import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
@Suite(.serialized)
final class GmailProviderConnectionServiceTests {
  private static let gmailReadScope = "https://www.googleapis.com/auth/gmail.readonly"

  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "apple-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  @Test
  func testGmailConnectionExposesProviderNeutralIdentityAndExplicitCapabilities() {
    let status = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "user@example.com",
      lastVerifiedAt: 1_781_200_000_100,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-001",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_200
    )

    let connection = status.mailboxConnection(
      productAccountId: session.productAccountId, authorizationState: .authorized)

    #expect(connection.productAccountId == ProductAccountId(session.productAccountId))
    #expect(connection.providerId == .gmail)
    #expect(
      connection.providerMailboxIdentity
        == StableProviderMailboxIdentity(providerId: .gmail, value: "gmail-user-001"))
    #expect(
      connection.id
        == MailboxConnectionId(
          providerMailboxIdentity: connection.providerMailboxIdentity
        ))
    #expect(connection.displayName == "user@example.com")
    #expect(connection.capabilities.canSynchronizeMetadata)
    #expect(connection.capabilities.canReadMessages)
    #expect(connection.capabilities.canRegisterPush)
    #expect(connection.capabilities.canSearchProvider)
    #expect(connection.capabilities.canSend)
    #expect(connection.capabilities.providerActions == Set(ProviderMailAction.allCases))
  }

  @Test
  func testGmailMessageIdentitiesRemainScopedToTheirMailboxConnection() {
    let message = GmailMessageMetadata(
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
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-001"
      )
    )

    #expect(message.mailboxConnectionId == connectionId)
    #expect(message.id == message.stableIdentity)
    #expect(
      message.threadIdentity
        == MailboxThreadIdentity(connectionId: connectionId, providerThreadId: "thread-001"))
    #expect(
      message.stableIdentity
        == StableProviderMessageIdentity(
          connectionId: connectionId,
          providerMessageId: "message-001"
        ))
    #expect(GmailInboxThread.group([message])[0].id == message.threadIdentity)

    let otherConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-002"
      )
    )
    let mailboxMessage = message.mailboxMetadata(connectionId: connectionId)
    let otherMailboxMessage = message.mailboxMetadata(connectionId: otherConnectionId)

    #expect(mailboxMessage.stableProviderMessageId == "gmail:gmail-user-001:message-001")
    #expect(MailboxThread.group([mailboxMessage, otherMailboxMessage]).count == 2)
  }

  @Test
  func testGmailIdentityTokenIsExcludedFromTokenPersistence() throws {
    let encoded = try JSONEncoder().encode(
      GmailProviderTokens(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        idToken: "transient-id-token"
      )
    )
    let decoded = try JSONDecoder().decode(GmailProviderTokens.self, from: encoded)

    #expect(encoded.range(of: Data("transient-id-token".utf8)) == nil)
    #expect(
      decoded == GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"))
  }

  @Test
  func testCompleteConnectionStoresReadableIdentityOnlyOnDevice() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    let pushConnectionStore = RecordingPushConnectionStore()
    let transport = RecordingGmailConnectionTransport()
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      tokenStore: tokenStore,
      transport: transport
    )

    let status = try await service.completeConnection(
      verifiedAccount: VerifiedGmailAccount(
        emailAddress: "user@example.com",
        providerAccountIdentifier: "gmail-user-001",
        tokens: GmailProviderTokens(
          accessToken: "access-token",
          refreshToken: "refresh-token",
          idToken: "gmail-identity-token"
        )
      ),
      session: session
    )

    #expect(status.emailAddress == "user@example.com")
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: "gmail-user-001"
      ) == GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"))
    #expect(transport.connectCall?.identityToken == "apple-token")
    #expect(transport.connectCall?.trustedDeviceId == "trusted-device-001")
    #expect(transport.connectCall?.gmailIdentityToken == "gmail-identity-token")
    #expect(
      transport.connectCall?.opaqueConnectionId
        == opaqueGmailConnectionId(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: "gmail-user-001"
        ))
    #expect(pushConnectionStore.connections == [status])
  }

  @Test
  func testCompleteConnectionKeepsTokensForTwoGmailMailboxIdentities() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    let service = GmailProviderConnectionService(
      tokenStore: tokenStore,
      transport: RecordingGmailConnectionTransport()
    )

    for providerAccountIdentifier in ["gmail-user-001", "gmail-user-002"] {
      _ = try await service.completeConnection(
        verifiedAccount: VerifiedGmailAccount(
          emailAddress: "\(providerAccountIdentifier)@example.com",
          providerAccountIdentifier: providerAccountIdentifier,
          tokens: GmailProviderTokens(
            accessToken: "access-\(providerAccountIdentifier)",
            refreshToken: "refresh-\(providerAccountIdentifier)",
            idToken: "identity-\(providerAccountIdentifier)"
          )
        ),
        session: session
      )
    }

    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: "gmail-user-001"
      )?.accessToken == "access-gmail-user-001")
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: "gmail-user-002"
      )?.accessToken == "access-gmail-user-002")
  }

  @Test
  func testCompleteConnectionClearsLocalTokensWhenBackendRegistrationFails() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    let transport = RecordingGmailConnectionTransport()
    transport.connectError = GmailProviderConnectionTestError.registrationFailed
    let service = GmailProviderConnectionService(
      tokenStore: tokenStore,
      transport: transport
    )

    do {
      _ = try await service.completeConnection(
        verifiedAccount: VerifiedGmailAccount(
          emailAddress: "user@example.com",
          providerAccountIdentifier: "gmail-user-001",
          tokens: GmailProviderTokens(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: "gmail-identity-token"
          )
        ),
        session: session
      )
      Issue.record("Expected backend registration failure")
    } catch GmailProviderConnectionTestError.registrationFailed {
      #expect(
        try tokenStore.load(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: "gmail-user-001"
        ) == nil)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testCompleteConnectionRestoresPreviousTokensWhenUpdateRegistrationFails() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "old-access-token", refreshToken: "old-refresh-token"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001"
    )
    let transport = RecordingGmailConnectionTransport()
    transport.connectError = GmailProviderConnectionTestError.registrationFailed
    let service = GmailProviderConnectionService(
      tokenStore: tokenStore,
      transport: transport
    )

    do {
      _ = try await service.completeConnection(
        verifiedAccount: VerifiedGmailAccount(
          emailAddress: "user@example.com",
          providerAccountIdentifier: "gmail-user-001",
          tokens: GmailProviderTokens(
            accessToken: "new-access-token",
            refreshToken: "new-refresh-token",
            idToken: "gmail-identity-token"
          )
        ),
        session: session
      )
      Issue.record("Expected backend registration failure")
    } catch GmailProviderConnectionTestError.registrationFailed {
      #expect(
        try tokenStore.load(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: "gmail-user-001"
        ) == GmailProviderTokens(accessToken: "old-access-token", refreshToken: "old-refresh-token")
      )
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testCompleteConnectionPreservesLocalCacheWhenUpdateRegistrationFails() async throws {
    let bodyReader = RecordingGmailMessageReader()
    let metadataStore = RecordingGmailProviderMetadataStore()
    let transport = RecordingGmailConnectionTransport()
    transport.status = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "old@example.com",
      lastVerifiedAt: 1_781_200_000_000,
      provider: "gmail",
      providerAccountIdentifier: "old-gmail-user",
      trustedDeviceId: "trusted-device-001",
      updatedAt: 1_781_200_000_000
    )
    transport.connectError = GmailProviderConnectionTestError.registrationFailed
    let service = GmailProviderConnectionService(
      bodyReader: bodyReader,
      metadataStore: metadataStore,
      tokenStore: InMemoryGmailProviderTokenStore(),
      transport: transport
    )

    do {
      _ = try await service.completeConnection(
        verifiedAccount: VerifiedGmailAccount(
          emailAddress: "new@example.com",
          providerAccountIdentifier: "new-gmail-user",
          tokens: GmailProviderTokens(
            accessToken: "new-access-token",
            refreshToken: "new-refresh-token",
            idToken: "gmail-identity-token"
          )
        ),
        session: session
      )
      Issue.record("Expected backend registration failure")
    } catch GmailProviderConnectionTestError.registrationFailed {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(bodyReader.clearedSessions.isEmpty)
    #expect(metadataStore.clearedProductAccountIds.isEmpty)
  }

  @Test
  func testCompleteConnectionPreservesOtherMailboxLocalData() async throws {
    let metadataStore = RecordingGmailProviderMetadataStore()
    let bodyReader = RecordingGmailMessageReader()
    let transport = RecordingGmailConnectionTransport()
    transport.connectStatus = GmailOperationalConnectionStatus(
      connectedAt: 1_781_200_000_000,
      lastVerifiedAt: 1_781_210_000_000,
      opaqueConnectionId: opaqueGmailConnectionId(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: "new-gmail-user"
      ),
      trustedDeviceId: "trusted-device-001",
      updatedAt: 1_781_210_000_000
    )
    let service = GmailProviderConnectionService(
      bodyReader: bodyReader,
      metadataStore: metadataStore,
      tokenStore: InMemoryGmailProviderTokenStore(),
      transport: transport
    )

    _ = try await service.completeConnection(
      verifiedAccount: VerifiedGmailAccount(
        emailAddress: "new@example.com",
        providerAccountIdentifier: "new-gmail-user",
        tokens: GmailProviderTokens(
          accessToken: "new-access-token",
          refreshToken: "new-refresh-token",
          idToken: "gmail-identity-token"
        )
      ),
      session: session
    )

    #expect(bodyReader.clearedSessions.isEmpty)
    #expect(metadataStore.clearedProductAccountIds.isEmpty)
    #expect(transport.connectCalls.count == 1)
  }

  @Test
  func testCompleteConnectionRestoresPreviousTokensWhenCancelled() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "old-access-token", refreshToken: "old-refresh-token"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001"
    )
    let transport = RecordingGmailConnectionTransport()
    transport.onConnect = {
      try tokenStore.clear(
        productAccountId: self.session.productAccountId,
        providerAccountIdentifier: "gmail-user-001"
      )
    }
    transport.connectError = CancellationError()
    let service = GmailProviderConnectionService(
      tokenStore: tokenStore,
      transport: transport
    )

    do {
      _ = try await service.completeConnection(
        verifiedAccount: VerifiedGmailAccount(
          emailAddress: "user@example.com",
          providerAccountIdentifier: "gmail-user-001",
          tokens: GmailProviderTokens(
            accessToken: "new-access-token",
            refreshToken: "new-refresh-token",
            idToken: "gmail-identity-token"
          )
        ),
        session: session
      )
      Issue.record("Expected cancellation")
    } catch is CancellationError {
      #expect(
        try tokenStore.load(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: "gmail-user-001"
        ) == GmailProviderTokens(accessToken: "old-access-token", refreshToken: "old-refresh-token")
      )
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testLoadConnectionsReadsDeviceLocalStatus() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001"
    )
    let transport = RecordingGmailConnectionTransport()
    transport.status = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "user@example.com",
      lastVerifiedAt: 1_781_200_000_000,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-001",
      trustedDeviceId: "trusted-device-001",
      updatedAt: 1_781_200_000_000
    )
    let pushConnectionStore = RecordingPushConnectionStore(connection: transport.status)
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      tokenStore: tokenStore,
      transport: transport
    )

    let statuses = try await service.loadConnections(session: session)

    #expect(statuses.map(\.emailAddress) == ["user@example.com"])
    #expect(pushConnectionStore.loadedProductAccountId == session.productAccountId)
  }

  @Test
  func testLoadConnectionsMigratesLegacyTokensWithoutPushConnection() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    tokenStore.saveLegacy(
      GmailProviderTokens(accessToken: "legacy-access", refreshToken: "legacy-refresh"),
      productAccountId: session.productAccountId
    )
    let pushConnectionStore = RecordingPushConnectionStore()
    let transport = RecordingGmailConnectionTransport()
    let verifiedAccount = VerifiedGmailAccount(
      emailAddress: "user@example.com",
      providerAccountIdentifier: "gmail-user-001",
      tokens: GmailProviderTokens(
        accessToken: "refreshed-access",
        refreshToken: "legacy-refresh",
        idToken: "gmail-identity-token"
      )
    )
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      tokenStore: tokenStore,
      transport: transport,
      credentialVerifier: StaticGmailCredentialVerifier(account: verifiedAccount)
    )

    let statuses = try await service.loadConnections(session: session)

    #expect(statuses.map(\.providerAccountIdentifier) == ["gmail-user-001"])
    #expect(try tokenStore.loadLegacy(productAccountId: session.productAccountId) == nil)
    #expect(pushConnectionStore.connections == statuses)
    #expect(transport.connectCall?.gmailIdentityToken == "gmail-identity-token")
  }

  @Test
  func testLoadConnectionsReconstructsStatusFromScopedTokensWithoutPushConnection() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "scoped-access", refreshToken: "scoped-refresh"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001"
    )
    let pushConnectionStore = RecordingPushConnectionStore()
    let transport = RecordingGmailConnectionTransport()
    let verifiedAccount = VerifiedGmailAccount(
      emailAddress: "user@example.com",
      providerAccountIdentifier: "gmail-user-001",
      tokens: GmailProviderTokens(
        accessToken: "refreshed-access",
        refreshToken: "scoped-refresh",
        idToken: "gmail-identity-token"
      )
    )
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      tokenStore: tokenStore,
      transport: transport,
      credentialVerifier: StaticGmailCredentialVerifier(account: verifiedAccount)
    )

    let statuses = try await service.loadConnections(session: session)

    #expect(statuses.map(\.providerAccountIdentifier) == ["gmail-user-001"])
    #expect(pushConnectionStore.connections == statuses)
    #expect(transport.connectCall?.gmailIdentityToken == "gmail-identity-token")
  }

  @Test
  func testLoadConnectionsDoesNotVerifyBlockedStatuslessScopedTokens() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "scoped-access", refreshToken: "scoped-refresh"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001"
    )
    let verifier = CountingGmailCredentialVerifier()
    let transport = RecordingGmailConnectionTransport()
    let service = GmailProviderConnectionService(
      pushConnectionStore: RecordingPushConnectionStore(),
      tokenStore: tokenStore,
      transport: transport,
      credentialVerifier: verifier
    )

    let statuses = try await service.loadConnections(
      migrationPolicy: GmailCredentialMigrationPolicy(
        allowsUnscopedLegacyMigration: false,
        blockedProviderAccountIdentifiers: ["gmail-user-001"]
      ),
      session: session
    )

    #expect(statuses.isEmpty)
    #expect(verifier.verificationCount == 0)
    #expect(transport.connectCall == nil)
  }

  @Test
  func testLoadConnectionsDoesNotVerifyLegacyTokensAcrossGenerationHistory() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    tokenStore.saveLegacy(
      GmailProviderTokens(accessToken: "legacy-access", refreshToken: "legacy-refresh"),
      productAccountId: session.productAccountId
    )
    let verifier = CountingGmailCredentialVerifier()
    let transport = RecordingGmailConnectionTransport()
    let service = GmailProviderConnectionService(
      pushConnectionStore: RecordingPushConnectionStore(),
      tokenStore: tokenStore,
      transport: transport,
      credentialVerifier: verifier
    )

    let statuses = try await service.loadConnections(
      migrationPolicy: GmailCredentialMigrationPolicy(
        allowsUnscopedLegacyMigration: false,
        blockedProviderAccountIdentifiers: ["gmail-user-001"]
      ),
      session: session
    )

    #expect(statuses.isEmpty)
    #expect(verifier.verificationCount == 0)
    #expect(transport.connectCall == nil)
  }

  @Test
  func testLoadConnectionsIgnoresUnverifiableOrphanScopedTokens() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "valid-access", refreshToken: "valid-refresh"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001"
    )
    try tokenStore.save(
      GmailProviderTokens(accessToken: "revoked-access", refreshToken: "revoked-refresh"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-orphan"
    )
    let transport = RecordingGmailConnectionTransport()
    let service = GmailProviderConnectionService(
      pushConnectionStore: RecordingPushConnectionStore(connection: transport.status),
      tokenStore: tokenStore,
      transport: transport,
      credentialVerifier: RejectingGmailCredentialVerifier()
    )

    let statuses = try await service.loadConnections(session: session)

    #expect(statuses == [transport.status])
  }

  @Test
  func testLoadConnectionsIsolatesOrphanRegistrationFailure() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "valid-access", refreshToken: "valid-refresh"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001"
    )
    try tokenStore.save(
      GmailProviderTokens(accessToken: "orphan-access", refreshToken: "orphan-refresh"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-orphan"
    )
    let transport = RecordingGmailConnectionTransport()
    transport.connectError = GmailProviderConnectionTestError.registrationFailed
    let service = GmailProviderConnectionService(
      pushConnectionStore: RecordingPushConnectionStore(connection: transport.status),
      tokenStore: tokenStore,
      transport: transport,
      credentialVerifier: StaticGmailCredentialVerifier(
        account: VerifiedGmailAccount(
          emailAddress: "orphan@example.com",
          providerAccountIdentifier: "gmail-user-orphan",
          tokens: GmailProviderTokens(
            accessToken: "refreshed-access",
            refreshToken: "orphan-refresh",
            idToken: "gmail-identity-token"
          )
        )
      )
    )

    let statuses = try await service.loadConnections(session: session)

    #expect(statuses == [transport.status])
  }

  @Test
  func testLoadConnectionsMigratesLegacyTokensForExistingPushConnection() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    tokenStore.saveLegacy(
      GmailProviderTokens(accessToken: "legacy-access", refreshToken: "legacy-refresh"),
      productAccountId: session.productAccountId
    )
    let transport = RecordingGmailConnectionTransport()
    let pushConnectionStore = RecordingPushConnectionStore(connection: transport.status)
    let verifiedAccount = VerifiedGmailAccount(
      emailAddress: transport.status.emailAddress,
      providerAccountIdentifier: transport.status.providerAccountIdentifier,
      tokens: GmailProviderTokens(
        accessToken: "refreshed-access",
        refreshToken: "legacy-refresh",
        idToken: "gmail-identity-token"
      )
    )
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      tokenStore: tokenStore,
      transport: transport,
      credentialVerifier: StaticGmailCredentialVerifier(account: verifiedAccount)
    )

    let statuses = try await service.loadConnections(session: session)

    #expect(statuses == [transport.status])
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: transport.status.providerAccountIdentifier
      ) == GmailProviderTokens(accessToken: "refreshed-access", refreshToken: "legacy-refresh"))
    #expect(try tokenStore.loadLegacy(productAccountId: session.productAccountId) == nil)
    #expect(transport.connectCall == nil)
  }

  @Test
  func testLoadConnectionsIgnoresUnverifiableLegacyTokensForScopedConnections() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "scoped-access", refreshToken: "scoped-refresh"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001"
    )
    tokenStore.saveLegacy(
      GmailProviderTokens(accessToken: "revoked-access", refreshToken: "revoked-refresh"),
      productAccountId: session.productAccountId
    )
    let transport = RecordingGmailConnectionTransport()
    let service = GmailProviderConnectionService(
      pushConnectionStore: RecordingPushConnectionStore(connection: transport.status),
      tokenStore: tokenStore,
      transport: transport,
      credentialVerifier: RejectingGmailCredentialVerifier()
    )

    let statuses = try await service.loadConnections(session: session)

    #expect(statuses == [transport.status])
  }

  @Test
  func testLoadConnectionsKeepsTokenlessDeviceStatusVisibleForRemoval() async throws {
    let status = RecordingGmailConnectionTransport().status
    let service = GmailProviderConnectionService(
      pushConnectionStore: RecordingPushConnectionStore(connection: status),
      tokenStore: InMemoryGmailProviderTokenStore(),
      transport: RecordingGmailConnectionTransport()
    )

    let statuses = try await service.loadConnections(session: session)

    #expect(statuses == [status])
  }

  @Test
  func testLoadConnectionsPropagatesTokenLoadFailure() async throws {
    let connection = RecordingGmailConnectionTransport().status
    let service = GmailProviderConnectionService(
      pushConnectionStore: RecordingPushConnectionStore(connection: connection),
      tokenStore: FailingLoadGmailProviderTokenStore(),
      transport: RecordingGmailConnectionTransport()
    )

    do {
      _ = try await service.loadConnections(session: session)
      Issue.record("Expected token load failure")
    } catch GmailProviderConnectionTestError.tokenLoadFailed {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testLoadConnectionsRequiresCurrentTrustedDevice() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001"
    )
    let transport = RecordingGmailConnectionTransport()
    transport.status = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "user@example.com",
      lastVerifiedAt: 1_781_200_000_000,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-001",
      trustedDeviceId: "other-trusted-device",
      updatedAt: 1_781_200_000_000
    )
    let service = GmailProviderConnectionService(
      pushConnectionStore: RecordingPushConnectionStore(connection: transport.status),
      tokenStore: tokenStore,
      transport: transport
    )

    let statuses = try await service.loadConnections(session: session)

    #expect(statuses.isEmpty)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testClearLocalConnectionStopsWatchThenClearsTokensMetadataAndCachedBodies() async throws {
    let cacheStore = RecordingBackgroundContextCacheStore()
    let tokenStore = InMemoryGmailProviderTokenStore()
    let bodyReader = RecordingGmailMessageReader()
    let metadataStore = RecordingGmailProviderMetadataStore()
    let pushConnectionStore = RecordingPushConnectionStore(
      connection: GmailProviderConnectionStatus(
        connectedAt: 1_781_200_000_000,
        emailAddress: "user@example.com",
        lastVerifiedAt: 1_781_200_000_000,
        provider: "gmail",
        providerAccountIdentifier: "gmail-user-001",
        trustedDeviceId: session.trustedDeviceId,
        updatedAt: 1_781_200_000_000
      )
    )
    let pushWatchStore = RecordingPushWatchStore()
    let pushWatchStopper = RecordingPushWatchStopper(tokenStore: tokenStore)
    let notificationSuffix =
      "\(gmailSafeFileComponent(session.productAccountId))."
      + gmailSafeFileComponent("gmail-user-001")
    let receiptKey = "gmail-push-notification-receipts.\(notificationSuffix)"
    let eligibilityKey = "gmail-push-notification-eligibility.\(notificationSuffix)"
    UserDefaults.standard.set(["gmail:gmail-user-001:message-001"], forKey: receiptKey)
    UserDefaults.standard.set(["gmail:gmail-user-001:history-001"], forKey: eligibilityKey)
    defer {
      UserDefaults.standard.removeObject(forKey: receiptKey)
      UserDefaults.standard.removeObject(forKey: eligibilityKey)
    }
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001"
    )
    let service = GmailProviderConnectionService(
      backgroundContextCacheStore: cacheStore,
      bodyReader: bodyReader,
      pushConnectionStore: pushConnectionStore,
      pushWatchStopper: pushWatchStopper,
      pushWatchStore: pushWatchStore,
      metadataStore: metadataStore,
      tokenStore: tokenStore,
      transport: RecordingGmailConnectionTransport()
    )

    try await service.clearLocalConnection(session: session)

    #expect(pushWatchStopper.stoppedConnection == pushConnectionStore.connection)
    #expect(pushWatchStopper.stoppedSession == session)
    #expect(pushWatchStopper.tokensWereAvailable)
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: "gmail-user-001"
      ) == nil)
    #expect(bodyReader.clearedSessions == [session])
    #expect(cacheStore.clearedProductAccountIds == [session.productAccountId])
    #expect(metadataStore.clearedProductAccountIds == [session.productAccountId])
    #expect(pushConnectionStore.clearedProductAccountIds == [session.productAccountId])
    #expect(pushWatchStore.clearedAllProductAccountIds == [session.productAccountId])
    #expect(UserDefaults.standard.object(forKey: receiptKey) == nil)
    #expect(UserDefaults.standard.object(forKey: eligibilityKey) == nil)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testClearLocalConnectionRemovesOnlyRequestedMailboxIdentity() async throws {
    let first = RecordingGmailConnectionTransport().status
    let second = GmailProviderConnectionStatus(
      connectedAt: 1_781_200_000_000,
      emailAddress: "second@example.com",
      lastVerifiedAt: 1_781_200_000_000,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_000
    )
    let tokenStore = InMemoryGmailProviderTokenStore()
    for connection in [first, second] {
      try tokenStore.save(
        GmailProviderTokens(accessToken: connection.emailAddress, refreshToken: "refresh"),
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
    }
    let bodyReader = RecordingGmailMessageReader()
    let cacheStore = RecordingBackgroundContextCacheStore()
    let metadataStore = RecordingGmailProviderMetadataStore()
    let pushConnectionStore = RecordingPushConnectionStore(connection: first)
    let pushWatchStore = RecordingPushWatchStore()
    let transport = RecordingGmailConnectionTransport()
    transport.hasRemainingGmailConnections = true
    let service = GmailProviderConnectionService(
      backgroundContextCacheStore: cacheStore,
      bodyReader: bodyReader,
      pushConnectionStore: pushConnectionStore,
      pushWatchStore: pushWatchStore,
      metadataStore: metadataStore,
      tokenStore: tokenStore,
      transport: transport
    )

    try await service.clearLocalConnection(first, session: session)

    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: first.providerAccountIdentifier
      ) == nil)
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: second.providerAccountIdentifier
      ) != nil)
    #expect(bodyReader.clearedProviderAccountIdentifiers == [first.providerAccountIdentifier])
    #expect(
      cacheStore.clearedKeys == ["\(session.productAccountId):\(first.providerAccountIdentifier)"])
    #expect(
      metadataStore.clearedKeys == [
        "\(session.productAccountId):\(first.providerAccountIdentifier)"
      ])
    #expect(
      pushConnectionStore.clearedProviderAccountIdentifiers == [first.providerAccountIdentifier])
    #expect(
      pushWatchStore.clearedKeys == [
        "\(session.productAccountId):\(first.providerAccountIdentifier)"
      ])
    #expect(
      transport.removedOpaqueConnectionIds == [
        opaqueGmailConnectionId(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: first.providerAccountIdentifier
        )
      ])
  }

  @Test
  func testScopedCleanupModeDispatchesThroughProviderProtocol() async throws {
    let transport = RecordingGmailConnectionTransport()
    let bodyReader = RecordingGmailMessageReader()
    let cacheStore = RecordingBackgroundContextCacheStore()
    let metadataStore = RecordingGmailProviderMetadataStore()
    let provider: GmailProviderConnecting = GmailProviderConnectionService(
      backgroundContextCacheStore: cacheStore,
      bodyReader: bodyReader,
      pushConnectionStore: RecordingPushConnectionStore(connection: transport.status),
      pushWatchStore: RecordingPushWatchStore(),
      metadataStore: metadataStore,
      tokenStore: InMemoryGmailProviderTokenStore(),
      transport: transport
    )

    try await provider.clearLocalConnection(
      transport.status,
      session: session,
      allowsAccountWideCleanup: false
    )

    #expect(bodyReader.clearedSessions.isEmpty)
    #expect(cacheStore.clearedProductAccountIds.isEmpty)
    #expect(metadataStore.clearedProductAccountIds.isEmpty)
  }

  @Test
  func testClearLastLocalConnectionDeletesLegacyCredential() async throws {
    let productAccountId = "legacy-cleanup-\(UUID().uuidString)"
    let legacyAccount = "gmail-\(productAccountId)"
    let serviceName = "private-email.gmail-provider-tokens"
    let tokenStore = KeychainGmailProviderTokenStore()
    defer { try? tokenStore.clearAll(productAccountId: productAccountId) }
    try KeychainStore.writeString(
      #"{"accessToken":"legacy-access","refreshToken":"legacy-refresh"}"#,
      service: serviceName,
      account: legacyAccount
    )
    let legacySession = ProductAccountSessionSnapshot(
      appleUserIdentifier: session.appleUserIdentifier,
      identityToken: session.identityToken,
      productAccountId: productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )
    let transport = RecordingGmailConnectionTransport()
    let cacheStore = RecordingBackgroundContextCacheStore()
    let service = GmailProviderConnectionService(
      backgroundContextCacheStore: cacheStore,
      bodyReader: RecordingGmailMessageReader(),
      pushConnectionStore: RecordingPushConnectionStore(connection: transport.status),
      pushWatchStore: RecordingPushWatchStore(),
      metadataStore: RecordingGmailProviderMetadataStore(),
      tokenStore: tokenStore,
      transport: transport,
      credentialVerifier: StaticGmailCredentialVerifier(
        account: VerifiedGmailAccount(
          emailAddress: transport.status.emailAddress,
          providerAccountIdentifier: transport.status.providerAccountIdentifier,
          tokens: GmailProviderTokens(
            accessToken: "refreshed-access",
            refreshToken: "legacy-refresh"
          )
        )
      )
    )

    try await service.clearLocalConnection(transport.status, session: legacySession)

    #expect(try KeychainStore.readString(service: serviceName, account: legacyAccount) == nil)
    #expect(cacheStore.clearedProductAccountIds == [productAccountId])
  }

  @Test
  func testClearLocalConnectionDeletesMatchingLegacyCredentialWhenAnotherRouteRemains()
    async throws
  {
    let tokenStore = InMemoryGmailProviderTokenStore()
    tokenStore.saveLegacy(
      GmailProviderTokens(accessToken: "legacy-access", refreshToken: "legacy-refresh"),
      productAccountId: session.productAccountId
    )
    let transport = RecordingGmailConnectionTransport()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "scoped-access", refreshToken: "scoped-refresh"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: transport.status.providerAccountIdentifier
    )
    transport.hasRemainingGmailConnections = true
    let service = GmailProviderConnectionService(
      pushConnectionStore: RecordingPushConnectionStore(),
      tokenStore: tokenStore,
      transport: transport,
      credentialVerifier: StaticGmailCredentialVerifier(
        account: VerifiedGmailAccount(
          emailAddress: transport.status.emailAddress,
          providerAccountIdentifier: transport.status.providerAccountIdentifier,
          tokens: GmailProviderTokens(
            accessToken: "refreshed-access",
            refreshToken: "legacy-refresh",
            idToken: "gmail-identity-token"
          )
        )
      )
    )

    try await service.clearLocalConnection(transport.status, session: session)

    #expect(try tokenStore.loadLegacy(productAccountId: session.productAccountId) == nil)
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: transport.status.providerAccountIdentifier
      ) == nil)
  }

  @Test
  func testClearLocalConnectionPreservesUnverifiableLegacyCredentialAndClearsTargetStatus()
    async throws
  {
    let tokenStore = InMemoryGmailProviderTokenStore()
    tokenStore.saveLegacy(
      GmailProviderTokens(accessToken: "stale-access", refreshToken: "stale-refresh"),
      productAccountId: session.productAccountId
    )
    let transport = RecordingGmailConnectionTransport()
    transport.hasRemainingGmailConnections = true
    try tokenStore.save(
      GmailProviderTokens(accessToken: "scoped-access", refreshToken: "scoped-refresh"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: transport.status.providerAccountIdentifier
    )
    let pushConnectionStore = RecordingPushConnectionStore(connection: transport.status)
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      tokenStore: tokenStore,
      transport: transport,
      credentialVerifier: RejectingGmailCredentialVerifier()
    )

    try await service.clearLocalConnection(transport.status, session: session)

    #expect(try tokenStore.loadLegacy(productAccountId: session.productAccountId) != nil)
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: transport.status.providerAccountIdentifier
      ) == nil)
    #expect(
      pushConnectionStore.clearedProviderAccountIdentifiers == [
        transport.status.providerAccountIdentifier
      ])
  }

  @Test
  func testClearLocalConnectionDeletesUnverifiableLegacyCredentialWithMatchingOwnership()
    async throws
  {
    let tokenStore = InMemoryGmailProviderTokenStore()
    tokenStore.saveLegacy(
      GmailProviderTokens(accessToken: "stale-access", refreshToken: "stale-refresh"),
      productAccountId: session.productAccountId
    )
    let transport = RecordingGmailConnectionTransport()
    transport.hasRemainingGmailConnections = true
    let pushConnectionStore = RecordingPushConnectionStore(connection: transport.status)
    pushConnectionStore.legacyOwnedIdentifiers = [
      transport.status.providerAccountIdentifier
    ]
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      tokenStore: tokenStore,
      transport: transport,
      credentialVerifier: RejectingGmailCredentialVerifier()
    )

    try await service.clearLocalConnection(transport.status, session: session)

    #expect(try tokenStore.loadLegacy(productAccountId: session.productAccountId) == nil)
  }

  @Test
  func testClearLocalConnectionPreservesAnotherTokenOnlyMailbox() async throws {
    let removedConnection = RecordingGmailConnectionTransport().status
    let remainingProviderAccountIdentifier = "gmail-user-002"
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "removed-access", refreshToken: "removed-refresh"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: removedConnection.providerAccountIdentifier
    )
    try tokenStore.save(
      GmailProviderTokens(accessToken: "remaining-access", refreshToken: "remaining-refresh"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: remainingProviderAccountIdentifier
    )
    let bodyReader = RecordingGmailMessageReader()
    let cacheStore = RecordingBackgroundContextCacheStore()
    let metadataStore = RecordingGmailProviderMetadataStore()
    let pushConnectionStore = RecordingPushConnectionStore(connection: removedConnection)
    let service = GmailProviderConnectionService(
      backgroundContextCacheStore: cacheStore,
      bodyReader: bodyReader,
      pushConnectionStore: pushConnectionStore,
      pushWatchStore: RecordingPushWatchStore(),
      metadataStore: metadataStore,
      tokenStore: tokenStore,
      transport: RecordingGmailConnectionTransport()
    )

    try await service.clearLocalConnection(removedConnection, session: session)

    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: removedConnection.providerAccountIdentifier
      ) == nil)
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: remainingProviderAccountIdentifier
      ) != nil)
    #expect(bodyReader.clearedSessions.isEmpty)
    #expect(cacheStore.clearedProductAccountIds.isEmpty)
    #expect(metadataStore.clearedProductAccountIds.isEmpty)
    #expect(
      bodyReader.clearedProviderAccountIdentifiers == [removedConnection.providerAccountIdentifier])
    #expect(
      pushConnectionStore.clearedProviderAccountIdentifiers == [
        removedConnection.providerAccountIdentifier
      ])
  }

  @Test
  func testClearLocalConnectionDeletesScopedAliasForRemovedMailbox() async throws {
    let removedConnection = RecordingGmailConnectionTransport().status
    let obsoleteIdentifier = "obsolete-gmail-user"
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "alias-access", refreshToken: "alias-refresh"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: obsoleteIdentifier
    )
    let cacheStore = RecordingBackgroundContextCacheStore()
    let pushConnectionStore = RecordingPushConnectionStore(connection: removedConnection)
    let service = GmailProviderConnectionService(
      backgroundContextCacheStore: cacheStore,
      pushConnectionStore: pushConnectionStore,
      tokenStore: tokenStore,
      transport: RecordingGmailConnectionTransport(),
      credentialVerifier: StaticGmailCredentialVerifier(
        account: VerifiedGmailAccount(
          emailAddress: removedConnection.emailAddress,
          providerAccountIdentifier: removedConnection.providerAccountIdentifier,
          tokens: GmailProviderTokens(
            accessToken: "refreshed-access",
            refreshToken: "alias-refresh"
          )
        )
      )
    )

    try await service.clearLocalConnection(removedConnection, session: session)

    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: obsoleteIdentifier
      ) == nil)
    #expect(cacheStore.clearedProductAccountIds == [session.productAccountId])
  }

  @Test
  func testClearLocalConnectionPropagatesScopedAliasDeletionFailure() async throws {
    let removedConnection = RecordingGmailConnectionTransport().status
    let obsoleteIdentifier = "obsolete-gmail-user"
    let tokenStore = FailingClearGmailProviderTokenStore(
      failingProviderAccountIdentifier: obsoleteIdentifier,
      tokensByIdentifier: [
        obsoleteIdentifier: GmailProviderTokens(
          accessToken: "alias-access",
          refreshToken: "alias-refresh"
        )
      ]
    )
    let pushConnectionStore = RecordingPushConnectionStore(connection: removedConnection)
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      tokenStore: tokenStore,
      transport: RecordingGmailConnectionTransport(),
      credentialVerifier: StaticGmailCredentialVerifier(
        account: VerifiedGmailAccount(
          emailAddress: removedConnection.emailAddress,
          providerAccountIdentifier: removedConnection.providerAccountIdentifier,
          tokens: GmailProviderTokens(
            accessToken: "refreshed-access",
            refreshToken: "alias-refresh"
          )
        )
      )
    )

    do {
      try await service.clearLocalConnection(removedConnection, session: session)
      Issue.record("Expected alias token cleanup failure")
    } catch GmailProviderConnectionTestError.tokenCleanupFailed {
      #expect(pushConnectionStore.clearedProviderAccountIdentifiers.isEmpty)
      #expect(
        try tokenStore.load(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: obsoleteIdentifier
        ) != nil)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testHasLocalAuthorizationRecognizesMatchingLegacyOwnership() throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    tokenStore.saveLegacy(
      GmailProviderTokens(accessToken: "legacy-access", refreshToken: "legacy-refresh"),
      productAccountId: session.productAccountId
    )
    let pushConnectionStore = RecordingPushConnectionStore()
    pushConnectionStore.legacyOwnedIdentifiers = ["gmail-user-001"]
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      tokenStore: tokenStore,
      transport: RecordingGmailConnectionTransport()
    )

    #expect(
      try service.hasLocalAuthorization(
        providerAccountIdentifier: "gmail-user-001",
        session: session
      ))
    #expect(
      !(try service.hasLocalAuthorization(
        providerAccountIdentifier: "gmail-user-002",
        session: session
      )))
  }

  @Test
  func testClearLocalConnectionPreservesUnrelatedLegacyOnlyMailbox() async throws {
    let removedConnection = RecordingGmailConnectionTransport().status
    let tokenStore = InMemoryGmailProviderTokenStore()
    tokenStore.saveLegacy(
      GmailProviderTokens(accessToken: "legacy-access", refreshToken: "legacy-refresh"),
      productAccountId: session.productAccountId
    )
    let bodyReader = RecordingGmailMessageReader()
    let cacheStore = RecordingBackgroundContextCacheStore()
    let metadataStore = RecordingGmailProviderMetadataStore()
    let pushConnectionStore = RecordingPushConnectionStore(connection: removedConnection)
    let service = GmailProviderConnectionService(
      backgroundContextCacheStore: cacheStore,
      bodyReader: bodyReader,
      pushConnectionStore: pushConnectionStore,
      pushWatchStore: RecordingPushWatchStore(),
      metadataStore: metadataStore,
      tokenStore: tokenStore,
      transport: RecordingGmailConnectionTransport(),
      credentialVerifier: StaticGmailCredentialVerifier(
        account: VerifiedGmailAccount(
          emailAddress: "remaining@example.com",
          providerAccountIdentifier: "gmail-user-002",
          tokens: GmailProviderTokens(
            accessToken: "refreshed-access",
            refreshToken: "legacy-refresh"
          )
        )
      )
    )

    try await service.clearLocalConnection(removedConnection, session: session)

    #expect(try tokenStore.loadLegacy(productAccountId: session.productAccountId) != nil)
    #expect(bodyReader.clearedSessions.isEmpty)
    #expect(cacheStore.clearedProductAccountIds.isEmpty)
    #expect(metadataStore.clearedProductAccountIds.isEmpty)
    #expect(
      pushConnectionStore.clearedProviderAccountIdentifiers == [
        removedConnection.providerAccountIdentifier
      ])
    #expect(pushConnectionStore.clearedProductAccountIds.isEmpty)
  }

  @Test
  func testClearLocalConnectionDoesNotRemoveMailboxWhenCacheCannotBeCleared() async throws {
    let cacheStore = RecordingBackgroundContextCacheStore()
    cacheStore.clearError = GmailProviderConnectionTestError.tokenCleanupFailed
    let transport = RecordingGmailConnectionTransport()
    let service = GmailProviderConnectionService(
      backgroundContextCacheStore: cacheStore,
      transport: transport
    )

    do {
      try await service.clearLocalConnection(transport.status, session: session)
      Issue.record("Expected background context cache clear failure")
    } catch GmailProviderConnectionTestError.tokenCleanupFailed {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(transport.removedOpaqueConnectionIds.isEmpty)
  }

  @Test
  func testClearLocalConnectionContinuesLocalCleanupWhenRemoteRemovalFails() async throws {
    let transport = RecordingGmailConnectionTransport()
    transport.removeError = GmailProviderConnectionTestError.remoteRemovalFailed
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: transport.status.providerAccountIdentifier
    )
    let bodyReader = RecordingGmailMessageReader()
    let metadataStore = RecordingGmailProviderMetadataStore()
    let pushConnectionStore = RecordingPushConnectionStore(connection: transport.status)
    let pushWatchStore = RecordingPushWatchStore()
    let service = GmailProviderConnectionService(
      bodyReader: bodyReader,
      pushConnectionStore: pushConnectionStore,
      pushWatchStore: pushWatchStore,
      metadataStore: metadataStore,
      tokenStore: tokenStore,
      transport: transport
    )

    do {
      try await service.clearLocalConnection(transport.status, session: session)
      Issue.record("Expected remote removal failure")
    } catch GmailProviderConnectionTestError.remoteRemovalFailed {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: transport.status.providerAccountIdentifier
      ) == nil)
    #expect(
      bodyReader.clearedProviderAccountIdentifiers == [transport.status.providerAccountIdentifier])
    #expect(
      metadataStore.clearedKeys == [
        "\(session.productAccountId):\(transport.status.providerAccountIdentifier)"
      ])
    #expect(pushConnectionStore.clearedProviderAccountIdentifiers.isEmpty)
    #expect(
      pushWatchStore.clearedKeys == [
        "\(session.productAccountId):\(transport.status.providerAccountIdentifier)"
      ])
  }

  @Test
  func testAccountCleanupClearsScopedPushConnectionsWhenEnumerationFails() async throws {
    let pushConnectionStore = RecordingPushConnectionStore(
      connection: RecordingGmailConnectionTransport().status
    )
    pushConnectionStore.loadAllError = GmailProviderConnectionTestError.tokenLoadFailed
    let pushWatchStore = RecordingPushWatchStore()
    let notificationPrefix =
      "gmail-push-notification-receipts."
      + gmailSafeFileComponent(session.productAccountId)
      + "."
    let notificationKey = notificationPrefix + "enumeration-failure"
    UserDefaults.standard.set(["gmail:gmail-user-001:message-001"], forKey: notificationKey)
    defer { UserDefaults.standard.removeObject(forKey: notificationKey) }
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      pushWatchStore: pushWatchStore,
      tokenStore: InMemoryGmailProviderTokenStore(),
      transport: RecordingGmailConnectionTransport()
    )

    do {
      try await service.clearLocalConnection(session: session)
      Issue.record("Expected connection enumeration failure")
    } catch GmailProviderConnectionTestError.tokenLoadFailed {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(pushWatchStore.clearedAllProductAccountIds == [session.productAccountId])
    #expect(pushConnectionStore.clearedProductAccountIds.isEmpty)
    #expect(pushConnectionStore.clearedScopedProductAccountIds == [session.productAccountId])
    #expect(
      !(UserDefaults.standard.dictionaryRepresentation().keys.contains {
        $0.hasPrefix(notificationPrefix)
      }))
  }

  @Test
  func testAccountCleanupDeletesUnreadableLegacyPushConnection() async throws {
    let productAccountId = "\(session.productAccountId)-\(UUID().uuidString)"
    let keychainService = "private-email.gmail-push-connection"
    let legacyAccount =
      "gmail-push-connection.\(legacyGmailSafeFileComponent(productAccountId))"
    let cleanupSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: session.appleUserIdentifier,
      identityToken: session.identityToken,
      productAccountId: productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )
    let pushConnectionStore = KeychainGmailPushConnectionStore()
    defer { try? pushConnectionStore.clearAll(productAccountId: productAccountId) }
    try KeychainStore.writeString(
      "not-json",
      service: keychainService,
      account: legacyAccount
    )
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      pushWatchStore: RecordingPushWatchStore(),
      tokenStore: InMemoryGmailProviderTokenStore(),
      transport: RecordingGmailConnectionTransport()
    )

    do {
      try await service.clearLocalConnection(session: cleanupSession)
      Issue.record("Expected connection enumeration failure")
    } catch is DecodingError {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(try KeychainStore.readString(service: keychainService, account: legacyAccount) == nil)
  }

  @Test
  func testClearLocalConnectionPreservesSharedMailboxWatch() async throws {
    let transport = RecordingGmailConnectionTransport()
    transport.shouldStopWatch = false
    let tokenStore = InMemoryGmailProviderTokenStore()
    let pushWatchStopper = RecordingPushWatchStopper(tokenStore: tokenStore)
    let pushConnectionStore = RecordingPushConnectionStore(connection: transport.status)
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      pushWatchStopper: pushWatchStopper,
      tokenStore: tokenStore,
      transport: transport
    )

    try await service.clearLocalConnection(session: session)

    #expect(pushWatchStopper.stoppedConnection == nil)
    #expect(pushConnectionStore.clearedProductAccountIds == [session.productAccountId])
  }

  @Test
  func testClearLocalConnectionTreatsWatchStopFailureAsBestEffort() async throws {
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001"
    )
    let pushWatchStopper = RecordingPushWatchStopper(tokenStore: tokenStore)
    pushWatchStopper.stopError = GmailProviderConnectionTestError.watchStopFailed
    let pushConnectionStore = RecordingPushConnectionStore(
      connection: RecordingGmailConnectionTransport().status
    )
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      pushWatchStopper: pushWatchStopper,
      tokenStore: tokenStore,
      transport: RecordingGmailConnectionTransport()
    )

    try await service.clearLocalConnection(session: session)

    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: "gmail-user-001"
      ) == nil)
    #expect(pushConnectionStore.clearedProductAccountIds == [session.productAccountId])
  }

  @Test
  func testClearConnectionPreservesOwnershipWhenWatchCleanupFails() async throws {
    let transport = RecordingGmailConnectionTransport()
    let pushConnectionStore = RecordingPushConnectionStore(connection: transport.status)
    let pushWatchStore = RecordingPushWatchStore()
    pushWatchStore.clearError = GmailProviderConnectionTestError.watchStopFailed
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      pushWatchStore: pushWatchStore,
      transport: transport
    )

    do {
      try await service.clearLocalConnection(transport.status, session: session)
      Issue.record("Expected push watch cleanup failure")
    } catch GmailProviderConnectionTestError.watchStopFailed {
      #expect(pushConnectionStore.clearedProviderAccountIdentifiers.isEmpty)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testClearAllPreservesConnectionsWhenWatchCleanupFails() async throws {
    let transport = RecordingGmailConnectionTransport()
    let pushConnectionStore = RecordingPushConnectionStore(connection: transport.status)
    let pushWatchStore = RecordingPushWatchStore()
    pushWatchStore.clearError = GmailProviderConnectionTestError.watchStopFailed
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      pushWatchStore: pushWatchStore,
      transport: transport
    )

    do {
      try await service.clearLocalConnection(session: session)
      Issue.record("Expected push watch cleanup failure")
    } catch GmailProviderConnectionTestError.watchStopFailed {
      #expect(pushConnectionStore.clearedProductAccountIds.isEmpty)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testClearLocalConnectionAttemptsMetadataCleanupWhenTokenCleanupFails() async throws {
    let tokenStore = FailingClearGmailProviderTokenStore()
    let metadataStore = RecordingGmailProviderMetadataStore()
    let service = GmailProviderConnectionService(
      metadataStore: metadataStore,
      tokenStore: tokenStore,
      transport: RecordingGmailConnectionTransport()
    )

    do {
      try await service.clearLocalConnection(session: session)
      Issue.record("Expected token cleanup failure")
    } catch GmailProviderConnectionTestError.tokenCleanupFailed {
      #expect(metadataStore.clearedProductAccountIds == [session.productAccountId])
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testClearLocalConnectionRetriesLateCleanupAfterTokensAreRemoved() async throws {
    let transport = RecordingGmailConnectionTransport()
    let tokenStore = InMemoryGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId,
      providerAccountIdentifier: transport.status.providerAccountIdentifier
    )
    let metadataStore = RecordingGmailProviderMetadataStore()
    metadataStore.clearError = GmailProviderConnectionTestError.metadataCleanupFailed
    let pushConnectionStore = RecordingPushConnectionStore(connection: transport.status)
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      metadataStore: metadataStore,
      tokenStore: tokenStore,
      transport: transport
    )

    do {
      try await service.clearLocalConnection(transport.status, session: session)
      Issue.record("Expected metadata cleanup failure")
    } catch GmailProviderConnectionTestError.metadataCleanupFailed {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(transport.removedOpaqueConnectionIds.count == 1)
    #expect(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: transport.status.providerAccountIdentifier
      ) == nil)
    let visibleStatuses = try await service.loadConnections(session: session)
    #expect(visibleStatuses == [transport.status])
    #expect(!(try service.hasLocalAuthorization(transport.status, session: session)))
    let retryStatus = try requireValue(
      try service.loadConnectionForCleanup(
        providerAccountIdentifier: transport.status.providerAccountIdentifier,
        session: session
      ))

    metadataStore.clearError = nil
    try await service.clearLocalConnection(retryStatus, session: session)

    #expect(transport.removedOpaqueConnectionIds.count == 2)
    #expect(
      try service.loadConnectionForCleanup(
        providerAccountIdentifier: transport.status.providerAccountIdentifier,
        session: session
      ) == nil)
  }

  @Test
  func testLoadConnectionForCleanupIsolatesUnreadableConnectionStatus() throws {
    let pushConnectionStore = RecordingPushConnectionStore()
    pushConnectionStore.loadError = GmailProviderConnectionTestError.pushConnectionLoadFailed
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      transport: RecordingGmailConnectionTransport()
    )

    #expect(
      try service.loadConnectionForCleanup(
        providerAccountIdentifier: "gmail-user-001",
        session: session
      ) == nil)
  }

  @Test
  func testVerifierRequiresGmailProfileAccessBeforeReturningVerifiedAccount() async throws {
    let session = ConvexClientTesting.makeSession { request in
      if request.url?.path == "/token" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: request.url?.path == "/gmail/v1/users/me/profile" ? 403 : 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, Data("{}".utf8))
    }
    let verifier = GoogleGmailProviderCredentialVerifier(
      oauthClientId: "gmail-client-id",
      session: session
    )

    do {
      _ = try await verifier.verify(
        accessToken: "access-token",
        refreshToken: "refresh-token"
      )
      Issue.record("Expected Gmail authorization failure")
    } catch GmailProviderCredentialVerificationError.missingGmailAuthorization {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testVerifierRejectsMetadataOnlyGmailAuthorization() async throws {
    let session = ConvexClientTesting.makeSession { request in
      if request.url?.path == "/token" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }
      if request.url?.path == "/gmail/v1/users/me/profile" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"emailAddress":"user@example.com"}"#.utf8)
        )
      }
      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(
          #"{"scope":"https://www.googleapis.com/auth/gmail.metadata","sub":"gmail-user-001"}"#
            .utf8)
      )
    }
    let verifier = GoogleGmailProviderCredentialVerifier(
      oauthClientId: "gmail-client-id",
      session: session
    )

    do {
      _ = try await verifier.verify(
        accessToken: "access-token",
        refreshToken: "refresh-token"
      )
      Issue.record("Expected insufficient Gmail scope")
    } catch GmailProviderCredentialVerificationError.insufficientGmailScope {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testVerifierRequiresRefreshTokenForSameGmailAccount() async throws {
    let session = ConvexClientTesting.makeSession { request in
      let path = request.url?.path
      if path == "/gmail/v1/users/me/profile" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"emailAddress":"user@example.com"}"#.utf8)
        )
      }

      if path == "/token" {
        let body = Self.httpBodyString(for: request)
        #expect(request.httpMethod == "POST")
        #expect(
          request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(body?.contains("client_id=gmail-client-id") == true)
        #expect(body?.contains("grant_type=refresh_token") == true)
        #expect(body?.contains("refresh_token=refresh-token") == true)
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }

      if path == "/v1/userinfo" {
        let subject =
          request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token"
          ? "gmail-user-001" : "other-gmail-user"
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"sub":"\#(subject)"}"#.utf8)
        )
      }

      if request.url?.query == "access_token=access-token" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"scope":"\#(Self.gmailReadScope)"}"#.utf8)
        )
      }

      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(#"{"scope":"\#(Self.gmailReadScope)"}"#.utf8)
      )
    }
    let verifier = GoogleGmailProviderCredentialVerifier(
      oauthClientId: "gmail-client-id",
      session: session
    )

    do {
      _ = try await verifier.verify(
        accessToken: "access-token",
        refreshToken: "refresh-token"
      )
      Issue.record("Expected account mismatch")
    } catch GmailProviderCredentialVerificationError.accountMismatch {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testVerifierRequiresRefreshedAccessTokenToHaveGmailProfileAccess() async throws {
    let session = ConvexClientTesting.makeSession { request in
      let path = request.url?.path
      if path == "/gmail/v1/users/me/profile" {
        let statusCode =
          request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token" ? 200 : 403
        return (
          Self.httpResponse(for: request, statusCode: statusCode),
          Data(#"{"emailAddress":"user@example.com"}"#.utf8)
        )
      }

      if path == "/token" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }

      if path == "/v1/userinfo" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"sub":"gmail-user-001"}"#.utf8)
        )
      }

      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(#"{"scope":"\#(Self.gmailReadScope)"}"#.utf8)
      )
    }
    let verifier = GoogleGmailProviderCredentialVerifier(
      oauthClientId: "gmail-client-id",
      session: session
    )

    do {
      _ = try await verifier.verify(
        accessToken: "access-token",
        refreshToken: "refresh-token"
      )
      Issue.record("Expected Gmail authorization failure")
    } catch GmailProviderCredentialVerificationError.missingGmailAuthorization {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testVerifierReturnsVerifiedAccountAfterAccessRefreshAndGmailChecksPass() async throws {
    var profileAuthorizations: [String] = []
    let session = ConvexClientTesting.makeSession { request in
      let path = request.url?.path
      if path == "/gmail/v1/users/me/profile" {
        if let authorization = request.value(forHTTPHeaderField: "Authorization") {
          profileAuthorizations.append(authorization)
        }
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"emailAddress":"user@example.com"}"#.utf8)
        )
      }

      if path == "/token" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(
            #"{"access_token":"refreshed-access-token","id_token":"refreshed-id-token"}"#.utf8
          )
        )
      }

      if path == "/v1/userinfo" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"sub":"gmail-user-001"}"#.utf8)
        )
      }

      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(#"{"scope":"https://www.googleapis.com/auth/gmail.readonly"}"#.utf8)
      )
    }
    let verifier = GoogleGmailProviderCredentialVerifier(
      oauthClientId: "gmail-client-id",
      session: session
    )

    let account = try await verifier.verify(
      accessToken: "access-token",
      refreshToken: "refresh-token"
    )

    #expect(account.emailAddress == "user@example.com")
    #expect(account.providerAccountIdentifier == "gmail-user-001")
    #expect(profileAuthorizations == ["Bearer refreshed-access-token", "Bearer access-token"])
    #expect(
      account.tokens
        == GmailProviderTokens(
          accessToken: "refreshed-access-token",
          refreshToken: "refresh-token",
          idToken: "refreshed-id-token"
        ))
  }

  @Test
  func testVerifierUsesGmailProfileEmailWhenTokenInfoOmitsEmail() async throws {
    let session = ConvexClientTesting.makeSession { request in
      let path = request.url?.path
      if path == "/gmail/v1/users/me/profile" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"emailAddress":"user@example.com"}"#.utf8)
        )
      }

      if path == "/token" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }

      if path == "/v1/userinfo" {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"sub":"gmail-user-001"}"#.utf8)
        )
      }

      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(#"{"scope":"https://www.googleapis.com/auth/gmail.readonly"}"#.utf8)
      )
    }
    let verifier = GoogleGmailProviderCredentialVerifier(
      oauthClientId: "gmail-client-id",
      session: session
    )

    let account = try await verifier.verify(
      accessToken: "access-token",
      refreshToken: "refresh-token"
    )

    #expect(account.emailAddress == "user@example.com")
    #expect(account.providerAccountIdentifier == "gmail-user-001")
  }

  @Test
  func testGoogleOAuthRequestUsesPKCEAndIdentityAndGmailScopes() throws {
    let request = GoogleGmailOAuthRequest(
      clientIdentifier: "123.apps.googleusercontent.com",
      codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
      state: "oauth-state"
    )
    let authorizationURL = try requireValue(request.authorizationURL)
    let components = try requireValue(
      URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
    let query = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
      }
    )

    #expect(request.callbackScheme == "com.googleusercontent.apps.123")
    #expect(request.redirectURI?.absoluteString == "com.googleusercontent.apps.123:/oauth2redirect")
    #expect(query["access_type"] == "offline")
    #expect(query["client_id"] == "123.apps.googleusercontent.com")
    #expect(query["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(query["code_challenge_method"] == "S256")
    #expect(query["prompt"] == "select_account consent")
    #expect(query["response_type"] == "code")
    #expect(query["scope"] == GoogleGmailOAuthRequest.authorizationScope)
    #expect(query["state"] == "oauth-state")
  }

  @Test
  func testGoogleOAuthRequestRejectsCallbackWithDifferentState() throws {
    let request = GoogleGmailOAuthRequest(
      clientIdentifier: "123.apps.googleusercontent.com",
      codeVerifier: "code-verifier",
      state: "expected-state"
    )
    let callbackURL = try requireValue(
      URL(string: "com.googleusercontent.apps.123:/oauth2redirect?code=code&state=other-state"))

    #expect {
      try request.authorizationCode(from: callbackURL)
    } throws: { error in
      guard case GoogleGmailOAuthError.invalidAuthorizationState = error else {
        Issue.record("Unexpected error: \(error)")
        return true
      }
      return true
    }
  }

  @MainActor
  @Test
  func testGoogleOAuthTokenExchangeReturnsAccessAndRefreshTokens() async throws {
    let session = ConvexClientTesting.makeSession { request in
      #expect(request.httpMethod == "POST")
      #expect(
        request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
      let body = Self.httpBodyString(for: request)
      #expect(body?.contains("client_id=123.apps.googleusercontent.com") == true)
      #expect(body?.contains("code=authorization-code") == true)
      #expect(body?.contains("code_verifier=code-verifier") == true)
      #expect(body?.contains("grant_type=authorization_code") == true)
      #expect(
        body?.contains("redirect_uri=com.googleusercontent.apps.123%3A%2Foauth2redirect") == true)
      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(
          #"{"access_token":"access-token","id_token":"gmail-identity-token","refresh_token":"refresh-token"}"#
            .utf8
        )
      )
    }
    let service = GoogleGmailOAuthService(
      clientIdentifier: "123.apps.googleusercontent.com",
      session: session,
      tokenEndpoint: URL(string: "https://oauth.example.test/token")!
    )
    let request = GoogleGmailOAuthRequest(
      clientIdentifier: "123.apps.googleusercontent.com",
      codeVerifier: "code-verifier",
      state: "oauth-state"
    )

    let tokens = try await service.exchangeAuthorizationCode(
      "authorization-code",
      request: request
    )

    #expect(
      tokens
        == GmailProviderTokens(
          accessToken: "access-token",
          refreshToken: "refresh-token",
          idToken: "gmail-identity-token"
        ))
  }

  @Test
  func testBundledOAuthClientIdReadsGeneratedInfoPlistKey() throws {
    let bundle = try Self.makeBundle(
      infoDictionary: [
        GmailOAuthClientIdConfiguration.infoDictionaryKey: " bundled-client-id "
      ]
    )

    #expect(GmailOAuthClientIdConfiguration.bundledValue(bundle: bundle) == "bundled-client-id")
  }

  @Test
  func testBundledOAuthClientIdIgnoresUnresolvedBuildSettingPlaceholder() throws {
    let bundle = try Self.makeBundle(
      infoDictionary: [
        GmailOAuthClientIdConfiguration.infoDictionaryKey: "$(GMAIL_OAUTH_CLIENT_ID)"
      ]
    )

    #expect(GmailOAuthClientIdConfiguration.bundledValue(bundle: bundle) == nil)
  }

  private static func httpResponse(
    for request: URLRequest,
    statusCode: Int
  ) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
  }

  private static func httpBodyString(for request: URLRequest) -> String? {
    if let body = request.httpBody {
      return String(data: body, encoding: .utf8)
    }

    guard let stream = request.httpBodyStream else {
      return nil
    }

    stream.open()
    defer {
      stream.close()
    }

    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer {
      buffer.deallocate()
    }

    while stream.hasBytesAvailable {
      let count = stream.read(buffer, maxLength: bufferSize)
      if count <= 0 {
        break
      }
      data.append(buffer, count: count)
    }

    return String(data: data, encoding: .utf8)
  }

  private static func makeBundle(infoDictionary: [String: String]) throws -> Bundle {
    let bundleURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("bundle")
    try FileManager.default.createDirectory(
      at: bundleURL,
      withIntermediateDirectories: true
    )
    let infoPlistURL = bundleURL.appendingPathComponent("Info.plist")
    let data = try PropertyListSerialization.data(
      fromPropertyList: infoDictionary,
      format: .xml,
      options: 0
    )
    try data.write(to: infoPlistURL)

    guard let bundle = Bundle(url: bundleURL) else {
      throw GmailProviderConnectionTestError.bundleCreationFailed
    }

    return bundle
  }
}
// swiftlint:enable type_body_length

private enum GmailProviderConnectionTestError: Error {
  case bodyCacheCleanupFailed
  case bundleCreationFailed
  case metadataCleanupFailed
  case pushConnectionLoadFailed
  case registrationFailed
  case remoteRemovalFailed
  case tokenCleanupFailed
  case tokenLoadFailed
  case watchStopFailed
}

private struct StaticGmailCredentialVerifier: GmailProviderCredentialVerifying {
  let account: VerifiedGmailAccount

  func verify(
    accessToken _: String,
    refreshToken _: String
  ) async throws -> VerifiedGmailAccount {
    account
  }
}

private final class CountingGmailCredentialVerifier: GmailProviderCredentialVerifying {
  var verificationCount = 0

  func verify(
    accessToken _: String,
    refreshToken _: String
  ) async throws -> VerifiedGmailAccount {
    verificationCount += 1
    throw GmailProviderConnectionTestError.tokenLoadFailed
  }
}

private struct RejectingGmailCredentialVerifier: GmailProviderCredentialVerifying {
  func verify(
    accessToken _: String,
    refreshToken _: String
  ) async throws -> VerifiedGmailAccount {
    throw GmailProviderConnectionTestError.tokenLoadFailed
  }
}

private struct FailingGmailMessageReader: GmailMessageReading {
  func clearCachedMessageBodies(session _: ProductAccountSessionSnapshot) throws {
    throw GmailProviderConnectionTestError.bodyCacheCleanupFailed
  }

  func clearCachedMessageBodies(
    connection _: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) throws {
    throw GmailProviderConnectionTestError.bodyCacheCleanupFailed
  }

  func loadMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageBody {
    throw GmailProviderConnectionTestError.bodyCacheCleanupFailed
  }

  func removeCachedMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws {
    throw GmailProviderConnectionTestError.bodyCacheCleanupFailed
  }
}

private final class RecordingGmailMessageReader: GmailMessageReading {
  var clearedSessions: [ProductAccountSessionSnapshot] = []
  var clearedProviderAccountIdentifiers: [String] = []

  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws {
    clearedSessions.append(session)
  }

  func clearCachedMessageBodies(
    connection: GmailProviderConnectionStatus,
    session _: ProductAccountSessionSnapshot
  ) throws {
    clearedProviderAccountIdentifiers.append(connection.providerAccountIdentifier)
  }

  func loadMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageBody {
    throw GmailProviderConnectionTestError.bodyCacheCleanupFailed
  }

  func removeCachedMessageBody(
    message _: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws {
    throw GmailProviderConnectionTestError.bodyCacheCleanupFailed
  }
}

private final class RecordingGmailConnectionTransport: GmailProviderConnectionTransport {
  struct ConnectCall: Equatable {
    let gmailIdentityToken: String
    let identityToken: String
    let opaqueConnectionId: String
    let trustedDeviceId: String
  }

  var connectCall: ConnectCall?
  var connectCalls: [ConnectCall] = []
  var connectError: Error?
  var onConnect: (() throws -> Void)?
  var connectStatus: GmailOperationalConnectionStatus?
  var status = GmailProviderConnectionStatus(
    connectedAt: 1_781_200_000_000,
    emailAddress: "user@example.com",
    lastVerifiedAt: 1_781_200_000_000,
    provider: "gmail",
    providerAccountIdentifier: "gmail-user-001",
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_000
  )
  var shouldStopError: Error?
  var shouldStopWatch = true
  var hasRemainingGmailConnections = false
  var removeError: Error?
  var removedOpaqueConnectionIds: [String] = []

  func registerGmailConnection(
    gmailIdentityToken: String,
    identityToken: String,
    opaqueConnectionId: String,
    trustedDeviceId: String
  ) async throws -> GmailOperationalConnectionStatus {
    let connectCall = ConnectCall(
      gmailIdentityToken: gmailIdentityToken,
      identityToken: identityToken,
      opaqueConnectionId: opaqueConnectionId,
      trustedDeviceId: trustedDeviceId
    )
    self.connectCall = connectCall
    connectCalls.append(connectCall)
    try onConnect?()
    if let connectError {
      throw connectError
    }

    return connectStatus
      ?? GmailOperationalConnectionStatus(
        connectedAt: status.connectedAt,
        lastVerifiedAt: status.lastVerifiedAt,
        opaqueConnectionId: opaqueConnectionId,
        trustedDeviceId: status.trustedDeviceId,
        updatedAt: status.updatedAt
      )
  }

  func shouldStopGmailPushWatch(
    identityToken _: String,
    opaqueConnectionId _: String,
    trustedDeviceId _: String
  ) async throws -> Bool {
    if let shouldStopError {
      throw shouldStopError
    }
    return shouldStopWatch
  }

  func removeGmailConnection(
    identityToken _: String,
    opaqueConnectionId: String,
    trustedDeviceId _: String
  ) async throws -> Bool {
    removedOpaqueConnectionIds.append(opaqueConnectionId)
    if let removeError {
      throw removeError
    }
    return hasRemainingGmailConnections
  }
}

private final class FailingClearGmailProviderTokenStore: GmailProviderTokenPersisting {
  private let failingProviderAccountIdentifier: String?
  private var tokensByIdentifier: [String: GmailProviderTokens]

  init(
    failingProviderAccountIdentifier: String? = nil,
    tokensByIdentifier: [String: GmailProviderTokens] = [:]
  ) {
    self.failingProviderAccountIdentifier = failingProviderAccountIdentifier
    self.tokensByIdentifier = tokensByIdentifier
  }

  func clear(productAccountId _: String, providerAccountIdentifier: String) throws {
    if failingProviderAccountIdentifier == nil
      || failingProviderAccountIdentifier == providerAccountIdentifier
    {
      throw GmailProviderConnectionTestError.tokenCleanupFailed
    }
    tokensByIdentifier[providerAccountIdentifier] = nil
  }

  func clearAll(productAccountId _: String) throws {
    if failingProviderAccountIdentifier == nil {
      throw GmailProviderConnectionTestError.tokenCleanupFailed
    }
    tokensByIdentifier.removeAll()
  }

  func load(
    productAccountId _: String,
    providerAccountIdentifier: String
  ) throws -> GmailProviderTokens? {
    tokensByIdentifier[providerAccountIdentifier]
  }

  func loadAll(productAccountId _: String) throws -> [String: GmailProviderTokens] {
    tokensByIdentifier
  }

  func save(
    _: GmailProviderTokens,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}
}

private final class FailingLoadGmailProviderTokenStore: GmailProviderTokenPersisting {
  func clear(productAccountId _: String, providerAccountIdentifier _: String) throws {}

  func clearAll(productAccountId _: String) throws {}

  func load(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> GmailProviderTokens? {
    throw GmailProviderConnectionTestError.tokenLoadFailed
  }

  func loadAll(productAccountId _: String) throws -> [String: GmailProviderTokens] {
    throw GmailProviderConnectionTestError.tokenLoadFailed
  }

  func save(
    _: GmailProviderTokens,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}
}

private final class RecordingPushConnectionStore: GmailPushConnectionPersisting {
  var clearedProductAccountIds: [String] = []
  var clearedScopedProductAccountIds: [String] = []
  var clearedProviderAccountIdentifiers: [String] = []
  var connections: [GmailProviderConnectionStatus]
  var legacyOwnedIdentifiers: Set<String> = []
  var loadedProductAccountId: String?
  var loadError: Error?
  var loadAllError: Error?
  var connection: GmailProviderConnectionStatus? { connections.first }

  init(connection: GmailProviderConnectionStatus? = nil) {
    connections = connection.map { [$0] } ?? []
  }

  func clearAll(productAccountId: String) throws {
    clearedProductAccountIds.append(productAccountId)
  }

  func clearScoped(productAccountId: String) throws {
    clearedScopedProductAccountIds.append(productAccountId)
  }

  func hasLegacyOwnership(
    productAccountId _: String,
    providerAccountIdentifier: String
  ) throws -> Bool {
    legacyOwnedIdentifiers.contains(providerAccountIdentifier)
  }

  func clear(
    productAccountId _: String,
    providerAccountIdentifier: String
  ) throws {
    clearedProviderAccountIdentifiers.append(providerAccountIdentifier)
    connections.removeAll {
      $0.providerAccountIdentifier == providerAccountIdentifier
    }
  }

  func load(
    productAccountId _: String,
    providerAccountIdentifier: String
  ) throws -> GmailProviderConnectionStatus? {
    if let loadError {
      throw loadError
    }
    return connection?.providerAccountIdentifier == providerAccountIdentifier ? connection : nil
  }

  func loadAll(productAccountId: String) throws -> [GmailProviderConnectionStatus] {
    loadedProductAccountId = productAccountId
    if let loadAllError {
      throw loadAllError
    }
    return connections
  }

  func save(
    _ connection: GmailProviderConnectionStatus,
    productAccountId: String
  ) throws {
    loadedProductAccountId = productAccountId
    connections.removeAll {
      $0.providerAccountIdentifier == connection.providerAccountIdentifier
    }
    connections.append(connection)
  }
}

private final class RecordingPushWatchStopper: GmailPushWatchStopping {
  private let tokenStore: GmailProviderTokenPersisting
  var stoppedConnection: GmailProviderConnectionStatus?
  var stoppedSession: ProductAccountSessionSnapshot?
  var tokensWereAvailable = false
  var stopError: Error?

  init(tokenStore: GmailProviderTokenPersisting) {
    self.tokenStore = tokenStore
  }

  func stop(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot,
    tokens: GmailProviderTokens?
  ) async throws {
    stoppedConnection = connection
    stoppedSession = session
    if tokens != nil {
      tokensWereAvailable = true
    } else {
      tokensWereAvailable =
        try tokenStore.load(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        ) != nil
    }
    if let stopError {
      throw stopError
    }
  }
}

private final class RecordingPushWatchStore: GmailPushWatchPersisting {
  var clearError: Error?
  var clearedKeys: [String] = []
  var clearedAllProductAccountIds: [String] = []

  func clearAll(productAccountId: String) throws {
    if let clearError { throw clearError }
    clearedAllProductAccountIds.append(productAccountId)
  }

  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    if let clearError { throw clearError }
    clearedKeys.append("\(productAccountId):\(providerAccountIdentifier)")
  }

  func load(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> GmailPushWatchStatus? {
    nil
  }

  func save(
    _: GmailPushWatchStatus,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}
}

private final class RecordingBackgroundContextCacheStore: BackgroundContextCachePersisting {
  var clearError: Error?
  private(set) var clearedProductAccountIds: [String] = []
  private(set) var clearedKeys: [String] = []

  func clear(productAccountId: String) throws {
    clearedProductAccountIds.append(productAccountId)
    if let clearError { throw clearError }
  }

  func clear(productAccountId: String, providerAccountIdentifier: String) throws {
    clearedKeys.append("\(productAccountId):\(providerAccountIdentifier)")
    if let clearError { throw clearError }
  }

  func load(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> BackgroundCategorizationContextCache? {
    nil
  }

  func save(
    _: BackgroundCategorizationContextCache,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}
}

private final class RecordingGmailProviderMetadataStore: GmailMessageMetadataPersisting {
  var clearError: Error?
  var clearedProductAccountIds: [String] = []
  var clearedKeys: [String] = []

  func clearMessages(productAccountId: String) throws {
    clearedProductAccountIds.append(productAccountId)
    if let clearError {
      throw clearError
    }
  }

  func clearMessages(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    clearedKeys.append("\(productAccountId):\(providerAccountIdentifier)")
    if let clearError {
      throw clearError
    }
  }

  func loadMessages(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> [GmailMessageMetadata] {
    []
  }

  func saveMessages(
    _: [GmailMessageMetadata],
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}
}
