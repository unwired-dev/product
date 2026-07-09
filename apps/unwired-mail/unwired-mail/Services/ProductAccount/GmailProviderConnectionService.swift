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
  case accountMismatch
  case missingVerificationResponse

  var errorDescription: String? {
    switch self {
    case .invalidAccessToken:
      return "Gmail did not accept the access token."
    case .accountMismatch:
      return "The Gmail account did not match the verified token account."
    case .missingVerificationResponse:
      return "Gmail did not return account verification details."
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
  private let session: URLSession
  private let tokenInfoURL: URL

  init(
    session: URLSession = .shared,
    tokenInfoURL: URL = URL(string: "https://oauth2.googleapis.com/tokeninfo")!
  ) {
    self.session = session
    self.tokenInfoURL = tokenInfoURL
  }

  func verify(
    accessToken: String,
    refreshToken: String,
    expectedEmailAddress: String,
    expectedProviderAccountIdentifier: String
  ) async throws -> VerifiedGmailAccount {
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

    return VerifiedGmailAccount(
      emailAddress: emailAddress,
      providerAccountIdentifier: subject,
      tokens: GmailProviderTokens(
        accessToken: accessToken,
        refreshToken: refreshToken
      )
    )
  }
}

private struct GoogleTokenInfoResponse: Decodable {
  let email: String?
  let sub: String?
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
