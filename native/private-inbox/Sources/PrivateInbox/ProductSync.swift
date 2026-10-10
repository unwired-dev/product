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

// The only conditional-write refusal distinguishable from transport or backend failure.
enum ProductSyncWriteFailure: String, Error {
  case payloadChanged = "PRODUCT_SYNC_PAYLOAD_CHANGED"
}

// Backend steps for End-to-End Encrypted Product Sync. Every call presents this device's proof:
// a Trusted Device's, or for its own admission, a Pending Device's.
struct ProductSyncBackend {
  // Stores the first recovery envelope with its Recovery Key verifier and marks the account
  // initialized in one step. False when the account already holds other key material, which this
  // device must not replace.
  let initialize:
    (ProductSignInIdentity, ProductRegistrationReceipt, EncryptedPayload, String) async throws ->
      Bool
  let list:
    (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> [StoredPayload]
  // Compare-and-set: returns the stored record, which differs from ours when another write won.
  // Throws ProductSyncWriteFailure.payloadChanged when an expected record no longer exists.
  let put:
    (ProductSignInIdentity, ProductRegistrationReceipt, String, EncryptedPayload, Double?)
      async throws -> StoredPayload
  // A Pending Device asks with a one-time public key, replacing any earlier one.
  let requestEnrollment:
    (ProductSignInIdentity, ProductRegistrationReceipt, Curve25519.KeyAgreement.PublicKey)
      async throws -> Void
  let enrollmentStatus:
    (ProductSignInIdentity, ProductRegistrationReceipt) async throws -> EnrollmentStatus
  // Sent once the Pending Device stored its keys: its new Trusted Device id, or nil when the
  // authorization became void and it stays pending.
  let completeEnrollment:
    (ProductSignInIdentity, ProductRegistrationReceipt, Int) async throws -> String?
  // A Pending Device's Recovery Key proof: the newest recovery envelope, or nil for another key.
  let recoverPending:
    (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> EncryptedPayload?
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
  // The key epoch a revocation started and the remaining devices have not all adopted yet.
  let keyRotation: (ProductSignInIdentity, ProductRegistrationReceipt) async throws -> KeyRotation?
  let acknowledgeRotation:
    (ProductSignInIdentity, ProductRegistrationReceipt, Int) async throws -> Void
  let trustedDevices:
    (ProductSignInIdentity, ProductRegistrationReceipt) async throws -> [TrustedDevice]
  // Removes another device with a recent Product Sign-In: the new key ring sealed to the account's
  // committed key, the new recovery envelope and its Recovery Key verifier, and the recovery
  // record time it replaces.
  let revoke:
    (
      ProductSignInIdentity, ProductRegistrationReceipt, String, EncryptedPayload, EncryptedPayload,
      String, Double
    ) async throws -> Void
  // One record, or nil when none is stored.
  var get: (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> StoredPayload? =
    { _, _, _ in throw RegistrationError.unavailable }
  // Claims an opaque Draft delivery identifier for this Trusted Device: true when it holds the
  // claim, the first to ask or asking again, false when another device holds it.
  var claimDelivery: (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> Bool =
    { _, _, _ in throw RegistrationError.unavailable }

}

struct KeyRotation: Equatable {
  let keyEpoch: Int
  // The new key ring, sealed to the committed epoch's key that every remaining device holds.
  let transition: EncryptedPayload
}

struct TrustedDevice: Codable, Equatable {
  let id: String
  let name: String
  // Milliseconds since 1970, as Convex records it.
  let registeredAt: Double
}

// A Pending Device's request to receive this Product Account's keys.
struct PendingEnrollment {
  let pendingDeviceId: String
  let publicKey: Curve25519.KeyAgreement.PublicKey
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
  // Held by the device that created the keys or last removed a device; others never receive it.
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
  // A removal sent without a reply yet: its target, new Recovery Key and exact transition.
  var revocation: PendingRevocation?
}

struct PendingRevocation: Codable {
  let recoveryKey: Data
  let transition: EncryptedPayload
  // Older saved attempts have no target; their key can be adopted without attributing a removal.
  let trustedDeviceId: String?
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
  // The epoch every device gives a descriptor written before epochs, so their upgrades agree.
  static let legacyMailboxEpoch = "legacy"
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

  // Only uninitialized accounts create keys; losing initialization discards unpublished keys.
  // Initialization, enrollment and descriptor publication share one ordered account/session flow.
  // swiftlint:disable:next cyclomatic_complexity
  func synchronize(_ saved: SavedRegistration) async throws -> SavedRegistration {
    guard let backend = productSync, let session, var product = saved.product else { return saved }
    let account = product.productAccountId
    var saved = try await retryMailboxCleanup(saved)
    do {
      // A Pending Device first has to be admitted; until then it reads and writes nothing.
      if product.pending == true {
        guard product.productSyncMaterialInitialized == true,
          let admitted = try await admit(saved, backend: backend, session: session),
          let receipt = admitted.product
        else { return saved }
        saved = admitted
        product = receipt
      }
      var vault = try loadVault(account)
      if vault == nil {
        guard product.productSyncMaterialInitialized == false else { return saved }
        let ring = ProductSyncKeyRing.create()
        let recovery = RecoveryKey.generate()
        let created = ProductSyncVault(
          productAccountId: account, ring: ring, recoveryKey: recovery.bytes,
          recoveryEnvelope: try KeyRingEnvelope.recovery(ring, key: recovery, account: account))
        // Saved before publication so an interrupted attempt resumes with the same keys.
        try saveVault(created)
        vault = created
      }
      guard var current = vault else { return saved }
      if current.published {
        current = try await adoptRotation(current, backend: backend, session: session, product)
      } else {
        guard let envelope = current.recoveryEnvelope, let recoveryKey = current.recoveryKey else {
          throw RegistrationError.unavailable
        }
        let verifier = try KeyRingEnvelope.recoveryVerifier(
          RecoveryKey(bytes: recoveryKey), account: account)
        guard try await backend.initialize(session, product, envelope, verifier) else {
          try keys.remove(vaultAccount(account))
          var next = saved
          product.productSyncMaterialInitialized = true
          next.product = product
          try save(next)
          return next
        }
        current.published = true
        try saveVault(current)
      }
      let mailboxes = try await synchronizeMailboxes(
        saved, vault: current, backend: backend, session: session)
      saved = mailboxes.saved
      var next = current
      next.readMailboxes = mailboxes.addresses
      next.savedMailboxes = mailboxes.confirmed
      next.descriptorEpochs = mailboxes.epochs
      if next.readMailboxes != current.readMailboxes
        || next.savedMailboxes != current.savedMailboxes
        || next.descriptorEpochs != current.descriptorEpochs
      {
        try saveVault(next)
      }
      enrollmentRequests[account] = try await backend.pendingEnrollments(session, product)
      trustedDevices[account] = try await backend.trustedDevices(session, product).filter {
        $0.id != product.trustedDeviceId
      }
    } catch let error as RegistrationError where error.endsAccess {
      throw error
    } catch {
      // Product Sync stays pending; registration and the mailbox remain usable.
      Self.logProductSyncFailure("Product Sync failed", error)
    }
    // A descriptor purge may have durably removed credentials before a later step failed.
    return (try load()) ?? saved
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
            binding: .init(account: account, device: product.trustedDeviceId),
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
    try await backend.requestEnrollment(session, product, key.publicKey)
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
        session, product, vault.ring.current)
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

  // Marks this device's removals in Product Sync, purges connections another device removed or
  // added again since this device authorized them, publishes descriptors Product Sync lacks, and
  // reads every descriptor back. Returns the saved registration, the decrypted addresses and the
  // descriptors confirmed for this device's connections.
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func synchronizeMailboxes(
    _ saved: SavedRegistration, vault: ProductSyncVault, backend: ProductSyncBackend,
    session: ProductSignInIdentity
  ) async throws -> (
    saved: SavedRegistration, addresses: [String], confirmed: [String: String],
    epochs: [String: String]
  ) {
    guard let product = saved.product else { return (saved, [], [:], [:]) }
    func identifier(_ subject: String) throws -> String {
      try vault.ring.identifier("mailbox", "gmail:" + subject)
    }
    var stored = try await mailboxDescriptors(vault, backend: backend, session: session, product)
    @discardableResult
    func put(_ identifier: String, _ descriptor: MailboxDescriptor) async throws -> MailboxDescriptor? {
      let sealed = try vault.ring.seal(
        record: JSONEncoder().encode(descriptor), account: vault.productAccountId,
        identifier: identifier, schemaVersion: MailboxDescriptor.schemaVersion)
      let result = try await backend.put(
        session, product, identifier, sealed, stored[identifier]?.updatedAt)
      guard result.payloadIdentifier == identifier else { throw RegistrationError.unavailable }
      return try? JSONDecoder().decode(
        MailboxDescriptor.self,
        from: vault.ring.open(
          record: result.encryptedPayload, account: vault.productAccountId,
          identifier: identifier, schemaVersion: MailboxDescriptor.schemaVersion))
    }
    // Pre-epoch removal intent names the legacy incarnation, including after another device's
    // upgrade. It is never a wildcard over later additions.
    func matches(_ removal: MailboxRemoval, _ descriptor: MailboxDescriptor) -> Bool {
      descriptor.epoch == nil
        || (removal.epoch ?? Self.legacyMailboxEpoch) == descriptor.epoch
    }
    // A removal marks only the epoch it removed; a later addition from another device stays.
    func removes(_ removal: MailboxRemoval) throws -> MailboxDescriptor? {
      guard let live = stored[try identifier(removal.subject)]?.descriptor, live.removed != true,
        matches(removal, live)
      else { return nil }
      return live
    }
    var next = saved
    for removal in saved.mailboxRemovals ?? [] {
      let key = try identifier(removal.subject)
      if stored[key] == nil {
        try await put(
          key, MailboxDescriptor(
            provider: "gmail", address: removal.address, epoch: removal.epoch ?? Self.legacyMailboxEpoch,
            removed: true))
      } else if let live = try removes(removal) {
        var removed = live
        removed.removed = true
        try await put(try identifier(removal.subject), removed)
      }
    }
    if !(saved.mailboxRemovals ?? []).isEmpty {
      stored = try await mailboxDescriptors(vault, backend: backend, session: session, product)
    }
    var purged: [MailboxConnection] = []
    var wrote = false
    func publish(
      _ connection: MailboxConnection, key: String, descriptor: MailboxDescriptor,
      canAdopt: Bool
    ) async throws {
      next.update(connection.id) { $0.epoch = descriptor.epoch }
      guard let winner = try await put(key, descriptor) else { wrote = true; return }
      if winner.removed == true || (winner.epoch != descriptor.epoch && !canAdopt) {
        purged.append(connection)
      } else {
        // Only fresh consent or a matching retained recreation can adopt a losing CAS's winner.
        next.update(connection.id) {
          $0.epoch = winner.epoch
          $0.published = true
        }
        // A later list failure must not lose the confirmed CAS winner across relaunch.
        try save(next)
      }
      wrote = true
    }
    func purgeConnections() async throws {
      for connection in purged {
        next.connections = next.connections.filter { $0.id != connection.id }
        next.mailboxCacheRemovals = Array(Set(
          (next.mailboxCacheRemovals ?? []) + [connection.id])).sorted()
      }
      if !purged.isEmpty {
        try save(next)
        next = try await retryMailboxCleanup(next)
        purged = []
      }
    }
    for connection in saved.connections {
      // A later connection's failed write must not discard a removal already learned.
      try await purgeConnections()
      let key = try identifier(connection.receipt.subject)
      let usable = connection.authorizationNeeded != true
      guard let record = stored[key] else {
        if usable {
          let epoch = connection.epoch ?? UUID().uuidString
          try await publish(
            connection, key: key,
            descriptor: MailboxDescriptor(
              provider: "gmail", address: connection.receipt.address, epoch: epoch),
            canAdopt: connection.published != true && newlyAuthorizedMailboxes.contains(connection.id))
        }
        continue
      }
      // A record that fails to open or decode is never shown and never replaced.
      guard let descriptor = record.descriptor else { continue }
      let published = connection.published == true
      let sameEpoch = descriptor.epoch == connection.epoch
      // Only a known descriptor still at its observed epoch proves no intervening removal.
      // An absent descriptor cannot rule out an add/remove/re-add while this device was offline.
      let unchanged =
        connection.observed == true
        && connection.observedEpoch != nil
        && connection.observedEpoch == (descriptor.epoch ?? "")
      // A descriptor without an epoch predates epochs and is the same incarnation; once upgraded
      // it carries the fixed legacy epoch. A connection without an epoch predates epochs too, so
      // only that legacy epoch, or an observation, shows it was not removed and added again.
      let compatible =
        sameEpoch || descriptor.epoch == nil
        || (connection.epoch == nil
          && (descriptor.epoch == Self.legacyMailboxEpoch || unchanged))
      let recreation = saved.mailboxRemovals?.contains {
          $0.subject == connection.receipt.subject
            && matches($0, descriptor)
        } == true
      if descriptor.removed == true {
        if published || (connection.epoch != nil && sameEpoch)
          || (!newlyAuthorizedMailboxes.contains(connection.id) && !recreation) {
          purged.append(connection)
        } else if usable {
          // Added on this device after the removal: the connection starts a new epoch.
          let epoch = connection.epoch ?? UUID().uuidString
          try await publish(
            connection, key: key,
            descriptor: MailboxDescriptor(
              provider: "gmail", address: connection.receipt.address, epoch: epoch), canAdopt: true)
        }
      } else if !compatible {
        // An authorization from before a removal and a later addition is not carried over.
        if published
          || (!newlyAuthorizedMailboxes.contains(connection.id) && !recreation && !unchanged) {
          purged.append(connection)
        } else if connection.epoch != nil, recreation {
          // Explicit recreation advances the epoch even if the old removal was never published.
          try await publish(
            connection, key: key,
            descriptor: MailboxDescriptor(
              provider: "gmail", address: connection.receipt.address, epoch: connection.epoch),
            canAdopt: true)
        } else {
          next.update(connection.id) { $0.epoch = descriptor.epoch }
        }
      } else {
        // First authorization on a new device also upgrades an epochless descriptor to legacy;
        // using its fresh UUID would make existing legacy devices lose their valid grants.
        // Published epochs survive older-client rewrites, and retained recreation advances them.
        let epoch = descriptor.epoch == nil && !published && !recreation
          ? Self.legacyMailboxEpoch
          : connection.epoch ?? descriptor.epoch ?? Self.legacyMailboxEpoch
        next.update(connection.id) { $0.epoch = epoch }
        if usable, descriptor.address != connection.receipt.address || descriptor.epoch != epoch {
          try await publish(
            connection, key: key,
            descriptor: MailboxDescriptor(
              provider: "gmail", address: connection.receipt.address, epoch: epoch),
            canAdopt: false)
        }
      }
    }
    try await purgeConnections()
    if !(saved.mailboxRemovals ?? []).isEmpty || wrote {
      stored = try await mailboxDescriptors(vault, backend: backend, session: session, product)
    }
    // A removal that is marked, or overtaken by another addition, is done.
    next.mailboxRemovals = try (saved.mailboxRemovals ?? []).filter {
      // Missing or unreadable is no evidence that this removal committed.
      guard let descriptor = stored[try identifier($0.subject)]?.descriptor else { return true }
      if descriptor.removed == true { return false }
      return try removes($0) != nil
    }
    if next.mailboxRemovals?.isEmpty == true { next.mailboxRemovals = nil }
    var confirmed: [String: String] = [:]
    for connection in next.connections {
      let key = try identifier(connection.receipt.subject)
      guard let descriptor = stored[key]?.descriptor else { continue }
      // An older client may rewrite the descriptor without an epoch; that keeps the incarnation.
      if descriptor.removed == true
        || (descriptor.epoch != nil && descriptor.epoch != connection.epoch)
      {
        // Read-back may observe a removal/recreation after our successful write or CAS adoption.
        // It cannot extend that consent to yet another incarnation.
        purged.append(connection)
        continue
      }
      next.update(connection.id) { $0.published = true }
      if descriptor.address == connection.receipt.address {
        confirmed[key] = connection.receipt.address
      }
    }
    try await purgeConnections()
    try save(next)
    let readable = stored.compactMapValues { $0.descriptor }
    let live = readable.values.filter { $0.removed != true }
    return (
      next, Set(live.map(\.address)).sorted(), confirmed,
      readable.mapValues { $0.epoch ?? "" }
    )
  }

  func mailboxDescriptors(
    _ vault: ProductSyncVault, backend: ProductSyncBackend, session: ProductSignInIdentity,
    _ product: ProductRegistrationReceipt
  ) async throws -> [String: (descriptor: MailboxDescriptor?, updatedAt: Double)] {
    var result: [String: (descriptor: MailboxDescriptor?, updatedAt: Double)] = [:]
    for record in try await backend.list(session, product, "mailbox.") {
      // A record that fails to open or decode is never shown and never replaced.
      let descriptor = try? JSONDecoder().decode(
        MailboxDescriptor.self,
        from: vault.ring.open(
          record: record.encryptedPayload, account: vault.productAccountId,
          identifier: record.payloadIdentifier, schemaVersion: MailboxDescriptor.schemaVersion))
      result[record.payloadIdentifier] = (descriptor, record.updatedAt)
    }
    return result
  }

  func privateSync(_ saved: SavedRegistration) throws -> [String: String] {
    guard productSync != nil, let product = saved.product else { return [:] }
    var result: [String: String] = [:]
    // A Pending Device shows its Enrollment Code until it is admitted, even with keys it stored.
    if product.pending == true {
      if product.productSyncMaterialInitialized != true {
        result["privateSync"] = "setup-pending"
      } else if let enrollment = try loadEnrollment(product) {
        result["privateSync"] = "enrollment-pending"
        result["enrollmentCode"] = try EnrollmentCode(parsing: enrollment.code).display
        if let notice = enrollment.notice { result["enrollmentNotice"] = notice }
      } else {
        result["privateSync"] = "enrollment-needed"
      }
      return result
    }
    guard let vault = try loadVault(product.productAccountId) else {
      // A Trusted Device without local keys never creates replacements for existing key material;
      // its Recovery Key unlocks it. An unknown state, such as a receipt saved before Product Sync,
      // waits for verification.
      result["privateSync"] =
        product.productSyncMaterialInitialized != true ? "setup-pending" : "enrollment-needed"
      return result
    }
    if !vault.published {
      result["privateSync"] = "setup-pending"
    } else if !vault.recoveryKeyConfirmed, let recoveryKey = vault.recoveryKey {
      result["privateSync"] = "recovery-key"
      result["recoveryKey"] = try RecoveryKey(bytes: recoveryKey).display
    } else {
      result["privateSync"] = "ready"
    }
    // The newest request Convex listed as open; it rejects an approval that arrives too late.
    if vault.published,
      let request = enrollmentRequests[product.productAccountId]?.max(by: {
        $0.expiresAt < $1.expiresAt
      })
    {
      result["enrollmentRequest"] = request.pendingDeviceId
      result["enrollmentDevice"] = request.deviceName
    }
    // Other devices this one can remove; it re-encrypts with keys and a Recovery Key it holds.
    if vault.published, let devices = trustedDevices[product.productAccountId], !devices.isEmpty {
      result["trustedDevices"] = String(decoding: try JSONEncoder().encode(devices), as: UTF8.self)
    }
    if let mailboxes = vault.readMailboxes, !mailboxes.isEmpty {
      result["privateSyncMailboxes"] = mailboxes.joined(separator: "\n")
    }
    // A usable mailbox not yet read back needs a backend session, such as after an Apple relaunch.
    if vault.published,
      try saved.usableConnections.contains(where: {
        try vault.savedMailboxes?[vault.ring.identifier("mailbox", "gmail:" + $0.receipt.subject)]
          != $0.receipt.address
      })
    {
      result["privateSyncPending"] = "mailbox"
    }
    return result
  }

  func confirmRecoveryKey(_ entry: String) throws -> [String: String] {
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
    return try status(saved)
  }

  // Seals this device's keys to another device of the account, unlocked by the code it shows.
  func approveEnrollment(_ requestId: String, code entry: String) async throws -> [String: String] {
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
    // Only the account's newest key epoch is sealed; a pending one is adopted first.
    vault = try await adoptRotation(vault, backend: backend, session: session, product)
    let envelope = try KeyRingEnvelope.enrollment(
      vault.ring, to: request.publicKey, code: code,
      binding: .init(account: product.productAccountId, device: request.pendingDeviceId))
    try await backend.approveEnrollment(session, product, request, vault.ring.current, envelope)
    enrollmentRequests[product.productAccountId]?.removeAll { $0.pendingDeviceId == requestId }
    return try status(saved)
  }

  func declineEnrollment(_ requestId: String) async throws -> [String: String] {
    guard let backend = productSync, let session, let saved = try load(),
      let product = saved.product
    else { throw RegistrationError.enrollmentUnavailable }
    try await backend.declineEnrollment(session, product, requestId)
    enrollmentRequests[product.productAccountId]?.removeAll { $0.pendingDeviceId == requestId }
    return try status(saved)
  }

  // Checks for an approval of this device, or for another device waiting for one.
  func refreshPrivateSync() async throws -> [String: String] {
    guard let saved = try load(), saved.product != nil else {
      throw RegistrationError.unavailable
    }
    switch saved.provider {
    case .google:
      // Google renews its Product Sign-In silently.
      return try await status(reconfirm(saved))
    case .apple:
      // Apple cannot renew silently; without this process's sign-in it asks interactively.
      guard let session else { return try await signIn(with: .apple) }
      // A Pending Device reconnects, which renews a record that ended with its Enrollment Code.
      if saved.product?.pending == true {
        return try await status(establish(saved, identity: session))
      }
      return try await status(synchronize(saved))
    }
  }

}
