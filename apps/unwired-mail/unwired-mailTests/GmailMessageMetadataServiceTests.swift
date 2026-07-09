import XCTest

@testable import unwired_mail

// swiftlint:disable type_body_length
final class GmailMessageMetadataServiceTests: XCTestCase {
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

  func testSyncInboxStoresMetadataWithStableProviderIdentityAndNoCategory() async throws {
    let fixture = try makeSyncFixture()

    let result = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    XCTAssertEqual(
      fixture.requestRecorder.paths,
      [
        "/token",
        "/gmail/v1/users/me/messages",
        "/gmail/v1/users/me/messages/message-002",
        "/gmail/v1/users/me/messages/message-001",
      ]
    )
    XCTAssertEqual(result.messages.map(\.providerMessageId), ["message-002", "message-001"])
    XCTAssertEqual(result.threads.count, 1)
    XCTAssertEqual(result.threads[0].providerThreadId, "thread-001")
    XCTAssertEqual(result.threads[0].messages.count, 2)
    XCTAssertEqual(
      result.messages[0].stableProviderMessageId,
      "gmail:gmail-user-001:message-002"
    )
    XCTAssertTrue(result.messages.allSatisfy(\.isHistorical))
    XCTAssertTrue(result.messages.allSatisfy { $0.categoryId == nil })
    XCTAssertEqual(fixture.store.savedMessages, result.messages)
    XCTAssertEqual(
      try fixture.tokenStore.load(productAccountId: session.productAccountId),
      GmailProviderTokens(accessToken: "refreshed-access-token", refreshToken: "refresh-token")
    )
  }

  func testLoadInboxGroupsPersistedMessagesIntoThreads() async throws {
    let store = RecordingGmailMessageMetadataStore()
    store.messages = [
      metadata(
        messageId: "message-001",
        threadId: "thread-001",
        internalDateMilliseconds: 10
      ),
      metadata(
        messageId: "message-003",
        threadId: "thread-002",
        internalDateMilliseconds: 30
      ),
      metadata(
        messageId: "message-002",
        threadId: "thread-001",
        internalDateMilliseconds: 20
      ),
    ]
    let service = GmailMessageMetadataService(
      store: store,
      tokenStore: RecordingGmailProviderTokenStore()
    )

    let result = try await service.loadInbox(
      connection: connection,
      session: session
    )

    XCTAssertEqual(result.threads.map(\.providerThreadId), ["thread-002", "thread-001"])
    XCTAssertEqual(
      result.threads[1].messages.map(\.providerMessageId), ["message-002", "message-001"])
  }

  func testSyncInboxUsesLatestConnectionUpdateAsFirstSyncHistoricalCutoff() async throws {
    let fixture = try makeSyncFixture()
    let switchedConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_180_000_000,
      emailAddress: connection.emailAddress,
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: 1_781_200_000_000
    )

    let result = try await fixture.service.syncInbox(
      connection: switchedConnection,
      session: session
    )

    XCTAssertTrue(result.messages.allSatisfy(\.isHistorical))
  }

  func testSyncInboxPreservesExistingHistoricalStateWhenRefreshingMetadata() async throws {
    let fixture = try makeSyncFixture()
    fixture.store.messages = [
      metadata(
        messageId: "message-002",
        threadId: "thread-001",
        internalDateMilliseconds: 1_781_197_200_000
      )
    ]
    let connectionWithOlderCutoff = GmailProviderConnectionStatus(
      connectedAt: 1_781_180_000_000,
      emailAddress: connection.emailAddress,
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: 1_781_200_000_000
    )

    let result = try await fixture.service.syncInbox(
      connection: connectionWithOlderCutoff,
      session: session
    )

    XCTAssertEqual(
      result.messages.first { $0.providerMessageId == "message-002" }?.isHistorical,
      true
    )
  }

  func testSyncInboxRequiresDeviceHeldGmailTokens() async throws {
    let service = GmailMessageMetadataService(
      session: ConvexClientTesting.makeSession { request in
        XCTFail("Unexpected request: \(String(describing: request.url))")
        return (Self.httpResponse(for: request, statusCode: 200), Data())
      },
      store: RecordingGmailMessageMetadataStore(),
      tokenStore: RecordingGmailProviderTokenStore()
    )

    do {
      _ = try await service.syncInbox(
        connection: connection,
        session: session
      )
      XCTFail("Expected missing local tokens")
    } catch GmailMessageMetadataSyncError.missingLocalGmailTokens {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private static func httpResponse(
    for request: URLRequest,
    statusCode: Int
  ) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
  }

  private static func messageMetadataResponseData(
    messageId: String,
    internalDate: String,
    snippet: String
  ) -> Data {
    Data(
      """
      {
        "id": "\(messageId)",
        "threadId": "thread-001",
        "internalDate": "\(internalDate)",
        "snippet": "\(snippet)",
        "payload": {
          "headers": [
            {"name": "From", "value": "Sender <sender@example.com>"},
            {"name": "Subject", "value": "Thread subject"}
          ]
        }
      }
      """.utf8
    )
  }

  private func makeSyncFixture() throws -> GmailMessageMetadataSyncFixture {
    let store = RecordingGmailMessageMetadataStore()
    let tokenStore = RecordingGmailProviderTokenStore()
    let requestRecorder = GmailMetadataRequestRecorder()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let urlSession = ConvexClientTesting.makeSession { request in
      self.makeSyncResponse(
        for: request,
        requestRecorder: requestRecorder
      )
    }
    let service = GmailMessageMetadataService(
      gmailBaseURL: URL(string: "https://gmail.example.test/gmail/v1")!,
      oauthClientId: "gmail-client-id",
      session: urlSession,
      store: store,
      tokenStore: tokenStore,
      tokenRefreshURL: URL(string: "https://oauth.example.test/token")!
    )
    return GmailMessageMetadataSyncFixture(
      requestRecorder: requestRecorder,
      service: service,
      store: store,
      tokenStore: tokenStore
    )
  }

  private func makeSyncResponse(
    for request: URLRequest,
    requestRecorder: GmailMetadataRequestRecorder
  ) -> (HTTPURLResponse, Data) {
    requestRecorder.paths.append(request.url?.path ?? "")

    if request.url?.path == "/token" {
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Content-Type"),
        "application/x-www-form-urlencoded"
      )
      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
      )
    }

    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"),
      "Bearer refreshed-access-token"
    )

    if request.url?.path == "/gmail/v1/users/me/messages" {
      XCTAssertTrue(request.url?.query?.contains("labelIds=INBOX") == true)
      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(#"{"messages":[{"id":"message-002"},{"id":"message-001"}]}"#.utf8)
      )
    }

    return (
      Self.httpResponse(for: request, statusCode: 200),
      makeMessageMetadataResponseData(for: request)
    )
  }

  private func makeMessageMetadataResponseData(for request: URLRequest) -> Data {
    if request.url?.path == "/gmail/v1/users/me/messages/message-001" {
      return Self.messageMetadataResponseData(
        messageId: "message-001",
        internalDate: "1781190000000",
        snippet: "Older message snippet"
      )
    }

    return Self.messageMetadataResponseData(
      messageId: "message-002",
      internalDate: "1781197200000",
      snippet: "Latest message snippet"
    )
  }

  private func metadata(
    messageId: String,
    threadId: String,
    internalDateMilliseconds: Int64
  ) -> GmailMessageMetadata {
    GmailMessageMetadata(
      categoryId: nil,
      from: "Sender <sender@example.com>",
      isHistorical: true,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      providerInternalDateMilliseconds: internalDateMilliseconds,
      providerMessageId: messageId,
      providerThreadId: threadId,
      snippet: "Snippet",
      stableProviderMessageId: "gmail:gmail-user-001:\(messageId)",
      subject: "Subject"
    )
  }
}

private struct GmailMessageMetadataSyncFixture {
  let requestRecorder: GmailMetadataRequestRecorder
  let service: GmailMessageMetadataService
  let store: RecordingGmailMessageMetadataStore
  let tokenStore: RecordingGmailProviderTokenStore
}

private final class GmailMetadataRequestRecorder {
  var paths: [String] = []
}

private final class RecordingGmailMessageMetadataStore: GmailMessageMetadataPersisting {
  var didClear = false
  var messages: [GmailMessageMetadata] = []
  var savedMessages: [GmailMessageMetadata] = []

  func clearMessages(productAccountId _: String) throws {
    didClear = true
    messages = []
    savedMessages = []
  }

  func loadMessages(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> [GmailMessageMetadata] {
    messages
  }

  func saveMessages(
    _ messages: [GmailMessageMetadata],
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    savedMessages = messages
    self.messages = messages
  }
}

private final class RecordingGmailProviderTokenStore: GmailProviderTokenPersisting {
  var tokensByProductAccountId: [String: GmailProviderTokens] = [:]

  func clear(productAccountId: String) throws {
    tokensByProductAccountId[productAccountId] = nil
  }

  func load(productAccountId: String) throws -> GmailProviderTokens? {
    tokensByProductAccountId[productAccountId]
  }

  func save(
    _ tokens: GmailProviderTokens,
    productAccountId: String
  ) throws {
    tokensByProductAccountId[productAccountId] = tokens
  }
}
