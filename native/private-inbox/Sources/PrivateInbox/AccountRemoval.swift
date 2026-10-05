import Foundation

// Backend steps that end this device's access, or the whole Product Account's.
struct AccountRemoval {
  // Forgets this Trusted Device, identified by its installation, and its push routes.
  let unregister: (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> Void
  // Deletes the Product Account after a recent Product Sign-In; Apple adds its authorization code.
  let delete: (ProductSignInIdentity, ProductRegistrationReceipt) async throws -> Void
}

struct AccountRemovalState: Codable {
  enum Operation: String, Codable { case signOut, deletion, revoked }
  let operation: Operation
  var acknowledged = false
}

extension RegistrationStore {
  // An unanswered request must not reconnect a device that may already have unregistered.
  // Acknowledged cleanup resumes without any provider credential or interactive prompt.
  func removalStatus(_ saved: SavedRegistration) throws -> [String: String]? {
    guard let removal = saved.accountRemoval else { return nil }
    if removal.acknowledged {
      return try purge(
        notice:
          removal.operation == .deletion
          ? "deleted" : removal.operation == .signOut ? "signed-out" : nil)
    }
    session = nil
    enrollmentRequests = [:]
    trustedDevices = [:]
    guard let product = saved.product else { throw RegistrationError.unavailable }
    return [
      "kind": "mailbox-needed", "productAccountId": product.productAccountId,
      "signInProvider": saved.provider.rawValue, "reason": "unavailable",
      "privateSync": "unavailable",
      "removalPending": removal.operation == .signOut ? "sign-out" : "deletion",
    ]
  }

  // Convex forgets this Trusted Device and its push routes first; then the device keeps nothing of
  // the Product Account. Cancelled authentication changes nothing; unanswered backend work is
  // retained for retry and cannot silently reconnect this device.
  func signOut() async throws -> [String: String] {
    guard let removal, var saved = try load() else { throw RegistrationError.unavailable }
    if saved.accountRemoval?.acknowledged == true {
      return try removalStatus(saved) ?? ["kind": "signed-out"]
    }
    guard saved.accountRemoval == nil || saved.accountRemoval?.operation == .signOut else {
      throw RegistrationError.unavailable
    }
    if let product = saved.product {
      // Google renews silently; Sign in with Apple cannot, so it asks again.
      let identity: ProductSignInIdentity
      switch saved.provider {
      case .google:
        let google = try await provider.refresh(saved.identityCredential)
        identity = ProductSignInIdentity(
          provider: .google, subject: google.subject, idToken: google.idToken,
          credential: google.credential, contactEmail: nil)
      case .apple: identity = try await productIdentity(.apple, hint: nil)
      }
      guard identity.provider == saved.provider, identity.subject == saved.subject else {
        throw RegistrationError.invalidIdentity
      }
      if saved.accountRemoval == nil, let backend = productSync,
        var vault = try loadVault(product.productAccountId)
      {
        session = identity
        if vault.published {
          vault = try await adoptRotation(vault, backend: backend, session: identity, product)
        }
        // Never discard a published or unanswered Recovery Key the person has not backed up.
        if vault.recoveryKey != nil, !vault.recoveryKeyConfirmed || !vault.published {
          return try status(saved)
        }
        if let bytes = vault.recoveryKey {
          if let rotation = try await backend.keyRotation(identity, product) {
            guard rotation.keyEpoch == vault.ring.current else {
              throw RegistrationError.unavailable
            }
          } else {
            let envelope = try await backend.recoveryEnvelope(identity, product).encryptedPayload
            guard
              try KeyRingEnvelope.openRecovery(
                envelope, key: RecoveryKey(bytes: bytes), account: product.productAccountId
              ) == vault.ring
            else { throw RegistrationError.unavailable }
          }
        }
      }
      saved.accountRemoval = AccountRemovalState(operation: .signOut)
      try save(saved)
      try await removal.unregister(identity, product, saved.deviceIdentifier)
    }
    _ = try purge(notice: "signed-out")
    return ["kind": "signed-out"]
  }

  // Permanently deletes the Product Account after a fresh interactive Product Sign-In. An account
  // that Sign in with Apple opens is deleted through Apple, so Convex can revoke that authorization.
  // Convex decides whether the identity opens this account; an unanswered request stays pending
  // here, and repeating the deletion after a lost reply reports it as complete.
  func deleteAccount() async throws -> [String: String] {
    guard let removal, var saved = try load(), let product = saved.product else {
      throw RegistrationError.unavailable
    }
    if saved.accountRemoval?.acknowledged == true {
      return try removalStatus(saved) ?? ["kind": "signed-out"]
    }
    guard saved.accountRemoval == nil || saved.accountRemoval?.operation == .deletion else {
      throw RegistrationError.unavailable
    }
    let apple = saved.provider == .apple || product.signInProviders?.contains(.apple) == true
    let identity = try await productIdentity(
      apple ? .apple : .google, hint: saved.provider == .google ? saved.subject : nil)
    saved.accountRemoval = AccountRemovalState(operation: .deletion)
    try save(saved)
    try await removal.delete(identity, product)
    return try purge(notice: "deleted")
  }
}
