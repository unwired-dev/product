import Foundation

extension RegistrationStore {
  // Removes another Trusted Device after a fresh interactive Product Sign-In. A new key epoch
  // reaches the remaining devices sealed to the account key they already hold, and a new Recovery
  // Key wraps it. Backend authorization withholds the transition from the removed device; sealing
  // it to secrets that device never held is tracked in #753.
  func revoke(_ trustedDeviceId: String) async throws -> [String: String] {
    guard let backend = productSync, let saved = try load(), let product = saved.product,
      trustedDeviceId != product.trustedDeviceId,
      var vault = try loadVault(product.productAccountId), vault.published
    else { throw RegistrationError.unavailable }
    try await requireNotRevoked(product)
    let identity = try await productIdentity(
      saved.provider, hint: saved.provider == .google ? saved.subject : nil)
    guard identity.provider == saved.provider, identity.subject == saved.subject else {
      throw RegistrationError.invalidIdentity
    }
    session = identity
    let account = product.productAccountId
    // An epoch another removal started joins this ring first, so the new ring carries it too.
    vault = try await adoptRotation(vault, backend: backend, session: identity, product)
    // Never replace a Recovery Key the person has not backed up yet, including one reconciled
    // after a lost reply. Another removal may proceed once that exact key is confirmed.
    guard vault.recoveryKeyConfirmed else { throw RegistrationError.recoveryKeyMismatch }
    let recovery = try await backend.recoveryEnvelope(identity, product)
    let committed = recovery.encryptedPayload.keyVersion
    let epoch = (vault.ring.keys.map(\.version).max() ?? committed) + 1
    let ring = ProductSyncKeyRing(
      current: epoch,
      keys: vault.ring.keys + [.init(version: epoch, key: ProductSyncSeal.randomKey())])
    let recoveryKey = RecoveryKey.generate()
    let transition = try KeyRingEnvelope.rotation(
      ring, sealedWith: vault.ring, epoch: committed, account: account)
    // Kept before sending: if the reply is lost, the next synchronization learns whether it applied.
    vault.revocation = PendingRevocation(recoveryKey: recoveryKey.bytes, transition: transition)
    try saveVault(vault)
    do {
      try await backend.revoke(
        identity, product, trustedDeviceId, transition,
        KeyRingEnvelope.recovery(ring, key: recoveryKey, account: account), recovery.updatedAt)
    } catch {
      // Only a lost connection leaves the outcome unknown; a refusal changed nothing.
      if !(error is URLError || error is CancellationError) {
        vault.revocation = nil
        try saveVault(vault)
      }
      throw error
    }
    trustedDevices[account]?.removeAll { $0.id == trustedDeviceId }
    let current = try status(await synchronize(saved))
    // Only this removal's own transition, once adopted, makes its new Recovery Key current. A removal
    // another device completed first, or a synchronization that failed just now, leaves it unconfirmed.
    let adopted = try loadVault(account)?.recoveryKey == recoveryKey.bytes
    return current.merging(["revocationNotice": adopted ? "removed" : "unconfirmed"]) { $1 }
  }

  // Adopts the epoch a removal started, sealed to a key this device holds, and reports it so the
  // rotation completes once every remaining device has. A removal this device sent without a reply
  // is confirmed by the account's pending transition: only then does its new Recovery Key apply.
  func adoptRotation(
    _ vault: ProductSyncVault, backend: ProductSyncBackend, session: ProductSignInIdentity,
    _ product: ProductRegistrationReceipt
  ) async throws -> ProductSyncVault {
    let rotation = try await backend.keyRotation(session, product)
    var next = vault
    if let pending = vault.revocation {
      next.revocation = nil
      if rotation?.transition == pending.transition {
        next.recoveryKey = pending.recoveryKey
        next.recoveryKeyConfirmed = false
      }
    }
    if let rotation, !vault.ring.keys.contains(where: { $0.version == rotation.keyEpoch }) {
      next.ring = try KeyRingEnvelope.openRotation(
        rotation.transition, with: vault.ring, keyEpoch: rotation.keyEpoch,
        account: product.productAccountId)
    }
    if vault.revocation != nil || next.ring != vault.ring {
      try saveVault(next)
    }
    if let rotation {
      try await backend.acknowledgeRotation(session, product, rotation.keyEpoch)
    }
    return next
  }
}
