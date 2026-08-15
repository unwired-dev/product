import Foundation
import QuartzCore
import SwiftData
import SwiftUI
import Testing
import UIKit

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

private final class MailboxAdapterURLStub: URLProtocolStub {}

private let gmailAdapterMessageBody = MailboxMessageBody(
  text: "Decrypted body",
  html: "<p>Decrypted body</p>"
)

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

private let adapterOutgoingMessage = OutgoingMessage(
  body: "Queued private body",
  recipient: "reader@example.com",
  subject: "Queued message"
)

private let adapterOtherOutgoingMessage = OutgoingMessage(
  body: "Other queued private body",
  recipient: "other-reader@example.com",
  subject: "Other queued message"
)

@MainActor
@Suite(.serialized)
final class MailboxConnectionAdapterTests {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "product-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  @Test
  func testRawMessageSourcePreservesBytesAndParsesFoldedDuplicateHeaders() throws {
    let data = Data(
      "Subject: First\r\nReceived: one\r\nReceived: two\r\nX-Long: first\r\n\tsecond\r\n\r\nBody\u{0}"
        .utf8
    )

    let source = try MailboxMessageSource.exact(data)

    #expect(source.raw == .exact(data))
    #expect(source.headersAreExact)
    #expect(
      source.headers
        == [
          .init(name: "Subject", value: "First"),
          .init(name: "Received", value: "one"),
          .init(name: "Received", value: "two"),
          .init(name: "X-Long", value: "first second"),
        ])
    #expect(
      MailboxMessageSourceParser.headers(in: Data("Subject: LF\n\nBody: not-a-header".utf8))
        == [.init(name: "Subject", value: "LF")]
    )
    #expect(
      MailboxMessageSourceParser.headers(in: Data("\tleading\r\nSubject: Valid".utf8))
        == [.init(name: "Subject", value: "Valid")]
    )
    #expect(
      MailboxMessageSourceParser.headers(in: Data("Subject: No separator".utf8))
        == [.init(name: "Subject", value: "No separator")]
    )
    #expect(throws: MailboxMessageSourceError.exceedsSizeLimit) {
      try MailboxMessageSource.exact(
        Data(count: MailboxMessageSourcePolicy.maximumByteCount + 1)
      )
    }
  }

  @Test
  func testRawMessageSourceParserBoundsHeaderPresentation() {
    let maximumHeaderByteCount = MailboxMessageSourcePolicy.maximumHeaderByteCount
    let oversizedHeader = Data(
      "Subject: \(String(repeating: "a", count: maximumHeaderByteCount))"
        .utf8
    )
    let manyHeaders = Data(
      (0...MailboxMessageSourcePolicy.maximumHeaderLineCount)
        .map { "X-\($0): value" }
        .joined(separator: "\r\n")
        .utf8
    )

    let boundedBytes = MailboxMessageSourceParser.headers(in: oversizedHeader)
    let boundedFields = MailboxMessageSourceParser.headers(in: manyHeaders)

    #expect(boundedBytes.count == 1)
    #expect(boundedBytes[0].value.utf8.count < maximumHeaderByteCount)
    #expect(boundedFields.count == MailboxMessageSourcePolicy.maximumHeaderLineCount)
  }

  @Test
  func testUnavailableRawMessageSourceUsesHonestMetadataFallback() {
    let source = MailboxMessageSource.unavailable(for: adapterMessage)

    #expect(!source.headersAreExact)
    #expect(source.headers.contains(.init(name: "Subject", value: adapterMessage.subject)))
    #expect(
      source.raw
        == .unavailable(
          reason: "This provider does not make exact RFC 822 bytes available."
        ))
  }

  @Test
  func testRawMessageSourceCacheEncryptsAndInvalidatesChangedRevision() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "raw-source-cache-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let bodyCache = FileGmailMessageBodyCache(rootDirectory: rootDirectory)
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let cache = MailboxMessageSourceCache(cache: bodyCache, keyMaterialStore: keyStore)
    let data = Data("Subject: Exact\r\n\r\nBody".utf8)

    try cache.save(
      data,
      stableProviderMessageId: adapterMessage.stableProviderMessageId,
      revision: "one",
      session: session
    )

    #expect(
      try cache.load(
        stableProviderMessageId: adapterMessage.stableProviderMessageId,
        revision: "one",
        session: session
      ) == data)
    let storedPayload = try requireValue(
      bodyCache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: "\(adapterMessage.stableProviderMessageId):raw-source"
      ))
    let ciphertext = try requireValue(Data(base64Encoded: storedPayload.ciphertextBase64))
    #expect(ciphertext != data)
    #expect(ciphertext.range(of: data) == nil)
    #expect(
      try cache.load(
        stableProviderMessageId: adapterMessage.stableProviderMessageId,
        revision: "two",
        session: session
      ) == nil)
  }

  @Test
  func testRawMessageSourceCachePreservesCiphertextWhenKeyRecoveryIsRequired() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "raw-source-recovery-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let bodyCache = FileGmailMessageBodyCache(rootDirectory: rootDirectory)
    let originalKeyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try originalKeyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let originalCache = MailboxMessageSourceCache(
      cache: bodyCache,
      keyMaterialStore: originalKeyStore
    )
    let unavailableCache = MailboxMessageSourceCache(
      cache: bodyCache,
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore()
    )
    #expect(throws: ProductSyncKeyMaterialStoreError.recoveryRequired) {
      try unavailableCache.load(
        stableProviderMessageId: adapterMessage.stableProviderMessageId,
        session: session
      )
    }
    let data = Data("Subject: Exact\r\n\r\nBody".utf8)
    try originalCache.save(
      data,
      stableProviderMessageId: adapterMessage.stableProviderMessageId,
      session: session
    )

    #expect(throws: ProductSyncKeyMaterialStoreError.recoveryRequired) {
      try unavailableCache.load(
        stableProviderMessageId: adapterMessage.stableProviderMessageId,
        session: session
      )
    }
    #expect(
      try originalCache.load(
        stableProviderMessageId: adapterMessage.stableProviderMessageId,
        session: session
      ) == data)
  }

  @Test
  func testSingleCategoryIdentifierAcceptsOneCategory() throws {
    #expect(try singleCategoryIdentifier(["system:invoices"]) == "system:invoices")
  }

  @Test(arguments: [[], ["system:invoices", "system:travel"]])
  func testSingleCategoryIdentifierRejectsUnsupportedCounts(_ categoryIds: [String]) {
    #expect(throws: MailboxConnectionAdapterError.unsupportedProvider) {
      try singleCategoryIdentifier(categoryIds)
    }
  }

  @Test
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

    #expect(oauthAuthorizer.authorizationCount == 1)
    #expect(credentialVerifier.accessToken == "oauth-access-token")
    #expect(credentialVerifier.refreshToken == "oauth-refresh-token")
    #expect(connectionService.completedAccount?.tokens.idToken == "oauth-id-token")
    #expect(connection?.id.rawValue == "gmail:gmail-user-001")
    #expect(connection?.productAccountId == ProductAccountId(session.productAccountId))
    #expect(definitionSyncService.recreatedDefinition?.id == connection?.id)
  }

  @Test
  func testGmailConnectDoesNotAuthorizeBeforeGenerationSnapshotLoads() async {
    let credentialVerifier = RecordingAdapterCredentialVerifier()
    let oauthAuthorizer = RecordingAdapterOAuthAuthorizer()
    let definitionSyncService = RecordingAdapterDefinitionSyncService(snapshot: .empty)
    definitionSyncService.loadError = AdapterTestError.unavailable
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: RecordingAdapterConnectionService(),
      credentialVerifier: credentialVerifier,
      definitionSyncService: definitionSyncService,
      oauthAuthorizer: oauthAuthorizer
    )

    do {
      _ = try await adapter.connect(
        session: session,
        isSessionCurrent: { $0 == self.session }
      )
      Issue.record("Expected the unavailable authorization-generation snapshot to fail")
    } catch is AdapterTestError {
      #expect(oauthAuthorizer.authorizationCount == 0)
      #expect(credentialVerifier.accessToken == nil)
      #expect(credentialVerifier.refreshToken == nil)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
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
    #expect(eventsBeforeRelease.isEmpty)

    await completionGate.release()
    _ = try await connectTask.value
    try await cleanupTask.value
    let events = await eventLog.snapshot()
    #expect(events == ["connection-completed", "local-state-cleared"])
  }

  @Test
  func testGmailConnectDoesNotRecoverUnrelatedConnections() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer()
    )

    _ = try await adapter.connect(session: session, isSessionCurrent: { $0 == self.session })

    #expect(connectionService.loadConnectionsCallCount == 0)
  }

  @Test
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

    #expect(connectionService.clearedProviderAccountIdentifiers == ["gmail-user-001"])
    #expect(connection?.authorizationGeneration == 1)
    #expect(definitionSyncService.completedCleanupGenerations[synchronized.id] == 1)
  }

  @Test
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

    #expect(connectionService.clearedProviderAccountIdentifiers == ["gmail-user-001"])
    #expect(definitionSyncService.completedCleanupGenerations[synchronized.id] == 1)
  }

  @Test
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

    #expect(connectionService.clearedProviderAccountIdentifiers == ["gmail-user-001"])
    #expect(
      connectionService.migrationPolicies == [
        GmailCredentialMigrationPolicy(
          allowsUnscopedLegacyMigration: false,
          blockedProviderAccountIdentifiers: ["gmail-user-001"]
        )
      ])
  }

  @Test
  func testGmailLoadDoesNotAdvertiseAuthorizationBeforeGenerationSnapshotLoads() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let definitionSyncService = RecordingAdapterDefinitionSyncService(snapshot: .empty)
    definitionSyncService.loadError = AdapterTestError.unavailable
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: definitionSyncService,
      oauthAuthorizer: RecordingAdapterOAuthAuthorizer(),
      syncGate: MailboxConnectionSyncGate()
    )

    let connections = try await adapter.loadConnections(session: session)

    #expect(connections.map(\.authorizationState) == [.required])
    #expect(connectionService.loadConnectionsCallCount == 0)
    #expect(connectionService.migrationPolicies.isEmpty)
  }

  @Test
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
      Issue.record("Expected synchronized definition save failure")
    } catch is AdapterTestError {
    }

    #expect(connectionService.clearedProviderAccountIdentifiers.isEmpty)
    #expect(connectionService.statuses.map(\.providerAccountIdentifier) == ["gmail-user-001"])
  }

  @Test
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

    #expect(connectionService.clearedProviderAccountIdentifiers == ["gmail-user-001"])
    #expect(connectionService.completedAccount?.tokens.accessToken == "oauth-access-token")
    #expect(connection?.authorizationGeneration == 1)
  }

  @Test
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

    #expect(connectionService.clearedProviderAccountIdentifiers == ["gmail-user-001"])
    #expect(connectionService.completeConnectionCallCount == 2)
    #expect(connection?.authorizationGeneration == cleanupGeneration)
    #expect(
      definitionSyncService.completedCleanupGenerations[staleConnection.id] == cleanupGeneration)
  }

  @Test
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
      Issue.record("Expected synchronized recreation to report the removal")
    } catch let error as MailboxConnectionSyncError {
      #expect(error == .connectionRemoved(removalObservation))
    }

    #expect(connectionService.clearedProviderAccountIdentifiers == ["gmail-user-001"])
    #expect(connectionService.statuses.isEmpty)
  }

  @Test
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
    #expect(connectionService.completedAccount == nil)

    await clearGate.release()
    try await cleanupTask.value
    _ = try await connectTask.value
    let events = await eventLog.snapshot()
    #expect(events == ["local-state-cleared", "connection-completed"])
  }

  @Test
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

    #expect(mailboxResult.messages == [adapterMessage])
    #expect(mailboxResult.threads.first?.messages.count == 2)
    #expect(mailboxResult.threads.first?.latestMessage.providerMessageId == "message-002")
  }

  @Test
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
      Issue.record("Expected Product Sync failure")
    } catch is AdapterTestError {
    }

    #expect(connectionService.clearedConnection == nil)
  }

  @Test
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
      Issue.record("Expected Product Sync failure")
    } catch is AdapterTestError {
    }

    #expect(connectionService.statuses.first?.authorizationGeneration == 2)
  }

  @Test
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
      Issue.record("Expected authorization for a different Gmail identity to be rejected")
    } catch let error as MailboxConnectionAdapterError {
      #expect(error == .unexpectedAuthorizedAccount)
      #expect(connectionService.completedAccount == nil)
    }
  }

  @Test
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

    #expect(firstDeviceBefore.first?.authorizationState == .authorized)
    #expect(secondDeviceBefore.first?.authorizationState == .required)
    #expect(firstDeviceAfter.first?.authorizationState == .authorized)
    #expect(secondDeviceAfter.first?.authorizationState == .authorized)
    #expect(firstDeviceAfter.first?.trustedDeviceId == session.trustedDeviceId)
    #expect(secondDeviceAfter.first?.trustedDeviceId == secondDeviceSession.trustedDeviceId)
  }

  @Test
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

    #expect(staleConnections.first?.authorizationState == .required)
    #expect(currentConnections.first?.authorizationState == .authorized)
    let staleOperationConnection = try requireValue(currentConnections.first)
      .withAuthorizationGeneration(0)
    do {
      _ = try await currentAdapter.syncInbox(
        connection: staleOperationConnection,
        session: session
      )
      Issue.record("Expected a stale operation generation to require authorization")
    } catch {
      #expect(error as? MailboxConnectionAdapterError == .authorizationRequired)
    }
    do {
      try await currentAdapter.perform(
        .archive,
        messages: [adapterMessage],
        connection: staleOperationConnection,
        session: session
      )
      Issue.record("Expected a stale action generation to require authorization")
    } catch {
      #expect(error as? MailboxConnectionAdapterError == .authorizationRequired)
    }
  }

  @Test
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
      Issue.record("Expected authorization to be required")
    } catch let error as MailboxConnectionAdapterError {
      #expect(error == .authorizationRequired)
    }
    #expect(bodyReader.loadedProviderAccountIdentifiers.isEmpty)
  }

  @Test
  func testViewModelFallsBackFromUnauthorizedSyncedDefaultToAuthorizedConnection() async {
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

    let authorizedConnection = localStatus.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    #expect(viewModel.selectedConnectionId == authorizedConnection.id)
    #expect(viewModel.connection?.authorizationState == .authorized)
    #expect(viewModel.connection?.id == authorizedConnection.id)
  }

  @Test
  func testViewModelUpdatesSessionAfterIdentityTokenRefresh() {
    let viewModel = MailboxProviderConnectionViewModel(
      service: GmailMailboxConnectionAdapter(),
      isSessionCurrent: { _ in true },
      session: session
    )
    let refreshedSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: session.appleUserIdentifier,
      identityToken: "refreshed-token",
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )

    viewModel.sessionSnapshot = refreshedSession

    #expect(viewModel.sessionSnapshot == refreshedSession)
  }

  @Test
  func testViewModelLoadsStoredConnectionsButRejectsProviderOperationsWhenRevalidationFails()
    async
  {
    let connectionService = RecordingAdapterConnectionService()
    let oauthAuthorizer = RecordingAdapterOAuthAuthorizer()
    let pushService = RecordingAdapterPushService()
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: RecordingAdapterCredentialVerifier(),
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      oauthAuthorizer: oauthAuthorizer,
      pushWatchService: pushService
    )
    let viewModel = MailboxProviderConnectionViewModel(
      service: adapter,
      isSessionCurrent: { _ in true },
      revalidateTrustedDevice: { false },
      session: session
    )
    let loaded = await viewModel.load()
    let connected = await viewModel.connect()
    await viewModel.renewPushWatch()

    #expect(!(loaded))
    #expect(connected == nil)
    #expect(viewModel.connections.count == 1)
    #expect(connectionService.loadStoredConnectionsCallCount == 1)
    #expect(connectionService.loadConnectionsCallCount == 0)
    #expect(oauthAuthorizer.authorizationCount == 0)
    #expect(pushService.providerAccountIdentifiers.isEmpty)
  }

  @Test
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

    #expect(
      viewModel.selectedConnectionId
        == localStatus.mailboxConnection(
          productAccountId: session.productAccountId,
          authorizationState: .authorized
        ).id)
  }

  @Test
  func testViewModelReportsSuccessfulDefaultSenderChange() async {
    let connectionService = RecordingAdapterConnectionService()
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [connection.definition],
        defaultSendingConnectionId: nil,
        removedConnectionIds: [],
        updatedAt: 1_781_200_000_300
      )
    )
    let viewModel = MailboxProviderConnectionViewModel(
      service: GmailMailboxConnectionAdapter(
        connectionService: connectionService,
        definitionSyncService: definitionSyncService
      ),
      isSessionCurrent: { $0 == self.session },
      session: session
    )
    _ = await viewModel.load()

    let didSetDefault = await viewModel.setDefaultSendingConnection(connection)

    #expect(didSetDefault)
    #expect(viewModel.defaultSendingConnectionId == connection.id)
  }

  @Test
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

    #expect(viewModel.connections.isEmpty)
    #expect(viewModel.errorMessage != nil)
  }

  @Test
  func testViewModelPreservesAuthoritativeSnapshotWhenReloadIsCancelled() async {
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
    let connectionsBeforeCancellation = viewModel.connections
    connectionService.loadError = CancellationError()

    _ = await viewModel.load()

    #expect(viewModel.connectionsSnapshotIsAuthoritative)
    #expect(viewModel.connections == connectionsBeforeCancellation)
  }

  @Test
  func testViewModelPreservesDefaultSenderWhenRefreshingItFails() async {
    let connectionService = RecordingAdapterConnectionService()
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [connection.definition],
        defaultSendingConnectionId: connection.id,
        removedConnectionIds: [],
        updatedAt: 1_781_200_000_300
      )
    )
    let viewModel = MailboxProviderConnectionViewModel(
      service: GmailMailboxConnectionAdapter(
        connectionService: connectionService,
        definitionSyncService: definitionSyncService
      ),
      isSessionCurrent: { $0 == self.session },
      session: session
    )
    _ = await viewModel.load()
    definitionSyncService.loadError = AdapterTestError.unavailable

    let refreshed = await viewModel.refreshSnapshot()

    #expect(!(refreshed))
    #expect(viewModel.defaultSendingConnectionId == connection.id)
    #expect(viewModel.errorMessage != nil)
  }

  @Test
  func testViewModelKeepsStoredConnectionsUnauthorizedWhenGenerationSnapshotFails() async {
    let connectionService = RecordingAdapterConnectionService()
    let selectedStatus = RecordingAdapterConnectionService.status
    let defaultStatus = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "zsecond@example.com",
      lastVerifiedAt: 1_781_200_000_100,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_200
    )
    let selectedConnection = selectedStatus.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let defaultConnection = defaultStatus.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    connectionService.statuses = [selectedStatus, defaultStatus]
    let definitionSyncService = RecordingAdapterDefinitionSyncService(snapshot: .empty)
    definitionSyncService.loadError = AdapterTestError.unavailable
    let viewModel = MailboxProviderConnectionViewModel(
      service: GmailMailboxConnectionAdapter(
        connectionService: connectionService,
        definitionSyncService: definitionSyncService
      ),
      isSessionCurrent: { $0 == self.session },
      session: session
    )
    viewModel.selectedConnectionId = selectedConnection.id
    viewModel.defaultSendingConnectionId = defaultConnection.id

    let loadedAuthoritatively = await viewModel.load()

    #expect(!(loadedAuthoritatively))
    #expect(viewModel.connections.map(\.id) == [selectedConnection.id, defaultConnection.id])
    #expect(viewModel.connections.map(\.authorizationState) == [.required, .required])
    #expect(viewModel.selectedConnectionId == selectedConnection.id)
    #expect(viewModel.defaultSendingConnectionId == nil)
    #expect(viewModel.errorMessage != nil)
  }

  @Test
  func testViewModelFallsBackToAvailableSelectionWhenProviderSnapshotIsPartial() async {
    let healthyConnectionService = RecordingAdapterConnectionService()
    healthyConnectionService.statuses = [RecordingAdapterConnectionService.status]
    let healthyAdapter = GmailMailboxConnectionAdapter(
      connectionService: healthyConnectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty)
    )
    let failingConnectionService = RecordingAdapterConnectionService()
    failingConnectionService.loadError = AdapterTestError.unavailable
    let failingAdapter = GmailMailboxConnectionAdapter(
      connectionService: failingConnectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty)
    )
    let emptyAdapter = GmailMailboxConnectionAdapter(
      connectionService: RecordingAdapterConnectionService(),
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty)
    )
    let viewModel = MailboxProviderConnectionViewModel(
      service: MailboxConnectionRouter(
        exchangeWebServices: emptyAdapter,
        gmail: healthyAdapter,
        imap: failingAdapter,
        microsoftGraph: emptyAdapter
      ),
      isSessionCurrent: { $0 == self.session },
      session: session
    )
    let unavailableSelection = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .microsoftGraph,
        value: "temporarily-unavailable"
      )
    )
    viewModel.selectedConnectionId = unavailableSelection

    let loadedAuthoritatively = await viewModel.load()

    #expect(!(loadedAuthoritatively))
    #expect(!(viewModel.connections.isEmpty))
    #expect(
      viewModel.selectedConnectionId
        == healthyConnectionService.statuses.first?.mailboxConnection(
          productAccountId: session.productAccountId,
          authorizationState: .authorized
        ).id
    )
    #expect(viewModel.errorMessage != nil)
  }

  @Test
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

    #expect(firstAttempt == nil)
    #expect(viewModel.isConfirmingRecreation)
    #expect(definitionSyncService.recreateDefinitionCount == 1)
    #expect(definitionSyncService.recreationObservation == nil)

    definitionSyncService.recreateError = nil
    let recreated = await viewModel.connect()

    #expect(recreated?.id == adapterConnectionId)
    #expect(definitionSyncService.recreationObservation == removalObservation)
    #expect(!(viewModel.isConfirmingRecreation))
  }

  @Test
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

    #expect(!(viewModel.isConfirmingRecreation))
    definitionSyncService.recreateError = nil
    _ = await viewModel.connect()
    #expect(definitionSyncService.recreationObservation == nil)
  }

  @Test
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
    #expect(!(viewModel.connections.contains { $0.id == refreshedConnectionId }))

    let refreshed = await viewModel.refreshSnapshot()

    #expect(refreshed)
    #expect(viewModel.connections.contains { $0.id == refreshedConnectionId })
  }

  @Test
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

    #expect(connections.map(\.id.rawValue) == ["gmail:gmail-user-001", "gmail:gmail-user-002"])
    #expect(connectionService.clearedConnection?.providerAccountIdentifier == "gmail-user-001")
  }

  @Test
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

    #expect(connections.map(\.id) == [adapterConnectionId])
    #expect(connections[0].authorizationState == .required)
    #expect(!(connections[0].capabilities.canReadMessages))
    #expect(!(connections[0].capabilities.canSend))
    #expect(defaultSendingConnectionId == adapterConnectionId)
  }

  @Test
  func testGmailAdapterRestrictsTokenlessDeviceConnectionUntilReauthorized() async throws {
    let connectionService = RecordingAdapterConnectionService()
    connectionService.authorizationRequiredIdentifiers = ["gmail-user-001"]
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty)
    )

    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)

    #expect(connections.map(\.id) == [adapterConnectionId])
    #expect(connection.authorizationState == .required)
    #expect(connection.capabilities == .none)
  }

  @Test
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
    let connection = try requireValue(connections.first)

    try await adapter.clearLocalConnection(connection, session: session)

    #expect(connectionService.clearedConnection?.providerAccountIdentifier == "gmail-user-001")
    #expect(definitionSyncService.removedConnectionIds.isEmpty)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testGmailAdapterRemovesConnectionEverywhereAfterLocalCleanup() async throws {
    let connectionService = RecordingAdapterConnectionService()
    let outboxStore = AdapterOutboxStore()
    let outboxService = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: outboxStore
    )
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
      outboxService: outboxService
    )
    let connections = try await adapter.loadConnections(session: session)
    let connection = try requireValue(connections.first)
    let otherConnection = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: "other@example.com",
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: connection.updatedAt
    ).mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    _ = try await outboxService.enqueue(
      adapterOutgoingMessage,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    _ = try await outboxService.enqueue(
      adapterOtherOutgoingMessage,
      connection: otherConnection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )

    try await adapter.removeMailboxConnectionEverywhere(connection, session: session)

    let remainingAttempts = try await outboxService.items(session: session)
    #expect(connectionService.clearedConnection?.providerAccountIdentifier == "gmail-user-001")
    #expect(definitionSyncService.removedConnectionIds == [connection.id])
    #expect(remainingAttempts.map(\.connectionId) == [otherConnection.id])

    try await outboxService.clear(session: session)
  }

  @Test
  func testGmailRemovalReportsOutboxCleanupFailureBeforeClearingAuthorization() async throws {
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let connectionService = RecordingAdapterConnectionService()
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: [connection.definition],
        defaultSendingConnectionId: connection.id,
        removedConnectionIds: [],
        updatedAt: connection.updatedAt
      )
    )
    let outboxStore = AdapterOutboxStore()
    let outboxService = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: outboxStore
    )
    _ = try await outboxService.enqueue(
      adapterOutgoingMessage,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    outboxStore.saveError = AdapterTestError.unavailable
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      definitionSyncService: definitionSyncService,
      outboxService: outboxService
    )

    do {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
      Issue.record("Expected Outbox cleanup failure")
    } catch is AdapterTestError {
    }

    let retainedConnectionIds = try await outboxService.items(session: session)
      .map(\.connectionId)
    #expect(connectionService.clearedConnection == nil)
    #expect(definitionSyncService.removedConnectionIds == [connection.id])
    #expect(retainedConnectionIds == [connection.id])

    outboxStore.saveError = nil
    try await adapter.removeMailboxConnectionEverywhere(connection, session: session)

    #expect(connectionService.clearedConnection?.providerAccountIdentifier == "gmail-user-001")
    let remainingAttempts = try await outboxService.items(session: session)
    #expect(remainingAttempts.isEmpty)
  }

  @Test
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
    let connection = try requireValue(connections.first)

    try await adapter.removeMailboxConnectionEverywhere(connection, session: session)

    #expect(connection.authorizationState == .required)
    #expect(connection.capabilities == .none)
    #expect(connectionService.clearedConnection?.providerAccountIdentifier == "gmail-user-001")
    #expect(definitionSyncService.removedConnectionIds == [connection.id])
  }

  @Test
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
      Issue.record("Expected Product Sync failure")
    } catch is AdapterTestError {
    }

    #expect(connectionService.clearedConnection == nil)
  }

  @Test
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
      Issue.record("Expected local cleanup failure")
    } catch is AdapterTestError {
    }

    #expect(definitionSyncService.removedConnectionIds == [connection.id])
    #expect(connectionService.statuses.isEmpty)
    #expect(connectionService.cleanupStatuses == [RecordingAdapterConnectionService.status])

    let connections = try await adapter.loadConnections(session: session)

    #expect(connections.isEmpty)
    #expect(connectionService.statuses.isEmpty)
    #expect(connectionService.cleanupStatuses.isEmpty)
    #expect(
      connectionService.clearedProviderAccountIdentifiers == ["gmail-user-001", "gmail-user-001"])
  }

  @Test
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

    #expect(connections.isEmpty)
    #expect(connectionService.clearedProviderAccountIdentifiers.isEmpty)
    #expect(connectionService.cleanupStatuses == [RecordingAdapterConnectionService.status])
  }

  @Test
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

    #expect(connections.isEmpty)
    #expect(connectionService.clearedConnection?.providerAccountIdentifier == "gmail-user-001")
  }

  @Test
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
      Issue.record("Expected synchronized removal to fence provider access")
    } catch let error as MailboxConnectionAdapterError {
      #expect(error == .connectionRemoved)
      #expect(metadataService.syncedConnection == nil)
      #expect(connectionService.clearedConnection?.providerAccountIdentifier == "gmail-user-001")
    }
  }

  @Test
  func testGmailAdapterAppliesCompleteCategoryMembershipSet() async throws {
    let metadataService = RecordingAdapterMetadataService()
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: RecordingAdapterConnectionService(),
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      metadataService: metadataService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )

    let updated = try await adapter.setCategories(
      ["system:invoices", "system:flights", "system:invoices"],
      for: adapterMessage,
      session: session
    )

    #expect(
      metadataService.setCategoryIds
        == ["system:invoices", "system:flights", "system:invoices"]
    )
    #expect(updated.messageCategoryIds == ["system:flights", "system:invoices"])
  }

  @Test
  func testCategoryApplyUpdatesReaderMetadataBeforeEncryptedSyncCompletes() async throws {
    let updateStarted = expectation(description: "category update starts")
    let metadataService = DelayedAdapterProviderReadService(
      eventLog: AdapterLifecycleEventLog(),
      started: updateStarted
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: RecordingAdapterConnectionService(),
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      metadataService: metadataService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )
    let viewModel = GmailInboxViewModel(
      service: adapter,
      searchService: adapter,
      session: session
    )
    viewModel.threads = MailboxThread.group([adapterMessage])

    let applyTask = Task {
      await viewModel.setCategories(
        ["system:flights", "system:invoices"],
        for: adapterMessage
      )
    }
    await fulfillment(of: [updateStarted], timeout: 1)

    #expect(
      viewModel.threads.flatMap(\.messages).first?.messageCategoryIds
        == ["system:flights", "system:invoices"]
    )

    await metadataService.release()
    await applyTask.value
    #expect(viewModel.categoryOverrideErrorMessage == nil)
  }

  @Test
  func testCategoryApplyFailureRollsBackOnlyCategoryMemberships() async throws {
    let updateStarted = expectation(description: "category update starts")
    let metadataService = DelayedAdapterProviderReadService(
      eventLog: AdapterLifecycleEventLog(),
      started: updateStarted,
      failsCategorySet: true
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: RecordingAdapterConnectionService(),
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      metadataService: metadataService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )
    let viewModel = GmailInboxViewModel(service: adapter, searchService: adapter, session: session)
    viewModel.threads = MailboxThread.group([adapterMessage])

    let applyTask = Task {
      await viewModel.setCategories(["system:invoices"], for: adapterMessage)
    }
    await fulfillment(of: [updateStarted], timeout: 1)
    await metadataService.release()
    await applyTask.value

    #expect(
      viewModel.threads.flatMap(\.messages).first?.messageCategoryIds
        == adapterMessage.messageCategoryIds
    )
    #expect(viewModel.categoryOverrideErrorMessage != nil)
  }

  @Test
  func testCancelledCategoryApplyRollsBackWithoutReportingFailure() async throws {
    let updateStarted = expectation(description: "category update starts")
    let metadataService = DelayedAdapterProviderReadService(
      eventLog: AdapterLifecycleEventLog(),
      started: updateStarted
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: RecordingAdapterConnectionService(),
      definitionSyncService: RecordingAdapterDefinitionSyncService(
        snapshot: MailboxConnectionSyncSnapshot(
          connections: [connection.definition],
          defaultSendingConnectionId: nil,
          removedConnectionIds: [],
          updatedAt: connection.updatedAt
        )
      ),
      metadataService: metadataService,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )
    let viewModel = GmailInboxViewModel(service: adapter, searchService: adapter, session: session)
    viewModel.threads = MailboxThread.group([adapterMessage])

    let applyTask = Task {
      await viewModel.setCategories(["system:invoices"], for: adapterMessage)
    }
    await fulfillment(of: [updateStarted], timeout: 1)
    applyTask.cancel()
    await metadataService.release()
    await applyTask.value

    #expect(
      viewModel.threads.flatMap(\.messages).first?.messageCategoryIds
        == adapterMessage.messageCategoryIds
    )
    #expect(viewModel.categoryOverrideErrorMessage == nil)
  }

  @Test
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
      Issue.record("Expected synchronized removal to fence send")
    } catch let error as MailboxConnectionAdapterError {
      #expect(error == .connectionRemoved)
    }
    #expect(mailActionService.outgoingMessage == nil)
    #expect(connectionService.clearedConnection?.providerAccountIdentifier == "gmail-user-001")
    #expect(pendingActionStore.saveCallCount == 1)
    #expect(outboxStore.saveCallCount == 1)
  }

  @Test
  func testGmailTombstoneCleanupDoesNotEnumerateUnrelatedStoredConnections() async throws {
    let attachmentRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("GmailTombstoneAttachmentTests.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: attachmentRoot) }
    let attachmentStore = DownloadedAttachmentStore(rootDirectory: attachmentRoot)
    let attachment = MailboxMessageAttachment(
      byteCount: 3,
      filename: "private.pdf",
      id: "attachment-001",
      mimeType: "application/pdf"
    )
    let messageId = StableProviderMessageIdentity(
      connectionId: adapterConnectionId,
      providerMessageId: "message-001"
    )
    _ = try attachmentStore.save(
      Data("PDF".utf8),
      attachment: attachment,
      messageId: messageId
    )
    let connectionService = RecordingAdapterConnectionService()
    connectionService.loadStoredConnectionsError = AdapterTestError.unavailable
    let adapter = GmailMailboxConnectionAdapter(
      attachmentStore: attachmentStore,
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
      Issue.record("Expected synchronized removal")
    } catch let error as MailboxConnectionAdapterError {
      #expect(error == .connectionRemoved)
    }
    #expect(connectionService.clearedConnection?.providerAccountIdentifier == "gmail-user-001")
    #expect(attachmentStore.existingURL(attachment: attachment, messageId: messageId) == nil)
  }

  @Test
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
      Issue.record("Expected synchronized removal")
    } catch let error as MailboxConnectionAdapterError {
      #expect(error == .connectionRemoved)
    }
    #expect(connectionService.clearedProviderAccountIdentifiers == ["gmail-user-001"])
  }

  @Test
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
      Issue.record("Expected synchronized removal")
    } catch let error as MailboxConnectionAdapterError {
      #expect(error == .connectionRemoved)
    }
    #expect(connectionService.clearedProviderAccountIdentifiers == ["gmail-user-001"])
  }

  @Test
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
      Issue.record("Expected synchronized removal")
    } catch let error as MailboxConnectionAdapterError {
      #expect(error == .connectionRemoved)
    }
    #expect(pendingActionStore.saveCallCount == 1)
    #expect(outboxStore.saveCallCount == 1)
  }

  @Test
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
      Issue.record("Expected synchronized removal to reject the queued action")
    } catch let error as MailboxConnectionAdapterError {
      #expect(error == .connectionRemoved)
      let pendingActions = try await pendingActionService.pendingActions(session: session)
      #expect(pendingActions.isEmpty)
      #expect(connectionService.clearedConnection?.providerAccountIdentifier == "gmail-user-001")
    }
  }

  @Test
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

    #expect(metadataService.syncedConnection?.providerAccountIdentifier == "gmail-user-001")
    #expect(connectionService.clearedConnection == nil)
  }

  @Test
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

    #expect(loaded.messages == [message])
    #expect(synced.messages == [message])
    #expect(searched == [message])
    #expect(body == gmailAdapterMessageBody)
    #expect(metadataService.loadedConnection == gmailStatus)
    #expect(metadataService.syncedConnection == gmailStatus)
    #expect(searchService.query == "private phrase")
    #expect(pushService.connection == gmailStatus)
    #expect(mailActionService.action == .archive)
    #expect(mailActionService.messageIds == ["message-001"])
    #expect(mailActionService.outgoingMessage?.recipient == "reader@example.com")
  }

  @Test
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

    #expect(
      metadataService.inboxProjectionCandidateMessageIds == ["message-moved", "message-restored"])
    #expect(metadataService.loadedCollections == [.role(.inbox)])
  }

  @Test
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
        connectionService: RecordingAdapterConnectionService(),
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
      await syncGate.waitUntilOperationIsQueued(connection.id)
      let acquiredBeforeReadFinished = await exclusiveAcquired.value

      #expect(!(acquiredBeforeReadFinished))
      await loadGate.release()
      _ = try await load.value
      try await exclusive.value
      let acquiredAfterReadFinished = await exclusiveAcquired.value
      #expect(acquiredAfterReadFinished)
    }
  }

  @Test
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

    #expect(events == ["push-state-saved", "local-state-cleared"])
    #expect(connectionService.statuses.isEmpty)
  }

  @Test
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

    #expect(body == MailboxMessageBody(text: "Decrypted body"))
    #expect(events == ["body-cache-saved", "local-state-cleared"])
    #expect(connectionService.statuses.isEmpty)
  }

  @Test
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
        pinnedThreadIds: [],
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
    #expect(eventsBeforeRelease.isEmpty)
    await bodyReader.release()
    try await prefetchTask.value
    try await removalTask.value
    let events = await eventLog.snapshot()

    #expect(events == ["body-cache-saved", "local-state-cleared"])
    #expect(connectionService.statuses.isEmpty)
  }

  @Test
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
        pinnedThreadIds: [],
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
    #expect(body == MailboxMessageBody(text: "Decrypted body"))
    #expect(events == ["foreground-body-loaded", "prefetch-finished"])
  }

  @Test
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
    #expect(eventsBeforeRelease.isEmpty)
    await bodyReader.release()

    let body = try await bodyTask.value
    try await cleanupTask.value
    let events = await eventLog.snapshot()
    #expect(body == MailboxMessageBody(text: "Decrypted body"))
    #expect(events == ["body-cache-saved", "local-state-cleared"])
    #expect(connectionService.statuses.isEmpty)
  }

  @Test
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

    #expect(events == ["local-state-cleared"])
    #expect(connectionService.statuses.isEmpty)
  }

  @Test
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
    #expect(eventsBeforeRelease.isEmpty)
    await bodyReader.release()

    _ = try await bodyTask.value
    try await cleanupTask.value
    let events = await eventLog.snapshot()
    #expect(events == ["body-cache-saved", "local-state-cleared"])
  }

  @Test
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
    #expect(eventsBeforeRelease.isEmpty)

    await loadGate.release()
    _ = try await loadTask.value
    try await cleanupTask.value
    let events = await eventLog.snapshot()
    #expect(events == ["connection-load-finished", "local-state-cleared"])
    #expect(connectionService.statuses.isEmpty)
  }

  @Test
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
    #expect(eventsBeforeRelease.isEmpty)

    await loadGate.release()
    _ = try await loadTask.value
    try await cleanupTask.value
    let events = await eventLog.snapshot()
    #expect(events == ["connection-load-finished", "local-state-cleared"])
  }

  @Test
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

    #expect(connections.isEmpty)
    #expect(
      connectionService.clearedProviderAccountIdentifiers == [
        connection.providerMailboxIdentity.value
      ])
  }

  @Test
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
      Issue.record("Expected pending-action cleanup failure")
    } catch is AdapterTestError {
    }
    #expect(
      connectionService.clearedProviderAccountIdentifiers == [
        connection.providerMailboxIdentity.value
      ])
  }

  @Test
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
      Issue.record("Expected first tombstone cleanup failure")
    } catch is AdapterTestError {
    }

    #expect(
      connectionService.clearedProviderAccountIdentifiers == ["gmail-user-001", "gmail-user-002"])
  }

  @Test
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

    #expect(connectionService.clearedProviderAccountIdentifiers.isEmpty)
    #expect(connectionService.statuses == [RecordingAdapterConnectionService.status])
  }

  @Test
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
        pinnedThreadIds: [],
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
    #expect(eventsBeforeRelease.isEmpty)
    await bodyReader.releasePrefetch()

    try await prefetchTask.value
    do {
      _ = try await tombstoneTask.value
      Issue.record("Expected synchronized removal to reject the body load")
    } catch let error as MailboxConnectionAdapterError {
      #expect(error == .connectionRemoved)
    }
    let events = await eventLog.snapshot()
    #expect(events == ["prefetch-finished", "local-state-cleared"])
  }

  @Test
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
        pinnedThreadIds: [],
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
    #expect(eventsBeforeRelease.isEmpty)

    await bodyReader.releasePrefetch()
    try await prefetchTask.value
    do {
      _ = try await inboxTask.value
      Issue.record("Expected synchronized removal to reject the inbox load")
    } catch let error as MailboxConnectionAdapterError {
      #expect(error == .connectionRemoved)
    }
    let events = await eventLog.snapshot()
    #expect(events == ["prefetch-finished", "local-state-cleared"])
  }

  @Test
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
        pinnedThreadIds: [],
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
    #expect(eventsBeforeRelease.isEmpty)

    await bodyReader.releasePrefetch()
    try await prefetchTask.value
    do {
      _ = try await overrideTask.value
      Issue.record("Expected synchronized removal to reject the category override")
    } catch let error as MailboxConnectionAdapterError {
      #expect(error == .connectionRemoved)
    }
    let events = await eventLog.snapshot()
    #expect(events == ["prefetch-finished", "local-state-cleared"])
  }

  @Test
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

    #expect(connections.isEmpty)
    #expect(events == ["push-state-saved", "local-state-cleared"])
    #expect(connectionService.statuses.isEmpty)
  }

  // swiftlint:disable function_body_length
  @MainActor
  @Test
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
      let message = try requireValue(sync.messages.first)
      _ = try await adapter.loadMessageBody(message: message, session: session)
      try await adapter.prefetchMessageBodies(
        connection: connection,
        pinnedThreadIds: [message.threadIdentity],
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
    let defaults = try requireValue(UserDefaults(suiteName: defaultsSuite))
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
          message: try requireValue(messagesByConnection[connection.id]?.first),
          session: session
        ))
    }
    let outboxItems = try await outboxService.items(session: session)
    let outboxStates: [MailShellOutboxState] = outboxItems.map {
      switch $0.state {
      case .handingOff, .pending:
        .pending
      case .reconciling, .retrying, .sentCopyPending:
        .retrying
      case .failed, .outcomeUnknown, .userActionRequired:
        .failed
      case .cancelled, .sent, .superseded:
        .sent
      }
    }

    let pinnedIds = Set(messagesByConnection.values.flatMap { $0 }.map(\.threadIdentity))
    let navigation = MailboxNavigationSnapshot(
      messagesByConnection: messagesByConnection,
      pinnedThreadIds: pinnedIds,
      snoozedThreadIds: [],
      outboxStates: outboxStates
    )
    #expect(
      connections.map(\.id.rawValue) == [
        "gmail:gmail-user-001", "gmail:gmail-user-002",
      ])
    #expect(credentialVerifier.verifiedAccounts.map(\.providerAccountIdentifier) == [])
    #expect(model.threads.count == 2)
    #expect(navigation.count(for: .pins).itemCount == 2)
    #expect(navigation.showsOutbox)
    #expect(Set(outboxItems.map(\.connectionId)) == Set(connections.map(\.id)))
    #expect(
      Set(offlineBodies.map(\.text)) == [
        "Cached body for gmail-user-001",
        "Cached body for gmail-user-002",
      ])
    #expect(
      Set(metadataService.syncedProviderAccountIdentifiers) == [
        "gmail-user-001", "gmail-user-002",
      ])
    #expect(
      Set(bodyReader.loadedProviderAccountIdentifiers) == [
        "gmail-user-001", "gmail-user-002",
      ])
    #expect(
      Set(bodyReader.prefetchedProviderAccountIdentifiers) == [
        "gmail-user-001", "gmail-user-002",
      ])
    #expect(
      Set(pushService.providerAccountIdentifiers) == [
        "gmail-user-001", "gmail-user-002",
      ])
    #expect(
      Set(mailActionService.sentProviderAccountIdentifiers) == [
        "gmail-user-001", "gmail-user-002",
      ])
    #expect(
      Set(mailActionService.performedProviderAccountIdentifiers) == [
        "gmail-user-001", "gmail-user-002",
      ])
    #expect(
      Set(
        mailActionService.performedActions
          .filter { $0.action == .markUnread }
          .map(\.providerAccountIdentifier)
      ) == Set(connections.map(\.providerMailboxIdentity.value)))
    #expect(connections.allSatisfy { freshness.status(for: $0).phase == .idle })
    #expect(connections.allSatisfy { freshness.status(for: $0).lastSuccessfulSyncAt != nil })

    try await adapter.clearLocalConnection(connections[0], session: session)
    try await adapter.removeMailboxConnectionEverywhere(connections[1], session: session)

    #expect(
      connectionService.clearedProviderAccountIdentifiers == [
        "gmail-user-001", "gmail-user-002",
      ])
    #expect(definitionSyncService.removedConnectionIds == [connections[1].id])
    try await outboxService.clear(session: session)
  }
  // swiftlint:enable function_body_length

  // swiftlint:disable cyclomatic_complexity function_body_length
  @Test
  func testProviderRolloutMixedConnectionScenario() async throws {
    let connections = providerRolloutConnections(productAccountId: session.productAccountId)
    let connectionsByProvider = Dictionary(
      uniqueKeysWithValues: connections.map { ($0.providerId, $0) }
    )
    let pop3Connection = try requireValue(connectionsByProvider[.pop3SMTP])
    let graphConnection = try requireValue(connectionsByProvider[.microsoftGraph])
    let providerMailboxIds: [MailboxConnectionId: String] = Dictionary(
      uniqueKeysWithValues: connections.compactMap { connection in
        switch connection.providerId {
        case .gmail:
          (connection.id, "Label_projects")
        case .imapSMTP:
          (connection.id, "imap-mailbox:Projects")
        case .microsoftGraph:
          (connection.id, "graph-folder:projects")
        case .exchangeWebServices:
          (connection.id, EWSProviderMessage.customFolderStateId("projects"))
        default:
          nil
        }
      }
    )
    let threads = connections.enumerated().map { index, connection in
      mailShellThread(
        providerThreadId: "thread-\(connection.providerId.rawValue)",
        messages: [
          mailShellMessage(
            connectionId: connection.id,
            providerMessageId: "message-\(connection.providerId.rawValue)",
            providerThreadId: "thread-\(connection.providerId.rawValue)",
            receivedAt: Int64((connections.count - index) * 100),
            providerStateIds: ["INBOX", index.isMultiple(of: 2) ? "UNREAD" : nil]
              .compactMap(\.self) + [providerMailboxIds[connection.id]].compactMap(\.self)
          )
        ]
      )
    }
    let threadsByConnection = Dictionary(
      uniqueKeysWithValues: zip(connections, threads).map { ($0.id, [$1]) }
    )
    let messagesByConnection = threadsByConnection.mapValues { $0.flatMap(\.messages) }
    let selection = MailShellSelectionModel()
    selection.selectUnifiedInbox()
    for connection in connections {
      selection.updateThreads(threadsByConnection[connection.id, default: []], for: connection.id)
    }

    let listItems = selection.threadListItems(connections: connections)
    #expect(listItems.map(\.thread.id) == threads.map(\.id))
    #expect(listItems.map(\.sourceConnectionDisplayName) == connections.map(\.displayName))
    #expect(Set(listItems.map { $0.thread.id.connectionId.providerId }).count == 5)
    #expect(Set(listItems.map { $0.thread.id.connectionId }).count == 5)

    let providerMailboxesByConnection = Dictionary(
      uniqueKeysWithValues: providerMailboxIds.map { connectionId, providerMailboxId in
        (
          connectionId,
          [ProviderMailbox(id: providerMailboxId, title: "Projects")]
        )
      }
    )
    let pinnedThreadIds = Set([
      try requireValue(threadsByConnection[pop3Connection.id]?.first?.latestMessage.threadIdentity),
      try requireValue(
        threadsByConnection[graphConnection.id]?.first?.latestMessage.threadIdentity),
    ])
    let snapshot = MailboxNavigationSnapshot(
      messagesByConnection: messagesByConnection,
      pinnedThreadIds: pinnedThreadIds,
      snoozedThreadIds: [],
      outboxStates: [.pending, .retrying, .failed, .sent],
      providerMailboxesByConnection: providerMailboxesByConnection
    )
    #expect(snapshot.count(for: .inbox) == MailboxItemCount(itemCount: 5, unreadCount: 3))
    #expect(snapshot.count(for: .pins) == MailboxItemCount(itemCount: 2, unreadCount: 1))
    #expect(snapshot.outboxItemCount == 3)
    #expect(snapshot.showsOutbox)
    for (connectionId, providerMailboxId) in providerMailboxIds {
      #expect(snapshot.providerMailboxIds(for: connectionId) == [providerMailboxId])
      #expect(
        snapshot.count(for: .providerMailbox(providerMailboxId), in: connectionId).itemCount == 1
      )
    }
    #expect(snapshot.providerMailboxIds(for: pop3Connection.id).isEmpty)

    selection.selectThreads(Set(threads.map(\.id)))
    #expect(selection.bulkProviderActions(connections: connections).isEmpty)
    let fullCapabilityConnections = connections.filter { $0.providerId != .pop3SMTP }
    let fullCapabilityConnectionIds = Set(fullCapabilityConnections.map(\.id))
    selection.selectThreads(
      Set(threads.filter { fullCapabilityConnectionIds.contains($0.id.connectionId) }.map(\.id))
    )
    #expect(
      selection.bulkProviderActions(connections: connections) == [.markRead, .markUnread]
    )
    let fullCapabilityBatches = selection.bulkActionBatches(
      connections: connections,
      pinnedThreadIds: pinnedThreadIds
    )
    #expect(Set(fullCapabilityBatches.map(\.connection.id)) == fullCapabilityConnectionIds)

    let actionService = RecordingBulkMailActionService(failingConnectionId: graphConnection.id)
    let actionViewModel = GmailMailActionViewModel(service: actionService, session: session)
    let bulkResult = await actionViewModel.performBulk(
      .markRead,
      batches: fullCapabilityBatches
    )
    #expect(
      Set(bulkResult?.succeededConnectionIds ?? [])
        == fullCapabilityConnectionIds.subtracting([graphConnection.id])
    )
    #expect(bulkResult?.failures.map(\.connectionId) == [graphConnection.id])

    let defaultDraft = MailShellCompositionDraft.new(
      defaultSendingConnectionId: pop3Connection.id
    )
    #expect(defaultDraft.connectionId == pop3Connection.id)
    #expect(pop3Connection.capabilities.canSend)
    #expect(pop3Connection.capabilities.providerActions.isEmpty)

    let defaultsSuite = "ProviderRolloutMixedConnectionScenario.\(UUID().uuidString)"
    let defaults = try requireValue(UserDefaults(suiteName: defaultsSuite))
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    let freshness = MailboxFreshnessViewModel(
      service: GmailMailboxConnectionAdapter(
        definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
        outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
      ),
      session: session,
      isSessionCurrent: { $0 == self.session },
      successStore: UserDefaultsMailboxSyncSuccessStore(defaults: defaults)
    )
    freshness.updateConnections(connections)
    for connection in connections {
      freshness.recordExternalSync(
        connectionIdRawValue: connection.id.rawValue,
        phase: .idle,
        successfulSyncAt: Date(timeIntervalSince1970: 1_781_200_000)
      )
    }
    #expect(connections.allSatisfy { freshness.status(for: $0).phase == .idle })
    #expect(connections.allSatisfy { freshness.status(for: $0).lastSuccessfulSyncAt != nil })

    let synchronizedDefinitions = try JSONEncoder().encode(connections.map(\.definition))
    let synchronizedPayload = try requireValue(
      String(data: synchronizedDefinitions, encoding: .utf8)
    ).lowercased()
    for prohibitedField in ["accesstoken", "refreshtoken", "credential", "password", "body"] {
      #expect(!(synchronizedPayload.contains(prohibitedField)))
    }

    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "provider-rollout-body-cache-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: cacheRoot) }
    let bodyCache = FileGmailMessageBodyCache(rootDirectory: cacheRoot)
    let keyMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 1, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 2, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let encryptedBody = try keyMaterial.encryptPayload(Data("Cached body".utf8))
    for message in messagesByConnection.values.flatMap({ $0 }) {
      try bodyCache.saveMessageBody(
        encryptedBody,
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.id.rawValue
      )
    }
    try bodyCache.clearMessageBodies(
      productAccountId: session.productAccountId,
      connectionId: pop3Connection.id
    )
    #expect(
      try bodyCache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: try requireValue(
          messagesByConnection[pop3Connection.id]?.first?.id.rawValue
        )
      ) == nil
    )
    for connection in connections where connection.id != pop3Connection.id {
      #expect(
        try bodyCache.loadMessageBody(
          productAccountId: session.productAccountId,
          stableProviderMessageId: try requireValue(
            messagesByConnection[connection.id]?.first?.id.rawValue
          )
        ) != nil
      )
    }

    let outboxService = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: AdapterOutboxStore()
    )
    for connection in connections {
      _ = try await outboxService.enqueue(
        OutgoingMessage(
          body: "Queued for \(connection.displayName)",
          recipient: "recipient@example.com",
          subject: "Provider-scoped Outbox"
        ),
        connection: connection,
        session: session,
        provider: { _, _, _ in },
        reconcile: { _, _ in .unknown }
      )
    }
    #expect(
      Set(try await outboxService.items(session: session).map(\.connectionId))
        == Set(connections.map(\.id)))
    try await outboxService.clear(connection: pop3Connection, session: session)
    #expect(
      Set(try await outboxService.items(session: session).map(\.connectionId))
        == Set(connections.filter { $0.id != pop3Connection.id }.map(\.id))
    )

    selection.selectThreads([try requireValue(threadsByConnection[pop3Connection.id]?.first?.id)])
    selection.updateThreads([], for: pop3Connection.id)
    #expect(selection.selectedThreadIds.isEmpty)
    #expect(
      Set(selection.threads.map { $0.id.connectionId })
        == Set(connections.filter { $0.id != pop3Connection.id }.map(\.id)))
    await outboxService.suspend(productAccountId: session.productAccountId)
    try await outboxService.clear(session: session)
  }
  // swiftlint:enable cyclomatic_complexity function_body_length

  @Test
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

    #expect(
      mailActionService.outgoingMessage?.rfcMessageId == "<unwired-attempt-001@outbox.unwired.mail>"
    )
    #expect(searchService.query == "in:sent rfc822msgid:<unwired-attempt-001@outbox.unwired.mail>")
    #expect(status == .sent)
  }

  @Test
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
    #expect(eventsBeforeRelease.isEmpty)

    await mailActionService.release()
    try await sendTask.value
    try await removalTask.value
    let events = await eventLog.snapshot()
    #expect(events == ["message-sent", "local-state-cleared"])
  }

  @Test
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
    #expect(eventsBeforeRelease.isEmpty)

    await mailActionService.release()
    let actionError = await actionTask.value
    #expect(actionError == nil)
    try await removalTask.value
    let events = await eventLog.snapshot()
    #expect(events == ["provider-action-finished", "local-state-cleared"])
  }

  @Test
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
    #expect(eventsBeforeRelease.isEmpty)

    await metadataService.release()
    _ = try await categorizationTask.value
    try await removalTask.value
    let events = await eventLog.snapshot()
    #expect(events == ["historical-categorization-finished", "local-state-cleared"])
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testGmailFreshnessSyncWaitsForHistoricalCategorizationPersistence() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let categorizationStarted = expectation(description: "historical categorization starts")
    let syncTaskStarted = expectation(description: "freshness sync task starts")
    let freshnessPersistenceStarted = expectation(description: "freshness persistence starts")
    freshnessPersistenceStarted.isInverted = true
    let metadataService = DelayedAdapterProviderReadService(
      eventLog: eventLog,
      started: categorizationStarted,
      syncStarted: freshnessPersistenceStarted
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: RecordingAdapterConnectionService(),
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
    let syncTask = Task {
      syncTaskStarted.fulfill()
      return try await adapter.syncRecentInbox(
        connection: connection,
        includingHistoryCandidates: false,
        session: session,
        sinceHistoryId: nil,
        throughHistoryId: nil,
        shouldPersist: { true }
      )
    }
    await fulfillment(of: [syncTaskStarted], timeout: 1)
    await fulfillment(of: [freshnessPersistenceStarted], timeout: 0.1)
    let eventsBeforeRelease = await eventLog.snapshot()
    #expect(eventsBeforeRelease == [])

    await metadataService.release()
    _ = try await categorizationTask.value
    _ = try await syncTask.value
    let events = await eventLog.snapshot()
    #expect(events == ["historical-categorization-finished", "freshness-sync-finished"])
  }

  @Test
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
    #expect(eventsBeforeRelease.isEmpty)

    pendingActionStore.release()
    try await actionTask.value
    try await removalTask.value
    let events = await eventLog.snapshot()
    #expect(events == ["local-state-cleared"])
    #expect(try pendingActionStore.load(productAccountId: session.productAccountId).isEmpty)
  }

  @Test
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
    #expect(try pendingActionStore.load(productAccountId: session.productAccountId).isEmpty)

    await removalGate.release()
    try await removalTask.value
    do {
      try await actionTask.value
      Issue.record("Expected the action racing with removal to observe the tombstone")
    } catch MailboxConnectionAdapterError.connectionRemoved {
    }
    #expect(try pendingActionStore.load(productAccountId: session.productAccountId).isEmpty)
  }

  @Test
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
    #expect(eventsBeforeRelease.isEmpty)

    await providerService.release()
    _ = try await mailboxesTask.value
    _ = try await searchTask.value
    _ = try await deliveryTask.value
    try await removalTask.value
    let events = await eventLog.snapshot()

    #expect(events.last == "local-state-cleared")
    #expect(
      Set(events.dropLast()) == [
        "provider-mailboxes-loaded", "provider-search-finished", "delivery-status-loaded",
      ])
  }

  @Test
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
    #expect(eventsBeforeRelease.isEmpty)

    await providerService.release()
    _ = try await overrideTask.value
    try await removalTask.value
    let events = await eventLog.snapshot()
    #expect(events == ["categories-set", "local-state-cleared"])
  }

  @Test
  func testGmailMailboxRemovalWaitsForInFlightCategorySet() async throws {
    let eventLog = AdapterLifecycleEventLog()
    let connectionService = RecordingAdapterConnectionService(lifecycleEventLog: eventLog)
    let updateStarted = expectation(description: "category update starts")
    let providerService = DelayedAdapterProviderReadService(
      eventLog: eventLog,
      started: updateStarted
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

    let updateTask = Task {
      try await adapter.setCategories(
        ["system-primary", "system:invoices"],
        for: adapterMessage,
        session: session
      )
    }
    await fulfillment(of: [updateStarted], timeout: 1)
    let removalTask = Task {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
    }
    await Task.yield()
    #expect(await eventLog.snapshot() == [])

    await providerService.release()
    _ = try await updateTask.value
    try await removalTask.value
    #expect(await eventLog.snapshot() == ["categories-set", "local-state-cleared"])
  }

  @Test
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
    #expect(error == nil)
  }

  @Test
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
      ) { _, _, _, _ in
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

    #expect(result.messages == [adapterMessage])
  }

  @Test
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

    #expect(failure != nil)
    #expect(Set(failureDetails?.flatMap(\.messageIds) ?? []) == [adapterMessage.id])
    #expect(blockedConnectionIds == [connection.id])

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

    #expect(retryFailure == nil)
    #expect(mailActionService.messageIds == messages.map(\.providerMessageId))
    #expect(remainingFailureDetails == [])
  }

  @Test
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

    #expect(metadataService.loadedCollections == [.allObserved, .role(.inbox)])
    #expect(eventLog.events == ["observed", "resume", "inbox"])
  }

  @Test
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

    #expect(result.hasUnlistedNewMessages)
    #expect(result.newMessageIds == ["message-001"])
    #expect(result.providerCursorIsExpired)
  }

  @Test
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
    ) { _, _, _, _ in }

    let result = try await adapter.syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: true,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    let actionStates = try await pendingActionService.pendingActions(session: session).map(\.state)
    #expect(result.messages.map(\.providerMessageId) == ["message-002"])
    #expect(actionStates == [.providerConfirmed])
  }

  @Test
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
    ) { _, _, _, _ in }

    _ = try await adapter.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    let actions = try await pendingActionService.pendingActions(session: session)
    #expect(actions.isEmpty)
  }

  @Test
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
    #expect(queuedActions.map(\.action) == [.archive])

    await backfillGate.release()
    _ = try await backfillTask.value
    try await actionTask.value
  }

  @Test
  func testGmailAdapterRecentSyncPreemptsHistoricalBackfillWithoutOverlap() async throws {
    let backfillStarted = expectation(description: "historical backfill started")
    let recentSyncStarted = expectation(description: "recent sync started")
    let priorityProbe = AdapterSyncPriorityProbe(
      backfillStarted: backfillStarted,
      recentSyncStarted: recentSyncStarted
    )
    let metadataService = RecordingAdapterMetadataService(syncPriorityProbe: priorityProbe)
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      metadataService: metadataService,
      pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore()),
      syncGate: MailboxConnectionSyncGate()
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let backfillTask = Task {
      try await adapter.continueHistoricalBackfill(connection: connection, session: session)
    }
    await fulfillment(of: [backfillStarted], timeout: 1)

    let recentSyncTask = Task {
      try await adapter.syncRecentInbox(
        connection: connection,
        includingHistoryCandidates: true,
        session: session,
        sinceHistoryId: "10",
        throughHistoryId: "11",
        shouldPersist: { true }
      )
    }
    await fulfillment(of: [recentSyncStarted], timeout: 1)
    await priorityProbe.releaseBackfill()

    _ = try await recentSyncTask.value
    do {
      _ = try await backfillTask.value
      Issue.record("Expected recent sync to cancel the historical backfill")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected cancellation, got \(error)")
    }
    let snapshot = await priorityProbe.snapshot()
    #expect(snapshot.maximumConcurrentOperations == 1)
    #expect(snapshot.events == ["backfill-started", "backfill-cancelled", "recent-sync-started"])
  }

  @Test
  func testGmailAdapterRechecksCancellationAfterHistoricalBackfillReturns() async throws {
    let eventLog = RecordingAdapterEventLog()
    let metadataService = RecordingAdapterMetadataService(eventLog: eventLog)
    metadataService.cancelsAfterHistoricalBackfill = true
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      metadataService: metadataService,
      pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore())
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )

    do {
      _ = try await adapter.continueHistoricalBackfill(
        connection: connection,
        session: session
      )
      Issue.record("Expected cancellation after the historical page returned")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected cancellation, got \(error)")
    }

    #expect(eventLog.events.isEmpty)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testGmailAdapterFailedRecentSyncRecoversCompletedCancelledBackfill() async throws {
    let pendingActionService = PendingProviderActionService(store: AdapterPendingActionStore())
    let historicalBackfillGate = AdapterLifecycleOperationGate()
    let metadataService = RecordingAdapterMetadataService(
      historicalBackfillGate: historicalBackfillGate
    )
    var staleGmailMessage = adapterGmailMessage
    staleGmailMessage.providerLabelIds = ["INBOX"]
    metadataService.inboxSyncResult = GmailMetadataSyncResult(
      historicalMetadataBackfillIsComplete: true,
      messages: [staleGmailMessage],
      threads: GmailInboxThread.group([staleGmailMessage])
    )
    metadataService.cancelsAfterHistoricalBackfill = true
    metadataService.failsRecentSync = true
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      metadataService: metadataService,
      pendingActionService: pendingActionService,
      syncGate: MailboxConnectionSyncGate()
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
    ) { _, _, _, _ in }

    let backfillTask = Task {
      try await adapter.continueHistoricalBackfill(
        connection: connection,
        session: session
      )
    }
    await historicalBackfillGate.waitUntilStarted()
    let preemptionStarted = expectation(description: "recent sync began preemption")
    let recentSyncTask = Task {
      try await adapter.syncRecentInbox(
        connection: connection,
        includingHistoryCandidates: true,
        session: session,
        sinceHistoryId: "10",
        throughHistoryId: "11",
        shouldPersist: { true },
        didBeginPreemption: {
          preemptionStarted.fulfill()
        }
      )
    }
    await fulfillment(of: [preemptionStarted], timeout: 1)
    await historicalBackfillGate.release()

    do {
      _ = try await backfillTask.value
      Issue.record("Expected final-page cancellation before pending-action reconciliation")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected cancellation, got \(error)")
    }
    do {
      _ = try await recentSyncTask.value
      Issue.record("Expected the recent sync to fail")
    } catch AdapterTestError.unavailable {
    } catch {
      Issue.record("Expected provider failure, got \(error)")
    }

    let actions = try await pendingActionService.pendingActions(session: session)
    #expect(actions.isEmpty)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testGmailAdapterCancelledPreemptorRecoversCompletedCancelledBackfill() async throws {
    let pendingActionService = PendingProviderActionService(store: AdapterPendingActionStore())
    let historicalBackfillGate = AdapterLifecycleOperationGate()
    let metadataService = RecordingAdapterMetadataService(
      historicalBackfillGate: historicalBackfillGate
    )
    var staleGmailMessage = adapterGmailMessage
    staleGmailMessage.providerLabelIds = ["INBOX"]
    metadataService.inboxSyncResult = GmailMetadataSyncResult(
      historicalMetadataBackfillIsComplete: true,
      messages: [staleGmailMessage],
      threads: GmailInboxThread.group([staleGmailMessage])
    )
    metadataService.cancelsAfterHistoricalBackfill = true
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      metadataService: metadataService,
      pendingActionService: pendingActionService,
      syncGate: MailboxConnectionSyncGate()
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
    ) { _, _, _, _ in }

    let backfillTask = Task {
      try await adapter.continueHistoricalBackfill(
        connection: connection,
        session: session
      )
    }
    await historicalBackfillGate.waitUntilStarted()
    let preemptionStarted = expectation(description: "recent sync began preemption")
    let recentSyncTask = Task {
      try await adapter.syncRecentInbox(
        connection: connection,
        includingHistoryCandidates: true,
        session: session,
        sinceHistoryId: "10",
        throughHistoryId: "11",
        shouldPersist: { true },
        didBeginPreemption: {
          preemptionStarted.fulfill()
        }
      )
    }
    await fulfillment(of: [preemptionStarted], timeout: 1)
    recentSyncTask.cancel()
    await historicalBackfillGate.release()

    do {
      _ = try await backfillTask.value
      Issue.record("Expected final-page cancellation before pending-action reconciliation")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected cancellation, got \(error)")
    }
    do {
      _ = try await recentSyncTask.value
      Issue.record("Expected the recent sync to be cancelled while acquiring the gate")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected cancellation, got \(error)")
    }

    let actions = try await pendingActionService.pendingActions(session: session)
    #expect(actions.isEmpty)
  }

  @Test
  func testGmailAdapterFailedRecentSyncPreservesActionWithoutPreemptedBackfill() async throws {
    let pendingActionService = PendingProviderActionService(store: AdapterPendingActionStore())
    let metadataService = RecordingAdapterMetadataService()
    var staleGmailMessage = adapterGmailMessage
    staleGmailMessage.providerLabelIds = ["INBOX"]
    metadataService.inboxSyncResult = GmailMetadataSyncResult(
      historicalMetadataBackfillIsComplete: true,
      messages: [staleGmailMessage],
      threads: GmailInboxThread.group([staleGmailMessage])
    )
    metadataService.failsRecentSync = true
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      metadataService: metadataService,
      pendingActionService: pendingActionService,
      syncGate: MailboxConnectionSyncGate()
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
    ) { _, _, _, _ in }

    do {
      _ = try await adapter.syncRecentInbox(
        connection: connection,
        includingHistoryCandidates: true,
        session: session,
        sinceHistoryId: "10",
        throughHistoryId: "11",
        shouldPersist: { true }
      )
      Issue.record("Expected the recent sync to fail")
    } catch AdapterTestError.unavailable {
    } catch {
      Issue.record("Expected provider failure, got \(error)")
    }

    let actionStates = try await pendingActionService.pendingActions(session: session).map(\.state)
    #expect(actionStates == [.providerConfirmed])
  }

  @Test
  func testGmailAdapterStaleRecentSyncDoesNotPreemptHistoricalBackfill() async throws {
    let backfillStarted = expectation(description: "historical backfill started")
    let priorityProbe = AdapterSyncPriorityProbe(
      backfillStarted: backfillStarted
    )
    let metadataService = RecordingAdapterMetadataService(syncPriorityProbe: priorityProbe)
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      metadataService: metadataService,
      pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore()),
      syncGate: MailboxConnectionSyncGate()
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let persistenceFence = AdapterPersistenceFence()
    let backfillTask = Task {
      try await adapter.continueHistoricalBackfill(connection: connection, session: session)
    }
    await fulfillment(of: [backfillStarted], timeout: 1)

    do {
      _ = try await adapter.syncRecentInbox(
        connection: connection,
        includingHistoryCandidates: true,
        session: session,
        sinceHistoryId: "10",
        throughHistoryId: "11",
        shouldPersist: { persistenceFence.allowFirstCheckOnly() }
      )
      Issue.record("Expected the stale recent sync to stop inside the preemption gate")
    } catch GmailMessageMetadataSyncError.staleLocalConnection {
    } catch {
      Issue.record("Expected stale connection, got \(error)")
    }

    let snapshot = await priorityProbe.snapshot()
    #expect(snapshot.events == ["backfill-started"])
    await priorityProbe.releaseBackfill()
    _ = try await backfillTask.value
  }

  @Test
  func testMailboxConnectionSyncGateCancelledPreemptorLeavesBackfillRunning() async throws {
    let backfillStarted = expectation(description: "historical backfill started")
    let priorityProbe = AdapterSyncPriorityProbe(
      backfillStarted: backfillStarted
    )
    let entryGate = AdapterLifecycleOperationGate()
    let gate = MailboxConnectionSyncGate()
    let connectionId = adapterConnectionId
    let backfill = Task {
      try await gate.withPreemptibleLock(connectionId) {
        try await priorityProbe.suspendBackfill()
      }
    }
    await fulfillment(of: [backfillStarted], timeout: 1)
    let preemptor = Task {
      await entryGate.waitForRelease()
      try await gate.withPreemptingLock(connectionId) {}
    }
    await entryGate.waitUntilStarted()

    preemptor.cancel()
    await entryGate.release()

    do {
      try await preemptor.value
      Issue.record("Expected the cancelled preemptor to stop before acquiring the gate")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected cancellation, got \(error)")
    }
    let snapshot = await priorityProbe.snapshot()
    #expect(snapshot.events == ["backfill-started"])
    await priorityProbe.releaseBackfill()
    try await backfill.value
  }

  @Test
  func testMailboxConnectionSyncGateKeepsQueuedGlobalExclusiveAheadOfPreemptor() async throws {
    let backfillStarted = expectation(description: "historical backfill started")
    let priorityProbe = AdapterSyncPriorityProbe(
      backfillStarted: backfillStarted
    )
    let eventLog = AdapterLifecycleEventLog()
    let gate = MailboxConnectionSyncGate()
    let connectionId = adapterConnectionId
    let backfill = Task {
      try await gate.withPreemptibleLock(connectionId) {
        try await priorityProbe.suspendBackfill()
      }
    }
    await fulfillment(of: [backfillStarted], timeout: 1)
    let exclusiveAttempted = expectation(description: "global exclusive attempted")
    let exclusive = Task {
      exclusiveAttempted.fulfill()
      try await gate.withAllConnectionsLocked {
        await eventLog.record("global-exclusive")
      }
    }
    await fulfillment(of: [exclusiveAttempted])
    for _ in 0..<10 {
      await Task.yield()
    }

    let preemptor = Task {
      try await gate.withPreemptingLock(connectionId) {
        await eventLog.record("preemptor")
      }
    }

    try await exclusive.value
    try await preemptor.value
    do {
      try await backfill.value
      Issue.record("Expected the preemptor to cancel the historical backfill")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected cancellation, got \(error)")
    }
    let events = await eventLog.snapshot()
    #expect(events == ["global-exclusive", "preemptor"])
  }

  @Test
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

    #expect(viewModel.selectedMailbox == .unified(.inbox))
    #expect(viewModel.navigationLevel == .threadList)
    #expect(viewModel.preferredCompactColumn == .content)

    viewModel.selectMailbox(connectionId: adapterConnectionId)
    viewModel.updateThreads([olderThread, newerThread], for: adapterConnectionId)
    viewModel.selectThread(olderThread.id)
    viewModel.updateThreads([newerThread, olderThread], for: adapterConnectionId)

    #expect(viewModel.selectedThreadId == olderThread.id)
    #expect(viewModel.navigationLevel == .conversation)
    #expect(viewModel.preferredCompactColumn == .detail)
    #expect(viewModel.compactColumn(isEditing: true) == .content)

    viewModel.updateThreads([newerThread], for: adapterConnectionId)

    #expect(viewModel.selectedThreadId == nil)
    #expect(viewModel.navigationLevel == .threadList)
    #expect(viewModel.preferredCompactColumn == .content)
  }

  @Test
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

    #expect(viewModel.selectedThreadId == searchMessage.threadIdentity)
    #expect(viewModel.selectedThread?.messages == [searchMessage])
    #expect(viewModel.partialSearchResultThreadId == searchMessage.threadIdentity)
  }

  @Test
  func testMailShellSelectionTargetsMatchedMessageInLoadedThread() throws {
    let olderMessage = mailShellMessage(
      providerMessageId: "message-older",
      providerThreadId: "thread-001",
      receivedAt: 100
    )
    let newerMessage = mailShellMessage(
      providerMessageId: "message-newer",
      providerThreadId: "thread-001",
      receivedAt: 200
    )
    let loadedThread = mailShellThread(
      providerThreadId: "thread-001",
      messages: [olderMessage, newerMessage]
    )
    let viewModel = MailShellSelectionModel()
    viewModel.selectMailbox(connectionId: adapterConnectionId)
    viewModel.updateThreads([loadedThread], for: adapterConnectionId)

    viewModel.selectSearchResult(olderMessage)

    let scrollTarget = try #require(viewModel.selectedMessageScrollTarget)
    #expect(viewModel.selectedThread?.messages == loadedThread.messages)
    #expect(viewModel.partialSearchResultThreadId == nil)
    #expect(scrollTarget.messageId == olderMessage.id)

    viewModel.clearMessageScrollTarget(scrollTarget)
    #expect(viewModel.selectedMessageScrollTarget == nil)
  }

  @Test
  func testMailShellSelectionRetainsEverySearchHitUntilThreadHydrates() {
    let olderMessage = mailShellMessage(
      providerMessageId: "message-older",
      providerThreadId: "thread-001",
      receivedAt: 100
    )
    let newerMessage = mailShellMessage(
      providerMessageId: "message-newer",
      providerThreadId: "thread-001",
      receivedAt: 200
    )
    let viewModel = MailShellSelectionModel()
    viewModel.selectMailbox(connectionId: adapterConnectionId)

    viewModel.selectSearchResult(olderMessage)
    viewModel.selectSearchResult(newerMessage)

    #expect(viewModel.selectedThread?.messages == [newerMessage, olderMessage])
    #expect(viewModel.partialSearchResultThreadId == newerMessage.threadIdentity)

    viewModel.updateThreads(
      [
        mailShellThread(
          providerThreadId: "thread-001",
          messages: [olderMessage, newerMessage]
        )
      ],
      for: adapterConnectionId
    )

    #expect(viewModel.partialSearchResultThreadId == nil)
  }

  @Test
  func testMailShellSelectionKeepsSearchResultOutsideActiveMailView() {
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
    ).assigningCategories(["system:promotions"])
    let viewModel = MailShellSelectionModel(initialMailView: .important)
    viewModel.selectMailbox(connectionId: adapterConnectionId)
    viewModel.updateThreads([loadedThread], for: adapterConnectionId)

    viewModel.selectSearchResult(searchMessage)
    viewModel.updateThreads([loadedThread], for: adapterConnectionId)

    #expect(viewModel.selectedMailView == .important)
    #expect(viewModel.selectedThreadId == searchMessage.threadIdentity)
    #expect(viewModel.selectedThread?.messages == [searchMessage])
  }

  @Test
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

    #expect(viewModel.selectedConnectionId == otherConnectionId)
    #expect(viewModel.selectedThread?.messages == [searchMessage])
  }

  @Test
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
    #expect(items.map(\.thread.id) == [newerThread.id, olderThread.id])
    #expect(
      items.map(\.sourceConnectionDisplayName) == [
        secondConnection.displayName, firstConnection.displayName,
      ])
  }

  @Test
  func testNewApplicationSessionStartsInUnifiedInboxWithImportantSelected() {
    let model = MailShellSelectionModel(initialMailView: .important)

    #expect(model.selectedMailbox == .unified(.inbox))
    #expect(model.selectedMailView == .important)
  }

  @Test
  func testUnsupportedMailboxesHideMailViewPresentations() {
    let model = MailShellSelectionModel()

    model.selectUnifiedMailbox(.drafts)
    #expect(model.mailViewPresentations(categoryChoices: []).isEmpty)

    model.selectOutbox()
    #expect(model.mailViewPresentations(categoryChoices: []).isEmpty)
  }

  @Test
  func testMailViewsFilterWholeThreadsAndCountUnreadThreadsOnce() throws {
    let orderThread = mailShellThread(
      providerThreadId: "thread-order",
      messages: [
        mailShellMessage(
          providerMessageId: "order",
          providerThreadId: "thread-order",
          receivedAt: 200,
          providerStateIds: ["INBOX"]
        )
        .assigningCategories(["system:invoices"]),
        mailShellMessage(
          providerMessageId: "order-follow-up",
          providerThreadId: "thread-order",
          receivedAt: 100,
          providerStateIds: ["INBOX", "UNREAD"]
        ),
      ]
    )
    let promotionThread = mailShellThread(
      providerThreadId: "thread-promotion",
      messages: [
        mailShellMessage(
          providerMessageId: "promotion",
          providerThreadId: "thread-promotion",
          receivedAt: 300,
          providerStateIds: ["INBOX", "UNREAD"]
        )
        .assigningCategories(["system:promotions"])
      ]
    )
    let model = MailShellSelectionModel()
    model.updateMailViews(configuration: .defaults)
    model.selectMailbox(connectionId: adapterConnectionId)
    model.updateThreads([promotionThread, orderThread], for: adapterConnectionId)

    model.selectMailView(.category("system:invoices"))

    #expect(model.threads.map(\.id) == [orderThread.id])
    let presentations = model.mailViewPresentations(
      categoryChoices: MessageCategoryChoice.available(customCategories: [])
    )
    let orderView = try #require(
      presentations.first { $0.selection == .category("system:invoices") }
    )
    let promotionView = try #require(
      presentations.first { $0.selection == .category("system:promotions") }
    )
    #expect(orderView.unreadThreadCount == 1)
    #expect(orderView.badge == "1")
    #expect(promotionView.unreadThreadCount == 1)
    #expect(MailViewFilter.isUnread(orderThread))
  }

  @Test
  func testRemovedMailViewFallsBackToAllAndPreservesThreadSelection() {
    let flightThread = mailShellThread(
      providerThreadId: "thread-flight",
      messages: [
        mailShellMessage(
          providerMessageId: "flight",
          providerThreadId: "thread-flight",
          receivedAt: 100
        )
        .assigningCategories(["system:flights"])
      ]
    )
    let model = MailShellSelectionModel()
    model.selectMailbox(connectionId: adapterConnectionId)
    model.updateThreads([flightThread], for: adapterConnectionId)
    model.selectMailView(.category("system:flights"))
    model.selectThread(flightThread.id)

    model.updateMailViews(
      configuration: MailViewConfiguration(
        importantCategoryIds: ["system:people"],
        categorySlots: ["system:invoices", nil, nil]
      )
    )

    #expect(model.selectedMailView == .all)
    #expect(model.selectedThreadId == flightThread.id)
  }

  @Test
  func testDisabledSystemCategoriesAreUnavailableToMailViews() {
    let choices = MessageCategoryChoice.available(
      customCategories: [],
      configuration: CategoryConfiguration(
        disabledSystemCategoryIds: ["system:flights"]
      )
    )

    #expect(!choices.contains { $0.id == "system:flights" })
    #expect(choices.contains { $0.id == "system:invoices" })
  }

  @Test
  func testMailViewPresentationsUseCustomCategorySymbol() throws {
    let customCategoryId = "custom:travel"
    let model = MailShellSelectionModel()
    model.updateMailViews(
      configuration: MailViewConfiguration(
        importantCategoryIds: ["system:people"],
        categorySlots: [customCategoryId, nil, nil]
      )
    )

    let presentation = try #require(
      model.mailViewPresentations(
        categoryChoices: [
          MessageCategoryChoice(
            id: customCategoryId,
            name: "Travel",
            systemImage: "briefcase.fill"
          )
        ]
      ).first { $0.selection == .category(customCategoryId) }
    )

    #expect(presentation.systemImage == "briefcase.fill")
  }

  @Test
  func testDraftsUseAllAndRestoreThePriorThreadMailView() {
    let model = MailShellSelectionModel()
    model.selectMailView(.category("system:flights"))

    model.selectUnifiedMailbox(.drafts)
    #expect(model.selectedMailView == .all)

    model.selectUnifiedInbox()
    #expect(model.selectedMailView == .category("system:flights"))

    model.selectMailbox(
      connectionId: adapterConnectionId,
      collection: .role(.drafts)
    )
    #expect(model.selectedMailView == .all)

    model.selectUnifiedInbox()
    #expect(model.selectedMailView == .category("system:flights"))
  }

  @Test
  func testMailboxSyncOverlayDelaysAutomaticWorkAndAggregatesProgress() throws {
    let now = Date(timeIntervalSince1970: 100)
    let secondConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "second"
      )
    )
    let connections = [
      MailboxSyncOverlayConnection(
        id: adapterConnectionId,
        name: "First",
        status: MailboxSyncStatus(
          lastSuccessfulSyncAt: nil,
          phase: .syncing,
          activity: .automatic,
          progress: MailboxSyncProgress(completedUnitCount: 1, totalUnitCount: 2),
          visibleAfter: now.addingTimeInterval(1)
        )
      ),
      MailboxSyncOverlayConnection(
        id: secondConnectionId,
        name: "Second",
        status: MailboxSyncStatus(
          lastSuccessfulSyncAt: nil,
          phase: .syncing,
          activity: .automatic,
          progress: MailboxSyncProgress(completedUnitCount: 3, totalUnitCount: 4),
          visibleAfter: now.addingTimeInterval(1)
        )
      ),
    ]

    #expect(
      MailboxSyncOverlayState.aggregate(
        connections: connections,
        isLoadingInitialAvailability: false,
        now: now
      ) == nil
    )
    let visible = try #require(
      MailboxSyncOverlayState.aggregate(
        connections: connections,
        isLoadingInitialAvailability: false,
        now: now.addingTimeInterval(1)
      )
    )
    #expect(visible.progress == 0.625)
    #expect(visible.title == "Synchronizing mailboxes…")
  }

  @Test
  func testMailShellMessageBodyDoesNotPublishLoadAfterClear() async throws {
    let loadStarted = expectation(description: "Message body load started")
    let presentationReleased = expectation(description: "late presentation released")
    let loader = GatedMessageBodyLoader(started: loadStarted)
    let clearSignal = MessageBodyClearSignal()
    var didPublishLoadedBody = false
    let host = UIHostingController(
      rootView: ClearableMessageBodyHarness(
        clearSignal: clearSignal,
        onLoaded: { didPublishLoadedBody = true },
        onRelease: { presentationReleased.fulfill() },
        load: { await loader.load() }
      )
    )
    let window = try releaseFixtureWindow(hosting: host)

    releaseBeginRendering(host.view)
    await fulfillment(of: [loadStarted], timeout: 1)
    clearSignal.value = UUID()
    await releaseRenderFrame(host.view)
    loader.resume(
      with: MailboxMessageBody(
        text: "Private body",
        inlineImages: [
          MailboxMessageInlineImage(
            contentID: "late@example.com",
            data: Data([1]),
            decodedPixelCount: 1,
            mimeType: "image/png"
          )
        ]
      )
    )
    await fulfillment(of: [presentationReleased], timeout: 1)

    #expect(!(didPublishLoadedBody))
    withExtendedLifetime(window) {}
  }

  @Test
  func testMailShellMessageBodyReleasesLoadedPresentationAfterClear() async throws {
    let bodyLoaded = expectation(description: "Message body loaded")
    let presentationReleased = expectation(description: "Message body presentation released")
    let clearSignal = MessageBodyClearSignal()
    let host = UIHostingController(
      rootView: ClearableMessageBodyHarness(
        clearSignal: clearSignal,
        onLoaded: { bodyLoaded.fulfill() },
        onRelease: { presentationReleased.fulfill() },
        load: { MailboxMessageBody(text: "Private body") }
      )
    )
    let window = try releaseFixtureWindow(hosting: host)

    releaseBeginRendering(host.view)
    await fulfillment(of: [bodyLoaded], timeout: 1)
    clearSignal.value = UUID()
    await fulfillment(of: [presentationReleased], timeout: 1)

    withExtendedLifetime(window) {}
  }

  @Test
  func testMailShellMessageBodyRetriesFailedLoadInline() async throws {
    let loadFailed = expectation(description: "Initial message body load failed")
    let bodyLoaded = expectation(description: "Message body loaded after retry")
    let retrySignal = MessageBodyRetrySignal()
    var loadAttempts = 0
    let host = UIHostingController(
      rootView: RetryableMessageBodyHarness(
        retrySignal: retrySignal,
        onLoaded: { bodyLoaded.fulfill() },
        load: {
          loadAttempts += 1
          if loadAttempts == 1 {
            loadFailed.fulfill()
            throw URLError(.timedOut)
          }
          return MailboxMessageBody(text: "Recovered body")
        }
      )
    )
    let window = try releaseFixtureWindow(hosting: host)

    releaseBeginRendering(host.view)
    await fulfillment(of: [loadFailed], timeout: 1)
    await releaseRenderFrame(host.view)
    retrySignal.value = UUID()
    await fulfillment(of: [bodyLoaded], timeout: 1)

    #expect(loadAttempts == 2)
    withExtendedLifetime(window) {}
  }

  // swiftlint:disable cyclomatic_complexity function_body_length
  @MainActor
  @Test
  func testGmailFirstReleaseCachedPresentationMeetsPerformanceBudgets() async throws {
    #if CI_PERFORMANCE_BUDGET
      let presentationBudgetScale = 4.0
    #else
      let presentationBudgetScale = 1.0
    #endif
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
    let defaultProfile = MailProfileDefinition.defaultProfile(
      productAccountId: session.productAccountId)
    let workProfileId = MailProfileId(rawValue: "release-profile-work")
    let workProfile = MailProfileDefinition(
      id: workProfileId,
      appearance: MailProfileAppearance(colorName: "orange", symbolName: "briefcase"),
      name: "Work",
      recordScope: .profile(workProfileId),
      quietState: .inactive
    )
    let profileSnapshot = MailProfileSyncSnapshot(
      assignments: [
        firstConnection.id: defaultProfile.id,
        secondConnection.id: workProfile.id,
      ],
      conflicts: [],
      defaultProfileId: defaultProfile.id,
      profiles: [defaultProfile, workProfile],
      updatedAt: 1
    )
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
              providerThreadId: "thread-\(index)",
              messages: [
                mailShellMessage(
                  connectionId: connection.id,
                  providerMessageId: "message-\(index)",
                  providerThreadId: "thread-\(index)",
                  receivedAt: Int64(index)
                )
                .assigningCategories([
                  index.isMultiple(of: 2) ? "system:invoices" : "system:flights"
                ])
              ]
            )
          }
        )
      }
    )
    let sentThreadsByConnection = Dictionary(
      uniqueKeysWithValues: connections.map { connection in
        (
          connection.id,
          (0..<25).map { index in
            mailShellThread(
              providerThreadId: "sent-thread-\(index)",
              messages: [
                mailShellMessage(
                  connectionId: connection.id,
                  providerMessageId: "sent-message-\(index)",
                  providerThreadId: "sent-thread-\(index)",
                  receivedAt: Int64(index),
                  providerStateIds: ["SENT"]
                )
              ]
            )
          }
        )
      }
    )
    let metadataStore = try SwiftDataGmailMessageMetadataStore.inMemory()
    for connection in connections {
      try metadataStore.saveMessages(
        (threadsByConnection[connection.id, default: []]
          + sentThreadsByConnection[connection.id, default: []]).flatMap(\.messages).map(
            \.gmailMetadata),
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
    let bodyCacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "release-body-cache-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: bodyCacheRoot) }
    let bodyCache = FileGmailMessageBodyCache(rootDirectory: bodyCacheRoot)
    let allReleaseMessages =
      (threadsByConnection.values.flatMap { $0 }
      + sentThreadsByConnection.values.flatMap { $0 })
      .flatMap(\.messages)
    for message in allReleaseMessages {
      try bodyCache.saveMessageBody(
        keyMaterial.encryptPayload(
          GmailMessageBodyCachePayload.encode(GmailMessageBody(text: "Cached body")),
          associatedData: Data("gmail-body-cache-v1:\(message.id.rawValue)".utf8)
        ),
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.id.rawValue
      )
    }
    let connectionService = RecordingAdapterConnectionService()
    connectionService.statuses = connectionStatuses
    let metadataService = RecordingAdapterMetadataService()
    metadataService.cachedService = cachedMetadataService
    metadataService.providerDelayNanoseconds = 25_000_000
    let definitionSyncService = RecordingAdapterDefinitionSyncService(
      snapshot: MailboxConnectionSyncSnapshot(
        connections: connections.map(\.definition),
        defaultSendingConnectionId: connections.first?.id,
        removedConnectionIds: [],
        updatedAt: 1_781_200_000_300
      )
    )
    let adapter = GmailMailboxConnectionAdapter(
      bodyReader: GmailMessageBodyService(
        cache: bodyCache,
        keyMaterialStore: keyMaterialStore,
        oauthClientId: nil
      ),
      connectionService: connectionService,
      definitionSyncService: definitionSyncService,
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
      messagesByConnection: Dictionary(
        uniqueKeysWithValues: connections.map { connection in
          (
            connection.id,
            (threadsByConnection[connection.id, default: []]
              + sentThreadsByConnection[connection.id, default: []]).flatMap(\.messages)
          )
        }
      ),
      pinnedThreadIds: [],
      snoozedThreadIds: [],
      outboxStates: []
    )
    var launchSamples: [Double] = []
    var profileSwitchSamples: [Double] = []
    var profileSwitchMainActorStalls: [Double] = []
    var mailboxSwitchSamples: [Double] = []
    var mailViewSwitchSamples: [Double] = []
    var bodyOpenSamples: [Double] = []
    var emptyDraftOpenSamples: [Double] = []
    var warmDraftOpenSamples: [Double] = []
    var directInputFeedbackSamples: [Double] = []
    var formattingFeedbackSamples: [Double] = []
    let genericMailSetupService = GenericMailSetupService(
      authorizationStore: ReleaseGenericMailAuthorizationStore(),
      definitionSyncService: definitionSyncService
    )
    let productAccountResponse = ProductAccountConnectResponse(
      accountCreated: false,
      deviceRegistered: true,
      productSyncMaterialInitialized: true,
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )
    let bodyMessage = try requireValue(
      threadsByConnection[secondConnection.id]?.first?.latestMessage)
    var bodyWarmupFinished = false
    let bodyHost = UIHostingController(
      rootView: ReleaseMessageBodyHarness(
        loadId: UUID(),
        onLoaded: { bodyWarmupFinished = true },
        load: { try await adapter.loadMessageBody(message: bodyMessage, session: self.session) }
      )
    )
    let bodyWindow = try releaseFixtureWindow(hosting: bodyHost)
    let bodyWarmupRendered = await releaseWaitForRenderedContent(
      in: bodyHost.view,
      budgetScale: presentationBudgetScale,
      isReady: { bodyWarmupFinished }
    )
    #expect(bodyWarmupRendered)
    bodyWindow.isHidden = true

    for _ in 0..<20 {
      let launchSessionStore = InMemoryProductAccountSessionStore()
      try launchSessionStore.save(session)
      let launchKeyMaterialStore = InMemoryProductSyncKeyMaterialStore()
      try launchKeyMaterialStore.save(keyMaterial, productAccountId: session.productAccountId)
      let productAccountSession = ProductAccountSession(
        appleSignInService: PreviewAppleSignInService(
          credential: AppleSignInCredential(
            appleUserIdentifier: session.appleUserIdentifier,
            identityToken: session.identityToken
          )
        ),
        productAccountService: PreviewProductAccountService(response: productAccountResponse),
        sessionStore: launchSessionStore,
        productSyncKeyMaterialStore: launchKeyMaterialStore
      )
      let launchFinished = expectation(description: "Production mail shell launch finished")
      let releaseBudgetDriver = MailShellReleaseBudgetDriver()
      let launchStart = clock.now
      let launchHost = UIHostingController(
        rootView: RootView(session: productAccountSession) { launchSnapshot in
          AccountView(
            session: productAccountSession,
            snapshot: launchSnapshot,
            categorySyncService: ReleaseCustomCategorySyncService(),
            categorySyncServiceFactory: { _ in ReleaseCustomCategorySyncService() },
            genericMailSetupService: genericMailSetupService,
            inboxPreferenceSync: ReleaseInboxPreferenceSyncService(),
            inboxPreferenceSyncFactory: { _ in ReleaseInboxPreferenceSyncService() },
            mailboxConnection: adapter,
            notificationAuthorization: ReleaseNotificationAuthorization(),
            notificationRuleSync: ReleaseNotificationRuleSyncService(),
            pinSyncService: ReleasePinSyncService(),
            snoozeSyncService: ReleaseThreadSnoozeSyncService(),
            profileSnapshotLoader: ReleaseMailProfileSnapshotLoader(
              snapshot: profileSnapshot
            ),
            initialLaunchDidFinish: { launchFinished.fulfill() },
            releaseBudgetDriver: releaseBudgetDriver
          )
        }
        .environment(SettingsRouter())
      )
      let launchWindow = try releaseFixtureWindow(hosting: launchHost)
      await fulfillment(of: [launchFinished], timeout: 2 * presentationBudgetScale)
      let firstInboxIds = threadsByConnection[firstConnection.id, default: []].map(\.id)
      let renderedFirstInbox = await releaseWaitForRenderedThreads(
        firstInboxIds,
        driver: releaseBudgetDriver,
        budgetScale: presentationBudgetScale,
        view: launchHost.view
      )
      #expect(renderedFirstInbox)
      launchSamples.append(releaseElapsedMilliseconds(from: launchStart, clock: clock))

      let secondInboxIds = threadsByConnection[secondConnection.id, default: []].map(\.id)
      let profileSwitchStart = clock.now
      var renderedWorkProfile = false
      let profileSwitchMainActorStall = await releaseMainThreadStall {
        releaseBudgetDriver.selectProfile(workProfileId)
        renderedWorkProfile = await releaseWaitForRenderedThreads(
          secondInboxIds,
          driver: releaseBudgetDriver,
          budgetScale: presentationBudgetScale,
          view: launchHost.view
        )
      }
      #expect(renderedWorkProfile)
      #expect(releaseBudgetDriver.activeProfileId == workProfileId)
      #expect(releaseBudgetDriver.activeProfileRecordScope == workProfile.recordScope)
      profileSwitchSamples.append(
        releaseElapsedMilliseconds(from: profileSwitchStart, clock: clock)
      )
      profileSwitchMainActorStalls.append(profileSwitchMainActorStall)

      let switchStart = clock.now
      releaseBudgetDriver.selectMailbox(
        .connection(secondConnection.id, .role(.inbox))
      )
      let renderedSecondInbox = await releaseWaitForRenderedThreads(
        secondInboxIds,
        driver: releaseBudgetDriver,
        budgetScale: presentationBudgetScale,
        view: launchHost.view
      )
      #expect(renderedSecondInbox)
      mailboxSwitchSamples.append(releaseElapsedMilliseconds(from: switchStart, clock: clock))

      let mailViewSwitchStart = clock.now
      releaseBudgetDriver.selectMailView(.category("system:flights"))
      let flightIds = threadsByConnection[secondConnection.id, default: []]
        .filter { thread in
          thread.messages.contains {
            $0.messageCategoryIds.contains("system:flights")
          }
        }
        .map(\.id)
      #expect(flightIds.count == 25)
      let renderedFlightView = await releaseWaitForRenderedThreads(
        flightIds,
        driver: releaseBudgetDriver,
        budgetScale: presentationBudgetScale,
        view: launchHost.view
      )
      #expect(renderedFlightView)
      mailViewSwitchSamples.append(
        releaseElapsedMilliseconds(from: mailViewSwitchStart, clock: clock)
      )
      releaseBudgetDriver.selectMailView(.important)
      let renderedRestoredInbox = await releaseWaitForRenderedThreads(
        secondInboxIds,
        driver: releaseBudgetDriver,
        budgetScale: presentationBudgetScale,
        view: launchHost.view
      )
      #expect(renderedRestoredInbox)

      let bodyStart = clock.now
      var bodyLoaded = false
      bodyHost.rootView = ReleaseMessageBodyHarness(
        loadId: UUID(),
        onLoaded: { bodyLoaded = true },
        load: {
          try await adapter.loadMessageBody(message: bodyMessage, session: self.session)
        }
      )
      bodyWindow.makeKeyAndVisible()
      let bodyRendered = await releaseWaitForRenderedContent(
        in: bodyHost.view,
        budgetScale: presentationBudgetScale,
        isReady: { bodyLoaded }
      )
      #expect(bodyRendered)
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
      let draftWindow = try releaseFixtureWindow(hosting: draftHost)
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
      launchWindow.isHidden = true
      bodyWindow.isHidden = true
      draftWindow.isHidden = true
    }

    var providerLatencySamples: [Double] = []
    for connection in connections {
      let providerStart = clock.now
      _ = try await productionSyncAdapter.syncInbox(connection: connection, session: session)
      providerLatencySamples.append(releaseElapsedMilliseconds(from: providerStart, clock: clock))
    }
    var categorizationStartupSamplesByConnection: [MailboxConnectionId: [Double]] = [:]
    var syncAndCategorizationMainActorStalls: [Double] = []
    for (connection, status) in zip(connections, connectionStatuses) {
      for _ in 0..<10 {
        let sample = try await releaseCategorizationStartupSample(
          clock: clock,
          connection: connection,
          keyMaterial: keyMaterial,
          session: session,
          status: status
        )
        categorizationStartupSamplesByConnection[connection.id, default: []].append(
          sample.durationMilliseconds
        )
        syncAndCategorizationMainActorStalls.append(sample.mainActorStallMilliseconds)
        #expect(sample.messageCount == 50)
        #expect(sample.flightMessageCount == 13)
        #expect(sample.inviteMessageCount == 12)
        #expect(sample.newsletterAndPromotionMessageCount == 12)
        #expect(sample.orderMessageCount == 13)
        #expect(sample.assignmentPayloadCount == 50)
        #expect(sample.loadedEncryptedPayloadCount > 0)
        #expect(sample.savedBackgroundContextCount == 1)
      }
    }
    let rolloutConnections = providerRolloutConnections(
      productAccountId: session.productAccountId
    )
    let providerRolloutThreadsByConnection = Dictionary(
      uniqueKeysWithValues: rolloutConnections.map { connection in
        (
          connection.id,
          (0..<50).map { index in
            mailShellThread(
              connectionId: connection.id,
              providerMessageId: "release-message-\(index)",
              providerThreadId: "release-thread-\(index)",
              receivedAt: Int64(index)
            )
          }
        )
      }
    )
    let providerRolloutThreads = providerRolloutThreadsByConnection.values.flatMap { $0 }
    let providerRolloutConnectionIds = Set(rolloutConnections.map(\.id))
    let providerRolloutNavigation = MailboxNavigationSnapshot(
      messagesByConnection: providerRolloutThreadsByConnection.mapValues { $0.flatMap(\.messages) },
      pinnedThreadIds: [],
      snoozedThreadIds: [],
      outboxStates: []
    )
    var providerRolloutAggregationSamples: [Double] = []
    for _ in 0..<20 {
      let providerRolloutSelection = MailShellSelectionModel()
      providerRolloutSelection.selectUnifiedInbox()
      let aggregationStart = clock.now
      providerRolloutSelection.replaceUnifiedThreads(
        providerRolloutThreads,
        connectionIds: providerRolloutConnectionIds
      )
      let items = providerRolloutSelection.threadListItems(
        connections: rolloutConnections
      )
      _ = providerRolloutNavigation.count(for: .inbox)
      #expect(items.count == 250)
      providerRolloutAggregationSamples.append(
        releaseElapsedMilliseconds(from: aggregationStart, clock: clock)
      )
    }
    let providerRolloutMainActorStall = await releaseMainThreadStall {
      for _ in 0..<20 {
        let providerRolloutSelection = MailShellSelectionModel()
        providerRolloutSelection.selectUnifiedInbox()
        providerRolloutSelection.replaceUnifiedThreads(
          providerRolloutThreads,
          connectionIds: providerRolloutConnectionIds
        )
        _ = providerRolloutSelection.threadListItems(connections: rolloutConnections)
        _ = providerRolloutNavigation.count(for: .inbox)
        await Task.yield()
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

    #expect(releaseP95(launchSamples) < 1_000 * presentationBudgetScale)
    #expect(releaseP95(profileSwitchSamples) < 200 * presentationBudgetScale)
    #expect(profileSwitchMainActorStalls.max() ?? .infinity < 100)
    #expect(releaseP95(mailboxSwitchSamples) < 200 * presentationBudgetScale)
    #expect(releaseP95(mailViewSwitchSamples) < 200 * presentationBudgetScale)
    #expect(releaseP95(bodyOpenSamples) < 200 * presentationBudgetScale)
    #expect(releaseP95(emptyDraftOpenSamples) < 300 * presentationBudgetScale)
    #expect(releaseP95(warmDraftOpenSamples) < 200 * presentationBudgetScale)
    #expect(releaseP95(directInputFeedbackSamples) < 34 * presentationBudgetScale)
    #expect(releaseP95(formattingFeedbackSamples) < 34 * presentationBudgetScale)
    #expect(releaseP95(providerRolloutAggregationSamples) < 200 * presentationBudgetScale)
    for samples in categorizationStartupSamplesByConnection.values {
      #expect(samples.count == 10)
      #expect(releaseP95(samples) < 1_000)
    }
    #expect(syncAndCategorizationMainActorStalls.max() ?? .infinity < 100)
    #expect(providerRolloutMainActorStall < 100)
    #expect(unreadCountingMainActorStall < 100)
    #expect(formattingMainActorStall < 100)
    #expect(draftAutosaveMainActorStall < 100)
    #expect(threadsByConnection.values.map(\.count).sorted() == [50, 50])
    #expect(
      providerRolloutThreadsByConnection.values.map(\.count).sorted() == [50, 50, 50, 50, 50])
    let categorizationStartupP95 = try requireValue(
      categorizationStartupSamplesByConnection.values.map(releaseP95).max())
    let syncAndCategorizationMainActorStall = try requireValue(
      syncAndCategorizationMainActorStalls.max())
    print(
      "Gmail-first release ms: launch p95=\(releaseP95(launchSamples)), "
        + "Profile switch p95=\(releaseP95(profileSwitchSamples)), "
        + "Profile switch main max=\(profileSwitchMainActorStalls.max() ?? .infinity), "
        + "mailbox switch p95=\(releaseP95(mailboxSwitchSamples)), "
        + "Mail View switch p95=\(releaseP95(mailViewSwitchSamples)), "
        + "body p95=\(releaseP95(bodyOpenSamples)), "
        + "empty Draft p95=\(releaseP95(emptyDraftOpenSamples)), "
        + "warm Draft p95=\(releaseP95(warmDraftOpenSamples)), "
        + "input frame p95=\(releaseP95(directInputFeedbackSamples)), "
        + "format frame p95=\(releaseP95(formattingFeedbackSamples)), "
        + "categorization startup max per-connection p95=\(categorizationStartupP95) "
        + "for 10 fresh starts x 2 connections x 50 messages, "
        + "sync + categorization main max=\(syncAndCategorizationMainActorStall), "
        + "mixed-provider aggregation p95=\(releaseP95(providerRolloutAggregationSamples)) "
        + "for 5 connections x 50 messages, "
        + "mixed-provider aggregation main max=\(providerRolloutMainActorStall), "
        + "unread main max=\(unreadCountingMainActorStall), "
        + "format main max=\(formattingMainActorStall), "
        + "Draft autosave main max=\(draftAutosaveMainActorStall), "
        + "provider seam p95=\(releaseP95(providerLatencySamples)) (reported separately)"
    )
  }
  // swiftlint:enable cyclomatic_complexity function_body_length

  @MainActor
  @Test
  func testReleaseBudgetDriverIgnoresStaleRendersAfterShellReappears() {
    let driver = MailShellReleaseBudgetDriver()
    let firstOwner = UUID()
    let secondOwner = UUID()
    let staleId = MailboxThreadIdentity(
      connectionId: adapterConnectionId,
      providerThreadId: "stale-thread"
    )
    let currentId = MailboxThreadIdentity(
      connectionId: adapterConnectionId,
      providerThreadId: "current-thread"
    )

    driver.installSelectionHandler(owner: firstOwner, mailbox: { _ in }, mailView: { _ in })
    driver.recordRenderedItemId(staleId, owner: firstOwner)
    #expect(driver.renderedItemIds == [staleId])

    driver.removeSelectionHandler(owner: firstOwner)
    driver.installSelectionHandler(owner: secondOwner, mailbox: { _ in }, mailView: { _ in })
    driver.recordRenderedItemId(staleId, owner: firstOwner)
    driver.recordRenderedItemId(currentId, owner: secondOwner)

    #expect(driver.renderedItemIds == [currentId])
  }

  @Test
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

    #expect(viewModel.threads.count == 2)
    #expect(Set(viewModel.threads.map(\.id)) == [firstThread.id, secondThread.id])
  }

  @Test
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

    #expect(viewModel.selectedThreadId == selectedThread.id)
    #expect(viewModel.threads.map(\.id) == [insertedThread.id, selectedThread.id, otherThread.id])

    viewModel.updateThreads([], for: firstConnection.id)

    #expect(viewModel.selectedThreadId == nil)
  }

  @Test
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

    #expect(
      viewModel.bulkProviderActions(connections: [firstConnection, secondConnection]) == [
        .delete, .markRead,
      ])
    let batches = viewModel.bulkActionBatches(
      connections: [firstConnection, secondConnection],
      pinnedThreadIds: []
    )
    #expect(batches.map(\.connection.id) == [firstConnection.id, secondConnection.id])
    #expect(
      batches.map { $0.messages.map(\.id) } == [
        [firstThread.latestMessage.id], [secondThread.latestMessage.id],
      ])
  }

  @Test
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

    #expect(destinations.map(\.title) == ["Projects"])
    #expect(
      destinations.first?.providerMailboxIdsByConnection == [
        firstConnection.id: "Label_101", secondConnection.id: "Label_201",
      ])
    #expect(
      destinations.first?.targeting(batches)?.map(\.targetProviderMailboxId) == [
        "Label_101", "Label_201",
      ])
    #expect(
      destinations.first?.targeting(batches)?.map(\.targetProviderStateIds) == [
        ["SPAM"], ["TRASH"],
      ])
    #expect(destinations.first?.targeting([batches[0]]) == nil)
  }

  @Test
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

    #expect(viewModel.selectedThreadIds == [firstThread.id, secondThread.id])
    #expect(viewModel.selectedThreadId == nil)

    viewModel.updateThreads([], for: adapterConnectionId)

    #expect(viewModel.selectedThreadIds == [secondThread.id])
    #expect(viewModel.selectedThreadId == secondThread.id)
  }

  @Test
  func testUnifiedInboxRefreshVisibilityRequiresInboxAndAuthorizedSynchronizableConnection() {
    let authorizedConnection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let authorizationRequiredConnection =
      RecordingAdapterConnectionService.status.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .required
      )

    #expect(
      MailShellThreadList.showsUnifiedInboxRefreshButton(
        mailboxSelection: .unified(.inbox),
        connections: [authorizedConnection]
      ))
    #expect(
      !(MailShellThreadList.showsUnifiedInboxRefreshButton(
        mailboxSelection: .unified(.sent),
        connections: [authorizedConnection]
      )))
    #expect(
      !(MailShellThreadList.showsUnifiedInboxRefreshButton(
        mailboxSelection: .unified(.inbox),
        connections: [authorizationRequiredConnection]
      )))
  }

  @Test
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
      pinnedThreadIds: [firstMessages[2].threadIdentity],
      snoozedThreadIds: [],
      outboxStates: []
    )

    #expect(snapshot.count(for: .inbox) == MailboxItemCount(itemCount: 2, unreadCount: 1))
    #expect(snapshot.count(for: .pins) == MailboxItemCount(itemCount: 1, unreadCount: 0))
    #expect(snapshot.count(for: .drafts) == MailboxItemCount(itemCount: 1, unreadCount: 0))
    #expect(snapshot.count(for: .sent) == MailboxItemCount(itemCount: 1, unreadCount: 0))
    #expect(snapshot.count(for: .archive) == MailboxItemCount(itemCount: 1, unreadCount: 0))
    #expect(snapshot.count(for: .allMail) == MailboxItemCount(itemCount: 5, unreadCount: 1))
    #expect(snapshot.count(for: .spam) == MailboxItemCount(itemCount: 1, unreadCount: 1))
    #expect(snapshot.count(for: .trash) == MailboxItemCount(itemCount: 1, unreadCount: 0))
    #expect(snapshot.providerMailboxIds(for: adapterConnectionId) == ["Label_projects"])
    #expect(snapshot.providerMailboxIds(for: secondConnectionId).isEmpty)
  }

  @Test
  func testSpamAndTrashHideSidebarMessageCounts() {
    #expect(UnifiedMailbox.inbox.showsSidebarMessageCount)
    #expect(UnifiedMailbox.allMail.showsSidebarMessageCount)
    #expect(!UnifiedMailbox.spam.showsSidebarMessageCount)
    #expect(!UnifiedMailbox.trash.showsSidebarMessageCount)
  }

  @Test
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

    #expect(
      result.projected(to: .role(.inbox), snoozedThreadIds: []).messages == [message])
    #expect(
      result.projected(to: .providerMailbox("Label_projects"), snoozedThreadIds: []).messages
        == [message])
    #expect(result.projected(to: .role(.archive), snoozedThreadIds: []).messages.isEmpty)
    #expect(result.messages.first?.providerStateIds == ["INBOX", "UNREAD", "Label_projects"])
  }

  @Test
  func testContextualMoveFromProviderMailboxRequiresCompatibleConnection() {
    let gmailActions = MailShellConversationReader.contextualProviderActions(
      supported: [.move],
      messages: [],
      collection: .providerMailbox("Label_projects"),
      allowsMove: true,
      allowsProviderMailboxMove: true
    )
    let graphActions = MailShellConversationReader.contextualProviderActions(
      supported: [.move],
      messages: [],
      collection: .providerMailbox("graph-folder-projects"),
      allowsMove: true,
      allowsProviderMailboxMove: true
    )

    #expect(gmailActions.contains(.move))
    #expect(graphActions.contains(.move))
    #expect(MailShellConversationReader.allowsMoveFromProviderMailbox(.gmail))
    #expect(MailShellConversationReader.allowsMoveFromProviderMailbox(.microsoftGraph))
    #expect(MailShellConversationReader.allowsMoveFromProviderMailbox(.exchangeWebServices))

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

    #expect(archiveActions == [.delete])
    #expect(
      MailboxMessageCollection.providerMailboxIds(in: [archiveMessage]) == [
        EWSProviderMessage.customFolderStateId("archive-projects")
      ])
  }

  @Test
  func testConversationReaderAlignsMessagesBySentState() {
    #expect(
      MailShellConversationReader.messageHorizontalPlacement(providerStateIds: ["SENT"])
        == .trailing)
    #expect(
      MailShellConversationReader.messageHorizontalPlacement(providerStateIds: ["INBOX"])
        == .leading)
  }

  @Test
  func testConversationReaderShowsCategoryMenuForGmailInboxOnly() {
    #expect(
      MailShellConversationReader.showsCategoryMenu(
        providerId: .gmail,
        providerStateIds: ["INBOX"]
      ))
    #expect(
      !(MailShellConversationReader.showsCategoryMenu(
        providerId: .microsoftGraph,
        providerStateIds: ["INBOX"]
      )))
    #expect(
      !(MailShellConversationReader.showsCategoryMenu(
        providerId: .gmail,
        providerStateIds: ["SENT"]
      )))
  }

  @Test
  func testConversationReaderDisablesCategoryMenuWhileBusy() {
    #expect(
      MailShellConversationReader.isCategoryMenuDisabled(
        isConnectionBusy: true,
        isAssigningCategory: false
      ))
    #expect(
      MailShellConversationReader.isCategoryMenuDisabled(
        isConnectionBusy: false,
        isAssigningCategory: true
      ))
    #expect(
      !(MailShellConversationReader.isCategoryMenuDisabled(
        isConnectionBusy: false,
        isAssigningCategory: false
      )))
  }

  @Test
  func testConversationReaderKeepsForwardEnabledWhenBodyTextWasEvicted() {
    #expect(
      !(MailShellConversationReader.isForwardDisabled(
        readerMutationIsDisabled: false,
        isLoadingMessageBody: false
      )))
    #expect(
      MailShellConversationReader.isForwardDisabled(
        readerMutationIsDisabled: false,
        isLoadingMessageBody: true
      ))
  }

  @Test
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

    #expect(spamActions == [.notSpam])
    #expect(trashActions == [.restore])
  }

  @Test
  func testProviderSpecificGmailLabelsRemainConnectionScoped() {
    let message = mailShellMessage(
      providerMessageId: "message-001",
      providerThreadId: "thread-001",
      receivedAt: 100,
      providerStateIds: ["INBOX", "IMPORTANT", "STARRED", "CATEGORY_UPDATES", "Label_projects"]
    )
    let snapshot = MailboxNavigationSnapshot(
      messagesByConnection: [adapterConnectionId: [message]],
      pinnedThreadIds: [],
      snoozedThreadIds: [],
      outboxStates: [],
      providerMailboxesByConnection: [
        adapterConnectionId: [
          ProviderMailbox(id: "Label_empty", title: "Empty label"),
          ProviderMailbox(id: "Label_projects", title: "Projects"),
        ]
      ]
    )

    #expect(
      snapshot.providerMailboxIds(for: adapterConnectionId) == ["Label_empty", "Label_projects"])
    #expect(
      snapshot.providerMailboxes(for: adapterConnectionId).first {
        $0.id == "Label_projects"
      }?.title == "Projects")
    #expect(!(MailboxMessageCollection.isProviderMailboxId("STARRED")))
  }

  @Test
  func testOutboxNavigationIsConditionalOnActionableDeliveryState() {
    #expect(
      !(MailboxNavigationSnapshot(
        messagesByConnection: [:],
        pinnedThreadIds: [],
        snoozedThreadIds: [],
        outboxStates: []
      ).showsOutbox))
    #expect(
      !(MailboxNavigationSnapshot(
        messagesByConnection: [:],
        pinnedThreadIds: [],
        snoozedThreadIds: [],
        outboxStates: [.sent]
      ).showsOutbox))
    #expect(
      MailboxNavigationSnapshot(
        messagesByConnection: [:],
        pinnedThreadIds: [],
        snoozedThreadIds: [],
        outboxStates: [.pending, .retrying, .failed]
      ).showsOutbox)
  }

  @Test
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
      pinnedThreadIds: [],
      snoozedThreadIds: [],
      outboxStates: []
    )
    let after = MailboxNavigationSnapshot(
      messagesByConnection: [adapterConnectionId: [archivedMessage]],
      pinnedThreadIds: [],
      snoozedThreadIds: [],
      outboxStates: []
    )

    #expect(before.count(for: .inbox).itemCount == 1)
    #expect(before.count(for: .archive).itemCount == 0)
    #expect(after.count(for: .inbox).itemCount == 0)
    #expect(after.count(for: .archive).itemCount == 1)
  }

  @Test
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
    #expect(viewModel.selectedMailboxMessages(in: thread, pinnedThreadIds: []) == [sentMessage])

    viewModel.selectMailbox(
      connectionId: adapterConnectionId,
      collection: .providerMailbox("Label_projects")
    )
    #expect(viewModel.selectedMailboxMessages(in: thread, pinnedThreadIds: []) == [sentMessage])
    viewModel.updateThreads([thread], for: adapterConnectionId)
    viewModel.selectThread(thread.id)
    #expect(
      viewModel.bulkActionBatches(
        connections: [
          mailShellConnection(
            emailAddress: "reader@example.com",
            providerAccountIdentifier: "gmail-user-001",
            productAccountId: session.productAccountId
          )
        ],
        pinnedThreadIds: []
      ).first?.sourceProviderMailboxId == "Label_projects")

    viewModel.selectUnifiedMailbox(.pins)
    #expect(
      viewModel.selectedMailboxMessages(
        in: thread,
        pinnedThreadIds: [sentMessage.threadIdentity]
      ) == thread.messages)
  }

  @Test
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
      pinnedThreadIds: []
    )
    let actions = MailShellConversationReader.contextualProviderActions(
      supported: [.move, .spam],
      messages: selectedMessages,
      collection: .role(.inbox),
      allowsMove: true,
      allowsProviderMailboxMove: true
    )

    #expect(selectedMessages == [inboxMessage])
    #expect(actions == [.move, .spam])
  }

  @Test
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

    #expect(viewModel.selectedConnectionId == otherConnectionId)
    #expect(viewModel.threads.isEmpty)
    #expect(viewModel.selectedThreadId == nil)
    #expect(viewModel.navigationLevel == .threadList)
    #expect(viewModel.preferredCompactColumn == .content)
  }

  @Test
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

    #expect(viewModel.selectedThreadId == nil)
    #expect(viewModel.navigationLevel == .threadList)
  }

  @Test
  func testConversationReaderToolbarKeepsAdaptiveActionOrder() {
    let compactActions = MailShellReaderToolbarLayout.actions(
      isCompact: true,
      canReply: true,
      canReplyAll: true,
      canForward: true,
      canCategorize: true,
      providerActions: [.archive, .delete, .move, .spam]
    )
    let regularActions = MailShellReaderToolbarLayout.actions(
      isCompact: false,
      canReply: true,
      canReplyAll: true,
      canForward: true,
      canCategorize: true,
      providerActions: [.archive, .delete, .move, .spam]
    )

    #expect(compactActions == [.reply, .more])
    #expect(
      regularActions == [.reply, .replyAll, .forward, .category, .archive, .delete, .pin, .more]
    )

    let reducedCompactActions = MailShellReaderToolbarLayout.actions(
      isCompact: true,
      canReply: true,
      canReplyAll: false,
      canForward: true,
      canCategorize: true,
      providerActions: []
    )
    let reducedRegularActions = MailShellReaderToolbarLayout.actions(
      isCompact: false,
      canReply: true,
      canReplyAll: false,
      canForward: true,
      canCategorize: true,
      providerActions: []
    )

    #expect(reducedCompactActions == [.reply, .more])
    #expect(reducedRegularActions == [.reply, .forward, .category, .pin, .more])
  }

  @Test
  func testConversationReaderToolbarUsesActualDetailWidth() {
    #expect(
      MailShellReaderToolbarLayout.usesCompactActions(
        isCompactSizeClass: true,
        availableWidth: 900
      ))
    #expect(
      MailShellReaderToolbarLayout.usesCompactActions(
        isCompactSizeClass: false,
        availableWidth: 600
      ))
    #expect(
      !MailShellReaderToolbarLayout.usesCompactActions(
        isCompactSizeClass: false,
        availableWidth: 900
      ))
  }

  @Test
  func testMessageCategorySelectionStartsFromMembershipsAndFiltersChoices() {
    var message = mailShellMessage(
      providerMessageId: "message-categories",
      providerThreadId: "thread-001",
      receivedAt: 100
    )
    message.categoryIds = ["system:flights", "custom:travel"]
    var selection = MessageCategorySelection(message: message)
    let choices = [
      MessageCategoryChoice(id: "system:flights", name: "Flights"),
      MessageCategoryChoice(id: "system:invoices", name: "Orders"),
      MessageCategoryChoice(id: "custom:travel", name: "Travel planning"),
    ]

    #expect(selection.selectedCategoryIds == ["system:flights", "custom:travel"])
    selection.retainAvailableChoices(Array(choices.dropLast()))
    #expect(selection.selectedCategoryIds == ["system:flights"])
    selection.toggle("system:flights")
    #expect(selection.selectedCategoryIds.isEmpty)
    #expect(selection.filteredChoices(choices, query: "travel").map(\.id) == ["custom:travel"])
  }

  @Test
  func testMailShellReplyAndForwardDraftsKeepSourceConnectionIdentity() {
    let message = mailShellMessage(
      providerMessageId: "message-001",
      providerThreadId: "thread-001",
      receivedAt: 100
    )

    let reply = MailShellCompositionDraft.reply(to: message)
    let replyWithQuote = MailShellCompositionDraft.reply(
      to: message,
      quotedText: "Earlier line\nSecond line"
    )
    let replyAll = MailShellCompositionDraft.replyAll(
      to: message,
      senderAddress: "reader@example.com"
    )
    let forward = MailShellCompositionDraft.forward(message, body: "Decrypted body")

    #expect(reply.connectionId == message.connectionId)
    #expect(reply.sourceThreadId == message.threadIdentity)
    #expect(reply.sourceMailboxIdentity == message.connectionId.providerMailboxIdentity)
    #expect(reply.replyToMessage == message)
    #expect(reply.recipient == "sender@example.com")
    #expect(reply.subject == "Re: Subject message-001")
    #expect(replyWithQuote.body.isEmpty)
    #expect(replyWithQuote.quotedText == "Earlier line\nSecond line")
    #expect(replyWithQuote.deliveryBody == "> Earlier line\n> Second line")
    var authoredReply = replyWithQuote
    authoredReply.body = "My answer"
    #expect(authoredReply.deliveryBody == "My answer\n\n> Earlier line\n> Second line")
    #expect(replyAll.connectionId == message.connectionId)
    #expect(replyAll.recipient == "sender@example.com")
    #expect(forward.connectionId == message.connectionId)
    #expect(forward.sourceThreadId == message.threadIdentity)
    #expect(forward.sourceMailboxIdentity == message.connectionId.providerMailboxIdentity)
    #expect(forward.sourceMessage == message)
    #expect(forward.replyToMessage == nil)
    #expect(forward.forwardSourceMessage == message)
    #expect(forward.subject == "Fwd: Subject message-001")
    #expect(forward.body.contains("Decrypted body"))
  }

  @Test
  func testExplicitlyDeclinedReadReceiptOverridesInitialPolicy() {
    var draft = MailShellCompositionDraft.new(defaultSendingConnectionId: nil)
    draft.requestsReadReceipt = false
    draft.hasExplicitReadReceiptChoice = true

    draft.applyInitialReadReceiptPolicy(.requestByDefault)

    #expect(!(draft.requestsReadReceipt))
  }

  @Test
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

    #expect(
      draft.recipient
        == "sender@example.com, teammate@example.com, \"Doe, Jane\" <jane@example.com>")
  }

  @Test
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

    #expect(draft.recipient == "")
  }

  @Test
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

    #expect(draft.connectionId == unavailableDefault)
  }

  @Test
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

    #expect(reply.recipient == "recipient@example.com")
  }

  @Test
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

    #expect(MailShellCompositionDraft.reply(to: message).recipient == "recipient@example.com")
  }

  @Test
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

    #expect(reply.recipient == "sender@example.com")
  }

  @Test
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
      connection: connection,
      undoSendWindow: .tenSeconds
    )

    #expect(didSend)
    #expect(service.outgoingMessage?.threadId == nil)
    #expect(service.outgoingMessage?.inReplyTo == nil)
  }

  @Test
  func testMailActionRevalidatesTrustedDeviceAtOutboxDispatch() async {
    let service = RecordingAdapterMailActionService()
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      mailActionService: service
    )
    let connection = RecordingAdapterConnectionService.status.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let viewModel = GmailMailActionViewModel(
      service: adapter,
      session: session,
      outboxService: OutboxDeliveryService(
        handoffDelayNanoseconds: 0,
        store: AdapterOutboxStore()
      ),
      revalidateTrustedDevice: { false }
    )

    let didSend = await viewModel.send(
      recipient: "reader@example.com",
      subject: "Subject",
      body: "Private body",
      replyTo: nil,
      connection: connection,
      undoSendWindow: .off
    )

    #expect(!(didSend))
    #expect(service.outgoingMessage == nil)
  }

  @Test
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
      connection: selectedConnection,
      undoSendWindow: .tenSeconds
    )
    let attempt = try requireValue(store.load(productAccountId: session.productAccountId).first)

    #expect(didSend)
    #expect(attempt.message.kind == .new)
    #expect(attempt.message.sourceProviderMessageId == nil)
    #expect(attempt.message.providerThreadId == nil)
  }

  @Test(arguments: [false, true])
  func testEditingOutboxReplyOnSameConnectionPreservesProviderReplyMetadata(
    requestsReadReceipt: Bool
  ) async throws {
    let connection = mailShellConnection(
      emailAddress: "user@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId,
      canRequestReadReceipts: true
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
        requestsReadReceipt: true,
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
      connection: connection,
      requestsReadReceipt: requestsReadReceipt,
      undoSendWindow: .tenSeconds
    )
    let replacement = try requireValue(
      store.load(productAccountId: session.productAccountId)
        .first(where: { $0.state == .pending }))

    #expect(didEdit)
    #expect(replacement.message.kind == .reply)
    #expect(replacement.message.sourceProviderMessageId == "provider-message")
    #expect(replacement.message.providerThreadId == "provider-thread")
    #expect(replacement.message.requestsReadReceipt == requestsReadReceipt)
  }

  @Test
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

    #expect(viewModel.blockedConnectionId == connection.id)
    #expect(viewModel.errorMessage == "Pending action requires attention.")
  }

  @Test
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

    #expect(viewModel.failedConnectionIds == [secondConnection.id])
    #expect(viewModel.pendingFailureConnectionId == secondConnection.id)
    #expect(viewModel.errorMessage == "second@example.com requires attention.")
  }

  @Test
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

    #expect(result?.succeededConnectionIds == [firstConnection.id])
    #expect(result?.failures.map(\.connectionId) == [secondConnection.id])
    #expect(result?.failures.map(\.messageCount) == [1])
    #expect(
      result?.failures.first?.messageIds == [
        StableProviderMessageIdentity(
          connectionId: secondConnection.id,
          providerMessageId: "message-second"
        )
      ])
    let recordedConnectionIds = await service.recordedConnectionIds()
    #expect(Set(recordedConnectionIds) == [firstConnection.id, secondConnection.id])
    #expect(
      viewModel.errorMessage == "second@example.com — Subject message-second "
        + "[\(result?.failures.first?.messageIds.first?.rawValue ?? "")]: "
        + "Authorize this Mailbox Connection on this device before accessing mail.")
  }

  @Test
  func testMailActionViewModelPreservesConnectionLevelBulkErrorsWithoutDetails() async {
    let connection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let viewModel = GmailMailActionViewModel(
      service: ConnectionPendingActionFailureService(
        selectedFailureDetails: [],
        coversSelectedMessageIds: false
      ),
      session: session
    )

    let result = await viewModel.performBulk(
      .archive,
      batches: [mailShellBulkActionBatch(connection: connection, suffix: "first", receivedAt: 200)]
    )

    #expect(result?.succeededConnectionIds.isEmpty ?? false)
    #expect(result?.failures.map(\.connectionId) == [connection.id])
    #expect(
      viewModel.errorMessage == "first@example.com — Subject message-first "
        + "[gmail:gmail-user-001:message-first]: The provider connection failed.")
  }

  @Test
  func testMailActionViewModelIgnoresUnrelatedErrorsForSuccessfulBulkBatch() async {
    let connection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )

    for errorSource in ["resume", "retry"] {
      let unrelatedError = "An older pending action failed."
      let viewModel = GmailMailActionViewModel(
        service: ConnectionPendingActionFailureService(
          resumeError: errorSource == "resume" ? unrelatedError : nil,
          retryError: errorSource == "retry" ? unrelatedError : nil,
          selectedFailureDetails: []
        ),
        session: session
      )

      let result = await viewModel.performBulk(
        .archive,
        batches: [
          mailShellBulkActionBatch(connection: connection, suffix: "first", receivedAt: 200)
        ]
      )

      #expect(
        result?.succeededConnectionIds == [connection.id],
        Comment(rawValue: errorSource)
      )
      #expect(result?.failures.isEmpty ?? false, Comment(rawValue: errorSource))
      #expect(viewModel.errorMessage == nil, Comment(rawValue: errorSource))
    }
  }

  @Test
  func testMailActionViewModelPrefersConnectionErrorWhenFailureLookupIsIncomplete() async {
    let connection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let messageId = StableProviderMessageIdentity(
      connectionId: connection.id,
      providerMessageId: "message-first"
    )
    let viewModel = GmailMailActionViewModel(
      service: ConnectionPendingActionFailureService(
        selectedFailureDetails: [
          MailboxProviderActionFailureDetail(
            description: "A matched action failed.",
            messageIds: [messageId]
          )
        ],
        coversSelectedMessageIds: false
      ),
      session: session
    )

    let result = await viewModel.performBulk(
      .archive,
      batches: [mailShellBulkActionBatch(connection: connection, suffix: "first", receivedAt: 200)]
    )

    #expect(result?.failures.map(\.messageIds) == [[messageId]])
    #expect(
      viewModel.errorMessage == "first@example.com — Subject message-first "
        + "[gmail:gmail-user-001:message-first]: The provider connection failed.")
  }

  @Test
  func testMailActionViewModelReleasesSelectionAfterIncompleteFailureLookup() async {
    let connection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let resumeStarted = expectation(description: "pending actions resume")
    let selectionReleased = expectation(description: "selection released")
    let service = DeferredBulkResumeService(
      resumeStarted: resumeStarted,
      selectionReleased: selectionReleased
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    let result = await viewModel.performBulk(
      .archive,
      batches: [mailShellBulkActionBatch(connection: connection, suffix: "first", receivedAt: 200)]
    )

    await fulfillment(of: [resumeStarted, selectionReleased], timeout: 1)
    #expect(result?.succeededConnectionIds == [connection.id])
    let releasedSelectionCount = await service.releasedSelectionCount()
    #expect(releasedSelectionCount == 1)
  }

  @Test
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

    #expect(result?.succeededConnectionIds == [connection.id])
    #expect(viewModel.errorMessage == nil)
    #expect(!(viewModel.isPerformingAction))
  }

  @Test
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
        Issue.record("Deferred batches must return before the gated cache reload")
      }
    )

    #expect(result?.succeededConnectionIds == [connection.id])
    #expect(!(result?.shouldReloadImmediately(connection.id) ?? true))
    #expect(!(viewModel.isPerformingAction))
  }

  @Test
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

    #expect(result?.succeededConnectionIds == [connection.id])
    #expect(!(viewModel.isPerformingAction))
    await fulfillment(of: [resumeStarted], timeout: 1)
    let resumeCount = await service.resumeCount()
    #expect(resumeCount == 1)
  }

  @Test
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
        #expect(completedConnection.id == connection.id)
        deferredCompletion.fulfill()
      }
    )

    #expect(result?.succeededConnectionIds == [connection.id])
    #expect(!(viewModel.isPerformingAction))
    await fulfillment(of: [resumeStarted, deferredCompletion], timeout: 1)
    let resumeCount = await service.resumeCount()
    #expect(resumeCount == 1)
  }

  @Test
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

    #expect(result?.succeededConnectionIds == [backfillingConnection.id])
    #expect(result?.failures.map(\.connectionId) == [currentConnection.id])
    #expect(
      viewModel.errorMessage == "current@example.com — Subject message-current "
        + "[gmail:gmail-user-002:message-current]: The provider connection failed.")
    await fulfillment(of: [resumesStarted], timeout: 1)
  }

  @Test
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

    #expect(result?.succeededConnectionIds == [connection.id])
    #expect(!(viewModel.isPerformingAction))
    let errorSurfaced = expectation(description: "deferred error surfaced")
    Task { @MainActor in
      while viewModel.errorMessage == nil {
        await Task.yield()
      }
      errorSurfaced.fulfill()
    }
    await fulfillment(of: [resumeStarted, errorSurfaced], timeout: 1)
    #expect(viewModel.failedConnectionIds == [connection.id])
    #expect(
      viewModel.errorMessage == "first@example.com — Subject message-first "
        + "[gmail:gmail-user-001:message-first]: The provider connection failed.")
  }

  @Test
  func testMailActionViewModelIgnoresUnrelatedDeferredConnectionError() async {
    let connection = mailShellConnection(
      emailAddress: "first@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let resumeStarted = expectation(description: "pending actions resume")
    let deferredCompletion = expectation(description: "deferred completion reported")
    let service = DeferredBulkResumeService(
      resumeStarted: resumeStarted,
      resumeError: "An older pending action failed.",
      failedConnectionId: connection.id,
      selectedFailureDetails: []
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    let result = await viewModel.performBulk(
      .archive,
      batches: [mailShellBulkActionBatch(connection: connection, suffix: "first", receivedAt: 200)],
      deferredPendingActionConnectionIds: [connection.id],
      onDeferredCompletion: { _ in
        deferredCompletion.fulfill()
      }
    )

    #expect(result?.succeededConnectionIds == [connection.id])
    await fulfillment(of: [resumeStarted, deferredCompletion], timeout: 1)
    #expect(viewModel.errorMessage == nil)
  }

  @Test
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
    let resumesCompleted = expectation(description: "pending actions completed")
    resumesCompleted.expectedFulfillmentCount = 2
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
      deferredPendingActionConnectionIds: [firstConnection.id, secondConnection.id],
      onDeferredCompletion: { _ in
        resumesCompleted.fulfill()
      }
    )

    #expect(Set(result?.succeededConnectionIds ?? []) == [firstConnection.id, secondConnection.id])
    await fulfillment(of: [resumesStarted, resumesCompleted], timeout: 1)
    #expect(
      viewModel.errorMessage == "first@example.com — Subject message-first "
        + "[gmail:gmail-user-001:message-first]: The provider connection failed.\n"
        + "second@example.com — Subject message-second "
        + "[gmail:gmail-user-002:message-second]: The provider connection failed.")
  }

  @Test
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

  @Test
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

    #expect(result?.failures.map(\.connectionId) == [currentConnection.id])
    await fulfillment(of: [resumesStarted], timeout: 1)
    let errorsSurfaced = expectation(description: "inline and deferred errors surfaced")
    Task { @MainActor in
      while viewModel.errorMessage?.contains("deferred@example.com") != true {
        await Task.yield()
      }
      errorsSurfaced.fulfill()
    }
    await fulfillment(of: [errorsSurfaced], timeout: 1)
    #expect(
      viewModel.errorMessage == "current@example.com — Subject message-current "
        + "[gmail:gmail-user-002:message-current]: The provider connection failed.\n"
        + "deferred@example.com — Subject message-deferred "
        + "[gmail:gmail-user-001:message-deferred]: The provider connection failed.")
  }

  @Test
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

    #expect(result?.failures.map(\.connectionId) == [connection.id])
    await fulfillment(of: [resumeStarted], timeout: 0.1)
    let resumeCount = await service.resumeCount()
    #expect(resumeCount == 0)
  }

  @Test
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

    #expect(result?.failures.map(\.connectionId) == [currentConnection.id])
    await fulfillment(of: [resumeStarted, deferredCompletion], timeout: 1)
    #expect(viewModel.errorMessage?.contains("current@example.com") ?? false)
  }

  @Test
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
    #expect(!(viewModel.errorMessage?.contains("current@example.com") ?? true))
  }

  @Test
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

  @Test
  // swiftlint:disable:next function_body_length
  func testMailActionViewModelPreservesReconciledFailureFromOverlappingOperation() async {
    let failedConnection = mailShellConnection(
      emailAddress: "failed@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let gatedConnection = mailShellConnection(
      emailAddress: "gated@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let overlappingConnection = mailShellConnection(
      emailAddress: "overlapping@example.com",
      providerAccountIdentifier: "gmail-user-003",
      productAccountId: session.productAccountId
    )
    let resumesStarted = expectation(description: "pending actions resume")
    resumesStarted.expectedFulfillmentCount = 3
    let failedCompletion = expectation(description: "reconciled failure recorded")
    let gatedCompletion = expectation(description: "gated operation completed")
    let overlappingCompletion = expectation(description: "overlapping operation completed")
    let resumeGate = AdapterLifecycleOperationGate()
    let failedMessageId = StableProviderMessageIdentity(
      connectionId: failedConnection.id,
      providerMessageId: "message-failed"
    )
    let service = DeferredBulkResumeService(
      resumeStarted: resumesStarted,
      resumeGate: resumeGate,
      gatedResumeConnectionId: gatedConnection.id,
      selectedFailureDetails: [
        MailboxProviderActionFailureDetail(
          description: "The provider did not confirm this action.",
          messageIds: [failedMessageId]
        )
      ],
      selectedFailureDetailsConnectionId: failedConnection.id
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    _ = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(connection: failedConnection, suffix: "failed", receivedAt: 300),
        mailShellBulkActionBatch(connection: gatedConnection, suffix: "gated", receivedAt: 200),
      ],
      deferredPendingActionConnectionIds: [failedConnection.id, gatedConnection.id],
      onDeferredCompletion: { connection in
        if connection.id == failedConnection.id {
          failedCompletion.fulfill()
        } else {
          gatedCompletion.fulfill()
        }
      }
    )
    await fulfillment(of: [failedCompletion], timeout: 1)
    #expect(viewModel.errorMessage?.contains("failed@example.com") ?? false)

    _ = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(
          connection: overlappingConnection,
          suffix: "overlapping",
          receivedAt: 100
        )
      ],
      deferredPendingActionConnectionIds: [overlappingConnection.id],
      onDeferredCompletion: { _ in overlappingCompletion.fulfill() }
    )
    await fulfillment(of: [resumesStarted, overlappingCompletion], timeout: 1)

    #expect(viewModel.errorMessage?.contains("failed@example.com") ?? false)

    await resumeGate.release()
    await fulfillment(of: [gatedCompletion], timeout: 1)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testMailActionViewModelRetainsReconciledDeferredFailureAcrossBatchCompletions() async {
    let failedConnection = mailShellConnection(
      emailAddress: "failed@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let successfulConnection = mailShellConnection(
      emailAddress: "successful@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let resumesStarted = expectation(description: "pending actions resume")
    resumesStarted.expectedFulfillmentCount = 2
    let resumesCompleted = expectation(description: "deferred resumes completed")
    resumesCompleted.expectedFulfillmentCount = 2
    let successfulResumeGate = AdapterLifecycleOperationGate()
    let failedMessageId = StableProviderMessageIdentity(
      connectionId: failedConnection.id,
      providerMessageId: "message-failed"
    )
    let service = DeferredBulkResumeService(
      resumeStarted: resumesStarted,
      resumeGate: successfulResumeGate,
      gatedResumeConnectionId: successfulConnection.id,
      selectedFailureDetails: [
        MailboxProviderActionFailureDetail(
          description: "The provider did not confirm this action.",
          messageIds: [failedMessageId]
        )
      ],
      selectedFailureDetailsConnectionId: failedConnection.id
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    _ = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(connection: failedConnection, suffix: "failed", receivedAt: 200),
        mailShellBulkActionBatch(
          connection: successfulConnection,
          suffix: "successful",
          receivedAt: 100
        ),
      ],
      deferredPendingActionConnectionIds: [failedConnection.id, successfulConnection.id],
      onDeferredCompletion: { _ in resumesCompleted.fulfill() }
    )
    await fulfillment(of: [resumesStarted], timeout: 1)
    let failureSurfaced = expectation(description: "reconciled failure surfaced")
    Task { @MainActor in
      while viewModel.errorMessage?.contains("failed@example.com") != true {
        await Task.yield()
      }
      failureSurfaced.fulfill()
    }
    await fulfillment(of: [failureSurfaced], timeout: 1)

    await successfulResumeGate.release()
    await fulfillment(of: [resumesCompleted], timeout: 1)
    #expect(viewModel.errorMessage?.contains("failed@example.com") ?? false)
  }

  @Test
  func testMailActionViewModelKeepsUndismissedDeferredFailureAfterSuccess() async {
    let failedConnection = mailShellConnection(
      emailAddress: "failed@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let successfulConnection = mailShellConnection(
      emailAddress: "successful@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let resumesStarted = expectation(description: "pending actions resume")
    resumesStarted.expectedFulfillmentCount = 2
    let deferredCompletion = expectation(description: "deferred completion recorded")
    let service = DeferredBulkResumeService(
      resumeStarted: resumesStarted,
      resumeError: "The provider connection failed.",
      resumeErrorConnectionId: failedConnection.id,
      failedConnectionId: failedConnection.id
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    _ = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(connection: failedConnection, suffix: "failed", receivedAt: 200)
      ],
      deferredPendingActionConnectionIds: [failedConnection.id],
      onDeferredCompletion: { _ in deferredCompletion.fulfill() }
    )
    await fulfillment(of: [deferredCompletion], timeout: 1)

    let result = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(
          connection: successfulConnection,
          suffix: "successful",
          receivedAt: 100
        )
      ]
    )

    await fulfillment(of: [resumesStarted], timeout: 1)
    #expect(result?.succeededConnectionIds == [successfulConnection.id])
    #expect(viewModel.errorMessage?.contains("failed@example.com") ?? false)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testMailActionViewModelKeepsCompletedReconciledFailureUntilDismissed() async {
    let failedConnection = mailShellConnection(
      emailAddress: "failed@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let successfulConnection = mailShellConnection(
      emailAddress: "successful@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let resumesStarted = expectation(description: "pending actions resume")
    resumesStarted.expectedFulfillmentCount = 2
    let deferredCompletion = expectation(description: "reconciled failure recorded")
    let failedMessageId = StableProviderMessageIdentity(
      connectionId: failedConnection.id,
      providerMessageId: "message-failed"
    )
    let service = DeferredBulkResumeService(
      resumeStarted: resumesStarted,
      selectedFailureDetails: [
        MailboxProviderActionFailureDetail(
          description: "The provider did not confirm this action.",
          messageIds: [failedMessageId]
        )
      ],
      selectedFailureDetailsConnectionId: failedConnection.id
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    _ = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(connection: failedConnection, suffix: "failed", receivedAt: 200)
      ],
      deferredPendingActionConnectionIds: [failedConnection.id],
      onDeferredCompletion: { _ in deferredCompletion.fulfill() }
    )
    await fulfillment(of: [deferredCompletion], timeout: 1)
    await Task.yield()

    let result = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(
          connection: successfulConnection,
          suffix: "successful",
          receivedAt: 100
        )
      ]
    )

    await fulfillment(of: [resumesStarted], timeout: 1)
    #expect(result?.succeededConnectionIds == [successfulConnection.id])
    #expect(viewModel.errorMessage?.contains("failed@example.com") ?? false)

    viewModel.clearError()
    #expect(viewModel.errorMessage == nil)
  }

  @Test
  func testMailActionViewModelKeepsVisibleDeferredFailureWhenLaterBulkActionFails() async {
    let failedConnection = mailShellConnection(
      emailAddress: "failed@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let currentConnection = mailShellConnection(
      emailAddress: "current@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let resumeStarted = expectation(description: "pending actions resume")
    let deferredCompletion = expectation(description: "deferred completion recorded")
    let service = DeferredBulkResumeService(
      resumeStarted: resumeStarted,
      resumeError: "The provider connection failed.",
      failedConnectionId: failedConnection.id,
      performFailureConnectionId: currentConnection.id
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    _ = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(connection: failedConnection, suffix: "failed", receivedAt: 200)
      ],
      deferredPendingActionConnectionIds: [failedConnection.id],
      onDeferredCompletion: { _ in deferredCompletion.fulfill() }
    )
    await fulfillment(of: [resumeStarted, deferredCompletion], timeout: 1)

    let result = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(connection: currentConnection, suffix: "current", receivedAt: 100)
      ]
    )

    #expect(result?.failures.map(\.connectionId) == [currentConnection.id])
    #expect(viewModel.errorMessage?.contains("failed@example.com") ?? false)
    #expect(viewModel.errorMessage?.contains("current@example.com") ?? false)
  }

  @Test
  func testMailActionViewModelDoesNotResurfaceDismissedDeferredFailureAfterSuccess() async {
    let failedConnection = mailShellConnection(
      emailAddress: "failed@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let successfulConnection = mailShellConnection(
      emailAddress: "successful@example.com",
      providerAccountIdentifier: "gmail-user-002",
      productAccountId: session.productAccountId
    )
    let resumesStarted = expectation(description: "pending actions resume")
    resumesStarted.expectedFulfillmentCount = 2
    let deferredCompletion = expectation(description: "deferred completion recorded")
    let service = DeferredBulkResumeService(
      resumeStarted: resumesStarted,
      resumeError: "The provider connection failed.",
      resumeErrorConnectionId: failedConnection.id,
      failedConnectionId: failedConnection.id
    )
    let viewModel = GmailMailActionViewModel(service: service, session: session)

    _ = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(connection: failedConnection, suffix: "failed", receivedAt: 200)
      ],
      deferredPendingActionConnectionIds: [failedConnection.id],
      onDeferredCompletion: { _ in deferredCompletion.fulfill() }
    )
    await fulfillment(of: [deferredCompletion], timeout: 1)
    #expect(viewModel.errorMessage?.contains("failed@example.com") ?? false)
    viewModel.clearError()

    let result = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(
          connection: successfulConnection,
          suffix: "successful",
          receivedAt: 100
        )
      ]
    )

    await fulfillment(of: [resumesStarted], timeout: 1)
    #expect(result?.succeededConnectionIds == [successfulConnection.id])
    #expect(result?.failures == [])
    #expect(viewModel.errorMessage == nil)
  }

  @Test
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

    #expect(currentResult?.failures.map(\.connectionId) == [currentConnection.id])
    await fulfillment(of: [resumesStarted], timeout: 1)
    await resumeGate.release()
    await fulfillment(of: [deferredCompletion], timeout: 1)
    #expect(viewModel.errorMessage?.contains("current@example.com") ?? false)
  }

  @Test
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

  @Test
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
    let releasedSelectionCount = await service.releasedSelectionCount()
    #expect(resumeWasCancelled)
    #expect(releasedSelectionCount == 1)
  }

  @Test
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

  @Test
  func testMailActionViewModelFinishesPreparationTriggeredByPendingAction() async {
    let preparationCompleted = expectation(description: "sign-out preparation completes")
    let viewModel = GmailMailActionViewModel(
      service: ConnectionPendingActionFailureService(),
      session: session,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )

    viewModel.startPendingAction {
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          await viewModel.prepareForSignOut()
        }
        await group.waitForAll()
      }
      preparationCompleted.fulfill()
    }

    await fulfillment(of: [preparationCompleted], timeout: 0.1)
  }

  @Test
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

  @Test
  func testMailActionViewModelRejectsSendAfterSignOutBegins() async {
    let viewModel = GmailMailActionViewModel(
      service: ConnectionPendingActionFailureService(),
      session: session,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )
    let connection = mailShellConnection(
      emailAddress: "sender@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let didSendBeforeSignOut = await viewModel.send(
      recipient: "reader@example.com",
      subject: "Subject",
      body: "Private body",
      replyTo: nil,
      connection: connection,
      undoSendWindow: .tenSeconds
    )
    #expect(didSendBeforeSignOut)
    viewModel.beginPreparingForSignOut()

    let didSend = await viewModel.send(
      recipient: "reader@example.com",
      subject: "Subject",
      body: "Private body",
      replyTo: nil,
      connection: connection,
      undoSendWindow: .tenSeconds
    )

    #expect(!(didSend))
  }

  @Test
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
      sourceProviderMailboxId: "provider-mailbox:source",
      targetProviderMailboxId: "provider-mailbox:deleted-child",
      targetProviderStateIds: ["TRASH"],
      for: [message],
      connection: connection
    )

    #expect(didPerform)
    let sourceProviderMailboxIds = await service.recordedSourceProviderMailboxIds()
    #expect(sourceProviderMailboxIds == ["provider-mailbox:source"])
    let targetProviderStateIds = await service.recordedTargetProviderStateIds()
    #expect(targetProviderStateIds == [["TRASH"]])
  }

  @Test
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

    #expect(result?.failures.map(\.connectionId) == [secondConnection.id])
    #expect(viewModel.blockedConnectionId == secondConnection.id)

    await viewModel.retryBlockedAction(connection: secondConnection)

    #expect(viewModel.blockedConnectionId == nil)
    #expect(viewModel.errorMessage == nil)
    let retryCount = await service.retryCount()
    #expect(retryCount == 1)
  }

  @Test
  func testMailActionViewModelRevalidatesImmediatelyBeforeBulkDispatch() async {
    let connection = mailShellConnection(
      emailAddress: "sender@example.com",
      providerAccountIdentifier: "gmail-user-001",
      productAccountId: session.productAccountId
    )
    let service = RevocationFencedBulkMailActionService()
    var revalidationCount = 0
    let viewModel = GmailMailActionViewModel(
      service: service,
      session: session,
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore()),
      revalidateTrustedDevice: {
        revalidationCount += 1
        return false
      }
    )

    let result = await viewModel.performBulk(
      .archive,
      batches: [
        mailShellBulkActionBatch(
          connection: connection,
          suffix: "revoked-before-dispatch",
          receivedAt: 100
        )
      ]
    )

    let resumeCount = await service.resumeCount
    #expect(result != nil)
    #expect(revalidationCount == 1)
    #expect(resumeCount == 0)
  }

  @Test
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
    #expect(
      viewModel.bulkActionProgress
        == MailboxBulkActionProgress(
          action: .markRead,
          completedConnectionCount: 1,
          totalConnectionCount: 2
        ))
    selection.updateThreads([], for: firstConnection.id)
    #expect(selection.selectedThreadIds == [secondThread.id])
    #expect(
      viewModel.bulkActionProgress
        == MailboxBulkActionProgress(
          action: .markRead,
          completedConnectionCount: 1,
          totalConnectionCount: 2
        ))
    await service.release()
    let result = await task.value

    #expect(Set(result?.succeededConnectionIds ?? []) == [firstConnection.id, secondConnection.id])
    #expect(viewModel.bulkActionProgress == nil)
  }

  @Test
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

    #expect(thread.inboxMessages == [unknownMessage, inboxMessage])
  }

}

@Suite(.serialized)
final class ThreadPresentationRegressionTests {
  @Test
  func testThreadReaderKeepsQuotedContextInOldestMessageOnly() {
    let newest = mailShellMessage(
      providerMessageId: "message-newest",
      providerThreadId: "thread-001",
      receivedAt: 200
    )
    let oldest = mailShellMessage(
      providerMessageId: "message-oldest",
      providerThreadId: "thread-001",
      receivedAt: 100
    )
    let thread = mailShellThread(
      providerThreadId: "thread-001",
      messages: [oldest, newest]
    )

    #expect(MailShellConversationReader.removesQuotedReplies(from: newest, in: thread))
    #expect(!(MailShellConversationReader.removesQuotedReplies(from: oldest, in: thread)))
  }

  @Test
  func testThreadHTMLPresentationOmitsQuotedReplyHistory() throws {
    let html =
      """
      <p>New reply</p>
      <blockquote><p>Customer quotation</p></blockquote>
      <div class="gmail_quote">
        <div class="gmail_attr">On 11 Aug, Sender wrote:</div>
        <blockquote><p>Previous message</p></blockquote>
      </div>
      <div>On 10 Aug, Sender wrote:</div>
      <blockquote><p>Earlier message</p></blockquote>
      <div>On 9 Aug, Sender wrote:</div>
      <br>
      <blockquote><p>Oldest message</p></blockquote>
      On 8 Aug, Sender wrote:<br>
      <blockquote><p>Text-node attributed message</p></blockquote>
      <div>On 7 Aug, Sender &lt;sender@example.com&gt; wrote:</div>
      <div><p>Unwrapped quoted message</p></div>
      On 6 Aug, Sender wrote:<br>
      <div><p>Text-node attributed unwrapped message</p></div>
      <div>
        <p>Wrapped new reply</p>
        On 5 Aug, Sender wrote:<br>
        <div><p>Wrapped previous message</p></div>
      </div>
      """
    let singleMessageResult = try requireValue(MessageHTMLSanitizer.sanitize(html))
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(html, removesQuotedReplies: true))

    #expect(singleMessageResult.documentHTML.contains("Previous message"))
    #expect(result.documentHTML.contains("New reply"))
    #expect(result.documentHTML.contains("Customer quotation"))
    #expect(!(result.documentHTML.contains("Previous message")))
    #expect(!(result.documentHTML.contains("Earlier message")))
    #expect(!(result.documentHTML.contains("Oldest message")))
    #expect(!(result.documentHTML.contains("Text-node attributed message")))
    #expect(!(result.documentHTML.contains("Unwrapped quoted message")))
    #expect(!(result.documentHTML.contains("Text-node attributed unwrapped message")))
    #expect(result.documentHTML.contains("Wrapped new reply"))
    #expect(!(result.documentHTML.contains("Wrapped previous message")))
    #expect(!(result.documentHTML.contains("Sender wrote")))
  }

  @Test
  func testThreadHTMLPresentationIgnoresTrailingBreakAfterNestedAttribution() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div>
          <p>New reply</p>
          <div class="gmail_attr">On 11 Aug, Sender wrote:</div><br>
        </div>
        <blockquote><p>Previous message</p></blockquote>
        """,
        removesQuotedReplies: true
      ))

    #expect(result.documentHTML.contains("New reply"))
    #expect(!(result.documentHTML.contains("Previous message")))
    #expect(!(result.documentHTML.contains("Sender wrote")))
  }

  @Test
  func testThreadHTMLPresentationKeepsForwardedMessageWrappers() throws {
    let html =
      """
      <p>Forwarding this for context.</p>
      <div class="gmail_quote"><p>Forwarded Gmail message</p></div>
      <div class="moz-forward-container"><p>Forwarded Mozilla message</p></div>
      """
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(html, removesQuotedReplies: true))

    #expect(result.documentHTML.contains("Forwarded Gmail message"))
    #expect(result.documentHTML.contains("Forwarded Mozilla message"))
  }

  @Test
  func testThreadHTMLPresentationKeepsOutlookForwardedMessage() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Forwarding this for context.</p>
        <div id="divRplyFwdMsg"><b>Forwarded message</b><br>From: Sender</div>
        <p>Forwarded Outlook message body</p>
        """,
        removesQuotedReplies: true
      ))

    #expect(result.documentHTML.contains("Forwarded message"))
    #expect(result.documentHTML.contains("Forwarded Outlook message body"))
  }

  @Test
  func testThreadHTMLPresentationKeepsOriginalMessageForwards() throws {
    let outlookResult = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>FYI.</p>
        <div id="divRplyFwdMsg">
          <b>From:</b> Sender<br><b>Sent:</b> Tuesday<br><b>To:</b> Reader<br>
          <b>Subject:</b> Unprefixed original subject
        </div>
        <p>Forwarded Outlook body</p>
        """,
        removesQuotedReplies: true,
        messageSubject: "FW: Project status"
      ))
    let providerResult = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Sharing another original message.</p>
        <div class="gmail_quote">
          <div>-----Original Message-----</div>
          <p>Forwarded provider body</p>
        </div>
        """,
        removesQuotedReplies: true
      ))

    #expect(outlookResult.documentHTML.contains("Forwarded Outlook body"))
    #expect(providerResult.documentHTML.contains("Forwarded provider body"))
  }

  @Test
  func testThreadHTMLPresentationRemovesOutlookReplyHeaderAndHistory() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Thanks for the update.</p>
        <div id="divRplyFwdMsg">
          <b>From:</b> Sender<br><b>Sent:</b> Tuesday<br><b>To:</b> Reader<br>
          <b>Subject:</b> Re: Project status
        </div>
        <p>Previous Outlook reply body</p>
        """,
        removesQuotedReplies: true,
        messageSubject: "Re: Project status"
      ))

    #expect(result.documentHTML.contains("Thanks for the update"))
    #expect(!(result.documentHTML.contains("Project status")))
    #expect(!(result.documentHTML.contains("Previous Outlook reply body")))
  }

  @Test
  func testThreadHTMLPresentationKeepsGmailForwardedMessage() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>Forwarding this for context.</p>
        <div class="gmail_quote">
          <div>
            <div class="gmail_attr">Forwarded message</div>
            <p>Forwarded Gmail message body</p>
          </div>
          <blockquote><p>Nested forwarded conversation</p></blockquote>
        </div>
        """,
        removesQuotedReplies: true
      ))

    #expect(result.documentHTML.contains("Forwarded message"))
    #expect(result.documentHTML.contains("Forwarded Gmail message body"))
    #expect(result.documentHTML.contains("Nested forwarded conversation"))
  }

  @Test
  func testThreadHTMLPresentationKeepsOtherProviderForwardedMessages() throws {
    for providerClass in ["protonmail_quote", "yahoo_quoted", "zmail_extra"] {
      let result = try requireValue(
        MessageHTMLSanitizer.sanitize(
          """
          <p>Forwarding this for context.</p>
          <div class="\(providerClass)">
            <div><div>Forwarded message</div></div>
            <p>Forwarded provider message body</p>
          </div>
          """,
          removesQuotedReplies: true
        ))

      #expect(result.documentHTML.contains("Forwarded message"))
      #expect(result.documentHTML.contains("Forwarded provider message body"))
    }
  }

  @Test
  func testThreadHTMLPresentationRemovesReplyThatQuotesForwardedMessage() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>New reply</p>
        <div class="gmail_quote">
          <div class="gmail_attr">On 11 Aug, Sender wrote:</div>
          <div>
            <div class="gmail_attr">Forwarded message</div>
            <p>Quoted forwarded Gmail message body</p>
          </div>
        </div>
        """,
        removesQuotedReplies: true
      ))

    #expect(result.documentHTML.contains("New reply"))
    #expect(!(result.documentHTML.contains("Forwarded message")))
    #expect(!(result.documentHTML.contains("Quoted forwarded Gmail message body")))
  }

  @Test
  func testThreadHTMLPresentationRemovesProviderAttributionWithQuote() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>New reply</p>
        <div class="gmail_attr">On Tuesday, Sender wrote:</div>
        <blockquote><p>Previous Gmail message</p></blockquote>
        <div class="moz-cite-prefix">Sender wrote:</div>
        <blockquote><p>Previous Mozilla message</p></blockquote>
        """,
        removesQuotedReplies: true
      ))

    #expect(result.documentHTML.contains("New reply"))
    #expect(!(result.documentHTML.contains("Sender wrote")))
    #expect(!(result.documentHTML.contains("Previous Gmail message")))
    #expect(!(result.documentHTML.contains("Previous Mozilla message")))
  }

  @Test
  func testThreadHTMLPresentationRemovesQuoteAfterWrappedAttribution() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div>
          <p>Wrapped new reply</p>
          On 5 Aug, Sender wrote:
        </div>
        <blockquote><p>Wrapped previous message</p></blockquote>
        """,
        removesQuotedReplies: true
      ))

    #expect(result.documentHTML.contains("Wrapped new reply"))
    #expect(!(result.documentHTML.contains("Wrapped previous message")))
    #expect(!(result.documentHTML.contains("Sender wrote")))
  }

  @Test
  func testThreadHTMLPresentationRemovesQuoteAfterNestedWrappedAttribution() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div>Direct new reply
          <p>Nested wrapped new reply<br></p>
          <div class="gmail_attr">On Tuesday, Sender wrote:</div>
        </div>
        <blockquote><p>Nested wrapped previous message</p></blockquote>
        """,
        removesQuotedReplies: true
      ))

    #expect(result.documentHTML.contains("Nested wrapped new reply"))
    #expect(result.documentHTML.contains("Direct new reply"))
    #expect(!(result.documentHTML.contains("Nested wrapped previous message")))
    #expect(!(result.documentHTML.contains("Sender wrote")))
  }

  @Test
  func testThreadHTMLPresentationKeepsMixedWrapperAfterNestedAttribution() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div>
          <p>Leading reply text</p>
          <div class="gmail_attr">On Tuesday, Sender wrote:</div>
          Trailing direct reply text
        </div>
        <blockquote><p>Standalone quotation</p></blockquote>
        """,
        removesQuotedReplies: true
      ))

    #expect(result.documentHTML.contains("Leading reply text"))
    #expect(result.documentHTML.contains("Sender wrote"))
    #expect(result.documentHTML.contains("Trailing direct reply text"))
    #expect(result.documentHTML.contains("Standalone quotation"))
  }

  @Test
  func testThreadHTMLPresentationKeepsProseThatResemblesAnAttribution() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>On 11 proposals, Editor wrote:</p>
        <p>Here is the draft I meant.</p>
        <p>On 11 Aug, Editor wrote:</p>
        <p>Here is a separate follow-up.</p>
        """,
        removesQuotedReplies: true
      ))

    #expect(result.documentHTML.contains("On 11 proposals, Editor wrote:"))
    #expect(result.documentHTML.contains("Here is the draft I meant."))
    #expect(result.documentHTML.contains("On 11 Aug, Editor wrote:"))
    #expect(result.documentHTML.contains("Here is a separate follow-up."))
  }

  @Test
  func testThreadHTMLPresentationSkipsInlineWrappersBeforeQuote() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>New reply</p>
        <div>On 11 Aug, Sender wrote:</div>
        <span> </span>
        <font>Quoted sender header</font>
        <blockquote><p>Previous message</p></blockquote>
        """,
        removesQuotedReplies: true
      ))

    #expect(result.documentHTML.contains("New reply"))
    #expect(!(result.documentHTML.contains("Quoted sender header")))
    #expect(!(result.documentHTML.contains("Previous message")))
  }

  @Test
  func testThreadHTMLPresentationKeepsMixedContentWithNestedQuote() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <p>On 11 Aug, Editor wrote:</p>
        <table><tr><td>
          Leading reply text
          <blockquote><p>Nested quotation</p></blockquote>
        </td></tr></table>
        """,
        removesQuotedReplies: true
      ))

    #expect(result.documentHTML.contains("On 11 Aug, Editor wrote:"))
    #expect(result.documentHTML.contains("Leading reply text"))
    #expect(result.documentHTML.contains("Nested quotation"))
  }

  @Test
  func testThreadPlainTextPresentationOmitsQuotedReplyHistory() {
    let presentation = MessageHTMLPresentation.resolve(
      body: MailboxMessageBody(
        text: "New reply\n\nOn 11 Aug, Sender wrote:\n> Previous message"
      ),
      removesQuotedReplies: true
    )

    #expect(presentation == .plainText("New reply"))
  }

  @Test
  func testThreadPlainTextPresentationOmitsWrappedReplyAttribution() {
    let presentation = MessageHTMLPresentation.resolve(
      body: MailboxMessageBody(
        text: "New reply\n\nOn 11 Aug, Sender\n<sender@example.com>, wrote:\n> Previous message"
      ),
      removesQuotedReplies: true
    )

    #expect(presentation == .plainText("New reply"))
  }

  @Test
  func testThreadPlainTextPresentationOmitsQuoteOnlyReply() {
    let presentation = MessageHTMLPresentation.resolve(
      body: MailboxMessageBody(
        text: "On 11 Aug, Sender wrote:\n> Previous message"
      ),
      removesQuotedReplies: true
    )

    #expect(presentation == .plainText(""))
  }

  @Test
  func testThreadPlainTextPresentationRecognizesSenderAddressAttribution() {
    let presentation = MessageHTMLPresentation.resolve(
      body: MailboxMessageBody(
        text: "New reply\n\nOn Tuesday, Jane Doe <jane@example.com> wrote:\n> Previous message"
      ),
      removesQuotedReplies: true
    )

    #expect(presentation == .plainText("New reply"))
  }

  @Test
  func testThreadPlainTextPresentationKeepsAttributionLikeProseWithoutQuoteBoundary() {
    let text = """
      On 11 proposals, Editor wrote:
      Here is the draft I meant.
      """
    let presentation = MessageHTMLPresentation.resolve(
      body: MailboxMessageBody(text: text),
      removesQuotedReplies: true
    )

    #expect(presentation == .plainText(text))
  }

  @Test
  func testThreadPlainTextPresentationKeepsUnquotedWhitespace() {
    let text = "  indented code\ntrailing whitespace  \n"
    let presentation = MessageHTMLPresentation.resolve(
      body: MailboxMessageBody(text: text),
      removesQuotedReplies: true
    )

    #expect(presentation == .plainText(text))
  }

  @Test
  func testThreadPlainTextPresentationKeepsIndentationBeforeQuotedReply() {
    let presentation = MessageHTMLPresentation.resolve(
      body: MailboxMessageBody(
        text: "    indented code\n\nOn Tue, Aug 11, a@example.com wrote:\n> old text"
      ),
      removesQuotedReplies: true
    )

    #expect(presentation == .plainText("    indented code"))
  }

  @Test
  func testThreadPlainTextPresentationKeepsStandaloneQuotedPassage() {
    let presentation = MessageHTMLPresentation.resolve(
      body: MailboxMessageBody(
        text: """
          Here is the requested excerpt:
          > quoted passage
          My conclusion
          """
      ),
      removesQuotedReplies: true
    )

    #expect(
      presentation
        == .plainText("Here is the requested excerpt:\n> quoted passage\nMy conclusion"))
  }

  @Test
  func testThreadPlainTextPresentationKeepsForwardedMessage() {
    let text =
      """
      Forwarding this for context

      -----Original Message-----
      From: Sender <sender@example.com>
      Forwarded message body
      """
    let presentation = MessageHTMLPresentation.resolve(
      body: MailboxMessageBody(text: text),
      removesQuotedReplies: true
    )

    #expect(presentation == .plainText(text))
  }

  @Test
  func testSanitizerOmitsKnownCSSPreheaderContent() throws {
    let result = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <div class="preheader">Infomail preview text</div>
        <p>Visible message</p>
        """
      ))

    #expect(!(result.documentHTML.contains("Infomail preview text")))
    #expect(result.documentHTML.contains("Visible message"))

    let titledDocument = try requireValue(
      MessageHTMLSanitizer.sanitize(
        """
        <html>
          <head><title>Infomail document title</title></head>
          <body><p>Visible message</p></body>
        </html>
        """
      ))
    #expect(!(titledDocument.documentHTML.contains("Infomail document title")))
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
  providerActions: Set<ProviderMailAction> = Set(ProviderMailAction.allCases),
  canRequestReadReceipts: Bool = false
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
      canRequestReadReceipts: canRequestReadReceipts,
      canRegisterPush: connection.capabilities.canRegisterPush,
      canReply: connection.capabilities.canReply,
      canRespondToReadReceipts: connection.capabilities.canRespondToReadReceipts,
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

private struct ProviderRolloutConnectionFixture {
  let capabilities: MailboxConnectionCapabilities
  let displayName: String
  let providerAccountIdentifier: String
  let providerId: MailProviderId
}

// swiftlint:disable:next function_body_length
private func providerRolloutConnections(productAccountId: String) -> [MailboxConnection] {
  let roleMappings = Dictionary(
    uniqueKeysWithValues: CanonicalMailboxRole.allCases.map { ($0, $0.rawValue) }
  )
  let pop3Capabilities = MailboxConnectionCapabilities(
    canCategorizeHistorical: false,
    canForward: true,
    canReadMessages: true,
    canRequestReadReceipts: true,
    canRegisterPush: false,
    canReply: true,
    canRespondToReadReceipts: false,
    canSearchProvider: false,
    canSend: true,
    canSynchronizeMetadata: true,
    providerActions: []
  )
  let fixtures = [
    ProviderRolloutConnectionFixture(
      capabilities: .gmail,
      displayName: "Gmail",
      providerAccountIdentifier: "gmail-user-001",
      providerId: .gmail
    ),
    ProviderRolloutConnectionFixture(
      capabilities: .standardsMail(
        engineCapabilities: [.idle, .uidPlus],
        roleMappings: roleMappings
      ),
      displayName: "IMAP and SMTP",
      providerAccountIdentifier: "imap-user-001",
      providerId: .imapSMTP
    ),
    ProviderRolloutConnectionFixture(
      capabilities: .microsoftGraph,
      displayName: "Microsoft Graph",
      providerAccountIdentifier: "graph-user-001",
      providerId: .microsoftGraph
    ),
    ProviderRolloutConnectionFixture(
      capabilities: pop3Capabilities,
      displayName: "Legacy POP3",
      providerAccountIdentifier: "pop3-user-001",
      providerId: .pop3SMTP
    ),
    ProviderRolloutConnectionFixture(
      capabilities: .exchangeWebServices,
      displayName: "Exchange Web Services",
      providerAccountIdentifier: "ews-user-001",
      providerId: .exchangeWebServices
    ),
  ]
  return fixtures.map { fixture in
    MailboxConnection(
      authorizationState: .authorized,
      capabilities: fixture.capabilities,
      connectedAt: 1_781_200_000_000,
      displayName: fixture.displayName,
      id: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: fixture.providerId,
          value: fixture.providerAccountIdentifier
        )
      ),
      lastVerifiedAt: 1_781_200_000_100,
      productAccountId: ProductAccountId(productAccountId),
      trustedDeviceId: "trusted-device-001",
      updatedAt: 1_781_200_000_200
    )
  }
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

private final class ReleaseProductSyncRecordTransport: ProductSyncRecordTransport {
  private var payloads: [String: EncryptedProductSyncPayload] = [:]
  private var updatedAt: Int64 = 1_781_200_000_000

  private(set) var loadedEncryptedPayloadCount = 0

  var assignmentPayloadCount: Int {
    payloads.keys.filter { $0.hasPrefix("message-categories-v2:") }.count
  }

  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor: String?,
    limit: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    let matching = payloads.values
      .filter { $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) }
      .sorted { $0.payloadIdentifier < $1.payloadIdentifier }
    let start = min(Int(cursor ?? "") ?? 0, matching.count)
    let end = min(start + limit, matching.count)
    let loadedPayloads = Array(matching[start..<end])
    loadedEncryptedPayloadCount += loadedPayloads.count
    return EncryptedProductSyncPayloadPage(
      continueCursor: end == matching.count ? "" : String(end),
      isDone: end == matching.count,
      page: loadedPayloads
    )
  }

  func getEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    let loadedPayloads = payloadIdentifiers.compactMap { payloads[$0] }
    loadedEncryptedPayloadCount += loadedPayloads.count
    return loadedPayloads
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    guard payloads[payloadIdentifier]?.updatedAt == expectedUpdatedAt else {
      guard let existing = payloads[payloadIdentifier] else {
        throw ProductSyncRecordBoundaryError.invalidPayloadIdentifier
      }
      return existing
    }
    return store(encryptedPayload, payloadIdentifier: payloadIdentifier)
  }

  private func store(
    _ encryptedPayload: ProductSyncEncryptedPayload,
    payloadIdentifier: String
  ) -> EncryptedProductSyncPayload {
    updatedAt += 1
    let payload = EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: updatedAt
    )
    payloads[payloadIdentifier] = payload
    return payload
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

private struct ReleaseCategorizationStartupSample {
  let assignmentPayloadCount: Int
  let durationMilliseconds: Double
  let flightMessageCount: Int
  let inviteMessageCount: Int
  let loadedEncryptedPayloadCount: Int
  let mainActorStallMilliseconds: Double
  let messageCount: Int
  let newsletterAndPromotionMessageCount: Int
  let orderMessageCount: Int
  let savedBackgroundContextCount: Int
}

@MainActor
// swiftlint:disable:next function_body_length
private func releaseCategorizationStartupSample(
  clock: ContinuousClock,
  connection: MailboxConnection,
  keyMaterial: ProductSyncKeyMaterial,
  session: ProductAccountSessionSnapshot,
  status: GmailProviderConnectionStatus
) async throws -> ReleaseCategorizationStartupSample {
  let rootDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("release-categorization-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: rootDirectory,
    withIntermediateDirectories: true
  )
  defer { try? FileManager.default.removeItem(at: rootDirectory) }
  let storeURL = rootDirectory.appendingPathComponent("GmailMetadata.store")
  let cachedMessages = (0..<50).map { index in
    let content = releaseCategorizationContent(index: index)
    return GmailMessageMetadata(
      categoryId: nil,
      from: content.from,
      isHistorical: false,
      providerAccountIdentifier: status.providerAccountIdentifier,
      providerInternalDateMilliseconds: 1_781_200_001_000 + Int64(index),
      providerLabelIds: ["INBOX", "UNREAD"],
      providerMessageId: "sync-message-\(index)",
      providerThreadId: "sync-thread-\(index)",
      replyTo: nil,
      snippet: content.snippet,
      stableProviderMessageId:
        "gmail:\(status.providerAccountIdentifier):sync-message-\(index)",
      subject: content.subject,
      rfcMessageId: nil
    )
  }
  do {
    let seedStore = try releaseCategorizationMetadataStore(at: storeURL)
    try seedStore.saveMessages(
      cachedMessages,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: status.providerAccountIdentifier
    )
  }

  let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
  try keyMaterialStore.save(keyMaterial, productAccountId: session.productAccountId)
  let bodyCacheRoot = rootDirectory.appendingPathComponent("bodies", isDirectory: true)
  let bodyCache = FileGmailMessageBodyCache(rootDirectory: bodyCacheRoot)
  let bodyDependentMessageId =
    "gmail:\(status.providerAccountIdentifier):sync-message-49"
  try bodyCache.saveMessageBody(
    keyMaterial.encryptPayload(
      GmailMessageBodyCachePayload.encode(
        GmailMessageBody(text: "Your invoice receipt is attached.")
      ),
      associatedData: Data("gmail-body-cache-v1:\(bodyDependentMessageId)".utf8)
    ),
    productAccountId: session.productAccountId,
    stableProviderMessageId: bodyDependentMessageId
  )
  let transport = ReleaseProductSyncRecordTransport()
  _ = try await MessageCategoryAssignmentSyncService(
    recordBoundary: ProductSyncRecordBoundary(
      keyMaterialStore: keyMaterialStore,
      transport: transport
    )
  ).saveAssignment(
    MessageCategoryAssignment(
      categoryId: "system:flights",
      stableProviderMessageId:
        "gmail:\(status.providerAccountIdentifier):sync-message-0"
    ),
    session: session
  )
  let tokenStore = ReleaseGmailProviderTokenStore()
  try tokenStore.save(
    GmailProviderTokens(
      accessToken: "access-\(status.providerAccountIdentifier)",
      refreshToken: "refresh-\(status.providerAccountIdentifier)"
    ),
    productAccountId: session.productAccountId,
    providerAccountIdentifier: status.providerAccountIdentifier
  )

  let backgroundContextCache = KeychainBackgroundContextCacheStore(
    keyMaterialStore: keyMaterialStore
  )
  try backgroundContextCache.clear(
    productAccountId: session.productAccountId,
    providerAccountIdentifier: status.providerAccountIdentifier
  )
  defer {
    try? backgroundContextCache.clear(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: status.providerAccountIdentifier
    )
  }
  let stallProbe = ReleaseMainThreadStallProbe()
  stallProbe.start()
  let start = clock.now
  let metadataStore: SwiftDataGmailMessageMetadataStore
  do {
    metadataStore = try releaseCategorizationMetadataStore(at: storeURL)
    let categorizer = GmailMessageCategorizationService(
      assignmentSync: MessageCategoryAssignmentSyncService(
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: keyMaterialStore,
          transport: transport
        )
      ),
      backgroundContextCacheStore: backgroundContextCache,
      bodyReader: GmailMessageBodyService(
        cache: FileGmailMessageBodyCache(rootDirectory: bodyCacheRoot),
        keyMaterialStore: keyMaterialStore,
        oauthClientId: nil
      ),
      categorySync: CustomCategorySyncService(
        backgroundContextCacheStore: backgroundContextCache,
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: keyMaterialStore,
          transport: transport
        )
      ),
      currentTimeMilliseconds: { 1_781_200_002_000 },
      engine: RuleBasedClassificationEngine()
    )
    let metadataService = GmailMessageMetadataService(
      categorizer: categorizer,
      gmailBaseURL: URL(string: "https://gmail.release.test/gmail/v1")!,
      notificationEligibilityStore: ReleaseGmailPushEligibilityStore(),
      oauthClientId: "gmail-client-id",
      session: releaseGmailSyncSession(),
      store: metadataStore,
      tokenStore: tokenStore,
      tokenInfoURL: URL(string: "https://oauth.release.test/tokeninfo")!,
      tokenRefreshURL: URL(string: "https://oauth.release.test/token")!
    )
    let adapter = GmailMailboxConnectionAdapter(
      definitionSyncService: RecordingAdapterDefinitionSyncService(snapshot: .empty),
      metadataService: metadataService,
      pendingActionService: PendingProviderActionService(store: AdapterPendingActionStore()),
      outboxService: OutboxDeliveryService(store: AdapterOutboxStore())
    )
    _ = try await adapter.syncInbox(connection: connection, session: session)
  } catch {
    _ = await stallProbe.stop()
    throw error
  }
  let durationMilliseconds = releaseElapsedMilliseconds(from: start, clock: clock)
  let mainActorStallMilliseconds = await stallProbe.stop()
  let messages = try metadataStore.loadMessages(
    productAccountId: session.productAccountId,
    providerAccountIdentifier: status.providerAccountIdentifier
  )
  return ReleaseCategorizationStartupSample(
    assignmentPayloadCount: transport.assignmentPayloadCount,
    durationMilliseconds: durationMilliseconds,
    flightMessageCount: messages.count { $0.messageCategoryIds.contains("system:flights") },
    inviteMessageCount: messages.count { $0.messageCategoryIds.contains("system:invites") },
    loadedEncryptedPayloadCount: transport.loadedEncryptedPayloadCount,
    mainActorStallMilliseconds: mainActorStallMilliseconds,
    messageCount: messages.count,
    newsletterAndPromotionMessageCount: messages.count {
      $0.messageCategoryIds.contains("system:promotions")
    },
    orderMessageCount: messages.count { $0.messageCategoryIds.contains("system:invoices") },
    savedBackgroundContextCount: try backgroundContextCache.load(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: status.providerAccountIdentifier
    ) == nil ? 0 : 1
  )
}

private struct ReleaseCategorizationContent {
  let from: String
  let snippet: String
  let subject: String
}

private func releaseCategorizationContent(index: Int) -> ReleaseCategorizationContent {
  switch index {
  case 1...12:
    ReleaseCategorizationContent(
      from: "Store <offers@example.com>",
      snippet: "Limited discount offer",
      subject: "Promotion \(index)"
    )
  case 13...24:
    ReleaseCategorizationContent(
      from: "Host <events@example.com>",
      snippet: "Please RSVP",
      subject: "Invitation \(index)"
    )
  case 25...36:
    ReleaseCategorizationContent(
      from: "Billing <billing@example.com>",
      snippet: "Payment received",
      subject: "Invoice \(index)"
    )
  case 37...48:
    ReleaseCategorizationContent(
      from: "Airline <travel@example.com>",
      snippet: "Boarding itinerary",
      subject: "Flight \(index)"
    )
  case 49:
    ReleaseCategorizationContent(
      from: "Service <service@example.com>",
      snippet: "Your document is ready",
      subject: "Account update"
    )
  default:
    ReleaseCategorizationContent(
      from: "Airline <travel@example.com>",
      snippet: "Boarding itinerary",
      subject: "Flight \(index)"
    )
  }
}

private func releaseCategorizationMetadataStore(
  at url: URL
) throws -> SwiftDataGmailMessageMetadataStore {
  let schema = Schema([
    DurableGmailMessageMetadataRecord.self,
    GmailMetadataSyncCheckpointRecord.self,
  ])
  let configuration = ModelConfiguration(
    "ReleaseCategorizationStartup",
    schema: schema,
    url: url
  )
  let container = try ModelContainer(for: schema, configurations: [configuration])
  return SwiftDataGmailMessageMetadataStore(container: container)
}

// swiftlint:disable:next function_body_length
private func releaseGmailSyncSession() -> URLSession {
  ConvexClientTesting.makeSession(protocolClass: MailboxAdapterURLStub.self) { request in
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
      let messages = (0..<50).map { "{\"id\":\"sync-message-\($0)\"}" }
        .joined(separator: ",")
      return (response, Data("{\"messages\":[\(messages)]}".utf8))
    default:
      let messageId = request.url?.lastPathComponent ?? "sync-message-0"
      let messageIndex = Int(messageId.split(separator: "-").last ?? "0") ?? 0
      let content = releaseCategorizationContent(index: messageIndex)
      return (
        response,
        Data(
          """
          {
            "id":"\(messageId)",
            "threadId":"sync-thread-\(messageIndex)",
            "internalDate":"\(1_781_200_001_000 + messageIndex)",
            "labelIds":["INBOX","UNREAD"],
            "snippet":"\(content.snippet)",
            "payload":{"headers":[
              {"name":"From","value":"\(content.from)"},
              {"name":"To","value":"User <user@example.com>"},
              {"name":"Subject","value":"\(content.subject)"}
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

private struct ReleaseCustomCategorySyncService: CustomCategorySyncing {
  func deleteCategory(session _: ProductAccountSessionSnapshot) async throws {}

  func loadCategory(session _: ProductAccountSessionSnapshot) async throws -> CustomCategory? {
    nil
  }

  func saveCategory(
    _ category: CustomCategory,
    session _: ProductAccountSessionSnapshot
  ) async throws -> CustomCategory {
    category
  }
}

private struct ReleaseInboxPreferenceSyncService: InboxPreferenceSyncing {
  func loadPreferences(
    session _: ProductAccountSessionSnapshot
  ) async throws -> InboxPreferenceSyncSnapshot? {
    InboxPreferenceSyncSnapshot(preferences: .defaults, updatedAt: nil)
  }

  func savePreferences(
    _ preferences: InboxPreferences,
    expectedUpdatedAt _: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> InboxPreferenceConditionalSaveResult {
    .committed(InboxPreferenceSyncSnapshot(preferences: preferences, updatedAt: nil))
  }
}

private struct ReleaseNotificationAuthorization: NotificationAuthorizationRequesting {
  func requestAuthorization() async throws -> Bool {
    true
  }
}

private struct ReleaseNotificationRuleSyncService: NotificationRuleSyncing {
  func loadRules(
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    NotificationRuleSyncSnapshot(rules: NotificationRules(categoryIds: []), updatedAt: nil)
  }

  func saveRules(
    _ rules: NotificationRules,
    expectedUpdatedAt _: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    NotificationRuleSyncSnapshot(rules: rules, updatedAt: nil)
  }
}

private struct ReleasePinSyncService: PinSyncing {
  func loadPinnedThreadIds(
    session _: ProductAccountSessionSnapshot
  ) async throws -> Set<StableThreadIdentity> {
    []
  }

  func setPinned(
    _ isPinned: Bool,
    threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    _ = isPinned
    _ = threadId
    _ = anchorMessageId
  }
}

private struct ReleaseThreadSnoozeSyncService: ThreadSnoozeSyncing {
  func load(
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ThreadSnoozeSnapshot {
    ThreadSnoozeSnapshot(snoozes: [:])
  }

  func snooze(
    thread _: MailboxThread,
    dueAtMilliseconds _: Int64,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func cancel(
    threadId _: StableThreadIdentity,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func reconcile(
    with _: [MailboxMessageMetadata],
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ThreadSnoozeSnapshot {
    ThreadSnoozeSnapshot(snoozes: [:])
  }

  func loadPreferences(
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ThreadSnoozePreferences {
    .defaults
  }

  func setReturnToAttentionEnabled(
    _: Bool,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
}

private struct ReleaseMailProfileSnapshotLoader: MailProfileSnapshotLoading {
  let snapshot: MailProfileSyncSnapshot

  func loadProfileSnapshot(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    snapshot
  }
}

private final class ReleaseGenericMailAuthorizationStore: GenericMailAuthorizationPersisting {
  func clearAll(productAccountId _: ProductAccountId) throws {}

  func load(
    productAccountId _: ProductAccountId,
    emailAddress _: String
  ) throws -> DeviceLocalGenericMailAuthorization? {
    nil
  }

  func load(
    productAccountId _: ProductAccountId,
    connectionId _: MailboxConnectionId
  ) throws -> DeviceLocalGenericMailAuthorization? {
    nil
  }

  func remove(
    productAccountId _: ProductAccountId,
    connectionId _: MailboxConnectionId
  ) throws {}

  func save(
    _ authorization: DeviceLocalGenericMailAuthorization,
    productAccountId _: ProductAccountId
  ) throws {
    _ = authorization
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
) throws -> UIWindow {
  let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
  let windowScene = try requireValue(
    scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
  let window = UIWindow(windowScene: windowScene)
  window.frame = windowScene.screen.bounds
  window.rootViewController = controller
  window.makeKeyAndVisible()
  return window
}

@MainActor
private func releaseBeginRendering(_ view: UIView) {
  view.setNeedsLayout()
  view.layoutIfNeeded()
  CATransaction.flush()
}

@MainActor
private func releaseRenderFrame(_ view: UIView) async {
  releaseBeginRendering(view)
  try? await Task.sleep(nanoseconds: 17_000_000)
  view.layoutIfNeeded()
  CATransaction.flush()
}

@MainActor
private func releaseWaitForRenderedThreads(
  _ expectedIds: [MailboxThreadIdentity],
  driver: MailShellReleaseBudgetDriver,
  budgetScale: Double,
  view: UIView
) async -> Bool {
  let expectedIdSet = Set(expectedIds)
  for _ in 0..<Int(100 * budgetScale) {
    await releaseRenderFrame(view)
    if !driver.renderedItemIds.isDisjoint(with: expectedIdSet) {
      return true
    }
  }
  return false
}

@MainActor
private func releaseWaitForRenderedContent(
  in view: UIView,
  budgetScale: Double,
  isReady: () -> Bool
) async -> Bool {
  for _ in 0..<Int(100 * budgetScale) {
    await releaseRenderFrame(view)
    if isReady() {
      return true
    }
  }
  return false
}

@MainActor
private final class MessageBodyClearSignal: ObservableObject {
  @Published var value = UUID()
}

@MainActor
private final class MessageBodyRetrySignal: ObservableObject {
  @Published var value = UUID()
}

private struct ReleaseMessageBodyHarness: View {
  let loadId: UUID
  let onLoaded: () -> Void
  let load: () async throws -> MailboxMessageBody

  var body: some View {
    MailShellMessageBody(onLoaded: onLoaded, load: load)
      .id(loadId)
  }
}

private struct ClearableMessageBodyHarness: View {
  @ObservedObject var clearSignal: MessageBodyClearSignal
  let onLoaded: () -> Void
  var onRelease: () -> Void = {}
  let load: () async throws -> MailboxMessageBody

  var body: some View {
    MailShellMessageBody(
      clearSignal: clearSignal.value,
      onLoaded: onLoaded,
      onRelease: onRelease,
      load: load
    )
  }
}

private struct RetryableMessageBodyHarness: View {
  @ObservedObject var retrySignal: MessageBodyRetrySignal
  let onLoaded: () -> Void
  let load: () async throws -> MailboxMessageBody

  var body: some View {
    MailShellMessageBody(
      retrySignal: retrySignal.value,
      onLoaded: onLoaded,
      load: load
    )
  }
}

@MainActor
private final class GatedMessageBodyLoader {
  private var continuation: CheckedContinuation<MailboxMessageBody, Never>?
  private let started: TestExpectation

  init(started: TestExpectation) {
    self.started = started
  }

  func load() async -> MailboxMessageBody {
    started.fulfill()
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func resume(with body: MailboxMessageBody = MailboxMessageBody(text: "Private body")) {
    continuation?.resume(returning: body)
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
  var loadStoredConnectionsCallCount = 0
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
    loadStoredConnectionsCallCount += 1
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
  private let syncPriorityProbe: AdapterSyncPriorityProbe?
  var cachedService: GmailMessageMetadataSyncing?
  var cancelsAfterHistoricalBackfill = false
  var failsRecentSync = false
  var inboxProjectionCandidateMessageIds: Set<String> = []
  var loadedConnection: GmailProviderConnectionStatus?
  var loadedCollections: [MailboxMessageCollection] = []
  var inboxSyncResult = RecordingAdapterMetadataService.defaultResult
  var recentSyncResult = RecordingAdapterMetadataService.defaultResult
  var setCategoryIds: [String]?
  var providerDelayNanoseconds: UInt64 = 0
  var syncedConnection: GmailProviderConnectionStatus?
  var syncedProviderAccountIdentifiers: [String] = []

  init(
    eventLog: RecordingAdapterEventLog? = nil,
    historicalBackfillGate: AdapterLifecycleOperationGate? = nil,
    loadGate: AdapterLifecycleOperationGate? = nil,
    syncPriorityProbe: AdapterSyncPriorityProbe? = nil
  ) {
    self.eventLog = eventLog
    self.historicalBackfillGate = historicalBackfillGate
    self.loadGate = loadGate
    self.syncPriorityProbe = syncPriorityProbe
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
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    loadedConnection = connection
    if let cachedService {
      return try await cachedService.loadInbox(connection: connection, session: session)
    }
    return inboxSyncResult
  }

  func loadInboxProjectionCandidates(
    additionalProviderMessageIds: Set<String>,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    inboxProjectionCandidateMessageIds = additionalProviderMessageIds
    if let cachedService {
      return try await cachedService.loadInboxProjectionCandidates(
        additionalProviderMessageIds: additionalProviderMessageIds,
        connection: connection,
        session: session
      )
    }
    return try await loadMailbox(.role(.inbox), connection: connection, session: session)
  }

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    loadedConnection = connection
    loadedCollections.append(collection)
    if collection == .allObserved {
      eventLog?.events.append("observed")
    } else if collection == .role(.inbox) {
      eventLog?.events.append("inbox")
    }
    await loadGate?.waitForRelease()
    if let cachedService {
      return try await cachedService.loadMailbox(
        collection,
        connection: connection,
        session: session
      )
    }
    return
      collection == .allObserved
      ? inboxSyncResult : inboxSyncResult.projected(to: collection)
  }

  func continueHistoricalBackfill(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    try await syncPriorityProbe?.suspendBackfill()
    await historicalBackfillGate?.waitForRelease()
    if cancelsAfterHistoricalBackfill {
      withUnsafeCurrentTask { $0?.cancel() }
    }
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
    await syncPriorityProbe?.recordRecentSync()
    if providerDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: providerDelayNanoseconds)
    }
    if failsRecentSync {
      throw AdapterTestError.unavailable
    }
    return recentSyncResult
  }

  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    message.assigningCategory(categoryId)
  }

  func setCategories(
    _ categoryIds: [String],
    for message: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    setCategoryIds = categoryIds
    return message.assigningCategories(categoryIds)
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
  private let failsCategorySet: Bool
  private let gate = AdapterLifecycleOperationGate()
  private let started: TestExpectation
  private let syncStarted: TestExpectation?

  init(
    eventLog: AdapterLifecycleEventLog,
    started: TestExpectation,
    syncStarted: TestExpectation? = nil,
    failsCategorySet: Bool = false
  ) {
    self.eventLog = eventLog
    self.failsCategorySet = failsCategorySet
    self.started = started
    self.syncStarted = syncStarted
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
    syncStarted?.fulfill()
    await eventLog.record("freshness-sync-finished")
    return GmailMetadataSyncResult(messages: [], threads: [])
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

  func setCategories(
    _ categoryIds: [String],
    for message: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    started.fulfill()
    await gate.waitForRelease()
    try Task.checkCancellation()
    if failsCategorySet { throw AdapterTestError.unavailable }
    await eventLog.record("categories-set")
    return message.assigningCategories(categoryIds)
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
    return GmailMessageBody(text: gmailAdapterMessageBody.text, html: gmailAdapterMessageBody.html)
  }

  func prefetchMessageBodies(
    connection: GmailProviderConnectionStatus,
    pinnedThreadIds _: Set<String>,
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

private final class AdapterPersistenceFence: @unchecked Sendable {
  private var checkCount = 0
  private let lock = NSLock()

  func allowFirstCheckOnly() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    checkCount += 1
    return checkCount == 1
  }
}

private actor AdapterSyncPriorityProbe {
  struct Snapshot {
    let events: [String]
    let maximumConcurrentOperations: Int
  }

  private let backfillStarted: TestExpectation
  private let recentSyncStarted: TestExpectation?
  private var activeOperationCount = 0
  private var backfillContinuation: CheckedContinuation<Void, Error>?
  private var events: [String] = []
  private var maximumConcurrentOperations = 0

  init(
    backfillStarted: TestExpectation,
    recentSyncStarted: TestExpectation? = nil
  ) {
    self.backfillStarted = backfillStarted
    self.recentSyncStarted = recentSyncStarted
  }

  func suspendBackfill() async throws {
    beginOperation("backfill-started")
    backfillStarted.fulfill()
    defer { activeOperationCount -= 1 }
    try await withTaskCancellationHandler {
      let _: Void = try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        backfillContinuation = continuation
      }
    } onCancel: {
      Task { await self.cancelBackfill() }
    }
  }

  func recordRecentSync() {
    beginOperation("recent-sync-started")
    recentSyncStarted?.fulfill()
    activeOperationCount -= 1
  }

  func releaseBackfill() {
    backfillContinuation?.resume()
    backfillContinuation = nil
  }

  func snapshot() -> Snapshot {
    Snapshot(
      events: events,
      maximumConcurrentOperations: maximumConcurrentOperations
    )
  }

  private func beginOperation(_ event: String) {
    activeOperationCount += 1
    maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperationCount)
    events.append(event)
  }

  private func cancelBackfill() {
    events.append("backfill-cancelled")
    backfillContinuation?.resume(throwing: CancellationError())
    backfillContinuation = nil
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
    pinnedThreadIds _: Set<String>,
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
    pinnedThreadIds _: Set<String>,
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
  private let saveStarted: TestExpectation

  init(saveStarted: TestExpectation) {
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
  var saveError: Error?
  private(set) var saveCallCount = 0

  func load(productAccountId: String) throws -> [OutgoingDeliveryAttempt] {
    attempts.filter { $0.productAccountId.rawValue == productAccountId }
  }

  func save(
    _ attempts: [OutgoingDeliveryAttempt],
    productAccountId _: String
  ) throws {
    saveCallCount += 1
    if let saveError { throw saveError }
    self.attempts = attempts
  }
}

private actor GatedAdapterMailActionService: GmailProviderMailActing {
  private let blockedProviderIdentifier: String
  private let firstStarted: TestExpectation
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private let secondPerformed: TestExpectation

  init(
    blockedProviderIdentifier: String,
    firstStarted: TestExpectation,
    secondPerformed: TestExpectation
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
  private var sourceProviderMailboxIds: [String?] = []
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
    sourceProviderMailboxId: String?,
    targetProviderMailboxId _: String?,
    targetProviderStateIds: Set<String>,
    messages _: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    connectionIds.append(connection.id)
    sourceProviderMailboxIds.append(sourceProviderMailboxId)
    self.targetProviderStateIds.append(targetProviderStateIds)
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

  func recordedSourceProviderMailboxIds() -> [String?] {
    sourceProviderMailboxIds
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

private actor RevocationFencedBulkMailActionService: MailboxProviderMailActing {
  private(set) var resumeCount = 0

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
    resumeCount += 1
    return nil
  }

  func send(
    _: OutgoingMessage,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
}

private struct ConnectionPendingActionFailureService: MailboxProviderMailActing {
  let coversSelectedMessageIds: Bool
  let resumeError: String?
  let retryError: String?
  let selectedFailureDetails: [MailboxProviderActionFailureDetail]?
  let trackedSelection: MailboxProviderActionSelection

  init(
    resumeError: String? = "The provider connection failed.",
    retryError: String? = nil,
    selectedFailureDetails: [MailboxProviderActionFailureDetail]? = nil,
    coversSelectedMessageIds: Bool = true
  ) {
    self.coversSelectedMessageIds = coversSelectedMessageIds
    self.resumeError = resumeError
    self.retryError = retryError
    self.selectedFailureDetails = selectedFailureDetails
    trackedSelection = MailboxProviderActionSelection(pendingActionIds: [UUID()])
  }

  func perform(
    _: ProviderMailAction,
    messages _: [MailboxMessageMetadata],
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  // swiftlint:disable:next function_parameter_count
  func performTracked(
    _: ProviderMailAction,
    sourceProviderMailboxId _: String?,
    targetProviderMailboxId _: String?,
    targetProviderStateIds _: Set<String>,
    messages _: [MailboxMessageMetadata],
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxProviderActionSelection? {
    trackedSelection
  }

  func resumePendingActions(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async -> String? {
    resumeError
  }

  func waitForPendingActionRetries(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async -> String? {
    retryError
  }

  func pendingActionFailureDetails(
    _: ProviderMailAction,
    messages _: [MailboxMessageMetadata],
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async -> [MailboxProviderActionFailureDetail]? {
    selectedFailureDetails
  }

  func pendingActionFailureLookup(
    _: ProviderMailAction,
    selection: MailboxProviderActionSelection?,
    messages _: [MailboxMessageMetadata],
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async -> MailboxProviderActionFailureLookup? {
    guard selection == trackedSelection, let selectedFailureDetails else { return nil }
    return MailboxProviderActionFailureLookup(
      coversSelectedMessageIds: coversSelectedMessageIds,
      details: selectedFailureDetails,
      matchedPendingActionIds: coversSelectedMessageIds
        ? trackedSelection.pendingActionIds : []
    )
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
  private var recordedReleasedSelectionCount = 0
  private let resumeGate: AdapterLifecycleOperationGate?
  private let resumeError: String?
  private let resumeErrorConnectionId: MailboxConnectionId?
  private let resumeStarted: TestExpectation
  private let selectedFailureDetails: [MailboxProviderActionFailureDetail]?
  private let selectedFailureDetailsConnectionId: MailboxConnectionId?
  private let selectionReleased: TestExpectation?
  private let trackedSelection = MailboxProviderActionSelection(pendingActionIds: [UUID()])
  private var recordedResumeWasCancelled = false
  private let suspendsResumeUntilCancelled: Bool

  init(
    resumeStarted: TestExpectation,
    resumeError: String? = nil,
    resumeErrorConnectionId: MailboxConnectionId? = nil,
    failedConnectionId: MailboxConnectionId? = nil,
    failedConnectionIds: Set<MailboxConnectionId> = [],
    blockedConnectionIds: Set<MailboxConnectionId> = [],
    performFailureConnectionId: MailboxConnectionId? = nil,
    resumeGate: AdapterLifecycleOperationGate? = nil,
    gatedResumeConnectionId: MailboxConnectionId? = nil,
    selectedFailureDetails: [MailboxProviderActionFailureDetail]? = nil,
    selectedFailureDetailsConnectionId: MailboxConnectionId? = nil,
    selectionReleased: TestExpectation? = nil,
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
    self.selectedFailureDetails = selectedFailureDetails
    self.selectedFailureDetailsConnectionId = selectedFailureDetailsConnectionId
    self.selectionReleased = selectionReleased
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

  // swiftlint:disable:next function_parameter_count
  func performTracked(
    _ action: ProviderMailAction,
    sourceProviderMailboxId _: String?,
    targetProviderMailboxId _: String?,
    targetProviderStateIds _: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxProviderActionSelection? {
    try await perform(action, messages: messages, connection: connection, session: session)
    return trackedSelection
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

  func pendingActionFailureDetails(
    _: ProviderMailAction,
    messages _: [MailboxMessageMetadata],
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async -> [MailboxProviderActionFailureDetail]? {
    selectedFailureDetails
  }

  func pendingActionFailureLookup(
    _: ProviderMailAction,
    selection: MailboxProviderActionSelection?,
    messages _: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async -> MailboxProviderActionFailureLookup? {
    guard selection == trackedSelection, let selectedFailureDetails,
      selectedFailureDetailsConnectionId == nil
        || selectedFailureDetailsConnectionId == connection.id
    else { return nil }
    return MailboxProviderActionFailureLookup(
      coversSelectedMessageIds: true,
      details: selectedFailureDetails,
      matchedPendingActionIds: trackedSelection.pendingActionIds
    )
  }

  func releasePendingActionSelection(
    _ selection: MailboxProviderActionSelection,
    connection _: MailboxConnection
  ) async {
    guard selection == trackedSelection else { return }
    recordedReleasedSelectionCount += 1
    selectionReleased?.fulfill()
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

  func releasedSelectionCount() -> Int {
    recordedReleasedSelectionCount
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
  private let firstStarted: TestExpectation
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private let secondStarted: TestExpectation

  init(
    blockedConnectionId: MailboxConnectionId,
    firstStarted: TestExpectation,
    secondStarted: TestExpectation
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
