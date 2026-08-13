import Foundation
import Testing

@testable import unwired_mail

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
  private var list = BlockedSenderList.empty
  private var throwsOnApply: Bool
  private var mutationCount = 0

  init(throwsOnApply: Bool) {
    self.throwsOnApply = throwsOnApply
  }

  func apply(
    _ mutations: [BlockedSenderMutation],
    session _: ProductAccountSessionSnapshot
  ) async throws -> BlockedSenderList {
    if throwsOnApply { throw URLError(.notConnectedToInternet) }
    mutationCount += mutations.count
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
    mutationCount
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

  func perform(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    actions.append(action)
    messageIds.append(contentsOf: messages.map(\.providerMessageId))
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
