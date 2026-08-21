import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length type_name

private final class GraphAdapterURLStub: URLProtocolStub {}

private let fullGraphMailScopes = Set(["Mail.ReadWrite", "Mail.Send"])

@MainActor
@Suite(.serialized)
final class MicrosoftGraphMailboxConnectionAdapterTests {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "product-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  @Test
  func testOAuthRequestUsesPKCEAndValidatesTheCallbackState() throws {
    let request = MicrosoftGraphOAuthRequest(
      callbackScheme: "msauth.dev.unwired.mail",
      clientIdentifier: "client-id"
    )
    let queryItems = try requireValue(
      URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
    let values = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })
    let state = try requireValue(values["state"] ?? nil)

    #expect(values["client_id"] == "client-id")
    #expect(values["code_challenge_method"] == "S256")
    #expect(!(try requireValue(values["code_challenge"] ?? nil).isEmpty))
    #expect(try requireValue(values["scope"] ?? nil).contains("offline_access"))
    #expect(request.redirectURI.absoluteString == "msauth.dev.unwired.mail://auth")
    #expect(
      try request.authorizationCode(
        from: URL(string: "msauth.dev.unwired.mail://auth?code=code-1&state=\(state)")!
      ) == "code-1")
    #expect {
      try request.authorizationCode(
        from: URL(
          string: "msauth.dev.unwired.mail://auth?code=code-1&state=incorrect"
        )!
      )
    } throws: {
      #expect($0 as? MicrosoftGraphOAuthError == .invalidAuthorizationState)
      return true
    }
  }

  @Test
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

    #expect(connection?.id == graphConnectionId)
    #expect(reconnected?.id == graphConnectionId)
    #expect(definitions.recreatedDefinitionCount == 2)
    #expect(definitions.definitions.count == 1)
    #expect(connection?.authorizationState == .authorized)
    #expect(definitions.savedDefinition?.provider == MailProviderId.microsoftGraph.rawValue)
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: graphAccount.id
      ) == authorizer.authorizedTokens)
    let encodedDefinition = try JSONEncoder().encode(definitions.savedDefinition)
    let definitionJSON = try requireValue(String(data: encodedDefinition, encoding: .utf8))
    #expect(!(definitionJSON.contains(authorizer.authorizedTokens.accessToken)))
    #expect(!(definitionJSON.contains(authorizer.authorizedTokens.refreshToken)))
  }

  @Test
  func testGraphReauthorizationWinsAgainstStaleRemovalCleanup() async throws {
    let authorizer = RecordingMicrosoftGraphAuthorizer()
    let definitions = RecordingMicrosoftGraphDefinitionSyncService()
    let syncGate = MailboxConnectionSyncGate()
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    let blocker = TestRendezvous()
    let adapter = try makeAdapter(
      authorizer: authorizer,
      client: RecordingMicrosoftGraphClient(),
      definitions: definitions,
      syncGate: syncGate,
      tokenStore: tokenStore
    )
    let cleanup = Task {
      try await syncGate.withLock(graphConnectionId) {
        await blocker.hold()
        try tokenStore.clear(
          productAccountId: self.session.productAccountId,
          providerAccountIdentifier: graphAccount.id
        )
      }
    }
    await blocker.waitUntilHeld()

    let connection = Task {
      try await adapter.connect(
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
    }
    await Task.yield()
    #expect(definitions.savedDefinition == nil)
    await blocker.release()

    _ = try await connection.value
    try await cleanup.value
    let tokens = try tokenStore.load(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )

    #expect(tokens == authorizer.authorizedTokens)
  }

  @Test
  func testGraphReauthorizationPurgesStaleGenerationBeforeSavingFreshTokens() async throws {
    let authorizer = RecordingMicrosoftGraphAuthorizer()
    let bodyCache = RecordingMicrosoftGraphBodyCache()
    let definitions = RecordingMicrosoftGraphDefinitionSyncService(
      authorizationCleanupConnectionIds: [graphConnectionId],
      definitions: [graphConnectionDefinition.withAuthorizationGeneration(1)],
      localCleanupGenerations: [graphConnectionId: 1]
    )
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "stale-access",
        authorizationGeneration: 0,
        expiresAtMilliseconds: 4_000_000_000_000,
        grantedScopes: fullGraphMailScopes,
        refreshToken: "stale-refresh"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    let adapter = try makeAdapter(
      authorizer: authorizer,
      bodyCache: bodyCache,
      client: RecordingMicrosoftGraphClient(),
      definitions: definitions,
      syncGate: MailboxConnectionSyncGate(),
      tokenStore: tokenStore
    )

    let connection = try await adapter.connect(
      session: session,
      isSessionCurrent: { $0 == self.session }
    )

    #expect(bodyCache.connectionClearCount == 1)
    #expect(connection?.authorizationGeneration == 1)
    #expect(definitions.completedCleanupGenerations[graphConnectionId] == 1)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testGraphSendHoldsConnectionGateUntilProviderOperationFinishes() async throws {
    let client = RecordingMicrosoftGraphClient()
    let providerGate = TestRendezvous()
    client.beforeSendReturn = {
      await providerGate.hold()
    }
    let syncGate = MailboxConnectionSyncGate()
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "access-token",
        expiresAtMilliseconds: 4_000_000_000_000,
        grantedScopes: fullGraphMailScopes,
        refreshToken: "refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    let adapter = try makeAdapter(
      client: client,
      definitions: RecordingMicrosoftGraphDefinitionSyncService(
        definitions: [graphConnectionDefinition]
      ),
      syncGate: syncGate,
      tokenStore: tokenStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let send = Task {
      try await adapter.send(
        OutgoingMessage(body: "Body", recipient: "reader@example.com", subject: "Subject"),
        connection: connection,
        session: session
      )
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
    let finishedWhileProviderWasRunning = await cleanupFinished.value

    #expect(!(finishedWhileProviderWasRunning))
    await providerGate.release()
    try await send.value
    try await cleanup.value
    let cleanupDidFinish = await cleanupFinished.value
    #expect(client.sentMessages.count == 1)
    #expect(cleanupDidFinish)
  }

  @Test
  func testGraphReauthorizationRechecksCleanupAfterSavingDefinition() async throws {
    let authorizer = RecordingMicrosoftGraphAuthorizer()
    let bodyCache = RecordingMicrosoftGraphBodyCache()
    let definitions = RecordingMicrosoftGraphDefinitionSyncService(
      definitions: [graphConnectionDefinition]
    )
    let cleanupGeneration = 1
    definitions.snapshotAfterSave = MailboxConnectionSyncSnapshot(
      connections: [
        graphConnectionDefinition.withAuthorizationGeneration(cleanupGeneration)
      ],
      defaultSendingConnectionId: nil,
      removedConnectionIds: [],
      updatedAt: 1_781_200_000_001,
      authorizationCleanupConnectionIds: [graphConnectionId],
      localCleanupGenerations: [graphConnectionId: cleanupGeneration]
    )
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "stale-access",
        authorizationGeneration: 0,
        expiresAtMilliseconds: 4_000_000_000_000,
        grantedScopes: fullGraphMailScopes,
        refreshToken: "stale-refresh"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    let adapter = try makeAdapter(
      authorizer: authorizer,
      bodyCache: bodyCache,
      client: RecordingMicrosoftGraphClient(),
      definitions: definitions,
      syncGate: MailboxConnectionSyncGate(),
      tokenStore: tokenStore
    )

    let connection = try await adapter.connect(
      session: session,
      isSessionCurrent: { $0 == self.session }
    )
    let savedTokens = try tokenStore.load(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )

    #expect(bodyCache.connectionClearCount == 1)
    #expect(connection?.authorizationGeneration == cleanupGeneration)
    #expect(savedTokens?.accessToken == authorizer.authorizedTokens.accessToken)
    #expect(savedTokens?.authorizationGeneration == cleanupGeneration)
    #expect(definitions.completedCleanupGenerations[graphConnectionId] == cleanupGeneration)
  }

  @Test
  func testConnectClearsExistingTokensWhenRecreationIsRejected() async throws {
    let authorizer = RecordingMicrosoftGraphAuthorizer()
    let definitions = RecordingMicrosoftGraphDefinitionSyncService()
    let removalObservation = MailboxConnectionRemovalObservation(
      connectionId: graphConnectionId,
      removedAt: 1_781_200_000_500
    )
    definitions.recreateError = MailboxConnectionSyncError.connectionRemoved(removalObservation)
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "previous-access-token",
        expiresAtMilliseconds: 4_000_000_000_000,
        grantedScopes: fullGraphMailScopes,
        refreshToken: "previous-refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    let adapter = try makeAdapter(
      authorizer: authorizer,
      client: RecordingMicrosoftGraphClient(),
      definitions: definitions,
      tokenStore: tokenStore
    )

    do {
      _ = try await adapter.connect(
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
      Issue.record("Expected synchronized recreation to report the removal")
    } catch let error as MailboxConnectionSyncError {
      #expect(error == .connectionRemoved(removalObservation))
    }

    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: graphAccount.id
      ) == nil)
  }

  @Test
  func testFullCapabilitiesRequestWriteAndSendScopes() throws {
    let request = MicrosoftGraphOAuthRequest(
      callbackScheme: "msauth.dev.unwired.mail",
      clientIdentifier: "client-id"
    )
    let queryItems = try requireValue(
      URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
    let scope = try requireValue(queryItems.first(where: { $0.name == "scope" })?.value)

    #expect(MailboxConnectionCapabilities.microsoftGraph.canSend)
    #expect(MailboxConnectionCapabilities.microsoftGraph.canReply)
    #expect(MailboxConnectionCapabilities.microsoftGraph.canForward)
    #if canImport(UIKit)
      #expect(MailboxConnectionCapabilities.microsoftGraph.canRegisterPush)
    #else
      #expect(!(MailboxConnectionCapabilities.microsoftGraph.canRegisterPush))
    #endif
    #expect(!(MailboxConnectionCapabilities.microsoftGraph.supports(.archive)))
    #expect(!(MailboxConnectionCapabilities.microsoftGraph.supports(.spam)))
    #expect(!(MailboxConnectionCapabilities.microsoftGraph.supports(.star)))
    #expect(scope.contains("Mail.ReadWrite"))
    #expect(scope.contains("Mail.Send"))
  }

  @Test
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

    #expect(!(tokens.hasFullMailAccess))
    #expect(tokens.authorizationGeneration == 0)
  }

  @Test
  func testGraphConnectionRequiresAuthorizationForAnOlderConnectionGeneration() async throws {
    let definitions = RecordingMicrosoftGraphDefinitionSyncService(
      definitions: [graphConnectionDefinition.withAuthorizationGeneration(1)]
    )
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "access-token",
        authorizationGeneration: 0,
        expiresAtMilliseconds: 4_000_000_000_000,
        grantedScopes: fullGraphMailScopes,
        refreshToken: "refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    let adapter = try makeAdapter(
      client: RecordingMicrosoftGraphClient(),
      definitions: definitions,
      tokenStore: tokenStore
    )

    let staleConnections = try await adapter.loadConnections(session: session)
    let staleConnection = try requireValue(staleConnections.first)
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "access-token",
        authorizationGeneration: 1,
        expiresAtMilliseconds: 4_000_000_000_000,
        grantedScopes: fullGraphMailScopes,
        refreshToken: "refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
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
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testGraphReplyUsesProviderReplyDraftBeforeSending() async throws {
    var requests: [URLRequest] = []
    var requestBodies: [Data?] = []
    let session = ConvexClientTesting.makeSession(
      protocolClass: GraphAdapterURLStub.self
    ) { request in
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
          url: try requireValue(request.url),
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
        assets: [
          MailDraftAsset(
            data: Data("image".utf8),
            filename: "diagram.png",
            mediaType: "image/png",
            disposition: .inline
          )
        ],
        ccRecipients: "copy@example.com",
        bccRecipients: "hidden@example.com",
        inReplyTo: "<source@example.com>",
        kind: .reply,
        providerThreadId: "conversation-1",
        sourceProviderMessageId: "source-message",
        idempotencyKey: "reply-attempt"
      ),
      accessToken: "provider-access"
    )

    #expect(requests.map(\.httpMethod) == ["GET", "POST", "POST"])
    #expect(
      requests.compactMap(\.url?.path) == [
        "/v1.0/me/mailFolders/drafts/messages",
        "/v1.0/me/messages/source-message/createReply",
        "/v1.0/me/messages/reply-draft/send",
      ])
    let createBody = try requireValue(requestBodies[1])
    let createJSON = try requireValue(
      JSONSerialization.jsonObject(with: createBody) as? [String: Any])
    let draftJSON = try requireValue(createJSON["message"] as? [String: Any])
    let recipients = try requireValue(draftJSON["toRecipients"] as? [[String: Any]])
    #expect(recipients.count == 2)
    #expect(
      recipients.compactMap { ($0["emailAddress"] as? [String: Any])?["address"] as? String } == [
        "jane@example.com", "second@example.com",
      ])
    let ccRecipients = try requireValue(draftJSON["ccRecipients"] as? [[String: Any]])
    #expect(
      ccRecipients.compactMap {
        ($0["emailAddress"] as? [String: Any])?["address"] as? String
      } == ["copy@example.com"])
    let bccRecipients = try requireValue(draftJSON["bccRecipients"] as? [[String: Any]])
    #expect(
      bccRecipients.compactMap {
        ($0["emailAddress"] as? [String: Any])?["address"] as? String
      } == ["hidden@example.com"])
    let extendedProperties = try requireValue(
      draftJSON["singleValueExtendedProperties"] as? [[String: Any]])
    #expect(extendedProperties.first?["value"] as? String == "reply-attempt")
    let attachments = try requireValue(draftJSON["attachments"] as? [[String: Any]])
    #expect(attachments.first?["@odata.type"] as? String == "#microsoft.graph.fileAttachment")
    #expect(
      attachments.first?["contentBytes"] as? String == Data("image".utf8).base64EncodedString())
    #expect(attachments.first?["contentType"] as? String == "image/png")
    #expect(attachments.first?["isInline"] as? Bool == true)
    #expect(attachments.first?["name"] as? String == "diagram.png")
    #expect(draftJSON["internetMessageHeaders"] == nil)
  }

  @Test
  func testGraphForwardSendsTheAlreadyComposedBodyAsANewDraft() async throws {
    var requests: [URLRequest] = []
    var requestBodies: [Data?] = []
    let session = ConvexClientTesting.makeSession(
      protocolClass: GraphAdapterURLStub.self
    ) { request in
      requests.append(request)
      requestBodies.append(try graphRequestBody(request))
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: requests.count == 1 ? 200 : (requests.count == 2 ? 201 : 202),
          httpVersion: nil,
          headerFields: nil
        )!,
        requests.count == 1
          ? Data(#"{"value":[]}"#.utf8)
          : (requests.count == 2 ? Data(#"{"id":"forward-draft"}"#.utf8) : Data())
      )
    }
    let client = URLSessionMicrosoftGraphClient(session: session)

    try await client.send(
      OutgoingMessage(
        body: "Preface\n\nForwarded message from Sender:\nOriginal body",
        recipient: "recipient@example.com",
        subject: "Fwd: Subject",
        inReplyTo: "<source@example.com>",
        kind: .forward,
        sourceProviderMessageId: "source-message",
        idempotencyKey: "forward-attempt"
      ),
      accessToken: "provider-access"
    )

    #expect(requests.map(\.httpMethod) == ["GET", "POST", "POST"])
    #expect(
      requests.compactMap(\.url?.path) == [
        "/v1.0/me/mailFolders/drafts/messages",
        "/v1.0/me/messages",
        "/v1.0/me/messages/forward-draft/send",
      ])
    let createBody = try requireValue(requestBodies[1])
    let draftJSON = try requireValue(
      JSONSerialization.jsonObject(with: createBody) as? [String: Any])
    #expect(
      (draftJSON["body"] as? [String: Any])?["content"] as? String
        == "Preface\n\nForwarded message from Sender:\nOriginal body")
    #expect(
      (draftJSON["internetMessageHeaders"] as? [[String: String]]) ?? [] == [
        ["name": "In-Reply-To", "value": "<source@example.com>"],
        ["name": "References", "value": "<source@example.com>"],
      ])
  }

  @Test
  func testGraphSendReusesAnExistingProviderDraft() async throws {
    var requests: [URLRequest] = []
    let session = ConvexClientTesting.makeSession(
      protocolClass: GraphAdapterURLStub.self
    ) { request in
      requests.append(request)
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
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

    #expect(requests.map(\.httpMethod) == ["GET", "POST"])
    #expect(
      requests.compactMap(\.url?.path) == [
        "/v1.0/me/mailFolders/drafts/messages",
        "/v1.0/me/messages/existing-draft/send",
      ])
  }

  @Test
  func testGraphSendFailureReturnsCreatedProviderDraftIdentity() async throws {
    var requests: [URLRequest] = []
    let session = ConvexClientTesting.makeSession(
      protocolClass: GraphAdapterURLStub.self
    ) { request in
      requests.append(request)
      let statusCode = requests.count == 1 ? 200 : (requests.count == 2 ? 201 : 503)
      let data =
        requests.count == 1
        ? Data(#"{"value":[]}"#.utf8)
        : (requests.count == 2 ? Data(#"{"id":"retained-draft"}"#.utf8) : Data())
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: statusCode,
          httpVersion: nil,
          headerFields: nil
        )!,
        data
      )
    }
    let client = URLSessionMicrosoftGraphClient(session: session)

    do {
      try await client.send(
        OutgoingMessage(
          body: "Body",
          recipient: "recipient@example.com",
          subject: "Subject",
          idempotencyKey: "retained-attempt"
        ),
        accessToken: "provider-access"
      )
      Issue.record("Expected provider handoff to fail")
    } catch let error as MicrosoftGraphSendError {
      #expect(error.stage == .providerHandoff)
      #expect(error.providerDraftId == "retained-draft")
    }
  }

  @Test
  func testGraphDraftDeletionTreatsMissingDraftAsAlreadyClean() async throws {
    var request: URLRequest?
    let session = ConvexClientTesting.makeSession(
      protocolClass: GraphAdapterURLStub.self
    ) { capturedRequest in
      request = capturedRequest
      return (
        HTTPURLResponse(
          url: try requireValue(capturedRequest.url),
          statusCode: 404,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data()
      )
    }
    let client = URLSessionMicrosoftGraphClient(session: session)

    try await client.deleteDraft("stale-draft", accessToken: "provider-access")

    #expect(request?.httpMethod == "DELETE")
    #expect(request?.url?.path == "/v1.0/me/messages/stale-draft")
  }

  @Test
  func testGraphDraftDeletionPropagatesNonMissingFailure() async throws {
    var request: URLRequest?
    let session = ConvexClientTesting.makeSession(
      protocolClass: GraphAdapterURLStub.self
    ) { capturedRequest in
      request = capturedRequest
      return (
        HTTPURLResponse(
          url: try requireValue(capturedRequest.url),
          statusCode: 500,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data()
      )
    }
    let client = URLSessionMicrosoftGraphClient(session: session)

    do {
      try await client.deleteDraft("failed-draft", accessToken: "provider-access")
      Issue.record("Expected draft deletion to fail")
    } catch {
      #expect(error as? MicrosoftGraphClientError == .requestFailed(500))
    }

    #expect(request?.httpMethod == "DELETE")
    #expect(request?.url?.path == "/v1.0/me/messages/failed-draft")
  }

  @Test
  func testGraphPushSubscriptionAcceptsFractionalExpiration() async throws {
    var capturedRequest: URLRequest?
    let session = ConvexClientTesting.makeSession(
      protocolClass: GraphAdapterURLStub.self
    ) { request in
      capturedRequest = request
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
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

    #expect(response.subscriptionId == "subscription-1")
    let requestBody = try requireValue(try graphRequestBody(try requireValue(capturedRequest)))
    let requestJSON = try requireValue(
      JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
    #expect(requestJSON["resource"] as? String == "me/messages")
  }

  @Test
  func testGraphSendFailureDispositionDependsOnProviderHandoffStage() {
    let preparation = outboxFailureDisposition(
      for:
        MicrosoftGraphSendError(
          stage: .preparation,
          underlyingError: MicrosoftGraphClientError.requestFailed(503)
        )
    )
    let handoff = outboxFailureDisposition(
      for:
        MicrosoftGraphSendError(
          stage: .providerHandoff,
          underlyingError: MicrosoftGraphClientError.requestFailed(503)
        )
    )

    guard case .transient = preparation else {
      Issue.record("Expected pre-handoff failure to be transient")
      return
    }
    guard case .ambiguous = handoff else {
      Issue.record("Expected provider handoff failure to be ambiguous")
      return
    }
  }

  @Test
  func testGraphOutboxRetriesTransientTokenRefreshFailures() {
    for status in [429, 503] {
      let disposition = outboxFailureDisposition(
        for: MicrosoftGraphOAuthError.tokenExchangeFailed(status: status)
      )

      guard case .transient = disposition else {
        Issue.record("Expected token endpoint status \(status) to be transient")
        return
      }
    }
  }

  @Test
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
    let initialConnection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: initialConnection, session: session)
    let refreshedConnections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(refreshedConnections.first)
    let message = try requireValue(inbox.messages.first)

    try await adapter.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    )
    let projected = try await adapter.loadInbox(connection: connection, session: session)
    #expect(projected.messages.isEmpty)
    #expect(try pendingStore.load(productAccountId: session.productAccountId).count == 1)

    let resumeError = await adapter.resumePendingActions(connection: connection, session: session)
    #expect(resumeError == nil)
    #expect(
      client.moves == [
        .init(destinationFolderId: "archive-id", messageId: message.providerMessageId)
      ])
  }

  @Test
  func testAmbiguousGraphActionFailureStopsForReconciliation() async throws {
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
    let initialConnection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: initialConnection, session: session)
    let refreshedConnections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(refreshedConnections.first)
    let message = try requireValue(inbox.messages.first)

    try await adapter.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connection: connection, session: session)
    let hasBlockedAction = try await pendingActions.hasBlockedAction(
      connection: connection,
      session: session
    )
    #expect(client.moveAttempts == 1)
    #expect(hasBlockedAction)
    #expect(client.moves.isEmpty)
  }

  @Test
  func testAmbiguousGraphTransportFailureDoesNotReplayMove() async throws {
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
    client.moveErrors = [URLError(.networkConnectionLost)]
    let pendingStore = InMemoryGraphPendingActionStore()
    let pendingActions = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 0 },
      store: pendingStore
    )
    let adapter = try authorizedAdapter(
      client: client,
      pendingActionService: pendingActions
    )
    let initialConnections = try await adapter.loadConnections(session: session)
    let initialConnection = try requireValue(initialConnections.first)
    let inbox = try await adapter.syncInbox(
      connection: initialConnection,
      session: session
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let message = try requireValue(inbox.messages.first)

    try await adapter.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connection: connection, session: session)

    #expect(client.moveAttempts == 1)
    let hasBlockedAction = try await pendingActions.hasBlockedAction(
      connection: connection,
      session: session
    )
    #expect(hasBlockedAction)
    let failureDescription = try await pendingActions.failureDescription(
      connection: connection,
      session: session
    )
    #expect(
      failureDescription
        == "This action may have already been applied and must be confirmed before retrying.")
  }

  @Test
  func testGraphConnectionFailureRetriesMove() async throws {
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
    client.moveErrors = [URLError(.cannotConnectToHost)]
    let pendingActions = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 0 },
      store: InMemoryGraphPendingActionStore()
    )
    let adapter = try authorizedAdapter(
      client: client,
      pendingActionService: pendingActions
    )
    let initialConnections = try await adapter.loadConnections(session: session)
    let initialConnection = try requireValue(initialConnections.first)
    let inbox = try await adapter.syncInbox(
      connection: initialConnection,
      session: session
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let message = try requireValue(inbox.messages.first)

    try await adapter.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connection: connection, session: session)
    await pendingActions.waitForScheduledRetries(connection: connection, session: session)

    #expect(client.moveAttempts == 2)
    #expect(
      client.moves == [
        .init(destinationFolderId: "archive-id", messageId: message.providerMessageId)
      ])
  }

  @Test
  func testTransientTokenRefreshFailureRetriesQueuedGraphAction() async throws {
    let authorizer = RecordingMicrosoftGraphAuthorizer()
    authorizer.refreshErrors = [
      MicrosoftGraphOAuthError.tokenExchangeFailed(status: 429)
    ]
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
    let pendingActions = PendingProviderActionService(
      retryDelayNanoseconds: { _ in 0 },
      store: InMemoryGraphPendingActionStore()
    )
    let adapter = try authorizedAdapter(
      authorizer: authorizer,
      client: client,
      pendingActionService: pendingActions
    )
    let initialConnections = try await adapter.loadConnections(session: session)
    let initialConnection = try requireValue(initialConnections.first)
    let inbox = try await adapter.syncInbox(
      connection: initialConnection,
      session: session
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let message = try requireValue(inbox.messages.first)
    client.rejectedAccessTokens = ["access-token"]

    try await adapter.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connection: connection, session: session)
    await pendingActions.waitForScheduledRetries(connection: connection, session: session)

    #expect(authorizer.refreshedTokens == 2)
    #expect(
      client.moves == [
        .init(destinationFolderId: "archive-id", messageId: message.providerMessageId)
      ])
  }

  @Test
  func testMappedFolderRolesControlAdvertisedProviderActions() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [
      graphFolder(id: "inbox-id", wellKnownName: "inbox"),
      graphFolder(id: "archive-id", displayName: "Archive", wellKnownName: "archive"),
      graphFolder(id: "custom-id", displayName: "Receipts", wellKnownName: nil),
    ]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    let adapter = try authorizedAdapter(client: client)
    let initialConnections = try await adapter.loadConnections(session: session)
    let initialConnection = try requireValue(initialConnections.first)

    #expect(!(initialConnection.capabilities.supports(.archive)))
    #expect(!(initialConnection.capabilities.supports(.delete)))
    _ = try await adapter.syncInbox(connection: initialConnection, session: session)

    let synchronizedConnections = try await adapter.loadConnections(session: session)
    let synchronizedConnection = try requireValue(synchronizedConnections.first)
    #expect(synchronizedConnection.capabilities.supports(.archive))
    #expect(synchronizedConnection.capabilities.supports(.move))
    #expect(synchronizedConnection.capabilities.supports(.restore))
    #expect(!(synchronizedConnection.capabilities.supports(.delete)))
    #expect(!(synchronizedConnection.capabilities.supports(.spam)))
  }

  @Test
  func testSendingAndDeliveryReconciliationUseStableOutboxMessageId() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let message = OutgoingMessage(
      body: "Graph body",
      recipient: "recipient@example.com",
      subject: "Graph subject",
      idempotencyKey: "graph-attempt-1"
    )
    client.deliveryStatuses[try requireValue(message.rfcMessageId)] = .sent

    try await adapter.send(message, connection: connection, session: session)
    let status = try await adapter.deliveryStatus(
      idempotencyKey: "graph-attempt-1",
      connection: connection,
      session: session
    )

    #expect(client.sentMessages == [message])
    #expect(status == .sent)
  }

  @Test
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
        grantedScopes: fullGraphMailScopes,
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
    let connection = try requireValue(connections.first)

    try await adapter.registerOrRenewPush(connection: connection, session: session)
    try await adapter.setDefaultSendingConnection(connection, session: session)

    #expect(push.registeredConnectionIds == [connection.id])
    #expect(push.accessTokens == ["access-token"])
    #expect(definitions.defaultSendingConnectionId == connection.id)
  }

  @Test
  func testConnectionCleanupPassesProviderTokenBeforeClearingAuthorization() async throws {
    let push = RecordingMicrosoftGraphPushRegistrar()
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let adapter = try authorizedAdapter(
      client: RecordingMicrosoftGraphClient(),
      keyMaterialStore: keyStore,
      pushRegistrar: push
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    do {
      try await adapter.clearLocalConnection(connection, session: session)
    } catch ProductSyncKeyMaterialStoreError.recoveryRequired {
      // The default encrypted Outbox store has no test key; push cleanup must run first.
    }

    #expect(push.clearedAccessTokens == ["access-token"])
    #expect(push.clearedConnectionIds == [connection.id])
  }

  @Test
  func testConnectionCleanupContinuesWhenStoredTokenCannotBeDecoded() async throws {
    let push = RecordingMicrosoftGraphPushRegistrar()
    let tokenStore = FailingLoadMicrosoftGraphAuthorizationStore()
    let adapter = try makeAdapter(
      client: RecordingMicrosoftGraphClient(),
      definitions: RecordingMicrosoftGraphDefinitionSyncService(
        definitions: [graphConnectionDefinition]
      ),
      outboxService: OutboxDeliveryService(store: InMemoryGraphOutboxDeliveryStore()),
      pushRegistrar: push,
      tokenStore: tokenStore
    )
    let connection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: .microsoftGraph,
      connectedAt: graphConnectionDefinition.connectedAt,
      displayName: graphConnectionDefinition.displayName,
      id: graphConnectionDefinition.id,
      lastVerifiedAt: graphConnectionDefinition.connectedAt,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: graphConnectionDefinition.connectedAt
    )

    do {
      try await adapter.clearLocalConnection(connection, session: session)
      Issue.record("Expected the token decoding error to be reported after cleanup")
    } catch GraphTokenStoreTestError.cannotDecode {}

    #expect(push.clearedAccessTokens == [nil])
    #expect(tokenStore.clearedProviderAccountIdentifiers == [graphAccount.id])
  }

  @Test
  func testRemovedConnectionPushCleanupFailureDoesNotBlockActiveConnections() async throws {
    let removedConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .microsoftGraph,
        value: "removed-graph-account"
      )
    )
    let definitions = RecordingMicrosoftGraphDefinitionSyncService(
      definitions: [graphConnectionDefinition]
    )
    definitions.removedConnectionIds = [removedConnectionId]
    let push = RecordingMicrosoftGraphPushRegistrar()
    push.clearError = URLError(.notConnectedToInternet)
    let adapter = try makeAdapter(
      client: RecordingMicrosoftGraphClient(),
      definitions: definitions,
      outboxService: OutboxDeliveryService(store: InMemoryGraphOutboxDeliveryStore()),
      pushRegistrar: push,
      tokenStore: InMemoryMicrosoftGraphAuthorizationStore()
    )

    let connections = try await adapter.loadConnections(session: session)

    #expect(connections.map(\.id) == [graphConnectionDefinition.id])
    #expect(push.clearedConnectionIds == [removedConnectionId])
  }

  @Test
  func testAccountCleanupContinuesWhenStoredTokenCannotBeDecoded() async throws {
    let push = RecordingMicrosoftGraphPushRegistrar()
    let tokenStore = FailingLoadMicrosoftGraphAuthorizationStore(
      providerAccountIdentifiers: [graphAccount.id]
    )
    let adapter = try makeAdapter(
      client: RecordingMicrosoftGraphClient(),
      definitions: RecordingMicrosoftGraphDefinitionSyncService(
        definitions: [graphConnectionDefinition]
      ),
      pushRegistrar: push,
      tokenStore: tokenStore
    )

    do {
      try await adapter.clearLocalConnection(session: session)
      Issue.record("Expected the token decoding error to be reported after cleanup")
    } catch GraphTokenStoreTestError.cannotDecode {}

    #expect(push.clearedAllAccessTokens == [[:]])
    #expect(tokenStore.clearAllCallCount == 1)
  }

  @Test
  func testAccountCleanupWaitsForEveryActiveConnection() async throws {
    let syncGate = MailboxConnectionSyncGate()
    let push = RecordingMicrosoftGraphPushRegistrar()
    let adapter = try makeAdapter(
      client: RecordingMicrosoftGraphClient(),
      definitions: RecordingMicrosoftGraphDefinitionSyncService(
        definitions: [graphConnectionDefinition]
      ),
      pushRegistrar: push,
      syncGate: syncGate,
      tokenStore: InMemoryMicrosoftGraphAuthorizationStore()
    )
    let unrelatedConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-001"
      )
    )
    let blocker = TestRendezvous()
    let activeConnection = Task {
      try await syncGate.withLock(unrelatedConnectionId) {
        await blocker.hold()
      }
    }
    await blocker.waitUntilHeld()
    let cleanupInvoked = expectation(description: "account cleanup invoked")
    let cleanup = Task {
      cleanupInvoked.fulfill()
      try await adapter.clearLocalConnection(session: session)
    }
    await fulfillment(of: [cleanupInvoked], timeout: 1)

    #expect(push.clearedAllAccessTokens.isEmpty)

    await blocker.release()
    try await activeConnection.value
    try await cleanup.value
    #expect(push.clearedAllAccessTokens == [[:]])
  }

  @Test
  func testConnectionRemovalContinuesWhenPushCleanupFails() async throws {
    let push = RecordingMicrosoftGraphPushRegistrar()
    push.clearError = URLError(.networkConnectionLost)
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let definitions = RecordingMicrosoftGraphDefinitionSyncService(
      definitions: [graphConnectionDefinition]
    )
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "access-token",
        expiresAtMilliseconds: 4_000_000_000_000,
        grantedScopes: fullGraphMailScopes,
        refreshToken: "refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = try makeAdapter(
      client: RecordingMicrosoftGraphClient(),
      definitions: definitions,
      keyMaterialStore: keyStore,
      outboxService: OutboxDeliveryService(
        store: FileOutboxDeliveryStore(
          keyMaterialStore: keyStore,
          rootDirectory: directory
        )
      ),
      pushRegistrar: push,
      tokenStore: tokenStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    do {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
      Issue.record("Expected push cleanup failure")
    } catch {}

    #expect(definitions.removedConnectionIds == [connection.id])
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testConnectionRemovalClearsLocalDataAfterDraftCleanupRetriesExhaust() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let definitions = RecordingMicrosoftGraphDefinitionSyncService(
      definitions: [graphConnectionDefinition]
    )
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "access-token",
        expiresAtMilliseconds: 4_000_000_000_000,
        grantedScopes: fullGraphMailScopes,
        refreshToken: "refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    let outboxService = OutboxDeliveryService(
      handoffDelayNanoseconds: 0,
      maximumAttempts: 1,
      providerDraftCleaner: { _, _, _ in
        throw URLError(.networkConnectionLost)
      },
      store: InMemoryGraphOutboxDeliveryStore()
    )
    let adapter = try makeAdapter(
      client: RecordingMicrosoftGraphClient(),
      definitions: definitions,
      keyMaterialStore: keyStore,
      outboxService: outboxService,
      tokenStore: tokenStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    _ = try await outboxService.enqueue(
      OutgoingMessage(
        body: "Body",
        recipient: "reader@example.com",
        subject: "Subject"
      ),
      connection: connection,
      session: session,
      provider: { _, _, _ in
        throw MicrosoftGraphSendError(
          stage: .providerHandoff,
          underlyingError: MicrosoftGraphClientError.requestFailed(429),
          providerDraftId: "exhausted-draft"
        )
      },
      reconcile: { _, _ in .notSent }
    )

    do {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
      Issue.record("Expected exhausted draft cleanup to remain reported")
    } catch {
      #expect(error is OutboxProviderDraftCleanupExhaustedError)
    }

    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: graphAccount.id
      ) == nil)
    #expect(definitions.removedConnectionIds == [connection.id])
  }

  @Test
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
    let connection = try requireValue(loadedConnections.first)

    let initial = try await firstAdapter.syncInbox(connection: connection, session: session)

    #expect(initial.hasInitialMailboxAvailability)
    #expect(!(initial.historicalMetadataBackfillIsComplete))
    #expect(initial.messages.count == 50)
    #expect(initial.messages.first?.subject == "Message 75")

    let recreated = try authorizedAdapter(client: client, store: store)
    let complete = try await recreated.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    #expect(complete.historicalMetadataBackfillIsComplete)
    #expect(complete.messages.count == 75)
    #expect(complete.messages.last?.subject == "Message 1")
    #expect(client.requestedContinuations.last == "https://graph.microsoft.test/inbox/page-2")
    #expect(
      try store.loadState(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )?.initialCrawlMessageIdsByFolderId?["inbox-id"] == nil)
  }

  @Test
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
    let connection = try requireValue(connections.first)

    let initial = try await adapter.syncInbox(connection: connection, session: session)

    #expect(initial.messages.count == 50)
    #expect(initial.messages.first?.subject == "Message 50")
    #expect(!(initial.historicalMetadataBackfillIsComplete))
    #expect(client.requestedContinuations == [nil, "https://graph.microsoft.test/inbox/page-2"])
  }

  @Test
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
    let connection = try requireValue(connections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)
    let initial = try await adapter.loadMailbox(
      .allObserved,
      connection: connection,
      session: session
    )

    #expect(initial.messages.map(\.subject) == ["Message 100", "Message 1"])
    #expect(
      client.requestedContinuations == [
        nil,
        "https://graph.microsoft.test/inbox/page-2",
      ])
    #expect(client.requestedRecentFolderIds == ["sent-id"])
  }

  @Test
  func testInitialSentSeedIsRemovedWhenAbsentFromItsFirstDeltaBaseline() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [
      graphFolder(id: "inbox-id", wellKnownName: "inbox"),
      graphFolder(id: "sent-id", displayName: "Sent Items", wellKnownName: "sentitems"),
    ]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1, folderId: "inbox-id")],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    client.pages["sent-id|recent"] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(100, folderId: "sent-id")],
      nextLink: nil,
      deltaLink: nil
    )
    client.pages[pageKey(folderId: "sent-id")] = MicrosoftGraphMetadataPage(
      messages: [],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/sent/delta")
    )
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)
    let initial = try await adapter.loadMailbox(
      .allObserved,
      connection: connection,
      session: session
    )
    _ = try await adapter.syncInbox(connection: connection, session: session)
    _ = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )
    let complete = try await adapter.loadMailbox(
      .allObserved,
      connection: connection,
      session: session
    )

    #expect(initial.messages.contains { $0.providerMessageId == "immutable-message-100" })
    #expect(!(complete.messages.contains { $0.providerMessageId == "immutable-message-100" }))
    #expect(complete.historicalMetadataBackfillIsComplete)
  }

  @Test
  func testRecentSyncConsumesCompletedFolderDeltaWhileBackfillIsIncomplete() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [
      graphFolder(id: "inbox-id", wellKnownName: "inbox"),
      graphFolder(id: "sent-id", displayName: "Sent Items", wellKnownName: "sentitems"),
    ]
    let inboxDelta = "https://graph.microsoft.test/inbox/delta-1"
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1)],
      nextLink: nil,
      deltaLink: URL(string: inboxDelta)
    )
    client.pages["sent-id|recent"] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(2, folderId: "sent-id")],
      nextLink: nil,
      deltaLink: nil
    )
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let initial = try await adapter.syncInbox(connection: connection, session: session)
    #expect(!(initial.historicalMetadataBackfillIsComplete))
    client.pages[pageKey(folderId: "inbox-id", continuation: inboxDelta)] =
      MicrosoftGraphMetadataPage(
        messages: [graphMessage(3)],
        nextLink: nil,
        deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta-2")
      )

    let refreshed = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: false,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    #expect(client.requestedContinuations.last == inboxDelta)
    #expect(refreshed.messages.contains { $0.providerMessageId == "immutable-message-3" })
  }

  @Test
  func testRecentInboxDeltaRemovesCachedMessageWhileBackfillRemainsIncomplete() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: (1...50).reversed().map { graphMessage($0) },
      nextLink: URL(string: "https://graph.microsoft.test/inbox/history-page-2"),
      deltaLink: nil
    )
    let recentDelta = "https://graph.microsoft.test/inbox/recent-delta-1"
    client.pages["inbox-id|recent-delta"] = MicrosoftGraphMetadataPage(
      messages: [],
      nextLink: nil,
      deltaLink: URL(string: recentDelta)
    )
    let refreshedRecentDelta = "https://graph.microsoft.test/inbox/recent-delta-2"
    client.pages[pageKey(folderId: "inbox-id", continuation: recentDelta)] =
      MicrosoftGraphMetadataPage(
        messages: [],
        nextLink: nil,
        deltaLink: URL(string: refreshedRecentDelta)
      )
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    let initial = try await adapter.syncInbox(connection: connection, session: session)
    #expect(!(initial.historicalMetadataBackfillIsComplete))
    #expect(initial.messages.contains { $0.providerMessageId == "immutable-message-1" })
    client.pages[pageKey(folderId: "inbox-id", continuation: refreshedRecentDelta)] =
      MicrosoftGraphMetadataPage(
        messages: [graphMessage(1, removed: true)],
        nextLink: nil,
        deltaLink: URL(string: "https://graph.microsoft.test/inbox/recent-delta-3")
      )

    let refreshed = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: false,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    #expect(!(refreshed.historicalMetadataBackfillIsComplete))
    #expect(!(refreshed.messages.contains { $0.providerMessageId == "immutable-message-1" }))
    #expect(client.requestedRecentDeltaFolderIds == ["inbox-id"])
    #expect(client.requestedRecentDeltaCutoffs == [connection.connectedAt])
    #expect(client.requestedContinuations.last == refreshedRecentDelta)
  }

  @Test
  func testInitialSyncObservesRemovalAfterRecentInboxCursorIsEstablished() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: (1...50).reversed().map { graphMessage($0) },
      nextLink: URL(string: "https://graph.microsoft.test/inbox/history-page-2"),
      deltaLink: nil
    )
    let recentDelta = "https://graph.microsoft.test/inbox/recent-delta-1"
    client.pages["inbox-id|recent-delta"] = MicrosoftGraphMetadataPage(
      messages: [],
      nextLink: nil,
      deltaLink: URL(string: recentDelta)
    )
    client.metadataPageDidLoad = {
      client.pages[pageKey(folderId: "inbox-id", continuation: recentDelta)] =
        MicrosoftGraphMetadataPage(
          messages: [graphMessage(1, removed: true)],
          nextLink: nil,
          deltaLink: URL(string: "https://graph.microsoft.test/inbox/recent-delta-2")
        )
    }
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    let initial = try await adapter.syncInbox(connection: connection, session: session)

    #expect(!(initial.historicalMetadataBackfillIsComplete))
    #expect(!(initial.messages.contains { $0.providerMessageId == "immutable-message-1" }))
    #expect(client.requestedRecentDeltaFolderIds == ["inbox-id"])
    #expect(client.requestedContinuations == [nil, recentDelta])
  }

  @Test
  func testRecentInboxDeltaBaselineDoesNotRemoveMessagesMissingFromItsBoundedPage()
    async throws
  {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: (1...50).reversed().map { graphMessage($0) },
      nextLink: URL(string: "https://graph.microsoft.test/inbox/history-page-2"),
      deltaLink: nil
    )
    client.pages["inbox-id|recent-delta"] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(50)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/recent-delta")
    )
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    let initial = try await adapter.syncInbox(connection: connection, session: session)

    #expect(!(initial.historicalMetadataBackfillIsComplete))
    #expect(initial.messages.count == 50)
    #expect(initial.messages.contains { $0.providerMessageId == "immutable-message-1" })
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testRecentInboxDeltaRequestUsesConnectionBoundaryFilter() async throws {
    var capturedRequest: URLRequest?
    let session = ConvexClientTesting.makeSession(
      protocolClass: GraphAdapterURLStub.self
    ) { request in
      capturedRequest = request
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(
          ##"""
          {"value":[{
            "id":"immutable-message-1",
            "sender":{"emailAddress":{"name":"Transport Ari","address":"ari@example.com"}},
            "from":{"emailAddress":{"name":"Ari Example","address":"ari@example.com"}},
            "replyTo":[
              {"emailAddress":{"name":"Ari Replies","address":"ari@example.com"}}
            ],
            "toRecipients":[
              {"emailAddress":{"name":"Reader","address":"reader@example.com"}}
            ],
            "attachments":[{
              "@odata.type":"#microsoft.graph.fileAttachment",
              "id":"calendar-1","name":"invite.ics","contentType":"text/calendar",
              "size":512,"isInline":false
            }],
            "internetMessageHeaders":[
              {"name":"Received","value":"private transport path"},
              {"name":"List-ID","value":"Product News <news.example.com>"},
              {
                "name":"List-Unsubscribe",
                "value":"<mailto:leave@example.com?subject=remove&body=unsubscribe>"
              },
              {
                "name":"list-unsubscribe",
                "value":"<https://lists.example.com/unsubscribe>"
              },
              {
                "name":"List-Unsubscribe-Post",
                "value":"List-Unsubscribe=One-Click"
              }
            ]
          },{
            "@odata.type":"#microsoft.graph.eventMessageRequest",
            "id":"immutable-message-2",
            "meetingMessageType":"meetingRequest"
          }]}
          """##.utf8
        )
      )
    }
    let client = URLSessionMicrosoftGraphClient(session: session)

    let page = try await client.loadRecentDeltaMetadataPage(
      folder: graphFolder(id: "inbox-id", wellKnownName: "inbox"),
      receivedAfterMilliseconds: 0,
      pageSize: 50,
      accessToken: "provider-access"
    )

    let request = try requireValue(capturedRequest)
    #expect(request.url?.path == "/v1.0/me/mailFolders/inbox-id/messages/delta")
    let queryItems = try requireValue(
      URLComponents(url: try requireValue(request.url), resolvingAgainstBaseURL: false)?.queryItems)
    #expect(
      queryItems.first { $0.name == "$filter" }?.value == "receivedDateTime ge 1970-01-01T00:00:00Z"
    )
    let select = try requireValue(queryItems.first { $0.name == "$select" }?.value)
    let selectedFields = Set(select.split(separator: ",").map(String.init))
    #expect(selectedFields.contains("hasAttachments"))
    #expect(selectedFields.contains("internetMessageHeaders"))
    #expect(selectedFields.contains("sender"))
    #expect(!(selectedFields.contains("meetingMessageType")))
    #expect(selectedFields.contains("bodyPreview"))
    #expect(!(selectedFields.contains("body")))
    let expand = try requireValue(queryItems.first { $0.name == "$expand" }?.value)
    #expect(expand.contains("attachments"))
    #expect(expand.contains("contentType"))
    #expect(!(expand.contains("contentBytes")))
    let message = try requireValue(page.messages.first)
    #expect(message.sender == "Transport Ari <ari@example.com>")
    #expect(message.from == "Ari Example <ari@example.com>")
    #expect(message.replyTo == ["Ari Replies <ari@example.com>"])
    #expect(message.calendarInvitation?.providerAttachmentId == "calendar-1")
    #expect(message.calendarInvitation?.byteCount == 512)
    #expect(
      page.messages.last?.calendarInvitation?.providerPartId
        == "microsoft-graph:event-message"
    )
    #expect(
      message.internetMessageHeaders?.map(\.name) == [
        "List-ID", "List-Unsubscribe", "list-unsubscribe", "List-Unsubscribe-Post",
      ])
    let metadata = try requireValue(
      message.mailboxMetadata(
        connectionId: graphConnectionId,
        connectedAt: 0,
        foldersById: ["inbox-id": graphFolder(id: "inbox-id", wellKnownName: "inbox")]
      )
    )
    #expect(metadata.sender == "Transport Ari <ari@example.com>")
    #expect(metadata.from == "Ari Example <ari@example.com>")
    #expect(metadata.replyToIdentities == ["Ari Replies <ari@example.com>"])
    let suggestion = try requireValue(metadata.unsubscribeSuggestion)
    #expect(suggestion.mailingListIdentity.rawValue == "list-id:news.example.com")
    #expect(
      suggestion.actions == [
        .oneClick(try requireValue(URL(string: "https://lists.example.com/unsubscribe"))),
        .mailto(
          UnsubscribeMailtoMessage(
            body: "unsubscribe",
            recipient: "leave@example.com",
            subject: "remove"
          )
        ),
        .web(try requireValue(URL(string: "https://lists.example.com/unsubscribe"))),
      ]
    )
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testGraphEventMessageCalendarContentLoadsOnlyThroughExplicitBoundedShape()
    async throws
  {
    var capturedRequests: [URLRequest] = []
    let session = ConvexClientTesting.makeSession(
      protocolClass: GraphAdapterURLStub.self
    ) { request in
      capturedRequests.append(request)
      let response =
        if capturedRequests.count == 1 {
          ##"""
          {
            "@odata.type":"#microsoft.graph.eventMessageRequest",
            "meetingMessageType":"meetingRequest",
            "event":{
              "iCalUId":"meeting-001@example.com",
              "subject":"Planning review",
              "bodyPreview":"Bring the launch plan.",
              "start":{"dateTime":"2026-09-01T15:00:00.0000000","timeZone":"UTC"},
              "end":{"dateTime":"2026-09-01T16:00:00.0000000","timeZone":"UTC"},
              "isAllDay":false,
              "isCancelled":false,
              "lastModifiedDateTime":"2026-08-13T09:00:00Z",
              "location":{"displayName":"Room 4"},
              "recurrence":null,
              "type":"singleInstance"
            }
          }
          """##
        } else {
          ##"""
          {
            "@odata.type":"#microsoft.graph.eventMessageRequest",
            "meetingMessageType":"meetingCancelled",
            "event":{
              "iCalUId":"meeting-001@example.com",
              "subject":"Planning review",
              "bodyPreview":"Cancelled.",
              "start":{"dateTime":"2026-09-01T15:00:00.0000000","timeZone":"UTC"},
              "end":{"dateTime":"2026-09-01T16:00:00.0000000","timeZone":"UTC"},
              "isAllDay":false,
              "isCancelled":true,
              "lastModifiedDateTime":"2026-08-13T10:00:00Z",
              "location":{"displayName":"Room 4"},
              "recurrence":null,
              "type":"singleInstance"
            }
          }
          """##
        }
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(response.utf8)
      )
    }
    let client = URLSessionMicrosoftGraphClient(session: session)

    let request = try await client.loadEventMessageCalendarCandidate(
      messageId: "immutable/message",
      accessToken: "provider-access"
    )
    let cancellation = try await client.loadEventMessageCalendarCandidate(
      messageId: "immutable/message-update",
      accessToken: "provider-access"
    )

    #expect(request.method == .request)
    #expect(request.uid == "meeting-001@example.com")
    #expect(request.summary == "Planning review")
    #expect(request.location == "Room 4")
    #expect(request.notes == "Bring the launch plan.")
    #expect(request.timeZoneIdentifier == "UTC")
    #expect(cancellation.method == .cancel)
    #expect(cancellation.opaqueUID == request.opaqueUID)
    #expect(cancellation.sequence > request.sequence)
    let firstURL = try requireValue(capturedRequests.first?.url)
    #expect(firstURL.path == "/v1.0/me/messages/immutable/message")
    let queryItems = try requireValue(
      URLComponents(url: firstURL, resolvingAgainstBaseURL: false)?.queryItems
    )
    let expand = try requireValue(queryItems.first { $0.name == "$expand" }?.value)
    #expect(expand.contains("microsoft.graph.eventMessage/event"))
    #expect(expand.contains("iCalUId"))
    #expect(!(expand.contains("body,")))
    #expect(
      capturedRequests.first?.value(forHTTPHeaderField: "Prefer")
        == #"IdType="ImmutableId", outlook.timezone="UTC""#
    )
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testGraphAttachmentDescriptorsExcludeBytesAndClassifyPresentationBoundaries()
    async throws
  {
    var capturedRequest: URLRequest?
    let session = ConvexClientTesting.makeSession(
      protocolClass: GraphAdapterURLStub.self
    ) { request in
      capturedRequest = request
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(
          ##"""
          {"value":[
            {
              "@odata.type":"#microsoft.graph.fileAttachment",
              "id":"file-1","name":"receipt.pdf","contentType":"application/pdf",
              "size":3,"isInline":false
            },
            {
              "@odata.type":"#microsoft.graph.fileAttachment",
              "id":"inline-1","name":"logo.png","contentType":"image/png",
              "size":4,"isInline":true,"contentId":"logo@example"
            },
            {
              "@odata.type":"#microsoft.graph.itemAttachment",
              "id":"item-1","name":"forwarded.eml","contentType":"message/rfc822",
              "size":5,"isInline":false
            },
            {
              "@odata.type":"#microsoft.graph.referenceAttachment",
              "id":"reference-1","name":"cloud-file","size":6,"isInline":false
            }
          ]}
          """##.utf8
        )
      )
    }
    let client = URLSessionMicrosoftGraphClient(session: session)

    let descriptors = try await client.loadAttachmentDescriptors(
      messageId: "immutable/message",
      accessToken: "provider-access"
    )

    #expect(
      descriptors.map(\.kind) == [.file, .inlineImage, .unsupportedItem, .unsupportedReference])
    #expect(descriptors.compactMap(\.mailboxAttachment).map(\.id) == ["file-1"])
    let request = try requireValue(capturedRequest)
    #expect(request.url?.path == "/v1.0/me/messages/immutable/message/attachments")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer provider-access")
    #expect(request.value(forHTTPHeaderField: "Prefer") == #"IdType="ImmutableId""#)
    let select = try requireValue(
      URLComponents(url: try requireValue(request.url), resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "$select" }?.value)
    #expect(select == "id,name,contentType,size,isInline")
    #expect(!(select.contains("contentBytes")))
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testGraphAttachmentDownloadUsesAuthenticatedRawEndpointAndBoundsBytes() async throws {
    var capturedRequests: [URLRequest] = []
    let session = ConvexClientTesting.makeSession(
      protocolClass: GraphAdapterURLStub.self
    ) { request in
      capturedRequests.append(request)
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data("PDF".utf8)
      )
    }
    let client = URLSessionMicrosoftGraphClient(session: session)

    let data = try await client.loadAttachmentData(
      messageId: "immutable-message",
      attachmentId: "attachment/id",
      expectedByteCount: 3,
      maximumByteCount: 4,
      accessToken: "provider-access"
    )
    #expect(data == Data("PDF".utf8))
    let request = try requireValue(capturedRequests.first)
    #expect(
      request.url?.path
        == "/v1.0/me/messages/immutable-message/attachments/attachment/id/$value")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer provider-access")
    #expect(request.value(forHTTPHeaderField: "Prefer") == #"IdType="ImmutableId""#)

    do {
      _ = try await client.loadAttachmentData(
        messageId: "immutable-message",
        attachmentId: "attachment/id",
        expectedByteCount: 2,
        maximumByteCount: 4,
        accessToken: "provider-access"
      )
      Issue.record("Expected provider bytes larger than the descriptor to be rejected")
    } catch MailboxMessageAttachmentError.invalidResponse {
    } catch {
      Issue.record("Expected invalid attachment response, got \(error)")
    }

    let oversizedSession = ConvexClientTesting.makeSession(
      protocolClass: GraphAdapterURLStub.self
    ) { request in
      (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Length": "5"]
        )!,
        Data("PDF".utf8)
      )
    }
    let oversizedClient = URLSessionMicrosoftGraphClient(session: oversizedSession)
    do {
      _ = try await oversizedClient.loadAttachmentData(
        messageId: "immutable-message",
        attachmentId: "attachment/id",
        expectedByteCount: 4,
        maximumByteCount: 4,
        accessToken: "provider-access"
      )
      Issue.record("Expected an oversized Content-Length to be rejected")
    } catch MailboxMessageAttachmentError.invalidResponse {
    } catch {
      Issue.record("Expected invalid attachment response, got \(error)")
    }

    do {
      _ = try await oversizedClient.loadAttachmentData(
        messageId: "immutable-message",
        attachmentId: "attachment/id",
        expectedByteCount: 5,
        maximumByteCount: 4,
        accessToken: "provider-access"
      )
      Issue.record("Expected an oversized descriptor to be rejected")
    } catch MailboxMessageAttachmentError.invalidResponse {
    } catch {
      Issue.record("Expected invalid attachment response, got \(error)")
    }
  }

  @Test
  func testGraphRawMessageSourceUsesAuthenticatedMimeEndpointAndPreservesBytes() async throws {
    var capturedRequest: URLRequest?
    let expected = Data("Subject: Exact\r\n\r\nBody\u{0}".utf8)
    let session = ConvexClientTesting.makeSession(
      protocolClass: GraphAdapterURLStub.self
    ) { request in
      capturedRequest = request
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Length": String(expected.count)]
        )!,
        expected
      )
    }
    let client = URLSessionMicrosoftGraphClient(session: session)

    let source = try await client.loadMessageSourceData(
      messageId: "immutable/message",
      maximumByteCount: expected.count,
      accessToken: "provider-access"
    )

    #expect(source == expected)
    let request = try requireValue(capturedRequest)
    #expect(request.url?.path == "/v1.0/me/messages/immutable/message/$value")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer provider-access")
    #expect(request.value(forHTTPHeaderField: "Prefer") == #"IdType="ImmutableId""#)
  }

  @Test
  func testGraphRawMessageSourceRejectsOversizedDeclaredAndReceivedBodies() async throws {
    let oversized = Data("oversized".utf8)
    let session = ConvexClientTesting.makeSession(
      protocolClass: GraphAdapterURLStub.self
    ) { request in
      (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Length": String(oversized.count)]
        )!,
        oversized
      )
    }
    let client = URLSessionMicrosoftGraphClient(session: session)

    await #expect(throws: MailboxMessageAttachmentError.invalidResponse) {
      try await client.loadMessageSourceData(
        messageId: "immutable-message",
        maximumByteCount: oversized.count - 1,
        accessToken: "provider-access"
      )
    }
  }

  @Test
  func testInitialAvailabilityFindsNewerMessagesAfterFirstFolderHasFifty() async throws {
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
    client.pages["sent-id|recent"] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(100, folderId: "sent-id")],
      nextLink: nil,
      deltaLink: nil
    )
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    let initial = try await adapter.syncInbox(connection: connection, session: session)
    let allObserved = try await adapter.loadMailbox(
      .allObserved,
      connection: connection,
      session: session
    )

    #expect(initial.hasInitialMailboxAvailability)
    #expect(!(initial.historicalMetadataBackfillIsComplete))
    #expect(initial.messages.count == 49)
    #expect(!(initial.messages.contains { $0.subject == "Message 1" }))
    #expect(allObserved.messages.count == 51)
    #expect(allObserved.messages.first?.subject == "Message 100")
    #expect(client.requestedContinuations == [nil])
    #expect(client.requestedRecentFolderIds == ["sent-id"])
  }

  @Test
  func testExpiredDeltaCursorRestartsWithoutRetainingDuplicateOrStaleMessages() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [
        graphMessage(
          1,
          internetMessageHeaders: [
            MicrosoftGraphInternetMessageHeader(
              name: "List-ID",
              value: "Product News <news.example.com>"
            ),
            MicrosoftGraphInternetMessageHeader(
              name: "List-Unsubscribe",
              value: "<https://lists.example.com/unsubscribe>"
            ),
          ]
        )
      ],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta-1")
    )
    let store = try SwiftDataMicrosoftGraphMetadataStore.inMemory()
    let adapter = try authorizedAdapter(client: client, store: store)
    let loadedConnections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(loadedConnections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    client.expiredContinuations = ["https://graph.microsoft.test/inbox/delta-1"]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(2)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta-2")
    )

    let refreshed = try await adapter.syncInbox(connection: connection, session: session)

    #expect(refreshed.providerCursorIsExpired)
    #expect(refreshed.messages.map(\.providerMessageId) == ["immutable-message-2"])
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testPreviousMetadataContractRebuildsBeforeHistoricalBackfill() async throws {
    let client = RecordingMicrosoftGraphClient()
    let folder = graphFolder(id: "inbox-id", wellKnownName: "inbox")
    client.folders = [folder]
    client.pages[pageKey(folderId: folder.id)] = MicrosoftGraphMetadataPage(
      messages: [
        graphMessage(
          2,
          internetMessageHeaders: [
            MicrosoftGraphInternetMessageHeader(
              name: "List-ID",
              value: "Product News <news.example.com>"
            ),
            MicrosoftGraphInternetMessageHeader(
              name: "List-Unsubscribe",
              value: "<https://lists.example.com/unsubscribe>"
            ),
          ]
        )
      ],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/current-delta")
    )
    let store = try SwiftDataMicrosoftGraphMetadataStore.inMemory()
    let legacyState = MicrosoftGraphMetadataSyncState(
      folders: [
        MicrosoftGraphFolderSyncState(
          folder: folder,
          deltaLink: URL(string: "https://graph.microsoft.test/inbox/legacy-delta"),
          nextLink: nil
        )
      ],
      hasInitialMailboxAvailability: true,
      metadataContractVersion: 3
    )
    try store.savePage(
      [graphMessage(1)],
      folderId: folder.id,
      state: legacyState,
      productAccountId: session.productAccountId,
      connectionId: graphConnectionId
    )
    let adapter = try authorizedAdapter(client: client, store: store)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    client.metadataError = URLError(.notConnectedToInternet)
    await #expect(throws: URLError.self) {
      _ = try await adapter.continueHistoricalBackfill(
        connection: connection,
        session: session
      )
    }
    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ).map(\.id) == ["immutable-message-1"]
    )
    #expect(
      try store.loadState(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )?.metadataContractVersion == 3
    )
    client.metadataError = nil

    let refreshed = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    #expect(client.requestedContinuations == [nil, nil])
    #expect(refreshed.messages.map(\.providerMessageId) == ["immutable-message-2"])
    #expect(
      refreshed.messages.first?.unsubscribeSuggestion?.mailingListIdentity.rawValue
        == "list-id:news.example.com"
    )
  }

  @Test
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
    let connection = try requireValue(loadedConnections.first)

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

    #expect(observed.threads.count == 2)
    #expect(observed.threads.first { $0.providerThreadId == "conversation-1" }?.messages.count == 2)
    #expect(
      Set(
        observed.messages.first { $0.providerMessageId == "immutable-message-1" }?
          .providerStateIds ?? []
      ) == ["INBOX", "UNREAD"])
    #expect(
      observed.messages.first { $0.providerMessageId == "immutable-message-3" }?
        .providerStateIds == [MicrosoftGraphProviderMessage.customFolderStateId("custom")])
  }

  @Test
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
    let connection = try requireValue(loadedConnections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)

    let first = try await adapter.loadMessageBody(message: message, session: session)
    let second = try await adapter.loadMessageBody(message: message, session: session)

    #expect(first.text == "Private body")
    #expect(second == first)
    #expect(client.bodyRequestCount == 1)
    #expect(client.attachmentDescriptorRequestCount == 0)
    #expect(bodyCache.savedMessageIds == [message.stableProviderMessageId])
  }

  @Test
  func testOpeningGraphMessageCachesOnlyDownloadableFileAttachmentDescriptors() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1, hasAttachments: true)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    client.bodies["immutable-message-1"] = "Private body"
    client.attachmentDescriptors["immutable-message-1"] = [
      graphAttachment(id: "file-1", kind: .file),
      graphAttachment(id: "inline-1", kind: .inlineImage),
      graphAttachment(id: "item-1", kind: .unsupportedItem),
    ]
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let bodyCache = RecordingMicrosoftGraphBodyCache()
    let adapter = try authorizedAdapter(
      bodyCache: bodyCache,
      client: client,
      keyMaterialStore: keyStore
    )
    let loadedConnections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(loadedConnections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)

    let first = try await adapter.loadMessageBody(message: message, session: session)
    client.attachmentDescriptors["immutable-message-1"] = []
    let second = try await adapter.loadMessageBody(message: message, session: session)

    #expect(first.attachments.map(\.id) == ["file-1"])
    #expect(second == first)
    #expect(client.bodyRequestCount == 1)
    #expect(client.attachmentDescriptorRequestCount == 1)
    #expect(bodyCache.savedMessageIds == [message.stableProviderMessageId])
  }

  @Test
  func testGraphAttachmentDownloadKeepsImmutableMessageAndAttachmentIdentity() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1, hasAttachments: true)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    client.bodies["immutable-message-1"] = "Private body"
    client.attachmentDescriptors["immutable-message-1"] = [
      graphAttachment(id: "file-1", kind: .file)
    ]
    client.attachmentData["file-1"] = Data("PDF".utf8)
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let adapter = try authorizedAdapter(client: client, keyMaterialStore: keyStore)
    let loadedConnections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(loadedConnections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)
    let body = try await adapter.loadMessageBody(message: message, session: session)
    let attachment = try requireValue(body.attachments.first)

    let data = try await adapter.loadMessageAttachment(
      attachment,
      message: message,
      session: session
    )

    #expect(data == Data("PDF".utf8))
    #expect(client.attachmentRequests.count == 1)
    #expect(client.attachmentRequests.first?.messageId == "immutable-message-1")
    #expect(client.attachmentRequests.first?.attachmentId == "file-1")
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testGraphCalendarFileAttachmentLoadsOnlyAfterExplicitCandidateRequest() async throws {
    let invitationData = Data(
      """
      BEGIN:VCALENDAR\r
      METHOD:REQUEST\r
      BEGIN:VEVENT\r
      UID:graph-file-001@example.com\r
      SEQUENCE:4\r
      DTSTART:20260901T150000Z\r
      DTEND:20260901T160000Z\r
      SUMMARY:Graph file invitation\r
      END:VEVENT\r
      END:VCALENDAR\r

      """.utf8
    )
    let invitation = CalendarInvitationDescriptor(
      byteCount: invitationData.count,
      mimeType: "text/calendar",
      providerAttachmentId: "calendar-1",
      providerMessageIdentity: "immutable-message-1",
      providerPartId: "calendar-1"
    )
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1, calendarInvitation: invitation, hasAttachments: true)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    client.attachmentDescriptors["immutable-message-1"] = [
      graphAttachment(
        id: "calendar-1",
        kind: .file,
        byteCount: invitationData.count,
        filename: "invite.ics",
        mimeType: "text/calendar"
      )
    ]
    client.attachmentData["calendar-1"] = invitationData
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let inboxPage = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inboxPage.messages.first)

    #expect(client.attachmentDescriptorRequestCount == 0)
    #expect(client.attachmentRequests.isEmpty)
    #expect(client.bodyRequestCount == 0)
    let candidate = try await adapter.loadCalendarInvitationCandidate(
      invitation,
      message: message,
      session: session
    )

    #expect(candidate.uid == "graph-file-001@example.com")
    #expect(candidate.sequence == 4)
    #expect(client.attachmentDescriptorRequestCount == 1)
    #expect(client.attachmentRequests.first?.messageId == "immutable-message-1")
    #expect(client.attachmentRequests.first?.attachmentId == "calendar-1")
    #expect(
      client.attachmentRequests.first?.maximumByteCount
        == CalendarInvitationDescriptor.maximumByteCount
    )
    #expect(client.bodyRequestCount == 0)

    client.attachmentDescriptors["immutable-message-1"] = [
      graphAttachment(
        id: "calendar-1",
        kind: .file,
        byteCount: invitationData.count + 1,
        filename: "invite.ics",
        mimeType: "text/calendar"
      )
    ]
    await #expect(throws: CalendarInvitationParsingError.invalidInvitation) {
      try await adapter.loadCalendarInvitationCandidate(
        invitation,
        message: message,
        session: session
      )
    }
    #expect(client.attachmentRequests.count == 1)
  }

  @Test
  func testGraphEventMessageLoadsTheSharedCandidateWithoutBodyOrAttachmentBytes() async throws {
    let invitation = CalendarInvitationDescriptor(
      byteCount: 0,
      mimeType: "application/vnd.microsoft.graph.event-message",
      providerAttachmentId: nil,
      providerMessageIdentity: "immutable-message-1",
      providerPartId: "microsoft-graph:event-message"
    )
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1, calendarInvitation: invitation)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    client.eventCandidates["immutable-message-1"] = try CalendarInvitationParser.parse(
      Data(
        """
        BEGIN:VCALENDAR\r
        METHOD:CANCEL\r
        BEGIN:VEVENT\r
        UID:graph-event-001@example.com\r
        SEQUENCE:6\r
        SUMMARY:Cancelled Graph event\r
        END:VEVENT\r
        END:VCALENDAR\r

        """.utf8
      )
    )
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let inboxPage = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inboxPage.messages.first)

    let candidate = try await adapter.loadCalendarInvitationCandidate(
      invitation,
      message: message,
      session: session
    )

    #expect(candidate.method == .cancel)
    #expect(candidate.uid == "graph-event-001@example.com")
    #expect(client.eventCandidateRequests == ["immutable-message-1"])
    #expect(client.attachmentDescriptorRequestCount == 0)
    #expect(client.attachmentRequests.isEmpty)
    #expect(client.bodyRequestCount == 0)
  }

  @Test
  func testGraphAttachmentDownloadDoesNotBlockConnectionCleanup() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1, hasAttachments: true)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    client.bodies["immutable-message-1"] = "Private body"
    client.attachmentDescriptors["immutable-message-1"] = [
      graphAttachment(id: "file-1", kind: .file)
    ]
    client.attachmentData["file-1"] = Data("PDF".utf8)
    let providerGate = TestRendezvous()
    client.beforeAttachmentDataReturn = {
      await providerGate.hold()
    }
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let adapter = try authorizedAdapter(client: client, keyMaterialStore: keyStore)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)
    let body = try await adapter.loadMessageBody(message: message, session: session)
    let attachment = try requireValue(body.attachments.first)

    let download = Task {
      try await adapter.loadMessageAttachment(
        attachment,
        message: message,
        session: session
      )
    }
    await providerGate.waitUntilHeld()
    let cleanupFinished = TestFlag()
    let cleanup = Task {
      try await adapter.clearLocalConnection(connection, session: session)
      await cleanupFinished.set()
    }
    await cleanupFinished.waitUntilSet()

    let cleanupDidFinish = await cleanupFinished.value
    #expect(cleanupDidFinish)
    await providerGate.release()
    let downloadedData = try await download.value
    #expect(downloadedData == Data("PDF".utf8))
    try await cleanup.value
  }

  @Test
  func testGraphAttachmentDownloadFailureKeepsBodyReadableAndRetryable() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1, hasAttachments: true)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    client.bodies["immutable-message-1"] = "Private body"
    client.attachmentDescriptors["immutable-message-1"] = [
      graphAttachment(id: "file-1", kind: .file)
    ]
    client.attachmentData["file-1"] = Data("PDF".utf8)
    client.attachmentDataErrors = [URLError(.cannotConnectToHost)]
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let adapter = try authorizedAdapter(client: client, keyMaterialStore: keyStore)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)
    let body = try await adapter.loadMessageBody(message: message, session: session)
    let attachment = try requireValue(body.attachments.first)

    do {
      _ = try await adapter.loadMessageAttachment(
        attachment,
        message: message,
        session: session
      )
      Issue.record("Expected the first attachment download to fail")
    } catch is URLError {
    }
    let cachedBody = try await adapter.loadMessageBody(message: message, session: session)
    let retriedData = try await adapter.loadMessageAttachment(
      attachment,
      message: message,
      session: session
    )
    #expect(cachedBody == body)
    #expect(retriedData == Data("PDF".utf8))
    #expect(client.attachmentRequests.count == 2)
    #expect(client.bodyRequestCount == 1)
  }

  @Test
  func testGraphAttachmentDescriptorFailureKeepsBodyReadableAndRetryable() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1, hasAttachments: true)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    client.bodies["immutable-message-1"] = "Private body"
    client.attachmentDescriptorErrors = [URLError(.cannotConnectToHost)]
    client.attachmentDescriptors["immutable-message-1"] = [
      graphAttachment(id: "file-1", kind: .file)
    ]
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let adapter = try authorizedAdapter(client: client, keyMaterialStore: keyStore)
    let loadedConnections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(loadedConnections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)

    let first = try await adapter.loadMessageBody(message: message, session: session)
    let retried = try await adapter.loadMessageBody(message: message, session: session)

    #expect(first.text == "Private body")
    #expect(first.attachments.isEmpty)
    #expect(retried.attachments.map(\.id) == ["file-1"])
    #expect(client.attachmentDescriptorRequestCount == 2)
    #expect(client.bodyRequestCount == 2)
  }

  @Test
  func testGraphAttachmentDescriptorURLCancellationPropagates() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1, hasAttachments: true)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    client.bodies["immutable-message-1"] = "Private body"
    client.attachmentDescriptorErrors = [URLError(.cancelled)]
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let bodyCache = RecordingMicrosoftGraphBodyCache()
    let adapter = try authorizedAdapter(
      bodyCache: bodyCache,
      client: client,
      keyMaterialStore: keyStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)

    do {
      _ = try await adapter.loadMessageBody(message: message, session: session)
      Issue.record("Expected attachment descriptor cancellation to propagate")
    } catch is CancellationError {
    }
    #expect(bodyCache.savedMessageIds.isEmpty)
  }

  @Test
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
        grantedScopes: fullGraphMailScopes,
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
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)
    _ = try await adapter.loadMessageBody(message: message, session: session)
    definitions.definitions = []
    definitions.removedConnectionIds = [connection.id]

    do {
      _ = try await adapter.loadMessageBody(message: message, session: session)
      Issue.record("Expected a removal tombstone to reject the cached body")
    } catch {
      #expect(error as? MailboxConnectionAdapterError == .connectionRemoved)
    }

    #expect(bodyCache.payloads[message.stableProviderMessageId] == nil)
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: graphAccount.id
      ) == nil)
  }

  @Test
  func testCachedBodyReadRejectsStaleAuthorizationGenerationAndClearsLocalCache()
    async throws
  {
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
        grantedScopes: fullGraphMailScopes,
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
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)
    _ = try await adapter.loadMessageBody(message: message, session: session)
    definitions.definitions = [graphConnectionDefinition.withAuthorizationGeneration(1)]

    do {
      _ = try await adapter.loadMessageBody(message: message, session: session)
      Issue.record("Expected stale authorization to reject the cached body")
    } catch {
      #expect(error as? MailboxConnectionAdapterError == .authorizationRequired)
    }

    #expect(bodyCache.payloads[message.stableProviderMessageId] == nil)
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: graphAccount.id
      ) == nil)
  }

  @Test
  func testCategoryOverrideSurvivesMetadataRecoveryThroughProductSync() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [
        graphMessage(
          1,
          internetMessageHeaders: [
            MicrosoftGraphInternetMessageHeader(
              name: "List-ID",
              value: "Product News <news.example.com>"
            ),
            MicrosoftGraphInternetMessageHeader(
              name: "List-Unsubscribe",
              value: "<https://lists.example.com/unsubscribe>"
            ),
          ]
        )
      ],
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
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)

    let overridden = try await adapter.overrideCategory(
      "system:invoices",
      for: message,
      session: session
    )
    try store.clear(productAccountId: session.productAccountId, connectionId: connection.id)
    let recovered = try await adapter.syncInbox(connection: connection, session: session)

    #expect(overridden.categoryId == "system:invoices")
    #expect(assignmentSync.savedUserOverrides.count == 1)
    #expect(recovered.messages.first?.categoryId == "system:invoices")
    #expect(
      recovered.messages.first?.unsubscribeSuggestion?.mailingListIdentity.rawValue
        == "list-id:news.example.com"
    )
  }

  @Test
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
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    let requestCount = client.requestedContinuations.count

    let paused = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    #expect(!(paused.historicalMetadataBackfillIsComplete))
    #expect(client.requestedContinuations.count == requestCount)
  }

  @Test
  func testSentMessagesUseTheirSentTimestampForMetadata() {
    let sentDate = "2026-06-01T12:00:00Z"
    let message = MicrosoftGraphProviderMessage(
      ccRecipients: [],
      conversationId: "conversation-1",
      from: "sender@example.com",
      hasAttachments: true,
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

    #expect(
      metadata?.providerInternalDateMilliseconds
        == Int64(ISO8601DateFormatter().date(from: sentDate)!.timeIntervalSince1970 * 1_000))
    #expect(metadata?.hasAttachments == true)
  }

  @Test
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
    let connection = try requireValue(firstConnections.first)
    _ = try await firstAdapter.syncInbox(connection: connection, session: session)

    let reopenedStore = SwiftDataMicrosoftGraphMetadataStore()
    let reopenedAdapter = try authorizedAdapter(client: client, store: reopenedStore)
    let reopened = try await reopenedAdapter.loadInbox(
      connection: connection,
      session: session
    )

    #expect(reopened.messages.map(\.providerMessageId) == ["immutable-message-1"])
    #expect(reopened.hasInitialMailboxAvailability)
    #expect(reopened.historicalMetadataBackfillIsComplete)
  }

  @Test
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
        grantedScopes: fullGraphMailScopes,
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
    let connection = try requireValue(loadedConnections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)

    #expect(authorizer.refreshedTokens == 1)
    #expect(client.accessTokens.last == authorizer.refreshResult.accessToken)
  }

  @Test
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
        grantedScopes: fullGraphMailScopes,
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
    let connection = try requireValue(connections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)

    #expect(authorizer.refreshedTokens == 1)
    #expect(client.accessTokens.last == authorizer.refreshResult.accessToken)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testRejectedAccessTokenDoesNotRefreshAfterAuthorizationGenerationAdvances()
    async throws
  {
    let authorizer = RecordingMicrosoftGraphAuthorizer()
    let client = RecordingMicrosoftGraphClient()
    client.rejectedAccessTokens = ["access-token"]
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    let definitions = RecordingMicrosoftGraphDefinitionSyncService(
      definitions: [graphConnectionDefinition]
    )
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "access-token",
        expiresAtMilliseconds: 4_000_000_000_000,
        grantedScopes: fullGraphMailScopes,
        refreshToken: "refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    client.onRejectedAccessToken = {
      definitions.definitions = [graphConnectionDefinition.withAuthorizationGeneration(1)]
      try tokenStore.save(
        MicrosoftGraphTokens(
          accessToken: "replacement-token",
          authorizationGeneration: 1,
          expiresAtMilliseconds: 4_000_000_000_000,
          grantedScopes: fullGraphMailScopes,
          refreshToken: "replacement-refresh-token"
        ),
        productAccountId: self.session.productAccountId,
        providerAccountIdentifier: graphAccount.id
      )
    }
    let adapter = try makeAdapter(
      authorizer: authorizer,
      client: client,
      definitions: definitions,
      tokenStore: tokenStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    do {
      _ = try await adapter.syncInbox(connection: connection, session: session)
      Issue.record("Expected authorization to be required")
    } catch {
      #expect(error as? MailboxConnectionAdapterError == .authorizationRequired)
    }
    #expect(authorizer.refreshedTokens == 0)
    #expect(client.accessTokens == ["access-token"])
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: graphAccount.id
      )?.accessToken == "replacement-token")
  }

  @Test
  func testWrappedSendUnauthorizedErrorRefreshesAndRetries() async throws {
    let authorizer = RecordingMicrosoftGraphAuthorizer()
    let client = RecordingMicrosoftGraphClient()
    client.sendErrors = [
      MicrosoftGraphSendError(
        stage: .preparation,
        underlyingError: MicrosoftGraphClientError.requestFailed(401)
      )
    ]
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "access-token",
        expiresAtMilliseconds: 4_000_000_000_000,
        grantedScopes: fullGraphMailScopes,
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
    let connection = try requireValue(connections.first)
    let message = OutgoingMessage(
      body: "Body",
      recipient: "recipient@example.com",
      subject: "Subject",
      idempotencyKey: "wrapped-401"
    )

    try await adapter.send(message, connection: connection, session: session)

    #expect(authorizer.refreshedTokens == 1)
    #expect(client.accessTokens == ["access-token", authorizer.refreshResult.accessToken])
    #expect(client.sentMessages == [message])
  }

  @Test
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
        grantedScopes: fullGraphMailScopes,
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
    let connection = try requireValue(connections.first)

    do {
      _ = try await adapter.syncInbox(connection: connection, session: session)
      Issue.record("Expected authorization to be required")
    } catch {
      #expect(error as? MailboxConnectionAdapterError == .authorizationRequired)
    }
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: graphAccount.id
      ) == nil)
  }

  @Test
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
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)

    try await adapter.prefetchMessageBodies(
      connection: connection,
      pinnedThreadIds: [],
      referenceDate: Date(timeIntervalSince1970: 1_781_200_100),
      session: session
    )

    #expect(bodyCache.savedMessageIds == inbox.messages.map(\.stableProviderMessageId))
  }

  @Test
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
          grantedScopes: fullGraphMailScopes,
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

    #expect(connections.count == 2)
    #expect(Set(connections.map(\.id.providerId)) == [.microsoftGraph])
    #expect(MailboxThread.group(messages).count == 2)
    #expect(
      connections[0].id
        != MailboxConnectionId(
          providerMailboxIdentity: StableProviderMailboxIdentity(
            providerId: .gmail,
            value: connections[0].providerMailboxIdentity.value
          )
        ))

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
      #expect(actionError == nil)
    }
    #expect(client.readUpdates.count == 2)
    #expect(
      Set(client.accessTokens) == ["access-\(graphAccount.id)", "access-\(secondAccount.id)"])
  }

  @Test
  func testCancellationDoesNotCommitAPartialPage() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.error = CancellationError()
    let store = try SwiftDataMicrosoftGraphMetadataStore.inMemory()
    let adapter = try authorizedAdapter(client: client, store: store)
    let loadedConnections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(loadedConnections.first)

    do {
      _ = try await adapter.syncInbox(connection: connection, session: session)
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    }

    #expect(
      try store.loadState(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ) == nil)
    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ) == [])
  }

  @Test
  func testStaleInitialSyncDoesNotCommitCursorBeforeSnapshotAndCanRetry() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages["inbox-id|recent-delta"] = MicrosoftGraphMetadataPage(
      messages: [],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/recent-delta")
    )
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
    let connection = try requireValue(connections.first)

    do {
      _ = try await adapter.syncRecentInbox(
        connection: connection,
        includingHistoryCandidates: false,
        session: session,
        sinceHistoryId: nil,
        throughHistoryId: nil,
        shouldPersist: { shouldPersist }
      )
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    }

    #expect(
      try store.loadState(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ) == nil)

    client.metadataPageDidLoad = nil
    shouldPersist = true
    let retried = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: false,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { shouldPersist }
    )

    #expect(retried.hasInitialMailboxAvailability)
    #expect(retried.messages.contains { $0.providerMessageId == "immutable-message-1" })
  }

  @Test
  func testPushRegistrationRoutesOnlyOpaqueMetadataAndCoalescesRenewal() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let defaultsName = "MicrosoftGraphPushRegistrationTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
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

    #expect(routeTransport.prepared.count == 1)
    #expect(routeTransport.prepared.first?.identityToken == session.identityToken)
    #expect(!(routeTransport.prepared.first?.clientStateDigest.isEmpty ?? true))
    #expect(!(routeTransport.prepared.first?.opaqueConnectionId.contains(graphAccount.id) ?? true))
    #expect(subscriptionClient.created.count == 1)
    #expect(subscriptionClient.created.first?.accessToken == "provider-access-token")
    #expect(
      subscriptionClient.created.first?.notificationURL.absoluteString
        == "https://deployment.convex.site/microsoft-graph/push?routeId=graph-route-1")
    #expect(routeTransport.confirmed.count == 1)
    #expect(
      routeTransport.confirmed.first?.clientStateDigest
        == routeTransport.prepared.first?.clientStateDigest)
  }

  @Test
  func testConcurrentPushRegistrationSerializesTheWholeOperation() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let defaultsName = "MicrosoftGraphConcurrentPushRegistrationTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let routeTransport = RecordingMicrosoftGraphPushRouteTransport()
    let subscriptionClient = RecordingMicrosoftGraphSubscriptionClient()
    subscriptionClient.createDelayNanoseconds = 50_000_000
    let service = MicrosoftGraphPushSubscriptionService(
      now: { Date(timeIntervalSince1970: 2_000_000_000) },
      siteURL: URL(string: "https://deployment.convex.site"),
      statusStore: UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults),
      subscriptionClient: subscriptionClient,
      transport: routeTransport
    )

    async let first: Void = service.registerOrRenew(
      connection: connection,
      accessToken: "provider-access-token",
      session: session
    )
    async let second: Void = service.registerOrRenew(
      connection: connection,
      accessToken: "provider-access-token",
      session: session
    )
    _ = try await (first, second)

    #expect(routeTransport.prepared.count == 1)
    #expect(subscriptionClient.created.count == 1)
    #expect(routeTransport.confirmed.count == 1)
  }

  @Test
  func testPushCleanupWaitsForInitialRegistration() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let defaultsName = "MicrosoftGraphConcurrentPushCleanupTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let routeTransport = RecordingMicrosoftGraphPushRouteTransport()
    let subscriptionClient = RecordingMicrosoftGraphSubscriptionClient()
    subscriptionClient.createDelayNanoseconds = 50_000_000
    let statusStore = UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults)
    let service = MicrosoftGraphPushSubscriptionService(
      siteURL: URL(string: "https://deployment.convex.site"),
      statusStore: statusStore,
      subscriptionClient: subscriptionClient,
      transport: routeTransport
    )

    async let registration: Void = service.registerOrRenew(
      connection: connection,
      accessToken: "provider-access-token",
      session: session
    )
    while subscriptionClient.createStartedCount == 0 {
      await Task.yield()
    }
    async let cleanup: Void = service.clearAll(
      accessTokensByProviderAccountIdentifier: [
        connection.providerMailboxIdentity.value: "provider-access-token"
      ],
      session: session
    )
    _ = try await (registration, cleanup)

    #expect(subscriptionClient.deletedSubscriptionIds == ["subscription-1"])
    #expect(routeTransport.removedOpaqueConnectionIds.count == 1)
    #expect(
      try statusStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerMailboxIdentity.value
      ) == nil)
  }

  @Test
  func testPushRegistrationRecoversFromCorruptLocalStatus() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let defaultsName = "MicrosoftGraphCorruptPushRegistrationTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let key = "microsoft-graph-push.\(session.productAccountId)"
    defaults.set(Data("not-json".utf8), forKey: key)
    let statusStore = UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults)
    let subscriptionClient = RecordingMicrosoftGraphSubscriptionClient()
    let service = MicrosoftGraphPushSubscriptionService(
      siteURL: URL(string: "https://deployment.convex.site"),
      statusStore: statusStore,
      subscriptionClient: subscriptionClient,
      transport: RecordingMicrosoftGraphPushRouteTransport()
    )

    try await service.registerOrRenew(
      connection: connection,
      accessToken: "provider-access-token",
      session: session
    )

    #expect(subscriptionClient.created.count == 1)
    #expect(
      try statusStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerMailboxIdentity.value
      ) != nil)
  }

  @Test
  func testForegroundMailboxSyncRenewsPushWithoutWaitingForNotification() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    let push = RecordingMicrosoftGraphPushRegistrar()
    let adapter = try authorizedAdapter(client: client, pushRegistrar: push)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)

    #expect(push.registeredConnectionIds == [connection.id])
    #expect(push.accessTokens == ["access-token"])
  }

  @Test
  func testGraphWakeupSynchronizesWhenPushRenewalFails() async throws {
    let client = RecordingMicrosoftGraphClient()
    client.folders = [graphFolder(id: "inbox-id", wellKnownName: "inbox")]
    client.pages[pageKey(folderId: "inbox-id")] = MicrosoftGraphMetadataPage(
      messages: [graphMessage(1)],
      nextLink: nil,
      deltaLink: URL(string: "https://graph.microsoft.test/inbox/delta")
    )
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let defaultsName = "MicrosoftGraphPushWakeupTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let statusStore = UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults)
    try statusStore.save(
      MicrosoftGraphPushStatus(
        expiresAtMilliseconds: 4_000_000_000_000,
        opaqueConnectionId: "opaque-id",
        providerAccountIdentifier: connection.providerMailboxIdentity.value,
        routeId: "route-id",
        subscriptionId: "subscription-id"
      ),
      productAccountId: session.productAccountId
    )
    let push = RecordingMailboxPushService()
    push.error = URLError(.networkConnectionLost)
    let handler = MicrosoftGraphPushWakeupHandler(
      connectionManager: adapter,
      pushService: push,
      sessionStore: sessionStore,
      statusStore: statusStore,
      successStore: UserDefaultsMailboxSyncSuccessStore(defaults: defaults),
      syncService: adapter
    )

    let handled = try await handler.handle(
      userInfo: [
        "provider": MailProviderId.microsoftGraph.rawValue,
        "routeId": "route-id",
      ]
    )

    #expect(handled)
    #expect(push.connectionIds == [connection.id])
  }

  @Test
  func testGraphWakeupStopsBeforeProviderAccessWhenTrustRevalidationFails() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let push = RecordingMailboxPushService()
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let defaultsName = "MicrosoftGraphRevokedWakeupTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let statusStore = UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults)
    try statusStore.save(
      MicrosoftGraphPushStatus(
        expiresAtMilliseconds: 4_000_000_000_000,
        opaqueConnectionId: "opaque-id",
        providerAccountIdentifier: connection.providerMailboxIdentity.value,
        routeId: "route-id",
        subscriptionId: "subscription-id"
      ),
      productAccountId: session.productAccountId
    )
    var revalidatedSessions: [ProductAccountSessionSnapshot] = []
    let handler = MicrosoftGraphPushWakeupHandler(
      connectionManager: adapter,
      pushService: push,
      revalidateTrustedDevice: {
        revalidatedSessions.append($0)
        return false
      },
      sessionStore: sessionStore,
      statusStore: statusStore,
      syncService: adapter
    )

    let handled = try await handler.handle(
      userInfo: [
        "provider": MailProviderId.microsoftGraph.rawValue,
        "routeId": "route-id",
      ]
    )

    #expect(!(handled))
    #expect(revalidatedSessions == [session])
    #expect(push.connectionIds.isEmpty)
    #expect(client.accessTokens.isEmpty)
  }

  @Test
  func testBackgroundFetchRenewsQuietGraphMailboxInsideRenewalWindow() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let defaultsName = "MicrosoftGraphBackgroundRenewalTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let statusStore = UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    try statusStore.save(
      MicrosoftGraphPushStatus(
        expiresAtMilliseconds: Int64(now.addingTimeInterval(60 * 60).timeIntervalSince1970 * 1_000),
        opaqueConnectionId: "opaque-id",
        providerAccountIdentifier: connection.providerMailboxIdentity.value,
        routeId: "route-id",
        subscriptionId: "subscription-id"
      ),
      productAccountId: session.productAccountId
    )
    let push = RecordingMailboxPushService()
    let handler = MicrosoftGraphPushRenewalHandler(
      connectionManager: adapter,
      now: { now },
      pushService: push,
      sessionStore: sessionStore,
      statusStore: statusStore
    )

    let renewed = try await handler.handle()

    #expect(renewed)
    #expect(push.connectionIds == [connection.id])
  }

  @Test
  func testBackgroundFetchStopsBeforeProviderAccessWhenTrustRevalidationFails() async throws {
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let push = RecordingMailboxPushService()
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let defaultsName = "MicrosoftGraphRevokedRenewalTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let statusStore = UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    try statusStore.save(
      MicrosoftGraphPushStatus(
        expiresAtMilliseconds: Int64(now.addingTimeInterval(60 * 60).timeIntervalSince1970 * 1_000),
        opaqueConnectionId: "opaque-id",
        providerAccountIdentifier: connection.providerMailboxIdentity.value,
        routeId: "route-id",
        subscriptionId: "subscription-id"
      ),
      productAccountId: session.productAccountId
    )
    var revalidatedSessions: [ProductAccountSessionSnapshot] = []
    let handler = MicrosoftGraphPushRenewalHandler(
      connectionManager: adapter,
      now: { now },
      pushService: push,
      revalidateTrustedDevice: {
        revalidatedSessions.append($0)
        return false
      },
      sessionStore: sessionStore,
      statusStore: statusStore
    )

    let renewed = try await handler.handle()

    #expect(!(renewed))
    #expect(revalidatedSessions == [session])
    #expect(push.connectionIds.isEmpty)
    #expect(client.accessTokens.isEmpty)
  }

  @Test
  func testBackgroundFetchSkipsFreshGraphSubscription() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let defaultsName = "MicrosoftGraphFreshBackgroundRenewalTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let statusStore = UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    try statusStore.save(
      MicrosoftGraphPushStatus(
        expiresAtMilliseconds: Int64(
          now.addingTimeInterval(2 * 24 * 60 * 60).timeIntervalSince1970 * 1_000
        ),
        opaqueConnectionId: "opaque-id",
        providerAccountIdentifier: connection.providerMailboxIdentity.value,
        routeId: "route-id",
        subscriptionId: "subscription-id"
      ),
      productAccountId: session.productAccountId
    )
    let push = RecordingMailboxPushService()
    let handler = MicrosoftGraphPushRenewalHandler(
      connectionManager: adapter,
      now: { now },
      pushService: push,
      sessionStore: sessionStore,
      statusStore: statusStore
    )

    let renewed = try await handler.handle()

    #expect(!(renewed))
    #expect(push.connectionIds.isEmpty)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testBackgroundFetchStopsRenewingAfterCancellation() async throws {
    let secondAccount = MicrosoftGraphAccount(
      displayName: "Second Graph Reader",
      emailAddress: "second@example.com",
      id: "graph-user-002"
    )
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    for account in [graphAccount, secondAccount] {
      try tokenStore.save(
        MicrosoftGraphTokens(
          accessToken: "access-\(account.id)",
          expiresAtMilliseconds: 4_000_000_000_000,
          grantedScopes: fullGraphMailScopes,
          refreshToken: "refresh-\(account.id)"
        ),
        productAccountId: session.productAccountId,
        providerAccountIdentifier: account.id
      )
    }
    let adapter = try makeAdapter(
      client: RecordingMicrosoftGraphClient(),
      definitions: RecordingMicrosoftGraphDefinitionSyncService(
        definitions: [
          graphConnectionDefinition,
          makeGraphConnectionDefinition(account: secondAccount),
        ]
      ),
      tokenStore: tokenStore
    )
    let sessionStore = InMemoryProductAccountSessionStore()
    try sessionStore.save(session)
    let push = RecordingMailboxPushService()
    let renewalStarted = expectation(description: "First renewal started")
    var resumeRenewal: CheckedContinuation<Void, Never>?
    push.beforeReturn = {
      renewalStarted.fulfill()
      await withCheckedContinuation { resumeRenewal = $0 }
    }
    let defaultsName = "MicrosoftGraphCancelledBackgroundRenewalTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let handler = MicrosoftGraphPushRenewalHandler(
      connectionManager: adapter,
      pushService: push,
      sessionStore: sessionStore,
      statusStore: UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults)
    )

    let renewalTask = Task {
      try await handler.handle()
    }
    await fulfillment(of: [renewalStarted])
    renewalTask.cancel()
    resumeRenewal?.resume()
    do {
      _ = try await renewalTask.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    }

    #expect(push.connectionIds.count == 1)
  }

  @Test
  func testPushRegistrationDeletesNewSubscriptionWhenConfirmationFails() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let routeTransport = RecordingMicrosoftGraphPushRouteTransport()
    routeTransport.confirmError = URLError(.cannotConnectToHost)
    let subscriptionClient = RecordingMicrosoftGraphSubscriptionClient()
    let defaultsName = "MicrosoftGraphPushRollbackTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let service = MicrosoftGraphPushSubscriptionService(
      siteURL: URL(string: "https://deployment.convex.site"),
      statusStore: UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults),
      subscriptionClient: subscriptionClient,
      transport: routeTransport
    )

    do {
      try await service.registerOrRenew(
        connection: connection,
        accessToken: "provider-access-token",
        session: session
      )
      Issue.record("Expected route confirmation failure")
    } catch {}

    #expect(subscriptionClient.deletedSubscriptionIds == ["subscription-1"])
    #expect(subscriptionClient.deleteAccessTokens == ["provider-access-token"])
    #expect(
      routeTransport.rolledBackClientStateDigests == [
        try requireValue(routeTransport.prepared.first?.clientStateDigest)
      ])
  }

  @Test
  func testPushRegistrationPreservesSubscriptionWhenConfirmationRollbackIsRejected()
    async throws
  {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let routeTransport = RecordingMicrosoftGraphPushRouteTransport()
    routeTransport.confirmError = URLError(.networkConnectionLost)
    routeTransport.rollbackResult = false
    let subscriptionClient = RecordingMicrosoftGraphSubscriptionClient()
    let defaultsName = "MicrosoftGraphPushAmbiguousConfirmationTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let service = MicrosoftGraphPushSubscriptionService(
      siteURL: URL(string: "https://deployment.convex.site"),
      statusStore: UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults),
      subscriptionClient: subscriptionClient,
      transport: routeTransport
    )

    do {
      try await service.registerOrRenew(
        connection: connection,
        accessToken: "provider-access-token",
        session: session
      )
      Issue.record("Expected route confirmation failure")
    } catch {}

    #expect(routeTransport.rolledBackClientStateDigests.count == 1)
    #expect(subscriptionClient.deletedSubscriptionIds.isEmpty)
  }

  @Test
  func testPushRegistrationRollsBackRouteWhenSubscriptionCreationFails() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let routeTransport = RecordingMicrosoftGraphPushRouteTransport()
    let subscriptionClient = RecordingMicrosoftGraphSubscriptionClient()
    subscriptionClient.createError = URLError(.cannotConnectToHost)
    let defaultsName = "MicrosoftGraphPushPreparationRollbackTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let service = MicrosoftGraphPushSubscriptionService(
      siteURL: URL(string: "https://deployment.convex.site"),
      statusStore: UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults),
      subscriptionClient: subscriptionClient,
      transport: routeTransport
    )

    do {
      try await service.registerOrRenew(
        connection: connection,
        accessToken: "provider-access-token",
        session: session
      )
      Issue.record("Expected subscription creation failure")
    } catch {}

    #expect(
      routeTransport.rolledBackClientStateDigests == [
        try requireValue(routeTransport.prepared.first?.clientStateDigest)
      ])
    #expect(subscriptionClient.deletedSubscriptionIds.isEmpty)
  }

  @Test
  func testPushRegistrationRecreatesAnExpiredProviderSubscription() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let defaultsName = "MicrosoftGraphPushRecreationTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
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

    #expect(subscriptionClient.renewedSubscriptionIds == ["expired-subscription"])
    #expect(routeTransport.removedOpaqueConnectionIds == ["old-opaque-id"])
    #expect(subscriptionClient.created.count == 1)
    #expect(routeTransport.confirmed.last?.subscriptionId == "subscription-1")
  }

  @Test
  func testPushCleanupDeletesProviderSubscriptionBeforeLocalState() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let defaultsName = "MicrosoftGraphPushCleanupTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let statusStore = UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults)
    try statusStore.save(
      MicrosoftGraphPushStatus(
        expiresAtMilliseconds: 4_000_000_000_000,
        opaqueConnectionId: "opaque-id",
        providerAccountIdentifier: connection.providerMailboxIdentity.value,
        routeId: "route-id",
        subscriptionId: "subscription-id"
      ),
      productAccountId: session.productAccountId
    )
    let subscriptionClient = RecordingMicrosoftGraphSubscriptionClient()
    let service = MicrosoftGraphPushSubscriptionService(
      statusStore: statusStore,
      subscriptionClient: subscriptionClient,
      transport: RecordingMicrosoftGraphPushRouteTransport()
    )

    try await service.clear(
      accessToken: "provider-access-token",
      connection: connection,
      session: session
    )

    #expect(subscriptionClient.deletedSubscriptionIds == ["subscription-id"])
    #expect(subscriptionClient.deleteAccessTokens == ["provider-access-token"])
    #expect(
      try statusStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerMailboxIdentity.value
      ) == nil)
  }

  @Test
  func testConnectionCleanupRefreshesExpiredTokenBeforeDeletingSubscription() async throws {
    let authorizer = RecordingMicrosoftGraphAuthorizer()
    let push = RecordingMicrosoftGraphPushRegistrar()
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "expired-token",
        expiresAtMilliseconds: 1,
        grantedScopes: fullGraphMailScopes,
        refreshToken: "refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    let adapter = try makeAdapter(
      authorizer: authorizer,
      client: RecordingMicrosoftGraphClient(),
      definitions: RecordingMicrosoftGraphDefinitionSyncService(
        definitions: [graphConnectionDefinition]
      ),
      now: { Date(timeIntervalSince1970: 2_000_000_000) },
      pushRegistrar: push,
      tokenStore: tokenStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    try await adapter.clearLocalConnection(connection, session: session)

    #expect(authorizer.refreshedTokens == 1)
    #expect(push.clearedAccessTokens == [authorizer.refreshResult.accessToken])
  }

  @Test
  func testAccountCleanupRefreshesExpiredTokensBeforeDeletingSubscriptions() async throws {
    let authorizer = RecordingMicrosoftGraphAuthorizer()
    let push = RecordingMicrosoftGraphPushRegistrar()
    let tokenStore = InMemoryMicrosoftGraphAuthorizationStore()
    try tokenStore.save(
      MicrosoftGraphTokens(
        accessToken: "expired-token",
        expiresAtMilliseconds: 1,
        grantedScopes: fullGraphMailScopes,
        refreshToken: "refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    let adapter = try makeAdapter(
      authorizer: authorizer,
      client: RecordingMicrosoftGraphClient(),
      definitions: RecordingMicrosoftGraphDefinitionSyncService(
        definitions: [graphConnectionDefinition]
      ),
      now: { Date(timeIntervalSince1970: 2_000_000_000) },
      pushRegistrar: push,
      tokenStore: tokenStore
    )

    try await adapter.clearLocalConnection(session: session)

    #expect(authorizer.refreshedTokens == 1)
    #expect(
      push.clearedAllAccessTokens == [[graphAccount.id: authorizer.refreshResult.accessToken]])
  }

  @Test
  func testPushCleanupRemovesRouteAndLocalStateWhenProviderDeletionFails() async throws {
    let client = RecordingMicrosoftGraphClient()
    let adapter = try authorizedAdapter(client: client)
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let defaultsName = "MicrosoftGraphPushFailedCleanupTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let statusStore = UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults)
    try statusStore.save(
      MicrosoftGraphPushStatus(
        expiresAtMilliseconds: 4_000_000_000_000,
        opaqueConnectionId: "opaque-id",
        providerAccountIdentifier: connection.providerMailboxIdentity.value,
        routeId: "route-id",
        subscriptionId: "subscription-id"
      ),
      productAccountId: session.productAccountId
    )
    let routeTransport = RecordingMicrosoftGraphPushRouteTransport()
    let subscriptionClient = RecordingMicrosoftGraphSubscriptionClient()
    subscriptionClient.deleteError = URLError(.networkConnectionLost)
    let service = MicrosoftGraphPushSubscriptionService(
      statusStore: statusStore,
      subscriptionClient: subscriptionClient,
      transport: routeTransport
    )

    do {
      try await service.clear(
        accessToken: "provider-access-token",
        connection: connection,
        session: session
      )
      Issue.record("Expected provider deletion failure")
    } catch {}

    #expect(routeTransport.removedOpaqueConnectionIds == ["opaque-id"])
    #expect(
      try statusStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerMailboxIdentity.value
      ) == nil)
  }

  @Test
  func testPushCleanupClearsCorruptLocalStatus() async throws {
    let defaultsName = "MicrosoftGraphCorruptPushCleanupTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let key = "microsoft-graph-push.\(session.productAccountId)"
    defaults.set(Data("not-json".utf8), forKey: key)
    let routeTransport = RecordingMicrosoftGraphPushRouteTransport()
    let statusStore = UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults)
    let service = MicrosoftGraphPushSubscriptionService(
      statusStore: statusStore,
      subscriptionClient: RecordingMicrosoftGraphSubscriptionClient(),
      transport: routeTransport
    )

    let connection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: .microsoftGraph,
      connectedAt: 1,
      displayName: "provider@example.com",
      id: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .microsoftGraph,
          value: "provider-account"
        )
      ),
      lastVerifiedAt: 1,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1
    )
    try await service.clear(
      accessToken: nil,
      connection: connection,
      session: session
    )

    #expect(
      try statusStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerMailboxIdentity.value
      ) == nil)
    #expect(routeTransport.removedOpaqueConnectionIds.count == 1)
    #expect(routeTransport.removedOpaqueConnectionIds.first?.count == 64)
  }

  @Test
  func testPushCleanupAllRemovesRouteWhenLocalStatusIsCorrupt() async throws {
    let defaultsName = "MicrosoftGraphCorruptPushCleanupAllTests.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    defaults.set(
      Data("not-json".utf8),
      forKey: "microsoft-graph-push.\(session.productAccountId)"
    )
    let routeTransport = RecordingMicrosoftGraphPushRouteTransport()
    let service = MicrosoftGraphPushSubscriptionService(
      statusStore: UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults),
      subscriptionClient: RecordingMicrosoftGraphSubscriptionClient(),
      transport: routeTransport
    )

    try await service.clearAll(
      accessTokensByProviderAccountIdentifier: ["provider-account": "access-token"],
      session: session
    )

    #expect(routeTransport.removedOpaqueConnectionIds.count == 1)
    #expect(routeTransport.removedOpaqueConnectionIds.first?.count == 64)
  }

  @Test
  func testPushCleanupAllTreatsDeletedProductAccountRouteAsRemoved() async throws {
    let defaultsName = "GraphDeletedAccountCleanup.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let statusStore = UserDefaultsMicrosoftGraphPushStatusStore(defaults: defaults)
    try statusStore.save(
      MicrosoftGraphPushStatus(
        clientStateDigest: "digest",
        expiresAtMilliseconds: 4_000_000_000_000,
        opaqueConnectionId: "opaque-connection-id",
        providerAccountIdentifier: graphAccount.id,
        routeId: "route-id",
        subscriptionId: "subscription-id"
      ),
      productAccountId: session.productAccountId
    )
    let routeTransport = RecordingMicrosoftGraphPushRouteTransport()
    routeTransport.removeError = ConvexClientError.convexApplicationFailure(
      status: "error",
      code: "PRODUCT_ACCOUNT_DELETED",
      message: nil
    )
    let service = MicrosoftGraphPushSubscriptionService(
      statusStore: statusStore,
      subscriptionClient: RecordingMicrosoftGraphSubscriptionClient(),
      transport: routeTransport
    )

    try await service.clearAll(
      accessTokensByProviderAccountIdentifier: [:],
      session: session
    )

    #expect(try statusStore.loadAll(productAccountId: session.productAccountId) == [])
  }

  private func authorizedAdapter(
    assignmentSync: MessageCategoryAssignmentSyncing = RecordingGraphCategoryAssignmentSync(),
    authorizer: RecordingMicrosoftGraphAuthorizer? = nil,
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
        grantedScopes: fullGraphMailScopes,
        refreshToken: "refresh-token"
      ),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: graphAccount.id
    )
    return try makeAdapter(
      assignmentSync: assignmentSync,
      authorizer: authorizer,
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
    outboxService: OutboxDeliveryService = OutboxDeliveryService(
      store: InMemoryGraphOutboxDeliveryStore()
    ),
    pendingActionService: PendingProviderActionService = PendingProviderActionService(
      store: InMemoryGraphPendingActionStore()
    ),
    pushRegistrar: MicrosoftGraphPushRegistering = RecordingMicrosoftGraphPushRegistrar(),
    shouldContinueHistoricalBackfill: @escaping () -> Bool = { true },
    syncGate: MailboxConnectionSyncGate = .shared,
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
      outboxService: outboxService,
      pendingActionService: pendingActionService,
      pushRegistrar: pushRegistrar,
      shouldContinueHistoricalBackfill: shouldContinueHistoricalBackfill,
      syncGate: syncGate,
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
  calendarInvitation: CalendarInvitationDescriptor? = nil,
  conversationId: String? = nil,
  folderId: String = "inbox-id",
  hasAttachments: Bool? = nil,
  internetMessageHeaders: [MicrosoftGraphInternetMessageHeader]? = nil,
  isRead: Bool = false,
  removed: Bool = false
) -> MicrosoftGraphProviderMessage {
  MicrosoftGraphProviderMessage(
    calendarInvitation: calendarInvitation,
    ccRecipients: [],
    conversationId: conversationId ?? "conversation-\(number)",
    from: "Sender \(number) <sender\(number)@example.com>",
    hasAttachments: hasAttachments,
    id: "immutable-message-\(number)",
    internetMessageHeaders: internetMessageHeaders,
    internetMessageId: "<message-\(number)@example.com>",
    isRead: isRead,
    parentFolderId: folderId,
    receivedDateTime: ISO8601DateFormatter().string(
      from: Date(timeIntervalSince1970: 1_781_200_000 + Double(number))
    ),
    removed: removed,
    replyTo: [],
    subject: "Message \(number)",
    bodyPreview: "Preview \(number)",
    toRecipients: ["reader@example.com"]
  )
}

private func graphAttachment(
  id: String,
  kind: MicrosoftGraphAttachmentDescriptor.Kind,
  byteCount: Int = 3,
  filename: String = "receipt.pdf",
  mimeType: String = "application/pdf"
) -> MicrosoftGraphAttachmentDescriptor {
  MicrosoftGraphAttachmentDescriptor(
    byteCount: byteCount,
    filename: filename,
    id: id,
    kind: kind,
    mimeType: mimeType
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
    grantedScopes: fullGraphMailScopes,
    refreshToken: "authorized-refresh-token"
  )
  let refreshResult = MicrosoftGraphTokens(
    accessToken: "refreshed-access-token",
    expiresAtMilliseconds: 4_100_000_000_000,
    grantedScopes: fullGraphMailScopes,
    refreshToken: "refreshed-refresh-token"
  )
  var refreshError: Error?
  var refreshErrors: [Error] = []
  var refreshedTokens = 0

  func authorize() async throws -> MicrosoftGraphTokens {
    authorizedTokens
  }

  func refresh(_ tokens: MicrosoftGraphTokens) async throws -> MicrosoftGraphTokens {
    refreshedTokens += 1
    if !refreshErrors.isEmpty {
      throw refreshErrors.removeFirst()
    }
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
  struct AttachmentRequest {
    let messageId: String
    let attachmentId: String
    let expectedByteCount: Int
    let maximumByteCount: Int
  }

  struct Move: Equatable {
    let destinationFolderId: String
    let messageId: String
  }

  var accessTokens: [String] = []
  var account = graphAccount
  var attachmentData: [String: Data] = [:]
  var attachmentDataErrors: [Error] = []
  var attachmentDescriptorErrors: [Error] = []
  var attachmentDescriptorRequestCount = 0
  var attachmentDescriptors: [String: [MicrosoftGraphAttachmentDescriptor]] = [:]
  var attachmentRequests: [AttachmentRequest] = []
  var bodies: [String: String] = [:]
  var bodyRequestCount = 0
  var error: Error?
  var eventCandidates: [String: CalendarInvitationCandidate] = [:]
  var eventCandidateRequests: [String] = []
  var expiredContinuations: Set<String> = []
  var folders: [MicrosoftGraphFolder] = []
  var metadataPageDidLoad: (() -> Void)?
  var metadataError: Error?
  var moveAttempts = 0
  var moveErrors: [Error] = []
  var onRejectedAccessToken: (() throws -> Void)?
  var pages: [String: MicrosoftGraphMetadataPage] = [:]
  var rejectedAccessTokens: Set<String> = []
  var requestedContinuations: [String?] = []
  var requestedRecentDeltaCutoffs: [Int64] = []
  var requestedRecentDeltaFolderIds: [String] = []
  var requestedRecentFolderIds: [String] = []
  var deliveryStatuses: [String: MailboxDeliveryStatus] = [:]
  var deletedDraftIds: [String] = []
  var deleteDraftErrors: [Error] = []
  var moves: [Move] = []
  var readUpdates: [(messageId: String, isRead: Bool)] = []
  var sendErrors: [Error] = []
  var sentMessages: [OutgoingMessage] = []
  var beforeSendReturn: (() async -> Void)?
  var beforeAttachmentDataReturn: (() async -> Void)?

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

  func loadRecentDeltaMetadataPage(
    folder: MicrosoftGraphFolder,
    receivedAfterMilliseconds: Int64,
    pageSize _: Int,
    accessToken: String
  ) async throws -> MicrosoftGraphMetadataPage {
    accessTokens.append(accessToken)
    try validate(accessToken)
    requestedRecentDeltaFolderIds.append(folder.id)
    requestedRecentDeltaCutoffs.append(receivedAfterMilliseconds)
    return pages["\(folder.id)|recent-delta"]
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
    if let metadataError { throw metadataError }
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

  func loadEventMessageCalendarCandidate(
    messageId: String,
    accessToken: String
  ) async throws -> CalendarInvitationCandidate {
    accessTokens.append(accessToken)
    try validate(accessToken)
    eventCandidateRequests.append(messageId)
    guard let candidate = eventCandidates[messageId] else {
      throw MicrosoftGraphClientError.invalidProviderResponse
    }
    return candidate
  }

  func loadAttachmentDescriptors(
    messageId: String,
    accessToken: String
  ) async throws -> [MicrosoftGraphAttachmentDescriptor] {
    accessTokens.append(accessToken)
    try validate(accessToken)
    attachmentDescriptorRequestCount += 1
    if !attachmentDescriptorErrors.isEmpty {
      throw attachmentDescriptorErrors.removeFirst()
    }
    return attachmentDescriptors[messageId] ?? []
  }

  func loadAttachmentData(
    messageId: String,
    attachmentId: String,
    expectedByteCount: Int,
    maximumByteCount: Int,
    accessToken: String
  ) async throws -> Data {
    accessTokens.append(accessToken)
    try validate(accessToken)
    attachmentRequests.append(
      AttachmentRequest(
        messageId: messageId,
        attachmentId: attachmentId,
        expectedByteCount: expectedByteCount,
        maximumByteCount: maximumByteCount
      )
    )
    if !attachmentDataErrors.isEmpty {
      throw attachmentDataErrors.removeFirst()
    }
    await beforeAttachmentDataReturn?()
    let data = attachmentData[attachmentId] ?? Data()
    guard data.count <= maximumByteCount,
      expectedByteCount == 0 || data.count <= expectedByteCount
    else { throw MailboxMessageAttachmentError.invalidResponse }
    return data
  }

  func deleteDraft(_ draftId: String, accessToken: String) async throws {
    accessTokens.append(accessToken)
    try validate(accessToken)
    if !deleteDraftErrors.isEmpty {
      throw deleteDraftErrors.removeFirst()
    }
    deletedDraftIds.append(draftId)
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
    await beforeSendReturn?()
    if !sendErrors.isEmpty {
      throw sendErrors.removeFirst()
    }
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
      try onRejectedAccessToken?()
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

private enum GraphTokenStoreTestError: Error {
  case cannotDecode
}

private final class FailingLoadMicrosoftGraphAuthorizationStore:
  MicrosoftGraphAuthorizationPersisting
{
  private(set) var clearAllCallCount = 0
  private(set) var clearedProviderAccountIdentifiers: [String] = []
  private let storedProviderAccountIdentifiers: Set<String>

  init(providerAccountIdentifiers: Set<String> = []) {
    storedProviderAccountIdentifiers = providerAccountIdentifiers
  }

  func clear(
    productAccountId _: String,
    providerAccountIdentifier: String
  ) throws {
    clearedProviderAccountIdentifiers.append(providerAccountIdentifier)
  }

  func clearAll(productAccountId _: String) throws {
    clearAllCallCount += 1
  }

  func providerAccountIdentifiers(productAccountId _: String) throws -> Set<String> {
    storedProviderAccountIdentifiers
  }

  func load(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> MicrosoftGraphTokens? {
    throw GraphTokenStoreTestError.cannotDecode
  }

  func save(
    _: MicrosoftGraphTokens,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}
}

private final class RecordingMicrosoftGraphPushRegistrar: MicrosoftGraphPushRegistering {
  var accessTokens: [String] = []
  var clearError: Error?
  var clearedAllAccessTokens: [[String: String]] = []
  var clearedAccessTokens: [String?] = []
  var clearedConnectionIds: [MailboxConnectionId] = []
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
    accessToken: String?,
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    clearedAccessTokens.append(accessToken)
    clearedConnectionIds.append(connection.id)
    if let clearError { throw clearError }
  }

  func clearAll(
    accessTokensByProviderAccountIdentifier: [String: String],
    session _: ProductAccountSessionSnapshot
  ) async throws {
    clearedAllAccessTokens.append(accessTokensByProviderAccountIdentifier)
  }
}

private final class RecordingMailboxPushService: MailboxPushRegistering {
  private(set) var connectionIds: [MailboxConnectionId] = []
  var beforeReturn: (() async -> Void)?
  var error: Error?

  func registerOrRenewPush(
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    connectionIds.append(connection.id)
    await beforeReturn?()
    if let error { throw error }
  }
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
    let clientStateDigest: String?
    let expiresAt: Int64
    let routeId: String
    let subscriptionId: String
    let trustedDeviceId: String
  }

  private(set) var confirmed: [ConfirmedCall] = []
  var confirmError: Error?
  private(set) var prepared: [PreparedCall] = []
  var removeError: Error?
  private(set) var removedOpaqueConnectionIds: [String] = []
  var rollbackResult = true
  private(set) var rolledBackClientStateDigests: [String] = []

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
    confirmation: MicrosoftGraphPushRouteConfirmation,
    identityToken _: String,
    trustedDeviceId: String
  ) async throws -> MicrosoftGraphPushRouteResponse {
    confirmed.append(
      ConfirmedCall(
        clientStateDigest: confirmation.clientStateDigest,
        expiresAt: confirmation.expiresAt,
        routeId: confirmation.routeId,
        subscriptionId: confirmation.subscriptionId,
        trustedDeviceId: trustedDeviceId
      )
    )
    if let confirmError { throw confirmError }
    return MicrosoftGraphPushRouteResponse(routeId: confirmation.routeId)
  }

  func removeMicrosoftGraphPushRoute(
    identityToken _: String,
    opaqueConnectionId: String,
    trustedDeviceId _: String
  ) async throws -> Bool {
    removedOpaqueConnectionIds.append(opaqueConnectionId)
    if let removeError { throw removeError }
    return true
  }

  func rollbackMicrosoftGraphPushRoute(
    clientStateDigest: String,
    identityToken _: String,
    routeId _: String,
    trustedDeviceId _: String
  ) async throws -> Bool {
    rolledBackClientStateDigests.append(clientStateDigest)
    return rollbackResult
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
  var createDelayNanoseconds: UInt64 = 0
  var createError: Error?
  private(set) var createStartedCount = 0
  private(set) var deleteAccessTokens: [String] = []
  private(set) var deletedSubscriptionIds: [String] = []
  var deleteError: Error?
  var renewError: Error?
  private(set) var renewedSubscriptionIds: [String] = []

  func create(
    accessToken: String,
    clientState: String,
    expirationDate: Date,
    notificationURL: URL
  ) async throws -> MicrosoftGraphPushStatusProviderResponse {
    createStartedCount += 1
    if createDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: createDelayNanoseconds)
    }
    created.append(
      CreateCall(
        accessToken: accessToken,
        clientState: clientState,
        expirationDate: expirationDate,
        notificationURL: notificationURL
      )
    )
    if let createError { throw createError }
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

  func delete(
    accessToken: String,
    subscriptionId: String
  ) async throws {
    deleteAccessTokens.append(accessToken)
    deletedSubscriptionIds.append(subscriptionId)
    if let deleteError { throw deleteError }
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
    identities _: [FutureLearningSignalIdentity],
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
  var authorizationCleanupConnectionIds: [MailboxConnectionId]
  var completedCleanupGenerations: [MailboxConnectionId: Int] = [:]
  var defaultSendingConnectionId: MailboxConnectionId?
  var definitions: [MailboxConnectionDefinition]
  var localCleanupGenerations: [MailboxConnectionId: Int]
  var removedConnectionIds: [MailboxConnectionId] = []
  var recreatedDefinitionCount = 0
  var recreateError: Error?
  var savedDefinition: MailboxConnectionDefinition?
  var snapshotAfterSave: MailboxConnectionSyncSnapshot?

  init(
    authorizationCleanupConnectionIds: [MailboxConnectionId] = [],
    definitions: [MailboxConnectionDefinition] = [],
    localCleanupGenerations: [MailboxConnectionId: Int] = [:]
  ) {
    self.authorizationCleanupConnectionIds = authorizationCleanupConnectionIds
    self.definitions = definitions
    self.localCleanupGenerations = localCleanupGenerations
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

  func recreateDefinition(
    _ definition: MailboxConnectionDefinition,
    after _: MailboxConnectionRemovalObservation?,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    recreatedDefinitionCount += 1
    if let recreateError { throw recreateError }
    return try await saveDefinition(definition, session: session)
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
    removedConnectionIds.removeAll { $0 == definition.id }
    if let snapshotAfterSave {
      return snapshotAfterSave
    }
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
      updatedAt: 1_781_200_000_000,
      authorizationCleanupConnectionIds: authorizationCleanupConnectionIds,
      localCleanupGenerations: localCleanupGenerations
    )
  }
}

private final class RecordingMicrosoftGraphBodyCache: GmailMessageBodyCaching {
  var connectionClearCount = 0
  var payloads: [String: ProductSyncEncryptedPayload] = [:]
  var savedMessageIds: [String] = []

  func clearMessageBodies(productAccountId _: String) throws {
    payloads = [:]
  }

  func clearMessageBodies(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    connectionClearCount += 1
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

private final class InMemoryGraphOutboxDeliveryStore:
  OutboxDeliveryPersisting, @unchecked Sendable
{
  private var attemptsByProductAccountId: [String: [OutgoingDeliveryAttempt]] = [:]

  func load(productAccountId: String) throws -> [OutgoingDeliveryAttempt] {
    attemptsByProductAccountId[productAccountId] ?? []
  }

  func save(
    _ attempts: [OutgoingDeliveryAttempt],
    productAccountId: String
  ) throws {
    attemptsByProductAccountId[productAccountId] = attempts
  }
}
