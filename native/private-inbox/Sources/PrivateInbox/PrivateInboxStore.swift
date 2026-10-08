import CryptoKit
import Darwin
import Foundation

#if os(iOS)
  import UIKit
#endif

struct StoredMessage: Codable {
  let id: String
  let sender: String
  let address: String
  let subject: String
  let preview: String
  let body: String
  let receivedAt: String
  var unread: Bool
}

struct InboxSnapshot: Codable {
  let version: Int
  var revision: Int
  var messages: [StoredMessage]
}

// One Mailbox Connection's cache. Its document is TypeScript's; native keeps it encrypted, for one
// mailbox address, and replaces it only from the revision the caller read.
struct MailboxCache: Codable {
  let revision: Int
  let address: String
  // The Google account behind the address, which a recycled address does not share.
  let subject: String?
  let document: String
}

// Mailbox body work runs off the main actor: state is immutable and every transaction holds the
// store's file lock, which also serializes threads within this process.
public final class PrivateInboxStore: @unchecked Sendable {
  private let directory: URL
  // Downloaded Attachments, in plaintext so the system can preview or share them: one directory
  // per connection outside backups, cleared with the connection's cache and at launch.
  private let attachments: URL
  private let keychain: DeviceKeychain
  private let protectedDataAvailable: @Sendable () -> Bool
  // The Bounded Encrypted Body Cache's device-wide limit, in stored bytes.
  private let bodyLimit: Int
  private let attachmentLimit: Int
  private let associatedData = Data("dev.unwired.private-inbox.v1".utf8)
  private let mailboxAssociatedData = Data("dev.unwired.private-inbox.mailbox.v1".utf8)

  public convenience init(directory: URL, service: String, attachments: URL? = nil) {
    self.init(
      directory: directory, service: service, attachments: attachments,
      protectedDataAvailable: Self.protectedDataAvailability())
  }

  init(
    directory: URL, service: String, attachments: URL? = nil,
    protectedDataAvailable: @escaping @Sendable () -> Bool,
    bodyLimit: Int = 500 * 1024 * 1024, attachmentLimit: Int = 250 * 1024 * 1024
  ) {
    self.directory = directory
    self.attachments = attachments ?? directory.appendingPathComponent("attachments")
    self.bodyLimit = bodyLimit
    self.attachmentLimit = attachmentLimit
    keychain = DeviceKeychain(service: service + ".database")
    self.protectedDataAvailable = protectedDataAvailable
  }

  private static func protectedDataAvailability() -> @Sendable () -> Bool {
    #if os(iOS)
      let application: UIApplication
      if Thread.isMainThread {
        application = MainActor.assumeIsolated { UIApplication.shared }
      } else {
        application = DispatchQueue.main.sync {
          MainActor.assumeIsolated { UIApplication.shared }
        }
      }
      // UIKit answers only on the main thread. Callers that move store work off it check
      // availability there before and after the work.
      return {
        Thread.isMainThread
          ? MainActor.assumeIsolated { application.isProtectedDataAvailable } : true
      }
    #else
      return { true }
    #endif
  }

  func isProtectedDataAvailable() -> Bool { protectedDataAvailable() }

  private func requireProtectedData() throws {
    guard protectedDataAvailable() else { throw PrivateInboxError.locked }
  }

  public func open(seed: String) throws -> String {
    try transaction {
      let availableKey = try keychain.read("encryption-key")
      let file = directory.appendingPathComponent("inbox.enc")
      let encrypted: Data
      do {
        encrypted = try Data(contentsOf: file)
      } catch CocoaError.fileReadNoSuchFile {
        try requireProtectedData()
        let messages = try JSONDecoder().decode([StoredMessage].self, from: Data(seed.utf8))
        let snapshot = InboxSnapshot(version: 1, revision: 0, messages: messages)
        try validate(snapshot)
        let key: Data
        if let existing = availableKey {
          key = existing
        } else {
          key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
          try keychain.insert(key, account: "encryption-key")
        }
        try save(snapshot, key: key)
        return try encode(snapshot)
      }
      // A missing key never returns on unlock; a locked device fails the transaction's check.
      guard let key = availableKey, key.count == 32 else { throw PrivateInboxError.unavailable }
      return try encode(decrypt(encrypted, key: key))
    }
  }

  public func setUnread(id: String, unread: Bool) throws -> String {
    try transaction {
      let key = try existingKey()
      let data = try Data(contentsOf: directory.appendingPathComponent("inbox.enc"))
      var snapshot = try decrypt(data, key: key)
      guard let index = snapshot.messages.firstIndex(where: { $0.id == id }) else {
        throw PrivateInboxError.invalidStore
      }
      snapshot.messages[index].unread = unread
      snapshot.revision += 1
      try save(snapshot, key: key)
      return try encode(snapshot)
    }
  }

  // Each connection keeps its cache and bodies in its own directory, named by its opaque ID.
  private func connectionPath(_ connection: String, _ name: String) throws -> String {
    guard connection.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
      throw PrivateInboxError.invalidStore
    }
    return "mailboxes/\(connection)/\(name)"
  }

  // The single cache written before Mailbox Connections moves to the connection it belongs to,
  // with its bodies, so its pending changes survive. Another mailbox's legacy cache stays until
  // the account's caches are removed.
  private func adoptLegacyMailbox(connection: String, address: String, subject: String) throws {
    let manager = FileManager.default
    let legacy = directory.appendingPathComponent("mailbox.enc")
    guard manager.fileExists(atPath: legacy.path),
      !manager.fileExists(atPath: directory.appendingPathComponent(
        try connectionPath(connection, "mailbox.enc")).path),
      // An unreadable legacy cache is left alone rather than blocking this connection.
      let cache = (try? readMailbox(file: "mailbox.enc")) ?? nil,
      cache.address == address, cache.subject == subject
    else { return }
    let target = directory.appendingPathComponent(try connectionPath(connection, ""))
    try manager.createDirectory(
      at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let bodies = directory.appendingPathComponent("bodies")
    let targetBodies = target.appendingPathComponent("bodies")
    if manager.fileExists(atPath: bodies.path) {
      if manager.fileExists(atPath: targetBodies.path) {
        // A saved body wins across both tiers; adoption must not restore an older opened copy.
        var savedBodies = Set(try manager.contentsOfDirectory(
          at: targetBodies, includingPropertiesForKeys: nil
        ).map { $0.deletingPathExtension().lastPathComponent })
        for file in try manager.contentsOfDirectory(at: bodies, includingPropertiesForKeys: nil) {
          let destination = targetBodies.appendingPathComponent(file.lastPathComponent)
          let name = file.deletingPathExtension().lastPathComponent
          if savedBodies.contains(name) {
            try manager.removeItem(at: file)
          } else {
            try manager.moveItem(at: file, to: destination)
            savedBodies.insert(name)
          }
        }
        try manager.removeItem(at: bodies)
      } else {
        try manager.moveItem(at: bodies, to: targetBodies)
      }
    }
    try manager.moveItem(at: legacy, to: target.appendingPathComponent("mailbox.enc"))
  }

  // Another mailbox's cache, including another Google account at the same address, reads as
  // empty; its first commit replaces it. Cache replies do not include the subject.
  public func openMailbox(connection: String, address: String, subject: String) throws
    -> [String: Any]
  {
    try transaction {
      try adoptLegacyMailbox(connection: connection, address: address, subject: subject)
      let cache = try readMailbox(file: try connectionPath(connection, "mailbox.enc"))
      let owned = cache.flatMap { $0.address == address && $0.subject == subject ? $0 : nil }
      return [
        "revision": cache?.revision ?? 0, "address": address,
        "document": owned?.document ?? NSNull(),
      ]
    }
  }

  public func commitMailbox(
    connection: String, address: String, subject: String, expectedRevision: Int, document: String
  ) throws -> [String: Any] {
    try transaction {
      try adoptLegacyMailbox(connection: connection, address: address, subject: subject)
      let file = try connectionPath(connection, "mailbox.enc")
      let cache = try readMailbox(file: file)
      guard (cache?.revision ?? 0) == expectedRevision else { throw PrivateInboxError.conflict }
      let key: Data
      if cache != nil {
        key = try existingKey()
      } else if let existing = try keychain.read("encryption-key") {
        key = existing
      } else {
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("inbox.enc").path)
        else { throw PrivateInboxError.unavailable }
        key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try keychain.insert(key, account: "encryption-key")
      }
      let next = MailboxCache(
        revision: expectedRevision + 1, address: address, subject: subject, document: document)
      try FileManager.default.createDirectory(
        at: directory.appendingPathComponent(try connectionPath(connection, "")),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try write(
        JSONEncoder().encode(next), file: file, key: key, authenticating: mailboxAssociatedData)
      return ["revision": next.revision, "address": address, "document": document]
    }
  }

  // Needs no key, so a locked device can still forget a connection's cache, bodies and
  // Downloaded Attachments.
  public func removeMailbox(connection: String, includingLegacy: Bool = false) throws {
    let path = try connectionPath(connection, "")
    try unlockedTransaction {
      try removeURLs(
        ([path] + (includingLegacy ? ["mailbox.enc", "bodies"] : [])).map {
          directory.appendingPathComponent($0)
        } + [try attachmentURL(connection)])
    }
  }

  // Every connection's cache, bodies and Downloaded Attachments, including the cache written
  // before connections.
  public func removeMailboxes() throws {
    try unlockedTransaction {
      try removeURLs(
        ["mailboxes", "mailbox.enc", "bodies"].map {
          directory.appendingPathComponent($0)
        } + [attachments])
    }
  }

  // Downloaded Attachments left by an earlier process have no owner; launch removes them.
  public func removeAttachments() throws {
    try unlockedTransaction { try removeAttachmentItem(attachments) }
  }

  private func removeAttachmentItem(_ url: URL) throws {
    do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
  }

  private func attachmentURL(_ connection: String, _ file: String? = nil) throws -> URL {
    _ = try connectionPath(connection, "")
    let folder = attachments.appendingPathComponent(connection)
    guard let file else { return folder }
    guard UUID(uuidString: file)?.uuidString == file else { throw PrivateInboxError.invalidStore }
    return folder.appendingPathComponent(file)
  }

  // Writes an attachment whose base64url data decodes to exactly `size` bytes under a name that
  // cannot leave its own directory, and returns the file's opaque name.
  public func saveAttachment(
    connection: String, name: String, data: String, size: Int, protectedFiles: Set<String> = []
  ) throws -> String
  {
    guard size >= 0, size <= 25 * 1024 * 1024,
      data.utf8.count <= 4 * ((size + 2) / 3)
    else { throw PrivateInboxError.unavailable }
    var base64 = data.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let bytes = Data(base64Encoded: base64), bytes.count == size else {
      throw PrivateInboxError.unavailable
    }
    let file = UUID().uuidString
    let folder = try attachmentURL(connection, file)
    let safe = Self.attachmentName(name)
    return try transaction {
      guard size <= attachmentLimit else { throw PrivateInboxError.unavailable }
      let files = try attachmentFiles()
      var stored = files.reduce(0) { $0 + $1.size }
      let evictable = files.filter {
        !protectedFiles.contains($0.url.deletingLastPathComponent().lastPathComponent)
      }
      // Plan before deleting: active system presentations still count toward the hard budget.
      guard stored + size - evictable.reduce(0, { $0 + $1.size }) <= attachmentLimit else {
        throw PrivateInboxError.unavailable
      }
      for entry in evictable.sorted(by: {
        $0.date == $1.date ? $0.url.path < $1.url.path : $0.date < $1.date
      }) where stored + size > attachmentLimit {
        try removeAttachmentItem(entry.url.deletingLastPathComponent())
        stored -= entry.size
      }
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      var root = attachments
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try root.setResourceValues(values)
      do {
        #if os(iOS)
          try bytes.write(
            to: folder.appendingPathComponent(safe), options: [.atomic, .completeFileProtection])
        #else
          try bytes.write(to: folder.appendingPathComponent(safe), options: .atomic)
        #endif
      } catch {
        try? removeAttachmentItem(folder)
        throw error
      }
      return file
    }
  }

  // The saved file, or nil when the system or a removal deleted it.
  public func attachmentFile(connection: String, file: String) throws -> URL? {
    let folder = try attachmentURL(connection, file)
    return try transaction {
      let contents = try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard let contents, contents.count == 1, let url = contents.first,
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true, values.isSymbolicLink != true
      else { return nil }
      try FileManager.default.setAttributes(
        [.modificationDate: Date()], ofItemAtPath: url.path)
      return url
    }
  }

  private func attachmentFiles() throws -> [(url: URL, size: Int, date: Date)] {
    guard FileManager.default.fileExists(atPath: attachments.path) else { return [] }
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .isSymbolicLinkKey,
      .fileSizeKey, .contentModificationDateKey,
    ]
    var files: [(url: URL, size: Int, date: Date)] = []
    for connection in try FileManager.default.contentsOfDirectory(
      at: attachments, includingPropertiesForKeys: nil)
    {
      for folder in try FileManager.default.contentsOfDirectory(
        at: connection, includingPropertiesForKeys: nil)
      {
        for url in try FileManager.default.contentsOfDirectory(
          at: folder, includingPropertiesForKeys: keys)
        {
          let values = try url.resourceValues(forKeys: Set(keys))
          guard values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, let date = values.contentModificationDate
          else { throw PrivateInboxError.invalidStore }
          files.append((url, size, date))
        }
      }
    }
    return files
  }

  public func discardAttachment(connection: String, file: String) throws {
    let folder = try attachmentURL(connection, file)
    try unlockedTransaction { try removeAttachmentItem(folder) }
  }

  // TypeScript sends a cleaned name; this keeps the file inside its directory regardless.
  static func attachmentName(_ name: String) -> String {
    let component = name.replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    guard !component.isEmpty, !component.hasPrefix("."), component.utf8.count <= 255 else {
      return "attachment"
    }
    return component
  }

  private func removeItems(_ names: [String]) throws {
    try removeURLs(names.map { directory.appendingPathComponent($0) })
  }

  private func removeURLs(_ urls: [URL]) throws {
    var failure: (any Error)?
    for url in urls {
      do {
        try FileManager.default.removeItem(at: url)
      } catch CocoaError.fileNoSuchFile {} catch { failure = failure ?? error }
    }
    if let failure { throw failure }
  }

  // The Bounded Encrypted Body Cache holds TypeScript's body documents, one file per message, each
  // sealed to its mailbox and message ID. The name's suffix records the eviction tier: opened
  // bodies go before prefetched ones, least recently read first, and bodies in the protected
  // working set are never evicted to admit another. A prefetch exclusion marker has its own tier,
  // evicted with prefetched bodies, so listing can tell it from a saved body.
  public enum BodyTier: String, Sendable, CaseIterable {
    case opened = "o"
    case prefetched = "p"
    case excluded = "x"
  }

  private func bodyName(address: String, subject: String, id: String) -> (String, Data) {
    let identity = Data([subject, address, id].joined(separator: "\n").utf8)
    let name = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    return (name, Data("dev.unwired.private-inbox.body.v1\n".utf8) + identity)
  }

  private func bodyURL(_ connection: String, _ name: String, _ tier: BodyTier) throws -> URL {
    directory.appendingPathComponent(try connectionPath(connection, "bodies/\(name).\(tier.rawValue)"))
  }

  // A missing or unreadable body reads as nil. Verified access discards an unreadable one and
  // updates access time; cache-only access leaves its ciphertext and timestamp untouched.
  public func openMessageBody(
    connection: String, address: String, subject: String, id: String, readOnly: Bool = false
  ) throws -> String? {
    try transaction {
      let (name, identity) = bodyName(address: address, subject: subject, id: id)
      for tier in BodyTier.allCases {
        let file = try bodyURL(connection, name, tier)
        let data: Data
        do {
          data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
          continue
        }
        let key = try existingKey()
        guard let box = try? AES.GCM.SealedBox(combined: data),
          let plaintext = try? AES.GCM.open(
            box, using: SymmetricKey(data: key), authenticating: identity)
        else {
          if !readOnly { try FileManager.default.removeItem(at: file) }
          return nil
        }
        if !readOnly {
          try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        }
        return String(decoding: plaintext, as: UTF8.self)
      }
      return nil
    }
  }

  // Stores a body when it fits after evicting eligible bodies outside the protected set; returns
  // false, storing nothing, when it cannot fit.
  public func commitMessageBody(
    connection: String, address: String, subject: String, id: String, document: String,
    tier: BodyTier, protectedIds: [String]
  ) throws -> Bool {
    try transaction {
      let (name, identity) = bodyName(address: address, subject: subject, id: id)
      let protected = Set(protectedIds.map { bodyName(address: address, subject: subject, id: $0).0 })
      let plaintext = Data(document.utf8)
      // AES-GCM combined representation adds a 12-byte nonce and 16-byte tag.
      let storedSize = plaintext.count + 28
      let key = try existingKey()
      try FileManager.default.createDirectory(
        at: directory.appendingPathComponent(try connectionPath(connection, "bodies")),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      // Reserve capacity before publication, so interruption cannot leave an over-budget cache.
      guard try evictBodies(
        reserving: storedSize, replacing: bodyURL(connection, name, tier), protected: protected)
      else {
        return false
      }
      // Other tiers' files go before the new one is published, so one body never has two valid
      // files; an interruption between them is a cache miss, fetched again.
      for other in BodyTier.allCases where other != tier {
        do {
          try FileManager.default.removeItem(at: try bodyURL(connection, name, other))
        } catch CocoaError.fileNoSuchFile {}
      }
      try write(
        plaintext, file: try connectionPath(connection, "bodies/\(name).\(tier.rawValue)"),
        key: key, authenticating: identity)
      return true
    }
  }

  // The named messages that have a stored body or exclusion marker, and those that have only an
  // exclusion marker.
  public func listMessageBodies(
    connection: String, address: String, subject: String, ids: [String]
  ) throws -> (stored: [String], excluded: [String]) {
    try transaction {
      let entries = try bodies(connection)
      let stored = Set(entries.map(\.name))
      let excluded = Set(entries.filter { $0.tier == .excluded }.map(\.name))
      func name(_ id: String) -> String { bodyName(address: address, subject: subject, id: id).0 }
      return (
        ids.filter { stored.contains(name($0)) }, ids.filter { excluded.contains(name($0)) }
      )
    }
  }

  // Removes the bodies of every message not named, such as those that left the cached Inbox,
  // and reconciles a cache an interrupted writer left over the limit. As in admission, only the
  // protected bodies that fit, in working-set order, keep their protection, so the limit holds.
  public func retainMessageBodies(
    connection: String, address: String, subject: String, expectedRevision: Int, ids: [String],
    protectedIds: [String]
  ) throws {
    try transaction {
      let cache = try readMailbox(file: try connectionPath(connection, "mailbox.enc"))
      guard (cache?.revision ?? 0) == expectedRevision else { throw PrivateInboxError.conflict }
      let kept = Set(ids.map { bodyName(address: address, subject: subject, id: $0).0 })
      for entry in try bodies(connection) where !kept.contains(entry.name) {
        try FileManager.default.removeItem(at: entry.file)
      }
      let sizes = Dictionary(grouping: try bodies(connection), by: \.name).mapValues {
        $0.reduce(0) { $0 + $1.size }
      }
      var protected = Set<String>()
      var protectedSize = 0
      for id in protectedIds {
        let name = bodyName(address: address, subject: subject, id: id).0
        let size = sizes[name] ?? 0
        guard !protected.contains(name), protectedSize + size <= bodyLimit else { continue }
        protected.insert(name)
        protectedSize += size
      }
      _ = try evictBodies(reserving: 0, replacing: nil, protected: protected)
    }
  }

  private struct BodyEntry {
    let file: URL
    let name: String
    let tier: BodyTier
    let read: Date
    let size: Int
  }

  // One connection's bodies, or with none named, every connection's: the limit is device-wide.
  private func bodies(_ connection: String? = nil) throws -> [BodyEntry] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    func contents(_ path: String) throws -> [URL] {
      do {
        return try FileManager.default.contentsOfDirectory(
          at: directory.appendingPathComponent(path), includingPropertiesForKeys: keys)
      } catch CocoaError.fileReadNoSuchFile {
        return []
      }
    }
    let folders =
      try connection.map { [try connectionPath($0, "bodies")] }
      // The bodies written before Mailbox Connections count until adopted or removed.
      ?? ["bodies"] + contents("mailboxes").map { "mailboxes/\($0.lastPathComponent)/bodies" }
    let files = try folders.flatMap(contents)
    return try files.map { file in
      let values = try file.resourceValues(forKeys: Set(keys))
      return BodyEntry(
        file: file, name: file.deletingPathExtension().lastPathComponent,
        tier: BodyTier(rawValue: file.pathExtension) ?? .opened,
        read: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0)
    }
  }

  // Deterministic: opened bodies before prefetched ones, each least recently read first, then
  // by name. Nothing is removed unless the reservation then fits.
  private func evictBodies(reserving bytes: Int, replacing file: URL?, protected: Set<String>) throws
    -> Bool
  {
    let entries = try bodies()
    let name = file?.deletingPathExtension().lastPathComponent
    // Conservatively reserve the old tier and its replacement before deleting anything.
    // A refused tier change must preserve the old ciphertext and every protected body.
    var total = entries.reduce(bytes) { $0 + ($1.file == file ? 0 : $1.size) }
    let eligible = entries.filter { $0.name != name && !protected.contains($0.name) }.sorted {
      ($0.tier == .opened ? 0 : 1, $0.read, $0.name) < ($1.tier == .opened ? 0 : 1, $1.read, $1.name)
    }
    var evicted: [BodyEntry] = []
    for entry in eligible where total > bodyLimit {
      evicted.append(entry)
      total -= entry.size
    }
    guard total <= bodyLimit else { return false }
    for entry in evicted { try FileManager.default.removeItem(at: entry.file) }
    return true
  }

  private func readMailbox(file: String) throws -> MailboxCache? {
    let data: Data
    do {
      data = try Data(contentsOf: directory.appendingPathComponent(file))
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    }
    let key = try existingKey()
    do {
      let box = try AES.GCM.SealedBox(combined: data)
      let plaintext = try AES.GCM.open(
        box, using: SymmetricKey(data: key), authenticating: mailboxAssociatedData)
      let cache = try JSONDecoder().decode(MailboxCache.self, from: plaintext)
      guard cache.revision > 0 else { throw PrivateInboxError.invalidStore }
      return cache
    } catch {
      throw PrivateInboxError.invalidStore
    }
  }

  private func existingKey() throws -> Data {
    guard let key = try keychain.read("encryption-key"), key.count == 32 else {
      throw PrivateInboxError.unavailable
    }
    return key
  }

  private func decrypt(_ data: Data, key: Data) throws -> InboxSnapshot {
    do {
      let box = try AES.GCM.SealedBox(combined: data)
      let plaintext = try AES.GCM.open(
        box, using: SymmetricKey(data: key), authenticating: associatedData)
      let snapshot = try JSONDecoder().decode(InboxSnapshot.self, from: plaintext)
      try validate(snapshot)
      return snapshot
    } catch {
      throw PrivateInboxError.invalidStore
    }
  }

  private func validate(_ snapshot: InboxSnapshot) throws {
    guard snapshot.version == 1, snapshot.revision >= 0,
      Set(snapshot.messages.map(\.id)).count == snapshot.messages.count
    else { throw PrivateInboxError.invalidStore }
  }

  private func encode(_ snapshot: InboxSnapshot) throws -> String {
    // JSONEncoder always produces UTF-8.
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
  }

  private func save(_ snapshot: InboxSnapshot, key: Data) throws {
    try write(
      JSONEncoder().encode(snapshot), file: "inbox.enc", key: key, authenticating: associatedData)
  }

  private func write(_ plaintext: Data, file name: String, key: Data, authenticating: Data) throws {
    guard key.count == 32 else { throw PrivateInboxError.unavailable }
    let box = try AES.GCM.seal(
      plaintext, using: SymmetricKey(data: key), authenticating: authenticating)
    guard let encrypted = box.combined else { throw PrivateInboxError.unavailable }
    let file = directory.appendingPathComponent(name)
    #if os(iOS)
      try encrypted.write(to: file, options: [.atomic, .completeFileProtection])
    #else
      try encrypted.write(to: file, options: .atomic)
    #endif
    // A fulfilled mutation means ciphertext has reached the filesystem, before publishing it to windows.
    let descriptor = Darwin.open(file.path, O_RDONLY)
    guard descriptor >= 0 else { throw PrivateInboxError.unavailable }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw PrivateInboxError.unavailable }
  }

  private func transaction<T>(_ operation: () throws -> T) throws -> T {
    try requireProtectedData()
    do {
      return try unlockedTransaction(operation)
    } catch {
      try requireProtectedData()
      throw error
    }
  }

  private func unlockedTransaction<T>(_ operation: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var location = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try location.setResourceValues(values)
    let descriptor = Darwin.open(
      directory.appendingPathComponent("store.lock").path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw PrivateInboxError.unavailable }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw PrivateInboxError.unavailable }
    defer { flock(descriptor, LOCK_UN) }
    return try operation()
  }
}
