import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
final class GmailProviderConnectionServiceTests: XCTestCase {
  private static let gmailReadScope = "https://www.googleapis.com/auth/gmail.readonly"

  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "apple-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

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

    let connection = status.mailboxConnection(productAccountId: session.productAccountId)

    XCTAssertEqual(connection.productAccountId, ProductAccountId(session.productAccountId))
    XCTAssertEqual(connection.providerId, .gmail)
    XCTAssertEqual(
      connection.providerMailboxIdentity,
      StableProviderMailboxIdentity(providerId: .gmail, value: "gmail-user-001")
    )
    XCTAssertEqual(
      connection.id,
      MailboxConnectionId(
        providerMailboxIdentity: connection.providerMailboxIdentity
      )
    )
    XCTAssertEqual(connection.displayName, "user@example.com")
    XCTAssertTrue(connection.capabilities.canSynchronizeMetadata)
    XCTAssertTrue(connection.capabilities.canReadMessages)
    XCTAssertTrue(connection.capabilities.canRegisterPush)
    XCTAssertTrue(connection.capabilities.canSearchProvider)
    XCTAssertTrue(connection.capabilities.canSend)
    XCTAssertEqual(connection.capabilities.providerActions, Set(ProviderMailAction.allCases))
  }

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

    XCTAssertEqual(message.mailboxConnectionId, connectionId)
    XCTAssertEqual(message.id, message.stableIdentity)
    XCTAssertEqual(
      message.threadIdentity,
      MailboxThreadIdentity(connectionId: connectionId, providerThreadId: "thread-001")
    )
    XCTAssertEqual(
      message.stableIdentity,
      StableProviderMessageIdentity(
        connectionId: connectionId,
        providerMessageId: "message-001"
      )
    )
    XCTAssertEqual(GmailInboxThread.group([message])[0].id, message.threadIdentity)

    let otherConnectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-002"
      )
    )
    let mailboxMessage = message.mailboxMetadata(connectionId: connectionId)
    let otherMailboxMessage = message.mailboxMetadata(connectionId: otherConnectionId)

    XCTAssertEqual(mailboxMessage.stableProviderMessageId, "gmail:gmail-user-001:message-001")
    XCTAssertEqual(MailboxThread.group([mailboxMessage, otherMailboxMessage]).count, 2)
  }

  func testGmailIdentityTokenIsExcludedFromTokenPersistence() throws {
    let encoded = try JSONEncoder().encode(
      GmailProviderTokens(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        idToken: "transient-id-token"
      )
    )
    let decoded = try JSONDecoder().decode(GmailProviderTokens.self, from: encoded)

    XCTAssertNil(encoded.range(of: Data("transient-id-token".utf8)))
    XCTAssertEqual(
      decoded,
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token")
    )
  }

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

    XCTAssertEqual(status.emailAddress, "user@example.com")
    XCTAssertEqual(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: "gmail-user-001"
      ),
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token")
    )
    XCTAssertEqual(transport.connectCall?.identityToken, "apple-token")
    XCTAssertEqual(transport.connectCall?.trustedDeviceId, "trusted-device-001")
    XCTAssertEqual(transport.connectCall?.gmailIdentityToken, "gmail-identity-token")
    XCTAssertEqual(
      transport.connectCall?.opaqueConnectionId,
      opaqueGmailConnectionId(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: "gmail-user-001"
      )
    )
    XCTAssertEqual(pushConnectionStore.connections, [status])
  }

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

    XCTAssertEqual(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: "gmail-user-001"
      )?.accessToken,
      "access-gmail-user-001"
    )
    XCTAssertEqual(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: "gmail-user-002"
      )?.accessToken,
      "access-gmail-user-002"
    )
  }

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
      XCTFail("Expected backend registration failure")
    } catch GmailProviderConnectionTestError.registrationFailed {
      XCTAssertNil(
        try tokenStore.load(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: "gmail-user-001"
        )
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

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
      XCTFail("Expected backend registration failure")
    } catch GmailProviderConnectionTestError.registrationFailed {
      XCTAssertEqual(
        try tokenStore.load(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: "gmail-user-001"
        ),
        GmailProviderTokens(accessToken: "old-access-token", refreshToken: "old-refresh-token")
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

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
      XCTFail("Expected backend registration failure")
    } catch GmailProviderConnectionTestError.registrationFailed {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertTrue(bodyReader.clearedSessions.isEmpty)
    XCTAssertTrue(metadataStore.clearedProductAccountIds.isEmpty)
  }

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

    XCTAssertTrue(bodyReader.clearedSessions.isEmpty)
    XCTAssertTrue(metadataStore.clearedProductAccountIds.isEmpty)
    XCTAssertEqual(transport.connectCalls.count, 1)
  }

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
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertEqual(
        try tokenStore.load(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: "gmail-user-001"
        ),
        GmailProviderTokens(accessToken: "old-access-token", refreshToken: "old-refresh-token")
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

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

    XCTAssertEqual(statuses.map(\.emailAddress), ["user@example.com"])
    XCTAssertEqual(pushConnectionStore.loadedProductAccountId, session.productAccountId)
  }

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

    XCTAssertEqual(statuses.map(\.providerAccountIdentifier), ["gmail-user-001"])
    XCTAssertNil(try tokenStore.loadLegacy(productAccountId: session.productAccountId))
    XCTAssertEqual(pushConnectionStore.connections, statuses)
    XCTAssertEqual(transport.connectCall?.gmailIdentityToken, "gmail-identity-token")
  }

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

    XCTAssertEqual(statuses.map(\.providerAccountIdentifier), ["gmail-user-001"])
    XCTAssertEqual(pushConnectionStore.connections, statuses)
    XCTAssertEqual(transport.connectCall?.gmailIdentityToken, "gmail-identity-token")
  }

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

    XCTAssertEqual(statuses, [transport.status])
  }

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

    XCTAssertEqual(statuses, [transport.status])
  }

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

    XCTAssertEqual(statuses, [transport.status])
    XCTAssertEqual(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: transport.status.providerAccountIdentifier
      ),
      GmailProviderTokens(accessToken: "refreshed-access", refreshToken: "legacy-refresh")
    )
    XCTAssertNil(try tokenStore.loadLegacy(productAccountId: session.productAccountId))
    XCTAssertNil(transport.connectCall)
  }

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

    XCTAssertEqual(statuses, [transport.status])
  }

  func testLoadConnectionsRequiresLocalTokens() async throws {
    let service = GmailProviderConnectionService(
      tokenStore: InMemoryGmailProviderTokenStore(),
      transport: RecordingGmailConnectionTransport()
    )

    let statuses = try await service.loadConnections(session: session)

    XCTAssertTrue(statuses.isEmpty)
  }

  func testLoadConnectionsPropagatesTokenLoadFailure() async throws {
    let connection = RecordingGmailConnectionTransport().status
    let service = GmailProviderConnectionService(
      pushConnectionStore: RecordingPushConnectionStore(connection: connection),
      tokenStore: FailingLoadGmailProviderTokenStore(),
      transport: RecordingGmailConnectionTransport()
    )

    do {
      _ = try await service.loadConnections(session: session)
      XCTFail("Expected token load failure")
    } catch GmailProviderConnectionTestError.tokenLoadFailed {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

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

    XCTAssertTrue(statuses.isEmpty)
  }

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

    XCTAssertEqual(pushWatchStopper.stoppedConnection, pushConnectionStore.connection)
    XCTAssertEqual(pushWatchStopper.stoppedSession, session)
    XCTAssertTrue(pushWatchStopper.tokensWereAvailable)
    XCTAssertNil(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: "gmail-user-001"
      )
    )
    XCTAssertEqual(bodyReader.clearedSessions, [session])
    XCTAssertEqual(cacheStore.clearedProductAccountIds, [session.productAccountId])
    XCTAssertEqual(metadataStore.clearedProductAccountIds, [session.productAccountId])
    XCTAssertEqual(pushConnectionStore.clearedProductAccountIds, [session.productAccountId])
    XCTAssertEqual(pushWatchStore.clearedAllProductAccountIds, [session.productAccountId])
  }

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

    XCTAssertNil(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: first.providerAccountIdentifier
      )
    )
    XCTAssertNotNil(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: second.providerAccountIdentifier
      )
    )
    XCTAssertEqual(bodyReader.clearedProviderAccountIdentifiers, [first.providerAccountIdentifier])
    XCTAssertEqual(
      cacheStore.clearedKeys,
      ["\(session.productAccountId):\(first.providerAccountIdentifier)"]
    )
    XCTAssertEqual(
      metadataStore.clearedKeys,
      ["\(session.productAccountId):\(first.providerAccountIdentifier)"]
    )
    XCTAssertEqual(
      pushConnectionStore.clearedProviderAccountIdentifiers, [first.providerAccountIdentifier])
    XCTAssertEqual(
      pushWatchStore.clearedKeys,
      ["\(session.productAccountId):\(first.providerAccountIdentifier)"]
    )
    XCTAssertEqual(
      transport.removedOpaqueConnectionIds,
      [
        opaqueGmailConnectionId(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: first.providerAccountIdentifier
        )
      ]
    )
  }

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
      transport: transport
    )

    try await service.clearLocalConnection(transport.status, session: legacySession)

    XCTAssertNil(try KeychainStore.readString(service: serviceName, account: legacyAccount))
    XCTAssertEqual(cacheStore.clearedProductAccountIds, [productAccountId])
  }

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
      XCTFail("Expected background context cache clear failure")
    } catch GmailProviderConnectionTestError.tokenCleanupFailed {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertTrue(transport.removedOpaqueConnectionIds.isEmpty)
  }

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

    XCTAssertNil(pushWatchStopper.stoppedConnection)
    XCTAssertEqual(pushConnectionStore.clearedProductAccountIds, [session.productAccountId])
  }

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

    XCTAssertNil(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: "gmail-user-001"
      )
    )
    XCTAssertEqual(pushConnectionStore.clearedProductAccountIds, [session.productAccountId])
  }

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
      XCTFail("Expected token cleanup failure")
    } catch GmailProviderConnectionTestError.tokenCleanupFailed {
      XCTAssertEqual(metadataStore.clearedProductAccountIds, [session.productAccountId])
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

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
      XCTFail("Expected metadata cleanup failure")
    } catch GmailProviderConnectionTestError.metadataCleanupFailed {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertEqual(transport.removedOpaqueConnectionIds.count, 1)
    XCTAssertNil(
      try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: transport.status.providerAccountIdentifier
      )
    )
    let authorizedStatuses = try await service.loadConnections(session: session)
    XCTAssertTrue(authorizedStatuses.isEmpty)
    let retryStatus = try XCTUnwrap(
      service.loadConnectionForCleanup(
        providerAccountIdentifier: transport.status.providerAccountIdentifier,
        session: session
      )
    )

    metadataStore.clearError = nil
    try await service.clearLocalConnection(retryStatus, session: session)

    XCTAssertEqual(transport.removedOpaqueConnectionIds.count, 2)
    XCTAssertNil(
      try service.loadConnectionForCleanup(
        providerAccountIdentifier: transport.status.providerAccountIdentifier,
        session: session
      )
    )
  }

  func testLoadConnectionForCleanupIsolatesUnreadableConnectionStatus() throws {
    let pushConnectionStore = RecordingPushConnectionStore()
    pushConnectionStore.loadError = GmailProviderConnectionTestError.pushConnectionLoadFailed
    let service = GmailProviderConnectionService(
      pushConnectionStore: pushConnectionStore,
      transport: RecordingGmailConnectionTransport()
    )

    XCTAssertNil(
      try service.loadConnectionForCleanup(
        providerAccountIdentifier: "gmail-user-001",
        session: session
      )
    )
  }

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
      XCTFail("Expected Gmail authorization failure")
    } catch GmailProviderCredentialVerificationError.missingGmailAuthorization {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

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
      XCTFail("Expected insufficient Gmail scope")
    } catch GmailProviderCredentialVerificationError.insufficientGmailScope {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

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
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
          request.value(forHTTPHeaderField: "Content-Type"),
          "application/x-www-form-urlencoded"
        )
        XCTAssertTrue(body?.contains("client_id=gmail-client-id") == true)
        XCTAssertTrue(body?.contains("grant_type=refresh_token") == true)
        XCTAssertTrue(body?.contains("refresh_token=refresh-token") == true)
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
      XCTFail("Expected account mismatch")
    } catch GmailProviderCredentialVerificationError.accountMismatch {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

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
      XCTFail("Expected Gmail authorization failure")
    } catch GmailProviderCredentialVerificationError.missingGmailAuthorization {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // swiftlint:disable:next function_body_length
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

    XCTAssertEqual(account.emailAddress, "user@example.com")
    XCTAssertEqual(account.providerAccountIdentifier, "gmail-user-001")
    XCTAssertEqual(
      profileAuthorizations,
      ["Bearer refreshed-access-token", "Bearer access-token"]
    )
    XCTAssertEqual(
      account.tokens,
      GmailProviderTokens(
        accessToken: "refreshed-access-token",
        refreshToken: "refresh-token",
        idToken: "refreshed-id-token"
      )
    )
  }

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

    XCTAssertEqual(account.emailAddress, "user@example.com")
    XCTAssertEqual(account.providerAccountIdentifier, "gmail-user-001")
  }

  func testGoogleOAuthRequestUsesPKCEAndIdentityAndGmailScopes() throws {
    let request = GoogleGmailOAuthRequest(
      clientIdentifier: "123.apps.googleusercontent.com",
      codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
      state: "oauth-state"
    )
    let authorizationURL = try XCTUnwrap(request.authorizationURL)
    let components = try XCTUnwrap(
      URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)
    )
    let query = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
      }
    )

    XCTAssertEqual(request.callbackScheme, "com.googleusercontent.apps.123")
    XCTAssertEqual(
      request.redirectURI?.absoluteString,
      "com.googleusercontent.apps.123:/oauth2redirect"
    )
    XCTAssertEqual(query["access_type"], "offline")
    XCTAssertEqual(query["client_id"], "123.apps.googleusercontent.com")
    XCTAssertEqual(query["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    XCTAssertEqual(query["code_challenge_method"], "S256")
    XCTAssertEqual(query["prompt"], "select_account consent")
    XCTAssertEqual(query["response_type"], "code")
    XCTAssertEqual(query["scope"], GoogleGmailOAuthRequest.authorizationScope)
    XCTAssertEqual(query["state"], "oauth-state")
  }

  func testGoogleOAuthRequestRejectsCallbackWithDifferentState() throws {
    let request = GoogleGmailOAuthRequest(
      clientIdentifier: "123.apps.googleusercontent.com",
      codeVerifier: "code-verifier",
      state: "expected-state"
    )
    let callbackURL = try XCTUnwrap(
      URL(string: "com.googleusercontent.apps.123:/oauth2redirect?code=code&state=other-state")
    )

    XCTAssertThrowsError(try request.authorizationCode(from: callbackURL)) { error in
      guard case GoogleGmailOAuthError.invalidAuthorizationState = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  @MainActor
  func testGoogleOAuthTokenExchangeReturnsAccessAndRefreshTokens() async throws {
    let session = ConvexClientTesting.makeSession { request in
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Content-Type"),
        "application/x-www-form-urlencoded"
      )
      let body = Self.httpBodyString(for: request)
      XCTAssertTrue(body?.contains("client_id=123.apps.googleusercontent.com") == true)
      XCTAssertTrue(body?.contains("code=authorization-code") == true)
      XCTAssertTrue(body?.contains("code_verifier=code-verifier") == true)
      XCTAssertTrue(body?.contains("grant_type=authorization_code") == true)
      XCTAssertTrue(
        body?.contains("redirect_uri=com.googleusercontent.apps.123%3A%2Foauth2redirect") == true
      )
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

    XCTAssertEqual(
      tokens,
      GmailProviderTokens(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        idToken: "gmail-identity-token"
      )
    )
  }

  func testBundledOAuthClientIdReadsGeneratedInfoPlistKey() throws {
    let bundle = try Self.makeBundle(
      infoDictionary: [
        GmailOAuthClientIdConfiguration.infoDictionaryKey: " bundled-client-id "
      ]
    )

    XCTAssertEqual(
      GmailOAuthClientIdConfiguration.bundledValue(bundle: bundle),
      "bundled-client-id"
    )
  }

  func testBundledOAuthClientIdIgnoresUnresolvedBuildSettingPlaceholder() throws {
    let bundle = try Self.makeBundle(
      infoDictionary: [
        GmailOAuthClientIdConfiguration.infoDictionaryKey: "$(GMAIL_OAUTH_CLIENT_ID)"
      ]
    )

    XCTAssertNil(GmailOAuthClientIdConfiguration.bundledValue(bundle: bundle))
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
    return hasRemainingGmailConnections
  }
}

private final class FailingClearGmailProviderTokenStore: GmailProviderTokenPersisting {
  func clear(productAccountId _: String, providerAccountIdentifier _: String) throws {
    throw GmailProviderConnectionTestError.tokenCleanupFailed
  }

  func clearAll(productAccountId _: String) throws {
    throw GmailProviderConnectionTestError.tokenCleanupFailed
  }

  func load(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> GmailProviderTokens? {
    nil
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
  var clearedProviderAccountIdentifiers: [String] = []
  var connections: [GmailProviderConnectionStatus]
  var loadedProductAccountId: String?
  var loadError: Error?
  var connection: GmailProviderConnectionStatus? { connections.first }

  init(connection: GmailProviderConnectionStatus? = nil) {
    connections = connection.map { [$0] } ?? []
  }

  func clearAll(productAccountId: String) throws {
    clearedProductAccountIds.append(productAccountId)
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
  var clearedKeys: [String] = []
  var clearedAllProductAccountIds: [String] = []

  func clearAll(productAccountId: String) throws {
    clearedAllProductAccountIds.append(productAccountId)
  }

  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
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
