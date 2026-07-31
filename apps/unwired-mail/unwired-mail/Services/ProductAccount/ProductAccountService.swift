import Foundation

struct ProductAccountConnectResponse: Decodable, Equatable {
  let accountCreated: Bool
  let deviceRegistered: Bool
  let productSyncMaterialInitialized: Bool
  let productAccountId: String
  let trustedDeviceId: String
}

struct ProductSyncMaterialInitializedResponse: Decodable, Equatable {
  let productSyncMaterialInitialized: Bool
}

struct TrustedDeviceSummary: Decodable, Equatable, Identifiable {
  let displayName: String
  let id: String
  let lastSeenAt: Int64
  let platform: String
  let registeredAt: Int64
}

struct TrustedDeviceUnregistrationResponse: Decodable, Equatable {
  let registered: Bool
}

enum RecoveryKeyStatus: Equatable {
  case current
  case notBackedUp
  case replacedOnAnotherDevice
  case unavailable
}

struct AccountAndDevicesSnapshot: Equatable {
  let devices: [TrustedDeviceSummary]
  let recoveryKeyStatus: RecoveryKeyStatus
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
  func markProductSyncMaterialInitialized(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> ProductSyncMaterialInitializedResponse
  func unregisterTrustedDevice(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> TrustedDeviceUnregistrationResponse
}

protocol TrustedDeviceManaging {
  func listTrustedDevices(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> [TrustedDeviceSummary]
  func renameTrustedDevice(
    displayName: String,
    identityToken: String,
    trustedDeviceId: String,
    trustedDeviceToRenameId: String
  ) async throws -> TrustedDeviceSummary
}

protocol RecoveryMaterialTransporting {
  func getRecoveryMaterial(
    identityToken: String,
    payloadIdentifier: String
  ) async throws -> EncryptedProductSyncPayload?
  func putRecoveryMaterialIfUnchanged(
    identityToken: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId: String,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload
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
      deviceName: TrustedDeviceIdentity.displayName,
      platform: TrustedDeviceIdentity.platform
    )
  }

  func markProductSyncMaterialInitialized(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> ProductSyncMaterialInitializedResponse {
    try await client.markProductSyncMaterialInitialized(
      identityToken: identityToken,
      trustedDeviceId: trustedDeviceId
    )
  }

  func unregisterTrustedDevice(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> TrustedDeviceUnregistrationResponse {
    try await client.unregisterTrustedDevice(
      identityToken: identityToken,
      trustedDeviceId: trustedDeviceId
    )
  }
}

enum AccountAndDevicesServiceError: LocalizedError, Equatable {
  case missingProductSyncKeyMaterial
  case recoveryMaterialChanged

  var errorDescription: String? {
    switch self {
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before managing the Recovery Key."
    case .recoveryMaterialChanged:
      return "The Recovery Key changed on another Trusted Device. Refresh and try again."
    }
  }
}

final class AccountAndDevicesService {
  static let recoveryPayloadIdentifier = "product-account-recovery-v1"

  private let deviceTransport: TrustedDeviceManaging
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let recoveryTransport: RecoveryMaterialTransporting

  init(
    deviceTransport: TrustedDeviceManaging = ConvexClient(),
    keyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore(),
    recoveryTransport: RecoveryMaterialTransporting = ConvexClient()
  ) {
    self.deviceTransport = deviceTransport
    self.keyMaterialStore = keyMaterialStore
    self.recoveryTransport = recoveryTransport
  }

  func load(
    session: ProductAccountSessionSnapshot
  ) async throws -> AccountAndDevicesSnapshot {
    async let devices = deviceTransport.listTrustedDevices(
      identityToken: session.identityToken,
      trustedDeviceId: session.trustedDeviceId
    )
    async let remoteRecoveryMaterial = recoveryTransport.getRecoveryMaterial(
      identityToken: session.identityToken,
      payloadIdentifier: Self.recoveryPayloadIdentifier
    )
    let material = try keyMaterialStore.load(
      productAccountId: session.productAccountId
    )
    let (loadedDevices, remoteMaterial) = try await (
      devices,
      remoteRecoveryMaterial
    )

    return AccountAndDevicesSnapshot(
      devices: loadedDevices.sorted {
        if $0.id == session.trustedDeviceId { return true }
        if $1.id == session.trustedDeviceId { return false }
        if $0.registeredAt != $1.registeredAt {
          return $0.registeredAt < $1.registeredAt
        }
        return $0.id < $1.id
      },
      recoveryKeyStatus: recoveryKeyStatus(
        localMaterial: material,
        remoteMaterial: remoteMaterial
      )
    )
  }

  func renameDevice(
    _ device: TrustedDeviceSummary,
    displayName: String,
    session: ProductAccountSessionSnapshot
  ) async throws -> TrustedDeviceSummary {
    try await deviceTransport.renameTrustedDevice(
      displayName: displayName,
      identityToken: session.identityToken,
      trustedDeviceId: session.trustedDeviceId,
      trustedDeviceToRenameId: device.id
    )
  }

  func replaceRecoveryKey(
    session: ProductAccountSessionSnapshot,
    recentIdentityToken: String
  ) async throws -> ProductSyncRecoveryKey {
    guard
      let material = try keyMaterialStore.load(
        productAccountId: session.productAccountId
      )
    else {
      throw AccountAndDevicesServiceError.missingProductSyncKeyMaterial
    }
    let existing = try await recoveryTransport.getRecoveryMaterial(
      identityToken: recentIdentityToken,
      payloadIdentifier: Self.recoveryPayloadIdentifier
    )
    let replacement = try material.replacingRecoveryKey()
    try keyMaterialStore.save(
      replacement,
      productAccountId: session.productAccountId
    )
    do {
      let written = try await recoveryTransport.putRecoveryMaterialIfUnchanged(
        identityToken: recentIdentityToken,
        payloadIdentifier: Self.recoveryPayloadIdentifier,
        encryptedPayload: replacement.recoveryWrappedAccountKey,
        trustedDeviceId: session.trustedDeviceId,
        expectedUpdatedAt: existing?.updatedAt
      )
      guard written.encryptedPayload == replacement.recoveryWrappedAccountKey else {
        throw AccountAndDevicesServiceError.recoveryMaterialChanged
      }
    } catch {
      do {
        let authoritative = try await recoveryTransport.getRecoveryMaterial(
          identityToken: recentIdentityToken,
          payloadIdentifier: Self.recoveryPayloadIdentifier
        )
        if authoritative?.encryptedPayload
          == replacement.recoveryWrappedAccountKey
        {
          return replacement.recoveryKey
        }
        try? keyMaterialStore.save(
          material,
          productAccountId: session.productAccountId
        )
      } catch {
        // Keep the replacement locally until connectivity can resolve whether
        // the compare-and-set committed.
      }
      throw error
    }
    return replacement.recoveryKey
  }

  func revealCurrentRecoveryKey(
    session: ProductAccountSessionSnapshot,
    recentIdentityToken: String
  ) async throws -> ProductSyncRecoveryKey {
    guard
      let material = try keyMaterialStore.load(
        productAccountId: session.productAccountId
      )
    else {
      throw AccountAndDevicesServiceError.missingProductSyncKeyMaterial
    }
    let remote = try await recoveryTransport.getRecoveryMaterial(
      identityToken: recentIdentityToken,
      payloadIdentifier: Self.recoveryPayloadIdentifier
    )
    guard remote?.encryptedPayload == material.recoveryWrappedAccountKey else {
      throw AccountAndDevicesServiceError.recoveryMaterialChanged
    }
    return material.recoveryKey
  }

  private func recoveryKeyStatus(
    localMaterial: ProductSyncKeyMaterial?,
    remoteMaterial: EncryptedProductSyncPayload?
  ) -> RecoveryKeyStatus {
    guard let localMaterial else { return .unavailable }
    guard let remoteMaterial else { return .notBackedUp }
    return remoteMaterial.encryptedPayload
      == localMaterial.recoveryWrappedAccountKey
      ? .current : .replacedOnAnotherDevice
  }
}

extension ConvexClient: TrustedDeviceManaging {}

extension ConvexClient: RecoveryMaterialTransporting {
  func getRecoveryMaterial(
    identityToken: String,
    payloadIdentifier: String
  ) async throws -> EncryptedProductSyncPayload? {
    try await getEncryptedProductSyncPayload(
      identityToken: identityToken,
      payloadIdentifier: payloadIdentifier
    )
  }

  func putRecoveryMaterialIfUnchanged(
    identityToken: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId: String,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    try await replaceRecoveryMaterialIfUnchanged(
      identityToken: identityToken,
      encryptedPayload: encryptedPayload,
      trustedDeviceId: trustedDeviceId,
      expectedUpdatedAt: expectedUpdatedAt
    )
  }
}

struct PreviewProductAccountService: ProductAccountConnecting {
  let response: ProductAccountConnectResponse

  func connect(identityToken: String) async throws -> ProductAccountConnectResponse {
    _ = identityToken
    return response
  }

  func markProductSyncMaterialInitialized(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> ProductSyncMaterialInitializedResponse {
    _ = identityToken
    _ = trustedDeviceId
    return ProductSyncMaterialInitializedResponse(
      productSyncMaterialInitialized: true
    )
  }

  func unregisterTrustedDevice(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> TrustedDeviceUnregistrationResponse {
    _ = identityToken
    _ = trustedDeviceId
    return TrustedDeviceUnregistrationResponse(registered: false)
  }
}

extension ProductAccountConnectResponse {
  static let preview = ProductAccountConnectResponse(
    accountCreated: true,
    deviceRegistered: true,
    productSyncMaterialInitialized: false,
    productAccountId: "productAccountFixtureId",
    trustedDeviceId: "trustedDeviceFixtureId"
  )

  static let resumed = ProductAccountConnectResponse(
    accountCreated: false,
    deviceRegistered: true,
    productSyncMaterialInitialized: true,
    productAccountId: "productAccountFixtureId",
    trustedDeviceId: "trustedDeviceFixtureId"
  )
}
