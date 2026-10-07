import Foundation

@testable import PrivateInbox

// The connection list registration reports to JavaScript, in the order the connections were added.
func mailboxList(_ entries: [(subject: String, address: String, state: String)]) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  let list = entries.map {
    ["id": MailboxConnection.id(subject: $0.subject), "address": $0.address, "state": $0.state]
  }
  return String(decoding: (try? encoder.encode(list)) ?? Data(), as: UTF8.self)
}

extension RegistrationStore {
  // The generation JavaScript holds for the connection of this Google account.
  func generation(_ subject: String) -> String {
    mailboxGeneration(MailboxConnection.id(subject: subject)).uuidString
  }
}


// Epochs are random; these field assertions compare the stable display contract separately.
func mailboxDisplay(_ value: String?) throws -> String? {
  guard let value else { return nil }
  var entries = try JSONDecoder().decode([[String: String]].self, from: Data(value.utf8))
  for index in entries.indices { entries[index].removeValue(forKey: "epoch") }
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  return String(decoding: try encoder.encode(entries), as: UTF8.self)
}

// A registration reply with its connection list in the stable display contract.
func displayed(_ reply: [String: String]) throws -> [String: String] {
  var result = reply
  result["mailboxes"] = try mailboxDisplay(reply["mailboxes"])
  return result
}
