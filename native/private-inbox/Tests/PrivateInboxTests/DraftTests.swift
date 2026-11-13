import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

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
    // Verified content without a decodable image has an explicit no-thumbnail reply.
    let read = try await store.readDraftAsset(
      owner: owner, id: "plan00001", digest: digest, type: "application/pdf")
    #expect(read["uri"] is NSNull)
    // A large image previews as a bounded PNG thumbnail; its full bytes never cross the bridge.
    let image = try Self.png(width: 1_600, height: 900)
    let photo = try await store.importDraftAsset(
      owner: owner, id: "photo0001",
      source: ["kind": "data", "uri": "data:image/png;base64,\(image.base64EncodedString())"])
    let thumbnail = try await store.readDraftAsset(
      owner: owner, id: "photo0001", digest: try #require(photo["digest"] as? String),
      type: "image/png")
    let uri = try #require(thumbnail["uri"] as? String)
    #expect(uri.hasPrefix("data:image/png;base64,"))
    let encoded = try #require(Data(base64Encoded: String(uri.dropFirst("data:image/png;base64,".count))))
    #expect(encoded.count < image.count)
    let decoded = try #require(
      CGImageSourceCreateWithData(encoded as CFData, nil).flatMap {
        CGImageSourceCreateImageAtIndex($0, 0, nil)
      })
    #expect(max(decoded.width, decoded.height) <= RegistrationStore.draftPreviewSize)
    #expect(
      try cache.readDraftAsset(
        owner: owner, id: "photo0001", digest: try #require(photo["digest"] as? String)) == image)
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

  // Composer recovery records are sealed to their account on this device, keep the assets they name
  // through saves, are written only while protected data is available, are removed without a key
  // and go with an account purge.
  @Test @MainActor func composerRecoveryRecordsKeepTheirAssetsUntilRemoved() async throws {
    let session = AssetSession()
    defer { session.remove() }
    let (store, cache) = (session.store, session.cache)
    let owner = try await session.owner()
    _ = try await store.importDraftAsset(
      owner: owner, id: "plan00001",
      source: [
        "kind": "data", "uri": "data:image/png;base64,\(session.bytes.base64EncodedString())",
      ])
    _ = try await store.commitDrafts(
      owner: owner, expectedRevision: 0, document: "{}", keep: ["plan00001"])
    let document = #"{"id":"draft1","subject":"Unsaved private subject"}"#
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.writeComposerRecovery(
        owner: "another-account", id: "draft1", document: document, assets: [])
    }
    _ = try await store.writeComposerRecovery(
      owner: owner, id: "draft1", document: document, assets: ["plan00001"])
    let folder = session.directory.appendingPathComponent("composer-recovery")
    let files = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    #expect(
      try Data(contentsOf: try #require(files.first)).range(
        of: Data("Unsaved private subject".utf8)) == nil)

    // A save that no longer names the asset keeps it while the record does, also after relaunch.
    _ = try await store.commitDrafts(owner: owner, expectedRevision: 1, document: "{}", keep: [])
    #expect(session.exists("draft-assets/plan00001"))
    let opened = try await store.openComposerRecovery()
    #expect(opened["owner"] as? String == owner)
    #expect(opened["records"] as? [[String: String]] == [["id": "draft1", "document": document]])
    let relaunched = PrivateInboxStore(
      directory: session.directory, service: session.service,
      attachments: session.directory.appendingPathComponent("tmp"), protectedDataAvailable: { true })
    #expect(try relaunched.openComposerRecovery(owner: owner).map(\.document) == [document])

    // While locked a record is neither written nor read, but it is still removed; the next save
    // then drops the asset.
    let locked = PrivateInboxStore(
      directory: session.directory, service: session.service,
      attachments: session.directory.appendingPathComponent("tmp"), protectedDataAvailable: { false })
    #expect(throws: PrivateInboxError.locked) {
      try locked.writeComposerRecovery(owner: owner, id: "draft2", document: "{}", assets: [])
    }
    #expect(throws: PrivateInboxError.locked) { _ = try locked.openComposerRecovery(owner: owner) }
    try locked.removeComposerRecovery(id: "draft1")
    #expect(try cache.openComposerRecovery(owner: owner).isEmpty)
    _ = try await store.commitDrafts(owner: owner, expectedRevision: 2, document: "{}", keep: [])
    #expect(!session.exists("draft-assets/plan00001"))

    // A record moved to another file name does not open and is removed.
    try cache.writeComposerRecovery(owner: owner, id: "draft3", document: "{}", assets: [])
    let sealed = try #require(
      try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
    try FileManager.default.copyItem(at: sealed, to: folder.appendingPathComponent("moved"))
    #expect(try cache.openComposerRecovery(owner: owner).map(\.id) == ["draft3"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)

    // Another Product Account reads no record, and opening its own removes this account's.
    #expect(try cache.openComposerRecovery(owner: "another-account").isEmpty)
    #expect(try cache.openComposerRecovery(owner: owner).isEmpty)
    _ = try await store.writeComposerRecovery(
      owner: owner, id: "draft4", document: document, assets: [])
    _ = try await store.purge(notice: "signed-out")
    #expect(!session.exists("composer-recovery"))

    // A first record on a store without a key creates it, and the store keeps working.
    let freshService = session.service + ".fresh"
    defer { try? DeviceKeychain(service: freshService + ".database").remove("encryption-key") }
    let fresh = PrivateInboxStore(
      directory: session.directory.appendingPathComponent("fresh"), service: freshService,
      attachments: session.directory.appendingPathComponent("tmp"), protectedDataAvailable: { true })
    try fresh.writeComposerRecovery(owner: owner, id: "draft5", document: "{}", assets: [])
    _ = try fresh.commitDrafts(owner: owner, expectedRevision: 0, document: "{}")
    #expect(try fresh.openComposerRecovery(owner: owner).map(\.id) == ["draft5"])
  }

  // Recovery records count toward the Outgoing Content Store's limit with the Drafts and their
  // assets: a record that does not fit is refused, and records leave less space for saves.
  @Test @MainActor func composerRecoveryRecordsCountTowardTheOutgoingContentLimit() async throws {
    let session = AssetSession()
    defer { session.remove() }
    let cache = session.cache
    let owner = try await session.owner()
    _ = try cache.importDraftAsset(owner: owner, id: "filler001", bytes: session.bytes)
    _ = try cache.commitDrafts(
      owner: owner, expectedRevision: 0, document: "{}", keep: ["filler001"])
    let handle = try FileHandle(
      forWritingTo: session.directory.appendingPathComponent("draft-assets/filler001"))
    try handle.truncate(atOffset: UInt64(PrivateInboxStore.outgoingContentLimit - 10_000))
    try handle.close()
    func record(_ id: String, _ count: Int) throws {
      try cache.writeComposerRecovery(
        owner: owner, id: id, document: String(repeating: "x", count: count), assets: [])
    }

    // Replacing a record counts only the new one.
    try record("draft1", 5_000)
    try record("draft1", 8_000)
    #expect(throws: PrivateInboxError.unavailable) { try record("draft1", 20_000) }
    #expect(throws: PrivateInboxError.unavailable) { try record("draft2", 3_000) }
    #expect(
      try cache.openComposerRecovery(owner: owner).map(\.document) == [
        String(repeating: "x", count: 8_000)
      ])

    // A save and an import that would fit without the record are refused.
    #expect(throws: PrivateInboxError.unavailable) {
      _ = try cache.commitDrafts(
        owner: owner, expectedRevision: 1, document: String(repeating: "x", count: 3_000),
        keep: ["filler001"])
    }
    #expect(throws: PrivateInboxError.tooLarge) {
      _ = try cache.importDraftAsset(owner: owner, id: "late00001", bytes: Data(count: 3_000))
    }

    try cache.removeComposerRecovery(id: "draft1")
    _ = try cache.commitDrafts(
      owner: owner, expectedRevision: 1, document: String(repeating: "x", count: 3_000),
      keep: ["filler001"])
    try record("draft2", 3_000)
  }

  // Mail Templates are kept like Drafts: encrypted for the account that wrote them, replaced only
  // from the revision read, sealed apart from the Drafts document and removed by an account purge.
  @Test @MainActor func mailTemplatesStayEncryptedWithTheirProductAccount() async throws {
    let session = AssetSession()
    defer { session.remove() }
    let (store, cache) = (session.store, session.cache)
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.openMailTemplates()
    }
    let owner = try await session.owner()
    let opened = try await store.openMailTemplates()
    #expect(opened["owner"] as? String == owner && opened["revision"] as? Int == 0)
    #expect(opened["document"] is NSNull)
    let document = #"{"templates":[{"id":"invoice","name":"Private template name"}]}"#
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.commitMailTemplates(
        owner: "another-account", expectedRevision: 0, document: document)
    }
    let committed = try await store.commitMailTemplates(
      owner: owner, expectedRevision: 0, document: document)
    #expect(committed["revision"] as? Int == 1)
    await #expect(throws: PrivateInboxError.conflict) {
      _ = try await store.commitMailTemplates(owner: owner, expectedRevision: 0, document: "{}")
    }
    let file = session.directory.appendingPathComponent("mail-templates.enc")
    let ciphertext = try Data(contentsOf: file)
    #expect(ciphertext.range(of: Data("Private template name".utf8)) == nil)
    // Drafts are a separate document.
    #expect(try cache.openDraftDocument(owner: owner).document == nil)

    // After relaunch only the same account reads them, and only while protected data is available.
    let relaunched = PrivateInboxStore(
      directory: session.directory, service: session.service,
      attachments: session.directory.appendingPathComponent("tmp"), protectedDataAvailable: { true })
    #expect(try relaunched.openMailTemplateDocument(owner: owner) == (1, document))
    #expect(try relaunched.openMailTemplateDocument(owner: "another-account") == (1, nil))
    let locked = PrivateInboxStore(
      directory: session.directory, service: session.service,
      attachments: session.directory.appendingPathComponent("tmp"), protectedDataAvailable: { false })
    #expect(throws: PrivateInboxError.locked) {
      _ = try locked.commitMailTemplateDocument(owner: owner, expectedRevision: 1, document: "{}")
    }
    // Escaping counts: a document under the limit whose encrypted file would exceed it is refused.
    #expect(throws: PrivateInboxError.unavailable) {
      _ = try relaunched.commitMailTemplateDocument(
        owner: owner, expectedRevision: 1,
        document: String(repeating: "\"", count: PrivateInboxStore.outgoingContentLimit / 2 + 1))
    }

    // A damaged file, or the Drafts document served in its place, does not open.
    var damaged = ciphertext
    damaged[damaged.count - 1] ^= 1
    try damaged.write(to: file)
    #expect(throws: PrivateInboxError.invalidStore) {
      _ = try relaunched.openMailTemplateDocument(owner: owner)
    }
    _ = try cache.commitDraftDocument(owner: owner, expectedRevision: 0, document: document)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.copyItem(
      at: session.directory.appendingPathComponent("drafts.enc"), to: file)
    #expect(throws: PrivateInboxError.invalidStore) {
      _ = try relaunched.openMailTemplateDocument(owner: owner)
    }
    try FileManager.default.removeItem(at: file)
    try ciphertext.write(to: file)

    _ = try await store.purge(notice: "signed-out")
    #expect(!session.exists("mail-templates.enc"))
  }

  // Blocked Senders are kept like Mail Templates, in their own sealed file that neither the Drafts
  // nor the Mail Templates document opens as.
  @Test @MainActor func blockedSendersStayEncryptedWithTheirProductAccount() async throws {
    let session = AssetSession()
    defer { session.remove() }
    let (store, cache) = (session.store, session.cache)
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.openBlockedSenders()
    }
    let owner = try await session.owner()
    let opened = try await store.openBlockedSenders()
    #expect(opened["owner"] as? String == owner && opened["revision"] as? Int == 0)
    #expect(opened["document"] is NSNull)
    let document = #"{"senders":[{"profile":"work","address":"offers@private.invalid"}]}"#
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.commitBlockedSenders(
        owner: "another-account", expectedRevision: 0, document: document)
    }
    let committed = try await store.commitBlockedSenders(
      owner: owner, expectedRevision: 0, document: document)
    #expect(committed["revision"] as? Int == 1)
    await #expect(throws: PrivateInboxError.conflict) {
      _ = try await store.commitBlockedSenders(owner: owner, expectedRevision: 0, document: "{}")
    }
    let file = session.directory.appendingPathComponent("blocked-senders.enc")
    let ciphertext = try Data(contentsOf: file)
    #expect(ciphertext.range(of: Data("offers@private.invalid".utf8)) == nil)
    #expect(try cache.openMailTemplateDocument(owner: owner).document == nil)

    let tmp = session.directory.appendingPathComponent("tmp")
    let relaunched = PrivateInboxStore(
      directory: session.directory, service: session.service, attachments: tmp,
      protectedDataAvailable: { true })
    #expect(try relaunched.openBlockedSenderDocument(owner: owner) == (1, document))
    #expect(try relaunched.openBlockedSenderDocument(owner: "another-account") == (1, nil))
    let locked = PrivateInboxStore(
      directory: session.directory, service: session.service, attachments: tmp,
      protectedDataAvailable: { false })
    #expect(throws: PrivateInboxError.locked) {
      _ = try locked.commitBlockedSenderDocument(owner: owner, expectedRevision: 1, document: "{}")
    }

    // The Mail Templates document served in its place does not open.
    _ = try cache.commitMailTemplateDocument(owner: owner, expectedRevision: 0, document: document)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.copyItem(
      at: session.directory.appendingPathComponent("mail-templates.enc"), to: file)
    #expect(throws: PrivateInboxError.invalidStore) {
      _ = try relaunched.openBlockedSenderDocument(owner: owner)
    }

    _ = try await store.purge(notice: "signed-out")
    #expect(!session.exists("blocked-senders.enc"))
  }

  // Send Reminders are kept like Mail Templates, in their own sealed file that neither the Drafts
  // nor the Mail Templates document opens as.
  @Test @MainActor func sendRemindersStayEncryptedWithTheirProductAccount() async throws {
    let session = AssetSession()
    defer { session.remove() }
    let (store, cache) = (session.store, session.cache)
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.openSendReminders()
    }
    let owner = try await session.owner()
    let opened = try await store.openSendReminders()
    #expect(opened["owner"] as? String == owner && opened["revision"] as? Int == 0)
    #expect(opened["document"] is NSNull)
    let document = #"{"reminders":[{"draft":"private-draft-id","profile":"work"}]}"#
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.commitSendReminders(
        owner: "another-account", expectedRevision: 0, document: document)
    }
    let committed = try await store.commitSendReminders(
      owner: owner, expectedRevision: 0, document: document)
    #expect(committed["revision"] as? Int == 1)
    await #expect(throws: PrivateInboxError.conflict) {
      _ = try await store.commitSendReminders(owner: owner, expectedRevision: 0, document: "{}")
    }
    let file = session.directory.appendingPathComponent("send-reminders.enc")
    let ciphertext = try Data(contentsOf: file)
    #expect(ciphertext.range(of: Data("private-draft-id".utf8)) == nil)
    #expect(try cache.openMailTemplateDocument(owner: owner).document == nil)

    let tmp = session.directory.appendingPathComponent("tmp")
    let relaunched = PrivateInboxStore(
      directory: session.directory, service: session.service, attachments: tmp,
      protectedDataAvailable: { true })
    #expect(try relaunched.openSendReminderDocument(owner: owner) == (1, document))
    #expect(try relaunched.openSendReminderDocument(owner: "another-account") == (1, nil))
    let locked = PrivateInboxStore(
      directory: session.directory, service: session.service, attachments: tmp,
      protectedDataAvailable: { false })
    #expect(throws: PrivateInboxError.locked) {
      _ = try locked.commitSendReminderDocument(owner: owner, expectedRevision: 1, document: "{}")
    }

    // The Mail Templates document served in its place does not open.
    _ = try cache.commitMailTemplateDocument(owner: owner, expectedRevision: 0, document: document)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.copyItem(
      at: session.directory.appendingPathComponent("mail-templates.enc"), to: file)
    #expect(throws: PrivateInboxError.invalidStore) {
      _ = try relaunched.openSendReminderDocument(owner: owner)
    }

    _ = try await store.purge(notice: "signed-out")
    #expect(!session.exists("send-reminders.enc"))
  }

  // Send Reminders share the Outgoing Content Store's limit with the Drafts and their assets: a
  // reminder that does not fit is refused, and reminders leave less space for saves.
  @Test @MainActor func sendRemindersCountTowardTheOutgoingContentLimit() async throws {
    let session = AssetSession()
    defer { session.remove() }
    let cache = session.cache
    let owner = try await session.owner()
    _ = try cache.importDraftAsset(owner: owner, id: "filler001", bytes: session.bytes)
    _ = try cache.commitDrafts(
      owner: owner, expectedRevision: 0, document: "{}", keep: ["filler001"])
    let handle = try FileHandle(
      forWritingTo: session.directory.appendingPathComponent("draft-assets/filler001"))
    try handle.truncate(atOffset: UInt64(PrivateInboxStore.outgoingContentLimit - 10_000))
    try handle.close()
    func reminders(_ revision: Int, _ count: Int) throws -> Int {
      try cache.commitSendReminderDocument(
        owner: owner, expectedRevision: revision,
        document: String(repeating: "x", count: count))
    }

    // Replacing the document counts only the new one.
    #expect(try reminders(0, 5_000) == 1)
    #expect(try reminders(1, 8_000) == 2)
    #expect(throws: PrivateInboxError.unavailable) { _ = try reminders(2, 20_000) }
    // The Drafts document no longer fits beside the reminders.
    #expect(throws: PrivateInboxError.unavailable) {
      _ = try cache.commitDrafts(
        owner: owner, expectedRevision: 1, document: String(repeating: "x", count: 3_000),
        keep: ["filler001"])
    }
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

extension DraftTests {
  // Refused garbage collection after document replacement does not refuse the durable save;
  // a later save retries the leftover ciphertext once its directory is writable again.
  @Test @MainActor func draftSaveSucceedsWhenAssetCleanupMustWait() async throws {
    let session = AssetSession()
    defer { session.remove() }
    let store = session.store
    let owner = try await session.owner()
    _ = try await store.importDraftAsset(
      owner: owner, id: "cleanup01",
      source: [
        "kind": "data", "uri": "data:image/png;base64,\(session.bytes.base64EncodedString())",
      ])
    _ = try await store.commitDrafts(
      owner: owner, expectedRevision: 0, document: "kept", keep: ["cleanup01"])
    let folder = session.directory.appendingPathComponent("draft-assets")
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
    let saved = try await store.commitDrafts(
      owner: owner, expectedRevision: 1, document: "removed", keep: [])
    #expect(saved["revision"] as? Int == 2)
    #expect(session.exists("draft-assets/cleanup01"))
    let opened = try await store.openDrafts()
    #expect(opened["revision"] as? Int == 2)
    #expect(opened["document"] as? String == "removed")
    // The leftover still takes Outgoing Content Store space until it is removed, so a save that
    // would exceed the limit with it is refused.
    let handle = try FileHandle(forWritingTo: folder.appendingPathComponent("cleanup01"))
    try handle.truncate(atOffset: UInt64(PrivateInboxStore.outgoingContentLimit - 1_000))
    try handle.close()
    await #expect(throws: PrivateInboxError.unavailable) {
      _ = try await store.commitDrafts(
        owner: owner, expectedRevision: 2, document: String(repeating: "x", count: 2_000),
        keep: [])
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    _ = try await store.commitDrafts(
      owner: owner, expectedRevision: 2, document: "retried", keep: [])
    #expect(!session.exists("draft-assets/cleanup01"))

    // A discard that cannot remove an uncommitted import still releases its import protection,
    // so a later save removes the leftover file instead of keeping it until relaunch.
    _ = try await store.importDraftAsset(
      owner: owner, id: "discard01",
      source: [
        "kind": "data", "uri": "data:image/png;base64,\(session.bytes.base64EncodedString())",
      ])
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    await #expect(throws: (any Error).self) { try await store.discardDraftAsset(id: "discard01") }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    #expect(session.exists("draft-assets/discard01"))
    _ = try await store.commitDrafts(
      owner: owner, expectedRevision: 3, document: "discarded", keep: [])
    #expect(!session.exists("draft-assets/discard01"))
  }

  // A solid-colour PNG of the given size, as a photo-sized image.
  private static func png(width: Int, height: Int) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }
}
