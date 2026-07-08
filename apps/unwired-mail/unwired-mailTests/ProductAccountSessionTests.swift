import XCTest

@testable import unwired_mail

@MainActor
final class ProductAccountSessionTests: XCTestCase {
  private var store = InMemoryProductAccountSessionStore()

  override func setUp() {
    store = InMemoryProductAccountSessionStore()
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
      sessionStore: store
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
      sessionStore: store
    )

    await session.signInWithApple()
    session.signOut()

    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(try store.load())
  }
}
