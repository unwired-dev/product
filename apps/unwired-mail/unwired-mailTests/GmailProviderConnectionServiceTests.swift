import XCTest

@testable import unwired_mail

final class GmailProviderConnectionServiceTests: XCTestCase {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "apple-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  func testCompleteConnectionStoresTokensLocallyAndSendsOnlyMetadataToBackend() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    let transport = RecordingGmailProviderConnectionTransport()
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
    let transport = RecordingGmailProviderConnectionTransport()
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
    let transport = RecordingGmailProviderConnectionTransport()
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

  func testLoadConnectionReadsBackendStatus() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let transport = RecordingGmailProviderConnectionTransport()
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
  }

  func testLoadConnectionRequiresLocalTokens() async throws {
    let service = GmailProviderConnectionService(
      tokenStore: InMemoryGmailProviderTokenStore(),
      transport: RecordingGmailProviderConnectionTransport()
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
    let transport = RecordingGmailProviderConnectionTransport()
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

  func testVerifierRequiresRefreshTokenForSameGmailAccount() async throws {
    let session = ConvexClientTesting.makeSession { request in
      let path = request.url?.path
      if path == "/gmail/v1/users/me/profile" {
        return (Self.httpResponse(for: request, statusCode: 200), Data("{}".utf8))
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
          Data(#"{"email":"user@example.com","sub":"gmail-user-001"}"#.utf8)
        )
      }

      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(#"{"email":"other@example.com","sub":"other-gmail-user"}"#.utf8)
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
        return (Self.httpResponse(for: request, statusCode: statusCode), Data("{}".utf8))
      }

      if path == "/token" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }

      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(#"{"email":"user@example.com","sub":"gmail-user-001"}"#.utf8)
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
        return (Self.httpResponse(for: request, statusCode: 200), Data("{}".utf8))
      }

      if path == "/token" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }

      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(#"{"email":"user@example.com","sub":"gmail-user-001"}"#.utf8)
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
}

private enum GmailProviderConnectionTestError: Error {
  case registrationFailed
}

private final class RecordingGmailProviderConnectionTransport: GmailProviderConnectionTransport {
  struct ConnectCall: Equatable {
    let identityToken: String
    let trustedDeviceId: String
    let emailAddress: String
    let providerAccountIdentifier: String
  }

  var connectCall: ConnectCall?
  var connectError: Error?
  var loadIdentityToken: String?
  var status = GmailProviderConnectionStatus(
    connectedAt: 1_781_200_000_000,
    emailAddress: "user@example.com",
    lastVerifiedAt: 1_781_200_000_000,
    provider: "gmail",
    providerAccountIdentifier: "gmail-user-001",
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_000
  )

  func connectGmailProvider(
    identityToken: String,
    trustedDeviceId: String,
    emailAddress: String,
    providerAccountIdentifier: String
  ) async throws -> GmailProviderConnectionStatus {
    connectCall = ConnectCall(
      identityToken: identityToken,
      trustedDeviceId: trustedDeviceId,
      emailAddress: emailAddress,
      providerAccountIdentifier: providerAccountIdentifier
    )
    if let connectError {
      throw connectError
    }

    return status
  }

  func getGmailProviderConnection(
    identityToken: String
  ) async throws -> GmailProviderConnectionStatus? {
    loadIdentityToken = identityToken
    return status
  }
}
