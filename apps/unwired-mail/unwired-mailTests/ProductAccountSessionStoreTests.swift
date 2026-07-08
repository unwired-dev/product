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
}
