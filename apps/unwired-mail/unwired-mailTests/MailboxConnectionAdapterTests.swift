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
    XCTAssertEqual(definitionSyncService.recreatedDefinition?.id, connection?.id)
  }

  func testGmailAccountCleanupWaitsForInFlightConnect() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let completionGate = AdapterLifecycleOperationGate()
    let connectionService = RecordingAdapterConnectionService(
      lifecycleEventLog: eventLog,
      completionGate: completionGate
    )
    connectionService.statuses = []
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer(),
      syncGate: MailboxConnectionSyncGate()
    )

    let connectTask = Task {
      try await adapter.connect(session: session, isSessionCurrent: { $0 == self.session })
    }
    await completionGate.waitUntilStarted()
    let cleanupTask = Task {
      try await adapter.clearLocalConnection(session: session, isStillCurrent: { true })
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)

    await completionGate.release()
    _ = try await connectTask.value
    try await cleanupTask.value
    let events = await eventLog.snapshot()
    XCTAssertEqual(
      events,
      ["connection-completed", "local-state-cleared"]
    )
  }

  func testGmailConnectDoesNotRecoverUnrelatedConnections() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer()
    )

    _ = try await adapter.connect(session: session, isSessionCurrent: { $0 == self.session })

    XCTAssertEqual(connectionService.loadConnectionsCallCount, 0)
  }

  func testGmailReauthorizationPurgesStaleGenerationBeforeInstallingFreshAuthorization()
    async throws
  {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.locallyAuthorizedIdentifiers = ["gmail-user-001"]
    let synchronized = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .required
    ).definition.withAuthorizationGeneration(1)
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [synchronized],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: 1,
        authorizationCleanupConnectionIds: [synchronized.id],
        localCleanupGenerations: [synchronized.id: 1]
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: definitionSyncService,
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer(),
      pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore()),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let connection = try await adapter.connect(
      session: session,
      isSessionCurrent: { $0 == self.session }
    )

    XCTAssertEqual(connectionService.clearedProviderAccountIdentifiers, ["gmail-user-001"])
    XCTAssertEqual(connection?.authorizationGeneration, 1)
    XCTAssertEqual(definitionSyncService.completedCleanupGenerations[synchronized.id], 1)
  }

  func testCompletedGmailTombstoneCleanupIsNotRepeatedWithoutALocalCredential()
    async throws
  {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = []
    connectionService.locallyAuthorizedIdentifiers = []
    let synchronized = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .required
    ).definition.withAuthorizationGeneration(1)
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [synchronized],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: 1,
        authorizationCleanupConnectionIds: [synchronized.id],
        localCleanupGenerations: [synchronized.id: 1]
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: definitionSyncService,
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer(),
      pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore()),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    _ = try await adapter.loadConnections(session: session)
    _ = try await adapter.loadConnections(session: session)

    XCTAssertEqual(connectionService.clearedProviderAccountIdentifiers, ["gmail-user-001"])
    XCTAssertEqual(definitionSyncService.completedCleanupGenerations[synchronized.id], 1)
  }

  func testGmailLoadBlocksCredentialMigrationForAnAdvancedGeneration() async throws {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = []
    connectionService.locallyAuthorizedIdentifiers = ["gmail-user-001"]
    let synchronized = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .required
    ).definition.withAuthorizationGeneration(1)
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [synchronized],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: 1,
        authorizationCleanupConnectionIds: [synchronized.id],
        localCleanupGenerations: [synchronized.id: 1]
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: definitionSyncService,
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer(),
      pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore()),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    _ = try await adapter.loadConnections(session: session)

    XCTAssertEqual(connectionService.clearedProviderAccountIdentifiers, ["gmail-user-001"])
    XCTAssertEqual(
      connectionService.migrationPolicies,
      [
        GmailCredentialMigrationPolicy(
          allowsUnscopedLegacyMigration: false,
          blockedProviderAccountIdentifiers: ["gmail-user-001"]
        )
      ]
    )
  }

  func testGmailConnectRollbackPreservesExistingTokenOnlyAuthorization() async throws {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = []
    connectionService.locallyAuthorizedIdentifiers = ["gmail-user-001"]
    let definitionSyncService = RecordingAdapterDefinitionSyncService(snapshot: .empty)
    definitionSyncService.saveError = AdapterTestError.unavailable
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: definitionSyncService,
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer(),
      syncGate: MailboxConnectionSyncGate()
    )

    do {
      _ = try await adapter.connect(session: session, isSessionCurrent: { $0 == self.session })
      XCTFail("Expected synchronized definition save failure")
    } catch is AdapterTestError {
    }

    XCTAssertTrue(connectionService.clearedProviderAccountIdentifiers.isEmpty)
    XCTAssertEqual(connectionService.statuses.map(\.providerAccountIdentifier), ["gmail-user-001"])
  }

  func testGmailReauthorizationPurgesStaleGenerationBeforeSavingFreshTokens() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let staleConnection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [staleConnection.definition.withAuthorizationGeneration(1)],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: staleConnection.updatedAt,
        authorizationCleanupConnectionIds: [staleConnection.id]
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: definitionSyncService,
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer(),
      pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore()),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let connection = try await adapter.connect(
      session: session,
      isSessionCurrent: { $0 == self.session }
    )

    XCTAssertEqual(connectionService.clearedProviderAccountIdentifiers, ["gmail-user-001"])
    XCTAssertEqual(connectionService.completedAccount?.tokens.accessToken, "oauth-access-token")
    XCTAssertEqual(connection?.authorizationGeneration, 1)
  }

  func testGmailReauthorizationRechecksCleanupAfterSavingDefinition() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let staleConnection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [staleConnection.definition],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: staleConnection.updatedAt
      )
    )
    let cleanupGeneration = 1
    definitionSyncService.snapshotAfterSave = MailboxConnectionSyncSnapshot(
      connections: [
        staleConnection.definition.withAuthorizationGeneration(cleanupGeneration)
      ],
      defaultSendingConnectionId: nil,
      removedConnectionIds: [],
      updatedAt: staleConnection.updatedAt + 1,
      authorizationCleanupConnectionIds: [staleConnection.id],
      localCleanupGenerations: [staleConnection.id: cleanupGeneration]
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: definitionSyncService,
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer(),
      pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore()),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let connection = try await adapter.connect(
      session: session,
      isSessionCurrent: { $0 == self.session }
    )

    XCTAssertEqual(connectionService.clearedProviderAccountIdentifiers, ["gmail-user-001"])
    XCTAssertEqual(connectionService.completeConnectionCallCount, 2)
    XCTAssertEqual(connection?.authorizationGeneration, cleanupGeneration)
    XCTAssertEqual(
      definitionSyncService.completedCleanupGenerations[staleConnection.id],
      cleanupGeneration
    )
  }

  func testGmailConnectClearsExistingAuthorizationWhenRecreationIsRejected() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let removalObservation = MailboxConnectionRemovalObservation(
      connectionId: adapterConnectionId,
      removedAt: 1_781_200_000_500
    )
    let definitionSyncService = RecordingAdapterDefinitionSyncService(snapshot: .empty)
    definitionSyncService.recreateError =
      MailboxConnectionSyncError.connectionRemoved(removalObservation)
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: definitionSyncService,
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer(),
      syncGate: MailboxConnectionSyncGate()
    )

    do {
      _ = try await adapter.connect(session: session, isSessionCurrent: { $0 == self.session })
      XCTFail("Expected synchronized recreation to report the removal")
    } catch let error as MailboxConnectionSyncError {
      XCTAssertEqual(error, .connectionRemoved(removalObservation))
    }

    XCTAssertEqual(connectionService.clearedProviderAccountIdentifiers, ["gmail-user-001"])
    XCTAssertTrue(connectionService.statuses.isEmpty)
  }

  func testGmailConnectionCleanupFencesConcurrentConnect() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let clearGate = AdapterLifecycleOperationGate()
    let connectionService = RecordingAdapterConnectionService(
      lifecycleEventLog: eventLog,
      clearGate: clearGate
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer(),
      pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore()),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )

    let cleanupTask = Task {
      try await adapter.clearLocalConnection(connection, session: session)
    }
    await clearGate.waitUntilStarted()
    let connectTask = Task {
      try await adapter.connect(session: session, isSessionCurrent: { $0 == self.session })
    }
    await Task.yield()
    XCTAssertNil(connectionService.completedAccount)

    await clearGate.release()
    try await cleanupTask.value
    _ = try await connectTask.value
    let events = await eventLog.snapshot()
    XCTAssertEqual(
      events,
      ["local-state-cleared", "connection-completed"]
    )
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

  func testGmailReconnectPreservesExistingGenerationWhenDefinitionSyncFails() async throws {
    let existingStatus = RecordingAdapterConnectionService.status
      .withAuthorizationGeneration(2)
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = [existingStatus]
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [
          existingStatus.mailboxConnection(
            productAccountId: session.productAccountId,
            authorizationState: .authorized
          ).definition
        ],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: 1_781_200_000_300
      )
    )
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

    XCTAssertEqual(connectionService.statuses.first?.authorizationGeneration, 2)
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
        removalObservation: nil,
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
      XCTFail("Expected authorization for a different Gmail identity to be rejected")
    } catch let error as MailboxConnectionAdapterError {
      XCTAssertEqual(error, .unexpectedAuthorizedAccount)
      XCTAssertNil(connectionService.completedAccount)
    }
  }

  // swiftlint:disable:next function_body_length
  func testTrustedDevicesAuthorizeSameSyncedDefinitionIndependently() async throws {
    let secondDeviceSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: session.appleUserIdentifier,
      identityToken: session.identityToken,
      productAccountId: session.productAccountId,
      trustedDeviceId: "trusted-device-002"
    )
    let definition = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
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
      removalObservation: nil,
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

  // swiftlint:disable:next function_body_length
  func testGmailAdapterRequiresAuthorizationForAnOlderConnectionGeneration() async throws {
    let staleStatus = RecordingAdapterConnectionService.status
    let recreatedDefinition = staleStatus.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    ).definition.withAuthorizationGeneration(1)
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [recreatedDefinition],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: 1_781_200_000_300
      )
    )
    let staleConnectionService = RecordingAdapterConnectionService()
    staleConnectionService.statuses = [staleStatus]
    let currentConnectionService = RecordingAdapterConnectionService()
    currentConnectionService.statuses = [
      GmailProviderConnectionStatus(
        authorizationGeneration: 1,
        connectedAt: staleStatus.connectedAt,
        emailAddress: staleStatus.emailAddress,
        lastVerifiedAt: staleStatus.lastVerifiedAt,
        provider: staleStatus.provider,
        providerAccountIdentifier: staleStatus.providerAccountIdentifier,
        trustedDeviceId: staleStatus.trustedDeviceId,
        updatedAt: staleStatus.updatedAt
      )
    ]
    let staleAdapter = GmailMailboxConnectionAdapter(
      connectionService: staleConnectionService,
      definitionSyncService: definitionSyncService
    )
    let currentAdapter = GmailMailboxConnectionAdapter(
      connectionService: currentConnectionService,
      definitionSyncService: definitionSyncService
    )

    let staleConnections = try await staleAdapter.loadConnections(session: session)
    let currentConnections = try await currentAdapter.loadConnections(session: session)

    XCTAssertEqual(staleConnections.first?.authorizationState, .required)
    XCTAssertEqual(currentConnections.first?.authorizationState, .authorized)
    let staleOperationConnection = try XCTUnwrap(currentConnections.first)
      .withAuthorizationGeneration(0)
    do {
      _ = try await currentAdapter.syncInbox(
        connection: staleOperationConnection,
        session: session
      )
      XCTFail("Expected a stale operation generation to require authorization")
    } catch {
      XCTAssertEqual(error as? MailboxConnectionAdapterError, .authorizationRequired)
    }
    do {
      try await currentAdapter.perform(
        .archive,
        messages: [adapterMessage],
        connection: staleOperationConnection,
        session: session
      )
      XCTFail("Expected a stale action generation to require authorization")
    } catch {
      XCTAssertEqual(error as? MailboxConnectionAdapterError, .authorizationRequired)
    }
  }

  func testGmailProviderAccessRequiresPersistedAuthorizationGeneration() async throws {
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = []
    let bodyReader = RecordingAdapterMessageReader()
    let adapter = GmailMailboxConnectionAdapter(
      bodyReader: bodyReader,
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition.withAuthorizationGeneration(1)],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      )
    )

    do {
      _ = try await adapter.loadMessageBody(message: adapterMessage, session: session)
      XCTFail("Expected authorization to be required")
    } catch let error as MailboxConnectionAdapterError {
      XCTAssertEqual(error, .authorizationRequired)
    }
    XCTAssertTrue(bodyReader.loadedProviderAccountIdentifiers.isEmpty)
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
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    ).definition
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [
          defaultDefinition,
          localStatus.mailboxConnection(
            productAccountId: session.productAccountId,
            authorizationState: .authorized
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
        productAccountId: session.productAccountId,
        authorizationState: .authorized
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
          localStatus.mailboxConnection(
            productAccountId: session.productAccountId,
            authorizationState: .authorized
          ).definition
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
      localStatus.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .authorized
      ).id
    )
  }

  func testViewModelReportsLoadErrorWhenConnectionsCannotLoad() async {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.loadError = AdapterTestError.unavailable
    let definitionSyncService = RecordingAdapterDefinitionSyncService(snapshot: .empty)
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

    XCTAssertTrue(viewModel.connections.isEmpty)
    XCTAssertNotNil(viewModel.errorMessage)
  }

  func testViewModelRequiresExplicitRetryToRecreateAnObservedRemoval() async {
    let definitionSyncService = RecordingAdapterDefinitionSyncService(snapshot: .empty)
    let removalObservation = MailboxConnectionRemovalObservation(
      connectionId: adapterConnectionId,
      removedAt: 1_781_200_000_500
    )
    definitionSyncService.recreateError =
      MailboxConnectionSyncError.connectionRemoved(removalObservation)
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: RecordingAdapterConnectionService(),
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: definitionSyncService,
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer()
    )
    let viewModel = MailboxProviderConnectionViewModel(
      service: adapter,
      isSessionCurrent: { $0 == self.session },
      session: session
    )

    let firstAttempt = await viewModel.connect()

    XCTAssertNil(firstAttempt)
    XCTAssertTrue(viewModel.isConfirmingRecreation)
    XCTAssertEqual(definitionSyncService.recreateDefinitionCount, 1)
    XCTAssertNil(definitionSyncService.recreationObservation)

    definitionSyncService.recreateError = nil
    let recreated = await viewModel.connect()

    XCTAssertEqual(recreated?.id, adapterConnectionId)
    XCTAssertEqual(definitionSyncService.recreationObservation, removalObservation)
    XCTAssertFalse(viewModel.isConfirmingRecreation)
  }

  func testViewModelClearsRecreationObservationAfterConcurrentModification() async {
    let definitionSyncService = RecordingAdapterDefinitionSyncService(snapshot: .empty)
    let removalObservation = MailboxConnectionRemovalObservation(
      connectionId: adapterConnectionId,
      removedAt: 1_781_200_000_500
    )
    definitionSyncService.recreateError =
      MailboxConnectionSyncError.connectionRemoved(removalObservation)
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: RecordingAdapterConnectionService(),
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: definitionSyncService,
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer()
    )
    let viewModel = MailboxProviderConnectionViewModel(
      service: adapter,
      isSessionCurrent: { $0 == self.session },
      session: session
    )
    _ = await viewModel.connect()
    definitionSyncService.recreateError = MailboxConnectionSyncError.concurrentModification

    _ = await viewModel.connect()

    XCTAssertFalse(viewModel.isConfirmingRecreation)
    definitionSyncService.recreateError = nil
    _ = await viewModel.connect()
    XCTAssertNil(definitionSyncService.recreationObservation)
  }

  func testViewModelRefreshesItsConnectionSnapshotAfterMetadataSync() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty)
    )
    let viewModel = MailboxProviderConnectionViewModel(
      service: adapter,
      isSessionCurrent: { $0 == self.session },
      session: session
    )
    _ = await viewModel.load()
    let refreshedStatus = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "refreshed@example.com",
      lastVerifiedAt: 1_781_200_000_100,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-refreshed",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_200
    )
    connectionService.statuses = [refreshedStatus]
    let refreshedConnectionId = refreshedStatus.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    ).id
    XCTAssertFalse(viewModel.connections.contains { $0.id == refreshedConnectionId })

    let refreshed = await viewModel.refreshSnapshot()

    XCTAssertTrue(refreshed)
    XCTAssertTrue(viewModel.connections.contains { $0.id == refreshedConnectionId })
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
            productAccountId: session.productAccountId,
            authorizationState: .authorized
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

  func testGmailAdapterRestrictsTokenlessDeviceConnectionUntilReauthorized() async throws {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.authorizationRequiredIdentifiers = ["gmail-user-001"]
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty)
    )

    let connections = try await adapter.loadConnections(session: session)
    let connection = try XCTUnwrap(connections.first)

    XCTAssertEqual(connections.map(\.id), [adapterConnectionId])
    XCTAssertEqual(connection.authorizationState, .required)
    XCTAssertEqual(connection.capabilities, .none)
  }

  func testGmailAdapterKeepsSyncedDefinitionWhenRemovingOnlyDeviceAuthorization() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [
          RecordingAdapterConnectionService.status.mailboxConnection(
            productAccountId: session.productAccountId,
            authorizationState: .authorized
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
            productAccountId: session.productAccountId,
            authorizationState: .authorized
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

  func testGmailAdapterRemovesTokenlessDeviceConnectionEverywhere() async throws {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.authorizationRequiredIdentifiers = ["gmail-user-001"]
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [
          RecordingAdapterConnectionService.status.mailboxConnection(
            productAccountId: session.productAccountId,
            authorizationState: .authorized
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

    XCTAssertEqual(connection.authorizationState, .required)
    XCTAssertEqual(connection.capabilities, .none)
    XCTAssertEqual(connectionService.clearedConnection?.providerAccountIdentifier, "gmail-user-001")
    XCTAssertEqual(definitionSyncService.removedConnectionIds, [connection.id])
  }

  func testGmailRemovalKeepsLocalAuthorizationWhenSyncRemovalFails() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let definitionSyncService = RecordingAdapterDefinitionSyncService(snapshot: .empty)
    definitionSyncService.removeError = AdapterTestError.unavailable
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )

    do {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
      XCTFail("Expected Product Sync failure")
    } catch is AdapterTestError {
    }

    XCTAssertNil(connectionService.clearedConnection)
  }

  func testGmailRemovalRetriesFailedLocalCleanupAfterReload() async throws {
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let connectionService = RecordingAdapterConnectionService()
    connectionService.clearErrors = [AdapterTestError.unavailable]
    connectionService.hideStatusOnClearFailure = true
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [connection.definition],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: connection.updatedAt
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )

    do {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
      XCTFail("Expected local cleanup failure")
    } catch is AdapterTestError {
    }

    XCTAssertEqual(definitionSyncService.removedConnectionIds, [connection.id])
    XCTAssertTrue(connectionService.statuses.isEmpty)
    XCTAssertEqual(
      connectionService.cleanupStatuses,
      [RecordingAdapterConnectionService.status]
    )

    let connections = try await adapter.loadConnections(session: session)

    XCTAssertTrue(connections.isEmpty)
    XCTAssertTrue(connectionService.statuses.isEmpty)
    XCTAssertTrue(connectionService.cleanupStatuses.isEmpty)
    XCTAssertEqual(
      connectionService.clearedProviderAccountIdentifiers,
      ["gmail-user-001", "gmail-user-001"]
    )
  }

  func testGmailRemovalIgnoresOtherProviderTombstoneWithMatchingIdentity() async throws {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = []
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [
          MailboxConnectionId(
            providerMailboxIdentity: StableProviderMailboxIdentity(
              providerId: .imapSMTP,
              value: RecordingAdapterConnectionService.status.providerAccountIdentifier
            )
          )
        ],
        updatedAt: 1_781_200_000_300
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService
    )

    let connections = try await adapter.loadConnections(session: session)

    XCTAssertTrue(connections.isEmpty)
    XCTAssertTrue(connectionService.clearedProviderAccountIdentifiers.isEmpty)
    XCTAssertEqual(
      connectionService.cleanupStatuses,
      [RecordingAdapterConnectionService.status]
    )
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
      productAccountId: session.productAccountId,
      authorizationState: .authorized
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

  func testGmailAdapterClearsLocalAuthorizationWhenSendFindsSynchronizedRemoval() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let mailActionService = RecordingAdapterMailActionService()
    let pendingActionStore = AdapterPendingActionStore()
    let outboxStore = AdapterOutboxStore()
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [adapterConnectionId],
          updatedAt: 1_781_200_000_300
        )
      ),
      mailActionService: mailActionService,
      pendingActionService: PendingProviderActionService(store: pendingActionStore),
      outboxService: OutboxDeliveryService(store: outboxStore),
      syncGate: MailboxConnectionSyncGate()
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let message = OutgoingMessage(
      body: "Hello",
      recipient: "reader@example.com",
      subject: "Subject",
      idempotencyKey: "unwired-attempt-001"
    )

    do {
      try await adapter.send(message, connection: connection, session: session)
      XCTFail("Expected synchronized removal to fence send")
    } catch let error as MailboxConnectionAdapterError {
      XCTAssertEqual(error, .connectionRemoved)
    }
    XCTAssertNil(mailActionService.outgoingMessage)
    XCTAssertEqual(connectionService.clearedConnection?.providerAccountIdentifier, "gmail-user-001")
    XCTAssertEqual(pendingActionStore.saveCallCount, 1)
    XCTAssertEqual(outboxStore.saveCallCount, 1)
  }

  func testGmailTombstoneCleanupDoesNotEnumerateUnrelatedStoredConnections() async throws {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.loadStoredConnectionsError = AdapterTestError.unavailable
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [adapterConnectionId],
          updatedAt: 1_781_200_000_300
        )
      ),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    do {
      _ = try await adapter.loadMessageBody(message: adapterMessage, session: session)
      XCTFail("Expected synchronized removal")
    } catch let error as MailboxConnectionAdapterError {
      XCTAssertEqual(error, .connectionRemoved)
    }
    XCTAssertEqual(connectionService.clearedConnection?.providerAccountIdentifier, "gmail-user-001")
  }

  func testGmailTombstoneCleanupClearsConnectionWithoutStoredStatus() async throws {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = []
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [adapterConnectionId],
          updatedAt: 1_781_200_000_300
        )
      ),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    do {
      _ = try await adapter.loadMessageBody(message: adapterMessage, session: session)
      XCTFail("Expected synchronized removal")
    } catch let error as MailboxConnectionAdapterError {
      XCTAssertEqual(error, .connectionRemoved)
    }
    XCTAssertEqual(connectionService.clearedProviderAccountIdentifiers, ["gmail-user-001"])
  }

  func testGmailTombstoneCleanupFallsBackWhenStoredStatusCannotBeLoaded() async throws {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.loadStoredConnectionError = AdapterTestError.unavailable
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [adapterConnectionId],
          updatedAt: 1_781_200_000_300
        )
      ),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    do {
      _ = try await adapter.loadMessageBody(message: adapterMessage, session: session)
      XCTFail("Expected synchronized removal")
    } catch let error as MailboxConnectionAdapterError {
      XCTAssertEqual(error, .connectionRemoved)
    }
    XCTAssertEqual(connectionService.clearedProviderAccountIdentifiers, ["gmail-user-001"])
  }

  func testGmailBodyReadPreservesRemovalSignalWhenCleanupFails() async throws {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.clearConnectionError = AdapterTestError.unavailable
    let pendingActionStore = AdapterPendingActionStore()
    let outboxStore = AdapterOutboxStore()
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [adapterConnectionId],
          updatedAt: 1_781_200_000_300
        )
      ),
      pendingActionService: PendingProviderActionService(store: pendingActionStore),
      outboxService: OutboxDeliveryService(store: outboxStore),
      syncGate: MailboxConnectionSyncGate()
    )

    do {
      _ = try await adapter.loadMessageBody(message: adapterMessage, session: session)
      XCTFail("Expected synchronized removal")
    } catch let error as MailboxConnectionAdapterError {
      XCTAssertEqual(error, .connectionRemoved)
    }
    XCTAssertEqual(pendingActionStore.saveCallCount, 1)
    XCTAssertEqual(outboxStore.saveCallCount, 1)
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
      productAccountId: session.productAccountId,
      authorizationState: .authorized
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
      productAccountId: session.productAccountId,
      authorizationState: .authorized
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
    let connection = gmailStatus.mailboxConnection(
      productAccountId: session.productAccountId, authorizationState: .authorized)
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

  func testGmailAdapterLoadsPendingInboxCandidatesForMailboxProjection() async throws {
    let metadataService = RecordingAdapterMetadataService()
    let pendingActionService = PendingProviderActionService(store: AdapterPendingActionStore())
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      metadataService: metadataService,
      pendingActionService: pendingActionService
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let restoredMessage = mailShellMessage(
      connectionId: connection.id,
      providerMessageId: "message-restored",
      providerThreadId: "thread-restored",
      receivedAt: 100,
      providerStateIds: ["TRASH"]
    )
    let movedMessage = mailShellMessage(
      connectionId: connection.id,
      providerMessageId: "message-moved",
      providerThreadId: "thread-moved",
      receivedAt: 90,
      providerStateIds: ["Label_projects"]
    )
    try await pendingActionService.enqueue(
      .restore,
      messages: [restoredMessage],
      connection: connection,
      session: session
    )
    try await pendingActionService.enqueue(
      .move,
      targetProviderMailboxId: "INBOX",
      messages: [movedMessage],
      connection: connection,
      session: session
    )

    _ = try await adapter.loadMailbox(
      .role(.inbox),
      connection: connection,
      session: session
    )

    XCTAssertEqual(
      metadataService.inboxProjectionCandidateMessageIds,
      ["message-moved", "message-restored"]
    )
    XCTAssertEqual(metadataService.loadedCollections, [.role(.inbox)])
  }

  func testGmailCachedMetadataLoadsHoldSharedGenerationGate() async throws {
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let collections: [MailboxMessageCollection] = [.role(.inbox), .role(.archive)]
    for collection in collections {
      let loadGate = AdapterLifecycleOperationGate()
      let metadataService = RecordingAdapterMetadataService(loadGate: loadGate)
      let syncGate = MailboxConnectionSyncGate()
      let adapter = GmailMailboxConnectionAdapter(
        definitionSyncService: RecordingAdapterDefinitionSyncService(
          snapshot: MailboxConnectionSyncSnapshot(
            connections: [connection.definition],
            defaultSendingConnectionId: nil,
            removedConnectionIds: [],
            updatedAt: connection.updatedAt
          )
        ),
        metadataService: metadataService,
        pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore()),
        outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
        syncGate: syncGate
      )
      let load = Task {
        try await adapter.loadMailbox(collection, connection: connection, session: session)
      }
      await loadGate.waitUntilStarted()
      let exclusiveAcquired = TestFlag()
      let exclusive = Task {
        try await syncGate.withLock(connection.id) {
          await exclusiveAcquired.set()
        }
      }
      try await Task.sleep(for: .milliseconds(20))
      let acquiredBeforeReadFinished = await exclusiveAcquired.value

      XCTAssertFalse(acquiredBeforeReadFinished)
      await loadGate.release()
      _ = try await load.value
      try await exclusive.value
      let acquiredAfterReadFinished = await exclusiveAcquired.value
      XCTAssertTrue(acquiredAfterReadFinished)
    }
  }

  func testGmailMailboxRemovalWaitsForInFlightPushRenewal() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let pushService = DelayedAdapterPushService(eventLog: eventLog)
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      pushWatchService: pushService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let renewalTask = Task {
      try await adapter.registerOrRenewPush(connection: connection, session: session)
    }
    await pushService.waitUntilStarted()
    let removalStarted = expectation(description: "mailbox removal starts")
    let removalTask = Task {
      removalStarted.fulfill()
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
    }
    await fulfillment(of: [removalStarted], timeout: 1)
    await Task.yield()
    await pushService.release()
    try await renewalTask.value
    try await removalTask.value
    let events = await eventLog.snapshot()

    XCTAssertEqual(events, ["push-state-saved", "local-state-cleared"])
    XCTAssertTrue(connectionService.statuses.isEmpty)
  }

  func testGmailMailboxRemovalWaitsForInFlightMessageBodyLoad() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let bodyReader = DelayedAdapterMessageReader(eventLog: eventLog)
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      bodyReader: bodyReader,
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let bodyTask = Task {
      try await adapter.loadMessageBody(message: adapterMessage, session: session)
    }
    await bodyReader.waitUntilStarted()
    let removalStarted = expectation(description: "mailbox removal starts")
    let removalTask = Task {
      removalStarted.fulfill()
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
    }
    await fulfillment(of: [removalStarted], timeout: 1)
    await Task.yield()
    await bodyReader.release()
    let body = try await bodyTask.value
    try await removalTask.value
    let events = await eventLog.snapshot()

    XCTAssertEqual(body, MailboxMessageBody(text: "Decrypted body"))
    XCTAssertEqual(events, ["body-cache-saved", "local-state-cleared"])
    XCTAssertTrue(connectionService.statuses.isEmpty)
  }

  func testGmailMailboxRemovalWaitsForInFlightMessageBodyPrefetch() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let bodyReader = DelayedAdapterMessageReader(eventLog: eventLog)
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      bodyReader: bodyReader,
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let prefetchTask = Task {
      try await adapter.prefetchMessageBodies(
        connection: connection,
        pinnedMessageIds: [],
        referenceDate: Date(timeIntervalSince1970: 1_781_200_000),
        session: session
      )
    }
    await bodyReader.waitUntilStarted()
    let removalTask = Task {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)
    await bodyReader.release()
    try await prefetchTask.value
    try await removalTask.value
    let events = await eventLog.snapshot()

    XCTAssertEqual(events, ["body-cache-saved", "local-state-cleared"])
    XCTAssertTrue(connectionService.statuses.isEmpty)
  }

  func testGmailForegroundBodyLoadDoesNotWaitForInFlightPrefetch() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let bodyReader = DelayedAdapterPrefetchReader(eventLog: eventLog)
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      bodyReader: bodyReader,
      connectionService: RecordingAdapterConnectionService(),
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let prefetchTask = Task {
      try await adapter.prefetchMessageBodies(
        connection: connection,
        pinnedMessageIds: [],
        referenceDate: Date(timeIntervalSince1970: 1_781_200_000),
        session: session
      )
    }
    await bodyReader.waitUntilPrefetchStarted()
    let bodyLoaded = expectation(description: "foreground body load finishes")
    let bodyTask = Task {
      let body = try await adapter.loadMessageBody(message: adapterMessage, session: session)
      bodyLoaded.fulfill()
      return body
    }
    await fulfillment(of: [bodyLoaded], timeout: 1)
    await bodyReader.releasePrefetch()

    let body = try await bodyTask.value
    try await prefetchTask.value
    let events = await eventLog.snapshot()
    XCTAssertEqual(body, MailboxMessageBody(text: "Decrypted body"))
    XCTAssertEqual(events, ["foreground-body-loaded", "prefetch-finished"])
  }

  func testGmailAccountCleanupWaitsForInFlightMessageBodyLoad() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let bodyReader = DelayedAdapterMessageReader(eventLog: eventLog)
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      bodyReader: bodyReader,
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let bodyTask = Task {
      try await adapter.loadMessageBody(message: adapterMessage, session: session)
    }
    await bodyReader.waitUntilStarted()
    let cleanupTask = Task {
      try await adapter.clearLocalConnection(session: session, isStillCurrent: { true })
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)
    await bodyReader.release()

    let body = try await bodyTask.value
    try await cleanupTask.value
    let events = await eventLog.snapshot()
    XCTAssertEqual(body, MailboxMessageBody(text: "Decrypted body"))
    XCTAssertEqual(events, ["body-cache-saved", "local-state-cleared"])
    XCTAssertTrue(connectionService.statuses.isEmpty)
  }

  func testGmailAccountCleanupDoesNotDependOnConnectionEnumeration() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    connectionService.loadError = AdapterTestError.unavailable
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    try await adapter.clearLocalConnection(session: session, isStillCurrent: { true })
    let events = await eventLog.snapshot()

    XCTAssertEqual(events, ["local-state-cleared"])
    XCTAssertTrue(connectionService.statuses.isEmpty)
  }

  func testGmailAccountCleanupUsesAllConnectionsFence() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    connectionService.loadError = AdapterTestError.unavailable
    let bodyReader = DelayedAdapterMessageReader(eventLog: eventLog)
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      bodyReader: bodyReader,
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let bodyTask = Task {
      try await adapter.loadMessageBody(message: adapterMessage, session: session)
    }
    await bodyReader.waitUntilStarted()
    let cleanupTask = Task {
      try await adapter.clearLocalConnection(session: session, isStillCurrent: { true })
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)
    await bodyReader.release()

    _ = try await bodyTask.value
    try await cleanupTask.value
    let events = await eventLog.snapshot()
    XCTAssertEqual(events, ["body-cache-saved", "local-state-cleared"])
  }

  func testGmailAccountCleanupWaitsForRecoveryCapableConnectionLoad() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let loadGate = AdapterLifecycleOperationGate()
    let connectionService = RecordingAdapterConnectionService(
      lifecycleEventLog: eventLog,
      loadGate: loadGate
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let loadTask = Task {
      try await adapter.loadConnections(session: session)
    }
    await loadGate.waitUntilStarted()
    let cleanupTask = Task {
      try await adapter.clearLocalConnection(session: session, isStillCurrent: { true })
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)

    await loadGate.release()
    _ = try await loadTask.value
    try await cleanupTask.value
    let events = await eventLog.snapshot()
    XCTAssertEqual(events, ["connection-load-finished", "local-state-cleared"])
    XCTAssertTrue(connectionService.statuses.isEmpty)
  }

  func testGmailTombstoneCleanupWaitsForRecoveryCapableConnectionLoad() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let loadGate = AdapterLifecycleOperationGate()
    let connectionService = RecordingAdapterConnectionService(
      lifecycleEventLog: eventLog,
      loadGate: loadGate
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let loadTask = Task {
      try await adapter.loadConnections(session: session)
    }
    await loadGate.waitUntilStarted()
    let cleanupTask = Task {
      try await adapter.clearLocalConnection(connection, session: session)
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)

    await loadGate.release()
    _ = try await loadTask.value
    try await cleanupTask.value
    let events = await eventLog.snapshot()
    XCTAssertEqual(events, ["connection-load-finished", "local-state-cleared"])
  }

  func testGmailReconciliationCleansTokenOnlyTombstone() async throws {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = []
    connectionService.cleanupStatuses = []
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [connection.id],
          updatedAt: connection.updatedAt
        )
      ),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let connections = try await adapter.loadConnections(session: session)

    XCTAssertTrue(connections.isEmpty)
    XCTAssertEqual(
      connectionService.clearedProviderAccountIdentifiers,
      [connection.providerMailboxIdentity.value]
    )
  }

  func testGmailReconciliationContinuesProviderCleanupAfterQueueCleanupFails() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let pendingActionStore = AdapterPendingActionStore()
    pendingActionStore.saveError = AdapterTestError.unavailable
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [connection.id],
          updatedAt: connection.updatedAt
        )
      ),
      pendingActionService: PendingProviderActionService(store: pendingActionStore),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    do {
      _ = try await adapter.loadConnections(session: session)
      XCTFail("Expected pending-action cleanup failure")
    } catch is AdapterTestError {
    }
    XCTAssertEqual(
      connectionService.clearedProviderAccountIdentifiers,
      [connection.providerMailboxIdentity.value]
    )
  }

  func testGmailReconciliationContinuesAfterEarlierTombstoneCleanupFails() async throws {
    let firstStatus = RecordingAdapterConnectionService.status
    let secondStatus = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_300,
      emailAddress: "second@example.com",
      lastVerifiedAt: 1_781_200_000_400,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_500
    )
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = [firstStatus, secondStatus]
    connectionService.cleanupStatuses = [firstStatus, secondStatus]
    connectionService.clearErrors = [AdapterTestError.unavailable]
    let removedConnectionIds = [firstStatus, secondStatus].map {
      $0.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .authorized
      ).id
    }
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [],
          defaultSendingConnectionId: nil,
          removedConnectionIds: removedConnectionIds,
          updatedAt: 1_781_200_000_600
        )
      ),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    do {
      _ = try await adapter.loadConnections(session: session)
      XCTFail("Expected first tombstone cleanup failure")
    } catch is AdapterTestError {
    }

    XCTAssertEqual(
      connectionService.clearedProviderAccountIdentifiers,
      ["gmail-user-001", "gmail-user-002"]
    )
  }

  func testGmailReconciliationRevalidatesTombstoneBeforeCleanup() async throws {
    let reconcileGate = AdapterLifecycleOperationGate()
    let connectionService = RecordingAdapterConnectionService()
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [connection.id],
        updatedAt: connection.updatedAt
      ),
      reconcileGate: reconcileGate
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let loadTask = Task {
      try await adapter.loadConnections(session: session)
    }
    await reconcileGate.waitUntilStarted()
    _ = try await definitionSyncService.saveConnection(connection, session: session)
    await reconcileGate.release()
    _ = try await loadTask.value

    XCTAssertTrue(connectionService.clearedProviderAccountIdentifiers.isEmpty)
    XCTAssertEqual(connectionService.statuses, [RecordingAdapterConnectionService.status])
  }

  func testGmailTombstoneCleanupWaitsForInFlightPrefetch() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let bodyReader = DelayedAdapterPrefetchReader(eventLog: eventLog)
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [connection.definition],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: connection.updatedAt
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      bodyReader: bodyReader,
      connectionService: connectionService,
      definitionSyncService: definitionSyncService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let prefetchTask = Task {
      try await adapter.prefetchMessageBodies(
        connection: connection,
        pinnedMessageIds: [],
        referenceDate: Date(timeIntervalSince1970: 1_781_200_000),
        session: session
      )
    }
    await bodyReader.waitUntilPrefetchStarted()
    _ = try await definitionSyncService.removeConnection(connection.id, session: session)
    let tombstoneTask = Task {
      try await adapter.loadMessageBody(message: adapterMessage, session: session)
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)
    await bodyReader.releasePrefetch()

    try await prefetchTask.value
    do {
      _ = try await tombstoneTask.value
      XCTFail("Expected synchronized removal to reject the body load")
    } catch let error as MailboxConnectionAdapterError {
      XCTAssertEqual(error, .connectionRemoved)
    }
    let events = await eventLog.snapshot()
    XCTAssertEqual(events, ["prefetch-finished", "local-state-cleared"])
  }

  func testGmailLoadInboxTombstoneCleanupReacquiresExclusiveGate() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let bodyReader = DelayedAdapterPrefetchReader(eventLog: eventLog)
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [connection.definition],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: connection.updatedAt
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      bodyReader: bodyReader,
      connectionService: connectionService,
      definitionSyncService: definitionSyncService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let prefetchTask = Task {
      try await adapter.prefetchMessageBodies(
        connection: connection,
        pinnedMessageIds: [],
        referenceDate: Date(timeIntervalSince1970: 1_781_200_000),
        session: session
      )
    }
    await bodyReader.waitUntilPrefetchStarted()
    _ = try await definitionSyncService.removeConnection(connection.id, session: session)
    let inboxTask = Task {
      try await adapter.loadInbox(connection: connection, session: session)
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)

    await bodyReader.releasePrefetch()
    try await prefetchTask.value
    do {
      _ = try await inboxTask.value
      XCTFail("Expected synchronized removal to reject the inbox load")
    } catch let error as MailboxConnectionAdapterError {
      XCTAssertEqual(error, .connectionRemoved)
    }
    let events = await eventLog.snapshot()
    XCTAssertEqual(events, ["prefetch-finished", "local-state-cleared"])
  }

  // swiftlint:disable:next function_body_length
  func testGmailOverrideCategoryTombstoneCleanupReacquiresExclusiveGate() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let bodyReader = DelayedAdapterPrefetchReader(eventLog: eventLog)
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [connection.definition],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: connection.updatedAt
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      bodyReader: bodyReader,
      connectionService: connectionService,
      definitionSyncService: definitionSyncService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let prefetchTask = Task {
      try await adapter.prefetchMessageBodies(
        connection: connection,
        pinnedMessageIds: [],
        referenceDate: Date(timeIntervalSince1970: 1_781_200_000),
        session: session
      )
    }
    await bodyReader.waitUntilPrefetchStarted()
    _ = try await definitionSyncService.removeConnection(connection.id, session: session)
    let overrideTask = Task {
      try await adapter.overrideCategory(
        "system-primary",
        for: adapterMessage,
        session: session
      )
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)

    await bodyReader.releasePrefetch()
    try await prefetchTask.value
    do {
      _ = try await overrideTask.value
      XCTFail("Expected synchronized removal to reject the category override")
    } catch let error as MailboxConnectionAdapterError {
      XCTAssertEqual(error, .connectionRemoved)
    }
    let events = await eventLog.snapshot()
    XCTAssertEqual(events, ["prefetch-finished", "local-state-cleared"])
  }

  func testGmailRemoteRemovalWaitsForInFlightPushRenewal() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let pushService = DelayedAdapterPushService(eventLog: eventLog)
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [connection.definition],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: connection.updatedAt
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService,
      pushWatchService: pushService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let renewalTask = Task {
      try await adapter.registerOrRenewPush(connection: connection, session: session)
    }
    await pushService.waitUntilStarted()
    _ = try await definitionSyncService.removeConnection(connection.id, session: session)
    let reconciliationTask = Task {
      try await adapter.loadConnections(session: session)
    }
    await Task.yield()
    await pushService.release()
    try await renewalTask.value
    let connections = try await reconciliationTask.value
    let events = await eventLog.snapshot()

    XCTAssertTrue(connections.isEmpty)
    XCTAssertEqual(events, ["push-state-saved", "local-state-cleared"])
    XCTAssertTrue(connectionService.statuses.isEmpty)
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
        removalObservation: nil,
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
      productAccountId: session.productAccountId,
      authorizationState: .authorized
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

  func testGmailMailboxRemovalWaitsForInFlightSend() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let mailActionService = DelayedAdapterMailActionService(eventLog: eventLog)
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      mailActionService: mailActionService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )
    let message = OutgoingMessage(
      body: "Hello",
      recipient: "reader@example.com",
      subject: "Subject",
      idempotencyKey: "unwired-attempt-001"
    )

    let sendTask = Task {
      try await adapter.send(message, connection: connection, session: session)
    }
    await mailActionService.waitUntilStarted()
    let removalTask = Task {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)

    await mailActionService.release()
    try await sendTask.value
    try await removalTask.value
    let events = await eventLog.snapshot()
    XCTAssertEqual(events, ["message-sent", "local-state-cleared"])
  }

  func testGmailMailboxRemovalWaitsForInFlightProviderAction() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let mailActionService = DelayedAdapterMailActionService(eventLog: eventLog)
    let pendingActionService = PendingProviderActionService(store: AdapterPendingActionStore())
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      mailActionService: mailActionService,
      pendingActionService: pendingActionService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )
    try await adapter.perform(
      .archive,
      messages: [adapterMessage],
      connection: connection,
      session: session
    )

    let actionTask = Task {
      await adapter.resumePendingActions(connection: connection, session: session)
    }
    await mailActionService.waitUntilStarted()
    let removalTask = Task {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)

    await mailActionService.release()
    let actionError = await actionTask.value
    XCTAssertNil(actionError)
    try await removalTask.value
    let events = await eventLog.snapshot()
    XCTAssertEqual(events, ["provider-action-finished", "local-state-cleared"])
  }

  func testGmailMailboxRemovalWaitsForHistoricalCategorization() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let categorizationStarted = expectation(description: "historical categorization starts")
    let metadataService = DelayedAdapterProviderReadService(
      eventLog: eventLog,
      started: categorizationStarted
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      metadataService: metadataService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let categorizationTask = Task {
      try await adapter.categorizeHistorical(
        scope: HistoricalCategorizationScope(
          receivedAtOrAfterMilliseconds: 0,
          receivedBeforeMilliseconds: 100
        ),
        connection: connection,
        session: session
      )
    }
    await fulfillment(of: [categorizationStarted], timeout: 1)
    let removalTask = Task {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)

    await metadataService.release()
    _ = try await categorizationTask.value
    try await removalTask.value
    let events = await eventLog.snapshot()
    XCTAssertEqual(
      events,
      ["historical-categorization-finished", "local-state-cleared"]
    )
  }

  func testGmailMailboxRemovalWaitsForPendingActionPersistence() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let saveStarted = expectation(description: "pending action save starts")
    let pendingActionStore = BlockingAdapterPendingActionStore(saveStarted: saveStarted)
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      pendingActionService: PendingProviderActionService(store: pendingActionStore),
      pendingActionGate: MailboxConnectionSyncGate(),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let actionTask = Task {
      try await adapter.perform(
        .archive,
        messages: [adapterMessage],
        connection: connection,
        session: session
      )
    }
    await fulfillment(of: [saveStarted], timeout: 1)
    let removalTask = Task {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)

    pendingActionStore.release()
    try await actionTask.value
    try await removalTask.value
    let events = await eventLog.snapshot()
    XCTAssertEqual(events, ["local-state-cleared"])
    XCTAssertTrue(try pendingActionStore.load(productAccountId: session.productAccountId).isEmpty)
  }

  func testGmailMailboxRemovalFencesActionsBeforeWritingTombstone() async throws {
    let removalGate = AdapterLifecycleOperationGate()
    let pendingActionStore = AdapterPendingActionStore()
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [connection.definition],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: connection.updatedAt
      ),
      removeGate: removalGate
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: RecordingAdapterConnectionService(),
      definitionSyncService: definitionSyncService,
      pendingActionService: PendingProviderActionService(store: pendingActionStore),
      pendingActionGate: MailboxConnectionSyncGate(),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let removalTask = Task {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
    }
    await removalGate.waitUntilStarted()
    let actionTask = Task {
      try await adapter.perform(
        .archive,
        messages: [adapterMessage],
        connection: connection,
        session: session
      )
    }
    await Task.yield()
    XCTAssertTrue(try pendingActionStore.load(productAccountId: session.productAccountId).isEmpty)

    await removalGate.release()
    try await removalTask.value
    do {
      try await actionTask.value
      XCTFail("Expected the action racing with removal to observe the tombstone")
    } catch MailboxConnectionAdapterError.connectionRemoved {
    }
    XCTAssertTrue(try pendingActionStore.load(productAccountId: session.productAccountId).isEmpty)
  }

  // swiftlint:disable:next function_body_length
  func testGmailMailboxRemovalWaitsForCredentialWritingProviderReads() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let providerReadsStarted = expectation(description: "provider reads start")
    providerReadsStarted.expectedFulfillmentCount = 3
    let providerService = DelayedAdapterProviderReadService(
      eventLog: eventLog,
      started: providerReadsStarted
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      metadataService: providerService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      searchService: providerService,
      syncGate: MailboxConnectionSyncGate()
    )

    let mailboxesTask = Task {
      try await adapter.loadProviderMailboxes(connection: connection, session: session)
    }
    let searchTask = Task {
      try await adapter.searchProvider(
        query: "private phrase",
        connection: connection,
        session: session
      )
    }
    let deliveryTask = Task {
      try await adapter.deliveryStatus(
        idempotencyKey: "unwired-attempt-001",
        connection: connection,
        session: session
      )
    }
    await fulfillment(of: [providerReadsStarted], timeout: 1)
    let removalTask = Task {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)

    await providerService.release()
    _ = try await mailboxesTask.value
    _ = try await searchTask.value
    _ = try await deliveryTask.value
    try await removalTask.value
    let events = await eventLog.snapshot()

    XCTAssertEqual(events.last, "local-state-cleared")
    XCTAssertEqual(
      Set(events.dropLast()),
      ["provider-mailboxes-loaded", "provider-search-finished", "delivery-status-loaded"]
    )
  }

  func testGmailMailboxRemovalWaitsForInFlightCategoryOverride() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let overrideStarted = expectation(description: "category override starts")
    let providerService = DelayedAdapterProviderReadService(
      eventLog: eventLog,
      started: overrideStarted
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      metadataService: providerService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      syncGate: MailboxConnectionSyncGate()
    )

    let overrideTask = Task {
      try await adapter.overrideCategory(
        "system-primary",
        for: adapterMessage,
        session: session
      )
    }
    await fulfillment(of: [overrideStarted], timeout: 1)
    let removalTask = Task {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
    }
    await Task.yield()
    let eventsBeforeRelease = await eventLog.snapshot()
    XCTAssertTrue(eventsBeforeRelease.isEmpty)

    await providerService.release()
    _ = try await overrideTask.value
    try await removalTask.value
    let events = await eventLog.snapshot()
    XCTAssertEqual(events, ["category-overridden", "local-state-cleared"])
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
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let secondConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "second@example.com",
      lastVerifiedAt: 1_781_200_000_100,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_200
    ).mailboxConnection(productAccountId: session.productAccountId, authorizationState: .authorized)
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
      productAccountId: session.productAccountId,
      authorizationState: .authorized
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
      productAccountId: session.productAccountId,
      authorizationState: .authorized
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
      productAccountId: session.productAccountId,
      authorizationState: .authorized
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
      productAccountId: session.productAccountId,
      authorizationState: .authorized
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

  // swiftlint:disable:next function_body_length
  func testGmailAdapterKeepsOptimisticActionAcrossIncompleteRecentSync() async throws {
    let pendingActionService = PendingProviderActionService(store: AdapterPendingActionStore())
    let metadataService = RecordingAdapterMetadataService()
    var staleGmailMessage = adapterGmailMessage
    staleGmailMessage.providerLabelIds = ["INBOX"]
    let staleMessage = staleGmailMessage.mailboxMetadata(connectionId: adapterConnectionId)
    let newestGmailMessage = GmailMessageMetadata(
      categoryId: nil,
      from: "New Sender <new@example.com>",
      isHistorical: false,
      providerAccountIdentifier: "gmail-user-001",
      providerInternalDateMilliseconds: 1_781_200_001_000,
      providerMessageId: "message-002",
      providerThreadId: "thread-002",
      replyTo: nil,
      snippet: "New private message",
      stableProviderMessageId: "gmail:gmail-user-001:message-002",
      subject: "New subject",
      rfcMessageId: "<message-002@example.com>"
    )
    metadataService.inboxSyncResult = GmailMetadataSyncResult(
      messages: [staleGmailMessage, newestGmailMessage],
      threads: GmailInboxThread.group([staleGmailMessage, newestGmailMessage])
    )
    metadataService.recentSyncResult = GmailMetadataSyncResult(
      historicalMetadataBackfillIsComplete: false,
      messages: [newestGmailMessage],
      threads: GmailInboxThread.group([newestGmailMessage])
    )
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      metadataService: metadataService,
      pendingActionService: pendingActionService
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    try await pendingActionService.perform(
      .archive,
      messages: [staleMessage],
      connection: connection,
      session: session
    ) { _, _, _ in }

    let result = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: true,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    let actionStates = try await pendingActionService.pendingActions(session: session).map(\.state)
    XCTAssertEqual(result.messages.map(\.providerMessageId), ["message-002"])
    XCTAssertEqual(actionStates, [.providerConfirmed])
  }

  func testGmailAdapterReconcilesOptimisticActionsWhenHistoricalBackfillCompletes() async throws {
    let pendingActionService = PendingProviderActionService(store: AdapterPendingActionStore())
    let metadataService = RecordingAdapterMetadataService()
    var staleGmailMessage = adapterGmailMessage
    staleGmailMessage.providerLabelIds = ["INBOX"]
    metadataService.inboxSyncResult = GmailMetadataSyncResult(
      historicalMetadataBackfillIsComplete: true,
      messages: [staleGmailMessage],
      threads: GmailInboxThread.group([staleGmailMessage])
    )
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      metadataService: metadataService,
      pendingActionService: pendingActionService
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    try await pendingActionService.perform(
      .archive,
      messages: [staleGmailMessage.mailboxMetadata(connectionId: connection.id)],
      connection: connection,
      session: session
    ) { _, _, _ in }

    _ = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    let actions = try await pendingActionService.pendingActions(session: session)
    XCTAssertTrue(actions.isEmpty)
  }

  func testGmailAdapterEnqueuesCachedActionDuringHistoricalBackfill() async throws {
    let backfillGate = AdapterLifecycleOperationGate()
    let metadataService = RecordingAdapterMetadataService(historicalBackfillGate: backfillGate)
    let pendingActionService = PendingProviderActionService(store: AdapterPendingActionStore())
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      metadataService: metadataService,
      pendingActionService: pendingActionService,
      pendingActionGate: MailboxConnectionSyncGate(),
      syncGate: MailboxConnectionSyncGate()
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let backfillTask = Task {
      try await adapter.continueHistoricalBackfill(connection: connection, session: session)
    }
    await backfillGate.waitUntilStarted()
    let actionEnqueued = expectation(description: "Cached action enqueued during backfill")
    let actionTask = Task {
      try await adapter.perform(
        .archive,
        messages: [adapterMessage],
        connection: connection,
        session: session
      )
      actionEnqueued.fulfill()
    }

    await fulfillment(of: [actionEnqueued], timeout: 1)
    let queuedActions = try await pendingActionService.pendingActions(session: session)
    XCTAssertEqual(queuedActions.map(\.action), [.archive])

    await backfillGate.release()
    _ = try await backfillTask.value
    try await actionTask.value
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

  func testMailShellSelectionCanOpenProviderSearchResultOutsideLoadedMailbox() {
    let loadedThread = mailShellThread(
      connectionId: adapterConnectionId,
      providerMessageId: "loaded-message",
      providerThreadId: "loaded-thread",
      receivedAt: 200
    )
    let searchMessage = mailShellMessage(
      providerMessageId: "archived-message",
      providerThreadId: "archived-thread",
      receivedAt: 100
    )
    let viewModel = MailShellSelectionModel()
    viewModel.selectMailbox(connectionId: adapterConnectionId)
    viewModel.updateThreads([loadedThread], for: adapterConnectionId)

    viewModel.selectSearchResult(searchMessage)
    viewModel.updateThreads([loadedThread], for: adapterConnectionId)

    XCTAssertEqual(viewModel.selectedThreadId, searchMessage.threadIdentity)
    XCTAssertEqual(viewModel.selectedThread?.messages, [searchMessage])
    XCTAssertEqual(viewModel.expandedMessageIds, [searchMessage.id])
  }

  func testMailShellSelectionSwitchesConnectionForProviderSearchResult() {
    let otherConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-002"
      )
    )
    let searchMessage = mailShellMessage(
      connectionId: otherConnectionId,
      providerMessageId: "other-message",
      providerThreadId: "other-thread",
      receivedAt: 100
    )
    let viewModel = MailShellSelectionModel()
    viewModel.selectMailbox(connectionId: adapterConnectionId)

    viewModel.selectSearchResult(searchMessage)

    XCTAssertEqual(viewModel.selectedConnectionId, otherConnectionId)
    XCTAssertEqual(viewModel.selectedThread?.messages, [searchMessage])
  }

  func testMailShellUnifiedInboxInterleavesThreadsAndShowsSourceConnections() {
    let firstConnection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
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

  func testMailShellMessageBodyDoesNotPublishLoadAfterClear() async {
    let loadStarted = expectation(description: "Message body load started")
    let loader = GatedMessageBodyLoader(started: loadStarted)
    let clearSignal = MessageBodyClearSignal()
    var didPublishLoadedBody = false
    let host = UIHostingController(
      rootView: ClearableMessageBodyHarness(
        clearSignal: clearSignal,
        onLoaded: { didPublishLoadedBody = true },
        load: { await loader.load() }
      )
    )
    let window = releaseFixtureWindow(hosting: host)

    await fulfillment(of: [loadStarted], timeout: 1)
    clearSignal.value = UUID()
    await releaseRenderFrame(host.view)
    loader.resume()
    await releaseRenderFrame(host.view)

    XCTAssertFalse(didPublishLoadedBody)
    withExtendedLifetime(window) {}
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
      productAccountId: session.productAccountId,
      authorizationState: .authorized
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
          ProviderMailbox(id: "Label_101", providerStateIds: ["SPAM"], title: "Projects"),
          ProviderMailbox(id: "Label_102", title: "First only"),
        ],
        secondConnection.id: [
          ProviderMailbox(id: "Label_201", providerStateIds: ["TRASH"], title: "Projects"),
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
    XCTAssertEqual(
      destinations.first?.targeting(batches)?.map(\.targetProviderStateIds),
      [["SPAM"], ["TRASH"]]
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

  func testContextualMoveFromProviderMailboxRequiresCompatibleConnection() {
    let gmailActions = MailShellConversationReader.contextualProviderActions(
      supported: [.move],
      messages: [],
      collection: .providerMailbox("Label_projects"),
      allowsMove: true,
      allowsProviderMailboxMove: false
    )
    let graphActions = MailShellConversationReader.contextualProviderActions(
      supported: [.move],
      messages: [],
      collection: .providerMailbox("graph-folder-projects"),
      allowsMove: true,
      allowsProviderMailboxMove: true
    )

    XCTAssertFalse(gmailActions.contains(.move))
    XCTAssertTrue(graphActions.contains(.move))
    XCTAssertFalse(
      MailShellConversationReader.allowsMoveFromProviderMailbox(.gmail)
    )
    XCTAssertTrue(
      MailShellConversationReader.allowsMoveFromProviderMailbox(.microsoftGraph)
    )
    XCTAssertTrue(
      MailShellConversationReader.allowsMoveFromProviderMailbox(.exchangeWebServices)
    )

    let archiveMessage = mailShellMessage(
      providerMessageId: "archive-message",
      providerThreadId: "archive-thread",
      receivedAt: 100,
      providerStateIds: [
        "ARCHIVE",
        EWSProviderMessage.archiveHierarchyStateId,
        EWSProviderMessage.customFolderStateId("archive-projects"),
      ]
    )
    let archiveActions = MailShellConversationReader.contextualProviderActions(
      supported: [.delete, .move, .restore, .spam],
      messages: [archiveMessage],
      collection: .providerMailbox(
        EWSProviderMessage.customFolderStateId("archive-projects")
      ),
      allowsMove: true,
      allowsProviderMailboxMove: true
    )

    XCTAssertEqual(archiveActions, [.delete])
    XCTAssertEqual(
      MailboxMessageCollection.providerMailboxIds(in: [archiveMessage]),
      [EWSProviderMessage.customFolderStateId("archive-projects")]
    )
  }

  func testContextualActionsHonorInheritedProviderMailboxRoles() {
    let spamMessage = mailShellMessage(
      providerMessageId: "spam-message",
      providerThreadId: "spam-thread",
      receivedAt: 100,
      providerStateIds: [
        "SPAM",
        EWSProviderMessage.customFolderStateId("junk-projects"),
      ]
    )
    let trashMessage = mailShellMessage(
      providerMessageId: "trash-message",
      providerThreadId: "trash-thread",
      receivedAt: 100,
      providerStateIds: [
        "TRASH",
        EWSProviderMessage.customFolderStateId("deleted-projects"),
      ]
    )

    let spamActions = MailShellConversationReader.contextualProviderActions(
      supported: [.notSpam, .restore, .spam],
      messages: [spamMessage],
      collection: .providerMailbox(
        EWSProviderMessage.customFolderStateId("junk-projects")
      ),
      allowsMove: true,
      allowsProviderMailboxMove: true
    )
    let trashActions = MailShellConversationReader.contextualProviderActions(
      supported: [.notSpam, .restore, .spam],
      messages: [trashMessage],
      collection: .providerMailbox(
        EWSProviderMessage.customFolderStateId("deleted-projects")
      ),
      allowsMove: true,
      allowsProviderMailboxMove: true
    )

    XCTAssertEqual(spamActions, [.notSpam])
    XCTAssertEqual(trashActions, [.restore])
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

  func testMailShellArchiveActionGatingOnlyUsesSelectedMailboxMessages() {
    let inboxMessage = mailShellMessage(
      providerMessageId: "message-inbox",
      providerThreadId: "thread-001",
      receivedAt: 100,
      providerStateIds: ["INBOX"]
    )
    let archiveMessage = mailShellMessage(
      providerMessageId: "message-archive",
      providerThreadId: "thread-001",
      receivedAt: 50,
      providerStateIds: [
        "ARCHIVE",
        EWSProviderMessage.archiveHierarchyStateId,
      ]
    )
    let thread = mailShellThread(
      providerThreadId: "thread-001",
      messages: [archiveMessage, inboxMessage]
    )
    let viewModel = MailShellSelectionModel()
    viewModel.selectUnifiedMailbox(.inbox)

    let selectedMessages = viewModel.selectedMailboxMessages(
      in: thread,
      pinnedMessageIds: []
    )
    let actions = MailShellConversationReader.contextualProviderActions(
      supported: [.move, .spam],
      messages: selectedMessages,
      collection: .role(.inbox),
      allowsMove: true,
      allowsProviderMailboxMove: true
    )

    XCTAssertEqual(selectedMessages, [inboxMessage])
    XCTAssertEqual(actions, [.move, .spam])
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
      productAccountId: session.productAccountId,
      authorizationState: .authorized
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

  func testMailActionReplyFromAnotherConnectionUsesANewProviderMessage() async throws {
    let sourceConnection = mailShellConnection(
      emailAddress: "source@example.com",
      providerAccountIdentifier: "source-account",
      productAccountId: session.productAccountId
    )
    let selectedConnection = mailShellConnection(
      emailAddress: "selected@example.com",
      providerAccountIdentifier: "selected-account",
      productAccountId: session.productAccountId
    )
    let sourceMessage = mailShellMessage(
      connectionId: sourceConnection.id,
      providerMessageId: "source-message",
      providerThreadId: "source-thread",
      receivedAt: 100
    )
    let store = AdapterOutboxStore()
    let viewModel = GmailMailActionViewModel(
      service: RestoredBlockedActionService(),
      session: session,
      outboxService: OutboxDeliveryService(store: store)
    )

    let didSend = await viewModel.send(
      recipient: "recipient@example.com",
      subject: "Re: Subject",
      body: "Reply",
      replyTo: sourceMessage,
      sourceMessage: sourceMessage,
      connection: selectedConnection
    )
    let attempt = try XCTUnwrap(
      store.load(productAccountId: session.productAccountId).first
    )

    XCTAssertTrue(didSend)
    XCTAssertEqual(attempt.message.kind, .new)
    XCTAssertNil(attempt.message.sourceProviderMessageId)
    XCTAssertNil(attempt.message.providerThreadId)
  }

  func testEditingOutboxReplyOnSameConnectionPreservesProviderReplyMetadata() async throws {
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let store = AdapterOutboxStore()
    let outboxService = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: store
    )
    let original = try await outboxService.enqueue(
      OutgoingMessage(
        body: "Original",
        recipient: "sender@example.com",
        subject: "Re: Subject",
        inReplyTo: "<source@example.com>",
        kind: .reply,
        providerThreadId: "provider-thread",
        sourceProviderMessageId: "provider-message"
      ),
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .unknown }
    )
    let viewModel = GmailMailActionViewModel(
      service: RestoredBlockedActionService(),
      session: session,
      outboxService: outboxService
    )

    let didEdit = await viewModel.editOutboxAttempt(
      original,
      recipient: "updated@example.com",
      subject: "Re: Updated",
      body: "Updated",
      connection: connection
    )
    let replacement = try XCTUnwrap(
      store.load(productAccountId: session.productAccountId)
        .first(where: { $0.state == .pending })
    )

    XCTAssertTrue(didEdit)
    XCTAssertEqual(replacement.message.kind, .reply)
    XCTAssertEqual(replacement.message.sourceProviderMessageId, "provider-message")
    XCTAssertEqual(replacement.message.providerThreadId, "provider-thread")
  }

  func testMailActionViewModelRestoresBlockedConnectionState() async {
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
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
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let secondConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "second@example.com",
      lastVerifiedAt: 1_781_200_000_100,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_200
    ).mailboxConnection(productAccountId: session.productAccountId, authorizationState: .authorized)
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

  func testMailActionViewModelLeavesBulkActionsEnqueuedDuringHistoricalBackfill() async {
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
      batches: [mailShellBulkActionBatch(connection: connection, suffix: "first", receivedAt: 200)],
      deferredPendingActionConnectionIds: [connection.id]
    )

    XCTAssertEqual(result?.succeededConnectionIds, [connection.id])
    XCTAssertNil(viewModel.errorMessage)
    XCTAssertFalse(viewModel.isPerformingAction)
  }

  func testMailActionViewModelSkipsGatedReloadForDeferredBulkAction() async {
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
      batches: [mailShellBulkActionBatch(connection: connection, suffix: "first", receivedAt: 200)],
      deferredPendingActionConnectionIds: [connection.id],
      onEnqueued: { _ in
        XCTFail("Deferred batches must return before the gated cache reload")
      }
    )

    XCTAssertEqual(result?.succeededConnectionIds, [connection.id])
    XCTAssertFalse(result?.shouldReloadImmediately(connection.id) ?? true)
    XCTAssertFalse(viewModel.isPerformingAction)
  }

  func testMailActionViewModelRechecksBackfillBeforeResumingBulkAction() async {
    let connection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let resumeStarted = expectation(description: "pending actions resume in background")
    let service = DeferredBulkResumeService(resumeStarted: resumeStarted)
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    let result = await viewModel.performBulk(
      .archive,
      batches: [mailShellBulkActionBatch(connection: connection, suffix: "first", receivedAt: 200)],
      shouldDeferPendingActions: { _ in true }
    )

    XCTAssertEqual(result?.succeededConnectionIds, [connection.id])
    XCTAssertFalse(viewModel.isPerformingAction)
    await fulfillment(of: [resumeStarted], timeout: 1)
    let resumeCount = await service.resumeCount()
    XCTAssertEqual(resumeCount, 1)
  }

  func testMailActionViewModelResumesEnqueuedBulkActionsInBackground() async {
    let connection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let resumeStarted = expectation(description: "pending actions resume")
    let deferredCompletion = expectation(description: "deferred completion reported")
    let service = DeferredBulkResumeService(resumeStarted: resumeStarted)
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    let result = await viewModel.performBulk(
      .archive,
      batches: [mailShellBulkActionBatch(connection: connection, suffix: "first", receivedAt: 200)],
      deferredPendingActionConnectionIds: [connection.id],
      onDeferredCompletion: { completedConnection in
        XCTAssertEqual(completedConnection.id, connection.id)
        deferredCompletion.fulfill()
      }
    )

    XCTAssertEqual(result?.succeededConnectionIds, [connection.id])
    XCTAssertFalse(viewModel.isPerformingAction)
    await fulfillment(of: [resumeStarted, deferredCompletion], timeout: 1)
    let resumeCount = await service.resumeCount()
    XCTAssertEqual(resumeCount, 1)
  }

  func testMailActionViewModelResumesOnlyNonBackfillingConnectionsInline() async {
    let backfillingConnection = mailShellConnection(
      emailAddress: "backfilling@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let currentConnection = mailShellConnection(
      emailAddress: "current@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let resumesStarted = expectation(description: "pending actions resume")
    resumesStarted.expectedFulfillmentCount = 2
    let service = DeferredBulkResumeService(
      resumeStarted: resumesStarted,
      resumeError: "The provider connection failed.",
      resumeErrorConnectionId: currentConnection.id
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    let result = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(
          connection: backfillingConnection,
          suffix: "backfilling",
          receivedAt: 200
        ),
        mailShellBulkActionBatch(
          connection: currentConnection,
          suffix: "current",
          receivedAt: 100
        ),
      ],
      deferredPendingActionConnectionIds: [backfillingConnection.id]
    )

    XCTAssertEqual(result?.succeededConnectionIds, [backfillingConnection.id])
    XCTAssertEqual(result?.failures.map(\.connectionId), [currentConnection.id])
    XCTAssertEqual(
      viewModel.errorMessage,
      "current@example.com — Subject message-current "
        + "[gmail:gmail-user-002:message-current]: The provider connection failed."
    )
    await fulfillment(of: [resumesStarted], timeout: 1)
  }

  func testMailActionViewModelSurfacesDeferredBulkResumeFailures() async {
    let connection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let resumeStarted = expectation(description: "pending actions resume")
    let service = DeferredBulkResumeService(
      resumeStarted: resumeStarted,
      resumeError: "The provider connection failed.",
      failedConnectionId: connection.id
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    let result = await viewModel.performBulk(
      .archive,
      batches: [mailShellBulkActionBatch(connection: connection, suffix: "first", receivedAt: 200)],
      deferredPendingActionConnectionIds: [connection.id]
    )

    XCTAssertEqual(result?.succeededConnectionIds, [connection.id])
    XCTAssertFalse(viewModel.isPerformingAction)
    let errorSurfaced = expectation(description: "deferred error surfaced")
    Task { @MainActor in
      while viewModel.errorMessage == nil {
        await Task.yield()
      }
      errorSurfaced.fulfill()
    }
    await fulfillment(of: [resumeStarted, errorSurfaced], timeout: 1)
    XCTAssertEqual(viewModel.failedConnectionIds, [connection.id])
    XCTAssertEqual(
      viewModel.errorMessage,
      "first@example.com — Subject message-first "
        + "[gmail:gmail-user-001:message-first]: The provider connection failed."
    )
  }

  func testMailActionViewModelAggregatesDeferredBulkResumeFailures() async {
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
    let resumesStarted = expectation(description: "pending actions resume")
    resumesStarted.expectedFulfillmentCount = 2
    let service = DeferredBulkResumeService(
      resumeStarted: resumesStarted,
      resumeError: "The provider connection failed.",
      failedConnectionIds: [firstConnection.id, secondConnection.id]
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    let result = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(connection: firstConnection, suffix: "first", receivedAt: 200),
        mailShellBulkActionBatch(connection: secondConnection, suffix: "second", receivedAt: 100),
      ],
      deferredPendingActionConnectionIds: [firstConnection.id, secondConnection.id]
    )

    XCTAssertEqual(
      Set(result?.succeededConnectionIds ?? []),
      [firstConnection.id, secondConnection.id]
    )
    await fulfillment(of: [resumesStarted], timeout: 1)
    let errorsSurfaced = expectation(description: "deferred errors surfaced")
    Task { @MainActor in
      while viewModel.errorMessage == nil {
        await Task.yield()
      }
      errorsSurfaced.fulfill()
    }
    await fulfillment(of: [errorsSurfaced], timeout: 1)
    XCTAssertEqual(
      viewModel.errorMessage,
      "first@example.com — Subject message-first "
        + "[gmail:gmail-user-001:message-first]: The provider connection failed.\n"
        + "second@example.com — Subject message-second "
        + "[gmail:gmail-user-002:message-second]: The provider connection failed."
    )
  }

  func testMailActionViewModelPreservesBlockedDeferredBulkResumeFailures() async {
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
    let resumesStarted = expectation(description: "pending actions resume")
    resumesStarted.expectedFulfillmentCount = 2
    let service = DeferredBulkResumeService(
      resumeStarted: resumesStarted,
      resumeError: "The provider connection requires attention.",
      blockedConnectionIds: [firstConnection.id, secondConnection.id]
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    _ = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(connection: firstConnection, suffix: "first", receivedAt: 200),
        mailShellBulkActionBatch(connection: secondConnection, suffix: "second", receivedAt: 100),
      ],
      deferredPendingActionConnectionIds: [firstConnection.id, secondConnection.id]
    )

    await fulfillment(of: [resumesStarted], timeout: 1)
    let errorsSurfaced = expectation(description: "blocked errors surfaced")
    Task { @MainActor in
      while viewModel.errorMessage?.contains("first@example.com") != true
        || viewModel.errorMessage?.contains("second@example.com") != true
      {
        await Task.yield()
      }
      errorsSurfaced.fulfill()
    }
    await fulfillment(of: [errorsSurfaced], timeout: 1)
  }

  // swiftlint:disable:next function_body_length
  func testMailActionViewModelPreservesInlineFailureWhenDeferredBatchFails() async {
    let deferredConnection = mailShellConnection(
      emailAddress: "deferred@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let currentConnection = mailShellConnection(
      emailAddress: "current@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let resumesStarted = expectation(description: "pending actions resume")
    resumesStarted.expectedFulfillmentCount = 2
    let service = DeferredBulkResumeService(
      resumeStarted: resumesStarted,
      resumeError: "The provider connection failed.",
      failedConnectionIds: [deferredConnection.id, currentConnection.id]
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    let result = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(
          connection: deferredConnection,
          suffix: "deferred",
          receivedAt: 200
        ),
        mailShellBulkActionBatch(
          connection: currentConnection,
          suffix: "current",
          receivedAt: 100
        ),
      ],
      deferredPendingActionConnectionIds: [deferredConnection.id]
    )

    XCTAssertEqual(result?.failures.map(\.connectionId), [currentConnection.id])
    await fulfillment(of: [resumesStarted], timeout: 1)
    let errorsSurfaced = expectation(description: "inline and deferred errors surfaced")
    Task { @MainActor in
      while viewModel.errorMessage?.contains("deferred@example.com") != true {
        await Task.yield()
      }
      errorsSurfaced.fulfill()
    }
    await fulfillment(of: [errorsSurfaced], timeout: 1)
    XCTAssertEqual(
      viewModel.errorMessage,
      "current@example.com — Subject message-current "
        + "[gmail:gmail-user-002:message-current]: The provider connection failed.\n"
        + "deferred@example.com — Subject message-deferred "
        + "[gmail:gmail-user-001:message-deferred]: The provider connection failed."
    )
  }

  func testMailActionViewModelDoesNotResumeDeferredBatchThatFailedToEnqueue() async {
    let connection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let resumeStarted = expectation(description: "pending actions resume")
    resumeStarted.isInverted = true
    let service = DeferredBulkResumeService(
      resumeStarted: resumeStarted,
      performFailureConnectionId: connection.id
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    let result = await viewModel.performBulk(
      .archive,
      batches: [mailShellBulkActionBatch(connection: connection, suffix: "first", receivedAt: 200)],
      deferredPendingActionConnectionIds: [connection.id]
    )

    XCTAssertEqual(result?.failures.map(\.connectionId), [connection.id])
    await fulfillment(of: [resumeStarted], timeout: 0.1)
    let resumeCount = await service.resumeCount()
    XCTAssertEqual(resumeCount, 0)
  }

  func testMailActionViewModelRetainsNonPersistedFailureThroughDeferredCompletion() async {
    let deferredConnection = mailShellConnection(
      emailAddress: "deferred@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let currentConnection = mailShellConnection(
      emailAddress: "current@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let resumeStarted = expectation(description: "pending actions resume")
    let deferredCompletion = expectation(description: "deferred completion reported")
    let service = DeferredBulkResumeService(
      resumeStarted: resumeStarted,
      performFailureConnectionId: currentConnection.id
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    let result = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(
          connection: deferredConnection,
          suffix: "deferred",
          receivedAt: 200
        ),
        mailShellBulkActionBatch(
          connection: currentConnection,
          suffix: "current",
          receivedAt: 100
        ),
      ],
      deferredPendingActionConnectionIds: [deferredConnection.id],
      onDeferredCompletion: { _ in
        deferredCompletion.fulfill()
      }
    )

    XCTAssertEqual(result?.failures.map(\.connectionId), [currentConnection.id])
    await fulfillment(of: [resumeStarted, deferredCompletion], timeout: 1)
    XCTAssertTrue(viewModel.errorMessage?.contains("current@example.com") ?? false)
  }

  // swiftlint:disable:next function_body_length
  func testMailActionViewModelDropsAcknowledgedInlineFailureBeforeDeferredCompletion() async {
    let deferredConnection = mailShellConnection(
      emailAddress: "deferred@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let currentConnection = mailShellConnection(
      emailAddress: "current@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let resumeStarted = expectation(description: "pending actions resume")
    resumeStarted.expectedFulfillmentCount = 2
    let resumeGate = AdapterLifecycleOperationGate()
    let service = DeferredBulkResumeService(
      resumeStarted: resumeStarted,
      resumeError: "The provider connection failed.",
      failedConnectionIds: [deferredConnection.id, currentConnection.id],
      resumeGate: resumeGate,
      gatedResumeConnectionId: deferredConnection.id
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    _ = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(
          connection: deferredConnection,
          suffix: "deferred",
          receivedAt: 200
        ),
        mailShellBulkActionBatch(
          connection: currentConnection,
          suffix: "current",
          receivedAt: 100
        ),
      ],
      deferredPendingActionConnectionIds: [deferredConnection.id]
    )
    await fulfillment(of: [resumeStarted], timeout: 1)
    await service.acknowledgePendingActionFailures(
      connection: currentConnection,
      session: session
    )
    await resumeGate.release()

    let deferredErrorSurfaced = expectation(description: "deferred error surfaced")
    Task { @MainActor in
      while viewModel.errorMessage?.contains("deferred@example.com") != true {
        await Task.yield()
      }
      deferredErrorSurfaced.fulfill()
    }
    await fulfillment(of: [deferredErrorSurfaced], timeout: 1)
    XCTAssertFalse(viewModel.errorMessage?.contains("current@example.com") ?? true)
  }

  func testMailActionViewModelAggregatesOverlappingDeferredOperations() async {
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
    let resumeStarted = expectation(description: "pending actions resume")
    resumeStarted.expectedFulfillmentCount = 2
    let resumeGate = AdapterLifecycleOperationGate()
    let service = DeferredBulkResumeService(
      resumeStarted: resumeStarted,
      resumeError: "The provider connection failed.",
      failedConnectionIds: [firstConnection.id, secondConnection.id],
      resumeGate: resumeGate
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    _ = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(connection: firstConnection, suffix: "first", receivedAt: 200)
      ],
      deferredPendingActionConnectionIds: [firstConnection.id]
    )
    _ = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(connection: secondConnection, suffix: "second", receivedAt: 100)
      ],
      deferredPendingActionConnectionIds: [secondConnection.id]
    )
    await fulfillment(of: [resumeStarted], timeout: 1)
    await resumeGate.release()

    let errorsSurfaced = expectation(description: "overlapping errors surfaced")
    Task { @MainActor in
      while viewModel.errorMessage?.contains("first@example.com") != true
        || viewModel.errorMessage?.contains("second@example.com") != true
      {
        await Task.yield()
      }
      errorsSurfaced.fulfill()
    }
    await fulfillment(of: [errorsSurfaced], timeout: 1)
  }

  // swiftlint:disable:next function_body_length
  func testMailActionViewModelPreservesNewerInlineFailureAfterDeferredCompletion() async {
    let deferredConnection = mailShellConnection(
      emailAddress: "deferred@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let currentConnection = mailShellConnection(
      emailAddress: "current@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let resumesStarted = expectation(description: "pending actions resume")
    resumesStarted.expectedFulfillmentCount = 2
    let deferredCompletion = expectation(description: "deferred completion recorded")
    let resumeGate = AdapterLifecycleOperationGate()
    let service = DeferredBulkResumeService(
      resumeStarted: resumesStarted,
      resumeError: "The provider connection failed.",
      resumeErrorConnectionId: currentConnection.id,
      failedConnectionId: currentConnection.id,
      resumeGate: resumeGate,
      gatedResumeConnectionId: deferredConnection.id
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    _ = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(
          connection: deferredConnection,
          suffix: "deferred",
          receivedAt: 200
        )
      ],
      deferredPendingActionConnectionIds: [deferredConnection.id],
      onDeferredCompletion: { _ in
        deferredCompletion.fulfill()
      }
    )
    let currentResult = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(
          connection: currentConnection,
          suffix: "current",
          receivedAt: 100
        )
      ]
    )

    XCTAssertEqual(currentResult?.failures.map(\.connectionId), [currentConnection.id])
    await fulfillment(of: [resumesStarted], timeout: 1)
    await resumeGate.release()
    await fulfillment(of: [deferredCompletion], timeout: 1)
    XCTAssertTrue(viewModel.errorMessage?.contains("current@example.com") ?? false)
  }

  func testMailActionViewModelReportsEachDeferredCompletionWithoutWaitingForOthers() async {
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
    let resumeStarted = expectation(description: "pending actions resume")
    resumeStarted.expectedFulfillmentCount = 2
    let firstCompleted = expectation(description: "first deferred batch completes")
    let resumeGate = AdapterLifecycleOperationGate()
    let service = DeferredBulkResumeService(
      resumeStarted: resumeStarted,
      resumeGate: resumeGate,
      gatedResumeConnectionId: secondConnection.id
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    _ = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(connection: firstConnection, suffix: "first", receivedAt: 200),
        mailShellBulkActionBatch(connection: secondConnection, suffix: "second", receivedAt: 100),
      ],
      deferredPendingActionConnectionIds: [firstConnection.id, secondConnection.id],
      onDeferredCompletion: { connection in
        if connection.id == firstConnection.id {
          firstCompleted.fulfill()
        }
      }
    )

    await fulfillment(of: [resumeStarted, firstCompleted], timeout: 1)
    await resumeGate.release()
  }

  func testMailActionViewModelCancelsDeferredResumesBeforeSignOut() async {
    let connection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let resumeStarted = expectation(description: "pending actions resume")
    let service = DeferredBulkResumeService(
      resumeStarted: resumeStarted,
      suspendsResumeUntilCancelled: true
    )
    let viewModel = GmailMailActionViewModel(
      service: service,
      session: session,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )

    _ = await viewModel.performBulk(
      .archive,
      batches: [mailShellBulkActionBatch(connection: connection, suffix: "first", receivedAt: 200)],
      deferredPendingActionConnectionIds: [connection.id]
    )
    await fulfillment(of: [resumeStarted], timeout: 1)

    await viewModel.prepareForSignOut()

    let resumeWasCancelled = await service.resumeWasCancelled()
    XCTAssertTrue(resumeWasCancelled)
  }

  func testMailActionViewModelCancelsSingleActionContinuationsBeforeSignOut() async {
    let actionStarted = expectation(description: "single action continuation started")
    let providerResumeStarted = expectation(description: "provider resume started")
    providerResumeStarted.isInverted = true
    let viewModel = GmailMailActionViewModel(
      service: ConnectionPendingActionFailureService(),
      session: session,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )

    viewModel.startPendingAction {
      actionStarted.fulfill()
      do {
        try await Task.sleep(for: .seconds(60))
      } catch {
        return
      }
      providerResumeStarted.fulfill()
    }
    await fulfillment(of: [actionStarted], timeout: 1)

    await viewModel.prepareForSignOut()

    await fulfillment(of: [providerResumeStarted], timeout: 0.1)
  }

  func testMailActionViewModelRejectsBulkTaskRegistrationAfterSignOutBegins() async {
    let operationStarted = expectation(description: "bulk task starts")
    operationStarted.isInverted = true
    let viewModel = GmailMailActionViewModel(
      service: ConnectionPendingActionFailureService(),
      session: session,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )
    await viewModel.prepareForSignOut()

    viewModel.startPendingAction {
      operationStarted.fulfill()
    }

    await fulfillment(of: [operationStarted], timeout: 0.1)
  }

  func testMailActionViewModelForwardsSingleMoveDestinationStates() async {
    let connection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let service = RecordingBulkMailActionService(
      failingConnectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .gmail,
          value: "other-account"
        )
      )
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)
    let message = mailShellMessage(
      connectionId: connection.id,
      providerMessageId: "message-first",
      providerThreadId: "thread-first",
      receivedAt: 200
    )

    let didPerform = await viewModel.perform(
      .move,
      targetProviderMailboxId: "provider-mailbox:deleted-child",
      targetProviderStateIds: ["TRASH"],
      for: [message],
      connection: connection
    )

    XCTAssertTrue(didPerform)
    let targetProviderStateIds = await service.recordedTargetProviderStateIds()
    XCTAssertEqual(targetProviderStateIds, [["TRASH"]])
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
  ).mailboxConnection(productAccountId: productAccountId, authorizationState: .authorized)
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
private final class MessageBodyClearSignal: ObservableObject {
  @Published var value = UUID()
}

private struct ClearableMessageBodyHarness: View {
  @ObservedObject var clearSignal: MessageBodyClearSignal
  let onLoaded: () -> Void
  let load: () async throws -> MailboxMessageBody

  var body: some View {
    MailShellMessageBody(
      clearSignal: clearSignal.value,
      onLoaded: onLoaded,
      load: load
    )
  }
}

@MainActor
private final class GatedMessageBodyLoader {
  private var continuation: CheckedContinuation<MailboxMessageBody, Never>?
  private let started: XCTestExpectation

  init(started: XCTestExpectation) {
    self.started = started
  }

  func load() async -> MailboxMessageBody {
    started.fulfill()
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func resume() {
    continuation?.resume(returning: MailboxMessageBody(text: "Private body"))
    continuation = nil
  }
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
  var completeConnectionCallCount = 0
  var authorizationRequiredIdentifiers: Set<String> = []
  var clearedConnection: GmailProviderConnectionStatus?
  var clearErrors: [Error] = []
  var clearedProviderAccountIdentifiers: [String] = []
  var clearConnectionError: Error?
  var loadError: Error?
  var loadConnectionsCallCount = 0
  var migrationPolicies: [GmailCredentialMigrationPolicy] = []
  var loadStoredConnectionError: Error?
  var loadStoredConnectionsError: Error?
  var locallyAuthorizedIdentifiers: Set<String> = []
  var cleanupStatuses = [RecordingAdapterConnectionService.status]
  var hideStatusOnClearFailure = false
  var statuses = [RecordingAdapterConnectionService.status]
  private let completionGate: AdapterLifecycleOperationGate?
  private let clearGate: AdapterLifecycleOperationGate?
  private let lifecycleEventLog: AdapterLifecycleEventLog?
  private let loadGate: AdapterLifecycleOperationGate?

  init(
    lifecycleEventLog: AdapterLifecycleEventLog? = nil,
    completionGate: AdapterLifecycleOperationGate? = nil,
    clearGate: AdapterLifecycleOperationGate? = nil,
    loadGate: AdapterLifecycleOperationGate? = nil
  ) {
    self.lifecycleEventLog = lifecycleEventLog
    self.completionGate = completionGate
    self.clearGate = clearGate
    self.loadGate = loadGate
  }

  func clearLocalConnection(session _: ProductAccountSessionSnapshot) async throws {
    await lifecycleEventLog?.record("local-state-cleared")
    statuses.removeAll()
    cleanupStatuses.removeAll()
  }

  func clearLocalConnection(
    _ connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    if let clearGate {
      await clearGate.waitForRelease()
    }
    await lifecycleEventLog?.record("local-state-cleared")
    clearedConnection = connection
    clearedProviderAccountIdentifiers.append(connection.providerAccountIdentifier)
    if let clearConnectionError {
      throw clearConnectionError
    }
    if !clearErrors.isEmpty {
      if hideStatusOnClearFailure {
        statuses.removeAll {
          $0.providerAccountIdentifier == connection.providerAccountIdentifier
        }
      }
      throw clearErrors.removeFirst()
    }
    statuses.removeAll {
      $0.providerAccountIdentifier == connection.providerAccountIdentifier
    }
    locallyAuthorizedIdentifiers.remove(connection.providerAccountIdentifier)
    cleanupStatuses.removeAll {
      $0.providerAccountIdentifier == connection.providerAccountIdentifier
    }
  }

  func completeConnection(
    verifiedAccount: VerifiedGmailAccount,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus {
    if let completionGate {
      await completionGate.waitForRelease()
    }
    completedAccount = verifiedAccount
    completeConnectionCallCount += 1
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
    await lifecycleEventLog?.record("connection-completed")
    cleanupStatuses.removeAll {
      $0.providerAccountIdentifier == status.providerAccountIdentifier
    }
    cleanupStatuses.append(status)
    return status
  }

  func loadConnections(
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailProviderConnectionStatus] {
    loadConnectionsCallCount += 1
    if let loadError { throw loadError }
    if let loadGate {
      await loadGate.waitForRelease()
      await lifecycleEventLog?.record("connection-load-finished")
    }
    return statuses
  }

  func loadConnections(
    migrationPolicy: GmailCredentialMigrationPolicy,
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailProviderConnectionStatus] {
    migrationPolicies.append(migrationPolicy)
    return try await loadConnections(session: session)
  }

  func loadStoredConnections(
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailProviderConnectionStatus] {
    if let loadError { throw loadError }
    if let loadStoredConnectionsError { throw loadStoredConnectionsError }
    return statuses
  }

  func loadStoredConnection(
    providerAccountIdentifier: String,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus? {
    if let loadStoredConnectionError { throw loadStoredConnectionError }
    return statuses.first {
      $0.providerAccountIdentifier == providerAccountIdentifier
    }
  }

  func bindAuthorizationGeneration(
    _ authorizationGeneration: Int,
    to connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) throws -> GmailProviderConnectionStatus {
    let boundConnection = connection.withAuthorizationGeneration(authorizationGeneration)
    statuses.removeAll {
      $0.providerAccountIdentifier == boundConnection.providerAccountIdentifier
    }
    statuses.append(boundConnection)
    return boundConnection
  }

  func hasLocalAuthorization(
    providerAccountIdentifier: String,
    session _: ProductAccountSessionSnapshot
  ) throws -> Bool {
    locallyAuthorizedIdentifiers.contains(providerAccountIdentifier)
      || statuses.contains {
        $0.providerAccountIdentifier == providerAccountIdentifier
          && !authorizationRequiredIdentifiers.contains(providerAccountIdentifier)
      }
  }

  func hasLocalAuthorization(
    _ connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) throws -> Bool {
    !authorizationRequiredIdentifiers.contains(connection.providerAccountIdentifier)
  }

  func loadConnectionForCleanup(
    providerAccountIdentifier: String,
    session _: ProductAccountSessionSnapshot
  ) throws -> GmailProviderConnectionStatus? {
    cleanupStatuses.first {
      $0.providerAccountIdentifier == providerAccountIdentifier
    }
  }
}

private final class RecordingAdapterDefinitionSyncService: MailboxConnectionDefinitionSyncing {
  var completedCleanupGenerations: [MailboxConnectionId: Int] = [:]
  var loadError: Error?
  var recreateDefinitionCount = 0
  var recreateError: Error?
  var recreatedDefinition: MailboxConnectionDefinition?
  var recreationObservation: MailboxConnectionRemovalObservation?
  var removedConnectionIds: [MailboxConnectionId] = []
  var removeError: Error?
  var saveError: Error?
  var snapshotAfterSave: MailboxConnectionSyncSnapshot?
  private let reconcileGate: AdapterLifecycleOperationGate?
  private let removeGate: AdapterLifecycleOperationGate?
  private var snapshot: MailboxConnectionSyncSnapshot

  init(
    snapshot: MailboxConnectionSyncSnapshot,
    reconcileGate: AdapterLifecycleOperationGate? = nil,
    removeGate: AdapterLifecycleOperationGate? = nil
  ) {
    self.snapshot = snapshot
    self.reconcileGate = reconcileGate
    self.removeGate = removeGate
  }

  func loadSnapshot(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    if let loadError { throw loadError }
    return snapshot
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
    let reconciledSnapshot = snapshot
    if let reconcileGate {
      await reconcileGate.waitForRelease()
    }
    return reconciledSnapshot
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
    await removeGate?.waitForRelease()
    return snapshot
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
    if let saveError { throw saveError }
    if let snapshotAfterSave {
      snapshot = snapshotAfterSave
      return snapshot
    }
    let existingGeneration =
      snapshot.connections.first(where: { $0.id == definition.id })?
      .authorizationGeneration
      ?? definition.authorizationGeneration
    let retainedDefinition = definition.withAuthorizationGeneration(
      max(existingGeneration, definition.authorizationGeneration)
    )
    snapshot = MailboxConnectionSyncSnapshot(
      connections: snapshot.connections.filter { $0.id != definition.id } + [retainedDefinition],
      defaultSendingConnectionId: snapshot.defaultSendingConnectionId,
      removedConnectionIds: snapshot.removedConnectionIds.filter { $0 != definition.id },
      updatedAt: snapshot.updatedAt,
      authorizationCleanupConnectionIds: snapshot.authorizationCleanupConnectionIds,
      localCleanupGenerations: snapshot.localCleanupGenerations
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
  private let historicalBackfillGate: AdapterLifecycleOperationGate?
  private let loadGate: AdapterLifecycleOperationGate?
  var inboxProjectionCandidateMessageIds: Set<String> = []
  var loadedConnection: GmailProviderConnectionStatus?
  var loadedCollections: [MailboxMessageCollection] = []
  var inboxSyncResult = RecordingAdapterMetadataService.defaultResult
  var recentSyncResult = RecordingAdapterMetadataService.defaultResult
  var providerDelayNanoseconds: UInt64 = 0
  var syncedConnection: GmailProviderConnectionStatus?
  var syncedProviderAccountIdentifiers: [String] = []

  init(
    eventLog: RecordingAdapterEventLog? = nil,
    historicalBackfillGate: AdapterLifecycleOperationGate? = nil,
    loadGate: AdapterLifecycleOperationGate? = nil
  ) {
    self.eventLog = eventLog
    self.historicalBackfillGate = historicalBackfillGate
    self.loadGate = loadGate
  }

  func categorizeHistorical(
    scope _: GmailHistoricalCategorizationScope,
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    inboxSyncResult
  }

  func loadInbox(
    connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    loadedConnection = connection
    return inboxSyncResult
  }

  func loadInboxProjectionCandidates(
    additionalProviderMessageIds: Set<String>,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    inboxProjectionCandidateMessageIds = additionalProviderMessageIds
    return try await loadMailbox(.role(.inbox), connection: connection, session: session)
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
    await loadGate?.waitForRelease()
    return
      collection == .allObserved
      ? inboxSyncResult : inboxSyncResult.projected(to: collection)
  }

  func continueHistoricalBackfill(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    await historicalBackfillGate?.waitForRelease()
    return inboxSyncResult
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
    return inboxSyncResult
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

  private static let defaultResult = GmailMetadataSyncResult(
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

private final class DelayedAdapterProviderReadService:
  GmailMessageMetadataSyncing, GmailMessageSearching
{
  private let eventLog: AdapterLifecycleEventLog
  private let gate = AdapterLifecycleOperationGate()
  private let started: XCTestExpectation

  init(eventLog: AdapterLifecycleEventLog, started: XCTestExpectation) {
    self.eventLog = eventLog
    self.started = started
  }

  func categorizeHistorical(
    scope _: GmailHistoricalCategorizationScope,
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    started.fulfill()
    await gate.waitForRelease()
    await eventLog.record("historical-categorization-finished")
    return GmailMetadataSyncResult(messages: [], threads: [])
  }

  func loadInbox(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    GmailMetadataSyncResult(messages: [], threads: [])
  }

  func loadProviderMailboxes(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [ProviderMailbox] {
    started.fulfill()
    await gate.waitForRelease()
    await eventLog.record("provider-mailboxes-loaded")
    return []
  }

  func searchProvider(
    query: String,
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    started.fulfill()
    await gate.waitForRelease()
    await eventLog.record(
      query.hasPrefix("in:sent ") ? "delivery-status-loaded" : "provider-search-finished"
    )
    return []
  }

  func syncInbox(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    GmailMetadataSyncResult(messages: [], threads: [])
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
    GmailMetadataSyncResult(messages: [], threads: [])
  }

  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    started.fulfill()
    await gate.waitForRelease()
    await eventLog.record("category-overridden")
    return message.assigningCategory(categoryId)
  }

  func release() async {
    await gate.release()
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

private actor AdapterLifecycleEventLog {
  private var events: [String] = []

  func record(_ event: String) {
    events.append(event)
  }

  func snapshot() -> [String] {
    events
  }
}

private actor AdapterLifecycleOperationGate {
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
    await withCheckedContinuation { continuation in
      releaseContinuations.append(continuation)
    }
  }

  func waitUntilStarted() async {
    guard !hasStarted else { return }
    await withCheckedContinuation { continuation in
      startContinuations.append(continuation)
    }
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

private final class DelayedAdapterMessageReader: GmailMessageReading {
  private let eventLog: AdapterLifecycleEventLog
  private let gate = AdapterLifecycleOperationGate()

  init(eventLog: AdapterLifecycleEventLog) {
    self.eventLog = eventLog
  }

  func clearCachedMessageBodies(session _: ProductAccountSessionSnapshot) throws {}

  func clearCachedMessageBodies(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) throws {}

  func loadMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageBody {
    await gate.waitForRelease()
    await eventLog.record("body-cache-saved")
    return GmailMessageBody(text: "Decrypted body")
  }

  func prefetchMessageBodies(
    connection _: GmailProviderConnectionStatus,
    pinnedMessageIds _: Set<String>,
    referenceDate _: Date,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    await gate.waitForRelease()
    await eventLog.record("body-cache-saved")
  }

  func removeCachedMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws {}

  func waitUntilStarted() async {
    await gate.waitUntilStarted()
  }

  func release() async {
    await gate.release()
  }
}

private final class DelayedAdapterPrefetchReader: GmailMessageReading {
  private let eventLog: AdapterLifecycleEventLog
  private let prefetchGate = AdapterLifecycleOperationGate()

  init(eventLog: AdapterLifecycleEventLog) {
    self.eventLog = eventLog
  }

  func clearCachedMessageBodies(session _: ProductAccountSessionSnapshot) throws {}

  func clearCachedMessageBodies(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) throws {}

  func loadMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageBody {
    await eventLog.record("foreground-body-loaded")
    return GmailMessageBody(text: "Decrypted body")
  }

  func prefetchMessageBodies(
    connection _: GmailProviderConnectionStatus,
    pinnedMessageIds _: Set<String>,
    referenceDate _: Date,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    await prefetchGate.waitForRelease()
    await eventLog.record("prefetch-finished")
  }

  func removeCachedMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws {}

  func waitUntilPrefetchStarted() async {
    await prefetchGate.waitUntilStarted()
  }

  func releasePrefetch() async {
    await prefetchGate.release()
  }
}

private final class DelayedAdapterPushService: GmailPushWatchRegistering {
  private let eventLog: AdapterLifecycleEventLog
  private let gate = AdapterLifecycleOperationGate()

  init(eventLog: AdapterLifecycleEventLog) {
    self.eventLog = eventLog
  }

  func registerOrRenew(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailPushWatchStatus {
    await gate.waitForRelease()
    await eventLog.record("push-state-saved")
    return GmailPushWatchStatus(expirationMilliseconds: 100, historyId: "10")
  }

  func waitUntilStarted() async {
    await gate.waitUntilStarted()
  }

  func release() async {
    await gate.release()
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

private final class DelayedAdapterMailActionService: GmailProviderMailActing {
  private let eventLog: AdapterLifecycleEventLog
  private let gate = AdapterLifecycleOperationGate()

  init(eventLog: AdapterLifecycleEventLog) {
    self.eventLog = eventLog
  }

  func perform(
    _: GmailProviderMailAction,
    messageIds _: [String],
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    await gate.waitForRelease()
    await eventLog.record("provider-action-finished")
  }

  func send(
    _: GmailOutgoingMessage,
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    await gate.waitForRelease()
    await eventLog.record("message-sent")
  }

  func waitUntilStarted() async {
    await gate.waitUntilStarted()
  }

  func release() async {
    await gate.release()
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
  var saveError: Error?
  private(set) var saveCallCount = 0

  func load(productAccountId: String) throws -> [PendingProviderAction] {
    actions.filter { $0.productAccountId == productAccountId }
  }

  func save(
    _ actions: [PendingProviderAction],
    productAccountId: String
  ) throws {
    saveCallCount += 1
    if let saveError { throw saveError }
    self.actions.removeAll { $0.productAccountId == productAccountId }
    self.actions += actions
  }
}

private final class BlockingAdapterPendingActionStore: PendingProviderActionPersisting {
  private var actions: [PendingProviderAction] = []
  private var hasBlockedSave = false
  private let releaseSemaphore = DispatchSemaphore(value: 0)
  private let saveStarted: XCTestExpectation

  init(saveStarted: XCTestExpectation) {
    self.saveStarted = saveStarted
  }

  func load(productAccountId: String) throws -> [PendingProviderAction] {
    actions.filter { $0.productAccountId == productAccountId }
  }

  func save(
    _ actions: [PendingProviderAction],
    productAccountId _: String
  ) throws {
    if !hasBlockedSave {
      hasBlockedSave = true
      saveStarted.fulfill()
      releaseSemaphore.wait()
    }
    self.actions = actions
  }

  func release() {
    releaseSemaphore.signal()
  }
}

private final class AdapterOutboxStore: OutboxDeliveryPersisting, @unchecked Sendable {
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
  private var targetProviderStateIds: [Set<String>] = []

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

  // swiftlint:disable:next function_parameter_count
  func perform(
    _: ProviderMailAction,
    targetProviderMailboxId _: String?,
    targetProviderStateIds: Set<String>,
    messages _: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    connectionIds.append(connection.id)
    self.targetProviderStateIds.append(targetProviderStateIds)
    if connection.id == failingConnectionId {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
  }

  func recordedConnectionIds() -> [MailboxConnectionId] {
    connectionIds
  }

  func recordedTargetProviderStateIds() -> [Set<String>] {
    targetProviderStateIds
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

private actor DeferredBulkResumeService: MailboxProviderMailActing {
  private let blockedConnectionIds: Set<MailboxConnectionId>
  private var failedConnectionIds: Set<MailboxConnectionId>
  private let gatedResumeConnectionId: MailboxConnectionId?
  private let performFailureConnectionId: MailboxConnectionId?
  private var recordedResumeCount = 0
  private let resumeGate: AdapterLifecycleOperationGate?
  private let resumeError: String?
  private let resumeErrorConnectionId: MailboxConnectionId?
  private let resumeStarted: XCTestExpectation
  private var recordedResumeWasCancelled = false
  private let suspendsResumeUntilCancelled: Bool

  init(
    resumeStarted: XCTestExpectation,
    resumeError: String? = nil,
    resumeErrorConnectionId: MailboxConnectionId? = nil,
    failedConnectionId: MailboxConnectionId? = nil,
    failedConnectionIds: Set<MailboxConnectionId> = [],
    blockedConnectionIds: Set<MailboxConnectionId> = [],
    performFailureConnectionId: MailboxConnectionId? = nil,
    resumeGate: AdapterLifecycleOperationGate? = nil,
    gatedResumeConnectionId: MailboxConnectionId? = nil,
    suspendsResumeUntilCancelled: Bool = false
  ) {
    self.blockedConnectionIds = blockedConnectionIds
    self.failedConnectionIds = failedConnectionIds
    if let failedConnectionId {
      self.failedConnectionIds.insert(failedConnectionId)
    }
    self.gatedResumeConnectionId = gatedResumeConnectionId
    self.performFailureConnectionId = performFailureConnectionId
    self.resumeGate = resumeGate
    self.resumeError = resumeError
    self.resumeErrorConnectionId = resumeErrorConnectionId
    self.resumeStarted = resumeStarted
    self.suspendsResumeUntilCancelled = suspendsResumeUntilCancelled
  }

  func perform(
    _: ProviderMailAction,
    messages _: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    if connection.id == performFailureConnectionId {
      throw AdapterTestError.unavailable
    }
  }

  func resumePendingActions(
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async -> String? {
    recordedResumeCount += 1
    resumeStarted.fulfill()
    if gatedResumeConnectionId == nil || gatedResumeConnectionId == connection.id {
      await resumeGate?.waitForRelease()
    }
    if suspendsResumeUntilCancelled {
      do {
        try await Task.sleep(for: .seconds(60))
      } catch {
        recordedResumeWasCancelled = true
        return nil
      }
    }
    return resumeErrorConnectionId == nil || resumeErrorConnectionId == connection.id
      ? resumeError : nil
  }

  func failedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session _: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    return connections.map(\.id).filter { failedConnectionIds.contains($0) }
  }

  func blockedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session _: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    connections.map(\.id).filter { blockedConnectionIds.contains($0) }
  }

  func acknowledgePendingActionFailures(
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async {
    failedConnectionIds.remove(connection.id)
  }

  func resumeCount() -> Int {
    recordedResumeCount
  }

  func resumeWasCancelled() -> Bool {
    recordedResumeWasCancelled
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
