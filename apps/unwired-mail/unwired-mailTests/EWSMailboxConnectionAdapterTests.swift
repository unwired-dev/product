import XCTest

@testable import unwired_mail

// swiftlint:disable file_length function_body_length type_body_length

@MainActor
final class EWSMailboxConnectionAdapterTests: XCTestCase {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "product-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  func testSetupAcceptsOnlyHTTPSOnPremisesEndpoints() throws {
    XCTAssertNoThrow(
      try EWSConnectionDefinition.validatedEndpoint(
        "https://mail.corp.example/EWS/Exchange.asmx"
      )
    )

    for endpoint in [
      "http://mail.corp.example/EWS/Exchange.asmx",
      "https://outlook.office365.com/EWS/Exchange.asmx",
      "https://outlook.office.com/EWS/Exchange.asmx",
      "https://outlook.office365.us/EWS/Exchange.asmx",
      "https://partner.outlook.cn/EWS/Exchange.asmx",
    ] {
      XCTAssertThrowsError(try EWSConnectionDefinition.validatedEndpoint(endpoint)) {
        XCTAssertEqual($0 as? EWSSetupError, .onPremisesEndpointRequired)
      }
    }
  }

  func testSetupKeepsAuthorizationDeviceLocalAndSynchronizesOnlyDefinition() async throws {
    let client = RecordingEWSClient()
    let definitions = RecordingEWSDefinitionSyncService()
    let authorizations = InMemoryEWSAuthorizationStore()
    let service = EWSSetupService(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: definitions,
      now: { Date(timeIntervalSince1970: 1_781_200_000) }
    )

    let connection = try await service.connect(
      authorizationMethod: .password,
      credential: " private-password ",
      emailAddress: "reader@corp.example",
      endpoint: "https://mail.corp.example/EWS/Exchange.asmx",
      username: #"CORP\reader"#,
      session: session,
      isSessionCurrent: { $0 == self.session }
    )

    XCTAssertEqual(connection.providerId, .exchangeWebServices)
    XCTAssertEqual(connection.authorizationState, .authorized)
    XCTAssertEqual(connection.capabilities, .exchangeWebServices)
    XCTAssertEqual(client.verifiedAuthorization?.credential, " private-password ")
    XCTAssertEqual(definitions.savedDefinition?.provider, "exchange-web-services")
    XCTAssertEqual(definitions.savedDefinition?.ewsDefinition?.serverVersion, .exchange2019)
    XCTAssertEqual(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )?.credential,
      " private-password "
    )

    let encoded = try JSONEncoder().encode(definitions.savedDefinition)
    XCTAssertFalse(
      (String(bytes: encoded, encoding: .utf8) ?? "").contains("private-password")
    )
  }

  func testSetupAcceptsSupportedVersionsAndAuthorizationMethods() async throws {
    for (index, version) in EWSServerVersion.allCases.enumerated() {
      let method = MailAuthorizationMethod.allCases[index % MailAuthorizationMethod.allCases.count]
      let client = RecordingEWSClient()
      client.account = EWSAccount(
        displayName: "On-Prem Reader",
        primaryEmailAddress: "reader-\(index)@corp.example",
        serverVersion: version
      )
      let definitions = RecordingEWSDefinitionSyncService()
      let service = EWSSetupService(
        authorizationStore: InMemoryEWSAuthorizationStore(),
        client: client,
        definitionSyncService: definitions
      )

      _ = try await service.connect(
        authorizationMethod: method,
        credential: "credential-\(index)",
        emailAddress: "reader-\(index)@corp.example",
        endpoint: "https://mail.corp.example/EWS/Exchange.asmx",
        username: #"CORP\reader"#,
        session: session,
        isSessionCurrent: { $0 == self.session }
      )

      XCTAssertEqual(client.verifiedAuthorization?.definition.authorizationMethod, method)
      XCTAssertEqual(definitions.savedDefinition?.ewsDefinition?.serverVersion, version)
    }
  }

  func testSetupRequiresEveryFullCapabilityMailboxRole() async throws {
    let client = RecordingEWSClient()
    client.folders.removeAll { $0.role == .drafts }
    let service = EWSSetupService(
      authorizationStore: InMemoryEWSAuthorizationStore(),
      client: client,
      definitionSyncService: RecordingEWSDefinitionSyncService()
    )

    do {
      _ = try await service.connect(
        authorizationMethod: .password,
        credential: "password",
        emailAddress: "reader@corp.example",
        endpoint: "https://mail.corp.example/EWS/Exchange.asmx",
        username: #"CORP\reader"#,
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
      XCTFail("Expected setup to reject an incomplete mailbox role mapping")
    } catch {
      XCTAssertEqual(error as? EWSSetupError, .missingRequiredMailboxRole)
    }
  }

  func testSystemClientUsesMailboxScopedRequestAndParsesSupportedServerVersion() async throws {
    let definition = makeEWSDefinition()
    var requests: [URLRequest] = []
    EWSURLProtocol.requestHandler = { request in
      requests.append(request)
      let payload =
        request.value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/ResolveNames") == true
        ? Self.resolveNamesResponse
        : Self.getFolderResponse
      return (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(payload.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }
    let client = SystemEWSClient(session: makeEWSURLSession())
    let authorization = DeviceLocalEWSAuthorization(
      credential: " password ",
      definition: definition
    )

    let account = try await client.verify(authorization)

    XCTAssertEqual(account.serverVersion, .exchange2019)
    XCTAssertEqual(account.primaryEmailAddress, "reader@corp.example")
    XCTAssertEqual(requests.count, 2)
    let expectedAuthorization = Data(#"CORP\reader: password "#.utf8).base64EncodedString()
    XCTAssertEqual(
      requests[0].value(forHTTPHeaderField: "Authorization"), "Basic \(expectedAuthorization)")
    XCTAssertTrue(
      requests[1].value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/GetFolder") == true)
  }

  func testSystemClientRejectsExchangeOnlineVersionBehindCustomEndpoint() async throws {
    EWSURLProtocol.requestHandler = { request in
      let payload =
        request.value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/ResolveNames") == true
        ? Self.resolveNamesResponse.replacingOccurrences(
          of: #"MinorVersion="2""#, with: #"MinorVersion="20""#)
        : Self.getFolderResponse
      return (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(payload.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }
    let authorization = DeviceLocalEWSAuthorization(
      credential: "password",
      definition: makeEWSDefinition()
    )

    do {
      _ = try await SystemEWSClient(session: makeEWSURLSession()).verify(authorization)
      XCTFail("Expected Exchange Online to be rejected")
    } catch {
      XCTAssertEqual(error as? EWSSetupError, .onPremisesEndpointRequired)
    }
  }

  func testSystemClientBuildsOAuthAppPasswordActionAndSendRequests() async throws {
    var requests: [URLRequest] = []
    EWSURLProtocol.requestHandler = { request in
      requests.append(request)
      return (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(Self.successResponse.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }
    let client = SystemEWSClient(session: makeEWSURLSession())
    let oauthDefinition = EWSConnectionDefinition(
      authorizationMethod: .oauth,
      emailAddress: "reader@corp.example",
      endpoint: makeEWSDefinition().endpoint,
      providerAccountIdentifier: "oauth-account",
      serverVersion: .exchange2019,
      username: #"CORP\reader"#
    )
    try await client.perform(
      .markRead,
      targetFolderId: nil,
      messages: [ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")],
      authorization: DeviceLocalEWSAuthorization(
        credential: "oauth-token",
        definition: oauthDefinition
      )
    )
    let appPasswordDefinition = EWSConnectionDefinition(
      authorizationMethod: .appPassword,
      emailAddress: "reader@corp.example",
      endpoint: makeEWSDefinition().endpoint,
      providerAccountIdentifier: "app-password-account",
      serverVersion: .exchange2019,
      username: #"CORP\reader"#
    )
    try await client.send(
      OutgoingMessage(
        body: "Body",
        recipient: "recipient@example.com",
        subject: "Subject",
        idempotencyKey: "ews-send"
      ),
      authorization: DeviceLocalEWSAuthorization(
        credential: "app-password",
        definition: appPasswordDefinition
      )
    )

    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
    let basic = Data(#"CORP\reader:app-password"#.utf8).base64EncodedString()
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Basic \(basic)")
    XCTAssertTrue(
      requests[0].value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/UpdateItem") == true)
    XCTAssertTrue(
      requests[1].value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/CreateItem") == true)
  }

  func testInitialAvailabilityAndBackfillPreserveRolesAndConversationIdentity() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.folders = [
      EWSFolder(changeKey: "inbox-key", displayName: "Inbox", id: "inbox-id", role: .inbox),
      EWSFolder(changeKey: "sent-key", displayName: "Sent Items", id: "sent-id", role: .sent),
    ]
    client.pages["inbox-id|0"] = EWSMessagePage(
      messages: [
        ewsMessage(3, folderId: "inbox-id", conversationId: "conversation-1"),
        ewsMessage(2, folderId: "inbox-id", conversationId: "conversation-1"),
      ],
      nextOffset: 2
    )
    client.pages["sent-id|0"] = EWSMessagePage(
      messages: [
        ewsMessage(20, folderId: "sent-id", conversationId: "conversation-1")
      ],
      nextOffset: nil
    )
    client.pages["inbox-id|2"] = EWSMessagePage(
      messages: [ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-2")],
      nextOffset: nil
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definition: definition.synchronizedDefinition(
          connectedAt: 1_781_200_000_000,
          displayName: "On-Prem Reader"
        )
      ),
      metadataStore: InMemoryEWSMetadataStore()
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    let initial = try await adapter.syncInbox(connection: connection, session: session)
    let sent = try await adapter.loadMailbox(
      .role(.sent),
      connection: connection,
      session: session
    )
    let complete = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    XCTAssertTrue(initial.hasInitialMailboxAvailability)
    XCTAssertFalse(initial.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(initial.messages.map(\.providerMessageId), ["ews-stable-3", "ews-stable-2"])
    XCTAssertEqual(sent.messages.map(\.providerMessageId), ["ews-stable-20"])
    XCTAssertEqual(initial.threads.first?.providerThreadId, "conversation-1")
    XCTAssertTrue(complete.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(
      complete.messages.map(\.providerMessageId),
      [
        "ews-stable-3", "ews-stable-2", "ews-stable-1",
      ])
    XCTAssertEqual(client.requestedPages, ["inbox-id|0", "sent-id|0", "inbox-id|2"])
  }

  func testProviderActionsUseSharedOfflineQueueAndKeepConnectionsIsolated() async throws {
    let firstDefinition = makeEWSDefinition()
    let secondDefinition = EWSConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "other@corp.example",
      endpoint: URL(string: "https://mail.corp.example/EWS/Exchange.asmx")!,
      providerAccountIdentifier: "ews-account-002",
      serverVersion: .exchange2019,
      username: #"CORP\other"#
    )
    let client = RecordingEWSClient()
    client.actionErrorsByConnectionId[firstDefinition.connectionId] = EWSClientTestError.offline
    client.pages["inbox-id|0"] = EWSMessagePage(
      messages: [
        ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1"),
        ewsMessage(2, folderId: "inbox-id", conversationId: "conversation-2"),
      ],
      nextOffset: nil
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "first-password", definition: firstDefinition),
      productAccountId: session.productAccountId
    )
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "second-password", definition: secondDefinition),
      productAccountId: session.productAccountId
    )
    let metadata = InMemoryEWSMetadataStore()
    try metadata.save(
      snapshot(message: ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")),
      productAccountId: session.productAccountId,
      connectionId: firstDefinition.connectionId
    )
    try metadata.save(
      snapshot(message: ewsMessage(2, folderId: "inbox-id", conversationId: "conversation-2")),
      productAccountId: session.productAccountId,
      connectionId: secondDefinition.connectionId
    )
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definitions: [firstDefinition, secondDefinition].map {
          $0.synchronizedDefinition(
            connectedAt: 1_781_200_000_000,
            displayName: $0.emailAddress
          )
        }
      ),
      metadataStore: metadata,
      pendingActionService: PendingProviderActionService(
        maximumAttempts: 1,
        store: EWSActionStore()
      )
    )
    let connections = try await adapter.loadConnections(session: session)
    let firstConnection = try XCTUnwrap(
      connections.first(where: { $0.id == firstDefinition.connectionId })
    )
    let secondConnection = try XCTUnwrap(
      connections.first(where: { $0.id == secondDefinition.connectionId })
    )
    let firstInbox = try await adapter.loadInbox(connection: firstConnection, session: session)
    let secondInbox = try await adapter.loadInbox(connection: secondConnection, session: session)
    let firstMessage = try XCTUnwrap(firstInbox.messages.first)
    let secondMessage = try XCTUnwrap(secondInbox.messages.first)

    try await adapter.perform(
      .markRead,
      messages: [firstMessage],
      connection: firstConnection,
      session: session
    )
    try await adapter.perform(
      .archive,
      messages: [secondMessage],
      connection: secondConnection,
      session: session
    )
    let error = await adapter.resumePendingActions(
      connections: connections,
      session: session
    )

    XCTAssertNotNil(error)
    XCTAssertEqual(
      client.performedActions.filter { $0.connectionId == secondConnection.id }.map(\.action),
      [.archive]
    )
  }

  func testBodyAndSendUseCurrentEWSItemIdentity() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.body = "Message body"
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let metadata = InMemoryEWSMetadataStore()
    try metadata.save(
      snapshot(message: ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")),
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId
    )
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definition: definition.synchronizedDefinition(
          connectedAt: 1_781_200_000_000,
          displayName: definition.emailAddress
        )
      ),
      metadataStore: metadata
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let inbox = try await adapter.loadInbox(connection: connection, session: session)
    let message = try XCTUnwrap(inbox.messages.first)
    let outgoing = OutgoingMessage(
      body: "Reply",
      recipient: "sender@example.com",
      subject: "Re: Message 1",
      inReplyTo: message.rfcMessageId,
      providerThreadId: message.providerThreadId,
      idempotencyKey: "send-001"
    )

    let body = try await adapter.loadMessageBody(message: message, session: session)
    try await adapter.send(outgoing, connection: connection, session: session)

    XCTAssertEqual(body.text, "Message body")
    XCTAssertEqual(client.loadedBodyItemId, "ews-current-1")
    XCTAssertEqual(client.sentMessages, [outgoing])
  }

  func testTransientEWSActionRetriesThroughSharedQueue() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.remainingActionFailuresByConnectionId[definition.connectionId] = 1
    client.folders = [
      EWSFolder(changeKey: "inbox-key", displayName: "Inbox", id: "inbox-id", role: .inbox)
    ]
    client.pages["inbox-id|0"] = EWSMessagePage(
      messages: [ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")],
      nextOffset: nil
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definition: definition.synchronizedDefinition(
          connectedAt: 1_781_200_000_000,
          displayName: definition.emailAddress
        )
      ),
      metadataStore: InMemoryEWSMetadataStore(),
      pendingActionService: PendingProviderActionService(
        maximumAttempts: 2,
        retryDelayNanoseconds: { _ in 1_000_000 },
        store: EWSActionStore()
      )
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let initial = try await adapter.syncInbox(connection: connection, session: session)
    let message = try XCTUnwrap(initial.messages.first)

    try await adapter.perform(
      .markRead,
      messages: [message],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connection: connection, session: session)
    let retryError = await adapter.waitForPendingActionRetries(
      connection: connection,
      session: session
    )

    XCTAssertNil(retryError)
    XCTAssertEqual(client.performedActions.map(\.action), [.markRead])
    XCTAssertEqual(client.remainingActionFailuresByConnectionId[connection.id], 0)
  }

  func testRecentSyncReconcilesChangedEWSItemIdentityWithoutDuplicatingMessage() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    let inboxFolder = EWSFolder(
      changeKey: "inbox-key",
      displayName: "Inbox",
      id: "inbox-id",
      role: .inbox
    )
    client.folders = [inboxFolder]
    client.pages["inbox-id|0"] = EWSMessagePage(
      messages: [ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")],
      nextOffset: nil
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definition: definition.synchronizedDefinition(
          connectedAt: 1_781_200_000_000,
          displayName: definition.emailAddress
        )
      ),
      metadataStore: InMemoryEWSMetadataStore()
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    var changed = ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")
    changed.itemId = "ews-moved-1"
    changed.isRead = true
    client.pages["inbox-id|0"] = EWSMessagePage(messages: [changed], nextOffset: nil)

    let result = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: false,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    XCTAssertEqual(result.messages.map(\.providerMessageId), ["ews-stable-1"])
    XCTAssertFalse(result.messages[0].providerStateIds?.contains("UNREAD") == true)
    _ = try await adapter.loadMessageBody(message: result.messages[0], session: session)
    XCTAssertEqual(client.loadedBodyItemId, "ews-moved-1")

    client.pages["inbox-id|0"] = EWSMessagePage(messages: [], nextOffset: nil)
    let afterDeletion = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: false,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )
    XCTAssertTrue(afterDeletion.messages.isEmpty)
  }

  func testCompletedRefreshBackfillReconcilesHistoricalDeletion() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.folders = [
      EWSFolder(changeKey: "inbox-key", displayName: "Inbox", id: "inbox-id", role: .inbox)
    ]
    let recent = ewsMessage(2, folderId: "inbox-id", conversationId: "conversation-1")
    let historical = ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-2")
    client.pages["inbox-id|0"] = EWSMessagePage(messages: [recent], nextOffset: 1)
    client.pages["inbox-id|1"] = EWSMessagePage(messages: [historical], nextOffset: nil)
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definition: definition.synchronizedDefinition(
          connectedAt: 1_781_200_000_000,
          displayName: definition.emailAddress
        )
      ),
      metadataStore: InMemoryEWSMetadataStore()
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    let complete = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )
    XCTAssertEqual(
      Set(complete.messages.map(\.providerMessageId)),
      ["ews-stable-1", "ews-stable-2"]
    )

    client.pages["inbox-id|0"] = EWSMessagePage(messages: [recent], nextOffset: 1)
    client.pages["inbox-id|1"] = EWSMessagePage(messages: [], nextOffset: nil)
    _ = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: false,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )
    let reconciled = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    XCTAssertEqual(reconciled.messages.map(\.providerMessageId), ["ews-stable-2"])
  }

  private func snapshot(message: EWSProviderMessage) -> EWSMetadataSnapshot {
    EWSMetadataSnapshot(
      folders: [
        EWSFolder(changeKey: "inbox-key", displayName: "Inbox", id: "inbox-id", role: .inbox)
      ],
      messages: [message],
      nextOffsetsByFolderId: [:],
      hasInitialMailboxAvailability: true
    )
  }

  private func makeEWSURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [EWSURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private static let resolveNamesResponse = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
      <s:Header><t:ServerVersionInfo MajorVersion="15" MinorVersion="2"
        Version="Exchange2019"/></s:Header>
      <s:Body><m:ResolveNamesResponse><m:ResponseMessages>
        <m:ResolveNamesResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
          <m:ResolutionSet><t:Resolution><t:Mailbox>
            <t:Name>On-Prem Reader</t:Name>
            <t:EmailAddress>reader@corp.example</t:EmailAddress>
          </t:Mailbox></t:Resolution></m:ResolutionSet>
        </m:ResolveNamesResponseMessage>
      </m:ResponseMessages></m:ResolveNamesResponse></s:Body>
    </s:Envelope>
    """

  private static let getFolderResponse = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
      <s:Header><t:ServerVersionInfo MajorVersion="15" MinorVersion="2"
        Version="Exchange2019"/></s:Header>
      <s:Body><m:GetFolderResponse><m:ResponseMessages>
        <m:GetFolderResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
          <m:Folders><t:Folder>
            <t:FolderId Id="inbox-id" ChangeKey="inbox-key"/>
            <t:DisplayName>Inbox</t:DisplayName>
          </t:Folder></m:Folders>
        </m:GetFolderResponseMessage>
      </m:ResponseMessages></m:GetFolderResponse></s:Body>
    </s:Envelope>
    """

  private static let successResponse = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
      <s:Body><m:Response><m:ResponseCode>NoError</m:ResponseCode></m:Response></s:Body>
    </s:Envelope>
    """

  private func makeEWSDefinition() -> EWSConnectionDefinition {
    EWSConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "reader@corp.example",
      endpoint: URL(string: "https://mail.corp.example/EWS/Exchange.asmx")!,
      providerAccountIdentifier: "ews-account-001",
      serverVersion: .exchange2019,
      username: #"CORP\reader"#
    )
  }

  private func ewsMessage(
    _ number: Int,
    folderId: String,
    conversationId: String
  ) -> EWSProviderMessage {
    EWSProviderMessage(
      bccRecipients: [],
      ccRecipients: [],
      changeKey: "change-\(number)",
      conversationId: conversationId,
      from: "Sender <sender@example.com>",
      internetMessageId: "<message-\(number)@example.com>",
      isDraft: false,
      isRead: number.isMultiple(of: 2),
      itemId: "ews-current-\(number)",
      parentFolderId: folderId,
      receivedAtMilliseconds: 1_781_200_000_000 + Int64(number),
      replyTo: [],
      stableProviderId: "ews-stable-\(number)",
      subject: "Message \(number)",
      summary: "Summary \(number)",
      toRecipients: ["Reader <reader@corp.example>"]
    )
  }
}

private final class RecordingEWSClient: EWSClient, @unchecked Sendable {
  struct PerformedAction: Equatable {
    let action: ProviderMailAction
    let connectionId: MailboxConnectionId
  }

  var actionErrorsByConnectionId: [MailboxConnectionId: Error] = [:]
  var account = EWSAccount(
    displayName: "On-Prem Reader",
    primaryEmailAddress: "reader@corp.example",
    serverVersion: .exchange2019
  )
  var body = ""
  private let lock = NSLock()
  var folders: [EWSFolder] = EWSFolderRole.allCases.map {
    EWSFolder(
      changeKey: "\($0.rawValue)-key",
      displayName: $0.rawValue,
      id: "\($0.rawValue)-id",
      role: $0
    )
  }
  var loadedBodyItemId: String?
  var pages: [String: EWSMessagePage] = [:]
  var performedActions: [PerformedAction] = []
  var remainingActionFailuresByConnectionId: [MailboxConnectionId: Int] = [:]
  var requestedPages: [String] = []
  var sentMessages: [OutgoingMessage] = []
  var verifiedAuthorization: DeviceLocalEWSAuthorization?

  func verify(_ authorization: DeviceLocalEWSAuthorization) async throws -> EWSAccount {
    verifiedAuthorization = authorization
    return account
  }

  func loadFolders(
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> [EWSFolder] {
    folders
  }

  func loadMessagePage(
    folder: EWSFolder,
    offset: Int,
    pageSize _: Int,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> EWSMessagePage {
    let key = "\(folder.id)|\(offset)"
    lock.withLock { requestedPages.append(key) }
    return pages[key] ?? EWSMessagePage(messages: [], nextOffset: nil)
  }

  func loadMessageBody(
    itemId: String,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> String {
    loadedBodyItemId = itemId
    return body
  }

  func perform(
    _ action: ProviderMailAction,
    targetFolderId _: String?,
    messages _: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws {
    if let error = actionErrorsByConnectionId[authorization.definition.connectionId] {
      throw error
    }
    let connectionId = authorization.definition.connectionId
    if let failures = remainingActionFailuresByConnectionId[connectionId], failures > 0 {
      remainingActionFailuresByConnectionId[connectionId] = failures - 1
      throw EWSServiceError.response(code: "HTTP 503", message: "Temporarily unavailable")
    }
    lock.withLock {
      performedActions.append(
        PerformedAction(action: action, connectionId: authorization.definition.connectionId)
      )
    }
  }

  func send(
    _ message: OutgoingMessage,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws {
    sentMessages.append(message)
  }
}

private final class RecordingEWSDefinitionSyncService: MailboxConnectionDefinitionSyncing,
  @unchecked Sendable
{
  var savedDefinition: MailboxConnectionDefinition?

  init(
    definition: MailboxConnectionDefinition? = nil,
    definitions: [MailboxConnectionDefinition]? = nil
  ) {
    savedDefinition = definition
    savedDefinitions = definitions ?? definition.map { [$0] } ?? []
  }

  private var savedDefinitions: [MailboxConnectionDefinition]

  func loadSnapshot(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    MailboxConnectionSyncSnapshot(
      connections: savedDefinitions,
      defaultSendingConnectionId: nil,
      removedConnectionIds: [],
      updatedAt: nil
    )
  }

  func reconcileConnections(
    _ connections: [MailboxConnectionDefinition],
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    MailboxConnectionSyncSnapshot(
      connections: connections,
      defaultSendingConnectionId: nil,
      removedConnectionIds: [],
      updatedAt: nil
    )
  }

  func removeConnection(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    if savedDefinition?.id == connectionId {
      savedDefinition = nil
    }
    savedDefinitions.removeAll { $0.id == connectionId }
    return try await loadSnapshot(session: session)
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
    savedDefinition = definition
    if let index = savedDefinitions.firstIndex(where: { $0.id == definition.id }) {
      savedDefinitions[index] = definition
    } else {
      savedDefinitions.append(definition)
    }
    return try await loadSnapshot(session: session)
  }

  func setDefaultSendingConnection(
    _ connectionId: MailboxConnectionId?,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    let snapshot = try await loadSnapshot(session: session)
    return MailboxConnectionSyncSnapshot(
      connections: snapshot.connections,
      defaultSendingConnectionId: connectionId,
      removedConnectionIds: [],
      updatedAt: snapshot.updatedAt
    )
  }
}

private enum EWSClientTestError: Error {
  case offline
}

private final class EWSActionStore: PendingProviderActionPersisting, @unchecked Sendable {
  private var actions: [PendingProviderAction] = []

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

private final class EWSURLProtocol: URLProtocol, @unchecked Sendable {
  static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  // swiftlint:disable:next static_over_final_class
  override class func canInit(with _: URLRequest) -> Bool {
    true
  }

  // swiftlint:disable:next static_over_final_class
  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    do {
      guard let handler = Self.requestHandler else {
        throw EWSClientTestError.offline
      }
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
