import Foundation
import SwiftData
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

@MainActor
@Suite(.serialized)
final class IMAPMailboxConnectionAdapterTests {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "identity-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  @Test
  // swiftlint:disable:next function_body_length
  func testSwiftDataMetadataStoreUpgradesLegacyDiskStore() throws {
    let definition = imapDefinition(username: "migration-reader")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("IMAPMetadata.store")
    let expectedMessage = imapMessage(uid: 42, subject: "Preserved message")
    let expectedState = IMAPMetadataSyncState(
      hasInitialMailboxAvailability: true,
      mailboxes: [
        IMAPMailboxBackfillState(
          descriptor: IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX"),
          nextOlderUID: 21,
          uidValidity: expectedMessage.uidValidity
        )
      ],
      scanId: "legacy-scan"
    )
    do {
      let legacySchema = Schema([
        DurableIMAPMessageMetadataRecord.self,
        IMAPMetadataSyncCheckpointRecord.self,
      ])
      let legacyConfiguration = ModelConfiguration(
        "IMAPMetadataMigrationTests",
        schema: legacySchema,
        url: storeURL
      )
      let legacyContainer = try ModelContainer(
        for: legacySchema,
        configurations: [legacyConfiguration]
      )
      let context = ModelContext(legacyContainer)
      context.insert(
        DurableIMAPMessageMetadataRecord(
          connectionIdRawValue: definition.connectionId.rawValue,
          encodedMessage: try JSONEncoder().encode(expectedMessage),
          mailbox: expectedMessage.mailbox,
          productAccountId: session.productAccountId,
          stableProviderMessageId: StableProviderMessageIdentity(
            connectionId: definition.connectionId,
            providerMessageId: expectedMessage.providerMessageId
          ).rawValue,
          storageKey: "legacy-message",
          uidValidity: expectedMessage.uidValidity
        )
      )
      context.insert(
        IMAPMetadataSyncCheckpointRecord(
          connectionIdRawValue: definition.connectionId.rawValue,
          encodedState: try JSONEncoder().encode(expectedState),
          productAccountId: session.productAccountId,
          storageKey: "legacy-checkpoint"
        )
      )
      try context.save()
    }

    let configuration = ModelConfiguration(
      "IMAPMetadataMigrationTests",
      schema: SwiftDataIMAPMessageMetadataStore.schema,
      url: storeURL
    )
    let container = try ModelContainer(
      for: SwiftDataIMAPMessageMetadataStore.schema,
      configurations: [configuration]
    )
    let store = SwiftDataIMAPMessageMetadataStore(container: container)

    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      ) == [expectedMessage])
    #expect(
      try store.loadState(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      ) == expectedState)

    let mapping = MailEngineUIDMapping(
      destinationMailbox: MailEngineMailboxIdentity("Archive"),
      destinationUIDValidity: 2,
      pairs: [MailEngineUIDPair(destinationUID: 1_042, sourceUID: expectedMessage.uid)],
      sourceMailbox: MailEngineMailboxIdentity(expectedMessage.mailbox),
      sourceUIDValidity: expectedMessage.uidValidity
    )
    try store.savePendingMove(
      mapping,
      sourceDeletionRequired: true,
      sourceMessages: [expectedMessage],
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId
    )
    #expect(
      try store.loadPendingMove(
        sourceMessages: [expectedMessage],
        destinationMailbox: mapping.destinationMailbox,
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      ) == IMAPPendingMoveContinuation(mapping: mapping, sourceDeletionRequired: true))
  }

  @Test
  func testAuthorizedIMAPConnectionJoinsProviderNeutralConnectionList() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = RecordingIMAPAuthorizationStore()
    authorizationStore.save(
      DeviceLocalGenericMailAuthorization(
        credential: "secret",
        definition: definition,
        engineCapabilities: [.idle, .uidPlus]
      ),
      productAccountId: ProductAccountId(session.productAccountId)
    )
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: RecordingIMAPClient(),
      definitions: [definition]
    )

    let connections = try await adapter.loadConnections(session: session)

    #expect(connections.count == 1)
    #expect(connections[0].authorizationState == .authorized)
    #expect(
      connections[0].capabilities
        == .standardsMail(
          engineCapabilities: [.idle, .uidPlus],
          roleMappings: definition.roleMappings
        ))
    #expect(connections[0].id == definition.connectionId)
  }

  @Test
  func testLegacyAuthorizationWithoutCapabilitiesRequiresReauthorization() async throws {
    let definition = imapDefinition(username: "legacy-reader")
    let encoded = try JSONEncoder().encode(
      DeviceLocalGenericMailAuthorization(
        credential: "secret",
        definition: definition,
        engineCapabilities: [.idle, .uidPlus]
      )
    )
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["engineCapabilities"] = nil
    let legacyAuthorization = try JSONDecoder().decode(
      DeviceLocalGenericMailAuthorization.self,
      from: JSONSerialization.data(withJSONObject: object)
    )
    let authorizationStore = RecordingIMAPAuthorizationStore()
    authorizationStore.save(
      legacyAuthorization,
      productAccountId: ProductAccountId(session.productAccountId)
    )
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: RecordingIMAPClient(),
      definitions: [definition]
    )

    let connection = try #require(try await adapter.loadConnections(session: session).first)

    #expect(!legacyAuthorization.hasPersistedEngineCapabilities)
    #expect(connection.authorizationState == .required)
    #expect(connection.capabilities == .none)
  }

  @Test
  func testStandardsMailCapabilitiesFollowVerifiedServerFeaturesAndRoleMappings() async throws {
    let readOnlyDefinition = imapDefinition(username: "read-only", roleMappings: [:])
    let fullDefinition = imapDefinition(username: "full")
    let authorizationStore = RecordingIMAPAuthorizationStore()
    authorizationStore.save(
      DeviceLocalGenericMailAuthorization(
        credential: "secret",
        definition: readOnlyDefinition
      ),
      productAccountId: ProductAccountId(session.productAccountId)
    )
    authorizationStore.save(
      DeviceLocalGenericMailAuthorization(
        credential: "secret",
        definition: fullDefinition,
        engineCapabilities: [.idle, .move, .uidPlus]
      ),
      productAccountId: ProductAccountId(session.productAccountId)
    )
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: RecordingIMAPClient(),
      definitions: [readOnlyDefinition, fullDefinition]
    )

    let connections = try await adapter.loadConnections(session: session)
    let readOnly = try requireValue(connections.first { $0.id == readOnlyDefinition.connectionId })
    let full = try requireValue(connections.first { $0.id == fullDefinition.connectionId })

    #expect(readOnly.capabilities.providerActions == [.markRead, .markUnread, .star, .unstar])
    #expect(!(readOnly.capabilities.canSend))
    #expect(!(readOnly.capabilities.canRegisterPush))
    #expect(full.capabilities.canSend)
    #expect(full.capabilities.canRegisterPush)
    #expect(full.capabilities.providerActions == Set(ProviderMailAction.allCases))
  }

  @Test
  func testStandardsMailMoveActionsRequireUIDPlus() {
    let roleMappings = imapDefinition(username: "mover").roleMappings
    let baselineActions: Set<ProviderMailAction> = [.markRead, .markUnread, .star, .unstar]

    for capabilities: Set<MailEngineCapability> in [[], [.move]] {
      #expect(
        MailboxConnectionCapabilities.standardsMail(
          engineCapabilities: capabilities,
          roleMappings: roleMappings
        ).providerActions == baselineActions)
    }
    #expect(
      MailboxConnectionCapabilities.standardsMail(
        engineCapabilities: [.uidPlus],
        roleMappings: roleMappings
      ).providerActions == Set(ProviderMailAction.allCases))

    let actionsWithoutRoleMappings = MailboxConnectionCapabilities.standardsMail(
      engineCapabilities: [.uidPlus],
      roleMappings: [:]
    ).providerActions
    #expect(actionsWithoutRoleMappings.contains(.move))
    #expect(!actionsWithoutRoleMappings.contains(.notSpam))
    #expect(!actionsWithoutRoleMappings.contains(.restore))
    #expect(!actionsWithoutRoleMappings.contains(.archive))
    #expect(!actionsWithoutRoleMappings.contains(.spam))
    #expect(!actionsWithoutRoleMappings.contains(.delete))
  }

  @Test
  func testRouterPreservesHealthyProvidersAndMarksPartialSnapshotNonAuthoritative() async throws {
    let healthyDefinition = imapDefinition(username: "healthy-provider")
    let healthyAuthorizationStore = RecordingIMAPAuthorizationStore()
    healthyAuthorizationStore.save(
      DeviceLocalGenericMailAuthorization(
        credential: "healthy-secret",
        definition: healthyDefinition
      ),
      productAccountId: ProductAccountId(session.productAccountId)
    )
    let healthyAdapter = try makeAdapter(
      authorizationStore: healthyAuthorizationStore,
      client: RecordingIMAPClient(),
      definitions: [healthyDefinition]
    )
    let emptyAdapter = try makeAdapter(
      authorizationStore: RecordingIMAPAuthorizationStore(),
      client: RecordingIMAPClient(),
      definitions: []
    )
    let failingDefinitionSyncService = RecordingIMAPDefinitionSyncService(definitions: [])
    failingDefinitionSyncService.loadError = IMAPAdapterTestError.unavailable
    let failingAdapter = try makeAdapter(
      authorizationStore: RecordingIMAPAuthorizationStore(),
      client: RecordingIMAPClient(),
      definitionSyncService: failingDefinitionSyncService,
      definitions: []
    )
    let router = MailboxConnectionRouter(
      exchangeWebServices: emptyAdapter,
      gmail: healthyAdapter,
      imap: failingAdapter,
      microsoftGraph: emptyAdapter
    )

    let snapshot = try await router.loadConnectionSnapshot(session: session)
    let connections = try await router.loadConnections(session: session)
    let viewModel = MailboxProviderConnectionViewModel(
      service: router,
      isSessionCurrent: { _ in true },
      session: session
    )
    let viewModelSnapshotIsAuthoritative = await viewModel.load()

    #expect(snapshot.connections.map(\.id) == [healthyDefinition.connectionId])
    #expect(!(snapshot.isAuthoritative))
    #expect(connections.map(\.id) == [healthyDefinition.connectionId])
    #expect(viewModel.connections.map(\.id) == [healthyDefinition.connectionId])
    #expect(!(viewModelSnapshotIsAuthoritative))
    #expect(!(viewModel.connectionsSnapshotIsAuthoritative))
    #expect(viewModel.errorMessage != nil)
  }

  @Test
  func testRouterLoadsProviderConnectionsConcurrentlyAndPreservesOrdering() async throws {
    let gmailGate = RouterOperationGate()
    let imapGate = RouterOperationGate()
    await imapGate.release()
    let gmailConnection = routerConnection(providerId: .gmail, displayName: "Zulu")
    let imapConnection = routerConnection(providerId: .imapSMTP, displayName: "alpha")
    let router = MailboxConnectionRouter(
      exchangeWebServices: RouterTestAdapter(),
      gmail: RouterTestAdapter(connections: [gmailConnection], loadGate: gmailGate),
      imap: RouterTestAdapter(connections: [imapConnection], loadGate: imapGate),
      microsoftGraph: RouterTestAdapter()
    )
    let imapStarted = expectation(description: "IMAP load starts while Gmail remains suspended")

    let loadTask = Task {
      try await router.loadConnectionSnapshot(session: session)
    }
    await gmailGate.waitUntilStarted()
    Task {
      await imapGate.waitUntilStarted()
      imapStarted.fulfill()
    }

    await fulfillment(of: [imapStarted], timeout: 1)
    await gmailGate.release()
    let snapshot = try await loadTask.value

    #expect(snapshot.connections.map(\.id) == [imapConnection.id, gmailConnection.id])
    #expect(snapshot.isAuthoritative)
  }

  @Test
  func testRouterRemovesDownloadedAttachmentsWithConnectionEverywhere() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RouterAttachmentStoreTests.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let attachmentStore = DownloadedAttachmentStore(rootDirectory: rootDirectory)
    let connection = routerConnection(providerId: .imapSMTP, displayName: "IMAP")
    let messageId = StableProviderMessageIdentity(
      connectionId: connection.id,
      providerMessageId: "message-001"
    )
    let attachment = MailboxMessageAttachment(
      byteCount: 3,
      filename: "private.pdf",
      id: "attachment-001",
      mimeType: "application/pdf"
    )
    let router = MailboxConnectionRouter(
      attachmentStore: attachmentStore,
      exchangeWebServices: RouterTestAdapter(),
      gmail: RouterTestAdapter(),
      imap: RouterTestAdapter(),
      microsoftGraph: RouterTestAdapter()
    )

    _ = try attachmentStore.save(
      Data("PDF".utf8),
      attachment: attachment,
      messageId: messageId
    )
    try await router.removeMailboxConnectionEverywhere(connection, session: session)

    #expect(attachmentStore.existingURL(attachment: attachment, messageId: messageId) == nil)
  }

  @Test
  func testRouterRemovesDownloadedAttachmentsWhenProviderRemovalFails() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RouterAttachmentStoreTests.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let attachmentStore = DownloadedAttachmentStore(rootDirectory: rootDirectory)
    let connection = routerConnection(providerId: .imapSMTP, displayName: "IMAP")
    let messageId = StableProviderMessageIdentity(
      connectionId: connection.id,
      providerMessageId: "message-001"
    )
    let attachment = MailboxMessageAttachment(
      byteCount: 3,
      filename: "private.pdf",
      id: "attachment-001",
      mimeType: "application/pdf"
    )
    let router = MailboxConnectionRouter(
      attachmentStore: attachmentStore,
      exchangeWebServices: RouterTestAdapter(),
      gmail: RouterTestAdapter(),
      imap: RouterTestAdapter(removalError: IMAPAdapterTestError.unavailable),
      microsoftGraph: RouterTestAdapter()
    )

    _ = try attachmentStore.save(
      Data("PDF".utf8),
      attachment: attachment,
      messageId: messageId
    )

    do {
      try await router.removeMailboxConnectionEverywhere(connection, session: session)
      Issue.record("Expected provider removal to fail.")
    } catch IMAPAdapterTestError.unavailable {}

    #expect(attachmentStore.existingURL(attachment: attachment, messageId: messageId) == nil)
  }

  @Test
  func testRouterResumesProviderActionsConcurrentlyAndPreservesErrorOrdering() async {
    let gmailGate = RouterOperationGate()
    let imapGate = RouterOperationGate()
    await imapGate.release()
    let gmailConnection = routerConnection(providerId: .gmail, displayName: "Gmail")
    let imapConnection = routerConnection(providerId: .imapSMTP, displayName: "IMAP")
    let router = MailboxConnectionRouter(
      exchangeWebServices: RouterTestAdapter(),
      gmail: RouterTestAdapter(pendingActionError: "Gmail failed.", pendingActionGate: gmailGate),
      imap: RouterTestAdapter(pendingActionError: "IMAP failed.", pendingActionGate: imapGate),
      microsoftGraph: RouterTestAdapter()
    )
    let imapStarted = expectation(description: "IMAP resume starts while Gmail remains suspended")

    let resumeTask = Task {
      await router.resumePendingActions(
        connections: [gmailConnection, imapConnection],
        session: session
      )
    }
    await gmailGate.waitUntilStarted()
    Task {
      await imapGate.waitUntilStarted()
      imapStarted.fulfill()
    }

    await fulfillment(of: [imapStarted], timeout: 1)
    await gmailGate.release()
    let error = await resumeTask.value

    #expect(error == "Gmail failed.\nIMAP failed.")
  }

  @Test
  func testRouterLoadsPendingActionConnectionIdsConcurrentlyAndPreservesProviderOrdering() async {
    let gmailGate = RouterOperationGate()
    let imapGate = RouterOperationGate()
    await imapGate.release()
    let gmailConnection = routerConnection(providerId: .gmail, displayName: "Gmail")
    let imapConnection = routerConnection(providerId: .imapSMTP, displayName: "IMAP")
    let router = MailboxConnectionRouter(
      exchangeWebServices: RouterTestAdapter(),
      gmail: RouterTestAdapter(
        blockedConnectionIds: [gmailConnection.id], pendingActionGate: gmailGate),
      imap: RouterTestAdapter(
        blockedConnectionIds: [imapConnection.id], pendingActionGate: imapGate),
      microsoftGraph: RouterTestAdapter()
    )
    let imapStarted = expectation(description: "IMAP status starts while Gmail remains suspended")

    let statusTask = Task {
      await router.blockedPendingActionConnectionIds(
        connections: [gmailConnection, imapConnection],
        session: session
      )
    }
    await gmailGate.waitUntilStarted()
    Task {
      await imapGate.waitUntilStarted()
      imapStarted.fulfill()
    }

    await fulfillment(of: [imapStarted], timeout: 1)
    await gmailGate.release()
    let connectionIds = await statusTask.value

    #expect(connectionIds == [gmailConnection.id, imapConnection.id])
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testIMAPConnectionRequiresAuthorizationForAnOlderConnectionGeneration() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = RecordingIMAPAuthorizationStore()
    let outboxStore = InMemoryIMAPOutboxStore()
    let pendingActionStore = InMemoryIMAPPendingActionStore()
    authorizationStore.save(
      DeviceLocalGenericMailAuthorization(
        authorizationGeneration: 0,
        credential: "secret",
        definition: definition
      ),
      productAccountId: ProductAccountId(session.productAccountId)
    )
    let adapter = try makeAdapter(
      authorizationGeneration: 1,
      authorizationCleanupConnectionIds: [definition.connectionId],
      authorizationStore: authorizationStore,
      client: RecordingIMAPClient(),
      definitions: [definition],
      outboxStore: outboxStore,
      pendingActionStore: pendingActionStore
    )

    let staleConnections = try await adapter.loadConnections(session: session)
    let staleConnection = try requireValue(staleConnections.first)
    let outboxCleanupCount = outboxStore.saveCallCount
    let pendingActionCleanupCount = pendingActionStore.saveCallCount
    authorizationStore.save(
      DeviceLocalGenericMailAuthorization(
        authorizationGeneration: 1,
        credential: "secret",
        definition: definition
      ),
      productAccountId: ProductAccountId(session.productAccountId)
    )
    let authorizedConnections = try await adapter.loadConnections(session: session)
    let authorizedConnection = try requireValue(authorizedConnections.first)

    #expect(staleConnection.authorizationState == .required)
    #expect(authorizedConnection.authorizationState == .authorized)
    do {
      _ = try await adapter.syncInbox(
        connection: authorizedConnection.withAuthorizationGeneration(0),
        session: session
      )
      Issue.record("Expected a stale operation generation to require authorization")
    } catch {
      #expect(error as? MailboxConnectionAdapterError == .authorizationRequired)
    }
    let preservedAuthorization = try requireValue(
      authorizationStore.load(
        productAccountId: ProductAccountId(session.productAccountId),
        connectionId: definition.connectionId
      ))
    #expect(preservedAuthorization.authorizationGeneration == 1)
    #expect(outboxStore.saveCallCount == outboxCleanupCount)
    #expect(pendingActionStore.saveCallCount == pendingActionCleanupCount)
  }

  @Test
  func testLoadConnectionsReturnsConcurrentReaddObservedDuringRemovalCleanup() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let definitions = RecordingIMAPDefinitionSyncService(
      definitions: [],
      removedConnectionIds: [definition.connectionId]
    )
    definitions.beforeLoadSnapshotReturn = { callCount in
      guard callCount == 2 else { return }
      definitions.replaceSnapshot(definitions: [definition], removedConnectionIds: [])
    }
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: RecordingIMAPClient(),
      definitionSyncService: definitions,
      definitions: []
    )

    let connections = try await adapter.loadConnections(session: session)

    #expect(connections.map(\.id) == [definition.connectionId])
    #expect(connections.first?.authorizationState == .authorized)
  }

  @Test
  func testRemovalCleanupClearsPendingActionsAndOutboxBeforeRecordingReceipt() async throws {
    let definition = imapDefinition(username: "reader")
    let definitions = RecordingIMAPDefinitionSyncService(
      definitions: [],
      removedConnectionIds: [definition.connectionId]
    )
    let outboxStore = InMemoryIMAPOutboxStore()
    let pendingActionStore = InMemoryIMAPPendingActionStore()
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: RecordingIMAPClient(),
      definitionSyncService: definitions,
      definitions: [],
      outboxStore: outboxStore,
      pendingActionStore: pendingActionStore
    )

    _ = try await adapter.loadConnections(session: session)

    #expect(outboxStore.saveCallCount == 1)
    #expect(pendingActionStore.saveCallCount == 1)
  }

  @Test
  func testInitialFiftyMessagesRemainUsableWhileBackfillResumesAfterRecreation() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = (1...75).map {
      imapMessage(uid: Int64($0), subject: "Message \($0)")
    }
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition],
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    let initial = try await adapter.syncInbox(connection: connection, session: session)

    #expect(initial.hasInitialMailboxAvailability)
    #expect(!(initial.historicalMetadataBackfillIsComplete))
    #expect(initial.messages.count == 50)
    #expect(initial.messages.first?.subject == "Message 75")
    client.messagesByUsername[definition.username]?.append(
      imapMessage(uid: 76, subject: "Message 76")
    )

    let recreatedAdapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition],
      store: store
    )
    let resumedInitial = try await recreatedAdapter.syncInbox(
      connection: connection,
      session: session
    )

    #expect(resumedInitial.messages.count == 50)
    #expect(resumedInitial.messages.first?.subject == "Message 76")
    #expect(client.metadataRequestCount == 2)

    let completed = try await recreatedAdapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    #expect(completed.historicalMetadataBackfillIsComplete)
    #expect(completed.messages.count == 76)

    client.messagesByUsername[definition.username]?.append(
      imapMessage(uid: 77, subject: "Message 77")
    )

    let refreshed = try await recreatedAdapter.syncInbox(connection: connection, session: session)

    #expect(refreshed.historicalMetadataBackfillIsComplete)
    #expect(refreshed.messages.count == 77)
    #expect(refreshed.messages.last?.subject == "Message 1")
  }

  @Test
  func testUnsubscribeMetadataPersistsWithoutLoadingMessageBody() async throws {
    let definition = imapDefinition(username: "newsletter-reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    var providerMessage = imapMessage(uid: 1, subject: "Newsletter")
    providerMessage.unsubscribeSuggestion = UnsubscribeSuggestionParser.suggestion(headers: [
      ("List-ID", "Example List <list.example.com>"),
      ("List-Unsubscribe", "<mailto:leave@example.com>, <https://lists.example.com/leave>"),
    ])
    client.messagesByUsername[definition.username] = [providerMessage]
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition],
      store: store
    )
    let connection = try #require(try await adapter.loadConnections(session: session).first)

    let initial = try await adapter.syncInbox(connection: connection, session: session)
    let recreated = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition],
      store: store
    )
    let cached = try await recreated.loadMailbox(
      .role(.inbox),
      connection: connection,
      session: session
    )

    #expect(initial.messages.first?.unsubscribeSuggestion == providerMessage.unsubscribeSuggestion)
    #expect(cached.messages.first?.unsubscribeSuggestion == providerMessage.unsubscribeSuggestion)
    #expect(client.bodyRequestCount == 0)
  }

  @Test
  func testInjectedCategorizerDecoratesVisibleSyncedMetadata() async throws {
    let definition = imapDefinition(username: "reader")
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [
      imapMessage(uid: 1, subject: "Flight itinerary ready")
    ]
    let categorizer = AssigningIMAPCategorizer(categoryId: "system:flights")
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: client,
      definitions: [definition],
      messageCategorizer: categorizer
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    let result = try await adapter.syncInbox(connection: connection, session: session)

    #expect(result.messages.first?.categoryId == "system:flights")
    #expect(result.threads.first?.latestMessage.categoryId == "system:flights")
    #expect(categorizer.categorizedStableIds == result.messages.map(\.stableProviderMessageId))
  }

  @Test
  func testInjectedCategorizerReceivesResolvedProfileRecordScope() async throws {
    let definition = imapDefinition(username: "reader")
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [
      imapMessage(uid: 1, subject: "Flight itinerary ready")
    ]
    let profileId = MailProfileId(rawValue: "profile-categories")
    let recordScope = MailProfileRecordScope.profile(profileId)
    let categorizer = AssigningIMAPCategorizer(categoryId: "system:flights")
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: client,
      definitions: [definition],
      messageCategorizer: categorizer,
      profileResolver: FixedIMAPNotificationProfileResolver(
        resolution: NotificationProfileResolution(
          deliveryContext: NotificationDeliveryContext(
            connectionId: definition.connectionId,
            isActiveProfile: true,
            isProfileQuiet: false,
            profileId: profileId,
            profileName: "Categories"
          ),
          recordScope: recordScope
        )
      )
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)

    #expect(categorizer.categorizedRecordScopes == [recordScope])
  }

  @Test
  func testInjectedCategorizerDecoratesLoadedInboxMetadata() async throws {
    let fixture = try await makePersistedCategorizationFixture(messageCount: 1)
    let categorizer = AssigningIMAPCategorizer(categoryId: "system:flights")
    let adapter = try makeAdapter(
      authorizationStore: fixture.authorizationStore,
      client: fixture.client,
      definitions: [fixture.definition],
      messageCategorizer: categorizer,
      store: fixture.store
    )

    let result = try await adapter.loadInbox(connection: fixture.connection, session: session)

    expectCategorized(result, count: 1)
    #expect(categorizer.categorizedStableIds == result.messages.map(\.stableProviderMessageId))
  }

  @Test
  func testInjectedCategorizerDecoratesAllObservedMailboxMetadata() async throws {
    let fixture = try await makePersistedCategorizationFixture(
      messageCount: 60,
      completesBackfill: true
    )
    let categorizer = AssigningIMAPCategorizer(categoryId: "system:flights")
    let adapter = try makeAdapter(
      authorizationStore: fixture.authorizationStore,
      client: fixture.client,
      definitions: [fixture.definition],
      messageCategorizer: categorizer,
      store: fixture.store
    )

    let result = try await adapter.loadMailbox(
      .allObserved,
      connection: fixture.connection,
      session: session
    )

    expectCategorized(result, count: 60)
    #expect(
      Set(categorizer.categorizedStableIds) == Set(result.messages.map(\.stableProviderMessageId)))
  }

  @Test
  func testInjectedCategorizerDecoratesPagedMailboxMetadata() async throws {
    let fixture = try await makePersistedCategorizationFixture(messageCount: 60)
    let categorizer = AssigningIMAPCategorizer(categoryId: "system:flights")
    let adapter = try makeAdapter(
      authorizationStore: fixture.authorizationStore,
      client: fixture.client,
      definitions: [fixture.definition],
      messageCategorizer: categorizer,
      store: fixture.store
    )

    let result = try await adapter.loadMailbox(
      .role(.inbox),
      connection: fixture.connection,
      session: session
    )

    expectCategorized(result, count: 50)
    #expect(
      Set(categorizer.categorizedStableIds) == Set(result.messages.map(\.stableProviderMessageId)))
  }

  @Test
  func testNewMailOnlyCategorizerLeavesBackfilledMetadataUnchanged() async throws {
    let fixture = try await makePersistedCategorizationFixture(messageCount: 75)
    let categorizer = AssigningIMAPCategorizer(
      categoryId: "system:flights",
      newMailOnly: true
    )
    let adapter = try makeAdapter(
      authorizationStore: fixture.authorizationStore,
      client: fixture.client,
      definitions: [fixture.definition],
      messageCategorizer: categorizer,
      store: fixture.store
    )

    _ = try await adapter.continueHistoricalBackfill(
      connection: fixture.connection,
      session: session
    )
    let result = try await adapter.loadMailbox(
      .allObserved,
      connection: fixture.connection,
      session: session
    )

    #expect(result.messages.count == 75)
    #expect(result.messages.filter(\.isHistorical).allSatisfy { $0.categoryId == nil })
    #expect(
      result.threads.flatMap(\.messages).filter(\.isHistorical)
        .allSatisfy { $0.categoryId == nil })
    #expect(
      result.messages.filter { !$0.isHistorical }.allSatisfy {
        $0.categoryId == "system:flights"
      })
  }

  @Test
  func testInitialAvailabilityKeepsEachMailboxsFirstPageUsable() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.mailboxesByUsername[definition.username] = [
      IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX"),
      IMAPMailboxDescriptor(displayName: "Archive", name: "Archive"),
    ]
    client.messagesByUsernameAndMailbox[definition.username] = [
      "INBOX": (1...60).map { imapMessage(uid: Int64($0)) },
      "Archive": (61...120).map {
        imapMessage(mailbox: "Archive", uid: Int64($0))
      },
    ]
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition]
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    let initial = try await adapter.syncInbox(connection: connection, session: session)
    let archive = try await adapter.loadMailbox(
      .role(.archive),
      connection: connection,
      session: session
    )

    #expect(initial.messages.count == 50)
    #expect(initial.messages.first?.providerInternalDateMilliseconds == 1_781_200_000_060)
    #expect(archive.messages.count == 50)
    #expect(archive.messages.first?.providerInternalDateMilliseconds == 1_781_200_000_120)
    #expect(!(initial.historicalMetadataBackfillIsComplete))
  }

  @Test
  func testRefreshDropsRecordsFromRemovedMailboxBeforeBackfillCompletes() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.mailboxesByUsername[definition.username] = [
      IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX"),
      IMAPMailboxDescriptor(displayName: "Archive", name: "Archive"),
    ]
    client.messagesByUsernameAndMailbox[definition.username] = [
      "INBOX": (1...60).map { imapMessage(uid: Int64($0)) },
      "Archive": (61...120).map {
        imapMessage(mailbox: "Archive", uid: Int64($0))
      },
    ]
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition]
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)
    client.mailboxesByUsername[definition.username] = [
      IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX")
    ]

    let refreshed = try await adapter.syncInbox(connection: connection, session: session)
    let observed = try await adapter.loadMailbox(
      .allObserved,
      connection: connection,
      session: session
    )

    #expect(!(refreshed.historicalMetadataBackfillIsComplete))
    #expect(refreshed.messages.count == 50)
    #expect(observed.messages.count == 50)
  }

  @Test
  func testObjectIdDeduplicatesOneMessageAcrossMailboxes() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.mailboxesByUsername[definition.username] = [
      IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX"),
      IMAPMailboxDescriptor(displayName: "Archive", name: "Archive"),
    ]
    client.messagesByUsernameAndMailbox[definition.username] = [
      "INBOX": [
        imapMessage(uid: 1, providerEmailId: "shared-email")
      ],
      "Archive": [
        imapMessage(
          mailbox: "Archive",
          uid: 8,
          providerEmailId: "shared-email",
          hasAttachments: true
        )
      ],
    ]
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition]
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    let result = try await adapter.syncInbox(connection: connection, session: session)

    #expect(result.messages.count == 1)
    #expect(result.messages.first?.providerMessageId == "imap-email:shared-email")
    #expect(result.messages.first?.hasAttachments == true)
    #expect(Set(result.messages.first?.providerStateIds ?? []) == ["INBOX", "ARCHIVE", "UNREAD"])
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testSavedRolesAndRFCLinkageDriveProjectionWithoutSubjectMerging() async throws {
    let definition = imapDefinition(
      username: "reader",
      roleMappings: [
        .archive: "Archive",
        .drafts: "Drafts",
        .sent: "Sent Items",
        .spam: "Junk",
        .trash: "Deleted",
      ]
    )
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.mailboxesByUsername[definition.username] = [
      IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX"),
      IMAPMailboxDescriptor(displayName: "Sent Items", name: "Sent Items"),
    ]
    client.messagesByUsernameAndMailbox[definition.username] = [
      "INBOX": [
        imapMessage(
          uid: 1,
          rfcMessageId: "<root@example.com>",
          subject: "Shared subject"
        ),
        imapMessage(
          uid: 2,
          inReplyTo: "<root@example.com>",
          references: ["<root@example.com>"],
          rfcMessageId: "<reply@example.com>",
          subject: "Re: Shared subject"
        ),
        imapMessage(
          uid: 3,
          inReplyTo: "<reply@example.com>",
          rfcMessageId: "<second-reply@example.com>",
          subject: "Re: Re: Shared subject"
        ),
        imapMessage(
          uid: 4,
          rfcMessageId: "<unrelated@example.com>",
          subject: "Shared subject"
        ),
      ],
      "Sent Items": [
        imapMessage(
          mailbox: "Sent Items",
          uid: 5,
          rfcMessageId: "<sent@example.com>",
          subject: "Sent"
        )
      ],
    ]
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition]
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)

    let inbox = try await adapter.loadMailbox(
      .role(.inbox),
      connection: connection,
      session: session
    )
    let sent = try await adapter.loadMailbox(
      .role(.sent),
      connection: connection,
      session: session
    )

    #expect(inbox.messages.count == 4)
    #expect(inbox.threads.map(\.messages.count).sorted() == [1, 3])
    #expect(sent.messages.map(\.subject) == ["Sent"])
    #expect((sent.messages.first?.providerStateIds ?? []).contains("SENT") == true)
  }

  @Test
  func testUIDValidityChangeAndExpungeRemoveOnlyAffectedConnectionRecords() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [
      imapMessage(uid: 1, subject: "First"),
      imapMessage(uid: 2, subject: "Second"),
    ]
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition],
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)

    client.uidValidityByUsername[definition.username] = 2
    client.messagesByUsername[definition.username] = [
      imapMessage(uid: 1, uidValidity: 2, subject: "Replacement")
    ]
    let reset = try await adapter.syncInbox(connection: connection, session: session)

    #expect(reset.messages.map(\.subject) == ["Replacement"])

    client.messagesByUsername[definition.username] = []
    let expunged = try await adapter.syncInbox(connection: connection, session: session)

    #expect(expunged.messages.isEmpty)
  }

  @Test
  func testCompletedBackfillRemovesAnExpungedMessageInRefreshedPage() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = (1...75).map {
      imapMessage(uid: Int64($0), subject: "Message \($0)")
    }
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition]
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)
    _ = try await adapter.continueHistoricalBackfill(connection: connection, session: session)
    client.messagesByUsername[definition.username]?.removeAll { $0.uid == 26 }

    let refreshed = try await adapter.syncInbox(connection: connection, session: session)

    #expect(refreshed.messages.count == 74)
    #expect(!(refreshed.messages.contains { $0.subject == "Message 26" }))
  }

  @Test
  func testCustomMailboxStateIdsAreNamespacedAndCaseSensitive() {
    let definition = imapDefinition(username: "reader", roleMappings: [.archive: "Projects"])
    let message = imapMessage(mailbox: "projects", uid: 1)

    let metadata = message.mailboxMetadata(
      connectionId: definition.connectionId,
      connectedAt: 0,
      roleMappings: definition.roleMappings
    )
    let customMailboxId = IMAPProviderMessage.customMailboxStateId("projects")

    #expect(!((metadata.providerStateIds ?? []).contains("ARCHIVE")))
    #expect((metadata.providerStateIds ?? []).contains(customMailboxId))
    #expect(
      MailboxMessageCollection.providerMailbox(customMailboxId)
        .contains(providerStateIds: metadata.providerStateIds, isSnoozed: false))
    #expect(
      !(MailboxMessageCollection.role(.archive)
        .contains(providerStateIds: metadata.providerStateIds, isSnoozed: false)))
  }

  @Test
  func testCancelledBackfillPersistsCompletedPagesAndResumesWithoutDuplicates() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = (1...120).map {
      imapMessage(uid: Int64($0), subject: "Message \($0)")
    }
    client.failOnMetadataRequest = 3
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition],
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)

    do {
      _ = try await adapter.continueHistoricalBackfill(
        connection: connection,
        session: session
      )
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    }
    let persisted = try await adapter.loadMailbox(
      .allObserved,
      connection: connection,
      session: session
    )
    #expect(persisted.messages.count == 100)

    client.failOnMetadataRequest = nil
    let completed = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    #expect(completed.messages.count == 120)
    #expect(Set(completed.messages.map(\.stableProviderMessageId)).count == 120)
    #expect(client.metadataRequestCount == 4)
  }

  @Test
  func testConnectionsRemainIsolatedAcrossSynchronization() async throws {
    let firstDefinition = imapDefinition(username: "first")
    let secondDefinition = imapDefinition(username: "second")
    let authorizationStore = RecordingIMAPAuthorizationStore()
    for definition in [firstDefinition, secondDefinition] {
      authorizationStore.save(
        DeviceLocalGenericMailAuthorization(credential: "secret", definition: definition),
        productAccountId: ProductAccountId(session.productAccountId)
      )
    }
    let client = RecordingIMAPClient()
    client.messagesByUsername[firstDefinition.username] = [
      imapMessage(uid: 1, subject: "First account")
    ]
    client.messagesByUsername[secondDefinition.username] = [
      imapMessage(uid: 1, subject: "Second account")
    ]
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [firstDefinition, secondDefinition]
    )
    let connections = try await adapter.loadConnections(session: session)
    for connection in connections {
      _ = try await adapter.syncInbox(connection: connection, session: session)
    }

    let results = try await connections.asyncMap { connection in
      try await adapter.loadMailbox(
        .allObserved,
        connection: connection,
        session: session
      )
    }

    #expect(results.map { $0.messages.count } == [1, 1])
    #expect(Set(results.flatMap(\.messages).map(\.connectionId)) == Set(connections.map(\.id)))
  }

  @Test
  func testOpenedBodyUsesSharedEncryptedCacheAcrossAdapterRecreation() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [imapMessage(uid: 1)]
    client.bodyByUID[1] = "Private body"
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let cache = FileGmailMessageBodyCache(rootDirectory: rootDirectory)
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      cache: cache,
      client: client,
      definitions: [definition],
      keyStore: keyStore,
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let synced = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(synced.messages.first)

    let first = try await adapter.loadMessageBody(message: message, session: session)
    let recreated = try makeAdapter(
      authorizationStore: authorizationStore,
      cache: cache,
      client: client,
      definitions: [definition],
      keyStore: keyStore,
      store: store
    )
    let second = try await recreated.loadMessageBody(message: message, session: session)

    #expect(first.text == "Private body")
    #expect(second == first)
    #expect(client.bodyRequestCount == 1)
  }

  @Test
  func testExplicitRawSourceLoadPreservesBytesAndUsesSharedEncryptedCache() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    let providerMessage = imapMessage(uid: 1)
    let rawData = Data("Subject: Exact\r\n\r\nBody\u{0}".utf8)
    client.messagesByUsername[definition.username] = [providerMessage]
    client.rawMessageByUID[providerMessage.uid] = rawData
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let cache = RecordingIMAPBodyCache()
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      cache: cache,
      client: client,
      definitions: [definition],
      keyStore: keyStore,
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let synced = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(synced.messages.first)

    let first = try await adapter.loadMessageSource(message: message, session: session)
    let second = try await adapter.loadMessageSource(message: message, session: session)

    #expect(first.raw == .exact(rawData))
    #expect(second == first)
    #expect(client.rawMessageRequestCount == 1)
  }

  @Test
  func testUnsupportedRawSourceUsesHonestMetadataFallback() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    let providerMessage = imapMessage(uid: 1)
    client.messagesByUsername[definition.username] = [providerMessage]
    client.rawMessageError = .operationUnsupported
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition],
      keyStore: keyStore,
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let synced = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(synced.messages.first)

    let source = try await adapter.loadMessageSource(message: message, session: session)

    #expect(source.headersAreExact == false)
    #expect(
      source.raw
        == .unavailable(
          reason: "This provider does not make exact RFC 822 bytes available."
        ))
  }

  @Test
  func testCalendarInvitationMetadataDoesNotFetchPartAndExplicitLoadUsesStoredSelector()
    async throws
  {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let invitation = CalendarInvitationDescriptor(
      byteCount: 512,
      contentTransferEncoding: "base64",
      mimeType: "text/calendar",
      providerAttachmentId: nil,
      providerMessageIdentity: "message-1",
      providerPartId: "2.1"
    )
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [
      imapMessage(calendarInvitation: invitation, uid: 1, hasAttachments: true)
    ]
    client.calendarInvitationDataByUID[1] = Data("BEGIN:VCALENDAR\r\nEND:VCALENDAR".utf8)
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition]
    )
    let connection = try #require(try await adapter.loadConnections(session: session).first)

    let sync = try await adapter.syncInbox(connection: connection, session: session)
    let message = try #require(sync.messages.first)
    let discovered = try #require(message.calendarInvitation)

    #expect(discovered == invitation)
    #expect(client.calendarInvitationRequestCount == 0)
    #expect(client.bodyRequestCount == 0)

    let data = try await adapter.loadCalendarInvitation(
      discovered,
      message: message,
      session: session
    )

    #expect(data == Data("BEGIN:VCALENDAR\r\nEND:VCALENDAR".utf8))
    #expect(client.calendarInvitationRequestCount == 1)
    #expect(client.lastCalendarInvitation == invitation)
    #expect(client.bodyRequestCount == 0)
  }

  @Test
  func testCalendarInvitationRejectsOversizeOrStaleDescriptorBeforePartFetch() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let invitation = CalendarInvitationDescriptor(
      byteCount: 512,
      mimeType: "text/calendar",
      providerAttachmentId: nil,
      providerMessageIdentity: "message-1",
      providerPartId: "2"
    )
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [
      imapMessage(calendarInvitation: invitation, uid: 1)
    ]
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition]
    )
    let connection = try #require(try await adapter.loadConnections(session: session).first)
    let message = try #require(
      try await adapter.syncInbox(connection: connection, session: session).messages.first
    )
    let stale = CalendarInvitationDescriptor(
      byteCount: 512,
      mimeType: "text/calendar",
      providerAttachmentId: nil,
      providerMessageIdentity: "message-1",
      providerPartId: "3"
    )
    let oversize = CalendarInvitationDescriptor(
      byteCount: CalendarInvitationDescriptor.maximumByteCount + 1,
      mimeType: "text/calendar",
      providerAttachmentId: nil,
      providerMessageIdentity: "message-1",
      providerPartId: "2"
    )

    await #expect(throws: MailboxMessageAttachmentError.self) {
      try await adapter.loadCalendarInvitation(stale, message: message, session: session)
    }
    await #expect(throws: CalendarInvitationParsingError.invitationTooLarge) {
      try await adapter.loadCalendarInvitation(oversize, message: message, session: session)
    }
    #expect(client.calendarInvitationRequestCount == 0)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testCachedBodyRejectsStaleAuthorizationGenerationAndClearsLocalData() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [imapMessage(uid: 1)]
    client.bodyByUID[1] = "Private body"
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let cache = FileGmailMessageBodyCache(rootDirectory: rootDirectory)
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      cache: cache,
      client: client,
      definitions: [definition],
      keyStore: keyStore,
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)
    _ = try await adapter.loadMessageBody(message: message, session: session)
    let staleAdapter = try makeAdapter(
      authorizationGeneration: 1,
      authorizationCleanupConnectionIds: [definition.connectionId],
      authorizationStore: authorizationStore,
      cache: cache,
      client: client,
      definitions: [definition],
      keyStore: keyStore,
      store: store
    )

    do {
      _ = try await staleAdapter.loadMessageBody(message: message, session: session)
      Issue.record("Expected stale authorization to reject a cached body fetch")
    } catch {
      #expect(error as? MailboxConnectionAdapterError == .authorizationRequired)
    }
    #expect(
      try authorizationStore.load(
        productAccountId: ProductAccountId(session.productAccountId),
        connectionId: connection.id
      ) == nil)
    #expect(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      ) == nil)
    #expect(client.bodyRequestCount == 1)
  }

  @Test
  func testUncachedBodyRejectsStaleAuthorizationGenerationAndClearsLocalData() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [imapMessage(uid: 1)]
    client.bodyByUID[1] = "Private body"
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let cache = FileGmailMessageBodyCache(rootDirectory: rootDirectory)
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      cache: cache,
      client: client,
      definitions: [definition],
      keyStore: keyStore,
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)
    let staleAdapter = try makeAdapter(
      authorizationGeneration: 1,
      authorizationCleanupConnectionIds: [definition.connectionId],
      authorizationStore: authorizationStore,
      cache: cache,
      client: client,
      definitions: [definition],
      keyStore: keyStore,
      store: store
    )

    do {
      _ = try await staleAdapter.loadMessageBody(message: message, session: session)
      Issue.record("Expected stale authorization to reject an uncached body fetch")
    } catch {
      #expect(error as? MailboxConnectionAdapterError == .authorizationRequired)
    }

    #expect(
      try authorizationStore.load(
        productAccountId: ProductAccountId(session.productAccountId),
        connectionId: connection.id
      ) == nil)
    #expect(client.bodyRequestCount == 0)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testUncachedBodyLoadFinishesBeforeConnectionCleanup() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let cache = RecordingIMAPBodyCache()
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [imapMessage(uid: 1)]
    client.bodyByUID[1] = "Private body"
    let providerGate = TestRendezvous()
    client.beforeBodyReturn = {
      await providerGate.hold()
    }
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let syncGate = MailboxConnectionSyncGate()
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      cache: cache,
      client: client,
      definitions: [definition],
      keyStore: keyStore,
      syncGate: syncGate
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)
    let bodyLoad = Task {
      try await adapter.loadMessageBody(message: message, session: session)
    }
    await providerGate.waitUntilHeld()
    let cleanupStarted = TestRendezvous()
    let cleanupFinished = TestFlag()
    let cleanup = Task {
      await cleanupStarted.hold()
      try await adapter.clearLocalConnection(connection, session: session)
      await cleanupFinished.set()
    }
    await cleanupStarted.waitUntilHeld()
    await cleanupStarted.release()
    await syncGate.waitUntilOperationIsQueued(connection.id)
    let cleanupFinishedEarly = await cleanupFinished.value

    #expect(!(cleanupFinishedEarly))
    await providerGate.release()
    let body = try await bodyLoad.value
    try await cleanup.value
    let cleanupDidFinish = await cleanupFinished.value

    #expect(body.text == "Private body")
    #expect(cleanupDidFinish)
    #expect(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      ) == nil)
  }

  @Test
  func testAcceptedSMTPSubmissionRetriesOnlyTheDurableSentCopy() async throws {
    let definition = imapDefinition(username: "sender")
    let engineSession = RecordingIMAPEngineSession(
      appendFailuresRemaining: 1,
      submissionOutcomes: [.accepted(serverMessageID: "server-message")]
    )
    let client = RecordingIMAPClient(
      engineCapabilities: [.uidPlus],
      engineSession: engineSession
    )
    let sentCopyStore = InMemoryStandardsMailSentCopyStore()
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition, engineCapabilities: [.uidPlus]),
      client: client,
      definitions: [definition],
      sentCopyStore: sentCopyStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let message = OutgoingMessage(
      body: "Hello from SwiftMail",
      recipient: "recipient@example.com",
      subject: "Durable Sent copy",
      idempotencyKey: "delivery-001"
    )

    do {
      try await adapter.send(message, connection: connection, session: session)
      Issue.record("Expected the failed Sent append to remain pending")
    } catch {
      #expect(error as? StandardsMailDeliveryError == .sentCopyPending)
    }

    #expect(await engineSession.submitCallCount() == 1)
    #expect(await engineSession.appendCallCount() == 1)
    #expect(
      try sentCopyStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ).map(\.idempotencyKey) == ["delivery-001"])

    let status = try await adapter.deliveryStatus(
      idempotencyKey: "delivery-001",
      connection: connection,
      session: session
    )

    #expect(status == .sent)
    #expect(await engineSession.submitCallCount() == 1)
    #expect(await engineSession.appendCallCount() == 2)
    #expect(
      try sentCopyStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ).isEmpty)
  }

  @Test
  func testStandardsMailSendClassifiesConnectionFailuresBeforeSubmission() async throws {
    let definition = imapDefinition(username: "sender")

    for (engineError, expectedError) in [
      (MailEngineError.authenticationRejected, StandardsMailDeliveryError.authenticationRequired),
      (
        MailEngineError.connectionClosed,
        StandardsMailDeliveryError.transientlyRejected(code: nil)
      ),
    ] {
      let client = RecordingIMAPClient(connectError: engineError)
      let adapter = try makeAdapter(
        authorizationStore: authorizedStore(definition),
        client: client,
        definitions: [definition]
      )
      let connections = try await adapter.loadConnections(session: session)
      let connection = try requireValue(connections.first)

      do {
        try await adapter.send(
          OutgoingMessage(body: "Body", recipient: "reader@example.com", subject: "Subject"),
          connection: connection,
          session: session
        )
        Issue.record("Expected the connection failure to be classified before submission.")
      } catch {
        #expect(error as? StandardsMailDeliveryError == expectedError)
      }
    }
  }

  @Test
  func testMarkReadProjectsUntilProviderSyncReconcilesThePendingAction() async throws {
    let definition = imapDefinition(username: "reader")
    let unreadMessage = imapMessage(uid: 1, subject: "Mark read")
    let engineSession = RecordingIMAPEngineSession()
    let client = RecordingIMAPClient(engineSession: engineSession)
    client.messagesByUsername[definition.username] = [unreadMessage]
    let pendingActionStore = InMemoryIMAPPendingActionStore()
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: client,
      definitions: [definition],
      pendingActionStore: pendingActionStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let initial = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(initial.messages.first)
    let selection = try await adapter.performTracked(
      .markRead,
      sourceProviderMailboxId: "INBOX",
      targetProviderMailboxId: nil,
      targetProviderStateIds: [],
      messages: [message],
      connection: connection,
      session: session
    )

    let failure = await adapter.resumePendingActions(
      connection: connection,
      session: session
    )
    let projected = try await adapter.loadInbox(connection: connection, session: session)

    #expect(failure == nil)
    #expect(projected.messages.first?.isUnread == false)
    #expect(pendingActionStore.actionCount == 1)

    client.messagesByUsername[definition.username] = [
      imapMessage(flags: ["\\Seen"], uid: 1, subject: "Mark read")
    ]
    let synchronized = try await adapter.syncInbox(connection: connection, session: session)

    #expect(synchronized.messages.first?.isUnread == false)
    #expect(pendingActionStore.actionCount == 0)
    if let selection {
      await adapter.releasePendingActionSelection(selection, connection: connection)
    }
  }

  @Test
  func testAcceptedMessageDoesNotWaitForAnotherPendingSentCopy() async throws {
    let definition = imapDefinition(username: "sender")
    let engineSession = RecordingIMAPEngineSession(
      appendFailuresRemaining: 1,
      submissionOutcomes: [.accepted(serverMessageID: nil)]
    )
    let sentCopyStore = InMemoryStandardsMailSentCopyStore()
    try sentCopyStore.save(
      [
        StandardsMailPendingSentCopy(
          connectionId: definition.connectionId,
          idempotencyKey: "older-delivery",
          mailbox: "Sent",
          rawMessage: Data("Message-ID: <older@example.com>\r\n\r\nOlder".utf8),
          rfcMessageId: "<older@example.com>"
        )
      ],
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId
    )
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: RecordingIMAPClient(engineSession: engineSession),
      definitions: [definition],
      sentCopyStore: sentCopyStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    try await adapter.send(
      OutgoingMessage(
        body: "Current",
        recipient: "recipient@example.com",
        subject: "Current delivery",
        idempotencyKey: "current-delivery"
      ),
      connection: connection,
      session: session
    )

    #expect(await engineSession.submitCallCount() == 1)
    #expect(await engineSession.appendCallCount() == 2)
    #expect(
      try sentCopyStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ).map(\.idempotencyKey) == ["older-delivery"])
  }

  @Test
  func testStandardsMailSendPreservesReplyAllRecipients() async throws {
    let definition = imapDefinition(username: "sender")
    let engineSession = RecordingIMAPEngineSession(
      submissionOutcomes: [.accepted(serverMessageID: nil)]
    )
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: RecordingIMAPClient(engineSession: engineSession),
      definitions: [definition]
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    try await adapter.send(
      OutgoingMessage(
        body: "Reply all",
        recipient: "first@example.com, \"Second, Person\" <second@example.com>, third@example.com",
        subject: "Reply all",
        idempotencyKey: "reply-all"
      ),
      connection: connection,
      session: session
    )

    let expectedRecipients = ["first@example.com", "second@example.com", "third@example.com"]
    #expect(await engineSession.lastRenderedRecipients() == expectedRecipients)
    #expect(await engineSession.lastSubmittedRecipients() == expectedRecipients)
  }

  @Test(
    "Standards Mail parses RFC 5322 recipient lists",
    .bug("https://github.com/unwired-dev/product/issues/441")
  )
  func standardsMailParsesRFCRecipientLists() async throws {
    let fixtures = [
      (
        value: "Ari (primary) <ari@example.com>, Bea <bea@example.com> (work)",
        expected: ["ari@example.com", "bea@example.com"]
      ),
      (
        value: "Friends: Ari <ari@example.com>, Bea <bea@example.com>;",
        expected: ["ari@example.com", "bea@example.com"]
      ),
      (
        value: #""Doe, Jane" <jane@example.com>, John <john@example.com>"#,
        expected: ["jane@example.com", "john@example.com"]
      ),
      (
        value: "CaseSensitive@Example.COM",
        expected: ["CaseSensitive@Example.COM"]
      ),
      (
        value: #""john..doe"@example.com, user@[127.0.0.1], postmaster@localhost"#,
        expected: [#""john..doe"@example.com"#, "user@[127.0.0.1]", "postmaster@localhost"]
      ),
      (
        value: "=?UTF-8?Q?Doe=2C_Jane?= <jane@example.com>",
        expected: ["jane@example.com"]
      ),
    ]

    for fixture in fixtures {
      #expect(RFCMailboxHeaderParser.recipientAddresses(in: fixture.value) == fixture.expected)
    }
  }

  @Test(
    "Standards Mail rejects malformed recipient lists before SMTP submission",
    .bug("https://github.com/unwired-dev/product/issues/441")
  )
  func standardsMailRejectsMalformedRecipientLists() async throws {
    let malformedLists = [
      "",
      " \t",
      "Friends: ari@example.com, bea@example.com",
      "victim@example.com: hidden@example.com;",
      "ari@example.com,,bea@example.com",
      "Ari <ari@example.com",
      #""Ari <ari@example.com>"#,
      "victim@example.com\r\nBcc: hidden@example.com",
      "victim@example.com\r\n Bcc: hidden@example.com",
    ]

    for recipient in malformedLists {
      let definition = imapDefinition(username: "sender")
      let engineSession = RecordingIMAPEngineSession(
        submissionOutcomes: [.accepted(serverMessageID: nil)]
      )
      let adapter = try makeAdapter(
        authorizationStore: authorizedStore(definition),
        client: RecordingIMAPClient(engineSession: engineSession),
        definitions: [definition]
      )
      let connections = try await adapter.loadConnections(session: session)
      let connection = try requireValue(connections.first)

      await #expect(throws: StandardsMailDeliveryError.invalidRecipients) {
        try await adapter.send(
          OutgoingMessage(body: "Body", recipient: recipient, subject: "Subject"),
          connection: connection,
          session: session
        )
      }
      #expect(await engineSession.lastRenderedRecipients() == nil)
      #expect(await engineSession.lastSubmittedRecipients() == nil)
    }
  }

  @Test
  func testAmbiguousSMTPSubmissionDoesNotCreateASentCopy() async throws {
    let definition = imapDefinition(username: "sender")
    let engineSession = RecordingIMAPEngineSession(submissionOutcomes: [.ambiguous])
    let sentCopyStore = InMemoryStandardsMailSentCopyStore()
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: RecordingIMAPClient(engineSession: engineSession),
      definitions: [definition],
      sentCopyStore: sentCopyStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    do {
      try await adapter.send(
        OutgoingMessage(
          body: "Hello",
          recipient: "recipient@example.com",
          subject: "Ambiguous",
          idempotencyKey: "delivery-ambiguous"
        ),
        connection: connection,
        session: session
      )
      Issue.record("Expected an ambiguous SMTP result")
    } catch {
      #expect(error as? StandardsMailDeliveryError == .ambiguous)
    }

    #expect(await engineSession.submitCallCount() == 1)
    #expect(await engineSession.appendCallCount() == 0)
    #expect(
      try sentCopyStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ).isEmpty)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testUIDPlusMoveResumesAfterDeleteUncertaintyWithoutCopyingAgain() async throws {
    let definition = imapDefinition(username: "mover")
    let sourceMessage = imapMessage(uid: 1, subject: "Move exactly once")
    let engineSession = RecordingIMAPEngineSession(deleteFailuresRemaining: 1)
    let client = RecordingIMAPClient(
      engineCapabilities: [.uidPlus],
      engineSession: engineSession
    )
    client.messagesByUsername[definition.username] = [sourceMessage]
    let metadataStore = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition, engineCapabilities: [.uidPlus]),
      client: client,
      definitions: [definition],
      store: metadataStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let syncResult = try await adapter.syncInbox(connection: connection, session: session)
    let syncedMessage = try requireValue(syncResult.messages.first)
    let trackedSelection = try await adapter.performTracked(
      .archive,
      sourceProviderMailboxId: "INBOX",
      targetProviderMailboxId: nil,
      targetProviderStateIds: [],
      messages: [syncedMessage],
      connection: connection,
      session: session
    )
    let selection = try requireValue(trackedSelection)
    await adapter.releasePendingActionSelection(selection, connection: connection)

    let firstFailure = await adapter.resumePendingActions(
      connection: connection,
      session: session
    )

    #expect(firstFailure != nil)
    #expect(await engineSession.copyCallCount() == 1)
    #expect(await engineSession.deleteCallCount() == 1)
    #expect(
      try metadataStore.loadPendingMove(
        sourceMessages: [sourceMessage],
        destinationMailbox: MailEngineMailboxIdentity("Archive"),
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )?.sourceDeletionRequired == true)

    let retryFailure = await adapter.retryBlockedPendingAction(
      connection: connection,
      session: session
    )
    let storedMessages = try metadataStore.loadMessages(
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
    let movedMessage = try requireValue(storedMessages.first)

    #expect(retryFailure == nil)
    #expect(await engineSession.copyCallCount() == 1)
    #expect(await engineSession.deleteCallCount() == 2)
    #expect(movedMessage.mailbox == "Archive")
    #expect(movedMessage.uid == 1_001)
    #expect(movedMessage.providerMessageId == sourceMessage.providerMessageId)
    #expect(
      try metadataStore.loadPendingMove(
        sourceMessages: [sourceMessage],
        destinationMailbox: MailEngineMailboxIdentity("Archive"),
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ) == nil)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testNativeMovePersistsServerMappingAndPreservesStableIdentity() async throws {
    let definition = imapDefinition(username: "native-mover")
    let invitation = CalendarInvitationDescriptor(
      byteCount: 512,
      dismissalIdentifier: "dismissed-invitation",
      mimeType: "text/calendar",
      providerAttachmentId: nil,
      providerPartId: "2"
    )
    let sourceMessage = imapMessage(
      calendarInvitation: invitation,
      uid: 2,
      subject: "Native move"
    )
    let engineSession = RecordingIMAPEngineSession()
    let client = RecordingIMAPClient(
      engineCapabilities: [.move, .uidPlus],
      engineSession: engineSession
    )
    client.messagesByUsername[definition.username] = [sourceMessage]
    let metadataStore = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition, engineCapabilities: [.move, .uidPlus]),
      client: client,
      definitions: [definition],
      store: metadataStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let syncResult = try await adapter.syncInbox(connection: connection, session: session)
    let syncedMessage = try requireValue(syncResult.messages.first)
    let trackedSelection = try await adapter.performTracked(
      .archive,
      sourceProviderMailboxId: "INBOX",
      targetProviderMailboxId: nil,
      targetProviderStateIds: [],
      messages: [syncedMessage],
      connection: connection,
      session: session
    )
    let selection = try requireValue(trackedSelection)
    await adapter.releasePendingActionSelection(selection, connection: connection)

    let failure = await adapter.resumePendingActions(connection: connection, session: session)
    let movedMessage = try requireValue(
      try metadataStore.loadMessages(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ).first
    )
    let projectedInbox = try await adapter.loadInbox(
      connection: connection,
      session: session
    )

    #expect(failure == nil)
    #expect(await engineSession.moveCallCount() == 1)
    #expect(await engineSession.copyCallCount() == 0)
    #expect(await engineSession.deleteCallCount() == 0)
    #expect(movedMessage.mailbox == "Archive")
    #expect(movedMessage.providerMessageId == sourceMessage.providerMessageId)
    #expect(movedMessage.calendarInvitation?.dismissalIdentifier == "dismissed-invitation")
    #expect(projectedInbox.messages.isEmpty)
    #expect(
      try metadataStore.loadPendingMove(
        sourceMessages: [sourceMessage],
        destinationMailbox: MailEngineMailboxIdentity("Archive"),
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ) == nil)

    client.mailboxesByUsername[definition.username] = [
      IMAPMailboxDescriptor(displayName: "Archive", name: "Archive")
    ]
    client.messagesByUsername[definition.username] = [
      imapMessage(
        calendarInvitation: CalendarInvitationDescriptor(
          byteCount: invitation.byteCount,
          mimeType: invitation.mimeType,
          providerAttachmentId: invitation.providerAttachmentId,
          providerMessageIdentity: "Archive\u{1f}2\u{1f}1002",
          providerPartId: invitation.providerPartId
        ),
        mailbox: "Archive",
        uid: 1_002,
        uidValidity: 2,
        subject: "Native move"
      )
    ]

    _ = try await adapter.syncInbox(connection: connection, session: session)
    let refreshedMessage = try #require(
      try metadataStore.loadMessages(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ).first
    )

    #expect(refreshedMessage.providerMessageId == sourceMessage.providerMessageId)
    #expect(refreshedMessage.calendarInvitation?.dismissalIdentifier == "dismissed-invitation")
  }

  private func authorizedStore(
    _ definition: GenericMailConnectionDefinition,
    engineCapabilities: Set<MailEngineCapability> = []
  ) -> RecordingIMAPAuthorizationStore {
    let store = RecordingIMAPAuthorizationStore()
    store.save(
      DeviceLocalGenericMailAuthorization(
        credential: "secret",
        definition: definition,
        engineCapabilities: engineCapabilities
      ),
      productAccountId: ProductAccountId(session.productAccountId)
    )
    return store
  }

  private func makeAdapter(
    authorizationGeneration: Int = 0,
    authorizationCleanupConnectionIds: [MailboxConnectionId] = [],
    authorizationStore: RecordingIMAPAuthorizationStore,
    cache: GmailMessageBodyCaching = RecordingIMAPBodyCache(),
    client: RecordingIMAPClient,
    definitionSyncService: MailboxConnectionDefinitionSyncing? = nil,
    definitions: [GenericMailConnectionDefinition],
    keyStore: ProductSyncKeyMaterialPersisting = InMemoryProductSyncKeyMaterialStore(),
    messageCategorizer: GmailMessageCategorizing? = nil,
    outboxStore: InMemoryIMAPOutboxStore = InMemoryIMAPOutboxStore(),
    pendingActionStore: InMemoryIMAPPendingActionStore = InMemoryIMAPPendingActionStore(),
    profileResolver: NotificationProfileResolving = LegacyNotificationProfileResolver(),
    sentCopyStore: InMemoryStandardsMailSentCopyStore = InMemoryStandardsMailSentCopyStore(),
    store: IMAPMessageMetadataPersisting? = nil,
    syncGate: MailboxConnectionSyncGate = MailboxConnectionSyncGate()
  ) throws -> IMAPMailboxConnectionAdapter {
    let metadataStore = try store ?? SwiftDataIMAPMessageMetadataStore.inMemory()
    return IMAPMailboxConnectionAdapter(
      authorizationStore: authorizationStore,
      cache: cache,
      client: client,
      definitionSyncService: definitionSyncService
        ?? RecordingIMAPDefinitionSyncService(
          authorizationGeneration: authorizationGeneration,
          authorizationCleanupConnectionIds: authorizationCleanupConnectionIds,
          definitions: definitions
        ),
      keyMaterialStore: keyStore,
      messageCategorizer: messageCategorizer,
      metadataStore: metadataStore,
      outboxService: OutboxDeliveryService(store: outboxStore),
      pendingActionService: PendingProviderActionService(
        store: pendingActionStore
      ),
      profileResolver: profileResolver,
      sentCopyStore: sentCopyStore,
      syncGate: syncGate
    )
  }

  private func makePersistedCategorizationFixture(
    messageCount: Int,
    completesBackfill: Bool = false
  ) async throws -> PersistedIMAPCategorizationFixture {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = (1...messageCount).map {
      imapMessage(uid: Int64($0), subject: "Message \($0)")
    }
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition],
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    if completesBackfill {
      _ = try await adapter.continueHistoricalBackfill(
        connection: connection,
        session: session
      )
    }
    return PersistedIMAPCategorizationFixture(
      authorizationStore: authorizationStore,
      client: client,
      connection: connection,
      definition: definition,
      store: store
    )
  }

  private func expectCategorized(
    _ result: MailboxMetadataSyncResult,
    count: Int
  ) {
    #expect(result.messages.count == count)
    #expect(result.messages.allSatisfy { $0.categoryId == "system:flights" })
    #expect(
      result.threads.flatMap(\.messages).allSatisfy {
        $0.categoryId == "system:flights"
      })
    #expect(
      result.threads.allSatisfy {
        $0.latestMessage.categoryId == "system:flights"
      })
  }
}

private enum IMAPAdapterTestError: Error {
  case unavailable
}

private struct PersistedIMAPCategorizationFixture {
  let authorizationStore: RecordingIMAPAuthorizationStore
  let client: RecordingIMAPClient
  let connection: MailboxConnection
  let definition: GenericMailConnectionDefinition
  let store: IMAPMessageMetadataPersisting
}

private final class AssigningIMAPCategorizer: GmailMessageCategorizing {
  let categoryId: String
  private(set) var categorizedRecordScopes: [MailProfileRecordScope] = []
  private(set) var categorizedStableIds: [String] = []
  let newMailOnly: Bool

  init(categoryId: String, newMailOnly: Bool = false) {
    self.categoryId = categoryId
    self.newMailOnly = newMailOnly
  }

  func categorize(
    messages: [GmailMessageMetadata],
    recordScope: MailProfileRecordScope,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    categorizedRecordScopes.append(recordScope)
    let eligibleMessages = messages.filter { !newMailOnly || !$0.isHistorical }
    categorizedStableIds = eligibleMessages.map(\.stableProviderMessageId)
    let eligibleIds = Set(eligibleMessages.map(\.id))
    return messages.map {
      eligibleIds.contains($0.id) ? $0.assigningCategory(categoryId) : $0
    }
  }

  func categorizeHistorical(
    messages: [GmailMessageMetadata],
    scope _: GmailHistoricalCategorizationScope,
    recordScope _: MailProfileRecordScope,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    messages
  }

  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    message.assigningCategory(categoryId)
  }
}

private struct FixedIMAPNotificationProfileResolver: NotificationProfileResolving {
  let resolution: NotificationProfileResolution

  func resolve(
    connectionId _: MailboxConnectionId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationProfileResolution {
    resolution
  }
}

private final class InMemoryIMAPOutboxStore: OutboxDeliveryPersisting, @unchecked Sendable {
  private var attempts: [OutgoingDeliveryAttempt] = []
  private(set) var saveCallCount = 0

  func load(productAccountId: String) throws -> [OutgoingDeliveryAttempt] {
    attempts.filter { $0.productAccountId.rawValue == productAccountId }
  }

  func save(
    _ attempts: [OutgoingDeliveryAttempt],
    productAccountId _: String
  ) throws {
    saveCallCount += 1
    self.attempts = attempts
  }
}

private final class InMemoryStandardsMailSentCopyStore:
  StandardsMailSentCopyPersisting, @unchecked Sendable
{
  private var copiesByConnectionId: [MailboxConnectionId: [StandardsMailPendingSentCopy]] = [:]

  func clear(productAccountId _: String) throws {
    copiesByConnectionId.removeAll()
  }

  func clear(
    productAccountId _: String,
    connectionId: MailboxConnectionId
  ) throws {
    copiesByConnectionId[connectionId] = nil
  }

  func load(
    productAccountId _: String,
    connectionId: MailboxConnectionId
  ) throws -> [StandardsMailPendingSentCopy] {
    copiesByConnectionId[connectionId, default: []]
  }

  func save(
    _ copies: [StandardsMailPendingSentCopy],
    productAccountId _: String,
    connectionId: MailboxConnectionId
  ) throws {
    copiesByConnectionId[connectionId] = copies
  }
}

private final class InMemoryIMAPPendingActionStore:
  PendingProviderActionPersisting, @unchecked Sendable
{
  private var actions: [PendingProviderAction] = []
  private(set) var saveCallCount = 0

  var actionCount: Int { actions.count }

  func load(productAccountId: String) throws -> [PendingProviderAction] {
    actions.filter { $0.productAccountId == productAccountId }
  }

  func save(
    _ actions: [PendingProviderAction],
    productAccountId _: String
  ) throws {
    saveCallCount += 1
    self.actions = actions
  }
}

private func imapDefinition(
  username: String,
  roleMappings: [CanonicalMailboxRole: String] = [
    .archive: "Archive",
    .drafts: "Drafts",
    .sent: "Sent",
    .spam: "Spam",
    .trash: "Trash",
  ]
) -> GenericMailConnectionDefinition {
  GenericMailConnectionDefinition(
    authorizationMethod: .password,
    emailAddress: "\(username)@example.com",
    incomingEndpoint: GenericMailEndpoint(
      mailProtocol: .imap,
      hostname: "imap.\(username).example.com",
      port: 993,
      security: .implicitTLS
    ),
    outgoingEndpoint: GenericMailEndpoint(
      mailProtocol: .smtp,
      hostname: "smtp.\(username).example.com",
      port: 465,
      security: .implicitTLS
    ),
    roleMappings: roleMappings,
    username: username
  )
}

private func imapMessage(
  calendarInvitation: CalendarInvitationDescriptor? = nil,
  flags: [String] = [],
  mailbox: String = "INBOX",
  uid: Int64,
  uidValidity: Int64 = 1,
  inReplyTo: String? = nil,
  references: [String] = [],
  rfcMessageId: String? = nil,
  providerEmailId: String? = nil,
  providerThreadId: String? = nil,
  hasAttachments: Bool = false,
  subject: String = "Subject"
) -> IMAPProviderMessage {
  IMAPProviderMessage(
    calendarInvitation: calendarInvitation,
    categoryId: nil,
    cc: nil,
    flags: flags,
    from: "Sender <sender@example.com>",
    hasAttachments: hasAttachments,
    inReplyTo: inReplyTo,
    internalDateMilliseconds: 1_781_200_000_000 + uid,
    mailbox: mailbox,
    providerEmailId: providerEmailId,
    providerThreadId: providerThreadId,
    references: references,
    replyTo: nil,
    rfcMessageId: rfcMessageId ?? "<message-\(uid)@example.com>",
    snippet: "Snippet",
    subject: subject,
    to: "reader@example.com",
    uid: uid,
    uidValidity: uidValidity
  )
}

private final class RecordingIMAPAuthorizationStore: GenericMailAuthorizationPersisting {
  private var authorizations: [String: DeviceLocalGenericMailAuthorization] = [:]

  func clearAll(productAccountId: ProductAccountId) throws {
    authorizations = authorizations.filter { !$0.key.hasPrefix("\(productAccountId.rawValue):") }
  }

  func load(
    productAccountId: ProductAccountId,
    emailAddress: String
  ) throws -> DeviceLocalGenericMailAuthorization? {
    authorizations.values.first { $0.definition.emailAddress == emailAddress }
  }

  func load(
    productAccountId: ProductAccountId,
    connectionId: MailboxConnectionId
  ) throws -> DeviceLocalGenericMailAuthorization? {
    authorizations[key(productAccountId: productAccountId, connectionId: connectionId)]
  }

  func remove(
    productAccountId: ProductAccountId,
    connectionId: MailboxConnectionId
  ) throws {
    authorizations[key(productAccountId: productAccountId, connectionId: connectionId)] = nil
  }

  func save(
    _ authorization: DeviceLocalGenericMailAuthorization,
    productAccountId: ProductAccountId
  ) {
    authorizations[
      key(productAccountId: productAccountId, connectionId: authorization.definition.connectionId)
    ] = authorization
  }

  private func key(
    productAccountId: ProductAccountId,
    connectionId: MailboxConnectionId
  ) -> String {
    "\(productAccountId.rawValue):\(connectionId.rawValue)"
  }
}

private final class RecordingIMAPDefinitionSyncService: MailboxConnectionDefinitionSyncing {
  var beforeLoadSnapshotReturn: ((Int) -> Void)?
  var loadError: Error?
  private var loadSnapshotCallCount = 0
  private var snapshot: MailboxConnectionSyncSnapshot

  init(
    authorizationGeneration: Int = 0,
    authorizationCleanupConnectionIds: [MailboxConnectionId] = [],
    definitions: [GenericMailConnectionDefinition],
    removedConnectionIds: [MailboxConnectionId] = []
  ) {
    snapshot = MailboxConnectionSyncSnapshot(
      connections: definitions.enumerated().map {
        $0.element.synchronizedDefinition(
          authorizationGeneration: authorizationGeneration,
          connectedAt: Int64($0.offset + 1)
        )
      },
      defaultSendingConnectionId: nil,
      removedConnectionIds: removedConnectionIds,
      updatedAt: 10,
      authorizationCleanupConnectionIds: authorizationCleanupConnectionIds
    )
  }

  func loadSnapshot(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    loadSnapshotCallCount += 1
    beforeLoadSnapshotReturn?(loadSnapshotCallCount)
    if let loadError { throw loadError }
    return snapshot
  }

  func replaceSnapshot(
    authorizationGeneration: Int = 0,
    definitions: [GenericMailConnectionDefinition],
    removedConnectionIds: [MailboxConnectionId]
  ) {
    snapshot = MailboxConnectionSyncSnapshot(
      connections: definitions.enumerated().map {
        $0.element.synchronizedDefinition(
          authorizationGeneration: authorizationGeneration,
          connectedAt: Int64($0.offset + 1)
        )
      },
      defaultSendingConnectionId: snapshot.defaultSendingConnectionId,
      removedConnectionIds: removedConnectionIds,
      updatedAt: snapshot.updatedAt
    )
  }

  func reconcileConnections(
    _ connections: [MailboxConnectionDefinition],
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    snapshot = MailboxConnectionSyncSnapshot(
      connections: connections,
      defaultSendingConnectionId: snapshot.defaultSendingConnectionId,
      removedConnectionIds: snapshot.removedConnectionIds,
      updatedAt: snapshot.updatedAt
    )
    return snapshot
  }

  func removeConnection(
    _ connectionId: MailboxConnectionId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    snapshot = MailboxConnectionSyncSnapshot(
      connections: snapshot.connections.filter { $0.id != connectionId },
      defaultSendingConnectionId: snapshot.defaultSendingConnectionId,
      removedConnectionIds: snapshot.removedConnectionIds + [connectionId],
      updatedAt: snapshot.updatedAt
    )
    return snapshot
  }

  func recreateDefinition(
    _ definition: MailboxConnectionDefinition,
    after _: MailboxConnectionRemovalObservation?,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    try await saveDefinition(definition, session: session)
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
    snapshot = MailboxConnectionSyncSnapshot(
      connections: snapshot.connections.filter { $0.id != definition.id } + [definition],
      defaultSendingConnectionId: snapshot.defaultSendingConnectionId,
      removedConnectionIds: snapshot.removedConnectionIds.filter { $0 != definition.id },
      updatedAt: snapshot.updatedAt
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
}

private actor RecordingIMAPEngineSession: MailEngineSession {
  private var appendFailuresRemaining: Int
  private var appendCalls = 0
  private var copyCalls = 0
  private var deleteCalls = 0
  private var deleteFailuresRemaining: Int
  private var renderedRecipientBatches: [[String]] = []
  private var messageIdsByMailbox: [MailEngineMailboxIdentity: Set<String>] = [:]
  private var moveCalls = 0
  private var submissionOutcomes: [MailEngineSMTPOutcome]
  private var submittedRecipientBatches: [[String]] = []
  private var submitCalls = 0

  init(
    appendFailuresRemaining: Int = 0,
    deleteFailuresRemaining: Int = 0,
    submissionOutcomes: [MailEngineSMTPOutcome] = []
  ) {
    self.appendFailuresRemaining = appendFailuresRemaining
    self.deleteFailuresRemaining = deleteFailuresRemaining
    self.submissionOutcomes = submissionOutcomes
  }

  func appendToSent(
    _ rawMessage: Data,
    mailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineMessageIdentity {
    appendCalls += 1
    if appendFailuresRemaining > 0 {
      appendFailuresRemaining -= 1
      throw MailEngineError.connectionClosed
    }
    if let messageId = Self.messageId(in: rawMessage) {
      messageIdsByMailbox[mailbox, default: []].insert(messageId)
    }
    return MailEngineMessageIdentity(
      connectionID: "test-engine",
      mailbox: mailbox,
      uid: Int64(appendCalls),
      uidValidity: 1
    )
  }

  func close() async {}

  func copy(
    messages: [MailEngineMessageIdentity],
    to destinationMailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping {
    copyCalls += 1
    return try Self.mapping(messages: messages, destinationMailbox: destinationMailbox)
  }

  func deletePermanently(
    _: [MailEngineMessageIdentity]
  ) async throws {
    deleteCalls += 1
    if deleteFailuresRemaining > 0 {
      deleteFailuresRemaining -= 1
      throw MailEngineError.operationOutcomeUnknown
    }
  }

  func fetchBodyParts(
    _: Set<MailEngineBodyPartSelector>,
    for _: MailEngineMessageIdentity
  ) async throws -> [MailEngineBodyPart] {
    []
  }

  func idle(
    mailbox _: MailEngineMailboxIdentity,
    onEvent _: @escaping @Sendable (MailEngineIdleEvent) async -> Void
  ) async throws {
    throw MailEngineError.connectionClosed
  }

  func containsMessage(
    rfcMessageID: String,
    mailbox: MailEngineMailboxIdentity
  ) async throws -> Bool {
    messageIdsByMailbox[mailbox, default: []].contains(rfcMessageID)
  }

  func loadTextBody(for _: MailEngineMessageIdentity) async throws -> String {
    "Body"
  }

  func loadMetadataPage(
    mailbox _: MailEngineMailboxIdentity,
    beforeUID _: Int64?,
    limit _: Int
  ) async throws -> MailEngineMetadataPage {
    MailEngineMetadataPage(messages: [], nextOlderUID: nil, uidValidity: 1)
  }

  func move(
    messages: [MailEngineMessageIdentity],
    to destinationMailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping {
    moveCalls += 1
    return try Self.mapping(messages: messages, destinationMailbox: destinationMailbox)
  }

  func renderMessage(
    _ message: MailEngineOutgoingMessage
  ) async throws -> Data {
    renderedRecipientBatches.append(message.recipients)
    let headers = [
      "Message-ID: \(message.messageID)",
      "From: \(message.sender)",
      "To: \(message.recipients.joined(separator: ", "))",
      "Subject: \(message.subject)",
    ].joined(separator: "\r\n")
    return Data(
      "\(headers)\r\n\r\n\(message.body)".utf8
    )
  }

  func submit(
    envelope: MailEngineEnvelope,
    rawMessage _: Data
  ) async throws -> MailEngineSMTPOutcome {
    submitCalls += 1
    submittedRecipientBatches.append(envelope.recipients)
    guard !submissionOutcomes.isEmpty else { return .accepted(serverMessageID: nil) }
    return submissionOutcomes.removeFirst()
  }

  func updateFlags(
    _: Set<String>,
    on _: [MailEngineMessageIdentity],
    mutation _: MailEngineFlagMutation
  ) async throws {}

  func appendCallCount() -> Int { appendCalls }

  func copyCallCount() -> Int { copyCalls }

  func deleteCallCount() -> Int { deleteCalls }

  func lastRenderedRecipients() -> [String]? { renderedRecipientBatches.last }

  func lastSubmittedRecipients() -> [String]? { submittedRecipientBatches.last }

  func moveCallCount() -> Int { moveCalls }

  func submitCallCount() -> Int { submitCalls }

  private static func mapping(
    messages: [MailEngineMessageIdentity],
    destinationMailbox: MailEngineMailboxIdentity
  ) throws -> MailEngineUIDMapping {
    guard let first = messages.first else { throw MailEngineError.operationUnsupported }
    return MailEngineUIDMapping(
      destinationMailbox: destinationMailbox,
      destinationUIDValidity: first.uidValidity + 1,
      pairs: messages.map {
        MailEngineUIDPair(destinationUID: $0.uid + 1_000, sourceUID: $0.uid)
      },
      sourceMailbox: first.mailbox,
      sourceUIDValidity: first.uidValidity
    )
  }

  private static func messageId(in rawMessage: Data) -> String? {
    String(data: rawMessage, encoding: .utf8)?
      .split(whereSeparator: \.isNewline)
      .first { $0.lowercased().hasPrefix("message-id:") }
      .map {
        String($0.dropFirst("message-id:".count))
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
  }
}

private final class RecordingIMAPClient: IMAPMailboxClient {
  var beforeBodyReturn: (() async -> Void)?
  var bodyByUID: [Int64: String] = [:]
  private(set) var bodyRequestCount = 0
  var calendarInvitationDataByUID: [Int64: Data] = [:]
  private(set) var calendarInvitationRequestCount = 0
  private let connectError: MailEngineError?
  private let engineCapabilities: Set<MailEngineCapability>
  private let engineSession: (any MailEngineSession)?
  var failOnMetadataRequest: Int?
  var mailboxesByUsername: [String: [IMAPMailboxDescriptor]] = [:]
  var messagesByUsername: [String: [IMAPProviderMessage]] = [:]
  var messagesByUsernameAndMailbox: [String: [String: [IMAPProviderMessage]]] = [:]
  private(set) var metadataRequestCount = 0
  var rawMessageByUID: [Int64: Data] = [:]
  var rawMessageError: MailEngineError?
  private(set) var rawMessageRequestCount = 0
  var uidValidityByUsername: [String: Int64] = [:]
  private(set) var lastCalendarInvitation: CalendarInvitationDescriptor?

  init(
    connectError: MailEngineError? = nil,
    engineCapabilities: Set<MailEngineCapability> = [],
    engineSession: (any MailEngineSession)? = nil
  ) {
    self.connectError = connectError
    self.engineCapabilities = engineCapabilities
    self.engineSession = engineSession
  }

  func connect(
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws -> (
    snapshot: MailEngineConnectionSnapshot,
    session: any MailEngineSession
  ) {
    if let connectError { throw connectError }
    guard let engineSession else { throw MailEngineError.operationUnsupported }
    return (
      snapshot: MailEngineConnectionSnapshot(
        capabilities: engineCapabilities,
        mailboxes: [],
        minimumTLSVersions: [.imap: .tls12, .smtp: .tls12]
      ),
      session: engineSession
    )
  }

  func listMailboxes(
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> [IMAPMailboxDescriptor] {
    mailboxesByUsername[authorization.definition.username]
      ?? [IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX")]
  }

  func loadMetadataPage(
    mailbox: IMAPMailboxDescriptor,
    beforeUID: Int64?,
    limit: Int,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> IMAPMetadataPage {
    metadataRequestCount += 1
    if metadataRequestCount == failOnMetadataRequest {
      throw CancellationError()
    }
    let username = authorization.definition.username
    let messages =
      messagesByUsernameAndMailbox[username]?[mailbox.name]
      ?? messagesByUsername[username, default: []].filter { $0.mailbox == mailbox.name }
    let eligible = messages.filter { message in
      beforeUID.map { message.uid < $0 } ?? true
    }
    .sorted { $0.uid < $1.uid }
    let pageMessages = Array(eligible.suffix(limit))
    let next = eligible.count > pageMessages.count ? pageMessages.first?.uid : nil
    return IMAPMetadataPage(
      messages: pageMessages,
      nextOlderUID: next,
      uidValidity: uidValidityByUsername[username] ?? pageMessages.first?.uidValidity ?? 1
    )
  }

  func loadTextBody(
    message: IMAPProviderMessage,
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws -> String {
    bodyRequestCount += 1
    await beforeBodyReturn?()
    return bodyByUID[message.uid] ?? "Body \(message.uid)"
  }

  func loadRawMessage(
    message: IMAPProviderMessage,
    maximumByteCount: Int,
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws -> Data {
    rawMessageRequestCount += 1
    if let rawMessageError { throw rawMessageError }
    let data = rawMessageByUID[message.uid] ?? Data()
    guard data.count <= maximumByteCount else {
      throw MailboxMessageSourceError.exceedsSizeLimit
    }
    return data
  }

  func loadCalendarInvitation(
    _ invitation: CalendarInvitationDescriptor,
    message: IMAPProviderMessage,
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws -> Data {
    calendarInvitationRequestCount += 1
    lastCalendarInvitation = invitation
    return calendarInvitationDataByUID[message.uid] ?? Data()
  }
}

private final class RecordingIMAPBodyCache: GmailMessageBodyCaching {
  private var payloads: [String: ProductSyncEncryptedPayload] = [:]

  func clearMessageBodies(productAccountId _: String) throws {
    payloads.removeAll()
  }

  func clearMessageBodies(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    payloads.removeAll()
  }

  func loadMessageBody(
    productAccountId _: String,
    stableProviderMessageId: String
  ) throws -> ProductSyncEncryptedPayload? {
    payloads[stableProviderMessageId]
  }

  func removeMessageBody(
    productAccountId _: String,
    stableProviderMessageId: String
  ) throws {
    payloads[stableProviderMessageId] = nil
  }

  func saveMessageBody(
    _ payload: ProductSyncEncryptedPayload,
    productAccountId _: String,
    stableProviderMessageId: String
  ) throws {
    payloads[stableProviderMessageId] = payload
  }

  func reconcileSelection(
    productAccountId _: String,
    providerAccountIdentifier _: String,
    protectedMessageIds _: Set<String>,
    pinnedMessageIds _: Set<String>
  ) throws {}

  func recordMessageBodyAccess(
    productAccountId _: String,
    stableProviderMessageId _: String,
    accessedAt _: Date
  ) throws {}
}

private actor RouterOperationGate {
  private var hasReleased = false
  private var hasStarted = false
  private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
  private var startContinuations: [CheckedContinuation<Void, Never>] = []

  func waitForRelease() async {
    hasStarted = true
    let continuations = startContinuations
    startContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
    guard !hasReleased else { return }
    await withCheckedContinuation { releaseContinuations.append($0) }
  }

  func waitUntilStarted() async {
    guard !hasStarted else { return }
    await withCheckedContinuation { startContinuations.append($0) }
  }

  func release() {
    hasReleased = true
    let continuations = releaseContinuations
    releaseContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }
}

private final class RouterTestAdapter: MailboxConnectionAdapter, @unchecked Sendable {
  private let blockedConnectionIds: [MailboxConnectionId]
  private let connections: [MailboxConnection]
  private let loadError: Error?
  private let loadGate: RouterOperationGate?
  private let pendingActionError: String?
  private let pendingActionGate: RouterOperationGate?
  private let removalError: Error?

  init(
    blockedConnectionIds: [MailboxConnectionId] = [],
    connections: [MailboxConnection] = [],
    loadError: Error? = nil,
    loadGate: RouterOperationGate? = nil,
    pendingActionError: String? = nil,
    pendingActionGate: RouterOperationGate? = nil,
    removalError: Error? = nil
  ) {
    self.blockedConnectionIds = blockedConnectionIds
    self.connections = connections
    self.loadError = loadError
    self.loadGate = loadGate
    self.pendingActionError = pendingActionError
    self.pendingActionGate = pendingActionGate
    self.removalError = removalError
  }

  func clearLocalConnection(session _: ProductAccountSessionSnapshot) async throws {}

  func clearLocalConnection(
    _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  @MainActor
  func connect(
    expectedConnectionId _: MailboxConnectionId?,
    removalObservation _: MailboxConnectionRemovalObservation?,
    session _: ProductAccountSessionSnapshot,
    isSessionCurrent _: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection? {
    nil
  }

  func loadConnections(
    session _: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    await loadGate?.waitForRelease()
    if let loadError { throw loadError }
    return connections
  }

  func loadDefaultSendingConnectionId(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionId? {
    nil
  }

  func removeMailboxConnectionEverywhere(
    _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    if let removalError { throw removalError }
  }

  func setDefaultSendingConnection(
    _: MailboxConnection?,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func categorizeHistorical(
    scope _: HistoricalCategorizationScope,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func loadInbox(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func syncInbox(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection _: MailboxConnection,
    includingHistoryCandidates _: Bool,
    session _: ProductAccountSessionSnapshot,
    sinceHistoryId _: String?,
    throughHistoryId _: String?,
    shouldPersist _: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func overrideCategory(
    _: String,
    for _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func setCategories(
    _: [String],
    for _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func searchProvider(
    query _: String,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata] {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func prefetchMessageBodies(
    connection _: MailboxConnection,
    pinnedThreadIds _: Set<StableThreadIdentity>,
    referenceDate _: Date,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func clearCachedMessageBodies(session _: ProductAccountSessionSnapshot) throws {}

  func clearCachedMessageBodies(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) throws {}

  func loadMessageBody(
    message _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func removeCachedMessageBody(
    message _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws {}

  func registerOrRenewPush(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func perform(
    _: ProviderMailAction,
    messages _: [MailboxMessageMetadata],
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func resumePendingActions(
    connections _: [MailboxConnection],
    session _: ProductAccountSessionSnapshot
  ) async -> String? {
    await pendingActionGate?.waitForRelease()
    return pendingActionError
  }

  func blockedPendingActionConnectionIds(
    connections _: [MailboxConnection],
    session _: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    await pendingActionGate?.waitForRelease()
    return blockedConnectionIds
  }

  func send(
    _: OutgoingMessage,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
}

private func routerConnection(
  providerId: MailProviderId,
  displayName: String
) -> MailboxConnection {
  MailboxConnection(
    authorizationState: .authorized,
    capabilities: .none,
    connectedAt: 1,
    displayName: displayName,
    id: MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: providerId,
        value: displayName.lowercased()
      )
    ),
    lastVerifiedAt: 1,
    productAccountId: ProductAccountId("product-account-001"),
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1
  )
}

extension Collection {
  fileprivate func asyncMap<T>(
    _ transform: (Element) async throws -> T
  ) async rethrows -> [T] {
    var results: [T] = []
    for element in self {
      results.append(try await transform(element))
    }
    return results
  }
}
