import Foundation
import os

extension RegistrationStore {
  // Whether an entry reads as a Recovery Key, so a malformed one is rejected before any renewal.
  func readsAsRecoveryKey(_ entry: String) -> Bool { (try? RecoveryKey(parsing: entry)) != nil }

  // Unlocks this device without a trusted device, after the flow renewed its Product Sign-In: the
  // Recovery Key opens the account's published recovery envelope here and never leaves the device.
  // A Pending Device first proves the key with a value derived from it for this purpose only,
  // receives the newest envelope, stores the keys it opens and is then admitted. A key that does
  // not open it, or an interruption before the keys are saved, leaves the account keys and
  // encrypted data intact. Returns whether the key was rejected. Temporary until #758.
  func recover(with entry: String) async throws -> Bool {
    guard let backend = productSync, var saved = try load(), saved.product != nil else {
      throw RegistrationError.unavailable
    }
    guard let key = try? RecoveryKey(parsing: entry) else { return true }
    guard let session, let product = saved.product else { throw RegistrationError.unavailable }
    let account = product.productAccountId
    // Already unlocked, for example by an approval collected while reconnecting.
    if product.pending != true, try loadVault(account) != nil { return false }
    guard product.productSyncMaterialInitialized == true else {
      throw RegistrationError.unavailable
    }
    let envelope: EncryptedPayload
    if product.pending == true {
      guard
        let released = try await backend.recoverPending(
          session, product, KeyRingEnvelope.recoveryProof(key, account: account))
      else { return true }
      envelope = released
    } else {
      envelope = try await backend.recoveryEnvelope(session, product).encryptedPayload
    }
    guard let ring = try? KeyRingEnvelope.openRecovery(envelope, key: key, account: account) else {
      return true
    }
    // The person holds the Recovery Key already, so this device neither keeps nor shows it.
    try saveVault(
      ProductSyncVault(
        productAccountId: account, ring: ring, published: true, recoveryKeyConfirmed: true))
    if product.pending == true {
      // A rotation that started meanwhile voids the proof; the device stays pending and proves again.
      guard let admitted = try await confirmAdmission(saved, backend: backend, session: session)
      else { throw RegistrationError.unavailable }
      saved = admitted
    }
    _ = try await synchronize(saved)
    return false
  }
}
