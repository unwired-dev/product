import Foundation

#if canImport(SwiftMail)
  import Logging
  import SwiftMail
#endif

// A Standards-Based Mailbox Connection's IMAP endpoint. Secure Mail Transport: implicit TLS from the
// first byte, certificates verified against the system's trusted roots, no override.
struct ImapAccount: Codable, Equatable, Sendable {
  let host: String
  let port: Int
  let username: String

  // Hosts, ports and user names an endpoint review can show back unchanged.
  init(host: String, port: Int, username: String) throws {
    let host = host.lowercased()
    guard host.range(of: "^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?)+$", options: .regularExpression) != nil,
      host.count <= 253, (1...65_535).contains(port), !username.isEmpty, username.count <= 320,
      username.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw RegistrationError.unavailable }
    self.host = host
    self.port = port
    self.username = username
  }

  // The provider subject identifying the connection; its receipt's `imap` provider keeps its
  // identifier and synchronized descriptor apart from every other provider's account.
  var subject: String { "\(host):\(port):\(username)" }
}

// Why an IMAP operation ended; every other failure is unavailable.
enum ImapFailure: Error, Equatable {
  // The server refused the user name and password.
  case authentication
  // The server could not be reached; a later attempt may succeed.
  case offline
  // TLS could not be established with a verified certificate.
  case insecure
  // The folder's UIDVALIDITY changed or is absent, so this request has no established identity.
  case changed
  case missing
  case tooLarge
}

struct ImapFolder: Sendable, Equatable {
  let name: String
  // Special-use roles the server declares, such as `sent`; `inbox` for the Inbox.
  let roles: [String]
  let selectable: Bool
}

struct ImapEnvelope: Sendable, Equatable {
  let uid: UInt32
  let flags: [String]
  // Milliseconds since 1970: the server's internal date, else the Date header.
  let received: Double
  let size: Int
  let sender: String
  let address: String
  let subject: String
}

// What a folder synchronization read: its identity, new or listed messages, and the flags of the
// already-known messages that remain. `reset` lists the newest messages afresh.
struct ImapFolderState: Sendable, Equatable {
  let uidValidity: UInt32
  let uidNext: UInt32
  let messages: [ImapEnvelope]
  let flags: [UInt32: [String]]
  let reset: Bool
}

// The checkpoint a synchronization resumes from.
struct ImapCheckpoint: Sendable, Equatable {
  let uidValidity: UInt32
  let uidNext: UInt32
  let known: [UInt32]
}

protocol ImapProvider: Sendable {
  func verify(_ account: ImapAccount, password: String) async throws
  func folders(_ account: ImapAccount, password: String) async throws -> [ImapFolder]
  func synchronize(
    _ account: ImapAccount, password: String, folder: String, from: ImapCheckpoint?, window: Int
  ) async throws -> ImapFolderState
  // The raw RFC 5322 message, read without setting \Seen.
  func message(
    _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32, uid: UInt32,
    limit: Int
  ) async throws -> Data
}

#if canImport(SwiftMail)
// SwiftMail over swift-nio-imap. Each operation opens one authenticated session and closes it, so
// no connection outlives the work that needed it.
// shortcut: one login per operation; keep a session per connection when IDLE or frequent reads need it.
struct SwiftMailImap: ImapProvider {
  private static let folderLimit = 1_000
  // SwiftMail logs hosts, folder names and server replies; none of them leaves this process.
  private static let quiet: Void = LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }

  private func session<Value: Sendable>(
    _ account: ImapAccount, _ password: String,
    _ work: @Sendable (IMAPServer) async throws -> Value
  ) async throws -> Value {
    _ = Self.quiet
    let server = IMAPServer(
      host: account.host, port: account.port, transportSecurity: .implicitTLS,
      certificateVerificationPolicy: .fullVerification, minimumTLSVersion: .tlsv12,
      // Bound the wire declaration before SwiftMail buffers bytes, even when RFC822.SIZE lies.
      parserLimits: IMAPParserLimits(
        bodySizeLimit: UInt64(RegistrationStore.imapMessageLimit), messageAttributeLimit: 64))
    do {
      try await server.connect()
      do {
        try await server.login(username: account.username, password: password)
      } catch let error as IMAPError {
        switch error {
        case .loginFailed, .authFailed: throw ImapFailure.authentication
        default: throw error
        }
      }
      let value = try await work(server)
      try? await server.logout()
      try? await server.disconnect()
      return value
    } catch {
      try? await server.disconnect()
      throw Self.failure(error)
    }
  }

  // Classifies by type name: SwiftMail rethrows NIO's own errors, whose modules this target does
  // not import.
  static func failure(_ error: any Error) -> any Error {
    if error is ImapFailure || error is CancellationError { return error }
    let type = String(reflecting: Swift.type(of: error))
    if type.contains("NIOSSL") || type.contains("BoringSSL") { return ImapFailure.insecure }
    if let error = error as? IMAPError {
      switch error {
      case .timeout, .connectionFailed, .greetingFailed: return ImapFailure.offline
      default: return error
      }
    }
    if type.hasPrefix("NIOCore.") || type.hasPrefix("NIOPosix.") || error is POSIXError
      || (error as NSError).domain == NSPOSIXErrorDomain
    {
      return ImapFailure.offline
    }
    return error
  }

  func verify(_ account: ImapAccount, password: String) async throws {
    try await session(account, password) { server in
      _ = try await Self.examine(server, folder: "INBOX")
    }
  }

  private static func examine(_ server: IMAPServer, folder: String) async throws -> Mailbox.Selection {
    let selection = try await server.examineMailbox(folder)
    // SwiftMail defaults to zero when EXAMINE omits UIDVALIDITY. No UID is safe to reuse then.
    guard selection.uidValidity.value > 0 else { throw ImapFailure.changed }
    return selection
  }

  func folders(_ account: ImapAccount, password: String) async throws -> [ImapFolder] {
    try await session(account, password) { server in
      try await server.listMailboxes().prefix(Self.folderLimit).map { info in
        let roles: [(Mailbox.Info.Attributes, String)] = [
          (.archive, "archive"), (.drafts, "drafts"), (.junk, "junk"), (.sent, "sent"),
          (.trash, "trash"), (.all, "all"), (.flagged, "flagged"),
        ]
        // Only ASCII INBOX case variants share a cache and message-ID namespace.
        let named = info.name.lowercased() == "inbox"
        let inbox = named || info.attributes.contains(.inbox)
        return ImapFolder(
          name: named ? "INBOX" : info.name,
          roles: (inbox ? ["inbox"] : [])
            + roles.filter { info.attributes.contains($0.0) }.map(\.1),
          selectable: info.isSelectable)
      }
    }
  }

  func synchronize(
    _ account: ImapAccount, password: String, folder: String, from: ImapCheckpoint?, window: Int
  ) async throws -> ImapFolderState {
    try await session(account, password) { server in
      let selection = try await Self.examine(server, folder: folder)
      let validity = selection.uidValidity.value
      let envelopes = { (infos: [MessageInfo]) in infos.compactMap(Self.envelope) }
      func newest() async throws -> [ImapEnvelope] {
        guard let latest = selection.latest(window) else { return [] }
        return envelopes(try await server.fetchMessageInfosBulk(using: latest, options: .slim))
      }
      // Without a checkpoint at this UIDVALIDITY, the newest messages are listed again.
      guard let from, from.uidValidity == validity else {
        let messages = try await newest()
        return ImapFolderState(
          uidValidity: validity,
          uidNext: max(selection.uidNext.value, (messages.map(\.uid).max() ?? 0) &+ 1),
          messages: messages, flags: [:], reset: true)
      }
      var flags: [UInt32: [String]] = [:]
      if !from.known.isEmpty {
        let present = try await server.fetchMessageInfosBulk(
          using: UIDSet(from.known.map(UID.init)), options: .uidFlagsOnly)
        for info in present {
          if let uid = info.uid?.value { flags[uid] = info.flags.map(Self.flag) }
        }
      }
      let arrivals: [ImapEnvelope]
      // Both counts bound arrivals still present: old uncached messages inflate the folder count,
      // while arrivals expunged before this read inflate the UIDNEXT gap.
      let next = selection.uidNext.value
      let unlisted = max(0, selection.messageCount - flags.count)
      let arrived =
        next == 0 ? unlisted : min(unlisted, Int(next - min(next, from.uidNext)))
      if arrived > window {
        // More arrived than the window keeps: only the newest are read.
        arrivals = try await newest()
      } else if selection.uidNext.value == 0 || selection.uidNext.value > from.uidNext {
        // `n:*` always names the newest message, even one below n.
        arrivals = envelopes(
          try await server.fetchMessageInfos(uidRange: UID(from.uidNext)..., options: .slim)
        ).filter { $0.uid >= from.uidNext }
      } else {
        arrivals = []
      }
      return ImapFolderState(
        uidValidity: validity,
        uidNext: max(selection.uidNext.value, from.uidNext, (arrivals.map(\.uid).max() ?? 0) &+ 1),
        messages: arrivals, flags: flags, reset: false)
    }
  }

  func message(
    _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32, uid: UInt32,
    limit: Int
  ) async throws -> Data {
    try await session(account, password) { server in
      let selection = try await Self.examine(server, folder: folder)
      guard selection.uidValidity.value == uidValidity else { throw ImapFailure.changed }
      guard let info = try await server.fetchMessageInfo(for: UID(uid), options: [.size]),
        info.uid?.value == uid
      else { throw ImapFailure.missing }
      guard let size = info.size, size <= limit else { throw ImapFailure.tooLarge }
      let raw = try await server.fetchRawMessage(identifier: UID(uid))
      guard raw.count <= limit else { throw ImapFailure.tooLarge }
      return raw
    }
  }

  private static func flag(_ flag: Flag) -> String {
    switch flag {
    case .seen: "\\Seen"
    case .answered: "\\Answered"
    case .flagged: "\\Flagged"
    case .deleted: "\\Deleted"
    case .draft: "\\Draft"
    case .custom(let name): name
    }
  }

  private static func envelope(_ info: MessageInfo) -> ImapEnvelope? {
    guard let uid = info.uid?.value else { return nil }
    let from = info.fromAddresses.lazy.compactMap { entry -> EmailAddress? in
      if case .mailbox(let address) = entry { return address }
      return nil
    }.first
    let date = info.internalDate ?? info.date ?? Date(timeIntervalSince1970: 0)
    return ImapEnvelope(
      uid: uid, flags: info.flags.map(flag), received: (date.timeIntervalSince1970 * 1000).rounded(),
      size: info.size ?? 0, sender: from?.name ?? from?.address ?? info.from ?? "",
      address: from?.address ?? "", subject: info.subject ?? "")
  }
}
#else
  // The synthetic metadata check compiles these sources without Swift packages; every host and
  // the storage probe link SwiftMail.
  struct SwiftMailImap: ImapProvider {
    func verify(_ account: ImapAccount, password: String) async throws {
      throw ImapFailure.offline
    }
    func folders(_ account: ImapAccount, password: String) async throws -> [ImapFolder] {
      throw ImapFailure.offline
    }
    func synchronize(
      _ account: ImapAccount, password: String, folder: String, from: ImapCheckpoint?,
      window: Int
    ) async throws -> ImapFolderState {
      throw ImapFailure.offline
    }
    func message(
      _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32, uid: UInt32,
      limit: Int
    ) async throws -> Data {
      throw ImapFailure.offline
    }
  }
#endif

extension RegistrationStore {
  // Bounds a message read: the same per-message limit as Gmail's received mail.
  nonisolated static let imapMessageLimit = 40 * 1024 * 1024

  // The connection's IMAP account and password, while it is connected and still this account.
  private func imapConnection(_ id: String) throws -> (ImapAccount, String, MailboxConnection) {
    guard let saved = try load(), saved.accountRemoval == nil, let connection = saved.connection(id),
      connection.authorizationNeeded != true, let account = connection.imap
    else { throw RegistrationError.gmailUnavailable }
    return (account, String(decoding: connection.credential, as: UTF8.self), connection)
  }

  // Verifies an IMAP login, then adds it as a connection, or repairs the connection for the same
  // account and address. The password stays in this device's registration record.
  func connectImap(address: String, account: ImapAccount, password: String) async throws
    -> [String: Any]
  {
    guard let product = try saved().product, product.pending != true,
      address.count <= 320, address.contains("@"),
      address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !password.isEmpty
    else { throw RegistrationError.unavailable }
    try await imap.verify(account, password: password)
    let receipt = GmailRegistrationReceipt(subject: account.subject, address: address, provider: .imap)
    try addConnection(credential: Data(password.utf8), receipt: receipt, imap: account)
    return ["connection": MailboxConnection.id(receipt), "address": address]
  }

  // Checks a saved IMAP connection's login, which every launch repeats before its mail opens.
  func verifyImap(_ id: String) async throws {
    guard let connection = try saved().connection(id), let account = connection.imap else {
      throw RegistrationError.unavailable
    }
    try await imap.verify(account, password: String(decoding: connection.credential, as: UTF8.self))
    var saved = try saved()
    // A connection removed or re-added meanwhile is not verified by this login.
    guard saved.connection(id)?.credential == connection.credential else {
      throw RegistrationError.unavailable
    }
    saved.update(id) { $0.authorizationNeeded = nil }
    try save(saved)
    verifiedMailboxes.insert(id)
    cacheOnlyMailboxes.remove(id)
  }

  // Runs one IMAP operation for a verified connection at the generation the caller opened. Work
  // that finishes after a removal, sign-out or another verification is discarded.
  private func imapWork<Value>(
    connection id: String, address: String, generation expected: String,
    _ work: (ImapAccount, String) async throws -> Value
  ) async throws -> Value {
    let generation = mailboxGeneration(id)
    guard generation.uuidString == expected else { throw PrivateInboxError.mailboxInvalidated }
    _ = try mailboxAccount(id)
    guard verifiedMailboxes.contains(id) else { throw RegistrationError.unavailable }
    let (account, password, connection) = try imapConnection(id)
    guard connection.receipt.address == address else { throw PrivateInboxError.mailboxInvalidated }
    let value: Value
    do {
      value = try await work(account, password)
    } catch ImapFailure.authentication {
      throw RegistrationError.gmailUnavailable
    }
    guard generation == mailboxGeneration(id), verifiedMailboxes.contains(id),
      (try? imapConnection(id))?.2.receipt.subject == connection.receipt.subject
    else { throw PrivateInboxError.mailboxInvalidated }
    return value
  }

  func imapFolders(connection: String, address: String, generation: String) async throws
    -> [String: Any]
  {
    let folders = try await imapWork(connection: connection, address: address, generation: generation) {
      try await imap.folders($0, password: $1)
    }
    return [
      "folders": folders.map {
        ["name": $0.name, "roles": $0.roles, "selectable": $0.selectable] as [String: Any]
      }
    ]
  }

  func imapSynchronize(
    connection: String, address: String, generation: String, folder: String,
    from: ImapCheckpoint?, window: Int
  ) async throws -> [String: Any] {
    guard (1...200).contains(window), !folder.isEmpty, folder.count <= 1_000,
      (from?.known.count ?? 0) <= 200
    else { throw RegistrationError.unavailable }
    let state = try await imapWork(connection: connection, address: address, generation: generation) {
      try await imap.synchronize($0, password: $1, folder: folder, from: from, window: window)
    }
    return [
      "uidValidity": Double(state.uidValidity), "uidNext": Double(state.uidNext),
      "reset": state.reset,
      "messages": state.messages.map {
        [
          "uid": Double($0.uid), "flags": $0.flags, "received": $0.received,
          "size": Double($0.size), "sender": $0.sender, "address": $0.address,
          "subject": $0.subject,
        ] as [String: Any]
      },
      "flags": state.flags.map { ["uid": Double($0.key), "flags": $0.value] as [String: Any] },
    ]
  }

  // The raw message as standard base64.
  func imapMessage(
    connection: String, address: String, generation: String, folder: String, uidValidity: UInt32,
    uid: UInt32
  ) async throws -> [String: Any] {
    let raw = try await imapWork(connection: connection, address: address, generation: generation) {
      try await imap.message(
        $0, password: $1, folder: folder, uidValidity: uidValidity, uid: uid,
        limit: Self.imapMessageLimit)
    }
    return ["data": raw.base64EncodedString()]
  }
}
