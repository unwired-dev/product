import Foundation
import XCTest

@testable import unwired_mail

final class ProductSyncKeyMaterialStoreTests: XCTestCase {
  private var store = InMemoryProductSyncKeyMaterialStore()

  override func setUp() {
    store = InMemoryProductSyncKeyMaterialStore()
  }

  func testEnsureMaterialCreatesAndReusesLocalMaterialForProductAccount() throws {
    let firstMaterial = try store.ensureMaterial(productAccountId: "productAccountFixtureId")
    let secondMaterial = try store.ensureMaterial(productAccountId: "productAccountFixtureId")

    XCTAssertEqual(secondMaterial, firstMaterial)
  }

  func testRestorePersistsRecoveryKeyMaterialForProductAccount() throws {
    let originalMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 9, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 10, count: ProductSyncKeyMaterial.keyByteCount)
    )

    let restoredMaterial = try store.restore(
      productAccountId: "productAccountFixtureId",
      recoveryKey: originalMaterial.recoveryKey,
      recoveryWrappedAccountKey: originalMaterial.recoveryWrappedAccountKey
    )

    XCTAssertEqual(restoredMaterial.accountKeyData, originalMaterial.accountKeyData)
    XCTAssertEqual(try store.load(productAccountId: "productAccountFixtureId"), restoredMaterial)
  }
}
