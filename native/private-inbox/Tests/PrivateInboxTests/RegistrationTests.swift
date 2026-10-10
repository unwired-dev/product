import Foundation
import Testing

@testable import PrivateInbox

@MainActor final class SyntheticGoogleRegistrationProvider: GoogleRegistrationProvider {
  var subject = "synthetic-product-subject"
  var outcome: RegistrationError?
  var scopes: Set<String> = []
  var gmailAvailable = true
  var address = "same@example.invalid"
  // Multi-connection journeys keep each provider subject's profile independent.
  var mailboxAddresses: [String: String] = [:]
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
    return GmailRegistrationReceipt(
      subject: identity.subject, address: mailboxAddresses[identity.subject] ?? address)
  }
  var gmailRequests: [URL] = []
  var gmailBodies: [Data?] = []
  var gmailContentTypes: [String] = []
  var gmailResponse: (Int, Data) = (200, Data(#"{"historyId":"7"}"#.utf8))
  var gmailFailure: (any Error)?
  func gmail(
    _ identity: GoogleRegistrationIdentity, url: URL, body: Data?, contentType: String
  ) async throws -> (Int, Data) {
    gmailRequests.append(url)
    gmailContentTypes.append(contentType)
    gmailBodies.append(body)
    let pause = beforeGmail
    beforeGmail = nil
    await pause?()
    if let gmailFailure { throw gmailFailure }
    return gmailResponse
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

  // The registration flow moved to TypeScript (packages/mail-core/test/registration-flow.test.ts).
  // Each retired flow test names its replacement there:
  // - googleRegistrationRetainsAccountAcrossConsentFailuresAndReselection: "keeps the Google Product
  //   Account across Gmail consent failures and mailbox reselection"
  // - interruptedGoogleRegistrationResumesWithoutReplacingIdentityOrExistingInbox: "resumes an
  //   interrupted Google registration without replacing its Product identity", plus the native
  //   storage half below
  // - appleRegistrationContinuesIntoGmailWithoutLinkingIdentities: "continues Apple registration
  //   into Gmail without linking identities"
  // - interruptedAppleRegistrationRestartsWithoutAnUncommittedAccount: "restarts an interrupted
  //   Apple registration without an uncommitted account"
  // - linkingVerifiesBothIdentitiesAndOpensTheSameAccountFromEitherProvider: "links after verifying
  //   both identities and opens the account from either provider"
  // - linkingRejectsOwnedIdentitiesStaleSessionsAndUnlinkedSwitches: "refuses owned identities,
  //   stale sessions and unlinked switches"

  @Test @MainActor
  func savedSignInSurvivesInterruptionAndNeverReplacesACommittedAccountOrInbox() async throws {
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
    var online = false
    let store = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: provider,
      connect: { identity, _, _ in
        guard online else { throw RegistrationError.unavailable }
        return ProductRegistrationReceipt(
          productAccountId: "account-" + identity.subject, trustedDeviceId: "synthetic-device",
          trustedDeviceCredential: String(repeating: "a", count: 64))
      })
    // The sign-in is stored before the backend request, so an interruption keeps it.
    _ = try await store.signInIdentity(.google, hint: false)
    try store.saveIdentity(replacing: true)
    await #expect(throws: RegistrationError.unavailable) {
      try await store.connectIdentity(.establish)
    }
    #expect(try store.load()?.subject == "synthetic-product-subject")
    #expect(try store.load()?.product == nil)
    online = true
    try await store.connectIdentity(.establish)
    let installation = try #require(try store.load()?.deviceIdentifier)
    // Once committed, another identity neither replaces the record nor reaches its account.
    provider.subject = "different-product-subject"
    #expect(try await store.signInIdentity(.google, hint: true)["matches"] as? Bool == false)
    #expect(provider.hints.last == "synthetic-product-subject")
    #expect(throws: RegistrationError.invalidIdentity) { try store.saveIdentity(replacing: true) }
    #expect(throws: RegistrationError.invalidIdentity) { try store.saveIdentity(replacing: false) }
    await #expect(throws: RegistrationError.invalidIdentity) {
      try await store.connectIdentity(.establish)
    }
    #expect(try store.load()?.subject == "synthetic-product-subject")
    #expect(try store.load()?.deviceIdentifier == installation)
    // A record for another Google client is not read by this one.
    let rotated = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "rotated-client",
      provider: provider, connect: { _, _, _ in throw RegistrationError.unavailable })
    #expect(try rotated.registration() == nil)
    #expect(try Data(contentsOf: directory.appendingPathComponent("inbox.enc")) == ciphertext)
  }

  @Test @MainActor func registrationProjectionCarriesNoCredentialTokenOrProviderSubject()
    async throws
  {
    let keys = DeviceKeychain(service: "dev.unwired.registration.tests.\(UUID().uuidString)")
    defer { try? keys.remove("registration") }
    let provider = SyntheticGoogleRegistrationProvider()
    provider.scopes = [RegistrationStore.gmailScope]
    // An account ID that does not spell the subject, so any subject in the projection is a leak.
    let store = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: provider,
      connect: { _, _, _ in
        ProductRegistrationReceipt(
          productAccountId: "synthetic-account", trustedDeviceId: "synthetic-device",
          trustedDeviceCredential: String(repeating: "a", count: 64))
      })
    _ = try await store.signIn()
    #expect(try await store.authorizeGmail()["kind"] == "connected")
    let saved = try #require(try store.load())
    let projection = try #require(try store.registration())
    let text = String(
      decoding: try JSONSerialization.data(withJSONObject: projection, options: .sortedKeys),
      as: UTF8.self)
    for secret in [
      "synthetic-product-subject", "synthetic-id-token", "synthetic-access-token",
      String(repeating: "a", count: 64), saved.deviceIdentifier,
      saved.identityCredential.base64EncodedString(),
    ] {
      #expect(!text.contains(secret))
    }
    // The fields TypeScript decodes, and no others.
    #expect(
      Set(projection.keys) == [
        "signInProvider", "product", "mailboxes", "mailboxRemovalPending", "privateSync", "session",
      ])
    #expect(
      (projection["product"] as? [String: Any]).map { Set($0.keys) } == [
        "productAccountId", "pending",
      ])
    let mailbox = try #require((projection["mailboxes"] as? [[String: Any]])?.first)
    #expect(Set(mailbox.keys) == ["id", "address", "epoch", "authorizationNeeded", "access"])
    #expect(mailbox["id"] as? String == MailboxConnection.id(subject: "synthetic-product-subject"))
    #expect(mailbox["access"] as? String == "verified")
  }

  @Test @MainActor func credentialedCallsAttachOnlyRequestedCredentialsAndNeverConnect()
    async throws
  {
    let keys = DeviceKeychain(service: "dev.unwired.registration.tests.\(UUID().uuidString)")
    defer { try? keys.remove("registration") }
    let provider = SyntheticGoogleRegistrationProvider()
    var sent: [BackendRequest] = []
    let store = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: provider,
      transport: { request in
        sent.append(request)
        return (403, Data(#"{"code":"SYNTHETIC"}"#.utf8))
      },
      connect: { identity, _, _ in
        ProductRegistrationReceipt(
          productAccountId: "account-" + identity.subject, trustedDeviceId: "synthetic-device",
          trustedDeviceCredential: String(repeating: "a", count: 64))
      })
    let revocation: [String: Any] = [
      "endpoint": "query", "path": "productAccount:isTrustedDeviceRevoked",
      "args": ["productAccountId": "account-synthetic-product-subject"], "device": true,
    ]
    // Without a saved Product Account there is no proof to attach.
    await #expect(throws: RegistrationError.unavailable) { _ = try await store.call(revocation) }
    _ = try await store.signIn()
    let reply = try await store.call(revocation)
    #expect(reply["status"] as? Int == 403)
    #expect(reply["body"] as? String == #"{"code":"SYNTHETIC"}"#)
    #expect(sent.last?.identity == nil)
    #expect(sent.last?.endpoint == .query)
    #expect(sent.last?.args["trustedDeviceId"] as? String == "synthetic-device")
    #expect(sent.last?.args["trustedDeviceCredential"] as? String == String(repeating: "a", count: 64))
    #expect(sent.last?.args["productAccountId"] as? String == "account-synthetic-product-subject")
    // The device proof replaces anything TypeScript names in its place.
    _ = try await store.call([
      "endpoint": "mutation", "path": "productAccount:unregisterTrustedDevice",
      "args": ["trustedDeviceCredential": "forged"], "identity": true, "device": true,
      "installation": true,
    ])
    #expect(sent.last?.identity?.subject == "synthetic-product-subject")
    #expect(sent.last?.args["trustedDeviceCredential"] as? String == String(repeating: "a", count: 64))
    #expect(sent.last?.args["deviceIdentifier"] as? String == (try store.load()?.deviceIdentifier))
    // Only the purpose-specific connect operation may receive an issued credential.
    for request: [String: Any] in [
      ["endpoint": "mutation", "path": "productAccount:connect", "args": [:]],
      ["endpoint": "action", "path": "productAccount:connect", "args": [:]],
      ["endpoint": "query", "path": "/sign-in-links/request", "args": [:]],
      ["endpoint": "action", "path": "productAccount:isTrustedDeviceRevoked", "args": [:]],
      ["endpoint": "httpAction", "path": "/sign-in-links/request", "args": [:]],
    ] {
      await #expect(throws: RegistrationError.unavailable) { _ = try await store.call(request) }
    }
    #expect(sent.count == 2)
  }

  // Covers the connect obligations #715 carried over: native validates the receipt it stores.
  @Test func connectReceiptsNeedTheAccountTheDeviceAndAWellFormedCredential() throws {
    let credential = String(repeating: "a", count: 64)
    func receipt(_ json: String) throws -> ProductRegistrationReceipt {
      try ProductRegistrationReceipt(
        connected: JSONDecoder().decode(ConnectReply.self, from: Data(json.utf8)))
    }
    let trusted = try receipt(
      #"{"productAccountId":"account","trustedDeviceId":"device","trustedDeviceCredential":"\#(credential)","signInProviders":["google"],"productSyncMaterialInitialized":true}"#
    )
    #expect(trusted.pending == nil)
    #expect(trusted.trustedDeviceId == "device")
    #expect(trusted.signInProviders == [.google])
    #expect(trusted.productSyncMaterialInitialized == true)
    let pending = try receipt(
      #"{"productAccountId":"account","pendingDeviceId":"pending","pendingDeviceCredential":"\#(credential)"}"#
    )
    #expect(pending.pending == true)
    #expect(pending.trustedDeviceId == "pending")
    for json in [
      #"{"productAccountId":"","trustedDeviceId":"device","trustedDeviceCredential":"\#(credential)"}"#,
      #"{"productAccountId":"account","trustedDeviceCredential":"\#(credential)"}"#,
      #"{"productAccountId":"account","trustedDeviceId":"","trustedDeviceCredential":"\#(credential)"}"#,
      #"{"productAccountId":"account","trustedDeviceId":"device"}"#,
      #"{"productAccountId":"account","trustedDeviceId":"device","trustedDeviceCredential":"abc"}"#,
      #"{"productAccountId":"account","pendingDeviceId":"p","pendingDeviceCredential":"\#(credential.uppercased())"}"#,
      #"{"trustedDeviceId":"device","trustedDeviceCredential":"\#(credential)"}"#,
    ] {
      #expect(throws: (any Error).self) { try receipt(json) }
    }
    let first = ProductRegistrationReceipt.connectArguments(
      deviceIdentifier: "installation", platform: "ios", previous: nil)
    #expect(first["deviceIdentifier"] as? String == "installation")
    #expect(first["platform"] as? String == "ios")
    #expect(first["supportsDeviceCredentials"] as? Bool == true)
    #expect(first["expectedProductAccountId"] == nil)
    let reconnect = ProductRegistrationReceipt.connectArguments(
      deviceIdentifier: "installation", platform: "macos", previous: trusted)
    #expect(reconnect["expectedProductAccountId"] as? String == "account")
    #expect(reconnect["trustedDeviceCredential"] as? String == credential)
    #expect(reconnect["pendingDeviceCredential"] == nil)
    let renewed = ProductRegistrationReceipt.connectArguments(
      deviceIdentifier: "installation", platform: "ios", previous: pending)
    #expect(renewed["pendingDeviceCredential"] as? String == credential)
    #expect(renewed["trustedDeviceCredential"] == nil)
  }
}
