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

extension RegistrationError {
  var code: String {
    switch self {
    case .cancelled: "cancelled"
    case .declined: "declined"
    case .gmailUnavailable: "gmail-unavailable"
    case .invalidIdentity: "invalid-identity"
    case .unavailable: "unavailable"
    case .identityOwned: "identity-owned"
    case .staleAuthentication: "stale-authentication"
    case .recoveryKeyMismatch: "recovery-key-mismatch"
    case .enrollmentCodeInvalid: "enrollment-code-invalid"
    case .enrollmentUnavailable: "enrollment-unavailable"
    case .revoked: "revoked"
    case .pendingDeviceUnavailable: "unavailable"
    case .deleted: "deleted"
    case .removalRefused, .appleAuthorizationRequired: "removal-refused"
    }
  }
}

extension RegistrationStore {
  // The fixed code a vault operation rejects with. A known transport failure is `offline`, which
  // lets the flow open the last verified saved Inbox; it reaches hosts as `unavailable`.
  static func rejectionCode(_ error: any Error) -> String {
    if let error = error as? RegistrationError { return error.code }
    if (error as? PrivateInboxError) == .locked { return "locked" }
    return transientMailboxFailure(error) ? "offline" : "unavailable"
  }
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

// The Mail Provider a Mailbox Connection reads, named as TypeScript and Product Sync name it.
enum MailProvider: String, Codable {
  case gmail
  case microsoftGraph = "microsoft-graph"
}

// A verified mailbox: its provider account and address. Receipts written before Microsoft mail
// carry no provider and are Gmail.
struct GmailRegistrationReceipt: Codable {
  let subject: String
  let address: String
  var provider: MailProvider? = nil

  var mailProvider: MailProvider { provider ?? .gmail }
  // The provider account, unique across providers; Product Sync names the descriptor by it.
  var account: String { mailProvider.rawValue + ":" + subject }
}

// One authorized mailbox on this device. Each keeps its own credential, verification and cache;
// its provider account identifies it, so adding the same mailbox again repairs it.
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
  // The opaque relay route of this connection's Gmail watch, and when Gmail ends that watch, in
  // milliseconds since 1970.
  var pushRoute: String?
  var pushExpiration: Double?
  var pushVerified: Bool?

  // The opaque identifier JavaScript names this connection by.
  var id: String { Self.id(receipt) }
  // A Gmail connection keeps the identifier of connections from before other providers.
  static func id(_ receipt: GmailRegistrationReceipt) -> String {
    id(subject: receipt.mailProvider == .gmail ? receipt.subject : receipt.account)
  }
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
  var provider: MailProvider? = nil

  var receipt: GmailRegistrationReceipt {
    GmailRegistrationReceipt(subject: subject, address: address, provider: provider)
  }
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

// A mailbox authorization from its provider, waiting for a connection to store it.
enum MailboxGrant {
  case google(GoogleRegistrationIdentity)
  case microsoft(MicrosoftMailIdentity)

  var credential: Data {
    switch self {
    case .google(let identity): identity.credential
    case .microsoft(let identity): identity.credential
    }
  }
  var scopes: Set<String> {
    switch self {
    case .google(let identity): identity.scopes
    case .microsoft(let identity): identity.scopes
    }
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
  var deviceIdentifier: String
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
  // The APNs registration the relay last accepted for this device.
  var pushDevice: PushDevice?
  // Relay routes of removed connections that could not be removed yet.
  var pushRouteRemovals: [String]?

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

// One Convex request: a query, mutation or action by function path, or an HTTP action by route.
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
  // Absent where the host has no Microsoft client configured.
  let microsoft: (any MicrosoftMailProvider)?
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
  // Token callbacks must not restart watches between the shared flow's removal steps.
  var pushRoutingPaused = false
  // A native callback purged custody; the shared flow still needs to present its removal notice.
  var pushRegistrationFailure: RegistrationError?
  var cacheOnlyMailboxes: Set<String> = []
  // Only the current explicit consent can recreate a tombstone it encounters for the first time.
  var newlyAuthorizedMailboxes: Set<String> = []
  // The latest verified Product Sign-In in this process; Apple tokens cannot be renewed silently.
  var session: ProductSignInIdentity?
  // The latest Product Sign-In in this process, verified or not; the next step presents it.
  var identity: ProductSignInIdentity?
  // The latest mailbox authorization, and its verified receipt, until a connection stores it.
  var mailboxAuthorization: (grant: MailboxGrant, receipt: GmailRegistrationReceipt?)?
  // Wake hints waiting for JavaScript; removing a route drops its own.
  var wakes = PushWakes.shared

  init(
    keys: DeviceKeychain, deployment: String, clientID: String,
    provider: any GoogleRegistrationProvider, apple: (any AppleRegistrationProvider)? = nil,
    microsoft: (any MicrosoftMailProvider)? = nil,
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
    self.microsoft = microsoft
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
    if let pushRegistrationFailure { throw pushRegistrationFailure }
    guard let saved = try load() else { return nil }
    var result: [String: Any] = [
      "signInProvider": saved.provider.rawValue,
      "mailboxes": saved.connections.map { connection in
        var entry: [String: Any] = [
          "id": connection.id, "provider": connection.receipt.mailProvider.rawValue,
          "address": connection.receipt.address,
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
    do {
      if let state = try productSyncState(saved) { result["productSync"] = state }
    } catch {
      Self.logProductSyncFailure("Product Sync state unreadable", error)
      result["productSync"] = "unreadable"
    }
    return result
  }

  func appleProvider() throws -> any AppleRegistrationProvider {
    guard let apple else { throw RegistrationError.unavailable }
    return apple
  }

  func microsoftProvider() throws -> any MicrosoftMailProvider {
    guard let microsoft else { throw RegistrationError.unavailable }
    return microsoft
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

  // Renews a connection's authorization without a prompt. A Google one must stay the same
  // account; a Microsoft refresh token belongs to its account, which verification reads again.
  func refreshMailbox(_ id: String) async throws -> [String: Any] {
    guard let connection = try saved().connection(id) else { throw RegistrationError.unavailable }
    let grant: MailboxGrant
    switch connection.receipt.mailProvider {
    case .gmail:
      let gmail = try await provider.refresh(connection.credential)
      guard gmail.subject == connection.receipt.subject else {
        throw RegistrationError.invalidIdentity
      }
      grant = .google(gmail)
    case .microsoftGraph:
      grant = .microsoft(try await microsoftProvider().refresh(connection.credential))
    }
    mailboxAuthorization = (grant, nil)
    return ["scopes": grant.scopes.sorted()]
  }

  // An interactive authorization with the mailbox's provider. A named connection suggests its
  // own account and keeps its provider; otherwise `suggest` offers the Google sign-in to Gmail.
  // An Apple identity is never a Google account hint.
  func signInMailbox(_ id: String?, suggest: Bool, provider added: MailProvider = .gmail)
    async throws -> [String: Any]
  {
    let saved = try saved()
    let existing = id.flatMap(saved.connection)?.receipt
    let grant: MailboxGrant
    switch existing?.mailProvider ?? added {
    case .gmail:
      let hint = existing?.subject ?? (suggest && saved.provider == .google ? saved.subject : nil)
      grant = .google(try await provider.signIn(mail: true, hint: hint))
    case .microsoftGraph:
      grant = .microsoft(try await microsoftProvider().signIn(hint: existing?.address))
    }
    mailboxAuthorization = (grant, nil)
    return ["scopes": grant.scopes.sorted()]
  }

  // Reads the authorized mailbox's account and address from its provider.
  func verifyMailbox() async throws -> [String: Any] {
    guard let grant = mailboxAuthorization?.grant else { throw RegistrationError.unavailable }
    guard case .microsoft(let identity) = grant else { return try await verifyGmail() }
    let receipt = try await microsoftProvider().verify(identity)
    guard receipt.mailProvider == .microsoftGraph, !receipt.subject.isEmpty,
      !receipt.address.isEmpty
    else { throw RegistrationError.invalidIdentity }
    mailboxAuthorization = (grant, receipt)
    return ["connection": MailboxConnection.id(receipt), "address": receipt.address]
  }

  // Reads the authorized mailbox's address; it names the same Google account.
  func verifyGmail() async throws -> [String: Any] {
    guard case .google(let gmail)? = mailboxAuthorization?.grant else {
      throw RegistrationError.unavailable
    }
    let receipt = try await provider.verifyGmail(gmail)
    guard receipt.subject == gmail.subject, receipt.mailProvider == .gmail,
      !receipt.address.isEmpty
    else {
      throw RegistrationError.invalidIdentity
    }
    mailboxAuthorization = (.google(gmail), receipt)
    return ["connection": MailboxConnection.id(receipt), "address": receipt.address]
  }

  // The verified authorization, consumed by the connection that stores it.
  func verifiedAuthorization() throws -> (MailboxGrant, GmailRegistrationReceipt) {
    guard let grant = mailboxAuthorization?.grant, let receipt = mailboxAuthorization?.receipt
    else { throw RegistrationError.unavailable }
    mailboxAuthorization = nil
    return (grant, receipt)
  }

  // Saves a renewed authorization to the connection it verified for.
  func confirmMailbox(_ id: String) throws {
    let (grant, receipt) = try verifiedAuthorization()
    var saved = try saved()
    guard MailboxConnection.id(receipt) == id, saved.connection(id) != nil else {
      throw RegistrationError.unavailable
    }
    saved.update(id) {
      $0.credential = grant.credential
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
    let (grant, receipt) = try verifiedAuthorization()
    var next = try saved()
    // Mailbox authorization follows admission; a Pending Device holds no mailbox.
    guard let product = next.product, product.pending != true else {
      throw RegistrationError.unavailable
    }
    let id = MailboxConnection.id(receipt)
    // Never reuse a directory whose previous removal has not finished.
    guard !(next.mailboxCacheRemovals ?? []).contains(id) else {
      throw RegistrationError.unavailable
    }
    // The descriptors this device last read; absent before it ever read them.
    let vault = try? loadVault(product.productAccountId)
    let observedEpoch = try? vault.flatMap {
      try $0.descriptorEpochs?[$0.ring.identifier("mailbox", receipt.account)]
    }
    if next.connection(id) == nil {
      next.connections += [
        MailboxConnection(
          credential: grant.credential, receipt: receipt,
          epoch: UUID().uuidString, observed: vault?.descriptorEpochs == nil ? nil : true,
          observedEpoch: observedEpoch)
      ]
    } else {
      next.update(id) {
        $0.credential = grant.credential
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
      [
        "cancelled", "declined", "gmail-unavailable", "microsoft-unavailable", "interrupted",
        "unavailable",
      ].contains(reason)
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
    guard try saved().product?.pending != true else { throw RegistrationError.unavailable }
    // Stop with its credential, but keep relay deletion behind the synchronized tombstone.
    let routeRemoval = try await unroute(id, deferRemoval: productSync != nil)
    var saved = try saved()
    guard let connection = saved.connection(id) else { throw RegistrationError.unavailable }
    saved.connections = saved.connections.filter { $0.id != id }
    saved.mailboxRemovals =
      (saved.mailboxRemovals ?? []).filter { $0.receipt.account != connection.receipt.account } + [
        MailboxRemoval(
          subject: connection.receipt.subject, address: connection.receipt.address,
          epoch: connection.epoch, provider: connection.receipt.provider)
      ]
    saved.mailboxCacheRemovals = Array(Set((saved.mailboxCacheRemovals ?? []) + [id])).sorted()
    if let routeRemoval {
      saved.pushRouteRemovals = Array(Set((saved.pushRouteRemovals ?? []) + [routeRemoval])).sorted()
    }
    // Credentials leave the durable record before cleanup suspends; its locator stays retryable.
    // TypeScript then synchronizes the removal to Product Sync.
    try save(saved)
    _ = try await retryMailboxCleanup(saved)
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
    wakes.drop(nil)
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
      for item in [
        vaultAccount(account), enrollmentAccount(account), deviceKeyAccount(account),
        mailAssistanceAccount(account),
      ] {
        do { try keys.remove(item) } catch { failure = failure ?? error }
      }
    }
    if let failure { throw failure }
    try keys.remove("registration")
    pushRegistrationFailure = nil
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

  // Convex error codes the registration flow distinguishes; others are unavailable.
  static let backendErrors: [String: RegistrationError] = [
    "SIGN_IN_IDENTITY_OWNED": .identityOwned,
    "SIGN_IN_PROVIDER_ALREADY_LINKED": .identityOwned,
    "SIGN_IN_RECENT_AUTHENTICATION_REQUIRED": .staleAuthentication,
    "SIGN_IN_LINK_EXPIRED": .staleAuthentication,
    "SIGN_IN_NOT_LINKED": .invalidIdentity,
    "ENROLLMENT_REQUEST_UNAVAILABLE": .enrollmentUnavailable,
    "PENDING_DEVICE_UNAVAILABLE": .pendingDeviceUnavailable,
    "TRUSTED_DEVICE_REVOKED": .revoked,
    "PRODUCT_ACCOUNT_DELETED": .deleted,
  ]

  // A Convex mutation this vault makes itself, because its arguments carry a Recovery Key proof or
  // its reply issues a credential. It presents this process's verified Product Sign-In and this
  // device's proof. A successful null result is nil.
  func credentialedCall<Value: Decodable>(_ path: String, _ args: [String: Any]) async throws
    -> Value?
  {
    guard let transport, let session, let product = try saved().product else {
      throw RegistrationError.unavailable
    }
    let (status, data) = try await transport(
      BackendRequest(
        endpoint: .mutation, path: path, args: args.merging(Self.proof(product)) { $1 },
        identity: session, product: product))
    // Application errors carry a code in errorData whatever the HTTP status.
    guard let reply = try? JSONDecoder().decode(ConvexEnvelope<Value>.self, from: data) else {
      throw RegistrationError.unavailable
    }
    if reply.status == "success", status == 200 { return reply.value }
    throw reply.errorData.flatMap { Self.backendErrors[$0.code] } ?? RegistrationError.unavailable
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
    // This process's verified Product Sign-In, which Product Sync presents.
    if request["session"] as? Bool == true {
      guard let session else { throw RegistrationError.unavailable }
      backend.identity = session
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
