import Foundation
import SwiftMail
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
  func testAuthorizedIMAPConnectionJoinsProviderNeutralConnectionList() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = RecordingIMAPAuthorizationStore()
    authorizationStore.save(
      DeviceLocalGenericMailAuthorization(credential: "secret", definition: definition),
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
    #expect(connections[0].capabilities == .imapRead)
    #expect(connections[0].id == definition.connectionId)
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
        .contains(providerStateIds: metadata.providerStateIds))
    #expect(
      !(MailboxMessageCollection.role(.archive)
        .contains(providerStateIds: metadata.providerStateIds)))
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

  @Test(arguments: [[], ["system:invoices", "system:travel"]])
  func testSetCategoriesRejectsUnsupportedCountsWithoutMutatingMetadata(
    _ categoryIds: [String]
  ) async throws {
    let definition = imapDefinition(username: "reader")
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [imapMessage(uid: 1)]
    let store = try SwiftDataIMAPMessageMetadataStore.inMemory()
    let adapter = try makeAdapter(
      authorizationStore: authorizedStore(definition),
      client: client,
      definitions: [definition],
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)

    do {
      _ = try await adapter.setCategories(categoryIds, for: message, session: session)
      Issue.record("Expected unsupported category count to be rejected")
    } catch {
      #expect(error as? MailboxConnectionAdapterError == .unsupportedProvider)
    }

    let stored = try requireValue(
      store.loadProviderMessage(
        stableProviderMessageId: message.stableProviderMessageId,
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ))
    #expect(stored.categoryId == nil)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testOpenedBodyCachesAttachmentDescriptorsAndDownloadsPart() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let attachment = MailboxMessageAttachment(
      byteCount: 4,
      filename: "report.pdf",
      id: "imap-body-part:2",
      mimeType: "application/pdf"
    )
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [
      imapMessage(uid: 1, hasAttachments: true)
    ]
    client.bodyByUID[1] = "Private body"
    client.attachmentsByUID[1] = [attachment]
    client.attachmentDataByID[attachment.id] = Data("PDF".utf8)
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
    let data = try await recreated.loadMessageAttachment(
      attachment,
      message: message,
      session: session
    )

    #expect(first.attachments == [attachment])
    #expect(second == first)
    #expect(data == Data("PDF".utf8))
    #expect(client.bodyRequestCount == 1)
    #expect(client.attachmentRequestCount == 1)
  }

  @Test
  func testPrefetchedBodyRefreshesAttachmentDescriptorsWhenOpened() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let attachment = MailboxMessageAttachment(
      byteCount: 4,
      filename: "report.pdf",
      id: "imap-body-part:2",
      mimeType: "application/pdf"
    )
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [
      imapMessage(uid: 1, hasAttachments: true)
    ]
    client.bodyByUID[1] = "Private body"
    client.attachmentsByUID[1] = [attachment]
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition],
      keyStore: keyStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)

    try await adapter.prefetchMessageBodies(
      connection: connection,
      pinnedThreadIds: [message.threadIdentity],
      referenceDate: Date(timeIntervalSince1970: 1_781_200_100),
      session: session
    )
    let body = try await adapter.loadMessageBody(message: message, session: session)

    #expect(body.attachments == [attachment])
    #expect(client.bodyRequestCount == 2)
  }

  @Test
  func testAttachmentDownloadPropagatesCancellation() async throws {
    let definition = imapDefinition(username: "reader")
    let authorizationStore = authorizedStore(definition)
    let attachment = MailboxMessageAttachment(
      byteCount: 4,
      filename: "report.pdf",
      id: "imap-body-part:2",
      mimeType: "application/pdf"
    )
    let client = RecordingIMAPClient()
    client.messagesByUsername[definition.username] = [
      imapMessage(uid: 1, hasAttachments: true)
    ]
    client.attachmentsByUID[1] = [attachment]
    client.attachmentDataByID[attachment.id] = Data("PDF".utf8)
    let providerGate = TestRendezvous()
    client.beforeAttachmentReturn = {
      await providerGate.hold()
    }
    let adapter = try makeAdapter(
      authorizationStore: authorizationStore,
      client: client,
      definitions: [definition]
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)
    let download = Task {
      try await adapter.loadMessageAttachment(
        attachment,
        message: message,
        session: session
      )
    }
    await providerGate.waitUntilHeld()

    download.cancel()
    await providerGate.release()

    do {
      _ = try await download.value
      Issue.record("Expected attachment cancellation to propagate")
    } catch is CancellationError {
      #expect(client.attachmentRequestCount == 1)
    }
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
    try await Task.sleep(for: .milliseconds(20))
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
  func testRepresentativeServerListTranscripts() async throws {
    let transcripts: [(String, String)] = [
      (#"* LIST (\HasNoChildren) "/" "INBOX""#, "INBOX"),
      (#"* LIST (\HasChildren) "/" "Projects""#, "Projects"),
      (#"* LIST (\HasNoChildren) "." "&AMk-l&AOk-ments""#, "Éléments"),
    ]
    for (listLine, expectedName) in transcripts {
      let task = TranscriptIMAPStreamTask(
        responses: [
          "* OK ready\r\n",
          "A1 OK authenticated\r\n",
          "\(listLine)\r\nA2 OK listed\r\n",
        ]
      )
      let client = SystemIMAPMailboxClient(
        streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [task])
      )

      let mailboxes = try await client.listMailboxes(
        authorization: DeviceLocalGenericMailAuthorization(
          credential: "secret",
          definition: imapDefinition(username: "reader")
        )
      )

      #expect(mailboxes.map(\.displayName) == [expectedName])
    }
  }

  @Test
  func testSwiftMailMapsOrdinaryAttachmentsAndFetchesOnlyPreferredBody() async throws {
    let message = Message(
      header: MessageInfo(sequenceNumber: SequenceNumber(1), uid: UID(7)),
      parts: [
        MessagePart(sectionString: "1", contentType: "text/plain", encoding: "7bit", size: 5),
        MessagePart(
          sectionString: "2",
          contentType: "application/pdf",
          disposition: "attachment",
          encoding: "base64",
          filename: "report.pdf",
          size: 4
        ),
        MessagePart(
          sectionString: "3",
          contentType: "image/png",
          disposition: "inline",
          encoding: "base64",
          filename: "inline.png",
          contentId: "hero",
          size: 4
        ),
      ]
    )
    var fetchedSections: [String] = []

    let body = try await SwiftMailIMAPMessageContentLoader.messageBody(in: message) { part in
      fetchedSections.append(part.section.description)
      return Data("Hello".utf8)
    }

    #expect(body.text == "Hello")
    #expect(fetchedSections == ["1"])
    #expect(
      body.attachments == [
        MailboxMessageAttachment(
          byteCount: 3,
          filename: "report.pdf",
          id: "swiftmail-body-part:2",
          mimeType: "application/pdf"
        )
      ])
  }

  @Test
  func testSwiftMailAllowsAttachmentOnlyMessages() async throws {
    let message = Message(
      header: MessageInfo(sequenceNumber: SequenceNumber(1), uid: UID(7)),
      parts: [
        MessagePart(
          sectionString: "1",
          contentType: "application/pdf",
          disposition: "attachment",
          filename: "report.pdf",
          size: 5
        )
      ]
    )

    let body = try await SwiftMailIMAPMessageContentLoader.messageBody(in: message) { _ in
      Issue.record("Attachment-only messages must not fetch a text part")
      return Data()
    }

    #expect(body.text.isEmpty)
    #expect(body.attachments.map(\.filename) == ["report.pdf"])
  }

  @Test
  func testSwiftMailDoesNotTreatTransferEncodedSizeAsDecodedPolicySize() throws {
    let maximumDecodedByteCount = MailboxMessageAttachmentPolicy.maximumByteCount
    let encodedBase64ByteCount = 4 * ((maximumDecodedByteCount + 2) / 3)
    let message = Message(
      header: MessageInfo(sequenceNumber: SequenceNumber(1), uid: UID(7)),
      parts: [
        MessagePart(
          sectionString: "1",
          contentType: "application/pdf",
          disposition: "attachment",
          encoding: "base64",
          filename: "maximum.pdf",
          size: encodedBase64ByteCount
        )
      ]
    )

    let attachments = SwiftMailIMAPMessageContentLoader.attachments(in: message)

    #expect(attachments.count == 1)
    #expect(attachments.first?.attachment.byteCount == 0)
    #expect(attachments.first?.part.size == encodedBase64ByteCount)
  }

  @Test
  func testSwiftMailMatchesAttachmentByStableIdentifier() throws {
    let message = Message(
      header: MessageInfo(sequenceNumber: SequenceNumber(1), uid: UID(7)),
      parts: [
        MessagePart(
          sectionString: "2",
          contentType: "application/pdf",
          disposition: "attachment",
          encoding: "base64",
          filename: "report.pdf",
          size: 4
        )
      ]
    )
    let cachedAttachment = MailboxMessageAttachment(
      byteCount: 0,
      filename: "cached-name.pdf",
      id: "swiftmail-body-part:2",
      mimeType: "application/octet-stream"
    )

    let selected = SwiftMailIMAPMessageContentLoader.attachment(
      withID: cachedAttachment.id,
      in: message
    )

    #expect(selected?.attachment.filename == "report.pdf")
    #expect(selected?.part.size == 4)
  }

  @Test
  func testSystemClientUsesObjectIdForStableIdentityAndThreading() async throws {
    let headers = "Message-ID: <fallback@example.com>\r\nSubject: Object identity\r\n"
    let fetch =
      "* 1 FETCH (UID 7 FLAGS (\\Seen) INTERNALDATE \" 7-Jul-2026 09:00:00 +0000\" "
      + "EMAILID (email-7) THREADID (thread-4) "
      + #"BODYSTRUCTURE (("TEXT" "PLAIN" ("CHARSET" "UTF-8") "#
      + #"NIL NIL "7BIT" 12 1 NIL NIL NIL)("APPLICATION" "PDF" "#
      + #"("NAME" "file.pdf") NIL NIL "BASE64" 100 NIL "#
      + #"("ATTACHMENT" ("FILENAME" "file.pdf")) NIL) "MIXED") "#
      + "BODY[HEADER.FIELDS (CC FROM IN-REPLY-TO MESSAGE-ID REFERENCES REPLY-TO SUBJECT TO)] "
      + "{\(headers.utf8.count)}\r\n\(headers))\r\nA5 OK fetched\r\n"
    let task = TranscriptIMAPStreamTask(
      responses: [
        "* OK ready\r\n",
        "A1 OK authenticated\r\n",
        "* CAPABILITY IMAP4rev1 OBJECTID\r\nA2 OK capable\r\n",
        "* OK [UIDVALIDITY 9] selected\r\nA3 OK selected\r\n",
        "* SEARCH 7\r\nA4 OK searched\r\n",
        fetch,
      ]
    )
    let client = SystemIMAPMailboxClient(
      streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [task])
    )

    let page = try await client.loadMetadataPage(
      mailbox: IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX"),
      beforeUID: nil,
      limit: 50,
      authorization: DeviceLocalGenericMailAuthorization(
        credential: "secret",
        definition: imapDefinition(username: "reader")
      )
    )

    #expect(page.messages.first?.providerMessageId == "imap-email:email-7")
    #expect(page.messages.first?.providerThreadId == "thread-4")
    #expect(page.messages.first?.hasAttachments == true)
    #expect(task.writes.contains { $0.contains("EMAILID THREADID") })
    #expect(task.writes.contains { $0.contains("BODYSTRUCTURE") })
  }

  @Test
  func testSystemClientRecognizesGreenMailAttachmentBodyStructure() async throws {
    let headers =
      "Message-ID: <message-content-attachment@synthetic.invalid>\r\n"
      + "Subject: Fixture Attachment\r\n"
    let bodyStructure =
      #"(("text" "plain" ("charset" "utf-8") NIL NIL "8bit" 112 3 NIL NIL NIL)"#
      + #"("text" "plain" ("name" "synthetic-note.txt") NIL NIL "base64" 194 4 NIL "#
      + #"("attachment" ("filename" "synthetic-note.txt")) NIL) "mixed" "#
      + #"("boundary" "attachment-fixture-boundary") NIL NIL)"#
    let fetch =
      "* 5 FETCH (UID 5 FLAGS (\\Seen) INTERNALDATE \" 7-Jul-2026 09:00:00 +0000\" "
      + "BODYSTRUCTURE \(bodyStructure) "
      + "BODY[HEADER.FIELDS (CC FROM IN-REPLY-TO MESSAGE-ID REFERENCES REPLY-TO SUBJECT TO)] "
      + "{\(headers.utf8.count)}\r\n\(headers))\r\nA5 OK fetched\r\n"
    let task = TranscriptIMAPStreamTask(
      responses: [
        "* OK ready\r\n",
        "A1 OK authenticated\r\n",
        "* CAPABILITY IMAP4rev1\r\nA2 OK capable\r\n",
        "* OK [UIDVALIDITY 9] selected\r\nA3 OK selected\r\n",
        "* SEARCH 5\r\nA4 OK searched\r\n",
        fetch,
      ]
    )
    let client = SystemIMAPMailboxClient(
      streamTaskFactory: TranscriptIMAPStreamTaskFactory(tasks: [task])
    )

    let page = try await client.loadMetadataPage(
      mailbox: IMAPMailboxDescriptor(displayName: "Inbox", name: "INBOX"),
      beforeUID: nil,
      limit: 50,
      authorization: DeviceLocalGenericMailAuthorization(
        credential: "secret",
        definition: imapDefinition(username: "reader")
      )
    )

    #expect(page.messages.first?.hasAttachments == true)
  }

  private func authorizedStore(
    _ definition: GenericMailConnectionDefinition
  ) -> RecordingIMAPAuthorizationStore {
    let store = RecordingIMAPAuthorizationStore()
    store.save(
      DeviceLocalGenericMailAuthorization(credential: "secret", definition: definition),
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
  private(set) var categorizedStableIds: [String] = []
  let newMailOnly: Bool

  init(categoryId: String, newMailOnly: Bool = false) {
    self.categoryId = categoryId
    self.newMailOnly = newMailOnly
  }

  func categorize(
    messages: [GmailMessageMetadata],
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
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

private final class InMemoryIMAPPendingActionStore:
  PendingProviderActionPersisting, @unchecked Sendable
{
  private var actions: [PendingProviderAction] = []
  private(set) var saveCallCount = 0

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
  let message = IMAPProviderMessage(
    categoryId: nil,
    cc: nil,
    flags: [],
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
  return message
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

private final class RecordingIMAPClient: IMAPMailboxClient {
  var attachmentDataByID: [String: Data] = [:]
  private(set) var attachmentRequestCount = 0
  var attachmentsByUID: [Int64: [MailboxMessageAttachment]] = [:]
  var beforeAttachmentReturn: (() async -> Void)?
  var beforeBodyReturn: (() async -> Void)?
  var bodyByUID: [Int64: String] = [:]
  private(set) var bodyRequestCount = 0
  var failOnMetadataRequest: Int?
  var mailboxesByUsername: [String: [IMAPMailboxDescriptor]] = [:]
  var messagesByUsername: [String: [IMAPProviderMessage]] = [:]
  var messagesByUsernameAndMailbox: [String: [String: [IMAPProviderMessage]]] = [:]
  private(set) var metadataRequestCount = 0
  var uidValidityByUsername: [String: Int64] = [:]

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

  func loadMessageBody(
    message: IMAPProviderMessage,
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws -> MailboxMessageBody {
    bodyRequestCount += 1
    await beforeBodyReturn?()
    return MailboxMessageBody(
      text: bodyByUID[message.uid] ?? "Body \(message.uid)",
      attachments: attachmentsByUID[message.uid] ?? []
    )
  }

  func loadMessageAttachment(
    _ attachment: MailboxMessageAttachment,
    message _: IMAPProviderMessage,
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws -> Data {
    attachmentRequestCount += 1
    await beforeAttachmentReturn?()
    try Task.checkCancellation()
    guard let data = attachmentDataByID[attachment.id] else {
      throw MailboxMessageAttachmentError.invalidResponse
    }
    return data
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

private final class TranscriptIMAPStreamTaskFactory: GenericMailStreamTaskCreating {
  private var tasks: [TranscriptIMAPStreamTask]

  init(tasks: [TranscriptIMAPStreamTask]) {
    self.tasks = tasks
  }

  func makeStreamTask(
    hostname _: String,
    port _: Int,
    minimumTransportVersion _: MailTransportVersion
  ) -> GenericMailStreamTasking {
    tasks.removeFirst()
  }
}

private final class TranscriptIMAPStreamTask: GenericMailStreamTasking {
  private var responses: [Data]
  private(set) var writes: [String] = []

  init(responses: [String]) {
    self.responses = responses.map { Data($0.utf8) }
  }

  init(responsesData: [Data]) {
    responses = responsesData
  }

  func close() {}

  func read() async throws -> String {
    guard !responses.isEmpty else { throw IMAPMailboxError.invalidProviderResponse }
    guard let response = String(data: responses.removeFirst(), encoding: .utf8) else {
      throw IMAPMailboxError.invalidProviderResponse
    }
    return response
  }

  func readData() async throws -> Data {
    guard !responses.isEmpty else { throw IMAPMailboxError.invalidProviderResponse }
    return responses.removeFirst()
  }

  func resume() {}

  func startSecureConnection() {}

  func write(_ value: String) async throws {
    writes.append(value)
  }
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
