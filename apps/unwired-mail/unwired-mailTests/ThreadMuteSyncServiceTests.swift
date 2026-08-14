import Foundation
import Testing

@testable import unwired_mail

@Suite(.serialized)
final class ThreadMuteSyncServiceTests {
  private let firstSession = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "first-device-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )
  private let secondSession = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "second-device-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-002"
  )

  @Test
  func testMuteSynchronizesAcrossDevicesWithoutExposingThreadIdentity() async throws {
    let services = try makeServices()

    try await services.first.setMuted(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      profileId: Self.profileId,
      session: firstSession
    )

    let snapshot = try await services.second.load(
      profileId: Self.profileId,
      session: secondSession
    )
    #expect(snapshot.mutedThreadIds == [Self.threadId])
    let firstPayload = await services.transport.firstPayload()
    let stored = try requireValue(firstPayload)
    #expect(!(stored.payloadIdentifier.contains(Self.threadId.providerThreadId)))
    #expect(!(stored.encryptedPayload.ciphertextBase64.contains(Self.threadId.providerThreadId)))
  }

  @Test
  func testMuteIsProfileScopedAndNewRepliesDoNotUnmuteThread() async throws {
    let services = try makeServices()
    let otherProfileId = MailProfileId(rawValue: "profile-personal")
    try await services.first.setMuted(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      profileId: Self.profileId,
      session: firstSession
    )

    let sameThreadAfterNewReply = try await services.second.reconcile(
      with: [Self.message(messageId: "message-new", threadId: Self.threadId.providerThreadId)],
      profileId: Self.profileId,
      session: secondSession
    )
    let otherProfile = try await services.second.load(
      profileId: otherProfileId,
      session: secondSession
    )

    #expect(sameThreadAfterNewReply.mutedThreadIds == [Self.threadId])
    #expect(otherProfile.mutedThreadIds.isEmpty)
  }

  @Test
  func testOfflineMutationPersistsLocallyAndReplaysAfterReconnect() async throws {
    let services = try makeServices()
    await services.transport.failNextPut(prefix: ThreadMuteSyncService.payloadIdentifierPrefix)

    try await services.first.setMuted(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      profileId: Self.profileId,
      session: firstSession
    )
    let localSnapshot = try await services.first.load(
      profileId: Self.profileId,
      session: firstSession
    )
    let synchronizedSnapshot = try await services.second.load(
      profileId: Self.profileId,
      session: secondSession
    )

    #expect(localSnapshot.mutedThreadIds == [Self.threadId])
    #expect(synchronizedSnapshot.mutedThreadIds == [Self.threadId])
  }

  @Test
  func testConcurrentMuteAndUnmuteConvergeByTrustedDeviceTieBreaker() async throws {
    let services = try makeServices(nowMilliseconds: { 100 })
    try await services.first.setMuted(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      profileId: Self.profileId,
      session: firstSession
    )
    try await services.second.setMuted(
      false,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      profileId: Self.profileId,
      session: secondSession
    )

    let snapshot = try await services.first.load(
      profileId: Self.profileId,
      session: firstSession
    )
    #expect(snapshot.mutedThreadIds.isEmpty)
  }

  @Test
  func testRethreadingMovesMuteAndOldIdentityCanUnmuteResolvedThread() async throws {
    let services = try makeServices()
    let rethreaded = StableThreadIdentity(
      connectionId: Self.threadId.connectionId,
      providerThreadId: "thread-rebuilt"
    )
    try await services.first.setMuted(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      profileId: Self.profileId,
      session: firstSession
    )

    let repaired = try await services.first.reconcile(
      with: [
        Self.message(
          messageId: Self.messageId.providerMessageId, threadId: rethreaded.providerThreadId)
      ],
      profileId: Self.profileId,
      session: firstSession
    )
    try await services.second.setMuted(
      false,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      profileId: Self.profileId,
      session: secondSession
    )
    let unmuted = try await services.first.load(
      profileId: Self.profileId,
      session: firstSession
    )

    #expect(repaired.mutedThreadIds == [rethreaded])
    #expect(unmuted.mutedThreadIds.isEmpty)
  }

  @Test
  func testAuthoritativeMuteUsesPendingMutationStoredUnderRedirectTarget() async throws {
    let services = try makeServices()
    let rethreaded = StableThreadIdentity(
      connectionId: Self.threadId.connectionId,
      providerThreadId: "thread-rebuilt"
    )
    try await services.first.setMuted(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      profileId: Self.profileId,
      session: firstSession
    )
    _ = try await services.first.reconcile(
      with: [
        Self.message(
          messageId: Self.messageId.providerMessageId,
          threadId: rethreaded.providerThreadId
        )
      ],
      profileId: Self.profileId,
      session: firstSession
    )
    try await services.first.setMuted(
      false,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      profileId: Self.profileId,
      session: firstSession
    )
    await services.transport.failNextPut(prefix: ThreadMuteSyncService.payloadIdentifierPrefix)
    try await services.first.setMuted(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      profileId: Self.profileId,
      session: firstSession
    )

    let isMuted = try await services.first.isMutedAuthoritatively(
      Self.threadId,
      profileId: Self.profileId,
      session: firstSession
    )

    #expect(isMuted)
  }

  @Test
  func testAuthoritativeMuteFailsClosedWhenProductSyncIsUnavailable() async throws {
    let services = try makeServices()
    await services.transport.failNextList(
      prefix: ThreadMuteSyncService.redirectIdentifierPrefix
    )

    await #expect(throws: ThreadMuteTestTransportError.self) {
      try await services.first.isMutedAuthoritatively(
        Self.threadId,
        profileId: Self.profileId,
        session: firstSession
      )
    }
  }

  @Test
  func testAuthoritativeMuteReturnsFalseWhenNoRecordExists() async throws {
    let services = try makeServices()

    let isMuted = try await services.first.isMutedAuthoritatively(
      Self.threadId,
      profileId: Self.profileId,
      session: firstSession
    )

    #expect(!isMuted)
  }

  @Test
  func testTransientBoundaryFailureRetainsPendingMute() async throws {
    let services = try makeServices()
    await services.transport.failNextPutWithRetryLimit()

    try await services.first.setMuted(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      profileId: Self.profileId,
      session: firstSession
    )
    let replayed = try await services.first.load(
      profileId: Self.profileId,
      session: firstSession
    )

    #expect(replayed.mutedThreadIds == [Self.threadId])
  }

  @MainActor
  @Test
  func testLoadPreservesAnInFlightOptimisticMute() async throws {
    let service = DelayedThreadMuteSyncService()
    let viewModel = ThreadMuteViewModel(service: service, session: firstSession)
    let thread = try requireValue(
      MailboxThread.group([Self.message(messageId: "message-001", threadId: "thread-001")])
        .first
    )

    let update = Task { await viewModel.toggleMute(thread) }
    await service.waitUntilSaveStarted()
    await viewModel.load()

    #expect(viewModel.mutedThreadIds == [Self.threadId])

    await service.releaseSave()
    await update.value
  }

  @Test
  func testSettingsItemKeepsMuteInspectableAndUnmuteAccessible() {
    let item = MutedThreadSettingsItem(
      id: Self.threadId,
      source: "Work Account",
      subject: "Quarterly planning"
    )

    #expect(item.unmuteAccessibilityLabel == "Unmute Quarterly planning")
  }

  @Test
  func testUnknownFutureVersionCoexistsWithoutChangingCurrentMuteState() async throws {
    let services = try makeServices()
    let futureIdentifier = "thread-mute-v2-future-client-record"
    await services.transport.insertOpaquePayload(identifier: futureIdentifier)

    try await services.first.setMuted(
      true,
      threadId: Self.threadId,
      anchorMessageId: Self.messageId,
      profileId: Self.profileId,
      session: firstSession
    )
    let snapshot = try await services.second.load(
      profileId: Self.profileId,
      session: secondSession
    )

    #expect(snapshot.mutedThreadIds == [Self.threadId])
    #expect(await services.transport.payloadCount(prefix: "thread-mute-v2-") == 1)
  }

  private func makeServices(
    nowMilliseconds: @escaping @Sendable () -> Int64 = { 1_781_200_000_001 }
  ) throws -> Services {
    let keyMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 7, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 8, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let firstKeys = InMemoryProductSyncKeyMaterialStore()
    let secondKeys = InMemoryProductSyncKeyMaterialStore()
    try firstKeys.save(keyMaterial, productAccountId: firstSession.productAccountId)
    try secondKeys.save(keyMaterial, productAccountId: secondSession.productAccountId)
    let transport = ThreadMuteTestTransport()
    return Services(
      first: ThreadMuteSyncService(
        nowMilliseconds: nowMilliseconds,
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: firstKeys,
          transport: transport
        ),
        localStateStore: InMemoryThreadMuteLocalStateStore()
      ),
      second: ThreadMuteSyncService(
        nowMilliseconds: nowMilliseconds,
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: secondKeys,
          transport: transport
        ),
        localStateStore: InMemoryThreadMuteLocalStateStore()
      ),
      transport: transport
    )
  }

  private struct Services {
    let first: ThreadMuteSyncService
    let second: ThreadMuteSyncService
    let transport: ThreadMuteTestTransport
  }

  private static let profileId = MailProfileId(rawValue: "profile-work")
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

  private static func message(messageId: String, threadId: String) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: nil,
      connectionId: Self.messageId.connectionId,
      from: "sender@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: 1,
      providerMessageId: messageId,
      providerStateIds: ["INBOX"],
      providerThreadId: threadId,
      recipientHeaders: nil,
      replyTo: nil,
      rfcMessageId: nil,
      snippet: "Preview",
      subject: "Subject"
    )
  }
}

private final class InMemoryThreadMuteLocalStateStore: ThreadMuteLocalStatePersisting {
  private var states: [String: ThreadMuteLocalState] = [:]

  func clear(productAccountId: String) throws {
    states[productAccountId] = nil
  }

  func load(productAccountId: String) throws -> ThreadMuteLocalState? {
    states[productAccountId]
  }

  func save(_ state: ThreadMuteLocalState, productAccountId: String) throws {
    states[productAccountId] = state
  }
}

private enum ThreadMuteTestTransportError: Error {
  case unavailable
}

private actor ThreadMuteTestTransport: ProductSyncRecordTransport {
  private var failingListPrefix: String?
  private var failingPutPrefix: String?
  private var failsNextPutWithRetryLimit = false
  private var payloads: [String: EncryptedProductSyncPayload] = [:]
  private var updatedAt: Int64 = 1_781_200_000_000

  func failNextPut(prefix: String) {
    failingPutPrefix = prefix
  }

  func failNextPutWithRetryLimit() {
    failsNextPutWithRetryLimit = true
  }

  func failNextList(prefix: String) {
    failingListPrefix = prefix
  }

  func firstPayload() -> EncryptedProductSyncPayload? {
    payloads.values.first
  }

  func insertOpaquePayload(identifier: String) {
    updatedAt += 1
    payloads[identifier] = EncryptedProductSyncPayload(
      encryptedPayload: ProductSyncEncryptedPayload(
        algorithm: ProductSyncEncryptedPayload.algorithmName,
        ciphertextBase64: "future-ciphertext",
        keyVersion: 2,
        nonceBase64: "future-nonce",
        schemaVersion: 2,
        tagBase64: "future-tag"
      ),
      payloadIdentifier: identifier,
      updatedAt: updatedAt
    )
  }

  func payloadCount(prefix: String) -> Int {
    payloads.keys.count { $0.hasPrefix(prefix) }
  }

  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor: String?,
    limit: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    if let failingListPrefix, payloadIdentifierPrefix.contains(failingListPrefix) {
      self.failingListPrefix = nil
      throw ThreadMuteTestTransportError.unavailable
    }
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

  func getEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    payloadIdentifiers.compactMap { payloads[$0] }
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    if failsNextPutWithRetryLimit {
      failsNextPutWithRetryLimit = false
      throw ProductSyncRecordBoundaryError.retryLimitExceeded
    }
    if let failingPutPrefix, payloadIdentifier.contains(failingPutPrefix) {
      self.failingPutPrefix = nil
      throw ThreadMuteTestTransportError.unavailable
    }
    let existing = payloads[payloadIdentifier]
    guard existing?.updatedAt == expectedUpdatedAt else {
      return try requireValue(existing)
    }
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

private actor DelayedThreadMuteSyncService: ThreadMuteSyncing {
  private var saveContinuation: CheckedContinuation<Void, Never>?
  private var saveStarted = false

  func load(
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ThreadMuteSnapshot {
    .empty
  }

  func isMutedAuthoritatively(
    _: StableThreadIdentity,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> Bool {
    false
  }

  func reconcile(
    with _: [MailboxMessageMetadata],
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ThreadMuteSnapshot {
    .empty
  }

  func setMuted(
    _: Bool,
    threadId _: StableThreadIdentity,
    anchorMessageId _: StableProviderMessageIdentity,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws {
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
