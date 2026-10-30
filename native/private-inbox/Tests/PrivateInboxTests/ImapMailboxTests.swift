import Foundation
import Network
import Testing

@testable import PrivateInbox

// A controlled IMAP server: logins and folder reads answer as configured, and every request names
// the account and password it presented.
final class ControlledImap: ImapProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [(String, String)] = []
  var failure: ImapFailure?
  static let messages = [
    ImapEnvelope(
      uid: 11, flags: ["\\Seen"], received: 1_760_000_000_000, size: 120,
      sender: "Synthetic Sender", address: "sender@example.invalid", subject: "Synthetic")
  ]

  func requests() -> [(String, String)] {
    lock.withLock { calls }
  }
  private func record(_ operation: String, _ password: String) throws {
    try lock.withLock {
      calls.append((operation, password))
      if let failure { throw failure }
    }
  }
  func verify(_ account: ImapAccount, password: String) async throws {
    try record("verify", password)
  }
  // Sessions opened, in order; with `holdFolders`, a session's folder listing waits for its close.
  var holdFolders = false
  private var opened: [ControlledImapSession] = []
  func sessions() -> [ControlledImapSession] { lock.withLock { opened } }
  func open(_ account: ImapAccount, password: String) async throws -> any ImapSession {
    try record("open", password)
    let session = ControlledImapSession(hold: holdFolders)
    lock.withLock { opened.append(session) }
    return session
  }
  func message(
    _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32, uid: UInt32,
    limit: Int
  ) async throws -> Data {
    try record("message \(folder) \(uidValidity) \(uid)", password)
    return Data("Subject: Synthetic\r\n\r\nBody".utf8)
  }
  func history(_ account: ImapAccount, password: String, request: ImapHistoryRequest) async throws
    -> ImapHistoryPage
  {
    try record("history \(request.folder) \(request.below ?? 0)", password)
    return ImapHistoryPage(
      uidValidity: 7, uidNext: 12, total: Self.messages.count, messages: Self.messages, below: 1, present: request.known)
  }
  func headers(
    _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32, uids: [UInt32]
  ) async throws -> [ImapHeaders] {
    try record("headers \(folder) \(uidValidity) \(uids)", password)
    return uids.map {
      ImapHeaders(uid: $0, fields: [ImapHeaderField(name: "content-type", value: "text/plain")])
    }
  }
  // Sent copies filed by boundary, as the server would hold them.
  private var filed: [String: Data] = [:]
  func copy(_ boundary: String) -> Data? { lock.withLock { filed[boundary] } }
  func findSent(_ account: ImapAccount, password: String, folder: String, boundary: String)
    async throws -> Int
  {
    try record("find \(folder) \(boundary)", password)
    return lock.withLock { filed[boundary] == nil ? 0 : 1 }
  }
  func fileSent(
    _ account: ImapAccount, password: String, folder: String, boundary: String, message: Data
  ) async throws {
    try record("file \(folder) \(boundary)", password)
    lock.withLock { filed[boundary] = filed[boundary] ?? message }
  }
}

// A controlled session: it lists the Inbox, records each change command and its close. With `hold`,
// a listing waits for `release()`, as SwiftMail's command waits for the server's reply even after
// the session closes. IDLE on the Inbox reports new mail; on any other folder it waits until the
// session closes.
final class ControlledImapSession: ImapSession, @unchecked Sendable {
  private let lock = NSLock()
  private let hold: Bool
  private var held: CheckedContinuation<Void, Never>?
  private var idling: CheckedContinuation<Void, Never>?
  private var ended = false
  private var issued: [String] = []
  init(hold: Bool) { self.hold = hold }

  var waiting: Bool { lock.withLock { held != nil || idling != nil } }
  var closed: Bool { lock.withLock { ended } }
  var commands: [String] { lock.withLock { issued } }
  private func command(_ text: String) { lock.withLock { issued.append(text) } }
  func release() {
    lock.withLock {
      held?.resume()
      held = nil
    }
  }
  func capabilities() async throws -> [String] { ["IMAP4rev1", "MOVE"] }
  func examine(_ folder: String) async throws -> ImapSelection {
    ImapSelection(uidValidity: 7, uidNext: 12, messages: ControlledImap.messages.count)
  }
  func envelopes(_ read: ImapEnvelopeRead) async throws -> [ImapEnvelope] {
    ControlledImap.messages
  }
  func search(_ folder: String, query: String, newest: Int) async throws -> ImapMatches {
    ImapMatches(uidValidity: 7, uids: [11], total: 2)
  }
  func folders() async throws -> [ImapListedFolder] {
    if hold {
      await withCheckedContinuation { continuation in lock.withLock { held = continuation } }
    }
    return [ImapListedFolder(name: "INBOX", attributes: ["\\HasNoChildren"], delimiter: "/")]
  }
  func select(_ folder: String) async throws -> UInt32 {
    command("select \(folder)")
    return 7
  }
  func flags(_ uids: [UInt32]) async throws -> [UInt32: [String]] {
    command("flags \(uids)")
    return [uids[0]: ["\\Seen"]]
  }
  func store(_ uid: UInt32, flag: ImapStoredFlag, set: Bool) async throws {
    command("store \(uid) \(flag.rawValue) \(set)")
  }
  func move(_ uid: UInt32, to destination: String) async throws -> ImapCopy? {
    command("move \(uid) \(destination)")
    return ImapCopy(uidValidity: 9, uid: 21)
  }
  func copy(_ uid: UInt32, to destination: String) async throws -> ImapCopy? {
    command("copy \(uid) \(destination)")
    return nil
  }
  func expunge(_ uid: UInt32) async throws { command("expunge \(uid)") }
  func idle(folder: String, seconds: Int) async throws -> [String] {
    guard folder != "INBOX" else { return ["exists"] }
    await withCheckedContinuation { continuation in
      lock.withLock {
        if ended { continuation.resume() } else { idling = continuation }
      }
    }
    throw ImapFailure.offline
  }
  func close() async {
    lock.withLock {
      ended = true
      idling?.resume()
      idling = nil
    }
  }
}

// A controlled SMTP server: logins and submissions answer as configured, and each names the
// endpoint and password it presented.
final class ControlledSmtp: SmtpProvider, @unchecked Sendable {
  struct Submission: Equatable {
    let account: SmtpAccount
    let password: String
    let from: String
    let to: [String]
    let message: Data
  }
  private let lock = NSLock()
  private var verified: [(SmtpAccount, String)] = []
  private var submitted: [Submission] = []
  var failure: (any Error)?

  func logins() -> [(SmtpAccount, String)] { lock.withLock { verified } }
  func submissions() -> [Submission] { lock.withLock { submitted } }

  func verify(_ account: SmtpAccount, password: String) async throws {
    try lock.withLock {
      verified.append((account, password))
      if let failure { throw failure }
    }
  }
  func send(
    _ account: SmtpAccount, password: String, from: String, to: [String], message: Data
  ) async throws {
    try lock.withLock {
      if let failure { throw failure }
      submitted.append(
        Submission(account: account, password: password, from: from, to: to, message: message))
    }
  }
}

extension PrivateInboxTests {
  // An IMAP connection keeps its password in the device record only, never reaches Google, and its
  // reads stay with the connection generation that verified it.
  // A signed-in store over a controlled IMAP server; `cleanup` removes its device records.
  @MainActor private func imapStore(_ imap: ControlledImap, google: SyntheticGoogleRegistrationProvider)
    async throws -> (store: RegistrationStore, cleanup: () -> Void)
  {
    let service = "dev.unwired.registration.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keys = DeviceKeychain(service: service)
    let store = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, imap: imap, smtp: ControlledSmtp(),
      mailCache: PrivateInboxStore(directory: directory, service: service),
      connect: { identity, _, _ in
        ProductRegistrationReceipt(
          productAccountId: "account-" + identity.subject, trustedDeviceId: "synthetic-device",
          trustedDeviceCredential: String(repeating: "a", count: 64))
      })
    _ = try await store.signIn()
    return (
      store,
      {
        try? keys.remove("registration")
        try? DeviceKeychain(service: service + ".database").remove("encryption-key")
        try? FileManager.default.removeItem(at: directory)
      }
    )
  }

  @Test @MainActor func imapConnectionKeepsItsPasswordAndGeneration() async throws {
    let google = SyntheticGoogleRegistrationProvider()
    let imap = ControlledImap()
    let smtp = try SmtpAccount(
      host: "smtp.example.invalid", port: 465, startTLS: false, username: "alex")
    let (store, cleanup) = try await imapStore(imap, google: google)
    defer { cleanup() }
    let account = try ImapAccount(host: "IMAP.Example.Invalid", port: 993, username: "alex")
    #expect(account.host == "imap.example.invalid")
    for (host, port, username) in [
      ("example", 993, "alex"), ("imap.example.invalid", 0, "alex"),
      ("imap.example.invalid", 993, ""), ("imap.example.invalid", 993, "alex\r\nA1 LOGOUT"),
      ("-imap.example.invalid", 993, "alex"),
    ] {
      #expect(throws: RegistrationError.unavailable) {
        _ = try ImapAccount(host: host, port: port, username: username)
      }
    }

    // A refused login stores nothing.
    imap.failure = .authentication
    await #expect(throws: ImapFailure.authentication) {
      _ = try await store.connectImap(
        address: "alex@example.invalid", account: account, password: "app-password", smtp: smtp,
        smtpPassword: nil)
    }
    #expect(try store.saved().connections.isEmpty)
    imap.failure = nil
    let reply = try await store.connectImap(
      address: "alex@example.invalid", account: account, password: "app-password", smtp: smtp,
      smtpPassword: nil)
    let id = try #require(reply["connection"] as? String)
    #expect(id == MailboxConnection.id(subject: "imap:imap.example.invalid:993:alex"))
    let projection = try #require(try store.registration())
    let listed = try #require((projection["mailboxes"] as? [[String: Any]])?.first)
    #expect(listed["provider"] as? String == "imap")
    #expect(
      listed["imap"] as? [String: AnyHashable]
        == ["host": "imap.example.invalid", "port": 993, "username": "alex"])
    #expect(listed["access"] as? String == "verified")
    let encoded = try JSONSerialization.data(withJSONObject: projection)
    #expect(encoded.range(of: Data("app-password".utf8)) == nil)

    // Gmail paths never present the IMAP password to Google.
    let generation = store.mailboxGeneration(id).uuidString
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.refreshMailbox(id)
    }
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.gmail(
        path: "profile", query: [], connection: id, address: "alex@example.invalid",
        generation: generation)
    }
    #expect(google.gmailRequests.isEmpty && google.refreshes == 0)

    let session = try #require(
      try await store.imapOpen(
        connection: id, address: "alex@example.invalid", generation: generation)["session"]
        as? String)
    let folders = try await store.imapListFolders(
      connection: id, address: "alex@example.invalid", generation: generation, session: session)
    let folder = try #require((folders["folders"] as? [[String: Any]])?.first)
    #expect(folder["name"] as? String == "INBOX" && folder["delimiter"] as? String == "/")
    #expect(folder["attributes"] as? [String] == ["\\HasNoChildren"])
    let capabilities = try await store.imapCapabilities(
      connection: id, address: "alex@example.invalid", generation: generation, session: session)
    #expect(capabilities["capabilities"] as? [String] == ["IMAP4rev1", "MOVE"])
    let selection = try await store.imapExamine(
      connection: id, address: "alex@example.invalid", generation: generation, session: session,
      folder: "INBOX")
    #expect(selection["uidValidity"] as? Double == 7 && selection["messages"] as? Double == 1)
    let envelopes = try await store.imapEnvelopes(
      connection: id, address: "alex@example.invalid", generation: generation, session: session,
      read: .newest(count: 200, total: 1))
    #expect((envelopes["messages"] as? [[String: Any]])?.first?["uid"] as? Double == 11)
    let flags = try await store.imapFlags(
      connection: id, address: "alex@example.invalid", generation: generation, session: session,
      uids: [11])
    #expect((flags["flags"] as? [[String: Any]])?.first?["flags"] as? [String] == ["\\Seen"])
    let matches = try await store.imapSearch(
      connection: id, address: "alex@example.invalid", generation: generation, session: session,
      folder: "INBOX", query: "Synthetic", newest: 50)
    #expect(matches["uidValidity"] as? Double == 7 && matches["uids"] as? [Double] == [11])
    #expect(matches["total"] as? Double == 2)
    store.imapClose(connection: id, session: session)
    let message = try await store.imapMessage(
      connection: id, address: "alex@example.invalid", generation: generation, folder: "INBOX",
      uidValidity: 7, uid: 11)
    #expect(message["data"] as? String == Data("Subject: Synthetic\r\n\r\nBody".utf8).base64EncodedString())
    let headers = try await store.imapHeaders(
      connection: id, address: "alex@example.invalid", generation: generation, folder: "INBOX",
      uidValidity: 7, uids: [11])
    #expect(
      (headers["messages"] as? [[String: Any]])?.first?["headers"] as? [[String: String]] == [
        ["name": "content-type", "value": "text/plain"]
      ])
    // A preflight names between one and 20 messages.
    for uids in [[], [UInt32](repeating: 11, count: 21), [0]] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.imapHeaders(
          connection: id, address: "alex@example.invalid", generation: generation,
          folder: "INBOX", uidValidity: 7, uids: uids)
      }
    }

    let watching = try #require(
      try await store.imapOpen(
        connection: id, address: "alex@example.invalid", generation: generation)["session"]
        as? String)
    let idle = try await store.imapIdle(
      connection: id, address: "alex@example.invalid", generation: generation, session: watching,
      folder: "INBOX", seconds: 300)
    #expect(idle["events"] as? [String] == ["exists"])
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.imapIdle(
        connection: id, address: "alex@example.invalid", generation: generation, session: watching,
        folder: "INBOX", seconds: 601)
    }
    store.imapClose(connection: id, session: watching)
    #expect(imap.requests().allSatisfy { $0.1 == "app-password" })
    for read in [ImapEnvelopeRead.newest(count: 201, total: 300), .uids([]), .uids([0]), .from(0)] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.imapEnvelopes(
          connection: id, address: "alex@example.invalid", generation: generation,
          session: "session", read: read)
      }
    }
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.imapFlags(
        connection: id, address: "alex@example.invalid", generation: generation,
        session: "session", uids: Array(1...201))
    }
    for (folder, query, newest) in [
      ("", "Synthetic", 50), ("INBOX", "", 50), ("INBOX", "a\r\nA1 LOGOUT", 50),
      ("INBOX", String(repeating: "a", count: 201), 50), ("INBOX", "Synthetic", 0),
      ("INBOX", "Synthetic", 201),
    ] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.imapSearch(
          connection: id, address: "alex@example.invalid", generation: generation,
          session: "session", folder: folder, query: query, newest: newest)
      }
    }

    // Work from before a removal or another verification is discarded.
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.imapOpen(
        connection: id, address: "alex@example.invalid", generation: UUID().uuidString)
    }
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.imapOpen(
        connection: id, address: "other@example.invalid", generation: generation)
    }
    // A refused password asks for it again instead of reading as a transient failure.
    imap.failure = .authentication
    await #expect(throws: RegistrationError.gmailUnavailable) {
      _ = try await store.imapOpen(
        connection: id, address: "alex@example.invalid", generation: generation)
    }
    imap.failure = nil
    // A connection waiting for its password reaches no server, as a refused Gmail grant does.
    try store.markMailbox(id, access: "authorization")
    await #expect(throws: RegistrationError.gmailUnavailable) {
      _ = try await store.imapOpen(
        connection: id, address: "alex@example.invalid", generation: generation)
    }
    try await store.verifyImap(id)
    #expect(try store.saved().connection(id)?.authorizationNeeded == nil)
    #expect(store.verifiedMailboxes.contains(id))

    // Adding the same account again repairs the connection with the new password.
    _ = try await store.connectImap(
      address: "alex@example.invalid", account: account, password: "new-password", smtp: smtp,
      smtpPassword: nil)
    #expect(try store.saved().connections.count == 1)
    #expect(try store.saved().connection(id)?.credential == Data("new-password".utf8))
    #expect(try store.saved().connection(id)?.receipt.account == "imap:imap.example.invalid:993:alex")
  }

  // A session answers one command at a time, only for the connection generation that opened it, and
  // closes when that generation changes, when it stays unused, or when TypeScript closes it.
  @Test @MainActor func imapSessionsStayWithTheirConnectionGeneration() async throws {
    let imap = ControlledImap()
    let (store, cleanup) = try await imapStore(imap, google: SyntheticGoogleRegistrationProvider())
    defer { cleanup() }
    let address = "alex@example.invalid"
    let account = try ImapAccount(host: "imap.example.invalid", port: 993, username: "alex")
    let smtp = try SmtpAccount(
      host: "smtp.example.invalid", port: 465, startTLS: false, username: "alex")
    let id = try #require(
      try await store.connectImap(
        address: address, account: account, password: "app-password", smtp: smtp,
        smtpPassword: nil)["connection"] as? String)
    var generation = store.mailboxGeneration(id).uuidString
    func open() async throws -> String {
      try #require(
        try await store.imapOpen(connection: id, address: address, generation: generation)["session"]
          as? String)
    }
    func list(_ session: String, connection: String? = nil, address other: String? = nil)
      async throws
    {
      _ = try await store.imapListFolders(
        connection: connection ?? id, address: other ?? address, generation: generation,
        session: session)
    }
    func settled(_ sessions: [ControlledImapSession]) async throws {
      for _ in 0..<100 where !sessions.allSatisfy(\.closed) {
        try await Task.sleep(for: .milliseconds(10))
      }
      let closed = sessions.allSatisfy(\.closed)
      #expect(closed)
    }

    // An unused session closes by itself.
    store.imapSessionLimits.idle = .milliseconds(30)
    _ = try await open()
    for _ in 0..<100 where !store.imapHandles.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(store.imapHandles.isEmpty)
    try await settled(imap.sessions())
    store.imapSessionLimits.idle = .seconds(60)

    let session = try await open()
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      try await list(session, connection: "another-connection")
    }
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      try await list(session, address: "other@example.invalid")
    }
    await #expect(throws: PrivateInboxError.mailboxInvalidated) { try await list("unknown") }

    // Organizing names one message by its UID in the folder the session selected; a move answers
    // where COPYUID says the message went, a copy without a receipt answers nothing.
    #expect(
      try await store.imapSelect(
        connection: id, address: address, generation: generation, session: session, folder: "INBOX"
      )["uidValidity"] as? Double == 7)
    let flags = try await store.imapFlags(
      connection: id, address: address, generation: generation, session: session, uids: [11])
    #expect((flags["flags"] as? [[String: Any]])?.first?["uid"] as? Double == 11)
    #expect(
      try await store.imapStore(
        connection: id, address: address, generation: generation, session: session, uid: 11,
        flag: .seen, set: true
      ).isEmpty)
    let moved = try await store.imapMove(
      connection: id, address: address, generation: generation, session: session, uid: 11,
      destination: "Archive")
    #expect(moved["uidValidity"] as? Double == 9 && moved["uid"] as? Double == 21)
    #expect(
      try await store.imapCopy(
        connection: id, address: address, generation: generation, session: session, uid: 11,
        destination: "Archive"
      ).isEmpty)
    #expect(
      try await store.imapExpunge(
        connection: id, address: address, generation: generation, session: session, uid: 11
      ).isEmpty)
    let organized = try #require(imap.sessions().last)
    #expect(
      organized.commands == [
        "select INBOX", "flags [11]", "store 11 seen true", "move 11 Archive", "copy 11 Archive",
        "expunge 11",
      ])
    // A request without a folder name or a positive UID reaches no server.
    let invalid: [@MainActor () async throws -> [String: Any]] = [
      {
        try await store.imapSelect(
          connection: id, address: address, generation: generation, session: session, folder: "")
      },
      {
        try await store.imapFlags(
          connection: id, address: address, generation: generation, session: session, uids: [])
      },
      {
        try await store.imapFlags(
          connection: id, address: address, generation: generation, session: session,
          uids: [UInt32](repeating: 11, count: 201))
      },
      {
        try await store.imapFlags(
          connection: id, address: address, generation: generation, session: session, uids: [0])
      },
      {
        try await store.imapStore(
          connection: id, address: address, generation: generation, session: session, uid: 0,
          flag: .seen, set: true)
      },
      {
        try await store.imapMove(
          connection: id, address: address, generation: generation, session: session, uid: 11,
          destination: "")
      },
      {
        try await store.imapCopy(
          connection: id, address: address, generation: generation, session: session, uid: 0,
          destination: "Archive")
      },
      {
        try await store.imapExpunge(
          connection: id, address: address, generation: generation, session: session, uid: 0)
      },
    ]
    for request in invalid {
      await #expect(throws: RegistrationError.unavailable) { _ = try await request() }
    }
    #expect(organized.commands.count == 6)

    // One command at a time: another is refused while the first waits for the server. Closing the
    // session answers the waiting command at once, before the server replies.
    func holding() async throws -> (String, Task<Void, any Error>, ControlledImapSession) {
      imap.holdFolders = true
      defer { imap.holdFolders = false }
      let held = try await open()
      let listing = Task { try await list(held) }
      let waiting = try #require(imap.sessions().last)
      for _ in 0..<100 where !waiting.waiting { try await Task.sleep(for: .milliseconds(10)) }
      #expect(waiting.waiting)
      return (held, listing, waiting)
    }
    var (held, listing, waiting) = try await holding()
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.imapCapabilities(
        connection: id, address: address, generation: generation, session: held)
    }
    store.imapClose(connection: id, session: held)
    await #expect(throws: PrivateInboxError.mailboxInvalidated) { try await listing.value }
    #expect(waiting.waiting)
    waiting.release()
    try await settled([waiting])
    await #expect(throws: PrivateInboxError.mailboxInvalidated) { try await list(held) }

    // Closing a session in IDLE answers the wait at once and ends it.
    let watching = try await open()
    let wait = Task {
      _ = try await store.imapIdle(
        connection: id, address: address, generation: generation, session: watching,
        folder: "Archive", seconds: 600)
    }
    let idling = try #require(imap.sessions().last)
    for _ in 0..<100 where !idling.waiting { try await Task.sleep(for: .milliseconds(10)) }
    #expect(idling.waiting)
    store.imapClose(connection: id, session: watching)
    await #expect(throws: PrivateInboxError.mailboxInvalidated) { try await wait.value }
    try await settled([idling])
    #expect(!idling.waiting)

    // A session open too long closes too, even with a command waiting; so does `session`.
    (held, listing, waiting) = try await holding()
    store.imapSessionLimits.lifetime = .milliseconds(50)
    try await Task.sleep(for: .milliseconds(100))
    store.closeStaleImapSessions()
    await #expect(throws: PrivateInboxError.mailboxInvalidated) { try await listing.value }
    waiting.release()
    try await settled([waiting])
    store.imapSessionLimits.lifetime = .seconds(900)

    // At most four per connection; a new connection generation closes them all.
    for _ in 0..<4 { _ = try await open() }
    let logins = imap.sessions().count
    await #expect(throws: RegistrationError.unavailable) { _ = try await open() }
    #expect(imap.sessions().count == logins)
    _ = try await store.connectImap(
      address: address, account: account, password: "app-password", smtp: smtp, smtpPassword: nil)
    #expect(store.imapHandles.isEmpty)
    try await settled(imap.sessions())
    await #expect(throws: PrivateInboxError.mailboxInvalidated) { try await list(session) }
    generation = store.mailboxGeneration(id).uuidString

    // Signing out of mailbox access closes sessions, and so does removing the connection.
    try await list(try await open())
    store.forgetMailboxAccess()
    #expect(store.imapHandles.isEmpty)
    try await store.verifyImap(id)
    generation = store.mailboxGeneration(id).uuidString
    _ = try await open()
    try await store.forgetConnection(id)
    #expect(store.imapHandles.isEmpty)
    try await settled(imap.sessions())
  }

  // Secure Mail Transport: a server that answers in plaintext on the IMAPS port is never logged in
  // to; the real SwiftMail engine fails before any credential is sent.
  @Test func swiftMailRefusesAPlaintextServer() async throws {
    let received = ReceivedBytes()
    let listener = try NWListener(using: .tcp, on: .any)
    listener.newConnectionHandler = { connection in
      connection.start(queue: .global())
      connection.send(
        content: Data("* OK IMAP4rev1 plaintext\r\n".utf8), completion: .contentProcessed { _ in })
      func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, _ in
          if let data { received.append(data) }
          if !done { receive() }
        }
      }
      receive()
    }
    let ready = AsyncStream<UInt16> { continuation in
      listener.stateUpdateHandler = { state in
        if case .ready = state { continuation.yield(listener.port?.rawValue ?? 0) }
      }
    }
    listener.start(queue: .global())
    defer { listener.cancel() }
    var iterator = ready.makeAsyncIterator()
    let port = try #require(await iterator.next())
    // Endpoint review never accepts a loopback address; only a saved record could carry one.
    let local = try JSONDecoder().decode(
      ImapAccount.self,
      from: Data(#"{"host":"127.0.0.1","port":\#(port),"username":"alex"}"#.utf8))
    await #expect(throws: ImapFailure.insecure) {
      try await SwiftMailImap().verify(local, password: "app-password")
    }
    #expect(received.data().range(of: Data("app-password".utf8)) == nil)
    #expect(received.data().range(of: Data("LOGIN".utf8)) == nil)
  }

  // The integration runner trusts its own synthetic CA only on its owned simulator. This exercises
  // the unchanged native engine and verified TLS, rather than an ImapProvider substitute.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["UNWIRED_IMAP_TLS_TEST_PORT"] != nil))
  func swiftMailReadsVerifiedTLSAndBoundsBodies() async throws {
    let port = try #require(Int(ProcessInfo.processInfo.environment["UNWIRED_IMAP_TLS_TEST_PORT"] ?? ""))
    let account = try JSONDecoder().decode(
      ImapAccount.self,
      from: Data(#"{"host":"localhost","port":\#(port),"username":"synthetic"}"#.utf8))
    let provider = SwiftMailImap()
    let mismatchedHost = try JSONDecoder().decode(
      ImapAccount.self,
      from: Data(#"{"host":"127.0.0.1","port":\#(port),"username":"synthetic"}"#.utf8))
    await #expect(throws: ImapFailure.insecure) {
      try await provider.verify(mismatchedHost, password: "synthetic-password")
    }
    await #expect(throws: ImapFailure.authentication) {
      try await provider.verify(account, password: "refused")
    }
    try await provider.verify(account, password: "synthetic-password")
    // One session lists every folder with its LIST attributes, and the server's capabilities.
    func listed(_ account: ImapAccount) async throws -> ([ImapListedFolder], [String]) {
      let session = try await provider.open(account, password: "synthetic-password")
      do {
        let result = (try await session.folders(), try await session.capabilities())
        await session.close()
        return result
      } catch {
        await session.close()
        throw error
      }
    }
    let (folders, capabilities) = try await listed(account)
    // swift-nio-imap reports any ASCII case of INBOX as `INBOX`.
    #expect(folders.map(\.name) == ["INBOX", "Archive", "ınbox", "Primary"])
    #expect(
      folders.map(\.attributes) == [
        ["\\HasNoChildren"], ["\\HasNoChildren", "\\Archive"], ["\\HasNoChildren"],
        ["\\HasNoChildren", "\\Inbox"],
      ])
    #expect(folders.allSatisfy { $0.delimiter == "/" })
    #expect(Set(capabilities.map { $0.uppercased() }).isSuperset(of: ["MOVE", "UIDPLUS", "IDLE"]))
    let overflowing = try JSONDecoder().decode(
      ImapAccount.self,
      from: Data(#"{"host":"localhost","port":\#(port),"username":"many-folders"}"#.utf8))
    await #expect(throws: RegistrationError.unavailable) { _ = try await listed(overflowing) }
    let atLimit = try JSONDecoder().decode(
      ImapAccount.self,
      from: Data(#"{"host":"localhost","port":\#(port),"username":"folder-limit"}"#.utf8))
    await #expect(throws: RegistrationError.unavailable) { _ = try await listed(atLimit) }
    let full = try JSONDecoder().decode(
      ImapAccount.self,
      from: Data(#"{"host":"localhost","port":\#(port),"username":"folders-at-limit"}"#.utf8))
    #expect(try await listed(full).0.count == 1_000)
    let undiscovered = try JSONDecoder().decode(
      ImapAccount.self,
      from: Data(#"{"host":"localhost","port":\#(port),"username":"namespace-failure"}"#.utf8))
    await #expect(throws: (any Error).self) { _ = try await listed(undiscovered) }
    let namespaced = try JSONDecoder().decode(
      ImapAccount.self,
      from: Data(#"{"host":"localhost","port":\#(port),"username":"namespaced"}"#.utf8))
    let (shared, sharedCapabilities) = try await listed(namespaced)
    #expect(shared.map(\.name) == ["INBOX", "Archive", "ınbox", "Primary", "Shared/Team"])
    #expect(Set(sharedCapabilities.map { $0.uppercased() }).isDisjoint(with: ["MOVE", "UIDPLUS", "IDLE"]))
    // One session examines folders and reads their envelopes and flags, as a synchronization
    // does.
    let reading = try await provider.open(account, password: "synthetic-password")
    do {
      #expect(
        try await reading.examine("INBOX") == ImapSelection(uidValidity: 7, uidNext: 12, messages: 1))
      let newest = try await reading.envelopes(.newest(count: 200, total: 1))
      #expect(newest.map(\.uid) == [11] && newest.first?.subject == "Controlled IMAP")
      #expect(try await reading.envelopes(.uids([11])).map(\.uid) == [11])
      #expect(try await reading.flags([11]) == [11: ["\\Flagged"]])
      // A large folder whose UIDNEXT has not moved is read by its known flags alone.
      #expect(
        try await reading.examine("Large") == ImapSelection(uidValidity: 7, uidNext: 512, messages: 500))
      #expect(try await reading.flags([511]) == [511: ["\\Flagged"]])
      // Expunged arrivals advance UIDNEXT too: they are read by UID, never by sequence number,
      // which the server rejects. `UID 12:*` still names the newest message, below 12.
      #expect(try await reading.examine("Sparse") == ImapSelection(uidValidity: 7, uidNext: 402, messages: 1))
      #expect(try await reading.envelopes(.from(12)).map(\.uid) == [11])
      await reading.close()
    } catch {
      await reading.close()
      throw error
    }
    let raw = try await provider.message(
      account, password: "synthetic-password", folder: "INBOX", uidValidity: 7, uid: 11,
      limit: RegistrationStore.imapMessageLimit)
    #expect(String(decoding: raw, as: UTF8.self).hasSuffix("Controlled body\r\n"))
    // Prefetch's preflight reads only the MIME header fields, unfolded, and no body.
    let described = try await provider.headers(
      account, password: "synthetic-password", folder: "INBOX", uidValidity: 7, uids: [11])
    #expect(
      described == [
        ImapHeaders(
          uid: 11,
          fields: [ImapHeaderField(name: "content-type", value: "text/plain; charset=utf-8")])
      ])
    await #expect(throws: ImapFailure.changed) {
      _ = try await provider.headers(
        account, password: "synthetic-password", folder: "INBOX", uidValidity: 8, uids: [11])
    }
    // The server declares a header literal beyond its bound and sends none of it: the
    // read is refused before buffering, without waiting for SwiftMail's command timeout.
    await #expect(throws: ImapFailure.tooLarge) {
      _ = try await provider.headers(
        account, password: "synthetic-password", folder: "INBOX", uidValidity: 7, uids: [12])
    }
    await #expect(throws: ImapFailure.changed) {
      _ = try await provider.message(
        account, password: "synthetic-password", folder: "INBOX", uidValidity: 8, uid: 11,
        limit: RegistrationStore.imapMessageLimit)
    }
    // SwiftMail reports zero when the server's EXAMINE omits UIDVALIDITY. Neither metadata nor
    // bodies may be fetched or cached under that unestablished identity.
    let unidentified = try await provider.open(account, password: "synthetic-password")
    await #expect(throws: ImapFailure.changed) { _ = try await unidentified.examine("NoValidity") }
    await unidentified.close()
    await #expect(throws: ImapFailure.changed) {
      _ = try await provider.message(
        account, password: "synthetic-password", folder: "NoValidity", uidValidity: 0, uid: 11,
        limit: RegistrationStore.imapMessageLimit)
    }
    // The server lies in RFC822.SIZE, declares an oversized BODY[], and sends no body bytes.
    // Without the parser bound this waits for SwiftMail's 10-second command timeout.
    do {
      _ = try await provider.message(
        account, password: "synthetic-password", folder: "INBOX", uidValidity: 7, uid: 12,
        limit: RegistrationStore.imapMessageLimit)
      Issue.record("Expected the oversized wire declaration to fail")
    } catch {
      #expect(String(reflecting: Swift.type(of: error)).hasSuffix("IMAPDecoderError"))
    }
    // Refusal closes its session and leaves later independent work usable.
    try await provider.verify(account, password: "synthetic-password")
  }
}

extension PrivateInboxTests {
  // Organizing, server search and IDLE through the unchanged engine over verified TLS, including
  // servers without MOVE, and without MOVE and UIDPLUS.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["UNWIRED_IMAP_TLS_TEST_PORT"] != nil))
  func swiftMailOrganizesSearchesAndWaitsOverVerifiedTLS() async throws {
    let port = try #require(Int(ProcessInfo.processInfo.environment["UNWIRED_IMAP_TLS_TEST_PORT"] ?? ""))
    func account(_ user: String) throws -> ImapAccount {
      try JSONDecoder().decode(
        ImapAccount.self,
        from: Data(#"{"host":"localhost","port":\#(port),"username":"\#(user)"}"#.utf8))
    }
    let provider = SwiftMailImap()
    let synthetic = try account("synthetic")
    let password = "synthetic-password"
    // TypeScript runs each organizing step in a session of its own.
    func organize(
      _ user: String = "synthetic", _ work: (any ImapSession) async throws -> Void
    ) async throws {
      let session = try await provider.open(try account(user), password: password)
      do {
        try await work(session)
      } catch {
        await session.close()
        throw error
      }
      await session.close()
    }
    try await organize { session in
      #expect(try await session.select("INBOX") == 7)
      #expect(try await session.flags([11]).keys.sorted() == [11])
      // A missing UID cannot target a different message.
      #expect(try await session.flags([13]).isEmpty)
      for flag in [ImapStoredFlag.seen, .flagged] {
        for set in [true, false] { try await session.store(11, flag: flag, set: set) }
      }
      #expect(try await session.move(11, to: "Archive") == ImapCopy(uidValidity: 9, uid: 21))
    }
    await #expect(throws: ImapFailure.missing) {
      try await organize { _ = try await $0.select("Gone") }
    }
    await #expect(throws: ImapFailure.changed) {
      try await organize { _ = try await $0.select("NoValidity") }
    }
    // MOVE's tagged failure can follow partial completion, with or without a mapping, and a
    // connection lost after the change was sent may have applied it.
    for destination in ["Missing", "Partial", "Drop"] {
      await #expect(throws: ImapFailure.interrupted) {
        try await organize { session in
          _ = try await session.select("INBOX")
          _ = try await session.move(11, to: destination)
        }
      }
    }
    // Without MOVE, UIDPLUS returns the copy receipt before deletion; resumption reuses that
    // receipt, finds the copy and deletes only the source.
    try await organize("no-move") { session in
      _ = try await session.select("INBOX")
      #expect(try await session.copy(11, to: "Unmapped") == nil)
      await #expect(throws: ImapFailure.unsupported) { _ = try await session.move(11, to: "Archive") }
      #expect(try await session.copy(11, to: "Archive") == ImapCopy(uidValidity: 9, uid: 22))
    }
    await #expect(throws: ImapFailure.interrupted) {
      try await organize("no-move") { session in
        _ = try await session.select("INBOX")
        _ = try await session.copy(11, to: "DropCopy")
      }
    }
    try await organize("no-move") { session in
      #expect(try await session.select("Archive") == 9)
      #expect(try await session.flags([22]).keys.sorted() == [22])
      #expect(try await session.flags([23]).isEmpty)
      #expect(try await session.select("INBOX") == 7)
      try await session.store(11, flag: .deleted, set: true)
      try await session.expunge(11)
    }
    // Without MOVE or UIDPLUS, SwiftMail refuses before sending anything.
    try await organize("namespaced") { session in
      _ = try await session.select("INBOX")
      await #expect(throws: ImapFailure.unsupported) { _ = try await session.move(11, to: "Archive") }
      await #expect(throws: ImapFailure.unsupported) { try await session.expunge(11) }
    }

    // A session's search examines the folder; one the server no longer selects is refused.
    let searching = try await provider.open(synthetic, password: password)
    do {
      #expect(
        try await searching.search("INBOX", query: "Controlled", newest: 50)
          == ImapMatches(uidValidity: 7, uids: [11], total: 1))
      await #expect(throws: ImapFailure.missing) {
        _ = try await searching.search("Gone", query: "Controlled", newest: 50)
      }
      await searching.close()
    } catch {
      await searching.close()
      throw error
    }
    // A compressed ESEARCH range yields only the newest bounded window, without expanding
    // billions of identifiers supplied by an untrusted server, and its envelopes alone are read.
    let largeSearch = try await provider.open(try account("large-search"), password: password)
    do {
      let matches = try await largeSearch.search("INBOX", query: "Controlled", newest: 50)
      #expect(matches.uids == Array((3_999_999_951...4_000_000_000).reversed()))
      #expect(matches.total == 4_000_000_000)
      #expect(try await largeSearch.envelopes(.uids(matches.uids)).map(\.uid) == [4_000_000_000])
      await largeSearch.close()
    } catch {
      await largeSearch.close()
      throw error
    }
    // A history page searches bounded UID windows newest first, keeps `limit` of them and resumes
    // below the oldest it kept; a billions-wide reported range is clamped to the window.
    let page = try await provider.history(
      try account("history"), password: password,
      request: ImapHistoryRequest(folder: "INBOX", above: 1, below: nil, limit: 2, known: [5, 11]))
    #expect(page.uidValidity == 7 && page.uidNext == 12 && page.total == 1)
    #expect(page.messages.map(\.uid) == [7, 11] || page.messages.map(\.uid) == [11, 7])
    #expect(page.below == 7 && page.present == [11])
    await #expect(throws: ImapFailure.missing) {
      _ = try await provider.history(
        try account("history"), password: password,
        request: ImapHistoryRequest(folder: "Gone", above: 1, below: nil, limit: 2, known: []))
    }

    // IDLE reports the Inbox's new mail at once and ends quietly at its bound in the same session;
    // closing the session ends a wait in progress.
    let watching = try await provider.open(synthetic, password: password)
    #expect(try await watching.idle(folder: "INBOX", seconds: 30) == ["exists"])
    #expect(try await watching.idle(folder: "Quiet", seconds: 1) == [])
    let wait = Task { try await watching.idle(folder: "Quiet", seconds: 30) }
    try await Task.sleep(for: .milliseconds(500))
    let closing = ContinuousClock.now
    await watching.close()
    await #expect(throws: ImapFailure.offline) { _ = try await wait.value }
    #expect(ContinuousClock.now - closing < .seconds(5))
  }
}

private final class ReceivedBytes: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  func append(_ data: Data) { lock.withLock { bytes.append(data) } }
  func data() -> Data { lock.withLock { bytes } }
}
