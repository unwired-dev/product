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
      _ = try await store.commitDrafts(
        owner: "another-account", expectedRevision: 0, document: document)
    }
    let committed = try await store.commitDrafts(
      owner: owner, expectedRevision: 0, document: document)
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
      connection: String(repeating: "a", count: 32), address: "alex@example.invalid",
      subject: "google-subject",
      expectedRevision: 0, document: "{}")
    try probeKeys.remove("encryption-key")
    #expect(throws: PrivateInboxError.unavailable) {
      _ = try probe.commitDrafts(owner: owner, expectedRevision: 0, document: document)
    }
    #expect(throws: PrivateInboxError.unavailable) { _ = try probe.open(seed: "[]") }
    #expect(try probeKeys.read("encryption-key") == nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: probeDirectory.appendingPathComponent("drafts.enc").path))
    // The Outgoing Content Store refuses a document over its limit and keeps the saved one.
    #expect(throws: PrivateInboxError.unavailable) {
      _ = try relaunched.commitDrafts(
        owner: owner, expectedRevision: 1,
        document: String(repeating: "x", count: PrivateInboxStore.outgoingContentLimit + 1))
    }
    // Escaping counts: a document under the limit whose encrypted file would exceed it is refused.
    #expect(throws: PrivateInboxError.unavailable) {
      _ = try relaunched.commitDrafts(
        owner: owner, expectedRevision: 1,
        document: String(repeating: "\"", count: PrivateInboxStore.outgoingContentLimit / 2 + 1))
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

  // Draft assets are sealed to their Product Account and identifier, verified by digest when read,
  // kept while a stored Draft names them or their import is uncommitted, and purged with the account.
  @Test @MainActor func draftAssetsStayWithTheirDraftsUntilNoDraftKeepsThem() async throws {
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
    let cache = PrivateInboxStore(
      directory: directory, service: service, attachments: directory.appendingPathComponent("tmp"),
      protectedDataAvailable: { true })
    let store = google.store(keys: keys, mailCache: cache, deviceRevoked: { _ in false })
    _ = try await store.signIn()
    _ = try await store.authorizeGmail()
    let owner = try #require(try await store.openDrafts()["owner"] as? String)
    let bytes = Data("Private plan bytes".utf8)
    let picked = directory.appendingPathComponent("plan.pdf")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try bytes.write(to: picked)

    // A picked file's bytes are sealed, and only their size and digest come back.
    let imported = try await store.importDraftAsset(
      owner: owner, id: "plan00001", source: ["kind": "file", "uri": picked.absoluteString])
    let digest = try #require(imported["digest"] as? String)
    #expect(imported["size"] as? Int == bytes.count)
    #expect(digest.count == 64)
    let sealed = directory.appendingPathComponent("draft-assets/plan00001")
    #expect(try Data(contentsOf: sealed).range(of: bytes) == nil)
    let read = try await store.readDraftAsset(
      owner: owner, id: "plan00001", digest: digest, type: "application/pdf")
    #expect(read["uri"] as? String == "data:application/pdf;base64,\(bytes.base64EncodedString())")
    // Another account, another digest or ciphertext moved to another identifier never reads.
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.importDraftAsset(
        owner: "another-account", id: "plan00002", source: ["kind": "file", "uri": picked.path])
    }
    #expect(throws: PrivateInboxError.invalidStore) {
      _ = try cache.readDraftAsset(owner: "another-account", id: "plan00001", digest: digest)
    }
    #expect(throws: PrivateInboxError.invalidStore) {
      _ = try cache.readDraftAsset(
        owner: owner, id: "plan00001", digest: String(repeating: "0", count: 64))
    }
    try FileManager.default.copyItem(
      at: sealed, to: directory.appendingPathComponent("draft-assets/moved0001"))
    #expect(throws: PrivateInboxError.invalidStore) {
      _ = try cache.readDraftAsset(owner: owner, id: "moved0001", digest: digest)
    }
    #expect(throws: PrivateInboxError.attachmentMissing) {
      _ = try cache.readDraftAsset(owner: owner, id: "absent001", digest: digest)
    }
    #expect(throws: PrivateInboxError.invalidStore) {
      _ = try cache.readDraftAsset(owner: owner, id: "../drafts", digest: digest)
    }

    // A save that does not name an uncommitted import keeps it; once a save keeps it, a later save
    // that drops it removes its bytes, after the document is stored. Unknown files go at once.
    _ = try await store.commitDrafts(owner: owner, expectedRevision: 0, document: "{}", keep: [])
    #expect(FileManager.default.fileExists(atPath: sealed.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("draft-assets/moved0001").path))
    _ = try await store.commitDrafts(
      owner: owner, expectedRevision: 1, document: "{}", keep: ["plan00001"])
    #expect(FileManager.default.fileExists(atPath: sealed.path))
    _ = try await store.commitDrafts(owner: owner, expectedRevision: 2, document: "{}", keep: [])
    #expect(!FileManager.default.fileExists(atPath: sealed.path))

    // Pasted data and a Downloaded Attachment import the same way; the Draft keeps only bytes.
    let pasted = try await store.importDraftAsset(
      owner: owner, id: "pasted001",
      source: ["kind": "data", "uri": "data:image/png;base64,\(bytes.base64EncodedString())"])
    #expect(pasted["digest"] as? String == digest)
    await #expect(throws: PrivateInboxError.unavailable) {
      _ = try await store.importDraftAsset(
        owner: owner, id: "pasted002", source: ["kind": "data", "uri": "data:image/png,plain"])
    }
    let connection = MailboxConnection.id(subject: google.subject)
    let generation = store.generation(google.subject)
    let encoded = bytes.base64EncodedString().replacingOccurrences(of: "=", with: "")
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    let downloaded = try #require(
      try await store.saveAttachment(
        connection: connection, address: google.address, generation: generation,
        name: "plan.pdf", data: encoded, size: bytes.count)["file"] as? String)
    let mailbox: [String: Any] = [
      "connection": connection, "address": google.address, "generation": generation,
    ]
    let received = try await store.importDraftAsset(
      owner: owner, id: "received1",
      source: ["kind": "received", "mailbox": mailbox, "file": downloaded])
    #expect(received["digest"] as? String == digest)
    var stale = mailbox
    stale["generation"] = UUID().uuidString
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.importDraftAsset(
        owner: owner, id: "received2",
        source: ["kind": "received", "mailbox": stale, "file": downloaded])
    }

    // A file over the per-file limit is refused before it is read.
    let large = directory.appendingPathComponent("large.bin")
    FileManager.default.createFile(atPath: large.path, contents: nil)
    let handle = try FileHandle(forWritingTo: large)
    try handle.truncate(atOffset: UInt64(PrivateInboxStore.draftAssetLimit + 1))
    try handle.close()
    await #expect(throws: PrivateInboxError.tooLarge) {
      _ = try await store.importDraftAsset(
        owner: owner, id: "large0001", source: ["kind": "file", "uri": large.path])
    }

    // A refused picker copy is removed, while a similarly named user folder stays untouched.
    let pickerFolder = RegistrationStore.pickedDraftFiles.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: pickerFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: pickerFolder) }
    let refusedPick = pickerFolder.appendingPathComponent("large.bin")
    try FileManager.default.copyItem(at: large, to: refusedPick)
    await #expect(throws: PrivateInboxError.tooLarge) {
      _ = try await store.importDraftAsset(
        owner: owner, id: "large0002", source: ["kind": "file", "uri": refusedPick.absoluteString])
    }
    #expect(!FileManager.default.fileExists(atPath: pickerFolder.path))
    let unrelated = RegistrationStore.pickedDraftFiles.deletingLastPathComponent()
      .appendingPathComponent("draft-picks-other-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: unrelated) }
    let original = unrelated.appendingPathComponent("plan.pdf")
    try bytes.write(to: original)
    _ = try await store.importDraftAsset(
      owner: owner, id: "original1", source: ["kind": "file", "uri": original.absoluteString])
    #expect(try Data(contentsOf: original) == bytes)
    // Abandoned picker results use the same exact ownership boundary.
    try FileManager.default.createDirectory(at: pickerFolder, withIntermediateDirectories: true)
    let abandoned = pickerFolder.appendingPathComponent("plan.pdf")
    try bytes.write(to: abandoned)
    RegistrationStore.discardPickedDraftFile(abandoned)
    #expect(!FileManager.default.fileExists(atPath: pickerFolder.path))
    RegistrationStore.discardPickedDraftFile(original)
    #expect(try Data(contentsOf: original) == bytes)

    // Discarding removes bytes at once, and the account purge removes the rest.
    try await store.discardDraftAsset(id: "pasted001")
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("draft-assets/pasted001").path))
    _ = try await store.purge(notice: "signed-out")
    #expect(
      !FileManager.default.fileExists(atPath: directory.appendingPathComponent("draft-assets").path)
    )
  }
}
