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
      "https://reader:password@mail.corp.example/EWS/Exchange.asmx",
      "https://mail.corp.example/EWS/Exchange.asmx?access_token=secret",
      "https://mail.corp.example/EWS/Exchange.asmx#secret",
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

  func testConnectionIdentityIncludesEffectiveEndpointPort() throws {
    let standard = try EWSConnectionDefinition.stableProviderAccountIdentifier(
      endpoint: XCTUnwrap(URL(string: "https://mail.corp.example/EWS/Exchange.asmx")),
      primaryEmailAddress: "reader@corp.example"
    )
    let explicitStandard = try EWSConnectionDefinition.stableProviderAccountIdentifier(
      endpoint: XCTUnwrap(URL(string: "https://mail.corp.example:443/EWS/Exchange.asmx")),
      primaryEmailAddress: "reader@corp.example"
    )
    let alternate = try EWSConnectionDefinition.stableProviderAccountIdentifier(
      endpoint: XCTUnwrap(URL(string: "https://mail.corp.example:8443/EWS/Exchange.asmx")),
      primaryEmailAddress: "reader@corp.example"
    )

    XCTAssertEqual(standard, explicitStandard)
    XCTAssertNotEqual(standard, alternate)
  }

  func testEWSRedirectsAndCredentialChallengesStayOnConfiguredOrigin() {
    let endpoint = URL(string: "https://mail.corp.example/EWS/Exchange.asmx")!

    XCTAssertTrue(
      EWSConnectionDefinition.hasSameOrigin(
        URL(string: "https://MAIL.corp.example:443/EWS/redirected")!,
        as: endpoint
      )
    )
    XCTAssertFalse(
      EWSConnectionDefinition.hasSameOrigin(
        URL(string: "https://login.corp.example/EWS/Exchange.asmx")!,
        as: endpoint
      )
    )
    XCTAssertFalse(
      EWSConnectionDefinition.hasSameOrigin(
        URL(string: "https://mail.corp.example:8443/EWS/Exchange.asmx")!,
        as: endpoint
      )
    )
  }

  func testEWSCapabilitiesDoNotAdvertiseUnimplementedProviderOperations() {
    XCTAssertFalse(MailboxConnectionCapabilities.exchangeWebServices.canCategorizeHistorical)
    XCTAssertFalse(MailboxConnectionCapabilities.exchangeWebServices.canSearchProvider)
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
    XCTAssertEqual(connection.displayName, "reader@corp.example")
    XCTAssertEqual(client.verifiedAuthorization?.credential, " private-password ")
    XCTAssertEqual(definitions.savedDefinition?.provider, "exchange-web-services")
    XCTAssertEqual(definitions.savedDefinition?.displayName, "reader@corp.example")
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

  func testSetupCancellationBeforePersistenceLeavesNoConnection() async throws {
    let client = RecordingEWSClient()
    let definitions = RecordingEWSDefinitionSyncService()
    let authorizations = InMemoryEWSAuthorizationStore()
    let service = EWSSetupService(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: definitions
    )
    var sessionIsCurrent = true
    definitions.didLoadSnapshot = {
      sessionIsCurrent = false
    }

    let result = await Task {
      do {
        _ = try await service.connect(
          authorizationMethod: .password,
          credential: "password",
          emailAddress: "reader@corp.example",
          endpoint: "https://mail.corp.example/EWS/Exchange.asmx",
          username: #"CORP\reader"#,
          session: session,
          isSessionCurrent: { _ in sessionIsCurrent }
        )
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }.value

    XCTAssertTrue(result)
    XCTAssertNil(definitions.savedDefinition)
    XCTAssertNil(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: makeEWSDefinition().connectionId
      )
    )
  }

  func testSetupAcceptsSupportedVersionsAndAuthorizationMethods() async throws {
    for (versionIndex, version) in EWSServerVersion.allCases.enumerated() {
      for (methodIndex, method) in MailAuthorizationMethod.allCases.enumerated() {
        let index = (versionIndex * MailAuthorizationMethod.allCases.count) + methodIndex
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
  }

  func testEWSSetupCanSetDefaultSendingConnection() async throws {
    let definition = makeEWSDefinition()
    let definitions = RecordingEWSDefinitionSyncService(
      definition: definition.synchronizedDefinition(
        connectedAt: 1_781_200_000_000,
        displayName: definition.emailAddress
      )
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      client: RecordingEWSClient(),
      definitionSyncService: definitions,
      metadataStore: InMemoryEWSMetadataStore()
    )
    let viewModel = EWSSetupViewModel(
      adapter: adapter,
      definitionSyncService: definitions,
      isSessionCurrent: { $0 == self.session },
      session: session
    )

    await viewModel.load()
    let connection = try XCTUnwrap(viewModel.connections.first)
    viewModel.credential = "credential-for-another-connection"
    await viewModel.select(connection)
    let didSetDefault = await viewModel.setDefaultSendingConnection(connection)

    XCTAssertEqual(viewModel.credential, "")
    XCTAssertTrue(didSetDefault)
    XCTAssertEqual(viewModel.defaultSendingConnectionId, connection.id)
    XCTAssertEqual(definitions.defaultSendingConnectionId, connection.id)
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
    XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
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

  func testSystemClientRejectsExchange2013BeforeSP1() async throws {
    EWSURLProtocol.requestHandler = { request in
      let payload =
        request.value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/ResolveNames") == true
        ? Self.resolveNamesResponse
          .replacingOccurrences(
            of: "MinorVersion=\"2\"",
            with: "MinorVersion=\"0\" MajorBuildNumber=\"800\" MinorBuildNumber=\"0\""
          )
          .replacingOccurrences(of: "Exchange2019", with: "Exchange2013")
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

    do {
      _ = try await SystemEWSClient(session: makeEWSURLSession()).verify(
        DeviceLocalEWSAuthorization(
          credential: "password",
          definition: makeEWSDefinition()
        )
      )
      XCTFail("Expected pre-SP1 Exchange 2013 to be rejected")
    } catch {
      XCTAssertEqual(error as? EWSSetupError, .unsupportedServerVersion)
    }
  }

  func testSystemClientBuildsOAuthAppPasswordActionAndSendRequests() async throws {
    var requests: [URLRequest] = []
    var requestBodies: [String] = []
    EWSURLProtocol.requestHandler = { request in
      requests.append(request)
      requestBodies.append(try Self.requestBody(request))
      let response =
        request.value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/UpdateItem") == true
        ? Self.updateItemResponse
        : Self.successResponse
      return (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(response.utf8)
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
    let updated = try await client.perform(
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
        recipient: #""Recipient, One" <one@example.com>, Two <two@example.com>"#,
        subject: "Subject",
        idempotencyKey: "ews-send"
      ),
      authorization: DeviceLocalEWSAuthorization(
        credential: "app-password",
        definition: appPasswordDefinition
      )
    )

    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
    XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
    XCTAssertTrue(
      requests[0].value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/UpdateItem") == true)
    XCTAssertTrue(
      requests[1].value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/CreateItem") == true)
    let updateBody = requestBodies[0]
    XCTAssertTrue(updateBody.contains("<t:IsRead>true</t:IsRead>"))
    XCTAssertFalse(updateBody.contains("<m:IsRead>"))
    XCTAssertEqual(updated.first?.changeKey, "updated-change-key")
    let sendBody = requestBodies[1]
    XCTAssertTrue(
      sendBody.contains(
        "<t:From><t:Mailbox><t:EmailAddress>reader@corp.example</t:EmailAddress>"
      )
    )
    XCTAssertTrue(sendBody.contains("<t:EmailAddress>one@example.com</t:EmailAddress>"))
    XCTAssertTrue(sendBody.contains("<t:EmailAddress>two@example.com</t:EmailAddress>"))
    XCTAssertFalse(sendBody.contains("Recipient, One"))
  }

  func testSystemClientRefreshesCurrentItemIdentityWithoutSubmittingStaleChangeKey()
    async throws
  {
    var requestBody = ""
    EWSURLProtocol.requestHandler = { request in
      requestBody = try Self.requestBody(request)
      return (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(Self.getItemResponse.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }
    let message = ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")

    let refreshed = try await SystemEWSClient(session: makeEWSURLSession())
      .refreshMessageIdentities(
        [message],
        authorization: DeviceLocalEWSAuthorization(
          credential: "password",
          definition: makeEWSDefinition()
        )
      )

    XCTAssertTrue(requestBody.contains(#"<t:ItemId Id="ews-current-1"/>"#))
    XCTAssertFalse(requestBody.contains(message.changeKey))
    XCTAssertEqual(refreshed.first?.itemId, "item-id")
    XCTAssertEqual(refreshed.first?.changeKey, "change-key")
  }

  func testSystemClientTreatsMixedBatchOutcomesAsAmbiguous() async throws {
    let mixedResponse = """
      <?xml version="1.0" encoding="utf-8"?>
      <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
        <s:Body><m:UpdateItemResponse><m:ResponseMessages>
          <m:UpdateItemResponseMessage ResponseClass="Success">
            <m:ResponseCode>NoError</m:ResponseCode>
            <m:Items><t:Message>
              <t:ItemId Id="updated-item-id" ChangeKey="updated-change-key"/>
            </t:Message></m:Items>
          </m:UpdateItemResponseMessage>
          <m:UpdateItemResponseMessage ResponseClass="Error">
            <m:MessageText>Conflict</m:MessageText>
            <m:ResponseCode>ErrorIrresolvableConflict</m:ResponseCode>
          </m:UpdateItemResponseMessage>
        </m:ResponseMessages></m:UpdateItemResponse></s:Body>
      </s:Envelope>
      """
    EWSURLProtocol.requestHandler = { request in
      (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(mixedResponse.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }

    do {
      _ = try await SystemEWSClient(session: makeEWSURLSession()).perform(
        .markRead,
        targetFolderId: nil,
        messages: [
          ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1"),
          ewsMessage(2, folderId: "inbox-id", conversationId: "conversation-2"),
        ],
        authorization: DeviceLocalEWSAuthorization(
          credential: "password",
          definition: makeEWSDefinition()
        )
      )
      XCTFail("Expected a mixed batch response to require reconciliation")
    } catch {
      XCTAssertEqual(error as? EWSServiceError, .invalidResponse)
    }
  }

  func testSystemClientRejectsSuccessfulHTTPResponseWithoutEWSResponseCode() async throws {
    let response = """
      <?xml version="1.0" encoding="utf-8"?>
      <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
        <s:Body><m:CreateItemResponse/></s:Body>
      </s:Envelope>
      """
    EWSURLProtocol.requestHandler = { request in
      (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(response.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }

    do {
      try await SystemEWSClient(session: makeEWSURLSession()).send(
        OutgoingMessage(
          body: "Body",
          recipient: "recipient@example.com",
          subject: "Subject",
          idempotencyKey: "missing-response-code"
        ),
        authorization: DeviceLocalEWSAuthorization(
          credential: "password",
          definition: makeEWSDefinition()
        )
      )
      XCTFail("Expected a response without an EWS response code to be rejected")
    } catch {
      XCTAssertEqual(error as? EWSServiceError, .invalidResponse)
    }
  }

  func testSystemClientTreatsPartialMultiFolderArchiveAsAmbiguous() async throws {
    var archiveRequestCount = 0
    EWSURLProtocol.requestHandler = { request in
      archiveRequestCount += 1
      if archiveRequestCount == 1 {
        return (
          HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
          )!,
          Data(Self.moveItemResponse.utf8)
        )
      }
      return (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 503,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data("Unavailable".utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }

    do {
      _ = try await SystemEWSClient(session: makeEWSURLSession()).perform(
        .archive,
        targetFolderId: nil,
        messages: [
          ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1"),
          ewsMessage(2, folderId: "projects-id", conversationId: "conversation-2"),
        ],
        authorization: DeviceLocalEWSAuthorization(
          credential: "password",
          definition: makeEWSDefinition()
        )
      )
      XCTFail("Expected a partial archive outcome to require reconciliation")
    } catch {
      XCTAssertTrue(error is EWSAmbiguousProviderActionError)
    }
  }

  func testSystemClientUsesValidMessageFieldURIs() async throws {
    var requests: [URLRequest] = []
    var requestBodies: [String] = []
    EWSURLProtocol.requestHandler = { request in
      requests.append(request)
      requestBodies.append(try Self.requestBody(request))
      let response =
        request.value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/FindItem") == true
        ? Self.findItemResponse
        : Self.successResponse
      return (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(response.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }
    let client = SystemEWSClient(session: makeEWSURLSession())
    let authorization = DeviceLocalEWSAuthorization(
      credential: "password",
      definition: makeEWSDefinition()
    )
    let folder = EWSFolder(
      changeKey: nil,
      displayName: "Inbox",
      id: "inbox-id",
      role: .inbox
    )

    _ = try await client.loadMessagePage(
      folder: folder,
      offset: 0,
      pageSize: 50,
      authorization: authorization
    )
    _ = try await client.deliveryStatus(
      rfcMessageId: "<delivery@example.com>",
      authorization: authorization
    )

    let metadataBody = requestBodies[0]
    for field in [
      "message:InternetMessageId",
      "message:From",
      "message:ReplyTo",
      "message:ToRecipients",
      "message:CcRecipients",
      "message:BccRecipients",
      "item:DateTimeCreated",
      "item:Preview",
    ] {
      XCTAssertTrue(metadataBody.contains(#"FieldURI="\#(field)""#))
    }
    XCTAssertFalse(metadataBody.contains(#"FieldURI="item:InternetMessageId""#))
    let deliveryBody = requestBodies[1]
    XCTAssertTrue(
      deliveryBody.contains(#"PropertyName="UnwiredOutboxId""#)
    )
  }

  func testSystemClientDoesNotUseInternetMessageIdAsStableIdentity() async throws {
    let response = Self.findItemResponse.replacingOccurrences(
      of: """
          </t:Message></t:Items>
        """,
      with: """
          <t:InternetMessageId>&lt;duplicate@example.com&gt;</t:InternetMessageId>
          </t:Message><t:Message>
            <t:ItemId Id="second-item-id" ChangeKey="second-change-key"/>
            <t:InternetMessageId>&lt;duplicate@example.com&gt;</t:InternetMessageId>
            <t:DateTimeReceived>2026-07-27T12:34:55.123Z</t:DateTimeReceived>
          </t:Message></t:Items>
        """
    )
    EWSURLProtocol.requestHandler = { request in
      (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(response.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }

    let page = try await SystemEWSClient(session: makeEWSURLSession()).loadMessagePage(
      folder: EWSFolder(
        changeKey: nil,
        displayName: "Inbox",
        id: "inbox-id",
        role: .inbox
      ),
      offset: 0,
      pageSize: 50,
      authorization: DeviceLocalEWSAuthorization(
        credential: "password",
        definition: makeEWSDefinition()
      )
    )

    XCTAssertEqual(Set(page.messages.map(\.stableProviderId)), ["item-id", "second-item-id"])
  }

  func testSystemClientUsesCreatedTimestampWhenReceivedTimestampIsMissing() async throws {
    EWSURLProtocol.requestHandler = { request in
      (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(
          Self.findItemResponse.replacingOccurrences(
            of: "DateTimeReceived",
            with: "DateTimeCreated"
          ).utf8
        )
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }
    let authorization = DeviceLocalEWSAuthorization(
      credential: "password",
      definition: makeEWSDefinition()
    )

    let page = try await SystemEWSClient(session: makeEWSURLSession()).loadMessagePage(
      folder: EWSFolder(
        changeKey: nil,
        displayName: "Drafts",
        id: "drafts-id",
        role: .drafts
      ),
      offset: 0,
      pageSize: 50,
      authorization: authorization
    )

    XCTAssertEqual(page.messages.first?.receivedAtMilliseconds, 1_785_155_696_123)
  }

  func testSystemClientPaginatesDeepFolderDiscovery() async throws {
    var findFolderOffsets: [Int] = []
    EWSURLProtocol.requestHandler = { request in
      let body = try Self.requestBody(request)
      if body.contains("<m:FindFolder") {
        let offset = body.contains(#"Offset="0""#) ? 0 : 100
        findFolderOffsets.append(offset)
        return (
          HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
          )!,
          Data(Self.findFolderResponse(offset: offset).utf8)
        )
      }
      return (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(Self.folderNotFoundResponse.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }
    let authorization = DeviceLocalEWSAuthorization(
      credential: "password",
      definition: makeEWSDefinition()
    )

    let folders = try await SystemEWSClient(session: makeEWSURLSession()).loadFolders(
      authorization: authorization
    )

    XCTAssertEqual(findFolderOffsets, [0, 100])
    XCTAssertEqual(Set(folders.map(\.id)), ["custom-0", "custom-100"])
    XCTAssertEqual(folders.first(where: { $0.id == "custom-0" })?.isSearchFolder, false)
    XCTAssertEqual(folders.first(where: { $0.id == "custom-100" })?.isSearchFolder, true)
  }

  func testSystemClientPropagatesMailboxStoreUnavailableForDistinguishedFolder() async throws {
    EWSURLProtocol.requestHandler = { request in
      let body = try Self.requestBody(request)
      let response =
        body.contains("<m:FindFolder")
        ? Self.findFolderResponse(offset: 100)
        : Self.folderNotFoundResponse.replacingOccurrences(
          of: "ErrorFolderNotFound",
          with: "ErrorMailboxStoreUnavailable"
        )
      return (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(response.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }

    do {
      _ = try await SystemEWSClient(session: makeEWSURLSession()).loadFolders(
        authorization: DeviceLocalEWSAuthorization(
          credential: "password",
          definition: makeEWSDefinition()
        )
      )
      XCTFail("Expected the temporary mailbox-store outage to propagate")
    } catch {
      guard
        let serviceError = error as? EWSServiceError,
        case .response(let code, _) = serviceError
      else {
        return XCTFail("Expected an EWS response error")
      }
      XCTAssertEqual(code, "ErrorMailboxStoreUnavailable")
    }
  }

  func testSystemClientParsesItemBodyFractionalTimestampAndMovedIdentity() async throws {
    var requestBodies: [String] = []
    EWSURLProtocol.requestHandler = { request in
      let body = try Self.requestBody(request)
      requestBodies.append(body)
      let payload =
        if body.contains("<m:GetItem>") {
          Self.getItemResponse
        } else if body.contains("<m:FindItem") {
          Self.findItemResponse
        } else if body.contains("<m:ArchiveItem>") {
          Self.archiveItemResponse
        } else {
          Self.moveItemResponse
        }
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
    let client = SystemEWSClient(session: makeEWSURLSession())
    let message = ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")

    let body = try await client.loadMessageBody(
      itemId: message.itemId,
      authorization: authorization
    )
    let page = try await client.loadMessagePage(
      folder: EWSFolder(changeKey: nil, displayName: "Inbox", id: "inbox-id", role: .inbox),
      offset: 0,
      pageSize: 50,
      authorization: authorization
    )
    let archived = try await client.perform(
      .archive,
      targetFolderId: nil,
      messages: [message],
      authorization: authorization
    )
    let moved = try await client.perform(
      .move,
      targetFolderId: "archive-id",
      messages: [message],
      authorization: authorization
    )
    let deleted = try await client.perform(
      .delete,
      targetFolderId: nil,
      messages: [message],
      authorization: authorization
    )

    XCTAssertEqual(body, "Rendered message body")
    XCTAssertEqual(page.messages.first?.receivedAtMilliseconds, 1_785_155_696_123)
    XCTAssertEqual(
      archived,
      [
        EWSMovedItemIdentity(
          changeKey: "change-key",
          itemId: "item-id",
          stableProviderId: message.stableProviderId
        )
      ]
    )
    XCTAssertEqual(
      moved,
      [
        EWSMovedItemIdentity(
          changeKey: "moved-change-key",
          itemId: "moved-item-id",
          stableProviderId: message.stableProviderId
        )
      ]
    )
    XCTAssertEqual(deleted, moved)
    XCTAssertTrue(requestBodies[2].contains("<m:ArchiveItem>"))
    XCTAssertTrue(requestBodies[2].contains("<m:ArchiveSourceFolderId>"))
    XCTAssertTrue(requestBodies[2].contains(#"Id="inbox-id""#))
    XCTAssertFalse(requestBodies[2].contains("<m:MoveItem>"))
    XCTAssertTrue(requestBodies[3].contains(#"Id="archiveinbox""#))
    XCTAssertTrue(requestBodies[3].contains(message.stableProviderId))
    XCTAssertTrue(requestBodies.last?.contains("<m:MoveItem>") == true)
    XCTAssertTrue(requestBodies.last?.contains(#"Id="deleteditems""#) == true)
    XCTAssertFalse(requestBodies.last?.contains("<m:DeleteItem") == true)
  }

  func testSystemClientRejectsInvalidFindItemPagingMetadata() async throws {
    let responses = [
      Self.successResponse,
      Self.findItemResponse.replacingOccurrences(
        of: #"IncludesLastItemInRange="true""#,
        with: #"IncludesLastItemInRange="false""#
      ),
    ]
    let authorization = DeviceLocalEWSAuthorization(
      credential: "password",
      definition: makeEWSDefinition()
    )
    let folder = EWSFolder(
      changeKey: nil,
      displayName: "Inbox",
      id: "inbox-id",
      role: .inbox
    )
    defer { EWSURLProtocol.requestHandler = nil }

    for response in responses {
      EWSURLProtocol.requestHandler = { request in
        (
          HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
          )!,
          Data(response.utf8)
        )
      }
      do {
        _ = try await SystemEWSClient(session: makeEWSURLSession()).loadMessagePage(
          folder: folder,
          offset: 0,
          pageSize: 50,
          authorization: authorization
        )
        XCTFail("Expected malformed FindItem paging metadata to be rejected")
      } catch {
        XCTAssertEqual(error as? EWSServiceError, .invalidResponse)
      }
    }
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
    XCTAssertEqual(
      client.requestedPages,
      ["inbox-id|0", "sent-id|0", "inbox-id|2"]
    )
  }

  func testSearchFoldersAreExcludedFromMoveDestinations() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.folders = [
      EWSFolder(
        changeKey: "regular-key",
        displayName: "Projects",
        id: "projects-id",
        isSearchFolder: false,
        role: nil
      ),
      EWSFolder(
        changeKey: "search-key",
        displayName: "Unread Mail",
        id: "unread-id",
        isSearchFolder: true,
        role: nil
      ),
    ]
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

    let mailboxes = try await adapter.loadProviderMailboxes(
      connection: connection,
      session: session
    )

    XCTAssertEqual(mailboxes.map(\.title), ["Projects"])
  }

  func testHistoricalBackfillResumesAndDrainsEveryPendingPage() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.folders = [
      EWSFolder(changeKey: "inbox-key", displayName: "Inbox", id: "inbox-id", role: .inbox)
    ]
    client.pages["inbox-id|0"] = EWSMessagePage(
      messages: [ewsMessage(3, folderId: "inbox-id", conversationId: "conversation-3")],
      nextOffset: 50
    )
    client.pages["inbox-id|50"] = EWSMessagePage(
      messages: [ewsMessage(2, folderId: "inbox-id", conversationId: "conversation-2")],
      nextOffset: 100
    )
    client.pages["inbox-id|100"] = EWSMessagePage(
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
    let complete = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )
    _ = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: false,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )
    XCTAssertTrue(complete.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(
      Set(complete.messages.map(\.providerMessageId)),
      ["ews-stable-1", "ews-stable-2", "ews-stable-3"]
    )
    XCTAssertEqual(
      client.requestedPages,
      ["inbox-id|0", "inbox-id|50", "inbox-id|100", "inbox-id|0"]
    )
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

  func testBodyCacheRejectsPayloadAfterChangeKeyChanges() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.body = "Original body"
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let metadata = InMemoryEWSMetadataStore()
    var storedMessage = ewsMessage(
      1,
      folderId: "inbox-id",
      conversationId: "conversation-1"
    )
    try metadata.save(
      snapshot(message: storedMessage),
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId
    )
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      cache: RecordingEWSBodyCache(),
      client: client,
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definition: definition.synchronizedDefinition(
          connectedAt: 1_781_200_000_000,
          displayName: definition.emailAddress
        )
      ),
      metadataStore: metadata,
      keyMaterialStore: keyStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let inbox = try await adapter.loadInbox(connection: connection, session: session)
    let message = try XCTUnwrap(inbox.messages.first)

    let original = try await adapter.loadMessageBody(message: message, session: session)
    storedMessage.changeKey = "changed-by-another-client"
    try metadata.save(
      snapshot(message: storedMessage),
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId
    )
    client.body = "Updated body"
    let updated = try await adapter.loadMessageBody(message: message, session: session)

    XCTAssertEqual(original.text, "Original body")
    XCTAssertEqual(updated.text, "Updated body")
    XCTAssertEqual(client.bodyRequestCount, 2)
  }

  func testTransientEWSActionRetriesThroughSharedQueue() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.remainingOfflineFailuresByConnectionId[definition.connectionId] = 1
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
    XCTAssertEqual(client.remainingOfflineFailuresByConnectionId[connection.id], 0)
  }

  func testArchiveFromSentRefreshesIdentityAndRunsProviderAction() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    let sentMessage = ewsMessage(1, folderId: "sent-id", conversationId: "conversation-1")
    var refreshedMessage = sentMessage
    refreshedMessage.changeKey = "refreshed-change-key"
    client.refreshedMessagesByStableId[sentMessage.stableProviderId] = refreshedMessage
    client.pages["sent-id|0"] = EWSMessagePage(messages: [sentMessage], nextOffset: nil)
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let metadata = InMemoryEWSMetadataStore()
    try metadata.save(
      EWSMetadataSnapshot(
        folders: client.folders,
        messages: [sentMessage],
        nextOffsetsByFolderId: [:],
        hasInitialMailboxAvailability: true
      ),
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
      metadataStore: metadata,
      pendingActionService: PendingProviderActionService(store: EWSActionStore())
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let sent = try await adapter.loadMailbox(
      .role(.sent),
      connection: connection,
      session: session
    )

    try await adapter.perform(
      .archive,
      messages: [try XCTUnwrap(sent.messages.first)],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connection: connection, session: session)
    let retryError = await adapter.waitForPendingActionRetries(
      connection: connection,
      session: session
    )

    XCTAssertNil(retryError)
    XCTAssertEqual(client.performedActions.map(\.action), [.archive])
    XCTAssertEqual(client.performedMessageChangeKeys, [["refreshed-change-key"]])
  }

  func testAuthenticationRejectedBlocksPendingEWSActionForUserIntervention() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.actionErrorsByConnectionId[definition.connectionId] =
      EWSServiceError.authenticationRejected
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
      pendingActionService: PendingProviderActionService(store: EWSActionStore())
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try XCTUnwrap(inbox.messages.first)

    try await adapter.perform(
      .markRead,
      messages: [message],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connection: connection, session: session)

    let blockedIds = await adapter.blockedPendingActionConnectionIds(
      connections: [connection],
      session: session
    )
    XCTAssertEqual(blockedIds, [connection.id])
  }

  func testSyncedEWSRemovalFencesAccessAndClearsLocalState() async throws {
    let definition = makeEWSDefinition()
    let definitions = RecordingEWSDefinitionSyncService(
      definition: definition.synchronizedDefinition(
        connectedAt: 1_781_200_000_000,
        displayName: definition.emailAddress
      )
    )
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
      client: RecordingEWSClient(),
      definitionSyncService: definitions,
      metadataStore: metadata
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    let inbox = try await adapter.loadInbox(connection: connection, session: session)
    let message = try XCTUnwrap(inbox.messages.first)
    definitions.removedConnectionIds = [connection.id]

    do {
      _ = try await adapter.loadMessageBody(message: message, session: session)
      XCTFail("Expected synchronized removal to fence provider access")
    } catch {}
    XCTAssertNil(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    )
    XCTAssertNil(
      try metadata.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    )
  }

  func testEWSConnectionsLoadThroughOfflineProviderSnapshotPath() async throws {
    let definition = makeEWSDefinition()
    let definitions = RecordingEWSDefinitionSyncService(
      definition: definition.synchronizedDefinition(
        connectedAt: 1_781_200_000_000,
        displayName: definition.emailAddress
      )
    )
    definitions.loadSnapshotError = EWSClientTestError.offline
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      definitionSyncService: definitions,
      metadataStore: InMemoryEWSMetadataStore()
    )

    let connections = try await adapter.loadConnections(session: session)

    XCTAssertEqual(connections.map(\.id), [definition.connectionId])
    XCTAssertEqual(definitions.providerAccessLoads, 1)
  }

  func testPersistedSyncRefreshesChangedEWSItemIdentityWithoutDuplicatingMessage()
    async throws
  {
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

    let result = try await adapter.syncInbox(connection: connection, session: session)

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

  func testPersistedSyncPreservesFallbackIdentityWhenMatchingMovedItemId() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.folders = [
      EWSFolder(changeKey: "inbox-key", displayName: "Inbox", id: "inbox-id", role: .inbox)
    ]
    var original = ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")
    original.stableProviderId = original.itemId
    client.pages["inbox-id|0"] = EWSMessagePage(messages: [original], nextOffset: nil)
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let metadataStore = InMemoryEWSMetadataStore()
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definition: definition.synchronizedDefinition(
          connectedAt: 1_781_200_000_000,
          displayName: definition.emailAddress
        )
      ),
      metadataStore: metadataStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    var stored = try XCTUnwrap(
      try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    )
    stored.messages[0].itemId = "ews-moved-1"
    try metadataStore.save(
      stored,
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
    var refreshed = original
    refreshed.itemId = "ews-moved-1"
    refreshed.stableProviderId = refreshed.itemId
    client.pages["inbox-id|0"] = EWSMessagePage(messages: [refreshed], nextOffset: nil)

    let result = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertEqual(result.messages.map(\.providerMessageId), [original.stableProviderId])
    _ = try await adapter.loadMessageBody(message: result.messages[0], session: session)
    XCTAssertEqual(client.loadedBodyItemId, refreshed.itemId)
  }

  func testRecentSyncRetainsUnobservedMessageTiedAtPageCutoff() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.folders = [
      EWSFolder(changeKey: "inbox-key", displayName: "Inbox", id: "inbox-id", role: .inbox)
    ]
    let cutoff = Int64(1_781_200_000_000)
    let observed = ewsMessage(
      1,
      folderId: "inbox-id",
      conversationId: "conversation-1",
      receivedAtMilliseconds: cutoff
    )
    let tied = ewsMessage(
      2,
      folderId: "inbox-id",
      conversationId: "conversation-2",
      receivedAtMilliseconds: cutoff
    )
    client.pages["inbox-id|0"] = EWSMessagePage(
      messages: [observed, tied],
      nextOffset: 50
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
    client.pages["inbox-id|0"] = EWSMessagePage(messages: [observed], nextOffset: 50)

    let result = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: false,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    XCTAssertEqual(
      Set(result.messages.map(\.providerMessageId)),
      Set([observed.stableProviderId, tied.stableProviderId])
    )
  }

  func testRecentInitialSyncDoesNotPersistAfterSessionBecomesStale() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
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
    let metadataStore = InMemoryEWSMetadataStore()
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definition: definition.synchronizedDefinition(
          connectedAt: 1_781_200_000_000,
          displayName: definition.emailAddress
        )
      ),
      metadataStore: metadataStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)
    var validityChecks = 0

    do {
      _ = try await adapter.syncRecentInbox(
        connection: connection,
        includingHistoryCandidates: false,
        session: session,
        sinceHistoryId: nil,
        throughHistoryId: nil,
        shouldPersist: {
          validityChecks += 1
          return validityChecks == 1
        }
      )
      XCTFail("Expected stale session cancellation")
    } catch is CancellationError {}

    XCTAssertNil(
      try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    )
  }

  func testOffsetBackfillDoesNotDeleteMessagesMissingFromMutablePages() async throws {
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

    XCTAssertEqual(
      Set(reconciled.messages.map(\.providerMessageId)),
      ["ews-stable-1", "ews-stable-2"]
    )
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

  private static let getItemResponse = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
      <s:Body><m:GetItemResponse><m:ResponseMessages>
        <m:GetItemResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
          <m:Items><t:Message>
            <t:ItemId Id="item-id" ChangeKey="change-key"/>
            <t:Body BodyType="Text">Rendered message body</t:Body>
          </t:Message></m:Items>
        </m:GetItemResponseMessage>
      </m:ResponseMessages></m:GetItemResponse></s:Body>
    </s:Envelope>
    """

  private static let findItemResponse = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
      <s:Body><m:FindItemResponse><m:ResponseMessages>
        <m:FindItemResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
          <m:RootFolder IncludesLastItemInRange="true">
            <t:Items><t:Message>
              <t:ItemId Id="item-id" ChangeKey="change-key"/>
              <t:DateTimeReceived>2026-07-27T12:34:56.123Z</t:DateTimeReceived>
            </t:Message></t:Items>
          </m:RootFolder>
        </m:FindItemResponseMessage>
      </m:ResponseMessages></m:FindItemResponse></s:Body>
    </s:Envelope>
    """

  private static let moveItemResponse = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
      <s:Body><m:MoveItemResponse><m:ResponseMessages>
        <m:MoveItemResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
          <m:Items><t:Message>
            <t:ItemId Id="moved-item-id" ChangeKey="moved-change-key"/>
          </t:Message></m:Items>
        </m:MoveItemResponseMessage>
      </m:ResponseMessages></m:MoveItemResponse></s:Body>
    </s:Envelope>
    """

  private static let archiveItemResponse = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
      <s:Body><m:ArchiveItemResponse><m:ResponseMessages>
        <m:ArchiveItemResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
          <m:Items/>
        </m:ArchiveItemResponseMessage>
      </m:ResponseMessages></m:ArchiveItemResponse></s:Body>
    </s:Envelope>
    """

  private static let updateItemResponse = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
      <s:Body><m:UpdateItemResponse><m:ResponseMessages>
        <m:UpdateItemResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
          <m:Items><t:Message>
            <t:ItemId Id="ews-current-1" ChangeKey="updated-change-key"/>
          </t:Message></m:Items>
        </m:UpdateItemResponseMessage>
      </m:ResponseMessages></m:UpdateItemResponse></s:Body>
    </s:Envelope>
    """

  private static func findFolderResponse(offset: Int) -> String {
    let includesLast = offset == 100
    let folderType = offset == 100 ? "SearchFolder" : "Folder"
    return """
      <?xml version="1.0" encoding="utf-8"?>
      <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
        <s:Body><m:FindFolderResponse><m:ResponseMessages>
          <m:FindFolderResponseMessage ResponseClass="Success">
            <m:ResponseCode>NoError</m:ResponseCode>
            <m:RootFolder IncludesLastItemInRange="\(includesLast)"
              IndexedPagingOffset="\(offset + 100)">
              <t:Folders><t:\(folderType)>
                <t:FolderId Id="custom-\(offset)" ChangeKey="key-\(offset)"/>
                <t:DisplayName>Custom \(offset)</t:DisplayName>
              </t:\(folderType)></t:Folders>
            </m:RootFolder>
          </m:FindFolderResponseMessage>
        </m:ResponseMessages></m:FindFolderResponse></s:Body>
      </s:Envelope>
      """
  }

  private static let folderNotFoundResponse = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
      <s:Body><m:GetFolderResponse><m:ResponseMessages>
        <m:GetFolderResponseMessage ResponseClass="Error">
          <m:MessageText>Folder not found</m:MessageText>
          <m:ResponseCode>ErrorFolderNotFound</m:ResponseCode>
        </m:GetFolderResponseMessage>
      </m:ResponseMessages></m:GetFolderResponse></s:Body>
    </s:Envelope>
    """

  private static func requestBody(_ request: URLRequest) throws -> String {
    if let body = request.httpBody {
      return String(data: body, encoding: .utf8) ?? ""
    }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count >= 0 else { throw stream.streamError ?? EWSClientTestError.offline }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    return String(data: data, encoding: .utf8) ?? ""
  }

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
    conversationId: String,
    receivedAtMilliseconds: Int64? = nil
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
      receivedAtMilliseconds:
        receivedAtMilliseconds ?? 1_781_200_000_000 + Int64(number),
      replyTo: [],
      stableProviderId: "ews-stable-\(number)",
      subject: "Message \(number)",
      summary: "Summary \(number)",
      toRecipients: ["Reader <reader@corp.example>"]
    )
  }
}

private final class RecordingEWSBodyCache: GmailMessageBodyCaching {
  private var payloads: [String: ProductSyncEncryptedPayload] = [:]

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
  private var storedBodyRequestCount = 0
  var bodyRequestCount: Int { lock.withLock { storedBodyRequestCount } }
  private let lock = NSLock()
  var folders: [EWSFolder] = EWSFolderRole.allCases.map {
    EWSFolder(
      changeKey: "\($0.rawValue)-key",
      displayName: $0.rawValue,
      id: "\($0.rawValue)-id",
      role: $0
    )
  }
  private var storedLoadedBodyItemId: String?
  var loadedBodyItemId: String? { lock.withLock { storedLoadedBodyItemId } }
  var pages: [String: EWSMessagePage] = [:]
  private var storedPerformedActions: [PerformedAction] = []
  var performedActions: [PerformedAction] { lock.withLock { storedPerformedActions } }
  private var storedPerformedMessageChangeKeys: [[String]] = []
  var performedMessageChangeKeys: [[String]] {
    lock.withLock { storedPerformedMessageChangeKeys }
  }
  var refreshedMessagesByStableId: [String: EWSProviderMessage] = [:]
  private var storedOfflineFailures: [MailboxConnectionId: Int] = [:]
  var remainingOfflineFailuresByConnectionId: [MailboxConnectionId: Int] {
    get { lock.withLock { storedOfflineFailures } }
    set { lock.withLock { storedOfflineFailures = newValue } }
  }
  private var storedActionFailures: [MailboxConnectionId: Int] = [:]
  var remainingActionFailuresByConnectionId: [MailboxConnectionId: Int] {
    get { lock.withLock { storedActionFailures } }
    set { lock.withLock { storedActionFailures = newValue } }
  }
  private var storedRequestedPages: [String] = []
  var requestedPages: [String] { lock.withLock { storedRequestedPages } }
  private var storedSentMessages: [OutgoingMessage] = []
  var sentMessages: [OutgoingMessage] { lock.withLock { storedSentMessages } }
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
    lock.withLock { storedRequestedPages.append(key) }
    return pages[key] ?? EWSMessagePage(messages: [], nextOffset: nil)
  }

  func loadMessageBody(
    itemId: String,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> String {
    return lock.withLock {
      storedBodyRequestCount += 1
      storedLoadedBodyItemId = itemId
      return body
    }
  }

  func refreshMessageIdentities(
    _ messages: [EWSProviderMessage],
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> [EWSProviderMessage] {
    messages.map { refreshedMessagesByStableId[$0.stableProviderId] ?? $0 }
  }

  func perform(
    _ action: ProviderMailAction,
    targetFolderId _: String?,
    messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSMovedItemIdentity] {
    if let error = actionErrorsByConnectionId[authorization.definition.connectionId] {
      throw error
    }
    let connectionId = authorization.definition.connectionId
    let shouldFailOffline = lock.withLock {
      guard let failures = storedOfflineFailures[connectionId],
        failures > 0
      else { return false }
      storedOfflineFailures[connectionId] = failures - 1
      return true
    }
    if shouldFailOffline {
      throw URLError(.notConnectedToInternet)
    }
    let shouldFailAction = lock.withLock {
      guard let failures = storedActionFailures[connectionId],
        failures > 0
      else { return false }
      storedActionFailures[connectionId] = failures - 1
      return true
    }
    if shouldFailAction {
      throw EWSServiceError.response(code: "HTTP 503", message: "Temporarily unavailable")
    }
    lock.withLock {
      storedPerformedActions.append(
        PerformedAction(action: action, connectionId: authorization.definition.connectionId)
      )
      storedPerformedMessageChangeKeys.append(messages.map(\.changeKey))
    }
    return []
  }

  func send(
    _ message: OutgoingMessage,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws {
    lock.withLock { storedSentMessages.append(message) }
  }
}

private final class RecordingEWSDefinitionSyncService: MailboxConnectionDefinitionSyncing,
  @unchecked Sendable
{
  var defaultSendingConnectionId: MailboxConnectionId?
  var didLoadSnapshot: (() -> Void)?
  var loadSnapshotError: Error?
  var providerAccessLoads = 0
  var removedConnectionIds: [MailboxConnectionId] = []
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
    if let loadSnapshotError { throw loadSnapshotError }
    didLoadSnapshot?()
    return snapshot()
  }

  func loadSnapshotForProviderAccess(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    providerAccessLoads += 1
    return snapshot()
  }

  private func snapshot() -> MailboxConnectionSyncSnapshot {
    MailboxConnectionSyncSnapshot(
      connections: savedDefinitions,
      defaultSendingConnectionId: defaultSendingConnectionId,
      removedConnectionIds: removedConnectionIds,
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
      removedConnectionIds: removedConnectionIds,
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
    removedConnectionIds.append(connectionId)
    return snapshot()
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
    return snapshot()
  }

  func setDefaultSendingConnection(
    _ connectionId: MailboxConnectionId?,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    defaultSendingConnectionId = connectionId
    return snapshot()
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
  private static let handlerLock = NSLock()
  private static var storedRequestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
    get { handlerLock.withLock { storedRequestHandler } }
    set { handlerLock.withLock { storedRequestHandler = newValue } }
  }

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
