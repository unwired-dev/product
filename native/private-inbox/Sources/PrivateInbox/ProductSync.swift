import CryptoKit
import Foundation
import os

// One stored Product Sync record as Convex returns it.
struct StoredPayload: Codable, Equatable {
  let payloadIdentifier: String
  let encryptedPayload: EncryptedPayload
  let updatedAt: Double
}

// The Convex HTTP API response; ConvexError data carries a stable code.
struct ConvexEnvelope<Value: Decodable>: Decodable {
  struct Failure: Decodable { let code: String }
  let status: String
  let value: Value?
  let errorData: Failure?
}

// The write refusals distinguishable from transport or backend failure.
enum ProductSyncWriteFailure: String, Error {
  case payloadChanged = "PRODUCT_SYNC_PAYLOAD_CHANGED"
  // A removal moved the account to a newer key epoch; the write is sealed again after adopting it.
  case keyRotationRequired = "PRODUCT_SYNC_KEY_ROTATION_REQUIRED"
}

// Why an activation changed nothing and its proposal cannot apply as prepared.
enum RevocationFailure: String, Error {
  // The epoch, recovery record or remaining devices changed since the proposal was prepared.
  case conflict = "KEY_ROTATION_CONFLICT"
  case targetRemoved = "TRUSTED_DEVICE_ALREADY_REMOVED"
}

// Backend steps for End-to-End Encrypted Product Sync that native code still sequences. Every call
// presents this device's proof: a Trusted Device's, or for its own admission, a Pending Device's.
// TypeScript initializes Product Sync and synchronizes mailbox descriptors through the credentialed
// call; record listing and writes stay here for native Draft sync only.
struct ProductSyncBackend {
  let list:
    (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> [StoredPayload]
  // Compare-and-set: returns the stored record, which differs from ours when another write won.
  // Throws ProductSyncWriteFailure.payloadChanged when an expected record no longer exists.
  let put:
    (ProductSignInIdentity, ProductRegistrationReceipt, String, EncryptedPayload, Double?)
      async throws -> StoredPayload
  // A Pending Device asks with a one-time public key and the encryption key it will bind,
  // replacing any earlier request.
  let requestEnrollment:
    (
      ProductSignInIdentity, ProductRegistrationReceipt, Curve25519.KeyAgreement.PublicKey,
      Curve25519.KeyAgreement.PublicKey
    ) async throws -> Void
  let enrollmentStatus:
    (ProductSignInIdentity, ProductRegistrationReceipt) async throws -> EnrollmentStatus
  // Sent once the Pending Device stored its keys, with the encryption key its approval or Recovery
  // Key proof named: its new Trusted Device id, or nil when the authorization became void or
  // named another key, and it stays pending.
  let completeEnrollment:
    (ProductSignInIdentity, ProductRegistrationReceipt, Int, Curve25519.KeyAgreement.PublicKey)
      async throws -> String?
  // A Trusted Device without a bound encryption key binds one with the current Recovery Key's
  // proof: false for another key. A different key already bound is never replaced.
  let bindDeviceKey:
    (ProductSignInIdentity, ProductRegistrationReceipt, Curve25519.KeyAgreement.PublicKey, String)
      async throws -> Bool
  // A Pending Device's Recovery Key proof with the encryption key it will bind: the newest recovery
  // envelope, or nil for another Recovery Key.
  let recoverPending:
    (ProductSignInIdentity, ProductRegistrationReceipt, String, Curve25519.KeyAgreement.PublicKey)
      async throws -> EncryptedPayload?
  // Requests from other devices of the account that are still waiting for approval.
  let pendingEnrollments:
    (ProductSignInIdentity, ProductRegistrationReceipt) async throws -> [PendingEnrollment]
  let approveEnrollment:
    (
      ProductSignInIdentity, ProductRegistrationReceipt, PendingEnrollment, Int,
      KeyRingEnvelope.Enrollment
    ) async throws -> Void
  let declineEnrollment:
    (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> Void
  // The account's published recovery envelope, opened only on this device with the Recovery Key.
  let recoveryEnvelope:
    (ProductSignInIdentity, ProductRegistrationReceipt) async throws -> StoredPayload
  // This device's latest complete key ring, sealed to its encryption key by the newest removal.
  let keyRotation:
    (ProductSignInIdentity, ProductRegistrationReceipt) async throws -> KeyRingEnvelope.Rotation?
  // Records adoption only; it never holds back a removal.
  let acknowledgeRotation:
    (ProductSignInIdentity, ProductRegistrationReceipt, Int) async throws -> Void
  // Every Trusted Device of the account, this one included, with its bound encryption key.
  let trustedDevices:
    (ProductSignInIdentity, ProductRegistrationReceipt) async throws -> [TrustedDevice]
  // Activates a prepared removal with a recent Product Sign-In, all at once or not at all: the new
  // epoch's key ring for every remaining device, the recovery envelope and verifier. Returns the
  // new epoch, also for a repeat of an activated proposal.
  let activateRevocation:
    (ProductSignInIdentity, ProductRegistrationReceipt, RevocationRequest) async throws -> Int
  // A proposal the account activated, and whether its Recovery Key is still the current one.
  let revocationOutcome:
    (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> (
      keyEpoch: Int, recoveryKeyCurrent: Bool
    )?
  // One record, or nil when none is stored.
  var get: (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> StoredPayload? =
    { _, _, _ in throw RegistrationError.unavailable }
  // Claims an opaque Draft delivery identifier for this Trusted Device: true when it holds the
  // claim, the first to ask or asking again, false when another device holds it.
  var claimDelivery: (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> Bool =
    { _, _, _ in throw RegistrationError.unavailable }

}

struct TrustedDevice: Codable, Equatable {
  let id: String
  let name: String
  // Milliseconds since 1970, as Convex records it.
  let registeredAt: Double
  // The raw public key a removal seals its key ring to; never shown, so never encoded.
  var encryptionKey: Data? = nil

  enum CodingKeys: String, CodingKey { case id, name, registeredAt }
}

// Everything one removal sends, kept unchanged so a repeat after a lost reply is the same proposal.
struct RevocationRequest: Codable, Equatable {
  struct Envelope: Codable, Equatable {
    let trustedDeviceId: String
    let publicKey: Data
    let envelope: KeyRingEnvelope.Rotation
  }
  let proposalId: String
  let trustedDeviceId: String
  let expectedKeyEpoch: Int
  let expectedRecoveryUpdatedAt: Double
  let envelopes: [Envelope]
  let recovery: EncryptedPayload
  let recoveryVerifier: String
}

// A Pending Device's request to receive this Product Account's keys.
struct PendingEnrollment {
  let pendingDeviceId: String
  let publicKey: Curve25519.KeyAgreement.PublicKey
  // The encryption key the approval is bound to and the device binds when it is admitted.
  let deviceKey: Curve25519.KeyAgreement.PublicKey
  let deviceName: String
  let expiresAt: Double
}

struct EnrollmentStatus {
  enum State: String, Decodable {
    case pending, approved, cancelled, expired
  }
  let state: State
  // Present only while approved: the key epoch and the envelope sealed to this device.
  var approval: (keyVersion: Int, envelope: KeyRingEnvelope.Enrollment)?
}

// This Pending Device's open enrollment request, kept in a device-only Keychain item until it is
// admitted.
struct ProductSyncEnrollment: Codable {
  var version = 2
  let productAccountId: String
  let pendingDeviceId: String
  let privateKey: Data
  let code: String
  // Why the previous request ended without unlocking this device: renewed or rejected.
  var notice: String?
}

// The device-held keys for one Product Account, kept in a device-only Keychain item.
struct ProductSyncVault: Codable {
  var version = 1
  let productAccountId: String
  var ring: ProductSyncKeyRing
  // Held by the device that created the keys until its setup is confirmed; others never receive it.
  var recoveryKey: Data?
  var recoveryEnvelope: EncryptedPayload?
  // Convex accepted this device's recovery envelope as the account's key material.
  var published = false
  var recoveryKeyConfirmed = false
  // Mailbox descriptors this device read back from Product Sync, by record identifier.
  var savedMailboxes: [String: String]?
  // Every mailbox address last read back and decrypted, shown when no session is available.
  var readMailboxes: [String]?
  // The epoch of every readable mailbox descriptor last read back, removed or not, by record
  // identifier; empty for a descriptor written before epochs.
  var descriptorEpochs: [String: String]?
  // A removal prepared on this device and not yet activated.
  var revocation: PendingRevocation?

  // The only copy of a Recovery Key not yet backed up, or a removal whose outcome is unknown.
  var holdsUnsettledKeys: Bool {
    (recoveryKey != nil && !recoveryKeyConfirmed) || revocation?.submitted == true
  }
}

struct PendingRevocation: Codable, Equatable {
  let request: RevocationRequest
  // The replacement Recovery Key; activation is sent only after the person confirms saving it.
  let recoveryKey: Data
  // An activation was sent without a definite answer; the account may already have applied it.
  var submitted = false
}

// The synchronized description of a Mailbox Connection; credentials never enter it. A removed
// connection keeps a descriptor marked removed, so every Trusted Device purges its authorization.
struct MailboxDescriptor: Codable, Equatable {
  static let schemaVersion = 1
  let provider: String
  let address: String
  // Renewed whenever the connection is added after a removal, or first published.
  var epoch: String? = nil
  var removed: Bool? = nil
}

extension RegistrationStore {
  static let productSyncLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.unwired.mail", category: "product-sync")

  // Logs the error's domain and code only; descriptions can carry account or key details.
  static func logProductSyncFailure(_ event: String, _ error: any Error) {
    let error = error as NSError
    productSyncLogger.error(
      "\(event, privacy: .public): \(error.domain, privacy: .public) \(error.code)")
  }

  func vaultAccount(_ productAccountId: String) -> String { "product-sync." + productAccountId }

  func loadVault(_ productAccountId: String) throws -> ProductSyncVault? {
    guard let data = try keys.read(vaultAccount(productAccountId)) else { return nil }
    let vault = try JSONDecoder().decode(ProductSyncVault.self, from: data)
    guard vault.version == 1, vault.productAccountId == productAccountId else {
      throw RegistrationError.unavailable
    }
    return vault
  }

  func saveVault(_ vault: ProductSyncVault) throws {
    try keys.save(JSONEncoder().encode(vault), account: vaultAccount(vault.productAccountId))
  }

  func enrollmentAccount(_ productAccountId: String) -> String {
    "product-sync-enrollment." + productAccountId
  }

  func deviceKeyAccount(_ productAccountId: String) -> String {
    "product-sync-device-key." + productAccountId
  }

  // This installation's long-lived encryption key for the account, created once and kept apart
  // from the key ring, so a retry after a lost reply presents the same key.
  func deviceKey(_ productAccountId: String, creatingIfMissing: Bool = false) throws
    -> Curve25519.KeyAgreement.PrivateKey
  {
    if let data = try keys.read(deviceKeyAccount(productAccountId)) {
      return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }
    guard creatingIfMissing else { throw RegistrationError.unavailable }
    let key = Curve25519.KeyAgreement.PrivateKey()
    try keys.save(key.rawRepresentation, account: deviceKeyAccount(productAccountId))
    return key
  }

  // This device's open request, only while it belongs to the same account and Pending Device.
  func loadEnrollment(_ product: ProductRegistrationReceipt) throws -> ProductSyncEnrollment? {
    guard product.pending == true,
      let data = try keys.read(enrollmentAccount(product.productAccountId))
    else { return nil }
    let enrollment = try? JSONDecoder().decode(ProductSyncEnrollment.self, from: data)
    guard let enrollment, enrollment.version == 2,
      enrollment.productAccountId == product.productAccountId,
      enrollment.pendingDeviceId == product.trustedDeviceId
    else { return nil }
    return enrollment
  }

  // Creates the account's key ring and Recovery Key once and stores both before anything is
  // published, then returns what initialization sends: the recovery envelope, its Recovery Key
  // verifier and this device's public encryption key. A retry after an interruption returns the
  // same keys; only an account known to hold no key material creates them.
  func createKeyRing() throws -> [String: Any] {
    guard let product = try saved().product, product.pending != true else {
      throw RegistrationError.unavailable
    }
    let account = product.productAccountId
    var vault = try loadVault(account)
    if vault == nil {
      guard product.productSyncMaterialInitialized == false else {
        throw RegistrationError.unavailable
      }
      let ring = ProductSyncKeyRing.create()
      let recovery = RecoveryKey.generate()
      let created = ProductSyncVault(
        productAccountId: account, ring: ring, recoveryKey: recovery.bytes,
        recoveryEnvelope: try KeyRingEnvelope.recovery(ring, key: recovery, account: account))
      try saveVault(created)
      vault = created
    }
    guard let vault, !vault.published, let envelope = vault.recoveryEnvelope,
      let recoveryKey = vault.recoveryKey
    else { throw RegistrationError.unavailable }
    return [
      "recoveryEnvelope": try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)),
      "recoveryVerifier": try KeyRingEnvelope.recoveryVerifier(
        RecoveryKey(bytes: recoveryKey), account: account),
      "deviceKey": try deviceKey(account, creatingIfMissing: true).publicKey.rawRepresentation
        .base64EncodedString(),
    ]
  }

  // Convex's answer to initialization: this device's keys became the account's, or the account
  // already holds other key material, which these unpublished keys never replace.
  func recordInitialization(_ initialized: Bool) throws {
    var saved = try saved()
    guard var product = saved.product, var vault = try loadVault(product.productAccountId),
      !vault.published
    else { throw RegistrationError.unavailable }
    if initialized {
      vault.published = true
      try saveVault(vault)
      return
    }
    try keys.remove(vaultAccount(product.productAccountId))
    product.productSyncMaterialInitialized = true
    saved.product = product
    try save(saved)
  }

  // A Trusted Device that lost its encryption key cannot replace its immutable registration. It
  // retains that row, durably chooses a new installation and connects again with the verified
  // Product Sign-In as a Pending Device of the same account. Never discards the only copy of an
  // unconfirmed Recovery Key or an unanswered removal.
  func reenroll() async throws {
    guard let session else { throw RegistrationError.unavailable }
    var saved = try saved()
    guard var product = saved.product, product.pending != true else {
      throw RegistrationError.unavailable
    }
    let account = product.productAccountId
    guard try keys.read(deviceKeyAccount(account)) == nil,
      try loadVault(account)?.holdsUnsettledKeys != true
    else { throw RegistrationError.unavailable }
    saved.deviceIdentifier = UUID().uuidString
    product.pending = true
    saved.product = product
    try save(saved)
    try keys.remove(vaultAccount(account))
    try keys.remove(enrollmentAccount(account))
    let rejoined = try await connect(session, saved.deviceIdentifier, product)
    guard rejoined.productAccountId == account else { throw RegistrationError.invalidIdentity }
    saved.product = rejoined
    try save(saved)
    forgetMailboxAccess()
    enrollmentRequests[account] = nil
    trustedDevices[account] = nil
  }

  // Temporary until #758 moves enrollment: this Pending Device's admission. True once it is a
  // Trusted Device.
  func admitPendingDevice() async throws -> Bool {
    guard let backend = productSync, let session, let saved = try load(),
      saved.product?.pending == true
    else { throw RegistrationError.unavailable }
    return try await admit(saved, backend: backend, session: session) != nil
  }

  // Temporary until #758 moves rotation: adopts this device's newest key ring.
  func adoptLatestRotation() async throws {
    guard let backend = productSync, let session, let product = try saved().product,
      let vault = try loadVault(product.productAccountId)
    else { throw RegistrationError.unavailable }
    _ = try await adoptRotation(vault, backend: backend, session: session, product)
  }

  // Temporary until #758 moves enrollment and revocation: other devices' enrollment requests and
  // the account's other Trusted Devices, kept for approval and removal in this process.
  func refreshDevices() async throws {
    guard let backend = productSync, let session, let product = try saved().product else {
      throw RegistrationError.unavailable
    }
    let account = product.productAccountId
    enrollmentRequests[account] = try await backend.pendingEnrollments(session, product)
    trustedDevices[account] = try await backend.trustedDevices(session, product).filter {
      $0.id != product.trustedDeviceId
    }
  }

  // Only now may an explicit consent adopt a removed descriptor it encounters for the first time.
  func finishSynchronization() {
    newlyAuthorizedMailboxes = []
  }

  // The published keys of the signed-in Trusted Device.
  func publishedVault() throws -> ProductSyncVault {
    guard let product = try saved().product, product.pending != true,
      let vault = try loadVault(product.productAccountId), vault.published
    else { throw RegistrationError.unavailable }
    return vault
  }

  // Seals a mailbox descriptor under its record identifier at the newest key epoch.
  func sealMailboxDescriptor(_ record: String, _ descriptor: [String: Any]) throws -> [String: Any]
  {
    let vault = try publishedVault()
    guard record.hasPrefix("mailbox."),
      let value = try? JSONDecoder().decode(
        MailboxDescriptor.self, from: JSONSerialization.data(withJSONObject: descriptor))
    else { throw RegistrationError.unavailable }
    let sealed = try vault.ring.seal(
      record: JSONEncoder().encode(value), account: vault.productAccountId, identifier: record,
      schemaVersion: MailboxDescriptor.schemaVersion)
    guard
      let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sealed))
        as? [String: Any]
    else { throw RegistrationError.unavailable }
    return payload
  }

  // Each stored record's descriptor when it opens for this account under its own identifier,
  // otherwise null: a record that fails to open or decode is never shown and never replaced.
  func openMailboxDescriptors(_ records: [Any]) throws -> [Any] {
    let vault = try publishedVault()
    return records.map { record in
      guard let record = record as? [String: Any],
        let identifier = record["payloadIdentifier"] as? String,
        let payload = record["encryptedPayload"],
        let data = try? JSONSerialization.data(withJSONObject: payload),
        let sealed = try? JSONDecoder().decode(EncryptedPayload.self, from: data),
        let plaintext = try? vault.ring.open(
          record: sealed, account: vault.productAccountId, identifier: identifier,
          schemaVersion: MailboxDescriptor.schemaVersion),
        let descriptor = try? JSONDecoder().decode(MailboxDescriptor.self, from: plaintext),
        let object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor))
      else { return NSNull() }
      return object
    }
  }

  // What synchronization learned about this device's connections: each changed descriptor epoch,
  // each connection read back, and the removals Product Sync now records. Applied to the record as
  // stored now, so work interleaved between TypeScript's steps is kept.
  func recordMailboxChanges(connections: [[String: Any]], settledRemovals: [String]) throws {
    var saved = try saved()
    for change in connections {
      guard let id = change["id"] as? String else { throw RegistrationError.unavailable }
      saved.update(id) {
        // A null epoch, as an adopted winner from before epochs carries, clears it.
        if change.keys.contains("epoch") { $0.epoch = change["epoch"] as? String }
        if change["published"] as? Bool == true { $0.published = true }
      }
    }
    if !settledRemovals.isEmpty, let product = saved.product,
      let vault = try loadVault(product.productAccountId)
    {
      saved.mailboxRemovals = try saved.mailboxRemovals?.filter {
        !settledRemovals.contains(try vault.ring.identifier("mailbox", $0.receipt.account))
      }
    }
    if saved.mailboxRemovals?.isEmpty == true { saved.mailboxRemovals = nil }
    try save(saved)
  }

  // A connection another device removed, or added again since this one authorized it, leaves this
  // device: its watch stops while its credential still exists, then the credential and cached mail
  // go. A failed relay or cache cleanup stays in the checkpoint for retry.
  func purgeMailbox(_ id: String) async throws {
    try await unroute(id)
    var saved = try saved()
    saved.connections = saved.connections.filter { $0.id != id }
    saved.mailboxCacheRemovals = Array(Set((saved.mailboxCacheRemovals ?? []) + [id])).sorted()
    try save(saved)
    _ = try await retryMailboxCleanup(saved)
  }

  // The descriptors last read back: every live address, the confirmed address of each of this
  // device's connections and every readable descriptor's epoch, by record identifier.
  func recordMailboxReadback(
    addresses: [String], confirmed: [String: String], epochs: [String: String]
  ) throws {
    guard let product = try saved().product, var vault = try loadVault(product.productAccountId)
    else { throw RegistrationError.unavailable }
    guard vault.readMailboxes != addresses || vault.savedMailboxes != confirmed
      || vault.descriptorEpochs != epochs
    else { return }
    vault.readMailboxes = addresses
    vault.savedMailboxes = confirmed
    vault.descriptorEpochs = epochs
    try saveVault(vault)
  }

  // Asks a Trusted Device to approve this Pending Device, and adopts the keys sealed to it once they
  // open with this device's key and code. Admission follows only after the keys are stored. An
  // approval that does not open, or that became void, changes nothing; a new request replaces it.
  // Returns the registration of the admitted Trusted Device, or nil while it still waits.
  func admit(
    _ saved: SavedRegistration, backend: ProductSyncBackend, session: ProductSignInIdentity
  ) async throws -> SavedRegistration? {
    guard let product = saved.product else { throw RegistrationError.unavailable }
    let account = product.productAccountId
    // Keys stored by an attempt that did not hear back whether it was admitted.
    if try loadVault(account) != nil {
      if let admitted = try await confirmAdmission(saved, backend: backend, session: session) {
        return admitted
      }
    }
    var notice: String?
    if let pending = try loadEnrollment(product) {
      let status = try await backend.enrollmentStatus(session, product)
      switch status.state {
      case .pending: return nil
      case .approved:
        if let approval = status.approval,
          let ring = try? KeyRingEnvelope.openEnrollment(
            approval.envelope,
            with: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: pending.privateKey),
            code: EnrollmentCode(parsing: pending.code),
            binding: .init(
              account: account, device: product.trustedDeviceId,
              deviceKey: deviceKey(account).publicKey),
            keyVersion: approval.keyVersion)
        {
          // The account keys are adopted as they are; the Recovery Key stays with its owner.
          try saveVault(
            ProductSyncVault(
              productAccountId: account, ring: ring, published: true, recoveryKeyConfirmed: true))
          if let admitted = try await confirmAdmission(saved, backend: backend, session: session) {
            return admitted
          }
        }
        notice = "rejected"
      case .cancelled, .expired:
        notice = "renewed"
      }
    }
    let key = Curve25519.KeyAgreement.PrivateKey()
    try await backend.requestEnrollment(
      session, product, key.publicKey, deviceKey(account, creatingIfMissing: true).publicKey)
    try keys.save(
      JSONEncoder().encode(
        ProductSyncEnrollment(
          productAccountId: account, pendingDeviceId: product.trustedDeviceId,
          privateKey: key.rawRepresentation, code: EnrollmentCode.generate().digits,
          notice: notice)),
      account: enrollmentAccount(account))
    return nil
  }

  // Confirms keys this Pending Device stored. The backend admits it as a Trusted Device with the same
  // credential; a void authorization leaves it pending, and its keys are discarded.
  func confirmAdmission(
    _ saved: SavedRegistration, backend: ProductSyncBackend, session: ProductSignInIdentity
  ) async throws -> SavedRegistration? {
    guard let product = saved.product else { throw RegistrationError.unavailable }
    let account = product.productAccountId
    guard let vault = try loadVault(account) else { throw RegistrationError.unavailable }
    guard
      let trustedDeviceId = try await backend.completeEnrollment(
        session, product, vault.ring.current, deviceKey(account).publicKey)
    else {
      try keys.remove(vaultAccount(account))
      return nil
    }
    var next = saved
    next.product = ProductRegistrationReceipt(
      productAccountId: account, trustedDeviceId: trustedDeviceId,
      trustedDeviceCredential: product.trustedDeviceCredential,
      signInProviders: product.signInProviders, productSyncMaterialInitialized: true)
    try save(next)
    try keys.remove(enrollmentAccount(account))
    return next
  }

  // What TypeScript reads of this device's Product Sync state: no key, credential or provider
  // subject. The Recovery Key and Enrollment Code cross only as text for display. Record
  // identifiers are the opaque names Product Sync stores descriptors under.
  func productSyncState(_ saved: SavedRegistration) throws -> [String: Any]? {
    guard productSync != nil, let product = saved.product else { return nil }
    let account = product.productAccountId
    var result: [String: Any] = [
      "pending": product.pending == true,
      "deviceKey": try keys.read(deviceKeyAccount(account)) != nil,
      "requests": (enrollmentRequests[account] ?? []).map {
        ["id": $0.pendingDeviceId, "device": $0.deviceName, "expiresAt": $0.expiresAt]
      },
      "trustedDevices": (trustedDevices[account] ?? []).map {
        ["id": $0.id, "name": $0.name, "registeredAt": $0.registeredAt]
      },
    ]
    if let initialized = product.productSyncMaterialInitialized {
      result["materialInitialized"] = initialized
    }
    if let enrollment = try loadEnrollment(product) {
      var entry: [String: Any] = ["code": try EnrollmentCode(parsing: enrollment.code).display]
      if let notice = enrollment.notice { entry["notice"] = notice }
      result["enrollment"] = entry
    }
    guard let vault = try loadVault(account) else { return result }
    func record(_ receipt: GmailRegistrationReceipt) throws -> String {
      try vault.ring.identifier("mailbox", receipt.account)
    }
    var entry: [String: Any] = [
      "keyEpoch": vault.ring.current,
      "published": vault.published,
      "recoveryKeyConfirmed": vault.recoveryKeyConfirmed,
      "mailboxes": try saved.connections.map { connection in
        var mailbox: [String: Any] = [
          "id": connection.id, "record": try record(connection.receipt),
          "published": connection.published == true,
          "newlyAuthorized": newlyAuthorizedMailboxes.contains(connection.id),
        ]
        if let observed = connection.observed { mailbox["observed"] = observed }
        if let observedEpoch = connection.observedEpoch { mailbox["observedEpoch"] = observedEpoch }
        return mailbox
      },
      "removals": try (saved.mailboxRemovals ?? []).map { removal in
        var entry: [String: Any] = [
          "id": MailboxConnection.id(removal.receipt),
          "record": try record(removal.receipt), "address": removal.address,
          "provider": removal.receipt.mailProvider.rawValue,
        ]
        if let epoch = removal.epoch { entry["epoch"] = epoch }
        return entry
      },
    ]
    // Only an unconfirmed Recovery Key is shown; a confirmed one never leaves native storage.
    if let recoveryKey = vault.recoveryKey, !vault.recoveryKeyConfirmed {
      entry["recoveryKey"] = try RecoveryKey(bytes: recoveryKey).display
    }
    if let revocation = vault.revocation {
      entry["revocation"] = [
        "device": revocation.request.trustedDeviceId,
        "recoveryKey": try RecoveryKey(bytes: revocation.recoveryKey).display,
        "submitted": revocation.submitted,
      ]
    }
    if let mailboxes = vault.readMailboxes { entry["readMailboxes"] = mailboxes }
    if let mailboxes = vault.savedMailboxes { entry["savedMailboxes"] = mailboxes }
    result["vault"] = entry
    return result
  }

  func confirmRecoveryKey(_ entry: String) throws {
    guard let saved = try load(), let product = saved.product,
      var vault = try loadVault(product.productAccountId), vault.published
    else { throw RegistrationError.unavailable }
    if !vault.recoveryKeyConfirmed {
      guard let recoveryKey = vault.recoveryKey,
        try RecoveryKey(bytes: recoveryKey).confirms(entry)
      else {
        throw RegistrationError.recoveryKeyMismatch
      }
      vault.recoveryKeyConfirmed = true
      try saveVault(vault)
    }
  }

  // Seals this device's keys to another device of the account, unlocked by the code it shows.
  func approveEnrollment(_ requestId: String, code entry: String) async throws {
    let code: EnrollmentCode
    do { code = try EnrollmentCode(parsing: entry) } catch {
      throw RegistrationError.enrollmentCodeInvalid
    }
    guard let backend = productSync, let session, let saved = try load(),
      let product = saved.product, product.pending != true,
      var vault = try loadVault(product.productAccountId), vault.published,
      let request = enrollmentRequests[product.productAccountId]?.first(where: {
        $0.pendingDeviceId == requestId
      })
    else { throw RegistrationError.enrollmentUnavailable }
    _ = try deviceKey(product.productAccountId)
    // Only the account's newest key epoch is sealed; a pending one is adopted first.
    vault = try await adoptRotation(vault, backend: backend, session: session, product)
    let envelope = try KeyRingEnvelope.enrollment(
      vault.ring, to: request.publicKey, code: code,
      binding: .init(
        account: product.productAccountId, device: request.pendingDeviceId,
        deviceKey: request.deviceKey))
    try await backend.approveEnrollment(session, product, request, vault.ring.current, envelope)
    enrollmentRequests[product.productAccountId]?.removeAll { $0.pendingDeviceId == requestId }
  }

  func declineEnrollment(_ requestId: String) async throws {
    guard let backend = productSync, let session, let saved = try load(),
      let product = saved.product
    else { throw RegistrationError.enrollmentUnavailable }
    _ = try deviceKey(product.productAccountId)
    try await backend.declineEnrollment(session, product, requestId)
    enrollmentRequests[product.productAccountId]?.removeAll { $0.pendingDeviceId == requestId }
  }

}
