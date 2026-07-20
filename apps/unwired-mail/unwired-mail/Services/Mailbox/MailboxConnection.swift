import Foundation

// swiftlint:disable file_length

struct ProductAccountId: Hashable, RawRepresentable, Sendable {
  let rawValue: String

  init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  init(rawValue: String) {
    self.rawValue = rawValue
  }
}

struct MailProviderId: Hashable, RawRepresentable, Sendable {
  static let gmail = MailProviderId(rawValue: "gmail")

  let rawValue: String
}

struct StableProviderMailboxIdentity: Hashable, Sendable {
  let providerId: MailProviderId
  let value: String
}

struct MailboxConnectionId: Hashable, Sendable {
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

enum ProviderMailAction: CaseIterable, Hashable, Sendable {
  case archive
  case delete
  case markRead
  case markUnread
  case star
  case unstar
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
}

struct MailboxConnection: Equatable, Identifiable, Sendable {
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
      capabilities: providerId == .gmail
        ? .gmail
        : MailboxConnectionCapabilities(
          canCategorizeHistorical: false,
          canForward: false,
          canReadMessages: false,
          canRegisterPush: false,
          canReply: false,
          canSearchProvider: false,
          canSend: false,
          canSynchronizeMetadata: false,
          providerActions: []
        ),
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

  private static func dateText(for milliseconds: Int64) -> String {
    let formatter = DateFormatter()
    formatter.calendar = .current
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    return formatter.string(
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
  let messages: [MailboxMessageMetadata]
  let newMessageIds: Set<String>?
  let providerCursorIsExpired: Bool
  let threads: [MailboxThread]
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
      subject: subject
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
      rfcMessageId: rfcMessageId
    )
  }
}

extension GmailMetadataSyncResult {
  func mailboxResult(connectionId: MailboxConnectionId) -> MailboxMetadataSyncResult {
    let messages = messages.map { $0.mailboxMetadata(connectionId: connectionId) }
    return MailboxMetadataSyncResult(
      hasUnlistedNewMessages: hasUnlistedNewMessages,
      messages: messages,
      newMessageIds: newMessageIds,
      providerCursorIsExpired: historyIsExpired,
      threads: MailboxThread.group(messages)
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

struct OutgoingMessage: Equatable, Sendable {
  let body: String
  let recipient: String
  let subject: String
  let inReplyTo: String?
  let providerThreadId: String?

  init(
    body: String,
    recipient: String,
    subject: String,
    inReplyTo: String? = nil,
    providerThreadId: String? = nil
  ) {
    self.body = body
    self.recipient = recipient
    self.subject = subject
    self.inReplyTo = inReplyTo
    self.providerThreadId = providerThreadId
  }
}

protocol MailboxConnectionClearing {
  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws
}

protocol MailboxConnectionManaging: MailboxConnectionClearing {
  @MainActor
  func connect(
    session: ProductAccountSessionSnapshot,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection?

  func loadConnection(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnection?
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

protocol MailboxMessageSearching {
  func searchProvider(
    query: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata]
}

protocol MailboxMessageReading {
  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws

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
  func perform(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws

  func send(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws
}

protocol MailboxConnectionAdapter:
  MailboxConnectionManaging, MailboxMetadataSyncing, MailboxMessageSearching,
  MailboxMessageReading, MailboxPushRegistering, MailboxProviderMailActing
{}

enum MailboxConnectionAdapterError: LocalizedError, Equatable {
  case productAccountMismatch
  case unsupportedProvider

  var errorDescription: String? {
    switch self {
    case .productAccountMismatch:
      return "The mailbox connection does not belong to the current Product Account."
    case .unsupportedProvider:
      return "The selected mail provider is not supported by this adapter."
    }
  }
}

struct GmailMailboxConnectionAdapter: MailboxConnectionAdapter {
  private let bodyReader: GmailMessageReading
  private let connectionService: GmailProviderConnecting
  private let credentialVerifier: GmailProviderCredentialVerifying
  private let mailActionService: GmailProviderMailActing
  private let metadataService: GmailMessageMetadataSyncing
  private let oauthAuthorizer: GmailOAuthAuthorizing
  private let pushWatchService: GmailPushWatchRegistering
  private let searchService: GmailMessageSearching

  init(
    bodyReader: GmailMessageReading = GmailMessageBodyService(),
    connectionService: GmailProviderConnecting = GmailProviderConnectionService(),
    credentialVerifier: GmailProviderCredentialVerifying =
      GoogleGmailProviderCredentialVerifier(),
    mailActionService: GmailProviderMailActing = GmailMessageMetadataService(),
    metadataService: GmailMessageMetadataSyncing = GmailMessageMetadataService(),
    oauthAuthorizer: GmailOAuthAuthorizing = GoogleGmailOAuthService(),
    pushWatchService: GmailPushWatchRegistering = GmailPushWatchService(),
    searchService: GmailMessageSearching = GmailMessageMetadataService()
  ) {
    self.bodyReader = bodyReader
    self.connectionService = connectionService
    self.credentialVerifier = credentialVerifier
    self.mailActionService = mailActionService
    self.metadataService = metadataService
    self.oauthAuthorizer = oauthAuthorizer
    self.pushWatchService = pushWatchService
    self.searchService = searchService
  }

  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws {
    try await connectionService.clearLocalConnection(session: session)
  }

  @MainActor
  func connect(
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
    return status.mailboxConnection(productAccountId: session.productAccountId)
  }

  func loadConnection(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnection? {
    try await connectionService.loadConnection(session: session)?.mailboxConnection(
      productAccountId: session.productAccountId
    )
  }

  func categorizeHistorical(
    scope: HistoricalCategorizationScope,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let result = try await metadataService.categorizeHistorical(
      scope: scope.gmailScope,
      connection: try gmailConnection(connection, session: session),
      session: session
    )
    return result.mailboxResult(connectionId: connection.id)
  }

  func loadInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let result = try await metadataService.loadInbox(
      connection: try gmailConnection(connection, session: session),
      session: session
    )
    return result.mailboxResult(connectionId: connection.id)
  }

  func syncInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let result = try await metadataService.syncInbox(
      connection: try gmailConnection(connection, session: session),
      session: session
    )
    return result.mailboxResult(connectionId: connection.id)
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
    let result = try await metadataService.syncRecentInbox(
      connection: try gmailConnection(connection, session: session),
      includingHistoryCandidates: includingHistoryCandidates,
      session: session,
      sinceHistoryId: sinceHistoryId,
      throughHistoryId: throughHistoryId,
      shouldPersist: shouldPersist
    )
    return result.mailboxResult(connectionId: connection.id)
  }

  func overrideCategory(
    _ categoryId: String,
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    try await metadataService.overrideCategory(
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
    try await searchService.searchProvider(
      query: query,
      connection: try gmailConnection(connection, session: session),
      session: session
    ).map { $0.mailboxMetadata(connectionId: connection.id) }
  }

  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws {
    try bodyReader.clearCachedMessageBodies(session: session)
  }

  func loadMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    let body = try await bodyReader.loadMessageBody(
      message: message.gmailMetadata,
      session: session
    )
    return MailboxMessageBody(text: body.text)
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
    _ = try await pushWatchService.registerOrRenew(
      connection: try gmailConnection(connection, session: session),
      session: session
    )
  }

  func perform(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await mailActionService.perform(
      gmailAction(action),
      messageIds: messages.map(\.providerMessageId),
      connection: try gmailConnection(connection, session: session),
      session: session
    )
  }

  func send(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await mailActionService.send(
      GmailOutgoingMessage(
        body: message.body,
        recipient: message.recipient,
        subject: message.subject,
        inReplyTo: message.inReplyTo,
        threadId: message.providerThreadId
      ),
      connection: try gmailConnection(connection, session: session),
      session: session
    )
  }

  private func gmailConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws -> GmailProviderConnectionStatus {
    guard connection.productAccountId == ProductAccountId(session.productAccountId) else {
      throw MailboxConnectionAdapterError.productAccountMismatch
    }
    guard connection.providerId == .gmail else {
      throw MailboxConnectionAdapterError.unsupportedProvider
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

  private func gmailAction(_ action: ProviderMailAction) -> GmailProviderMailAction {
    switch action {
    case .archive:
      return .archive
    case .delete:
      return .delete
    case .markRead:
      return .markRead
    case .markUnread:
      return .markUnread
    case .star:
      return .star
    case .unstar:
      return .unstar
    }
  }
}
