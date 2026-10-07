import Foundation
import Testing

@testable import PrivateInbox

@MainActor final class SyntheticGoogleRegistrationProvider: GoogleRegistrationProvider {
  var subject = "synthetic-product-subject"
  var outcome: RegistrationError?
  var scopes: Set<String> = []
  var gmailAvailable = true
  var address = "same@example.invalid"
  var refreshes = 0
  var hints: [String?] = []
  var refreshFailure: (any Error)?
  var verificationFailure: (any Error)?
  // Google accounts whose Gmail grant is refused, while the others verify.
  var refusedSubjects: Set<String> = []
  var beforeRefresh: (() async -> Void)?
  var beforeGmail: (() async -> Void)?

  func value(_ subject: String) -> GoogleRegistrationIdentity {
    GoogleRegistrationIdentity(
      subject: subject, credential: Data("\(subject)#\(refreshes)".utf8),
      idToken: "synthetic-id-token-" + subject, accessToken: "synthetic-access-token",
      scopes: scopes)
  }
  func signIn(mail: Bool, hint: String?) async throws -> GoogleRegistrationIdentity {
    hints.append(hint)
    if let outcome { throw outcome }
    return value(subject)
  }
  func refresh(_ credential: Data) async throws -> GoogleRegistrationIdentity {
    guard let saved = String(data: credential, encoding: .utf8)?.split(separator: "#").first
    else {
      throw RegistrationError.invalidIdentity
    }
    refreshes += 1
    let identity = value(String(saved))
    let pause = beforeRefresh
    beforeRefresh = nil
    await pause?()
    if let refreshFailure { throw refreshFailure }
    return identity
  }
  func verifyGmail(_ identity: GoogleRegistrationIdentity) async throws -> GmailRegistrationReceipt
  {
    if let verificationFailure { throw verificationFailure }
    guard gmailAvailable, !refusedSubjects.contains(identity.subject) else {
      throw RegistrationError.gmailUnavailable
    }
    return GmailRegistrationReceipt(subject: identity.subject, address: address)
  }
  var gmailRequests: [URL] = []
  var gmailBodies: [Data?] = []
  func gmail(_ identity: GoogleRegistrationIdentity, url: URL, body: Data?) async throws -> (
    Int, Data
  ) {
    gmailRequests.append(url)
    gmailBodies.append(body)
    let pause = beforeGmail
    beforeGmail = nil
    await pause?()
    return (200, Data(#"{"historyId":"7"}"#.utf8))
  }
  func store(keys: DeviceKeychain, mailCache: PrivateInboxStore? = nil,
    deviceRevoked: ((ProductRegistrationReceipt) async throws -> Bool)? = nil
  ) -> RegistrationStore {
    RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: self, deviceRevoked: deviceRevoked, mailCache: mailCache,
      connect: { identity, _, _ in
        ProductRegistrationReceipt(
          productAccountId: "account-" + identity.subject,
          trustedDeviceId: "synthetic-device",
          trustedDeviceCredential: String(repeating: "a", count: 64))
      })
  }

}

@MainActor final class SyntheticAppleRegistrationProvider: AppleRegistrationProvider {
  var subject = "synthetic-apple-subject"
  var outcome: RegistrationError?
  var state = AppleCredentialState.authorized
  var signIns = 0
  // Apple returns the address on first authorization only.
  var email: String? = "relay@privaterelay.example.invalid"

  func signIn() async throws -> AppleRegistrationIdentity {
    signIns += 1
    if let outcome { throw outcome }
    defer { email = nil }
    return AppleRegistrationIdentity(
      subject: subject, idToken: "synthetic-apple-token-" + subject, email: email,
      authorizationCode: "synthetic-apple-code-\(signIns)")
  }
  func credentialState(_ subject: String) async -> AppleCredentialState { state }
  // Records every Product Sign-In presented to the synthetic backend.
  var presented: [ProductSignInIdentity] = []
  func store(keys: DeviceKeychain, google: SyntheticGoogleRegistrationProvider)
    -> RegistrationStore
  {
    RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, apple: self,
      connect: { [self] identity, _, _ in
        presented.append(identity)
        return ProductRegistrationReceipt(
          productAccountId: "account-" + identity.subject, trustedDeviceId: "synthetic-device",
          trustedDeviceCredential: String(repeating: "a", count: 64))
      })
  }
}

extension PrivateInboxTests {
  @Test func identityClaimsRejectWrongProviderNonceAudienceSubjectIssuerAndExpiry() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func token(_ changed: [String: Any] = [:]) throws -> String {
      var claims: [String: Any] = [
        "iss": "https://accounts.google.com", "aud": "native-client", "sub": "subject",
        "exp": now.timeIntervalSince1970 + 60, "nonce": "fresh-nonce",
      ]
      claims.merge(changed) { _, new in new }
      let bytes = try JSONSerialization.data(withJSONObject: claims)
      return "header."
        + bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
          of: "/", with: "_"
        ).replacingOccurrences(of: "=", with: "") + ".signature"
    }
    try IdentityTokenClaims.validate(
      token(), issuers: IdentityTokenClaims.google, audience: "native-client", subject: "subject",
      nonce: "fresh-nonce", now: now)
    let apple = try IdentityTokenClaims.validate(
      token(["iss": "https://appleid.apple.com", "email": "relay@privaterelay.example.invalid"]),
      issuers: IdentityTokenClaims.apple, audience: "native-client", subject: "subject",
      nonce: "fresh-nonce", now: now)
    #expect(apple.email == "relay@privaterelay.example.invalid")
    // A token from one Sign-In Provider never satisfies the other's issuer.
    #expect(throws: (any Error).self) {
      try IdentityTokenClaims.validate(
        token(), issuers: IdentityTokenClaims.apple, audience: "native-client",
        subject: "subject", nonce: "fresh-nonce", now: now)
    }
    for changed: [String: Any] in [
      ["nonce": "previous-session-nonce"], ["aud": "another-client"], ["sub": "another-subject"],
      ["iss": "https://untrusted.example.invalid"], ["exp": now.timeIntervalSince1970 - 1],
    ] {
      #expect(throws: (any Error).self) {
        try IdentityTokenClaims.validate(
          token(changed), issuers: IdentityTokenClaims.google, audience: "native-client",
          subject: "subject", nonce: "fresh-nonce", now: now)
      }
    }
  }

  @Test @MainActor func googleRegistrationRetainsAccountAcrossConsentFailuresAndReselection()
    async throws
  {
    let keys = DeviceKeychain(service: "dev.unwired.registration.tests.\(UUID().uuidString)")
    defer { try? keys.remove("registration") }
    let provider = SyntheticGoogleRegistrationProvider()
    let first = provider.store(keys: keys)
    let registered = try await first.signIn()
    #expect(
      registered == [
        "kind": "mailbox-needed", "productAccountId": "account-synthetic-product-subject",
        "signInProvider": "google",
      ])
    for failure in [RegistrationError.cancelled, .declined, .gmailUnavailable] {
      provider.outcome = failure
      let result = try await first.authorizeGmail()
      #expect(result["kind"] == "mailbox-needed")
      #expect(result["productAccountId"] == registered["productAccountId"])
      #expect(try await provider.store(keys: keys).restore()["kind"] == "mailbox-needed")
    }
    provider.outcome = nil
    // A signed-in Google identity with missing mail scopes cannot connect Gmail.
    let declined = try await first.authorizeGmail()
    #expect(declined["kind"] == "mailbox-needed")
    #expect(declined["reason"] == "declined")
    provider.scopes = [RegistrationStore.gmailScope]
    provider.gmailAvailable = false
    let unavailable = try await first.authorizeGmail()
    #expect(unavailable["kind"] == "mailbox-needed")
    #expect(unavailable["reason"] == "gmail-unavailable")
    provider.gmailAvailable = true
    provider.subject = "synthetic-mailbox-subject"
    let connected = try await provider.store(keys: keys).authorizeGmail(chooseAccount: true)
    #expect(
      connected == [
        "kind": "connected", "productAccountId": "account-synthetic-product-subject",
        "signInProvider": "google",
        "mailboxes": mailboxList([
          ("synthetic-mailbox-subject", "same@example.invalid", "connected")
        ]),
      ])
    #expect(try await provider.store(keys: keys).restore() == connected)
    // A failed addition of another mailbox is reported without dropping the connected one.
    for failure in [RegistrationError.cancelled, .declined, .gmailUnavailable] {
      provider.outcome = failure
      await #expect(throws: failure) { try await first.authorizeGmail(chooseAccount: true) }
      #expect(try await provider.store(keys: keys).restore() == connected)
    }
    provider.outcome = nil
    #expect(try first.load()?.subject == "synthetic-product-subject")
    #expect(
      !connected.values.contains(where: {
        $0.contains("token") || $0.contains(String(repeating: "a", count: 64))
      }))
    provider.gmailAvailable = false
    #expect(try await provider.store(keys: keys).restore()["kind"] == "mailbox-needed")
  }

  @Test @MainActor
  func interruptedGoogleRegistrationResumesWithoutReplacingIdentityOrExistingInbox() async throws {
    let service = "dev.unwired.registration.tests.\(UUID().uuidString)"
    let keys = DeviceKeychain(service: service)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      try? keys.remove("registration")
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    let inbox = PrivateInboxStore(directory: directory, service: service)
    _ = try inbox.open(seed: seed)
    let ciphertext = try Data(contentsOf: directory.appendingPathComponent("inbox.enc"))
    let provider = SyntheticGoogleRegistrationProvider()
    let interrupted = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: provider,
      connect: { _, _, _ in throw RegistrationError.unavailable })
    await #expect(throws: (any Error).self) { try await interrupted.signIn() }
    #expect(try interrupted.load()?.subject == "synthetic-product-subject")
    let resumed = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: provider,
      connect: { identity, _, _ in
        ProductRegistrationReceipt(
          productAccountId: identity.subject, trustedDeviceId: "synthetic-device",
          trustedDeviceCredential: "synthetic-device-proof")
      })
    #expect(try await resumed.restore()["kind"] == "mailbox-needed")
    let beforeRefresh = try interrupted.load()?.identityCredential
    let offline = try await interrupted.restore()
    #expect(try interrupted.load()?.identityCredential != beforeRefresh)
    #expect(offline["kind"] == "mailbox-needed")
    #expect(offline["productAccountId"] == "synthetic-product-subject")
    #expect(offline["reason"] == "unavailable")
    // A Product identity failure before mailbox selection reports the retained account.
    let reauthorize = try await interrupted.authorizeGmail(chooseAccount: true)
    #expect(reauthorize["kind"] == "mailbox-needed")
    #expect(reauthorize["reason"] == "interrupted")
    // A record for another Google client is ignored rather than blocking a new sign-in.
    let rotated = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "rotated-client",
      provider: provider, connect: { _, _, _ in throw RegistrationError.unavailable })
    #expect(try await rotated.restore() == ["kind": "signed-out"])
    provider.subject = "different-product-subject"
    await #expect(throws: (any Error).self) { try await resumed.signIn() }
    #expect(try resumed.load()?.subject == "synthetic-product-subject")
    #expect(try Data(contentsOf: directory.appendingPathComponent("inbox.enc")) == ciphertext)
  }

  @Test @MainActor func appleRegistrationContinuesIntoGmailWithoutLinkingIdentities() async throws {
    let keys = DeviceKeychain(service: "dev.unwired.registration.tests.\(UUID().uuidString)")
    defer { try? keys.remove("registration") }
    let google = SyntheticGoogleRegistrationProvider()
    let apple = SyntheticAppleRegistrationProvider()
    func store() -> RegistrationStore { apple.store(keys: keys, google: google) }
    apple.outcome = .cancelled
    await #expect(throws: RegistrationError.cancelled) { try await store().signIn(with: .apple) }
    #expect(try store().load() == nil)
    apple.outcome = nil
    let account = [
      "productAccountId": "account-synthetic-apple-subject", "signInProvider": "apple",
      "contactEmail": "relay@privaterelay.example.invalid",
    ]
    #expect(
      try await store().signIn(with: .apple) == account.merging(["kind": "mailbox-needed"]) { $1 })
    // Apple sign-in grants no mail scope; the first Gmail session is declined here.
    let declined = try await store().authorizeGmail()
    #expect(declined == account.merging(["kind": "mailbox-needed", "reason": "declined"]) { $1 })
    // Restoring checks Apple's credential state without renewing the backend session.
    #expect(try await store().restore() == declined)
    // The Gmail account's address matches the relay address but is not a Linked Sign-In.
    google.scopes = [RegistrationStore.gmailScope]
    google.subject = "synthetic-mailbox-subject"
    google.address = "relay@privaterelay.example.invalid"
    let connected = try await store().authorizeGmail()
    #expect(
      connected
        == account.merging([
          "kind": "connected",
          "mailboxes": mailboxList([
            ("synthetic-mailbox-subject", "relay@privaterelay.example.invalid", "connected")
          ]),
        ]) { $1 })
    #expect(try await store().restore() == connected)
    // Neither the Apple subject nor its address is used to choose a Google mailbox.
    #expect(google.hints == [nil, nil])
    #expect(apple.presented.map(\.provider) == [.apple])
    #expect(apple.presented.allSatisfy { $0.subject == "synthetic-apple-subject" })
    // A committed Apple Product Account is not reachable through Google without explicit linking.
    await #expect(throws: RegistrationError.invalidIdentity) {
      try await store().signIn(with: .google)
    }
    // Reauthentication keeps the address Apple returned on first authorization.
    #expect(try await store().signIn(with: .apple)["contactEmail"] == account["contactEmail"])
    #expect(try await store().authorizeGmail() == connected)
    apple.state = .revoked
    #expect(
      try await store().restore()
        == account.merging(["kind": "mailbox-needed", "reason": "unavailable"]) { $1 })
    #expect(try await store().authorizeGmail()["reason"] == "unavailable")
    #expect(try store().load()?.product?.productAccountId == account["productAccountId"])
  }

  @Test @MainActor func interruptedAppleRegistrationRestartsWithoutAnUncommittedAccount()
    async throws
  {
    let keys = DeviceKeychain(service: "dev.unwired.registration.tests.\(UUID().uuidString)")
    defer { try? keys.remove("registration") }
    let google = SyntheticGoogleRegistrationProvider()
    let apple = SyntheticAppleRegistrationProvider()
    var online = false
    let store = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, apple: apple,
      connect: { identity, _, _ in
        guard online else { throw RegistrationError.unavailable }
        return ProductRegistrationReceipt(
          productAccountId: "account-" + identity.subject, trustedDeviceId: "synthetic-device",
          trustedDeviceCredential: String(repeating: "a", count: 64))
      })
    await #expect(throws: RegistrationError.unavailable) { try await store.signIn(with: .apple) }
    #expect(try store.load()?.provider == .apple)
    // Only an interactive Apple session can finish it, so restore reports the sign-in step.
    #expect(try await store.restore() == ["kind": "signed-out"])
    await #expect(throws: RegistrationError.unavailable) {
      try await store.authorizeGmail()
    }
    online = true
    // No Product Account was committed, so another Sign-In Provider may start fresh.
    let registered = try await store.signIn(with: .google)
    #expect(registered["productAccountId"] == "account-synthetic-product-subject")
    #expect(registered["signInProvider"] == "google")
    #expect(try store.load()?.contactEmail == nil)
  }
}

// Enforces the backend's ownership rules: one owner per subject, never by email.
@MainActor final class SyntheticSignInBackend {
  var owners: [String: String] = [:]
  var linked: [String: [SignInProvider]] = [:]
  var pending: [String: (account: String, provider: SignInProvider)] = [:]
  var stale = false
  // Identities that verified each link request, in order.
  var verified: [String] = []

  func receipt(_ account: String) -> ProductRegistrationReceipt {
    ProductRegistrationReceipt(
      productAccountId: account, trustedDeviceId: "synthetic-device",
      trustedDeviceCredential: String(repeating: "a", count: 64),
      signInProviders: linked[account])
  }
  func connect(_ identity: ProductSignInIdentity, previous: ProductRegistrationReceipt?) throws
    -> ProductRegistrationReceipt
  {
    let existing = owners[identity.subject]
    if let previous, existing != previous.productAccountId {
      throw RegistrationError.invalidIdentity
    }
    let account = existing ?? "account-" + identity.subject
    owners[identity.subject] = account
    if linked[account] == nil { linked[account] = [identity.provider] }
    return receipt(account)
  }
  func store(
    keys: DeviceKeychain, google: SyntheticGoogleRegistrationProvider,
    apple: SyntheticAppleRegistrationProvider
  ) -> RegistrationStore {
    RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, apple: apple,
      linking: SignInLinking(
        request: { [self] identity, product, provider in
          guard !stale else { throw RegistrationError.staleAuthentication }
          guard owners[identity.subject] == product.productAccountId else {
            throw RegistrationError.invalidIdentity
          }
          verified.append(identity.subject)
          let providers = linked[product.productAccountId] ?? []
          if providers.contains(provider) {
            return SignInLinkRequest(linkTicket: nil, signInProviders: providers)
          }
          let ticket = UUID().uuidString
          pending[ticket] = (product.productAccountId, provider)
          return SignInLinkRequest(linkTicket: ticket, signInProviders: providers)
        },
        complete: { [self] identity, product, ticket in
          guard let request = pending.removeValue(forKey: ticket),
            request.account == product.productAccountId, request.provider == identity.provider
          else { throw RegistrationError.staleAuthentication }
          guard owners[identity.subject] == nil else { throw RegistrationError.identityOwned }
          verified.append(identity.subject)
          owners[identity.subject] = request.account
          linked[request.account, default: []].append(identity.provider)
          return linked[request.account] ?? []
        }),
      connect: { [self] identity, _, previous in try connect(identity, previous: previous) })
  }
}

extension PrivateInboxTests {
  @Test @MainActor func linkingVerifiesBothIdentitiesAndOpensTheSameAccountFromEitherProvider()
    async throws
  {
    let keys = DeviceKeychain(service: "dev.unwired.registration.tests.\(UUID().uuidString)")
    let otherDevice = DeviceKeychain(
      service: "dev.unwired.registration.tests.\(UUID().uuidString)")
    defer {
      try? keys.remove("registration")
      try? otherDevice.remove("registration")
    }
    let google = SyntheticGoogleRegistrationProvider()
    let apple = SyntheticAppleRegistrationProvider()
    let backend = SyntheticSignInBackend()
    func store(_ keys: DeviceKeychain) -> RegistrationStore {
      backend.store(keys: keys, google: google, apple: apple)
    }
    _ = try await store(keys).signIn(with: .apple)
    google.scopes = [RegistrationStore.gmailScope]
    google.subject = "synthetic-mailbox-subject"
    let connected = try await store(keys).authorizeGmail()
    #expect(connected["kind"] == "connected")
    // The Gmail grant is a Mailbox Connection, never a Linked Sign-In.
    #expect(connected["alternateSignIn"] == nil)
    #expect(backend.owners["synthetic-mailbox-subject"] == nil)

    // Cancelling the second identity leaves the account unchanged.
    google.subject = "synthetic-linked-subject"
    google.outcome = .cancelled
    await #expect(throws: RegistrationError.cancelled) { try await store(keys).link(.google) }
    #expect(try await store(keys).restore() == connected)
    google.outcome = nil
    google.hints = []
    let linked = try await store(keys).link(.google)
    #expect(linked == connected.merging(["alternateSignIn": "google"]) { $1 })
    // Both identities were verified interactively; the mailbox never hinted the linked one.
    #expect(
      backend.verified == [
        "synthetic-apple-subject", "synthetic-apple-subject", "synthetic-linked-subject",
      ])
    #expect(google.hints == [nil])
    #expect(try await store(keys).restore() == linked)
    // Linking again reports the existing link without another Google session.
    #expect(try await store(keys).link(.google) == linked)
    #expect(google.hints == [nil])

    // On another installation the linked Google identity opens the same Product Account.
    let alternate = try await store(otherDevice).signIn(with: .google)
    #expect(alternate["productAccountId"] == "account-synthetic-apple-subject")
    #expect(alternate["signInProvider"] == "google")
    #expect(alternate["alternateSignIn"] == "apple")

    // When Apple is revoked here, the Linked Sign-In recovers this device's account.
    apple.state = .revoked
    #expect(try await store(keys).restore()["reason"] == "unavailable")
    // The connected mailbox is rechecked, not reauthorized, after switching sign-ins.
    google.hints = []
    let recovered = try await store(keys).signIn(with: .google)
    #expect(
      recovered
        == connected.merging([
          "signInProvider": "google", "alternateSignIn": "apple",
        ]) { $1 })
    #expect(google.hints == [nil])
  }

  @Test @MainActor func linkingRejectsOwnedIdentitiesStaleSessionsAndUnlinkedSwitches()
    async throws
  {
    let keys = DeviceKeychain(service: "dev.unwired.registration.tests.\(UUID().uuidString)")
    defer { try? keys.remove("registration") }
    let google = SyntheticGoogleRegistrationProvider()
    let apple = SyntheticAppleRegistrationProvider()
    let backend = SyntheticSignInBackend()
    let store = backend.store(keys: keys, google: google, apple: apple)
    // This Google identity already registered its own Product Account elsewhere.
    _ = try backend.connect(
      ProductSignInIdentity(
        provider: .google, subject: "synthetic-product-subject", idToken: "", credential: Data(),
        contactEmail: nil), previous: nil)
    let registered = try await store.signIn(with: .apple)
    // An unlinked provider cannot reach the committed account or create another one.
    await #expect(throws: RegistrationError.invalidIdentity) {
      try await store.signIn(with: .google)
    }
    await #expect(throws: RegistrationError.identityOwned) { try await store.link(.google) }
    backend.stale = true
    await #expect(throws: RegistrationError.staleAuthentication) {
      try await store.link(.google)
    }
    // A different Apple ID cannot vouch for this Product Account.
    backend.stale = false
    apple.subject = "another-apple-subject"
    await #expect(throws: RegistrationError.invalidIdentity) { try await store.link(.google) }
    #expect(try await store.restore() == registered)
    #expect(backend.linked["account-synthetic-apple-subject"] == [.apple])
    #expect(backend.owners.count == 2)
  }
}
