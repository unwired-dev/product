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

  func testTrustedDeviceCredentialPersistenceIsScopedAndClearable() throws {
    let credentialStore = InMemoryTrustedDeviceCredentialStore()

    try credentialStore.save("credential-001", trustedDeviceId: "trusted-device-001")
    try credentialStore.save("credential-002", trustedDeviceId: "trusted-device-002")
    try credentialStore.clear(trustedDeviceId: "trusted-device-001")

    XCTAssertNil(try credentialStore.load(trustedDeviceId: "trusted-device-001"))
    XCTAssertEqual(
      try credentialStore.load(trustedDeviceId: "trusted-device-002"),
      "credential-002"
    )
  }

  func testPendingTrustedDeviceUnregistrationsPreserveInsertionOrder() throws {
    let first = PendingTrustedDeviceUnregistration(
      appleUserIdentifier: "apple-user-001",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-002"
    )
    let second = PendingTrustedDeviceUnregistration(
      appleUserIdentifier: "apple-user-001",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )

    try store.savePendingTrustedDeviceUnregistration(first)
    try store.savePendingTrustedDeviceUnregistration(second)

    XCTAssertEqual(try store.loadPendingTrustedDeviceUnregistrations(), [first, second])
  }

  func testSavingPendingTrustedDeviceUnregistrationReplacesMalformedKeychainData() throws {
    let service = ProductAccountSessionStore.serviceName
    let account = "pending-trusted-device-unregistration"
    defer { try? KeychainStore.delete(service: service, account: account) }
    try KeychainStore.writeString("not-json", service: service, account: account)
    let keychainStore = KeychainProductAccountSessionStore()
    let unregistration = PendingTrustedDeviceUnregistration(
      appleUserIdentifier: "apple-user-001",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )

    try keychainStore.savePendingTrustedDeviceUnregistration(unregistration)

    XCTAssertEqual(try keychainStore.loadPendingTrustedDeviceUnregistrations(), [unregistration])
  }

  func testUnacknowledgedRecoveryKeysAreScopedToTheProductAccount() throws {
    let recoveryKey = UnacknowledgedRecoveryKey(
      recoveryKey: "first-account-key",
      recoveryWrappedAccountKey: try ProductSyncKeyMaterial.create().recoveryWrappedAccountKey
    )
    try store.saveUnacknowledgedRecoveryKey(
      recoveryKey,
      productAccountId: "first-product-account"
    )

    XCTAssertNil(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: "second-product-account")
    )
    try store.clearUnacknowledgedRecoveryKey(productAccountId: "second-product-account")
    XCTAssertEqual(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: "first-product-account"),
      recoveryKey
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
