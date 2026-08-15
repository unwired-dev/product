import Foundation
import Observation

// swiftlint:disable file_length

struct NormalizedSenderAddress: Codable, Hashable, RawRepresentable, Sendable {
  let rawValue: String

  init?(rawValue: String) {
    guard let normalized = Self.normalize(rawValue) else { return nil }
    self.rawValue = normalized
  }

  init?(_ headerValue: String?) {
    guard let headerValue, let normalized = Self.normalize(headerValue) else { return nil }
    rawValue = normalized
  }

  private static func normalize(_ value: String) -> String? {
    guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let address: String
    if let opening = trimmed.lastIndex(of: "<"),
      let closing = trimmed.lastIndex(of: ">"),
      opening < closing
    {
      address = String(trimmed[trimmed.index(after: opening)..<closing])
    } else {
      address = trimmed
    }
    let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
      .lowercased()
    let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
    guard
      parts.count == 2,
      !parts[0].isEmpty,
      !parts[1].isEmpty,
      !normalized.contains(where: { $0.isWhitespace || "<>,;".contains($0) })
    else {
      return nil
    }
    return normalized
  }
}

struct BlockedSenderMutation: Codable, Equatable, Sendable {
  let address: NormalizedSenderAddress
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let isBlocked: Bool

  func isNewer(than other: Self) -> Bool {
    if changedAtMilliseconds != other.changedAtMilliseconds {
      return changedAtMilliseconds > other.changedAtMilliseconds
    }
    return changedByTrustedDeviceId > other.changedByTrustedDeviceId
  }
}

struct BlockedSenderList: Codable, Equatable, Sendable {
  static let empty = BlockedSenderList(entries: [])
  static let primaryIdentifier = "mail-workflow-preferences:blocked-senders"
  static let supportedSchemaVersion = 1

  let entries: [BlockedSenderMutation]
  let schemaVersion: Int

  init(entries: [BlockedSenderMutation]) {
    self.entries = Self.resolved(entries)
    schemaVersion = Self.supportedSchemaVersion
  }

  var blockedAddresses: [NormalizedSenderAddress] {
    entries.filter(\.isBlocked).map(\.address).sorted { $0.rawValue < $1.rawValue }
  }

  var blockedAddressSet: Set<NormalizedSenderAddress> {
    Set(blockedAddresses)
  }

  func applying(_ mutations: [BlockedSenderMutation]) -> Self {
    BlockedSenderList(entries: entries + mutations)
  }

  private enum CodingKeys: String, CodingKey {
    case entries
    case schemaVersion
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard schemaVersion <= Self.supportedSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Blocked Senders were written by a newer client."
      )
    }
    self.init(entries: try container.decode([BlockedSenderMutation].self, forKey: .entries))
  }

  private static func resolved(_ entries: [BlockedSenderMutation]) -> [BlockedSenderMutation] {
    Dictionary(grouping: entries, by: \.address).compactMap { _, candidates in
      candidates.max { lhs, rhs in rhs.isNewer(than: lhs) }
    }
    .sorted { $0.address.rawValue < $1.address.rawValue }
  }
}

protocol BlockedSenderSyncing {
  func apply(
    _ mutations: [BlockedSenderMutation],
    session: ProductAccountSessionSnapshot
  ) async throws -> BlockedSenderList

  func load(
    session: ProductAccountSessionSnapshot
  ) async throws -> BlockedSenderList?
}

final class BlockedSenderSyncService: BlockedSenderSyncing {
  private let record: ProductSyncSingletonHandle<BlockedSenderList>

  init(
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary(),
    recordScope: MailProfileRecordScope = .legacyProductAccount
  ) {
    record = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: recordScope.productSyncIdentifier(BlockedSenderList.primaryIdentifier),
        cachePolicy: .authoritative
      )
    )
  }

  func apply(
    _ mutations: [BlockedSenderMutation],
    session: ProductAccountSessionSnapshot
  ) async throws -> BlockedSenderList {
    guard !mutations.isEmpty else { return try await load(session: session) ?? .empty }
    let updated = try await record.update(session: session) { current in
      .write((current?.value ?? .empty).applying(mutations))
    }
    return updated?.value ?? .empty
  }

  func load(
    session: ProductAccountSessionSnapshot
  ) async throws -> BlockedSenderList? {
    try await record.read(session: session)?.value
  }
}

struct BlockedSenderLocalState: Codable, Equatable, Sendable {
  var pendingMutations: [BlockedSenderMutation]
  var senders: BlockedSenderList

  static let empty = BlockedSenderLocalState(pendingMutations: [], senders: .empty)
}

protocol BlockedSenderLocalStatePersisting {
  func clear(productAccountId: String) throws
  func load(
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws -> BlockedSenderLocalState?
  func save(
    _ state: BlockedSenderLocalState,
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws
}

struct UserDefaultsBlockedSenderStateStore: BlockedSenderLocalStatePersisting {
  private static let keyPrefix = "mail-workflow-preferences.blocked-senders."
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(productAccountId: String) throws {
    let prefix = Self.keyPrefix + productAccountId + "."
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
      defaults.removeObject(forKey: key)
    }
  }

  func load(
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws -> BlockedSenderLocalState? {
    guard let data = defaults.data(forKey: key(productAccountId, recordScope: recordScope)) else {
      return nil
    }
    do {
      return try JSONDecoder().decode(BlockedSenderLocalState.self, from: data)
    } catch {
      defaults.removeObject(forKey: key(productAccountId, recordScope: recordScope))
      return nil
    }
  }

  func save(
    _ state: BlockedSenderLocalState,
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws {
    defaults.set(
      try JSONEncoder().encode(state),
      forKey: key(productAccountId, recordScope: recordScope)
    )
  }

  private func key(_ productAccountId: String, recordScope: MailProfileRecordScope) -> String {
    Self.keyPrefix + productAccountId + "." + (recordScope.namespace ?? "legacy")
  }
}

@MainActor
@Observable
final class BlockedSenderStore {
  private(set) var errorMessage: String?
  private(set) var isSynchronizing = false
  private(set) var senders: BlockedSenderList

  private let automaticallySynchronizes: Bool
  private var isRetired = false
  private let localStateStore: BlockedSenderLocalStatePersisting
  private var lastChangedAtMilliseconds: Int64 = 0
  private let nowMilliseconds: () -> Int64
  private let recordScope: MailProfileRecordScope
  private var session: ProductAccountSessionSnapshot
  private var sessionGeneration = 0
  private var state: BlockedSenderLocalState
  private let syncService: BlockedSenderSyncing
  private var syncTask: Task<Void, Never>?

  init(
    session: ProductAccountSessionSnapshot,
    recordScope: MailProfileRecordScope = .legacyProductAccount,
    syncService: BlockedSenderSyncing? = nil,
    localStateStore: BlockedSenderLocalStatePersisting = UserDefaultsBlockedSenderStateStore(),
    automaticallySynchronizes: Bool = true,
    nowMilliseconds: @escaping () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }
  ) {
    self.session = session
    self.recordScope = recordScope
    self.syncService = syncService ?? BlockedSenderSyncService(recordScope: recordScope)
    self.localStateStore = localStateStore
    self.automaticallySynchronizes = automaticallySynchronizes
    self.nowMilliseconds = nowMilliseconds
    do {
      let loaded =
        try localStateStore.load(
          productAccountId: session.productAccountId,
          recordScope: recordScope
        ) ?? .empty
      state = loaded
      senders = loaded.senders
      lastChangedAtMilliseconds = loaded.senders.entries.map(\.changedAtMilliseconds).max() ?? 0
    } catch {
      state = .empty
      senders = .empty
      errorMessage = error.localizedDescription
    }
  }

  var blockedAddresses: [NormalizedSenderAddress] {
    senders.blockedAddresses
  }

  var hasPendingChanges: Bool {
    !state.pendingMutations.isEmpty
  }

  func isBlocked(_ headerValue: String?) -> Bool {
    guard let address = NormalizedSenderAddress(headerValue) else { return false }
    return senders.blockedAddressSet.contains(address)
  }

  @discardableResult
  func block(_ headerValue: String?) -> Bool {
    guard let address = NormalizedSenderAddress(headerValue) else { return false }
    append(address: address, isBlocked: true)
    return true
  }

  func unblock(_ address: NormalizedSenderAddress) {
    append(address: address, isBlocked: false)
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    self.session = session
  }

  func retire() {
    isRetired = true
    syncTask?.cancel()
    syncTask = nil
    sessionGeneration += 1
    isSynchronizing = false
  }

  func synchronize() async {
    guard !isRetired, !isSynchronizing else { return }
    isSynchronizing = true
    let generation = sessionGeneration
    defer {
      if generation == sessionGeneration { isSynchronizing = false }
    }
    let pendingCount = state.pendingMutations.count
    let pending = Array(state.pendingMutations.prefix(pendingCount))
    do {
      let synchronized =
        if pending.isEmpty {
          try await syncService.load(session: session) ?? .empty
        } else {
          try await syncService.apply(pending, session: session)
        }
      guard generation == sessionGeneration else { return }
      let currentPrefix = Array(state.pendingMutations.prefix(pendingCount))
      let remaining =
        currentPrefix == pending
        ? Array(state.pendingMutations.dropFirst(pendingCount))
        : state.pendingMutations
      senders = synchronized.applying(remaining)
      state = BlockedSenderLocalState(pendingMutations: remaining, senders: senders)
      lastChangedAtMilliseconds = max(
        lastChangedAtMilliseconds,
        senders.entries.map(\.changedAtMilliseconds).max() ?? 0
      )
      try persist()
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      guard generation == sessionGeneration else { return }
      errorMessage = error.localizedDescription
    }
  }

  private func append(address: NormalizedSenderAddress, isBlocked: Bool) {
    let changedAtMilliseconds = max(nowMilliseconds(), lastChangedAtMilliseconds + 1)
    lastChangedAtMilliseconds = changedAtMilliseconds
    let mutation = BlockedSenderMutation(
      address: address,
      changedAtMilliseconds: changedAtMilliseconds,
      changedByTrustedDeviceId: session.trustedDeviceId,
      isBlocked: isBlocked
    )
    state.pendingMutations.removeAll { $0.address == address }
    state.pendingMutations.append(mutation)
    senders = senders.applying([mutation])
    state.senders = senders
    do {
      try persist()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
    scheduleSyncIfNeeded()
  }

  private func persist() throws {
    try localStateStore.save(
      state,
      productAccountId: session.productAccountId,
      recordScope: recordScope
    )
  }

  private func scheduleSyncIfNeeded() {
    guard !isRetired, automaticallySynchronizes, syncTask == nil else { return }
    syncTask = Task { [weak self] in
      guard let self else { return }
      await synchronize()
      syncTask = nil
      if hasPendingChanges { scheduleSyncIfNeeded() }
    }
  }
}

protocol BlockedSenderProfileResolving {
  func recordScope(
    for connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileRecordScope
}

struct ProductSyncBlockedSenderProfileResolver: BlockedSenderProfileResolving {
  private let service: MailboxConnectionSyncService

  init(service: MailboxConnectionSyncService = MailboxConnectionSyncService()) {
    self.service = service
  }

  func recordScope(
    for connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileRecordScope {
    let snapshot = try await service.loadProfileSnapshot(session: session)
    let profileId = snapshot.assignments[connectionId] ?? snapshot.defaultProfileId
    guard let profile = snapshot.profiles.first(where: { $0.id == profileId }) else {
      throw MailProfileSyncError.profileNotFound
    }
    return profile.recordScope
  }
}

protocol BlockedSenderReceiptPersisting {
  func clear(productAccountId: String)
  func contains(_ messageId: StableProviderMessageIdentity, productAccountId: String) -> Bool
  func insert(_ messageIds: [StableProviderMessageIdentity], productAccountId: String)
}

struct UserDefaultsBlockedSenderReceiptStore:
  BlockedSenderReceiptPersisting
{
  private static let keyPrefix = "blocked-sender-enforcement.receipts."
  private static let maximumReceiptCount = 10_000
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(productAccountId: String) {
    defaults.removeObject(forKey: Self.keyPrefix + productAccountId)
  }

  func contains(
    _ messageId: StableProviderMessageIdentity,
    productAccountId: String
  ) -> Bool {
    load(productAccountId: productAccountId).contains(messageId.rawValue)
  }

  func insert(
    _ messageIds: [StableProviderMessageIdentity],
    productAccountId: String
  ) {
    var receipts = load(productAccountId: productAccountId)
    for messageId in messageIds {
      receipts.removeAll { $0 == messageId.rawValue }
      receipts.append(messageId.rawValue)
    }
    if receipts.count > Self.maximumReceiptCount {
      receipts.removeFirst(receipts.count - Self.maximumReceiptCount)
    }
    defaults.set(receipts, forKey: Self.keyPrefix + productAccountId)
  }

  private func load(productAccountId: String) -> [String] {
    defaults.stringArray(forKey: Self.keyPrefix + productAccountId) ?? []
  }
}

@MainActor
protocol BlockedSenderEnforcing {
  func enforce(
    _ result: MailboxMetadataSyncResult,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> MailboxMetadataSyncResult
}

@MainActor
struct NoopBlockedSenderEnforcer: BlockedSenderEnforcing {
  nonisolated init(_: Void = ()) {}

  func enforce(
    _ result: MailboxMetadataSyncResult,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async -> MailboxMetadataSyncResult {
    result
  }
}

@MainActor
final class BlockedSenderEnforcementService: BlockedSenderEnforcing {
  private let actionService: MailboxProviderMailActing
  private let blockedAddressesProvider:
    ((MailboxConnection, ProductAccountSessionSnapshot) async -> Set<NormalizedSenderAddress>?)?
  private let localStateStore: BlockedSenderLocalStatePersisting
  private let profileResolver: BlockedSenderProfileResolving
  private let receiptStore: BlockedSenderReceiptPersisting
  private let syncServiceFactory: (MailProfileRecordScope) -> BlockedSenderSyncing

  init(
    actionService: MailboxProviderMailActing,
    blockedAddressesProvider:
      ((MailboxConnection, ProductAccountSessionSnapshot) async -> Set<NormalizedSenderAddress>?)? =
      nil,
    localStateStore: BlockedSenderLocalStatePersisting = UserDefaultsBlockedSenderStateStore(),
    profileResolver: BlockedSenderProfileResolving = ProductSyncBlockedSenderProfileResolver(),
    receiptStore: BlockedSenderReceiptPersisting = UserDefaultsBlockedSenderReceiptStore(),
    syncServiceFactory: @escaping (MailProfileRecordScope) -> BlockedSenderSyncing = {
      BlockedSenderSyncService(recordScope: $0)
    }
  ) {
    self.actionService = actionService
    self.blockedAddressesProvider = blockedAddressesProvider
    self.localStateStore = localStateStore
    self.profileResolver = profileResolver
    self.receiptStore = receiptStore
    self.syncServiceFactory = syncServiceFactory
  }

  // swiftlint:disable:next function_body_length
  func enforce(
    _ result: MailboxMetadataSyncResult,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> MailboxMetadataSyncResult {
    guard let newMessageIds = result.newMessageIds, !newMessageIds.isEmpty else { return result }
    guard
      let blockedAddresses = await blockedAddresses(connection: connection, session: session),
      !blockedAddresses.isEmpty
    else {
      return result
    }
    let blockedMessages = result.messages.filter { message in
      guard
        newMessageIds.contains(message.providerMessageId),
        !message.belongs(to: .trash),
        let address = NormalizedSenderAddress(message.from)
      else {
        return false
      }
      return blockedAddresses.contains(address)
    }
    guard !blockedMessages.isEmpty else { return result }

    let suppressedIds = Set(blockedMessages.map(\.providerMessageId))
    let suppressedResult = result.replacingNewMessageIds(newMessageIds.subtracting(suppressedIds))
    guard
      connection.authorizationState == .authorized,
      connection.capabilities.supports(.delete)
    else {
      return suppressedResult
    }
    let unenforcedMessages = blockedMessages.filter {
      !receiptStore.contains($0.id, productAccountId: session.productAccountId)
    }
    guard !unenforcedMessages.isEmpty else { return suppressedResult }

    do {
      try await actionService.perform(
        .delete,
        sourceProviderMailboxId: "INBOX",
        targetProviderMailboxId: nil,
        targetProviderStateIds: [],
        messages: unenforcedMessages,
        connection: connection,
        session: session
      )
      receiptStore.insert(
        unenforcedMessages.map(\.id),
        productAccountId: session.productAccountId
      )
      _ = await actionService.resumePendingActions(connection: connection, session: session)
    } catch is CancellationError {
      return result
    } catch {
      return result
    }
    return suppressedResult
  }

  private func blockedAddresses(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> Set<NormalizedSenderAddress>? {
    if let blockedAddressesProvider {
      return await blockedAddressesProvider(connection, session)
    }
    do {
      let recordScope = try await profileResolver.recordScope(
        for: connection.id,
        session: session
      )
      let localState = try localStateStore.load(
        productAccountId: session.productAccountId,
        recordScope: recordScope
      )
      do {
        let synchronized =
          try await syncServiceFactory(recordScope).load(session: session) ?? .empty
        let resolved = synchronized.applying(localState?.pendingMutations ?? [])
        try? localStateStore.save(
          BlockedSenderLocalState(
            pendingMutations: localState?.pendingMutations ?? [],
            senders: resolved
          ),
          productAccountId: session.productAccountId,
          recordScope: recordScope
        )
        return resolved.blockedAddressSet
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        return localState?.senders.blockedAddressSet
      }
    } catch is CancellationError {
      return nil
    } catch {
      return nil
    }
  }
}

extension MailboxMetadataSyncResult {
  fileprivate func replacingNewMessageIds(_ newMessageIds: Set<String>) -> Self {
    MailboxMetadataSyncResult(
      categorizedMessageCount: categorizedMessageCount,
      hasUnlistedNewMessages: hasUnlistedNewMessages,
      messages: messages,
      newMessageIds: newMessageIds,
      providerCursorIsExpired: providerCursorIsExpired,
      threads: threads,
      hasInitialMailboxAvailability: hasInitialMailboxAvailability,
      historicalMetadataBackfillCanResume: historicalMetadataBackfillCanResume,
      historicalMetadataBackfillIsComplete: historicalMetadataBackfillIsComplete
    )
  }
}
