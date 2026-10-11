import CryptoKit
import Foundation

// The fresh roster no longer lists the selected row: it may have signed out, or enrolled again
// under a new row that is still trusted, so nothing proves it was removed.
private struct RevocationTargetUnlisted: Error {}

// What a removal step reports: its notice, whether Product Sync must synchronize before the status
// is read, and a settled removal's outcome. A settled removal's notice depends on the key epoch this
// device holds after that synchronization, so TypeScript derives it then.
struct RevocationReply {
  struct Settlement {
    // The epoch the account committed for this proposal, absent without a receipt.
    var keyEpoch: Int?
    var recoveryKeyCurrent = false
    // The epoch this device adopted while settling; a device that enrolls again keeps no ring.
    let settledEpoch: Int
  }
  var notice: String?
  var synchronize = false
  var settlement: Settlement?

  var object: [String: Any] {
    var result: [String: Any] = [:]
    if let notice { result["notice"] = notice }
    if synchronize { result["synchronize"] = true }
    if let settlement {
      var entry: [String: Any] = [
        "recoveryKeyCurrent": settlement.recoveryKeyCurrent,
        "settledEpoch": settlement.settledEpoch,
      ]
      if let keyEpoch = settlement.keyEpoch { entry["keyEpoch"] = keyEpoch }
      result["settlement"] = entry
    }
    return result
  }
}

extension RegistrationStore {
  // Prepares removing another Trusted Device with the fresh interactive Product Sign-In the flow
  // just collected. The new key epoch is sealed separately to every remaining device's encryption
  // key and to a replacement Recovery Key, which is shown first; nothing reaches the backend until
  // the person confirms it. Returns no notice: the snapshot shows the proposal. Temporary until #758.
  func revoke(_ trustedDeviceId: String) async throws -> RevocationReply {
    guard let backend = productSync, let saved = try load(), let product = saved.product,
      product.pending != true, trustedDeviceId != product.trustedDeviceId,
      var vault = try loadVault(product.productAccountId), vault.published,
      // Never replace a Recovery Key the person has not backed up yet.
      vault.recoveryKeyConfirmed, let identity
    else { throw RegistrationError.unavailable }
    guard opens(saved, identity) else { throw RegistrationError.invalidIdentity }
    _ = try deviceKey(product.productAccountId)
    session = identity
    // An earlier activation without a reply may have applied; adopting settles it first.
    vault = try await adoptRotation(vault, backend: backend, session: identity, product)
    if vault.revocation != nil { return RevocationReply() }
    do {
      vault.revocation = try await proposal(
        removing: trustedDeviceId, vault: vault, backend: backend, session: identity, product)
    } catch is RevocationTargetUnlisted {
      return refreshRevocationTarget(saved, removing: trustedDeviceId)
    }
    try saveVault(vault)
    return RevocationReply()
  }

  // Activates the prepared removal once the entry matches the end of its replacement Recovery Key,
  // and returns its notice. A sign-in that is no longer recent rejects as stale authentication, so
  // the flow renews it and confirms again. Temporary until #758.
  func confirmRevocation(_ entry: String) async throws -> RevocationReply {
    guard let backend = productSync, let saved = try load(), let product = saved.product
    else { throw RegistrationError.unavailable }
    // A failed status refresh can leave the host showing a proposal already settled here.
    guard var vault = try loadVault(product.productAccountId), var pending = vault.revocation
    else { return RevocationReply() }
    guard try RecoveryKey(bytes: pending.recoveryKey).confirms(entry) else {
      throw RegistrationError.recoveryKeyMismatch
    }
    let missingDeviceKey = try keys.read(deviceKeyAccount(product.productAccountId)) == nil
    // A lost key permits only replay of intent that was already confirmed and submitted.
    if missingDeviceKey, !pending.submitted { throw RegistrationError.unavailable }
    let target = pending.request.trustedDeviceId
    guard let identity = self.identity ?? session else {
      throw RegistrationError.staleAuthentication
    }
    guard opens(saved, identity) else { throw RegistrationError.invalidIdentity }
    session = identity
    let wasSubmitted = pending.submitted
    // Kept before sending: a lost reply is settled by sending this same request again.
    pending.submitted = true
    vault.revocation = pending
    try saveVault(vault)
    do {
      _ = try await backend.activateRevocation(identity, product, pending.request)
    } catch RevocationFailure.conflict {
      // The account changed since preparing, so this proposal never applied. A fresh proposal and
      // key are confirmed again.
      // Keep the rejected proposal cancellable if preparing its replacement fails.
      pending.submitted = false
      vault.revocation = missingDeviceKey ? nil : pending
      try saveVault(vault)
      if missingDeviceKey { return RevocationReply(synchronize: true) }
      vault = try await adoptRotation(vault, backend: backend, session: identity, product)
      do {
        vault.revocation = try await proposal(
          removing: target, vault: vault, backend: backend, session: identity, product)
      } catch is RevocationTargetUnlisted {
        vault.revocation = nil
        try saveVault(vault)
        return refreshRevocationTarget(saved, removing: target)
      }
      try saveVault(vault)
      return RevocationReply(notice: "renewed")
    } catch RevocationFailure.targetRemoved {
      // Another device removed it first; this proposal and its key never applied.
      vault.revocation = nil
      try saveVault(vault)
      var reply = refreshRevocationTarget(saved, removing: target)
      reply.notice = "superseded"
      return reply
    } catch let error where error is URLError || error is CancellationError {
      // The outcome is unknown; the proposal stays, and confirming again repeats it safely.
      return RevocationReply(notice: "unconfirmed")
    } catch {
      // A definite refusal, including a sign-in that is no longer recent, settles this attempt but
      // not an earlier unanswered submission.
      pending.submitted = wasSubmitted
      vault.revocation = pending
      try saveVault(vault)
      throw error
    }
    // Read before adopting: a failed read then leaves the proposal to settle on the next attempt.
    guard try await backend.revocationOutcome(identity, product, pending.request.proposalId) != nil
    else { return RevocationReply(notice: "unconfirmed") }
    // Keep the receipt locator until this device durably adopts the committed ring.
    let adoption = try await adoptRotationWithOutcome(
      vault, backend: backend, session: identity, product)
    trustedDevices[product.productAccountId]?.removeAll { $0.id == target }
    return revocationStatus(vault: adoption.vault, outcome: adoption.outcome)
  }

  // Forget the stale selection; synchronization refreshes the list without inferring why the row
  // disappeared.
  func refreshRevocationTarget(
    _ saved: SavedRegistration, removing target: String
  ) -> RevocationReply {
    if let account = saved.product?.productAccountId {
      trustedDevices[account]?.removeAll { $0.id == target }
    }
    return RevocationReply(synchronize: true)
  }

  // Discards the prepared removal and returns its notice; an activation sent without a reply is
  // settled first. Temporary until #758.
  func cancelRevocation() async throws -> RevocationReply {
    guard let saved = try load(), let product = saved.product
    else { throw RegistrationError.unavailable }
    guard var vault = try loadVault(product.productAccountId), let pending = vault.revocation
    else { return RevocationReply() }
    if pending.submitted {
      // Read before adopting, so a failed read leaves the proposal in place.
      if let backend = productSync, let session = identity ?? session,
        try await backend.revocationOutcome(session, product, pending.request.proposalId) != nil
      {
        let adoption = try await adoptRotationWithOutcome(
          vault, backend: backend, session: session, product)
        if adoption.vault.revocation == nil {
          return revocationStatus(vault: adoption.vault, outcome: adoption.outcome)
        }
      }
      // An absent receipt cannot rule out a request that is still reaching the backend.
      return RevocationReply(notice: "unconfirmed")
    }
    vault.revocation = nil
    try saveVault(vault)
    return RevocationReply()
  }

  // A settled removal: TypeScript synchronizes, which may adopt a later rotation, then reports
  // "removed" only while its Recovery Key belongs to the epoch this device then holds.
  func revocationStatus(
    vault: ProductSyncVault, outcome: (keyEpoch: Int, recoveryKeyCurrent: Bool)?
  ) -> RevocationReply {
    RevocationReply(
      synchronize: true,
      settlement: .init(
        keyEpoch: outcome?.keyEpoch, recoveryKeyCurrent: outcome?.recoveryKeyCurrent == true,
        settledEpoch: vault.ring.current))
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
      throw RevocationTargetUnlisted()
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
