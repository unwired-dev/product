import CryptoKit
import Foundation

extension RegistrationStore {
  // Prepares removing another Trusted Device after a fresh interactive Product Sign-In. The new key
  // epoch is sealed separately to every remaining device's encryption key and to a replacement
  // Recovery Key, which is shown first; nothing reaches the backend until the person confirms it.
  func revoke(_ trustedDeviceId: String) async throws -> [String: String] {
    guard let backend = productSync, let saved = try load(), let product = saved.product,
      product.pending != true, trustedDeviceId != product.trustedDeviceId,
      var vault = try loadVault(product.productAccountId), vault.published,
      // Never replace a Recovery Key the person has not backed up yet.
      vault.recoveryKeyConfirmed
    else { throw RegistrationError.unavailable }
    let identity = try await recentIdentity(saved)
    session = identity
    // An earlier activation without a reply may have applied; adopting settles it first.
    vault = try await adoptRotation(vault, backend: backend, session: identity, product)
    if vault.revocation != nil { return try status(saved) }
    do {
      vault.revocation = try await proposal(
        removing: trustedDeviceId, vault: vault, backend: backend, session: identity, product)
    } catch RevocationFailure.targetRemoved {
      return try await superseded(saved, removing: trustedDeviceId)
    }
    try saveVault(vault)
    return try status(saved)
  }

  // Activates the prepared removal once the entry matches the end of its replacement Recovery Key.
  func confirmRevocation(_ entry: String) async throws -> [String: String] {
    guard let backend = productSync, let saved = try load(), let product = saved.product,
      var vault = try loadVault(product.productAccountId), var pending = vault.revocation
    else { throw RegistrationError.unavailable }
    guard try RecoveryKey(bytes: pending.recoveryKey).confirms(entry) else {
      throw RegistrationError.recoveryKeyMismatch
    }
    let target = pending.request.trustedDeviceId
    var identity: ProductSignInIdentity
    if let session { identity = session } else { identity = try await recentIdentity(saved) }
    session = identity
    let wasSubmitted = pending.submitted
    // Kept before sending: a lost reply is settled by sending this same request again.
    pending.submitted = true
    vault.revocation = pending
    try saveVault(vault)
    do {
      do {
        _ = try await backend.activateRevocation(identity, product, pending.request)
      } catch RegistrationError.staleAuthentication {
        // Preparing outlasted the recent sign-in that activation requires.
        identity = try await recentIdentity(saved)
        session = identity
        _ = try await backend.activateRevocation(identity, product, pending.request)
      }
    } catch RevocationFailure.conflict {
      // The account changed since preparing, so this proposal never applied. A fresh proposal and
      // key are confirmed again.
      vault.revocation = nil
      try saveVault(vault)
      vault = try await adoptRotation(vault, backend: backend, session: identity, product)
      do {
        vault.revocation = try await proposal(
          removing: target, vault: vault, backend: backend, session: identity, product)
      } catch RevocationFailure.targetRemoved {
        return try await superseded(saved, removing: target)
      }
      try saveVault(vault)
      return try status(saved).merging(["revocationNotice": "renewed"]) { $1 }
    } catch RevocationFailure.targetRemoved {
      // Another device removed it first; this proposal and its key never applied.
      vault.revocation = nil
      try saveVault(vault)
      return try await superseded(saved, removing: target)
    } catch let error where error is URLError || error is CancellationError {
      // The outcome is unknown; the proposal stays, and confirming again repeats it safely.
      return try status(saved).merging(["revocationNotice": "unconfirmed"]) { $1 }
    } catch {
      // A definite refusal settles this attempt, but not an earlier unanswered submission.
      pending.submitted = wasSubmitted
      vault.revocation = pending
      try saveVault(vault)
      throw error
    }
    // Keep the receipt locator until this device durably adopts the committed ring.
    _ = try await adoptRotation(vault, backend: backend, session: identity, product)
    let outcome = try await backend.revocationOutcome(identity, product, pending.request.proposalId)
    trustedDevices[product.productAccountId]?.removeAll { $0.id == target }
    return try status(await synchronize(saved)).merging([
      "revocationNotice": outcome?.recoveryKeyCurrent == true ? "removed" : "superseded"
    ]) { $1 }
  }

  // Another device removed the target first; the current state shows it gone.
  func superseded(_ saved: SavedRegistration, removing target: String) async throws
    -> [String: String]
  {
    if let account = saved.product?.productAccountId {
      trustedDevices[account]?.removeAll { $0.id == target }
    }
    return try status(await synchronize(saved)).merging(["revocationNotice": "superseded"]) { $1 }
  }

  // Discards the prepared removal; an activation sent without a reply is settled first.
  func cancelRevocation() async throws -> [String: String] {
    guard let saved = try load(), let product = saved.product,
      var vault = try loadVault(product.productAccountId), let pending = vault.revocation
    else { throw RegistrationError.unavailable }
    if pending.submitted {
      if let backend = productSync, let session {
        vault = try await adoptRotation(vault, backend: backend, session: session, product)
        if vault.revocation == nil {
          let outcome = try await backend.revocationOutcome(
            session, product, pending.request.proposalId)
          return try status(await synchronize(saved)).merging([
            "revocationNotice": outcome?.recoveryKeyCurrent == true ? "removed" : "superseded"
          ]) { $1 }
        }
      }
      // An absent receipt cannot rule out a request that is still reaching the backend.
      return try status(saved).merging(["revocationNotice": "unconfirmed"]) { $1 }
    }
    vault.revocation = nil
    try saveVault(vault)
    return try status(saved)
  }

  // A fresh interactive Product Sign-In of this registration's identity.
  func recentIdentity(_ saved: SavedRegistration) async throws -> ProductSignInIdentity {
    let identity = try await productIdentity(
      saved.provider, hint: saved.provider == .google ? saved.subject : nil)
    guard identity.provider == saved.provider, identity.subject == saved.subject else {
      throw RegistrationError.invalidIdentity
    }
    return identity
  }

  // Seals a new epoch to every remaining device's bound encryption key, including this
  // one, and to a new Recovery Key, against the epoch and recovery record read now.
  func proposal(
    removing trustedDeviceId: String, vault: ProductSyncVault, backend: ProductSyncBackend,
    session: ProductSignInIdentity, _ product: ProductRegistrationReceipt
  ) async throws -> PendingRevocation {
    let account = product.productAccountId
    let recovery = try await backend.recoveryEnvelope(session, product)
    let roster = try await backend.trustedDevices(session, product)
    guard roster.contains(where: { $0.id == trustedDeviceId }) else {
      throw RevocationFailure.targetRemoved
    }
    // Every survivor's key comes from the roster; this device's must be the one it holds.
    guard
      roster.first(where: { $0.id == product.trustedDeviceId })?.encryptionKey
        == (try deviceKey(account).publicKey.rawRepresentation)
    else { throw RegistrationError.unavailable }
    let epoch = (vault.ring.keys.map(\.version).max() ?? vault.ring.current) + 1
    let ring = ProductSyncKeyRing(
      current: epoch,
      keys: vault.ring.keys + [.init(version: epoch, key: ProductSyncSeal.randomKey())])
    let recoveryKey = RecoveryKey.generate()
    let envelopes = try roster.filter { $0.id != trustedDeviceId }.map { device in
      guard let key = device.encryptionKey else { throw RegistrationError.unavailable }
      let recipient = KeyRingEnvelope.RotationRecipient(
        account: account, device: device.id,
        publicKey: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: key))
      return RevocationRequest.Envelope(
        trustedDeviceId: device.id, publicKey: key,
        envelope: try KeyRingEnvelope.rotation(ring, to: recipient))
    }
    let proposalId = ProductSyncSeal.randomKey().prefix(16).map { String(format: "%02x", $0) }
      .joined()
    return PendingRevocation(
      request: RevocationRequest(
        proposalId: proposalId, trustedDeviceId: trustedDeviceId,
        expectedKeyEpoch: vault.ring.current, expectedRecoveryUpdatedAt: recovery.updatedAt,
        envelopes: envelopes,
        recovery: try KeyRingEnvelope.recovery(ring, key: recoveryKey, account: account),
        recoveryVerifier: KeyRingEnvelope.recoveryVerifier(recoveryKey, account: account)),
      recoveryKey: recoveryKey.bytes)
  }

  // Adopts this device's latest key ring, sealed to its encryption key, however many removals it
  // missed, saves it and only then acknowledges it. An activation this device sent without a reply
  // is settled here: once the account recorded it, the device's own envelope carries its ring.
  func adoptRotation(
    _ vault: ProductSyncVault, backend: ProductSyncBackend, session: ProductSignInIdentity,
    _ product: ProductRegistrationReceipt
  ) async throws -> ProductSyncVault {
    let account = product.productAccountId
    var next = vault
    var changed = false
    let outcome =
      if let pending = vault.revocation, pending.submitted {
        try await backend.revocationOutcome(session, product, pending.request.proposalId)
      } else {
        nil as (keyEpoch: Int, recoveryKeyCurrent: Bool)?
      }
    let rotation = try await backend.keyRotation(session, product)
    if let rotation, !next.ring.keys.contains(where: { $0.version == rotation.keyEpoch }) {
      let key = try deviceKey(account)
      next.ring = try KeyRingEnvelope.openRotation(
        rotation, with: key,
        recipient: .init(
          account: account, device: product.trustedDeviceId, publicKey: key.publicKey),
        current: next.ring)
      changed = true
    }
    if let outcome, next.ring.current >= outcome.keyEpoch {
      next.revocation = nil
      changed = true
    }
    if changed { try saveVault(next) }
    if let rotation {
      try await backend.acknowledgeRotation(session, product, rotation.keyEpoch)
    }
    return next
  }
}
