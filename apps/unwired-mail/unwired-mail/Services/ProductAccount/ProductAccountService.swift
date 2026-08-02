import Foundation

// swiftlint:disable file_length

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

struct ProductAccountDeletionResponse: Decodable, Equatable {
  let deleted: Bool
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
  func productSyncRecoveryIsBackedUp(
    identityToken: String,
    expectedRecoveryWrappedAccountKey: ProductSyncEncryptedPayload?
  ) async throws -> Bool
  func productSyncRecoveryMaterial(
    identityToken: String
  ) async throws -> EncryptedProductSyncPayload?
  func markProductSyncMaterialInitialized(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> ProductSyncMaterialInitializedResponse
  func unregisterTrustedDevice(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> TrustedDeviceUnregistrationResponse
  func deleteProductAccount(
    authorizationCode: String,
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> ProductAccountDeletionResponse
}

extension ProductAccountConnecting {
  func deleteProductAccount(
    authorizationCode _: String,
    identityToken _: String,
    trustedDeviceId _: String
  ) async throws -> ProductAccountDeletionResponse {
    throw ProductAccountServiceError.deletionUnavailable
  }

  func productSyncRecoveryMaterial(
    identityToken _: String
  ) async throws -> EncryptedProductSyncPayload? {
    nil
  }
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
  case deletionUnavailable
  case missingConvexURL
  case productAccountDeleted

  var errorDescription: String? {
    switch self {
    case .deletionUnavailable:
      return "Product Account deletion is unavailable. Check your connection and try again."
    case .missingConvexURL:
      return ConvexClientError.missingConvexURL.errorDescription
    case .productAccountDeleted:
      return "This Product Account was deleted. Local Product Account data was removed."
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

    do {
      return try await client.connectProductAccount(
        identityToken: identityToken,
        deviceIdentifier: deviceIdentifier,
        deviceName: TrustedDeviceIdentity.displayName,
        platform: TrustedDeviceIdentity.platform
      )
    } catch let ConvexClientError.convexApplicationFailure(_, code, _)
      where code == "PRODUCT_ACCOUNT_DELETED"
    {
      throw ProductAccountServiceError.productAccountDeleted
    }
  }

  func deleteProductAccount(
    authorizationCode: String,
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> ProductAccountDeletionResponse {
    while true {
      do {
        let response = try await client.deleteProductAccount(
          authorizationCode: authorizationCode,
          identityToken: identityToken,
          trustedDeviceId: trustedDeviceId
        )
        if response.deleted { return response }
      } catch let ConvexClientError.convexApplicationFailure(_, code, _)
        where code == "PRODUCT_ACCOUNT_DELETED"
      {
        return ProductAccountDeletionResponse(deleted: true)
      }
    }
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

  func productSyncRecoveryIsBackedUp(
    identityToken: String,
    expectedRecoveryWrappedAccountKey: ProductSyncEncryptedPayload?
  ) async throws -> Bool {
    guard let expectedRecoveryWrappedAccountKey else { return false }
    return try await productSyncRecoveryMaterial(identityToken: identityToken)?.encryptedPayload
      == expectedRecoveryWrappedAccountKey
  }

  func productSyncRecoveryMaterial(
    identityToken: String
  ) async throws -> EncryptedProductSyncPayload? {
    try await client.getEncryptedProductSyncPayload(
      identityToken: identityToken,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier
    )
  }

  func unregisterTrustedDevice(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> TrustedDeviceUnregistrationResponse {
    let deviceIdentifier = try TrustedDeviceIdentity.currentIdentifier()
    return try await client.unregisterTrustedDevice(
      deviceIdentifier: deviceIdentifier,
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

actor ProductAccountRecoveryOperationGate {
  private var lockedProductAccountIds: Set<String> = []
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  func acquire(productAccountId: String) async {
    guard lockedProductAccountIds.contains(productAccountId) else {
      lockedProductAccountIds.insert(productAccountId)
      return
    }
    await withCheckedContinuation { continuation in
      waiters[productAccountId, default: []].append(continuation)
    }
  }

  func release(productAccountId: String) {
    guard var productAccountWaiters = waiters[productAccountId], !productAccountWaiters.isEmpty
    else {
      lockedProductAccountIds.remove(productAccountId)
      waiters[productAccountId] = nil
      return
    }
    let next = productAccountWaiters.removeFirst()
    waiters[productAccountId] = productAccountWaiters.isEmpty ? nil : productAccountWaiters
    next.resume()
  }

  #if DEBUG
    func pendingWaiterCount(productAccountId: String) -> Int {
      waiters[productAccountId]?.count ?? 0
    }
  #endif
}

let productAccountRecoveryOperationGate = ProductAccountRecoveryOperationGate()

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
    session: ProductAccountSessionSnapshot,
    identityToken: String? = nil
  ) async throws -> AccountAndDevicesSnapshot {
    async let devices = deviceTransport.listTrustedDevices(
      identityToken: identityToken ?? session.identityToken,
      trustedDeviceId: session.trustedDeviceId
    )
    async let remoteRecoveryMaterial = recoveryTransport.getRecoveryMaterial(
      identityToken: identityToken ?? session.identityToken,
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
    session: ProductAccountSessionSnapshot,
    identityToken: String? = nil
  ) async throws -> TrustedDeviceSummary {
    try await deviceTransport.renameTrustedDevice(
      displayName: displayName,
      identityToken: identityToken ?? session.identityToken,
      trustedDeviceId: session.trustedDeviceId,
      trustedDeviceToRenameId: device.id
    )
  }

  func replaceRecoveryKey(
    session: ProductAccountSessionSnapshot,
    recentIdentityToken: String,
    isSessionCurrent: () -> Bool = { true },
    recoveryKeyPublished: (String) throws -> Void = { _ in },
    recoveryKeyRejected: (String) throws -> Void = { _ in }
  ) async throws -> ProductSyncRecoveryKey {
    await productAccountRecoveryOperationGate.acquire(
      productAccountId: session.productAccountId
    )
    do {
      let recoveryKey = try await performRecoveryKeyReplacement(
        session: session,
        recentIdentityToken: recentIdentityToken,
        isSessionCurrent: isSessionCurrent,
        recoveryKeyPublished: recoveryKeyPublished,
        recoveryKeyRejected: recoveryKeyRejected
      )
      await productAccountRecoveryOperationGate.release(
        productAccountId: session.productAccountId
      )
      return recoveryKey
    } catch {
      await productAccountRecoveryOperationGate.release(
        productAccountId: session.productAccountId
      )
      throw error
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func performRecoveryKeyReplacement(
    session: ProductAccountSessionSnapshot,
    recentIdentityToken: String,
    isSessionCurrent: () -> Bool,
    recoveryKeyPublished: (String) throws -> Void,
    recoveryKeyRejected: (String) throws -> Void
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
    guard isSessionCurrent() else { throw CancellationError() }
    let replacement = try material.replacingRecoveryKey()
    try keyMaterialStore.save(
      replacement,
      productAccountId: session.productAccountId
    )
    do {
      try recoveryKeyPublished(replacement.recoveryKey.rawValue)
    } catch {
      restoreKeyMaterial(material, productAccountId: session.productAccountId)
      throw error
    }
    do {
      let written = try await recoveryTransport.putRecoveryMaterialIfUnchanged(
        identityToken: recentIdentityToken,
        payloadIdentifier: Self.recoveryPayloadIdentifier,
        encryptedPayload: replacement.recoveryWrappedAccountKey,
        trustedDeviceId: session.trustedDeviceId,
        expectedUpdatedAt: existing?.updatedAt
      )
      guard written.encryptedPayload == replacement.recoveryWrappedAccountKey else {
        if isSessionCurrent() {
          restoreKeyMaterial(material, productAccountId: session.productAccountId)
        }
        try recoveryKeyRejected(replacement.recoveryKey.rawValue)
        throw AccountAndDevicesServiceError.recoveryMaterialChanged
      }
    } catch AccountAndDevicesServiceError.recoveryMaterialChanged {
      throw AccountAndDevicesServiceError.recoveryMaterialChanged
    } catch let replacementError {
      let authoritative: EncryptedProductSyncPayload?
      do {
        authoritative = try await recoveryTransport.getRecoveryMaterial(
          identityToken: recentIdentityToken,
          payloadIdentifier: Self.recoveryPayloadIdentifier
        )
      } catch {
        // Keep the replacement locally until connectivity can resolve whether
        // the compare-and-set committed.
        guard isSessionCurrent() else { throw CancellationError() }
        return replacement.recoveryKey
      }
      if authoritative?.encryptedPayload == replacement.recoveryWrappedAccountKey {
        guard isSessionCurrent() else { throw CancellationError() }
        return replacement.recoveryKey
      }
      guard isSessionCurrent() else { throw CancellationError() }
      try? keyMaterialStore.save(
        material,
        productAccountId: session.productAccountId
      )
      try recoveryKeyRejected(replacement.recoveryKey.rawValue)
      throw replacementError
    }
    guard isSessionCurrent() else { throw CancellationError() }
    return replacement.recoveryKey
  }

  private func restoreKeyMaterial(
    _ material: ProductSyncKeyMaterial,
    productAccountId: String
  ) {
    try? keyMaterialStore.save(
      material,
      productAccountId: productAccountId
    )
  }

  func revealCurrentRecoveryKey(
    session: ProductAccountSessionSnapshot,
    recentIdentityToken: String,
    recoveryKeyPublished: (String) -> Void = { _ in }
  ) async throws -> ProductSyncRecoveryKey {
    await productAccountRecoveryOperationGate.acquire(
      productAccountId: session.productAccountId
    )
    do {
      let recoveryKey = try await performCurrentRecoveryKeyReveal(
        session: session,
        recentIdentityToken: recentIdentityToken
      )
      recoveryKeyPublished(recoveryKey.rawValue)
      await productAccountRecoveryOperationGate.release(
        productAccountId: session.productAccountId
      )
      return recoveryKey
    } catch {
      await productAccountRecoveryOperationGate.release(
        productAccountId: session.productAccountId
      )
      throw error
    }
  }

  private func performCurrentRecoveryKeyReveal(
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

  func productSyncRecoveryIsBackedUp(
    identityToken _: String,
    expectedRecoveryWrappedAccountKey _: ProductSyncEncryptedPayload?
  ) async throws -> Bool {
    true
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
