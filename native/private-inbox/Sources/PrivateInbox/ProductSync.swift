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
}

// The device-held keys for one Product Account, kept in a device-only Keychain item.
struct ProductSyncVault: Codable {
  var version = 1
  let productAccountId: String
  let ring: ProductSyncKeyRing
  let recoveryKey: Data
  let recoveryEnvelope: EncryptedPayload
  // Convex accepted this device's recovery envelope as the account's key material.
  var published = false
  var recoveryKeyConfirmed = false
  // Mailbox descriptors this device read back from Product Sync, by record identifier.
  var savedMailboxes: [String: String]? = nil
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

  // Keys are created only for an account Convex reports as never initialized, then
  // published atomically; a device that loses that race discards its unused keys.
  func synchronize(_ saved: SavedRegistration) async -> SavedRegistration {
    guard let backend = productSync, let session, var product = saved.product else { return saved }
    let account = product.productAccountId
    do {
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
      if !current.published {
        guard try await backend.initialize(session, product, current.recoveryEnvelope) else {
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
      syncedMailboxes[account] = mailboxes.addresses
      if let (identifier, address) = mailboxes.confirmed,
        current.savedMailboxes?[identifier] != address
      {
        current.savedMailboxes = (current.savedMailboxes ?? [:]).merging([identifier: address]) {
          $1
        }
        try saveVault(current)
      }
    } catch {
      // Product Sync stays pending; registration and the mailbox remain usable.
      Self.productSyncLogger.error(
        "Product Sync failed: \(String(describing: error), privacy: .private)")
    }
    return saved
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
      if stored[identifier]?.descriptor != descriptor {
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
      // A record that fails authentication is never shown; a later write replaces it.
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
    if let mailboxes = syncedMailboxes[product.productAccountId], !mailboxes.isEmpty {
      result["privateSyncMailboxes"] = mailboxes.joined(separator: "\n")
    }
    guard let vault = try loadVault(product.productAccountId) else {
      // Missing local keys for an account with key material never create replacements. An
      // unknown state, such as a receipt saved before Product Sync, waits for verification.
      result["privateSync"] =
        product.productSyncMaterialInitialized == true ? "enrollment-needed" : "setup-pending"
      return result
    }
    if !vault.published {
      result["privateSync"] = "setup-pending"
    } else if !vault.recoveryKeyConfirmed {
      result["privateSync"] = "recovery-key"
      result["recoveryKey"] = try RecoveryKey(bytes: vault.recoveryKey).display
    } else {
      result["privateSync"] = "ready"
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
      guard try RecoveryKey(bytes: vault.recoveryKey).confirms(entry) else {
        throw RegistrationError.recoveryKeyMismatch
      }
      vault.recoveryKeyConfirmed = true
      try saveVault(vault)
    }
    return try saved.mailbox != nil && saved.mailboxSetupReason == nil
      ? connected(saved) : pending(saved)
  }
}
