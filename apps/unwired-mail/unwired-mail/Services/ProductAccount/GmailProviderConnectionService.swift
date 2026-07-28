import CryptoKit
import Foundation

// swiftlint:disable file_length

struct GmailProviderTokens: Codable, Equatable {
  let accessToken: String
  let idToken: String?
  let refreshToken: String

  init(accessToken: String, refreshToken: String, idToken: String? = nil) {
    self.accessToken = accessToken
    self.idToken = idToken
    self.refreshToken = refreshToken
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accessToken = try container.decode(String.self, forKey: .accessToken)
    idToken = nil
    refreshToken = try container.decode(String.self, forKey: .refreshToken)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(accessToken, forKey: .accessToken)
    try container.encode(refreshToken, forKey: .refreshToken)
  }

  private enum CodingKeys: String, CodingKey {
    case accessToken
    case refreshToken
  }
}

struct GmailProviderConnectionStatus: Codable, Equatable {
  let connectedAt: Int64
  let emailAddress: String
  let lastVerifiedAt: Int64
  let provider: String
  let providerAccountIdentifier: String
  let trustedDeviceId: String
  let updatedAt: Int64
}

struct GmailOperationalConnectionStatus: Codable, Equatable {
  let connectedAt: Int64
  let lastVerifiedAt: Int64
  let opaqueConnectionId: String
  let trustedDeviceId: String
  let updatedAt: Int64
}

struct VerifiedGmailAccount: Equatable {
  let emailAddress: String
  let providerAccountIdentifier: String
  let tokens: GmailProviderTokens
}

enum GmailProviderCredentialVerificationError: LocalizedError, Equatable {
  case invalidAccessToken
  case invalidRefreshToken
  case accountMismatch
  case missingVerificationResponse
  case missingOAuthClientId
  case missingGmailAuthorization
  case insufficientGmailScope

  var errorDescription: String? {
    switch self {
    case .invalidAccessToken:
      return "Gmail did not accept the access token."
    case .invalidRefreshToken:
      return "Gmail did not accept the refresh token."
    case .accountMismatch:
      return "The Gmail account did not match the verified token account."
    case .missingVerificationResponse:
      return "Gmail did not return account verification details."
    case .missingOAuthClientId:
      return "Gmail OAuth client id is not configured."
    case .missingGmailAuthorization:
      return "Gmail did not authorize mail access for this account."
    case .insufficientGmailScope:
      return "Gmail authorization does not allow reading message bodies."
    }
  }
}

protocol GmailProviderTokenPersisting {
  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws
  func clearAll(productAccountId: String) throws
  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailProviderTokens?
  func loadAll(productAccountId: String) throws -> [String: GmailProviderTokens]
  func loadLegacy(productAccountId: String) throws -> GmailProviderTokens?
  func clearLegacy(productAccountId: String) throws
  func save(
    _ tokens: GmailProviderTokens,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws
}

extension GmailProviderTokenPersisting {
  func loadAll(productAccountId _: String) throws -> [String: GmailProviderTokens] { [:] }
  func loadLegacy(productAccountId _: String) throws -> GmailProviderTokens? { nil }
  func clearLegacy(productAccountId _: String) throws {}
}

protocol GmailProviderConnectionTransport {
  func registerGmailConnection(
    gmailIdentityToken: String,
    identityToken: String,
    opaqueConnectionId: String,
    trustedDeviceId: String,
  ) async throws -> GmailOperationalConnectionStatus

  func removeGmailConnection(
    identityToken: String,
    opaqueConnectionId: String,
    trustedDeviceId: String
  ) async throws -> Bool

  func shouldStopGmailPushWatch(
    identityToken: String,
    opaqueConnectionId: String,
    trustedDeviceId: String
  ) async throws -> Bool
}

extension GmailProviderConnectionTransport {
  func removeGmailConnection(
    identityToken _: String,
    opaqueConnectionId _: String,
    trustedDeviceId _: String
  ) async throws -> Bool { false }
}

func opaqueGmailConnectionId(
  productAccountId: String,
  providerAccountIdentifier: String
) -> String {
  let input = Data(
    "dev.unwired.mail.gmail-operational-connection.v1"
      .appending("\0\(productAccountId)\0\(providerAccountIdentifier)")
      .utf8
  )
  return Data(SHA256.hash(data: input)).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

protocol GmailProviderConnecting {
  func clearLocalConnection(
    session: ProductAccountSessionSnapshot
  ) async throws

  func clearLocalConnection(
    _ connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws

  func completeConnection(
    verifiedAccount: VerifiedGmailAccount,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus

  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailProviderConnectionStatus]

  func loadStoredConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailProviderConnectionStatus]
}

protocol GmailProviderCredentialVerifying {
  func verify(
    accessToken: String,
    refreshToken: String
  ) async throws -> VerifiedGmailAccount
}

struct KeychainGmailProviderTokenStore: GmailProviderTokenPersisting {
  private let service = "private-email.gmail-provider-tokens"

  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailProviderTokens? {
    try tokens(
      account: accountName(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      ))
  }

  func loadAll(productAccountId: String) throws -> [String: GmailProviderTokens] {
    try Dictionary(
      uniqueKeysWithValues: providerAccountIdentifiers(productAccountId: productAccountId)
        .compactMap { providerAccountIdentifier in
          try load(
            productAccountId: productAccountId,
            providerAccountIdentifier: providerAccountIdentifier
          ).map { (providerAccountIdentifier, $0) }
        }
    )
  }

  func save(
    _ tokens: GmailProviderTokens,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    let data = try JSONEncoder().encode(tokens)
    guard let json = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }

    let previousIdentifiers = try providerAccountIdentifiers(productAccountId: productAccountId)
    var identifiers = previousIdentifiers
    identifiers.insert(providerAccountIdentifier)
    try saveProviderAccountIdentifiers(identifiers, productAccountId: productAccountId)
    do {
      try KeychainStore.writeString(
        json,
        service: service,
        account: accountName(
          productAccountId: productAccountId,
          providerAccountIdentifier: providerAccountIdentifier
        ),
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      )
    } catch {
      try? saveProviderAccountIdentifiers(
        previousIdentifiers,
        productAccountId: productAccountId
      )
      throw error
    }
  }

  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    try KeychainStore.delete(
      service: service,
      account: accountName(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      )
    )
    var identifiers = try providerAccountIdentifiers(productAccountId: productAccountId)
    identifiers.remove(providerAccountIdentifier)
    try saveProviderAccountIdentifiers(identifiers, productAccountId: productAccountId)
  }

  func clearAll(productAccountId: String) throws {
    for providerAccountIdentifier in try providerAccountIdentifiers(
      productAccountId: productAccountId
    ) {
      try KeychainStore.delete(
        service: service,
        account: accountName(
          productAccountId: productAccountId,
          providerAccountIdentifier: providerAccountIdentifier
        )
      )
    }
    try KeychainStore.delete(service: service, account: manifestName(productAccountId))
    try KeychainStore.delete(service: service, account: legacyAccountName(productAccountId))
  }

  func loadLegacy(productAccountId: String) throws -> GmailProviderTokens? {
    try tokens(account: legacyAccountName(productAccountId))
  }

  func clearLegacy(productAccountId: String) throws {
    try KeychainStore.delete(service: service, account: legacyAccountName(productAccountId))
  }

  private func accountName(
    productAccountId: String,
    providerAccountIdentifier: String
  ) -> String {
    "gmail-\(productAccountId)-\(providerAccountIdentifier)"
  }

  private func manifestName(_ productAccountId: String) -> String {
    "gmail-identities-\(productAccountId)"
  }

  private func legacyAccountName(_ productAccountId: String) -> String {
    "gmail-\(productAccountId)"
  }

  private func tokens(account: String) throws -> GmailProviderTokens? {
    guard
      let json = try KeychainStore.readString(service: service, account: account),
      let data = json.data(using: .utf8)
    else {
      return nil
    }
    return try JSONDecoder().decode(GmailProviderTokens.self, from: data)
  }

  private func providerAccountIdentifiers(productAccountId: String) throws -> Set<String> {
    guard
      let json = try KeychainStore.readString(
        service: service,
        account: manifestName(productAccountId)
      ),
      let data = json.data(using: .utf8)
    else {
      return []
    }
    return Set(try JSONDecoder().decode([String].self, from: data))
  }

  private func saveProviderAccountIdentifiers(
    _ identifiers: Set<String>,
    productAccountId: String
  ) throws {
    guard !identifiers.isEmpty else {
      try KeychainStore.delete(service: service, account: manifestName(productAccountId))
      return
    }
    let data = try JSONEncoder().encode(identifiers.sorted())
    guard let json = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(
      json,
      service: service,
      account: manifestName(productAccountId),
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }
}

private func clearGmailProviderTokens(
  _ tokenStore: GmailProviderTokenPersisting,
  productAccountId: String,
  providerAccountIdentifier: String,
  hasRemainingGmailConnections: Bool
) throws {
  if hasRemainingGmailConnections {
    try tokenStore.clear(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
  } else {
    try tokenStore.clearAll(productAccountId: productAccountId)
  }
}

// swiftlint:disable:next type_body_length
struct GmailProviderConnectionService: GmailProviderConnecting {
  private let backgroundContextCacheStore: BackgroundContextCachePersisting
  private let bodyReader: GmailMessageReading
  private let pushConnectionStore: GmailPushConnectionPersisting
  private let pushWatchStopper: GmailPushWatchStopping
  private let pushWatchStore: GmailPushWatchPersisting
  private let metadataStore: GmailMessageMetadataPersisting
  private let tokenStore: GmailProviderTokenPersisting
  private let transport: GmailProviderConnectionTransport
  private let credentialVerifier: GmailProviderCredentialVerifying

  init(
    backgroundContextCacheStore: BackgroundContextCachePersisting =
      KeychainBackgroundContextCacheStore(),
    bodyReader: GmailMessageReading = GmailMessageBodyService(),
    pushConnectionStore: GmailPushConnectionPersisting =
      KeychainGmailPushConnectionStore(),
    pushWatchStopper: GmailPushWatchStopping = GmailPushWatchService(),
    pushWatchStore: GmailPushWatchPersisting = UserDefaultsGmailPushWatchStore(),
    metadataStore: GmailMessageMetadataPersisting = SwiftDataGmailMessageMetadataStore(),
    tokenStore: GmailProviderTokenPersisting = KeychainGmailProviderTokenStore(),
    transport: GmailProviderConnectionTransport = ConvexClient(),
    credentialVerifier: GmailProviderCredentialVerifying =
      GoogleGmailProviderCredentialVerifier()
  ) {
    self.backgroundContextCacheStore = backgroundContextCacheStore
    self.bodyReader = bodyReader
    self.pushConnectionStore = pushConnectionStore
    self.pushWatchStopper = pushWatchStopper
    self.pushWatchStore = pushWatchStore
    self.metadataStore = metadataStore
    self.tokenStore = tokenStore
    self.transport = transport
    self.credentialVerifier = credentialVerifier
  }

  func completeConnection(
    verifiedAccount: VerifiedGmailAccount,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus {
    let providerAccountIdentifier = verifiedAccount.providerAccountIdentifier
    let previousTokens = try tokenStore.load(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    try tokenStore.save(
      GmailProviderTokens(
        accessToken: verifiedAccount.tokens.accessToken,
        refreshToken: verifiedAccount.tokens.refreshToken
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    return try await registerConnection(
      verifiedAccount: verifiedAccount,
      session: session,
      previousTokens: previousTokens
    )
  }

  func loadStoredConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailProviderConnectionStatus] {
    try pushConnectionStore.loadAll(productAccountId: session.productAccountId)
  }

  func clearLocalConnection(
    session: ProductAccountSessionSnapshot
  ) async throws {
    var cleanupError: Error?
    do {
      try backgroundContextCacheStore.clear(productAccountId: session.productAccountId)
    } catch {
      cleanupError = cleanupError ?? error
    }
    var connections: [GmailProviderConnectionStatus] = []
    do {
      connections = try pushConnectionStore.loadAll(productAccountId: session.productAccountId)
    } catch {
      cleanupError = cleanupError ?? error
    }
    for connection in connections {
      await stopPushWatchIfLastActiveRoute(connection: connection, session: session)
    }
    do {
      try bodyReader.clearCachedMessageBodies(session: session)
    } catch {
      cleanupError = cleanupError ?? error
    }
    do {
      try tokenStore.clearAll(productAccountId: session.productAccountId)
    } catch {
      cleanupError = cleanupError ?? error
    }
    do {
      try metadataStore.clearMessages(productAccountId: session.productAccountId)
    } catch {
      cleanupError = cleanupError ?? error
    }
    var didClearPushWatchStore = false
    do {
      try pushWatchStore.clearAll(productAccountId: session.productAccountId)
      didClearPushWatchStore = true
    } catch {
      cleanupError = cleanupError ?? error
    }
    if didClearPushWatchStore {
      do {
        try pushConnectionStore.clearAll(productAccountId: session.productAccountId)
      } catch {
        cleanupError = cleanupError ?? error
      }
    }
    if let cleanupError {
      throw cleanupError
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func clearLocalConnection(
    _ connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let shouldStopWatch = await shouldStopPushWatch(connection: connection, session: session)
    try backgroundContextCacheStore.clear(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    var cleanupError: Error?
    let hasRemainingGmailConnections: Bool
    do {
      hasRemainingGmailConnections = try await transport.removeGmailConnection(
        identityToken: session.identityToken,
        opaqueConnectionId: opaqueGmailConnectionId(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        ),
        trustedDeviceId: session.trustedDeviceId
      )
    } catch {
      cleanupError = error
      hasRemainingGmailConnections = true
    }
    if shouldStopWatch {
      try? await pushWatchStopper.stop(connection: connection, session: session)
    }
    do {
      try bodyReader.clearCachedMessageBodies(connection: connection, session: session)
    } catch {
      cleanupError = cleanupError ?? error
    }
    if !hasRemainingGmailConnections {
      do {
        try backgroundContextCacheStore.clear(productAccountId: session.productAccountId)
      } catch {
        cleanupError = cleanupError ?? error
      }
      do {
        try bodyReader.clearCachedMessageBodies(session: session)
      } catch {
        cleanupError = cleanupError ?? error
      }
      do {
        try metadataStore.clearMessages(productAccountId: session.productAccountId)
      } catch {
        cleanupError = cleanupError ?? error
      }
    }
    do {
      try clearGmailProviderTokens(
        tokenStore,
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier,
        hasRemainingGmailConnections: hasRemainingGmailConnections
      )
    } catch {
      cleanupError = cleanupError ?? error
    }
    do {
      try metadataStore.clearMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
    } catch {
      cleanupError = cleanupError ?? error
    }
    var didClearPushWatchStore = false
    do {
      try pushWatchStore.clear(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      didClearPushWatchStore = true
    } catch {
      cleanupError = cleanupError ?? error
    }
    if didClearPushWatchStore {
      do {
        try pushConnectionStore.clear(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        )
      } catch {
        cleanupError = cleanupError ?? error
      }
    }
    clearGmailPushNotificationState(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    if let cleanupError {
      throw cleanupError
    }
  }

  private func stopPushWatchIfLastActiveRoute(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async {
    guard await shouldStopPushWatch(connection: connection, session: session) else {
      return
    }

    try? await pushWatchStopper.stop(connection: connection, session: session)
  }

  private func registerConnection(
    verifiedAccount: VerifiedGmailAccount,
    session: ProductAccountSessionSnapshot,
    previousTokens: GmailProviderTokens?
  ) async throws -> GmailProviderConnectionStatus {
    do {
      guard let gmailIdentityToken = verifiedAccount.tokens.idToken else {
        throw GmailProviderCredentialVerificationError.missingVerificationResponse
      }
      let operationalStatus = try await transport.registerGmailConnection(
        gmailIdentityToken: gmailIdentityToken,
        identityToken: session.identityToken,
        opaqueConnectionId: opaqueGmailConnectionId(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: verifiedAccount.providerAccountIdentifier
        ),
        trustedDeviceId: session.trustedDeviceId
      )
      let status = GmailProviderConnectionStatus(
        connectedAt: operationalStatus.connectedAt,
        emailAddress: verifiedAccount.emailAddress,
        lastVerifiedAt: operationalStatus.lastVerifiedAt,
        provider: "gmail",
        providerAccountIdentifier: verifiedAccount.providerAccountIdentifier,
        trustedDeviceId: operationalStatus.trustedDeviceId,
        updatedAt: operationalStatus.updatedAt
      )
      try pushConnectionStore.save(status, productAccountId: session.productAccountId)
      return status
    } catch {
      if let previousTokens {
        try tokenStore.save(
          previousTokens,
          productAccountId: session.productAccountId,
          providerAccountIdentifier: verifiedAccount.providerAccountIdentifier
        )
      } else {
        try tokenStore.clear(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: verifiedAccount.providerAccountIdentifier
        )
      }
      throw error
    }
  }

  // swiftlint:disable:next function_body_length
  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailProviderConnectionStatus] {
    var statuses = try pushConnectionStore.loadAll(productAccountId: session.productAccountId)
    var tokensByIdentifier = try tokenStore.loadAll(productAccountId: session.productAccountId)
    for (storedIdentifier, tokens) in tokensByIdentifier.sorted(by: { $0.key < $1.key })
    where !statuses.contains(where: { $0.providerAccountIdentifier == storedIdentifier }) {
      do {
        let verifiedAccount = try await credentialVerifier.verify(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken
        )
        let status = try await completeConnection(
          verifiedAccount: verifiedAccount,
          session: session
        )
        statuses.removeAll {
          $0.providerAccountIdentifier == verifiedAccount.providerAccountIdentifier
        }
        statuses.append(status)
        tokensByIdentifier[verifiedAccount.providerAccountIdentifier] = verifiedAccount.tokens
        if storedIdentifier != verifiedAccount.providerAccountIdentifier {
          try tokenStore.clear(
            productAccountId: session.productAccountId,
            providerAccountIdentifier: storedIdentifier
          )
          tokensByIdentifier[storedIdentifier] = nil
        }
      } catch {
        continue
      }
    }
    if let legacyTokens = try tokenStore.loadLegacy(productAccountId: session.productAccountId),
      statuses.isEmpty
        || statuses.contains(where: {
          tokensByIdentifier[$0.providerAccountIdentifier] == nil
        })
    {
      do {
        let verifiedAccount = try await credentialVerifier.verify(
          accessToken: legacyTokens.accessToken,
          refreshToken: legacyTokens.refreshToken
        )
        var didMigrateLegacyTokens = false
        if statuses.contains(where: {
          $0.providerAccountIdentifier == verifiedAccount.providerAccountIdentifier
        }) {
          let migratedTokens = GmailProviderTokens(
            accessToken: verifiedAccount.tokens.accessToken,
            refreshToken: verifiedAccount.tokens.refreshToken
          )
          try tokenStore.save(
            migratedTokens,
            productAccountId: session.productAccountId,
            providerAccountIdentifier: verifiedAccount.providerAccountIdentifier
          )
          tokensByIdentifier[verifiedAccount.providerAccountIdentifier] = migratedTokens
          didMigrateLegacyTokens = true
        } else if statuses.isEmpty {
          let status = try await completeConnection(
            verifiedAccount: verifiedAccount,
            session: session
          )
          statuses = [status]
          tokensByIdentifier[status.providerAccountIdentifier] = verifiedAccount.tokens
          didMigrateLegacyTokens = true
        }
        if didMigrateLegacyTokens {
          try tokenStore.clearLegacy(productAccountId: session.productAccountId)
        }
      } catch {
        // A stale legacy credential must not hide connections with valid scoped tokens.
      }
    }
    return statuses.filter { status in
      guard status.trustedDeviceId == session.trustedDeviceId else { return false }
      return tokensByIdentifier[status.providerAccountIdentifier] != nil
    }
  }
}
extension GmailProviderConnectionService {
  fileprivate func shouldStopPushWatch(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async -> Bool {
    (try? await transport.shouldStopGmailPushWatch(
      identityToken: session.identityToken,
      opaqueConnectionId: opaqueGmailConnectionId(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      trustedDeviceId: session.trustedDeviceId
    )) == true
  }
}

extension ConvexClient: GmailProviderConnectionTransport {}

struct GoogleGmailProviderCredentialVerifier: GmailProviderCredentialVerifying {
  private let gmailProfileURL: URL
  private let oauthClientId: String?
  private let session: URLSession
  private let tokenInfoURL: URL
  private let tokenRefreshURL: URL
  private let userInfoURL: URL

  init(
    gmailProfileURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!,
    oauthClientId: String? =
      ProcessInfo.processInfo.environment["GMAIL_OAUTH_CLIENT_ID"]
      ?? DotEnvFile.value(for: "GMAIL_OAUTH_CLIENT_ID")
      ?? GmailOAuthClientIdConfiguration.bundledValue(),
    session: URLSession = .shared,
    tokenInfoURL: URL = URL(string: "https://oauth2.googleapis.com/tokeninfo")!,
    tokenRefreshURL: URL = URL(string: "https://oauth2.googleapis.com/token")!,
    userInfoURL: URL = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!
  ) {
    self.gmailProfileURL = gmailProfileURL
    self.oauthClientId = oauthClientId
    self.session = session
    self.tokenInfoURL = tokenInfoURL
    self.tokenRefreshURL = tokenRefreshURL
    self.userInfoURL = userInfoURL
  }

  func verify(
    accessToken: String,
    refreshToken: String
  ) async throws -> VerifiedGmailAccount {
    guard let oauthClientId, !oauthClientId.isEmpty else {
      throw GmailProviderCredentialVerificationError.missingOAuthClientId
    }

    let refreshedProfileAndTokenInfo = try await refreshProfileAndTokenInfo(
      refreshToken: refreshToken,
      oauthClientId: oauthClientId
    )
    guard refreshedProfileAndTokenInfo.tokenInfo.allowsReadingMessageBodies else {
      throw GmailProviderCredentialVerificationError.insufficientGmailScope
    }
    if let persistedIdentity = try? await verifyAccessToken(accessToken),
      persistedIdentity.profile.emailAddress.caseInsensitiveCompare(
        refreshedProfileAndTokenInfo.profile.emailAddress
      ) != .orderedSame
        || persistedIdentity.subject != refreshedProfileAndTokenInfo.subject
    {
      throw GmailProviderCredentialVerificationError.accountMismatch
    }

    return VerifiedGmailAccount(
      emailAddress: refreshedProfileAndTokenInfo.profile.emailAddress,
      providerAccountIdentifier: refreshedProfileAndTokenInfo.subject,
      tokens: GmailProviderTokens(
        accessToken: refreshedProfileAndTokenInfo.accessToken,
        refreshToken: refreshToken,
        idToken: refreshedProfileAndTokenInfo.idToken
      )
    )
  }

  private func verifyAccessToken(
    _ accessToken: String
  ) async throws -> PersistedGmailVerification {
    let profile = try await validateGmailAuthorization(accessToken: accessToken)
    var components = URLComponents(url: tokenInfoURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "access_token", value: accessToken)
    ]
    guard let url = components?.url else {
      throw GmailProviderCredentialVerificationError.invalidAccessToken
    }
    let (data, response) = try await session.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailProviderCredentialVerificationError.invalidAccessToken
    }
    let tokenInfo = try JSONDecoder().decode(GoogleTokenInfoResponse.self, from: data)
    guard tokenInfo.allowsReadingMessageBodies else {
      throw GmailProviderCredentialVerificationError.insufficientGmailScope
    }
    return PersistedGmailVerification(
      profile: profile,
      subject: try await loadGoogleAccountIdentifier(accessToken: accessToken)
    )
  }

  private func validateGmailAuthorization(
    accessToken: String
  ) async throws -> GoogleGmailProfileResponse {
    var request = URLRequest(url: gmailProfileURL)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailProviderCredentialVerificationError.missingGmailAuthorization
    }

    let profile = try JSONDecoder().decode(GoogleGmailProfileResponse.self, from: data)
    guard !profile.emailAddress.isEmpty else {
      throw GmailProviderCredentialVerificationError.missingVerificationResponse
    }
    return profile
  }

  private func refreshProfileAndTokenInfo(
    refreshToken: String,
    oauthClientId: String
  ) async throws -> RefreshedGmailVerification {
    var request = URLRequest(url: tokenRefreshURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formURLEncodedBody([
      "client_id": oauthClientId,
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
    ])

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailProviderCredentialVerificationError.invalidRefreshToken
    }

    let tokenResponse = try JSONDecoder().decode(GoogleRefreshTokenResponse.self, from: data)
    guard !tokenResponse.accessToken.isEmpty else {
      throw GmailProviderCredentialVerificationError.invalidRefreshToken
    }
    let profile = try await validateGmailAuthorization(accessToken: tokenResponse.accessToken)

    var components = URLComponents(url: tokenInfoURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "access_token", value: tokenResponse.accessToken)
    ]
    guard let url = components?.url else {
      throw GmailProviderCredentialVerificationError.invalidRefreshToken
    }

    let (tokenInfoData, tokenInfoResponse) = try await session.data(from: url)
    guard let httpResponse = tokenInfoResponse as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailProviderCredentialVerificationError.invalidRefreshToken
    }

    let tokenInfo = try JSONDecoder().decode(GoogleTokenInfoResponse.self, from: tokenInfoData)
    let subject = try await loadGoogleAccountIdentifier(accessToken: tokenResponse.accessToken)
    return RefreshedGmailVerification(
      accessToken: tokenResponse.accessToken,
      idToken: tokenResponse.idToken,
      profile: profile,
      subject: subject,
      tokenInfo: tokenInfo
    )
  }

  private func loadGoogleAccountIdentifier(accessToken: String) async throws -> String {
    var request = URLRequest(url: userInfoURL)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await session.data(for: request)
    guard
      let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      let userInfo = try? JSONDecoder().decode(GoogleOpenIDUserInfoResponse.self, from: data),
      !userInfo.sub.isEmpty
    else {
      throw GmailProviderCredentialVerificationError.missingVerificationResponse
    }
    return userInfo.sub
  }

  private func formURLEncodedBody(_ fields: [String: String]) -> Data {
    fields
      .map { key, value in
        "\(formURLEncode(key))=\(formURLEncode(value))"
      }
      .joined(separator: "&")
      .data(using: .utf8) ?? Data()
  }

  private func formURLEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}

enum GmailOAuthClientIdConfiguration {
  static let infoDictionaryKey = "GmailOAuthClientId"

  static func bundledValue(bundle: Bundle = .main) -> String? {
    guard
      let rawValue = bundle.object(forInfoDictionaryKey: infoDictionaryKey) as? String
    else {
      return nil
    }

    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.contains("$(") else {
      return nil
    }

    return value
  }
}

private struct GoogleTokenInfoResponse: Decodable {
  private static let bodyReadableScopes: Set = [
    "https://mail.google.com/",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/gmail.readonly",
  ]

  let scope: String?

  var allowsReadingMessageBodies: Bool {
    guard let scope else { return false }
    return !Self.bodyReadableScopes.isDisjoint(with: scope.split(separator: " ").map(String.init))
  }
}

private struct GoogleOpenIDUserInfoResponse: Decodable {
  let sub: String
}

private struct RefreshedGmailVerification {
  let accessToken: String
  let idToken: String?
  let profile: GoogleGmailProfileResponse
  let subject: String
  let tokenInfo: GoogleTokenInfoResponse
}

private struct PersistedGmailVerification {
  let profile: GoogleGmailProfileResponse
  let subject: String
}

private struct GoogleGmailProfileResponse: Decodable {
  let emailAddress: String
}

private struct GoogleRefreshTokenResponse: Decodable {
  let accessToken: String
  let idToken: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case idToken = "id_token"
  }
}

#if DEBUG || TESTING
  final class InMemoryGmailProviderTokenStore: GmailProviderTokenPersisting {
    private var legacyTokensByProductAccountId: [String: GmailProviderTokens] = [:]
    private var tokensByConnectionKey: [String: GmailProviderTokens] = [:]

    func load(
      productAccountId: String,
      providerAccountIdentifier: String
    ) throws -> GmailProviderTokens? {
      tokensByConnectionKey[key(productAccountId, providerAccountIdentifier)]
    }

    func loadAll(productAccountId: String) throws -> [String: GmailProviderTokens] {
      let prefix = "\(productAccountId):"
      return Dictionary(
        uniqueKeysWithValues: tokensByConnectionKey.compactMap { key, tokens in
          guard key.hasPrefix(prefix) else { return nil }
          return (String(key.dropFirst(prefix.count)), tokens)
        }
      )
    }

    func save(
      _ tokens: GmailProviderTokens,
      productAccountId: String,
      providerAccountIdentifier: String
    ) throws {
      tokensByConnectionKey[key(productAccountId, providerAccountIdentifier)] = tokens
    }

    func clear(
      productAccountId: String,
      providerAccountIdentifier: String
    ) throws {
      tokensByConnectionKey[key(productAccountId, providerAccountIdentifier)] = nil
    }

    func clearAll(productAccountId: String) throws {
      let prefix = "\(productAccountId):"
      tokensByConnectionKey = tokensByConnectionKey.filter { !$0.key.hasPrefix(prefix) }
      legacyTokensByProductAccountId[productAccountId] = nil
    }

    func loadLegacy(productAccountId: String) throws -> GmailProviderTokens? {
      legacyTokensByProductAccountId[productAccountId]
    }

    func clearLegacy(productAccountId: String) throws {
      legacyTokensByProductAccountId[productAccountId] = nil
    }

    func saveLegacy(_ tokens: GmailProviderTokens, productAccountId: String) {
      legacyTokensByProductAccountId[productAccountId] = tokens
    }

    private func key(_ productAccountId: String, _ providerAccountIdentifier: String) -> String {
      "\(productAccountId):\(providerAccountIdentifier)"
    }
  }
#endif
