import CryptoKit
import Foundation

enum RegistrationError: Error {
  case cancelled, declined, gmailUnavailable, invalidIdentity, unavailable
  // Linking: the identity belongs to another Product Account, or a sign-in is no longer recent.
  case identityOwned, staleAuthentication
  // The entry does not match the end of the Recovery Key shown for setup.
  case recoveryKeyMismatch
  // Enrollment: a mistyped approval code, or a request that can no longer be approved.
  case enrollmentCodeInvalid, enrollmentUnavailable
  // Another Trusted Device removed this one; its identifier stays refused.
  case revoked
  // This Pending Device's record ended, for example with its Enrollment Code; signing in renews it.
  case pendingDeviceUnavailable
  // The Product Account was deleted, from this device or another.
  case deleted
  // Convex refused a deletion before fencing anything: a malformed request or a device proof for
  // another account. Apple authorization is required because Sign in with Apple opens the account.
  case removalRefused, appleAuthorizationRequired

  // This device's access to the Product Account has ended; it keeps none of its data.
  var endsAccess: Bool { self == .revoked || self == .deleted }
}

enum SignInProvider: String, Codable {
  case google, apple
}

struct GoogleRegistrationIdentity {
  let subject: String
  let credential: Data
  let idToken: String
  let accessToken: String
  let scopes: Set<String>
}

struct AppleRegistrationIdentity {
  let subject: String
  let idToken: String
  // Possibly a private relay address; display and contact information only.
  let email: String?
  // Single-use proof Convex exchanges and revokes when the Product Account is deleted.
  var authorizationCode: String? = nil
}

enum AppleCredentialState {
  case authorized, revoked, unavailable
}

// The verified Product Sign-In presented to the backend.
struct ProductSignInIdentity {
  let provider: SignInProvider
  let subject: String
  let idToken: String
  let credential: Data
  let contactEmail: String?
  // Sign in with Apple only: lets Convex revoke this authorization when deleting the account.
  var authorizationCode: String? = nil
}

struct GmailRegistrationReceipt: Codable {
  let subject: String
  let address: String
}

// One authorized Gmail mailbox on this device. Each keeps its own credential, verification and
// cache; the Google account identifies it, so adding the same mailbox again repairs it.
struct MailboxConnection: Codable {
  var credential: Data
  var receipt: GmailRegistrationReceipt
  // Gmail refused this mailbox's grant; nothing reaches it until it is authorized again.
  var authorizationNeeded: Bool?
  // The synchronized descriptor's epoch this authorization belongs to. A new epoch means the
  // connection was removed and added again, so an authorization from before that is purged.
  var epoch: String?
  // This device has read its descriptor back at `epoch`.
  var published: Bool?

  // The opaque identifier JavaScript names this connection by.
  var id: String { Self.id(subject: receipt.subject) }
  static func id(subject: String) -> String {
    SHA256.hash(data: Data(("dev.unwired.mailbox-connection\n" + subject).utf8)).prefix(16)
      .map { String(format: "%02x", $0) }.joined()
  }
}

// A removed connection's descriptor still to be marked removed in Product Sync.
struct MailboxRemoval: Codable {
  let subject: String
  let address: String
  let epoch: String?
}

struct ProductRegistrationReceipt: Codable {
  let productAccountId: String
  // While `pending`, these identify this device's Pending Device record and its credential, which
  // carries over when a Trusted Device approves it or the Recovery Key unlocks it.
  let trustedDeviceId: String
  let trustedDeviceCredential: String
  // A Pending Device has no Product Account operations beyond its own admission and removal.
  var pending: Bool? = nil
  // Every Sign-In Provider that opens the Product Account; absent in records before linking.
  var signInProviders: [SignInProvider]? = nil
  // As reported by the latest connect; absent means unknown, which never permits creating keys
  // and reports setup as pending until the next connect.
  var productSyncMaterialInitialized: Bool? = nil
}

struct SignInLinkRequest {
  // Absent when the provider is already linked to this Product Account.
  let linkTicket: String?
  let signInProviders: [SignInProvider]
}

// Backend steps for an explicit link: the current account vouches, then the new identity redeems.
struct SignInLinking {
  let request:
    (ProductSignInIdentity, ProductRegistrationReceipt, SignInProvider) async throws ->
      SignInLinkRequest
  let complete:
    (ProductSignInIdentity, ProductRegistrationReceipt, String) async throws -> [SignInProvider]
}

@MainActor protocol GoogleRegistrationProvider {
  func signIn(mail: Bool, hint: String?) async throws -> GoogleRegistrationIdentity
  func refresh(_ credential: Data) async throws -> GoogleRegistrationIdentity
  func verifyGmail(_ identity: GoogleRegistrationIdentity) async throws -> GmailRegistrationReceipt
  // One Gmail API request with this identity's access token: a read, or a JSON POST with a body.
  // HTTP failures are returned, not thrown.
  func gmail(_ identity: GoogleRegistrationIdentity, url: URL, body: Data?) async throws -> (
    Int, Data
  )
}

@MainActor protocol AppleRegistrationProvider {
  func signIn() async throws -> AppleRegistrationIdentity
  func credentialState(_ subject: String) async -> AppleCredentialState
}

struct SavedRegistration: Codable {
  var version = 1
  let deployment: String
  let clientID: String
  let deviceIdentifier: String
  // Records written before Apple sign-in carry no provider and are Google.
  var signInProvider: SignInProvider?
  var subject: String
  // Apple has no native refresh credential, so its identity keeps empty data.
  var identityCredential: Data
  var contactEmail: String?
  var product: ProductRegistrationReceipt?
  // The single mailbox of records written before Mailbox Connections; read as one connection.
  var mailboxCredential: Data?
  var mailbox: GmailRegistrationReceipt?
  // Why the latest mailbox authorization ended without a usable mailbox.
  var mailboxSetupReason: String?
  var mailboxes: [MailboxConnection]?
  var mailboxRemovals: [MailboxRemoval]?
  // Cache cleanup survives interruption after the connection credential has been removed.
  var mailboxCacheRemovals: [String]?
  // The owner of the earlier root cache, retained until it is adopted or removed.
  var legacyMailboxConnection: String?
  // Stored before remote removal; acknowledgement precedes every local cleanup step.
  var accountRemoval: AccountRemovalState?

  var provider: SignInProvider { signInProvider ?? .google }

  // In the order they were added, which the unified Inbox keeps.
  var connections: [MailboxConnection] {
    get {
      if let mailboxes { return mailboxes }
      guard let mailbox, let mailboxCredential else { return [] }
      // A legacy setup reason beside a saved mailbox meant its grant needed renewing.
      return [
        MailboxConnection(
          credential: mailboxCredential, receipt: mailbox,
          authorizationNeeded: mailboxSetupReason == nil ? nil : true)
      ]
    }
    set {
      if mailboxes == nil, let mailbox {
        legacyMailboxConnection = MailboxConnection.id(subject: mailbox.subject)
      }
      mailboxes = newValue
      mailbox = nil
      mailboxCredential = nil
    }
  }

  var legacyCacheConnection: String? {
    legacyMailboxConnection ?? (mailboxes == nil ? mailbox.map { MailboxConnection.id(subject: $0.subject) } : nil)
  }

  func connection(_ id: String) -> MailboxConnection? { connections.first { $0.id == id } }
  mutating func update(_ id: String, _ change: (inout MailboxConnection) -> Void) {
    var all = connections
    guard let index = all.firstIndex(where: { $0.id == id }) else { return }
    change(&all[index])
    connections = all
  }
  var usableConnections: [MailboxConnection] {
    connections.filter { $0.authorizationNeeded != true }
  }
}

@MainActor final class RegistrationStore {
  static let gmailScope = "https://www.googleapis.com/auth/gmail.modify"
  let keys: DeviceKeychain
  let deployment: String
  let clientID: String
  let provider: any GoogleRegistrationProvider
  let apple: (any AppleRegistrationProvider)?
  // Receives the device's previous receipt, whose Product Account a reconnect must reach.
  let connect:
    (ProductSignInIdentity, String, ProductRegistrationReceipt?) async throws ->
      ProductRegistrationReceipt
  let linking: SignInLinking?
  let productSync: ProductSyncBackend?
  let removal: AccountRemoval?
  // Whether the account revoked this device, answered for its credential without a Product Sign-In.
  let deviceRevoked: ((ProductRegistrationReceipt) async throws -> Bool)?
  // Each connection's encrypted cache; account removal and connection removal clear it.
  let mailCache: PrivateInboxStore?
  // Per connection, invalidates suspended mailbox work without treating concurrent token renewal
  // as a change of mailbox. Clearing it invalidates every connection's work.
  var mailboxGenerations: [String: UUID] = [:]
  // Connections whose Gmail access verified in this process, and those open from cache only.
  var verifiedMailboxes: Set<String> = []
  var cacheOnlyMailboxes: Set<String> = []
  // Only the current explicit consent can recreate a tombstone it encounters for the first time.
  var newlyAuthorizedMailboxes: Set<String> = []
  // The latest verified Product Sign-In in this process; Apple tokens cannot be renewed silently.
  var session: ProductSignInIdentity?
  // Other devices' enrollment requests by Product Account, as last listed in this process.
  var enrollmentRequests: [String: [PendingEnrollment]] = [:]
  // The account's other Trusted Devices by Product Account, as last listed in this process.
  var trustedDevices: [String: [TrustedDevice]] = [:]

  init(
    keys: DeviceKeychain, deployment: String, clientID: String,
    provider: any GoogleRegistrationProvider, apple: (any AppleRegistrationProvider)? = nil,
    linking: SignInLinking? = nil, productSync: ProductSyncBackend? = nil,
    removal: AccountRemoval? = nil,
    deviceRevoked: ((ProductRegistrationReceipt) async throws -> Bool)? = nil,
    mailCache: PrivateInboxStore? = nil,
    connect:
      @escaping (ProductSignInIdentity, String, ProductRegistrationReceipt?) async throws ->
      ProductRegistrationReceipt
  ) {
    self.keys = keys
    self.deployment = deployment
    self.clientID = clientID
    self.provider = provider
    self.apple = apple
    self.linking = linking
    self.productSync = productSync
    self.removal = removal
    self.deviceRevoked = deviceRevoked
    self.mailCache = mailCache
    self.connect = connect
  }

  func load() throws -> SavedRegistration? {
    guard let data = try keys.read("registration") else { return nil }
    let saved = try JSONDecoder().decode(SavedRegistration.self, from: data)
    // A record from another deployment or client cannot be resumed here; start a new sign-in.
    guard saved.version == 1, saved.deployment == deployment, saved.clientID == clientID else {
      return nil
    }
    return saved
  }

  func save(_ saved: SavedRegistration) throws {
    try keys.save(JSONEncoder().encode(saved), account: "registration")
  }

  func account(_ saved: SavedRegistration, kind: String) throws -> [String: String] {
    guard let product = saved.product else { throw RegistrationError.unavailable }
    var result = [
      "kind": kind, "productAccountId": product.productAccountId,
      "signInProvider": saved.provider.rawValue,
    ]
    if let email = saved.contactEmail, !email.isEmpty { result["contactEmail"] = email }
    if let alternate = product.signInProviders?.first(where: { $0 != saved.provider }) {
      result["alternateSignIn"] = alternate.rawValue
    }
    // Unreadable local Product Sync state never fails registration or the mailbox.
    let sync: [String: String]
    do { sync = try privateSync(saved) } catch {
      Self.logProductSyncFailure("Product Sync state unreadable", error)
      sync = ["privateSync": "unavailable"]
    }
    result = result.merging(sync) { $1 }
    if !(saved.mailboxRemovals ?? []).isEmpty || !(saved.mailboxCacheRemovals ?? []).isEmpty {
      result["privateSyncPending"] = "mailbox"
    }
    return result
  }

  func pending(_ saved: SavedRegistration) throws -> [String: String] {
    // A device the account has not admitted shows only its enrollment gate.
    if saved.product?.pending == true { return try account(saved, kind: "device-pending") }
    var result = try account(saved, kind: "mailbox-needed")
    // Saved mailboxes that all need authorization again read as Gmail being unavailable.
    let reason =
      saved.mailboxSetupReason ?? (saved.connections.isEmpty ? nil : "gmail-unavailable")
    if let reason { result["reason"] = reason }
    if let mailboxes = try mailboxList(saved) { result["mailboxes"] = mailboxes }
    return result
  }

  // A connection's state on this device: verified, open from its cache only, or waiting for
  // Gmail authorization again.
  func mailboxState(_ connection: MailboxConnection) -> String {
    if connection.authorizationNeeded == true { return "authorization" }
    return cacheOnlyMailboxes.contains(connection.id) ? "cached" : "connected"
  }

  // JSON text listing this device's connections in the order they were added.
  func mailboxList(_ saved: SavedRegistration) throws -> String? {
    guard saved.product?.pending != true, !saved.connections.isEmpty else { return nil }
    let entries = saved.connections.map { connection in
      var entry = ["id": connection.id, "address": connection.receipt.address, "state": mailboxState(connection)]
      if let epoch = connection.epoch { entry["epoch"] = epoch }
      return entry
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(entries), as: UTF8.self)
  }

  func failure(_ saved: SavedRegistration, reason: String) throws -> [String: String] {
    var next = saved
    next.mailboxSetupReason = reason
    try save(next)
    return try pending(next)
  }

  func establish(_ saved: SavedRegistration, identity: ProductSignInIdentity) async throws
    -> SavedRegistration
  {
    guard identity.provider == saved.provider, identity.subject == saved.subject else {
      throw RegistrationError.invalidIdentity
    }
    var next = saved
    next.identityCredential = identity.credential
    // Apple returns the address only on first authorization; keep the earlier one.
    if let email = identity.contactEmail { next.contactEmail = email }
    // Persist successful identity authorization even if the backend request is interrupted.
    try save(next)
    let product = try await connect(identity, saved.deviceIdentifier, saved.product)
    if let previous = saved.product, product.productAccountId != previous.productAccountId {
      throw RegistrationError.invalidIdentity
    }
    next.product = product
    try save(next)
    session = identity
    return try await synchronize(next)
  }

  func appleProvider() throws -> any AppleRegistrationProvider {
    guard let apple else { throw RegistrationError.unavailable }
    return apple
  }

  func productIdentity(_ signInProvider: SignInProvider, hint: String?) async throws
    -> ProductSignInIdentity
  {
    switch signInProvider {
    case .google:
      let identity = try await provider.signIn(mail: false, hint: hint)
      return ProductSignInIdentity(
        provider: .google, subject: identity.subject, idToken: identity.idToken,
        credential: identity.credential, contactEmail: nil)
    case .apple:
      let identity = try await appleProvider().signIn()
      return ProductSignInIdentity(
        provider: .apple, subject: identity.subject, idToken: identity.idToken,
        credential: Data(), contactEmail: identity.email,
        authorizationCode: identity.authorizationCode)
    }
  }

  func signIn(with signInProvider: SignInProvider = .google) async throws -> [String: String] {
    var saved = try load()
    // Explicit linking is required before another provider can reach a committed Product Account.
    // The backend decides: the cached provider list may predate a link made on another device.
    if let current = saved, current.product != nil, current.provider != signInProvider {
      // Switching sign-ins keeps the mailbox; recheck it rather than restarting Gmail consent.
      return try await mailboxStatus(switchSignIn(current, to: signInProvider))
    }
    let identity = try await productIdentity(
      signInProvider, hint: saved?.provider == .google ? saved?.subject : nil)
    // Only a sign-in that never received a Product Account may be replaced by another identity.
    if let current = saved, current.product == nil,
      current.provider != identity.provider || current.subject != identity.subject
    {
      saved = nil
    }
    let record =
      saved
      ?? SavedRegistration(
        deployment: deployment, clientID: clientID, deviceIdentifier: UUID().uuidString,
        signInProvider: signInProvider, subject: identity.subject,
        identityCredential: identity.credential)
    // Signing in again keeps a saved mailbox; recheck it rather than restarting Gmail consent.
    return try await mailboxStatus(establish(record, identity: identity))
  }

  // Moves this device to a Linked Sign-In once the backend confirms it opens the same account.
  func switchSignIn(_ saved: SavedRegistration, to signInProvider: SignInProvider) async throws
    -> SavedRegistration
  {
    guard let previous = saved.product else { throw RegistrationError.unavailable }
    // The linked identity is chosen explicitly; no mailbox or contact address hints it.
    let identity = try await productIdentity(signInProvider, hint: nil)
    let product = try await connect(identity, saved.deviceIdentifier, previous)
    guard product.productAccountId == previous.productAccountId else {
      throw RegistrationError.invalidIdentity
    }
    var next = saved
    next.signInProvider = signInProvider
    next.subject = identity.subject
    next.identityCredential = identity.credential
    if let email = identity.contactEmail { next.contactEmail = email }
    next.product = product
    try save(next)
    session = identity
    return try await synchronize(next)
  }

  // Verifies the current Product Account and then the identity being linked, both interactively.
  func link(_ other: SignInProvider) async throws -> [String: String] {
    guard let linking, var saved = try load(), var product = saved.product else {
      throw RegistrationError.unavailable
    }
    guard other != saved.provider else { throw RegistrationError.invalidIdentity }
    let current = try await productIdentity(
      saved.provider, hint: saved.provider == .google ? saved.subject : nil)
    guard current.provider == saved.provider, current.subject == saved.subject else {
      throw RegistrationError.invalidIdentity
    }
    let request = try await linking.request(current, product, other)
    var providers = request.signInProviders
    if let ticket = request.linkTicket {
      // Nothing is stored until the backend commits the link; an interruption changes nothing.
      let identity = try await productIdentity(other, hint: nil)
      providers = try await linking.complete(identity, product, ticket)
    }
    product.signInProviders = providers
    saved.product = product
    try save(saved)
    return try status(saved)
  }

  // Confirms the retained Product Sign-In without an interactive session.
  // A removed device purges before any provider renewal or prompt, which may fail or be cancelled.
  // Offline, the check is skipped and the saved account stays usable.
  func requireNotRevoked(_ product: ProductRegistrationReceipt) async throws {
    if (try? await deviceRevoked?(product)) == true { throw RegistrationError.revoked }
  }

  func reconfirm(_ saved: SavedRegistration) async throws -> SavedRegistration {
    switch saved.provider {
    case .google:
      let identity = try await provider.refresh(saved.identityCredential)
      return try await establish(
        saved,
        identity: ProductSignInIdentity(
          provider: .google, subject: identity.subject, idToken: identity.idToken,
          credential: identity.credential, contactEmail: nil))
    case .apple:
      // Native Sign in with Apple cannot renew an identity token silently; check the grant instead.
      guard saved.product != nil,
        try await appleProvider().credentialState(saved.subject) == .authorized
      else { throw RegistrationError.unavailable }
      return saved
    }
  }

  func restore() async throws -> [String: String] {
    forgetMailboxAccess()
    guard let retained = try load() else { return ["kind": "signed-out"] }
    if let removal = try await removalStatus(retained) { return removal }
    let saved = try await retryMailboxCleanup(retained)
    // Apple Product Sign-In finishes interactively; an uncommitted one starts again.
    if saved.provider == .apple, saved.product == nil { return ["kind": "signed-out"] }
    var next: SavedRegistration
    do {
      next = try await reconfirm(saved)
    } catch let error as RegistrationError where error.endsAccess {
      throw error
    } catch {
      // Keep any identity credential that establish persisted before the backend failed.
      if Self.transientMailboxFailure(error), let cached = try cachedMailbox((try? load()) ?? saved)
      {
        return cached
      }
      if saved.product != nil { return try failure((try? load()) ?? saved, reason: "unavailable") }
      throw error
    }
    return try await mailboxStatus(next)
  }

  // Forgets which connections verified, invalidating all suspended mailbox work.
  func forgetMailboxAccess() {
    mailboxGenerations = [:]
    verifiedMailboxes = []
    cacheOnlyMailboxes = []
  }

  func mailboxGeneration(_ id: String) -> UUID {
    if let generation = mailboxGenerations[id] { return generation }
    let generation = UUID()
    mailboxGenerations[id] = generation
    return generation
  }

  // Reports each retained connection as connected only after its Gmail access verifies again,
  // including one Gmail refused before. One connection's failure never changes another's state.
  func mailboxStatus(_ saved: SavedRegistration) async throws -> [String: String] {
    guard saved.product?.pending != true, !saved.connections.isEmpty else {
      return try pending(saved)
    }
    var next = saved
    for connection in saved.connections {
      let id = connection.id
      do {
        let gmail = try await provider.refresh(connection.credential)
        guard gmail.subject == connection.receipt.subject else {
          throw RegistrationError.invalidIdentity
        }
        let receipt = try await checkedGmail(gmail)
        next.update(id) {
          $0.credential = gmail.credential
          $0.receipt = receipt
          $0.authorizationNeeded = nil
        }
        next.mailboxSetupReason = nil
        verifiedMailboxes.insert(id)
        cacheOnlyMailboxes.remove(id)
      } catch let error as RegistrationError where error.endsAccess {
        throw error
      } catch {
        // Cached consent is never proof of currently usable Gmail access; a refused grant never
        // opens its saved mail.
        verifiedMailboxes.remove(id)
        if Self.transientMailboxFailure(error), connection.authorizationNeeded != true {
          cacheOnlyMailboxes.insert(id)
        } else if !Self.transientMailboxFailure(error) {
          cacheOnlyMailboxes.remove(id)
          next.update(id) { $0.authorizationNeeded = true }
        }
      }
    }
    try save(next)
    let verified = next.usableConnections.contains { verifiedMailboxes.contains($0.id) }
    return try status(verified ? await synchronize(next) : next)
  }

  func checkedGmail(_ identity: GoogleRegistrationIdentity) async throws -> GmailRegistrationReceipt
  {
    guard
      identity.scopes.contains(Self.gmailScope)
        || identity.scopes.contains("https://mail.google.com/")
    else {
      throw RegistrationError.declined
    }
    let receipt = try await provider.verifyGmail(identity)
    guard receipt.subject == identity.subject, !receipt.address.isEmpty else {
      throw RegistrationError.invalidIdentity
    }
    return receipt
  }

  // Authorizes Gmail for the named connection again, or adds a mailbox when none is named. Adding
  // a mailbox that is already connected repairs that connection instead of duplicating it. The
  // first mailbox suggests the Google sign-in unless the person chooses another account.
  func authorizeGmail(connection id: String? = nil, chooseAccount: Bool = false) async throws
    -> [String: String]
  {
    // Gmail authorization follows admission; a Pending Device holds no mailbox.
    guard let saved = try load(), let product = saved.product, product.pending != true else {
      throw RegistrationError.unavailable
    }
    let existing = id.flatMap(saved.connection)
    // A connection removed meanwhile is not added back by reauthorizing it.
    if id != nil, existing == nil { throw RegistrationError.unavailable }
    // A failure leaves other usable mailboxes as they are; the host reports it.
    let keepsMailboxes = saved.usableConnections.contains { $0.id != id }
    // Confirm the retained Product Sign-In independently of the mailbox selection.
    var next: SavedRegistration
    do {
      next = try await reconfirm(saved)
    } catch let error as RegistrationError where error.endsAccess {
      throw error
    } catch {
      // Keep any identity credential that establish persisted before the backend failed.
      return try failure(
        (try? load()) ?? saved, reason: saved.provider == .apple ? "unavailable" : "interrupted")
    }
    // An Apple identity or its relay address is never a Google account hint. Another mailbox is
    // chosen without one.
    let suggested = !chooseAccount && saved.connections.isEmpty && saved.provider == .google
    let hint = existing?.receipt.subject ?? (suggested ? saved.subject : nil)
    do {
      let gmail = try await provider.signIn(mail: true, hint: hint)
      let receipt = try await checkedGmail(gmail)
      // Reauthorization repairs this connection; another Google account is added separately.
      if let existing, existing.receipt.subject != receipt.subject {
        throw RegistrationError.gmailUnavailable
      }
      next = try await retryMailboxCleanup(next)
      let id = MailboxConnection.id(subject: receipt.subject)
      // Never reuse a directory whose previous removal has not finished.
      guard !(next.mailboxCacheRemovals ?? []).contains(id) else {
        throw RegistrationError.unavailable
      }
      let connection = MailboxConnection(
        credential: gmail.credential, receipt: receipt,
        epoch: UUID().uuidString)
      if next.connection(connection.id) == nil {
        next.connections += [connection]
      } else {
        next.update(connection.id) {
          $0.credential = gmail.credential
          $0.receipt = receipt
          $0.authorizationNeeded = nil
        }
      }
      // Keep any unanswered removal until its old epoch is fenced in Product Sync.
      next.mailboxSetupReason = nil
      try save(next)
      mailboxGenerations[connection.id] = UUID()
      verifiedMailboxes.insert(connection.id)
      cacheOnlyMailboxes.remove(connection.id)
      newlyAuthorizedMailboxes.insert(connection.id)
      defer { newlyAuthorizedMailboxes.remove(connection.id) }
      return try await status(synchronize(next))
    } catch let error as RegistrationError where error.endsAccess {
      throw error
    } catch {
      if keepsMailboxes { throw error }
      switch error {
      case RegistrationError.cancelled: return try failure(next, reason: "cancelled")
      case RegistrationError.declined: return try failure(next, reason: "declined")
      case RegistrationError.gmailUnavailable:
        return try failure(next, reason: "gmail-unavailable")
      default: return try failure(next, reason: "interrupted")
      }
    }
  }

  // Removes a connection from this Product Account: its credential and cached mail leave this
  // device, its synchronized descriptor is marked removed, and its Gmail mail is untouched.
  func removeMailbox(_ id: String) async throws -> [String: String] {
    guard var saved = try load(), saved.product?.pending != true,
      let connection = saved.connection(id)
    else { throw RegistrationError.unavailable }
    saved.connections = saved.connections.filter { $0.id != id }
    saved.mailboxRemovals =
      (saved.mailboxRemovals ?? []).filter { $0.subject != connection.receipt.subject } + [
        MailboxRemoval(
          subject: connection.receipt.subject, address: connection.receipt.address,
          epoch: connection.epoch)
      ]
    saved.mailboxCacheRemovals = Array(Set((saved.mailboxCacheRemovals ?? []) + [id])).sorted()
    // Credentials leave the durable record before cleanup suspends; its locator stays retryable.
    try save(saved)
    saved = try await retryMailboxCleanup(saved)
    return try await status(synchronize(saved))
  }

  // A revoked device keeps nothing of the Product Account: keys, requests and credentials go.
  // Every item is attempted; the registration record goes last, so a failed purge is retried.
  func purge(notice: String? = nil) async throws -> [String: String] {
    forgetMailboxAccess()
    session = nil
    enrollmentRequests = [:]
    trustedDevices = [:]
    let saved = try load()
    let removalOperation: AccountRemovalState.Operation =
      notice == "deleted" ? .deletion : notice == "signed-out" ? .signOut : .revoked
    if var saved {
      saved.accountRemoval = AccountRemovalState(
        operation: removalOperation, acknowledged: true)
      try save(saved)
    }
    var failure: (any Error)?
    do { try await removeMailboxCaches() } catch { failure = error }
    if let account = saved?.product?.productAccountId {
      for item in [vaultAccount(account), enrollmentAccount(account)] {
        do { try keys.remove(item) } catch { failure = failure ?? error }
      }
    }
    if let failure { throw failure }
    try keys.remove("registration")
    if removalOperation == .signOut { return ["kind": "signed-out"] }
    return ["kind": "signed-out", "notice": notice ?? "revoked"]
  }

  // Every host operation runs through this, so whichever request learns of a revocation purges.
  // A saved account is checked first: an operation may open a provider prompt before any backend
  // request, and cancelling that prompt must not keep a removed device's keys and credentials.
  func purgingIfRevoked(
    _ operation: (RegistrationStore) async throws -> [String: String],
    removing: AccountRemovalState.Operation? = nil
  )
    async throws -> [String: String]
  {
    do {
      if let saved = try? load(), let removal = saved.accountRemoval,
        removal.acknowledged || removal.operation != removing,
        let status = try await removalStatus(saved)
      {
        return status
      }
      // An unreadable record skips the check; the operation reports that failure itself.
      if let product = (try? load())?.product { try await requireNotRevoked(product) }
      return try await operation(self)
    } catch RegistrationError.revoked {
      return try await purge()
    } catch RegistrationError.deleted {
      return try await purge(notice: "deleted")
    }
  }

  // Connected while any mailbox verified or saw no failure, saved-Inbox-only while every usable one
  // is open from its cache, and otherwise waiting for a mailbox.
  func status(_ saved: SavedRegistration) throws -> [String: String] {
    let states = saved.usableConnections.map(mailboxState)
    guard saved.product?.pending != true, !states.isEmpty else { return try pending(saved) }
    var result = try account(saved, kind: states.contains("connected") ? "connected" : "cached")
    if let mailboxes = try mailboxList(saved) { result["mailboxes"] = mailboxes }
    return result
  }
}
