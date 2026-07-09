import Foundation

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
  private let now: () -> Date
  private let session: URLSession
  private let store: GmailMessageMetadataPersisting
  private let tokenStore: GmailProviderTokenPersisting

  init(
    gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1")!,
    now: @escaping () -> Date = Date.init,
    session: URLSession = .shared,
    store: GmailMessageMetadataPersisting = FileGmailMessageMetadataStore(),
    tokenStore: GmailProviderTokenPersisting = KeychainGmailProviderTokenStore()
  ) {
    self.gmailBaseURL = gmailBaseURL
    self.now = now
    self.session = session
    self.store = store
    self.tokenStore = tokenStore
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
    guard let tokens = try tokenStore.load(productAccountId: session.productAccountId) else {
      throw GmailMessageMetadataSyncError.missingLocalGmailTokens
    }

    let categorizationBoundary = now()
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
    fetchedMessages = fetchedMessages.sorted {
      if $0.providerInternalDateMilliseconds == $1.providerInternalDateMilliseconds {
        return $0.providerMessageId < $1.providerMessageId
      }
      return $0.providerInternalDateMilliseconds > $1.providerInternalDateMilliseconds
    }

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
}

enum GmailMessageMetadataSyncError: LocalizedError, Equatable {
  case gmailRequestFailed
  case invalidGmailRequest
  case missingLocalGmailTokens

  var errorDescription: String? {
    switch self {
    case .gmailRequestFailed:
      return "Gmail message metadata sync failed."
    case .invalidGmailRequest:
      return "Gmail message metadata request could not be created."
    case .missingLocalGmailTokens:
      return "Gmail is connected on the backend, but this device has no local Gmail tokens."
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
