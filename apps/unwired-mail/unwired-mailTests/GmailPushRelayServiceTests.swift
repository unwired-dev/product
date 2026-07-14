import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

@MainActor
final class GmailPushRelayServiceTests: XCTestCase {
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

  func testTokenRefresherRenewsExpiredAccessTokenFromDeviceHeldRefreshToken() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "expired-access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let requestSession = ConvexClientTesting.makeSession { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      if request.url?.path == "/token" {
        return (response, Data(#"{"access_token":"refreshed-access-token"}"#.utf8))
      }
      return (
        response,
        Data(
          #"""
          {
            "email": "user@example.com",
            "scope": "https://www.googleapis.com/auth/gmail.readonly",
            "sub": "gmail-user-001"
          }
          """#.utf8
        )
      )
    }
    let service = GmailMessageMetadataService(
      oauthClientId: "gmail-client-id",
      session: requestSession,
      tokenStore: tokenStore,
      tokenInfoURL: URL(string: "https://example.test/tokeninfo")!,
      tokenRefreshURL: URL(string: "https://example.test/token")!
    )

    let tokens = try await service.refreshProviderTokens(
      connection: connection,
      session: session
    )

    XCTAssertEqual(
      tokens,
      GmailProviderTokens(accessToken: "refreshed-access-token", refreshToken: "refresh-token")
    )
    XCTAssertEqual(try tokenStore.load(productAccountId: session.productAccountId), tokens)
  }

  // swiftlint:disable:next function_body_length
  func testRegisterOrRenewWatchUsesDeviceHeldTokenAndStoresExpiration() async throws {
    let connectionStore = RecordingGmailPushConnectionStore()
    let tokenRefresher = RecordingGmailPushTokenRefresher(
      tokens: GmailProviderTokens(
        accessToken: "refreshed-access-token",
        refreshToken: "refresh-token"
      )
    )
    let watchStore = RecordingGmailPushWatchStore()
    let verificationTransport = RecordingGmailPushVerificationTransport()
    var recordedAuthorization: String?
    var recordedBody: [String: Any]?
    let requestSession = ConvexClientTesting.makeSession { request in
      recordedAuthorization = request.value(forHTTPHeaderField: "Authorization")
      recordedBody =
        try JSONSerialization.jsonObject(with: Self.httpBodyData(for: request))
        as? [String: Any]
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      let data = try JSONSerialization.data(withJSONObject: [
        "expiration": "1781300000000",
        "historyId": "history-123",
      ])
      return (response, data)
    }
    let service = GmailPushWatchService(
      connectionStore: connectionStore,
      nowMilliseconds: { 1_781_200_000_000 },
      session: requestSession,
      store: watchStore,
      tokenRefresher: tokenRefresher,
      topicName: "projects/private-email/topics/gmail-push",
      verificationTransport: verificationTransport
    )

    let status = try await service.registerOrRenew(
      connection: connection,
      session: session
    )

    XCTAssertEqual(recordedAuthorization, "Bearer refreshed-access-token")
    XCTAssertEqual(
      recordedBody?["topicName"] as? String, "projects/private-email/topics/gmail-push")
    XCTAssertEqual(recordedBody?["labelIds"] as? [String], ["INBOX"])
    XCTAssertEqual(recordedBody?["labelFilterBehavior"] as? String, "include")
    XCTAssertEqual(status.historyId, "history-123")
    XCTAssertEqual(status.routeId, "route-001")
    XCTAssertEqual(watchStore.savedStatus, status)
    XCTAssertEqual(tokenRefresher.connection, connection)
    XCTAssertEqual(tokenRefresher.session, session)
    XCTAssertEqual(connectionStore.savedConnection, connection)
    XCTAssertEqual(connectionStore.productAccountId, session.productAccountId)
    XCTAssertEqual(verificationTransport.historyId, "history-123")
    XCTAssertEqual(verificationTransport.session, session)
  }

  func testRegisterOrRenewWatchRenewsWatchWithLessThanOneDayRemaining() async throws {
    let expiring = GmailPushWatchStatus(
      expirationMilliseconds: 1_781_250_000_000,
      historyId: "history-expiring"
    )
    let tokenRefresher = RecordingGmailPushTokenRefresher(
      tokens: GmailProviderTokens(accessToken: "fresh-access-token", refreshToken: "refresh-token")
    )
    let requestSession = ConvexClientTesting.makeSession { request in
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-access-token")
      return (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(#"{"expiration":"1781900000000","historyId":"history-renewed"}"#.utf8)
      )
    }
    let service = GmailPushWatchService(
      connectionStore: RecordingGmailPushConnectionStore(),
      nowMilliseconds: { 1_781_200_000_000 },
      session: requestSession,
      store: RecordingGmailPushWatchStore(status: expiring),
      tokenRefresher: tokenRefresher,
      topicName: "projects/private-email/topics/gmail-push",
      verificationTransport: RecordingGmailPushVerificationTransport()
    )

    let status = try await service.registerOrRenew(connection: connection, session: session)

    XCTAssertEqual(status.historyId, "history-renewed")
  }

  func testRegisterOrRenewWatchKeepsWatchWithMoreThanOneDayRemaining() async throws {
    let existing = GmailPushWatchStatus(
      expirationMilliseconds: 1_781_400_000_000,
      historyId: "history-existing"
    )
    let watchStore = RecordingGmailPushWatchStore(status: existing)
    let service = GmailPushWatchService(
      nowMilliseconds: { 1_781_200_000_000 },
      session: ConvexClientTesting.makeSession { request in
        XCTFail("Unexpected request: \(String(describing: request.url))")
        return (
          HTTPURLResponse(
            url: request.url!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
          )!,
          Data()
        )
      },
      store: watchStore,
      tokenRefresher: FailingGmailPushTokenRefresher(),
      topicName: "projects/private-email/topics/gmail-push",
      verificationTransport: RecordingGmailPushVerificationTransport()
    )

    let status = try await service.registerOrRenew(
      connection: connection,
      session: session
    )

    XCTAssertEqual(
      status,
      GmailPushWatchStatus(
        expirationMilliseconds: existing.expirationMilliseconds,
        historyId: existing.historyId,
        routeId: "route-001"
      )
    )
  }

  func testRegisterOrRenewWatchReplacesUnverifiedCachedWatch() async throws {
    let existing = GmailPushWatchStatus(
      expirationMilliseconds: 1_781_400_000_000,
      historyId: "history-existing"
    )
    let requestSession = ConvexClientTesting.makeSession { request in
      XCTAssertEqual(request.url?.path, "/gmail/v1/users/me/watch")
      return (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(#"{"expiration":"1781900000000","historyId":"history-renewed"}"#.utf8)
      )
    }
    let service = GmailPushWatchService(
      nowMilliseconds: { 1_781_200_000_000 },
      session: requestSession,
      store: RecordingGmailPushWatchStore(status: existing),
      tokenRefresher: RecordingGmailPushTokenRefresher(
        tokens: GmailProviderTokens(
          accessToken: "fresh-access-token",
          refreshToken: "refresh-token"
        )
      ),
      topicName: "projects/private-email/topics/gmail-push",
      verificationTransport: RecordingGmailPushVerificationTransport(verified: false)
    )

    let status = try await service.registerOrRenew(connection: connection, session: session)

    XCTAssertEqual(status.historyId, "history-renewed")
  }

  func testStopWatchUsesDeviceHeldToken() async throws {
    let tokenRefresher = RecordingGmailPushTokenRefresher(
      tokens: GmailProviderTokens(
        accessToken: "refreshed-access-token",
        refreshToken: "refresh-token"
      )
    )
    var recordedRequest: URLRequest?
    let requestSession = ConvexClientTesting.makeSession { request in
      recordedRequest = request
      return (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 204,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data()
      )
    }
    let service = GmailPushWatchService(
      session: requestSession,
      tokenRefresher: tokenRefresher
    )

    try await service.stop(connection: connection, session: session)

    XCTAssertEqual(recordedRequest?.url?.path, "/gmail/v1/users/me/stop")
    XCTAssertEqual(recordedRequest?.httpMethod, "POST")
    XCTAssertEqual(
      recordedRequest?.value(forHTTPHeaderField: "Authorization"),
      "Bearer refreshed-access-token"
    )
    XCTAssertEqual(tokenRefresher.connection, connection)
    XCTAssertEqual(tokenRefresher.session, session)
  }

  func testRegisterDeviceSendsOnlyAPNsRoutingDataToBackend() async throws {
    let transport = RecordingDevicePushRegistrationTransport()
    let service = DevicePushRegistrationService(
      environment: .sandbox,
      transport: transport
    )

    try await service.register(
      deviceToken: Data([0x01, 0xAB, 0xFF]),
      session: session
    )

    XCTAssertEqual(
      transport.call,
      DevicePushRegistrationCall(
        apnsEnvironment: "sandbox",
        apnsToken: "01abff",
        identityToken: session.identityToken,
        trustedDeviceId: session.trustedDeviceId
      )
    )
  }

  func testDevicePushRegistrationRetriesRememberedTokenAfterFailure() async throws {
    let transport = RecordingDevicePushRegistrationTransport()
    let retrier = DevicePushRegistrationRetrier(
      environment: .sandbox,
      transport: transport
    )
    retrier.remember(deviceToken: Data([0x01, 0xAB, 0xFF]))
    transport.registerError = GmailPushRelayTestError.unexpectedCall

    do {
      try await retrier.retry(session: session)
      XCTFail("Expected registration failure")
    } catch GmailPushRelayTestError.unexpectedCall {
    }

    transport.registerError = nil
    try await retrier.retry(session: session)

    XCTAssertEqual(transport.calls.count, 2)
    XCTAssertEqual(transport.calls.last?.apnsToken, "01abff")
  }

  func testUnregisterDeviceClearsBackendRoutingForSignedOutSession() async throws {
    let transport = RecordingDevicePushRegistrationTransport()
    let service = DevicePushUnregistrationService(transport: transport)

    try await service.unregister(session: session)

    XCTAssertEqual(transport.unregisteredSession, session)
  }

  func testPushConnectionStoreKeepsAccountMetadataInKeychain() throws {
    let productAccountId = "\(session.productAccountId)-\(UUID().uuidString)"
    let store = KeychainGmailPushConnectionStore()
    defer { try? store.clear(productAccountId: productAccountId) }
    try store.save(connection, productAccountId: productAccountId)

    XCTAssertEqual(try store.load(productAccountId: productAccountId), connection)

    try store.clear(productAccountId: productAccountId)

    XCTAssertNil(try store.load(productAccountId: productAccountId))
  }

  func testGmailWakeupFetchesMailboxChangesThroughDeviceSyncService() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let connectionStore = RecordingGmailPushConnectionStore(connection: connection)
    let syncService = RecordingPushGmailMetadataSyncService()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: connectionStore,
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertTrue(handled)
    XCTAssertEqual(connectionStore.loadedProductAccountId, session.productAccountId)
    XCTAssertEqual(syncService.syncedConnection, connection)
    XCTAssertEqual(syncService.syncedSession, session)
    XCTAssertEqual(
      watchStore.savedStatus,
      GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        latestSyncedHistoryId: "124",
        routeId: "route-001"
      )
    )
  }

  func testGmailWakeupDoesNotPersistAfterSessionChangesDuringSync() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.onSync = {
      try? sessionStore.clear()
    }
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertFalse(handled)
    XCTAssertEqual(syncService.shouldPersist, false)
    XCTAssertNil(watchStore.savedStatus)
  }

  func testGmailWakeupIgnoresStaleConnectionRoute() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: RecordingGmailPushWatchStore(
        status: GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          routeId: "current-route"
        )
      )
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "stale-route",
    ])

    XCTAssertFalse(handled)
    XCTAssertNil(syncService.syncedConnection)
  }

  func testGmailWakeupIgnoresHistoryAtOrBeforeStoredWatermark() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: RecordingGmailPushWatchStore(
        status: GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "100",
          latestSyncedHistoryId: "124",
          routeId: "route-001"
        )
      )
    )

    for historyId in ["124", "123"] {
      let handled = try await handler.handle(userInfo: [
        "historyId": historyId,
        "provider": "gmail",
        "routeId": "route-001",
      ])
      XCTAssertFalse(handled)
    }
    XCTAssertNil(syncService.syncedConnection)
  }

  private static func httpBodyData(for request: URLRequest) -> Data {
    if let body = request.httpBody {
      return body
    }

    guard let stream = request.httpBodyStream else {
      return Data()
    }
    stream.open()
    defer { stream.close() }

    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_024)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let count = stream.read(buffer, maxLength: 1_024)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

private final class RecordingGmailPushWatchStore: GmailPushWatchPersisting {
  var clearedProductAccountId: String?
  var savedStatus: GmailPushWatchStatus?
  private let status: GmailPushWatchStatus?

  init(status: GmailPushWatchStatus? = nil) {
    self.status = status
  }

  func clear(
    productAccountId: String,
    providerAccountIdentifier _: String
  ) throws {
    clearedProductAccountId = productAccountId
  }

  func load(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> GmailPushWatchStatus? {
    status
  }

  func save(
    _ status: GmailPushWatchStatus,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    savedStatus = status
  }
}

private final class RecordingGmailPushConnectionStore: GmailPushConnectionPersisting {
  var clearedProductAccountId: String?
  var loadedProductAccountId: String?
  var productAccountId: String?
  var savedConnection: GmailProviderConnectionStatus?
  private let connection: GmailProviderConnectionStatus?

  init(connection: GmailProviderConnectionStatus? = nil) {
    self.connection = connection
  }

  func clear(productAccountId: String) throws {
    clearedProductAccountId = productAccountId
  }

  func load(productAccountId: String) throws -> GmailProviderConnectionStatus? {
    loadedProductAccountId = productAccountId
    return connection
  }

  func save(
    _ connection: GmailProviderConnectionStatus,
    productAccountId: String
  ) throws {
    savedConnection = connection
    self.productAccountId = productAccountId
  }
}

private final class RecordingGmailPushVerificationTransport: GmailPushVerificationTransport {
  var historyId: String?
  var session: ProductAccountSessionSnapshot?
  private let routeId: String
  private let verified: Bool

  init(verified: Bool = true, routeId: String = "route-001") {
    self.routeId = routeId
    self.verified = verified
  }

  func verifyGmailPushWatch(
    historyId: String,
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> GmailPushVerificationResponse {
    self.historyId = historyId
    session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: identityToken,
      productAccountId: "product-account-001",
      trustedDeviceId: trustedDeviceId
    )
    return GmailPushVerificationResponse(routeId: routeId, verified: verified)
  }
}

private final class RecordingGmailPushTokenRefresher: GmailProviderTokenRefreshing {
  var connection: GmailProviderConnectionStatus?
  var session: ProductAccountSessionSnapshot?
  let tokens: GmailProviderTokens

  init(tokens: GmailProviderTokens) {
    self.tokens = tokens
  }

  func refreshProviderTokens(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderTokens {
    self.connection = connection
    self.session = session
    return tokens
  }
}

private struct FailingGmailPushTokenRefresher: GmailProviderTokenRefreshing {
  func refreshProviderTokens(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderTokens {
    XCTFail("Unexpected token refresh")
    throw GmailPushRelayTestError.unexpectedCall
  }
}

private struct DevicePushRegistrationCall: Equatable {
  let apnsEnvironment: String
  let apnsToken: String
  let identityToken: String
  let trustedDeviceId: String
}

private final class RecordingDevicePushRegistrationTransport: DevicePushRegistrationTransport {
  var call: DevicePushRegistrationCall? { calls.last }
  var calls: [DevicePushRegistrationCall] = []
  var registerError: Error?
  var unregisteredSession: ProductAccountSessionSnapshot?

  func registerDevicePush(
    apnsEnvironment: String,
    apnsToken: String,
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> DevicePushRegistrationResponse {
    calls.append(
      DevicePushRegistrationCall(
        apnsEnvironment: apnsEnvironment,
        apnsToken: apnsToken,
        identityToken: identityToken,
        trustedDeviceId: trustedDeviceId
      ))
    if let registerError {
      throw registerError
    }
    return DevicePushRegistrationResponse(registered: true)
  }

  func unregisterDevicePush(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> DevicePushRegistrationResponse {
    unregisteredSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: identityToken,
      productAccountId: "product-account-001",
      trustedDeviceId: trustedDeviceId
    )
    return DevicePushRegistrationResponse(registered: false)
  }
}

private final class RecordingPushGmailMetadataSyncService: GmailMessageMetadataSyncing {
  var onSync: (() -> Void)?
  var shouldPersist: Bool?
  var syncedConnection: GmailProviderConnectionStatus?
  var syncedSession: ProductAccountSessionSnapshot?

  func categorizeHistorical(
    scope _: GmailHistoricalCategorizationScope,
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    throw GmailPushRelayTestError.unexpectedCall
  }

  func loadInbox(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    throw GmailPushRelayTestError.unexpectedCall
  }

  func syncInbox(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    throw GmailPushRelayTestError.unexpectedCall
  }

  func syncRecentInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot,
    shouldPersist: @escaping () -> Bool
  ) async throws -> GmailMetadataSyncResult {
    syncedConnection = connection
    syncedSession = session
    onSync?()
    let canPersist = shouldPersist()
    self.shouldPersist = canPersist
    guard canPersist else {
      throw GmailMessageMetadataSyncError.staleLocalConnection
    }
    return GmailMetadataSyncResult(messages: [], threads: [])
  }

  func overrideCategory(
    _: String,
    for _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    throw GmailPushRelayTestError.unexpectedCall
  }
}

private enum GmailPushRelayTestError: Error {
  case unexpectedCall
}
