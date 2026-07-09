import Foundation
import XCTest

@testable import unwired_mail

final class ProductSyncKeyMaterialStoreTests: XCTestCase {
  private var store = InMemoryProductSyncKeyMaterialStore()

  override func setUp() {
    store = InMemoryProductSyncKeyMaterialStore()
  }

  func testEnsureMaterialCreatesAndReusesLocalMaterialForProductAccount() throws {
    let firstMaterial = try store.ensureMaterial(
      productAccountId: "productAccountFixtureId",
      allowCreation: true
    )
    let secondMaterial = try store.ensureMaterial(
      productAccountId: "productAccountFixtureId",
      allowCreation: false
    )

    XCTAssertEqual(secondMaterial, firstMaterial)
    XCTAssertEqual(store.saveCount, 2)
  }

  func testEnsureMaterialRequiresRecoveryWhenCreationIsNotAllowed() {
    XCTAssertThrowsError(
      try store.ensureMaterial(
        productAccountId: "productAccountFixtureId",
        allowCreation: false
      )
    ) { error in
      XCTAssertEqual(error as? ProductSyncKeyMaterialStoreError, .recoveryRequired)
    }
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
