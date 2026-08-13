import Foundation

// swiftlint:disable file_length

struct ProductAccountId: Codable, Hashable, RawRepresentable, Sendable {
  let rawValue: String

  init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  init(rawValue: String) {
    self.rawValue = rawValue
  }
}

struct MailProviderId: Codable, Hashable, RawRepresentable, Sendable {
  static let gmail = MailProviderId(rawValue: "gmail")
  static let imapSMTP = MailProviderId(rawValue: "imap-smtp")
  static let pop3SMTP = MailProviderId(rawValue: "pop3-smtp")

  let rawValue: String
}

struct StableProviderMailboxIdentity: Codable, Hashable, Sendable {
  let providerId: MailProviderId
  let value: String
}

struct MailboxConnectionId: Codable, Hashable, Sendable {
  let providerMailboxIdentity: StableProviderMailboxIdentity

  var providerId: MailProviderId {
    providerMailboxIdentity.providerId
  }

  var rawValue: String {
    "\(providerId.rawValue):\(providerMailboxIdentity.value)"
  }
}

struct StableThreadIdentity: Codable, Hashable, Sendable {
  let connectionId: MailboxConnectionId
  let providerThreadId: String

  var rawValue: String {
    "\(connectionId.rawValue):\(providerThreadId)"
  }
}

typealias MailboxThreadIdentity = StableThreadIdentity

struct StableProviderMessageIdentity: Hashable, Sendable {
  let connectionId: MailboxConnectionId
  let providerMessageId: String

  var rawValue: String {
    "\(connectionId.rawValue):\(providerMessageId)"
  }
}

/// Acquires the all-connections lock before connection locks, ordered by ascending id.
/// Lock helpers are non-reentrant within one gate instance and must not be nested there.
/// Gmail operations that need both gates acquire `syncGate` before `pendingActionGate`.
actor MailboxConnectionSyncGate {
  static let pendingActions = MailboxConnectionSyncGate()

  struct Revision: Equatable, Sendable {
    fileprivate let allConnections: UInt64
    fileprivate let connection: UInt64
  }

  static let shared = MailboxConnectionSyncGate()
  private static let allConnectionsId = MailboxConnectionId(
    providerMailboxIdentity: StableProviderMailboxIdentity(
      providerId: MailProviderId(rawValue: "internal"),
      value: "all-connections"
    )
  )

  private enum LockMode: Equatable {
    case exclusive
    case shared
  }

  private enum WaiterPriority: Equatable {
    case normal
    case preempting
  }

  private struct PreemptibleOperation {
    let cancel: @Sendable () -> Void
    let id: UUID
  }

  private struct Waiter {
    let continuation: CheckedContinuation<Bool, Never>
    let id: UUID
    let mode: LockMode
    let priority: WaiterPriority
  }

  private var activePreemptibleOperations: [MailboxConnectionId: PreemptibleOperation] = [:]
  private var exclusivelyLockedConnectionIds: Set<MailboxConnectionId> = []
  private var exclusiveRevisions: [MailboxConnectionId: UInt64] = [:]
  private var preemptionRequestCounts: [MailboxConnectionId: Int] = [:]
  private var sharedLockCounts: [MailboxConnectionId: Int] = [:]
  private var waiters: [MailboxConnectionId: [Waiter]] = [:]
  #if DEBUG || TESTING
    private var queuedOperationObservers:
      [MailboxConnectionId: [CheckedContinuation<Void, Never>]] = [:]
  #endif

  func acquire(_ connectionId: MailboxConnectionId) async -> Bool {
    await acquire(connectionId, mode: .exclusive)
  }

  private func acquire(
    _ connectionId: MailboxConnectionId,
    mode: LockMode,
    priority: WaiterPriority = .normal
  ) async -> Bool {
    let hasExclusiveLock = exclusivelyLockedConnectionIds.contains(connectionId)
    let hasSharedLocks = sharedLockCounts[connectionId, default: 0] > 0
    let hasQueuedWaiters = waiters[connectionId]?.isEmpty == false
    if !hasExclusiveLock && !hasSharedLocks && !hasQueuedWaiters {
      grant(mode, for: connectionId)
      return true
    }
    if mode == .shared && !hasExclusiveLock && !hasQueuedWaiters {
      grant(mode, for: connectionId)
      return true
    }
    let waiterId = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        enqueue(
          Waiter(
            continuation: continuation,
            id: waiterId,
            mode: mode,
            priority: priority
          ),
          for: connectionId
        )
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterId, for: connectionId) }
    }
  }

  private func enqueue(_ waiter: Waiter, for connectionId: MailboxConnectionId) {
    if waiter.priority == .preempting {
      var connectionWaiters = waiters[connectionId, default: []]
      let insertionIndex =
        connectionWaiters.firstIndex { $0.priority == .normal }
        ?? connectionWaiters.endIndex
      connectionWaiters.insert(waiter, at: insertionIndex)
      waiters[connectionId] = connectionWaiters
    } else {
      waiters[connectionId, default: []].append(waiter)
    }
    #if DEBUG || TESTING
      let observers = queuedOperationObservers.removeValue(forKey: connectionId) ?? []
      for observer in observers {
        observer.resume()
      }
    #endif
  }

  private func grant(_ mode: LockMode, for connectionId: MailboxConnectionId) {
    switch mode {
    case .exclusive:
      exclusivelyLockedConnectionIds.insert(connectionId)
      exclusiveRevisions[connectionId, default: 0] += 1
    case .shared:
      sharedLockCounts[connectionId, default: 0] += 1
    }
  }

  private func cancelWaiter(_ waiterId: UUID, for connectionId: MailboxConnectionId) {
    guard var connectionWaiters = waiters[connectionId],
      let index = connectionWaiters.firstIndex(where: { $0.id == waiterId })
    else { return }
    let waiter = connectionWaiters.remove(at: index)
    waiters[connectionId] = connectionWaiters.isEmpty ? nil : connectionWaiters
    waiter.continuation.resume(returning: false)
  }

  func release(_ connectionId: MailboxConnectionId) {
    release(connectionId, mode: .exclusive)
  }

  private func release(_ connectionId: MailboxConnectionId, mode: LockMode) {
    switch mode {
    case .exclusive:
      exclusivelyLockedConnectionIds.remove(connectionId)
    case .shared:
      let remainingCount = sharedLockCounts[connectionId, default: 0] - 1
      sharedLockCounts[connectionId] = remainingCount > 0 ? remainingCount : nil
    }
    guard !exclusivelyLockedConnectionIds.contains(connectionId),
      sharedLockCounts[connectionId] == nil,
      var connectionWaiters = waiters[connectionId],
      !connectionWaiters.isEmpty
    else {
      return
    }

    let first = connectionWaiters.removeFirst()
    grant(first.mode, for: connectionId)
    first.continuation.resume(returning: true)
    if first.mode == .shared {
      while connectionWaiters.first?.mode == .shared {
        let next = connectionWaiters.removeFirst()
        grant(.shared, for: connectionId)
        next.continuation.resume(returning: true)
      }
    }
    waiters[connectionId] = connectionWaiters.isEmpty ? nil : connectionWaiters
  }

  func withLock<T>(
    _ connectionId: MailboxConnectionId,
    operation: () async throws -> T
  ) async throws -> T {
    guard await acquire(Self.allConnectionsId, mode: .shared) else {
      throw CancellationError()
    }
    defer { release(Self.allConnectionsId, mode: .shared) }
    guard await acquire(connectionId, mode: .exclusive) else {
      throw CancellationError()
    }
    defer { release(connectionId, mode: .exclusive) }
    return try await operation()
  }

  func revision(for connectionId: MailboxConnectionId) -> Revision {
    Revision(
      allConnections: exclusiveRevisions[Self.allConnectionsId, default: 0],
      connection: exclusiveRevisions[connectionId, default: 0]
    )
  }

  func withLock<T>(
    _ connectionId: MailboxConnectionId,
    ifUnchangedSince revision: Revision,
    operation: () async throws -> T
  ) async throws -> T {
    guard await acquire(Self.allConnectionsId, mode: .shared) else {
      throw CancellationError()
    }
    defer { release(Self.allConnectionsId, mode: .shared) }
    guard await acquire(connectionId, mode: .exclusive) else {
      throw CancellationError()
    }
    defer { release(connectionId, mode: .exclusive) }
    guard
      exclusiveRevisions[Self.allConnectionsId, default: 0] == revision.allConnections,
      exclusiveRevisions[connectionId, default: 0] == revision.connection + 1
    else {
      throw CancellationError()
    }
    return try await operation()
  }

  func withLocks<T>(
    _ connectionIds: [MailboxConnectionId],
    operation: () async throws -> T
  ) async throws -> T {
    guard await acquire(Self.allConnectionsId, mode: .shared) else {
      throw CancellationError()
    }
    defer { release(Self.allConnectionsId, mode: .shared) }
    let sortedConnectionIds = Array(Set(connectionIds)).sorted { $0.rawValue < $1.rawValue }
    var acquiredConnectionIds: [MailboxConnectionId] = []
    do {
      for connectionId in sortedConnectionIds {
        guard await acquire(connectionId, mode: .exclusive) else {
          throw CancellationError()
        }
        acquiredConnectionIds.append(connectionId)
      }
      let result = try await operation()
      for connectionId in acquiredConnectionIds.reversed() {
        release(connectionId, mode: .exclusive)
      }
      return result
    } catch {
      for connectionId in acquiredConnectionIds.reversed() {
        release(connectionId, mode: .exclusive)
      }
      throw error
    }
  }

  func withSharedLock<T>(
    _ connectionId: MailboxConnectionId,
    operation: () async throws -> T
  ) async throws -> T {
    guard await acquire(Self.allConnectionsId, mode: .shared) else {
      throw CancellationError()
    }
    defer { release(Self.allConnectionsId, mode: .shared) }
    guard await acquire(connectionId, mode: .shared) else {
      throw CancellationError()
    }
    defer { release(connectionId, mode: .shared) }
    return try await operation()
  }

  func withAllConnectionsShared<T>(
    operation: () async throws -> T
  ) async throws -> T {
    guard await acquire(Self.allConnectionsId, mode: .shared) else {
      throw CancellationError()
    }
    defer { release(Self.allConnectionsId, mode: .shared) }
    return try await operation()
  }

  func withAllConnectionsLocked<T>(
    operation: () async throws -> T
  ) async throws -> T {
    guard await acquire(Self.allConnectionsId, mode: .exclusive) else {
      throw CancellationError()
    }
    defer { release(Self.allConnectionsId, mode: .exclusive) }
    return try await operation()
  }
}

extension MailboxConnectionSyncGate {
  #if DEBUG || TESTING
    func waitUntilOperationIsQueued(_ connectionId: MailboxConnectionId) async {
      if waiters[connectionId]?.isEmpty == false { return }
      await withCheckedContinuation { continuation in
        queuedOperationObservers[connectionId, default: []].append(continuation)
      }
    }
  #endif

  /// Cancelling a preemptible operation does not release its lock until the operation exits.
  /// This keeps metadata writes serialized while a higher-priority sync waits to take ownership.
  func withPreemptibleLock<T>(
    _ connectionId: MailboxConnectionId,
    operation: @escaping () async throws -> T
  ) async throws -> T {
    guard await acquire(Self.allConnectionsId, mode: .shared) else {
      throw CancellationError()
    }
    defer { release(Self.allConnectionsId, mode: .shared) }
    guard await acquire(connectionId, mode: .exclusive) else {
      throw CancellationError()
    }
    defer { release(connectionId, mode: .exclusive) }

    let operationId = UUID()
    let task = Task {
      try await operation()
    }
    activePreemptibleOperations[connectionId] = PreemptibleOperation(
      cancel: { task.cancel() },
      id: operationId
    )
    if preemptionRequestCounts[connectionId, default: 0] > 0 {
      task.cancel()
    }
    defer {
      if activePreemptibleOperations[connectionId]?.id == operationId {
        activePreemptibleOperations[connectionId] = nil
      }
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  func withPreemptingLock<T>(
    _ connectionId: MailboxConnectionId,
    beforePreemption: () throws -> Void = {},
    didBeginPreemption: (Bool) -> Void = { _ in },
    operation: () async throws -> T
  ) async throws -> T {
    try Task.checkCancellation()
    try beforePreemption()
    preemptionRequestCounts[connectionId, default: 0] += 1
    defer {
      let remainingCount = preemptionRequestCounts[connectionId, default: 0] - 1
      preemptionRequestCounts[connectionId] = remainingCount > 0 ? remainingCount : nil
    }
    let activePreemptibleOperation = activePreemptibleOperations[connectionId]
    didBeginPreemption(activePreemptibleOperation != nil)
    activePreemptibleOperation?.cancel()
    guard await acquire(Self.allConnectionsId, mode: .shared) else {
      throw CancellationError()
    }
    defer { release(Self.allConnectionsId, mode: .shared) }
    guard await acquire(connectionId, mode: .exclusive, priority: .preempting) else {
      throw CancellationError()
    }
    defer { release(connectionId, mode: .exclusive) }
    try Task.checkCancellation()
    return try await operation()
  }
}

enum ProviderMailAction: String, CaseIterable, Codable, Hashable, Sendable {
  case archive
  case delete
  case markRead
  case markUnread
  case move
  case notSpam
  case restore
  case spam
  case star
  case unstar
}

struct MailboxProviderActionFailureDetail: Equatable, Sendable {
  let description: String
  let messageIds: [StableProviderMessageIdentity]
}

struct MailboxProviderActionSelection: Equatable, Sendable {
  let pendingActionIds: Set<UUID>
}

struct MailboxProviderActionFailureLookup: Equatable, Sendable {
  let coversSelectedMessageIds: Bool
  let details: [MailboxProviderActionFailureDetail]
  let matchedPendingActionIds: Set<UUID>
}

struct MailboxConnectionCapabilities: Equatable, Sendable {
  let canCategorizeHistorical: Bool
  let canForward: Bool
  let canReadMessages: Bool
  let canRequestReadReceipts: Bool
  let canRegisterPush: Bool
  let canReply: Bool
  let canRespondToReadReceipts: Bool
  let canSearchProvider: Bool
  let canSend: Bool
  let canSynchronizeMetadata: Bool
  let providerActions: Set<ProviderMailAction>

  func supports(_ action: ProviderMailAction) -> Bool {
    providerActions.contains(action)
  }

  static let gmail = MailboxConnectionCapabilities(
    canCategorizeHistorical: true,
    canForward: true,
    canReadMessages: true,
    canRequestReadReceipts: false,
    canRegisterPush: true,
    canReply: true,
    canRespondToReadReceipts: false,
    canSearchProvider: true,
    canSend: true,
    canSynchronizeMetadata: true,
    providerActions: Set(ProviderMailAction.allCases)
  )

  static let imapRead = MailboxConnectionCapabilities(
    canCategorizeHistorical: false,
    canForward: false,
    canReadMessages: true,
    canRequestReadReceipts: false,
    canRegisterPush: false,
    canReply: false,
    canRespondToReadReceipts: false,
    canSearchProvider: false,
    canSend: false,
    canSynchronizeMetadata: true,
    providerActions: []
  )

  static func standardsMail(
    engineCapabilities: Set<MailEngineCapability>,
    roleMappings: [CanonicalMailboxRole: String]
  ) -> MailboxConnectionCapabilities {
    let canMove = engineCapabilities.contains(.uidPlus)
    var actions: Set<ProviderMailAction> = [.markRead, .markUnread, .star, .unstar]
    if canMove {
      actions.insert(.move)
      if roleMappings[.archive] != nil { actions.insert(.archive) }
      if roleMappings[.spam] != nil { actions.formUnion([.spam, .notSpam]) }
      if roleMappings[.trash] != nil {
        actions.formUnion([.delete, .restore])
      } else if roleMappings[.archive] != nil {
        actions.insert(.restore)
      }
    }
    let canSend = roleMappings[.sent] != nil
    return MailboxConnectionCapabilities(
      canCategorizeHistorical: false,
      canForward: canSend,
      canReadMessages: true,
      canRequestReadReceipts: canSend,
      canRegisterPush: engineCapabilities.contains(.idle),
      canReply: canSend,
      canRespondToReadReceipts: false,
      canSearchProvider: false,
      canSend: canSend,
      canSynchronizeMetadata: true,
      providerActions: actions
    )
  }

  static let none = MailboxConnectionCapabilities(
    canCategorizeHistorical: false,
    canForward: false,
    canReadMessages: false,
    canRequestReadReceipts: false,
    canRegisterPush: false,
    canReply: false,
    canRespondToReadReceipts: false,
    canSearchProvider: false,
    canSend: false,
    canSynchronizeMetadata: false,
    providerActions: []
  )
}

enum MailboxAuthorizationState: Equatable, Sendable {
  case authorized
  case required
}

enum UnifiedMailbox: CaseIterable, Hashable, Sendable {
  case inbox
  case snoozed
  case pins
  case drafts
  case sent
  case archive
  case allMail
  case spam
  case trash

  var collection: MailboxMessageCollection {
    switch self {
    case .inbox:
      return .role(.inbox)
    case .snoozed:
      return .snoozed
    case .pins:
      return .pins
    case .drafts:
      return .role(.drafts)
    case .sent:
      return .role(.sent)
    case .archive:
      return .role(.archive)
    case .allMail:
      return .allMail
    case .spam:
      return .role(.spam)
    case .trash:
      return .role(.trash)
    }
  }
}

enum MailboxRole: Hashable, Sendable {
  case inbox
  case drafts
  case sent
  case archive
  case spam
  case trash
}

enum MailboxMessageCollection: Hashable, Sendable {
  case role(MailboxRole)
  case snoozed
  case pins
  case allMail
  case allObserved
  case providerMailbox(String)

  var providerMailboxMoveSourceId: String? {
    switch self {
    case .role(.inbox):
      "INBOX"
    case .providerMailbox(let providerMailboxId):
      providerMailboxId
    default:
      nil
    }
  }

  private static let gmailSystemStateIds: Set<String> = [
    "ARCHIVE",
    "CATEGORY_FORUMS",
    "CATEGORY_PERSONAL",
    "CATEGORY_PROMOTIONS",
    "CATEGORY_SOCIAL",
    "CATEGORY_UPDATES",
    "CHAT",
    "DRAFT",
    "EWS_ARCHIVE_HIERARCHY",
    "IMPORTANT",
    "INBOX",
    "SENT",
    "SPAM",
    "STARRED",
    "TRASH",
    "UNREAD",
  ]

  // swiftlint:disable:next cyclomatic_complexity
  func contains(
    providerStateIds: [String]?,
    isPinned: Bool = false,
    isSnoozed: Bool = false
  ) -> Bool {
    let states = Set(providerStateIds ?? ["INBOX"])
    switch self {
    case .role(.inbox):
      return states.contains("INBOX") && !isSnoozed
    case .role(.drafts):
      return states.contains("DRAFT")
    case .role(.sent):
      return states.contains("SENT")
    case .role(.archive):
      return
        (states.contains("ARCHIVE")
        || !states.contains(where: {
          $0.hasPrefix("imap-mailbox:") || $0.hasPrefix("graph-folder:")
            || $0.hasPrefix("ews-folder:")
        }))
        && states.isDisjoint(with: ["INBOX", "DRAFT", "SENT", "SPAM", "TRASH"])
    case .role(.spam):
      return states.contains("SPAM")
    case .role(.trash):
      return states.contains("TRASH")
    case .snoozed:
      return isSnoozed
    case .pins:
      return isPinned
    case .allMail:
      return states.isDisjoint(with: ["SPAM", "TRASH"])
    case .allObserved:
      return true
    case .providerMailbox(let providerStateId):
      return states.contains(providerStateId)
    }
  }

  static func providerMailboxIds(in messages: [MailboxMessageMetadata]) -> [String] {
    Set(
      messages
        .flatMap { $0.providerStateIds ?? [] }
        .filter { !gmailSystemStateIds.contains($0) }
    )
    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  static func isProviderMailboxId(_ providerStateId: String) -> Bool {
    !gmailSystemStateIds.contains(providerStateId)
  }
}

struct MailboxItemCount: Equatable, Sendable {
  let itemCount: Int
  let unreadCount: Int
}

struct ProviderMailbox: Equatable, Hashable, Sendable {
  let id: String
  let isMoveDestination: Bool
  let providerStateIds: Set<String>
  let title: String

  init(
    id: String,
    isMoveDestination: Bool = true,
    providerStateIds: Set<String> = [],
    title: String
  ) {
    self.id = id
    self.isMoveDestination = isMoveDestination
    self.providerStateIds = providerStateIds
    self.title = title
  }
}

struct MailboxConnection: Equatable, Identifiable, Sendable {
  let authorizationGeneration: Int
  let authorizationState: MailboxAuthorizationState
  let capabilities: MailboxConnectionCapabilities
  let connectedAt: Int64
  let displayName: String
  let id: MailboxConnectionId
  let lastVerifiedAt: Int64
  let productAccountId: ProductAccountId
  let trustedDeviceId: String
  let updatedAt: Int64

  init(
    authorizationGeneration: Int = 0,
    authorizationState: MailboxAuthorizationState,
    capabilities: MailboxConnectionCapabilities,
    connectedAt: Int64,
    displayName: String,
    id: MailboxConnectionId,
    lastVerifiedAt: Int64,
    productAccountId: ProductAccountId,
    trustedDeviceId: String,
    updatedAt: Int64
  ) {
    self.authorizationGeneration = authorizationGeneration
    self.authorizationState = authorizationState
    self.capabilities = capabilities
    self.connectedAt = connectedAt
    self.displayName = displayName
    self.id = id
    self.lastVerifiedAt = lastVerifiedAt
    self.productAccountId = productAccountId
    self.trustedDeviceId = trustedDeviceId
    self.updatedAt = updatedAt
  }

  var providerId: MailProviderId {
    id.providerId
  }

  var providerMailboxIdentity: StableProviderMailboxIdentity {
    id.providerMailboxIdentity
  }

  var mailboxAddress: String {
    displayName
  }

  func withAuthorizationGeneration(_ authorizationGeneration: Int) -> Self {
    MailboxConnection(
      authorizationGeneration: authorizationGeneration,
      authorizationState: authorizationState,
      capabilities: capabilities,
      connectedAt: connectedAt,
      displayName: displayName,
      id: id,
      lastVerifiedAt: lastVerifiedAt,
      productAccountId: productAccountId,
      trustedDeviceId: trustedDeviceId,
      updatedAt: updatedAt
    )
  }
}

extension GmailProviderConnectionStatus {
  var mailboxConnectionId: MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: provider),
        value: providerAccountIdentifier
      )
    )
  }

  func mailboxConnection(
    productAccountId: String,
    authorizationState: MailboxAuthorizationState
  ) -> MailboxConnection {
    let providerId = MailProviderId(rawValue: provider)
    return MailboxConnection(
      authorizationGeneration: authorizationGeneration,
      authorizationState: authorizationState,
      capabilities: authorizationState == .authorized && providerId == .gmail
        ? .gmail
        : .none,
      connectedAt: connectedAt,
      displayName: emailAddress,
      id: mailboxConnectionId,
      lastVerifiedAt: lastVerifiedAt,
      productAccountId: ProductAccountId(productAccountId),
      trustedDeviceId: trustedDeviceId,
      updatedAt: updatedAt
    )
  }
}

extension GmailMessageMetadata {
  var mailboxConnectionId: MailboxConnectionId {
    let mailboxIdentity = StableProviderMailboxIdentity(
      providerId: .gmail,
      value: providerAccountIdentifier
    )
    return MailboxConnectionId(
      providerMailboxIdentity: mailboxIdentity
    )
  }

  var stableIdentity: StableProviderMessageIdentity {
    StableProviderMessageIdentity(
      connectionId: mailboxConnectionId,
      providerMessageId: providerMessageId
    )
  }

  var threadIdentity: MailboxThreadIdentity {
    MailboxThreadIdentity(
      connectionId: mailboxConnectionId,
      providerThreadId: providerThreadId
    )
  }
}

struct HistoricalCategorizationScope: Equatable, Sendable {
  var categoryIds: Set<String>?
  var collection: MailboxMessageCollection = .role(.inbox)
  let receivedAtOrAfterMilliseconds: Int64
  let receivedBeforeMilliseconds: Int64

  static func isValidDateRange(
    startDate: Date,
    endDate: Date,
    calendar: Calendar
  ) -> Bool {
    calendar.startOfDay(for: startDate) <= calendar.startOfDay(for: endDate)
  }
}

struct MailboxMessageInlineImage: Equatable, Sendable {
  let contentID: String
  let data: Data
  let decodedPixelCount: Int
  let mimeType: String
}

struct MailboxMessageAttachment: Codable, Equatable, Identifiable, Sendable {
  let byteCount: Int
  let filename: String
  let id: String
  let mimeType: String
  let presentationData: Data?

  init(
    byteCount: Int,
    filename: String,
    id: String,
    mimeType: String,
    presentationData: Data? = nil
  ) {
    self.byteCount = byteCount
    self.filename = filename
    self.id = id
    self.mimeType = mimeType
    self.presentationData = presentationData
  }

  private enum CodingKeys: String, CodingKey {
    case byteCount
    case filename
    case id
    case mimeType
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    byteCount = try container.decode(Int.self, forKey: .byteCount)
    filename = try container.decode(String.self, forKey: .filename)
    id = try container.decode(String.self, forKey: .id)
    mimeType = try container.decode(String.self, forKey: .mimeType)
    presentationData = nil
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(byteCount, forKey: .byteCount)
    try container.encode(filename, forKey: .filename)
    try container.encode(id, forKey: .id)
    try container.encode(mimeType, forKey: .mimeType)
  }
}

struct MailboxMessageBody: Equatable, Sendable {
  let attachments: [MailboxMessageAttachment]
  let html: String?
  let inlineImages: [MailboxMessageInlineImage]
  let text: String

  init(
    text: String,
    html: String? = nil,
    inlineImages: [MailboxMessageInlineImage] = [],
    attachments: [MailboxMessageAttachment] = []
  ) {
    self.attachments = attachments
    self.html = html
    self.inlineImages = inlineImages
    self.text = text
  }
}

struct MailboxMessageMetadata: Equatable, Identifiable, Sendable {
  var categoryId: String?
  let connectionId: MailboxConnectionId
  let from: String?
  let isHistorical: Bool
  let providerInternalDateMilliseconds: Int64
  let providerMessageId: String
  let providerStateIds: [String]?
  let providerThreadId: String
  let recipientHeaders: [String]?
  let replyTo: String?
  let rfcMessageId: String?
  let snippet: String
  let subject: String
  var categoryIds: [String]? = .none
  var bccRecipients: [String]? = .none
  var calendarInvitation: CalendarInvitationDescriptor? = .none
  var hasAttachments = false
  var unsubscribeSuggestion: UnsubscribeSuggestion? = .none

  var messageCategoryIds: [String] {
    Array(Set([categoryId].compactMap { $0 } + (categoryIds ?? []))).sorted()
  }

  func assigningCategories(_ categoryIds: [String]) -> MailboxMessageMetadata {
    let categoryIds = normalizedMessageCategoryIds(categoryIds)
    var message = self
    message.categoryId = categoryIds.first
    message.categoryIds = categoryIds
    return message
  }

  var id: StableProviderMessageIdentity {
    StableProviderMessageIdentity(
      connectionId: connectionId,
      providerMessageId: providerMessageId
    )
  }

  var threadIdentity: MailboxThreadIdentity {
    MailboxThreadIdentity(
      connectionId: connectionId,
      providerThreadId: providerThreadId
    )
  }

  var stableProviderMessageId: String {
    id.rawValue
  }

  var isUnread: Bool {
    providerStateIds?.contains("UNREAD") == true
  }

  func belongs(to role: MailboxRole) -> Bool {
    MailboxMessageCollection.role(role).contains(providerStateIds: providerStateIds)
  }
}

func normalizedMessageCategoryIds(_ categoryIds: [String]) -> [String] {
  Array(Set(categoryIds)).sorted()
}

struct MailboxLocalMetadataSearch {
  static func messages(
    in messages: [MailboxMessageMetadata],
    matching query: String,
    categoryNamesById: [String: String]
  ) -> [MailboxMessageMetadata] {
    let terms = normalized(query).split(whereSeparator: \Character.isWhitespace)
    guard !terms.isEmpty else { return [] }

    return messages.filter { message in
      let searchableText = normalized(
        [
          message.from,
          message.recipientHeaders?.joined(separator: " "),
          message.bccRecipients?.joined(separator: " "),
          message.subject,
          dateText(for: message.providerInternalDateMilliseconds),
          message.messageCategoryIds.joined(separator: " "),
          message.messageCategoryIds.compactMap { categoryNamesById[$0] }.joined(separator: " "),
        ]
        .compactMap { $0 }
        .joined(separator: " ")
      )
      let providerStates = message.providerStateIds.map(providerStates(for:)) ?? []
      return terms.allSatisfy { term in
        searchableText.contains(term) || providerStates.contains(String(term))
      }
    }
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = .current
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    return formatter
  }()

  private static func dateText(for milliseconds: Int64) -> String {
    dateFormatter.string(
      from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    )
  }

  private static func normalized(_ value: String) -> String {
    value
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      .lowercased()
  }

  private static func providerStates(for stateIds: [String]) -> Set<String> {
    let states = Set(stateIds.map { normalized($0) })
    return states.union([
      states.contains("unread") ? "unread" : "read",
      states.contains("starred") ? "starred" : "unstarred",
    ])
  }
}

struct MailboxThread: Equatable, Identifiable, Sendable {
  let latestMessage: MailboxMessageMetadata
  let messages: [MailboxMessageMetadata]
  let providerThreadId: String

  var id: MailboxThreadIdentity {
    latestMessage.threadIdentity
  }

  var inboxMessages: [MailboxMessageMetadata] {
    messages.filter { $0.providerStateIds?.contains("INBOX") ?? true }
  }

  static func group(_ messages: [MailboxMessageMetadata]) -> [MailboxThread] {
    Dictionary(grouping: messages, by: \.threadIdentity)
      .map { threadIdentity, threadMessages in
        let sortedMessages = threadMessages.sorted {
          if $0.providerInternalDateMilliseconds == $1.providerInternalDateMilliseconds {
            return $0.providerMessageId < $1.providerMessageId
          }
          return $0.providerInternalDateMilliseconds > $1.providerInternalDateMilliseconds
        }
        return MailboxThread(
          latestMessage: sortedMessages[0],
          messages: sortedMessages,
          providerThreadId: threadIdentity.providerThreadId
        )
      }
      .sorted {
        if $0.latestMessage.providerInternalDateMilliseconds
          == $1.latestMessage.providerInternalDateMilliseconds
        {
          return $0.providerThreadId < $1.providerThreadId
        }
        return $0.latestMessage.providerInternalDateMilliseconds
          > $1.latestMessage.providerInternalDateMilliseconds
      }
  }
}

struct MailboxMetadataSyncResult: Equatable, Sendable {
  let categorizedMessageCount: Int
  let hasUnlistedNewMessages: Bool
  let hasInitialMailboxAvailability: Bool
  let historicalMetadataBackfillCanResume: Bool
  let historicalMetadataBackfillIsComplete: Bool
  let messages: [MailboxMessageMetadata]
  let newMessageIds: Set<String>?
  let providerCursorIsExpired: Bool
  let threads: [MailboxThread]

  init(
    categorizedMessageCount: Int = 0,
    hasUnlistedNewMessages: Bool,
    messages: [MailboxMessageMetadata],
    newMessageIds: Set<String>?,
    providerCursorIsExpired: Bool,
    threads: [MailboxThread],
    hasInitialMailboxAvailability: Bool = true,
    historicalMetadataBackfillCanResume: Bool = true,
    historicalMetadataBackfillIsComplete: Bool = true
  ) {
    self.categorizedMessageCount = categorizedMessageCount
    self.hasUnlistedNewMessages = hasUnlistedNewMessages
    self.hasInitialMailboxAvailability = hasInitialMailboxAvailability
    self.historicalMetadataBackfillCanResume = historicalMetadataBackfillCanResume
    self.historicalMetadataBackfillIsComplete = historicalMetadataBackfillIsComplete
    self.messages = messages
    self.newMessageIds = newMessageIds
    self.providerCursorIsExpired = providerCursorIsExpired
    self.threads = threads
  }
}

extension MailboxMetadataSyncResult {
  func limitedInitialPage(to limit: Int) -> MailboxMetadataSyncResult {
    guard hasInitialMailboxAvailability, !historicalMetadataBackfillIsComplete else {
      return self
    }
    let messages = Array(messages.prefix(limit))
    return MailboxMetadataSyncResult(
      categorizedMessageCount: categorizedMessageCount,
      hasUnlistedNewMessages: hasUnlistedNewMessages,
      messages: messages,
      newMessageIds: newMessageIds,
      providerCursorIsExpired: providerCursorIsExpired,
      threads: MailboxThread.group(messages),
      hasInitialMailboxAvailability: hasInitialMailboxAvailability,
      historicalMetadataBackfillCanResume: historicalMetadataBackfillCanResume,
      historicalMetadataBackfillIsComplete: historicalMetadataBackfillIsComplete
    )
  }

  func projected(
    to collection: MailboxMessageCollection,
    pinnedThreadIds: Set<StableThreadIdentity> = [],
    snoozedThreadIds: Set<StableThreadIdentity> = []
  ) -> MailboxMetadataSyncResult {
    let observedMessages = Dictionary(
      (threads.flatMap(\.messages) + messages).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    ).values
    let visibleMessages =
      observedMessages
      .filter {
        collection.contains(
          providerStateIds: $0.providerStateIds,
          isPinned: pinnedThreadIds.contains($0.threadIdentity),
          isSnoozed: snoozedThreadIds.contains($0.threadIdentity)
        )
      }
      .sorted(by: Self.messagesAreOrdered)
    let visibleThreadIds = Set(visibleMessages.map(\.threadIdentity))
    let visibleThreads = MailboxThread.group(Array(observedMessages))
      .filter { visibleThreadIds.contains($0.id) }
    return MailboxMetadataSyncResult(
      categorizedMessageCount: categorizedMessageCount,
      hasUnlistedNewMessages: hasUnlistedNewMessages,
      messages: visibleMessages,
      newMessageIds: newMessageIds,
      providerCursorIsExpired: providerCursorIsExpired,
      threads: visibleThreads,
      hasInitialMailboxAvailability: hasInitialMailboxAvailability,
      historicalMetadataBackfillCanResume: historicalMetadataBackfillCanResume,
      historicalMetadataBackfillIsComplete: historicalMetadataBackfillIsComplete
    )
  }

  var itemCount: MailboxItemCount {
    MailboxItemCount(
      itemCount: messages.count,
      unreadCount: messages.count { $0.providerStateIds?.contains("UNREAD") == true }
    )
  }

  private static func messagesAreOrdered(
    _ lhs: MailboxMessageMetadata,
    _ rhs: MailboxMessageMetadata
  ) -> Bool {
    if lhs.providerInternalDateMilliseconds == rhs.providerInternalDateMilliseconds {
      return lhs.providerMessageId < rhs.providerMessageId
    }
    return lhs.providerInternalDateMilliseconds > rhs.providerInternalDateMilliseconds
  }
}

extension GmailMessageMetadata {
  func mailboxMetadata(connectionId: MailboxConnectionId) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: categoryId,
      connectionId: connectionId,
      from: from,
      isHistorical: isHistorical,
      providerInternalDateMilliseconds: providerInternalDateMilliseconds,
      providerMessageId: providerMessageId,
      providerStateIds: providerLabelIds,
      providerThreadId: providerThreadId,
      recipientHeaders: recipientHeaders,
      replyTo: replyTo,
      rfcMessageId: rfcMessageId,
      snippet: snippet,
      subject: subject,
      categoryIds: categoryIds,
      bccRecipients: bccRecipients,
      calendarInvitation: calendarInvitation,
      hasAttachments: hasAttachments ?? false,
      unsubscribeSuggestion: unsubscribeSuggestion
    )
  }
}

extension MailboxMessageMetadata {
  var gmailMetadata: GmailMessageMetadata {
    GmailMessageMetadata(
      categoryId: categoryId,
      from: from,
      hasAttachments: hasAttachments ? true : nil,
      isHistorical: isHistorical,
      providerAccountIdentifier: connectionId.providerMailboxIdentity.value,
      providerInternalDateMilliseconds: providerInternalDateMilliseconds,
      providerLabelIds: providerStateIds,
      providerMessageId: providerMessageId,
      providerThreadId: providerThreadId,
      replyTo: replyTo,
      snippet: snippet,
      stableProviderMessageId: stableProviderMessageId,
      subject: subject,
      recipientHeaders: recipientHeaders,
      bccRecipients: bccRecipients,
      calendarInvitation: calendarInvitation,
      rfcMessageId: rfcMessageId,
      categoryIds: categoryIds,
      unsubscribeSuggestion: unsubscribeSuggestion
    )
  }
}

extension GmailMetadataSyncResult {
  func mailboxResult(connectionId: MailboxConnectionId) -> MailboxMetadataSyncResult {
    let messages = messages.map { $0.mailboxMetadata(connectionId: connectionId) }
    let threads = threads.flatMap {
      MailboxThread.group($0.messages.map { $0.mailboxMetadata(connectionId: connectionId) })
    }
    return MailboxMetadataSyncResult(
      categorizedMessageCount: categorizedMessageCount,
      hasUnlistedNewMessages: hasUnlistedNewMessages,
      messages: messages,
      newMessageIds: newMessageIds,
      providerCursorIsExpired: historyIsExpired,
      threads: threads,
      hasInitialMailboxAvailability: hasInitialMailboxAvailability,
      historicalMetadataBackfillCanResume: historicalMetadataBackfillCanResume,
      historicalMetadataBackfillIsComplete: historicalMetadataBackfillIsComplete
    )
  }
}

extension HistoricalCategorizationScope {
  var gmailScope: GmailHistoricalCategorizationScope {
    GmailHistoricalCategorizationScope(
      categoryIds: categoryIds,
      collection: collection,
      receivedAtOrAfterMilliseconds: receivedAtOrAfterMilliseconds,
      receivedBeforeMilliseconds: receivedBeforeMilliseconds
    )
  }
}

enum OutgoingMessageKind: String, Codable, Sendable {
  case forward
  case new
  case reply
}

struct OutgoingMessage: Codable, Equatable, Sendable {
  let body: String
  let idempotencyKey: String?
  let kind: OutgoingMessageKind?
  let recipient: String
  let requestsReadReceipt: Bool?
  let sourceProviderMessageId: String?
  let subject: String
  let inReplyTo: String?
  let providerThreadId: String?

  init(
    body: String,
    recipient: String,
    subject: String,
    inReplyTo: String? = nil,
    kind: OutgoingMessageKind? = nil,
    providerThreadId: String? = nil,
    requestsReadReceipt: Bool = false,
    sourceProviderMessageId: String? = nil,
    idempotencyKey: String? = nil
  ) {
    self.body = body
    self.idempotencyKey = idempotencyKey
    self.kind = kind
    self.recipient = recipient
    self.requestsReadReceipt = requestsReadReceipt
    self.sourceProviderMessageId = sourceProviderMessageId
    self.subject = subject
    self.inReplyTo = inReplyTo
    self.providerThreadId = providerThreadId
  }

  var rfcMessageId: String? {
    idempotencyKey.map(Self.rfcMessageId)
  }

  static func rfcMessageId(for idempotencyKey: String) -> String {
    "<\(idempotencyKey)@outbox.unwired.mail>"
  }

  func withIdempotencyKey(_ idempotencyKey: String) -> OutgoingMessage {
    OutgoingMessage(
      body: body,
      recipient: recipient,
      subject: subject,
      inReplyTo: inReplyTo,
      kind: kind,
      providerThreadId: providerThreadId,
      requestsReadReceipt: requestsReadReceipt == true,
      sourceProviderMessageId: sourceProviderMessageId,
      idempotencyKey: idempotencyKey
    )
  }
}

protocol MailboxConnectionClearing {
  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws
  func clearLocalConnection(
    session: ProductAccountSessionSnapshot,
    isStillCurrent: @escaping @MainActor () -> Bool
  ) async throws
  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws
}

extension MailboxConnectionClearing {
  func clearLocalConnection(
    session: ProductAccountSessionSnapshot,
    isStillCurrent _: @escaping @MainActor () -> Bool
  ) async throws {
    try await clearLocalConnection(session: session)
  }

}

protocol MailboxConnectionManaging: MailboxConnectionClearing {
  @MainActor
  func connect(
    expectedConnectionId: MailboxConnectionId?,
    removalObservation: MailboxConnectionRemovalObservation?,
    session: ProductAccountSessionSnapshot,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection?

  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection]

  func loadDefaultSendingConnectionId(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionId?

  func removeMailboxConnectionEverywhere(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws

  func setDefaultSendingConnection(
    _ connection: MailboxConnection?,
    session: ProductAccountSessionSnapshot
  ) async throws
}

extension MailboxConnectionManaging {
  @MainActor
  func connect(
    session: ProductAccountSessionSnapshot,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection? {
    try await connect(
      expectedConnectionId: nil,
      removalObservation: nil,
      session: session,
      isSessionCurrent: isSessionCurrent
    )
  }

}

protocol MailboxMetadataSyncing {
  func categorizeHistorical(
    scope: HistoricalCategorizationScope,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult

  func loadInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult

  func loadProviderMailboxes(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [ProviderMailbox]

  func continueHistoricalBackfill(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult

  func syncInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection: MailboxConnection,
    includingHistoryCandidates: Bool,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId: String?,
    throughHistoryId: String?,
    shouldPersist: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection: MailboxConnection,
    includingHistoryCandidates: Bool,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId: String?,
    throughHistoryId: String?,
    shouldPersist: @escaping () -> Bool,
    didBeginPreemption: @escaping () -> Void
  ) async throws -> MailboxMetadataSyncResult

  func overrideCategory(
    _ categoryId: String,
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata

  func setCategories(
    _ categoryIds: [String],
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata
}

extension MailboxMetadataSyncing {
  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await loadInbox(connection: connection, session: session)
      .projected(to: collection)
  }

  func loadProviderMailboxes(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [ProviderMailbox] {
    let result = try await loadMailbox(.allObserved, connection: connection, session: session)
    return MailboxMessageCollection.providerMailboxIds(in: result.messages).map {
      ProviderMailbox(id: $0, title: $0)
    }
  }

  func continueHistoricalBackfill(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await syncInbox(connection: connection, session: session)
  }

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection: MailboxConnection,
    includingHistoryCandidates: Bool,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId: String?,
    throughHistoryId: String?,
    shouldPersist: @escaping () -> Bool,
    didBeginPreemption: @escaping () -> Void
  ) async throws -> MailboxMetadataSyncResult {
    didBeginPreemption()
    return try await syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: includingHistoryCandidates,
      session: session,
      sinceHistoryId: sinceHistoryId,
      throughHistoryId: throughHistoryId,
      shouldPersist: shouldPersist
    )
  }
}

protocol MailboxMessageSearching {
  func searchProvider(
    query: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata]
}

protocol MailboxMessageBodyPrefetching {
  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedThreadIds: Set<StableThreadIdentity>,
    referenceDate: Date,
    session: ProductAccountSessionSnapshot
  ) async throws
}

protocol MailboxMessageReading {
  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws

  func clearCachedMessageBodies(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws

  func loadMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody

  func loadMessageBodyText(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> String

  func loadMessageAttachment(
    _ attachment: MailboxMessageAttachment,
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> Data

  func loadCalendarInvitation(
    _ invitation: CalendarInvitationDescriptor,
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> Data

  func removeCachedMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws
}

extension MailboxMessageReading {
  func loadCalendarInvitation(
    _: CalendarInvitationDescriptor,
    message _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> Data {
    throw MailboxMessageAttachmentError.unsupportedProvider
  }

  func loadMessageAttachment(
    _: MailboxMessageAttachment,
    message _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> Data {
    throw MailboxMessageAttachmentError.unsupportedProvider
  }

  func loadMessageBodyText(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> String {
    try await loadMessageBody(message: message, session: session).text
  }
}

enum MailboxMessageAttachmentError: LocalizedError {
  case invalidResponse
  case unsupportedProvider

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "The attachment could not be downloaded."
    case .unsupportedProvider:
      return "This Mailbox Connection does not support attachment downloads yet."
    }
  }
}

enum MailboxMessageAttachmentPolicy {
  static let maximumByteCount = 25 * 1_024 * 1_024
}

protocol MailboxPushRegistering {
  func registerOrRenewPush(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws
}

protocol MailboxProviderMailActing {
  func deliveryStatus(
    idempotencyKey: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxDeliveryStatus

  func perform(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws

  // swiftlint:disable:next function_parameter_count
  func performTracked(
    _ action: ProviderMailAction,
    sourceProviderMailboxId: String?,
    targetProviderMailboxId: String?,
    targetProviderStateIds: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxProviderActionSelection?

  func releasePendingActionSelection(
    _ selection: MailboxProviderActionSelection,
    connection: MailboxConnection
  ) async

  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws

  // swiftlint:disable:next function_parameter_count
  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    targetProviderStateIds: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws

  // swiftlint:disable:next function_parameter_count
  func perform(
    _ action: ProviderMailAction,
    sourceProviderMailboxId: String?,
    targetProviderMailboxId: String?,
    targetProviderStateIds: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String?

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String?

  func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String?

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String?

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String?

  func discardBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String?

  func blockedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId]

  func failedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId]

  func pendingActionFailureDetails(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxProviderActionFailureDetail]?

  /// Associates failures with the selected action and message IDs. A complete lookup with no
  /// details means those Pending Provider Actions did not fail; an incomplete lookup may use a
  /// connection-level resume or retry error as fallback evidence.
  func pendingActionFailureLookup(
    _ action: ProviderMailAction,
    selection: MailboxProviderActionSelection?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> MailboxProviderActionFailureLookup?

  func waitForPendingActionRetries(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String?

  func waitForPendingActionRetries(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String?

  func acknowledgePendingActionFailures(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async

  func send(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws
}

extension MailboxProviderMailActing {
  func deliveryStatus(
    idempotencyKey _: String,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxDeliveryStatus {
    .unknown
  }

  // swiftlint:disable:next function_parameter_count
  func performTracked(
    _ action: ProviderMailAction,
    sourceProviderMailboxId: String?,
    targetProviderMailboxId: String?,
    targetProviderStateIds: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxProviderActionSelection? {
    try await perform(
      action,
      sourceProviderMailboxId: sourceProviderMailboxId,
      targetProviderMailboxId: targetProviderMailboxId,
      targetProviderStateIds: targetProviderStateIds,
      messages: messages,
      connection: connection,
      session: session
    )
    return nil
  }

  func releasePendingActionSelection(
    _: MailboxProviderActionSelection,
    connection _: MailboxConnection
  ) async {}

  // swiftlint:disable:next function_parameter_count
  func perform(
    _ action: ProviderMailAction,
    sourceProviderMailboxId _: String?,
    targetProviderMailboxId: String?,
    targetProviderStateIds: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await perform(
      action,
      targetProviderMailboxId: targetProviderMailboxId,
      targetProviderStateIds: targetProviderStateIds,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  // swiftlint:disable:next function_parameter_count
  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    targetProviderStateIds _: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await perform(
      action,
      targetProviderMailboxId: targetProviderMailboxId,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    guard targetProviderMailboxId == nil else {
      throw MailboxConnectionAdapterError.providerMailboxTargetRequired
    }
    try await perform(
      action,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  func resumePendingActions(
    connections _: [MailboxConnection],
    session _: ProductAccountSessionSnapshot
  ) async -> String? {
    nil
  }

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    guard await revalidateProviderAccess() else { return nil }
    if connections.count == 1, let connection = connections.first {
      return await resumePendingActions(connection: connection, session: session)
    }
    return await resumePendingActions(connections: connections, session: session)
  }

  func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resumePendingActions(connections: [connection], session: session)
  }

  func retryBlockedPendingAction(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async -> String? {
    nil
  }

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    guard await revalidateProviderAccess() else { return nil }
    return await retryBlockedPendingAction(connection: connection, session: session)
  }

  func discardBlockedPendingAction(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async -> String? {
    nil
  }

  func blockedPendingActionConnectionIds(
    connections _: [MailboxConnection],
    session _: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    []
  }

  func failedPendingActionConnectionIds(
    connections _: [MailboxConnection],
    session _: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    []
  }

  func pendingActionFailureDetails(
    _: ProviderMailAction,
    messages _: [MailboxMessageMetadata],
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async -> [MailboxProviderActionFailureDetail]? {
    nil
  }

  func pendingActionFailureLookup(
    _ action: ProviderMailAction,
    selection _: MailboxProviderActionSelection?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> MailboxProviderActionFailureLookup? {
    guard
      let details = await pendingActionFailureDetails(
        action,
        messages: messages,
        connection: connection,
        session: session
      )
    else { return nil }
    return MailboxProviderActionFailureLookup(
      coversSelectedMessageIds: false,
      details: details,
      matchedPendingActionIds: []
    )
  }

  func waitForPendingActionRetries(
    connections _: [MailboxConnection],
    session _: ProductAccountSessionSnapshot
  ) async -> String? {
    nil
  }

  func waitForPendingActionRetries(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await waitForPendingActionRetries(connections: [connection], session: session)
  }

  func acknowledgePendingActionFailures(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async {}
}

protocol MailboxLocalDataMaintaining {
  func clearLocalMailboxData(session: ProductAccountSessionSnapshot) async throws
  func rebuildLocalIndexes(session: ProductAccountSessionSnapshot) async throws
}

extension MailboxLocalDataMaintaining {
  func clearLocalMailboxData(session _: ProductAccountSessionSnapshot) async throws {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func rebuildLocalIndexes(session _: ProductAccountSessionSnapshot) async throws {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }
}

protocol MailboxConnectionAdapter:
  MailboxConnectionManaging, MailboxMetadataSyncing, MailboxMessageSearching,
  MailboxLocalDataMaintaining, MailboxMessageBodyPrefetching, MailboxMessageReading,
  MailboxPushRegistering,
  MailboxProviderMailActing
{}

struct MailboxConnectionLoadSnapshot {
  let connections: [MailboxConnection]
  let isAuthoritative: Bool
  let loadErrorDescription: String?

  init(
    connections: [MailboxConnection],
    isAuthoritative: Bool,
    loadErrorDescription: String? = nil
  ) {
    self.connections = connections
    self.isAuthoritative = isAuthoritative
    self.loadErrorDescription = loadErrorDescription
  }
}

protocol MailboxConnectionSnapshotLoading {
  func loadConnectionSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionLoadSnapshot
}

enum MailboxConnectionLoadError: LocalizedError, Equatable {
  case partialProviderLoad(String)

  var errorDescription: String? {
    switch self {
    case .partialProviderLoad(let description):
      return description
    }
  }
}

enum MailboxConnectionAdapterError: LocalizedError, Equatable {
  case authorizationRequired
  case connectionRemoved
  case unsupportedCapability
  case unexpectedAuthorizedAccount
  case productAccountMismatch
  case providerMailboxTargetRequired
  case unsupportedProvider

  var errorDescription: String? {
    switch self {
    case .authorizationRequired:
      return "Authorize this Mailbox Connection on this device before accessing mail."
    case .connectionRemoved:
      return "This Mailbox Connection was removed on another trusted device."
    case .unsupportedCapability:
      return "This Mailbox Connection does not support that operation yet."
    case .unexpectedAuthorizedAccount:
      return "Sign in to the account for the selected Mailbox Connection."
    case .productAccountMismatch:
      return "The mailbox connection does not belong to the current Product Account."
    case .providerMailboxTargetRequired:
      return "Choose a provider mailbox before moving this message."
    case .unsupportedProvider:
      return "The selected mail provider is not supported by this adapter."
    }
  }
}

func singleCategoryIdentifier(_ categoryIds: [String]) throws -> String {
  guard categoryIds.count == 1, let categoryId = categoryIds.first else {
    throw MailboxConnectionAdapterError.unsupportedProvider
  }
  return categoryId
}

// swiftlint:disable:next type_body_length
struct GmailMailboxConnectionAdapter: MailboxConnectionAdapter {
  private let attachmentStore: DownloadedAttachmentStore
  private let bodyReader: GmailMessageReading
  private let connectionService: GmailProviderConnecting
  private let credentialVerifier: GmailProviderCredentialVerifying
  private let definitionSyncService: MailboxConnectionDefinitionSyncing
  private let mailActionService: GmailProviderMailActing
  private let metadataService: GmailMessageMetadataSyncing
  private let metadataStore: GmailMessageMetadataPersisting
  private let oauthAuthorizer: GmailOAuthAuthorizing
  private let pushWatchService: GmailPushWatchRegistering
  private let pendingActionService: PendingProviderActionService
  private let pendingActionGate: MailboxConnectionSyncGate
  private let outboxService: OutboxDeliveryService
  private let searchService: GmailMessageSearching
  private let syncGate: MailboxConnectionSyncGate

  init(
    attachmentStore: DownloadedAttachmentStore = DownloadedAttachmentStore(),
    bodyReader: GmailMessageReading = GmailMessageBodyService(),
    connectionService: GmailProviderConnecting = GmailProviderConnectionService(),
    credentialVerifier: GmailProviderCredentialVerifying =
      GoogleGmailProviderCredentialVerifier(),
    definitionSyncService: MailboxConnectionDefinitionSyncing = MailboxConnectionSyncService(),
    mailActionService: GmailProviderMailActing = GmailMessageMetadataService(),
    metadataService: GmailMessageMetadataSyncing = GmailMessageMetadataService(),
    metadataStore: GmailMessageMetadataPersisting = SwiftDataGmailMessageMetadataStore(),
    oauthAuthorizer: GmailOAuthAuthorizing = GoogleGmailOAuthService(),
    pushWatchService: GmailPushWatchRegistering = GmailPushWatchService(),
    pendingActionService: PendingProviderActionService = .shared,
    pendingActionGate: MailboxConnectionSyncGate = .pendingActions,
    outboxService: OutboxDeliveryService = .shared,
    searchService: GmailMessageSearching = GmailMessageMetadataService(),
    syncGate: MailboxConnectionSyncGate = .shared
  ) {
    self.attachmentStore = attachmentStore
    self.bodyReader = bodyReader
    self.connectionService = connectionService
    self.credentialVerifier = credentialVerifier
    self.definitionSyncService = definitionSyncService
    self.mailActionService = mailActionService
    self.metadataService = metadataService
    self.metadataStore = metadataStore
    self.oauthAuthorizer = oauthAuthorizer
    self.pushWatchService = pushWatchService
    self.pendingActionService = pendingActionService
    self.pendingActionGate = pendingActionGate
    self.outboxService = outboxService
    self.searchService = searchService
    self.syncGate = syncGate
  }

  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws {
    try await clearLocalConnection(session: session, isStillCurrent: { true })
  }

  func rebuildLocalIndexes(session: ProductAccountSessionSnapshot) async throws {
    try await syncGate.withAllConnectionsLocked {
      try metadataStore.clearMessages(productAccountId: session.productAccountId)
    }
  }

  func clearLocalMailboxData(session: ProductAccountSessionSnapshot) async throws {
    try await syncGate.withAllConnectionsLocked {
      var firstError: Error?
      do {
        try metadataStore.clearMessages(productAccountId: session.productAccountId)
      } catch {
        firstError = error
      }
      do {
        try bodyReader.clearCachedMessageBodies(session: session)
      } catch {
        firstError = firstError ?? error
      }
      if let firstError { throw firstError }
    }
  }

  func clearLocalConnection(
    session: ProductAccountSessionSnapshot,
    isStillCurrent: @escaping @MainActor () -> Bool
  ) async throws {
    let cleanup = {
      var firstError: Error?
      do {
        try await connectionService.clearLocalConnection(session: session)
      } catch {
        firstError = error
      }
      guard await isStillCurrent() else {
        if let firstError {
          throw firstError
        }
        return
      }
      do {
        try await pendingActionService.clear(session: session)
      } catch {
        firstError = firstError ?? error
      }
      if let firstError {
        throw firstError
      }
    }
    try await syncGate.withAllConnectionsLocked {
      try await pendingActionGate.withAllConnectionsLocked(operation: cleanup)
    }
  }

  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await syncGate.withAllConnectionsLocked {
      try await pendingActionGate.withLock(connection.id) {
        var firstError: Error?
        do {
          try await connectionService.clearLocalConnection(
            try gmailConnection(connection, session: session),
            session: session,
            allowsAccountWideCleanup: true
          )
        } catch {
          firstError = error
        }
        do {
          try await pendingActionService.clear(connection: connection, session: session)
        } catch {
          firstError = firstError ?? error
        }
        do {
          try await outboxService.clear(connection: connection, session: session)
        } catch {
          firstError = firstError ?? error
        }
        if let firstError {
          throw firstError
        }
      }
    }
  }

  @MainActor
  // swiftlint:disable:next function_body_length
  func connect(
    expectedConnectionId: MailboxConnectionId?,
    removalObservation: MailboxConnectionRemovalObservation?,
    session: ProductAccountSessionSnapshot,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection? {
    _ = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    let authorizedTokens = try await oauthAuthorizer.authorize()
    let verifiedAccount = try await credentialVerifier.verify(
      accessToken: authorizedTokens.accessToken,
      refreshToken: authorizedTokens.refreshToken
    )
    try Task.checkCancellation()
    guard isSessionCurrent(session) else {
      return nil
    }

    let verifiedConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: verifiedAccount.providerAccountIdentifier
      )
    )
    if let expectedConnectionId, expectedConnectionId != verifiedConnectionId {
      throw MailboxConnectionAdapterError.unexpectedAuthorizedAccount
    }
    return try await syncGate.withLock(verifiedConnectionId) {
      guard isSessionCurrent(session) else {
        return nil
      }
      var hadExistingConnection = try connectionService.hasLocalAuthorization(
        providerAccountIdentifier: verifiedAccount.providerAccountIdentifier,
        session: session
      )
      var existingStatus = try await connectionService.loadStoredConnection(
        providerAccountIdentifier: verifiedAccount.providerAccountIdentifier,
        session: session
      )
      let currentSnapshot = try await definitionSyncService.loadSnapshotForProviderAccess(
        session: session
      )
      var localAuthorizationGeneration =
        hadExistingConnection ? existingStatus?.authorizationGeneration ?? 0 : nil
      if try definitionSyncService.requiresLocalCleanup(
        in: currentSnapshot,
        connectionId: verifiedConnectionId,
        localAuthorizationGeneration: localAuthorizationGeneration,
        session: session
      ) {
        let localStatus = try localStatusForCleanup(
          id: verifiedConnectionId,
          localStatusesById: [:],
          session: session
        )
        try await performLocalCleanup(
          localStatus: localStatus,
          connection: removedMailboxConnection(
            id: verifiedConnectionId,
            localStatus: localStatus,
            session: session
          ),
          session: session
        )
        try definitionSyncService.recordLocalCleanup(
          in: currentSnapshot,
          connectionId: verifiedConnectionId,
          session: session
        )
        hadExistingConnection = false
        existingStatus = nil
        localAuthorizationGeneration = nil
      }

      let accountToConnect = VerifiedGmailAccount(
        emailAddress: verifiedAccount.emailAddress,
        providerAccountIdentifier: verifiedAccount.providerAccountIdentifier,
        tokens: GmailProviderTokens(
          accessToken: verifiedAccount.tokens.accessToken,
          refreshToken: verifiedAccount.tokens.refreshToken,
          idToken: authorizedTokens.idToken
        )
      )
      var status = try await connectionService.completeConnection(
        verifiedAccount: accountToConnect,
        session: session
      )
      if let existingStatus {
        status = try connectionService.bindAuthorizationGeneration(
          existingStatus.authorizationGeneration,
          to: status,
          session: session
        )
      }
      let connection = status.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .authorized
      )
      do {
        let snapshot =
          if expectedConnectionId == nil {
            try await definitionSyncService.recreateDefinition(
              connection.definition,
              after: removalObservation,
              session: session
            )
          } else {
            try await definitionSyncService.saveConnection(connection, session: session)
          }
        let authorizationGeneration =
          snapshot.connections.first(where: { $0.id == connection.id })?
          .authorizationGeneration
          ?? connection.authorizationGeneration
        if try definitionSyncService.requiresLocalCleanup(
          in: snapshot,
          connectionId: verifiedConnectionId,
          localAuthorizationGeneration: localAuthorizationGeneration,
          session: session
        ) {
          try await performLocalCleanup(
            localStatus: status,
            connection: connection,
            session: session
          )
          try definitionSyncService.recordLocalCleanup(
            in: snapshot,
            connectionId: verifiedConnectionId,
            session: session
          )
          hadExistingConnection = false
          status = try await connectionService.completeConnection(
            verifiedAccount: accountToConnect,
            session: session
          )
        }
        let boundStatus = try connectionService.bindAuthorizationGeneration(
          authorizationGeneration,
          to: status,
          session: session
        )
        return boundStatus.mailboxConnection(
          productAccountId: session.productAccountId,
          authorizationState: .authorized
        )
      } catch {
        var shouldClearLocalConnection = !hadExistingConnection
        if let syncError = error as? MailboxConnectionSyncError,
          case .connectionRemoved = syncError
        {
          shouldClearLocalConnection = true
        }
        if shouldClearLocalConnection {
          try await connectionService.clearLocalConnection(
            status,
            session: session,
            allowsAccountWideCleanup: false
          )
        }
        throw error
      }
    }
  }

  // swiftlint:disable:next function_body_length
  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    let storedStatuses = try await syncGate.withAllConnectionsLocked {
      try await connectionService.loadStoredConnections(session: session)
    }
    let synchronizedSnapshot: MailboxConnectionSyncSnapshot
    do {
      synchronizedSnapshot = try await definitionSyncService.loadSnapshotForProviderAccess(
        session: session
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return storedStatuses.map {
        $0.mailboxConnection(
          productAccountId: session.productAccountId,
          authorizationState: .required
        )
      }
    }
    let localStatuses = try await syncGate.withAllConnectionsLocked {
      try await connectionService.loadConnections(
        migrationPolicy: gmailCredentialMigrationPolicy(for: synchronizedSnapshot),
        session: session
      )
    }
    let localConnections = try localConnections(from: localStatuses, session: session)
    let localConnectionsById = Dictionary(
      localConnections.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let localStatusesById = statusesByConnectionId(localStatuses)
    guard
      let (snapshot, usedCachedSnapshot) = try await reconciledSnapshot(
        localConnections: localConnections,
        session: session
      )
    else { return localConnections }
    try await clearConnectionsRequiringLocalCleanup(
      snapshot.connectionIdsRequiringLocalCleanup,
      localStatusesById: localStatusesById,
      session: session
    )
    var definitions = snapshot.connections
    if usedCachedSnapshot {
      definitions += localConnections.map(\.definition).filter { definition in
        !definitions.contains(where: { $0.id == definition.id })
          && !snapshot.removedConnectionIds.contains(definition.id)
      }
    }
    return
      definitions
      .filter { $0.provider == MailProviderId.gmail.rawValue }
      .map { definition in
        if let localConnection = localConnectionsById[definition.id],
          localConnection.authorizationGeneration == definition.authorizationGeneration
        {
          return localConnection
        }
        return definition.mailboxConnection(
          productAccountId: session.productAccountId,
          trustedDeviceId: session.trustedDeviceId
        )
      }
  }

  private func gmailCredentialMigrationPolicy(
    for snapshot: MailboxConnectionSyncSnapshot
  ) -> GmailCredentialMigrationPolicy {
    let blockedConnectionIds = Set(
      snapshot.connections.filter {
        $0.provider == MailProviderId.gmail.rawValue && $0.authorizationGeneration > 0
      }.map(\.id)
        + snapshot.removedConnectionIds.filter { $0.providerId == .gmail }
        + snapshot.authorizationCleanupConnectionIds.filter { $0.providerId == .gmail }
    )
    let blockedIdentifiers = Set(
      blockedConnectionIds.map(\.providerMailboxIdentity.value)
    )
    return GmailCredentialMigrationPolicy(
      allowsUnscopedLegacyMigration: blockedIdentifiers.isEmpty,
      blockedProviderAccountIdentifiers: blockedIdentifiers
    )
  }

  private func localConnections(
    from statuses: [GmailProviderConnectionStatus],
    session: ProductAccountSessionSnapshot
  ) throws -> [MailboxConnection] {
    try statuses.map { status in
      status.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: try connectionService.hasLocalAuthorization(status, session: session)
          ? .authorized : .required
      )
    }
  }

  private func statusesByConnectionId(
    _ statuses: [GmailProviderConnectionStatus]
  ) -> [MailboxConnectionId: GmailProviderConnectionStatus] {
    Dictionary(
      statuses.map { ($0.mailboxConnectionId, $0) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  private func clearConnectionsRequiringLocalCleanup(
    _ connectionIds: [MailboxConnectionId],
    localStatusesById: [MailboxConnectionId: GmailProviderConnectionStatus],
    session: ProductAccountSessionSnapshot
  ) async throws {
    var firstError: Error?
    for connectionId in connectionIds where connectionId.providerId == .gmail {
      do {
        try await clearConnectionRequiringLocalCleanup(
          connectionId,
          localStatusesById: localStatusesById,
          session: session
        )
      } catch {
        firstError = firstError ?? error
      }
    }
    if let firstError {
      throw firstError
    }
  }

  private func clearConnectionRequiringLocalCleanup(
    _ connectionId: MailboxConnectionId,
    localStatusesById: [MailboxConnectionId: GmailProviderConnectionStatus],
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await syncGate.withAllConnectionsLocked {
      let currentSnapshot = try await definitionSyncService.loadSnapshotForProviderAccess(
        session: session
      )
      let currentLocalStatus = try await connectionService.loadStoredConnection(
        providerAccountIdentifier: connectionId.providerMailboxIdentity.value,
        session: session
      )
      let localAuthorizationGeneration =
        try connectionService.hasLocalAuthorization(
          providerAccountIdentifier: connectionId.providerMailboxIdentity.value,
          session: session
        ) ? currentLocalStatus?.authorizationGeneration ?? 0 : nil
      guard
        try definitionSyncService.requiresLocalCleanup(
          in: currentSnapshot,
          connectionId: connectionId,
          localAuthorizationGeneration: localAuthorizationGeneration,
          session: session
        )
      else { return }
      let localStatus: GmailProviderConnectionStatus?
      if let currentLocalStatus {
        localStatus = currentLocalStatus
      } else {
        localStatus = try localStatusForCleanup(
          id: connectionId,
          localStatusesById: localStatusesById,
          session: session
        )
      }
      let removedConnection = removedMailboxConnection(
        id: connectionId,
        localStatus: localStatus,
        session: session
      )
      try await performLocalCleanup(
        localStatus: localStatus,
        connection: removedConnection,
        session: session
      )
      try definitionSyncService.recordLocalCleanup(
        in: currentSnapshot,
        connectionId: connectionId,
        session: session
      )
    }
  }

  private func performLocalCleanup(
    localStatus: GmailProviderConnectionStatus?,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    var cleanupError: Error?
    do {
      try await connectionService.clearLocalConnection(
        localStatus
          ?? gmailConnection(
            connection,
            session: session,
            requiresAuthorization: false
          ),
        session: session,
        allowsAccountWideCleanup: true
      )
    } catch {
      cleanupError = error
    }
    do {
      try await clearRemovedConnection(connection, session: session)
    } catch {
      cleanupError = cleanupError ?? error
    }
    if let cleanupError { throw cleanupError }
  }

  private func localStatusForCleanup(
    id: MailboxConnectionId,
    localStatusesById: [MailboxConnectionId: GmailProviderConnectionStatus],
    session: ProductAccountSessionSnapshot
  ) throws -> GmailProviderConnectionStatus? {
    if let localStatus = localStatusesById[id] {
      return localStatus
    }
    return try connectionService.loadConnectionForCleanup(
      providerAccountIdentifier: id.providerMailboxIdentity.value,
      session: session
    )
  }

  private func removedMailboxConnection(
    id: MailboxConnectionId,
    localStatus: GmailProviderConnectionStatus?,
    session: ProductAccountSessionSnapshot
  ) -> MailboxConnection {
    if let localStatus {
      return localStatus.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .required
      )
    }
    return MailboxConnection(
      authorizationState: .required,
      capabilities: .gmail,
      connectedAt: 0,
      displayName: "",
      id: id,
      lastVerifiedAt: 0,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: "",
      updatedAt: 0
    )
  }

  private func reconciledSnapshot(
    localConnections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async throws -> (MailboxConnectionSyncSnapshot, Bool)? {
    do {
      return (
        try await definitionSyncService.reconcileConnections(
          localConnections.map(\.definition),
          session: session
        ),
        false
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard
        let snapshot = try? await definitionSyncService.loadSnapshotForProviderAccess(
          session: session
        )
      else { return nil }
      return (snapshot, true)
    }
  }

  func loadDefaultSendingConnectionId(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionId? {
    try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
      .defaultSendingConnectionId
  }

  func removeMailboxConnectionEverywhere(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await syncGate.withAllConnectionsLocked {
      let gmailStatus = try gmailConnection(
        connection, session: session, requiresAuthorization: false)
      try await pendingActionGate.withLock(connection.id) {
        _ = try await definitionSyncService.removeConnection(connection.id, session: session)
        try await clearRemovedConnectionWhilePendingActionLocked(connection, session: session)
      }
      try await connectionService.clearLocalConnection(
        gmailStatus,
        session: session,
        allowsAccountWideCleanup: true
      )
    }
  }

  private func clearRemovedConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await pendingActionGate.withLock(connection.id) {
      try await clearRemovedConnectionWhilePendingActionLocked(connection, session: session)
    }
  }

  private func clearRemovedConnectionWhilePendingActionLocked(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    var cleanupError: Error?
    do {
      try await pendingActionService.clear(connection: connection, session: session)
    } catch {
      cleanupError = error
    }
    do {
      try await outboxService.clear(connection: connection, session: session)
    } catch {
      cleanupError = cleanupError ?? error
    }
    do {
      try attachmentStore.clear(connectionId: connection.id)
    } catch {
      cleanupError = cleanupError ?? error
    }
    if let cleanupError {
      throw cleanupError
    }
  }

  func setDefaultSendingConnection(
    _ connection: MailboxConnection?,
    session: ProductAccountSessionSnapshot
  ) async throws {
    if let connection {
      guard connection.productAccountId == ProductAccountId(session.productAccountId) else {
        throw MailboxConnectionAdapterError.productAccountMismatch
      }
      guard connection.authorizationState == .authorized, connection.capabilities.canSend else {
        throw MailboxConnectionAdapterError.authorizationRequired
      }
    }
    _ = try await definitionSyncService.setDefaultSendingConnection(
      connection?.id,
      session: session
    )
  }

  func categorizeHistorical(
    scope: HistoricalCategorizationScope,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await withSharedProviderAccess(connection, session: session) { gmailConnection in
      let result = try await metadataService.categorizeHistorical(
        scope: scope.gmailScope,
        connection: gmailConnection,
        session: session
      )
      return try await pendingActionService.project(
        result.mailboxResult(connectionId: connection.id),
        collection: .role(.inbox),
        connection: connection,
        session: session
      )
    }
  }

  func loadInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await withSharedProviderAccess(connection, session: session) { gmailConnection in
      let additionalProviderMessageIds = Set(
        try await pendingActionService.pendingActions(session: session)
          .filter { pendingAction in
            guard
              pendingAction.connectionId == connection.id.rawValue,
              pendingAction.keepsOptimisticProjection
            else { return false }
            switch pendingAction.action {
            case .notSpam, .restore:
              return true
            case .move:
              return pendingAction.targetProviderMailboxId == "INBOX"
            default:
              return false
            }
          }
          .flatMap(\.messageIds)
      )
      let result = try await metadataService.loadInboxProjectionCandidates(
        additionalProviderMessageIds: additionalProviderMessageIds,
        connection: gmailConnection,
        session: session
      )
      return try await pendingActionService.project(
        result.mailboxResult(connectionId: connection.id),
        collection: .role(.inbox),
        connection: connection,
        session: session
      )
    }
  }

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    if collection == .role(.inbox) {
      return try await loadInbox(connection: connection, session: session)
    }
    return try await withSharedProviderAccess(connection, session: session) { gmailConnection in
      let result = try await metadataService.loadMailbox(
        .allObserved,
        connection: gmailConnection,
        session: session
      )
      return try await pendingActionService.project(
        result.mailboxResult(connectionId: connection.id),
        collection: collection,
        connection: connection,
        session: session
      )
    }
  }

  func loadProviderMailboxes(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [ProviderMailbox] {
    try await withSharedProviderAccess(connection, session: session) { gmailConnection in
      try await metadataService.loadProviderMailboxes(
        connection: gmailConnection,
        session: session
      )
    }
  }

  func continueHistoricalBackfill(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await syncGate.withPreemptibleLock(connection.id) {
      try Task.checkCancellation()
      let gmailConnection = try await gmailConnectionForProviderAccess(
        connection,
        session: session,
        connectionIsLocked: true
      )
      let result = try await metadataService.continueHistoricalBackfill(
        connection: gmailConnection,
        session: session
      )
      try Task.checkCancellation()
      if result.historicalMetadataBackfillIsComplete {
        let observedMessages = try await metadataService.loadMailbox(
          .allObserved,
          connection: gmailConnection,
          session: session
        )
        try await reconcileAndResumePendingActions(
          messages: observedMessages.messages.map {
            $0.mailboxMetadata(connectionId: connection.id)
          },
          removesContradictedActions: true,
          connection: connection,
          session: session
        )
      }
      return result.mailboxResult(connectionId: connection.id)
    }
  }

  func syncInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await syncGate.withLock(connection.id) {
      try Task.checkCancellation()
      let gmailConnection = try await gmailConnectionForProviderAccess(
        connection,
        session: session,
        connectionIsLocked: true
      )
      let syncResult = try await metadataService.syncInbox(
        connection: gmailConnection,
        session: session
      )
      let observedMessages = try await metadataService.loadMailbox(
        .allObserved,
        connection: gmailConnection,
        session: session
      )
      try await reconcileAndResumePendingActions(
        messages: observedMessages.messages.map { $0.mailboxMetadata(connectionId: connection.id) },
        removesContradictedActions: syncResult.historicalMetadataBackfillIsComplete,
        connection: connection,
        session: session
      )
      let projectedInbox = try await pendingActionService.project(
        observedMessages.mailboxResult(connectionId: connection.id),
        collection: .role(.inbox),
        connection: connection,
        session: session
      )
      _ = try await metadataService.loadMailbox(
        .role(.inbox),
        connection: gmailConnection,
        session: session
      )
      return projectedInbox
    }
  }

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection: MailboxConnection,
    includingHistoryCandidates: Bool,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId: String?,
    throughHistoryId: String?,
    shouldPersist: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    try await syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: includingHistoryCandidates,
      session: session,
      sinceHistoryId: sinceHistoryId,
      throughHistoryId: throughHistoryId,
      shouldPersist: shouldPersist,
      didBeginPreemption: {}
    )
  }

  // swiftlint:disable:next function_body_length function_parameter_count
  func syncRecentInbox(
    connection: MailboxConnection,
    includingHistoryCandidates: Bool,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId: String?,
    throughHistoryId: String?,
    shouldPersist: @escaping () -> Bool,
    didBeginPreemption: @escaping () -> Void
  ) async throws -> MailboxMetadataSyncResult {
    try Task.checkCancellation()
    guard shouldPersist() else { throw GmailMessageMetadataSyncError.staleLocalConnection }
    var didCancelHistoricalBackfill = false
    let recordPreemption: (Bool) -> Void = {
      didCancelHistoricalBackfill = $0
      didBeginPreemption()
    }
    do {
      return try await syncGate.withPreemptingLock(
        connection.id,
        beforePreemption: {
          guard shouldPersist() else {
            throw GmailMessageMetadataSyncError.staleLocalConnection
          }
        },
        didBeginPreemption: recordPreemption,
        operation: {
          let gmailConnection = try await gmailConnectionForProviderAccess(
            connection,
            session: session,
            connectionIsLocked: true
          )
          let recentSync = try await metadataService.syncRecentInbox(
            connection: gmailConnection,
            includingHistoryCandidates: includingHistoryCandidates,
            session: session,
            sinceHistoryId: sinceHistoryId,
            throughHistoryId: throughHistoryId,
            shouldPersist: shouldPersist
          )
          let observedMessages = try await metadataService.loadMailbox(
            .allObserved,
            connection: gmailConnection,
            session: session
          )
          try await reconcileAndResumePendingActions(
            messages: observedMessages.messages.map {
              $0.mailboxMetadata(connectionId: connection.id)
            },
            removesContradictedActions: recentSync.historicalMetadataBackfillIsComplete,
            connection: connection,
            session: session
          )
          let projectedInbox = try await pendingActionService.project(
            observedMessages.mailboxResult(connectionId: connection.id),
            collection: .role(.inbox),
            connection: connection,
            session: session
          )
          _ = try await metadataService.loadMailbox(
            .role(.inbox),
            connection: gmailConnection,
            session: session
          )
          return MailboxMetadataSyncResult(
            hasUnlistedNewMessages: recentSync.hasUnlistedNewMessages,
            messages: projectedInbox.messages,
            newMessageIds: recentSync.newMessageIds,
            providerCursorIsExpired: recentSync.historyIsExpired,
            threads: projectedInbox.threads,
            hasInitialMailboxAvailability: projectedInbox.hasInitialMailboxAvailability,
            historicalMetadataBackfillCanResume:
              projectedInbox.historicalMetadataBackfillCanResume,
            historicalMetadataBackfillIsComplete:
              projectedInbox.historicalMetadataBackfillIsComplete
          )
        }
      )
    } catch {
      let failure = error
      if didCancelHistoricalBackfill {
        await recoverCompletedBackfillAfterFailedPreemption(
          connection: connection,
          session: session
        )
      }
      throw failure
    }
  }

  func overrideCategory(
    _ categoryId: String,
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    try await setCategories([categoryId], for: message, session: session)
  }

  func setCategories(
    _ categoryIds: [String],
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    do {
      return try await syncGate.withLock(message.connectionId) {
        try await ensureConnectionIsActive(message.connectionId, session: session)
        return try await metadataService.setCategories(
          categoryIds,
          for: message.gmailMetadata,
          session: session
        ).mailboxMetadata(connectionId: message.connectionId)
      }
    } catch MailboxConnectionAdapterError.connectionRemoved {
      try await syncGate.withLock(message.connectionId) {
        try await clearRemovedConnectionState(message.connectionId, session: session)
      }
      throw MailboxConnectionAdapterError.connectionRemoved
    }
  }

  func searchProvider(
    query: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata] {
    try await withSharedProviderAccess(connection, session: session) { gmailConnection in
      try await searchService.searchProvider(
        query: query,
        connection: gmailConnection,
        session: session
      ).map { $0.mailboxMetadata(connectionId: connection.id) }
    }
  }

  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws {
    try bodyReader.clearCachedMessageBodies(session: session)
  }

  func clearCachedMessageBodies(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    try bodyReader.clearCachedMessageBodies(
      connection: try gmailConnection(connection, session: session),
      session: session
    )
  }

  func loadMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    do {
      return try await syncGate.withSharedLock(message.connectionId) {
        try await ensureConnectionIsActive(message.connectionId, session: session)
        let body = try await bodyReader.loadMessageBody(
          message: message.gmailMetadata,
          session: session
        )
        return MailboxMessageBody(
          text: body.text,
          html: body.html,
          inlineImages: body.inlineImages,
          attachments: body.attachments
        )
      }
    } catch MailboxConnectionAdapterError.connectionRemoved {
      try? await syncGate.withLock(message.connectionId) {
        try await clearRemovedConnectionState(message.connectionId, session: session)
      }
      throw MailboxConnectionAdapterError.connectionRemoved
    }
  }

  func loadMessageAttachment(
    _ attachment: MailboxMessageAttachment,
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> Data {
    do {
      return try await syncGate.withSharedLock(message.connectionId) {
        try await ensureConnectionIsActive(message.connectionId, session: session)
        return try await bodyReader.loadMessageAttachment(
          attachment,
          message: message.gmailMetadata,
          session: session
        )
      }
    } catch MailboxConnectionAdapterError.connectionRemoved {
      try? await syncGate.withLock(message.connectionId) {
        try await clearRemovedConnectionState(message.connectionId, session: session)
      }
      throw MailboxConnectionAdapterError.connectionRemoved
    }
  }

  func loadCalendarInvitation(
    _ invitation: CalendarInvitationDescriptor,
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> Data {
    do {
      return try await syncGate.withSharedLock(message.connectionId) {
        try await ensureConnectionIsActive(message.connectionId, session: session)
        return try await bodyReader.loadCalendarInvitation(
          invitation,
          message: message.gmailMetadata,
          session: session
        )
      }
    } catch MailboxConnectionAdapterError.connectionRemoved {
      try? await syncGate.withLock(message.connectionId) {
        try await clearRemovedConnectionState(message.connectionId, session: session)
      }
      throw MailboxConnectionAdapterError.connectionRemoved
    }
  }

  func loadMessageBodyText(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> String {
    do {
      return try await syncGate.withSharedLock(message.connectionId) {
        try await ensureConnectionIsActive(message.connectionId, session: session)
        return try await bodyReader.loadMessageBodyText(
          message: message.gmailMetadata,
          session: session
        )
      }
    } catch MailboxConnectionAdapterError.connectionRemoved {
      try? await syncGate.withLock(message.connectionId) {
        try await clearRemovedConnectionState(message.connectionId, session: session)
      }
      throw MailboxConnectionAdapterError.connectionRemoved
    }
  }

  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedThreadIds: Set<StableThreadIdentity>,
    referenceDate: Date,
    session: ProductAccountSessionSnapshot
  ) async throws {
    do {
      try await syncGate.withSharedLock(connection.id) {
        let gmailConnection = try await gmailConnectionForProviderAccess(
          connection,
          session: session,
          clearsRemovedConnection: false
        )
        try await bodyReader.prefetchMessageBodies(
          connection: gmailConnection,
          pinnedThreadIds: Set(
            pinnedThreadIds
              .filter { $0.connectionId == connection.id }
              .map(\.providerThreadId)
          ),
          referenceDate: referenceDate,
          session: session
        )
      }
    } catch MailboxConnectionAdapterError.connectionRemoved {
      try? await syncGate.withLock(connection.id) {
        try await clearRemovedConnectionState(connection.id, session: session)
      }
      throw MailboxConnectionAdapterError.connectionRemoved
    }
  }

  func removeCachedMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws {
    try bodyReader.removeCachedMessageBody(message: message.gmailMetadata, session: session)
  }

  func registerOrRenewPush(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await syncGate.withLock(connection.id) {
      let gmailConnection = try await gmailConnectionForProviderAccess(
        connection,
        session: session,
        connectionIsLocked: true
      )
      _ = try await pushWatchService.registerOrRenew(
        connection: gmailConnection,
        session: session
      )
    }
  }

  func perform(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await perform(
      action,
      targetProviderMailboxId: nil,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await perform(
      action,
      sourceProviderMailboxId: nil,
      targetProviderMailboxId: targetProviderMailboxId,
      targetProviderStateIds: [],
      messages: messages,
      connection: connection,
      session: session
    )
  }

  // swiftlint:disable:next function_parameter_count
  func perform(
    _ action: ProviderMailAction,
    sourceProviderMailboxId: String?,
    targetProviderMailboxId: String?,
    targetProviderStateIds _: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let selection = try await performTracked(
      action,
      sourceProviderMailboxId: sourceProviderMailboxId,
      targetProviderMailboxId: targetProviderMailboxId,
      targetProviderStateIds: [],
      messages: messages,
      connection: connection,
      session: session
    )
    if let selection {
      await pendingActionService.releaseSelection(selection)
    }
  }

  // swiftlint:disable:next function_parameter_count
  func performTracked(
    _ action: ProviderMailAction,
    sourceProviderMailboxId: String?,
    targetProviderMailboxId: String?,
    targetProviderStateIds _: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxProviderActionSelection? {
    do {
      _ = try gmailConnection(connection, session: session, requiresAuthorization: false)
      return try await pendingActionGate.withSharedLock(connection.id) {
        try await ensureConnectionIsActive(
          connection.id,
          authorizationGeneration: connection.authorizationGeneration,
          session: session
        )
        return try await pendingActionService.enqueue(
          action,
          sourceProviderMailboxId: sourceProviderMailboxId,
          targetProviderMailboxId: targetProviderMailboxId,
          messages: messages,
          connection: connection,
          session: session
        )
      }
    } catch MailboxConnectionAdapterError.connectionRemoved {
      try? await syncGate.withLock(connection.id) {
        try await clearRemovedConnectionState(connection.id, session: session)
      }
      throw MailboxConnectionAdapterError.connectionRemoved
    }
  }

  func releasePendingActionSelection(
    _ selection: MailboxProviderActionSelection,
    connection _: MailboxConnection
  ) async {
    await pendingActionService.releaseSelection(selection)
  }

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resumePendingActions(
      connections: connections,
      session: session,
      revalidateProviderAccess: { true }
    )
  }

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    return await withTaskGroup(of: (Int, String?, String).self, returning: String?.self) { group in
      for (index, connection) in connections.enumerated() {
        group.addTask {
          (
            index,
            await resumePendingActions(
              connection: connection,
              session: session,
              revalidateProviderAccess: revalidateProviderAccess
            ),
            connection.displayName
          )
        }
      }
      var indexedErrors: [(Int, String)] = []
      for await (index, error, displayName) in group {
        if let error {
          indexedErrors.append((index, "\(displayName): \(error)"))
        }
      }
      let errors = indexedErrors.sorted { $0.0 < $1.0 }.map(\.1)
      return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
  }

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await retryBlockedPendingAction(
      connection: connection,
      session: session,
      revalidateProviderAccess: { true }
    )
  }

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    await resolveBlockedPendingAction(
      connection: connection,
      session: session,
      discard: false,
      revalidateProviderAccess: revalidateProviderAccess
    )
  }

  func discardBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resolveBlockedPendingAction(connection: connection, session: session, discard: true)
  }

  func blockedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    var blockedConnectionIds: [MailboxConnectionId] = []
    for connection in connections {
      guard
        (try? await pendingActionService.hasBlockedAction(
          connection: connection,
          session: session
        )) == true
      else { continue }
      blockedConnectionIds.append(connection.id)
    }
    return blockedConnectionIds
  }

  func failedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    var failedConnectionIds: [MailboxConnectionId] = []
    for connection in connections {
      guard
        (try? await pendingActionService.hasFailedAction(
          connection: connection,
          session: session
        )) == true
      else { continue }
      failedConnectionIds.append(connection.id)
    }
    return failedConnectionIds
  }

  func pendingActionFailureDetails(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxProviderActionFailureDetail]? {
    try? await pendingActionService.failureDetails(
      action,
      messageIds: Set(messages.map(\.providerMessageId)),
      connection: connection,
      session: session
    )
  }

  func pendingActionFailureLookup(
    _ action: ProviderMailAction,
    selection: MailboxProviderActionSelection?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> MailboxProviderActionFailureLookup? {
    try? await pendingActionService.failureLookup(
      action,
      selectedActionIds: selection?.pendingActionIds,
      messageIds: Set(messages.map(\.providerMessageId)),
      connection: connection,
      session: session
    )
  }

  func waitForPendingActionRetries(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    let tasks = connections.enumerated().map { index, connection in
      Task {
        let description = await waitForPendingActionRetries(
          connection: connection,
          session: session
        )
        return (index, description.map { "\(connection.displayName): \($0)" })
      }
    }
    var indexedErrors: [(Int, String)] = []
    for task in tasks {
      let (index, error) = await task.value
      if let error {
        indexedErrors.append((index, error))
      }
    }
    let errors = indexedErrors.sorted { $0.0 < $1.0 }.map(\.1)
    return errors.isEmpty ? nil : errors.joined(separator: "\n")
  }

  func waitForPendingActionRetries(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await pendingActionService.waitForScheduledRetries(
      connection: connection,
      session: session
    )
    return try? await pendingActionService.failureDescription(
      connection: connection,
      session: session
    )
  }

  func acknowledgePendingActionFailures(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async {
    try? await pendingActionService.acknowledgeFailures(
      connection: connection,
      session: session
    )
  }

  func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resumePendingActions(
      connection: connection,
      session: session,
      revalidateProviderAccess: { true }
    )
  }

  private func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    await resumePendingActions(
      connection: connection,
      session: session,
      connectionIsLocked: false,
      revalidateProviderAccess: revalidateProviderAccess
    )
  }

  private func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    connectionIsLocked: Bool,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool = { true }
  ) async -> String? {
    var errorDescription: String?
    do {
      try await pendingActionService.resume(
        connection: connection,
        session: session,
        revalidateProviderAccess: revalidateProviderAccess
      ) { action, sourceProviderMailboxId, targetProviderMailboxId, messageIds in
        try await performProviderAction(
          try gmailAction(
            action,
            sourceProviderMailboxId: sourceProviderMailboxId,
            targetProviderMailboxId: targetProviderMailboxId
          ),
          messageIds: messageIds,
          connection: connection,
          session: session,
          connectionIsLocked: connectionIsLocked
        )
      }
    } catch is CancellationError {
      return nil
    } catch {
      errorDescription = error.localizedDescription
    }
    if let persistedDescription = try? await pendingActionService.failureDescription(
      connection: connection,
      session: session
    ) {
      errorDescription = persistedDescription
    }
    return errorDescription
  }

  private func resolveBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    discard: Bool,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool = { true }
  ) async -> String? {
    do {
      let provider = pendingActionPerformer(connection: connection, session: session)
      if discard {
        try await pendingActionService.discardBlockedAction(
          connection: connection,
          session: session,
          provider: provider
        )
      } else {
        try await pendingActionService.retryBlockedAction(
          connection: connection,
          session: session,
          revalidateProviderAccess: revalidateProviderAccess,
          provider: provider
        )
      }
      await pendingActionService.waitForScheduledRetries(
        connection: connection,
        session: session
      )
      return try await pendingActionService.failureDescription(
        connection: connection,
        session: session
      )
    } catch is CancellationError {
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private func pendingActionPerformer(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) -> PendingProviderActionPerformer {
    { action, sourceProviderMailboxId, targetProviderMailboxId, messageIds in
      try await performProviderAction(
        try gmailAction(
          action,
          sourceProviderMailboxId: sourceProviderMailboxId,
          targetProviderMailboxId: targetProviderMailboxId
        ),
        messageIds: messageIds,
        connection: connection,
        session: session,
        connectionIsLocked: false
      )
    }
  }

  func send(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    do {
      try await syncGate.withSharedLock(connection.id) {
        let gmailConnection = try await gmailConnectionForProviderAccess(
          connection,
          session: session,
          clearsRemovedConnection: false
        )
        try await mailActionService.send(
          GmailOutgoingMessage(
            body: message.body,
            recipient: message.recipient,
            subject: message.subject,
            inReplyTo: message.inReplyTo,
            threadId: message.providerThreadId,
            rfcMessageId: message.rfcMessageId,
            requestsReadReceipt: message.requestsReadReceipt == true
          ),
          connection: gmailConnection,
          session: session
        )
      }
    } catch MailboxConnectionAdapterError.connectionRemoved {
      try? await syncGate.withLock(connection.id) {
        try await clearRemovedConnectionState(connection.id, session: session)
      }
      throw MailboxConnectionAdapterError.connectionRemoved
    }
  }

  func deliveryStatus(
    idempotencyKey: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxDeliveryStatus {
    try await withSharedProviderAccess(connection, session: session) { gmailConnection in
      let rfcMessageId = OutgoingMessage.rfcMessageId(for: idempotencyKey)
      let messages = try await searchService.searchProvider(
        query: "in:sent rfc822msgid:\(rfcMessageId)",
        connection: gmailConnection,
        session: session
      )
      return messages.isEmpty ? .unknown : .sent
    }
  }

  private func withSharedProviderAccess<T>(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    requiresAuthorization: Bool = true,
    operation: (GmailProviderConnectionStatus) async throws -> T
  ) async throws -> T {
    do {
      return try await syncGate.withSharedLock(connection.id) {
        let gmailConnection = try await gmailConnectionForProviderAccess(
          connection,
          session: session,
          requiresAuthorization: requiresAuthorization,
          clearsRemovedConnection: false
        )
        return try await operation(gmailConnection)
      }
    } catch MailboxConnectionAdapterError.connectionRemoved {
      try? await syncGate.withLock(connection.id) {
        try await clearRemovedConnectionState(connection.id, session: session)
      }
      throw MailboxConnectionAdapterError.connectionRemoved
    }
  }

  private func gmailConnectionForProviderAccess(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    requiresAuthorization: Bool = true,
    clearsRemovedConnection: Bool = true,
    connectionIsLocked: Bool = false
  ) async throws -> GmailProviderConnectionStatus {
    let gmailConnection = try gmailConnection(
      connection,
      session: session,
      requiresAuthorization: requiresAuthorization
    )
    do {
      try await ensureConnectionIsActive(
        connection.id,
        authorizationGeneration: connection.authorizationGeneration,
        session: session
      )
    } catch MailboxConnectionAdapterError.connectionRemoved {
      if clearsRemovedConnection {
        if connectionIsLocked {
          try await clearRemovedConnectionState(connection.id, session: session)
        } else {
          try await syncGate.withLock(connection.id) {
            try await clearRemovedConnectionState(connection.id, session: session)
          }
        }
      }
      throw MailboxConnectionAdapterError.connectionRemoved
    }
    return gmailConnection
  }

  private func ensureConnectionIsActive(
    _ connectionId: MailboxConnectionId,
    authorizationGeneration: Int? = nil,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    if snapshot.removedConnectionIds.contains(connectionId) {
      throw MailboxConnectionAdapterError.connectionRemoved
    }
    guard let definition = snapshot.connections.first(where: { $0.id == connectionId }) else {
      return
    }
    guard
      let localConnection = try await connectionService.loadStoredConnection(
        providerAccountIdentifier: connectionId.providerMailboxIdentity.value,
        session: session
      )
    else {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    guard
      authorizationGeneration == nil
        || authorizationGeneration == definition.authorizationGeneration,
      localConnection.authorizationGeneration == definition.authorizationGeneration
    else {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
  }

  private func connectionIsRemoved(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool {
    try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
      .removedConnectionIds.contains(connectionId)
  }

  private func clearRemovedConnectionState(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws {
    guard try await connectionIsRemoved(connectionId, session: session) else {
      return
    }
    let localConnection = try? await connectionService.loadStoredConnection(
      providerAccountIdentifier: connectionId.providerMailboxIdentity.value,
      session: session
    )
    let removedConnection = removedMailboxConnection(
      id: connectionId,
      localStatus: localConnection,
      session: session
    )
    var cleanupError: Error?
    do {
      try await connectionService.clearLocalConnection(
        localConnection
          ?? gmailConnection(removedConnection, session: session, requiresAuthorization: false),
        session: session,
        allowsAccountWideCleanup: false
      )
    } catch {
      cleanupError = error
    }
    do {
      try await clearRemovedConnection(removedConnection, session: session)
    } catch {
      cleanupError = cleanupError ?? error
    }
    if let cleanupError {
      throw cleanupError
    }
  }

  private func gmailConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    requiresAuthorization: Bool = true
  ) throws -> GmailProviderConnectionStatus {
    guard connection.productAccountId == ProductAccountId(session.productAccountId) else {
      throw MailboxConnectionAdapterError.productAccountMismatch
    }
    guard connection.providerId == .gmail else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    if requiresAuthorization, connection.authorizationState != .authorized {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    return GmailProviderConnectionStatus(
      authorizationGeneration: connection.authorizationGeneration,
      connectedAt: connection.connectedAt,
      emailAddress: connection.displayName,
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.providerId.rawValue,
      providerAccountIdentifier: connection.providerMailboxIdentity.value,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
  }

  private func reconcileAndResumePendingActions(
    messages: [MailboxMessageMetadata],
    removesContradictedActions: Bool,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await pendingActionService.reconcileProviderSync(
      messages: messages,
      removesContradictedActions: removesContradictedActions,
      connection: connection,
      session: session
    )
    _ = await resumePendingActions(
      connection: connection,
      session: session,
      connectionIsLocked: true
    )
  }

  private func recoverCompletedBackfillAfterFailedPreemption(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async {
    let recovery = Task {
      try await syncGate.withLock(connection.id) {
        let gmailConnection = try await gmailConnectionForProviderAccess(
          connection,
          session: session,
          connectionIsLocked: true
        )
        let observedMessages = try await metadataService.loadMailbox(
          .allObserved,
          connection: gmailConnection,
          session: session
        )
        guard observedMessages.historicalMetadataBackfillIsComplete else { return }
        try await reconcileAndResumePendingActions(
          messages: observedMessages.messages.map {
            $0.mailboxMetadata(connectionId: connection.id)
          },
          removesContradictedActions: true,
          connection: connection,
          session: session
        )
      }
    }
    _ = try? await recovery.value
  }

  private func performProviderAction(
    _ action: GmailProviderMailAction,
    messageIds: [String],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    connectionIsLocked: Bool
  ) async throws {
    if connectionIsLocked {
      let gmailConnection = try await gmailConnectionForProviderAccess(
        connection,
        session: session,
        connectionIsLocked: true
      )
      try await mailActionService.perform(
        action,
        messageIds: messageIds,
        connection: gmailConnection,
        session: session
      )
      return
    }
    try await withSharedProviderAccess(connection, session: session) { gmailConnection in
      try await mailActionService.perform(
        action,
        messageIds: messageIds,
        connection: gmailConnection,
        session: session
      )
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  private func gmailAction(
    _ action: ProviderMailAction,
    sourceProviderMailboxId: String?,
    targetProviderMailboxId: String?
  ) throws -> GmailProviderMailAction {
    switch action {
    case .archive:
      return .archive
    case .delete:
      return .delete
    case .markRead:
      return .markRead
    case .markUnread:
      return .markUnread
    case .move:
      guard let targetProviderMailboxId, !targetProviderMailboxId.isEmpty else {
        throw MailboxConnectionAdapterError.providerMailboxTargetRequired
      }
      return .move(
        sourceProviderMailboxId: sourceProviderMailboxId ?? "INBOX",
        targetProviderMailboxId: targetProviderMailboxId
      )
    case .notSpam:
      return .notSpam
    case .restore:
      return .restore
    case .spam:
      return .spam
    case .star:
      return .star
    case .unstar:
      return .unstar
    }
  }
}

extension GmailMailboxConnectionAdapter: GmailConnectionAuthorizationChecking {
  func hasActiveAuthorization(
    _ connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool {
    guard try connectionService.hasLocalAuthorization(connection, session: session) else {
      return false
    }
    do {
      try await ensureConnectionIsActive(
        connection.mailboxConnectionId,
        authorizationGeneration: connection.authorizationGeneration,
        session: session
      )
      return true
    } catch MailboxConnectionAdapterError.connectionRemoved {
      return false
    } catch MailboxConnectionAdapterError.authorizationRequired {
      return false
    }
  }
}
