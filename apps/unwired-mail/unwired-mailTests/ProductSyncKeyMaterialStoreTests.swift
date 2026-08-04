import Foundation
import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

final class ProductSyncKeyMaterialStoreTests: XCTestCase {
  private var store = InMemoryProductSyncKeyMaterialStore()

  override func setUp() {
    store = InMemoryProductSyncKeyMaterialStore()
  }

  func testEnsureMaterialCreatesAndReusesLocalMaterialForProductAccount() throws {
    let firstMaterial = try store.ensureMaterial(
      productAccountId: "productAccountFixtureId",
      allowCreation: true
    )
    let secondMaterial = try store.ensureMaterial(
      productAccountId: "productAccountFixtureId",
      allowCreation: false
    )

    XCTAssertEqual(secondMaterial, firstMaterial)
    XCTAssertEqual(store.saveCount, 2)
  }

  func testEnsureMaterialRequiresRecoveryWhenCreationIsNotAllowed() {
    XCTAssertThrowsError(
      try store.ensureMaterial(
        productAccountId: "productAccountFixtureId",
        allowCreation: false
      )
    ) { error in
      XCTAssertEqual(error as? ProductSyncKeyMaterialStoreError, .recoveryRequired)
    }
  }

  func testRestorePersistsRecoveryKeyMaterialForProductAccount() throws {
    let originalMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 9, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 10, count: ProductSyncKeyMaterial.keyByteCount)
    )

    let restoredMaterial = try store.restore(
      productAccountId: "productAccountFixtureId",
      recoveryKey: originalMaterial.recoveryKey,
      recoveryWrappedAccountKey: originalMaterial.recoveryWrappedAccountKey
    )

    XCTAssertEqual(restoredMaterial.accountKeyData, originalMaterial.accountKeyData)
    XCTAssertEqual(try store.load(productAccountId: "productAccountFixtureId"), restoredMaterial)
  }

  func testReplacingRecoveryKeyPreservesTheProductSyncAccountKey() throws {
    let originalMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 9, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 10, count: ProductSyncKeyMaterial.keyByteCount)
    )

    let replacement = try originalMaterial.replacingRecoveryKey(
      with: Data(repeating: 11, count: ProductSyncKeyMaterial.keyByteCount)
    )

    XCTAssertEqual(replacement.accountKeyData, originalMaterial.accountKeyData)
    XCTAssertNotEqual(replacement.recoveryKey, originalMaterial.recoveryKey)
    XCTAssertEqual(
      try ProductSyncKeyMaterial.restore(
        recoveryKey: replacement.recoveryKey,
        recoveryWrappedAccountKey: replacement.recoveryWrappedAccountKey
      ).accountKeyData,
      originalMaterial.accountKeyData
    )
  }
}

@MainActor
final class AccountAndDevicesServiceTests: XCTestCase {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "stored-token",
    productAccountId: "product-account-\(UUID().uuidString)",
    trustedDeviceId: "device-current"
  )

  private func waitForRecoveryOperationWaiter(productAccountId: String) async {
    let queued = expectation(description: "recovery operation queued")
    let observer = Task {
      for _ in 0..<1_000 {
        if await productAccountRecoveryOperationGate.pendingWaiterCount(
          productAccountId: productAccountId
        ) > 0 {
          queued.fulfill()
          return
        }
        await Task.yield()
      }
    }
    await fulfillment(of: [queued], timeout: 1)
    observer.cancel()
  }

  func testReconcileAdoptsPendingKeyRotationBeforeAcknowledgingDevice() async throws {
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let original = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 1, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 2, count: ProductSyncKeyMaterial.keyByteCount)
    )
    try keyMaterialStore.save(original, productAccountId: session.productAccountId)
    let rotated = try original.rotatingAccountKey(
      toVersion: 2,
      accountKeyData: Data(repeating: 3, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let transport = RecordingProductSyncKeyRotationTransport()
    transport.rotationStatus = ProductSyncKeyRotationStatus(
      encryptedTransition: try original.encryptedTransition(
        to: rotated,
        productAccountId: session.productAccountId
      ),
      keyEpoch: 2,
      pendingDeviceCount: 2
    )
    transport.acknowledgementResponse = ProductSyncKeyRotationResponse(
      keyEpoch: 2,
      pendingDeviceCount: 1,
      state: .pending
    )

    let response = try await ProductSyncKeyRotationCoordinator(
      keyMaterialStore: keyMaterialStore,
      transport: transport
    ).reconcile(
      identityToken: "recent-token",
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )

    XCTAssertEqual(response?.pendingDeviceCount, 1)
    XCTAssertEqual(
      try keyMaterialStore.load(productAccountId: session.productAccountId),
      rotated
    )
    XCTAssertEqual(transport.acknowledgedKeyEpoch, 2)
    XCTAssertEqual(transport.acknowledgedTrustedDeviceId, session.trustedDeviceId)
  }

  func testReconcileRebindsRecoveryMarkerWhenMaterialAlreadyAdopted() async throws {
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let original = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 1, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 2, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let rotated = try original.rotatingAccountKey(
      toVersion: 2,
      accountKeyData: Data(repeating: 3, count: ProductSyncKeyMaterial.keyByteCount)
    )
    try keyMaterialStore.save(rotated, productAccountId: session.productAccountId)
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.saveUnacknowledgedRecoveryKey(
      UnacknowledgedRecoveryKey(
        recoveryKey: rotated.recoveryKey.rawValue,
        recoveryWrappedAccountKey: original.recoveryWrappedAccountKey
      ),
      productAccountId: session.productAccountId
    )
    let transport = RecordingProductSyncKeyRotationTransport()
    transport.rotationStatus = ProductSyncKeyRotationStatus(
      encryptedTransition: try original.encryptedTransition(
        to: rotated,
        productAccountId: session.productAccountId
      ),
      keyEpoch: 2,
      pendingDeviceCount: 1
    )

    _ = try await ProductSyncKeyRotationCoordinator(
      keyMaterialStore: keyMaterialStore,
      transport: transport,
      sessionStore: sessionStore
    ).reconcile(
      identityToken: "recent-token",
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )

    XCTAssertEqual(
      try sessionStore.loadUnacknowledgedRecoveryKey(
        productAccountId: session.productAccountId
      )?.recoveryWrappedAccountKey,
      rotated.recoveryWrappedAccountKey
    )
    XCTAssertEqual(transport.acknowledgedKeyEpoch, 2)
  }

  // swiftlint:disable:next function_body_length
  func testRevokeRotatesLocalKeyAndAcknowledgesOnlyAfterRemoteCutoff() async throws {
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let original = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 4, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 5, count: ProductSyncKeyMaterial.keyByteCount)
    )
    try keyMaterialStore.save(original, productAccountId: session.productAccountId)
    let recoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: original.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 17
    )
    let transport = RecordingProductSyncKeyRotationTransport()
    let authoritativeRotated = try original.rotatingAccountKey(
      toVersion: 2,
      accountKeyData: Data(repeating: 6, count: ProductSyncKeyMaterial.keyByteCount)
    )
    transport.rotationStatus = ProductSyncKeyRotationStatus(
      encryptedTransition: try original.encryptedTransition(
        to: authoritativeRotated,
        productAccountId: session.productAccountId
      ),
      keyEpoch: 2,
      pendingDeviceCount: 2
    )
    transport.revocationResponse = ProductSyncKeyRotationResponse(
      keyEpoch: 2,
      pendingDeviceCount: 1,
      state: .pending
    )
    transport.acknowledgementResponse = ProductSyncKeyRotationResponse(
      keyEpoch: 2,
      pendingDeviceCount: 1,
      state: .pending
    )
    let revokedDevice = TrustedDeviceSummary(
      displayName: "Old Mac",
      id: "device-revoked",
      lastSeenAt: 1,
      platform: "macos",
      registeredAt: 1
    )

    let response = try await ProductSyncKeyRotationCoordinator(
      keyMaterialStore: keyMaterialStore,
      transport: transport
    ).revoke(
      device: revokedDevice,
      session: session,
      recentIdentityToken: "recent-token",
      recoveryMaterial: recoveryMaterial
    )

    XCTAssertEqual(response.pendingDeviceCount, 1)
    XCTAssertEqual(transport.revokedTrustedDeviceId, revokedDevice.id)
    XCTAssertEqual(transport.revocationCallerTrustedDeviceId, session.trustedDeviceId)
    XCTAssertEqual(transport.expectedRecoveryUpdatedAt, recoveryMaterial.updatedAt)
    XCTAssertEqual(
      transport.recoveryWrappedAccountKey,
      authoritativeRotated.recoveryWrappedAccountKey
    )
    XCTAssertEqual(transport.acknowledgedKeyEpoch, 2)
    XCTAssertEqual(
      try keyMaterialStore.load(productAccountId: session.productAccountId),
      authoritativeRotated
    )
  }

  // swiftlint:disable:next function_body_length
  func testRevokeRemovesAnotherUnacknowledgedDeviceFromTheActiveRotation() async throws {
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let priorMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 13, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 14, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let currentMaterial = try priorMaterial.rotatingAccountKey(
      toVersion: 2,
      accountKeyData: Data(repeating: 15, count: ProductSyncKeyMaterial.keyByteCount)
    )
    try keyMaterialStore.save(currentMaterial, productAccountId: session.productAccountId)
    let transport = RecordingProductSyncKeyRotationTransport()
    transport.acknowledgementResponses = [
      2: ProductSyncKeyRotationResponse(
        keyEpoch: 2,
        pendingDeviceCount: 0,
        state: .complete
      ),
      3: ProductSyncKeyRotationResponse(
        keyEpoch: 3,
        pendingDeviceCount: 1,
        state: .pending
      ),
    ]
    transport.rotationStatus = ProductSyncKeyRotationStatus(
      encryptedTransition: try priorMaterial.encryptedTransition(
        to: currentMaterial,
        productAccountId: session.productAccountId
      ),
      keyEpoch: 2,
      pendingDeviceCount: 1
    )
    transport.revocationResponse = ProductSyncKeyRotationResponse(
      keyEpoch: 3,
      pendingDeviceCount: 1,
      state: .pending
    )
    let refreshedRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: currentMaterial.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 19
    )
    let recoveryTransport = RecordingAccountAndDevicesTransport()
    recoveryTransport.remoteRecoveryMaterial = refreshedRecoveryMaterial

    let response = try await ProductSyncKeyRotationCoordinator(
      keyMaterialStore: keyMaterialStore,
      transport: transport,
      recoveryTransport: recoveryTransport
    ).revoke(
      device: TrustedDeviceSummary(
        displayName: "Offline Mac",
        id: "device-offline",
        lastSeenAt: 1,
        platform: "macos",
        registeredAt: 1
      ),
      session: session,
      recentIdentityToken: "recent-token",
      recoveryMaterial: EncryptedProductSyncPayload(
        encryptedPayload: priorMaterial.recoveryWrappedAccountKey,
        payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
        updatedAt: 18
      )
    )

    XCTAssertEqual(response.keyEpoch, 3)
    XCTAssertEqual(response.state, .pending)
    XCTAssertEqual(transport.expectedRecoveryUpdatedAt, refreshedRecoveryMaterial.updatedAt)
    let rotatedMaterial = try XCTUnwrap(
      keyMaterialStore.load(productAccountId: session.productAccountId)
    )
    XCTAssertEqual(rotatedMaterial.accountKeyVersion, 3)
    XCTAssertEqual(
      transport.recoveryWrappedAccountKey,
      rotatedMaterial.recoveryWrappedAccountKey
    )
    XCTAssertEqual(transport.acknowledgedKeyEpoch, 3)
    XCTAssertEqual(transport.acknowledgedTrustedDeviceId, session.trustedDeviceId)
  }

  func testLoadListsCurrentDeviceFirstAndReportsMissingRecoveryBackup() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    transport.devices = [
      TrustedDeviceSummary(
        displayName: "Desk Mac",
        id: "device-other",
        lastSeenAt: 200,
        platform: "macos",
        registeredAt: 100
      ),
      TrustedDeviceSummary(
        displayName: "Jans iPhone",
        id: "device-current",
        lastSeenAt: 300,
        platform: "ios",
        registeredAt: 150
      ),
    ]
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )

    let snapshot = try await service.load(
      session: session,
      identityToken: "fresh-apple-token"
    )

    XCTAssertEqual(snapshot.devices.map(\.id), ["device-current", "device-other"])
    XCTAssertEqual(snapshot.recoveryKeyStatus, .notBackedUp)
    XCTAssertEqual(transport.listTrustedDeviceId, session.trustedDeviceId)
    XCTAssertEqual(transport.listIdentityToken, "fresh-apple-token")
    XCTAssertEqual(transport.recoveryReadIdentityToken, "fresh-apple-token")
  }

  // swiftlint:disable:next function_body_length
  func testLoadReportsRemoteRecoveryMismatchAfterReconcilingRotation() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    let rotationTransport = RecordingProductSyncKeyRotationTransport()
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let original = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 4, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 5, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let rotated = try original.rotatingAccountKey(
      toVersion: 2,
      accountKeyData: Data(repeating: 6, count: ProductSyncKeyMaterial.keyByteCount)
    )
    try keyMaterialStore.save(original, productAccountId: session.productAccountId)
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.saveUnacknowledgedRecoveryKey(
      UnacknowledgedRecoveryKey(
        recoveryKey: original.recoveryKey.rawValue,
        recoveryWrappedAccountKey: original.recoveryWrappedAccountKey
      ),
      productAccountId: session.productAccountId
    )
    rotationTransport.rotationStatus = ProductSyncKeyRotationStatus(
      encryptedTransition: try original.encryptedTransition(
        to: rotated,
        productAccountId: session.productAccountId
      ),
      keyEpoch: 2,
      pendingDeviceCount: 1
    )
    rotationTransport.acknowledgementResponse = ProductSyncKeyRotationResponse(
      keyEpoch: 2,
      pendingDeviceCount: 1,
      state: .pending
    )
    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: original.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: keyMaterialStore,
        recoveryTransport: transport,
        rotationTransport: rotationTransport,
        sessionStore: sessionStore
      )
    )

    await viewModel.load(session: session, recentIdentityToken: { "fresh-token" })

    XCTAssertEqual(viewModel.recoveryKeyStatus, .replacedOnAnotherDevice)
    XCTAssertTrue(viewModel.canRevokeTrustedDevices)
    XCTAssertEqual(
      try keyMaterialStore.load(productAccountId: session.productAccountId),
      rotated
    )
    XCTAssertEqual(
      try sessionStore.loadUnacknowledgedRecoveryKey(
        productAccountId: session.productAccountId
      )?.recoveryWrappedAccountKey,
      rotated.recoveryWrappedAccountKey
    )
  }

  // swiftlint:disable:next function_body_length
  func testCompletedRevocationRefreshesRecoveryStatus() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    let rotationTransport = RecordingProductSyncKeyRotationTransport()
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let material = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 7, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 8, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let rotated = try material.rotatingAccountKey(
      toVersion: material.accountKeyVersion + 1,
      accountKeyData: Data(repeating: 9, count: ProductSyncKeyMaterial.keyByteCount)
    )
    try keyMaterialStore.save(material, productAccountId: session.productAccountId)
    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: material.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    rotationTransport.rotationStatus = ProductSyncKeyRotationStatus(
      encryptedTransition: try material.encryptedTransition(
        to: rotated,
        productAccountId: session.productAccountId
      ),
      keyEpoch: rotated.accountKeyVersion,
      pendingDeviceCount: 1
    )
    rotationTransport.acknowledgementResponse = ProductSyncKeyRotationResponse(
      keyEpoch: rotated.accountKeyVersion,
      pendingDeviceCount: 1,
      state: .pending
    )
    rotationTransport.revocationResponse = ProductSyncKeyRotationResponse(
      keyEpoch: rotated.accountKeyVersion,
      pendingDeviceCount: 0,
      state: .complete
    )
    rotationTransport.persistRecoveryWrappedAccountKey = { encryptedPayload in
      transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
        encryptedPayload: encryptedPayload,
        payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
        updatedAt: 2
      )
    }
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: keyMaterialStore,
        recoveryTransport: transport,
        rotationTransport: rotationTransport
      )
    )
    await viewModel.load(session: session, recentIdentityToken: { "load-token" })

    await viewModel.revoke(
      TrustedDeviceSummary(
        displayName: "Old Mac",
        id: "device-other",
        lastSeenAt: 1,
        platform: "macos",
        registeredAt: 1
      ),
      session: session,
      recentIdentityToken: { "recent-token" }
    )
    await viewModel.load(session: session, recentIdentityToken: { "refresh-token" })

    XCTAssertEqual(viewModel.pendingKeyRotationDeviceCount, 0)
    XCTAssertEqual(viewModel.recoveryKeyStatus, .current)
    XCTAssertTrue(viewModel.canRevokeTrustedDevices)
  }

  func testRevocationReportsUnavailableRotationTransport() async {
    let transport = RecordingAccountAndDevicesTransport()
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      recoveryTransport: transport
    )

    do {
      _ = try await service.revokeDevice(
        TrustedDeviceSummary(
          displayName: "Old Mac",
          id: "device-other",
          lastSeenAt: 1,
          platform: "macos",
          registeredAt: 1
        ),
        session: session,
        recentIdentityToken: "recent-token"
      )
      XCTFail("Expected revocation without a rotation transport to fail")
    } catch {
      XCTAssertEqual(error as? AccountAndDevicesServiceError, .revocationUnavailable)
    }
  }

  func testCancelledRevocationDoesNotPresentAnError() async {
    let transport = RecordingAccountAndDevicesTransport()
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let material = try? keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    transport.remoteRecoveryMaterial = material.map {
      EncryptedProductSyncPayload(
        encryptedPayload: $0.recoveryWrappedAccountKey,
        payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
        updatedAt: 1
      )
    }
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: keyMaterialStore,
        recoveryTransport: transport
      )
    )
    await viewModel.load(session: session, recentIdentityToken: { "load-token" })

    await viewModel.revoke(
      TrustedDeviceSummary(
        displayName: "Old Mac",
        id: "device-other",
        lastSeenAt: 1,
        platform: "macos",
        registeredAt: 1
      ),
      session: session,
      recentIdentityToken: { throw CancellationError() }
    )

    XCTAssertNil(viewModel.errorMessage)
  }

  func testRevocationPurgesTheCurrentSessionWhenTheDeviceWasRevoked() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: material.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: keyMaterialStore,
        recoveryTransport: transport,
        rotationTransport: RecordingProductSyncKeyRotationTransport()
      )
    )
    var purgeCount = 0
    await viewModel.load(session: session, recentIdentityToken: { "recent-token" })
    transport.recoveryReadError = ConvexClientError.convexApplicationFailure(
      status: "error",
      code: "TRUSTED_DEVICE_REVOKED",
      message: nil
    )

    await viewModel.revoke(
      TrustedDeviceSummary(
        displayName: "Old Mac",
        id: "device-other",
        lastSeenAt: 1,
        platform: "macos",
        registeredAt: 1
      ),
      session: session,
      recentIdentityToken: { "recent-token" },
      trustedDeviceRevoked: { purgeCount += 1 }
    )

    XCTAssertEqual(purgeCount, 1)
    XCTAssertNil(viewModel.errorMessage)
  }

  func testRevocationRequiresCurrentRecoveryKeyBeforeCallingService() async {
    let transport = RecordingAccountAndDevicesTransport()
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
        recoveryTransport: transport
      )
    )
    var requestedAuthentication = false

    await viewModel.revoke(
      TrustedDeviceSummary(
        displayName: "Old Mac",
        id: "device-other",
        lastSeenAt: 1,
        platform: "macos",
        registeredAt: 1
      ),
      session: session,
      recentIdentityToken: {
        requestedAuthentication = true
        return "recent-token"
      }
    )

    XCTAssertEqual(
      viewModel.errorMessage,
      AccountAndDevicesServiceError.recoveryKeyUnavailableForRevocation.localizedDescription
    )
    XCTAssertFalse(requestedAuthentication)
  }

  func testLoadReusesActiveStoredAuthentication() async {
    let transport = RecordingAccountAndDevicesTransport()
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
        recoveryTransport: transport
      )
    )
    let activeSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: session.appleUserIdentifier,
      identityToken: session.identityToken,
      identityTokenExpiresAt: .distantFuture,
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )
    var didRefresh = false

    await viewModel.load(session: activeSession) {
      didRefresh = true
      return "fresh-token"
    }

    XCTAssertFalse(didRefresh)
    XCTAssertEqual(transport.listIdentityToken, "stored-token")
  }

  func testRevocationRequiresCurrentRecoveryMaterial() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: keyMaterialStore,
        recoveryTransport: transport
      )
    )

    await viewModel.load(session: session, recentIdentityToken: { "load-token" })
    XCTAssertFalse(viewModel.canRevokeTrustedDevices)

    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: material.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    await viewModel.load(session: session, recentIdentityToken: { "load-token" })

    XCTAssertTrue(viewModel.canRevokeTrustedDevices)
  }

  func testLoadRefreshesExpiredAuthentication() async {
    let transport = RecordingAccountAndDevicesTransport()
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
        recoveryTransport: transport
      )
    )
    let expiredSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: session.appleUserIdentifier,
      identityToken: session.identityToken,
      identityTokenExpiresAt: .distantPast,
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )

    await viewModel.load(session: expiredSession) { "fresh-token" }

    XCTAssertEqual(transport.listIdentityToken, "fresh-token")
  }

  func testLoadRefreshesUnverifiableAuthentication() async {
    let transport = RecordingAccountAndDevicesTransport()
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
        recoveryTransport: transport
      )
    )

    await viewModel.load(session: session) { "fresh-token" }

    XCTAssertEqual(transport.listIdentityToken, "fresh-token")
  }

  func testRenameRefreshesAuthenticationWhenTheMutationIsSubmitted() async {
    let transport = RecordingAccountAndDevicesTransport()
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      recoveryTransport: transport
    )
    let viewModel = AccountAndDevicesViewModel(service: service)
    let device = TrustedDeviceSummary(
      displayName: "Desk Mac",
      id: "device-current",
      lastSeenAt: 200,
      platform: "macos",
      registeredAt: 100
    )
    transport.devices = [device]

    await viewModel.load(session: session, recentIdentityToken: { "load-token" })

    await viewModel.rename(
      device,
      displayName: "Travel Mac",
      session: session,
      recentIdentityToken: { "fresh-rename-token" }
    )

    XCTAssertNil(viewModel.errorMessage)
    XCTAssertEqual(transport.renameIdentityToken, "fresh-rename-token")
    XCTAssertEqual(viewModel.devices.first?.displayName, "Travel Mac")
  }

  func testReplacingRecoveryKeyPublishesOnlyWrappedMaterialAfterRecentAuthentication()
    async throws
  {
    let transport = RecordingAccountAndDevicesTransport()
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let original = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )

    let recoveryKey = try await service.replaceRecoveryKey(
      session: session,
      recentIdentityToken: "fresh-apple-token"
    )

    let saved = try XCTUnwrap(
      keyMaterialStore.load(productAccountId: session.productAccountId)
    )
    XCTAssertEqual(saved.accountKeyData, original.accountKeyData)
    XCTAssertEqual(saved.recoveryKey, recoveryKey)
    XCTAssertNotEqual(saved.recoveryKey, original.recoveryKey)
    XCTAssertEqual(transport.recoveryWriteIdentityToken, "fresh-apple-token")
    XCTAssertEqual(
      transport.recoveryWritePayload,
      saved.recoveryWrappedAccountKey
    )
  }

  func testLoadRecognizesTheCurrentOpaqueRecoveryWrapper() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: material.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )

    let snapshot = try await service.load(session: session)

    XCTAssertEqual(snapshot.recoveryKeyStatus, .current)
  }

  func testCurrentRecoveryKeyCanBeRevealedAfterRecentAuthentication() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: material.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )

    let recoveryKey = try await service.revealCurrentRecoveryKey(
      session: session,
      recentIdentityToken: "fresh-apple-token"
    )

    XCTAssertEqual(recoveryKey, material.recoveryKey)
  }

  func testCurrentRecoveryKeyIsNotPresentedWhenMarkerPersistenceFails() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: material.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: keyMaterialStore,
        recoveryTransport: transport
      )
    )
    await viewModel.load(session: session, recentIdentityToken: { "load-token" })

    var markerPersistenceWasAttempted = false
    await viewModel.presentRecoveryKey(
      session: session,
      recentIdentityToken: { "reveal-token" },
      isSessionCurrent: { true },
      recoveryKeyPublished: { _ in
        markerPersistenceWasAttempted = true
        throw CocoaError(.fileWriteUnknown)
      }
    )

    XCTAssertTrue(markerPersistenceWasAttempted)
    XCTAssertNil(viewModel.revealedRecoveryKey)
    XCTAssertNotNil(viewModel.errorMessage)
  }

  func testCurrentRecoveryKeyRevealWaitsForConcurrentReplacement() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    let writeGate = RecoveryReplacementWriteGate()
    transport.recoveryWriteGate = writeGate
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let replacingService = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )
    let revealingService = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )

    let replacement = Task {
      try await replacingService.replaceRecoveryKey(
        session: session,
        recentIdentityToken: "replacement-token"
      )
    }
    await writeGate.waitUntilFirstWriteStarted()
    let reveal = Task {
      try await revealingService.revealCurrentRecoveryKey(
        session: session,
        recentIdentityToken: "reveal-token"
      )
    }
    await waitForRecoveryOperationWaiter(productAccountId: session.productAccountId)
    XCTAssertEqual(transport.recoveryReadCount, 1)

    await writeGate.releaseFirstWrite()
    let replacementKey = try await replacement.value
    let revealedKey = try await reveal.value
    XCTAssertEqual(revealedKey, replacementKey)
    XCTAssertEqual(transport.recoveryReadCount, 2)
  }

  func testAccountAndDevicesLoadWaitsForConcurrentReplacement() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    let writeGate = RecoveryReplacementWriteGate()
    transport.recoveryWriteGate = writeGate
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let replacingService = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )
    let loadingService = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )

    let replacement = Task {
      try await replacingService.replaceRecoveryKey(
        session: session,
        recentIdentityToken: "replacement-token"
      )
    }
    await writeGate.waitUntilFirstWriteStarted()
    let load = Task {
      try await loadingService.load(session: session, identityToken: "load-token")
    }
    await waitForRecoveryOperationWaiter(productAccountId: session.productAccountId)
    XCTAssertEqual(transport.recoveryReadCount, 1)

    await writeGate.releaseFirstWrite()
    _ = try await replacement.value
    let snapshot = try await load.value
    XCTAssertEqual(snapshot.recoveryKeyStatus, .current)
    XCTAssertEqual(transport.recoveryReadCount, 2)
  }

  func testCurrentRecoveryKeyCanBeExplicitlyReplaced() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: material.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: keyMaterialStore,
        recoveryTransport: transport
      )
    )
    await viewModel.load(session: session, recentIdentityToken: { "load-token" })

    var publishedRecoveryKey: String?
    var publishedBeforeRemoteWrite = false
    await viewModel.presentRecoveryKey(
      session: session,
      recentIdentityToken: { "replacement-token" },
      isSessionCurrent: { true },
      recoveryKeyPublished: {
        publishedRecoveryKey = $0
        publishedBeforeRemoteWrite = transport.recoveryWritePayload == nil
      },
      replacingCurrent: true
    )

    XCTAssertEqual(transport.recoveryWriteIdentityToken, "replacement-token")
    XCTAssertNil(viewModel.errorMessage)
    XCTAssertNotNil(viewModel.revealedRecoveryKey)
    XCTAssertEqual(publishedRecoveryKey, viewModel.revealedRecoveryKey)
    XCTAssertTrue(publishedBeforeRemoteWrite)
    XCTAssertEqual(viewModel.recoveryKeyStatus, .current)
    XCTAssertNotEqual(viewModel.revealedRecoveryKey, material.recoveryKey.rawValue)
  }

  func testRecoveryReplacementStopsWhenAcknowledgementPersistenceFails() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: keyMaterialStore,
        recoveryTransport: transport
      )
    )

    await viewModel.presentRecoveryKey(
      session: session,
      recentIdentityToken: { "replacement-token" },
      isSessionCurrent: { true },
      recoveryKeyPublished: { _ in throw CocoaError(.fileWriteUnknown) },
      replacingCurrent: true
    )

    XCTAssertNil(viewModel.revealedRecoveryKey)
    XCTAssertNotNil(viewModel.errorMessage)
    XCTAssertNil(transport.recoveryWritePayload)
  }

  func testPreservedRecoveryKeyIsNotPresentedAfterRemoteReplacement() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let replacement = try ProductSyncKeyMaterial.create()
    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: replacement.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: keyMaterialStore,
        recoveryTransport: transport
      )
    )
    await viewModel.load(session: session, recentIdentityToken: { "load-token" })

    viewModel.presentPreservedRecoveryKey("obsolete-key")

    XCTAssertEqual(viewModel.recoveryKeyStatus, .replacedOnAnotherDevice)
    XCTAssertNil(viewModel.revealedRecoveryKey)
  }

  func testRecoveryKeyAcknowledgementFailureUsesAccountAndDevicesError() {
    let viewModel = AccountAndDevicesViewModel()

    let acknowledged = viewModel.acknowledgeRecoveryKey {
      throw CocoaError(.fileWriteUnknown)
    }

    XCTAssertFalse(acknowledged)
    XCTAssertNotNil(viewModel.errorMessage)
  }

  func testConcurrentRecoveryReplacementDoesNotOverwriteLocalMaterial() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    transport.simulatesConcurrentRecoveryWrite = true
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let original = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )
    var publishedRecoveryKey: String?
    var rejectedRecoveryKey: String?

    do {
      _ = try await service.replaceRecoveryKey(
        session: session,
        recentIdentityToken: "fresh-apple-token",
        recoveryKeyPublished: { publishedRecoveryKey = $0 },
        recoveryKeyRejected: { rejectedRecoveryKey = $0 }
      )
      XCTFail("Expected concurrent replacement to fail")
    } catch {
      XCTAssertEqual(error as? AccountAndDevicesServiceError, .recoveryMaterialChanged)
    }

    XCTAssertEqual(
      try keyMaterialStore.load(productAccountId: session.productAccountId),
      original
    )
    XCTAssertEqual(rejectedRecoveryKey, publishedRecoveryKey)
    XCTAssertEqual(transport.recoveryReadCount, 1)
  }

  func testRejectedRecoveryKeyCleanupFailureIsSurfaced() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    transport.simulatesConcurrentRecoveryWrite = true
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let original = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: keyMaterialStore,
        recoveryTransport: transport
      )
    )

    var rejectedRecoveryKeyWasHandled = false
    await viewModel.presentRecoveryKey(
      session: session,
      recentIdentityToken: { "fresh-apple-token" },
      isSessionCurrent: { true },
      recoveryKeyRejected: { _ in
        rejectedRecoveryKeyWasHandled = true
        throw CocoaError(.fileWriteUnknown)
      },
      replacingCurrent: true
    )

    XCTAssertTrue(rejectedRecoveryKeyWasHandled)
    XCTAssertNotNil(viewModel.errorMessage)
    XCTAssertNil(viewModel.revealedRecoveryKey)
    XCTAssertEqual(
      try keyMaterialStore.load(productAccountId: session.productAccountId),
      original
    )
  }

  func testRecoveryReplacementSerializesAcrossServiceInstancesForOneAccount() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    let writeGate = RecoveryReplacementWriteGate()
    transport.recoveryWriteGate = writeGate
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let firstService = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )
    let secondService = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )

    var retainedRecoveryKeys: [String] = []
    let firstReplacement = Task {
      try await firstService.replaceRecoveryKey(
        session: session,
        recentIdentityToken: "first-token",
        recoveryKeyPublished: { retainedRecoveryKeys.append($0) }
      )
    }
    await writeGate.waitUntilFirstWriteStarted()
    let secondStarted = expectation(description: "second replacement requested")
    let secondReplacement = Task {
      secondStarted.fulfill()
      return try await secondService.replaceRecoveryKey(
        session: session,
        recentIdentityToken: "second-token",
        recoveryKeyPublished: { retainedRecoveryKeys.append($0) }
      )
    }

    await fulfillment(of: [secondStarted], timeout: 1)
    await waitForRecoveryOperationWaiter(productAccountId: session.productAccountId)
    XCTAssertEqual(transport.recoveryReadCount, 1)

    await writeGate.releaseFirstWrite()
    let firstRecoveryKey = try await firstReplacement.value
    let secondRecoveryKey = try await secondReplacement.value
    let saved = try XCTUnwrap(
      keyMaterialStore.load(productAccountId: session.productAccountId)
    )

    XCTAssertNotEqual(firstRecoveryKey, secondRecoveryKey)
    XCTAssertEqual(saved.recoveryKey, secondRecoveryKey)
    XCTAssertEqual(retainedRecoveryKeys, [firstRecoveryKey.rawValue, secondRecoveryKey.rawValue])
    XCTAssertEqual(transport.recoveryReadCount, 2)
  }

  func testOfflineRecoveryReplacementRestoresMaterialWhenBackendDidNotCommit()
    async throws
  {
    let transport = RecordingAccountAndDevicesTransport()
    transport.recoveryWriteError = AccountAndDevicesTransportError.offline
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let original = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: original.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )

    do {
      _ = try await service.replaceRecoveryKey(
        session: session,
        recentIdentityToken: "fresh-apple-token"
      )
      XCTFail("Expected offline replacement to fail")
    } catch {
      XCTAssertTrue(error is AccountAndDevicesTransportError)
    }

    XCTAssertEqual(
      try keyMaterialStore.load(productAccountId: session.productAccountId),
      original
    )
  }

  func testRecoveryReplacementPropagatesTrustedDeviceRevocation() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    transport.recoveryWriteError = ConvexClientError.convexApplicationFailure(
      status: "error",
      code: "TRUSTED_DEVICE_REVOKED",
      message: nil
    )
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let original = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: original.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )
    var rejectedRecoveryKey: String?

    do {
      _ = try await service.replaceRecoveryKey(
        session: session,
        recentIdentityToken: "fresh-apple-token",
        recoveryKeyRejected: { rejectedRecoveryKey = $0 }
      )
      XCTFail("Expected trusted-device revocation")
    } catch let error as ProductAccountServiceError {
      XCTAssertEqual(error, .trustedDeviceRevoked)
    }

    XCTAssertNotNil(rejectedRecoveryKey)
    XCTAssertEqual(transport.recoveryReadCount, 1)
    XCTAssertEqual(
      try keyMaterialStore.load(productAccountId: session.productAccountId),
      original
    )
  }

  func testRecoveryReplacementPropagatesRevocationFromTheReconciliationRead() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    transport.recoveryWriteError = AccountAndDevicesTransportError.offline
    transport.recoveryReadErrorOnCall = 2
    transport.recoveryReadErrorOnCallValue = ConvexClientError.convexApplicationFailure(
      status: "error",
      code: "TRUSTED_DEVICE_REVOKED",
      message: nil
    )
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let original = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: original.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )
    var rejectedRecoveryKey: String?

    do {
      _ = try await service.replaceRecoveryKey(
        session: session,
        recentIdentityToken: "fresh-apple-token",
        recoveryKeyRejected: { rejectedRecoveryKey = $0 }
      )
      XCTFail("Expected trusted-device revocation")
    } catch let error as ProductAccountServiceError {
      XCTAssertEqual(error, .trustedDeviceRevoked)
    }

    XCTAssertNotNil(rejectedRecoveryKey)
    XCTAssertEqual(transport.recoveryReadCount, 2)
    XCTAssertEqual(
      try keyMaterialStore.load(productAccountId: session.productAccountId),
      original
    )
  }

  func testResponseLostAfterRecoveryCommitStillReturnsCommittedKey() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    transport.recoveryWriteError = AccountAndDevicesTransportError.offline
    transport.commitsRecoveryBeforeThrowing = true
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let original = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: original.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )

    let recoveryKey = try await service.replaceRecoveryKey(
      session: session,
      recentIdentityToken: "fresh-apple-token"
    )

    let saved = try XCTUnwrap(
      keyMaterialStore.load(productAccountId: session.productAccountId)
    )
    XCTAssertEqual(saved.recoveryKey, recoveryKey)
    XCTAssertEqual(
      transport.remoteRecoveryMaterial?.encryptedPayload,
      saved.recoveryWrappedAccountKey
    )
  }

  func testResponseAndReconciliationLostStillRevealsRetainedRecoveryKey() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    transport.recoveryWriteError = AccountAndDevicesTransportError.offline
    transport.recoveryReadErrorOnCall = 2
    transport.commitsRecoveryBeforeThrowing = true
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let original = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: original.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )

    let recoveryKey = try await service.replaceRecoveryKey(
      session: session,
      recentIdentityToken: "fresh-apple-token"
    )

    let saved = try XCTUnwrap(
      keyMaterialStore.load(productAccountId: session.productAccountId)
    )
    XCTAssertEqual(saved.recoveryKey, recoveryKey)
    XCTAssertEqual(
      transport.remoteRecoveryMaterial?.encryptedPayload,
      saved.recoveryWrappedAccountKey
    )
  }

  func testRecoveryReplacementDoesNotRestoreKeysAfterSignOut() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport
    )
    var sessionCheckCount = 0

    do {
      _ = try await service.replaceRecoveryKey(
        session: session,
        recentIdentityToken: "fresh-apple-token",
        isSessionCurrent: {
          sessionCheckCount += 1
          if sessionCheckCount > 1 {
            try? keyMaterialStore.clear(productAccountId: session.productAccountId)
            return false
          }
          return true
        }
      )
      XCTFail("Expected signed-out recovery replacement to cancel")
    } catch is CancellationError {
    }

    XCTAssertNil(
      try keyMaterialStore.load(productAccountId: session.productAccountId)
    )
  }
}

private enum AccountAndDevicesTransportError: Error {
  case offline
}

private final class RecordingProductSyncKeyRotationTransport:
  ProductSyncKeyRotationTransporting
{
  var acknowledgementResponse = ProductSyncKeyRotationResponse(
    keyEpoch: 2,
    pendingDeviceCount: 0,
    state: .complete
  )
  var acknowledgementResponses: [Int: ProductSyncKeyRotationResponse] = [:]
  var acknowledgedKeyEpoch: Int?
  var acknowledgedTrustedDeviceId: String?
  var expectedRecoveryUpdatedAt: Int64?
  var recoveryWrappedAccountKey: ProductSyncEncryptedPayload?
  var persistRecoveryWrappedAccountKey: ((ProductSyncEncryptedPayload) -> Void)?
  var revocationCallerTrustedDeviceId: String?
  var revokedTrustedDeviceId: String?
  var revocationResponse = ProductSyncKeyRotationResponse(
    keyEpoch: 2,
    pendingDeviceCount: 1,
    state: .pending
  )
  var rotationStatus: ProductSyncKeyRotationStatus?

  // swiftlint:disable:next function_parameter_count
  func revokeTrustedDevice(
    encryptedTransition: ProductSyncEncryptedPayload,
    expectedRecoveryUpdatedAt: Int64,
    identityToken _: String,
    recoveryWrappedAccountKey: ProductSyncEncryptedPayload,
    trustedDeviceId: String,
    trustedDeviceToRevokeId: String
  ) async throws -> ProductSyncKeyRotationResponse {
    self.expectedRecoveryUpdatedAt = expectedRecoveryUpdatedAt
    self.recoveryWrappedAccountKey = recoveryWrappedAccountKey
    revocationCallerTrustedDeviceId = trustedDeviceId
    revokedTrustedDeviceId = trustedDeviceToRevokeId
    persistRecoveryWrappedAccountKey?(recoveryWrappedAccountKey)
    if rotationStatus == nil {
      rotationStatus = ProductSyncKeyRotationStatus(
        encryptedTransition: encryptedTransition,
        keyEpoch: revocationResponse.keyEpoch,
        pendingDeviceCount: revocationResponse.pendingDeviceCount
      )
    }
    if revocationResponse.state == .complete {
      rotationStatus = nil
    }
    return revocationResponse
  }

  func productSyncKeyRotation(
    identityToken _: String,
    trustedDeviceId _: String
  ) async throws -> ProductSyncKeyRotationStatus? {
    rotationStatus
  }

  func acknowledgeProductSyncKeyRotation(
    identityToken _: String,
    keyEpoch: Int,
    trustedDeviceId: String
  ) async throws -> ProductSyncKeyRotationResponse {
    acknowledgedKeyEpoch = keyEpoch
    acknowledgedTrustedDeviceId = trustedDeviceId
    let response = acknowledgementResponses[keyEpoch] ?? acknowledgementResponse
    if response.state == .complete {
      rotationStatus = nil
    }
    return response
  }
}

private final class RecordingAccountAndDevicesTransport:
  TrustedDeviceManaging, RecoveryMaterialTransporting
{
  var devices: [TrustedDeviceSummary] = []
  var listIdentityToken: String?
  var listTrustedDeviceId: String?
  var remoteRecoveryMaterial: EncryptedProductSyncPayload?
  var recoveryWriteIdentityToken: String?
  var recoveryWritePayload: ProductSyncEncryptedPayload?
  var recoveryWriteError: Error?
  var recoveryWriteGate: RecoveryReplacementWriteGate?
  var recoveryReadCount = 0
  var recoveryReadErrorOnCall: Int?
  var recoveryReadErrorOnCallValue: Error?
  var recoveryReadError: Error?
  var recoveryReadIdentityToken: String?
  var renameIdentityToken: String?
  var commitsRecoveryBeforeThrowing = false
  var simulatesConcurrentRecoveryWrite = false

  func listTrustedDevices(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> [TrustedDeviceSummary] {
    listIdentityToken = identityToken
    listTrustedDeviceId = trustedDeviceId
    return devices
  }

  func renameTrustedDevice(
    displayName: String,
    identityToken: String,
    trustedDeviceId _: String,
    trustedDeviceToRenameId: String
  ) async throws -> TrustedDeviceSummary {
    renameIdentityToken = identityToken
    return TrustedDeviceSummary(
      displayName: displayName,
      id: trustedDeviceToRenameId,
      lastSeenAt: 200,
      platform: "macos",
      registeredAt: 100
    )
  }

  func getRecoveryMaterial(
    identityToken: String,
    payloadIdentifier _: String,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload? {
    recoveryReadIdentityToken = identityToken
    recoveryReadCount += 1
    if let recoveryReadError { throw recoveryReadError }
    if recoveryReadCount == recoveryReadErrorOnCall {
      throw recoveryReadErrorOnCallValue ?? AccountAndDevicesTransportError.offline
    }
    return remoteRecoveryMaterial
  }

  func putRecoveryMaterialIfUnchanged(
    identityToken: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId _: String,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    await recoveryWriteGate?.waitForReleaseIfFirstWrite()
    recoveryWriteIdentityToken = identityToken
    recoveryWritePayload = encryptedPayload
    if commitsRecoveryBeforeThrowing {
      remoteRecoveryMaterial = EncryptedProductSyncPayload(
        encryptedPayload: encryptedPayload,
        payloadIdentifier: payloadIdentifier,
        updatedAt: 2
      )
    }
    if let recoveryWriteError {
      throw recoveryWriteError
    }
    let storedPayload =
      simulatesConcurrentRecoveryWrite
      ? ProductSyncEncryptedPayload(
        algorithm: ProductSyncEncryptedPayload.algorithmName,
        ciphertextBase64: "concurrent",
        keyVersion: 1,
        nonceBase64: "concurrent",
        schemaVersion: 1,
        tagBase64: "concurrent"
      ) : encryptedPayload
    let stored = EncryptedProductSyncPayload(
      encryptedPayload: storedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: 1
    )
    remoteRecoveryMaterial = stored
    return stored
  }
}

private actor RecoveryReplacementWriteGate {
  private var firstWriteStarted = false
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var startContinuations: [CheckedContinuation<Void, Never>] = []
  private var writeCount = 0

  func waitForReleaseIfFirstWrite() async {
    writeCount += 1
    guard writeCount == 1 else { return }
    firstWriteStarted = true
    let continuations = startContinuations
    startContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
    await withCheckedContinuation { releaseContinuation = $0 }
  }

  func waitUntilFirstWriteStarted() async {
    guard !firstWriteStarted else { return }
    await withCheckedContinuation { startContinuations.append($0) }
  }

  func releaseFirstWrite() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
