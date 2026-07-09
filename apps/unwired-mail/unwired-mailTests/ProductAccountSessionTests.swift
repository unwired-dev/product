import XCTest

@testable import unwired_mail

@MainActor
final class ProductAccountSessionTests: XCTestCase {
  private var store = InMemoryProductAccountSessionStore()
  private var keyMaterialStore = InMemoryProductSyncKeyMaterialStore()

  override func setUp() {
    store = InMemoryProductAccountSessionStore()
    keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
  }

  func testSignInStoresSessionAndMovesToSignedInState() async {
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .signedIn(let snapshot) = session.state else {
      return XCTFail("Expected signed-in state")
    }

    XCTAssertEqual(
      snapshot.productAccountId,
      ProductAccountConnectResponse.preview.productAccountId
    )
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertNotNil(try keyMaterialStore.load(productAccountId: snapshot.productAccountId))
  }

  func testSignOutClearsStoredSession() async {
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()
    session.signOut()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try store.load())
  }

  func testBootstrapPreservesSessionOnTransientBackendFailure() async throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    try store.save(snapshot)

    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: FailingProductAccountService(),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.bootstrap()

    guard case .failed = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(try store.load(), snapshot)
  }

  func testExistingProductAccountWithoutLocalSyncMaterialRequiresRecovery() async {
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .resumed),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .failed(let message) = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(
      message,
      ProductSyncKeyMaterialStoreError.recoveryRequired.localizedDescription
    )
    XCTAssertNil(
      try keyMaterialStore.load(
        productAccountId: ProductAccountConnectResponse.resumed.productAccountId
      )
    )
  }

  func testSameDeviceIncompleteInitialBootstrapCreatesMissingMaterial() async {
    let response = ProductAccountConnectResponse(
      accountCreated: false,
      deviceRegistered: false,
      hasEncryptedProductSyncPayloads: false,
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: response),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .signedIn(let snapshot) = session.state else {
      return XCTFail("Expected signed-in state")
    }
    XCTAssertEqual(snapshot.productAccountId, response.productAccountId)
    XCTAssertNotNil(try keyMaterialStore.load(productAccountId: response.productAccountId))
  }

  func testReturningRegisteredDeviceWithExistingSyncPayloadsRequiresRecovery() async {
    let response = ProductAccountConnectResponse(
      accountCreated: false,
      deviceRegistered: false,
      hasEncryptedProductSyncPayloads: true,
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    let session = ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-001",
          identityToken: "token-001"
        )
      ),
      productAccountService: PreviewProductAccountService(response: response),
      sessionStore: store,
      productSyncKeyMaterialStore: keyMaterialStore
    )

    await session.signInWithApple()

    guard case .failed(let message) = session.state else {
      return XCTFail("Expected failed state")
    }
    XCTAssertEqual(
      message,
      ProductSyncKeyMaterialStoreError.recoveryRequired.localizedDescription
    )
    XCTAssertNil(try keyMaterialStore.load(productAccountId: response.productAccountId))
  }
}

private struct FailingProductAccountService: ProductAccountConnecting {
  func connect(identityToken: String) async throws -> ProductAccountConnectResponse {
    _ = identityToken
    throw ConvexClientError.missingConvexURL
  }
}
