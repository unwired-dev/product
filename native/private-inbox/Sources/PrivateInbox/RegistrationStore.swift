import Foundation

enum RegistrationError: Error {
  case cancelled, declined, gmailUnavailable, invalidIdentity, unavailable
  // Linking: the identity belongs to another Product Account, or a sign-in is no longer recent.
  case identityOwned, staleAuthentication
  // The entry does not match the end of the Recovery Key shown for setup.
  case recoveryKeyMismatch
  // Enrollment: a mistyped approval code, or a request that can no longer be approved.
  case enrollmentCodeInvalid, enrollmentUnavailable
  // Another Trusted Device removed this one, or the account refuses new devices after a removal.
  case revoked
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
}

struct GmailRegistrationReceipt: Codable {
  let subject: String
  let address: String
}

struct ProductRegistrationReceipt: Codable {
  let productAccountId: String
  let trustedDeviceId: String
  let trustedDeviceCredential: String
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
  var mailboxCredential: Data?
  var mailbox: GmailRegistrationReceipt?
  var mailboxSetupReason: String?

  var provider: SignInProvider { signInProvider ?? .google }
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
  // Whether the account revoked this device, answered for its credential without a Product Sign-In.
  let deviceRevoked: ((ProductRegistrationReceipt) async throws -> Bool)?
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
    deviceRevoked: ((ProductRegistrationReceipt) async throws -> Bool)? = nil,
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
    self.deviceRevoked = deviceRevoked
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
    return result.merging(sync) { $1 }
  }

  func pending(_ saved: SavedRegistration) throws -> [String: String] {
    var result = try account(saved, kind: "mailbox-needed")
    if let reason = saved.mailboxSetupReason { result["reason"] = reason }
    return result
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
        credential: Data(), contactEmail: identity.email)
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
  func reconfirm(_ saved: SavedRegistration) async throws -> SavedRegistration {
    // A removed device must purge even if its provider grant can no longer be renewed.
    if let product = saved.product, (try? await deviceRevoked?(product)) == true {
      throw RegistrationError.revoked
    }
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
    guard let saved = try load() else { return ["kind": "signed-out"] }
    // Apple Product Sign-In finishes interactively; an uncommitted one starts again.
    if saved.provider == .apple, saved.product == nil { return ["kind": "signed-out"] }
    var next: SavedRegistration
    do {
      next = try await reconfirm(saved)
    } catch RegistrationError.revoked {
      throw RegistrationError.revoked
    } catch {
      // Keep any identity credential that establish persisted before the backend failed.
      if saved.product != nil { return try failure((try? load()) ?? saved, reason: "unavailable") }
      throw error
    }
    return try await mailboxStatus(next)
  }

  // Reports a retained mailbox as connected only after its Gmail access verifies again.
  func mailboxStatus(_ saved: SavedRegistration) async throws -> [String: String] {
    var next = saved
    guard let credential = next.mailboxCredential, let mailbox = next.mailbox else {
      return try pending(next)
    }
    do {
      let gmail = try await provider.refresh(credential)
      guard gmail.subject == mailbox.subject else { throw RegistrationError.invalidIdentity }
      let receipt = try await checkedGmail(gmail)
      next.mailboxCredential = gmail.credential
      next.mailbox = receipt
      next.mailboxSetupReason = nil
      try save(next)
      return try await connected(synchronize(next))
    } catch RegistrationError.revoked {
      throw RegistrationError.revoked
    } catch {
      // Cached consent is never proof of currently usable Gmail access.
      return try failure(next, reason: "gmail-unavailable")
    }
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

  func authorizeGmail(reselect: Bool) async throws -> [String: String] {
    guard let saved = try load(), saved.product != nil else { throw RegistrationError.unavailable }
    // Confirm the retained Product Sign-In independently of the mailbox selection.
    var next: SavedRegistration
    do {
      next = try await reconfirm(saved)
    } catch RegistrationError.revoked {
      throw RegistrationError.revoked
    } catch {
      // Keep any identity credential that establish persisted before the backend failed.
      return try failure(
        (try? load()) ?? saved, reason: saved.provider == .apple ? "unavailable" : "interrupted")
    }
    // An Apple identity or its relay address is never a Google account hint.
    let hint =
      reselect ? nil : saved.mailbox?.subject ?? (saved.provider == .google ? saved.subject : nil)
    do {
      let gmail = try await provider.signIn(mail: true, hint: hint)
      let receipt = try await checkedGmail(gmail)
      next.mailboxCredential = gmail.credential
      next.mailbox = receipt
      next.mailboxSetupReason = nil
      try save(next)
      return try await connected(synchronize(next))
    } catch RegistrationError.revoked {
      throw RegistrationError.revoked
    } catch {
      // A failed reselection keeps the connected mailbox; the host reports the rejection.
      if reselect, next.mailbox != nil, next.mailboxSetupReason == nil { throw error }
      switch error {
      case RegistrationError.cancelled: return try failure(next, reason: "cancelled")
      case RegistrationError.declined: return try failure(next, reason: "declined")
      case RegistrationError.gmailUnavailable:
        return try failure(next, reason: "gmail-unavailable")
      default: return try failure(next, reason: "interrupted")
      }
    }
  }

  // A revoked device keeps nothing of the Product Account: keys, requests and credentials go.
  // A device that never joined it, refused after another device's removal, was never trusted.
  func purge() throws -> [String: String] {
    let saved = try load()
    if let account = saved?.product?.productAccountId {
      try keys.remove(vaultAccount(account))
      try keys.remove(enrollmentAccount(account))
    }
    try keys.remove("registration")
    session = nil
    enrollmentRequests = [:]
    trustedDevices = [:]
    return ["kind": "signed-out", "notice": saved?.product == nil ? "refused" : "revoked"]
  }

  // Every host operation runs through this, so whichever request learns of a revocation purges.
  func purgingIfRevoked(_ operation: (RegistrationStore) async throws -> [String: String])
    async throws -> [String: String]
  {
    do { return try await operation(self) } catch RegistrationError.revoked { return try purge() }
  }

  func connected(_ saved: SavedRegistration) throws -> [String: String] {
    guard let mailbox = saved.mailbox else { throw RegistrationError.unavailable }
    var result = try account(saved, kind: "connected")
    result["providerSubject"] = mailbox.subject
    result["address"] = mailbox.address
    return result
  }
}
