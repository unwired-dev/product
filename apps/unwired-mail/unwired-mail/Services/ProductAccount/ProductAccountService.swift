import Foundation

struct ProductAccountConnectResponse: Decodable, Equatable {
  let accountCreated: Bool
  let deviceRegistered: Bool
  let hasEncryptedProductSyncPayloads: Bool
  let productAccountId: String
  let trustedDeviceId: String
}

struct EncryptedProductSyncPayload: Codable, Equatable {
  let encryptedPayload: ProductSyncEncryptedPayload
  let payloadIdentifier: String
  let updatedAt: Int64
}

struct EncryptedProductSyncPayloadPage: Decodable, Equatable {
  let continueCursor: String
  let isDone: Bool
  let page: [EncryptedProductSyncPayload]
}

protocol ProductAccountConnecting {
  func connect(identityToken: String) async throws -> ProductAccountConnectResponse
}

enum ProductAccountServiceError: LocalizedError, Equatable {
  case missingConvexURL

  var errorDescription: String? {
    switch self {
    case .missingConvexURL:
      return ConvexClientError.missingConvexURL.errorDescription
    }
  }
}

final class ConvexProductAccountService: ProductAccountConnecting {
  private let client: ConvexClient

  init(client: ConvexClient = ConvexClient()) {
    self.client = client
  }

  func connect(identityToken: String) async throws -> ProductAccountConnectResponse {
    let deviceIdentifier = try TrustedDeviceIdentity.currentIdentifier()

    return try await client.connectProductAccount(
      identityToken: identityToken,
      deviceIdentifier: deviceIdentifier,
      platform: TrustedDeviceIdentity.platform
    )
  }
}

struct PreviewProductAccountService: ProductAccountConnecting {
  let response: ProductAccountConnectResponse

  func connect(identityToken: String) async throws -> ProductAccountConnectResponse {
    _ = identityToken
    return response
  }
}

extension ProductAccountConnectResponse {
  static let preview = ProductAccountConnectResponse(
    accountCreated: true,
    deviceRegistered: true,
    hasEncryptedProductSyncPayloads: false,
    productAccountId: "productAccountFixtureId",
    trustedDeviceId: "trustedDeviceFixtureId"
  )

  static let resumed = ProductAccountConnectResponse(
    accountCreated: false,
    deviceRegistered: true,
    hasEncryptedProductSyncPayloads: true,
    productAccountId: "productAccountFixtureId",
    trustedDeviceId: "trustedDeviceFixtureId"
  )
}
