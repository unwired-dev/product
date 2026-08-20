import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
@Suite(.serialized)
final class GenericMailSetupServiceTests {
  @MainActor
  @Test
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

    #expect(connections.map(\.id) == [definition.connectionId])
    #expect(connections.first?.authorizationState == .authorized)
    #expect(connections.first?.providerId == .pop3SMTP)
  }

  @MainActor
  @Test
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

    #expect(viewModel.syncedDefinitions[0].connectionId == definition.connectionId)
    #expect(viewModel.connectionReloadKey != initialKey)
  }

  @MainActor
  @Test
  func testGenericMailDiscardRestoresTheSavedEditorBaseline() {
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true }
    )

    #expect(!(viewModel.hasUnsavedChanges))
    viewModel.emailAddress = "draft@example.com"
    viewModel.incomingHostname = "imap.example.com"
    #expect(viewModel.hasUnsavedChanges)

    viewModel.discardUnsavedChanges()

    #expect(!(viewModel.hasUnsavedChanges))
    #expect(viewModel.emailAddress == "")
    #expect(viewModel.incomingHostname == "")
  }

  @MainActor
  @Test
  func testGenericMailConnectStopsWhenTrustedDeviceRevalidationFails() async {
    var revalidationCount = 0
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true },
      revalidateTrustedDevice: {
        revalidationCount += 1
        return false
      }
    )

    let connected = await viewModel.connect()

    #expect(!(connected))
    #expect(revalidationCount == 1)
  }

  @MainActor
  @Test
  func testGenericMailConnectUsesTheRefreshedSession() async {
    let productAccountId = ProductAccountId("product-account-001")
    let initialSession = session(productAccountId: productAccountId)
    let refreshedSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: initialSession.appleUserIdentifier,
      identityToken: "refreshed-product-token",
      productAccountId: initialSession.productAccountId,
      trustedDeviceId: initialSession.trustedDeviceId
    )
    var currentSession = initialSession
    let verifier = RecordingGenericMailEndpointVerifier()
    verifier.results = [
      GenericMailEndpointVerification(
        authenticated: true,
        discoveredRoleMappings: Dictionary(
          uniqueKeysWithValues: CanonicalMailboxRole.allCases.map { role in
            (role, "Provider \(role.displayName)")
          }
        ),
        transportVersion: .tls12OrNewer
      )
    ]
    let sync = RecordingGenericSyncService()
    let viewModel = GenericMailSetupViewModel(
      productAccountId: productAccountId,
      isSessionCurrent: { currentSession == initialSession },
      isSyncSessionCurrent: { $0 == currentSession },
      service: GenericMailSetupService(
        authorizationStore: RecordingGenericMailAuthorizationStore(),
        definitionSyncService: sync,
        verifier: verifier
      ),
      syncSession: initialSession
    )
    viewModel.emailAddress = "reader@fastmail.com"
    viewModel.discover()
    viewModel.credential = "device-only-secret"

    currentSession = refreshedSession
    viewModel.updateSession(refreshedSession)

    let connected = await viewModel.connect()

    #expect(connected)
    #expect(sync.savedSession == refreshedSession)
  }

  @MainActor
  @Test
  func testGenericMailDiscardRestoresTheSelectedConnectionSaveIntent() async {
    let draft = manualDraft()
    let definition = GenericMailConnectionDefinition(
      authorizationMethod: draft.authorizationMethod,
      emailAddress: draft.emailAddress,
      incomingEndpoint: draft.incomingEndpoint,
      outgoingEndpoint: draft.outgoingEndpoint,
      roleMappings: draft.roleMappings,
      username: draft.username
    )
    let sync = RecordingGenericSyncService(definitions: [definition])
    let session = session(productAccountId: ProductAccountId("product-account-001"))
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

    viewModel.discover()
    #expect(viewModel.hasUnsavedChanges)
    viewModel.discardUnsavedChanges()
    viewModel.credential = "device-only-secret"

    let connected = await viewModel.connect()
    #expect(connected)
    #expect(sync.savedDefinition?.genericMailDefinition == definition)
    #expect(sync.recreatedDefinition == nil)
  }

  @Test
  func testReviewedCatalogDiscoversIMAPSMTPAndPOP3Locally() {
    let catalog = BundledMailProviderCatalog()

    let fastmail = catalog.discover(emailAddress: "reader@fastmail.com")
    let iCloud = catalog.discover(emailAddress: "reader@icloud.com")

    #expect(fastmail?.incomingEndpoints.map(\.mailProtocol) == [.imap, .pop3])
    #expect(fastmail?.outgoingEndpoint.mailProtocol == .smtp)
    #expect(fastmail?.outgoingEndpoint.security == .implicitTLS)
    #expect(fastmail?.preferredAuthorizationMethod == .appPassword)
    #expect(iCloud?.incomingEndpoints.map(\.mailProtocol) == [.imap])
    #expect(iCloud?.outgoingEndpoint.security == .startTLS)
    #expect(catalog.discover(emailAddress: "reader@unknown.example") == nil)
  }

  @MainActor
  @Test
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

    #expect(viewModel.incomingHostname == "pop.fastmail.com")
    #expect(viewModel.incomingPort == "995")
    #expect(viewModel.incomingSecurity == .implicitTLS)
  }

  @MainActor
  @Test
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

    #expect(viewModel.incomingHostname == "")
    #expect(viewModel.incomingPort == "")
    #expect(viewModel.outgoingHostname == "")
    #expect(viewModel.outgoingPort == "")
    #expect(viewModel.roleMappings.isEmpty)
  }

  @Test
  func testManualConfigurationVerifiesEveryEndpointBeforeSavingDeviceAuthorization()
    async throws
  {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    verifier.results = [
      GenericMailEndpointVerification(
        authenticated: true,
        engineCapabilities: [.idle, .uidPlus],
        transportVersion: .tls12OrNewer
      ),
      GenericMailEndpointVerification(
        authenticated: true,
        transportVersion: .tls12OrNewer
      ),
    ]
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )

    let definition = try await service.authorize(
      draft: manualDraft(),
      credential: "device-only-secret",
      productAccountId: ProductAccountId("product-account-001")
    )

    #expect(verifier.endpoints.map(\.mailProtocol) == [.imap, .smtp])
    #expect(definition.connectionId.providerId.rawValue == "imap-smtp")
    #expect(store.productAccountId == ProductAccountId("product-account-001"))
    #expect(store.authorization?.credential == "device-only-secret")
    #expect(store.authorization?.definition == definition)
    #expect(store.authorization?.engineCapabilities == [.idle, .uidPlus])
  }

  @Test
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

    #expect(store.authorization?.credential == "device-only-secret")
    #expect(sync.savedDefinition?.genericMailDefinition == definition)
    #expect(sync.savedDefinition?.connectedAt == 1_781_200_000_600)
    #expect(sync.recreatedDefinition?.genericMailDefinition == definition)
  }

  @MainActor
  @Test
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
    let localStateCleaner = RecordingGenericMailLocalStateCleaner()
    localStateCleaner.onClear = { connectionId in
      try store.remove(
        productAccountId: ProductAccountId(session.productAccountId),
        connectionId: connectionId
      )
    }
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId(session.productAccountId),
      isSessionCurrent: { true },
      service: GenericMailSetupService(
        authorizationStore: store,
        definitionSyncService: sync,
        localStateCleaner: localStateCleaner,
        verifier: RecordingGenericMailEndpointVerifier()
      ),
      syncSession: session
    )
    viewModel.emailAddress = draft.emailAddress
    viewModel.loadSaved()
    viewModel.credential = "new-secret"

    await viewModel.connect()

    #expect(viewModel.isConfirmingRecreation)
    #expect(sync.recreatedDefinition == nil)
    #expect(store.authorization == nil)

    sync.saveError = nil
    viewModel.credential = "new-secret"
    await viewModel.connect()

    #expect(sync.recreatedDefinition?.id == localDefinition.connectionId)
    #expect(sync.recreationObservation == removalObservation)
    #expect(!(viewModel.isConfirmingRecreation))
  }

  @MainActor
  @Test
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
    #expect(viewModel.isConfirmingRecreation)

    sync.saveError = MailboxConnectionSyncError.concurrentModification
    viewModel.credential = "new-secret"
    await viewModel.connect()

    #expect(!(viewModel.isConfirmingRecreation))

    sync.saveError = nil
    viewModel.credential = "new-secret"
    await viewModel.connect()

    #expect(sync.recreationObservation == nil)
    #expect(!(viewModel.isConfirmingRecreation))
  }

  @Test
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

    #expect(saved?.credential == "fresh-secret")
  }

  @Test
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

    #expect(localStateCleaner.clearedConnectionIds == [definition.connectionId])
    #expect(sync.completedCleanupGenerations[definition.connectionId] == 1)
    #expect(store.authorization?.authorizationGeneration == 1)
  }

  @Test
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
          sourceProviderMailboxId: nil,
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
    #expect(try pendingStore.load(productAccountId: productAccountId.rawValue).isEmpty)
    #expect(remainingOutboxItems.isEmpty)
  }

  @Test
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
      Issue.record("Expected Product Sync failure")
    } catch GenericMailSetupTestError.syncUnavailable {
      #expect(store.authorization == nil)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
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
      Issue.record("Expected Product Sync failure")
    } catch GenericMailSetupTestError.syncUnavailable {
      #expect(store.authorization?.credential == "previous-secret")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testSyncFailureRollsBackWhenConcurrentAccountCleanupFails() async throws {
    let productAccountId = ProductAccountId("product-account-cleanup-failure-\(UUID().uuidString)")
    let store = RecordingGenericMailAuthorizationStore()
    let sync = RecordingGenericSyncService()
    let saveStarted = TestExpectation(description: "definition save started")
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
      Issue.record("Expected account cleanup failure")
    } catch GenericMailSetupTestError.cleanupUnavailable {
    } catch {
      Issue.record("Unexpected cleanup error: \(error)")
    }
    await saveGate.open()

    do {
      _ = try await replacement.value
      Issue.record("Expected Product Sync failure")
    } catch GenericMailSetupTestError.syncUnavailable {
      #expect(store.authorization?.credential == "previous-secret")
    } catch {
      Issue.record("Unexpected authorization error: \(error)")
    }
  }

  @Test
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

    #expect(first.connectionId != second.connectionId)
  }

  @Test
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

    #expect(first.connectionId == second.connectionId)
  }

  @MainActor
  @Test
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

    #expect(viewModel.syncedDefinitions == [definition])
    #expect(!(viewModel.isAuthorized(definition)))
    #expect(viewModel.emailAddress == definition.emailAddress)
    #expect(viewModel.connectedDefinition == nil)
  }

  @MainActor
  @Test
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

    #expect(!(viewModel.isAuthorized(definition)))
    #expect(viewModel.connectedDefinition == nil)
  }

  @MainActor
  @Test
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

    #expect(viewModel.emailAddress == "draft@example.com")
    #expect(viewModel.incomingHostname == "draft.imap.example.com")
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testSyncedRemovalRetriesCompleteLocalCleanupUntilReceiptPersists() async throws {
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
    let sync = RecordingGenericSyncService(
      localCleanupGenerations: [definition.connectionId: 1],
      removedConnectionIds: [definition.connectionId]
    )
    let localStateCleaner = RecordingGenericMailLocalStateCleaner()
    localStateCleaner.error = GenericMailSetupTestError.syncUnavailable
    let service = GenericMailSetupService(
      authorizationStore: store,
      definitionSyncService: sync,
      localStateCleaner: localStateCleaner,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "product-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-002"
    )

    do {
      _ = try await service.loadSyncedDefinitions(session: session)
      Issue.record("Expected local cleanup failure")
    } catch GenericMailSetupTestError.syncUnavailable {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(localStateCleaner.clearedConnectionIds == [definition.connectionId])
    #expect(store.authorization != nil)
    #expect(sync.completedCleanupGenerations[definition.connectionId] == nil)

    localStateCleaner.error = nil
    localStateCleaner.onClear = { connectionId in
      try store.remove(
        productAccountId: ProductAccountId(session.productAccountId),
        connectionId: connectionId
      )
    }
    _ = try await service.loadSyncedDefinitions(session: session)
    _ = try await service.loadSyncedDefinitions(session: session)

    #expect(
      localStateCleaner.clearedConnectionIds == [definition.connectionId, definition.connectionId])
    #expect(store.authorization == nil)
    #expect(sync.completedCleanupGenerations[definition.connectionId] == 1)
  }

  @Test
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

    #expect(firstDefinition.connectionId == secondDefinition.connectionId)
    #expect(firstStore.authorization?.credential == "first-device-secret")
    #expect(secondStore.authorization?.credential == "second-device-secret")
    #expect(sync.currentSnapshot.connections.count == 1)
  }

  @Test
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

    #expect(store.authorization == nil)
    #expect(sync.currentSnapshot.connections.count == 1)
    #expect(sync.currentSnapshot.defaultSendingConnectionId == definition.connectionId)

    try await service.removeEverywhere(definition, session: session)

    #expect(sync.currentSnapshot.connections.isEmpty)
    #expect(sync.currentSnapshot.defaultSendingConnectionId == nil)
    #expect(sync.currentSnapshot.removedConnectionIds == [definition.connectionId])
  }

  @MainActor
  @Test
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

    #expect(!(didSetUnsupportedDefault))
    #expect(viewModel.defaultSendingConnectionId == nil)
    #expect(sync.currentSnapshot.defaultSendingConnectionId == nil)

    let didSetDefault = await viewModel.setDefaultSendingConnection(
      definition,
      routedConnections: [routedConnection(definition, capabilities: .gmail)]
    )

    #expect(didSetDefault)
    #expect(viewModel.defaultSendingConnectionId == definition.connectionId)
    #expect(sync.currentSnapshot.defaultSendingConnectionId == definition.connectionId)
  }

  @MainActor
  @Test
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

    #expect(didRemoveLocalAuthorization)
    #expect(store.authorization == nil)
    #expect(errorMessage != nil)
  }

  @MainActor
  @Test
  func testGenericRemovalCanRetryAfterConnectionDataCleanupFails() async throws {
    let sync = RecordingGenericSyncService()
    let store = RecordingGenericMailAuthorizationStore()
    let session = session(productAccountId: ProductAccountId("product-account-001"))
    let service = GenericMailSetupService(
      authorizationStore: store,
      definitionSyncService: sync,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let definition = try await service.authorize(
      draft: manualDraft(),
      credential: "device-only-secret",
      productAccountId: ProductAccountId(session.productAccountId),
      syncSession: session
    )
    var cleanupFails = true
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId(session.productAccountId),
      clearLocalData: { definition, _ in
        if cleanupFails { throw GenericMailSetupTestError.syncUnavailable }
        try store.remove(
          productAccountId: ProductAccountId(session.productAccountId),
          connectionId: definition.connectionId
        )
        return true
      },
      isSessionCurrent: { true },
      service: service,
      syncSession: session
    )

    let firstRemovalSucceeded = await viewModel.removeEverywhere(definition)

    #expect(!(firstRemovalSucceeded))
    #expect(sync.currentSnapshot.connections.map(\.id) == [definition.connectionId])
    #expect(store.authorization != nil)

    cleanupFails = false

    let retrySucceeded = await viewModel.removeEverywhere(definition)

    #expect(retrySucceeded)
    #expect(sync.currentSnapshot.connections.isEmpty)
    #expect(store.authorization == nil)
  }

  @MainActor
  @Test
  func testGenericRemovalCanRetryAfterAuthorizationFallbackFails() async throws {
    let sync = RecordingGenericSyncService()
    let store = RecordingGenericMailAuthorizationStore()
    let session = session(productAccountId: ProductAccountId("product-account-001"))
    let service = GenericMailSetupService(
      authorizationStore: store,
      definitionSyncService: sync,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    let definition = try await service.authorize(
      draft: manualDraft(),
      credential: "device-only-secret",
      productAccountId: ProductAccountId(session.productAccountId),
      syncSession: session
    )
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId(session.productAccountId),
      clearLocalData: { _, _ in false },
      isSessionCurrent: { true },
      service: service,
      syncSession: session
    )
    store.removeError = GenericMailSetupTestError.syncUnavailable

    let firstRemovalSucceeded = await viewModel.removeEverywhere(definition)

    #expect(!(firstRemovalSucceeded))
    #expect(sync.currentSnapshot.connections.map(\.id) == [definition.connectionId])
    #expect(store.authorization != nil)

    store.removeError = nil

    let retrySucceeded = await viewModel.removeEverywhere(definition)

    #expect(retrySucceeded)
    #expect(sync.currentSnapshot.connections.isEmpty)
    #expect(store.authorization == nil)
  }

  @Test
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

    #expect(verifier.credentials == ["  valid opaque password  ", "  valid opaque password  "])
    #expect(store.authorization?.credential == "  valid opaque password  ")
  }

  @Test
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
      Issue.record("Expected a secure transport failure")
    } catch GenericMailSetupError.secureTransportRequired(.imap) {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(store.authorization == nil)
    #expect(verifier.endpoints.map(\.mailProtocol) == [.imap])
  }

  @Test
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
      Issue.record("Expected certificate validation to fail")
    } catch GenericMailSetupTestError.invalidCertificate {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(store.authorization == nil)
  }

  @Test
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
      Issue.record("Expected authentication to fail")
    } catch GenericMailSetupError.authenticationFailed(.imap) {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(store.authorization == nil)
  }

  @Test
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
      Issue.record("Expected an explicit role mapping failure")
    } catch let GenericMailSetupError.missingRoleMappings(_, missing) {
      #expect(missing == [.sent])
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(store.authorization == nil)
  }

  @Test
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

    #expect(definition.roleMappings == discoveredRoles)
  }

  @Test
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

    #expect(definition.connectionId.providerId.rawValue == "pop3-smtp")
    #expect(definition.roleMappings.isEmpty)
  }

  @Test
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

    #expect(verifier.authorizationMethods == [.oauth, .oauth])
  }

  @MainActor
  @Test
  func testUnknownManualSetupDoesNotAssumeOAuthSupport() {
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true }
    )
    viewModel.emailAddress = "reader@unknown.example"

    viewModel.discover()

    #expect(viewModel.authorizationMethod == .password)
  }

  @MainActor
  @Test
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

    #expect(events == ["cancel", "remove", "notify"])
  }

  @MainActor
  @Test
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

    #expect(
      events == [
        "cancel failed",
        "failed remove",
        "cancel successful",
        "successful remove",
        "notify",
      ])
  }

  @MainActor
  @Test
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

    #expect(events == ["failed connect", "successful connect", "notify"])
  }

  @MainActor
  @Test
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

    #expect(viewModel.username == "second@example.com")
    #expect(viewModel.credential == "")
  }

  @MainActor
  @Test
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

    #expect(!(viewModel.showsMailboxRoles))

    await viewModel.connect()

    #expect(viewModel.rolesRequiringMapping == CanonicalMailboxRole.allCases)
    #expect(viewModel.showsMailboxRoles)
  }

  @MainActor
  @Test
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

    #expect(viewModel.connectedDefinition?.roleMappings == newRoles)
    #expect(!(viewModel.showsMailboxRoles))
  }

  @Test
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

    #expect(store.authorization == nil)
    #expect(store.clearedProductAccountId == ProductAccountId("product-account-001"))
  }

  @Test
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

    #expect(backgroundContextCacheStore.clearedProductAccountId == session.productAccountId)
    #expect(gmailConnection.clearedSession == session)
  }

  @Test
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
      Issue.record("Expected the stale session to cancel persistence")
    } catch is CancellationError {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(store.authorization == nil)
  }

  @Test
  func testAccountCleanupRacingFinalAuthorizationPersistenceLeavesNoCredential() async throws {
    let productAccountId = ProductAccountId("product-account-race-\(UUID().uuidString)")
    let store = BlockingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )
    let cleanupStarted = TestExpectation(description: "account cleanup started")
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

    #expect(store.authorization == nil)
  }

  @Test
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
      Issue.record("Expected cancellation while waiting to persist")
    } catch is CancellationError {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(store.authorization?.credential == "first-secret")
  }

  @Test
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

    #expect(
      try store.load(
        productAccountId: productAccountId,
        emailAddress: definition.emailAddress
      ) == authorization)
    try store.clearAll(productAccountId: productAccountId)
    #expect(
      try store.load(
        productAccountId: productAccountId,
        emailAddress: definition.emailAddress
      ) == nil)
  }

  @MainActor
  @Test
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

    #expect(viewModel.incomingHostname == definition.incomingEndpoint.hostname)
    #expect(viewModel.roleMappings[.sent] == "Changed Sent")
    #expect(viewModel.credential == "")
  }

  @Test
  func testSystemVerifierDelegatesIMAPAndSMTPToSwiftMail() async throws {
    let swiftMailVerifier = RecordingSwiftMailEndpointVerifier()
    swiftMailVerifier.result = GenericMailEndpointVerification(
      authenticated: true,
      discoveredRoleMappings: [.sent: "Sent Items"],
      engineCapabilities: [.idle, .move, .uidPlus],
      transportVersion: .tls12OrNewer
    )
    let streamFactory = RecordingGenericMailStreamTaskFactory(
      stream: ScriptedGenericMailStreamTask(responses: [])
    )
    let verifier = SystemGenericMailEndpointVerifier(
      streamTaskFactory: streamFactory,
      swiftMailVerifier: swiftMailVerifier
    )
    let endpoints = [
      GenericMailEndpoint(
        mailProtocol: .imap,
        hostname: "imap.example.com",
        port: 993,
        security: .implicitTLS
      ),
      GenericMailEndpoint(
        mailProtocol: .smtp,
        hostname: "smtp.example.com",
        port: 465,
        security: .implicitTLS
      ),
    ]

    var verifications: [GenericMailEndpointVerification] = []
    for endpoint in endpoints {
      verifications.append(
        try await verifier.verify(
          endpoint: endpoint,
          username: "reader@example.com",
          credential: "secret",
          authorizationMethod: .password
        ))
    }

    #expect(swiftMailVerifier.endpoints == endpoints)
    #expect(verifications.first?.discoveredRoleMappings[.sent] == "Sent Items")
    #expect(verifications.first?.engineCapabilities == [.idle, .move, .uidPlus])
    #expect(streamFactory.minimumTransportVersion == nil)
  }

  @Test
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

  @Test(
    "Cancelling POP3 verification closes its stream",
    .bug("https://github.com/unwired-dev/product/issues/443")
  )
  func cancellingPOP3VerificationClosesItsStream() async {
    let stream = BlockingGenericMailStreamTask()
    let verifier = SystemGenericMailEndpointVerifier(
      streamTaskFactory: RecordingGenericMailStreamTaskFactory(stream: stream)
    )
    let verification = Task {
      try await verifier.verify(
        endpoint: GenericMailEndpoint(
          mailProtocol: .pop3,
          hostname: "pop.example.com",
          port: 995,
          security: .implicitTLS
        ),
        username: "reader@example.com",
        credential: "secret",
        authorizationMethod: .password
      )
    }

    await stream.readStarted.waitUntilSet()
    verification.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await verification.value
    }
    #expect(stream.closeCount >= 1)
  }

  @Test
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
    let json = try requireValue(String(data: encoded, encoding: .utf8))

    #expect(verifier.usernames == ["reader@example.com", "reader@example.com"])
    #expect(verifier.credentials == ["device-only-secret", "device-only-secret"])
    #expect(verifier.endpoints.map(\.hostname) == ["imap.example.com", "smtp.example.com"])
    #expect(store.authorization?.definition.emailAddress == "reader@example.com")
    #expect(store.authorization?.credential == "device-only-secret")
    #expect(!(json.contains("product-account-001")))
    #expect(!(json.contains("identity-token")))
    #expect(!(json.contains("trusted-device")))
    #expect(!(json.contains("device-only-secret")))
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

private final class RecordingSwiftMailEndpointVerifier: SwiftMailEndpointVerifying {
  var endpoints: [GenericMailEndpoint] = []
  var result = GenericMailEndpointVerification(
    authenticated: true,
    transportVersion: .tls12OrNewer
  )

  func verify(
    endpoint: GenericMailEndpoint,
    username _: String,
    credential _: String,
    authorizationMethod _: MailAuthorizationMethod
  ) async throws -> GenericMailEndpointVerification {
    endpoints.append(endpoint)
    return result
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
  var removeError: Error?

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
    if let removeError { throw removeError }
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
  let loadStarted = TestExpectation(description: "authorization load started")

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
  var savedSession: ProductAccountSessionSnapshot?
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
    session: ProductAccountSessionSnapshot
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
    savedSession = session
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
  var error: Error?
  var onClear: ((MailboxConnectionId) throws -> Void)?

  func clear(
    connectionId: MailboxConnectionId,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    clearedConnectionIds.append(connectionId)
    if let error { throw error }
    try onClear?(connectionId)
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

private final class BlockingGenericMailStreamTask: GenericMailStreamTasking, @unchecked Sendable {
  let readStarted = TestFlag()

  private let lock = NSLock()
  private var isClosed = false
  private var readContinuation: CheckedContinuation<String, Error>?
  private var recordedCloseCount = 0

  var closeCount: Int {
    lock.withLock { recordedCloseCount }
  }

  func close() {
    let continuation = lock.withLock { () -> CheckedContinuation<String, Error>? in
      recordedCloseCount += 1
      isClosed = true
      defer { readContinuation = nil }
      return readContinuation
    }
    continuation?.resume(throwing: CancellationError())
  }

  func read() async throws -> String {
    await readStarted.set()
    return try await withCheckedThrowingContinuation { continuation in
      let wasClosed = lock.withLock { () -> Bool in
        if !isClosed { readContinuation = continuation }
        return isClosed
      }
      if wasClosed { continuation.resume(throwing: CancellationError()) }
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
