import Foundation

// One Mail Profile's definition in Product Sync: its opaque identifier, the record's write count
// and its name and optional Color and Icon keys, or none once the Profile is removed. Sealed
// together, so a record cannot be moved to another Profile or served as a newer one.
struct MailProfileRecord: Codable, Equatable {
  static let schemaVersion = 1
  let id: String
  let version: Int
  let name: String?
  var color: String? = nil
  var icon: String? = nil
}

// The Mail Profile that owns one incarnation of a Mailbox Connection, named by its descriptor's
// record identifier and epoch. Credentials and addresses never enter it.
struct MailboxProfileRecord: Codable, Equatable {
  static let schemaVersion = 1
  let record: String
  let epoch: String
  let version: Int
  let profile: String
}

// Whether one incarnation of a Mailbox Connection notifies for new Inbox mail, a Mail Workflow
// Preference of the Profile that owns it, named like its ownership.
struct MailboxNotificationsRecord: Codable, Equatable {
  static let schemaVersion = 1
  let record: String
  let epoch: String
  let version: Int
  let enabled: Bool
}

// The Spam and Trash folders a person chose for one incarnation of an IMAP connection whose server
// marks none. Folder names travel only inside this sealed record.
struct MailboxFoldersRecord: Codable, Equatable {
  static let schemaVersion = 1
  let record: String
  let epoch: String
  let version: Int
  let junk: String?
  let trash: String?
}

// Where one incarnation of a Mailbox Connection sits among the connections of the Mail Profile that
// owned it when arranged, with its ownership's version then, and its display Color key, kept as
// given like a Profile's Color.
struct MailboxDisplayRecord: Codable, Equatable {
  static let schemaVersion = 1
  let record: String
  let epoch: String
  let version: Int
  let profile: String?
  let position: Int?
  let ownership: Int?
  let color: String?
}

// A Mail Profile's Default Sending Identity: the primary address of one incarnation of a Mailbox
// Connection, or none once cleared. The address travels only inside this sealed record.
struct ProfileSendingRecord: Codable, Equatable {
  static let schemaVersion = 1
  struct Identity: Codable, Equatable {
    let record: String
    let epoch: String
    let address: String
  }
  let profile: String
  let version: Int
  let identity: Identity?
}

// Mail Profile definitions and connection ownership in Product Sync. TypeScript reads, merges and
// writes them; native code seals and opens each record under an identifier bound to its Profile or
// connection, and keeps TypeScript's Profile state in the account's device-only vault.
extension RegistrationStore {
  private enum ProfileRecord {
    case profile(MailProfileRecord)
    case mailbox(MailboxProfileRecord)
    case notifications(MailboxNotificationsRecord)
    case folders(MailboxFoldersRecord)
    case display(MailboxDisplayRecord)
    case sending(ProfileSendingRecord)

    init?(_ value: [String: Any]) {
      guard let kind = value["kind"] as? String,
        let version = (value["version"] as? Double).flatMap({ Int(exactly: $0) }), version >= 1
      else { return nil }
      if kind == "notifications" {
        guard let record = value["record"] as? String, record.hasPrefix("mailbox."),
          let epoch = value["epoch"] as? String, !epoch.isEmpty,
          let enabled = value["enabled"] as? Bool
        else { return nil }
        self = .notifications(
          MailboxNotificationsRecord(record: record, epoch: epoch, version: version, enabled: enabled))
      } else if kind == "folders" {
        guard let record = value["record"] as? String, record.hasPrefix("mailbox."),
          let epoch = value["epoch"] as? String, !epoch.isEmpty
        else { return nil }
        let junk = value["junk"] as? String
        let trash = value["trash"] as? String
        guard junk.map({ !$0.isEmpty }) ?? (value["junk"] == nil),
          trash.map({ !$0.isEmpty }) ?? (value["trash"] == nil)
        else { return nil }
        self = .folders(
          MailboxFoldersRecord(
            record: record, epoch: epoch, version: version, junk: junk, trash: trash))
      } else if kind == "display" {
        guard let record = value["record"] as? String, record.hasPrefix("mailbox."),
          let epoch = value["epoch"] as? String, !epoch.isEmpty
        else { return nil }
        let profile = value["profile"] as? String
        let position = (value["position"] as? Double).flatMap { Int(exactly: $0) }
        let ownership = (value["ownership"] as? Double).flatMap { Int(exactly: $0) }
        let color = value["color"] as? String
        // A position belongs to the Profile and the ownership version it was arranged under.
        guard profile.map({ !$0.isEmpty && $0.count <= 200 }) ?? (value["profile"] == nil),
          position.map({ $0 >= 0 }) ?? (value["position"] == nil),
          ownership.map({ $0 >= 0 }) ?? (value["ownership"] == nil),
          (profile == nil) == (position == nil), (profile == nil) == (ownership == nil),
          color.map({ !$0.isEmpty }) ?? (value["color"] == nil)
        else { return nil }
        self = .display(
          MailboxDisplayRecord(
            record: record, epoch: epoch, version: version, profile: profile, position: position,
            ownership: ownership, color: color))
      } else if kind == "sending" {
        guard let profile = value["profile"] as? String, !profile.isEmpty, profile.count <= 200
        else { return nil }
        var identity: ProfileSendingRecord.Identity?
        if let chosen = value["identity"] as? [String: Any] {
          guard let record = chosen["record"] as? String, record.hasPrefix("mailbox."),
            let epoch = chosen["epoch"] as? String, !epoch.isEmpty,
            let address = chosen["address"] as? String, !address.isEmpty
          else { return nil }
          identity = ProfileSendingRecord.Identity(record: record, epoch: epoch, address: address)
        } else if value["identity"] != nil {
          return nil
        }
        self = .sending(ProfileSendingRecord(profile: profile, version: version, identity: identity))
      } else if kind == "profile" {
        guard let id = value["id"] as? String, !id.isEmpty, id.count <= 200 else { return nil }
        let name = value["name"] as? String
        guard name.map({ !$0.isEmpty }) ?? (value["name"] == nil) else { return nil }
        // Style keys are carried as given, so a key a newer client wrote survives a rewrite here.
        let color = value["color"] as? String
        let icon = value["icon"] as? String
        guard color.map({ !$0.isEmpty }) ?? (value["color"] == nil),
          icon.map({ !$0.isEmpty }) ?? (value["icon"] == nil)
        else { return nil }
        self = .profile(
          MailProfileRecord(id: id, version: version, name: name, color: color, icon: icon))
      } else if kind == "mailbox" {
        guard let record = value["record"] as? String, record.hasPrefix("mailbox."),
          let epoch = value["epoch"] as? String, !epoch.isEmpty,
          let profile = value["profile"] as? String, !profile.isEmpty, profile.count <= 200
        else { return nil }
        self = .mailbox(
          MailboxProfileRecord(record: record, epoch: epoch, version: version, profile: profile))
      } else {
        return nil
      }
    }

    func identifier(_ ring: ProductSyncKeyRing) throws -> String {
      switch self {
      case .profile(let value): return try ring.identifier("profile", value.id)
      case .mailbox(let value): return try ring.identifier("mailbox-profile", value.record)
      case .notifications(let value):
        return try ring.identifier("mailbox-notifications", value.record)
      case .folders(let value): return try ring.identifier("mailbox-folders", value.record)
      case .display(let value): return try ring.identifier("mailbox-display", value.record)
      case .sending(let value): return try ring.identifier("profile-sending", value.profile)
      }
    }

    var schemaVersion: Int {
      switch self {
      case .profile: MailProfileRecord.schemaVersion
      case .mailbox: MailboxProfileRecord.schemaVersion
      case .notifications: MailboxNotificationsRecord.schemaVersion
      case .folders: MailboxFoldersRecord.schemaVersion
      case .display: MailboxDisplayRecord.schemaVersion
      case .sending: ProfileSendingRecord.schemaVersion
      }
    }

    func encoded() throws -> Data {
      switch self {
      case .profile(let value): return try JSONEncoder().encode(value)
      case .mailbox(let value): return try JSONEncoder().encode(value)
      case .notifications(let value): return try JSONEncoder().encode(value)
      case .folders(let value): return try JSONEncoder().encode(value)
      case .display(let value): return try JSONEncoder().encode(value)
      case .sending(let value): return try JSONEncoder().encode(value)
      }
    }

    func object() throws -> [String: Any] {
      guard var object = try JSONSerialization.jsonObject(with: encoded()) as? [String: Any]
      else { throw RegistrationError.unavailable }
      switch self {
      case .profile: object["kind"] = "profile"
      case .mailbox: object["kind"] = "mailbox"
      case .notifications: object["kind"] = "notifications"
      case .folders: object["kind"] = "folders"
      case .display: object["kind"] = "display"
      case .sending: object["kind"] = "sending"
      }
      return object
    }
  }

  // Seals a Profile definition or connection ownership at the newest key epoch, under the
  // identifier its Profile or connection determines.
  func sealProfileRecord(_ value: [String: Any]) throws -> [String: Any] {
    let vault = try publishedVault()
    guard let record = ProfileRecord(value) else { throw RegistrationError.unavailable }
    let identifier = try record.identifier(vault.ring)
    let sealed = try vault.ring.seal(
      record: record.encoded(), account: vault.productAccountId, identifier: identifier,
      schemaVersion: record.schemaVersion)
    guard
      let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sealed))
        as? [String: Any]
    else { throw RegistrationError.unavailable }
    return ["payloadIdentifier": identifier, "encryptedPayload": payload]
  }

  // Each stored record's Profile definition or ownership when it opens for this account under the
  // identifier its own content determines, otherwise null: such a record is never shown or replaced.
  func openProfileRecords(_ records: [Any]) throws -> [Any] {
    let vault = try publishedVault()
    func open(_ record: Any) throws -> [String: Any]? {
      guard let record = record as? [String: Any],
        let identifier = record["payloadIdentifier"] as? String,
        let payload = record["encryptedPayload"],
        let sealed = try? JSONDecoder().decode(
          EncryptedPayload.self, from: JSONSerialization.data(withJSONObject: payload))
      else { return nil }
      let opened: ProfileRecord
      if identifier.hasPrefix("profile.") {
        guard
          let plaintext = try? vault.ring.open(
            record: sealed, account: vault.productAccountId, identifier: identifier,
            schemaVersion: MailProfileRecord.schemaVersion),
          let value = try? JSONDecoder().decode(MailProfileRecord.self, from: plaintext)
        else { return nil }
        opened = .profile(value)
      } else if identifier.hasPrefix("mailbox-profile.") {
        guard
          let plaintext = try? vault.ring.open(
            record: sealed, account: vault.productAccountId, identifier: identifier,
            schemaVersion: MailboxProfileRecord.schemaVersion),
          let value = try? JSONDecoder().decode(MailboxProfileRecord.self, from: plaintext)
        else { return nil }
        opened = .mailbox(value)
      } else if identifier.hasPrefix("mailbox-notifications.") {
        guard
          let plaintext = try? vault.ring.open(
            record: sealed, account: vault.productAccountId, identifier: identifier,
            schemaVersion: MailboxNotificationsRecord.schemaVersion),
          let value = try? JSONDecoder().decode(MailboxNotificationsRecord.self, from: plaintext)
        else { return nil }
        opened = .notifications(value)
      } else if identifier.hasPrefix("mailbox-folders.") {
        guard
          let plaintext = try? vault.ring.open(
            record: sealed, account: vault.productAccountId, identifier: identifier,
            schemaVersion: MailboxFoldersRecord.schemaVersion),
          let value = try? JSONDecoder().decode(MailboxFoldersRecord.self, from: plaintext)
        else { return nil }
        opened = .folders(value)
      } else if identifier.hasPrefix("mailbox-display.") {
        guard
          let plaintext = try? vault.ring.open(
            record: sealed, account: vault.productAccountId, identifier: identifier,
            schemaVersion: MailboxDisplayRecord.schemaVersion),
          let value = try? JSONDecoder().decode(MailboxDisplayRecord.self, from: plaintext)
        else { return nil }
        opened = .display(value)
      } else if identifier.hasPrefix("profile-sending.") {
        guard
          let plaintext = try? vault.ring.open(
            record: sealed, account: vault.productAccountId, identifier: identifier,
            schemaVersion: ProfileSendingRecord.schemaVersion),
          let value = try? JSONDecoder().decode(ProfileSendingRecord.self, from: plaintext)
        else { return nil }
        opened = .sending(value)
      } else {
        return nil
      }
      return try opened.identifier(vault.ring) == identifier ? try opened.object() : nil
    }
    return try records.map { try open($0) ?? NSNull() }
  }

  // Saves TypeScript's Profile state in the protected registration, independently of replaceable
  // key material. It survives re-enrollment and leaves with the account's registration.
  func recordProfiles(_ state: [String: Any]) throws {
    var saved = try saved()
    guard let product = saved.product, product.pending != true,
      try loadVault(product.productAccountId) != nil
    else { throw RegistrationError.unavailable }
    saved.profiles = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
    try save(saved)
  }
}
