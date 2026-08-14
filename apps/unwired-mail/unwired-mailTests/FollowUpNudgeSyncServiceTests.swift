import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
@Suite(.serialized)
final class FollowUpNudgeSyncServiceTests {
  private let firstDeviceSession = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "first-device-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )
  private let secondDeviceSession = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "second-device-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-002"
  )

  @Test
  func testScheduledNudgeSynchronizesWithinProfileAndTransfersOwnershipOnReschedule()
    async throws
  {
    let services = try makeServices()

    try await services.firstDevice.schedule(
      thread: Self.sentThread,
      dueAtMilliseconds: 1_781_286_400_000,
      authorizedSendingAddresses: ["Me <me@example.com>"],
      source: .scheduled,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let firstSnapshot = try await services.secondDevice.load(
      profileId: Self.profileId,
      session: secondDeviceSession
    )
    #expect(firstSnapshot.nudges[Self.sentThread.id]?.source == .scheduled)
    #expect(
      firstSnapshot.nudges[Self.sentThread.id]?.notificationOwnerDeviceId
        == firstDeviceSession.trustedDeviceId
    )

    try await services.secondDevice.schedule(
      thread: Self.sentThread,
      dueAtMilliseconds: 1_781_372_800_000,
      authorizedSendingAddresses: ["me@example.com", "alias@example.com"],
      source: .suggestionAccepted,
      profileId: Self.profileId,
      session: secondDeviceSession
    )
    let rescheduled = try await services.firstDevice.load(
      profileId: Self.profileId,
      session: firstDeviceSession
    )

    #expect(rescheduled.nudges[Self.sentThread.id]?.source == .suggestionAccepted)
    #expect(rescheduled.nudges[Self.sentThread.id]?.dueAtMilliseconds == 1_781_372_800_000)
    #expect(
      rescheduled.nudges[Self.sentThread.id]?.notificationOwnerDeviceId
        == secondDeviceSession.trustedDeviceId
    )
  }

  @Test
  func testOnlySentMessagesFromAuthorizedIdentityCanCreateNudge() async throws {
    let services = try makeServices()
    let incomingThread = try #require(
      MailboxThread.group([
        Self.message(
          id: "incoming",
          receivedAtMilliseconds: 1_781_199_000_000,
          from: "sender@example.com",
          states: ["INBOX"]
        )
      ]).first
    )

    await #expect(throws: FollowUpNudgeSyncError.ineligibleThread) {
      try await services.firstDevice.schedule(
        thread: incomingThread,
        dueAtMilliseconds: 1_781_286_400_000,
        authorizedSendingAddresses: ["me@example.com"],
        source: .scheduled,
        profileId: Self.profileId,
        session: firstDeviceSession
      )
    }
    await #expect(throws: FollowUpNudgeSyncError.ineligibleThread) {
      try await services.firstDevice.schedule(
        thread: Self.sentThread,
        dueAtMilliseconds: 1_781_286_400_000,
        authorizedSendingAddresses: ["different@example.com"],
        source: .scheduled,
        profileId: Self.profileId,
        session: firstDeviceSession
      )
    }
  }

  @Test
  func testQualifyingReplyCancelsNudgeButAuthorizedAliasDoesNot() async throws {
    let services = try makeServices()
    try await services.firstDevice.schedule(
      thread: Self.sentThread,
      dueAtMilliseconds: 1_781_286_400_000,
      authorizedSendingAddresses: ["me@example.com", "Alias <alias@example.com>"],
      source: .scheduled,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let aliasMessage = Self.message(
      id: "alias-message",
      receivedAtMilliseconds: 1_781_200_000_000,
      from: "Alias <ALIAS@example.com>",
      states: ["INBOX"]
    )

    let afterAlias = try await services.secondDevice.reconcile(
      with: Self.sentThread.messages + [aliasMessage],
      profileId: Self.profileId,
      session: secondDeviceSession
    )
    #expect(afterAlias.nudges[Self.sentThread.id] != nil)

    let reply = Self.message(
      id: "reply-message",
      receivedAtMilliseconds: 1_781_201_000_000,
      from: "Recipient <recipient@example.com>",
      states: ["INBOX", "UNREAD"]
    )
    let afterReply = try await services.secondDevice.reconcile(
      with: Self.sentThread.messages + [aliasMessage, reply],
      profileId: Self.profileId,
      session: secondDeviceSession
    )

    #expect(afterReply.nudges.isEmpty)
    #expect(
      try await services.firstDevice.load(
        profileId: Self.profileId,
        session: firstDeviceSession
      ).nudges.isEmpty
    )
  }

  @Test
  func testReplyCancellationPreservesConcurrentReschedule() async throws {
    let transport = FollowUpNudgeReconcileRaceTransport()
    let services = try makeServices(transport: transport)
    try await services.firstDevice.schedule(
      thread: Self.sentThread,
      dueAtMilliseconds: 1_781_286_400_000,
      authorizedSendingAddresses: ["me@example.com"],
      source: .scheduled,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let reply = Self.message(
      id: "reply-message",
      receivedAtMilliseconds: 1_781_201_000_000,
      from: "recipient@example.com",
      states: ["INBOX"]
    )
    await transport.holdNextList()
    let reconcile = Task {
      try await services.firstDevice.reconcile(
        with: Self.sentThread.messages + [reply],
        profileId: Self.profileId,
        session: firstDeviceSession
      )
    }
    await transport.waitUntilListIsHeld()
    try await services.secondDevice.schedule(
      thread: Self.sentThread,
      dueAtMilliseconds: 1_781_372_800_000,
      authorizedSendingAddresses: ["me@example.com"],
      source: .scheduled,
      profileId: Self.profileId,
      session: secondDeviceSession
    )
    await transport.releaseList()

    let reconciled = try await reconcile.value
    #expect(reconciled.nudges[Self.sentThread.id]?.dueAtMilliseconds == 1_781_372_800_000)
  }

  @Test
  func testNudgesStayProfileScopedAndOlderRecordFamiliesIgnoreThem() async throws {
    let transport = InMemoryProductSyncRecordTransport()
    let services = try makeServices(transport: transport)
    try await services.firstDevice.schedule(
      thread: Self.sentThread,
      dueAtMilliseconds: 1_781_286_400_000,
      authorizedSendingAddresses: ["me@example.com"],
      source: .scheduled,
      profileId: Self.profileId,
      session: firstDeviceSession
    )

    let otherProfile = try await services.secondDevice.load(
      profileId: MailProfileId(rawValue: "profile-002"),
      session: secondDeviceSession
    )
    #expect(otherProfile.nudges.isEmpty)

    let keyStore = try keyedStore(session: firstDeviceSession)
    let snoozes = try await ThreadSnoozeSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore,
        transport: transport
      ),
      ciphertextCache: InMemoryProductSyncCiphertextCache()
    ).load(profileId: Self.profileId, session: firstDeviceSession)
    #expect(snoozes.snoozes.isEmpty)
  }

  @Test
  func testOfflineRestartLoadsEncryptedNudgeFromCiphertextCache() async throws {
    let keyStore = try keyedStore(session: firstDeviceSession)
    let cache = InMemoryProductSyncCiphertextCache()
    let online = FollowUpNudgeSyncService(
      nowMilliseconds: { 1_781_200_000_000 },
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore,
        transport: InMemoryProductSyncRecordTransport()
      ),
      ciphertextCache: cache
    )
    try await online.schedule(
      thread: Self.sentThread,
      dueAtMilliseconds: 1_781_286_400_000,
      authorizedSendingAddresses: ["me@example.com"],
      source: .scheduled,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    _ = try await online.load(profileId: Self.profileId, session: firstDeviceSession)

    let offline = FollowUpNudgeSyncService(
      nowMilliseconds: { 1_781_200_000_000 },
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore,
        transport: OfflineFollowUpNudgeTransport()
      ),
      ciphertextCache: cache
    )
    let snapshot = try await offline.load(
      profileId: Self.profileId,
      session: firstDeviceSession
    )

    #expect(snapshot.nudges[Self.sentThread.id]?.dueAtMilliseconds == 1_781_286_400_000)
  }

  @Test
  @MainActor
  func testOverdueNudgeRemainsVisibleWhenNotificationsAreDenied() async throws {
    let nowMilliseconds: Int64 = 1_781_300_000_000
    let services = try makeServices(firstNowMilliseconds: 1_781_200_000_000)
    try await services.firstDevice.schedule(
      thread: Self.sentThread,
      dueAtMilliseconds: 1_781_286_400_000,
      authorizedSendingAddresses: ["me@example.com"],
      source: .scheduled,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let viewModel = FollowUpNudgeViewModel(
      attentionDelivery: RecordingFollowUpNudgeAttentionDelivery(),
      notificationAuthorization: DeniedNotificationAuthorization(),
      preferenceLoader: { _, _ in .defaults },
      scheduler: ThreadSnoozeScheduler(
        nowMilliseconds: { nowMilliseconds },
        sleepUntilMilliseconds: { _ in }
      ),
      service: services.firstDevice,
      session: firstDeviceSession,
      profileId: Self.profileId
    )

    await viewModel.load()

    #expect(viewModel.nudgeThreadIds == [Self.sentThread.id])
    #expect(viewModel.overdueThreadIds == [Self.sentThread.id])
  }

  @Test
  @MainActor
  func testOnDeviceSuggestionCreatesNothingUntilExplicitAcceptance() async throws {
    let nowMilliseconds = Int64(Date.now.timeIntervalSince1970 * 1_000)
    let oldSentThread = try #require(
      MailboxThread.group([
        Self.message(
          id: "old-sent",
          receivedAtMilliseconds: nowMilliseconds - Int64(3 * 24 * 60 * 60 * 1_000),
          from: "Me <me@example.com>",
          states: ["SENT"]
        )
      ]).first
    )
    let services = try makeServices(firstNowMilliseconds: nowMilliseconds)
    let connection = Self.connection
    let viewModel = FollowUpNudgeViewModel(
      preferenceLoader: { _, _ in .defaults },
      scheduler: ThreadSnoozeScheduler(
        nowMilliseconds: { nowMilliseconds },
        sleepUntilMilliseconds: { _ in try await Task.sleep(for: .seconds(86_400)) }
      ),
      service: services.firstDevice,
      session: firstDeviceSession,
      profileId: Self.profileId
    )

    await viewModel.reconcile(with: oldSentThread.messages, connections: [connection])
    #expect(viewModel.suggestedThreadIds == [oldSentThread.id])
    #expect(
      try await services.firstDevice.load(
        profileId: Self.profileId,
        session: firstDeviceSession
      ).nudges.isEmpty
    )

    await viewModel.acceptSuggestion(oldSentThread, connection: connection)
    let accepted = try await services.firstDevice.load(
      profileId: Self.profileId,
      session: firstDeviceSession
    )

    #expect(accepted.nudges[oldSentThread.id]?.source == .suggestionAccepted)
    #expect(viewModel.suggestedThreadIds.isEmpty)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testInterruptionPolicyHonorsOwnerPrivacyAndReturnToAttention() {
    let nudge = FollowUpNudge(
      anchorMessageId: Self.sentThread.latestMessage.id,
      anchorSentAtMilliseconds: Self.sentThread.latestMessage.providerInternalDateMilliseconds,
      authorizedSendingAddresses: ["me@example.com"],
      changedAtMilliseconds: 1,
      changedByTrustedDeviceId: firstDeviceSession.trustedDeviceId,
      dueAtMilliseconds: 2,
      notificationOwnerDeviceId: firstDeviceSession.trustedDeviceId,
      observedMessageIds: [Self.sentThread.latestMessage.id],
      profileId: Self.profileId,
      source: .scheduled,
      threadId: Self.sentThread.id
    )
    let revealing = FollowUpNudgeInterruptionPolicy(
      allowsLockScreenContent: true,
      isOSAuthorized: true,
      isProfileLocked: false,
      isQuiet: false,
      returnToAttentionEnabled: true,
      trustedDeviceId: firstDeviceSession.trustedDeviceId
    )

    #expect(revealing.decision(for: nudge, subject: "Subject") == .revealing("Subject"))
    #expect(
      FollowUpNudgeInterruptionPolicy(
        allowsLockScreenContent: false,
        isOSAuthorized: true,
        isProfileLocked: false,
        isQuiet: false,
        returnToAttentionEnabled: true,
        trustedDeviceId: firstDeviceSession.trustedDeviceId
      ).decision(for: nudge, subject: "Subject") == .generic
    )
    #expect(
      FollowUpNudgeInterruptionPolicy(
        allowsLockScreenContent: true,
        isOSAuthorized: true,
        isProfileLocked: false,
        isQuiet: true,
        returnToAttentionEnabled: true,
        trustedDeviceId: firstDeviceSession.trustedDeviceId
      ).decision(for: nudge, subject: "Subject") == .suppress
    )
    #expect(
      FollowUpNudgeInterruptionPolicy(
        allowsLockScreenContent: true,
        isOSAuthorized: true,
        isProfileLocked: false,
        isQuiet: false,
        returnToAttentionEnabled: true,
        trustedDeviceId: secondDeviceSession.trustedDeviceId
      ).decision(for: nudge, subject: "Subject") == .suppress
    )
  }

  private func makeServices(
    firstNowMilliseconds: Int64 = 1_781_200_000_001,
    secondNowMilliseconds: Int64 = 1_781_200_000_002,
    transport: (any ProductSyncRecordTransport)? = nil
  ) throws -> (
    firstDevice: FollowUpNudgeSyncService,
    secondDevice: FollowUpNudgeSyncService
  ) {
    let keyMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 7, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 8, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let firstStore = InMemoryProductSyncKeyMaterialStore()
    let secondStore = InMemoryProductSyncKeyMaterialStore()
    try firstStore.save(keyMaterial, productAccountId: firstDeviceSession.productAccountId)
    try secondStore.save(keyMaterial, productAccountId: secondDeviceSession.productAccountId)
    let transport = transport ?? InMemoryProductSyncRecordTransport()
    return (
      FollowUpNudgeSyncService(
        nowMilliseconds: { firstNowMilliseconds },
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: firstStore,
          transport: transport
        ),
        ciphertextCache: InMemoryProductSyncCiphertextCache()
      ),
      FollowUpNudgeSyncService(
        nowMilliseconds: { secondNowMilliseconds },
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: secondStore,
          transport: transport
        ),
        ciphertextCache: InMemoryProductSyncCiphertextCache()
      )
    )
  }

  private func keyedStore(
    session: ProductAccountSessionSnapshot
  ) throws -> InMemoryProductSyncKeyMaterialStore {
    let keyMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 7, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 8, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let store = InMemoryProductSyncKeyMaterialStore()
    try store.save(keyMaterial, productAccountId: session.productAccountId)
    return store
  }

  private static let profileId = MailProfileId(rawValue: "profile-001")
  private static let connectionId = MailboxConnectionId(
    providerMailboxIdentity: StableProviderMailboxIdentity(
      providerId: .gmail,
      value: "gmail-user-001"
    )
  )
  private static let connection = MailboxConnection(
    authorizationState: .authorized,
    capabilities: .gmail,
    connectedAt: 1,
    displayName: "me@example.com",
    id: connectionId,
    lastVerifiedAt: 1,
    productAccountId: ProductAccountId("product-account-001"),
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1
  )
  private static let sentThread = MailboxThread.group([
    message(
      id: "sent-message",
      receivedAtMilliseconds: 1_781_199_000_000,
      from: "Me <me@example.com>",
      states: ["SENT"]
    )
  ])[0]

  private static func message(
    id: String,
    receivedAtMilliseconds: Int64,
    from: String,
    states: [String],
    threadId: String = "thread-001"
  ) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: nil,
      connectionId: connectionId,
      from: from,
      isHistorical: false,
      providerInternalDateMilliseconds: receivedAtMilliseconds,
      providerMessageId: id,
      providerStateIds: states,
      providerThreadId: threadId,
      recipientHeaders: ["recipient@example.com"],
      replyTo: nil,
      rfcMessageId: "<\(id)@example.com>",
      snippet: "Preview",
      subject: "Subject"
    )
  }
}

private actor FollowUpNudgeReconcileRaceTransport: ProductSyncRecordTransport {
  private let backing = InMemoryProductSyncRecordTransport()
  private let listGate = TestRendezvous()
  private var shouldHoldNextList = false

  func holdNextList() {
    shouldHoldNextList = true
  }

  func waitUntilListIsHeld() async {
    await listGate.waitUntilHeld()
  }

  func releaseList() async {
    await listGate.release()
  }

  func listEncryptedProductSyncPayloads(
    session: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor: String?,
    limit: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    let page = try await backing.listEncryptedProductSyncPayloads(
      session: session,
      payloadIdentifierPrefix: payloadIdentifierPrefix,
      cursor: cursor,
      limit: limit
    )
    if shouldHoldNextList {
      shouldHoldNextList = false
      await listGate.hold()
    }
    return page
  }

  func getEncryptedProductSyncPayloads(
    session: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    try await backing.getEncryptedProductSyncPayloads(
      session: session,
      payloadIdentifiers: payloadIdentifiers
    )
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    try await backing.putEncryptedProductSyncPayloadIfUnchanged(
      session: session,
      payloadIdentifier: payloadIdentifier,
      encryptedPayload: encryptedPayload,
      expectedUpdatedAt: expectedUpdatedAt
    )
  }
}

private struct OfflineFollowUpNudgeTransport: ProductSyncRecordTransport {
  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix _: String,
    cursor _: String?,
    limit _: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    throw URLError(.notConnectedToInternet)
  }

  func getEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifiers _: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    throw URLError(.notConnectedToInternet)
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier _: String,
    encryptedPayload _: ProductSyncEncryptedPayload,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    throw URLError(.notConnectedToInternet)
  }
}

private struct DeniedNotificationAuthorization: NotificationAuthorizationStateChecking {
  func notificationAuthorizationState() async -> NotificationAuthorizationState {
    .denied
  }
}

private actor RecordingFollowUpNudgeAttentionDelivery: FollowUpNudgeAttentionDelivering {
  func deliverFollowUpNudgeAttention(
    decision _: ThreadSnoozeInterruptionDecision,
    nudge _: FollowUpNudge,
    productAccountId _: String
  ) async throws {}
}
