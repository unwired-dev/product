import CryptoKit
import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length

@Suite(.serialized)
// swiftlint:disable:next type_body_length
final class PinSyncServiceTests {
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
  func testPinSynchronizesAcrossTrustedDevicesWithoutExposingMessageIdentity() async throws {
    let services = try makeServices()

    try await services.firstDevice.setPinned(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: firstDeviceSession
    )
    let secondDevicePins = try await services.secondDevice.loadPinnedThreadIds(
      session: secondDeviceSession
    )

    #expect(secondDevicePins == [Self.threadId])
    let firstPayload = await services.transport.firstPayload()
    let storedPayload = try requireValue(firstPayload)
    #expect(!(storedPayload.payloadIdentifier.contains(Self.messageId.providerMessageId)))
    #expect(
      !(storedPayload.encryptedPayload.ciphertextBase64.contains(Self.messageId.providerMessageId)))
    #expect(
      !(storedPayload.encryptedPayload.ciphertextBase64.contains(
        Self.messageId.connectionId.providerMailboxIdentity.value
      )))
  }

  @Test
  func testUnpinTombstoneConvergesWithoutRemovingAnotherConnectionPin() async throws {
    let services = try makeServices()
    let otherConnectionMessageId = StableProviderMessageIdentity(
      connectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .gmail,
          value: "gmail-user-002"
        )
      ),
      providerMessageId: Self.messageId.providerMessageId
    )
    let otherConnectionThreadId = StableThreadIdentity(
      connectionId: otherConnectionMessageId.connectionId,
      providerThreadId: Self.threadId.providerThreadId
    )
    try await services.firstDevice.setPinned(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: firstDeviceSession
    )
    try await services.secondDevice.setPinned(
      true,
      threadId: otherConnectionThreadId,
      anchorMessageId: otherConnectionMessageId,
      session: secondDeviceSession
    )

    try await services.firstDevice.setPinned(
      false,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: firstDeviceSession
    )

    let pins = try await services.secondDevice.loadPinnedThreadIds(
      session: secondDeviceSession
    )
    #expect(pins == [otherConnectionThreadId])
    let payloadCount = await services.transport.payloadCount(
      prefix: PinSyncService.payloadIdentifierPrefix
    )
    #expect(payloadCount == 2)
  }

  @Test
  func testDelayedOlderPinCannotOverwriteNewerUnpin() async throws {
    let services = try makeServices(
      firstDeviceNowMilliseconds: { 100 },
      secondDeviceNowMilliseconds: { 200 }
    )
    await services.transport.blockNextGet(identityToken: firstDeviceSession.identityToken)
    let delayedPin = Task {
      try await services.firstDevice.setPinned(
        true,
        threadId: Self.threadId,
        anchorMessageId: Self.messageId,
        session: firstDeviceSession
      )
    }
    await services.transport.waitUntilGetIsBlocked()

    try await services.secondDevice.setPinned(
      false,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: secondDeviceSession
    )
    await services.transport.releaseBlockedGet()

    do {
      try await delayedPin.value
      Issue.record("Expected the older Pin to lose to the newer Unpin")
    } catch PinSyncError.concurrentModification {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    let pins = try await services.firstDevice.loadPinnedThreadIds(session: firstDeviceSession)
    #expect(pins == [])
  }

  @Test
  func testPinMetadataSurvivesBodyCacheEviction() async throws {
    let services = try makeServices()
    try await services.firstDevice.setPinned(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: firstDeviceSession
    )
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let bodyCache = FileGmailMessageBodyCache(rootDirectory: rootDirectory)
    let stableProviderMessageId = Self.messageId.rawValue
    let cachedBody = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: "ciphertext",
      keyVersion: 1,
      nonceBase64: "nonce",
      schemaVersion: 1,
      tagBase64: "tag"
    )
    try bodyCache.saveMessageBody(
      cachedBody,
      productAccountId: firstDeviceSession.productAccountId,
      stableProviderMessageId: stableProviderMessageId
    )

    try bodyCache.removeMessageBody(
      productAccountId: firstDeviceSession.productAccountId,
      stableProviderMessageId: stableProviderMessageId
    )

    #expect(
      try bodyCache.loadMessageBody(
        productAccountId: firstDeviceSession.productAccountId,
        stableProviderMessageId: stableProviderMessageId
      ) == nil)
    let pins = try await services.secondDevice.loadPinnedThreadIds(session: secondDeviceSession)
    #expect(pins == [Self.threadId])
  }

  @MainActor
  @Test
  func testPinInteractionUpdatesLocallyBeforeProductSyncCompletes() async {
    let service = DelayedPinSyncService()
    let viewModel = PinViewModel(service: service, session: firstDeviceSession)

    let update = Task {
      await viewModel.togglePin(Self.threadId, anchorMessageId: Self.messageId)
    }
    await service.waitUntilSaveStarted()

    #expect(viewModel.pinnedThreadIds == [Self.threadId])
    #expect(viewModel.isUpdating(Self.threadId))

    await service.releaseSave()
    await update.value

    #expect(viewModel.pinnedThreadIds == [Self.threadId])
    #expect(!(viewModel.isUpdating(Self.threadId)))
    #expect(viewModel.errorMessage == nil)
  }

  @MainActor
  @Test
  func testPinViewModelUsesRefreshedSessionWithoutLosingLocalState() async {
    let service = RecordingPinSessionService()
    let viewModel = PinViewModel(service: service, session: firstDeviceSession)
    let refreshedSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: firstDeviceSession.appleUserIdentifier,
      identityToken: "refreshed-token",
      productAccountId: firstDeviceSession.productAccountId,
      trustedDeviceId: firstDeviceSession.trustedDeviceId
    )

    await viewModel.togglePin(Self.threadId, anchorMessageId: Self.messageId)
    viewModel.updateSession(refreshedSession)
    await viewModel.togglePin(Self.threadId, anchorMessageId: Self.messageId)

    #expect(viewModel.pinnedThreadIds.isEmpty)
    let sessions = await service.recordedSessions()
    #expect(sessions == [firstDeviceSession, refreshedSession])
  }

  @MainActor
  @Test
  func testPinInteractionDoesNotInvokeProviderMailActions() async throws {
    let services = try makeServices()
    let providerActions = RecordingProviderMailActionService()
    let pinViewModel = PinViewModel(service: services.firstDevice, session: firstDeviceSession)
    let mailboxService = EmptyMailboxService()
    let reader = MailShellConversationReader(
      connections: [],
      featureSuggestionStore: FeatureSuggestionPreferenceStore(
        session: firstDeviceSession,
        automaticallySynchronizes: false
      ),
      followUpNudgeViewModel: nil,
      inboxViewModel: GmailInboxViewModel(
        service: mailboxService,
        searchService: mailboxService,
        session: firstDeviceSession
      ),
      isConnectionBusy: false,
      mailActionViewModel: GmailMailActionViewModel(
        service: providerActions,
        session: firstDeviceSession
      ),
      messageReader: mailboxService,
      pinViewModel: pinViewModel,
      snoozeViewModel: ThreadSnoozeViewModel(
        service: ThreadSnoozeSyncService(),
        session: firstDeviceSession
      ),
      selection: MailShellSelectionModel(),
      session: firstDeviceSession
    )

    await reader.togglePin(Self.threadId, anchorMessageId: Self.messageId)

    let providerMutationCount = await providerActions.mutationCount()
    #expect(providerMutationCount == 0)
    #expect(pinViewModel.pinnedThreadIds == [Self.threadId])
  }

  @MainActor
  @Test
  func testAttachmentDownloadDoesNotInvokeProviderAfterRevalidationFails() async {
    let mailboxService = EmptyMailboxService()
    let reader = MailShellConversationReader(
      connections: [],
      featureSuggestionStore: FeatureSuggestionPreferenceStore(
        session: firstDeviceSession,
        automaticallySynchronizes: false
      ),
      followUpNudgeViewModel: nil,
      inboxViewModel: GmailInboxViewModel(
        service: mailboxService,
        searchService: mailboxService,
        session: firstDeviceSession
      ),
      isConnectionBusy: false,
      mailActionViewModel: GmailMailActionViewModel(
        service: RecordingProviderMailActionService(),
        session: firstDeviceSession
      ),
      messageReader: mailboxService,
      pinViewModel: PinViewModel(
        service: FailingPinSyncService(),
        session: firstDeviceSession
      ),
      snoozeViewModel: ThreadSnoozeViewModel(
        service: ThreadSnoozeSyncService(),
        session: firstDeviceSession
      ),
      selection: MailShellSelectionModel(),
      session: firstDeviceSession,
      revalidateTrustedDevice: { false }
    )

    do {
      _ = try await reader.loadAttachmentAfterRevalidation {
        Issue.record("Expected attachment loading to remain blocked")
        return Data()
      }
      Issue.record("Expected attachment loading to be cancelled")
    } catch is CancellationError {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @MainActor
  @Test
  func testPinInteractionRollsBackWhenProductSyncFails() async {
    let viewModel = PinViewModel(
      service: FailingPinSyncService(),
      session: firstDeviceSession
    )

    await viewModel.togglePin(Self.threadId, anchorMessageId: Self.messageId)

    #expect(viewModel.pinnedThreadIds.isEmpty)
    #expect(viewModel.errorMessage == PinSyncError.concurrentModification.localizedDescription)
  }

  private func makeServices(
    firstDeviceNowMilliseconds: @escaping @Sendable () -> Int64 = {
      1_781_200_000_001
    },
    secondDeviceNowMilliseconds: @escaping @Sendable () -> Int64 = {
      1_781_200_000_002
    }
  ) throws -> Services {
    let keyMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 7, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 8, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let firstStore = InMemoryProductSyncKeyMaterialStore()
    let secondStore = InMemoryProductSyncKeyMaterialStore()
    try firstStore.save(keyMaterial, productAccountId: firstDeviceSession.productAccountId)
    try secondStore.save(keyMaterial, productAccountId: secondDeviceSession.productAccountId)
    let transport = PinSyncTestTransport()
    let firstBoundary = ProductSyncRecordBoundary(
      keyMaterialStore: firstStore,
      transport: transport
    )
    return Services(
      firstDevice: PinSyncService(
        nowMilliseconds: firstDeviceNowMilliseconds,
        recordBoundary: firstBoundary
      ),
      secondDevice: PinSyncService(
        nowMilliseconds: secondDeviceNowMilliseconds,
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: secondStore,
          transport: transport
        )
      ),
      legacyRecords: firstBoundary.family(
        ProductSyncRecordFamilyDefinition<String, LegacyPinTestPayload>(
          identifier: { $0 },
          identifierPrefix: PinSyncService.legacyPayloadIdentifierPrefix,
          recordId: { identifier in
            identifier.hasPrefix(PinSyncService.legacyPayloadIdentifierPrefix)
              ? identifier
              : nil
          },
          cachePolicy: .authoritative
        )
      ),
      transport: transport
    )
  }

  private struct Services {
    let firstDevice: PinSyncService
    let secondDevice: PinSyncService
    let legacyRecords: ProductSyncRecordFamilyHandle<String, LegacyPinTestPayload>
    let transport: PinSyncTestTransport

    func writeLegacyPin(
      _ messageId: StableProviderMessageIdentity,
      isPinned: Bool = true,
      changedAtMilliseconds: Int64 = 1,
      session: ProductAccountSessionSnapshot
    ) async throws {
      let identifier = PinSyncServiceTests.legacyIdentifier(for: messageId)
      _ = try await legacyRecords.update(identifier, session: session) { _ in
        .write(
          LegacyPinTestPayload(
            changedAtMilliseconds: changedAtMilliseconds,
            changedByTrustedDeviceId: session.trustedDeviceId,
            isPinned: isPinned,
            messageId: messageId
          )
        )
      }
    }

    func legacyPinState(
      _ messageId: StableProviderMessageIdentity,
      session: ProductAccountSessionSnapshot
    ) async throws -> Bool? {
      let identifier = PinSyncServiceTests.legacyIdentifier(for: messageId)
      let record = try await legacyRecords.read([identifier], session: session)[identifier]
      return record?.value.isPinned
    }
  }

  private static let messageId = StableProviderMessageIdentity(
    connectionId: MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-001"
      )
    ),
    providerMessageId: "message-001"
  )
  private static let threadId = StableThreadIdentity(
    connectionId: messageId.connectionId,
    providerThreadId: "thread-001"
  )

  private static func message(
    threadId: String
  ) -> MailboxMessageMetadata {
    message(messageId: Self.messageId, threadId: threadId)
  }

  private static func message(
    messageId: StableProviderMessageIdentity,
    threadId: String
  ) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: nil,
      connectionId: messageId.connectionId,
      from: "sender@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: 1,
      providerMessageId: messageId.providerMessageId,
      providerStateIds: ["INBOX"],
      providerThreadId: threadId,
      recipientHeaders: nil,
      replyTo: nil,
      rfcMessageId: nil,
      snippet: "Preview",
      subject: "Subject"
    )
  }

  private static func legacyIdentifier(for messageId: StableProviderMessageIdentity) -> String {
    let components = [
      messageId.connectionId.providerId.rawValue,
      messageId.connectionId.providerMailboxIdentity.value,
      messageId.providerMessageId,
    ]
    let canonicalIdentity = components.map { "\($0.utf8.count):\($0)" }.joined()
    let digest = SHA256.hash(data: Data(canonicalIdentity.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return PinSyncService.legacyPayloadIdentifierPrefix + digest
  }
}

private struct LegacyPinTestPayload: Codable, Equatable, Sendable {
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let isPinned: Bool
  let provider: String
  let providerAccountIdentifier: String
  let providerMessageId: String
  let schemaVersion: Int

  init(
    changedAtMilliseconds: Int64,
    changedByTrustedDeviceId: String,
    isPinned: Bool,
    messageId: StableProviderMessageIdentity
  ) {
    self.changedAtMilliseconds = changedAtMilliseconds
    self.changedByTrustedDeviceId = changedByTrustedDeviceId
    self.isPinned = isPinned
    provider = messageId.connectionId.providerId.rawValue
    providerAccountIdentifier = messageId.connectionId.providerMailboxIdentity.value
    providerMessageId = messageId.providerMessageId
    schemaVersion = 1
  }
}

extension PinSyncServiceTests {
  @Test
  func testPinAfterLoadingNewerRemoteChangeAdvancesLogicalClock() async throws {
    let services = try makeServices(
      firstDeviceNowMilliseconds: { 100 },
      secondDeviceNowMilliseconds: { 200 }
    )
    try await services.secondDevice.setPinned(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: secondDeviceSession
    )

    let firstDevicePins = try await services.firstDevice.loadPinnedThreadIds(
      session: firstDeviceSession
    )
    #expect(firstDevicePins == [Self.threadId])
    try await services.firstDevice.setPinned(
      false,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: firstDeviceSession
    )

    let secondDevicePins = try await services.secondDevice.loadPinnedThreadIds(
      session: secondDeviceSession
    )
    #expect(secondDevicePins == [])
  }

  @Test
  func testPinAfterObservingNewerMatchingRemoteChangeAdvancesLogicalClock() async throws {
    let services = try makeServices(
      firstDeviceNowMilliseconds: { 100 },
      secondDeviceNowMilliseconds: { 200 }
    )
    try await services.secondDevice.setPinned(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: secondDeviceSession
    )

    try await services.firstDevice.setPinned(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: firstDeviceSession
    )
    try await services.firstDevice.setPinned(
      false,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: firstDeviceSession
    )

    let secondDevicePins = try await services.secondDevice.loadPinnedThreadIds(
      session: secondDeviceSession
    )
    #expect(secondDevicePins == [])
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testEqualTimestampConflictsUseTrustedDeviceIdRegardlessOfWriteOrder() async throws {
    for secondDeviceWritesFirst in [true, false] {
      let services = try makeServices(
        firstDeviceNowMilliseconds: { 100 },
        secondDeviceNowMilliseconds: { 100 }
      )
      if secondDeviceWritesFirst {
        await services.transport.blockNextGet(identityToken: secondDeviceSession.identityToken)
        let unpin = Task {
          try await services.secondDevice.setPinned(
            false,
            threadId: Self.threadId,
            anchorMessageId: Self.messageId,
            session: secondDeviceSession
          )
        }
        await services.transport.waitUntilGetIsBlocked()

        try await services.firstDevice.setPinned(
          true,
          threadId: Self.threadId,
          anchorMessageId: Self.messageId,
          session: firstDeviceSession
        )
        await services.transport.releaseBlockedGet()
        try await unpin.value
      } else {
        await services.transport.blockNextGet(identityToken: firstDeviceSession.identityToken)
        let pin = Task {
          try await services.firstDevice.setPinned(
            true,
            threadId: Self.threadId,
            anchorMessageId: Self.messageId,
            session: firstDeviceSession
          )
        }
        await services.transport.waitUntilGetIsBlocked()

        try await services.secondDevice.setPinned(
          false,
          threadId: Self.threadId,
          anchorMessageId: Self.messageId,
          session: secondDeviceSession
        )
        await services.transport.releaseBlockedGet()
        do {
          try await pin.value
          Issue.record("Expected the lower trusted device ID to lose the tie-breaker")
        } catch PinSyncError.concurrentModification {
        }
      }

      let pins = try await services.firstDevice.loadPinnedThreadIds(session: firstDeviceSession)
      #expect(pins == [])
    }
  }

  @MainActor
  @Test
  func testPinLoadPreservesAnInFlightOptimisticToggle() async {
    let service = DelayedPinSyncService()
    let viewModel = PinViewModel(service: service, session: firstDeviceSession)

    let update = Task {
      await viewModel.togglePin(Self.threadId, anchorMessageId: Self.messageId)
    }
    await service.waitUntilSaveStarted()
    await viewModel.load()

    #expect(viewModel.pinnedThreadIds == [Self.threadId])

    await service.releaseSave()
    await update.value
  }

  @MainActor
  @Test
  func testPinLoadDoesNotOverwriteAToggleThatCompletedDuringTheLoad() async {
    let service = StaleLoadingPinSyncService()
    let viewModel = PinViewModel(service: service, session: firstDeviceSession)

    let update = Task {
      await viewModel.togglePin(Self.threadId, anchorMessageId: Self.messageId)
    }
    await service.waitUntilSaveStarted()

    let load = Task {
      await viewModel.load()
    }
    await service.waitUntilLoadStarted()

    await service.releaseSave()
    await update.value
    await service.releaseLoad()
    await load.value

    #expect(viewModel.pinnedThreadIds == [Self.threadId])
  }

  @MainActor
  @Test
  func testPinReconciliationDoesNotOverwriteAToggleCompletedDuringReconciliation() async {
    let service = StaleLoadingPinSyncService()
    let viewModel = PinViewModel(service: service, session: firstDeviceSession)

    let update = Task {
      await viewModel.togglePin(Self.threadId, anchorMessageId: Self.messageId)
    }
    await service.waitUntilSaveStarted()

    let reconciliation = Task {
      await viewModel.reconcile(with: [Self.message(threadId: Self.threadId.providerThreadId)])
    }
    await service.waitUntilLoadStarted()

    await service.releaseSave()
    await update.value
    await service.releaseLoad()
    await reconciliation.value

    #expect(viewModel.pinnedThreadIds == [Self.threadId])
  }

  @MainActor
  @Test
  func testCancelledOlderReconciliationCannotOverwriteNewerResult() async {
    let newerThreadId = StableThreadIdentity(
      connectionId: Self.threadId.connectionId,
      providerThreadId: "thread-newer"
    )
    let service = OrderedPinReconcileService(
      olderResult: [Self.threadId],
      newerResult: [newerThreadId]
    )
    let viewModel = PinViewModel(service: service, session: firstDeviceSession)
    let olderReconciliation = Task {
      await viewModel.reconcile(with: [])
    }
    await service.waitUntilOlderReconciliationIsBlocked()

    olderReconciliation.cancel()
    await viewModel.reconcile(with: [])
    await service.releaseOlderReconciliation()
    await olderReconciliation.value

    #expect(viewModel.pinnedThreadIds == [newerThreadId])
  }

  @Test
  func testLegacyMessagePinsRemainActiveAndDeduplicateByThreadDuringRollout() async throws {
    let services = try makeServices()
    let secondMessageId = StableProviderMessageIdentity(
      connectionId: Self.messageId.connectionId,
      providerMessageId: "message-002"
    )
    try await services.writeLegacyPin(Self.messageId, session: firstDeviceSession)
    try await services.writeLegacyPin(secondMessageId, session: firstDeviceSession)
    let messages = [
      Self.message(messageId: Self.messageId, threadId: Self.threadId.providerThreadId),
      Self.message(messageId: secondMessageId, threadId: Self.threadId.providerThreadId),
    ]

    let firstResult = try await services.firstDevice.reconcilePins(
      with: messages,
      session: firstDeviceSession
    )
    let secondResult = try await services.secondDevice.reconcilePins(
      with: messages,
      session: secondDeviceSession
    )

    #expect(firstResult == [Self.threadId])
    #expect(secondResult == [Self.threadId])
    #expect(
      await services.transport.payloadCount(prefix: PinSyncService.payloadIdentifierPrefix) == 1)
    #expect(
      try await services.legacyPinState(Self.messageId, session: firstDeviceSession) == true)
    #expect(
      try await services.legacyPinState(secondMessageId, session: firstDeviceSession) == true)
  }

  @Test
  func testLegacyMessageWithoutReliableLinkageMigratesToSingletonThread() async throws {
    let services = try makeServices()
    let singletonThreadId = StableThreadIdentity(
      connectionId: Self.messageId.connectionId,
      providerThreadId:
        "message:\(Self.messageId.connectionId.rawValue):\(Self.messageId.providerMessageId)"
    )
    try await services.writeLegacyPin(Self.messageId, session: firstDeviceSession)

    let result = try await services.firstDevice.reconcilePins(
      with: [Self.message(threadId: singletonThreadId.providerThreadId)],
      session: firstDeviceSession
    )

    #expect(result == [singletonThreadId])
    #expect(try await services.legacyPinState(Self.messageId, session: firstDeviceSession) == true)
  }

  @Test
  func testLegacyUnpinFromOlderClientConvergesToThreadPin() async throws {
    let services = try makeServices(
      firstDeviceNowMilliseconds: { 100 },
      secondDeviceNowMilliseconds: { 200 }
    )
    try await services.firstDevice.setPinned(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: firstDeviceSession
    )
    try await services.writeLegacyPin(
      Self.messageId,
      isPinned: false,
      changedAtMilliseconds: 300,
      session: secondDeviceSession
    )

    let pins = try await services.secondDevice.reconcilePins(
      with: [Self.message(threadId: Self.threadId.providerThreadId)],
      session: secondDeviceSession
    )

    #expect(pins.isEmpty)
    #expect(try await services.legacyPinState(Self.messageId, session: firstDeviceSession) == false)
  }

  @Test
  func testLegacyPinRemainsUntilThreadPinWriteSucceeds() async throws {
    let services = try makeServices()
    try await services.writeLegacyPin(Self.messageId, session: firstDeviceSession)
    await services.transport.failNextPut(prefix: PinSyncService.payloadIdentifierPrefix)

    await #expect(throws: PinSyncTestTransportError.self) {
      try await services.firstDevice.reconcilePins(
        with: [Self.message(threadId: Self.threadId.providerThreadId)],
        session: firstDeviceSession
      )
    }

    #expect(try await services.legacyPinState(Self.messageId, session: firstDeviceSession) == true)
    #expect(
      await services.transport.payloadCount(prefix: PinSyncService.payloadIdentifierPrefix) == 0)
  }

  @Test
  func testPinnedThreadRepairsWhenAnchorMessageIsRethreaded() async throws {
    let services = try makeServices()
    let repairedThreadId = StableThreadIdentity(
      connectionId: Self.threadId.connectionId,
      providerThreadId: "thread-repaired"
    )
    try await services.firstDevice.setPinned(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: firstDeviceSession
    )

    let result = try await services.firstDevice.reconcilePins(
      with: [Self.message(threadId: repairedThreadId.providerThreadId)],
      session: firstDeviceSession
    )
    let repeatedResult = try await services.secondDevice.reconcilePins(
      with: [Self.message(threadId: repairedThreadId.providerThreadId)],
      session: secondDeviceSession
    )

    #expect(result == [repairedThreadId])
    #expect(repeatedResult == [repairedThreadId])
    let loadedPins = try await services.firstDevice.loadPinnedThreadIds(
      session: firstDeviceSession
    )
    #expect(loadedPins == [repairedThreadId])
    #expect(
      await services.transport.payloadCount(prefix: PinSyncService.payloadIdentifierPrefix) == 2)
    #expect(
      await services.transport.payloadCount(prefix: PinSyncService.redirectPayloadIdentifierPrefix)
        == 1)

    try await services.secondDevice.setPinned(
      false,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: secondDeviceSession
    )
    #expect(
      try await services.firstDevice.loadPinnedThreadIds(session: firstDeviceSession).isEmpty)
    #expect(
      await services.transport.payloadCount(prefix: PinSyncService.payloadIdentifierPrefix) == 2)
  }

  @Test
  func testPinnedThreadDoesNotCreateRedirectCycleWhenAnchorReturns() async throws {
    let services = try makeServices()
    let repairedThreadId = StableThreadIdentity(
      connectionId: Self.threadId.connectionId,
      providerThreadId: "thread-repaired"
    )
    try await services.firstDevice.setPinned(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: firstDeviceSession
    )

    _ = try await services.firstDevice.reconcilePins(
      with: [Self.message(threadId: repairedThreadId.providerThreadId)],
      session: firstDeviceSession
    )
    let result = try await services.firstDevice.reconcilePins(
      with: [Self.message(threadId: Self.threadId.providerThreadId)],
      session: firstDeviceSession
    )

    #expect(result == [repairedThreadId])
    #expect(
      try await services.firstDevice.loadPinnedThreadIds(session: firstDeviceSession)
        == [repairedThreadId])
    try await services.firstDevice.setPinned(
      false,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: firstDeviceSession
    )
    #expect(
      try await services.firstDevice.loadPinnedThreadIds(session: firstDeviceSession).isEmpty)
  }

  @Test
  func testConcurrentReverseRedirectsUseOneCanonicalThread() async throws {
    let services = try makeServices()
    let alternateThreadId = StableThreadIdentity(
      connectionId: Self.threadId.connectionId,
      providerThreadId: "thread-alternate"
    )
    try await services.firstDevice.setPinned(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: firstDeviceSession
    )
    try await services.secondDevice.setPinned(
      true,
      threadId: alternateThreadId,
      anchorMessageId: Self.messageId,
      session: secondDeviceSession
    )

    async let forward = services.firstDevice.reconcilePins(
      with: [Self.message(threadId: alternateThreadId.providerThreadId)],
      session: firstDeviceSession
    )
    async let reverse = services.secondDevice.reconcilePins(
      with: [Self.message(threadId: Self.threadId.providerThreadId)],
      session: secondDeviceSession
    )
    _ = try await (forward, reverse)

    try await services.firstDevice.setPinned(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      session: firstDeviceSession
    )
    let pinned = try await services.secondDevice.loadPinnedThreadIds(session: secondDeviceSession)
    #expect(pinned.count == 1)
    try await services.secondDevice.setPinned(
      false,
      threadId: alternateThreadId,
      anchorMessageId: Self.messageId,
      session: secondDeviceSession
    )
    #expect(
      try await services.firstDevice.loadPinnedThreadIds(session: firstDeviceSession).isEmpty)
  }
}

private actor DelayedPinSyncService: PinSyncing {
  private var saveContinuation: CheckedContinuation<Void, Never>?
  private var saveStarted = false

  func loadPinnedThreadIds(
    session _: ProductAccountSessionSnapshot
  ) async throws -> Set<StableThreadIdentity> {
    []
  }

  func setPinned(
    _ isPinned: Bool,
    threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    _ = isPinned
    _ = threadId
    _ = anchorMessageId
    saveStarted = true
    await withCheckedContinuation { continuation in
      saveContinuation = continuation
    }
  }

  func waitUntilSaveStarted() async {
    while !saveStarted {
      await Task.yield()
    }
  }

  func releaseSave() {
    saveContinuation?.resume()
    saveContinuation = nil
  }
}

private actor StaleLoadingPinSyncService: PinSyncing {
  private var loadContinuation: CheckedContinuation<Void, Never>?
  private var loadStarted = false
  private var saveContinuation: CheckedContinuation<Void, Never>?
  private var saveStarted = false

  func loadPinnedThreadIds(
    session _: ProductAccountSessionSnapshot
  ) async throws -> Set<StableThreadIdentity> {
    loadStarted = true
    await withCheckedContinuation { continuation in
      loadContinuation = continuation
    }
    return []
  }

  func setPinned(
    _: Bool,
    threadId _: StableThreadIdentity,
    anchorMessageId _: StableProviderMessageIdentity,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    saveStarted = true
    await withCheckedContinuation { continuation in
      saveContinuation = continuation
    }
  }

  func waitUntilLoadStarted() async {
    while !loadStarted {
      await Task.yield()
    }
  }

  func waitUntilSaveStarted() async {
    while !saveStarted {
      await Task.yield()
    }
  }

  func releaseLoad() {
    loadContinuation?.resume()
    loadContinuation = nil
  }

  func releaseSave() {
    saveContinuation?.resume()
    saveContinuation = nil
  }
}

private actor OrderedPinReconcileService: PinSyncing {
  private let newerResult: Set<StableThreadIdentity>
  private let olderResult: Set<StableThreadIdentity>
  private var olderContinuation: CheckedContinuation<Void, Never>?
  private var reconciliationCount = 0

  init(
    olderResult: Set<StableThreadIdentity>,
    newerResult: Set<StableThreadIdentity>
  ) {
    self.olderResult = olderResult
    self.newerResult = newerResult
  }

  func loadPinnedThreadIds(
    session _: ProductAccountSessionSnapshot
  ) async throws -> Set<StableThreadIdentity> {
    []
  }

  func reconcilePins(
    with _: [MailboxMessageMetadata],
    session _: ProductAccountSessionSnapshot
  ) async throws -> Set<StableThreadIdentity> {
    reconciliationCount += 1
    guard reconciliationCount == 1 else { return newerResult }
    await withCheckedContinuation { continuation in
      olderContinuation = continuation
    }
    return olderResult
  }

  func setPinned(
    _: Bool,
    threadId _: StableThreadIdentity,
    anchorMessageId _: StableProviderMessageIdentity,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func waitUntilOlderReconciliationIsBlocked() async {
    while olderContinuation == nil {
      await Task.yield()
    }
  }

  func releaseOlderReconciliation() {
    olderContinuation?.resume()
    olderContinuation = nil
  }
}

private struct FailingPinSyncService: PinSyncing {
  func loadPinnedThreadIds(
    session _: ProductAccountSessionSnapshot
  ) async throws -> Set<StableThreadIdentity> {
    []
  }

  func setPinned(
    _ isPinned: Bool,
    threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    _ = isPinned
    _ = threadId
    _ = anchorMessageId
    throw PinSyncError.concurrentModification
  }
}

private actor RecordingProviderMailActionService: MailboxProviderMailActing {
  private var mutations = 0

  func perform(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    _ = action
    _ = messages
    _ = connection
    _ = session
    mutations += 1
  }

  func send(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    _ = message
    _ = connection
    _ = session
    mutations += 1
  }

  func mutationCount() -> Int {
    mutations
  }
}

private final class EmptyMailboxService:
  MailboxMessageReading, MailboxMessageSearching, MailboxMetadataSyncing
{
  func categorizeHistorical(
    scope _: HistoricalCategorizationScope,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    emptyResult
  }

  func loadInbox(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    emptyResult
  }

  func syncInbox(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    emptyResult
  }

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection _: MailboxConnection,
    includingHistoryCandidates _: Bool,
    session _: ProductAccountSessionSnapshot,
    sinceHistoryId _: String?,
    throughHistoryId _: String?,
    shouldPersist _: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    emptyResult
  }

  func overrideCategory(
    _: String,
    for message: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    message
  }

  func setCategories(
    _ categoryIds: [String],
    for message: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    message.assigningCategories(categoryIds)
  }

  func searchProvider(
    query _: String,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata] {
    []
  }

  func clearCachedMessageBodies(session _: ProductAccountSessionSnapshot) throws {}

  func clearCachedMessageBodies(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) throws {}

  func loadMessageBody(
    message _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    MailboxMessageBody(text: "")
  }

  func removeCachedMessageBody(
    message _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws {}

  private var emptyResult: MailboxMetadataSyncResult {
    MailboxMetadataSyncResult(
      hasUnlistedNewMessages: false,
      messages: [],
      newMessageIds: [],
      providerCursorIsExpired: false,
      threads: []
    )
  }
}

private enum PinSyncTestTransportError: Error {
  case unavailable
}

private actor PinSyncTestTransport: ProductSyncRecordTransport {
  private var blockedGetContinuation: CheckedContinuation<Void, Never>?
  private var blockedGetHasStarted = false
  private var blockedIdentityToken: String?
  private var failingPutPrefix: String?
  private var payloads: [String: EncryptedProductSyncPayload] = [:]
  private var updatedAt: Int64 = 1_781_200_000_000

  func firstPayload() -> EncryptedProductSyncPayload? {
    payloads.values.first
  }

  func payloadCount() -> Int {
    payloads.count
  }

  func payloadCount(prefix: String) -> Int {
    payloads.keys.count { $0.hasPrefix(prefix) }
  }

  func failNextPut(prefix: String) {
    failingPutPrefix = prefix
  }

  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor: String?,
    limit: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    let matching = payloads.values
      .filter { $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) }
      .sorted { $0.payloadIdentifier < $1.payloadIdentifier }
    let start = min(Int(cursor ?? "") ?? 0, matching.count)
    let end = min(start + limit, matching.count)
    return EncryptedProductSyncPayloadPage(
      continueCursor: end == matching.count ? "" : String(end),
      isDone: end == matching.count,
      page: Array(matching[start..<end])
    )
  }

  func blockNextGet(identityToken: String) {
    blockedIdentityToken = identityToken
    blockedGetHasStarted = false
  }

  func waitUntilGetIsBlocked() async {
    while !blockedGetHasStarted {
      await Task.yield()
    }
  }

  func releaseBlockedGet() {
    blockedGetContinuation?.resume()
    blockedGetContinuation = nil
  }

  func getEncryptedProductSyncPayloads(
    session: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    if blockedIdentityToken == session.identityToken {
      blockedIdentityToken = nil
      blockedGetHasStarted = true
      await withCheckedContinuation { continuation in
        blockedGetContinuation = continuation
      }
    }
    return payloadIdentifiers.compactMap { payloads[$0] }
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    if let failingPutPrefix, payloadIdentifier.hasPrefix(failingPutPrefix) {
      self.failingPutPrefix = nil
      throw PinSyncTestTransportError.unavailable
    }
    let existing = payloads[payloadIdentifier]
    guard existing?.updatedAt == expectedUpdatedAt else {
      return try requireValue(existing)
    }
    return write(payloadIdentifier: payloadIdentifier, encryptedPayload: encryptedPayload)
  }

  private func write(
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload
  ) -> EncryptedProductSyncPayload {
    updatedAt += 1
    let payload = EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: updatedAt
    )
    payloads[payloadIdentifier] = payload
    return payload
  }
}

private actor RecordingPinSessionService: PinSyncing {
  private var sessions: [ProductAccountSessionSnapshot] = []

  func loadPinnedThreadIds(
    session _: ProductAccountSessionSnapshot
  ) async throws -> Set<StableThreadIdentity> {
    []
  }

  func setPinned(
    _: Bool,
    threadId _: StableThreadIdentity,
    anchorMessageId _: StableProviderMessageIdentity,
    session: ProductAccountSessionSnapshot
  ) async throws {
    sessions.append(session)
  }

  func recordedSessions() -> [ProductAccountSessionSnapshot] {
    sessions
  }
}
