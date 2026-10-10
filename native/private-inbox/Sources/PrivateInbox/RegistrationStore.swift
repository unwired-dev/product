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
  // What this device had last read of the synchronized descriptor when it authorized the
  // connection: `observed` with `observedEpoch`, nil when there was no descriptor (empty for one
  // without an epoch). Only a later live descriptor at that known epoch proves no removal since;
  // absence supplies no incarnation to adopt after relaunch.
  var observed: Bool?
  var observedEpoch: String?

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

// Convex's reply to productAccount:connect. A device the account has not admitted connects as a
// Pending Device.
struct ConnectReply: Decodable {
  let productAccountId: String
  let trustedDeviceId: String?
  let trustedDeviceCredential: String?
  let pendingDeviceId: String?
  let pendingDeviceCredential: String?
  let signInProviders: [SignInProvider]?
  let productSyncMaterialInitialized: Bool?
}

extension ProductRegistrationReceipt {
  // What a connect presents: a reconnect sends its existing credential and never creates or
  // reaches another Product Account.
  static func connectArguments(
    deviceIdentifier: String, platform: String, previous: ProductRegistrationReceipt?
  ) -> [String: Any] {
    var args: [String: Any] = [
      "deviceIdentifier": deviceIdentifier, "platform": platform,
      "supportsDeviceCredentials": true,
    ]
    if let previous {
      args[previous.pending == true ? "pendingDeviceCredential" : "trustedDeviceCredential"] =
        previous.trustedDeviceCredential
      args["expectedProductAccountId"] = previous.productAccountId
    }
    return args
  }

  // The receipt the reply issues: only for a Product Account, a device and a well-formed credential.
  init(connected reply: ConnectReply) throws {
    guard
      let deviceId = reply.trustedDeviceId ?? reply.pendingDeviceId,
      let credential = reply.trustedDeviceCredential ?? reply.pendingDeviceCredential,
      !reply.productAccountId.isEmpty, !deviceId.isEmpty,
      credential.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    else { throw RegistrationError.unavailable }
    self.init(
      productAccountId: reply.productAccountId, trustedDeviceId: deviceId,
      trustedDeviceCredential: credential, pending: reply.pendingDeviceId != nil ? true : nil,
      signInProviders: reply.signInProviders,
      productSyncMaterialInitialized: reply.productSyncMaterialInitialized)
  }
}

@MainActor protocol GoogleRegistrationProvider {
  func signIn(mail: Bool, hint: String?) async throws -> GoogleRegistrationIdentity
  func refresh(_ credential: Data) async throws -> GoogleRegistrationIdentity
  func verifyGmail(_ identity: GoogleRegistrationIdentity) async throws -> GmailRegistrationReceipt
  // One Gmail API request with this identity's access token: a read, or a POST of a body of
  // `contentType`. HTTP failures are returned, not thrown.
  func gmail(
    _ identity: GoogleRegistrationIdentity, url: URL, body: Data?, contentType: String
  ) async throws -> (Int, Data)
}

extension GoogleRegistrationProvider {
  // A read, or a JSON POST with a body.
  func gmail(_ identity: GoogleRegistrationIdentity, url: URL, body: Data?) async throws -> (
    Int, Data
  ) {
    try await gmail(identity, url: url, body: body, contentType: "application/json")
  }
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

// One Convex request: a query or mutation by function path, or an HTTP action by route.
struct BackendRequest {
  enum Endpoint: String { case query, mutation, action }
  let endpoint: Endpoint
  let path: String
  var args: [String: Any]
  // The Product Sign-In whose token authenticates it, when the call needs one.
  var identity: ProductSignInIdentity?
  // The receipt whose device proof `args` carries, when the call needs one.
  var product: ProductRegistrationReceipt?
}

// Sends a request and returns its HTTP status and body.
typealias BackendTransport = @MainActor (BackendRequest) async throws -> (Int, Data)

// The minimal native vault behind TypeScript's registration flow: the saved registration in the
// Keychain, provider SDK sign-ins and credentialed backend calls. TypeScript decides the flow and
// reads a projection without credentials, tokens or provider subjects; every change goes through an
// operation named by its purpose.
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
  let productSync: ProductSyncBackend?
  // Whether the account revoked this device, answered for its credential without a Product Sign-In.
  let deviceRevoked: ((ProductRegistrationReceipt) async throws -> Bool)?
  // The generic credentialed call TypeScript names; absent where a host has no backend.
  let transport: BackendTransport?
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
  // The latest Product Sign-In in this process, verified or not; the next step presents it.
  var identity: ProductSignInIdentity?
  // The latest Gmail authorization, and its verified receipt, until a connection stores it.
  var mailboxAuthorization: (identity: GoogleRegistrationIdentity, receipt: GmailRegistrationReceipt?)?
  // Other devices' enrollment requests by Product Account, as last listed in this process.
  var enrollmentRequests: [String: [PendingEnrollment]] = [:]
  // The account's other Trusted Devices by Product Account, as last listed in this process.
  var trustedDevices: [String: [TrustedDevice]] = [:]

  init(
    keys: DeviceKeychain, deployment: String, clientID: String,
    provider: any GoogleRegistrationProvider, apple: (any AppleRegistrationProvider)? = nil,
    productSync: ProductSyncBackend? = nil,
    deviceRevoked: ((ProductRegistrationReceipt) async throws -> Bool)? = nil,
    transport: BackendTransport? = nil, mailCache: PrivateInboxStore? = nil,
    connect:
      @escaping (ProductSignInIdentity, String, ProductRegistrationReceipt?) async throws ->
      ProductRegistrationReceipt
  ) {
    self.keys = keys
    self.deployment = deployment
    self.clientID = clientID
    self.provider = provider
    self.apple = apple
    self.productSync = productSync
    self.deviceRevoked = deviceRevoked
    self.transport = transport
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

  func saved() throws -> SavedRegistration {
    guard let saved = try load() else { throw RegistrationError.unavailable }
    return saved
  }

  // What TypeScript reads of the saved registration: no credential, token or provider subject.
  func registration() throws -> [String: Any]? {
    guard let saved = try load() else { return nil }
    var result: [String: Any] = [
      "signInProvider": saved.provider.rawValue,
      "mailboxes": saved.connections.map { connection in
        var entry: [String: Any] = [
          "id": connection.id, "address": connection.receipt.address,
          "authorizationNeeded": connection.authorizationNeeded == true,
          "access": verifiedMailboxes.contains(connection.id)
            ? "verified" : cacheOnlyMailboxes.contains(connection.id) ? "cached" : "unverified",
        ]
        if let epoch = connection.epoch { entry["epoch"] = epoch }
        return entry
      },
      "mailboxRemovalPending": !(saved.mailboxRemovals ?? []).isEmpty
        || !(saved.mailboxCacheRemovals ?? []).isEmpty,
      "session": session != nil,
    ]
    if let email = saved.contactEmail { result["contactEmail"] = email }
    if let reason = saved.mailboxSetupReason { result["mailboxSetupReason"] = reason }
    if let removal = saved.accountRemoval {
      result["removal"] = [
        "operation": removal.operation.rawValue, "acknowledged": removal.acknowledged,
      ]
    }
    if let product = saved.product {
      var receipt: [String: Any] = [
        "productAccountId": product.productAccountId, "pending": product.pending == true,
      ]
      if let providers = product.signInProviders {
        receipt["signInProviders"] = providers.map(\.rawValue)
      }
      result["product"] = receipt
    }
    // Unreadable local Product Sync state never fails registration or the mailbox.
    do { result["privateSync"] = try privateSync(saved) } catch {
      Self.logProductSyncFailure("Product Sync state unreadable", error)
      result["privateSync"] = ["privateSync": "unavailable"]
    }
    return result
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

  // Whether an identity is the saved record's provider and account.
  func opens(_ saved: SavedRegistration?, _ identity: ProductSignInIdentity) -> Bool {
    saved.map { $0.provider == identity.provider && $0.subject == identity.subject } ?? false
  }

  // An interactive Product Sign-In; `hint` suggests the saved Google account.
  func signInIdentity(_ signInProvider: SignInProvider, hint: Bool) async throws -> [String: Any] {
    let saved = try load()
    let signedIn = try await productIdentity(
      signInProvider, hint: hint && saved?.provider == .google ? saved?.subject : nil)
    identity = signedIn
    return ["matches": opens(saved, signedIn)]
  }

  // Renews the saved Google Product Sign-In without a prompt.
  func renewIdentity() async throws -> [String: Any] {
    let saved = try saved()
    guard saved.provider == .google else { throw RegistrationError.unavailable }
    let google = try await provider.refresh(saved.identityCredential)
    let renewed = ProductSignInIdentity(
      provider: .google, subject: google.subject, idToken: google.idToken,
      credential: google.credential, contactEmail: nil)
    identity = renewed
    return ["matches": opens(saved, renewed)]
  }

  // Native Sign in with Apple cannot renew an identity token silently; its grant is checked instead.
  func appleCredentialState() async throws -> String {
    let saved = try saved()
    switch try await appleProvider().credentialState(saved.subject) {
    case .authorized: return "authorized"
    case .revoked: return "revoked"
    case .unavailable: return "unavailable"
    }
  }

  func reuseSession() throws {
    guard let session else { throw RegistrationError.unavailable }
    identity = session
  }

  // Persists the latest sign-in before any backend request, so an interruption keeps it. Only a
  // sign-in that never received a Product Account may be replaced by another identity.
  func saveIdentity(replacing: Bool) throws {
    guard let identity else { throw RegistrationError.unavailable }
    let existing = try load()
    if replacing, existing?.product != nil { throw RegistrationError.invalidIdentity }
    if !replacing, let existing, !opens(existing, identity) {
      throw RegistrationError.invalidIdentity
    }
    var next =
      (replacing ? nil : existing)
      ?? SavedRegistration(
        deployment: deployment, clientID: clientID, deviceIdentifier: UUID().uuidString,
        signInProvider: identity.provider, subject: identity.subject,
        identityCredential: identity.credential)
    next.identityCredential = identity.credential
    // Apple returns the address only on first authorization; keep the earlier one.
    if let email = identity.contactEmail { next.contactEmail = email }
    try save(next)
  }

  enum ConnectMode: String {
    // The saved identity reconnects.
    case establish
    // A Linked Sign-In of the same Product Account becomes this device's sign-in.
    case `switch`
    // Any sign-in of the account renews this device's proof; the record keeps its own sign-in.
    case renew
  }

  // Connects the latest sign-in and stores the issued device credential before returning. A
  // reconnect never creates or reaches another Product Account.
  func connectIdentity(_ mode: ConnectMode) async throws {
    guard let identity else { throw RegistrationError.unavailable }
    var saved = try saved()
    let previous = saved.product
    switch mode {
    case .establish:
      guard opens(saved, identity) else { throw RegistrationError.invalidIdentity }
    case .switch, .renew:
      guard previous != nil else { throw RegistrationError.unavailable }
    }
    let product = try await connect(identity, saved.deviceIdentifier, previous)
    if let previous, product.productAccountId != previous.productAccountId {
      throw RegistrationError.invalidIdentity
    }
    if mode == .switch {
      saved.signInProvider = identity.provider
      saved.subject = identity.subject
      saved.identityCredential = identity.credential
      if let email = identity.contactEmail { saved.contactEmail = email }
    }
    saved.product = product
    try save(saved)
    if mode != .renew { session = identity }
  }

  // Temporary until #757 moves Product Sync to TypeScript.
  func synchronizeRegistration() async throws {
    defer { newlyAuthorizedMailboxes = [] }
    _ = try await synchronize(saved())
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

  func retryMailboxCleanup() async throws {
    _ = try await retryMailboxCleanup(saved())
  }

  // Renews a connection's Gmail authorization without a prompt; it must stay the same account.
  func refreshMailbox(_ id: String) async throws -> [String: Any] {
    guard let connection = try saved().connection(id) else { throw RegistrationError.unavailable }
    let gmail = try await provider.refresh(connection.credential)
    guard gmail.subject == connection.receipt.subject else {
      throw RegistrationError.invalidIdentity
    }
    mailboxAuthorization = (gmail, nil)
    return ["scopes": gmail.scopes.sorted()]
  }

  // An interactive Gmail authorization. A named connection suggests its own account; otherwise
  // `suggest` offers the Google sign-in. An Apple identity is never a Google account hint.
  func signInMailbox(_ id: String?, suggest: Bool) async throws -> [String: Any] {
    let saved = try saved()
    let hint =
      id.flatMap(saved.connection)?.receipt.subject
      ?? (suggest && saved.provider == .google ? saved.subject : nil)
    let gmail = try await provider.signIn(mail: true, hint: hint)
    mailboxAuthorization = (gmail, nil)
    return ["scopes": gmail.scopes.sorted()]
  }

  // Reads the authorized mailbox's address; it names the same Google account.
  func verifyGmail() async throws -> [String: Any] {
    guard let gmail = mailboxAuthorization?.identity else { throw RegistrationError.unavailable }
    let receipt = try await provider.verifyGmail(gmail)
    guard receipt.subject == gmail.subject, !receipt.address.isEmpty else {
      throw RegistrationError.invalidIdentity
    }
    mailboxAuthorization = (gmail, receipt)
    return ["connection": MailboxConnection.id(subject: receipt.subject), "address": receipt.address]
  }

  // The verified authorization, consumed by the connection that stores it.
  func verifiedAuthorization() throws -> (GoogleRegistrationIdentity, GmailRegistrationReceipt) {
    guard let gmail = mailboxAuthorization?.identity, let receipt = mailboxAuthorization?.receipt
    else { throw RegistrationError.unavailable }
    mailboxAuthorization = nil
    return (gmail, receipt)
  }

  // Saves a renewed authorization to the connection it verified for.
  func confirmMailbox(_ id: String) throws {
    let (gmail, receipt) = try verifiedAuthorization()
    var saved = try saved()
    guard MailboxConnection.id(subject: receipt.subject) == id, saved.connection(id) != nil else {
      throw RegistrationError.unavailable
    }
    saved.update(id) {
      $0.credential = gmail.credential
      $0.receipt = receipt
      $0.authorizationNeeded = nil
    }
    saved.mailboxSetupReason = nil
    try save(saved)
    verifiedMailboxes.insert(id)
    cacheOnlyMailboxes.remove(id)
  }

  // Adds the verified authorization as a connection, or repairs the existing one for its account.
  func storeMailbox() throws {
    let (gmail, receipt) = try verifiedAuthorization()
    var next = try saved()
    // Gmail authorization follows admission; a Pending Device holds no mailbox.
    guard let product = next.product, product.pending != true else {
      throw RegistrationError.unavailable
    }
    let id = MailboxConnection.id(subject: receipt.subject)
    // Never reuse a directory whose previous removal has not finished.
    guard !(next.mailboxCacheRemovals ?? []).contains(id) else {
      throw RegistrationError.unavailable
    }
    // The descriptors this device last read; absent before it ever read them.
    let vault = try? loadVault(product.productAccountId)
    let observedEpoch = try? vault.flatMap {
      try $0.descriptorEpochs?[$0.ring.identifier("mailbox", "gmail:" + receipt.subject)]
    }
    if next.connection(id) == nil {
      next.connections += [
        MailboxConnection(
          credential: gmail.credential, receipt: receipt,
          epoch: UUID().uuidString, observed: vault?.descriptorEpochs == nil ? nil : true,
          observedEpoch: observedEpoch)
      ]
    } else {
      next.update(id) {
        $0.credential = gmail.credential
        $0.receipt = receipt
        $0.authorizationNeeded = nil
      }
    }
    // Keep any unanswered removal until its old epoch is fenced in Product Sync.
    next.mailboxSetupReason = nil
    try save(next)
    mailboxGenerations[id] = UUID()
    verifiedMailboxes.insert(id)
    cacheOnlyMailboxes.remove(id)
    newlyAuthorizedMailboxes.insert(id)
  }

  // A connection that did not verify: open from its cache only, waiting for Gmail authorization
  // again, or unverified while it already waits.
  func markMailbox(_ id: String, access: String) throws {
    verifiedMailboxes.remove(id)
    switch access {
    case "cached": cacheOnlyMailboxes.insert(id)
    case "unverified": break
    case "authorization":
      cacheOnlyMailboxes.remove(id)
      var saved = try saved()
      saved.update(id) { $0.authorizationNeeded = true }
      try save(saved)
    default: throw RegistrationError.unavailable
    }
  }

  // Why the latest mailbox authorization ended without a usable mailbox.
  func recordMailboxSetup(_ reason: String) throws {
    guard
      ["cancelled", "declined", "gmail-unavailable", "interrupted", "unavailable"].contains(reason)
    else { throw RegistrationError.unavailable }
    var saved = try saved()
    saved.mailboxSetupReason = reason
    try save(saved)
  }

  // The Sign-In Providers that open the Product Account, as the backend reported them.
  func saveSignInProviders(_ providers: [SignInProvider]) throws {
    var saved = try saved()
    guard var product = saved.product else { throw RegistrationError.unavailable }
    product.signInProviders = providers
    saved.product = product
    try save(saved)
  }

  // Removes a connection from this Product Account: its credential and cached mail leave this
  // device, its synchronized descriptor is marked removed, and its Gmail mail is untouched.
  func removeMailbox(_ id: String) async throws {
    var saved = try saved()
    guard saved.product?.pending != true, let connection = saved.connection(id) else {
      throw RegistrationError.unavailable
    }
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
    _ = try await synchronize(retryMailboxCleanup(saved))
  }

  // Confirms the retained Product Sign-In without an interactive session.
  // A removed device purges before any provider renewal or prompt, which may fail or be cancelled.
  // Offline, the check is skipped and the saved account stays usable.
  func requireNotRevoked(_ product: ProductRegistrationReceipt) async throws {
    if (try? await deviceRevoked?(product)) == true { throw RegistrationError.revoked }
  }

  // A revoked device keeps nothing of the Product Account: keys, requests and credentials go.
  // Every item is attempted; the registration record goes last, so a failed purge is retried.
  func purge(notice: String? = nil) async throws {
    forgetMailboxAccess()
    session = nil
    identity = nil
    mailboxAuthorization = nil
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
  }

  // A Trusted Device's proof, or a Pending Device's for its own admission and removal.
  static func proof(_ product: ProductRegistrationReceipt) -> [String: Any] {
    product.pending == true
      ? [
        "pendingDeviceId": product.trustedDeviceId,
        "pendingDeviceCredential": product.trustedDeviceCredential,
      ]
      : [
        "trustedDeviceId": product.trustedDeviceId,
        "trustedDeviceCredential": product.trustedDeviceCredential,
      ]
  }

  // TypeScript names a Convex call; this device attaches the credentials it asks for and returns
  // the reply. Connecting issues a credential, so it is only available as its own operation.
  func call(_ request: [String: Any]) async throws -> [String: Any] {
    guard let transport,
      let endpoint = (request["endpoint"] as? String).flatMap(BackendRequest.Endpoint.init),
      let path = request["path"] as? String, path != "productAccount:connect",
      (endpoint == .action) == path.hasPrefix("/"),
      var args = request["args"] as? [String: Any]
    else { throw RegistrationError.unavailable }
    let saved = try load()
    var backend = BackendRequest(endpoint: endpoint, path: path, args: [:])
    if request["identity"] as? Bool == true {
      guard let identity else { throw RegistrationError.unavailable }
      backend.identity = identity
    }
    if request["device"] as? Bool == true {
      guard let product = saved?.product else { throw RegistrationError.unavailable }
      args.merge(Self.proof(product)) { $1 }
      backend.product = product
    }
    if request["installation"] as? Bool == true {
      guard let saved else { throw RegistrationError.unavailable }
      args["deviceIdentifier"] = saved.deviceIdentifier
    }
    // Convex exchanges and revokes it with the client that issued it.
    if request["appleAuthorization"] as? Bool == true, let code = identity?.authorizationCode {
      args["authorizationCode"] = code
    }
    backend.args = args
    let (status, data) = try await transport(backend)
    return ["status": status, "body": String(decoding: data, as: UTF8.self)]
  }
}
