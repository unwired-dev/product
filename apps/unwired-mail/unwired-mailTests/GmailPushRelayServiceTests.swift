import UserNotifications
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

  // swiftlint:disable:next function_body_length
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
        return (
          response,
          Data(
            #"{"access_token":"refreshed-access-token","id_token":"gmail-identity-token"}"#.utf8
          )
        )
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
      GmailProviderTokens(
        accessToken: "refreshed-access-token",
        refreshToken: "refresh-token",
        idToken: "gmail-identity-token"
      )
    )
    XCTAssertEqual(try tokenStore.load(productAccountId: session.productAccountId), tokens)
  }

  // swiftlint:disable:next function_body_length
  func testTokenRefresherMigratesLegacyTokensWhenStoppingAnUpgradedWatch() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    tokenStore.saveLegacy(
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
        return (
          response,
          Data(
            #"{"access_token":"refreshed-access-token","id_token":"gmail-identity-token"}"#.utf8
          )
        )
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
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      tokens
    )
    XCTAssertNil(try tokenStore.loadLegacy(productAccountId: session.productAccountId))
  }

  // swiftlint:disable:next function_body_length
  func testRegisterOrRenewWatchUsesDeviceHeldTokenAndStoresExpiration() async throws {
    let connectionStore = RecordingGmailPushConnectionStore()
    let tokenRefresher = RecordingGmailPushTokenRefresher(
      tokens: GmailProviderTokens(
        accessToken: "refreshed-access-token",
        refreshToken: "refresh-token",
        idToken: "gmail-identity-token"
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
    XCTAssertEqual(verificationTransport.gmailIdentityToken, "gmail-identity-token")
    XCTAssertEqual(verificationTransport.historyId, "history-123")
    XCTAssertEqual(verificationTransport.session, session)
  }

  func testRegisterOrRenewWatchRenewsWatchWithLessThanOneDayRemaining() async throws {
    let expiring = GmailPushWatchStatus(
      expirationMilliseconds: 1_781_250_000_000,
      historyId: "history-expiring",
      latestSyncedHistoryId: "history-synced"
    )
    let tokenRefresher = RecordingGmailPushTokenRefresher(
      tokens: GmailProviderTokens(
        accessToken: "fresh-access-token",
        refreshToken: "refresh-token",
        idToken: "gmail-identity-token"
      )
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
    XCTAssertEqual(status.latestSyncedHistoryId, "history-synced")
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
      tokenRefresher: RecordingGmailPushTokenRefresher(
        tokens: GmailProviderTokens(
          accessToken: "fresh-access-token",
          refreshToken: "refresh-token",
          idToken: "gmail-identity-token"
        )
      ),
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
          refreshToken: "refresh-token",
          idToken: "gmail-identity-token"
        )
      ),
      topicName: "projects/private-email/topics/gmail-push",
      verificationTransport: RecordingGmailPushVerificationTransport(verified: false)
    )

    let status = try await service.registerOrRenew(connection: connection, session: session)

    XCTAssertEqual(status.historyId, "history-renewed")
  }

  func testRegisterOrRenewWatchPersistsConnectionBeforeVerification() async throws {
    let connectionStore = RecordingGmailPushConnectionStore()
    let service = GmailPushWatchService(
      connectionStore: connectionStore,
      nowMilliseconds: { 1_781_200_000_000 },
      session: ConvexClientTesting.makeSession { request in
        (
          HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
          )!,
          Data(#"{"expiration":"1781900000000","historyId":"history-new"}"#.utf8)
        )
      },
      store: RecordingGmailPushWatchStore(),
      tokenRefresher: RecordingGmailPushTokenRefresher(
        tokens: GmailProviderTokens(
          accessToken: "fresh-access-token",
          refreshToken: "refresh-token",
          idToken: "gmail-identity-token"
        )
      ),
      topicName: "projects/private-email/topics/gmail-push",
      verificationTransport: ThrowingGmailPushVerificationTransport()
    )

    do {
      _ = try await service.registerOrRenew(connection: connection, session: session)
      XCTFail("Expected watch verification to fail")
    } catch {
    }

    XCTAssertEqual(connectionStore.savedConnection, connection)
    XCTAssertEqual(connectionStore.productAccountId, session.productAccountId)
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

  // swiftlint:disable:next function_body_length
  func testPushConnectionStoreMigratesLegacyMetadataAndKeepsMailboxesIsolated() throws {
    let productAccountId = "\(session.productAccountId)-\(UUID().uuidString)"
    let first = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: connection.emailAddress,
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: "gmail/user",
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
    let second = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: "second@example.com",
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: "gmail:user",
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
    let service = "private-email.gmail-push-connection"
    let legacyAccount =
      "gmail-push-connection.\(legacyGmailSafeFileComponent(productAccountId))"
    let legacyJSON = try XCTUnwrap(
      String(data: JSONEncoder().encode(first), encoding: .utf8)
    )
    let store = KeychainGmailPushConnectionStore()
    defer {
      try? store.clear(productAccountId: productAccountId)
      try? KeychainStore.delete(service: service, account: legacyAccount)
    }
    try KeychainStore.writeString(legacyJSON, service: service, account: legacyAccount)

    XCTAssertEqual(try store.loadAll(productAccountId: productAccountId), [first])
    XCTAssertNil(try KeychainStore.readString(service: service, account: legacyAccount))
    try store.save(second, productAccountId: productAccountId)

    try store.clear(
      productAccountId: productAccountId,
      providerAccountIdentifier: first.providerAccountIdentifier
    )

    XCTAssertNil(
      try store.load(
        productAccountId: productAccountId,
        providerAccountIdentifier: first.providerAccountIdentifier
      )
    )
    XCTAssertEqual(
      try store.load(
        productAccountId: productAccountId,
        providerAccountIdentifier: second.providerAccountIdentifier
      ),
      second
    )
  }

  func testPushConnectionStoreClearingLegacyMailboxPreventsResurrection() throws {
    let productAccountId = "\(session.productAccountId)-\(UUID().uuidString)"
    let service = "private-email.gmail-push-connection"
    let legacyAccount =
      "gmail-push-connection.\(legacyGmailSafeFileComponent(productAccountId))"
    let legacyJSON = try XCTUnwrap(
      String(data: JSONEncoder().encode(connection), encoding: .utf8)
    )
    let store = KeychainGmailPushConnectionStore()
    defer {
      try? store.clear(productAccountId: productAccountId)
      try? KeychainStore.delete(service: service, account: legacyAccount)
    }
    try KeychainStore.writeString(legacyJSON, service: service, account: legacyAccount)

    try store.clear(
      productAccountId: productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    XCTAssertEqual(try store.loadAll(productAccountId: productAccountId), [])
    XCTAssertNil(try KeychainStore.readString(service: service, account: legacyAccount))
  }

  func testPushConnectionStoreDoesNotReplaceScopedConnectionWithLegacyDuplicate() throws {
    let productAccountId = "\(session.productAccountId)-\(UUID().uuidString)"
    let service = "private-email.gmail-push-connection"
    let legacyAccount =
      "gmail-push-connection.\(legacyGmailSafeFileComponent(productAccountId))"
    let current = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: "current@example.com",
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt + 1
    )
    let legacyJSON = try XCTUnwrap(
      String(data: JSONEncoder().encode(connection), encoding: .utf8)
    )
    let store = KeychainGmailPushConnectionStore()
    defer {
      try? store.clear(productAccountId: productAccountId)
      try? KeychainStore.delete(service: service, account: legacyAccount)
    }
    try store.save(current, productAccountId: productAccountId)
    try KeychainStore.writeString(legacyJSON, service: service, account: legacyAccount)

    XCTAssertEqual(try store.loadAll(productAccountId: productAccountId), [current])
    XCTAssertNotNil(try KeychainStore.readString(service: service, account: legacyAccount))
  }

  func testNotificationStoresPreserveLegacyStateForAnotherMailbox() throws {
    let suiteName = "PushNotificationMigrationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let otherIdentifier = "gmail-user-002"
    let legacyProductAccount = legacyGmailSafeFileComponent(session.productAccountId)
    let legacyProviderAccount = legacyGmailSafeFileComponent(
      otherIdentifier
    )
    let legacySuffix = "\(legacyProductAccount).\(legacyProviderAccount)"
    let receiptKey = "gmail-push-notification-receipts.\(legacySuffix)"
    let eligibilityKey = "gmail-push-notification-eligibility.\(legacySuffix)"
    let otherMessage = GmailMessageMetadata(
      categoryId: nil,
      from: "Sender <sender@example.com>",
      isHistorical: false,
      providerAccountIdentifier: otherIdentifier,
      providerInternalDateMilliseconds: 1,
      providerMessageId: "message-001",
      providerThreadId: "thread-001",
      replyTo: nil,
      snippet: "Private message",
      stableProviderMessageId: "gmail:\(otherIdentifier):message-001",
      subject: "Subject",
      rfcMessageId: "<message-001@example.com>"
    )
    defaults.set([otherMessage.stableProviderMessageId], forKey: receiptKey)
    let eligibilityJSON = """
      [{"stableProviderMessageId":"\(otherMessage.stableProviderMessageId)","throughHistoryId":"124"}]
      """
    defaults.set(Data(eligibilityJSON.utf8), forKey: eligibilityKey)

    let receiptStore = GmailPushNotificationReceiptStore(defaults: defaults)
    let eligibilityStore = GmailPushEligibilityStore(defaults: defaults)

    XCTAssertEqual(
      try claimAndReleaseReceipt(
        pushMessage(categoryId: nil),
        from: receiptStore
      ),
      .claimed
    )
    XCTAssertTrue(
      try eligibilityStore.eligibleStableMessageIds(
        after: "123",
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ).isEmpty
    )
    XCTAssertNotNil(defaults.object(forKey: receiptKey))
    XCTAssertNotNil(defaults.object(forKey: eligibilityKey))
  }

  func testPushWatchStoreMigratesLegacyStatusAndKeepsCollidingIdentitiesIsolated() throws {
    let suiteName = "PushWatchStoreTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let firstIdentifier = "gmail/user"
    let secondIdentifier = "gmail:user"
    let first = GmailPushWatchStatus(
      expirationMilliseconds: 100,
      historyId: "10",
      routeId: "route-001"
    )
    let second = GmailPushWatchStatus(
      expirationMilliseconds: 200,
      historyId: "20",
      routeId: "route-002"
    )
    let legacyProductAccount = legacyGmailSafeFileComponent(session.productAccountId)
    let legacyProviderAccount = legacyGmailSafeFileComponent(firstIdentifier)
    let legacyKey = "gmail-push-watch.\(legacyProductAccount).\(legacyProviderAccount)"
    defaults.set(try JSONEncoder().encode(first), forKey: legacyKey)
    let store = UserDefaultsGmailPushWatchStore(defaults: defaults)

    XCTAssertEqual(
      try store.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: firstIdentifier
      ),
      first
    )
    try store.save(
      second,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: secondIdentifier
    )
    try store.clear(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: firstIdentifier
    )

    XCTAssertNil(
      try store.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: firstIdentifier
      )
    )
    XCTAssertEqual(
      try store.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: secondIdentifier
      ),
      second
    )
  }

  func testClearingNotificationStateDoesNotDeleteCollidingLegacyState() {
    let suiteName = "PushNotificationStateTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let firstIdentifier = "gmail/user"
    let secondIdentifier = "gmail:user"
    let currentSuffix =
      "\(gmailSafeFileComponent(session.productAccountId)).\(gmailSafeFileComponent(firstIdentifier))"
    let legacyProductAccount = legacyGmailSafeFileComponent(session.productAccountId)
    let legacySuffix = "\(legacyProductAccount).\(legacyGmailSafeFileComponent(secondIdentifier))"
    let receiptPrefix = "gmail-push-notification-receipts."
    let eligibilityPrefix = "gmail-push-notification-eligibility."
    defaults.set(["current"], forKey: "\(receiptPrefix)\(currentSuffix)")
    defaults.set(Data("current".utf8), forKey: "\(eligibilityPrefix)\(currentSuffix)")
    defaults.set(["legacy"], forKey: "\(receiptPrefix)\(legacySuffix)")
    defaults.set(Data("legacy".utf8), forKey: "\(eligibilityPrefix)\(legacySuffix)")

    clearGmailPushNotificationState(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: firstIdentifier,
      defaults: defaults
    )

    XCTAssertNil(defaults.object(forKey: "\(receiptPrefix)\(currentSuffix)"))
    XCTAssertNil(defaults.object(forKey: "\(eligibilityPrefix)\(currentSuffix)"))
    XCTAssertEqual(
      defaults.stringArray(forKey: "\(receiptPrefix)\(legacySuffix)"),
      ["legacy"]
    )
    XCTAssertEqual(
      defaults.data(forKey: "\(eligibilityPrefix)\(legacySuffix)"),
      Data("legacy".utf8)
    )
  }

  // swiftlint:disable:next function_body_length
  func testGmailWakeupFetchesMailboxChangesThroughDeviceSyncService() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let connectionStore = RecordingGmailPushConnectionStore(connection: connection)
    let syncService = RecordingPushGmailMetadataSyncService()
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId
    )
    let suiteName = "MailboxSyncSuccessStoreTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let successStore = UserDefaultsMailboxSyncSuccessStore(defaults: defaults)
    successStore.clear(
      productAccountId: session.productAccountId,
      connectionId: mailboxConnection.id
    )
    defer {
      successStore.clear(
        productAccountId: session.productAccountId,
        connectionId: mailboxConnection.id
      )
    }
    let statusPublished = expectation(description: "push sync status published")
    let observer = NotificationCenter.default.addObserver(
      forName: .mailboxMetadataDidSynchronize,
      object: nil,
      queue: .main
    ) { notification in
      guard
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.connectionId]
          as? String == mailboxConnection.id.rawValue,
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.phase]
          as? MailboxSyncPhase == .idle,
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.successfulSyncAt] is Date
      else { return }
      statusPublished.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: connectionStore,
      notificationRuleSync: StubNotificationRuleSync(rules: NotificationRules(categoryIds: [])),
      sessionStore: sessionStore,
      successStore: successStore,
      syncService: syncService,
      watchStore: watchStore
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])
    await fulfillment(of: [statusPublished], timeout: 1)

    XCTAssertTrue(handled)
    XCTAssertEqual(connectionStore.loadedProductAccountId, session.productAccountId)
    XCTAssertEqual(
      syncService.syncedConnection,
      mailboxConnection
    )
    XCTAssertEqual(syncService.syncedSession, session)
    XCTAssertEqual(syncService.sinceHistoryId, "123")
    XCTAssertNotNil(
      successStore.load(
        productAccountId: session.productAccountId,
        connectionId: mailboxConnection.id
      )
    )
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

  func testGmailWakeupRoutesToMatchingMailboxWhenTwoConnectionsExist() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let second = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: "second@example.com",
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
    let syncService = RecordingPushGmailMetadataSyncService()
    let watchStore = RecordingGmailPushWatchStore(statuses: [
      connection.providerAccountIdentifier: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      ),
      second.providerAccountIdentifier: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "456",
        routeId: "route-002"
      ),
    ])
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connections: [connection, second]),
      notificationRuleSync: StubNotificationRuleSync(rules: NotificationRules(categoryIds: [])),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "457",
      "provider": "gmail",
      "routeId": "route-002",
    ])

    XCTAssertTrue(handled)
    XCTAssertEqual(
      syncService.syncedConnection,
      second.mailboxConnection(productAccountId: session.productAccountId)
    )
    XCTAssertEqual(syncService.sinceHistoryId, "456")
  }

  func testGmailWakeupSkipsUnreadableWatchForAnotherMailbox() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let second = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: "second@example.com",
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
    let syncService = RecordingPushGmailMetadataSyncService()
    let watchStore = RecordingGmailPushWatchStore(
      statuses: [
        second.providerAccountIdentifier: GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "456",
          routeId: "route-002"
        )
      ],
      failingProviderAccountIdentifiers: [connection.providerAccountIdentifier]
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connections: [connection, second]),
      notificationRuleSync: StubNotificationRuleSync(rules: NotificationRules(categoryIds: [])),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "457",
      "provider": "gmail",
      "routeId": "route-002",
    ])

    XCTAssertTrue(handled)
    XCTAssertEqual(
      syncService.syncedConnection,
      second.mailboxConnection(productAccountId: session.productAccountId)
    )
  }

  func testGmailWakeupShowsNotificationForNewMessageMatchingEncryptedRules() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message]
    syncService.newMessageIds = [message.providerMessageId]
    let notificationDelivery = RecordingNotificationDelivery()
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: RecordingGmailPushWatchStore(
        status: GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          routeId: "route-001"
        )
      )
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertTrue(handled)
    XCTAssertEqual(notificationDelivery.messages, [message])
  }

  func testGmailWakeupUsesCachedRulesWhenStoredProductSyncTokenExpired() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message]
    syncService.newMessageIds = [message.providerMessageId]
    let notificationDelivery = RecordingNotificationDelivery()
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: ExpiredCachedRuleSync(
        cachedRules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: RecordingGmailPushWatchStore(
        status: GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          routeId: "route-001"
        )
      )
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertTrue(handled)
    XCTAssertEqual(notificationDelivery.messages, [message])
  }

  func testGmailWakeupUsesBackgroundCategorizationBeforeApplyingCachedRules() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: nil)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message]
    syncService.newMessageIds = [message.providerMessageId]
    let notificationDelivery = RecordingNotificationDelivery()
    let handler = GmailPushWakeupHandler(
      backgroundCategorizer: AssigningBackgroundCategorizer(categoryId: "system:flights"),
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: ExpiredCachedRuleSync(
        cachedRules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: RecordingGmailPushWatchStore(
        status: GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          routeId: "route-001"
        )
      )
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertTrue(handled)
    XCTAssertEqual(notificationDelivery.messages, [message.assigningCategory("system:flights")])
  }

  func testGmailWakeupUsesRulesCurrentAfterInboxSync() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message]
    syncService.newMessageIds = [message.providerMessageId]
    let notificationDelivery = RecordingNotificationDelivery()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: ChangingNotificationRuleSync(
        rules: [
          NotificationRules(categoryIds: ["system:flights"]),
          NotificationRules(categoryIds: []),
        ]
      ),
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
    XCTAssertTrue(notificationDelivery.messages.isEmpty)
    XCTAssertEqual(watchStore.savedStatus?.latestSyncedHistoryId, "124")
  }

  func testGmailWakeupNotifiesForHistoryMessageAlreadyInLocalCache() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.existingMessages = [message]
    syncService.syncedMessages = [message]
    syncService.newMessageIds = [message.providerMessageId]
    let notificationDelivery = RecordingNotificationDelivery()
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: RecordingGmailPushWatchStore(
        status: GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          routeId: "route-001"
        )
      )
    )

    _ = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertEqual(notificationDelivery.messages, [message])
  }

  func testGmailWakeupDoesNotNotifyBeforeNewMessageIsCategorized() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [pushMessage(categoryId: nil)]
    let notificationDelivery = RecordingNotificationDelivery()
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: RecordingGmailPushWatchStore(
        status: GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          routeId: "route-001"
        )
      )
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertTrue(handled)
    XCTAssertTrue(notificationDelivery.messages.isEmpty)
  }

  func testGmailWakeupShowsEnabledGenericFallbackWhenNewMessageIsUncategorized()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [pushMessage(categoryId: nil)]
    let notificationDelivery = RecordingNotificationDelivery()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      genericNotificationFallbackStore: StubGenericNotificationFallbackStore(isEnabled: true),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
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
    XCTAssertTrue(notificationDelivery.messages.isEmpty)
    XCTAssertEqual(notificationDelivery.genericNotificationIdentifiers.count, 1)
    XCTAssertEqual(watchStore.savedStatus?.latestSyncedHistoryId, "124")
  }

  func testGmailWakeupDoesNotNotifyForMessagesOutsideTheHistoryDelta() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message]
    syncService.newMessageIds = []
    let notificationDelivery = RecordingNotificationDelivery()
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: RecordingGmailPushWatchStore(
        status: GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          routeId: "route-001"
        )
      )
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertTrue(handled)
    XCTAssertTrue(notificationDelivery.messages.isEmpty)
  }

  func testGmailWakeupShowsEnabledGenericFallbackWhenHistoryDeltaIsUnavailable()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.usesUnavailableHistoryDelta = true
    let notificationDelivery = RecordingNotificationDelivery()
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      genericNotificationFallbackStore: StubGenericNotificationFallbackStore(isEnabled: true),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: RecordingGmailPushWatchStore(
        status: GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          routeId: "route-001"
        )
      )
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertTrue(handled)
    XCTAssertEqual(notificationDelivery.genericNotificationIdentifiers.count, 1)
  }

  func testGmailWakeupShowsEnabledGenericFallbackWhenHistoryIsExpired() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.historyIsExpired = true
    let notificationDelivery = RecordingNotificationDelivery()
    let mailboxConnection = connection.mailboxConnection(productAccountId: session.productAccountId)
    let statusPublished = expectation(description: "expired history status published")
    let observer = NotificationCenter.default.addObserver(
      forName: .mailboxMetadataDidSynchronize,
      object: nil,
      queue: .main
    ) { notification in
      guard
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.connectionId]
          as? String == mailboxConnection.id.rawValue,
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.phase]
          as? MailboxSyncPhase == .idle,
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.successfulSyncAt] is Date
      else { return }
      statusPublished.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      genericNotificationFallbackStore: StubGenericNotificationFallbackStore(isEnabled: true),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    await fulfillment(of: [statusPublished], timeout: 1)
    XCTAssertFalse(handled)
    XCTAssertEqual(notificationDelivery.genericNotificationIdentifiers.count, 1)
    XCTAssertEqual(watchStore.savedStatus?.latestSyncedHistoryId, "124")
  }

  func testGmailWakeupDoesNotShowFallbackAfterBackgroundDeadline() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [pushMessage(categoryId: "system:flights")]
    let notificationDelivery = RecordingNotificationDelivery()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      hasProcessingTimeRemaining: { false },
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
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
    XCTAssertTrue(notificationDelivery.messages.isEmpty)
    XCTAssertNil(watchStore.savedStatus)
  }

  func testGmailWakeupShowsEnabledGenericFallbackAfterBackgroundDeadline() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let notificationDelivery = RecordingNotificationDelivery()
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      genericNotificationFallbackStore: StubGenericNotificationFallbackStore(isEnabled: true),
      hasProcessingTimeRemaining: { false },
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: RecordingPushGmailMetadataSyncService(),
      watchStore: RecordingGmailPushWatchStore(
        status: GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          routeId: "route-001"
        )
      )
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertTrue(handled)
    XCTAssertEqual(notificationDelivery.genericNotificationIdentifiers.count, 1)
  }

  func testGmailWakeupDoesNotShowGenericFallbackAfterBackgroundDeadlineWithoutRules()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let notificationDelivery = RecordingNotificationDelivery()
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      genericNotificationFallbackStore: StubGenericNotificationFallbackStore(isEnabled: true),
      hasProcessingTimeRemaining: { false },
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(rules: NotificationRules(categoryIds: [])),
      sessionStore: sessionStore,
      syncService: RecordingPushGmailMetadataSyncService(),
      watchStore: RecordingGmailPushWatchStore(
        status: GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          routeId: "route-001"
        )
      )
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertFalse(handled)
    XCTAssertTrue(notificationDelivery.genericNotificationIdentifiers.isEmpty)
  }

  func testGmailWakeupShowsEnabledFallbackWhenDeadlineExpiresDuringCategoryDelivery()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let firstMessage = pushMessage(categoryId: "system:flights")
    let secondMessage = GmailMessageMetadata(
      categoryId: "system:flights",
      from: "Sender <sender@example.com>",
      isHistorical: false,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      providerInternalDateMilliseconds: 2,
      providerMessageId: "message-002",
      providerThreadId: "thread-002",
      replyTo: nil,
      snippet: "Snippet",
      stableProviderMessageId: "gmail:gmail-user-001:message-002",
      subject: "Subject",
      rfcMessageId: "<message-002@example.com>"
    )
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [firstMessage, secondMessage]
    let notificationDelivery = RecordingNotificationDelivery()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      genericNotificationFallbackStore: StubGenericNotificationFallbackStore(isEnabled: true),
      hasProcessingTimeRemaining: { notificationDelivery.messages.isEmpty },
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
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
    XCTAssertEqual(notificationDelivery.messages, [firstMessage])
    XCTAssertEqual(notificationDelivery.genericNotificationIdentifiers.count, 1)
    XCTAssertEqual(watchStore.savedStatus?.latestSyncedHistoryId, "124")
  }

  func testGmailWakeupDoesNotAdvanceWatermarkWhenNotificationRulesCannotLoad() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationRuleSync: FailingNotificationRuleSync(),
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
    XCTAssertNil(watchStore.savedStatus)
    XCTAssertEqual(
      syncService.syncedConnection,
      connection.mailboxConnection(productAccountId: session.productAccountId)
    )
  }

  func testGmailWakeupDoesNotFallbackWhenNotificationRulesCannotLoad()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let notificationDelivery = RecordingNotificationDelivery()
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      genericNotificationFallbackStore: StubGenericNotificationFallbackStore(isEnabled: true),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: FailingNotificationRuleSync(),
      sessionStore: sessionStore,
      syncService: RecordingPushGmailMetadataSyncService(),
      watchStore: RecordingGmailPushWatchStore(
        status: GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          routeId: "route-001"
        )
      )
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertFalse(handled)
    XCTAssertTrue(notificationDelivery.genericNotificationIdentifiers.isEmpty)
  }

  func testGmailWakeupShowsEnabledGenericFallbackWhenMetadataSyncFails() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncError = GmailPushRelayTestError.unexpectedCall
    let notificationDelivery = RecordingNotificationDelivery()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      genericNotificationFallbackStore: StubGenericNotificationFallbackStore(isEnabled: true),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
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
    XCTAssertEqual(notificationDelivery.genericNotificationIdentifiers.count, 1)
    XCTAssertNil(watchStore.savedStatus)
  }

  func testGmailWakeupDoesNotFallbackWhenRulesAreDisabledDuringFailedMetadataSync()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncError = GmailPushRelayTestError.unexpectedCall
    let notificationDelivery = RecordingNotificationDelivery()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      genericNotificationFallbackStore: StubGenericNotificationFallbackStore(isEnabled: true),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: ChangingNotificationRuleSync(
        rules: [
          NotificationRules(categoryIds: ["system:flights"]),
          NotificationRules(categoryIds: []),
        ]
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    do {
      _ = try await handler.handle(userInfo: [
        "historyId": "124",
        "provider": "gmail",
        "routeId": "route-001",
      ])
      XCTFail("Expected metadata sync failure")
    } catch {
      XCTAssertTrue(error is GmailPushRelayTestError)
    }
    XCTAssertTrue(notificationDelivery.genericNotificationIdentifiers.isEmpty)
    XCTAssertNil(watchStore.savedStatus)
  }

  func testGmailWakeupDoesNotFallbackWhenRulesCannotReloadAfterMetadataSync()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let notificationDelivery = RecordingNotificationDelivery()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      genericNotificationFallbackStore: StubGenericNotificationFallbackStore(isEnabled: true),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: FailingAfterFirstNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: RecordingPushGmailMetadataSyncService(),
      watchStore: watchStore
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertFalse(handled)
    XCTAssertTrue(notificationDelivery.genericNotificationIdentifiers.isEmpty)
    XCTAssertNil(watchStore.savedStatus)
  }

  func testGmailWakeupAdvancesWatermarkForUnlistedMessagesWithoutNotificationRules() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.hasUnlistedNewMessages = true
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationRuleSync: StubNotificationRuleSync(rules: NotificationRules(categoryIds: [])),
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
    XCTAssertEqual(watchStore.savedStatus?.latestSyncedHistoryId, "124")
    XCTAssertEqual(syncService.includesHistoryCandidates, false)
  }

  func testGmailWakeupDeliversListedMessagesBeforeRetryingUnlistedMessages() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.hasUnlistedNewMessages = true
    syncService.syncedMessages = [message]
    syncService.newMessageIds = [message.providerMessageId]
    let notificationDelivery = RecordingNotificationDelivery()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
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
    XCTAssertEqual(notificationDelivery.messages, [message])
    XCTAssertNil(watchStore.savedStatus)
  }

  func testGmailWakeupDeliversListedMessagesBeforeEnabledGenericFallback() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let uncategorizedMessage = GmailMessageMetadata(
      categoryId: nil,
      from: "Sender <sender@example.com>",
      isHistorical: false,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      providerInternalDateMilliseconds: 2,
      providerMessageId: "message-002",
      providerThreadId: "thread-002",
      replyTo: nil,
      snippet: "Snippet",
      stableProviderMessageId: "gmail:gmail-user-001:message-002",
      subject: "Subject",
      rfcMessageId: "<message-002@example.com>"
    )
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message, uncategorizedMessage]
    syncService.newMessageIds = [message.providerMessageId, uncategorizedMessage.providerMessageId]
    let notificationDelivery = RecordingNotificationDelivery()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      genericNotificationFallbackStore: StubGenericNotificationFallbackStore(isEnabled: true),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
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
    XCTAssertEqual(notificationDelivery.messages, [message])
    XCTAssertEqual(notificationDelivery.genericNotificationIdentifiers.count, 1)
    XCTAssertEqual(watchStore.savedStatus?.latestSyncedHistoryId, "124")
  }

  func testGmailWakeupDoesNotAdvanceWatermarkWhenNotificationDeliveryFails() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message]
    syncService.newMessageIds = [message.providerMessageId]
    let receiptStore = RecordingGmailPushReceiptStore()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: FailingNotificationDelivery(),
      notificationReceiptStore: receiptStore,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
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
    XCTAssertTrue(receiptStore.receipts.isEmpty)
    XCTAssertNil(watchStore.savedStatus)
  }

  func testGmailWakeupShowsEnabledGenericFallbackWhenCategoryNotificationDeliveryFails()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message]
    syncService.newMessageIds = [message.providerMessageId]
    let genericDelivery = RecordingNotificationDelivery()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      genericNotificationDelivery: genericDelivery,
      genericNotificationFallbackStore: StubGenericNotificationFallbackStore(isEnabled: true),
      notificationDelivery: FailingNotificationDelivery(),
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
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
    XCTAssertEqual(genericDelivery.genericNotificationIdentifiers.count, 1)
    XCTAssertEqual(watchStore.savedStatus?.latestSyncedHistoryId, "124")
  }

  func testGmailWakeupDoesNotAdvanceWatermarkWhenNotificationAuthorizationIsDenied()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message]
    syncService.newMessageIds = [message.providerMessageId]
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: RecordingNotificationDelivery(),
      notificationAuthorization: StubNotificationAuthorization(granted: false),
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
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
    XCTAssertNil(watchStore.savedStatus)
  }

  func testGmailWakeupAdvancesWatermarkWhenNoMessageMatchesDeniedNotificationAuthorization()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [pushMessage(categoryId: "system:promotions")]
    syncService.newMessageIds = ["message-001"]
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationAuthorization: StubNotificationAuthorization(granted: false),
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
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
    XCTAssertEqual(watchStore.savedStatus?.latestSyncedHistoryId, "124")
  }

  func testGmailWakeupAdvancesWatermarkForCompletedReceiptWhenAuthorizationIsDenied()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let receiptStore = RecordingGmailPushReceiptStore()
    _ = try receiptStore.claim(
      message,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    try receiptStore.complete(
      message,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message]
    syncService.newMessageIds = [message.providerMessageId]
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: RecordingNotificationDelivery(),
      notificationAuthorization: StubNotificationAuthorization(granted: false),
      notificationReceiptStore: receiptStore,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
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
    XCTAssertEqual(watchStore.savedStatus?.latestSyncedHistoryId, "124")
  }

  func testGmailWakeupStopsNotificationsWhenBackgroundTimeExpiresDuringDelivery() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [
      pushMessage(categoryId: "system:flights"),
      pushMessage(categoryId: "system:flights"),
    ]
    let notificationDelivery = RecordingNotificationDelivery()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      hasProcessingTimeRemaining: { notificationDelivery.messages.isEmpty },
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
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
    XCTAssertEqual(notificationDelivery.messages.count, 1)
    XCTAssertNil(watchStore.savedStatus)
  }

  // swiftlint:disable:next function_body_length
  func testGmailWakeupDoesNotRedeliverAfterPartialNotificationDelivery() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let messages = [
      pushMessage(categoryId: "system:flights"),
      GmailMessageMetadata(
        categoryId: "system:flights",
        from: "Sender <sender@example.com>",
        isHistorical: false,
        providerAccountIdentifier: connection.providerAccountIdentifier,
        providerInternalDateMilliseconds: 2,
        providerMessageId: "message-002",
        providerThreadId: "thread-002",
        replyTo: nil,
        snippet: "Snippet",
        stableProviderMessageId: "gmail:gmail-user-001:message-002",
        subject: "Subject",
        rfcMessageId: "<message-002@example.com>"
      ),
    ]
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = messages
    syncService.newMessageIds = Set(messages.map(\.providerMessageId))
    let notificationDelivery = RecordingNotificationDelivery()
    let receiptStore = RecordingGmailPushReceiptStore()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let firstHandler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      hasProcessingTimeRemaining: { notificationDelivery.messages.isEmpty },
      notificationDelivery: notificationDelivery,
      notificationReceiptStore: receiptStore,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    let firstHandled = try await firstHandler.handle(userInfo: [
      "historyId": "124", "provider": "gmail", "routeId": "route-001",
    ])
    XCTAssertFalse(firstHandled)

    let secondHandler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationReceiptStore: receiptStore,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    let secondHandled = try await secondHandler.handle(userInfo: [
      "historyId": "124", "provider": "gmail", "routeId": "route-001",
    ])
    XCTAssertTrue(secondHandled)
    XCTAssertEqual(notificationDelivery.messages, messages)
    XCTAssertEqual(receiptStore.receipts, Set(messages.map(\.stableProviderMessageId)))
  }

  func testUserNotificationServiceRequestsVisibleNotificationAuthorization() async throws {
    let center = RecordingUserNotificationCenter()
    let service = UserNotificationService(center: center)

    let granted = try await service.requestAuthorization()

    XCTAssertTrue(granted)
    XCTAssertEqual(
      center.authorizationOptions,
      [.alert, .badge, .sound]
    )
  }

  func testUserNotificationServiceBuildsPrivacyPreservingNotification() async throws {
    let center = RecordingUserNotificationCenter()
    let service = UserNotificationService(center: center)
    let message = pushMessage(categoryId: "system:flights")

    try await service.deliver(message: message)

    let request = try XCTUnwrap(center.request)
    XCTAssertEqual(request.identifier, message.stableProviderMessageId)
    XCTAssertEqual(request.content.title, "New mail")
    XCTAssertEqual(request.content.body, "A message matched your notification rules.")
    XCTAssertFalse(request.content.body.contains(message.subject))
    XCTAssertTrue(request.content.userInfo.isEmpty)
    XCTAssertNil(request.trigger)
  }

  func testUserNotificationServiceBuildsContentFreeGenericFallback() async throws {
    let center = RecordingUserNotificationCenter()
    let service = UserNotificationService(center: center)

    try await service.deliverGeneric(identifier: "generic-fallback")

    let request = try XCTUnwrap(center.request)
    XCTAssertEqual(request.identifier, "generic-fallback")
    XCTAssertEqual(request.content.title, "New mail")
    XCTAssertEqual(request.content.body, "New mail is available.")
    XCTAssertTrue(request.content.userInfo.isEmpty)
    XCTAssertNil(request.trigger)
  }

  func testGenericNotificationFallbackStoreIsDisabledByDefaultAndScopedToAccount() throws {
    let suiteName = "GenericNotificationFallbackTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsFallbackStore(defaults: defaults)

    XCTAssertFalse(store.isEnabled(productAccountId: "account-a"))
    XCTAssertFalse(store.isEnabled(productAccountId: "account-b"))

    store.setEnabled(true, productAccountId: "account-a")

    XCTAssertTrue(store.isEnabled(productAccountId: "account-a"))
    XCTAssertFalse(store.isEnabled(productAccountId: "account-b"))
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
      notificationRuleSync: StubNotificationRuleSync(rules: NotificationRules(categoryIds: [])),
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

  func testGmailWakeupDoesNotPersistAfterSessionChangesDuringNotificationDelivery() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [pushMessage(categoryId: "system:flights")]
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let notificationDelivery = RecordingNotificationDelivery(
      onDeliver: { try? sessionStore.clear() }
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
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
    XCTAssertEqual(notificationDelivery.messages.count, 1)
    XCTAssertNil(watchStore.savedStatus)
  }

  func testGmailWakeupStopsNotificationDeliveryAfterSessionChanges() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let firstMessage = pushMessage(categoryId: "system:flights")
    let secondMessage = GmailMessageMetadata(
      categoryId: "system:flights",
      from: firstMessage.from,
      isHistorical: false,
      providerAccountIdentifier: firstMessage.providerAccountIdentifier,
      providerInternalDateMilliseconds: firstMessage.providerInternalDateMilliseconds,
      providerMessageId: "message-002",
      providerThreadId: "thread-002",
      replyTo: nil,
      snippet: firstMessage.snippet,
      stableProviderMessageId: "gmail:gmail-user-001:message-002",
      subject: firstMessage.subject,
      rfcMessageId: "<message-002@example.com>"
    )
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [firstMessage, secondMessage]
    let notificationDelivery = RecordingNotificationDelivery(
      onDeliver: { try? sessionStore.clear() }
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: RecordingGmailPushWatchStore(
        status: GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          routeId: "route-001"
        )
      )
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertFalse(handled)
    XCTAssertEqual(notificationDelivery.messages, [firstMessage])
  }

  func testConcurrentGmailWakeupPreservesTheNewestRouteWatermark() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.onSync = {
      try? watchStore.save(
        GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          latestSyncedHistoryId: "126",
          routeId: "route-001"
        ),
        productAccountId: self.session.productAccountId,
        providerAccountIdentifier: self.connection.providerAccountIdentifier
      )
    }
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationRuleSync: StubNotificationRuleSync(rules: .init(categoryIds: [])),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "125",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertTrue(handled)
    XCTAssertEqual(syncService.shouldPersist, true)
    XCTAssertEqual(watchStore.savedStatus?.latestSyncedHistoryId, "126")
  }

  func testGmailWakeupDoesNotDeliverAfterConcurrentWatermarkAdvance() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let message = pushMessage(categoryId: "system:flights")
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message]
    syncService.newMessageIds = [message.providerMessageId]
    syncService.onSync = {
      try? watchStore.save(
        GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          latestSyncedHistoryId: "126",
          routeId: "route-001"
        ),
        productAccountId: self.session.productAccountId,
        providerAccountIdentifier: self.connection.providerAccountIdentifier
      )
    }
    let notificationDelivery = RecordingNotificationDelivery()
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "125",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    XCTAssertFalse(handled)
    XCTAssertTrue(notificationDelivery.messages.isEmpty)
    XCTAssertEqual(watchStore.savedStatus?.latestSyncedHistoryId, "126")
  }

  func testGmailWakeupDoesNotAdvanceWatermarkForInFlightNotification() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message]
    syncService.newMessageIds = [message.providerMessageId]
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: RecordingNotificationDelivery(),
      notificationReceiptStore: InFlightGmailPushReceiptStore(),
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124", "provider": "gmail", "routeId": "route-001",
    ])

    XCTAssertFalse(handled)
    XCTAssertNil(watchStore.savedStatus)
  }

  func testOverlappingGmailWakeupsDeliverMatchingMessageOnce() async throws {
    let overlappingWake = try await startOverlappingFirstWake()
    let fixture = overlappingWake.fixture
    defer { fixture.cleanup() }

    let overlappingWakeHandled = try await overlappingWake.handler.handle(
      userInfo: overlappingWake.userInfo
    )

    XCTAssertFalse(overlappingWakeHandled)
    XCTAssertNil(fixture.watchStore.savedStatus)
    overlappingWake.notificationCenter.resumeDelivery()
    let firstWakeHandled = try await overlappingWake.firstWake.value
    XCTAssertTrue(firstWakeHandled)
    XCTAssertEqual(
      overlappingWake.notificationCenter.requests.map(\.identifier),
      [fixture.message.stableProviderMessageId]
    )
    XCTAssertEqual(fixture.watchStore.savedStatus?.latestSyncedHistoryId, "124")
  }

  func testCancelledOverlappingGmailWakeupReleasesMessageForRetry() async throws {
    let overlappingWake = try await startOverlappingFirstWake()
    let fixture = overlappingWake.fixture
    defer { fixture.cleanup() }

    let overlappingWakeHandled = try await overlappingWake.handler.handle(
      userInfo: overlappingWake.userInfo
    )
    XCTAssertFalse(overlappingWakeHandled)
    overlappingWake.notificationCenter.failDelivery(with: CancellationError())
    do {
      _ = try await overlappingWake.firstWake.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    XCTAssertNil(fixture.watchStore.savedStatus)

    let retryCenter = RecordingUserNotificationCenter()
    let retryHandler = fixture.handler(notificationCenter: retryCenter)
    let retryHandled = try await retryHandler.handle(userInfo: overlappingWake.userInfo)
    XCTAssertTrue(retryHandled)
    XCTAssertEqual(retryCenter.request?.identifier, fixture.message.stableProviderMessageId)
    XCTAssertEqual(fixture.watchStore.savedStatus?.latestSyncedHistoryId, "124")
  }

  func testGmailWakeupRetriesDurableEligibilityAfterInboxPersistenceWasInterrupted()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let eligibilityStore = RecordingGmailPushEligibilityStore()
    try eligibilityStore.record(
      [message],
      throughHistoryId: "124",
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message]
    syncService.newMessageIds = []
    let notificationDelivery = RecordingNotificationDelivery()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationEligibilityStore: eligibilityStore,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124", "provider": "gmail", "routeId": "route-001",
    ])

    XCTAssertTrue(handled)
    XCTAssertEqual(notificationDelivery.messages, [message])
    XCTAssertEqual(watchStore.savedStatus?.latestSyncedHistoryId, "124")
    XCTAssertTrue(
      try eligibilityStore.eligibleStableMessageIds(
        after: "124",
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ).isEmpty
    )
  }

  func testGmailWakeupDoesNotAdvanceWatermarkForStaleDurableEligibilityWithoutHistoryDelta()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let eligibilityStore = RecordingGmailPushEligibilityStore()
    try eligibilityStore.record(
      [pushMessage(id: "stale-message", categoryId: "system:flights")],
      throughHistoryId: "124",
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [pushMessage(id: "current-message", categoryId: "system:flights")]
    syncService.usesUnavailableHistoryDelta = true
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: RecordingNotificationDelivery(),
      notificationEligibilityStore: eligibilityStore,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124", "provider": "gmail", "routeId": "route-001",
    ])

    XCTAssertFalse(handled)
    XCTAssertNil(watchStore.savedStatus)
  }

  func testGmailWakeupDoesNotAdvanceWatermarkAfterDeliveringDurableEligibilityWithoutHistoryDelta()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let eligibilityStore = RecordingGmailPushEligibilityStore()
    try eligibilityStore.record(
      [message],
      throughHistoryId: "124",
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message]
    syncService.usesUnavailableHistoryDelta = true
    let notificationDelivery = RecordingNotificationDelivery()
    let watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationEligibilityStore: eligibilityStore,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124", "provider": "gmail", "routeId": "route-001",
    ])

    XCTAssertFalse(handled)
    XCTAssertEqual(notificationDelivery.messages, [message])
    XCTAssertNil(watchStore.savedStatus)
  }

  func testNotificationEligibilityPersistsUntilItsWatermarkAdvances() throws {
    let suiteName = "GmailPushEligibilityTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let message = pushMessage(categoryId: "system:flights")
    try GmailPushEligibilityStore(defaults: defaults).record(
      [message],
      throughHistoryId: "124",
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    let restartedStore = GmailPushEligibilityStore(defaults: defaults)
    XCTAssertEqual(
      try restartedStore.eligibleStableMessageIds(
        after: "123",
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      [message.stableProviderMessageId]
    )
    XCTAssertTrue(
      try restartedStore.eligibleStableMessageIds(
        after: "124",
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ).isEmpty
    )
  }

  func testNotificationEligibilityRetainsLatestBoundaryForRepeatedMessages() throws {
    let suiteName = "GmailPushEligibilityTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = GmailPushEligibilityStore(defaults: defaults)
    let message = pushMessage(categoryId: "system:flights")

    try store.record(
      [message],
      throughHistoryId: "124",
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    try store.record(
      [message],
      throughHistoryId: "130",
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    XCTAssertEqual(
      try store.eligibleStableMessageIds(
        after: "126",
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      [message.stableProviderMessageId]
    )
  }

  func testRouteReplacementDuringDeliveryDoesNotRedeliverMessage() async throws {
    let fixture = try gmailPushOverlapFixture()
    defer { fixture.cleanup() }
    let originalCenter = SuspendingUserNotificationCenter()
    let originalHandler = fixture.handler(notificationCenter: originalCenter)
    let originalUserInfo = fixture.userInfo()
    let originalWake = Task { try await originalHandler.handle(userInfo: originalUserInfo) }
    await originalCenter.waitUntilDeliveryStarts()
    try fixture.replaceRoute(with: "route-002")
    originalCenter.resumeDelivery()
    let originalWakeHandled = try await originalWake.value
    XCTAssertFalse(originalWakeHandled)

    let replacementCenter = RecordingUserNotificationCenter()
    let replacementHandler = fixture.handler(notificationCenter: replacementCenter)
    let replacementWakeHandled = try await replacementHandler.handle(
      userInfo: fixture.userInfo(routeId: "route-002")
    )
    XCTAssertTrue(replacementWakeHandled)
    XCTAssertEqual(originalCenter.requests.count, 1)
    XCTAssertNil(replacementCenter.request)
    XCTAssertEqual(fixture.watchStore.savedStatus?.latestSyncedHistoryId, "124")
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

  private func pushMessage(
    id: String = "message-001",
    categoryId: String?
  ) -> GmailMessageMetadata {
    GmailMessageMetadata(
      categoryId: categoryId,
      from: "Airline <updates@example.com>",
      isHistorical: false,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      providerInternalDateMilliseconds: 1_781_300_000_000,
      providerMessageId: id,
      providerThreadId: "thread-001",
      replyTo: nil,
      snippet: "Your itinerary is ready",
      stableProviderMessageId: "gmail:gmail-user-001:\(id)",
      subject: "Flight confirmation",
      rfcMessageId: "<\(id)@example.com>"
    )
  }

  private func gmailPushOverlapFixture() throws -> GmailPushOverlapFixture {
    try GmailPushOverlapFixture(
      connection: connection,
      message: pushMessage(categoryId: "system:flights"),
      session: session
    )
  }

  private func claimAndReleaseReceipt(
    _ message: GmailMessageMetadata,
    from store: GmailPushNotificationReceiptStore
  ) throws -> GmailPushNotificationReceiptClaim {
    let claim = try store.claim(
      message,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    try store.release(
      message,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    return claim
  }

  private struct OverlappingGmailWake {
    let fixture: GmailPushOverlapFixture
    let notificationCenter: SuspendingUserNotificationCenter
    let handler: GmailPushWakeupHandler
    let userInfo: [AnyHashable: Any]
    let firstWake: Task<Bool, Error>
  }

  private func startOverlappingFirstWake() async throws -> OverlappingGmailWake {
    let fixture = try gmailPushOverlapFixture()
    let notificationCenter = SuspendingUserNotificationCenter()
    let handler = fixture.handler(notificationCenter: notificationCenter)
    let userInfo = fixture.userInfo()
    let firstWake = Task { try await handler.handle(userInfo: userInfo) }
    await notificationCenter.waitUntilDeliveryStarts()
    return OverlappingGmailWake(
      fixture: fixture,
      notificationCenter: notificationCenter,
      handler: handler,
      userInfo: userInfo,
      firstWake: firstWake
    )
  }
}

@MainActor
private final class GmailPushOverlapFixture {
  let message: GmailMessageMetadata
  let watchStore: RecordingGmailPushWatchStore

  private let connection: GmailProviderConnectionStatus
  private let defaults: UserDefaults
  private let receiptStore: GmailPushNotificationReceiptStore
  private let session: ProductAccountSessionSnapshot
  private let sessionStore = InMemoryProductAccountSessionStore()
  private let suiteName: String
  private let syncService = RecordingPushGmailMetadataSyncService()

  init(
    connection: GmailProviderConnectionStatus,
    message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws {
    self.connection = connection
    self.message = message
    self.session = session
    let suiteName = "GmailPushOverlapTests.\(UUID().uuidString)"
    self.suiteName = suiteName
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    receiptStore = GmailPushNotificationReceiptStore(defaults: defaults)
    watchStore = RecordingGmailPushWatchStore(
      status: GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: "route-001"
      )
    )
    try sessionStore.save(session)
    syncService.syncedMessages = [message]
    syncService.newMessageIds = [message.providerMessageId]
  }

  func cleanup() {
    defaults.removePersistentDomain(forName: suiteName)
  }

  func handler(
    notificationCenter: UserNotificationCenterClient
  ) -> GmailPushWakeupHandler {
    GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: UserNotificationService(center: notificationCenter),
      notificationReceiptStore: receiptStore,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )
  }

  func replaceRoute(with routeId: String) throws {
    try watchStore.save(
      GmailPushWatchStatus(
        expirationMilliseconds: 1_781_400_000_000,
        historyId: "123",
        routeId: routeId
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
  }

  func userInfo(routeId: String = "route-001") -> [AnyHashable: Any] {
    ["historyId": "124", "provider": "gmail", "routeId": routeId]
  }
}

private final class RecordingGmailPushWatchStore: GmailPushWatchPersisting {
  var clearedProductAccountId: String?
  var savedStatus: GmailPushWatchStatus?
  private var status: GmailPushWatchStatus?
  private var statuses: [String: GmailPushWatchStatus]
  private let failingProviderAccountIdentifiers: Set<String>

  init(status: GmailPushWatchStatus? = nil) {
    self.status = status
    statuses = [:]
    failingProviderAccountIdentifiers = []
  }

  init(
    statuses: [String: GmailPushWatchStatus],
    failingProviderAccountIdentifiers: Set<String> = []
  ) {
    status = nil
    self.statuses = statuses
    self.failingProviderAccountIdentifiers = failingProviderAccountIdentifiers
  }

  func clear(
    productAccountId: String,
    providerAccountIdentifier _: String
  ) throws {
    clearedProductAccountId = productAccountId
  }

  func load(
    productAccountId _: String,
    providerAccountIdentifier: String
  ) throws -> GmailPushWatchStatus? {
    if failingProviderAccountIdentifiers.contains(providerAccountIdentifier) {
      throw GmailPushRelayTestError.unexpectedCall
    }
    return statuses[providerAccountIdentifier] ?? status
  }

  func save(
    _ status: GmailPushWatchStatus,
    productAccountId _: String,
    providerAccountIdentifier: String
  ) throws {
    savedStatus = status
    self.status = status
    statuses[providerAccountIdentifier] = status
  }
}

private final class RecordingGmailPushConnectionStore: GmailPushConnectionPersisting {
  var clearedProductAccountId: String?
  var loadedProductAccountId: String?
  var productAccountId: String?
  var savedConnection: GmailProviderConnectionStatus?
  private let connection: GmailProviderConnectionStatus?
  private let connections: [GmailProviderConnectionStatus]

  init(connection: GmailProviderConnectionStatus? = nil) {
    self.connection = connection
    connections = connection.map { [$0] } ?? []
  }

  init(connections: [GmailProviderConnectionStatus]) {
    connection = connections.first
    self.connections = connections
  }

  func clear(productAccountId: String) throws {
    clearedProductAccountId = productAccountId
  }

  func load(productAccountId: String) throws -> GmailProviderConnectionStatus? {
    loadedProductAccountId = productAccountId
    return connection
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailProviderConnectionStatus? {
    loadedProductAccountId = productAccountId
    return connections.first { $0.providerAccountIdentifier == providerAccountIdentifier }
  }

  func loadAll(productAccountId: String) throws -> [GmailProviderConnectionStatus] {
    loadedProductAccountId = productAccountId
    return connections
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
  var gmailIdentityToken: String?
  var historyId: String?
  var session: ProductAccountSessionSnapshot?
  private let routeId: String
  private let verified: Bool

  init(verified: Bool = true, routeId: String = "route-001") {
    self.routeId = routeId
    self.verified = verified
  }

  func verifyGmailPushWatch(
    gmailIdentityToken: String,
    historyId: String,
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> GmailPushVerificationResponse {
    self.gmailIdentityToken = gmailIdentityToken
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

private final class ThrowingGmailPushVerificationTransport: GmailPushVerificationTransport {
  func verifyGmailPushWatch(
    gmailIdentityToken _: String,
    historyId _: String,
    identityToken _: String,
    trustedDeviceId _: String
  ) async throws -> GmailPushVerificationResponse {
    throw GmailPushRelayError.invalidWatchResponse
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

private final class RecordingPushGmailMetadataSyncService: MailboxMetadataSyncing {
  var existingMessages: [GmailMessageMetadata] = []
  var historyIsExpired = false
  var onSync: (() -> Void)?
  var shouldPersist: Bool?
  var sinceHistoryId: String?
  var syncedMessages: [GmailMessageMetadata] = []
  var hasUnlistedNewMessages = false
  var includesHistoryCandidates: Bool?
  var newMessageIds: Set<String>?
  var syncedConnection: MailboxConnection?
  var syncedSession: ProductAccountSessionSnapshot?
  var syncError: Error?
  var usesUnavailableHistoryDelta = false

  func categorizeHistorical(
    scope _: HistoricalCategorizationScope,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    throw GmailPushRelayTestError.unexpectedCall
  }

  func loadInbox(
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    GmailMetadataSyncResult(messages: existingMessages, threads: [])
      .mailboxResult(connectionId: connection.id)
  }

  func syncInbox(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    throw GmailPushRelayTestError.unexpectedCall
  }

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection: MailboxConnection,
    includingHistoryCandidates: Bool,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId: String?,
    throughHistoryId _: String?,
    shouldPersist: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    syncedConnection = connection
    includesHistoryCandidates = includingHistoryCandidates
    syncedSession = session
    self.sinceHistoryId = sinceHistoryId
    onSync?()
    let canPersist = shouldPersist()
    self.shouldPersist = canPersist
    guard canPersist else {
      throw GmailMessageMetadataSyncError.staleLocalConnection
    }
    if let syncError {
      throw syncError
    }
    return GmailMetadataSyncResult(
      historyIsExpired: historyIsExpired,
      hasUnlistedNewMessages: hasUnlistedNewMessages,
      messages: syncedMessages,
      newMessageIds: usesUnavailableHistoryDelta
        ? nil
        : newMessageIds ?? Set(syncedMessages.map(\.providerMessageId)),
      threads: []
    ).mailboxResult(connectionId: connection.id)
  }

  func overrideCategory(
    _: String,
    for _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    throw GmailPushRelayTestError.unexpectedCall
  }
}

private final class RecordingNotificationDelivery:
  CategoryAwareNotificationDelivering, GenericNotificationDelivering,
  NotificationAuthorizationRequesting
{
  private(set) var genericNotificationIdentifiers: [String] = []
  private(set) var messages: [GmailMessageMetadata] = []
  private let onDeliver: () -> Void

  init(onDeliver: @escaping () -> Void = {}) {
    self.onDeliver = onDeliver
  }

  func deliver(message: GmailMessageMetadata) async throws {
    messages.append(message)
    onDeliver()
  }

  func deliverGeneric(identifier: String) async throws {
    genericNotificationIdentifiers.append(identifier)
    onDeliver()
  }

  func requestAuthorization() async throws -> Bool {
    true
  }
}

private struct StubGenericNotificationFallbackStore: GenericNotificationFallbackPersisting {
  let isEnabled: Bool

  func isEnabled(productAccountId _: String) -> Bool {
    isEnabled
  }

  func setEnabled(_: Bool, productAccountId _: String) {}
}

private struct FailingNotificationDelivery:
  CategoryAwareNotificationDelivering, NotificationAuthorizationRequesting
{
  func deliver(message _: GmailMessageMetadata) async throws {
    throw GmailPushRelayTestError.unexpectedCall
  }

  func requestAuthorization() async throws -> Bool {
    true
  }
}

private struct StubNotificationAuthorization: NotificationAuthorizationRequesting {
  let granted: Bool

  init(granted: Bool = true) {
    self.granted = granted
  }

  func requestAuthorization() async throws -> Bool {
    granted
  }
}

private final class RecordingGmailPushReceiptStore:
  GmailPushNotificationReceiptPersisting
{
  private(set) var receipts: Set<String> = []

  func claim(
    _ message: GmailMessageMetadata,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> GmailPushNotificationReceiptClaim {
    receipts.insert(message.stableProviderMessageId).inserted ? .claimed : .completed
  }

  func complete(
    _: GmailMessageMetadata,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}

  func release(
    _ message: GmailMessageMetadata,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    receipts.remove(message.stableProviderMessageId)
  }
}

private final class RecordingGmailPushEligibilityStore: GmailPushEligibilityPersisting {
  private var records: [String: String] = [:]

  func record(
    _ messages: [GmailMessageMetadata],
    throughHistoryId: String,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    for message in messages {
      if let historyId = records[message.stableProviderMessageId],
        !gmailHistoryIdIsNewer(throughHistoryId, than: historyId)
      {
        continue
      }
      records[message.stableProviderMessageId] = throughHistoryId
    }
  }

  func eligibleStableMessageIds(
    after historyId: String,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> Set<String> {
    Set(records.compactMap { gmailHistoryIdIsNewer($0.value, than: historyId) ? $0.key : nil })
  }

  func discard(
    through historyId: String,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    records = records.filter { gmailHistoryIdIsNewer($0.value, than: historyId) }
  }
}

private struct InFlightGmailPushReceiptStore: GmailPushNotificationReceiptPersisting {
  func claim(
    _: GmailMessageMetadata,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> GmailPushNotificationReceiptClaim { .inFlight }

  func complete(
    _: GmailMessageMetadata,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}

  func release(
    _: GmailMessageMetadata,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}
}

private final class RecordingUserNotificationCenter: UserNotificationCenterClient {
  private(set) var authorizationOptions: UNAuthorizationOptions?
  private(set) var request: UNNotificationRequest?

  func add(_ request: UNNotificationRequest) async throws {
    self.request = request
  }

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    authorizationOptions = options
    return true
  }
}

@MainActor
private final class SuspendingUserNotificationCenter: UserNotificationCenterClient {
  private var deliveryContinuation: CheckedContinuation<Void, Error>?
  private var deliveryStartedContinuation: CheckedContinuation<Void, Never>?
  private var didStartDelivery = false
  private(set) var requests: [UNNotificationRequest] = []

  func add(_ request: UNNotificationRequest) async throws {
    guard deliveryContinuation == nil else {
      XCTFail("Unexpected overlapping notification delivery")
      throw CancellationError()
    }
    requests.append(request)
    didStartDelivery = true
    deliveryStartedContinuation?.resume()
    deliveryStartedContinuation = nil
    try await withCheckedThrowingContinuation { continuation in
      deliveryContinuation = continuation
    }
  }

  func requestAuthorization(options _: UNAuthorizationOptions) async throws -> Bool {
    true
  }

  func waitUntilDeliveryStarts() async {
    guard !didStartDelivery else { return }
    await withCheckedContinuation { continuation in
      deliveryStartedContinuation = continuation
    }
  }

  func resumeDelivery() {
    deliveryContinuation?.resume()
    deliveryContinuation = nil
  }

  func failDelivery(with error: Error) {
    deliveryContinuation?.resume(throwing: error)
    deliveryContinuation = nil
  }
}

private struct StubNotificationRuleSync: NotificationRuleSyncing {
  let rules: NotificationRules

  func loadRules(
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    NotificationRuleSyncSnapshot(rules: rules, updatedAt: nil)
  }

  func saveRules(
    _ rules: NotificationRules,
    expectedUpdatedAt _: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    NotificationRuleSyncSnapshot(rules: rules, updatedAt: nil)
  }
}

private struct AssigningBackgroundCategorizer: GmailMessageCategorizing {
  let categoryId: String

  func categorize(
    messages: [GmailMessageMetadata],
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    messages
  }

  func categorizeForBackgroundNotification(
    messages: [GmailMessageMetadata],
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    messages.map { $0.assigningCategory(categoryId) }
  }

  func categorizeHistorical(
    messages: [GmailMessageMetadata],
    scope _: GmailHistoricalCategorizationScope,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    messages
  }

  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    message.assigningCategory(categoryId)
  }
}

private struct FailingNotificationRuleSync: NotificationRuleSyncing {
  func loadRules(
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    throw GmailPushRelayTestError.unexpectedCall
  }

  func saveRules(
    _ rules: NotificationRules,
    expectedUpdatedAt _: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    NotificationRuleSyncSnapshot(rules: rules, updatedAt: nil)
  }
}

private struct ExpiredCachedRuleSync: NotificationRuleSyncing {
  let cachedRules: NotificationRules

  func loadRules(
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    throw ConvexClientError.httpError(statusCode: 401)
  }

  func loadRulesForBackground(
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    NotificationRuleSyncSnapshot(rules: cachedRules, updatedAt: 1_781_400_000_000)
  }

  func saveRules(
    _ rules: NotificationRules,
    expectedUpdatedAt _: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    NotificationRuleSyncSnapshot(rules: rules, updatedAt: nil)
  }
}

private actor ChangingNotificationRuleSync: NotificationRuleSyncing {
  private var rules: [NotificationRules]

  init(rules: [NotificationRules]) {
    self.rules = rules
  }

  func loadRules(
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    NotificationRuleSyncSnapshot(rules: rules.removeFirst(), updatedAt: nil)
  }

  func saveRules(
    _ rules: NotificationRules,
    expectedUpdatedAt _: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    NotificationRuleSyncSnapshot(rules: rules, updatedAt: nil)
  }
}

private actor FailingAfterFirstNotificationRuleSync: NotificationRuleSyncing {
  private let rules: NotificationRules
  private var hasLoaded = false

  init(rules: NotificationRules) {
    self.rules = rules
  }

  func loadRules(
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    guard !hasLoaded else { throw GmailPushRelayTestError.unexpectedCall }
    hasLoaded = true
    return NotificationRuleSyncSnapshot(rules: rules, updatedAt: nil)
  }

  func saveRules(
    _ rules: NotificationRules,
    expectedUpdatedAt _: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    NotificationRuleSyncSnapshot(rules: rules, updatedAt: nil)
  }
}

private enum GmailPushRelayTestError: Error {
  case unexpectedCall
}
