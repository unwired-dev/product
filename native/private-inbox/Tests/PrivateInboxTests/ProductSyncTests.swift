// swiftlint:disable file_length function_body_length
// Integrated security journeys keep their setup, rejected transitions and final outcomes together.
import CryptoKit
import Foundation
import Testing

@testable import PrivateInbox

private func device() -> DeviceKeychain {
  DeviceKeychain(service: "dev.unwired.product-sync.tests.\(UUID().uuidString)")
}

// The final group with its first digit changed.
private func wrongGroup(_ key: RecoveryKey) -> String {
  (key.lastGroup.first == "0" ? "1" : "0") + key.lastGroup.dropFirst()
}

// This device's Product Sync projection, as TypeScript reads it.
@MainActor private func syncState(_ store: RegistrationStore) throws -> [String: Any] {
  guard let saved = try store.load(), let state = try store.productSyncState(saved) else {
    throw RegistrationError.unavailable
  }
  return state
}

private func remove(_ keys: DeviceKeychain, accounts: [String]) {
  try? keys.remove("registration")
  for account in accounts {
    try? keys.remove("product-sync." + account)
    try? keys.remove("product-sync-enrollment." + account)
    try? keys.remove("product-sync-device-key." + account)
  }
}

extension PrivateInboxTests {
  @Test func productSyncEnvelopesBindKeyVersionsContextAndRejectTampering() throws {
    let ring = ProductSyncKeyRing.create()
    let plaintext = Data(#"{"provider":"gmail","address":"same@example.invalid"}"#.utf8)
    let first = try ring.seal(
      record: plaintext, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
    let second = try ring.seal(
      record: plaintext, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
    // Every seal uses a fresh nonce, so equal records never produce equal ciphertext.
    #expect(first.nonceBase64 != second.nonceBase64)
    #expect(first.ciphertextBase64 != second.ciphertextBase64)
    #expect(Data(base64Encoded: first.nonceBase64)?.count == 12)
    #expect(first.keyVersion == 1)
    #expect(
      try ring.open(record: second, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
        == plaintext)

    func flipped(_ base64: String) -> String {
      var bytes = Data(base64Encoded: base64) ?? Data()
      bytes[0] ^= 1
      return bytes.base64EncodedString()
    }
    let tampered = [
      EncryptedPayload(
        ciphertextBase64: flipped(first.ciphertextBase64), keyVersion: 1,
        nonceBase64: first.nonceBase64, schemaVersion: 1, tagBase64: first.tagBase64),
      EncryptedPayload(
        ciphertextBase64: first.ciphertextBase64, keyVersion: 1,
        nonceBase64: flipped(first.nonceBase64), schemaVersion: 1, tagBase64: first.tagBase64),
      EncryptedPayload(
        ciphertextBase64: first.ciphertextBase64, keyVersion: 1, nonceBase64: first.nonceBase64,
        schemaVersion: 1, tagBase64: flipped(first.tagBase64)),
      EncryptedPayload(
        algorithm: "AES-GCM-128", ciphertextBase64: first.ciphertextBase64, keyVersion: 1,
        nonceBase64: first.nonceBase64, schemaVersion: 1, tagBase64: first.tagBase64),
    ]
    for payload in tampered {
      #expect(throws: ProductSyncError.rejected) {
        try ring.open(
          record: payload, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
      }
    }
    // The record is bound to its account, identifier and schema; another account's keys fail.
    for (account, identifier, schema) in [
      ("account-b", "mailbox.1", 1), ("account-a", "mailbox.2", 1), ("account-a", "mailbox.1", 2),
    ] {
      #expect(throws: ProductSyncError.rejected) {
        try ring.open(
          record: first, account: account, identifier: identifier, schemaVersion: schema)
      }
    }
    #expect(throws: ProductSyncError.rejected) {
      try ProductSyncKeyRing.create().open(
        record: first, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
    }
    // A later epoch still opens earlier records but rejects a relabelled key version.
    let rotated = ProductSyncKeyRing(
      current: 2,
      keys: ring.keys + [.init(version: 2, key: ProductSyncSeal.randomKey())])
    #expect(
      try rotated.open(
        record: first, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
        == plaintext)
    let relabelled = EncryptedPayload(
      ciphertextBase64: first.ciphertextBase64, keyVersion: 2, nonceBase64: first.nonceBase64,
      schemaVersion: 1, tagBase64: first.tagBase64)
    #expect(throws: ProductSyncError.rejected) {
      try rotated.open(
        record: relabelled, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
    }
    let current = try rotated.seal(
      record: plaintext, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
    #expect(current.keyVersion == 2)
    #expect(throws: ProductSyncError.rejected) {
      try ring.open(
        record: current, account: "account-a", identifier: "mailbox.1", schemaVersion: 1)
    }
    // Opaque identifiers are stable across epochs and differ between Product Accounts.
    let identifier = try ring.identifier("mailbox", "gmail:synthetic-subject")
    #expect(identifier.hasPrefix("mailbox."))
    #expect(!identifier.contains("synthetic"))
    #expect(try rotated.identifier("mailbox", "gmail:synthetic-subject") == identifier)
    #expect(
      try ProductSyncKeyRing.create().identifier("mailbox", "gmail:synthetic-subject") != identifier
    )
  }

  @Test func recoveryAndEnrollmentEnvelopesOpenOnlyForTheirAccountAndRecipient() throws {
    let ring = ProductSyncKeyRing.create()
    let key = RecoveryKey.generate()
    // The written form parses back regardless of case, separators or look-alike letters.
    #expect(key.display.count == 64)
    #expect(try RecoveryKey(parsing: key.display) == key)
    #expect(
      try RecoveryKey(
        parsing: key.display.lowercased().replacingOccurrences(of: "-", with: " ")
          .replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "l")) == key
    )
    #expect(throws: ProductSyncError.invalidRecoveryKey) {
      try RecoveryKey(parsing: String(key.display.dropLast()))
    }
    #expect(throws: ProductSyncError.invalidRecoveryKey) {
      try RecoveryKey(parsing: String(key.display.dropLast()) + "U")
    }
    #expect(key.confirms(key.lastGroup.lowercased()))
    #expect(!key.confirms(wrongGroup(key)))

    let envelope = try KeyRingEnvelope.recovery(ring, key: key, account: "account-a")
    #expect(envelope.schemaVersion == KeyRingEnvelope.recoverySchemaVersion)
    #expect(try KeyRingEnvelope.openRecovery(envelope, key: key, account: "account-a") == ring)
    // An authenticated but unusable ring must not make a recovering device appear unlocked.
    for invalid in [
      ProductSyncKeyRing(current: 1, keys: []),
      ProductSyncKeyRing(current: 2, keys: ring.keys),
      ProductSyncKeyRing(current: 1, keys: [.init(version: 1, key: Data(repeating: 0, count: 31))]),
    ] {
      let malformed = try KeyRingEnvelope.recovery(invalid, key: key, account: "account-a")
      #expect(throws: ProductSyncError.rejected) {
        try KeyRingEnvelope.openRecovery(malformed, key: key, account: "account-a")
      }
    }
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRecovery(envelope, key: .generate(), account: "account-a")
    }
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRecovery(envelope, key: key, account: "account-b")
    }
    // Convex compares the SHA-256 of the 64-hex proof with the verifier it stores; the proof is
    // bound to the account.
    let proof = KeyRingEnvelope.recoveryProof(key, account: "account-a")
    #expect(proof.wholeMatch(of: /[0-9a-f]{64}/) != nil)
    #expect(
      KeyRingEnvelope.recoveryVerifier(key, account: "account-a")
        == SHA256.hash(data: Data(proof.utf8)).map { String(format: "%02x", $0) }.joined())
    #expect(proof != KeyRingEnvelope.recoveryProof(key, account: "account-b"))
    for (keyVersion, schemaVersion) in [(2, 3), (1, 2)] {
      #expect(throws: ProductSyncError.rejected) {
        try KeyRingEnvelope.openRecovery(
          EncryptedPayload(
            ciphertextBase64: envelope.ciphertextBase64, keyVersion: keyVersion,
            nonceBase64: envelope.nonceBase64, schemaVersion: schemaVersion,
            tagBase64: envelope.tagBase64), key: key, account: "account-a")
      }
    }

    // The approval code reads back like the Recovery Key and catches a mistyped digit.
    let code = EnrollmentCode.generate()
    #expect(code.digits.count == 56)
    #expect(code.display.count == 69)
    #expect(try EnrollmentCode(parsing: code.display.lowercased()) == code)
    #expect(
      try EnrollmentCode(parsing: code.display.replacingOccurrences(of: "-", with: " ")) == code)
    let mistyped =
      String(code.digits.dropLast()) + (code.digits.last == "0" ? "1" : "0")
    #expect(throws: ProductSyncError.invalidEnrollmentCode) {
      try EnrollmentCode(parsing: mistyped)
    }
    #expect(throws: ProductSyncError.invalidEnrollmentCode) {
      try EnrollmentCode(parsing: String(code.digits.dropLast()))
    }

    #expect(throws: ProductSyncError.invalidEnrollmentCode) {
      try EnrollmentCode(parsing: "H4KP-9QWE-3TRM-7XB2")
    }

    let enrolling = Curve25519.KeyAgreement.PrivateKey()
    let deviceKey = Curve25519.KeyAgreement.PrivateKey().publicKey
    let binding = KeyRingEnvelope.EnrollmentBinding(
      account: "account-a", device: "device-b", deviceKey: deviceKey)
    let sealed = try KeyRingEnvelope.enrollment(
      ring, to: enrolling.publicKey, code: code, binding: binding)
    #expect(
      try KeyRingEnvelope.openEnrollment(
        sealed, with: enrolling, code: code, binding: binding, keyVersion: 1) == ring)
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openEnrollment(
        sealed, with: Curve25519.KeyAgreement.PrivateKey(), code: code, binding: binding,
        keyVersion: 1)
    }
    // Only the code the enrolling device showed opens it, so the backend cannot forge one.
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openEnrollment(
        sealed, with: enrolling, code: .generate(), binding: binding, keyVersion: 1)
    }
    // An approval bound to another device encryption key, as a substituted key would be, never opens.
    let otherKey = Curve25519.KeyAgreement.PrivateKey().publicKey
    for (account, device, key, keyVersion) in [
      ("account-b", "device-b", deviceKey, 1), ("account-a", "device-c", deviceKey, 1),
      ("account-a", "device-b", deviceKey, 2), ("account-a", "device-b", otherKey, 1),
    ] {
      #expect(throws: ProductSyncError.rejected) {
        try KeyRingEnvelope.openEnrollment(
          sealed, with: enrolling, code: code,
          binding: .init(account: account, device: device, deviceKey: key),
          keyVersion: keyVersion)
      }
    }
    // The approval Mock Mail Sessions' synthetic trusted device seals in TypeScript opens here
    // (packages/mail-core/test/synthetic-registration.test.ts pins the same bytes).
    let synthetic = KeyRingEnvelope.Enrollment(
      encapsulatedKey: Data(base64Encoded: "zo060cy2M+x7cMF4FKXHbs0CloUFDTRHRboFhw5YfVk=")!,
      ciphertext: Data(
        base64Encoded:
          "LbIyKdbb6gpUjiVZMVlUiSKdVk9l5bY0nmGvQ+d1yYTIIsN/PxwHn79g+o0Z6DNOVU3+NOeqFUAbyCLfEP3Lmujm0DIuGNxIB2rq3qGgwT3DvcXkJx8ofSXv75v391WKseSvlYSQC9hs"
      )!)
    let opened = try KeyRingEnvelope.openEnrollment(
      synthetic,
      with: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)),
      code: EnrollmentCode(
        parsing: "W65S-JAHG-7NHT-52ZB-74MF-RZQ5-B803-ZRRF-HBCM-CH52-5A1A-PTSC-BF7V-7TB5"),
      binding: .init(
        account: "synthetic-product-account", device: "synthetic-pending-installation",
        deviceKey: Curve25519.KeyAgreement.PrivateKey(
          rawRepresentation: Data(repeating: 3, count: 32)
        ).publicKey),
      keyVersion: 1)
    #expect(
      opened
        == ProductSyncKeyRing(
          current: 1,
          keys: [
            .init(
              version: 1,
              key: Data(base64Encoded: "KnLll/+hFLlv/cYU5tbSeaNGZmbnGjqNLWuv4LcLZe8=")!)
          ]))
  }

  // The native half of enrollment, recovery, key rotation and removal, which TypeScript sequences
  // (packages/mail-core/test/device-trust.test.ts and device-revocation.test.ts). Keys, codes and
  // proposals are stored before
  // anything is sent or acknowledged; every envelope opens only for its account, device, key, code
  // and epoch; and nothing a removed device held opens its removal's epoch.
  @Test @MainActor func enrollmentRecoveryAndRemovalKeepEveryKeyOnTheDevice() async throws {
    let (creatorKeys, enrollingKeys, recoveringKeys) = (device(), device(), device())
    let account = "account-synthetic-product-subject"
    defer {
      for keys in [creatorKeys, enrollingKeys, recoveringKeys] {
        remove(keys, accounts: [account])
      }
    }
    let google = SyntheticGoogleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    let creator = backend.store(keys: creatorKeys, google: google)
    let shown = try #require(try await creator.signIn()["recoveryKey"])
    _ = try creator.flowConfirmRecoveryKey(String(shown.suffix(4)))
    let ring = try #require(try creator.loadVault(account)?.ring)
    let creatorId = try #require(try creator.load()?.product?.trustedDeviceId)

    // Enrollment: the Pending Device stores its one-time key and code before its request is sent,
    // and shows the code; neither private key reaches the projection.
    let enrolling = backend.store(keys: enrollingKeys, google: google)
    #expect(try await enrolling.signIn()["kind"] == "device-pending")
    let pendingId = try #require(try enrolling.load()?.product?.trustedDeviceId)
    let request = try enrolling.beginEnrollment(notice: nil)
    let stored = try JSONDecoder().decode(
      ProductSyncEnrollment.self,
      from: #require(try enrollingKeys.read("product-sync-enrollment." + account)))
    let enrollment = try #require(syncState(enrolling)["enrollment"] as? [String: Any])
    let code = try #require(enrollment["code"] as? String)
    #expect(code == (try EnrollmentCode(parsing: stored.code).display))
    let projection = String(
      decoding: try JSONSerialization.data(withJSONObject: syncState(enrolling)), as: UTF8.self)
    #expect(!projection.contains(stored.privateKey.base64EncodedString()))
    #expect(enrolling.readsAsEnrollmentCode(code.lowercased()))
    let typo = String(code.dropLast()) + (code.last == "0" ? "1" : "0")
    #expect(!enrolling.readsAsEnrollmentCode(typo))
    #expect(throws: RegistrationError.unavailable) { try creator.beginEnrollment(notice: nil) }

    // The trusted device seals its ring for that request; only the shown code opens it, only on
    // that device and only at the sealed epoch.
    let listed: [String: Any] = [
      "pendingDeviceId": pendingId, "enrollmentPublicKey": request["enrollmentPublicKey"] as Any,
      "deviceEncryptionPublicKey": request["deviceKey"] as Any,
    ]
    #expect(throws: RegistrationError.enrollmentCodeInvalid) {
      try creator.sealEnrollment(typo, request: listed)
    }
    let wrongCode = try creator.sealEnrollment(EnrollmentCode.generate().display, request: listed)
    #expect(try enrolling.openEnrollment(wrongCode) == false)
    var otherDevice = listed
    otherDevice["pendingDeviceId"] = "pending-other"
    #expect(
      try enrolling.openEnrollment(creator.sealEnrollment(code, request: otherDevice)) == false)
    let approval = try creator.sealEnrollment(code, request: listed)
    var relabelled = approval
    relabelled["keyVersion"] = 2
    #expect(try enrolling.openEnrollment(relabelled) == false)
    #expect(try enrolling.loadVault(account) == nil)
    #expect(try enrolling.openEnrollment(approval))
    // The keys are stored before admission is confirmed.
    #expect(try enrolling.loadVault(account)?.ring == ring)
    #expect(try enrolling.load()?.product?.pending == true)
    // Convex admits it with the key the approval named; the receipt is saved before returning.
    backend.pending[pendingId]?.approved = true
    backend.pending[pendingId]?.deviceKey = request["deviceKey"].flatMap { Data(base64Encoded: $0) }
    #expect(try await enrolling.confirmAdmission())
    let enrolled = try #require(try enrolling.load()?.product)
    #expect(enrolled.pending == nil)
    #expect(enrolled.trustedDeviceCredential == String(repeating: "a", count: 64))
    #expect(try enrollingKeys.read("product-sync-enrollment." + account) == nil)

    // Recovery: malformed and unrelated keys store nothing; the written key, typed loosely, opens
    // the envelope Convex returns once its proof matches. Convex never sees the Recovery Key.
    let recovering = backend.store(keys: recoveringKeys, google: google)
    _ = try await recovering.signIn()
    _ = try recovering.beginEnrollment(notice: "renewed")
    let removedEnrollment = try JSONDecoder().decode(
      ProductSyncEnrollment.self,
      from: #require(try recoveringKeys.read("product-sync-enrollment." + account)))
    #expect(try await recovering.recoverPendingDevice("0000"))
    #expect(try await recovering.recoverPendingDevice(RecoveryKey.generate().display))
    #expect(try recovering.loadVault(account) == nil)
    #expect(try await recovering.recoverPendingDevice(shown.lowercased()) == false)
    #expect(try recovering.loadVault(account)?.ring == ring)
    #expect(try recovering.load()?.product?.pending == true)
    #expect(try await recovering.confirmAdmission())
    let removedId = try #require(try recovering.load()?.product?.trustedDeviceId)
    let visible = String(
      decoding: try JSONEncoder().encode(backend.verifiers)
        + JSONEncoder().encode(backend.recovery),
      as: UTF8.self)
    #expect(
      !visible.contains(shown) && !visible.contains(shown.replacingOccurrences(of: "-", with: "")))

    // A Trusted Device without its keys opens the recovery envelope and binds its key with the
    // Recovery Key's proof; another key unlocks nothing.
    try creatorKeys.remove("product-sync." + account)
    let published = try #require(backend.recovery[account])
    let envelope = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(published)) as? [String: Any])
    #expect(
      try await creator.recoverTrustedDevice(RecoveryKey.generate().display, envelope: envelope))
    #expect(try creator.loadVault(account) == nil)
    #expect(try await creator.recoverTrustedDevice(shown, envelope: envelope) == false)
    #expect(try creator.loadVault(account)?.ring == ring)

    // Removal: the proposal and replacement Recovery Key are stored before anything is sent, and
    // this device's own key must be the one the roster lists.
    func roster(_ ids: [String]) throws -> [[String: Any]] {
      try ids.map {
        [
          "id": $0,
          "deviceEncryptionPublicKey": try #require(backend.deviceKeys[$0]).base64EncodedString(),
        ]
      }
    }
    let enrolledId = enrolled.trustedDeviceId
    var swapped = try roster([creatorId, enrolledId])
    swapped[0]["deviceEncryptionPublicKey"] = swapped[1]["deviceEncryptionPublicKey"]
    #expect(throws: RegistrationError.unavailable) {
      try creator.prepareRevocation([
        "trustedDeviceId": removedId, "expectedRecoveryUpdatedAt": 1.0, "devices": swapped,
      ])
    }
    try creator.prepareRevocation([
      "trustedDeviceId": removedId, "expectedRecoveryUpdatedAt": 1.0,
      "devices": try roster([creatorId, enrolledId]),
    ])
    let prepared = try #require(try creator.loadVault(account)?.revocation)
    #expect(!prepared.submitted)
    let replacement = try RecoveryKey(bytes: prepared.recoveryKey)
    let shownProposal = try #require(
      (try syncState(creator)["vault"] as? [String: Any])?["revocation"] as? [String: Any])
    #expect(shownProposal["recoveryKey"] as? String == replacement.display)
    #expect(shownProposal["proposal"] as? String == prepared.request.proposalId)
    #expect(throws: RegistrationError.recoveryKeyMismatch) {
      try creator.submitRevocation(wrongGroup(replacement))
    }
    #expect(try creator.loadVault(account)?.revocation?.submitted == false)
    let body = try creator.submitRevocation(replacement.lastGroup)
    #expect(try creator.loadVault(account)?.revocation?.submitted == true)
    #expect(body["proposalId"] as? String == prepared.request.proposalId)
    #expect(body["trustedDeviceToRevokeId"] as? String == removedId)
    try creator.withdrawRevocation()
    #expect(try creator.loadVault(account)?.revocation?.submitted == false)
    _ = try creator.submitRevocation(replacement.lastGroup)

    // Each remaining device opens only its own envelope and keeps every key it holds.
    let envelopes = try #require(body["keyEnvelopes"] as? [[String: Any]])
    func rotation(_ id: String) throws -> [String: Any] {
      var entry = try #require(envelopes.first { $0["trustedDeviceId"] as? String == id })
      entry["keyEpoch"] = 2
      return entry
    }
    #expect(throws: ProductSyncError.rejected) { try enrolling.adoptRotation(rotation(creatorId)) }
    try enrolling.adoptRotation(rotation(enrolledId))
    let rotated = try #require(try enrolling.loadVault(account)?.ring)
    #expect(rotated.current == 2)
    #expect(ring.keys.allSatisfy(rotated.keys.contains))
    try enrolling.adoptRotation(rotation(enrolledId))
    #expect(try enrolling.loadVault(account)?.ring == rotated)

    // Nothing the removed device holds opens the new epoch: not its device key, its ring, its
    // enrollment secrets or the previous Recovery Key.
    let removedKey = try recovering.deviceKey(account)
    for entry in envelopes {
      let sealed = KeyRingEnvelope.Rotation(
        keyEpoch: 2,
        encapsulatedKey: try #require(
          (entry["encapsulatedKeyBase64"] as? String).flatMap { Data(base64Encoded: $0) }),
        ciphertext: try #require(
          (entry["ciphertextBase64"] as? String).flatMap { Data(base64Encoded: $0) }))
      for device in [removedId, try #require(entry["trustedDeviceId"] as? String)] {
        #expect(throws: ProductSyncError.rejected) {
          try KeyRingEnvelope.openRotation(
            sealed, with: removedKey,
            recipient: .init(account: account, device: device, publicKey: removedKey.publicKey),
            current: ring)
        }
      }
      #expect(throws: ProductSyncError.rejected) {
        try KeyRingEnvelope.openEnrollment(
          .init(encapsulatedKey: sealed.encapsulatedKey, ciphertext: sealed.ciphertext),
          with: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: removedEnrollment.privateKey),
          code: EnrollmentCode(parsing: removedEnrollment.code),
          binding: .init(account: account, device: removedId, deviceKey: removedKey.publicKey),
          keyVersion: 2)
      }
    }
    let recordId = try rotated.identifier("draft", "probe")
    let record = try rotated.seal(
      record: Data("probe".utf8), account: account, identifier: recordId, schemaVersion: 1)
    #expect(throws: ProductSyncError.rejected) {
      try ring.open(record: record, account: account, identifier: recordId, schemaVersion: 1)
    }
    let committed = try JSONDecoder().decode(
      EncryptedPayload.self,
      from: JSONSerialization.data(withJSONObject: #require(body["recoveryWrappedAccountKey"])))
    #expect(
      try KeyRingEnvelope.openRecovery(committed, key: replacement, account: account).current == 2)
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRecovery(
        committed, key: RecoveryKey(parsing: shown), account: account)
    }

    // Without its device key, the remover adopts only its committed proposal's ring, which the
    // confirmed replacement Recovery Key opens; a different epoch is refused.
    try creatorKeys.remove("product-sync-device-key." + account)
    #expect(throws: ProductSyncError.rejected) { try creator.settleRevocation(keyEpoch: 3) }
    #expect(try creator.loadVault(account)?.revocation != nil)
    try creator.settleRevocation(keyEpoch: 2)
    #expect(try creator.loadVault(account)?.ring.current == 2)
    #expect(try creator.loadVault(account)?.revocation == nil)
    // A proposal that never applied is discarded with its key.
    try enrolling.prepareRevocation([
      "trustedDeviceId": creatorId, "expectedRecoveryUpdatedAt": 2.0,
      "devices": try roster([enrolledId]),
    ])
    #expect(try enrolling.loadVault(account)?.revocation?.request.expectedKeyEpoch == 2)
    try enrolling.discardRevocation()
    #expect(try enrolling.loadVault(account)?.revocation == nil)
  }

  // The native half of initialization and descriptor synchronization, which TypeScript sequences
  // (packages/mail-core/test/product-sync.test.ts): keys are stored before anything is published,
  // a retry returns the same keys, unpublished keys never replace other key material, and a
  // descriptor opens only under its own identifier, account and epoch.
  @Test @MainActor func vaultOperationsStoreKeysFirstAndOpenRecordsOnlyWhereTheyWereSealed()
    async throws
  {
    let keys = device()
    let account = "account-synthetic-product-subject"
    defer { remove(keys, accounts: [account]) }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let backend = SyntheticProductSyncBackend()
    let store = backend.store(keys: keys, google: google)
    _ = try await store.signInIdentity(.google, hint: false)
    try store.saveIdentity(replacing: true)
    try await store.connectIdentity(.establish)
    #expect(try store.load()?.product?.productSyncMaterialInitialized == false)

    // Created and stored before publication; a relaunch returns the same keys.
    let created = try store.createKeyRing()
    let unpublished = try #require(try store.loadVault(account))
    #expect(!unpublished.published)
    let relaunched = backend.store(keys: keys, google: google)
    let again = try relaunched.createKeyRing()
    #expect(NSDictionary(dictionary: again).isEqual(to: created))
    #expect(try relaunched.loadVault(account)?.ring == unpublished.ring)
    let projection = try syncState(store)
    let text = String(
      decoding: try JSONSerialization.data(withJSONObject: projection), as: UTF8.self)
    for secret in unpublished.ring.keys.map({ $0.key.base64EncodedString() }) {
      #expect(!text.contains(secret))
    }
    #expect((projection["vault"] as? [String: Any])?["published"] as? Bool == false)
    #expect(
      (projection["vault"] as? [String: Any])?["recoveryKey"] as? String
        == (try RecoveryKey(bytes: #require(unpublished.recoveryKey)).display))
    try store.recordInitialization(true)
    #expect(try store.loadVault(account)?.published == true)
    #expect(throws: RegistrationError.unavailable) { try store.createKeyRing() }
    // Once confirmed, the Recovery Key no longer crosses to TypeScript.
    try store.confirmRecoveryKey(RecoveryKey(bytes: #require(unpublished.recoveryKey)).lastGroup)
    #expect((try syncState(store)["vault"] as? [String: Any])?["recoveryKey"] == nil)
    #expect(try store.loadVault(account)?.recoveryKeyConfirmed == true)

    // Sealed and opened only under its own identifier, for this account at a known epoch.
    let ring = unpublished.ring
    let record = try ring.identifier("mailbox", "gmail:synthetic-product-subject")
    let descriptor: [String: Any] = ["provider": "gmail", "address": "same@example.invalid"]
    let sealed = try store.sealMailboxDescriptor(record, descriptor)
    var tampered = sealed
    tampered["tagBase64"] = Data(repeating: 0, count: 16).base64EncodedString()
    let foreign = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(
        ProductSyncKeyRing.create().seal(
          record: JSONEncoder().encode(
            MailboxDescriptor(provider: "gmail", address: "x@example.invalid")),
          account: account, identifier: record, schemaVersion: 1)))
    let opened = try store.openMailboxDescriptors([
      ["payloadIdentifier": record, "encryptedPayload": sealed],
      ["payloadIdentifier": "mailbox.other", "encryptedPayload": sealed],
      ["payloadIdentifier": record, "encryptedPayload": tampered],
      ["payloadIdentifier": record, "encryptedPayload": foreign],
      ["payloadIdentifier": record],
    ])
    #expect((opened.first as? [String: Any])?["address"] as? String == "same@example.invalid")
    #expect(opened.dropFirst().allSatisfy { $0 is NSNull })
    #expect(throws: RegistrationError.unavailable) {
      try store.sealMailboxDescriptor("draft.other", descriptor)
    }

    // A new connection records which descriptor epoch this device had last read for it.
    try store.recordMailboxReadback(addresses: [], confirmed: [:], epochs: [record: "observed"])
    _ = try await store.signInMailbox(nil, suggest: false)
    _ = try await store.verifyGmail()
    try store.storeMailbox()
    let connection = try #require(try store.load()?.connections.first)
    #expect(connection.observed == true)
    #expect(connection.observedEpoch == "observed")
    // Synchronization's changes apply to the stored connection; a null epoch clears it.
    try store.recordMailboxChanges(
      connections: [["id": connection.id, "epoch": "adopted", "published": true]],
      settledRemovals: [])
    #expect(try store.load()?.connections.first?.epoch == "adopted")
    #expect(try store.load()?.connections.first?.published == true)
    try store.recordMailboxChanges(
      connections: [["id": connection.id, "epoch": NSNull()]], settledRemovals: [])
    #expect(try store.load()?.connections.first?.epoch == nil)
    let mailbox = try #require(
      ((try syncState(store)["vault"] as? [String: Any])?["mailboxes"] as? [[String: Any]])?.first)
    #expect(mailbox["record"] as? String == record)
    #expect(mailbox["newlyAuthorized"] as? Bool == true)
    store.finishSynchronization()
    #expect(
      ((try syncState(store)["vault"] as? [String: Any])?["mailboxes"] as? [[String: Any]])?.first?[
        "newlyAuthorized"] as? Bool == false)

    // Another account's key material already published: these unpublished keys are discarded.
    let other = device()
    defer { remove(other, accounts: [account]) }
    let second = backend.store(keys: other, google: google)
    var saved = try #require(try store.load())
    saved.product?.productSyncMaterialInitialized = false
    try other.save(JSONEncoder().encode(saved), account: "registration")
    _ = try second.createKeyRing()
    try second.recordInitialization(false)
    #expect(try second.loadVault(account) == nil)
    #expect(try second.load()?.product?.productSyncMaterialInitialized == true)
    // An unknown state never creates keys.
    saved.product?.productSyncMaterialInitialized = nil
    try other.save(JSONEncoder().encode(saved), account: "registration")
    #expect(throws: RegistrationError.unavailable) { try second.createKeyRing() }

    // Unreadable keys never fail registration; TypeScript reports Product Sync unavailable.
    try keys.save(Data("malformed".utf8), account: "product-sync." + account)
    #expect(try store.registration()?["productSync"] as? String == "unreadable")
  }

  // The native half of Mail Profile synchronization, which TypeScript sequences
  // (packages/mail-core/test/mail-profiles.test.ts): a definition or ownership opens only under the
  // identifier its own Profile or connection determines, and the Profile state TypeScript records
  // stays in protected registration across relaunch and replacement of key material.
  @Test @MainActor func profileRecordsOpenOnlyUnderTheirOwnIdentifier() async throws {
    let keys = device()
    let account = "account-synthetic-product-subject"
    defer { remove(keys, accounts: [account]) }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let backend = SyntheticProductSyncBackend()
    let store = backend.store(keys: keys, google: google)
    _ = try await store.signInIdentity(.google, hint: false)
    try store.saveIdentity(replacing: true)
    try await store.connectIdentity(.establish)
    _ = try store.createKeyRing()
    try store.recordInitialization(true)
    let ring = try #require(try store.loadVault(account)).ring

    let work: [String: Any] = ["kind": "profile", "id": "work", "version": 1.0, "name": "Work"]
    let mailbox = try ring.identifier("mailbox", "gmail:synthetic-product-subject")
    let owner: [String: Any] = [
      "kind": "mailbox", "record": mailbox, "epoch": "epoch-1", "version": 2.0,
      "profile": "work",
    ]
    let removed: [String: Any] = ["kind": "profile", "id": "home", "version": 3.0]
    let sealed = try [work, owner, removed].map(store.sealProfileRecord)
    #expect(sealed[0]["payloadIdentifier"] as? String == (try ring.identifier("profile", "work")))
    #expect(
      sealed[1]["payloadIdentifier"] as? String
        == (try ring.identifier("mailbox-profile", mailbox)))
    let opened = try store.openProfileRecords(
      sealed + [
        // Served under another Profile's or connection's identifier, it opens nowhere.
        [
          "payloadIdentifier": try ring.identifier("profile", "home"),
          "encryptedPayload": sealed[0]["encryptedPayload"] as Any,
        ],
        [
          "payloadIdentifier": try ring.identifier("mailbox-profile", "mailbox.other"),
          "encryptedPayload": sealed[1]["encryptedPayload"] as Any,
        ],
        // A Profile record listed under the descriptor prefix opens as neither.
        [
          "payloadIdentifier": mailbox, "encryptedPayload": sealed[0]["encryptedPayload"] as Any,
        ],
      ])
    #expect((opened[0] as? [String: Any])?["name"] as? String == "Work")
    #expect((opened[0] as? [String: Any])?["kind"] as? String == "profile")
    #expect((opened[1] as? [String: Any])?["profile"] as? String == "work")
    #expect((opened[1] as? [String: Any])?["epoch"] as? String == "epoch-1")
    // A removed Profile keeps its identifier and write count, without a name.
    let tombstone = try #require(opened[2] as? [String: Any])
    #expect(tombstone["id"] as? String == "home" && tombstone["name"] == nil)
    #expect(opened.dropFirst(3).allSatisfy { $0 is NSNull })
    // Even correctly authenticated ciphertext cannot bind another Profile's or connection's content
    // to this identifier. This exercises the content check separately from outer AEAD binding.
    let mismatched: [(String, Data)] = [
      (
        try ring.identifier("profile", "home"),
        try JSONEncoder().encode(MailProfileRecord(id: "work", version: 1, name: "Work"))
      ),
      (
        try ring.identifier("mailbox-profile", "mailbox.other"),
        try JSONEncoder().encode(
          MailboxProfileRecord(record: mailbox, epoch: "epoch-1", version: 2, profile: "work"))
      ),
    ]
    for (identifier, plaintext) in mismatched {
      let payload = try ring.seal(
        record: plaintext, account: account, identifier: identifier, schemaVersion: 1)
      let result = try store.openProfileRecords([
        [
          "payloadIdentifier": identifier,
          "encryptedPayload": try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)),
        ]
      ])
      #expect(result.allSatisfy { $0 is NSNull })
    }
    // Malformed records are refused rather than sealed.
    for malformed: [String: Any] in [
      ["kind": "profile", "id": "work", "version": 0.0, "name": "Work"],
      ["kind": "profile", "id": "work", "version": 1.0, "name": ""],
      ["kind": "mailbox", "record": "draft.other", "epoch": "e", "version": 1.0, "profile": "work"],
      ["kind": "other", "id": "work", "version": 1.0],
    ] {
      #expect(throws: RegistrationError.unavailable) { try store.sealProfileRecord(malformed) }
    }

    // TypeScript's Profile state stays in protected registration and crosses back unchanged.
    let state: [String: Any] = [
      "profiles": [["id": "work", "name": "Work", "version": 1]], "owners": [],
    ]
    try store.recordProfiles(state)
    // Replacing key material during recovery or admission cannot discard unpublished Profile data.
    try store.saveVault(
      ProductSyncVault(
        productAccountId: account, ring: ring, published: true, recoveryKeyConfirmed: true))
    let relaunched = backend.store(keys: keys, google: google)
    func projected() throws -> Any? { try relaunched.registration()?["profiles"] }
    #expect((try projected() as? NSDictionary)?.isEqual(to: state) == true)
    // Unreadable keys leave the confirmed Profile state readable.
    try keys.save(Data("malformed".utf8), account: "product-sync." + account)
    #expect(try relaunched.registration()?["productSync"] as? String == "unreadable")
    #expect((try projected() as? NSDictionary)?.isEqual(to: state) == true)
    // Unreadable Profile state is reported as such, never as none.
    var saved = try #require(try relaunched.load())
    saved.profiles = Data("malformed".utf8)
    try relaunched.save(saved)
    #expect(try projected() as? String == "unreadable")
  }

  // Enrollment, Recovery Key recovery, key rotation adoption and Device Revocation moved to
  // TypeScript. Each retired test names its replacement in device-trust.test.ts (enrollment and
  // recovery) or device-revocation.test.ts (rotation and removal), under packages/mail-core/test;
  // the native half of all of them is
  // enrollmentRecoveryAndRemovalKeepEveryKeyOnTheDevice above:
  // - trustedDeviceApprovalUnlocksANewDeviceWithoutReplacingAccountKeys: "approves a new device only
  //   with the code it shows and never replaces the account keys"
  // - recoveryKeyUnlocksANewDeviceWithoutReplacingAccountKeys: "unlocks with the Recovery Key only
  //   after storing the keys, and changes nothing before"; its Apple reauthentication is the
  //   registration flow's
  // - interruptedRecoveryDoesNotAcknowledgeANewerApprovalWithOlderKeys: "admits a device whose
  //   interrupted recovery a removal overtook only through a newer approval"
  // Rotation and removal replacements are in device-revocation.test.ts:
  // - removingADeviceSealsANewEpochToEachRemainingDeviceAfterItsRecoveryKeyIsConfirmed: "removes a
  //   device only after its replacement Recovery Key is confirmed …"
  // - aRemovedDevicesSecretsOpenNoPayloadOfItsRemovalEpochOrLater: the removed-device assertions of
  //   enrollmentRecoveryAndRemovalKeepEveryKeyOnTheDevice and the envelope tests above
  // - anOfflineDeviceSkipsSuccessiveRemovalsAndAdoptsTheNewestRingDirectly: "lets a device that
  //   stayed offline adopt the newest of successive removals directly"
  // - aLostActivationReplyIsSettledWithoutRemovingTwice: "settles a lost activation reply without
  //   removing twice"
  // - anUnansweredActivationKeepsItsIdentityAcrossCancellationAndRestart: "keeps an unanswered
  //   activation across cancellation and restart"
  // - aLostReplyFollowedByAnotherRotationNeverClaimsItsKeyIsCurrent: "never calls a key current
  //   that a later removal replaced after a lost reply"
  // - aCommittedActivationKeepsItsReceiptUntilDurableAdoption: "keeps a committed activation until
  //   this device durably adopts its ring"
  // - anOvertakenProposalIsPreparedAgainWithANewKeyBeforeItApplies: "prepares an overtaken proposal
  //   again with a new key …"
  // - draftWritesAtAnOvertakenEpochAdoptBeforeRetrying: "adopts the newest key epoch when a Draft
  //   write is refused for an earlier one" there, and "adopts the newer key epoch a refused write
  //   names …" in draft-sync-rotation.test.ts; native Draft sync now only reports the refusal
  // - aDeviceThatLostItsKeysEnrollsAgainAsANewDevice: "admits a device that lost its key again only
  //   under a new identifier"
  // - aFailedOutcomeReadAfterActivationKeepsTheProposalToSettle: "keeps a proposal to settle when
  //   reading its outcome fails"
  // - aFailedAdoptionAcknowledgementDoesNotStrandRevocation: "settles a removal although
  //   acknowledging its adoption fails"
  // - aRotationDuringRevocationSettlementNeverCallsTheProposedKeyCurrent: "never calls a proposed
  //   key current when a rotation lands during settlement"
  // - aFailedProposalRenewalKeepsTheRejectedProposalCancellable: "keeps a refused proposal
  //   cancellable when preparing its replacement fails"
  // - aTargetThatEnrolledAgainIsNeverReportedRemoved: "never reports a target removed that enrolled
  //   again under a new identifier"
  // - aRejectedActivationAfterDeviceKeyLossNeverReportsItsTargetRemoved: "never reports a target
  //   removed when an unanswered activation is refused after the device key is lost"
  // - aLostDeviceKeyNeverDiscardsAnUnconfirmedRecoveryKey: "neither approves, declines nor enrolls
  //   again while a lost device key guards an unconfirmed Recovery Key"
  // - aLostDeviceKeySettlesOnlyItsSubmittedRemovalBeforeFreshEnrollment: "settles only its submitted
  //   removal before enrolling again without its device key"

  // Product Sync initialization and mailbox descriptor synchronization moved to TypeScript
  // (packages/mail-core/test/product-sync.test.ts). Each retired test names its replacement there;
  // the native half is vaultOperationsStoreKeysFirstAndOpenRecordsOnlyWhereTheyWereSealed above:
  // - newAccountInitializesProductSyncOnceAndRelaunchKeepsItsKeys: "initializes a new account
  //   once, keeps its keys across relaunch and stores only opaque records"
  // - mailboxDescriptorsThisDeviceCannotOpenAreNeverReplaced: "never shows or replaces a descriptor
  //   this device cannot open"
  // - missingLocalKeysNeverReplaceAnExistingAccountsKeyMaterial: "resumes an interrupted
  //   initialization with the same keys …" and "discards unpublished keys when the account already
  //   holds other key material"; its recovery and approval steps are in device-trust.test.ts
  // - unknownProductSyncStateWaitsForVerificationWithoutCreatingKeys: "waits for verification
  //   without creating keys while the account state is unknown"
  // - unreadableProductSyncKeysLeaveRegistrationAndGmailUsable: "keeps registration and Gmail usable
  //   while Product Sync keys are unreadable"
  // - appleRelaunchAsksToSignInAgainBeforeSavingANewMailbox: "saves a mailbox chosen after an Apple
  //   relaunch once Apple sign-in renews the session"
  // - writesSealedAtAnOvertakenEpochAreSealedAgainAfterAdoptingIt: "seals a write again at the
  //   newest epoch after a removal overtakes it"

  // Guarding every operation against a revoked device is the TypeScript flow's job now. These
  // retired tests are replaced in packages/mail-core/test/registration-flow.test.ts:
  // - savedAccountPromptsPurgeRevokedDevicesBeforeCancellation and
  //   appleRestoreLearnsOfRevocationFromTheDeviceCredentialAlone: "purges a revoked … device before
  //   any prompt, and skips the check offline"
}
