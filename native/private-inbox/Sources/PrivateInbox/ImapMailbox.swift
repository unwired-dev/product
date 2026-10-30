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
  // The server lacks the extension a request needs, such as MOVE or UIDPLUS.
  case unsupported
  // The server refused a change to an identified message, such as a move to a removed folder.
  case rejected
  // The connection failed after a change was sent, so the server may have applied it.
  case interrupted
}

// Where COPYUID says a moved or copied message went: its destination UIDVALIDITY and UID.
struct ImapCopy: Sendable, Equatable {
  let uidValidity: UInt32
  let uid: UInt32
}

// A folder's search matches under its UIDVALIDITY: the newest UIDs asked for, newest first, and how
// many matched in all.
struct ImapMatches: Sendable, Equatable {
  let uidValidity: UInt32
  let uids: [UInt32]
  let total: Int
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

// A message's Content-Type and Content-Disposition fields, unfolded, read without its body.
struct ImapHeaders: Sendable, Equatable {
  let uid: UInt32
  let fields: [ImapHeaderField]
}

struct ImapHeaderField: Sendable, Equatable {
  let name: String
  let value: String
}

// What EXAMINE reported for a folder: its identity, its next UID and how many messages it holds.
struct ImapSelection: Sendable, Equatable {
  let uidValidity: UInt32
  let uidNext: UInt32
  let messages: Int
}

// The messages of the examined folder an envelope read names.
enum ImapEnvelopeRead: Sendable, Equatable {
  case uids([UInt32])
  // `UID n:*`, which always names the newest message, even one below n.
  case from(UInt32)
  // The newest `count` of the folder's `total` messages, by sequence number.
  case newest(count: Int, total: Int)
}

// One Historical Metadata Backfill read: up to `limit` of the newest messages with UIDs from
// `above` up to, not including, `below` (UIDNEXT when nil), and the `known` UIDs to check.
struct ImapHistoryRequest: Sendable, Equatable {
  let folder: String
  let above: UInt32
  let below: UInt32?
  let limit: Int
  let known: [UInt32]
}

// What a history read found: the folder's identity and message count, the messages, the exclusive
// UID the next read starts below, and which known UIDs remain.
struct ImapHistoryPage: Sendable, Equatable {
  let uidValidity: UInt32
  let uidNext: UInt32
  let total: Int
  let messages: [ImapEnvelope]
  let below: UInt32
  let present: [UInt32]
}

protocol ImapProvider: Sendable {
  func verify(_ account: ImapAccount, password: String) async throws
  // Logs in and keeps the session open until it is closed.
  func open(_ account: ImapAccount, password: String) async throws -> any ImapSession
  // One page of the folder's history, newest first, found by bounded UID-range searches.
  func history(_ account: ImapAccount, password: String, request: ImapHistoryRequest) async throws
    -> ImapHistoryPage
  // The raw RFC 5322 message, read without setting \Seen.
  func message(
    _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32, uid: UInt32,
    limit: Int
  ) async throws -> Data
  // The MIME header fields of each message still in the folder, read without any body.
  func headers(
    _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32, uids: [UInt32]
  ) async throws -> [ImapHeaders]
}

#if canImport(SwiftMail)
// SwiftMail over swift-nio-imap. Each operation opens one authenticated session and closes it, so
// no connection outlives the work that needed it.
// shortcut: one login per operation; keep a session per connection when frequent reads need it.
struct SwiftMailImap: ImapProvider {
  // SwiftMail logs hosts, folder names and server replies; none of them leaves this process.
  static let quiet: Void = LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }

  // Connects and logs in; a failure closes the connection.
  private func connected(
    _ account: ImapAccount, _ password: String,
    literalLimit: Int = RegistrationStore.imapMessageLimit
  ) async throws -> IMAPServer {
    _ = Self.quiet
    let server = IMAPServer(
      host: account.host, port: account.port, transportSecurity: .implicitTLS,
      certificateVerificationPolicy: .fullVerification, minimumTLSVersion: .tlsv12,
      // Bound the wire declaration before SwiftMail buffers bytes, even when RFC822.SIZE lies, and
      // stop reading a folder list past 1,000 folders.
      parserLimits: IMAPParserLimits(
        bodySizeLimit: UInt64(literalLimit), messageAttributeLimit: 64,
        maximumListResponses: 1_000))
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
      return server
    } catch {
      try? await server.disconnect()
      throw Self.failure(error)
    }
  }

  private func session<Value: Sendable>(
    _ account: ImapAccount, _ password: String,
    literalLimit: Int = RegistrationStore.imapMessageLimit,
    _ work: @Sendable (IMAPServer) async throws -> Value
  ) async throws -> Value {
    let server = try await connected(account, password, literalLimit: literalLimit)
    do {
      let value = try await work(server)
      try? await server.logout()
      try? await server.disconnect()
      return value
    } catch {
      try? await server.disconnect()
      throw Self.failure(error)
    }
  }

  func open(_ account: ImapAccount, password: String) async throws -> any ImapSession {
    SwiftMailImapSession(server: try await connected(account, password))
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

  static func examine(_ server: IMAPServer, folder: String) async throws -> Mailbox.Selection {
    let selection = try await server.examineMailbox(folder)
    // SwiftMail defaults to zero when EXAMINE omits UIDVALIDITY. No UID is safe to reuse then.
    guard selection.uidValidity.value > 0 else { throw ImapFailure.changed }
    return selection
  }

  // Searches at most eight UID ranges below the cursor, each up to four times wider than the last,
  // so every request stays bounded however sparse the folder's UIDs are; no extension is needed.
  func history(_ account: ImapAccount, password: String, request: ImapHistoryRequest) async throws
    -> ImapHistoryPage
  {
    try await session(account, password) { server in
      // A folder deleted since it was listed is skipped, not a failure of the whole backfill.
      let selection: Mailbox.Selection
      do {
        selection = try await Self.examine(server, folder: request.folder)
      } catch IMAPError.selectFailed {
        throw ImapFailure.missing
      }
      var next = selection.uidNext.value
      if next == 0, let latest = selection.latest(1) {
        let newest = try await server.fetchMessageInfosBulk(using: latest, options: .uidFlagsOnly)
        next = (newest.compactMap { $0.uid?.value }.max() ?? 0) &+ 1
      }
      let present =
        request.known.isEmpty
        ? []
        : try await server.fetchMessageInfosBulk(
          using: UIDSet(request.known.map(UID.init)), options: .uidFlagsOnly
        ).compactMap { $0.uid?.value }
      let floor = max(request.above, 1)
      var high = request.below ?? next
      var span = UInt32(request.limit)
      var found: [UInt32] = []
      var searches = 0
      while found.count < request.limit, high > floor, searches < 8 {
        searches += 1
        let low = high - min(span, high - floor)
        let result: ExtendedSearchResult<UID> = try await server.extendedSearch(
          identifierSet: UIDSet(UID(low)...UID(high - 1)), criteria: [.all])
        // Clamp each reported range to the searched window before expanding it: an untrusted server
        // may answer with billions of identifiers.
        for range in (result.all ?? UIDSet()).ranges.reversed() where found.count <= request.limit {
          let lower = max(range.lowerBound, Int(low))
          let upper = min(range.upperBound, Int(high) - 1)
          if lower <= upper {
            found += (lower...upper).reversed().prefix(request.limit + 1 - found.count)
              .map { UInt32($0) }
          }
        }
        high = low
        span = min(span &* 4, 1 << 16)
      }
      let kept = Array(found.prefix(request.limit))
      let messages =
        kept.isEmpty
        ? []
        : try await server.fetchMessageInfosBulk(
          using: UIDSet(kept.map(UID.init)), options: .slim
        ).compactMap(Self.envelope)
      return ImapHistoryPage(
        uidValidity: selection.uidValidity.value,
        uidNext: max(next, (found.max() ?? 0) &+ 1), total: selection.messageCount,
        messages: messages, below: found.count > request.limit ? (kept.last ?? high) : high,
        present: present)
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

  func headers(
    _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32, uids: [UInt32]
  ) async throws -> [ImapHeaders] {
    // Each header literal has the MIME header budget; larger declarations refuse the read.
    // shortcut: Aggregate receive is unbounded, accepted for #1185; add the upstream bound in #1187.
    try await session(account, password, literalLimit: RegistrationStore.imapHeaderLimit) { server in
      let selection = try await Self.examine(server, folder: folder)
      guard selection.uidValidity.value == uidValidity else { throw ImapFailure.changed }
      // Request only BODY.PEEK[HEADER.FIELDS (...)], without any body part.
      let infos: [MessageInfo]
      do {
        infos = try await server.fetchMessageInfosBulk(
          using: UIDSet(uids.map(UID.init)), options: [],
          headerFields: ["Content-Type", "Content-Disposition"])
      } catch where String(reflecting: Swift.type(of: error)).hasSuffix("IMAPDecoderError") {
        throw ImapFailure.tooLarge
      }
      return infos.compactMap { info in
        info.uid.map { uid in
          ImapHeaders(
            uid: uid.value,
            fields: (info.additionalHeaderFields ?? []).map {
              ImapHeaderField(name: $0.name, value: $0.value)
            })
        }
      }
    }
  }

  static func flag(_ flag: Flag) -> String {
    switch flag {
    case .seen: "\\Seen"
    case .answered: "\\Answered"
    case .flagged: "\\Flagged"
    case .deleted: "\\Deleted"
    case .draft: "\\Draft"
    case .custom(let name): name
    }
  }

  static func envelope(_ info: MessageInfo) -> ImapEnvelope? {
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
    func open(_ account: ImapAccount, password: String) async throws -> any ImapSession {
      throw ImapFailure.offline
    }
    func history(_ account: ImapAccount, password: String, request: ImapHistoryRequest)
      async throws -> ImapHistoryPage
    {
      throw ImapFailure.offline
    }
    func message(
      _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32, uid: UInt32,
      limit: Int
    ) async throws -> Data {
      throw ImapFailure.offline
    }
    func headers(
      _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32,
      uids: [UInt32]
    ) async throws -> [ImapHeaders] {
      throw ImapFailure.offline
    }
  }
#endif

extension RegistrationStore {
  // Bounds a message read: the same per-message limit as Gmail's received mail.
  nonisolated static let imapMessageLimit = 40 * 1024 * 1024
  // Prefetch requests at most 20 UIDs, with the MIME header budget per literal; see #1187.
  nonisolated static let imapHeaderLimit = 256 * 1024
  nonisolated static let imapHeaderMessages = 20

  // The connection's IMAP account and password, while it is connected and still this account.
  func imapConnection(_ id: String) throws -> (ImapAccount, String, MailboxConnection) {
    guard let saved = try load(), saved.accountRemoval == nil, let connection = saved.connection(id),
      connection.authorizationNeeded != true, let account = connection.imap
    else { throw RegistrationError.gmailUnavailable }
    return (account, String(decoding: connection.credential, as: UTF8.self), connection)
  }

  // Verifies the IMAP login, then the SMTP login on its own, and only then adds the connection, or
  // repairs the connection for the same account and address. `smtpPassword` is a separate SMTP
  // password; without one SMTP uses the IMAP password. Passwords stay in this device's record.
  func connectImap(
    address: String, account: ImapAccount, password: String, smtp: SmtpAccount,
    smtpPassword: String?
  ) async throws -> [String: Any] {
    guard let product = try saved().product, product.pending != true,
      address.count <= 320, address.contains("@"),
      address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !password.isEmpty,
      smtpPassword?.isEmpty != true
    else { throw RegistrationError.unavailable }
    try await imap.verify(account, password: password)
    try await self.smtp.verify(smtp, password: smtpPassword ?? password)
    let receipt = GmailRegistrationReceipt(subject: account.subject, address: address, provider: .imap)
    try addConnection(
      credential: Data(password.utf8), receipt: receipt, imap: account, smtp: smtp,
      smtpCredential: smtpPassword.map { Data($0.utf8) })
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
  func imapWork<Value>(
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

  // One history page of at most 500 messages, checking at most 500 known UIDs.
  func imapHistory(
    connection: String, address: String, generation: String, request: ImapHistoryRequest
  ) async throws -> [String: Any] {
    guard Self.imapFolderName(request.folder), request.above > 0,
      request.below.map({ $0 > 0 }) ?? true, (1...500).contains(request.limit),
      request.known.count <= 500
    else { throw RegistrationError.unavailable }
    let page = try await imapWork(connection: connection, address: address, generation: generation) {
      try await imap.history($0, password: $1, request: request)
    }
    return [
      "uidValidity": Double(page.uidValidity), "uidNext": Double(page.uidNext),
      "total": Double(page.total), "messages": page.messages.map(Self.envelopeReply),
      "below": Double(page.below), "present": page.present.map(Double.init),
    ]
  }

  nonisolated static func imapFolderName(_ name: String) -> Bool {
    !name.isEmpty && name.count <= 1_000
  }

  nonisolated static func envelopeReply(_ envelope: ImapEnvelope) -> [String: Any] {
    [
      "uid": Double(envelope.uid), "flags": envelope.flags, "received": envelope.received,
      "size": Double(envelope.size), "sender": envelope.sender, "address": envelope.address,
      "subject": envelope.subject,
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

  // The Content-Type and Content-Disposition fields of up to 20 messages, without their bodies.
  func imapHeaders(
    connection: String, address: String, generation: String, folder: String, uidValidity: UInt32,
    uids: [UInt32]
  ) async throws -> [String: Any] {
    guard Self.imapFolderName(folder), uidValidity > 0,
      (1...Self.imapHeaderMessages).contains(uids.count),
      uids.allSatisfy({ $0 > 0 })
    else { throw RegistrationError.unavailable }
    let found = try await imapWork(connection: connection, address: address, generation: generation) {
      try await imap.headers(
        $0, password: $1, folder: folder, uidValidity: uidValidity, uids: uids)
    }
    return [
      "messages": found.map { message in
        [
          "uid": Double(message.uid),
          "headers": message.fields.map { ["name": $0.name, "value": $0.value] },
        ] as [String: Any]
      }
    ]
  }
}
