import Foundation

extension RegistrationStore {
  // Whether an entry reads as a Recovery Key, so a malformed one is rejected before any renewal.
  func readsAsRecoveryKey(_ entry: String) -> Bool { (try? RecoveryKey(parsing: entry)) != nil }

  // A Pending Device proves the entered Recovery Key with a value derived from it for this purpose
  // only, and receives the newest recovery envelope, which opens only here; the account keys are
  // stored before returning, and TypeScript then confirms admission. The Recovery Key never leaves
  // the device. Returns whether the key was rejected, which leaves everything unchanged.
  func recoverPendingDevice(_ entry: String) async throws -> Bool {
    guard let product = try saved().product, product.pending == true else {
      throw RegistrationError.unavailable
    }
    guard let key = try? RecoveryKey(parsing: entry) else { return true }
    let account = product.productAccountId
    // A successful null result is a proof that matches no Recovery Key of the account.
    let envelope: EncryptedPayload? = try await credentialedCall(
      "productSyncEnrollment:recover",
      [
        "recoveryProof": KeyRingEnvelope.recoveryProof(key, account: account),
        "deviceEncryptionPublicKey": try deviceKey(account).publicKey.rawRepresentation
          .base64EncodedString(),
      ])
    guard let envelope,
      let ring = try? KeyRingEnvelope.openRecovery(envelope, key: key, account: account)
    else { return true }
    // The person holds the Recovery Key already, so this device neither keeps nor shows it.
    try saveVault(
      ProductSyncVault(
        productAccountId: account, ring: ring, published: true, recoveryKeyConfirmed: true))
    return false
  }

  // A Trusted Device without its account keys opens the account's recovery envelope with the
  // entered Recovery Key, binds its encryption key with that key's proof, so later removals seal
  // their keys to it, and stores the keys. Returns whether the key was rejected, which leaves the
  // account keys and encrypted data intact.
  func recoverTrustedDevice(_ entry: String, envelope: [String: Any]) async throws -> Bool {
    guard let product = try saved().product, product.pending != true else {
      throw RegistrationError.unavailable
    }
    guard let key = try? RecoveryKey(parsing: entry) else { return true }
    let account = product.productAccountId
    guard
      let payload = try? JSONDecoder().decode(
        EncryptedPayload.self, from: JSONSerialization.data(withJSONObject: envelope))
    else { throw RegistrationError.unavailable }
    guard let ring = try? KeyRingEnvelope.openRecovery(payload, key: key, account: account) else {
      return true
    }
    struct Binding: Decodable { let bound: Bool }
    let binding: Binding? = try await credentialedCall(
      "productSync:bindDeviceEncryptionKey",
      [
        "deviceEncryptionPublicKey": try deviceKey(account).publicKey.rawRepresentation
          .base64EncodedString(),
        "recoveryProof": KeyRingEnvelope.recoveryProof(key, account: account),
      ])
    guard let binding else { throw RegistrationError.unavailable }
    guard binding.bound else { return true }
    try saveVault(
      ProductSyncVault(
        productAccountId: account, ring: ring, published: true, recoveryKeyConfirmed: true))
    return false
  }
}
