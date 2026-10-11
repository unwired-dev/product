import Foundation
import Testing

@testable import PrivateInbox

extension PrivateInboxTests {
  // Each Google account is one connection with its own credential, verification and cache. Adding
  // it again repairs it, a refused grant stays with its own connection, and removal takes only it.
  @Test @MainActor func mailboxConnectionsStayDeduplicatedAndIsolated() async throws {
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
    google.mailboxAddresses = [
      "synthetic-product-subject": "same@example.invalid",
      "synthetic-other-mailbox": "other@example.invalid",
    ]
    let store = google.store(
      keys: keys, mailCache: PrivateInboxStore(directory: directory, service: service),
      deviceRevoked: { _ in false })
    _ = try await store.signIn()
    google.hints = []
    _ = try await store.authorizeGmail()
    let first = MailboxConnection.id(subject: "synthetic-product-subject")
    let second = MailboxConnection.id(subject: "synthetic-other-mailbox")
    google.subject = "synthetic-other-mailbox"
    google.address = "other@example.invalid"
    let both = try await store.authorizeGmail(chooseAccount: true)
    #expect(both["kind"] == "connected")
    #expect(
      try mailboxDisplay(both["mailboxes"])
        == mailboxList([
          ("synthetic-product-subject", "same@example.invalid", "connected"),
          ("synthetic-other-mailbox", "other@example.invalid", "connected"),
        ]))
    // Adding the same Google account again authorizes its connection instead of duplicating it.
    #expect(try await store.authorizeGmail(chooseAccount: true) == both)
    #expect(try store.load()?.connections.count == 2)
    // Only the first mailbox suggests the Google sign-in; another one is chosen freely.
    #expect(google.hints == ["synthetic-product-subject", nil, nil])

    _ = try store.commitMailbox(
      connection: first, address: "same@example.invalid", expectedRevision: 0,
      document: "first", generation: store.generation("synthetic-product-subject"))
    _ = try store.commitMailbox(
      connection: second, address: "other@example.invalid", expectedRevision: 0,
      document: "second", generation: store.generation("synthetic-other-mailbox"))
    #expect(try store.openMailbox(first)["document"] as? String == "first")
    #expect(try store.openMailbox(second)["document"] as? String == "second")

    // Gmail refuses one connection's grant; the other stays connected and its mail stays open.
    google.refusedSubjects = ["synthetic-other-mailbox"]
    let mixed = try await store.restore()
    #expect(mixed["kind"] == "connected")
    #expect(
      try mailboxDisplay(mixed["mailboxes"])
        == mailboxList([
          ("synthetic-product-subject", "same@example.invalid", "connected"),
          ("synthetic-other-mailbox", "other@example.invalid", "authorization"),
        ]))
    #expect(try store.openMailbox(first)["document"] as? String == "first")
    #expect(throws: RegistrationError.gmailUnavailable) { _ = try store.openMailbox(second) }
    google.gmailRequests = []
    await #expect(throws: RegistrationError.gmailUnavailable) {
      _ = try await store.gmail(
        path: "profile", query: [], connection: second, address: "other@example.invalid",
        generation: store.generation("synthetic-other-mailbox"))
    }
    #expect(google.gmailRequests.isEmpty)
    // Reauthorization repairs its own connection; another Google account cannot take its place.
    google.refusedSubjects = []
    google.subject = "synthetic-product-subject"
    await #expect(throws: RegistrationError.gmailUnavailable) {
      try await store.authorizeGmail(connection: second)
    }
    google.subject = "synthetic-other-mailbox"
    #expect(try await store.authorizeGmail(connection: second) == both)
    #expect(google.hints.last == "synthetic-other-mailbox")
    #expect(try store.openMailbox(second)["document"] as? String == "second")

    // Removing one connection removes its credential and cache; the other is untouched.
    let removed = try await store.flowRemoveMailbox(second)
    #expect(
      try mailboxDisplay(removed["mailboxes"])
        == mailboxList([("synthetic-product-subject", "same@example.invalid", "connected")]))
    #expect(try store.load()?.connections.map(\.receipt.subject) == ["synthetic-product-subject"])
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("mailboxes/\(second)").path))
    #expect(try store.openMailbox(first)["document"] as? String == "first")
    await #expect(throws: RegistrationError.unavailable) { try await store.flowRemoveMailbox(second) }
    await #expect(throws: RegistrationError.unavailable) {
      try await store.authorizeGmail(connection: second)
    }
    // Without Product Sync the removal and recreation stay queued, with a new authorization epoch.
    #expect(try store.load()?.mailboxRemovals?.map(\.subject) == ["synthetic-other-mailbox"])
    _ = try await store.authorizeGmail(chooseAccount: true)
    #expect(try store.load()?.mailboxRemovals?.map(\.subject) == ["synthetic-other-mailbox"])
    #expect(try store.load()?.connection(second)?.epoch != nil)
    #expect(try store.openMailbox(second)["document"] is NSNull)
  }

  // A record and cache written before Mailbox Connections become that mailbox's connection, so
  // its saved mail, bodies and pending changes survive the upgrade.
  @Test @MainActor func aSingleMailboxRecordAndItsCacheBecomeOneConnection() async throws {
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
    func store() -> RegistrationStore {
      google.store(
        keys: keys, mailCache: PrivateInboxStore(directory: directory, service: service),
        deviceRevoked: { _ in false })
    }
    let writer = store()
    _ = try await writer.signIn()
    _ = try await writer.authorizeGmail()
    let subject = "synthetic-product-subject"
    let id = MailboxConnection.id(subject: subject)
    _ = try writer.commitMailbox(
      connection: id, address: "same@example.invalid", expectedRevision: 0,
      document: "saved with a pending change", generation: writer.generation(subject))
    _ = try await writer.commitMessageBody(
      connection: id, address: "same@example.invalid", generation: writer.generation(subject),
      id: "a", admission: ["document": "saved body", "tier": "opened", "protectedIds": [String]()])
    // Rewrite both in the earlier layout: one mailbox in the record, its cache at the root.
    var saved = try #require(try writer.load())
    let connection = try #require(saved.connections.first)
    saved.mailboxes = nil
    saved.mailbox = connection.receipt
    saved.mailboxCredential = connection.credential
    try writer.save(saved)
    let folder = directory.appendingPathComponent("mailboxes/\(id)")
    try FileManager.default.moveItem(
      at: folder.appendingPathComponent("mailbox.enc"),
      to: directory.appendingPathComponent("mailbox.enc"))
    try FileManager.default.moveItem(
      at: folder.appendingPathComponent("bodies"), to: directory.appendingPathComponent("bodies"))
    try FileManager.default.removeItem(at: directory.appendingPathComponent("mailboxes"))

    let relaunched = store()
    #expect(try relaunched.load()?.connections.map(\.id) == [id])
    let restored = try await relaunched.restore()
    #expect(restored["kind"] == "connected")
    #expect(try mailboxDisplay(restored["mailboxes"]) == mailboxList([(subject, "same@example.invalid", "connected")]))
    #expect(try relaunched.load()?.mailbox == nil)
    #expect(
      try relaunched.openMailbox(id)["document"] as? String == "saved with a pending change")
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mailbox.enc").path))
    #expect(
      try await relaunched.openMessageBody(
        connection: id, address: "same@example.invalid", generation: relaunched.generation(subject),
        id: "a")["document"] as? String == "saved body")

    // Removal before opening the legacy cache still removes its private data without touching
    // another connection. The ownership marker survived conversion of the registration record.
    try FileManager.default.moveItem(
      at: folder.appendingPathComponent("mailbox.enc"),
      to: directory.appendingPathComponent("mailbox.enc"))
    try FileManager.default.moveItem(
      at: folder.appendingPathComponent("bodies"), to: directory.appendingPathComponent("bodies"))
    google.subject = "synthetic-other-mailbox"
    google.address = "other@example.invalid"
    _ = try await relaunched.authorizeGmail(chooseAccount: true)
    _ = try await relaunched.flowRemoveMailbox(MailboxConnection.id(subject: google.subject))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("mailbox.enc").path))
    _ = try await relaunched.flowRemoveMailbox(id)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mailbox.enc").path))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("bodies").path))
    google.subject = subject
    google.address = "same@example.invalid"
    _ = try await relaunched.authorizeGmail()
    #expect(try relaunched.openMailbox(id)["document"] is NSNull)

    // A legacy setup reason beside the saved mailbox meant Gmail needed authorizing again.
    var refused = try #require(try relaunched.load())
    refused.mailboxes = nil
    refused.mailbox = connection.receipt
    refused.mailboxCredential = connection.credential
    refused.mailboxSetupReason = "gmail-unavailable"
    try relaunched.save(refused)
    #expect(try relaunched.load()?.connections.first?.authorizationNeeded == true)
  }

  // A failure deleting cache files cannot restore removed credentials or make the host retain
  // plaintext. Relaunch retries the recorded cleanup before any provider access.
  @Test @MainActor func removedConnectionsStayClosedWhileCacheCleanupRetries() async throws {
    let service = "dev.unwired.product-sync.tests.\(UUID().uuidString)"
    let keys = DeviceKeychain(service: service)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let account = "account-synthetic-product-subject"
    defer {
      try? keys.remove("registration")
      try? keys.remove("product-sync." + account)
      try? keys.remove("product-sync-enrollment." + account)
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let backend = SyntheticProductSyncBackend()
    func store() -> RegistrationStore {
      RegistrationStore(
        keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
        provider: google, productSync: backend.backend,
        deviceRevoked: { product in backend.revoked.contains(product.trustedDeviceId) },
        mailCache: PrivateInboxStore(directory: directory, service: service),
        connect: { identity, device, _ in try backend.connect("account-" + identity.subject, device: device) })
    }
    let writer = store()
    _ = try await writer.signIn()
    _ = try await writer.authorizeGmail()
    let subject = "synthetic-product-subject"
    let id = MailboxConnection.id(subject: subject)
    _ = try writer.commitMailbox(
      connection: id, address: "same@example.invalid", expectedRevision: 0,
      document: "private cached mail", generation: writer.generation(subject))
    // A directory at the lock-file path makes opening it for read/write fail deterministically.
    let lock = directory.appendingPathComponent("store.lock")
    try FileManager.default.removeItem(at: lock)
    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
    // Another device removed it: synchronization purges the connection here.
    try await writer.purgeMailbox(id)
    let blocked = try writer.status()
    #expect(blocked["mailboxes"] == nil)
    #expect(blocked["privateSyncPending"] == "mailbox")
    #expect(try writer.load()?.connections.isEmpty == true)
    #expect(try writer.load()?.mailboxCacheRemovals == [id])
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("mailboxes/\(id)").path))
    #expect(throws: RegistrationError.gmailUnavailable) { _ = try writer.openMailbox(id) }
    try FileManager.default.removeItem(at: lock)
    let resumed = try await store().restore()
    #expect(resumed["mailboxes"] == nil)
    #expect(resumed["privateSyncPending"] == nil)
    #expect(try writer.load()?.mailboxCacheRemovals == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mailboxes/\(id)").path))
  }


  // Mailbox descriptor synchronization moved to TypeScript
  // (packages/mail-core/test/product-sync.test.ts). Each retired test names its replacement there:
  // - removalsReachProductSyncAndEveryTrustedDevice: "marks removals in Product Sync and purges
  //   connections another device removed"
  // - offlineAuthorizationAdoptsAnUnchangedDescriptor: "adopts only an unchanged descriptor after an
  //   offline authorization"

  // Bodies written before Mailbox Connections count toward the device-wide limit until adopted or
  // removed. How concurrent additions converge on one epoch moved to TypeScript: "converges
  // concurrent additions on the compare-and-set winner" in packages/mail-core/test/product-sync.test.ts.
  @Test func legacyBodiesCountTowardTheDeviceWideLimit() throws {
    let service = "dev.unwired.private-inbox.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    let cache = PrivateInboxStore(
      directory: directory, service: service, protectedDataAvailable: { true }, bodyLimit: 200)
    let legacy = MailboxConnection.id(subject: "synthetic-legacy-mailbox")
    let current = MailboxConnection.id(subject: "synthetic-current-mailbox")
    _ = try cache.commitMailbox(
      connection: legacy, address: "legacy@example.invalid", subject: "synthetic-legacy-mailbox",
      expectedRevision: 0, document: "{}")
    let text = String(repeating: "x", count: 120)
    #expect(
      try cache.commitMessageBody(
        connection: legacy, address: "legacy@example.invalid", subject: "synthetic-legacy-mailbox",
        id: "old", document: text, tier: .opened, protectedIds: []))
    // The legacy layout kept bodies at the root, outside every connection's directory.
    try FileManager.default.moveItem(
      at: directory.appendingPathComponent("mailboxes/\(legacy)/bodies"),
      to: directory.appendingPathComponent("bodies"))
    #expect(
      try cache.commitMessageBody(
        connection: current, address: "current@example.invalid",
        subject: "synthetic-current-mailbox", id: "new", document: text, tier: .opened,
        protectedIds: ["new"]))
    let remaining = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
      .map { directory.appendingPathComponent($0) }
      .filter { $0.path.contains("/bodies/") }
    #expect(remaining.count == 1)
    #expect(try remaining.reduce(0) { $0 + (try Data(contentsOf: $1).count) } <= 200)

    // Eviction leaves the legacy metadata (and its pending actions) adoptable. Moving the root
    // bodies folder cannot double-count it, and connection membership scans stay scoped.
    try FileManager.default.moveItem(
      at: directory.appendingPathComponent("mailboxes/\(legacy)/mailbox.enc"),
      to: directory.appendingPathComponent("mailbox.enc"))
    #expect(try cache.listMessageBodies(
      connection: legacy, address: "legacy@example.invalid", subject: "synthetic-legacy-mailbox",
      ids: ["old"]).stored.isEmpty)
    try cache.retainMessageBodies(
      connection: current, address: "current@example.invalid", subject: "synthetic-current-mailbox",
      expectedRevision: 0, ids: ["new"], protectedIds: ["new"])
    let legacyCache = try cache.openMailbox(
      connection: legacy, address: "legacy@example.invalid", subject: "synthetic-legacy-mailbox")
    #expect(legacyCache["revision"] as? Int == 1)
    #expect(legacyCache["document"] as? String == "{}")
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("bodies").path))
    #expect(try cache.openMessageBody(
      connection: current, address: "current@example.invalid", subject: "synthetic-current-mailbox",
      id: "new") == text)
    #expect(try cache.commitMessageBody(
      connection: legacy, address: "legacy@example.invalid", subject: "synthetic-legacy-mailbox",
      id: "adopted", document: text, tier: .opened, protectedIds: ["adopted"]))
    #expect(try cache.openMessageBody(
      connection: current, address: "current@example.invalid", subject: "synthetic-current-mailbox",
      id: "new") == nil)
  }

  // Legacy adoption keeps bodies already saved for the connection. How connections from before
  // epochs converge and stay fenced moved to TypeScript: "converges connections from before epochs
  // on the legacy epoch and fences later incarnations" in packages/mail-core/test/product-sync.test.ts.
  @Test func legacyAdoptionKeepsBodiesSavedBesideTheConnection() throws {
    let service = "dev.unwired.private-inbox.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    // A body saved for the connection before its legacy cache is adopted stays beside it.
    let cache = PrivateInboxStore(directory: directory, service: service)
    let id = MailboxConnection.id(subject: "synthetic-legacy-mailbox")
    _ = try cache.commitMailbox(
      connection: id, address: "legacy@example.invalid", subject: "synthetic-legacy-mailbox",
      expectedRevision: 0, document: "legacy document")
    _ = try cache.commitMessageBody(
      connection: id, address: "legacy@example.invalid", subject: "synthetic-legacy-mailbox",
      id: "old", document: "legacy body", tier: .opened, protectedIds: [])
    let collisions: [(String, PrivateInboxStore.BodyTier, PrivateInboxStore.BodyTier)] = [
      ("same-tier", .opened, .opened), ("opened-to-prefetched", .opened, .prefetched),
      ("prefetched-to-opened", .prefetched, .opened),
    ]
    for (message, legacyTier, _) in collisions {
      #expect(try cache.commitMessageBody(
        connection: id, address: "legacy@example.invalid", subject: "synthetic-legacy-mailbox",
        id: message, document: "old collision", tier: legacyTier, protectedIds: []))
    }
    let folder = directory.appendingPathComponent("mailboxes/\(id)")
    try FileManager.default.moveItem(
      at: folder.appendingPathComponent("mailbox.enc"),
      to: directory.appendingPathComponent("mailbox.enc"))
    try FileManager.default.moveItem(
      at: folder.appendingPathComponent("bodies"), to: directory.appendingPathComponent("bodies"))
    _ = try cache.commitMessageBody(
      connection: id, address: "legacy@example.invalid", subject: "synthetic-legacy-mailbox",
      id: "new", document: "new body", tier: .opened, protectedIds: [])
    for (message, _, destinationTier) in collisions {
      #expect(try cache.commitMessageBody(
        connection: id, address: "legacy@example.invalid", subject: "synthetic-legacy-mailbox",
        id: message, document: "destination body", tier: destinationTier, protectedIds: []))
    }
    #expect(
      try cache.openMailbox(
        connection: id, address: "legacy@example.invalid",
        subject: "synthetic-legacy-mailbox")["document"] as? String == "legacy document")
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("bodies").path))
    for (message, body) in [("old", "legacy body"), ("new", "new body")] {
      #expect(
        try cache.openMessageBody(
          connection: id, address: "legacy@example.invalid", subject: "synthetic-legacy-mailbox",
          id: message) == body)
    }
    for (message, _, _) in collisions {
      #expect(try cache.openMessageBody(
        connection: id, address: "legacy@example.invalid", subject: "synthetic-legacy-mailbox",
        id: message) == "destination body")
    }
    #expect(try FileManager.default.contentsOfDirectory(
      at: folder.appendingPathComponent("bodies"), includingPropertiesForKeys: nil).count == 5)
  }
}
