import AuthenticationServices
import Foundation

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(UIKit)
  import UIKit
#endif

struct AppleSignInCredential: Equatable {
  let appleUserIdentifier: String
  let identityToken: String
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
  case missingUserIdentifier
  case credentialUnavailable
  case notAuthorized
  case configurationMissing

  var errorDescription: String? {
    switch self {
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

@MainActor
final class SignInWithAppleService: NSObject, AppleSignInPerforming {
  private var continuation: CheckedContinuation<AppleSignInCredential, Error>?

  func signIn() async throws -> AppleSignInCredential {
    try await performAuthorization()
  }

  func restoreSession(
    snapshot: ProductAccountSessionSnapshot
  ) async throws -> AppleSignInCredential {
    let authorizationState = await AppleAuthorizationStateChecker()
      .authorizationState(
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
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation

      let provider = ASAuthorizationAppleIDProvider()
      let request = provider.createRequest()
      request.requestedScopes = []

      let controller = ASAuthorizationController(authorizationRequests: [request])
      controller.delegate = self
      controller.presentationContextProvider = self
      controller.performRequests()
    }
  }
}

extension SignInWithAppleService: ASAuthorizationControllerDelegate {
  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
      continuation?.resume(throwing: AppleSignInError.credentialUnavailable)
      continuation = nil
      return
    }

    guard let tokenData = credential.identityToken,
      let identityToken = String(data: tokenData, encoding: .utf8)
    else {
      continuation?.resume(throwing: AppleSignInError.missingIdentityToken)
      continuation = nil
      return
    }

    let userIdentifier = credential.user
    guard !userIdentifier.isEmpty else {
      continuation?.resume(throwing: AppleSignInError.missingUserIdentifier)
      continuation = nil
      return
    }

    continuation?.resume(
      returning: AppleSignInCredential(
        appleUserIdentifier: userIdentifier,
        identityToken: identityToken
      )
    )
    continuation = nil
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithError error: Error
  ) {
    if let authError = error as? ASAuthorizationError, authError.code == .unknown {
      continuation?.resume(throwing: AppleSignInError.configurationMissing)
    } else {
      continuation?.resume(throwing: error)
    }
    continuation = nil
  }
}

extension SignInWithAppleService: ASAuthorizationControllerPresentationContextProviding {
  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    #if canImport(UIKit)
      let scenes = UIApplication.shared.connectedScenes
      let windowScene = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
      let window = windowScene?.windows.first { $0.isKeyWindow }
      return window ?? ASPresentationAnchor()
    #elseif canImport(AppKit)
      return NSApplication.shared.windows.first ?? ASPresentationAnchor()
    #else
      return ASPresentationAnchor()
    #endif
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
