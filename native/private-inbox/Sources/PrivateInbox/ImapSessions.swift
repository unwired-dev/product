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

// One authenticated session that TypeScript drives through purpose-named primitives. Closing it
// ends the connection, failing any command still in flight.
protocol ImapSession: Sendable {
  func capabilities() async throws -> [String]
  // Every folder the server lists, in every namespace it declares.
  func folders() async throws -> [ImapListedFolder]
  // Examines the folder read-only for the reads that follow; refuses one without UIDVALIDITY.
  func examine(_ folder: String) async throws -> ImapSelection
  // Envelopes of the examined folder's messages that `read` names.
  func envelopes(_ read: ImapEnvelopeRead) async throws -> [ImapEnvelope]
  // The flags of each named message still in the examined folder.
  func flags(_ uids: [UInt32]) async throws -> [UInt32: [String]]
  // Examines the folder and searches its text; refuses a folder the server no longer selects, one
  // without UIDVALIDITY, and a query in a charset the server cannot search.
  func search(_ folder: String, query: String, newest: Int) async throws -> ImapMatches
  func close() async
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

    func search(_ folder: String, query: String, newest: Int) async throws -> ImapMatches {
      try await run { server in
        let selection: Mailbox.Selection
        do {
          selection = try await SwiftMailImap.examine(server, folder: folder)
        } catch IMAPError.selectFailed {
          throw ImapFailure.missing
        }
        let matches: UIDSet
        do {
          matches = try await server.extendedSearch(criteria: [.text(query)]).all ?? UIDSet()
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

  // The server's search of one folder for a short text: its newest matches, at most 200, and how
  // many matched in all.
  func imapSearch(
    connection: String, address: String, generation: String, session: String, folder: String,
    query: String, newest: Int
  ) async throws -> [String: Any] {
    guard Self.imapFolderName(folder), !query.isEmpty, query.count <= 200,
      query.rangeOfCharacter(from: .controlCharacters) == nil, (1...200).contains(newest)
    else { throw RegistrationError.unavailable }
    let matches = try await imapCommand(
      session, connection: connection, address: address, generation: generation
    ) { try await $0.search(folder, query: query, newest: newest) }
    return [
      "uidValidity": Double(matches.uidValidity), "uids": matches.uids.map(Double.init),
      "total": Double(matches.total),
    ]
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
