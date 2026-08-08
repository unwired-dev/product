import Foundation
import Testing

@testable import unwired_mail

@Suite(.serialized)
final class ProductAccountSessionStoreTests {
  private var store = InMemoryProductAccountSessionStore()

  init() {
    store = InMemoryProductAccountSessionStore()
  }

  @Test
  func testSaveAndLoadRoundTrip() throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    try store.save(snapshot)
    let loaded = try store.load()

    #expect(loaded == snapshot)
  }

  @Test
  func testClearRemovesStoredSession() throws {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "token-001",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    try store.save(snapshot)
    try store.clear()

    #expect(try store.load() == nil)
  }

  @Test
  func testTrustedDeviceCredentialPersistenceIsScopedAndClearable() throws {
    let credentialStore = InMemoryTrustedDeviceCredentialStore()

    try credentialStore.save("credential-001", trustedDeviceId: "trusted-device-001")
    try credentialStore.save("credential-002", trustedDeviceId: "trusted-device-002")
    try credentialStore.clear(trustedDeviceId: "trusted-device-001")

    #expect(try credentialStore.load(trustedDeviceId: "trusted-device-001") == nil)
    #expect(try credentialStore.load(trustedDeviceId: "trusted-device-002") == "credential-002")
  }

  @Test
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

    #expect(try store.loadPendingTrustedDeviceUnregistrations() == [first, second])
  }

  @Test
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

    #expect(try keychainStore.loadPendingTrustedDeviceUnregistrations() == [unregistration])
  }

  @Test
  func testUnacknowledgedRecoveryKeysAreScopedToTheProductAccount() throws {
    let recoveryKey = UnacknowledgedRecoveryKey(
      recoveryKey: "first-account-key",
      recoveryWrappedAccountKey: try ProductSyncKeyMaterial.create().recoveryWrappedAccountKey
    )
    try store.saveUnacknowledgedRecoveryKey(
      recoveryKey,
      productAccountId: "first-product-account"
    )

    #expect(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: "second-product-account") == nil)
    try store.clearUnacknowledgedRecoveryKey(productAccountId: "second-product-account")
    #expect(
      try store.loadUnacknowledgedRecoveryKey(productAccountId: "first-product-account")
        == recoveryKey)
  }

  @Test
  func testIdentityTokenStateUsesVerifiedExpiration() {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "apple-token",
      identityTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    #expect(snapshot.identityTokenState(at: Date(timeIntervalSince1970: 999)) == .active)
    #expect(snapshot.identityTokenState(at: Date(timeIntervalSince1970: 1_000)) == .expired)
  }

  @Test
  func testIdentityTokenStateIsUnverifiableWithoutVerifiedExpiration() {
    let snapshot = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "e30.eyJleHAiOjEwMDB9.invalid-signature",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )

    #expect(snapshot.identityTokenState(at: Date()) == .unverifiable)
  }

  @Test
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

    #expect(snapshot.identityTokenExpiresAt == nil)
    #expect(snapshot.identityTokenState(at: Date()) == .unverifiable)
  }
}
