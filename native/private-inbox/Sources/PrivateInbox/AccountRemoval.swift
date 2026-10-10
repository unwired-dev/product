import Foundation

// Backend steps that end this device's access, or the whole Product Account's.
struct AccountRemoval {
  // Forgets this Trusted Device, identified by its installation, and its push routes, or this
  // Pending Device.
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
  func removalStatus(_ saved: SavedRegistration) async throws -> [String: String]? {
    guard let removal = saved.accountRemoval else { return nil }
    if removal.acknowledged {
      return try await purge(
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
      return try await removalStatus(saved) ?? ["kind": "signed-out"]
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
      // A Pending Device holds no published keys or Recovery Key of its own to protect.
      if saved.accountRemoval == nil, product.pending != true, let backend = productSync,
        var vault = try loadVault(product.productAccountId)
      {
        session = identity
        if vault.published {
          vault = try await adoptRotation(vault, backend: backend, session: identity, product)
        }
        if vault.revocation?.submitted == true {
          return try status(saved).merging(["revocationNotice": "unconfirmed"]) { $1 }
        }
        // Never discard a published or unanswered Recovery Key the person has not backed up.
        if vault.recoveryKey != nil, !vault.recoveryKeyConfirmed || !vault.published {
          return try status(saved)
        }
      }
      saved.accountRemoval = AccountRemovalState(operation: .signOut)
      try save(saved)
      try await removal.unregister(identity, product, saved.deviceIdentifier)
    }
    _ = try await purge(notice: "signed-out")
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
      return try await removalStatus(saved) ?? ["kind": "signed-out"]
    }
    guard saved.accountRemoval == nil || saved.accountRemoval?.operation == .deletion else {
      throw RegistrationError.unavailable
    }
    let apple = saved.provider == .apple || product.signInProviders?.contains(.apple) == true
    let identity = try await productIdentity(
      apple ? .apple : .google, hint: saved.provider == .google ? saved.subject : nil)
    // Another identity of the same provider cannot open this account; Convex would refuse it.
    if identity.provider == saved.provider, identity.subject != saved.subject {
      throw RegistrationError.invalidIdentity
    }
    // An expired Pending Device may have been cleaned up. Renew its proof before recording
    // deletion intent; a retry of an unanswered deletion must not reconnect the account.
    if saved.accountRemoval == nil, product.pending == true {
      var needsProof = productSync == nil
      if let backend = productSync {
        do {
          _ = try await backend.enrollmentStatus(identity, product)
        } catch RegistrationError.pendingDeviceUnavailable {
          needsProof = true
        }
      }
      if needsProof {
        let refreshed = try await connect(identity, saved.deviceIdentifier, product)
        guard refreshed.productAccountId == product.productAccountId else {
          throw RegistrationError.invalidIdentity
        }
        saved.product = refreshed
        try save(saved)
      }
    }
    let wasPending = saved.accountRemoval != nil
    saved.accountRemoval = AccountRemovalState(operation: .deletion)
    try save(saved)
    do {
      try await removal.delete(identity, saved.product ?? product)
    } catch let error as RegistrationError
      where [
        .staleAuthentication, .removalRefused, .appleAuthorizationRequired,
        .pendingDeviceUnavailable,
      ]
      .contains(error)
    {
      // This attempt was refused before fencing anything. A refusal cannot settle an earlier
      // unanswered deletion; keep its intent and report uncertainty until cleanup is acknowledged.
      if !wasPending { saved.accountRemoval = nil }
      if error == .appleAuthorizationRequired, var refreshed = saved.product {
        let providers = refreshed.signInProviders ?? [saved.provider]
        refreshed.signInProviders = providers.contains(.apple) ? providers : providers + [.apple]
        saved.product = refreshed
      }
      try save(saved)
      if wasPending { throw RegistrationError.unavailable }
      throw error
    }
    return try await purge(notice: "deleted")
  }
}
