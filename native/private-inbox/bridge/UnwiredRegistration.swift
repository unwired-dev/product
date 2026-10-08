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

  func gmail(_ identity: GoogleRegistrationIdentity, url: URL, body: Data?) async throws -> (
    Int, Data
  ) {
    try await GmailTransport.send(
      token: identity.accessToken, url: url, body: body, session: mailSession)
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

// The Convex HTTP API response; ConvexError data carries a stable code.
private struct ConvexEnvelope<Value: Decodable>: Decodable {
  struct Failure: Decodable { let code: String }
  let status: String
  let value: Value?
  let errorData: Failure?
}

@objc(UnwiredRegistration)
final class UnwiredRegistration: NSObject {
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.unwired.mail", category: "registration")
  @MainActor private static var busy = false
  @MainActor private static let operations = RegistrationOperationGate()
  @MainActor private static var sharedStore: RegistrationStore?

  @MainActor private func store() throws -> RegistrationStore {
    if let store = Self.sharedStore { return store }
    #if UNWIRED_REGISTRATION_MOCK
      guard let bundle = Bundle.main.bundleIdentifier,
        let scenario = Bundle.main.object(forInfoDictionaryKey: "UnwiredMockScenario") as? String
      else { throw RegistrationError.unavailable }
      let store = try mockRegistrationStore(
        bundle: bundle, scenario: scenario, mailCache: try? UnwiredPrivateInbox.store())
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
        linking: SignInLinking(
          request: { identity, product, provider in
            struct Response: Decodable {
              let linkTicket: String?
              let signInProviders: [SignInProvider]
            }
            let response: Response = try await Self.signInLink(
              base: base, identity: identity, operation: "request",
              args: [
                "provider": provider.rawValue, "trustedDeviceId": product.trustedDeviceId,
                "trustedDeviceCredential": product.trustedDeviceCredential,
              ])
            return SignInLinkRequest(
              linkTicket: response.linkTicket, signInProviders: response.signInProviders)
          },
          complete: { identity, product, ticket in
            struct Response: Decodable {
              let productAccountId: String
              let signInProviders: [SignInProvider]
            }
            let response: Response = try await Self.signInLink(
              base: base, identity: identity, operation: "complete",
              args: [
                "linkTicket": ticket, "trustedDeviceId": product.trustedDeviceId,
                "trustedDeviceCredential": product.trustedDeviceCredential,
              ])
            guard response.productAccountId == product.productAccountId else {
              throw RegistrationError.invalidIdentity
            }
            return response.signInProviders
          }),
        productSync: Self.productSync(base: base),
        removal: Self.removal(base: base, bundle: bundle),
        deviceRevoked: { product in
          try await Self.mutation(
            base: base, identity: nil, path: "productAccount:isTrustedDeviceRevoked",
            args: [
              "productAccountId": product.productAccountId,
              "trustedDeviceId": product.trustedDeviceId,
              "trustedDeviceCredential": product.trustedDeviceCredential,
            ], function: "query")
        },
        mailCache: try? UnwiredPrivateInbox.store(),
        connect: { identity, deviceIdentifier, previous in
          try await Self.connect(
            base: base, identity: identity, deviceIdentifier: deviceIdentifier,
            previous: previous)
        })
      Self.sharedStore = store
      return store
    #endif
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

  @MainActor private static func signInLink<Value: Decodable>(
    base: URL, identity: ProductSignInIdentity, operation: String, args: [String: Any]
  ) async throws -> Value {
    var request = URLRequest(url: try site(base, path: "/sign-in-links/" + operation))
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer " + identity.idToken, forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: args)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let result = try? JSONDecoder().decode(ConvexEnvelope<Value>.self, from: data) else {
      throw RegistrationError.unavailable
    }
    if result.status == "success", let value = result.value,
      (response as? HTTPURLResponse)?.statusCode == 200
    {
      return value
    }
    throw result.errorData.flatMap { backendErrors[$0.code] } ?? RegistrationError.unavailable
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
    var request = URLRequest(url: base.appending(path: "api/" + function))
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let identity {
      request.setValue("Bearer " + identity.idToken, forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "path": path, "args": args, "format": "json",
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    // Application errors carry a code in errorData whatever the HTTP status.
    guard let result = try? JSONDecoder().decode(ConvexEnvelope<Value>.self, from: data) else {
      throw RegistrationError.unavailable
    }
    if result.status == "success", (response as? HTTPURLResponse)?.statusCode == 200 {
      return result.value
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
    var args: [String: Any] = [
      "deviceIdentifier": deviceIdentifier, "platform": platform,
      "supportsDeviceCredentials": true,
    ]
    if let previous {
      args[previous.pending == true ? "pendingDeviceCredential" : "trustedDeviceCredential"] =
        previous.trustedDeviceCredential
      // A reconnect never creates or reaches another Product Account.
      args["expectedProductAccountId"] = previous.productAccountId
    }
    // A device the account has not admitted connects as a Pending Device.
    struct Response: Decodable {
      let productAccountId: String
      let trustedDeviceId: String?
      let trustedDeviceCredential: String?
      let pendingDeviceId: String?
      let pendingDeviceCredential: String?
      let signInProviders: [SignInProvider]?
      let productSyncMaterialInitialized: Bool?
    }
    let response: Response = try await mutation(
      base: base, identity: identity, path: "productAccount:connect", args: args)
    let pending = response.pendingDeviceId != nil
    guard
      let deviceId = response.trustedDeviceId ?? response.pendingDeviceId,
      let credential = response.trustedDeviceCredential ?? response.pendingDeviceCredential,
      !response.productAccountId.isEmpty, !deviceId.isEmpty,
      credential.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    else { throw RegistrationError.unavailable }
    return ProductRegistrationReceipt(
      productAccountId: response.productAccountId, trustedDeviceId: deviceId,
      trustedDeviceCredential: credential, pending: pending ? true : nil,
      signInProviders: response.signInProviders,
      productSyncMaterialInitialized: response.productSyncMaterialInitialized)
  }

  private func perform(
    _ name: String, _ resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock,
    operation: @escaping @MainActor (RegistrationStore) async throws -> [String: String]
  ) {
    Task { @MainActor in
      guard !Self.busy else {
        reject("busy", "Authorization is already running.", nil)
        return
      }
      Self.busy = true
      defer { Self.busy = false }
      do {
        let removal: AccountRemovalState.Operation? =
          name == "signOut" ? .signOut : name == "deleteProductAccount" ? .deletion : nil
        resolve(
          try await Self.operations.perform {
            try await store().purgingIfRevoked(operation, removing: removal)
          })
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
          ?? ((error as? PrivateInboxError) == .locked ? "locked" : "unavailable")
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
  }

  @objc(restore:rejecter:)
  func restore(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock)
  {
    perform("restore", resolve, reject: reject) { try await $0.restore() }
  }
  @objc(signIn:resolver:rejecter:)
  func signIn(
    _ provider: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("signIn", resolve, reject: reject) {
      guard let provider = SignInProvider(rawValue: provider) else {
        throw RegistrationError.unavailable
      }
      return try await $0.signIn(with: provider)
    }
  }
  @objc(link:resolver:rejecter:)
  func link(
    _ provider: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("link", resolve, reject: reject) {
      guard let provider = SignInProvider(rawValue: provider) else {
        throw RegistrationError.unavailable
      }
      return try await $0.link(provider)
    }
  }
  @objc(confirmRecoveryKey:resolver:rejecter:)
  func confirmRecoveryKey(
    _ entry: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("confirmRecoveryKey", resolve, reject: reject) { try $0.confirmRecoveryKey(entry) }
  }
  @objc(approveEnrollment:code:resolver:rejecter:)
  func approveEnrollment(
    _ requestId: String, code: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("approveEnrollment", resolve, reject: reject) {
      try await $0.approveEnrollment(requestId, code: code)
    }
  }
  @objc(declineEnrollment:resolver:rejecter:)
  func declineEnrollment(
    _ requestId: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("declineEnrollment", resolve, reject: reject) {
      try await $0.declineEnrollment(requestId)
    }
  }
  @objc(revokeTrustedDevice:resolver:rejecter:)
  func revokeTrustedDevice(
    _ trustedDeviceId: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("revokeTrustedDevice", resolve, reject: reject) {
      try await $0.revoke(trustedDeviceId)
    }
  }
  @objc(signOut:rejecter:)
  func signOut(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock)
  {
    perform("signOut", resolve, reject: reject) { try await $0.signOut() }
  }
  @objc(deleteProductAccount:rejecter:)
  func deleteProductAccount(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("deleteProductAccount", resolve, reject: reject) { try await $0.deleteAccount() }
  }
  @objc(refreshPrivateSync:rejecter:)
  func refreshPrivateSync(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("refreshPrivateSync", resolve, reject: reject) { try await $0.refreshPrivateSync() }
  }
  @objc(addMailbox:resolver:rejecter:)
  func addMailbox(
    _ chooseAccount: Bool, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("addMailbox", resolve, reject: reject) {
      try await $0.authorizeGmail(chooseAccount: chooseAccount)
    }
  }
  @objc(authorizeGmail:resolver:rejecter:)
  func authorizeGmail(
    _ connection: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("authorizeGmail", resolve, reject: reject) {
      try await $0.authorizeGmail(connection: connection)
    }
  }
  @objc(removeMailbox:resolver:rejecter:)
  func removeMailbox(
    _ connection: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("removeMailbox", resolve, reject: reject) { try await $0.removeMailbox(connection) }
  }
}

extension UnwiredRegistration {
  @objc static func requiresMainQueueSetup() -> Bool { true }

  // Mailbox preflight and registration changes share custody across all suspension points.
  private func mailbox(
    _ name: String, _ resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock,
    operation: @escaping @MainActor (RegistrationStore) async throws -> [String: Any]
  ) {
    Task { @MainActor in
      do {
        resolve(try await Self.operations.perform { try await operation(store()) })
      } catch {
        switch error {
        case RegistrationError.revoked:
          reject("mailbox-revoked", "This device no longer has access.", nil)
        case RegistrationError.gmailUnavailable:
          reject("gmail-unavailable", "Gmail needs authorization again.", nil)
        case PrivateInboxError.locked: reject("locked", "Private storage is locked.", nil)
        case PrivateInboxError.conflict: reject("conflict", "The mailbox changed.", nil)
        case PrivateInboxError.mailboxInvalidated:
          reject("mailbox-invalidated", "The mailbox is no longer available.", nil)
        default:
          Self.logger.error("\(name, privacy: .public) failed: unavailable")
          reject("unavailable", "Gmail could not be reached.", nil)
        }
      }
    }
  }

  @objc(gmailRequest:query:mailbox:resolver:rejecter:)
  func gmailRequest(
    _ path: String, query: [Any], mailbox scope: [String: Any],
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("gmailRequest", resolve, reject: reject) {
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

  @objc(commitDrafts:expectedRevision:document:resolver:rejecter:)
  func commitDrafts(
    _ owner: String, expectedRevision: Double, document: String,
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    mailbox("commitDrafts", resolve, reject: reject) {
      guard let revision = Int(exactly: expectedRevision), revision >= 0 else {
        throw RegistrationError.unavailable
      }
      return try await $0.commitDrafts(owner: owner, expectedRevision: revision, document: document)
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

  @objc(recoverWithRecoveryKey:resolver:rejecter:)
  func recoverWithRecoveryKey(
    _ entry: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("recoverWithRecoveryKey", resolve, reject: reject) { try await $0.recover(with: entry) }
  }

  // Every Product Sync call carries the device proof; Convex sees only opaque payloads.
  // The transport factory assembles all authenticated operations with the same device proof.
  // swiftlint:disable:next function_body_length
  @MainActor private static func productSync(base: URL) -> ProductSyncBackend {
    func proof(_ product: ProductRegistrationReceipt) -> [String: Any] {
      Self.proof(product)
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
      })
  }

  // A Trusted Device's proof, or a Pending Device's for its own admission and removal.
  @MainActor private static func proof(_ product: ProductRegistrationReceipt) -> [String: Any] {
    product.pending == true
      ? [
        "pendingDeviceId": product.trustedDeviceId,
        "pendingDeviceCredential": product.trustedDeviceCredential,
      ]
      : [
        "trustedDeviceId": product.trustedDeviceId,
        "trustedDeviceCredential": product.trustedDeviceCredential,
      ]
  }

  @MainActor private static func removal(base: URL, bundle: String) -> AccountRemoval {
    AccountRemoval(
      unregister: { identity, product, deviceIdentifier in
        struct Response: Decodable { let registered: Bool }
        let _: Response = try await mutation(
          base: base, identity: identity,
          path: product.pending == true
            ? "productAccount:unregisterPendingDevice" : "productAccount:unregisterTrustedDevice",
          args: proof(product).merging(["deviceIdentifier": deviceIdentifier]) { $1 }
        )
      },
      delete: { identity, product in
        var request = URLRequest(url: try site(base, path: "/product-account/delete"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The fresh token is the recent-authentication proof.
        request.setValue("Bearer " + identity.idToken, forHTTPHeaderField: "Authorization")
        var args = proof(product)
        if let code = identity.authorizationCode {
          // Convex exchanges and revokes it with the client that issued it.
          args["authorizationCode"] = code
          args["appleClientId"] = bundle
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: args)
        let (data, response) = try await URLSession.shared.data(for: request)
        struct Failure: Decodable { let code: String }
        switch (response as? HTTPURLResponse)?.statusCode {
        // Complete, or continuing on the backend; the account is fenced either way.
        case 200:
          struct Response: Decodable { let deleted: Bool }
          _ = try JSONDecoder().decode(Response.self, from: data)
          return
        case 401: throw RegistrationError.staleAuthentication
        // Refusals Convex returns before fencing the account.
        case 400: throw RegistrationError.removalRefused
        case 403:
          throw (try? JSONDecoder().decode(Failure.self, from: data)).flatMap {
            backendErrors[$0.code]
          } ?? RegistrationError.removalRefused
        case 409: throw RegistrationError.appleAuthorizationRequired
        // Repeating the deletion after a lost reply reports it as complete.
        default: throw RegistrationError.unavailable
        }
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
