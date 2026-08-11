import Foundation
import SwiftData
import Testing

@testable import unwired_mail

// swiftlint:disable file_length function_body_length type_body_length

@MainActor
@Suite(.serialized)
final class EWSMailboxConnectionAdapterTests {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "product-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  @Test
  func testProductionEWSSessionRequiresTLS12OrNewer() {
    let session = SystemEWSClient.makeProductionSession()
    defer { session.invalidateAndCancel() }

    #expect(session.configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
  }

  @Test
  func testSwiftDataMetadataStoreMigratesLegacySnapshotWithoutLosingMessages() throws {
    let definition = makeEWSDefinition()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("EWSMetadata.store")
    let expected = EWSMetadataSnapshot(
      folders: [
        EWSFolder(changeKey: "inbox-key", displayName: "Inbox", id: "inbox-id", role: .inbox)
      ],
      messages: [
        ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1"),
        ewsMessage(2, folderId: "inbox-id", conversationId: "conversation-2"),
      ],
      nextOffsetsByFolderId: ["inbox-id": 50],
      hasInitialMailboxAvailability: true
    )
    do {
      let legacySchema = Schema([DurableEWSMetadataSnapshotRecord.self])
      let legacyConfiguration = ModelConfiguration(
        "EWSMetadataMigrationTests",
        schema: legacySchema,
        url: storeURL
      )
      let legacyContainer = try ModelContainer(
        for: legacySchema,
        configurations: [legacyConfiguration]
      )
      let context = ModelContext(legacyContainer)
      context.insert(
        DurableEWSMetadataSnapshotRecord(
          connectionIdRawValue: definition.connectionId.rawValue,
          encodedSnapshot: try JSONEncoder().encode(expected),
          productAccountId: session.productAccountId,
          storageKey: "\(session.productAccountId)\0\(definition.connectionId.rawValue)"
        )
      )
      try context.save()
    }
    let schema = SwiftDataEWSMetadataStore.schema
    let configuration = ModelConfiguration(
      "EWSMetadataMigrationTests",
      schema: schema,
      url: storeURL
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let store = SwiftDataEWSMetadataStore(container: container)

    var migrated = try requireValue(
      store.load(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      ))
    #expect(
      migrated.messages.sorted { $0.stableProviderId < $1.stableProviderId }
        == expected.messages.sorted { $0.stableProviderId < $1.stableProviderId })
    migrated.messages = []
    var expectedState = expected
    expectedState.messages = []
    #expect(migrated == expectedState)

    let migratedContext = ModelContext(container)
    #expect(try migratedContext.fetch(FetchDescriptor<DurableEWSMetadataSnapshotRecord>()).isEmpty)
    #expect(try migratedContext.fetch(FetchDescriptor<DurableEWSMetadataStateRecord>()).count == 1)
    #expect(
      try migratedContext.fetch(FetchDescriptor<DurableEWSMessageMetadataRecord>()).count
        == expected.messages.count)
  }

  @Test
  func testSwiftDataMetadataStoreWritesOnlyIncrementalPageRecords() throws {
    let definition = makeEWSDefinition()
    let schema = SwiftDataEWSMetadataStore.schema
    let configuration = ModelConfiguration(
      "EWSMetadataIncrementalTests",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let store = SwiftDataEWSMetadataStore(container: container)
    let untouched = ewsMessage(4, folderId: "inbox-id", conversationId: "conversation-4")
    let observedIds = Set((0..<200).map { "observed-\($0)" })
    let candidateIds = Set((0..<200).map { "candidate-\($0)" })
    var snapshot = EWSMetadataSnapshot(
      folders: [
        EWSFolder(changeKey: "inbox-key", displayName: "Inbox", id: "inbox-id", role: .inbox)
      ],
      messages: [
        ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1"),
        ewsMessage(2, folderId: "inbox-id", conversationId: "conversation-2"),
        untouched,
      ],
      nextOffsetsByFolderId: ["inbox-id": 50],
      deletionCandidatesByFolderId: ["inbox-id": candidateIds],
      reconciliationMessageIdsByFolderId: ["inbox-id": observedIds],
      hasInitialMailboxAvailability: true
    )
    try store.save(
      snapshot,
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId
    )
    let initialContext = ModelContext(container)
    let initialUntouched = try requireValue(
      try initialContext.fetch(FetchDescriptor<DurableEWSMessageMetadataRecord>())
        .first { $0.stableProviderId == untouched.stableProviderId })
    let initialUntouchedId = initialUntouched.persistentModelID
    let initialUntouchedData = initialUntouched.encodedMessage

    var changed = ewsMessage(2, folderId: "inbox-id", conversationId: "conversation-2")
    changed.isRead = true
    let inserted = ewsMessage(3, folderId: "inbox-id", conversationId: "conversation-3")
    let pageObservedIds: Set<String> = ["page-observed-1", "page-observed-2"]
    snapshot.messages = [changed, inserted, untouched]
    snapshot.nextOffsetsByFolderId = ["inbox-id": 100]
    snapshot.reconciliationMessageIdsByFolderId["inbox-id", default: []]
      .formUnion(pageObservedIds)
    try store.save(
      snapshot,
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId,
      messageChanges: EWSMetadataMessageChanges(
        deletingStableProviderIds: ["ews-stable-1"],
        reconciliationChanges: EWSMetadataReconciliationChanges(
          addingObservedIdsByFolderId: ["inbox-id": pageObservedIds]
        ),
        upserting: [changed, inserted]
      )
    )

    var loaded = try requireValue(
      store.load(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      ))
    loaded.messages.sort { $0.stableProviderId < $1.stableProviderId }
    snapshot.messages.sort { $0.stableProviderId < $1.stableProviderId }
    #expect(loaded == snapshot)
    let finalContext = ModelContext(container)
    let finalUntouched = try requireValue(
      try finalContext.fetch(FetchDescriptor<DurableEWSMessageMetadataRecord>())
        .first { $0.stableProviderId == untouched.stableProviderId })
    #expect(finalUntouched.persistentModelID == initialUntouchedId)
    #expect(finalUntouched.encodedMessage == initialUntouchedData)
    #expect(try finalContext.fetch(FetchDescriptor<DurableEWSMessageMetadataRecord>()).count == 3)
    #expect(
      try finalContext.fetch(FetchDescriptor<DurableEWSReconciliationMetadataRecord>()).count
        == observedIds.count + candidateIds.count + pageObservedIds.count)
    let encodedState = try requireValue(
      try finalContext.fetch(FetchDescriptor<DurableEWSMetadataStateRecord>()).first
    ).encodedState
    let storedState = try JSONDecoder().decode(EWSMetadataSnapshot.self, from: encodedState)
    #expect(storedState.messages.isEmpty)
    #expect(storedState.deletionCandidatesByFolderId?.isEmpty == true)
    #expect(storedState.reconciliationMessageIdsByFolderId.isEmpty)

    snapshot.reconciliationMessageIdsByFolderId = [:]
    snapshot.deletionCandidatesByFolderId = ["inbox-id": pageObservedIds]
    try store.save(
      snapshot,
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId,
      messageChanges: EWSMetadataMessageChanges(
        reconciliationChanges: EWSMetadataReconciliationChanges(
          clearingObservedFolderIds: ["inbox-id"],
          replacingCandidatesByFolderId: ["inbox-id": pageObservedIds]
        ),
        upserting: []
      )
    )
    #expect(
      try store.load(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      )?.deletionCandidatesByFolderId == ["inbox-id": pageObservedIds])
    #expect(
      try ModelContext(container).fetch(
        FetchDescriptor<DurableEWSReconciliationMetadataRecord>()
      ).count == pageObservedIds.count)

    snapshot.deletionCandidatesByFolderId = [:]
    try store.save(
      snapshot,
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId,
      messageChanges: EWSMetadataMessageChanges(
        reconciliationChanges: EWSMetadataReconciliationChanges(
          clearingCandidateFolderIds: ["inbox-id"],
          clearingObservedFolderIds: ["inbox-id"]
        ),
        upserting: []
      )
    )
    let reconciled = try requireValue(
      store.load(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      ))
    #expect(reconciled.deletionCandidatesByFolderId?.isEmpty == true)
    #expect(reconciled.reconciliationMessageIdsByFolderId.isEmpty)
    #expect(
      try ModelContext(container).fetch(
        FetchDescriptor<DurableEWSReconciliationMetadataRecord>()
      ).isEmpty)
  }

  @Test
  func testInMemoryMetadataStoreAppliesMatchingIncrementalChanges() throws {
    let definition = makeEWSDefinition()
    let store = InMemoryEWSMetadataStore()
    let first = ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")
    let second = ewsMessage(2, folderId: "inbox-id", conversationId: "conversation-2")
    var initial = snapshot(message: first)
    initial.reconciliationMessageIdsByFolderId = ["inbox-id": [first.stableProviderId]]
    try store.save(
      initial,
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId
    )
    var updated = initial
    updated.messages = [second]
    updated.reconciliationMessageIdsByFolderId = ["inbox-id": [second.stableProviderId]]

    try store.save(
      updated,
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId,
      messageChanges: EWSMetadataMessageChanges(
        deletingStableProviderIds: [first.stableProviderId],
        reconciliationChanges: EWSMetadataReconciliationChanges(
          addingObservedIdsByFolderId: ["inbox-id": [second.stableProviderId]],
          clearingObservedFolderIds: ["inbox-id"]
        ),
        upserting: [second]
      )
    )

    #expect(
      try store.load(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      ) == updated)
  }

  @Test
  func testInMemoryMetadataStoreRejectsMismatchedIncrementalChanges() throws {
    let definition = makeEWSDefinition()
    let store = InMemoryEWSMetadataStore()
    let first = ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")
    let second = ewsMessage(2, folderId: "inbox-id", conversationId: "conversation-2")
    let initial = snapshot(message: first)
    try store.save(
      initial,
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId
    )
    var mismatched = initial
    mismatched.messages = [second]

    #expect {
      try store.save(
        mismatched,
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId,
        messageChanges: EWSMetadataMessageChanges(upserting: [])
      )
    } throws: { error in
      guard case InMemoryEWSMetadataStore.ConsistencyError.incrementalSnapshotMismatch = error
      else {
        Issue.record("Unexpected error: \(error)")
        return true
      }
      return true
    }
  }

  @Test
  func testEWSOAuthRequestUsesPKCEAndPreservesConfiguredAuthorizationQuery() throws {
    let request = try EWSOAuthRequest(
      configuration: EWSOAuthConfiguration(
        authorizationEndpoint: URL(
          string: "https://login.corp.example/authorize?tenant=mail"
        )!,
        callbackScheme: "unwired-ews",
        clientIdentifier: "ews-client",
        scope: "openid offline_access EWS.AccessAsUser.All",
        tokenEndpoint: URL(string: "https://login.corp.example/token")!
      ),
      codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
      state: "expected-state"
    )
    let query = try requireValue(
      URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems
    ).reduce(into: [String: String]()) { result, item in
      result[item.name] = item.value
    }

    #expect(query["tenant"] == "mail")
    #expect(query["client_id"] == "ews-client")
    #expect(query["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(query["code_challenge_method"] == "S256")
    #expect(query["redirect_uri"] == "unwired-ews://auth")
    #expect(query["response_type"] == "code")
    #expect(query["scope"] == "openid offline_access EWS.AccessAsUser.All")
    #expect(query["state"] == "expected-state")
    #expect(
      try request.authorizationCode(
        from: URL(string: "unwired-ews://auth?code=authorization-code&state=expected-state")!
      ) == "authorization-code")
    #expect {
      try request.authorizationCode(
        from: URL(string: "unwired-ews://auth?code=authorization-code&state=wrong-state")!
      )
    } throws: { error in
      #expect(error as? EWSOAuthError == .invalidAuthorizationState)
      return true
    }
    for callback in [
      "other-scheme://auth?code=authorization-code&state=expected-state",
      "unwired-ews://other-host?code=authorization-code&state=expected-state",
      "unwired-ews://auth?code=&state=expected-state",
      "unwired-ews://auth?state=expected-state",
    ] {
      let callbackURL = try requireValue(URL(string: callback))
      #expect {
        try request.authorizationCode(from: callbackURL)
      } throws: { error in
        #expect(error as? EWSOAuthError == .invalidAuthorizationCallback)
        return true
      }
    }
  }

  @Test
  func testEWSOAuthRefreshExchangesAndRotatesTheRefreshToken() async throws {
    var capturedRequest: URLRequest?
    EWSURLProtocol.requestHandler = { request in
      capturedRequest = request
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(
          #"{"access_token":"fresh-access","expires_in":3600,"refresh_token":"rotated-refresh"}"#
            .utf8
        )
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }
    let service = EWSOAuthService(
      configuration: try makeEWSOAuthConfiguration(),
      now: { Date(timeIntervalSince1970: 1_781_200_000) },
      session: makeEWSURLSession()
    )

    let refreshed = try await service.refresh(
      EWSOAuthTokens(
        accessToken: "old-access",
        expiresAtMilliseconds: 1_781_199_000_000,
        refreshToken: "old-refresh"
      )
    )

    #expect(
      refreshed
        == EWSOAuthTokens(
          accessToken: "fresh-access",
          expiresAtMilliseconds: 1_781_203_600_000,
          refreshToken: "rotated-refresh"
        ))
    let request = try requireValue(capturedRequest)
    #expect(request.url == URL(string: "https://login.corp.example/token"))
    #expect(request.httpMethod == "POST")
    let body = String(data: try requireValue(try ewsRequestBody(request)), encoding: .utf8) ?? ""
    #expect(body.contains("client_id=ews-client"))
    #expect(body.contains("grant_type=refresh_token"))
    #expect(body.contains("refresh_token=old-refresh"))
    #expect(body.contains("scope=openid%20offline_access%20EWS.AccessAsUser.All"))
    #expect(!(body.contains("client_secret")))
    #expect(!(body.contains("secret=")))
  }

  @Test
  func testEWSOAuthRefreshMapsRejectedGrantToReauthorization() async throws {
    EWSURLProtocol.requestHandler = { request in
      (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 400,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(#"{"error":"invalid_grant"}"#.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }
    let service = EWSOAuthService(
      configuration: try makeEWSOAuthConfiguration(),
      session: makeEWSURLSession()
    )

    do {
      _ = try await service.refresh(
        EWSOAuthTokens(
          accessToken: "old-access",
          expiresAtMilliseconds: 0,
          refreshToken: "rejected-refresh"
        )
      )
      Issue.record("Expected invalid_grant to require authorization")
    } catch {
      #expect(error as? EWSOAuthError == .authorizationRejected)
    }
  }

  @Test
  func testEWSOAuthRefreshPreservesTransientServerFailure() async throws {
    EWSURLProtocol.requestHandler = { request in
      (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 503,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data()
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }
    let service = EWSOAuthService(
      configuration: try makeEWSOAuthConfiguration(),
      session: makeEWSURLSession()
    )

    do {
      _ = try await service.refresh(
        EWSOAuthTokens(
          accessToken: "old-access",
          expiresAtMilliseconds: 0,
          refreshToken: "preserved-refresh"
        )
      )
      Issue.record("Expected a transient token endpoint failure")
    } catch {
      #expect(error as? EWSOAuthError == .tokenExchangeFailed(status: 503))
      #expect(error as? EWSOAuthError != .authorizationRejected)
    }
  }

  @Test
  func testSetupAcceptsOnlyHTTPSOnPremisesEndpoints() throws {
    #expect(throws: Never.self) {
      try EWSConnectionDefinition.validatedEndpoint(
        "https://mail.corp.example/EWS/Exchange.asmx"
      )
    }

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
      #expect {
        try EWSConnectionDefinition.validatedEndpoint(endpoint)
      } throws: {
        #expect($0 as? EWSSetupError == .onPremisesEndpointRequired)
        return true
      }
    }
  }

  @Test
  func testConnectionIdentityIncludesEffectiveEndpointPort() throws {
    let standard = try EWSConnectionDefinition.stableProviderAccountIdentifier(
      endpoint: requireValue(URL(string: "https://mail.corp.example/EWS/Exchange.asmx")),
      mailboxIdentifier: "mailbox-id"
    )
    let explicitStandard = try EWSConnectionDefinition.stableProviderAccountIdentifier(
      endpoint: requireValue(URL(string: "https://mail.corp.example:443/EWS/Exchange.asmx")),
      mailboxIdentifier: "mailbox-id"
    )
    let alternate = try EWSConnectionDefinition.stableProviderAccountIdentifier(
      endpoint: requireValue(URL(string: "https://mail.corp.example:8443/EWS/Exchange.asmx")),
      mailboxIdentifier: "mailbox-id"
    )

    #expect(standard == explicitStandard)
    #expect(standard != alternate)
  }

  @Test
  func testEWSSetupDiscardRestoresTheSavedEditorBaseline() {
    let viewModel = EWSSetupViewModel(
      isSessionCurrent: { $0 == self.session },
      session: session
    )

    #expect(!(viewModel.hasUnsavedChanges))
    viewModel.emailAddress = "draft@corp.example"
    viewModel.endpoint = "https://mail.corp.example/EWS/Exchange.asmx"
    #expect(viewModel.hasUnsavedChanges)

    viewModel.discardUnsavedChanges()

    #expect(!(viewModel.hasUnsavedChanges))
    #expect(viewModel.emailAddress == "")
    #expect(viewModel.endpoint == "")
  }

  @Test
  func testEWSSetupConnectStopsWhenTrustedDeviceRevalidationFails() async {
    var revalidationCount = 0
    let viewModel = EWSSetupViewModel(
      isSessionCurrent: { $0 == self.session },
      revalidateTrustedDevice: {
        revalidationCount += 1
        return false
      },
      session: session
    )

    let connection = await viewModel.connect()

    #expect(connection == nil)
    #expect(revalidationCount == 1)
  }

  @Test
  func testSetupUsesVerifiedMailboxIdentityAcrossAliases() async throws {
    let client = RecordingEWSClient()
    let service = EWSSetupService(
      authorizationStore: InMemoryEWSAuthorizationStore(),
      client: client,
      definitionSyncService: RecordingEWSDefinitionSyncService()
    )
    let first = try await service.connect(
      authorizationMethod: .password,
      credential: "password",
      emailAddress: "reader@corp.example",
      endpoint: "https://mail.corp.example/EWS/Exchange.asmx",
      username: #"CORP\reader"#,
      session: session,
      isSessionCurrent: { _ in true }
    )
    let second = try await service.connect(
      authorizationMethod: .password,
      credential: "password",
      emailAddress: "alias@corp.example",
      endpoint: "https://mail.corp.example/EWS/Exchange.asmx",
      username: #"CORP\reader"#,
      session: session,
      isSessionCurrent: { _ in true }
    )

    #expect(first.id == second.id)
  }

  @Test
  func testEWSSetupViewModelRerunsLoadRequestedWhileWorking() async {
    let firstLoad = TestRendezvous()
    let definitions = RecordingEWSDefinitionSyncService()
    var shouldHoldFirstLoad = true
    definitions.beforeLoadSnapshotReturn = {
      guard shouldHoldFirstLoad else { return }
      shouldHoldFirstLoad = false
      await firstLoad.hold()
    }
    let viewModel = EWSSetupViewModel(
      definitionSyncService: definitions,
      isSessionCurrent: { $0 == self.session },
      session: session
    )
    let initialLoad = Task { await viewModel.load() }
    await firstLoad.waitUntilHeld()
    let requestedRefresh = Task { await viewModel.load() }

    await firstLoad.release()
    await initialLoad.value
    await requestedRefresh.value

    #expect(definitions.loadSnapshotCallCount == 2)
  }

  @Test
  func testEWSSetupViewModelRequiresExplicitRecreationRetry() async throws {
    let definitions = RecordingEWSDefinitionSyncService()
    let client = RecordingEWSClient()
    let providerAccountIdentifier = try EWSConnectionDefinition.stableProviderAccountIdentifier(
      endpoint: requireValue(URL(string: "https://mail.corp.example/EWS/Exchange.asmx")),
      mailboxIdentifier: client.account.providerMailboxIdentifier
    )
    let removalObservation = MailboxConnectionRemovalObservation(
      connectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .exchangeWebServices,
          value: providerAccountIdentifier
        )
      ),
      removedAt: 1_781_200_000_500
    )
    definitions.recreateError = MailboxConnectionSyncError.connectionRemoved(removalObservation)
    definitions.removedConnectionIds = [removalObservation.connectionId]
    let authorizations = InMemoryEWSAuthorizationStore()
    let localDefinition = EWSConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "reader@corp.example",
      endpoint: URL(string: "https://mail.corp.example/EWS/Exchange.asmx")!,
      providerAccountIdentifier: providerAccountIdentifier,
      serverVersion: client.account.serverVersion,
      username: #"CORP\reader"#
    )
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "old-password", definition: localDefinition),
      productAccountId: session.productAccountId
    )
    let service = EWSSetupService(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: definitions
    )
    let viewModel = EWSSetupViewModel(
      adapter: EWSMailboxConnectionAdapter(
        authorizationStore: authorizations,
        client: client,
        definitionSyncService: definitions,
        metadataStore: InMemoryEWSMetadataStore()
      ),
      authorizationStore: authorizations,
      definitionSyncService: definitions,
      isSessionCurrent: { $0 == self.session },
      service: service,
      session: session
    )
    viewModel.credential = "password"
    viewModel.emailAddress = "reader@corp.example"
    viewModel.endpoint = "https://mail.corp.example/EWS/Exchange.asmx"
    viewModel.username = #"CORP\reader"#

    let firstAttempt = await viewModel.connect()

    #expect(firstAttempt == nil)
    #expect(viewModel.isConfirmingRecreation)
    #expect(definitions.recreateDefinitionCount == 1)
    #expect(definitions.recreationObservation == nil)
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: removalObservation.connectionId
      ) == nil)

    definitions.recreateError = nil
    viewModel.credential = "new-password"
    let recreatedConnection = await viewModel.connect()

    #expect(recreatedConnection?.id == removalObservation.connectionId)
    #expect(definitions.recreationObservation == removalObservation)
    #expect(!(viewModel.isConfirmingRecreation))

    viewModel.credential = "newer-password"
    _ = await viewModel.connect()

    #expect(definitions.recreateDefinitionCount == 2)
  }

  @Test
  func testEWSSetupDiscardClearsPendingRecreation() async throws {
    let definitions = RecordingEWSDefinitionSyncService()
    let client = RecordingEWSClient()
    let providerAccountIdentifier = try EWSConnectionDefinition.stableProviderAccountIdentifier(
      endpoint: requireValue(URL(string: "https://mail.corp.example/EWS/Exchange.asmx")),
      mailboxIdentifier: client.account.providerMailboxIdentifier
    )
    let removalObservation = MailboxConnectionRemovalObservation(
      connectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .exchangeWebServices,
          value: providerAccountIdentifier
        )
      ),
      removedAt: 1_781_200_000_500
    )
    definitions.recreateError = MailboxConnectionSyncError.connectionRemoved(removalObservation)
    definitions.removedConnectionIds = [removalObservation.connectionId]
    let authorizations = InMemoryEWSAuthorizationStore()
    let viewModel = EWSSetupViewModel(
      adapter: EWSMailboxConnectionAdapter(
        authorizationStore: authorizations,
        client: client,
        definitionSyncService: definitions,
        metadataStore: InMemoryEWSMetadataStore()
      ),
      authorizationStore: authorizations,
      definitionSyncService: definitions,
      isSessionCurrent: { $0 == self.session },
      service: EWSSetupService(
        authorizationStore: authorizations,
        client: client,
        definitionSyncService: definitions
      ),
      session: session
    )
    viewModel.credential = "password"
    viewModel.emailAddress = "reader@corp.example"
    viewModel.endpoint = "https://mail.corp.example/EWS/Exchange.asmx"
    viewModel.username = #"CORP\reader"#
    _ = await viewModel.connect()
    #expect(viewModel.isConfirmingRecreation)

    viewModel.discardUnsavedChanges()

    #expect(!(viewModel.isConfirmingRecreation))
  }

  @Test
  func testEWSSetupViewModelClearsStaleConfirmationAfterConcurrentRecreation() async throws {
    let definitions = RecordingEWSDefinitionSyncService()
    let client = RecordingEWSClient()
    let providerAccountIdentifier = try EWSConnectionDefinition.stableProviderAccountIdentifier(
      endpoint: requireValue(URL(string: "https://mail.corp.example/EWS/Exchange.asmx")),
      mailboxIdentifier: client.account.providerMailboxIdentifier
    )
    let removalObservation = MailboxConnectionRemovalObservation(
      connectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .exchangeWebServices,
          value: providerAccountIdentifier
        )
      ),
      removedAt: 1_781_200_000_500
    )
    definitions.recreateError = MailboxConnectionSyncError.connectionRemoved(removalObservation)
    definitions.removedConnectionIds = [removalObservation.connectionId]
    let authorizations = InMemoryEWSAuthorizationStore()
    let viewModel = EWSSetupViewModel(
      adapter: EWSMailboxConnectionAdapter(
        authorizationStore: authorizations,
        client: client,
        definitionSyncService: definitions,
        metadataStore: InMemoryEWSMetadataStore()
      ),
      authorizationStore: authorizations,
      definitionSyncService: definitions,
      isSessionCurrent: { $0 == self.session },
      service: EWSSetupService(
        authorizationStore: authorizations,
        client: client,
        definitionSyncService: definitions
      ),
      session: session
    )
    viewModel.credential = "password"
    viewModel.emailAddress = "reader@corp.example"
    viewModel.endpoint = "https://mail.corp.example/EWS/Exchange.asmx"
    viewModel.username = #"CORP\reader"#
    _ = await viewModel.connect()
    #expect(viewModel.isConfirmingRecreation)

    definitions.recreateError = MailboxConnectionSyncError.concurrentModification
    viewModel.credential = "password"
    _ = await viewModel.connect()

    #expect(!(viewModel.isConfirmingRecreation))

    definitions.recreateError = nil
    viewModel.credential = "password"
    _ = await viewModel.connect()

    #expect(definitions.recreationObservation == nil)
    #expect(!(viewModel.isConfirmingRecreation))
  }

  @Test
  func testEWSRedirectsAndCredentialChallengesStayOnConfiguredOrigin() {
    let endpoint = URL(string: "https://mail.corp.example/EWS/Exchange.asmx")!

    #expect(
      EWSConnectionDefinition.hasSameOrigin(
        URL(string: "https://MAIL.corp.example:443/EWS/redirected")!,
        as: endpoint
      ))
    #expect(
      !(EWSConnectionDefinition.hasSameOrigin(
        URL(string: "https://login.corp.example/EWS/Exchange.asmx")!,
        as: endpoint
      )))
    #expect(
      !(EWSConnectionDefinition.hasSameOrigin(
        URL(string: "https://mail.corp.example:8443/EWS/Exchange.asmx")!,
        as: endpoint
      )))
  }

  @Test
  func testEWSOAuthTokenExchangeRejectsCrossOrigin307And308Redirects() throws {
    let tokenEndpoint = try requireValue(URL(string: "https://login.corp.example/token"))
    let redirectedRequest = URLRequest(
      url: try requireValue(URL(string: "https://attacker.example/token"))
    )

    for statusCode in [307, 308] {
      let response = try requireValue(
        HTTPURLResponse(
          url: tokenEndpoint,
          statusCode: statusCode,
          httpVersion: nil,
          headerFields: ["Location": "https://attacker.example/token"]
        ))
      #expect(
        EWSOAuthTokenRedirectPolicy.redirectedRequest(
          redirectedRequest,
          response: response,
          tokenEndpoint: tokenEndpoint
        ) == nil)
    }

    let sameOriginRequest = URLRequest(
      url: try requireValue(URL(string: "https://login.corp.example/token/v2"))
    )
    for statusCode in [307, 308] {
      let response = try requireValue(
        HTTPURLResponse(
          url: tokenEndpoint,
          statusCode: statusCode,
          httpVersion: nil,
          headerFields: nil
        ))
      #expect(
        EWSOAuthTokenRedirectPolicy.redirectedRequest(
          sameOriginRequest,
          response: response,
          tokenEndpoint: tokenEndpoint
        )?.url == sameOriginRequest.url)
    }

    let seeOther = try requireValue(
      HTTPURLResponse(
        url: tokenEndpoint,
        statusCode: 303,
        httpVersion: nil,
        headerFields: nil
      ))
    #expect(
      EWSOAuthTokenRedirectPolicy.redirectedRequest(
        sameOriginRequest,
        response: seeOther,
        tokenEndpoint: tokenEndpoint
      ) == nil)
  }

  @Test
  func testEWSCapabilitiesDoNotAdvertiseUnimplementedProviderOperations() {
    #expect(!(MailboxConnectionCapabilities.exchangeWebServices.canCategorizeHistorical))
    #expect(!(MailboxConnectionCapabilities.exchangeWebServices.canSearchProvider))
  }

  @Test
  func testEWSOAuthSetupUsesBrowserTokensAndPersistsRefreshCredential() async throws {
    let tokens = EWSOAuthTokens(
      accessToken: "access-token",
      expiresAtMilliseconds: 1_781_200_300_000,
      refreshToken: "refresh-token"
    )
    let oauthService = RecordingEWSOAuthService(authorization: tokens)
    let client = RecordingEWSClient()
    let authorizations = InMemoryEWSAuthorizationStore()
    let definitions = RecordingEWSDefinitionSyncService()
    let service = EWSSetupService(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: definitions,
      oauthService: oauthService
    )

    let connection = try await service.connect(
      authorizationMethod: .oauth,
      credential: "",
      emailAddress: "reader@corp.example",
      endpoint: "https://mail.corp.example/EWS/Exchange.asmx",
      username: #"CORP\reader"#,
      session: session,
      isSessionCurrent: { $0 == self.session }
    )

    #expect(oauthService.authorizationCount == 1)
    #expect(client.verifiedAuthorization?.credential == "access-token")
    #expect(client.verifiedAuthorization?.oauthTokens == tokens)
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )?.oauthTokens == tokens)
    let encodedDefinition = try JSONEncoder().encode(requireValue(definitions.savedDefinition))
    let synchronizedPayload = String(bytes: encodedDefinition, encoding: .utf8) ?? ""
    #expect(!(synchronizedPayload.contains(tokens.accessToken)))
    #expect(!(synchronizedPayload.contains(tokens.refreshToken)))
  }

  @Test
  func testEWSRefreshesExpiringOAuthBeforeProviderAccessAndPersistsRotation() async throws {
    let passwordDefinition = makeEWSDefinition()
    let definition = EWSConnectionDefinition(
      authorizationMethod: .oauth,
      emailAddress: passwordDefinition.emailAddress,
      endpoint: passwordDefinition.endpoint,
      providerAccountIdentifier: passwordDefinition.providerAccountIdentifier,
      serverVersion: passwordDefinition.serverVersion,
      username: passwordDefinition.username
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(
        credential: "expiring-access-token",
        definition: definition,
        oauthTokens: EWSOAuthTokens(
          accessToken: "expiring-access-token",
          expiresAtMilliseconds: 1_781_200_100_000,
          refreshToken: "old-refresh-token"
        )
      ),
      productAccountId: session.productAccountId
    )
    let rotatedTokens = EWSOAuthTokens(
      accessToken: "fresh-access-token",
      expiresAtMilliseconds: 1_781_203_600_000,
      refreshToken: "rotated-refresh-token"
    )
    let oauthService = RecordingEWSOAuthService(
      authorization: rotatedTokens,
      refreshResult: .success(rotatedTokens)
    )
    let client = RecordingEWSClient()
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
      now: { Date(timeIntervalSince1970: 1_781_200_000) },
      oauthService: oauthService
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)

    #expect(oauthService.refreshCount == 1)
    #expect(client.loadedFolderAuthorizationCredentials == ["fresh-access-token"])
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )?.oauthTokens == rotatedTokens)
  }

  @Test
  func testEWSKeepsOAuthTokenOutsideRefreshLeewayForProviderAccess() async throws {
    let passwordDefinition = makeEWSDefinition()
    let definition = EWSConnectionDefinition(
      authorizationMethod: .oauth,
      emailAddress: passwordDefinition.emailAddress,
      endpoint: passwordDefinition.endpoint,
      providerAccountIdentifier: passwordDefinition.providerAccountIdentifier,
      serverVersion: passwordDefinition.serverVersion,
      username: passwordDefinition.username
    )
    let tokens = EWSOAuthTokens(
      accessToken: "stored-access-token",
      expiresAtMilliseconds: 1_781_203_600_000,
      refreshToken: "stored-refresh-token"
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(
        credential: tokens.accessToken,
        definition: definition,
        oauthTokens: tokens
      ),
      productAccountId: session.productAccountId
    )
    let oauthService = RecordingEWSOAuthService(authorization: tokens)
    let client = RecordingEWSClient()
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
      now: { Date(timeIntervalSince1970: 1_781_200_000) },
      oauthService: oauthService
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)

    #expect(oauthService.refreshCount == 0)
    #expect(client.loadedFolderAuthorizationCredentials == [tokens.accessToken])
  }

  @Test
  func testEWSRejectedRefreshClearsCredentialAndRequiresAuthorization() async throws {
    let passwordDefinition = makeEWSDefinition()
    let definition = EWSConnectionDefinition(
      authorizationMethod: .oauth,
      emailAddress: passwordDefinition.emailAddress,
      endpoint: passwordDefinition.endpoint,
      providerAccountIdentifier: passwordDefinition.providerAccountIdentifier,
      serverVersion: passwordDefinition.serverVersion,
      username: passwordDefinition.username
    )
    let tokens = EWSOAuthTokens(
      accessToken: "expired-access-token",
      expiresAtMilliseconds: 0,
      refreshToken: "rejected-refresh-token"
    )
    let authorization = DeviceLocalEWSAuthorization(
      credential: tokens.accessToken,
      definition: definition,
      oauthTokens: tokens
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(authorization, productAccountId: session.productAccountId)
    let oauthService = RecordingEWSOAuthService(
      authorization: tokens,
      refreshResult: .failure(EWSOAuthError.authorizationRejected)
    )
    let coordinator = EWSOAuthRefreshCoordinator(
      authorizationStore: authorizations,
      now: { Date(timeIntervalSince1970: 1_781_200_000) },
      oauthService: oauthService
    )

    do {
      _ = try await coordinator.refreshIfNeeded(
        authorization,
        productAccountId: session.productAccountId
      )
      Issue.record("Expected a rejected refresh to require authorization")
    } catch {
      #expect(error as? MailboxConnectionAdapterError == .authorizationRequired)
    }
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      ) == nil)
  }

  @Test
  func testEWSTransientRefreshFailurePreservesAuthorization() async throws {
    let passwordDefinition = makeEWSDefinition()
    let definition = EWSConnectionDefinition(
      authorizationMethod: .oauth,
      emailAddress: passwordDefinition.emailAddress,
      endpoint: passwordDefinition.endpoint,
      providerAccountIdentifier: passwordDefinition.providerAccountIdentifier,
      serverVersion: passwordDefinition.serverVersion,
      username: passwordDefinition.username
    )
    let tokens = EWSOAuthTokens(
      accessToken: "expired-access-token",
      expiresAtMilliseconds: 0,
      refreshToken: "preserved-refresh-token"
    )
    let authorization = DeviceLocalEWSAuthorization(
      credential: tokens.accessToken,
      definition: definition,
      oauthTokens: tokens
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(authorization, productAccountId: session.productAccountId)
    let oauthService = RecordingEWSOAuthService(
      authorization: tokens,
      refreshResult: .failure(EWSOAuthError.tokenExchangeFailed(status: 503))
    )
    let coordinator = EWSOAuthRefreshCoordinator(
      authorizationStore: authorizations,
      now: { Date(timeIntervalSince1970: 1_781_200_000) },
      oauthService: oauthService
    )

    do {
      _ = try await coordinator.refreshIfNeeded(
        authorization,
        productAccountId: session.productAccountId
      )
      Issue.record("Expected a transient refresh failure")
    } catch {
      #expect(error as? EWSOAuthError == .tokenExchangeFailed(status: 503))
    }
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      )?.oauthTokens == tokens)
  }

  @Test
  func testEWSConcurrentRefreshCallersShareOneTokenExchange() async throws {
    let passwordDefinition = makeEWSDefinition()
    let definition = EWSConnectionDefinition(
      authorizationMethod: .oauth,
      emailAddress: passwordDefinition.emailAddress,
      endpoint: passwordDefinition.endpoint,
      providerAccountIdentifier: passwordDefinition.providerAccountIdentifier,
      serverVersion: passwordDefinition.serverVersion,
      username: passwordDefinition.username
    )
    let expiringTokens = EWSOAuthTokens(
      accessToken: "expiring-access-token",
      expiresAtMilliseconds: 0,
      refreshToken: "old-refresh-token"
    )
    let authorization = DeviceLocalEWSAuthorization(
      credential: expiringTokens.accessToken,
      definition: definition,
      oauthTokens: expiringTokens
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(authorization, productAccountId: session.productAccountId)
    let freshTokens = EWSOAuthTokens(
      accessToken: "fresh-access-token",
      expiresAtMilliseconds: 1_781_203_600_000,
      refreshToken: "rotated-refresh-token"
    )
    let refreshGate = TestRendezvous()
    let joinBarrier = TestBarrier(participantCount: 3)
    let oauthService = RecordingEWSOAuthService(
      authorization: freshTokens,
      refreshResult: .success(freshTokens)
    )
    oauthService.beforeRefreshReturn = { await refreshGate.hold() }
    let coordinator = EWSOAuthRefreshCoordinator(
      authorizationStore: authorizations,
      now: { Date(timeIntervalSince1970: 1_781_200_000) },
      oauthService: oauthService,
      onRefreshTaskJoined: { await joinBarrier.arriveAndWait() }
    )

    async let first = coordinator.refreshIfNeeded(
      authorization,
      productAccountId: session.productAccountId
    )
    await refreshGate.waitUntilHeld()
    async let second = coordinator.refreshIfNeeded(
      authorization,
      productAccountId: session.productAccountId
    )
    async let third = coordinator.refreshIfNeeded(
      authorization,
      productAccountId: session.productAccountId
    )
    await joinBarrier.arriveAndWait()
    await refreshGate.release()
    let (firstResult, secondResult, thirdResult) = try await (first, second, third)

    #expect(
      [firstResult.oauthTokens, secondResult.oauthTokens, thirdResult.oauthTokens] == [
        freshTokens, freshTokens, freshTokens,
      ])
    #expect(oauthService.refreshCount == 1)
  }

  @Test
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
      saveIntent: .add(after: nil),
      username: #"CORP\reader"#,
      session: session,
      isSessionCurrent: { $0 == self.session }
    )

    #expect(connection.providerId == .exchangeWebServices)
    #expect(connection.authorizationState == .authorized)
    #expect(connection.capabilities == .exchangeWebServices)
    #expect(connection.displayName == "reader@corp.example")
    #expect(client.verifiedAuthorization?.credential == " private-password ")
    #expect(definitions.savedDefinition?.provider == "exchange-web-services")
    #expect(definitions.savedDefinition?.displayName == "reader@corp.example")
    #expect(definitions.savedDefinition?.ewsDefinition?.serverVersion == .exchange2019)
    #expect(definitions.recreatedDefinition?.id == connection.id)
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )?.credential == " private-password ")

    let encoded = try JSONEncoder().encode(definitions.savedDefinition)
    #expect(!((String(bytes: encoded, encoding: .utf8) ?? "").contains("private-password")))
  }

  @Test
  func testEWSConnectionRequiresAuthorizationForAnOlderConnectionGeneration() async throws {
    let definition = makeEWSDefinition()
    let synchronizedDefinition = definition.synchronizedDefinition(
      authorizationGeneration: 1,
      connectedAt: 1_781_200_000_000,
      displayName: definition.emailAddress
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(
        authorizationGeneration: 0,
        credential: "password",
        definition: definition
      ),
      productAccountId: session.productAccountId
    )
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      client: RecordingEWSClient(),
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definition: synchronizedDefinition
      ),
      metadataStore: InMemoryEWSMetadataStore()
    )

    let staleConnections = try await adapter.loadConnections(session: session)
    let staleConnection = try requireValue(staleConnections.first)
    try authorizations.save(
      DeviceLocalEWSAuthorization(
        authorizationGeneration: 1,
        credential: "password",
        definition: definition
      ),
      productAccountId: session.productAccountId
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
  func testEWSSendHoldsConnectionGateUntilProviderOperationFinishes() async throws {
    let definition = makeEWSDefinition()
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let client = RecordingEWSClient()
    let providerGate = TestRendezvous()
    client.beforeSendReturn = {
      await providerGate.hold()
    }
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definition: definition.synchronizedDefinition(
          authorizationGeneration: 0,
          connectedAt: 1_781_200_000_000,
          displayName: definition.emailAddress
        )
      ),
      metadataStore: InMemoryEWSMetadataStore(),
      outboxService: OutboxDeliveryService(store: EWSOutboxStore()),
      pendingActionService: PendingProviderActionService(store: EWSActionStore()),
      syncGate: MailboxConnectionSyncGate()
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
    try await Task.sleep(for: .milliseconds(20))
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
  func testEWSReauthorizationPurgesStaleGenerationBeforeSavingFreshAuthorization() async throws {
    let endpoint = try requireValue(URL(string: "https://mail.corp.example/EWS/Exchange.asmx"))
    let definition = EWSConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "reader@corp.example",
      endpoint: endpoint,
      providerAccountIdentifier: try EWSConnectionDefinition.stableProviderAccountIdentifier(
        endpoint: endpoint,
        mailboxIdentifier: "mailbox-id"
      ),
      serverVersion: .exchange2019,
      username: #"CORP\reader"#
    )
    let synchronizedDefinition = definition.synchronizedDefinition(
      authorizationGeneration: 1,
      connectedAt: 1_781_200_000_000,
      displayName: definition.emailAddress
    )
    let definitions = RecordingEWSDefinitionSyncService(
      authorizationCleanupConnectionIds: [definition.connectionId],
      definition: synchronizedDefinition,
      localCleanupGenerations: [definition.connectionId: 1]
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(
        authorizationGeneration: 0,
        credential: "stale-password",
        definition: definition
      ),
      productAccountId: session.productAccountId
    )
    let localStateCleaner = RecordingEWSLocalStateCleaner()
    let service = EWSSetupService(
      authorizationStore: authorizations,
      client: RecordingEWSClient(),
      definitionSyncService: definitions,
      localStateCleaner: localStateCleaner,
      syncGate: MailboxConnectionSyncGate()
    )

    let connection = try await service.connect(
      authorizationMethod: .password,
      credential: "fresh-password",
      emailAddress: definition.emailAddress,
      endpoint: definition.endpoint.absoluteString,
      username: definition.username,
      session: session,
      isSessionCurrent: { $0 == self.session }
    )

    #expect(localStateCleaner.clearedConnectionIds == [definition.connectionId])
    #expect(connection.authorizationGeneration == 1)
    #expect(definitions.completedCleanupGenerations[definition.connectionId] == 1)
  }

  @Test
  func testEWSReauthorizationDoesNotRestoreAuthorizationAfterSessionCleanup() async throws {
    let definition = try makeVerifiedEWSDefinition()
    let synchronizedDefinition = definition.synchronizedDefinition(
      authorizationGeneration: 1,
      connectedAt: 1_781_200_000_000,
      displayName: definition.emailAddress
    )
    let definitions = RecordingEWSDefinitionSyncService(
      authorizationCleanupConnectionIds: [definition.connectionId],
      definition: synchronizedDefinition,
      localCleanupGenerations: [definition.connectionId: 1]
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(
        authorizationGeneration: 0,
        credential: "stale-password",
        definition: definition
      ),
      productAccountId: session.productAccountId
    )
    let cleanupGate = TestRendezvous()
    let localStateCleaner = RecordingEWSLocalStateCleaner()
    localStateCleaner.onClear = {
      try authorizations.clear(
        productAccountId: self.session.productAccountId,
        connectionId: definition.connectionId
      )
      await cleanupGate.hold()
    }
    let service = EWSSetupService(
      authorizationStore: authorizations,
      client: RecordingEWSClient(),
      definitionSyncService: definitions,
      localStateCleaner: localStateCleaner,
      syncGate: MailboxConnectionSyncGate()
    )
    var sessionIsCurrent = true
    let setup = Task {
      try await service.connect(
        authorizationMethod: .password,
        credential: "fresh-password",
        emailAddress: definition.emailAddress,
        endpoint: definition.endpoint.absoluteString,
        username: definition.username,
        session: session,
        isSessionCurrent: { _ in sessionIsCurrent }
      )
    }
    await cleanupGate.waitUntilHeld()
    sessionIsCurrent = false
    await cleanupGate.release()

    do {
      _ = try await setup.value
      Issue.record("Expected session cleanup to cancel authorization persistence")
    } catch is CancellationError {
    }
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      ) == nil)
  }

  @Test
  func testEWSReauthorizationWaitsForInFlightProviderWorkBeforeCleanup() async throws {
    let definition = try makeVerifiedEWSDefinition()
    let synchronizedDefinition = definition.synchronizedDefinition(
      authorizationGeneration: 1,
      connectedAt: 1_781_200_000_000,
      displayName: definition.emailAddress
    )
    let definitions = RecordingEWSDefinitionSyncService(
      authorizationCleanupConnectionIds: [definition.connectionId],
      definition: synchronizedDefinition,
      localCleanupGenerations: [definition.connectionId: 1]
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(
        authorizationGeneration: 0,
        credential: "stale-password",
        definition: definition
      ),
      productAccountId: session.productAccountId
    )
    let syncGate = MailboxConnectionSyncGate()
    let providerGate = TestRendezvous()
    let providerOperation = Task {
      try await syncGate.withLock(definition.connectionId) {
        await providerGate.hold()
      }
    }
    await providerGate.waitUntilHeld()
    let saveGate = TestRendezvous()
    definitions.beforeSaveDefinitionReturn = {
      await saveGate.hold()
    }
    let localStateCleaner = RecordingEWSLocalStateCleaner()
    let service = EWSSetupService(
      authorizationStore: authorizations,
      client: RecordingEWSClient(),
      definitionSyncService: definitions,
      localStateCleaner: localStateCleaner,
      syncGate: syncGate
    )
    let setup = Task {
      try await service.connect(
        authorizationMethod: .password,
        credential: "fresh-password",
        emailAddress: definition.emailAddress,
        endpoint: definition.endpoint.absoluteString,
        username: definition.username,
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
    }
    await saveGate.waitUntilHeld()
    await saveGate.release()
    try await Task.sleep(for: .milliseconds(20))

    #expect(localStateCleaner.clearedConnectionIds.isEmpty)
    await providerGate.release()
    try await providerOperation.value
    _ = try await setup.value
    #expect(localStateCleaner.clearedConnectionIds == [definition.connectionId])
  }

  @Test
  func testEWSSetupRechecksRemoteRemovalBeforeSavingAuthorization() async throws {
    let definition = try makeVerifiedEWSDefinition()
    let definitions = RecordingEWSDefinitionSyncService()
    definitions.beforeSaveDefinitionReturn = {
      _ = try? await definitions.removeConnection(definition.connectionId, session: self.session)
    }
    let authorizations = InMemoryEWSAuthorizationStore()
    let service = EWSSetupService(
      authorizationStore: authorizations,
      client: RecordingEWSClient(),
      definitionSyncService: definitions,
      syncGate: MailboxConnectionSyncGate()
    )

    do {
      _ = try await service.connect(
        authorizationMethod: .password,
        credential: "fresh-password",
        emailAddress: definition.emailAddress,
        endpoint: definition.endpoint.absoluteString,
        username: definition.username,
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
      Issue.record("Expected the remote removal to abort authorization persistence")
    } catch {
      #expect(error as? MailboxConnectionAdapterError == .connectionRemoved)
    }
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      ) == nil)
  }

  @Test
  func testEWSSetupRechecksProductSyncOutsideTheConnectionGate() async throws {
    let definition = try makeVerifiedEWSDefinition()
    let definitions = RecordingEWSDefinitionSyncService()
    let secondSnapshotGate = TestRendezvous()
    definitions.beforeLoadSnapshotReturn = {
      guard definitions.loadSnapshotCallCount == 2 else { return }
      await secondSnapshotGate.hold()
    }
    let authorizations = InMemoryEWSAuthorizationStore()
    let syncGate = MailboxConnectionSyncGate()
    let service = EWSSetupService(
      authorizationStore: authorizations,
      client: RecordingEWSClient(),
      definitionSyncService: definitions,
      syncGate: syncGate
    )
    let setup = Task {
      try await service.connect(
        authorizationMethod: .password,
        credential: "fresh-password",
        emailAddress: definition.emailAddress,
        endpoint: definition.endpoint.absoluteString,
        username: definition.username,
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
    }
    await secondSnapshotGate.waitUntilHeld()
    let competingGateAcquired = TestRendezvous()
    let competingOperation = Task {
      try await syncGate.withLock(definition.connectionId) {
        await competingGateAcquired.hold()
      }
    }
    await competingGateAcquired.waitUntilHeld()
    await competingGateAcquired.release()
    await secondSnapshotGate.release()
    try await competingOperation.value

    do {
      _ = try await setup.value
      Issue.record(
        "Expected the competing connection operation to cancel authorization persistence")
    } catch is CancellationError {
    }
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      ) == nil)
  }

  @Test
  func testEWSSetupRejectsGenerationChangedAfterDefinitionPersistence() async throws {
    let definition = try makeVerifiedEWSDefinition()
    let definitions = RecordingEWSDefinitionSyncService()
    definitions.beforeLoadSnapshotReturn = {
      guard definitions.loadSnapshotCallCount == 2 else { return }
      _ = try? await definitions.saveDefinition(
        definition.synchronizedDefinition(
          authorizationGeneration: 1,
          connectedAt: 1_781_200_000_000,
          displayName: definition.emailAddress
        ),
        session: self.session
      )
    }
    let authorizations = InMemoryEWSAuthorizationStore()
    let service = EWSSetupService(
      authorizationStore: authorizations,
      client: RecordingEWSClient(),
      definitionSyncService: definitions,
      syncGate: MailboxConnectionSyncGate()
    )

    do {
      _ = try await service.connect(
        authorizationMethod: .password,
        credential: "fresh-password",
        emailAddress: definition.emailAddress,
        endpoint: definition.endpoint.absoluteString,
        username: definition.username,
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
      Issue.record("Expected the changed authorization generation to cancel persistence")
    } catch is CancellationError {
    }
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      ) == nil)
  }

  @Test
  func testEWSSetupRejectsConcurrentRemoveAndReaddWithoutHoldingTheConnectionGate()
    async throws
  {
    let endpoint = try requireValue(URL(string: "https://mail.corp.example/EWS/Exchange.asmx"))
    let definition = EWSConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "reader@corp.example",
      endpoint: endpoint,
      providerAccountIdentifier: try EWSConnectionDefinition.stableProviderAccountIdentifier(
        endpoint: endpoint,
        mailboxIdentifier: "mailbox-id"
      ),
      serverVersion: .exchange2019,
      username: #"CORP\reader"#
    )
    let definitions = RecordingEWSDefinitionSyncService(
      definition: definition.synchronizedDefinition(
        connectedAt: 1_781_200_000_000,
        displayName: definition.emailAddress
      )
    )
    let snapshotGate = TestRendezvous()
    definitions.beforeLoadSnapshotReturn = {
      await snapshotGate.hold()
    }
    let authorizations = InMemoryEWSAuthorizationStore()
    let syncGate = MailboxConnectionSyncGate()
    let service = EWSSetupService(
      authorizationStore: authorizations,
      client: RecordingEWSClient(),
      definitionSyncService: definitions,
      localStateCleaner: RecordingEWSLocalStateCleaner(),
      syncGate: syncGate
    )

    let setupTask = Task {
      try await service.connect(
        authorizationMethod: .password,
        credential: "fresh-password",
        emailAddress: definition.emailAddress,
        endpoint: definition.endpoint.absoluteString,
        username: definition.username,
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
    }
    await snapshotGate.waitUntilHeld()
    try await syncGate.withLock(definition.connectionId) {
      _ = try await definitions.removeConnection(definition.connectionId, session: session)
      definitions.authorizationCleanupConnectionIds = [definition.connectionId]
      definitions.localCleanupGenerations = [definition.connectionId: 1]
      _ = try await definitions.saveDefinition(
        definition.synchronizedDefinition(
          authorizationGeneration: 1,
          connectedAt: 1_781_200_000_000,
          displayName: definition.emailAddress
        ),
        session: session
      )
    }
    await snapshotGate.release()

    do {
      _ = try await setupTask.value
      Issue.record("Expected the superseded authorization commit to be cancelled")
    } catch is CancellationError {
    }
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: definition.connectionId
      ) == nil)
  }

  @Test
  func testSimultaneousEWSSetupCommitsOnlyOneAuthorization() async throws {
    let endpoint = try requireValue(URL(string: "https://mail.corp.example/EWS/Exchange.asmx"))
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .exchangeWebServices,
        value: try EWSConnectionDefinition.stableProviderAccountIdentifier(
          endpoint: endpoint,
          mailboxIdentifier: "mailbox-id"
        )
      )
    )
    let definitions = RecordingEWSDefinitionSyncService()
    let saveBarrier = TestBarrier(participantCount: 2)
    definitions.beforeSaveDefinitionReturn = {
      await saveBarrier.arriveAndWait()
    }
    let authorizations = InMemoryEWSAuthorizationStore()
    let service = EWSSetupService(
      authorizationStore: authorizations,
      client: RecordingEWSClient(),
      definitionSyncService: definitions,
      syncGate: MailboxConnectionSyncGate()
    )
    let firstTask = Task {
      try await service.connect(
        authorizationMethod: .password,
        credential: "first-password",
        emailAddress: "reader@corp.example",
        endpoint: endpoint.absoluteString,
        username: #"CORP\reader"#,
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
    }
    let secondTask = Task {
      try await service.connect(
        authorizationMethod: .password,
        credential: "second-password",
        emailAddress: "reader@corp.example",
        endpoint: endpoint.absoluteString,
        username: #"CORP\reader"#,
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
    }

    var cancellationCount = 0
    var successCount = 0
    for task in [firstTask, secondTask] {
      do {
        _ = try await task.value
        successCount += 1
      } catch is CancellationError {
        cancellationCount += 1
      }
    }
    let authorization = try authorizations.load(
      productAccountId: session.productAccountId,
      connectionId: connectionId
    )

    #expect(successCount == 1)
    #expect(cancellationCount == 1)
    #expect(
      authorization.map {
        ["first-password", "second-password"].contains($0.credential)
      } == true)
  }

  @Test
  func testEWSReauthorizationAbortsWhenStaleRemovalCleanupIntervenes() async throws {
    let endpoint = try requireValue(URL(string: "https://mail.corp.example/EWS/Exchange.asmx"))
    let definition = EWSConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "reader@corp.example",
      endpoint: endpoint,
      providerAccountIdentifier: try EWSConnectionDefinition.stableProviderAccountIdentifier(
        endpoint: endpoint,
        mailboxIdentifier: "mailbox-id"
      ),
      serverVersion: .exchange2019,
      username: #"CORP\reader"#
    )
    let synchronizedDefinition = definition.synchronizedDefinition(
      authorizationGeneration: 1,
      connectedAt: 1_781_200_000_000,
      displayName: definition.emailAddress
    )
    let definitions = RecordingEWSDefinitionSyncService(definition: synchronizedDefinition)
    definitions.removedConnectionIds = [definition.connectionId]
    let authorizations = InMemoryEWSAuthorizationStore()
    let syncGate = MailboxConnectionSyncGate()
    let setupGate = TestRendezvous()
    let client = RecordingEWSClient()
    definitions.beforeLoadSnapshotReturn = {
      await setupGate.hold()
    }
    let setupService = EWSSetupService(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: definitions,
      localStateCleaner: RecordingEWSLocalStateCleaner(),
      syncGate: syncGate
    )
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      client: RecordingEWSClient(),
      definitionSyncService: definitions,
      metadataStore: InMemoryEWSMetadataStore(),
      syncGate: syncGate
    )

    let setupTask = Task {
      try await setupService.connect(
        authorizationMethod: .password,
        credential: "fresh-password",
        emailAddress: "reader@corp.example",
        endpoint: "https://mail.corp.example/EWS/Exchange.asmx",
        username: #"CORP\reader"#,
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
    }
    await setupGate.waitUntilHeld()
    let loadTask = Task {
      try await adapter.loadConnections(session: session)
    }
    while definitions.providerAccessLoads == 0 {
      await Task.yield()
    }
    await setupGate.release()

    do {
      _ = try await setupTask.value
      Issue.record("Expected the concurrent cleanup to cancel authorization persistence")
    } catch is CancellationError {
    }
    do {
      _ = try await loadTask.value
    } catch ProductSyncKeyMaterialStoreError.recoveryRequired {
      // The stale cleanup had no local queue key material in this test fixture.
    }
    let authorization = try authorizations.load(
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId
    )

    #expect(authorization == nil)
  }

  @Test
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

    #expect(result)
    #expect(definitions.savedDefinition == nil)
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: makeEWSDefinition().connectionId
      ) == nil)
  }

  @Test
  func testSetupSessionInvalidationAfterDefinitionPersistencePreventsAuthorizationCommit()
    async throws
  {
    let client = RecordingEWSClient()
    let definitions = RecordingEWSDefinitionSyncService()
    let authorizations = InMemoryEWSAuthorizationStore()
    let service = EWSSetupService(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: definitions
    )
    var sessionIsCurrent = true
    definitions.didSaveDefinition = {
      sessionIsCurrent = false
    }

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
      Issue.record("Expected the stale session to cancel authorization persistence")
    } catch is CancellationError {
    }

    let definition = try requireValue(definitions.savedDefinition)
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: definition.id
      ) == nil)
  }

  @Test
  func testSetupAcceptsSupportedVersionsAndAuthorizationMethods() async throws {
    for (versionIndex, version) in EWSServerVersion.allCases.enumerated() {
      for (methodIndex, method) in MailAuthorizationMethod.allCases.enumerated() {
        let index = (versionIndex * MailAuthorizationMethod.allCases.count) + methodIndex
        let client = RecordingEWSClient()
        client.account = EWSAccount(
          displayName: "On-Prem Reader",
          primaryEmailAddress: "reader-\(index)@corp.example",
          providerMailboxIdentifier: "mailbox-\(index)",
          serverVersion: version
        )
        let definitions = RecordingEWSDefinitionSyncService()
        let oauthTokens = EWSOAuthTokens(
          accessToken: "oauth-credential-\(index)",
          expiresAtMilliseconds: 1_781_203_600_000,
          refreshToken: "oauth-refresh-\(index)"
        )
        let service = EWSSetupService(
          authorizationStore: InMemoryEWSAuthorizationStore(),
          client: client,
          definitionSyncService: definitions,
          oauthService: RecordingEWSOAuthService(authorization: oauthTokens)
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

        #expect(client.verifiedAuthorization?.definition.authorizationMethod == method)
        #expect(definitions.savedDefinition?.ewsDefinition?.serverVersion == version)
      }
    }
  }

  @Test
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
    let connection = try requireValue(viewModel.connections.first)
    viewModel.credential = "credential-for-another-connection"
    await viewModel.select(connection)
    let didSetDefault = await viewModel.setDefaultSendingConnection(connection)

    #expect(viewModel.credential == "")
    #expect(didSetDefault)
    #expect(viewModel.defaultSendingConnectionId == connection.id)
    #expect(definitions.defaultSendingConnectionId == connection.id)
  }

  @Test
  func testEWSRemovalReportsCompletionWhenSnapshotRefreshFails() async throws {
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
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let viewModel = EWSSetupViewModel(
      adapter: EWSMailboxConnectionAdapter(
        authorizationStore: authorizations,
        definitionSyncService: definitions,
        metadataStore: InMemoryEWSMetadataStore(),
        outboxService: OutboxDeliveryService(store: EWSOutboxStore()),
        pendingActionService: PendingProviderActionService(store: EWSActionStore()),
        keyMaterialStore: keyMaterialStore
      ),
      definitionSyncService: definitions,
      isSessionCurrent: { $0 == self.session },
      session: session
    )
    await viewModel.load()
    let connection = try requireValue(viewModel.connections.first)
    definitions.loadSnapshotError = EWSServiceError.invalidResponse

    let didRemove = await viewModel.removeEverywhere(connection)

    #expect(
      didRemove,
      Comment(rawValue: viewModel.errorMessage ?? "Removal unexpectedly failed.")
    )
    #expect(viewModel.errorMessage != nil)
  }

  @Test
  func testEWSSetupSelectionPrefersSynchronizedDefinitionOverStaleAuthorization() async throws {
    let localDefinition = makeEWSDefinition()
    let synchronizedDefinition = EWSConnectionDefinition(
      authorizationMethod: .oauth,
      emailAddress: "reader@corp.example",
      endpoint: URL(string: "https://new-mail.corp.example/EWS/Exchange.asmx")!,
      providerAccountIdentifier: localDefinition.providerAccountIdentifier,
      serverVersion: .exchange2019,
      username: "reader@corp.example"
    )
    let definitions = RecordingEWSDefinitionSyncService(
      definition: synchronizedDefinition.synchronizedDefinition(
        connectedAt: 1_781_200_000_000,
        displayName: synchronizedDefinition.emailAddress
      )
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "stale-password", definition: localDefinition),
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
      authorizationStore: authorizations,
      definitionSyncService: definitions,
      isSessionCurrent: { $0 == self.session },
      session: session
    )

    await viewModel.load()
    let connection = try requireValue(viewModel.connections.first)
    await viewModel.select(connection)

    #expect(connection.authorizationState == .required)
    #expect(viewModel.authorizationMethod == .oauth)
    #expect(viewModel.endpoint == synchronizedDefinition.endpoint.absoluteString)
    #expect(viewModel.username == synchronizedDefinition.username)
    #expect(viewModel.credential == "")
  }

  @Test
  func testEWSSetupInvalidationPreventsInFlightCredentialPersistence() async throws {
    let gate = TestRendezvous()
    let client = RecordingEWSClient()
    client.beforeVerifyReturn = {
      await gate.hold()
    }
    let definitions = RecordingEWSDefinitionSyncService()
    let authorizations = InMemoryEWSAuthorizationStore()
    let viewModel = EWSSetupViewModel(
      authorizationStore: authorizations,
      definitionSyncService: definitions,
      isSessionCurrent: { $0 == self.session },
      service: EWSSetupService(
        authorizationStore: authorizations,
        client: client,
        definitionSyncService: definitions
      ),
      session: session
    )
    viewModel.credential = "password"
    viewModel.emailAddress = "reader@corp.example"
    viewModel.endpoint = "https://mail.corp.example/EWS/Exchange.asmx"
    viewModel.username = #"CORP\reader"#

    let connectionTask = Task { await viewModel.connect() }
    await gate.waitUntilHeld()
    viewModel.invalidate()
    await gate.release()
    let connection = await connectionTask.value

    #expect(connection == nil)
    #expect(definitions.savedDefinition == nil)
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: makeEWSDefinition().connectionId
      ) == nil)
  }

  @Test
  func testSynchronizedMailboxAliasChangePreservesDeviceAuthorization() async throws {
    let localDefinition = makeEWSDefinition()
    let synchronizedDefinition = EWSConnectionDefinition(
      authorizationMethod: localDefinition.authorizationMethod,
      emailAddress: "canonical@corp.example",
      endpoint: localDefinition.endpoint,
      providerAccountIdentifier: localDefinition.providerAccountIdentifier,
      serverVersion: localDefinition.serverVersion,
      username: localDefinition.username
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: localDefinition),
      productAccountId: session.productAccountId
    )
    let client = RecordingEWSClient()
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      client: client,
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definition: synchronizedDefinition.synchronizedDefinition(
          connectedAt: 1_781_200_000_000,
          displayName: synchronizedDefinition.emailAddress
        )
      ),
      metadataStore: InMemoryEWSMetadataStore()
    )

    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)

    #expect(connection.authorizationState == .authorized)
    #expect(!(client.requestedPages.isEmpty))
  }

  @Test
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
      Issue.record("Expected setup to reject an incomplete mailbox role mapping")
    } catch {
      #expect(error as? EWSSetupError == .missingRequiredMailboxRole)
    }
  }

  @Test
  func testSetupAllowsMailboxWithoutOnlineArchive() async throws {
    let client = RecordingEWSClient()
    client.folders.removeAll { $0.role == .archive }
    let service = EWSSetupService(
      authorizationStore: InMemoryEWSAuthorizationStore(),
      client: client,
      definitionSyncService: RecordingEWSDefinitionSyncService()
    )

    let connection = try await service.connect(
      authorizationMethod: .password,
      credential: "password",
      emailAddress: "reader@corp.example",
      endpoint: "https://mail.corp.example/EWS/Exchange.asmx",
      username: #"CORP\reader"#,
      session: session,
      isSessionCurrent: { $0 == self.session }
    )

    #expect(connection.authorizationState == .authorized)
    #expect(!(connection.capabilities.supports(.archive)))
    #expect(connection.capabilities.supports(.delete))
  }

  @Test
  func testLoadedConnectionDoesNotAdvertiseArchiveWithoutOnlineArchiveMetadata() async throws {
    let definition = makeEWSDefinition()
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let metadata = InMemoryEWSMetadataStore()
    try metadata.save(
      EWSMetadataSnapshot(
        folders: [
          EWSFolder(changeKey: "inbox-key", displayName: "Inbox", id: "inbox-id", role: .inbox)
        ],
        messages: [],
        nextOffsetsByFolderId: [:],
        hasInitialMailboxAvailability: true
      ),
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId
    )
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definition: definition.synchronizedDefinition(
          connectedAt: 1_781_200_000_000,
          displayName: definition.emailAddress
        )
      ),
      metadataStore: metadata
    )

    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    #expect(connection.authorizationState == .authorized)
    #expect(!(connection.capabilities.supports(.archive)))
    #expect(connection.capabilities.supports(.delete))
  }

  @Test
  func testLoadedConnectionKeepsArchiveBeforeFirstMetadataSnapshot() async throws {
    let definition = makeEWSDefinition()
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(
        credential: "password",
        definition: definition,
        hasOnlineArchive: true
      ),
      productAccountId: session.productAccountId
    )
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definition: definition.synchronizedDefinition(
          connectedAt: 1_781_200_000_000,
          displayName: definition.emailAddress
        )
      ),
      metadataStore: InMemoryEWSMetadataStore()
    )

    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    #expect(connection.authorizationState == .authorized)
    #expect(connection.capabilities.supports(.archive))
  }

  @Test
  func testSystemClientUsesMailboxScopedFolderAccessAndParsesSupportedServerVersion() async throws {
    let definition = makeEWSDefinition()
    var requests: [URLRequest] = []
    EWSURLProtocol.requestHandler = { request in
      requests.append(request)
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(Self.getFolderResponse.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }
    let client = SystemEWSClient(session: makeEWSURLSession())
    let authorization = DeviceLocalEWSAuthorization(
      credential: " password ",
      definition: definition
    )

    let account = try await client.verify(authorization)

    #expect(account.serverVersion == .exchange2019)
    #expect(account.primaryEmailAddress == "reader@corp.example")
    #expect(account.providerMailboxIdentifier == "inbox-id")
    #expect(requests.count == 1)
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    #expect(requests[0].value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/GetFolder") == true)
    #expect(try Self.requestBody(requests[0]).contains("<t:EmailAddress>reader@corp.example"))
  }

  @Test
  func testSystemClientRejectsExchangeOnlineVersionBehindCustomEndpoint() async throws {
    EWSURLProtocol.requestHandler = { request in
      let payload = Self.getFolderResponse.replacingOccurrences(
        of: #"MinorVersion="2""#, with: #"MinorVersion="20""#)
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
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
      Issue.record("Expected Exchange Online to be rejected")
    } catch {
      #expect(error as? EWSSetupError == .onPremisesEndpointRequired)
    }
  }

  @Test
  func testSystemClientResolvesArchiveDestinationForReturnedItemId() async throws {
    var requestBodies: [String] = []
    EWSURLProtocol.requestHandler = { request in
      let body = try Self.requestBody(request)
      requestBodies.append(body)
      let payload =
        body.contains("<m:ArchiveItem>")
        ? Self.archiveItemWithIdentityResponse
        : Self.archiveGetItemResponse
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
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
    let message = ewsMessage(1, folderId: "sent-id", conversationId: "conversation-1")

    let archived = try await SystemEWSClient(session: makeEWSURLSession()).perform(
      .archive,
      targetFolderId: nil,
      messages: [message],
      authorization: authorization
    )

    #expect(
      archived == [
        EWSMovedItemIdentity(
          changeKey: "archived-change-key",
          destinationFolderId: "archive-sent-id",
          itemId: "archived-item-id",
          stableProviderId: message.stableProviderId
        )
      ])
    #expect(requestBodies.count == 2)
    #expect(requestBodies[1].contains("<m:GetItem>"))
    #expect(requestBodies[1].contains(#"Id="archived-item-id""#))
    #expect(requestBodies[1].contains(#"FieldURI="item:ParentFolderId""#))
  }

  @Test
  func testSystemClientRejectsExchange2013BeforeSP1() async throws {
    EWSURLProtocol.requestHandler = { request in
      let payload = Self.getFolderResponse
        .replacingOccurrences(
          of: "MinorVersion=\"2\"",
          with: "MinorVersion=\"0\" MajorBuildNumber=\"800\" MinorBuildNumber=\"0\""
        )
        .replacingOccurrences(of: "Exchange2019", with: "Exchange2013")
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
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
      Issue.record("Expected pre-SP1 Exchange 2013 to be rejected")
    } catch {
      #expect(error as? EWSSetupError == .unsupportedServerVersion)
    }
  }

  @Test
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
          url: try requireValue(request.url),
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
        recipient:
          #""Recipient, One" <one@example.com>; Two <two@example.com>, three@example.com"#,
        subject: "Subject",
        idempotencyKey: "ews-send"
      ),
      authorization: DeviceLocalEWSAuthorization(
        credential: "app-password",
        definition: appPasswordDefinition
      )
    )

    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer oauth-token")
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
    #expect(requests[0].value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/UpdateItem") == true)
    #expect(requests[1].value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/CreateItem") == true)
    let updateBody = requestBodies[0]
    #expect(updateBody.contains("<t:IsRead>true</t:IsRead>"))
    #expect(!(updateBody.contains("<m:IsRead>")))
    #expect(updated.first?.changeKey == "updated-change-key")
    let sendBody = requestBodies[1]
    #expect(
      sendBody.contains(
        "<t:From><t:Mailbox><t:EmailAddress>reader@corp.example</t:EmailAddress>"
      ))
    #expect(sendBody.contains("<t:EmailAddress>one@example.com</t:EmailAddress>"))
    #expect(sendBody.contains("<t:EmailAddress>two@example.com</t:EmailAddress>"))
    #expect(sendBody.contains("<t:EmailAddress>three@example.com</t:EmailAddress>"))
    #expect(!(sendBody.contains("Recipient, One")))
  }

  @Test(arguments: [false, true])
  func testSystemClientSerializesReadReceiptChoiceForNewMessagesAndReplies(
    requestsReadReceipt: Bool
  ) async throws {
    var requestBodies: [String] = []
    EWSURLProtocol.requestHandler = { request in
      requestBodies.append(try Self.requestBody(request))
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(Self.successResponse.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }
    let client = SystemEWSClient(session: makeEWSURLSession())
    let authorization = DeviceLocalEWSAuthorization(
      credential: "password",
      definition: makeEWSDefinition()
    )

    try await client.send(
      OutgoingMessage(
        body: "New message",
        recipient: "recipient@example.com",
        subject: "New",
        kind: .new,
        requestsReadReceipt: requestsReadReceipt
      ),
      authorization: authorization
    )
    try await client.send(
      OutgoingMessage(
        body: "Reply",
        recipient: "recipient@example.com",
        subject: "Re: Source",
        inReplyTo: "<source@example.com>",
        kind: .reply,
        requestsReadReceipt: requestsReadReceipt
      ),
      authorization: authorization
    )

    #expect(requestBodies.count == 2)
    for requestBody in requestBodies {
      #expect(
        requestBody.contains(
          "<t:IsReadReceiptRequested>\(requestsReadReceipt)</t:IsReadReceiptRequested>"
        ))
    }
  }

  @Test
  func testSystemClientDeletesFlagFieldWhenUnstarring() async throws {
    var requestBody = ""
    EWSURLProtocol.requestHandler = { request in
      requestBody = try Self.requestBody(request)
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(Self.updateItemResponse.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }

    _ = try await SystemEWSClient(session: makeEWSURLSession()).perform(
      .unstar,
      targetFolderId: nil,
      messages: [ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")],
      authorization: DeviceLocalEWSAuthorization(
        credential: "password",
        definition: makeEWSDefinition()
      )
    )

    #expect(requestBody.contains("<t:DeleteItemField>"))
    #expect(requestBody.contains(#"FieldURI="item:Flag""#))
    #expect(!(requestBody.contains("<t:SetItemField>")))
    #expect(!(requestBody.contains("NotFlagged")))
  }

  @Test
  func testSystemClientRefreshesCurrentItemIdentityWithoutSubmittingStaleChangeKey()
    async throws
  {
    var requestBody = ""
    EWSURLProtocol.requestHandler = { request in
      requestBody = try Self.requestBody(request)
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
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

    #expect(requestBody.contains(#"<t:ItemId Id="ews-current-1"/>"#))
    #expect(!(requestBody.contains(message.changeKey)))
    #expect(refreshed.first?.itemId == "item-id")
    #expect(refreshed.first?.changeKey == "change-key")
  }

  @Test
  func testSystemClientPreservesItemNotFoundFromMixedIdentityRefresh() async throws {
    let mixedResponse = """
      <?xml version="1.0" encoding="utf-8"?>
      <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
        <s:Body><m:GetItemResponse><m:ResponseMessages>
          <m:GetItemResponseMessage ResponseClass="Success">
            <m:ResponseCode>NoError</m:ResponseCode>
            <m:Items><t:Message>
              <t:ItemId Id="current-item-id" ChangeKey="current-change-key"/>
            </t:Message></m:Items>
          </m:GetItemResponseMessage>
          <m:GetItemResponseMessage ResponseClass="Error">
            <m:MessageText>Item not found</m:MessageText>
            <m:ResponseCode>ErrorItemNotFound</m:ResponseCode>
          </m:GetItemResponseMessage>
        </m:ResponseMessages></m:GetItemResponse></s:Body>
      </s:Envelope>
      """
    EWSURLProtocol.requestHandler = { request in
      (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(mixedResponse.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }

    let partiallyRefreshed = try await SystemEWSClient(session: makeEWSURLSession())
      .refreshMessageIdentitiesAllowingMissing(
        [
          ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1"),
          ewsMessage(2, folderId: "inbox-id", conversationId: "conversation-2"),
        ],
        authorization: DeviceLocalEWSAuthorization(
          credential: "password",
          definition: makeEWSDefinition()
        )
      )
    #expect(partiallyRefreshed[0]?.itemId == "current-item-id")
    #expect(partiallyRefreshed[1] == nil)

    do {
      _ = try await SystemEWSClient(session: makeEWSURLSession()).refreshMessageIdentities(
        [
          ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1"),
          ewsMessage(2, folderId: "inbox-id", conversationId: "conversation-2"),
        ],
        authorization: DeviceLocalEWSAuthorization(
          credential: "password",
          definition: makeEWSDefinition()
        )
      )
      Issue.record("Expected the missing identity to remain recoverable")
    } catch let error as EWSServiceError {
      #expect(error.isItemNotFound)
    }
  }

  @Test
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
          url: try requireValue(request.url),
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
      Issue.record("Expected a mixed batch response to require reconciliation")
    } catch {
      #expect(error as? EWSServiceError == .invalidResponse)
    }
  }

  @Test
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
          url: try requireValue(request.url),
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
      Issue.record("Expected a response without an EWS response code to be rejected")
    } catch {
      #expect(error as? EWSServiceError == .invalidResponse)
    }
  }

  @Test
  func testSystemClientTreatsPartialMultiFolderArchiveAsAmbiguous() async throws {
    var archiveRequestCount = 0
    EWSURLProtocol.requestHandler = { request in
      archiveRequestCount += 1
      if archiveRequestCount == 1 {
        return (
          HTTPURLResponse(
            url: try requireValue(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
          )!,
          Data(Self.moveItemResponse.utf8)
        )
      }
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
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
      Issue.record("Expected a partial archive outcome to require reconciliation")
    } catch {
      #expect(error is EWSAmbiguousProviderActionError)
    }
  }

  @Test
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
          url: try requireValue(request.url),
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

    let page = try await client.loadMessagePage(
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
    #expect(page.messages.first?.hasAttachments == true)
    for field in [
      "message:InternetMessageId",
      "message:From",
      "message:ReplyTo",
      "message:ToRecipients",
      "message:CcRecipients",
      "message:BccRecipients",
      "item:DateTimeCreated",
      "item:HasAttachments",
      "item:DateTimeSent",
      "item:Preview",
    ] {
      #expect(metadataBody.contains(#"FieldURI="\#(field)""#))
    }
    #expect(!(metadataBody.contains(#"FieldURI="item:InternetMessageId""#)))
    let deliveryBody = requestBodies[1]
    #expect(deliveryBody.contains(#"PropertyName="UnwiredOutboxId""#))
    let pagingRange = try requireValue(deliveryBody.range(of: "<m:IndexedPageItemView"))
    let restrictionRange = try requireValue(deliveryBody.range(of: "<m:Restriction>"))
    #expect(pagingRange.lowerBound < restrictionRange.lowerBound)
  }

  @Test
  func testSystemClientSortsAndDatesSentItemsBySentTimestamp() async throws {
    var requestBody = ""
    let response = Self.findItemResponse.replacingOccurrences(
      of: "<t:DateTimeReceived>2026-07-27T12:34:56.123Z</t:DateTimeReceived>",
      with: """
        <t:DateTimeReceived>2025-01-01T00:00:00Z</t:DateTimeReceived>
        <t:DateTimeSent>2026-07-27T12:34:56.123Z</t:DateTimeSent>
        """
    )
    EWSURLProtocol.requestHandler = { request in
      requestBody = try Self.requestBody(request)
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
    defer { EWSURLProtocol.requestHandler = nil }
    let authorization = DeviceLocalEWSAuthorization(
      credential: "password",
      definition: makeEWSDefinition()
    )

    let page = try await SystemEWSClient(session: makeEWSURLSession()).loadMessagePage(
      folder: EWSFolder(
        changeKey: nil,
        displayName: "Sent Items",
        id: "sent-id",
        role: .sent
      ),
      offset: 0,
      pageSize: 50,
      authorization: authorization
    )

    let sortStart = try requireValue(requestBody.range(of: "<m:SortOrder>"))
    let sortEnd = try requireValue(requestBody.range(of: "</m:SortOrder>"))
    #expect(
      requestBody[sortStart.lowerBound..<sortEnd.upperBound]
        .contains(#"FieldURI="item:DateTimeSent""#))
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let sentDate = try requireValue(dateFormatter.date(from: "2026-07-27T12:34:56.123Z"))
    #expect(
      page.messages.first?.receivedAtMilliseconds == Int64(sentDate.timeIntervalSince1970 * 1_000))
  }

  @Test
  func testPasswordCredentialIsOnlyUsedForInitialMatchingChallenge() {
    #expect(
      shouldUseEWSPasswordCredential(
        authenticationMethod: NSURLAuthenticationMethodNTLM,
        challengeMatchesEndpoint: true,
        previousFailureCount: 0
      ))
    #expect(
      !(shouldUseEWSPasswordCredential(
        authenticationMethod: NSURLAuthenticationMethodNTLM,
        challengeMatchesEndpoint: true,
        previousFailureCount: 1
      )))
    #expect(
      !(shouldUseEWSPasswordCredential(
        authenticationMethod: NSURLAuthenticationMethodNTLM,
        challengeMatchesEndpoint: false,
        previousFailureCount: 0
      )))
    #expect(
      mappedEWSRequestError(
        URLError(.userAuthenticationRequired),
        authenticationWasRejected: true
      ) as? EWSServiceError == .authenticationRejected)
  }

  @Test
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
          url: try requireValue(request.url),
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

    #expect(Set(page.messages.map(\.stableProviderId)) == ["item-id", "second-item-id"])
  }

  @Test
  func testSystemClientSortsDraftsByLastModifiedTimestamp() async throws {
    var requestBody = ""
    EWSURLProtocol.requestHandler = { request in
      requestBody = try Self.requestBody(request)
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(
          Self.findItemResponse.replacingOccurrences(
            of: "<t:DateTimeReceived>2026-07-27T12:34:56.123Z</t:DateTimeReceived>",
            with: """
              <t:IsDraft>true</t:IsDraft>
              <t:LastModifiedTime>2026-07-27T12:34:57.123Z</t:LastModifiedTime>
              """
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

    #expect(page.messages.first?.receivedAtMilliseconds == 1_785_155_697_123)
    #expect(requestBody.contains(#"FieldURI="item:LastModifiedTime""#))
    #expect(requestBody.contains(#"Order="Descending""#))
  }

  @Test
  func testArchiveHierarchyMessagesKeepArchiveAndCustomFolderMembership() throws {
    let connection = makeEWSDefinition().synchronizedDefinition(
      connectedAt: 1_781_200_000_000,
      displayName: "Archive"
    ).mailboxConnection(
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )
    let message = ewsMessage(
      1,
      folderId: "archive-projects",
      conversationId: "conversation-1"
    )

    let metadata = message.mailboxMetadata(
      connection: connection,
      foldersById: [
        "archive-projects": EWSFolder(
          changeKey: "archive-key",
          displayName: "Projects",
          id: "archive-projects",
          isArchiveHierarchy: true,
          role: nil
        )
      ]
    )

    #expect(
      Set(metadata.providerStateIds ?? []) == [
        "ARCHIVE", "UNREAD", EWSProviderMessage.archiveHierarchyStateId,
        EWSProviderMessage.customFolderStateId("archive-projects"),
      ])
    #expect(
      MailboxMessageCollection.role(.archive).contains(
        providerStateIds: metadata.providerStateIds
      ))
  }

  @Test
  func testDeletedItemsDescendantsKeepTrashAndCustomFolderMembership() throws {
    let connection = makeEWSDefinition().synchronizedDefinition(
      connectedAt: 1_781_200_000_000,
      displayName: "Deleted Projects"
    ).mailboxConnection(
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )
    let message = ewsMessage(
      1,
      folderId: "deleted-projects",
      conversationId: "conversation-1"
    )

    let metadata = message.mailboxMetadata(
      connection: connection,
      foldersById: [
        "deleted-items": EWSFolder(
          changeKey: "deleted-key",
          displayName: "Deleted Items",
          id: "deleted-items",
          role: .trash
        ),
        "deleted-projects": EWSFolder(
          changeKey: "projects-key",
          displayName: "Projects",
          id: "deleted-projects",
          parentFolderId: "deleted-items",
          role: nil
        ),
      ]
    )

    #expect(
      Set(metadata.providerStateIds ?? []) == [
        "TRASH", "UNREAD", EWSProviderMessage.customFolderStateId("deleted-projects"),
      ])
    #expect(
      MailboxMessageCollection.role(.trash).contains(
        providerStateIds: metadata.providerStateIds
      ))
  }

  @Test
  func testJunkDescendantsKeepSpamAndCustomFolderMembership() throws {
    let connection = makeEWSDefinition().synchronizedDefinition(
      connectedAt: 1_781_200_000_000,
      displayName: "Junk Projects"
    ).mailboxConnection(
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )
    let message = ewsMessage(
      1,
      folderId: "junk-projects",
      conversationId: "conversation-1"
    )

    let metadata = message.mailboxMetadata(
      connection: connection,
      foldersById: [
        "junk-email": EWSFolder(
          changeKey: "junk-key",
          displayName: "Junk Email",
          id: "junk-email",
          role: .spam
        ),
        "junk-projects": EWSFolder(
          changeKey: "projects-key",
          displayName: "Projects",
          id: "junk-projects",
          parentFolderId: "junk-email",
          role: nil
        ),
      ]
    )

    #expect(
      Set(metadata.providerStateIds ?? []) == [
        "SPAM", "UNREAD", EWSProviderMessage.customFolderStateId("junk-projects"),
      ])
    #expect(
      MailboxMessageCollection.role(.spam).contains(
        providerStateIds: metadata.providerStateIds
      ))
    #expect(
      !(MailboxMessageCollection.allMail.contains(
        providerStateIds: metadata.providerStateIds
      )))
  }

  @Test
  func testArchiveDeletedItemsDescendantsKeepTrashMembership() throws {
    let connection = makeEWSDefinition().synchronizedDefinition(
      connectedAt: 1_781_200_000_000,
      displayName: "Archive Deleted Projects"
    ).mailboxConnection(
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )
    let message = ewsMessage(
      1,
      folderId: "archive-deleted-projects",
      conversationId: "conversation-1"
    )

    let metadata = message.mailboxMetadata(
      connection: connection,
      foldersById: [
        "archive-deleted-items": EWSFolder(
          changeKey: "deleted-key",
          displayName: "Deleted Items",
          id: "archive-deleted-items",
          isArchiveHierarchy: true,
          isTrashHierarchy: true,
          role: nil
        ),
        "archive-deleted-projects": EWSFolder(
          changeKey: "projects-key",
          displayName: "Projects",
          id: "archive-deleted-projects",
          isArchiveHierarchy: true,
          parentFolderId: "archive-deleted-items",
          role: nil
        ),
      ]
    )

    #expect(
      Set(metadata.providerStateIds ?? []) == [
        "ARCHIVE", "TRASH", "UNREAD",
        EWSProviderMessage.archiveHierarchyStateId,
        EWSProviderMessage.customFolderStateId("archive-deleted-projects"),
      ])
    #expect(
      MailboxMessageCollection.role(.trash).contains(
        providerStateIds: metadata.providerStateIds
      ))
    #expect(
      !(MailboxMessageCollection.role(.archive).contains(
        providerStateIds: metadata.providerStateIds
      )))
    #expect(
      !(MailboxMessageCollection.allMail.contains(
        providerStateIds: metadata.providerStateIds
      )))
  }

  @Test
  func testSystemClientPaginatesDeepFolderDiscovery() async throws {
    var findFolderOffsets: [Int] = []
    var requestedArchiveHierarchy = false
    var requestedFolderClass = false
    EWSURLProtocol.requestHandler = { request in
      let body = try Self.requestBody(request)
      if body.contains("<m:FindFolder") {
        requestedFolderClass =
          requestedFolderClass || body.contains(#"FieldURI="folder:FolderClass""#)
        if body.contains(#"Id="archivemsgfolderroot""#) {
          requestedArchiveHierarchy = true
          return (
            HTTPURLResponse(
              url: try requireValue(request.url),
              statusCode: 200,
              httpVersion: nil,
              headerFields: nil
            )!,
            Data(Self.folderNotFoundResponse.utf8)
          )
        }
        let offset = body.contains(#"Offset="0""#) ? 0 : 100
        findFolderOffsets.append(offset)
        return (
          HTTPURLResponse(
            url: try requireValue(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
          )!,
          Data(Self.findFolderResponse(offset: offset).utf8)
        )
      }
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
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

    #expect(findFolderOffsets == [0, 100])
    #expect(requestedArchiveHierarchy)
    #expect(requestedFolderClass)
    #expect(Set(folders.map(\.id)) == ["custom-0", "custom-100"])
    #expect(folders.first(where: { $0.id == "custom-0" })?.folderClass == "IPF.Note")
    #expect(folders.first(where: { $0.id == "custom-0" })?.isSearchFolder == false)
    #expect(folders.first(where: { $0.id == "custom-100" })?.isSearchFolder == true)
    #expect(folders.first(where: { $0.id == "custom-0" })?.parentFolderId == "parent-0")
    #expect(folders.first(where: { $0.id == "custom-100" })?.parentFolderId == "parent-100")
  }

  @Test
  func testEWSFolderAcceptsMailCompatibleSubclasses() {
    #expect(
      EWSFolder(
        changeKey: nil,
        displayName: "Messages",
        folderClass: "IPF.Note.Custom",
        id: "messages-id",
        role: nil
      ).isMailFolder)
    #expect(
      EWSFolder(
        changeKey: nil,
        displayName: "Messages",
        folderClass: "ipf.note.custom",
        id: "messages-id",
        role: nil
      ).isMailFolder)
    #expect(
      !(EWSFolder(
        changeKey: nil,
        displayName: "Calendar",
        folderClass: "IPF.Appointment",
        id: "calendar-id",
        role: nil
      ).isMailFolder))
  }

  @Test
  func testSystemClientMarksDistinguishedOutbox() async throws {
    EWSURLProtocol.requestHandler = { request in
      let body = try Self.requestBody(request)
      let response =
        if body.contains("<m:FindFolder"),
          body.contains(#"Id="msgfolderroot""#)
        {
          Self.findFolderResponse(offset: 100)
            .replacingOccurrences(of: "custom-100", with: "outbox-id")
            .replacingOccurrences(of: "Custom 100", with: "Localized Outbox")
        } else if body.contains(#"Id="outbox""#) {
          Self.getFolderResponse
            .replacingOccurrences(of: "inbox-id", with: "outbox-id")
            .replacingOccurrences(of: "Inbox", with: "Localized Outbox")
        } else {
          Self.folderNotFoundResponse
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
    defer { EWSURLProtocol.requestHandler = nil }

    let folders = try await SystemEWSClient(session: makeEWSURLSession()).loadFolders(
      authorization: DeviceLocalEWSAuthorization(
        credential: "password",
        definition: makeEWSDefinition()
      )
    )

    #expect(folders.first(where: { $0.id == "outbox-id" })?.isOutbox == true)
  }

  @Test
  func testSystemClientMarksArchiveDeletedItemsHierarchy() async throws {
    var archiveSentRequestBody = ""
    EWSURLProtocol.requestHandler = { request in
      let body = try Self.requestBody(request)
      if body.contains("<m:FindItem") {
        archiveSentRequestBody = body
      }
      let response =
        if body.contains("<m:FindItem") {
          Self.findItemResponse.replacingOccurrences(
            of: "<t:DateTimeReceived>2026-07-27T12:34:56.123Z</t:DateTimeReceived>",
            with: "<t:DateTimeSent>2026-07-27T12:34:56.123Z</t:DateTimeSent>"
          )
        } else if body.contains("<m:FindFolder"),
          body.contains(#"Id="archivemsgfolderroot""#)
        {
          Self.findFolderResponse(offset: 100)
            .replacingOccurrences(of: "custom-100", with: "nested-custom-id")
            .replacingOccurrences(of: "parent-100", with: "archive-sent-id")
            .replacingOccurrences(of: "Custom 100", with: "Sent Items")
            .replacingOccurrences(
              of: "</t:Folders>",
              with: """
                <t:Folder>
                  <t:FolderId Id="archive-sent-id" ChangeKey="archive-sent-key"/>
                  <t:ParentFolderId Id="archive-root-id"/>
                  <t:DisplayName>Sent Items</t:DisplayName>
                  <t:FolderClass>IPF.Note</t:FolderClass>
                </t:Folder>
                </t:Folders>
                """
            )
        } else if body.contains(#"Id="archivemsgfolderroot""#) {
          Self.getFolderResponse
            .replacingOccurrences(of: "inbox-id", with: "archive-root-id")
            .replacingOccurrences(of: "Inbox", with: "Archive Root")
        } else if body.contains(#"Id="archivedeleteditems""#) {
          Self.getFolderResponse
            .replacingOccurrences(of: "inbox-id", with: "archive-deleted-id")
            .replacingOccurrences(of: "Inbox", with: "Deleted Items")
            .replacingOccurrences(
              of: "</t:DisplayName>",
              with: "</t:DisplayName><t:FolderClass>IPF.Note</t:FolderClass>"
            )
        } else if body.contains(#"Id="sentitems""#) {
          Self.getFolderResponse
            .replacingOccurrences(of: "inbox-id", with: "sent-id")
            .replacingOccurrences(of: "Inbox", with: "Sent Items")
        } else if body.contains("<m:FindFolder") {
          Self.findFolderResponse(offset: 100)
        } else {
          Self.folderNotFoundResponse
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
    defer { EWSURLProtocol.requestHandler = nil }

    let folders = try await SystemEWSClient(session: makeEWSURLSession()).loadFolders(
      authorization: DeviceLocalEWSAuthorization(
        credential: "password",
        definition: makeEWSDefinition()
      )
    )
    let archiveDeletedItems = try requireValue(
      folders.first(where: { $0.id == "archive-deleted-id" }))

    #expect(archiveDeletedItems.isArchiveHierarchy == true)
    #expect(archiveDeletedItems.isTrashHierarchy == true)
    #expect(archiveDeletedItems.folderClass == "IPF.Note")
    let archiveSent = try requireValue(folders.first(where: { $0.id == "archive-sent-id" }))
    #expect(archiveSent.isArchiveHierarchy == true)
    #expect(archiveSent.isSentHierarchy == true)
    #expect(archiveSent.role == nil)
    #expect(folders.first(where: { $0.id == "nested-custom-id" })?.isSentHierarchy == nil)

    _ = try await SystemEWSClient(session: makeEWSURLSession()).loadMessagePage(
      folder: archiveSent,
      offset: 0,
      pageSize: 50,
      authorization: DeviceLocalEWSAuthorization(
        credential: "password",
        definition: makeEWSDefinition()
      )
    )
    #expect(archiveSentRequestBody.contains(#"FieldURI="item:DateTimeSent""#))
  }

  @Test
  func testSystemClientRejectsMalformedDiscoveredFolder() async throws {
    EWSURLProtocol.requestHandler = { request in
      let body = try Self.requestBody(request)
      let response =
        body.contains(#"Id="archivemsgfolderroot""#)
        ? Self.folderNotFoundResponse
        : Self.findFolderResponse(offset: 100).replacingOccurrences(
          of: #"<t:FolderId Id="custom-100" ChangeKey="key-100"/>"#,
          with: ""
        )
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
    defer { EWSURLProtocol.requestHandler = nil }

    do {
      _ = try await SystemEWSClient(session: makeEWSURLSession()).loadFolders(
        authorization: DeviceLocalEWSAuthorization(
          credential: "password",
          definition: makeEWSDefinition()
        )
      )
      Issue.record("Expected a malformed discovered folder to be rejected")
    } catch {
      #expect(error as? EWSServiceError == .invalidResponse)
    }
  }

  @Test
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
          url: try requireValue(request.url),
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
      Issue.record("Expected the temporary mailbox-store outage to propagate")
    } catch {
      guard
        let serviceError = error as? EWSServiceError,
        case .response(let code, _) = serviceError
      else {
        Issue.record("Expected an EWS response error")
        return
      }
      #expect(code == "ErrorMailboxStoreUnavailable")
    }
  }

  @Test
  func testSystemClientParsesItemBodyFractionalTimestampAndMovedIdentity() async throws {
    var requestBodies: [String] = []
    EWSURLProtocol.requestHandler = { request in
      let body = try Self.requestBody(request)
      requestBodies.append(body)
      let payload =
        if body.contains("<m:GetItem>") {
          Self.getItemResponse
        } else if body.contains("<m:FindFolder") {
          Self.archiveFolderResponse
        } else if body.contains("<m:FindItem") {
          Self.findItemResponse
        } else if body.contains("<m:ArchiveItem>") {
          Self.archiveItemResponse
        } else {
          Self.moveItemResponse
        }
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
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

    #expect(body == "  Rendered message body\n")
    #expect(page.messages.first?.receivedAtMilliseconds == 1_785_155_696_123)
    #expect(
      archived == [
        EWSMovedItemIdentity(
          changeKey: "change-key",
          destinationFolderId: "archive-custom-id",
          itemId: "item-id",
          stableProviderId: message.stableProviderId
        )
      ])
    #expect(
      moved == [
        EWSMovedItemIdentity(
          changeKey: "moved-change-key",
          itemId: "moved-item-id",
          stableProviderId: message.stableProviderId
        )
      ])
    #expect(deleted == moved)
    #expect(requestBodies[2].contains("<m:ArchiveItem>"))
    #expect(requestBodies[2].contains("<m:ArchiveSourceFolderId>"))
    #expect(requestBodies[2].contains(#"Id="inbox-id""#))
    #expect(!(requestBodies[2].contains("<m:MoveItem>")))
    #expect(requestBodies[3].contains(#"Id="archivemsgfolderroot""#))
    #expect(requestBodies[4].contains(#"Id="archive-sent-id""#))
    #expect(requestBodies[4].contains(#"Id="archive-custom-id""#))
    #expect(!(requestBodies[4].contains(#"Id="archive-search-id""#)))
    #expect(requestBodies[4].contains(#"FieldURI="item:ParentFolderId""#))
    #expect(requestBodies[4].contains(message.stableProviderId))
    #expect(requestBodies.last?.contains("<m:MoveItem>") == true)
    #expect(requestBodies.last?.contains(#"Id="deleteditems""#) == true)
    #expect(!(requestBodies.last?.contains("<m:DeleteItem") == true))
  }

  @Test
  func testSystemClientClassifiesDescriptorsAndBoundsAuthenticatedAttachmentDownload()
    async throws
  {
    var authorizationHeaders: [String?] = []
    var requestBodies: [String] = []
    EWSURLProtocol.requestHandler = { request in
      let body = try Self.requestBody(request)
      requestBodies.append(body)
      authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
      let payload: Data
      if body.contains(#"AttachmentId Id="oversized""#) {
        payload = Data(repeating: 0x41, count: 70_000)
      } else if body.contains("<m:GetAttachment>") {
        payload = Data(Self.getAttachmentResponse.utf8)
      } else {
        payload = Data(Self.getAttachmentDescriptorsResponse.utf8)
      }
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Length": "\(payload.count)"]
        )!,
        payload
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }
    let definition = EWSConnectionDefinition(
      authorizationMethod: .oauth,
      emailAddress: "reader@corp.example",
      endpoint: URL(string: "https://mail.corp.example/EWS/Exchange.asmx")!,
      providerAccountIdentifier: "ews-account-001",
      serverVersion: .exchange2019,
      username: "reader@corp.example"
    )
    let authorization = DeviceLocalEWSAuthorization(
      credential: "provider-access-token",
      definition: definition
    )
    let client = SystemEWSClient(session: makeEWSURLSession())

    let descriptors = try await client.loadAttachmentDescriptors(
      itemId: "item-id",
      authorization: authorization
    )
    let data = try await client.loadAttachmentData(
      providerAttachmentId: "file-id",
      expectedByteCount: 3,
      maximumByteCount: 4,
      authorization: authorization
    )

    #expect(descriptors.map(\.kind) == [.file, .inlineImage, .unsupportedItem])
    #expect(descriptors.map(\.providerAttachmentId) == ["file-id", "inline-id", "item-id"])
    #expect(data == Data("PDF".utf8))
    #expect(authorizationHeaders.allSatisfy { $0 == "Bearer provider-access-token" })
    #expect(requestBodies[0].contains(#"FieldURI="item:Attachments""#))
    #expect(requestBodies[1].contains("<m:GetAttachment>"))

    do {
      _ = try await client.loadAttachmentData(
        providerAttachmentId: "oversized",
        expectedByteCount: 4,
        maximumByteCount: 4,
        authorization: authorization
      )
      Issue.record("Expected the bounded EWS response reader to reject oversized data")
    } catch MailboxMessageAttachmentError.invalidResponse {
    } catch {
      Issue.record("Expected an invalid attachment response, got \(error)")
    }
  }

  @Test
  func testSystemClientRecoversMovedIdentityWithBoundedStableKeySearch() async throws {
    var requestBody = ""
    EWSURLProtocol.requestHandler = { request in
      requestBody = try Self.requestBody(request)
      return (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(Self.findItemResponse.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }
    let authorization = DeviceLocalEWSAuthorization(
      credential: "password",
      definition: makeEWSDefinition()
    )
    let message = ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")
    let folders = [
      EWSFolder(changeKey: nil, displayName: "Inbox", id: "inbox-id", role: .inbox),
      EWSFolder(changeKey: nil, displayName: "Projects", id: "projects-id", role: nil),
      EWSFolder(
        changeKey: nil,
        displayName: "Search",
        id: "search-id",
        isSearchFolder: true,
        role: nil
      ),
      EWSFolder(
        changeKey: nil,
        displayName: "Outbox",
        id: "outbox-id",
        isOutbox: true,
        role: nil
      ),
    ]

    let recovered = try await SystemEWSClient(session: makeEWSURLSession())
      .recoverMessageIdentity(message, folders: folders, authorization: authorization)

    #expect(
      recovered
        == EWSMovedItemIdentity(
          changeKey: "change-key",
          destinationFolderId: "archive-custom-id",
          itemId: "item-id",
          stableProviderId: message.stableProviderId
        ))
    #expect(requestBody.contains("<m:FindItem Traversal=\"Shallow\">"))
    #expect(requestBody.contains("MaxEntriesReturned=\"2\""))
    #expect(requestBody.contains("PropertyTag=\"0x300B\""))
    #expect(requestBody.contains(message.stableProviderId))
    #expect(requestBody.contains("Id=\"inbox-id\""))
    #expect(requestBody.contains("Id=\"projects-id\""))
    #expect(!(requestBody.contains("Id=\"search-id\"")))
    #expect(!(requestBody.contains("Id=\"outbox-id\"")))
  }

  @Test
  func testSystemClientPreservesItemNotFoundWhenStableKeySearchHasNoMatch() async throws {
    let emptyResponse = """
      <?xml version="1.0" encoding="utf-8"?>
      <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
        <s:Body><m:FindItemResponse><m:ResponseMessages>
          <m:FindItemResponseMessage ResponseClass="Success">
            <m:ResponseCode>NoError</m:ResponseCode>
            <m:RootFolder IncludesLastItemInRange="true" TotalItemsInView="0">
              <t:Items/>
            </m:RootFolder>
          </m:FindItemResponseMessage>
        </m:ResponseMessages></m:FindItemResponse></s:Body>
      </s:Envelope>
      """
    EWSURLProtocol.requestHandler = { request in
      (
        HTTPURLResponse(
          url: try requireValue(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(emptyResponse.utf8)
      )
    }
    defer { EWSURLProtocol.requestHandler = nil }

    do {
      _ = try await SystemEWSClient(session: makeEWSURLSession()).recoverMessageIdentity(
        ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1"),
        folders: [
          EWSFolder(changeKey: nil, displayName: "Inbox", id: "inbox-id", role: .inbox)
        ],
        authorization: DeviceLocalEWSAuthorization(
          credential: "password",
          definition: makeEWSDefinition()
        )
      )
      Issue.record("Expected the missing item to remain item-not-found")
    } catch let error as EWSServiceError {
      #expect(error.isItemNotFound)
    }
  }

  @Test
  func testSystemClientRejectsInvalidFindItemPagingMetadata() async throws {
    let responses = [
      Self.successResponse,
      Self.findItemResponse.replacingOccurrences(
        of: #"IncludesLastItemInRange="true""#,
        with: #"IncludesLastItemInRange="false""#
      ),
      Self.findItemResponse.replacingOccurrences(
        of: #"<t:ItemId Id="item-id" ChangeKey="change-key"/>"#,
        with: ""
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
            url: try requireValue(request.url),
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
        Issue.record("Expected malformed FindItem paging metadata to be rejected")
      } catch {
        #expect(error as? EWSServiceError == .invalidResponse)
      }
    }
  }

  @Test
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
    let connection = try requireValue(connections.first)

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

    #expect(initial.hasInitialMailboxAvailability)
    #expect(!(initial.historicalMetadataBackfillIsComplete))
    #expect(initial.messages.map(\.providerMessageId) == ["ews-stable-3", "ews-stable-2"])
    #expect(sent.messages.map(\.providerMessageId) == ["ews-stable-20"])
    #expect(initial.threads.first?.providerThreadId == "conversation-1")
    #expect(!(complete.historicalMetadataBackfillIsComplete))
    #expect(
      complete.messages.map(\.providerMessageId) == [
        "ews-stable-3", "ews-stable-2", "ews-stable-1",
      ])
    #expect(client.requestedPages == ["inbox-id|0", "sent-id|0", "inbox-id|2"])
  }

  @Test
  func testSearchAndArchiveFoldersAreExcludedFromMoveDestinations() async throws {
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
        changeKey: "junk-key",
        displayName: "Junk Email",
        id: "junk-id",
        role: .spam
      ),
      EWSFolder(
        changeKey: "junk-projects-key",
        displayName: "Junk Projects",
        id: "junk-projects-id",
        parentFolderId: "junk-id",
        role: nil
      ),
      EWSFolder(
        changeKey: "search-key",
        displayName: "Unread Mail",
        id: "unread-id",
        isSearchFolder: true,
        role: nil
      ),
      EWSFolder(
        changeKey: "archive-key",
        displayName: "Archived Projects",
        id: "archive-projects-id",
        isArchiveHierarchy: true,
        isSearchFolder: false,
        role: nil
      ),
      EWSFolder(
        changeKey: "calendar-key",
        displayName: "Calendar",
        folderClass: "IPF.Appointment",
        id: "calendar-id",
        isSearchFolder: false,
        role: nil
      ),
      EWSFolder(
        changeKey: "outbox-key",
        displayName: "Localized Outbox",
        id: "outbox-id",
        isOutbox: true,
        isSearchFolder: false,
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
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)

    let mailboxes = try await adapter.loadProviderMailboxes(
      connection: connection,
      session: session
    )

    #expect(mailboxes.map(\.title) == ["Projects", "Junk Projects", "Archived Projects"])
    #expect(mailboxes.filter(\.isMoveDestination).map(\.title) == ["Projects", "Junk Projects"])
    #expect(mailboxes.first(where: { $0.title == "Junk Projects" })?.providerStateIds == ["SPAM"])
    #expect(
      client.requestedPages == [
        "projects-id|0", "junk-id|0", "junk-projects-id|0", "archive-projects-id|0",
      ])
  }

  @Test
  func testDeletingArchiveMessageTargetsArchiveDeletedItems() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    let archiveMessage = ewsMessage(
      1,
      folderId: "archive-projects-id",
      conversationId: "conversation-1"
    )
    client.folders += [
      EWSFolder(
        changeKey: "archive-projects-key",
        displayName: "Archive Projects",
        id: "archive-projects-id",
        isArchiveHierarchy: true,
        role: nil
      ),
      EWSFolder(
        changeKey: "archive-deleted-key",
        displayName: "Archive Deleted Items",
        id: "archive-deleted-id",
        isArchiveHierarchy: true,
        isTrashHierarchy: true,
        role: nil
      ),
    ]
    client.pages["archive-projects-id|0"] = EWSMessagePage(
      messages: [archiveMessage],
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
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    let archiveProjects = try await adapter.loadMailbox(
      .providerMailbox(EWSProviderMessage.customFolderStateId("archive-projects-id")),
      connection: connection,
      session: session
    )

    try await adapter.perform(
      .delete,
      messages: [try requireValue(archiveProjects.messages.first)],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connection: connection, session: session)
    let retryError = await adapter.waitForPendingActionRetries(
      connection: connection,
      session: session
    )

    #expect(retryError == nil)
    #expect(client.performedActions.last?.action == .delete)
    #expect(client.performedActions.last?.targetFolderId == "archive-deleted-id")
  }

  @Test
  func testArchiveStoreCrossMailboxActionsAreRejectedBeforeEnqueue() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    let archiveMessage = ewsMessage(
      1,
      folderId: "archive-projects-id",
      conversationId: "conversation-1"
    )
    client.folders.append(
      EWSFolder(
        changeKey: "archive-projects-key",
        displayName: "Archive Projects",
        id: "archive-projects-id",
        isArchiveHierarchy: true,
        role: nil
      )
    )
    client.pages["archive-projects-id|0"] = EWSMessagePage(
      messages: [archiveMessage],
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
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    let archiveProjects = try await adapter.loadMailbox(
      .providerMailbox(EWSProviderMessage.customFolderStateId("archive-projects-id")),
      connection: connection,
      session: session
    )
    let message = try requireValue(archiveProjects.messages.first)

    for action in [ProviderMailAction.move, .restore, .spam] {
      do {
        try await adapter.perform(
          action,
          targetProviderMailboxId: EWSProviderMessage.customFolderStateId("inbox-id"),
          messages: [message],
          connection: connection,
          session: session
        )
        Issue.record("Expected \(action) to be rejected for an archive-store message")
      } catch {
        #expect(error as? MailboxConnectionAdapterError == .unsupportedCapability)
      }
    }
    #expect(client.performedActions.isEmpty)
  }

  @Test
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
    var now = Date(timeIntervalSince1970: 2_000_000_000)
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
      now: { now }
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

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
    let verified = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )
    client.pages["inbox-id|50"] = EWSMessagePage(
      messages: [
        ewsMessage(
          2,
          folderId: "inbox-id",
          conversationId: "conversation-2",
          isRead: false
        )
      ],
      nextOffset: 100
    )
    _ = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: false,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )
    let throttled = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )
    #expect(client.requestedPages.count == 7)
    #expect(
      !(try requireValue(
        throttled.messages.first(where: { $0.providerMessageId == "ews-stable-2" })?
          .providerStateIds
      ).contains("UNREAD")))
    now.addTimeInterval(EWSMailboxConnectionAdapter.completedReconciliationInterval)
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
    #expect(!(complete.historicalMetadataBackfillIsComplete))
    #expect(verified.historicalMetadataBackfillIsComplete)
    let reconciledMessage = try requireValue(
      reconciled.messages.first(where: { $0.providerMessageId == "ews-stable-2" }))
    #expect(try requireValue(reconciledMessage.providerStateIds).contains("UNREAD"))
    #expect(
      Set(complete.messages.map(\.providerMessageId)) == [
        "ews-stable-1", "ews-stable-2", "ews-stable-3",
      ])
    #expect(
      client.requestedPages == [
        "inbox-id|0", "inbox-id|50", "inbox-id|100", "inbox-id|0", "inbox-id|50",
        "inbox-id|100", "inbox-id|0", "inbox-id|0", "inbox-id|50", "inbox-id|100",
      ])
  }

  @Test
  func testHistoricalBackfillPersistsOnlyMessagesFromEachPage() async throws {
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
    let connection = try requireValue(connections.first)

    _ = try await adapter.syncInbox(connection: connection, session: session)
    let result = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    #expect(metadataStore.messageWriteCounts == [1, 1, 1])
    #expect(metadataStore.reconciliationWriteCounts == [1, 1, 2])
    #expect(
      Set(result.messages.map(\.providerMessageId)) == [
        "ews-stable-1", "ews-stable-2", "ews-stable-3",
      ])
    #expect(
      try requireValue(
        metadataStore.load(
          productAccountId: session.productAccountId,
          connectionId: connection.id
        )
      ).nextOffsetsByFolderId.isEmpty)
  }

  @Test(arguments: [[], ["system:invoices", "system:travel"]])
  func testSetCategoriesRejectsUnsupportedCountsWithoutMutatingMetadata(
    _ categoryIds: [String]
  ) async throws {
    let definition = makeEWSDefinition()
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let providerMessage = ewsMessage(
      1,
      folderId: "inbox-id",
      conversationId: "conversation-1"
    )
    let metadataStore = InMemoryEWSMetadataStore()
    try metadataStore.save(
      snapshot(message: providerMessage),
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId
    )
    let adapter = EWSMailboxConnectionAdapter(
      authorizationStore: authorizations,
      definitionSyncService: RecordingEWSDefinitionSyncService(
        definition: definition.synchronizedDefinition(
          connectedAt: 1_781_200_000_000,
          displayName: definition.emailAddress
        )
      ),
      metadataStore: metadataStore
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let message = providerMessage.mailboxMetadata(
      connection: connection,
      foldersById: [
        "inbox-id": EWSFolder(
          changeKey: "inbox-key",
          displayName: "Inbox",
          id: "inbox-id",
          role: .inbox
        )
      ]
    )

    do {
      _ = try await adapter.setCategories(categoryIds, for: message, session: session)
      Issue.record("Expected unsupported category count to be rejected")
    } catch {
      #expect(error as? MailboxConnectionAdapterError == .unsupportedProvider)
    }

    let stored = try requireValue(
      try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )?.messages.first)
    #expect(stored.categoryId == nil)
  }

  @Test
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
    let firstConnection = try requireValue(
      connections.first(where: { $0.id == firstDefinition.connectionId }))
    let secondConnection = try requireValue(
      connections.first(where: { $0.id == secondDefinition.connectionId }))
    let firstInbox = try await adapter.loadInbox(connection: firstConnection, session: session)
    let secondInbox = try await adapter.loadInbox(connection: secondConnection, session: session)
    let firstMessage = try requireValue(firstInbox.messages.first)
    let secondMessage = try requireValue(secondInbox.messages.first)

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

    #expect(error != nil)
    #expect(
      client.performedActions.filter { $0.connectionId == secondConnection.id }.map(\.action) == [
        .archive
      ])
  }

  @Test
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
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.loadInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)
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

    #expect(body.text == "Message body")
    #expect(client.loadedBodyItemId == "ews-current-1")
    #expect(client.sentMessages == [outgoing])
  }

  @Test
  func testEWSBodyCachesOnlyFileDescriptorsAndDownloadsWithinOwningMessage() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.body = "Private body"
    var storedMessage = ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")
    storedMessage.hasAttachments = true
    client.attachmentDescriptors[storedMessage.itemId] = [
      EWSAttachmentDescriptor(
        byteCount: 3,
        filename: "report.pdf",
        kind: .file,
        mimeType: "application/pdf",
        providerAttachmentId: "file-id"
      ),
      EWSAttachmentDescriptor(
        byteCount: 2,
        filename: "inline.png",
        kind: .inlineImage,
        mimeType: "image/png",
        providerAttachmentId: "inline-id"
      ),
      EWSAttachmentDescriptor(
        byteCount: 10,
        filename: "attached-message.eml",
        kind: .unsupportedItem,
        mimeType: "message/rfc822",
        providerAttachmentId: "item-id"
      ),
    ]
    client.attachmentData["file-id"] = Data("PDF".utf8)
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let metadata = InMemoryEWSMetadataStore()
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
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.loadInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)

    let first = try await adapter.loadMessageBody(message: message, session: session)
    let second = try await adapter.loadMessageBody(message: message, session: session)
    let attachment = try requireValue(first.attachments.first)
    let identifier = try requireValue(EWSMessageAttachmentIdentifier(rawValue: attachment.id))
    let data = try await adapter.loadMessageAttachment(
      attachment,
      message: message,
      session: session
    )

    #expect(first.attachments.map(\.filename) == ["report.pdf"])
    #expect(second == first)
    #expect(client.bodyRequestCount == 1)
    #expect(client.attachmentDescriptorItemIds == [storedMessage.itemId])
    #expect(identifier.ownerStableProviderMessageId == storedMessage.stableProviderId)
    #expect(identifier.providerAttachmentId == "file-id")
    #expect(data == Data("PDF".utf8))
    #expect(
      client.attachmentRequests == [
        RecordingEWSClient.AttachmentRequest(
          expectedByteCount: 3,
          maximumByteCount: MailboxMessageAttachmentPolicy.maximumByteCount,
          providerAttachmentId: "file-id"
        )
      ])

    let foreignIdentifier = try requireValue(
      EWSMessageAttachmentIdentifier(
        ownerStableProviderMessageId: "another-message",
        providerAttachmentId: "file-id"
      ))
    do {
      _ = try await adapter.loadMessageAttachment(
        MailboxMessageAttachment(
          byteCount: 3,
          filename: "report.pdf",
          id: foreignIdentifier.rawValue,
          mimeType: "application/pdf"
        ),
        message: message,
        session: session
      )
      Issue.record("Expected a cross-message EWS attachment identity to be rejected")
    } catch MailboxMessageAttachmentError.invalidResponse {
    } catch {
      Issue.record("Expected an invalid attachment response, got \(error)")
    }
    #expect(client.attachmentRequests.count == 1)
  }

  @Test
  func testUncachedBodyRecoversExternallyMovedHistoricalMessageIdentity() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.body = "Recovered body"
    client.remainingBodyItemNotFoundFailures = 1
    let inbox = EWSFolder(
      changeKey: "inbox-key",
      displayName: "Inbox",
      id: "inbox-id",
      role: .inbox
    )
    let projects = EWSFolder(
      changeKey: nil,
      displayName: "Projects",
      id: "projects-id",
      role: nil
    )
    client.folders = [inbox, projects]
    let stale = ewsMessage(1, folderId: inbox.id, conversationId: "conversation-1")
    client.recoveredIdentitiesByStableId[stale.stableProviderId] = EWSMovedItemIdentity(
      changeKey: "moved-change-key",
      destinationFolderId: projects.id,
      itemId: "moved-item-id",
      stableProviderId: stale.stableProviderId
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let metadata = InMemoryEWSMetadataStore()
    try metadata.save(
      EWSMetadataSnapshot(
        folders: client.folders,
        messages: [stale],
        nextOffsetsByFolderId: [inbox.id: 50],
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
      metadataStore: metadata
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let loadedInbox = try await adapter.loadInbox(connection: connection, session: session)
    let message = try requireValue(loadedInbox.messages.first)

    let body = try await adapter.loadMessageBody(message: message, session: session)

    #expect(body.text == "Recovered body")
    #expect(client.loadedBodyItemIds == [stale.itemId, "moved-item-id"])
    #expect(client.recoveredStableIds == [stale.stableProviderId])
    #expect(client.recoveryFolderIds == [inbox.id, projects.id])
    let stored = try requireValue(
      try metadata.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )?.messages.first)
    #expect(stored.itemId == "moved-item-id")
    #expect(stored.changeKey == "moved-change-key")
    #expect(stored.parentFolderId == projects.id)
  }

  @Test
  func testBodyPrefetchRecoversExternallyMovedHistoricalMessageIdentity() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.body = "Recovered body"
    let inbox = EWSFolder(
      changeKey: "inbox-key",
      displayName: "Inbox",
      id: "inbox-id",
      role: .inbox
    )
    let projects = EWSFolder(
      changeKey: nil,
      displayName: "Projects",
      id: "projects-id",
      role: nil
    )
    let trash = EWSFolder(
      changeKey: "trash-key",
      displayName: "Trash",
      id: "trash-id",
      role: .trash
    )
    client.folders = [projects, inbox, trash]
    let stale = ewsMessage(1, folderId: inbox.id, conversationId: "conversation-1")
    let secondStale = ewsMessage(2, folderId: inbox.id, conversationId: "conversation-2")
    let trashedStale = ewsMessage(3, folderId: inbox.id, conversationId: "conversation-3")
    client.bodyItemNotFoundItemIds = [stale.itemId, secondStale.itemId, trashedStale.itemId]
    client.recoveredIdentitiesByStableId[stale.stableProviderId] = EWSMovedItemIdentity(
      changeKey: "moved-change-key",
      destinationFolderId: projects.id,
      itemId: "moved-item-id",
      stableProviderId: stale.stableProviderId
    )
    client.recoveredIdentitiesByStableId[secondStale.stableProviderId] = EWSMovedItemIdentity(
      changeKey: "second-moved-change-key",
      destinationFolderId: projects.id,
      itemId: "second-moved-item-id",
      stableProviderId: secondStale.stableProviderId
    )
    client.recoveredIdentitiesByStableId[trashedStale.stableProviderId] = EWSMovedItemIdentity(
      changeKey: "trashed-change-key",
      destinationFolderId: trash.id,
      itemId: "trashed-item-id",
      stableProviderId: trashedStale.stableProviderId
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let metadata = InMemoryEWSMetadataStore()
    try metadata.save(
      EWSMetadataSnapshot(
        folders: [inbox, projects, trash],
        messages: [stale, secondStale, trashedStale],
        nextOffsetsByFolderId: [inbox.id: 50],
        hasInitialMailboxAvailability: true
      ),
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
    let connection = try requireValue(connections.first)
    let loadedInbox = try await adapter.loadInbox(connection: connection, session: session)
    let messages = loadedInbox.messages

    try await adapter.prefetchMessageBodies(
      connection: connection,
      pinnedThreadIds: Set(messages.map(\.threadIdentity)),
      referenceDate: Date(timeIntervalSince1970: 2_000_000_000),
      session: session
    )

    #expect(
      Set(client.loadedBodyItemIds) == [
        stale.itemId, "moved-item-id", secondStale.itemId, "second-moved-item-id",
        trashedStale.itemId,
      ])
    #expect(client.loadedBodyItemIds.count == 5)
    #expect(
      Set(client.recoveredStableIds) == [
        stale.stableProviderId, secondStale.stableProviderId, trashedStale.stableProviderId,
      ])
    #expect(client.loadFoldersCallCount == 1)
    let storedSnapshot = try requireValue(
      try metadata.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ))
    let stored = try requireValue(
      storedSnapshot.messages.first { $0.stableProviderId == stale.stableProviderId })
    #expect(stored.itemId == "moved-item-id")
    #expect(stored.changeKey == "moved-change-key")
    #expect(stored.parentFolderId == projects.id)
    #expect(storedSnapshot.folders.map(\.id) == [projects.id, inbox.id, trash.id])
    for message in messages where message.providerMessageId != trashedStale.stableProviderId {
      let cached = try await adapter.loadMessageBody(message: message, session: session)
      #expect(cached.text == "Recovered body")
    }
    #expect(client.loadedBodyItemIds.count == 5)
  }

  @Test
  func testBodyCacheSurvivesMetadataOnlyChangeKeyChanges() async throws {
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
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.loadInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)

    let original = try await adapter.loadMessageBody(message: message, session: session)
    storedMessage.changeKey = "changed-by-another-client"
    try metadata.save(
      snapshot(message: storedMessage),
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId
    )
    client.body = "Updated body"
    let updated = try await adapter.loadMessageBody(message: message, session: session)

    #expect(original.text == "Original body")
    #expect(updated.text == "Original body")
    #expect(client.bodyRequestCount == 1)
  }

  @Test
  func testBodyCacheInvalidatesWhenDraftChangeKeyChanges() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.body = "Original draft"
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let metadata = InMemoryEWSMetadataStore()
    var storedMessage = ewsMessage(
      1,
      folderId: "drafts-id",
      conversationId: "conversation-1",
      isDraft: true
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
    let connection = try requireValue(connections.first)
    let message = storedMessage.mailboxMetadata(
      connection: connection,
      foldersById: [
        "drafts-id": EWSFolder(
          changeKey: "drafts-key",
          displayName: "Drafts",
          id: "drafts-id",
          role: .drafts
        )
      ]
    )

    let original = try await adapter.loadMessageBody(message: message, session: session)
    storedMessage.changeKey = "edited-draft"
    try metadata.save(
      snapshot(message: storedMessage),
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId
    )
    client.body = "Edited draft"
    let updated = try await adapter.loadMessageBody(message: message, session: session)

    #expect(original.text == "Original draft")
    #expect(updated.text == "Edited draft")
    #expect(client.bodyRequestCount == 2)
  }

  @Test
  func testPreDeliveryHostFailureRetriesThroughSharedQueue() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.remainingOfflineFailuresByConnectionId[definition.connectionId] = 1
    client.offlineFailureCode = .cannotFindHost
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
    let connection = try requireValue(connections.first)
    let initial = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(initial.messages.first)

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

    #expect(retryError == nil)
    #expect(client.performedActions.map(\.action) == [.markRead])
    #expect(client.remainingOfflineFailuresByConnectionId[connection.id] == 0)
  }

  @Test
  func testTransientEWSServerResponseRetriesThroughSharedQueue() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.remainingActionFailuresByConnectionId[definition.connectionId] = 1
    client.actionFailureCode = "ErrorADUnavailable"
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
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)

    try await adapter.perform(
      .markRead,
      messages: [try requireValue(inbox.messages.first)],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connection: connection, session: session)
    let retryError = await adapter.waitForPendingActionRetries(
      connection: connection,
      session: session
    )

    #expect(retryError == nil)
    #expect(client.performedActions.map(\.action) == [.markRead])
  }

  @Test
  func testPreMutationInvalidIdentityResponseRetriesThroughSharedQueue() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.remainingInvalidIdentityRefreshes = 1
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
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)

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

    #expect(retryError == nil)
    #expect(client.performedActions.map(\.action) == [.markRead])
    #expect(client.remainingInvalidIdentityRefreshes == 0)
  }

  @Test
  func testMissingIdentityAfterAmbiguousMoveRemainsBlockedForReconciliation() async throws {
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
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    client.pages["inbox-id|0"] = EWSMessagePage(messages: [], nextOffset: 50)
    client.identityRefreshError = EWSServiceError.response(
      code: "ErrorItemNotFound",
      message: "The item no longer exists at this identity."
    )

    try await adapter.perform(
      .move,
      targetProviderMailboxId: EWSProviderMessage.customFolderStateId("destination-id"),
      messages: [try requireValue(inbox.messages.first)],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connection: connection, session: session)

    let blockedIds = await adapter.blockedPendingActionConnectionIds(
      connections: [connection],
      session: session
    )
    #expect(blockedIds == [connection.id])
    #expect(client.performedActions.isEmpty)
  }

  @Test
  func testActionRecoversExternallyMovedHistoricalMessageIdentity() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    let inbox = EWSFolder(
      changeKey: "inbox-key",
      displayName: "Inbox",
      id: "inbox-id",
      role: .inbox
    )
    let projects = EWSFolder(
      changeKey: nil,
      displayName: "Projects",
      id: "projects-id",
      role: nil
    )
    client.folders = [inbox, projects]
    var recent = ewsMessage(
      2,
      folderId: inbox.id,
      conversationId: "conversation-2",
      isRead: false
    )
    recent.stableProviderId = recent.itemId
    let stale = ewsMessage(1, folderId: inbox.id, conversationId: "conversation-1")
    client.pages["\(inbox.id)|0"] = EWSMessagePage(messages: [recent], nextOffset: 50)
    client.pages["\(projects.id)|0"] = EWSMessagePage(messages: [], nextOffset: 50)
    client.missingIdentityStableIds = [stale.stableProviderId]
    client.recoveredIdentitiesByStableId[stale.stableProviderId] = EWSMovedItemIdentity(
      changeKey: "moved-change-key",
      destinationFolderId: projects.id,
      itemId: "moved-item-id",
      stableProviderId: stale.stableProviderId
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let metadata = InMemoryEWSMetadataStore()
    try metadata.save(
      EWSMetadataSnapshot(
        folders: client.folders,
        messages: [recent, stale],
        nextOffsetsByFolderId: [inbox.id: 50],
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
    let connection = try requireValue(connections.first)
    let loadedInbox = try await adapter.loadInbox(connection: connection, session: session)
    let messages = loadedInbox.messages

    try await adapter.perform(
      .markRead,
      messages: messages,
      connection: connection,
      session: session
    )
    let error = await adapter.resumePendingActions(connection: connection, session: session)

    #expect(error == nil)
    #expect(client.recoveredStableIds == [stale.stableProviderId])
    #expect(client.performedMessageItemIds == [[recent.itemId, "moved-item-id"]])
    #expect(client.performedMessageChangeKeys == [[recent.changeKey, "moved-change-key"]])
    let stored = try requireValue(
      try metadata.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )?.messages.first { $0.stableProviderId == stale.stableProviderId })
    #expect(stored.itemId == "moved-item-id")
    #expect(stored.changeKey == "moved-change-key")
    #expect(stored.parentFolderId == projects.id)
    #expect(stored.isRead)
  }

  @Test
  func testActionStopsWhenRecoveredIdentityConfirmsMoveAlreadyCompleted() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    let inbox = EWSFolder(
      changeKey: "inbox-key",
      displayName: "Inbox",
      id: "inbox-id",
      role: .inbox
    )
    let projects = EWSFolder(
      changeKey: nil,
      displayName: "Projects",
      id: "projects-id",
      role: nil
    )
    client.folders = [inbox, projects]
    let recent = ewsMessage(2, folderId: inbox.id, conversationId: "conversation-2")
    let stale = ewsMessage(1, folderId: inbox.id, conversationId: "conversation-1")
    client.pages["\(inbox.id)|0"] = EWSMessagePage(messages: [recent], nextOffset: nil)
    client.pages["\(projects.id)|0"] = EWSMessagePage(messages: [], nextOffset: nil)
    client.identityRefreshError = EWSServiceError.response(
      code: "ErrorItemNotFound",
      message: "The item no longer exists at this identity."
    )
    client.recoveredIdentitiesByStableId[stale.stableProviderId] = EWSMovedItemIdentity(
      changeKey: "moved-change-key",
      destinationFolderId: projects.id,
      itemId: "moved-item-id",
      stableProviderId: stale.stableProviderId
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let metadata = InMemoryEWSMetadataStore()
    try metadata.save(
      EWSMetadataSnapshot(
        folders: client.folders,
        messages: [recent, stale],
        nextOffsetsByFolderId: [inbox.id: 50],
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
    let connection = try requireValue(connections.first)
    let loadedInbox = try await adapter.loadInbox(connection: connection, session: session)
    let message = try requireValue(
      loadedInbox.messages.first { $0.providerMessageId == stale.stableProviderId })

    try await adapter.perform(
      .move,
      targetProviderMailboxId: EWSProviderMessage.customFolderStateId(projects.id),
      messages: [message],
      connection: connection,
      session: session
    )
    let error = await adapter.resumePendingActions(connection: connection, session: session)

    #expect(error == nil)
    #expect(client.recoveredStableIds == [stale.stableProviderId])
    #expect(client.performedActions.isEmpty)
    let stored = try requireValue(
      try metadata.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )?.messages.first { $0.stableProviderId == stale.stableProviderId })
    #expect(stored.parentFolderId == projects.id)
  }

  @Test
  func testActionRecoveryReappliesArchiveSourceRestriction() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    let inbox = EWSFolder(
      changeKey: "inbox-key",
      displayName: "Inbox",
      id: "inbox-id",
      role: .inbox
    )
    let projects = EWSFolder(
      changeKey: nil,
      displayName: "Projects",
      id: "projects-id",
      role: nil
    )
    let archive = EWSFolder(
      changeKey: "archive-key",
      displayName: "Online Archive",
      id: "archive-id",
      isArchiveHierarchy: true,
      role: nil
    )
    client.folders = [inbox, projects, archive]
    let recent = ewsMessage(2, folderId: inbox.id, conversationId: "conversation-2")
    let stale = ewsMessage(1, folderId: inbox.id, conversationId: "conversation-1")
    client.pages["\(inbox.id)|0"] = EWSMessagePage(messages: [recent], nextOffset: 50)
    client.pages["\(projects.id)|0"] = EWSMessagePage(messages: [], nextOffset: nil)
    client.pages["\(archive.id)|0"] = EWSMessagePage(messages: [], nextOffset: nil)
    client.identityRefreshError = EWSServiceError.response(
      code: "ErrorItemNotFound",
      message: "The item no longer exists at this identity."
    )
    client.recoveredIdentitiesByStableId[stale.stableProviderId] = EWSMovedItemIdentity(
      changeKey: "archive-change-key",
      destinationFolderId: archive.id,
      itemId: "archive-item-id",
      stableProviderId: stale.stableProviderId
    )
    let authorizations = InMemoryEWSAuthorizationStore()
    try authorizations.save(
      DeviceLocalEWSAuthorization(credential: "password", definition: definition),
      productAccountId: session.productAccountId
    )
    let metadata = InMemoryEWSMetadataStore()
    try metadata.save(
      EWSMetadataSnapshot(
        folders: client.folders,
        messages: [recent, stale],
        nextOffsetsByFolderId: [inbox.id: 50],
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
    let connection = try requireValue(connections.first)
    let loadedInbox = try await adapter.loadInbox(connection: connection, session: session)
    let message = try requireValue(
      loadedInbox.messages.first { $0.providerMessageId == stale.stableProviderId })

    try await adapter.perform(
      .move,
      targetProviderMailboxId: EWSProviderMessage.customFolderStateId(projects.id),
      messages: [message],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connection: connection, session: session)

    let blockedIds = await adapter.blockedPendingActionConnectionIds(
      connections: [connection],
      session: session
    )
    #expect(blockedIds.isEmpty)
    #expect(client.recoveredStableIds == [stale.stableProviderId])
    #expect(client.performedActions.isEmpty)
  }

  @Test
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
    let connection = try requireValue(connections.first)
    let sent = try await adapter.loadMailbox(
      .role(.sent),
      connection: connection,
      session: session
    )

    try await adapter.perform(
      .archive,
      messages: [try requireValue(sent.messages.first)],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connection: connection, session: session)
    let retryError = await adapter.waitForPendingActionRetries(
      connection: connection,
      session: session
    )

    #expect(retryError == nil)
    #expect(client.performedActions.map(\.action) == [.archive])
    #expect(client.performedMessageChangeKeys == [["refreshed-change-key"]])
  }

  @Test
  func testPostCommitRefreshFailureDoesNotRetryConfirmedAction() async throws {
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
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    client.failPageLoadsAfterAction = true

    try await adapter.perform(
      .markRead,
      messages: [try requireValue(inbox.messages.first)],
      connection: connection,
      session: session
    )
    let failure = await adapter.resumePendingActions(
      connection: connection,
      session: session
    )

    #expect(failure == nil)
    #expect(client.performedActions.map(\.action) == [.markRead])
  }

  @Test
  func testBulkActionSharesMailboxRefreshesAcrossSelectedMessages() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.folders = [
      EWSFolder(changeKey: "inbox-key", displayName: "Inbox", id: "inbox-id", role: .inbox)
    ]
    client.pages["inbox-id|0"] = EWSMessagePage(
      messages: [
        ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1"),
        ewsMessage(2, folderId: "inbox-id", conversationId: "conversation-2"),
      ],
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
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let folderLoadsBeforeAction = client.loadFoldersCallCount
    let pageLoadsBeforeAction = client.requestedPages.count

    try await adapter.perform(
      .markRead,
      messages: inbox.messages,
      connection: connection,
      session: session
    )
    let failure = await adapter.resumePendingActions(
      connection: connection,
      session: session
    )

    #expect(failure == nil)
    #expect(client.loadFoldersCallCount - folderLoadsBeforeAction == 2)
    #expect(client.requestedPages.count - pageLoadsBeforeAction == 2)
    #expect(client.performedActions.map(\.action) == [.markRead])
    #expect(
      Set(try requireValue(client.performedMessageItemIds.first)) == [
        "ews-current-1", "ews-current-2",
      ])
  }

  @Test
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
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.syncInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)

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
    #expect(blockedIds == [connection.id])
  }

  @Test
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
    let connection = try requireValue(connections.first)
    let inbox = try await adapter.loadInbox(connection: connection, session: session)
    let message = try requireValue(inbox.messages.first)
    definitions.removedConnectionIds = [connection.id]

    do {
      _ = try await adapter.loadMessageBody(message: message, session: session)
      Issue.record("Expected synchronized removal to fence provider access")
    } catch {}
    #expect(
      try authorizations.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ) == nil)
    #expect(
      try metadata.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ) == nil)
  }

  @Test
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

    #expect(connections.map(\.id) == [definition.connectionId])
    #expect(definitions.providerAccessLoads == 1)
  }

  @Test
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
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    var changed = ewsMessage(1, folderId: "inbox-id", conversationId: "conversation-1")
    changed.itemId = "ews-moved-1"
    changed.isRead = true
    client.pages["inbox-id|0"] = EWSMessagePage(messages: [changed], nextOffset: nil)

    let result = try await adapter.syncInbox(connection: connection, session: session)

    #expect(result.messages.map(\.providerMessageId) == ["ews-stable-1"])
    #expect(!(result.messages[0].providerStateIds?.contains("UNREAD") == true))
    _ = try await adapter.loadMessageBody(message: result.messages[0], session: session)
    #expect(client.loadedBodyItemId == "ews-moved-1")

    client.pages["inbox-id|0"] = EWSMessagePage(messages: [], nextOffset: nil)
    let afterDeletion = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: false,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )
    #expect(afterDeletion.messages.isEmpty)
  }

  @Test
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
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    var stored = try requireValue(
      try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ))
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

    #expect(result.messages.map(\.providerMessageId) == [original.stableProviderId])
    _ = try await adapter.loadMessageBody(message: result.messages[0], session: session)
    #expect(client.loadedBodyItemId == refreshed.itemId)
  }

  @Test
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
    let connection = try requireValue(connections.first)
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

    #expect(
      Set(result.messages.map(\.providerMessageId))
        == Set([observed.stableProviderId, tied.stableProviderId]))
  }

  @Test
  func testRecentSyncPersistsMultipleUpsertsInSnapshotOrder() async throws {
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
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    let refreshedMessages = [5, 2, 9, 3, 8, 4, 7, 6].map {
      ewsMessage($0, folderId: "inbox-id", conversationId: "conversation-\($0)")
    }
    client.pages["inbox-id|0"] = EWSMessagePage(messages: refreshedMessages, nextOffset: nil)

    _ = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: false,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    #expect(
      try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )?.messages.map(\.stableProviderId) == refreshedMessages.map(\.stableProviderId))
  }

  @Test
  func testRecentSyncConfirmsMissingFolderBeforeDeletingItsMessages() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    let inboxFolder = EWSFolder(
      changeKey: "inbox-key",
      displayName: "Inbox",
      id: "inbox-id",
      role: .inbox
    )
    let projectsFolder = EWSFolder(
      changeKey: "projects-key",
      displayName: "Projects",
      id: "projects-id",
      role: nil
    )
    client.folders = [inboxFolder, projectsFolder]
    client.pages["inbox-id|0"] = EWSMessagePage(messages: [], nextOffset: nil)
    client.pages["projects-id|0"] = EWSMessagePage(
      messages: [ewsMessage(1, folderId: "projects-id", conversationId: "conversation-1")],
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
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    client.folders = [inboxFolder]

    _ = try await adapter.syncInbox(connection: connection, session: session)
    let afterFirstMiss = try requireValue(
      try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ))
    #expect(afterFirstMiss.messages.map(\.stableProviderId) == ["ews-stable-1"])
    #expect(afterFirstMiss.missingFolderIds == ["projects-id"])

    _ = try await adapter.syncInbox(connection: connection, session: session)
    let afterConfirmedMiss = try requireValue(
      try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ))
    #expect(afterConfirmedMiss.messages.isEmpty)
    #expect(afterConfirmedMiss.missingFolderIds?.isEmpty == true)
  }

  @Test
  func testRecentInitialSyncDoesNotPersistAfterSessionBecomesStale() async throws {
    let definition = makeEWSDefinition()
    let client = RecordingEWSClient()
    client.folders = [
      EWSFolder(changeKey: "inbox-key", displayName: "Inbox", id: "inbox-id", role: .inbox),
      EWSFolder(changeKey: nil, displayName: "Projects", id: "projects-id", role: nil),
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
    let connection = try requireValue(connections.first)
    let didLoadMessagePage = LockedBoolean()
    client.didLoadMessagePage = {
      didLoadMessagePage.setTrue()
    }

    do {
      _ = try await adapter.syncRecentInbox(
        connection: connection,
        includingHistoryCandidates: false,
        session: session,
        sinceHistoryId: nil,
        throughHistoryId: nil,
        shouldPersist: {
          !didLoadMessagePage.value
        }
      )
      Issue.record("Expected stale session cancellation")
    } catch is CancellationError {}

    #expect(client.requestedPages == ["inbox-id|0"])
    #expect(
      try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ) == nil)
  }

  @Test
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
    var now = Date(timeIntervalSince1970: 2_000_000_000)
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
      now: { now }
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    let complete = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )
    #expect(Set(complete.messages.map(\.providerMessageId)) == ["ews-stable-1", "ews-stable-2"])

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

    #expect(Set(reconciled.messages.map(\.providerMessageId)) == ["ews-stable-1", "ews-stable-2"])

    now.addTimeInterval(EWSMailboxConnectionAdapter.completedReconciliationInterval)
    _ = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: false,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )
    _ = try await adapter.continueHistoricalBackfill(
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
    let deletionReconciled = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    #expect(Set(deletionReconciled.messages.map(\.providerMessageId)) == ["ews-stable-2"])
  }

  @Test
  func testSinglePageReconciliationClearsPendingVerificationMarker() async throws {
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
    let connection = try requireValue(connections.first)
    _ = try await adapter.syncInbox(connection: connection, session: session)
    _ = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )
    let awaitingVerification = try requireValue(
      try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ))
    #expect(awaitingVerification.pendingVerificationFolderIds == ["inbox-id"])

    client.pages["inbox-id|0"] = EWSMessagePage(messages: [recent], nextOffset: nil)
    _ = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: false,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    let reconciled = try requireValue(
      try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ))
    #expect(reconciled.pendingVerificationFolderIds?.isEmpty == true)
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
            <t:Body BodyType="Text">  Rendered message body&#10;</t:Body>
          </t:Message></m:Items>
        </m:GetItemResponseMessage>
      </m:ResponseMessages></m:GetItemResponse></s:Body>
    </s:Envelope>
    """

  private static let getAttachmentDescriptorsResponse = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
      <s:Body><m:GetItemResponse><m:ResponseMessages>
        <m:GetItemResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
          <m:Items><t:Message><t:Attachments>
            <t:FileAttachment>
              <t:AttachmentId Id="file-id"/><t:Name>report.pdf</t:Name>
              <t:ContentType>application/pdf</t:ContentType><t:Size>3</t:Size>
              <t:IsInline>false</t:IsInline>
            </t:FileAttachment>
            <t:FileAttachment>
              <t:AttachmentId Id="inline-id"/><t:Name>inline.png</t:Name>
              <t:ContentType>image/png</t:ContentType><t:ContentId>hero-image</t:ContentId>
              <t:Size>2</t:Size><t:IsInline>true</t:IsInline>
            </t:FileAttachment>
            <t:ItemAttachment>
              <t:AttachmentId Id="item-id"/><t:Name>attached-message.eml</t:Name>
              <t:ContentType>message/rfc822</t:ContentType><t:Size>10</t:Size>
            </t:ItemAttachment>
          </t:Attachments></t:Message></m:Items>
        </m:GetItemResponseMessage>
      </m:ResponseMessages></m:GetItemResponse></s:Body>
    </s:Envelope>
    """

  private static let getAttachmentResponse = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
      <s:Body><m:GetAttachmentResponse><m:ResponseMessages>
        <m:GetAttachmentResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
          <m:Attachments><t:FileAttachment>
            <t:AttachmentId Id="file-id"/><t:Name>report.pdf</t:Name>
            <t:ContentType>application/pdf</t:ContentType><t:Size>3</t:Size>
            <t:Content>UERG</t:Content>
          </t:FileAttachment></m:Attachments>
        </m:GetAttachmentResponseMessage>
      </m:ResponseMessages></m:GetAttachmentResponse></s:Body>
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
              <t:ParentFolderId Id="archive-custom-id"/>
              <t:DateTimeReceived>2026-07-27T12:34:56.123Z</t:DateTimeReceived>
              <t:HasAttachments>true</t:HasAttachments>
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

  private static let archiveItemWithIdentityResponse = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
      <s:Body><m:ArchiveItemResponse><m:ResponseMessages>
        <m:ArchiveItemResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
          <m:Items><t:Message>
            <t:ItemId Id="archived-item-id" ChangeKey="archive-response-key"/>
          </t:Message></m:Items>
        </m:ArchiveItemResponseMessage>
      </m:ResponseMessages></m:ArchiveItemResponse></s:Body>
    </s:Envelope>
    """

  private static let archiveGetItemResponse = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
      <s:Body><m:GetItemResponse><m:ResponseMessages>
        <m:GetItemResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
          <m:Items><t:Message>
            <t:ItemId Id="archived-item-id" ChangeKey="archived-change-key"/>
            <t:ParentFolderId Id="archive-sent-id"/>
          </t:Message></m:Items>
        </m:GetItemResponseMessage>
      </m:ResponseMessages></m:GetItemResponse></s:Body>
    </s:Envelope>
    """

  private static let archiveFolderResponse = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
      <s:Body><m:FindFolderResponse><m:ResponseMessages>
        <m:FindFolderResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
          <m:RootFolder IncludesLastItemInRange="true">
            <t:Folders>
              <t:Folder>
                <t:FolderId Id="archive-sent-id" ChangeKey="archive-sent-key"/>
                <t:DisplayName>Sent Items</t:DisplayName>
              </t:Folder>
              <t:Folder>
                <t:FolderId Id="archive-custom-id" ChangeKey="archive-custom-key"/>
                <t:DisplayName>Projects</t:DisplayName>
              </t:Folder>
              <t:SearchFolder>
                <t:FolderId Id="archive-search-id" ChangeKey="archive-search-key"/>
                <t:DisplayName>Virtual results</t:DisplayName>
              </t:SearchFolder>
            </t:Folders>
          </m:RootFolder>
        </m:FindFolderResponseMessage>
      </m:ResponseMessages></m:FindFolderResponse></s:Body>
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
                <t:ParentFolderId Id="parent-\(offset)"/>
                <t:DisplayName>Custom \(offset)</t:DisplayName>
                <t:FolderClass>IPF.Note</t:FolderClass>
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
    try ewsRequestBodyText(request, fallbackError: EWSClientTestError.offline) ?? ""
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

  private func makeEWSOAuthConfiguration() throws -> EWSOAuthConfiguration {
    try EWSOAuthConfiguration(
      authorizationEndpoint: requireValue(
        URL(string: "https://login.corp.example/authorize?tenant=mail")),
      callbackScheme: "unwired-ews",
      clientIdentifier: "ews-client",
      scope: "openid offline_access EWS.AccessAsUser.All",
      tokenEndpoint: requireValue(URL(string: "https://login.corp.example/token"))
    )
  }

  private func makeVerifiedEWSDefinition() throws -> EWSConnectionDefinition {
    let endpoint = try requireValue(URL(string: "https://mail.corp.example/EWS/Exchange.asmx"))
    return EWSConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "reader@corp.example",
      endpoint: endpoint,
      providerAccountIdentifier: try EWSConnectionDefinition.stableProviderAccountIdentifier(
        endpoint: endpoint,
        mailboxIdentifier: "mailbox-id"
      ),
      serverVersion: .exchange2019,
      username: #"CORP\reader"#
    )
  }

  private func ewsMessage(
    _ number: Int,
    folderId: String,
    conversationId: String,
    isDraft: Bool = false,
    isRead: Bool? = nil,
    receivedAtMilliseconds: Int64? = nil
  ) -> EWSProviderMessage {
    EWSProviderMessage(
      bccRecipients: [],
      ccRecipients: [],
      changeKey: "change-\(number)",
      conversationId: conversationId,
      from: "Sender <sender@example.com>",
      internetMessageId: "<message-\(number)@example.com>",
      isDraft: isDraft,
      isRead: isRead ?? number.isMultiple(of: 2),
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

private final class LockedBoolean: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue = false

  var value: Bool {
    lock.withLock { storedValue }
  }

  func setTrue() {
    lock.withLock { storedValue = true }
  }
}

private final class RecordingEWSClient: EWSClient, @unchecked Sendable {
  struct AttachmentRequest: Equatable {
    let expectedByteCount: Int
    let maximumByteCount: Int
    let providerAttachmentId: String
  }

  struct PerformedAction: Equatable {
    let action: ProviderMailAction
    let connectionId: MailboxConnectionId
    let targetFolderId: String?
  }

  var actionErrorsByConnectionId: [MailboxConnectionId: Error] = [:]
  var actionFailureCode = "HTTP 503"
  var attachmentData: [String: Data] = [:]
  var attachmentDescriptors: [String: [EWSAttachmentDescriptor]] = [:]
  var account = EWSAccount(
    displayName: "On-Prem Reader",
    primaryEmailAddress: "reader@corp.example",
    providerMailboxIdentifier: "mailbox-id",
    serverVersion: .exchange2019
  )
  var body = ""
  var beforeSendReturn: (() async -> Void)?
  var beforeVerifyReturn: (() async -> Void)?
  var didLoadMessagePage: (() -> Void)?
  var failPageLoadsAfterAction = false
  private var storedBodyRequestCount = 0
  var bodyRequestCount: Int { lock.withLock { storedBodyRequestCount } }
  private var storedAttachmentDescriptorItemIds: [String] = []
  var attachmentDescriptorItemIds: [String] {
    lock.withLock { storedAttachmentDescriptorItemIds }
  }
  private var storedAttachmentRequests: [AttachmentRequest] = []
  var attachmentRequests: [AttachmentRequest] { lock.withLock { storedAttachmentRequests } }
  private var storedBodyItemNotFoundFailures = 0
  var remainingBodyItemNotFoundFailures: Int {
    get { lock.withLock { storedBodyItemNotFoundFailures } }
    set { lock.withLock { storedBodyItemNotFoundFailures = newValue } }
  }
  private var storedBodyItemNotFoundItemIds: Set<String> = []
  var bodyItemNotFoundItemIds: Set<String> {
    get { lock.withLock { storedBodyItemNotFoundItemIds } }
    set { lock.withLock { storedBodyItemNotFoundItemIds = newValue } }
  }
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
  private var storedLoadedBodyItemIds: [String] = []
  var loadedBodyItemIds: [String] { lock.withLock { storedLoadedBodyItemIds } }
  var pages: [String: EWSMessagePage] = [:]
  private var storedPerformedActions: [PerformedAction] = []
  var performedActions: [PerformedAction] { lock.withLock { storedPerformedActions } }
  private var storedPerformedMessageChangeKeys: [[String]] = []
  var performedMessageChangeKeys: [[String]] {
    lock.withLock { storedPerformedMessageChangeKeys }
  }
  private var storedPerformedMessageItemIds: [[String]] = []
  var performedMessageItemIds: [[String]] {
    lock.withLock { storedPerformedMessageItemIds }
  }
  var identityRefreshError: Error?
  var refreshedMessagesByStableId: [String: EWSProviderMessage] = [:]
  var missingIdentityStableIds: Set<String> = []
  var recoveredIdentitiesByStableId: [String: EWSMovedItemIdentity] = [:]
  private var storedRecoveredStableIds: [String] = []
  var recoveredStableIds: [String] { lock.withLock { storedRecoveredStableIds } }
  private var storedRecoveryFolderIds: [String] = []
  var recoveryFolderIds: [String] { lock.withLock { storedRecoveryFolderIds } }
  private var storedLoadFoldersCallCount = 0
  var loadFoldersCallCount: Int { lock.withLock { storedLoadFoldersCallCount } }
  private var storedFolderAuthorizationCredentials: [String] = []
  var loadedFolderAuthorizationCredentials: [String] {
    lock.withLock { storedFolderAuthorizationCredentials }
  }
  private var storedRemainingInvalidIdentityRefreshes = 0
  var remainingInvalidIdentityRefreshes: Int {
    get { lock.withLock { storedRemainingInvalidIdentityRefreshes } }
    set { lock.withLock { storedRemainingInvalidIdentityRefreshes = newValue } }
  }
  private var storedOfflineFailures: [MailboxConnectionId: Int] = [:]
  var remainingOfflineFailuresByConnectionId: [MailboxConnectionId: Int] {
    get { lock.withLock { storedOfflineFailures } }
    set { lock.withLock { storedOfflineFailures = newValue } }
  }
  private var storedOfflineFailureCode: URLError.Code = .notConnectedToInternet
  var offlineFailureCode: URLError.Code {
    get { lock.withLock { storedOfflineFailureCode } }
    set { lock.withLock { storedOfflineFailureCode = newValue } }
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
    await beforeVerifyReturn?()
    return account
  }

  func loadFolders(
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSFolder] {
    lock.withLock {
      storedLoadFoldersCallCount += 1
      storedFolderAuthorizationCredentials.append(authorization.credential)
    }
    return folders
  }

  func loadMessagePage(
    folder: EWSFolder,
    offset: Int,
    pageSize _: Int,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> EWSMessagePage {
    let key = "\(folder.id)|\(offset)"
    lock.withLock { storedRequestedPages.append(key) }
    if failPageLoadsAfterAction, !performedActions.isEmpty {
      throw EWSServiceError.invalidResponse
    }
    let page = pages[key] ?? EWSMessagePage(messages: [], nextOffset: nil)
    didLoadMessagePage?()
    return page
  }

  func loadMessageBody(
    itemId: String,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> String {
    try lock.withLock {
      storedBodyRequestCount += 1
      storedLoadedBodyItemId = itemId
      storedLoadedBodyItemIds.append(itemId)
      if storedBodyItemNotFoundItemIds.remove(itemId) != nil {
        throw EWSServiceError.response(
          code: "ErrorItemNotFound",
          message: "The item no longer exists at this identity."
        )
      }
      if storedBodyItemNotFoundFailures > 0 {
        storedBodyItemNotFoundFailures -= 1
        throw EWSServiceError.response(
          code: "ErrorItemNotFound",
          message: "The item no longer exists at this identity."
        )
      }
      return body
    }
  }

  func loadAttachmentDescriptors(
    itemId: String,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> [EWSAttachmentDescriptor] {
    lock.withLock { storedAttachmentDescriptorItemIds.append(itemId) }
    return attachmentDescriptors[itemId] ?? []
  }

  func loadAttachmentData(
    providerAttachmentId: String,
    expectedByteCount: Int,
    maximumByteCount: Int,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> Data {
    lock.withLock {
      storedAttachmentRequests.append(
        AttachmentRequest(
          expectedByteCount: expectedByteCount,
          maximumByteCount: maximumByteCount,
          providerAttachmentId: providerAttachmentId
        )
      )
    }
    guard let data = attachmentData[providerAttachmentId],
      data.count <= maximumByteCount,
      expectedByteCount == 0 || data.count <= expectedByteCount
    else { throw MailboxMessageAttachmentError.invalidResponse }
    return data
  }

  func refreshMessageIdentities(
    _ messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSProviderMessage] {
    let refreshed = try await refreshMessageIdentitiesAllowingMissing(
      messages,
      authorization: authorization
    )
    guard refreshed.allSatisfy({ $0 != nil }) else {
      throw EWSServiceError.response(code: "ErrorItemNotFound", message: "Item not found")
    }
    return refreshed.compactMap { $0 }
  }

  func refreshMessageIdentitiesAllowingMissing(
    _ messages: [EWSProviderMessage],
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> [EWSProviderMessage?] {
    if let identityRefreshError {
      if let serviceError = identityRefreshError as? EWSServiceError,
        serviceError.isItemNotFound
      {
        return messages.map { _ in nil }
      }
      throw identityRefreshError
    }
    let shouldFail = lock.withLock {
      guard storedRemainingInvalidIdentityRefreshes > 0 else { return false }
      storedRemainingInvalidIdentityRefreshes -= 1
      return true
    }
    if shouldFail { throw EWSServiceError.invalidResponse }
    return messages.map { message in
      missingIdentityStableIds.contains(message.stableProviderId)
        ? nil
        : refreshedMessagesByStableId[message.stableProviderId] ?? message
    }
  }

  func recoverMessageIdentity(
    _ message: EWSProviderMessage,
    folders: [EWSFolder],
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> EWSMovedItemIdentity {
    lock.withLock {
      storedRecoveredStableIds.append(message.stableProviderId)
      storedRecoveryFolderIds = folders.map(\.id)
    }
    guard let identity = recoveredIdentitiesByStableId[message.stableProviderId] else {
      throw EWSServiceError.response(code: "ErrorItemNotFound", message: "Item not found")
    }
    return identity
  }

  func perform(
    _ action: ProviderMailAction,
    targetFolderId: String?,
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
      throw URLError(offlineFailureCode)
    }
    let shouldFailAction = lock.withLock {
      guard let failures = storedActionFailures[connectionId],
        failures > 0
      else { return false }
      storedActionFailures[connectionId] = failures - 1
      return true
    }
    if shouldFailAction {
      throw EWSServiceError.response(
        code: actionFailureCode,
        message: "Temporarily unavailable"
      )
    }
    lock.withLock {
      storedPerformedActions.append(
        PerformedAction(
          action: action,
          connectionId: authorization.definition.connectionId,
          targetFolderId: targetFolderId
        )
      )
      storedPerformedMessageChangeKeys.append(messages.map(\.changeKey))
      storedPerformedMessageItemIds.append(messages.map(\.itemId))
    }
    return []
  }

  func send(
    _ message: OutgoingMessage,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws {
    await beforeSendReturn?()
    lock.withLock { storedSentMessages.append(message) }
  }
}

@MainActor
private final class RecordingEWSOAuthService: EWSOAuthAuthorizing {
  private(set) var authorizationCount = 0
  private(set) var refreshCount = 0
  var authorization: EWSOAuthTokens
  var beforeRefreshReturn: (() async -> Void)?
  var refreshResult: Result<EWSOAuthTokens, Error>?

  init(
    authorization: EWSOAuthTokens,
    refreshResult: Result<EWSOAuthTokens, Error>? = nil
  ) {
    self.authorization = authorization
    self.refreshResult = refreshResult
  }

  func authorize() async throws -> EWSOAuthTokens {
    authorizationCount += 1
    return authorization
  }

  func refresh(_ tokens: EWSOAuthTokens) async throws -> EWSOAuthTokens {
    refreshCount += 1
    await beforeRefreshReturn?()
    return try refreshResult?.get() ?? tokens
  }
}

private final class RecordingEWSDefinitionSyncService: MailboxConnectionDefinitionSyncing,
  @unchecked Sendable
{
  var authorizationCleanupConnectionIds: [MailboxConnectionId]
  var beforeLoadSnapshotReturn: (() async -> Void)?
  var beforeSaveDefinitionReturn: (() async -> Void)?
  var completedCleanupGenerations: [MailboxConnectionId: Int] = [:]
  var defaultSendingConnectionId: MailboxConnectionId?
  var didLoadSnapshot: (() -> Void)?
  var didSaveDefinition: (() -> Void)?
  var loadSnapshotError: Error?
  var loadSnapshotCallCount = 0
  var localCleanupGenerations: [MailboxConnectionId: Int]
  var providerAccessLoads = 0
  var recreateDefinitionCount = 0
  var recreateError: Error?
  var recreatedDefinition: MailboxConnectionDefinition?
  var recreationObservation: MailboxConnectionRemovalObservation?
  var removedConnectionIds: [MailboxConnectionId] = []
  var savedDefinition: MailboxConnectionDefinition?

  init(
    authorizationCleanupConnectionIds: [MailboxConnectionId] = [],
    definition: MailboxConnectionDefinition? = nil,
    definitions: [MailboxConnectionDefinition]? = nil,
    localCleanupGenerations: [MailboxConnectionId: Int] = [:]
  ) {
    self.authorizationCleanupConnectionIds = authorizationCleanupConnectionIds
    self.localCleanupGenerations = localCleanupGenerations
    savedDefinition = definition
    savedDefinitions = definitions ?? definition.map { [$0] } ?? []
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

  private var savedDefinitions: [MailboxConnectionDefinition]

  func loadSnapshot(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    loadSnapshotCallCount += 1
    if let loadSnapshotError { throw loadSnapshotError }
    didLoadSnapshot?()
    await beforeLoadSnapshotReturn?()
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
      updatedAt: nil,
      authorizationCleanupConnectionIds: authorizationCleanupConnectionIds,
      localCleanupGenerations: localCleanupGenerations
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

  func recreateDefinition(
    _ definition: MailboxConnectionDefinition,
    after removalObservation: MailboxConnectionRemovalObservation?,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    recreateDefinitionCount += 1
    recreationObservation = removalObservation
    if let recreateError { throw recreateError }
    recreatedDefinition = definition
    let snapshot = try await saveDefinition(definition, session: session)
    removedConnectionIds.removeAll { $0 == definition.id }
    return MailboxConnectionSyncSnapshot(
      connections: snapshot.connections,
      defaultSendingConnectionId: snapshot.defaultSendingConnectionId,
      removedConnectionIds: removedConnectionIds,
      updatedAt: snapshot.updatedAt
    )
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
    removedConnectionIds.removeAll { $0 == definition.id }
    didSaveDefinition?()
    let savedSnapshot = snapshot()
    await beforeSaveDefinitionReturn?()
    return savedSnapshot
  }

  func setDefaultSendingConnection(
    _ connectionId: MailboxConnectionId?,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    defaultSendingConnectionId = connectionId
    return snapshot()
  }
}

private final class RecordingEWSLocalStateCleaner: EWSLocalStateClearing {
  var clearedConnectionIds: [MailboxConnectionId] = []
  var onClear: (() async throws -> Void)?

  func clear(
    connectionId: MailboxConnectionId,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    clearedConnectionIds.append(connectionId)
    try await onClear?()
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

private final class EWSOutboxStore: OutboxDeliveryPersisting, @unchecked Sendable {
  private var attempts: [OutgoingDeliveryAttempt] = []

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

private func ewsRequestBody(_ request: URLRequest) throws -> Data? {
  guard
    let text = try ewsRequestBodyText(
      request,
      fallbackError: URLError(.cannotDecodeContentData)
    )
  else { return nil }
  return Data(text.utf8)
}

private func ewsRequestBodyText(
  _ request: URLRequest,
  fallbackError: Error
) throws -> String? {
  if let body = request.httpBody { return String(data: body, encoding: .utf8) ?? "" }
  guard let stream = request.httpBodyStream else { return nil }
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    guard count >= 0 else {
      throw stream.streamError ?? fallbackError
    }
    guard count > 0 else { break }
    data.append(buffer, count: count)
  }
  return String(data: data, encoding: .utf8) ?? ""
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
