import Foundation

struct GmailProviderTokens: Codable, Equatable {
  let accessToken: String
  let refreshToken: String
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
    }
  }
}

protocol GmailProviderTokenPersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> GmailProviderTokens?
  func save(_ tokens: GmailProviderTokens, productAccountId: String) throws
}

protocol GmailProviderConnectionTransport {
  func connectGmailProvider(
    identityToken: String,
    trustedDeviceId: String,
    emailAddress: String,
    providerAccountIdentifier: String
  ) async throws -> GmailProviderConnectionStatus

  func getGmailProviderConnection(
    identityToken: String
  ) async throws -> GmailProviderConnectionStatus?
}

protocol GmailProviderConnecting {
  func clearLocalConnection(
    session: ProductAccountSessionSnapshot
  ) throws

  func completeConnection(
    verifiedAccount: VerifiedGmailAccount,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus

  func loadConnection(
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus?
}

protocol GmailProviderCredentialVerifying {
  func verify(
    accessToken: String,
    refreshToken: String,
    expectedEmailAddress: String,
    expectedProviderAccountIdentifier: String
  ) async throws -> VerifiedGmailAccount
}

struct KeychainGmailProviderTokenStore: GmailProviderTokenPersisting {
  private let service = "private-email.gmail-provider-tokens"

  func load(productAccountId: String) throws -> GmailProviderTokens? {
    guard
      let json = try KeychainStore.readString(
        service: service,
        account: accountName(productAccountId: productAccountId)
      ),
      let data = json.data(using: .utf8)
    else {
      return nil
    }

    return try JSONDecoder().decode(GmailProviderTokens.self, from: data)
  }

  func save(_ tokens: GmailProviderTokens, productAccountId: String) throws {
    let data = try JSONEncoder().encode(tokens)
    guard let json = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }

    try KeychainStore.writeString(
      json,
      service: service,
      account: accountName(productAccountId: productAccountId),
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }

  func clear(productAccountId: String) throws {
    try KeychainStore.delete(
      service: service,
      account: accountName(productAccountId: productAccountId)
    )
  }

  private func accountName(productAccountId: String) -> String {
    "gmail-\(productAccountId)"
  }
}

struct GmailProviderConnectionService: GmailProviderConnecting {
  private let tokenStore: GmailProviderTokenPersisting
  private let transport: GmailProviderConnectionTransport

  init(
    tokenStore: GmailProviderTokenPersisting = KeychainGmailProviderTokenStore(),
    transport: GmailProviderConnectionTransport = ConvexClient()
  ) {
    self.tokenStore = tokenStore
    self.transport = transport
  }

  func completeConnection(
    verifiedAccount: VerifiedGmailAccount,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus {
    let previousTokens = try tokenStore.load(productAccountId: session.productAccountId)
    try tokenStore.save(
      verifiedAccount.tokens,
      productAccountId: session.productAccountId
    )

    do {
      return try await transport.connectGmailProvider(
        identityToken: session.identityToken,
        trustedDeviceId: session.trustedDeviceId,
        emailAddress: verifiedAccount.emailAddress,
        providerAccountIdentifier: verifiedAccount.providerAccountIdentifier
      )
    } catch {
      if let previousTokens {
        try tokenStore.save(previousTokens, productAccountId: session.productAccountId)
      } else {
        try tokenStore.clear(productAccountId: session.productAccountId)
      }
      throw error
    }
  }

  func clearLocalConnection(
    session: ProductAccountSessionSnapshot
  ) throws {
    try tokenStore.clear(productAccountId: session.productAccountId)
  }

  func loadConnection(
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus? {
    guard
      let status = try await transport.getGmailProviderConnection(
        identityToken: session.identityToken
      ),
      status.trustedDeviceId == session.trustedDeviceId,
      try tokenStore.load(productAccountId: session.productAccountId) != nil
    else {
      return nil
    }

    return status
  }
}

extension ConvexClient: GmailProviderConnectionTransport {}

struct GoogleGmailProviderCredentialVerifier: GmailProviderCredentialVerifying {
  private let gmailProfileURL: URL
  private let oauthClientId: String?
  private let session: URLSession
  private let tokenInfoURL: URL
  private let tokenRefreshURL: URL

  init(
    gmailProfileURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!,
    oauthClientId: String? =
      ProcessInfo.processInfo.environment["GMAIL_OAUTH_CLIENT_ID"]
      ?? DotEnvFile.value(for: "GMAIL_OAUTH_CLIENT_ID"),
    session: URLSession = .shared,
    tokenInfoURL: URL = URL(string: "https://oauth2.googleapis.com/tokeninfo")!,
    tokenRefreshURL: URL = URL(string: "https://oauth2.googleapis.com/token")!
  ) {
    self.gmailProfileURL = gmailProfileURL
    self.oauthClientId = oauthClientId
    self.session = session
    self.tokenInfoURL = tokenInfoURL
    self.tokenRefreshURL = tokenRefreshURL
  }

  func verify(
    accessToken: String,
    refreshToken: String,
    expectedEmailAddress: String,
    expectedProviderAccountIdentifier: String
  ) async throws -> VerifiedGmailAccount {
    guard let oauthClientId, !oauthClientId.isEmpty else {
      throw GmailProviderCredentialVerificationError.missingOAuthClientId
    }

    try await validateGmailAuthorization(accessToken: accessToken)
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
    guard let emailAddress = tokenInfo.email, let subject = tokenInfo.sub else {
      throw GmailProviderCredentialVerificationError.missingVerificationResponse
    }
    guard
      emailAddress.caseInsensitiveCompare(expectedEmailAddress) == .orderedSame,
      subject == expectedProviderAccountIdentifier
    else {
      throw GmailProviderCredentialVerificationError.accountMismatch
    }

    let refreshedTokenInfo = try await refreshTokenInfo(
      refreshToken: refreshToken,
      oauthClientId: oauthClientId
    )
    guard
      refreshedTokenInfo.email?.caseInsensitiveCompare(expectedEmailAddress) == .orderedSame,
      refreshedTokenInfo.sub == expectedProviderAccountIdentifier
    else {
      throw GmailProviderCredentialVerificationError.accountMismatch
    }

    return VerifiedGmailAccount(
      emailAddress: emailAddress,
      providerAccountIdentifier: subject,
      tokens: GmailProviderTokens(
        accessToken: accessToken,
        refreshToken: refreshToken
      )
    )
  }

  private func validateGmailAuthorization(accessToken: String) async throws {
    var request = URLRequest(url: gmailProfileURL)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

    let (_, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailProviderCredentialVerificationError.missingGmailAuthorization
    }
  }

  private func refreshTokenInfo(
    refreshToken: String,
    oauthClientId: String
  ) async throws -> GoogleTokenInfoResponse {
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
    try await validateGmailAuthorization(accessToken: tokenResponse.accessToken)

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

    return try JSONDecoder().decode(GoogleTokenInfoResponse.self, from: tokenInfoData)
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

private struct GoogleTokenInfoResponse: Decodable {
  let email: String?
  let sub: String?
}

private struct GoogleRefreshTokenResponse: Decodable {
  let accessToken: String

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
  }
}

#if DEBUG
  final class InMemoryGmailProviderTokenStore: GmailProviderTokenPersisting {
    private var tokensByProductAccountId: [String: GmailProviderTokens] = [:]

    func load(productAccountId: String) throws -> GmailProviderTokens? {
      tokensByProductAccountId[productAccountId]
    }

    func save(_ tokens: GmailProviderTokens, productAccountId: String) throws {
      tokensByProductAccountId[productAccountId] = tokens
    }

    func clear(productAccountId: String) throws {
      tokensByProductAccountId[productAccountId] = nil
    }
  }
#endif
