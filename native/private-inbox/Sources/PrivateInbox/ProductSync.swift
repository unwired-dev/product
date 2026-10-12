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

// Backend steps for End-to-End Encrypted Product Sync that native Draft sync still sequences. Every
// call presents this Trusted Device's proof. TypeScript sequences initialization, mailbox
// descriptors, enrollment, recovery, key rotation and revocation through the credentialed call.
struct ProductSyncBackend {
  let list:
    (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> [StoredPayload]
  // Compare-and-set: returns the stored record, which differs from ours when another write won.
  // Throws ProductSyncWriteFailure.payloadChanged when an expected record no longer exists.
  let put:
    (ProductSignInIdentity, ProductRegistrationReceipt, String, EncryptedPayload, Double?)
      async throws -> StoredPayload
  // One record, or nil when none is stored.
  var get: (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> StoredPayload? =
    { _, _, _ in throw RegistrationError.unavailable }
  // Claims an opaque Draft delivery identifier for this Trusted Device: true when it holds the
  // claim, the first to ask or asking again, false when another device holds it.
  var claimDelivery: (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> Bool =
    { _, _, _ in throw RegistrationError.unavailable }
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

  // Creates and stores this Pending Device's one-time key pair and Enrollment Code, replacing an
  // earlier request's, and returns the public keys its request names: the one-time key and the
  // encryption key it keeps once admitted. `notice` says why the previous request ended without
  // unlocking this device. The code is shown through the projection.
  func beginEnrollment(notice: String?) throws -> [String: String] {
    guard notice.map({ ["renewed", "rejected"].contains($0) }) ?? true,
      let product = try saved().product, product.pending == true
    else { throw RegistrationError.unavailable }
    let account = product.productAccountId
    let deviceKey = try deviceKey(account, creatingIfMissing: true)
    let key = Curve25519.KeyAgreement.PrivateKey()
    try keys.save(
      JSONEncoder().encode(
        ProductSyncEnrollment(
          productAccountId: account, pendingDeviceId: product.trustedDeviceId,
          privateKey: key.rawRepresentation, code: EnrollmentCode.generate().digits,
          notice: notice)),
      account: enrollmentAccount(account))
    return [
      "enrollmentPublicKey": key.publicKey.rawRepresentation.base64EncodedString(),
      "deviceKey": deviceKey.publicKey.rawRepresentation.base64EncodedString(),
    ]
  }

  // Opens an approval with this Pending Device's one-time key and code, bound to its account,
  // device, encryption key and the approval's key epoch, and stores the account keys as they are;
  // the Recovery Key stays with its owner. False when it does not open, which changes nothing.
  func openEnrollment(_ approval: [String: Any]) throws -> Bool {
    guard let product = try saved().product, let pending = try loadEnrollment(product) else {
      throw RegistrationError.unavailable
    }
    let account = product.productAccountId
    guard let keyVersion = approval["keyVersion"] as? Int,
      let encapsulatedKey = (approval["encapsulatedKeyBase64"] as? String).flatMap({
        Data(base64Encoded: $0)
      }),
      let ciphertext = (approval["ciphertextBase64"] as? String).flatMap({
        Data(base64Encoded: $0)
      }),
      let ring = try? KeyRingEnvelope.openEnrollment(
        .init(encapsulatedKey: encapsulatedKey, ciphertext: ciphertext),
        with: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: pending.privateKey),
        code: EnrollmentCode(parsing: pending.code),
        binding: .init(
          account: account, device: product.trustedDeviceId,
          deviceKey: deviceKey(account).publicKey),
        keyVersion: keyVersion)
    else { return false }
    try saveVault(
      ProductSyncVault(
        productAccountId: account, ring: ring, published: true, recoveryKeyConfirmed: true))
    return true
  }

  // Confirms the keys this Pending Device stored, with the encryption key its approval or Recovery
  // Key proof named. Convex admits it as a Trusted Device under a new identifier with the same
  // credential, which is saved before returning true. A void authorization leaves it pending, and
  // its keys are discarded.
  func confirmAdmission() async throws -> Bool {
    var saved = try saved()
    guard let product = saved.product, product.pending == true,
      let vault = try loadVault(product.productAccountId)
    else { throw RegistrationError.unavailable }
    let account = product.productAccountId
    struct Completion: Decodable {
      let admitted: Bool
      let trustedDeviceId: String?
    }
    let completion: Completion? = try await credentialedCall(
      "productSyncEnrollment:complete",
      [
        "keyVersion": vault.ring.current,
        "deviceEncryptionPublicKey": try deviceKey(account).publicKey.rawRepresentation
          .base64EncodedString(),
      ])
    guard let completion else { throw RegistrationError.unavailable }
    guard completion.admitted, let trustedDeviceId = completion.trustedDeviceId else {
      try keys.remove(vaultAccount(account))
      return false
    }
    saved.product = ProductRegistrationReceipt(
      productAccountId: account, trustedDeviceId: trustedDeviceId,
      trustedDeviceCredential: product.trustedDeviceCredential,
      signInProviders: product.signInProviders, productSyncMaterialInitialized: true)
    try save(saved)
    try keys.remove(enrollmentAccount(account))
    return true
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
      "deviceId": product.trustedDeviceId,
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
        "proposal": revocation.request.proposalId,
        "device": revocation.request.trustedDeviceId,
        "recoveryKey": try RecoveryKey(bytes: revocation.recoveryKey).display,
        "submitted": revocation.submitted,
      ]
    }
    if let mailboxes = vault.readMailboxes { entry["readMailboxes"] = mailboxes }
    if let mailboxes = vault.savedMailboxes { entry["savedMailboxes"] = mailboxes }
    if let profiles = saved.profiles {
      entry["profiles"] = try JSONSerialization.jsonObject(with: profiles)
    }
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

  // Whether an entry reads as an Enrollment Code, check digit included, so a mistyped one is caught
  // before anything is sent.
  func readsAsEnrollmentCode(_ entry: String) -> Bool {
    (try? EnrollmentCode(parsing: entry)) != nil
  }

  // Seals this device's key ring to another device's request, bound to its account, Pending
  // Device and the encryption key it will keep, and unlocked only by the code that device shows.
  // Returns the approval Convex stores; the code never leaves this device.
  func sealEnrollment(_ entry: String, request: [String: Any]) throws -> [String: Any] {
    let code: EnrollmentCode
    do { code = try EnrollmentCode(parsing: entry) } catch {
      throw RegistrationError.enrollmentCodeInvalid
    }
    guard let product = try saved().product, product.pending != true,
      let vault = try loadVault(product.productAccountId), vault.published,
      let pendingDeviceId = request["pendingDeviceId"] as? String,
      let enrollmentKey = Self.publicKey(request["enrollmentPublicKey"]),
      let requestDeviceKey = Self.publicKey(request["deviceEncryptionPublicKey"])
    else { throw RegistrationError.enrollmentUnavailable }
    _ = try deviceKey(product.productAccountId)
    let envelope = try KeyRingEnvelope.enrollment(
      vault.ring, to: enrollmentKey, code: code,
      binding: .init(
        account: product.productAccountId, device: pendingDeviceId,
        deviceKey: requestDeviceKey))
    return [
      "keyVersion": vault.ring.current,
      "encapsulatedKeyBase64": envelope.encapsulatedKey.base64EncodedString(),
      "ciphertextBase64": envelope.ciphertext.base64EncodedString(),
    ]
  }

  // A raw X25519 public key as Convex lists it, in base64.
  static func publicKey(_ value: Any?) -> Curve25519.KeyAgreement.PublicKey? {
    (value as? String).flatMap { Data(base64Encoded: $0) }.flatMap {
      try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0)
    }
  }
}
