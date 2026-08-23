import Foundation
@preconcurrency import GTMSessionFetcherCore
@preconcurrency import GoogleAPIClientForREST_Gmail
import Testing

@testable import unwired_mail

// The qualification matrix keeps both transports and their deterministic fixtures together.
// swiftlint:disable file_length type_body_length

private final class GmailRESTQualificationURLStub: URLProtocolStub {}

@Suite(.serialized)
final class GmailRESTSearchQualificationTests {
  enum Transport: CaseIterable, CustomTestStringConvertible {
    case direct
    case generatedClient

    var testDescription: String {
      switch self {
      case .direct: "direct"
      case .generatedClient: "generated-client"
      }
    }
  }

  enum Failure: CaseIterable, CustomTestStringConvertible {
    case authentication
    case malformedResponse
    case rateLimit

    var testDescription: String {
      switch self {
      case .authentication: "authentication"
      case .malformedResponse: "malformed-response"
      case .rateLimit: "rate-limit"
      }
    }
  }

  private let connection = GmailProviderConnectionStatus(
    connectedAt: 1_781_200_000_000,
    emailAddress: "user@example.com",
    lastVerifiedAt: 1_781_200_000_000,
    provider: "gmail",
    providerAccountIdentifier: "gmail-user-001",
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_000
  )
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "apple-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  @Test(arguments: Transport.allCases)
  func testSearchQualificationSuccessAndPagination(transport: Transport) async throws {
    let service = try makeService(transport: transport, failure: nil)

    let messages = try await service.searchProvider(
      query: " invoice total ",
      connection: connection,
      session: session
    )

    #expect(messages.map(\.providerMessageId) == ["message-001", "message-002"])
    #expect(messages.map(\.providerThreadId) == ["thread-message-001", "thread-message-002"])
    #expect(messages.allSatisfy { $0.providerAccountIdentifier == "gmail-user-001" })
    #expect(messages.allSatisfy { $0.subject == "Thread subject" })
  }

  @Test(arguments: Transport.allCases, Failure.allCases)
  func testSearchQualificationFailures(
    transport: Transport,
    failure: Failure
  ) async throws {
    let service = try makeService(transport: transport, failure: failure)

    do {
      _ = try await service.searchProvider(
        query: "invoice",
        connection: connection,
        session: session
      )
      Issue.record("Expected \(failure.testDescription) failure")
    } catch {
      switch failure {
      case .authentication:
        #expect(error as? GmailMessageMetadataSyncError == .oauthResponseStatus(401))
      case .malformedResponse:
        #expect(
          error is DecodingError || error as? GmailMessageMetadataSyncError == .gmailRequestFailed)
      case .rateLimit:
        #expect(error as? GmailMessageMetadataSyncError == .gmailRequestFailed)
      }
    }
  }

  @Test(arguments: Transport.allCases)
  func testSearchQualificationHonorsCancellation(transport: Transport) async throws {
    let service = try makeService(transport: transport, failure: nil)
    let task = Task {
      try await service.searchProvider(
        query: "invoice",
        connection: connection,
        session: session
      )
    }
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    } catch {
      let error = error as NSError
      #expect(error.domain == NSURLErrorDomain)
      #expect(error.code == NSURLErrorCancelled)
    }
  }

  @Test
  func testGeneratedClientCancelsAnInFlightQuery() async {
    let queryStarted = expectation(description: "generated query started")
    let service = GTLRGmailService()
    service.testBlock = { _, _ in
      queryStarted.fulfill()
    }
    let client = GoogleGmailRESTClient(service: service)
    let task = Task {
      try await client.searchMessages(accessToken: "access-token", query: "invoice")
    }

    await fulfillment(of: [queryStarted])
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected in-flight query cancellation")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected CancellationError, received \(error)")
    }
  }

  @Test
  func testGeneratedClientKeepsConnectionsAndAuthorizationIsolated() async throws {
    let service = GTLRGmailService()
    let observedAuthorizationHeaders = LockedAuthorizationHeaders()
    service.testBlock = { ticket, response in
      if let query = ticket.originalQuery as? GTLRGmailQuery_UsersMessagesList,
        let authorization = query.additionalHTTPHeaders?["Authorization"] as? String
      {
        observedAuthorizationHeaders.record(authorization)
        let suffix = authorization.replacingOccurrences(of: "Bearer token-", with: "")
        response(Self.listResponse(ids: ["message-\(suffix)"], nextPageToken: nil), nil)
      } else if let query = ticket.originalQuery as? GTLRGmailQuery_UsersMessagesGet,
        let identifier = query.identifier
      {
        response(Self.messageResponse(messageId: identifier), nil)
      } else {
        response(nil, NSError(domain: "Qualification", code: 1))
      }
    }
    let tokenRefresher = QualificationTokenRefresher()
    let candidate = ExperimentalGoogleGmailRESTSearchService(
      client: GoogleGmailRESTClient(service: service),
      tokenRefresher: tokenRefresher
    )
    let secondConnection = connection(
      providerAccountIdentifier: "gmail-user-002",
      emailAddress: "other@example.com"
    )

    async let first = candidate.searchProvider(
      query: "first",
      connection: connection,
      session: session
    )
    async let second = candidate.searchProvider(
      query: "second",
      connection: secondConnection,
      session: session
    )

    let (firstMessages, secondMessages) = try await (first, second)
    #expect(firstMessages.map(\.providerMessageId) == ["message-gmail-user-001"])
    #expect(secondMessages.map(\.providerMessageId) == ["message-gmail-user-002"])
    #expect(firstMessages.allSatisfy { $0.providerAccountIdentifier == "gmail-user-001" })
    #expect(secondMessages.allSatisfy { $0.providerAccountIdentifier == "gmail-user-002" })
    #expect(
      observedAuthorizationHeaders.values == [
        "Bearer token-gmail-user-001",
        "Bearer token-gmail-user-002",
      ])
  }

  @Test
  func testGeneratedClientDisablesRetriesAndAutomaticPagination() {
    let service = GTLRGmailService()
    _ = GoogleGmailRESTClient(service: service)

    #expect(!service.isRetryEnabled)
    #expect(!service.shouldFetchNextPages)
    #expect(!GTMSessionFetcher.isLoggingEnabled())
    #expect(GoogleGmailRESTClientBuildPolicy.dependencyVersion == "5.4.0")
    #expect(
      GoogleGmailRESTClientBuildPolicy.dependencyRevision
        == "07cd7c8ca9119dc08afd4bad52280bd3b763196c")
  }

  private func makeService(
    transport: Transport,
    failure: Failure?
  ) throws -> any GmailMessageSearching {
    switch transport {
    case .direct:
      let tokenStore = QualificationTokenStore()
      try tokenStore.save(
        GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      let urlSession = ConvexClientTesting.makeSession(
        protocolClass: GmailRESTQualificationURLStub.self
      ) { request in
        Self.directResponse(for: request, failure: failure)
      }
      return GmailMessageMetadataService(
        gmailBaseURL: URL(string: "https://gmail.example.test/gmail/v1")!,
        oauthClientId: "gmail-client-id",
        session: urlSession,
        tokenStore: tokenStore,
        tokenInfoURL: URL(string: "https://oauth.example.test/tokeninfo")!,
        tokenRefreshURL: URL(string: "https://oauth.example.test/token")!
      )
    case .generatedClient:
      if failure == .authentication {
        return ExperimentalGoogleGmailRESTSearchService(
          tokenRefresher: FailingQualificationTokenRefresher(
            error: GmailMessageMetadataSyncError.oauthResponseStatus(401)
          )
        )
      }
      let service = GTLRGmailService()
      service.testBlock = { ticket, response in
        Self.generatedClientResponse(for: ticket, response: response, failure: failure)
      }
      return ExperimentalGoogleGmailRESTSearchService(
        client: GoogleGmailRESTClient(service: service),
        tokenRefresher: QualificationTokenRefresher()
      )
    }
  }

  private static func directResponse(
    for request: URLRequest,
    failure: Failure?
  ) -> (HTTPURLResponse, Data) {
    let statusCode: Int
    let data: Data
    switch request.url?.path {
    case "/token":
      statusCode = failure == .authentication ? 401 : 200
      data = Data(#"{"access_token":"access-token"}"#.utf8)
    case "/tokeninfo":
      statusCode = 200
      data = Data(#"{"sub":"gmail-user-001","email":"user@example.com"}"#.utf8)
    case "/gmail/v1/users/me/messages":
      if failure == .rateLimit {
        statusCode = 429
        data = Data()
      } else if failure == .malformedResponse {
        statusCode = 200
        data = Data("{".utf8)
      } else if request.url?.query?.contains("pageToken=next-page") == true {
        statusCode = 200
        data = Data(#"{"messages":[{"id":"message-002"}]}"#.utf8)
      } else {
        statusCode = 200
        data = Data(
          #"{"messages":[{"id":"message-001"}],"nextPageToken":"next-page"}"#.utf8
        )
      }
    default:
      statusCode = 200
      data = messageResponseData(messageId: request.url?.lastPathComponent ?? "")
    }
    return (
      HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
      )!,
      data
    )
  }

  private static func generatedClientResponse(
    for ticket: GTLRServiceTicket,
    response: @escaping (Any?, Error?) -> Void,
    failure: Failure?
  ) {
    if failure == .rateLimit {
      response(nil, NSError(domain: "GTLRGmail", code: 429))
      return
    }
    if let query = ticket.originalQuery as? GTLRGmailQuery_UsersMessagesList {
      if failure == .malformedResponse {
        response(listResponse(ids: [nil], nextPageToken: nil), nil)
      } else if query.pageToken == "next-page" {
        response(listResponse(ids: ["message-002"], nextPageToken: nil), nil)
      } else {
        response(listResponse(ids: ["message-001"], nextPageToken: "next-page"), nil)
      }
      return
    }
    if let query = ticket.originalQuery as? GTLRGmailQuery_UsersMessagesGet,
      let identifier = query.identifier
    {
      response(messageResponse(messageId: identifier), nil)
      return
    }
    response(nil, NSError(domain: "Qualification", code: 2))
  }

  private static func listResponse(
    ids: [String?],
    nextPageToken: String?
  ) -> GTLRGmail_ListMessagesResponse {
    let list = GTLRGmail_ListMessagesResponse()
    list.messages = ids.map { identifier in
      let message = GTLRGmail_Message()
      message.identifier = identifier
      return message
    }
    list.nextPageToken = nextPageToken
    return list
  }

  private static func messageResponse(messageId: String) -> GTLRGmail_Message {
    let message = GTLRGmail_Message()
    message.identifier = messageId
    message.threadId = "thread-\(messageId)"
    message.internalDate = 1_784_073_600_000
    message.json?["internalDate"] = "1784073600000"
    message.labelIds = ["INBOX", "UNREAD"]
    message.snippet = "Provider result"
    let payload = GTLRGmail_MessagePart()
    payload.headers = [
      header(name: "From", value: "Sender <sender@example.com>"),
      header(name: "To", value: "User <user@example.com>"),
      header(name: "Subject", value: "Thread subject"),
    ]
    message.payload = payload
    return message
  }

  private static func header(name: String, value: String) -> GTLRGmail_MessagePartHeader {
    let header = GTLRGmail_MessagePartHeader()
    header.name = name
    header.value = value
    return header
  }

  private static func messageResponseData(messageId: String) -> Data {
    Data(
      """
      {
        "id":"\(messageId)",
        "threadId":"thread-\(messageId)",
        "internalDate":"1784073600000",
        "labelIds":["INBOX","UNREAD"],
        "snippet":"Provider result",
        "payload":{"headers":[
          {"name":"From","value":"Sender <sender@example.com>"},
          {"name":"To","value":"User <user@example.com>"},
          {"name":"Subject","value":"Thread subject"}
        ]}
      }
      """.utf8
    )
  }

  private func connection(
    providerAccountIdentifier: String,
    emailAddress: String
  ) -> GmailProviderConnectionStatus {
    GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: emailAddress,
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: providerAccountIdentifier,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
  }
}

private struct QualificationTokenRefresher: GmailProviderTokenRefreshing {
  func refreshProviderTokens(
    connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderTokens {
    GmailProviderTokens(
      accessToken: "token-\(connection.providerAccountIdentifier)",
      refreshToken: "unused"
    )
  }
}

private struct FailingQualificationTokenRefresher: GmailProviderTokenRefreshing {
  let error: Error

  func refreshProviderTokens(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderTokens {
    throw error
  }
}

private final class QualificationTokenStore: GmailProviderTokenPersisting {
  private let lock = NSLock()
  private var tokens: [String: GmailProviderTokens] = [:]

  func clear(productAccountId: String, providerAccountIdentifier: String) throws {
    lock.withLock { tokens[key(productAccountId, providerAccountIdentifier)] = nil }
  }

  func clearAll(productAccountId: String) throws {
    lock.withLock {
      tokens = tokens.filter { !$0.key.hasPrefix("\(productAccountId):") }
    }
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailProviderTokens? {
    lock.withLock { tokens[key(productAccountId, providerAccountIdentifier)] }
  }

  func save(
    _ tokens: GmailProviderTokens,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    lock.withLock { self.tokens[key(productAccountId, providerAccountIdentifier)] = tokens }
  }

  private func key(_ productAccountId: String, _ providerAccountIdentifier: String) -> String {
    "\(productAccountId):\(providerAccountIdentifier)"
  }
}

private final class LockedAuthorizationHeaders: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Set<String> = []

  var values: Set<String> { lock.withLock { storage } }

  func record(_ value: String) {
    _ = lock.withLock { storage.insert(value) }
  }
}
