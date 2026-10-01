import CryptoKit
import Foundation
import Testing

@testable import PrivateInbox

// Convex's Product Sync rules: one recovery envelope per account and compare-and-set records.
@MainActor final class SyntheticProductSyncBackend {
  var recovery: [String: EncryptedPayload] = [:]
  var records: [String: [String: StoredPayload]] = [:]
  var initializations = 0
  var offline = false
  var clock = 1_000.0

  func receipt(_ account: String) -> ProductRegistrationReceipt {
    ProductRegistrationReceipt(
      productAccountId: account, trustedDeviceId: "synthetic-device",
      trustedDeviceCredential: String(repeating: "a", count: 64),
      productSyncMaterialInitialized: recovery[account] != nil)
  }

  var backend: ProductSyncBackend {
    ProductSyncBackend(
      initialize: { [self] _, product, envelope in
        guard !offline else { throw RegistrationError.unavailable }
        if let existing = recovery[product.productAccountId] { return existing == envelope }
        recovery[product.productAccountId] = envelope
        initializations += 1
        return true
      },
      list: { [self] _, product, prefix in
        guard !offline else { throw RegistrationError.unavailable }
        return (records[product.productAccountId] ?? [:]).values
          .filter { $0.payloadIdentifier.hasPrefix(prefix) }
          .sorted { $0.payloadIdentifier < $1.payloadIdentifier }
      },
      put: { [self] _, product, identifier, payload, expected in
        guard !offline else { throw RegistrationError.unavailable }
        let existing = records[product.productAccountId]?[identifier]
        if let existing, existing.updatedAt != expected { return existing }
        clock += 1
        let stored = StoredPayload(
          payloadIdentifier: identifier, encryptedPayload: payload, updatedAt: clock)
        records[product.productAccountId, default: [:]][identifier] = stored
        return stored
      })
  }

  func store(keys: DeviceKeychain, google: SyntheticGoogleRegistrationProvider)
    -> RegistrationStore
  {
    RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, productSync: backend,
      connect: { [self] identity, _, _ in receipt("account-" + identity.subject) })
  }
}

private func device() -> DeviceKeychain {
  DeviceKeychain(service: "dev.unwired.product-sync.tests.\(UUID().uuidString)")
}

// The final group with its first digit changed.
private func wrongGroup(_ key: RecoveryKey) -> String {
  (key.lastGroup.first == "0" ? "1" : "0") + key.lastGroup.dropFirst()
}

private func remove(_ keys: DeviceKeychain, accounts: [String]) {
  try? keys.remove("registration")
  for account in accounts { try? keys.remove("product-sync." + account) }
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
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRecovery(envelope, key: .generate(), account: "account-a")
    }
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openRecovery(envelope, key: key, account: "account-b")
    }
    for (keyVersion, schemaVersion) in [(2, 3), (1, 2)] {
      #expect(throws: ProductSyncError.rejected) {
        try KeyRingEnvelope.openRecovery(
          EncryptedPayload(
            ciphertextBase64: envelope.ciphertextBase64, keyVersion: keyVersion,
            nonceBase64: envelope.nonceBase64, schemaVersion: schemaVersion,
            tagBase64: envelope.tagBase64), key: key, account: "account-a")
      }
    }

    let enrolling = Curve25519.KeyAgreement.PrivateKey()
    let sealed = try KeyRingEnvelope.enrollment(
      ring, to: enrolling.publicKey, account: "account-a", device: "device-b", request: "request-1")
    #expect(
      try KeyRingEnvelope.openEnrollment(
        sealed, with: enrolling, account: "account-a", device: "device-b", request: "request-1")
        == ring)
    #expect(throws: ProductSyncError.rejected) {
      try KeyRingEnvelope.openEnrollment(
        sealed, with: Curve25519.KeyAgreement.PrivateKey(), account: "account-a",
        device: "device-b", request: "request-1")
    }
    for (account, device, request) in [
      ("account-b", "device-b", "request-1"), ("account-a", "device-c", "request-1"),
      ("account-a", "device-b", "request-2"),
    ] {
      #expect(throws: ProductSyncError.rejected) {
        try KeyRingEnvelope.openEnrollment(
          sealed, with: enrolling, account: account, device: device, request: request)
      }
    }
  }

  @Test @MainActor func newAccountInitializesProductSyncOnceAndRelaunchKeepsItsKeys() async throws {
    let keys = device()
    defer { remove(keys, accounts: ["account-synthetic-product-subject"]) }
    let google = SyntheticGoogleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    let registered = try await backend.store(keys: keys, google: google).signIn()
    #expect(registered["privateSync"] == "recovery-key")
    let shown = try RecoveryKey(parsing: try #require(registered["recoveryKey"]))
    // The published envelope restores the device-held keys with the displayed Recovery Key only.
    let account = "account-synthetic-product-subject"
    let ring = try KeyRingEnvelope.openRecovery(
      try #require(backend.recovery[account]), key: shown, account: account)
    #expect(try backend.store(keys: keys, google: google).loadVault(account)?.ring == ring)
    #expect(backend.initializations == 1)

    google.scopes = [RegistrationStore.gmailScope]
    google.subject = "synthetic-mailbox-subject"
    let store = backend.store(keys: keys, google: google)
    let connected = try await store.authorizeGmail(reselect: false)
    #expect(connected["kind"] == "connected")
    #expect(connected["privateSyncMailboxes"] == "same@example.invalid")
    // Signing in again, as offered for pending setup, rechecks the mailbox without new consent.
    google.subject = "synthetic-product-subject"
    let sessions = google.hints.count
    #expect(try await backend.store(keys: keys, google: google).signIn() == connected)
    #expect(google.hints.count == sessions + 1)
    google.subject = "synthetic-mailbox-subject"
    let records = try #require(backend.records[account])
    #expect(records.count == 1)
    // Convex holds only opaque identifiers and ciphertext; no address, subject or credential.
    let visible =
      try String(decoding: JSONEncoder().encode(records), as: UTF8.self)
      + String(decoding: JSONEncoder().encode(backend.recovery), as: UTF8.self)
    for secret in [
      "same@example.invalid", "synthetic-mailbox-subject", "synthetic-access-token",
      shown.display,
    ] {
      #expect(!visible.contains(secret))
    }

    #expect(throws: RegistrationError.recoveryKeyMismatch) {
      try store.confirmRecoveryKey(wrongGroup(shown))
    }
    let confirmed = try store.confirmRecoveryKey(shown.lastGroup.lowercased())
    #expect(confirmed["privateSync"] == "ready")
    #expect(confirmed["recoveryKey"] == nil)

    // A record sealed for another Product Account is never presented as this account's mailbox.
    let foreign = ProductSyncKeyRing.create()
    backend.records[account]?["mailbox.foreign"] = StoredPayload(
      payloadIdentifier: "mailbox.foreign",
      encryptedPayload: try foreign.seal(
        record: JSONEncoder().encode(
          MailboxDescriptor(provider: "gmail", address: "x@example.invalid")),
        account: "account-other", identifier: "mailbox.foreign", schemaVersion: 1),
      updatedAt: 1)

    // Relaunch recovers the same keys and the decrypted record without generating anything.
    let relaunched = try await backend.store(keys: keys, google: google).restore()
    var expected = connected.merging(["privateSync": "ready"]) { $1 }
    expected["recoveryKey"] = nil
    #expect(relaunched == expected)
    #expect(backend.initializations == 1)
    #expect(try backend.store(keys: keys, google: google).loadVault(account)?.ring == ring)
  }

  @Test @MainActor func missingLocalKeysNeverReplaceAnExistingAccountsKeyMaterial() async throws {
    let first = device()
    let second = device()
    let account = "account-synthetic-product-subject"
    defer {
      remove(first, accounts: [account])
      remove(second, accounts: [account])
    }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let backend = SyntheticProductSyncBackend()

    // An interrupted first publication keeps the saved keys and finishes them later.
    backend.offline = true
    let pending = try await backend.store(keys: first, google: google).signIn()
    #expect(pending["privateSync"] == "setup-pending")
    let saved = try #require(try backend.store(keys: first, google: google).loadVault(account))
    #expect(backend.recovery[account] == nil)

    // Meanwhile another installation finds the account uninitialized and wins publication.
    backend.offline = false
    let winner = try await backend.store(keys: second, google: google).signIn()
    #expect(winner["privateSync"] == "recovery-key")
    let published = try #require(backend.recovery[account])
    #expect(published != saved.recoveryEnvelope)

    // The first device discards its unpublished keys and needs enrollment instead.
    let resumed = try await backend.store(keys: first, google: google).restore()
    #expect(resumed["privateSync"] == "enrollment-needed")
    #expect(resumed["recoveryKey"] == nil)
    #expect(try backend.store(keys: first, google: google).loadVault(account) == nil)
    #expect(backend.recovery[account] == published)
    #expect(backend.initializations == 1)

    // Gmail stays authorizable, but no record is written without the account's keys.
    let connected = try await backend.store(keys: first, google: google).authorizeGmail(
      reselect: false)
    #expect(connected["kind"] == "connected")
    #expect(connected["privateSync"] == "enrollment-needed")
    #expect(backend.records[account] == nil)
    #expect(
      try await backend.store(keys: first, google: google).restore()["privateSync"]
        == "enrollment-needed")
    #expect(throws: RegistrationError.unavailable) {
      try backend.store(keys: first, google: google).confirmRecoveryKey("0000")
    }

    // The winning device resumes with its own keys after relaunch.
    let restored = try await backend.store(keys: second, google: google).restore()
    #expect(restored["recoveryKey"] == winner["recoveryKey"])
    #expect(backend.initializations == 1)
  }

  @Test @MainActor func unknownProductSyncStateWaitsForVerificationWithoutCreatingKeys()
    async throws
  {
    let keys = device()
    let account = "account-synthetic-apple-subject"
    defer { remove(keys, accounts: [account]) }
    let google = SyntheticGoogleRegistrationProvider()
    let apple = SyntheticAppleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    var legacy = true
    func store() -> RegistrationStore {
      RegistrationStore(
        keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
        provider: google, apple: apple, productSync: backend.backend,
        connect: { identity, _, _ in
          var receipt = backend.receipt("account-" + identity.subject)
          if legacy { receipt.productSyncMaterialInitialized = nil }
          return receipt
        })
    }
    // A receipt without Product Sync state, as saved before this slice, neither creates keys
    // nor demands enrollment; Apple restore cannot reconnect, so it offers sign-in again.
    #expect(try await store().signIn(with: .apple)["privateSync"] == "setup-pending")
    #expect(try await store().restore()["privateSync"] == "setup-pending")
    #expect(try store().loadVault(account) == nil)
    #expect(backend.initializations == 0)
    // Signing in again reports the account's actual state, which initializes it.
    legacy = false
    #expect(try await store().signIn(with: .apple)["privateSync"] == "recovery-key")
    #expect(backend.initializations == 1)
  }

  @Test @MainActor func appleRelaunchAsksToSignInAgainBeforeSavingANewMailbox() async throws {
    let keys = device()
    let account = "account-synthetic-apple-subject"
    defer { remove(keys, accounts: [account]) }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let apple = SyntheticAppleRegistrationProvider()
    let backend = SyntheticProductSyncBackend()
    func store() -> RegistrationStore {
      RegistrationStore(
        keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
        provider: google, apple: apple, productSync: backend.backend,
        connect: { identity, _, _ in backend.receipt("account-" + identity.subject) })
    }
    let first = store()
    _ = try await first.signIn(with: .apple)
    google.subject = "synthetic-mailbox-subject"
    #expect(try await first.authorizeGmail(reselect: false)["privateSyncPending"] == nil)
    // An Apple relaunch cannot reach Convex but still shows the list it last decrypted.
    #expect(try await store().restore()["privateSyncMailboxes"] == "same@example.invalid")
    // After relaunch Apple has no backend session, so a newly chosen mailbox waits for sign-in.
    google.subject = "synthetic-other-mailbox"
    google.address = "other@example.invalid"
    let reselected = try await store().authorizeGmail(reselect: true)
    #expect(reselected["kind"] == "connected")
    #expect(reselected["privateSyncPending"] == "mailbox")
    #expect(backend.records[account]?.count == 1)
    // Signing in again saves the descriptor and reads both back.
    let signedIn = try await store().signIn(with: .apple)
    #expect(signedIn["privateSyncPending"] == nil)
    #expect(signedIn["privateSyncMailboxes"] == "other@example.invalid\nsame@example.invalid")
    #expect(backend.records[account]?.count == 2)
  }
}
