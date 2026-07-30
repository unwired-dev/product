import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
final class GenericMailSetupServiceTests: XCTestCase {
  @MainActor
  func testSettingsSummaryIncludesAuthorizedPOP3Definition() {
    let definition = GenericMailConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "legacy@example.com",
      incomingEndpoint: GenericMailEndpoint(
        mailProtocol: .pop3, hostname: "pop.example.com", port: 995, security: .implicitTLS),
      outgoingEndpoint: GenericMailEndpoint(
        mailProtocol: .smtp, hostname: "smtp.example.com", port: 465, security: .implicitTLS),
      roleMappings: [:],
      username: "legacy@example.com"
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "product-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )

    let connections = EmailAccountsSettingsView.makeSummaryConnections(
      routedConnections: [],
      genericDefinitions: [definition],
      authorizedGenericConnectionIds: [definition.connectionId],
      session: session
    )

    XCTAssertEqual(connections.map(\.id), [definition.connectionId])
    XCTAssertEqual(connections.first?.authorizationState, .authorized)
    XCTAssertEqual(connections.first?.providerId, .pop3SMTP)
  }

  @MainActor
  func testConnectionReloadKeyChangesWhenSyncedDefinitionContentChanges() {
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true }
    )
    let definition = GenericMailConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "reader@example.com",
      incomingEndpoint: GenericMailEndpoint(
        mailProtocol: .imap, hostname: "imap.example.com", port: 993, security: .implicitTLS),
      outgoingEndpoint: GenericMailEndpoint(
        mailProtocol: .smtp, hostname: "smtp.example.com", port: 465, security: .implicitTLS),
      roleMappings: [.sent: "Sent"],
      username: "reader@example.com"
    )
    viewModel.syncedDefinitions = [definition]
    let initialKey = viewModel.connectionReloadKey
    viewModel.syncedDefinitions = [
      GenericMailConnectionDefinition(
        authorizationMethod: definition.authorizationMethod,
        emailAddress: "updated@example.com",
        incomingEndpoint: definition.incomingEndpoint,
        outgoingEndpoint: definition.outgoingEndpoint,
        roleMappings: [.sent: "Updated Sent"],
        username: definition.username
      )
    ]

    XCTAssertEqual(viewModel.syncedDefinitions[0].connectionId, definition.connectionId)
    XCTAssertNotEqual(viewModel.connectionReloadKey, initialKey)
  }

  func testReviewedCatalogDiscoversIMAPSMTPAndPOP3Locally() {
    let catalog = BundledMailProviderCatalog()

    let fastmail = catalog.discover(emailAddress: "reader@fastmail.com")
    let iCloud = catalog.discover(emailAddress: "reader@icloud.com")

    XCTAssertEqual(fastmail?.incomingEndpoints.map(\.mailProtocol), [.imap, .pop3])
    XCTAssertEqual(fastmail?.outgoingEndpoint.mailProtocol, .smtp)
    XCTAssertEqual(fastmail?.outgoingEndpoint.security, .implicitTLS)
    XCTAssertEqual(fastmail?.preferredAuthorizationMethod, .appPassword)
    XCTAssertEqual(iCloud?.incomingEndpoints.map(\.mailProtocol), [.imap])
    XCTAssertEqual(iCloud?.outgoingEndpoint.security, .startTLS)
    XCTAssertNil(catalog.discover(emailAddress: "reader@unknown.example"))
  }

  @MainActor
  func testDiscoveredPOP3SelectionAppliesItsOwnEndpoint() {
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true },
      service: GenericMailSetupService(
        authorizationStore: RecordingGenericMailAuthorizationStore(),
        verifier: RecordingGenericMailEndpointVerifier()
      )
    )
    viewModel.emailAddress = "reader@fastmail.com"

    viewModel.discover()
    viewModel.selectIncomingProtocol(.pop3)

    XCTAssertEqual(viewModel.incomingHostname, "pop.fastmail.com")
    XCTAssertEqual(viewModel.incomingPort, "995")
    XCTAssertEqual(viewModel.incomingSecurity, .implicitTLS)
  }

  @MainActor
  func testFailedDiscoveryClearsEndpointsAndMappingsFromPreviousProvider() {
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true }
    )
    viewModel.emailAddress = "reader@fastmail.com"
    viewModel.discover()
    viewModel.roleMappings[.sent] = "Sent from previous provider"

    viewModel.emailAddress = "reader@unknown.example"
    viewModel.discover()

    XCTAssertEqual(viewModel.incomingHostname, "")
    XCTAssertEqual(viewModel.incomingPort, "")
    XCTAssertEqual(viewModel.outgoingHostname, "")
    XCTAssertEqual(viewModel.outgoingPort, "")
    XCTAssertTrue(viewModel.roleMappings.isEmpty)
  }

  func testManualConfigurationVerifiesEveryEndpointBeforeSavingDeviceAuthorization()
    async throws
  {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )

    let definition = try await service.authorize(
      draft: manualDraft(),
      credential: "device-only-secret",
      productAccountId: ProductAccountId("product-account-001")
    )

    XCTAssertEqual(verifier.endpoints.map(\.mailProtocol), [.imap, .smtp])
    XCTAssertEqual(definition.connectionId.providerId.rawValue, "imap-smtp")
    XCTAssertEqual(store.productAccountId, ProductAccountId("product-account-001"))
    XCTAssertEqual(store.authorization?.credential, "device-only-secret")
    XCTAssertEqual(store.authorization?.definition, definition)
  }

  func testVerifiedDefinitionSynchronizesWhileCredentialRemainsDeviceLocal() async throws {
    let store = RecordingGenericMailAuthorizationStore()
    let sync = RecordingGenericSyncService()
    let service = GenericMailSetupService(
      authorizationStore: store,
      clock: { 1_781_200_000_600 },
      definitionSyncService: sync,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "product-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )

    let definition = try await service.authorize(
      draft: manualDraft(),
      credential: "device-only-secret",
      productAccountId: ProductAccountId(session.productAccountId),
      saveIntent: .add(after: nil),
      syncSession: session
    )

    XCTAssertEqual(store.authorization?.credential, "device-only-secret")
    XCTAssertEqual(sync.savedDefinition?.genericMailDefinition, definition)
    XCTAssertEqual(sync.savedDefinition?.connectedAt, 1_781_200_000_600)
    XCTAssertEqual(sync.recreatedDefinition?.genericMailDefinition, definition)
  }

  @MainActor
  // swiftlint:disable:next function_body_length
  func testStaleLocalReauthorizationRequiresASecondExplicitRecreationAction() async {
    let draft = manualDraft()
    let store = RecordingGenericMailAuthorizationStore()
    let localDefinition = GenericMailConnectionDefinition(
      authorizationMethod: draft.authorizationMethod,
      emailAddress: draft.emailAddress,
      incomingEndpoint: draft.incomingEndpoint,
      outgoingEndpoint: draft.outgoingEndpoint,
      roleMappings: draft.roleMappings,
      username: draft.username
    )
    store.authorization = DeviceLocalGenericMailAuthorization(
      credential: "old-secret",
      definition: localDefinition
    )
    let sync = RecordingGenericSyncService(
      removedConnectionIds: [localDefinition.connectionId]
    )
    let removalObservation = MailboxConnectionRemovalObservation(
      connectionId: localDefinition.connectionId,
      removedAt: 1_781_200_000_500
    )
    sync.saveError = MailboxConnectionSyncError.connectionRemoved(removalObservation)
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "product-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId(session.productAccountId),
      isSessionCurrent: { true },
      service: GenericMailSetupService(
        authorizationStore: store,
        definitionSyncService: sync,
        verifier: RecordingGenericMailEndpointVerifier()
      ),
      syncSession: session
    )
    viewModel.emailAddress = draft.emailAddress
    viewModel.loadSaved()
    viewModel.credential = "new-secret"

    await viewModel.connect()

    XCTAssertTrue(viewModel.isConfirmingRecreation)
    XCTAssertNil(sync.recreatedDefinition)
    XCTAssertNil(store.authorization)

    sync.saveError = nil
    viewModel.credential = "new-secret"
    await viewModel.connect()

    XCTAssertEqual(sync.recreatedDefinition?.id, localDefinition.connectionId)
    XCTAssertEqual(sync.recreationObservation, removalObservation)
    XCTAssertFalse(viewModel.isConfirmingRecreation)
  }

  @MainActor
  // swiftlint:disable:next function_body_length
  func testConcurrentGenericMailRecreationClearsStaleConfirmation() async {
    let draft = manualDraft()
    let store = RecordingGenericMailAuthorizationStore()
    let localDefinition = GenericMailConnectionDefinition(
      authorizationMethod: draft.authorizationMethod,
      emailAddress: draft.emailAddress,
      incomingEndpoint: draft.incomingEndpoint,
      outgoingEndpoint: draft.outgoingEndpoint,
      roleMappings: draft.roleMappings,
      username: draft.username
    )
    store.authorization = DeviceLocalGenericMailAuthorization(
      credential: "old-secret",
      definition: localDefinition
    )
    let sync = RecordingGenericSyncService(
      removedConnectionIds: [localDefinition.connectionId]
    )
    let removalObservation = MailboxConnectionRemovalObservation(
      connectionId: localDefinition.connectionId,
      removedAt: 1_781_200_000_500
    )
    sync.saveError = MailboxConnectionSyncError.connectionRemoved(removalObservation)
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "product-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId(session.productAccountId),
      isSessionCurrent: { true },
      service: GenericMailSetupService(
        authorizationStore: store,
        definitionSyncService: sync,
        verifier: RecordingGenericMailEndpointVerifier()
      ),
      syncSession: session
    )
    viewModel.emailAddress = draft.emailAddress
    viewModel.loadSaved()
    viewModel.credential = "new-secret"
    await viewModel.connect()
    XCTAssertTrue(viewModel.isConfirmingRecreation)

    sync.saveError = MailboxConnectionSyncError.concurrentModification
    viewModel.credential = "new-secret"
    await viewModel.connect()

    XCTAssertFalse(viewModel.isConfirmingRecreation)

    sync.saveError = nil
    viewModel.credential = "new-secret"
    await viewModel.connect()

    XCTAssertNil(sync.recreationObservation)
    XCTAssertFalse(viewModel.isConfirmingRecreation)
  }

  func testSyncedReauthorizationWinsAgainstStaleAdapterCleanup() async throws {
    let productAccountId = ProductAccountId("product-account-race-\(UUID().uuidString)")
    let store = RecordingGenericMailAuthorizationStore()
    let sync = RecordingGenericSyncService()
    let syncGate = MailboxConnectionSyncGate()
    let blocker = TestRendezvous()
    let service = GenericMailSetupService(
      authorizationStore: store,
      definitionSyncService: sync,
      syncGate: syncGate,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let connectionId = try service.connectionId(for: manualDraft())
    let cleanup = Task {
      try await syncGate.withLock(connectionId) {
        await blocker.hold()
        try store.remove(productAccountId: productAccountId, connectionId: connectionId)
      }
    }
    await blocker.waitUntilHeld()

    let authorization = Task {
      try await service.authorize(
        draft: manualDraft(),
        credential: "fresh-secret",
        productAccountId: productAccountId,
        syncSession: self.session(productAccountId: productAccountId)
      )
    }
    while sync.savedDefinition == nil {
      await Task.yield()
    }
    await blocker.release()

    let definition = try await authorization.value
    try await cleanup.value
    let saved = try store.load(
      productAccountId: productAccountId,
      connectionId: definition.connectionId
    )

    XCTAssertEqual(saved?.credential, "fresh-secret")
  }

  func testSyncedReauthorizationPurgesStaleGenerationBeforeSavingFreshAuthorization()
    async throws
  {
    let productAccountId = ProductAccountId("product-account-stale-generation")
    let definition = try await GenericMailSetupService(
      authorizationStore: RecordingGenericMailAuthorizationStore(),
      verifier: RecordingGenericMailEndpointVerifier()
    ).authorize(
      draft: manualDraft(),
      credential: "verified-secret",
      productAccountId: productAccountId
    )
    let store = RecordingGenericMailAuthorizationStore()
    try store.save(
      DeviceLocalGenericMailAuthorization(
        authorizationGeneration: 0,
        credential: "stale-secret",
        definition: definition
      ),
      productAccountId: productAccountId
    )
    let sync = RecordingGenericSyncService(
      authorizationCleanupConnectionIds: [definition.connectionId],
      authorizationGeneration: 1,
      definitions: [definition],
      localCleanupGenerations: [definition.connectionId: 1]
    )
    let localStateCleaner = RecordingGenericMailLocalStateCleaner()
    let service = GenericMailSetupService(
      authorizationStore: store,
      definitionSyncService: sync,
      localStateCleaner: localStateCleaner,
      syncGate: MailboxConnectionSyncGate(),
      verifier: RecordingGenericMailEndpointVerifier()
    )

    _ = try await service.authorize(
      draft: manualDraft(),
      credential: "fresh-secret",
      productAccountId: productAccountId,
      syncSession: session(productAccountId: productAccountId)
    )

    XCTAssertEqual(localStateCleaner.clearedConnectionIds, [definition.connectionId])
    XCTAssertEqual(sync.completedCleanupGenerations[definition.connectionId], 1)
    XCTAssertEqual(store.authorization?.authorizationGeneration, 1)
  }

  // swiftlint:disable:next function_body_length
  func testGenericLocalStateCleanupClearsPendingActionsAndOutboxDeliveries() async throws {
    let productAccountId = ProductAccountId("product-account-queued-cleanup")
    let session = session(productAccountId: productAccountId)
    let definition = try await GenericMailSetupService(
      authorizationStore: RecordingGenericMailAuthorizationStore(),
      verifier: RecordingGenericMailEndpointVerifier()
    ).authorize(
      draft: manualDraft(),
      credential: "secret",
      productAccountId: productAccountId
    )
    let connection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: .gmail,
      connectedAt: 1,
      displayName: definition.emailAddress,
      id: definition.connectionId,
      lastVerifiedAt: 1,
      productAccountId: productAccountId,
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1
    )
    let pendingStore = GenericMailPendingActionStore(
      actions: [
        PendingProviderAction(
          action: .markRead,
          attemptCount: 0,
          connectionId: connection.id.rawValue,
          id: UUID(),
          lastErrorDescription: nil,
          messageIds: ["message-1"],
          productAccountId: productAccountId.rawValue,
          providerId: connection.providerId.rawValue,
          providerMailboxIdentity: connection.providerMailboxIdentity.value,
          sequence: 1,
          state: .pending,
          targetProviderMailboxId: nil,
          targetProviderStateIds: nil
        )
      ]
    )
    let outboxStore = GenericMailOutboxStore()
    let outboxService = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: outboxStore
    )
    _ = try await outboxService.enqueue(
      OutgoingMessage(body: "Body", recipient: "reader@example.com", subject: "Subject"),
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    let cacheDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let cleaner = GenericMailLocalStateCleaner(
      authorizationStore: RecordingGenericMailAuthorizationStore(),
      cache: FileGmailMessageBodyCache(rootDirectory: cacheDirectory),
      metadataStore: try SwiftDataIMAPMessageMetadataStore.inMemory(),
      outboxService: outboxService,
      pendingActionService: PendingProviderActionService(store: pendingStore)
    )

    try await cleaner.clear(connectionId: connection.id, session: session)

    let remainingOutboxItems = try await outboxService.items(session: session)
    XCTAssertTrue(try pendingStore.load(productAccountId: productAccountId.rawValue).isEmpty)
    XCTAssertTrue(remainingOutboxItems.isEmpty)
  }

  func testSyncFailureRollsBackNewDeviceAuthorization() async {
    let store = RecordingGenericMailAuthorizationStore()
    let sync = RecordingGenericSyncService()
    sync.saveError = GenericMailSetupTestError.syncUnavailable
    let service = GenericMailSetupService(
      authorizationStore: store,
      definitionSyncService: sync,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "product-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )

    do {
      _ = try await service.authorize(
        draft: manualDraft(),
        credential: "device-only-secret",
        productAccountId: ProductAccountId(session.productAccountId),
        syncSession: session
      )
      XCTFail("Expected Product Sync failure")
    } catch GenericMailSetupTestError.syncUnavailable {
      XCTAssertNil(store.authorization)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testSyncFailureRestoresPreviousDeviceAuthorization() async throws {
    let store = RecordingGenericMailAuthorizationStore()
    let sync = RecordingGenericSyncService()
    let service = GenericMailSetupService(
      authorizationStore: store,
      definitionSyncService: sync,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "product-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )

    _ = try await service.authorize(
      draft: manualDraft(),
      credential: "previous-secret",
      productAccountId: ProductAccountId(session.productAccountId)
    )
    sync.saveError = GenericMailSetupTestError.syncUnavailable

    do {
      _ = try await service.authorize(
        draft: manualDraft(),
        credential: "replacement-secret",
        productAccountId: ProductAccountId(session.productAccountId),
        syncSession: session
      )
      XCTFail("Expected Product Sync failure")
    } catch GenericMailSetupTestError.syncUnavailable {
      XCTAssertEqual(store.authorization?.credential, "previous-secret")
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testSyncFailureRollsBackWhenConcurrentAccountCleanupFails() async throws {
    let productAccountId = ProductAccountId("product-account-cleanup-failure-\(UUID().uuidString)")
    let store = RecordingGenericMailAuthorizationStore()
    let sync = RecordingGenericSyncService()
    let saveStarted = XCTestExpectation(description: "definition save started")
    let saveGate = GenericMailSetupAsyncGate()
    sync.onSave = {
      saveStarted.fulfill()
      try await saveGate.wait(timeout: .seconds(1))
    }
    sync.saveError = GenericMailSetupTestError.syncUnavailable
    let service = GenericMailSetupService(
      authorizationStore: store,
      definitionSyncService: sync,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let sessionState = LockedBoolean(true)

    _ = try await service.authorize(
      draft: manualDraft(),
      credential: "previous-secret",
      productAccountId: productAccountId
    )
    store.clearError = GenericMailSetupTestError.cleanupUnavailable
    let replacement = Task {
      try await service.authorize(
        draft: manualDraft(),
        credential: "replacement-secret",
        productAccountId: productAccountId,
        syncSession: session(productAccountId: productAccountId),
        isSessionCurrent: { sessionState.value }
      )
    }
    await fulfillment(of: [saveStarted], timeout: 1)
    sessionState.value = false

    do {
      try await service.clearLocalAuthorizations(productAccountId: productAccountId)
      XCTFail("Expected account cleanup failure")
    } catch GenericMailSetupTestError.cleanupUnavailable {
    } catch {
      XCTFail("Unexpected cleanup error: \(error)")
    }
    await saveGate.open()

    do {
      _ = try await replacement.value
      XCTFail("Expected Product Sync failure")
    } catch GenericMailSetupTestError.syncUnavailable {
      XCTAssertEqual(store.authorization?.credential, "previous-secret")
    } catch {
      XCTFail("Unexpected authorization error: \(error)")
    }
  }

  func testAuthenticatedUsernamesAtSameAddressAndEndpointsRemainDistinct() async throws {
    let service = GenericMailSetupService(
      authorizationStore: RecordingGenericMailAuthorizationStore(),
      verifier: RecordingGenericMailEndpointVerifier()
    )
    var firstDraft = manualDraft()
    firstDraft.username = "first-user"
    var secondDraft = manualDraft()
    secondDraft.username = "second-user"

    let first = try await service.authorize(
      draft: firstDraft,
      credential: "first-secret",
      productAccountId: ProductAccountId("product-account-001")
    )
    let second = try await service.authorize(
      draft: secondDraft,
      credential: "second-secret",
      productAccountId: ProductAccountId("product-account-001")
    )

    XCTAssertNotEqual(first.connectionId, second.connectionId)
  }

  func testDisplayAliasesForSameAuthenticatedMailboxConverge() async throws {
    let service = GenericMailSetupService(
      authorizationStore: RecordingGenericMailAuthorizationStore(),
      verifier: RecordingGenericMailEndpointVerifier()
    )
    var firstDraft = manualDraft()
    firstDraft.emailAddress = "first-alias@example.com"
    var secondDraft = manualDraft()
    secondDraft.emailAddress = "second-alias@example.com"

    let first = try await service.authorize(
      draft: firstDraft,
      credential: "first-secret",
      productAccountId: ProductAccountId("product-account-001")
    )
    let second = try await service.authorize(
      draft: secondDraft,
      credential: "second-secret",
      productAccountId: ProductAccountId("product-account-001")
    )

    XCTAssertEqual(first.connectionId, second.connectionId)
  }

  @MainActor
  func testSyncedGenericDefinitionAppearsAuthorizationRequiredOnAnotherDevice() async {
    let definition = GenericMailConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "reader@example.com",
      incomingEndpoint: GenericMailEndpoint(
        mailProtocol: .imap,
        hostname: "imap.example.com",
        port: 993,
        security: .implicitTLS
      ),
      outgoingEndpoint: GenericMailEndpoint(
        mailProtocol: .smtp,
        hostname: "smtp.example.com",
        port: 465,
        security: .implicitTLS
      ),
      roleMappings: [.sent: "Sent"],
      username: "reader@example.com"
    )
    let sync = RecordingGenericSyncService(definitions: [definition])
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "second-device-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-002"
    )
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId(session.productAccountId),
      isSessionCurrent: { true },
      service: GenericMailSetupService(
        authorizationStore: RecordingGenericMailAuthorizationStore(),
        definitionSyncService: sync,
        verifier: RecordingGenericMailEndpointVerifier()
      ),
      syncSession: session
    )

    await viewModel.loadSyncedDefinitions()

    XCTAssertEqual(viewModel.syncedDefinitions, [definition])
    XCTAssertFalse(viewModel.isAuthorized(definition))
    XCTAssertEqual(viewModel.emailAddress, definition.emailAddress)
    XCTAssertNil(viewModel.connectedDefinition)
  }

  @MainActor
  func testStaleGenericAuthorizationAppearsAuthorizationRequiredAfterReadd() async {
    let definition = GenericMailConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "reader@example.com",
      incomingEndpoint: GenericMailEndpoint(
        mailProtocol: .imap,
        hostname: "imap.example.com",
        port: 993,
        security: .implicitTLS
      ),
      outgoingEndpoint: GenericMailEndpoint(
        mailProtocol: .smtp,
        hostname: "smtp.example.com",
        port: 465,
        security: .implicitTLS
      ),
      roleMappings: [.sent: "Sent"],
      username: "reader@example.com"
    )
    let store = RecordingGenericMailAuthorizationStore()
    store.authorization = DeviceLocalGenericMailAuthorization(
      authorizationGeneration: 0,
      credential: "device-only-secret",
      definition: definition
    )
    let sync = RecordingGenericSyncService(
      authorizationGeneration: 1,
      definitions: [definition]
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "second-device-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-002"
    )
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId(session.productAccountId),
      isSessionCurrent: { true },
      service: GenericMailSetupService(
        authorizationStore: store,
        definitionSyncService: sync,
        verifier: RecordingGenericMailEndpointVerifier()
      ),
      syncSession: session
    )

    await viewModel.loadSyncedDefinitions()

    XCTAssertFalse(viewModel.isAuthorized(definition))
    XCTAssertNil(viewModel.connectedDefinition)
  }

  @MainActor
  func testRefreshingSyncedDefinitionsPreservesManualSetupDraft() async {
    let definition = GenericMailConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "synced@example.com",
      incomingEndpoint: GenericMailEndpoint(
        mailProtocol: .imap, hostname: "imap.example.com", port: 993, security: .implicitTLS),
      outgoingEndpoint: GenericMailEndpoint(
        mailProtocol: .smtp, hostname: "smtp.example.com", port: 465, security: .implicitTLS),
      roleMappings: [.sent: "Sent"],
      username: "synced@example.com"
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001", identityToken: "product-token",
      productAccountId: "product-account-001", trustedDeviceId: "trusted-device-001"
    )
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId(session.productAccountId),
      isSessionCurrent: { true },
      service: GenericMailSetupService(
        authorizationStore: RecordingGenericMailAuthorizationStore(),
        definitionSyncService: RecordingGenericSyncService(definitions: [definition]),
        verifier: RecordingGenericMailEndpointVerifier()
      ),
      syncSession: session
    )

    await viewModel.loadSyncedDefinitions()
    viewModel.emailAddress = "draft@example.com"
    viewModel.incomingHostname = "draft.imap.example.com"
    await viewModel.loadSyncedDefinitions()

    XCTAssertEqual(viewModel.emailAddress, "draft@example.com")
    XCTAssertEqual(viewModel.incomingHostname, "draft.imap.example.com")
  }

  func testSyncedRemovalPurgesDeviceLocalGenericAuthorization() async throws {
    let definition = GenericMailConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "reader@example.com",
      incomingEndpoint: GenericMailEndpoint(
        mailProtocol: .imap,
        hostname: "imap.example.com",
        port: 993,
        security: .implicitTLS
      ),
      outgoingEndpoint: GenericMailEndpoint(
        mailProtocol: .smtp,
        hostname: "smtp.example.com",
        port: 465,
        security: .implicitTLS
      ),
      roleMappings: [.sent: "Sent"],
      username: "reader@example.com"
    )
    let store = RecordingGenericMailAuthorizationStore()
    store.authorization = DeviceLocalGenericMailAuthorization(
      credential: "device-only-secret",
      definition: definition
    )
    let sync = RecordingGenericSyncService(removedConnectionIds: [definition.connectionId])
    let service = GenericMailSetupService(
      authorizationStore: store,
      definitionSyncService: sync,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "product-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-002"
    )

    _ = try await service.loadSyncedDefinitions(session: session)

    XCTAssertNil(store.authorization)
  }

  func testTrustedDevicesAuthorizeGenericDefinitionIndependently() async throws {
    let sync = RecordingGenericSyncService()
    let firstStore = RecordingGenericMailAuthorizationStore()
    let secondStore = RecordingGenericMailAuthorizationStore()
    let firstService = GenericMailSetupService(
      authorizationStore: firstStore,
      definitionSyncService: sync,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let secondService = GenericMailSetupService(
      authorizationStore: secondStore,
      definitionSyncService: sync,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let firstSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "first-device-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )
    let secondSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "second-device-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-002"
    )

    let firstDefinition = try await firstService.authorize(
      draft: manualDraft(),
      credential: "first-device-secret",
      productAccountId: ProductAccountId(firstSession.productAccountId),
      syncSession: firstSession
    )
    let secondDefinition = try await secondService.authorize(
      draft: manualDraft(),
      credential: "second-device-secret",
      productAccountId: ProductAccountId(secondSession.productAccountId),
      syncSession: secondSession
    )

    XCTAssertEqual(firstDefinition.connectionId, secondDefinition.connectionId)
    XCTAssertEqual(firstStore.authorization?.credential, "first-device-secret")
    XCTAssertEqual(secondStore.authorization?.credential, "second-device-secret")
    XCTAssertEqual(sync.currentSnapshot.connections.count, 1)
  }

  func testGenericRemovalScopesAndDefaultUseSharedDefinition() async throws {
    let sync = RecordingGenericSyncService()
    let store = RecordingGenericMailAuthorizationStore()
    let service = GenericMailSetupService(
      authorizationStore: store,
      definitionSyncService: sync,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "product-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )
    let definition = try await service.authorize(
      draft: manualDraft(),
      credential: "device-only-secret",
      productAccountId: ProductAccountId(session.productAccountId),
      syncSession: session
    )

    try await service.setDefaultSendingConnection(definition, session: session)
    try service.removeLocalAuthorization(
      definition,
      productAccountId: ProductAccountId(session.productAccountId)
    )

    XCTAssertNil(store.authorization)
    XCTAssertEqual(sync.currentSnapshot.connections.count, 1)
    XCTAssertEqual(sync.currentSnapshot.defaultSendingConnectionId, definition.connectionId)

    try await service.removeEverywhere(definition, session: session)

    XCTAssertTrue(sync.currentSnapshot.connections.isEmpty)
    XCTAssertNil(sync.currentSnapshot.defaultSendingConnectionId)
    XCTAssertEqual(sync.currentSnapshot.removedConnectionIds, [definition.connectionId])
  }

  @MainActor
  func testAuthorizedGenericDefinitionRequiresRoutedSendSupportToBecomeDefault() async throws {
    let sync = RecordingGenericSyncService()
    let store = RecordingGenericMailAuthorizationStore()
    let service = GenericMailSetupService(
      authorizationStore: store,
      definitionSyncService: sync,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "product-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )
    let definition = try await service.authorize(
      draft: manualDraft(),
      credential: "device-only-secret",
      productAccountId: ProductAccountId(session.productAccountId),
      syncSession: session
    )
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId(session.productAccountId),
      isSessionCurrent: { true },
      service: service,
      syncSession: session
    )
    await viewModel.loadSyncedDefinitions()

    let didSetUnsupportedDefault = await viewModel.setDefaultSendingConnection(
      definition,
      routedConnections: [routedConnection(definition, capabilities: .imapRead)]
    )

    XCTAssertFalse(didSetUnsupportedDefault)
    XCTAssertNil(viewModel.defaultSendingConnectionId)
    XCTAssertNil(sync.currentSnapshot.defaultSendingConnectionId)

    let didSetDefault = await viewModel.setDefaultSendingConnection(
      definition,
      routedConnections: [routedConnection(definition, capabilities: .gmail)]
    )

    XCTAssertTrue(didSetDefault)
    XCTAssertEqual(viewModel.defaultSendingConnectionId, definition.connectionId)
    XCTAssertEqual(sync.currentSnapshot.defaultSendingConnectionId, definition.connectionId)
  }

  @MainActor
  func testGenericRemovalClearsLocalAuthorizationWhenSyncRemovalFails() async throws {
    let sync = RecordingGenericSyncService()
    let store = RecordingGenericMailAuthorizationStore()
    let service = GenericMailSetupService(
      authorizationStore: store,
      definitionSyncService: sync,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001", identityToken: "product-token",
      productAccountId: "product-account-001", trustedDeviceId: "trusted-device-001"
    )
    let definition = try await service.authorize(
      draft: manualDraft(), credential: "device-only-secret",
      productAccountId: ProductAccountId(session.productAccountId), syncSession: session
    )
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId(session.productAccountId),
      isSessionCurrent: { true },
      service: service,
      syncSession: session
    )
    await viewModel.loadSyncedDefinitions()
    sync.removeError = GenericMailSetupTestError.syncUnavailable

    let didRemoveLocalAuthorization = await viewModel.removeEverywhere(definition)
    let errorMessage = viewModel.errorMessage

    XCTAssertTrue(didRemoveLocalAuthorization)
    XCTAssertNil(store.authorization)
    XCTAssertNotNil(errorMessage)
  }

  func testOpaqueCredentialWhitespaceIsPreservedForAuthenticationAndStorage() async throws {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )

    _ = try await service.authorize(
      draft: manualDraft(),
      credential: "  valid opaque password  ",
      productAccountId: ProductAccountId("product-account-001")
    )

    XCTAssertEqual(
      verifier.credentials,
      ["  valid opaque password  ", "  valid opaque password  "]
    )
    XCTAssertEqual(store.authorization?.credential, "  valid opaque password  ")
  }

  func testTLSVersionBelow12IsRejectedBeforeAuthorizationIsPersisted() async {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    verifier.results = [
      GenericMailEndpointVerification(
        authenticated: true,
        transportVersion: .olderThanTLS12
      )
    ]
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )

    do {
      _ = try await service.authorize(
        draft: manualDraft(),
        credential: "secret",
        productAccountId: ProductAccountId("product-account-001")
      )
      XCTFail("Expected a secure transport failure")
    } catch GenericMailSetupError.secureTransportRequired(.imap) {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertNil(store.authorization)
    XCTAssertEqual(verifier.endpoints.map(\.mailProtocol), [.imap])
  }

  func testCertificateFailureDoesNotPersistAuthorization() async {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    verifier.error = GenericMailSetupTestError.invalidCertificate
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )

    do {
      _ = try await service.authorize(
        draft: manualDraft(),
        credential: "secret",
        productAccountId: ProductAccountId("product-account-001")
      )
      XCTFail("Expected certificate validation to fail")
    } catch GenericMailSetupTestError.invalidCertificate {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertNil(store.authorization)
  }

  func testRejectedAuthenticationDoesNotPersistAuthorization() async {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    verifier.results = [
      GenericMailEndpointVerification(
        authenticated: false,
        transportVersion: .tls12OrNewer
      )
    ]
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )

    do {
      _ = try await service.authorize(
        draft: manualDraft(),
        credential: "secret",
        productAccountId: ProductAccountId("product-account-001")
      )
      XCTFail("Expected authentication to fail")
    } catch GenericMailSetupError.authenticationFailed(.imap) {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertNil(store.authorization)
  }

  func testIMAPRequiresExplicitMailboxRoleMapping() async {
    let store = RecordingGenericMailAuthorizationStore()
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    var draft = manualDraft()
    draft.roleMappings[.sent] = ""

    do {
      _ = try await service.authorize(
        draft: draft,
        credential: "secret",
        productAccountId: ProductAccountId("product-account-001")
      )
      XCTFail("Expected an explicit role mapping failure")
    } catch let GenericMailSetupError.missingRoleMappings(_, missing) {
      XCTAssertEqual(missing, [.sent])
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertNil(store.authorization)
  }

  func testUnambiguousIMAPSpecialUseRolesDoNotRequireManualMapping() async throws {
    let verifier = RecordingGenericMailEndpointVerifier()
    let discoveredRoles = Dictionary(
      uniqueKeysWithValues: CanonicalMailboxRole.allCases.map { role in
        (role, "Provider \(role.displayName)")
      }
    )
    verifier.results = [
      GenericMailEndpointVerification(
        authenticated: true,
        discoveredRoleMappings: discoveredRoles,
        transportVersion: .tls12OrNewer
      )
    ]
    let service = GenericMailSetupService(
      authorizationStore: RecordingGenericMailAuthorizationStore(),
      verifier: verifier
    )
    var draft = manualDraft()
    draft.roleMappings = [:]

    let definition = try await service.authorize(
      draft: draft,
      credential: "secret",
      productAccountId: ProductAccountId("product-account-001")
    )

    XCTAssertEqual(definition.roleMappings, discoveredRoles)
  }

  func testPOP3UsesProductOwnedRolesWithoutPretendingToMapServerFolders() async throws {
    let store = RecordingGenericMailAuthorizationStore()
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    var draft = manualDraft()
    draft.incomingEndpoint = GenericMailEndpoint(
      mailProtocol: .pop3,
      hostname: "pop.example.com",
      port: 995,
      security: .implicitTLS
    )
    draft.roleMappings = [:]

    let definition = try await service.authorize(
      draft: draft,
      credential: "secret",
      productAccountId: ProductAccountId("product-account-001")
    )

    XCTAssertEqual(definition.connectionId.providerId.rawValue, "pop3-smtp")
    XCTAssertTrue(definition.roleMappings.isEmpty)
  }

  func testOAuthCredentialUsesThePreferredXOAUTH2AuthorizationPath() async throws {
    let verifier = RecordingGenericMailEndpointVerifier()
    let service = GenericMailSetupService(
      authorizationStore: RecordingGenericMailAuthorizationStore(),
      verifier: verifier
    )
    var draft = manualDraft()
    draft.authorizationMethod = .oauth

    _ = try await service.authorize(
      draft: draft,
      credential: "oauth-access-token",
      productAccountId: ProductAccountId("product-account-001")
    )

    XCTAssertEqual(verifier.authorizationMethods, [.oauth, .oauth])
  }

  @MainActor
  func testUnknownManualSetupDoesNotAssumeOAuthSupport() {
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true }
    )
    viewModel.emailAddress = "reader@unknown.example"

    viewModel.discover()

    XCTAssertEqual(viewModel.authorizationMethod, .password)
  }

  @MainActor
  func testGenericMailDestructiveActionCancelsMailboxWorkBeforeRemoval() async {
    var events: [String] = []

    await GenericMailSetupPanel.performDestructiveAction(
      cancelMailboxWork: { events.append("cancel") },
      action: {
        events.append("remove")
        return true
      },
      connectionsDidChange: { events.append("notify") }
    )

    XCTAssertEqual(events, ["cancel", "remove", "notify"])
  }

  @MainActor
  func testGenericMailDestructiveActionNotifiesOnlyAfterSuccess() async {
    var events: [String] = []

    await GenericMailSetupPanel.performDestructiveAction(
      cancelMailboxWork: { events.append("cancel failed") },
      action: {
        events.append("failed remove")
        return false
      },
      connectionsDidChange: { events.append("notify") }
    )
    await GenericMailSetupPanel.performDestructiveAction(
      cancelMailboxWork: { events.append("cancel successful") },
      action: {
        events.append("successful remove")
        return true
      },
      connectionsDidChange: { events.append("notify") }
    )

    XCTAssertEqual(
      events,
      [
        "cancel failed",
        "failed remove",
        "cancel successful",
        "successful remove",
        "notify",
      ])
  }

  @MainActor
  func testGenericConnectNotifiesOnlyAfterSuccessfulAuthorization() async {
    var events: [String] = []

    await GenericMailSetupPanel.performConnect(
      connect: {
        events.append("failed connect")
        return false
      },
      connectionsDidChange: { events.append("notify") }
    )
    await GenericMailSetupPanel.performConnect(
      connect: {
        events.append("successful connect")
        return true
      },
      connectionsDidChange: { events.append("notify") }
    )

    XCTAssertEqual(events, ["failed connect", "successful connect", "notify"])
  }

  @MainActor
  func testDiscoveringAnotherMailboxReplacesTheUsernameAndCredential() {
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true }
    )
    viewModel.emailAddress = "first@example.com"
    viewModel.username = "first@example.com"
    viewModel.credential = "first-secret"

    viewModel.emailAddress = "second@example.com"
    viewModel.discover()

    XCTAssertEqual(viewModel.username, "second@example.com")
    XCTAssertEqual(viewModel.credential, "")
  }

  @MainActor
  func testMailboxRoleInputsAppearOnlyAfterVerificationFindsAmbiguity() async {
    let verifier = RecordingGenericMailEndpointVerifier()
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true },
      service: GenericMailSetupService(
        authorizationStore: RecordingGenericMailAuthorizationStore(),
        verifier: verifier
      )
    )
    let draft = manualDraft()
    viewModel.emailAddress = draft.emailAddress
    viewModel.username = draft.username
    viewModel.incomingHostname = draft.incomingEndpoint.hostname
    viewModel.incomingPort = String(draft.incomingEndpoint.port)
    viewModel.outgoingHostname = draft.outgoingEndpoint.hostname
    viewModel.outgoingPort = String(draft.outgoingEndpoint.port)
    viewModel.credential = "secret"
    viewModel.roleMappings = [:]

    XCTAssertFalse(viewModel.showsMailboxRoles)

    await viewModel.connect()

    XCTAssertEqual(viewModel.rolesRequiringMapping, CanonicalMailboxRole.allCases)
    XCTAssertTrue(viewModel.showsMailboxRoles)
  }

  @MainActor
  func testSavedRoleMappingsAreNotReusedAfterEmailAddressChanges() async {
    let oldDefinition = GenericMailConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "old@example.com",
      incomingEndpoint: manualDraft().incomingEndpoint,
      outgoingEndpoint: manualDraft().outgoingEndpoint,
      roleMappings: manualDraft().roleMappings,
      username: "old@example.com"
    )
    let newRoles = Dictionary(
      uniqueKeysWithValues: CanonicalMailboxRole.allCases.map { role in
        (role, "New \(role.displayName)")
      }
    )
    let store = RecordingGenericMailAuthorizationStore()
    store.authorization = DeviceLocalGenericMailAuthorization(
      credential: "old-secret",
      definition: oldDefinition
    )
    let verifier = RecordingGenericMailEndpointVerifier()
    verifier.results = [
      GenericMailEndpointVerification(
        authenticated: true,
        discoveredRoleMappings: newRoles,
        transportVersion: .tls12OrNewer
      )
    ]
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true },
      service: GenericMailSetupService(
        authorizationStore: store,
        verifier: verifier
      )
    )
    viewModel.emailAddress = oldDefinition.emailAddress
    viewModel.loadSaved()

    viewModel.emailAddress = "new@example.com"
    viewModel.username = "new@example.com"
    viewModel.credential = "new-secret"
    await viewModel.connect()

    XCTAssertEqual(viewModel.connectedDefinition?.roleMappings, newRoles)
    XCTAssertFalse(viewModel.showsMailboxRoles)
  }

  func testAccountCleanupClearsEveryDeviceLocalGenericAuthorization() async throws {
    let store = RecordingGenericMailAuthorizationStore()
    store.authorization = DeviceLocalGenericMailAuthorization(
      credential: "secret",
      definition: GenericMailConnectionDefinition(
        authorizationMethod: .password,
        emailAddress: "reader@example.com",
        incomingEndpoint: manualDraft().incomingEndpoint,
        outgoingEndpoint: manualDraft().outgoingEndpoint,
        roleMappings: manualDraft().roleMappings,
        username: "reader@example.com"
      )
    )
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: RecordingGenericMailEndpointVerifier()
    )

    try await service.clearLocalAuthorizations(
      productAccountId: ProductAccountId("product-account-001")
    )

    XCTAssertNil(store.authorization)
    XCTAssertEqual(
      store.clearedProductAccountId,
      ProductAccountId("product-account-001")
    )
  }

  func testProductAccountCleanupClearsBackgroundCategorizationContext() async throws {
    let authorizationStore = RecordingGenericMailAuthorizationStore()
    let backgroundContextCacheStore = RecordingBackgroundContextCacheStore()
    let gmailConnection = RecordingMailboxConnectionClearer()
    let clearer = ProductAccountMailboxConnectionClearer(
      backgroundContextCacheStore: backgroundContextCacheStore,
      genericMailSetupService: GenericMailSetupService(
        authorizationStore: authorizationStore,
        verifier: RecordingGenericMailEndpointVerifier()
      ),
      gmailConnection: gmailConnection
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "identity-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )

    try await clearer.clearLocalConnection(session: session)

    XCTAssertEqual(
      backgroundContextCacheStore.clearedProductAccountId,
      session.productAccountId
    )
    XCTAssertEqual(gmailConnection.clearedSession, session)
  }

  func testSessionChangeDuringVerificationPreventsLateCredentialPersistence() async {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    var isSessionCurrent = true
    verifier.onVerify = { endpoint in
      if endpoint.mailProtocol == .smtp { isSessionCurrent = false }
    }
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )

    do {
      _ = try await service.authorize(
        draft: manualDraft(),
        credential: "secret",
        productAccountId: ProductAccountId("product-account-001"),
        isSessionCurrent: { isSessionCurrent }
      )
      XCTFail("Expected the stale session to cancel persistence")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertNil(store.authorization)
  }

  func testAccountCleanupRacingFinalAuthorizationPersistenceLeavesNoCredential() async throws {
    let productAccountId = ProductAccountId("product-account-race-\(UUID().uuidString)")
    let store = BlockingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )
    let cleanupStarted = XCTestExpectation(description: "account cleanup started")
    let gmailConnection = RecordingMailboxConnectionClearer()
    gmailConnection.onClear = {
      cleanupStarted.fulfill()
    }
    let clearer = ProductAccountMailboxConnectionClearer(
      backgroundContextCacheStore: RecordingBackgroundContextCacheStore(),
      genericMailSetupService: service,
      gmailConnection: gmailConnection
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "identity-token",
      productAccountId: productAccountId.rawValue,
      trustedDeviceId: "trusted-device-001"
    )
    let sessionState = LockedBoolean(true)

    let authorization = Task {
      try await service.authorize(
        draft: manualDraft(),
        credential: "secret",
        productAccountId: productAccountId,
        isSessionCurrent: { sessionState.value }
      )
    }
    await fulfillment(of: [store.loadStarted], timeout: 1)
    sessionState.value = false
    let cleanup = Task {
      try await clearer.clearLocalConnection(session: session)
    }
    await fulfillment(of: [cleanupStarted], timeout: 1)
    store.resumeLoad()

    do {
      _ = try await authorization.value
    } catch is CancellationError {
      // Cleanup advanced the authorization generation before the final save.
    }
    try await cleanup.value

    XCTAssertNil(store.authorization)
  }

  func testCancellationWhileWaitingToPersistDoesNotReplaceAuthorization() async throws {
    let productAccountId = ProductAccountId("product-account-cancellation-\(UUID().uuidString)")
    let store = BlockingGenericMailAuthorizationStore()
    let authorizationCoordinator = GenericMailAuthorizationCoordinator()
    let service = GenericMailSetupService(
      authorizationStore: store,
      authorizationCoordinator: authorizationCoordinator,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let firstAuthorization = Task {
      try await service.authorize(
        draft: manualDraft(),
        credential: "first-secret",
        productAccountId: productAccountId
      )
    }
    await fulfillment(of: [store.loadStarted], timeout: 1)
    let cancelledAuthorization = Task {
      try await service.authorize(
        draft: manualDraft(),
        credential: "cancelled-secret",
        productAccountId: productAccountId
      )
    }
    try await authorizationCoordinator.waitUntilContended(productAccountId: productAccountId)
    cancelledAuthorization.cancel()
    store.resumeLoad()

    _ = try await firstAuthorization.value
    do {
      _ = try await cancelledAuthorization.value
      XCTFail("Expected cancellation while waiting to persist")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertEqual(store.authorization?.credential, "first-secret")
  }

  func testKeychainStoreRoundTripsAndClearsDeviceLocalAuthorization() throws {
    let store = KeychainGenericMailAuthorizationStore()
    let productAccountId = ProductAccountId("generic-mail-test-\(UUID().uuidString)")
    let definition = GenericMailConnectionDefinition(
      authorizationMethod: .appPassword,
      emailAddress: "reader@example.com",
      incomingEndpoint: manualDraft().incomingEndpoint,
      outgoingEndpoint: manualDraft().outgoingEndpoint,
      roleMappings: manualDraft().roleMappings,
      username: "reader@example.com"
    )
    let authorization = DeviceLocalGenericMailAuthorization(
      credential: "app-password",
      definition: definition
    )
    defer { try? store.clearAll(productAccountId: productAccountId) }

    try store.save(authorization, productAccountId: productAccountId)

    XCTAssertEqual(
      try store.load(
        productAccountId: productAccountId,
        emailAddress: definition.emailAddress
      ),
      authorization
    )
    try store.clearAll(productAccountId: productAccountId)
    XCTAssertNil(
      try store.load(
        productAccountId: productAccountId,
        emailAddress: definition.emailAddress
      )
    )
  }

  @MainActor
  func testSavedSetupCanBeLoadedForLaterRoleChanges() {
    let store = RecordingGenericMailAuthorizationStore()
    let definition = GenericMailConnectionDefinition(
      authorizationMethod: .appPassword,
      emailAddress: "reader@example.com",
      incomingEndpoint: manualDraft().incomingEndpoint,
      outgoingEndpoint: manualDraft().outgoingEndpoint,
      roleMappings: manualDraft().roleMappings,
      username: "reader@example.com"
    )
    store.authorization = DeviceLocalGenericMailAuthorization(
      credential: "secret",
      definition: definition
    )
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true },
      service: GenericMailSetupService(
        authorizationStore: store,
        verifier: RecordingGenericMailEndpointVerifier()
      )
    )
    viewModel.emailAddress = definition.emailAddress

    viewModel.loadSaved()
    viewModel.roleMappings[.sent] = "Changed Sent"

    XCTAssertEqual(viewModel.incomingHostname, definition.incomingEndpoint.hostname)
    XCTAssertEqual(viewModel.roleMappings[.sent], "Changed Sent")
    XCTAssertEqual(viewModel.credential, "")
  }

  func testSystemVerifierCompletesSTARTTLSBeforeSMTPAuthorization() async throws {
    let stream = ScriptedGenericMailStreamTask(responses: [
      .success("220 ready\r\n"),
      .success("250-example\r\n250 STARTTLS\r\n"),
      .success("220 begin TLS\r\n250 injected before TLS\r\n"),
      .success("250 AUTH PLAIN\r\n"),
      .success("235 authenticated\r\n"),
    ])
    let factory = RecordingGenericMailStreamTaskFactory(stream: stream)
    let verifier = SystemGenericMailEndpointVerifier(streamTaskFactory: factory)

    _ = try await verifier.verify(
      endpoint: GenericMailEndpoint(
        mailProtocol: .smtp,
        hostname: "smtp.example.com",
        port: 587,
        security: .startTLS
      ),
      username: "reader@example.com",
      credential: "secret",
      authorizationMethod: .password
    )

    let secureIndex = try XCTUnwrap(stream.events.firstIndex(of: .startSecureConnection))
    let authorizationIndex = try XCTUnwrap(
      stream.events.firstIndex(where: { event in
        guard case .write(let value) = event else { return false }
        return value.hasPrefix("AUTH PLAIN")
      })
    )
    XCTAssertLessThan(secureIndex, authorizationIndex)
    XCTAssertEqual(factory.minimumTransportVersion, .tls12OrNewer)
  }

  func testSystemVerifierReturnsSMTPAuthenticationFailureWithoutWaitingForTimeout() async {
    let stream = ScriptedGenericMailStreamTask(responses: [
      .success("220 ready\r\n"),
      .success("250 AUTH PLAIN\r\n"),
      .success("535 authentication rejected\r\n"),
    ])
    let verifier = SystemGenericMailEndpointVerifier(
      streamTaskFactory: RecordingGenericMailStreamTaskFactory(stream: stream)
    )

    do {
      _ = try await verifier.verify(
        endpoint: GenericMailEndpoint(
          mailProtocol: .smtp,
          hostname: "smtp.example.com",
          port: 465,
          security: .implicitTLS
        ),
        username: "reader@example.com",
        credential: "secret",
        authorizationMethod: .password
      )
      XCTFail("Expected SMTP authentication to fail")
    } catch let error as GenericMailSetupError {
      XCTAssertEqual(error, .authenticationFailed(.smtp))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testSystemVerifierBuffersFragmentedPOP3Responses() async throws {
    let stream = ScriptedGenericMailStreamTask(responses: [
      .success("+"), .success("OK ready\r\n"),
      .success("+O"), .success("K user\r\n"),
      .success("+OK authenticated\r\n"),
      .success("+OK authenticated\r\n"),
    ])
    let verifier = SystemGenericMailEndpointVerifier(
      streamTaskFactory: RecordingGenericMailStreamTaskFactory(stream: stream)
    )

    _ = try await verifier.verify(
      endpoint: GenericMailEndpoint(
        mailProtocol: .pop3,
        hostname: "pop.example.com",
        port: 110,
        security: .startTLS
      ),
      username: "reader@example.com",
      credential: "secret",
      authorizationMethod: .password
    )
  }

  func testSystemVerifierSurfacesCertificateFailureBeforeAuthorization() async {
    let stream = ScriptedGenericMailStreamTask(responses: [
      .failure(URLError(.serverCertificateUntrusted))
    ])
    let verifier = SystemGenericMailEndpointVerifier(
      streamTaskFactory: RecordingGenericMailStreamTaskFactory(stream: stream)
    )

    do {
      _ = try await verifier.verify(
        endpoint: GenericMailEndpoint(
          mailProtocol: .imap,
          hostname: "imap.example.com",
          port: 993,
          security: .implicitTLS
        ),
        username: "reader@example.com",
        credential: "secret",
        authorizationMethod: .password
      )
      XCTFail("Expected system trust validation to fail")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .serverCertificateUntrusted)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertFalse(
      stream.events.contains(where: { event in
        guard case .write = event else { return false }
        return true
      })
    )
  }

  func testSystemVerifierReadsUnambiguousIMAPSpecialUseRoles() async throws {
    let stream = ScriptedGenericMailStreamTask(responses: [
      .success("* OK ready\r\n"),
      .success("a2 OK authenticated\r\n"),
      .success(
        "* LIST (\\Drafts) \"/\" \"Drafts\"\r\n"
          + "* LIST (\\Sent) \"/\" \"Sent Items\"\r\n"
          + "* LIST (\\Archive) \"/\" \"Archive\"\r\n"
          + "* LIST (\\Junk) \"/\" \"Junk\"\r\n"
          + "* LIST (\\Trash) \"/\" \"Deleted\"\r\n"
          + "a3 OK listed\r\n"
      ),
    ])
    let verifier = SystemGenericMailEndpointVerifier(
      streamTaskFactory: RecordingGenericMailStreamTaskFactory(stream: stream)
    )

    let verification = try await verifier.verify(
      endpoint: GenericMailEndpoint(
        mailProtocol: .imap,
        hostname: "imap.example.com",
        port: 993,
        security: .implicitTLS
      ),
      username: "reader@example.com",
      credential: "secret",
      authorizationMethod: .password
    )

    XCTAssertEqual(verification.discoveredRoleMappings[.sent], "Sent Items")
    XCTAssertEqual(verification.discoveredRoleMappings[.trash], "Deleted")
  }

  func testSystemVerifierReadsUnquotedIMAPSpecialUseRole() async throws {
    let stream = ScriptedGenericMailStreamTask(responses: [
      .success("* OK ready\r\n"),
      .success("a2 OK authenticated\r\n"),
      .success("* LIST (\\Sent) \"/\" Sent\r\na3 OK listed\r\n"),
    ])
    let verifier = SystemGenericMailEndpointVerifier(
      streamTaskFactory: RecordingGenericMailStreamTaskFactory(stream: stream)
    )

    let verification = try await verifier.verify(
      endpoint: GenericMailEndpoint(
        mailProtocol: .imap,
        hostname: "imap.example.com",
        port: 993,
        security: .implicitTLS
      ),
      username: "reader@example.com",
      credential: "secret",
      authorizationMethod: .password
    )

    XCTAssertEqual(verification.discoveredRoleMappings[.sent], "Sent")
  }

  func testSystemVerifierRespondsToIMAPOAuthContinuation() async {
    let stream = ScriptedGenericMailStreamTask(responses: [
      .success("* OK ready\r\n"),
      .success("+ token expired\r\n"),
      .success("a2 NO authentication failed\r\n"),
    ])
    let verifier = SystemGenericMailEndpointVerifier(
      streamTaskFactory: RecordingGenericMailStreamTaskFactory(stream: stream)
    )

    do {
      _ = try await verifier.verify(
        endpoint: GenericMailEndpoint(
          mailProtocol: .imap,
          hostname: "imap.example.com",
          port: 993,
          security: .implicitTLS
        ),
        username: "reader@example.com",
        credential: "expired-token",
        authorizationMethod: .oauth
      )
      XCTFail("Expected authentication failure")
    } catch GenericMailSetupError.authenticationFailed(.imap) {
      XCTAssertTrue(stream.events.contains(.write("\r\n")))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testSystemVerifierClosesStreamWhenCancelled() async {
    let stream = BlockingGenericMailStreamTask()
    let verifier = SystemGenericMailEndpointVerifier(
      streamTaskFactory: RecordingGenericMailStreamTaskFactory(stream: stream)
    )
    let verification = Task {
      try await verifier.verify(
        endpoint: GenericMailEndpoint(
          mailProtocol: .imap,
          hostname: "imap.example.com",
          port: 993,
          security: .implicitTLS
        ),
        username: "reader@example.com",
        credential: "secret",
        authorizationMethod: .password
      )
    }

    await fulfillment(of: [stream.readStarted], timeout: 1)
    verification.cancel()
    let completed = XCTestExpectation(description: "verification completed after cancellation")
    Task {
      do {
        _ = try await verification.value
        XCTFail("Expected cancellation")
      } catch is CancellationError {} catch {
        XCTFail("Unexpected error: \(error)")
      }
      completed.fulfill()
    }
    await fulfillment(of: [completed], timeout: 1)
    XCTAssertGreaterThanOrEqual(stream.closeCount, 1)
  }

  func testSensitiveSetupDataStaysInsideDeviceLocalCollaborators() async throws {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    let definition = try await GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    ).authorize(
      draft: manualDraft(),
      credential: "device-only-secret",
      productAccountId: ProductAccountId("product-account-001")
    )
    let encoded = try JSONEncoder().encode(definition)
    let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

    XCTAssertEqual(verifier.usernames, ["reader@example.com", "reader@example.com"])
    XCTAssertEqual(verifier.credentials, ["device-only-secret", "device-only-secret"])
    XCTAssertEqual(
      verifier.endpoints.map(\.hostname),
      ["imap.example.com", "smtp.example.com"]
    )
    XCTAssertEqual(store.authorization?.definition.emailAddress, "reader@example.com")
    XCTAssertEqual(store.authorization?.credential, "device-only-secret")
    XCTAssertFalse(json.contains("product-account-001"))
    XCTAssertFalse(json.contains("identity-token"))
    XCTAssertFalse(json.contains("trusted-device"))
    XCTAssertFalse(json.contains("device-only-secret"))
  }

  private func manualDraft() -> GenericMailSetupDraft {
    GenericMailSetupDraft(
      authorizationMethod: .password,
      emailAddress: "reader@example.com",
      incomingEndpoint: GenericMailEndpoint(
        mailProtocol: .imap,
        hostname: "imap.example.com",
        port: 993,
        security: .implicitTLS
      ),
      outgoingEndpoint: GenericMailEndpoint(
        mailProtocol: .smtp,
        hostname: "smtp.example.com",
        port: 587,
        security: .startTLS
      ),
      roleMappings: Dictionary(
        uniqueKeysWithValues: CanonicalMailboxRole.allCases.map { role in
          (role, "Server \(role.displayName)")
        }
      ),
      username: "reader@example.com"
    )
  }

  private func routedConnection(
    _ definition: GenericMailConnectionDefinition,
    capabilities: MailboxConnectionCapabilities
  ) -> MailboxConnection {
    MailboxConnection(
      authorizationState: .authorized,
      capabilities: capabilities,
      connectedAt: 1,
      displayName: definition.emailAddress,
      id: definition.connectionId,
      lastVerifiedAt: 1,
      productAccountId: ProductAccountId("product-account-001"),
      trustedDeviceId: "trusted-device-001",
      updatedAt: 1
    )
  }

  private func session(productAccountId: ProductAccountId) -> ProductAccountSessionSnapshot {
    ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "product-token",
      productAccountId: productAccountId.rawValue,
      trustedDeviceId: "trusted-device-001"
    )
  }
}

private final class RecordingGenericMailEndpointVerifier: GenericMailEndpointVerifying {
  var authorizationMethods: [MailAuthorizationMethod] = []
  var credentials: [String] = []
  var endpoints: [GenericMailEndpoint] = []
  var error: Error?
  var onVerify: ((GenericMailEndpoint) -> Void)?
  var results: [GenericMailEndpointVerification] = []

  func verify(
    endpoint: GenericMailEndpoint,
    username: String,
    credential: String,
    authorizationMethod: MailAuthorizationMethod
  ) async throws -> GenericMailEndpointVerification {
    endpoints.append(endpoint)
    authorizationMethods.append(authorizationMethod)
    credentials.append(credential)
    usernames.append(username)
    onVerify?(endpoint)
    if let error { throw error }
    if !results.isEmpty { return results.removeFirst() }
    return GenericMailEndpointVerification(
      authenticated: true,
      transportVersion: .tls12OrNewer
    )
  }

  var usernames: [String] = []
}

private final class RecordingGenericMailAuthorizationStore: GenericMailAuthorizationPersisting {
  var authorization: DeviceLocalGenericMailAuthorization?
  var clearError: Error?
  var clearedProductAccountId: ProductAccountId?
  var productAccountId: ProductAccountId?

  func clearAll(productAccountId: ProductAccountId) throws {
    if let clearError { throw clearError }
    authorization = nil
    clearedProductAccountId = productAccountId
  }

  func load(
    productAccountId _: ProductAccountId,
    emailAddress _: String
  ) throws -> DeviceLocalGenericMailAuthorization? {
    authorization
  }

  func load(
    productAccountId _: ProductAccountId,
    connectionId: MailboxConnectionId
  ) throws -> DeviceLocalGenericMailAuthorization? {
    authorization?.definition.connectionId == connectionId ? authorization : nil
  }

  func remove(
    productAccountId: ProductAccountId,
    connectionId _: MailboxConnectionId
  ) throws {
    authorization = nil
    self.productAccountId = productAccountId
  }

  func save(
    _ authorization: DeviceLocalGenericMailAuthorization,
    productAccountId: ProductAccountId
  ) throws {
    self.authorization = authorization
    self.productAccountId = productAccountId
  }
}

private final class BlockingGenericMailAuthorizationStore:
  GenericMailAuthorizationPersisting, @unchecked Sendable
{
  let loadStarted = XCTestExpectation(description: "authorization load started")

  private var storedAuthorization: DeviceLocalGenericMailAuthorization?
  private let lock = NSLock()
  private let loadRelease = DispatchSemaphore(value: 0)
  private var shouldBlockLoad = true

  var authorization: DeviceLocalGenericMailAuthorization? {
    lock.withLock { storedAuthorization }
  }

  func clearAll(productAccountId _: ProductAccountId) throws {
    lock.withLock {
      storedAuthorization = nil
    }
  }

  func load(
    productAccountId _: ProductAccountId,
    emailAddress _: String
  ) throws -> DeviceLocalGenericMailAuthorization? {
    authorization
  }

  func load(
    productAccountId _: ProductAccountId,
    connectionId _: MailboxConnectionId
  ) throws -> DeviceLocalGenericMailAuthorization? {
    let shouldBlock = lock.withLock {
      defer { shouldBlockLoad = false }
      return shouldBlockLoad
    }
    if shouldBlock {
      loadStarted.fulfill()
      loadRelease.wait()
    }
    return authorization
  }

  func remove(
    productAccountId _: ProductAccountId,
    connectionId _: MailboxConnectionId
  ) throws {
    lock.withLock {
      storedAuthorization = nil
    }
  }

  func save(
    _ authorization: DeviceLocalGenericMailAuthorization,
    productAccountId _: ProductAccountId
  ) throws {
    lock.withLock {
      storedAuthorization = authorization
    }
  }

  func resumeLoad() {
    loadRelease.signal()
  }
}

private final class LockedBoolean: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Bool

  init(_ value: Bool) {
    storedValue = value
  }

  var value: Bool {
    get {
      lock.withLock { storedValue }
    }
    set {
      lock.withLock {
        storedValue = newValue
      }
    }
  }
}

private final class RecordingBackgroundContextCacheStore:
  BackgroundContextCachePersisting
{
  var clearedProductAccountId: String?

  func clear(productAccountId: String) throws {
    clearedProductAccountId = productAccountId
  }

  func clear(productAccountId _: String, providerAccountIdentifier _: String) throws {}

  func load(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> BackgroundCategorizationContextCache? {
    nil
  }

  func save(
    _ cache: BackgroundCategorizationContextCache,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}
}

private final class RecordingMailboxConnectionClearer: MailboxConnectionClearing {
  var clearedSession: ProductAccountSessionSnapshot?
  var onClear: (() -> Void)?

  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws {
    onClear?()
    clearedSession = session
  }

  func clearLocalConnection(
    _: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    clearedSession = session
  }
}

private final class RecordingGenericSyncService:
  MailboxConnectionDefinitionSyncing
{
  var completedCleanupGenerations: [MailboxConnectionId: Int] = [:]
  var onSave: (() async throws -> Void)?
  var recreatedDefinition: MailboxConnectionDefinition?
  var recreationObservation: MailboxConnectionRemovalObservation?
  var saveError: Error?
  var removeError: Error?
  var savedDefinition: MailboxConnectionDefinition?
  private var snapshot: MailboxConnectionSyncSnapshot

  var currentSnapshot: MailboxConnectionSyncSnapshot { snapshot }

  init(
    authorizationCleanupConnectionIds: [MailboxConnectionId] = [],
    authorizationGeneration: Int = 0,
    definitions: [GenericMailConnectionDefinition] = [],
    localCleanupGenerations: [MailboxConnectionId: Int] = [:],
    removedConnectionIds: [MailboxConnectionId] = []
  ) {
    snapshot = MailboxConnectionSyncSnapshot(
      connections: definitions.map {
        $0.synchronizedDefinition(
          authorizationGeneration: authorizationGeneration,
          connectedAt: 1
        )
      },
      defaultSendingConnectionId: nil,
      removedConnectionIds: removedConnectionIds,
      updatedAt: definitions.isEmpty && removedConnectionIds.isEmpty ? nil : 1,
      authorizationCleanupConnectionIds: authorizationCleanupConnectionIds,
      localCleanupGenerations: localCleanupGenerations
    )
  }

  func completedLocalCleanupGeneration(
    _ connectionId: MailboxConnectionId,
    session _: ProductAccountSessionSnapshot
  ) throws -> Int? {
    completedCleanupGenerations[connectionId]
  }

  func recordLocalCleanup(
    _ connectionId: MailboxConnectionId,
    generation: Int,
    session _: ProductAccountSessionSnapshot
  ) throws {
    completedCleanupGenerations[connectionId] = generation
  }

  func loadSnapshot(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    snapshot
  }

  func reconcileConnections(
    _ connections: [MailboxConnectionDefinition],
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    for connection in connections where !snapshot.connections.contains(connection) {
      snapshot = replacingConnections(snapshot.connections + [connection])
    }
    return snapshot
  }

  func removeConnection(
    _ connectionId: MailboxConnectionId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    if let removeError { throw removeError }
    snapshot = MailboxConnectionSyncSnapshot(
      connections: snapshot.connections.filter { $0.id != connectionId },
      defaultSendingConnectionId: snapshot.defaultSendingConnectionId == connectionId
        ? nil : snapshot.defaultSendingConnectionId,
      removedConnectionIds: snapshot.removedConnectionIds + [connectionId],
      updatedAt: 1
    )
    return snapshot
  }

  func recreateDefinition(
    _ definition: MailboxConnectionDefinition,
    after removalObservation: MailboxConnectionRemovalObservation?,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    recreatedDefinition = definition
    recreationObservation = removalObservation
    _ = try await saveDefinition(definition, session: session)
    snapshot = MailboxConnectionSyncSnapshot(
      connections: snapshot.connections,
      defaultSendingConnectionId: snapshot.defaultSendingConnectionId,
      removedConnectionIds: snapshot.removedConnectionIds.filter { $0 != definition.id },
      updatedAt: snapshot.updatedAt
    )
    return snapshot
  }

  func saveConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    try await saveDefinition(connection.definition, session: session)
  }

  func saveDefinition(
    _ definition: MailboxConnectionDefinition,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    try await onSave?()
    if let saveError { throw saveError }
    let existingGeneration =
      snapshot.connections.first(where: { $0.id == definition.id })?
      .authorizationGeneration
      ?? definition.authorizationGeneration
    let retainedDefinition = definition.withAuthorizationGeneration(
      max(existingGeneration, definition.authorizationGeneration)
    )
    savedDefinition = retainedDefinition
    snapshot = replacingConnections(
      snapshot.connections.filter { $0.id != definition.id } + [retainedDefinition]
    )
    return snapshot
  }

  func setDefaultSendingConnection(
    _ connectionId: MailboxConnectionId?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    snapshot = MailboxConnectionSyncSnapshot(
      connections: snapshot.connections,
      defaultSendingConnectionId: connectionId,
      removedConnectionIds: snapshot.removedConnectionIds,
      updatedAt: snapshot.updatedAt
    )
    return snapshot
  }

  private func replacingConnections(
    _ connections: [MailboxConnectionDefinition]
  ) -> MailboxConnectionSyncSnapshot {
    MailboxConnectionSyncSnapshot(
      connections: connections,
      defaultSendingConnectionId: snapshot.defaultSendingConnectionId,
      removedConnectionIds: snapshot.removedConnectionIds,
      updatedAt: 1,
      authorizationCleanupConnectionIds: snapshot.authorizationCleanupConnectionIds,
      localCleanupGenerations: snapshot.localCleanupGenerations
    )
  }
}

private final class RecordingGenericMailLocalStateCleaner: GenericMailLocalStateClearing {
  var clearedConnectionIds: [MailboxConnectionId] = []

  func clear(
    connectionId: MailboxConnectionId,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    clearedConnectionIds.append(connectionId)
  }
}

private final class GenericMailPendingActionStore: PendingProviderActionPersisting {
  var actions: [PendingProviderAction]

  init(actions: [PendingProviderAction]) {
    self.actions = actions
  }

  func load(productAccountId _: String) throws -> [PendingProviderAction] {
    actions
  }

  func save(
    _ actions: [PendingProviderAction],
    productAccountId _: String
  ) throws {
    self.actions = actions
  }
}

private final class GenericMailOutboxStore: OutboxDeliveryPersisting {
  var attempts: [OutgoingDeliveryAttempt] = []

  func load(productAccountId _: String) throws -> [OutgoingDeliveryAttempt] {
    attempts
  }

  func save(
    _ attempts: [OutgoingDeliveryAttempt],
    productAccountId _: String
  ) throws {
    self.attempts = attempts
  }
}

private actor GenericMailSetupAsyncGate {
  private typealias Waiter = (id: UUID, continuation: CheckedContinuation<Bool, Never>)

  private var isOpen = false
  private var waiters: [Waiter] = []

  func wait(timeout: Duration) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        guard await self.wait() else { throw CancellationError() }
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw GenericMailSetupTestError.timeout
      }
      guard let result = await group.nextResult() else { return }
      group.cancelAll()
      while await group.nextResult() != nil {}
      try result.get()
    }
  }

  func open() {
    isOpen = true
    let continuations = waiters.map(\.continuation)
    waiters.removeAll()
    for continuation in continuations {
      continuation.resume(returning: true)
    }
  }

  private func wait() async -> Bool {
    guard !isOpen else { return true }
    let waiterId = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        waiters.append((waiterId, continuation))
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterId) }
    }
  }

  private func cancelWaiter(_ waiterId: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == waiterId }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(returning: false)
  }
}

private enum GenericMailSetupTestError: Error {
  case cleanupUnavailable
  case invalidCertificate
  case syncUnavailable
  case timeout
}

private enum GenericMailStreamEvent: Equatable {
  case close
  case read
  case resume
  case startSecureConnection
  case write(String)
}

private final class ScriptedGenericMailStreamTask: GenericMailStreamTasking {
  var events: [GenericMailStreamEvent] = []
  private var responses: [Result<String, Error>]

  init(responses: [Result<String, Error>]) {
    self.responses = responses
  }

  func close() {
    events.append(.close)
  }

  func read() async throws -> String {
    events.append(.read)
    return try responses.removeFirst().get()
  }

  func resume() {
    events.append(.resume)
  }

  func startSecureConnection() {
    events.append(.startSecureConnection)
  }

  func write(_ value: String) async throws {
    events.append(.write(value))
  }
}

private final class BlockingGenericMailStreamTask: GenericMailStreamTasking {
  let readStarted = XCTestExpectation(description: "stream read started")
  private let lock = NSLock()
  private var readContinuation: CheckedContinuation<String, Error>?
  private var recordedCloseCount = 0
  private var isClosed = false

  var closeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return recordedCloseCount
  }

  func close() {
    lock.lock()
    recordedCloseCount += 1
    isClosed = true
    let continuation = readContinuation
    readContinuation = nil
    lock.unlock()
    continuation?.resume(throwing: CancellationError())
  }

  func read() async throws -> String {
    return try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      let wasClosed = isClosed
      if wasClosed {
        readContinuation = nil
      } else {
        readContinuation = continuation
      }
      lock.unlock()
      if wasClosed {
        continuation.resume(throwing: CancellationError())
      }
      readStarted.fulfill()
    }
  }

  func resume() {}
  func startSecureConnection() {}
  func write(_: String) async throws {}
}

private final class RecordingGenericMailStreamTaskFactory: GenericMailStreamTaskCreating {
  var minimumTransportVersion: MailTransportVersion?
  private let stream: GenericMailStreamTasking

  init(stream: GenericMailStreamTasking) {
    self.stream = stream
  }

  func makeStreamTask(
    hostname _: String,
    port _: Int,
    minimumTransportVersion: MailTransportVersion
  ) -> GenericMailStreamTasking {
    self.minimumTransportVersion = minimumTransportVersion
    return stream
  }
}
