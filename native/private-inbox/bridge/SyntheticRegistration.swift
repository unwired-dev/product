#if UNWIRED_REGISTRATION_MOCK
  import Foundation

  // Compiled only for an externally selected, fixed Mock Mail Session.
  @MainActor final class MockGoogleRegistrationProvider: GoogleRegistrationProvider {
    let scenario: String
    // The Gmail session that follows Apple sign-in in the same launch is declined.
    var declineNextMailbox = false
    init(scenario: String) { self.scenario = scenario }

    func identity(_ subject: String, granted: Bool) -> GoogleRegistrationIdentity {
      GoogleRegistrationIdentity(
        subject: subject, credential: Data(subject.utf8),
        idToken: "synthetic-identity", accessToken: "synthetic-mail-access",
        scopes: granted ? [RegistrationStore.gmailScope] : [])
    }
    func signIn(mail: Bool, hint: String?) async throws -> GoogleRegistrationIdentity {
      if !mail { return identity("synthetic-product-subject", granted: false) }
      if declineNextMailbox {
        declineNextMailbox = false
        return identity("synthetic-alternate-mailbox", granted: false)
      }
      if hint == nil { return identity("synthetic-alternate-mailbox", granted: true) }
      switch scenario {
      case "registration-cancelled": throw RegistrationError.cancelled
      case "registration-no-gmail": return identity("synthetic-no-gmail", granted: true)
      case "registration-interrupted": throw RegistrationError.unavailable
      default: return identity("synthetic-product-subject", granted: false)
      }
    }
    func refresh(_ credential: Data) async throws -> GoogleRegistrationIdentity {
      guard let subject = String(data: credential, encoding: .utf8), subject.hasPrefix("synthetic-")
      else {
        throw RegistrationError.invalidIdentity
      }
      return identity(subject, granted: subject == "synthetic-alternate-mailbox")
    }
    func verifyGmail(_ identity: GoogleRegistrationIdentity) async throws
      -> GmailRegistrationReceipt
    {
      if identity.subject == "synthetic-no-gmail" { throw RegistrationError.gmailUnavailable }
      return GmailRegistrationReceipt(subject: identity.subject, address: "other@example.invalid")
    }
  }

  @MainActor final class MockAppleRegistrationProvider: AppleRegistrationProvider {
    let google: MockGoogleRegistrationProvider
    init(google: MockGoogleRegistrationProvider) { self.google = google }

    func signIn() async throws -> AppleRegistrationIdentity {
      google.declineNextMailbox = google.scenario == "registration-apple"
      return AppleRegistrationIdentity(
        subject: "synthetic-apple-subject", idToken: "synthetic-apple-identity",
        email: "relay@privaterelay.example.invalid")
    }
    func credentialState(_ subject: String) async -> AppleCredentialState {
      subject == "synthetic-apple-subject" ? .authorized : .revoked
    }
  }

  @MainActor func mockRegistrationStore(bundle: String, scenario: String) throws
    -> RegistrationStore
  {
    guard
      [
        "registration-cancelled", "registration-declined", "registration-no-gmail",
        "registration-interrupted", "registration-apple", "registration-link",
      ].contains(scenario)
    else {
      throw RegistrationError.unavailable
    }
    let google = MockGoogleRegistrationProvider(scenario: scenario)
    // Each synthetic sign-in identity owns its own Product Account; in the link
    // scenario the Google identity is unregistered and may join the Apple account.
    let accounts = [
      "synthetic-product-subject": "synthetic-product-account",
      "synthetic-apple-subject": "synthetic-apple-product-account",
    ]
    return RegistrationStore(
      keys: DeviceKeychain(service: bundle + ".google-registration"),
      deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, apple: MockAppleRegistrationProvider(google: google),
      linking: SignInLinking(
        request: { identity, product, _ in
          guard accounts[identity.subject] == product.productAccountId else {
            throw RegistrationError.invalidIdentity
          }
          return SignInLinkRequest(
            linkTicket: String(repeating: "b", count: 64),
            signInProviders: product.signInProviders ?? [identity.provider])
        },
        complete: { identity, product, _ in
          guard scenario == "registration-link" else { throw RegistrationError.identityOwned }
          return (product.signInProviders ?? []) + [identity.provider]
        }),
      connect: { identity, _, _ in
        guard let account = accounts[identity.subject] else {
          throw RegistrationError.invalidIdentity
        }
        return ProductRegistrationReceipt(
          productAccountId: account, trustedDeviceId: "synthetic-device",
          trustedDeviceCredential: String(repeating: "a", count: 64),
          signInProviders: [identity.provider])
      })
  }
#endif
