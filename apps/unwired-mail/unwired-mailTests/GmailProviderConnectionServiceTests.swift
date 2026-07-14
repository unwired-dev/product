import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
final class GmailProviderConnectionServiceTests: XCTestCase {
  private static let gmailReadScope = "https://www.googleapis.com/auth/gmail.readonly"

  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "apple-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  func testCompleteConnectionStoresTokensLocallyAndSendsOnlyMetadataToBackend() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    let transport = RecordingGmailConnectionTransport()
    let service = GmailProviderConnectionService(
      tokenStore: tokenStore,
      transport: transport
    )

    let status = try await service.completeConnection(
      verifiedAccount: VerifiedGmailAccount(
        emailAddress: "user@example.com",
        providerAccountIdentifier: "gmail-user-001",
        tokens: GmailProviderTokens(
          accessToken: "access-token",
          refreshToken: "refresh-token"
        )
      ),
      session: session
    )

    XCTAssertEqual(status.emailAddress, "user@example.com")
    XCTAssertEqual(
      try tokenStore.load(productAccountId: session.productAccountId),
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token")
    )
    XCTAssertEqual(transport.connectCall?.identityToken, "apple-token")
    XCTAssertEqual(transport.connectCall?.trustedDeviceId, "trusted-device-001")
    XCTAssertEqual(transport.connectCall?.emailAddress, "user@example.com")
    XCTAssertEqual(transport.connectCall?.providerAccountIdentifier, "gmail-user-001")
  }

  func testCompleteConnectionClearsLocalTokensWhenBackendRegistrationFails() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    let transport = RecordingGmailConnectionTransport()
    transport.connectError = GmailProviderConnectionTestError.registrationFailed
    let service = GmailProviderConnectionService(
      tokenStore: tokenStore,
      transport: transport
    )

    do {
      _ = try await service.completeConnection(
        verifiedAccount: VerifiedGmailAccount(
          emailAddress: "user@example.com",
          providerAccountIdentifier: "gmail-user-001",
          tokens: GmailProviderTokens(
            accessToken: "access-token",
            refreshToken: "refresh-token"
          )
        ),
        session: session
      )
      XCTFail("Expected backend registration failure")
    } catch GmailProviderConnectionTestError.registrationFailed {
      XCTAssertNil(try tokenStore.load(productAccountId: session.productAccountId))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testCompleteConnectionRestoresPreviousTokensWhenUpdateRegistrationFails() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "old-access-token", refreshToken: "old-refresh-token"),
      productAccountId: session.productAccountId
    )
    let transport = RecordingGmailConnectionTransport()
    transport.connectError = GmailProviderConnectionTestError.registrationFailed
    let service = GmailProviderConnectionService(
      tokenStore: tokenStore,
      transport: transport
    )

    do {
      _ = try await service.completeConnection(
        verifiedAccount: VerifiedGmailAccount(
          emailAddress: "user@example.com",
          providerAccountIdentifier: "gmail-user-001",
          tokens: GmailProviderTokens(
            accessToken: "new-access-token",
            refreshToken: "new-refresh-token"
          )
        ),
        session: session
      )
      XCTFail("Expected backend registration failure")
    } catch GmailProviderConnectionTestError.registrationFailed {
      XCTAssertEqual(
        try tokenStore.load(productAccountId: session.productAccountId),
        GmailProviderTokens(accessToken: "old-access-token", refreshToken: "old-refresh-token")
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testCompleteConnectionClearsLocalCacheBeforeUpdateRegistration() async throws {
    let bodyReader = RecordingGmailMessageReader()
    let metadataStore = RecordingGmailProviderMetadataStore()
    let transport = RecordingGmailConnectionTransport()
    transport.status = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "old@example.com",
      lastVerifiedAt: 1_781_200_000_000,
      provider: "gmail",
      providerAccountIdentifier: "old-gmail-user",
      trustedDeviceId: "trusted-device-001",
      updatedAt: 1_781_200_000_000
    )
    transport.connectError = GmailProviderConnectionTestError.registrationFailed
    let service = GmailProviderConnectionService(
      bodyReader: bodyReader,
      metadataStore: metadataStore,
      tokenStore: InMemoryGmailProviderTokenStore(),
      transport: transport
    )

    do {
      _ = try await service.completeConnection(
        verifiedAccount: VerifiedGmailAccount(
          emailAddress: "new@example.com",
          providerAccountIdentifier: "new-gmail-user",
          tokens: GmailProviderTokens(
            accessToken: "new-access-token",
            refreshToken: "new-refresh-token"
          )
        ),
        session: session
      )
      XCTFail("Expected backend registration failure")
    } catch GmailProviderConnectionTestError.registrationFailed {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertEqual(bodyReader.clearedSessions, [session])
    XCTAssertEqual(metadataStore.clearedProductAccountIds, [session.productAccountId])
  }

  // swiftlint:disable:next function_body_length
  func testCompleteConnectionClearsMetadataWhenProviderAccountChanges() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "old-access-token", refreshToken: "old-refresh-token"),
      productAccountId: session.productAccountId
    )
    let metadataStore = RecordingGmailProviderMetadataStore()
    let pushWatchStore = RecordingPushWatchStore()
    let pushWatchStopper = RecordingPushWatchStopper(tokenStore: tokenStore)
    let transport = RecordingGmailConnectionTransport()
    transport.status = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "old@example.com",
      lastVerifiedAt: 1_781_200_000_000,
      provider: "gmail",
      providerAccountIdentifier: "old-gmail-user",
      trustedDeviceId: "trusted-device-001",
      updatedAt: 1_781_200_000_000
    )
    transport.connectStatus = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "new@example.com",
      lastVerifiedAt: 1_781_210_000_000,
      provider: "gmail",
      providerAccountIdentifier: "new-gmail-user",
      trustedDeviceId: "trusted-device-001",
      updatedAt: 1_781_210_000_000
    )
    let service = GmailProviderConnectionService(
      pushWatchStopper: pushWatchStopper,
      pushWatchStore: pushWatchStore,
      metadataStore: metadataStore,
      tokenStore: tokenStore,
      transport: transport
    )

    let status = try await service.completeConnection(
      verifiedAccount: VerifiedGmailAccount(
        emailAddress: "new@example.com",
        providerAccountIdentifier: "new-gmail-user",
        tokens: GmailProviderTokens(
          accessToken: "new-access-token",
          refreshToken: "new-refresh-token"
        )
      ),
      session: session
    )

    XCTAssertEqual(status.providerAccountIdentifier, "new-gmail-user")
    XCTAssertEqual(pushWatchStopper.stoppedConnection, transport.status)
    XCTAssertTrue(pushWatchStopper.tokensWereAvailable)
    XCTAssertEqual(metadataStore.clearedProductAccountIds, [session.productAccountId])
    XCTAssertEqual(
      pushWatchStore.clearedKeys,
      ["\(session.productAccountId):old-gmail-user"]
    )
  }

  func testCompleteConnectionDoesNotRotateRouteWhenMetadataCleanupFails() async throws {
    let metadataStore = RecordingGmailProviderMetadataStore()
    metadataStore.clearError = GmailProviderConnectionTestError.metadataCleanupFailed
    let pushWatchStore = RecordingPushWatchStore()
    let transport = RecordingGmailConnectionTransport()
    transport.status = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "old@example.com",
      lastVerifiedAt: 1_781_200_000_000,
      provider: "gmail",
      providerAccountIdentifier: "old-gmail-user",
      trustedDeviceId: "trusted-device-001",
      updatedAt: 1_781_200_000_000
    )
    transport.connectStatus = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "new@example.com",
      lastVerifiedAt: 1_781_210_000_000,
      provider: "gmail",
      providerAccountIdentifier: "new-gmail-user",
      trustedDeviceId: "trusted-device-001",
      updatedAt: 1_781_210_000_000
    )
    let service = GmailProviderConnectionService(
      pushWatchStore: pushWatchStore,
      metadataStore: metadataStore,
      tokenStore: InMemoryGmailProviderTokenStore(),
      transport: transport
    )

    do {
      _ = try await service.completeConnection(
        verifiedAccount: VerifiedGmailAccount(
          emailAddress: "new@example.com",
          providerAccountIdentifier: "new-gmail-user",
          tokens: GmailProviderTokens(
            accessToken: "new-access-token",
            refreshToken: "new-refresh-token"
          )
        ),
        session: session
      )
      XCTFail("Expected metadata cleanup failure")
    } catch GmailProviderConnectionTestError.metadataCleanupFailed {
    }

    XCTAssertEqual(metadataStore.clearedProductAccountIds, [session.productAccountId])
    XCTAssertTrue(pushWatchStore.clearedKeys.isEmpty)
    XCTAssertTrue(transport.connectCalls.isEmpty)
  }

  func testCompleteConnectionThrowsWhenBodyCacheCleanupFails() async throws {
    let transport = RecordingGmailConnectionTransport()
    let tokenStore = InMemoryGmailProviderTokenStore()
    let previousTokens = GmailProviderTokens(
      accessToken: "old-access-token",
      refreshToken: "old-refresh-token"
    )
    try tokenStore.save(previousTokens, productAccountId: session.productAccountId)
    transport.status = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "old@example.com",
      lastVerifiedAt: 1_781_200_000_000,
      provider: "gmail",
      providerAccountIdentifier: "old-gmail-user",
      trustedDeviceId: "trusted-device-001",
      updatedAt: 1_781_200_000_000
    )
    transport.connectStatus = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "new@example.com",
      lastVerifiedAt: 1_781_210_000_000,
      provider: "gmail",
      providerAccountIdentifier: "new-gmail-user",
      trustedDeviceId: "trusted-device-001",
      updatedAt: 1_781_210_000_000
    )
    let service = GmailProviderConnectionService(
      bodyReader: FailingGmailMessageReader(),
      tokenStore: tokenStore,
      transport: transport
    )

    do {
      _ = try await service.completeConnection(
        verifiedAccount: VerifiedGmailAccount(
          emailAddress: "new@example.com",
          providerAccountIdentifier: "new-gmail-user",
          tokens: GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token")
        ),
        session: session
      )
      XCTFail("Expected body cache cleanup failure")
    } catch GmailProviderConnectionTestError.bodyCacheCleanupFailed {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertEqual(try tokenStore.load(productAccountId: session.productAccountId), previousTokens)
    XCTAssertTrue(transport.connectCalls.isEmpty)
  }

  func testCompleteConnectionClearsLocalCacheWhenPriorLookupFails() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "old-access-token", refreshToken: "old-refresh-token"),
      productAccountId: session.productAccountId
    )
    let metadataStore = RecordingGmailProviderMetadataStore()
    let bodyReader = RecordingGmailMessageReader()
    let transport = RecordingGmailConnectionTransport()
    transport.loadError = GmailProviderConnectionTestError.registrationFailed
    let service = GmailProviderConnectionService(
      bodyReader: bodyReader,
      metadataStore: metadataStore,
      tokenStore: tokenStore,
      transport: transport
    )

    _ = try await service.completeConnection(
      verifiedAccount: VerifiedGmailAccount(
        emailAddress: "user@example.com",
        providerAccountIdentifier: "gmail-user-001",
        tokens: GmailProviderTokens(
          accessToken: "new-access-token",
          refreshToken: "new-refresh-token"
        )
      ),
      session: session
    )

    XCTAssertEqual(bodyReader.clearedSessions, [session])
    XCTAssertEqual(metadataStore.clearedProductAccountIds, [session.productAccountId])
  }

  func testCompleteConnectionDoesNotRestorePreviousTokensWhenCancelled() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "old-access-token", refreshToken: "old-refresh-token"),
      productAccountId: session.productAccountId
    )
    let transport = RecordingGmailConnectionTransport()
    transport.onConnect = {
      try tokenStore.clear(productAccountId: self.session.productAccountId)
    }
    transport.connectError = CancellationError()
    let service = GmailProviderConnectionService(
      tokenStore: tokenStore,
      transport: transport
    )

    do {
      _ = try await service.completeConnection(
        verifiedAccount: VerifiedGmailAccount(
          emailAddress: "user@example.com",
          providerAccountIdentifier: "gmail-user-001",
          tokens: GmailProviderTokens(
            accessToken: "new-access-token",
            refreshToken: "new-refresh-token"
          )
        ),
        session: session
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertNil(try tokenStore.load(productAccountId: session.productAccountId))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testCompleteConnectionDoesNotSaveTokensWhenConnectionLookupIsCancelled() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    let transport = RecordingGmailConnectionTransport()
    transport.loadError = CancellationError()
    let service = GmailProviderConnectionService(
      tokenStore: tokenStore,
      transport: transport
    )

    do {
      _ = try await service.completeConnection(
        verifiedAccount: VerifiedGmailAccount(
          emailAddress: "user@example.com",
          providerAccountIdentifier: "gmail-user-001",
          tokens: GmailProviderTokens(
            accessToken: "new-access-token",
            refreshToken: "new-refresh-token"
          )
        ),
        session: session
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertNil(try tokenStore.load(productAccountId: session.productAccountId))
      XCTAssertNil(transport.connectCall)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testLoadConnectionReadsBackendStatus() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let transport = RecordingGmailConnectionTransport()
    transport.status = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "user@example.com",
      lastVerifiedAt: 1_781_200_000_000,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-001",
      trustedDeviceId: "trusted-device-001",
      updatedAt: 1_781_200_000_000
    )
    let service = GmailProviderConnectionService(
      tokenStore: tokenStore,
      transport: transport
    )

    let status = try await service.loadConnection(session: session)

    XCTAssertEqual(status?.emailAddress, "user@example.com")
    XCTAssertEqual(transport.loadIdentityToken, "apple-token")
    XCTAssertEqual(transport.loadTrustedDeviceId, "trusted-device-001")
  }

  func testLoadConnectionRequiresLocalTokens() async throws {
    let service = GmailProviderConnectionService(
      tokenStore: InMemoryGmailProviderTokenStore(),
      transport: RecordingGmailConnectionTransport()
    )

    let status = try await service.loadConnection(session: session)

    XCTAssertNil(status)
  }

  func testLoadConnectionRequiresCurrentTrustedDevice() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let transport = RecordingGmailConnectionTransport()
    transport.status = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "user@example.com",
      lastVerifiedAt: 1_781_200_000_000,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-001",
      trustedDeviceId: "other-trusted-device",
      updatedAt: 1_781_200_000_000
    )
    let service = GmailProviderConnectionService(
      tokenStore: tokenStore,
      transport: transport
    )

    let status = try await service.loadConnection(session: session)

    XCTAssertNil(status)
  }

  func testClearLocalConnectionStopsWatchThenClearsTokensMetadataAndCachedBodies() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    let bodyReader = RecordingGmailMessageReader()
    let metadataStore = RecordingGmailProviderMetadataStore()
    let pushConnectionStore = RecordingPushConnectionStore(
      connection: GmailProviderConnectionStatus(
        connectedAt: 1_781_200_000_000,
        emailAddress: "user@example.com",
        lastVerifiedAt: 1_781_200_000_000,
        provider: "gmail",
        providerAccountIdentifier: "gmail-user-001",
        trustedDeviceId: session.trustedDeviceId,
        updatedAt: 1_781_200_000_000
      )
    )
    let pushWatchStore = RecordingPushWatchStore()
    let pushWatchStopper = RecordingPushWatchStopper(tokenStore: tokenStore)
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let service = GmailProviderConnectionService(
      bodyReader: bodyReader,
      pushConnectionStore: pushConnectionStore,
      pushWatchStopper: pushWatchStopper,
      pushWatchStore: pushWatchStore,
      metadataStore: metadataStore,
      tokenStore: tokenStore,
      transport: RecordingGmailConnectionTransport()
    )

    try await service.clearLocalConnection(session: session)

    XCTAssertEqual(pushWatchStopper.stoppedConnection, pushConnectionStore.connection)
    XCTAssertEqual(pushWatchStopper.stoppedSession, session)
    XCTAssertTrue(pushWatchStopper.tokensWereAvailable)
    XCTAssertNil(try tokenStore.load(productAccountId: session.productAccountId))
    XCTAssertEqual(bodyReader.clearedSessions, [session])
    XCTAssertEqual(metadataStore.clearedProductAccountIds, [session.productAccountId])
    XCTAssertEqual(pushConnectionStore.clearedProductAccountIds, [session.productAccountId])
    XCTAssertEqual(
      pushWatchStore.clearedKeys,
      ["\(session.productAccountId):gmail-user-001"]
    )
  }

  func testClearLocalConnectionPreservesSharedMailboxWatch() async throws {
    let transport = RecordingGmailConnectionTransport()
    transport.shouldStopWatch = false
    let tokenStore = InMemoryGmailProviderTokenStore()
    let pushWatchStopper = RecordingPushWatchStopper(tokenStore: tokenStore)
    let pushConnectionStore = RecordingPushConnectionStore(connection: transport.status)
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      pushWatchStopper: pushWatchStopper,
      tokenStore: tokenStore,
      transport: transport
    )

    try await service.clearLocalConnection(session: session)

    XCTAssertNil(pushWatchStopper.stoppedConnection)
    XCTAssertEqual(pushConnectionStore.clearedProductAccountIds, [session.productAccountId])
  }

  func testClearLocalConnectionTreatsWatchStopFailureAsBestEffort() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let pushWatchStopper = RecordingPushWatchStopper(tokenStore: tokenStore)
    pushWatchStopper.stopError = GmailProviderConnectionTestError.watchStopFailed
    let pushConnectionStore = RecordingPushConnectionStore(
      connection: RecordingGmailConnectionTransport().status
    )
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      pushWatchStopper: pushWatchStopper,
      tokenStore: tokenStore,
      transport: RecordingGmailConnectionTransport()
    )

    try await service.clearLocalConnection(session: session)

    XCTAssertNil(try tokenStore.load(productAccountId: session.productAccountId))
    XCTAssertEqual(pushConnectionStore.clearedProductAccountIds, [session.productAccountId])
  }

  func testClearLocalConnectionAttemptsMetadataCleanupWhenTokenCleanupFails() async throws {
    let tokenStore = FailingClearGmailProviderTokenStore()
    let metadataStore = RecordingGmailProviderMetadataStore()
    let service = GmailProviderConnectionService(
      metadataStore: metadataStore,
      tokenStore: tokenStore,
      transport: RecordingGmailConnectionTransport()
    )

    do {
      try await service.clearLocalConnection(session: session)
      XCTFail("Expected token cleanup failure")
    } catch GmailProviderConnectionTestError.tokenCleanupFailed {
      XCTAssertEqual(metadataStore.clearedProductAccountIds, [session.productAccountId])
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testVerifierRequiresGmailProfileAccessBeforeReturningVerifiedAccount() async throws {
    let session = ConvexClientTesting.makeSession { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: request.url?.path == "/gmail/v1/users/me/profile" ? 403 : 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, Data("{}".utf8))
    }
    let verifier = GoogleGmailProviderCredentialVerifier(
      oauthClientId: "gmail-client-id",
      session: session
    )

    do {
      _ = try await verifier.verify(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        expectedEmailAddress: "user@example.com",
        expectedProviderAccountIdentifier: "gmail-user-001"
      )
      XCTFail("Expected Gmail authorization failure")
    } catch GmailProviderCredentialVerificationError.missingGmailAuthorization {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testVerifierRejectsMetadataOnlyGmailAuthorization() async throws {
    let session = ConvexClientTesting.makeSession { request in
      if request.url?.path == "/gmail/v1/users/me/profile" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"emailAddress":"user@example.com"}"#.utf8)
        )
      }
      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(
          #"{"scope":"https://www.googleapis.com/auth/gmail.metadata","sub":"gmail-user-001"}"#
            .utf8)
      )
    }
    let verifier = GoogleGmailProviderCredentialVerifier(
      oauthClientId: "gmail-client-id",
      session: session
    )

    do {
      _ = try await verifier.verify(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        expectedEmailAddress: "user@example.com",
        expectedProviderAccountIdentifier: "gmail-user-001"
      )
      XCTFail("Expected insufficient Gmail scope")
    } catch GmailProviderCredentialVerificationError.insufficientGmailScope {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // swiftlint:disable:next function_body_length
  func testVerifierRequiresRefreshTokenForSameGmailAccount() async throws {
    let session = ConvexClientTesting.makeSession { request in
      let path = request.url?.path
      if path == "/gmail/v1/users/me/profile" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"emailAddress":"user@example.com"}"#.utf8)
        )
      }

      if path == "/token" {
        let body = Self.httpBodyString(for: request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
          request.value(forHTTPHeaderField: "Content-Type"),
          "application/x-www-form-urlencoded"
        )
        XCTAssertTrue(body?.contains("client_id=gmail-client-id") == true)
        XCTAssertTrue(body?.contains("grant_type=refresh_token") == true)
        XCTAssertTrue(body?.contains("refresh_token=refresh-token") == true)
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }

      if request.url?.query == "access_token=access-token" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(
            #"{"email":"user@example.com","scope":"\#(Self.gmailReadScope)","sub":"gmail-user-001"}"#
              .utf8)
        )
      }

      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(
          #"{"email":"other@example.com","scope":"\#(Self.gmailReadScope)","sub":"other-gmail-user"}"#
            .utf8)
      )
    }
    let verifier = GoogleGmailProviderCredentialVerifier(
      oauthClientId: "gmail-client-id",
      session: session
    )

    do {
      _ = try await verifier.verify(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        expectedEmailAddress: "user@example.com",
        expectedProviderAccountIdentifier: "gmail-user-001"
      )
      XCTFail("Expected account mismatch")
    } catch GmailProviderCredentialVerificationError.accountMismatch {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testVerifierRequiresRefreshedAccessTokenToHaveGmailProfileAccess() async throws {
    let session = ConvexClientTesting.makeSession { request in
      let path = request.url?.path
      if path == "/gmail/v1/users/me/profile" {
        let statusCode =
          request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token" ? 200 : 403
        return (
          Self.httpResponse(for: request, statusCode: statusCode),
          Data(#"{"emailAddress":"user@example.com"}"#.utf8)
        )
      }

      if path == "/token" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }

      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(
          #"{"email":"user@example.com","scope":"\#(Self.gmailReadScope)","sub":"gmail-user-001"}"#
            .utf8)
      )
    }
    let verifier = GoogleGmailProviderCredentialVerifier(
      oauthClientId: "gmail-client-id",
      session: session
    )

    do {
      _ = try await verifier.verify(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        expectedEmailAddress: "user@example.com",
        expectedProviderAccountIdentifier: "gmail-user-001"
      )
      XCTFail("Expected Gmail authorization failure")
    } catch GmailProviderCredentialVerificationError.missingGmailAuthorization {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testVerifierReturnsVerifiedAccountAfterAccessRefreshAndGmailChecksPass() async throws {
    var profileAuthorizations: [String] = []
    let session = ConvexClientTesting.makeSession { request in
      let path = request.url?.path
      if path == "/gmail/v1/users/me/profile" {
        if let authorization = request.value(forHTTPHeaderField: "Authorization") {
          profileAuthorizations.append(authorization)
        }
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"emailAddress":"user@example.com"}"#.utf8)
        )
      }

      if path == "/token" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }

      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(
          #"{"scope":"https://www.googleapis.com/auth/gmail.readonly","sub":"gmail-user-001"}"#.utf8
        )
      )
    }
    let verifier = GoogleGmailProviderCredentialVerifier(
      oauthClientId: "gmail-client-id",
      session: session
    )

    let account = try await verifier.verify(
      accessToken: "access-token",
      refreshToken: "refresh-token",
      expectedEmailAddress: "user@example.com",
      expectedProviderAccountIdentifier: "gmail-user-001"
    )

    XCTAssertEqual(account.emailAddress, "user@example.com")
    XCTAssertEqual(account.providerAccountIdentifier, "gmail-user-001")
    XCTAssertEqual(
      profileAuthorizations,
      ["Bearer access-token", "Bearer refreshed-access-token"]
    )
    XCTAssertEqual(
      account.tokens,
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token")
    )
  }

  func testVerifierUsesGmailProfileEmailWhenTokenInfoOmitsEmail() async throws {
    let session = ConvexClientTesting.makeSession { request in
      let path = request.url?.path
      if path == "/gmail/v1/users/me/profile" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"emailAddress":"user@example.com"}"#.utf8)
        )
      }

      if path == "/token" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }

      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(
          #"{"scope":"https://www.googleapis.com/auth/gmail.readonly","sub":"gmail-user-001"}"#.utf8
        )
      )
    }
    let verifier = GoogleGmailProviderCredentialVerifier(
      oauthClientId: "gmail-client-id",
      session: session
    )

    let account = try await verifier.verify(
      accessToken: "access-token",
      refreshToken: "refresh-token",
      expectedEmailAddress: "user@example.com",
      expectedProviderAccountIdentifier: "gmail-user-001"
    )

    XCTAssertEqual(account.emailAddress, "user@example.com")
    XCTAssertEqual(account.providerAccountIdentifier, "gmail-user-001")
  }

  func testBundledOAuthClientIdReadsGeneratedInfoPlistKey() throws {
    let bundle = try Self.makeBundle(
      infoDictionary: [
        GmailOAuthClientIdConfiguration.infoDictionaryKey: " bundled-client-id "
      ]
    )

    XCTAssertEqual(
      GmailOAuthClientIdConfiguration.bundledValue(bundle: bundle),
      "bundled-client-id"
    )
  }

  func testBundledOAuthClientIdIgnoresUnresolvedBuildSettingPlaceholder() throws {
    let bundle = try Self.makeBundle(
      infoDictionary: [
        GmailOAuthClientIdConfiguration.infoDictionaryKey: "$(GMAIL_OAUTH_CLIENT_ID)"
      ]
    )

    XCTAssertNil(GmailOAuthClientIdConfiguration.bundledValue(bundle: bundle))
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

  private static func httpBodyString(for request: URLRequest) -> String? {
    if let body = request.httpBody {
      return String(data: body, encoding: .utf8)
    }

    guard let stream = request.httpBodyStream else {
      return nil
    }

    stream.open()
    defer {
      stream.close()
    }

    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer {
      buffer.deallocate()
    }

    while stream.hasBytesAvailable {
      let count = stream.read(buffer, maxLength: bufferSize)
      if count <= 0 {
        break
      }
      data.append(buffer, count: count)
    }

    return String(data: data, encoding: .utf8)
  }

  private static func makeBundle(infoDictionary: [String: String]) throws -> Bundle {
    let bundleURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("bundle")
    try FileManager.default.createDirectory(
      at: bundleURL,
      withIntermediateDirectories: true
    )
    let infoPlistURL = bundleURL.appendingPathComponent("Info.plist")
    let data = try PropertyListSerialization.data(
      fromPropertyList: infoDictionary,
      format: .xml,
      options: 0
    )
    try data.write(to: infoPlistURL)

    guard let bundle = Bundle(url: bundleURL) else {
      throw GmailProviderConnectionTestError.bundleCreationFailed
    }

    return bundle
  }
}
// swiftlint:enable type_body_length

private enum GmailProviderConnectionTestError: Error {
  case bodyCacheCleanupFailed
  case bundleCreationFailed
  case metadataCleanupFailed
  case registrationFailed
  case tokenCleanupFailed
  case watchStopFailed
}

private struct FailingGmailMessageReader: GmailMessageReading {
  func clearCachedMessageBodies(session _: ProductAccountSessionSnapshot) throws {
    throw GmailProviderConnectionTestError.bodyCacheCleanupFailed
  }

  func loadMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageBody {
    throw GmailProviderConnectionTestError.bodyCacheCleanupFailed
  }

  func removeCachedMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws {
    throw GmailProviderConnectionTestError.bodyCacheCleanupFailed
  }
}

private final class RecordingGmailMessageReader: GmailMessageReading {
  var clearedSessions: [ProductAccountSessionSnapshot] = []

  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws {
    clearedSessions.append(session)
  }

  func loadMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageBody {
    throw GmailProviderConnectionTestError.bodyCacheCleanupFailed
  }

  func removeCachedMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws {
    throw GmailProviderConnectionTestError.bodyCacheCleanupFailed
  }
}

private final class RecordingGmailConnectionTransport: GmailProviderConnectionTransport {
  struct ConnectCall: Equatable {
    let identityToken: String
    let trustedDeviceId: String
    let emailAddress: String
    let providerAccountIdentifier: String
  }

  var connectCall: ConnectCall?
  var connectCalls: [ConnectCall] = []
  var connectError: Error?
  var loadError: Error?
  var loadIdentityToken: String?
  var loadTrustedDeviceId: String?
  var onConnect: (() throws -> Void)?
  var connectStatus: GmailProviderConnectionStatus?
  var status = GmailProviderConnectionStatus(
    connectedAt: 1_781_200_000_000,
    emailAddress: "user@example.com",
    lastVerifiedAt: 1_781_200_000_000,
    provider: "gmail",
    providerAccountIdentifier: "gmail-user-001",
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_000
  )
  var shouldStopError: Error?
  var shouldStopWatch = true

  func connectGmailProvider(
    identityToken: String,
    trustedDeviceId: String,
    emailAddress: String,
    providerAccountIdentifier: String
  ) async throws -> GmailProviderConnectionStatus {
    let connectCall = ConnectCall(
      identityToken: identityToken,
      trustedDeviceId: trustedDeviceId,
      emailAddress: emailAddress,
      providerAccountIdentifier: providerAccountIdentifier
    )
    self.connectCall = connectCall
    connectCalls.append(connectCall)
    try onConnect?()
    if let connectError {
      throw connectError
    }

    return connectStatus ?? status
  }

  func getGmailProviderConnection(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> GmailProviderConnectionStatus? {
    loadIdentityToken = identityToken
    loadTrustedDeviceId = trustedDeviceId
    if let loadError {
      throw loadError
    }

    return status
  }

  func shouldStopGmailPushWatch(
    identityToken _: String,
    trustedDeviceId _: String
  ) async throws -> Bool {
    if let shouldStopError {
      throw shouldStopError
    }
    return shouldStopWatch
  }
}

private final class FailingClearGmailProviderTokenStore: GmailProviderTokenPersisting {
  func clear(productAccountId _: String) throws {
    throw GmailProviderConnectionTestError.tokenCleanupFailed
  }

  func load(productAccountId _: String) throws -> GmailProviderTokens? {
    nil
  }

  func save(_: GmailProviderTokens, productAccountId _: String) throws {}
}

private final class RecordingPushConnectionStore: GmailPushConnectionPersisting {
  var clearedProductAccountIds: [String] = []
  let connection: GmailProviderConnectionStatus?

  init(connection: GmailProviderConnectionStatus? = nil) {
    self.connection = connection
  }

  func clear(productAccountId: String) throws {
    clearedProductAccountIds.append(productAccountId)
  }

  func load(productAccountId _: String) throws -> GmailProviderConnectionStatus? {
    connection
  }

  func save(
    _ connection: GmailProviderConnectionStatus,
    productAccountId: String
  ) throws {
    _ = connection
    _ = productAccountId
  }
}

private final class RecordingPushWatchStopper: GmailPushWatchStopping {
  private let tokenStore: GmailProviderTokenPersisting
  var stoppedConnection: GmailProviderConnectionStatus?
  var stoppedSession: ProductAccountSessionSnapshot?
  var tokensWereAvailable = false
  var stopError: Error?

  init(tokenStore: GmailProviderTokenPersisting) {
    self.tokenStore = tokenStore
  }

  func stop(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws {
    stoppedConnection = connection
    stoppedSession = session
    tokensWereAvailable =
      try tokenStore.load(productAccountId: session.productAccountId) != nil
    if let stopError {
      throw stopError
    }
  }
}

private final class RecordingPushWatchStore: GmailPushWatchPersisting {
  var clearedKeys: [String] = []

  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    clearedKeys.append("\(productAccountId):\(providerAccountIdentifier)")
  }

  func load(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> GmailPushWatchStatus? {
    nil
  }

  func save(
    _: GmailPushWatchStatus,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}
}

private final class RecordingGmailProviderMetadataStore: GmailMessageMetadataPersisting {
  var clearError: Error?
  var clearedProductAccountIds: [String] = []

  func clearMessages(productAccountId: String) throws {
    clearedProductAccountIds.append(productAccountId)
    if let clearError {
      throw clearError
    }
  }

  func loadMessages(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> [GmailMessageMetadata] {
    []
  }

  func saveMessages(
    _: [GmailMessageMetadata],
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}
}
