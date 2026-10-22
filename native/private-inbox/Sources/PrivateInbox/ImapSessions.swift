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
  func close() async
}

#if canImport(SwiftMail)
  final class SwiftMailImapSession: ImapSession {
    private static let folderLimit = 1_000
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
        let listed = try await server.listMailboxes()
        guard listed.count <= Self.folderLimit else { throw RegistrationError.unavailable }
        return listed.map { info in
          ImapListedFolder(
            name: info.name,
            attributes: Self.attributes.filter { info.attributes.contains($0.0) }.map(\.1),
            delimiter: info.hierarchyDelimiter)
        }
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
    var opened: (any ImapSession)?
    do {
      try await imapWork(connection: connection, address: address, generation: generation) {
        opened = try await imap.open($0, password: $1)
      }
      guard let session = opened,
        imapHandles.values.filter({ $0.connection == connection }).count
          < imapSessionLimits.perConnection
      else { throw RegistrationError.unavailable }
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
