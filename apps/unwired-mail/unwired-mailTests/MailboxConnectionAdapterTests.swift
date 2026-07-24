import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

private let adapterGmailMessage = GmailMessageMetadata(
  categoryId: nil,
  from: "Sender <sender@example.com>",
  isHistorical: false,
  providerAccountIdentifier: "gmail-user-001",
  providerInternalDateMilliseconds: 1_781_200_000_000,
  providerMessageId: "message-001",
  providerThreadId: "thread-001",
  replyTo: nil,
  snippet: "Private message",
  stableProviderMessageId: "gmail:gmail-user-001:message-001",
  subject: "Subject",
  rfcMessageId: "<message-001@example.com>"
)

private let adapterConnectionId = MailboxConnectionId(
  providerMailboxIdentity: StableProviderMailboxIdentity(
    providerId: .gmail,
    value: "gmail-user-001"
  )
)

private let adapterMessage = adapterGmailMessage.mailboxMetadata(
  connectionId: adapterConnectionId
)

@MainActor
final class MailboxConnectionAdapterTests: XCTestCase {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "product-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  func testGmailAdapterConnectsThroughProviderNeutralBoundary() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let credentialVerifier = RecordingAdapterCredentialVerifier()
    let oauthAuthorizer = RecordingAdapterOAuthAuthorizer()
    let definitionSyncService = RecordingAdapterDefinitionSyncService(snapshot: .empty)
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: credentialVerifier,
      definitionSyncService: definitionSyncService,
      oauthAuthorizer: oauthAuthorizer
    )

    let connection = try await adapter.connect(
      session: session,
      isSessionCurrent: { $0 == self.session }
    )

    XCTAssertEqual(oauthAuthorizer.authorizationCount, 1)
    XCTAssertEqual(credentialVerifier.accessToken, "oauth-access-token")
    XCTAssertEqual(credentialVerifier.refreshToken, "oauth-refresh-token")
    XCTAssertEqual(connectionService.completedAccount?.tokens.idToken, "oauth-id-token")
    XCTAssertEqual(connection?.id.rawValue, "gmail:gmail-user-001")
    XCTAssertEqual(connection?.productAccountId, ProductAccountId(session.productAccountId))
  }

  func testGmailSyncAdapterKeepsNonInboxMessagesInVisibleThreads() {
    let sentMessage = GmailMessageMetadata(
      categoryId: nil,
      from: "Reader <reader@example.com>",
      isHistorical: false,
      providerAccountIdentifier: "gmail-user-001",
      providerInternalDateMilliseconds: 1_781_200_001_000,
      providerLabelIds: ["SENT"],
      providerMessageId: "message-002",
      providerThreadId: adapterGmailMessage.providerThreadId,
      replyTo: nil,
      snippet: "Sent reply",
      stableProviderMessageId: "gmail:gmail-user-001:message-002",
      subject: adapterGmailMessage.subject,
      rfcMessageId: "<message-002@example.com>"
    )
    let result = GmailMetadataSyncResult(
      messages: [adapterGmailMessage],
      threads: GmailInboxThread.group([adapterGmailMessage, sentMessage])
    )

    let mailboxResult = result.mailboxResult(connectionId: adapterConnectionId)

    XCTAssertEqual(mailboxResult.messages, [adapterMessage])
    XCTAssertEqual(mailboxResult.threads.first?.messages.count, 2)
    XCTAssertEqual(mailboxResult.threads.first?.latestMessage.providerMessageId, "message-002")
  }

  func testGmailAdapterKeepsExistingAuthorizationWhenDefinitionSyncFails() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let definitionSyncService = RecordingAdapterDefinitionSyncService(snapshot: .empty)
    definitionSyncService.saveError = AdapterTestError.unavailable
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: definitionSyncService,
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer()
    )

    do {
      _ = try await adapter.connect(session: session, isSessionCurrent: { $0 == self.session })
      XCTFail("Expected Product Sync failure")
    } catch is AdapterTestError {
    }

    XCTAssertNil(connectionService.clearedConnection)
  }

  func testGmailAdapterRejectsAuthorizationForDifferentMailboxDefinition() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer()
    )
    let differentConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-002"
      )
    )

    do {
      _ = try await adapter.connect(
        expectedConnectionId: differentConnectionId,
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
      XCTFail("Expected authorization for a different Gmail identity to be rejected")
    } catch let error as MailboxConnectionAdapterError {
      XCTAssertEqual(error, .unexpectedAuthorizedAccount)
      XCTAssertNil(connectionService.completedAccount)
    }
  }

  func testTrustedDevicesAuthorizeSameSyncedDefinitionIndependently() async throws {
    let secondDeviceSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: session.appleUserIdentifier,
      identityToken: session.identityToken,
      productAccountId: session.productAccountId,
      trustedDeviceId: "trusted-device-002"
    )
    let definition = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    ).definition
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [definition],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: 1_781_200_000_300
      )
    )
    let firstDeviceConnections = RecordingAdapterConnectionService()
    let secondDeviceConnections = RecordingAdapterConnectionService()
    secondDeviceConnections.statuses = []
    let firstDeviceAdapter = GmailMailboxConnectionAdapter(
      connectionService: firstDeviceConnections,
      definitionSyncService: definitionSyncService
    )
    let secondDeviceAdapter = GmailMailboxConnectionAdapter(
      connectionService: secondDeviceConnections,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: definitionSyncService,
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer()
    )

    let firstDeviceBefore = try await firstDeviceAdapter.loadConnections(session: session)
    let secondDeviceBefore = try await secondDeviceAdapter.loadConnections(
      session: secondDeviceSession
    )
    _ = try await secondDeviceAdapter.connect(
      expectedConnectionId: adapterConnectionId,
      session: secondDeviceSession,
      isSessionCurrent: { $0 == secondDeviceSession }
    )
    let firstDeviceAfter = try await firstDeviceAdapter.loadConnections(session: session)
    let secondDeviceAfter = try await secondDeviceAdapter.loadConnections(
      session: secondDeviceSession
    )

    XCTAssertEqual(firstDeviceBefore.first?.authorizationState, .authorized)
    XCTAssertEqual(secondDeviceBefore.first?.authorizationState, .required)
    XCTAssertEqual(firstDeviceAfter.first?.authorizationState, .authorized)
    XCTAssertEqual(secondDeviceAfter.first?.authorizationState, .authorized)
    XCTAssertEqual(firstDeviceAfter.first?.trustedDeviceId, session.trustedDeviceId)
    XCTAssertEqual(secondDeviceAfter.first?.trustedDeviceId, secondDeviceSession.trustedDeviceId)
  }

  func testViewModelSelectsUnauthorizedSyncedDefaultWithoutSubstitution() async {
    let localStatus = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "available@example.com",
      lastVerifiedAt: 1_781_200_000_100,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_200
    )
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = [localStatus]
    let defaultDefinition = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    ).definition
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [
          defaultDefinition,
          localStatus.mailboxConnection(
            productAccountId: session.productAccountId
          ).definition,
        ],
        defaultSendingConnectionId: adapterConnectionId,
        removedConnectionIds: [],
        updatedAt: 1_781_200_000_300
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService
    )
    let viewModel = GmailProviderConnectionViewModel(
      service: adapter,
      isSessionCurrent: { $0 == self.session },
      session: session
    )

    await viewModel.load()

    XCTAssertEqual(viewModel.selectedConnectionId, adapterConnectionId)
    XCTAssertEqual(viewModel.connection?.authorizationState, .required)
    XCTAssertNotEqual(
      viewModel.connection?.id,
      localStatus.mailboxConnection(
        productAccountId: session.productAccountId
      ).id)
  }

  func testViewModelFallsBackToGmailWhenDefaultUsesAnotherProvider() async {
    let localStatus = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "available@example.com",
      lastVerifiedAt: 1_781_200_000_100,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_200
    )
    let genericDefaultConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: "imap-smtp"), value: "generic-user-001"
      )
    )
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = [localStatus]
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [
          localStatus.mailboxConnection(productAccountId: session.productAccountId).definition
        ],
        defaultSendingConnectionId: genericDefaultConnectionId,
        removedConnectionIds: [],
        updatedAt: 1_781_200_000_300
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService
    )
    let viewModel = GmailProviderConnectionViewModel(
      service: adapter,
      isSessionCurrent: { $0 == self.session },
      session: session
    )

    await viewModel.load()

    XCTAssertEqual(
      viewModel.selectedConnectionId,
      localStatus.mailboxConnection(productAccountId: session.productAccountId).id
    )
  }

  func testViewModelReportsLoadErrorWhenConnectionsCannotLoad() async {
    let definitionSyncService = RecordingAdapterDefinitionSyncService(snapshot: .empty)
    definitionSyncService.loadError = AdapterTestError.unavailable
    let adapter = GmailMailboxConnectionAdapter(definitionSyncService: definitionSyncService)
    let viewModel = GmailProviderConnectionViewModel(
      service: adapter,
      isSessionCurrent: { $0 == self.session },
      session: session
    )

    await viewModel.load()

    XCTAssertTrue(viewModel.connections.isEmpty)
    XCTAssertNotNil(viewModel.errorMessage)
  }

  func testGmailAdapterListsAndRemovesOneMailboxConnection() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let second = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "second@example.com",
      lastVerifiedAt: 1_781_200_000_100,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_200
    )
    connectionService.statuses = [RecordingAdapterConnectionService.status, second]
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty)
    )

    let connections = try await adapter.loadConnections(session: session)
    try await adapter.clearLocalConnection(connections[0], session: session)

    XCTAssertEqual(
      connections.map(\.id.rawValue), ["gmail:gmail-user-001", "gmail:gmail-user-002"])
    XCTAssertEqual(
      connectionService.clearedConnection?.providerAccountIdentifier,
      "gmail-user-001"
    )
  }

  func testGmailAdapterShowsSynchronizedConnectionThatRequiresDeviceAuthorization() async throws {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = []
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [
          RecordingAdapterConnectionService.status.mailboxConnection(
            productAccountId: session.productAccountId
          ).definition
        ],
        defaultSendingConnectionId: adapterConnectionId,
        removedConnectionIds: [],
        updatedAt: 1_781_200_000_300
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService
    )

    let connections = try await adapter.loadConnections(session: session)
    let defaultSendingConnectionId = try await adapter.loadDefaultSendingConnectionId(
      session: session
    )

    XCTAssertEqual(connections.map(\.id), [adapterConnectionId])
    XCTAssertEqual(connections[0].authorizationState, .required)
    XCTAssertFalse(connections[0].capabilities.canReadMessages)
    XCTAssertFalse(connections[0].capabilities.canSend)
    XCTAssertEqual(defaultSendingConnectionId, adapterConnectionId)
  }

  func testGmailAdapterKeepsSyncedDefinitionWhenRemovingOnlyDeviceAuthorization() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [
          RecordingAdapterConnectionService.status.mailboxConnection(
            productAccountId: session.productAccountId
          ).definition
        ],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: 1_781_200_000_300
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    try await adapter.clearLocalConnection(connection, session: session)

    XCTAssertEqual(connectionService.clearedConnection?.providerAccountIdentifier, "gmail-user-001")
    XCTAssertTrue(definitionSyncService.removedConnectionIds.isEmpty)
  }

  func testGmailAdapterRemovesConnectionEverywhereAfterLocalCleanup() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [
          RecordingAdapterConnectionService.status.mailboxConnection(
            productAccountId: session.productAccountId
          ).definition
        ],
        defaultSendingConnectionId: adapterConnectionId,
        removedConnectionIds: [],
        updatedAt: 1_781_200_000_300
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    try await adapter.removeMailboxConnectionEverywhere(connection, session: session)

    XCTAssertEqual(connectionService.clearedConnection?.providerAccountIdentifier, "gmail-user-001")
    XCTAssertEqual(definitionSyncService.removedConnectionIds, [connection.id])
  }

  func testGmailRemovalClearsLocalAuthorizationBeforeSyncRemoval() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let definitionSyncService = RecordingAdapterDefinitionSyncService(snapshot: .empty)
    definitionSyncService.removeError = AdapterTestError.unavailable
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )

    do {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
      XCTFail("Expected Product Sync failure")
    } catch is AdapterTestError {
    }

    XCTAssertEqual(connectionService.clearedConnection?.providerAccountIdentifier, "gmail-user-001")
  }

  func testGmailAdapterPurgesLocalAuthorizationForSynchronizedRemoval() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [adapterConnectionId],
        updatedAt: 1_781_200_000_300
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService
    )

    let connections = try await adapter.loadConnections(session: session)

    XCTAssertTrue(connections.isEmpty)
    XCTAssertEqual(connectionService.clearedConnection?.providerAccountIdentifier, "gmail-user-001")
  }

  func testGmailAdapterBlocksProviderAccessAfterSynchronizedRemoval() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let metadataService = RecordingAdapterMetadataService()
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [adapterConnectionId],
        updatedAt: 1_781_200_000_300
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService,
      metadataService: metadataService
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )

    do {
      _ = try await adapter.syncInbox(connection: connection, session: session)
      XCTFail("Expected synchronized removal to fence provider access")
    } catch let error as MailboxConnectionAdapterError {
      XCTAssertEqual(error, .connectionRemoved)
      XCTAssertNil(metadataService.syncedConnection)
      XCTAssertEqual(
        connectionService.clearedConnection?.providerAccountIdentifier,
        "gmail-user-001"
      )
    }
  }

  func testGmailAdapterRejectsPendingActionAfterSynchronizedRemoval() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let pendingActionService = PendingProviderActionService(store: AdapterPendingActionStore())
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [adapterConnectionId],
        updatedAt: 1_781_200_000_300
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService,
      pendingActionService: pendingActionService
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )

    do {
      try await adapter.perform(
        .archive,
        messages: [
          mailShellMessage(
            providerMessageId: "removed-action",
            providerThreadId: "removed-action-thread",
            receivedAt: 100
          )
        ],
        connection: connection,
        session: session
      )
      XCTFail("Expected synchronized removal to reject the queued action")
    } catch let error as MailboxConnectionAdapterError {
      XCTAssertEqual(error, .connectionRemoved)
      let pendingActions = try await pendingActionService.pendingActions(session: session)
      XCTAssertTrue(pendingActions.isEmpty)
      XCTAssertEqual(
        connectionService.clearedConnection?.providerAccountIdentifier,
        "gmail-user-001"
      )
    }
  }

  func testGmailAdapterDoesNotClearUnreconciledLocalAuthorization() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let metadataService = RecordingAdapterMetadataService()
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: 1_781_200_000_300
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService,
      metadataService: metadataService
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )

    _ = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertEqual(metadataService.syncedConnection?.providerAccountIdentifier, "gmail-user-001")
    XCTAssertNil(connectionService.clearedConnection)
  }

  func testGmailAdapterRoutesExistingMailOperationsWithoutChangingResults() async throws {
    let bodyReader = RecordingAdapterMessageReader()
    let mailActionService = RecordingAdapterMailActionService()
    let metadataService = RecordingAdapterMetadataService()
    let pushService = RecordingAdapterPushService()
    let searchService = RecordingAdapterSearchService()
    let adapter = GmailMailboxConnectionAdapter(
      bodyReader: bodyReader,
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      mailActionService: mailActionService,
      metadataService: metadataService,
      pushWatchService: pushService,
      pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore()),
      searchService: searchService
    )
    let gmailStatus = RecordingAdapterConnectionService.status
    let connection = gmailStatus.mailboxConnection(productAccountId: session.productAccountId)
    let message = adapterMessage

    let loaded = try await adapter.loadInbox(connection: connection, session: session)
    let synced = try await adapter.syncInbox(connection: connection, session: session)
    let searched = try await adapter.searchProvider(
      query: "private phrase",
      connection: connection,
      session: session
    )
    let body = try await adapter.loadMessageBody(message: message, session: session)
    try await adapter.registerOrRenewPush(connection: connection, session: session)
    try await adapter.perform(
      .archive,
      messages: [message],
      connection: connection,
      session: session
    )
    _ = await adapter.resumePendingActions(connections: [connection], session: session)
    try await adapter.send(
      OutgoingMessage(body: "Hello", recipient: "reader@example.com", subject: "Subject"),
      connection: connection,
      session: session
    )

    XCTAssertEqual(loaded.messages, [message])
    XCTAssertEqual(synced.messages, [message])
    XCTAssertEqual(searched, [message])
    XCTAssertEqual(body, MailboxMessageBody(text: "Decrypted body"))
    XCTAssertEqual(metadataService.loadedConnection, gmailStatus)
    XCTAssertEqual(metadataService.syncedConnection, gmailStatus)
    XCTAssertEqual(searchService.query, "private phrase")
    XCTAssertEqual(pushService.connection, gmailStatus)
    XCTAssertEqual(mailActionService.action, .archive)
    XCTAssertEqual(mailActionService.messageIds, ["message-001"])
    XCTAssertEqual(mailActionService.outgoingMessage?.recipient, "reader@example.com")
  }

  // swiftlint:disable:next function_body_length
  func testPendingActionsResumeIndependentlyAcrossConnections() async throws {
    let firstStarted = expectation(description: "first connection started")
    let secondPerformed = expectation(description: "second connection performed")
    let mailActionService = GatedAdapterMailActionService(
      blockedProviderIdentifier: "gmail-user-001",
      firstStarted: firstStarted,
      secondPerformed: secondPerformed
    )
    let pendingActionService = PendingProviderActionService(store: AdapterPendingActionStore())
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      mailActionService: mailActionService,
      pendingActionService: pendingActionService
    )
    let firstConnection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )
    let secondConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "second@example.com",
      lastVerifiedAt: 1_781_200_000_100,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_200
    ).mailboxConnection(productAccountId: session.productAccountId)
    let secondMessage = MailboxMessageMetadata(
      categoryId: nil,
      connectionId: secondConnection.id,
      from: "sender@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: 1_781_200_000_000,
      providerMessageId: "message-002",
      providerStateIds: ["INBOX"],
      providerThreadId: "thread-002",
      recipientHeaders: ["second@example.com"],
      replyTo: nil,
      rfcMessageId: "<message-002@example.com>",
      snippet: "Message",
      subject: "Subject"
    )
    try await adapter.perform(
      .archive,
      messages: [adapterMessage],
      connection: firstConnection,
      session: session
    )
    try await adapter.perform(
      .markRead,
      messages: [secondMessage],
      connection: secondConnection,
      session: session
    )

    let resumeTask = Task {
      await adapter.resumePendingActions(
        connections: [firstConnection, secondConnection],
        session: session
      )
    }
    await fulfillment(of: [firstStarted, secondPerformed], timeout: 1)
    await mailActionService.release()
    let error = await resumeTask.value
    XCTAssertNil(error)
  }

  func testGmailAdapterReprojectsInboxAfterPendingActionFails() async throws {
    let pendingActionService = PendingProviderActionService(
      failureDisposition: {
        $0 is PendingAdapterActionError ? .permanent : .transient
      },
      store: AdapterPendingActionStore()
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )
    do {
      try await pendingActionService.perform(
        .archive,
        messages: [adapterMessage],
        connection: connection,
        session: session
      ) { _, _, _ in
        throw CancellationError()
      }
    } catch {
    }
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      mailActionService: FailingAdapterMailActionService(),
      metadataService: RecordingAdapterMetadataService(),
      pendingActionService: pendingActionService
    )

    let result = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertEqual(result.messages, [adapterMessage])
  }

  // swiftlint:disable:next function_body_length
  func testGmailAdapterPersistsAuthorizationLossAndRetriesEntireQueuedBatch() async throws {
    let mailActionService = RecoverableAuthMailActionService()
    let pendingActionService = PendingProviderActionService(store: AdapterPendingActionStore())
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      mailActionService: mailActionService,
      pendingActionService: pendingActionService
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )
    let secondMessage = mailShellMessage(
      providerMessageId: "message-002",
      providerThreadId: "thread-002",
      receivedAt: 200
    )
    let messages = [adapterMessage, secondMessage]

    try await adapter.perform(
      .archive,
      messages: messages,
      connection: connection,
      session: session
    )
    let failure = await adapter.resumePendingActions(connection: connection, session: session)
    let failureDetails = await adapter.pendingActionFailureDetails(
      .archive,
      messages: messages,
      connection: connection,
      session: session
    )
    let blockedConnectionIds = await adapter.blockedPendingActionConnectionIds(
      connections: [connection],
      session: session
    )

    XCTAssertNotNil(failure)
    XCTAssertEqual(
      Set(failureDetails?.flatMap(\.messageIds) ?? []),
      [adapterMessage.id]
    )
    XCTAssertEqual(blockedConnectionIds, [connection.id])

    mailActionService.restoreAuthorization()
    let retryFailure = await adapter.retryBlockedPendingAction(
      connection: connection,
      session: session
    )
    let remainingFailureDetails = await adapter.pendingActionFailureDetails(
      .archive,
      messages: messages,
      connection: connection,
      session: session
    )

    XCTAssertNil(retryFailure)
    XCTAssertEqual(mailActionService.messageIds, messages.map(\.providerMessageId))
    XCTAssertEqual(remainingFailureDetails, [])
  }

  func testGmailAdapterReloadsInboxAfterResumingPendingActions() async throws {
    let eventLog = RecordingAdapterEventLog()
    let metadataService = RecordingAdapterMetadataService(eventLog: eventLog)
    let mailActionService = RecordingAdapterMailActionService(eventLog: eventLog)
    let pendingActionService = PendingProviderActionService(store: AdapterPendingActionStore())
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      mailActionService: mailActionService,
      metadataService: metadataService,
      pendingActionService: pendingActionService
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )

    try await adapter.perform(
      .archive,
      messages: [adapterMessage],
      connection: connection,
      session: session
    )
    _ = try await adapter.syncInbox(connection: connection, session: session)

    XCTAssertEqual(metadataService.loadedCollections, [.allObserved, .role(.inbox)])
    XCTAssertEqual(eventLog.events, ["observed", "resume", "inbox"])
  }

  func testGmailAdapterPreservesRecentSyncNotificationFlags() async throws {
    let metadataService = RecordingAdapterMetadataService()
    metadataService.recentSyncResult = GmailMetadataSyncResult(
      historyIsExpired: true,
      hasUnlistedNewMessages: true,
      messages: [adapterGmailMessage],
      newMessageIds: ["message-001"],
      threads: GmailInboxThread.group([adapterGmailMessage])
    )
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      metadataService: metadataService,
      pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore())
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )

    let result = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: true,
      session: session,
      sinceHistoryId: "100",
      throughHistoryId: "101",
      shouldPersist: { true }
    )

    XCTAssertTrue(result.hasUnlistedNewMessages)
    XCTAssertEqual(result.newMessageIds, ["message-001"])
    XCTAssertTrue(result.providerCursorIsExpired)
  }

  func testMailShellPreservesSelectedThreadAcrossReordering() {
    let olderThread = mailShellThread(
      providerThreadId: "thread-older",
      messages: [
        mailShellMessage(
          providerMessageId: "message-older",
          providerThreadId: "thread-older",
          receivedAt: 100
        )
      ]
    )
    let newerThread = mailShellThread(
      providerThreadId: "thread-newer",
      messages: [
        mailShellMessage(
          providerMessageId: "message-newer",
          providerThreadId: "thread-newer",
          receivedAt: 200
        )
      ]
    )
    let viewModel = MailShellSelectionModel()

    XCTAssertEqual(viewModel.navigationLevel, .mailboxList)
    XCTAssertEqual(viewModel.preferredCompactColumn, .sidebar)

    viewModel.selectMailbox(connectionId: adapterConnectionId)
    viewModel.updateThreads([olderThread, newerThread], for: adapterConnectionId)
    viewModel.selectThread(olderThread.id)
    viewModel.updateThreads([newerThread, olderThread], for: adapterConnectionId)

    XCTAssertEqual(viewModel.selectedThreadId, olderThread.id)
    XCTAssertEqual(viewModel.navigationLevel, .conversation)
    XCTAssertEqual(viewModel.preferredCompactColumn, .detail)
    XCTAssertEqual(viewModel.compactColumn(isEditing: true), .content)

    viewModel.updateThreads([newerThread], for: adapterConnectionId)

    XCTAssertNil(viewModel.selectedThreadId)
    XCTAssertEqual(viewModel.navigationLevel, .threadList)
    XCTAssertEqual(viewModel.preferredCompactColumn, .content)
  }

  func testMailShellUnifiedInboxInterleavesThreadsAndShowsSourceConnections() {
    let firstConnection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )
    let secondConnection = mailShellConnection(
      emailAddress: "other@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let olderThread = mailShellThread(
      connectionId: firstConnection.id,
      providerMessageId: "message-older",
      providerThreadId: "thread-older",
      receivedAt: 100
    )
    let newerThread = mailShellThread(
      connectionId: secondConnection.id,
      providerMessageId: "message-newer",
      providerThreadId: "thread-newer",
      receivedAt: 200
    )
    let viewModel = MailShellSelectionModel()

    viewModel.selectUnifiedInbox()
    viewModel.updateThreads([olderThread], for: firstConnection.id)
    viewModel.updateThreads([newerThread], for: secondConnection.id)

    let items = viewModel.threadListItems(connections: [firstConnection, secondConnection])
    XCTAssertEqual(items.map(\.thread.id), [newerThread.id, olderThread.id])
    XCTAssertEqual(
      items.map(\.sourceConnectionDisplayName),
      [secondConnection.displayName, firstConnection.displayName]
    )
  }

  func testMailShellUnifiedInboxKeepsDuplicateConversationsConnectionScoped() {
    let secondConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-002"
      )
    )
    let firstThread = mailShellThread(
      connectionId: adapterConnectionId,
      providerMessageId: "shared-message",
      providerThreadId: "shared-thread",
      receivedAt: 100
    )
    let secondThread = mailShellThread(
      connectionId: secondConnectionId,
      providerMessageId: "shared-message",
      providerThreadId: "shared-thread",
      receivedAt: 100
    )
    let viewModel = MailShellSelectionModel()
    viewModel.selectUnifiedInbox()

    viewModel.updateThreads([firstThread], for: adapterConnectionId)
    viewModel.updateThreads([secondThread], for: secondConnectionId)

    XCTAssertEqual(viewModel.threads.count, 2)
    XCTAssertEqual(Set(viewModel.threads.map(\.id)), [firstThread.id, secondThread.id])
  }

  func testMailShellUnifiedInboxPreservesSelectionDuringOtherConnectionUpdates() {
    let firstConnection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )
    let secondConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-002"
      )
    )
    let selectedThread = mailShellThread(
      connectionId: firstConnection.id,
      providerMessageId: "message-selected",
      providerThreadId: "thread-selected",
      receivedAt: 200
    )
    let otherThread = mailShellThread(
      connectionId: secondConnectionId,
      providerMessageId: "message-other",
      providerThreadId: "thread-other",
      receivedAt: 100
    )
    let insertedThread = mailShellThread(
      connectionId: secondConnectionId,
      providerMessageId: "message-inserted",
      providerThreadId: "thread-inserted",
      receivedAt: 300
    )
    let viewModel = MailShellSelectionModel()
    viewModel.selectUnifiedInbox()
    viewModel.updateThreads([selectedThread], for: firstConnection.id)
    viewModel.updateThreads([otherThread], for: secondConnectionId)
    viewModel.selectThread(selectedThread.id)

    viewModel.updateThreads([insertedThread, otherThread], for: secondConnectionId)

    XCTAssertEqual(viewModel.selectedThreadId, selectedThread.id)
    XCTAssertEqual(
      viewModel.threads.map(\.id),
      [insertedThread.id, selectedThread.id, otherThread.id]
    )

    viewModel.updateThreads([], for: firstConnection.id)

    XCTAssertNil(viewModel.selectedThreadId)
  }

  func testMailShellBulkSelectionIntersectsCapabilitiesAcrossConnections() {
    let firstConnection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let secondConnection = mailShellConnection(
      emailAddress: "second@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId,
      providerActions: [.delete, .markRead]
    )
    let firstThread = mailShellThread(
      connectionId: firstConnection.id,
      providerMessageId: "message-first",
      providerThreadId: "thread-first",
      receivedAt: 200
    )
    let secondThread = mailShellThread(
      connectionId: secondConnection.id,
      providerMessageId: "message-second",
      providerThreadId: "thread-second",
      receivedAt: 100
    )
    let viewModel = MailShellSelectionModel()
    viewModel.selectUnifiedInbox()
    viewModel.updateThreads([firstThread], for: firstConnection.id)
    viewModel.updateThreads([secondThread], for: secondConnection.id)

    viewModel.selectThreads([firstThread.id, secondThread.id])

    XCTAssertEqual(
      viewModel.bulkProviderActions(connections: [firstConnection, secondConnection]),
      [.delete, .markRead]
    )
    let batches = viewModel.bulkActionBatches(
      connections: [firstConnection, secondConnection],
      pinnedMessageIds: []
    )
    XCTAssertEqual(batches.map(\.connection.id), [firstConnection.id, secondConnection.id])
    XCTAssertEqual(
      batches.map { $0.messages.map(\.id) },
      [[firstThread.latestMessage.id], [secondThread.latestMessage.id]]
    )
  }

  func testBulkMoveDestinationTargetsEveryConnectionWithoutUsingDisplayTitleAsIdentity() {
    let firstConnection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let secondConnection = mailShellConnection(
      emailAddress: "second@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let batches = [
      mailShellBulkActionBatch(connection: firstConnection, suffix: "first", receivedAt: 200),
      mailShellBulkActionBatch(connection: secondConnection, suffix: "second", receivedAt: 100),
    ]

    let destinations = MailboxBulkMoveDestination.shared(
      connectionIds: [firstConnection.id, secondConnection.id],
      providerMailboxesByConnection: [
        firstConnection.id: [
          ProviderMailbox(id: "Label_101", title: "Projects"),
          ProviderMailbox(id: "Label_102", title: "First only"),
        ],
        secondConnection.id: [
          ProviderMailbox(id: "Label_201", title: "Projects"),
          ProviderMailbox(id: "Label_202", title: "Second only"),
        ],
      ]
    )

    XCTAssertEqual(destinations.map(\.title), ["Projects"])
    XCTAssertEqual(
      destinations.first?.providerMailboxIdsByConnection,
      [firstConnection.id: "Label_101", secondConnection.id: "Label_201"]
    )
    XCTAssertEqual(
      destinations.first?.targeting(batches)?.map(\.targetProviderMailboxId),
      ["Label_101", "Label_201"]
    )
    XCTAssertNil(destinations.first?.targeting([batches[0]]))
  }

  func testMailShellBulkSelectionSurvivesRefreshAndDropsOnlyRemovedThreads() {
    let secondConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-002"
      )
    )
    let firstThread = mailShellThread(
      connectionId: adapterConnectionId,
      providerMessageId: "message-first",
      providerThreadId: "thread-first",
      receivedAt: 200
    )
    let secondThread = mailShellThread(
      connectionId: secondConnectionId,
      providerMessageId: "message-second",
      providerThreadId: "thread-second",
      receivedAt: 100
    )
    let insertedThread = mailShellThread(
      connectionId: secondConnectionId,
      providerMessageId: "message-inserted",
      providerThreadId: "thread-inserted",
      receivedAt: 300
    )
    let viewModel = MailShellSelectionModel()
    viewModel.selectUnifiedInbox()
    viewModel.updateThreads([firstThread], for: adapterConnectionId)
    viewModel.updateThreads([secondThread], for: secondConnectionId)
    viewModel.selectThreads([firstThread.id, secondThread.id])

    viewModel.updateThreads([insertedThread, secondThread], for: secondConnectionId)

    XCTAssertEqual(viewModel.selectedThreadIds, [firstThread.id, secondThread.id])
    XCTAssertNil(viewModel.selectedThreadId)

    viewModel.updateThreads([], for: adapterConnectionId)

    XCTAssertEqual(viewModel.selectedThreadIds, [secondThread.id])
    XCTAssertEqual(viewModel.selectedThreadId, secondThread.id)
  }

  func testCanonicalUnifiedMailboxCountsAggregateObservedDataAcrossConnections() {
    let secondConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-002"
      )
    )
    let firstMessages = canonicalMailboxMessages()
    let secondMessages = canonicalMailboxMessages(connectionId: secondConnectionId)
    let snapshot = MailboxNavigationSnapshot(
      messagesByConnection: [
        adapterConnectionId: firstMessages,
        secondConnectionId: secondMessages,
      ],
      pinnedMessageIds: [firstMessages[2].id],
      outboxStates: []
    )

    XCTAssertEqual(snapshot.count(for: .inbox), MailboxItemCount(itemCount: 2, unreadCount: 1))
    XCTAssertEqual(snapshot.count(for: .pins), MailboxItemCount(itemCount: 1, unreadCount: 0))
    XCTAssertEqual(snapshot.count(for: .drafts), MailboxItemCount(itemCount: 1, unreadCount: 0))
    XCTAssertEqual(snapshot.count(for: .sent), MailboxItemCount(itemCount: 1, unreadCount: 0))
    XCTAssertEqual(snapshot.count(for: .archive), MailboxItemCount(itemCount: 1, unreadCount: 0))
    XCTAssertEqual(snapshot.count(for: .allMail), MailboxItemCount(itemCount: 5, unreadCount: 1))
    XCTAssertEqual(snapshot.count(for: .spam), MailboxItemCount(itemCount: 1, unreadCount: 1))
    XCTAssertEqual(snapshot.count(for: .trash), MailboxItemCount(itemCount: 1, unreadCount: 0))
    XCTAssertEqual(
      snapshot.providerMailboxIds(for: adapterConnectionId),
      ["Label_projects"]
    )
    XCTAssertTrue(snapshot.providerMailboxIds(for: secondConnectionId).isEmpty)
  }

  func testCanonicalMailboxProjectionUsesNativeGmailStatesWithoutMutatingThem() {
    let message = mailShellMessage(
      providerMessageId: "message-001",
      providerThreadId: "thread-001",
      receivedAt: 100,
      providerStateIds: ["INBOX", "UNREAD", "Label_projects"]
    )
    let result = MailboxMetadataSyncResult(
      hasUnlistedNewMessages: false,
      messages: [message],
      newMessageIds: nil,
      providerCursorIsExpired: false,
      threads: MailboxThread.group([message])
    )

    XCTAssertEqual(result.projected(to: .role(.inbox)).messages, [message])
    XCTAssertEqual(result.projected(to: .providerMailbox("Label_projects")).messages, [message])
    XCTAssertTrue(result.projected(to: .role(.archive)).messages.isEmpty)
    XCTAssertEqual(result.messages.first?.providerStateIds, ["INBOX", "UNREAD", "Label_projects"])
  }

  func testProviderSpecificGmailLabelsRemainConnectionScoped() {
    let message = mailShellMessage(
      providerMessageId: "message-001",
      providerThreadId: "thread-001",
      receivedAt: 100,
      providerStateIds: ["INBOX", "IMPORTANT", "STARRED", "CATEGORY_UPDATES", "Label_projects"]
    )
    let snapshot = MailboxNavigationSnapshot(
      messagesByConnection: [adapterConnectionId: [message]],
      pinnedMessageIds: [],
      outboxStates: [],
      providerMailboxesByConnection: [
        adapterConnectionId: [
          ProviderMailbox(id: "Label_empty", title: "Empty label"),
          ProviderMailbox(id: "Label_projects", title: "Projects"),
        ]
      ]
    )

    XCTAssertEqual(
      snapshot.providerMailboxIds(for: adapterConnectionId),
      ["Label_empty", "Label_projects"]
    )
    XCTAssertEqual(
      snapshot.providerMailboxes(for: adapterConnectionId).first {
        $0.id == "Label_projects"
      }?.title,
      "Projects"
    )
    XCTAssertFalse(MailboxMessageCollection.isProviderMailboxId("STARRED"))
  }

  func testOutboxNavigationIsConditionalOnActionableDeliveryState() {
    XCTAssertFalse(
      MailboxNavigationSnapshot(
        messagesByConnection: [:],
        pinnedMessageIds: [],
        outboxStates: []
      ).showsOutbox
    )
    XCTAssertFalse(
      MailboxNavigationSnapshot(
        messagesByConnection: [:],
        pinnedMessageIds: [],
        outboxStates: [.sent]
      ).showsOutbox
    )
    XCTAssertTrue(
      MailboxNavigationSnapshot(
        messagesByConnection: [:],
        pinnedMessageIds: [],
        outboxStates: [.pending, .retrying, .failed]
      ).showsOutbox
    )
  }

  func testCanonicalRoleTransitionRecomputesCountsFromObservedState() {
    let inboxMessage = mailShellMessage(
      providerMessageId: "message-001",
      providerThreadId: "thread-001",
      receivedAt: 100,
      providerStateIds: ["INBOX", "UNREAD"]
    )
    let archivedMessage = mailShellMessage(
      providerMessageId: "message-001",
      providerThreadId: "thread-001",
      receivedAt: 100,
      providerStateIds: []
    )

    let before = MailboxNavigationSnapshot(
      messagesByConnection: [adapterConnectionId: [inboxMessage]],
      pinnedMessageIds: [],
      outboxStates: []
    )
    let after = MailboxNavigationSnapshot(
      messagesByConnection: [adapterConnectionId: [archivedMessage]],
      pinnedMessageIds: [],
      outboxStates: []
    )

    XCTAssertEqual(before.count(for: .inbox).itemCount, 1)
    XCTAssertEqual(before.count(for: .archive).itemCount, 0)
    XCTAssertEqual(after.count(for: .inbox).itemCount, 0)
    XCTAssertEqual(after.count(for: .archive).itemCount, 1)
  }

  func testMailShellScopesActionsToMessagesVisibleInSelectedMailbox() {
    let inboxMessage = mailShellMessage(
      providerMessageId: "message-inbox",
      providerThreadId: "thread-001",
      receivedAt: 100,
      providerStateIds: ["INBOX"]
    )
    let sentMessage = mailShellMessage(
      providerMessageId: "message-sent",
      providerThreadId: "thread-001",
      receivedAt: 200,
      providerStateIds: ["SENT", "Label_projects"]
    )
    let thread = mailShellThread(
      providerThreadId: "thread-001",
      messages: [inboxMessage, sentMessage]
    )
    let viewModel = MailShellSelectionModel()

    viewModel.selectUnifiedMailbox(.sent)
    XCTAssertEqual(
      viewModel.selectedMailboxMessages(in: thread, pinnedMessageIds: []),
      [sentMessage]
    )

    viewModel.selectMailbox(
      connectionId: adapterConnectionId,
      collection: .providerMailbox("Label_projects")
    )
    XCTAssertEqual(
      viewModel.selectedMailboxMessages(in: thread, pinnedMessageIds: []),
      [sentMessage]
    )

    viewModel.selectUnifiedMailbox(.pins)
    XCTAssertEqual(
      viewModel.selectedMailboxMessages(in: thread, pinnedMessageIds: [sentMessage.id]),
      [sentMessage]
    )
  }

  func testMailShellScopesThreadsToSelectedMailbox() {
    let selectedThread = mailShellThread(
      providerThreadId: "thread-selected",
      messages: [
        mailShellMessage(
          providerMessageId: "message-selected",
          providerThreadId: "thread-selected",
          receivedAt: 100
        )
      ]
    )
    let otherConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-002"
      )
    )
    let viewModel = MailShellSelectionModel()
    viewModel.selectMailbox(connectionId: adapterConnectionId)
    viewModel.updateThreads([selectedThread], for: adapterConnectionId)
    viewModel.selectThread(selectedThread.id)

    viewModel.selectMailbox(connectionId: otherConnectionId)

    XCTAssertEqual(viewModel.selectedConnectionId, otherConnectionId)
    XCTAssertTrue(viewModel.threads.isEmpty)
    XCTAssertNil(viewModel.selectedThreadId)
    XCTAssertEqual(viewModel.navigationLevel, .threadList)
    XCTAssertEqual(viewModel.preferredCompactColumn, .content)
  }

  func testMailShellClearsThreadSelection() {
    let thread = mailShellThread(
      providerThreadId: "thread-001",
      messages: [
        mailShellMessage(
          providerMessageId: "message-001",
          providerThreadId: "thread-001",
          receivedAt: 100
        )
      ]
    )
    let viewModel = MailShellSelectionModel()
    viewModel.selectMailbox(connectionId: adapterConnectionId)
    viewModel.updateThreads([thread], for: adapterConnectionId)
    viewModel.selectThread(thread.id)

    viewModel.clearThreadSelection()

    XCTAssertNil(viewModel.selectedThreadId)
    XCTAssertEqual(viewModel.navigationLevel, .threadList)
  }

  func testMailShellExpandsLatestMessageAndTogglesOlderMessages() {
    let olderMessage = mailShellMessage(
      providerMessageId: "message-older",
      providerThreadId: "thread-001",
      receivedAt: 100
    )
    let latestMessage = mailShellMessage(
      providerMessageId: "message-latest",
      providerThreadId: "thread-001",
      receivedAt: 200
    )
    let thread = mailShellThread(
      providerThreadId: "thread-001",
      messages: [olderMessage, latestMessage]
    )
    let viewModel = MailShellSelectionModel()
    viewModel.selectMailbox(connectionId: adapterConnectionId)
    viewModel.updateThreads([thread], for: adapterConnectionId)

    viewModel.selectThread(thread.id)

    XCTAssertTrue(viewModel.isMessageExpanded(latestMessage, in: thread))
    XCTAssertFalse(viewModel.isMessageExpanded(olderMessage, in: thread))

    viewModel.toggleMessageExpansion(olderMessage, in: thread)

    XCTAssertTrue(viewModel.isMessageExpanded(olderMessage, in: thread))
  }

  func testMailShellReplyAndForwardDraftsKeepSourceConnectionIdentity() {
    let message = mailShellMessage(
      providerMessageId: "message-001",
      providerThreadId: "thread-001",
      receivedAt: 100
    )

    let reply = MailShellCompositionDraft.reply(to: message)
    let forward = MailShellCompositionDraft.forward(message, body: "Decrypted body")

    XCTAssertEqual(reply.connectionId, message.connectionId)
    XCTAssertEqual(reply.sourceThreadId, message.threadIdentity)
    XCTAssertEqual(reply.sourceMailboxIdentity, message.connectionId.providerMailboxIdentity)
    XCTAssertEqual(reply.replyToMessage, message)
    XCTAssertEqual(reply.recipient, "sender@example.com")
    XCTAssertEqual(reply.subject, "Re: Subject message-001")
    XCTAssertEqual(forward.connectionId, message.connectionId)
    XCTAssertEqual(forward.sourceThreadId, message.threadIdentity)
    XCTAssertEqual(forward.sourceMailboxIdentity, message.connectionId.providerMailboxIdentity)
    XCTAssertEqual(forward.sourceMessage, message)
    XCTAssertNil(forward.replyToMessage)
    XCTAssertEqual(forward.forwardSourceMessage, message)
    XCTAssertEqual(forward.subject, "Fwd: Subject message-001")
    XCTAssertTrue(forward.body.contains("Decrypted body"))
  }

  func testMailShellReplyUsesRecipientHeaderForSentMessages() {
    let message = MailboxMessageMetadata(
      categoryId: nil,
      connectionId: adapterConnectionId,
      from: "reader@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: 100,
      providerMessageId: "message-001",
      providerStateIds: ["SENT"],
      providerThreadId: "thread-001",
      recipientHeaders: ["recipient@example.com"],
      replyTo: nil,
      rfcMessageId: "<message-001@example.com>",
      snippet: "Message",
      subject: "Subject"
    )

    let reply = MailShellCompositionDraft.reply(to: message)

    XCTAssertEqual(reply.recipient, "recipient@example.com")
  }

  func testMailShellReplyPrefersRecipientHeaderOverReplyToForSentMessages() {
    let message = MailboxMessageMetadata(
      categoryId: nil,
      connectionId: adapterConnectionId,
      from: "reader@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: 100,
      providerMessageId: "message-001",
      providerStateIds: ["SENT"],
      providerThreadId: "thread-001",
      recipientHeaders: ["recipient@example.com"],
      replyTo: "reader@example.com",
      rfcMessageId: "<message-001@example.com>",
      snippet: "Message",
      subject: "Subject"
    )

    XCTAssertEqual(MailShellCompositionDraft.reply(to: message).recipient, "recipient@example.com")
  }

  func testMailShellReplyUsesSenderForReceivedMessages() {
    let message = MailboxMessageMetadata(
      categoryId: nil,
      connectionId: adapterConnectionId,
      from: "sender@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: 100,
      providerMessageId: "message-001",
      providerStateIds: ["INBOX"],
      providerThreadId: "thread-001",
      recipientHeaders: ["reader@example.com"],
      replyTo: nil,
      rfcMessageId: "<message-001@example.com>",
      snippet: "Message",
      subject: "Subject"
    )

    let reply = MailShellCompositionDraft.reply(to: message)

    XCTAssertEqual(reply.recipient, "sender@example.com")
  }

  func testMailActionReplyWithoutRFCMessageIDDoesNotSetProviderThread() async {
    let service = RecordingAdapterMailActionService()
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      mailActionService: service
    )
    let viewModel = GmailMailActionViewModel(service: adapter, session: session)
    let replyTo = MailboxMessageMetadata(
      categoryId: nil,
      connectionId: adapterConnectionId,
      from: "sender@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: 100,
      providerMessageId: "message-001",
      providerStateIds: ["INBOX"],
      providerThreadId: "thread-001",
      recipientHeaders: ["reader@example.com"],
      replyTo: nil,
      rfcMessageId: nil,
      snippet: "Message",
      subject: "Subject"
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )

    let didSend = await viewModel.send(
      recipient: "sender@example.com",
      subject: "Re: Subject",
      body: "Reply",
      replyTo: replyTo,
      connection: connection
    )

    XCTAssertTrue(didSend)
    XCTAssertNil(service.outgoingMessage?.threadId)
    XCTAssertNil(service.outgoingMessage?.inReplyTo)
  }

  func testMailActionViewModelRestoresBlockedConnectionState() async {
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )
    let viewModel = GmailMailActionViewModel(
      service: RestoredBlockedActionService(),
      session: session
    )

    await viewModel.resume(connections: [connection])

    XCTAssertEqual(viewModel.blockedConnectionId, connection.id)
    XCTAssertEqual(viewModel.errorMessage, "Pending action requires attention.")
  }

  func testMailActionViewModelAdvancesAcrossMultipleFailedConnections() async {
    let firstConnection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )
    let secondConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "second@example.com",
      lastVerifiedAt: 1_781_200_000_100,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_200
    ).mailboxConnection(productAccountId: session.productAccountId)
    let service = MultiplePendingFailureService(
      failedConnectionIds: [firstConnection.id, secondConnection.id]
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)
    await viewModel.resume(connections: [firstConnection, secondConnection])

    await viewModel.acknowledgeFailures(connection: firstConnection)

    XCTAssertEqual(viewModel.failedConnectionIds, [secondConnection.id])
    XCTAssertEqual(viewModel.pendingFailureConnectionId, secondConnection.id)
    XCTAssertEqual(viewModel.errorMessage, "second@example.com requires attention.")
  }

  func testMailActionViewModelKeepsSuccessfulBulkBatchesWhenAuthorizationIsLost() async {
    let firstConnection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let secondConnection = mailShellConnection(
      emailAddress: "second@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let service = RecordingBulkMailActionService(failingConnectionId: secondConnection.id)
    let viewModel = GmailMailActionViewModel(service: service, session: session)
    let result = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(connection: firstConnection, suffix: "first", receivedAt: 200),
        mailShellBulkActionBatch(connection: secondConnection, suffix: "second", receivedAt: 100),
      ]
    )

    XCTAssertEqual(result?.succeededConnectionIds, [firstConnection.id])
    XCTAssertEqual(result?.failures.map(\.connectionId), [secondConnection.id])
    XCTAssertEqual(result?.failures.map(\.messageCount), [1])
    XCTAssertEqual(
      result?.failures.first?.messageIds,
      [
        StableProviderMessageIdentity(
          connectionId: secondConnection.id,
          providerMessageId: "message-second"
        )
      ]
    )
    let recordedConnectionIds = await service.recordedConnectionIds()
    XCTAssertEqual(
      Set(recordedConnectionIds),
      [firstConnection.id, secondConnection.id]
    )
    XCTAssertEqual(
      viewModel.errorMessage,
      "second@example.com — Subject message-second "
        + "[\(result?.failures.first?.messageIds.first?.rawValue ?? "")]: "
        + "Authorize this Mailbox Connection on this device before accessing mail."
    )
  }

  func testMailActionViewModelPreservesConnectionLevelBulkErrorsWithoutDetails() async {
    let connection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let viewModel = GmailMailActionViewModel(
      service: ConnectionPendingActionFailureService(),
      session: session
    )

    let result = await viewModel.performBulk(
      .archive,
      batches: [mailShellBulkActionBatch(connection: connection, suffix: "first", receivedAt: 200)]
    )

    XCTAssertTrue(result?.succeededConnectionIds.isEmpty ?? false)
    XCTAssertEqual(result?.failures.map(\.connectionId), [connection.id])
    XCTAssertEqual(
      viewModel.errorMessage,
      "first@example.com — Subject message-first "
        + "[gmail:gmail-user-001:message-first]: The provider connection failed."
    )
  }

  func testMailActionViewModelRetriesBlockedBulkConnection() async {
    let firstConnection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let secondConnection = mailShellConnection(
      emailAddress: "second@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let service = RetryableBulkMailActionService(blockedConnectionId: secondConnection.id)
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    let result = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(connection: firstConnection, suffix: "first", receivedAt: 200),
        mailShellBulkActionBatch(connection: secondConnection, suffix: "second", receivedAt: 100),
      ]
    )

    XCTAssertEqual(result?.failures.map(\.connectionId), [secondConnection.id])
    XCTAssertEqual(viewModel.blockedConnectionId, secondConnection.id)

    await viewModel.retryBlockedAction(connection: secondConnection)

    XCTAssertNil(viewModel.blockedConnectionId)
    XCTAssertNil(viewModel.errorMessage)
    let retryCount = await service.retryCount()
    XCTAssertEqual(retryCount, 1)
  }

  // swiftlint:disable:next function_body_length
  func testBulkBatchesStartIndependentlyAcrossConnections() async {
    let firstStarted = expectation(description: "First connection started")
    let secondStarted = expectation(description: "Second connection started")
    let firstConnection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let secondConnection = mailShellConnection(
      emailAddress: "second@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let service = GatedBulkMailActionService(
      blockedConnectionId: firstConnection.id,
      firstStarted: firstStarted,
      secondStarted: secondStarted
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)
    let firstThread = mailShellThread(
      connectionId: firstConnection.id,
      providerMessageId: "message-first",
      providerThreadId: "thread-first",
      receivedAt: 200
    )
    let secondThread = mailShellThread(
      connectionId: secondConnection.id,
      providerMessageId: "message-second",
      providerThreadId: "thread-second",
      receivedAt: 100
    )
    let selection = MailShellSelectionModel()
    selection.selectUnifiedInbox()
    selection.updateThreads([firstThread], for: firstConnection.id)
    selection.updateThreads([secondThread], for: secondConnection.id)
    selection.selectThreads([firstThread.id, secondThread.id])
    let task = Task {
      await viewModel.performBulk(
        .markRead,
        batches: [
          MailboxBulkActionBatch(connection: firstConnection, messages: firstThread.messages),
          MailboxBulkActionBatch(connection: secondConnection, messages: secondThread.messages),
        ]
      )
    }

    await fulfillment(of: [firstStarted, secondStarted], timeout: 1)
    XCTAssertEqual(
      viewModel.bulkActionProgress,
      MailboxBulkActionProgress(
        action: .markRead,
        completedConnectionCount: 1,
        totalConnectionCount: 2
      )
    )
    selection.updateThreads([], for: firstConnection.id)
    XCTAssertEqual(selection.selectedThreadIds, [secondThread.id])
    XCTAssertEqual(
      viewModel.bulkActionProgress,
      MailboxBulkActionProgress(
        action: .markRead,
        completedConnectionCount: 1,
        totalConnectionCount: 2
      )
    )
    await service.release()
    let result = await task.value

    XCTAssertEqual(
      Set(result?.succeededConnectionIds ?? []),
      [firstConnection.id, secondConnection.id]
    )
    XCTAssertNil(viewModel.bulkActionProgress)
  }

  func testMailboxThreadInboxMessagesIncludesLegacyMessagesWithoutProviderState() {
    let inboxMessage = mailShellMessage(
      providerMessageId: "message-inbox",
      providerThreadId: "thread-001",
      receivedAt: 100
    )
    let unknownMessage = mailShellMessage(
      providerMessageId: "message-unknown",
      providerThreadId: "thread-001",
      receivedAt: 200,
      providerStateIds: nil
    )

    let thread = mailShellThread(
      providerThreadId: "thread-001",
      messages: [inboxMessage, unknownMessage]
    )

    XCTAssertEqual(thread.inboxMessages, [unknownMessage, inboxMessage])
  }

}

private func mailShellThread(
  providerThreadId: String,
  messages: [MailboxMessageMetadata]
) -> MailboxThread {
  MailboxThread.group(messages).first { $0.providerThreadId == providerThreadId }!
}

private func mailShellThread(
  connectionId: MailboxConnectionId,
  providerMessageId: String,
  providerThreadId: String,
  receivedAt: Int64
) -> MailboxThread {
  mailShellThread(
    providerThreadId: providerThreadId,
    messages: [
      mailShellMessage(
        connectionId: connectionId,
        providerMessageId: providerMessageId,
        providerThreadId: providerThreadId,
        receivedAt: receivedAt
      )
    ]
  )
}

private func mailShellConnection(
  emailAddress: String,
  providerAccountIdentifier: String,
  productAccountId: String,
  providerActions: Set<ProviderMailAction> = Set(ProviderMailAction.allCases)
) -> MailboxConnection {
  let connection = GmailProviderConnectionStatus(
    connectedAt: 1_781_200_000_000,
    emailAddress: emailAddress,
    lastVerifiedAt: 1_781_200_000_100,
    provider: "gmail",
    providerAccountIdentifier: providerAccountIdentifier,
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_200
  ).mailboxConnection(productAccountId: productAccountId)
  return MailboxConnection(
    authorizationState: connection.authorizationState,
    capabilities: MailboxConnectionCapabilities(
      canCategorizeHistorical: connection.capabilities.canCategorizeHistorical,
      canForward: connection.capabilities.canForward,
      canReadMessages: connection.capabilities.canReadMessages,
      canRegisterPush: connection.capabilities.canRegisterPush,
      canReply: connection.capabilities.canReply,
      canSearchProvider: connection.capabilities.canSearchProvider,
      canSend: connection.capabilities.canSend,
      canSynchronizeMetadata: connection.capabilities.canSynchronizeMetadata,
      providerActions: providerActions
    ),
    connectedAt: connection.connectedAt,
    displayName: connection.displayName,
    id: connection.id,
    lastVerifiedAt: connection.lastVerifiedAt,
    productAccountId: connection.productAccountId,
    trustedDeviceId: connection.trustedDeviceId,
    updatedAt: connection.updatedAt
  )
}

private func mailShellBulkActionBatch(
  connection: MailboxConnection,
  suffix: String,
  receivedAt: Int64
) -> MailboxBulkActionBatch {
  MailboxBulkActionBatch(
    connection: connection,
    messages: [
      mailShellMessage(
        connectionId: connection.id,
        providerMessageId: "message-\(suffix)",
        providerThreadId: "thread-\(suffix)",
        receivedAt: receivedAt
      )
    ]
  )
}

private func canonicalMailboxMessages() -> [MailboxMessageMetadata] {
  [
    mailShellMessage(
      providerMessageId: "inbox-unread",
      providerThreadId: "thread-inbox-unread",
      receivedAt: 800,
      providerStateIds: ["INBOX", "UNREAD", "Label_projects"]
    ),
    mailShellMessage(
      providerMessageId: "draft",
      providerThreadId: "thread-draft",
      receivedAt: 600,
      providerStateIds: ["DRAFT"]
    ),
    mailShellMessage(
      providerMessageId: "archived",
      providerThreadId: "thread-archived",
      receivedAt: 400,
      providerStateIds: ["Label_projects"]
    ),
    mailShellMessage(
      providerMessageId: "spam",
      providerThreadId: "thread-spam",
      receivedAt: 300,
      providerStateIds: ["SPAM", "UNREAD"]
    ),
  ]
}

private func canonicalMailboxMessages(
  connectionId: MailboxConnectionId
) -> [MailboxMessageMetadata] {
  [
    mailShellMessage(
      connectionId: connectionId,
      providerMessageId: "inbox-read",
      providerThreadId: "thread-inbox-read",
      receivedAt: 700,
      providerStateIds: ["INBOX"]
    ),
    mailShellMessage(
      connectionId: connectionId,
      providerMessageId: "sent",
      providerThreadId: "thread-sent",
      receivedAt: 500,
      providerStateIds: ["SENT"]
    ),
    mailShellMessage(
      connectionId: connectionId,
      providerMessageId: "trash",
      providerThreadId: "thread-trash",
      receivedAt: 200,
      providerStateIds: ["TRASH"]
    ),
  ]
}

private func mailShellMessage(
  connectionId: MailboxConnectionId = adapterConnectionId,
  providerMessageId: String,
  providerThreadId: String,
  receivedAt: Int64,
  providerStateIds: [String]? = ["INBOX"]
) -> MailboxMessageMetadata {
  MailboxMessageMetadata(
    categoryId: nil,
    connectionId: connectionId,
    from: "Sender <sender@example.com>",
    isHistorical: false,
    providerInternalDateMilliseconds: receivedAt,
    providerMessageId: providerMessageId,
    providerStateIds: providerStateIds,
    providerThreadId: providerThreadId,
    recipientHeaders: ["reader@example.com"],
    replyTo: "sender@example.com",
    rfcMessageId: "<\(providerMessageId)@example.com>",
    snippet: "Message \(providerMessageId)",
    subject: "Subject \(providerMessageId)"
  )
}

@MainActor
private final class RecordingAdapterOAuthAuthorizer: GmailOAuthAuthorizing {
  var authorizationCount = 0

  func authorize() async throws -> GmailProviderTokens {
    authorizationCount += 1
    return GmailProviderTokens(
      accessToken: "oauth-access-token",
      refreshToken: "oauth-refresh-token",
      idToken: "oauth-id-token"
    )
  }
}

private final class RecordingAdapterCredentialVerifier: GmailProviderCredentialVerifying {
  var accessToken: String?
  var refreshToken: String?

  func verify(
    accessToken: String,
    refreshToken: String
  ) async throws -> VerifiedGmailAccount {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    return VerifiedGmailAccount(
      emailAddress: "user@example.com",
      providerAccountIdentifier: "gmail-user-001",
      tokens: GmailProviderTokens(
        accessToken: accessToken,
        refreshToken: refreshToken
      )
    )
  }
}

private final class RecordingAdapterConnectionService: GmailProviderConnecting {
  static let status = GmailProviderConnectionStatus(
    connectedAt: 1_781_200_000_000,
    emailAddress: "user@example.com",
    lastVerifiedAt: 1_781_200_000_100,
    provider: "gmail",
    providerAccountIdentifier: "gmail-user-001",
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_200
  )

  var completedAccount: VerifiedGmailAccount?
  var clearedConnection: GmailProviderConnectionStatus?
  var statuses = [RecordingAdapterConnectionService.status]

  func clearLocalConnection(session _: ProductAccountSessionSnapshot) async throws {}

  func clearLocalConnection(
    _ connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    clearedConnection = connection
  }

  func completeConnection(
    verifiedAccount: VerifiedGmailAccount,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus {
    completedAccount = verifiedAccount
    let status = GmailProviderConnectionStatus(
      connectedAt: Self.status.connectedAt,
      emailAddress: verifiedAccount.emailAddress,
      lastVerifiedAt: Self.status.lastVerifiedAt,
      provider: Self.status.provider,
      providerAccountIdentifier: verifiedAccount.providerAccountIdentifier,
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: Self.status.updatedAt
    )
    statuses = [status]
    return status
  }

  func loadConnection(
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus? {
    Self.status
  }

  func loadConnections(
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailProviderConnectionStatus] {
    statuses
  }
}

private final class RecordingAdapterDefinitionSyncService: MailboxConnectionDefinitionSyncing {
  var loadError: Error?
  var removedConnectionIds: [MailboxConnectionId] = []
  var removeError: Error?
  var saveError: Error?
  private var snapshot: MailboxConnectionSyncSnapshot

  init(snapshot: MailboxConnectionSyncSnapshot) {
    self.snapshot = snapshot
  }

  func loadSnapshot(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    if let loadError { throw loadError }
    return snapshot
  }

  func reconcileConnections(
    _ connections: [MailboxConnectionDefinition],
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    for connection in connections
    where !snapshot.connections.contains(where: { $0.id == connection.id })
      && !snapshot.removedConnectionIds.contains(connection.id)
    {
      snapshot = MailboxConnectionSyncSnapshot(
        connections: snapshot.connections + [connection],
        defaultSendingConnectionId: snapshot.defaultSendingConnectionId,
        removedConnectionIds: snapshot.removedConnectionIds,
        updatedAt: snapshot.updatedAt
      )
    }
    return snapshot
  }

  func removeConnection(
    _ connectionId: MailboxConnectionId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    if let removeError { throw removeError }
    removedConnectionIds.append(connectionId)
    snapshot = MailboxConnectionSyncSnapshot(
      connections: snapshot.connections.filter { $0.id != connectionId },
      defaultSendingConnectionId: snapshot.defaultSendingConnectionId == connectionId
        ? nil : snapshot.defaultSendingConnectionId,
      removedConnectionIds: snapshot.removedConnectionIds + [connectionId],
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
    if let saveError { throw saveError }
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

private enum AdapterTestError: Error {
  case unavailable
}

extension MailboxConnectionSyncSnapshot {
  fileprivate static let empty = MailboxConnectionSyncSnapshot(
    connections: [],
    defaultSendingConnectionId: nil,
    removedConnectionIds: [],
    updatedAt: nil
  )
}

private final class RecordingAdapterMetadataService: GmailMessageMetadataSyncing {
  private let eventLog: RecordingAdapterEventLog?
  var loadedConnection: GmailProviderConnectionStatus?
  var loadedCollections: [MailboxMessageCollection] = []
  var recentSyncResult = RecordingAdapterMetadataService.result
  var syncedConnection: GmailProviderConnectionStatus?

  init(eventLog: RecordingAdapterEventLog? = nil) {
    self.eventLog = eventLog
  }

  func categorizeHistorical(
    scope _: GmailHistoricalCategorizationScope,
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    Self.result
  }

  func loadInbox(
    connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    loadedConnection = connection
    return Self.result
  }

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    loadedConnection = connection
    loadedCollections.append(collection)
    if collection == .allObserved {
      eventLog?.events.append("observed")
    } else if collection == .role(.inbox) {
      eventLog?.events.append("inbox")
    }
    return collection == .allObserved ? Self.result : Self.result.projected(to: collection)
  }

  func syncInbox(
    connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    syncedConnection = connection
    return Self.result
  }

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection _: GmailProviderConnectionStatus,
    includingHistoryCandidates _: Bool,
    session _: ProductAccountSessionSnapshot,
    sinceHistoryId _: String?,
    throughHistoryId _: String?,
    shouldPersist _: @escaping () -> Bool
  ) async throws -> GmailMetadataSyncResult {
    recentSyncResult
  }

  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    message.assigningCategory(categoryId)
  }

  private static let result = GmailMetadataSyncResult(
    messages: [adapterGmailMessage],
    threads: GmailInboxThread.group([adapterGmailMessage])
  )
}

private final class RecordingAdapterSearchService: GmailMessageSearching {
  var query: String?

  func searchProvider(
    query: String,
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    self.query = query
    return [adapterGmailMessage]
  }
}

private final class RecordingAdapterMessageReader: GmailMessageReading {
  func clearCachedMessageBodies(session _: ProductAccountSessionSnapshot) throws {}

  func loadMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageBody {
    GmailMessageBody(text: "Decrypted body")
  }

  func removeCachedMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws {}
}

private final class RecordingAdapterPushService: GmailPushWatchRegistering {
  var connection: GmailProviderConnectionStatus?

  func registerOrRenew(
    connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailPushWatchStatus {
    self.connection = connection
    return GmailPushWatchStatus(expirationMilliseconds: 100, historyId: "10")
  }
}

private final class RecordingAdapterMailActionService: GmailProviderMailActing {
  private let eventLog: RecordingAdapterEventLog?
  var action: GmailProviderMailAction?
  var messageIds: [String] = []
  var outgoingMessage: GmailOutgoingMessage?

  init(eventLog: RecordingAdapterEventLog? = nil) {
    self.eventLog = eventLog
  }

  func perform(
    _ action: GmailProviderMailAction,
    messageIds: [String],
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    self.action = action
    self.messageIds = messageIds
    eventLog?.events.append("resume")
  }

  func send(
    _ message: GmailOutgoingMessage,
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    outgoingMessage = message
  }
}

private final class FailingAdapterMailActionService: GmailProviderMailActing {
  func perform(
    _: GmailProviderMailAction,
    messageIds _: [String],
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    throw PendingAdapterActionError.rejected
  }

  func send(
    _: GmailOutgoingMessage,
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
}

private final class RecoverableAuthMailActionService: GmailProviderMailActing {
  private var isAuthorized = false
  var messageIds: [String] = []

  func perform(
    _: GmailProviderMailAction,
    messageIds: [String],
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    guard isAuthorized else {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    self.messageIds.append(contentsOf: messageIds)
  }

  func restoreAuthorization() {
    isAuthorized = true
  }

  func send(
    _: GmailOutgoingMessage,
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
}

private final class RecordingAdapterEventLog {
  var events: [String] = []
}

private final class AdapterPendingActionStore: PendingProviderActionPersisting {
  private var actions: [PendingProviderAction] = []

  func load(productAccountId: String) throws -> [PendingProviderAction] {
    actions.filter { $0.productAccountId == productAccountId }
  }

  func save(
    _ actions: [PendingProviderAction],
    productAccountId: String
  ) throws {
    self.actions.removeAll { $0.productAccountId == productAccountId }
    self.actions += actions
  }
}

private actor GatedAdapterMailActionService: GmailProviderMailActing {
  private let blockedProviderIdentifier: String
  private let firstStarted: XCTestExpectation
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private let secondPerformed: XCTestExpectation

  init(
    blockedProviderIdentifier: String,
    firstStarted: XCTestExpectation,
    secondPerformed: XCTestExpectation
  ) {
    self.blockedProviderIdentifier = blockedProviderIdentifier
    self.firstStarted = firstStarted
    self.secondPerformed = secondPerformed
  }

  func perform(
    _: GmailProviderMailAction,
    messageIds _: [String],
    connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    if connection.providerAccountIdentifier == blockedProviderIdentifier {
      firstStarted.fulfill()
      await withCheckedContinuation { continuation in
        releaseContinuation = continuation
      }
    } else {
      secondPerformed.fulfill()
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }

  func send(
    _: GmailOutgoingMessage,
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
}

private struct RestoredBlockedActionService: MailboxProviderMailActing {
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
    "Pending action requires attention."
  }

  func blockedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session _: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    connections.map(\.id)
  }

  func send(
    _: OutgoingMessage,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
}

private enum PendingAdapterActionError: Error {
  case rejected
}

private actor MultiplePendingFailureService: MailboxProviderMailActing {
  private var failedConnectionIds: Set<MailboxConnectionId>

  init(failedConnectionIds: Set<MailboxConnectionId>) {
    self.failedConnectionIds = failedConnectionIds
  }

  func perform(
    _: ProviderMailAction,
    messages _: [MailboxMessageMetadata],
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func resumePendingActions(
    connections: [MailboxConnection],
    session _: ProductAccountSessionSnapshot
  ) async -> String? {
    connections.first(where: { failedConnectionIds.contains($0.id) })
      .map { "\($0.displayName) requires attention." }
  }

  func failedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session _: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    connections.map(\.id).filter { failedConnectionIds.contains($0) }
  }

  func acknowledgePendingActionFailures(
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async {
    failedConnectionIds.remove(connection.id)
  }

  func send(
    _: OutgoingMessage,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
}

private actor RecordingBulkMailActionService: MailboxProviderMailActing {
  private var connectionIds: [MailboxConnectionId] = []
  private let failingConnectionId: MailboxConnectionId

  init(failingConnectionId: MailboxConnectionId) {
    self.failingConnectionId = failingConnectionId
  }

  func perform(
    _: ProviderMailAction,
    messages _: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    connectionIds.append(connection.id)
    if connection.id == failingConnectionId {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
  }

  func recordedConnectionIds() -> [MailboxConnectionId] {
    connectionIds
  }

  func send(
    _: OutgoingMessage,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
}

private actor RetryableBulkMailActionService: MailboxProviderMailActing {
  private let blockedConnectionId: MailboxConnectionId
  private var isBlocked = true
  private var retries = 0

  init(blockedConnectionId: MailboxConnectionId) {
    self.blockedConnectionId = blockedConnectionId
  }

  func perform(
    _: ProviderMailAction,
    messages _: [MailboxMessageMetadata],
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func resumePendingActions(
    connections: [MailboxConnection],
    session _: ProductAccountSessionSnapshot
  ) async -> String? {
    guard isBlocked, connections.contains(where: { $0.id == blockedConnectionId }) else {
      return nil
    }
    return "Authorization expired."
  }

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async -> String? {
    guard connection.id == blockedConnectionId else { return nil }
    retries += 1
    isBlocked = false
    return nil
  }

  func blockedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session _: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    guard isBlocked else { return [] }
    return connections.map(\.id).filter { $0 == blockedConnectionId }
  }

  func retryCount() -> Int {
    retries
  }

  func send(
    _: OutgoingMessage,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
}

private struct ConnectionPendingActionFailureService: MailboxProviderMailActing {
  func perform(
    _: ProviderMailAction,
    messages _: [MailboxMessageMetadata],
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func resumePendingActions(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async -> String? {
    "The provider connection failed."
  }

  func pendingActionFailureDetails(
    _: ProviderMailAction,
    messages _: [MailboxMessageMetadata],
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async -> [MailboxProviderActionFailureDetail]? {
    []
  }

  func send(
    _: OutgoingMessage,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
}

private actor GatedBulkMailActionService: MailboxProviderMailActing {
  private let blockedConnectionId: MailboxConnectionId
  private let firstStarted: XCTestExpectation
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private let secondStarted: XCTestExpectation

  init(
    blockedConnectionId: MailboxConnectionId,
    firstStarted: XCTestExpectation,
    secondStarted: XCTestExpectation
  ) {
    self.blockedConnectionId = blockedConnectionId
    self.firstStarted = firstStarted
    self.secondStarted = secondStarted
  }

  func perform(
    _: ProviderMailAction,
    messages _: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    if connection.id == blockedConnectionId {
      firstStarted.fulfill()
      await withCheckedContinuation { continuation in
        releaseContinuation = continuation
      }
    } else {
      secondStarted.fulfill()
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }

  func send(
    _: OutgoingMessage,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
}
