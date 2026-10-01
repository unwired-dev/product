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
      throw RegistrationError.unavailable
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
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
        throw RegistrationError.gmailUnavailable
      }
      profile = try JSONDecoder().decode(Profile.self, from: data)
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw RegistrationError.gmailUnavailable
    }
    return GmailRegistrationReceipt(subject: identity.subject, address: profile.emailAddress)
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
  @MainActor private static var sharedStore: RegistrationStore?
  @objc static func requiresMainQueueSetup() -> Bool { true }

  @MainActor private func store() throws -> RegistrationStore {
    if let store = Self.sharedStore { return store }
    #if UNWIRED_REGISTRATION_MOCK
      guard let bundle = Bundle.main.bundleIdentifier,
        let scenario = Bundle.main.object(forInfoDictionaryKey: "UnwiredMockScenario") as? String
      else { throw RegistrationError.unavailable }
      let store = try mockRegistrationStore(bundle: bundle, scenario: scenario)
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
            let response: Response = try await Self.mutation(
              base: base, identity: identity, path: "signInLinks:request",
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
            let response: Response = try await Self.mutation(
              base: base, identity: identity, path: "signInLinks:complete",
              args: [
                "linkTicket": ticket, "trustedDeviceId": product.trustedDeviceId,
                "trustedDeviceCredential": product.trustedDeviceCredential,
              ])
            guard response.productAccountId == product.productAccountId else {
              throw RegistrationError.invalidIdentity
            }
            return response.signInProviders
          }),
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
  ]

  @MainActor private static func mutation<Value: Decodable>(
    base: URL, identity: ProductSignInIdentity, path: String, args: [String: Any]
  ) async throws -> Value {
    var request = URLRequest(url: base.appending(path: "api/mutation"))
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer " + identity.idToken, forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "path": path, "args": args, "format": "json",
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    // Application errors carry a code in errorData whatever the HTTP status.
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
      args["trustedDeviceCredential"] = previous.trustedDeviceCredential
      // A reconnect never creates or reaches another Product Account.
      args["expectedProductAccountId"] = previous.productAccountId
    }
    let product: ProductRegistrationReceipt = try await mutation(
      base: base, identity: identity, path: "productAccount:connect", args: args)
    guard !product.productAccountId.isEmpty, !product.trustedDeviceId.isEmpty,
      product.trustedDeviceCredential.range(of: "^[0-9a-f]{64}$", options: .regularExpression)
        != nil
    else { throw RegistrationError.unavailable }
    return product
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
      do { resolve(try await operation(store())) } catch {
        // Descriptions stay private: SDK and transport errors can echo request details.
        let failure = error as NSError
        Self.logger.error(
          """
          \(name, privacy: .public) failed: \(failure.domain, privacy: .public) \
          \(failure.code, privacy: .public) \(failure.localizedDescription, privacy: .private)
          """)
        let code = (error as? RegistrationError)?.code ?? "unavailable"
        reject(
          code,
          code == "cancelled"
            ? "Sign-in was cancelled."
            : "Registration could not finish. Retry with your saved account.", nil)
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
  @objc(authorizeGmail:resolver:rejecter:)
  func authorizeGmail(
    _ reselect: Bool, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("authorizeGmail", resolve, reject: reject) {
      try await $0.authorizeGmail(reselect: reselect)
    }
  }
}
