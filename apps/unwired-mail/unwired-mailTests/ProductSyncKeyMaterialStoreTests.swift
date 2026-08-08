import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

@Suite(.serialized)
final class ProductSyncKeyMaterialStoreTests {
  private var store = InMemoryProductSyncKeyMaterialStore()

  init() {
    store = InMemoryProductSyncKeyMaterialStore()
  }

  @Test
  func testEnsureMaterialCreatesAndReusesLocalMaterialForProductAccount() throws {
    let firstMaterial = try store.ensureMaterial(
      productAccountId: "productAccountFixtureId",
      allowCreation: true
    )
    let secondMaterial = try store.ensureMaterial(
      productAccountId: "productAccountFixtureId",
      allowCreation: false
    )

    #expect(secondMaterial == firstMaterial)
    #expect(store.saveCount == 2)
  }

  @Test
  func testEnsureMaterialRequiresRecoveryWhenCreationIsNotAllowed() {
    #expect {
      try store.ensureMaterial(
        productAccountId: "productAccountFixtureId",
        allowCreation: false
      )
    } throws: { error in
      #expect(error as? ProductSyncKeyMaterialStoreError == .recoveryRequired)
      return true
    }
  }

  @Test
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

    #expect(restoredMaterial.accountKeyData == originalMaterial.accountKeyData)
    #expect(try store.load(productAccountId: "productAccountFixtureId") == restoredMaterial)
  }

  @Test
  func testReplacingRecoveryKeyPreservesTheProductSyncAccountKey() throws {
    let originalMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 9, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 10, count: ProductSyncKeyMaterial.keyByteCount)
    )

    let replacement = try originalMaterial.replacingRecoveryKey(
      with: Data(repeating: 11, count: ProductSyncKeyMaterial.keyByteCount)
    )

    #expect(replacement.accountKeyData == originalMaterial.accountKeyData)
    #expect(replacement.recoveryKey != originalMaterial.recoveryKey)
    #expect(
      try ProductSyncKeyMaterial.restore(
        recoveryKey: replacement.recoveryKey,
        recoveryWrappedAccountKey: replacement.recoveryWrappedAccountKey
      ).accountKeyData == originalMaterial.accountKeyData)
  }
}

@MainActor
@Suite(.serialized)
final class AccountAndDevicesServiceTests {
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

  @Test
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

    #expect(response?.pendingDeviceCount == 1)
    #expect(try keyMaterialStore.load(productAccountId: session.productAccountId) == rotated)
    #expect(transport.acknowledgedKeyEpoch == 2)
    #expect(transport.acknowledgedTrustedDeviceId == session.trustedDeviceId)
  }

  @Test
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

    #expect(
      try sessionStore.loadUnacknowledgedRecoveryKey(
        productAccountId: session.productAccountId
      )?.recoveryWrappedAccountKey == rotated.recoveryWrappedAccountKey)
    #expect(transport.acknowledgedKeyEpoch == 2)
  }

  @Test
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

    #expect(response.pendingDeviceCount == 1)
    #expect(transport.revokedTrustedDeviceId == revokedDevice.id)
    #expect(transport.revocationCallerTrustedDeviceId == session.trustedDeviceId)
    #expect(transport.expectedRecoveryUpdatedAt == recoveryMaterial.updatedAt)
    #expect(transport.recoveryWrappedAccountKey == authoritativeRotated.recoveryWrappedAccountKey)
    #expect(transport.acknowledgedKeyEpoch == 2)
    #expect(
      try keyMaterialStore.load(productAccountId: session.productAccountId) == authoritativeRotated)
  }

  @Test
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

    #expect(response.keyEpoch == 3)
    #expect(response.state == .pending)
    #expect(transport.expectedRecoveryUpdatedAt == refreshedRecoveryMaterial.updatedAt)
    let rotatedMaterial = try requireValue(
      try keyMaterialStore.load(productAccountId: session.productAccountId))
    #expect(rotatedMaterial.accountKeyVersion == 3)
    #expect(transport.recoveryWrappedAccountKey == rotatedMaterial.recoveryWrappedAccountKey)
    #expect(transport.acknowledgedKeyEpoch == 3)
    #expect(transport.acknowledgedTrustedDeviceId == session.trustedDeviceId)
  }

  @Test
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

    #expect(snapshot.devices.map(\.id) == ["device-current", "device-other"])
    #expect(snapshot.recoveryKeyStatus == .notBackedUp)
    #expect(transport.listTrustedDeviceId == session.trustedDeviceId)
    #expect(transport.listIdentityToken == "fresh-apple-token")
    #expect(transport.recoveryReadIdentityToken == "fresh-apple-token")
  }

  @Test
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

    #expect(viewModel.recoveryKeyStatus == .replacedOnAnotherDevice)
    #expect(viewModel.canRevokeTrustedDevices)
    #expect(try keyMaterialStore.load(productAccountId: session.productAccountId) == rotated)
    #expect(
      try sessionStore.loadUnacknowledgedRecoveryKey(
        productAccountId: session.productAccountId
      )?.recoveryWrappedAccountKey == rotated.recoveryWrappedAccountKey)
  }

  @Test
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

    #expect(viewModel.pendingKeyRotationDeviceCount == 0)
    #expect(viewModel.recoveryKeyStatus == .current)
    #expect(viewModel.canRevokeTrustedDevices)
  }

  @Test
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
      Issue.record("Expected revocation without a rotation transport to fail")
    } catch {
      #expect(error as? AccountAndDevicesServiceError == .revocationUnavailable)
    }
  }

  @Test
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

    #expect(viewModel.errorMessage == nil)
  }

  @Test
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

    #expect(purgeCount == 1)
    #expect(viewModel.errorMessage == nil)
  }

  @Test
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

    #expect(
      viewModel.errorMessage
        == AccountAndDevicesServiceError.recoveryKeyUnavailableForRevocation.localizedDescription)
    #expect(!(requestedAuthentication))
  }

  @Test
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

    #expect(!(didRefresh))
    #expect(transport.listIdentityToken == "stored-token")
  }

  @Test
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
    #expect(!(viewModel.canRevokeTrustedDevices))

    transport.remoteRecoveryMaterial = EncryptedProductSyncPayload(
      encryptedPayload: material.recoveryWrappedAccountKey,
      payloadIdentifier: AccountAndDevicesService.recoveryPayloadIdentifier,
      updatedAt: 1
    )
    await viewModel.load(session: session, recentIdentityToken: { "load-token" })

    #expect(viewModel.canRevokeTrustedDevices)
  }

  @Test
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

    #expect(transport.listIdentityToken == "fresh-token")
  }

  @Test
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

    #expect(transport.listIdentityToken == "fresh-token")
  }

  @Test
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

    #expect(viewModel.errorMessage == nil)
    #expect(transport.renameIdentityToken == "fresh-rename-token")
    #expect(viewModel.devices.first?.displayName == "Travel Mac")
  }

  @Test
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

    let saved = try requireValue(
      try keyMaterialStore.load(productAccountId: session.productAccountId))
    #expect(saved.accountKeyData == original.accountKeyData)
    #expect(saved.recoveryKey == recoveryKey)
    #expect(saved.recoveryKey != original.recoveryKey)
    #expect(transport.recoveryWriteIdentityToken == "fresh-apple-token")
    #expect(transport.recoveryWritePayload == saved.recoveryWrappedAccountKey)
  }

  @Test
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

    #expect(snapshot.recoveryKeyStatus == .current)
  }

  @Test
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

    #expect(recoveryKey == material.recoveryKey)
  }

  @Test
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

    #expect(markerPersistenceWasAttempted)
    #expect(viewModel.revealedRecoveryKey == nil)
    #expect(viewModel.errorMessage != nil)
  }

  @Test
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
    #expect(transport.recoveryReadCount == 1)

    await writeGate.releaseFirstWrite()
    let replacementKey = try await replacement.value
    let revealedKey = try await reveal.value
    #expect(revealedKey == replacementKey)
    #expect(transport.recoveryReadCount == 2)
  }

  @Test
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
    #expect(transport.recoveryReadCount == 1)

    await writeGate.releaseFirstWrite()
    _ = try await replacement.value
    let snapshot = try await load.value
    #expect(snapshot.recoveryKeyStatus == .current)
    #expect(transport.recoveryReadCount == 2)
  }

  @Test
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

    #expect(transport.recoveryWriteIdentityToken == "replacement-token")
    #expect(viewModel.errorMessage == nil)
    #expect(viewModel.revealedRecoveryKey != nil)
    #expect(publishedRecoveryKey == viewModel.revealedRecoveryKey)
    #expect(publishedBeforeRemoteWrite)
    #expect(viewModel.recoveryKeyStatus == .current)
    #expect(viewModel.revealedRecoveryKey != material.recoveryKey.rawValue)
  }

  @Test
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

    #expect(viewModel.revealedRecoveryKey == nil)
    #expect(viewModel.errorMessage != nil)
    #expect(transport.recoveryWritePayload == nil)
  }

  @Test
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

    #expect(viewModel.recoveryKeyStatus == .replacedOnAnotherDevice)
    #expect(viewModel.revealedRecoveryKey == nil)
  }

  @Test
  func testRecoveryKeyAcknowledgementFailureUsesAccountAndDevicesError() {
    let viewModel = AccountAndDevicesViewModel()

    let acknowledged = viewModel.acknowledgeRecoveryKey {
      throw CocoaError(.fileWriteUnknown)
    }

    #expect(!(acknowledged))
    #expect(viewModel.errorMessage != nil)
  }

  @Test
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
      Issue.record("Expected concurrent replacement to fail")
    } catch {
      #expect(error as? AccountAndDevicesServiceError == .recoveryMaterialChanged)
    }

    #expect(try keyMaterialStore.load(productAccountId: session.productAccountId) == original)
    #expect(rejectedRecoveryKey == publishedRecoveryKey)
    #expect(transport.recoveryReadCount == 1)
  }

  @Test
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

    #expect(rejectedRecoveryKeyWasHandled)
    #expect(viewModel.errorMessage != nil)
    #expect(viewModel.revealedRecoveryKey == nil)
    #expect(try keyMaterialStore.load(productAccountId: session.productAccountId) == original)
  }

  @Test
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
    #expect(transport.recoveryReadCount == 1)

    await writeGate.releaseFirstWrite()
    let firstRecoveryKey = try await firstReplacement.value
    let secondRecoveryKey = try await secondReplacement.value
    let saved = try requireValue(
      try keyMaterialStore.load(productAccountId: session.productAccountId))

    #expect(firstRecoveryKey != secondRecoveryKey)
    #expect(saved.recoveryKey == secondRecoveryKey)
    #expect(retainedRecoveryKeys == [firstRecoveryKey.rawValue, secondRecoveryKey.rawValue])
    #expect(transport.recoveryReadCount == 2)
  }

  @Test
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
      Issue.record("Expected offline replacement to fail")
    } catch {
      #expect(error is AccountAndDevicesTransportError)
    }

    #expect(try keyMaterialStore.load(productAccountId: session.productAccountId) == original)
  }

  @Test
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
      Issue.record("Expected trusted-device revocation")
    } catch let error as ProductAccountServiceError {
      #expect(error == .trustedDeviceRevoked)
    }

    #expect(rejectedRecoveryKey != nil)
    #expect(transport.recoveryReadCount == 1)
    #expect(try keyMaterialStore.load(productAccountId: session.productAccountId) == original)
  }

  @Test
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
      Issue.record("Expected trusted-device revocation")
    } catch let error as ProductAccountServiceError {
      #expect(error == .trustedDeviceRevoked)
    }

    #expect(rejectedRecoveryKey != nil)
    #expect(transport.recoveryReadCount == 2)
    #expect(try keyMaterialStore.load(productAccountId: session.productAccountId) == original)
  }

  @Test
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

    let saved = try requireValue(
      try keyMaterialStore.load(productAccountId: session.productAccountId))
    #expect(saved.recoveryKey == recoveryKey)
    #expect(transport.remoteRecoveryMaterial?.encryptedPayload == saved.recoveryWrappedAccountKey)
  }

  @Test
  func testResponseAndReconciliationLossDoesNotPresentUnverifiedRecoveryKey() async throws {
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
    let viewModel = AccountAndDevicesViewModel(
      service: AccountAndDevicesService(
        deviceTransport: transport,
        keyMaterialStore: keyMaterialStore,
        recoveryTransport: transport
      )
    )
    var publishedRecoveryKey: String?

    await viewModel.presentRecoveryKey(
      session: session,
      recentIdentityToken: { "fresh-apple-token" },
      isSessionCurrent: { true },
      recoveryKeyPublished: { publishedRecoveryKey = $0 },
      replacingCurrent: true
    )

    let saved = try requireValue(
      try keyMaterialStore.load(productAccountId: session.productAccountId))
    #expect(publishedRecoveryKey != nil)
    #expect(saved.recoveryKey.rawValue == publishedRecoveryKey)
    #expect(transport.remoteRecoveryMaterial?.encryptedPayload == saved.recoveryWrappedAccountKey)
    #expect(viewModel.recoveryKeyStatus == .unverified)
    #expect(viewModel.revealedRecoveryKey == nil)
    #expect(viewModel.errorMessage == nil)
  }

  @Test
  func testLaterAuthoritativeCommitMakesUnverifiedRecoveryKeyCurrent() async throws {
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
    let sessionStore = InMemoryProductAccountSessionStore()
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport,
      sessionStore: sessionStore
    )

    do {
      _ = try await service.replaceRecoveryKey(
        session: session,
        recentIdentityToken: "fresh-apple-token",
        recoveryKeyPublished: { recoveryKey in
          let replacement = try requireValue(
            try keyMaterialStore.load(productAccountId: session.productAccountId))
          try sessionStore.saveUnacknowledgedRecoveryKey(
            UnacknowledgedRecoveryKey(
              recoveryKey: recoveryKey,
              recoveryWrappedAccountKey: replacement.recoveryWrappedAccountKey
            ),
            productAccountId: session.productAccountId
          )
        }
      )
      Issue.record("Expected replacement verification to remain pending")
    } catch {
      #expect(error as? AccountAndDevicesServiceError == .recoveryMaterialUnverified)
    }

    transport.recoveryReadErrorOnCall = nil
    let snapshot = try await service.load(session: session)

    #expect(snapshot.recoveryKeyStatus == .current)
    #expect(
      try sessionStore.loadUnacknowledgedRecoveryKey(
        productAccountId: session.productAccountId
      ) != nil)
  }

  @Test
  func testLaterAuthoritativeRejectionClearsUnverifiedRecoveryKeyMarker() async throws {
    let transport = RecordingAccountAndDevicesTransport()
    transport.recoveryWriteError = AccountAndDevicesTransportError.offline
    transport.recoveryReadErrorOnCall = 2
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
    let sessionStore = InMemoryProductAccountSessionStore()
    var reconciledProductAccountId: String?
    let service = AccountAndDevicesService(
      deviceTransport: transport,
      keyMaterialStore: keyMaterialStore,
      recoveryTransport: transport,
      sessionStore: sessionStore,
      recoveryMarkerCleared: { reconciledProductAccountId = $0 }
    )

    do {
      _ = try await service.replaceRecoveryKey(
        session: session,
        recentIdentityToken: "fresh-apple-token",
        recoveryKeyPublished: { recoveryKey in
          let replacement = try requireValue(
            try keyMaterialStore.load(productAccountId: session.productAccountId))
          try sessionStore.saveUnacknowledgedRecoveryKey(
            UnacknowledgedRecoveryKey(
              recoveryKey: recoveryKey,
              recoveryWrappedAccountKey: replacement.recoveryWrappedAccountKey
            ),
            productAccountId: session.productAccountId
          )
        }
      )
      Issue.record("Expected replacement verification to remain pending")
    } catch {
      #expect(error as? AccountAndDevicesServiceError == .recoveryMaterialUnverified)
    }

    transport.recoveryReadErrorOnCall = nil
    let snapshot = try await service.load(session: session)

    #expect(snapshot.recoveryKeyStatus == .replacedOnAnotherDevice)
    #expect(
      try sessionStore.loadUnacknowledgedRecoveryKey(
        productAccountId: session.productAccountId
      ) == nil)
    #expect(reconciledProductAccountId == session.productAccountId)
  }

  @Test
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
      Issue.record("Expected signed-out recovery replacement to cancel")
    } catch is CancellationError {
    }

    #expect(try keyMaterialStore.load(productAccountId: session.productAccountId) == nil)
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
