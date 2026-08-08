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
      messageId: Self.messageId,
      session: firstDeviceSession
    )
    let secondDevicePins = try await services.secondDevice.loadPinnedMessageIds(
      session: secondDeviceSession
    )

    #expect(secondDevicePins == [Self.messageId])
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
    try await services.firstDevice.setPinned(
      true,
      messageId: Self.messageId,
      session: firstDeviceSession
    )
    try await services.secondDevice.setPinned(
      true,
      messageId: otherConnectionMessageId,
      session: secondDeviceSession
    )

    try await services.firstDevice.setPinned(
      false,
      messageId: Self.messageId,
      session: firstDeviceSession
    )

    let pins = try await services.secondDevice.loadPinnedMessageIds(
      session: secondDeviceSession
    )
    #expect(pins == [otherConnectionMessageId])
    let payloadCount = await services.transport.payloadCount()
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
        messageId: Self.messageId,
        session: firstDeviceSession
      )
    }
    await services.transport.waitUntilGetIsBlocked()

    try await services.secondDevice.setPinned(
      false,
      messageId: Self.messageId,
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
    let pins = try await services.firstDevice.loadPinnedMessageIds(session: firstDeviceSession)
    #expect(pins == [])
  }

  @Test
  func testPinMetadataSurvivesBodyCacheEviction() async throws {
    let services = try makeServices()
    try await services.firstDevice.setPinned(
      true,
      messageId: Self.messageId,
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
    let pins = try await services.secondDevice.loadPinnedMessageIds(session: secondDeviceSession)
    #expect(pins == [Self.messageId])
  }

  @MainActor
  @Test
  func testPinInteractionUpdatesLocallyBeforeProductSyncCompletes() async {
    let service = DelayedPinSyncService()
    let viewModel = PinViewModel(service: service, session: firstDeviceSession)

    let update = Task {
      await viewModel.togglePin(Self.messageId)
    }
    await service.waitUntilSaveStarted()

    #expect(viewModel.pinnedMessageIds == [Self.messageId])
    #expect(viewModel.isUpdating(Self.messageId))

    await service.releaseSave()
    await update.value

    #expect(viewModel.pinnedMessageIds == [Self.messageId])
    #expect(!(viewModel.isUpdating(Self.messageId)))
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

    await viewModel.togglePin(Self.messageId)
    viewModel.updateSession(refreshedSession)
    await viewModel.togglePin(Self.messageId)

    #expect(viewModel.pinnedMessageIds.isEmpty)
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
      selection: MailShellSelectionModel(),
      session: firstDeviceSession
    )

    await reader.togglePin(Self.messageId)

    let providerMutationCount = await providerActions.mutationCount()
    #expect(providerMutationCount == 0)
    #expect(pinViewModel.pinnedMessageIds == [Self.messageId])
  }

  @MainActor
  @Test
  func testAttachmentDownloadDoesNotInvokeProviderAfterRevalidationFails() async {
    let mailboxService = EmptyMailboxService()
    let reader = MailShellConversationReader(
      connections: [],
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

    await viewModel.togglePin(Self.messageId)

    #expect(viewModel.pinnedMessageIds.isEmpty)
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
    return Services(
      firstDevice: PinSyncService(
        nowMilliseconds: firstDeviceNowMilliseconds,
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: firstStore,
          transport: transport
        )
      ),
      secondDevice: PinSyncService(
        nowMilliseconds: secondDeviceNowMilliseconds,
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: secondStore,
          transport: transport
        )
      ),
      transport: transport
    )
  }

  private struct Services {
    let firstDevice: PinSyncService
    let secondDevice: PinSyncService
    let transport: PinSyncTestTransport
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
      messageId: Self.messageId,
      session: secondDeviceSession
    )

    let firstDevicePins = try await services.firstDevice.loadPinnedMessageIds(
      session: firstDeviceSession
    )
    #expect(firstDevicePins == [Self.messageId])
    try await services.firstDevice.setPinned(
      false,
      messageId: Self.messageId,
      session: firstDeviceSession
    )

    let secondDevicePins = try await services.secondDevice.loadPinnedMessageIds(
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
      messageId: Self.messageId,
      session: secondDeviceSession
    )

    try await services.firstDevice.setPinned(
      true,
      messageId: Self.messageId,
      session: firstDeviceSession
    )
    try await services.firstDevice.setPinned(
      false,
      messageId: Self.messageId,
      session: firstDeviceSession
    )

    let secondDevicePins = try await services.secondDevice.loadPinnedMessageIds(
      session: secondDeviceSession
    )
    #expect(secondDevicePins == [])
  }

  @Test
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
            messageId: Self.messageId,
            session: secondDeviceSession
          )
        }
        await services.transport.waitUntilGetIsBlocked()

        try await services.firstDevice.setPinned(
          true,
          messageId: Self.messageId,
          session: firstDeviceSession
        )
        await services.transport.releaseBlockedGet()
        try await unpin.value
      } else {
        await services.transport.blockNextGet(identityToken: firstDeviceSession.identityToken)
        let pin = Task {
          try await services.firstDevice.setPinned(
            true,
            messageId: Self.messageId,
            session: firstDeviceSession
          )
        }
        await services.transport.waitUntilGetIsBlocked()

        try await services.secondDevice.setPinned(
          false,
          messageId: Self.messageId,
          session: secondDeviceSession
        )
        await services.transport.releaseBlockedGet()
        do {
          try await pin.value
          Issue.record("Expected the lower trusted device ID to lose the tie-breaker")
        } catch PinSyncError.concurrentModification {
        }
      }

      let pins = try await services.firstDevice.loadPinnedMessageIds(session: firstDeviceSession)
      #expect(pins == [])
    }
  }

  @MainActor
  @Test
  func testPinLoadPreservesAnInFlightOptimisticToggle() async {
    let service = DelayedPinSyncService()
    let viewModel = PinViewModel(service: service, session: firstDeviceSession)

    let update = Task {
      await viewModel.togglePin(Self.messageId)
    }
    await service.waitUntilSaveStarted()
    await viewModel.load()

    #expect(viewModel.pinnedMessageIds == [Self.messageId])

    await service.releaseSave()
    await update.value
  }

  @MainActor
  @Test
  func testPinLoadDoesNotOverwriteAToggleThatCompletedDuringTheLoad() async {
    let service = StaleLoadingPinSyncService()
    let viewModel = PinViewModel(service: service, session: firstDeviceSession)

    let update = Task {
      await viewModel.togglePin(Self.messageId)
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

    #expect(viewModel.pinnedMessageIds == [Self.messageId])
  }
}

private actor DelayedPinSyncService: PinSyncing {
  private var saveContinuation: CheckedContinuation<Void, Never>?
  private var saveStarted = false

  func loadPinnedMessageIds(
    session _: ProductAccountSessionSnapshot
  ) async throws -> Set<StableProviderMessageIdentity> {
    []
  }

  func setPinned(
    _ isPinned: Bool,
    messageId: StableProviderMessageIdentity,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    _ = isPinned
    _ = messageId
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

  func loadPinnedMessageIds(
    session _: ProductAccountSessionSnapshot
  ) async throws -> Set<StableProviderMessageIdentity> {
    loadStarted = true
    await withCheckedContinuation { continuation in
      loadContinuation = continuation
    }
    return []
  }

  func setPinned(
    _: Bool,
    messageId _: StableProviderMessageIdentity,
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

private struct FailingPinSyncService: PinSyncing {
  func loadPinnedMessageIds(
    session _: ProductAccountSessionSnapshot
  ) async throws -> Set<StableProviderMessageIdentity> {
    []
  }

  func setPinned(
    _ isPinned: Bool,
    messageId: StableProviderMessageIdentity,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    _ = isPinned
    _ = messageId
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

private actor PinSyncTestTransport: ProductSyncRecordTransport {
  private var blockedGetContinuation: CheckedContinuation<Void, Never>?
  private var blockedGetHasStarted = false
  private var blockedIdentityToken: String?
  private var payloads: [String: EncryptedProductSyncPayload] = [:]
  private var updatedAt: Int64 = 1_781_200_000_000

  func firstPayload() -> EncryptedProductSyncPayload? {
    payloads.values.first
  }

  func payloadCount() -> Int {
    payloads.count
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

  func loadPinnedMessageIds(
    session _: ProductAccountSessionSnapshot
  ) async throws -> Set<StableProviderMessageIdentity> {
    []
  }

  func setPinned(
    _: Bool,
    messageId _: StableProviderMessageIdentity,
    session: ProductAccountSessionSnapshot
  ) async throws {
    sessions.append(session)
  }

  func recordedSessions() -> [ProductAccountSessionSnapshot] {
    sessions
  }
}
