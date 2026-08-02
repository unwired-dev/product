import AuthenticationServices
import Foundation

// swiftlint:disable file_length

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(UIKit)
  import UIKit
#endif

struct AuthenticationPresentationWindowSnapshot {
  let anchor: ASPresentationAnchor
  let isKeyWindow: Bool
}
struct AuthenticationPresentationSceneSnapshot {
  let isForegroundActive: Bool
  let windows: [AuthenticationPresentationWindowSnapshot]
}

enum AuthenticationPresentationAnchor {
  typealias Resolver = @MainActor () -> ASPresentationAnchor?

  @MainActor
  static func preferredAnchor(
    in scenes: [AuthenticationPresentationSceneSnapshot]
  ) -> ASPresentationAnchor? {
    for scene in scenes where scene.isForegroundActive {
      if let anchor = scene.windows.first(where: \.isKeyWindow)?.anchor {
        return anchor
      }
    }
    return nil
  }

  @MainActor
  static func current() -> ASPresentationAnchor? {
    #if canImport(UIKit)
      let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      let scenes = windowScenes.map { windowScene in
        return AuthenticationPresentationSceneSnapshot(
          isForegroundActive: windowScene.activationState == .foregroundActive,
          windows: windowScene.windows.map {
            AuthenticationPresentationWindowSnapshot(anchor: $0, isKeyWindow: $0.isKeyWindow)
          }
        )
      }
      return preferredAnchor(in: scenes)
    #elseif canImport(AppKit)
      return NSApplication.shared.keyWindow
    #else
      return nil
    #endif
  }
}

final class AuthenticationPresentationAnchorStore: @unchecked Sendable {
  private let lock = NSLock()
  private let resolve: AuthenticationPresentationAnchor.Resolver
  private var capturedAnchor: ASPresentationAnchor?

  init(
    resolve: @escaping AuthenticationPresentationAnchor.Resolver =
      AuthenticationPresentationAnchor.current
  ) {
    self.resolve = resolve
  }

  @MainActor
  func captureCurrent() -> Bool {
    guard let anchor = resolve() else {
      return false
    }
    lock.withLock {
      capturedAnchor = anchor
    }
    return true
  }

  nonisolated func current() -> ASPresentationAnchor {
    lock.withLock {
      guard let capturedAnchor else {
        preconditionFailure("Authentication presentation anchor requested before capture")
      }
      return capturedAnchor
    }
  }

  nonisolated func clear() {
    lock.withLock {
      capturedAnchor = nil
    }
  }
}

struct AppleSignInCredential: Equatable {
  let authorizationCode: String?
  let appleUserIdentifier: String
  let identityToken: String

  init(
    authorizationCode: String? = nil,
    appleUserIdentifier: String,
    identityToken: String
  ) {
    self.authorizationCode = authorizationCode
    self.appleUserIdentifier = appleUserIdentifier
    self.identityToken = identityToken
  }
}

private struct ProductAccountTokenClaims: Decodable {
  let expiration: TimeInterval

  private enum CodingKeys: String, CodingKey {
    case expiration = "exp"
  }
}

enum AppleIdentityToken {
  static func expirationDate(from identityToken: String) -> Date? {
    let segments = identityToken.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3 else { return nil }

    var encodedClaims = String(segments[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encodedClaims.append(String(repeating: "=", count: (4 - encodedClaims.count % 4) % 4))
    guard
      let claimsData = Data(base64Encoded: encodedClaims),
      let claims = try? JSONDecoder().decode(ProductAccountTokenClaims.self, from: claimsData),
      claims.expiration.isFinite
    else {
      return nil
    }

    return Date(timeIntervalSince1970: claims.expiration)
  }
}

enum AppleSignInError: LocalizedError, Equatable {
  case missingIdentityToken
  case missingAuthorizationCode
  case missingUserIdentifier
  case credentialUnavailable
  case notAuthorized
  case configurationMissing
  case authorizationInProgress
  case presentationAnchorUnavailable

  var errorDescription: String? {
    switch self {
    case .missingAuthorizationCode:
      return "Sign in with Apple did not return an authorization code."
    case .missingIdentityToken:
      return "Sign in with Apple did not return an identity token."
    case .missingUserIdentifier:
      return "Sign in with Apple did not return a user identifier."
    case .credentialUnavailable:
      return "Sign in with Apple credentials are unavailable."
    case .notAuthorized:
      return "Sign in with Apple authorization was revoked."
    case .configurationMissing:
      return """
        Sign in with Apple is not configured for this build. In Xcode, select a \
        Development Team, enable the Sign in with Apple capability, and rebuild. \
        The App ID dev.unwired.mail must also have Sign in with Apple enabled in \
        the Apple Developer portal.
        """
    case .authorizationInProgress:
      return "A Sign in with Apple request is already in progress."
    case .presentationAnchorUnavailable:
      return "Sign in with Apple could not open the authentication window."
    }
  }
}

enum ProductAccountAuthorizationState: Equatable {
  case authorized
  case revoked
  case unauthorized
  case unavailable
}

protocol ProductAccountAuthorizationStateChecking {
  func authorizationState(
    forAppleUserIdentifier appleUserIdentifier: String
  ) async -> ProductAccountAuthorizationState
}

struct AppleAuthorizationStateChecker:
  ProductAccountAuthorizationStateChecking
{
  func authorizationState(
    forAppleUserIdentifier appleUserIdentifier: String
  ) async -> ProductAccountAuthorizationState {
    await Task.detached(priority: .userInitiated) {
      await withCheckedContinuation { continuation in
        ASAuthorizationAppleIDProvider().getCredentialState(
          forUserID: appleUserIdentifier
        ) { state, error in
          guard error == nil else {
            continuation.resume(returning: .unavailable)
            return
          }
          switch state {
          case .authorized:
            continuation.resume(returning: .authorized)
          case .revoked:
            continuation.resume(returning: .revoked)
          case .notFound:
            continuation.resume(returning: .unauthorized)
          case .transferred:
            continuation.resume(returning: .unavailable)
          @unknown default:
            continuation.resume(returning: .unavailable)
          }
        }
      }
    }.value
  }
}

protocol AppleSignInPerforming {
  func signIn() async throws -> AppleSignInCredential
  func restoreSession(snapshot: ProductAccountSessionSnapshot) async throws -> AppleSignInCredential
}

private struct AppleAuthorizationRequest: @unchecked Sendable {
  let controller: ASAuthorizationController

  func perform() {
    controller.performRequests()
  }
}

@MainActor
final class SignInWithAppleService: NSObject, AppleSignInPerforming {
  private static let authorizationQueue = DispatchQueue(
    label: "dev.unwired.mail.apple-authorization",
    qos: .default
  )

  private var authorizationController: ASAuthorizationController?
  private var continuation: CheckedContinuation<AppleSignInCredential, Error>?
  private let authorizationStateChecker: ProductAccountAuthorizationStateChecking
  private let performAuthorizationRequest: @MainActor (ASAuthorizationController) -> Void
  nonisolated private let presentationAnchorStore: AuthenticationPresentationAnchorStore

  init(
    authorizationStateChecker: ProductAccountAuthorizationStateChecking =
      AppleAuthorizationStateChecker(),
    performAuthorizationRequest: @escaping @MainActor (ASAuthorizationController) -> Void =
      SignInWithAppleService.performAuthorizationRequest,
    presentationAnchorStore: AuthenticationPresentationAnchorStore =
      AuthenticationPresentationAnchorStore()
  ) {
    self.authorizationStateChecker = authorizationStateChecker
    self.performAuthorizationRequest = performAuthorizationRequest
    self.presentationAnchorStore = presentationAnchorStore
    super.init()
  }

  func signIn() async throws -> AppleSignInCredential {
    try await performAuthorization()
  }

  func restoreSession(
    snapshot: ProductAccountSessionSnapshot
  ) async throws -> AppleSignInCredential {
    let authorizationState = await authorizationStateChecker.authorizationState(
      forAppleUserIdentifier: snapshot.appleUserIdentifier
    )

    switch authorizationState {
    case .authorized:
      return AppleSignInCredential(
        appleUserIdentifier: snapshot.appleUserIdentifier,
        identityToken: snapshot.identityToken
      )
    case .revoked, .unauthorized:
      throw AppleSignInError.notAuthorized
    case .unavailable:
      throw AppleSignInError.credentialUnavailable
    }
  }

  private func performAuthorization() async throws -> AppleSignInCredential {
    guard authorizationController == nil, continuation == nil else {
      throw AppleSignInError.authorizationInProgress
    }
    guard presentationAnchorStore.captureCurrent() else {
      throw AppleSignInError.presentationAnchorUnavailable
    }
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation

      let provider = ASAuthorizationAppleIDProvider()
      let request = provider.createRequest()
      request.requestedScopes = []

      let controller = ASAuthorizationController(authorizationRequests: [request])
      controller.delegate = self
      controller.presentationContextProvider = self
      authorizationController = controller
      performAuthorizationRequest(controller)
    }
  }

  private static func performAuthorizationRequest(_ controller: ASAuthorizationController) {
    let authorizationRequest = AppleAuthorizationRequest(controller: controller)
    authorizationQueue.async {
      authorizationRequest.perform()
    }
  }

  private func finishAuthorization(
    controller: ASAuthorizationController,
    result: Result<AppleSignInCredential, Error>
  ) {
    guard controller === authorizationController, let continuation else {
      return
    }
    self.continuation = nil
    authorizationController = nil
    presentationAnchorStore.clear()
    continuation.resume(with: result)
  }
}

extension SignInWithAppleService: ASAuthorizationControllerDelegate {
  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    guard controller === authorizationController else {
      return
    }
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
      finishAuthorization(
        controller: controller,
        result: .failure(AppleSignInError.credentialUnavailable)
      )
      return
    }

    guard let tokenData = credential.identityToken,
      let identityToken = String(data: tokenData, encoding: .utf8)
    else {
      finishAuthorization(
        controller: controller,
        result: .failure(AppleSignInError.missingIdentityToken)
      )
      return
    }

    let userIdentifier = credential.user
    guard !userIdentifier.isEmpty else {
      finishAuthorization(
        controller: controller,
        result: .failure(AppleSignInError.missingUserIdentifier)
      )
      return
    }

    guard let authorizationCodeData = credential.authorizationCode,
      let authorizationCode = String(data: authorizationCodeData, encoding: .utf8)
    else {
      finishAuthorization(
        controller: controller,
        result: .failure(AppleSignInError.missingAuthorizationCode)
      )
      return
    }

    finishAuthorization(
      controller: controller,
      result: .success(
        AppleSignInCredential(
          authorizationCode: authorizationCode,
          appleUserIdentifier: userIdentifier,
          identityToken: identityToken
        )
      )
    )
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithError error: Error
  ) {
    let resolvedError: Error
    if let authError = error as? ASAuthorizationError, authError.code == .unknown {
      resolvedError = AppleSignInError.configurationMissing
    } else {
      resolvedError = error
    }
    finishAuthorization(
      controller: controller,
      result: .failure(resolvedError)
    )
  }
}

extension SignInWithAppleService: ASAuthorizationControllerPresentationContextProviding {
  nonisolated func presentationAnchor(
    for controller: ASAuthorizationController
  ) -> ASPresentationAnchor {
    presentationAnchorStore.current()
  }
}

struct PreviewAppleSignInService: AppleSignInPerforming {
  let credential: AppleSignInCredential

  func signIn() async throws -> AppleSignInCredential {
    credential
  }

  func restoreSession(
    snapshot: ProductAccountSessionSnapshot
  ) async throws -> AppleSignInCredential {
    _ = snapshot
    return credential
  }
}
