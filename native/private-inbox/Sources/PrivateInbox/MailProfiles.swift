import Foundation

// One Mail Profile's definition in Product Sync: its opaque identifier, the record's write count
// and its name, or none once the Profile is removed. Sealed together, so a record cannot be moved
// to another Profile or served as a newer one.
struct MailProfileRecord: Codable, Equatable {
  static let schemaVersion = 1
  let id: String
  let version: Int
  let name: String?
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

// Mail Profile definitions and connection ownership in Product Sync. TypeScript reads, merges and
// writes them; native code seals and opens each record under an identifier bound to its Profile or
// connection, and keeps TypeScript's Profile state in the account's device-only vault.
extension RegistrationStore {
  private enum ProfileRecord {
    case profile(MailProfileRecord)
    case mailbox(MailboxProfileRecord)
    case notifications(MailboxNotificationsRecord)

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
      } else if kind == "profile" {
        guard let id = value["id"] as? String, !id.isEmpty, id.count <= 200 else { return nil }
        let name = value["name"] as? String
        guard name.map({ !$0.isEmpty }) ?? (value["name"] == nil) else { return nil }
        self = .profile(MailProfileRecord(id: id, version: version, name: name))
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
      }
    }

    var schemaVersion: Int {
      switch self {
      case .profile: MailProfileRecord.schemaVersion
      case .mailbox: MailboxProfileRecord.schemaVersion
      case .notifications: MailboxNotificationsRecord.schemaVersion
      }
    }

    func encoded() throws -> Data {
      switch self {
      case .profile(let value): return try JSONEncoder().encode(value)
      case .mailbox(let value): return try JSONEncoder().encode(value)
      case .notifications(let value): return try JSONEncoder().encode(value)
      }
    }

    func object() throws -> [String: Any] {
      guard var object = try JSONSerialization.jsonObject(with: encoded()) as? [String: Any]
      else { throw RegistrationError.unavailable }
      switch self {
      case .profile: object["kind"] = "profile"
      case .mailbox: object["kind"] = "mailbox"
      case .notifications: object["kind"] = "notifications"
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
