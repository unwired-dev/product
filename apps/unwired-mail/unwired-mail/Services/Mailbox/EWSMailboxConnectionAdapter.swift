import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftData

// swiftlint:disable file_length function_parameter_count type_body_length

extension MailProviderId {
  static let exchangeWebServices = MailProviderId(rawValue: "exchange-web-services")
}

enum EWSSetupError: LocalizedError, Equatable {
  case authenticationFailed
  case invalidMailboxIdentity
  case missingRequiredMailboxRole
  case onPremisesEndpointRequired
  case unsupportedServerVersion

  var errorDescription: String? {
    switch self {
    case .authenticationFailed:
      return "Exchange Web Services did not accept this mailbox authorization."
    case .invalidMailboxIdentity:
      return "Exchange Web Services did not return a stable mailbox identity."
    case .missingRequiredMailboxRole:
      return "Exchange did not expose every mailbox required for full mail support."
    case .onPremisesEndpointRequired:
      return
        "Enter an HTTPS Exchange Web Services endpoint hosted by your organization. "
        + "Exchange Online and Microsoft 365 must use Microsoft Graph."
    case .unsupportedServerVersion:
      return "This Exchange server is not a supported on-premises EWS version."
    }
  }
}

enum EWSOAuthError: LocalizedError, Equatable {
  case authorizationRejected
  case configurationMissing
  case invalidAuthorizationCallback
  case invalidAuthorizationState
  case invalidConfiguration
  case tokenExchangeFailed(status: Int?)
  case webAuthenticationUnavailable

  var errorDescription: String? {
    switch self {
    case .authorizationRejected:
      return "Exchange OAuth authorization expired. Authorize this mailbox again."
    case .configurationMissing:
      return "Exchange OAuth is not configured for this build."
    case .invalidAuthorizationCallback, .invalidAuthorizationState:
      return "Exchange OAuth returned an invalid authorization response."
    case .invalidConfiguration:
      return "Exchange OAuth configuration must use HTTPS provider endpoints and a callback scheme."
    case .tokenExchangeFailed(let status):
      return status.map { "Exchange OAuth token exchange failed with HTTP status \($0)." }
        ?? "Exchange OAuth token exchange failed."
    case .webAuthenticationUnavailable:
      return "Exchange OAuth could not open the system authentication window."
    }
  }
}

struct EWSOAuthConfiguration: Equatable, Sendable {
  let authorizationEndpoint: URL
  let callbackScheme: String
  let clientIdentifier: String
  let scope: String
  let tokenEndpoint: URL

  init(
    authorizationEndpoint: URL,
    callbackScheme: String,
    clientIdentifier: String,
    scope: String,
    tokenEndpoint: URL
  ) throws {
    let callbackScheme = callbackScheme.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedCallbackScheme = callbackScheme.lowercased()
    let clientIdentifier = clientIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    let scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      authorizationEndpoint.scheme?.lowercased() == "https",
      authorizationEndpoint.host?.isEmpty == false,
      tokenEndpoint.scheme?.lowercased() == "https",
      tokenEndpoint.host?.isEmpty == false,
      !callbackScheme.isEmpty,
      callbackScheme.range(
        of: "^[A-Za-z][A-Za-z0-9+.-]*$",
        options: .regularExpression
      ) != nil,
      !["http", "https"].contains(normalizedCallbackScheme),
      URL(string: "\(callbackScheme)://auth") != nil,
      !clientIdentifier.isEmpty,
      !scope.isEmpty
    else { throw EWSOAuthError.invalidConfiguration }
    self.authorizationEndpoint = authorizationEndpoint
    self.callbackScheme = callbackScheme
    self.clientIdentifier = clientIdentifier
    self.scope = scope
    self.tokenEndpoint = tokenEndpoint
  }

  static func bundledValue() -> Self? {
    func value(environmentKey: String, bundleKey: String) -> String? {
      ProcessInfo.processInfo.environment[environmentKey]
        ?? DotEnvFile.value(for: environmentKey)
        ?? Bundle.main.object(forInfoDictionaryKey: bundleKey) as? String
    }
    guard
      let authorizationEndpoint = value(
        environmentKey: "EWS_OAUTH_AUTHORIZATION_ENDPOINT",
        bundleKey: "EWSOAuthAuthorizationEndpoint"
      ).flatMap(URL.init(string:)),
      let callbackScheme = Bundle.main.object(
        forInfoDictionaryKey: "EWSOAuthCallbackScheme"
      ) as? String,
      let clientIdentifier = value(
        environmentKey: "EWS_OAUTH_CLIENT_ID",
        bundleKey: "EWSOAuthClientId"
      ),
      let scope = value(
        environmentKey: "EWS_OAUTH_SCOPE",
        bundleKey: "EWSOAuthScope"
      ),
      let tokenEndpoint = value(
        environmentKey: "EWS_OAUTH_TOKEN_ENDPOINT",
        bundleKey: "EWSOAuthTokenEndpoint"
      ).flatMap(URL.init(string:))
    else { return nil }
    return try? Self(
      authorizationEndpoint: authorizationEndpoint,
      callbackScheme: callbackScheme,
      clientIdentifier: clientIdentifier,
      scope: scope,
      tokenEndpoint: tokenEndpoint
    )
  }
}

struct EWSOAuthTokens: Codable, Equatable, Sendable {
  let accessToken: String
  let expiresAtMilliseconds: Int64
  let refreshToken: String
}

@MainActor
protocol EWSOAuthAuthorizing: AnyObject {
  func authorize() async throws -> EWSOAuthTokens
  func refresh(_ tokens: EWSOAuthTokens) async throws -> EWSOAuthTokens
}

@MainActor
final class EWSOAuthService: NSObject, EWSOAuthAuthorizing {
  private let configuration: EWSOAuthConfiguration?
  nonisolated private let now: @Sendable () -> Date
  nonisolated private let presentationAnchorStore: AuthenticationPresentationAnchorStore
  private let session: URLSession
  private var authenticationID: UUID?
  private var authenticationContinuation: CheckedContinuation<URL, Error>?
  private var webAuthenticationSession: ASWebAuthenticationSession?

  nonisolated init(
    configuration: EWSOAuthConfiguration? = EWSOAuthConfiguration.bundledValue(),
    now: @escaping @Sendable () -> Date = { Date() },
    session: URLSession = .shared,
    presentationAnchorStore: AuthenticationPresentationAnchorStore =
      AuthenticationPresentationAnchorStore()
  ) {
    self.configuration = configuration
    self.now = now
    self.presentationAnchorStore = presentationAnchorStore
    self.session = session
  }

  func authorize() async throws -> EWSOAuthTokens {
    guard let configuration else { throw EWSOAuthError.configurationMissing }
    let request = try EWSOAuthRequest(configuration: configuration)
    let callback = try await authenticate(
      authorizationURL: request.authorizationURL,
      callbackScheme: configuration.callbackScheme
    )
    let code = try request.authorizationCode(from: callback)
    return try await exchange(
      configuration: configuration,
      parameters: [
        "client_id": configuration.clientIdentifier,
        "code": code,
        "code_verifier": request.codeVerifier,
        "grant_type": "authorization_code",
        "redirect_uri": request.redirectURI.absoluteString,
        "scope": configuration.scope,
      ]
    )
  }

  func refresh(_ tokens: EWSOAuthTokens) async throws -> EWSOAuthTokens {
    guard let configuration else { throw EWSOAuthError.configurationMissing }
    return try await exchange(
      configuration: configuration,
      parameters: [
        "client_id": configuration.clientIdentifier,
        "grant_type": "refresh_token",
        "refresh_token": tokens.refreshToken,
        "scope": configuration.scope,
      ],
      fallbackRefreshToken: tokens.refreshToken
    )
  }

  private func exchange(
    configuration: EWSOAuthConfiguration,
    parameters: [String: String],
    fallbackRefreshToken: String? = nil
  ) async throws -> EWSOAuthTokens {
    var request = URLRequest(url: configuration.tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = parameters.ewsFormURLEncodedData()
    let (data, response) = try await session.data(
      for: request,
      delegate: EWSOAuthTokenRedirectDelegate(tokenEndpoint: configuration.tokenEndpoint)
    )
    if let rejection = try? JSONDecoder().decode(EWSOAuthTokenErrorResponse.self, from: data),
      rejection.code == "invalid_grant"
    {
      throw EWSOAuthError.authorizationRejected
    }
    guard let response = response as? HTTPURLResponse else {
      throw EWSOAuthError.tokenExchangeFailed(status: nil)
    }
    guard
      (200..<300).contains(response.statusCode),
      let payload = try? JSONDecoder().decode(EWSOAuthTokenResponse.self, from: data),
      !payload.accessToken.isEmpty,
      payload.expiresIn > 0,
      let refreshToken = payload.refreshToken?.ewsNonEmpty ?? fallbackRefreshToken?.ewsNonEmpty
    else { throw EWSOAuthError.tokenExchangeFailed(status: response.statusCode) }
    return EWSOAuthTokens(
      accessToken: payload.accessToken,
      expiresAtMilliseconds: Int64(
        now().addingTimeInterval(TimeInterval(payload.expiresIn)).timeIntervalSince1970 * 1_000
      ),
      refreshToken: refreshToken
    )
  }

  private func authenticate(
    authorizationURL: URL,
    callbackScheme: String
  ) async throws -> URL {
    let authenticationID = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        guard self.authenticationID == nil else {
          continuation.resume(throwing: EWSOAuthError.webAuthenticationUnavailable)
          return
        }
        guard presentationAnchorStore.captureCurrent() else {
          continuation.resume(throwing: EWSOAuthError.webAuthenticationUnavailable)
          return
        }
        self.authenticationID = authenticationID
        authenticationContinuation = continuation
        let authenticationSession = ASWebAuthenticationSession(
          url: authorizationURL,
          callbackURLScheme: callbackScheme
        ) { [weak self] callbackURL, error in
          Task { @MainActor in
            self?.finishAuthentication(
              authenticationID: authenticationID,
              callbackURL: callbackURL,
              error: error
            )
          }
        }
        authenticationSession.presentationContextProvider = self
        authenticationSession.prefersEphemeralWebBrowserSession = false
        webAuthenticationSession = authenticationSession
        if !authenticationSession.start() {
          finishAuthentication(
            authenticationID: authenticationID,
            callbackURL: nil,
            error: EWSOAuthError.webAuthenticationUnavailable
          )
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancelAuthentication(authenticationID: authenticationID)
      }
    }
  }

  private func cancelAuthentication(authenticationID: UUID) {
    guard self.authenticationID == authenticationID else { return }
    let continuation = authenticationContinuation
    self.authenticationID = nil
    authenticationContinuation = nil
    webAuthenticationSession?.cancel()
    webAuthenticationSession = nil
    presentationAnchorStore.clear()
    continuation?.resume(throwing: CancellationError())
  }

  private func finishAuthentication(
    authenticationID: UUID,
    callbackURL: URL?,
    error: Error?
  ) {
    guard self.authenticationID == authenticationID else { return }
    guard let continuation = authenticationContinuation else { return }
    self.authenticationID = nil
    authenticationContinuation = nil
    webAuthenticationSession = nil
    presentationAnchorStore.clear()
    if let authenticationError = error as? ASWebAuthenticationSessionError,
      authenticationError.code == .canceledLogin
    {
      continuation.resume(throwing: CancellationError())
    } else if let error {
      continuation.resume(throwing: error)
    } else if let callbackURL {
      continuation.resume(returning: callbackURL)
    } else {
      continuation.resume(throwing: EWSOAuthError.invalidAuthorizationCallback)
    }
  }
}

enum EWSOAuthTokenRedirectPolicy {
  static func redirectedRequest(
    _ request: URLRequest,
    response: HTTPURLResponse,
    tokenEndpoint: URL
  ) -> URLRequest? {
    guard [307, 308].contains(response.statusCode),
      let redirectURL = request.url,
      EWSConnectionDefinition.hasSameOrigin(redirectURL, as: tokenEndpoint)
    else { return nil }
    return request
  }
}

private final class EWSOAuthTokenRedirectDelegate: NSObject, URLSessionTaskDelegate {
  private let tokenEndpoint: URL

  init(tokenEndpoint: URL) {
    self.tokenEndpoint = tokenEndpoint
  }

  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(
      EWSOAuthTokenRedirectPolicy.redirectedRequest(
        request,
        response: response,
        tokenEndpoint: tokenEndpoint
      )
    )
  }
}

extension EWSOAuthService: ASWebAuthenticationPresentationContextProviding {
  nonisolated func presentationAnchor(
    for session: ASWebAuthenticationSession
  ) -> ASPresentationAnchor {
    presentationAnchorStore.current()
  }
}

struct EWSOAuthRequest {
  let authorizationURL: URL
  let codeVerifier: String
  let redirectURI: URL
  private let state: String

  init(
    configuration: EWSOAuthConfiguration,
    codeVerifier: String = Self.randomValue(byteCount: 32),
    state: String = Self.randomValue(byteCount: 24)
  ) throws {
    guard
      let redirectURI = URL(string: "\(configuration.callbackScheme)://auth"),
      var components = URLComponents(
        url: configuration.authorizationEndpoint,
        resolvingAgainstBaseURL: false
      )
    else { throw EWSOAuthError.invalidConfiguration }
    self.codeVerifier = codeVerifier
    self.redirectURI = redirectURI
    self.state = state
    let challenge = Data(SHA256.hash(data: Data(codeVerifier.utf8))).ewsBase64URLString()
    components.queryItems =
      (components.queryItems ?? []) + [
        URLQueryItem(name: "client_id", value: configuration.clientIdentifier),
        URLQueryItem(name: "code_challenge", value: challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "scope", value: configuration.scope),
        URLQueryItem(name: "state", value: state),
      ]
    guard let authorizationURL = components.url else {
      throw EWSOAuthError.invalidConfiguration
    }
    self.authorizationURL = authorizationURL
  }

  func authorizationCode(from callbackURL: URL) throws -> String {
    guard
      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == redirectURI.scheme?.lowercased(),
      components.host?.lowercased() == redirectURI.host?.lowercased()
    else { throw EWSOAuthError.invalidAuthorizationCallback }
    guard
      components.queryItems?.first(where: { $0.name == "state" })?.value == state
    else { throw EWSOAuthError.invalidAuthorizationState }
    guard
      let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
      !code.isEmpty
    else { throw EWSOAuthError.invalidAuthorizationCallback }
    return code
  }

  private static func randomValue(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    precondition(
      SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess,
      "Secure random generation failed"
    )
    return Data(bytes).ewsBase64URLString()
  }
}

extension Data {
  fileprivate func ewsBase64URLString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

private struct EWSOAuthTokenResponse: Decodable {
  let accessToken: String
  let expiresIn: Int
  let refreshToken: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
  }
}

private struct EWSOAuthTokenErrorResponse: Decodable {
  let code: String

  enum CodingKeys: String, CodingKey {
    case code = "error"
  }
}

extension Dictionary where Key == String, Value == String {
  fileprivate func ewsFormURLEncodedData() -> Data {
    map { key, value in
      "\(key.ewsFormURLEncoded())=\(value.ewsFormURLEncoded())"
    }
    .sorted()
    .joined(separator: "&")
    .data(using: .utf8) ?? Data()
  }
}

extension String {
  fileprivate var ewsNonEmpty: String? {
    isEmpty ? nil : self
  }

  fileprivate func ewsFormURLEncoded() -> String {
    addingPercentEncoding(
      withAllowedCharacters: CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-._~")
      )
    ) ?? self
  }
}

struct EWSAmbiguousProviderActionError: LocalizedError {
  var errorDescription: String? {
    "Exchange may have applied this action. Reconcile the mailbox before retrying."
  }
}

enum EWSServerVersion: String, Codable, CaseIterable, Equatable, Sendable {
  case exchange2013SP1
  case exchange2016
  case exchange2019

  var requestVersion: String {
    switch self {
    case .exchange2013SP1, .exchange2016, .exchange2019:
      return "Exchange2013_SP1"
    }
  }
}

struct EWSAccount: Equatable, Sendable {
  let displayName: String
  let primaryEmailAddress: String
  let providerMailboxIdentifier: String
  let serverVersion: EWSServerVersion
}

/// Synchronizable, credential-free configuration for one on-premises EWS mailbox.
///
/// Example:
/// ```swift
/// let connectionId = definition.connectionId
/// ```
struct EWSConnectionDefinition: Codable, Equatable, Sendable {
  let authorizationMethod: MailAuthorizationMethod
  let emailAddress: String
  let endpoint: URL
  let providerAccountIdentifier: String
  let serverVersion: EWSServerVersion
  let username: String

  var connectionId: MailboxConnectionId {
    return MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .exchangeWebServices,
        value: providerAccountIdentifier
      )
    )
  }

  func matchesAuthorizationScope(_ other: Self) -> Bool {
    authorizationMethod == other.authorizationMethod
      && endpoint == other.endpoint
      && providerAccountIdentifier == other.providerAccountIdentifier
      && serverVersion == other.serverVersion
      && username == other.username
  }

  static func validatedEndpoint(_ value: String) throws -> URL {
    guard
      let endpoint = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
      endpoint.scheme?.lowercased() == "https",
      let host = endpoint.host?.lowercased(),
      !host.isEmpty,
      endpoint.user == nil,
      endpoint.password == nil,
      endpoint.query == nil,
      endpoint.fragment == nil,
      !exchangeOnlineHosts.contains(host),
      !exchangeOnlineHostSuffixes.contains(where: host.hasSuffix)
    else {
      throw EWSSetupError.onPremisesEndpointRequired
    }
    return endpoint
  }

  static func stableProviderAccountIdentifier(
    endpoint: URL,
    mailboxIdentifier: String
  ) throws -> String {
    guard
      let host = endpoint.host?.lowercased(),
      !host.isEmpty,
      !mailboxIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw EWSSetupError.invalidMailboxIdentity
    }
    let identityInput = [
      host,
      String(effectivePort(endpoint) ?? 443),
      endpoint.path,
      mailboxIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
    ].joined(separator: "\0")
    return Data(SHA256.hash(data: Data(identityInput.utf8)))
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func hasSameOrigin(_ candidate: URL, as endpoint: URL) -> Bool {
    candidate.scheme?.lowercased() == endpoint.scheme?.lowercased()
      && candidate.host?.lowercased() == endpoint.host?.lowercased()
      && effectivePort(candidate) == effectivePort(endpoint)
  }

  private static func effectivePort(_ url: URL) -> Int? {
    url.port ?? (url.scheme?.lowercased() == "https" ? 443 : nil)
  }

  private static let exchangeOnlineHosts: Set<String> = [
    "outlook.office.de",
    "outlook.office.com",
    "outlook.office365.com",
    "outlook.office365.us",
    "partner.outlook.cn",
    "webmail.apps.mil",
  ]

  private static let exchangeOnlineHostSuffixes = [
    ".microsoftonline.com",
    ".office.com",
    ".office.de",
    ".office365.com",
    ".office365.us",
    ".outlook.com",
    ".outlook.cn",
    ".apps.mil",
  ]
}

/// Combines an opaque device-held credential with its credential-free EWS definition.
///
/// This value belongs only in Keychain-backed device storage and must never enter Product Sync.
///
/// Example:
/// ```swift
/// try store.save(authorization, productAccountId: accountId)
/// ```
struct DeviceLocalEWSAuthorization: Codable, Equatable, Sendable {
  let authorizationGeneration: Int
  let credential: String
  let definition: EWSConnectionDefinition
  let hasOnlineArchive: Bool?
  let oauthTokens: EWSOAuthTokens?

  init(
    authorizationGeneration: Int = 0,
    credential: String,
    definition: EWSConnectionDefinition,
    hasOnlineArchive: Bool? = nil,
    oauthTokens: EWSOAuthTokens? = nil
  ) {
    self.authorizationGeneration = authorizationGeneration
    self.credential = credential
    self.definition = definition
    self.hasOnlineArchive = hasOnlineArchive
    self.oauthTokens = oauthTokens
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    authorizationGeneration =
      try container.decodeIfPresent(Int.self, forKey: .authorizationGeneration) ?? 0
    credential = try container.decode(String.self, forKey: .credential)
    definition = try container.decode(EWSConnectionDefinition.self, forKey: .definition)
    hasOnlineArchive = try container.decodeIfPresent(Bool.self, forKey: .hasOnlineArchive)
    oauthTokens = try container.decodeIfPresent(EWSOAuthTokens.self, forKey: .oauthTokens)
  }

  private enum CodingKeys: String, CodingKey {
    case authorizationGeneration
    case credential
    case definition
    case hasOnlineArchive
    case oauthTokens
  }
}

/// Performs device-local EWS operations without sending credentials or mailbox data to Product Sync.
///
/// Example:
/// ```swift
/// let account = try await client.verify(authorization)
/// ```
protocol EWSClient: Sendable {
  /// Verifies authorization and returns the stable mailbox identity and supported server version.
  func verify(_ authorization: DeviceLocalEWSAuthorization) async throws -> EWSAccount
  /// Loads provider folders and maps recognized Exchange distinguished roles.
  func loadFolders(
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSFolder]
  /// Reuses persisted distinguished-role mappings when resolving provider folders.
  func loadFolders(
    authorization: DeviceLocalEWSAuthorization,
    knownFolders: [EWSFolder]
  ) async throws -> [EWSFolder]
  /// Loads one resumable metadata page without fetching message bodies.
  func loadMessagePage(
    folder: EWSFolder,
    offset: Int,
    pageSize: Int,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> EWSMessagePage
  /// Fetches one message body from the on-premises provider.
  func loadMessageBody(
    itemId: String,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> String
  /// Reloads current item ids and change keys immediately before a mutation.
  func refreshMessageIdentities(
    _ messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSProviderMessage]
  /// Reloads current identities while preserving item-not-found outcomes per message.
  func refreshMessageIdentitiesAllowingMissing(
    _ messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSProviderMessage?]
  /// Recovers one externally moved item through its stable provider search key.
  func recoverMessageIdentity(
    _ message: EWSProviderMessage,
    folders: [EWSFolder],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> EWSMovedItemIdentity
  /// Applies one provider mutation for an already persisted pending action.
  func perform(
    _ action: ProviderMailAction,
    targetFolderId: String?,
    messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSMovedItemIdentity]
  /// Sends one Outbox message through the on-premises provider.
  func send(
    _ message: OutgoingMessage,
    authorization: DeviceLocalEWSAuthorization
  ) async throws
  /// Reconciles an Outbox idempotency key against Sent Items.
  func deliveryStatus(
    rfcMessageId: String,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> MailboxDeliveryStatus
}

extension EWSClient {
  func loadFolders(
    authorization: DeviceLocalEWSAuthorization,
    knownFolders _: [EWSFolder]
  ) async throws -> [EWSFolder] {
    try await loadFolders(authorization: authorization)
  }

  func loadFolders(
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> [EWSFolder] {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func loadMessagePage(
    folder _: EWSFolder,
    offset _: Int,
    pageSize _: Int,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> EWSMessagePage {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func loadMessageBody(
    itemId _: String,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> String {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func refreshMessageIdentities(
    _ messages: [EWSProviderMessage],
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> [EWSProviderMessage] {
    messages
  }

  func refreshMessageIdentitiesAllowingMissing(
    _ messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSProviderMessage?] {
    try await refreshMessageIdentities(messages, authorization: authorization).map(Optional.some)
  }

  func recoverMessageIdentity(
    _ message: EWSProviderMessage,
    folders _: [EWSFolder],
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> EWSMovedItemIdentity {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func perform(
    _ action: ProviderMailAction,
    targetFolderId _: String?,
    messages _: [EWSProviderMessage],
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> [EWSMovedItemIdentity] {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func send(
    _ message: OutgoingMessage,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func deliveryStatus(
    rfcMessageId _: String,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> MailboxDeliveryStatus {
    .unknown
  }
}

/// Persists EWS authorization only in this device's protected credential store.
///
/// Example:
/// ```swift
/// try store.save(authorization, productAccountId: session.productAccountId)
/// ```
protocol EWSAuthorizationPersisting: Sendable {
  /// Clears one device-local authorization.
  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws
  /// Clears all EWS authorizations for one Product Account on this device.
  func clearAll(productAccountId: String) throws
  /// Lists connection ids backed by device-local EWS authorizations.
  func connectionIds(productAccountId: String) throws -> [MailboxConnectionId]
  /// Loads one authorization from device-local protected storage.
  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> DeviceLocalEWSAuthorization?
  /// Saves one authorization without synchronizing the credential.
  func save(
    _ authorization: DeviceLocalEWSAuthorization,
    productAccountId: String
  ) throws
}

struct KeychainEWSAuthorizationStore: EWSAuthorizationPersisting {
  private let service = "dev.unwired.mail.exchange-web-services-authorization"

  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    let previous = try load(
      productAccountId: productAccountId,
      connectionId: connectionId
    )
    let previousIds = try rawConnectionIds(productAccountId: productAccountId)
    try KeychainStore.delete(service: service, account: account(productAccountId, connectionId))
    try KeychainStore.delete(
      service: service,
      account: legacyAccount(productAccountId, connectionId)
    )
    var ids = previousIds
    ids.remove(connectionId.rawValue)
    do {
      try saveConnectionIds(ids, productAccountId: productAccountId)
    } catch {
      if let previous {
        try? save(previous, productAccountId: productAccountId)
      } else {
        try? saveConnectionIds(previousIds, productAccountId: productAccountId)
      }
      throw error
    }
  }

  func clearAll(productAccountId: String) throws {
    for rawValue in try rawConnectionIds(productAccountId: productAccountId) {
      try KeychainStore.delete(
        service: service,
        account: account(productAccountId, rawConnectionId: rawValue)
      )
      try KeychainStore.delete(
        service: service,
        account: legacyAccount(productAccountId, rawConnectionId: rawValue)
      )
    }
    try KeychainStore.delete(service: service, account: manifestAccount(productAccountId))
    try KeychainStore.delete(service: service, account: legacyManifestAccount(productAccountId))
  }

  func connectionIds(productAccountId: String) throws -> [MailboxConnectionId] {
    let prefix = "\(MailProviderId.exchangeWebServices.rawValue):"
    return try rawConnectionIds(productAccountId: productAccountId)
      .sorted()
      .compactMap { rawValue in
        guard rawValue.hasPrefix(prefix) else { return nil }
        return MailboxConnectionId(
          providerMailboxIdentity: StableProviderMailboxIdentity(
            providerId: .exchangeWebServices,
            value: String(rawValue.dropFirst(prefix.count))
          )
        )
      }
  }

  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> DeviceLocalEWSAuthorization? {
    let currentAccount = account(productAccountId, connectionId)
    let legacy = legacyAccount(productAccountId, connectionId)
    let json =
      try KeychainStore.readString(service: service, account: currentAccount)
      ?? KeychainStore.readString(service: service, account: legacy)
    guard let json, let data = json.data(using: .utf8) else { return nil }
    let authorization = try JSONDecoder().decode(DeviceLocalEWSAuthorization.self, from: data)
    if try KeychainStore.readString(service: service, account: currentAccount) == nil {
      try KeychainStore.writeString(
        json,
        service: service,
        account: currentAccount,
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      )
      try KeychainStore.delete(service: service, account: legacy)
    }
    return authorization
  }

  func save(
    _ authorization: DeviceLocalEWSAuthorization,
    productAccountId: String
  ) throws {
    let data = try JSONEncoder().encode(authorization)
    guard let json = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    let previousIds = try rawConnectionIds(productAccountId: productAccountId)
    var ids = previousIds
    ids.insert(authorization.definition.connectionId.rawValue)
    try saveConnectionIds(ids, productAccountId: productAccountId)
    do {
      try KeychainStore.writeString(
        json,
        service: service,
        account: account(productAccountId, authorization.definition.connectionId),
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      )
    } catch {
      try? saveConnectionIds(previousIds, productAccountId: productAccountId)
      throw error
    }
  }

  private func rawConnectionIds(productAccountId: String) throws -> Set<String> {
    let currentAccount = manifestAccount(productAccountId)
    let legacyAccount = legacyManifestAccount(productAccountId)
    let json =
      try KeychainStore.readString(service: service, account: currentAccount)
      ?? KeychainStore.readString(service: service, account: legacyAccount)
    guard let json, let data = json.data(using: .utf8) else { return [] }
    let ids = Set(try JSONDecoder().decode([String].self, from: data))
    if try KeychainStore.readString(service: service, account: currentAccount) == nil {
      try saveConnectionIds(ids, productAccountId: productAccountId)
      try KeychainStore.delete(service: service, account: legacyAccount)
    }
    return ids
  }

  private func saveConnectionIds(
    _ ids: Set<String>,
    productAccountId: String
  ) throws {
    guard !ids.isEmpty else {
      try KeychainStore.delete(service: service, account: manifestAccount(productAccountId))
      return
    }
    let data = try JSONEncoder().encode(ids.sorted())
    guard let json = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(
      json,
      service: service,
      account: manifestAccount(productAccountId),
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }

  private func account(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId
  ) -> String {
    account(productAccountId, rawConnectionId: connectionId.rawValue)
  }

  private func account(
    _ productAccountId: String,
    rawConnectionId: String
  ) -> String {
    "credential\0\(productAccountId)\0\(rawConnectionId)"
  }

  private func manifestAccount(_ productAccountId: String) -> String {
    "manifest\0\(productAccountId)"
  }

  private func legacyAccount(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId
  ) -> String {
    legacyAccount(productAccountId, rawConnectionId: connectionId.rawValue)
  }

  private func legacyAccount(
    _ productAccountId: String,
    rawConnectionId: String
  ) -> String {
    "\(productAccountId)-\(rawConnectionId)"
  }

  private func legacyManifestAccount(_ productAccountId: String) -> String {
    "connections-\(productAccountId)"
  }
}

#if DEBUG || TESTING
  final class InMemoryEWSAuthorizationStore: EWSAuthorizationPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: DeviceLocalEWSAuthorization] = [:]

    func clear(
      productAccountId: String,
      connectionId: MailboxConnectionId
    ) throws {
      lock.withLock { values[key(productAccountId, connectionId)] = nil }
    }

    func clearAll(productAccountId: String) throws {
      let prefix = "\(productAccountId)\0"
      lock.withLock { values = values.filter { !$0.key.hasPrefix(prefix) } }
    }

    func connectionIds(productAccountId: String) throws -> [MailboxConnectionId] {
      let prefix = "\(productAccountId)\0"
      return lock.withLock {
        values.compactMap { key, authorization in
          key.hasPrefix(prefix) ? authorization.definition.connectionId : nil
        }
      }
    }

    func load(
      productAccountId: String,
      connectionId: MailboxConnectionId
    ) throws -> DeviceLocalEWSAuthorization? {
      lock.withLock { values[key(productAccountId, connectionId)] }
    }

    func save(
      _ authorization: DeviceLocalEWSAuthorization,
      productAccountId: String
    ) throws {
      lock.withLock {
        values[key(productAccountId, authorization.definition.connectionId)] = authorization
      }
    }

    private func key(
      _ productAccountId: String,
      _ connectionId: MailboxConnectionId
    ) -> String {
      "\(productAccountId)\0\(connectionId.rawValue)"
    }
  }
#endif

actor EWSOAuthRefreshCoordinator {
  private static let refreshLeewayMilliseconds: Int64 = 5 * 60 * 1_000

  private let authorizationStore: EWSAuthorizationPersisting
  private let now: @Sendable () -> Date
  private let oauthService: EWSOAuthAuthorizing
  private let onRefreshTaskJoined: (@Sendable () async -> Void)?
  private var refreshTaskOwners: [String: UUID] = [:]
  private var refreshTasks: [String: Task<EWSOAuthTokens, Error>] = [:]

  init(
    authorizationStore: EWSAuthorizationPersisting,
    now: @escaping @Sendable () -> Date,
    oauthService: EWSOAuthAuthorizing,
    onRefreshTaskJoined: (@Sendable () async -> Void)? = nil
  ) {
    self.authorizationStore = authorizationStore
    self.now = now
    self.oauthService = oauthService
    self.onRefreshTaskJoined = onRefreshTaskJoined
  }

  func refreshIfNeeded(
    _ authorization: DeviceLocalEWSAuthorization,
    productAccountId: String
  ) async throws -> DeviceLocalEWSAuthorization {
    guard authorization.definition.authorizationMethod == .oauth else { return authorization }
    guard
      let stored = try authorizationStore.load(
        productAccountId: productAccountId,
        connectionId: authorization.definition.connectionId
      ),
      stored.authorizationGeneration == authorization.authorizationGeneration,
      stored.definition.matchesAuthorizationScope(authorization.definition),
      let tokens = stored.oauthTokens
    else { throw MailboxConnectionAdapterError.authorizationRequired }
    let current = DeviceLocalEWSAuthorization(
      authorizationGeneration: stored.authorizationGeneration,
      credential: tokens.accessToken,
      definition: authorization.definition,
      hasOnlineArchive: stored.hasOnlineArchive,
      oauthTokens: tokens
    )
    let refreshDeadline =
      Int64(now().timeIntervalSince1970 * 1_000)
      + Self.refreshLeewayMilliseconds
    guard tokens.expiresAtMilliseconds <= refreshDeadline else { return current }
    let refreshKey = "\(productAccountId)\0\(authorization.definition.connectionId.rawValue)"
    let refreshedTokens: EWSOAuthTokens
    do {
      refreshedTokens = try await self.refreshedTokens(tokens, refreshKey: refreshKey)
    } catch EWSOAuthError.authorizationRejected {
      try authorizationStore.clear(
        productAccountId: productAccountId,
        connectionId: authorization.definition.connectionId
      )
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    let refreshed = DeviceLocalEWSAuthorization(
      authorizationGeneration: current.authorizationGeneration,
      credential: refreshedTokens.accessToken,
      definition: current.definition,
      hasOnlineArchive: current.hasOnlineArchive,
      oauthTokens: refreshedTokens
    )
    try authorizationStore.save(refreshed, productAccountId: productAccountId)
    return refreshed
  }

  private func refreshedTokens(
    _ tokens: EWSOAuthTokens,
    refreshKey: String
  ) async throws -> EWSOAuthTokens {
    let refreshTask: Task<EWSOAuthTokens, Error>
    if let inFlight = refreshTasks[refreshKey] {
      await onRefreshTaskJoined?()
      refreshTask = inFlight
    } else {
      let owner = UUID()
      refreshTask = Task { @MainActor [oauthService] in
        try await oauthService.refresh(tokens)
      }
      refreshTasks[refreshKey] = refreshTask
      refreshTaskOwners[refreshKey] = owner
      Task { [weak self] in
        _ = await refreshTask.result
        await self?.removeRefreshTask(refreshKey: refreshKey, owner: owner)
      }
    }
    return try await refreshTask.value
  }

  private func removeRefreshTask(refreshKey: String, owner: UUID) {
    guard refreshTaskOwners[refreshKey] == owner else { return }
    refreshTasks[refreshKey] = nil
    refreshTaskOwners[refreshKey] = nil
  }
}

extension MailboxConnectionCapabilities {
  static let exchangeWebServices = exchangeWebServices(hasOnlineArchive: true)

  static func exchangeWebServices(hasOnlineArchive: Bool) -> MailboxConnectionCapabilities {
    var providerActions = Set(ProviderMailAction.allCases)
    if !hasOnlineArchive {
      providerActions.remove(.archive)
    }
    return MailboxConnectionCapabilities(
      canCategorizeHistorical: false,
      canForward: true,
      canReadMessages: true,
      canRequestReadReceipts: true,
      canRegisterPush: false,
      canReply: true,
      canRespondToReadReceipts: false,
      canSearchProvider: false,
      canSend: true,
      canSynchronizeMetadata: true,
      providerActions: providerActions
    )
  }
}

protocol EWSLocalStateClearing {
  func clear(
    connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws
}

struct EWSLocalStateCleaner: EWSLocalStateClearing {
  private let authorizationStore: EWSAuthorizationPersisting
  private let bodyService: EWSMessageBodyService
  private let metadataStore: EWSMetadataPersisting
  private let outboxService: OutboxDeliveryService
  private let pendingActionService: PendingProviderActionService

  init(
    authorizationStore: EWSAuthorizationPersisting = KeychainEWSAuthorizationStore(),
    cache: GmailMessageBodyCaching = FileGmailMessageBodyCache(),
    client: EWSClient = SystemEWSClient(),
    keyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore(),
    metadataStore: EWSMetadataPersisting = SwiftDataEWSMetadataStore(),
    outboxService: OutboxDeliveryService = .shared,
    pendingActionService: PendingProviderActionService = .shared
  ) {
    self.authorizationStore = authorizationStore
    bodyService = EWSMessageBodyService(
      cache: cache,
      client: client,
      keyMaterialStore: keyMaterialStore
    )
    self.metadataStore = metadataStore
    self.outboxService = outboxService
    self.pendingActionService = pendingActionService
  }

  func clear(
    connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try authorizationStore.clear(
      productAccountId: session.productAccountId,
      connectionId: connectionId
    )
    try metadataStore.clear(
      productAccountId: session.productAccountId,
      connectionId: connectionId
    )
    let connection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: .exchangeWebServices,
      connectedAt: 0,
      displayName: "",
      id: connectionId,
      lastVerifiedAt: 0,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 0
    )
    try await pendingActionService.clear(connection: connection, session: session)
    try await outboxService.clear(connection: connection, session: session)
    try bodyService.clear(connection: connection, session: session)
  }
}

/// Connects a verified full-capability on-premises EWS mailbox without syncing its credential.
///
/// Example:
/// ```swift
/// let connection = try await service.connect(
///   authorizationMethod: .password,
///   credential: password,
///   emailAddress: email,
///   endpoint: endpoint,
///   username: username,
///   session: session,
///   isSessionCurrent: { $0 == session }
/// )
/// ```
@MainActor
struct EWSSetupService {
  private let authorizationStore: EWSAuthorizationPersisting
  private let client: EWSClient
  private let definitionSyncService: MailboxConnectionDefinitionSyncing
  private let localStateCleaner: EWSLocalStateClearing
  private let now: () -> Date
  private let oauthService: EWSOAuthAuthorizing
  private let syncGate: MailboxConnectionSyncGate

  init(
    authorizationStore: EWSAuthorizationPersisting = KeychainEWSAuthorizationStore(),
    client: EWSClient = SystemEWSClient(),
    definitionSyncService: MailboxConnectionDefinitionSyncing =
      MailboxConnectionSyncService(),
    localStateCleaner: EWSLocalStateClearing? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    oauthService: EWSOAuthAuthorizing? = nil,
    syncGate: MailboxConnectionSyncGate = .shared
  ) {
    self.authorizationStore = authorizationStore
    self.client = client
    self.definitionSyncService = definitionSyncService
    self.localStateCleaner =
      localStateCleaner
      ?? EWSLocalStateCleaner(authorizationStore: authorizationStore, client: client)
    self.now = now
    self.oauthService = oauthService ?? EWSOAuthService()
    self.syncGate = syncGate
  }

  // swiftlint:disable cyclomatic_complexity function_body_length
  /// Verifies the server, mailbox identity, version, and required roles before persisting setup.
  func connect(
    authorizationMethod: MailAuthorizationMethod,
    credential: String,
    emailAddress: String,
    endpoint endpointValue: String,
    saveIntent: MailboxConnectionDefinitionSaveIntent = .authorizeExisting,
    username: String,
    session: ProductAccountSessionSnapshot,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection {
    guard isSessionCurrent(session) else { throw CancellationError() }
    let endpoint = try EWSConnectionDefinition.validatedEndpoint(endpointValue)
    let emailAddress = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !emailAddress.isEmpty, !username.isEmpty else {
      throw EWSSetupError.invalidMailboxIdentity
    }
    let oauthTokens = authorizationMethod == .oauth ? try await oauthService.authorize() : nil
    let credential = oauthTokens?.accessToken ?? credential
    guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw EWSSetupError.authenticationFailed
    }

    let provisionalIdentifier = try EWSConnectionDefinition.stableProviderAccountIdentifier(
      endpoint: endpoint,
      mailboxIdentifier: emailAddress
    )
    let provisionalDefinition = EWSConnectionDefinition(
      authorizationMethod: authorizationMethod,
      emailAddress: emailAddress,
      endpoint: endpoint,
      providerAccountIdentifier: provisionalIdentifier,
      serverVersion: .exchange2013SP1,
      username: username
    )
    let account = try await client.verify(
      DeviceLocalEWSAuthorization(
        credential: credential,
        definition: provisionalDefinition,
        oauthTokens: oauthTokens
      )
    )
    guard isSessionCurrent(session) else { throw CancellationError() }

    let providerAccountIdentifier =
      try EWSConnectionDefinition.stableProviderAccountIdentifier(
        endpoint: endpoint,
        mailboxIdentifier: account.providerMailboxIdentifier
      )
    let definition = EWSConnectionDefinition(
      authorizationMethod: authorizationMethod,
      emailAddress: account.primaryEmailAddress,
      endpoint: endpoint,
      providerAccountIdentifier: providerAccountIdentifier,
      serverVersion: account.serverVersion,
      username: username
    )
    var authorization = DeviceLocalEWSAuthorization(
      credential: credential,
      definition: definition,
      oauthTokens: oauthTokens
    )
    let requiredRoles = Set(EWSFolderRole.allCases.filter { $0 != .archive })
    let resolvedRoles = Set(
      try await client.loadFolders(authorization: authorization).compactMap(\.role)
    )
    guard requiredRoles.isSubset(of: resolvedRoles) else {
      throw EWSSetupError.missingRequiredMailboxRole
    }
    authorization = DeviceLocalEWSAuthorization(
      credential: credential,
      definition: definition,
      hasOnlineArchive: resolvedRoles.contains(.archive),
      oauthTokens: oauthTokens
    )
    guard isSessionCurrent(session) else { throw CancellationError() }
    try Task.checkCancellation()

    let timestamp = Int64(now().timeIntervalSince1970 * 1_000)
    let commitRevision = await syncGate.revision(for: definition.connectionId)
    let synchronizedSnapshot = try await definitionSyncService.loadSnapshot(session: session)
    guard isSessionCurrent(session) else { throw CancellationError() }
    let synchronizedDefinition = synchronizedSnapshot.connections
      .first(where: { $0.id == definition.connectionId })
    let connectedAt = synchronizedDefinition?.connectedAt ?? timestamp
    let savedSnapshot = try await saveDefinition(
      definition.synchronizedDefinition(
        authorizationGeneration: synchronizedDefinition?.authorizationGeneration ?? 0,
        connectedAt: connectedAt,
        displayName: account.primaryEmailAddress
      ),
      intent: saveIntent,
      session: session
    )
    guard isSessionCurrent(session) else { throw CancellationError() }
    let savedDefinition = try Self.activeDefinition(
      in: savedSnapshot,
      connectionId: definition.connectionId
    )
    let currentSnapshot = try await definitionSyncService.loadSnapshot(session: session)
    guard isSessionCurrent(session) else { throw CancellationError() }
    let currentDefinition = try Self.activeDefinition(
      in: currentSnapshot,
      connectionId: definition.connectionId
    )
    guard
      currentDefinition.authorizationGeneration == savedDefinition.authorizationGeneration
    else {
      throw CancellationError()
    }
    return try await syncGate.withLock(
      definition.connectionId,
      ifUnchangedSince: commitRevision
    ) {
      guard isSessionCurrent(session) else { throw CancellationError() }
      try Task.checkCancellation()
      let localAuthorizationGeneration = try authorizationStore.load(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      )?.authorizationGeneration
      if try definitionSyncService.requiresLocalCleanup(
        in: currentSnapshot,
        connectionId: definition.connectionId,
        localAuthorizationGeneration: localAuthorizationGeneration,
        session: session
      ) {
        try await localStateCleaner.clear(
          connectionId: definition.connectionId,
          session: session
        )
        try definitionSyncService.recordLocalCleanup(
          in: currentSnapshot,
          connectionId: definition.connectionId,
          session: session
        )
      }
      guard isSessionCurrent(session) else { throw CancellationError() }
      try Task.checkCancellation()
      let savedAuthorization = DeviceLocalEWSAuthorization(
        authorizationGeneration: currentDefinition.authorizationGeneration,
        credential: authorization.credential,
        definition: authorization.definition,
        hasOnlineArchive: authorization.hasOnlineArchive,
        oauthTokens: authorization.oauthTokens
      )
      try authorizationStore.save(savedAuthorization, productAccountId: session.productAccountId)
      return MailboxConnection(
        authorizationGeneration: savedAuthorization.authorizationGeneration,
        authorizationState: .authorized,
        capabilities: .exchangeWebServices(hasOnlineArchive: resolvedRoles.contains(.archive)),
        connectedAt: currentDefinition.connectedAt,
        displayName: account.primaryEmailAddress,
        id: definition.connectionId,
        lastVerifiedAt: timestamp,
        productAccountId: ProductAccountId(session.productAccountId),
        trustedDeviceId: session.trustedDeviceId,
        updatedAt: timestamp
      )
    }
  }

  private static func activeDefinition(
    in snapshot: MailboxConnectionSyncSnapshot,
    connectionId: MailboxConnectionId
  ) throws -> MailboxConnectionDefinition {
    guard
      !snapshot.removedConnectionIds.contains(connectionId),
      let definition = snapshot.connections.first(where: { $0.id == connectionId })
    else {
      throw MailboxConnectionAdapterError.connectionRemoved
    }
    return definition
  }

  private func saveDefinition(
    _ definition: MailboxConnectionDefinition,
    intent: MailboxConnectionDefinitionSaveIntent,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    switch intent {
    case .add(let removalObservation):
      return try await definitionSyncService.recreateDefinition(
        definition,
        after: removalObservation,
        session: session
      )
    case .authorizeExisting:
      return try await definitionSyncService.saveDefinition(definition, session: session)
    }
  }
  // swiftlint:enable cyclomatic_complexity function_body_length
}

enum EWSFolderRole: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
  case archive
  case drafts
  case inbox
  case sent
  case spam
  case trash

  var mailboxRole: MailboxRole {
    switch self {
    case .archive: return .archive
    case .drafts: return .drafts
    case .inbox: return .inbox
    case .sent: return .sent
    case .spam: return .spam
    case .trash: return .trash
    }
  }
}

struct EWSFolder: Codable, Equatable, Hashable, Sendable {
  let changeKey: String?
  let displayName: String
  let folderClass: String?
  let id: String
  let isArchiveHierarchy: Bool?
  let isOutbox: Bool?
  let isSearchFolder: Bool?
  let isSentHierarchy: Bool?
  let isTrashHierarchy: Bool?
  let parentFolderId: String?
  let role: EWSFolderRole?

  init(
    changeKey: String?,
    displayName: String,
    folderClass: String? = nil,
    id: String,
    isArchiveHierarchy: Bool? = nil,
    isOutbox: Bool? = nil,
    isSearchFolder: Bool? = nil,
    isSentHierarchy: Bool? = nil,
    isTrashHierarchy: Bool? = nil,
    parentFolderId: String? = nil,
    role: EWSFolderRole?
  ) {
    self.changeKey = changeKey
    self.displayName = displayName
    self.folderClass = folderClass
    self.id = id
    self.isArchiveHierarchy = isArchiveHierarchy
    self.isOutbox = isOutbox
    self.isSearchFolder = isSearchFolder
    self.isSentHierarchy = isSentHierarchy
    self.isTrashHierarchy = isTrashHierarchy
    self.parentFolderId = parentFolderId
    self.role = role
  }

  var isMailFolder: Bool {
    guard let folderClass else { return true }
    let normalizedClass = folderClass.lowercased()
    return normalizedClass == "ipf.note" || normalizedClass.hasPrefix("ipf.note.")
  }
}

struct EWSProviderMessage: Codable, Equatable, Sendable {
  var bccRecipients: [String]
  var categoryId: String?
  var categoryIds: [String]?
  let ccRecipients: [String]
  var changeKey: String
  let conversationId: String?
  let from: String?
  var hasAttachments: Bool? = .none
  let internetMessageId: String?
  let isDraft: Bool
  var isFlagged: Bool
  var isRead: Bool
  var itemId: String
  var parentFolderId: String
  let receivedAtMilliseconds: Int64
  let replyTo: [String]
  var stableProviderId: String
  let subject: String
  let summary: String
  let toRecipients: [String]

  init(
    bccRecipients: [String],
    categoryId: String? = nil,
    categoryIds: [String]? = nil,
    ccRecipients: [String],
    changeKey: String,
    conversationId: String?,
    from: String?,
    hasAttachments: Bool? = nil,
    internetMessageId: String?,
    isDraft: Bool,
    isFlagged: Bool = false,
    isRead: Bool,
    itemId: String,
    parentFolderId: String,
    receivedAtMilliseconds: Int64,
    replyTo: [String],
    stableProviderId: String,
    subject: String,
    summary: String,
    toRecipients: [String]
  ) {
    self.bccRecipients = bccRecipients
    self.categoryId = categoryId
    self.categoryIds = categoryIds
    self.ccRecipients = ccRecipients
    self.changeKey = changeKey
    self.conversationId = conversationId
    self.from = from
    self.hasAttachments = hasAttachments
    self.internetMessageId = internetMessageId
    self.isDraft = isDraft
    self.isFlagged = isFlagged
    self.isRead = isRead
    self.itemId = itemId
    self.parentFolderId = parentFolderId
    self.receivedAtMilliseconds = receivedAtMilliseconds
    self.replyTo = replyTo
    self.stableProviderId = stableProviderId
    self.subject = subject
    self.summary = summary
    self.toRecipients = toRecipients
  }

  func mailboxMetadata(
    connection: MailboxConnection,
    foldersById: [String: EWSFolder]
  ) -> MailboxMessageMetadata {
    let folder = foldersById[parentFolderId]
    var states: [String] = []
    if !isRead { states.append("UNREAD") }
    if isFlagged { states.append("STARRED") }
    if isDraft { states.append("DRAFT") }
    if folder?.isArchiveHierarchy == true {
      states.append(Self.archiveHierarchyStateId)
    }
    if let role = folder?.role {
      states.append(Self.providerStateId(role.mailboxRole))
    } else {
      if folder?.isArchiveHierarchy == true {
        states.append(Self.providerStateId(.archive))
      }
      if Self.isTrashHierarchy(
        folderId: parentFolderId,
        foldersById: foldersById
      ) {
        states.append(Self.providerStateId(.trash))
      }
      if Self.isSpamHierarchy(
        folderId: parentFolderId,
        foldersById: foldersById
      ) {
        states.append(Self.providerStateId(.spam))
      }
      states.append(Self.customFolderStateId(parentFolderId))
    }
    return MailboxMessageMetadata(
      categoryId: categoryId,
      connectionId: connection.id,
      from: from,
      isHistorical: receivedAtMilliseconds < connection.connectedAt,
      providerInternalDateMilliseconds: receivedAtMilliseconds,
      providerMessageId: stableProviderId,
      providerStateIds: states.sorted(),
      providerThreadId: Self.nonEmpty(conversationId)
        ?? Self.nonEmpty(internetMessageId)
        ?? "message:\(connection.id.rawValue):\(stableProviderId)",
      recipientHeaders: toRecipients + ccRecipients,
      replyTo: replyTo.first,
      rfcMessageId: internetMessageId,
      snippet: summary,
      subject: Self.nonEmpty(subject) ?? "(No subject)",
      categoryIds: categoryIds,
      bccRecipients: bccRecipients,
      hasAttachments: hasAttachments ?? false
    )
  }

  static func providerStateId(_ role: MailboxRole) -> String {
    switch role {
    case .inbox: return "INBOX"
    case .drafts: return "DRAFT"
    case .sent: return "SENT"
    case .archive: return "ARCHIVE"
    case .spam: return "SPAM"
    case .trash: return "TRASH"
    }
  }

  static let archiveHierarchyStateId = "EWS_ARCHIVE_HIERARCHY"

  static func customFolderStateId(_ id: String) -> String {
    let encoded = Data(id.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "ews-folder:\(encoded)"
  }

  static func inheritedRoleStateIds(
    folderId: String,
    foldersById: [String: EWSFolder]
  ) -> Set<String> {
    var states: Set<String> = []
    if isTrashHierarchy(folderId: folderId, foldersById: foldersById) {
      states.insert(providerStateId(.trash))
    }
    if isSpamHierarchy(folderId: folderId, foldersById: foldersById) {
      states.insert(providerStateId(.spam))
    }
    return states
  }

  private static func isTrashHierarchy(
    folderId: String,
    foldersById: [String: EWSFolder]
  ) -> Bool {
    var currentFolderId: String? = folderId
    var visitedFolderIds: Set<String> = []
    while let candidateId = currentFolderId,
      visitedFolderIds.insert(candidateId).inserted,
      let folder = foldersById[candidateId]
    {
      if folder.role == .trash || folder.isTrashHierarchy == true { return true }
      currentFolderId = folder.parentFolderId
    }
    return false
  }

  private static func isSpamHierarchy(
    folderId: String,
    foldersById: [String: EWSFolder]
  ) -> Bool {
    var currentFolderId: String? = folderId
    var visitedFolderIds: Set<String> = []
    while let candidateId = currentFolderId,
      visitedFolderIds.insert(candidateId).inserted,
      let folder = foldersById[candidateId]
    {
      if folder.role == .spam { return true }
      currentFolderId = folder.parentFolderId
    }
    return false
  }

  static func folderId(fromProviderStateId stateId: String) -> String? {
    let prefix = "ews-folder:"
    guard stateId.hasPrefix(prefix) else { return nil }
    var value = String(stateId.dropFirst(prefix.count))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    guard let data = Data(base64Encoded: value) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }
}

struct EWSMessagePage: Equatable, Sendable {
  let messages: [EWSProviderMessage]
  let nextOffset: Int?
}

struct EWSMovedItemIdentity: Equatable, Sendable {
  let changeKey: String
  let destinationFolderId: String?
  let itemId: String
  let stableProviderId: String

  init(
    changeKey: String,
    destinationFolderId: String? = nil,
    itemId: String,
    stableProviderId: String
  ) {
    self.changeKey = changeKey
    self.destinationFolderId = destinationFolderId
    self.itemId = itemId
    self.stableProviderId = stableProviderId
  }
}

/// Captures connection-scoped EWS metadata and resumable full-scan reconciliation state.
///
/// Example:
/// ```swift
/// let complete = snapshot.historicalMetadataBackfillIsComplete
/// ```
struct EWSMetadataSnapshot: Codable, Equatable, Sendable {
  var completedHistoricalBackfillFolderIds: Set<String>? = []
  var reconciliationAtByFolderId: [String: Int64]? = [:]
  var folders: [EWSFolder]
  var messages: [EWSProviderMessage]
  var missingFolderIds: Set<String>? = []
  var nextOffsetsByFolderId: [String: Int]
  var pendingVerificationFolderIds: Set<String>? = []
  var deletionCandidatesByFolderId: [String: Set<String>]? = [:]
  var reconciliationMessageIdsByFolderId: [String: Set<String>] = [:]
  var hasInitialMailboxAvailability: Bool

  var historicalMetadataBackfillIsComplete: Bool {
    hasInitialMailboxAvailability && nextOffsetsByFolderId.isEmpty
      && completedFolderIds.isSuperset(of: folders.map(\.id))
  }

  var completedFolderIds: Set<String> {
    if let completedHistoricalBackfillFolderIds {
      return completedHistoricalBackfillFolderIds
    }
    return hasInitialMailboxAvailability && nextOffsetsByFolderId.isEmpty
      ? Set(folders.map(\.id))
      : []
  }
}

struct EWSMetadataMessageChanges: Sendable {
  let deletingStableProviderIds: Set<String>
  let reconciliationChanges: EWSMetadataReconciliationChanges
  let upserting: [EWSProviderMessage]

  init(
    deletingStableProviderIds: Set<String> = [],
    reconciliationChanges: EWSMetadataReconciliationChanges = .init(),
    upserting: [EWSProviderMessage]
  ) {
    self.deletingStableProviderIds = deletingStableProviderIds
    self.reconciliationChanges = reconciliationChanges
    self.upserting = upserting
  }
}

struct EWSMetadataReconciliationChanges: Sendable {
  let addingObservedIdsByFolderId: [String: Set<String>]
  let clearingCandidateFolderIds: Set<String>
  let clearingObservedFolderIds: Set<String>
  let replacingCandidatesByFolderId: [String: Set<String>]

  init(
    addingObservedIdsByFolderId: [String: Set<String>] = [:],
    clearingCandidateFolderIds: Set<String> = [],
    clearingObservedFolderIds: Set<String> = [],
    replacingCandidatesByFolderId: [String: Set<String>] = [:]
  ) {
    self.addingObservedIdsByFolderId = addingObservedIdsByFolderId
    self.clearingCandidateFolderIds = clearingCandidateFolderIds
    self.clearingObservedFolderIds = clearingObservedFolderIds
    self.replacingCandidatesByFolderId = replacingCandidatesByFolderId
  }
}

/// Persists device-local EWS metadata while excluding message bodies and credentials.
///
/// Example:
/// ```swift
/// try store.save(snapshot, productAccountId: accountId, connectionId: connectionId)
/// ```
protocol EWSMetadataPersisting {
  /// Clears all body-free EWS metadata for one Product Account.
  func clear(productAccountId: String) throws
  /// Clears body-free EWS metadata for one connection.
  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws
  /// Loads a connection's resumable metadata snapshot.
  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> EWSMetadataSnapshot?
  /// Atomically saves connection state and either replaces or incrementally changes messages.
  func save(
    _ snapshot: EWSMetadataSnapshot,
    productAccountId: String,
    connectionId: MailboxConnectionId,
    messageChanges: EWSMetadataMessageChanges?
  ) throws
}

extension EWSMetadataPersisting {
  /// Saves a complete connection snapshot, replacing its stored messages.
  func save(
    _ snapshot: EWSMetadataSnapshot,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    try save(
      snapshot,
      productAccountId: productAccountId,
      connectionId: connectionId,
      messageChanges: nil
    )
  }
}

/// SwiftData record for one connection's encoded, body-free EWS metadata snapshot.
///
/// Example:
/// ```swift
/// let record = DurableEWSMetadataSnapshotRecord(
///   connectionIdRawValue: connectionId.rawValue,
///   encodedSnapshot: data,
///   productAccountId: accountId,
///   storageKey: key
/// )
/// ```
@Model
final class DurableEWSMetadataSnapshotRecord {
  var connectionIdRawValue: String
  var encodedSnapshot: Data
  var productAccountId: String
  @Attribute(.unique) var storageKey: String

  init(
    connectionIdRawValue: String,
    encodedSnapshot: Data,
    productAccountId: String,
    storageKey: String
  ) {
    self.connectionIdRawValue = connectionIdRawValue
    self.encodedSnapshot = encodedSnapshot
    self.productAccountId = productAccountId
    self.storageKey = storageKey
  }

  func snapshot() throws -> EWSMetadataSnapshot {
    try JSONDecoder().decode(EWSMetadataSnapshot.self, from: encodedSnapshot)
  }
}

/// SwiftData record for connection-level EWS folders and reconciliation state.
@Model
final class DurableEWSMetadataStateRecord {
  var connectionIdRawValue: String
  var encodedState: Data
  var productAccountId: String
  @Attribute(.unique) var storageKey: String

  init(
    connectionIdRawValue: String,
    encodedState: Data,
    productAccountId: String,
    storageKey: String
  ) {
    self.connectionIdRawValue = connectionIdRawValue
    self.encodedState = encodedState
    self.productAccountId = productAccountId
    self.storageKey = storageKey
  }

  func snapshot() throws -> EWSMetadataSnapshot {
    try JSONDecoder().decode(EWSMetadataSnapshot.self, from: encodedState)
  }
}

/// SwiftData record for one body-free EWS message.
@Model
final class DurableEWSMessageMetadataRecord {
  var connectionIdRawValue: String
  var encodedMessage: Data
  var productAccountId: String
  var stableProviderId: String
  @Attribute(.unique) var storageKey: String

  init(
    connectionIdRawValue: String,
    encodedMessage: Data,
    productAccountId: String,
    stableProviderId: String,
    storageKey: String
  ) {
    self.connectionIdRawValue = connectionIdRawValue
    self.encodedMessage = encodedMessage
    self.productAccountId = productAccountId
    self.stableProviderId = stableProviderId
    self.storageKey = storageKey
  }

  func message() throws -> EWSProviderMessage {
    try JSONDecoder().decode(EWSProviderMessage.self, from: encodedMessage)
  }
}

/// SwiftData record for one observed or candidate message in a reconciliation pass.
@Model
final class DurableEWSReconciliationMetadataRecord {
  var connectionIdRawValue: String
  var folderId: String
  var kindRawValue: String
  var productAccountId: String
  var stableProviderId: String
  @Attribute(.unique) var storageKey: String

  init(
    connectionIdRawValue: String,
    folderId: String,
    kindRawValue: String,
    productAccountId: String,
    stableProviderId: String,
    storageKey: String
  ) {
    self.connectionIdRawValue = connectionIdRawValue
    self.folderId = folderId
    self.kindRawValue = kindRawValue
    self.productAccountId = productAccountId
    self.stableProviderId = stableProviderId
    self.storageKey = storageKey
  }
}

/// Stores body-free EWS metadata in a connection-scoped SwiftData container.
///
/// Example:
/// ```swift
/// try store.save(snapshot, productAccountId: accountId, connectionId: connectionId)
/// ```
struct SwiftDataEWSMetadataStore: EWSMetadataPersisting {
  private enum ReconciliationKind: String {
    case candidate
    case observed
  }

  private let containerResult: Result<ModelContainer, Error>

  static var schema: Schema {
    Schema([
      DurableEWSMetadataSnapshotRecord.self,
      DurableEWSMetadataStateRecord.self,
      DurableEWSMessageMetadataRecord.self,
      DurableEWSReconciliationMetadataRecord.self,
    ])
  }

  init(container: ModelContainer? = nil) {
    containerResult = Result {
      if let container { return container }
      let schema = Self.schema
      let configuration = ModelConfiguration("EWSMetadata", schema: schema)
      return try ModelContainer(for: schema, configurations: [configuration])
    }
  }

  /// Deletes every EWS snapshot for a Product Account from the local database.
  func clear(productAccountId: String) throws {
    let context = try makeContext()
    let legacyRecords = try context.fetch(
      FetchDescriptor<DurableEWSMetadataSnapshotRecord>(
        predicate: #Predicate { $0.productAccountId == productAccountId }
      )
    )
    let stateRecords = try context.fetch(
      FetchDescriptor<DurableEWSMetadataStateRecord>(
        predicate: #Predicate { $0.productAccountId == productAccountId }
      )
    )
    let messageRecords = try context.fetch(
      FetchDescriptor<DurableEWSMessageMetadataRecord>(
        predicate: #Predicate { $0.productAccountId == productAccountId }
      )
    )
    let reconciliationRecords = try context.fetch(
      FetchDescriptor<DurableEWSReconciliationMetadataRecord>(
        predicate: #Predicate { $0.productAccountId == productAccountId }
      )
    )
    for record in legacyRecords { context.delete(record) }
    for record in stateRecords { context.delete(record) }
    for record in messageRecords { context.delete(record) }
    for record in reconciliationRecords { context.delete(record) }
    try context.save()
  }

  /// Deletes one connection's EWS snapshot from the local database.
  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    let context = try makeContext()
    if let record = try legacyRecord(productAccountId, connectionId, context: context) {
      context.delete(record)
    }
    if let record = try stateRecord(productAccountId, connectionId, context: context) {
      context.delete(record)
    }
    for record in try messageRecords(productAccountId, connectionId, context: context) {
      context.delete(record)
    }
    for record in try reconciliationRecords(productAccountId, connectionId, context: context) {
      context.delete(record)
    }
    try context.save()
  }

  /// Loads one connection's body-free snapshot from the local database.
  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> EWSMetadataSnapshot? {
    let context = try makeContext()
    if try stateRecord(productAccountId, connectionId, context: context) == nil,
      let legacy = try legacyRecord(productAccountId, connectionId, context: context)
    {
      try persist(
        legacy.snapshot(),
        productAccountId: productAccountId,
        connectionId: connectionId,
        messageChanges: nil,
        context: context
      )
      context.delete(legacy)
      try context.save()
    }
    guard
      let state = try stateRecord(productAccountId, connectionId, context: context)
    else { return nil }
    var snapshot = try state.snapshot()
    snapshot.messages = try messageRecords(
      productAccountId,
      connectionId,
      context: context
    ).map { try $0.message() }
    for record in try reconciliationRecords(
      productAccountId,
      connectionId,
      context: context
    ) {
      if record.kindRawValue == ReconciliationKind.observed.rawValue {
        snapshot.reconciliationMessageIdsByFolderId[record.folderId, default: []]
          .insert(record.stableProviderId)
      } else if record.kindRawValue == ReconciliationKind.candidate.rawValue {
        var candidates = snapshot.deletionCandidatesByFolderId ?? [:]
        candidates[record.folderId, default: []].insert(record.stableProviderId)
        snapshot.deletionCandidatesByFolderId = candidates
      }
    }
    return snapshot
  }

  /// Atomically inserts or updates one connection's body-free snapshot.
  func save(
    _ snapshot: EWSMetadataSnapshot,
    productAccountId: String,
    connectionId: MailboxConnectionId,
    messageChanges: EWSMetadataMessageChanges?
  ) throws {
    let context = try makeContext()
    let hasState = try stateRecord(productAccountId, connectionId, context: context) != nil
    if !hasState,
      let legacy = try legacyRecord(productAccountId, connectionId, context: context)
    {
      context.delete(legacy)
    }
    try persist(
      snapshot,
      productAccountId: productAccountId,
      connectionId: connectionId,
      messageChanges: hasState ? messageChanges : nil,
      context: context
    )
    try context.save()
  }

  private func makeContext() throws -> ModelContext {
    try ModelContext(containerResult.get())
  }

  private func legacyRecord(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws -> DurableEWSMetadataSnapshotRecord? {
    let connectionIdRawValue = connectionId.rawValue
    var descriptor = FetchDescriptor<DurableEWSMetadataSnapshotRecord>(
      predicate: #Predicate {
        $0.productAccountId == productAccountId
          && $0.connectionIdRawValue == connectionIdRawValue
      }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  private func stateRecord(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws -> DurableEWSMetadataStateRecord? {
    let connectionIdRawValue = connectionId.rawValue
    var descriptor = FetchDescriptor<DurableEWSMetadataStateRecord>(
      predicate: #Predicate {
        $0.productAccountId == productAccountId
          && $0.connectionIdRawValue == connectionIdRawValue
      }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  private func messageRecords(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws -> [DurableEWSMessageMetadataRecord] {
    let connectionIdRawValue = connectionId.rawValue
    return try context.fetch(
      FetchDescriptor<DurableEWSMessageMetadataRecord>(
        predicate: #Predicate {
          $0.productAccountId == productAccountId
            && $0.connectionIdRawValue == connectionIdRawValue
        }
      )
    )
  }

  private func messageRecord(
    storageKey: String,
    context: ModelContext
  ) throws -> DurableEWSMessageMetadataRecord? {
    var descriptor = FetchDescriptor<DurableEWSMessageMetadataRecord>(
      predicate: #Predicate { $0.storageKey == storageKey }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  private func reconciliationRecords(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws -> [DurableEWSReconciliationMetadataRecord] {
    let connectionIdRawValue = connectionId.rawValue
    return try context.fetch(
      FetchDescriptor<DurableEWSReconciliationMetadataRecord>(
        predicate: #Predicate {
          $0.productAccountId == productAccountId
            && $0.connectionIdRawValue == connectionIdRawValue
        }
      )
    )
  }

  private func reconciliationRecords(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId,
    folderId: String,
    kind: ReconciliationKind,
    context: ModelContext
  ) throws -> [DurableEWSReconciliationMetadataRecord] {
    let connectionIdRawValue = connectionId.rawValue
    let kindRawValue = kind.rawValue
    return try context.fetch(
      FetchDescriptor<DurableEWSReconciliationMetadataRecord>(
        predicate: #Predicate {
          $0.productAccountId == productAccountId
            && $0.connectionIdRawValue == connectionIdRawValue
            && $0.folderId == folderId
            && $0.kindRawValue == kindRawValue
        }
      )
    )
  }

  private func reconciliationRecord(
    storageKey: String,
    context: ModelContext
  ) throws -> DurableEWSReconciliationMetadataRecord? {
    var descriptor = FetchDescriptor<DurableEWSReconciliationMetadataRecord>(
      predicate: #Predicate { $0.storageKey == storageKey }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  private func persist(
    _ snapshot: EWSMetadataSnapshot,
    productAccountId: String,
    connectionId: MailboxConnectionId,
    messageChanges: EWSMetadataMessageChanges?,
    context: ModelContext
  ) throws {
    var state = snapshot
    state.messages = []
    state.deletionCandidatesByFolderId = [:]
    state.reconciliationMessageIdsByFolderId = [:]
    let encodedState = try JSONEncoder().encode(state)
    if let record = try stateRecord(productAccountId, connectionId, context: context) {
      record.encodedState = encodedState
    } else {
      context.insert(
        DurableEWSMetadataStateRecord(
          connectionIdRawValue: connectionId.rawValue,
          encodedState: encodedState,
          productAccountId: productAccountId,
          storageKey: Self.storageKey(productAccountId, connectionId)
        )
      )
    }
    if let messageChanges {
      try apply(
        messageChanges,
        productAccountId: productAccountId,
        connectionId: connectionId,
        context: context
      )
      try apply(
        messageChanges.reconciliationChanges,
        productAccountId: productAccountId,
        connectionId: connectionId,
        context: context
      )
    } else {
      try replaceMessages(
        with: snapshot.messages,
        productAccountId: productAccountId,
        connectionId: connectionId,
        context: context
      )
      try replaceReconciliationMetadata(
        with: snapshot,
        productAccountId: productAccountId,
        connectionId: connectionId,
        context: context
      )
    }
  }

  private func apply(
    _ changes: EWSMetadataMessageChanges,
    productAccountId: String,
    connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws {
    let upsertsById = Dictionary(
      changes.upserting.map { ($0.stableProviderId, $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    let affectedIds = changes.deletingStableProviderIds.union(upsertsById.keys)
    var recordsById: [String: DurableEWSMessageMetadataRecord] = [:]
    for stableProviderId in affectedIds {
      let key = Self.messageStorageKey(productAccountId, connectionId, stableProviderId)
      recordsById[stableProviderId] = try messageRecord(storageKey: key, context: context)
    }
    for stableProviderId in changes.deletingStableProviderIds
    where upsertsById[stableProviderId] == nil {
      if let record = recordsById[stableProviderId] { context.delete(record) }
    }
    for message in upsertsById.values {
      try persistMessage(
        message,
        productAccountId: productAccountId,
        connectionId: connectionId,
        existing: recordsById[message.stableProviderId],
        context: context
      )
    }
  }

  private func replaceMessages(
    with messages: [EWSProviderMessage],
    productAccountId: String,
    connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws {
    let desiredIds = Set(messages.map(\.stableProviderId))
    let existingRecords = try messageRecords(productAccountId, connectionId, context: context)
    let recordsById = Dictionary(
      existingRecords.map { ($0.stableProviderId, $0) },
      uniquingKeysWith: { kept, _ in kept }
    )
    for record in existingRecords where !desiredIds.contains(record.stableProviderId) {
      context.delete(record)
    }
    for message in messages {
      try persistMessage(
        message,
        productAccountId: productAccountId,
        connectionId: connectionId,
        existing: recordsById[message.stableProviderId],
        context: context
      )
    }
  }

  private func apply(
    _ changes: EWSMetadataReconciliationChanges,
    productAccountId: String,
    connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws {
    for folderId in changes.clearingObservedFolderIds {
      try deleteReconciliationRecords(
        productAccountId,
        connectionId,
        folderId: folderId,
        kind: .observed,
        context: context
      )
    }
    for folderId in changes.clearingCandidateFolderIds
      .union(changes.replacingCandidatesByFolderId.keys)
    {
      try deleteReconciliationRecords(
        productAccountId,
        connectionId,
        folderId: folderId,
        kind: .candidate,
        context: context
      )
    }
    for (folderId, stableProviderIds) in changes.replacingCandidatesByFolderId {
      try insertReconciliationRecords(
        stableProviderIds,
        productAccountId: productAccountId,
        connectionId: connectionId,
        folderId: folderId,
        kind: .candidate,
        skipExistingLookup: true,
        context: context
      )
    }
    for (folderId, stableProviderIds) in changes.addingObservedIdsByFolderId {
      try insertReconciliationRecords(
        stableProviderIds,
        productAccountId: productAccountId,
        connectionId: connectionId,
        folderId: folderId,
        kind: .observed,
        skipExistingLookup: changes.clearingObservedFolderIds.contains(folderId),
        context: context
      )
    }
  }

  private func replaceReconciliationMetadata(
    with snapshot: EWSMetadataSnapshot,
    productAccountId: String,
    connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws {
    for record in try reconciliationRecords(productAccountId, connectionId, context: context) {
      context.delete(record)
    }
    for (folderId, stableProviderIds) in snapshot.reconciliationMessageIdsByFolderId {
      try insertReconciliationRecords(
        stableProviderIds,
        productAccountId: productAccountId,
        connectionId: connectionId,
        folderId: folderId,
        kind: .observed,
        skipExistingLookup: true,
        context: context
      )
    }
    for (folderId, stableProviderIds) in snapshot.deletionCandidatesByFolderId ?? [:] {
      try insertReconciliationRecords(
        stableProviderIds,
        productAccountId: productAccountId,
        connectionId: connectionId,
        folderId: folderId,
        kind: .candidate,
        skipExistingLookup: true,
        context: context
      )
    }
  }

  private func deleteReconciliationRecords(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId,
    folderId: String,
    kind: ReconciliationKind,
    context: ModelContext
  ) throws {
    for record in try reconciliationRecords(
      productAccountId,
      connectionId,
      folderId: folderId,
      kind: kind,
      context: context
    ) {
      context.delete(record)
    }
  }

  private func insertReconciliationRecords(
    _ stableProviderIds: Set<String>,
    productAccountId: String,
    connectionId: MailboxConnectionId,
    folderId: String,
    kind: ReconciliationKind,
    skipExistingLookup: Bool = false,
    context: ModelContext
  ) throws {
    for stableProviderId in stableProviderIds {
      let storageKey = Self.reconciliationStorageKey(
        productAccountId,
        connectionId,
        folderId,
        kind,
        stableProviderId
      )
      if !skipExistingLookup,
        try reconciliationRecord(storageKey: storageKey, context: context) != nil
      {
        continue
      }
      context.insert(
        DurableEWSReconciliationMetadataRecord(
          connectionIdRawValue: connectionId.rawValue,
          folderId: folderId,
          kindRawValue: kind.rawValue,
          productAccountId: productAccountId,
          stableProviderId: stableProviderId,
          storageKey: storageKey
        )
      )
    }
  }

  private func persistMessage(
    _ message: EWSProviderMessage,
    productAccountId: String,
    connectionId: MailboxConnectionId,
    existing: DurableEWSMessageMetadataRecord?,
    context: ModelContext
  ) throws {
    let key = Self.messageStorageKey(
      productAccountId,
      connectionId,
      message.stableProviderId
    )
    let encodedMessage = try JSONEncoder().encode(message)
    if let existing {
      existing.encodedMessage = encodedMessage
    } else {
      context.insert(
        DurableEWSMessageMetadataRecord(
          connectionIdRawValue: connectionId.rawValue,
          encodedMessage: encodedMessage,
          productAccountId: productAccountId,
          stableProviderId: message.stableProviderId,
          storageKey: key
        )
      )
    }
  }

  private static func storageKey(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId
  ) -> String {
    compoundStorageKey([productAccountId, connectionId.rawValue])
  }

  private static func messageStorageKey(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId,
    _ stableProviderId: String
  ) -> String {
    compoundStorageKey([productAccountId, connectionId.rawValue, stableProviderId])
  }

  private static func reconciliationStorageKey(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId,
    _ folderId: String,
    _ kind: ReconciliationKind,
    _ stableProviderId: String
  ) -> String {
    compoundStorageKey([
      productAccountId,
      connectionId.rawValue,
      folderId,
      kind.rawValue,
      stableProviderId,
    ])
  }

  private static func compoundStorageKey(_ components: [String]) -> String {
    components.map { "\($0.utf8.count):\($0)" }.joined()
  }
}

#if DEBUG || TESTING
  final class InMemoryEWSMetadataStore: EWSMetadataPersisting {
    enum ConsistencyError: Error {
      case incrementalSnapshotMismatch
    }

    private let lock = NSLock()
    private var snapshots: [String: EWSMetadataSnapshot] = [:]
    private var storedMessageWriteCounts: [Int] = []
    private var storedReconciliationWriteCounts: [Int] = []

    var messageWriteCounts: [Int] {
      lock.withLock { storedMessageWriteCounts }
    }

    var reconciliationWriteCounts: [Int] {
      lock.withLock { storedReconciliationWriteCounts }
    }

    func clear(productAccountId: String) throws {
      let prefix = "\(productAccountId)\0"
      lock.withLock {
        snapshots = snapshots.filter { !$0.key.hasPrefix(prefix) }
      }
    }

    func clear(
      productAccountId: String,
      connectionId: MailboxConnectionId
    ) throws {
      lock.withLock {
        snapshots[key(productAccountId, connectionId)] = nil
      }
    }

    func load(
      productAccountId: String,
      connectionId: MailboxConnectionId
    ) throws -> EWSMetadataSnapshot? {
      lock.withLock {
        snapshots[key(productAccountId, connectionId)]
      }
    }

    func save(
      _ snapshot: EWSMetadataSnapshot,
      productAccountId: String,
      connectionId: MailboxConnectionId,
      messageChanges: EWSMetadataMessageChanges?
    ) throws {
      try lock.withLock {
        let snapshotKey = key(productAccountId, connectionId)
        let previous = snapshots[snapshotKey]
        let storedSnapshot: EWSMetadataSnapshot
        if let messageChanges, let previous {
          storedSnapshot = applying(messageChanges, to: previous, stateFrom: snapshot)
          guard storedSnapshot == snapshot else {
            throw ConsistencyError.incrementalSnapshotMismatch
          }
        } else {
          storedSnapshot = snapshot
        }
        snapshots[snapshotKey] = storedSnapshot
        storedMessageWriteCounts.append(
          messageChanges.map {
            $0.upserting.count + $0.deletingStableProviderIds.count
          } ?? snapshot.messages.count
        )
        storedReconciliationWriteCounts.append(
          messageChanges.map {
            reconciliationWriteCount(
              previous: previous,
              changes: $0.reconciliationChanges
            )
          } ?? reconciliationRecordCount(in: snapshot)
        )
      }
    }

    private func applying(
      _ changes: EWSMetadataMessageChanges,
      to previous: EWSMetadataSnapshot,
      stateFrom snapshot: EWSMetadataSnapshot
    ) -> EWSMetadataSnapshot {
      var result = snapshot
      result.messages = previous.messages.filter {
        !changes.deletingStableProviderIds.contains($0.stableProviderId)
      }
      for message in changes.upserting {
        if let index = result.messages.firstIndex(where: {
          $0.stableProviderId == message.stableProviderId
        }) {
          result.messages[index] = message
        } else {
          result.messages.append(message)
        }
      }
      var observed = previous.reconciliationMessageIdsByFolderId
      for folderId in changes.reconciliationChanges.clearingObservedFolderIds {
        observed[folderId] = nil
      }
      for (folderId, ids) in changes.reconciliationChanges.addingObservedIdsByFolderId {
        observed[folderId, default: []].formUnion(ids)
      }
      result.reconciliationMessageIdsByFolderId = observed
      var candidates = previous.deletionCandidatesByFolderId ?? [:]
      for folderId in changes.reconciliationChanges.clearingCandidateFolderIds {
        candidates[folderId] = nil
      }
      for (folderId, ids) in changes.reconciliationChanges.replacingCandidatesByFolderId {
        candidates[folderId] = ids
      }
      result.deletionCandidatesByFolderId = candidates
      return result
    }

    private func reconciliationWriteCount(
      previous: EWSMetadataSnapshot?,
      changes: EWSMetadataReconciliationChanges
    ) -> Int {
      guard let previous else { return 0 }
      let observedDeletes = changes.clearingObservedFolderIds.reduce(into: 0) {
        $0 += previous.reconciliationMessageIdsByFolderId[$1]?.count ?? 0
      }
      let candidateClearIds = changes.clearingCandidateFolderIds.union(
        changes.replacingCandidatesByFolderId.keys
      )
      let candidateDeletes = candidateClearIds.reduce(into: 0) {
        $0 += previous.deletionCandidatesByFolderId?[$1]?.count ?? 0
      }
      let inserts =
        changes.addingObservedIdsByFolderId.values.reduce(0) { $0 + $1.count }
        + changes.replacingCandidatesByFolderId.values.reduce(0) { $0 + $1.count }
      return observedDeletes + candidateDeletes + inserts
    }

    private func reconciliationRecordCount(in snapshot: EWSMetadataSnapshot) -> Int {
      snapshot.reconciliationMessageIdsByFolderId.values.reduce(0) { $0 + $1.count }
        + (snapshot.deletionCandidatesByFolderId?.values.reduce(0) { $0 + $1.count } ?? 0)
    }

    private func key(
      _ productAccountId: String,
      _ connectionId: MailboxConnectionId
    ) -> String {
      "\(productAccountId)\0\(connectionId.rawValue)"
    }
  }
#endif

struct EWSMessageBodyService {
  private let cache: GmailMessageBodyCaching
  private let client: EWSClient
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting

  init(
    cache: GmailMessageBodyCaching,
    client: EWSClient,
    keyMaterialStore: ProductSyncKeyMaterialPersisting
  ) {
    self.cache = cache
    self.client = client
    self.keyMaterialStore = keyMaterialStore
  }

  func clear(session: ProductAccountSessionSnapshot) throws {
    try cache.clearMessageBodies(productAccountId: session.productAccountId)
  }

  func clear(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    try cache.clearMessageBodies(
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
  }

  func load(
    message: MailboxMessageMetadata,
    providerMessage: EWSProviderMessage,
    authorization: DeviceLocalEWSAuthorization,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    if let cached = try loadCached(
      message: message,
      providerMessage: providerMessage,
      session: session
    ) {
      try? cache.recordMessageBodyAccess(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId,
        accessedAt: Date()
      )
      return cached
    }
    let text = try await client.loadMessageBody(
      itemId: providerMessage.itemId,
      authorization: authorization
    )
    if let material = try? keyMaterialStore.load(productAccountId: session.productAccountId) {
      try? cache.saveMessageBody(
        material.encryptPayload(
          Data(text.utf8),
          associatedData: associatedData(message, providerMessage: providerMessage)
        ),
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
    }
    return MailboxMessageBody(text: text)
  }

  func prefetch(
    messages: [(MailboxMessageMetadata, EWSProviderMessage)],
    connection: MailboxConnection,
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
    authorization: DeviceLocalEWSAuthorization,
    session: ProductAccountSessionSnapshot,
    recoverProviderMessage: (EWSProviderMessage) async throws -> EWSProviderMessage?
  ) async throws {
    let protectedIds = Set(messages.map { $0.0.stableProviderMessageId })
    try cache.reconcileSelection(
      productAccountId: session.productAccountId,
      connectionId: connection.id,
      protectedMessageIds: protectedIds,
      pinnedMessageIds: Set(pinnedMessageIds.map(\.rawValue))
    )
    guard let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw ProductSyncKeyMaterialStoreError.recoveryRequired
    }
    for (message, providerMessage) in messages
    where
      try loadCached(
        message: message,
        providerMessage: providerMessage,
        session: session
      ) == nil
    {
      try Task.checkCancellation()
      guard
        let (text, currentProviderMessage) = try await loadBody(
          providerMessage: providerMessage,
          authorization: authorization,
          recoverProviderMessage: recoverProviderMessage
        )
      else { continue }
      _ = try cache.saveMessageBody(
        GmailMessageBodyCacheWrite(
          cachedAt: Date(
            timeIntervalSince1970: TimeInterval(message.providerInternalDateMilliseconds) / 1_000
          ),
          isPinned: pinnedMessageIds.contains(message.id),
          isProtected: true,
          payload: material.encryptPayload(
            Data(text.utf8),
            associatedData: associatedData(message, providerMessage: currentProviderMessage)
          ),
          retention: .prefetched
        ),
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
    }
  }

  private func loadBody(
    providerMessage: EWSProviderMessage,
    authorization: DeviceLocalEWSAuthorization,
    recoverProviderMessage: (EWSProviderMessage) async throws -> EWSProviderMessage?
  ) async throws -> (String, EWSProviderMessage)? {
    do {
      return (
        try await client.loadMessageBody(
          itemId: providerMessage.itemId,
          authorization: authorization
        ),
        providerMessage
      )
    } catch let error as EWSServiceError where error.isItemNotFound {
      guard let recovered = try await recoverProviderMessage(providerMessage) else { return nil }
      return (
        try await client.loadMessageBody(
          itemId: recovered.itemId,
          authorization: authorization
        ),
        recovered
      )
    }
  }

  func remove(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws {
    try cache.removeMessageBody(
      productAccountId: session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId
    )
  }

  private func loadCached(
    message: MailboxMessageMetadata,
    providerMessage: EWSProviderMessage,
    session: ProductAccountSessionSnapshot
  ) throws -> MailboxMessageBody? {
    guard
      let payload = try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      ),
      let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else { return nil }
    do {
      let data = try material.decryptPayload(
        payload,
        associatedData: associatedData(message, providerMessage: providerMessage)
      )
      guard let text = String(data: data, encoding: .utf8) else { return nil }
      return MailboxMessageBody(text: text)
    } catch {
      try? cache.removeMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
      return nil
    }
  }

  private func associatedData(
    _ message: MailboxMessageMetadata,
    providerMessage: EWSProviderMessage
  ) -> Data {
    let draftVersion = providerMessage.isDraft ? ":\(providerMessage.changeKey)" : ""
    return Data(
      "exchange-web-services-body-cache:\(message.stableProviderMessageId)\(draftVersion)".utf8
    )
  }
}

private typealias EWSBodyCandidate = (MailboxMessageMetadata, EWSProviderMessage)

// swiftlint:disable:next type_body_length
struct EWSMailboxConnectionAdapter: MailboxConnectionAdapter {
  static let initialPageSize = 50
  static let completedReconciliationInterval: TimeInterval = 24 * 60 * 60

  private let attachmentStore: DownloadedAttachmentStore
  private let authorizationStore: EWSAuthorizationPersisting
  private let bodyService: EWSMessageBodyService
  private let client: EWSClient
  private let definitionSyncService: MailboxConnectionDefinitionSyncing
  private let localStateCleaner: EWSLocalStateClearing
  private let metadataStore: EWSMetadataPersisting
  private let now: () -> Date
  private let oauthRefreshCoordinator: EWSOAuthRefreshCoordinator
  private let outboxService: OutboxDeliveryService
  private let pendingActionService: PendingProviderActionService
  private let syncGate: MailboxConnectionSyncGate

  init(
    attachmentStore: DownloadedAttachmentStore = DownloadedAttachmentStore(),
    authorizationStore: EWSAuthorizationPersisting = KeychainEWSAuthorizationStore(),
    cache: GmailMessageBodyCaching = FileGmailMessageBodyCache(),
    client: EWSClient = SystemEWSClient(),
    definitionSyncService: MailboxConnectionDefinitionSyncing =
      MailboxConnectionSyncService(),
    metadataStore: EWSMetadataPersisting = SwiftDataEWSMetadataStore(),
    now: @escaping @Sendable () -> Date = { Date() },
    oauthService: EWSOAuthAuthorizing? = nil,
    outboxService: OutboxDeliveryService = .shared,
    pendingActionService: PendingProviderActionService = .shared,
    syncGate: MailboxConnectionSyncGate = .shared,
    keyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore()
  ) {
    self.attachmentStore = attachmentStore
    self.authorizationStore = authorizationStore
    bodyService = EWSMessageBodyService(
      cache: cache,
      client: client,
      keyMaterialStore: keyMaterialStore
    )
    self.client = client
    self.definitionSyncService = definitionSyncService
    localStateCleaner = EWSLocalStateCleaner(
      authorizationStore: authorizationStore,
      cache: cache,
      client: client,
      keyMaterialStore: keyMaterialStore,
      metadataStore: metadataStore,
      outboxService: outboxService,
      pendingActionService: pendingActionService
    )
    self.metadataStore = metadataStore
    self.now = now
    oauthRefreshCoordinator = EWSOAuthRefreshCoordinator(
      authorizationStore: authorizationStore,
      now: now,
      oauthService: oauthService ?? EWSOAuthService()
    )
    self.outboxService = outboxService
    self.pendingActionService = pendingActionService
    self.syncGate = syncGate
  }

  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws {
    let connectionIds = try authorizationStore.connectionIds(
      productAccountId: session.productAccountId
    ).sorted {
      $0.rawValue < $1.rawValue
    }
    try await syncGate.withLocks(connectionIds) {
      try authorizationStore.clearAll(productAccountId: session.productAccountId)
      try metadataStore.clear(productAccountId: session.productAccountId)
      try await pendingActionService.clear(session: session)
      try bodyService.clear(session: session)
    }
  }

  func rebuildLocalIndexes(session: ProductAccountSessionSnapshot) async throws {
    try await syncGate.withAllConnectionsLocked {
      try metadataStore.clear(productAccountId: session.productAccountId)
    }
  }

  func clearLocalMailboxData(session: ProductAccountSessionSnapshot) async throws {
    try await syncGate.withAllConnectionsLocked {
      var firstError: Error?
      do {
        try metadataStore.clear(productAccountId: session.productAccountId)
      } catch {
        firstError = error
      }
      do {
        try bodyService.clear(session: session)
      } catch {
        firstError = firstError ?? error
      }
      if let firstError { throw firstError }
    }
  }

  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try validate(connection, session: session, requiresAuthorization: false)
    try await syncGate.withLock(connection.id) {
      try await clearLocalConnectionWithoutLock(connection, session: session)
    }
  }

  private func clearLocalConnectionWithoutLock(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await clearLocalConnectionWithoutLock(connection.id, session: session)
  }

  private func clearLocalConnectionWithoutLock(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws {
    var firstError: Error?
    do {
      try await localStateCleaner.clear(connectionId: connectionId, session: session)
    } catch {
      firstError = error
    }
    do {
      try attachmentStore.clear(connectionId: connectionId)
    } catch {
      firstError = firstError ?? error
    }
    if let firstError { throw firstError }
  }

  @MainActor
  func connect(
    expectedConnectionId _: MailboxConnectionId?,
    removalObservation _: MailboxConnectionRemovalObservation?,
    session _: ProductAccountSessionSnapshot,
    isSessionCurrent _: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection? {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    var snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    for connectionId in snapshot.connectionIdsRequiringLocalCleanup
    where connectionId.providerId == .exchangeWebServices {
      snapshot = try await refreshAndClearLocalStateIfNeeded(
        connectionId,
        session: session
      )
    }
    var connections: [MailboxConnection] = []
    for definition in snapshot.connections {
      guard
        definition.provider == MailProviderId.exchangeWebServices.rawValue,
        let ewsDefinition = definition.ewsDefinition
      else { continue }
      let authorization = try? authorizationStore.load(
        productAccountId: session.productAccountId,
        connectionId: definition.id
      )
      let authorized =
        authorization?
        .definition.matchesAuthorizationScope(ewsDefinition) == true
        && authorization?.authorizationGeneration == definition.authorizationGeneration
        && (ewsDefinition.authorizationMethod != .oauth || authorization?.oauthTokens != nil)
      let metadataSnapshot = try await loadMetadataSnapshot(
        connectionId: definition.id,
        session: session
      )
      let hasOnlineArchive =
        metadataSnapshot?.folders.contains { $0.role == .archive }
        ?? authorization?.hasOnlineArchive
        ?? false
      connections.append(
        MailboxConnection(
          authorizationGeneration: definition.authorizationGeneration,
          authorizationState: authorized ? .authorized : .required,
          capabilities: authorized
            ? .exchangeWebServices(hasOnlineArchive: hasOnlineArchive)
            : .none,
          connectedAt: definition.connectedAt,
          displayName: definition.displayName,
          id: definition.id,
          lastVerifiedAt: authorized ? definition.connectedAt : 0,
          productAccountId: ProductAccountId(session.productAccountId),
          trustedDeviceId: session.trustedDeviceId,
          updatedAt: snapshot.updatedAt ?? definition.connectedAt
        )
      )
    }
    return connections
  }

  private func loadMetadataSnapshot(
    connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> EWSMetadataSnapshot? {
    try await syncGate.withLock(connectionId) {
      try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connectionId
      )
    }
  }

  private func refreshAndClearLocalStateIfNeeded(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    try await syncGate.withLock(connectionId) {
      let currentSnapshot = try await definitionSyncService.loadSnapshotForProviderAccess(
        session: session
      )
      let authorizationGeneration =
        try? authorizationStore.load(
          productAccountId: session.productAccountId,
          connectionId: connectionId
        )?.authorizationGeneration
      guard
        try definitionSyncService.requiresLocalCleanup(
          in: currentSnapshot,
          connectionId: connectionId,
          localAuthorizationGeneration: authorizationGeneration,
          session: session
        )
      else {
        return currentSnapshot
      }
      try await clearLocalConnectionWithoutLock(connectionId, session: session)
      try definitionSyncService.recordLocalCleanup(
        in: currentSnapshot,
        connectionId: connectionId,
        session: session
      )
      return currentSnapshot
    }
  }

  func loadDefaultSendingConnectionId(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionId? {
    try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
      .defaultSendingConnectionId
  }

  func removeMailboxConnectionEverywhere(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await clearLocalConnection(connection, session: session)
    _ = try await definitionSyncService.removeConnection(connection.id, session: session)
  }

  func setDefaultSendingConnection(
    _ connection: MailboxConnection?,
    session: ProductAccountSessionSnapshot
  ) async throws {
    if let connection {
      try validate(connection, session: session, requiresAuthorization: false)
    }
    _ = try await definitionSyncService.setDefaultSendingConnection(
      connection?.id,
      session: session
    )
  }

  func categorizeHistorical(
    scope _: HistoricalCategorizationScope,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await continueHistoricalBackfill(connection: connection, session: session)
  }

  func loadInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await loadResult(.role(.inbox), connection: connection, session: session)
  }

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await loadResult(collection, connection: connection, session: session)
  }

  func loadProviderMailboxes(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [ProviderMailbox] {
    let folders = try await syncGate.withLock(connection.id) {
      _ = try await authorizationForProviderAccess(
        connection,
        session: session,
        isWithinSyncGate: true
      )
      return try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )?.folders ?? []
    }
    let foldersById = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
    return folders.compactMap {
      guard
        $0.role == nil,
        $0.isOutbox != true,
        $0.isSearchFolder != true,
        $0.isMailFolder
      else { return nil }
      return ProviderMailbox(
        id: EWSProviderMessage.customFolderStateId($0.id),
        isMoveDestination: $0.isArchiveHierarchy != true,
        providerStateIds: EWSProviderMessage.inheritedRoleStateIds(
          folderId: $0.id,
          foldersById: foldersById
        ),
        title: $0.displayName
      )
    }
  }

  func continueHistoricalBackfill(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await syncGate.withLock(connection.id) {
      try await continueHistoricalBackfillWithoutLock(connection: connection, session: session)
    }
  }

  // swiftlint:disable:next function_body_length
  private func continueHistoricalBackfillWithoutLock(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let authorization = try await authorizationForProviderAccess(
      connection,
      session: session,
      isWithinSyncGate: true
    )
    guard
      var snapshot = try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    else {
      return try await syncInbox(
        connection: connection,
        session: session,
        shouldPersist: { true }
      )
    }
    while let folder = snapshot.folders.first(where: {
      snapshot.nextOffsetsByFolderId[$0.id] != nil
    }) {
      var offset = snapshot.nextOffsetsByFolderId[folder.id] ?? 0
      while true {
        try Task.checkCancellation()
        let page = try await client.loadMessagePage(
          folder: folder,
          offset: offset,
          pageSize: Self.initialPageSize,
          authorization: authorization
        )
        let upserted = upsert(page.messages, into: &snapshot.messages)
        snapshot.reconciliationMessageIdsByFolderId[folder.id, default: []]
          .formUnion(upserted.observedIds)
        var deletedMessageIds: Set<String> = []
        var reconciliationChanges = EWSMetadataReconciliationChanges(
          addingObservedIdsByFolderId: [folder.id: upserted.observedIds]
        )
        if let nextOffset = page.nextOffset {
          offset = nextOffset
          snapshot.nextOffsetsByFolderId[folder.id] = nextOffset
        } else {
          snapshot.nextOffsetsByFolderId[folder.id] = nil
          var pendingVerification = snapshot.pendingVerificationFolderIds ?? []
          if pendingVerification.remove(folder.id) != nil {
            deletedMessageIds = finishReconciliation(for: folder.id, snapshot: &snapshot)
            reconciliationChanges = EWSMetadataReconciliationChanges(
              clearingCandidateFolderIds: [folder.id],
              clearingObservedFolderIds: [folder.id]
            )
          } else {
            // Offset paging is mutable while messages move or disappear. Keep
            // deletion candidates from this pass, then require one bounded
            // verification scan before removing anything.
            let storedIds = Set(
              snapshot.messages.lazy
                .filter { $0.parentFolderId == folder.id }
                .map(\.stableProviderId)
            )
            var candidates = snapshot.deletionCandidatesByFolderId ?? [:]
            candidates[folder.id] = storedIds.subtracting(
              snapshot.reconciliationMessageIdsByFolderId[folder.id] ?? []
            )
            snapshot.deletionCandidatesByFolderId = candidates
            pendingVerification.insert(folder.id)
            snapshot.reconciliationMessageIdsByFolderId[folder.id] = nil
            reconciliationChanges = EWSMetadataReconciliationChanges(
              clearingObservedFolderIds: [folder.id],
              replacingCandidatesByFolderId: [folder.id: candidates[folder.id] ?? []]
            )
          }
          snapshot.pendingVerificationFolderIds = pendingVerification
        }
        try metadataStore.save(
          snapshot,
          productAccountId: session.productAccountId,
          connectionId: connection.id,
          messageChanges: EWSMetadataMessageChanges(
            deletingStableProviderIds: deletedMessageIds,
            reconciliationChanges: reconciliationChanges,
            upserting: upserted.messages
          )
        )
        if page.nextOffset == nil { break }
      }
    }
    return try await projectedResult(
      snapshot,
      .role(.inbox),
      connection: connection,
      session: session
    )
  }

  func syncInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await syncGate.withLock(connection.id) {
      try await syncInbox(
        connection: connection,
        session: session,
        shouldPersist: { true }
      )
    }
  }

  // swiftlint:disable:next function_body_length
  private func syncInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    shouldPersist: () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    let authorization = try await authorizationForProviderAccess(
      connection,
      session: session,
      isWithinSyncGate: true
    )
    if try metadataStore.load(
      productAccountId: session.productAccountId,
      connectionId: connection.id
    ) != nil {
      let snapshot = try await refreshRecentSnapshot(
        connection,
        authorization: authorization,
        session: session,
        shouldPersist: shouldPersist
      )
      let rawResult = try result(snapshot, .allObserved, connection: connection)
      try await pendingActionService.reconcileProviderSync(
        messages: rawResult.messages,
        connection: connection,
        session: session,
        isConfirmed: { action, targetFolderId, messageIds in
          actionIsConfirmed(
            action,
            targetFolderId: targetFolderId,
            messageIds: messageIds,
            snapshot: snapshot,
            connection: connection
          )
        }
      )
      return try await projectedResult(
        snapshot,
        .role(.inbox),
        connection: connection,
        session: session
      )
    }
    let folders = try await client.loadFolders(authorization: authorization)
      .filter { $0.isOutbox != true && $0.isSearchFolder != true && $0.isMailFolder }
    var snapshot = EWSMetadataSnapshot(
      folders: folders,
      messages: [],
      nextOffsetsByFolderId: [:],
      hasInitialMailboxAvailability: false
    )
    for folder in folders {
      try Task.checkCancellation()
      guard shouldPersist() else { throw CancellationError() }
      let page = try await client.loadMessagePage(
        folder: folder,
        offset: 0,
        pageSize: Self.initialPageSize,
        authorization: authorization
      )
      let observedIds = upsert(page.messages, into: &snapshot.messages).observedIds
      snapshot.reconciliationMessageIdsByFolderId[folder.id] =
        observedIds
      if let nextOffset = page.nextOffset {
        snapshot.nextOffsetsByFolderId[folder.id] = nextOffset
      } else {
        finishReconciliation(for: folder.id, snapshot: &snapshot)
      }
    }
    snapshot.hasInitialMailboxAvailability = true
    guard shouldPersist() else { throw CancellationError() }
    try metadataStore.save(
      snapshot,
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
    return try await projectedResult(
      snapshot,
      .role(.inbox),
      connection: connection,
      session: session
    )
  }

  func syncRecentInbox(
    connection: MailboxConnection,
    includingHistoryCandidates _: Bool,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId _: String?,
    throughHistoryId _: String?,
    shouldPersist: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    try await syncGate.withLock(connection.id) {
      guard shouldPersist() else { throw CancellationError() }
      let authorization = try await authorizationForProviderAccess(
        connection,
        session: session,
        isWithinSyncGate: true
      )
      guard
        try metadataStore.load(
          productAccountId: session.productAccountId,
          connectionId: connection.id
        ) != nil
      else {
        return try await syncInbox(
          connection: connection,
          session: session,
          shouldPersist: shouldPersist
        )
      }
      let snapshot = try await refreshRecentSnapshot(
        connection,
        authorization: authorization,
        session: session,
        shouldPersist: shouldPersist
      )
      let rawResult = try result(snapshot, .allObserved, connection: connection)
      try await pendingActionService.reconcileProviderSync(
        messages: rawResult.messages,
        connection: connection,
        session: session,
        isConfirmed: { action, targetFolderId, messageIds in
          actionIsConfirmed(
            action,
            targetFolderId: targetFolderId,
            messageIds: messageIds,
            snapshot: snapshot,
            connection: connection
          )
        }
      )
      return try await projectedResult(
        snapshot,
        .role(.inbox),
        connection: connection,
        session: session
      )
    }
  }

  func overrideCategory(
    _ categoryId: String,
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    let connection = try await requiredConnection(message.connectionId, session: session)
    return try await syncGate.withLock(connection.id) {
      guard
        var snapshot = try metadataStore.load(
          productAccountId: session.productAccountId,
          connectionId: connection.id
        ),
        let index = snapshot.messages.firstIndex(where: {
          $0.stableProviderId == message.providerMessageId
        })
      else { throw MailboxConnectionAdapterError.connectionRemoved }
      snapshot.messages[index].categoryId = categoryId
      try metadataStore.save(
        snapshot,
        productAccountId: session.productAccountId,
        connectionId: connection.id,
        messageChanges: EWSMetadataMessageChanges(
          upserting: [snapshot.messages[index]]
        )
      )
      return snapshot.messages[index].mailboxMetadata(
        connection: connection,
        foldersById: Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
      )
    }
  }

  func setCategories(
    _ categoryIds: [String],
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    guard categoryIds.count == 1, let categoryId = categoryIds.first else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    return try await overrideCategory(categoryId, for: message, session: session)
  }

  func searchProvider(
    query: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata] {
    let result = try await loadResult(.allObserved, connection: connection, session: session)
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    return result.messages.filter {
      [$0.subject, $0.snippet, $0.from ?? ""].contains {
        $0.localizedCaseInsensitiveContains(query)
      }
    }
  }

  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws {
    try bodyService.clear(session: session)
  }

  func clearCachedMessageBodies(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    try validate(connection, session: session, requiresAuthorization: false)
    try bodyService.clear(connection: connection, session: session)
  }

  func loadMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    let connection = try await requiredConnection(message.connectionId, session: session)
    return try await syncGate.withLock(connection.id) {
      let authorization = try await authorizationForProviderAccess(
        connection,
        session: session,
        isWithinSyncGate: true
      )
      let providerMessage = try storedMessage(message, session: session)
      do {
        return try await bodyService.load(
          message: message,
          providerMessage: providerMessage,
          authorization: authorization,
          session: session
        )
      } catch let error as EWSServiceError where error.isItemNotFound {
        let recovered = try await recoverMessageIdentities(
          [providerMessage],
          connection: connection,
          authorization: authorization,
          session: session
        )
        return try await bodyService.load(
          message: message,
          providerMessage: recovered[0],
          authorization: authorization,
          session: session
        )
      }
    }
  }

  // swiftlint:disable:next function_body_length
  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedThreadIds: Set<StableThreadIdentity>,
    referenceDate: Date,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await syncGate.withLock(connection.id) {
      let authorization = try await authorizationForProviderAccess(
        connection,
        session: session,
        isWithinSyncGate: true
      )
      let snapshot = try requiredSnapshot(connection, session: session)
      let folders = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
      let lowerBound =
        Int64(referenceDate.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970)
        * 1_000
      let upperBound = Int64(referenceDate.timeIntervalSince1970 * 1_000)
      let storedMessages = snapshot.messages
      var pinnedMessageIds: Set<StableProviderMessageIdentity> = []
      let candidates = storedMessages.compactMap { providerMessage -> EWSBodyCandidate? in
        let message = providerMessage.mailboxMetadata(connection: connection, foldersById: folders)
        let states = Set(message.providerStateIds ?? [])
        guard states.isDisjoint(with: ["DRAFT", "SPAM", "TRASH"]) else { return nil }
        let isPinned = pinnedThreadIds.contains(message.threadIdentity)
        if isPinned { pinnedMessageIds.insert(message.id) }
        let isRecent =
          (lowerBound...upperBound).contains(message.providerInternalDateMilliseconds)
          && !states.isDisjoint(with: ["INBOX", "SENT"])
        return isPinned || isRecent ? (message, providerMessage) : nil
      }.sorted {
        $0.0.providerInternalDateMilliseconds > $1.0.providerInternalDateMilliseconds
      }
      let recentIds = Set(
        candidates.filter { !pinnedMessageIds.contains($0.0.id) }.prefix(500).map { $0.0.id }
      )
      let selected = candidates.filter {
        pinnedMessageIds.contains($0.0.id) || recentIds.contains($0.0.id)
      }
      var recoveryFolders: [EWSFolder]?
      try await bodyService.prefetch(
        messages: selected,
        connection: connection,
        pinnedMessageIds: pinnedMessageIds,
        authorization: authorization,
        session: session,
        recoverProviderMessage: { providerMessage in
          if recoveryFolders == nil {
            recoveryFolders = try await client.loadFolders(
              authorization: authorization,
              knownFolders: snapshot.folders
            ).filter { $0.isOutbox != true && $0.isSearchFolder != true && $0.isMailFolder }
          }
          let recovered = try await recoverMessageIdentities(
            [providerMessage],
            connection: connection,
            authorization: authorization,
            session: session,
            loadedFolders: recoveryFolders
          )
          let currentSnapshot = try requiredSnapshot(connection, session: session)
          let foldersById = Dictionary(
            uniqueKeysWithValues: currentSnapshot.folders.map { ($0.id, $0) }
          )
          let states = Set(
            recovered[0].mailboxMetadata(connection: connection, foldersById: foldersById)
              .providerStateIds ?? []
          )
          return states.isDisjoint(with: ["DRAFT", "SPAM", "TRASH"]) ? recovered[0] : nil
        }
      )
    }
  }

  func removeCachedMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws {
    guard message.connectionId.providerId == .exchangeWebServices else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    try bodyService.remove(message: message, session: session)
  }

  func registerOrRenewPush(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func perform(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await perform(
      action,
      targetProviderMailboxId: nil,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    targetProviderStateIds: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let selection = try await performTracked(
      action,
      sourceProviderMailboxId: nil,
      targetProviderMailboxId: targetProviderMailboxId,
      targetProviderStateIds: targetProviderStateIds,
      messages: messages,
      connection: connection,
      session: session
    )
    if let selection {
      await pendingActionService.releaseSelection(selection)
    }
  }

  // swiftlint:disable:next function_parameter_count
  func performTracked(
    _ action: ProviderMailAction,
    sourceProviderMailboxId _: String?,
    targetProviderMailboxId: String?,
    targetProviderStateIds: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxProviderActionSelection? {
    try await syncGate.withLock(connection.id) {
      _ = try await authorizationForProviderAccess(
        connection,
        session: session,
        isWithinSyncGate: true
      )
      if action == .move, targetProviderMailboxId == nil {
        throw MailboxConnectionAdapterError.providerMailboxTargetRequired
      }
      if [.move, .restore, .spam].contains(action),
        messages.contains(where: {
          $0.providerStateIds?.contains(EWSProviderMessage.archiveHierarchyStateId) == true
        })
      {
        throw MailboxConnectionAdapterError.unsupportedCapability
      }
      return try await pendingActionService.enqueue(
        action,
        targetProviderMailboxId: targetProviderMailboxId,
        targetProviderStateIds: targetProviderStateIds,
        messages: messages,
        connection: connection,
        session: session,
        coalescesMessages: true
      )
    }
  }

  func releasePendingActionSelection(
    _ selection: MailboxProviderActionSelection,
    connection _: MailboxConnection
  ) async {
    await pendingActionService.releaseSelection(selection)
  }

  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await perform(
      action,
      targetProviderMailboxId: targetProviderMailboxId,
      targetProviderStateIds: [],
      messages: messages,
      connection: connection,
      session: session
    )
  }

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resumePendingActions(
      connections: connections,
      session: session,
      revalidateProviderAccess: { true }
    )
  }

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    let results = await withTaskGroup(of: (Int, String?).self) { group in
      for (index, connection) in connections.enumerated() {
        group.addTask {
          (
            index,
            await resumePendingActions(
              connection: connection,
              session: session,
              revalidateProviderAccess: revalidateProviderAccess
            )
          )
        }
      }
      var values: [(Int, String?)] = []
      for await value in group { values.append(value) }
      return values.sorted { $0.0 < $1.0 }
    }
    let errors = results.compactMap(\.1)
    return errors.isEmpty ? nil : errors.joined(separator: "\n")
  }

  func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resumePendingActions(
      connection: connection,
      session: session,
      revalidateProviderAccess: { true }
    )
  }

  private func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    do {
      try await pendingActionService.resume(
        connection: connection,
        session: session,
        revalidateProviderAccess: revalidateProviderAccess,
        provider: pendingActionPerformer(connection: connection, session: session)
      )
      return try await pendingActionService.failureDescription(
        connection: connection,
        session: session
      )
    } catch is CancellationError {
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await retryBlockedPendingAction(
      connection: connection,
      session: session,
      revalidateProviderAccess: { true }
    )
  }

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    await resolveBlockedAction(
      connection: connection,
      session: session,
      discard: false,
      revalidateProviderAccess: revalidateProviderAccess
    )
  }

  func discardBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resolveBlockedAction(connection: connection, session: session, discard: true)
  }

  func blockedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    var ids: [MailboxConnectionId] = []
    for connection in connections
    where
      (try? await pendingActionService.hasBlockedAction(
        connection: connection,
        session: session
      )) == true
    {
      ids.append(connection.id)
    }
    return ids
  }

  func failedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    var ids: [MailboxConnectionId] = []
    for connection in connections
    where
      (try? await pendingActionService.hasFailedAction(
        connection: connection,
        session: session
      )) == true
    {
      ids.append(connection.id)
    }
    return ids
  }

  func pendingActionFailureDetails(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxProviderActionFailureDetail]? {
    try? await pendingActionService.failureDetails(
      action,
      messageIds: Set(messages.map(\.providerMessageId)),
      connection: connection,
      session: session
    )
  }

  func pendingActionFailureLookup(
    _ action: ProviderMailAction,
    selection: MailboxProviderActionSelection?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> MailboxProviderActionFailureLookup? {
    try? await pendingActionService.failureLookup(
      action,
      selectedActionIds: selection?.pendingActionIds,
      messageIds: Set(messages.map(\.providerMessageId)),
      connection: connection,
      session: session
    )
  }

  func waitForPendingActionRetries(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    for connection in connections {
      await pendingActionService.waitForScheduledRetries(
        connection: connection,
        session: session
      )
    }
    return await resumePendingActions(connections: connections, session: session)
  }

  func waitForPendingActionRetries(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await pendingActionService.waitForScheduledRetries(
      connection: connection,
      session: session
    )
    return await resumePendingActions(connection: connection, session: session)
  }

  func acknowledgePendingActionFailures(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async {
    try? await pendingActionService.acknowledgeFailures(
      connection: connection,
      session: session
    )
  }

  func send(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await syncGate.withLock(connection.id) {
      let authorization = try await authorizationForProviderAccess(
        connection,
        session: session,
        isWithinSyncGate: true
      )
      try await client.send(
        message,
        authorization: authorization
      )
    }
  }

  func deliveryStatus(
    idempotencyKey: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxDeliveryStatus {
    try await syncGate.withLock(connection.id) {
      let authorization = try await authorizationForProviderAccess(
        connection,
        session: session,
        isWithinSyncGate: true
      )
      return try await client.deliveryStatus(
        rfcMessageId: OutgoingMessage.rfcMessageId(for: idempotencyKey),
        authorization: authorization
      )
    }
  }

  // swiftlint:disable:next function_body_length cyclomatic_complexity
  private func pendingActionPerformer(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) -> PendingProviderActionPerformer {
    { action, _, targetFolderId, messageIds in
      try await syncGate.withLock(connection.id) {
        let authorization = try await authorizationForProviderAccess(
          connection,
          session: session,
          isWithinSyncGate: true
        )
        let snapshotBeforeRefresh = try requiredSnapshot(connection, session: session)
        let refreshedSnapshot: EWSMetadataSnapshot
        do {
          refreshedSnapshot = try await refreshRecentSnapshot(
            connection,
            authorization: authorization,
            session: session
          )
        } catch EWSServiceError.invalidResponse {
          throw URLError(.badServerResponse)
        }
        if actionIsConfirmed(
          action,
          targetFolderId: targetFolderId,
          messageIds: messageIds,
          snapshot: refreshedSnapshot,
          connection: connection
        ) {
          return
        }
        let snapshot = try requiredSnapshot(connection, session: session)
        let messages = messageIds.compactMap { messageId in
          snapshot.messages.first(where: { $0.stableProviderId == messageId })
            ?? snapshotBeforeRefresh.messages.first(where: { $0.stableProviderId == messageId })
        }
        guard messages.count == messageIds.count else {
          throw MailboxConnectionAdapterError.connectionRemoved
        }
        let currentMessages = try await currentMessagesForAction(
          messages,
          connection: connection,
          authorization: authorization,
          session: session
        )
        let currentSnapshot = try requiredSnapshot(connection, session: session)
        if actionIsConfirmed(
          action,
          targetFolderId: targetFolderId,
          messageIds: messageIds,
          snapshot: currentSnapshot,
          connection: connection
        ) {
          return
        }
        if [.move, .restore, .spam].contains(action),
          currentMessages.contains(where: { message in
            currentSnapshot.folders.first(where: { $0.id == message.parentFolderId })?
              .isArchiveHierarchy == true
          })
        {
          throw MailboxConnectionAdapterError.unsupportedCapability
        }
        let movedItems: [EWSMovedItemIdentity]
        let providerTargetFolderId =
          targetFolderId.flatMap {
            EWSProviderMessage.folderId(fromProviderStateId: $0)
          }
          ?? (action == .delete
            && currentMessages.allSatisfy { message in
              currentSnapshot.folders.first(where: { $0.id == message.parentFolderId })?
                .isArchiveHierarchy == true
            }
            ? currentSnapshot.folders.first(where: {
              $0.isArchiveHierarchy == true && $0.isTrashHierarchy == true
            })?.id
            : nil)
        do {
          movedItems = try await client.perform(
            action,
            targetFolderId: providerTargetFolderId,
            messages: currentMessages,
            authorization: authorization
          )
        } catch let error as URLError {
          if error.code == .cancelled || Task.isCancelled {
            throw CancellationError()
          }
          if Self.isDefinitePreDeliveryNetworkFailure(error) {
            throw error
          }
          throw EWSAmbiguousProviderActionError()
        } catch EWSServiceError.invalidResponse {
          throw EWSAmbiguousProviderActionError()
        } catch EWSServiceError.response(let code, let message) {
          guard Self.isAmbiguousMutationResponse(code) else {
            throw EWSServiceError.response(code: code, message: message)
          }
          throw EWSAmbiguousProviderActionError()
        }
        try applyConfirmedAction(
          action,
          targetFolderId: targetFolderId
            ?? providerTargetFolderId.map(EWSProviderMessage.customFolderStateId),
          messageIds: messageIds,
          movedItems: movedItems,
          connection: connection,
          session: session
        )
        _ = try? await refreshRecentSnapshot(
          connection,
          authorization: authorization,
          session: session
        )
      }
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  private func actionIsConfirmed(
    _ action: ProviderMailAction,
    targetFolderId: String?,
    messageIds: [String],
    snapshot: EWSMetadataSnapshot,
    connection: MailboxConnection
  ) -> Bool {
    let foldersById = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
    let messages = snapshot.messages
      .filter { messageIds.contains($0.stableProviderId) }
      .map { $0.mailboxMetadata(connection: connection, foldersById: foldersById) }
    guard messages.count == messageIds.count else { return false }
    return messages.allSatisfy { message in
      let states = Set(message.providerStateIds ?? [])
      switch action {
      case .archive: return states.contains("ARCHIVE")
      case .delete: return states.contains("TRASH")
      case .markRead: return !states.contains("UNREAD")
      case .markUnread: return states.contains("UNREAD")
      case .move:
        guard let targetFolderId else { return false }
        let providerFolderId = EWSProviderMessage.folderId(
          fromProviderStateId: targetFolderId
        )
        let destinationState =
          providerFolderId.flatMap { foldersById[$0]?.role }
          .map { EWSProviderMessage.providerStateId($0.mailboxRole) }
          ?? targetFolderId
        return states.contains(destinationState)
          && (destinationState == "INBOX" || !states.contains("INBOX"))
      case .notSpam: return !states.contains("SPAM") && states.contains("INBOX")
      case .restore: return !states.contains("TRASH") && states.contains("INBOX")
      case .spam: return !states.contains("INBOX") && states.contains("SPAM")
      case .star: return states.contains("STARRED")
      case .unstar: return !states.contains("STARRED")
      }
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_parameter_count
  private func applyConfirmedAction(
    _ action: ProviderMailAction,
    targetFolderId: String?,
    messageIds: [String],
    movedItems: [EWSMovedItemIdentity],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    var snapshot = try requiredSnapshot(connection, session: session)
    var changedMessages: [EWSProviderMessage] = []
    let destinationRole: EWSFolderRole? =
      switch action {
      case .archive: .archive
      case .delete: .trash
      case .notSpam, .restore: .inbox
      case .spam: .spam
      default: nil
      }
    let destinationId =
      targetFolderId.flatMap { EWSProviderMessage.folderId(fromProviderStateId: $0) }
      ?? destinationRole.flatMap { role in
        snapshot.folders.first(where: { $0.role == role })?.id
      }
    for index in snapshot.messages.indices
    where messageIds.contains(snapshot.messages[index].stableProviderId) {
      let moved = movedItems.first(where: {
        $0.stableProviderId == snapshot.messages[index].stableProviderId
      })
      if let moved {
        snapshot.messages[index].itemId = moved.itemId
        snapshot.messages[index].changeKey = moved.changeKey
      }
      switch action {
      case .markRead:
        snapshot.messages[index].isRead = true
      case .markUnread:
        snapshot.messages[index].isRead = false
      case .star:
        snapshot.messages[index].isFlagged = true
      case .unstar:
        snapshot.messages[index].isFlagged = false
      case .archive, .delete, .move, .notSpam, .restore, .spam:
        if let destinationId = moved?.destinationFolderId ?? destinationId {
          snapshot.messages[index].parentFolderId = destinationId
        }
      }
      changedMessages.append(snapshot.messages[index])
    }
    try metadataStore.save(
      snapshot,
      productAccountId: session.productAccountId,
      connectionId: connection.id,
      messageChanges: EWSMetadataMessageChanges(upserting: changedMessages)
    )
  }

  // swiftlint:disable:next function_body_length
  private func refreshRecentSnapshot(
    _ connection: MailboxConnection,
    authorization: DeviceLocalEWSAuthorization,
    session: ProductAccountSessionSnapshot,
    shouldPersist: () -> Bool = { true }
  ) async throws -> EWSMetadataSnapshot {
    var snapshot = try requiredSnapshot(connection, session: session)
    let originalMessageIds = Set(snapshot.messages.map(\.stableProviderId))
    let storedReconciliationFolderIds = Set(
      snapshot.reconciliationMessageIdsByFolderId.keys
    ).union(snapshot.deletionCandidatesByFolderId?.keys ?? [:].keys)
    var addingObservedIdsByFolderId: [String: Set<String>] = [:]
    var clearingCandidateFolderIds: Set<String> = []
    var clearingObservedFolderIds: Set<String> = []
    var upsertedMessages: [EWSProviderMessage] = []
    let loadedFolders = try await client.loadFolders(
      authorization: authorization,
      knownFolders: snapshot.folders
    ).filter { $0.isOutbox != true && $0.isSearchFolder != true && $0.isMailFolder }
    let loadedFolderIds = Set(loadedFolders.map(\.id))
    let previouslyMissingFolderIds = snapshot.missingFolderIds ?? []
    let missingFolders = snapshot.folders.filter {
      !loadedFolderIds.contains($0.id)
    }
    let confirmedMissingFolderIds = Set(missingFolders.map(\.id))
      .intersection(previouslyMissingFolderIds)
    let retainedMissingFolders = missingFolders.filter {
      !confirmedMissingFolderIds.contains($0.id)
    }
    let folders = loadedFolders + retainedMissingFolders
    snapshot.missingFolderIds = Set(retainedMissingFolders.map(\.id))
    var recentPagesByFolderId: [String: EWSMessagePage] = [:]
    var recentObservedIdsByFolderId: [String: Set<String>] = [:]
    for folder in loadedFolders {
      try Task.checkCancellation()
      guard shouldPersist() else { throw CancellationError() }
      let page = try await client.loadMessagePage(
        folder: folder,
        offset: 0,
        pageSize: Self.initialPageSize,
        authorization: authorization
      )
      recentPagesByFolderId[folder.id] = page
      let upserted = upsert(page.messages, into: &snapshot.messages)
      recentObservedIdsByFolderId[folder.id] = upserted.observedIds
      upsertedMessages.append(contentsOf: upserted.messages)
      let scanIsInProgress =
        snapshot.nextOffsetsByFolderId[folder.id] != nil
        || snapshot.reconciliationMessageIdsByFolderId[folder.id] != nil
      let lastCompletedAt =
        snapshot.reconciliationAtByFolderId?[folder.id]
      let reconciliationIsDue =
        lastCompletedAt.map {
          now().timeIntervalSince1970 * 1_000 - Double($0)
            >= Self.completedReconciliationInterval * 1_000
        } ?? true
      if !scanIsInProgress
        && (!snapshot.completedFolderIds.contains(folder.id) || reconciliationIsDue)
      {
        snapshot.reconciliationMessageIdsByFolderId[folder.id] = upserted.observedIds
        if let nextOffset = page.nextOffset {
          snapshot.nextOffsetsByFolderId[folder.id] = nextOffset
          addingObservedIdsByFolderId[folder.id] = upserted.observedIds
        } else {
          finishReconciliation(for: folder.id, snapshot: &snapshot)
          clearingCandidateFolderIds.insert(folder.id)
          clearingObservedFolderIds.insert(folder.id)
        }
      }
    }
    let activeFolderIds = Set(folders.map(\.id))
    snapshot.folders = folders
    snapshot.messages.removeAll { !activeFolderIds.contains($0.parentFolderId) }
    for folder in folders {
      guard
        let page = recentPagesByFolderId[folder.id],
        let observedIds = recentObservedIdsByFolderId[folder.id]
      else { continue }
      let observedCutoff = page.messages.map(\.receivedAtMilliseconds).min()
      snapshot.messages.removeAll { message in
        guard message.parentFolderId == folder.id, !observedIds.contains(message.stableProviderId)
        else { return false }
        if page.nextOffset == nil { return true }
        return observedCutoff.map { message.receivedAtMilliseconds > $0 } ?? false
      }
    }
    snapshot.nextOffsetsByFolderId = snapshot.nextOffsetsByFolderId.filter {
      activeFolderIds.contains($0.key)
    }
    snapshot.reconciliationMessageIdsByFolderId =
      snapshot.reconciliationMessageIdsByFolderId.filter {
        activeFolderIds.contains($0.key)
      }
    snapshot.deletionCandidatesByFolderId =
      snapshot.deletionCandidatesByFolderId?.filter {
        activeFolderIds.contains($0.key)
      }
    snapshot.reconciliationAtByFolderId =
      snapshot.reconciliationAtByFolderId?.filter {
        activeFolderIds.contains($0.key)
      }
    snapshot.pendingVerificationFolderIds =
      snapshot.pendingVerificationFolderIds?.filter {
        activeFolderIds.contains($0)
      }
    let removedReconciliationFolderIds = storedReconciliationFolderIds.subtracting(
      activeFolderIds
    )
    clearingCandidateFolderIds.formUnion(removedReconciliationFolderIds)
    clearingObservedFolderIds.formUnion(removedReconciliationFolderIds)
    guard shouldPersist() else { throw CancellationError() }
    let messagesById = Dictionary(
      snapshot.messages.map { ($0.stableProviderId, $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    try metadataStore.save(
      snapshot,
      productAccountId: session.productAccountId,
      connectionId: connection.id,
      messageChanges: EWSMetadataMessageChanges(
        deletingStableProviderIds: originalMessageIds.subtracting(messagesById.keys),
        reconciliationChanges: EWSMetadataReconciliationChanges(
          addingObservedIdsByFolderId: addingObservedIdsByFolderId,
          clearingCandidateFolderIds: clearingCandidateFolderIds,
          clearingObservedFolderIds: clearingObservedFolderIds
        ),
        upserting: upsertedMessages.filter { messagesById[$0.stableProviderId] != nil }
      )
    )
    return snapshot
  }

  private static func isDefinitePreDeliveryNetworkFailure(_ error: URLError) -> Bool {
    switch error.code {
    case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
      .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
      return true
    default:
      return false
    }
  }

  private static func mappedIdentityRefreshError(_ error: EWSServiceError) -> Error {
    if case .invalidResponse = error {
      return URLError(.badServerResponse)
    }
    if error.isItemNotFound {
      return EWSAmbiguousProviderActionError()
    }
    return error
  }

  private func currentMessagesForAction(
    _ messages: [EWSProviderMessage],
    connection: MailboxConnection,
    authorization: DeviceLocalEWSAuthorization,
    session: ProductAccountSessionSnapshot
  ) async throws -> [EWSProviderMessage] {
    let refreshed: [EWSProviderMessage?]
    do {
      refreshed = try await client.refreshMessageIdentitiesAllowingMissing(
        messages,
        authorization: authorization
      )
    } catch let error as EWSServiceError {
      throw Self.mappedIdentityRefreshError(error)
    }
    guard refreshed.count == messages.count else {
      throw URLError(.badServerResponse)
    }
    let missingIndices = refreshed.indices.filter { refreshed[$0] == nil }
    guard !missingIndices.isEmpty else { return refreshed.compactMap { $0 } }
    let recovered: [EWSProviderMessage]
    do {
      recovered = try await recoverMessageIdentities(
        missingIndices.map { messages[$0] },
        connection: connection,
        authorization: authorization,
        session: session
      )
    } catch let error as EWSServiceError {
      throw Self.mappedIdentityRefreshError(error)
    }
    var current = refreshed
    for (index, message) in zip(missingIndices, recovered) { current[index] = message }
    return current.compactMap { $0 }
  }

  private func recoverMessageIdentities(
    _ messages: [EWSProviderMessage],
    connection: MailboxConnection,
    authorization: DeviceLocalEWSAuthorization,
    session: ProductAccountSessionSnapshot,
    loadedFolders providedFolders: [EWSFolder]? = nil
  ) async throws -> [EWSProviderMessage] {
    var snapshot = try requiredSnapshot(connection, session: session)
    let loadedFolders: [EWSFolder]
    if let providedFolders {
      loadedFolders = providedFolders
    } else {
      loadedFolders = try await client.loadFolders(
        authorization: authorization,
        knownFolders: snapshot.folders
      ).filter { $0.isOutbox != true && $0.isSearchFolder != true && $0.isMailFolder }
    }
    var identities: [EWSMovedItemIdentity] = []
    for message in messages {
      identities.append(
        try await client.recoverMessageIdentity(
          message,
          folders: loadedFolders,
          authorization: authorization
        )
      )
    }
    var recoveredMessages = messages
    for (index, identity) in identities.enumerated() {
      guard
        identity.stableProviderId == recoveredMessages[index].stableProviderId,
        let parentFolderId = identity.destinationFolderId
      else { throw EWSServiceError.invalidResponse }
      recoveredMessages[index].itemId = identity.itemId
      recoveredMessages[index].changeKey = identity.changeKey
      recoveredMessages[index].parentFolderId = parentFolderId
      if let snapshotIndex = snapshot.messages.firstIndex(where: {
        $0.stableProviderId == identity.stableProviderId
      }) {
        snapshot.messages[snapshotIndex] = recoveredMessages[index]
      } else {
        snapshot.messages.append(recoveredMessages[index])
      }
    }
    let loadedFolderIds = Set(loadedFolders.map(\.id))
    snapshot.folders =
      loadedFolders + snapshot.folders.filter { !loadedFolderIds.contains($0.id) }
    try metadataStore.save(
      snapshot,
      productAccountId: session.productAccountId,
      connectionId: connection.id,
      messageChanges: EWSMetadataMessageChanges(upserting: recoveredMessages)
    )
    return recoveredMessages
  }

  private static func isAmbiguousMutationResponse(_ code: String) -> Bool {
    if code == "ErrorTimeoutExpired" { return true }
    guard let status = code.split(separator: " ").last.flatMap({ Int($0) }) else {
      return false
    }
    return status == 408 || status == 409 || status == 425 || status >= 500
  }

  @discardableResult
  private func finishReconciliation(
    for folderId: String,
    snapshot: inout EWSMetadataSnapshot
  ) -> Set<String> {
    guard let observedIds = snapshot.reconciliationMessageIdsByFolderId[folderId] else {
      return []
    }
    var deletedMessageIds: Set<String> = []
    let candidates = snapshot.deletionCandidatesByFolderId?[folderId]
    snapshot.messages.removeAll {
      let shouldDelete =
        $0.parentFolderId == folderId
        && !observedIds.contains($0.stableProviderId)
        && (candidates?.contains($0.stableProviderId) ?? true)
      if shouldDelete { deletedMessageIds.insert($0.stableProviderId) }
      return shouldDelete
    }
    var completedFolderIds = snapshot.completedFolderIds
    completedFolderIds.insert(folderId)
    snapshot.completedHistoricalBackfillFolderIds = completedFolderIds
    var completedAt = snapshot.reconciliationAtByFolderId ?? [:]
    completedAt[folderId] = Int64(now().timeIntervalSince1970 * 1_000)
    snapshot.reconciliationAtByFolderId = completedAt
    snapshot.deletionCandidatesByFolderId?[folderId] = nil
    snapshot.reconciliationMessageIdsByFolderId[folderId] = nil
    snapshot.pendingVerificationFolderIds?.remove(folderId)
    return deletedMessageIds
  }

  private func resolveBlockedAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    discard: Bool,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool = { true }
  ) async -> String? {
    do {
      let performer = pendingActionPerformer(connection: connection, session: session)
      if discard {
        try await pendingActionService.discardBlockedAction(
          connection: connection,
          session: session,
          provider: performer
        )
      } else {
        try await pendingActionService.retryBlockedAction(
          connection: connection,
          session: session,
          revalidateProviderAccess: revalidateProviderAccess,
          provider: performer
        )
      }
      return try await pendingActionService.failureDescription(
        connection: connection,
        session: session
      )
    } catch {
      return error.localizedDescription
    }
  }

  // swiftlint:disable:next function_body_length
  private func authorizationForProviderAccess(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    isWithinSyncGate: Bool = false
  ) async throws -> DeviceLocalEWSAuthorization {
    try validate(connection, session: session, requiresAuthorization: true)
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    if snapshot.removedConnectionIds.contains(connection.id) {
      if isWithinSyncGate {
        try await clearLocalConnectionWithoutLock(connection, session: session)
      } else {
        try await clearLocalConnection(connection, session: session)
      }
      try definitionSyncService.recordLocalCleanup(
        in: snapshot,
        connectionId: connection.id,
        session: session
      )
      throw MailboxConnectionAdapterError.connectionRemoved
    }
    guard
      let authorization = try authorizationStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    else { throw MailboxConnectionAdapterError.authorizationRequired }
    if try definitionSyncService.requiresLocalCleanup(
      in: snapshot,
      connectionId: connection.id,
      localAuthorizationGeneration: authorization.authorizationGeneration,
      session: session
    ) {
      if isWithinSyncGate {
        try await clearLocalConnectionWithoutLock(connection, session: session)
      } else {
        try await clearLocalConnection(connection, session: session)
      }
      try definitionSyncService.recordLocalCleanup(
        in: snapshot,
        connectionId: connection.id,
        session: session
      )
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    guard
      let synchronizedDefinition = snapshot.connections.first(where: {
        $0.id == connection.id
      }),
      let definition = synchronizedDefinition.ewsDefinition
    else { throw MailboxConnectionAdapterError.connectionRemoved }
    guard
      connection.authorizationGeneration == synchronizedDefinition.authorizationGeneration,
      authorization.authorizationGeneration == synchronizedDefinition.authorizationGeneration,
      authorization.definition.matchesAuthorizationScope(definition)
    else {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    let scopedAuthorization = DeviceLocalEWSAuthorization(
      authorizationGeneration: authorization.authorizationGeneration,
      credential: authorization.credential,
      definition: definition,
      hasOnlineArchive: authorization.hasOnlineArchive,
      oauthTokens: authorization.oauthTokens
    )
    return try await oauthRefreshCoordinator.refreshIfNeeded(
      scopedAuthorization,
      productAccountId: session.productAccountId
    )
  }

  private func loadResult(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let snapshot = try await syncGate.withLock(connection.id) {
      _ = try await authorizationForProviderAccess(
        connection,
        session: session,
        isWithinSyncGate: true
      )
      return
        try metadataStore.load(
          productAccountId: session.productAccountId,
          connectionId: connection.id
        )
        ?? EWSMetadataSnapshot(
          folders: [],
          messages: [],
          nextOffsetsByFolderId: [:],
          hasInitialMailboxAvailability: false
        )
    }
    return try await projectedResult(
      snapshot,
      collection,
      connection: connection,
      session: session
    )
  }

  private func projectedResult(
    _ snapshot: EWSMetadataSnapshot,
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await pendingActionService.project(
      result(snapshot, .allObserved, connection: connection),
      collection: collection,
      connection: connection,
      session: session
    )
  }

  private func requiredSnapshot(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws -> EWSMetadataSnapshot {
    guard
      let snapshot = try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    else { throw MailboxConnectionAdapterError.connectionRemoved }
    return snapshot
  }

  private func storedMessage(
    _ message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws -> EWSProviderMessage {
    let snapshot = try requiredSnapshot(
      MailboxConnection(
        authorizationState: .authorized,
        capabilities: .exchangeWebServices,
        connectedAt: 0,
        displayName: "",
        id: message.connectionId,
        lastVerifiedAt: 0,
        productAccountId: ProductAccountId(session.productAccountId),
        trustedDeviceId: session.trustedDeviceId,
        updatedAt: 0
      ),
      session: session
    )
    guard
      let stored = snapshot.messages.first(where: {
        $0.stableProviderId == message.providerMessageId
      })
    else { throw MailboxConnectionAdapterError.connectionRemoved }
    return stored
  }

  private func result(
    _ snapshot: EWSMetadataSnapshot,
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection
  ) throws -> MailboxMetadataSyncResult {
    let foldersById = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
    let allMessages = snapshot.messages.map {
      $0.mailboxMetadata(connection: connection, foldersById: foldersById)
    }.sorted {
      if $0.providerInternalDateMilliseconds == $1.providerInternalDateMilliseconds {
        return $0.providerMessageId < $1.providerMessageId
      }
      return $0.providerInternalDateMilliseconds > $1.providerInternalDateMilliseconds
    }
    let messages = allMessages.filter {
      collection.contains(providerStateIds: $0.providerStateIds)
    }
    let visibleThreadIds = Set(messages.map(\.threadIdentity))
    let threads = MailboxThread.group(allMessages).filter { visibleThreadIds.contains($0.id) }
    return MailboxMetadataSyncResult(
      hasUnlistedNewMessages: false,
      messages: messages,
      newMessageIds: nil,
      providerCursorIsExpired: false,
      threads: threads,
      hasInitialMailboxAvailability: snapshot.hasInitialMailboxAvailability,
      historicalMetadataBackfillIsComplete: snapshot.historicalMetadataBackfillIsComplete
    )
  }

  @discardableResult
  private func upsert(
    _ messages: [EWSProviderMessage],
    into existing: inout [EWSProviderMessage]
  ) -> (observedIds: Set<String>, messages: [EWSProviderMessage]) {
    var observedIds: Set<String> = []
    var upsertedMessages: [EWSProviderMessage] = []
    var indexesByIdentity: [String: Int] = [:]
    for (index, message) in existing.enumerated() {
      indexesByIdentity[message.stableProviderId] = index
      indexesByIdentity[message.itemId] = index
    }
    for message in messages {
      if let index =
        indexesByIdentity[message.stableProviderId] ?? indexesByIdentity[message.itemId]
      {
        var updated = message
        updated.categoryId = updated.categoryId ?? existing[index].categoryId
        updated.stableProviderId = existing[index].stableProviderId
        existing[index] = updated
        indexesByIdentity[updated.stableProviderId] = index
        indexesByIdentity[updated.itemId] = index
        observedIds.insert(updated.stableProviderId)
        upsertedMessages.append(updated)
      } else {
        existing.append(message)
        let index = existing.index(before: existing.endIndex)
        indexesByIdentity[message.stableProviderId] = index
        indexesByIdentity[message.itemId] = index
        observedIds.insert(message.stableProviderId)
        upsertedMessages.append(message)
      }
    }
    return (observedIds, upsertedMessages)
  }

  private func requiredConnection(
    _ id: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnection {
    guard let connection = try await loadConnections(session: session).first(where: { $0.id == id })
    else { throw MailboxConnectionAdapterError.connectionRemoved }
    return connection
  }

  private func validate(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    requiresAuthorization: Bool
  ) throws {
    guard connection.productAccountId == ProductAccountId(session.productAccountId) else {
      throw MailboxConnectionAdapterError.productAccountMismatch
    }
    guard connection.providerId == .exchangeWebServices else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    if requiresAuthorization, connection.authorizationState != .authorized {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
  }
}
