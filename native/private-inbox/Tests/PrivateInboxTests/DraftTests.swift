import Foundation
import Testing

@testable import PrivateInbox

struct DraftTests {
  @Test @MainActor func draftsStayEncryptedWithTheirProductAccountUntilItIsPurged() async throws {
    let service = "dev.unwired.registration.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keys = DeviceKeychain(service: service)
    defer {
      try? keys.remove("registration")
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let store = google.store(
      keys: keys, mailCache: PrivateInboxStore(directory: directory, service: service),
      deviceRevoked: { _ in false })
    // Without a Product Account there are no Drafts to open.
    await #expect(throws: PrivateInboxError.mailboxInvalidated) { _ = try await store.openDrafts() }
    _ = try await store.signIn()

    let opened = try await store.openDrafts()
    let owner = try #require(opened["owner"] as? String)
    #expect(opened["revision"] as? Int == 0)
    #expect(opened["document"] is NSNull)
    let document = #"{"version":1,"drafts":[{"subject":"Private draft subject"}]}"#
    // A save prepared for another Product Account changes nothing.
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.commitDrafts(owner: "another-account", expectedRevision: 0, document: document)
    }
    let committed = try await store.commitDrafts(owner: owner, expectedRevision: 0, document: document)
    #expect(committed["revision"] as? Int == 1)
    // A save from a revision that moved on is refused rather than overwriting it.
    await #expect(throws: PrivateInboxError.conflict) {
      _ = try await store.commitDrafts(owner: owner, expectedRevision: 0, document: "{}")
    }
    let file = directory.appendingPathComponent("drafts.enc")
    let ciphertext = try Data(contentsOf: file)
    #expect(ciphertext.range(of: Data("Private draft subject".utf8)) == nil)

    // Another store instance, as after relaunch, reads the same Draft for the same account only.
    let relaunched = PrivateInboxStore(directory: directory, service: service)
    #expect(try relaunched.openDrafts(owner: owner)["document"] as? String == document)
    let foreign = try relaunched.openDrafts(owner: "another-account")
    #expect(foreign["document"] is NSNull)
    #expect(foreign["revision"] as? Int == 1)
    // A first Draft must never replace a lost key while another encrypted layout depends on it.
    let probeDirectory = directory.appendingPathComponent("key-probe")
    let probe = PrivateInboxStore(directory: probeDirectory, service: service + ".probe")
    let probeKeys = DeviceKeychain(service: service + ".probe.database")
    defer { try? probeKeys.remove("encryption-key") }
    _ = try probe.commitMailbox(
      connection: String(repeating: "a", count: 32), address: "alex@example.invalid", subject: "google-subject",
      expectedRevision: 0, document: "{}")
    try probeKeys.remove("encryption-key")
    #expect(throws: PrivateInboxError.unavailable) {
      _ = try probe.commitDrafts(owner: owner, expectedRevision: 0, document: document)
    }
    #expect(throws: PrivateInboxError.unavailable) { _ = try probe.open(seed: "[]") }
    #expect(try probeKeys.read("encryption-key") == nil)
    #expect(!FileManager.default.fileExists(atPath: probeDirectory.appendingPathComponent("drafts.enc").path))
    // The Outgoing Content Store refuses a document over its limit and keeps the saved one.
    #expect(throws: PrivateInboxError.unavailable) {
      _ = try relaunched.commitDrafts(
        owner: owner, expectedRevision: 1,
        document: String(repeating: "x", count: PrivateInboxStore.outgoingContentLimit + 1))
    }
    var damaged = ciphertext
    damaged[damaged.count - 1] ^= 1
    try damaged.write(to: file)
    #expect(throws: PrivateInboxError.invalidStore) { _ = try relaunched.openDrafts(owner: owner) }
    #expect(try Data(contentsOf: file) == damaged)
    try ciphertext.write(to: file)

    // Purging the account removes its Drafts with everything else it kept on this device.
    _ = try await store.purge(notice: "signed-out")
    #expect(!FileManager.default.fileExists(atPath: file.path))
    await #expect(throws: PrivateInboxError.mailboxInvalidated) { _ = try await store.openDrafts() }
  }
}
