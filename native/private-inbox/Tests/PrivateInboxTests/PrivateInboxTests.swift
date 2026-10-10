import Foundation
import Security
import Testing

@testable import PrivateInbox

struct PrivateInboxTests {
  let seed = """
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
    // Another 32-byte key in the Keychain never opens or replaces the existing store.
    try keys.save(Data(repeating: 7, count: 32), account: "encryption-key")
    #expect(throws: PrivateInboxError.invalidStore) { try reopened.open(seed: seed) }
    #expect(try Data(contentsOf: path) == ciphertext)
    try keys.remove("encryption-key")
    // Unlocking never restores a missing key, so the store must not ask the person to unlock.
    #expect(throws: PrivateInboxError.unavailable) { try reopened.open(seed: seed) }
    #expect(throws: PrivateInboxError.unavailable) {
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

  // A locked Keychain cannot be produced in tests; only it may report a state that unlock recovers.
  @Test func onlyUnavailableProtectedDataReportsLocked() {
    #expect(DeviceKeychain.failure(errSecInteractionNotAllowed) == .locked)
    #expect(DeviceKeychain.failure(errSecMissingEntitlement) == .unavailable)
    #expect(DeviceKeychain.failure(errSecDecode) == .unavailable)
  }

  @Test func protectedDataLockPreservesStorageAndRetriesAfterUnlock() throws {
    let service = "dev.unwired.private-inbox.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keys = DeviceKeychain(service: service + ".database")
    defer {
      try? keys.remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    let protectedData = ProtectedDataSwitch()
    let store = PrivateInboxStore(
      directory: directory, service: service, protectedDataAvailable: { protectedData.available })
    #expect(throws: PrivateInboxError.locked) { try store.open(seed: seed) }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(try keys.read("encryption-key") == nil)
    protectedData.available = true
    _ = try store.open(seed: seed)
    _ = try store.setUnread(id: "first", unread: false)
    let file = directory.appendingPathComponent("inbox.enc")
    let ciphertext = try Data(contentsOf: file)
    let key = try keys.read("encryption-key")
    protectedData.available = false
    #expect(throws: PrivateInboxError.locked) { try store.open(seed: "[]") }
    #expect(throws: PrivateInboxError.locked) {
      try store.setUnread(id: "second", unread: false)
    }
    #expect(try Data(contentsOf: file) == ciphertext)
    #expect(try keys.read("encryption-key") == key)
    protectedData.available = true
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

// Protected-data availability a test switches while store work may read it from any thread.
private final class ProtectedDataSwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var available: Bool {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
}
