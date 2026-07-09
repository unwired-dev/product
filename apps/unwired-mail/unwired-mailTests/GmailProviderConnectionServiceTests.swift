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
