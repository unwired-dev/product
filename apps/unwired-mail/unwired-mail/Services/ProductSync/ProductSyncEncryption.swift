import CryptoKit
import Foundation
import Security

// swiftlint:disable file_length

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
  let accountKeyVersion: Int
  let legacyAccountKeysBase64: [String: String]
  let recoveryKeyRawValue: String
  let recoveryWrappedAccountKey: ProductSyncEncryptedPayload

  private enum CodingKeys: String, CodingKey {
    case accountKeyBase64
    case accountKeyVersion
    case legacyAccountKeysBase64
    case recoveryKeyRawValue
    case recoveryWrappedAccountKey
  }

  init(
    accountKeyBase64: String,
    accountKeyVersion: Int,
    legacyAccountKeysBase64: [String: String],
    recoveryKeyRawValue: String,
    recoveryWrappedAccountKey: ProductSyncEncryptedPayload
  ) {
    self.accountKeyBase64 = accountKeyBase64
    self.accountKeyVersion = accountKeyVersion
    self.legacyAccountKeysBase64 = legacyAccountKeysBase64
    self.recoveryKeyRawValue = recoveryKeyRawValue
    self.recoveryWrappedAccountKey = recoveryWrappedAccountKey
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountKeyBase64 = try container.decode(String.self, forKey: .accountKeyBase64)
    accountKeyVersion = try container.decodeIfPresent(Int.self, forKey: .accountKeyVersion) ?? 1
    legacyAccountKeysBase64 =
      try container.decodeIfPresent(
        [String: String].self,
        forKey: .legacyAccountKeysBase64
      ) ?? [:]
    recoveryKeyRawValue = try container.decode(String.self, forKey: .recoveryKeyRawValue)
    recoveryWrappedAccountKey = try container.decode(
      ProductSyncEncryptedPayload.self,
      forKey: .recoveryWrappedAccountKey
    )
  }
}

private struct ProductSyncRecoveryKeyRing: Codable {
  let accountKeyBase64: String
  let accountKeyVersion: Int
  let legacyAccountKeysBase64: [String: String]
}

private struct ProductSyncKeyRotationEnvelope: Codable {
  let accountKeyBase64: String
  let accountKeyVersion: Int
  let legacyAccountKeysBase64: [String: String]
  let recoveryWrappedAccountKey: ProductSyncEncryptedPayload
}

// swiftlint:disable:next type_body_length
struct ProductSyncKeyMaterial: Equatable {
  static let keyByteCount = 32

  private static let recoveryAssociatedData = Data(
    "dev.unwired.mail.product-sync.recovery-wrap.v1".utf8
  )

  let accountKeyData: Data
  let accountKeyVersion: Int
  let legacyAccountKeysData: [Int: Data]
  let recoveryKey: ProductSyncRecoveryKey
  let recoveryWrappedAccountKey: ProductSyncEncryptedPayload

  init(
    accountKeyData: Data,
    accountKeyVersion: Int = 1,
    legacyAccountKeysData: [Int: Data] = [:],
    recoveryKey: ProductSyncRecoveryKey,
    recoveryWrappedAccountKey: ProductSyncEncryptedPayload
  ) throws {
    guard
      accountKeyData.count == Self.keyByteCount,
      accountKeyVersion > 0,
      legacyAccountKeysData.allSatisfy({
        $0.key > 0 && $0.key != accountKeyVersion && $0.value.count == Self.keyByteCount
      })
    else {
      throw ProductSyncEncryptionError.invalidKeyLength
    }

    self.accountKeyData = accountKeyData
    self.accountKeyVersion = accountKeyVersion
    self.legacyAccountKeysData = legacyAccountKeysData
    self.recoveryKey = recoveryKey
    self.recoveryWrappedAccountKey = recoveryWrappedAccountKey
  }

  init(snapshot: ProductSyncKeyMaterialSnapshot) throws {
    guard let accountKeyData = Data(base64Encoded: snapshot.accountKeyBase64) else {
      throw ProductSyncEncryptionError.invalidKeyLength
    }
    let legacyAccountKeysData = try Self.decodeLegacyAccountKeys(
      snapshot.legacyAccountKeysBase64
    )

    try self.init(
      accountKeyData: accountKeyData,
      accountKeyVersion: snapshot.accountKeyVersion,
      legacyAccountKeysData: legacyAccountKeysData,
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
    let recoveryWrappedAccountKey = try recoveryWrappedAccountKey(
      accountKeyData: accountKeyData,
      accountKeyVersion: 1,
      legacyAccountKeysData: [:],
      recoveryKeyData: recoveryKeyData
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
    let recovered = try decrypt(
      recoveryWrappedAccountKey,
      using: recoveryKeyData,
      associatedData: recoveryAssociatedData
    )

    let accountKeyData: Data
    let accountKeyVersion: Int
    let legacyAccountKeysData: [Int: Data]
    if recoveryWrappedAccountKey.schemaVersion == 1 {
      accountKeyData = recovered
      accountKeyVersion = recoveryWrappedAccountKey.keyVersion
      legacyAccountKeysData = [:]
    } else if recoveryWrappedAccountKey.schemaVersion == 2 {
      let keyRing = try JSONDecoder().decode(ProductSyncRecoveryKeyRing.self, from: recovered)
      guard let decodedAccountKey = Data(base64Encoded: keyRing.accountKeyBase64) else {
        throw ProductSyncEncryptionError.invalidKeyLength
      }
      accountKeyData = decodedAccountKey
      accountKeyVersion = keyRing.accountKeyVersion
      legacyAccountKeysData = try decodeLegacyAccountKeys(
        keyRing.legacyAccountKeysBase64
      )
    } else {
      throw ProductSyncEncryptionError.decryptionFailed
    }

    return try ProductSyncKeyMaterial(
      accountKeyData: accountKeyData,
      accountKeyVersion: accountKeyVersion,
      legacyAccountKeysData: legacyAccountKeysData,
      recoveryKey: recoveryKey,
      recoveryWrappedAccountKey: recoveryWrappedAccountKey
    )
  }

  func replacingRecoveryKey() throws -> ProductSyncKeyMaterial {
    try replacingRecoveryKey(with: Self.randomBytes(count: Self.keyByteCount))
  }

  func replacingRecoveryKey(with recoveryKeyData: Data) throws -> ProductSyncKeyMaterial {
    let replacementRecoveryKey = try ProductSyncRecoveryKey(keyData: recoveryKeyData)
    return try ProductSyncKeyMaterial(
      accountKeyData: accountKeyData,
      accountKeyVersion: accountKeyVersion,
      legacyAccountKeysData: legacyAccountKeysData,
      recoveryKey: replacementRecoveryKey,
      recoveryWrappedAccountKey: Self.recoveryWrappedAccountKey(
        accountKeyData: accountKeyData,
        accountKeyVersion: accountKeyVersion,
        legacyAccountKeysData: legacyAccountKeysData,
        recoveryKeyData: recoveryKeyData
      )
    )
  }

  func rotatingAccountKey(toVersion newVersion: Int) throws -> ProductSyncKeyMaterial {
    try rotatingAccountKey(
      toVersion: newVersion,
      accountKeyData: Self.randomBytes(count: Self.keyByteCount)
    )
  }

  func rotatingAccountKey(
    toVersion newVersion: Int,
    accountKeyData newAccountKeyData: Data
  ) throws -> ProductSyncKeyMaterial {
    guard newVersion > accountKeyVersion else {
      throw ProductSyncEncryptionError.invalidKeyLength
    }
    var legacyKeys = legacyAccountKeysData
    legacyKeys[self.accountKeyVersion] = self.accountKeyData
    let recoveryKeyData = try recoveryKey.keyData()
    return try ProductSyncKeyMaterial(
      accountKeyData: newAccountKeyData,
      accountKeyVersion: newVersion,
      legacyAccountKeysData: legacyKeys,
      recoveryKey: recoveryKey,
      recoveryWrappedAccountKey: Self.recoveryWrappedAccountKey(
        accountKeyData: newAccountKeyData,
        accountKeyVersion: newVersion,
        legacyAccountKeysData: legacyKeys,
        recoveryKeyData: recoveryKeyData
      )
    )
  }

  func encryptedTransition(
    to rotatedMaterial: ProductSyncKeyMaterial,
    productAccountId: String,
    encryptingWithKeyVersion: Int? = nil
  ) throws -> ProductSyncEncryptedPayload {
    let encryptionKeyVersion = encryptingWithKeyVersion ?? accountKeyVersion
    let encryptionKeyData =
      if encryptionKeyVersion == accountKeyVersion {
        accountKeyData
      } else {
        legacyAccountKeysData[encryptionKeyVersion]
      }
    guard
      rotatedMaterial.accountKeyVersion > accountKeyVersion,
      let encryptionKeyData
    else {
      throw ProductSyncEncryptionError.encryptionFailed
    }
    return try Self.encrypt(
      JSONEncoder().encode(
        ProductSyncKeyRotationEnvelope(
          accountKeyBase64: rotatedMaterial.accountKeyData.base64EncodedString(),
          accountKeyVersion: rotatedMaterial.accountKeyVersion,
          legacyAccountKeysBase64: Dictionary(
            uniqueKeysWithValues: rotatedMaterial.legacyAccountKeysData.map {
              (String($0.key), $0.value.base64EncodedString())
            }
          ),
          recoveryWrappedAccountKey: rotatedMaterial.recoveryWrappedAccountKey
        )
      ),
      using: encryptionKeyData,
      associatedData: Self.rotationAssociatedData(
        productAccountId: productAccountId,
        keyVersion: rotatedMaterial.accountKeyVersion
      ),
      keyVersion: encryptionKeyVersion
    )
  }

  func applyingTransition(
    _ encryptedTransition: ProductSyncEncryptedPayload,
    keyVersion: Int,
    productAccountId: String
  ) throws -> ProductSyncKeyMaterial {
    let plaintext = try decryptPayload(
      encryptedTransition,
      associatedData: Self.rotationAssociatedData(
        productAccountId: productAccountId,
        keyVersion: keyVersion
      )
    )
    let envelope = try JSONDecoder().decode(ProductSyncKeyRotationEnvelope.self, from: plaintext)
    guard
      envelope.accountKeyVersion == keyVersion,
      envelope.recoveryWrappedAccountKey.keyVersion == keyVersion,
      let accountKeyData = Data(base64Encoded: envelope.accountKeyBase64)
    else {
      throw ProductSyncEncryptionError.decryptionFailed
    }
    let legacyAccountKeysData = try Self.decodeLegacyAccountKeys(
      envelope.legacyAccountKeysBase64
    )
    if let restored = try? Self.restore(
      recoveryKey: recoveryKey,
      recoveryWrappedAccountKey: envelope.recoveryWrappedAccountKey
    ), restored.accountKeyData == accountKeyData,
      restored.legacyAccountKeysData == legacyAccountKeysData
    {
      return restored
    }
    let recoveryKeyData = try recoveryKey.keyData()
    return try ProductSyncKeyMaterial(
      accountKeyData: accountKeyData,
      accountKeyVersion: keyVersion,
      legacyAccountKeysData: legacyAccountKeysData,
      recoveryKey: recoveryKey,
      recoveryWrappedAccountKey: Self.recoveryWrappedAccountKey(
        accountKeyData: accountKeyData,
        accountKeyVersion: keyVersion,
        legacyAccountKeysData: legacyAccountKeysData,
        recoveryKeyData: recoveryKeyData
      )
    )
  }

  var snapshot: ProductSyncKeyMaterialSnapshot {
    ProductSyncKeyMaterialSnapshot(
      accountKeyBase64: accountKeyData.base64EncodedString(),
      accountKeyVersion: accountKeyVersion,
      legacyAccountKeysBase64: Dictionary(
        uniqueKeysWithValues: legacyAccountKeysData.map {
          (String($0.key), $0.value.base64EncodedString())
        }
      ),
      recoveryKeyRawValue: recoveryKey.rawValue,
      recoveryWrappedAccountKey: recoveryWrappedAccountKey
    )
  }

  private static func decodeLegacyAccountKeys(
    _ encodedKeys: [String: String]
  ) throws -> [Int: Data] {
    var decodedKeys: [Int: Data] = [:]
    for (encodedVersion, encodedKey) in encodedKeys {
      guard
        let version = Int(encodedVersion),
        decodedKeys[version] == nil,
        let keyData = Data(base64Encoded: encodedKey)
      else {
        throw ProductSyncEncryptionError.invalidKeyLength
      }
      decodedKeys[version] = keyData
    }
    return decodedKeys
  }

  func encryptPayload(
    _ plaintext: Data,
    associatedData: Data = Data()
  ) throws -> ProductSyncEncryptedPayload {
    try Self.encrypt(
      plaintext,
      using: accountKeyData,
      associatedData: associatedData,
      keyVersion: accountKeyVersion
    )
  }

  func decryptPayload(
    _ payload: ProductSyncEncryptedPayload,
    associatedData: Data = Data()
  ) throws -> Data {
    let keyData =
      if payload.keyVersion == accountKeyVersion {
        accountKeyData
      } else {
        legacyAccountKeysData[payload.keyVersion]
      }
    guard let keyData else { throw ProductSyncEncryptionError.decryptionFailed }
    return try Self.decrypt(payload, using: keyData, associatedData: associatedData)
  }

  private static func recoveryWrappedAccountKey(
    accountKeyData: Data,
    accountKeyVersion: Int,
    legacyAccountKeysData: [Int: Data],
    recoveryKeyData: Data
  ) throws -> ProductSyncEncryptedPayload {
    if accountKeyVersion == 1, legacyAccountKeysData.isEmpty {
      return try encrypt(
        accountKeyData,
        using: recoveryKeyData,
        associatedData: recoveryAssociatedData
      )
    }
    let keyRing = ProductSyncRecoveryKeyRing(
      accountKeyBase64: accountKeyData.base64EncodedString(),
      accountKeyVersion: accountKeyVersion,
      legacyAccountKeysBase64: Dictionary(
        uniqueKeysWithValues: legacyAccountKeysData.map {
          (String($0.key), $0.value.base64EncodedString())
        }
      )
    )
    return try encrypt(
      JSONEncoder().encode(keyRing),
      using: recoveryKeyData,
      associatedData: recoveryAssociatedData,
      keyVersion: accountKeyVersion,
      schemaVersion: 2
    )
  }

  private static func rotationAssociatedData(
    productAccountId: String,
    keyVersion: Int
  ) -> Data {
    Data("dev.unwired.mail.product-sync.rotation.\(productAccountId).\(keyVersion)".utf8)
  }

  private static func encrypt(
    _ plaintext: Data,
    using keyData: Data,
    associatedData: Data,
    keyVersion: Int = 1,
    schemaVersion: Int = 1
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
        keyVersion: keyVersion,
        nonceBase64: sealedBox.nonce.data.base64EncodedString(),
        schemaVersion: schemaVersion,
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

extension AES.GCM.Nonce {
  fileprivate var data: Data {
    withUnsafeBytes { Data($0) }
  }
}

extension Data {
  fileprivate init?(productSyncBase64URLEncoded value: String) {
    var base64 =
      value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")

    let paddingLength = (4 - base64.count % 4) % 4
    base64.append(String(repeating: "=", count: paddingLength))

    self.init(base64Encoded: base64)
  }

  fileprivate func productSyncBase64URLString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
