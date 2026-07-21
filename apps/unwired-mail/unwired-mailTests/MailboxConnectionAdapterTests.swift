import XCTest

@testable import unwired_mail

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
    let adapter = GmailMailboxConnectionAdapter(
      connectionService: connectionService,
      credentialVerifier: credentialVerifier,
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
    let adapter = GmailMailboxConnectionAdapter(connectionService: connectionService)

    let connections = try await adapter.loadConnections(session: session)
    try await adapter.clearLocalConnection(connections[0], session: session)

    XCTAssertEqual(
      connections.map(\.id.rawValue), ["gmail:gmail-user-001", "gmail:gmail-user-002"])
    XCTAssertEqual(
      connectionService.clearedConnection?.providerAccountIdentifier,
      "gmail-user-001"
    )
  }

  func testGmailAdapterRoutesExistingMailOperationsWithoutChangingResults() async throws {
    let bodyReader = RecordingAdapterMessageReader()
    let mailActionService = RecordingAdapterMailActionService()
    let metadataService = RecordingAdapterMetadataService()
    let pushService = RecordingAdapterPushService()
    let searchService = RecordingAdapterSearchService()
    let adapter = GmailMailboxConnectionAdapter(
      bodyReader: bodyReader,
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
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderConnectionStatus {
    completedAccount = verifiedAccount
    return Self.status
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
