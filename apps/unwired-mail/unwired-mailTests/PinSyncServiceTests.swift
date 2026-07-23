import Foundation
import XCTest

@testable import unwired_mail

// swiftlint:disable file_length

final class PinSyncServiceTests: XCTestCase {
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

    XCTAssertEqual(secondDevicePins, [Self.messageId])
    let firstPayload = await services.transport.firstPayload()
    let storedPayload = try XCTUnwrap(firstPayload)
    XCTAssertFalse(storedPayload.payloadIdentifier.contains(Self.messageId.providerMessageId))
    XCTAssertFalse(
      storedPayload.encryptedPayload.ciphertextBase64.contains(Self.messageId.providerMessageId)
    )
    XCTAssertFalse(
      storedPayload.encryptedPayload.ciphertextBase64.contains(
        Self.messageId.connectionId.providerMailboxIdentity.value
      )
    )
  }

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
    XCTAssertEqual(pins, [otherConnectionMessageId])
    let payloadCount = await services.transport.payloadCount()
    XCTAssertEqual(payloadCount, 2)
  }

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
      XCTFail("Expected the older Pin to lose to the newer Unpin")
    } catch PinSyncError.concurrentModification {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let pins = try await services.firstDevice.loadPinnedMessageIds(session: firstDeviceSession)
    XCTAssertEqual(pins, [])
  }

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
      stableProviderMessageId: "gmail:gmail-user-001:message-001"
    )

    try bodyCache.removeMessageBody(
      productAccountId: firstDeviceSession.productAccountId,
      stableProviderMessageId: "gmail:gmail-user-001:message-001"
    )

    XCTAssertNil(
      try bodyCache.loadMessageBody(
        productAccountId: firstDeviceSession.productAccountId,
        stableProviderMessageId: "gmail:gmail-user-001:message-001"
      )
    )
    let pins = try await services.secondDevice.loadPinnedMessageIds(session: secondDeviceSession)
    XCTAssertEqual(pins, [Self.messageId])
  }

  @MainActor
  func testPinInteractionUpdatesLocallyBeforeProductSyncCompletes() async {
    let service = DelayedPinSyncService()
    let viewModel = PinViewModel(service: service, session: firstDeviceSession)

    let update = Task {
      await viewModel.togglePin(Self.messageId)
    }
    await service.waitUntilSaveStarted()

    XCTAssertEqual(viewModel.pinnedMessageIds, [Self.messageId])
    XCTAssertTrue(viewModel.isUpdating(Self.messageId))

    await service.releaseSave()
    await update.value

    XCTAssertEqual(viewModel.pinnedMessageIds, [Self.messageId])
    XCTAssertFalse(viewModel.isUpdating(Self.messageId))
    XCTAssertNil(viewModel.errorMessage)
  }

  @MainActor
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
      selection: MailShellSelectionModel()
    )

    await reader.togglePin(Self.messageId)

    let providerMutationCount = await providerActions.mutationCount()
    XCTAssertEqual(providerMutationCount, 0)
    XCTAssertEqual(pinViewModel.pinnedMessageIds, [Self.messageId])
  }

  @MainActor
  func testPinInteractionRollsBackWhenProductSyncFails() async {
    let viewModel = PinViewModel(
      service: FailingPinSyncService(),
      session: firstDeviceSession
    )

    await viewModel.togglePin(Self.messageId)

    XCTAssertTrue(viewModel.pinnedMessageIds.isEmpty)
    XCTAssertEqual(viewModel.errorMessage, PinSyncError.concurrentModification.localizedDescription)
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
        keyMaterialStore: firstStore,
        nowMilliseconds: firstDeviceNowMilliseconds,
        transport: transport
      ),
      secondDevice: PinSyncService(
        keyMaterialStore: secondStore,
        nowMilliseconds: secondDeviceNowMilliseconds,
        transport: transport
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
    XCTAssertEqual(firstDevicePins, [Self.messageId])
    try await services.firstDevice.setPinned(
      false,
      messageId: Self.messageId,
      session: firstDeviceSession
    )

    let secondDevicePins = try await services.secondDevice.loadPinnedMessageIds(
      session: secondDeviceSession
    )
    XCTAssertEqual(secondDevicePins, [])
  }

  @MainActor
  func testPinLoadPreservesAnInFlightOptimisticToggle() async {
    let service = DelayedPinSyncService()
    let viewModel = PinViewModel(service: service, session: firstDeviceSession)

    let update = Task {
      await viewModel.togglePin(Self.messageId)
    }
    await service.waitUntilSaveStarted()
    await viewModel.load()

    XCTAssertEqual(viewModel.pinnedMessageIds, [Self.messageId])

    await service.releaseSave()
    await update.value
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

private actor PinSyncTestTransport: ProductSyncPayloadTransport {
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
    identityToken _: String,
    payloadIdentifierPrefix: String?
  ) async throws -> [EncryptedProductSyncPayload] {
    payloads.values
      .filter { payload in
        guard let payloadIdentifierPrefix else { return true }
        return payload.payloadIdentifier.hasPrefix(payloadIdentifierPrefix)
      }
      .sorted { $0.payloadIdentifier < $1.payloadIdentifier }
  }

  func getEncryptedProductSyncPayload(
    identityToken: String,
    payloadIdentifier: String
  ) async throws -> EncryptedProductSyncPayload? {
    if blockedIdentityToken == identityToken {
      blockedIdentityToken = nil
      blockedGetHasStarted = true
      await withCheckedContinuation { continuation in
        blockedGetContinuation = continuation
      }
    }
    return payloads[payloadIdentifier]
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
    identityToken _: String,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    payloadIdentifiers.compactMap { payloads[$0] }
  }

  func putEncryptedProductSyncPayload(
    identityToken _: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload {
    write(payloadIdentifier: payloadIdentifier, encryptedPayload: encryptedPayload)
  }

  func putEncryptedProductSyncPayloadIfAbsent(
    identityToken _: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload {
    payloads[payloadIdentifier]
      ?? write(payloadIdentifier: payloadIdentifier, encryptedPayload: encryptedPayload)
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    identityToken _: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId _: String,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    let existing = payloads[payloadIdentifier]
    guard existing?.updatedAt == expectedUpdatedAt else {
      return try XCTUnwrap(existing)
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
