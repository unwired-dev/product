import CryptoKit
import Foundation

enum ProductSyncError: Error, Equatable {
  case invalidRecoveryKey
  case invalidEnrollmentCode
  // Authentication failed: wrong key, account, record, version or modified bytes.
  case rejected
}

// The opaque fields Convex stores. Everything else a payload is bound to is authenticated, never sent.
struct EncryptedPayload: Codable, Equatable {
  static let algorithmName = "AES-GCM-256"
  var algorithm = Self.algorithmName
  let ciphertextBase64: String
  let keyVersion: Int
  let nonceBase64: String
  let schemaVersion: Int
  let tagBase64: String
}

enum ProductSyncSeal {
  // Length-prefixed so that no two different contexts encode to the same bytes.
  static func binding(_ purpose: String, _ parts: [String]) -> Data {
    var data = Data()
    for part in ["dev.unwired.product-sync.v1", purpose] + parts {
      let bytes = Data(part.utf8)
      withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { data.append(contentsOf: $0) }
      data.append(bytes)
    }
    return data
  }

  // The key and schema versions travel in clear text, so they are authenticated with the context.
  static func associatedData(
    _ purpose: String, _ parts: [String], keyVersion: Int, schemaVersion: Int
  ) -> Data {
    binding(
      purpose,
      parts + [EncryptedPayload.algorithmName, String(keyVersion), String(schemaVersion)])
  }

  static func seal(
    _ plaintext: Data, using key: SymmetricKey, purpose: String, context: [String],
    keyVersion: Int, schemaVersion: Int
  ) throws -> EncryptedPayload {
    // AES-GCM draws a fresh random 96-bit nonce for every seal; none is reused or derived.
    let box = try AES.GCM.seal(
      plaintext, using: key,
      authenticating: associatedData(
        purpose, context, keyVersion: keyVersion, schemaVersion: schemaVersion))
    return EncryptedPayload(
      ciphertextBase64: box.ciphertext.base64EncodedString(), keyVersion: keyVersion,
      nonceBase64: box.nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
      schemaVersion: schemaVersion,
      tagBase64: box.tag.base64EncodedString())
  }

  static func open(
    _ payload: EncryptedPayload, using key: SymmetricKey, purpose: String, context: [String]
  ) throws -> Data {
    guard payload.algorithm == EncryptedPayload.algorithmName,
      let nonce = Data(base64Encoded: payload.nonceBase64),
      let ciphertext = Data(base64Encoded: payload.ciphertextBase64),
      let tag = Data(base64Encoded: payload.tagBase64)
    else { throw ProductSyncError.rejected }
    do {
      return try AES.GCM.open(
        AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag),
        using: key,
        authenticating: associatedData(
          purpose, context, keyVersion: payload.keyVersion, schemaVersion: payload.schemaVersion))
    } catch {
      throw ProductSyncError.rejected
    }
  }

  static func randomKey() -> Data {
    SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
  }
}

// The Product Account's sync keys: the current epoch plus any earlier epochs kept for old records.
struct ProductSyncKeyRing: Codable, Equatable {
  struct Entry: Codable, Equatable {
    let version: Int
    let key: Data
  }
  let current: Int
  let keys: [Entry]

  static func create() -> ProductSyncKeyRing {
    ProductSyncKeyRing(current: 1, keys: [Entry(version: 1, key: ProductSyncSeal.randomKey())])
  }

  func key(_ version: Int) throws -> SymmetricKey {
    guard let entry = keys.first(where: { $0.version == version }), entry.key.count == 32 else {
      throw ProductSyncError.rejected
    }
    return SymmetricKey(data: entry.key)
  }

  // Opaque to the backend, yet stable for one logical record across devices and key epochs.
  func identifier(_ kind: String, _ name: String) throws -> String {
    guard let first = keys.min(by: { $0.version < $1.version }) else {
      throw ProductSyncError.rejected
    }
    let key = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: first.key),
      info: ProductSyncSeal.binding("record-identifier", []), outputByteCount: 32)
    let mac = HMAC<SHA256>.authenticationCode(
      for: ProductSyncSeal.binding(kind, [name]), using: key)
    return kind + "." + Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  // Each record is bound to its Product Account, opaque identifier, key epoch and schema.
  func seal(record plaintext: Data, account: String, identifier: String, schemaVersion: Int)
    throws -> EncryptedPayload
  {
    try ProductSyncSeal.seal(
      plaintext, using: key(current), purpose: "record", context: [account, identifier],
      keyVersion: current, schemaVersion: schemaVersion)
  }

  func open(
    record payload: EncryptedPayload, account: String, identifier: String, schemaVersion: Int
  )
    throws -> Data
  {
    guard payload.schemaVersion == schemaVersion else { throw ProductSyncError.rejected }
    return try ProductSyncSeal.open(
      payload, using: key(payload.keyVersion), purpose: "record", context: [account, identifier])
  }
}

// A user-held 256-bit secret shown as 13 groups of Crockford base32.
struct RecoveryKey: Equatable {
  static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
  let bytes: Data

  init(bytes: Data) throws {
    guard bytes.count == 32 else { throw ProductSyncError.invalidRecoveryKey }
    self.bytes = bytes
  }

  private init(random bytes: Data) { self.bytes = bytes }

  static func generate() -> RecoveryKey { RecoveryKey(random: ProductSyncSeal.randomKey()) }

  // Accepts any case, spacing and the usual Crockford look-alikes.
  init(parsing text: String) throws {
    var value = 0
    var bits = 0
    var bytes = Data()
    var count = 0
    for character in text.uppercased() where character != "-" && !character.isWhitespace {
      let normalized: Character =
        switch character {
        case "O": "0"
        case "I", "L": "1"
        default: character
        }
      guard let digit = Self.alphabet.firstIndex(of: normalized) else {
        throw ProductSyncError.invalidRecoveryKey
      }
      value = (value << 5) | digit
      bits += 5
      count += 1
      if bits >= 8 {
        bits -= 8
        bytes.append(UInt8((value >> bits) & 0xff))
        value &= (1 << bits) - 1
      }
    }
    // 52 digits carry 256 bits; the four spare bits must be zero.
    guard count == 52, value == 0 else { throw ProductSyncError.invalidRecoveryKey }
    try self.init(bytes: bytes)
  }

  var display: String {
    var digits: [Character] = []
    var value = 0
    var bits = 0
    for byte in bytes {
      value = (value << 8) | Int(byte)
      bits += 8
      while bits >= 5 {
        bits -= 5
        digits.append(Self.alphabet[(value >> bits) & 31])
      }
      value &= (1 << bits) - 1
    }
    digits.append(Self.alphabet[(value << (5 - bits)) & 31])
    return stride(from: 0, to: digits.count, by: 4).map {
      String(digits[$0..<min($0 + 4, digits.count)])
    }.joined(separator: "-")
  }

  var lastGroup: String { String(display.suffix(4)) }

  // Setup is confirmed by re-entering the final group from the written copy.
  func confirms(_ entry: String) -> Bool {
    let normalized = entry.uppercased().filter { !$0.isWhitespace && $0 != "-" }.map {
      switch $0 {
      case "O": "0"
      case "I", "L": "1"
      default: String($0)
      }
    }.joined()
    return normalized == lastGroup
  }
}

// Authenticated envelopes that carry a key ring to a recovering or enrolling device.
enum KeyRingEnvelope {
  // Schemas 1 and 2 were the prototype's unbound wrappers; they are never opened here.
  static let recoverySchemaVersion = 3

  static func recoveryKey(_ key: RecoveryKey, account: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: key.bytes),
      info: ProductSyncSeal.binding("recovery-key", [account]), outputByteCount: 32)
  }

  static func recovery(_ ring: ProductSyncKeyRing, key: RecoveryKey, account: String) throws
    -> EncryptedPayload
  {
    try ProductSyncSeal.seal(
      JSONEncoder().encode(ring), using: recoveryKey(key, account: account), purpose: "recovery",
      context: [account], keyVersion: ring.current, schemaVersion: recoverySchemaVersion)
  }

  static func openRecovery(_ payload: EncryptedPayload, key: RecoveryKey, account: String)
    throws -> ProductSyncKeyRing
  {
    guard payload.schemaVersion == recoverySchemaVersion else { throw ProductSyncError.rejected }
    let ring = try JSONDecoder().decode(
      ProductSyncKeyRing.self,
      from: ProductSyncSeal.open(
        payload, using: recoveryKey(key, account: account), purpose: "recovery",
        context: [account]))
    guard ring.current == payload.keyVersion else { throw ProductSyncError.rejected }
    return ring
  }

  // Sealed to one enrolling device's key and bound to its account, device, request and key epoch.
  struct Enrollment: Codable, Equatable {
    let encapsulatedKey: Data
    let ciphertext: Data
  }

  struct EnrollmentBinding {
    let account: String
    let device: String
    let request: String

    func context(keyVersion: Int) -> Data {
      ProductSyncSeal.binding("enrollment", [account, device, request, String(keyVersion)])
    }
  }

  static let enrollmentSuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

  // The approval code is the pre-shared key: the backend never sees it, so it can neither
  // read keys sealed to a substituted public key nor forge an approval this device accepts.
  static func enrollment(
    _ ring: ProductSyncKeyRing, to recipient: Curve25519.KeyAgreement.PublicKey,
    code: EnrollmentCode, binding: EnrollmentBinding
  ) throws -> Enrollment {
    let context = binding.context(keyVersion: ring.current)
    var sender = try HPKE.Sender(
      recipientKey: recipient, ciphersuite: enrollmentSuite, info: context,
      presharedKey: code.presharedKey, presharedKeyIdentifier: EnrollmentCode.identifier)
    let ciphertext = try sender.seal(JSONEncoder().encode(ring), authenticating: context)
    return Enrollment(encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext)
  }

  static func openEnrollment(
    _ envelope: Enrollment, with key: Curve25519.KeyAgreement.PrivateKey, code: EnrollmentCode,
    binding: EnrollmentBinding, keyVersion: Int
  ) throws -> ProductSyncKeyRing {
    let context = binding.context(keyVersion: keyVersion)
    let ring: ProductSyncKeyRing
    do {
      var recipient = try HPKE.Recipient(
        privateKey: key, ciphersuite: enrollmentSuite, info: context,
        encapsulatedKey: envelope.encapsulatedKey, presharedKey: code.presharedKey,
        presharedKeyIdentifier: EnrollmentCode.identifier)
      ring = try JSONDecoder().decode(
        ProductSyncKeyRing.self,
        from: recipient.open(envelope.ciphertext, authenticating: context))
    } catch {
      throw ProductSyncError.rejected
    }
    // Every epoch must be a usable key, and the current one the epoch the approval claims.
    guard ring.current == keyVersion, ring.keys.contains(where: { $0.version == keyVersion }),
      ring.keys.allSatisfy({ $0.key.count == 32 })
    else { throw ProductSyncError.rejected }
    return ring
  }
}

// A one-time code the enrolling device shows and the person types on the approving device.
struct EnrollmentCode: Equatable {
  static let identifier = Data("dev.unwired.enrollment-code.v1".utf8)
  // 55 random Crockford digits (275 bits) meet HPKE's 256-bit PSK entropy minimum.
  // A final check digit catches most typing mistakes.
  static let randomDigitCount = 55
  static let digitCount = randomDigitCount + 1
  let digits: String

  static func generate() -> EnrollmentCode {
    let random = String(
      (0..<randomDigitCount).map { _ in RecoveryKey.alphabet[Int.random(in: 0..<32)] })
    return EnrollmentCode(checked: random)
  }

  private init(checked random: String) { digits = random + Self.check(random) }

  // Accepts any case, spacing and the usual Crockford look-alikes.
  init(parsing text: String) throws {
    let normalized = String(
      text.uppercased().filter { $0 != "-" && !$0.isWhitespace }.map {
        switch $0 {
        case "O": "0"
        case "I", "L": "1"
        default: $0
        }
      })
    guard normalized.count == Self.digitCount, normalized.allSatisfy(RecoveryKey.alphabet.contains),
      String(normalized.suffix(1)) == Self.check(String(normalized.prefix(Self.randomDigitCount)))
    else { throw ProductSyncError.invalidEnrollmentCode }
    digits = normalized
  }

  private static func check(_ random: String) -> String {
    let digest = SHA256.hash(data: ProductSyncSeal.binding("enrollment-code-check", [random]))
    return String(RecoveryKey.alphabet[Int(Array(digest)[0] & 31)])
  }

  var display: String {
    stride(from: 0, to: Self.digitCount, by: 4).map {
      String(digits.dropFirst($0).prefix(4))
    }.joined(separator: "-")
  }

  var presharedKey: SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: Data(digits.utf8)),
      info: ProductSyncSeal.binding("enrollment-code", []), outputByteCount: 32)
  }
}
