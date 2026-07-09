import Foundation
import XCTest

@testable import unwired_mail

final class ProductSyncEncryptionTests: XCTestCase {
  func testEncryptsAndDecryptsPayloadWithAccountKey() throws {
    let material = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 1, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 2, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let plaintext = Data("custom category: travel".utf8)
    let associatedData = Data("payload-001".utf8)

    let encrypted = try material.encryptPayload(plaintext, associatedData: associatedData)
    let decrypted = try material.decryptPayload(encrypted, associatedData: associatedData)

    XCTAssertEqual(decrypted, plaintext)
    XCTAssertFalse(encrypted.ciphertextBase64.contains("custom category"))
  }

  func testRecoveryKeyRestoresAccessToEncryptedPayloads() throws {
    let material = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 3, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 4, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let encrypted = try material.encryptPayload(Data("synced payload".utf8))

    let restored = try ProductSyncKeyMaterial.restore(
      recoveryKey: material.recoveryKey,
      recoveryWrappedAccountKey: material.recoveryWrappedAccountKey
    )

    XCTAssertEqual(try restored.decryptPayload(encrypted), Data("synced payload".utf8))
  }

  func testAccountRecoveryWithoutRecoveryKeyCannotDecryptPayloads() throws {
    let material = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 5, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 6, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let unrelatedMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 7, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 8, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let encrypted = try material.encryptPayload(Data("private product data".utf8))

    XCTAssertThrowsError(try unrelatedMaterial.decryptPayload(encrypted)) { error in
      XCTAssertEqual(error as? ProductSyncEncryptionError, .decryptionFailed)
    }
  }

  func testInvalidRecoveryKeyIsRejected() {
    XCTAssertThrowsError(try ProductSyncRecoveryKey(rawValue: "password-reset-token")) { error in
      XCTAssertEqual(error as? ProductSyncEncryptionError, .invalidRecoveryKey)
    }
  }
}
