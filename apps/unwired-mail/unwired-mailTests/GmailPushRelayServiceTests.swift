import Foundation
import Testing
import UserNotifications

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

private final class GmailPushURLStub: URLProtocolStub {}

@MainActor
@Suite(.serialized)
final class GmailPushRelayServiceTests {
  @Test
  func testBackgroundRevalidationInvalidatesStructuredRevocation() async {
    let activeSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: session.appleUserIdentifier,
      identityToken: session.identityToken,
      identityTokenExpiresAt: Date(timeIntervalSinceNow: 60),
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )
    var revokedSessions: [ProductAccountSessionSnapshot] = []
    let revalidator = BackgroundTrustedDeviceRevalidator(
      productAccountService: RevokedBackgroundProductAccountService(),
      trustedDeviceRevoked: { revokedSessions.append($0) }
    )

    let revalidated = await revalidator.revalidate(activeSession)

    #expect(!(revalidated))
    #expect(revokedSessions == [activeSession])
  }

  @Test
  func testGmailPushWakeupStopsBeforeProviderAccessWhenTrustRevalidationFails() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    var revalidationCount = 0
    let handler = GmailPushWakeupHandler(
      revalidateTrustedDevice: { _ in
        revalidationCount += 1
        return false
      },
      sessionStore: sessionStore
    )

    let handled = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    #expect(!(handled))
    #expect(revalidationCount == 1)
  }

  @Test
  func testAppPermitsMailRefreshBackgroundTask() throws {
    let identifiers = try requireValue(
      Bundle(for: PushNotificationAppDelegate.self)
        .object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers")
        as? [String])

    #expect(identifiers.contains(MailRefreshBackgroundTask.identifier))
  }

  @Test
  func testMailRefreshTaskReschedulesAndCompletesSuccessfulRenewal() async {
    var didReschedule = false
    var completion: Bool?

    let task = MailRefreshBackgroundTask.run(
      reschedule: { didReschedule = true },
      renewal: {},
      completion: { completion = $0 },
      installExpirationHandler: { _ in }
    )
    await task.value

    #expect(didReschedule)
    #expect(completion == true)
  }

  @Test
  func testMailRefreshTaskReportsRenewalFailure() async {
    var completion: Bool?

    let task = MailRefreshBackgroundTask.run(
      reschedule: {},
      renewal: { throw URLError(.cannotConnectToHost) },
      completion: { completion = $0 },
      installExpirationHandler: { _ in }
    )
    await task.value

    #expect(completion == false)
  }

  @Test
  func testMailRefreshTaskExpirationCancelsRenewal() async {
    let renewalStarted = expectation(description: "Renewal started")
    var expirationHandler: (() -> Void)?
    var didCancel = false
    var completion: Bool?

    let task = MailRefreshBackgroundTask.run(
      reschedule: {},
      renewal: {
        renewalStarted.fulfill()
        do {
          try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
          didCancel = true
          throw CancellationError()
        }
      },
      completion: { completion = $0 },
      installExpirationHandler: { expirationHandler = $0 }
    )
    await fulfillment(of: [renewalStarted])
    expirationHandler?()
    await task.value

    #expect(didCancel)
    #expect(completion == false)
  }

  @Test
  func testGmailPushWakeupCoordinatorCancelsAndDrainsAccountWork() async {
    let coordinator = GmailPushWakeupCoordinator()
    let wakeupStarted = expectation(description: "Gmail push wakeup started")
    let otherWakeupStarted = expectation(description: "Other Gmail push wakeup started")
    var didCancel = false
    var didCancelOther = false
    let wakeup = Task {
      try await coordinator.handle(productAccountId: "account-a") {
        wakeupStarted.fulfill()
        do {
          try await Task.sleep(for: .seconds(60))
          return true
        } catch is CancellationError {
          didCancel = true
          throw CancellationError()
        }
      }
    }
    let otherWakeup = Task {
      try await coordinator.handle(productAccountId: "account-b") {
        otherWakeupStarted.fulfill()
        do {
          try await Task.sleep(for: .seconds(60))
          return true
        } catch is CancellationError {
          didCancelOther = true
          throw CancellationError()
        }
      }
    }
    await fulfillment(of: [wakeupStarted, otherWakeupStarted])

    await coordinator.cancelAndDrain(productAccountId: "account-a")

    do {
      _ = try await wakeup.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {} catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(didCancel)
    #expect(!(didCancelOther))
    coordinator.finishDraining(productAccountId: "account-a")
    await coordinator.cancelAndDrain(productAccountId: "account-b")
    _ = try? await otherWakeup.value
    coordinator.finishDraining(productAccountId: "account-b")
  }

  @Test
  func testGmailPushWakeupCoordinatorRejectsNewWorkUntilDrainFinishes() async {
    let coordinator = GmailPushWakeupCoordinator()
    let wakeupStarted = expectation(description: "Gmail push wakeup started")
    let cancelledWakeupHold = TestRendezvous()
    let wakeup = Task {
      try await coordinator.handle(productAccountId: "account-a") {
        wakeupStarted.fulfill()
        do {
          try await Task.sleep(for: .seconds(60))
          return true
        } catch is CancellationError {
          await cancelledWakeupHold.hold()
          throw CancellationError()
        }
      }
    }
    await fulfillment(of: [wakeupStarted])
    let drain = Task { await coordinator.cancelAndDrain(productAccountId: "account-a") }
    await cancelledWakeupHold.waitUntilHeld()

    var lateWakeupStarted = false
    do {
      _ = try await coordinator.handle(productAccountId: "account-a") {
        lateWakeupStarted = true
        return true
      }
      Issue.record("Expected draining account to reject new work")
    } catch is CancellationError {} catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(!(lateWakeupStarted))
    await cancelledWakeupHold.release()
    await drain.value
    _ = try? await wakeup.value

    coordinator.finishDraining(productAccountId: "account-a")
    let handledAfterDrain = try? await coordinator.handle(productAccountId: "account-a") { true }
    #expect(handledAfterDrain == true)
  }

  @Test
  func testMailRefreshTaskExpirationBeforeStartSkipsRenewal() async {
    var didRenew = false
    var completion: Bool?

    let task = MailRefreshBackgroundTask.run(
      reschedule: {},
      renewal: { didRenew = true },
      completion: { completion = $0 },
      installExpirationHandler: { $0() }
    )
    await task.value

    #expect(!(didRenew))
    #expect(completion == false)
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

  @Test
  // swiftlint:disable:next function_body_length
  func testTokenRefresherRenewsExpiredAccessTokenFromDeviceHeldRefreshToken() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "expired-access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let requestSession = ConvexClientTesting.makeSession(
      protocolClass: GmailPushURLStub.self
    ) { request in
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

    #expect(
      tokens
        == GmailProviderTokens(
          accessToken: "refreshed-access-token",
          refreshToken: "refresh-token",
          idToken: "gmail-identity-token"
        ))
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == tokens)
  }

  @Test
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
    let requestSession = ConvexClientTesting.makeSession(
      protocolClass: GmailPushURLStub.self
    ) { request in
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

    #expect(recordedAuthorization == "Bearer refreshed-access-token")
    #expect(recordedBody?["topicName"] as? String == "projects/private-email/topics/gmail-push")
    #expect(recordedBody?["labelIds"] as? [String] == ["INBOX"])
    #expect(recordedBody?["labelFilterBehavior"] as? String == "include")
    #expect(status.historyId == "history-123")
    #expect(status.routeId == "route-001")
    #expect(watchStore.savedStatus == status)
    #expect(tokenRefresher.connection == connection)
    #expect(tokenRefresher.session == session)
    #expect(connectionStore.savedConnection == connection)
    #expect(connectionStore.productAccountId == session.productAccountId)
    #expect(verificationTransport.gmailIdentityToken == "gmail-identity-token")
    #expect(verificationTransport.historyId == "history-123")
    #expect(verificationTransport.session == session)
  }

  @Test
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
    var recordedAuthorization: String?
    let requestSession = ConvexClientTesting.makeSession(
      protocolClass: GmailPushURLStub.self
    ) { request in
      recordedAuthorization = request.value(forHTTPHeaderField: "Authorization")
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

    #expect(recordedAuthorization == "Bearer fresh-access-token")
    #expect(status.historyId == "history-renewed")
    #expect(status.latestSyncedHistoryId == "history-synced")
  }

  @Test
  func testRegisterOrRenewWatchKeepsWatchWithMoreThanOneDayRemaining() async throws {
    let existing = GmailPushWatchStatus(
      expirationMilliseconds: 1_781_400_000_000,
      historyId: "history-existing"
    )
    let watchStore = RecordingGmailPushWatchStore(status: existing)
    var transportedRequest: URLRequest?
    let service = GmailPushWatchService(
      nowMilliseconds: { 1_781_200_000_000 },
      session: ConvexClientTesting.makeSession(
        protocolClass: GmailPushURLStub.self
      ) { request in
        transportedRequest = request
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

    #expect(transportedRequest == nil)
    #expect(
      status
        == GmailPushWatchStatus(
          expirationMilliseconds: existing.expirationMilliseconds,
          historyId: existing.historyId,
          routeId: "route-001"
        ))
  }

  @Test
  func testRegisterOrRenewWatchReplacesUnverifiedCachedWatch() async throws {
    let existing = GmailPushWatchStatus(
      expirationMilliseconds: 1_781_400_000_000,
      historyId: "history-existing"
    )
    var recordedPath: String?
    let requestSession = ConvexClientTesting.makeSession(
      protocolClass: GmailPushURLStub.self
    ) { request in
      recordedPath = request.url?.path
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

    #expect(recordedPath == "/gmail/v1/users/me/watch")
    #expect(status.historyId == "history-renewed")
  }

  @Test
  func testRegisterOrRenewWatchPersistsConnectionBeforeVerification() async throws {
    let connectionStore = RecordingGmailPushConnectionStore()
    let service = GmailPushWatchService(
      connectionStore: connectionStore,
      nowMilliseconds: { 1_781_200_000_000 },
      session: ConvexClientTesting.makeSession(
        protocolClass: GmailPushURLStub.self
      ) { request in
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
      Issue.record("Expected watch verification to fail")
    } catch {
    }

    #expect(connectionStore.savedConnection == connection)
    #expect(connectionStore.productAccountId == session.productAccountId)
  }

  @Test
  func testStopWatchUsesDeviceHeldToken() async throws {
    let tokenRefresher = RecordingGmailPushTokenRefresher(
      tokens: GmailProviderTokens(
        accessToken: "refreshed-access-token",
        refreshToken: "refresh-token"
      )
    )
    var recordedRequest: URLRequest?
    let requestSession = ConvexClientTesting.makeSession(
      protocolClass: GmailPushURLStub.self
    ) { request in
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

    #expect(recordedRequest?.url?.path == "/gmail/v1/users/me/stop")
    #expect(recordedRequest?.httpMethod == "POST")
    #expect(
      recordedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-access-token"
    )
    #expect(tokenRefresher.connection == connection)
    #expect(tokenRefresher.session == session)
  }

  @Test
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

    #expect(
      transport.call
        == DevicePushRegistrationCall(
          apnsEnvironment: "sandbox",
          apnsToken: "01abff",
          identityToken: session.identityToken,
          trustedDeviceId: session.trustedDeviceId
        ))
  }

  @Test
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
      Issue.record("Expected registration failure")
    } catch GmailPushRelayTestError.unexpectedCall {
    }

    transport.registerError = nil
    try await retrier.retry(session: session)

    #expect(transport.calls.count == 2)
    #expect(transport.calls.last?.apnsToken == "01abff")
  }

  @Test
  func testUnregisterDeviceClearsBackendRoutingForSignedOutSession() async throws {
    let transport = RecordingDevicePushRegistrationTransport()
    let service = DevicePushUnregistrationService(transport: transport)

    try await service.unregister(session: session)

    #expect(transport.unregisteredSession == session)
  }

  @Test
  func testPushConnectionStoreRecordsLegacyOwnershipForScopedConnection() throws {
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
    let legacyJSON = try requireValue(
      String(data: JSONEncoder().encode(connection), encoding: .utf8))
    let ownershipStore = InMemoryLegacyWatchOwnerStore()
    let store = KeychainGmailPushConnectionStore(
      legacyWatchOwnershipStore: ownershipStore
    )
    defer {
      try? store.clearAll(productAccountId: productAccountId)
      try? KeychainStore.delete(service: service, account: legacyAccount)
    }
    try store.save(current, productAccountId: productAccountId)
    try KeychainStore.writeString(legacyJSON, service: service, account: legacyAccount)

    #expect(try store.loadAll(productAccountId: productAccountId) == [current])
    #expect(
      try ownershipStore.load(productAccountId: productAccountId)
        == connection.providerAccountIdentifier)
    #expect(try KeychainStore.readString(service: service, account: legacyAccount) == nil)
  }

  @Test
  func testPushConnectionStoreClearRemovesMatchingLegacyDuplicate() throws {
    let productAccountId = "\(session.productAccountId)-\(UUID().uuidString)"
    let service = "private-email.gmail-push-connection"
    let legacyAccount =
      "gmail-push-connection.\(legacyGmailSafeFileComponent(productAccountId))"
    let legacyJSON = try requireValue(
      String(data: JSONEncoder().encode(connection), encoding: .utf8))
    let store = KeychainGmailPushConnectionStore()
    defer { try? store.clearAll(productAccountId: productAccountId) }
    try store.save(connection, productAccountId: productAccountId)
    try KeychainStore.writeString(legacyJSON, service: service, account: legacyAccount)

    try store.clear(
      productAccountId: productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    #expect(try KeychainStore.readString(service: service, account: legacyAccount) == nil)
    #expect(try store.loadAll(productAccountId: productAccountId).isEmpty)
  }

  @Test
  func testPushConnectionStoreMigratesLegacyConnectionWithoutManifest() throws {
    let productAccountId = "\(session.productAccountId)-\(UUID().uuidString)"
    let service = "private-email.gmail-push-connection"
    let legacyAccount =
      "gmail-push-connection.\(legacyGmailSafeFileComponent(productAccountId))"
    let legacyJSON = try requireValue(
      String(data: JSONEncoder().encode(connection), encoding: .utf8))
    let ownershipStore = InMemoryLegacyWatchOwnerStore()
    let store = KeychainGmailPushConnectionStore(
      legacyWatchOwnershipStore: ownershipStore
    )
    defer { try? store.clearAll(productAccountId: productAccountId) }
    try KeychainStore.writeString(legacyJSON, service: service, account: legacyAccount)

    #expect(try store.loadAll(productAccountId: productAccountId) == [connection])
    #expect(
      try ownershipStore.load(productAccountId: productAccountId)
        == connection.providerAccountIdentifier)
    #expect(
      try store.load(
        productAccountId: productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == connection)
    #expect(try KeychainStore.readString(service: service, account: legacyAccount) == nil)
  }

  @Test
  func testPushConnectionStoreTargetedLoadMigratesMatchingLegacyConnection() throws {
    let productAccountId = "\(session.productAccountId)-\(UUID().uuidString)"
    let service = "private-email.gmail-push-connection"
    let legacyAccount =
      "gmail-push-connection.\(legacyGmailSafeFileComponent(productAccountId))"
    let legacyJSON = try requireValue(
      String(data: JSONEncoder().encode(connection), encoding: .utf8))
    let ownershipStore = InMemoryLegacyWatchOwnerStore()
    let store = KeychainGmailPushConnectionStore(
      legacyWatchOwnershipStore: ownershipStore
    )
    defer { try? store.clearAll(productAccountId: productAccountId) }
    try KeychainStore.writeString(legacyJSON, service: service, account: legacyAccount)

    #expect(
      try store.load(
        productAccountId: productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == connection)
    #expect(
      try ownershipStore.load(productAccountId: productAccountId)
        == connection.providerAccountIdentifier)
    #expect(try KeychainStore.readString(service: service, account: legacyAccount) == nil)
  }

  @Test
  func testPushConnectionStoreMigratesLegacyConnectionWithStaleManifestEntry() throws {
    let productAccountId = "\(session.productAccountId)-\(UUID().uuidString)"
    let service = "private-email.gmail-push-connection"
    let safeProductAccountId = gmailSafeFileComponent(productAccountId)
    let legacyAccount =
      "gmail-push-connection.\(legacyGmailSafeFileComponent(productAccountId))"
    let manifestAccount = "gmail-push-connections.\(safeProductAccountId)"
    let scopedAccount =
      "gmail-push-connection.\(safeProductAccountId)."
      + gmailSafeFileComponent(connection.providerAccountIdentifier)
    let legacyJSON = try requireValue(
      String(data: JSONEncoder().encode(connection), encoding: .utf8))
    let manifestJSON = try requireValue(
      String(
        data: JSONEncoder().encode([connection.providerAccountIdentifier]),
        encoding: .utf8
      ))
    let store = KeychainGmailPushConnectionStore()
    defer { try? store.clearAll(productAccountId: productAccountId) }
    try KeychainStore.writeString(legacyJSON, service: service, account: legacyAccount)
    try KeychainStore.writeString(manifestJSON, service: service, account: manifestAccount)

    #expect(try store.loadAll(productAccountId: productAccountId) == [connection])
    #expect(try KeychainStore.readString(service: service, account: scopedAccount) != nil)
    #expect(try KeychainStore.readString(service: service, account: legacyAccount) == nil)
  }

  @Test
  func testPushConnectionStoreLoadsValidConnectionsPastUnreadableScopedConnection() throws {
    let productAccountId = "\(session.productAccountId)-\(UUID().uuidString)"
    let service = "private-email.gmail-push-connection"
    let validConnection = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: "valid@example.com",
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: "gmail-user-valid",
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
    let scopedAccount =
      "gmail-push-connection.\(gmailSafeFileComponent(productAccountId))."
      + gmailSafeFileComponent(connection.providerAccountIdentifier)
    let store = KeychainGmailPushConnectionStore()
    defer { try? store.clearAll(productAccountId: productAccountId) }
    try store.save(connection, productAccountId: productAccountId)
    try store.save(validConnection, productAccountId: productAccountId)
    try KeychainStore.writeString("not-json", service: service, account: scopedAccount)

    #expect(try store.loadAll(productAccountId: productAccountId) == [validConnection])
    #expect(try KeychainStore.readString(service: service, account: scopedAccount) == "not-json")
  }

  @Test
  func testPushConnectionStoreClearScopedDeletesUnreadableLegacyConnection() throws {
    let productAccountId = "\(session.productAccountId)-\(UUID().uuidString)"
    let service = "private-email.gmail-push-connection"
    let legacyAccount =
      "gmail-push-connection.\(legacyGmailSafeFileComponent(productAccountId))"
    let store = KeychainGmailPushConnectionStore()
    defer { try? store.clearAll(productAccountId: productAccountId) }
    try KeychainStore.writeString("not-json", service: service, account: legacyAccount)

    try store.clearScoped(productAccountId: productAccountId)

    #expect(try KeychainStore.readString(service: service, account: legacyAccount) == nil)
  }

  @Test
  func testPushConnectionStoreClearScopedPreservesLegacyConnection() throws {
    let productAccountId = "\(session.productAccountId)-\(UUID().uuidString)"
    let service = "private-email.gmail-push-connection"
    let safeProductAccountId = gmailSafeFileComponent(productAccountId)
    let legacyAccount =
      "gmail-push-connection.\(legacyGmailSafeFileComponent(productAccountId))"
    let scopedAccount =
      "gmail-push-connection.\(safeProductAccountId)."
      + gmailSafeFileComponent(connection.providerAccountIdentifier)
    let legacyJSON = try requireValue(
      String(data: JSONEncoder().encode(connection), encoding: .utf8))
    let store = KeychainGmailPushConnectionStore()
    defer { try? store.clearAll(productAccountId: productAccountId) }
    try store.save(connection, productAccountId: productAccountId)
    try KeychainStore.writeString(legacyJSON, service: service, account: legacyAccount)

    try store.clearScoped(productAccountId: productAccountId)

    #expect(try KeychainStore.readString(service: service, account: scopedAccount) == nil)
    #expect(try KeychainStore.readString(service: service, account: legacyAccount) == legacyJSON)
  }

  @Test
  func testPushConnectionStoreClearScopedPreservesLegacyEvidenceOnKeychainFailure() throws {
    let productAccountId = "\(session.productAccountId)-\(UUID().uuidString)"
    let transientStatus: Int32 = -25_308
    let ownershipStore = InMemoryLegacyWatchOwnerStore()
    try ownershipStore.save(
      providerAccountIdentifier: connection.providerAccountIdentifier,
      productAccountId: productAccountId
    )
    let store = KeychainGmailPushConnectionStore(
      legacyWatchOwnershipStore: ownershipStore,
      readString: { _, account in
        if account.hasPrefix("gmail-push-connections.") { return nil }
        throw KeychainStoreError.unhandledStatus(transientStatus)
      }
    )

    #expect {
      try store.clearScoped(productAccountId: productAccountId)
    } throws: { error in
      #expect(error as? KeychainStoreError == .unhandledStatus(transientStatus))
      return true
    }
    #expect(
      try ownershipStore.load(productAccountId: productAccountId)
        == connection.providerAccountIdentifier)
  }

  @Test
  func testNotificationStoresPreserveLegacyStateForAnotherMailbox() throws {
    let suiteName = "PushNotificationMigrationTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: suiteName))
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

    #expect(
      try claimAndReleaseReceipt(
        pushMessage(categoryId: nil),
        from: receiptStore
      ) == .claimed)
    #expect(
      try eligibilityStore.eligibleStableMessageIds(
        after: "123",
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ).isEmpty)
    #expect(defaults.object(forKey: receiptKey) != nil)
    #expect(defaults.object(forKey: eligibilityKey) != nil)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testPushWatchStoreLeavesUnownedLegacyStatusUntouchedForCollidingIdentities() throws {
    let suiteName = "PushWatchStoreTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: suiteName))
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
    let legacyData = try JSONEncoder().encode(first)
    defaults.set(legacyData, forKey: legacyKey)
    let ownershipStore = InMemoryLegacyWatchOwnerStore()
    let store = UserDefaultsGmailPushWatchStore(
      defaults: defaults,
      legacyOwnershipStore: ownershipStore
    )

    #expect(
      try store.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: secondIdentifier
      ) == nil)
    #expect(
      try store.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: firstIdentifier
      ) == nil)
    #expect(defaults.data(forKey: legacyKey) == legacyData)
    try store.save(
      second,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: secondIdentifier
    )
    try store.clear(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: firstIdentifier
    )

    #expect(
      try store.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: firstIdentifier
      ) == nil)
    #expect(
      try store.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: secondIdentifier
      ) == second)
    #expect(defaults.data(forKey: legacyKey) == legacyData)
  }

  @Test
  func testPushWatchStoreMigratesLegacyStatusOnlyForVerifiedOwner() throws {
    let suiteName = "PushWatchStoreTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let status = GmailPushWatchStatus(
      expirationMilliseconds: 100,
      historyId: "10",
      routeId: "route-001"
    )
    let providerAccountIdentifier = "gmail/user"
    let legacyKey =
      "gmail-push-watch.\(legacyGmailSafeFileComponent(session.productAccountId))."
      + legacyGmailSafeFileComponent(providerAccountIdentifier)
    defaults.set(try JSONEncoder().encode(status), forKey: legacyKey)
    let ownershipStore = InMemoryLegacyWatchOwnerStore()
    try ownershipStore.save(
      providerAccountIdentifier: providerAccountIdentifier,
      productAccountId: session.productAccountId
    )
    let store = UserDefaultsGmailPushWatchStore(
      defaults: defaults,
      legacyOwnershipStore: ownershipStore
    )

    #expect(
      try store.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      ) == status)
    #expect(defaults.data(forKey: legacyKey) == nil)
    #expect(try ownershipStore.load(productAccountId: session.productAccountId) == nil)
    #expect(
      try store.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      ) == status)
  }

  @Test
  func testPushWatchStoreClearAllPreservesUnverifiedLegacyStatus() throws {
    let suiteName = "PushWatchStoreTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let providerAccountIdentifier = "gmail/user"
    let legacyKey =
      "gmail-push-watch.\(legacyGmailSafeFileComponent(session.productAccountId))."
      + legacyGmailSafeFileComponent(providerAccountIdentifier)
    let legacyData = try JSONEncoder().encode(
      GmailPushWatchStatus(expirationMilliseconds: 100, historyId: "10")
    )
    defaults.set(legacyData, forKey: legacyKey)
    let store = UserDefaultsGmailPushWatchStore(
      defaults: defaults,
      legacyOwnershipStore: InMemoryLegacyWatchOwnerStore()
    )

    try store.clearAll(productAccountId: session.productAccountId)

    #expect(defaults.data(forKey: legacyKey) == legacyData)
  }

  @Test
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

    #expect(defaults.object(forKey: "\(receiptPrefix)\(currentSuffix)") == nil)
    #expect(defaults.object(forKey: "\(eligibilityPrefix)\(currentSuffix)") == nil)
    #expect(defaults.stringArray(forKey: "\(receiptPrefix)\(legacySuffix)") == ["legacy"])
    #expect(defaults.data(forKey: "\(eligibilityPrefix)\(legacySuffix)") == Data("legacy".utf8))
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testGmailWakeupFetchesMailboxChangesThroughDeviceSyncService() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let connectionStore = RecordingGmailPushConnectionStore(connection: connection)
    let syncService = RecordingPushGmailMetadataSyncService()
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let suiteName = "MailboxSyncSuccessStoreTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: suiteName))
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
    let preemptionPublished = expectation(description: "push preemption status published")
    let statusPublished = expectation(description: "push sync status published")
    let observer = NotificationCenter.default.addObserver(
      forName: .mailboxMetadataDidSynchronize,
      object: nil,
      queue: .main
    ) { notification in
      guard
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.connectionId]
          as? String == mailboxConnection.id.rawValue
      else { return }
      let phase =
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.phase]
        as? MailboxSyncPhase
      if phase == .syncing,
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.supersedesHistoricalBackfill]
          as? Bool == true
      {
        preemptionPublished.fulfill()
      } else if phase == .idle,
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.successfulSyncAt] is Date
      {
        statusPublished.fulfill()
      }
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
    await fulfillment(of: [preemptionPublished, statusPublished], timeout: 1)

    #expect(handled)
    #expect(connectionStore.loadedProductAccountId == session.productAccountId)
    #expect(syncService.syncedConnection == mailboxConnection)
    #expect(syncService.syncedSession == session)
    #expect(syncService.sinceHistoryId == "123")
    #expect(
      successStore.load(
        productAccountId: session.productAccountId,
        connectionId: mailboxConnection.id
      ) != nil)
    #expect(
      watchStore.savedStatus
        == GmailPushWatchStatus(
          expirationMilliseconds: 1_781_400_000_000,
          historyId: "123",
          latestSyncedHistoryId: "124",
          routeId: "route-001"
        ))
  }

  @Test
  func testGmailWakeupRejectsTokenlessConnectionBeforeMailboxSync() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.localAuthorizationAvailable = false
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
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

    #expect(!(handled))
    #expect(syncService.syncedConnection == nil)
  }

  @Test
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

    #expect(handled)
    #expect(
      syncService.syncedConnection
        == second.mailboxConnection(
          productAccountId: session.productAccountId, authorizationState: .authorized))
    #expect(syncService.sinceHistoryId == "456")
  }

  @Test
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

    #expect(handled)
    #expect(
      syncService.syncedConnection
        == second.mailboxConnection(
          productAccountId: session.productAccountId, authorizationState: .authorized))
  }

  @Test
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

    #expect(handled)
    #expect(notificationDelivery.messages == [message])
  }

  @Test
  func testGmailWakeupQuietProfileSuppressesNotificationButCompletesMailSync() async throws {
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
      notificationSuppressionResolver: StubMailProfileNotificationGate(
        isSuppressed: true
      ),
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

    #expect(handled)
    #expect(syncService.syncedConnection != nil)
    #expect(notificationDelivery.messages.isEmpty)
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "124")
  }

  @Test
  func testGmailWakeupResolvesNotificationSuppressionOncePerExpiredHistoryWake() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.historyIsExpired = true
    let notificationDelivery = RecordingNotificationDelivery()
    let suppressionResolver = StubMailProfileNotificationGate(isSuppressed: false)
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      genericNotificationFallbackStore: StubGenericNotificationFallbackStore(isEnabled: true),
      notificationDelivery: notificationDelivery,
      notificationSuppressionResolver: suppressionResolver,
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

    #expect(suppressionResolver.invocationCount == 1)
    #expect(notificationDelivery.genericNotificationIdentifiers.count == 1)
  }

  @Test
  func testGmailWakeupSuppressionFailureFailsClosedAndAdvancesExpiredHistory() async throws {
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
      notificationSuppressionResolver: StubMailProfileNotificationGate(
        error: StubMailProfileNotificationGateError.unavailable
      ),
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    _ = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    #expect(notificationDelivery.messages.isEmpty)
    #expect(notificationDelivery.genericNotificationIdentifiers.isEmpty)
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "124")
  }

  @Test
  func testGmailWakeupSuppressedExpiredHistoryAdvancesWithoutFallback() async throws {
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
      notificationSuppressionResolver: StubMailProfileNotificationGate(isSuppressed: true),
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    _ = try await handler.handle(userInfo: [
      "historyId": "124",
      "provider": "gmail",
      "routeId": "route-001",
    ])

    #expect(notificationDelivery.genericNotificationIdentifiers.isEmpty)
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "124")
  }

  @Test
  func testGmailWakeupSuppressionCancellationAbortsWithoutAdvancingWatermark() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.historyIsExpired = true
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
      notificationSuppressionResolver: StubMailProfileNotificationGate(error: CancellationError()),
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      sessionStore: sessionStore,
      syncService: syncService,
      watchStore: watchStore
    )

    await #expect(throws: CancellationError.self) {
      try await handler.handle(userInfo: [
        "historyId": "124",
        "provider": "gmail",
        "routeId": "route-001",
      ])
    }
    #expect(watchStore.savedStatus == nil)
  }

  @Test
  func testGmailWakeupHonorsDisabledConnectionOverride() async throws {
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
        rules: NotificationRules(
          isEnabled: true,
          categoryIds: ["system:flights"],
          connectionPolicies: [
            NotificationConnectionPolicy(
              connectionId: connection.mailboxConnectionId.rawValue,
              isEnabled: false,
              categoryIds: ["system:flights"]
            )
          ]
        )
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

    #expect(handled)
    #expect(notificationDelivery.messages.isEmpty)
  }

  @Test
  func testUnassignedConnectionUsesDefaultNotificationProfile() async throws {
    let defaultProfile = MailProfileDefinition.defaultProfile(
      productAccountId: session.productAccountId
    )
    let profile = try ProductSyncNotificationProfileResolver.profile(
      for: connection.mailboxConnectionId,
      in: MailProfileSyncSnapshot(
        assignments: [:],
        conflicts: [],
        defaultProfileId: defaultProfile.id,
        profiles: [defaultProfile],
        updatedAt: 1
      )
    )

    #expect(profile == defaultProfile)
  }

  @Test
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

    #expect(handled)
    #expect(notificationDelivery.messages == [message])
  }

  @Test
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

    #expect(handled)
    #expect(notificationDelivery.messages == [message.assigningCategory("system:flights")])
  }

  @Test
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

    #expect(handled)
    #expect(notificationDelivery.messages.isEmpty)
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "124")
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testGmailWakeupUsesProfilePolicyCurrentAfterInboxSync() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let message = pushMessage(categoryId: "system:flights")
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncedMessages = [message]
    syncService.newMessageIds = [message.providerMessageId]
    let notificationDelivery = RecordingNotificationDelivery()
    let profileId = MailProfileId(rawValue: "profile-work")
    let profileResolver = SequencedNotificationProfileResolver(
      resolutions: [
        NotificationProfileResolution(
          deliveryContext: NotificationDeliveryContext(
            connectionId: connection.mailboxConnectionId,
            isActiveProfile: true,
            isProfileQuiet: false,
            profileId: profileId,
            profileName: "Work"
          ),
          recordScope: .legacyProductAccount
        ),
        NotificationProfileResolution(
          deliveryContext: NotificationDeliveryContext(
            connectionId: connection.mailboxConnectionId,
            isActiveProfile: true,
            isProfileQuiet: true,
            profileId: profileId,
            profileName: "Work"
          ),
          recordScope: .legacyProductAccount
        ),
      ]
    )
    let handler = GmailPushWakeupHandler(
      connectionStore: RecordingGmailPushConnectionStore(connection: connection),
      notificationDelivery: notificationDelivery,
      notificationRuleSync: StubNotificationRuleSync(
        rules: NotificationRules(categoryIds: ["system:flights"])
      ),
      profileResolver: profileResolver,
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

    #expect(handled)
    #expect(notificationDelivery.messages.isEmpty)
    #expect(await profileResolver.resolveCount == 2)
  }

  @Test
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

    #expect(notificationDelivery.messages == [message])
  }

  @Test
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

    #expect(handled)
    #expect(notificationDelivery.messages.isEmpty)
  }

  @Test
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

    #expect(handled)
    #expect(notificationDelivery.messages.isEmpty)
    #expect(notificationDelivery.genericNotificationIdentifiers.count == 1)
    #expect(notificationDelivery.productAccountIds == [session.productAccountId])
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "124")
  }

  @Test
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

    #expect(handled)
    #expect(notificationDelivery.messages.isEmpty)
  }

  @Test
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

    #expect(handled)
    #expect(notificationDelivery.genericNotificationIdentifiers.count == 1)
  }

  @Test
  func testGmailWakeupShowsEnabledGenericFallbackWhenHistoryIsExpired() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.historyIsExpired = true
    let notificationDelivery = RecordingNotificationDelivery()
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId, authorizationState: .authorized)
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
    #expect(!(handled))
    #expect(notificationDelivery.genericNotificationIdentifiers.count == 1)
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "124")
  }

  @Test
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

    #expect(!(handled))
    #expect(notificationDelivery.messages.isEmpty)
    #expect(watchStore.savedStatus == nil)
  }

  @Test
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

    #expect(handled)
    #expect(notificationDelivery.genericNotificationIdentifiers.count == 1)
  }

  @Test
  func testGmailWakeupRejectsStaleGenerationBeforeBackgroundDeadlineFallback() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let notificationDelivery = RecordingNotificationDelivery()
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.localAuthorizationAvailable = false
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

    #expect(!(handled))
    #expect(notificationDelivery.genericNotificationIdentifiers.isEmpty)
    #expect(watchStore.clearedProductAccountId == session.productAccountId)
    #expect(watchStore.clearedProviderAccountIdentifier == connection.providerAccountIdentifier)
    #expect(watchStore.savedStatus == nil)
  }

  @Test
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

    #expect(!(handled))
    #expect(notificationDelivery.genericNotificationIdentifiers.isEmpty)
  }

  @Test
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

    #expect(handled)
    #expect(notificationDelivery.messages == [firstMessage])
    #expect(notificationDelivery.genericNotificationIdentifiers.count == 1)
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "124")
  }

  @Test
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

    #expect(!(handled))
    #expect(watchStore.savedStatus == nil)
    #expect(
      syncService.syncedConnection
        == connection.mailboxConnection(
          productAccountId: session.productAccountId, authorizationState: .authorized))
  }

  @Test
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

    #expect(!(handled))
    #expect(notificationDelivery.genericNotificationIdentifiers.isEmpty)
  }

  @Test
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

    #expect(!(handled))
    #expect(notificationDelivery.genericNotificationIdentifiers.count == 1)
    #expect(watchStore.savedStatus == nil)
  }

  @Test
  func testGmailWakeupClearsWatchWithoutFallbackWhenAuthorizationGenerationIsStale()
    async throws
  {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let syncService = RecordingPushGmailMetadataSyncService()
    syncService.syncError = MailboxConnectionAdapterError.authorizationRequired
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

    #expect(!(handled))
    #expect(notificationDelivery.genericNotificationIdentifiers.isEmpty)
    #expect(watchStore.clearedProductAccountId == session.productAccountId)
    #expect(watchStore.clearedProviderAccountIdentifier == connection.providerAccountIdentifier)
  }

  @Test
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
      Issue.record("Expected metadata sync failure")
    } catch {
      #expect(error is GmailPushRelayTestError)
    }
    #expect(notificationDelivery.genericNotificationIdentifiers.isEmpty)
    #expect(watchStore.savedStatus == nil)
  }

  @Test
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

    #expect(!(handled))
    #expect(notificationDelivery.genericNotificationIdentifiers.isEmpty)
    #expect(watchStore.savedStatus == nil)
  }

  @Test
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

    #expect(handled)
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "124")
    #expect(syncService.includesHistoryCandidates == false)
  }

  @Test
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

    #expect(!(handled))
    #expect(notificationDelivery.messages == [message])
    #expect(notificationDelivery.productAccountIds == [session.productAccountId])
    #expect(watchStore.savedStatus == nil)
  }

  @Test
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

    #expect(handled)
    #expect(notificationDelivery.messages == [message])
    #expect(notificationDelivery.genericNotificationIdentifiers.count == 1)
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "124")
  }

  @Test
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

    #expect(!(handled))
    #expect(receiptStore.receipts.isEmpty)
    #expect(watchStore.savedStatus == nil)
  }

  @Test
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

    #expect(handled)
    #expect(genericDelivery.genericNotificationIdentifiers.count == 1)
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "124")
  }

  @Test
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

    #expect(!(handled))
    #expect(watchStore.savedStatus == nil)
  }

  @Test
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

    #expect(handled)
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "124")
  }

  @Test
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

    #expect(handled)
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "124")
  }

  @Test
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

    #expect(!(handled))
    #expect(notificationDelivery.messages.count == 1)
    #expect(watchStore.savedStatus == nil)
  }

  @Test
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
    #expect(!(firstHandled))

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
    #expect(secondHandled)
    #expect(notificationDelivery.messages == messages)
    #expect(receiptStore.receipts == Set(messages.map(\.stableProviderMessageId)))
  }

  @Test
  func testUserNotificationServiceRequestsVisibleNotificationAuthorization() async throws {
    let center = RecordingUserNotificationCenter()
    let service = UserNotificationService(center: center)

    let granted = try await service.requestAuthorization()

    #expect(granted)
    #expect(center.authorizationOptions == [.alert, .badge, .sound])
  }

  @Test
  func testForegroundGenericFallbackUsesVisiblePresentationOptions() {
    let options = PushNotificationAppDelegate.foregroundPresentationOptions(userInfo: [:])

    #expect(options == [.banner, .badge, .sound])
  }

  @Test
  func testUserNotificationServiceClearsOnlyTheProductAccountsNotifications() {
    let center = RecordingUserNotificationCenter()
    let identifierStore = RecordingNotificationIdentifierStore()
    identifierStore.record(identifier: "account-a:message-001", productAccountId: "account-a")
    identifierStore.record(identifier: "account-b:message-002", productAccountId: "account-b")
    let service = UserNotificationService(center: center, identifierStore: identifierStore)

    service.clear(productAccountId: "account-a")

    #expect(center.removedPendingNotificationIdentifiers == ["account-a:message-001"])
    #expect(center.removedDeliveredNotificationIdentifiers == ["account-a:message-001"])
    #expect(identifierStore.identifiers(productAccountId: "account-a") == [])
    #expect(identifierStore.identifiers(productAccountId: "account-b") == ["account-b:message-002"])
  }

  @Test
  func testUserNotificationServiceMigratesPendingLegacyNotificationForCurrentProductAccount()
    async
  {
    let center = RecordingUserNotificationCenter()
    let identifierStore = RecordingNotificationIdentifierStore()
    let legacyRequest = UNNotificationRequest(
      identifier: "gmail:provider-a:message-001",
      content: UNMutableNotificationContent(),
      trigger: nil
    )
    let otherAccountRequest = UNNotificationRequest(
      identifier: "gmail:provider-b:message-002",
      content: UNMutableNotificationContent(),
      trigger: nil
    )
    center.pendingRequestsForOwnership = [legacyRequest, otherAccountRequest]
    identifierStore.record(
      identifier: otherAccountRequest.identifier,
      productAccountId: "account-b"
    )
    let service = UserNotificationService(center: center, identifierStore: identifierStore)

    await service.migrateLegacyIdentifiers(
      productAccountId: "account-a",
      gmailProviderAccountIdentifiers: ["provider-a"]
    )
    service.clear(productAccountId: "account-a")

    #expect(center.removedPendingNotificationIdentifiers == [legacyRequest.identifier])
    #expect(
      identifierStore.identifiers(productAccountId: "account-b")
        == [otherAccountRequest.identifier]
    )
  }

  @Test
  func testNotificationIdentifierStoreEnumeratesIdentifiersAcrossProductAccounts() throws {
    let suiteName = "NotificationIdentifierStoreTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsNotificationIdentifierStore(defaults: defaults)

    store.record(identifier: "gmail:provider-a:message-001", productAccountId: "account-a")
    store.record(identifier: "gmail:provider-b:message-002", productAccountId: "account-b")

    #expect(
      store.allIdentifiers()
        == ["gmail:provider-a:message-001", "gmail:provider-b:message-002"]
    )
  }

  @Test
  func testUserNotificationServiceLeavesLegacyFallbackWithoutProvenOwnership()
    async
  {
    let center = RecordingUserNotificationCenter()
    let legacyRequest = UNNotificationRequest(
      identifier: "gmail-generic-fallback:route-a:history-001",
      content: UNMutableNotificationContent(),
      trigger: nil
    )
    center.deliveredRequestsForOwnership = [legacyRequest]
    let service = UserNotificationService(
      center: center,
      identifierStore: RecordingNotificationIdentifierStore()
    )

    await service.migrateLegacyIdentifiers(
      productAccountId: "account-a",
      gmailProviderAccountIdentifiers: ["provider-a"]
    )
    service.clear(productAccountId: "account-a")

    #expect(center.removedDeliveredNotificationIdentifiers == [])
  }

  @Test
  func testUserNotificationServiceLeavesLegacyNotificationOwnedByAnotherProvider() async {
    let center = RecordingUserNotificationCenter()
    let legacyRequest = UNNotificationRequest(
      identifier: "gmail:provider-b:message-001",
      content: UNMutableNotificationContent(),
      trigger: nil
    )
    center.pendingRequestsForOwnership = [legacyRequest]
    let service = UserNotificationService(
      center: center,
      identifierStore: RecordingNotificationIdentifierStore()
    )

    await service.migrateLegacyIdentifiers(
      productAccountId: "account-a",
      gmailProviderAccountIdentifiers: ["provider-a"]
    )
    service.clear(productAccountId: "account-a")

    #expect(center.removedPendingNotificationIdentifiers == [])
  }

  @Test
  func testUserNotificationServiceBuildsPrivacyPreservingNotification() async throws {
    let center = RecordingUserNotificationCenter()
    let service = UserNotificationService(center: center)
    let message = pushMessage(categoryId: "system:flights")

    try await service.deliver(message: message, productAccountId: "account-a")

    let request = try requireValue(center.request)
    #expect(request.identifier == "account-a:\(message.stableProviderMessageId)")
    #expect(request.content.title == "New mail")
    #expect(request.content.body == "1 new message")
    #expect(!(request.content.body.contains(message.subject)))
    #expect(request.content.userInfo.isEmpty)
    #expect(request.trigger == nil)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testProfileAwareNotificationUsesDevicePresentationAndDeepLinkContext() async throws {
    let center = RecordingUserNotificationCenter()
    let preferences = RecordingNotificationPreferenceStore(
      preferences: NotificationDevicePreferences(
        isBadgeEnabled: false,
        isSoundEnabled: false,
        lockScreenContentLevel: .senderAndSubject
      )
    )
    let service = UserNotificationService(center: center, preferenceStore: preferences)
    let message = pushMessage(categoryId: "system:flights")
    let profileId = MailProfileId(rawValue: "profile-work")

    try await service.deliver(
      message: message,
      productAccountId: "account-a",
      context: NotificationDeliveryContext(
        connectionId: connection.mailboxConnectionId,
        isActiveProfile: false,
        isProfileQuiet: false,
        profileId: profileId,
        profileName: "Work"
      )
    )

    let request = try requireValue(center.request)
    #expect(request.content.title.contains("Airline <updates@example.com>"))
    #expect(request.content.title.contains("Work"))
    #expect(request.content.body == message.subject)
    #expect(request.content.sound == nil)
    #expect(request.content.badge == nil)
    #expect(
      request.content.userInfo[NotificationDeliveryContext.profileIdUserInfoKey] as? String
        == profileId.rawValue
    )
    #expect(
      request.content.userInfo[NotificationDeliveryContext.connectionIdUserInfoKey] as? String
        == connection.mailboxConnectionId.rawValue
    )
    #expect(
      request.content.userInfo[NotificationDeliveryContext.productAccountIdUserInfoKey] as? String
        == "account-a"
    )
    let deliveredDeepLink = try #require(
      NotificationDeepLink(userInfo: request.content.userInfo)
    )
    let expectedDeepLink = try #require(
      NotificationDeepLink(
        userInfo: [
          NotificationDeliveryContext.connectionIdUserInfoKey:
            connection.mailboxConnectionId.rawValue,
          NotificationDeliveryContext.productAccountIdUserInfoKey: "account-a",
          NotificationDeliveryContext.profileIdUserInfoKey: profileId.rawValue,
        ]
      )
    )
    #expect(deliveredDeepLink == expectedDeepLink)
    #expect(
      request.content.userInfo[
        NotificationDeliveryContext.settingsDestinationUserInfoKey
      ] as? String == "notifications"
    )
  }

  @Test
  func testPendingNotificationDeepLinkWaitsForMatchingAccount() throws {
    let store = PendingNotificationDeepLinkStore()
    let deepLink = try #require(
      NotificationDeepLink(
        userInfo: [
          NotificationDeliveryContext.connectionIdUserInfoKey:
            connection.mailboxConnectionId.rawValue,
          NotificationDeliveryContext.productAccountIdUserInfoKey: "account-a",
          NotificationDeliveryContext.profileIdUserInfoKey: "profile-work",
        ]
      )
    )

    store.remember(deepLink)

    #expect(store.take(productAccountId: "account-b") == nil)
    #expect(store.take(productAccountId: "account-a") == deepLink)
    #expect(store.take(productAccountId: "account-a") == nil)
  }

  @Test
  func testThreadSnoozeAttentionCarriesMailboxDeepLinkContext() async throws {
    let center = RecordingUserNotificationCenter()
    let service = UserNotificationService(center: center)
    let profileId = MailProfileId(rawValue: "profile-work")
    let threadId = StableThreadIdentity(
      connectionId: connection.mailboxConnectionId,
      providerThreadId: "thread-001"
    )
    let snooze = ThreadSnooze(
      anchorMessageId: StableProviderMessageIdentity(
        connectionId: connection.mailboxConnectionId,
        providerMessageId: "message-001"
      ),
      anchorReceivedAtMilliseconds: 1_781_200_000_000,
      dueAtMilliseconds: 1_781_286_400_000,
      notificationOwnerDeviceId: "trusted-device-001",
      profileId: profileId,
      threadId: threadId
    )

    try await service.deliverThreadSnoozeAttention(
      decision: .generic,
      snooze: snooze,
      productAccountId: "account-a"
    )

    let request = try requireValue(center.request)
    let deepLink = try #require(NotificationDeepLink(userInfo: request.content.userInfo))
    #expect(deepLink.connectionId == connection.mailboxConnectionId)
    #expect(deepLink.productAccountId == "account-a")
    #expect(deepLink.profileId == profileId)
  }

  @Test
  func testQuietProfileSuppressesVisibleNotification() async throws {
    let center = RecordingUserNotificationCenter()
    let service = UserNotificationService(center: center)

    try await service.deliver(
      message: pushMessage(categoryId: "system:flights"),
      productAccountId: "account-a",
      context: NotificationDeliveryContext(
        connectionId: connection.mailboxConnectionId,
        isActiveProfile: true,
        isProfileQuiet: true,
        profileId: .defaultProfile(productAccountId: "account-a"),
        profileName: "Default Profile"
      )
    )

    #expect(center.request == nil)
  }

  @Test
  func testCountOnlyPresentationDoesNotExposeInactiveProfileName() async throws {
    let center = RecordingUserNotificationCenter()
    let service = UserNotificationService(
      center: center,
      preferenceStore: RecordingNotificationPreferenceStore(
        preferences: NotificationDevicePreferences(lockScreenContentLevel: .countOnly)
      )
    )

    try await service.deliver(
      message: pushMessage(categoryId: "system:flights"),
      productAccountId: "account-a",
      context: NotificationDeliveryContext(
        connectionId: connection.mailboxConnectionId,
        isActiveProfile: false,
        isProfileQuiet: false,
        profileId: MailProfileId(rawValue: "profile-confidential"),
        profileName: "Confidential"
      )
    )

    let request = try requireValue(center.request)
    #expect(request.content.title == "New mail")
    #expect(request.content.body == "1 new message")
  }

  @Test
  func testUserNotificationServiceBuildsContentFreeGenericFallback() async throws {
    let center = RecordingUserNotificationCenter()
    let service = UserNotificationService(center: center)

    try await service.deliverGeneric(identifier: "generic-fallback", productAccountId: "account-a")

    let request = try requireValue(center.request)
    #expect(request.identifier == "account-a:generic-fallback")
    #expect(request.content.title == "New mail")
    #expect(request.content.body == "New mail is available.")
    #expect(request.content.userInfo.isEmpty)
    #expect(request.trigger == nil)
  }

  @Test
  func testGenericNotificationFallbackStoreIsDisabledByDefaultAndScopedToAccount() throws {
    let suiteName = "GenericNotificationFallbackTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsFallbackStore(defaults: defaults)

    #expect(!(store.isEnabled(productAccountId: "account-a")))
    #expect(!(store.isEnabled(productAccountId: "account-b")))

    store.setEnabled(true, productAccountId: "account-a")

    #expect(store.isEnabled(productAccountId: "account-a"))
    #expect(!(store.isEnabled(productAccountId: "account-b")))

    store.clear(productAccountId: "account-a")

    #expect(defaults.object(forKey: "generic-notification-fallback.account-a") == nil)
  }

  @Test
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

    #expect(!(handled))
    #expect(syncService.shouldPersist == false)
    #expect(watchStore.savedStatus == nil)
  }

  @Test
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

    #expect(!(handled))
    #expect(notificationDelivery.messages.count == 1)
    #expect(watchStore.savedStatus == nil)
  }

  @Test
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

    #expect(!(handled))
    #expect(notificationDelivery.messages == [firstMessage])
  }

  @Test
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

    #expect(handled)
    #expect(syncService.shouldPersist == true)
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "126")
  }

  @Test
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

    #expect(!(handled))
    #expect(notificationDelivery.messages.isEmpty)
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "126")
  }

  @Test
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

    #expect(!(handled))
    #expect(watchStore.savedStatus == nil)
  }

  @Test
  func testOverlappingGmailWakeupsDeliverMatchingMessageOnce() async throws {
    let overlappingWake = try await startOverlappingFirstWake()
    let fixture = overlappingWake.fixture
    defer { fixture.cleanup() }

    let overlappingWakeHandled = try await overlappingWake.handler.handle(
      userInfo: overlappingWake.userInfo
    )

    #expect(!(overlappingWakeHandled))
    #expect(fixture.watchStore.savedStatus == nil)
    overlappingWake.notificationCenter.resumeDelivery()
    let firstWakeHandled = try await overlappingWake.firstWake.value
    #expect(firstWakeHandled)
    #expect(
      overlappingWake.notificationCenter.requests.map(\.identifier) == [
        "\(session.productAccountId):\(fixture.message.stableProviderMessageId)"
      ])
    #expect(fixture.watchStore.savedStatus?.latestSyncedHistoryId == "124")
  }

  @Test
  func testCancelledOverlappingGmailWakeupReleasesMessageForRetry() async throws {
    let overlappingWake = try await startOverlappingFirstWake()
    let fixture = overlappingWake.fixture
    defer { fixture.cleanup() }

    let overlappingWakeHandled = try await overlappingWake.handler.handle(
      userInfo: overlappingWake.userInfo
    )
    #expect(!(overlappingWakeHandled))
    overlappingWake.notificationCenter.failDelivery(with: CancellationError())
    do {
      _ = try await overlappingWake.firstWake.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {}
    #expect(fixture.watchStore.savedStatus == nil)

    let retryCenter = RecordingUserNotificationCenter()
    let retryHandler = fixture.handler(notificationCenter: retryCenter)
    let retryHandled = try await retryHandler.handle(userInfo: overlappingWake.userInfo)
    #expect(retryHandled)
    #expect(
      retryCenter.request?.identifier
        == "\(session.productAccountId):\(fixture.message.stableProviderMessageId)")
    #expect(fixture.watchStore.savedStatus?.latestSyncedHistoryId == "124")
  }

  @Test
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

    #expect(handled)
    #expect(notificationDelivery.messages == [message])
    #expect(watchStore.savedStatus?.latestSyncedHistoryId == "124")
    #expect(
      try eligibilityStore.eligibleStableMessageIds(
        after: "124",
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ).isEmpty)
  }

  @Test
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

    #expect(!(handled))
    #expect(watchStore.savedStatus == nil)
  }

  @Test
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

    #expect(!(handled))
    #expect(notificationDelivery.messages == [message])
    #expect(watchStore.savedStatus == nil)
  }

  @Test
  func testNotificationEligibilityPersistsUntilItsWatermarkAdvances() throws {
    let suiteName = "GmailPushEligibilityTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let message = pushMessage(categoryId: "system:flights")
    try GmailPushEligibilityStore(defaults: defaults).record(
      [message],
      throughHistoryId: "124",
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    let restartedStore = GmailPushEligibilityStore(defaults: defaults)
    #expect(
      try restartedStore.eligibleStableMessageIds(
        after: "123",
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [message.stableProviderMessageId])
    #expect(
      try restartedStore.eligibleStableMessageIds(
        after: "124",
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ).isEmpty)
  }

  @Test
  func testNotificationEligibilityRetainsLatestBoundaryForRepeatedMessages() throws {
    let suiteName = "GmailPushEligibilityTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: suiteName))
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

    #expect(
      try store.eligibleStableMessageIds(
        after: "126",
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [message.stableProviderMessageId])
  }

  @Test
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
    #expect(!(originalWakeHandled))

    let replacementCenter = RecordingUserNotificationCenter()
    let replacementHandler = fixture.handler(notificationCenter: replacementCenter)
    let replacementWakeHandled = try await replacementHandler.handle(
      userInfo: fixture.userInfo(routeId: "route-002")
    )
    #expect(replacementWakeHandled)
    #expect(originalCenter.requests.count == 1)
    #expect(replacementCenter.request == nil)
    #expect(fixture.watchStore.savedStatus?.latestSyncedHistoryId == "124")
  }

  @Test
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

    #expect(!(handled))
    #expect(syncService.syncedConnection == nil)
  }

  @Test
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
      #expect(!(handled))
    }
    #expect(syncService.syncedConnection == nil)
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
    defaults = try requireValue(UserDefaults(suiteName: suiteName))
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
  var clearedProviderAccountIdentifier: String?
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
    providerAccountIdentifier: String
  ) throws {
    clearedProductAccountId = productAccountId
    clearedProviderAccountIdentifier = providerAccountIdentifier
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

  func clearAll(productAccountId: String) throws {
    clearedProductAccountId = productAccountId
  }

  func clear(
    productAccountId: String,
    providerAccountIdentifier _: String
  ) throws {
    clearedProductAccountId = productAccountId
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
    opaqueConnectionId _: String,
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
    opaqueConnectionId _: String,
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
    Issue.record("Unexpected token refresh")
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

private final class RecordingPushGmailMetadataSyncService:
  GmailConnectionAuthorizationChecking, MailboxMetadataSyncing
{
  var existingMessages: [GmailMessageMetadata] = []
  var historyIsExpired = false
  var onSync: (() -> Void)?
  var shouldPersist: Bool?
  var sinceHistoryId: String?
  var syncedMessages: [GmailMessageMetadata] = []
  var hasUnlistedNewMessages = false
  var includesHistoryCandidates: Bool?
  var localAuthorizationAvailable = true
  var newMessageIds: Set<String>?
  var syncedConnection: MailboxConnection?
  var syncedSession: ProductAccountSessionSnapshot?
  var syncError: Error?
  var usesUnavailableHistoryDelta = false

  func hasActiveAuthorization(
    _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> Bool {
    localAuthorizationAvailable
  }

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

  func setCategories(
    _: [String],
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
  private(set) var productAccountIds: [String] = []
  private let onDeliver: () -> Void

  init(onDeliver: @escaping () -> Void = {}) {
    self.onDeliver = onDeliver
  }

  func deliver(message: GmailMessageMetadata, productAccountId: String) async throws {
    messages.append(message)
    productAccountIds.append(productAccountId)
    onDeliver()
  }

  func deliverGeneric(identifier: String, productAccountId: String) async throws {
    genericNotificationIdentifiers.append(identifier)
    productAccountIds.append(productAccountId)
    onDeliver()
  }

  func requestAuthorization() async throws -> Bool {
    true
  }
}

private final class RecordingNotificationIdentifierStore:
  UserNotificationIdentifierPersisting
{
  private var identifiersByProductAccountId: [String: Set<String>] = [:]

  func allIdentifiers() -> Set<String> {
    identifiersByProductAccountId.values.reduce(into: Set<String>()) {
      $0.formUnion($1)
    }
  }

  func identifiers(productAccountId: String) -> Set<String> {
    identifiersByProductAccountId[productAccountId] ?? []
  }

  func record(identifier: String, productAccountId: String) {
    identifiersByProductAccountId[productAccountId, default: []].insert(identifier)
  }

  func clear(productAccountId: String) {
    identifiersByProductAccountId[productAccountId] = nil
  }
}

private final class RecordingNotificationPreferenceStore:
  NotificationDevicePreferencePersisting
{
  var preferences: NotificationDevicePreferences

  init(preferences: NotificationDevicePreferences) {
    self.preferences = preferences
  }

  func clear(productAccountId _: String) {
    preferences = .default
  }

  func load(productAccountId _: String) -> NotificationDevicePreferences {
    preferences
  }

  func save(_ preferences: NotificationDevicePreferences, productAccountId _: String) {
    self.preferences = preferences
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
  func deliver(message _: GmailMessageMetadata, productAccountId _: String) async throws {
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

private final class InMemoryLegacyWatchOwnerStore:
  GmailLegacyPushWatchOwnershipPersisting
{
  private var ownersByProductAccountId: [String: String] = [:]

  func clear(productAccountId: String) throws {
    ownersByProductAccountId[productAccountId] = nil
  }

  func load(productAccountId: String) throws -> String? {
    ownersByProductAccountId[productAccountId]
  }

  func save(providerAccountIdentifier: String, productAccountId: String) throws {
    ownersByProductAccountId[productAccountId] = providerAccountIdentifier
  }
}

private final class RecordingUserNotificationCenter: UserNotificationCenterClient {
  private(set) var authorizationOptions: UNAuthorizationOptions?
  private(set) var removedDeliveredNotificationIdentifiers: [String] = []
  private(set) var removedPendingNotificationIdentifiers: [String] = []
  private(set) var request: UNNotificationRequest?
  var deliveredRequestsForOwnership: [UNNotificationRequest] = []
  var pendingRequestsForOwnership: [UNNotificationRequest] = []

  func deliveredNotificationRequestsForOwnership() async -> [UNNotificationRequest] {
    deliveredRequestsForOwnership
  }

  func pendingNotificationRequestsForOwnership() async -> [UNNotificationRequest] {
    pendingRequestsForOwnership
  }

  func add(_ request: UNNotificationRequest) async throws {
    self.request = request
  }

  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
    removedDeliveredNotificationIdentifiers = identifiers
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
    removedPendingNotificationIdentifiers = identifiers
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
      Issue.record("Unexpected overlapping notification delivery")
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

  func removeDeliveredNotifications(withIdentifiers _: [String]) {}

  func removePendingNotificationRequests(withIdentifiers _: [String]) {}

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

private enum StubMailProfileNotificationGateError: Error {
  case unavailable
}

@MainActor
private final class StubMailProfileNotificationGate:
  MailProfileNotificationGate
{
  private let result: Result<Bool, Error>
  private(set) var invocationCount = 0

  init(isSuppressed: Bool) {
    result = .success(isSuppressed)
  }

  init(error: Error) {
    result = .failure(error)
  }

  func visibleNotificationsAreSuppressed(
    for _: MailboxConnectionId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> Bool {
    invocationCount += 1
    return try result.get()
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

private actor SequencedNotificationProfileResolver: NotificationProfileResolving {
  private var resolutions: [NotificationProfileResolution]
  private(set) var resolveCount = 0

  init(resolutions: [NotificationProfileResolution]) {
    self.resolutions = resolutions
  }

  func resolve(
    connectionId _: MailboxConnectionId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationProfileResolution {
    resolveCount += 1
    return resolutions.removeFirst()
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

private struct RevokedBackgroundProductAccountService: ProductAccountConnecting {
  func connect(identityToken _: String) async throws -> ProductAccountConnectResponse {
    throw ProductAccountServiceError.trustedDeviceRevoked
  }

  func markProductSyncMaterialInitialized(
    identityToken _: String,
    trustedDeviceId _: String
  ) async throws -> ProductSyncMaterialInitializedResponse {
    throw GmailPushRelayTestError.unexpectedCall
  }

  func productSyncRecoveryIsBackedUp(
    identityToken _: String,
    trustedDeviceId _: String,
    expectedRecoveryWrappedAccountKey _: ProductSyncEncryptedPayload?
  ) async throws -> Bool {
    throw GmailPushRelayTestError.unexpectedCall
  }

  func unregisterTrustedDevice(
    identityToken _: String,
    trustedDeviceId _: String
  ) async throws -> TrustedDeviceUnregistrationResponse {
    throw GmailPushRelayTestError.unexpectedCall
  }
}
