import Foundation
@preconcurrency import GTMSessionFetcherCore
@preconcurrency import GoogleAPIClientForREST_Gmail

enum GoogleGmailRESTClientBuildPolicy {
  static let dependencyVersion = "5.4.0"
  static let dependencyRevision = "07cd7c8ca9119dc08afd4bad52280bd3b763196c"
  static let qualificationIssue = 434

  static var isEnabled: Bool {
    #if DEBUG || TESTING || UNWIRED_INTERNAL_GOOGLE_GMAIL_REST
      true
    #else
      false
    #endif
  }
}

enum GmailSearchServiceFactory {
  static func makeDefault() -> any GmailMessageSearching {
    if GoogleGmailRESTClientBuildPolicy.isEnabled {
      ExperimentalGoogleGmailRESTSearchService()
    } else {
      GmailMessageMetadataService()
    }
  }
}

/// Runs provider search through Google's generated Gmail REST client in eligible builds.
struct ExperimentalGoogleGmailRESTSearchService: GmailMessageSearching {
  private let client: GoogleGmailRESTClient
  private let tokenRefresher: any GmailProviderTokenRefreshing

  init(
    client: GoogleGmailRESTClient = GoogleGmailRESTClient(),
    tokenRefresher: any GmailProviderTokenRefreshing = GmailMessageMetadataService()
  ) {
    self.client = client
    self.tokenRefresher = tokenRefresher
  }

  func searchProvider(
    query: String,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    guard GoogleGmailRESTClientBuildPolicy.isEnabled else {
      throw GmailMessageMetadataSyncError.gmailRequestFailed
    }
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }

    let tokens = try await tokenRefresher.refreshProviderTokens(
      connection: connection,
      session: session
    )
    let responses = try await client.searchMessages(
      accessToken: tokens.accessToken,
      query: query
    )
    let categorizationBoundary = Date(
      timeIntervalSince1970: TimeInterval(connection.updatedAt) / 1_000
    )
    return responses.map {
      $0.metadata(
        categorizationBoundary: categorizationBoundary,
        connection: connection
      )
    }
  }
}

/// Keeps generated Google transport types inside the experimental adapter.
final class GoogleGmailRESTClient {
  private static let maximumMessageCount = 100
  private static let maximumMessageResponseByteCount = 1_048_576
  private static let maximumPageResponseByteCount = 262_144

  private let service: GTLRGmailService

  init(service: GTLRGmailService = GTLRGmailService()) {
    GTMSessionFetcher.setLoggingEnabled(false)
    service.isRetryEnabled = false
    service.shouldFetchNextPages = false
    self.service = service
  }

  /// Searches Gmail and returns bounded product-owned metadata responses.
  func searchMessages(
    accessToken: String,
    query: String
  ) async throws -> [GmailMessageMetadataResponse] {
    var messageIds: [String] = []
    var nextPageToken: String?

    repeat {
      try Task.checkCancellation()
      let remainingCount = Self.maximumMessageCount - messageIds.count
      guard remainingCount > 0 else { break }

      let listQuery = GTLRGmailQuery_UsersMessagesList.query(withUserId: "me")
      listQuery.additionalHTTPHeaders = authorizationHeaders(accessToken: accessToken)
      listQuery.fields = "messages(id),nextPageToken"
      listQuery.maxResults = UInt(remainingCount)
      listQuery.pageToken = nextPageToken
      listQuery.q = query

      let response: GTLRGmail_ListMessagesResponse = try await execute(listQuery)
      try validateResponseSize(response, maximumByteCount: Self.maximumPageResponseByteCount)
      let pageMessageIds = try (response.messages ?? []).map { message in
        guard let identifier = message.identifier, !identifier.isEmpty else {
          throw GmailMessageMetadataSyncError.gmailRequestFailed
        }
        return identifier
      }
      guard pageMessageIds.count <= remainingCount else {
        throw GmailMessageMetadataSyncError.gmailRequestFailed
      }
      messageIds.append(contentsOf: pageMessageIds)
      nextPageToken = response.nextPageToken?.isEmpty == false ? response.nextPageToken : nil
    } while nextPageToken != nil

    var responses: [GmailMessageMetadataResponse] = []
    responses.reserveCapacity(messageIds.count)
    for messageId in messageIds {
      try Task.checkCancellation()
      let getQuery = GTLRGmailQuery_UsersMessagesGet.query(
        withUserId: "me",
        identifier: messageId
      )
      getQuery.additionalHTTPHeaders = authorizationHeaders(accessToken: accessToken)
      getQuery.fields = GmailMessageMetadataResponse.requestedFields
      getQuery.format = kGTLRGmailFormatFull
      getQuery.metadataHeaders = GmailMessageMetadataResponse.requestedHeaderNames

      let response: GTLRGmail_Message = try await execute(getQuery)
      let data = try serializedJSON(
        response,
        maximumByteCount: Self.maximumMessageResponseByteCount
      )
      responses.append(try JSONDecoder().decode(GmailMessageMetadataResponse.self, from: data))
    }
    return responses
  }

  private func authorizationHeaders(accessToken: String) -> [String: String] {
    ["Authorization": "Bearer \(accessToken)"]
  }

  private func execute<Result: GTLRObject>(_ query: GTLRQuery) async throws -> Result {
    let operation = GoogleGmailRESTQueryOperation()
    let object: AnyObject = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard operation.install(continuation) else { return }
        let ticket = service.executeQuery(query) { _, object, error in
          if let error {
            operation.resume(throwing: Self.normalizedError(error))
          } else if let object = object as AnyObject? {
            operation.resume(returning: object)
          } else {
            operation.resume(throwing: GmailMessageMetadataSyncError.gmailRequestFailed)
          }
        }
        operation.install(ticket)
      }
    } onCancel: {
      operation.cancel()
    }
    try Task.checkCancellation()
    guard let result = object as? Result else {
      throw GmailMessageMetadataSyncError.gmailRequestFailed
    }
    return result
  }

  private func serializedJSON(
    _ object: GTLRObject,
    maximumByteCount: Int
  ) throws -> Data {
    guard let json = object.json, JSONSerialization.isValidJSONObject(json) else {
      throw GmailMessageMetadataSyncError.gmailRequestFailed
    }
    let data = try JSONSerialization.data(withJSONObject: json)
    guard data.count <= maximumByteCount else {
      throw GmailMessageMetadataSyncError.gmailRequestFailed
    }
    return data
  }

  private func validateResponseSize(
    _ object: GTLRObject,
    maximumByteCount: Int
  ) throws {
    _ = try serializedJSON(object, maximumByteCount: maximumByteCount)
  }

  private static func normalizedError(_ error: Error) -> Error {
    let error = error as NSError
    if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
      return CancellationError()
    }
    return GmailMessageMetadataSyncError.gmailRequestFailed
  }
}

private final class GoogleGmailRESTQueryOperation: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<AnyObject, Error>?
  private var isCancelled = false
  private var isFinished = false
  private var ticket: GTLRServiceTicket?

  func install(_ continuation: CheckedContinuation<AnyObject, Error>) -> Bool {
    let shouldCancel = lock.withLock {
      guard !isCancelled else { return true }
      self.continuation = continuation
      return false
    }
    if shouldCancel {
      continuation.resume(throwing: CancellationError())
    }
    return !shouldCancel
  }

  func install(_ ticket: GTLRServiceTicket) {
    let shouldCancel = lock.withLock {
      guard !isCancelled else { return true }
      guard !isFinished else { return false }
      self.ticket = ticket
      return false
    }
    if shouldCancel {
      ticket.cancel()
    }
  }

  func cancel() {
    let (continuation, ticket) = lock.withLock {
      guard !isCancelled, !isFinished else {
        return (nil as CheckedContinuation<AnyObject, Error>?, nil as GTLRServiceTicket?)
      }
      isCancelled = true
      let continuation = self.continuation
      self.continuation = nil
      return (continuation, self.ticket)
    }
    continuation?.resume(throwing: CancellationError())
    ticket?.cancel()
  }

  func resume(returning value: AnyObject) {
    let continuation = lock.withLock {
      guard !isCancelled, !isFinished else {
        return nil as CheckedContinuation<AnyObject, Error>?
      }
      isFinished = true
      let continuation = self.continuation
      self.continuation = nil
      ticket = nil
      return continuation
    }
    continuation?.resume(returning: value)
  }

  func resume(throwing error: Error) {
    let continuation = lock.withLock {
      guard !isCancelled, !isFinished else {
        return nil as CheckedContinuation<AnyObject, Error>?
      }
      isFinished = true
      let continuation = self.continuation
      self.continuation = nil
      ticket = nil
      return continuation
    }
    continuation?.resume(throwing: error)
  }
}
