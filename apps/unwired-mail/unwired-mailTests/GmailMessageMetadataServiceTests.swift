import XCTest

@testable import unwired_mail

// swiftlint:disable file_length function_body_length type_body_length
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
        "/tokeninfo",
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

  func testSyncInboxStoresReplyToHeader() async throws {
    let fixture = try makeSyncFixture(replyTo: "Replies <replies@example.com>")

    let result = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    XCTAssertEqual(
      result.messages.first { $0.providerMessageId == "message-002" }?.replyTo,
      "Replies <replies@example.com>"
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

  func testOverrideCategoryPersistsUpdatedMessageMetadata() async throws {
    let message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    )
    let store = RecordingGmailMessageMetadataStore()
    store.messages = [message]
    let categorizer = RecordingGmailMessageCategorizer()
    let service = GmailMessageMetadataService(
      categorizer: categorizer,
      store: store,
      tokenStore: RecordingGmailProviderTokenStore()
    )

    let overridden = try await service.overrideCategory(
      "system:invoices",
      for: message,
      session: session
    )

    XCTAssertEqual(overridden.categoryId, "system:invoices")
    XCTAssertEqual(store.savedMessages, [overridden])
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

  func testSyncInboxCategorizesAndPersistsMessagesAfterAccountInstall() async throws {
    let categorizer = RecordingGmailMessageCategorizer(categoryId: "system:promotions")
    let fixture = try makeSyncFixture(categorizer: categorizer)
    let installedConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_100_000_000,
      emailAddress: connection.emailAddress,
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: 1_781_100_000_000
    )

    let result = try await fixture.service.syncInbox(
      connection: installedConnection,
      session: session
    )

    XCTAssertTrue(categorizer.receivedMessages.allSatisfy { !$0.isHistorical })
    XCTAssertEqual(
      categorizer.receivedMessages.map(\.stableProviderMessageId),
      ["gmail:gmail-user-001:message-002", "gmail:gmail-user-001:message-001"]
    )
    XCTAssertTrue(result.messages.allSatisfy { $0.categoryId == "system:promotions" })
    XCTAssertEqual(fixture.store.savedMessages, result.messages)
  }

  func testSyncInboxFollowsGmailPaginationBeforeSavingMetadata() async throws {
    let fixture = try makeSyncFixture(usesPagination: true)

    let result = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    XCTAssertEqual(
      result.messages.map(\.providerMessageId),
      [
        "message-003",
        "message-002",
        "message-001",
      ])
    XCTAssertEqual(
      fixture.requestRecorder.queries.filter { $0.contains("labelIds=INBOX") },
      [
        "labelIds=INBOX&maxResults=25",
        "labelIds=INBOX&maxResults=25&pageToken=next-page-token",
      ]
    )
    XCTAssertEqual(
      fixture.store.savedMessages.map(\.providerMessageId),
      [
        "message-003",
        "message-002",
        "message-001",
      ])
  }

  func testSyncInboxRejectsRefreshedTokenForDifferentGoogleAccount() async throws {
    let fixture = try makeSyncFixture(tokenInfoSubject: "different-gmail-user")

    do {
      _ = try await fixture.service.syncInbox(
        connection: connection,
        session: session
      )
      XCTFail("Expected refreshed token account mismatch")
    } catch GmailMessageMetadataSyncError.refreshedTokenAccountMismatch {
      XCTAssertEqual(fixture.store.savedMessages, [])
      XCTAssertFalse(
        fixture.requestRecorder.paths.contains("/gmail/v1/users/me/messages")
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
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

  func testProviderActionsUseGmailModifyAndTrashEndpoints() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.perform(
      .markUnread,
      messageIds: ["message-001"],
      connection: connection,
      session: session
    )
    try await fixture.service.perform(
      .delete,
      messageIds: ["message-001"],
      connection: connection,
      session: session
    )

    XCTAssertEqual(
      fixture.recorder.requests.map(\.path),
      [
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/modify",
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/trash",
      ])
    XCTAssertEqual(fixture.recorder.requests[2].method, "POST")
    XCTAssertEqual(fixture.recorder.requests[2].jsonBody["addLabelIds"] as? [String], ["UNREAD"])
    XCTAssertEqual(fixture.recorder.requests[2].jsonBody["removeLabelIds"] as? [String], [])
    XCTAssertEqual(fixture.recorder.requests[5].method, "POST")
  }

  func testProviderThreadActionsAuthorizeOnce() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.perform(
      .archive,
      messageIds: ["message-001", "message-002"],
      connection: connection,
      session: session
    )

    XCTAssertEqual(
      fixture.recorder.requests.map(\.path),
      [
        "/token", "/tokeninfo",
        "/gmail/v1/users/me/messages/message-001/modify",
        "/gmail/v1/users/me/messages/message-002/modify",
      ]
    )
  }

  func testProviderActionsRequireGmailWriteScope() async throws {
    let fixture = try makeMailActionFixture(
      tokenScopes: "https://www.googleapis.com/auth/gmail.readonly"
    )

    do {
      try await fixture.service.perform(
        .archive,
        messageIds: ["message-001"],
        connection: connection,
        session: session
      )
      XCTFail("Expected insufficient Gmail scope")
    } catch GmailMessageMetadataSyncError.insufficientGmailScope {
      XCTAssertEqual(fixture.recorder.requests.map(\.path), ["/token", "/tokeninfo"])
    }
  }

  func testSendAcceptsGmailModifyScope() async throws {
    let fixture = try makeMailActionFixture(
      tokenScopes: "https://www.googleapis.com/auth/gmail.modify"
    )

    try await fixture.service.send(
      GmailOutgoingMessage(body: "Café", recipient: "recipient@example.com", subject: "Subject"),
      connection: connection,
      session: session
    )

    XCTAssertEqual(fixture.recorder.requests.last?.path, "/gmail/v1/users/me/messages/send")
  }

  func testSendUsesGmailRawMessageEndpoint() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.send(
      GmailOutgoingMessage(body: "Café", recipient: "recipient@example.com", subject: "Subject"),
      connection: connection,
      session: session
    )

    let sentRequest = fixture.recorder.requests.last
    XCTAssertEqual(sentRequest?.path, "/gmail/v1/users/me/messages/send")
    XCTAssertEqual(sentRequest?.method, "POST")
    let raw = try XCTUnwrap(sentRequest?.jsonBody["raw"] as? String)
    let paddedRaw =
      raw.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try XCTUnwrap(Data(base64Encoded: paddedRaw))
    let expectedMIME = [
      "To: recipient@example.com",
      "From: user@example.com",
      "Subject: Subject",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=utf-8",
      "Content-Transfer-Encoding: 8bit",
      "",
      "Café",
    ].joined(separator: "\r\n")
    XCTAssertEqual(String(bytes: mime, encoding: .utf8), expectedMIME)
  }

  func testSendEncodesRecipientDisplayName() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.send(
      GmailOutgoingMessage(
        body: "Hello",
        recipient: "José García <jose@example.com>",
        subject: "Subject"
      ),
      connection: connection,
      session: session
    )

    let raw = try XCTUnwrap(fixture.recorder.requests.last?.jsonBody["raw"] as? String)
    let paddedRaw =
      raw.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try XCTUnwrap(Data(base64Encoded: paddedRaw))
    let mimeText = try XCTUnwrap(String(bytes: mime, encoding: .utf8))
    XCTAssertTrue(mimeText.contains("To: =?UTF-8?B?Sm9zw6kgR2FyY8OtYQ==?= <jose@example.com>"))
  }

  func testSendPreservesMultipleRecipientsWhenEncodingDisplayNames() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.send(
      GmailOutgoingMessage(
        body: "Hello",
        recipient: "Alice <alice@example.com>, José <jose@example.com>",
        subject: "Subject"
      ),
      connection: connection,
      session: session
    )

    let raw = try XCTUnwrap(fixture.recorder.requests.last?.jsonBody["raw"] as? String)
    let paddedRaw =
      raw.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try XCTUnwrap(Data(base64Encoded: paddedRaw))
    let mimeText = try XCTUnwrap(String(bytes: mime, encoding: .utf8))
    XCTAssertTrue(
      mimeText.contains("To: Alice <alice@example.com>, =?UTF-8?B?Sm9zw6k=?= <jose@example.com>")
    )
  }

  func testSendEncodesQuotedDisplayNameWithComma() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.send(
      GmailOutgoingMessage(
        body: "Hello",
        recipient: "\"García, José\" <jose@example.com>",
        subject: "Subject"
      ),
      connection: connection,
      session: session
    )

    let raw = try XCTUnwrap(fixture.recorder.requests.last?.jsonBody["raw"] as? String)
    let paddedRaw =
      raw.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try XCTUnwrap(Data(base64Encoded: paddedRaw))
    let mimeText = try XCTUnwrap(String(bytes: mime, encoding: .utf8))
    XCTAssertTrue(mimeText.contains("To: =?UTF-8?B?IkdhcmPDrWEsIEpvc8OpIg==?= <jose@example.com>"))
  }

  func testSendAddsReplyThreadingHeadersAndRejectsHeaderInjection() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.send(
      GmailOutgoingMessage(
        body: "Hello",
        recipient: "recipient@example.com",
        subject: "Subject",
        inReplyTo: "<original@example.com>",
        threadId: "thread-001"
      ),
      connection: connection,
      session: session
    )

    let sentRequest = try XCTUnwrap(fixture.recorder.requests.last)
    XCTAssertEqual(sentRequest.jsonBody["threadId"] as? String, "thread-001")
    let raw = try XCTUnwrap(sentRequest.jsonBody["raw"] as? String)
    let paddedRaw = raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try XCTUnwrap(Data(base64Encoded: paddedRaw))
    let mimeText = try XCTUnwrap(String(bytes: mime, encoding: .utf8))
    XCTAssertTrue(mimeText.contains("In-Reply-To: <original@example.com>"))
    XCTAssertTrue(mimeText.contains("References: <original@example.com>"))

    do {
      try await fixture.service.send(
        GmailOutgoingMessage(
          body: "Hello",
          recipient: "victim@example.com\r\nBcc: bad",
          subject: "Subject"
        ),
        connection: connection,
        session: session
      )
      XCTFail("Expected header validation failure")
    } catch GmailMessageMetadataSyncError.invalidMessageHeader {
    }
  }

  private func makeMailActionFixture(
    tokenScopes: String =
      "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.send"
  ) throws -> GmailMailActionFixture {
    let tokenStore = RecordingGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let recorder = GmailMailActionRequestRecorder()
    let urlSession = ConvexClientTesting.makeSession { request in
      recorder.requests.append(GmailMailActionRequest(request: request))
      switch request.url?.path {
      case "/token":
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      case "/tokeninfo":
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(
            "{\"sub\":\"gmail-user-001\",\"email\":\"user@example.com\",\"scope\":\"\(tokenScopes)\"}"
              .utf8
          )
        )
      default:
        return (Self.httpResponse(for: request, statusCode: 200), Data())
      }
    }
    return GmailMailActionFixture(
      recorder: recorder,
      service: GmailMessageMetadataService(
        gmailBaseURL: URL(string: "https://gmail.example.test/gmail/v1")!,
        oauthClientId: "gmail-client-id",
        session: urlSession,
        tokenStore: tokenStore,
        tokenInfoURL: URL(string: "https://oauth.example.test/tokeninfo")!,
        tokenRefreshURL: URL(string: "https://oauth.example.test/token")!
      )
    )
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
    snippet: String,
    replyTo: String? = nil
  ) -> Data {
    let replyToHeader =
      replyTo.map {
        ",\n            {\"name\": \"Reply-To\", \"value\": \"\($0)\"}"
      } ?? ""
    return Data(
      """
      {
        "id": "\(messageId)",
        "threadId": "thread-001",
        "internalDate": "\(internalDate)",
        "snippet": "\(snippet)",
        "payload": {
          "headers": [
            {"name": "From", "value": "Sender <sender@example.com>"},
            {"name": "Subject", "value": "Thread subject"}\(replyToHeader)
          ]
        }
      }
      """.utf8
    )
  }

  private func makeSyncFixture(
    categorizer: GmailMessageCategorizing = RecordingGmailMessageCategorizer(),
    tokenInfoSubject: String = "gmail-user-001",
    usesPagination: Bool = false,
    replyTo: String? = nil
  ) throws -> GmailMessageMetadataSyncFixture {
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
        requestRecorder: requestRecorder,
        tokenInfoSubject: tokenInfoSubject,
        usesPagination: usesPagination,
        replyTo: replyTo
      )
    }
    let service = GmailMessageMetadataService(
      categorizer: categorizer,
      gmailBaseURL: URL(string: "https://gmail.example.test/gmail/v1")!,
      oauthClientId: "gmail-client-id",
      session: urlSession,
      store: store,
      tokenStore: tokenStore,
      tokenInfoURL: URL(string: "https://oauth.example.test/tokeninfo")!,
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
    requestRecorder: GmailMetadataRequestRecorder,
    tokenInfoSubject: String,
    usesPagination: Bool,
    replyTo: String?
  ) -> (HTTPURLResponse, Data) {
    requestRecorder.paths.append(request.url?.path ?? "")
    requestRecorder.queries.append(request.url?.query ?? "")

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

    if request.url?.path == "/tokeninfo" {
      XCTAssertEqual(request.url?.query, "access_token=refreshed-access-token")
      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(
          """
          {"sub":"\(tokenInfoSubject)","email":"user@example.com"}
          """.utf8
        )
      )
    }

    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"),
      "Bearer refreshed-access-token"
    )

    if request.url?.path == "/gmail/v1/users/me/messages" {
      XCTAssertTrue(request.url?.query?.contains("labelIds=INBOX") == true)
      if usesPagination, request.url?.query?.contains("pageToken=next-page-token") == true {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"messages":[{"id":"message-001"}]}"#.utf8)
        )
      }
      if usesPagination {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(
            #"{"messages":[{"id":"message-003"},{"id":"message-002"}],"nextPageToken":"next-page-token"}"#
              .utf8
          )
        )
      }
      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(#"{"messages":[{"id":"message-002"},{"id":"message-001"}]}"#.utf8)
      )
    }

    return (
      Self.httpResponse(for: request, statusCode: 200),
      makeMessageMetadataResponseData(for: request, replyTo: replyTo)
    )
  }

  private func makeMessageMetadataResponseData(
    for request: URLRequest,
    replyTo: String?
  ) -> Data {
    if request.url?.path == "/gmail/v1/users/me/messages/message-001" {
      return Self.messageMetadataResponseData(
        messageId: "message-001",
        internalDate: "1781190000000",
        snippet: "Older message snippet",
        replyTo: replyTo
      )
    }

    if request.url?.path == "/gmail/v1/users/me/messages/message-003" {
      return Self.messageMetadataResponseData(
        messageId: "message-003",
        internalDate: "1781199000000",
        snippet: "Newest message snippet",
        replyTo: replyTo
      )
    }

    return Self.messageMetadataResponseData(
      messageId: "message-002",
      internalDate: "1781197200000",
      snippet: "Latest message snippet",
      replyTo: replyTo
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
      replyTo: nil,
      snippet: "Snippet",
      stableProviderMessageId: "gmail:gmail-user-001:\(messageId)",
      subject: "Subject",
      rfcMessageId: nil
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
  var queries: [String] = []
}

private final class RecordingGmailMessageCategorizer: GmailMessageCategorizing {
  private let categoryId: String?
  private(set) var receivedMessages: [GmailMessageMetadata] = []

  init(categoryId: String? = nil) {
    self.categoryId = categoryId
  }

  func categorize(
    messages: [GmailMessageMetadata],
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    receivedMessages = messages
    guard let categoryId else {
      return messages
    }
    return messages.map { message in
      GmailMessageMetadata(
        categoryId: categoryId,
        from: message.from,
        isHistorical: message.isHistorical,
        providerAccountIdentifier: message.providerAccountIdentifier,
        providerInternalDateMilliseconds: message.providerInternalDateMilliseconds,
        providerMessageId: message.providerMessageId,
        providerThreadId: message.providerThreadId,
        replyTo: message.replyTo,
        snippet: message.snippet,
        stableProviderMessageId: message.stableProviderMessageId,
        subject: message.subject,
        rfcMessageId: message.rfcMessageId
      )
    }
  }

  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    GmailMessageMetadata(
      categoryId: categoryId,
      from: message.from,
      isHistorical: message.isHistorical,
      providerAccountIdentifier: message.providerAccountIdentifier,
      providerInternalDateMilliseconds: message.providerInternalDateMilliseconds,
      providerMessageId: message.providerMessageId,
      providerThreadId: message.providerThreadId,
      replyTo: message.replyTo,
      snippet: message.snippet,
      stableProviderMessageId: message.stableProviderMessageId,
      subject: message.subject,
      rfcMessageId: message.rfcMessageId
    )
  }
}

private struct GmailMailActionFixture {
  let recorder: GmailMailActionRequestRecorder
  let service: GmailMessageMetadataService
}

private final class GmailMailActionRequestRecorder {
  var requests: [GmailMailActionRequest] = []
}

private struct GmailMailActionRequest {
  let jsonBody: [String: Any]
  let method: String
  let path: String

  init(request: URLRequest) {
    method = request.httpMethod ?? "GET"
    path = request.url?.path ?? ""
    jsonBody =
      (try? JSONSerialization.jsonObject(with: Self.bodyData(for: request))) as? [String: Any]
      ?? [:]
  }

  private static func bodyData(for request: URLRequest) -> Data {
    if let body = request.httpBody {
      return body
    }

    guard let stream = request.httpBodyStream else {
      return Data()
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
      let count = stream.read(buffer, maxLength: bufferSize)
      if count <= 0 {
        break
      }
      data.append(buffer, count: count)
    }

    return data
  }
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
