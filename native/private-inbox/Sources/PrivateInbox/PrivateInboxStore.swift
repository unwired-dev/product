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

public final class PrivateInboxStore {
  private let directory: URL
  private let keychain: DeviceKeychain
  private let protectedDataAvailable: () -> Bool
  private let associatedData = Data("dev.unwired.private-inbox.v1".utf8)

  public convenience init(directory: URL, service: String) {
    self.init(
      directory: directory, service: service,
      protectedDataAvailable: Self.protectedDataAvailability())
  }

  init(directory: URL, service: String, protectedDataAvailable: @escaping () -> Bool) {
    self.directory = directory
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
      guard let key = availableKey, key.count == 32 else { throw PrivateInboxError.locked }
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

  private func existingKey() throws -> Data {
    guard let key = try keychain.read("encryption-key"), key.count == 32 else {
      throw PrivateInboxError.locked
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
    guard key.count == 32 else { throw PrivateInboxError.locked }
    let plaintext = try JSONEncoder().encode(snapshot)
    let box = try AES.GCM.seal(
      plaintext, using: SymmetricKey(data: key), authenticating: associatedData)
    guard let encrypted = box.combined else { throw PrivateInboxError.unavailable }
    let file = directory.appendingPathComponent("inbox.enc")
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
