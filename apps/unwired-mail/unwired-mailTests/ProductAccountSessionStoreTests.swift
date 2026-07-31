import XCTest

@testable import unwired_mail

final class ProductAccountSessionStoreTests: XCTestCase {
  private var store = InMemoryProductAccountSessionStore()

  override func setUp() {
    store = InMemoryProductAccountSessionStore()
  }

  func testSaveAndLoadRoundTrip() throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    try store.save(snapshot)
    let loaded = try store.load()

    XCTAssertEqual(loaded, snapshot)
  }

  func testClearRemovesStoredSession() throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    try store.save(snapshot)
    try store.clear()

    XCTAssertNil(try store.load())
  }

  func testUnacknowledgedRecoveryKeysAreScopedToTheProductAccount() throws {
    try store.saveUnacknowledgedRecoveryKey(
      "first-account-key",
      productAccountId: "first-product-account"
    )

    XCTAssertNil(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: "second-product-account")
    )
    try store.clearUnacknowledgedRecoveryKey(productAccountId: "second-product-account")
    XCTAssertEqual(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: "first-product-account"),
      "first-account-key"
    )
  }

  func testIdentityTokenStateUsesVerifiedExpiration() {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "apple-token",
      identityTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    XCTAssertEqual(
      snapshot.identityTokenState(at: Date(timeIntervalSince1970: 999)),
      .active
    )
    XCTAssertEqual(
      snapshot.identityTokenState(at: Date(timeIntervalSince1970: 1_000)),
      .expired
    )
  }

  func testIdentityTokenStateIsUnverifiableWithoutVerifiedExpiration() {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "e30.eyJleHAiOjEwMDB9.invalid-signature",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    XCTAssertEqual(snapshot.identityTokenState(at: Date()), .unverifiable)
  }

  func testLegacyEncodedSessionHasNoVerifiedExpiration() throws {
    let legacyData = Data(
      #"""
      {
        "appleUserIdentifier": "apple-user-001",
        "identityToken": "e30.eyJleHAiOjEwMDB9.invalid-signature",
        "productAccountId": "productAccountFixtureId",
        "trustedDeviceId": "trustedDeviceFixtureId"
      }
      """#.utf8
    )

    let snapshot = try JSONDecoder().decode(ProductAccountSessionSnapshot.self, from: legacyData)

    XCTAssertNil(snapshot.identityTokenExpiresAt)
    XCTAssertEqual(snapshot.identityTokenState(at: Date()), .unverifiable)
  }
}
