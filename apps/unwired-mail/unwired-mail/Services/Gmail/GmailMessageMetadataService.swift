import Foundation

// swiftlint:disable file_length

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
  let snippet: String
  let stableProviderMessageId: String
  let subject: String
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
  let messages: [GmailMessageMetadata]
  let threads: [GmailInboxThread]
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
  func loadInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult

  func syncInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult
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

    let prefix = "\(safeFileComponent(productAccountId))-"
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
      "\(safeFileComponent(productAccountId))-\(safeFileComponent(providerAccountIdentifier)).json"
    )
  }

  private func safeFileComponent(_ value: String) -> String {
    value
      .map { character in
        character.isLetter || character.isNumber || character == "-" ? character : "_"
      }
      .reduce(into: "") { partialResult, character in
        partialResult.append(character)
      }
  }
}

struct GmailMessageMetadataService: GmailMessageMetadataSyncing {
  private let gmailBaseURL: URL
  private let oauthClientId: String?
  private let session: URLSession
  private let store: GmailMessageMetadataPersisting
  private let tokenStore: GmailProviderTokenPersisting
  private let tokenRefreshURL: URL

  init(
    gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1")!,
    oauthClientId: String? =
      ProcessInfo.processInfo.environment["GMAIL_OAUTH_CLIENT_ID"]
      ?? DotEnvFile.value(for: "GMAIL_OAUTH_CLIENT_ID")
      ?? GmailOAuthClientIdConfiguration.bundledValue(),
    session: URLSession = .shared,
    store: GmailMessageMetadataPersisting = FileGmailMessageMetadataStore(),
    tokenStore: GmailProviderTokenPersisting = KeychainGmailProviderTokenStore(),
    tokenRefreshURL: URL = URL(string: "https://oauth2.googleapis.com/token")!
  ) {
    self.gmailBaseURL = gmailBaseURL
    self.oauthClientId = oauthClientId
    self.session = session
    self.store = store
    self.tokenStore = tokenStore
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

  func syncInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    guard let storedTokens = try tokenStore.load(productAccountId: session.productAccountId) else {
      throw GmailMessageMetadataSyncError.missingLocalGmailTokens
    }

    let tokens = try await refreshedTokens(
      storedTokens,
      productAccountId: session.productAccountId
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
    let listedMessages = try await listInboxMessages(accessToken: tokens.accessToken)
    var fetchedMessages: [GmailMessageMetadata] = []
    for listedMessage in listedMessages {
      fetchedMessages.append(
        try await fetchMessageMetadata(
          accessToken: tokens.accessToken,
          categorizationBoundary: categorizationBoundary,
          connection: connection,
          providerMessageId: listedMessage.id
        )
      )
    }
    try Task.checkCancellation()
    fetchedMessages = sortedMessages(
      fetchedMessages,
      preservingExistingStateFrom: existingMessagesByStableId
    )

    try Task.checkCancellation()
    try store.saveMessages(
      fetchedMessages,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    return GmailMetadataSyncResult(
      messages: fetchedMessages,
      threads: GmailInboxThread.group(fetchedMessages)
    )
  }

  private func listInboxMessages(
    accessToken: String
  ) async throws -> [GmailListedMessage] {
    var components = URLComponents(
      url: gmailBaseURL.appendingPathComponent("users/me/messages"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
      URLQueryItem(name: "labelIds", value: "INBOX"),
      URLQueryItem(name: "maxResults", value: "25"),
    ]
    guard let url = components?.url else {
      throw GmailMessageMetadataSyncError.invalidGmailRequest
    }

    let response = try await sendAuthorizedRequest(
      url: url,
      accessToken: accessToken,
      responseType: GmailListMessagesResponse.self
    )
    return response.messages ?? []
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
      snippet: response.snippet,
      stableProviderMessageId: "gmail:\(connection.providerAccountIdentifier):\(response.id)",
      subject: subject?.isEmpty == false ? subject! : "(No subject)"
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
    try tokenStore.save(refreshedTokens, productAccountId: productAccountId)
    return refreshedTokens
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
  case gmailRequestFailed
  case invalidGmailRequest
  case missingLocalGmailTokens
  case missingOAuthClientId
  case refreshTokenRejected

  var errorDescription: String? {
    switch self {
    case .gmailRequestFailed:
      return "Gmail message metadata sync failed."
    case .invalidGmailRequest:
      return "Gmail message metadata request could not be created."
    case .missingLocalGmailTokens:
      return "Gmail is connected on the backend, but this device has no local Gmail tokens."
    case .missingOAuthClientId:
      return "Gmail OAuth client id is not configured."
    case .refreshTokenRejected:
      return "Gmail did not refresh local mail access for this account."
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
      snippet: snippet,
      stableProviderMessageId: stableProviderMessageId,
      subject: subject
    )
  }
}

private struct GmailListMessagesResponse: Decodable {
  let messages: [GmailListedMessage]?
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
