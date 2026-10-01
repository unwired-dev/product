import AuthenticationServices
import Foundation

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

// Holds one system authorization session and its presentation window.
private final class AppleAuthorizationSession: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  let anchor: ASPresentationAnchor
  let continuation: CheckedContinuation<ASAuthorization, any Error>

  init(anchor: ASPresentationAnchor, continuation: CheckedContinuation<ASAuthorization, any Error>)
  {
    self.anchor = anchor
    self.continuation = continuation
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    anchor
  }
  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    continuation.resume(returning: authorization)
  }
  func authorizationController(
    controller: ASAuthorizationController, didCompleteWithError error: any Error
  ) {
    continuation.resume(throwing: error)
  }
}

@MainActor final class NativeAppleRegistrationProvider: AppleRegistrationProvider {
  let audience: String
  private var active: (ASAuthorizationController, AppleAuthorizationSession)?
  init(audience: String) { self.audience = audience }

  func signIn() async throws -> AppleRegistrationIdentity {
    #if os(iOS)
      guard
        let anchor = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
          .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: {
            $0.isKeyWindow
          })
      else { throw RegistrationError.unavailable }
    #else
      guard let anchor = NSApp.keyWindow else { throw RegistrationError.unavailable }
    #endif
    guard active == nil else { throw RegistrationError.unavailable }
    let nonce = UUID().uuidString + UUID().uuidString
    let request = ASAuthorizationAppleIDProvider().createRequest()
    // The address, often a private relay, is display and contact information only.
    request.requestedScopes = [.email]
    request.nonce = nonce
    let authorization: ASAuthorization
    do {
      authorization = try await withCheckedThrowingContinuation { continuation in
        let controller = ASAuthorizationController(authorizationRequests: [request])
        let session = AppleAuthorizationSession(anchor: anchor, continuation: continuation)
        controller.delegate = session
        controller.presentationContextProvider = session
        active = (controller, session)
        controller.performRequests()
      }
      active = nil
    } catch {
      active = nil
      if (error as? ASAuthorizationError)?.code == .canceled { throw RegistrationError.cancelled }
      throw error
    }
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
      let data = credential.identityToken, let token = String(data: data, encoding: .utf8)
    else { throw RegistrationError.invalidIdentity }
    let claims = try IdentityTokenClaims.validate(
      token, issuers: IdentityTokenClaims.apple, audience: audience, subject: credential.user,
      nonce: nonce)
    return AppleRegistrationIdentity(
      subject: credential.user, idToken: token, email: credential.email ?? claims.email)
  }

  func credentialState(_ subject: String) async -> AppleCredentialState {
    do {
      switch try await ASAuthorizationAppleIDProvider().credentialState(forUserID: subject) {
      case .authorized: return .authorized
      case .revoked, .notFound: return .revoked
      default: return .unavailable
      }
    } catch {
      return .unavailable
    }
  }
}
