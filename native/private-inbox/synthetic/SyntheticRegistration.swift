#if UNWIRED_REGISTRATION_MOCK
  import CryptoKit
  import Foundation

  // Compiled only for the externally selected `registration-enrollment` Mock Mail Session, whose
  // synthetic trusted device seals its approval with real key material. Every other registration
  // scenario is answered from TypeScript through the synthetic relay.
  @MainActor final class MockGoogleRegistrationProvider: GoogleRegistrationProvider {
    func identity(_ subject: String) -> GoogleRegistrationIdentity {
      GoogleRegistrationIdentity(
        subject: subject, credential: Data(subject.utf8),
        idToken: "synthetic-identity", accessToken: "synthetic-mail-access", scopes: [])
    }
    func signIn(mail: Bool, hint: String?) async throws -> GoogleRegistrationIdentity {
      identity("synthetic-product-subject")
    }
    func refresh(_ credential: Data) async throws -> GoogleRegistrationIdentity {
      guard let subject = String(data: credential, encoding: .utf8), subject.hasPrefix("synthetic-")
      else {
        throw RegistrationError.invalidIdentity
      }
      return identity(subject)
    }
    // The approved device's Gmail still needs its own authorization, which the journey never gives.
    func verifyGmail(_ identity: GoogleRegistrationIdentity) async throws
      -> GmailRegistrationReceipt
    {
      throw RegistrationError.gmailUnavailable
    }
    func gmail(
      _ identity: GoogleRegistrationIdentity, url: URL, body request: Data?, contentType: String
    ) async throws -> (Int, Data) {
      (401, Data())
    }
  }

  // Convex's Product Sync rules over device-only Keychain storage, so relaunches keep its records.
  @MainActor final class MockProductSyncBackend {
    struct Request: Codable {
      let account: String
      let publicKey: Data
      // The encryption key the approval is bound to and admission binds.
      let deviceKey: Data
      var approved: KeyRingEnvelope.Enrollment?
    }
    struct State: Codable {
      var recovery: [String: EncryptedPayload] = [:]
      var records: [String: [String: StoredPayload]] = [:]
      // Delivery claims this device holds, by account; no other device claims in mock sessions.
      var claims: [String: Set<String>]?
      // Open enrollment requests by Pending Device id.
      var requests: [String: Request] = [:]
      // Device identifiers each account admitted: the one that created its keys, then others.
      var admitted: [String: [String]] = [:]
      // Keys held by the synthetic trusted device of an account that existed before this run.
      var trusted: [String: ProductSyncKeyRing] = [:]
      // Bound encryption keys, by Trusted Device id.
      var deviceKeys: [String: Data] = [:]
    }
    // The synthetic account's Recovery Key, which only seals the trusted device's recovery envelope.
    static let recoveryKey = "000G-40R4-0M30-E209-185G-R38E-1W81-24GK-2GAH-C5RR-34D1-P70X-3RFG"
    static let pendingPrefix = "synthetic-pending-"
    let keys: DeviceKeychain
    init(keys: DeviceKeychain) { self.keys = keys }

    // Another device already created this account's keys and saved a mailbox with them.
    func seedTrustedDevice(_ account: String) throws {
      try update { state in
        guard state.trusted[account] == nil else { return }
        let ring = ProductSyncKeyRing.create()
        let key = try RecoveryKey(parsing: Self.recoveryKey)
        state.trusted[account] = ring
        state.admitted[account] = ["synthetic-trusted-installation"]
        state.recovery[account] = try KeyRingEnvelope.recovery(ring, key: key, account: account)
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

    // A Trusted Device for an admitted identifier; any other device of an account with keys waits.
    func connect(_ account: String, deviceIdentifier: String) throws -> (id: String, pending: Bool)
    {
      try update { state in
        let admitted = state.admitted[account, default: []]
        if admitted.contains(deviceIdentifier)
          || (admitted.isEmpty && state.recovery[account] == nil)
        {
          if !admitted.contains(deviceIdentifier) {
            state.admitted[account, default: []].append(deviceIdentifier)
          }
          return ("synthetic-device-" + deviceIdentifier, false)
        }
        return (Self.pendingPrefix + deviceIdentifier, true)
      }
    }

    // The synthetic trusted device approves once the request has been shown and this device checks
    // for approval, using the code the person would type from this device's screen; it reads that
    // code from the run's Keychain.
    func approveIfShown(_ id: String, state: inout State) throws {
      guard var request = state.requests[id], request.approved == nil,
        let ring = state.trusted[request.account]
      else { return }
      if let data = try keys.read("product-sync-enrollment." + request.account) {
        let shown = try JSONDecoder().decode(ProductSyncEnrollment.self, from: data)
        if shown.pendingDeviceId == id {
          request.approved = try KeyRingEnvelope.enrollment(
            ring, to: Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.publicKey),
            code: EnrollmentCode(parsing: shown.code),
            binding: .init(
              account: request.account, device: id,
              deviceKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.deviceKey)))
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

    // Native Draft sync's records and delivery claims.
    var backend: ProductSyncBackend {
      ProductSyncBackend(
        list: { [self] _, product, prefix in
          try state().records[product.productAccountId, default: [:]].values
            .filter { $0.payloadIdentifier.hasPrefix(prefix) }
            .sorted { $0.payloadIdentifier < $1.payloadIdentifier }
        },
        put: { [self] _, product, identifier, payload, expected in
          try update { state in
            guard payload.keyVersion == 1 else { throw ProductSyncWriteFailure.keyRotationRequired }
            let existing = state.records[product.productAccountId]?[identifier]
            if let existing, existing.updatedAt != expected { return existing }
            let stored = StoredPayload(
              payloadIdentifier: identifier, encryptedPayload: payload,
              updatedAt: (existing?.updatedAt ?? 0) + 1)
            state.records[product.productAccountId, default: [:]][identifier] = stored
            return stored
          }
        },
        get: { [self] _, product, identifier in
          try state().records[product.productAccountId]?[identifier]
        },
        claimDelivery: { [self] _, product, identifier in
          try update { state in
            state.claims = (state.claims ?? [:]).merging([
              product.productAccountId: [identifier]
            ]) { $0.union($1) }
          }
          return true
        })
    }

    // A new request replaces the earlier key, so an approval sealed to it is never collected.
    func requestEnrollment(_ product: ProductRegistrationReceipt, _ args: [String: Any]) throws {
      try update { state in
        guard product.pending == true, state.recovery[product.productAccountId] != nil,
          let publicKey = Self.data(args["enrollmentPublicKey"]),
          let deviceKey = Self.data(args["deviceEncryptionPublicKey"])
        else { throw RegistrationError.unavailable }
        state.requests[product.trustedDeviceId] = Request(
          account: product.productAccountId, publicKey: publicKey, deviceKey: deviceKey)
      }
    }

    func enrollmentStatus(_ product: ProductRegistrationReceipt) throws -> [String: Any] {
      try update { state in
        let id = product.trustedDeviceId
        try approveIfShown(id, state: &state)
        guard let request = state.requests[id] else { return ["state": "cancelled"] }
        guard let approved = request.approved else { return ["state": "pending"] }
        return [
          "state": "approved",
          "approval": [
            "keyVersion": 1,
            "encapsulatedKeyBase64": approved.encapsulatedKey.base64EncodedString(),
            "ciphertextBase64": approved.ciphertext.base64EncodedString(),
          ],
        ]
      }
    }

    // Admits a Pending Device that the synthetic trusted device approved.
    func completeEnrollment(_ product: ProductRegistrationReceipt, _ args: [String: Any]) throws
      -> [String: Any]
    {
      try update { state in
        let id = product.trustedDeviceId
        // Only the encryption key the approval named is admitted.
        let authorized = state.requests[id].flatMap { $0.approved == nil ? nil : $0.deviceKey }
        guard args["keyVersion"] as? Int == 1, product.pending == true,
          id.hasPrefix(Self.pendingPrefix), let authorized,
          authorized == Self.data(args["deviceEncryptionPublicKey"])
        else { return ["admitted": false] }
        let deviceIdentifier = String(id.dropFirst(Self.pendingPrefix.count))
        state.requests[id] = nil
        state.admitted[product.productAccountId, default: []].append(deviceIdentifier)
        state.deviceKeys["synthetic-device-" + deviceIdentifier] = authorized
        return ["admitted": true, "trustedDeviceId": "synthetic-device-" + deviceIdentifier]
      }
    }

    static func data(_ value: Any?) -> Data? {
      (value as? String).flatMap { Data(base64Encoded: $0) }
    }
  }

  @MainActor func mockRegistrationStore(
    bundle: String, scenario: String, mailCache: PrivateInboxStore?
  ) throws -> RegistrationStore {
    guard scenario == "registration-enrollment" else { throw RegistrationError.unavailable }
    let keys = DeviceKeychain(service: bundle + ".google-registration")
    let productSync = MockProductSyncBackend(keys: keys)
    // The Google account already exists with keys on a synthetic trusted device.
    try productSync.seedTrustedDevice("synthetic-product-account")
    return RegistrationStore(
      keys: keys,
      deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: MockGoogleRegistrationProvider(),
      productSync: productSync.backend,
      deviceRevoked: { _ in false },
      // The Convex calls TypeScript's registration flow names, answered as Convex would.
      transport: { request in
        func reply(_ value: Any) throws -> (Int, Data) {
          (200, try JSONSerialization.data(withJSONObject: ["status": "success", "value": value]))
        }
        func refusal(_ code: String) throws -> (Int, Data) {
          (
            200,
            try JSONSerialization.data(withJSONObject: [
              "status": "error", "errorData": ["code": code],
            ])
          )
        }
        guard let product = request.product else { return try refusal("UNAVAILABLE") }
        switch request.path {
        case "productAccount:isTrustedDeviceRevoked": return try reply(false)
        // Signing out forgets this device; signing in again makes it wait for admission.
        case "productAccount:unregisterTrustedDevice", "productAccount:unregisterPendingDevice":
          let deviceIdentifier = request.args["deviceIdentifier"] as? String
          try productSync.update { state in
            state.admitted[product.productAccountId]?.removeAll { $0 == deviceIdentifier }
            state.requests[product.trustedDeviceId] = nil
          }
          return try reply(["registered": false])
        case "productSyncEnrollment:request":
          try productSync.requestEnrollment(product, request.args)
          return try reply(["expiresAt": 1_788_400_000_000])
        case "productSyncEnrollment:status":
          return try reply(productSync.enrollmentStatus(product))
        case "productSyncEnrollment:complete":
          return try reply(productSync.completeEnrollment(product, request.args))
        // The synthetic devices in this session never wait for this device's approval.
        case "productSyncEnrollment:listPending": return try reply([Any]())
        case "productSync:getEncryptedPayloadForTrustedDevice":
          guard let identity = request.identity,
            let identifier = request.args["payloadIdentifier"] as? String
          else { return try refusal("UNAVAILABLE") }
          if identifier == "product-account-recovery-v1" {
            guard let envelope = try productSync.state().recovery[product.productAccountId]
            else { return try reply(NSNull()) }
            return try reply([
              "payloadIdentifier": identifier,
              "encryptedPayload": try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(envelope)),
              "updatedAt": 1,
            ])
          }
          let stored = try await productSync.backend.get(identity, product, identifier)
          return try reply(
            stored.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
              ?? NSNull())
        // No other device removes one in this session, so no key rotation reaches this device.
        case "productAccount:getProductSyncKeyRotation", "productAccount:getKeyRotationProposal":
          return try reply(NSNull())
        case "productAccount:listTrustedDevices": return try reply([Any]())
        case "productSync:listEncryptedPayloadsForTrustedDevice":
          guard let identity = request.identity,
            let prefix = request.args["payloadIdentifierPrefix"] as? String
          else { return try refusal("UNAVAILABLE") }
          let records = try await productSync.backend.list(identity, product, prefix)
          return try reply([
            "page": try JSONSerialization.jsonObject(with: JSONEncoder().encode(records)),
            "isDone": true, "continueCursor": "",
          ])
        case "productSync:putEncryptedPayloadIfUnchanged":
          guard let identity = request.identity,
            let identifier = request.args["payloadIdentifier"] as? String,
            let payload = request.args["encryptedPayload"]
          else { return try refusal("UNAVAILABLE") }
          do {
            let stored = try await productSync.backend.put(
              identity, product, identifier,
              JSONDecoder().decode(
                EncryptedPayload.self, from: JSONSerialization.data(withJSONObject: payload)),
              request.args["expectedUpdatedAt"] as? Double)
            return try reply(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)))
          } catch let failure as ProductSyncWriteFailure {
            return try refusal(failure.rawValue)
          }
        default: return try refusal("UNAVAILABLE")
        }
      },
      mailCache: mailCache,
      connect: { identity, deviceIdentifier, _ in
        guard identity.subject == "synthetic-product-subject" else {
          throw RegistrationError.invalidIdentity
        }
        let account = "synthetic-product-account"
        let device = try productSync.connect(account, deviceIdentifier: deviceIdentifier)
        return ProductRegistrationReceipt(
          productAccountId: account, trustedDeviceId: device.id,
          trustedDeviceCredential: String(repeating: "a", count: 64),
          pending: device.pending ? true : nil, signInProviders: [identity.provider],
          productSyncMaterialInitialized: try productSync.initialized(account))
      })
  }
#endif
