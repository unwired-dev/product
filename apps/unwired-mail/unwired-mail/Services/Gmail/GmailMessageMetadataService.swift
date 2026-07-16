import Foundation

// swiftlint:disable file_length type_body_length

struct GmailMessageMetadata: Codable, Equatable, Identifiable {
  var id: String {
    stableProviderMessageId
  }

  let categoryId: String?
  let from: String?
  let isHistorical: Bool
  let providerAccountIdentifier: String
  let providerInternalDateMilliseconds: Int64
  let providerMessageId: String
  let providerThreadId: String
  let replyTo: String?
  let snippet: String
  let stableProviderMessageId: String
  let subject: String
  let rfcMessageId: String?
}

struct GmailInboxThread: Equatable, Identifiable {
  var id: String {
    providerThreadId
  }

  let latestMessage: GmailMessageMetadata
  let messages: [GmailMessageMetadata]
  let providerThreadId: String
}

struct GmailMetadataSyncResult: Equatable {
  let hasUnlistedNewMessages: Bool
  let messages: [GmailMessageMetadata]
  let newMessageIds: Set<String>?
  let threads: [GmailInboxThread]

  init(
    hasUnlistedNewMessages: Bool = false,
    messages: [GmailMessageMetadata],
    newMessageIds: Set<String>? = nil,
    threads: [GmailInboxThread]
  ) {
    self.hasUnlistedNewMessages = hasUnlistedNewMessages
    self.messages = messages
    self.newMessageIds = newMessageIds
    self.threads = threads
  }
}

protocol GmailMessageMetadataPersisting {
  func clearMessages(productAccountId: String) throws

  func loadMessages(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> [GmailMessageMetadata]

  func saveMessages(
    _ messages: [GmailMessageMetadata],
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws
}

protocol GmailMessageMetadataSyncing {
  func categorizeHistorical(
    scope: GmailHistoricalCategorizationScope,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult

  func loadInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult

  func syncInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult

  func syncRecentInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId: String?,
    throughHistoryId: String?,
    shouldPersist: @escaping () -> Bool
  ) async throws -> GmailMetadataSyncResult

  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata
}

extension GmailMessageMetadataSyncing {
  func syncRecentInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    try await syncRecentInbox(
      connection: connection,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )
  }
}

enum GmailProviderMailAction: Equatable {
  case archive
  case delete
  case markRead
  case markUnread
  case star
  case unstar
}

struct GmailOutgoingMessage: Equatable {
  let body: String
  let recipient: String
  let subject: String
  let inReplyTo: String?
  let threadId: String?

  init(
    body: String,
    recipient: String,
    subject: String,
    inReplyTo: String? = nil,
    threadId: String? = nil
  ) {
    self.body = body
    self.recipient = recipient
    self.subject = subject
    self.inReplyTo = inReplyTo
    self.threadId = threadId
  }
}

protocol GmailProviderMailActing {
  func perform(
    _ action: GmailProviderMailAction,
    messageIds: [String],
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws

  func send(
    _ message: GmailOutgoingMessage,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws
}

struct FileGmailMessageMetadataStore: GmailMessageMetadataPersisting {
  private let fileManager: FileManager
  private let rootDirectory: URL

  init(
    fileManager: FileManager = .default,
    rootDirectory: URL? = nil
  ) {
    self.fileManager = fileManager
    self.rootDirectory =
      rootDirectory
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("UnwiredMail/GmailMetadata", isDirectory: true)
  }

  func clearMessages(productAccountId: String) throws {
    guard fileManager.fileExists(atPath: rootDirectory.path) else {
      return
    }

    let prefix = "\(gmailSafeFileComponent(productAccountId))-"
    let fileURLs = try fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: nil
    )
    for fileURL in fileURLs where fileURL.lastPathComponent.hasPrefix(prefix) {
      try fileManager.removeItem(at: fileURL)
    }
  }

  func loadMessages(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> [GmailMessageMetadata] {
    let fileURL = metadataFileURL(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return []
    }

    let data = try Data(contentsOf: fileURL)
    return try JSONDecoder().decode([GmailMessageMetadata].self, from: data)
  }

  func saveMessages(
    _ messages: [GmailMessageMetadata],
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    try fileManager.createDirectory(
      at: rootDirectory,
      withIntermediateDirectories: true
    )
    let fileURL = metadataFileURL(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    let data = try JSONEncoder().encode(messages)
    try data.write(to: fileURL, options: [.atomic])
  }

  private func metadataFileURL(
    productAccountId: String,
    providerAccountIdentifier: String
  ) -> URL {
    rootDirectory.appendingPathComponent(
      "\(gmailSafeFileComponent(productAccountId))-\(gmailSafeFileComponent(providerAccountIdentifier)).json"
    )
  }
}

func gmailSafeFileComponent(_ value: String) -> String {
  value
    .map { character in
      character.isLetter || character.isNumber || character == "-" ? character : "_"
    }
    .reduce(into: "") { partialResult, character in
      partialResult.append(character)
    }
}

struct GmailMessageMetadataService:
  GmailMessageMetadataSyncing, GmailProviderMailActing, GmailProviderTokenRefreshing
{
  private let categorizer: GmailMessageCategorizing
  private let gmailBaseURL: URL
  private let oauthClientId: String?
  private let session: URLSession
  private let store: GmailMessageMetadataPersisting
  private let tokenStore: GmailProviderTokenPersisting
  private let tokenInfoURL: URL
  private let tokenRefreshURL: URL

  init(
    categorizer: GmailMessageCategorizing = GmailMessageCategorizationService(),
    gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1")!,
    oauthClientId: String? =
      ProcessInfo.processInfo.environment["GMAIL_OAUTH_CLIENT_ID"]
      ?? DotEnvFile.value(for: "GMAIL_OAUTH_CLIENT_ID")
      ?? GmailOAuthClientIdConfiguration.bundledValue(),
    session: URLSession = .shared,
    store: GmailMessageMetadataPersisting = FileGmailMessageMetadataStore(),
    tokenStore: GmailProviderTokenPersisting = KeychainGmailProviderTokenStore(),
    tokenInfoURL: URL = URL(string: "https://oauth2.googleapis.com/tokeninfo")!,
    tokenRefreshURL: URL = URL(string: "https://oauth2.googleapis.com/token")!
  ) {
    self.categorizer = categorizer
    self.gmailBaseURL = gmailBaseURL
    self.oauthClientId = oauthClientId
    self.session = session
    self.store = store
    self.tokenStore = tokenStore
    self.tokenInfoURL = tokenInfoURL
    self.tokenRefreshURL = tokenRefreshURL
  }

  func loadInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    let messages = try store.loadMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    return GmailMetadataSyncResult(
      messages: messages,
      threads: GmailInboxThread.group(messages)
    )
  }

  func categorizeHistorical(
    scope: GmailHistoricalCategorizationScope,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    let messages = try store.loadMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let categorizedMessages = try await categorizer.categorizeHistorical(
      messages: messages,
      scope: scope,
      session: session
    )
    try store.saveMessages(
      categorizedMessages,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    return GmailMetadataSyncResult(
      messages: categorizedMessages,
      threads: GmailInboxThread.group(categorizedMessages)
    )
  }

  func syncInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    try await syncInbox(
      connection: connection,
      maximumPages: nil,
      preservingUnlistedMessages: false,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      session: session,
      shouldPersist: nil
    )
  }

  func syncRecentInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId: String?,
    throughHistoryId: String?,
    shouldPersist: @escaping () -> Bool
  ) async throws -> GmailMetadataSyncResult {
    try await syncInbox(
      connection: connection,
      maximumPages: 1,
      preservingUnlistedMessages: true,
      sinceHistoryId: sinceHistoryId,
      throughHistoryId: throughHistoryId,
      session: session,
      shouldPersist: shouldPersist
    )
  }

  // swiftlint:disable:next function_body_length function_parameter_count
  private func syncInbox(
    connection: GmailProviderConnectionStatus,
    maximumPages: Int?,
    preservingUnlistedMessages: Bool,
    sinceHistoryId: String?,
    throughHistoryId: String?,
    session: ProductAccountSessionSnapshot,
    shouldPersist: (() -> Bool)?
  ) async throws -> GmailMetadataSyncResult {
    let tokens = try await tokensForSync(
      connection: connection,
      deferPersistence: shouldPersist != nil,
      session: session
    )
    let existingMessages = try store.loadMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let existingMessagesByStableId = Dictionary(
      uniqueKeysWithValues: existingMessages.map { ($0.stableProviderMessageId, $0) }
    )
    let categorizationBoundary = historicalCutoff(
      connection: connection,
      hasLocalMetadata: !existingMessages.isEmpty
    )
    let inboxHistoryChanges: GmailInboxHistoryChanges?
    if let sinceHistoryId {
      inboxHistoryChanges = try await fetchInboxHistoryChanges(
        accessToken: tokens.accessToken,
        sinceHistoryId: sinceHistoryId,
        throughHistoryId: throughHistoryId
      )
    } else {
      inboxHistoryChanges = nil
    }
    let listedMessages = try await listInboxMessages(
      accessToken: tokens.accessToken,
      maximumPages: maximumPages,
      including: inboxHistoryChanges?.addedMessageIds
    )
    var fetchedMessages = try await fetchListedMessageMetadata(
      accessToken: tokens.accessToken,
      categorizationBoundary: categorizationBoundary,
      connection: connection,
      listedMessages: listedMessages
    )
    fetchedMessages = sortedMessages(
      fetchedMessages,
      preservingExistingStateFrom: existingMessagesByStableId
    )
    try Task.checkCancellation()
    guard shouldPersist?() ?? true else {
      throw GmailMessageMetadataSyncError.staleLocalConnection
    }
    fetchedMessages = try await categorizer.categorize(
      messages: fetchedMessages,
      session: session
    )
    let currentInboxMessageIds = Set(fetchedMessages.map(\.providerMessageId))
    if preservingUnlistedMessages {
      let fetchedStableIds = Set(fetchedMessages.map(\.stableProviderMessageId))
      let unlistedMessages = existingMessages.filter {
        !fetchedStableIds.contains($0.stableProviderMessageId)
          && !(inboxHistoryChanges?.removedMessageIds.contains($0.providerMessageId) ?? false)
      }
      fetchedMessages = sortedMessages(
        fetchedMessages + unlistedMessages,
        preservingExistingStateFrom: existingMessagesByStableId
      )
    }

    try Task.checkCancellation()
    guard shouldPersist?() ?? true else {
      throw GmailMessageMetadataSyncError.staleLocalConnection
    }
    if shouldPersist != nil {
      try tokenStore.save(tokens, productAccountId: session.productAccountId)
    }
    try store.saveMessages(
      fetchedMessages,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    let addedMessageIds = inboxHistoryChanges?.addedMessageIds
    return GmailMetadataSyncResult(
      hasUnlistedNewMessages: addedMessageIds.map {
        !$0.isSubset(of: currentInboxMessageIds)
      } ?? false,
      messages: fetchedMessages,
      newMessageIds: addedMessageIds?.intersection(currentInboxMessageIds),
      threads: GmailInboxThread.group(fetchedMessages)
    )
  }

  private func tokensForSync(
    connection: GmailProviderConnectionStatus,
    deferPersistence: Bool,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderTokens {
    guard let storedTokens = try tokenStore.load(productAccountId: session.productAccountId) else {
      throw GmailMessageMetadataSyncError.missingLocalGmailTokens
    }
    let tokens = try await refreshedTokens(
      storedTokens,
      persist: !deferPersistence,
      productAccountId: session.productAccountId
    )
    try await validateRefreshedToken(tokens.accessToken, matches: connection)
    return tokens
  }

  func refreshProviderTokens(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderTokens {
    guard let storedTokens = try tokenStore.load(productAccountId: session.productAccountId) else {
      throw GmailMessageMetadataSyncError.missingLocalGmailTokens
    }

    let tokens = try await refreshedTokens(
      storedTokens,
      productAccountId: session.productAccountId
    )
    try await validateRefreshedToken(tokens.accessToken, matches: connection)
    return tokens
  }

  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    let overriddenMessage = try await categorizer.overrideCategory(
      categoryId,
      for: message,
      session: session
    )
    var didReplaceMessage = false
    var messages = try store.loadMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: message.providerAccountIdentifier
    ).map { storedMessage in
      guard storedMessage.stableProviderMessageId == message.stableProviderMessageId else {
        return storedMessage
      }
      didReplaceMessage = true
      return overriddenMessage
    }
    if !didReplaceMessage {
      messages.append(overriddenMessage)
    }
    try store.saveMessages(
      messages,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: message.providerAccountIdentifier
    )
    return overriddenMessage
  }

  func perform(
    _ action: GmailProviderMailAction,
    messageIds: [String],
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let accessToken = try await authorizedAccessToken(
      connection: connection,
      session: session,
      requiredScopes: [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://mail.google.com/",
      ]
    )
    for messageId in messageIds {
      let url = gmailBaseURL.appendingPathComponent("users/me/messages/\(messageId)")

      switch action {
      case .delete:
        try await sendAuthorizedRequest(
          url: url.appendingPathComponent("trash"), accessToken: accessToken, method: "POST")
      case .archive, .markRead, .markUnread, .star, .unstar:
        let labels: (add: [String], remove: [String])
        switch action {
        case .archive:
          labels = ([], ["INBOX"])
        case .markRead:
          labels = ([], ["UNREAD"])
        case .markUnread:
          labels = (["UNREAD"], [])
        case .star:
          labels = (["STARRED"], [])
        case .unstar:
          labels = ([], ["STARRED"])
        case .delete:
          fatalError("Handled above")
        }
        let body = try JSONEncoder().encode([
          "addLabelIds": labels.add,
          "removeLabelIds": labels.remove,
        ])
        try await sendAuthorizedRequest(
          url: url.appendingPathComponent("modify"),
          accessToken: accessToken,
          method: "POST",
          body: body
        )
      }
    }
  }

  func send(
    _ message: GmailOutgoingMessage,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let accessToken = try await authorizedAccessToken(
      connection: connection,
      session: session,
      requiredScopes: [
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.compose",
        "https://mail.google.com/",
      ]
    )
    let sender = try headerValue(connection.emailAddress)
    let recipient = try mailboxHeaderValue(message.recipient)
    let subject = try encodedHeaderValue(message.subject)
    var headers = [
      "To: \(recipient)",
      "From: \(sender)",
      "Subject: \(subject)",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=utf-8",
      "Content-Transfer-Encoding: 8bit",
    ]
    if let inReplyTo = message.inReplyTo {
      let replyHeader = try headerValue(inReplyTo)
      headers.append("In-Reply-To: \(replyHeader)")
      headers.append("References: \(replyHeader)")
    }
    let mimeMessage = (headers + ["", message.body]).joined(separator: "\r\n")
    let raw = Data(mimeMessage.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    var payload: [String: String] = ["raw": raw]
    if let threadId = message.threadId {
      payload["threadId"] = threadId
    }
    let body = try JSONEncoder().encode(payload)
    try await sendAuthorizedRequest(
      url: gmailBaseURL.appendingPathComponent("users/me/messages/send"),
      accessToken: accessToken,
      method: "POST",
      body: body
    )
  }

  private func authorizedAccessToken(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot,
    requiredScopes: Set<String>
  ) async throws -> String {
    guard let storedTokens = try tokenStore.load(productAccountId: session.productAccountId) else {
      throw GmailMessageMetadataSyncError.missingLocalGmailTokens
    }
    let tokens = try await refreshedTokens(storedTokens, productAccountId: session.productAccountId)
    try await validateRefreshedToken(
      tokens.accessToken,
      matches: connection,
      requiredScopes: requiredScopes
    )
    return tokens.accessToken
  }

  private func listInboxMessages(
    accessToken: String,
    maximumPages: Int?,
    including requiredMessageIds: Set<String>?
  ) async throws -> [GmailListedMessage] {
    var listedMessages: [GmailListedMessage] = []
    var nextPageToken: String?
    var pageCount = 0

    while true {
      var components = URLComponents(
        url: gmailBaseURL.appendingPathComponent("users/me/messages"),
        resolvingAgainstBaseURL: false
      )
      var queryItems = [
        URLQueryItem(name: "labelIds", value: "INBOX"),
        URLQueryItem(name: "maxResults", value: "25"),
      ]
      if let nextPageToken {
        queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
      }
      components?.queryItems = queryItems
      guard let url = components?.url else {
        throw GmailMessageMetadataSyncError.invalidGmailRequest
      }

      let response = try await sendAuthorizedRequest(
        url: url,
        accessToken: accessToken,
        responseType: GmailListMessagesResponse.self
      )
      listedMessages.append(contentsOf: response.messages ?? [])
      nextPageToken = response.nextPageToken
      pageCount += 1
      try Task.checkCancellation()
      guard nextPageToken != nil else { break }
      guard maximumPages.map({ pageCount < $0 }) ?? true else { break }
    }

    return listedMessages
  }

  // swiftlint:disable:next function_body_length
  private func fetchInboxHistoryChanges(
    accessToken: String,
    sinceHistoryId: String,
    throughHistoryId: String?
  ) async throws -> GmailInboxHistoryChanges {
    var addedMessageIds: Set<String> = []
    var historyAddedMessageIds: Set<String> = []
    var removedMessageIds: Set<String> = []
    var nextPageToken: String?

    var reachedWakeBoundary = false
    repeat {
      var components = URLComponents(
        url: gmailBaseURL.appendingPathComponent("users/me/history"),
        resolvingAgainstBaseURL: false
      )
      var queryItems = [
        URLQueryItem(name: "startHistoryId", value: sinceHistoryId),
        URLQueryItem(name: "labelId", value: "INBOX"),
      ]
      if let nextPageToken {
        queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
      }
      components?.queryItems = queryItems
      guard let url = components?.url else {
        throw GmailMessageMetadataSyncError.invalidGmailRequest
      }

      let response = try await sendAuthorizedRequest(
        url: url,
        accessToken: accessToken,
        responseType: GmailListHistoryResponse.self
      )
      for record in response.history ?? [] {
        if let throughHistoryId, let recordId = record.id,
          gmailHistoryIdIsNewer(recordId, than: throughHistoryId)
        {
          reachedWakeBoundary = true
          break
        }
        for addition in record.messagesAdded ?? [] {
          if addition.message.labelIds?.contains("INBOX") != false {
            addedMessageIds.insert(addition.message.id)
            historyAddedMessageIds.insert(addition.message.id)
          }
          removedMessageIds.remove(addition.message.id)
        }
        for addition in record.labelsAdded ?? [] where addition.labelIds.contains("INBOX") {
          restoreHistoryAddition(
            addition.message.id,
            from: historyAddedMessageIds,
            into: &addedMessageIds
          )
          removedMessageIds.remove(addition.message.id)
        }
        for removal in record.labelsRemoved ?? [] where removal.labelIds.contains("INBOX") {
          removedMessageIds.insert(removal.message.id)
          addedMessageIds.remove(removal.message.id)
        }
        for deletion in record.messagesDeleted ?? [] {
          removedMessageIds.insert(deletion.message.id)
          addedMessageIds.remove(deletion.message.id)
          historyAddedMessageIds.remove(deletion.message.id)
        }
      }
      nextPageToken = response.nextPageToken
      try Task.checkCancellation()
    } while nextPageToken != nil && !reachedWakeBoundary

    return GmailInboxHistoryChanges(
      addedMessageIds: addedMessageIds,
      removedMessageIds: removedMessageIds
    )
  }

  private func restoreHistoryAddition(
    _ messageId: String,
    from historyAddedMessageIds: Set<String>,
    into addedMessageIds: inout Set<String>
  ) {
    guard historyAddedMessageIds.contains(messageId) else { return }
    addedMessageIds.insert(messageId)
  }

  private func fetchListedMessageMetadata(
    accessToken: String,
    categorizationBoundary: Date,
    connection: GmailProviderConnectionStatus,
    listedMessages: [GmailListedMessage]
  ) async throws -> [GmailMessageMetadata] {
    var messages: [GmailMessageMetadata] = []
    for listedMessage in listedMessages {
      messages.append(
        try await fetchMessageMetadata(
          accessToken: accessToken,
          categorizationBoundary: categorizationBoundary,
          connection: connection,
          providerMessageId: listedMessage.id
        )
      )
    }
    return messages
  }

  private func fetchMessageMetadata(
    accessToken: String,
    categorizationBoundary: Date,
    connection: GmailProviderConnectionStatus,
    providerMessageId: String
  ) async throws -> GmailMessageMetadata {
    var components = URLComponents(
      url: gmailBaseURL.appendingPathComponent("users/me/messages/\(providerMessageId)"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
      URLQueryItem(name: "format", value: "metadata"),
      URLQueryItem(name: "metadataHeaders", value: "From"),
      URLQueryItem(name: "metadataHeaders", value: "Message-ID"),
      URLQueryItem(name: "metadataHeaders", value: "Reply-To"),
      URLQueryItem(name: "metadataHeaders", value: "Subject"),
    ]
    guard let url = components?.url else {
      throw GmailMessageMetadataSyncError.invalidGmailRequest
    }

    let response = try await sendAuthorizedRequest(
      url: url,
      accessToken: accessToken,
      responseType: GmailMessageMetadataResponse.self
    )
    let internalDateMilliseconds = Int64(response.internalDate) ?? 0
    let internalDate = Date(timeIntervalSince1970: TimeInterval(internalDateMilliseconds) / 1_000)
    let subject = response.payload?.headers.first {
      $0.name.caseInsensitiveCompare("Subject") == .orderedSame
    }?.value

    return GmailMessageMetadata(
      categoryId: nil,
      from: response.payload?.headers.first {
        $0.name.caseInsensitiveCompare("From") == .orderedSame
      }?.value,
      isHistorical: internalDate <= categorizationBoundary,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      providerInternalDateMilliseconds: internalDateMilliseconds,
      providerMessageId: response.id,
      providerThreadId: response.threadId,
      replyTo: response.payload?.headers.first {
        $0.name.caseInsensitiveCompare("Reply-To") == .orderedSame
      }?.value,
      snippet: response.snippet,
      stableProviderMessageId: "gmail:\(connection.providerAccountIdentifier):\(response.id)",
      subject: subject?.isEmpty == false ? subject! : "(No subject)",
      rfcMessageId: response.payload?.headers.first {
        $0.name.caseInsensitiveCompare("Message-ID") == .orderedSame
      }?.value
    )
  }

  private func sendAuthorizedRequest<Response: Decodable>(
    url: URL,
    accessToken: String,
    responseType: Response.Type
  ) async throws -> Response {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailMessageMetadataSyncError.gmailRequestFailed
    }

    return try JSONDecoder().decode(Response.self, from: data)
  }

  private func headerValue(_ value: String) throws -> String {
    guard !value.unicodeScalars.contains(where: { $0.value == 0x0A || $0.value == 0x0D }) else {
      throw GmailMessageMetadataSyncError.invalidMessageHeader
    }
    return value
  }

  private func encodedHeaderValue(_ value: String) throws -> String {
    let value = try headerValue(value)
    guard value.unicodeScalars.contains(where: { $0.value > 127 }) else {
      return value
    }
    return "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
  }

  private func mailboxHeaderValue(_ value: String) throws -> String {
    let value = try headerValue(value)
    return try mailboxValues(in: value)
      .map { try encodedMailboxHeaderValue($0) }
      .joined(separator: ", ")
  }

  private func mailboxValues(in value: String) -> [String] {
    var mailboxes: [String] = []
    var mailbox = ""
    var isEscaped = false
    var isQuoted = false
    var angleBracketDepth = 0

    for character in value {
      if isEscaped {
        mailbox.append(character)
        isEscaped = false
        continue
      }

      if character == "\\" && isQuoted {
        mailbox.append(character)
        isEscaped = true
        continue
      }

      switch character {
      case "\"":
        isQuoted.toggle()
      case "<":
        angleBracketDepth += 1
      case ">":
        angleBracketDepth = max(0, angleBracketDepth - 1)
      case "," where !isQuoted && angleBracketDepth == 0:
        mailboxes.append(mailbox)
        mailbox = ""
        continue
      default:
        break
      }

      mailbox.append(character)
    }

    mailboxes.append(mailbox)
    return mailboxes
  }

  private func encodedMailboxHeaderValue(_ value: String) throws -> String {
    let value = value.trimmingCharacters(in: .whitespaces)
    guard let addressStart = value.lastIndex(of: "<"), value.hasSuffix(">") else {
      return value
    }
    let displayName = value[..<addressStart].trimmingCharacters(in: .whitespaces)
    guard !displayName.isEmpty else {
      return String(value[addressStart...])
    }
    return "\(try encodedHeaderValue(displayName)) \(value[addressStart...])"
  }

  private func sendAuthorizedRequest(
    url: URL,
    accessToken: String,
    method: String,
    body: Data? = nil
  ) async throws {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    if body != nil {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let (_, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailMessageMetadataSyncError.gmailRequestFailed
    }
  }

  private func sortedMessages(
    _ messages: [GmailMessageMetadata],
    preservingExistingStateFrom existingMessagesByStableId: [String: GmailMessageMetadata]
  ) -> [GmailMessageMetadata] {
    messages
      .map { message in
        guard let existingMessage = existingMessagesByStableId[message.stableProviderMessageId]
        else {
          return message
        }

        return message.preservingCategoryStateAndHistoricalBoundary(from: existingMessage)
      }
      .sorted {
        if $0.providerInternalDateMilliseconds == $1.providerInternalDateMilliseconds {
          return $0.providerMessageId < $1.providerMessageId
        }
        return $0.providerInternalDateMilliseconds > $1.providerInternalDateMilliseconds
      }
  }

  private func historicalCutoff(
    connection: GmailProviderConnectionStatus,
    hasLocalMetadata: Bool
  ) -> Date {
    let cutoffMilliseconds = hasLocalMetadata ? connection.connectedAt : connection.updatedAt
    return Date(timeIntervalSince1970: TimeInterval(cutoffMilliseconds) / 1_000)
  }

  private func refreshedTokens(
    _ tokens: GmailProviderTokens,
    persist: Bool = true,
    productAccountId: String
  ) async throws -> GmailProviderTokens {
    guard let oauthClientId, !oauthClientId.isEmpty else {
      throw GmailMessageMetadataSyncError.missingOAuthClientId
    }

    var request = URLRequest(url: tokenRefreshURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formURLEncodedBody([
      "client_id": oauthClientId,
      "grant_type": "refresh_token",
      "refresh_token": tokens.refreshToken,
    ])

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailMessageMetadataSyncError.refreshTokenRejected
    }

    let tokenResponse = try JSONDecoder().decode(GmailRefreshTokenResponse.self, from: data)
    guard !tokenResponse.accessToken.isEmpty else {
      throw GmailMessageMetadataSyncError.refreshTokenRejected
    }

    let refreshedTokens = GmailProviderTokens(
      accessToken: tokenResponse.accessToken,
      refreshToken: tokens.refreshToken
    )
    if persist {
      try tokenStore.save(refreshedTokens, productAccountId: productAccountId)
    }
    return refreshedTokens
  }

  private func validateRefreshedToken(
    _ accessToken: String,
    matches connection: GmailProviderConnectionStatus,
    requiredScopes: Set<String>? = nil
  ) async throws {
    var components = URLComponents(url: tokenInfoURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "access_token", value: accessToken)
    ]
    guard let url = components?.url else {
      throw GmailMessageMetadataSyncError.invalidGmailRequest
    }

    let (data, response) = try await session.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailMessageMetadataSyncError.refreshedTokenAccountMismatch
    }

    let tokenInfo = try JSONDecoder().decode(GmailTokenInfoResponse.self, from: data)
    guard let subject = tokenInfo.sub, subject == connection.providerAccountIdentifier else {
      throw GmailMessageMetadataSyncError.refreshedTokenAccountMismatch
    }
    if let email = tokenInfo.email, !email.isEmpty {
      guard email.caseInsensitiveCompare(connection.emailAddress) == .orderedSame else {
        throw GmailMessageMetadataSyncError.refreshedTokenAccountMismatch
      }
    }
    if let requiredScopes {
      guard !tokenInfo.scopes.isDisjoint(with: requiredScopes) else {
        throw GmailMessageMetadataSyncError.insufficientGmailScope
      }
    }
  }

  private func formURLEncodedBody(_ fields: [String: String]) -> Data {
    fields
      .map { key, value in
        "\(formURLEncode(key))=\(formURLEncode(value))"
      }
      .joined(separator: "&")
      .data(using: .utf8) ?? Data()
  }

  private func formURLEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}

enum GmailMessageMetadataSyncError: LocalizedError, Equatable {
  case invalidMessageHeader
  case gmailRequestFailed
  case invalidGmailRequest
  case insufficientGmailScope
  case missingLocalGmailTokens
  case missingOAuthClientId
  case refreshedTokenAccountMismatch
  case refreshTokenRejected
  case staleLocalConnection

  var errorDescription: String? {
    switch self {
    case .invalidMessageHeader:
      return "Message recipients and subjects cannot contain line breaks."
    case .gmailRequestFailed:
      return "Gmail message metadata sync failed."
    case .invalidGmailRequest:
      return "Gmail message metadata request could not be created."
    case .insufficientGmailScope:
      return "Reconnect Gmail with permission to send and manage mail."
    case .missingLocalGmailTokens:
      return "Gmail is connected on the backend, but this device has no local Gmail tokens."
    case .missingOAuthClientId:
      return "Gmail OAuth client id is not configured."
    case .refreshedTokenAccountMismatch:
      return "Local Gmail tokens belong to a different Google account."
    case .refreshTokenRejected:
      return "Gmail did not refresh local mail access for this account."
    case .staleLocalConnection:
      return "The Gmail connection changed while mailbox sync was running."
    }
  }
}

extension GmailInboxThread {
  static func group(_ messages: [GmailMessageMetadata]) -> [GmailInboxThread] {
    Dictionary(grouping: messages, by: \.providerThreadId)
      .map { providerThreadId, threadMessages in
        let sortedMessages = threadMessages.sorted {
          if $0.providerInternalDateMilliseconds == $1.providerInternalDateMilliseconds {
            return $0.providerMessageId < $1.providerMessageId
          }
          return $0.providerInternalDateMilliseconds > $1.providerInternalDateMilliseconds
        }
        return GmailInboxThread(
          latestMessage: sortedMessages[0],
          messages: sortedMessages,
          providerThreadId: providerThreadId
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

extension GmailMessageMetadata {
  fileprivate func preservingCategoryStateAndHistoricalBoundary(
    from existingMessage: GmailMessageMetadata
  ) -> GmailMessageMetadata {
    GmailMessageMetadata(
      categoryId: existingMessage.categoryId,
      from: from,
      isHistorical: existingMessage.isHistorical,
      providerAccountIdentifier: providerAccountIdentifier,
      providerInternalDateMilliseconds: providerInternalDateMilliseconds,
      providerMessageId: providerMessageId,
      providerThreadId: providerThreadId,
      replyTo: replyTo,
      snippet: snippet,
      stableProviderMessageId: stableProviderMessageId,
      subject: subject,
      rfcMessageId: rfcMessageId
    )
  }
}

private struct GmailListMessagesResponse: Decodable {
  let messages: [GmailListedMessage]?
  let nextPageToken: String?
}

private struct GmailListHistoryResponse: Decodable {
  let history: [GmailHistoryRecord]?
  let nextPageToken: String?
}

private struct GmailInboxHistoryChanges {
  let addedMessageIds: Set<String>
  let removedMessageIds: Set<String>

  init(addedMessageIds: Set<String>, removedMessageIds: Set<String>) {
    self.addedMessageIds = addedMessageIds.subtracting(removedMessageIds)
    self.removedMessageIds = removedMessageIds
  }
}

private struct GmailHistoryRecord: Decodable {
  let id: String?
  let labelsAdded: [GmailHistoryLabelChange]?
  let labelsRemoved: [GmailHistoryLabelChange]?
  let messagesAdded: [GmailHistoryMessageChange]?
  let messagesDeleted: [GmailHistoryMessageChange]?
}

private struct GmailHistoryLabelChange: Decodable {
  let labelIds: [String]
  let message: GmailHistoryMessage
}

private struct GmailHistoryMessageChange: Decodable {
  let message: GmailHistoryMessage
}

private struct GmailHistoryMessage: Decodable {
  let id: String
  let labelIds: [String]?
}

private struct GmailListedMessage: Decodable {
  let id: String
}

private struct GmailMessageMetadataResponse: Decodable {
  let id: String
  let internalDate: String
  let payload: GmailMessagePayload?
  let snippet: String
  let threadId: String
}

private struct GmailMessagePayload: Decodable {
  let headers: [GmailMessageHeader]
}

private struct GmailMessageHeader: Decodable {
  let name: String
  let value: String
}

private struct GmailRefreshTokenResponse: Decodable {
  let accessToken: String

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
  }
}

private struct GmailTokenInfoResponse: Decodable {
  let email: String?
  let scope: String?
  let sub: String?

  var scopes: Set<String> {
    Set((scope ?? "").split(separator: " ").map(String.init))
  }
}
