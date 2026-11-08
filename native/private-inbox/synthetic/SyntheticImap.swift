#if UNWIRED_REGISTRATION_MOCK
  import Foundation

  // The registration Mock Mail Session's IMAP and SMTP servers. Any login succeeds. The IMAP
  // server marks only its Sent folder, so it says nothing about which folders hold Spam and Trash;
  // its changes and submissions are accepted and discarded.
  struct SyntheticImap: ImapProvider {
    static let uidValidity: UInt32 = 1
    // Folders as the server lists them, with their messages by UID.
    static let folders: [(folder: ImapListedFolder, messages: [ImapEnvelope])] = [
      (listed("INBOX"), [envelope(1, "Sam Rivera", "sam@example.invalid", "Welcome to IMAP")]),
      (listed("Sent Messages", "\\Sent"), []),
      (listed("Bulk Mail"), [envelope(1, "Prize Desk", "prizes@example.invalid", "Unwanted offer")]),
      (listed("Deleted Messages"), [envelope(1, "Old Shop", "shop@example.invalid", "Old receipt")]),
    ]

    private static func listed(_ name: String, _ attributes: String...) -> ImapListedFolder {
      ImapListedFolder(name: name, attributes: ["\\HasNoChildren"] + attributes, delimiter: "/")
    }
    private static func envelope(_ uid: UInt32, _ sender: String, _ address: String, _ subject: String)
      -> ImapEnvelope
    {
      ImapEnvelope(
        uid: uid, flags: [], received: 1_793_520_000_000, size: 120, sender: sender,
        address: address, subject: subject)
    }
    static func messages(_ folder: String) throws -> [ImapEnvelope] {
      guard let found = folders.first(where: { $0.folder.name == folder }) else {
        throw ImapFailure.missing
      }
      return found.messages
    }

    func verify(_ account: ImapAccount, password: String) async throws {}
    func open(_ account: ImapAccount, password: String) async throws -> any ImapSession {
      SyntheticImapSession()
    }
    func history(_ account: ImapAccount, password: String, request: ImapHistoryRequest) async throws
      -> ImapHistoryPage
    {
      let all = try Self.messages(request.folder)
      let shown = all.filter { $0.uid > request.above && $0.uid < (request.below ?? .max) }
      let kept = Array(shown.suffix(request.limit))
      return ImapHistoryPage(
        uidValidity: Self.uidValidity, uidNext: (all.map(\.uid).max() ?? 0) + 1, total: all.count,
        messages: kept,
        below: shown.count > request.limit ? kept[0].uid : max(request.above, 1),
        present: request.known.filter { uid in all.contains { $0.uid == uid } })
    }
    func message(
      _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32, uid: UInt32,
      limit: Int
    ) async throws -> Data {
      guard let found = try Self.messages(folder).first(where: { $0.uid == uid }) else {
        throw ImapFailure.missing
      }
      return Data(
        """
        From: \(found.sender) <\(found.address)>\r
        To: alex@example.invalid\r
        Subject: \(found.subject)\r
        Date: Sun, 01 Nov 2026 09:00:00 +0000\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        \(found.subject).\r

        """.utf8)
    }
    func headers(
      _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32, uids: [UInt32]
    ) async throws -> [ImapHeaders] {
      uids.map {
        ImapHeaders(uid: $0, fields: [ImapHeaderField(name: "content-type", value: "text/plain")])
      }
    }
  }

  final class SyntheticImapSession: ImapSession, @unchecked Sendable {
    private let lock = NSLock()
    private var examined = "INBOX"
    private var closed = false

    private func current() throws -> [ImapEnvelope] {
      try SyntheticImap.messages(lock.withLock { examined })
    }
    func capabilities() async throws -> [String] { ["IMAP4rev1", "MOVE", "UIDPLUS"] }
    func folders() async throws -> [ImapListedFolder] { SyntheticImap.folders.map(\.folder) }
    func select(_ folder: String) async throws -> UInt32 {
      _ = try await examine(folder)
      return SyntheticImap.uidValidity
    }
    func examine(_ folder: String) async throws -> ImapSelection {
      let messages = try SyntheticImap.messages(folder)
      lock.withLock { examined = folder }
      return ImapSelection(
        uidValidity: SyntheticImap.uidValidity, uidNext: (messages.map(\.uid).max() ?? 0) + 1,
        messages: messages.count)
    }
    func envelopes(_ read: ImapEnvelopeRead) async throws -> [ImapEnvelope] {
      let messages = try current()
      return switch read {
      case .uids(let uids): messages.filter { uids.contains($0.uid) }
      case .from(let uid): messages.filter { $0.uid >= uid }.suffix(1).map { $0 }
      case .newest(let count, _): Array(messages.suffix(count))
      }
    }
    func flags(_ uids: [UInt32]) async throws -> [UInt32: [String]] {
      Dictionary(
        uniqueKeysWithValues: try current().filter { uids.contains($0.uid) }.map { ($0.uid, $0.flags) })
    }
    func search(_ folder: String, for criterion: ImapSearchCriterion, newest: Int) async throws
      -> ImapMatches
    {
      _ = try SyntheticImap.messages(folder)
      return ImapMatches(uidValidity: SyntheticImap.uidValidity, uids: [], total: 0)
    }
    // Waits without news until the time runs out or the session closes.
    func idle(folder: String, seconds: Int) async throws -> [String] {
      for _ in 0..<seconds where !lock.withLock({ closed }) {
        try await Task.sleep(for: .seconds(1))
      }
      return []
    }
    func store(_ uid: UInt32, flag: ImapStoredFlag, set: Bool) async throws {}
    func move(_ uid: UInt32, to destination: String) async throws -> ImapCopy? { nil }
    func copy(_ uid: UInt32, to destination: String) async throws -> ImapCopy? { nil }
    func expunge(_ uid: UInt32) async throws {}
    func append(_ folder: String, message: Data) async throws {}
    func close() async { lock.withLock { closed = true } }
  }

  struct SyntheticSmtp: SmtpProvider {
    func verify(_ account: SmtpAccount, password: String) async throws {}
    func send(
      _ account: SmtpAccount, password: String, from: String, to: [String], message: Data
    ) async throws {}
  }
#endif
