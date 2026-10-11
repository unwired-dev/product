import AuthenticationServices
import Foundation

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

// Presents Microsoft's authorization page in the system web authentication session and resolves
// its callback. The session shares the system browser's sign-in, so a Microsoft account already
// signed in there is offered.
@MainActor final class MicrosoftAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var anchor: ASPresentationAnchor?
  private var session: ASWebAuthenticationSession?

  func authenticate(_ url: URL, callbackScheme: String) async throws -> URL {
    #if os(iOS)
      guard
        let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
          .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: {
            $0.isKeyWindow
          })
      else { throw RegistrationError.unavailable }
    #else
      guard let window = NSApp.keyWindow else { throw RegistrationError.unavailable }
    #endif
    guard session == nil else { throw RegistrationError.unavailable }
    anchor = window
    defer {
      session = nil
      anchor = nil
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let session = ASWebAuthenticationSession(
          url: url, callback: .customScheme(callbackScheme)
        ) { callback, error in
          if let callback {
            continuation.resume(returning: callback)
          } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
            continuation.resume(throwing: RegistrationError.cancelled)
          } else {
            continuation.resume(throwing: error ?? RegistrationError.unavailable)
          }
        }
        session.presentationContextProvider = self
        self.session = session
        if !session.start() {
          self.session = nil
          continuation.resume(throwing: RegistrationError.unavailable)
        }
      }
    } onCancel: {
      Task { @MainActor in self.session?.cancel() }
    }
  }

  nonisolated func presentationAnchor(for session: ASWebAuthenticationSession)
    -> ASPresentationAnchor
  {
    MainActor.assumeIsolated { anchor ?? ASPresentationAnchor() }
  }
}
