import Foundation

// Test-only line protocol for exercising the real native vault from the shared Inbox journeys.
// No credentials, keys, transport or production bridge APIs are replaced or exported.
@main struct GmailHistoryStore {
  struct Command: Decodable {
    struct History: Decodable {
      let segments: [String: String]
      let keep: Set<String>
    }
    let operation: String
    let address: String
    let revision: Int?
    let document: String?
    let history: History?
    let name: String?
    let id: String?
    let tier: String?
    let ids: [String]?
    let protectedIds: [String]?
  }

  static func main() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = "dev.unwired.history.tests.\(UUID().uuidString)"
    defer {
      try? FileManager.default.removeItem(at: directory)
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
    }
    let connection = String(repeating: "0", count: 32)
    while let line = readLine() {
      let response: [String: Any]
      do {
        let command = try JSONDecoder().decode(Command.self, from: Data(line.utf8))
        // Every request uses a fresh instance: only disk and the real Keychain carry progress.
        let store = PrivateInboxStore(directory: directory, service: service)
        switch command.operation {
        case "open":
          response = try store.openMailbox(
            connection: connection, address: command.address, subject: "synthetic-history")
        case "commit":
          guard let revision = command.revision, let document = command.document else {
            throw PrivateInboxError.invalidStore
          }
          response = try store.commitMailbox(
            connection: connection, address: command.address, subject: "synthetic-history",
            expectedRevision: revision, document: document,
            history: command.history.map { ($0.segments, $0.keep) })
        case "segment":
          guard let name = command.name else { throw PrivateInboxError.invalidStore }
          response = [
            "document": try store.openMailboxSegment(
              connection: connection, address: command.address, subject: "synthetic-history",
              name: name) ?? NSNull()
          ]
        case "body":
          guard let id = command.id else { throw PrivateInboxError.invalidStore }
          response = [
            "document": try store.openMessageBody(
              connection: connection, address: command.address, subject: "synthetic-history",
              id: id) ?? NSNull()
          ]
        case "commit-body":
          let tiers: [String: PrivateInboxStore.BodyTier] = [
            "opened": .opened, "prefetched": .prefetched, "excluded": .excluded,
          ]
          guard let id = command.id, let document = command.document,
            let tier = command.tier.flatMap({ tiers[$0] })
          else { throw PrivateInboxError.invalidStore }
          response = [
            "admitted": try store.commitMessageBody(
              connection: connection, address: command.address, subject: "synthetic-history",
              id: id, document: document, tier: tier, protectedIds: command.protectedIds ?? [],
              expectedRevision: command.revision)
          ]
        case "list-bodies":
          let (stored, excluded) = try store.listMessageBodies(
            connection: connection, address: command.address, subject: "synthetic-history",
            ids: command.ids ?? [])
          response = ["stored": stored, "excluded": excluded]
        case "retain-bodies":
          guard let revision = command.revision else { throw PrivateInboxError.invalidStore }
          try store.retainMessageBodies(
            connection: connection, address: command.address, subject: "synthetic-history",
            expectedRevision: revision, ids: command.ids ?? [],
            protectedIds: command.protectedIds ?? [])
          response = [:]
        default:
          throw PrivateInboxError.invalidStore
        }
      } catch {
        response = ["code": (error as? PrivateInboxError) == .conflict ? "conflict" : "unavailable"]
      }
      var output = try JSONSerialization.data(withJSONObject: response)
      output.append(0x0A)
      try FileHandle.standardOutput.write(contentsOf: output)
    }
  }
}
