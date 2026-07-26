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
      callbackScheme: "msauth.dev.unwired.mail",
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
    XCTAssertEqual(request.redirectURI.absoluteString, "msauth.dev.unwired.mail://auth")
    XCTAssertEqual(
      try request.authorizationCode(
        from: URL(string: "msauth.dev.unwired.mail://auth?code=code-1&state=\(state)")!
      ),
      "code-1"
    )
    XCTAssertThrowsError(
      try request.authorizationCode(
        from: URL(
          string: "msauth.dev.unwired.mail://auth?code=code-1&state=incorrect"
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

  func testFullCapabilitiesRequestWriteAndSendScopes() throws {
    let request = MicrosoftGraphOAuthRequest(
      callbackScheme: "msauth.dev.unwired.mail",
      clientIdentifier: "client-id"
    )
    let queryItems = try XCTUnwrap(
      URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems
    )
    let scope = try XCTUnwrap(queryItems.first(where: { $0.name == "scope" })?.value)

    XCTAssertTrue(MailboxConnectionCapabilities.microsoftGraph.canSend)
    XCTAssertTrue(MailboxConnectionCapabilities.microsoftGraph.canReply)
    XCTAssertTrue(MailboxConnectionCapabilities.microsoftGraph.canForward)
    XCTAssertTrue(MailboxConnectionCapabilities.microsoftGraph.canRegisterPush)
    XCTAssertTrue(MailboxConnectionCapabilities.microsoftGraph.supports(.archive))
    XCTAssertTrue(MailboxConnectionCapabilities.microsoftGraph.supports(.spam))
    XCTAssertFalse(MailboxConnectionCapabilities.microsoftGraph.supports(.star))
    XCTAssertTrue(scope.contains("Mail.ReadWrite"))
    XCTAssertTrue(scope.contains("Mail.Send"))
  }

  func testLegacyReadOnlyTokensRequireReauthorizationForFullCapabilities() throws {
    let legacyJSON = """
      {
        "accessToken": "legacy-access",
        "expiresAtMilliseconds": 4000000000000,
        "refreshToken": "legacy-refresh"
      }
      """
    let tokens = try JSONDecoder().decode(
      MicrosoftGraphTokens.self,
      from: Data(legacyJSON.utf8)
    )

    XCTAssertFalse(tokens.hasFullMailAccess)
  }

  // swiftlint:disable:next function_body_length
  func testGraphReplyUsesProviderReplyDraftBeforeSending() async throws {
    var requests: [URLRequest] = []
    var requestBodies: [Data?] = []
    let session = ConvexClientTesting.makeSession { request in
      requests.append(request)
      requestBodies.append(try graphRequestBody(request))
      let data: Data
      switch requests.count {
      case 1:
        data = Data(#"{"value":[]}"#.utf8)
      case 2:
        data = Data(#"{"id":"reply-draft"}"#.utf8)
      default:
        data = Data()
      }
      return (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: requests.count == 1 ? 200 : (requests.count == 2 ? 201 : 202),
          httpVersion: nil,
          headerFields: nil
        )!,
        data
      )
    }
    let client = URLSessionMicrosoftGraphClient(session: session)

    try await client.send(
      OutgoingMessage(
        body: "Reply body",
        recipient: #""Doe, Jane" <jane@example.com>, Second <second@example.com>"#,
        subject: "Re: Subject",
        inReplyTo: "<source@example.com>",
        kind: .reply,
        providerThreadId: "conversation-1",
        sourceProviderMessageId: "source-message",
        idempotencyKey: "reply-attempt"
      ),
      accessToken: "provider-access"
    )

    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "PATCH", "POST"])
    XCTAssertEqual(
      requests.compactMap(\.url?.path),
      [
        "/v1.0/me/mailFolders/drafts/messages",
        "/v1.0/me/messages/source-message/createReply",
        "/v1.0/me/messages/reply-draft",
        "/v1.0/me/messages/reply-draft/send",
      ]
    )
    let updateBody = try XCTUnwrap(requestBodies[2])
    let updateJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: updateBody) as? [String: Any]
    )
    let recipients = try XCTUnwrap(updateJSON["toRecipients"] as? [[String: Any]])
    XCTAssertEqual(recipients.count, 2)
    XCTAssertEqual(
      recipients.compactMap { ($0["emailAddress"] as? [String: Any])?["address"] as? String },
      ["jane@example.com", "second@example.com"]
    )
    XCTAssertNil(updateJSON["internetMessageHeaders"])
  }

  func testGraphSendReusesAnExistingProviderDraft() async throws {
    var requests: [URLRequest] = []
    let session = ConvexClientTesting.makeSession { request in
      requests.append(request)
      return (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: requests.count == 1 ? 200 : 202,
          httpVersion: nil,
          headerFields: nil
        )!,
        requests.count == 1
          ? Data(#"{"value":[{"id":"existing-draft"}]}"#.utf8)
          : Data()
      )
    }
    let client = URLSessionMicrosoftGraphClient(session: session)

    try await client.send(
      OutgoingMessage(
        body: "Body",
        recipient: "recipient@example.com",
        subject: "Subject",
        idempotencyKey: "retry-attempt"
      ),
      accessToken: "provider-access"
    )

    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(
      requests.compactMap(\.url?.path),
      [
        "/v1.0/me/mailFolders/drafts/messages",
        "/v1.0/me/messages/existing-draft/send",
      ]
    )
  }

  func testGraphPushSubscriptionAcceptsFractionalExpiration() async throws {
    let session = ConvexClientTesting.makeSession { request in
      (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 201,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(
          #"{"id":"subscription-1","expirationDateTime":"2030-01-02T03:04:05.1234567Z"}"#
            .utf8
        )
      )
    }
    let client = URLSessionMicrosoftGraphSubscriptionClient(session: session)

    let response = try await client.create(
      accessToken: "provider-access",
      clientState: "client-state",
      expirationDate: Date(),
      notificationURL: URL(string: "https://deployment.convex.site/microsoft-graph/push")!
    )

    XCTAssertEqual(response.subscriptionId, "subscription-1")
  }

  func testProviderActionsUseDurableQueueAndGraphFolderMappings() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [
      graphFolder(id: "inbox-id", wellKnownName: "inbox"),
      graphFolder(id: "archive-id", displayName: "Archive", wellKnownName: "archive"),
      graphFolder(id: "deleted-id", displayName: "Deleted", wellKnownName: "deleteditems"),
      graphFolder(id: "junk-id", displayName: "Junk", wellKnownName: "junkemail"),
    ]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    let pendingStore = InMemoryGraphPendingActionStore()
    let pendingActions = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 0 },
      store: pendingStore
    )
    let adapter = try authorizedAdapter(
      client: client,
      pendingActionService: pendingActions
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try XCTUnwrap(inbox.messages.first)

    try await adapter.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    )
    let projected = try await adapter.loadInbox(connection: connection, session: session)
    XCTAssertTrue(projected.messages.isEmpty)
    XCTAssertEqual(try pendingStore.load(productAccountId: session.productAccountId).count, 1)

    let resumeError = await adapter.resumePendingActions(connection: connection, session: session)
    XCTAssertNil(resumeError)
    XCTAssertEqual(
      client.moves,
      [.init(destinationFolderId: "archive-id", messageId: message.providerMessageId)]
    )
  }

  func testTransientGraphActionFailureRetriesThroughTheSharedQueue() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [
      graphFolder(id: "inbox-id", wellKnownName: "inbox"),
      graphFolder(id: "archive-id", displayName: "Archive", wellKnownName: "archive"),
    ]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    client.moveErrors = [MicrosoftGraphClientError.requestFailed(503)]
    let pendingActions = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 0 },
      store: InMemoryGraphPendingActionStore()
    )
    let adapter = try authorizedAdapter(
      client: client,
      pendingActionService: pendingActions
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try XCTUnwrap(inbox.messages.first)

    try await adapter.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connection: connection, session: session)
    let retryError = await adapter.waitForPendingActionRetries(
      connections: [connection],
      session: session
    )

    XCTAssertNil(retryError)
    XCTAssertEqual(client.moveAttempts, 2)
    XCTAssertEqual(client.moves.count, 1)
  }

  func testSendingAndDeliveryReconciliationUseStableOutboxMessageId() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let message = OutgoingMessage(
      body: "Graph body",
      recipient: "recipient@example.com",
      subject: "Graph subject",
      idempotencyKey: "graph-attempt-1"
    )
    client.deliveryStatuses[try XCTUnwrap(message.rfcMessageId)] = .sent

    try await adapter.send(message, connection: connection, session: session)
    let status = try await adapter.deliveryStatus(
      idempotencyKey: "graph-attempt-1",
      connection: connection,
      session: session
    )

    XCTAssertEqual(client.sentMessages, [message])
    XCTAssertEqual(status, .sent)
  }

  func testPushRegistrationAndDefaultSenderRemainConnectionScoped() async throws {
    let client = RecordingMicrosoftGraphClient()
    let definitions = RecordingMicrosoftGraphDefinitionSyncService(
      definitions: [graphConnectionDefinition]
    )
    let push = RecordingMicrosoftGraphPushRegistrar()
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
      client: client,
      definitions: definitions,
      pushRegistrar: push,
      tokenStore: tokenStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    try await adapter.registerOrRenewPush(connection: connection, session: session)
    try await adapter.setDefaultSendingConnection(connection, session: session)

    XCTAssertEqual(push.registeredConnectionIds, [connection.id])
    XCTAssertEqual(push.accessTokens, ["access-token"])
    XCTAssertEqual(definitions.defaultSendingConnectionId, connection.id)
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
      ]
    )
    XCTAssertEqual(client.requestedRecentFolderIds, ["sent-id"])
  }

  func testInitialAvailabilityStopsAfterFiftyMessagesBeforeLoadingOtherFolders() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [
      graphFolder(id: "inbox-id", wellKnownName: "inbox"),
      graphFolder(id: "sent-id", displayName: "Sent Items", wellKnownName: "sentitems"),
    ]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: (1...50).reversed().map { graphMessage($0, folderId: "inbox-id") },
      nextLink: URL(string: "https://graph.microsoft.test/inbox/page-2"),
      deltaLink: nil
    )
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    let initial = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertTrue(initial.hasInitialMailboxAvailability)
    XCTAssertFalse(initial.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(initial.messages.count, 50)
    XCTAssertEqual(client.requestedContinuations, [nil])
    XCTAssertTrue(client.requestedRecentFolderIds.isEmpty)
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

  // swiftlint:disable:next function_body_length
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
    let pendingActions = PendingProviderActionService(
      store: InMemoryGraphPendingActionStore()
    )
    let adapter = try makeAdapter(
      client: client,
      definitions: RecordingMicrosoftGraphDefinitionSyncService(
        definitions: [graphConnectionDefinition, secondDefinition]
      ),
      pendingActionService: pendingActions,
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

    for connection in connections {
      let connectionMessages = messages.filter { $0.connectionId == connection.id }
      try await adapter.perform(
        .markRead,
        messages: connectionMessages,
        connection: connection,
        session: session
      )
    }
    client.accessTokens = []

    for connection in connections {
      let actionError = await adapter.resumePendingActions(
        connection: connection,
        session: session
      )
      XCTAssertNil(actionError)
    }
    XCTAssertEqual(client.readUpdates.count, 2)
    XCTAssertEqual(
      Set(client.accessTokens),
      ["access-\(graphAccount.id)", "access-\(secondAccount.id)"]
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

  func testPushRegistrationRoutesOnlyOpaqueMetadataAndCoalescesRenewal() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let defaultsName = "MicrosoftGraphPushRegistrationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let routeTransport = RecordingMicrosoftGraphPushRouteTransport()
    let subscriptionClient = RecordingMicrosoftGraphSubscriptionClient()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let service = MicrosoftGraphPushSubscriptionService(
      now: { now },
      siteURL: URL(string: "https://deployment.convex.site"),
      statusStore: UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults),
      subscriptionClient: subscriptionClient,
      transport: routeTransport
    )

    try await service.registerOrRenew(
      connection: connection,
      accessToken: "provider-access-token",
      session: session
    )
    try await service.registerOrRenew(
      connection: connection,
      accessToken: "provider-access-token",
      session: session
    )

    XCTAssertEqual(routeTransport.prepared.count, 1)
    XCTAssertEqual(routeTransport.prepared.first?.identityToken, session.identityToken)
    XCTAssertFalse(routeTransport.prepared.first?.clientStateDigest.isEmpty ?? true)
    XCTAssertFalse(
      routeTransport.prepared.first?.opaqueConnectionId.contains(graphAccount.id) ?? true
    )
    XCTAssertEqual(subscriptionClient.created.count, 1)
    XCTAssertEqual(subscriptionClient.created.first?.accessToken, "provider-access-token")
    XCTAssertEqual(
      subscriptionClient.created.first?.notificationURL.absoluteString,
      "https://deployment.convex.site/microsoft-graph/push?routeId=graph-route-1"
    )
    XCTAssertEqual(routeTransport.confirmed.count, 1)
  }

  func testPushRegistrationRecreatesAnExpiredProviderSubscription() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let defaultsName = "MicrosoftGraphPushRecreationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let statusStore = UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults)
    try statusStore.save(
      MicrosoftGraphPushStatus(
        expiresAtMilliseconds: 1,
        opaqueConnectionId: "old-opaque-id",
        providerAccountIdentifier: connection.providerMailboxIdentity.value,
        routeId: "old-route",
        subscriptionId: "expired-subscription"
      ),
      productAccountId: session.productAccountId
    )
    let routeTransport = RecordingMicrosoftGraphPushRouteTransport()
    let subscriptionClient = RecordingMicrosoftGraphSubscriptionClient()
    subscriptionClient.renewError = MicrosoftGraphClientError.requestFailed(404)
    let service = MicrosoftGraphPushSubscriptionService(
      now: { Date(timeIntervalSince1970: 2_000_000_000) },
      siteURL: URL(string: "https://deployment.convex.site"),
      statusStore: statusStore,
      subscriptionClient: subscriptionClient,
      transport: routeTransport
    )

    try await service.registerOrRenew(
      connection: connection,
      accessToken: "provider-access-token",
      session: session
    )

    XCTAssertEqual(subscriptionClient.renewedSubscriptionIds, ["expired-subscription"])
    XCTAssertEqual(routeTransport.removedOpaqueConnectionIds, ["old-opaque-id"])
    XCTAssertEqual(subscriptionClient.created.count, 1)
    XCTAssertEqual(routeTransport.confirmed.last?.subscriptionId, "subscription-1")
  }

  private func authorizedAdapter(
    assignmentSync: MessageCategoryAssignmentSyncing = RecordingGraphCategoryAssignmentSync(),
    bodyCache: GmailMessageBodyCaching = RecordingMicrosoftGraphBodyCache(),
    client: RecordingMicrosoftGraphClient,
    keyMaterialStore: ProductSyncKeyMaterialPersisting = InMemoryProductSyncKeyMaterialStore(),
    pendingActionService: PendingProviderActionService = PendingProviderActionService(
      store: InMemoryGraphPendingActionStore()
    ),
    pushRegistrar: MicrosoftGraphPushRegistering = RecordingMicrosoftGraphPushRegistrar(),
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
      pendingActionService: pendingActionService,
      pushRegistrar: pushRegistrar,
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
    pendingActionService: PendingProviderActionService = PendingProviderActionService(
      store: InMemoryGraphPendingActionStore()
    ),
    pushRegistrar: MicrosoftGraphPushRegistering = RecordingMicrosoftGraphPushRegistrar(),
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
      pendingActionService: pendingActionService,
      pushRegistrar: pushRegistrar,
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
    capabilities: .microsoftGraph,
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

private func graphRequestBody(_ request: URLRequest) throws -> Data? {
  if let body = request.httpBody {
    return body
  }
  guard let stream = request.httpBodyStream else {
    return nil
  }
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    guard count >= 0 else {
      throw stream.streamError ?? URLError(.cannotDecodeContentData)
    }
    guard count > 0 else { break }
    data.append(buffer, count: count)
  }
  return data
}

private final class RecordingMicrosoftGraphClient: MicrosoftGraphClient {
  struct Move: Equatable {
    let destinationFolderId: String
    let messageId: String
  }

  var accessTokens: [String] = []
  var account = graphAccount
  var bodies: [String: String] = [:]
  var bodyRequestCount = 0
  var error: Error?
  var expiredContinuations: Set<String> = []
  var folders: [MicrosoftGraphFolder] = []
  var metadataPageDidLoad: (() -> Void)?
  var moveAttempts = 0
  var moveErrors: [Error] = []
  var pages: [String: MicrosoftGraphMetadataPage] = [:]
  var rejectedAccessTokens: Set<String> = []
  var requestedContinuations: [String?] = []
  var requestedRecentFolderIds: [String] = []
  var deliveryStatuses: [String: MailboxDeliveryStatus] = [:]
  var moves: [Move] = []
  var readUpdates: [(messageId: String, isRead: Bool)] = []
  var sentMessages: [OutgoingMessage] = []

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

  func moveMessage(
    messageId: String,
    destinationFolderId: String,
    accessToken: String
  ) async throws {
    accessTokens.append(accessToken)
    try validate(accessToken)
    moveAttempts += 1
    if !moveErrors.isEmpty {
      throw moveErrors.removeFirst()
    }
    moves.append(.init(destinationFolderId: destinationFolderId, messageId: messageId))
  }

  func setMessageRead(
    _ isRead: Bool,
    messageId: String,
    accessToken: String
  ) async throws {
    accessTokens.append(accessToken)
    try validate(accessToken)
    readUpdates.append((messageId, isRead))
  }

  func send(_ message: OutgoingMessage, accessToken: String) async throws {
    accessTokens.append(accessToken)
    try validate(accessToken)
    sentMessages.append(message)
  }

  func deliveryStatus(
    rfcMessageId: String,
    accessToken: String
  ) async throws -> MailboxDeliveryStatus {
    accessTokens.append(accessToken)
    try validate(accessToken)
    return deliveryStatuses[rfcMessageId] ?? .unknown
  }

  private func validate(_ accessToken: String) throws {
    if rejectedAccessTokens.contains(accessToken) {
      throw MicrosoftGraphClientError.requestFailed(401)
    }
  }
}

private final class InMemoryGraphPendingActionStore:
  PendingProviderActionPersisting, @unchecked Sendable
{
  private var actionsByProductAccount: [String: [PendingProviderAction]] = [:]

  func load(productAccountId: String) throws -> [PendingProviderAction] {
    actionsByProductAccount[productAccountId] ?? []
  }

  func save(
    _ actions: [PendingProviderAction],
    productAccountId: String
  ) throws {
    actionsByProductAccount[productAccountId] = actions
  }
}

private final class RecordingMicrosoftGraphPushRegistrar: MicrosoftGraphPushRegistering {
  var accessTokens: [String] = []
  var registeredConnectionIds: [MailboxConnectionId] = []

  func registerOrRenew(
    connection: MailboxConnection,
    accessToken: String,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    registeredConnectionIds.append(connection.id)
    accessTokens.append(accessToken)
  }

  func clear(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func clearAll(session _: ProductAccountSessionSnapshot) async throws {}
}

private final class RecordingMicrosoftGraphPushRouteTransport:
  MicrosoftGraphPushRouteTransport
{
  struct PreparedCall {
    let clientStateDigest: String
    let identityToken: String
    let opaqueConnectionId: String
    let trustedDeviceId: String
  }

  struct ConfirmedCall {
    let expiresAt: Int64
    let routeId: String
    let subscriptionId: String
    let trustedDeviceId: String
  }

  private(set) var confirmed: [ConfirmedCall] = []
  private(set) var prepared: [PreparedCall] = []
  private(set) var removedOpaqueConnectionIds: [String] = []

  func prepareMicrosoftGraphPushRoute(
    clientStateDigest: String,
    identityToken: String,
    opaqueConnectionId: String,
    trustedDeviceId: String
  ) async throws -> MicrosoftGraphPushRouteResponse {
    prepared.append(
      PreparedCall(
        clientStateDigest: clientStateDigest,
        identityToken: identityToken,
        opaqueConnectionId: opaqueConnectionId,
        trustedDeviceId: trustedDeviceId
      )
    )
    return MicrosoftGraphPushRouteResponse(routeId: "graph-route-1")
  }

  func confirmMicrosoftGraphPushRoute(
    expiresAt: Int64,
    identityToken _: String,
    routeId: String,
    subscriptionId: String,
    trustedDeviceId: String
  ) async throws -> MicrosoftGraphPushRouteResponse {
    confirmed.append(
      ConfirmedCall(
        expiresAt: expiresAt,
        routeId: routeId,
        subscriptionId: subscriptionId,
        trustedDeviceId: trustedDeviceId
      )
    )
    return MicrosoftGraphPushRouteResponse(routeId: routeId)
  }

  func removeMicrosoftGraphPushRoute(
    identityToken _: String,
    opaqueConnectionId: String,
    trustedDeviceId _: String
  ) async throws -> Bool {
    removedOpaqueConnectionIds.append(opaqueConnectionId)
    return true
  }
}

private final class RecordingMicrosoftGraphSubscriptionClient:
  MicrosoftGraphSubscriptionRequesting
{
  struct CreateCall {
    let accessToken: String
    let clientState: String
    let expirationDate: Date
    let notificationURL: URL
  }

  private(set) var created: [CreateCall] = []
  var renewError: Error?
  private(set) var renewedSubscriptionIds: [String] = []

  func create(
    accessToken: String,
    clientState: String,
    expirationDate: Date,
    notificationURL: URL
  ) async throws -> MicrosoftGraphPushStatusProviderResponse {
    created.append(
      CreateCall(
        accessToken: accessToken,
        clientState: clientState,
        expirationDate: expirationDate,
        notificationURL: notificationURL
      )
    )
    return MicrosoftGraphPushStatusProviderResponse(
      expirationDate: expirationDate,
      subscriptionId: "subscription-1"
    )
  }

  func renew(
    accessToken _: String,
    expirationDate: Date,
    subscriptionId: String
  ) async throws -> MicrosoftGraphPushStatusProviderResponse {
    renewedSubscriptionIds.append(subscriptionId)
    if let renewError {
      throw renewError
    }
    return MicrosoftGraphPushStatusProviderResponse(
      expirationDate: expirationDate,
      subscriptionId: subscriptionId
    )
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
