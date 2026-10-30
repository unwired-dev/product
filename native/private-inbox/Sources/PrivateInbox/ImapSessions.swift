import Foundation

#if canImport(SwiftMail)
  import SwiftMail
#endif

// A folder as the server lists it: its LIST attributes, such as `\Sent` or `\Noselect`, and its
// hierarchy delimiter, such as `/`, which nests one folder name under another.
struct ImapListedFolder: Sendable, Equatable {
  let name: String
  let attributes: [String]
  let delimiter: String?
}

// What a folder search looks for: a short text anywhere in the message, or a MIME boundary in its
// Content-Type header, which marks a Sent copy Unwired filed.
enum ImapSearchCriterion: Sendable, Equatable {
  case text(String)
  case boundary(String)
}

// One authenticated session that TypeScript drives through purpose-named primitives. Closing it
// ends the connection, failing any command still in flight.
protocol ImapSession: Sendable {
  func capabilities() async throws -> [String]
  // Every folder the server lists, in every namespace it declares.
  func folders() async throws -> [ImapListedFolder]
  // Selects the folder read-write for the commands that follow and returns its UIDVALIDITY; refuses
  // a folder the server does not select, one without UIDVALIDITY and a read-only selection.
  func select(_ folder: String) async throws -> UInt32
  // Each change sends one command for one message of the selected folder. Once sent, a failure
  // other than the server's refusal is `interrupted`: the server may have applied it.
  func store(_ uid: UInt32, flag: ImapStoredFlag, set: Bool) async throws
  // MOVE, with where COPYUID says the message went when the server reports it.
  func move(_ uid: UInt32, to destination: String) async throws -> ImapCopy?
  // COPY, with the COPYUID receipt when the server reports one.
  func copy(_ uid: UInt32, to destination: String) async throws -> ImapCopy?
  // UID EXPUNGE of this message alone; a plain EXPUNGE would remove other clients' deleted mail.
  func expunge(_ uid: UInt32) async throws
  // Waits in IDLE on the folder until the server sends an event or `seconds` pass, and reports the
  // kinds of event sent before the wait ended, none when the folder stayed quiet: `exists`,
  // `expunge`, `vanished`, `recent`, `flags`, `fetch`, `alert`, `capability` or `bye`.
  func idle(folder: String, seconds: Int) async throws -> [String]
  // Examines the folder read-only for the reads that follow; refuses one without UIDVALIDITY.
  func examine(_ folder: String) async throws -> ImapSelection
  // Envelopes of the examined folder's messages that `read` names.
  func envelopes(_ read: ImapEnvelopeRead) async throws -> [ImapEnvelope]
  // The flags of each named message still in the selected or examined folder.
  func flags(_ uids: [UInt32]) async throws -> [UInt32: [String]]
  // Examines the folder and searches it; refuses a folder the server no longer selects, one
  // without UIDVALIDITY, and a text in a charset the server cannot search.
  func search(_ folder: String, for criterion: ImapSearchCriterion, newest: Int) async throws
    -> ImapMatches
  // Appends the message to the folder, marked read.
  func append(_ folder: String, message: Data) async throws
  func close() async
}

// The flags a change stores: read state, the star, and deletion before a targeted expunge.
enum ImapStoredFlag: String, Sendable {
  case seen
  case flagged
  case deleted
}

#if canImport(SwiftMail)
  final class SwiftMailImapSession: ImapSession {
    // The LIST attributes SwiftMail reports, by their RFC 3501, 6154 and 8457 names.
    private static let attributes: [(Mailbox.Info.Attributes, String)] = [
      (.noSelect, "\\Noselect"), (.hasChildren, "\\HasChildren"),
      (.hasNoChildren, "\\HasNoChildren"),
      (.marked, "\\Marked"), (.unmarked, "\\Unmarked"), (.archive, "\\Archive"),
      (.drafts, "\\Drafts"), (.flagged, "\\Flagged"), (.junk, "\\Junk"), (.sent, "\\Sent"),
      (.trash, "\\Trash"), (.inbox, "\\Inbox"), (.all, "\\All"), (.important, "\\Important"),
    ]
    private let server: IMAPServer

    init(server: IMAPServer) { self.server = server }

    private func run<Value: Sendable>(_ work: @Sendable (IMAPServer) async throws -> Value)
      async throws -> Value
    {
      do { return try await work(server) } catch { throw SwiftMailImap.failure(error) }
    }

    func capabilities() async throws -> [String] {
      try await run { try await $0.fetchCapabilities().map { String($0) } }
    }

    func folders() async throws -> [ImapListedFolder] {
      try await run { server in
        // SwiftMail ignores namespace discovery failures at login; retirement needs the full list.
        if await server.namespaces == nil {
          let capabilities = try await server.fetchCapabilities()
          if capabilities.contains(where: { String($0) == "NAMESPACE" }) {
            _ = try await server.fetchNamespaces()
          }
        }
        let listed: [Mailbox.Info]
        do {
          listed = try await server.listMailboxes()
        } catch is ExceededListResponseLimitError {
          throw RegistrationError.unavailable
        }
        return listed.map { info in
          ImapListedFolder(
            name: info.name,
            attributes: Self.attributes.filter { info.attributes.contains($0.0) }.map(\.1),
            delimiter: info.hierarchyDelimiter)
        }
      }
    }

    func select(_ folder: String) async throws -> UInt32 {
      try await run { server in
        let selection: Mailbox.Selection
        do {
          selection = try await server.selectMailbox(folder)
        } catch IMAPError.selectFailed {
          throw ImapFailure.missing
        }
        // SwiftMail defaults to zero when SELECT omits UIDVALIDITY. No UID is safe to change then.
        guard selection.uidValidity.value > 0 else { throw ImapFailure.changed }
        guard !selection.isReadOnly else { throw ImapFailure.unsupported }
        return selection.uidValidity.value
      }
    }

    func examine(_ folder: String) async throws -> ImapSelection {
      try await run { server in
        let selection = try await SwiftMailImap.examine(server, folder: folder)
        return ImapSelection(
          uidValidity: selection.uidValidity.value, uidNext: selection.uidNext.value,
          messages: selection.messageCount)
      }
    }

    func envelopes(_ read: ImapEnvelopeRead) async throws -> [ImapEnvelope] {
      try await run { server in
        let infos: [MessageInfo]
        switch read {
        case .uids(let uids):
          infos = try await server.fetchMessageInfosBulk(
            using: UIDSet(uids.map(UID.init)), options: .slim)
        case .from(let uid):
          infos = try await server.fetchMessageInfos(uidRange: UID(uid)..., options: .slim)
        case .newest(let count, let total):
          infos = try await server.fetchMessageInfos(
            sequenceRange: SequenceNumber(max(1, total - count + 1))...SequenceNumber(total),
            options: .slim)
        }
        return infos.compactMap(SwiftMailImap.envelope)
      }
    }

    func flags(_ uids: [UInt32]) async throws -> [UInt32: [String]] {
      try await run { server in
        let present = try await server.fetchMessageInfosBulk(
          using: UIDSet(uids.map(UID.init)), options: .uidFlagsOnly)
        var flags: [UInt32: [String]] = [:]
        for info in present {
          if let uid = info.uid?.value { flags[uid] = info.flags.map(SwiftMailImap.flag) }
        }
        return flags
      }
    }

    func store(_ uid: UInt32, flag: ImapStoredFlag, set: Bool) async throws {
      let stored: Flag =
        switch flag {
        case .seen: .seen
        case .flagged: .flagged
        case .deleted: .deleted
        }
      try await change {
        try await $0.store(flags: [stored], on: UIDSet(UID(uid)), operation: set ? .add : .remove)
      }
    }

    func move(_ uid: UInt32, to destination: String) async throws -> ImapCopy? {
      Self.receipt(
        try await change {
          try await $0.move(messages: UIDSet(UID(uid)), to: destination, fallback: .disabled)
        }, uid)
    }

    func copy(_ uid: UInt32, to destination: String) async throws -> ImapCopy? {
      Self.receipt(try await change { try await $0.copy(messages: UIDSet(UID(uid)), to: destination) }, uid)
    }

    func expunge(_ uid: UInt32) async throws {
      try await change { try await $0.expunge(messages: UIDSet(UID(uid))) }
    }

    // Runs one change command. Partial completion is uncertain; a definite refusal does not
    // authorize another attempt.
    private func change<Value: Sendable>(_ work: @Sendable (IMAPServer) async throws -> Value)
      async throws -> Value
    {
      do {
        return try await work(server)
      } catch let error as IMAPError {
        switch error {
        case .moveFailedAfterPossiblePartialCompletion, .moveFailedAfterPartialCompletion,
          .moveFallbackFailedAfterCopy:
          throw ImapFailure.interrupted
        case .storeFailed, .copyFailed, .moveFailed, .expungeFailed, .commandFailed:
          throw ImapFailure.rejected
        // SwiftMail refuses before sending when the server lacks MOVE or UIDPLUS.
        case .commandNotSupported: throw ImapFailure.unsupported
        default: throw ImapFailure.interrupted
        }
      } catch let error as CancellationError {
        throw error
      } catch {
        throw ImapFailure.interrupted
      }
    }

    // Where COPYUID says the message went, when the server reported it.
    private static func receipt(_ copied: CopyUID?, _ uid: UInt32) -> ImapCopy? {
      guard let copied, copied.destinationUIDValidity.value > 0,
        let mapped = copied.mapping.first(where: { $0.source.value == uid }),
        mapped.destination.value > 0
      else { return nil }
      return ImapCopy(uidValidity: copied.destinationUIDValidity.value, uid: mapped.destination.value)
    }

    func search(_ folder: String, for criterion: ImapSearchCriterion, newest: Int) async throws
      -> ImapMatches
    {
      let search: SearchCriteria =
        switch criterion {
        case .text(let text): .text(text)
        case .boundary(let boundary): .header("Content-Type", boundary)
        }
      return try await run { server in
        let selection: Mailbox.Selection
        do {
          selection = try await SwiftMailImap.examine(server, folder: folder)
        } catch IMAPError.selectFailed {
          throw ImapFailure.missing
        }
        let matches: UIDSet
        do {
          matches = try await server.extendedSearch(criteria: [search]).all ?? UIDSet()
        } catch IMAPError.searchCharsetNotSupported {
          throw ImapFailure.unsupported
        }
        // The newest, without expanding ranges an untrusted server may report billions wide.
        let uids = matches.ranges.reversed().lazy.flatMap { $0.reversed() }.prefix(newest)
          .map { UInt32($0) }
        return ImapMatches(
          uidValidity: selection.uidValidity.value, uids: Array(uids), total: matches.count)
      }
    }

    func append(_ folder: String, message: Data) async throws {
      try await run { server in
        _ = try await server.append(
          rawMessage: String(decoding: message, as: UTF8.self), to: folder, flags: [.seen],
          internalDate: nil)
      }
    }

    func idle(folder: String, seconds: Int) async throws -> [String] {
      try await run { server in
        _ = try await SwiftMailImap.examine(server, folder: folder)
        let events = try await server.idle()
        let deadline = ContinuousClock.now + .seconds(seconds)
        // DONE ends the stream once the server acknowledges it, after any events it sent first.
        let bound = Task {
          try await Task.sleep(until: deadline)
          try? await server.done()
        }
        defer { bound.cancel() }
        var kinds: [String] = []
        for await event in events {
          let kind = Self.kind(event)
          guard !kinds.contains(kind) else { continue }
          kinds.append(kind)
          if kinds.count == 1 {
            bound.cancel()
            try? await server.done()
          }
        }
        // A stream that ends quietly before its bound lost the connection.
        if kinds.isEmpty, ContinuousClock.now < deadline { throw ImapFailure.offline }
        return kinds
      }
    }

    private static func kind(_ event: IMAPServerEvent) -> String {
      switch event {
      case .exists: "exists"
      case .expunge: "expunge"
      case .vanished: "vanished"
      case .recent: "recent"
      case .flags: "flags"
      case .fetch, .fetchUID: "fetch"
      case .alert: "alert"
      case .capability: "capability"
      case .bye: "bye"
      }
    }

    // Closes without LOGOUT, which would wait behind a command still in flight.
    func close() async { try? await server.disconnect() }
  }
#endif

extension RegistrationStore {
  // Opens a session for a verified connection at the generation the caller opened. TypeScript runs
  // one operation in it and closes it; it also closes when the generation changes, when it stays
  // unused or open too long, and only a few may be open per connection.
  func imapOpen(connection: String, address: String, generation: String) async throws
    -> [String: Any]
  {
    closeStaleImapSessions()
    func full() -> Bool {
      imapHandles.values.filter { $0.connection == connection }.count
        >= imapSessionLimits.perConnection
    }
    // A full connection logs in no further. The registration gate serializes opens from
    // TypeScript; the check after login covers concurrent callers outside it.
    guard !full() else { throw RegistrationError.unavailable }
    var opened: (any ImapSession)?
    do {
      try await imapWork(connection: connection, address: address, generation: generation) {
        opened = try await imap.open($0, password: $1)
      }
      guard let session = opened, !full() else { throw RegistrationError.unavailable }
      let id = UUID().uuidString
      imapHandles[id] = ImapHandle(
        connection: connection, address: address, generation: mailboxGeneration(connection),
        subject: try imapConnection(connection).2.receipt.subject, session: session)
      scheduleImapSweep()
      return ["session": id]
    } catch {
      await opened?.close()
      throw error
    }
  }

  func imapCapabilities(connection: String, address: String, generation: String, session: String)
    async throws -> [String: Any]
  {
    let capabilities = try await imapCommand(
      session, connection: connection, address: address, generation: generation
    ) { try await $0.capabilities() }
    return ["capabilities": capabilities]
  }

  func imapListFolders(connection: String, address: String, generation: String, session: String)
    async throws -> [String: Any]
  {
    let folders = try await imapCommand(
      session, connection: connection, address: address, generation: generation
    ) { try await $0.folders() }
    return [
      "folders": folders.map {
        var folder: [String: Any] = ["name": $0.name, "attributes": $0.attributes]
        folder["delimiter"] = $0.delimiter
        return folder
      }
    ]
  }

  func imapSelect(
    connection: String, address: String, generation: String, session: String, folder: String
  ) async throws -> [String: Any] {
    guard Self.imapFolderName(folder) else { throw RegistrationError.unavailable }
    let uidValidity = try await imapCommand(
      session, connection: connection, address: address, generation: generation
    ) { try await $0.select(folder) }
    return ["uidValidity": Double(uidValidity)]
  }

  // Waits in IDLE on the folder for up to `seconds`; resolves the kinds of event the server sent.
  func imapIdle(
    connection: String, address: String, generation: String, session: String, folder: String,
    seconds: Int
  ) async throws -> [String: Any] {
    guard Self.imapFolderName(folder), (1...600).contains(seconds) else {
      throw RegistrationError.unavailable
    }
    let events = try await imapCommand(
      session, connection: connection, address: address, generation: generation
    ) { try await $0.idle(folder: folder, seconds: seconds) }
    return ["events": events]
  }

  func imapExamine(
    connection: String, address: String, generation: String, session: String, folder: String
  ) async throws -> [String: Any] {
    guard Self.imapFolderName(folder) else { throw RegistrationError.unavailable }
    let selection = try await imapCommand(
      session, connection: connection, address: address, generation: generation
    ) { try await $0.examine(folder) }
    return [
      "uidValidity": Double(selection.uidValidity), "uidNext": Double(selection.uidNext),
      "messages": Double(selection.messages),
    ]
  }

  // At most 200 named or newest messages; `UID n:*` is bounded by the server's arrivals.
  func imapEnvelopes(
    connection: String, address: String, generation: String, session: String,
    read: ImapEnvelopeRead
  ) async throws -> [String: Any] {
    let bounded =
      switch read {
      case .uids(let uids): Self.imapUids(uids)
      case .from(let uid): uid > 0
      case .newest(let count, let total): (1...200).contains(count) && total > 0
      }
    guard bounded else { throw RegistrationError.unavailable }
    let envelopes = try await imapCommand(
      session, connection: connection, address: address, generation: generation
    ) { try await $0.envelopes(read) }
    return ["messages": envelopes.map(Self.envelopeReply)]
  }

  // The flags of at most 200 named messages; a message no longer in the folder is left out.
  func imapFlags(
    connection: String, address: String, generation: String, session: String, uids: [UInt32]
  ) async throws -> [String: Any] {
    guard Self.imapUids(uids) else { throw RegistrationError.unavailable }
    let flags = try await imapCommand(
      session, connection: connection, address: address, generation: generation
    ) { try await $0.flags(uids) }
    return ["flags": flags.map { ["uid": Double($0.key), "flags": $0.value] as [String: Any] }]
  }

  func imapStore(
    connection: String, address: String, generation: String, session: String, uid: UInt32,
    flag: ImapStoredFlag, set: Bool
  ) async throws -> [String: Any] {
    guard uid > 0 else { throw RegistrationError.unavailable }
    try await imapCommand(session, connection: connection, address: address, generation: generation) {
      try await $0.store(uid, flag: flag, set: set)
    }
    return [:]
  }

  // A move or copy resolves `{ uidValidity, uid }` where the server reported the message went.
  func imapMove(
    connection: String, address: String, generation: String, session: String, uid: UInt32,
    destination: String
  ) async throws -> [String: Any] {
    guard uid > 0, Self.imapFolderName(destination) else { throw RegistrationError.unavailable }
    return Self.receiptReply(
      try await imapCommand(session, connection: connection, address: address, generation: generation) {
        try await $0.move(uid, to: destination)
      })
  }

  func imapCopy(
    connection: String, address: String, generation: String, session: String, uid: UInt32,
    destination: String
  ) async throws -> [String: Any] {
    guard uid > 0, Self.imapFolderName(destination) else { throw RegistrationError.unavailable }
    return Self.receiptReply(
      try await imapCommand(session, connection: connection, address: address, generation: generation) {
        try await $0.copy(uid, to: destination)
      })
  }

  func imapExpunge(
    connection: String, address: String, generation: String, session: String, uid: UInt32
  ) async throws -> [String: Any] {
    guard uid > 0 else { throw RegistrationError.unavailable }
    try await imapCommand(session, connection: connection, address: address, generation: generation) {
      try await $0.expunge(uid)
    }
    return [:]
  }

  private nonisolated static func receiptReply(_ receipt: ImapCopy?) -> [String: Any] {
    receipt.map { ["uidValidity": Double($0.uidValidity), "uid": Double($0.uid)] } ?? [:]
  }

  // The server's search of one folder for a short text or a Sent copy's boundary: its newest
  // matches, at most 200, and how many matched in all.
  func imapSearch(
    connection: String, address: String, generation: String, session: String, folder: String,
    for criterion: ImapSearchCriterion, newest: Int
  ) async throws -> [String: Any] {
    guard Self.imapFolderName(folder), Self.imapCriterion(criterion), (1...200).contains(newest)
    else { throw RegistrationError.unavailable }
    let matches = try await imapCommand(
      session, connection: connection, address: address, generation: generation
    ) { try await $0.search(folder, for: criterion, newest: newest) }
    return [
      "uidValidity": Double(matches.uidValidity), "uids": matches.uids.map(Double.init),
      "total": Double(matches.total),
    ]
  }

  // A text without control characters, or one of the boundaries TypeScript chooses, which a quoted
  // IMAP search carries unchanged.
  private nonisolated static func imapCriterion(_ criterion: ImapSearchCriterion) -> Bool {
    switch criterion {
    case .text(let text):
      !text.isEmpty && text.count <= 200 && text.rangeOfCharacter(from: .controlCharacters) == nil
    case .boundary(let boundary):
      boundary.range(of: "^[0-9A-Za-z=_.-]{8,70}$", options: .regularExpression) != nil
    }
  }

  // Appends a Sent copy TypeScript composed, read, to the folder. Filing is a provider write, so it
  // needs a current device proof.
  func imapAppend(
    connection: String, address: String, generation: String, session: String, folder: String,
    segments: [Any]
  ) async throws -> [String: Any] {
    guard Self.imapFolderName(folder) else { throw RegistrationError.unavailable }
    let product = try mailboxAccount(connection)
    let message = try await outgoingMessage(segments: segments, owner: product.productAccountId)
    try await requireTrustedDevice(product)
    try await imapCommand(
      session, connection: connection, address: address, generation: generation
    ) { try await $0.append(folder, message: message) }
    return [:]
  }

  private nonisolated static func imapUids(_ uids: [UInt32]) -> Bool {
    (1...200).contains(uids.count) && uids.allSatisfy { $0 > 0 }
  }

  // Closes the connection's session, cancelling a command in flight; an unknown one is ignored.
  func imapClose(connection: String, session id: String) {
    if imapHandles[id]?.connection == connection { closeImapSession(id) }
  }

  // Runs one command on an open session of this connection generation. A closed, expired or stale
  // session is refused, and so is a command while another is in flight.
  private func imapCommand<Value: Sendable>(
    _ id: String, connection: String, address: String, generation: String,
    _ work: @escaping @Sendable (any ImapSession) async throws -> Value
  ) async throws -> Value {
    closeStaleImapSessions()
    let handle = try currentImapHandle(
      id, connection: connection, address: address, generation: generation)
    guard handle.command == nil else { throw RegistrationError.unavailable }
    let session = handle.session
    defer {
      handle.command = nil
      handle.used = .now
    }
    // Closing answers the caller at once. SwiftMail 1.16 cannot abort a command on the wire, so
    // the connection closes once that command answers or times out.
    let value: Value = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Value, any Error>) in
      let reply = ImapReply<Value>(continuation)
      let command = Task { @MainActor in
        do {
          let value = try await work(session)
          reply.resume(.success(value))
        } catch {
          reply.resume(.failure(error))
        }
      }
      handle.command = {
        command.cancel()
        reply.resume(.failure(PrivateInboxError.mailboxInvalidated))
      }
    }
    _ = try currentImapHandle(id, connection: connection, address: address, generation: generation)
    return value
  }

  private func currentImapHandle(
    _ id: String, connection: String, address: String, generation: String
  ) throws -> ImapHandle {
    guard let handle = imapHandles[id], handle.connection == connection,
      handle.address == address, handle.generation.uuidString == generation,
      (try? mailboxAccount(connection)) != nil,
      (try? imapConnection(connection))?.2.receipt.subject == handle.subject
    else { throw PrivateInboxError.mailboxInvalidated }
    return handle
  }

  // Closes sessions from another connection generation or an unverified connection, and those
  // unused or open longer than their limits.
  func closeStaleImapSessions() {
    let now = ContinuousClock.now
    for (id, handle) in imapHandles
    where handle.generation != mailboxGenerations[handle.connection]
      || !verifiedMailboxes.contains(handle.connection)
      || (handle.command == nil && now - handle.used > imapSessionLimits.idle)
      || now - handle.opened > imapSessionLimits.lifetime
    {
      closeImapSession(id)
    }
  }

  private func closeImapSession(_ id: String) {
    guard let handle = imapHandles.removeValue(forKey: id) else { return }
    handle.command?()
    let session = handle.session
    Task { await session.close() }
  }

  // Closes abandoned sessions while any are open.
  private func scheduleImapSweep() {
    guard imapSweep == nil else { return }
    imapSweep = Task { [weak self] in
      while let interval = self?.imapSessionLimits.idle {
        try? await Task.sleep(for: interval / 2)
        guard let self else { return }
        closeStaleImapSessions()
        if imapHandles.isEmpty {
          imapSweep = nil
          return
        }
      }
    }
  }
}

// An open IMAP session and the connection generation it belongs to.
@MainActor final class ImapHandle {
  let connection: String
  let address: String
  let generation: UUID
  let subject: String
  let session: any ImapSession
  let opened = ContinuousClock.now
  var used = ContinuousClock.now
  // Cancels the command in flight.
  var command: (() -> Void)?

  init(
    connection: String, address: String, generation: UUID, subject: String,
    session: any ImapSession
  ) {
    self.connection = connection
    self.address = address
    self.generation = generation
    self.subject = subject
    self.session = session
  }
}

// A command's caller, answered once: by the command, or by its session closing first.
@MainActor private final class ImapReply<Value: Sendable> {
  private var continuation: CheckedContinuation<Value, any Error>?
  init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }
  func resume(_ result: Result<Value, any Error>) {
    continuation?.resume(with: result)
    continuation = nil
  }
}

struct ImapSessionLimits {
  var idle = Duration.seconds(60)
  // Longer than the longest IDLE wait.
  var lifetime = Duration.seconds(900)
  var perConnection = 4
}
