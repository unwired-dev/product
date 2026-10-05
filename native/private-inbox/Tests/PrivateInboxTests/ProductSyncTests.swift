// swiftlint:disable file_length function_body_length
// Integrated security journeys keep their setup, rejected transitions and final outcomes together.
import CryptoKit
import Foundation
import Testing

@testable import PrivateInbox

// Convex's Product Sync rules: one recovery envelope per account, compare-and-set records and
// enrollment requests that only another live device of the account can approve, once.
@MainActor final class SyntheticProductSyncBackend {
  struct Request {
    let account: String
    let device: String
    let publicKey: Curve25519.KeyAgreement.PublicKey
    var state: EnrollmentStatus.State = .pending
    var approval: (keyVersion: Int, envelope: KeyRingEnvelope.Enrollment)?
    var expiresAt: Double
  }
  var recovery: [String: EncryptedPayload] = [:]
  var records: [String: [String: StoredPayload]] = [:]
  var requests: [String: Request] = [:]
  var revoked: Set<String> = []
  var initializations = 0
  var offline = false
  var clock = 1_000.0
  // Key rotation: the committed epoch and recovery record time, at most one pending epoch with its
  // transition and recovery envelope, and the epoch each device acknowledged.
  var committed: [String: Int] = [:]
  var recoveryUpdatedAt: [String: Double] = [:]
  var rotations: [String: (epoch: Int, transition: EncryptedPayload, recovery: EncryptedPayload)] =
    [:]
  var epochs: [String: Int] = [:]
  var devices: [String: [String]] = [:]
  // Accounts with a removal refuse every device identifier they have not seen before.
  var tombstoned: Set<String> = []
  // The next removal applies but its reply is lost.
  var loseReply = false
  // The removal reply arrives, but the following synchronization cannot reach the backend.
  var offlineAfterRevocation = false

  func epoch(_ account: String) -> Int { rotations[account]?.epoch ?? committed[account] ?? 1 }

  func receipt(_ account: String, device: String = "synthetic-device")
    -> ProductRegistrationReceipt
  {
    if devices[account]?.contains(device) != true {
      devices[account, default: []].append(device)
      epochs[device] = committed[account] ?? 1
    }
    return ProductRegistrationReceipt(
      productAccountId: account, trustedDeviceId: device,
      trustedDeviceCredential: String(repeating: "a", count: 64),
      productSyncMaterialInitialized: recovery[account] != nil)
  }

  // Every call presents a live Trusted Device of the account.
  func device(_ product: ProductRegistrationReceipt) throws {
    guard !offline else { throw RegistrationError.unavailable }
    guard !revoked.contains(product.trustedDeviceId) else { throw RegistrationError.revoked }
  }

  // The caller's own request; another device's or an unknown one reads as cancelled.
  func own(_ product: ProductRegistrationReceipt, _ id: String) -> Request? {
    guard let request = requests[id], request.account == product.productAccountId,
      request.device == product.trustedDeviceId
    else { return nil }
    return request
  }

  // A pending, unexpired request of the caller's account from another live device.
  func approvable(_ product: ProductRegistrationReceipt, _ id: String, requester: String? = nil)
    throws -> Request
  {
    guard let request = requests[id], request.account == product.productAccountId,
      request.state == .pending, request.expiresAt > clock,
      request.device != product.trustedDeviceId, !revoked.contains(request.device),
      requester == nil || requester == request.device
    else { throw RegistrationError.enrollmentUnavailable }
    return request
  }

  var backend: ProductSyncBackend {
    ProductSyncBackend(
      initialize: { [self] _, product, envelope in
        guard !offline else { throw RegistrationError.unavailable }
        if let existing = recovery[product.productAccountId] { return existing == envelope }
        recovery[product.productAccountId] = envelope
        recoveryUpdatedAt[product.productAccountId] = clock
        initializations += 1
        return true
      },
      list: { [self] _, product, prefix in
        guard !offline else { throw RegistrationError.unavailable }
        return (records[product.productAccountId] ?? [:]).values
          .filter { $0.payloadIdentifier.hasPrefix(prefix) }
          .sorted { $0.payloadIdentifier < $1.payloadIdentifier }
      },
      put: { [self] _, product, identifier, payload, expected in
        guard !offline else { throw RegistrationError.unavailable }
        guard payload.keyVersion == epoch(product.productAccountId) else {
          throw RegistrationError.unavailable
        }
        let existing = records[product.productAccountId]?[identifier]
        if let existing, existing.updatedAt != expected { return existing }
        clock += 1
        let stored = StoredPayload(
          payloadIdentifier: identifier, encryptedPayload: payload, updatedAt: clock)
        records[product.productAccountId, default: [:]][identifier] = stored
        return stored
      },
      requestEnrollment: { [self] _, product, publicKey in
        try device(product)
        guard recovery[product.productAccountId] != nil else {
          throw RegistrationError.unavailable
        }
        // A new request supersedes the device's earlier ones.
        requests = requests.filter { $0.value.device != product.trustedDeviceId }
        let id = "request-\(requests.count)-\(UUID().uuidString)"
        requests[id] = Request(
          account: product.productAccountId, device: product.trustedDeviceId,
          publicKey: publicKey, expiresAt: clock + 900_000)
        return id
      },
      enrollmentStatus: { [self] _, product, id in
        try device(product)
        guard let request = own(product, id) else { return EnrollmentStatus(state: .cancelled) }
        if request.expiresAt <= clock, request.state != .cancelled {
          return EnrollmentStatus(state: .expired)
        }
        return EnrollmentStatus(state: request.state, approval: request.approval)
      },
      completeEnrollment: { [self] _, product, id in
        try device(product)
        if own(product, id)?.state == .approved { requests[id] = nil }
      },
      pendingEnrollments: { [self] _, product in
        try device(product)
        return requests.compactMap { id, _ in
          guard let request = try? approvable(product, id) else { return nil }
          return PendingEnrollment(
            requestId: id, trustedDeviceId: request.device, publicKey: request.publicKey,
            deviceName: "iPad", expiresAt: request.expiresAt)
        }
      },
      approveEnrollment: { [self] _, product, pending, keyVersion, envelope in
        try device(product)
        guard keyVersion == epoch(product.productAccountId) else {
          throw RegistrationError.unavailable
        }
        var request = try approvable(
          product, pending.requestId, requester: pending.trustedDeviceId)
        request.state = .approved
        request.approval = (keyVersion, envelope)
        request.expiresAt = clock + 900_000
        requests[pending.requestId] = request
      },
      // Any live device of the account, including the requester, cancels an open request.
      declineEnrollment: { [self] _, product, id in
        try device(product)
        guard let request = requests[id], request.account == product.productAccountId,
          request.state == .pending, request.expiresAt > clock
        else { throw RegistrationError.enrollmentUnavailable }
        requests[id]?.state = .cancelled
      },
      recoveryEnvelope: { [self] _, product in
        try device(product)
        guard let envelope = recovery[product.productAccountId] else {
          throw RegistrationError.unavailable
        }
        return StoredPayload(
          payloadIdentifier: "product-account-recovery-v1", encryptedPayload: envelope,
          updatedAt: recoveryUpdatedAt[product.productAccountId] ?? 0)
      },
      keyRotation: { [self] _, product in
        try device(product)
        return rotations[product.productAccountId].map {
          KeyRotation(keyEpoch: $0.epoch, transition: $0.transition)
        }
      },
      // The pending recovery envelope is committed once every remaining device holds the epoch.
      acknowledgeRotation: { [self] _, product, keyEpoch in
        try device(product)
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
          recoveryUpdatedAt[account] = clock
          committed[account] = keyEpoch
          rotations[account] = nil
        }
      },
      trustedDevices: { [self] _, product in
        try device(product)
        return (devices[product.productAccountId] ?? []).map {
          TrustedDevice(id: $0, name: "Device " + $0.suffix(4), registeredAt: 1_000)
        }
      },
      revoke: { [self] _, product, target, transition, wrapped, updatedAt in
        try device(product)
        let account = product.productAccountId
        // A completed removal answers with the current state and applies nothing new.
        if revoked.contains(target) { return }
        guard target != product.trustedDeviceId, devices[account]?.contains(target) == true,
          updatedAt == recoveryUpdatedAt[account], transition.keyVersion == committed[account] ?? 1,
          wrapped.keyVersion == epoch(account) + 1,
          wrapped.schemaVersion == KeyRingEnvelope.recoverySchemaVersion
        else { throw RegistrationError.unavailable }
        revoked.insert(target)
        tombstoned.insert(account)
        devices[account]?.removeAll { $0 == target }
        requests = requests.filter { $0.value.device != target }
        rotations[account] = (wrapped.keyVersion, transition, wrapped)
        offline = offlineAfterRevocation
        if loseReply {
          loseReply = false
          throw URLError(.networkConnectionLost)
        }
      })
  }

  // Each installation is its own Trusted Device of the account its sign-in reaches.
  func store(keys: DeviceKeychain, google: SyntheticGoogleRegistrationProvider)
    -> RegistrationStore
  {
    RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, productSync: backend,
      connect: { [self] identity, device, _ in
        let account = "account-" + identity.subject
        // A revoked device, or any new one after a removal, is refused.
        guard !revoked.contains("device-" + device),
          !tombstoned.contains(account) || devices[account]?.contains("device-" + device) == true
        else { throw RegistrationError.revoked }
        return receipt(account, device: "device-" + device)
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
      binding: .init(account: "account-a", device: "device-b", request: "request-1"))
    #expect(
      try KeyRingEnvelope.openEnrollment(
        sealed, with: enrolling, code: code,
        binding: .init(account: "account-a", device: "device-b", request: "request-1"),
        keyVersion: 1) == ring)
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openEnrollment(
        sealed, with: Curve25519.KeyAgreement.PrivateKey(), code: code,
        binding: .init(account: "account-a", device: "device-b", request: "request-1"),
        keyVersion: 1)
    }
    // Only the code the enrolling device showed opens it, so the backend cannot forge one.
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openEnrollment(
        sealed, with: enrolling, code: .generate(),
        binding: .init(account: "account-a", device: "device-b", request: "request-1"),
        keyVersion: 1)
    }
    for (account, device, request, keyVersion) in [
      ("account-b", "device-b", "request-1", 1), ("account-a", "device-c", "request-1", 1),
      ("account-a", "device-b", "request-2", 1), ("account-a", "device-b", "request-1", 2),
    ] {
      #expect(throws: ProductSyncError.rejected) {
        try KeyRingEnvelope.openEnrollment(
          sealed, with: enrolling, code: code,
          binding: .init(account: account, device: device, request: request), keyVersion: keyVersion
        )
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

    google.scopes = [RegistrationStore.gmailScope]
    google.subject = "synthetic-mailbox-subject"
    let store = backend.store(keys: keys, google: google)
    let connected = try await store.authorizeGmail(reselect: false)
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
      try store.confirmRecoveryKey(wrongGroup(shown))
    }
    let confirmed = try store.confirmRecoveryKey(shown.lastGroup.lowercased())
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
    _ = try await backend.store(keys: keys, google: google).authorizeGmail(reselect: false)
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

    // Meanwhile another installation finds the account uninitialized and wins publication.
    backend.offline = false
    let winner = try await backend.store(keys: second, google: google).signIn()
    #expect(winner["privateSync"] == "recovery-key")
    let published = try #require(backend.recovery[account])
    #expect(published != saved.recoveryEnvelope)

    // The first device discards its unpublished keys and needs enrollment instead.
    let resumed = try await backend.store(keys: first, google: google).restore()
    #expect(resumed["privateSync"] == "enrollment-needed")
    #expect(resumed["recoveryKey"] == nil)
    #expect(try backend.store(keys: first, google: google).loadVault(account) == nil)
    #expect(backend.recovery[account] == published)
    #expect(backend.initializations == 1)

    // Gmail stays authorizable, but no record is written without the account's keys; the next
    // verified sign-in asks a trusted device for them instead.
    let connected = try await backend.store(keys: first, google: google).authorizeGmail(
      reselect: false)
    #expect(connected["kind"] == "connected")
    #expect(connected["privateSync"] == "enrollment-pending")
    #expect(backend.records[account] == nil)
    #expect(
      try await backend.store(keys: first, google: google).restore()["privateSync"]
        == "enrollment-pending")
    #expect(throws: RegistrationError.unavailable) {
      try backend.store(keys: first, google: google).confirmRecoveryKey("0000")
    }

    // The winning device resumes with its own keys after relaunch.
    let restored = try await backend.store(keys: second, google: google).restore()
    #expect(restored["recoveryKey"] == winner["recoveryKey"])
    #expect(backend.initializations == 1)
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
        connect: { identity, _, _ in
          var receipt = backend.receipt("account-" + identity.subject)
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
      let connected = try await backend.store(keys: keys, google: google).authorizeGmail(
        reselect: false)
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
        connect: { identity, _, _ in backend.receipt("account-" + identity.subject) })
    }
    let first = store()
    _ = try await first.signIn(with: .apple)
    google.subject = "synthetic-mailbox-subject"
    #expect(try await first.authorizeGmail(reselect: false)["privateSyncPending"] == nil)
    // An Apple relaunch cannot reach Convex but still shows the list it last decrypted.
    #expect(try await store().restore()["privateSyncMailboxes"] == "same@example.invalid")
    // After relaunch Apple has no backend session, so a newly chosen mailbox waits for sign-in.
    google.subject = "synthetic-other-mailbox"
    google.address = "other@example.invalid"
    let reselected = try await store().authorizeGmail(reselect: true)
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
    #expect(try await approver.authorizeGmail(reselect: false)["kind"] == "connected")
    google.subject = "synthetic-product-subject"
    let recovery = try #require(backend.recovery[account])
    let ring = try #require(try approver.loadVault(account)?.ring)

    // The same Product Sign-In on another installation reaches the account but no keys.
    let enrolling = backend.store(keys: new, google: google)
    let requested = try await enrolling.signIn()
    #expect(requested["kind"] == "mailbox-needed")
    #expect(requested["privateSync"] == "enrollment-pending")
    #expect(requested["privateSyncMailboxes"] == nil)
    let firstCode = try #require(requested["enrollmentCode"])
    #expect(try enrolling.loadVault(account) == nil)

    // The trusted device sees the request; a mistyped code is caught before anything is sent.
    let listed = try await approver.refreshPrivateSync()
    let firstRequest = try #require(listed["enrollmentRequest"])
    #expect(listed["enrollmentDevice"] == "iPad")
    let typo = String(firstCode.dropLast()) + (firstCode.last == "0" ? "1" : "0")
    await #expect(throws: RegistrationError.enrollmentCodeInvalid) {
      try await approver.approveEnrollment(firstRequest, code: typo)
    }
    #expect(backend.requests[firstRequest]?.state == .pending)

    // A declined request ends; the new device asks again with a new code.
    _ = try await approver.declineEnrollment(firstRequest)
    let renewed = try await enrolling.refreshPrivateSync()
    #expect(renewed["privateSync"] == "enrollment-pending")
    #expect(renewed["enrollmentNotice"] == "renewed")
    let secondCode = try #require(renewed["enrollmentCode"])
    #expect(secondCode != firstCode)
    await #expect(throws: RegistrationError.enrollmentUnavailable) {
      try await approver.approveEnrollment(firstRequest, code: firstCode)
    }

    // An approval the backend forges without the code, here with other keys, is rejected.
    let secondRequest = try #require(try await approver.refreshPrivateSync()["enrollmentRequest"])
    let target = try #require(backend.requests[secondRequest])
    backend.requests[secondRequest]?.state = .approved
    backend.requests[secondRequest]?.approval = (
      1,
      try KeyRingEnvelope.enrollment(
        .create(), to: target.publicKey, code: .generate(),
        binding: .init(account: account, device: target.device, request: secondRequest))
    )
    let rejected = try await enrolling.refreshPrivateSync()
    #expect(rejected["privateSync"] == "enrollment-pending")
    #expect(rejected["enrollmentNotice"] == "rejected")
    #expect(try enrolling.loadVault(account) == nil)
    let thirdCode = try #require(rejected["enrollmentCode"])

    // An expired request cannot be approved.
    let thirdRequest = try #require(try await approver.refreshPrivateSync()["enrollmentRequest"])
    backend.clock += 900_001
    await #expect(throws: RegistrationError.enrollmentUnavailable) {
      try await approver.approveEnrollment(thirdRequest, code: thirdCode)
    }
    let expired = try await enrolling.refreshPrivateSync()
    #expect(expired["enrollmentNotice"] == "renewed")
    let code = try #require(expired["enrollmentCode"])

    // The code shown on the new device, typed loosely, approves exactly its request.
    let request = try #require(try await approver.refreshPrivateSync()["enrollmentRequest"])
    let approved = try await approver.approveEnrollment(
      request, code: code.lowercased().replacingOccurrences(of: "-", with: " "))
    #expect(approved["enrollmentRequest"] == nil)
    #expect(approved["privateSync"] == "recovery-key")
    // Replaying the approval is refused; the backend saw no code and no plaintext keys.
    await #expect(throws: RegistrationError.enrollmentUnavailable) {
      try await approver.approveEnrollment(request, code: code)
    }
    let sealed = try #require(backend.requests[request]?.approval)
    let visible = try #require(String(data: JSONEncoder().encode(sealed.envelope), encoding: .utf8))
    for secret in [code, code.replacingOccurrences(of: "-", with: "")]
      + ring.keys.map({ $0.key.base64EncodedString() })
    {
      #expect(!visible.contains(secret))
    }

    // The new device adopts the account keys and reads the synchronized mailbox list, while Gmail
    // on this device still needs its own authorization.
    let unlocked = try await enrolling.refreshPrivateSync()
    #expect(unlocked["kind"] == "mailbox-needed")
    #expect(unlocked["privateSync"] == "ready")
    #expect(unlocked["recoveryKey"] == nil)
    #expect(unlocked["enrollmentCode"] == nil)
    #expect(unlocked["privateSyncMailboxes"] == "same@example.invalid")
    #expect(try enrolling.loadVault(account)?.ring == ring)
    #expect(backend.requests[request] == nil)
    // Nothing replaced the account's key material.
    #expect(backend.recovery[account] == recovery)
    #expect(backend.initializations == 1)
    #expect(try approver.loadVault(account)?.ring == ring)
    #expect(
      try await backend.store(keys: new, google: google).restore()["privateSync"] == "ready")

    // A revoked device's request can no longer be approved.
    let other = device()
    defer { remove(other, accounts: [account]) }
    let revoked = backend.store(keys: other, google: google)
    #expect(try await revoked.signIn()["privateSync"] == "enrollment-pending")
    let revokedRequest = try #require(
      try await approver.refreshPrivateSync()["enrollmentRequest"])
    let revokedCode = try #require(try revoked.privateSync(revoked.load()!)["enrollmentCode"])
    backend.revoked.insert(try #require(backend.requests[revokedRequest]).device)
    await #expect(throws: RegistrationError.enrollmentUnavailable) {
      try await approver.approveEnrollment(revokedRequest, code: revokedCode)
    }
    #expect(backend.recovery[account] == recovery)
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
    #expect(try await lost.authorizeGmail(reselect: false)["kind"] == "connected")
    google.subject = "synthetic-product-subject"
    let recovery = try #require(backend.recovery[account])
    let ring = try #require(try lost.loadVault(account)?.ring)

    // Product Sign-In on a new installation reaches the account but none of its keys.
    let recovering = backend.store(keys: new, google: google)
    let requested = try await recovering.signIn()
    #expect(requested["privateSync"] == "enrollment-pending")

    // Malformed, unrelated and another account's keys unlock nothing and change nothing, even
    // when the backend substitutes that account's envelope. Each reports the current status.
    let other = RecoveryKey.generate()
    var rejected = requested
    rejected["recoveryNotice"] = "rejected"
    for entry in [String(shown.dropLast()), "0000", other.display] {
      #expect(try await recovering.recover(with: entry) == rejected)
    }
    backend.recovery[account] = try KeyRingEnvelope.recovery(
      .create(), key: other, account: "account-other")
    #expect(try await recovering.recover(with: other.display) == rejected)
    backend.recovery[account] = recovery
    #expect(try recovering.loadVault(account) == nil)
    // When the request expired while the form was open, the sign-in the attempt renews also
    // replaces it, and the rejection shows the new code rather than the superseded one.
    backend.clock += 900_001
    let renewed = try await recovering.recover(with: other.display)
    #expect(renewed["recoveryNotice"] == "rejected")
    #expect(renewed["enrollmentNotice"] == "renewed")
    let code = try #require(renewed["enrollmentCode"])
    #expect(code != requested["enrollmentCode"])
    let request = try #require(backend.requests.keys.first)
    // An interrupted recovery leaves the device waiting for approval, also after relaunch.
    backend.offline = true
    await #expect(throws: RegistrationError.unavailable) {
      try await recovering.recover(with: shown)
    }
    backend.offline = false
    let relaunched = try await backend.store(keys: new, google: google).restore()
    #expect(relaunched["privateSync"] == "enrollment-pending")
    #expect(relaunched["enrollmentCode"] == code)
    #expect(relaunched["recoveryNotice"] == nil)
    #expect(try recovering.loadVault(account) == nil)
    #expect(backend.requests[request]?.state == .pending)

    // The written key, typed loosely, adopts the account keys and reads the synchronized mailbox
    // list; Gmail on this device still needs its own authorization.
    let unlocked = try await backend.store(keys: new, google: google).recover(
      with: shown.lowercased().replacingOccurrences(of: "-", with: " "))
    #expect(unlocked["kind"] == "mailbox-needed")
    #expect(unlocked["privateSync"] == "ready")
    #expect(unlocked["recoveryKey"] == nil)
    #expect(unlocked["enrollmentCode"] == nil)
    #expect(unlocked["privateSyncMailboxes"] == "same@example.invalid")
    #expect(try recovering.loadVault(account)?.ring == ring)
    #expect(try recovering.loadVault(account)?.recoveryKey == nil)
    // Its approval request is withdrawn; nothing replaced the account's key material.
    #expect(backend.requests[request]?.state == .cancelled)
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
        connect: { _, device, _ in backend.receipt(account, device: "device-" + device) })
    }
    let appleRecovery = appleStore()
    #expect(try await appleRecovery.signIn(with: .apple)["privateSync"] == "enrollment-pending")
    // Recovery must reauthenticate even with a process session. A different identity or a
    // cancelled renewal cannot adopt the account keys, and a later retry uses fresh sign-in.
    let subject = apple.subject
    apple.subject = "another-apple-subject"
    await #expect(throws: RegistrationError.invalidIdentity) {
      try await appleRecovery.recover(with: shown)
    }
    #expect(try appleRecovery.loadVault(account) == nil)
    apple.subject = subject
    apple.outcome = .cancelled
    await #expect(throws: RegistrationError.cancelled) {
      try await appleRecovery.recover(with: shown)
    }
    #expect(try appleRecovery.loadVault(account) == nil)
    apple.outcome = nil
    #expect(try await appleRecovery.recover(with: shown)["privateSync"] == "ready")
    #expect(try appleRecovery.loadVault(account)?.ring == ring)
    #expect(try await appleStore().restore()["privateSyncMailboxes"] == "same@example.invalid")
    #expect(backend.recovery[account] == recovery)
    #expect(backend.initializations == 1)

    // The backend never received the Recovery Key or the account keys.
    let visible = try #require(
      String(
        data: JSONEncoder().encode(backend.records) + JSONEncoder().encode(backend.recovery),
        encoding: .utf8))
    for secret in [shown, shown.replacingOccurrences(of: "-", with: "")]
      + ring.keys.map({ $0.key.base64EncodedString() })
    {
      #expect(!visible.contains(secret))
    }
  }

  @Test @MainActor func revokingADeviceRotatesKeysForRemainingDevicesAndPurgesItOnReconnect()
    async throws
  {
    let (creator, kept, lost) = (device(), device(), device())
    let account = "account-synthetic-product-subject"
    defer {
      for keys in [creator, kept, lost] { remove(keys, accounts: [account]) }
    }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let backend = SyntheticProductSyncBackend()
    // The first device creates the keys and saves its mailbox; two more unlock with the Recovery Key.
    let remover = backend.store(keys: creator, google: google)
    let shown = try #require(try await remover.signIn()["recoveryKey"])
    _ = try remover.confirmRecoveryKey(String(shown.suffix(4)))
    google.subject = "synthetic-mailbox-subject"
    #expect(try await remover.authorizeGmail(reselect: false)["kind"] == "connected")
    google.subject = "synthetic-product-subject"
    let survivor = backend.store(keys: kept, google: google)
    _ = try await survivor.signIn()
    #expect(try await survivor.recover(with: shown)["privateSync"] == "ready")
    let removed = backend.store(keys: lost, google: google)
    _ = try await removed.signIn()
    #expect(try await removed.recover(with: shown)["privateSync"] == "ready")
    let removedId = try #require(try removed.load()?.product?.trustedDeviceId)
    let oldRing = try #require(try removed.loadVault(account)?.ring)
    let oldRecovery = try #require(backend.recovery[account])

    // The trusted device lists the other two and removes one after signing in again.
    let listed = try #require(try await remover.refreshPrivateSync()["trustedDevices"])
    let devices = try JSONDecoder().decode([TrustedDevice].self, from: Data(listed.utf8))
    #expect(devices.count == 2)
    #expect(devices.contains { $0.id == removedId })
    let signIns = google.hints.count
    let result = try await remover.revoke(removedId)
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
    // Another removal must not discard the sole new Recovery Key before it was backed up.
    let survivorId = try #require(try survivor.load()?.product?.trustedDeviceId)
    await #expect(throws: RegistrationError.recoveryKeyMismatch) {
      try await remover.revoke(survivorId)
    }
    #expect(try remover.loadVault(account)?.recoveryKey == RecoveryKey(parsing: newKey).bytes)
    #expect(!backend.revoked.contains(survivorId))
    _ = try remover.confirmRecoveryKey(String(newKey.suffix(4)))
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
    #expect(
      try await removed.purgingIfRevoked { try await $0.restore() }
        == ["kind": "signed-out", "notice": "revoked"])
    for item in ["registration", "product-sync." + account, "product-sync-enrollment." + account] {
      #expect(try lost.read(item) == nil)
    }
    // Signing in again mints a new device identifier, which the account refuses.
    #expect(
      try await removed.purgingIfRevoked { try await $0.signIn() }
        == ["kind": "signed-out", "notice": "refused"])
    #expect(try lost.read("registration") == nil)

    // The survivor adopts the new epoch from a key it holds; then the rotation completes.
    #expect(try await survivor.refreshPrivateSync()["privateSync"] == "ready")
    #expect(try survivor.loadVault(account)?.ring == ring)
    #expect(backend.rotations[account] == nil)
    let committed = try #require(backend.recovery[account])
    #expect(try KeyRingEnvelope.openRecovery(committed, key: RecoveryKey(parsing: newKey), account: account) == ring)
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRecovery(committed, key: RecoveryKey(parsing: shown), account: account)
    }

    // A mailbox saved at the new epoch reaches the survivor, but not the removed device's keys.
    google.subject = "synthetic-other-mailbox"
    google.address = "other@example.invalid"
    #expect(try await remover.authorizeGmail(reselect: true)["kind"] == "connected")
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
    let unconfirmed = try await remover.revoke(survivorId)
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
    #expect(backend.rotations[account] == nil)
    #expect(
      try KeyRingEnvelope.openRecovery(
        #require(backend.recovery[account]), key: RecoveryKey(parsing: replacement), account: account)
        == remover.loadVault(account)?.ring)
  }

  @Test @MainActor func aLostRevocationReplyKeepsTheNewRecoveryKeyOnlyIfTheRemovalApplied()
    async throws
  {
    let (creator, other) = (device(), device())
    let account = "account-synthetic-product-subject"
    defer {
      for keys in [creator, other] { remove(keys, accounts: [account]) }
    }
    let google = SyntheticGoogleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    let remover = backend.store(keys: creator, google: google)
    let shown = try #require(try await remover.signIn()["recoveryKey"])
    _ = try remover.confirmRecoveryKey(String(shown.suffix(4)))
    let enrolled = backend.store(keys: other, google: google)
    _ = try await enrolled.signIn()
    _ = try await enrolled.recover(with: shown)
    let target = try #require(try enrolled.load()?.product?.trustedDeviceId)

    // A refused removal changes nothing and leaves no pending Recovery Key.
    await #expect(throws: RegistrationError.unavailable) {
      try await remover.revoke("device-unknown")
    }
    #expect(try remover.loadVault(account)?.revocation == nil)
    #expect(backend.rotations[account] == nil)

    // The reply is lost after the removal applied: this device learns it on its next sync.
    backend.loseReply = true
    await #expect(throws: URLError.self) { try await remover.revoke(target) }
    #expect(try remover.loadVault(account)?.revocation != nil)
    #expect(try remover.privateSync(remover.load()!)["privateSync"] == "ready")
    let synced = try await remover.refreshPrivateSync()
    #expect(synced["privateSync"] == "recovery-key")
    let newKey = try #require(synced["recoveryKey"])
    #expect(newKey != shown)
    #expect(try remover.loadVault(account)?.revocation == nil)
    // The only remaining device adopted the epoch, so its recovery envelope opens with the new key.
    #expect(backend.rotations[account] == nil)
    #expect(
      try KeyRingEnvelope.openRecovery(
        #require(backend.recovery[account]), key: RecoveryKey(parsing: newKey), account: account)
        == remover.loadVault(account)?.ring)

    // Removing a device that is already gone applies nothing, so no new Recovery Key is claimed.
    _ = try remover.confirmRecoveryKey(String(newKey.suffix(4)))
    let repeated = try await remover.revoke(target)
    #expect(repeated["revocationNotice"] == "unconfirmed")
    #expect(repeated["privateSync"] == "ready")
    #expect(try remover.loadVault(account)?.recoveryKey == RecoveryKey(parsing: newKey).bytes)
    #expect(try remover.loadVault(account)?.revocation == nil)
  }

  @Test @MainActor func appleRestoreLearnsOfRevocationFromTheDeviceCredentialAlone() async throws {
    let keys = device()
    let account = "account-synthetic-apple-subject"
    defer { remove(keys, accounts: [account]) }
    let google = SyntheticGoogleRegistrationProvider()
    let apple = SyntheticAppleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    var revoked: Bool? = false
    func store() -> RegistrationStore {
      RegistrationStore(
        keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
        provider: google, apple: apple, productSync: backend.backend,
        deviceRevoked: { _ in
          guard let revoked else { throw URLError(.notConnectedToInternet) }
          return revoked
        },
        connect: { identity, _, _ in backend.receipt("account-" + identity.subject) })
    }
    _ = try await store().signIn(with: .apple)
    #expect(try await store().purgingIfRevoked { try await $0.restore() }["kind"] == "mailbox-needed")
    // Offline, an Apple relaunch keeps the saved account usable.
    revoked = nil
    #expect(try await store().purgingIfRevoked { try await $0.restore() }["kind"] == "mailbox-needed")
    revoked = true
    // An unavailable provider grant must not hide the backend's positive revocation proof.
    apple.state = .revoked
    #expect(
      try await store().purgingIfRevoked { try await $0.restore() }
        == ["kind": "signed-out", "notice": "revoked"])
    #expect(try keys.read("registration") == nil)
    #expect(try keys.read("product-sync." + account) == nil)
  }
}
