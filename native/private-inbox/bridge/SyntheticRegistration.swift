#if UNWIRED_REGISTRATION_MOCK
  import CryptoKit
  import Foundation

  // Compiled only for an externally selected, fixed Mock Mail Session.
  @MainActor final class MockGoogleRegistrationProvider: GoogleRegistrationProvider {
    let scenario: String
    private let messages: [String: [String: Any]]
    init(scenario: String, messages: [String: [String: Any]]? = nil) {
      self.scenario = scenario
      self.messages = messages ?? Self.syntheticMessages
    }

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

    // A synthetic Gmail mailbox: three Inbox messages over two list pages and one label. Label
    // changes from this launch apply; history reports no other changes.
    // A message may declare a "disposition", served as its Content-Disposition header.
    static let syntheticMessages: [String: [String: Any]] = [
      "19a0c0ffee000001": [
        "from": "Rowan Hale <rowan@example.invalid>", "subject": "Garden plans for spring",
        "snippet": "The seed order arrived. Shall we plan the beds this weekend?",
        "internalDate": "1759219200000", "labelIds": ["INBOX", "UNREAD"],
        "html":
          "<p>The seed order arrived. Shall we plan the beds this weekend?</p>"
          + "<p>Planting notes: <a href=\"https://example.invalid/garden\">garden plan</a></p>"
          + "<img src=\"https://example.invalid/pixel.gif\" alt=\"\">",
      ],
      "19a0c0ffee000002": [
        "from": "\"Ada Brook\" <ada@example.invalid>", "subject": "Notes from Tuesday",
        "snippet": "Thanks for the thoughtful questions &amp; the follow-up.",
        "internalDate": "1759132800000", "labelIds": ["INBOX"],
        "text": "Thanks for the thoughtful questions & the follow-up.\n\nAda",
      ],
      "19a0c0ffee000003": [
        "from": "test@example.invalid", "subject": "Welcome to your synthetic Inbox",
        "snippet": "Nothing here came from a real mailbox.",
        "internalDate": "1759046400000", "labelIds": ["INBOX", "CATEGORY_UPDATES"],
        "text": "Nothing here came from a real mailbox.",
      ],
    ]

    // Label changes from this launch, over the messages' initial labels.
    lazy var syntheticLabels = messages.mapValues { $0["labelIds"] as? [String] ?? [] }

    // A synthetic message's MIME headers, as its single part declares them.
    static func mimeHeaders(_ message: [String: Any], mimeType: String) -> [[String: String]] {
      [["name": "Content-Type", "value": mimeType + "; charset=UTF-8"]]
        + ((message["disposition"] as? String).map {
          [["name": "Content-Disposition", "value": $0]]
        } ?? [])
    }

    func gmail(
      _ identity: GoogleRegistrationIdentity, url: URL, body request: Data?, contentType: String
    ) async throws -> (Int, Data) {
      guard identity.subject == "synthetic-alternate-mailbox" else { return (401, Data()) }
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
      // Gmail repeats metadataHeaders once per requested header, in any order and case.
      let requested = Set(
        items.filter { $0.name == "metadataHeaders" }.compactMap { $0.value?.lowercased() })
      let body: Any
      switch url.lastPathComponent {
      case "profile": body = ["emailAddress": "other@example.invalid", "historyId": "100"]
      // Synthetic Gmail accepts every message and keeps nothing of it.
      case "send": body = ["id": "19a0c0ffee0000ff", "threadId": "19a0c0ffee0000ff"]
      case "history": body = ["historyId": "100"]
      case "labels":
        body = ["labels": [["id": "Label_1", "name": "Travel", "type": "user"]]]
      case "modify":
        let id = url.deletingLastPathComponent().lastPathComponent
        guard let labels = syntheticLabels[id], let request,
          let change = try JSONSerialization.jsonObject(with: request) as? [String: [String]]
        else { return (404, Data()) }
        let remaining = labels.filter { !(change["removeLabelIds"] ?? []).contains($0) }
        syntheticLabels[id] =
          remaining + (change["addLabelIds"] ?? []).filter { !remaining.contains($0) }
        body = ["id": id, "threadId": id, "labelIds": syntheticLabels[id] ?? []]
      case "messages" where query["pageToken"] == "2":
        body = ["messages": [["id": "19a0c0ffee000003", "threadId": "19a0c0ffee000003"]]]
      case "messages":
        body = [
          "messages": ["19a0c0ffee000001", "19a0c0ffee000002"].map { ["id": $0, "threadId": $0] },
          "nextPageToken": "2",
        ]
      // The body-free preflight prefetch makes: each synthetic message is one part, and only the
      // requested admission headers are returned.
      case let id
      where query["format"] == "metadata"
        && !requested.isDisjoint(with: ["content-type", "content-disposition"]):
        guard let message = messages[id] else { return (404, Data()) }
        let mimeType = message["html"] == nil ? "text/plain" : "text/html"
        body = [
          "id": id, "threadId": id, "labelIds": syntheticLabels[id] ?? [],
          "payload": [
            "mimeType": mimeType,
            "headers": Self.mimeHeaders(message, mimeType: mimeType).filter {
              requested.contains(($0["name"] ?? "").lowercased())
            },
          ],
        ]
      case let id where query["format"] == "full":
        guard let message = messages[id] else { return (404, Data()) }
        let html = message["html"] as? String
        let content = html ?? message["text"] as? String ?? ""
        let data = Data(content.utf8).base64EncodedString()
          .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let mimeType = html == nil ? "text/plain" : "text/html"
        body = [
          "id": id, "threadId": id, "labelIds": syntheticLabels[id] ?? [],
          "payload": [
            "mimeType": mimeType,
            "headers": Self.mimeHeaders(message, mimeType: mimeType),
            "body": ["size": content.utf8.count, "data": data],
          ],
        ]
      case let id:
        guard let message = messages[id] else { return (404, Data()) }
        body = [
          "id": id, "threadId": id, "labelIds": syntheticLabels[id] ?? [],
          "snippet": message["snippet"] ?? "", "historyId": "100",
          "internalDate": message["internalDate"] ?? "",
          "payload": [
            "headers": [
              ["name": "From", "value": message["from"] ?? ""],
              ["name": "Subject", "value": message["subject"] ?? ""],
            ]
          ],
        ]
      }
      return (200, try JSONSerialization.data(withJSONObject: body))
    }
  }

  @MainActor final class MockAppleRegistrationProvider: AppleRegistrationProvider {
    func signIn() async throws -> AppleRegistrationIdentity {
      AppleRegistrationIdentity(
        subject: "synthetic-apple-subject", idToken: "synthetic-apple-identity",
        email: "relay@privaterelay.example.invalid")
    }
    func credentialState(_ subject: String) async -> AppleCredentialState {
      subject == "synthetic-apple-subject" ? .authorized : .revoked
    }
  }

  // A synthetic Microsoft mailbox read through Graph: one Inbox message, a delta round that
  // finds no later changes, and its text body.
  @MainActor final class MockMicrosoftMailProvider: MicrosoftMailProvider {
    static let message = "AAMkAGI2-synthetic-outlook="
    private let identity = MicrosoftMailIdentity(
      credential: Data("synthetic-microsoft".utf8), accessToken: "synthetic-graph-access",
      scopes: ["Mail.Read", "User.Read", "offline_access"])

    func signIn(hint: String?) async throws -> MicrosoftMailIdentity { identity }
    func refresh(_ credential: Data) async throws -> MicrosoftMailIdentity { identity }
    func verify(_ identity: MicrosoftMailIdentity) async throws -> GmailRegistrationReceipt {
      GmailRegistrationReceipt(
        subject: "synthetic-microsoft-account", address: "casey@example.invalid",
        provider: .microsoftGraph)
    }
    func graph(_ identity: MicrosoftMailIdentity, url: URL) async throws -> (Int, Data) {
      let delta = "https://graph.microsoft.com/v1.0/me/mailFolders('inbox')/messages/delta"
      let listed: [String: Any] = [
        "id": Self.message, "conversationId": "synthetic-outlook-conversation",
        "receivedDateTime": "2025-10-01T09:00:00Z", "subject": "Quarterly planning",
        "bodyPreview": "Agenda for Thursday.", "isRead": false,
        "from": ["emailAddress": ["name": "Jordan Lee", "address": "jordan@example.invalid"]],
      ]
      let body: [String: Any]
      if url.path.hasSuffix("/attachments") {
        body = ["value": []]
      } else if url.path.hasPrefix("/v1.0/me/messages/") {
        body = [
          "id": Self.message, "hasAttachments": false,
          "body": ["contentType": "text", "content": "Agenda for Thursday.\n\nJordan"],
          "from": listed["from"] ?? [:],
          "toRecipients": [["emailAddress": ["address": "casey@example.invalid"]]],
        ]
      } else if url.path.hasSuffix("/delta") {
        let first = url.query?.contains("deltatoken") != true
        body = ["value": first ? [listed] : [], "@odata.deltaLink": delta + "?$deltatoken=1"]
      } else {
        body = ["value": [listed]]
      }
      return (200, try JSONSerialization.data(withJSONObject: body))
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
      // The Recovery Key verifier published with each account's recovery envelope.
      var verifiers: [String: String] = [:]
      var records: [String: [String: StoredPayload]] = [:]
      // Delivery claims this device holds, by account; no other device claims in mock sessions.
      var claims: [String: Set<String>]?
      // Open enrollment requests by Pending Device id.
      var requests: [String: Request] = [:]
      // Pending Devices whose Recovery Key proof matched, with the encryption key it named.
      var recovered: [String: Data] = [:]
      // Device identifiers each account admitted: the one that created its keys, then others.
      var admitted: [String: [String]] = [:]
      // Keys held by the synthetic trusted device of an account that existed before this run.
      var trusted: [String: ProductSyncKeyRing] = [:]
      // Each account's key epoch, once a removal moved it past the first.
      var epochs: [String: Int] = [:]
      // Bound encryption keys and each device's latest key ring envelope, by Trusted Device id.
      var deviceKeys: [String: Data] = [:]
      var envelopes: [String: KeyRingEnvelope.Rotation] = [:]
      // Activated removal proposals with their epochs, and the one whose Recovery Key is current.
      var proposals: [String: Int] = [:]
      var recoveryProposal: [String: String] = [:]
      var removed: Set<String> = []
      // This device's identifiers another device removed; they stay refused.
      var removedIdentifiers: Set<String> = []
      // Product Accounts this device deleted; their sign-ins are refused afterwards.
      var deleted: Set<String> = []
      // The launch that first connected; a later launch learns of this device's removal.
      var connectedLaunch: String?
    }
    // The other device of the `registration-revocation` account, which this device removes, with
    // a fixed encryption key that only the synthetic iPad would hold.
    static let iPadId = "synthetic-ipad"
    static let iPadKey = try? Curve25519.KeyAgreement.PrivateKey(
      rawRepresentation: Data(repeating: 7, count: 32)
    ).publicKey.rawRepresentation
    // The synthetic account's Recovery Key, typed by the `registration-recovery` journey.
    static let recoveryKey = "000G-40R4-0M30-E209-185G-R38E-1W81-24GK-2GAH-C5RR-34D1-P70X-3RFG"
    static let pendingPrefix = "synthetic-pending-"
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
        let key = try RecoveryKey(parsing: Self.recoveryKey)
        state.trusted[account] = ring
        state.admitted[account] = ["synthetic-trusted-installation"]
        state.recovery[account] = try KeyRingEnvelope.recovery(ring, key: key, account: account)
        state.verifiers[account] = KeyRingEnvelope.recoveryVerifier(key, account: account)
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
        if state.removedIdentifiers.contains(deviceIdentifier) { throw RegistrationError.revoked }
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
      guard approves, var request = state.requests[id], request.approved == nil,
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

    // Convex's initialization: the first recovery envelope becomes the account's key material.
    func initialize(
      _ product: ProductRegistrationReceipt, envelope: EncryptedPayload, verifier: String,
      deviceKey: Data
    ) throws -> Bool {
      try update { state in
        if let existing = state.recovery[product.productAccountId] {
          return existing == envelope
        }
        state.recovery[product.productAccountId] = envelope
        state.verifiers[product.productAccountId] = verifier
        state.deviceKeys[product.trustedDeviceId] = deviceKey
        return true
      }
    }

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
            guard payload.keyVersion == state.epochs[product.productAccountId] ?? 1 else {
              throw ProductSyncWriteFailure.keyRotationRequired
            }
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
        state.recovered[product.trustedDeviceId] = nil
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

    // Admits a Pending Device that a Trusted Device approved or whose Recovery Key matched.
    func completeEnrollment(_ product: ProductRegistrationReceipt, _ args: [String: Any]) throws
      -> [String: Any]
    {
      try update { state in
        let id = product.trustedDeviceId
        let epoch = state.epochs[product.productAccountId] ?? 1
        // Only the encryption key the approval or Recovery Key proof named is admitted.
        let authorized =
          state.recovered[id]
          ?? state.requests[id].flatMap { $0.approved == nil ? nil : $0.deviceKey }
        guard args["keyVersion"] as? Int == epoch, product.pending == true,
          id.hasPrefix(Self.pendingPrefix),
          authorized == Self.data(args["deviceEncryptionPublicKey"])
        else { return ["admitted": false] }
        let deviceIdentifier = String(id.dropFirst(Self.pendingPrefix.count))
        state.requests[id] = nil
        state.recovered[id] = nil
        state.admitted[product.productAccountId, default: []].append(deviceIdentifier)
        state.deviceKeys["synthetic-device-" + deviceIdentifier] = authorized
        return ["admitted": true, "trustedDeviceId": "synthetic-device-" + deviceIdentifier]
      }
    }

    func provesRecoveryKey(_ proof: Any?, _ account: String, _ state: State) -> Bool {
      guard let proof = proof as? String else { return false }
      return SHA256.hash(data: Data(proof.utf8)).map({ String(format: "%02x", $0) }).joined()
        == state.verifiers[account]
    }

    // The current Recovery Key binds a key once; a different one is never replaced.
    func bindDeviceKey(_ product: ProductRegistrationReceipt, _ args: [String: Any]) throws -> Bool
    {
      try update { state in
        guard provesRecoveryKey(args["recoveryProof"], product.productAccountId, state),
          let deviceKey = Self.data(args["deviceEncryptionPublicKey"])
        else { return false }
        let bound = state.deviceKeys[product.trustedDeviceId]
        guard bound == nil || bound == deviceKey else { throw RegistrationError.unavailable }
        state.deviceKeys[product.trustedDeviceId] = deviceKey
        return true
      }
    }

    func recoverPending(_ product: ProductRegistrationReceipt, _ args: [String: Any]) throws
      -> EncryptedPayload?
    {
      try update { state in
        let account = product.productAccountId
        guard product.pending == true,
          provesRecoveryKey(args["recoveryProof"], account, state),
          let deviceKey = Self.data(args["deviceEncryptionPublicKey"]),
          let envelope = state.recovery[account]
        else { return nil }
        state.recovered[product.trustedDeviceId] = deviceKey
        return envelope
      }
    }

    // This device and, until it is removed, the iPad; other sessions remove nothing.
    func trustedDevices(_ product: ProductRegistrationReceipt) throws -> [[String: Any]] {
      let state = try state()
      guard removable, !state.removed.contains(Self.iPadId) else { return [] }
      func summary(_ id: String, _ name: String, _ registeredAt: Double, _ key: Data?)
        -> [String: Any]
      {
        var device: [String: Any] = [
          "id": id, "displayName": name, "registeredAt": registeredAt,
          "lastSeenAt": registeredAt, "platform": "ios",
        ]
        if let key { device["deviceEncryptionPublicKey"] = key.base64EncodedString() }
        return device
      }
      return [
        summary(
          product.trustedDeviceId, "This device", 1_788_307_200_000,
          state.deviceKeys[product.trustedDeviceId]),
        summary(Self.iPadId, "iPad", 1_788_220_800_000, Self.iPadKey),
      ]
    }

    // What a removal sends besides this device's credentials.
    struct Activation: Decodable {
      struct Envelope: Decodable {
        let trustedDeviceId: String
        let deviceEncryptionPublicKey: String
        let encapsulatedKeyBase64: String
        let ciphertextBase64: String
      }
      let trustedDeviceToRevokeId: String
      let proposalId: String
      let expectedKeyEpoch: Int
      let keyEnvelopes: [Envelope]
      let recoveryWrappedAccountKey: EncryptedPayload
      let recoveryVerifier: String
    }

    // Activates removing the iPad when the proposal still matches the account, once, answering as
    // the HTTP route does: its new epoch, or a refusal's status and code.
    func activate(_ product: ProductRegistrationReceipt, _ args: [String: Any]) throws -> (
      Int, [String: Any]
    ) {
      guard
        let request = try? JSONDecoder().decode(
          Activation.self, from: JSONSerialization.data(withJSONObject: args))
      else { return (400, ["code": "KEY_ROTATION_INVALID"]) }
      return try update { state in
        let account = product.productAccountId
        if let epoch = state.proposals[request.proposalId] { return (200, ["keyEpoch": epoch]) }
        guard removable, request.trustedDeviceToRevokeId == Self.iPadId else {
          return (404, ["code": "KEY_ROTATION_INVALID"])
        }
        if state.removed.contains(Self.iPadId) {
          return (409, ["code": "TRUSTED_DEVICE_ALREADY_REMOVED"])
        }
        let epoch = state.epochs[account] ?? 1
        guard request.expectedKeyEpoch == epoch,
          request.keyEnvelopes.map(\.trustedDeviceId) == [product.trustedDeviceId],
          request.keyEnvelopes.first.flatMap({ Data(base64Encoded: $0.deviceEncryptionPublicKey) })
            == state.deviceKeys[product.trustedDeviceId],
          let envelope = request.keyEnvelopes.first,
          let encapsulatedKey = Data(base64Encoded: envelope.encapsulatedKeyBase64),
          let ciphertext = Data(base64Encoded: envelope.ciphertextBase64)
        else { return (409, ["code": "KEY_ROTATION_CONFLICT"]) }
        guard request.recoveryWrappedAccountKey.keyVersion == epoch + 1,
          request.recoveryWrappedAccountKey.schemaVersion
            == KeyRingEnvelope.recoverySchemaVersion
        else { return (400, ["code": "KEY_ROTATION_INVALID"]) }
        state.removed.insert(Self.iPadId)
        state.epochs[account] = epoch + 1
        state.envelopes[product.trustedDeviceId] = KeyRingEnvelope.Rotation(
          keyEpoch: epoch + 1, encapsulatedKey: encapsulatedKey, ciphertext: ciphertext)
        state.recovery[account] = request.recoveryWrappedAccountKey
        state.verifiers[account] = request.recoveryVerifier
        state.proposals[request.proposalId] = epoch + 1
        state.recoveryProposal[account] = request.proposalId
        return (200, ["keyEpoch": epoch + 1])
      }
    }

    static func data(_ value: Any?) -> Data? {
      (value as? String).flatMap { Data(base64Encoded: $0) }
    }
  }

  @MainActor func mockRegistrationStore(
    bundle: String, scenario: String, mailCache: PrivateInboxStore?
  ) throws -> RegistrationStore {
    guard
      [
        "registration-cancelled", "registration-declined", "registration-no-gmail",
        "registration-interrupted", "registration-apple", "registration-link",
        "registration-enrollment", "registration-recovery", "registration-revocation",
        "registration-revoked", "registration-removal", "registration-draft-editor",
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
    // Another device's removal of this one is recorded by its bare device identifier.
    let revoked = { (product: ProductRegistrationReceipt) throws -> Bool in
      let prefix = "synthetic-device-"
      guard product.trustedDeviceId.hasPrefix(prefix) else { return false }
      return try productSync.state().removedIdentifiers.contains(
        String(product.trustedDeviceId.dropFirst(prefix.count)))
    }
    return RegistrationStore(
      keys: keys,
      deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, apple: MockAppleRegistrationProvider(),
      microsoft: MockMicrosoftMailProvider(),
      productSync: productSync.backend,
      // Gmail writes require a current Trusted Device proof, answered from the synthetic backend's
      // removals so the packaged journeys reach the synthetic Gmail mailbox.
      deviceRevoked: { try revoked($0) },
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
        case "productAccount:isTrustedDeviceRevoked": return try reply(revoked(product))
        case "/sign-in-links/request":
          guard let identity = request.identity, accounts[identity.subject] == product.productAccountId
          else { return try refusal("SIGN_IN_NOT_LINKED") }
          return try reply([
            "linkTicket": String(repeating: "b", count: 64),
            "signInProviders": (product.signInProviders ?? [identity.provider]).map(\.rawValue),
          ])
        case "/sign-in-links/complete":
          guard scenario == "registration-link", let identity = request.identity else {
            return try refusal("SIGN_IN_IDENTITY_OWNED")
          }
          return try reply([
            "productAccountId": product.productAccountId,
            "signInProviders": ((product.signInProviders ?? []) + [identity.provider]).map(
              \.rawValue),
          ])
        // Signing out forgets this device; signing in again makes it wait for admission.
        case "productAccount:unregisterTrustedDevice", "productAccount:unregisterPendingDevice":
          let deviceIdentifier = request.args["deviceIdentifier"] as? String
          try productSync.update { state in
            state.admitted[product.productAccountId]?.removeAll { $0 == deviceIdentifier }
            state.requests[product.trustedDeviceId] = nil
          }
          return try reply(["registered": false])
        // Enrollment, recovery, key rotation and removal, which TypeScript sequences.
        case "productSyncEnrollment:request":
          try productSync.requestEnrollment(product, request.args)
          return try reply(["expiresAt": 1_788_400_000_000])
        case "productSyncEnrollment:status":
          return try reply(productSync.enrollmentStatus(product))
        case "productSyncEnrollment:complete":
          return try reply(productSync.completeEnrollment(product, request.args))
        case "productSyncEnrollment:recover":
          let envelope = try productSync.recoverPending(product, request.args)
          return try reply(
            envelope.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
              ?? NSNull())
        // The synthetic devices in this session never wait for this device's approval.
        case "productSyncEnrollment:listPending": return try reply([Any]())
        case "productSync:bindDeviceEncryptionKey":
          return try reply(["bound": productSync.bindDeviceKey(product, request.args)])
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
        case "productAccount:getProductSyncKeyRotation":
          guard let rotation = try productSync.state().envelopes[product.trustedDeviceId] else {
            return try reply(NSNull())
          }
          return try reply([
            "keyEpoch": rotation.keyEpoch,
            "encapsulatedKeyBase64": rotation.encapsulatedKey.base64EncodedString(),
            "ciphertextBase64": rotation.ciphertext.base64EncodedString(),
          ])
        case "productAccount:acknowledgeProductSyncKeyRotation":
          return try reply(["keyEpoch": request.args["keyEpoch"] ?? 1])
        case "productAccount:listTrustedDevices":
          return try reply(productSync.trustedDevices(product))
        case "productAccount:getKeyRotationProposal":
          let state = try productSync.state()
          guard let proposalId = request.args["proposalId"] as? String,
            let epoch = state.proposals[proposalId]
          else { return try reply(NSNull()) }
          return try reply([
            "keyEpoch": epoch,
            "recoveryKeyCurrent": state.recoveryProposal[product.productAccountId] == proposalId,
          ])
        case "/trusted-devices/revoke":
          let (status, body) = try productSync.activate(product, request.args)
          return (status, try JSONSerialization.data(withJSONObject: body))
        // Product Sync's initialization and mailbox descriptors, which TypeScript sequences.
        case "productSync:initialize":
          guard let payload = request.args["encryptedPayload"],
            let verifier = request.args["recoveryVerifier"] as? String,
            let deviceKey = (request.args["deviceEncryptionPublicKey"] as? String)
              .flatMap({ Data(base64Encoded: $0) })
          else { return try refusal("UNAVAILABLE") }
          return try reply([
            "initialized": try productSync.initialize(
              product,
              envelope: JSONDecoder().decode(
                EncryptedPayload.self, from: JSONSerialization.data(withJSONObject: payload)),
              verifier: verifier, deviceKey: deviceKey)
          ])
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
        case "/product-account/delete":
          _ = try productSync.update { $0.deleted.insert(product.productAccountId) }
          return (200, Data(#"{"deleted":true}"#.utf8))
        default: return try refusal("UNAVAILABLE")
        }
      },
      mailCache: mailCache,
      connect: { identity, deviceIdentifier, _ in
        guard let account = accounts[identity.subject] else {
          throw RegistrationError.invalidIdentity
        }
        if try productSync.state().deleted.contains(account) {
          throw RegistrationError.deleted
        }
        // Another device removes this one after its first sign-in; the relaunch learns of it. Its
        // identifier stays refused, and a new sign-in waits like any other new device.
        let earlier = try productSync.update { state in
          defer { state.connectedLaunch = state.connectedLaunch ?? launch }
          return state.connectedLaunch.map { $0 != launch } ?? false
        }
        if scenario == "registration-revoked", earlier {
          try productSync.update { state in
            if state.admitted[account]?.contains(deviceIdentifier) == true {
              state.admitted[account]?.removeAll { $0 == deviceIdentifier }
              state.removedIdentifiers.insert(deviceIdentifier)
            }
          }
        }
        let device = try productSync.connect(account, deviceIdentifier: deviceIdentifier)
        return ProductRegistrationReceipt(
          productAccountId: account, trustedDeviceId: device.id,
          trustedDeviceCredential: String(repeating: "a", count: 64),
          pending: device.pending ? true : nil, signInProviders: [identity.provider],
          productSyncMaterialInitialized: try productSync.initialized(account))
      })
  }
#endif
