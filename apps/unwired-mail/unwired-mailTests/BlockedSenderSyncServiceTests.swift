import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
@Suite(.serialized)
@MainActor
struct BlockedSenderSyncServiceTests {
  @Test
  func normalizesExactAddressesWithoutInferringAliases() throws {
    #expect(
      NormalizedSenderAddress(" Sender <PERSON@Example.com> ")?.rawValue == "person@example.com")
    #expect(
      NormalizedSenderAddress("person+news@example.com")?.rawValue == "person+news@example.com")
    #expect(
      NormalizedSenderAddress("person@example.com")
        != NormalizedSenderAddress("person+news@example.com"))
    #expect(NormalizedSenderAddress("not-an-address") == nil)
    #expect(NormalizedSenderAddress("person@@example.com") == nil)
    #expect(NormalizedSenderAddress("@example.com") == nil)
    #expect(NormalizedSenderAddress("person@") == nil)
    #expect(NormalizedSenderAddress("per son@example.com") == nil)
    #expect(NormalizedSenderAddress("person@example.com,other@example.com") == nil)
    #expect(NormalizedSenderAddress("person\u{0}@example.com") == nil)
    #expect(NormalizedSenderAddress(nil) == nil)
  }

  @Test
  func mutationsConvergeByTimestampAndTrustedDevice() throws {
    let address = try #require(NormalizedSenderAddress("sender@example.com"))
    let list = BlockedSenderList(entries: [
      mutation(address, at: 20, device: "device-a", blocked: false),
      mutation(address, at: 10, device: "device-z", blocked: true),
      mutation(address, at: 20, device: "device-b", blocked: true),
    ])

    #expect(list.blockedAddresses == [address])
    #expect(list.entries.count == 1)
    #expect(list.entries.first?.changedByTrustedDeviceId == "device-b")
  }

  @Test
  func storeKeepsOfflineMutationAndReplaysIt() async throws {
    let localStore = InMemoryBlockedSenderLocalStateStore()
    let syncService = ControllableBlockedSenderSyncService(throwsOnApply: true)
    let store = BlockedSenderStore(
      session: Self.session,
      syncService: syncService,
      localStateStore: localStore,
      automaticallySynchronizes: false,
      nowMilliseconds: { 100 }
    )

    #expect(store.block("Sender <person@example.com>"))
    await store.synchronize()
    #expect(store.hasPendingChanges)
    #expect(store.isBlocked("person@example.com"))

    await syncService.setThrowsOnApply(false)
    await store.synchronize()

    #expect(!store.hasPendingChanges)
    #expect(store.isBlocked("PERSON@example.com"))
    #expect(await syncService.appliedMutationCount() == 1)
  }

  @Test
  func sameDeviceMutationsRemainOrderedWithinOneMillisecond() throws {
    let store = BlockedSenderStore(
      session: Self.session,
      syncService: ControllableBlockedSenderSyncService(throwsOnApply: false),
      localStateStore: InMemoryBlockedSenderLocalStateStore(),
      automaticallySynchronizes: false,
      nowMilliseconds: { 100 }
    )

    #expect(store.block("person@example.com"))
    let address = try #require(NormalizedSenderAddress("person@example.com"))
    store.unblock(address)

    #expect(!store.isBlocked("person@example.com"))
  }

  @Test
  func localMutationFollowsFutureDatedRemoteMutation() async throws {
    let address = try #require(NormalizedSenderAddress("person@example.com"))
    let remoteMutation = mutation(address, at: 1_000, device: "remote-device", blocked: true)
    let syncService = ControllableBlockedSenderSyncService(
      list: BlockedSenderList(entries: [remoteMutation]),
      throwsOnApply: false
    )
    let store = BlockedSenderStore(
      session: Self.session,
      syncService: syncService,
      localStateStore: InMemoryBlockedSenderLocalStateStore(),
      automaticallySynchronizes: false,
      nowMilliseconds: { 100 }
    )

    await store.synchronize()
    store.unblock(address)
    await store.synchronize()

    let appliedMutation = await syncService.lastAppliedMutation()
    let localMutation = try #require(appliedMutation)
    #expect(localMutation.changedAtMilliseconds > remoteMutation.changedAtMilliseconds)
  }

  @Test
  func retiredStoreDoesNotApplySuspendedSynchronization() async throws {
    let syncService = SuspendedBlockedSenderSyncService()
    let store = BlockedSenderStore(
      session: Self.session,
      syncService: syncService,
      localStateStore: InMemoryBlockedSenderLocalStateStore(),
      automaticallySynchronizes: false,
      nowMilliseconds: { 100 }
    )
    #expect(store.block("person@example.com"))

    let synchronization = Task { await store.synchronize() }
    await syncService.waitUntilApplyStarts()
    store.retire()
    #expect(!store.isSynchronizing)
    await syncService.finishApply()
    await synchronization.value

    #expect(store.isBlocked("person@example.com"))
    #expect(store.hasPendingChanges)
  }

  @Test
  func enforcerTrashesOnlyNewBlockedMessagesAndSuppressesTheirNotifications() async throws {
    let blockedAddress = try #require(NormalizedSenderAddress("blocked@example.com"))
    let blockedList = BlockedSenderList(entries: [
      mutation(blockedAddress, at: 1, device: "device-a", blocked: true)
    ])
    let actionService = RecordingBlockedSenderActionService()
    let enforcer = BlockedSenderEnforcementService(
      actionService: actionService,
      localStateStore: InMemoryBlockedSenderLocalStateStore(),
      profileResolver: FixedBlockedSenderProfileResolver(),
      receiptStore: InMemoryBlockedSenderReceiptStore(),
      syncServiceFactory: { _ in FixedBlockedSenderSyncService(list: blockedList) }
    )
    let existingBlocked = Self.message(id: "existing", from: "blocked@example.com")
    let newBlocked = Self.message(id: "blocked-new", from: "Blocked <BLOCKED@example.com>")
    let newAllowed = Self.message(id: "allowed-new", from: "allowed@example.com")
    let messages = [existingBlocked, newBlocked, newAllowed]
    let result = MailboxMetadataSyncResult(
      hasUnlistedNewMessages: false,
      messages: messages,
      newMessageIds: [newBlocked.providerMessageId, newAllowed.providerMessageId],
      providerCursorIsExpired: false,
      threads: MailboxThread.group(messages)
    )

    let enforced = await enforcer.enforce(
      result,
      connection: Self.connection,
      session: Self.session
    )
    _ = await enforcer.enforce(result, connection: Self.connection, session: Self.session)

    #expect(enforced.newMessageIds == [newAllowed.providerMessageId])
    #expect(enforced.messages == result.messages)
    #expect(await actionService.recordedActions() == [.delete])
    #expect(await actionService.recordedMessageIds() == [newBlocked.providerMessageId])
  }

  @Test
  func enforcerSuppressesWithoutCapabilityAndRetriesActionFailures() async throws {
    let blockedAddress = try #require(NormalizedSenderAddress("blocked@example.com"))
    let blockedList = BlockedSenderList(entries: [
      mutation(blockedAddress, at: 1, device: "device-a", blocked: true)
    ])
    let message = Self.message(id: "blocked-new", from: "blocked@example.com")
    let result = MailboxMetadataSyncResult(
      hasUnlistedNewMessages: false,
      messages: [message],
      newMessageIds: [message.providerMessageId],
      providerCursorIsExpired: false,
      threads: MailboxThread.group([message])
    )

    for connection in [
      Self.makeConnection(authorizationState: .required),
      Self.makeConnection(capabilities: .imapRead),
    ] {
      let actionService = RecordingBlockedSenderActionService()
      let enforcer = Self.enforcer(
        actionService: actionService,
        blockedList: blockedList
      )
      let enforced = await enforcer.enforce(result, connection: connection, session: Self.session)
      #expect(enforced.newMessageIds == [])
      #expect(await actionService.recordedActions().isEmpty)
    }

    let failingActionService = RecordingBlockedSenderActionService(throwsOnPerform: true)
    let failingEnforcer = Self.enforcer(
      actionService: failingActionService,
      blockedList: blockedList
    )
    let firstFailure = await failingEnforcer.enforce(
      result,
      connection: Self.connection,
      session: Self.session
    )
    let secondFailure = await failingEnforcer.enforce(
      result,
      connection: Self.connection,
      session: Self.session
    )
    #expect(firstFailure.newMessageIds == result.newMessageIds)
    #expect(secondFailure.newMessageIds == result.newMessageIds)
    #expect(await failingActionService.recordedActions() == [.delete, .delete])
  }

  private static let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user",
    identityToken: "identity-token",
    productAccountId: "product-account",
    trustedDeviceId: "trusted-device"
  )

  private static let connectionId = MailboxConnectionId(
    providerMailboxIdentity: StableProviderMailboxIdentity(
      providerId: .gmail,
      value: "gmail-user"
    )
  )

  private static let connection = MailboxConnection(
    authorizationState: .authorized,
    capabilities: .gmail,
    connectedAt: 1,
    displayName: "person@example.com",
    id: connectionId,
    lastVerifiedAt: 1,
    productAccountId: ProductAccountId(session.productAccountId),
    trustedDeviceId: session.trustedDeviceId,
    updatedAt: 1
  )

  private static func makeConnection(
    authorizationState: MailboxAuthorizationState = .authorized,
    capabilities: MailboxConnectionCapabilities = .gmail
  ) -> MailboxConnection {
    MailboxConnection(
      authorizationState: authorizationState,
      capabilities: capabilities,
      connectedAt: 1,
      displayName: "person@example.com",
      id: connectionId,
      lastVerifiedAt: 1,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1
    )
  }

  private static func enforcer(
    actionService: RecordingBlockedSenderActionService,
    blockedList: BlockedSenderList
  ) -> BlockedSenderEnforcementService {
    BlockedSenderEnforcementService(
      actionService: actionService,
      localStateStore: InMemoryBlockedSenderLocalStateStore(),
      profileResolver: FixedBlockedSenderProfileResolver(),
      receiptStore: InMemoryBlockedSenderReceiptStore(),
      syncServiceFactory: { _ in FixedBlockedSenderSyncService(list: blockedList) }
    )
  }

  private static func message(id: String, from: String) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: nil,
      connectionId: connectionId,
      from: from,
      isHistorical: false,
      providerInternalDateMilliseconds: 1,
      providerMessageId: id,
      providerStateIds: ["INBOX", "UNREAD"],
      providerThreadId: "thread-\(id)",
      recipientHeaders: nil,
      replyTo: nil,
      rfcMessageId: nil,
      snippet: "Preview",
      subject: "Subject"
    )
  }

  private func mutation(
    _ address: NormalizedSenderAddress,
    at milliseconds: Int64,
    device: String,
    blocked: Bool
  ) -> BlockedSenderMutation {
    BlockedSenderMutation(
      address: address,
      changedAtMilliseconds: milliseconds,
      changedByTrustedDeviceId: device,
      isBlocked: blocked
    )
  }
}

private actor ControllableBlockedSenderSyncService: BlockedSenderSyncing {
  private var list: BlockedSenderList
  private var throwsOnApply: Bool
  private var appliedMutations: [BlockedSenderMutation] = []

  init(list: BlockedSenderList = .empty, throwsOnApply: Bool) {
    self.list = list
    self.throwsOnApply = throwsOnApply
  }

  func apply(
    _ mutations: [BlockedSenderMutation],
    session _: ProductAccountSessionSnapshot
  ) async throws -> BlockedSenderList {
    if throwsOnApply { throw URLError(.notConnectedToInternet) }
    appliedMutations.append(contentsOf: mutations)
    list = list.applying(mutations)
    return list
  }

  func load(session _: ProductAccountSessionSnapshot) async throws -> BlockedSenderList? {
    list
  }

  func setThrowsOnApply(_ value: Bool) {
    throwsOnApply = value
  }

  func appliedMutationCount() -> Int {
    appliedMutations.count
  }

  func lastAppliedMutation() -> BlockedSenderMutation? {
    appliedMutations.last
  }
}

private actor SuspendedBlockedSenderSyncService: BlockedSenderSyncing {
  private var applyContinuation: CheckedContinuation<Void, Never>?
  private var applyStarted = false

  func apply(
    _: [BlockedSenderMutation],
    session _: ProductAccountSessionSnapshot
  ) async throws -> BlockedSenderList {
    applyStarted = true
    await withCheckedContinuation { applyContinuation = $0 }
    return .empty
  }

  func load(session _: ProductAccountSessionSnapshot) async throws -> BlockedSenderList? {
    .empty
  }

  func waitUntilApplyStarts() async {
    while !applyStarted { await Task.yield() }
  }

  func finishApply() {
    applyContinuation?.resume()
    applyContinuation = nil
  }
}

private struct FixedBlockedSenderSyncService: BlockedSenderSyncing {
  let list: BlockedSenderList

  func apply(
    _: [BlockedSenderMutation],
    session _: ProductAccountSessionSnapshot
  ) async throws -> BlockedSenderList {
    list
  }

  func load(session _: ProductAccountSessionSnapshot) async throws -> BlockedSenderList? {
    list
  }
}

private final class InMemoryBlockedSenderLocalStateStore: BlockedSenderLocalStatePersisting {
  private var states: [String: BlockedSenderLocalState] = [:]

  func clear(productAccountId: String) throws {
    states = states.filter { !$0.key.hasPrefix(productAccountId + ".") }
  }

  func load(
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws -> BlockedSenderLocalState? {
    states[key(productAccountId, recordScope)]
  }

  func save(
    _ state: BlockedSenderLocalState,
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws {
    states[key(productAccountId, recordScope)] = state
  }

  private func key(_ productAccountId: String, _ recordScope: MailProfileRecordScope) -> String {
    productAccountId + "." + (recordScope.namespace ?? "legacy")
  }
}

private struct FixedBlockedSenderProfileResolver: BlockedSenderProfileResolving {
  func recordScope(
    for _: MailboxConnectionId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailProfileRecordScope {
    .legacyProductAccount
  }
}

private final class InMemoryBlockedSenderReceiptStore:
  BlockedSenderReceiptPersisting
{
  private var receipts: [String: Set<StableProviderMessageIdentity>] = [:]

  func clear(productAccountId: String) {
    receipts[productAccountId] = nil
  }

  func contains(
    _ messageId: StableProviderMessageIdentity,
    productAccountId: String
  ) -> Bool {
    receipts[productAccountId, default: []].contains(messageId)
  }

  func insert(
    _ messageIds: [StableProviderMessageIdentity],
    productAccountId: String
  ) {
    receipts[productAccountId, default: []].formUnion(messageIds)
  }
}

private actor RecordingBlockedSenderActionService: MailboxProviderMailActing {
  private var actions: [ProviderMailAction] = []
  private var messageIds: [String] = []
  private let throwsOnPerform: Bool

  init(throwsOnPerform: Bool = false) {
    self.throwsOnPerform = throwsOnPerform
  }

  func perform(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    actions.append(action)
    messageIds.append(contentsOf: messages.map(\.providerMessageId))
    if throwsOnPerform { throw URLError(.cannotConnectToHost) }
  }

  func send(
    _: OutgoingMessage,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func recordedActions() -> [ProviderMailAction] {
    actions
  }

  func recordedMessageIds() -> [String] {
    messageIds
  }
}
