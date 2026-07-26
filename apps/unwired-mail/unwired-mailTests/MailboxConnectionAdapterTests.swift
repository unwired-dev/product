import QuartzCore
import SwiftUI
import UIKit
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
    let viewModel = MailboxProviderConnectionViewModel(
      service: adapter,
      isSessionCurrent: { $0 == self.session },
      session: session
    )

    _ = await viewModel.load()

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
    let viewModel = MailboxProviderConnectionViewModel(
      service: adapter,
      isSessionCurrent: { $0 == self.session },
      session: session
    )

    _ = await viewModel.load()

    XCTAssertEqual(
      viewModel.selectedConnectionId,
      localStatus.mailboxConnection(productAccountId: session.productAccountId).id
    )
  }

  func testViewModelReportsLoadErrorWhenConnectionsCannotLoad() async {
    let definitionSyncService = RecordingAdapterDefinitionSyncService(snapshot: .empty)
    definitionSyncService.loadError = AdapterTestError.unavailable
    let adapter = GmailMailboxConnectionAdapter(definitionSyncService: definitionSyncService)
    let viewModel = MailboxProviderConnectionViewModel(
      service: adapter,
      isSessionCurrent: { $0 == self.session },
      session: session
    )

    _ = await viewModel.load()

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
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
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
      definitionSyncService: definitionSyncService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
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
      definitionSyncService: definitionSyncService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
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
      definitionSyncService: definitionSyncService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
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
      metadataService: metadataService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
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
      pendingActionService: pendingActionService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
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

  // swiftlint:disable function_body_length
  @MainActor
  func testGmailFirstReleaseMixedConnectionScenario() async throws {
    let firstStatus = RecordingAdapterConnectionService.status
    let secondStatus = GmailProviderConnectionStatus(
      connectedAt: firstStatus.connectedAt,
      emailAddress: "second@example.com",
      lastVerifiedAt: firstStatus.lastVerifiedAt,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: firstStatus.updatedAt
    )
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = []
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: firstStatus.updatedAt
      )
    )
    let credentialVerifier = RecordingAdapterCredentialVerifier()
    credentialVerifier.verifiedAccounts = [firstStatus, secondStatus].map {
      VerifiedGmailAccount(
        emailAddress: $0.emailAddress,
        providerAccountIdentifier: $0.providerAccountIdentifier,
        tokens: GmailProviderTokens(
          accessToken: "verified-\($0.providerAccountIdentifier)",
          refreshToken: "refreshed-\($0.providerAccountIdentifier)"
        )
      )
    }
    let bodyReader = RecordingAdapterMessageReader()
    let mailActionService = RecordingAdapterMailActionService()
    let metadataService = RecordingAdapterMetadataService()
    let pushService = RecordingAdapterPushService()
    let outboxService = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: AdapterOutboxStore()
    )
    let pendingActionService = PendingProviderActionService(store: AdapterPendingActionStore())
    let adapter = GmailMailboxConnectionAdapter(
      bodyReader: bodyReader,
      connectionService: connectionService,
      credentialVerifier: credentialVerifier,
      definitionSyncService: definitionSyncService,
      mailActionService: mailActionService,
      metadataService: metadataService,
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer(),
      pushWatchService: pushService,
      pendingActionService: pendingActionService,
      outboxService: outboxService
    )

    for _ in 0..<2 {
      _ = try await adapter.connect(
        expectedConnectionId: nil,
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
    }
    let connections = try await adapter.loadConnections(session: session)
    let model = MailShellSelectionModel()
    model.selectUnifiedInbox()
    var messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]] = [:]
    for connection in connections {
      let sync = try await adapter.syncInbox(connection: connection, session: session)
      model.updateThreads(sync.threads, for: connection.id)
      messagesByConnection[connection.id] = sync.messages
      let message = try XCTUnwrap(sync.messages.first)
      _ = try await adapter.loadMessageBody(message: message, session: session)
      try await adapter.prefetchMessageBodies(
        connection: connection,
        pinnedMessageIds: [message.id],
        referenceDate: Date(timeIntervalSince1970: 1_781_200_000),
        session: session
      )
      try await adapter.perform(
        .archive,
        messages: [message],
        connection: connection,
        session: session
      )
      try await pendingActionService.enqueue(
        .markUnread,
        messages: [message],
        connection: connection,
        session: session
      )
      try await adapter.send(
        OutgoingMessage(
          body: "Hello from \(connection.displayName)",
          recipient: "reader@example.com",
          subject: "Mixed Gmail release"
        ),
        connection: connection,
        session: session
      )
      _ = try await outboxService.enqueue(
        OutgoingMessage(
          body: "Queued from \(connection.displayName)",
          recipient: "offline@example.com",
          subject: "Connection-scoped Outbox"
        ),
        connection: connection,
        session: session,
        provider: { _, _, _ in },
        reconcile: { _, _ in .unknown }
      )
      try await adapter.registerOrRenewPush(connection: connection, session: session)
    }
    _ = await adapter.resumePendingActions(connections: connections, session: session)
    let defaultsSuite = "MailboxConnectionAdapterTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    defer {
      defaults.removePersistentDomain(forName: defaultsSuite)
    }
    let freshness = MailboxFreshnessViewModel(
      service: adapter,
      session: session,
      isSessionCurrent: { $0 == self.session },
      successStore: UserDefaultsMailboxSyncSuccessStore(defaults: defaults)
    )
    await freshness.synchronize(connections: connections)
    bodyReader.isOffline = true
    var offlineBodies: [MailboxMessageBody] = []
    for connection in connections {
      offlineBodies.append(
        try await adapter.loadMessageBody(
          message: try XCTUnwrap(messagesByConnection[connection.id]?.first),
          session: session
        ))
    }
    let outboxItems = try await outboxService.items(session: session)
    let outboxStates: [MailShellOutboxState] = outboxItems.map {
      switch $0.state {
      case .handingOff, .pending:
        .pending
      case .reconciling, .retrying:
        .retrying
      case .failed, .outcomeUnknown, .userActionRequired:
        .failed
      case .cancelled, .sent, .superseded:
        .sent
      }
    }

    let pinnedIds = Set(messagesByConnection.values.flatMap { $0 }.map(\.id))
    let navigation = MailboxNavigationSnapshot(
      messagesByConnection: messagesByConnection,
      pinnedMessageIds: pinnedIds,
      outboxStates: outboxStates
    )
    XCTAssertEqual(
      connections.map(\.id.rawValue),
      [
        "gmail:gmail-user-001", "gmail:gmail-user-002",
      ])
    XCTAssertEqual(
      credentialVerifier.verifiedAccounts.map(\.providerAccountIdentifier),
      []
    )
    XCTAssertEqual(model.threads.count, 2)
    XCTAssertEqual(navigation.count(for: .pins).itemCount, 2)
    XCTAssertTrue(navigation.showsOutbox)
    XCTAssertEqual(Set(outboxItems.map(\.connectionId)), Set(connections.map(\.id)))
    XCTAssertEqual(
      Set(offlineBodies.map(\.text)),
      [
        "Cached body for gmail-user-001",
        "Cached body for gmail-user-002",
      ])
    XCTAssertEqual(
      Set(metadataService.syncedProviderAccountIdentifiers),
      [
        "gmail-user-001", "gmail-user-002",
      ])
    XCTAssertEqual(
      Set(bodyReader.loadedProviderAccountIdentifiers),
      [
        "gmail-user-001", "gmail-user-002",
      ])
    XCTAssertEqual(
      Set(bodyReader.prefetchedProviderAccountIdentifiers),
      [
        "gmail-user-001", "gmail-user-002",
      ])
    XCTAssertEqual(
      Set(pushService.providerAccountIdentifiers),
      [
        "gmail-user-001", "gmail-user-002",
      ])
    XCTAssertEqual(
      Set(mailActionService.sentProviderAccountIdentifiers),
      [
        "gmail-user-001", "gmail-user-002",
      ])
    XCTAssertEqual(
      Set(mailActionService.performedProviderAccountIdentifiers),
      [
        "gmail-user-001", "gmail-user-002",
      ])
    XCTAssertEqual(
      Set(
        mailActionService.performedActions
          .filter { $0.action == .markUnread }
          .map(\.providerAccountIdentifier)
      ),
      Set(connections.map(\.providerMailboxIdentity.value))
    )
    XCTAssertTrue(connections.allSatisfy { freshness.status(for: $0).phase == .idle })
    XCTAssertTrue(
      connections.allSatisfy { freshness.status(for: $0).lastSuccessfulSyncAt != nil }
    )

    try await adapter.clearLocalConnection(connections[0], session: session)
    try await adapter.removeMailboxConnectionEverywhere(connections[1], session: session)

    XCTAssertEqual(
      connectionService.clearedProviderAccountIdentifiers,
      [
        "gmail-user-001", "gmail-user-002",
      ])
    XCTAssertEqual(definitionSyncService.removedConnectionIds, [connections[1].id])
    try await outboxService.clear(session: session)
  }
  // swiftlint:enable function_body_length

  func testGmailAdapterUsesStableOutboxIdentityAndReconcilesSentDelivery() async throws {
    let mailActionService = RecordingAdapterMailActionService()
    let searchService = RecordingAdapterSearchService()
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      mailActionService: mailActionService,
      searchService: searchService
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId
    )
    let message = OutgoingMessage(
      body: "Hello",
      recipient: "reader@example.com",
      subject: "Subject",
      idempotencyKey: "unwired-attempt-001"
    )

    try await adapter.send(message, connection: connection, session: session)
    let status = try await adapter.deliveryStatus(
      idempotencyKey: "unwired-attempt-001",
      connection: connection,
      session: session
    )

    XCTAssertEqual(
      mailActionService.outgoingMessage?.rfcMessageId,
      "<unwired-attempt-001@outbox.unwired.mail>"
    )
    XCTAssertEqual(
      searchService.query,
      "in:sent rfc822msgid:<unwired-attempt-001@outbox.unwired.mail>"
    )
    XCTAssertEqual(status, .sent)
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

  // swiftlint:disable function_body_length
  @MainActor
  func testGmailFirstReleaseCachedPresentationMeetsPerformanceBudgets() async throws {
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
    let connections = [firstConnection, secondConnection]
    let connectionStatuses = connections.map {
      GmailProviderConnectionStatus(
        connectedAt: $0.connectedAt,
        emailAddress: $0.displayName,
        lastVerifiedAt: $0.lastVerifiedAt,
        provider: $0.providerId.rawValue,
        providerAccountIdentifier: $0.providerMailboxIdentity.value,
        trustedDeviceId: $0.trustedDeviceId,
        updatedAt: $0.updatedAt
      )
    }
    let threadsByConnection = Dictionary(
      uniqueKeysWithValues: connections.map { connection in
        (
          connection.id,
          (0..<50).map { index in
            mailShellThread(
              connectionId: connection.id,
              providerMessageId: "message-\(index)",
              providerThreadId: "thread-\(index)",
              receivedAt: Int64(index)
            )
          }
        )
      }
    )
    let metadataStore = try SwiftDataGmailMessageMetadataStore.inMemory()
    for connection in connections {
      try metadataStore.saveMessages(
        threadsByConnection[connection.id, default: []].flatMap(\.messages).map(\.gmailMetadata),
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerMailboxIdentity.value
      )
    }
    let cachedMetadataService = GmailMessageMetadataService(store: metadataStore)
    let keyMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 1, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 2, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    try keyMaterialStore.save(keyMaterial, productAccountId: session.productAccountId)
    let encryptedBodyCache = ReleaseEncryptedMessageBodyCache()
    for message in threadsByConnection.values.flatMap({ $0 }).flatMap(\.messages) {
      try encryptedBodyCache.saveMessageBody(
        keyMaterial.encryptPayload(
          Data("Cached body".utf8),
          associatedData: Data("gmail-body-cache:\(message.id.rawValue)".utf8)
        ),
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.id.rawValue
      )
    }
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = connectionStatuses
    let metadataService = RecordingAdapterMetadataService()
    metadataService.providerDelayNanoseconds = 25_000_000
    let adapter = GmailMailboxConnectionAdapter(
      bodyReader: GmailMessageBodyService(
        cache: encryptedBodyCache,
        keyMaterialStore: keyMaterialStore,
        oauthClientId: nil
      ),
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: connections.map(\.definition),
          defaultSendingConnectionId: connections.first?.id,
          removedConnectionIds: [],
          updatedAt: 1_781_200_000_300
        )
      ),
      metadataService: metadataService,
      pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore()),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )
    let productionSyncTokenStore = ReleaseGmailProviderTokenStore()
    for status in connectionStatuses {
      try productionSyncTokenStore.save(
        GmailProviderTokens(
          accessToken: "access-\(status.providerAccountIdentifier)",
          refreshToken: "refresh-\(status.providerAccountIdentifier)"
        ),
        productAccountId: session.productAccountId,
        providerAccountIdentifier: status.providerAccountIdentifier
      )
    }
    let productionSyncService = GmailMessageMetadataService(
      gmailBaseURL: URL(string: "https://gmail.release.test/gmail/v1")!,
      notificationEligibilityStore: ReleaseGmailPushEligibilityStore(),
      oauthClientId: "gmail-client-id",
      session: releaseGmailSyncSession(),
      store: metadataStore,
      tokenStore: productionSyncTokenStore,
      tokenInfoURL: URL(string: "https://oauth.release.test/tokeninfo")!,
      tokenRefreshURL: URL(string: "https://oauth.release.test/token")!
    )
    let productionSyncAdapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      metadataService: productionSyncService,
      pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore()),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )
    let clock = ContinuousClock()
    let navigationSnapshot = MailboxNavigationSnapshot(
      messagesByConnection: threadsByConnection.mapValues { $0.flatMap(\.messages) },
      pinnedMessageIds: [],
      outboxStates: []
    )
    let inboxViewModel = GmailInboxViewModel(
      service: adapter,
      searchService: adapter,
      session: session
    )
    let mailActionViewModel = GmailMailActionViewModel(
      service: adapter,
      session: session,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )
    var launchSamples: [Double] = []
    var mailboxSwitchSamples: [Double] = []
    var mailViewSwitchSamples: [Double] = []
    var bodyOpenSamples: [Double] = []
    var emptyDraftOpenSamples: [Double] = []
    var warmDraftOpenSamples: [Double] = []
    var directInputFeedbackSamples: [Double] = []
    var formattingFeedbackSamples: [Double] = []
    var selectedThreadIds: Set<MailboxThreadIdentity> = []
    let selectedThreadIdsBinding = Binding(
      get: { selectedThreadIds },
      set: { selectedThreadIds = $0 }
    )

    for _ in 0..<20 {
      let launchStart = clock.now
      let launchModel = MailShellSelectionModel()
      launchModel.selectUnifiedInbox()
      for (connection, status) in zip(connections, connectionStatuses) {
        let cached = try await cachedMetadataService.loadInbox(
          connection: status,
          session: session
        ).mailboxResult(connectionId: connection.id)
        launchModel.updateThreads(cached.threads, for: connection.id)
      }
      let launchItems = launchModel.threadListItems(connections: connections)
      XCTAssertEqual(launchItems.count, 100)
      let host = UIHostingController(
        rootView: MailShellThreadList(
          connection: nil,
          connections: connections,
          isConnectionBusy: false,
          items: launchItems,
          mailActionViewModel: mailActionViewModel,
          mailboxSelection: .unified(.inbox),
          navigationSnapshot: navigationSnapshot,
          selectedThreadIds: selectedThreadIdsBinding,
          viewModel: inboxViewModel
        )
      )
      let window = releaseFixtureWindow(hosting: host)
      await releaseRenderFrame(host.view)
      launchSamples.append(releaseElapsedMilliseconds(from: launchStart, clock: clock))

      let switchStart = clock.now
      launchModel.selectMailbox(connectionId: secondConnection.id)
      XCTAssertEqual(launchModel.threads.count, 50)
      host.rootView = MailShellThreadList(
        connection: secondConnection,
        connections: connections,
        isConnectionBusy: false,
        items: launchModel.threadListItems(connections: connections),
        mailActionViewModel: mailActionViewModel,
        mailboxSelection: .connection(secondConnection.id, .role(.inbox)),
        navigationSnapshot: navigationSnapshot,
        selectedThreadIds: selectedThreadIdsBinding,
        viewModel: inboxViewModel
      )
      await releaseRenderFrame(host.view)
      mailboxSwitchSamples.append(releaseElapsedMilliseconds(from: switchStart, clock: clock))

      let mailViewSwitchStart = clock.now
      launchModel.selectMailbox(connectionId: secondConnection.id, collection: .role(.sent))
      host.rootView = MailShellThreadList(
        connection: secondConnection,
        connections: connections,
        isConnectionBusy: false,
        items: launchModel.threadListItems(connections: connections),
        mailActionViewModel: mailActionViewModel,
        mailboxSelection: .connection(secondConnection.id, .role(.sent)),
        navigationSnapshot: navigationSnapshot,
        selectedThreadIds: selectedThreadIdsBinding,
        viewModel: inboxViewModel
      )
      await releaseRenderFrame(host.view)
      mailViewSwitchSamples.append(
        releaseElapsedMilliseconds(from: mailViewSwitchStart, clock: clock)
      )
      launchModel.selectMailbox(connectionId: secondConnection.id)

      let bodyStart = clock.now
      host.rootView = MailShellThreadList(
        connection: secondConnection,
        connections: connections,
        isConnectionBusy: false,
        items: launchModel.threadListItems(connections: connections),
        mailActionViewModel: mailActionViewModel,
        mailboxSelection: .connection(secondConnection.id, .role(.inbox)),
        navigationSnapshot: navigationSnapshot,
        selectedThreadIds: selectedThreadIdsBinding,
        viewModel: inboxViewModel
      )
      let bodyLoaded = expectation(description: "Cached message body loaded")
      let bodyHost = UIHostingController(
        rootView: MailShellMessageBody(
          onLoaded: { bodyLoaded.fulfill() },
          load: {
            try await adapter.loadMessageBody(
              message: try XCTUnwrap(launchModel.threads.first?.latestMessage),
              session: self.session
            )
          }
        )
      )
      let bodyWindow = releaseFixtureWindow(hosting: bodyHost)
      await fulfillment(of: [bodyLoaded], timeout: 1)
      await releaseRenderFrame(bodyHost.view)
      bodyOpenSamples.append(releaseElapsedMilliseconds(from: bodyStart, clock: clock))

      let emptyDraftStart = clock.now
      let emptyDraft = MailShellCompositionDraft.new(
        defaultSendingConnectionId: firstConnection.id
      )
      let draftHost = UIHostingController(
        rootView: MailShellComposer(
          connections: connections,
          draft: emptyDraft,
          isSending: false,
          send: { _ in true }
        )
      )
      let draftWindow = releaseFixtureWindow(hosting: draftHost)
      await releaseRenderFrame(draftHost.view)
      emptyDraftOpenSamples.append(
        releaseElapsedMilliseconds(from: emptyDraftStart, clock: clock)
      )

      var warmDraft = MailShellCompositionDraft(
        body: String(repeating: "Warm draft body. ", count: 20),
        connectionId: firstConnection.id,
        recipient: "recipient@example.com",
        replyToMessage: nil,
        sourceMessage: nil,
        subject: "Warm draft"
      )
      let warmDraftStart = clock.now
      draftHost.rootView = MailShellComposer(
        connections: connections,
        draft: warmDraft,
        isSending: false,
        send: { _ in true }
      )
      await releaseRenderFrame(draftHost.view)
      warmDraftOpenSamples.append(
        releaseElapsedMilliseconds(from: warmDraftStart, clock: clock)
      )

      let directInputStart = clock.now
      warmDraft.body.append("a")
      draftHost.rootView = MailShellComposer(
        connections: connections,
        draft: warmDraft,
        isSending: false,
        send: { _ in true }
      )
      await releaseRenderFrame(draftHost.view)
      directInputFeedbackSamples.append(
        releaseElapsedMilliseconds(from: directInputStart, clock: clock)
      )

      let formattingStart = clock.now
      warmDraft.body = warmDraft.body.replacingOccurrences(of: "Warm", with: "WARM")
      draftHost.rootView = MailShellComposer(
        connections: connections,
        draft: warmDraft,
        isSending: false,
        send: { _ in true }
      )
      await releaseRenderFrame(draftHost.view)
      formattingFeedbackSamples.append(
        releaseElapsedMilliseconds(from: formattingStart, clock: clock)
      )
      window.isHidden = true
      bodyWindow.isHidden = true
      draftWindow.isHidden = true
    }

    var providerLatencySamples: [Double] = []
    let stallProbe = ReleaseMainThreadStallProbe()
    stallProbe.start()
    for connection in connections {
      let providerStart = clock.now
      _ = try await productionSyncAdapter.syncInbox(connection: connection, session: session)
      providerLatencySamples.append(releaseElapsedMilliseconds(from: providerStart, clock: clock))
    }
    let syncMainActorStall = await stallProbe.stop()
    let categorizationMainActorStall = try await releaseMainThreadStall {
      for connection in connections {
        guard let message = threadsByConnection[connection.id]?.first?.latestMessage else {
          XCTFail("Missing categorization fixture message")
          continue
        }
        _ = try await adapter.overrideCategory(
          "system:promotions",
          for: message,
          session: session
        )
      }
    }
    let unreadCountingMainActorStall = await releaseMainThreadStall {
      for _ in 0..<20 {
        _ = navigationSnapshot.count(for: .inbox)
        await Task.yield()
      }
    }
    let formattingMainActorStall = await releaseMainThreadStall {
      _ = await Task.detached {
        String(repeating: "Draft formatting ", count: 100)
          .replacingOccurrences(of: "formatting", with: "FORMAT")
      }.value
    }
    let autosaveURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("release-draft-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: autosaveURL) }
    let draftAutosaveMainActorStall = try await releaseMainThreadStall {
      let payload = Data(
        #"{"recipient":"recipient@example.com","subject":"Warm draft","body":"Cached body"}"#.utf8
      )
      try await Task.detached {
        try payload.write(to: autosaveURL, options: .atomic)
      }.value
    }

    XCTAssertLessThan(releaseP95(launchSamples), 1_000)
    XCTAssertLessThan(releaseP95(mailboxSwitchSamples), 200)
    XCTAssertLessThan(releaseP95(mailViewSwitchSamples), 200)
    XCTAssertLessThan(releaseP95(bodyOpenSamples), 200)
    XCTAssertLessThan(releaseP95(emptyDraftOpenSamples), 200)
    XCTAssertLessThan(releaseP95(warmDraftOpenSamples), 200)
    XCTAssertLessThan(releaseP95(directInputFeedbackSamples), 34)
    XCTAssertLessThan(releaseP95(formattingFeedbackSamples), 34)
    XCTAssertLessThan(syncMainActorStall, 100)
    XCTAssertLessThan(categorizationMainActorStall, 100)
    XCTAssertLessThan(unreadCountingMainActorStall, 100)
    XCTAssertLessThan(formattingMainActorStall, 100)
    XCTAssertLessThan(draftAutosaveMainActorStall, 100)
    XCTAssertEqual(
      try metadataStore.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: firstConnection.providerMailboxIdentity.value
      ).map(\.providerMessageId),
      ["sync-message"]
    )
    XCTAssertEqual(threadsByConnection.values.map(\.count).sorted(), [50, 50])
    print(
      "Gmail-first release ms: launch p95=\(releaseP95(launchSamples)), "
        + "mailbox switch p95=\(releaseP95(mailboxSwitchSamples)), "
        + "Mail View switch p95=\(releaseP95(mailViewSwitchSamples)), "
        + "body p95=\(releaseP95(bodyOpenSamples)), "
        + "empty Draft p95=\(releaseP95(emptyDraftOpenSamples)), "
        + "warm Draft p95=\(releaseP95(warmDraftOpenSamples)), "
        + "input frame p95=\(releaseP95(directInputFeedbackSamples)), "
        + "format frame p95=\(releaseP95(formattingFeedbackSamples)), "
        + "sync main max=\(syncMainActorStall), "
        + "categorization main max=\(categorizationMainActorStall), "
        + "unread main max=\(unreadCountingMainActorStall), "
        + "format main max=\(formattingMainActorStall), "
        + "Draft autosave main max=\(draftAutosaveMainActorStall), "
        + "provider seam p95=\(releaseP95(providerLatencySamples)) (reported separately)"
    )
  }
  // swiftlint:enable function_body_length

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
    let replyAll = MailShellCompositionDraft.replyAll(
      to: message,
      senderAddress: "reader@example.com"
    )
    let forward = MailShellCompositionDraft.forward(message, body: "Decrypted body")

    XCTAssertEqual(reply.connectionId, message.connectionId)
    XCTAssertEqual(reply.sourceThreadId, message.threadIdentity)
    XCTAssertEqual(reply.sourceMailboxIdentity, message.connectionId.providerMailboxIdentity)
    XCTAssertEqual(reply.replyToMessage, message)
    XCTAssertEqual(reply.recipient, "sender@example.com")
    XCTAssertEqual(reply.subject, "Re: Subject message-001")
    XCTAssertEqual(replyAll.connectionId, message.connectionId)
    XCTAssertEqual(replyAll.recipient, "sender@example.com")
    XCTAssertEqual(forward.connectionId, message.connectionId)
    XCTAssertEqual(forward.sourceThreadId, message.threadIdentity)
    XCTAssertEqual(forward.sourceMailboxIdentity, message.connectionId.providerMailboxIdentity)
    XCTAssertEqual(forward.sourceMessage, message)
    XCTAssertNil(forward.replyToMessage)
    XCTAssertEqual(forward.forwardSourceMessage, message)
    XCTAssertEqual(forward.subject, "Fwd: Subject message-001")
    XCTAssertTrue(forward.body.contains("Decrypted body"))
  }

  func testMailShellReplyAllSplitsRecipientHeaderMailboxes() {
    let message = MailboxMessageMetadata(
      categoryId: nil,
      connectionId: adapterConnectionId,
      from: "Sender <sender@example.com>",
      isHistorical: false,
      providerInternalDateMilliseconds: 100,
      providerMessageId: "message-001",
      providerStateIds: ["INBOX"],
      providerThreadId: "thread-001",
      recipientHeaders: [
        "reader@example.com, teammate@example.com",
        "\"Doe, Jane\" <jane@example.com>",
      ],
      replyTo: "sender@example.com",
      rfcMessageId: "<message-001@example.com>",
      snippet: "Message message-001",
      subject: "Subject message-001",
      bccRecipients: ["hidden@example.com"]
    )

    let draft = MailShellCompositionDraft.replyAll(
      to: message,
      senderAddress: "reader@example.com"
    )

    XCTAssertEqual(
      draft.recipient,
      "sender@example.com, teammate@example.com, \"Doe, Jane\" <jane@example.com>"
    )
  }

  func testMailShellReplyAllDoesNotExposeLegacyBccOrSenderAliases() {
    let message = MailboxMessageMetadata(
      categoryId: nil,
      connectionId: adapterConnectionId,
      from: "Sender Alias <sender+alias@example.com>",
      isHistorical: false,
      providerInternalDateMilliseconds: 100,
      providerMessageId: "message-legacy",
      providerStateIds: ["SENT"],
      providerThreadId: "thread-legacy",
      recipientHeaders: ["sender+alias@example.com, hidden@example.com, teammate@example.com"],
      replyTo: "sender@example.com",
      rfcMessageId: "<message-legacy@example.com>",
      snippet: "Legacy message",
      subject: "Legacy subject"
    )

    let draft = MailShellCompositionDraft.replyAll(
      to: message,
      senderAddress: "sender@example.com"
    )

    XCTAssertEqual(draft.recipient, "")
  }

  func testNewMessageKeepsUnavailableDefaultSendingConnectionWithoutSubstitution() {
    let unavailableDefault = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .imapSMTP,
        value: "unavailable@example.com"
      )
    )

    let draft = MailShellCompositionDraft.new(
      defaultSendingConnectionId: unavailableDefault
    )

    XCTAssertEqual(draft.connectionId, unavailableDefault)
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
    let viewModel = GmailMailActionViewModel(
      service: adapter,
      session: session,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )
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
      session: session,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
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
    let viewModel = GmailMailActionViewModel(
      service: service,
      session: session,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )
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

private struct PerformedAdapterAction {
  let action: GmailProviderMailAction
  let providerAccountIdentifier: String
}

private final class ReleaseGmailProviderTokenStore: GmailProviderTokenPersisting {
  private var tokensByConnection: [String: GmailProviderTokens] = [:]

  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    tokensByConnection[key(productAccountId, providerAccountIdentifier)] = nil
  }

  func clearAll(productAccountId: String) throws {
    tokensByConnection = tokensByConnection.filter {
      !$0.key.hasPrefix("\(productAccountId)\u{0}")
    }
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailProviderTokens? {
    tokensByConnection[key(productAccountId, providerAccountIdentifier)]
  }

  func save(
    _ tokens: GmailProviderTokens,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    tokensByConnection[key(productAccountId, providerAccountIdentifier)] = tokens
  }

  private func key(_ productAccountId: String, _ providerAccountIdentifier: String) -> String {
    "\(productAccountId)\u{0}\(providerAccountIdentifier)"
  }
}

private struct ReleaseGmailPushEligibilityStore: GmailPushEligibilityPersisting {
  func record(
    _: [GmailMessageMetadata],
    throughHistoryId _: String,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}

  func eligibleStableMessageIds(
    after _: String,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> Set<String> { [] }

  func discard(
    through _: String,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}
}

// swiftlint:disable:next function_body_length
private func releaseGmailSyncSession() -> URLSession {
  ConvexClientTesting.makeSession { request in
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )!
    switch request.url?.path {
    case "/token":
      let body = String(data: releaseRequestBodyData(request), encoding: .utf8) ?? ""
      let identifier = body.contains("gmail-user-002") ? "gmail-user-002" : "gmail-user-001"
      return (
        response,
        Data(#"{"access_token":"refreshed-\#(identifier)"}"#.utf8)
      )
    case "/tokeninfo":
      let identifier =
        request.url?.query?.contains("gmail-user-002") == true
        ? "gmail-user-002" : "gmail-user-001"
      let email = identifier == "gmail-user-002" ? "second@example.com" : "first@example.com"
      return (
        response,
        Data(
          """
          {
            "sub":"\(identifier)",
            "email":"\(email)",
            "scope":"https://www.googleapis.com/auth/gmail.modify"
          }
          """.utf8
        )
      )
    case "/gmail/v1/users/me/messages":
      return (response, Data(#"{"messages":[{"id":"sync-message"}]}"#.utf8))
    default:
      return (
        response,
        Data(
          """
          {
            "id":"sync-message",
            "threadId":"sync-thread",
            "internalDate":"1781200000000",
            "labelIds":["INBOX","UNREAD"],
            "snippet":"Release sync fixture",
            "payload":{"headers":[
              {"name":"From","value":"Sender <sender@example.com>"},
              {"name":"To","value":"User <user@example.com>"},
              {"name":"Subject","value":"Release sync"}
            ]}
          }
          """.utf8
        )
      )
    }
  }
}

private func releaseRequestBodyData(_ request: URLRequest) -> Data {
  if let body = request.httpBody {
    return body
  }
  guard let stream = request.httpBodyStream else {
    return Data()
  }
  stream.open()
  defer { stream.close() }
  var data = Data()
  let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_024)
  defer { buffer.deallocate() }
  while stream.hasBytesAvailable {
    let count = stream.read(buffer, maxLength: 1_024)
    guard count > 0 else { break }
    data.append(buffer, count: count)
  }
  return data
}

private final class ReleaseEncryptedMessageBodyCache: GmailMessageBodyCaching {
  private var payloads: [String: ProductSyncEncryptedPayload] = [:]

  func clearMessageBodies(productAccountId _: String) throws {
    payloads.removeAll()
  }

  func clearMessageBodies(
    productAccountId _: String,
    providerAccountIdentifier: String
  ) throws {
    payloads = payloads.filter {
      !$0.key.hasPrefix("gmail:\(providerAccountIdentifier):")
    }
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

private func releaseElapsedMilliseconds(
  from start: ContinuousClock.Instant,
  clock: ContinuousClock
) -> Double {
  let components = start.duration(to: clock.now).components
  return Double(components.seconds) * 1_000
    + Double(components.attoseconds) / 1_000_000_000_000_000
}

@MainActor
private func releaseFixtureWindow<Content: View>(
  hosting controller: UIHostingController<Content>
) -> UIWindow {
  let window = UIWindow(frame: UIScreen.main.bounds)
  window.rootViewController = controller
  window.makeKeyAndVisible()
  return window
}

@MainActor
private func releaseRenderFrame(_ view: UIView) async {
  view.setNeedsLayout()
  view.layoutIfNeeded()
  CATransaction.flush()
  try? await Task.sleep(nanoseconds: 17_000_000)
  view.layoutIfNeeded()
  CATransaction.flush()
}

@MainActor
private final class ReleaseMainThreadStallProbe {
  private let clock = ContinuousClock()
  private var lastTick: ContinuousClock.Instant?
  private var maximumDelayMilliseconds = 0.0
  private var task: Task<Void, Never>?

  func start() {
    lastTick = clock.now
    task = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 10_000_000)
        guard let self, let lastTick = self.lastTick else { return }
        let interval = releaseElapsedMilliseconds(from: lastTick, clock: self.clock)
        self.maximumDelayMilliseconds = max(
          self.maximumDelayMilliseconds,
          max(0, interval - 10)
        )
        self.lastTick = self.clock.now
      }
    }
  }

  func stop() async -> Double {
    try? await Task.sleep(nanoseconds: 20_000_000)
    task?.cancel()
    task = nil
    return maximumDelayMilliseconds
  }
}

@MainActor
private func releaseMainThreadStall(
  _ operation: () async throws -> Void
) async rethrows -> Double {
  let probe = ReleaseMainThreadStallProbe()
  probe.start()
  try await operation()
  return await probe.stop()
}

private func releaseP95(_ samples: [Double]) -> Double {
  guard !samples.isEmpty else { return .infinity }
  let sorted = samples.sorted()
  let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
  return sorted[index]
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
  var verifiedAccounts: [VerifiedGmailAccount] = []

  func verify(
    accessToken: String,
    refreshToken: String
  ) async throws -> VerifiedGmailAccount {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    if !verifiedAccounts.isEmpty {
      return verifiedAccounts.removeFirst()
    }
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
  var clearedProviderAccountIdentifiers: [String] = []
  var statuses = [RecordingAdapterConnectionService.status]

  func clearLocalConnection(session _: ProductAccountSessionSnapshot) async throws {}

  func clearLocalConnection(
    _ connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    clearedConnection = connection
    clearedProviderAccountIdentifiers.append(connection.providerAccountIdentifier)
    statuses.removeAll {
      $0.providerAccountIdentifier == connection.providerAccountIdentifier
    }
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
    statuses.removeAll {
      $0.providerAccountIdentifier == status.providerAccountIdentifier
    }
    statuses.append(status)
    return status
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
  var providerDelayNanoseconds: UInt64 = 0
  var syncedConnection: GmailProviderConnectionStatus?
  var syncedProviderAccountIdentifiers: [String] = []

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
    if providerDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: providerDelayNanoseconds)
    }
    syncedConnection = connection
    syncedProviderAccountIdentifiers.append(connection.providerAccountIdentifier)
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
  private var cachedBodies: [String: GmailMessageBody] = [:]
  var isOffline = false
  var loadedProviderAccountIdentifiers: [String] = []
  var prefetchedProviderAccountIdentifiers: [String] = []

  func clearCachedMessageBodies(session _: ProductAccountSessionSnapshot) throws {}

  func clearCachedMessageBodies(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) throws {}

  func loadMessageBody(
    message: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageBody {
    loadedProviderAccountIdentifiers.append(message.providerAccountIdentifier)
    if isOffline {
      guard let cached = cachedBodies[message.providerAccountIdentifier] else {
        throw URLError(.notConnectedToInternet)
      }
      return cached
    }
    return GmailMessageBody(text: "Decrypted body")
  }

  func prefetchMessageBodies(
    connection: GmailProviderConnectionStatus,
    pinnedMessageIds _: Set<String>,
    referenceDate _: Date,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    prefetchedProviderAccountIdentifiers.append(connection.providerAccountIdentifier)
    cachedBodies[connection.providerAccountIdentifier] = GmailMessageBody(
      text: "Cached body for \(connection.providerAccountIdentifier)"
    )
  }

  func removeCachedMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws {}
}

private final class RecordingAdapterPushService: GmailPushWatchRegistering {
  var connection: GmailProviderConnectionStatus?
  var providerAccountIdentifiers: [String] = []

  func registerOrRenew(
    connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailPushWatchStatus {
    self.connection = connection
    providerAccountIdentifiers.append(connection.providerAccountIdentifier)
    return GmailPushWatchStatus(expirationMilliseconds: 100, historyId: "10")
  }
}

private final class RecordingAdapterMailActionService: GmailProviderMailActing {
  private let eventLog: RecordingAdapterEventLog?
  var action: GmailProviderMailAction?
  var messageIds: [String] = []
  var outgoingMessage: GmailOutgoingMessage?
  var performedActions: [PerformedAdapterAction] = []
  var performedProviderAccountIdentifiers: [String] = []
  var sentProviderAccountIdentifiers: [String] = []

  init(eventLog: RecordingAdapterEventLog? = nil) {
    self.eventLog = eventLog
  }

  func perform(
    _ action: GmailProviderMailAction,
    messageIds: [String],
    connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    self.action = action
    self.messageIds = messageIds
    performedActions.append(
      PerformedAdapterAction(
        action: action,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ))
    performedProviderAccountIdentifiers.append(connection.providerAccountIdentifier)
    eventLog?.events.append("resume")
  }

  func send(
    _ message: GmailOutgoingMessage,
    connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    outgoingMessage = message
    sentProviderAccountIdentifiers.append(connection.providerAccountIdentifier)
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

private final class AdapterOutboxStore: OutboxDeliveryPersisting, @unchecked Sendable {
  private var attempts: [OutgoingDeliveryAttempt] = []

  func load(productAccountId: String) throws -> [OutgoingDeliveryAttempt] {
    attempts.filter { $0.productAccountId.rawValue == productAccountId }
  }

  func save(
    _ attempts: [OutgoingDeliveryAttempt],
    productAccountId _: String
  ) throws {
    self.attempts = attempts
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
