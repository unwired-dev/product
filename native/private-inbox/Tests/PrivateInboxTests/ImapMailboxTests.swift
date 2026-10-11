import Foundation
import Network
import Testing

@testable import PrivateInbox

// A controlled IMAP server: logins and folder reads answer as configured, and every request names
// the account and password it presented.
private final class ControlledImap: ImapProvider, @unchecked Sendable {
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
  func folders(_ account: ImapAccount, password: String) async throws -> [ImapFolder] {
    try record("folders", password)
    return [ImapFolder(name: "INBOX", roles: ["inbox"], selectable: true)]
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
    let store = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, imap: imap,
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
        address: "alex@example.invalid", account: account, password: "app-password")
    }
    #expect(try store.saved().connections.isEmpty)
    imap.failure = nil
    let reply = try await store.connectImap(
      address: "alex@example.invalid", account: account, password: "app-password")
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
      address: "alex@example.invalid", account: account, password: "new-password")
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
    let folders = try await provider.folders(account, password: "synthetic-password")
    #expect(folders.map(\.name) == ["INBOX", "Archive"])
    #expect(folders.first?.roles == ["inbox"])
    let initial = try await provider.synchronize(
      account, password: "synthetic-password", folder: "INBOX", from: nil, window: 200)
    #expect(initial.reset && initial.uidValidity == 7 && initial.uidNext == 12)
    #expect(initial.messages.map(\.uid) == [11])
    #expect(initial.messages.first?.subject == "Controlled IMAP")
    let resumed = try await provider.synchronize(
      account, password: "synthetic-password", folder: "INBOX",
      from: ImapCheckpoint(uidValidity: 7, uidNext: 12, known: [11]), window: 200)
    #expect(!resumed.reset && resumed.messages.isEmpty && resumed.flags[11] == ["\\Flagged"])
    let raw = try await provider.message(
      account, password: "synthetic-password", folder: "INBOX", uidValidity: 7, uid: 11,
      limit: RegistrationStore.imapMessageLimit)
    #expect(String(decoding: raw, as: UTF8.self).hasSuffix("Controlled body\r\n"))
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

private final class ReceivedBytes: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  func append(_ data: Data) { lock.withLock { bytes.append(data) } }
  func data() -> Data { lock.withLock { bytes } }
}
