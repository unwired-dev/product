import Foundation
import os

extension RegistrationStore {
  // Unlocks this device without a trusted device: the Recovery Key opens the account's published
  // recovery envelope here and never leaves the device. A key that does not open it, or an
  // interruption before the keys are saved, leaves the account keys and encrypted data intact.
  // A rejected key resolves with this device's current status and a notice, because the renewed
  // sign-in may already have replaced an expired approval request and its Enrollment Code.
  func recover(with entry: String) async throws -> [String: String] {
    guard let backend = productSync, var saved = try load(), saved.product != nil else {
      throw RegistrationError.unavailable
    }
    func rejected() throws -> [String: String] {
      try status(saved).merging(["recoveryNotice": "rejected"]) { $1 }
    }
    // A malformed key is rejected before any sign-in renewal.
    guard let key = try? RecoveryKey(parsing: entry) else { return try rejected() }
    // Refresh authentication for every attempt, including a form left open beyond token expiry.
    // Google renews silently; Apple cannot refresh its token without interactive sign-in.
    if saved.provider == .google {
      saved = try await reconfirm(saved)
    } else {
      _ = try await signIn(with: .apple)
      saved = try load() ?? saved
    }
    guard let session, let product = saved.product else { throw RegistrationError.unavailable }
    let account = product.productAccountId
    // Already unlocked, for example by an approval collected while reconnecting.
    if try loadVault(account) != nil { return try status(saved) }
    guard product.productSyncMaterialInitialized == true else {
      throw RegistrationError.unavailable
    }
    let envelope = try await backend.recoveryEnvelope(session, product).encryptedPayload
    guard let ring = try? KeyRingEnvelope.openRecovery(envelope, key: key, account: account) else {
      return try rejected()
    }
    // The person holds the Recovery Key already, so this device neither keeps nor shows it.
    try saveVault(
      ProductSyncVault(
        productAccountId: account, ring: ring, published: true, recoveryKeyConfirmed: true))
    if let pending = try loadEnrollment(product) {
      do {
        try await backend.declineEnrollment(session, product, pending.requestId)
      } catch {
        // The request expires on its own; this device already holds the keys.
        Self.logProductSyncFailure("Enrollment cancellation failed", error)
      }
    }
    try keys.remove(enrollmentAccount(account))
    return try status(await synchronize(saved))
  }
}
