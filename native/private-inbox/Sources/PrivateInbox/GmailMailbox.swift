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

  // Gmail's largest message through its messages.send upload.
  static let gmailMessageLimit = 35 * 1024 * 1024

  // The one Gmail send: a message TypeScript composed as ASCII text, with each named Draft Asset's
  // verified bytes inserted here as base64 lines, so an asset's bytes never cross the bridge. Any
  // failure once the request starts may follow Gmail accepting the message: deliveryUnknown.
  func gmailSend(
    segments: [Any], threadId: String?, connection: String, address: String, generation: String
  ) async throws -> [String: Any] {
    let owner = try mailboxAccount(connection).productAccountId
    guard
      threadId?.range(of: "^[0-9A-Za-z]{1,100}$", options: .regularExpression) != nil
        || threadId == nil
    else { throw RegistrationError.unavailable }
    var message = Data()
    for segment in segments {
      let segment = segment as? [String: Any]
      if let text = segment?["text"] as? String, text.utf8.allSatisfy({ $0 < 0x80 }) {
        message.append(Data(text.utf8))
      } else if let asset = segment?["asset"] as? [String: Any],
        let id = asset["id"] as? String,
        id.range(of: "^[0-9a-z]{8,64}$", options: .regularExpression) != nil,
        let digest = asset["digest"] as? String,
        digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
      {
        let bytes: Data
        do {
          bytes = try await draftAssetBytes(owner: owner, id: id, digest: digest)
        } catch PrivateInboxError.invalidStore {
          // Bytes that no longer verify against their digest are not sent either.
          throw PrivateInboxError.attachmentMissing
        }
        message.append(
          bytes.base64EncodedData(options: [
            .lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed,
          ]))
      } else {
        throw RegistrationError.unavailable
      }
      guard message.count <= Self.gmailMessageLimit else { throw PrivateInboxError.tooLarge }
    }
    // Gmail's multipart upload: the thread to join, then the message.
    let boundary = "unwired-upload-" + UUID().uuidString
    var body = Data(
      "--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
    body.append(
      try JSONSerialization.data(withJSONObject: threadId.map { ["threadId": $0] } ?? [:]))
    body.append(Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8))
    body.append(message)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    guard
      let url = URL(
        string:
          "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart"
      )
    else { throw RegistrationError.unavailable }
    return try await gmail(
      url: url, body: body, contentType: "multipart/related; boundary=" + boundary,
      connection: connection, address: address, generation: generation, sending: true)
  }

  // Resolves the HTTP status and body. A grant Google refuses to renew is gmailUnavailable, which
  // asks for authorization again; a renewal that cannot reach Google is unavailable, a retry.
  // While `sending`, a failure once the request starts is deliveryUnknown, and Gmail's answer is
  // returned whatever changed meanwhile, as the message may already be sent.
  private func gmail(
    url: URL, body: Data?, contentType: String = "application/json", connection id: String,
    address: String, generation expectedGeneration: String, sending: Bool = false
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
    try Task.checkCancellation()
    guard identity.subject == mailbox.subject else { throw RegistrationError.gmailUnavailable }
    guard current() else { throw PrivateInboxError.mailboxInvalidated }
    // Keep a renewed access token unless the connection changed while it was renewed.
    if identity.credential != credential, var latest = try load(),
      latest.connection(id)?.credential == credential
    {
      latest.update(id) { $0.credential = identity.credential }
      try save(latest)
    }
    let status: Int
    let data: Data
    do {
      (status, data) = try await provider.gmail(
        identity, url: url, body: body, contentType: contentType)
    } catch where sending {
      throw PrivateInboxError.deliveryUnknown
    }
    guard sending || current() else { throw PrivateInboxError.mailboxInvalidated }
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
    discard: @escaping @Sendable (PrivateInboxStore, Value) throws -> Void = { _, _ in },
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
    do {
      guard mailCache.isProtectedDataAvailable() else { throw PrivateInboxError.locked }
      _ = try bodyOwner(
        connection: connection, address: address, generation: generation, verified: verified)
    } catch {
      do { try await Task.detached { try discard(mailCache, value) }.value } catch {
        Self.logProductSyncFailure("Unacknowledged attachment cleanup failed", error)
      }
      throw error
    }
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

// Downloaded Attachments: bytes TypeScript verified come from the verified mailbox's Gmail, and
// only the current generation of a connection saves or presents its files.
extension RegistrationStore {
  func saveAttachment(
    connection: String, address: String, generation: String, name: String, data: String,
    size: Int, protectedFiles: Set<String> = []
  ) async throws -> [String: Any] {
    let file = try await bodyWork(
      connection: connection, address: address, generation: generation, verified: true,
      discard: { try $0.discardAttachment(connection: connection, file: $1) }
    ) { store, _ in
      try store.saveAttachment(
        connection: connection, name: name, data: data, size: size, protectedFiles: protectedFiles)
    }
    return ["file": file]
  }

  // Deleting is always allowed, including after a removal or another verification.
  func discardAttachment(connection: String, file: String) async throws {
    guard let mailCache else { return }
    try await Task.detached(priority: .userInitiated) {
      try mailCache.discardAttachment(connection: connection, file: file)
    }.value
  }

  func attachmentFile(connection: String, address: String, generation: String, file: String)
    async throws -> URL
  {
    let url = try await bodyWork(
      connection: connection, address: address, generation: generation, verified: false
    ) { store, _ in try store.attachmentFile(connection: connection, file: file) }
    guard let url else { throw PrivateInboxError.attachmentMissing }
    return url
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
  static func send(
    token: String, url: URL, body: Data?, session: URLSession,
    limit: Int = 40 * 1024 * 1024, contentType: String = "application/json"
  ) async throws -> (Int, Data) {
    var request = URLRequest(url: url)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    if let body {
      request.httpMethod = "POST"
      request.httpBody = body
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }
    request.timeoutInterval = 30
    do {
      // Data arrives in URLSession's chunks, bounded as each one arrives, so a large response
      // never costs one async iteration per byte while the operation gate is held.
      let receiver = BoundedResponse(limit: limit)
      let task = session.dataTask(with: request)
      task.delegate = receiver
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          receiver.start(continuation)
          task.resume()
        }
      } onCancel: {
        task.cancel()
      }
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw RegistrationError.unavailable
    }
  }
}

// One response's status and body, refused once it exceeds the limit, whether its length is
// declared or streamed.
final class BoundedResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let limit: Int
  private let lock = NSLock()
  private var status: Int?
  private var data = Data()
  private var overflow = false
  private var continuation: CheckedContinuation<(Int, Data), any Error>?
  private var completion: Result<(Int, Data), any Error>?

  init(limit: Int) { self.limit = limit }

  // Redirects must not carry a mailbox bearer token to another host.
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? { nil }

  func start(_ continuation: CheckedContinuation<(Int, Data), any Error>) {
    let completion: Result<(Int, Data), any Error>? = lock.withLock {
      if let completion { return completion }
      self.continuation = continuation
      return nil
    }
    // Cancelling a suspended task can complete before its continuation is installed.
    if let completion { continuation.resume(with: completion) }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse
  ) async -> URLSession.ResponseDisposition {
    lock.withLock {
      guard let response = response as? HTTPURLResponse,
        response.expectedContentLength <= limit
      else {
        overflow = true
        return .cancel
      }
      status = response.statusCode
      if response.expectedContentLength > 0,
        let length = Int(exactly: response.expectedContentLength)
      {
        data.reserveCapacity(length)
      }
      return .allow
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    let refused = lock.withLock {
      guard !overflow, data.count + chunk.count <= limit else {
        overflow = true
        return true
      }
      data.append(chunk)
      return false
    }
    if refused { dataTask.cancel() }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    let (continuation, result): (CheckedContinuation<(Int, Data), any Error>?, Result<(Int, Data), any Error>) =
      lock.withLock {
        if let completion { return (nil, completion) }
        let continuation = self.continuation
        self.continuation = nil
        let result: Result<(Int, Data), any Error>
        if overflow {
          result = .failure(RegistrationError.unavailable)
        } else if let error {
          result = .failure(error)
        } else if let status {
          result = .success((status, data))
        } else {
          result = .failure(RegistrationError.unavailable)
        }
        completion = result
        return (continuation, result)
      }
    continuation?.resume(with: result)
  }
}
