import Foundation
import Testing

@testable import unwired_mail

@Suite(.serialized)
final class ProductSyncEncryptionTests {
  @Test
  func testEncryptsAndDecryptsPayloadWithAccountKey() throws {
    let material = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 1, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 2, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let plaintext = Data("custom category: travel".utf8)
    let associatedData = Data("payload-001".utf8)

    let encrypted = try material.encryptPayload(plaintext, associatedData: associatedData)
    let decrypted = try material.decryptPayload(encrypted, associatedData: associatedData)

    #expect(decrypted == plaintext)
    #expect(!(encrypted.ciphertextBase64.contains("custom category")))
  }

  @Test
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

    #expect(try restored.decryptPayload(encrypted) == Data("synced payload".utf8))
  }

  @Test
  func testSnapshotRejectsLegacyKeyVersionsThatNormalizeToTheSameInteger() throws {
    let material = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 3, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 4, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let snapshot = material.snapshot
    let duplicateKeyData = Data(
      repeating: 5,
      count: ProductSyncKeyMaterial.keyByteCount
    ).base64EncodedString()
    let corrupted = ProductSyncKeyMaterialSnapshot(
      accountKeyBase64: snapshot.accountKeyBase64,
      accountKeyVersion: snapshot.accountKeyVersion,
      legacyAccountKeysBase64: ["2": duplicateKeyData, "02": duplicateKeyData],
      recoveryKeyRawValue: snapshot.recoveryKeyRawValue,
      recoveryWrappedAccountKey: snapshot.recoveryWrappedAccountKey
    )

    #expect {
      try ProductSyncKeyMaterial(snapshot: corrupted)
    } throws: { error in
      #expect(error as? ProductSyncEncryptionError == .invalidKeyLength)
      return true
    }
  }

  @Test
  func testRotationProtectsFuturePayloadsAndRecoveryRetainsEarlierEpochs() throws {
    let original = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 3, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 4, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let earlierPayload = try original.encryptPayload(Data("earlier payload".utf8))
    let rotated = try original.rotatingAccountKey(
      toVersion: 2,
      accountKeyData: Data(repeating: 5, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let transition = try original.encryptedTransition(
      to: rotated,
      productAccountId: "product-account-001"
    )
    let adopted = try original.applyingTransition(
      transition,
      keyVersion: 2,
      productAccountId: "product-account-001"
    )
    let futurePayload = try adopted.encryptPayload(Data("future payload".utf8))

    #expect(earlierPayload.keyVersion == 1)
    #expect(futurePayload.keyVersion == 2)
    #expect(adopted == rotated)
    #expect(throws: (any Error).self) { try original.decryptPayload(futurePayload) }

    let recovered = try ProductSyncKeyMaterial.restore(
      recoveryKey: rotated.recoveryKey,
      recoveryWrappedAccountKey: rotated.recoveryWrappedAccountKey
    )
    #expect(try recovered.decryptPayload(earlierPayload) == Data("earlier payload".utf8))
    #expect(try recovered.decryptPayload(futurePayload) == Data("future payload".utf8))
  }

  @Test
  func testRotationAdoptsWithAnOlderDeviceLocalRecoveryKey() throws {
    let olderRecoveryDevice = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 9, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 10, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let replacementRecoveryDevice = try olderRecoveryDevice.replacingRecoveryKey(
      with: Data(repeating: 11, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let rotated = try replacementRecoveryDevice.rotatingAccountKey(
      toVersion: 2,
      accountKeyData: Data(repeating: 12, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let transition = try replacementRecoveryDevice.encryptedTransition(
      to: rotated,
      productAccountId: "product-account-001"
    )

    let adopted = try olderRecoveryDevice.applyingTransition(
      transition,
      keyVersion: 2,
      productAccountId: "product-account-001"
    )
    let futurePayload = try rotated.encryptPayload(Data("future payload".utf8))

    #expect(adopted.accountKeyVersion == 2)
    #expect(adopted.recoveryKey == olderRecoveryDevice.recoveryKey)
    #expect(try adopted.decryptPayload(futurePayload) == Data("future payload".utf8))
    #expect(adopted.recoveryWrappedAccountKey != rotated.recoveryWrappedAccountKey)
  }

  @Test
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

    #expect {
      try unrelatedMaterial.decryptPayload(encrypted)
    } throws: { error in
      #expect(error as? ProductSyncEncryptionError == .decryptionFailed)
      return true
    }
  }

  @Test
  func testInvalidRecoveryKeyIsRejected() {
    #expect {
      try ProductSyncRecoveryKey(rawValue: "password-reset-token")
    } throws: { error in
      #expect(error as? ProductSyncEncryptionError == .invalidRecoveryKey)
      return true
    }
  }
}
