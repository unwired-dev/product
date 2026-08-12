import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

@MainActor
@Suite(.serialized)
final class NotificationRuleSyncServiceTests {
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

  @Test
  func testLoadDecryptsNotificationRulesFromProductSync() async throws {
    let store = InMemoryProductSyncKeyMaterialStore()
    _ = try store.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: recordBoundary(keyMaterialStore: store, transport: transport)
    )
    let rules = NotificationRules(categoryIds: ["system:promotions"])
    _ = try await service.saveRules(rules, expectedUpdatedAt: nil, session: session)

    let loadedRules = try await service.loadRules(session: session)

    #expect(loadedRules.rules == rules)
  }

  @Test
  func testLegacyRuleSchemaEnablesGlobalPolicyWithoutConnectionOverrides() throws {
    let data = Data(
      #"{"categoryIds":["system:flights","system:invites"],"schemaVersion":1}"#.utf8
    )

    let rules = try JSONDecoder().decode(NotificationRules.self, from: data)

    #expect(rules.isEnabled)
    #expect(rules.categoryIds == ["system:flights", "system:invites"])
    #expect(rules.connectionPolicies.isEmpty)
    #expect(rules.schemaVersion == 2)
  }

  @Test
  func testLoadMigratesLegacyRecordIntoNewAuthoritativePayload() async throws {
    let store = try seededKeyMaterialStore(for: session)
    let transport = RecordingRuleSyncTransport()
    let boundary = recordBoundary(keyMaterialStore: store, transport: transport)
    let legacyRecord = boundary.singleton(
      ProductSyncSingletonDefinition<NotificationRules>(
        identifier: NotificationRules.legacyIdentifier,
        cachePolicy: .authoritative
      )
    )
    _ = try await legacyRecord.writeIfUnchanged(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedRevision: nil,
      session: session
    )
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: boundary
    )

    let snapshot = try await service.loadRules(session: session)

    #expect(snapshot.rules.isEnabled)
    #expect(snapshot.rules.categoryIds == ["system:flights"])
    #expect(snapshot.rules.connectionPolicies.isEmpty)
    #expect(
      Set(transport.writes.map(\.payloadIdentifier))
        == Set([NotificationRules.legacyIdentifier, NotificationRules.primaryIdentifier])
    )
  }

  @Test
  func testProfileScopesUseDisjointNotificationPayloadIdentifiers() async throws {
    let store = try seededKeyMaterialStore(for: session)
    let transport = RecordingRuleSyncTransport()
    let boundary = recordBoundary(keyMaterialStore: store, transport: transport)
    let profileId = MailProfileId(rawValue: "profile-secondary")
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: boundary,
      recordScope: .profile(profileId)
    )

    _ = try await service.saveRules(
      NotificationRules(categoryIds: ["system:invites"]),
      expectedUpdatedAt: nil,
      session: session
    )

    #expect(
      transport.writes.map(\.payloadIdentifier)
        == [
          MailProfileRecordScope.profile(profileId).productSyncIdentifier(
            NotificationRules.primaryIdentifier
          )
        ]
    )
  }

  @Test
  func testLoadWithoutSyncedRulesReturnsEmptyRulesWithoutCreatingKeyMaterial() async throws {
    let store = InMemoryProductSyncKeyMaterialStore()
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: recordBoundary(
        keyMaterialStore: store, transport: RecordingRuleSyncTransport())
    )

    let loadedRules = try await service.loadRules(session: session)

    #expect(loadedRules.rules == NotificationRules(categoryIds: []))
    #expect(try store.load(productAccountId: session.productAccountId) == nil)
  }

  @Test
  func testLoadExistingRemoteRulesRequiresLocalKeyMaterial() async throws {
    let transport = RecordingRuleSyncTransport()
    let firstDevice = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: recordBoundary(
        keyMaterialStore: try seededKeyMaterialStore(for: session), transport: transport)
    )
    _ = try await firstDevice.saveRules(
      NotificationRules(categoryIds: ["system:invites"]),
      expectedUpdatedAt: nil,
      session: session
    )
    let freshDevice = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: recordBoundary(
        keyMaterialStore: InMemoryProductSyncKeyMaterialStore(), transport: transport)
    )

    do {
      _ = try await freshDevice.loadRules(session: session)
      Issue.record("Expected missing Product Sync key material")
    } catch let error as NotificationRuleSyncError {
      #expect(error == .missingProductSyncKeyMaterial)
    }
  }

  @Test
  func testBackgroundLoadUsesCachedEncryptedRulesWhenStoredTokenExpired() async throws {
    let keyStore = try seededKeyMaterialStore(for: expiredSession)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      authorizationStateChecker: StubAuthorizationStateChecker(state: .authorized),
      cacheStore: cacheStore,
      now: { Date(timeIntervalSince1970: 1_000) },
      recordBoundary: recordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let rules = NotificationRules(categoryIds: ["system:flights"])
    _ = try await service.saveRules(rules, expectedUpdatedAt: nil, session: expiredSession)
    transport.loadError = ConvexClientError.httpError(statusCode: 401)

    do {
      _ = try await service.loadRules(session: expiredSession)
      Issue.record("Expected foreground load to surface expired Product Sync auth")
    } catch let error as ConvexClientError {
      #expect(error == .httpError(statusCode: 401))
    }

    let loadedRules = try await service.loadRulesForBackground(session: expiredSession)

    #expect(loadedRules.rules == rules)
    let cachedPayload = try requireValue(cacheStore.payloads[expiredSession.productAccountId])
    #expect(!(try JSONEncoder().encode(cachedPayload).contains(Data("system:flights".utf8))))
  }

  @Test
  func testBackgroundLoadUsesCachedLegacyRulesWhenStoredTokenExpired() async throws {
    let keyStore = try seededKeyMaterialStore(for: expiredSession)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let boundary = recordBoundary(keyMaterialStore: keyStore, transport: transport)
    let legacyRecord = boundary.singleton(
      ProductSyncSingletonDefinition<NotificationRules>(
        identifier: NotificationRules.legacyIdentifier,
        cachePolicy: .authoritative
      )
    )
    let rules = NotificationRules(categoryIds: ["system:flights"])
    _ = try await legacyRecord.writeIfUnchanged(
      rules,
      expectedRevision: nil,
      session: expiredSession
    )
    let legacyPayload = try requireValue(transport.writes.first)
    try cacheStore.save(legacyPayload, productAccountId: expiredSession.productAccountId)
    let service = NotificationRuleSyncService(
      authorizationStateChecker: StubAuthorizationStateChecker(state: .authorized),
      cacheStore: cacheStore,
      now: { Date(timeIntervalSince1970: 1_000) },
      recordBoundary: boundary
    )
    transport.loadError = ConvexClientError.httpError(statusCode: 401)

    let loadedRules = try await service.loadRulesForBackground(session: expiredSession)

    #expect(loadedRules.rules == rules)
  }

  @Test
  func testBackgroundLoadFailsClosedWhenAppleAuthorizationIsRevoked() async throws {
    try await assertBackgroundLoadFailsClosed(
      authorizationState: .revoked,
      identityTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
      loadError: .httpError(statusCode: 401)
    )
  }

  @Test
  func testBackgroundLoadFailsClosedWhenAppleAuthorizationIsMissing() async throws {
    try await assertBackgroundLoadFailsClosed(
      authorizationState: .unauthorized,
      identityTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
      loadError: .httpError(statusCode: 401)
    )
  }

  @Test
  func testBackgroundLoadFailsClosedWhenAppleAuthorizationCannotBeVerified() async throws {
    try await assertBackgroundLoadFailsClosed(
      authorizationState: .unavailable,
      identityTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
      loadError: .httpError(statusCode: 401)
    )
  }

  @Test
  func testBackgroundLoadFailsClosedWhenRejectedTokenIsStillActive() async throws {
    try await assertBackgroundLoadFailsClosed(
      authorizationState: .authorized,
      identityTokenExpiresAt: Date(timeIntervalSince1970: 2_000),
      loadError: .httpError(statusCode: 401)
    )
  }

  @Test
  func testBackgroundLoadFailsClosedWhenTokenExpiryCannotBeVerified() async throws {
    try await assertBackgroundLoadFailsClosed(
      authorizationState: .authorized,
      identityTokenExpiresAt: nil,
      loadError: .httpError(statusCode: 401)
    )
  }

  @Test
  func testBackgroundLoadFailsClosedWhenTrustedDeviceIsRejected() async throws {
    try await assertBackgroundLoadFailsClosed(
      authorizationState: .authorized,
      identityTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
      loadError: .httpError(statusCode: 403)
    )
  }

  @Test
  func testBackgroundLoadFailsClosedForUnrelatedRemoteFailure() async throws {
    try await assertBackgroundLoadFailsClosed(
      authorizationState: .authorized,
      identityTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
      loadError: .httpError(statusCode: 500)
    )
  }

  @Test
  func testAuthenticatedEmptyRulesClearCachedBackgroundRules() async throws {
    let keyStore = try seededKeyMaterialStore(for: session)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let populatedTransport = RecordingRuleSyncTransport()
    let populatedService = NotificationRuleSyncService(
      cacheStore: cacheStore,
      recordBoundary: recordBoundary(keyMaterialStore: keyStore, transport: populatedTransport)
    )
    _ = try await populatedService.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: session
    )
    let emptyTransport = RecordingRuleSyncTransport()
    let emptyService = NotificationRuleSyncService(
      cacheStore: cacheStore,
      recordBoundary: recordBoundary(keyMaterialStore: keyStore, transport: emptyTransport)
    )

    let emptyRules = try await emptyService.loadRules(session: session)
    emptyTransport.loadError = ConvexClientError.httpError(statusCode: 401)

    #expect(emptyRules.rules == NotificationRules(categoryIds: []))
    #expect(cacheStore.payloads[session.productAccountId] == nil)
    do {
      _ = try await emptyService.loadRulesForBackground(session: session)
      Issue.record("Expected missing cache to preserve fail-closed behavior")
    } catch let error as ConvexClientError {
      #expect(error == .httpError(statusCode: 401))
    }
  }

  @Test
  func testAuthenticatedEmptyRulesFailWhenCachedRulesCannotClear() async throws {
    let keyStore = try seededKeyMaterialStore(for: session)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let populatedService = NotificationRuleSyncService(
      cacheStore: cacheStore,
      recordBoundary: recordBoundary(
        keyMaterialStore: keyStore, transport: RecordingRuleSyncTransport())
    )
    _ = try await populatedService.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: session
    )
    cacheStore.clearError = NotificationRuleCacheTestError.writeFailed
    let emptyService = NotificationRuleSyncService(
      cacheStore: cacheStore,
      recordBoundary: recordBoundary(
        keyMaterialStore: keyStore, transport: RecordingRuleSyncTransport())
    )

    do {
      _ = try await emptyService.loadRules(session: session)
      Issue.record("Expected cache-clear failure to prevent a stale background cache")
    } catch let error as NotificationRuleCacheTestError {
      #expect(error == .writeFailed)
    }
  }

  @Test
  func testBackgroundLoadFailsClosedForUndecryptableRemoteRules() async throws {
    let keyStore = try seededKeyMaterialStore(for: session)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: cacheStore,
      recordBoundary: recordBoundary(keyMaterialStore: keyStore, transport: transport)
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
      Issue.record("Expected current undecryptable rules to fail closed")
    } catch {
      #expect(cacheStore.payloads[session.productAccountId] == nil)
    }
  }

  @Test
  func testForegroundLoadFailsWhenUndecryptableRulesCannotClearCachedRules() async throws {
    let keyStore = try seededKeyMaterialStore(for: session)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: cacheStore,
      recordBoundary: recordBoundary(keyMaterialStore: keyStore, transport: transport)
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
      Issue.record("Expected cache-clear failure to prevent stale background rules")
    } catch let error as NotificationRuleCacheTestError {
      #expect(error == .writeFailed)
    }
  }

  @Test
  func testSaveSucceedsWhenBackgroundCacheWriteFails() async throws {
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let service = NotificationRuleSyncService(
      cacheStore: cacheStore,
      recordBoundary: recordBoundary(
        keyMaterialStore: try seededKeyMaterialStore(for: session),
        transport: RecordingRuleSyncTransport())
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

    #expect(savedRules.rules == rules)
    #expect(cacheStore.payloads[session.productAccountId] == nil)
  }

  @Test
  func testSaveFailsWhenCachedRulesCannotClear() async throws {
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      authorizationStateChecker: StubAuthorizationStateChecker(state: .authorized),
      cacheStore: cacheStore,
      now: { Date(timeIntervalSince1970: 1_000) },
      recordBoundary: recordBoundary(
        keyMaterialStore: try seededKeyMaterialStore(for: expiredSession),
        transport: transport
      )
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
      Issue.record("Expected cache-clear failure to prevent a stale background cache")
    } catch let error as NotificationRuleCacheTestError {
      #expect(error == .writeFailed)
    }
    #expect(transport.writes.count == 1)
    #expect(transport.readCount == 0)

    transport.loadError = ConvexClientError.httpError(statusCode: 401)
    let cachedRules = try await service.loadRulesForBackground(session: expiredSession)
    #expect(cachedRules.rules == NotificationRules(categoryIds: ["system:flights"]))
  }

  @Test
  func testTransientSaveFailureInvalidatesCachedRules() async throws {
    try await assertFailedSaveInvalidatesCachedRules(
      error: ConvexClientError.httpError(statusCode: 503)
    )
  }

  @Test
  func testExpiredAuthenticationSaveFailureInvalidatesCachedRules() async throws {
    try await assertFailedSaveInvalidatesCachedRules(
      error: ConvexClientError.httpError(statusCode: 401)
    )
  }

  @Test
  func testSaveConflictCachesAuthoritativeRemoteRules() async throws {
    let keyStore = try seededKeyMaterialStore(for: expiredSession)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      authorizationStateChecker: StubAuthorizationStateChecker(state: .authorized),
      cacheStore: cacheStore,
      now: { Date(timeIntervalSince1970: 1_000) },
      recordBoundary: recordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let initialSnapshot = try await service.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: expiredSession
    )
    let remoteRules = NotificationRules(categoryIds: ["system:invoices"])
    _ = try await NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: recordBoundary(keyMaterialStore: keyStore, transport: transport)
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
      Issue.record("Expected concurrent modification")
    } catch let error as NotificationRuleSyncError {
      #expect(error == .concurrentModification)
    }

    transport.loadError = ConvexClientError.httpError(statusCode: 401)
    let cachedRules = try await service.loadRulesForBackground(session: expiredSession)
    #expect(cachedRules.rules == remoteRules)
  }

  @Test
  func testForegroundLoadSucceedsWhenCacheRefreshFails() async throws {
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: cacheStore,
      recordBoundary: recordBoundary(
        keyMaterialStore: try seededKeyMaterialStore(for: session), transport: transport)
    )
    let rules = NotificationRules(categoryIds: ["system:flights"])
    _ = try await service.saveRules(rules, expectedUpdatedAt: nil, session: session)
    cacheStore.saveError = NotificationRuleCacheTestError.writeFailed

    let loadedRules = try await service.loadRules(session: session)

    #expect(loadedRules.rules == rules)
  }

  @Test
  func testBackgroundLoadFailsClosedWhenEncryptedCacheCannotRefresh() async throws {
    let keyStore = try seededKeyMaterialStore(for: session)
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: cacheStore,
      recordBoundary: recordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    _ = try await service.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: session
    )
    cacheStore.saveError = NotificationRuleCacheTestError.writeFailed

    do {
      _ = try await service.loadRulesForBackground(session: session)
      Issue.record("Expected cache refresh failure to fail closed")
    } catch let error as NotificationRuleCacheTestError {
      #expect(error == .writeFailed)
    }
  }

  @Test
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

    #expect(
      try store.load(
        productAccountId: productAccountId,
        payloadIdentifier: NotificationRules.primaryIdentifier
      ) == payload
    )
    try store.clear(productAccountId: productAccountId)
    #expect(
      try store.load(
        productAccountId: productAccountId,
        payloadIdentifier: NotificationRules.primaryIdentifier
      ) == nil
    )
  }

  @Test
  func testSaveWithoutLocalKeyMaterialRejectsWhenAnotherPayloadExists() async throws {
    let transport = RecordingRuleSyncTransport()
    transport.store(
      EncryptedProductSyncPayload(
        encryptedPayload: ProductSyncEncryptedPayload(
          algorithm: ProductSyncEncryptedPayload.algorithmName,
          ciphertextBase64: "ciphertext",
          keyVersion: 1,
          nonceBase64: "nonce",
          schemaVersion: 1,
          tagBase64: "tag"
        ),
        payloadIdentifier: "custom-category-primary",
        updatedAt: 1_781_200_000_000
      )
    )
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: recordBoundary(
        keyMaterialStore: InMemoryProductSyncKeyMaterialStore(), transport: transport)
    )

    do {
      _ = try await service.saveRules(
        NotificationRules(categoryIds: ["system:flights"]),
        expectedUpdatedAt: nil,
        session: session
      )
      Issue.record("Expected missing Product Sync key material")
    } catch let error as NotificationRuleSyncError {
      #expect(error == .missingProductSyncKeyMaterial)
    }
  }

  @Test
  func testSaveWithoutLocalKeyMaterialRejectsWhenNoPayloadExists() async throws {
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: recordBoundary(
        keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
        transport: RecordingRuleSyncTransport())
    )

    do {
      _ = try await service.saveRules(
        NotificationRules(categoryIds: ["system:flights"]),
        expectedUpdatedAt: nil,
        session: session
      )
      Issue.record("Expected missing Product Sync key material")
    } catch let error as NotificationRuleSyncError {
      #expect(error == .missingProductSyncKeyMaterial)
    }
  }

  @Test
  func testViewModelSavesRulesBeforeReportingDeniedNotificationAuthorization() async throws {
    let store = try seededKeyMaterialStore(for: session)
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: recordBoundary(keyMaterialStore: store, transport: transport)
    )
    let authorization = StubNotificationAuthorization(granted: false)
    let viewModel = NotificationRuleViewModel(
      authorization: authorization,
      service: service,
      session: session
    )
    await viewModel.load(categoryIds: ["system:flights"])
    viewModel.setNotificationEnabled(true)
    viewModel.setEnabled(true, categoryId: "system:flights")

    await viewModel.save()

    #expect(authorization.requestCount == 1)
    #expect(viewModel.enabledCategoryIds == ["system:flights"])
    #expect(
      viewModel.errorMessage
        == "Rules were saved, but visible notifications are disabled in system settings.")
    let loadedRules = try await service.loadRules(session: session)
    #expect(loadedRules.rules == NotificationRules(categoryIds: ["system:flights"]))
  }

  @Test
  func testViewModelPrunesRulesForUnavailableCategories() async throws {
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: recordBoundary(
        keyMaterialStore: try seededKeyMaterialStore(for: session), transport: transport)
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

    #expect(viewModel.enabledCategoryIds == ["system:flights", "system:invoices"])
    #expect(viewModel.hasUnsavedChanges)
    #expect(authorization.requestCount == 0)

    let savedRules = try await service.loadRules(session: session)
    #expect(savedRules.rules == NotificationRules(categoryIds: ["system:flights"]))
  }

  @Test
  func testViewModelPreservesRulesWhenAvailableCategoriesAreUnknown() async throws {
    let transport = RecordingRuleSyncTransport()
    let store = try seededKeyMaterialStore(for: session)
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: recordBoundary(keyMaterialStore: store, transport: transport)
    )
    let rules = NotificationRules(categoryIds: ["custom-category-primary", "system:flights"])
    _ = try await service.saveRules(rules, expectedUpdatedAt: nil, session: session)
    let viewModel = NotificationRuleViewModel(
      authorization: StubNotificationAuthorization(granted: true),
      service: service,
      session: session
    )

    await viewModel.load()

    #expect(viewModel.enabledCategoryIds == Set(rules.categoryIds))
  }

  @Test
  func testViewModelTracksUnsavedRuleEdits() async throws {
    let viewModel = NotificationRuleViewModel(
      authorization: StubNotificationAuthorization(granted: true),
      service: NotificationRuleSyncService(
        cacheStore: InMemoryNotificationRuleCacheStore(),
        recordBoundary: recordBoundary(
          keyMaterialStore: try seededKeyMaterialStore(for: session),
          transport: RecordingRuleSyncTransport())
      ),
      session: session
    )

    await viewModel.load(categoryIds: ["system:flights"])
    #expect(!(viewModel.hasUnsavedChanges))

    viewModel.setNotificationEnabled(true)
    viewModel.setEnabled(true, categoryId: "system:flights")
    #expect(viewModel.hasUnsavedChanges)

    await viewModel.save()
    #expect(!(viewModel.hasUnsavedChanges))
  }

  @Test
  func testViewModelRequestsNotificationAuthorizationForLoadedRules() async throws {
    let transport = RecordingRuleSyncTransport()
    let store = try seededKeyMaterialStore(for: session)
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: recordBoundary(keyMaterialStore: store, transport: transport)
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

    #expect(authorization.requestCount == 0)
    #expect(
      viewModel.errorMessage
        == "Rules are enabled, but visible notifications are disabled in system settings.")
  }

  @Test
  func testSaveRejectsStaleExpectedUpdatedAt() async throws {
    let transport = RecordingRuleSyncTransport()
    let store = InMemoryProductSyncKeyMaterialStore()
    _ = try store.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: recordBoundary(keyMaterialStore: store, transport: transport)
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
      Issue.record("Expected concurrent modification")
    } catch let error as NotificationRuleSyncError {
      #expect(error == .concurrentModification)
    }
  }

  private func assertFailedSaveInvalidatesCachedRules(
    error: ConvexClientError
  ) async throws {
    let cacheStore = InMemoryNotificationRuleCacheStore()
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: cacheStore,
      recordBoundary: recordBoundary(
        keyMaterialStore: try seededKeyMaterialStore(for: session), transport: transport)
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
      Issue.record("Expected remote save failure")
    } catch let caughtError as ConvexClientError {
      #expect(caughtError == error)
    }
    #expect(cacheStore.payloads[session.productAccountId] == nil)

    transport.loadError = error
    do {
      _ = try await service.loadRulesForBackground(session: session)
      Issue.record("Expected failed save to leave no background cache")
    } catch let caughtError as ConvexClientError {
      #expect(caughtError == error)
    }
  }
}

extension NotificationRuleSyncServiceTests {
  @Test
  func testSaveEncryptsNotificationRulesBeforeWritingToProductSync() async throws {
    let store = InMemoryProductSyncKeyMaterialStore()
    _ = try store.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingRuleSyncTransport()
    let service = NotificationRuleSyncService(
      cacheStore: InMemoryNotificationRuleCacheStore(),
      recordBoundary: recordBoundary(keyMaterialStore: store, transport: transport)
    )

    let savedRules = try await service.saveRules(
      NotificationRules(categoryIds: ["system:flights", "system:invoices"]),
      expectedUpdatedAt: nil,
      session: session
    )

    #expect(savedRules.rules.categoryIds == ["system:flights", "system:invoices"])
    #expect(transport.writes.count == 1)
    #expect(transport.writes[0].payloadIdentifier == NotificationRules.primaryIdentifier)
    let ciphertext = try requireValue(
      Data(base64Encoded: transport.writes[0].encryptedPayload.ciphertextBase64))
    let plaintext = try JSONEncoder().encode(
      NotificationRules(categoryIds: ["system:flights", "system:invoices"])
    )
    #expect(!(ciphertext.contains(Data("system:flights".utf8))))
    #expect(!(ciphertext.contains(Data("system:invoices".utf8))))
    #expect(!(ciphertext.contains(plaintext)))
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
      now: { Date(timeIntervalSince1970: 1_000) },
      recordBoundary: recordBoundary(
        keyMaterialStore: try seededKeyMaterialStore(for: testSession),
        transport: transport
      )
    )
    _ = try await service.saveRules(
      NotificationRules(categoryIds: ["system:flights"]),
      expectedUpdatedAt: nil,
      session: testSession
    )
    transport.loadError = loadError

    do {
      _ = try await service.loadRulesForBackground(session: testSession)
      Issue.record("Expected cached rules to remain unavailable")
    } catch let error as ConvexClientError {
      #expect(error == loadError)
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

private func recordBoundary(
  keyMaterialStore: ProductSyncKeyMaterialPersisting,
  transport: ProductSyncRecordTransport
) -> ProductSyncRecordBoundary {
  ProductSyncRecordBoundary(keyMaterialStore: keyMaterialStore, transport: transport)
}

private final class StubNotificationAuthorization:
  NotificationAuthorizationRequesting, NotificationAuthorizationStateChecking
{
  private let granted: Bool
  private(set) var requestCount = 0

  init(granted: Bool) {
    self.granted = granted
  }

  func requestAuthorization() async throws -> Bool {
    requestCount += 1
    return granted
  }

  func notificationAuthorizationState() async -> NotificationAuthorizationState {
    granted ? .authorized : .denied
  }
}

private final class RecordingRuleSyncTransport: ProductSyncRecordTransport {
  private(set) var expectedUpdatedAts: [Int64?] = []
  private(set) var readCount = 0
  private(set) var writes: [EncryptedProductSyncPayload] = []
  var loadError: Error?
  var saveError: Error?

  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor: String?,
    limit: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    readCount += 1
    if let loadError {
      throw loadError
    }
    let matching =
      writes
      .filter { $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) }
      .sorted { $0.payloadIdentifier < $1.payloadIdentifier }
    let start = min(Int(cursor ?? "") ?? 0, matching.count)
    let end = min(start + limit, matching.count)
    return EncryptedProductSyncPayloadPage(
      continueCursor: end == matching.count ? "" : String(end),
      isDone: end == matching.count,
      page: Array(matching[start..<end])
    )
  }

  func getEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    readCount += 1
    if let loadError {
      throw loadError
    }
    return writes.filter { payloadIdentifiers.contains($0.payloadIdentifier) }
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
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
    if expectedUpdatedAt != nil,
      !writes.contains(where: { $0.payloadIdentifier == payloadIdentifier })
    {
      throw ProductSyncRecordBoundaryError.invalidPayloadIdentifier
    }
    let payload = EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: 1_781_200_000_000 + Int64(writes.count)
    )
    writes.removeAll { $0.payloadIdentifier == payloadIdentifier }
    writes.append(payload)
    return payload
  }

  func store(_ payload: EncryptedProductSyncPayload) {
    writes.removeAll { $0.payloadIdentifier == payload.payloadIdentifier }
    writes.append(payload)
  }

  func replaceStoredPayload(_ payload: EncryptedProductSyncPayload) {
    writes = [payload]
  }
}

private final class InMemoryNotificationRuleCacheStore: NotificationRuleCachePersisting {
  private var records: [String: [String: EncryptedProductSyncPayload]] = [:]
  var clearError: Error?
  var saveError: Error?

  var payloads: [String: EncryptedProductSyncPayload] {
    records.compactMapValues { records in
      records.keys.sorted().first(where: { $0.hasSuffix(NotificationRules.primaryIdentifier) })
        .flatMap { records[$0] }
    }
  }

  func clear(productAccountId: String) throws {
    if let clearError {
      throw clearError
    }
    records[productAccountId] = nil
  }

  func clear(productAccountId: String, payloadIdentifier: String) throws {
    if let clearError {
      throw clearError
    }
    records[productAccountId]?[payloadIdentifier] = nil
  }

  func load(
    productAccountId: String,
    payloadIdentifier: String
  ) throws -> EncryptedProductSyncPayload? {
    records[productAccountId]?[payloadIdentifier]
  }

  func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) throws {
    if let saveError {
      throw saveError
    }
    records[productAccountId, default: [:]][payload.payloadIdentifier] = payload
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
