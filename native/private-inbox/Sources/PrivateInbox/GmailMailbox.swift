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

// Gmail reads and the mailbox cache for TypeScript's Inbox synchronization. TypeScript chooses the
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

  func cachedMailbox(_ saved: SavedRegistration) throws -> [String: String]? {
    guard saved.product != nil, saved.accountRemoval == nil, saved.mailbox != nil,
      saved.mailboxCredential != nil, saved.mailboxSetupReason == nil
    else { return nil }
    mailboxCacheOnly = true
    var result = try connected(saved)
    result["kind"] = "cached"
    return result
  }

  // The account this device still holds; a purged or removing one invalidates mailbox work.
  func mailboxAccount() throws -> ProductRegistrationReceipt {
    guard let saved = try load(), saved.accountRemoval == nil, let product = saved.product else {
      throw PrivateInboxError.mailboxInvalidated
    }
    _ = try connectedMailbox()
    return product
  }

  // Runs when a synchronization opens or commits the cache, not for each Gmail read, so the backend
  // sees no per-message activity. A failed revocation query permits offline cache access; a
  // positive rejection purges first.
  func prepareMailbox() async throws {
    let generation = mailboxGeneration
    let product = try mailboxAccount()
    do {
      try await requireNotRevoked(product)
    } catch RegistrationError.revoked {
      _ = try purge()
      throw PrivateInboxError.mailboxInvalidated
    }
    guard generation == mailboxGeneration else { throw PrivateInboxError.mailboxInvalidated }
    _ = try mailboxAccount()
  }

  // Only reads of the connected mailbox's own resources reach the credential.
  static func gmailURL(path: String, query: [URLQueryItem]) throws -> URL {
    guard
      path.range(
        of: "^(profile|history|messages(/[0-9A-Za-z]+)?)$", options: .regularExpression) != nil,
      var components = URLComponents(
        string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)
    else { throw RegistrationError.unavailable }
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else { throw RegistrationError.unavailable }
    return url
  }

  func connectedMailbox() throws -> (Data, GmailRegistrationReceipt) {
    guard let saved = try load(), saved.accountRemoval == nil,
      let credential = saved.mailboxCredential, let mailbox = saved.mailbox
    else { throw RegistrationError.gmailUnavailable }
    return (credential, mailbox)
  }

  // Resolves the HTTP status and body. A grant Google refuses to renew is gmailUnavailable, which
  // asks for authorization again; a renewal that cannot reach Google is unavailable, a retry.
  func gmail(
    path: String, query: [URLQueryItem], address: String, generation expectedGeneration: String
  ) async throws -> [String: Any] {
    let url = try Self.gmailURL(path: path, query: query)
    let generation = mailboxGeneration
    _ = try mailboxAccount()
    guard mailboxVerified else { throw RegistrationError.unavailable }
    let (credential, mailbox) = try connectedMailbox()
    guard mailbox.address == address, generation.uuidString == expectedGeneration else {
      throw PrivateInboxError.mailboxInvalidated
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
    guard generation == mailboxGeneration, mailboxVerified,
      try connectedMailbox().1.subject == mailbox.subject
    else { throw PrivateInboxError.mailboxInvalidated }
    // Keep a renewed access token unless the mailbox changed while it was renewed.
    if identity.credential != credential, var latest = try load(),
      latest.mailboxCredential == credential
    {
      latest.mailboxCredential = identity.credential
      try save(latest)
    }
    let (status, data) = try await provider.gmail(identity, url: url)
    guard generation == mailboxGeneration, mailboxVerified,
      try connectedMailbox().1.subject == mailbox.subject
    else { throw PrivateInboxError.mailboxInvalidated }
    return ["status": status, "body": String(decoding: data, as: UTF8.self)]
  }

  func openMailbox() throws -> [String: Any] {
    guard let mailCache else { throw RegistrationError.unavailable }
    guard mailboxVerified || mailboxCacheOnly else { throw RegistrationError.gmailUnavailable }
    let mailbox = try connectedMailbox().1
    var result = try mailCache.openMailbox(address: mailbox.address, subject: mailbox.subject)
    result["generation"] = mailboxGeneration.uuidString
    if mailboxCacheOnly { result["availability"] = "retry" }
    return result
  }

  // A commit read for another mailbox, or after removal began, changes nothing.
  func commitMailbox(
    address: String, expectedRevision: Int, document: String, generation: String
  ) throws
    -> [String: Any]
  {
    guard let mailCache else { throw RegistrationError.unavailable }
    guard mailboxVerified else { throw RegistrationError.unavailable }
    let mailbox = try connectedMailbox().1
    guard mailbox.address == address, mailboxGeneration.uuidString == generation else {
      throw PrivateInboxError.mailboxInvalidated
    }
    var result = try mailCache.commitMailbox(
      address: address, subject: mailbox.subject, expectedRevision: expectedRevision,
      document: document)
    result["generation"] = generation
    return result
  }
}
