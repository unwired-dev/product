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

    viewModel.updateThreads([newerThread], for: adapterConnectionId)

    XCTAssertNil(viewModel.selectedThreadId)
    XCTAssertEqual(viewModel.navigationLevel, .threadList)
    XCTAssertEqual(viewModel.preferredCompactColumn, .content)
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

}

private func mailShellThread(
  providerThreadId: String,
  messages: [MailboxMessageMetadata]
) -> MailboxThread {
  MailboxThread.group(messages).first { $0.providerThreadId == providerThreadId }!
}

private func mailShellMessage(
  providerMessageId: String,
  providerThreadId: String,
  receivedAt: Int64
) -> MailboxMessageMetadata {
  MailboxMessageMetadata(
    categoryId: nil,
    connectionId: adapterConnectionId,
    from: "Sender <sender@example.com>",
    isHistorical: false,
    providerInternalDateMilliseconds: receivedAt,
    providerMessageId: providerMessageId,
    providerStateIds: ["INBOX"],
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
    snapshot
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
  var loadedConnection: GmailProviderConnectionStatus?
  var syncedConnection: GmailProviderConnectionStatus?

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
    Self.result
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
  var action: GmailProviderMailAction?
  var messageIds: [String] = []
  var outgoingMessage: GmailOutgoingMessage?

  func perform(
    _ action: GmailProviderMailAction,
    messageIds: [String],
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    self.action = action
    self.messageIds = messageIds
  }

  func send(
    _ message: GmailOutgoingMessage,
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    outgoingMessage = message
  }
}
