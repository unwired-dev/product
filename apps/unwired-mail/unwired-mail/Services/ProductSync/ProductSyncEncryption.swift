import CryptoKit
import Foundation
import Security

enum ProductSyncEncryptionError: LocalizedError, Equatable {
  case decryptionFailed
  case encryptionFailed
  case invalidKeyLength
  case invalidRecoveryKey
  case randomBytesFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .decryptionFailed:
      return "Encrypted Product Sync payload could not be decrypted."
    case .encryptionFailed:
      return "Encrypted Product Sync payload could not be created."
    case .invalidKeyLength:
      return "Product Sync key material must be 32 bytes."
    case .invalidRecoveryKey:
      return "Recovery Key is invalid."
    case .randomBytesFailed(let status):
      return "Secure random generation failed with status \(status)."
    }
  }
}

struct ProductSyncRecoveryKey: Codable, Equatable {
  static let prefix = "uwrk_"

  let rawValue: String

  init(rawValue: String) throws {
    guard rawValue.hasPrefix(Self.prefix) else {
      throw ProductSyncEncryptionError.invalidRecoveryKey
    }
    let encodedKey = String(rawValue.dropFirst(Self.prefix.count))
    guard
      let keyData = Data(productSyncBase64URLEncoded: encodedKey),
      keyData.count == ProductSyncKeyMaterial.keyByteCount
    else {
      throw ProductSyncEncryptionError.invalidRecoveryKey
    }

    self.rawValue = rawValue
  }

  init(keyData: Data) throws {
    guard keyData.count == ProductSyncKeyMaterial.keyByteCount else {
      throw ProductSyncEncryptionError.invalidKeyLength
    }

    rawValue = Self.prefix + keyData.productSyncBase64URLString()
  }

  func keyData() throws -> Data {
    let encodedKey = String(rawValue.dropFirst(Self.prefix.count))
    guard let keyData = Data(productSyncBase64URLEncoded: encodedKey) else {
      throw ProductSyncEncryptionError.invalidRecoveryKey
    }

    return keyData
  }
}

struct ProductSyncEncryptedPayload: Codable, Equatable {
  static let algorithmName = "AES-GCM-256"

  let algorithm: String
  let ciphertextBase64: String
  let keyVersion: Int
  let nonceBase64: String
  let schemaVersion: Int
  let tagBase64: String
}

struct ProductSyncKeyMaterialSnapshot: Codable, Equatable {
  let accountKeyBase64: String
  let recoveryKeyRawValue: String
  let recoveryWrappedAccountKey: ProductSyncEncryptedPayload
}

struct ProductSyncKeyMaterial: Equatable {
  static let keyByteCount = 32

  private static let recoveryAssociatedData = Data(
    "dev.unwired.mail.product-sync.recovery-wrap.v1".utf8
  )

  let accountKeyData: Data
  let recoveryKey: ProductSyncRecoveryKey
  let recoveryWrappedAccountKey: ProductSyncEncryptedPayload

  init(
    accountKeyData: Data,
    recoveryKey: ProductSyncRecoveryKey,
    recoveryWrappedAccountKey: ProductSyncEncryptedPayload
  ) throws {
    guard accountKeyData.count == Self.keyByteCount else {
      throw ProductSyncEncryptionError.invalidKeyLength
    }

    self.accountKeyData = accountKeyData
    self.recoveryKey = recoveryKey
    self.recoveryWrappedAccountKey = recoveryWrappedAccountKey
  }

  init(snapshot: ProductSyncKeyMaterialSnapshot) throws {
    guard let accountKeyData = Data(base64Encoded: snapshot.accountKeyBase64) else {
      throw ProductSyncEncryptionError.invalidKeyLength
    }

    try self.init(
      accountKeyData: accountKeyData,
      recoveryKey: ProductSyncRecoveryKey(rawValue: snapshot.recoveryKeyRawValue),
      recoveryWrappedAccountKey: snapshot.recoveryWrappedAccountKey
    )
  }

  static func create() throws -> ProductSyncKeyMaterial {
    try create(
      accountKeyData: randomBytes(count: keyByteCount),
      recoveryKeyData: randomBytes(count: keyByteCount)
    )
  }

  static func create(accountKeyData: Data, recoveryKeyData: Data) throws -> ProductSyncKeyMaterial {
    guard
      accountKeyData.count == keyByteCount,
      recoveryKeyData.count == keyByteCount
    else {
      throw ProductSyncEncryptionError.invalidKeyLength
    }

    let recoveryKey = try ProductSyncRecoveryKey(keyData: recoveryKeyData)
    let recoveryWrappedAccountKey = try encrypt(
      accountKeyData,
      using: recoveryKeyData,
      associatedData: recoveryAssociatedData
    )

    return try ProductSyncKeyMaterial(
      accountKeyData: accountKeyData,
      recoveryKey: recoveryKey,
      recoveryWrappedAccountKey: recoveryWrappedAccountKey
    )
  }

  static func restore(
    recoveryKey: ProductSyncRecoveryKey,
    recoveryWrappedAccountKey: ProductSyncEncryptedPayload
  ) throws -> ProductSyncKeyMaterial {
    let recoveryKeyData = try recoveryKey.keyData()
    let accountKeyData = try decrypt(
      recoveryWrappedAccountKey,
      using: recoveryKeyData,
      associatedData: recoveryAssociatedData
    )

    return try ProductSyncKeyMaterial(
      accountKeyData: accountKeyData,
      recoveryKey: recoveryKey,
      recoveryWrappedAccountKey: recoveryWrappedAccountKey
    )
  }

  var snapshot: ProductSyncKeyMaterialSnapshot {
    ProductSyncKeyMaterialSnapshot(
      accountKeyBase64: accountKeyData.base64EncodedString(),
      recoveryKeyRawValue: recoveryKey.rawValue,
      recoveryWrappedAccountKey: recoveryWrappedAccountKey
    )
  }

  func encryptPayload(
    _ plaintext: Data,
    associatedData: Data = Data()
  ) throws -> ProductSyncEncryptedPayload {
    try Self.encrypt(plaintext, using: accountKeyData, associatedData: associatedData)
  }

  func decryptPayload(
    _ payload: ProductSyncEncryptedPayload,
    associatedData: Data = Data()
  ) throws -> Data {
    try Self.decrypt(payload, using: accountKeyData, associatedData: associatedData)
  }

  private static func encrypt(
    _ plaintext: Data,
    using keyData: Data,
    associatedData: Data
  ) throws -> ProductSyncEncryptedPayload {
    guard keyData.count == keyByteCount else {
      throw ProductSyncEncryptionError.invalidKeyLength
    }

    do {
      let sealedBox = try AES.GCM.seal(
        plaintext,
        using: SymmetricKey(data: keyData),
        authenticating: associatedData
      )

      return ProductSyncEncryptedPayload(
        algorithm: ProductSyncEncryptedPayload.algorithmName,
        ciphertextBase64: sealedBox.ciphertext.base64EncodedString(),
        keyVersion: 1,
        nonceBase64: sealedBox.nonce.data.base64EncodedString(),
        schemaVersion: 1,
        tagBase64: sealedBox.tag.base64EncodedString()
      )
    } catch {
      throw ProductSyncEncryptionError.encryptionFailed
    }
  }

  private static func decrypt(
    _ payload: ProductSyncEncryptedPayload,
    using keyData: Data,
    associatedData: Data
  ) throws -> Data {
    guard
      payload.algorithm == ProductSyncEncryptedPayload.algorithmName,
      keyData.count == keyByteCount,
      let nonceData = Data(base64Encoded: payload.nonceBase64),
      let ciphertext = Data(base64Encoded: payload.ciphertextBase64),
      let tag = Data(base64Encoded: payload.tagBase64)
    else {
      throw ProductSyncEncryptionError.decryptionFailed
    }

    do {
      let nonce = try AES.GCM.Nonce(data: nonceData)
      let sealedBox = try AES.GCM.SealedBox(
        nonce: nonce,
        ciphertext: ciphertext,
        tag: tag
      )

      return try AES.GCM.open(
        sealedBox,
        using: SymmetricKey(data: keyData),
        authenticating: associatedData
      )
    } catch {
      throw ProductSyncEncryptionError.decryptionFailed
    }
  }

  private static func randomBytes(count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { buffer in
      SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else {
      throw ProductSyncEncryptionError.randomBytesFailed(status)
    }

    return data
  }
}

private extension AES.GCM.Nonce {
  var data: Data {
    withUnsafeBytes { Data($0) }
  }
}

private extension Data {
  init?(productSyncBase64URLEncoded value: String) {
    var base64 = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let paddingLength = (4 - base64.count % 4) % 4
    base64.append(String(repeating: "=", count: paddingLength))

    self.init(base64Encoded: base64)
  }

  func productSyncBase64URLString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
