import CryptoKit
import Foundation
import GoogleSignIn
import React
import os

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

@MainActor final class NativeGoogleRegistrationProvider: GoogleRegistrationProvider {
  let clientID: String
  private let mailSession = URLSession(configuration: .ephemeral)
  init(clientID: String) { self.clientID = clientID }

  func identity(_ user: GIDGoogleUser, nonce: String? = nil) throws -> GoogleRegistrationIdentity {
    guard let subject = user.userID, let token = user.idToken?.tokenString else {
      throw RegistrationError.invalidIdentity
    }
    try IdentityTokenClaims.validate(
      token, issuers: IdentityTokenClaims.google, audience: clientID, subject: subject, nonce: nonce
    )
    return GoogleRegistrationIdentity(
      subject: subject,
      credential: try NSKeyedArchiver.archivedData(
        withRootObject: user, requiringSecureCoding: true),
      idToken: token, accessToken: user.accessToken.tokenString,
      scopes: Set(user.grantedScopes ?? []))
  }

  func signIn(mail: Bool, hint: String?) async throws -> GoogleRegistrationIdentity {
    GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    let nonce = UUID().uuidString + UUID().uuidString
    let scopes = mail ? [RegistrationStore.gmailScope] : []
    // The SDK's transient cache is cleared after copying into our device-only Keychain.
    defer { GIDSignIn.sharedInstance.signOut() }
    let result: GIDSignInResult
    do {
      #if os(iOS)
        guard
          let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: {
              $0.isKeyWindow
            }),
          var presenter = window.rootViewController
        else { throw RegistrationError.unavailable }
        while let presented = presenter.presentedViewController { presenter = presented }
        result = try await GIDSignIn.sharedInstance.signIn(
          withPresenting: presenter, hint: hint, additionalScopes: scopes, nonce: nonce)
      #else
        guard let window = NSApp.keyWindow else { throw RegistrationError.unavailable }
        result = try await GIDSignIn.sharedInstance.signIn(
          withPresenting: window, hint: hint, additionalScopes: scopes, nonce: nonce)
      #endif
    } catch {
      let failure = error as NSError
      if failure.domain == kGIDSignInErrorDomain
        && failure.code == GIDSignInError.canceled.rawValue
      {
        throw RegistrationError.cancelled
      }
      throw error
    }
    return try identity(result.user, nonce: nonce)
  }

  func refresh(_ credential: Data) async throws -> GoogleRegistrationIdentity {
    guard
      let user = try NSKeyedUnarchiver.unarchivedObject(
        ofClass: GIDGoogleUser.self, from: credential)
    else {
      throw RegistrationError.invalidIdentity
    }
    let refreshed = try await user.refreshTokensIfNeeded()
    return try identity(refreshed)
  }

  func verifyGmail(_ identity: GoogleRegistrationIdentity) async throws -> GmailRegistrationReceipt
  {
    var request = URLRequest(
      url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
    request.setValue("Bearer " + identity.accessToken, forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 30
    struct Profile: Decodable { let emailAddress: String }
    let profile: Profile
    do {
      let (data, response) = try await mailSession.data(for: request)
      guard let response = response as? HTTPURLResponse else {
        throw RegistrationError.gmailUnavailable
      }
      if response.statusCode == 429 || response.statusCode >= 500 {
        throw URLError(.cannotConnectToHost)
      }
      guard response.statusCode == 200 else {
        throw RegistrationError.gmailUnavailable
      }
      profile = try JSONDecoder().decode(Profile.self, from: data)
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch is CancellationError {
      throw CancellationError()
    } catch  where RegistrationStore.transientMailboxFailure(error) {
      throw error
    } catch {
      throw RegistrationError.gmailUnavailable
    }
    return GmailRegistrationReceipt(subject: identity.subject, address: profile.emailAddress)
  }

  func gmail(
    _ identity: GoogleRegistrationIdentity, url: URL, body: Data?, contentType: String
  ) async throws -> (Int, Data) {
    try await GmailTransport.send(
      token: identity.accessToken, url: url, body: body, session: mailSession,
      contentType: contentType)
  }
}

extension RegistrationError {
  var code: String {
    switch self {
    case .cancelled: "cancelled"
    case .declined: "declined"
    case .gmailUnavailable: "gmail-unavailable"
    case .invalidIdentity: "invalid-identity"
    case .unavailable: "unavailable"
    case .identityOwned: "identity-owned"
    case .staleAuthentication: "stale-authentication"
    case .recoveryKeyMismatch: "recovery-key-mismatch"
    case .enrollmentCodeInvalid: "enrollment-code-invalid"
    case .enrollmentUnavailable: "enrollment-unavailable"
    case .revoked: "revoked"
    case .pendingDeviceUnavailable: "unavailable"
    case .deleted: "deleted"
    case .removalRefused, .appleAuthorizationRequired: "removal-refused"
    }
  }
}

@objc(UnwiredRegistration)
final class UnwiredRegistration: NSObject {
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.unwired.mail", category: "registration")
  @MainActor private static var busy = false
  @MainActor private static let operations = RegistrationOperationGate()
  @MainActor private static var sharedStore: RegistrationStore?
  @MainActor private static var reads: [String: Task<Void, Never>] = [:]

  @MainActor private func store() async throws -> RegistrationStore {
    if let store = Self.sharedStore { return store }
    #if UNWIRED_REGISTRATION_MOCK
      guard let bundle = Bundle.main.bundleIdentifier,
        let scenario = Bundle.main.object(forInfoDictionaryKey: "UnwiredMockScenario") as? String
      else { throw RegistrationError.unavailable }
      let store = try mockRegistrationStore(
        bundle: bundle, scenario: scenario, mailCache: try await Self.launchMailCache())
      Self.sharedStore = store
      return store
    #else
      guard let bundle = Bundle.main.bundleIdentifier,
        let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
        clientID.hasSuffix(".apps.googleusercontent.com"),
        let deployment = Bundle.main.object(forInfoDictionaryKey: "UnwiredConvexURL") as? String,
        let base = URL(string: deployment), base.scheme == "https", base.host != nil,
        base.user == nil, base.password == nil, base.query == nil, base.fragment == nil
      else { throw RegistrationError.unavailable }
      let store = RegistrationStore(
        keys: DeviceKeychain(service: bundle + ".google-registration"),
        deployment: deployment, clientID: clientID,
        provider: NativeGoogleRegistrationProvider(clientID: clientID),
        apple: NativeAppleRegistrationProvider(audience: bundle),
        productSync: Self.productSync(base: base),
        deviceRevoked: { product in
          try await Self.mutation(
            base: base, identity: nil, path: "productAccount:isTrustedDeviceRevoked",
            args: [
              "productAccountId": product.productAccountId,
              "trustedDeviceId": product.trustedDeviceId,
              "trustedDeviceCredential": product.trustedDeviceCredential,
            ], function: "query")
        },
        transport: { request in try await Self.send(base: base, request) },
        mailCache: try await Self.launchMailCache(),
        connect: { identity, deviceIdentifier, previous in
          try await Self.connect(
            base: base, identity: identity, deviceIdentifier: deviceIdentifier,
            previous: previous)
        })
      Self.sharedStore = store
      return store
    #endif
  }

  // The mailbox cache for this process. Downloaded Attachments from an earlier process have no
  // reader left, so they are removed before any Inbox opens.
  @MainActor private static func launchMailCache() async throws -> PrivateInboxStore? {
    let cache = try? UnwiredPrivateInbox.store()
    if let cache {
      try await Task.detached(priority: .userInitiated) { try cache.removeAttachments() }.value
    }
    // Picked files an earlier process did not import have no Draft left to add them to.
    try? FileManager.default.removeItem(at: RegistrationStore.pickedDraftFiles)
    return cache
  }

  // Convex error codes the registration flow distinguishes; others are unavailable.
  private static let backendErrors: [String: RegistrationError] = [
    "SIGN_IN_IDENTITY_OWNED": .identityOwned,
    "SIGN_IN_PROVIDER_ALREADY_LINKED": .identityOwned,
    "SIGN_IN_RECENT_AUTHENTICATION_REQUIRED": .staleAuthentication,
    "SIGN_IN_LINK_EXPIRED": .staleAuthentication,
    "SIGN_IN_NOT_LINKED": .invalidIdentity,
    "ENROLLMENT_REQUEST_UNAVAILABLE": .enrollmentUnavailable,
    "PENDING_DEVICE_UNAVAILABLE": .pendingDeviceUnavailable,
    "TRUSTED_DEVICE_REVOKED": .revoked,
    "PRODUCT_ACCOUNT_DELETED": .deleted,
  ]

  // The deployment's HTTP actions live on its .convex.site host.
  private static func site(_ base: URL, path: String) throws -> URL {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
      let host = components.host, host.hasSuffix(".convex.cloud")
    else { throw RegistrationError.unavailable }
    components.host = String(host.dropLast(".convex.cloud".count)) + ".convex.site"
    components.path = path
    guard let url = components.url else { throw RegistrationError.unavailable }
    return url
  }

  // The deployment's Convex HTTP API for functions, or one of its HTTP action routes. The same
  // transport serves TypeScript's credentialed calls and, until #757 and #758, native Product Sync,
  // enrollment and revocation.
  @MainActor static func send(base: URL, _ request: BackendRequest) async throws -> (Int, Data) {
    var urlRequest: URLRequest
    var body = request.args
    switch request.endpoint {
    case .action:
      urlRequest = URLRequest(url: try site(base, path: request.path))
      // Convex exchanges and revokes an Apple authorization code with the client that issued it.
      if body["authorizationCode"] != nil { body["appleClientId"] = Bundle.main.bundleIdentifier }
    case .query, .mutation:
      urlRequest = URLRequest(url: base.appending(path: "api/" + request.endpoint.rawValue))
      body = ["path": request.path, "args": request.args, "format": "json"]
    }
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = 30
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let identity = request.identity {
      urlRequest.setValue("Bearer " + identity.idToken, forHTTPHeaderField: "Authorization")
    }
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    guard let response = response as? HTTPURLResponse else { throw RegistrationError.unavailable }
    return (response.statusCode, data)
  }

  @MainActor private static func mutation<Value: Decodable>(
    base: URL, identity: ProductSignInIdentity?, path: String, args: [String: Any],
    function: String = "mutation"
  ) async throws -> Value {
    guard
      let value: Value = try await optionalResult(
        base: base, identity: identity, path: path, args: args, function: function)
    else { throw RegistrationError.unavailable }
    return value
  }

  // A successful null result is nil. Without an identity, only functions that take the Trusted
  // Device credential as their proof can succeed. Temporary for native callers until #757 and #758.
  @MainActor private static func optionalResult<Value: Decodable>(
    base: URL, identity: ProductSignInIdentity?, path: String, args: [String: Any],
    function: String = "mutation"
  ) async throws -> Value? {
    let (status, data) = try await send(
      base: base,
      BackendRequest(
        endpoint: function == "query" ? .query : .mutation, path: path, args: args,
        identity: identity))
    // Application errors carry a code in errorData whatever the HTTP status.
    guard let result = try? JSONDecoder().decode(ConvexEnvelope<Value>.self, from: data) else {
      throw RegistrationError.unavailable
    }
    if result.status == "success", status == 200 {
      return result.value
    }
    if result.status == "error", path == "productSync:putEncryptedPayloadIfUnchanged",
      let code = result.errorData?.code, let refusal = ProductSyncWriteFailure(rawValue: code)
    {
      throw refusal
    }
    throw result.errorData.flatMap { backendErrors[$0.code] } ?? RegistrationError.unavailable
  }

  @MainActor private static func connect(
    base: URL, identity: ProductSignInIdentity, deviceIdentifier: String,
    previous: ProductRegistrationReceipt?
  ) async throws -> ProductRegistrationReceipt {
    #if os(iOS)
      let platform = "ios"
    #else
      let platform = "macos"
    #endif
    let reply: ConnectReply = try await mutation(
      base: base, identity: identity, path: "productAccount:connect",
      args: ProductRegistrationReceipt.connectArguments(
        deviceIdentifier: deviceIdentifier, platform: platform, previous: previous))
    return try ProductRegistrationReceipt(connected: reply)
  }

  private func perform(
    _ name: String, _ resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock,
    operation: @escaping @MainActor (RegistrationStore) async throws -> Any
  ) {
    Task { @MainActor in await self.settle(name, resolve, reject: reject, operation: operation) }
  }

  @MainActor private func settle(
    _ name: String, _ resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock,
    operation: @escaping @MainActor (RegistrationStore) async throws -> Any
  ) async {
    guard !Self.busy else {
      reject("busy", "Authorization is already running.", nil)
      return
    }
    Self.busy = true
    defer { Self.busy = false }
    do {
      let value = try await Self.operations.perform { try await operation(store()) }
      resolve(value)
    } catch {
      // Descriptions stay private: SDK and transport errors can echo request details.
      let failure = error as NSError
      Self.logger.error(
        """
        \(name, privacy: .public) failed: \(failure.domain, privacy: .public) \
        \(failure.code, privacy: .public) \(failure.localizedDescription, privacy: .private)
        """)
      let code =
        (error as? RegistrationError)?.code
        ?? ((error as? PrivateInboxError) == .locked
          ? "locked"
          : RegistrationStore.transientMailboxFailure(error) ? "offline" : "unavailable")
      let message =
        switch code {
        case "cancelled": "Sign-in was cancelled."
        case "recovery-key-mismatch": "That does not match the end of your Recovery Key."
        case "enrollment-code-invalid": "That code does not match the new device's code."
        case "enrollment-unavailable": "That device request is no longer available."
        case "locked": "Unlock your device to open your saved account."
        default: "Registration could not finish. Retry with your saved account."
        }
      reject(code, message, nil)
    }
  }

  // An operation that resolves without a value.
  private func performStep(
    _ name: String, _ resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock,
    operation: @escaping @MainActor (RegistrationStore) async throws -> Void
  ) {
    perform(name, resolve, reject: reject) { store -> Any in
      try await operation(store)
      return NSNull()
    }
  }

  // The registration flow runs in TypeScript; each method is one purpose-named vault operation.
  @objc(registration:rejecter:)
  func registration(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("registration", resolve, reject: reject) { store -> Any in
      guard let projection = try store.registration() else { return NSNull() }
      return projection
    }
  }
  @objc(signInIdentity:hint:resolver:rejecter:)
  func signInIdentity(
    _ provider: String, hint: Bool, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("signInIdentity", resolve, reject: reject) {
      guard let provider = SignInProvider(rawValue: provider) else {
        throw RegistrationError.unavailable
      }
      return try await $0.signInIdentity(provider, hint: hint)
    }
  }
  @objc(renewIdentity:rejecter:)
  func renewIdentity(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("renewIdentity", resolve, reject: reject) { try await $0.renewIdentity() }
  }
  @objc(appleCredentialState:rejecter:)
  func appleCredentialState(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("appleCredentialState", resolve, reject: reject) {
      try await $0.appleCredentialState()
    }
  }
  @objc(reuseSession:rejecter:)
  func reuseSession(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("reuseSession", resolve, reject: reject) { try $0.reuseSession() }
  }
  @objc(saveIdentity:resolver:rejecter:)
  func saveIdentity(
    _ replacing: Bool, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("saveIdentity", resolve, reject: reject) { try $0.saveIdentity(replacing: replacing) }
  }
  @objc(connect:resolver:rejecter:)
  func connect(
    _ mode: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("connect", resolve, reject: reject) {
      guard let mode = RegistrationStore.ConnectMode(rawValue: mode) else {
        throw RegistrationError.unavailable
      }
      try await $0.connectIdentity(mode)
    }
  }
  @objc(synchronize:rejecter:)
  func synchronize(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("synchronize", resolve, reject: reject) { try await $0.synchronizeRegistration() }
  }
  @objc(forgetMailboxAccess:rejecter:)
  func forgetMailboxAccess(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("forgetMailboxAccess", resolve, reject: reject) { $0.forgetMailboxAccess() }
  }
  @objc(retryMailboxCleanup:rejecter:)
  func retryMailboxCleanup(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("retryMailboxCleanup", resolve, reject: reject) {
      try await $0.retryMailboxCleanup()
    }
  }
  @objc(refreshMailbox:resolver:rejecter:)
  func refreshMailbox(
    _ connection: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("refreshMailbox", resolve, reject: reject) {
      try await $0.refreshMailbox(connection)
    }
  }
  @objc(signInMailbox:suggest:resolver:rejecter:)
  func signInMailbox(
    _ connection: String?, suggest: Bool, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("signInMailbox", resolve, reject: reject) {
      try await $0.signInMailbox(connection, suggest: suggest)
    }
  }
  @objc(verifyGmail:rejecter:)
  func verifyGmail(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("verifyGmail", resolve, reject: reject) { try await $0.verifyGmail() }
  }
  @objc(confirmMailbox:resolver:rejecter:)
  func confirmMailbox(
    _ connection: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("confirmMailbox", resolve, reject: reject) { try $0.confirmMailbox(connection) }
  }
  @objc(storeMailbox:rejecter:)
  func storeMailbox(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("storeMailbox", resolve, reject: reject) { try $0.storeMailbox() }
  }
  @objc(markMailbox:access:resolver:rejecter:)
  func markMailbox(
    _ connection: String, access: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("markMailbox", resolve, reject: reject) {
      try $0.markMailbox(connection, access: access)
    }
  }
  @objc(recordMailboxSetup:resolver:rejecter:)
  func recordMailboxSetup(
    _ reason: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("recordMailboxSetup", resolve, reject: reject) { try $0.recordMailboxSetup(reason) }
  }
  @objc(saveSignInProviders:resolver:rejecter:)
  func saveSignInProviders(
    _ providers: [String], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("saveSignInProviders", resolve, reject: reject) {
      let parsed = providers.compactMap(SignInProvider.init)
      guard parsed.count == providers.count else { throw RegistrationError.unavailable }
      try $0.saveSignInProviders(parsed)
    }
  }
  @objc(recordRemoval:resolver:rejecter:)
  func recordRemoval(
    _ operation: String?, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("recordRemoval", resolve, reject: reject) {
      let parsed = operation.flatMap(AccountRemovalState.Operation.init)
      guard (parsed == nil) == (operation == nil) else { throw RegistrationError.unavailable }
      try $0.recordRemoval(parsed)
    }
  }
  @objc(prepareSignOut:rejecter:)
  func prepareSignOut(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("prepareSignOut", resolve, reject: reject) { try await $0.prepareSignOut() }
  }
  @objc(endSession:rejecter:)
  func endSession(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("endSession", resolve, reject: reject) { $0.endSession() }
  }
  @objc(purge:resolver:rejecter:)
  func purge(
    _ notice: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("purge", resolve, reject: reject) {
      guard ["revoked", "deleted", "signed-out"].contains(notice) else {
        throw RegistrationError.unavailable
      }
      try await $0.purge(notice: notice)
    }
  }
  @objc(call:resolver:rejecter:)
  func call(
    _ request: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("call", resolve, reject: reject) { try await $0.call(request) }
  }
  @objc(removeMailbox:resolver:rejecter:)
  func removeMailbox(
    _ connection: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("removeMailbox", resolve, reject: reject) { try await $0.removeMailbox(connection) }
  }
  @objc(confirmRecoveryKey:resolver:rejecter:)
  func confirmRecoveryKey(
    _ entry: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("confirmRecoveryKey", resolve, reject: reject) { try $0.confirmRecoveryKey(entry) }
  }
  @objc(readsAsRecoveryKey:resolver:rejecter:)
  func readsAsRecoveryKey(
    _ entry: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("readsAsRecoveryKey", resolve, reject: reject) { $0.readsAsRecoveryKey(entry) }
  }
  @objc(recoverWithRecoveryKey:resolver:rejecter:)
  func recoverWithRecoveryKey(
    _ entry: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("recoverWithRecoveryKey", resolve, reject: reject) {
      ["rejected": try await $0.recover(with: entry)]
    }
  }
  @objc(approveEnrollment:code:resolver:rejecter:)
  func approveEnrollment(
    _ requestId: String, code: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("approveEnrollment", resolve, reject: reject) {
      try await $0.approveEnrollment(requestId, code: code)
    }
  }
  @objc(declineEnrollment:resolver:rejecter:)
  func declineEnrollment(
    _ requestId: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("declineEnrollment", resolve, reject: reject) {
      try await $0.declineEnrollment(requestId)
    }
  }
  @objc(revokeTrustedDevice:resolver:rejecter:)
  func revokeTrustedDevice(
    _ trustedDeviceId: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("revokeTrustedDevice", resolve, reject: reject) {
      try await $0.revoke(trustedDeviceId).map { ["notice": $0] } ?? [:]
    }
  }
}

extension UnwiredRegistration {
  @objc static func requiresMainQueueSetup() -> Bool { true }

  // Mailbox preflight and registration changes share custody across all suspension points.
  private func mailbox(
    _ name: String, _ resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock,
    request: String? = nil,
    operation: @escaping @MainActor (RegistrationStore) async throws -> [String: Any]
  ) {
    DispatchQueue.main.async {
      if let request, Self.reads[request] != nil {
        reject("unavailable", "Gmail could not be reached.", nil)
        return
      }
      let task = Task { @MainActor in
        defer { if let request { Self.reads.removeValue(forKey: request) } }
        do {
          resolve(
            try await Self.operations.perform {
              try Task.checkCancellation()
              return try await operation(self.store())
            })
        } catch {
          Self.rejectMailbox(name, error, reject)
        }
      }
      if let request { Self.reads[request] = task }
    }
  }

  private static func rejectMailbox(
    _ name: String, _ error: any Error, _ reject: RCTPromiseRejectBlock
  ) {
    switch error {
    case is CancellationError:
      reject("cancelled", "The Gmail request was cancelled.", nil)
    case RegistrationError.revoked, RegistrationError.deleted:
      reject("mailbox-revoked", "This device no longer has access.", nil)
    case RegistrationError.gmailUnavailable:
      reject("gmail-unavailable", "Gmail needs authorization again.", nil)
    case PrivateInboxError.locked: reject("locked", "Private storage is locked.", nil)
    case PrivateInboxError.attachmentMissing:
      reject("attachment-missing", "The attachment is no longer on this device.", nil)
    case PrivateInboxError.tooLarge:
      reject("too-large", "The file is too large for Drafts on this device.", nil)
    case PrivateInboxError.conflict: reject("conflict", "The mailbox changed.", nil)
    case PrivateInboxError.mailboxInvalidated:
      reject("mailbox-invalidated", "The mailbox is no longer available.", nil)
    case PrivateInboxError.deliveryUnknown:
      reject("delivery-unknown", "Gmail may have received the message.", nil)
    default:
      logger.error("\(name, privacy: .public) failed: unavailable")
      reject("unavailable", "Gmail could not be reached.", nil)
    }
  }

  // Reads the Draft sync keys and session under the registration gate, then works on the network
  // without holding it, so a large upload never stalls saving Drafts or reading Gmail.
  private func syncDrafts(
    _ name: String, owner: String, _ resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock,
    operation: @escaping @MainActor (RegistrationStore, DraftSync) async throws -> [String: Any]
  ) {
    DispatchQueue.main.async {
      Task { @MainActor in
        do {
          let (store, sync) = try await Self.operations.perform {
            let store = try await self.store()
            return (store, try await store.prepareDraftSync(owner: owner))
          }
          do {
            let result = try await operation(store, sync)
            _ = try await Self.operations.perform { try store.draftSync(owner: owner) }
            resolve(result)
          } catch {
            try await Self.operations.perform {
              try await store.draftSyncFailure(owner: owner, error: error)
            }
          }
        } catch {
          Self.rejectMailbox(name, error, reject)
        }
      }
    }
  }

  // An asset as TypeScript names it for Product Sync: its file identifier, SHA-256 and size.
  private static func syncedAsset(_ asset: Any) throws -> (id: String, digest: String, size: Int) {
    guard let asset = asset as? [String: Any], let id = asset["id"] as? String,
      id.range(of: "^[0-9a-z]{8,64}$", options: .regularExpression) != nil,
      let digest = asset["digest"] as? String,
      digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
      let size = (asset["size"] as? Double).flatMap({ Int(exactly: $0) }), size >= 0,
      size <= PrivateInboxStore.draftAssetLimit
    else { throw RegistrationError.unavailable }
    return (id, digest, size)
  }

  @objc(pullDrafts:known:resolver:rejecter:)
  func pullDrafts(
    _ owner: String, known: [String],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    syncDrafts("pullDrafts", owner: owner, resolve, reject: reject) { _, sync in
      try await sync.pull(known: known)
    }
  }

  // `record` carries the Draft's identifier, the record's write count, its JSON or null to delete
  // it, and the revision it replaces.
  @objc(pushDraft:record:resolver:rejecter:)
  func pushDraft(
    _ owner: String, record: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    syncDrafts("pushDraft", owner: owner, resolve, reject: reject) { _, sync in
      guard let id = record["id"] as? String, !id.isEmpty, id.count <= 200,
        let version = (record["version"] as? Double).flatMap({ Int(exactly: $0) }), version >= 1
      else { throw RegistrationError.unavailable }
      let draft = record["draft"] as? String
      guard draft != nil || record["draft"] is NSNull else { throw RegistrationError.unavailable }
      return try await sync.push(
        id: id, version: version, draft: draft,
        expected: record["expectedUpdatedAt"] as? Double)
    }
  }

  @objc(uploadDraftAsset:asset:resolver:rejecter:)
  func uploadDraftAsset(
    _ owner: String, asset: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    syncDrafts("uploadDraftAsset", owner: owner, resolve, reject: reject) { store, sync in
      let (id, digest, size) = try Self.syncedAsset(asset)
      let bytes = try await Self.operations.perform {
        try await store.draftAssetBytes(owner: owner, id: id, digest: digest)
      }
      guard bytes.count == size else { throw RegistrationError.unavailable }
      try await sync.upload(bytes, id: id, digest: digest)
      return ["owner": owner]
    }
  }

  @objc(downloadDraftAsset:asset:resolver:rejecter:)
  func downloadDraftAsset(
    _ owner: String, asset: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    syncDrafts("downloadDraftAsset", owner: owner, resolve, reject: reject) { store, sync in
      let (id, digest, size) = try Self.syncedAsset(asset)
      let bytes = try await sync.download(id: id, digest: digest, size: size)
      return try await Self.operations.perform {
        try await store.storeDraftAsset(owner: owner, id: id, bytes: bytes)
      }
    }
  }

  // Claims Draft `id` for delivery from this Trusted Device through Convex.
  @objc(claimDraftDelivery:id:resolver:rejecter:)
  func claimDraftDelivery(
    _ owner: String, id: String,
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    syncDrafts("claimDraftDelivery", owner: owner, resolve, reject: reject) { _, sync in
      guard !id.isEmpty, id.count <= 200 else { throw RegistrationError.unavailable }
      return try await sync.claimDelivery(draft: id)
    }
  }

  @objc(cancelGmailRequest:)
  func cancelGmailRequest(_ request: String) {
    DispatchQueue.main.async { Self.reads[request]?.cancel() }
  }

  @objc(gmailRequest:query:mailbox:resolver:rejecter:)
  func gmailRequest(
    _ path: String, query: [Any], mailbox scope: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    let request = scope["request"] as? String
    if let request,
      request.count > 200
        || request.range(
          of: "^[0-9A-Za-z:-]+$", options: .regularExpression) == nil
    {
      reject("unavailable", "Gmail could not be reached.", nil)
      return
    }
    mailbox("gmailRequest", resolve, reject: reject, request: request) {
      let (connection, address, generation) = try Self.scope(scope)
      // Name-value pairs, so repeated parameters keep their order.
      let items = try query.map { pair in
        guard let pair = pair as? [String], pair.count == 2 else {
          throw RegistrationError.unavailable
        }
        return URLQueryItem(name: pair[0], value: pair[1])
      }
      return try await $0.gmail(
        path: path, query: items, connection: connection, address: address,
        generation: generation)
    }
  }

  @objc(gmailModify:mailbox:resolver:rejecter:)
  func gmailModify(
    _ change: [String: Any], mailbox scope: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("gmailModify", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard let message = change["message"] as? String,
        let add = change["add"] as? [String], let remove = change["remove"] as? [String]
      else { throw RegistrationError.unavailable }
      return try await $0.gmailModify(
        message: message, add: add, remove: remove, connection: connection, address: address,
        generation: generation)
    }
  }

  // `message` carries `segments`, each `{ text }` or `{ asset: { id, digest } }`, and an optional
  // `threadId`. Not cancellable: once started, its outcome may only be unknown.
  @objc(gmailSend:mailbox:resolver:rejecter:)
  func gmailSend(
    _ message: [String: Any], mailbox scope: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("gmailSend", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard let segments = message["segments"] as? [Any],
        message["threadId"] == nil || message["threadId"] is String
      else { throw RegistrationError.unavailable }
      return try await $0.gmailSend(
        segments: segments, threadId: message["threadId"] as? String, connection: connection,
        address: address, generation: generation)
    }
  }

  @objc(openMailbox:resolver:rejecter:)
  func openMailbox(
    _ connection: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("openMailbox", resolve, reject: reject) {
      try await $0.prepareMailbox(connection)
      return try $0.openMailbox(connection)
    }
  }

  @objc(commitMailbox:expectedRevision:document:resolver:rejecter:)
  func commitMailbox(
    _ scope: [String: Any], expectedRevision: Double, document: String,
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("commitMailbox", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      try await $0.prepareMailbox(connection)
      guard let revision = Int(exactly: expectedRevision) else {
        throw RegistrationError.unavailable
      }
      return try $0.commitMailbox(
        connection: connection, address: address, expectedRevision: revision, document: document,
        generation: generation)
    }
  }

  @objc(openDrafts:rejecter:)
  func openDrafts(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("openDrafts", resolve, reject: reject) { try await $0.openDrafts() }
  }

  // `commit` carries the document and the assets its Drafts keep.
  @objc(commitDrafts:expectedRevision:commit:resolver:rejecter:)
  func commitDrafts(
    _ owner: String, expectedRevision: Double, commit: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("commitDrafts", resolve, reject: reject) {
      guard let revision = Int(exactly: expectedRevision), revision >= 0,
        let document = commit["document"] as? String, let keep = commit["keep"] as? [String]
      else {
        throw RegistrationError.unavailable
      }
      return try await $0.commitDrafts(
        owner: owner, expectedRevision: revision, document: document, keep: keep)
    }
  }

  @objc(importDraftAsset:id:source:resolver:rejecter:)
  func importDraftAsset(
    _ owner: String, id: String, source: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("importDraftAsset", resolve, reject: reject) {
      try await $0.importDraftAsset(owner: owner, id: id, source: source)
    }
  }

  @objc(readDraftAsset:asset:resolver:rejecter:)
  func readDraftAsset(
    _ owner: String, asset: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("readDraftAsset", resolve, reject: reject) {
      guard let id = asset["id"] as? String, let digest = asset["digest"] as? String,
        let type = asset["type"] as? String
      else { throw RegistrationError.unavailable }
      return try await $0.readDraftAsset(
        owner: owner, id: id, digest: digest, type: type,
        preview: asset["preview"] as? Bool ?? true)
    }
  }

  @objc(discardDraftAsset:id:resolver:rejecter:)
  func discardDraftAsset(
    _ owner: String, id: String,
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("discardDraftAsset", resolve, reject: reject) {
      try await $0.discardDraftAsset(id: id)
      return [:]
    }
  }

  // The system picker waits for the person, so it does not hold the mailbox operation gate.
  @objc(discardPickedDraftFiles:resolver:rejecter:)
  func discardPickedDraftFiles(
    _ uris: [String], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    Task { @MainActor in
      await Task.detached(priority: .userInitiated) {
        for uri in uris {
          if let file = URL(string: uri), file.isFileURL {
            RegistrationStore.discardPickedDraftFile(file)
          }
        }
      }.value
      resolve([:])
    }
  }

  // The system picker waits for the person, so it does not hold the mailbox operation gate.
  @objc(pickDraftFiles:resolver:rejecter:)
  func pickDraftFiles(
    _ source: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.main.async {
      Task { @MainActor in
        do {
          resolve(try await DraftFilePicker.pick(source))
        } catch {
          Self.logger.error("pickDraftFiles failed: unavailable")
          reject("unavailable", "The files could not be added.", nil)
        }
      }
    }
  }

  // The connection, address and generation that every mailbox call names.
  private static func scope(_ scope: [String: Any]) throws -> (String, String, String) {
    guard let connection = scope["connection"] as? String,
      let address = scope["address"] as? String,
      let generation = scope["generation"] as? String
    else { throw RegistrationError.unavailable }
    return (connection, address, generation)
  }

  @objc(openMessageBody:id:resolver:rejecter:)
  func openMessageBody(
    _ scope: [String: Any], id: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("openMessageBody", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      return try await $0.openMessageBody(
        connection: connection, address: address, generation: generation, id: id)
    }
  }

  @objc(commitMessageBody:id:admission:resolver:rejecter:)
  func commitMessageBody(
    _ scope: [String: Any], id: String, admission: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("commitMessageBody", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      return try await $0.commitMessageBody(
        connection: connection, address: address, generation: generation, id: id,
        admission: admission)
    }
  }

  @objc(listMessageBodies:ids:resolver:rejecter:)
  func listMessageBodies(
    _ scope: [String: Any], ids: [String], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("listMessageBodies", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      return try await $0.listMessageBodies(
        connection: connection, address: address, generation: generation, ids: ids)
    }
  }

  @objc(retainMessageBodies:ids:protectedIds:resolver:rejecter:)
  func retainMessageBodies(
    _ scope: [String: Any], ids: [String], protectedIds: [String],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("retainMessageBodies", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard let value = scope["revision"] as? Double,
        let revision = Int(exactly: value), revision >= 0
      else { throw RegistrationError.unavailable }
      return try await $0.retainMessageBodies(
        connection: connection, address: address, generation: generation,
        expectedRevision: revision, ids: ids, protectedIds: protectedIds)
    }
  }

  @objc(saveAttachment:attachment:resolver:rejecter:)
  func saveAttachment(
    _ scope: [String: Any], attachment: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("saveAttachment", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard let name = attachment["name"] as? String, let data = attachment["data"] as? String,
        let value = attachment["size"] as? Double, let size = Int(exactly: value), size >= 0
      else { throw RegistrationError.unavailable }
      return try await $0.saveAttachment(
        connection: connection, address: address, generation: generation, name: name,
        data: data, size: size, protectedFiles: Set(Self.presentedAttachments.keys))
    }
  }

  @objc(discardAttachment:file:resolver:rejecter:)
  func discardAttachment(
    _ scope: [String: Any], file: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("discardAttachment", resolve, reject: reject) {
      let (connection, _, _) = try Self.scope(scope)
      // A file the system is still previewing or sharing is deleted when that presentation ends.
      if Self.presentedAttachments[file] != nil {
        Self.deferredDiscards[file] = connection
        return [:]
      }
      try await $0.discardAttachment(connection: connection, file: file)
      return [:]
    }
  }

  // Presentation leases: active previews and shares by file, and discards waiting for them.
  @MainActor private static var presentedAttachments: [String: Int] = [:]
  @MainActor private static var deferredDiscards: [String: String] = [:]

  @MainActor private static func endPresentation(_ file: String) {
    let remaining = (Self.presentedAttachments[file] ?? 1) - 1
    Self.presentedAttachments[file] = remaining > 0 ? remaining : nil
    guard remaining <= 0, let connection = Self.deferredDiscards.removeValue(forKey: file),
      let store = Self.sharedStore
    else { return }
    Task { @MainActor in
      do {
        try await Self.operations.perform {
          // A queued Open/Share may have acquired a new lease while this task awaited the gate.
          if Self.presentedAttachments[file] != nil {
            Self.deferredDiscards[file] = connection
            return
          }
          try await store.discardAttachment(connection: connection, file: file)
        }
      } catch {
        Self.logger.error("Deferred attachment discard failed: unavailable")
      }
    }
  }

  // Resolves once the preview or share sheet is shown.
  @objc(presentAttachment:file:action:resolver:rejecter:)
  func presentAttachment(
    _ scope: [String: Any], file: String, action: String,
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    // The initiating window is captured before waiting for the gate or storage.
    DispatchQueue.main.async {
      let origin = AttachmentPresenter.origin()
      self.presentAttachment(
        scope, file: file, action: action, from: origin, resolve: resolve, reject: reject)
    }
  }

  @MainActor private func presentAttachment(
    _ scope: [String: Any], file: String, action: String, from origin: PresentationOrigin,
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("presentAttachment", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard action == "open" || action == "share" else { throw RegistrationError.unavailable }
      let url = try await $0.attachmentFile(
        connection: connection, address: address, generation: generation, file: file)
      Self.presentedAttachments[file, default: 0] += 1
      let presented = AttachmentPresenter.present(url, share: action == "share", from: origin) {
        Self.endPresentation(file)
      }
      guard presented else {
        Self.endPresentation(file)
        throw RegistrationError.unavailable
      }
      return [:]
    }
  }

  // Every Product Sync call carries the device proof; Convex sees only opaque payloads.
  // The transport factory assembles all authenticated operations with the same device proof.
  // swiftlint:disable:next function_body_length
  @MainActor private static func productSync(base: URL) -> ProductSyncBackend {
    func proof(_ product: ProductRegistrationReceipt) -> [String: Any] {
      RegistrationStore.proof(product)
    }
    func json(_ payload: EncryptedPayload) throws -> Any {
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
    }
    return ProductSyncBackend(
      initialize: { identity, product, envelope, verifier in
        struct Response: Decodable { let initialized: Bool }
        let response: Response = try await mutation(
          base: base, identity: identity, path: "productSync:initialize",
          args: proof(product).merging([
            "encryptedPayload": try json(envelope), "recoveryVerifier": verifier,
          ]) { $1 })
        return response.initialized
      },
      list: { identity, product, prefix in
        struct Page: Decodable {
          let page: [StoredPayload]
          let isDone: Bool
          let continueCursor: String
        }
        // Convex serves at most 100 records per page; read every page for a complete set.
        var records: [StoredPayload] = []
        var cursor: Any = NSNull()
        while true {
          let page: Page = try await mutation(
            base: base, identity: identity,
            path: "productSync:listEncryptedPayloadsForTrustedDevice",
            args: proof(product).merging([
              "payloadIdentifierPrefix": prefix,
              "paginationOpts": ["cursor": cursor, "numItems": 100],
            ]) { $1 },
            function: "query")
          records += page.page
          if page.isDone { return records }
          cursor = page.continueCursor
        }
      },
      put: { identity, product, identifier, payload, expectedUpdatedAt in
        var args = proof(product)
        args["payloadIdentifier"] = identifier
        args["encryptedPayload"] = try json(payload)
        if let expectedUpdatedAt { args["expectedUpdatedAt"] = expectedUpdatedAt }
        return try await mutation(
          base: base, identity: identity, path: "productSync:putEncryptedPayloadIfUnchanged",
          args: args)
      },
      requestEnrollment: { identity, product, publicKey in
        struct Response: Decodable { let expiresAt: Double }
        let _: Response = try await mutation(
          base: base, identity: identity, path: "productSyncEnrollment:request",
          args: proof(product).merging([
            "enrollmentPublicKey": publicKey.rawRepresentation.base64EncodedString()
          ]) { $1 })
      },
      enrollmentStatus: { identity, product in
        try await readEnrollmentStatus(base: base, identity: identity, args: proof(product))
      },
      completeEnrollment: { identity, product, keyVersion in
        struct Response: Decodable {
          let admitted: Bool
          let trustedDeviceId: String?
        }
        let response: Response = try await mutation(
          base: base, identity: identity, path: "productSyncEnrollment:complete",
          args: proof(product).merging(["keyVersion": keyVersion]) { $1 })
        return response.admitted ? response.trustedDeviceId : nil
      },
      recoverPending: { identity, product, recoveryProof in
        // A successful null result is a proof that matches no Recovery Key of the account.
        try await optionalResult(
          base: base, identity: identity, path: "productSyncEnrollment:recover",
          args: proof(product).merging(["recoveryProof": recoveryProof]) { $1 })
      },
      pendingEnrollments: { identity, product in
        try await readPendingEnrollments(base: base, identity: identity, args: proof(product))
      },
      approveEnrollment: { identity, product, request, keyVersion, envelope in
        struct Response: Decodable { let approved: Bool }
        let _: Response = try await mutation(
          base: base, identity: identity, path: "productSyncEnrollment:approve",
          args: proof(product).merging([
            "pendingDeviceId": request.pendingDeviceId,
            "enrollmentPublicKey": request.publicKey.rawRepresentation.base64EncodedString(),
            "keyVersion": keyVersion,
            "encapsulatedKeyBase64": envelope.encapsulatedKey.base64EncodedString(),
            "ciphertextBase64": envelope.ciphertext.base64EncodedString(),
          ]) { $1 })
      },
      declineEnrollment: { identity, product, pendingDeviceId in
        struct Response: Decodable { let declined: Bool }
        let _: Response = try await mutation(
          base: base, identity: identity, path: "productSyncEnrollment:decline",
          args: proof(product).merging(["pendingDeviceId": pendingDeviceId]) { $1 })
      },
      recoveryEnvelope: { identity, product in
        // A missing envelope decodes as no value and reports Product Sync as unavailable.
        try await mutation(
          base: base, identity: identity, path: "productSync:getEncryptedPayloadForTrustedDevice",
          args: proof(product).merging(["payloadIdentifier": "product-account-recovery-v1"]) {
            $1
          },
          function: "query")
      },
      keyRotation: { identity, product in
        struct Response: Decodable {
          let keyEpoch: Int
          let encryptedTransition: EncryptedPayload
        }
        let response: Response? = try await optionalResult(
          base: base, identity: identity, path: "productAccount:getProductSyncKeyRotation",
          args: proof(product), function: "query")
        return response.map {
          KeyRotation(keyEpoch: $0.keyEpoch, transition: $0.encryptedTransition)
        }
      },
      acknowledgeRotation: { identity, product, keyEpoch in
        struct Response: Decodable { let keyEpoch: Int }
        let _: Response = try await mutation(
          base: base, identity: identity, path: "productAccount:acknowledgeProductSyncKeyRotation",
          args: proof(product).merging(["keyEpoch": keyEpoch]) { $1 })
      },
      trustedDevices: { identity, product in
        struct Device: Decodable {
          let id: String
          let displayName: String
          let registeredAt: Double
        }
        let devices: [Device] = try await mutation(
          base: base, identity: identity, path: "productAccount:listTrustedDevices",
          args: proof(product), function: "query")
        return devices.map {
          TrustedDevice(id: $0.id, name: $0.displayName, registeredAt: $0.registeredAt)
        }
      },
      revoke: {
        identity, product, trustedDeviceToRevokeId, transition, recovery, verifier, updatedAt in
        var request = URLRequest(url: try site(base, path: "/trusted-devices/revoke"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + identity.idToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
          withJSONObject: proof(product).merging([
            "trustedDeviceToRevokeId": trustedDeviceToRevokeId,
            "encryptedTransition": try json(transition),
            "recoveryWrappedAccountKey": try json(recovery),
            "recoveryVerifier": verifier,
            "expectedRecoveryUpdatedAt": updatedAt,
          ]) { $1 })
        let (data, response) = try await URLSession.shared.data(for: request)
        struct Failure: Decodable { let code: String }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return
        case 401: throw RegistrationError.staleAuthentication
        case 403:
          throw (try? JSONDecoder().decode(Failure.self, from: data)).flatMap {
            backendErrors[$0.code]
          } ?? RegistrationError.unavailable
        case 400, 404, 409: throw RegistrationError.unavailable
        default:
          // A server/proxy failure can follow a committed mutation. Preserve the pending key
          // until synchronization compares its exact transition with the authoritative one.
          throw URLError(.badServerResponse)
        }
      },
      get: { identity, product, identifier in
        try await optionalResult(
          base: base, identity: identity, path: "productSync:getEncryptedPayloadForTrustedDevice",
          args: proof(product).merging(["payloadIdentifier": identifier]) { $1 },
          function: "query")
      },
      claimDelivery: { identity, product, identifier in
        struct Response: Decodable { let claimed: Bool }
        let response: Response = try await mutation(
          base: base, identity: identity, path: "draftDelivery:claim",
          args: proof(product).merging(["claimIdentifier": identifier]) { $1 })
        return response.claimed
      })
  }

  @MainActor fileprivate static func readEnrollmentStatus(
    base: URL, identity: ProductSignInIdentity, args: [String: Any]
  ) async throws -> EnrollmentStatus {
    struct Approval: Decodable {
      let keyVersion: Int
      let encapsulatedKeyBase64: String
      let ciphertextBase64: String
    }
    struct Response: Decodable {
      let state: EnrollmentStatus.State
      let approval: Approval?
    }
    let response: Response = try await mutation(
      base: base, identity: identity, path: "productSyncEnrollment:status",
      args: args)
    // A malformed approval opens nothing; the device asks again.
    guard let approval = response.approval,
      let encapsulatedKey = Data(base64Encoded: approval.encapsulatedKeyBase64),
      let ciphertext = Data(base64Encoded: approval.ciphertextBase64)
    else { return EnrollmentStatus(state: response.state) }
    return EnrollmentStatus(
      state: response.state,
      approval: (
        approval.keyVersion,
        KeyRingEnvelope.Enrollment(encapsulatedKey: encapsulatedKey, ciphertext: ciphertext)
      ))
  }

  @MainActor fileprivate static func readPendingEnrollments(
    base: URL, identity: ProductSignInIdentity, args: [String: Any]
  ) async throws -> [PendingEnrollment] {
    struct Request: Decodable {
      let pendingDeviceId: String
      let enrollmentPublicKey: String
      let displayName: String
      let expiresAt: Double
    }
    let requests: [Request] = try await mutation(
      base: base, identity: identity, path: "productSyncEnrollment:listPending",
      args: args)
    return requests.compactMap { request in
      guard let raw = Data(base64Encoded: request.enrollmentPublicKey),
        let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
      else { return nil }
      return PendingEnrollment(
        pendingDeviceId: request.pendingDeviceId, publicKey: publicKey,
        deviceName: request.displayName, expiresAt: request.expiresAt)
    }
  }
}
