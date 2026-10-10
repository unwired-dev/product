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

  // Removal marks the connection's synchronized descriptor removed. Every Trusted Device then
  // purges that connection's credential and cache, including an authorization from before a
  // removal and a later addition; adding the mailbox again starts a new epoch.
  @Test @MainActor func removalsReachProductSyncAndEveryTrustedDevice() async throws {
    let keys = DeviceKeychain(service: "dev.unwired.product-sync.tests.\(UUID().uuidString)")
    let account = "account-synthetic-product-subject"
    defer {
      try? keys.remove("registration")
      try? keys.remove("product-sync." + account)
      try? keys.remove("product-sync-enrollment." + account)
    }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let backend = SyntheticProductSyncBackend()
    let registration = backend.store(keys: keys, google: google)
    func store() -> RegistrationStore { registration }
    _ = try await store().signIn()
    let added = try await store().authorizeGmail()
    #expect(added["privateSyncMailboxes"] == "same@example.invalid")
    let ring = try #require(try store().loadVault(account)).ring
    let subject = "synthetic-product-subject"
    let identifier = try ring.identifier("mailbox", "gmail:" + subject)
    func descriptor() throws -> MailboxDescriptor? {
      guard let record = backend.records[account]?[identifier] else { return nil }
      return try JSONDecoder().decode(
        MailboxDescriptor.self,
        from: ring.open(
          record: record.encryptedPayload, account: account, identifier: identifier,
          schemaVersion: MailboxDescriptor.schemaVersion))
    }
    func put(_ value: MailboxDescriptor) throws {
      let sealed = try ring.seal(
        record: JSONEncoder().encode(value), account: account, identifier: identifier,
        schemaVersion: MailboxDescriptor.schemaVersion)
      backend.records[account, default: [:]][identifier] = StoredPayload(
        payloadIdentifier: identifier, encryptedPayload: sealed,
        updatedAt: (backend.records[account]?[identifier]?.updatedAt ?? 0) + 1)
    }
    let published = try #require(try descriptor())
    #expect(published.removed == nil)
    #expect(published.epoch != nil)
    #expect(try store().load()?.connections.first?.published == true)

    // Removal marks the descriptor removed; credentials and mail never reach Product Sync.
    let removed = try await store().flowRemoveMailbox(MailboxConnection.id(subject: subject))
    #expect(removed["kind"] == "mailbox-needed")
    #expect(removed["mailboxes"] == nil)
    #expect(removed["privateSyncMailboxes"] == nil)
    #expect(
      try descriptor()
        == MailboxDescriptor(
          provider: "gmail", address: "same@example.invalid", epoch: published.epoch,
          removed: true))
    #expect(try store().load()?.mailboxRemovals == nil)

    // Adding the mailbox again starts a new epoch.
    let readded = try await store().authorizeGmail()
    #expect(readded["privateSyncMailboxes"] == "same@example.invalid")
    let renewed = try #require(try descriptor())
    #expect(renewed.removed == nil)
    #expect(renewed.epoch != published.epoch)

    // Another device removes it: this device purges the connection on its next synchronization.
    try put(
      MailboxDescriptor(
        provider: "gmail", address: "same@example.invalid", epoch: renewed.epoch, removed: true))
    let purged = try await store().restore()
    #expect(purged["kind"] == "mailbox-needed")
    #expect(purged["mailboxes"] == nil)
    #expect(try store().load()?.connections.isEmpty == true)

    // An authorization from before a removal and another device's addition is purged too.
    _ = try await store().authorizeGmail()
    try put(
      MailboxDescriptor(
        provider: "gmail", address: "same@example.invalid", epoch: "added-on-another-device"))
    #expect(try await store().restore()["mailboxes"] == nil)
    // Authorizing a mailbox another device already published adopts that device's epoch.
    #expect(try await store().authorizeGmail()["kind"] == "connected")
    #expect(try store().load()?.connections.first?.epoch == "added-on-another-device")
    #expect(try store().load()?.connections.first?.published == true)
    #expect(try descriptor()?.epoch == "added-on-another-device")

    // Removing while offline and adding back cannot inherit the pre-removal epoch.
    backend.offline = true
    let id = MailboxConnection.id(subject: subject)
    _ = try await store().flowRemoveMailbox(id)
    _ = try await store().authorizeGmail()
    #expect(try store().load()?.mailboxRemovals?.count == 1)
    backend.offline = false
    _ = try await store().restore()
    let recreated = try #require(try descriptor())
    #expect(recreated.epoch != "added-on-another-device")
    #expect(recreated.removed != true)
    #expect(try store().load()?.connections.first?.epoch == recreated.epoch)
    let shown = try JSONDecoder().decode(
      [[String: String]].self, from: Data(try #require(try await store().restore()["mailboxes"]).utf8))
    #expect(shown.first?["epoch"] == recreated.epoch)
    #expect(try store().load()?.mailboxRemovals == nil)

    // A newer unreadable descriptor is read-only, but cannot acknowledge a removal.
    let newer = try ring.seal(
      record: JSONEncoder().encode(recreated), account: account, identifier: identifier,
      schemaVersion: MailboxDescriptor.schemaVersion + 1)
    backend.records[account]?[identifier] = StoredPayload(
      payloadIdentifier: identifier, encryptedPayload: newer, updatedAt: 100)
    let waiting = try await store().flowRemoveMailbox(id)
    #expect(waiting["privateSyncPending"] == "mailbox")
    #expect(try store().load()?.mailboxRemovals?.count == 1)
    #expect(backend.records[account]?[identifier]?.encryptedPayload == newer)
    // When it becomes readable, the retained removal publishes the matching tombstone.
    try put(recreated)
    _ = try await store().refreshPrivateSync()
    #expect(try descriptor()?.removed == true)
    #expect(try store().load()?.mailboxRemovals == nil)

    // An absent descriptor also needs a tombstone; absence never acknowledges publication.
    _ = try await store().authorizeGmail()
    backend.records[account]?.removeValue(forKey: identifier)
    _ = try await store().flowRemoveMailbox(id)
    #expect(try descriptor()?.removed == true)
    #expect(try store().load()?.mailboxRemovals == nil)

    // An offline authorization cannot resurrect a removal during ordinary restore.
    backend.offline = true
    _ = try await store().authorizeGmail()
    #expect(try store().load()?.connections.count == 1)
    backend.offline = false
    #expect(try await store().restore()["mailboxes"] == nil)
    #expect(try store().load()?.connections.isEmpty == true)
    // Fresh explicit consent after learning the tombstone can recreate it.
    #expect(try await store().authorizeGmail()["kind"] == "connected")
    #expect(try descriptor()?.removed != true)
    _ = try await store().flowRemoveMailbox(id)
    backend.offline = true
    _ = try await store().authorizeGmail()
    try put(MailboxDescriptor(
      provider: "gmail", address: "same@example.invalid", epoch: "another-device-recreated"))
    backend.offline = false
    // A later live incarnation also cannot inherit the earlier unpublished authorization.
    #expect(try await store().restore()["mailboxes"] == nil)
    #expect(try await store().authorizeGmail()["kind"] == "connected")
    #expect(try store().load()?.connections.first?.epoch == "another-device-recreated")
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
    let ring = try #require(try writer.loadVault(account)).ring
    let identifier = try ring.identifier("mailbox", "gmail:" + subject)
    let connection = try #require(try writer.load()?.connections.first)
    let removed = MailboxDescriptor(
      provider: "gmail", address: connection.receipt.address, epoch: connection.epoch, removed: true)
    backend.records[account]?[identifier] = StoredPayload(
      payloadIdentifier: identifier,
      encryptedPayload: try ring.seal(
        record: JSONEncoder().encode(removed), account: account, identifier: identifier,
        schemaVersion: MailboxDescriptor.schemaVersion), updatedAt: 100)
    // A directory at the lock-file path makes opening it for read/write fail deterministically.
    let lock = directory.appendingPathComponent("store.lock")
    try FileManager.default.removeItem(at: lock)
    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
    let blocked = try await store().restore()
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


  // Two devices adding the same mailbox at once converge on one epoch: the device whose descriptor
  // write loses adopts the winner's epoch and keeps its connection across relaunch. Bodies written
  // before Mailbox Connections count toward the device-wide limit until adopted or removed.
  @Test @MainActor func concurrentAdditionsConvergeAndLegacyBodiesCountTowardTheLimit()
    async throws
  {
    let keys = DeviceKeychain(service: "dev.unwired.product-sync.tests.\(UUID().uuidString)")
    let account = "account-synthetic-product-subject"
    let service = "dev.unwired.private-inbox.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
    defer {
      backend.beforePut = nil
      backend.beforeList = nil
    }
    let registration = backend.store(keys: keys, google: google)
    func store() -> RegistrationStore { registration }
    _ = try await store().signIn()
    let ring = try #require(try store().loadVault(account)).ring
    let identifier = try ring.identifier("mailbox", "gmail:synthetic-product-subject")
    let id = MailboxConnection.id(subject: "synthetic-product-subject")
    func put(_ epoch: String, removed: Bool = false) throws {
      let sealed = try ring.seal(
        record: JSONEncoder().encode(
          MailboxDescriptor(
            provider: "gmail", address: "same@example.invalid", epoch: epoch,
            removed: removed ? true : nil)),
        account: account, identifier: identifier, schemaVersion: MailboxDescriptor.schemaVersion)
      backend.clock += 1
      backend.records[account, default: [:]][identifier] = StoredPayload(
        payloadIdentifier: identifier, encryptedPayload: sealed, updatedAt: backend.clock)
    }
    // Another device publishes the same mailbox between this device's read and its write.
    backend.beforePut = { _, written in
      guard written == identifier else { return }
      backend.beforePut = nil
      try put("added-on-another-device")
    }
    #expect(try await store().authorizeGmail()["kind"] == "connected")
    let adopted = try #require(try store().load()?.connections.first)
    #expect(adopted.epoch == "added-on-another-device")
    #expect(adopted.published == true)
    // A relaunch does not read the winning epoch as a removal and recreation.
    let relaunched = try await backend.store(keys: keys, google: google).restore()
    #expect(relaunched["kind"] == "connected")
    #expect(try store().load()?.connections.map(\.epoch) == ["added-on-another-device"])

    // Competing fresh recreations of the same tombstone converge too. Losing the later list
    // cannot discard the CAS winner that this device already confirmed and saved.
    _ = try await store().flowRemoveMailbox(id)
    backend.beforePut = { _, written in
      guard written == identifier else { return }
      backend.beforePut = nil
      try put("concurrent-recreation")
      backend.beforeList = { _, _ in
        backend.beforeList = nil
        throw RegistrationError.unavailable
      }
    }
    _ = try await store().authorizeGmail()
    #expect(try store().load()?.connections.first?.epoch == "concurrent-recreation")
    #expect(try store().load()?.connections.first?.published == true)
    #expect(try await backend.store(keys: keys, google: google).restore()["kind"] == "connected")

    // The durable remove/re-add intent remains eligible after relaunch, but only for the
    // tombstone it names. A concurrent recreation winning that CAS supplies the new epoch.
    backend.offline = true
    _ = try await store().flowRemoveMailbox(id)
    _ = try await store().authorizeGmail()
    backend.offline = false
    var writes = 0
    backend.beforePut = { _, written in
      guard written == identifier else { return }
      writes += 1
      if writes == 2 {
        backend.beforePut = nil
        try put("concurrent-retained-recreation")
      }
    }
    #expect(try await backend.store(keys: keys, google: google).restore()["kind"] == "connected")
    #expect(try store().load()?.connections.first?.epoch == "concurrent-retained-recreation")
    #expect(try store().load()?.mailboxRemovals == nil)

    // An offline grant encountering absence may attempt publication on restore. It cannot
    // inherit a later incarnation that another device publishes before that CAS.
    _ = try await store().flowRemoveMailbox(id)
    backend.records[account]?.removeValue(forKey: identifier)
    backend.offline = true
    _ = try await store().authorizeGmail()
    backend.offline = false
    backend.beforePut = { _, written in
      guard written == identifier else { return }
      backend.beforePut = nil
      try put("offline-grant-was-removed", removed: true)
      try put("later-incarnation")
    }
    #expect(try await store().restore()["mailboxes"] == nil)
    #expect(try store().load()?.connections.isEmpty == true)

    // A tombstone winning a fresh addition's CAS is authoritative removal, not consent.
    backend.records[account]?.removeValue(forKey: identifier)
    backend.beforePut = { _, written in
      guard written == identifier else { return }
      backend.beforePut = nil
      try put("removal-winner", removed: true)
    }
    #expect(try await store().authorizeGmail()["mailboxes"] == nil)
    #expect(try store().load()?.connections.isEmpty == true)

    // A successful addition can be removed/recreated before read-back. The later list must
    // not extend the grant bound to the successful CAS's epoch to that newer incarnation.
    backend.beforePut = { _, written in
      guard written == identifier else { return }
      backend.beforePut = nil
      backend.beforeList = { _, _ in
        backend.beforeList = nil
        let epoch = try #require(try store().load()?.connections.first?.epoch)
        try put(epoch, removed: true)
        try put("recreated-after-success")
      }
    }
    #expect(try await store().authorizeGmail()["mailboxes"] == nil)
    #expect(try store().load()?.connections.isEmpty == true)

    // An address update's losing CAS cannot move an already-published grant to a new epoch.
    _ = try await store().authorizeGmail()
    var renamed = try #require(try store().load())
    renamed.update(id) { $0.receipt = GmailRegistrationReceipt(
      subject: "synthetic-product-subject", address: "renamed@example.invalid") }
    try store().save(renamed)
    backend.beforePut = { _, written in
      guard written == identifier else { return }
      backend.beforePut = nil
      try put("recreated-during-address-update")
      // The CAS already proved removal; a later unavailable list cannot preserve that grant.
      backend.beforeList = { _, _ in
        backend.beforeList = nil
        throw RegistrationError.unavailable
      }
    }
    #expect(try await store().refreshPrivateSync()["mailboxes"] == nil)
    #expect(try store().load()?.connections.isEmpty == true)

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

  // A mailbox another device published is authorized here while Product Sync is unreachable.
  // Restoring against that unchanged descriptor adopts it rather than purging the new grant, while
  // a descriptor that changed since this device last read it still fences the grant.
  @Test @MainActor func offlineAuthorizationAdoptsAnUnchangedDescriptor() async throws {
    let keys = DeviceKeychain(service: "dev.unwired.product-sync.tests.\(UUID().uuidString)")
    let account = "account-synthetic-product-subject"
    defer {
      try? keys.remove("registration")
      try? keys.remove("product-sync." + account)
      try? keys.remove("product-sync-enrollment." + account)
    }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    google.mailboxAddresses = [
      "synthetic-other-mailbox": "other@example.invalid",
      "synthetic-third-mailbox": "third@example.invalid",
      "synthetic-unobserved-mailbox": "unobserved@example.invalid",
      "synthetic-failing-mailbox": "failing@example.invalid",
    ]
    let backend = SyntheticProductSyncBackend()
    func store() -> RegistrationStore { backend.store(keys: keys, google: google) }
    _ = try await store().signIn()
    _ = try await store().authorizeGmail()
    let ring = try #require(try store().loadVault(account)).ring
    // Another device's descriptors, read once by this device.
    func publish(_ subject: String, _ address: String, epoch: String) throws {
      let identifier = try ring.identifier("mailbox", "gmail:" + subject)
      let sealed = try ring.seal(
        record: JSONEncoder().encode(
          MailboxDescriptor(provider: "gmail", address: address, epoch: epoch)),
        account: account, identifier: identifier, schemaVersion: MailboxDescriptor.schemaVersion)
      backend.clock += 1
      backend.records[account, default: [:]][identifier] = StoredPayload(
        payloadIdentifier: identifier, encryptedPayload: sealed, updatedAt: backend.clock)
    }
    try publish("synthetic-other-mailbox", "other@example.invalid", epoch: "published-elsewhere")
    try publish("synthetic-third-mailbox", "third@example.invalid", epoch: "first-incarnation")
    _ = try await store().restore()
    // Both are authorized here offline; meanwhile the third is removed and added again elsewhere.
    backend.offline = true
    for subject in [
      "synthetic-other-mailbox", "synthetic-third-mailbox", "synthetic-unobserved-mailbox",
      "synthetic-failing-mailbox",
    ] {
      google.subject = subject
      _ = try await store().authorizeGmail(chooseAccount: true)
    }
    google.subject = "synthetic-product-subject"
    #expect(try store().load()?.connections.count == 5)
    backend.offline = false
    try publish("synthetic-third-mailbox", "third@example.invalid", epoch: "second-incarnation")
    // Absence in the earlier snapshot is not evidence that an unseen add/remove/re-add did
    // not happen while this grant was offline. Only the known unchanged epoch can be adopted.
    try publish("synthetic-unobserved-mailbox", "unobserved@example.invalid", epoch: "later-incarnation")
    let failing = try ring.identifier("mailbox", "gmail:synthetic-failing-mailbox")
    backend.beforePut = { _, identifier in
      if identifier == failing { throw RegistrationError.unavailable }
    }
    defer { backend.beforePut = nil }
    // A later connection's failed publication cannot undo a removal already learned above.
    _ = try await store().restore()
    let afterFailure = try #require(try store().load()?.connections)
    #expect(!afterFailure.contains { $0.receipt.subject == "synthetic-third-mailbox" })
    #expect(!afterFailure.contains { $0.receipt.subject == "synthetic-unobserved-mailbox" })
    backend.beforePut = nil
    #expect(try await store().restore()["kind"] == "connected")
    let connections = try #require(try store().load()?.connections)
    let other = try #require(connections.first { $0.receipt.subject == "synthetic-other-mailbox" })
    #expect(other.epoch == "published-elsewhere")
    #expect(other.published == true)
    #expect(!connections.contains { $0.receipt.subject == "synthetic-third-mailbox" })
    #expect(!connections.contains { $0.receipt.subject == "synthetic-unobserved-mailbox" })
  }

  // Connections and descriptors from before epochs converge on one legacy epoch, so upgrades by
  // different devices agree, while a connection from before epochs never inherits a mailbox that
  // was removed and added again. Legacy adoption keeps bodies already saved for the connection.
  @Test @MainActor func legacyConnectionsConvergeOnOneEpochAndStayFenced() async throws {
    let keys = DeviceKeychain(service: "dev.unwired.product-sync.tests.\(UUID().uuidString)")
    let account = "account-synthetic-product-subject"
    let service = "dev.unwired.private-inbox.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
    func store() -> RegistrationStore { backend.store(keys: keys, google: google) }
    _ = try await store().signIn()
    _ = try await store().authorizeGmail()
    let ring = try #require(try store().loadVault(account)).ring
    let identifier = try ring.identifier("mailbox", "gmail:synthetic-product-subject")
    func put(epoch: String?, removed: Bool = false) throws {
      let sealed = try ring.seal(
        record: JSONEncoder().encode(
          MailboxDescriptor(
            provider: "gmail", address: "same@example.invalid", epoch: epoch,
            removed: removed ? true : nil)),
        account: account, identifier: identifier, schemaVersion: MailboxDescriptor.schemaVersion)
      backend.clock += 1
      backend.records[account, default: [:]][identifier] = StoredPayload(
        payloadIdentifier: identifier, encryptedPayload: sealed, updatedAt: backend.clock)
    }
    func descriptorEpoch() throws -> String? {
      let record = try #require(backend.records[account]?[identifier])
      return try JSONDecoder().decode(
        MailboxDescriptor.self,
        from: ring.open(
          record: record.encryptedPayload, account: account, identifier: identifier,
          schemaVersion: MailboxDescriptor.schemaVersion)
      ).epoch
    }
    // This device's connection and its descriptor as a build from before epochs left them.
    func makeLegacy() throws {
      var saved = try #require(try store().load())
      saved.update(MailboxConnection.id(subject: "synthetic-product-subject")) {
        $0.epoch = nil
        $0.published = nil
        $0.observed = nil
        $0.observedEpoch = nil
      }
      try store().save(saved)
    }
    try makeLegacy()
    try put(epoch: nil)
    // A concurrent legacy upgrade wins the CAS; both devices still choose the same incarnation.
    backend.beforePut = { _, written in
      guard written == identifier else { return }
      backend.beforePut = nil
      try put(epoch: RegistrationStore.legacyMailboxEpoch)
    }
    defer { backend.beforePut = nil }
    #expect(try await store().restore()["kind"] == "connected")
    #expect(try store().load()?.connections.first?.epoch == RegistrationStore.legacyMailboxEpoch)
    #expect(try descriptorEpoch() == RegistrationStore.legacyMailboxEpoch)
    // Another device from before epochs reads the upgraded descriptor as its own incarnation.
    try makeLegacy()
    #expect(try await store().restore()["kind"] == "connected")
    #expect(try store().load()?.connections.first?.epoch == RegistrationStore.legacyMailboxEpoch)
    // A device authorizing the pre-epoch mailbox for the first time must not give it a UUID
    // that would make the existing legacy devices lose their valid grant on the next restore.
    var freshDevice = try #require(try store().load())
    freshDevice.connections = []
    try store().save(freshDevice)
    try put(epoch: nil)
    #expect(try await store().authorizeGmail()["kind"] == "connected")
    #expect(try descriptorEpoch() == RegistrationStore.legacyMailboxEpoch)
    try makeLegacy()
    #expect(try await store().restore()["kind"] == "connected")
    // A mailbox removed and added again elsewhere is not carried over from before epochs.
    try makeLegacy()
    try put(epoch: "added-again-elsewhere")
    #expect(try await store().restore()["mailboxes"] == nil)
    #expect(try store().load()?.connections.isEmpty == true)

    // A queued removal of the pre-epoch incarnation cannot remove a newer remote incarnation.
    _ = try await store().authorizeGmail()
    try makeLegacy()
    try put(epoch: nil)
    backend.offline = true
    let mailbox = MailboxConnection.id(subject: "synthetic-product-subject")
    _ = try await store().flowRemoveMailbox(mailbox)
    try put(epoch: "newer-than-legacy-removal")
    backend.offline = false
    _ = try await store().restore()
    #expect(try descriptorEpoch() == "newer-than-legacy-removal")
    #expect(try store().load()?.mailboxRemovals == nil)
    // The remote live mailbox stays visible; it has not been tombstoned by the legacy removal.
    #expect(try await store().restore()["privateSyncMailboxes"] == "same@example.invalid")

    // Retained explicit offline recreation still matches its removal after another legacy upgrade.
    _ = try await store().authorizeGmail()
    try makeLegacy()
    try put(epoch: nil)
    backend.offline = true
    let recreating = store()
    _ = try await recreating.flowRemoveMailbox(mailbox)
    _ = try await recreating.authorizeGmail()
    let recreatedEpoch = try #require(try store().load()?.connections.first?.epoch)
    try put(epoch: RegistrationStore.legacyMailboxEpoch)
    backend.offline = false
    #expect(try await store().restore()["kind"] == "connected")
    #expect(try store().load()?.connections.first?.epoch == recreatedEpoch)
    #expect(try descriptorEpoch() == recreatedEpoch)
    #expect(try store().load()?.mailboxRemovals == nil)
    // A legacy tombstone purges ordinary restore; explicit consent recreates it at a fresh epoch.
    try makeLegacy()
    try put(epoch: RegistrationStore.legacyMailboxEpoch, removed: true)
    #expect(try await store().restore()["mailboxes"] == nil)
    #expect(try await store().authorizeGmail()["kind"] == "connected")
    #expect(try descriptorEpoch() != RegistrationStore.legacyMailboxEpoch)

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
