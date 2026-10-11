import CryptoKit
import Foundation

// Key rotation and Device Revocation material. TypeScript sequences adoption and every removal step;
// these operations keep the keys, the replacement Recovery Key and the prepared proposal.
extension RegistrationStore {
  // Adopts this device's latest complete key ring, sealed to its encryption key by the newest
  // removal, however many it missed. The new ring must keep every key this device holds, and it is
  // saved before returning; a ring this device already holds changes nothing.
  func adoptRotation(_ envelope: [String: Any]) throws {
    guard let product = try saved().product, product.pending != true,
      var vault = try loadVault(product.productAccountId),
      let keyEpoch = envelope["keyEpoch"] as? Int,
      let encapsulatedKey = (envelope["encapsulatedKeyBase64"] as? String).flatMap({
        Data(base64Encoded: $0)
      }),
      let ciphertext = (envelope["ciphertextBase64"] as? String).flatMap({
        Data(base64Encoded: $0)
      })
    else { throw RegistrationError.unavailable }
    guard !vault.ring.keys.contains(where: { $0.version == keyEpoch }) else { return }
    let key = try deviceKey(product.productAccountId)
    vault.ring = try KeyRingEnvelope.openRotation(
      .init(keyEpoch: keyEpoch, encapsulatedKey: encapsulatedKey, ciphertext: ciphertext),
      with: key,
      recipient: .init(
        account: product.productAccountId, device: product.trustedDeviceId,
        publicKey: key.publicKey),
      current: vault.ring)
    try saveVault(vault)
  }

  // Settles this device's submitted removal, which the account committed at `keyEpoch`. Without its
  // encryption key the device adopts only that proposal's ring, which its confirmed replacement
  // Recovery Key opens; otherwise the proposal clears once this device holds that epoch.
  func settleRevocation(keyEpoch: Int) throws {
    guard let product = try saved().product,
      var vault = try loadVault(product.productAccountId),
      let pending = vault.revocation, pending.submitted
    else { return }
    if try keys.read(deviceKeyAccount(product.productAccountId)) == nil {
      let ring = try KeyRingEnvelope.openRecovery(
        pending.request.recovery, key: RecoveryKey(bytes: pending.recoveryKey),
        account: product.productAccountId)
      guard ring.current == keyEpoch, vault.ring.keys.allSatisfy(ring.keys.contains) else {
        throw ProductSyncError.rejected
      }
      vault.ring = ring
    } else if vault.ring.current < keyEpoch {
      return
    }
    vault.revocation = nil
    try saveVault(vault)
  }

  // Makes the latest Product Sign-In, or else this process's verified one, the session the next
  // backend steps present. It must open the saved registration; none is stale authentication.
  func adoptIdentity() throws {
    guard let identity = identity ?? session else { throw RegistrationError.staleAuthentication }
    guard opens(try load(), identity) else { throw RegistrationError.invalidIdentity }
    self.identity = identity
    session = identity
  }

  // Prepares removing another Trusted Device: a new key epoch sealed separately to each remaining
  // device's bound encryption key, this one's included, and to a replacement Recovery Key, against
  // the key epoch held now and the recovery record TypeScript read. Saved before returning; nothing
  // reaches the backend until the person confirms that key. Replaces a proposal never sent.
  func prepareRevocation(_ proposal: [String: Any]) throws {
    guard let product = try saved().product, product.pending != true,
      var vault = try loadVault(product.productAccountId), vault.published,
      // Never replace a Recovery Key the person has not backed up yet, or an unanswered removal.
      vault.recoveryKeyConfirmed, vault.revocation?.submitted != true,
      let target = proposal["trustedDeviceId"] as? String, target != product.trustedDeviceId,
      let expectedRecoveryUpdatedAt = proposal["expectedRecoveryUpdatedAt"] as? Double,
      let devices = proposal["devices"] as? [[String: Any]]
    else { throw RegistrationError.unavailable }
    let account = product.productAccountId
    let survivors = try devices.map { device in
      guard let id = device["id"] as? String, id != target,
        let key = (device["deviceEncryptionPublicKey"] as? String).flatMap({
          Data(base64Encoded: $0)
        })
      else { throw RegistrationError.unavailable }
      return (id: id, key: key)
    }
    // Every survivor's key comes from the roster; this device's must be the one it holds.
    guard
      survivors.first(where: { $0.id == product.trustedDeviceId })?.key
        == (try deviceKey(account).publicKey.rawRepresentation)
    else { throw RegistrationError.unavailable }
    let epoch = (vault.ring.keys.map(\.version).max() ?? vault.ring.current) + 1
    let ring = ProductSyncKeyRing(
      current: epoch,
      keys: vault.ring.keys + [.init(version: epoch, key: ProductSyncSeal.randomKey())])
    let recoveryKey = RecoveryKey.generate()
    let envelopes = try survivors.map { device in
      let recipient = KeyRingEnvelope.RotationRecipient(
        account: account, device: device.id,
        publicKey: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.key))
      return RevocationRequest.Envelope(
        trustedDeviceId: device.id, publicKey: device.key,
        envelope: try KeyRingEnvelope.rotation(ring, to: recipient))
    }
    let proposalId = ProductSyncSeal.randomKey().prefix(16).map { String(format: "%02x", $0) }
      .joined()
    vault.revocation = PendingRevocation(
      request: RevocationRequest(
        proposalId: proposalId, trustedDeviceId: target,
        expectedKeyEpoch: vault.ring.current,
        expectedRecoveryUpdatedAt: expectedRecoveryUpdatedAt, envelopes: envelopes,
        recovery: try KeyRingEnvelope.recovery(ring, key: recoveryKey, account: account),
        recoveryVerifier: KeyRingEnvelope.recoveryVerifier(recoveryKey, account: account)),
      recoveryKey: recoveryKey.bytes)
    try saveVault(vault)
  }

  // Once the entry matches the end of the replacement Recovery Key, records that the prepared
  // removal is submitted, before anything is sent, so a lost reply is settled by sending this same
  // request again. Returns what the activation carries besides this device's credentials. A sign-in
  // that is no longer recent rejects as stale authentication, so the flow renews it and confirms
  // again.
  func submitRevocation(_ entry: String) throws -> [String: Any] {
    guard let product = try saved().product,
      var vault = try loadVault(product.productAccountId), var pending = vault.revocation
    else { throw RegistrationError.unavailable }
    guard try RecoveryKey(bytes: pending.recoveryKey).confirms(entry) else {
      throw RegistrationError.recoveryKeyMismatch
    }
    // A lost key permits only replay of intent that was already confirmed and submitted.
    if try keys.read(deviceKeyAccount(product.productAccountId)) == nil, !pending.submitted {
      throw RegistrationError.unavailable
    }
    try adoptIdentity()
    pending.submitted = true
    vault.revocation = pending
    try saveVault(vault)
    let request = pending.request
    return [
      "trustedDeviceToRevokeId": request.trustedDeviceId,
      "proposalId": request.proposalId,
      "expectedKeyEpoch": request.expectedKeyEpoch,
      "expectedRecoveryUpdatedAt": request.expectedRecoveryUpdatedAt,
      "keyEnvelopes": request.envelopes.map {
        [
          "trustedDeviceId": $0.trustedDeviceId,
          "deviceEncryptionPublicKey": $0.publicKey.base64EncodedString(),
          "encapsulatedKeyBase64": $0.envelope.encapsulatedKey.base64EncodedString(),
          "ciphertextBase64": $0.envelope.ciphertext.base64EncodedString(),
        ]
      },
      "recoveryWrappedAccountKey": try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(request.recovery)),
      "recoveryVerifier": request.recoveryVerifier,
    ]
  }

  // A definite refusal: the prepared removal stays, with no submission outstanding.
  func withdrawRevocation() throws {
    guard let product = try saved().product,
      var vault = try loadVault(product.productAccountId), vault.revocation != nil
    else { return }
    vault.revocation?.submitted = false
    try saveVault(vault)
  }

  // The prepared removal and its replacement Recovery Key are discarded.
  func discardRevocation() throws {
    guard let product = try saved().product,
      var vault = try loadVault(product.productAccountId), vault.revocation != nil
    else { return }
    vault.revocation = nil
    try saveVault(vault)
  }
}
