#if UNWIRED_REGISTRATION_MOCK
  import CryptoKit
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

  // Convex's Product Sync rules over device-only Keychain storage, so relaunches keep its records.
  @MainActor final class MockProductSyncBackend {
    struct Request: Codable {
      let account: String
      let device: String
      let publicKey: Data
      var approved: KeyRingEnvelope.Enrollment?
      var checks = 0
    }
    struct State: Codable {
      var recovery: [String: EncryptedPayload] = [:]
      var records: [String: [String: StoredPayload]] = [:]
      var requests: [String: Request] = [:]
      // Keys held by the synthetic trusted device of an account that existed before this run.
      var trusted: [String: ProductSyncKeyRing] = [:]
      // A removal's pending epoch, transition and recovery envelope, until this device adopts it.
      var rotations: [String: Rotation] = [:]
      var removed: Set<String> = []
      // Product Accounts this device deleted; their sign-ins are refused afterwards.
      var deleted: Set<String> = []
      // The launch that first connected; a later launch learns of this device's removal.
      var connectedLaunch: String?
    }
    struct Rotation: Codable {
      let epoch: Int
      let transition: EncryptedPayload
      let recovery: EncryptedPayload
    }
    // The other device of the `registration-revocation` account, which this device removes.
    static let iPad = TrustedDevice(id: "synthetic-ipad", name: "iPad", registeredAt: 1_788_220_800_000)
    // The synthetic account's Recovery Key, typed by the `registration-recovery` journey.
    static let recoveryKey = "000G-40R4-0M30-E209-185G-R38E-1W81-24GK-2GAH-C5RR-34D1-P70X-3RFG"
    let keys: DeviceKeychain
    // Whether the synthetic trusted device is available to approve this device.
    let approves: Bool
    // Whether the account has an iPad this device can remove.
    let removable: Bool
    init(keys: DeviceKeychain, approves: Bool, removable: Bool = false) {
      self.keys = keys
      self.approves = approves
      self.removable = removable
    }

    // Another device already created this account's keys and saved a mailbox with them.
    func seedTrustedDevice(_ account: String) throws {
      try update { state in
        guard state.trusted[account] == nil else { return }
        let ring = ProductSyncKeyRing.create()
        state.trusted[account] = ring
        state.recovery[account] = try KeyRingEnvelope.recovery(
          ring, key: RecoveryKey(parsing: Self.recoveryKey), account: account)
        let identifier = try ring.identifier("mailbox", "gmail:synthetic-trusted-mailbox")
        state.records[account] = [
          identifier: StoredPayload(
            payloadIdentifier: identifier,
            encryptedPayload: try ring.seal(
              record: JSONEncoder().encode(
                MailboxDescriptor(provider: "gmail", address: "alex@example.invalid")),
              account: account, identifier: identifier,
              schemaVersion: MailboxDescriptor.schemaVersion), updatedAt: 1)
        ]
      }
    }

    // The synthetic trusted device approves once the request has been shown, using the code the
    // person would type from this device's screen; it reads that code from the run's Keychain.
    func approveIfShown(_ id: String, state: inout State) throws {
      guard approves, var request = state.requests[id], request.approved == nil,
        let ring = state.trusted[request.account]
      else { return }
      request.checks += 1
      if request.checks > 1,
        let data = try keys.read("product-sync-enrollment." + request.account)
      {
        let shown = try JSONDecoder().decode(ProductSyncEnrollment.self, from: data)
        if shown.requestId == id {
          request.approved = try KeyRingEnvelope.enrollment(
            ring, to: Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.publicKey),
            code: EnrollmentCode(parsing: shown.code),
            binding: .init(account: request.account, device: request.device, request: id))
        }
      }
      state.requests[id] = request
    }

    func state() throws -> State {
      try keys.read("synthetic-product-sync").map {
        try JSONDecoder().decode(State.self, from: $0)
      } ?? State()
    }
    func update<Value>(_ change: (inout State) throws -> Value) throws -> Value {
      var next = try state()
      let value = try change(&next)
      try keys.save(JSONEncoder().encode(next), account: "synthetic-product-sync")
      return value
    }
    func initialized(_ account: String) throws -> Bool { try state().recovery[account] != nil }

    var backend: ProductSyncBackend {
      ProductSyncBackend(
        initialize: { [self] _, product, envelope in
          try update { state in
            if let existing = state.recovery[product.productAccountId] {
              return existing == envelope
            }
            state.recovery[product.productAccountId] = envelope
            return true
          }
        },
        list: { [self] _, product, prefix in
          try state().records[product.productAccountId, default: [:]].values
            .filter { $0.payloadIdentifier.hasPrefix(prefix) }
            .sorted { $0.payloadIdentifier < $1.payloadIdentifier }
        },
        put: { [self] _, product, identifier, payload, expected in
          try update { state in
            let existing = state.records[product.productAccountId]?[identifier]
            if let existing, existing.updatedAt != expected { return existing }
            let stored = StoredPayload(
              payloadIdentifier: identifier, encryptedPayload: payload,
              updatedAt: (existing?.updatedAt ?? 0) + 1)
            state.records[product.productAccountId, default: [:]][identifier] = stored
            return stored
          }
        },
        requestEnrollment: { [self] _, product, publicKey in
          try update { state in
            guard state.recovery[product.productAccountId] != nil else {
              throw RegistrationError.unavailable
            }
            state.requests = state.requests.filter { $0.value.device != product.trustedDeviceId }
            let id = "synthetic-request-" + UUID().uuidString
            state.requests[id] = Request(
              account: product.productAccountId, device: product.trustedDeviceId,
              publicKey: publicKey.rawRepresentation)
            return id
          }
        },
        enrollmentStatus: { [self] _, product, id in
          try update { state in
            try approveIfShown(id, state: &state)
            guard let request = state.requests[id], request.device == product.trustedDeviceId
            else { return EnrollmentStatus(state: .cancelled) }
            guard let approved = request.approved else { return EnrollmentStatus(state: .pending) }
            return EnrollmentStatus(state: .approved, approval: (1, approved))
          }
        },
        completeEnrollment: { [self] _, _, id in
          try update { state in state.requests[id] = nil }
        },
        // The synthetic devices in this session never wait for this device's approval.
        pendingEnrollments: { _, _ in [] },
        approveEnrollment: { _, _, _, _, _ in throw RegistrationError.enrollmentUnavailable },
        // Only this device's own request can be cancelled, as after Recovery Key unlock.
        declineEnrollment: { [self] _, product, id in
          try update { state in
            guard state.requests[id]?.device == product.trustedDeviceId else {
              throw RegistrationError.enrollmentUnavailable
            }
            state.requests[id] = nil
          }
        },
        recoveryEnvelope: { [self] _, product in
          guard let envelope = try state().recovery[product.productAccountId] else {
            throw RegistrationError.unavailable
          }
          return StoredPayload(
            payloadIdentifier: "product-account-recovery-v1", encryptedPayload: envelope,
            updatedAt: 1)
        },
        keyRotation: { [self] _, product in
          try state().rotations[product.productAccountId].map {
            KeyRotation(keyEpoch: $0.epoch, transition: $0.transition)
          }
        },
        // This device is the only one left, so its adoption completes the rotation.
        acknowledgeRotation: { [self] _, product, epoch in
          try update { state in
            let account = product.productAccountId
            guard let rotation = state.rotations[account], rotation.epoch == epoch else { return }
            state.recovery[account] = rotation.recovery
            state.rotations[account] = nil
          }
        },
        trustedDevices: { [self] _, _ in
          guard removable else { return [] }
          return try state().removed.contains(Self.iPad.id) ? [] : [Self.iPad]
        },
        revoke: { [self] _, product, target, transition, recovery, _ in
          try update { state in
            guard removable, target == Self.iPad.id, !state.removed.contains(target),
              recovery.schemaVersion == KeyRingEnvelope.recoverySchemaVersion
            else { throw RegistrationError.unavailable }
            state.removed.insert(target)
            state.rotations[product.productAccountId] = Rotation(
              epoch: recovery.keyVersion, transition: transition, recovery: recovery)
          }
        })
    }
  }

  @MainActor func mockRegistrationStore(bundle: String, scenario: String) throws
    -> RegistrationStore
  {
    guard
      [
        "registration-cancelled", "registration-declined", "registration-no-gmail",
        "registration-interrupted", "registration-apple", "registration-link",
        "registration-enrollment", "registration-recovery", "registration-revocation",
        "registration-revoked", "registration-removal",
      ].contains(scenario)
    else {
      throw RegistrationError.unavailable
    }
    let google = MockGoogleRegistrationProvider(scenario: scenario)
    let keys = DeviceKeychain(service: bundle + ".google-registration")
    let launch = UUID().uuidString
    let productSync = MockProductSyncBackend(
      keys: keys, approves: scenario == "registration-enrollment",
      removable: scenario == "registration-revocation")
    // The Google account already exists with keys on a synthetic trusted device. In the recovery
    // scenario that device is lost, and the person holds the account's Recovery Key.
    if scenario == "registration-enrollment" || scenario == "registration-recovery" {
      try productSync.seedTrustedDevice("synthetic-product-account")
    }
    // Each synthetic sign-in identity owns its own Product Account; in the link
    // scenario the Google identity is unregistered and may join the Apple account.
    let accounts = [
      "synthetic-product-subject": "synthetic-product-account",
      "synthetic-apple-subject": "synthetic-apple-product-account",
    ]
    return RegistrationStore(
      keys: keys,
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
      productSync: productSync.backend,
      removal: AccountRemoval(
        unregister: { _, _, _ in },
        delete: { _, product in
          try productSync.update { $0.deleted.insert(product.productAccountId) }
        }),
      connect: { identity, _, _ in
        guard let account = accounts[identity.subject] else {
          throw RegistrationError.invalidIdentity
        }
        if try productSync.state().deleted.contains(account) {
          throw RegistrationError.deleted
        }
        // Another device removes this one after its first sign-in; the relaunch learns of it.
        let earlier = try productSync.update { state in
          defer { state.connectedLaunch = state.connectedLaunch ?? launch }
          return state.connectedLaunch.map { $0 != launch } ?? false
        }
        if scenario == "registration-revoked", earlier { throw RegistrationError.revoked }
        return ProductRegistrationReceipt(
          productAccountId: account, trustedDeviceId: "synthetic-device",
          trustedDeviceCredential: String(repeating: "a", count: 64),
          signInProviders: [identity.provider],
          productSyncMaterialInitialized: try productSync.initialized(account))
      })
  }
#endif
