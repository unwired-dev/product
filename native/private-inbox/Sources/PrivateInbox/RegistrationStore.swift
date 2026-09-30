import Foundation

enum RegistrationError: Error {
  case cancelled, declined, gmailUnavailable, invalidIdentity, unavailable
}

struct GoogleRegistrationIdentity {
  let subject: String
  let credential: Data
  let idToken: String
  let accessToken: String
  let scopes: Set<String>
}

struct GmailRegistrationReceipt: Codable {
  let subject: String
  let address: String
}

struct ProductRegistrationReceipt: Codable {
  let productAccountId: String
  let trustedDeviceId: String
  let trustedDeviceCredential: String
}

@MainActor protocol GoogleRegistrationProvider {
  func signIn(mail: Bool, hint: String?) async throws -> GoogleRegistrationIdentity
  func refresh(_ credential: Data) async throws -> GoogleRegistrationIdentity
  func verifyGmail(_ identity: GoogleRegistrationIdentity) async throws -> GmailRegistrationReceipt
}

struct SavedRegistration: Codable {
  var version = 1
  let deployment: String
  let clientID: String
  let deviceIdentifier: String
  let subject: String
  var identityCredential: Data
  var product: ProductRegistrationReceipt?
  var mailboxCredential: Data?
  var mailbox: GmailRegistrationReceipt?
  var mailboxSetupReason: String?
}

@MainActor final class RegistrationStore {
  static let gmailScope = "https://www.googleapis.com/auth/gmail.modify"
  let keys: DeviceKeychain
  let deployment: String
  let clientID: String
  let provider: any GoogleRegistrationProvider
  let connect:
    (GoogleRegistrationIdentity, String, String?) async throws -> ProductRegistrationReceipt

  init(
    keys: DeviceKeychain, deployment: String, clientID: String,
    provider: any GoogleRegistrationProvider,
    connect:
      @escaping (GoogleRegistrationIdentity, String, String?) async throws ->
      ProductRegistrationReceipt
  ) {
    self.keys = keys
    self.deployment = deployment
    self.clientID = clientID
    self.provider = provider
    self.connect = connect
  }

  func load() throws -> SavedRegistration? {
    guard let data = try keys.read("registration") else { return nil }
    let saved = try JSONDecoder().decode(SavedRegistration.self, from: data)
    guard saved.version == 1, saved.deployment == deployment, saved.clientID == clientID else {
      throw RegistrationError.unavailable
    }
    return saved
  }

  func save(_ saved: SavedRegistration) throws {
    try keys.save(JSONEncoder().encode(saved), account: "registration")
  }

  func pending(_ saved: SavedRegistration) throws -> [String: String] {
    guard let product = saved.product else { throw RegistrationError.unavailable }
    var result = ["kind": "mailbox-needed", "productAccountId": product.productAccountId]
    if let reason = saved.mailboxSetupReason { result["reason"] = reason }
    return result
  }

  func failure(_ saved: SavedRegistration, reason: String) throws -> [String: String] {
    var next = saved
    next.mailboxSetupReason = reason
    try save(next)
    return try pending(next)
  }

  func establish(_ saved: SavedRegistration, identity: GoogleRegistrationIdentity) async throws
    -> SavedRegistration
  {
    guard identity.subject == saved.subject else { throw RegistrationError.invalidIdentity }
    var next = saved
    next.identityCredential = identity.credential
    // Persist successful identity authorization even if the backend request is interrupted.
    try save(next)
    let product = try await connect(
      identity, saved.deviceIdentifier, saved.product?.trustedDeviceCredential)
    if let previous = saved.product, product.productAccountId != previous.productAccountId {
      throw RegistrationError.invalidIdentity
    }
    next.product = product
    try save(next)
    return next
  }

  func signIn() async throws -> [String: String] {
    if let saved = try load() {
      let identity = try await provider.signIn(mail: false, hint: saved.subject)
      return try pending(await establish(saved, identity: identity))
    }
    let identity = try await provider.signIn(mail: false, hint: nil)
    let saved = SavedRegistration(
      deployment: deployment, clientID: clientID, deviceIdentifier: UUID().uuidString,
      subject: identity.subject, identityCredential: identity.credential)
    return try pending(await establish(saved, identity: identity))
  }

  func restore() async throws -> [String: String] {
    guard let saved = try load() else { return ["kind": "signed-out"] }
    var next: SavedRegistration
    do {
      let identity = try await provider.refresh(saved.identityCredential)
      next = try await establish(saved, identity: identity)
    } catch {
      if saved.product != nil { return try failure(saved, reason: "unavailable") }
      throw error
    }
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
      return try connected(next)
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
    // Refresh the retained Product Sign-In independently of the mailbox selection.
    let identity = try await provider.refresh(saved.identityCredential)
    var next = try await establish(saved, identity: identity)
    do {
      let gmail = try await provider.signIn(
        mail: true, hint: reselect ? nil : (saved.mailbox?.subject ?? saved.subject))
      let receipt = try await checkedGmail(gmail)
      next.mailboxCredential = gmail.credential
      next.mailbox = receipt
      next.mailboxSetupReason = nil
      try save(next)
      return try connected(next)
    } catch RegistrationError.cancelled {
      return try failure(next, reason: "cancelled")
    } catch RegistrationError.declined {
      return try failure(next, reason: "declined")
    } catch RegistrationError.gmailUnavailable {
      return try failure(next, reason: "gmail-unavailable")
    } catch {
      return try failure(next, reason: "interrupted")
    }
  }

  func connected(_ saved: SavedRegistration) throws -> [String: String] {
    guard let product = saved.product, let mailbox = saved.mailbox else {
      throw RegistrationError.unavailable
    }
    return [
      "kind": "connected", "productAccountId": product.productAccountId,
      "providerSubject": mailbox.subject, "address": mailbox.address,
    ]
  }
}
