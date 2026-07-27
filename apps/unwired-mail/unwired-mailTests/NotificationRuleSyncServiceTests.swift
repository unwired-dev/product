import Foundation
import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

@MainActor
final class NotificationRuleSyncServiceTests: XCTestCase {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-preview",
    identityToken: "apple-token",
    productAccountId: "productAccountFixtureId",
    trustedDeviceId: "trustedDeviceFixtureId"
  )
  private var expiredSession: ProductAccountSessionSnapshot {
    ProductAccountSessionSnapshot(
      appleUserIdentifier: session.appleUserIdentifier,
      identityToken: session.identityToken,
      identityTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )
  }

  func testLoadDecryptsNotificationRulesFromProductSync() async throws {
    let store = InMemoryProductSyncKeyMaterialStore()
    _ = try store.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      keyMaterialStore: store,
      transport: transport
    )
    let rules = NotificationRules(categoryIds: ["system:promotions"])
    _ = try await service.saveRules(rules, expectedUpdatedAt: nil, session: session)

    let loadedRules = try await service.loadRules(session: session)

    XCTAssertEqual(loadedRules.rules, rules)
  }

  func testLoadWithoutSyncedRulesReturnsEmptyRulesWithoutCreatingKeyMaterial() async throws {
    let store = InMemoryProductSyncKeyMaterialStore()
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
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
      cacheStore: InMemoryNotificationRuleCacheStore(),
      keyMaterialStore: try seededKeyMaterialStore(for: session),
      transport: transport
    )
    _ = try await firstDevice.saveRules(
      NotificationRules(categoryIds: ["system:invites"]),
      expectedUpdatedAt: nil,
      session: session
    )
    let freshDevice = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
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

  func testBackgroundLoadUsesCachedEncryptedRulesWhenStoredTokenExpired() async throws {
    let keyStore = try seededKeyMaterialStore(for: expiredSession)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      authorizationStateChecker: StubAuthorizationStateChecker(state: .authorized),
      cacheStore: cacheStore,
      keyMaterialStore: keyStore,
      now: { Date(timeIntervalSince1970: 1_000) },
      transport: transport
    )
    let rules = NotificationRules(categoryIds: ["system:flights"])
    _ = try await service.saveRules(rules, expectedUpdatedAt: nil, session: expiredSession)
    transport.loadError = ConvexClientError.httpError(statusCode: 401)

    do {
      _ = try await service.loadRules(session: expiredSession)
      XCTFail("Expected foreground load to surface expired Product Sync auth")
    } catch let error as ConvexClientError {
      XCTAssertEqual(error, .httpError(statusCode: 401))
    }

    let loadedRules = try await service.loadRulesForBackground(session: expiredSession)

    XCTAssertEqual(loadedRules.rules, rules)
    let cachedPayload = try XCTUnwrap(cacheStore.payloads[expiredSession.productAccountId])
    XCTAssertFalse(
      try JSONEncoder().encode(cachedPayload).contains(Data("system:flights".utf8))
    )
  }

  func testBackgroundLoadFailsClosedWhenAppleAuthorizationIsRevoked() async throws {
    try await assertBackgroundLoadFailsClosed(
      authorizationState: .revoked,
      identityTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
      loadError: .httpError(statusCode: 401)
    )
  }

  func testBackgroundLoadFailsClosedWhenAppleAuthorizationIsMissing() async throws {
    try await assertBackgroundLoadFailsClosed(
      authorizationState: .unauthorized,
      identityTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
      loadError: .httpError(statusCode: 401)
    )
  }

  func testBackgroundLoadFailsClosedWhenAppleAuthorizationCannotBeVerified() async throws {
    try await assertBackgroundLoadFailsClosed(
      authorizationState: .unavailable,
      identityTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
      loadError: .httpError(statusCode: 401)
    )
  }

  func testBackgroundLoadFailsClosedWhenRejectedTokenIsStillActive() async throws {
    try await assertBackgroundLoadFailsClosed(
      authorizationState: .authorized,
      identityTokenExpiresAt: Date(timeIntervalSince1970: 2_000),
      loadError: .httpError(statusCode: 401)
    )
  }

  func testBackgroundLoadFailsClosedWhenTokenExpiryCannotBeVerified() async throws {
    try await assertBackgroundLoadFailsClosed(
      authorizationState: .authorized,
      identityTokenExpiresAt: nil,
      loadError: .httpError(statusCode: 401)
    )
  }

  func testBackgroundLoadFailsClosedWhenTrustedDeviceIsRejected() async throws {
    try await assertBackgroundLoadFailsClosed(
      authorizationState: .authorized,
      identityTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
      loadError: .httpError(statusCode: 403)
    )
  }

  func testBackgroundLoadFailsClosedForUnrelatedRemoteFailure() async throws {
    try await assertBackgroundLoadFailsClosed(
      authorizationState: .authorized,
      identityTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
      loadError: .httpError(statusCode: 500)
    )
  }

  func testAuthenticatedEmptyRulesClearCachedBackgroundRules() async throws {
    let keyStore = try seededKeyMaterialStore(for: session)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let populatedTransport = RecordingRuleSyncTransport()
    let populatedService = NotificationRuleSyncService(
      cacheStore: cacheStore,
      keyMaterialStore: keyStore,
      transport: populatedTransport
    )
    _ = try await populatedService.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: session
    )
    let emptyTransport = RecordingRuleSyncTransport()
    let emptyService = NotificationRuleSyncService(
      cacheStore: cacheStore,
      keyMaterialStore: keyStore,
      transport: emptyTransport
    )

    let emptyRules = try await emptyService.loadRules(session: session)
    emptyTransport.loadError = ConvexClientError.httpError(statusCode: 401)

    XCTAssertEqual(emptyRules.rules, NotificationRules(categoryIds: []))
    XCTAssertNil(cacheStore.payloads[session.productAccountId])
    do {
      _ = try await emptyService.loadRulesForBackground(session: session)
      XCTFail("Expected missing cache to preserve fail-closed behavior")
    } catch let error as ConvexClientError {
      XCTAssertEqual(error, .httpError(statusCode: 401))
    }
  }

  func testAuthenticatedEmptyRulesFailWhenCachedRulesCannotClear() async throws {
    let keyStore = try seededKeyMaterialStore(for: session)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let populatedService = NotificationRuleSyncService(
      cacheStore: cacheStore,
      keyMaterialStore: keyStore,
      transport: RecordingRuleSyncTransport()
    )
    _ = try await populatedService.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: session
    )
    cacheStore.clearError = NotificationRuleCacheTestError.writeFailed
    let emptyService = NotificationRuleSyncService(
      cacheStore: cacheStore,
      keyMaterialStore: keyStore,
      transport: RecordingRuleSyncTransport()
    )

    do {
      _ = try await emptyService.loadRules(session: session)
      XCTFail("Expected cache-clear failure to prevent a stale background cache")
    } catch let error as NotificationRuleCacheTestError {
      XCTAssertEqual(error, .writeFailed)
    }
  }

  func testBackgroundLoadFailsClosedForUndecryptableRemoteRules() async throws {
    let keyStore = try seededKeyMaterialStore(for: session)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: cacheStore,
      keyMaterialStore: keyStore,
      transport: transport
    )
    _ = try await service.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: session
    )
    transport.replaceStoredPayload(
      EncryptedProductSyncPayload(
        encryptedPayload: ProductSyncEncryptedPayload(
          algorithm: ProductSyncEncryptedPayload.algorithmName,
          ciphertextBase64: "invalid",
          keyVersion: 1,
          nonceBase64: "invalid",
          schemaVersion: 1,
          tagBase64: "invalid"
        ),
        payloadIdentifier: NotificationRules.primaryIdentifier,
        updatedAt: 1_781_400_000_001
      )
    )

    do {
      _ = try await service.loadRulesForBackground(session: session)
      XCTFail("Expected current undecryptable rules to fail closed")
    } catch {
      XCTAssertNil(cacheStore.payloads[session.productAccountId])
    }
  }

  func testForegroundLoadFailsWhenUndecryptableRulesCannotClearCachedRules() async throws {
    let keyStore = try seededKeyMaterialStore(for: session)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: cacheStore,
      keyMaterialStore: keyStore,
      transport: transport
    )
    _ = try await service.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: session
    )
    transport.replaceStoredPayload(
      EncryptedProductSyncPayload(
        encryptedPayload: ProductSyncEncryptedPayload(
          algorithm: ProductSyncEncryptedPayload.algorithmName,
          ciphertextBase64: "invalid",
          keyVersion: 1,
          nonceBase64: "invalid",
          schemaVersion: 1,
          tagBase64: "invalid"
        ),
        payloadIdentifier: NotificationRules.primaryIdentifier,
        updatedAt: 1_781_400_000_001
      )
    )
    cacheStore.clearError = NotificationRuleCacheTestError.writeFailed

    do {
      _ = try await service.loadRules(session: session)
      XCTFail("Expected cache-clear failure to prevent stale background rules")
    } catch let error as NotificationRuleCacheTestError {
      XCTAssertEqual(error, .writeFailed)
    }
  }

  func testSaveSucceedsWhenBackgroundCacheWriteFails() async throws {
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let service = NotificationRuleSyncService(
      cacheStore: cacheStore,
      keyMaterialStore: try seededKeyMaterialStore(for: session),
      transport: RecordingRuleSyncTransport()
    )
    let initialRules = NotificationRules(categoryIds: ["system:flights"])
    let initialSnapshot = try await service.saveRules(
      initialRules,
      expectedUpdatedAt: nil,
      session: session
    )
    cacheStore.saveError = NotificationRuleCacheTestError.writeFailed
    let rules = NotificationRules(categoryIds: ["system:invoices"])

    let savedRules = try await service.saveRules(
      rules,
      expectedUpdatedAt: initialSnapshot.updatedAt,
      session: session
    )

    XCTAssertEqual(savedRules.rules, rules)
    XCTAssertNil(cacheStore.payloads[session.productAccountId])
  }

  func testSaveFailsWhenCachedRulesCannotClear() async throws {
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      authorizationStateChecker: StubAuthorizationStateChecker(state: .authorized),
      cacheStore: cacheStore,
      keyMaterialStore: try seededKeyMaterialStore(for: expiredSession),
      now: { Date(timeIntervalSince1970: 1_000) },
      transport: transport
    )
    let initialSnapshot = try await service.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: expiredSession
    )
    cacheStore.clearError = NotificationRuleCacheTestError.writeFailed

    do {
      _ = try await service.saveRules(
        NotificationRules(categoryIds: ["system:invoices"]),
        expectedUpdatedAt: initialSnapshot.updatedAt,
        session: expiredSession
      )
      XCTFail("Expected cache-clear failure to prevent a stale background cache")
    } catch let error as NotificationRuleCacheTestError {
      XCTAssertEqual(error, .writeFailed)
    }
    XCTAssertEqual(transport.writes.count, 1)

    transport.loadError = ConvexClientError.httpError(statusCode: 401)
    let cachedRules = try await service.loadRulesForBackground(session: expiredSession)
    XCTAssertEqual(cachedRules.rules, NotificationRules(categoryIds: ["system:flights"]))
  }

  func testTransientSaveFailureInvalidatesCachedRules() async throws {
    try await assertFailedSaveInvalidatesCachedRules(
      error: ConvexClientError.httpError(statusCode: 503)
    )
  }

  func testExpiredAuthenticationSaveFailureInvalidatesCachedRules() async throws {
    try await assertFailedSaveInvalidatesCachedRules(
      error: ConvexClientError.httpError(statusCode: 401)
    )
  }

  func testSaveConflictCachesAuthoritativeRemoteRules() async throws {
    let keyStore = try seededKeyMaterialStore(for: expiredSession)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      authorizationStateChecker: StubAuthorizationStateChecker(state: .authorized),
      cacheStore: cacheStore,
      keyMaterialStore: keyStore,
      now: { Date(timeIntervalSince1970: 1_000) },
      transport: transport
    )
    let initialSnapshot = try await service.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: expiredSession
    )
    let remoteRules = NotificationRules(categoryIds: ["system:invoices"])
    _ = try await NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      keyMaterialStore: keyStore,
      transport: transport
    ).saveRules(
      remoteRules,
      expectedUpdatedAt: initialSnapshot.updatedAt,
      session: expiredSession
    )

    do {
      _ = try await service.saveRules(
        NotificationRules(categoryIds: ["system:promotions"]),
        expectedUpdatedAt: initialSnapshot.updatedAt,
        session: expiredSession
      )
      XCTFail("Expected concurrent modification")
    } catch let error as NotificationRuleSyncError {
      XCTAssertEqual(error, .concurrentModification)
    }

    transport.loadError = ConvexClientError.httpError(statusCode: 401)
    let cachedRules = try await service.loadRulesForBackground(session: expiredSession)
    XCTAssertEqual(cachedRules.rules, remoteRules)
  }

  func testForegroundLoadSucceedsWhenCacheRefreshFails() async throws {
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: cacheStore,
      keyMaterialStore: try seededKeyMaterialStore(for: session),
      transport: transport
    )
    let rules = NotificationRules(categoryIds: ["system:flights"])
    _ = try await service.saveRules(rules, expectedUpdatedAt: nil, session: session)
    cacheStore.saveError = NotificationRuleCacheTestError.writeFailed

    let loadedRules = try await service.loadRules(session: session)

    XCTAssertEqual(loadedRules.rules, rules)
  }

  func testBackgroundLoadFailsClosedWhenEncryptedCacheCannotRefresh() async throws {
    let keyStore = try seededKeyMaterialStore(for: session)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: cacheStore,
      keyMaterialStore: keyStore,
      transport: transport
    )
    _ = try await service.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: session
    )
    cacheStore.saveError = NotificationRuleCacheTestError.writeFailed

    do {
      _ = try await service.loadRulesForBackground(session: session)
      XCTFail("Expected cache refresh failure to fail closed")
    } catch let error as NotificationRuleCacheTestError {
      XCTAssertEqual(error, .writeFailed)
    }
  }

  func testNotificationRuleCacheKeepsEncryptedPayloadInKeychain() throws {
    let productAccountId = "notification-rule-cache-\(UUID().uuidString)"
    let store = KeychainNotificationRuleCacheStore()
    let payload = EncryptedProductSyncPayload(
      encryptedPayload: ProductSyncEncryptedPayload(
        algorithm: ProductSyncEncryptedPayload.algorithmName,
        ciphertextBase64: "ciphertext",
        keyVersion: 1,
        nonceBase64: "nonce",
        schemaVersion: 1,
        tagBase64: "tag"
      ),
      payloadIdentifier: NotificationRules.primaryIdentifier,
      updatedAt: 1_781_400_000_000
    )
    defer { try? store.clear(productAccountId: productAccountId) }

    try store.save(payload, productAccountId: productAccountId)

    XCTAssertEqual(try store.load(productAccountId: productAccountId), payload)
    try store.clear(productAccountId: productAccountId)
    XCTAssertNil(try store.load(productAccountId: productAccountId))
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
      cacheStore: InMemoryNotificationRuleCacheStore(),
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
      cacheStore: InMemoryNotificationRuleCacheStore(),
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
      cacheStore: InMemoryNotificationRuleCacheStore(),
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
      cacheStore: InMemoryNotificationRuleCacheStore(),
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
    await viewModel.load()
    viewModel.setEnabled(true, categoryId: "system:invoices")
    await viewModel.prune(categoryIds: ["system:flights", "system:invoices"])

    XCTAssertEqual(viewModel.enabledCategoryIds, ["system:flights", "system:invoices"])
    XCTAssertTrue(viewModel.hasUnsavedChanges)
    XCTAssertEqual(authorization.requestCount, 1)

    let savedRules = try await service.loadRules(session: session)
    XCTAssertEqual(savedRules.rules, NotificationRules(categoryIds: ["system:flights"]))
  }

  func testViewModelPreservesRulesWhenAvailableCategoriesAreUnknown() async throws {
    let transport = RecordingRuleSyncTransport()
    let store = try seededKeyMaterialStore(for: session)
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
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
        cacheStore: InMemoryNotificationRuleCacheStore(),
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
      cacheStore: InMemoryNotificationRuleCacheStore(),
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
      cacheStore: InMemoryNotificationRuleCacheStore(),
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

  private func assertFailedSaveInvalidatesCachedRules(
    error: ConvexClientError
  ) async throws {
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: cacheStore,
      keyMaterialStore: try seededKeyMaterialStore(for: session),
      transport: transport
    )
    let initialSnapshot = try await service.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: session
    )
    transport.saveError = error

    do {
      _ = try await service.saveRules(
        NotificationRules(categoryIds: ["system:invoices"]),
        expectedUpdatedAt: initialSnapshot.updatedAt,
        session: session
      )
      XCTFail("Expected remote save failure")
    } catch let caughtError as ConvexClientError {
      XCTAssertEqual(caughtError, error)
    }
    XCTAssertNil(cacheStore.payloads[session.productAccountId])

    transport.loadError = error
    do {
      _ = try await service.loadRulesForBackground(session: session)
      XCTFail("Expected failed save to leave no background cache")
    } catch let caughtError as ConvexClientError {
      XCTAssertEqual(caughtError, error)
    }
  }
}

extension NotificationRuleSyncServiceTests {
  func testSaveEncryptsNotificationRulesBeforeWritingToProductSync() async throws {
    let store = InMemoryProductSyncKeyMaterialStore()
    _ = try store.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
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
    let ciphertext = try XCTUnwrap(
      Data(base64Encoded: transport.writes[0].encryptedPayload.ciphertextBase64)
    )
    let plaintext = try JSONEncoder().encode(
      NotificationRules(categoryIds: ["system:flights", "system:invoices"])
    )
    XCTAssertFalse(ciphertext.contains(Data("system:flights".utf8)))
    XCTAssertFalse(ciphertext.contains(Data("system:invoices".utf8)))
    XCTAssertFalse(ciphertext.contains(plaintext))
  }

  private func assertBackgroundLoadFailsClosed(
    authorizationState: ProductAccountAuthorizationState,
    identityTokenExpiresAt: Date?,
    loadError: ConvexClientError
  ) async throws {
    let testSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: session.appleUserIdentifier,
      identityToken: session.identityToken,
      identityTokenExpiresAt: identityTokenExpiresAt,
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      authorizationStateChecker: StubAuthorizationStateChecker(
        state: authorizationState
      ),
      cacheStore: InMemoryNotificationRuleCacheStore(),
      keyMaterialStore: try seededKeyMaterialStore(for: testSession),
      now: { Date(timeIntervalSince1970: 1_000) },
      transport: transport
    )
    _ = try await service.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: testSession
    )
    transport.loadError = loadError

    do {
      _ = try await service.loadRulesForBackground(session: testSession)
      XCTFail("Expected cached rules to remain unavailable")
    } catch let error as ConvexClientError {
      XCTAssertEqual(error, loadError)
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
  var loadError: Error?
  var saveError: Error?

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
    if let loadError {
      throw loadError
    }
    return writes.first { $0.payloadIdentifier == payloadIdentifier }
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
    if let saveError {
      throw saveError
    }
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

  func replaceStoredPayload(_ payload: EncryptedProductSyncPayload) {
    writes = [payload]
  }
}

private final class InMemoryNotificationRuleCacheStore: NotificationRuleCachePersisting {
  private(set) var payloads: [String: EncryptedProductSyncPayload] = [:]
  var clearError: Error?
  var saveError: Error?

  func clear(productAccountId: String) throws {
    if let clearError {
      throw clearError
    }
    payloads[productAccountId] = nil
  }

  func load(productAccountId: String) throws -> EncryptedProductSyncPayload? {
    payloads[productAccountId]
  }

  func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) throws {
    if let saveError {
      throw saveError
    }
    payloads[productAccountId] = payload
  }
}

private enum NotificationRuleCacheTestError: Error {
  case writeFailed
}

private struct StubAuthorizationStateChecker: ProductAccountAuthorizationStateChecking {
  let state: ProductAccountAuthorizationState

  func authorizationState(forAppleUserIdentifier _: String) async
    -> ProductAccountAuthorizationState
  {
    state
  }
}
