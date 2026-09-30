#if UNWIRED_REGISTRATION_MOCK
  import Foundation

  // Compiled only for an externally selected, fixed Mock Mail Session.
  @MainActor final class MockGoogleRegistrationProvider: GoogleRegistrationProvider {
    let scenario: String
    init(scenario: String) { self.scenario = scenario }

    func identity(_ subject: String, granted: Bool) -> GoogleRegistrationIdentity {
      GoogleRegistrationIdentity(
        subject: subject, credential: Data(subject.utf8),
        idToken: "synthetic-identity", accessToken: "synthetic-mail-access",
        scopes: granted ? [RegistrationStore.gmailScope] : [])
    }
    func signIn(mail: Bool, hint: String?) async throws -> GoogleRegistrationIdentity {
      if !mail { return identity("synthetic-product-subject", granted: false) }
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

  @MainActor func mockRegistrationStore(bundle: String, scenario: String) throws
    -> RegistrationStore
  {
    guard
      [
        "registration-cancelled", "registration-declined", "registration-no-gmail",
        "registration-interrupted",
      ].contains(scenario)
    else {
      throw RegistrationError.unavailable
    }
    return RegistrationStore(
      keys: DeviceKeychain(service: bundle + ".google-registration"),
      deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: MockGoogleRegistrationProvider(scenario: scenario),
      connect: { identity, _, _ in
        guard identity.subject == "synthetic-product-subject" else {
          throw RegistrationError.invalidIdentity
        }
        return ProductRegistrationReceipt(
          productAccountId: "synthetic-product-account", trustedDeviceId: "synthetic-device",
          trustedDeviceCredential: String(repeating: "a", count: 64))
      })
  }
#endif
