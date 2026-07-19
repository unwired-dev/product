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
    XCTAssertEqual(connectionStore.loadedProductAccountId, session.productAccountId)
    XCTAssertEqual(syncService.syncedConnection, connection)
    XCTAssertEqual(syncService.syncedSession, session)
    XCTAssertEqual(syncService.sinceHistoryId, "123")
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
      syncService: RecordingPushGmailMetadataSyncService(),
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

    XCTAssertTrue(handled)
    XCTAssertEqual(notificationDelivery.genericNotificationIdentifiers.count, 1)
    XCTAssertEqual(watchStore.savedStatus?.latestSyncedHistoryId, "124")
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
    let fixture = try gmailPushOverlapFixture()
    defer { fixture.cleanup() }
    let notificationCenter = SuspendingUserNotificationCenter()
    let handler = fixture.handler(notificationCenter: notificationCenter)
    let userInfo = fixture.userInfo()

    let firstWake = Task { try await handler.handle(userInfo: userInfo) }
    await notificationCenter.waitUntilDeliveryStarts()

    let overlappingWakeHandled = try await handler.handle(userInfo: userInfo)

    XCTAssertFalse(overlappingWakeHandled)
    XCTAssertNil(fixture.watchStore.savedStatus)
    notificationCenter.resumeDelivery()
    let firstWakeHandled = try await firstWake.value
    XCTAssertTrue(firstWakeHandled)
    XCTAssertEqual(
      notificationCenter.requests.map(\.identifier),
      [fixture.message.stableProviderMessageId]
    )
    XCTAssertEqual(fixture.watchStore.savedStatus?.latestSyncedHistoryId, "124")
  }

  func testCancelledOverlappingGmailWakeupReleasesMessageForRetry() async throws {
    let fixture = try gmailPushOverlapFixture()
    defer { fixture.cleanup() }
    let notificationCenter = SuspendingUserNotificationCenter()
    let handler = fixture.handler(notificationCenter: notificationCenter)
    let userInfo = fixture.userInfo()
    let firstWake = Task { try await handler.handle(userInfo: userInfo) }
    await notificationCenter.waitUntilDeliveryStarts()
    let overlappingWakeHandled = try await handler.handle(userInfo: userInfo)
    XCTAssertFalse(overlappingWakeHandled)
    notificationCenter.failDelivery(with: CancellationError())
    do {
      _ = try await firstWake.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    XCTAssertNil(fixture.watchStore.savedStatus)

    let retryCenter = RecordingUserNotificationCenter()
    let retryHandler = fixture.handler(notificationCenter: retryCenter)
    let retryHandled = try await retryHandler.handle(userInfo: userInfo)
    XCTAssertTrue(retryHandled)
    XCTAssertEqual(retryCenter.request?.identifier, fixture.message.stableProviderMessageId)
    XCTAssertEqual(fixture.watchStore.savedStatus?.latestSyncedHistoryId, "124")
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

  private func pushMessage(categoryId: String?) -> GmailMessageMetadata {
    GmailMessageMetadata(
      categoryId: categoryId,
      from: "Airline <updates@example.com>",
      isHistorical: false,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      providerInternalDateMilliseconds: 1_781_300_000_000,
      providerMessageId: "message-001",
      providerThreadId: "thread-001",
      replyTo: nil,
      snippet: "Your itinerary is ready",
      stableProviderMessageId: "gmail:gmail-user-001:message-001",
      subject: "Flight confirmation",
      rfcMessageId: "<message-001@example.com>"
    )
  }

  private func gmailPushOverlapFixture() throws -> GmailPushOverlapFixture {
    try GmailPushOverlapFixture(
      connection: connection,
      message: pushMessage(categoryId: "system:flights"),
      session: session
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
    self.status = status
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
  var existingMessages: [GmailMessageMetadata] = []
  var historyIsExpired = false
  var onSync: (() -> Void)?
  var shouldPersist: Bool?
  var sinceHistoryId: String?
  var syncedMessages: [GmailMessageMetadata] = []
  var hasUnlistedNewMessages = false
  var includesHistoryCandidates: Bool?
  var newMessageIds: Set<String>?
  var syncedConnection: GmailProviderConnectionStatus?
  var syncedSession: ProductAccountSessionSnapshot?
  var syncError: Error?
  var usesUnavailableHistoryDelta = false

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
    GmailMetadataSyncResult(messages: existingMessages, threads: [])
  }

  func syncInbox(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    throw GmailPushRelayTestError.unexpectedCall
  }

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection: GmailProviderConnectionStatus,
    includingHistoryCandidates: Bool,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId: String?,
    throughHistoryId _: String?,
    shouldPersist: @escaping () -> Bool
  ) async throws -> GmailMetadataSyncResult {
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
    )
  }

  func overrideCategory(
    _: String,
    for _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
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
  private(set) var requests: [UNNotificationRequest] = []

  func add(_ request: UNNotificationRequest) async throws {
    requests.append(request)
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
    guard deliveryContinuation == nil else { return }
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
