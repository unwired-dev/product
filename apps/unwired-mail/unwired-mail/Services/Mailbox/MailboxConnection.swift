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

struct MailboxThreadIdentity: Hashable, Sendable {
  let connectionId: MailboxConnectionId
  let providerThreadId: String
}

struct StableProviderMessageIdentity: Hashable, Sendable {
  let connectionId: MailboxConnectionId
  let providerMessageId: String

  var rawValue: String {
    "\(connectionId.rawValue):\(providerMessageId)"
  }
}

/// Acquires the all-connections lock before connection locks, ordered by ascending id.
/// Lock helpers are non-reentrant and must not be nested, including for the same id.
actor MailboxConnectionSyncGate {
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

  private struct Waiter {
    let continuation: CheckedContinuation<Bool, Never>
    let id: UUID
    let mode: LockMode
  }

  private var exclusivelyLockedConnectionIds: Set<MailboxConnectionId> = []
  private var sharedLockCounts: [MailboxConnectionId: Int] = [:]
  private var waiters: [MailboxConnectionId: [Waiter]] = [:]

  func acquire(_ connectionId: MailboxConnectionId) async -> Bool {
    await acquire(connectionId, mode: .exclusive)
  }

  private func acquire(_ connectionId: MailboxConnectionId, mode: LockMode) async -> Bool {
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
        waiters[connectionId, default: []].append(
          Waiter(continuation: continuation, id: waiterId, mode: mode)
        )
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterId, for: connectionId) }
    }
  }

  private func grant(_ mode: LockMode, for connectionId: MailboxConnectionId) {
    switch mode {
    case .exclusive:
      exclusivelyLockedConnectionIds.insert(connectionId)
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

struct MailboxConnectionCapabilities: Equatable, Sendable {
  let canCategorizeHistorical: Bool
  let canForward: Bool
  let canReadMessages: Bool
  let canRegisterPush: Bool
  let canReply: Bool
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
    canRegisterPush: true,
    canReply: true,
    canSearchProvider: true,
    canSend: true,
    canSynchronizeMetadata: true,
    providerActions: Set(ProviderMailAction.allCases)
  )

  static let imapRead = MailboxConnectionCapabilities(
    canCategorizeHistorical: false,
    canForward: false,
    canReadMessages: true,
    canRegisterPush: false,
    canReply: false,
    canSearchProvider: false,
    canSend: false,
    canSynchronizeMetadata: true,
    providerActions: []
  )

  static let none = MailboxConnectionCapabilities(
    canCategorizeHistorical: false,
    canForward: false,
    canReadMessages: false,
    canRegisterPush: false,
    canReply: false,
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
  case pins
  case allMail
  case allObserved
  case providerMailbox(String)

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

  func contains(providerStateIds: [String]?, isPinned: Bool = false) -> Bool {
    let states = Set(providerStateIds ?? ["INBOX"])
    switch self {
    case .role(.inbox):
      return states.contains("INBOX")
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
  let authorizationState: MailboxAuthorizationState
  let capabilities: MailboxConnectionCapabilities
  let connectedAt: Int64
  let displayName: String
  let id: MailboxConnectionId
  let lastVerifiedAt: Int64
  let productAccountId: ProductAccountId
  let trustedDeviceId: String
  let updatedAt: Int64

  var providerId: MailProviderId {
    id.providerId
  }

  var providerMailboxIdentity: StableProviderMailboxIdentity {
    id.providerMailboxIdentity
  }
}

extension GmailProviderConnectionStatus {
  func mailboxConnection(productAccountId: String) -> MailboxConnection {
    let providerId = MailProviderId(rawValue: provider)
    let providerMailboxIdentity = StableProviderMailboxIdentity(
      providerId: providerId,
      value: providerAccountIdentifier
    )
    return MailboxConnection(
      authorizationState: .authorized,
      capabilities: providerId == .gmail
        ? .gmail
        : .none,
      connectedAt: connectedAt,
      displayName: emailAddress,
      id: MailboxConnectionId(
        providerMailboxIdentity: providerMailboxIdentity
      ),
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

struct MailboxMessageBody: Equatable, Sendable {
  let text: String
}

struct MailboxMessageMetadata: Equatable, Identifiable, Sendable {
  let categoryId: String?
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
  var bccRecipients: [String]? = .none

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

  func belongs(to role: MailboxRole) -> Bool {
    MailboxMessageCollection.role(role).contains(providerStateIds: providerStateIds)
  }
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
          message.categoryId,
          message.categoryId.flatMap { categoryNamesById[$0] },
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
  let hasUnlistedNewMessages: Bool
  let hasInitialMailboxAvailability: Bool
  let historicalMetadataBackfillIsComplete: Bool
  let messages: [MailboxMessageMetadata]
  let newMessageIds: Set<String>?
  let providerCursorIsExpired: Bool
  let threads: [MailboxThread]

  init(
    hasUnlistedNewMessages: Bool,
    messages: [MailboxMessageMetadata],
    newMessageIds: Set<String>?,
    providerCursorIsExpired: Bool,
    threads: [MailboxThread],
    hasInitialMailboxAvailability: Bool = true,
    historicalMetadataBackfillIsComplete: Bool = true
  ) {
    self.hasUnlistedNewMessages = hasUnlistedNewMessages
    self.hasInitialMailboxAvailability = hasInitialMailboxAvailability
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
      hasUnlistedNewMessages: hasUnlistedNewMessages,
      messages: messages,
      newMessageIds: newMessageIds,
      providerCursorIsExpired: providerCursorIsExpired,
      threads: MailboxThread.group(messages),
      hasInitialMailboxAvailability: hasInitialMailboxAvailability,
      historicalMetadataBackfillIsComplete: historicalMetadataBackfillIsComplete
    )
  }

  func projected(
    to collection: MailboxMessageCollection,
    pinnedMessageIds: Set<StableProviderMessageIdentity> = []
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
          isPinned: pinnedMessageIds.contains($0.id)
        )
      }
      .sorted(by: Self.messagesAreOrdered)
    let visibleThreadIds = Set(visibleMessages.map(\.threadIdentity))
    let visibleThreads = MailboxThread.group(Array(observedMessages))
      .filter { visibleThreadIds.contains($0.id) }
    return MailboxMetadataSyncResult(
      hasUnlistedNewMessages: hasUnlistedNewMessages,
      messages: visibleMessages,
      newMessageIds: newMessageIds,
      providerCursorIsExpired: providerCursorIsExpired,
      threads: visibleThreads,
      hasInitialMailboxAvailability: hasInitialMailboxAvailability,
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
      bccRecipients: bccRecipients
    )
  }
}

extension MailboxMessageMetadata {
  var gmailMetadata: GmailMessageMetadata {
    GmailMessageMetadata(
      categoryId: categoryId,
      from: from,
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
      rfcMessageId: rfcMessageId
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
      hasUnlistedNewMessages: hasUnlistedNewMessages,
      messages: messages,
      newMessageIds: newMessageIds,
      providerCursorIsExpired: historyIsExpired,
      threads: threads,
      hasInitialMailboxAvailability: hasInitialMailboxAvailability,
      historicalMetadataBackfillIsComplete: historicalMetadataBackfillIsComplete
    )
  }
}

extension HistoricalCategorizationScope {
  var gmailScope: GmailHistoricalCategorizationScope {
    GmailHistoricalCategorizationScope(
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
    sourceProviderMessageId: String? = nil,
    idempotencyKey: String? = nil
  ) {
    self.body = body
    self.idempotencyKey = idempotencyKey
    self.kind = kind
    self.recipient = recipient
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

  func overrideCategory(
    _ categoryId: String,
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
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
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

  func removeCachedMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws
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

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String?

  func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String?

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
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

protocol MailboxConnectionAdapter:
  MailboxConnectionManaging, MailboxMetadataSyncing, MailboxMessageSearching,
  MailboxMessageBodyPrefetching, MailboxMessageReading, MailboxPushRegistering,
  MailboxProviderMailActing
{}

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

// swiftlint:disable:next type_body_length
struct GmailMailboxConnectionAdapter: MailboxConnectionAdapter {
  private let bodyReader: GmailMessageReading
  private let connectionService: GmailProviderConnecting
  private let credentialVerifier: GmailProviderCredentialVerifying
  private let definitionSyncService: MailboxConnectionDefinitionSyncing
  private let mailActionService: GmailProviderMailActing
  private let metadataService: GmailMessageMetadataSyncing
  private let oauthAuthorizer: GmailOAuthAuthorizing
  private let pushWatchService: GmailPushWatchRegistering
  private let pendingActionService: PendingProviderActionService
  private let outboxService: OutboxDeliveryService
  private let searchService: GmailMessageSearching
  private let syncGate: MailboxConnectionSyncGate

  init(
    bodyReader: GmailMessageReading = GmailMessageBodyService(),
    connectionService: GmailProviderConnecting = GmailProviderConnectionService(),
    credentialVerifier: GmailProviderCredentialVerifying =
      GoogleGmailProviderCredentialVerifier(),
    definitionSyncService: MailboxConnectionDefinitionSyncing = MailboxConnectionSyncService(),
    mailActionService: GmailProviderMailActing = GmailMessageMetadataService(),
    metadataService: GmailMessageMetadataSyncing = GmailMessageMetadataService(),
    oauthAuthorizer: GmailOAuthAuthorizing = GoogleGmailOAuthService(),
    pushWatchService: GmailPushWatchRegistering = GmailPushWatchService(),
    pendingActionService: PendingProviderActionService = .shared,
    outboxService: OutboxDeliveryService = .shared,
    searchService: GmailMessageSearching = GmailMessageMetadataService(),
    syncGate: MailboxConnectionSyncGate = .shared
  ) {
    self.bodyReader = bodyReader
    self.connectionService = connectionService
    self.credentialVerifier = credentialVerifier
    self.definitionSyncService = definitionSyncService
    self.mailActionService = mailActionService
    self.metadataService = metadataService
    self.oauthAuthorizer = oauthAuthorizer
    self.pushWatchService = pushWatchService
    self.pendingActionService = pendingActionService
    self.outboxService = outboxService
    self.searchService = searchService
    self.syncGate = syncGate
  }

  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws {
    try await clearLocalConnection(session: session, isStillCurrent: { true })
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
      do {
        try await outboxService.clear(session: session)
      } catch {
        firstError = firstError ?? error
      }
      if let firstError {
        throw firstError
      }
    }
    try await syncGate.withAllConnectionsLocked(operation: cleanup)
  }

  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await syncGate.withAllConnectionsLocked {
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

  @MainActor
  // swiftlint:disable:next function_body_length
  func connect(
    expectedConnectionId: MailboxConnectionId?,
    session: ProductAccountSessionSnapshot,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection? {
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
      let hadExistingConnection =
        try await connectionService.loadStoredConnection(
          providerAccountIdentifier: verifiedAccount.providerAccountIdentifier,
          session: session
        ) != nil
        || connectionService.hasLocalAuthorization(
          providerAccountIdentifier: verifiedAccount.providerAccountIdentifier,
          session: session
        )

      let status = try await connectionService.completeConnection(
        verifiedAccount: VerifiedGmailAccount(
          emailAddress: verifiedAccount.emailAddress,
          providerAccountIdentifier: verifiedAccount.providerAccountIdentifier,
          tokens: GmailProviderTokens(
            accessToken: verifiedAccount.tokens.accessToken,
            refreshToken: verifiedAccount.tokens.refreshToken,
            idToken: authorizedTokens.idToken
          )
        ),
        session: session
      )
      let connection = status.mailboxConnection(productAccountId: session.productAccountId)
      do {
        _ = try await definitionSyncService.saveConnection(connection, session: session)
        return connection
      } catch {
        if !hadExistingConnection {
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

  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    let localStatuses = try await syncGate.withAllConnectionsLocked {
      try await connectionService.loadConnections(session: session)
    }
    let localConnections = localStatuses.map {
      $0.mailboxConnection(productAccountId: session.productAccountId)
    }
    let localStatusesById = Dictionary(
      localStatuses.map { status in
        (
          status.mailboxConnection(productAccountId: session.productAccountId).id,
          status
        )
      },
      uniquingKeysWith: { first, _ in first }
    )
    guard
      let (snapshot, usedCachedSnapshot) = try await reconciledSnapshot(
        localConnections: localConnections,
        session: session
      )
    else { return localConnections }
    try await clearRemovedConnections(
      snapshot.removedConnectionIds,
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
        if let localStatus = localStatusesById[definition.id] {
          return localStatus.mailboxConnection(productAccountId: session.productAccountId)
        }
        return definition.mailboxConnection(
          productAccountId: session.productAccountId,
          trustedDeviceId: session.trustedDeviceId
        )
      }
  }

  private func clearRemovedConnections(
    _ removedConnectionIds: [MailboxConnectionId],
    localStatusesById: [MailboxConnectionId: GmailProviderConnectionStatus],
    session: ProductAccountSessionSnapshot
  ) async throws {
    var firstError: Error?
    for removedConnectionId in removedConnectionIds where removedConnectionId.providerId == .gmail {
      do {
        try await syncGate.withAllConnectionsLocked {
          guard try await connectionIsRemoved(removedConnectionId, session: session) else {
            return
          }
          let localStatus = try localStatusForCleanup(
            id: removedConnectionId,
            authorizedStatusesById: localStatusesById,
            session: session
          )
          let removedConnection = removedMailboxConnection(
            id: removedConnectionId,
            localStatus: localStatus,
            session: session
          )
          var cleanupError: Error?
          do {
            try await connectionService.clearLocalConnection(
              localStatus
                ?? gmailConnection(
                  removedConnection,
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
            try await clearRemovedConnection(removedConnection, session: session)
          } catch {
            cleanupError = cleanupError ?? error
          }
          if let cleanupError {
            throw cleanupError
          }
        }
      } catch {
        firstError = firstError ?? error
      }
    }
    if let firstError {
      throw firstError
    }
  }

  private func localStatusForCleanup(
    id: MailboxConnectionId,
    authorizedStatusesById: [MailboxConnectionId: GmailProviderConnectionStatus],
    session: ProductAccountSessionSnapshot
  ) throws -> GmailProviderConnectionStatus? {
    if let authorizedStatus = authorizedStatusesById[id] {
      return authorizedStatus
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
      return localStatus.mailboxConnection(productAccountId: session.productAccountId)
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
      _ = try await definitionSyncService.removeConnection(connection.id, session: session)
      try await clearRemovedConnection(connection, session: session)
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
    let gmailConnection = try await gmailConnectionForProviderAccess(
      connection,
      session: session
    )
    let result = try await metadataService.loadMailbox(
      .allObserved,
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

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let gmailConnection = try await gmailConnectionForProviderAccess(
      connection,
      session: session
    )
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
    try await syncGate.withLock(connection.id) {
      try Task.checkCancellation()
      let result = try await metadataService.continueHistoricalBackfill(
        connection: try await gmailConnectionForProviderAccess(
          connection,
          session: session,
          connectionIsLocked: true
        ),
        session: session
      )
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
      _ = try await metadataService.syncInbox(
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
    try await syncGate.withLock(connection.id) {
      try Task.checkCancellation()
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
        messages: observedMessages.messages.map { $0.mailboxMetadata(connectionId: connection.id) },
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
        historicalMetadataBackfillIsComplete: projectedInbox.historicalMetadataBackfillIsComplete
      )
    }
  }

  func overrideCategory(
    _ categoryId: String,
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    do {
      return try await syncGate.withSharedLock(message.connectionId) {
        try await ensureConnectionIsActive(message.connectionId, session: session)
        return try await metadataService.overrideCategory(
          categoryId,
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
        return MailboxMessageBody(text: body.text)
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
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
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
          pinnedMessageIds: Set(pinnedMessageIds.map(\.rawValue)),
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
    try await withSharedProviderAccess(
      connection,
      session: session,
      requiresAuthorization: false
    ) { _ in
      try await pendingActionService.enqueue(
        action,
        targetProviderMailboxId: targetProviderMailboxId,
        messages: messages,
        connection: connection,
        session: session
      )
    }
  }

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    return await withTaskGroup(of: (Int, String?, String).self, returning: String?.self) { group in
      for (index, connection) in connections.enumerated() {
        group.addTask {
          (
            index,
            await resumePendingActions(connection: connection, session: session),
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
    await resolveBlockedPendingAction(connection: connection, session: session, discard: false)
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
      connectionIsLocked: false
    )
  }

  private func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    connectionIsLocked: Bool
  ) async -> String? {
    var errorDescription: String?
    do {
      try await pendingActionService.resume(
        connection: connection,
        session: session
      ) { action, targetProviderMailboxId, messageIds in
        try await performProviderAction(
          try gmailAction(action, targetProviderMailboxId: targetProviderMailboxId),
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
    discard: Bool
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
    { action, targetProviderMailboxId, messageIds in
      try await performProviderAction(
        try gmailAction(action, targetProviderMailboxId: targetProviderMailboxId),
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
            rfcMessageId: message.rfcMessageId
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
      try await ensureConnectionIsActive(connection.id, session: session)
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
    session: ProductAccountSessionSnapshot
  ) async throws {
    if try await connectionIsRemoved(connectionId, session: session) {
      throw MailboxConnectionAdapterError.connectionRemoved
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
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await pendingActionService.reconcileProviderSync(
      messages: messages,
      connection: connection,
      session: session
    )
    _ = await resumePendingActions(
      connection: connection,
      session: session,
      connectionIsLocked: true
    )
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
      return .move(targetProviderMailboxId: targetProviderMailboxId)
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
