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

  // A signed-in account with an authorized mailbox and its Draft storage.
  @MainActor private struct AssetSession {
    let google = SyntheticGoogleRegistrationProvider()
    let service = "dev.unwired.registration.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache: PrivateInboxStore
    let store: RegistrationStore
    let bytes = Data("Private plan bytes".utf8)

    init() {
      google.scopes = [RegistrationStore.gmailScope]
      cache = PrivateInboxStore(
        directory: directory, service: service,
        attachments: directory.appendingPathComponent("tmp"), protectedDataAvailable: { true })
      store = google.store(
        keys: DeviceKeychain(service: service), mailCache: cache, deviceRevoked: { _ in false })
    }

    func owner() async throws -> String {
      _ = try await store.signIn()
      _ = try await store.authorizeGmail()
      return try #require(try await store.openDrafts()["owner"] as? String)
    }

    // A file as a system picker leaves it: in its own folder under the picker root.
    func picked(_ name: String) throws -> URL {
      let folder = RegistrationStore.pickedDraftFiles.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let file = folder.appendingPathComponent(name)
      try bytes.write(to: file)
      return file
    }

    func exists(_ path: String) -> Bool {
      FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path)
    }

    func remove() {
      try? DeviceKeychain(service: service).remove("registration")
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
  }

  // Draft assets are sealed to their Product Account and identifier, verified by digest when read,
  // kept while a stored Draft names them or their import is uncommitted, and purged with the account.
  @Test @MainActor func draftAssetsStayWithTheirDraftsUntilNoDraftKeepsThem() async throws {
    let session = AssetSession()
    defer { session.remove() }
    let (store, cache, bytes) = (session.store, session.cache, session.bytes)
    let owner = try await session.owner()

    // A picked file's bytes are sealed, only their size and digest come back, and the picker's
    // copy is removed once they are stored.
    let picked = try session.picked("plan.pdf")
    let imported = try await store.importDraftAsset(
      owner: owner, id: "plan00001", source: ["kind": "file", "uri": picked.absoluteString])
    let digest = try #require(imported["digest"] as? String)
    #expect(imported["size"] as? Int == bytes.count)
    #expect(digest.count == 64)
    #expect(!FileManager.default.fileExists(atPath: picked.path))
    let sealed = session.directory.appendingPathComponent("draft-assets/plan00001")
    #expect(try Data(contentsOf: sealed).range(of: bytes) == nil)
    let read = try await store.readDraftAsset(
      owner: owner, id: "plan00001", digest: digest, type: "application/pdf")
    #expect(read["uri"] as? String == "data:application/pdf;base64,\(bytes.base64EncodedString())")
    // Verifying an attachment returns no bytes.
    let verified = try await store.readDraftAsset(
      owner: owner, id: "plan00001", digest: digest, type: "application/pdf", preview: false)
    #expect(verified.isEmpty)
    // Another account, another digest or ciphertext moved to another identifier never reads.
    let other = try session.picked("plan.pdf")
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.importDraftAsset(
        owner: "another-account", id: "plan00002", source: ["kind": "file", "uri": other.path])
    }
    #expect(throws: PrivateInboxError.invalidStore) {
      _ = try cache.readDraftAsset(owner: "another-account", id: "plan00001", digest: digest)
    }
    #expect(throws: PrivateInboxError.invalidStore) {
      _ = try cache.readDraftAsset(
        owner: owner, id: "plan00001", digest: String(repeating: "0", count: 64))
    }
    try FileManager.default.copyItem(
      at: sealed, to: session.directory.appendingPathComponent("draft-assets/moved0001"))
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
    #expect(session.exists("draft-assets/plan00001"))
    #expect(!session.exists("draft-assets/moved0001"))
    _ = try await store.commitDrafts(
      owner: owner, expectedRevision: 1, document: "{}", keep: ["plan00001"])
    #expect(session.exists("draft-assets/plan00001"))
    _ = try await store.commitDrafts(owner: owner, expectedRevision: 2, document: "{}", keep: [])
    #expect(!session.exists("draft-assets/plan00001"))

    // Discarding removes bytes at once, and the account purge removes the rest.
    let pasted = try await store.importDraftAsset(
      owner: owner, id: "pasted001",
      source: ["kind": "data", "uri": "data:image/png;base64,\(bytes.base64EncodedString())"])
    #expect(pasted["digest"] as? String == digest)
    try await store.discardDraftAsset(id: "pasted001")
    #expect(!session.exists("draft-assets/pasted001"))
    _ = try await store.importDraftAsset(
      owner: owner, id: "pasted002",
      source: ["kind": "data", "uri": "data:image/png;base64,\(bytes.base64EncodedString())"])
    _ = try await store.purge(notice: "signed-out")
    #expect(!session.exists("draft-assets"))
  }

  // Bytes come only from a picker's copy, pasted data or a current Downloaded Attachment; any other
  // path JavaScript names is refused, and only the picker's own folders are ever removed.
  @Test @MainActor func draftAssetsImportOnlyFromGrantedSources() async throws {
    let session = AssetSession()
    defer { session.remove() }
    let (store, bytes) = (session.store, session.bytes)
    let owner = try await session.owner()

    await #expect(throws: PrivateInboxError.unavailable) {
      _ = try await store.importDraftAsset(
        owner: owner, id: "pasted002", source: ["kind": "data", "uri": "data:image/png,plain"])
    }
    let connection = MailboxConnection.id(subject: session.google.subject)
    let generation = store.generation(session.google.subject)
    let encoded = bytes.base64EncodedString().replacingOccurrences(of: "=", with: "")
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    let downloaded = try #require(
      try await store.saveAttachment(
        connection: connection, address: session.google.address, generation: generation,
        name: "plan.pdf", data: encoded, size: bytes.count)["file"] as? String)
    let mailbox: [String: Any] = [
      "connection": connection, "address": session.google.address, "generation": generation,
    ]
    let received = try await store.importDraftAsset(
      owner: owner, id: "received1",
      source: ["kind": "received", "mailbox": mailbox, "file": downloaded])
    #expect(received["size"] as? Int == bytes.count)
    var stale = mailbox
    stale["generation"] = UUID().uuidString
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.importDraftAsset(
        owner: owner, id: "received2",
        source: ["kind": "received", "mailbox": stale, "file": downloaded])
    }
    // The same Downloaded Attachment named as a plain file skips no generation check: refused.
    let plaintext = try await store.attachmentFile(
      connection: connection, address: session.google.address, generation: generation,
      file: downloaded)
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.importDraftAsset(
        owner: owner, id: "plaintext", source: ["kind": "file", "uri": plaintext.absoluteString])
    }

    // A picker's copy over the per-file limit is refused before it is read, and removed.
    let large = try session.picked("large.bin")
    let handle = try FileHandle(forWritingTo: large)
    try handle.truncate(atOffset: UInt64(PrivateInboxStore.draftAssetLimit + 1))
    try handle.close()
    await #expect(throws: PrivateInboxError.tooLarge) {
      _ = try await store.importDraftAsset(
        owner: owner, id: "large0001", source: ["kind": "file", "uri": large.absoluteString])
    }
    #expect(!FileManager.default.fileExists(atPath: large.deletingLastPathComponent().path))

    // A similarly named folder beside the picker root is not the picker's: it is neither read
    // nor removed.
    let unrelated = RegistrationStore.pickedDraftFiles.deletingLastPathComponent()
      .appendingPathComponent("draft-picks-other-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: unrelated) }
    let original = unrelated.appendingPathComponent("plan.pdf")
    try bytes.write(to: original)
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.importDraftAsset(
        owner: owner, id: "original1", source: ["kind": "file", "uri": original.absoluteString])
    }
    RegistrationStore.discardPickedDraftFile(original)
    #expect(try Data(contentsOf: original) == bytes)
    // Abandoned picker results use the same exact ownership boundary.
    let abandoned = try session.picked("plan.pdf")
    RegistrationStore.discardPickedDraftFile(abandoned)
    #expect(!FileManager.default.fileExists(atPath: abandoned.deletingLastPathComponent().path))
  }
}
