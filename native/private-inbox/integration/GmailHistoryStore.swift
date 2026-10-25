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
