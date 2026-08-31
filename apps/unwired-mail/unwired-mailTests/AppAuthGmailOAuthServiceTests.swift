@preconcurrency import AppAuth
import Foundation
import Testing

@testable import unwired_mail

@Suite(.serialized)
@MainActor
struct AppAuthGmailOAuthServiceTests {
  @Test
  func authorizationRequestUsesSystemBrowserPKCEAndLeastPrivilegeScopes() throws {
    let snapshot = try AppAuthGmailOAuthRequest(
      clientIdentifier: "mail.apps.googleusercontent.com"
    ).securitySnapshot()

    #expect(
      snapshot.authorizationEndpoint.absoluteString
        == "https://accounts.google.com/o/oauth2/v2/auth")
    #expect(snapshot.tokenEndpoint.absoluteString == "https://oauth2.googleapis.com/token")
    #expect(
      snapshot.redirectURI.absoluteString == "com.googleusercontent.apps.mail:/oauth2redirect")
    #expect(snapshot.scopes == ["openid", "email", GoogleGmailOAuthRequest.gmailScope])
    #expect(snapshot.accessType == "offline")
    #expect(snapshot.includesPreviouslyGrantedScopes)
    #expect(snapshot.prompt == "select_account consent")
    #expect(!snapshot.usesClientSecret)
    #expect(snapshot.usesPKCES256)
    #expect(snapshot.hasState)
    #expect(snapshot.hasNonce)
  }

  @Test
  func invalidAppleClientIdentifierIsRejected() {
    #expect(throws: AppAuthGmailOAuthError.invalidClientIdentifier) {
      try AppAuthGmailOAuthRequest(clientIdentifier: "web-client").securitySnapshot()
    }
  }

  @Test
  func overlappingAuthorizationsKeepCredentialsIndependent() async throws {
    let firstGate = TestRendezvous()
    let secondGate = TestRendezvous()
    let performer = ControlledAppAuthGmailOAuthPerformer(
      operations: [
        .init(
          gate: firstGate,
          credential: .init(
            accessToken: "access-one", refreshToken: "refresh-one", idToken: "id-one")
        ),
        .init(
          gate: secondGate,
          credential: .init(
            accessToken: "access-two", refreshToken: "refresh-two", idToken: "id-two")
        ),
      ]
    )
    let service = AppAuthGmailOAuthService(
      clientIdentifier: "mail.apps.googleusercontent.com",
      performer: performer
    )

    let first = Task { try await service.authorize() }
    await firstGate.waitUntilHeld()
    let second = Task { try await service.authorize() }
    await secondGate.waitUntilHeld()

    await secondGate.release()
    let secondTokens = try await second.value
    await firstGate.release()
    let firstTokens = try await first.value

    #expect(
      firstTokens
        == GmailProviderTokens(
          accessToken: "access-one",
          refreshToken: "refresh-one",
          idToken: "id-one"
        ))
    #expect(
      secondTokens
        == GmailProviderTokens(
          accessToken: "access-two",
          refreshToken: "refresh-two",
          idToken: "id-two"
        ))
  }

  @Test
  func cancellationRemainsAConnectionScopedCancellation() async {
    let performer = FailingAppAuthGmailOAuthPerformer(error: CancellationError())
    let service = AppAuthGmailOAuthService(
      clientIdentifier: "mail.apps.googleusercontent.com",
      performer: performer
    )

    await #expect(throws: CancellationError.self) {
      try await service.authorize()
    }
  }

  @Test(arguments: [
    NSError(
      domain: OIDGeneralErrorDomain,
      code: OIDErrorCode.userCanceledAuthorizationFlow.rawValue
    ),
    NSError(
      domain: OIDGeneralErrorDomain,
      code: OIDErrorCode.programCanceledAuthorizationFlow.rawValue
    ),
    NSError(
      domain: OIDOAuthAuthorizationErrorDomain,
      code: OIDErrorCodeOAuth.accessDenied.rawValue
    ),
  ])
  func appAuthCancellationAndConsentDenialMapToCancellation(error: NSError) {
    #expect(AppAuthGmailOAuthErrorMapper.map(error) is CancellationError)
  }

  @Test
  func interruptedCallbackErrorIsPreservedForConnectionScopedRecovery() {
    let interruption = NSError(domain: "AppAuthQualification", code: 17)

    #expect(AppAuthGmailOAuthErrorMapper.map(interruption) as NSError === interruption)
  }

  @Test
  func missingCredentialComponentIsRejected() async {
    let performer = ImmediateAppAuthGmailOAuthPerformer(
      credential: .init(accessToken: "access", refreshToken: nil, idToken: "id")
    )
    let service = AppAuthGmailOAuthService(
      clientIdentifier: "mail.apps.googleusercontent.com",
      performer: performer
    )

    await #expect(throws: AppAuthGmailOAuthError.unusableTokenResponse) {
      try await service.authorize()
    }
  }

  @Test
  func candidateRequiresExplicitNonReleaseOptIn() {
    #expect(!AppAuthGmailOAuthQualification.isCandidateEnabled(environment: [:]))
    #if DEBUG || TESTING
      #expect(
        AppAuthGmailOAuthQualification.isCandidateEnabled(
          environment: ["UNWIRED_GMAIL_OAUTH_IMPLEMENTATION": "appauth"]
        ))
    #else
      #expect(
        !AppAuthGmailOAuthQualification.isCandidateEnabled(
          environment: ["UNWIRED_GMAIL_OAUTH_IMPLEMENTATION": "appauth"]
        ))
    #endif
  }

  @Test
  func factoryKeepsCurrentAuthorizerWithoutOptIn() {
    #expect(GmailOAuthAuthorizerFactory.make(environment: [:]) is GoogleGmailOAuthService)
  }

  @Test
  func factorySelectsCandidateOnlyWhenTheBuildAllowsOptIn() {
    let authorizer = GmailOAuthAuthorizerFactory.make(
      environment: ["UNWIRED_GMAIL_OAUTH_IMPLEMENTATION": "appauth"]
    )
    #if DEBUG || TESTING
      #expect(!(authorizer is GoogleGmailOAuthService))
    #else
      #expect(authorizer is GoogleGmailOAuthService)
    #endif
  }

  @Test
  func pinsReviewedAppAuthRelease() {
    #expect(AppAuthGmailOAuthQualification.packageVersion == "2.1.0")
    #expect(
      AppAuthGmailOAuthQualification.packageRevision == "a7caeda164dc5108bf4649472b28a5af65dc6f33")
  }
}

@MainActor
private final class ImmediateAppAuthGmailOAuthPerformer: AppAuthGmailOAuthPerforming {
  private let credential: AppAuthGmailOAuthCredential

  init(credential: AppAuthGmailOAuthCredential) {
    self.credential = credential
  }

  func authorize(
    _ request: AppAuthGmailOAuthRequest
  ) async throws -> AppAuthGmailOAuthCredential {
    credential
  }
}

@MainActor
private final class FailingAppAuthGmailOAuthPerformer: AppAuthGmailOAuthPerforming {
  private let error: Error

  init(error: Error) {
    self.error = error
  }

  func authorize(
    _ request: AppAuthGmailOAuthRequest
  ) async throws -> AppAuthGmailOAuthCredential {
    throw error
  }
}

@MainActor
private final class ControlledAppAuthGmailOAuthPerformer: AppAuthGmailOAuthPerforming {
  struct Operation {
    let gate: TestRendezvous
    let credential: AppAuthGmailOAuthCredential
  }

  private var operations: [Operation]

  init(operations: [Operation]) {
    self.operations = operations
  }

  func authorize(
    _ request: AppAuthGmailOAuthRequest
  ) async throws -> AppAuthGmailOAuthCredential {
    let operation = operations.removeFirst()
    await operation.gate.hold()
    return operation.credential
  }
}
