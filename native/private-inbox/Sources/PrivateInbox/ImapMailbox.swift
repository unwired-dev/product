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
  // The server lacks the extension a request needs, such as MOVE or UIDPLUS, or IDLE.
  case unsupported
  // The server refused a change to an identified message, such as a move to a removed folder.
  case rejected
  // The connection failed after a change was sent, so the server may have applied it.
  case interrupted
}

// One change to one identified message: its read state, or a move to `destination`.
struct ImapChange: Sendable, Equatable {
  let folder: String
  let uidValidity: UInt32
  let uid: UInt32
  let read: Bool?
  let destination: String?
  let copied: ImapCopy?

  init(
    folder: String, uidValidity: UInt32, uid: UInt32, read: Bool?, destination: String?,
    copied: ImapCopy? = nil
  ) {
    self.folder = folder
    self.uidValidity = uidValidity
    self.uid = uid
    self.read = read
    self.destination = destination
    self.copied = copied
  }
}

struct ImapCopy: Sendable, Equatable {
  let uidValidity: UInt32
  let uid: UInt32
}

// A copy receipt must be saved before its source deletion is resumed. A move reports the new UID
// when the server says (COPYUID); `absent` means the same source generation no longer holds the UID.
enum ImapOutcome: Sendable, Equatable {
  case stored
  case copied(uidValidity: UInt32, uid: UInt32)
  case moved(uidValidity: UInt32, uid: UInt32)
  case movedUnmapped
  case absent
}

// A folder's newest search matches, read under its UIDVALIDITY; `more` when older ones were left out.
struct ImapFound: Sendable, Equatable {
  let folder: String
  let uidValidity: UInt32
  let messages: [ImapEnvelope]
  let more: Bool
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
  // Logs in and keeps the session open until it is closed.
  func open(_ account: ImapAccount, password: String) async throws -> any ImapSession
  func synchronize(
    _ account: ImapAccount, password: String, folder: String, from: ImapCheckpoint?, window: Int
  ) async throws -> ImapFolderState
  // The raw RFC 5322 message, read without setting \Seen.
  func message(
    _ account: ImapAccount, password: String, folder: String, uidValidity: UInt32, uid: UInt32,
    limit: Int
  ) async throws -> Data
  // Applies one change; a UIDVALIDITY that no longer matches changes nothing.
  func modify(_ account: ImapAccount, password: String, change: ImapChange) async throws
    -> ImapOutcome
  // The server's text search of each folder in order, newest `limit` matches per folder. Folders the
  // server no longer selects are skipped and counted.
  func search(
    _ account: ImapAccount, password: String, query: String, folders: [String], limit: Int
  ) async throws -> (found: [ImapFound], skipped: Int)
  // Waits in IDLE on the folder for up to `seconds`; true once the server reports a change.
  func idle(_ account: ImapAccount, password: String, folder: String, seconds: Int) async throws
    -> Bool
  // How many messages in the folder carry the MIME boundary in their Content-Type.
  func findSent(_ account: ImapAccount, password: String, folder: String, boundary: String)
    async throws -> Int
  // Appends the message, read, to the folder unless a message with its boundary is already there.
  func fileSent(
    _ account: ImapAccount, password: String, folder: String, boundary: String, message: Data
  ) async throws
}

#if canImport(SwiftMail)
// SwiftMail over swift-nio-imap. Each operation opens one authenticated session and closes it, so
// no connection outlives the work that needed it.
// shortcut: one login per operation, IDLE included; keep a session per connection when frequent
// reads need it.
struct SwiftMailImap: ImapProvider {
  // SwiftMail logs hosts, folder names and server replies; none of them leaves this process.
  static let quiet: Void = LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }

  // Connects and logs in; a failure closes the connection.
  private func connected(_ account: ImapAccount, _ password: String) async throws -> IMAPServer {
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
      return server
    } catch {
      try? await server.disconnect()
      throw Self.failure(error)
    }
  }

  private func session<Value: Sendable>(
    _ account: ImapAccount, _ password: String,
    _ work: @Sendable (IMAPServer) async throws -> Value
  ) async throws -> Value {
    let server = try await connected(account, password)
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

  private static func examine(_ server: IMAPServer, folder: String) async throws -> Mailbox.Selection {
    let selection = try await server.examineMailbox(folder)
    // SwiftMail defaults to zero when EXAMINE omits UIDVALIDITY. No UID is safe to reuse then.
    guard selection.uidValidity.value > 0 else { throw ImapFailure.changed }
    return selection
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

  func modify(_ account: ImapAccount, password: String, change: ImapChange) async throws
    -> ImapOutcome
  {
    try await session(account, password) { server in
      let advertised = try await server.fetchCapabilities().map { String($0).uppercased() }
      if let copied = change.copied, let destination = change.destination {
        let destinationSelection = try await Self.examine(server, folder: destination)
        guard destinationSelection.uidValidity.value == copied.uidValidity else {
          throw ImapFailure.changed
        }
        let destinationMessages = try await server.fetchMessageInfosBulk(
          using: UIDSet(UID(copied.uid)), options: .uidFlagsOnly)
        guard destinationMessages.contains(where: { $0.uid?.value == copied.uid }) else {
          throw ImapFailure.missing
        }
      }
      let selection: Mailbox.Selection
      do {
        selection = try await server.selectMailbox(change.folder)
      } catch IMAPError.selectFailed {
        throw ImapFailure.missing
      }
      guard selection.uidValidity.value > 0, selection.uidValidity.value == change.uidValidity
      else { throw ImapFailure.changed }
      guard !selection.isReadOnly else { throw ImapFailure.unsupported }
      let message = UIDSet(UID(change.uid))
      let present = try await server.fetchMessageInfosBulk(using: message, options: .uidFlagsOnly)
      guard present.contains(where: { $0.uid?.value == change.uid }) else {
        if let copied = change.copied {
          return .moved(uidValidity: copied.uidValidity, uid: copied.uid)
        }
        return .absent
      }
      // Failures before the change command are retried as unsent; after it, the caller reconciles.
      var issued = false
      do {
        if let read = change.read {
          issued = true
          try await server.store(flags: [.seen], on: message, operation: read ? .add : .remove)
          return .stored
        }
        guard let destination = change.destination else { throw RegistrationError.unavailable }
        guard advertised.contains("MOVE") || advertised.contains("UIDPLUS") else {
          throw ImapFailure.unsupported
        }
        issued = true
        if let copied = change.copied {
          guard advertised.contains("UIDPLUS") else { throw ImapFailure.unsupported }
          try await server.store(flags: [.deleted], on: message, operation: .add)
          try await server.expunge(messages: message)
          return .moved(uidValidity: copied.uidValidity, uid: copied.uid)
        }
        let copied: CopyUID?
        if advertised.contains("MOVE") {
          copied = try await server.move(messages: message, to: destination, fallback: .disabled)
        } else {
          // The caller saves this receipt before requesting targeted source deletion.
          copied = try await server.copy(messages: message, to: destination)
          guard let receipt = copied, receipt.destinationUIDValidity.value > 0,
            let mapped = receipt.mapping.first(where: { $0.source.value == change.uid }),
            mapped.destination.value > 0
          else { throw ImapFailure.interrupted }
          return .copied(
            uidValidity: receipt.destinationUIDValidity.value, uid: mapped.destination.value)
        }
        guard let mapped = copied?.mapping.first(where: { $0.source.value == change.uid }) else {
          return .movedUnmapped
        }
        return .moved(
          uidValidity: copied?.destinationUIDValidity.value ?? 0, uid: mapped.destination.value)
      } catch let error as IMAPError {
        switch error {
        // Partial completion is uncertain; a definite refusal does not authorize another copy.
        case .moveFailedAfterPossiblePartialCompletion, .moveFailedAfterPartialCompletion,
          .moveFallbackFailedAfterCopy:
          throw ImapFailure.interrupted
        case .storeFailed, .copyFailed, .moveFailed, .expungeFailed, .commandFailed:
          throw ImapFailure.rejected
        default: throw issued ? ImapFailure.interrupted : error
        }
      } catch let error as ImapFailure {
        throw error
      } catch {
        throw issued && !(error is CancellationError) ? ImapFailure.interrupted : error
      }
    }
  }

  func search(
    _ account: ImapAccount, password: String, query: String, folders: [String], limit: Int
  ) async throws -> (found: [ImapFound], skipped: Int) {
    try await session(account, password) { server in
      var found: [ImapFound] = []
      var skipped = 0
      for folder in folders {
        let selection: Mailbox.Selection
        do {
          selection = try await Self.examine(server, folder: folder)
        } catch ImapFailure.changed {
          skipped += 1
          continue
        } catch IMAPError.selectFailed {
          skipped += 1
          continue
        }
        let result: ExtendedSearchResult<UID>
        do {
          result = try await server.extendedSearch(criteria: [.text(query)])
        } catch IMAPError.searchCharsetNotSupported {
          throw ImapFailure.unsupported
        }
        let matches = result.all ?? UIDSet()
        let newest = Array(
          matches.ranges.reversed().lazy.flatMap { $0.reversed() }.prefix(limit)
        ).map { UID(UInt32($0)) }
        guard !newest.isEmpty else { continue }
        let infos = try await server.fetchMessageInfosBulk(
          using: UIDSet(Array(newest)), options: .slim)
        found.append(
          ImapFound(
            folder: folder, uidValidity: selection.uidValidity.value,
            messages: infos.compactMap(Self.envelope), more: matches.count > limit))
      }
      return (found, skipped)
    }
  }

  func idle(_ account: ImapAccount, password: String, folder: String, seconds: Int) async throws
    -> Bool
  {
    try await session(account, password) { server in
      let advertised = try await server.fetchCapabilities().map { String($0).uppercased() }
      guard advertised.contains("IDLE") else { throw ImapFailure.unsupported }
      _ = try await Self.examine(server, folder: folder)
      let events = try await server.idle()
      let changed = try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
          for await event in events {
            switch event {
            case .exists, .expunge, .vanished, .fetch, .fetchUID: return true
            // The server is closing the connection; a later wait reconnects.
            case .bye: throw ImapFailure.offline
            default: continue
            }
          }
          throw ImapFailure.offline
        }
        group.addTask {
          try await Task.sleep(for: .seconds(seconds))
          return false
        }
        defer { group.cancelAll() }
        return try await group.next() ?? false
      }
      try? await server.done()
      return changed
    }
  }

  func findSent(_ account: ImapAccount, password: String, folder: String, boundary: String)
    async throws -> Int
  {
    try await session(account, password) { server in
      try await Self.sentCopies(server, folder: folder, boundary: boundary)
    }
  }

  func fileSent(
    _ account: ImapAccount, password: String, folder: String, boundary: String, message: Data
  ) async throws {
    try await session(account, password) { server in
      // An earlier filing whose answer was lost may have stored the copy already.
      guard try await Self.sentCopies(server, folder: folder, boundary: boundary) == 0 else {
        return
      }
      try await server.append(
        rawMessage: String(decoding: message, as: UTF8.self), to: folder, flags: [.seen],
        internalDate: nil)
    }
  }

  private static func sentCopies(_ server: IMAPServer, folder: String, boundary: String)
    async throws -> Int
  {
    do {
      _ = try await examine(server, folder: folder)
    } catch IMAPError.selectFailed {
      throw ImapFailure.missing
    }
    let found: ExtendedSearchResult<UID> = try await server.extendedSearch(
      criteria: [.header("Content-Type", boundary)])
    return found.all?.count ?? 0
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
    func open(_ account: ImapAccount, password: String) async throws -> any ImapSession {
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
    func modify(_ account: ImapAccount, password: String, change: ImapChange) async throws
      -> ImapOutcome
    {
      throw ImapFailure.offline
    }
    func search(
      _ account: ImapAccount, password: String, query: String, folders: [String], limit: Int
    ) async throws -> (found: [ImapFound], skipped: Int) {
      throw ImapFailure.offline
    }
    func idle(_ account: ImapAccount, password: String, folder: String, seconds: Int)
      async throws -> Bool
    {
      throw ImapFailure.offline
    }
    func findSent(_ account: ImapAccount, password: String, folder: String, boundary: String)
      async throws -> Int
    {
      throw ImapFailure.offline
    }
    func fileSent(
      _ account: ImapAccount, password: String, folder: String, boundary: String, message: Data
    ) async throws {
      throw ImapFailure.offline
    }
  }
#endif

extension RegistrationStore {
  // Bounds a message read: the same per-message limit as Gmail's received mail.
  nonisolated static let imapMessageLimit = 40 * 1024 * 1024

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

  func imapSynchronize(
    connection: String, address: String, generation: String, folder: String,
    from: ImapCheckpoint?, window: Int
  ) async throws -> [String: Any] {
    guard (1...200).contains(window), Self.imapFolderName(folder),
      (from?.known.count ?? 0) <= 200
    else { throw RegistrationError.unavailable }
    let state = try await imapWork(connection: connection, address: address, generation: generation) {
      try await imap.synchronize($0, password: $1, folder: folder, from: from, window: window)
    }
    return [
      "uidValidity": Double(state.uidValidity), "uidNext": Double(state.uidNext),
      "reset": state.reset,
      "messages": state.messages.map(Self.envelopeReply),
      "flags": state.flags.map { ["uid": Double($0.key), "flags": $0.value] as [String: Any] },
    ]
  }

  // A UIDPLUS copy returns `copied`; only a saved receipt may resume its source deletion.
  func imapModify(
    connection: String, address: String, generation: String, change: ImapChange
  ) async throws -> [String: Any] {
    guard (change.read == nil) != (change.destination == nil), Self.imapFolderName(change.folder),
      change.destination.map(Self.imapFolderName) ?? true, change.destination != change.folder,
      change.uidValidity > 0, change.uid > 0,
      change.copied.map({ $0.uidValidity > 0 && $0.uid > 0 && change.destination != nil }) ?? true
    else { throw RegistrationError.unavailable }
    let outcome = try await imapWork(connection: connection, address: address, generation: generation) {
      try await imap.modify($0, password: $1, change: change)
    }
    switch outcome {
    case .stored: return ["outcome": "stored"]
    case .copied(let uidValidity, let uid):
      return ["outcome": "copied", "uidValidity": Double(uidValidity), "uid": Double(uid)]
    case .absent: return ["outcome": "absent"]
    case .movedUnmapped: return ["outcome": "moved"]
    case .moved(let uidValidity, let uid):
      return ["outcome": "moved", "uidValidity": Double(uidValidity), "uid": Double(uid)]
    }
  }

  // The server's search of up to 50 folders, newest 50 matches each.
  func imapSearch(
    connection: String, address: String, generation: String, query: String, folders: [String]
  ) async throws -> [String: Any] {
    guard !query.isEmpty, query.count <= 200,
      query.rangeOfCharacter(from: .controlCharacters) == nil, (1...50).contains(folders.count),
      folders.allSatisfy(Self.imapFolderName)
    else { throw RegistrationError.unavailable }
    let result = try await imapWork(connection: connection, address: address, generation: generation) {
      try await imap.search($0, password: $1, query: query, folders: folders, limit: 50)
    }
    return [
      "folders": result.found.map { found in
        [
          "folder": found.folder, "uidValidity": Double(found.uidValidity),
          "messages": found.messages.map(Self.envelopeReply), "more": found.more,
        ] as [String: Any]
      },
      "skipped": Double(result.skipped),
    ]
  }

  // Waits for a change in the folder for up to `seconds`; rejects `imap-unsupported` without IDLE.
  func imapIdle(
    connection: String, address: String, generation: String, folder: String, seconds: Int
  ) async throws -> [String: Any] {
    guard Self.imapFolderName(folder), (1...600).contains(seconds) else {
      throw RegistrationError.unavailable
    }
    let changed = try await imapWork(connection: connection, address: address, generation: generation) {
      try await imap.idle($0, password: $1, folder: folder, seconds: seconds)
    }
    return ["changed": changed]
  }

  private nonisolated static func imapFolderName(_ name: String) -> Bool {
    !name.isEmpty && name.count <= 1_000
  }

  private nonisolated static func envelopeReply(_ envelope: ImapEnvelope) -> [String: Any] {
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
}
