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

// The connected mailbox's cache. Its document is TypeScript's; native keeps it encrypted, for one
// mailbox address, and replaces it only from the revision the caller read.
struct MailboxCache: Codable {
  let revision: Int
  let address: String
  // The Google account behind the address, which a recycled address does not share.
  let subject: String?
  let document: String
}

public final class PrivateInboxStore {
  private let directory: URL
  private let keychain: DeviceKeychain
  private let protectedDataAvailable: () -> Bool
  // The Bounded Encrypted Body Cache's device-wide limit, in stored bytes.
  private let bodyLimit: Int
  private let associatedData = Data("dev.unwired.private-inbox.v1".utf8)
  private let mailboxAssociatedData = Data("dev.unwired.private-inbox.mailbox.v1".utf8)

  public convenience init(directory: URL, service: String) {
    self.init(
      directory: directory, service: service,
      protectedDataAvailable: Self.protectedDataAvailability())
  }

  init(
    directory: URL, service: String, protectedDataAvailable: @escaping () -> Bool,
    bodyLimit: Int = 500 * 1024 * 1024
  ) {
    self.directory = directory
    self.bodyLimit = bodyLimit
    keychain = DeviceKeychain(service: service + ".database")
    self.protectedDataAvailable = protectedDataAvailable
  }

  private static func protectedDataAvailability() -> () -> Bool {
    #if os(iOS)
      let application: UIApplication
      if Thread.isMainThread {
        application = MainActor.assumeIsolated { UIApplication.shared }
      } else {
        application = DispatchQueue.main.sync {
          MainActor.assumeIsolated { UIApplication.shared }
        }
      }
      return { application.isProtectedDataAvailable }
    #else
      return { true }
    #endif
  }

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

  // Another mailbox's cache, including another Google account at the same address, reads as
  // empty; its first commit replaces it. Cache replies do not include the subject.
  public func openMailbox(address: String, subject: String) throws -> [String: Any] {
    try transaction {
      let cache = try readMailbox()
      let owned = cache.flatMap { $0.address == address && $0.subject == subject ? $0 : nil }
      return [
        "revision": cache?.revision ?? 0, "address": address,
        "document": owned?.document ?? NSNull(),
      ]
    }
  }

  public func commitMailbox(
    address: String, subject: String, expectedRevision: Int, document: String
  ) throws -> [String: Any] {
    try transaction {
      let cache = try readMailbox()
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
      try write(
        JSONEncoder().encode(next), file: "mailbox.enc", key: key,
        authenticating: mailboxAssociatedData)
      return ["revision": next.revision, "address": address, "document": document]
    }
  }

  // Needs no key, so a locked device can still forget the mailbox and its bodies.
  public func removeMailbox() throws {
    try unlockedTransaction {
      for name in ["mailbox.enc", "bodies"] {
        do {
          try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        } catch CocoaError.fileNoSuchFile {}
      }
    }
  }

  // The Bounded Encrypted Body Cache holds TypeScript's body documents, one file per message, each
  // sealed to its mailbox and message ID. The name's suffix records the eviction tier: opened
  // bodies go before prefetched ones, least recently read first, and bodies in the protected
  // working set are never evicted to admit another.
  public enum BodyTier: String {
    case opened = "o"
    case prefetched = "p"
  }

  private func bodyName(address: String, subject: String, id: String) -> (String, Data) {
    let identity = Data([subject, address, id].joined(separator: "\n").utf8)
    let name = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    return (name, Data("dev.unwired.private-inbox.body.v1\n".utf8) + identity)
  }

  private func bodyURL(_ name: String, _ tier: BodyTier) -> URL {
    directory.appendingPathComponent("bodies/\(name).\(tier.rawValue)")
  }

  // A missing or unreadable body reads as nil. Verified access discards an unreadable one and
  // updates access time; cache-only access leaves its ciphertext and timestamp untouched.
  public func openMessageBody(
    address: String, subject: String, id: String, readOnly: Bool = false
  ) throws -> String? {
    try transaction {
      let (name, identity) = bodyName(address: address, subject: subject, id: id)
      for tier in [BodyTier.opened, .prefetched] {
        let file = bodyURL(name, tier)
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
    address: String, subject: String, id: String, document: String, tier: BodyTier,
    protectedIds: [String]
  ) throws -> Bool {
    try transaction {
      let (name, identity) = bodyName(address: address, subject: subject, id: id)
      let protected = Set(protectedIds.map { bodyName(address: address, subject: subject, id: $0).0 })
      let plaintext = Data(document.utf8)
      // AES-GCM combined representation adds a 12-byte nonce and 16-byte tag.
      let storedSize = plaintext.count + 28
      let key = try existingKey()
      try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("bodies"), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      // Reserve capacity before publication, so interruption cannot leave an over-budget cache.
      guard try evictBodies(
        reserving: storedSize, replacing: bodyURL(name, tier), protected: protected)
      else {
        return false
      }
      // The other tier's file goes before the new one is published, so one body never has two
      // valid files; an interruption between them is a cache miss, fetched again.
      let other = bodyURL(name, tier == .opened ? .prefetched : .opened)
      do { try FileManager.default.removeItem(at: other) } catch CocoaError.fileNoSuchFile {}
      try write(
        plaintext, file: "bodies/\(name).\(tier.rawValue)", key: key, authenticating: identity)
      return true
    }
  }

  // The named messages that have a stored body or exclusion marker.
  public func listMessageBodies(address: String, subject: String, ids: [String]) throws -> [String] {
    try transaction {
      let stored = Set(try bodies().map(\.name))
      return ids.filter { stored.contains(bodyName(address: address, subject: subject, id: $0).0) }
    }
  }

  // Removes the bodies of every message not named, such as those that left the cached Inbox,
  // and reconciles a cache an interrupted writer left over the limit. As in admission, only the
  // protected bodies that fit, in working-set order, keep their protection, so the limit holds.
  public func retainMessageBodies(
    address: String, subject: String, expectedRevision: Int, ids: [String],
    protectedIds: [String]
  ) throws {
    try transaction {
      let cache = try readMailbox()
      guard (cache?.revision ?? 0) == expectedRevision else { throw PrivateInboxError.conflict }
      let kept = Set(ids.map { bodyName(address: address, subject: subject, id: $0).0 })
      for entry in try bodies() where !kept.contains(entry.name) {
        try FileManager.default.removeItem(at: entry.file)
      }
      let sizes = Dictionary(grouping: try bodies(), by: \.name).mapValues {
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

  private func bodies() throws -> [BodyEntry] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    let files: [URL]
    do {
      files = try FileManager.default.contentsOfDirectory(
        at: directory.appendingPathComponent("bodies"), includingPropertiesForKeys: keys)
    } catch CocoaError.fileReadNoSuchFile {
      return []
    }
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
      ($0.tier == .prefetched ? 1 : 0, $0.read, $0.name) < ($1.tier == .prefetched ? 1 : 0, $1.read, $1.name)
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

  private func readMailbox() throws -> MailboxCache? {
    let data: Data
    do {
      data = try Data(contentsOf: directory.appendingPathComponent("mailbox.enc"))
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
