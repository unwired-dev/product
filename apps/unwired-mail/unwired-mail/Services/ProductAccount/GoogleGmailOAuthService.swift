import AuthenticationServices
import CryptoKit
import Foundation
import Security

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(UIKit)
  import UIKit
#endif

@MainActor
protocol GmailOAuthAuthorizing {
  func authorize() async throws -> GmailProviderTokens
}

enum GoogleGmailOAuthError: LocalizedError {
  case authorizationFailed(String)
  case configurationMissing
  case invalidAuthorizationCallback
  case invalidAuthorizationState
  case invalidClientIdentifier
  case tokenExchangeFailed
  case webAuthenticationUnavailable

  var errorDescription: String? {
    switch self {
    case .authorizationFailed(let message):
      return "Google sign-in failed: \(message)"
    case .configurationMissing:
      return """
        Google sign-in is not configured. Set GMAIL_OAUTH_CLIENT_ID to an iOS OAuth client ID.
        """
    case .invalidAuthorizationCallback:
      return "Google sign-in returned an invalid response."
    case .invalidAuthorizationState:
      return "Google sign-in could not verify the authorization response."
    case .invalidClientIdentifier:
      return "The configured Google OAuth client ID is not valid for an Apple app."
    case .tokenExchangeFailed:
      return "Google did not return usable account credentials."
    case .webAuthenticationUnavailable:
      return "Google sign-in could not open the authentication window."
    }
  }
}

struct GoogleGmailOAuthRequest {
  static let authorizationEndpoint = URL(
    string: "https://accounts.google.com/o/oauth2/v2/auth"
  )!
  static let gmailScope = "https://www.googleapis.com/auth/gmail.modify"
  static let authorizationScope = "openid email \(gmailScope)"

  let clientIdentifier: String
  let codeVerifier: String
  let state: String

  init(
    clientIdentifier: String,
    codeVerifier: String = Self.randomBase64URLString(byteCount: 64),
    state: String = Self.randomBase64URLString(byteCount: 32)
  ) {
    self.clientIdentifier = clientIdentifier
    self.codeVerifier = codeVerifier
    self.state = state
  }

  var authorizationURL: URL? {
    guard let redirectURI else { return nil }
    var components = URLComponents(
      url: Self.authorizationEndpoint,
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "client_id", value: clientIdentifier),
      URLQueryItem(name: "code_challenge", value: codeChallenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "include_granted_scopes", value: "true"),
      URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: Self.authorizationScope),
      URLQueryItem(name: "state", value: state),
    ]
    return components?.url
  }

  var callbackScheme: String? {
    let suffix = ".apps.googleusercontent.com"
    guard clientIdentifier.hasSuffix(suffix) else { return nil }
    let identifier = clientIdentifier.dropLast(suffix.count)
    guard !identifier.isEmpty else { return nil }
    return "com.googleusercontent.apps.\(identifier)"
  }

  var redirectURI: URL? {
    callbackScheme.flatMap { URL(string: "\($0):/oauth2redirect") }
  }

  func authorizationCode(from callbackURL: URL) throws -> String {
    guard
      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
      components.queryValue(named: "state") == state
    else {
      throw GoogleGmailOAuthError.invalidAuthorizationState
    }

    if let error = components.queryValue(named: "error") {
      if error == "access_denied" {
        throw CancellationError()
      }
      let description = components.queryValue(named: "error_description") ?? error
      throw GoogleGmailOAuthError.authorizationFailed(description)
    }

    guard let code = components.queryValue(named: "code"), !code.isEmpty else {
      throw GoogleGmailOAuthError.invalidAuthorizationCallback
    }
    return code
  }

  private var codeChallenge: String {
    Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64URLEncodedString()
  }

  private static func randomBase64URLString(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let result = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
    precondition(result == errSecSuccess, "Secure random generation failed")
    return Data(bytes).base64URLEncodedString()
  }
}

@MainActor
final class GoogleGmailOAuthService: NSObject, GmailOAuthAuthorizing {
  private let clientIdentifier: String?
  private let session: URLSession
  private let tokenEndpoint: URL
  private var authenticationContinuation: CheckedContinuation<URL, Error>?
  private var webAuthenticationSession: ASWebAuthenticationSession?

  nonisolated init(
    clientIdentifier: String? =
      ProcessInfo.processInfo.environment["GMAIL_OAUTH_CLIENT_ID"]
      ?? DotEnvFile.value(for: "GMAIL_OAUTH_CLIENT_ID")
      ?? GmailOAuthClientIdConfiguration.bundledValue(),
    session: URLSession = .shared,
    tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!
  ) {
    self.clientIdentifier = clientIdentifier
    self.session = session
    self.tokenEndpoint = tokenEndpoint
  }

  func authorize() async throws -> GmailProviderTokens {
    guard let clientIdentifier, !clientIdentifier.isEmpty else {
      throw GoogleGmailOAuthError.configurationMissing
    }

    let request = GoogleGmailOAuthRequest(clientIdentifier: clientIdentifier)
    guard
      let authorizationURL = request.authorizationURL,
      let callbackScheme = request.callbackScheme,
      request.redirectURI != nil
    else {
      throw GoogleGmailOAuthError.invalidClientIdentifier
    }

    let callbackURL = try await authenticate(
      authorizationURL: authorizationURL,
      callbackScheme: callbackScheme
    )
    let code = try request.authorizationCode(from: callbackURL)
    return try await exchangeAuthorizationCode(code, request: request)
  }

  func exchangeAuthorizationCode(
    _ code: String,
    request: GoogleGmailOAuthRequest
  ) async throws -> GmailProviderTokens {
    guard let redirectURI = request.redirectURI else {
      throw GoogleGmailOAuthError.invalidClientIdentifier
    }

    var tokenRequest = URLRequest(url: tokenEndpoint)
    tokenRequest.httpMethod = "POST"
    tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    tokenRequest.httpBody = [
      "client_id": request.clientIdentifier,
      "code": code,
      "code_verifier": request.codeVerifier,
      "grant_type": "authorization_code",
      "redirect_uri": redirectURI.absoluteString,
    ].formURLEncodedData()

    let (data, response) = try await session.data(for: tokenRequest)
    guard
      let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      let tokenResponse = try? JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: data),
      !tokenResponse.accessToken.isEmpty,
      !tokenResponse.refreshToken.isEmpty
    else {
      throw GoogleGmailOAuthError.tokenExchangeFailed
    }

    return GmailProviderTokens(
      accessToken: tokenResponse.accessToken,
      refreshToken: tokenResponse.refreshToken
    )
  }

  private func authenticate(
    authorizationURL: URL,
    callbackScheme: String
  ) async throws -> URL {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }

        authenticationContinuation = continuation
        let authenticationSession = ASWebAuthenticationSession(
          url: authorizationURL,
          callbackURLScheme: callbackScheme
        ) { [weak self] callbackURL, error in
          Task { @MainActor in
            self?.finishAuthentication(callbackURL: callbackURL, error: error)
          }
        }
        authenticationSession.presentationContextProvider = self
        authenticationSession.prefersEphemeralWebBrowserSession = false
        webAuthenticationSession = authenticationSession
        guard authenticationSession.start() else {
          finishAuthentication(
            callbackURL: nil,
            error: GoogleGmailOAuthError.webAuthenticationUnavailable
          )
          return
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancelAuthentication()
      }
    }
  }

  private func cancelAuthentication() {
    let continuation = authenticationContinuation
    authenticationContinuation = nil
    webAuthenticationSession?.cancel()
    webAuthenticationSession = nil
    continuation?.resume(throwing: CancellationError())
  }

  private func finishAuthentication(callbackURL: URL?, error: Error?) {
    guard let continuation = authenticationContinuation else { return }
    authenticationContinuation = nil
    webAuthenticationSession = nil

    if let authenticationError = error as? ASWebAuthenticationSessionError,
      authenticationError.code == .canceledLogin
    {
      continuation.resume(throwing: CancellationError())
    } else if let error {
      continuation.resume(throwing: error)
    } else if let callbackURL {
      continuation.resume(returning: callbackURL)
    } else {
      continuation.resume(throwing: GoogleGmailOAuthError.invalidAuthorizationCallback)
    }
  }
}

extension GoogleGmailOAuthService: ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
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

private struct GoogleOAuthTokenResponse: Decodable {
  let accessToken: String
  let refreshToken: String

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
  }
}

extension URLComponents {
  fileprivate func queryValue(named name: String) -> String? {
    queryItems?.first { $0.name == name }?.value
  }
}

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

extension Dictionary where Key == String, Value == String {
  fileprivate func formURLEncodedData() -> Data {
    map { "\($0.key.formURLEncoded())=\($0.value.formURLEncoded())" }
      .sorted()
      .joined(separator: "&")
      .data(using: .utf8) ?? Data()
  }
}

extension String {
  fileprivate func formURLEncoded() -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
  }
}
