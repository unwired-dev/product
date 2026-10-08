import Foundation

// Registration changes and mailbox access must not undo one another across suspension.
@MainActor public final class RegistrationOperationGate {
  private var active = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  public init() {}

  public func perform<Value>(_ operation: () async throws -> Value) async rethrows -> Value {
    if active { await withCheckedContinuation { waiting.append($0) } } else { active = true }
    defer {
      if waiting.isEmpty { active = false } else { waiting.removeFirst().resume() }
    }
    return try await operation()
  }
}

// Gmail requests and the mailbox cache for TypeScript's Inbox synchronization. TypeScript chooses the
// Gmail resource and owns the cached document; the mailbox credential never leaves this file.
extension RegistrationStore {
  // Only known transport failures permit reading the last verified mailbox's local cache.
  static func transientMailboxFailure(_ error: any Error) -> Bool {
    let value = error as NSError
    if value.domain == NSURLErrorDomain {
      return [
        URLError.notConnectedToInternet.rawValue, URLError.timedOut.rawValue,
        URLError.networkConnectionLost.rawValue, URLError.cannotFindHost.rawValue,
        URLError.cannotConnectToHost.rawValue,
      ].contains(value.code)
    }
    return value.domain == "org.openid.appauth.general" && [-5, -6].contains(value.code)
  }

  // Every usable connection opens from its cache only, until registration verifies again.
  func cachedMailbox(_ saved: SavedRegistration) throws -> [String: String]? {
    guard saved.product != nil, saved.accountRemoval == nil, !saved.usableConnections.isEmpty
    else { return nil }
    for connection in saved.usableConnections {
      verifiedMailboxes.remove(connection.id)
      cacheOnlyMailboxes.insert(connection.id)
    }
    return try status(saved)
  }

  // The account this device still holds; a purged or removing one invalidates mailbox work.
  func mailboxAccount(_ id: String) throws -> ProductRegistrationReceipt {
    guard let saved = try load(), saved.accountRemoval == nil, let product = saved.product else {
      throw PrivateInboxError.mailboxInvalidated
    }
    _ = try connectedMailbox(id)
    return product
  }

  // Runs when a synchronization opens or commits the cache, not for each Gmail read, so the backend
  // sees no per-message activity. A failed revocation query permits offline cache access; a
  // positive rejection purges first and reports the removal, so the Inbox can hand over to the
  // account page's explanation instead of retrying an invalidated mailbox.
  func prepareMailbox(_ id: String) async throws {
    let generation = mailboxGeneration(id)
    let product = try mailboxAccount(id)
    do {
      try await requireNotRevoked(product)
    } catch RegistrationError.revoked {
      _ = try await purge()
      throw RegistrationError.revoked
    }
    guard generation == mailboxGeneration(id) else { throw PrivateInboxError.mailboxInvalidated }
    _ = try mailboxAccount(id)
  }

  // Only reads of the connected mailbox's own resources reach the credential.
  static func gmailURL(path: String, query: [URLQueryItem]) throws -> URL {
    guard
      path.range(
        of: "^(profile|history|labels|messages(/[0-9A-Za-z]+(/attachments/[0-9A-Za-z_-]+)?)?)$",
        options: .regularExpression) != nil,
      var components = URLComponents(
        string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)
    else { throw RegistrationError.unavailable }
    components.queryItems = query.isEmpty ? nil : query
    // Foundation leaves `+` as is, which Google reads as a space, as in a search for `a+b@`.
    components.percentEncodedQuery = components.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    guard let url = components.url else { throw RegistrationError.unavailable }
    return url
  }

  // A connection that is gone or needs authorization again reaches no credential.
  func connectedMailbox(_ id: String) throws -> (Data, GmailRegistrationReceipt) {
    guard let saved = try load(), saved.accountRemoval == nil, let connection = saved.connection(id),
      connection.authorizationNeeded != true
    else { throw RegistrationError.gmailUnavailable }
    return (connection.credential, connection.receipt)
  }

  // Invalidates a connection's suspended work, then removes its cache.
  func forgetConnection(_ id: String) async throws {
    mailboxGenerations[id] = UUID()
    verifiedMailboxes.remove(id)
    cacheOnlyMailboxes.remove(id)
    try await removeMailboxCache(id)
  }

  func gmail(
    path: String, query: [URLQueryItem], connection: String, address: String, generation: String
  ) async throws -> [String: Any] {
    try await gmail(
      url: Self.gmailURL(path: path, query: query), body: nil, connection: connection,
      address: address, generation: generation)
  }

  // The one Gmail write: a label change of one message. This file writes the body, so only label
  // identifiers cross from TypeScript.
  func gmailModify(
    message: String, add: [String], remove: [String], connection: String, address: String,
    generation: String
  ) async throws -> [String: Any] {
    func valid(_ value: String, _ pattern: String) -> Bool {
      value.range(of: pattern, options: .regularExpression) != nil
    }
    guard valid(message, "^[0-9A-Za-z]+$"), add.count + remove.count <= 100,
      (add + remove).allSatisfy({ valid($0, "^[0-9A-Za-z_]{1,100}$") }),
      let url = URL(
        string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(message)/modify")
    else { throw RegistrationError.unavailable }
    let body = try JSONSerialization.data(withJSONObject: [
      "addLabelIds": add, "removeLabelIds": remove,
    ])
    return try await gmail(
      url: url, body: body, connection: connection, address: address, generation: generation)
  }

  // Resolves the HTTP status and body. A grant Google refuses to renew is gmailUnavailable, which
  // asks for authorization again; a renewal that cannot reach Google is unavailable, a retry.
  private func gmail(
    url: URL, body: Data?, connection id: String, address: String,
    generation expectedGeneration: String
  ) async throws -> [String: Any] {
    let generation = mailboxGeneration(id)
    // Work from before a removal or another verification is stale, whatever the connection's
    // state now.
    guard generation.uuidString == expectedGeneration else {
      throw PrivateInboxError.mailboxInvalidated
    }
    _ = try mailboxAccount(id)
    guard verifiedMailboxes.contains(id) else { throw RegistrationError.unavailable }
    let (credential, mailbox) = try connectedMailbox(id)
    guard mailbox.address == address, generation.uuidString == expectedGeneration else {
      throw PrivateInboxError.mailboxInvalidated
    }
    // Still this connection, verified, at the generation this request started in. A purge or
    // removal changes the generation first, so it reads as invalidated rather than refused.
    func current() -> Bool {
      generation == mailboxGeneration(id) && verifiedMailboxes.contains(id)
        && (try? connectedMailbox(id))?.1.subject == mailbox.subject
    }
    // A mutation requires a current Trusted Device proof. Offline cache reads may use the
    // permissive preflight, but a failed proof must never authorize a provider write.
    if body != nil {
      let product = try mailboxAccount(id)
      guard let deviceRevoked else { throw RegistrationError.unavailable }
      if try await deviceRevoked(product) {
        _ = try await purge()
        throw RegistrationError.revoked
      }
      guard current() else { throw PrivateInboxError.mailboxInvalidated }
    }
    let identity: GoogleRegistrationIdentity
    do {
      identity = try await provider.refresh(credential)
    } catch is CancellationError {
      throw CancellationError()
    } catch is RegistrationError {
      throw RegistrationError.gmailUnavailable
    } catch  where (error as NSError).domain == "org.openid.appauth.oauth_token" {
      throw RegistrationError.gmailUnavailable
    } catch {
      throw RegistrationError.unavailable
    }
    guard identity.subject == mailbox.subject else { throw RegistrationError.gmailUnavailable }
    guard current() else { throw PrivateInboxError.mailboxInvalidated }
    // Keep a renewed access token unless the connection changed while it was renewed.
    if identity.credential != credential, var latest = try load(),
      latest.connection(id)?.credential == credential
    {
      latest.update(id) { $0.credential = identity.credential }
      try save(latest)
    }
    let (status, data) = try await provider.gmail(identity, url: url, body: body)
    guard current() else { throw PrivateInboxError.mailboxInvalidated }
    return ["status": status, "body": String(decoding: data, as: UTF8.self)]
  }

  func openMailbox(_ id: String) throws -> [String: Any] {
    guard let mailCache else { throw RegistrationError.unavailable }
    guard verifiedMailboxes.contains(id) || cacheOnlyMailboxes.contains(id) else {
      throw RegistrationError.gmailUnavailable
    }
    let mailbox = try connectedMailbox(id).1
    var result = try mailCache.openMailbox(
      connection: id, address: mailbox.address, subject: mailbox.subject)
    result["generation"] = mailboxGeneration(id).uuidString
    let product = try mailboxAccount(id)
    result["owner"] = [product.productAccountId, product.trustedDeviceId, mailbox.subject,
      try load()?.connection(id)?.epoch ?? "legacy"].joined(separator: "\n")
    if !verifiedMailboxes.contains(id) { result["availability"] = "retry" }
    return result
  }

  // A commit read for another mailbox or connection, or after removal began, changes nothing.
  func commitMailbox(
    connection id: String, address: String, expectedRevision: Int, document: String,
    generation: String
  ) throws
    -> [String: Any]
  {
    guard let mailCache else { throw RegistrationError.unavailable }
    guard mailboxGeneration(id).uuidString == generation else {
      throw PrivateInboxError.mailboxInvalidated
    }
    guard verifiedMailboxes.contains(id) else { throw RegistrationError.unavailable }
    let mailbox = try connectedMailbox(id).1
    guard mailbox.address == address, mailboxGeneration(id).uuidString == generation else {
      throw PrivateInboxError.mailboxInvalidated
    }
    var result = try mailCache.commitMailbox(
      connection: id, address: address, subject: mailbox.subject,
      expectedRevision: expectedRevision, document: document)
    result["generation"] = generation
    let product = try mailboxAccount(id)
    result["owner"] = [product.productAccountId, product.trustedDeviceId, mailbox.subject,
      try load()?.connection(id)?.epoch ?? "legacy"].joined(separator: "\n")
    return result
  }

  // The connection's Google account, when the caller's mailbox is still the open one. Saved
  // bodies open in cache-only mode; storing and pruning need the verified mailbox.
  private func bodyOwner(connection id: String, address: String, generation: String, verified: Bool)
    throws -> String
  {
    guard mailCache != nil else { throw RegistrationError.unavailable }
    let open = verifiedMailboxes.contains(id)
    guard open || cacheOnlyMailboxes.contains(id) else { throw RegistrationError.gmailUnavailable }
    guard open || !verified else { throw RegistrationError.unavailable }
    let mailbox = try connectedMailbox(id).1
    guard mailbox.address == address, mailboxGeneration(id).uuidString == generation else {
      throw PrivateInboxError.mailboxInvalidated
    }
    return mailbox.subject
  }

  // Reads, decrypts, encrypts and writes bodies off the main actor. The mailbox operation gate
  // keeps registration changes out until the work ends, protected data is checked here on the
  // main actor, and the caller's mailbox is checked again before any result is published.
  private func bodyWork<Value: Sendable>(
    connection: String, address: String, generation: String, verified: Bool,
    _ work: @escaping @Sendable (PrivateInboxStore, String) throws -> Value
  ) async throws -> Value {
    let subject = try bodyOwner(
      connection: connection, address: address, generation: generation, verified: verified)
    guard let mailCache else { throw RegistrationError.unavailable }
    guard mailCache.isProtectedDataAvailable() else { throw PrivateInboxError.locked }
    let value: Value
    do {
      value = try await Task.detached(priority: .userInitiated) {
        try work(mailCache, subject)
      }.value
    } catch {
      guard mailCache.isProtectedDataAvailable() else { throw PrivateInboxError.locked }
      throw error
    }
    guard mailCache.isProtectedDataAvailable() else { throw PrivateInboxError.locked }
    _ = try bodyOwner(
      connection: connection, address: address, generation: generation, verified: verified)
    return value
  }

  // Removing a cache can delete a large part of the body budget, so it runs off the main actor
  // while the caller keeps the operation gate: registration changes still wait for it to finish.
  func removeMailboxCache(_ id: String) async throws {
    guard let mailCache else { return }
    let legacy = try load()?.legacyCacheConnection == id
    try await Task.detached(priority: .userInitiated) {
      try mailCache.removeMailbox(connection: id, includingLegacy: legacy)
    }
      .value
  }

  // A failed file removal keeps its identifier, but never its credential or an open Inbox.
  func retryMailboxCleanup(_ saved: SavedRegistration) async throws -> SavedRegistration {
    var next = saved
    for id in saved.mailboxCacheRemovals ?? [] {
      do {
        try await forgetConnection(id)
      } catch {
        Self.logProductSyncFailure("Mailbox cache cleanup failed", error)
        continue
      }
      next.mailboxCacheRemovals?.removeAll { $0 == id }
      if next.legacyCacheConnection == id { next.legacyMailboxConnection = nil }
      if next.mailboxCacheRemovals?.isEmpty == true { next.mailboxCacheRemovals = nil }
      try save(next)
    }
    return next
  }

  func removeMailboxCaches() async throws {
    guard let mailCache else { return }
    try await Task.detached(priority: .userInitiated) { try mailCache.removeMailboxes() }.value
  }

  func openMessageBody(connection: String, address: String, generation: String, id: String)
    async throws -> [String: Any]
  {
    let readOnly = !verifiedMailboxes.contains(connection)
    let body = try await bodyWork(
      connection: connection, address: address, generation: generation, verified: false
    ) {
      try $0.openMessageBody(
        connection: connection, address: address, subject: $1, id: id, readOnly: readOnly)
    }
    return ["document": body ?? NSNull()]
  }

  func commitMessageBody(
    connection: String, address: String, generation: String, id: String,
    admission: [String: Any]
  ) async throws -> [String: Any] {
    guard let document = admission["document"] as? String,
      let tier = (admission["tier"] as? String).flatMap(PrivateInboxStore.BodyTier.init(rawName:)),
      let protectedIds = admission["protectedIds"] as? [String]
    else { throw RegistrationError.unavailable }
    let admitted = try await bodyWork(
      connection: connection, address: address, generation: generation, verified: true
    ) {
      try $0.commitMessageBody(
        connection: connection, address: address, subject: $1, id: id, document: document,
        tier: tier, protectedIds: protectedIds)
    }
    return ["admitted": admitted]
  }

  func listMessageBodies(connection: String, address: String, generation: String, ids: [String])
    async throws -> [String: Any]
  {
    let listed = try await bodyWork(
      connection: connection, address: address, generation: generation, verified: false
    ) {
      try $0.listMessageBodies(connection: connection, address: address, subject: $1, ids: ids)
    }
    return ["stored": listed.stored, "excluded": listed.excluded]
  }

  func retainMessageBodies(
    connection: String, address: String, generation: String, expectedRevision: Int,
    ids: [String], protectedIds: [String]
  ) async throws -> [String: Any] {
    try await bodyWork(
      connection: connection, address: address, generation: generation, verified: true
    ) {
      try $0.retainMessageBodies(
        connection: connection, address: address, subject: $1,
        expectedRevision: expectedRevision, ids: ids, protectedIds: protectedIds)
    }
    return [:]
  }
}

extension PrivateInboxStore.BodyTier {
  // TypeScript names tiers by their meaning; files carry the short suffix.
  init?(rawName: String) {
    switch rawName {
    case "opened": self = .opened
    case "prefetched": self = .prefetched
    case "excluded": self = .excluded
    default: return nil
    }
  }
}

// The production Gmail HTTP adapter. Its caller supplies only the native-held credential.
enum GmailTransport {
  static func send(token: String, url: URL, body: Data?, session: URLSession) async throws -> (Int, Data) {
    var request = URLRequest(url: url)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    if let body {
      request.httpMethod = "POST"
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    request.timeoutInterval = 30
    do {
      let (data, response) = try await session.data(for: request, delegate: RefusingRedirects())
      guard let response = response as? HTTPURLResponse else {
        throw RegistrationError.unavailable
      }
      return (response.statusCode, data)
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw RegistrationError.unavailable
    }
  }
}

// Redirects must not carry a mailbox bearer token to another host.
final class RefusingRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? { nil }
}
