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

actor MailboxConnectionSyncGate {
  static let shared = MailboxConnectionSyncGate()

  private typealias Waiter = (id: UUID, continuation: CheckedContinuation<Bool, Never>)

  private var lockedConnectionIds: Set<MailboxConnectionId> = []
  private var waiters: [MailboxConnectionId: [Waiter]] = [:]

  func acquire(_ connectionId: MailboxConnectionId) async -> Bool {
    guard lockedConnectionIds.contains(connectionId) else {
      lockedConnectionIds.insert(connectionId)
      return true
    }
    let waiterId = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        waiters[connectionId, default: []].append((waiterId, continuation))
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterId, for: connectionId) }
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
    guard var connectionWaiters = waiters[connectionId], !connectionWaiters.isEmpty else {
      lockedConnectionIds.remove(connectionId)
      waiters[connectionId] = nil
      return
    }
    let next = connectionWaiters.removeFirst().continuation
    waiters[connectionId] = connectionWaiters.isEmpty ? nil : connectionWaiters
    next.resume(returning: true)
  }

  func withLock<T>(
    _ connectionId: MailboxConnectionId,
    operation: () async throws -> T
  ) async throws -> T {
    guard await acquire(connectionId) else {
      throw CancellationError()
    }
    defer { release(connectionId) }
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
      return !states.contains(where: { $0.hasPrefix("imap-mailbox:") })
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
  let title: String
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

struct OutgoingMessage: Codable, Equatable, Sendable {
  let body: String
  let idempotencyKey: String?
  let recipient: String
  let subject: String
  let inReplyTo: String?
  let providerThreadId: String?

  init(
    body: String,
    recipient: String,
    subject: String,
    inReplyTo: String? = nil,
    providerThreadId: String? = nil,
    idempotencyKey: String? = nil
  ) {
    self.body = body
    self.idempotencyKey = idempotencyKey
    self.recipient = recipient
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
      providerThreadId: providerThreadId,
      idempotencyKey: idempotencyKey
    )
  }
}

protocol MailboxConnectionClearing {
  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws
  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws
}

extension MailboxConnectionClearing {
  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
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

  func loadConnection(
    session: ProductAccountSessionSnapshot
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

  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    if let connection = try await loadConnection(session: session) {
      return [connection]
    }
    return []
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

extension MailboxMessageReading {
  func clearCachedMessageBodies(
    connection _: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    try clearCachedMessageBodies(session: session)
  }
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
      return "Sign in to the Google account for the selected Mailbox Connection."
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
    self.searchService = searchService
    self.syncGate = syncGate
  }

  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws {
    var firstError: Error?
    do {
      try await connectionService.clearLocalConnection(session: session)
    } catch {
      firstError = error
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

  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    var firstError: Error?
    do {
      try await connectionService.clearLocalConnection(
        try gmailConnection(connection, session: session),
        session: session
      )
    } catch {
      firstError = error
    }
    do {
      try await pendingActionService.clear(connection: connection, session: session)
    } catch {
      firstError = firstError ?? error
    }
    if let firstError {
      throw firstError
    }
  }

  @MainActor
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
    let hadExistingConnection = try await connectionService.loadConnections(session: session)
      .contains {
        $0.mailboxConnection(productAccountId: session.productAccountId).id == verifiedConnectionId
      }

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
        try await connectionService.clearLocalConnection(status, session: session)
      }
      throw error
    }
  }

  func loadConnection(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnection? {
    try await loadConnections(session: session).first
  }

  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    let localStatuses = try await connectionService.loadConnections(session: session)
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
    for removedConnectionId in snapshot.removedConnectionIds {
      guard let localStatus = localStatusesById[removedConnectionId] else { continue }
      let removedConnection = localStatus.mailboxConnection(
        productAccountId: session.productAccountId
      )
      try await connectionService.clearLocalConnection(localStatus, session: session)
      try await pendingActionService.clear(connection: removedConnection, session: session)
    }
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
    let gmailStatus = try gmailConnection(
      connection, session: session, requiresAuthorization: false)
    try await connectionService.clearLocalConnection(gmailStatus, session: session)
    _ = try await definitionSyncService.removeConnection(connection.id, session: session)
    try await pendingActionService.clear(connection: connection, session: session)
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
    let gmailConnection = try await gmailConnectionForProviderAccess(
      connection,
      session: session
    )
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
    let gmailConnection = try await gmailConnectionForProviderAccess(
      connection,
      session: session
    )
    return try await metadataService.loadProviderMailboxes(
      connection: gmailConnection,
      session: session
    )
  }

  func continueHistoricalBackfill(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await syncGate.withLock(connection.id) {
      try Task.checkCancellation()
      let result = try await metadataService.continueHistoricalBackfill(
        connection: try await gmailConnectionForProviderAccess(connection, session: session),
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
        session: session
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
        session: session
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
    try await ensureConnectionIsActive(message.connectionId, session: session)
    return try await metadataService.overrideCategory(
      categoryId,
      for: message.gmailMetadata,
      session: session
    ).mailboxMetadata(connectionId: message.connectionId)
  }

  func searchProvider(
    query: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata] {
    let gmailConnection = try await gmailConnectionForProviderAccess(
      connection,
      session: session
    )
    return try await searchService.searchProvider(
      query: query,
      connection: gmailConnection,
      session: session
    ).map { $0.mailboxMetadata(connectionId: connection.id) }
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
    try await ensureConnectionIsActive(message.connectionId, session: session)
    let body = try await bodyReader.loadMessageBody(
      message: message.gmailMetadata,
      session: session
    )
    return MailboxMessageBody(text: body.text)
  }

  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
    referenceDate: Date,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let gmailConnection = try await gmailConnectionForProviderAccess(
      connection,
      session: session
    )
    try await bodyReader.prefetchMessageBodies(
      connection: gmailConnection,
      pinnedMessageIds: Set(pinnedMessageIds.map(\.rawValue)),
      referenceDate: referenceDate,
      session: session
    )
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
    let gmailConnection = try await gmailConnectionForProviderAccess(
      connection,
      session: session
    )
    _ = try await pushWatchService.registerOrRenew(
      connection: gmailConnection,
      session: session
    )
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
    _ = try await gmailConnectionForProviderAccess(
      connection,
      session: session,
      requiresAuthorization: false
    )
    try await pendingActionService.enqueue(
      action,
      targetProviderMailboxId: targetProviderMailboxId,
      messages: messages,
      connection: connection,
      session: session
    )
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
    var errorDescription: String?
    do {
      try await pendingActionService.resume(
        connection: connection,
        session: session
      ) { action, targetProviderMailboxId, messageIds in
        try await performProviderAction(
          action,
          targetProviderMailboxId: targetProviderMailboxId,
          messageIds: messageIds,
          connection: connection,
          session: session
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
        action,
        targetProviderMailboxId: targetProviderMailboxId,
        messageIds: messageIds,
        connection: connection,
        session: session
      )
    }
  }

  func send(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let gmailConnection = try await gmailConnectionForProviderAccess(
      connection,
      session: session
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

  func deliveryStatus(
    idempotencyKey: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxDeliveryStatus {
    let gmailConnection = try await gmailConnectionForProviderAccess(
      connection,
      session: session
    )
    let rfcMessageId = OutgoingMessage.rfcMessageId(for: idempotencyKey)
    let messages = try await searchService.searchProvider(
      query: "in:sent rfc822msgid:\(rfcMessageId)",
      connection: gmailConnection,
      session: session
    )
    return messages.isEmpty ? .notSent : .sent
  }

  private func gmailConnectionForProviderAccess(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    requiresAuthorization: Bool = true
  ) async throws -> GmailProviderConnectionStatus {
    let gmailConnection = try gmailConnection(
      connection,
      session: session,
      requiresAuthorization: requiresAuthorization
    )
    do {
      try await ensureConnectionIsActive(connection.id, session: session)
    } catch MailboxConnectionAdapterError.connectionRemoved {
      try await pendingActionService.clear(connection: connection, session: session)
      throw MailboxConnectionAdapterError.connectionRemoved
    }
    return gmailConnection
  }

  private func ensureConnectionIsActive(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(
      session: session
    )
    if snapshot.removedConnectionIds.contains(connectionId) {
      if let localConnection = try await connectionService.loadConnections(session: session)
        .first(where: { status in
          status.provider == connectionId.providerId.rawValue
            && status.providerAccountIdentifier
              == connectionId.providerMailboxIdentity.value
        })
      {
        try await connectionService.clearLocalConnection(localConnection, session: session)
      }
      throw MailboxConnectionAdapterError.connectionRemoved
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
    _ = await resumePendingActions(connections: [connection], session: session)
  }

  private func performProviderAction(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    messageIds: [String],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let gmailConnection = try await gmailConnectionForProviderAccess(
      connection,
      session: session
    )
    try await mailActionService.perform(
      try gmailAction(action, targetProviderMailboxId: targetProviderMailboxId),
      messageIds: messageIds,
      connection: gmailConnection,
      session: session
    )
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
