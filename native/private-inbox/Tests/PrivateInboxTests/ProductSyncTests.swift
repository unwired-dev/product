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
    // The encryption key its request or Recovery Key proof named, which admission binds.
    var deviceKey: Curve25519.KeyAgreement.PublicKey?
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
  // Key rotation: each account's epoch and recovery record time, each Trusted Device's bound
  // encryption key, latest key ring envelope and acknowledged epoch, and activated proposals.
  var committed: [String: Int] = [:]
  var recoveryUpdatedAt: [String: Double] = [:]
  var deviceKeys: [String: Data] = [:]
  var envelopes: [String: KeyRingEnvelope.Rotation] = [:]
  var epochs: [String: Int] = [:]
  var devices: [String: [String]] = [:]
  var proposals: [String: (keyEpoch: Int, target: String)] = [:]
  var recoveryProposal: [String: String] = [:]
  var activations = 0
  // The next removal applies but its reply is lost.
  var loseReply = false
  var failActivationBeforeCommit = false
  // The removal reply arrives, but the following synchronization cannot reach the backend.
  var offlineAfterRevocation = false
  // The next activation finds the Product Sign-In no longer recent.
  var staleOnce = false
  // Another device's removal that commits just before the next mailbox write lands.
  var removalBeforeMailboxPut: (keyEpoch: Int, envelopes: [String: KeyRingEnvelope.Rotation])?

  func epoch(_ account: String) -> Int { committed[account] ?? 1 }

  func verifies(_ proof: String, _ account: String) -> Bool {
    SHA256.hash(data: Data(proof.utf8)).map({ String(format: "%02x", $0) }).joined()
      == verifiers[account]
  }

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
      initialize: { [self] _, product, envelope, verifier, deviceKey in
        try trusted(product)
        let account = product.productAccountId
        if let existing = recovery[account] { return existing == envelope }
        recovery[account] = envelope
        verifiers[account] = verifier
        recoveryUpdatedAt[account] = clock
        deviceKeys[product.trustedDeviceId] = deviceKey.rawRepresentation
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
        if identifier.hasPrefix("mailbox."), let removal = removalBeforeMailboxPut {
          removalBeforeMailboxPut = nil
          committed[product.productAccountId] = removal.keyEpoch
          envelopes.merge(removal.envelopes) { $1 }
        }
        guard payload.keyVersion == epoch(product.productAccountId) else {
          throw ProductSyncWriteFailure.keyRotationRequired
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
      requestEnrollment: { [self] _, product, publicKey, deviceKey in
        var device = try pendingDevice(product)
        guard recovery[product.productAccountId] != nil else {
          throw RegistrationError.unavailable
        }
        device.publicKey = publicKey
        device.deviceKey = deviceKey
        device.approval = nil
        device.recovered = nil
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
      completeEnrollment: { [self] _, product, keyVersion, deviceKey in
        let device = try pendingDevice(product)
        guard !failCompletion else { throw URLError(.notConnectedToInternet) }
        let keyEpoch = epoch(product.productAccountId)
        guard keyVersion == keyEpoch,
          device.recovered == keyEpoch || approvalStillTrusted(device),
          device.deviceKey?.rawRepresentation == deviceKey.rawRepresentation
        else { return nil }
        pending[product.trustedDeviceId] = nil
        let id = "device-" + device.installation
        devices[product.productAccountId, default: []].append(id)
        epochs[id] = keyEpoch
        deviceKeys[id] = deviceKey.rawRepresentation
        if loseCompletionReply {
          loseCompletionReply = false
          throw URLError(.networkConnectionLost)
        }
        return id
      },
      // Only the current Recovery Key binds a key, once; a different bound key is never replaced.
      bindDeviceKey: { [self] _, product, deviceKey, proof in
        try trusted(product)
        guard verifies(proof, product.productAccountId) else { return false }
        let bound = deviceKeys[product.trustedDeviceId]
        guard bound == nil || bound == deviceKey.rawRepresentation else {
          throw RegistrationError.unavailable
        }
        deviceKeys[product.trustedDeviceId] = deviceKey.rawRepresentation
        epochs[product.trustedDeviceId] = epoch(product.productAccountId)
        return true
      },
      // Only the current Recovery Key admits a device.
      recoverPending: { [self] _, product, proof, deviceKey in
        _ = try pendingDevice(product)
        let account = product.productAccountId
        guard let envelope = recovery[account], verifies(proof, account) else { return nil }
        pending[product.trustedDeviceId]?.recovered = envelope.keyVersion
        pending[product.trustedDeviceId]?.deviceKey = deviceKey
        return envelope
      },
      pendingEnrollments: { [self] _, product in
        try trusted(product)
        return pending.compactMap { id, device in
          guard let request = try? openRequest(product, id), request.approval == nil,
            let publicKey = device.publicKey, let deviceKey = device.deviceKey
          else { return nil }
          return PendingEnrollment(
            pendingDeviceId: id, publicKey: publicKey, deviceKey: deviceKey, deviceName: "iPad",
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
        return envelopes[product.trustedDeviceId]
      },
      // Adoption only: stale and repeated acknowledgements never lower it or hold anything back.
      acknowledgeRotation: { [self] _, product, keyEpoch in
        try trusted(product)
        guard keyEpoch <= epoch(product.productAccountId) else {
          throw RegistrationError.unavailable
        }
        epochs[product.trustedDeviceId] = max(epochs[product.trustedDeviceId] ?? 1, keyEpoch)
      },
      trustedDevices: { [self] _, product in
        try trusted(product)
        return (devices[product.productAccountId] ?? []).map {
          TrustedDevice(
            id: $0, name: "Device " + $0.suffix(4), registeredAt: 1_000,
            encryptionKey: deviceKeys[$0])
        }
      },
      // Convex's activation: a repeat answers with its epoch; otherwise the snapshot must be current
      // and the envelopes must cover exactly the remaining devices with bound keys, then everything
      // commits together.
      activateRevocation: { [self] _, product, request in
        try trusted(product)
        let account = product.productAccountId
        if failActivationBeforeCommit { throw URLError(.networkConnectionLost) }
        if staleOnce {
          staleOnce = false
          throw RegistrationError.staleAuthentication
        }
        if let activated = proposals[request.proposalId] {
          guard activated.target == request.trustedDeviceId else {
            throw RevocationFailure.conflict
          }
          return activated.keyEpoch
        }
        guard request.trustedDeviceId != product.trustedDeviceId else {
          throw RegistrationError.unavailable
        }
        if revoked.contains(request.trustedDeviceId) { throw RevocationFailure.targetRemoved }
        guard devices[account]?.contains(request.trustedDeviceId) == true else {
          throw RegistrationError.unavailable
        }
        let next = epoch(account) + 1
        let remaining = (devices[account] ?? []).filter { $0 != request.trustedDeviceId }
        guard request.expectedKeyEpoch == epoch(account),
          request.expectedRecoveryUpdatedAt == recoveryUpdatedAt[account],
          request.envelopes.map(\.trustedDeviceId).sorted() == remaining.sorted(),
          request.envelopes.allSatisfy({ deviceKeys[$0.trustedDeviceId] == $0.publicKey })
        else { throw RevocationFailure.conflict }
        guard request.envelopes.allSatisfy({ $0.envelope.keyEpoch == next }),
          request.recovery.keyVersion == next,
          request.recovery.schemaVersion == KeyRingEnvelope.recoverySchemaVersion
        else { throw RegistrationError.unavailable }
        revoked.insert(request.trustedDeviceId)
        devices[account]?.removeAll { $0 == request.trustedDeviceId }
        envelopes[request.trustedDeviceId] = nil
        for envelope in request.envelopes {
          envelopes[envelope.trustedDeviceId] = envelope.envelope
        }
        committed[account] = next
        clock += 1
        recovery[account] = request.recovery
        verifiers[account] = request.recoveryVerifier
        recoveryUpdatedAt[account] = clock
        recoveryProposal[account] = request.proposalId
        epochs[product.trustedDeviceId] = next
        proposals[request.proposalId] = (next, request.trustedDeviceId)
        activations += 1
        offline = offlineAfterRevocation
        if loseReply {
          loseReply = false
          throw URLError(.networkConnectionLost)
        }
        return next
      },
      revocationOutcome: { [self] _, product, proposalId in
        try trusted(product)
        return proposals[proposalId].map {
          ($0.keyEpoch, recoveryProposal[product.productAccountId] == proposalId)
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
    try? keys.remove("product-sync-device-key." + account)
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
    let deviceKey = Curve25519.KeyAgreement.PrivateKey().publicKey
    let binding = KeyRingEnvelope.EnrollmentBinding(
      account: "account-a", device: "device-b", deviceKey: deviceKey)
    let sealed = try KeyRingEnvelope.enrollment(
      ring, to: enrolling.publicKey, code: code, binding: binding)
    #expect(
      try KeyRingEnvelope.openEnrollment(
        sealed, with: enrolling, code: code, binding: binding, keyVersion: 1) == ring)
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openEnrollment(
        sealed, with: Curve25519.KeyAgreement.PrivateKey(), code: code, binding: binding,
        keyVersion: 1)
    }
    // Only the code the enrolling device showed opens it, so the backend cannot forge one.
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openEnrollment(
        sealed, with: enrolling, code: .generate(), binding: binding, keyVersion: 1)
    }
    // An approval bound to another device encryption key, as a substituted key would be, never opens.
    let otherKey = Curve25519.KeyAgreement.PrivateKey().publicKey
    for (account, device, key, keyVersion) in [
      ("account-b", "device-b", deviceKey, 1), ("account-a", "device-c", deviceKey, 1),
      ("account-a", "device-b", deviceKey, 2), ("account-a", "device-b", otherKey, 1),
    ] {
      #expect(throws: ProductSyncError.rejected) {
        try KeyRingEnvelope.openEnrollment(
          sealed, with: enrolling, code: code,
          binding: .init(account: account, device: device, deviceKey: key),
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
      try backend.store(keys: first, google: google).confirmRecoveryKey("0000")
    }

    // The account's Recovery Key unlocks this Trusted Device from the recovery envelope directly,
    // and binds the encryption key this Trusted Device never bound.
    let firstId = try #require(
      try backend.store(keys: first, google: google).load()?.product?.trustedDeviceId)
    #expect(backend.deviceKeys[firstId] == nil)
    let unlocked = try await backend.store(keys: first, google: google).recover(with: key.display)
    #expect(unlocked["privateSync"] == "ready")
    #expect(
      backend.deviceKeys[firstId]
        == (try backend.store(keys: first, google: google).deviceKey(account).publicKey
          .rawRepresentation))
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
      try await approver.approveEnrollment(pendingId, code: typo)
    }
    #expect(backend.pending[pendingId]?.approval == nil)

    // A declined request ends; the new device asks again with a new code.
    _ = try await approver.declineEnrollment(pendingId)
    let renewed = try await enrolling.refreshPrivateSync()
    #expect(renewed["privateSync"] == "enrollment-pending")
    #expect(renewed["enrollmentNotice"] == "renewed")
    let secondCode = try #require(renewed["enrollmentCode"])
    #expect(secondCode != firstCode)

    // An approval sealed with the previous code does not open: the device stays pending, asks with
    // a new code and keeps no keys.
    #expect(try await approver.refreshPrivateSync()["enrollmentRequest"] == pendingId)
    _ = try await approver.approveEnrollment(pendingId, code: firstCode)
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
      try await approver.approveEnrollment(pendingId, code: thirdCode)
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
    let approved = try await approver.approveEnrollment(
      request, code: code.lowercased().replacingOccurrences(of: "-", with: " "))
    #expect(approved["enrollmentRequest"] == nil)
    #expect(approved["privateSync"] == "recovery-key")
    // Replaying the approval is refused; the backend saw no code and no plaintext keys.
    await #expect(throws: RegistrationError.enrollmentUnavailable) {
      try await approver.approveEnrollment(request, code: code)
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
      #expect(try await recovering.recover(with: entry) == rejected)
    }
    backend.recovery[account] = try KeyRingEnvelope.recovery(
      .create(), key: other, account: "account-other")
    backend.verifiers[account] = KeyRingEnvelope.recoveryVerifier(other, account: account)
    #expect(try await recovering.recover(with: other.display) == rejected)
    backend.recovery[account] = recovery
    backend.verifiers[account] = KeyRingEnvelope.recoveryVerifier(
      try RecoveryKey(parsing: shown), account: account)
    #expect(try recovering.loadVault(account) == nil)
    #expect(try recovering.load()?.product?.pending == true)
    // When the Pending Device ended while the form was open, the sign-in the attempt renews also
    // replaces it, and the rejection shows the new code rather than the superseded one.
    backend.clock += 900_001
    let renewed = try await recovering.recover(with: other.display)
    #expect(renewed["recoveryNotice"] == "rejected")
    let code = try #require(renewed["enrollmentCode"])
    #expect(code != requested["enrollmentCode"])
    let request = try #require(try recovering.load()?.product?.trustedDeviceId)
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
    #expect(backend.pending[request]?.publicKey != nil)

    // The written key, typed loosely, adopts the account keys and admits this device; it reads
    // the synchronized mailbox list, while Gmail on this device still needs its own authorization.
    let unlocked = try await backend.store(keys: new, google: google).recover(
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
    _ = try remover.confirmRecoveryKey(String(shown.suffix(4)))
    let survivor = backend.store(keys: kept, google: google)
    _ = try await survivor.signIn()
    _ = try await survivor.recover(with: shown)
    let removed = backend.store(keys: lost, google: google)
    _ = try await removed.signIn()
    _ = try await removed.recover(with: shown)
    let newcomer = backend.store(keys: joining, google: google)
    let code = try #require(try await newcomer.signIn()["enrollmentCode"])
    backend.failCompletion = true
    await #expect(throws: URLError.self) { try await newcomer.recover(with: shown) }
    backend.failCompletion = false
    #expect(try newcomer.loadVault(account)?.ring.current == 1)
    let removedId = try #require(try removed.load()?.product?.trustedDeviceId)
    let key = try #require(try await remover.revoke(removedId)["revocationRecoveryKey"])
    _ = try await remover.confirmRevocation(String(key.suffix(4)))
    let request = try #require(try await survivor.refreshPrivateSync()["enrollmentRequest"])
    _ = try await survivor.approveEnrollment(request, code: code)
    // Refresh must open and persist the epoch-2 approval before admitting/acknowledging it.
    #expect(try await newcomer.refreshPrivateSync()["privateSync"] == "ready")
    #expect(try newcomer.load()?.product?.pending == nil)
    #expect(try newcomer.loadVault(account)?.ring == survivor.loadVault(account)?.ring)
    #expect(try newcomer.loadVault(account)?.ring.current == 2)
  }

  @Test @MainActor
  func removingADeviceSealsANewEpochToEachRemainingDeviceAfterItsRecoveryKeyIsConfirmed()
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
    _ = try remover.confirmRecoveryKey(String(shown.suffix(4)))
    google.subject = "synthetic-mailbox-subject"
    #expect(try await remover.authorizeGmail()["kind"] == "connected")
    google.subject = "synthetic-product-subject"
    let survivor = backend.store(keys: kept, google: google)
    _ = try await survivor.signIn()
    #expect(try await survivor.recover(with: shown)["privateSync"] == "ready")
    let removed = backend.store(keys: lost, google: google)
    _ = try await removed.signIn()
    #expect(try await removed.recover(with: shown)["privateSync"] == "ready")
    let removerId = try #require(try remover.load()?.product?.trustedDeviceId)
    let survivorId = try #require(try survivor.load()?.product?.trustedDeviceId)
    let removedId = try #require(try removed.load()?.product?.trustedDeviceId)
    let oldRing = try #require(try removed.loadVault(account)?.ring)
    // Each admitted device bound its own encryption key.
    #expect(Set(backend.deviceKeys.keys) == [removerId, survivorId, removedId])

    // Just before its removal, the lost device approves a new installation, which stores the keys
    // but cannot confirm its admission yet.
    let newcomer = backend.store(keys: joining, google: google)
    let firstCode = try #require(try await newcomer.signIn()["enrollmentCode"])
    let request = try #require(try await removed.refreshPrivateSync()["enrollmentRequest"])
    _ = try await removed.approveEnrollment(request, code: firstCode)
    backend.failCompletion = true
    #expect(try await newcomer.refreshPrivateSync()["kind"] == "device-pending")
    backend.failCompletion = false
    #expect(try newcomer.loadVault(account)?.ring == oldRing)

    // Preparing a removal asks for a fresh sign-in and shows a replacement Recovery Key; the
    // account is unchanged until the person confirms it.
    let listed = try #require(try await remover.refreshPrivateSync()["trustedDevices"])
    let devices = try JSONDecoder().decode([TrustedDevice].self, from: Data(listed.utf8))
    #expect(devices.map(\.id).sorted() == [removedId, survivorId].sorted())
    #expect(!listed.contains("encryptionKey"))
    let signIns = google.hints.count
    let prepared = try await remover.revoke(removedId)
    #expect(google.hints.count == signIns + 1)
    #expect(prepared["revocationDevice"] == removedId)
    let discarded = try #require(prepared["revocationRecoveryKey"])
    #expect(discarded != shown)
    #expect(prepared["revocationNotice"] == nil)
    // Cancelling discards it without reaching the account.
    let cancelled = try await remover.cancelRevocation()
    #expect(cancelled["revocationDevice"] == nil)
    #expect(cancelled["revocationRecoveryKey"] == nil)
    #expect(try remover.loadVault(account)?.revocation == nil)
    #expect(backend.activations == 0)
    #expect(!backend.revoked.contains(removedId))
    // A new proposal has a new key; an entry that does not match it activates nothing.
    let replacement = try #require(try await remover.revoke(removedId)["revocationRecoveryKey"])
    #expect(replacement != discarded)
    await #expect(throws: RegistrationError.recoveryKeyMismatch) {
      try await remover.confirmRevocation(wrongGroup(RecoveryKey(parsing: replacement)))
    }
    #expect(backend.activations == 0)
    #expect(try remover.loadVault(account)?.revocation?.submitted == false)

    // Confirmed, the removal activates at once, before any other device adopts it.
    let result = try await remover.confirmRevocation(String(replacement.suffix(4)))
    #expect(result["revocationNotice"] == "removed")
    #expect(result["revocationDevice"] == nil)
    #expect(result["privateSync"] == "ready")
    #expect(result["recoveryKey"] == nil)
    #expect(!(result["trustedDevices"] ?? "").contains(removedId))
    #expect(backend.committed[account] == 2)
    let ring = try #require(try remover.loadVault(account)?.ring)
    #expect(ring.current == 2)
    #expect(oldRing.keys.allSatisfy(ring.keys.contains))
    // Every remaining device received its own envelope; the removed device received none.
    #expect(Set(backend.envelopes.keys) == [removerId, survivorId])
    // The replacement Recovery Key is current immediately; the previous one opens nothing new.
    let committed = try #require(backend.recovery[account])
    #expect(
      try KeyRingEnvelope.openRecovery(
        committed, key: RecoveryKey(parsing: replacement), account: account) == ring)
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRecovery(
        committed, key: RecoveryKey(parsing: shown), account: account)
    }
    let outcome = try await backend.backend.revocationOutcome(
      #require(remover.session), #require(remover.load()?.product),
      #require(backend.recoveryProposal[account]))
    #expect(outcome?.keyEpoch == 2)
    #expect(outcome?.recoveryKeyCurrent == true)

    // The approval ended with its approver and the epoch it sealed: the device discards the keys
    // it stored and asks again.
    let renewed = try await newcomer.refreshPrivateSync()
    #expect(renewed["kind"] == "device-pending")
    #expect(renewed["enrollmentNotice"] == "renewed")
    let code = try #require(renewed["enrollmentCode"])
    #expect(code != firstCode)
    #expect(try newcomer.loadVault(account) == nil)

    // A corrupt registration must still drop process-local access while retaining its locator
    // so a later readable registration can finish the account cleanup.
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
      try await removed.purgingIfRevoked { try await $0.revoke(survivorId) }
        == ["kind": "signed-out", "notice": "revoked"])
    #expect(google.hints.count == prompts)
    google.outcome = nil
    for item in [
      "registration", "product-sync." + account, "product-sync-enrollment." + account,
      "product-sync-device-key." + account,
    ] {
      #expect(try lost.read(item) == nil)
    }
    // Signing in again only waits as a Pending Device, and the previous Recovery Key admits nobody.
    let returned = try await removed.purgingIfRevoked { try await $0.signIn() }
    #expect(returned["kind"] == "device-pending")
    #expect(try await removed.recover(with: shown)["recoveryNotice"] == "rejected")
    #expect(try lost.read("product-sync." + account) == nil)

    // The survivor adopts the new epoch from its own envelope and acknowledges it.
    #expect(try await survivor.refreshPrivateSync()["privateSync"] == "ready")
    #expect(try survivor.loadVault(account)?.ring == ring)
    #expect(backend.epochs[survivorId] == 2)
    // It seals the new epoch to the waiting device, which is admitted at that epoch.
    _ = try await survivor.approveEnrollment(request, code: code)
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
  }

  @Test @MainActor func aRemovedDevicesSecretsOpenNoPayloadOfItsRemovalEpochOrLater() async throws {
    let (creator, kept, lost, other) = (device(), device(), device(), device())
    let account = "account-synthetic-product-subject"
    defer {
      for keys in [creator, kept, lost, other] { remove(keys, accounts: [account]) }
    }
    let google = SyntheticGoogleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    let remover = backend.store(keys: creator, google: google)
    let shown = try #require(try await remover.signIn()["recoveryKey"])
    _ = try remover.confirmRecoveryKey(String(shown.suffix(4)))
    let survivor = backend.store(keys: kept, google: google)
    _ = try await survivor.signIn()
    _ = try await survivor.recover(with: shown)
    let third = backend.store(keys: other, google: google)
    _ = try await third.signIn()
    _ = try await third.recover(with: shown)
    // The device to be removed enrolls through an approval, so it also holds enrollment secrets.
    let removed = backend.store(keys: lost, google: google)
    let code = try #require(try await removed.signIn()["enrollmentCode"])
    let enrollment = try JSONDecoder().decode(
      ProductSyncEnrollment.self,
      from: #require(try lost.read("product-sync-enrollment." + account)))
    let request = try #require(try await remover.refreshPrivateSync()["enrollmentRequest"])
    _ = try await remover.approveEnrollment(request, code: code)
    let retainedApproval = try #require(backend.pending[request]?.approval?.envelope)
    #expect(try await removed.refreshPrivateSync()["privateSync"] == "ready")
    let removedId = try #require(try removed.load()?.product?.trustedDeviceId)
    let thirdId = try #require(try third.load()?.product?.trustedDeviceId)
    // Everything the removed device holds at removal.
    let secretKey = try removed.deviceKey(account)
    let secretRing = try #require(try removed.loadVault(account)?.ring)
    let secretRecovery = try RecoveryKey(parsing: shown)
    let enrollmentKey = try Curve25519.KeyAgreement.PrivateKey(
      rawRepresentation: enrollment.privateKey)
    let enrollmentCode = try EnrollmentCode(parsing: enrollment.code)
    let retainedRecovery = try #require(backend.recovery[account])

    // Two successive removals; every payload Convex stores along the way is retained.
    var envelopes: [(String, KeyRingEnvelope.Rotation)] = []
    var recoveries: [EncryptedPayload] = []
    var records: [(String, EncryptedPayload)] = []
    var currentKey = shown
    for target in [removedId, thirdId] {
      let key = try #require(try await remover.revoke(target)["revocationRecoveryKey"])
      currentKey = key
      #expect(
        try await remover.confirmRevocation(String(key.suffix(4)))["revocationNotice"]
          == "removed")
      envelopes += backend.envelopes.map { ($0.key, $0.value) }
      recoveries.append(try #require(backend.recovery[account]))
      let ring = try #require(try remover.loadVault(account)?.ring)
      // Mailbox descriptors, Draft records and Draft Assets use the same authenticated record seal.
      for prefix in ["mailbox", "draft", "draft-asset"] {
        let identifier = try ring.identifier(prefix, "probe")
        records.append(
          (
            identifier,
            try ring.seal(
              record: Data("probe".utf8), account: account, identifier: identifier, schemaVersion: 1
            )
          ))
      }
    }
    #expect(backend.committed[account] == 3)
    #expect(envelopes.count == 5)
    let survivorId = try #require(try survivor.load()?.product?.trustedDeviceId)
    let survivorKey = try survivor.deviceKey(account)

    for (recipientId, envelope) in envelopes {
      let recipientKey = try #require(backend.deviceKeys[recipientId])
      let bindings = try [recipientId, removedId].map {
        KeyRingEnvelope.RotationRecipient(
          account: account, device: $0,
          publicKey: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientKey))
      }
      for binding in bindings {
        #expect(throws: ProductSyncError.rejected) {
          try KeyRingEnvelope.openRotation(
            envelope, with: secretKey, recipient: binding, current: secretRing)
        }
      }
      #expect(throws: ProductSyncError.rejected) {
        try KeyRingEnvelope.openEnrollment(
          .init(encapsulatedKey: envelope.encapsulatedKey, ciphertext: envelope.ciphertext),
          with: enrollmentKey, code: enrollmentCode,
          binding: .init(account: account, device: removedId, deviceKey: secretKey.publicKey),
          keyVersion: envelope.keyEpoch)
      }
    }
    for recovery in recoveries {
      #expect(throws: ProductSyncError.rejected) {
        try KeyRingEnvelope.openRecovery(recovery, key: secretRecovery, account: account)
      }
    }
    // Retained admission and recovery artifacts still open only the historical ring.
    #expect(
      try KeyRingEnvelope.openEnrollment(
        retainedApproval, with: enrollmentKey, code: enrollmentCode,
        binding: .init(account: account, device: request, deviceKey: secretKey.publicKey),
        keyVersion: secretRing.current) == secretRing)
    #expect(
      try KeyRingEnvelope.openRecovery(
        retainedRecovery, key: secretRecovery, account: account) == secretRing)
    // Records from both new epochs do not open with any account key the removed device held.
    let newestRing = try #require(try remover.loadVault(account)?.ring)
    for (identifier, record) in records {
      #expect(throws: ProductSyncError.rejected) {
        try secretRing.open(
          record: record, account: account, identifier: identifier, schemaVersion: 1)
      }
    }

    // The surviving device opens its envelope only under its own account, device and epoch.
    let own = try #require(envelopes.last { $0.0 == survivorId }?.1)
    let binding = KeyRingEnvelope.RotationRecipient(
      account: account, device: survivorId, publicKey: survivorKey.publicKey)
    #expect(
      try KeyRingEnvelope.openRotation(
        own, with: survivorKey, recipient: binding, current: secretRing)
        == newestRing)
    for wrong in [
      KeyRingEnvelope.RotationRecipient(
        account: "account-other", device: survivorId, publicKey: survivorKey.publicKey),
      KeyRingEnvelope.RotationRecipient(
        account: account, device: removedId, publicKey: survivorKey.publicKey),
      KeyRingEnvelope.RotationRecipient(
        account: account, device: survivorId, publicKey: secretKey.publicKey),
    ] {
      #expect(throws: ProductSyncError.rejected) {
        try KeyRingEnvelope.openRotation(
          own, with: survivorKey, recipient: wrong, current: secretRing)
      }
    }
    let relabelled = KeyRingEnvelope.Rotation(
      keyEpoch: own.keyEpoch + 1, encapsulatedKey: own.encapsulatedKey, ciphertext: own.ciphertext)
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRotation(
        relabelled, with: survivorKey, recipient: binding, current: secretRing)
    }
    // A ring that drops a key this device holds is refused.
    let shrunk = try KeyRingEnvelope.rotation(
      ProductSyncKeyRing(current: 4, keys: [.init(version: 4, key: ProductSyncSeal.randomKey())]),
      to: binding)
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRotation(
        shrunk, with: survivorKey, recipient: binding, current: newestRing)
    }
    // The current Recovery Key opens the newest recovery envelope.
    #expect(
      try KeyRingEnvelope.openRecovery(
        #require(recoveries.last), key: RecoveryKey(parsing: currentKey), account: account)
        == newestRing)
  }

  @Test @MainActor func anOfflineDeviceSkipsSuccessiveRemovalsAndAdoptsTheNewestRingDirectly()
    async throws
  {
    let (creator, offline, first, second) = (device(), device(), device(), device())
    let account = "account-synthetic-product-subject"
    defer {
      for keys in [creator, offline, first, second] { remove(keys, accounts: [account]) }
    }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let backend = SyntheticProductSyncBackend()
    let remover = backend.store(keys: creator, google: google)
    let shown = try #require(try await remover.signIn()["recoveryKey"])
    _ = try remover.confirmRecoveryKey(String(shown.suffix(4)))
    // A mailbox saved at the first epoch stays readable to every remaining device.
    google.subject = "synthetic-mailbox-subject"
    #expect(try await remover.authorizeGmail()["kind"] == "connected")
    google.subject = "synthetic-product-subject"
    var stores: [RegistrationStore] = []
    for keys in [offline, first, second] {
      let store = backend.store(keys: keys, google: google)
      _ = try await store.signIn()
      _ = try await store.recover(with: shown)
      stores.append(store)
    }
    let absent = stores[0]
    let absentId = try #require(try absent.load()?.product?.trustedDeviceId)
    #expect(backend.epochs[absentId] == 1)

    // Two removals complete while that device never connects; its acknowledgement holds neither.
    for target in stores.dropFirst() {
      let id = try #require(try target.load()?.product?.trustedDeviceId)
      let key = try #require(try await remover.revoke(id)["revocationRecoveryKey"])
      #expect(
        try await remover.confirmRevocation(String(key.suffix(4)))["revocationNotice"]
          == "removed")
    }
    #expect(backend.committed[account] == 3)
    #expect(backend.epochs[absentId] == 1)
    // It keeps one envelope, its latest complete ring.
    #expect(backend.envelopes[absentId]?.keyEpoch == 3)

    // Reconnecting, it adopts epoch 3 directly, without a Recovery Key, and reads older data.
    let caught = try await absent.refreshPrivateSync()
    #expect(caught["privateSync"] == "ready")
    #expect(caught["privateSyncMailboxes"] == "same@example.invalid")
    let ring = try #require(try absent.loadVault(account)?.ring)
    #expect(try ring == remover.loadVault(account)?.ring)
    #expect(ring.keys.map(\.version).sorted() == [1, 2, 3])
    #expect(backend.epochs[absentId] == 3)
    // A stale or repeated acknowledgement never lowers the recorded adoption.
    let product = try #require(try absent.load()?.product)
    let session = try #require(absent.session)
    try await backend.backend.acknowledgeRotation(session, product, 1)
    try await backend.backend.acknowledgeRotation(session, product, 3)
    #expect(backend.epochs[absentId] == 3)
  }

  @Test(arguments: [false, true]) @MainActor
  func aLostActivationReplyIsSettledWithoutRemovingTwice(settledBySynchronizing: Bool)
    async throws
  {
    let (creator, other, kept) = (device(), device(), device())
    let account = "account-synthetic-product-subject"
    defer {
      for keys in [creator, other, kept] { remove(keys, accounts: [account]) }
    }
    let google = SyntheticGoogleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    let remover = backend.store(keys: creator, google: google)
    let shown = try #require(try await remover.signIn()["recoveryKey"])
    _ = try remover.confirmRecoveryKey(String(shown.suffix(4)))
    let target = backend.store(keys: other, google: google)
    _ = try await target.signIn()
    _ = try await target.recover(with: shown)
    let targetId = try #require(try target.load()?.product?.trustedDeviceId)
    let survivor = backend.store(keys: kept, google: google)
    _ = try await survivor.signIn()
    _ = try await survivor.recover(with: shown)

    // A device the account does not list prepares nothing.
    #expect(try await remover.revoke("device-unknown")["revocationNotice"] == "superseded")
    #expect(try remover.loadVault(account)?.revocation == nil)

    // The activation applies, but its reply is lost: the proposal and its key stay shown.
    let key = try #require(try await remover.revoke(targetId)["revocationRecoveryKey"])
    backend.loseReply = true
    let lost = try await remover.confirmRevocation(String(key.suffix(4)))
    #expect(lost["revocationNotice"] == "unconfirmed")
    #expect(lost["revocationRecoveryKey"] == key)
    #expect(backend.revoked.contains(targetId))
    #expect(try remover.loadVault(account)?.revocation?.submitted == true)

    let settled =
      settledBySynchronizing
      ? try await remover.refreshPrivateSync()
      : try await remover.confirmRevocation(String(key.suffix(4)))
    #expect(settled["revocationNotice"] == (settledBySynchronizing ? nil : "removed"))
    #expect(settled["revocationRecoveryKey"] == nil)
    #expect(try remover.loadVault(account)?.revocation == nil)
    // Nothing was removed or rotated twice, and the confirmed key is the account's current one.
    #expect(backend.activations == 1)
    #expect(backend.committed[account] == 2)
    let ring = try #require(try remover.loadVault(account)?.ring)
    #expect(ring.current == 2)
    #expect(
      try KeyRingEnvelope.openRecovery(
        #require(backend.recovery[account]), key: RecoveryKey(parsing: key), account: account)
        == ring)
    // Removing a device that is already gone prepares nothing new.
    let repeated = try await remover.revoke(targetId)
    #expect(repeated["revocationNotice"] == "superseded")
    #expect(repeated["revocationRecoveryKey"] == nil)
    #expect(backend.activations == 1)
  }

  @Test @MainActor func anUnansweredActivationKeepsItsIdentityAcrossCancellationAndRestart()
    async throws
  {
    let (creator, other, kept) = (device(), device(), device())
    let account = "account-synthetic-product-subject"
    defer { for keys in [creator, other, kept] { remove(keys, accounts: [account]) } }
    let google = SyntheticGoogleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    let remover = backend.store(keys: creator, google: google)
    let shown = try #require(try await remover.signIn()["recoveryKey"])
    _ = try remover.confirmRecoveryKey(String(shown.suffix(4)))
    var ids: [String] = []
    for keys in [other, kept] {
      let store = backend.store(keys: keys, google: google)
      _ = try await store.signIn()
      _ = try await store.recover(with: shown)
      ids.append(try #require(try store.load()?.product?.trustedDeviceId))
    }
    let key = try #require(try await remover.revoke(ids[0])["revocationRecoveryKey"])
    let proposal = try #require(try remover.loadVault(account)?.revocation)
    backend.failActivationBeforeCommit = true
    #expect(
      try await remover.confirmRevocation(String(key.suffix(4)))["revocationNotice"]
        == "unconfirmed")
    // The receipt does not exist yet; that cannot prove the original request was rejected.
    #expect(try await remover.cancelRevocation()["revocationNotice"] == "unconfirmed")
    #expect(try remover.loadVault(account)?.revocation?.request == proposal.request)
    let restarted = backend.store(keys: creator, google: google)
    // There is no in-process Product Sign-In after relaunch, but cancellation still preserves it.
    #expect(try await restarted.cancelRevocation()["revocationRecoveryKey"] == key)
    #expect(try await restarted.revoke(ids[1])["revocationDevice"] == ids[0])
    #expect(try restarted.loadVault(account)?.revocation?.request == proposal.request)
    backend.failActivationBeforeCommit = false
    backend.staleOnce = true
    google.outcome = .cancelled
    await #expect(throws: RegistrationError.cancelled) {
      try await restarted.confirmRevocation(String(key.suffix(4)))
    }
    #expect(try restarted.loadVault(account)?.revocation?.submitted == true)
    #expect(try await restarted.cancelRevocation()["revocationNotice"] == "unconfirmed")
    google.outcome = nil
    #expect(
      try await restarted.confirmRevocation(String(key.suffix(4)))["revocationNotice"] == "removed")
    #expect(backend.activations == 1)
    #expect(backend.revoked.contains(ids[0]))
    #expect(!backend.revoked.contains(ids[1]))
    #expect(try restarted.loadVault(account)?.ring.current == 2)
    #expect(try restarted.loadVault(account)?.revocation == nil)
  }

  @Test(arguments: [false, true]) @MainActor
  func aLostReplyFollowedByAnotherRotationNeverClaimsItsKeyIsCurrent(cancel: Bool) async throws {
    let keychains = (0..<4).map { _ in device() }
    let account = "account-synthetic-product-subject"
    defer { for keys in keychains { remove(keys, accounts: [account]) } }
    let google = SyntheticGoogleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    let remover = backend.store(keys: keychains[0], google: google)
    let shown = try #require(try await remover.signIn()["recoveryKey"])
    _ = try remover.confirmRecoveryKey(String(shown.suffix(4)))
    var others: [RegistrationStore] = []
    for keys in keychains.dropFirst() {
      let store = backend.store(keys: keys, google: google)
      _ = try await store.signIn()
      _ = try await store.recover(with: shown)
      others.append(store)
    }
    let first = try #require(try others[0].load()?.product?.trustedDeviceId)
    let second = try #require(try others[2].load()?.product?.trustedDeviceId)
    let key = try #require(try await remover.revoke(first)["revocationRecoveryKey"])
    backend.loseReply = true
    #expect(
      try await remover.confirmRevocation(String(key.suffix(4)))["revocationNotice"]
        == "unconfirmed")
    let latest = try #require(try await others[1].revoke(second)["revocationRecoveryKey"])
    _ = try await others[1].confirmRevocation(String(latest.suffix(4)))
    let settled =
      cancel
      ? try await remover.cancelRevocation()
      : try await remover.confirmRevocation(String(key.suffix(4)))
    #expect(settled["revocationNotice"] == "superseded")
    #expect(settled["revocationRecoveryKey"] == nil)
    #expect(try remover.loadVault(account)?.revocation == nil)
    #expect(try remover.loadVault(account)?.ring.current == 3)
    #expect(backend.activations == 2)
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRecovery(
        #require(backend.recovery[account]), key: RecoveryKey(parsing: key), account: account)
    }
  }

  @Test @MainActor func aCommittedActivationKeepsItsReceiptUntilDurableAdoption() async throws {
    let (creator, other) = (device(), device())
    let account = "account-synthetic-product-subject"
    defer { for keys in [creator, other] { remove(keys, accounts: [account]) } }
    let google = SyntheticGoogleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    let remover = backend.store(keys: creator, google: google)
    let shown = try #require(try await remover.signIn()["recoveryKey"])
    _ = try remover.confirmRecoveryKey(String(shown.suffix(4)))
    let target = backend.store(keys: other, google: google)
    _ = try await target.signIn()
    _ = try await target.recover(with: shown)
    let targetId = try #require(try target.load()?.product?.trustedDeviceId)
    let key = try #require(try await remover.revoke(targetId)["revocationRecoveryKey"])
    backend.offlineAfterRevocation = true
    await #expect(throws: RegistrationError.unavailable) {
      try await remover.confirmRevocation(String(key.suffix(4)))
    }
    #expect(backend.committed[account] == 2)
    #expect(try remover.loadVault(account)?.ring.current == 1)
    #expect(try remover.loadVault(account)?.revocation?.submitted == true)
    backend.offline = false
    let restarted = backend.store(keys: creator, google: google)
    _ = try await restarted.restore()
    #expect(try restarted.loadVault(account)?.ring.current == 2)
    #expect(try restarted.loadVault(account)?.revocation == nil)
    #expect(backend.activations == 1)
  }

  @Test @MainActor func anOvertakenProposalIsPreparedAgainWithANewKeyBeforeItApplies()
    async throws
  {
    let keychains = (0..<5).map { _ in device() }
    let account = "account-synthetic-product-subject"
    defer { for keys in keychains { remove(keys, accounts: [account]) } }
    let google = SyntheticGoogleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    let remover = backend.store(keys: keychains[0], google: google)
    let shown = try #require(try await remover.signIn()["recoveryKey"])
    _ = try remover.confirmRecoveryKey(String(shown.suffix(4)))
    var stores: [RegistrationStore] = []
    var ids: [String] = []
    for keys in keychains.dropFirst() {
      let store = backend.store(keys: keys, google: google)
      _ = try await store.signIn()
      _ = try await store.recover(with: shown)
      stores.append(store)
      ids.append(try #require(try store.load()?.product?.trustedDeviceId))
    }
    let other = stores[2]

    // While this device's proposal waits, another device removes a third one.
    let first = try #require(try await remover.revoke(ids[0])["revocationRecoveryKey"])
    let elsewhere = try #require(try await other.revoke(ids[1])["revocationRecoveryKey"])
    _ = try await other.confirmRevocation(String(elsewhere.suffix(4)))
    #expect(backend.committed[account] == 2)
    // Its confirmation finds the account changed: nothing applies, and a new key is shown.
    let renewed = try await remover.confirmRevocation(String(first.suffix(4)))
    #expect(renewed["revocationNotice"] == "renewed")
    let second = try #require(renewed["revocationRecoveryKey"])
    #expect(second != first)
    #expect(renewed["revocationDevice"] == ids[0])
    #expect(!backend.revoked.contains(ids[0]))
    #expect(backend.committed[account] == 2)
    #expect(try remover.loadVault(account)?.ring.current == 2)
    // Confirming the discarded key does not count for the new proposal.
    await #expect(throws: RegistrationError.recoveryKeyMismatch) {
      try await remover.confirmRevocation(String(first.suffix(4)))
    }
    // The sign-in has aged by now; activation renews it and applies the new proposal.
    backend.staleOnce = true
    let signIns = google.hints.count
    let removed = try await remover.confirmRevocation(String(second.suffix(4)))
    #expect(removed["revocationNotice"] == "removed")
    #expect(google.hints.count == signIns + 1)
    #expect(backend.committed[account] == 3)
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRecovery(
        #require(backend.recovery[account]), key: RecoveryKey(parsing: first), account: account)
    }

    // A device another one removes first supersedes a waiting proposal, which never applies.
    let waiting = try #require(try await remover.revoke(ids[3])["revocationRecoveryKey"])
    let elsewhereAgain = try #require(try await other.revoke(ids[3])["revocationRecoveryKey"])
    _ = try await other.confirmRevocation(String(elsewhereAgain.suffix(4)))
    let superseded = try await remover.confirmRevocation(String(waiting.suffix(4)))
    #expect(superseded["revocationNotice"] == "superseded")
    #expect(superseded["revocationRecoveryKey"] == nil)
    #expect(!(superseded["trustedDevices"] ?? "").contains(ids[3]))
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRecovery(
        #require(backend.recovery[account]), key: RecoveryKey(parsing: waiting), account: account)
    }
    #expect(
      try KeyRingEnvelope.openRecovery(
        #require(backend.recovery[account]), key: RecoveryKey(parsing: elsewhereAgain),
        account: account)
        == other.loadVault(account)?.ring)
  }

  @Test @MainActor func writesSealedAtAnOvertakenEpochAreSealedAgainAfterAdoptingIt()
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
    let remover = backend.store(keys: creator, google: google)
    let shown = try #require(try await remover.signIn()["recoveryKey"])
    _ = try remover.confirmRecoveryKey(String(shown.suffix(4)))
    let writer = backend.store(keys: kept, google: google)
    _ = try await writer.signIn()
    _ = try await writer.recover(with: shown)
    let removed = backend.store(keys: lost, google: google)
    _ = try await removed.signIn()
    _ = try await removed.recover(with: shown)
    let removedId = try #require(try removed.load()?.product?.trustedDeviceId)

    // A Draft sync prepared before the removal still holds the old epoch's ring.
    let owner = account
    let stale = try writer.draftSync(owner: owner)
    let key = try #require(try await remover.revoke(removedId)["revocationRecoveryKey"])
    _ = try await remover.confirmRevocation(String(key.suffix(4)))
    // Its write is refused at once; the device then adopts the epoch and the retry is sealed with it.
    await #expect(throws: ProductSyncWriteFailure.keyRotationRequired) {
      do {
        _ = try await stale.push(id: "draft-1", version: 1, draft: "{}", expected: nil)
      } catch {
        try await writer.draftSyncFailure(owner: owner, error: error)
      }
    }
    #expect(try writer.loadVault(account)?.ring.current == 2)
    let retried = try await writer.draftSync(owner: owner).push(
      id: "draft-1", version: 1, draft: "{}", expected: nil)
    #expect(retried["committed"] as? Bool == true)
    #expect(
      backend.records[account]?.values.allSatisfy { $0.encryptedPayload.keyVersion == 2 } == true)

    // A mailbox write that a removal overtakes mid-synchronization is sealed again in the same run.
    google.subject = "synthetic-mailbox-subject"
    let writerId = try #require(try writer.load()?.product?.trustedDeviceId)
    let ring = try #require(try writer.loadVault(account)?.ring)
    let next = ProductSyncKeyRing(
      current: 3, keys: ring.keys + [.init(version: 3, key: ProductSyncSeal.randomKey())])
    backend.removalBeforeMailboxPut = (
      3,
      [
        writerId: try KeyRingEnvelope.rotation(
          next,
          to: .init(
            account: account, device: writerId,
            publicKey: Curve25519.KeyAgreement.PublicKey(
              rawRepresentation: #require(backend.deviceKeys[writerId]))))
      ]
    )
    #expect(try await writer.authorizeGmail()["kind"] == "connected")
    #expect(backend.removalBeforeMailboxPut == nil)
    #expect(try writer.loadVault(account)?.ring == next)
    #expect(
      backend.records[account]?.values.contains {
        $0.payloadIdentifier.hasPrefix("mailbox.") && $0.encryptedPayload.keyVersion == 3
      } == true)
  }

  @Test(arguments: [false, true]) @MainActor
  func aDeviceThatLostItsKeysEnrollsAgainAsANewDevice(retainsRing: Bool) async throws {
    let (creator, original) = (device(), device())
    let account = "account-synthetic-product-subject"
    defer {
      for keys in [creator, original] { remove(keys, accounts: [account]) }
    }
    let google = SyntheticGoogleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    let approver = backend.store(keys: creator, google: google)
    let shown = try #require(try await approver.signIn()["recoveryKey"])
    _ = try approver.confirmRecoveryKey(String(shown.suffix(4)))
    let lostStore = backend.store(keys: original, google: google)
    _ = try await lostStore.signIn()
    _ = try await lostStore.recover(with: shown)
    let oldId = try #require(try lostStore.load()?.product?.trustedDeviceId)
    let oldKey = try #require(backend.deviceKeys[oldId])

    // Losing its private key requires fresh admission, even if the old ring is still present.
    if !retainsRing { try original.remove("product-sync." + account) }
    try original.remove("product-sync-device-key." + account)
    #expect(
      try lostStore.privateSync(#require(try lostStore.load()))["privateSync"]
        == "enrollment-needed")
    #expect(throws: RegistrationError.unavailable) {
      try lostStore.deviceKey(account)
    }
    #expect(try original.read("product-sync-device-key." + account) == nil)
    #expect(backend.deviceKeys[oldId] == oldKey)

    // As a new installation, sign-in alone admits nothing: it waits for a fresh authorization.
    let rejoined = backend.store(keys: original, google: google)
    let code = try #require(try await rejoined.signIn()["enrollmentCode"])
    let request = try #require(try await approver.refreshPrivateSync()["enrollmentRequest"])
    _ = try await approver.approveEnrollment(request, code: code)
    #expect(try await rejoined.refreshPrivateSync()["privateSync"] == "ready")
    let newId = try #require(try rejoined.load()?.product?.trustedDeviceId)
    #expect(newId != oldId)
    #expect(
      backend.deviceKeys[newId] == (try rejoined.deviceKey(account).publicKey.rawRepresentation))
    #expect(backend.deviceKeys[newId] != oldKey)

    // The abandoned registration stays listed until it is removed explicitly.
    let listed = try #require(try await approver.refreshPrivateSync()["trustedDevices"])
    #expect(listed.contains(oldId))
    let key = try #require(try await approver.revoke(oldId)["revocationRecoveryKey"])
    #expect(
      try await approver.confirmRevocation(String(key.suffix(4)))["revocationNotice"] == "removed")
    #expect(try await rejoined.refreshPrivateSync()["privateSync"] == "ready")
    #expect(try rejoined.loadVault(account)?.ring.current == 2)
  }

  @Test(arguments: [
    (SignInProvider.google, "link"), (.apple, "link"),
    (.google, "sign-in"), (.apple, "sign-in"),
    (.google, "switch"), (.apple, "switch"), (.apple, "recovery"),
  ])
  @MainActor func savedAccountPromptsPurgeRevokedDevicesBeforeCancellation(
    _ scenario: (SignInProvider, String)
  ) async throws {
    let (signInProvider, operation) = scenario
    let keys = device()
    let google = SyntheticGoogleRegistrationProvider()
    let apple = SyntheticAppleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    let account = "account-" + (signInProvider == .apple ? apple.subject : google.subject)
    defer { remove(keys, accounts: [account]) }
    var revoked: Bool? = false
    let store = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, apple: apple,
      linking: SignInLinking(
        request: { _, _, _ in throw RegistrationError.unavailable },
        complete: { _, _, _ in throw RegistrationError.unavailable }),
      productSync: backend.backend,
      deviceRevoked: { _ in
        guard let revoked else { throw URLError(.notConnectedToInternet) }
        return revoked
      },
      connect: { identity, device, _ in
        try backend.connect("account-" + identity.subject, device: device)
      })
    let registered = try await store.signIn(with: signInProvider)
    let recoveryKey = try #require(registered["recoveryKey"])
    google.scopes = [RegistrationStore.gmailScope]
    _ = try await store.authorizeGmail()
    #expect(try store.load()?.connections.isEmpty == false)
    #expect(try keys.read("product-sync." + account) != nil)
    let other: SignInProvider = signInProvider == .apple ? .google : .apple
    func perform(_ current: RegistrationStore) async throws -> [String: String] {
      switch operation {
      case "link": return try await current.link(other)
      case "sign-in": return try await current.signIn(with: signInProvider)
      case "switch": return try await current.signIn(with: other)
      default: return try await current.recover(with: recoveryKey)
      }
    }
    google.outcome = .cancelled
    apple.outcome = .cancelled
    // A missing revocation reply retains the resumable account when the prompt is cancelled.
    revoked = nil
    await #expect(throws: RegistrationError.cancelled) {
      try await store.purgingIfRevoked(perform)
    }
    #expect(try store.load()?.connections.isEmpty == false)
    #expect(try keys.read("product-sync." + account) != nil)
    let prompts = google.hints.count + apple.signIns
    revoked = true
    #expect(
      try await store.purgingIfRevoked(perform)
        == ["kind": "signed-out", "notice": "revoked"])
    #expect(google.hints.count + apple.signIns == prompts)
    #expect(store.session == nil)
    for item in ["registration", "product-sync." + account, "product-sync-enrollment." + account] {
      #expect(try keys.read(item) == nil)
    }
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
        connect: { identity, device, _ in
          try backend.connect("account-" + identity.subject, device: device)
        })
    }
    _ = try await store().signIn(with: .apple)
    #expect(
      try await store().purgingIfRevoked { try await $0.restore() }["kind"] == "mailbox-needed")
    // Offline, an Apple relaunch keeps the saved account usable.
    revoked = nil
    #expect(
      try await store().purgingIfRevoked { try await $0.restore() }["kind"] == "mailbox-needed")
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
