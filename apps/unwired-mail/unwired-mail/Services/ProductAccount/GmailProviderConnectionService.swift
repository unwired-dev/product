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
      account: accountName(productAccountId: productAccountId)
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
      try tokenStore.clear(productAccountId: session.productAccountId)
      throw error
    }
  }

  func loadConnection(
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus? {
    try await transport.getGmailProviderConnection(identityToken: session.identityToken)
  }
}

extension ConvexClient: GmailProviderConnectionTransport {}

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
