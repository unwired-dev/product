import CryptoKit
import Foundation
import os

// One stored Product Sync record as Convex returns it.
struct StoredPayload: Codable, Equatable {
  let payloadIdentifier: String
  let encryptedPayload: EncryptedPayload
  let updatedAt: Double
}

// Backend steps for End-to-End Encrypted Product Sync; every call presents a Trusted Device proof.
struct ProductSyncBackend {
  // Stores the first recovery envelope and marks the account initialized in one step.
  // False when the account already holds other key material, which this device must not replace.
  let initialize:
    (ProductSignInIdentity, ProductRegistrationReceipt, EncryptedPayload) async throws -> Bool
  let list:
    (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> [StoredPayload]
  // Compare-and-set: returns the stored record, which differs from ours when another write won.
  let put:
    (ProductSignInIdentity, ProductRegistrationReceipt, String, EncryptedPayload, Double?)
      async throws -> StoredPayload
  // Device enrollment: the new device asks with a one-time public key and returns the request.
  let requestEnrollment:
    (ProductSignInIdentity, ProductRegistrationReceipt, Curve25519.KeyAgreement.PublicKey)
      async throws -> String
  let enrollmentStatus:
    (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> EnrollmentStatus
  // Removes the sealed approval from the backend once this device holds the keys.
  let completeEnrollment:
    (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> Void
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
  let keyRotation:
    (ProductSignInIdentity, ProductRegistrationReceipt) async throws -> KeyRotation?
  let acknowledgeRotation:
    (ProductSignInIdentity, ProductRegistrationReceipt, Int) async throws -> Void
  let trustedDevices:
    (ProductSignInIdentity, ProductRegistrationReceipt) async throws -> [TrustedDevice]
  // Removes another device with a recent Product Sign-In: the new key ring sealed to the account's
  // committed key, the new recovery envelope, and the recovery record time it replaces.
  let revoke:
    (
      ProductSignInIdentity, ProductRegistrationReceipt, String, EncryptedPayload, EncryptedPayload,
      Double
    ) async throws -> Void
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

// Another device's request to receive this Product Account's keys.
struct PendingEnrollment {
  let requestId: String
  let trustedDeviceId: String
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

// This device's open enrollment request, kept in a device-only Keychain item until approved.
struct ProductSyncEnrollment: Codable {
  var version = 1
  let productAccountId: String
  let trustedDeviceId: String
  let requestId: String
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
  // A removal sent without a reply yet: its target, new Recovery Key and exact transition.
  var revocation: PendingRevocation?
}

struct PendingRevocation: Codable {
  let recoveryKey: Data
  let transition: EncryptedPayload
  // Older saved attempts have no target; their key can be adopted without attributing a removal.
  let trustedDeviceId: String?
}

// The synchronized description of an authorized mailbox; credentials never enter it.
struct MailboxDescriptor: Codable, Equatable {
  static let schemaVersion = 1
  let provider: String
  let address: String
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

  // This device's open request, only while it belongs to the same account and Trusted Device.
  func loadEnrollment(_ product: ProductRegistrationReceipt) throws -> ProductSyncEnrollment? {
    guard let data = try keys.read(enrollmentAccount(product.productAccountId)) else { return nil }
    let enrollment = try JSONDecoder().decode(ProductSyncEnrollment.self, from: data)
    guard enrollment.version == 1, enrollment.productAccountId == product.productAccountId,
      enrollment.trustedDeviceId == product.trustedDeviceId
    else { return nil }
    return enrollment
  }

  // Only uninitialized accounts create keys; losing initialization discards unpublished keys.
  // Initialization, enrollment and descriptor publication share one ordered account/session flow.
  // swiftlint:disable:next cyclomatic_complexity
  func synchronize(_ saved: SavedRegistration) async throws -> SavedRegistration {
    guard let backend = productSync, let session, var product = saved.product else { return saved }
    let account = product.productAccountId
    do {
      var vault = try loadVault(account)
      // Synchronization can adopt an initialized account's keys through trusted-device approval.
      if vault == nil, product.productSyncMaterialInitialized == true {
        vault = try await enroll(product, backend: backend, session: session)
      }
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
        guard let envelope = current.recoveryEnvelope else { throw RegistrationError.unavailable }
        guard try await backend.initialize(session, product, envelope) else {
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
      var next = current
      next.readMailboxes = mailboxes.addresses
      if let (identifier, address) = mailboxes.confirmed {
        next.savedMailboxes = (current.savedMailboxes ?? [:]).merging([identifier: address]) {
          $1
        }
      }
      if next.readMailboxes != current.readMailboxes
        || next.savedMailboxes != current.savedMailboxes
      {
        try saveVault(next)
      }
      enrollmentRequests[account] = try await backend.pendingEnrollments(session, product)
      trustedDevices[account] = try await backend.trustedDevices(session, product).filter {
        $0.id != product.trustedDeviceId
      }
    } catch RegistrationError.revoked {
      throw RegistrationError.revoked
    } catch {
      // Product Sync stays pending; registration and the mailbox remain usable.
      Self.logProductSyncFailure("Product Sync failed", error)
    }
    return saved
  }

  // Asks a trusted device to approve this one and adopts the keys sealed to it. An approval that
  // does not open with this device's key and code changes nothing; a new request replaces it.
  func enroll(
    _ product: ProductRegistrationReceipt, backend: ProductSyncBackend,
    session: ProductSignInIdentity
  ) async throws -> ProductSyncVault? {
    let account = product.productAccountId
    var notice: String?
    if let pending = try loadEnrollment(product) {
      let status = try await backend.enrollmentStatus(session, product, pending.requestId)
      switch status.state {
      case .pending: return nil
      case .approved:
        if let approval = status.approval,
          let ring = try? KeyRingEnvelope.openEnrollment(
            approval.envelope,
            with: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: pending.privateKey),
            code: EnrollmentCode(parsing: pending.code),
            binding: .init(
              account: account, device: product.trustedDeviceId, request: pending.requestId),
            keyVersion: approval.keyVersion)
        {
          // The account keys are adopted as they are; the Recovery Key stays with its owner.
          let vault = ProductSyncVault(
            productAccountId: account, ring: ring, published: true, recoveryKeyConfirmed: true)
          try saveVault(vault)
          try keys.remove(enrollmentAccount(account))
          do {
            try await backend.completeEnrollment(session, product, pending.requestId)
          } catch {
            // The approval expires on its own; this device already holds the keys.
            Self.logProductSyncFailure("Enrollment completion failed", error)
          }
          return vault
        }
        notice = "rejected"
      case .cancelled, .expired:
        notice = "renewed"
      }
    }
    let key = Curve25519.KeyAgreement.PrivateKey()
    let request = try await backend.requestEnrollment(session, product, key.publicKey)
    try keys.save(
      JSONEncoder().encode(
        ProductSyncEnrollment(
          productAccountId: account, trustedDeviceId: product.trustedDeviceId,
          requestId: request, privateKey: key.rawRepresentation,
          code: EnrollmentCode.generate().digits, notice: notice)),
      account: enrollmentAccount(account))
    return nil
  }

  // Writes this device's verified mailbox descriptor when missing, then reads every descriptor back.
  func synchronizeMailboxes(
    _ saved: SavedRegistration, vault: ProductSyncVault, backend: ProductSyncBackend,
    session: ProductSignInIdentity
  ) async throws -> (addresses: [String], confirmed: (String, String)?) {
    guard let product = saved.product else { return ([], nil) }
    var stored = try await mailboxDescriptors(vault, backend: backend, session: session, product)
    var confirmed: (String, String)?
    if let mailbox = saved.mailbox, saved.mailboxSetupReason == nil {
      let identifier = try vault.ring.identifier("mailbox", "gmail:" + mailbox.subject)
      let descriptor = MailboxDescriptor(provider: "gmail", address: mailbox.address)
      // Only a missing or readable, different record is replaced; a newer client may own the rest.
      let existing = stored[identifier]
      if existing == nil || (existing?.descriptor != nil && existing?.descriptor != descriptor) {
        let sealed = try vault.ring.seal(
          record: JSONEncoder().encode(descriptor), account: vault.productAccountId,
          identifier: identifier, schemaVersion: MailboxDescriptor.schemaVersion)
        _ = try await backend.put(
          session, product, identifier, sealed, stored[identifier]?.updatedAt)
        stored = try await mailboxDescriptors(vault, backend: backend, session: session, product)
      }
      if stored[identifier]?.descriptor == descriptor { confirmed = (identifier, mailbox.address) }
    }
    return (Set(stored.values.compactMap { $0.descriptor?.address }).sorted(), confirmed)
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
    guard let vault = try loadVault(product.productAccountId) else {
      // Missing local keys for an account with key material never create replacements. An
      // unknown state, such as a receipt saved before Product Sync, waits for verification.
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
      result["enrollmentRequest"] = request.requestId
      result["enrollmentDevice"] = request.deviceName
    }
    // Other devices this one can remove; it re-encrypts with keys and a Recovery Key it holds.
    if vault.published, let devices = trustedDevices[product.productAccountId], !devices.isEmpty {
      result["trustedDevices"] = String(decoding: try JSONEncoder().encode(devices), as: UTF8.self)
    }
    if let mailboxes = vault.readMailboxes, !mailboxes.isEmpty {
      result["privateSyncMailboxes"] = mailboxes.joined(separator: "\n")
    }
    // A verified mailbox not yet read back needs a backend session, such as after an Apple relaunch.
    if let mailbox = saved.mailbox, saved.mailboxSetupReason == nil, vault.published,
      try vault.savedMailboxes?[vault.ring.identifier("mailbox", "gmail:" + mailbox.subject)]
        != mailbox.address
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
      let product = saved.product, let vault = try loadVault(product.productAccountId),
      vault.published,
      let request = enrollmentRequests[product.productAccountId]?.first(where: {
        $0.requestId == requestId
      })
    else { throw RegistrationError.enrollmentUnavailable }
    let envelope = try KeyRingEnvelope.enrollment(
      vault.ring, to: request.publicKey, code: code,
      binding: .init(
        account: product.productAccountId, device: request.trustedDeviceId,
        request: request.requestId))
    try await backend.approveEnrollment(session, product, request, vault.ring.current, envelope)
    enrollmentRequests[product.productAccountId]?.removeAll { $0.requestId == requestId }
    return try status(saved)
  }

  func declineEnrollment(_ requestId: String) async throws -> [String: String] {
    guard let backend = productSync, let session, let saved = try load(),
      let product = saved.product
    else { throw RegistrationError.enrollmentUnavailable }
    try await backend.declineEnrollment(session, product, requestId)
    enrollmentRequests[product.productAccountId]?.removeAll { $0.requestId == requestId }
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
      guard session != nil else { return try await signIn(with: .apple) }
      return try await status(synchronize(saved))
    }
  }

  func status(_ saved: SavedRegistration) throws -> [String: String] {
    try saved.mailbox != nil && saved.mailboxSetupReason == nil ? connected(saved) : pending(saved)
  }
}
