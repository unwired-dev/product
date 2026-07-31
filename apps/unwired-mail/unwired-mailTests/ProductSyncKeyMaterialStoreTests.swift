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

    viewModel.acknowledgeRecoveryKey {
      throw CocoaError(.fileWriteUnknown)
    }

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
    payloadIdentifier _: String
  ) async throws -> EncryptedProductSyncPayload? {
    recoveryReadIdentityToken = identityToken
    recoveryReadCount += 1
    if recoveryReadCount == recoveryReadErrorOnCall {
      throw AccountAndDevicesTransportError.offline
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
