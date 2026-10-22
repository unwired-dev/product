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
  var state = ImapFolderState(
    uidValidity: 7, uidNext: 12,
    messages: [
      ImapEnvelope(
        uid: 11, flags: ["\\Seen"], received: 1_760_000_000_000, size: 120,
        sender: "Synthetic Sender", address: "sender@example.invalid", subject: "Synthetic")
    ], flags: [:], reset: true)

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
  var outcome = ImapOutcome.moved(uidValidity: 9, uid: 4)
  func folders(_ account: ImapAccount, password: String) async throws -> ImapListing {
    try record("folders", password)
    return ImapListing(
      folders: [ImapFolder(name: "INBOX", roles: ["inbox"], selectable: true, delimiter: "/")], moves: true,
      idle: false)
  }
  func synchronize(
    _ account: ImapAccount, password: String, folder: String, from: ImapCheckpoint?, window: Int
  ) async throws -> ImapFolderState {
    try record("synchronize \(folder)", password)
    return state
  }
  func message(
    _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32, uid: UInt32,
    limit: Int
  ) async throws -> Data {
    try record("message \(folder) \(uidValidity) \(uid)", password)
    return Data("Subject: Synthetic\r\n\r\nBody".utf8)
  }
  func headers(
    _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32, uids: [UInt32]
  ) async throws -> [ImapHeaders] {
    try record("headers \(folder) \(uidValidity) \(uids)", password)
    return uids.map {
      ImapHeaders(uid: $0, fields: [ImapHeaderField(name: "content-type", value: "text/plain")])
    }
  }
  func modify(_ account: ImapAccount, password: String, change: ImapChange) async throws
    -> ImapOutcome
  {
    try record("modify \(change.folder) \(change.uid) \(change.destination ?? "read")", password)
    return outcome
  }
  func search(
    _ account: ImapAccount, password: String, query: String, folders: [String], limit: Int
  ) async throws -> (found: [ImapFound], skipped: Int) {
    try record("search \(folders.joined(separator: ",")) \(limit)", password)
    return ([ImapFound(folder: "INBOX", uidValidity: 7, messages: state.messages, more: true)], 1)
  }
  func idle(_ account: ImapAccount, password: String, folder: String, seconds: Int) async throws
    -> Bool
  {
    try record("idle \(folder) \(seconds)", password)
    return true
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
  @Test @MainActor func imapConnectionKeepsItsPasswordAndGeneration() async throws {
    let service = "dev.unwired.registration.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keys = DeviceKeychain(service: service)
    defer {
      try? keys.remove("registration")
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    let google = SyntheticGoogleRegistrationProvider()
    let imap = ControlledImap()
    let smtp = try SmtpAccount(
      host: "smtp.example.invalid", port: 465, startTLS: false, username: "alex")
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

    let folders = try await store.imapFolders(
      connection: id, address: "alex@example.invalid", generation: generation)
    #expect((folders["folders"] as? [[String: Any]])?.first?["name"] as? String == "INBOX")
    let synchronized = try await store.imapSynchronize(
      connection: id, address: "alex@example.invalid", generation: generation, folder: "INBOX",
      from: nil, window: 200)
    #expect(synchronized["uidValidity"] as? Double == 7)
    #expect((synchronized["messages"] as? [[String: Any]])?.first?["uid"] as? Double == 11)
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
    #expect(folders["moves"] as? Bool == true && folders["idle"] as? Bool == false)

    // Organizing changes one identified message; a move reports where the server put it.
    let moved = try await store.imapModify(
      connection: id, address: "alex@example.invalid", generation: generation,
      change: ImapChange(folder: "INBOX", uidValidity: 7, uid: 11, read: nil, destination: "Archive"))
    #expect(moved["outcome"] as? String == "moved")
    #expect(moved["uidValidity"] as? Double == 9 && moved["uid"] as? Double == 4)
    imap.outcome = .copied(uidValidity: 9, uid: 4)
    let copied = try await store.imapModify(
      connection: id, address: "alex@example.invalid", generation: generation,
      change: ImapChange(folder: "INBOX", uidValidity: 7, uid: 11, read: nil, destination: "Archive"))
    #expect(copied["outcome"] as? String == "copied")
    #expect(copied["uidValidity"] as? Double == 9 && copied["uid"] as? Double == 4)
    imap.outcome = .absent
    let absent = try await store.imapModify(
      connection: id, address: "alex@example.invalid", generation: generation,
      change: ImapChange(folder: "INBOX", uidValidity: 7, uid: 11, read: true, destination: nil))
    #expect(absent as? [String: String] == ["outcome": "absent"])
    // A change names exactly one of read state and a different destination folder.
    for change in [
      ImapChange(folder: "INBOX", uidValidity: 7, uid: 11, read: true, destination: "Archive"),
      ImapChange(folder: "INBOX", uidValidity: 7, uid: 11, read: nil, destination: nil),
      ImapChange(folder: "INBOX", uidValidity: 7, uid: 11, read: nil, destination: "INBOX"),
      ImapChange(
        folder: "INBOX", uidValidity: 7, uid: 11, read: true, destination: nil,
        copied: ImapCopy(uidValidity: 9, uid: 4)),
      ImapChange(
        folder: "INBOX", uidValidity: 7, uid: 11, read: nil, destination: "Archive",
        copied: ImapCopy(uidValidity: 0, uid: 4)),
    ] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.imapModify(
          connection: id, address: "alex@example.invalid", generation: generation, change: change)
      }
    }
    let found = try await store.imapSearch(
      connection: id, address: "alex@example.invalid", generation: generation, query: "Synthetic",
      folders: ["INBOX", "Archive"])
    #expect(found["skipped"] as? Double == 1)
    #expect((found["folders"] as? [[String: Any]])?.first?["more"] as? Bool == true)
    #expect(
      ((found["folders"] as? [[String: Any]])?.first?["messages"] as? [[String: Any]])?.first?["uid"]
        as? Double == 11)
    for (query, folders) in [
      ("", ["INBOX"]), ("a\r\nA1 LOGOUT", ["INBOX"]), ("Synthetic", []),
      ("Synthetic", Array(repeating: "INBOX", count: 51)),
    ] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.imapSearch(
          connection: id, address: "alex@example.invalid", generation: generation, query: query,
          folders: folders)
      }
    }
    let idle = try await store.imapIdle(
      connection: id, address: "alex@example.invalid", generation: generation, folder: "INBOX",
      seconds: 300)
    #expect(idle["changed"] as? Bool == true)
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.imapIdle(
        connection: id, address: "alex@example.invalid", generation: generation, folder: "INBOX",
        seconds: 601)
    }
    #expect(imap.requests().map(\.0).contains("search INBOX,Archive 50"))
    #expect(imap.requests().allSatisfy { $0.1 == "app-password" })
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.imapSynchronize(
        connection: id, address: "alex@example.invalid", generation: generation, folder: "INBOX",
        from: nil, window: 201)
    }

    // Work from before a removal or another verification is discarded.
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.imapFolders(
        connection: id, address: "alex@example.invalid", generation: UUID().uuidString)
    }
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.imapFolders(
        connection: id, address: "other@example.invalid", generation: generation)
    }
    // A refused password asks for it again instead of reading as a transient failure.
    imap.failure = .authentication
    await #expect(throws: RegistrationError.gmailUnavailable) {
      _ = try await store.imapFolders(
        connection: id, address: "alex@example.invalid", generation: generation)
    }
    imap.failure = nil
    // A connection waiting for its password reaches no server, as a refused Gmail grant does.
    try store.markMailbox(id, access: "authorization")
    await #expect(throws: RegistrationError.gmailUnavailable) {
      _ = try await store.imapFolders(
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
    let listing = try await provider.folders(account, password: "synthetic-password")
    #expect(listing.folders.map(\.name) == ["INBOX", "Archive", "ınbox", "Primary"])
    #expect(listing.folders.map(\.roles) == [["inbox"], ["archive"], [], ["inbox"]])
    #expect(listing.moves && listing.idle)
    let overflowing = try JSONDecoder().decode(
      ImapAccount.self,
      from: Data(#"{"host":"localhost","port":\#(port),"username":"many-folders"}"#.utf8))
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await provider.folders(overflowing, password: "synthetic-password")
    }
    let undiscovered = try JSONDecoder().decode(
      ImapAccount.self,
      from: Data(#"{"host":"localhost","port":\#(port),"username":"namespace-failure"}"#.utf8))
    await #expect(throws: (any Error).self) {
      _ = try await provider.folders(undiscovered, password: "synthetic-password")
    }
    let namespaced = try JSONDecoder().decode(
      ImapAccount.self,
      from: Data(#"{"host":"localhost","port":\#(port),"username":"namespaced"}"#.utf8))
    let shared = try await provider.folders(namespaced, password: "synthetic-password")
    #expect(shared.folders.map(\.name) == ["INBOX", "Archive", "ınbox", "Primary", "Shared/Team"])
    #expect(!shared.moves && !shared.idle)
    let initial = try await provider.synchronize(
      account, password: "synthetic-password", folder: "INBOX", from: nil, window: 200)
    #expect(initial.reset && initial.uidValidity == 7 && initial.uidNext == 12)
    #expect(initial.messages.map(\.uid) == [11])
    #expect(initial.messages.first?.subject == "Controlled IMAP")
    let resumed = try await provider.synchronize(
      account, password: "synthetic-password", folder: "INBOX",
      from: ImapCheckpoint(uidValidity: 7, uidNext: 12, known: [11]), window: 200)
    #expect(!resumed.reset && resumed.messages.isEmpty && resumed.flags[11] == ["\\Flagged"])
    // Older messages never cached are not arrivals: a large folder whose UIDNEXT has not moved
    // reads only the known flags, never its newest envelopes again.
    let large = try await provider.synchronize(
      account, password: "synthetic-password", folder: "Large",
      from: ImapCheckpoint(uidValidity: 7, uidNext: 512, known: [511]), window: 200)
    #expect(!large.reset && large.messages.isEmpty && large.flags[511] == ["\\Flagged"])
    // Expunged arrivals advance UIDNEXT too; a large gap must not relist old envelopes when the
    // remaining folder fits within the window. The server rejects that sequence-number fetch.
    let sparse = try await provider.synchronize(
      account, password: "synthetic-password", folder: "Sparse",
      from: ImapCheckpoint(uidValidity: 7, uidNext: 12, known: [11]), window: 200)
    #expect(!sparse.reset && sparse.messages.isEmpty && sparse.flags[11] == ["\\Flagged"])
    #expect(sparse.uidNext == 402)
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
    // The server declares header fields beyond the per-message bound and sends none of them: the
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
    await #expect(throws: ImapFailure.changed) {
      _ = try await provider.synchronize(
        account, password: "synthetic-password", folder: "NoValidity", from: nil, window: 200)
    }
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
  // servers without MOVE, without MOVE and UIDPLUS, and without IDLE.
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
    func change(
      folder: String = "INBOX", uidValidity: UInt32 = 7, uid: UInt32 = 11, read: Bool? = nil,
      to destination: String? = nil, copied: ImapCopy? = nil
    ) -> ImapChange {
      ImapChange(
        folder: folder, uidValidity: uidValidity, uid: uid, read: read, destination: destination,
        copied: copied)
    }
    #expect(try await provider.modify(synthetic, password: password, change: change(read: true)) == .stored)
    #expect(try await provider.modify(synthetic, password: password, change: change(read: false)) == .stored)
    #expect(
      try await provider.modify(synthetic, password: password, change: change(to: "Archive"))
        == .moved(uidValidity: 9, uid: 21))
    // Missing UIDs and mismatched mailbox generations cannot target a different message.
    #expect(try await provider.modify(synthetic, password: password, change: change(uid: 13, to: "Archive")) == .absent)
    await #expect(throws: ImapFailure.changed) {
      _ = try await provider.modify(synthetic, password: password, change: change(uidValidity: 8, read: true))
    }
    await #expect(throws: ImapFailure.missing) {
      _ = try await provider.modify(synthetic, password: password, change: change(folder: "Gone", read: true))
    }
    // MOVE's tagged failure can follow partial completion, with or without a mapping.
    await #expect(throws: ImapFailure.interrupted) {
      _ = try await provider.modify(synthetic, password: password, change: change(to: "Missing"))
    }
    await #expect(throws: ImapFailure.interrupted) {
      _ = try await provider.modify(synthetic, password: password, change: change(to: "Partial"))
    }
    // A connection lost after the change was sent may have applied it.
    await #expect(throws: ImapFailure.interrupted) {
      _ = try await provider.modify(synthetic, password: password, change: change(to: "Drop"))
    }
    // UIDPLUS returns the copy receipt before deletion; resumption reuses that receipt.
    let noMove = try account("no-move")
    let copied = ImapCopy(uidValidity: 9, uid: 22)
    for destination in ["Unmapped", "DropCopy"] {
      await #expect(throws: ImapFailure.interrupted) {
        _ = try await provider.modify(
          noMove, password: password, change: change(to: destination))
      }
    }
    #expect(
      try await provider.modify(noMove, password: password, change: change(to: "Archive"))
        == .copied(uidValidity: 9, uid: 22))
    #expect(
      try await provider.modify(noMove, password: password, change: change(to: "Archive", copied: copied))
        == .moved(uidValidity: 9, uid: 22))
    #expect(
      try await provider.modify(noMove, password: password, change: change(uid: 13, to: "Archive", copied: copied))
        == .moved(uidValidity: 9, uid: 22))
    await #expect(throws: ImapFailure.changed) {
      _ = try await provider.modify(
        noMove, password: password,
        change: change(to: "Archive", copied: ImapCopy(uidValidity: 10, uid: 22)))
    }
    await #expect(throws: ImapFailure.missing) {
      _ = try await provider.modify(
        noMove, password: password,
        change: change(to: "Archive", copied: ImapCopy(uidValidity: 9, uid: 23)))
    }
    await #expect(throws: ImapFailure.changed) {
      _ = try await provider.modify(
        noMove, password: password, change: change(uidValidity: 8, to: "Archive", copied: copied))
    }
    await #expect(throws: ImapFailure.unsupported) {
      _ = try await provider.modify(try account("namespaced"), password: password, change: change(to: "Archive"))
    }

    let search = try await provider.search(
      synthetic, password: password, query: "Controlled", folders: ["INBOX", "Gone"], limit: 50)
    #expect(search.skipped == 1)
    #expect(search.found.map(\.folder) == ["INBOX"] && search.found.first?.uidValidity == 7)
    #expect(search.found.first?.messages.map(\.uid) == [11] && search.found.first?.more == false)
    // A compressed ESEARCH range must fetch only the newest bounded window, without expanding
    // billions of identifiers supplied by an untrusted server.
    let largeSearch = try await provider.search(
      try account("large-search"), password: password, query: "Controlled", folders: ["INBOX"],
      limit: 50)
    #expect(largeSearch.found.first?.messages.map(\.uid) == [4_000_000_000])
    #expect(largeSearch.found.first?.more == true)

    #expect(try await provider.idle(synthetic, password: password, folder: "INBOX", seconds: 30))
    #expect(try await provider.idle(synthetic, password: password, folder: "Quiet", seconds: 1) == false)
    await #expect(throws: ImapFailure.unsupported) {
      _ = try await provider.idle(try account("namespaced"), password: password, folder: "INBOX", seconds: 1)
    }
  }
}

private final class ReceivedBytes: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  func append(_ data: Data) { lock.withLock { bytes.append(data) } }
  func data() -> Data { lock.withLock { bytes } }
}
