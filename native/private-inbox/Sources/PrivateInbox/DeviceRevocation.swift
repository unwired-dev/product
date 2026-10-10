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
    _ = try deviceKey(product.productAccountId)
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
    let missingDeviceKey = try keys.read(deviceKeyAccount(product.productAccountId)) == nil
    // A lost key permits only replay of intent that was already confirmed and submitted.
    if missingDeviceKey, !pending.submitted { throw RegistrationError.unavailable }
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
      // Keep the rejected proposal cancellable if preparing its replacement fails.
      pending.submitted = false
      vault.revocation = missingDeviceKey ? nil : pending
      try saveVault(vault)
      if missingDeviceKey {
        return try status(await synchronize(saved)).merging(["revocationNotice": "superseded"]) { $1 }
      }
      vault = try await adoptRotation(vault, backend: backend, session: identity, product)
      do {
        vault.revocation = try await proposal(
          removing: target, vault: vault, backend: backend, session: identity, product)
      } catch RevocationFailure.targetRemoved {
        vault.revocation = nil
        try saveVault(vault)
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
    // Read before adopting: a failed read then leaves the proposal to settle on the next attempt.
    guard try await backend.revocationOutcome(identity, product, pending.request.proposalId) != nil
    else { return try status(saved).merging(["revocationNotice": "unconfirmed"]) { $1 } }
    // Keep the receipt locator until this device durably adopts the committed ring.
    let adoption = try await adoptRotationWithOutcome(
      vault, backend: backend, session: identity, product)
    trustedDevices[product.productAccountId]?.removeAll { $0.id == target }
    return try await revocationStatus(saved, vault: adoption.vault, outcome: adoption.outcome)
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
      // Read before adopting, so a failed read leaves the proposal in place.
      if let backend = productSync, let session,
        try await backend.revocationOutcome(session, product, pending.request.proposalId) != nil
      {
        let adoption = try await adoptRotationWithOutcome(
          vault, backend: backend, session: session, product)
        if adoption.vault.revocation == nil {
          return try await revocationStatus(saved, vault: adoption.vault, outcome: adoption.outcome)
        }
      }
      // An absent receipt cannot rule out a request that is still reaching the backend.
      return try status(saved).merging(["revocationNotice": "unconfirmed"]) { $1 }
    }
    vault.revocation = nil
    try saveVault(vault)
    return try status(saved)
  }

  // Synchronization may adopt a later rotation; unreadable state must not reject settled removal.
  func revocationStatus(
    _ saved: SavedRegistration, vault: ProductSyncVault,
    outcome: (keyEpoch: Int, recoveryKeyCurrent: Bool)?
  ) async throws -> [String: String] {
    let saved = try await synchronize(saved)
    let epoch: Int
    do {
      if let current = try loadVault(vault.productAccountId) {
        epoch = current.ring.current
      } else if saved.product?.pending == true {
        // Lost-key reenrollment intentionally removes the just-settled vault.
        epoch = vault.ring.current
      } else {
        return try status(saved)
      }
    } catch {
      Self.logProductSyncFailure("Product Sync state unreadable", error)
      return try status(saved)
    }
    let recoveryKeyCurrent = outcome?.recoveryKeyCurrent == true && outcome?.keyEpoch == epoch
    return try status(saved).merging([
      "revocationNotice": recoveryKeyCurrent ? "removed" : "superseded"
    ]) { $1 }
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
    try await adoptRotationWithOutcome(vault, backend: backend, session: session, product).vault
  }

  // Settlement uses the freshest receipt observed during adoption, even without a device key.
  func adoptRotationWithOutcome(
    _ vault: ProductSyncVault, backend: ProductSyncBackend, session: ProductSignInIdentity,
    _ product: ProductRegistrationReceipt
  ) async throws -> (
    vault: ProductSyncVault, outcome: (keyEpoch: Int, recoveryKeyCurrent: Bool)?
  ) {
    let account = product.productAccountId
    var next = vault
    var changed = false
    let outcome =
      if let pending = vault.revocation, pending.submitted {
        try await backend.revocationOutcome(session, product, pending.request.proposalId)
      } else {
        nil as (keyEpoch: Int, recoveryKeyCurrent: Bool)?
      }
    if try keys.read(deviceKeyAccount(account)) == nil {
      if let outcome, let pending = vault.revocation {
        // The receipt commits this exact proposal; its confirmed backup opens only that ring.
        let ring = try KeyRingEnvelope.openRecovery(
          pending.request.recovery, key: RecoveryKey(bytes: pending.recoveryKey), account: account)
        guard ring.current == outcome.keyEpoch, vault.ring.keys.allSatisfy(ring.keys.contains) else {
          throw ProductSyncError.rejected
        }
        next.ring = ring
        next.revocation = nil
        try saveVault(next)
      }
      // No rotation acknowledgement or ordinary synchronization without fresh device admission.
      return (next, outcome)
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
      do {
        try await backend.acknowledgeRotation(session, product, rotation.keyEpoch)
      } catch let error as RegistrationError where error.endsAccess {
        throw error
      } catch {
        // Adoption is durable; later synchronization retries this tracking-only acknowledgement.
        Self.logProductSyncFailure("Product Sync rotation acknowledgement failed", error)
      }
    }
    return (next, outcome)
  }
}
