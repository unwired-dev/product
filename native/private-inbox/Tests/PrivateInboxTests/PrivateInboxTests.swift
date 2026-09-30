import CryptoKit
import Foundation
import Testing

@testable import PrivateInbox

struct PrivateInboxTests {
  private let seed = """
    [{"id":"first","sender":"Synthetic Sender","address":"fixture@example.com","subject":"Private fixture subject",
      "preview":"Private preview","body":"Secret fixture body","receivedAt":"2026-09-28T09:42:00Z","unread":true},
    {"id":"second","sender":"Another Sender","address":"other@example.com","subject":"Another fixture",
      "preview":"Another preview","body":"Another body","receivedAt":"2026-09-28T09:42:00Z","unread":true}]
    """

  @Test func encryptedRelaunchMissingKeyAndTampering() throws {
    let service = "dev.unwired.private-inbox.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keys = DeviceKeychain(service: service + ".database")
    defer {
      try? keys.remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    let store = PrivateInboxStore(directory: directory, service: service)
    _ = try store.open(seed: seed)
    _ = try store.setUnread(id: "first", unread: false)
    let reopened = PrivateInboxStore(directory: directory, service: service)
    let snapshot = try JSONDecoder().decode(
      InboxSnapshot.self, from: Data(reopened.open(seed: "[]").utf8))
    #expect(snapshot.messages.first?.unread == false)
    #expect(snapshot.messages.count == 2)
    let path = directory.appendingPathComponent("inbox.enc")
    let ciphertext = try Data(contentsOf: path)
    for plaintext in [
      "Synthetic Sender", "fixture@example.com", "Private fixture subject", "Secret fixture body",
    ] {
      #expect(ciphertext.range(of: Data(plaintext.utf8)) == nil)
    }
    let key = try #require(try keys.read("encryption-key"))
    #expect(throws: (any Error).self) {
      try AES.GCM.open(
        AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(size: .bits256),
        authenticating: Data("dev.unwired.private-inbox.v1".utf8))
    }
    try keys.remove("encryption-key")
    #expect(throws: PrivateInboxError.locked) { try reopened.open(seed: seed) }
    #expect(throws: PrivateInboxError.locked) {
      try reopened.setUnread(id: "second", unread: false)
    }
    #expect(try keys.read("encryption-key") == nil)
    #expect(try Data(contentsOf: path) == ciphertext)
    try keys.insert(key, account: "encryption-key")
    let restored = try JSONDecoder().decode(
      InboxSnapshot.self, from: Data(reopened.open(seed: seed).utf8))
    #expect(restored.messages.first?.unread == false)
    var damaged = ciphertext
    damaged[damaged.count - 1] ^= 1
    try damaged.write(to: path)
    #expect(throws: PrivateInboxError.invalidStore) { try reopened.open(seed: seed) }
    #expect(try Data(contentsOf: path) == damaged)
    try ciphertext.write(to: path)
  }

  @Test func protectedDataLockPreservesStorageAndRetriesAfterUnlock() throws {
    let service = "dev.unwired.private-inbox.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keys = DeviceKeychain(service: service + ".database")
    defer {
      try? keys.remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    var available = false
    let store = PrivateInboxStore(
      directory: directory, service: service, protectedDataAvailable: { available })
    #expect(throws: PrivateInboxError.locked) { try store.open(seed: seed) }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(try keys.read("encryption-key") == nil)
    available = true
    _ = try store.open(seed: seed)
    _ = try store.setUnread(id: "first", unread: false)
    let file = directory.appendingPathComponent("inbox.enc")
    let ciphertext = try Data(contentsOf: file)
    let key = try keys.read("encryption-key")
    available = false
    #expect(throws: PrivateInboxError.locked) { try store.open(seed: "[]") }
    #expect(throws: PrivateInboxError.locked) {
      try store.setUnread(id: "second", unread: false)
    }
    #expect(try Data(contentsOf: file) == ciphertext)
    #expect(try keys.read("encryption-key") == key)
    available = true
    let restored = try JSONDecoder().decode(
      InboxSnapshot.self, from: Data(store.open(seed: "[]").utf8))
    #expect(restored.messages.count == 2)
    #expect(restored.messages[0].unread == false)
    #expect(restored.messages[1].unread == true)
  }

  @Test func credentialRemovalPreservesTheDatabase() throws {
    let service = "dev.unwired.private-inbox.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keys = DeviceKeychain(service: service + ".database")
    let credential = SyntheticCredential(service: service)
    defer {
      try? keys.remove("encryption-key")
      try? credential.remove()
      try? FileManager.default.removeItem(at: directory)
    }
    let store = PrivateInboxStore(directory: directory, service: service)
    _ = try store.open(seed: seed)
    _ = try store.setUnread(id: "first", unread: false)
    try credential.store()
    let proof = try credential.use()
    #expect(try SyntheticCredential(service: service).use() == proof)
    try credential.remove()
    #expect(throws: PrivateInboxError.locked) { try credential.use() }
    try credential.remove()
    let afterRemoval = try JSONDecoder().decode(
      InboxSnapshot.self, from: Data(store.open(seed: seed).utf8))
    #expect(afterRemoval.messages.first?.unread == false)
  }

  @Test func competingStoreInstancesPreserveCompletedChanges() async throws {
    let service = "dev.unwired.private-inbox.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    let store = PrivateInboxStore(directory: directory, service: service)
    _ = try store.open(seed: seed)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for id in ["first", "second"] {
        group.addTask {
          let window = PrivateInboxStore(directory: directory, service: service)
          _ = try window.setUnread(id: id, unread: false)
        }
      }
      try await group.waitForAll()
    }
    let snapshot = try JSONDecoder().decode(
      InboxSnapshot.self, from: Data(store.open(seed: seed).utf8))
    #expect(snapshot.revision == 2)
    #expect(snapshot.messages.allSatisfy { !$0.unread })
  }
}

@MainActor final class SyntheticGoogleRegistrationProvider: GoogleRegistrationProvider {
  var subject = "synthetic-product-subject"
  var outcome: RegistrationError?
  var scopes: Set<String> = []
  var gmailAvailable = true

  func value(_ subject: String) -> GoogleRegistrationIdentity {
    GoogleRegistrationIdentity(
      subject: subject, credential: Data(subject.utf8),
      idToken: "synthetic-id-token-" + subject, accessToken: "synthetic-access-token",
      scopes: scopes)
  }
  func signIn(mail: Bool, hint: String?) async throws -> GoogleRegistrationIdentity {
    if let outcome { throw outcome }
    return value(subject)
  }
  func refresh(_ credential: Data) async throws -> GoogleRegistrationIdentity {
    guard let saved = String(data: credential, encoding: .utf8) else {
      throw RegistrationError.invalidIdentity
    }
    return value(saved)
  }
  func verifyGmail(_ identity: GoogleRegistrationIdentity) async throws -> GmailRegistrationReceipt
  {
    guard gmailAvailable else { throw RegistrationError.gmailUnavailable }
    return GmailRegistrationReceipt(subject: identity.subject, address: "same@example.invalid")
  }
  func store(keys: DeviceKeychain) -> RegistrationStore {
    RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: self,
      connect: { identity, _, _ in
        ProductRegistrationReceipt(
          productAccountId: "account-" + identity.subject,
          trustedDeviceId: "synthetic-device",
          trustedDeviceCredential: String(repeating: "a", count: 64))
      })
  }

}

extension PrivateInboxTests {
  @Test func googleCallbackClaimsRejectWrongNonceAudienceSubjectIssuerAndExpiry() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func token(_ changed: [String: Any] = [:]) throws -> String {
      var claims: [String: Any] = [
        "iss": "https://accounts.google.com", "aud": "native-client", "sub": "subject",
        "exp": now.timeIntervalSince1970 + 60, "nonce": "fresh-nonce",
      ]
      claims.merge(changed) { _, new in new }
      let bytes = try JSONSerialization.data(withJSONObject: claims)
      return "header."
        + bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
          of: "/", with: "_"
        ).replacingOccurrences(of: "=", with: "") + ".signature"
    }
    try GoogleIdentityClaims.validate(
      token(), clientID: "native-client", subject: "subject", nonce: "fresh-nonce", now: now)
    for changed: [String: Any] in [
      ["nonce": "previous-session-nonce"], ["aud": "another-client"], ["sub": "another-subject"],
      ["iss": "https://untrusted.example.invalid"], ["exp": now.timeIntervalSince1970 - 1],
    ] {
      #expect(throws: (any Error).self) {
        try GoogleIdentityClaims.validate(
          token(changed), clientID: "native-client", subject: "subject", nonce: "fresh-nonce",
          now: now)
      }
    }
  }

  @Test @MainActor func googleRegistrationRetainsAccountAcrossConsentFailuresAndReselection()
    async throws
  {
    let keys = DeviceKeychain(service: "dev.unwired.registration.tests.\(UUID().uuidString)")
    defer { try? keys.remove("registration") }
    let provider = SyntheticGoogleRegistrationProvider()
    let first = provider.store(keys: keys)
    let registered = try await first.signIn()
    #expect(
      registered == [
        "kind": "mailbox-needed", "productAccountId": "account-synthetic-product-subject",
      ])
    for failure in [RegistrationError.cancelled, .declined, .gmailUnavailable] {
      provider.outcome = failure
      let result = try await first.authorizeGmail(reselect: false)
      #expect(result["kind"] == "mailbox-needed")
      #expect(result["productAccountId"] == registered["productAccountId"])
      #expect(try await provider.store(keys: keys).restore()["kind"] == "mailbox-needed")
    }
    provider.outcome = nil
    // A signed-in Google identity with missing mail scopes cannot connect Gmail.
    let declined = try await first.authorizeGmail(reselect: false)
    #expect(declined["kind"] == "mailbox-needed")
    #expect(declined["reason"] == "declined")
    provider.scopes = [RegistrationStore.gmailScope]
    provider.gmailAvailable = false
    let unavailable = try await first.authorizeGmail(reselect: false)
    #expect(unavailable["kind"] == "mailbox-needed")
    #expect(unavailable["reason"] == "gmail-unavailable")
    provider.gmailAvailable = true
    provider.subject = "synthetic-mailbox-subject"
    let connected = try await provider.store(keys: keys).authorizeGmail(reselect: true)
    #expect(
      connected == [
        "kind": "connected", "productAccountId": "account-synthetic-product-subject",
        "providerSubject": "synthetic-mailbox-subject", "address": "same@example.invalid",
      ])
    #expect(try await provider.store(keys: keys).restore() == connected)
    #expect(try first.load()?.subject == "synthetic-product-subject")
    #expect(
      !connected.values.contains(where: {
        $0.contains("token") || $0.contains(String(repeating: "a", count: 64))
      }))
    provider.gmailAvailable = false
    #expect(try await provider.store(keys: keys).restore()["kind"] == "mailbox-needed")
  }

  @Test @MainActor
  func interruptedGoogleRegistrationResumesWithoutReplacingIdentityOrExistingInbox() async throws {
    let service = "dev.unwired.registration.tests.\(UUID().uuidString)"
    let keys = DeviceKeychain(service: service)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      try? keys.remove("registration")
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    let inbox = PrivateInboxStore(directory: directory, service: service)
    _ = try inbox.open(seed: seed)
    let ciphertext = try Data(contentsOf: directory.appendingPathComponent("inbox.enc"))
    let provider = SyntheticGoogleRegistrationProvider()
    let interrupted = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: provider,
      connect: { _, _, _ in throw RegistrationError.unavailable })
    await #expect(throws: (any Error).self) { try await interrupted.signIn() }
    #expect(try interrupted.load()?.subject == "synthetic-product-subject")
    let resumed = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: provider,
      connect: { identity, _, _ in
        ProductRegistrationReceipt(
          productAccountId: identity.subject, trustedDeviceId: "synthetic-device",
          trustedDeviceCredential: "synthetic-device-proof")
      })
    #expect(try await resumed.restore()["kind"] == "mailbox-needed")
    let offline = try await interrupted.restore()
    #expect(offline["kind"] == "mailbox-needed")
    #expect(offline["productAccountId"] == "synthetic-product-subject")
    #expect(offline["reason"] == "interrupted")
    provider.subject = "different-product-subject"
    await #expect(throws: (any Error).self) { try await resumed.signIn() }
    #expect(try resumed.load()?.subject == "synthetic-product-subject")
    #expect(try Data(contentsOf: directory.appendingPathComponent("inbox.enc")) == ciphertext)
  }
}
