#if UNWIRED_REGISTRATION_MOCK
  import Foundation
  import React

  // Compiled only for an externally selected registration Mock Mail Session. The real vault asks
  // JavaScript at each provider and backend seam, and the synthetic TypeScript layers answer as
  // Google, Apple, Microsoft and Convex would. Native keeps its Keychain, keys and Inbox store.
  @objc(UnwiredSyntheticRegistration)
  final class UnwiredSyntheticRegistration: RCTEventEmitter {
    @MainActor private static var listener: UnwiredSyntheticRegistration?
    @MainActor private static var waiting: [String: CheckedContinuation<Any, any Error>] = [:]
    // Requests asked before JavaScript listens.
    @MainActor private static var queued: [[String: Any]] = []

    override static func requiresMainQueueSetup() -> Bool { true }
    override func supportedEvents() -> [String]! { ["request"] }
    override func constantsToExport() -> [AnyHashable: Any]! {
      ["scenario": Bundle.main.object(forInfoDictionaryKey: "UnwiredMockScenario") as? String ?? ""]
    }
    override func startObserving() {
      Task { @MainActor in
        Self.listener = self
        Self.flush()
      }
    }
    override func stopObserving() {
      Task { @MainActor in if Self.listener === self { Self.listener = nil } }
    }

    // One synthetic provider or backend answer: the JSON value JavaScript replied with.
    @MainActor static func ask(_ operation: String, _ payload: [String: Any]) async throws -> Any {
      try await withCheckedThrowingContinuation { answer in
        let id = UUID().uuidString
        waiting[id] = answer
        queued.append(["id": id, "operation": operation, "payload": payload])
        flush()
      }
    }
    @MainActor private static func flush() {
      guard let listener else { return }
      for request in queued { listener.sendEvent(withName: "request", body: request) }
      queued = []
    }

    @objc(answer:reply:) func answer(_ id: String, reply: String) {
      Task { @MainActor in
        Self.waiting.removeValue(forKey: id)?.resume(
          with: Result {
            try JSONSerialization.jsonObject(with: Data(reply.utf8), options: .fragmentsAllowed)
          })
      }
    }
    @objc(refuse:code:) func refuse(_ id: String, code: String) {
      Task { @MainActor in Self.waiting.removeValue(forKey: id)?.resume(throwing: Self.error(code)) }
    }

    // The synthetic backend's state, in the run's Keychain namespace so relaunches keep it.
    private static var keys: DeviceKeychain? {
      Bundle.main.bundleIdentifier.map { DeviceKeychain(service: $0 + ".google-registration") }
    }
    @objc(readState:rejecter:) func readState(
      _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
    ) {
      do {
        let state = try Self.keys?.read("synthetic-registration")
        resolve(state.flatMap { String(data: $0, encoding: .utf8) } ?? NSNull())
      } catch {
        reject("unavailable", "The synthetic state is unavailable.", nil)
      }
    }
    @objc(saveState:resolver:rejecter:) func saveState(
      _ state: String, resolve: @escaping RCTPromiseResolveBlock,
      reject: @escaping RCTPromiseRejectBlock
    ) {
      do {
        guard let keys = Self.keys else { throw RegistrationError.unavailable }
        try keys.save(Data(state.utf8), account: "synthetic-registration")
        resolve(NSNull())
      } catch {
        reject("unavailable", "The synthetic state is unavailable.", nil)
      }
    }

    // The refusal a synthetic answer names, as the real provider or backend would raise it.
    static func error(_ code: String) -> any Error {
      switch code {
      case "cancelled": RegistrationError.cancelled
      case "gmail-unavailable": RegistrationError.gmailUnavailable
      case "invalid-identity": RegistrationError.invalidIdentity
      case "revoked": RegistrationError.revoked
      case "deleted": RegistrationError.deleted
      case ProductSyncWriteFailure.keyRotationRequired.rawValue:
        ProductSyncWriteFailure.keyRotationRequired
      case ProductSyncWriteFailure.payloadChanged.rawValue: ProductSyncWriteFailure.payloadChanged
      default: RegistrationError.unavailable
      }
    }
  }

  // A synthetic answer's fields; anything malformed is unavailable.
  @MainActor private func ask(_ operation: String, _ payload: [String: Any] = [:]) async throws
    -> [String: Any]
  {
    guard let reply = try await UnwiredSyntheticRegistration.ask(operation, payload) as? [String: Any]
    else { throw RegistrationError.unavailable }
    return reply
  }
  private func string(_ reply: [String: Any], _ key: String) throws -> String {
    guard let value = reply[key] as? String else { throw RegistrationError.unavailable }
    return value
  }
  private func json(_ value: some Encodable) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
  }
  private func decode<Value: Decodable>(_ type: Value.Type, _ value: Any) throws -> Value {
    try JSONDecoder().decode(
      type, from: JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
  }
  // An HTTP exchange's reply: its status and text body. HTTP failures are returned, not thrown.
  @MainActor private func exchange(_ operation: String, _ payload: [String: Any]) async throws
    -> (Int, Data)
  {
    let reply = try await ask(operation, payload)
    guard let status = reply["status"] as? Int else { throw RegistrationError.unavailable }
    return (status, Data(try string(reply, "body").utf8))
  }
  private func text(_ body: Data?) -> Any { body.flatMap { String(data: $0, encoding: .utf8) } ?? NSNull() }

  @MainActor final class SyntheticGoogleProvider: GoogleRegistrationProvider {
    private func identity(_ reply: [String: Any]) throws -> GoogleRegistrationIdentity {
      let subject = try string(reply, "subject")
      return GoogleRegistrationIdentity(
        subject: subject, credential: Data(subject.utf8), idToken: try string(reply, "idToken"),
        accessToken: try string(reply, "accessToken"),
        scopes: Set(reply["scopes"] as? [String] ?? []))
    }
    func signIn(mail: Bool, hint: String?) async throws -> GoogleRegistrationIdentity {
      try identity(await ask("google.signIn", ["mail": mail, "hint": hint ?? NSNull()]))
    }
    func refresh(_ credential: Data) async throws -> GoogleRegistrationIdentity {
      try identity(await ask("google.refresh", ["subject": text(credential)]))
    }
    func verifyGmail(_ identity: GoogleRegistrationIdentity) async throws
      -> GmailRegistrationReceipt
    {
      try decode(
        GmailRegistrationReceipt.self, await ask("google.verify", ["subject": identity.subject]))
    }
    func gmail(
      _ identity: GoogleRegistrationIdentity, url: URL, body: Data?, contentType: String
    ) async throws -> (Int, Data) {
      try await exchange(
        "google.gmail",
        [
          "subject": identity.subject, "url": url.absoluteString, "body": text(body),
          "contentType": contentType,
        ])
    }
  }

  @MainActor final class SyntheticAppleProvider: AppleRegistrationProvider {
    func signIn() async throws -> AppleRegistrationIdentity {
      let reply = try await ask("apple.signIn")
      return AppleRegistrationIdentity(
        subject: try string(reply, "subject"), idToken: try string(reply, "idToken"),
        email: reply["email"] as? String)
    }
    func credentialState(_ subject: String) async -> AppleCredentialState {
      let reply = try? await ask("apple.credentialState", ["subject": subject])
      return switch reply?["state"] as? String {
      case "authorized": .authorized
      case "revoked": .revoked
      default: .unavailable
      }
    }
  }

  @MainActor final class SyntheticMicrosoftProvider: MicrosoftMailProvider {
    private func identity(_ reply: [String: Any]) throws -> MicrosoftMailIdentity {
      MicrosoftMailIdentity(
        credential: Data(try string(reply, "credential").utf8),
        accessToken: try string(reply, "accessToken"),
        scopes: Set(reply["scopes"] as? [String] ?? []))
    }
    func signIn(hint: String?) async throws -> MicrosoftMailIdentity {
      try identity(await ask("microsoft.signIn", ["hint": hint ?? NSNull()]))
    }
    func refresh(_ credential: Data) async throws -> MicrosoftMailIdentity {
      try identity(await ask("microsoft.refresh", ["credential": text(credential)]))
    }
    func verify(_ identity: MicrosoftMailIdentity) async throws -> GmailRegistrationReceipt {
      try decode(GmailRegistrationReceipt.self, await ask("microsoft.verify"))
    }
    func graph(
      _ identity: MicrosoftMailIdentity, url: URL, method: String, body: Data?,
      contentType: String
    ) async throws -> (Int, Data) {
      try await exchange(
        "microsoft.graph",
        [
          "url": url.absoluteString, "method": method, "body": text(body),
          "contentType": contentType,
        ])
    }
  }

  // The fields of a backend call the synthetic backend reads; tokens and credentials stay here.
  private func caller(_ identity: ProductSignInIdentity?, _ product: ProductRegistrationReceipt?)
    throws -> [String: Any]
  {
    [
      "identity": identity.map { ["provider": $0.provider.rawValue, "subject": $0.subject] }
        ?? NSNull(),
      "product": try product.map(json) ?? NSNull(),
    ]
  }

  @MainActor func syntheticRegistrationStore(mailCache: PrivateInboxStore?) throws
    -> RegistrationStore
  {
    guard let bundle = Bundle.main.bundleIdentifier else { throw RegistrationError.unavailable }
    func stored(_ reply: [String: Any]) throws -> StoredPayload? {
      try (reply["stored"]).flatMap { $0 is NSNull ? nil : try decode(StoredPayload.self, $0) }
    }
    return RegistrationStore(
      keys: DeviceKeychain(service: bundle + ".google-registration"),
      deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: SyntheticGoogleProvider(), apple: SyntheticAppleProvider(),
      microsoft: SyntheticMicrosoftProvider(),
      productSync: ProductSyncBackend(
        list: { identity, product, prefix in
          let reply = try await ask(
            "productSync.list", try caller(identity, product).merging(["prefix": prefix]) { $1 })
          return try decode([StoredPayload].self, reply["records"] ?? [])
        },
        put: { identity, product, identifier, payload, expected in
          let reply = try await ask(
            "productSync.put",
            try caller(identity, product).merging([
              "identifier": identifier, "payload": try json(payload),
              "expectedUpdatedAt": expected ?? NSNull(),
            ]) { $1 })
          guard let stored = try stored(reply) else { throw RegistrationError.unavailable }
          return stored
        },
        get: { identity, product, identifier in
          try stored(
            await ask(
              "productSync.get",
              try caller(identity, product).merging(["identifier": identifier]) { $1 }))
        },
        claimDelivery: { identity, product, identifier in
          try await ask(
            "productSync.claimDelivery",
            try caller(identity, product).merging(["identifier": identifier]) { $1 })["claimed"]
            as? Bool ?? false
        }),
      deviceRevoked: { product in
        try await ask("convex.deviceRevoked", try caller(nil, product))["revoked"] as? Bool ?? false
      },
      transport: { request in
        try await exchange(
          "convex.call",
          try caller(request.identity, request.product).merging([
            "endpoint": request.endpoint.rawValue, "path": request.path, "args": request.args,
          ]) { $1 })
      },
      mailCache: mailCache,
      connect: { identity, deviceIdentifier, _ in
        try decode(
          ProductRegistrationReceipt.self,
          await ask(
            "convex.connect",
            try caller(identity, nil).merging(["deviceIdentifier": deviceIdentifier]) { $1 }))
      })
  }
#endif
