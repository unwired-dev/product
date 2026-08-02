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

enum ProductSyncKeyRotationState: String, Decodable, Equatable {
  case complete
  case pending
}

struct ProductSyncKeyRotationResponse: Decodable, Equatable {
  let keyEpoch: Int
  let pendingDeviceCount: Int
  let state: ProductSyncKeyRotationState
}

struct ProductSyncKeyRotationStatus: Decodable, Equatable {
  let encryptedTransition: ProductSyncEncryptedPayload
  let keyEpoch: Int
  let pendingDeviceCount: Int
}

enum RecoveryKeyStatus: Equatable {
  case current
  case notBackedUp
  case replacedOnAnotherDevice
  case unavailable
}

struct AccountAndDevicesSnapshot: Equatable {
  let devices: [TrustedDeviceSummary]
  let pendingKeyRotationDeviceCount: Int
  let recoveryKeyStatus: RecoveryKeyStatus

  init(
    devices: [TrustedDeviceSummary],
    pendingKeyRotationDeviceCount: Int = 0,
    recoveryKeyStatus: RecoveryKeyStatus
  ) {
    self.devices = devices
    self.pendingKeyRotationDeviceCount = pendingKeyRotationDeviceCount
    self.recoveryKeyStatus = recoveryKeyStatus
  }
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
    trustedDeviceId: String,
    expectedRecoveryWrappedAccountKey: ProductSyncEncryptedPayload?
  ) async throws -> Bool
  func productSyncRecoveryMaterial(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> EncryptedProductSyncPayload?
  func markProductSyncMaterialInitialized(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> ProductSyncMaterialInitializedResponse
  func unregisterTrustedDevice(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> TrustedDeviceUnregistrationResponse
  func reconcileProductSyncKeyRotation(
    identityToken: String,
    productAccountId: String,
    trustedDeviceId: String
  ) async throws -> ProductSyncKeyRotationResponse?
}

extension ProductAccountConnecting {
  func productSyncRecoveryMaterial(
    identityToken _: String,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload? {
    nil
  }

  func reconcileProductSyncKeyRotation(
    identityToken _: String,
    productAccountId _: String,
    trustedDeviceId _: String
  ) async throws -> ProductSyncKeyRotationResponse? {
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
    payloadIdentifier: String,
    trustedDeviceId: String
  ) async throws -> EncryptedProductSyncPayload?
  func putRecoveryMaterialIfUnchanged(
    identityToken: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId: String,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload
}

protocol ProductSyncKeyRotationTransporting {
  // swiftlint:disable:next function_parameter_count
  func revokeTrustedDevice(
    encryptedTransition: ProductSyncEncryptedPayload,
    expectedRecoveryUpdatedAt: Int64,
    identityToken: String,
    recoveryWrappedAccountKey: ProductSyncEncryptedPayload,
    trustedDeviceId: String,
    trustedDeviceToRevokeId: String
  ) async throws -> ProductSyncKeyRotationResponse
  func productSyncKeyRotation(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> ProductSyncKeyRotationStatus?
  func acknowledgeProductSyncKeyRotation(
    identityToken: String,
    keyEpoch: Int,
    trustedDeviceId: String
  ) async throws -> ProductSyncKeyRotationResponse
}

enum ProductAccountServiceError: LocalizedError, Equatable {
  case missingConvexURL
  case trustedDeviceRevoked

  var errorDescription: String? {
    switch self {
    case .missingConvexURL:
      return ConvexClientError.missingConvexURL.errorDescription
    case .trustedDeviceRevoked:
      return "This Trusted Device was revoked. Its local Product Account data was removed."
    }
  }
}

final class ConvexProductAccountService: ProductAccountConnecting {
  private let client: ConvexClient
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting

  init(
    client: ConvexClient = ConvexClient(),
    keyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore()
  ) {
    self.client = client
    self.keyMaterialStore = keyMaterialStore
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
    } catch let ConvexClientError.convexFailure(_, message)
      where message == "Trusted device revoked; purge local data"
    {
      throw ProductAccountServiceError.trustedDeviceRevoked
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
    trustedDeviceId: String,
    expectedRecoveryWrappedAccountKey: ProductSyncEncryptedPayload?
  ) async throws -> Bool {
    guard let expectedRecoveryWrappedAccountKey else { return false }
    return try await productSyncRecoveryMaterial(
      identityToken: identityToken,
      trustedDeviceId: trustedDeviceId
    )?.encryptedPayload
      == expectedRecoveryWrappedAccountKey
  }

  func productSyncRecoveryMaterial(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> EncryptedProductSyncPayload? {
    try await client.getEncryptedProductSyncPayload(
      identityToken: identityToken,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      trustedDeviceId: trustedDeviceId
    )
  }

  func reconcileProductSyncKeyRotation(
    identityToken: String,
    productAccountId: String,
    trustedDeviceId: String
  ) async throws -> ProductSyncKeyRotationResponse? {
    try await ProductSyncKeyRotationCoordinator(
      keyMaterialStore: keyMaterialStore,
      transport: client
    ).reconcile(
      identityToken: identityToken,
      productAccountId: productAccountId,
      trustedDeviceId: trustedDeviceId
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
  case revokeCurrentDevice

  var errorDescription: String? {
    switch self {
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before managing the Recovery Key."
    case .recoveryMaterialChanged:
      return "The Recovery Key changed on another Trusted Device. Refresh and try again."
    case .revokeCurrentDevice:
      return "Use Sign Out to remove the current Trusted Device."
    }
  }
}

struct ProductSyncKeyRotationCoordinator {
  let keyMaterialStore: ProductSyncKeyMaterialPersisting
  let transport: ProductSyncKeyRotationTransporting

  func reconcile(
    identityToken: String,
    productAccountId: String,
    trustedDeviceId: String
  ) async throws -> ProductSyncKeyRotationResponse? {
    guard
      let status = try await transport.productSyncKeyRotation(
        identityToken: identityToken,
        trustedDeviceId: trustedDeviceId
      )
    else { return nil }
    guard
      var material = try keyMaterialStore.load(productAccountId: productAccountId)
    else {
      throw AccountAndDevicesServiceError.missingProductSyncKeyMaterial
    }
    if material.accountKeyVersion < status.keyEpoch {
      material = try material.applyingTransition(
        status.encryptedTransition,
        keyVersion: status.keyEpoch,
        productAccountId: productAccountId
      )
      try keyMaterialStore.save(material, productAccountId: productAccountId)
    } else if material.accountKeyVersion != status.keyEpoch {
      throw AccountAndDevicesServiceError.recoveryMaterialChanged
    }
    return try await transport.acknowledgeProductSyncKeyRotation(
      identityToken: identityToken,
      keyEpoch: status.keyEpoch,
      trustedDeviceId: trustedDeviceId
    )
  }

  // swiftlint:disable:next function_body_length
  func revoke(
    device: TrustedDeviceSummary,
    session: ProductAccountSessionSnapshot,
    recentIdentityToken: String,
    recoveryMaterial: EncryptedProductSyncPayload
  ) async throws -> ProductSyncKeyRotationResponse {
    guard device.id != session.trustedDeviceId else {
      throw AccountAndDevicesServiceError.revokeCurrentDevice
    }
    guard
      let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw AccountAndDevicesServiceError.missingProductSyncKeyMaterial
    }
    if let activeRotation = try await transport.productSyncKeyRotation(
      identityToken: recentIdentityToken,
      trustedDeviceId: session.trustedDeviceId
    ), activeRotation.keyEpoch == material.accountKeyVersion {
      return try await transport.revokeTrustedDevice(
        encryptedTransition: activeRotation.encryptedTransition,
        expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
        identityToken: recentIdentityToken,
        recoveryWrappedAccountKey: material.recoveryWrappedAccountKey,
        trustedDeviceId: session.trustedDeviceId,
        trustedDeviceToRevokeId: device.id
      )
    }
    guard recoveryMaterial.encryptedPayload == material.recoveryWrappedAccountKey else {
      throw AccountAndDevicesServiceError.recoveryMaterialChanged
    }
    let rotatedMaterial = try material.rotatingAccountKey(
      toVersion: material.accountKeyVersion + 1
    )
    let response = try await transport.revokeTrustedDevice(
      encryptedTransition: material.encryptedTransition(
        to: rotatedMaterial,
        productAccountId: session.productAccountId
      ),
      expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
      identityToken: recentIdentityToken,
      recoveryWrappedAccountKey: rotatedMaterial.recoveryWrappedAccountKey,
      trustedDeviceId: session.trustedDeviceId,
      trustedDeviceToRevokeId: device.id
    )
    if response.keyEpoch == material.accountKeyVersion {
      return response
    }
    guard response.keyEpoch == rotatedMaterial.accountKeyVersion else {
      throw AccountAndDevicesServiceError.recoveryMaterialChanged
    }
    guard
      let authoritativeRotation = try await transport.productSyncKeyRotation(
        identityToken: recentIdentityToken,
        trustedDeviceId: session.trustedDeviceId
      ),
      authoritativeRotation.keyEpoch == response.keyEpoch
    else {
      throw AccountAndDevicesServiceError.recoveryMaterialChanged
    }
    let adoptedMaterial = try material.applyingTransition(
      authoritativeRotation.encryptedTransition,
      keyVersion: authoritativeRotation.keyEpoch,
      productAccountId: session.productAccountId
    )
    try keyMaterialStore.save(adoptedMaterial, productAccountId: session.productAccountId)
    return try await transport.acknowledgeProductSyncKeyRotation(
      identityToken: recentIdentityToken,
      keyEpoch: response.keyEpoch,
      trustedDeviceId: session.trustedDeviceId
    )
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

// swiftlint:disable:next type_body_length
final class AccountAndDevicesService {
  static let recoveryPayloadIdentifier = "product-account-recovery-v1"

  private let deviceTransport: TrustedDeviceManaging
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let recoveryTransport: RecoveryMaterialTransporting
  private let rotationTransport: ProductSyncKeyRotationTransporting?

  init(
    deviceTransport: TrustedDeviceManaging = ConvexClient(),
    keyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore(),
    recoveryTransport: RecoveryMaterialTransporting = ConvexClient(),
    rotationTransport: ProductSyncKeyRotationTransporting? = nil
  ) {
    self.deviceTransport = deviceTransport
    self.keyMaterialStore = keyMaterialStore
    self.recoveryTransport = recoveryTransport
    self.rotationTransport =
      rotationTransport ?? deviceTransport as? ProductSyncKeyRotationTransporting
  }

  func load(
    session: ProductAccountSessionSnapshot,
    identityToken: String? = nil
  ) async throws -> AccountAndDevicesSnapshot {
    let resolvedIdentityToken = identityToken ?? session.identityToken
    let rotationResponse: ProductSyncKeyRotationResponse? =
      if let rotationTransport {
        try await ProductSyncKeyRotationCoordinator(
          keyMaterialStore: keyMaterialStore,
          transport: rotationTransport
        ).reconcile(
          identityToken: resolvedIdentityToken,
          productAccountId: session.productAccountId,
          trustedDeviceId: session.trustedDeviceId
        )
      } else {
        nil
      }
    async let devices = deviceTransport.listTrustedDevices(
      identityToken: resolvedIdentityToken,
      trustedDeviceId: session.trustedDeviceId
    )
    async let remoteRecoveryMaterial = recoveryTransport.getRecoveryMaterial(
      identityToken: resolvedIdentityToken,
      payloadIdentifier: Self.recoveryPayloadIdentifier,
      trustedDeviceId: session.trustedDeviceId
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
      pendingKeyRotationDeviceCount: rotationResponse?.pendingDeviceCount ?? 0,
      recoveryKeyStatus:
        rotationResponse == nil
        ? recoveryKeyStatus(
          localMaterial: material,
          remoteMaterial: remoteMaterial
        ) : .current
    )
  }

  func revokeDevice(
    _ device: TrustedDeviceSummary,
    session: ProductAccountSessionSnapshot,
    recentIdentityToken: String
  ) async throws -> ProductSyncKeyRotationResponse {
    guard let rotationTransport else {
      throw AccountAndDevicesServiceError.recoveryMaterialChanged
    }
    await productAccountRecoveryOperationGate.acquire(
      productAccountId: session.productAccountId
    )
    do {
      guard
        let recoveryMaterial = try await recoveryTransport.getRecoveryMaterial(
          identityToken: recentIdentityToken,
          payloadIdentifier: Self.recoveryPayloadIdentifier,
          trustedDeviceId: session.trustedDeviceId
        )
      else {
        throw AccountAndDevicesServiceError.recoveryMaterialChanged
      }
      let response = try await ProductSyncKeyRotationCoordinator(
        keyMaterialStore: keyMaterialStore,
        transport: rotationTransport
      ).revoke(
        device: device,
        session: session,
        recentIdentityToken: recentIdentityToken,
        recoveryMaterial: recoveryMaterial
      )
      await productAccountRecoveryOperationGate.release(
        productAccountId: session.productAccountId
      )
      return response
    } catch {
      await productAccountRecoveryOperationGate.release(
        productAccountId: session.productAccountId
      )
      throw error
    }
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
      payloadIdentifier: Self.recoveryPayloadIdentifier,
      trustedDeviceId: session.trustedDeviceId
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
          payloadIdentifier: Self.recoveryPayloadIdentifier,
          trustedDeviceId: session.trustedDeviceId
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
      payloadIdentifier: Self.recoveryPayloadIdentifier,
      trustedDeviceId: session.trustedDeviceId
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
extension ConvexClient: ProductSyncKeyRotationTransporting {}

extension ConvexClient: RecoveryMaterialTransporting {
  func getRecoveryMaterial(
    identityToken: String,
    payloadIdentifier: String,
    trustedDeviceId: String
  ) async throws -> EncryptedProductSyncPayload? {
    try await getEncryptedProductSyncPayload(
      identityToken: identityToken,
      payloadIdentifier: payloadIdentifier,
      trustedDeviceId: trustedDeviceId
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
    trustedDeviceId _: String,
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
