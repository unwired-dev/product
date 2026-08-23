@preconcurrency import AppAuth
import Foundation

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(UIKit)
  import UIKit
#endif

enum AppAuthGmailOAuthQualification {
  static let packageVersion = "2.1.0"
  static let packageRevision = "a7caeda164dc5108bf4649472b28a5af65dc6f33"

  static func isCandidateEnabled(environment: [String: String]) -> Bool {
    #if DEBUG || TESTING
      return environment["UNWIRED_GMAIL_OAUTH_IMPLEMENTATION"] == "appauth"
    #else
      return false
    #endif
  }
}

enum GmailOAuthAuthorizerFactory {
  static func make(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> any GmailOAuthAuthorizing {
    if AppAuthGmailOAuthQualification.isCandidateEnabled(environment: environment) {
      return OptInAppAuthGmailOAuthAuthorizer()
    }
    return GoogleGmailOAuthService()
  }
}

@MainActor
private final class OptInAppAuthGmailOAuthAuthorizer: GmailOAuthAuthorizing {
  nonisolated init() {}

  func authorize() async throws -> GmailProviderTokens {
    try await AppAuthGmailOAuthService().authorize()
  }
}

enum AppAuthGmailOAuthError: LocalizedError, Equatable {
  case configurationMissing
  case invalidClientIdentifier
  case tokenExchangeUnavailable
  case unusableTokenResponse
  case webAuthenticationUnavailable

  var errorDescription: String? {
    switch self {
    case .configurationMissing:
      return "Google sign-in is not configured for this build."
    case .invalidClientIdentifier:
      return "The configured Google OAuth client ID is not valid for an Apple app."
    case .tokenExchangeUnavailable:
      return "Google sign-in returned an authorization response that cannot be exchanged."
    case .unusableTokenResponse:
      return "Google did not return usable account credentials."
    case .webAuthenticationUnavailable:
      return "Google sign-in could not open the authentication window."
    }
  }
}

struct AppAuthGmailOAuthRequestSnapshot: Equatable {
  let authorizationEndpoint: URL
  let tokenEndpoint: URL
  let redirectURI: URL
  let scopes: Set<String>
  let accessType: String?
  let includesPreviouslyGrantedScopes: Bool
  let prompt: String?
  let usesClientSecret: Bool
  let usesPKCES256: Bool
  let hasState: Bool
  let hasNonce: Bool
}

struct AppAuthGmailOAuthRequest {
  static let authorizationEndpoint = URL(
    string: "https://accounts.google.com/o/oauth2/v2/auth"
  )!
  static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
  static let scopes = [
    OIDScopeOpenID,
    OIDScopeEmail,
    GoogleGmailOAuthRequest.gmailScope,
  ]

  let clientIdentifier: String

  var redirectURI: URL? {
    let suffix = ".apps.googleusercontent.com"
    guard clientIdentifier.hasSuffix(suffix) else { return nil }
    let identifier = clientIdentifier.dropLast(suffix.count)
    guard !identifier.isEmpty else { return nil }
    return URL(string: "com.googleusercontent.apps.\(identifier):/oauth2redirect")
  }

  func makeAuthorizationRequest() throws -> OIDAuthorizationRequest {
    guard let redirectURI else {
      throw AppAuthGmailOAuthError.invalidClientIdentifier
    }
    let configuration = OIDServiceConfiguration(
      authorizationEndpoint: Self.authorizationEndpoint,
      tokenEndpoint: Self.tokenEndpoint
    )
    return OIDAuthorizationRequest(
      configuration: configuration,
      clientId: clientIdentifier,
      clientSecret: nil,
      scopes: Self.scopes,
      redirectURL: redirectURI,
      responseType: OIDResponseTypeCode,
      additionalParameters: [
        "access_type": "offline",
        "include_granted_scopes": "true",
        "prompt": "select_account consent",
      ]
    )
  }

  func securitySnapshot() throws -> AppAuthGmailOAuthRequestSnapshot {
    let request = try makeAuthorizationRequest()
    guard let redirectURI else {
      throw AppAuthGmailOAuthError.invalidClientIdentifier
    }
    return AppAuthGmailOAuthRequestSnapshot(
      authorizationEndpoint: request.configuration.authorizationEndpoint,
      tokenEndpoint: request.configuration.tokenEndpoint,
      redirectURI: redirectURI,
      scopes: Set(request.scope?.split(separator: " ").map(String.init) ?? []),
      accessType: request.additionalParameters?["access_type"],
      includesPreviouslyGrantedScopes:
        request.additionalParameters?["include_granted_scopes"] == "true",
      prompt: request.additionalParameters?["prompt"],
      usesClientSecret: request.clientSecret != nil,
      usesPKCES256:
        request.codeVerifier?.isEmpty == false
        && request.codeChallenge?.isEmpty == false
        && request.codeChallengeMethod == OIDOAuthorizationRequestCodeChallengeMethodS256,
      hasState: request.state?.isEmpty == false,
      hasNonce: request.nonce?.isEmpty == false
    )
  }
}

struct AppAuthGmailOAuthCredential: Equatable {
  let accessToken: String?
  let refreshToken: String?
  let idToken: String?
}

enum AppAuthGmailOAuthErrorMapper {
  static func map(_ error: Error) -> Error {
    let error = error as NSError
    let isAppAuthCancellation =
      error.domain == OIDGeneralErrorDomain
      && (error.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue
        || error.code == OIDErrorCode.programCanceledAuthorizationFlow.rawValue)
    let isConsentDenial =
      error.domain == OIDOAuthAuthorizationErrorDomain
      && error.code == OIDErrorCodeOAuth.accessDenied.rawValue
    return isAppAuthCancellation || isConsentDenial ? CancellationError() : error
  }
}

@MainActor
protocol AppAuthGmailOAuthPerforming: AnyObject {
  func authorize(_ request: AppAuthGmailOAuthRequest) async throws -> AppAuthGmailOAuthCredential
}

@MainActor
final class AppAuthGmailOAuthService: GmailOAuthAuthorizing {
  private let clientIdentifier: String?
  private let performer: any AppAuthGmailOAuthPerforming

  init(
    clientIdentifier: String? =
      ProcessInfo.processInfo.environment["GMAIL_OAUTH_CLIENT_ID"]
      ?? DotEnvFile.value(for: "GMAIL_OAUTH_CLIENT_ID")
      ?? GmailOAuthClientIdConfiguration.bundledValue(),
    performer: (any AppAuthGmailOAuthPerforming)? = nil
  ) {
    self.clientIdentifier = clientIdentifier
    self.performer = performer ?? SystemAppAuthGmailOAuthPerformer()
  }

  func authorize() async throws -> GmailProviderTokens {
    guard let clientIdentifier, !clientIdentifier.isEmpty else {
      throw AppAuthGmailOAuthError.configurationMissing
    }
    let credential = try await performer.authorize(
      AppAuthGmailOAuthRequest(clientIdentifier: clientIdentifier)
    )
    guard
      let accessToken = credential.accessToken,
      let refreshToken = credential.refreshToken,
      let idToken = credential.idToken,
      !accessToken.isEmpty,
      !refreshToken.isEmpty,
      !idToken.isEmpty
    else {
      throw AppAuthGmailOAuthError.unusableTokenResponse
    }
    return GmailProviderTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      idToken: idToken
    )
  }
}

@MainActor
final class SystemAppAuthGmailOAuthPerformer: AppAuthGmailOAuthPerforming {
  private struct AuthorizationOperation {
    let continuation: CheckedContinuation<OIDAuthorizationResponse, Error>
    var session: (any OIDExternalUserAgentSession)?
  }

  private var operations: [UUID: AuthorizationOperation] = [:]

  func authorize(_ request: AppAuthGmailOAuthRequest) async throws -> AppAuthGmailOAuthCredential {
    let authorizationResponse = try await present(try request.makeAuthorizationRequest())
    guard let tokenRequest = authorizationResponse.tokenExchangeRequest() else {
      throw AppAuthGmailOAuthError.tokenExchangeUnavailable
    }
    let tokenResponse = try await exchange(
      tokenRequest,
      authorizationResponse: authorizationResponse
    )
    return AppAuthGmailOAuthCredential(
      accessToken: tokenResponse.accessToken,
      refreshToken: tokenResponse.refreshToken,
      idToken: tokenResponse.idToken
    )
  }

  private func present(
    _ request: OIDAuthorizationRequest
  ) async throws -> OIDAuthorizationResponse {
    let operationID = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        operations[operationID] = AuthorizationOperation(
          continuation: continuation,
          session: nil
        )
        guard
          let session = present(
            request,
            callback: { [weak self] response, error in
              Task { @MainActor in
                self?.finish(operationID, response: response, error: error)
              }
            })
        else {
          finish(
            operationID,
            response: nil,
            error: AppAuthGmailOAuthError.webAuthenticationUnavailable
          )
          return
        }
        operations[operationID]?.session = session
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancel(operationID)
      }
    }
  }

  private func present(
    _ request: OIDAuthorizationRequest,
    callback: @escaping OIDAuthorizationCallback
  ) -> (any OIDExternalUserAgentSession)? {
    #if canImport(UIKit)
      guard
        let window = AuthenticationPresentationAnchor.current(),
        let viewController = window.rootViewController
      else {
        return nil
      }
      return OIDAuthorizationService.present(
        request,
        presenting: topViewController(from: viewController),
        callback: callback
      )
    #elseif canImport(AppKit)
      guard let window = AuthenticationPresentationAnchor.current() else {
        return nil
      }
      return OIDAuthorizationService.present(
        request,
        presenting: window,
        callback: callback
      )
    #else
      return nil
    #endif
  }

  private func exchange(
    _ request: OIDTokenRequest,
    authorizationResponse: OIDAuthorizationResponse
  ) async throws -> OIDTokenResponse {
    try await withCheckedThrowingContinuation { continuation in
      OIDAuthorizationService.perform(
        request,
        originalAuthorizationResponse: authorizationResponse
      ) { response, error in
        if let response {
          continuation.resume(returning: response)
        } else {
          continuation.resume(
            throwing: error ?? AppAuthGmailOAuthError.unusableTokenResponse
          )
        }
      }
    }
  }

  private func cancel(_ operationID: UUID) {
    guard let operation = operations.removeValue(forKey: operationID) else { return }
    operation.session?.cancel()
    operation.continuation.resume(throwing: CancellationError())
  }

  private func finish(
    _ operationID: UUID,
    response: OIDAuthorizationResponse?,
    error: Error?
  ) {
    guard let operation = operations.removeValue(forKey: operationID) else { return }
    if let response {
      operation.continuation.resume(returning: response)
    } else {
      operation.continuation.resume(
        throwing: error.map(AppAuthGmailOAuthErrorMapper.map)
          ?? AppAuthGmailOAuthError.unusableTokenResponse
      )
    }
  }

  #if canImport(UIKit)
    private func topViewController(from root: UIViewController) -> UIViewController {
      if let presented = root.presentedViewController {
        return topViewController(from: presented)
      }
      if let navigation = root as? UINavigationController,
        let visible = navigation.visibleViewController
      {
        return topViewController(from: visible)
      }
      if let tab = root as? UITabBarController,
        let selected = tab.selectedViewController
      {
        return topViewController(from: selected)
      }
      return root
    }
  #endif
}
