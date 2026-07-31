import Foundation
import XCTest

@testable import unwired_mail

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
    productAccountId: "product-account-001",
    trustedDeviceId: "device-current"
  )

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

    let snapshot = try await service.load(session: session)

    XCTAssertEqual(snapshot.devices.map(\.id), ["device-current", "device-other"])
    XCTAssertEqual(snapshot.recoveryKeyStatus, .notBackedUp)
    XCTAssertEqual(transport.listTrustedDeviceId, session.trustedDeviceId)
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

    do {
      _ = try await service.replaceRecoveryKey(
        session: session,
        recentIdentityToken: "fresh-apple-token"
      )
      XCTFail("Expected concurrent replacement to fail")
    } catch {
      XCTAssertEqual(error as? AccountAndDevicesServiceError, .recoveryMaterialChanged)
    }

    XCTAssertEqual(
      try keyMaterialStore.load(productAccountId: session.productAccountId),
      original
    )
  }
}

private final class RecordingAccountAndDevicesTransport:
  TrustedDeviceManaging, RecoveryMaterialTransporting
{
  var devices: [TrustedDeviceSummary] = []
  var listTrustedDeviceId: String?
  var remoteRecoveryMaterial: EncryptedProductSyncPayload?
  var recoveryWriteIdentityToken: String?
  var recoveryWritePayload: ProductSyncEncryptedPayload?
  var simulatesConcurrentRecoveryWrite = false

  func listTrustedDevices(
    identityToken _: String,
    trustedDeviceId: String
  ) async throws -> [TrustedDeviceSummary] {
    listTrustedDeviceId = trustedDeviceId
    return devices
  }

  func renameTrustedDevice(
    displayName: String,
    identityToken _: String,
    trustedDeviceId _: String,
    trustedDeviceToRenameId: String
  ) async throws -> TrustedDeviceSummary {
    TrustedDeviceSummary(
      displayName: displayName,
      id: trustedDeviceToRenameId,
      lastSeenAt: 200,
      platform: "macos",
      registeredAt: 100
    )
  }

  func getRecoveryMaterial(
    identityToken _: String,
    payloadIdentifier _: String
  ) async throws -> EncryptedProductSyncPayload? {
    remoteRecoveryMaterial
  }

  func putRecoveryMaterialIfUnchanged(
    identityToken: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId _: String,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    recoveryWriteIdentityToken = identityToken
    recoveryWritePayload = encryptedPayload
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
    return EncryptedProductSyncPayload(
      encryptedPayload: storedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: 1
    )
  }
}
