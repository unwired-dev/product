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

@objc(UnwiredRegistration)
final class UnwiredRegistration: NSObject {
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.unwired.mail", category: "registration")
  @MainActor private static var busy = false
  @MainActor private static let operations = RegistrationOperationGate()
  @MainActor private static var sharedStore: RegistrationStore?
  @MainActor private static var reads: [String: Task<Void, Never>] = [:]
  @MainActor private static var remoteLoads: [String: RemoteLoad] = [:]
  private final class RemoteLoad {
    let budget = RemoteContentBudget()
    var requests: [String: Task<Void, Never>] = [:]
  }

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
      // Microsoft mail needs the public-client application registered for this redirect scheme.
      let microsoftClientID = Self.microsoftClientID
      let authentication = MicrosoftAuthentication()
      let store = RegistrationStore(
        keys: DeviceKeychain(service: bundle + ".google-registration"),
        deployment: deployment, clientID: clientID,
        provider: NativeGoogleRegistrationProvider(clientID: clientID),
        apple: NativeAppleRegistrationProvider(audience: bundle),
        microsoft: microsoftClientID.isEmpty
          ? nil
          : GraphMailProvider(
            clientID: microsoftClientID, callbackScheme: "msauth." + bundle,
            authenticate: { try await authentication.authenticate($0, callbackScheme: $1) }),
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
  // transport serves TypeScript's credentialed calls, the vault's own proof-carrying calls and
  // native Draft sync.
  @MainActor static func send(base: URL, _ request: BackendRequest) async throws -> (Int, Data) {
    var urlRequest: URLRequest
    var body = request.args
    switch request.endpoint {
    case .action where request.path.hasPrefix("/"):
      urlRequest = URLRequest(url: try site(base, path: request.path))
      // Convex exchanges and revokes an Apple authorization code with the client that issued it.
      if body["authorizationCode"] != nil { body["appleClientId"] = Bundle.main.bundleIdentifier }
    case .query, .mutation, .action:
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
  // Device credential as their proof can succeed.
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
    throw result.errorData.flatMap { RegistrationStore.backendErrors[$0.code] }
      ?? RegistrationError.unavailable
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
      // Foreign errors can echo account or server content even through private OSLog fields.
      let code = RegistrationStore.rejectionCode(error)
      Self.logger.error(
        "\(name, privacy: .public) failed: \(code, privacy: .public)")
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
  // Product Sync's native steps; TypeScript sequences synchronization.
  @objc(createKeyRing:rejecter:)
  func createKeyRing(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("createKeyRing", resolve, reject: reject) { try $0.createKeyRing() }
  }
  @objc(recordInitialization:resolver:rejecter:)
  func recordInitialization(
    _ initialized: Bool, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("recordInitialization", resolve, reject: reject) {
      try $0.recordInitialization(initialized)
    }
  }
  @objc(reenroll:rejecter:)
  func reenroll(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("reenroll", resolve, reject: reject) { try await $0.reenroll() }
  }
  @objc(beginEnrollment:resolver:rejecter:)
  func beginEnrollment(
    _ notice: String?, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("beginEnrollment", resolve, reject: reject) {
      try $0.beginEnrollment(notice: notice)
    }
  }
  @objc(openEnrollment:resolver:rejecter:)
  func openEnrollment(
    _ approval: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("openEnrollment", resolve, reject: reject) {
      ["opened": try $0.openEnrollment(approval)]
    }
  }
  @objc(confirmAdmission:rejecter:)
  func confirmAdmission(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("confirmAdmission", resolve, reject: reject) {
      ["admitted": try await $0.confirmAdmission()]
    }
  }
  @objc(recoverPendingDevice:resolver:rejecter:)
  func recoverPendingDevice(
    _ entry: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("recoverPendingDevice", resolve, reject: reject) {
      ["rejected": try await $0.recoverPendingDevice(entry)]
    }
  }
  @objc(recoverTrustedDevice:envelope:resolver:rejecter:)
  func recoverTrustedDevice(
    _ entry: String, envelope: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("recoverTrustedDevice", resolve, reject: reject) {
      ["rejected": try await $0.recoverTrustedDevice(entry, envelope: envelope)]
    }
  }
  @objc(readsAsEnrollmentCode:resolver:rejecter:)
  func readsAsEnrollmentCode(
    _ entry: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("readsAsEnrollmentCode", resolve, reject: reject) { $0.readsAsEnrollmentCode(entry) }
  }
  @objc(sealEnrollment:request:resolver:rejecter:)
  func sealEnrollment(
    _ code: String, request: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("sealEnrollment", resolve, reject: reject) {
      try $0.sealEnrollment(code, request: request)
    }
  }
  @objc(adoptRotation:resolver:rejecter:)
  func adoptRotation(
    _ envelope: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("adoptRotation", resolve, reject: reject) { try $0.adoptRotation(envelope) }
  }
  @objc(settleRevocation:resolver:rejecter:)
  func settleRevocation(
    _ keyEpoch: Double, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("settleRevocation", resolve, reject: reject) {
      guard let epoch = Int(exactly: keyEpoch) else { throw RegistrationError.unavailable }
      try $0.settleRevocation(keyEpoch: epoch)
    }
  }
  @objc(adoptIdentity:rejecter:)
  func adoptIdentity(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("adoptIdentity", resolve, reject: reject) { try $0.adoptIdentity() }
  }
  @objc(prepareRevocation:resolver:rejecter:)
  func prepareRevocation(
    _ proposal: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("prepareRevocation", resolve, reject: reject) {
      try $0.prepareRevocation(proposal)
    }
  }
  @objc(submitRevocation:resolver:rejecter:)
  func submitRevocation(
    _ entry: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("submitRevocation", resolve, reject: reject) { try $0.submitRevocation(entry) }
  }
  @objc(withdrawRevocation:rejecter:)
  func withdrawRevocation(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("withdrawRevocation", resolve, reject: reject) { try $0.withdrawRevocation() }
  }
  @objc(discardRevocation:rejecter:)
  func discardRevocation(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("discardRevocation", resolve, reject: reject) { try $0.discardRevocation() }
  }
  @objc(finishSynchronization:rejecter:)
  func finishSynchronization(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("finishSynchronization", resolve, reject: reject) { $0.finishSynchronization() }
  }
  @objc(sealMailboxDescriptor:descriptor:resolver:rejecter:)
  func sealMailboxDescriptor(
    _ record: String, descriptor: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("sealMailboxDescriptor", resolve, reject: reject) {
      try $0.sealMailboxDescriptor(record, descriptor)
    }
  }
  @objc(openMailboxDescriptors:resolver:rejecter:)
  func openMailboxDescriptors(
    _ records: [Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("openMailboxDescriptors", resolve, reject: reject) {
      try $0.openMailboxDescriptors(records)
    }
  }
  @objc(recordMailboxChanges:settledRemovals:resolver:rejecter:)
  func recordMailboxChanges(
    _ connections: [[String: Any]], settledRemovals: [String],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("recordMailboxChanges", resolve, reject: reject) {
      try $0.recordMailboxChanges(connections: connections, settledRemovals: settledRemovals)
    }
  }
  @objc(purgeMailbox:resolver:rejecter:)
  func purgeMailbox(
    _ connection: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("purgeMailbox", resolve, reject: reject) { try await $0.purgeMailbox(connection) }
  }
  @objc(removeQueuedPushRoutes:rejecter:)
  func removeQueuedPushRoutes(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("removeQueuedPushRoutes", resolve, reject: reject) {
      try await $0.removeQueuedPushRoutes()
    }
  }
  @objc(recordMailboxReadback:confirmed:epochs:resolver:rejecter:)
  func recordMailboxReadback(
    _ addresses: [String], confirmed: [String: String], epochs: [String: String],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("recordMailboxReadback", resolve, reject: reject) {
      try $0.recordMailboxReadback(addresses: addresses, confirmed: confirmed, epochs: epochs)
    }
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
  @objc(signInMailbox:suggest:provider:resolver:rejecter:)
  func signInMailbox(
    _ connection: String?, suggest: Bool, provider: String,
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("signInMailbox", resolve, reject: reject) {
      guard let provider = MailProvider(rawValue: provider) else {
        throw RegistrationError.unavailable
      }
      return try await $0.signInMailbox(connection, suggest: suggest, provider: provider)
    }
  }
  @objc(verifyMailbox:rejecter:)
  func verifyMailbox(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("verifyMailbox", resolve, reject: reject) { try await $0.verifyMailbox() }
  }
  @objc(confirmMailbox:resolver:rejecter:)
  func confirmMailbox(
    _ connection: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("confirmMailbox", resolve, reject: reject) { try $0.confirmMailbox(connection) }
  }
  // `setup` names the reviewed endpoint, the mailbox address and the password, which goes no
  // further than this device's registration record.
  @objc(connectImap:resolver:rejecter:)
  func connectImap(
    _ setup: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("connectImap", resolve, reject: reject) {
      guard let address = setup["address"] as? String, let host = setup["host"] as? String,
        let port = (setup["port"] as? Double).flatMap({ Int(exactly: $0) }),
        let username = setup["username"] as? String, let password = setup["password"] as? String,
        let smtp = setup["smtp"] as? [String: Any], let smtpHost = smtp["host"] as? String,
        let smtpPort = (smtp["port"] as? Double).flatMap({ Int(exactly: $0) }),
        let security = smtp["security"] as? String, ["tls", "starttls"].contains(security),
        let smtpUsername = smtp["username"] as? String,
        smtp["password"] == nil || smtp["password"] is String
      else { throw RegistrationError.unavailable }
      return try await $0.connectImap(
        address: address, account: ImapAccount(host: host, port: port, username: username),
        password: password,
        smtp: SmtpAccount(
          host: smtpHost, port: smtpPort, startTLS: security == "starttls", username: smtpUsername),
        smtpPassword: smtp["password"] as? String)
    }
  }
  @objc(verifyImap:resolver:rejecter:)
  func verifyImap(
    _ connection: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("verifyImap", resolve, reject: reject) { try await $0.verifyImap(connection) }
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
    perform("prepareSignOut", resolve, reject: reject) { try $0.prepareSignOut() }
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
  @objc(routeMailboxes:rejecter:)
  func routeMailboxes(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("routeMailboxes", resolve, reject: reject) { try await Self.route($0) }
  }
  @objc(stopMailboxWatches:rejecter:)
  func stopMailboxWatches(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("stopMailboxWatches", resolve, reject: reject) {
      try await $0.stopMailboxWatches()
    }
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
}

extension UnwiredRegistration {
  @objc static func requiresMainQueueSetup() -> Bool { true }

  private static var microsoftClientID: String {
    Bundle.main.object(forInfoDictionaryKey: "UnwiredMicrosoftClientID") as? String ?? ""
  }

  // Hosts offer Microsoft mail only when this build can authorize it.
  @objc func constantsToExport() -> [AnyHashable: Any]! {
    #if UNWIRED_REGISTRATION_MOCK
      ["microsoftMail": true]
    #else
      ["microsoftMail": !Self.microsoftClientID.isEmpty]
    #endif
  }

  // Routes with this process's APNs registration and the build's Cloud Pub/Sub topic; without a
  // fully qualified topic this build registers no routes.
  @MainActor private static func route(_ store: RegistrationStore, deviceChanged: Bool = false)
    async throws
  {
    let topic = (Bundle.main.object(forInfoDictionaryKey: "UnwiredGmailTopic") as? String)
      .flatMap { topic in
        topic.range(of: topicPattern, options: .regularExpression) == nil ? nil : topic
      }
    let now = Date().timeIntervalSince1970 * 1_000
    if deviceChanged {
      try await store.pushDeviceChanged(device: PushWakes.shared.device, topic: topic, now: now)
    } else {
      try await store.routeMailboxes(device: PushWakes.shared.device, topic: topic, now: now)
    }
  }

  // A token that arrives or rotates after this process routed reaches the relay at once, rather
  // than at the next verification. Before the store opens, that verification routes with it.
  @MainActor static func pushDeviceChanged() {
    guard let store = sharedStore else { return }
    Task { @MainActor in
      do { try await operations.perform { try await route(store, deviceChanged: true) } } catch {
        logger.error("Gmail push rerouting failed")
      }
    }
  }

  private static let topicPattern =
    "^projects/[a-z][a-z0-9-]{4,28}[a-z0-9]/topics/[A-Za-z][A-Za-z0-9._~%+-]{2,254}$"

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

  // Long server work, an IDLE wait or a search across folders, that must not stall other mailbox
  // work behind the registration gate. Only the store is obtained under the gate; the IMAP work
  // checks the connection and its generation synchronously before and after its network wait.
  private func ungatedMailbox(
    _ name: String, _ resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock,
    operation: @escaping @MainActor (RegistrationStore) async throws -> [String: Any]
  ) {
    DispatchQueue.main.async {
      Task { @MainActor in
        do {
          let store = try await Self.operations.perform { try await self.store() }
          resolve(try await operation(store))
        } catch {
          Self.rejectMailbox(name, error, reject)
        }
      }
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
    // A removal moved the account to a newer key epoch; TypeScript adopts it before retrying.
    case ProductSyncWriteFailure.keyRotationRequired:
      reject("key-rotation-required", "Private sync moved to newer keys.", nil)
    case let error as ImapFailure:
      reject(error.code, "The mail server could not be read.", nil)
    case let error as SmtpFailure:
      reject(error.code, "The outgoing mail server did not take the message.", nil)
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

  // A Graph read shares Gmail reads' cancellation by request name.
  @objc(graphRequest:mailbox:resolver:rejecter:)
  func graphRequest(
    _ url: String, mailbox scope: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    let request = scope["request"] as? String
    if let request,
      request.count > 200
        || request.range(of: "^[0-9A-Za-z:-]+$", options: .regularExpression) == nil
    {
      reject("unavailable", "Microsoft mail could not be reached.", nil)
      return
    }
    mailbox("graphRequest", resolve, reject: reject, request: request) {
      let (connection, address, generation) = try Self.scope(scope)
      return try await $0.graph(
        url: url, connection: connection, address: address, generation: generation)
    }
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

  // `change` names a Microsoft message and exactly one of `read` or `folder`.
  @objc(graphModify:mailbox:resolver:rejecter:)
  func graphModify(
    _ change: [String: Any], mailbox scope: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("graphModify", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard let message = change["message"] as? String,
        change["read"] == nil || change["read"] is Bool,
        change["folder"] == nil || change["folder"] is String
      else { throw RegistrationError.unavailable }
      return try await $0.graphModify(
        message: message, read: change["read"] as? Bool, folder: change["folder"] as? String,
        connection: connection, address: address, generation: generation)
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

  // `message` carries `segments` as for gmailSend, and its envelope `recipients`. Not cancellable:
  // once started, its outcome may only be unknown.
  @objc(imapSend:mailbox:resolver:rejecter:)
  func imapSend(
    _ message: [String: Any], mailbox scope: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("imapSend", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard let segments = message["segments"] as? [Any],
        let recipients = message["recipients"] as? [String]
      else { throw RegistrationError.unavailable }
      return try await $0.imapSend(
        segments: segments, recipients: recipients, connection: connection, address: address,
        generation: generation)
    }
  }

  // `request` names the Sent `folder`, the message's MIME `boundary` and, to file it, `segments`.
  @objc(imapFileSent:request:resolver:rejecter:)
  func imapFileSent(
    _ scope: [String: Any], request: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("imapFileSent", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard let folder = request["folder"] as? String,
        let boundary = request["boundary"] as? String,
        let segments = request["segments"] as? [Any]
      else { throw RegistrationError.unavailable }
      return try await $0.imapFileSent(
        segments: segments, folder: folder, boundary: boundary, connection: connection,
        address: address, generation: generation)
    }
  }

  @objc(imapFindSent:request:resolver:rejecter:)
  func imapFindSent(
    _ scope: [String: Any], request: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    ungatedMailbox("imapFindSent", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard let folder = request["folder"] as? String,
        let boundary = request["boundary"] as? String
      else { throw RegistrationError.unavailable }
      return try await $0.imapFindSent(
        folder: folder, boundary: boundary, connection: connection, address: address,
        generation: generation)
    }
  }

  // `message` carries `segments`, each `{ text }` or `{ asset: { id, digest } }`. Not
  // cancellable: once started, its outcome may only be unknown.
  @objc(graphSend:mailbox:resolver:rejecter:)
  func graphSend(
    _ message: [String: Any], mailbox scope: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("graphSend", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard let segments = message["segments"] as? [Any] else {
        throw RegistrationError.unavailable
      }
      return try await $0.graphSend(
        segments: segments, connection: connection, address: address, generation: generation)
    }
  }

  @objc(imapFolders:resolver:rejecter:)
  func imapFolders(
    _ scope: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("imapFolders", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      return try await $0.imapFolders(
        connection: connection, address: address, generation: generation)
    }
  }

  // `request` names the folder, how many of its newest messages to keep, and optionally the
  // checkpoint `{ uidValidity, uidNext, known }` the last committed synchronization reached.
  @objc(imapSynchronize:request:resolver:rejecter:)
  func imapSynchronize(
    _ scope: [String: Any], request: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("imapSynchronize", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard let folder = request["folder"] as? String,
        let window = (request["window"] as? Double).flatMap({ Int(exactly: $0) })
      else { throw RegistrationError.unavailable }
      var from: ImapCheckpoint?
      if let checkpoint = request["from"] as? [String: Any] {
        guard let validity = (checkpoint["uidValidity"] as? Double).flatMap({ UInt32(exactly: $0) }),
          let next = (checkpoint["uidNext"] as? Double).flatMap({ UInt32(exactly: $0) }),
          let known = checkpoint["known"] as? [Double]
        else { throw RegistrationError.unavailable }
        let uids = known.compactMap { UInt32(exactly: $0) }
        guard uids.count == known.count else { throw RegistrationError.unavailable }
        from = ImapCheckpoint(uidValidity: validity, uidNext: next, known: uids)
      }
      return try await $0.imapSynchronize(
        connection: connection, address: address, generation: generation, folder: folder,
        from: from, window: window)
    }
  }

  // `message` names `{ folder, uidValidity, uid }`; a changed UIDVALIDITY reads nothing.
  @objc(imapMessage:message:resolver:rejecter:)
  func imapMessage(
    _ scope: [String: Any], message: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("imapMessage", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard let folder = message["folder"] as? String,
        let validity = (message["uidValidity"] as? Double).flatMap({ UInt32(exactly: $0) }),
        let uid = (message["uid"] as? Double).flatMap({ UInt32(exactly: $0) })
      else { throw RegistrationError.unavailable }
      return try await $0.imapMessage(
        connection: connection, address: address, generation: generation, folder: folder,
        uidValidity: validity, uid: uid)
    }
  }

  // `change` names `{ folder, uidValidity, uid }` and exactly one of `read` or `destination`.
  @objc(imapModify:change:resolver:rejecter:)
  func imapModify(
    _ scope: [String: Any], change: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("imapModify", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard let folder = change["folder"] as? String,
        let validity = (change["uidValidity"] as? Double).flatMap({ UInt32(exactly: $0) }),
        let uid = (change["uid"] as? Double).flatMap({ UInt32(exactly: $0) }),
        change["read"] == nil || change["read"] is Bool,
        change["destination"] == nil || change["destination"] is String
      else { throw RegistrationError.unavailable }
      let copied: ImapCopy?
      if let value = change["copied"] {
        guard let receipt = value as? [String: Any],
          let copiedValidity = (receipt["uidValidity"] as? Double).flatMap({ UInt32(exactly: $0) }),
          let copiedUID = (receipt["uid"] as? Double).flatMap({ UInt32(exactly: $0) }),
          copiedValidity > 0, copiedUID > 0
        else { throw RegistrationError.unavailable }
        copied = ImapCopy(uidValidity: copiedValidity, uid: copiedUID)
      } else {
        copied = nil
      }
      return try await $0.imapModify(
        connection: connection, address: address, generation: generation,
        change: ImapChange(
          folder: folder, uidValidity: validity, uid: uid, read: change["read"] as? Bool,
          destination: change["destination"] as? String, copied: copied))
    }
  }

  // `request` names the `query` and the `folders` to search, in order.
  @objc(imapSearch:request:resolver:rejecter:)
  func imapSearch(
    _ scope: [String: Any], request: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    ungatedMailbox("imapSearch", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard let query = request["query"] as? String, let folders = request["folders"] as? [String]
      else { throw RegistrationError.unavailable }
      return try await $0.imapSearch(
        connection: connection, address: address, generation: generation, query: query,
        folders: folders)
    }
  }

  // `request` names the `folder` to watch and the most `seconds` to wait.
  @objc(imapIdle:request:resolver:rejecter:)
  func imapIdle(
    _ scope: [String: Any], request: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    ungatedMailbox("imapIdle", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      guard let folder = request["folder"] as? String,
        let seconds = (request["seconds"] as? Double).flatMap({ Int(exactly: $0) })
      else { throw RegistrationError.unavailable }
      return try await $0.imapIdle(
        connection: connection, address: address, generation: generation, folder: folder,
        seconds: seconds)
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

  // The routes a wake may name, read under the gate so a removal in progress is never missed.
  @objc(mailboxRoutes:rejecter:)
  func mailboxRoutes(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("mailboxRoutes", resolve, reject: reject) {
      try $0.mailboxRoutes(now: Date().timeIntervalSince1970 * 1_000)
    }
  }

  // Resolves with the next wake hint, or null for a reader a reloaded JavaScript context replaced.
  @objc(nextWake:rejecter:)
  func nextWake(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    Task { @MainActor in resolve(await PushWakes.shared.next().map(PushWakes.hint) ?? NSNull()) }
  }

  @objc(completeWake:result:)
  func completeWake(_ id: String, result: String) {
    Task { @MainActor in
      PushWakes.shared.settle(id, ["synchronized", "ignored"].contains(result) ? result : "failed")
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

  // The message and exact source a remote content call names below its mailbox.
  private static func resource(_ resource: [String: Any]) throws -> (String, String) {
    guard let id = resource["id"] as? String, let url = resource["url"] as? String else {
      throw RegistrationError.unavailable
    }
    return (id, url)
  }

  @objc(openRemoteContent:resource:resolver:rejecter:)
  func openRemoteContent(
    _ scope: [String: Any], resource: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("openRemoteContent", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      let (id, url) = try Self.resource(resource)
      return try await $0.openRemoteContent(
        connection: connection, address: address, generation: generation, id: id, url: url)
    }
  }

  @objc(touchRemoteContent:resource:resolver:rejecter:)
  func touchRemoteContent(
    _ scope: [String: Any], resource: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("touchRemoteContent", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      let (id, url) = try Self.resource(resource)
      return try await $0.touchRemoteContent(
        connection: connection, address: address, generation: generation, id: id, url: url)
    }
  }

  @objc(commitRemoteContent:resource:admission:resolver:rejecter:)
  func commitRemoteContent(
    _ scope: [String: Any], resource: [String: Any], admission: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("commitRemoteContent", resolve, reject: reject) {
      let (connection, address, generation) = try Self.scope(scope)
      let (id, url) = try Self.resource(resource)
      return try await $0.commitRemoteContent(
        connection: connection, address: address, generation: generation, id: id, url: url,
        admission: admission)
    }
  }

  // Checks the mailbox under the operation gate, then fetches without holding it, so a slow image
  // server never stalls Gmail or registration, and checks the mailbox again before resolving.
  @objc(fetchRemoteContent:url:request:resolver:rejecter:)
  func fetchRemoteContent(
    _ scope: [String: Any], url: String, request: [String: Any], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.main.async {
      guard let session = request["session"] as? String,
        let requestID = request["request"] as? String,
        let key = try? Self.remoteLoadKey(scope, session: session)
      else {
        reject("refused", "The image cannot be loaded.", nil)
        return
      }
      let load = Self.remoteLoads[key] ?? RemoteLoad()
      let budget = load.budget
      Self.remoteLoads[key] = load
      guard load.requests[requestID] == nil else {
        reject("refused", "The image cannot be loaded.", nil)
        return
      }
      load.requests[requestID] = Task { @MainActor in
        defer { load.requests.removeValue(forKey: requestID) }
        do {
          let (connection, address, generation) = try Self.scope(scope)
          let owned = {
            try await Self.operations.perform {
              try await self.store().remoteContentOwner(
                connection: connection, address: address, generation: generation)
            }
          }
          try Task.checkCancellation()
          try budget.checkDeadline()
          try await owned()
          #if UNWIRED_REGISTRATION_MOCK || UNWIRED_ASSISTANCE_MOCK
            // Every mock scenario build stays deterministic and never reaches a real server.
            throw RemoteContentError.refused
          #else
            guard let target = URL(string: url) else { throw RemoteContentError.refused }
            let data = try await RemoteContentFetcher(
              exchange: { try await RemoteTransport(budget: budget).exchange($0) },
              budget: budget
            ).fetch(target)
            try Task.checkCancellation()
            try await owned()
            resolve(["data": data.base64EncodedString()])
          #endif
        } catch RemoteContentError.refused {
          reject("refused", "The image cannot be loaded.", nil)
        } catch RemoteContentError.unavailable {
          reject("unavailable", "The image could not be reached.", nil)
        } catch {
          Self.rejectMailbox("fetchRemoteContent", error, reject)
        }
      }
    }
  }

  private static func remoteLoadKey(_ scope: [String: Any], session: String) throws -> String {
    let (connection, address, generation) = try Self.scope(scope)
    return try JSONEncoder().encode([connection, address, generation, session]).base64EncodedString()
  }

  @objc(cancelRemoteContent:session:finished:resolver:rejecter:)
  func cancelRemoteContent(
    _ scope: [String: Any], session: String, finished: Bool, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.main.async {
      do {
        let key = try Self.remoteLoadKey(scope, session: session)
        if let load = Self.remoteLoads[key] {
          for task in load.requests.values { task.cancel() }
          load.requests.removeAll()
          if finished { Self.remoteLoads.removeValue(forKey: key) }
        }
        resolve([:])
      } catch { Self.rejectMailbox("cancelRemoteContent", error, reject) }
    }
  }

  @objc(clearRemoteContent:rejecter:)
  func clearRemoteContent(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("clearRemoteContent", resolve, reject: reject) {
      try await $0.clearRemoteContent()
      return [:]
    }
  }

  // The device-local remote content policies, as TypeScript encoded them; never synchronized.
  private static let remoteContentSettingsKey = "dev.unwired.remote-content-settings"

  @objc(remoteContentSettings:rejecter:)
  func remoteContentSettings(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    let settings = UserDefaults.standard.string(forKey: Self.remoteContentSettingsKey)
    resolve(["settings": settings.map { $0 as Any } ?? NSNull()])
  }

  @objc(setRemoteContentSettings:resolver:rejecter:)
  func setRemoteContentSettings(
    _ settings: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    UserDefaults.standard.set(settings, forKey: Self.remoteContentSettingsKey)
    resolve([:])
  }

  // Mail Assistance Enablement for the signed-in Product Account, which `owner` names.
  @objc(mailAssistance:rejecter:)
  func mailAssistance(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("mailAssistance", resolve, reject: reject) { try $0.mailAssistance() }
  }

  @objc(setMailAssistance:profiles:resolver:rejecter:)
  func setMailAssistance(
    _ owner: String, profiles: [String], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("setMailAssistance", resolve, reject: reject) {
      try $0.setMailAssistance(owner: owner, profiles: profiles)
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

  // Native Draft sync's Product Sync calls; each carries the device proof, and Convex sees only
  // opaque payloads.
  @MainActor private static func productSync(base: URL) -> ProductSyncBackend {
    func proof(_ product: ProductRegistrationReceipt) -> [String: Any] {
      RegistrationStore.proof(product)
    }
    func json(_ payload: EncryptedPayload) throws -> Any {
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
    }
    return ProductSyncBackend(
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
}
