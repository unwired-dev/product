// swiftlint:disable file_length function_body_length
// Integrated security journeys keep their setup, rejected transitions and final outcomes together.
import CryptoKit
import Foundation
import Testing

@testable import PrivateInbox

// Convex's Product Sync rules: one recovery envelope per account, compare-and-set records, Pending
// Devices that only a live Trusted Device at the newest key epoch or the Recovery Key admits.
@MainActor final class SyntheticProductSyncBackend {
  struct PendingDevice {
    let account: String
    let installation: String
    var publicKey: Curve25519.KeyAgreement.PublicKey?
    var approval: (keyVersion: Int, envelope: KeyRingEnvelope.Enrollment, approver: String)?
    var expiresAt: Double
    // The key epoch a matching Recovery Key proof authorized.
    var recovered: Int?
  }
  var recovery: [String: EncryptedPayload] = [:]
  // The digest of the proof of the Recovery Key that opens the committed recovery envelope.
  var verifiers: [String: String] = [:]
  var records: [String: [String: StoredPayload]] = [:]
  // Each account's Draft delivery claims and the Trusted Device holding each.
  var claims: [String: [String: String]] = [:]
  // Runs before each record write, as another device's write that lands first.
  var beforePut: ((String, String) throws -> Void)?
  // Controls read-back independently of the CAS response.
  var beforeList: ((String, String) throws -> Void)?
  // Pending Devices by id; each ends with its request unless it is renewed or approved.
  var pending: [String: PendingDevice] = [:]
  var revoked: Set<String> = []
  var initializations = 0
  var offline = false
  // A Pending Device's admission cannot reach the backend, which admits nobody.
  var failCompletion = false
  // Admission commits, but the Pending Device never receives its Trusted Device receipt.
  var loseCompletionReply = false
  var clock = 1_000.0
  // Key rotation: the committed epoch and recovery record time, at most one pending epoch with its
  // transition, recovery envelope and verifier, and the epoch each Trusted Device acknowledged.
  var committed: [String: Int] = [:]
  var recoveryUpdatedAt: [String: Double] = [:]
  struct Rotation {
    let epoch: Int
    let transition: EncryptedPayload
    let recovery: EncryptedPayload
    let verifier: String
  }
  var rotations: [String: Rotation] = [:]
  var epochs: [String: Int] = [:]
  var devices: [String: [String]] = [:]
  // The next removal applies but its reply is lost.
  var loseReply = false
  // The removal reply arrives, but the following synchronization cannot reach the backend.
  var offlineAfterRevocation = false

  func epoch(_ account: String) -> Int { rotations[account]?.epoch ?? committed[account] ?? 1 }

  // Product Sign-In admits a returning Trusted Device, or the first device of an account without
  // keys or Trusted Devices. Any other device waits as a Pending Device; a removed one is refused.
  func connect(_ account: String, device installation: String) throws -> ProductRegistrationReceipt
  {
    let id = "device-" + installation
    guard !revoked.contains(id) else { throw RegistrationError.revoked }
    func receipt(_ id: String, pending: Bool? = nil) -> ProductRegistrationReceipt {
      ProductRegistrationReceipt(
        productAccountId: account, trustedDeviceId: id,
        trustedDeviceCredential: String(repeating: "a", count: 64), pending: pending,
        productSyncMaterialInitialized: recovery[account] != nil)
    }
    if devices[account]?.contains(id) == true { return receipt(id) }
    if devices[account, default: []].isEmpty, recovery[account] == nil {
      devices[account, default: []].append(id)
      epochs[id] = committed[account] ?? 1
      return receipt(id)
    }
    // A record that ended is replaced by a new Pending Device.
    if let open = pending.first(where: {
      $0.value.installation == installation && $0.value.expiresAt > clock
    }) {
      return receipt(open.key, pending: true)
    }
    let pendingId = "pending-" + UUID().uuidString
    pending = pending.filter { $0.value.installation != installation }
    pending[pendingId] = PendingDevice(
      account: account, installation: installation, expiresAt: clock + 900_000)
    return receipt(pendingId, pending: true)
  }

  // Every call presents a live Trusted Device of the account.
  func trusted(_ product: ProductRegistrationReceipt) throws {
    guard !offline else { throw RegistrationError.unavailable }
    guard !revoked.contains(product.trustedDeviceId) else { throw RegistrationError.revoked }
    guard product.pending != true,
      devices[product.productAccountId]?.contains(product.trustedDeviceId) == true
    else { throw RegistrationError.unavailable }
  }

  // Admission calls present the caller's own Pending Device, unexpired unless it reads its status.
  func pendingDevice(_ product: ProductRegistrationReceipt, expired: Bool = false) throws
    -> PendingDevice
  {
    guard !offline else { throw RegistrationError.unavailable }
    guard product.pending == true, let device = pending[product.trustedDeviceId],
      device.account == product.productAccountId, expired || device.expiresAt > clock
    else { throw RegistrationError.pendingDeviceUnavailable }
    return device
  }

  // An approval authorizes only while its approver is trusted and its epoch is still the newest.
  func approvalStillTrusted(_ device: PendingDevice) -> Bool {
    guard let approval = device.approval else { return false }
    return approval.keyVersion == epoch(device.account)
      && devices[device.account]?.contains(approval.approver) == true
  }

  // An open request of the caller's account that a Trusted Device can still approve or decline.
  func openRequest(_ product: ProductRegistrationReceipt, _ id: String) throws -> PendingDevice {
    guard let device = pending[id], device.account == product.productAccountId,
      device.expiresAt > clock, device.publicKey != nil
    else { throw RegistrationError.enrollmentUnavailable }
    return device
  }

  var backend: ProductSyncBackend {
    ProductSyncBackend(
      initialize: { [self] _, product, envelope, verifier in
        try trusted(product)
        let account = product.productAccountId
        if let existing = recovery[account] { return existing == envelope }
        recovery[account] = envelope
        verifiers[account] = verifier
        recoveryUpdatedAt[account] = clock
        initializations += 1
        return true
      },
      list: { [self] _, product, prefix in
        try trusted(product)
        try beforeList?(product.productAccountId, prefix)
        return (records[product.productAccountId] ?? [:]).values
          .filter { $0.payloadIdentifier.hasPrefix(prefix) }
          .sorted { $0.payloadIdentifier < $1.payloadIdentifier }
      },
      put: { [self] _, product, identifier, payload, expected in
        try trusted(product)
        try beforePut?(product.productAccountId, identifier)
        guard payload.keyVersion == epoch(product.productAccountId) else {
          throw RegistrationError.unavailable
        }
        let existing = records[product.productAccountId]?[identifier]
        if let existing, existing.updatedAt != expected { return existing }
        // As Convex does, a compare-and-set against a record that no longer exists is refused.
        if existing == nil, expected != nil { throw ProductSyncWriteFailure.payloadChanged }
        clock += 1
        let stored = StoredPayload(
          payloadIdentifier: identifier, encryptedPayload: payload, updatedAt: clock)
        records[product.productAccountId, default: [:]][identifier] = stored
        return stored
      },
      // A new request replaces the earlier key, so an approval sealed to it is never collected.
      requestEnrollment: { [self] _, product, publicKey in
        var device = try pendingDevice(product)
        guard recovery[product.productAccountId] != nil else {
          throw RegistrationError.unavailable
        }
        device.publicKey = publicKey
        device.approval = nil
        device.expiresAt = clock + 900_000
        pending[product.trustedDeviceId] = device
      },
      // A declined request, or an approval whose approver left or whose epoch was superseded,
      // reads as cancelled.
      enrollmentStatus: { [self] _, product in
        let device = try pendingDevice(product, expired: true)
        if device.expiresAt <= clock { return EnrollmentStatus(state: .expired) }
        guard device.publicKey != nil else { return EnrollmentStatus(state: .cancelled) }
        guard let approval = device.approval else { return EnrollmentStatus(state: .pending) }
        guard approvalStillTrusted(device) else { return EnrollmentStatus(state: .cancelled) }
        return EnrollmentStatus(
          state: .approved, approval: (approval.keyVersion, approval.envelope))
      },
      // Admits at the newest epoch, which the approval or the Recovery Key proof authorized.
      completeEnrollment: { [self] _, product, keyVersion in
        let device = try pendingDevice(product)
        guard !failCompletion else { throw URLError(.notConnectedToInternet) }
        let keyEpoch = epoch(product.productAccountId)
        guard keyVersion == keyEpoch,
          device.recovered == keyEpoch || approvalStillTrusted(device)
        else { return nil }
        pending[product.trustedDeviceId] = nil
        let id = "device-" + device.installation
        devices[product.productAccountId, default: []].append(id)
        epochs[id] = keyEpoch
        if loseCompletionReply {
          loseCompletionReply = false
          throw URLError(.networkConnectionLost)
        }
        return id
      },
      // During a pending rotation only the removal's replacement Recovery Key admits a device.
      recoverPending: { [self] _, product, proof in
        _ = try pendingDevice(product)
        let account = product.productAccountId
        let rotation = rotations[account]
        guard let verifier = rotation?.verifier ?? verifiers[account],
          let envelope = rotation?.recovery ?? recovery[account],
          SHA256.hash(data: Data(proof.utf8)).map({ String(format: "%02x", $0) }).joined()
            == verifier
        else { return nil }
        pending[product.trustedDeviceId]?.recovered = envelope.keyVersion
        return envelope
      },
      pendingEnrollments: { [self] _, product in
        try trusted(product)
        return pending.compactMap { id, device in
          guard let request = try? openRequest(product, id), request.approval == nil,
            let publicKey = device.publicKey
          else { return nil }
          return PendingEnrollment(
            pendingDeviceId: id, publicKey: publicKey, deviceName: "iPad",
            expiresAt: device.expiresAt)
        }
      },
      // Only a Trusted Device holding the newest epoch approves, once, the key the device showed.
      approveEnrollment: { [self] _, product, request, keyVersion, envelope in
        try trusted(product)
        guard keyVersion == epoch(product.productAccountId),
          epochs[product.trustedDeviceId] == keyVersion
        else { throw RegistrationError.unavailable }
        var device = try openRequest(product, request.pendingDeviceId)
        guard device.approval == nil,
          device.publicKey?.rawRepresentation == request.publicKey.rawRepresentation
        else { throw RegistrationError.enrollmentUnavailable }
        device.approval = (keyVersion, envelope, product.trustedDeviceId)
        device.expiresAt = clock + 900_000
        pending[request.pendingDeviceId] = device
      },
      // Any Trusted Device of the account cancels an open request; the device asks again.
      declineEnrollment: { [self] _, product, id in
        try trusted(product)
        _ = try openRequest(product, id)
        pending[id]?.publicKey = nil
        pending[id]?.approval = nil
      },
      recoveryEnvelope: { [self] _, product in
        try trusted(product)
        guard let envelope = recovery[product.productAccountId] else {
          throw RegistrationError.unavailable
        }
        return StoredPayload(
          payloadIdentifier: "product-account-recovery-v1", encryptedPayload: envelope,
          updatedAt: recoveryUpdatedAt[product.productAccountId] ?? 0)
      },
      keyRotation: { [self] _, product in
        try trusted(product)
        return rotations[product.productAccountId].map {
          KeyRotation(keyEpoch: $0.epoch, transition: $0.transition)
        }
      },
      // The pending recovery envelope and verifier are committed once every remaining device holds
      // the epoch.
      acknowledgeRotation: { [self] _, product, keyEpoch in
        try trusted(product)
        let account = product.productAccountId
        guard let rotation = rotations[account] else {
          guard committed[account] == keyEpoch else { throw RegistrationError.unavailable }
          return
        }
        guard rotation.epoch == keyEpoch else { throw RegistrationError.unavailable }
        epochs[product.trustedDeviceId] = keyEpoch
        if (devices[account] ?? []).allSatisfy({ epochs[$0] == keyEpoch }) {
          clock += 1
          recovery[account] = rotation.recovery
          verifiers[account] = rotation.verifier
          recoveryUpdatedAt[account] = clock
          committed[account] = keyEpoch
          rotations[account] = nil
        }
      },
      trustedDevices: { [self] _, product in
        try trusted(product)
        return (devices[product.productAccountId] ?? []).map {
          TrustedDevice(id: $0, name: "Device " + $0.suffix(4), registeredAt: 1_000)
        }
      },
      revoke: { [self] _, product, target, transition, wrapped, verifier, updatedAt in
        try trusted(product)
        let account = product.productAccountId
        // A completed removal answers with the current state and applies nothing new.
        if revoked.contains(target) { return }
        guard target != product.trustedDeviceId, devices[account]?.contains(target) == true,
          updatedAt == recoveryUpdatedAt[account], transition.keyVersion == committed[account] ?? 1,
          wrapped.keyVersion == epoch(account) + 1,
          wrapped.schemaVersion == KeyRingEnvelope.recoverySchemaVersion
        else { throw RegistrationError.unavailable }
        revoked.insert(target)
        devices[account]?.removeAll { $0 == target }
        rotations[account] = Rotation(
          epoch: wrapped.keyVersion, transition: transition, recovery: wrapped, verifier: verifier)
        offline = offlineAfterRevocation
        if loseReply {
          loseReply = false
          throw URLError(.networkConnectionLost)
        }
      },
      get: { [self] _, product, identifier in
        try trusted(product)
        return records[product.productAccountId]?[identifier]
      },
      claimDelivery: { [self] _, product, identifier in
        try trusted(product)
        let holder =
          claims[product.productAccountId]?[identifier] ?? product.trustedDeviceId
        claims[product.productAccountId, default: [:]][identifier] = holder
        return holder == product.trustedDeviceId
      })
  }

  // Each installation is its own device of the account its sign-in reaches.
  func store(keys: DeviceKeychain, google: SyntheticGoogleRegistrationProvider)
    -> RegistrationStore
  {
    RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, productSync: backend,
      deviceRevoked: { [self] product in revoked.contains(product.trustedDeviceId) },
      connect: { [self] identity, device, _ in
        try connect("account-" + identity.subject, device: device)
      })
  }
}

private func device() -> DeviceKeychain {
  DeviceKeychain(service: "dev.unwired.product-sync.tests.\(UUID().uuidString)")
}

// The final group with its first digit changed.
private func wrongGroup(_ key: RecoveryKey) -> String {
  (key.lastGroup.first == "0" ? "1" : "0") + key.lastGroup.dropFirst()
}

private func remove(_ keys: DeviceKeychain, accounts: [String]) {
  try? keys.remove("registration")
  for account in accounts {
    try? keys.remove("product-sync." + account)
    try? keys.remove("product-sync-enrollment." + account)
  }
}

extension PrivateInboxTests {
  @Test func productSyncEnvelopesBindKeyVersionsContextAndRejectTampering() throws {
    let ring = ProductSyncKeyRing.create()
    let plaintext = Data(#"{"provider":"gmail","address":"same@example.invalid"}"#.utf8)
    let first = try ring.seal(
      record: plaintext, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
    let second = try ring.seal(
      record: plaintext, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
    // Every seal uses a fresh nonce, so equal records never produce equal ciphertext.
    #expect(first.nonceBase64 != second.nonceBase64)
    #expect(first.ciphertextBase64 != second.ciphertextBase64)
    #expect(Data(base64Encoded: first.nonceBase64)?.count == 12)
    #expect(first.keyVersion == 1)
    #expect(
      try ring.open(record: second, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
        == plaintext)

    func flipped(_ base64: String) -> String {
      var bytes = Data(base64Encoded: base64) ?? Data()
      bytes[0] ^= 1
      return bytes.base64EncodedString()
    }
    let tampered = [
      EncryptedPayload(
        ciphertextBase64: flipped(first.ciphertextBase64), keyVersion: 1,
        nonceBase64: first.nonceBase64, schemaVersion: 1, tagBase64: first.tagBase64),
      EncryptedPayload(
        ciphertextBase64: first.ciphertextBase64, keyVersion: 1,
        nonceBase64: flipped(first.nonceBase64), schemaVersion: 1, tagBase64: first.tagBase64),
      EncryptedPayload(
        ciphertextBase64: first.ciphertextBase64, keyVersion: 1, nonceBase64: first.nonceBase64,
        schemaVersion: 1, tagBase64: flipped(first.tagBase64)),
      EncryptedPayload(
        algorithm: "AES-GCM-128", ciphertextBase64: first.ciphertextBase64, keyVersion: 1,
        nonceBase64: first.nonceBase64, schemaVersion: 1, tagBase64: first.tagBase64),
    ]
    for payload in tampered {
      #expect(throws: ProductSyncError.rejected) {
        try ring.open(
          record: payload, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
      }
    }
    // The record is bound to its account, identifier and schema; another account's keys fail.
    for (account, identifier, schema) in [
      ("account-b", "mailbox.1", 1), ("account-a", "mailbox.2", 1), ("account-a", "mailbox.1", 2),
    ] {
      #expect(throws: ProductSyncError.rejected) {
        try ring.open(
          record: first, account: account, identifier: identifier, schemaVersion: schema)
      }
    }
    #expect(throws: ProductSyncError.rejected) {
      try ProductSyncKeyRing.create().open(
        record: first, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
    }
    // A later epoch still opens earlier records but rejects a relabelled key version.
    let rotated = ProductSyncKeyRing(
      current: 2,
      keys: ring.keys + [.init(version: 2, key: ProductSyncSeal.randomKey())])
    #expect(
      try rotated.open(
        record: first, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
        == plaintext)
    let relabelled = EncryptedPayload(
      ciphertextBase64: first.ciphertextBase64, keyVersion: 2, nonceBase64: first.nonceBase64,
      schemaVersion: 1, tagBase64: first.tagBase64)
    #expect(throws: ProductSyncError.rejected) {
      try rotated.open(
        record: relabelled, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
    }
    let current = try rotated.seal(
      record: plaintext, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
    #expect(current.keyVersion == 2)
    #expect(throws: ProductSyncError.rejected) {
      try ring.open(
        record: current, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
    }
    // Opaque identifiers are stable across epochs and differ between Product Accounts.
    let identifier = try ring.identifier("mailbox", "gmail:synthetic-subject")
    #expect(identifier.hasPrefix("mailbox."))
    #expect(!identifier.contains("synthetic"))
    #expect(try rotated.identifier("mailbox", "gmail:synthetic-subject") == identifier)
    #expect(
      try ProductSyncKeyRing.create().identifier("mailbox", "gmail:synthetic-subject") != identifier
    )
  }

  @Test func recoveryAndEnrollmentEnvelopesOpenOnlyForTheirAccountAndRecipient() throws {
    let ring = ProductSyncKeyRing.create()
    let key = RecoveryKey.generate()
    // The written form parses back regardless of case, separators or look-alike letters.
    #expect(key.display.count == 64)
    #expect(try RecoveryKey(parsing: key.display) == key)
    #expect(
      try RecoveryKey(
        parsing: key.display.lowercased().replacingOccurrences(of: "-", with: " ")
          .replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "l")) == key
    )
    #expect(throws: ProductSyncError.invalidRecoveryKey) {
      try RecoveryKey(parsing: String(key.display.dropLast()))
    }
    #expect(throws: ProductSyncError.invalidRecoveryKey) {
      try RecoveryKey(parsing: String(key.display.dropLast()) + "U")
    }
    #expect(key.confirms(key.lastGroup.lowercased()))
    #expect(!key.confirms(wrongGroup(key)))

    let envelope = try KeyRingEnvelope.recovery(ring, key: key, account: "account-a")
    #expect(envelope.schemaVersion == KeyRingEnvelope.recoverySchemaVersion)
    #expect(try KeyRingEnvelope.openRecovery(envelope, key: key, account: "account-a") == ring)
    // An authenticated but unusable ring must not make a recovering device appear unlocked.
    for invalid in [
      ProductSyncKeyRing(current: 1, keys: []),
      ProductSyncKeyRing(current: 2, keys: ring.keys),
      ProductSyncKeyRing(current: 1, keys: [.init(version: 1, key: Data(repeating: 0, count: 31))]),
    ] {
      let malformed = try KeyRingEnvelope.recovery(invalid, key: key, account: "account-a")
      #expect(throws: ProductSyncError.rejected) {
        try KeyRingEnvelope.openRecovery(malformed, key: key, account: "account-a")
      }
    }
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRecovery(envelope, key: .generate(), account: "account-a")
    }
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRecovery(envelope, key: key, account: "account-b")
    }
    // Convex compares the SHA-256 of the 64-hex proof with the verifier it stores; the proof is
    // bound to the account.
    let proof = KeyRingEnvelope.recoveryProof(key, account: "account-a")
    #expect(proof.wholeMatch(of: /[0-9a-f]{64}/) != nil)
    #expect(
      KeyRingEnvelope.recoveryVerifier(key, account: "account-a")
        == SHA256.hash(data: Data(proof.utf8)).map { String(format: "%02x", $0) }.joined())
    #expect(proof != KeyRingEnvelope.recoveryProof(key, account: "account-b"))
    for (keyVersion, schemaVersion) in [(2, 3), (1, 2)] {
      #expect(throws: ProductSyncError.rejected) {
        try KeyRingEnvelope.openRecovery(
          EncryptedPayload(
            ciphertextBase64: envelope.ciphertextBase64, keyVersion: keyVersion,
            nonceBase64: envelope.nonceBase64, schemaVersion: schemaVersion,
            tagBase64: envelope.tagBase64), key: key, account: "account-a")
      }
    }

    // The approval code reads back like the Recovery Key and catches a mistyped digit.
    let code = EnrollmentCode.generate()
    #expect(code.digits.count == 56)
    #expect(code.display.count == 69)
    #expect(try EnrollmentCode(parsing: code.display.lowercased()) == code)
    #expect(
      try EnrollmentCode(parsing: code.display.replacingOccurrences(of: "-", with: " ")) == code)
    let mistyped =
      String(code.digits.dropLast()) + (code.digits.last == "0" ? "1" : "0")
    #expect(throws: ProductSyncError.invalidEnrollmentCode) {
      try EnrollmentCode(parsing: mistyped)
    }
    #expect(throws: ProductSyncError.invalidEnrollmentCode) {
      try EnrollmentCode(parsing: String(code.digits.dropLast()))
    }

    #expect(throws: ProductSyncError.invalidEnrollmentCode) {
      try EnrollmentCode(parsing: "H4KP-9QWE-3TRM-7XB2")
    }

    let enrolling = Curve25519.KeyAgreement.PrivateKey()
    let sealed = try KeyRingEnvelope.enrollment(
      ring, to: enrolling.publicKey, code: code,
      binding: .init(account: "account-a", device: "device-b"))
    #expect(
      try KeyRingEnvelope.openEnrollment(
        sealed, with: enrolling, code: code,
        binding: .init(account: "account-a", device: "device-b"),
        keyVersion: 1) == ring)
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openEnrollment(
        sealed, with: Curve25519.KeyAgreement.PrivateKey(), code: code,
        binding: .init(account: "account-a", device: "device-b"),
        keyVersion: 1)
    }
    // Only the code the enrolling device showed opens it, so the backend cannot forge one.
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openEnrollment(
        sealed, with: enrolling, code: .generate(),
        binding: .init(account: "account-a", device: "device-b"),
        keyVersion: 1)
    }
    for (account, device, keyVersion) in [
      ("account-b", "device-b", 1), ("account-a", "device-c", 1), ("account-a", "device-b", 2),
    ] {
      #expect(throws: ProductSyncError.rejected) {
        try KeyRingEnvelope.openEnrollment(
          sealed, with: enrolling, code: code, binding: .init(account: account, device: device),
          keyVersion: keyVersion)
      }
    }
  }

  @Test @MainActor func newAccountInitializesProductSyncOnceAndRelaunchKeepsItsKeys() async throws {
    let keys = device()
    defer { remove(keys, accounts: ["account-synthetic-product-subject"]) }
    let google = SyntheticGoogleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    let registered = try await backend.store(keys: keys, google: google).signIn()
    #expect(registered["privateSync"] == "recovery-key")
    let shown = try RecoveryKey(parsing: try #require(registered["recoveryKey"]))
    // The published envelope restores the device-held keys with the displayed Recovery Key only.
    let account = "account-synthetic-product-subject"
    let ring = try KeyRingEnvelope.openRecovery(
      try #require(backend.recovery[account]), key: shown, account: account)
    #expect(try backend.store(keys: keys, google: google).loadVault(account)?.ring == ring)
    #expect(backend.initializations == 1)
    // Its verifier, published with it, lets the Recovery Key admit a Pending Device later.
    #expect(backend.verifiers[account] == KeyRingEnvelope.recoveryVerifier(shown, account: account))

    google.scopes = [RegistrationStore.gmailScope]
    google.subject = "synthetic-mailbox-subject"
    let store = backend.store(keys: keys, google: google)
    let connected = try await store.authorizeGmail()
    #expect(connected["kind"] == "connected")
    #expect(connected["privateSyncMailboxes"] == "same@example.invalid")
    // Signing in again, as offered for pending setup, rechecks the mailbox without new consent.
    google.subject = "synthetic-product-subject"
    let sessions = google.hints.count
    #expect(try await backend.store(keys: keys, google: google).signIn() == connected)
    #expect(google.hints.count == sessions + 1)
    google.subject = "synthetic-mailbox-subject"
    let records = try #require(backend.records[account])
    #expect(records.count == 1)
    // Convex holds only opaque identifiers and ciphertext; no address, subject or credential.
    let visible =
      try String(decoding: JSONEncoder().encode(records), as: UTF8.self)
      + String(decoding: JSONEncoder().encode(backend.recovery), as: UTF8.self)
    for secret in [
      "same@example.invalid", "synthetic-mailbox-subject", "synthetic-access-token",
      shown.display,
    ] {
      #expect(!visible.contains(secret))
    }

    #expect(throws: RegistrationError.recoveryKeyMismatch) {
      try store.flowConfirmRecoveryKey(wrongGroup(shown))
    }
    let confirmed = try store.flowConfirmRecoveryKey(shown.lastGroup.lowercased())
    #expect(confirmed["privateSync"] == "ready")
    #expect(confirmed["recoveryKey"] == nil)

    // A record sealed for another Product Account is never presented as this account's mailbox.
    let foreign = ProductSyncKeyRing.create()
    backend.records[account]?["mailbox.foreign"] = StoredPayload(
      payloadIdentifier: "mailbox.foreign",
      encryptedPayload: try foreign.seal(
        record: JSONEncoder().encode(
          MailboxDescriptor(provider: "gmail", address: "x@example.invalid")),
        account: "account-other", identifier: "mailbox.foreign", schemaVersion: 1),
      updatedAt: 1)

    // Relaunch recovers the same keys and the decrypted record without generating anything.
    let relaunched = try await backend.store(keys: keys, google: google).restore()
    var expected = connected.merging(["privateSync": "ready"]) { $1 }
    expected["recoveryKey"] = nil
    #expect(relaunched == expected)
    #expect(backend.initializations == 1)
    #expect(try backend.store(keys: keys, google: google).loadVault(account)?.ring == ring)
  }

  @Test @MainActor func mailboxDescriptorsThisDeviceCannotOpenAreNeverReplaced() async throws {
    let keys = device()
    let account = "account-synthetic-product-subject"
    defer { remove(keys, accounts: [account]) }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let backend = SyntheticProductSyncBackend()
    _ = try await backend.store(keys: keys, google: google).signIn()
    google.subject = "synthetic-mailbox-subject"
    _ = try await backend.store(keys: keys, google: google).authorizeGmail()
    google.subject = "synthetic-product-subject"
    let ring = try #require(try backend.store(keys: keys, google: google).loadVault(account)?.ring)
    let identifier = try ring.identifier("mailbox", "gmail:synthetic-mailbox-subject")
    #expect(backend.records[account]?.keys.sorted() == [identifier])

    func sealed(_ address: String, with keys: ProductSyncKeyRing = ring, schema: Int = 1) throws
      -> EncryptedPayload
    {
      try keys.seal(
        record: JSONEncoder().encode(MailboxDescriptor(provider: "gmail", address: address)),
        account: account, identifier: identifier, schemaVersion: schema)
    }
    // Stores the record in place of this device's descriptor, then signs in to synchronize.
    func signInOver(_ payload: EncryptedPayload) async throws -> (StoredPayload, [String: String]) {
      let stored = StoredPayload(
        payloadIdentifier: identifier, encryptedPayload: payload, updatedAt: 1)
      backend.records[account]?[identifier] = stored
      return (stored, try await backend.store(keys: keys, google: google).signIn())
    }

    // A newer client's schema, an epoch this device lacks and a record failing authentication at
    // the current schema and epoch are all read-only: never shown, never replaced.
    let rotated = ProductSyncKeyRing(
      current: 2, keys: ring.keys + [.init(version: 2, key: ProductSyncSeal.randomKey())])
    let current = try sealed("tampered@example.invalid")
    var ciphertext = try #require(Data(base64Encoded: current.ciphertextBase64))
    ciphertext[0] ^= 1
    let tampered = EncryptedPayload(
      ciphertextBase64: ciphertext.base64EncodedString(), keyVersion: current.keyVersion,
      nonceBase64: current.nonceBase64, schemaVersion: current.schemaVersion,
      tagBase64: current.tagBase64)
    for payload in [
      try sealed("newer@example.invalid", schema: MailboxDescriptor.schemaVersion + 1),
      try sealed("rotated@example.invalid", with: rotated), tampered,
    ] {
      let (stored, signedIn) = try await signInOver(payload)
      #expect(backend.records[account]?[identifier] == stored)
      #expect(signedIn["kind"] == "connected")
      #expect(signedIn["privateSyncMailboxes"] == nil)
    }

    // A record that opens at the current schema and differs is replaced and read back.
    let (stale, signedIn) = try await signInOver(sealed("stale@example.invalid"))
    let replaced = try #require(backend.records[account]?[identifier])
    #expect(replaced != stale)
    #expect(signedIn["privateSyncMailboxes"] == "same@example.invalid")
  }

  @Test @MainActor func missingLocalKeysNeverReplaceAnExistingAccountsKeyMaterial() async throws {
    let first = device()
    let second = device()
    let account = "account-synthetic-product-subject"
    defer {
      remove(first, accounts: [account])
      remove(second, accounts: [account])
    }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let backend = SyntheticProductSyncBackend()

    // An interrupted first publication keeps the saved keys and finishes them later.
    backend.offline = true
    let pending = try await backend.store(keys: first, google: google).signIn()
    #expect(pending["privateSync"] == "setup-pending")
    let saved = try #require(try backend.store(keys: first, google: google).loadVault(account))
    #expect(backend.recovery[account] == nil)

    // Another installation waits as a Pending Device and never creates keys of its own.
    backend.offline = false
    let waiting = try await backend.store(keys: second, google: google).signIn()
    #expect(waiting["kind"] == "device-pending")
    #expect(waiting["privateSync"] == "setup-pending")
    #expect(waiting["enrollmentCode"] == nil)
    #expect(try backend.store(keys: second, google: google).loadVault(account) == nil)
    #expect(backend.initializations == 0)

    // Meanwhile the backend reports key material this device did not publish.
    let key = RecoveryKey.generate()
    let ring = ProductSyncKeyRing.create()
    backend.recovery[account] = try KeyRingEnvelope.recovery(ring, key: key, account: account)
    backend.verifiers[account] = KeyRingEnvelope.recoveryVerifier(key, account: account)
    let published = try #require(backend.recovery[account])
    #expect(published != saved.recoveryEnvelope)

    // The first device discards its unpublished keys instead of replacing the account's.
    let resumed = try await backend.store(keys: first, google: google).restore()
    #expect(resumed["privateSync"] == "enrollment-needed")
    #expect(resumed["recoveryKey"] == nil)
    #expect(try backend.store(keys: first, google: google).loadVault(account) == nil)
    #expect(backend.recovery[account] == published)
    #expect(backend.initializations == 0)

    // Gmail stays authorizable, but no record is written without the account's keys.
    let connected = try await backend.store(keys: first, google: google).authorizeGmail()
    #expect(connected["kind"] == "connected")
    #expect(connected["privateSync"] == "enrollment-needed")
    #expect(backend.records[account] == nil)
    #expect(throws: RegistrationError.unavailable) {
      try backend.store(keys: first, google: google).flowConfirmRecoveryKey("0000")
    }

    // The account's Recovery Key unlocks this Trusted Device from the recovery envelope directly.
    let unlocked = try await backend.store(keys: first, google: google).flowRecover(with: key.display)
    #expect(unlocked["privateSync"] == "ready")
    #expect(unlocked["privateSyncMailboxes"] == "same@example.invalid")
    #expect(try backend.store(keys: first, google: google).loadVault(account)?.ring == ring)
    #expect(backend.recovery[account] == published)

    // The waiting installation now asks a Trusted Device for the keys.
    let requested = try await backend.store(keys: second, google: google).refreshPrivateSync()
    #expect(requested["kind"] == "device-pending")
    #expect(requested["privateSync"] == "enrollment-pending")
    #expect(requested["enrollmentCode"] != nil)
    #expect(backend.initializations == 0)
  }

  @Test @MainActor func unknownProductSyncStateWaitsForVerificationWithoutCreatingKeys()
    async throws
  {
    let keys = device()
    let account = "account-synthetic-apple-subject"
    defer { remove(keys, accounts: [account]) }
    let google = SyntheticGoogleRegistrationProvider()
    let apple = SyntheticAppleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    var legacy = true
    func store() -> RegistrationStore {
      RegistrationStore(
        keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
        provider: google, apple: apple, productSync: backend.backend,
        connect: { identity, device, _ in
          var receipt = try backend.connect("account-" + identity.subject, device: device)
          if legacy { receipt.productSyncMaterialInitialized = nil }
          return receipt
        })
    }
    // A receipt without Product Sync state, as saved before this slice, neither creates keys
    // nor demands enrollment; Apple restore cannot reconnect, so it offers sign-in again.
    #expect(try await store().signIn(with: .apple)["privateSync"] == "setup-pending")
    #expect(try await store().restore()["privateSync"] == "setup-pending")
    #expect(try store().loadVault(account) == nil)
    #expect(backend.initializations == 0)
    // Signing in again reports the account's actual state, which initializes it.
    legacy = false
    #expect(try await store().signIn(with: .apple)["privateSync"] == "recovery-key")
    #expect(backend.initializations == 1)
  }

  @Test @MainActor func unreadableProductSyncKeysLeaveRegistrationAndGmailUsable() async throws {
    let keys = device()
    let account = "account-synthetic-product-subject"
    defer { remove(keys, accounts: [account]) }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let backend = SyntheticProductSyncBackend()
    _ = try await backend.store(keys: keys, google: google).signIn()
    let ring = try #require(try backend.store(keys: keys, google: google).loadVault(account)).ring
    // A malformed item, then another Product Account's keys stored under this account's item.
    for vault in [
      Data("malformed".utf8),
      try JSONEncoder().encode(ProductSyncVault(productAccountId: "account-other", ring: ring)),
    ] {
      try keys.save(vault, account: "product-sync." + account)
      google.subject = "synthetic-mailbox-subject"
      let connected = try await backend.store(keys: keys, google: google).authorizeGmail()
      #expect(connected["kind"] == "connected")
      #expect(connected["privateSync"] == "unavailable")
      #expect(try await backend.store(keys: keys, google: google).restore() == connected)
      google.subject = "synthetic-product-subject"
      #expect(try await backend.store(keys: keys, google: google).signIn() == connected)
      #expect(try backend.store(keys: keys, google: google).load()?.mailboxSetupReason == nil)
      // The unreadable keys are kept, never replaced.
      #expect(try keys.read("product-sync." + account) == vault)
    }
    #expect(backend.initializations == 1)
  }

  @Test @MainActor func appleRelaunchAsksToSignInAgainBeforeSavingANewMailbox() async throws {
    let keys = device()
    let account = "account-synthetic-apple-subject"
    defer { remove(keys, accounts: [account]) }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let apple = SyntheticAppleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    func store() -> RegistrationStore {
      RegistrationStore(
        keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
        provider: google, apple: apple, productSync: backend.backend,
        connect: { identity, device, _ in
          try backend.connect("account-" + identity.subject, device: device)
        })
    }
    let first = store()
    _ = try await first.signIn(with: .apple)
    google.subject = "synthetic-mailbox-subject"
    #expect(try await first.authorizeGmail()["privateSyncPending"] == nil)
    // An Apple relaunch cannot reach Convex but still shows the list it last decrypted.
    #expect(try await store().restore()["privateSyncMailboxes"] == "same@example.invalid")
    // After relaunch Apple has no backend session, so a newly chosen mailbox waits for sign-in.
    google.mailboxAddresses = [
      "synthetic-mailbox-subject": "same@example.invalid",
      "synthetic-other-mailbox": "other@example.invalid",
    ]
    google.subject = "synthetic-other-mailbox"
    let reselected = try await store().authorizeGmail(chooseAccount: true)
    #expect(reselected["kind"] == "connected")
    #expect(reselected["privateSyncPending"] == "mailbox")
    #expect(backend.records[account]?.count == 1)
    // Signing in again saves the descriptor and reads both back.
    let signedIn = try await store().signIn(with: .apple)
    #expect(signedIn["privateSyncPending"] == nil)
    #expect(signedIn["privateSyncMailboxes"] == "other@example.invalid\nsame@example.invalid")
    #expect(backend.records[account]?.count == 2)
  }

  @Test @MainActor func trustedDeviceApprovalUnlocksANewDeviceWithoutReplacingAccountKeys()
    async throws
  {
    let trusted = device()
    let new = device()
    let account = "account-synthetic-product-subject"
    defer {
      remove(trusted, accounts: [account])
      remove(new, accounts: [account])
    }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let backend = SyntheticProductSyncBackend()
    // The first device creates the account keys and saves its mailbox to Product Sync.
    let approver = backend.store(keys: trusted, google: google)
    _ = try await approver.signIn()
    google.subject = "synthetic-mailbox-subject"
    #expect(try await approver.authorizeGmail()["kind"] == "connected")
    google.subject = "synthetic-product-subject"
    let recovery = try #require(backend.recovery[account])
    let ring = try #require(try approver.loadVault(account)?.ring)

    // The same Product Sign-In on another installation only waits as a Pending Device: it holds no
    // keys and cannot authorize Gmail.
    let enrolling = backend.store(keys: new, google: google)
    let requested = try await enrolling.signIn()
    #expect(requested["kind"] == "device-pending")
    #expect(requested["privateSync"] == "enrollment-pending")
    #expect(requested["privateSyncMailboxes"] == nil)
    let firstCode = try #require(requested["enrollmentCode"])
    #expect(try enrolling.loadVault(account) == nil)
    let pendingId = try #require(try enrolling.load()?.product?.trustedDeviceId)
    await #expect(throws: RegistrationError.unavailable) {
      try await enrolling.authorizeGmail()
    }

    // The trusted device sees the request; a mistyped code is caught before anything is sent.
    let listed = try await approver.refreshPrivateSync()
    #expect(listed["enrollmentRequest"] == pendingId)
    #expect(listed["enrollmentDevice"] == "iPad")
    let typo = String(firstCode.dropLast()) + (firstCode.last == "0" ? "1" : "0")
    await #expect(throws: RegistrationError.enrollmentCodeInvalid) {
      try await approver.flowApproveEnrollment(pendingId, code: typo)
    }
    #expect(backend.pending[pendingId]?.approval == nil)

    // A declined request ends; the new device asks again with a new code.
    _ = try await approver.flowDeclineEnrollment(pendingId)
    let renewed = try await enrolling.refreshPrivateSync()
    #expect(renewed["privateSync"] == "enrollment-pending")
    #expect(renewed["enrollmentNotice"] == "renewed")
    let secondCode = try #require(renewed["enrollmentCode"])
    #expect(secondCode != firstCode)

    // An approval sealed with the previous code does not open: the device stays pending, asks with
    // a new code and keeps no keys.
    #expect(try await approver.refreshPrivateSync()["enrollmentRequest"] == pendingId)
    _ = try await approver.flowApproveEnrollment(pendingId, code: firstCode)
    let rejected = try await enrolling.refreshPrivateSync()
    #expect(rejected["kind"] == "device-pending")
    #expect(rejected["enrollmentNotice"] == "rejected")
    #expect(try enrolling.loadVault(account) == nil)
    let thirdCode = try #require(rejected["enrollmentCode"])
    #expect(![firstCode, secondCode].contains(thirdCode))

    // An expired request cannot be approved; reconnecting replaces the ended Pending Device.
    #expect(try await approver.refreshPrivateSync()["enrollmentRequest"] == pendingId)
    backend.clock += 900_001
    await #expect(throws: RegistrationError.enrollmentUnavailable) {
      try await approver.flowApproveEnrollment(pendingId, code: thirdCode)
    }
    let expired = try await enrolling.refreshPrivateSync()
    #expect(expired["privateSync"] == "enrollment-pending")
    let code = try #require(expired["enrollmentCode"])
    #expect(code != thirdCode)
    let request = try #require(try enrolling.load()?.product?.trustedDeviceId)
    #expect(request != pendingId)
    #expect(backend.pending[pendingId] == nil)

    // The code shown on the new device, typed loosely, approves exactly its request.
    #expect(try await approver.refreshPrivateSync()["enrollmentRequest"] == request)
    let approved = try await approver.flowApproveEnrollment(
      request, code: code.lowercased().replacingOccurrences(of: "-", with: " "))
    #expect(approved["enrollmentRequest"] == nil)
    #expect(approved["privateSync"] == "recovery-key")
    // Replaying the approval is refused; the backend saw no code and no plaintext keys.
    await #expect(throws: RegistrationError.enrollmentUnavailable) {
      try await approver.flowApproveEnrollment(request, code: code)
    }
    let sealed = try #require(backend.pending[request]?.approval)
    let visible = try #require(String(data: JSONEncoder().encode(sealed.envelope), encoding: .utf8))
    for secret in [code, code.replacingOccurrences(of: "-", with: "")]
      + ring.keys.map({ $0.key.base64EncodedString() })
    {
      #expect(!visible.contains(secret))
    }

    // The new device adopts the account keys, becomes a Trusted Device with the same credential
    // and reads the synchronized mailbox list; Gmail on this device still needs its own consent.
    let unlocked = try await enrolling.refreshPrivateSync()
    #expect(unlocked["kind"] == "mailbox-needed")
    #expect(unlocked["privateSync"] == "ready")
    #expect(unlocked["recoveryKey"] == nil)
    #expect(unlocked["enrollmentCode"] == nil)
    #expect(unlocked["privateSyncMailboxes"] == "same@example.invalid")
    #expect(try enrolling.loadVault(account)?.ring == ring)
    #expect(try new.read("product-sync-enrollment." + account) == nil)
    let admitted = try #require(try enrolling.load()?.product)
    #expect(admitted.pending == nil)
    #expect(admitted.trustedDeviceId == backend.devices[account]?.last)
    #expect(admitted.trustedDeviceCredential == String(repeating: "a", count: 64))
    #expect(backend.pending[request] == nil)
    google.subject = "synthetic-mailbox-subject"
    #expect(try await enrolling.authorizeGmail()["kind"] == "connected")
    google.subject = "synthetic-product-subject"
    // Nothing replaced the account's key material.
    #expect(backend.recovery[account] == recovery)
    #expect(backend.initializations == 1)
    #expect(try approver.loadVault(account)?.ring == ring)
    #expect(
      try await backend.store(keys: new, google: google).restore()["privateSync"] == "ready")
  }

  @Test @MainActor func recoveryKeyUnlocksANewDeviceWithoutReplacingAccountKeys() async throws {
    let trusted = device()
    let new = device()
    let appleDevice = device()
    let account = "account-synthetic-product-subject"
    defer {
      remove(trusted, accounts: [account])
      remove(new, accounts: [account])
      remove(appleDevice, accounts: [account])
    }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let backend = SyntheticProductSyncBackend()
    // The lost device created the account keys, showed the Recovery Key and saved its mailbox.
    let lost = backend.store(keys: trusted, google: google)
    let shown = try #require(try await lost.signIn()["recoveryKey"])
    google.subject = "synthetic-mailbox-subject"
    #expect(try await lost.authorizeGmail()["kind"] == "connected")
    google.subject = "synthetic-product-subject"
    let recovery = try #require(backend.recovery[account])
    let ring = try #require(try lost.loadVault(account)?.ring)

    // Product Sign-In on a new installation only waits as a Pending Device.
    let recovering = backend.store(keys: new, google: google)
    let requested = try await recovering.signIn()
    #expect(requested["kind"] == "device-pending")
    #expect(requested["privateSync"] == "enrollment-pending")

    // Malformed, unrelated and another account's keys unlock nothing and change nothing, even
    // when the backend accepts that key's proof and substitutes that account's envelope. Each
    // reports the current status.
    let other = RecoveryKey.generate()
    var rejected = requested
    rejected["recoveryNotice"] = "rejected"
    for entry in [String(shown.dropLast()), "0000", other.display] {
      #expect(try await recovering.flowRecover(with: entry) == rejected)
    }
    backend.recovery[account] = try KeyRingEnvelope.recovery(
      .create(), key: other, account: "account-other")
    backend.verifiers[account] = KeyRingEnvelope.recoveryVerifier(other, account: account)
    #expect(try await recovering.flowRecover(with: other.display) == rejected)
    backend.recovery[account] = recovery
    backend.verifiers[account] = KeyRingEnvelope.recoveryVerifier(
      try RecoveryKey(parsing: shown), account: account)
    #expect(try recovering.loadVault(account) == nil)
    #expect(try recovering.load()?.product?.pending == true)
    // When the Pending Device ended while the form was open, the sign-in the attempt renews also
    // replaces it, and the rejection shows the new code rather than the superseded one.
    backend.clock += 900_001
    let renewed = try await recovering.flowRecover(with: other.display)
    #expect(renewed["recoveryNotice"] == "rejected")
    let code = try #require(renewed["enrollmentCode"])
    #expect(code != requested["enrollmentCode"])
    let request = try #require(try recovering.load()?.product?.trustedDeviceId)
    // An interrupted recovery leaves the device waiting for approval, also after relaunch.
    backend.offline = true
    await #expect(throws: RegistrationError.unavailable) {
      try await recovering.flowRecover(with: shown)
    }
    backend.offline = false
    let relaunched = try await backend.store(keys: new, google: google).restore()
    #expect(relaunched["privateSync"] == "enrollment-pending")
    #expect(relaunched["enrollmentCode"] == code)
    #expect(relaunched["recoveryNotice"] == nil)
    #expect(try recovering.loadVault(account) == nil)
    #expect(backend.pending[request]?.publicKey != nil)

    // The written key, typed loosely, adopts the account keys and admits this device; it reads
    // the synchronized mailbox list, while Gmail on this device still needs its own authorization.
    let unlocked = try await backend.store(keys: new, google: google).flowRecover(
      with: shown.lowercased().replacingOccurrences(of: "-", with: " "))
    #expect(unlocked["kind"] == "mailbox-needed")
    #expect(unlocked["privateSync"] == "ready")
    #expect(unlocked["recoveryKey"] == nil)
    #expect(unlocked["enrollmentCode"] == nil)
    #expect(unlocked["privateSyncMailboxes"] == "same@example.invalid")
    #expect(try recovering.loadVault(account)?.ring == ring)
    #expect(try recovering.loadVault(account)?.recoveryKey == nil)
    #expect(try recovering.load()?.product?.pending == nil)
    // Its Pending Device and request are gone; nothing replaced the account's key material.
    #expect(backend.pending[request] == nil)
    #expect(try new.read("product-sync-enrollment." + account) == nil)
    #expect(backend.recovery[account] == recovery)
    #expect(backend.initializations == 1)
    #expect(try lost.loadVault(account)?.ring == ring)
    let restored = try await backend.store(keys: new, google: google).restore()
    #expect(restored["privateSync"] == "ready")
    #expect(restored["privateSyncMailboxes"] == "same@example.invalid")

    // This account's synthetic Apple sign-in reaches the same account on another installation.
    let apple = SyntheticAppleRegistrationProvider()
    func appleStore() -> RegistrationStore {
      RegistrationStore(
        keys: appleDevice, deployment: "https://synthetic.example.invalid",
        clientID: "synthetic-client", provider: google, apple: apple, productSync: backend.backend,
        connect: { _, device, _ in try backend.connect(account, device: device) })
    }
    let appleRecovery = appleStore()
    #expect(try await appleRecovery.signIn(with: .apple)["privateSync"] == "enrollment-pending")
    // Recovery must reauthenticate even with a process session. A different identity or a
    // cancelled renewal cannot adopt the account keys, and a later retry uses fresh sign-in.
    let subject = apple.subject
    apple.subject = "another-apple-subject"
    await #expect(throws: RegistrationError.invalidIdentity) {
      try await appleRecovery.flowRecover(with: shown)
    }
    #expect(try appleRecovery.loadVault(account) == nil)
    apple.subject = subject
    apple.outcome = .cancelled
    await #expect(throws: RegistrationError.cancelled) {
      try await appleRecovery.flowRecover(with: shown)
    }
    #expect(try appleRecovery.loadVault(account) == nil)
    apple.outcome = nil
    #expect(try await appleRecovery.flowRecover(with: shown)["privateSync"] == "ready")
    #expect(try appleRecovery.loadVault(account)?.ring == ring)
    #expect(try await appleStore().restore()["privateSyncMailboxes"] == "same@example.invalid")
    #expect(backend.recovery[account] == recovery)
    #expect(backend.initializations == 1)

    // The backend never received the Recovery Key or the account keys.
    let visible = try #require(
      String(
        data: JSONEncoder().encode(backend.records) + JSONEncoder().encode(backend.recovery)
          + JSONEncoder().encode(backend.verifiers), encoding: .utf8))
    for secret in [shown, shown.replacingOccurrences(of: "-", with: "")]
      + ring.keys.map({ $0.key.base64EncodedString() })
    {
      #expect(!visible.contains(secret))
    }
  }

  @Test @MainActor func interruptedRecoveryDoesNotAcknowledgeANewerApprovalWithOlderKeys()
    async throws
  {
    let (creator, kept, lost, joining) = (device(), device(), device(), device())
    let account = "account-synthetic-product-subject"
    defer { for keys in [creator, kept, lost, joining] { remove(keys, accounts: [account]) } }
    let google = SyntheticGoogleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    let remover = backend.store(keys: creator, google: google)
    let shown = try #require(try await remover.signIn()["recoveryKey"])
    _ = try remover.flowConfirmRecoveryKey(String(shown.suffix(4)))
    let survivor = backend.store(keys: kept, google: google)
    _ = try await survivor.signIn()
    _ = try await survivor.flowRecover(with: shown)
    let removed = backend.store(keys: lost, google: google)
    _ = try await removed.signIn()
    _ = try await removed.flowRecover(with: shown)
    let newcomer = backend.store(keys: joining, google: google)
    let code = try #require(try await newcomer.signIn()["enrollmentCode"])
    backend.failCompletion = true
    await #expect(throws: URLError.self) { try await newcomer.flowRecover(with: shown) }
    backend.failCompletion = false
    #expect(try newcomer.loadVault(account)?.ring.current == 1)
    let removedId = try #require(try removed.load()?.product?.trustedDeviceId)
    _ = try await remover.flowRevoke(removedId)
    let request = try #require(try await survivor.refreshPrivateSync()["enrollmentRequest"])
    _ = try await survivor.flowApproveEnrollment(request, code: code)
    // Refresh must open and persist the epoch-2 approval before admitting/acknowledging it.
    #expect(try await newcomer.refreshPrivateSync()["privateSync"] == "ready")
    #expect(try newcomer.load()?.product?.pending == nil)
    #expect(try newcomer.loadVault(account)?.ring == survivor.loadVault(account)?.ring)
    #expect(try newcomer.loadVault(account)?.ring.current == 2)
  }

  @Test @MainActor func revokingADeviceRotatesKeysForRemainingDevicesAndPurgesItOnReconnect()
    async throws
  {
    let (creator, kept, lost, joining) = (device(), device(), device(), device())
    let account = "account-synthetic-product-subject"
    defer {
      for keys in [creator, kept, lost, joining] { remove(keys, accounts: [account]) }
    }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let backend = SyntheticProductSyncBackend()
    // The first device creates the keys and saves its mailbox; two more unlock with the Recovery Key.
    let remover = backend.store(keys: creator, google: google)
    let shown = try #require(try await remover.signIn()["recoveryKey"])
    _ = try remover.flowConfirmRecoveryKey(String(shown.suffix(4)))
    google.subject = "synthetic-mailbox-subject"
    #expect(try await remover.authorizeGmail()["kind"] == "connected")
    google.subject = "synthetic-product-subject"
    let survivor = backend.store(keys: kept, google: google)
    _ = try await survivor.signIn()
    #expect(try await survivor.flowRecover(with: shown)["privateSync"] == "ready")
    let removed = backend.store(keys: lost, google: google)
    _ = try await removed.signIn()
    #expect(try await removed.flowRecover(with: shown)["privateSync"] == "ready")
    let removedId = try #require(try removed.load()?.product?.trustedDeviceId)
    let oldRing = try #require(try removed.loadVault(account)?.ring)
    let oldRecovery = try #require(backend.recovery[account])

    // Just before its removal, the lost device approves a new installation, which stores the keys
    // but cannot confirm its admission yet.
    let newcomer = backend.store(keys: joining, google: google)
    let firstCode = try #require(try await newcomer.signIn()["enrollmentCode"])
    let request = try #require(try await removed.refreshPrivateSync()["enrollmentRequest"])
    _ = try await removed.flowApproveEnrollment(request, code: firstCode)
    backend.failCompletion = true
    #expect(try await newcomer.refreshPrivateSync()["kind"] == "device-pending")
    backend.failCompletion = false
    #expect(try newcomer.loadVault(account)?.ring == oldRing)

    // The trusted device lists the other two and removes one after signing in again.
    let listed = try #require(try await remover.refreshPrivateSync()["trustedDevices"])
    let devices = try JSONDecoder().decode([TrustedDevice].self, from: Data(listed.utf8))
    #expect(devices.count == 2)
    #expect(devices.contains { $0.id == removedId })
    let signIns = google.hints.count
    let result = try await remover.flowRevoke(removedId)
    #expect(google.hints.count == signIns + 1)
    #expect(result["revocationNotice"] == "removed")
    // A new Recovery Key wraps the new epoch; the old one stops opening new data.
    #expect(result["privateSync"] == "recovery-key")
    let newKey = try #require(result["recoveryKey"])
    #expect(newKey != shown)
    let remaining = try #require(result["trustedDevices"])
    #expect(!remaining.contains(removedId))
    let ring = try #require(try remover.loadVault(account)?.ring)
    #expect(ring.current == 2)
    #expect(oldRing.keys.allSatisfy(ring.keys.contains))
    #expect(
      try backend.rotations[account]?.verifier
        == KeyRingEnvelope.recoveryVerifier(RecoveryKey(parsing: newKey), account: account))
    // The approval ended with its approver and the epoch it sealed: the device discards the keys
    // it stored and asks again.
    let renewed = try await newcomer.refreshPrivateSync()
    #expect(renewed["kind"] == "device-pending")
    #expect(renewed["enrollmentNotice"] == "renewed")
    let code = try #require(renewed["enrollmentCode"])
    #expect(code != firstCode)
    #expect(try newcomer.loadVault(account) == nil)
    #expect(try newcomer.load()?.product?.pending == true)
    // Another removal must not discard the sole new Recovery Key before it was backed up: it
    // shows that key again and removes nothing.
    let survivorId = try #require(try survivor.load()?.product?.trustedDeviceId)
    let blocked = try await remover.flowRevoke(survivorId)
    #expect(blocked["recoveryKey"] == newKey)
    #expect(blocked["revocationNotice"] == nil)
    #expect(try remover.loadVault(account)?.recoveryKey == RecoveryKey(parsing: newKey).bytes)
    #expect(!backend.revoked.contains(survivorId))
    _ = try remover.flowConfirmRecoveryKey(String(newKey.suffix(4)))
    // The survivor has not adopted it yet, so the account keeps its committed recovery envelope.
    #expect(backend.rotations[account]?.epoch == 2)
    #expect(backend.recovery[account] == oldRecovery)

    // The removed device purges its account data and credentials when it next reconnects.
    // A failed registration read must still drop the in-process session and lists. Keep the
    // durable registration locator so a later successful read can retry the account cleanup.
    let registration = try #require(try lost.read("registration"))
    #expect(removed.session != nil)
    try lost.save(Data("invalid-registration".utf8), account: "registration")
    await #expect(throws: DecodingError.self) {
      try await removed.purgingIfRevoked { _ in throw RegistrationError.revoked }
    }
    #expect(removed.session == nil)
    #expect(removed.enrollmentRequests.isEmpty)
    #expect(removed.trustedDevices.isEmpty)
    #expect(try lost.read("registration") != nil)
    #expect(try lost.read("product-sync." + account) != nil)
    try lost.save(registration, account: "registration")
    // Still open, the removed device tries a removal of its own: it purges before any sign-in
    // prompt, so cancelling that prompt cannot keep its keys.
    let prompts = google.hints.count
    google.outcome = .cancelled
    #expect(
      try await removed.purgingIfRevoked { try await $0.flowRevoke(survivorId) }
        == ["kind": "signed-out", "notice": "revoked"])
    #expect(google.hints.count == prompts)
    google.outcome = nil
    for item in ["registration", "product-sync." + account, "product-sync-enrollment." + account] {
      #expect(try lost.read(item) == nil)
    }
    // Signing in again mints a new device identifier, which only waits as a Pending Device. The
    // previous Recovery Key admits nobody while the removal's rotation is pending.
    let returned = try await removed.purgingIfRevoked { try await $0.signIn() }
    #expect(returned["kind"] == "device-pending")
    #expect(returned["privateSync"] == "enrollment-pending")
    #expect(try await removed.flowRecover(with: shown)["recoveryNotice"] == "rejected")
    #expect(try lost.read("product-sync." + account) == nil)

    // The survivor adopts the new epoch from a key it holds; then the rotation completes.
    #expect(try await survivor.refreshPrivateSync()["privateSync"] == "ready")
    #expect(try survivor.loadVault(account)?.ring == ring)
    #expect(backend.rotations[account] == nil)
    let committed = try #require(backend.recovery[account])
    #expect(
      try KeyRingEnvelope.openRecovery(
        committed, key: RecoveryKey(parsing: newKey), account: account) == ring)
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRecovery(
        committed, key: RecoveryKey(parsing: shown), account: account)
    }
    #expect(try await removed.flowRecover(with: shown)["recoveryNotice"] == "rejected")
    #expect(try lost.read("product-sync." + account) == nil)
    // The survivor, which listed it while adopting, seals the new epoch to the waiting device; it
    // is admitted at that epoch.
    _ = try await survivor.flowApproveEnrollment(request, code: code)
    #expect(try await newcomer.refreshPrivateSync()["privateSync"] == "ready")
    #expect(try newcomer.loadVault(account)?.ring == ring)

    // A mailbox saved at the new epoch reaches the survivor, but not the removed device's keys.
    google.subject = "synthetic-other-mailbox"
    google.address = "other@example.invalid"
    #expect(try await remover.authorizeGmail(chooseAccount: true)["kind"] == "connected")
    google.subject = "synthetic-product-subject"
    #expect(
      try await survivor.refreshPrivateSync()["privateSyncMailboxes"]
        == "other@example.invalid\nsame@example.invalid")
    let saved = try #require(
      backend.records[account]?.values.first { $0.encryptedPayload.keyVersion == 2 })
    #expect(throws: ProductSyncError.rejected) {
      try oldRing.open(
        record: saved.encryptedPayload, account: account, identifier: saved.payloadIdentifier,
        schemaVersion: MailboxDescriptor.schemaVersion)
    }

    // Success from removal is not success adopting its keys. Preserve the pending transition
    // and the confirmed Recovery Key until synchronization can adopt this exact removal.
    backend.offlineAfterRevocation = true
    let unconfirmed = try await remover.flowRevoke(survivorId)
    #expect(unconfirmed["revocationNotice"] == "unconfirmed")
    #expect(unconfirmed["recoveryKey"] == nil)
    #expect(backend.revoked.contains(survivorId))
    #expect(try remover.loadVault(account)?.recoveryKey == RecoveryKey(parsing: newKey).bytes)
    #expect(try remover.loadVault(account)?.revocation != nil)
    backend.offline = false
    let adopted = try await remover.refreshPrivateSync()
    #expect(adopted["privateSync"] == "recovery-key")
    let replacement = try #require(adopted["recoveryKey"])
    #expect(replacement != newKey)
    #expect(try remover.loadVault(account)?.revocation == nil)
    _ = try await newcomer.refreshPrivateSync()
    #expect(backend.rotations[account] == nil)
    #expect(
      try KeyRingEnvelope.openRecovery(
        #require(backend.recovery[account]), key: RecoveryKey(parsing: replacement),
        account: account)
        == remover.loadVault(account)?.ring)
  }

  @Test(arguments: [false, true]) @MainActor
  func aLostRevocationReplyKeepsTheNewRecoveryKeyOnlyIfTheRemovalApplied(
    retryAnotherDevice: Bool
  ) async throws {
    let (creator, other, kept, joining) = (device(), device(), device(), device())
    let account = "account-synthetic-product-subject"
    defer {
      for keys in [creator, other, kept, joining] { remove(keys, accounts: [account]) }
    }
    let google = SyntheticGoogleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    let remover = backend.store(keys: creator, google: google)
    let shown = try #require(try await remover.signIn()["recoveryKey"])
    _ = try remover.flowConfirmRecoveryKey(String(shown.suffix(4)))
    let enrolled = backend.store(keys: other, google: google)
    _ = try await enrolled.signIn()
    _ = try await enrolled.flowRecover(with: shown)
    let target = try #require(try enrolled.load()?.product?.trustedDeviceId)
    let survivor = backend.store(keys: kept, google: google)
    _ = try await survivor.signIn()
    _ = try await survivor.flowRecover(with: shown)
    let survivorId = try #require(try survivor.load()?.product?.trustedDeviceId)

    // A refused removal changes nothing and leaves no pending Recovery Key.
    await #expect(throws: RegistrationError.unavailable) {
      try await remover.flowRevoke("device-unknown")
    }
    #expect(try remover.loadVault(account)?.revocation == nil)
    #expect(backend.rotations[account] == nil)

    // The reply is lost after the removal applied. Trying again learns that it applied and shows
    // its new Recovery Key, rather than refusing to replace an unconfirmed key or removing again.
    backend.loseReply = true
    await #expect(throws: URLError.self) { try await remover.flowRevoke(target) }
    #expect(try remover.loadVault(account)?.revocation != nil)
    #expect(try remover.privateSync(remover.load()!)["privateSync"] == "ready")
    let synced = try await remover.flowRevoke(retryAnotherDevice ? survivorId : target)
    #expect(synced["revocationNotice"] == (retryAnotherDevice ? nil : "removed"))
    #expect(synced["privateSync"] == "recovery-key")
    #expect(!backend.revoked.contains(survivorId))
    let remaining = try #require(synced["trustedDevices"])
    #expect(!remaining.contains(target))
    #expect(remaining.contains(survivorId))
    let newKey = try #require(synced["recoveryKey"])
    #expect(newKey != shown)
    #expect(try remover.loadVault(account)?.revocation == nil)
    // Until the rotation completes, only this replacement Recovery Key admits a new installation,
    // which receives the new epoch with it.
    let newcomer = backend.store(keys: joining, google: google)
    _ = try await newcomer.signIn()
    #expect(try await newcomer.flowRecover(with: newKey)["privateSync"] == "ready")
    #expect(try newcomer.loadVault(account)?.ring == remover.loadVault(account)?.ring)
    #expect(backend.rotations[account] != nil)
    // Every remaining device adopts the epoch, so its recovery envelope opens with the new key.
    #expect(try await survivor.refreshPrivateSync()["privateSync"] == "ready")
    #expect(backend.rotations[account] == nil)
    #expect(
      try KeyRingEnvelope.openRecovery(
        #require(backend.recovery[account]), key: RecoveryKey(parsing: newKey), account: account)
        == remover.loadVault(account)?.ring)

    // Removing a device that is already gone applies nothing, so no new Recovery Key is claimed.
    _ = try remover.flowConfirmRecoveryKey(String(newKey.suffix(4)))
    let repeated = try await remover.flowRevoke(target)
    #expect(repeated["revocationNotice"] == "unconfirmed")
    #expect(repeated["privateSync"] == "ready")
    #expect(try remover.loadVault(account)?.recoveryKey == RecoveryKey(parsing: newKey).bytes)
    #expect(try remover.loadVault(account)?.revocation == nil)
  }

  // Guarding every operation against a revoked device is the TypeScript flow's job now. These
  // retired tests are replaced in packages/mail-core/test/registration-flow.test.ts:
  // - savedAccountPromptsPurgeRevokedDevicesBeforeCancellation and
  //   appleRestoreLearnsOfRevocationFromTheDeviceCredentialAlone: "purges a revoked … device before
  //   any prompt, and skips the check offline"

}
