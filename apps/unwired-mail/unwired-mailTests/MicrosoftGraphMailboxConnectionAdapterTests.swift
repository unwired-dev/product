import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length type_name

@MainActor
final class MicrosoftGraphMailboxConnectionAdapterTests: XCTestCase {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "product-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  func testOAuthRequestUsesPKCEAndValidatesTheCallbackState() throws {
    let request = MicrosoftGraphOAuthRequest(
      callbackScheme: "dev.unwired.mail.microsoft",
      clientIdentifier: "client-id"
    )
    let queryItems = try XCTUnwrap(
      URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems
    )
    let values = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })
    let state = try XCTUnwrap(values["state"] ?? nil)

    XCTAssertEqual(values["client_id"], "client-id")
    XCTAssertEqual(values["code_challenge_method"], "S256")
    XCTAssertFalse(try XCTUnwrap(values["code_challenge"] ?? nil).isEmpty)
    XCTAssertTrue(try XCTUnwrap(values["scope"] ?? nil).contains("offline_access"))
    XCTAssertEqual(
      try request.authorizationCode(
        from: URL(string: "dev.unwired.mail.microsoft:/oauthredirect?code=code-1&state=\(state)")!
      ),
      "code-1"
    )
    XCTAssertThrowsError(
      try request.authorizationCode(
        from: URL(
          string: "dev.unwired.mail.microsoft:/oauthredirect?code=code-1&state=incorrect"
        )!
      )
    ) {
      XCTAssertEqual($0 as? MicrosoftGraphOAuthError, .invalidAuthorizationState)
    }
  }

  func testConnectKeepsTokensDeviceLocalAndSynchronizesOnlyTheDefinition() async throws {
    let authorizer = RecordingMicrosoftGraphAuthorizer()
    let client = RecordingMicrosoftGraphClient()
    let definitions = RecordingMicrosoftGraphDefinitionSyncService()
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    let adapter = try makeAdapter(
      authorizer: authorizer,
      client: client,
      definitions: definitions,
      tokenStore: tokenStore
    )

    let connection = try await adapter.connect(
      session: session,
      isSessionCurrent: { $0 == self.session }
    )
    let reconnected = try await adapter.connect(
      session: session,
      isSessionCurrent: { $0 == self.session }
    )

    XCTAssertEqual(connection?.id, graphConnectionId)
    XCTAssertEqual(reconnected?.id, graphConnectionId)
    XCTAssertEqual(definitions.definitions.count, 1)
    XCTAssertEqual(connection?.authorizationState, .authorized)
    XCTAssertEqual(definitions.savedDefinition?.provider, MailProviderId.microsoftGraph.rawValue)
    XCTAssertEqual(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: graphAccount.id
      ),
      authorizer.authorizedTokens
    )
    let encodedDefinition = try JSONEncoder().encode(definitions.savedDefinition)
    let definitionJSON = try XCTUnwrap(String(data: encodedDefinition, encoding: .utf8))
    XCTAssertFalse(definitionJSON.contains(authorizer.authorizedTokens.accessToken))
    XCTAssertFalse(definitionJSON.contains(authorizer.authorizedTokens.refreshToken))
  }

  func testInitialFiftyMessagesRemainAvailableWhileBackfillResumesAfterRecreation() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: (26...75).reversed().map { graphMessage($0) },
      nextLink: URL(string: "https://graph.microsoft.test/inbox/page-2"),
      deltaLink: nil
    )
    client.pages[
      pageKey(
        folderId: "inbox-id",
        continuation: "https://graph.microsoft.test/inbox/page-2"
      )
    ] = MicrosoftGraphMetadataPage(
      messages: (1...25).reversed().map { graphMessage($0) },
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta-1")
    )
    let store = try SwiftDataMicrosoftGraphMetadataStore.inMemory()
    let firstAdapter = try authorizedAdapter(client: client, store: store)
    let loadedConnections = try await firstAdapter.loadConnections(session: session)
    let connection = try XCTUnwrap(loadedConnections.first)

    let initial = try await firstAdapter.syncInbox(connection: connection, session: session)

    XCTAssertTrue(initial.hasInitialMailboxAvailability)
    XCTAssertFalse(initial.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(initial.messages.count, 50)
    XCTAssertEqual(initial.messages.first?.subject, "Message 75")

    let recreated = try authorizedAdapter(client: client, store: store)
    let complete = try await recreated.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    XCTAssertTrue(complete.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(complete.messages.count, 75)
    XCTAssertEqual(complete.messages.last?.subject, "Message 1")
    XCTAssertEqual(client.requestedContinuations.last, "https://graph.microsoft.test/inbox/page-2")
  }

  func testInitialAvailabilityAccumulatesShortProviderPagesToFifty() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: (21...50).reversed().map { graphMessage($0) },
      nextLink: URL(string: "https://graph.microsoft.test/inbox/page-2"),
      deltaLink: nil
    )
    client.pages[
      pageKey(
        folderId: "inbox-id",
        continuation: "https://graph.microsoft.test/inbox/page-2"
      )
    ] = MicrosoftGraphMetadataPage(
      messages: (1...20).reversed().map { graphMessage($0) },
      nextLink: URL(string: "https://graph.microsoft.test/inbox/page-3"),
      deltaLink: nil
    )
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    let initial = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertEqual(initial.messages.count, 50)
    XCTAssertEqual(initial.messages.first?.subject, "Message 50")
    XCTAssertFalse(initial.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(
      client.requestedContinuations,
      [nil, "https://graph.microsoft.test/inbox/page-2"]
    )
  }

  func testInitialAvailabilityIncludesNewestMessagesAcrossFolders() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [
      graphFolder(id: "inbox-id", wellKnownName: "inbox"),
      graphFolder(id: "sent-id", displayName: "Sent Items", wellKnownName: "sentitems"),
    ]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1, folderId: "inbox-id")],
      nextLink: URL(string: "https://graph.microsoft.test/inbox/page-2"),
      deltaLink: nil
    )
    client.pages[pageKey(folderId: "sent-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(100, folderId: "sent-id")],
      nextLink: URL(string: "https://graph.microsoft.test/sent/page-2"),
      deltaLink: nil
    )
    client.pages["sent-id|recent"] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(100, folderId: "sent-id")],
      nextLink: nil,
      deltaLink: nil
    )
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)
    let initial = try await adapter.loadMailbox(
      .allObserved,
      connection: connection,
      session: session
    )

    XCTAssertEqual(initial.messages.map(\.subject), ["Message 100", "Message 1"])
    XCTAssertEqual(
      client.requestedContinuations,
      [
        nil,
        "https://graph.microsoft.test/inbox/page-2",
        nil,
        "https://graph.microsoft.test/sent/page-2",
      ]
    )
    XCTAssertEqual(client.requestedRecentFolderIds, ["sent-id"])
  }

  func testExpiredDeltaCursorRestartsWithoutRetainingDuplicateOrStaleMessages() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta-1")
    )
    let store = try SwiftDataMicrosoftGraphMetadataStore.inMemory()
    let adapter = try authorizedAdapter(client: client, store: store)
    let loadedConnections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(loadedConnections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    client.expiredContinuations = ["https://graph.microsoft.test/inbox/delta-1"]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(2)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta-2")
    )

    let refreshed = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertTrue(refreshed.providerCursorIsExpired)
    XCTAssertEqual(refreshed.messages.map(\.providerMessageId), ["immutable-message-2"])
  }

  // swiftlint:disable:next function_body_length
  func testNativeFolderRolesAndConversationIdsMapWithoutLocalizedNameGuessing() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [
      graphFolder(id: "localized-inbox", displayName: "Posteingang", wellKnownName: "inbox"),
      graphFolder(id: "custom", displayName: "Inbox", wellKnownName: nil),
    ]
    client.pages[pageKey(folderId: "localized-inbox")] = MicrosoftGraphMetadataPage(
      messages: [
        graphMessage(
          1,
          conversationId: "conversation-1",
          folderId: "localized-inbox",
          isRead: false
        ),
        graphMessage(
          2,
          conversationId: "conversation-1",
          folderId: "localized-inbox",
          isRead: true
        ),
      ],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/localized-inbox/delta")
    )
    client.pages[pageKey(folderId: "custom")] = MicrosoftGraphMetadataPage(
      messages: [
        graphMessage(3, conversationId: "conversation-2", folderId: "custom", isRead: true)
      ],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/custom/delta")
    )
    let adapter = try authorizedAdapter(client: client)
    let loadedConnections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(loadedConnections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)
    _ = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )
    let observed = try await adapter.loadMailbox(
      .allObserved,
      connection: connection,
      session: session
    )

    XCTAssertEqual(observed.threads.count, 2)
    XCTAssertEqual(
      observed.threads.first { $0.providerThreadId == "conversation-1" }?.messages.count, 2)
    XCTAssertEqual(
      Set(
        observed.messages.first { $0.providerMessageId == "immutable-message-1" }?
          .providerStateIds ?? []
      ),
      ["INBOX", "UNREAD"]
    )
    XCTAssertEqual(
      observed.messages.first { $0.providerMessageId == "immutable-message-3" }?
        .providerStateIds,
      [MicrosoftGraphProviderMessage.customFolderStateId("custom")]
    )
  }

  func testOpeningMessageUsesTheSharedEncryptedBodyCacheAfterFirstRead() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    client.bodies["immutable-message-1"] = "Private body"
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let bodyCache = RecordingMicrosoftGraphBodyCache()
    let adapter = try authorizedAdapter(
      bodyCache: bodyCache,
      client: client,
      keyMaterialStore: keyStore
    )
    let loadedConnections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(loadedConnections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try XCTUnwrap(inbox.messages.first)

    let first = try await adapter.loadMessageBody(message: message, session: session)
    let second = try await adapter.loadMessageBody(message: message, session: session)

    XCTAssertEqual(first.text, "Private body")
    XCTAssertEqual(second, first)
    XCTAssertEqual(client.bodyRequestCount, 1)
    XCTAssertEqual(bodyCache.savedMessageIds, [message.stableProviderMessageId])
  }

  // swiftlint:disable:next function_body_length
  func testCachedBodyReadRejectsRemovedConnectionAndClearsLocalCache() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    client.bodies["immutable-message-1"] = "Private body"
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let bodyCache = RecordingMicrosoftGraphBodyCache()
    let definitions = RecordingMicrosoftGraphDefinitionSyncService(
      definitions: [graphConnectionDefinition]
    )
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "access-token",
        expiresAtMilliseconds: 4_000_000_000_000,
        refreshToken: "refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    let adapter = try makeAdapter(
      bodyCache: bodyCache,
      client: client,
      definitions: definitions,
      keyMaterialStore: keyStore,
      tokenStore: tokenStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try XCTUnwrap(inbox.messages.first)
    _ = try await adapter.loadMessageBody(message: message, session: session)
    definitions.definitions = []
    definitions.removedConnectionIds = [connection.id]

    do {
      _ = try await adapter.loadMessageBody(message: message, session: session)
      XCTFail("Expected a removal tombstone to reject the cached body")
    } catch {
      XCTAssertEqual(error as? MailboxConnectionAdapterError, .connectionRemoved)
    }

    XCTAssertNil(bodyCache.payloads[message.stableProviderMessageId])
    XCTAssertNil(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: graphAccount.id
      )
    )
  }

  func testCategoryOverrideSurvivesMetadataRecoveryThroughProductSync() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    let assignmentSync = RecordingGraphCategoryAssignmentSync()
    let store = try SwiftDataMicrosoftGraphMetadataStore.inMemory()
    let adapter = try authorizedAdapter(
      assignmentSync: assignmentSync,
      client: client,
      store: store
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try XCTUnwrap(inbox.messages.first)

    let overridden = try await adapter.overrideCategory(
      "system:invoices",
      for: message,
      session: session
    )
    try store.clear(productAccountId: session.productAccountId, connectionId: connection.id)
    let recovered = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertEqual(overridden.categoryId, "system:invoices")
    XCTAssertEqual(assignmentSync.savedUserOverrides.count, 1)
    XCTAssertEqual(recovered.messages.first?.categoryId, "system:invoices")
  }

  func testHistoricalBackfillPausesBeforeRequestingPagesInLowPowerMode() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: (1...50).reversed().map { graphMessage($0) },
      nextLink: URL(string: "https://graph.microsoft.test/inbox/page-2"),
      deltaLink: nil
    )
    let adapter = try authorizedAdapter(
      client: client,
      shouldContinueHistoricalBackfill: { false }
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    let requestCount = client.requestedContinuations.count

    let paused = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    XCTAssertFalse(paused.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(client.requestedContinuations.count, requestCount)
  }

  func testSentMessagesUseTheirSentTimestampForMetadata() {
    let sentDate = "2026-06-01T12:00:00Z"
    let message = MicrosoftGraphProviderMessage(
      ccRecipients: [],
      conversationId: "conversation-1",
      from: "sender@example.com",
      id: "message-1",
      internetMessageId: nil,
      isRead: true,
      parentFolderId: "sent-id",
      receivedDateTime: nil,
      sentDateTime: sentDate,
      replyTo: [],
      subject: "Sent message",
      bodyPreview: "Preview",
      toRecipients: ["recipient@example.com"]
    )

    let metadata = message.mailboxMetadata(
      connectionId: graphConnectionId,
      connectedAt: 0,
      foldersById: ["sent-id": graphFolder(id: "sent-id", wellKnownName: "sentitems")]
    )

    XCTAssertEqual(
      metadata?.providerInternalDateMilliseconds,
      Int64(ISO8601DateFormatter().date(from: sentDate)!.timeIntervalSince1970 * 1_000)
    )
  }

  func testMetadataAndCheckpointReopenFromThePersistentLocalStore() async throws {
    let firstStore = SwiftDataMicrosoftGraphMetadataStore()
    try firstStore.clear(productAccountId: session.productAccountId)
    defer {
      let cleanupStore = SwiftDataMicrosoftGraphMetadataStore()
      try? cleanupStore.clear(productAccountId: session.productAccountId)
    }
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    let firstAdapter = try authorizedAdapter(client: client, store: firstStore)
    let firstConnections = try await firstAdapter.loadConnections(session: session)
    let connection = try XCTUnwrap(firstConnections.first)
    _ = try await firstAdapter.syncInbox(connection: connection, session: session)

    let reopenedStore = SwiftDataMicrosoftGraphMetadataStore()
    let reopenedAdapter = try authorizedAdapter(client: client, store: reopenedStore)
    let reopened = try await reopenedAdapter.loadInbox(
      connection: connection,
      session: session
    )

    XCTAssertEqual(reopened.messages.map(\.providerMessageId), ["immutable-message-1"])
    XCTAssertTrue(reopened.hasInitialMailboxAvailability)
    XCTAssertTrue(reopened.historicalMetadataBackfillIsComplete)
  }

  func testExpiredAccessTokenRefreshesBeforeProviderAccess() async throws {
    let authorizer = RecordingMicrosoftGraphAuthorizer()
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "expired-token",
        expiresAtMilliseconds: 1,
        refreshToken: "refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    let adapter = try makeAdapter(
      authorizer: authorizer,
      client: client,
      definitions: RecordingMicrosoftGraphDefinitionSyncService(
        definitions: [graphConnectionDefinition]
      ),
      now: { Date(timeIntervalSince1970: 2_000_000_000) },
      tokenStore: tokenStore
    )
    let loadedConnections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(loadedConnections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertEqual(authorizer.refreshedTokens, 1)
    XCTAssertEqual(client.accessTokens.last, authorizer.refreshResult.accessToken)
  }

  func testRejectedUnexpiredAccessTokenRefreshesAndRetriesProviderAccess() async throws {
    let authorizer = RecordingMicrosoftGraphAuthorizer()
    let client = RecordingMicrosoftGraphClient()
    client.rejectedAccessTokens = ["access-token"]
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "access-token",
        expiresAtMilliseconds: 4_000_000_000_000,
        refreshToken: "refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    let adapter = try makeAdapter(
      authorizer: authorizer,
      client: client,
      definitions: RecordingMicrosoftGraphDefinitionSyncService(
        definitions: [graphConnectionDefinition]
      ),
      tokenStore: tokenStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertEqual(authorizer.refreshedTokens, 1)
    XCTAssertEqual(client.accessTokens.last, authorizer.refreshResult.accessToken)
  }

  func testRejectedRefreshRequiresReauthorization() async throws {
    let authorizer = RecordingMicrosoftGraphAuthorizer()
    authorizer.refreshError = MicrosoftGraphOAuthError.authorizationRejected
    let client = RecordingMicrosoftGraphClient()
    client.rejectedAccessTokens = ["access-token"]
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "access-token",
        expiresAtMilliseconds: 4_000_000_000_000,
        refreshToken: "refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    let adapter = try makeAdapter(
      authorizer: authorizer,
      client: client,
      definitions: RecordingMicrosoftGraphDefinitionSyncService(
        definitions: [graphConnectionDefinition]
      ),
      tokenStore: tokenStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    do {
      _ = try await adapter.syncInbox(connection: connection, session: session)
      XCTFail("Expected authorization to be required")
    } catch {
      XCTAssertEqual(error as? MailboxConnectionAdapterError, .authorizationRequired)
    }
    XCTAssertNil(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: graphAccount.id
      )
    )
  }

  func testPrefetchPreservesNewestFirstOrder() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1), graphMessage(3), graphMessage(2)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    client.bodies = [
      "immutable-message-1": "Body 1",
      "immutable-message-2": "Body 2",
      "immutable-message-3": "Body 3",
    ]
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let bodyCache = RecordingMicrosoftGraphBodyCache()
    let adapter = try authorizedAdapter(
      bodyCache: bodyCache,
      client: client,
      keyMaterialStore: keyStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)

    try await adapter.prefetchMessageBodies(
      connection: connection,
      pinnedMessageIds: [],
      referenceDate: Date(timeIntervalSince1970: 1_781_200_100),
      session: session
    )

    XCTAssertEqual(
      bodyCache.savedMessageIds,
      inbox.messages.map(\.stableProviderMessageId)
    )
  }

  func testMultipleMicrosoftConnectionsRemainMailboxScopedAndProviderDistinct() async throws {
    let secondAccount = MicrosoftGraphAccount(
      displayName: "Second Graph Reader",
      emailAddress: "second@example.com",
      id: "graph-user-002"
    )
    let secondDefinition = makeGraphConnectionDefinition(account: secondAccount)
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    for account in [graphAccount, secondAccount] {
      try tokenStore.save(
        MicrosoftGraphTokens(
          accessToken: "access-\(account.id)",
          expiresAtMilliseconds: 4_000_000_000_000,
          refreshToken: "refresh-\(account.id)"
        ),
        productAccountId: session.productAccountId,
        providerAccountIdentifier: account.id
      )
    }
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1, conversationId: "shared-conversation")],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    let adapter = try makeAdapter(
      client: client,
      definitions: RecordingMicrosoftGraphDefinitionSyncService(
        definitions: [graphConnectionDefinition, secondDefinition]
      ),
      tokenStore: tokenStore
    )

    let connections = try await adapter.loadConnections(session: session)
    var messages: [MailboxMessageMetadata] = []
    for connection in connections {
      messages += try await adapter.syncInbox(connection: connection, session: session).messages
    }

    XCTAssertEqual(connections.count, 2)
    XCTAssertEqual(Set(connections.map(\.id.providerId)), [.microsoftGraph])
    XCTAssertEqual(MailboxThread.group(messages).count, 2)
    XCTAssertNotEqual(
      connections[0].id,
      MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .gmail,
          value: connections[0].providerMailboxIdentity.value
        )
      )
    )
  }

  func testCancellationDoesNotCommitAPartialPage() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.error = CancellationError()
    let store = try SwiftDataMicrosoftGraphMetadataStore.inMemory()
    let adapter = try authorizedAdapter(client: client, store: store)
    let loadedConnections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(loadedConnections.first)

    do {
      _ = try await adapter.syncInbox(connection: connection, session: session)
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    }

    XCTAssertNil(
      try store.loadState(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    )
    XCTAssertEqual(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ),
      []
    )
  }

  func testStaleSyncCallbackDoesNotCommitReturnedProviderData() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    var shouldPersist = true
    client.metadataPageDidLoad = { shouldPersist = false }
    let store = try SwiftDataMicrosoftGraphMetadataStore.inMemory()
    let adapter = try authorizedAdapter(client: client, store: store)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    do {
      _ = try await adapter.syncRecentInbox(
        connection: connection,
        includingHistoryCandidates: false,
        session: session,
        sinceHistoryId: nil,
        throughHistoryId: nil,
        shouldPersist: { shouldPersist }
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    }

    XCTAssertNil(
      try store.loadState(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    )
  }

  private func authorizedAdapter(
    assignmentSync: MessageCategoryAssignmentSyncing = RecordingGraphCategoryAssignmentSync(),
    bodyCache: GmailMessageBodyCaching = RecordingMicrosoftGraphBodyCache(),
    client: RecordingMicrosoftGraphClient,
    keyMaterialStore: ProductSyncKeyMaterialPersisting = InMemoryProductSyncKeyMaterialStore(),
    shouldContinueHistoricalBackfill: @escaping () -> Bool = { true },
    store: MicrosoftGraphMetadataPersisting? = nil
  ) throws -> MicrosoftGraphMailboxConnectionAdapter {
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "access-token",
        expiresAtMilliseconds: 4_000_000_000_000,
        refreshToken: "refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    return try makeAdapter(
      assignmentSync: assignmentSync,
      bodyCache: bodyCache,
      client: client,
      definitions: RecordingMicrosoftGraphDefinitionSyncService(
        definitions: [graphConnectionDefinition]
      ),
      keyMaterialStore: keyMaterialStore,
      metadataStore: store,
      shouldContinueHistoricalBackfill: shouldContinueHistoricalBackfill,
      tokenStore: tokenStore
    )
  }

  private func makeAdapter(
    assignmentSync: MessageCategoryAssignmentSyncing = RecordingGraphCategoryAssignmentSync(),
    authorizer: RecordingMicrosoftGraphAuthorizer? = nil,
    bodyCache: GmailMessageBodyCaching = RecordingMicrosoftGraphBodyCache(),
    client: RecordingMicrosoftGraphClient,
    definitions: RecordingMicrosoftGraphDefinitionSyncService,
    keyMaterialStore: ProductSyncKeyMaterialPersisting = InMemoryProductSyncKeyMaterialStore(),
    metadataStore: MicrosoftGraphMetadataPersisting? = nil,
    now: @escaping () -> Date = Date.init,
    shouldContinueHistoricalBackfill: @escaping () -> Bool = { true },
    tokenStore: MicrosoftGraphAuthorizationPersisting
  ) throws -> MicrosoftGraphMailboxConnectionAdapter {
    let resolvedMetadataStore: MicrosoftGraphMetadataPersisting
    if let metadataStore {
      resolvedMetadataStore = metadataStore
    } else {
      resolvedMetadataStore = try SwiftDataMicrosoftGraphMetadataStore.inMemory()
    }
    return MicrosoftGraphMailboxConnectionAdapter(
      assignmentSync: assignmentSync,
      authorizer: authorizer ?? RecordingMicrosoftGraphAuthorizer(),
      bodyCache: bodyCache,
      client: client,
      definitionSyncService: definitions,
      keyMaterialStore: keyMaterialStore,
      metadataStore: resolvedMetadataStore,
      now: now,
      shouldContinueHistoricalBackfill: shouldContinueHistoricalBackfill,
      tokenStore: tokenStore
    )
  }
}

private let graphAccount = MicrosoftGraphAccount(
  displayName: "Graph Reader",
  emailAddress: "reader@example.com",
  id: "graph-user-001"
)

private let graphConnectionId = MailboxConnectionId(
  providerMailboxIdentity: StableProviderMailboxIdentity(
    providerId: .microsoftGraph,
    value: graphAccount.id
  )
)

private let graphConnectionDefinition = makeGraphConnectionDefinition(account: graphAccount)

private func makeGraphConnectionDefinition(
  account: MicrosoftGraphAccount
) -> MailboxConnectionDefinition {
  MailboxConnection(
    authorizationState: .authorized,
    capabilities: .microsoftGraphRead,
    connectedAt: 1_781_200_000_000,
    displayName: account.emailAddress,
    id: MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .microsoftGraph,
        value: account.id
      )
    ),
    lastVerifiedAt: 1_781_200_000_000,
    productAccountId: ProductAccountId("product-account-001"),
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_000
  ).definition
}

private func graphFolder(
  id: String,
  displayName: String = "Inbox",
  wellKnownName: String?
) -> MicrosoftGraphFolder {
  MicrosoftGraphFolder(
    displayName: displayName,
    id: id,
    parentFolderId: "root",
    wellKnownName: wellKnownName
  )
}

private func graphMessage(
  _ number: Int,
  conversationId: String? = nil,
  folderId: String = "inbox-id",
  isRead: Bool = false
) -> MicrosoftGraphProviderMessage {
  MicrosoftGraphProviderMessage(
    ccRecipients: [],
    conversationId: conversationId ?? "conversation-\(number)",
    from: "Sender \(number) <sender\(number)@example.com>",
    id: "immutable-message-\(number)",
    internetMessageId: "<message-\(number)@example.com>",
    isRead: isRead,
    parentFolderId: folderId,
    receivedDateTime: ISO8601DateFormatter().string(
      from: Date(timeIntervalSince1970: 1_781_200_000 + Double(number))
    ),
    replyTo: [],
    subject: "Message \(number)",
    bodyPreview: "Preview \(number)",
    toRecipients: ["reader@example.com"]
  )
}

private func pageKey(folderId: String, continuation: String? = nil) -> String {
  "\(folderId)|\(continuation ?? "initial")"
}

@MainActor
private final class RecordingMicrosoftGraphAuthorizer: MicrosoftGraphAuthorizing {
  let authorizedTokens = MicrosoftGraphTokens(
    accessToken: "authorized-access-token",
    expiresAtMilliseconds: 4_000_000_000_000,
    refreshToken: "authorized-refresh-token"
  )
  let refreshResult = MicrosoftGraphTokens(
    accessToken: "refreshed-access-token",
    expiresAtMilliseconds: 4_100_000_000_000,
    refreshToken: "refreshed-refresh-token"
  )
  var refreshError: Error?
  var refreshedTokens = 0

  func authorize() async throws -> MicrosoftGraphTokens {
    authorizedTokens
  }

  func refresh(_ tokens: MicrosoftGraphTokens) async throws -> MicrosoftGraphTokens {
    refreshedTokens += 1
    if let refreshError { throw refreshError }
    return refreshResult
  }
}

private final class RecordingMicrosoftGraphClient: MicrosoftGraphClient {
  var accessTokens: [String] = []
  var account = graphAccount
  var bodies: [String: String] = [:]
  var bodyRequestCount = 0
  var error: Error?
  var expiredContinuations: Set<String> = []
  var folders: [MicrosoftGraphFolder] = []
  var metadataPageDidLoad: (() -> Void)?
  var pages: [String: MicrosoftGraphMetadataPage] = [:]
  var rejectedAccessTokens: Set<String> = []
  var requestedContinuations: [String?] = []
  var requestedRecentFolderIds: [String] = []

  func verifyAccount(accessToken: String) async throws -> MicrosoftGraphAccount {
    accessTokens.append(accessToken)
    try validate(accessToken)
    return account
  }

  func loadFolders(accessToken: String) async throws -> [MicrosoftGraphFolder] {
    accessTokens.append(accessToken)
    try validate(accessToken)
    if let error { throw error }
    return folders
  }

  func loadRecentMetadataPage(
    folder: MicrosoftGraphFolder,
    pageSize _: Int,
    accessToken: String
  ) async throws -> MicrosoftGraphMetadataPage {
    accessTokens.append(accessToken)
    try validate(accessToken)
    requestedRecentFolderIds.append(folder.id)
    return pages["\(folder.id)|recent"]
      ?? MicrosoftGraphMetadataPage(messages: [], nextLink: nil, deltaLink: nil)
  }

  func loadMetadataPage(
    folder: MicrosoftGraphFolder,
    continuationURL: URL?,
    pageSize: Int,
    accessToken: String
  ) async throws -> MicrosoftGraphMetadataPage {
    accessTokens.append(accessToken)
    try validate(accessToken)
    requestedContinuations.append(continuationURL?.absoluteString)
    if let error { throw error }
    if let continuation = continuationURL?.absoluteString,
      expiredContinuations.contains(continuation)
    {
      throw MicrosoftGraphClientError.deltaTokenExpired
    }
    let key = pageKey(folderId: folder.id, continuation: continuationURL?.absoluteString)
    let page =
      pages[key]
      ?? MicrosoftGraphMetadataPage(
        messages: [],
        nextLink: nil,
        deltaLink: URL(string: "https://graph.microsoft.test/\(folder.id)/delta")
      )
    metadataPageDidLoad?()
    return page
  }

  func loadTextBody(messageId: String, accessToken: String) async throws -> String {
    accessTokens.append(accessToken)
    try validate(accessToken)
    bodyRequestCount += 1
    return bodies[messageId] ?? ""
  }

  private func validate(_ accessToken: String) throws {
    if rejectedAccessTokens.contains(accessToken) {
      throw MicrosoftGraphClientError.requestFailed(401)
    }
  }
}

private final class RecordingGraphCategoryAssignmentSync: MessageCategoryAssignmentSyncing {
  var assignmentsByMessageId: [String: MessageCategoryAssignment] = [:]
  private(set) var savedUserOverrides: [MessageCategoryAssignment] = []

  func loadAssignments(
    stableProviderMessageIds: [String],
    session _: ProductAccountSessionSnapshot
  ) async throws -> [String: MessageCategoryAssignment] {
    assignmentsByMessageId.filter { stableProviderMessageIds.contains($0.key) }
  }

  func loadAssignment(
    stableProviderMessageId: String,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment? {
    assignmentsByMessageId[stableProviderMessageId]
  }

  func loadFutureLearningSignals(
    senderAddresses _: [String],
    session _: ProductAccountSessionSnapshot
  ) async throws -> [FutureLearningSignal] {
    []
  }

  func saveAssignment(
    _ assignment: MessageCategoryAssignment,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment {
    assignmentsByMessageId[assignment.stableProviderMessageId] = assignment
    return assignment
  }

  func saveUserOverride(
    _ assignment: MessageCategoryAssignment,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment {
    assignmentsByMessageId[assignment.stableProviderMessageId] = assignment
    savedUserOverrides.append(assignment)
    return assignment
  }
}

private final class RecordingMicrosoftGraphDefinitionSyncService:
  MailboxConnectionDefinitionSyncing
{
  var defaultSendingConnectionId: MailboxConnectionId?
  var definitions: [MailboxConnectionDefinition]
  var removedConnectionIds: [MailboxConnectionId] = []
  var savedDefinition: MailboxConnectionDefinition?

  init(definitions: [MailboxConnectionDefinition] = []) {
    self.definitions = definitions
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
    for connection in connections where !definitions.contains(where: { $0.id == connection.id }) {
      definitions.append(connection)
    }
    return snapshot
  }

  func removeConnection(
    _ connectionId: MailboxConnectionId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    definitions.removeAll { $0.id == connectionId }
    removedConnectionIds.append(connectionId)
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
    savedDefinition = definition
    definitions.removeAll { $0.id == definition.id }
    definitions.append(definition)
    return snapshot
  }

  func setDefaultSendingConnection(
    _ connectionId: MailboxConnectionId?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    defaultSendingConnectionId = connectionId
    return snapshot
  }

  private var snapshot: MailboxConnectionSyncSnapshot {
    MailboxConnectionSyncSnapshot(
      connections: definitions,
      defaultSendingConnectionId: defaultSendingConnectionId,
      removedConnectionIds: removedConnectionIds,
      updatedAt: 1_781_200_000_000
    )
  }
}

private final class RecordingMicrosoftGraphBodyCache: GmailMessageBodyCaching {
  var payloads: [String: ProductSyncEncryptedPayload] = [:]
  var savedMessageIds: [String] = []

  func clearMessageBodies(productAccountId _: String) throws {
    payloads = [:]
  }

  func clearMessageBodies(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    payloads = [:]
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
    savedMessageIds.append(stableProviderMessageId)
  }
}
