import XCTest

@testable import unwired_mail

// swiftlint:disable file_length function_body_length type_body_length

final class GmailMessageBodyServiceTests: XCTestCase {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "apple-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  private let message = GmailMessageMetadata(
    categoryId: "travel",
    from: "Sender <sender@example.com>",
    isHistorical: true,
    providerAccountIdentifier: "gmail-user-001",
    providerInternalDateMilliseconds: 1_781_197_200_000,
    providerMessageId: "message-001",
    providerThreadId: "thread-001",
    replyTo: nil,
    snippet: "Body preview",
    stableProviderMessageId: "gmail:gmail-user-001:message-001",
    subject: "Trip details",
    rfcMessageId: nil
  )

  func testReadFetchesBodyOnDemandAndCachesOnlyEncryptedPayload() async throws {
    let fixture = try makeFixture()

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.text, "Private trip details")
    XCTAssertEqual(
      fixture.requestPaths, ["/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001"])
    XCTAssertNotNil(fixture.cache.payload)
    XCTAssertFalse(fixture.cache.serializedPayload.contains("Private trip details"))

    let cachedBody = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(cachedBody, body)
    XCTAssertEqual(
      fixture.requestPaths, ["/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001"])
  }

  func testCachedReadDoesNotFetchMissingBodyFromGmail() throws {
    let fixture = try makeFixture()

    let body = try fixture.service.loadCachedMessageBody(message: message, session: session)

    XCTAssertNil(body)
    XCTAssertEqual(fixture.requestPaths, [])
  }

  func testReadPreservesSeparatorsBetweenHTMLTableCells() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"text/html","body":{"data":""#
        + #"PHRhYmxlPjx0cj48dGQ+SGk8L3RkPjx0ZD5UaGVyZTwvdGQ+PC90cj48L3RhYmxlPg=="#
        + #""}}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.text, "\nHi\n\nThere\n\n")
  }

  func testReadRemovesNonVisibleHTMLContentAndDecodesEntities() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"text/html","body":{"data":""#
        + #"PHN0eWxlPi5idXR0b257Y29sb3I6cmVkfTwvc3R5bGU+PHNjcmlwdD50cmFjaygpPC9zY3JpcHQ+PHA+"#
        + #"VG9tICZhbXA7IEplcnJ5Jm5ic3A7PC9wPg=="#
        + #""}}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertFalse(body.text.contains(".button"))
    XCTAssertFalse(body.text.contains("track()"))
    XCTAssertTrue(body.text.contains("Tom & Jerry\u{00A0}"))
  }

  func testReadDecodesNamedAndNumericHTMLEntities() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"text/html","body":{"data":""#
        + #"PHA+VG9tJnJzcXVvO3MmbmJzcDtub3RlJm1kYXNoOyYjODIxNzs8L3A+"#
        + #""}}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertTrue(body.text.contains("Tom’s\u{00A0}note—’"))
  }

  func testReadPreservesAttributedHTMLLineBreaks() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"text/html","body":{"data":""#
        + #"PHA+Rmlyc3Q8YnIgY2xhc3M9Im1lc3NhZ2UtYnJlYWsiPlNlY29uZDwvcD4="#
        + #""}}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertTrue(body.text.contains("First\nSecond"))
  }

  func testReadPrefersHTMLOverWhitespaceOnlyPlainTextAlternative() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"multipart/alternative","parts":["#
        + #"{"mimeType":"text/plain","body":{"data":"DQo="}},"#
        + #"{"mimeType":"text/html","body":{"data":"PHA+QWN0dWFsIGNvbnRlbnQ8L3A+"}}]}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertTrue(body.text.contains("Actual content"))
  }

  func testReadRejectsMetadataOnlyTokenBeforeFetchingMessage() async throws {
    let fixture = try makeFixture(
      tokenInfoResponse:
        #"{"scope":"https://www.googleapis.com/auth/gmail.metadata","sub":"gmail-user-001"}"#
    )

    do {
      _ = try await fixture.service.loadMessageBody(message: message, session: session)
      XCTFail("Expected Gmail request failure")
    } catch GmailMessageBodyError.gmailRequestFailed {
      XCTAssertEqual(fixture.requestPaths, ["/token", "/tokeninfo"])
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testRemovingCachedBodyLeavesDurableMessageMetadataUntouched() async throws {
    let fixture = try makeFixture()
    _ = try await fixture.service.loadMessageBody(message: message, session: session)

    try fixture.service.removeCachedMessageBody(message: message, session: session)

    XCTAssertTrue(fixture.cache.didRemove)
    XCTAssertNil(fixture.cache.payload)
    XCTAssertEqual(message.categoryId, "travel")
    XCTAssertEqual(message.subject, "Trip details")
  }

  func testFileCacheClearsOnlySelectedMailboxPayload() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let cache = FileGmailMessageBodyCache(rootDirectory: rootDirectory)
    let payload = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: "ciphertext",
      keyVersion: 1,
      nonceBase64: "nonce",
      schemaVersion: 1,
      tagBase64: "tag"
    )

    let firstProviderAccountIdentifier = "gmail/user"
    let firstStableMessageId = "gmail:\(firstProviderAccountIdentifier):message-001"
    let secondProviderAccountIdentifier = "gmail:user"
    let secondStableMessageId = "gmail:\(secondProviderAccountIdentifier):message-002"
    try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    let legacyFirstURL = legacyBodyCacheURL(
      rootDirectory: rootDirectory,
      stableProviderMessageId: firstStableMessageId
    )
    try JSONEncoder().encode(payload).write(to: legacyFirstURL)
    try cache.saveMessageBody(
      payload,
      productAccountId: session.productAccountId,
      stableProviderMessageId: secondStableMessageId
    )
    XCTAssertNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: firstStableMessageId
      )
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFirstURL.path))

    try cache.clearMessageBodies(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: secondProviderAccountIdentifier
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFirstURL.path))

    let legacySecondURL = legacyBodyCacheURL(
      rootDirectory: rootDirectory,
      stableProviderMessageId: secondStableMessageId
    )
    try JSONEncoder().encode(payload).write(to: legacySecondURL)
    try cache.clearMessageBodies(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: secondProviderAccountIdentifier
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacySecondURL.path))

    XCTAssertNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: firstStableMessageId
      )
    )
    XCTAssertNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: secondStableMessageId
      )
    )

    try cache.clearMessageBodies(productAccountId: session.productAccountId)
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFirstURL.path))
  }

  private func legacyBodyCacheURL(
    rootDirectory: URL,
    stableProviderMessageId: String
  ) -> URL {
    let productAccount = legacyGmailSafeFileComponent(session.productAccountId)
    let stableMessage = legacyGmailSafeFileComponent(stableProviderMessageId)
    return rootDirectory.appendingPathComponent(
      "\(productAccount)-\(stableMessage).json"
    )
  }

  func testReadFetchesAttachmentBackedBodyOnDemand() async throws {
    let cache = RecordingGmailMessageBodyCache()
    let keyMaterialStore = RecordingBodyCacheKeyMaterialStore()
    try keyMaterialStore.save(
      ProductSyncKeyMaterial.create(
        accountKeyData: Data(repeating: 1, count: ProductSyncKeyMaterial.keyByteCount),
        recoveryKeyData: Data(repeating: 2, count: ProductSyncKeyMaterial.keyByteCount)
      ),
      productAccountId: session.productAccountId
    )
    let tokenStore = RecordingBodyCacheTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let urlSession = ConvexClientTesting.makeSession { request in
      if request.url?.path == "/token" {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }
      if request.url?.path == "/tokeninfo" {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(
            #"{"scope":"https://www.googleapis.com/auth/gmail.readonly","sub":"gmail-user-001"}"#
              .utf8
          )
        )
      }
      if request.url?.path.hasSuffix("/attachments/attachment-001") == true {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(#"{"data":"UHJpdmF0ZSBhdHRhY2htZW50IGJvZHk"}"#.utf8)
        )
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(
          #"{"id":"message-001","payload":{"mimeType":"text/plain","body":{"attachmentId":"attachment-001"}}}"#
            .utf8)
      )
    }
    let service = GmailMessageBodyService(
      gmailBaseURL: URL(string: "https://gmail.example.test/gmail/v1")!,
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      oauthClientId: "gmail-client-id",
      session: urlSession,
      tokenStore: tokenStore,
      tokenRefreshURL: URL(string: "https://gmail.example.test/token")!,
      tokenInfoURL: URL(string: "https://gmail.example.test/tokeninfo")!
    )

    let body = try await service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.text, "Private attachment body")
  }

  private func makeFixture(
    tokenInfoResponse: String =
      #"{"scope":"https://www.googleapis.com/auth/gmail.readonly","sub":"gmail-user-001"}"#,
    messageResponse: String =
      #"{"id":"message-001","payload":{"mimeType":"text/plain","body":{"data":"UHJpdmF0ZSB0cmlwIGRldGFpbHM"}}}"#
  ) throws -> GmailMessageBodyFixture {
    let cache = RecordingGmailMessageBodyCache()
    let keyMaterialStore = RecordingBodyCacheKeyMaterialStore()
    try keyMaterialStore.save(
      ProductSyncKeyMaterial.create(
        accountKeyData: Data(repeating: 1, count: ProductSyncKeyMaterial.keyByteCount),
        recoveryKeyData: Data(repeating: 2, count: ProductSyncKeyMaterial.keyByteCount)
      ),
      productAccountId: session.productAccountId
    )
    let tokenStore = RecordingBodyCacheTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let requestPaths = NSMutableArray()
    let urlSession = ConvexClientTesting.makeSession { request in
      requestPaths.add(request.url!.path)
      if request.url?.path == "/token" {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }
      if request.url?.path == "/tokeninfo" {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(tokenInfoResponse.utf8)
        )
      }
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-access-token")
      XCTAssertEqual(request.url?.query, "format=full")
      return (
        HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!,
        Data(messageResponse.utf8)
      )
    }
    return GmailMessageBodyFixture(
      cache: cache,
      requestPaths: requestPaths,
      service: GmailMessageBodyService(
        gmailBaseURL: URL(string: "https://gmail.example.test/gmail/v1")!,
        cache: cache,
        keyMaterialStore: keyMaterialStore,
        oauthClientId: "gmail-client-id",
        session: urlSession,
        tokenStore: tokenStore,
        tokenRefreshURL: URL(string: "https://gmail.example.test/token")!,
        tokenInfoURL: URL(string: "https://gmail.example.test/tokeninfo")!
      )
    )
  }
}

private struct GmailMessageBodyFixture {
  let cache: RecordingGmailMessageBodyCache
  let requestPaths: NSMutableArray
  let service: GmailMessageBodyService
}

private final class RecordingGmailMessageBodyCache: GmailMessageBodyCaching {
  var didRemove = false
  var payload: ProductSyncEncryptedPayload?

  var serializedPayload: String {
    guard let payload, let data = try? JSONEncoder().encode(payload) else {
      return ""
    }
    return String(bytes: data, encoding: .utf8) ?? ""
  }

  func clearMessageBodies(productAccountId _: String) throws {
    payload = nil
  }

  func loadMessageBody(
    productAccountId _: String,
    stableProviderMessageId _: String
  ) throws -> ProductSyncEncryptedPayload? {
    payload
  }

  func removeMessageBody(
    productAccountId _: String,
    stableProviderMessageId _: String
  ) throws {
    didRemove = true
    payload = nil
  }

  func saveMessageBody(
    _ payload: ProductSyncEncryptedPayload,
    productAccountId _: String,
    stableProviderMessageId _: String
  ) throws {
    self.payload = payload
  }
}

private final class RecordingBodyCacheKeyMaterialStore: ProductSyncKeyMaterialPersisting {
  var material: ProductSyncKeyMaterial?

  func clear(productAccountId _: String) throws {
    material = nil
  }

  func ensureMaterial(
    productAccountId _: String,
    allowCreation _: Bool
  ) throws -> ProductSyncKeyMaterial {
    try XCTUnwrap(material)
  }

  func load(productAccountId _: String) throws -> ProductSyncKeyMaterial? {
    material
  }

  func restore(
    productAccountId _: String,
    recoveryKey _: ProductSyncRecoveryKey,
    recoveryWrappedAccountKey _: ProductSyncEncryptedPayload
  ) throws -> ProductSyncKeyMaterial {
    try XCTUnwrap(material)
  }

  func save(_ material: ProductSyncKeyMaterial, productAccountId _: String) throws {
    self.material = material
  }
}

private final class RecordingBodyCacheTokenStore: GmailProviderTokenPersisting {
  var tokens: GmailProviderTokens?

  func clear(productAccountId _: String) throws {
    tokens = nil
  }

  func clear(productAccountId: String, providerAccountIdentifier _: String) throws {
    try clear(productAccountId: productAccountId)
  }

  func clearAll(productAccountId: String) throws {
    try clear(productAccountId: productAccountId)
  }

  func load(productAccountId _: String) throws -> GmailProviderTokens? {
    tokens
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier _: String
  ) throws -> GmailProviderTokens? {
    try load(productAccountId: productAccountId)
  }

  func save(_ tokens: GmailProviderTokens, productAccountId _: String) throws {
    self.tokens = tokens
  }

  func save(
    _ tokens: GmailProviderTokens,
    productAccountId: String,
    providerAccountIdentifier _: String
  ) throws {
    try save(tokens, productAccountId: productAccountId)
  }
}
