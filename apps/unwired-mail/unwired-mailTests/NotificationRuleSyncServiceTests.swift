import Foundation
import XCTest

@testable import unwired_mail

@MainActor
final class NotificationRuleSyncServiceTests: XCTestCase {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-preview",
    identityToken: "apple-token",
    productAccountId: "productAccountFixtureId",
    trustedDeviceId: "trustedDeviceFixtureId"
  )

  func testSaveEncryptsNotificationRulesBeforeWritingToProductSync() async throws {
    let store = InMemoryProductSyncKeyMaterialStore()
    _ = try store.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      keyMaterialStore: store,
      transport: transport
    )

    let savedRules = try await service.saveRules(
      NotificationRules(categoryIds: ["system:flights", "system:invoices"]),
      expectedUpdatedAt: nil,
      session: session
    )

    XCTAssertEqual(savedRules.rules.categoryIds, ["system:flights", "system:invoices"])
    XCTAssertEqual(transport.writes.count, 1)
    XCTAssertEqual(transport.writes[0].payloadIdentifier, NotificationRules.primaryIdentifier)
    XCTAssertFalse(
      transport.writes[0].encryptedPayload.ciphertextBase64.contains("system:flights")
    )
    XCTAssertFalse(
      transport.writes[0].encryptedPayload.ciphertextBase64.contains("system:invoices")
    )
  }

  func testLoadDecryptsNotificationRulesFromProductSync() async throws {
    let store = InMemoryProductSyncKeyMaterialStore()
    _ = try store.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(keyMaterialStore: store, transport: transport)
    let rules = NotificationRules(categoryIds: ["system:promotions"])
    _ = try await service.saveRules(rules, expectedUpdatedAt: nil, session: session)

    let loadedRules = try await service.loadRules(session: session)

    XCTAssertEqual(loadedRules.rules, rules)
  }

  func testLoadWithoutSyncedRulesReturnsEmptyRulesWithoutCreatingKeyMaterial() async throws {
    let store = InMemoryProductSyncKeyMaterialStore()
    let service = NotificationRuleSyncService(
      keyMaterialStore: store,
      transport: RecordingRuleSyncTransport()
    )

    let loadedRules = try await service.loadRules(session: session)

    XCTAssertEqual(loadedRules.rules, NotificationRules(categoryIds: []))
    XCTAssertNil(try store.load(productAccountId: session.productAccountId))
  }

  func testLoadExistingRemoteRulesRequiresLocalKeyMaterial() async throws {
    let transport = RecordingRuleSyncTransport()
    let firstDevice = NotificationRuleSyncService(
      keyMaterialStore: try seededKeyMaterialStore(for: session),
      transport: transport
    )
    _ = try await firstDevice.saveRules(
      NotificationRules(categoryIds: ["system:invites"]),
      expectedUpdatedAt: nil,
      session: session
    )
    let freshDevice = NotificationRuleSyncService(
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      transport: transport
    )

    do {
      _ = try await freshDevice.loadRules(session: session)
      XCTFail("Expected missing Product Sync key material")
    } catch let error as NotificationRuleSyncError {
      XCTAssertEqual(error, .missingProductSyncKeyMaterial)
    }
  }

  func testSaveWithoutLocalKeyMaterialRejectsWhenAnotherPayloadExists() async throws {
    let transport = RecordingRuleSyncTransport()
    _ = try await transport.putEncryptedProductSyncPayload(
      identityToken: session.identityToken,
      payloadIdentifier: "custom-category-primary",
      encryptedPayload: ProductSyncEncryptedPayload(
        algorithm: ProductSyncEncryptedPayload.algorithmName,
        ciphertextBase64: "ciphertext",
        keyVersion: 1,
        nonceBase64: "nonce",
        schemaVersion: 1,
        tagBase64: "tag"
      ),
      trustedDeviceId: session.trustedDeviceId
    )
    let service = NotificationRuleSyncService(
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      transport: transport
    )

    do {
      _ = try await service.saveRules(
        NotificationRules(categoryIds: ["system:flights"]),
        expectedUpdatedAt: nil,
        session: session
      )
      XCTFail("Expected missing Product Sync key material")
    } catch let error as NotificationRuleSyncError {
      XCTAssertEqual(error, .missingProductSyncKeyMaterial)
    }
  }

  func testSaveWithoutLocalKeyMaterialRejectsWhenNoPayloadExists() async throws {
    let service = NotificationRuleSyncService(
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      transport: RecordingRuleSyncTransport()
    )

    do {
      _ = try await service.saveRules(
        NotificationRules(categoryIds: ["system:flights"]),
        expectedUpdatedAt: nil,
        session: session
      )
      XCTFail("Expected missing Product Sync key material")
    } catch let error as NotificationRuleSyncError {
      XCTAssertEqual(error, .missingProductSyncKeyMaterial)
    }
  }

  func testViewModelSavesRulesBeforeReportingDeniedNotificationAuthorization() async throws {
    let store = try seededKeyMaterialStore(for: session)
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      keyMaterialStore: store,
      transport: transport
    )
    let authorization = StubNotificationAuthorization(granted: false)
    let viewModel = NotificationRuleViewModel(
      authorization: authorization,
      service: service,
      session: session
    )
    await viewModel.load(categoryIds: ["system:flights"])
    viewModel.setEnabled(true, categoryId: "system:flights")

    await viewModel.save()

    XCTAssertEqual(authorization.requestCount, 1)
    XCTAssertEqual(viewModel.enabledCategoryIds, ["system:flights"])
    XCTAssertEqual(
      viewModel.errorMessage,
      "Rules were saved, but visible notifications are disabled in system settings."
    )
    let loadedRules = try await service.loadRules(session: session)
    XCTAssertEqual(loadedRules.rules, NotificationRules(categoryIds: ["system:flights"]))
  }

  func testViewModelPrunesRulesForUnavailableCategories() async throws {
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      keyMaterialStore: try seededKeyMaterialStore(for: session),
      transport: transport
    )
    _ = try await service.saveRules(
      NotificationRules(categoryIds: ["custom-category-primary", "system:flights"]),
      expectedUpdatedAt: nil,
      session: session
    )
    let authorization = StubNotificationAuthorization(granted: true)
    let viewModel = NotificationRuleViewModel(
      authorization: authorization,
      service: service,
      session: session
    )
    await viewModel.load(categoryIds: ["system:flights"])

    XCTAssertEqual(viewModel.enabledCategoryIds, ["system:flights"])
    XCTAssertFalse(viewModel.hasUnsavedChanges)
    XCTAssertEqual(authorization.requestCount, 1)

    let savedRules = try await service.loadRules(session: session)
    XCTAssertEqual(savedRules.rules, NotificationRules(categoryIds: ["system:flights"]))
    XCTAssertFalse(viewModel.hasUnsavedChanges)
  }

  func testViewModelPreservesRulesWhenAvailableCategoriesAreUnknown() async throws {
    let transport = RecordingRuleSyncTransport()
    let store = try seededKeyMaterialStore(for: session)
    let service = NotificationRuleSyncService(
      keyMaterialStore: store,
      transport: transport
    )
    let rules = NotificationRules(categoryIds: ["custom-category-primary", "system:flights"])
    _ = try await service.saveRules(rules, expectedUpdatedAt: nil, session: session)
    let viewModel = NotificationRuleViewModel(
      authorization: StubNotificationAuthorization(granted: true),
      service: service,
      session: session
    )

    await viewModel.load()

    XCTAssertEqual(viewModel.enabledCategoryIds, Set(rules.categoryIds))
  }

  func testViewModelTracksUnsavedRuleEdits() async throws {
    let viewModel = NotificationRuleViewModel(
      authorization: StubNotificationAuthorization(granted: true),
      service: NotificationRuleSyncService(
        keyMaterialStore: try seededKeyMaterialStore(for: session),
        transport: RecordingRuleSyncTransport()
      ),
      session: session
    )

    await viewModel.load(categoryIds: ["system:flights"])
    XCTAssertFalse(viewModel.hasUnsavedChanges)

    viewModel.setEnabled(true, categoryId: "system:flights")
    XCTAssertTrue(viewModel.hasUnsavedChanges)

    await viewModel.save()
    XCTAssertFalse(viewModel.hasUnsavedChanges)
  }

  func testViewModelRequestsNotificationAuthorizationForLoadedRules() async throws {
    let transport = RecordingRuleSyncTransport()
    let store = try seededKeyMaterialStore(for: session)
    let service = NotificationRuleSyncService(
      keyMaterialStore: store,
      transport: transport
    )
    _ = try await service.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: session
    )
    let authorization = StubNotificationAuthorization(granted: false)
    let viewModel = NotificationRuleViewModel(
      authorization: authorization,
      service: service,
      session: session
    )

    await viewModel.load(categoryIds: ["system:flights"])

    XCTAssertEqual(authorization.requestCount, 1)
    XCTAssertEqual(
      viewModel.errorMessage,
      "Rules are enabled, but visible notifications are disabled in system settings."
    )
  }

  func testSaveRejectsStaleExpectedUpdatedAt() async throws {
    let transport = RecordingRuleSyncTransport()
    let store = InMemoryProductSyncKeyMaterialStore()
    _ = try store.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let service = NotificationRuleSyncService(
      keyMaterialStore: store,
      transport: transport
    )
    _ = try await service.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: session
    )

    do {
      _ = try await service.saveRules(
        NotificationRules(categoryIds: ["system:invoices"]),
        expectedUpdatedAt: 0,
        session: session
      )
      XCTFail("Expected concurrent modification")
    } catch let error as NotificationRuleSyncError {
      XCTAssertEqual(error, .concurrentModification)
    }
  }
}

private func seededKeyMaterialStore(
  for session: ProductAccountSessionSnapshot
) throws -> InMemoryProductSyncKeyMaterialStore {
  let store = InMemoryProductSyncKeyMaterialStore()
  _ = try store.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
  return store
}

private final class StubNotificationAuthorization: NotificationAuthorizationRequesting {
  private let granted: Bool
  private(set) var requestCount = 0

  init(granted: Bool) {
    self.granted = granted
  }

  func requestAuthorization() async throws -> Bool {
    requestCount += 1
    return granted
  }
}

private final class RecordingRuleSyncTransport: ProductSyncPayloadTransport {
  private(set) var expectedUpdatedAts: [Int64?] = []
  private(set) var writes: [EncryptedProductSyncPayload] = []

  func listEncryptedProductSyncPayloads(
    identityToken _: String,
    payloadIdentifierPrefix: String?
  ) async throws -> [EncryptedProductSyncPayload] {
    guard let payloadIdentifierPrefix else { return writes }
    return writes.filter { $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) }
  }

  func getEncryptedProductSyncPayload(
    identityToken _: String,
    payloadIdentifier: String
  ) async throws -> EncryptedProductSyncPayload? {
    writes.first { $0.payloadIdentifier == payloadIdentifier }
  }

  func getEncryptedProductSyncPayloads(
    identityToken _: String,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    writes.filter { payloadIdentifiers.contains($0.payloadIdentifier) }
  }

  func putEncryptedProductSyncPayload(
    identityToken _: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload {
    let payload = EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: 1_781_200_000_000 + Int64(writes.count)
    )
    writes.removeAll { $0.payloadIdentifier == payloadIdentifier }
    writes.append(payload)
    return payload
  }

  func putEncryptedProductSyncPayloadIfAbsent(
    identityToken: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId: String
  ) async throws -> EncryptedProductSyncPayload {
    if let existing = writes.first(where: { $0.payloadIdentifier == payloadIdentifier }) {
      return existing
    }
    return try await putEncryptedProductSyncPayload(
      identityToken: identityToken,
      payloadIdentifier: payloadIdentifier,
      encryptedPayload: encryptedPayload,
      trustedDeviceId: trustedDeviceId
    )
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    identityToken: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId: String,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    expectedUpdatedAts.append(expectedUpdatedAt)
    if let existing = writes.first(where: { $0.payloadIdentifier == payloadIdentifier }),
      existing.updatedAt != expectedUpdatedAt
    {
      return existing
    }
    return try await putEncryptedProductSyncPayload(
      identityToken: identityToken,
      payloadIdentifier: payloadIdentifier,
      encryptedPayload: encryptedPayload,
      trustedDeviceId: trustedDeviceId
    )
  }
}
