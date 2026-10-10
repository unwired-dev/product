import Foundation

struct AccountRemovalState: Codable {
  enum Operation: String, Codable { case signOut, deletion, revoked }
  let operation: Operation
  var acknowledged = false
}

extension RegistrationStore {
  // Stored before remote removal; acknowledgement precedes every local cleanup step. An
  // unanswered request must not reconnect a device that may already have unregistered.
  func recordRemoval(_ operation: AccountRemovalState.Operation?) throws {
    guard operation != .revoked else { throw RegistrationError.unavailable }
    var saved = try saved()
    saved.accountRemoval = operation.map { AccountRemovalState(operation: $0) }
    try save(saved)
  }

  // Ends this process's Product Sign-In while a removal waits for its answer.
  func endSession() {
    session = nil
    enrollmentRequests = [:]
    trustedDevices = [:]
  }

  // Whether this Trusted Device may sign out with the latest sign-in: it never discards a published
  // or unanswered Recovery Key the person has not backed up, and adopts a pending key epoch first.
  func prepareSignOut() async throws -> Bool {
    guard let identity else { throw RegistrationError.unavailable }
    let saved = try saved()
    guard let product = saved.product else { throw RegistrationError.unavailable }
    guard opens(saved, identity) else { throw RegistrationError.invalidIdentity }
    // A Pending Device holds no published keys or Recovery Key of its own to protect.
    guard saved.accountRemoval == nil, product.pending != true, let backend = productSync,
      var vault = try loadVault(product.productAccountId)
    else { return true }
    session = identity
    if vault.published {
      vault = try await adoptRotation(vault, backend: backend, session: identity, product)
    }
    if vault.recoveryKey != nil, !vault.recoveryKeyConfirmed || !vault.published {
      return false
    }
    if let bytes = vault.recoveryKey {
      if let rotation = try await backend.keyRotation(identity, product) {
        guard rotation.keyEpoch == vault.ring.current else { throw RegistrationError.unavailable }
      } else {
        let envelope = try await backend.recoveryEnvelope(identity, product).encryptedPayload
        guard
          try KeyRingEnvelope.openRecovery(
            envelope, key: RecoveryKey(bytes: bytes), account: product.productAccountId
          ) == vault.ring
        else { throw RegistrationError.unavailable }
      }
    }
    return true
  }
}
