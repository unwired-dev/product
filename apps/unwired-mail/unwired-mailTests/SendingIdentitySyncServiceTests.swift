import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length

@MainActor
@Suite(.serialized)
// swiftlint:disable:next type_body_length
struct SendingIdentitySyncServiceTests {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user",
    identityToken: "identity-token",
    productAccountId: "product-account",
    trustedDeviceId: "trusted-device"
  )

  @Test
  func migrationKeepsTheLegacyDefaultConnectionAndScopesIdentitiesToAProfile() {
    let primary = Self.connection(address: "primary@example.com", value: "primary")
    let otherProfile = Self.connection(address: "other@example.com", value: "other")
    var preferences = SendingIdentityPreferences(
      identities: [
        SendingIdentity(
          address: "other@example.com",
          connectionId: otherProfile.id,
          verification: .providerConfirmed
        )
      ]
    )

    preferences.reconcile(
      connections: [primary],
      legacyDefaultConnectionId: primary.id
    )

    #expect(preferences.identities.map(\.address) == ["primary@example.com"])
    #expect(preferences.defaultIdentity?.connectionId == primary.id)
    #expect(!preferences.identities.contains { $0.connectionId == otherProfile.id })
  }

  @Test
  func providerRefreshRemovesRevokedAliasesButKeepsManualAliases() {
    let connection = Self.connection(address: "primary@example.com", value: "primary")
    let revoked = SendingIdentity(
      address: "revoked@example.com",
      connectionId: connection.id,
      verification: .providerConfirmed
    )
    let manual = SendingIdentity(
      address: "manual@example.com",
      connectionId: connection.id,
      verification: .manualProviderTest
    )
    var preferences = SendingIdentityPreferences(identities: [revoked, manual])

    preferences.reconcile(
      connections: [connection],
      providerConfirmedAddresses: [connection.id: []],
      legacyDefaultConnectionId: connection.id
    )

    #expect(
      Set(preferences.identities.map(\.address)) == [
        "manual@example.com", "primary@example.com",
      ])
  }

  @Test
  func nonAuthoritativeConnectionLoadsPreserveOmittedIdentities() async {
    let primary = Self.connection(address: "primary@example.com", value: "primary")
    let omitted = Self.connection(address: "omitted@example.com", value: "omitted")
    let remotePreferences = SendingIdentityPreferences(
      identities: [
        SendingIdentity(
          address: "primary@example.com",
          connectionId: primary.id,
          verification: .providerConfirmed
        ),
        SendingIdentity(
          address: "omitted@example.com",
          connectionId: omitted.id,
          verification: .providerConfirmed
        ),
      ]
    )
    let sync = ScriptedSendingIdentitySyncService()
    await sync.setSnapshot(remotePreferences)
    let store = SendingIdentityStore(
      session: session,
      syncService: sync,
      challengeStore: InMemorySendingIdentityChallengeStore()
    )

    await store.synchronize(
      connections: [],
      connectionsAreAuthoritative: false,
      legacyDefaultConnectionId: nil
    )
    #expect(
      Set(store.preferences.identities.map(\.address)) == [
        "omitted@example.com", "primary@example.com",
      ])

    await store.synchronize(
      connections: [primary],
      connectionsAreAuthoritative: false,
      legacyDefaultConnectionId: primary.id
    )
    #expect(
      Set(store.preferences.identities.map(\.address)) == [
        "omitted@example.com", "primary@example.com",
      ])
  }

  @Test
  func initialSynchronizationAdoptsTheRemoteDefaultIdentity() async {
    let connection = Self.connection(address: "primary@example.com", value: "primary")
    let primary = SendingIdentity(
      address: "primary@example.com",
      connectionId: connection.id,
      verification: .providerConfirmed
    )
    let alias = SendingIdentity(
      address: "alias@example.com",
      connectionId: connection.id,
      verification: .providerConfirmed
    )
    let sync = ScriptedSendingIdentitySyncService()
    await sync.setSnapshot(
      SendingIdentityPreferences(identities: [primary, alias], defaultIdentityId: alias.id)
    )
    let store = SendingIdentityStore(
      session: session,
      syncService: sync,
      challengeStore: InMemorySendingIdentityChallengeStore()
    )

    await store.synchronize(
      connections: [connection],
      legacyDefaultConnectionId: connection.id
    )

    #expect(store.preferences.defaultIdentityId == alias.id)
  }

  @Test
  func laterSynchronizationAdoptsANewerRemoteDefaultWhenLocalStateIsClean() async {
    let connection = Self.connection(address: "primary@example.com", value: "primary")
    let primary = SendingIdentity(
      address: "primary@example.com",
      connectionId: connection.id,
      verification: .providerConfirmed
    )
    let alias = SendingIdentity(
      address: "alias@example.com",
      connectionId: connection.id,
      verification: .providerConfirmed
    )
    let sync = ScriptedSendingIdentitySyncService()
    await sync.setSnapshot(
      SendingIdentityPreferences(identities: [primary, alias], defaultIdentityId: primary.id)
    )
    let store = SendingIdentityStore(
      session: session,
      syncService: sync,
      challengeStore: InMemorySendingIdentityChallengeStore()
    )
    await store.synchronize(
      connections: [connection],
      legacyDefaultConnectionId: connection.id
    )
    await sync.setSnapshot(
      SendingIdentityPreferences(identities: [primary, alias], defaultIdentityId: alias.id)
    )

    await store.synchronize(
      connections: [connection],
      legacyDefaultConnectionId: connection.id
    )

    #expect(store.preferences.defaultIdentityId == alias.id)
    #expect(await sync.savedPreferences()?.defaultIdentityId == alias.id)
  }

  @Test
  func defaultChangeDuringSynchronizationQueuesAnotherWrite() async {
    let connection = Self.connection(address: "primary@example.com", value: "primary")
    let primary = SendingIdentity(
      address: "primary@example.com",
      connectionId: connection.id,
      verification: .providerConfirmed
    )
    let alias = SendingIdentity(
      address: "alias@example.com",
      connectionId: connection.id,
      verification: .providerConfirmed
    )
    let sync = SuspendingSendingIdentitySyncService(
      preferences: SendingIdentityPreferences(
        identities: [primary, alias],
        defaultIdentityId: primary.id
      )
    )
    let store = SendingIdentityStore(
      session: session,
      syncService: sync,
      challengeStore: InMemorySendingIdentityChallengeStore()
    )
    await store.synchronize(
      connections: [connection],
      legacyDefaultConnectionId: connection.id
    )
    await sync.suspendNextSave()
    let synchronization = Task {
      await store.synchronize(
        connections: [connection],
        legacyDefaultConnectionId: connection.id
      )
    }
    await sync.waitUntilSuspendedSaveStarts()

    await store.setDefault(alias.id)
    await sync.resumeSuspendedSave()
    await synchronization.value

    #expect(await sync.savedPreferences().defaultIdentityId == alias.id)
    #expect(store.preferences.defaultIdentityId == alias.id)
  }

  @Test
  func providerConfirmedAliasesAreAvailableAndReceivingAliasWinsForReplies() throws {
    let connection = Self.connection(address: "primary@example.com", value: "primary")
    var preferences = SendingIdentityPreferences()
    preferences.reconcile(
      connections: [connection],
      providerConfirmedAddresses: [connection.id: ["Alias@Example.com"]],
      legacyDefaultConnectionId: connection.id
    )
    let message = Self.message(
      connectionId: connection.id,
      recipients: ["Unwired User <alias@example.com>"]
    )

    let alias = try #require(preferences.receivingIdentity(for: message))

    #expect(alias.address == "alias@example.com")
    #expect(alias.verification == .providerConfirmed)
  }

  @Test
  func unavailableReceivingIdentityDoesNotFallBackToTheDefault() {
    let connection = Self.connection(address: "primary@example.com", value: "primary")
    var preferences = SendingIdentityPreferences()
    preferences.reconcile(
      connections: [connection],
      legacyDefaultConnectionId: connection.id
    )
    let message = Self.message(
      connectionId: connection.id,
      recipients: ["retired-alias@example.com"]
    )

    #expect(preferences.receivingIdentity(for: message) == nil)
  }

  @Test
  func manualAliasRequiresProviderAcceptanceAndTheDeviceLocalCode() async throws {
    let connection = Self.connection(address: "primary@example.com", value: "primary")
    let sync = ScriptedSendingIdentitySyncService()
    let challenges = InMemorySendingIdentityChallengeStore()
    let store = SendingIdentityStore(
      session: session,
      syncService: sync,
      challengeStore: challenges,
      codeGenerator: { "246810" },
      now: { Date(timeIntervalSince1970: 100) }
    )
    await store.synchronize(
      connections: [connection],
      legacyDefaultConnectionId: connection.id
    )
    var sentMessage: OutgoingMessage?

    #expect(
      await store.beginManualVerification(
        address: "Alias@Example.com",
        connection: connection,
        send: { message, _ in
          sentMessage = message
        }
      ))
    #expect(sentMessage?.recipient == "alias@example.com")
    #expect(sentMessage?.fromAddress == "alias@example.com")
    #expect(sentMessage?.body.contains("246810") == true)
    #expect(!(await store.completeManualVerification(code: "wrong")))
    #expect(await store.completeManualVerification(code: "246810"))
    #expect(
      store.preferences.identities.first { $0.address == "alias@example.com" }?.verification
        == .manualProviderTest)
    #expect(challenges.challenge == nil)
  }

  @Test
  func providerRejectionDoesNotPersistAManualAliasChallenge() async {
    let connection = Self.connection(address: "primary@example.com", value: "primary")
    let challenges = InMemorySendingIdentityChallengeStore()
    let store = SendingIdentityStore(
      session: session,
      syncService: ScriptedSendingIdentitySyncService(),
      challengeStore: challenges,
      codeGenerator: { "123456" }
    )

    let accepted = await store.beginManualVerification(
      address: "alias@example.com",
      connection: connection,
      send: { _, _ in throw TestVerificationError.rejected }
    )

    #expect(!accepted)
    #expect(challenges.challenge == nil)
    #expect(store.preferences.identities.isEmpty)
    #expect(store.errorMessage == "Provider verification failed.")
  }

  @Test
  func conditionalWriteConflictMergesRemoteAndLocallyVerifiedAliases() async throws {
    let connection = Self.connection(address: "primary@example.com", value: "primary")
    let remoteAlias = SendingIdentity(
      address: "remote@example.com",
      connectionId: connection.id,
      verification: .providerConfirmed
    )
    let sync = ScriptedSendingIdentitySyncService()
    let store = SendingIdentityStore(
      session: session,
      syncService: sync,
      challengeStore: InMemorySendingIdentityChallengeStore(),
      codeGenerator: { "654321" }
    )
    await store.synchronize(
      connections: [connection],
      legacyDefaultConnectionId: connection.id
    )
    #expect(
      await store.beginManualVerification(
        address: "local@example.com",
        connection: connection,
        send: { _, _ in }
      ))
    await sync.conflictOnce(
      with: SendingIdentityPreferences(
        identities: [remoteAlias],
        defaultIdentityId: remoteAlias.id
      )
    )

    #expect(await store.completeManualVerification(code: "654321"))
    #expect(
      Set(store.preferences.identities.map(\.address)) == [
        "local@example.com", "primary@example.com", "remote@example.com",
      ])
  }

  @Test
  func expiredVerificationChallengeIsRemoved() async {
    let connection = Self.connection(address: "primary@example.com", value: "primary")
    let challenges = InMemorySendingIdentityChallengeStore()
    challenges.challenge = SendingIdentityVerificationChallenge(
      address: "alias@example.com",
      code: "123456",
      connectionId: connection.id,
      expiresAtMilliseconds: 99_000
    )
    let store = SendingIdentityStore(
      session: session,
      syncService: ScriptedSendingIdentitySyncService(),
      challengeStore: challenges,
      now: { Date(timeIntervalSince1970: 100) }
    )

    #expect(!(await store.completeManualVerification(code: "123456")))
    #expect(challenges.challenge == nil)
    #expect(store.verificationAddress == nil)
    #expect(store.errorMessage == SendingIdentityError.verificationExpired.localizedDescription)
  }

  @Test
  func keychainChallengeStorePersistsAndDeletesADeviceLocalChallenge() throws {
    let productAccountId = "sending-identity-test-\(UUID().uuidString)"
    let recordScope = MailProfileRecordScope.profile(MailProfileId(rawValue: "profile"))
    let challengeStore = KeychainIdentityChallengeStore()
    let challenge = SendingIdentityVerificationChallenge(
      address: "alias@example.com",
      code: "123456",
      connectionId: Self.connection(address: "primary@example.com", value: "primary").id,
      expiresAtMilliseconds: 1_000
    )
    defer {
      try? challengeStore.save(
        nil,
        productAccountId: productAccountId,
        recordScope: recordScope
      )
    }

    try challengeStore.save(
      challenge,
      productAccountId: productAccountId,
      recordScope: recordScope
    )
    #expect(
      try challengeStore.load(productAccountId: productAccountId, recordScope: recordScope)
        == challenge)

    try challengeStore.save(nil, productAccountId: productAccountId, recordScope: recordScope)
    #expect(
      try challengeStore.load(productAccountId: productAccountId, recordScope: recordScope) == nil)
  }

  @Test
  func olderOutboxPayloadDecodesWithoutSendingIdentityFields() throws {
    let data = Data(
      #"{"body":"Body","recipient":"to@example.com","subject":"Subject"}"#.utf8
    )

    let message = try JSONDecoder().decode(OutgoingMessage.self, from: data)

    #expect(message.fromAddress == nil)
    #expect(message.sendingIdentityId == nil)
  }

  private static func connection(address: String, value: String) -> MailboxConnection {
    MailboxConnection(
      authorizationState: .authorized,
      capabilities: .gmail,
      connectedAt: 1,
      displayName: address,
      id: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .gmail,
          value: value
        )
      ),
      lastVerifiedAt: 1,
      productAccountId: ProductAccountId("product-account"),
      trustedDeviceId: "trusted-device",
      updatedAt: 1
    )
  }

  private static func message(
    connectionId: MailboxConnectionId,
    recipients: [String]
  ) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: nil,
      connectionId: connectionId,
      from: "sender@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: 1,
      providerMessageId: "message",
      providerStateIds: ["INBOX"],
      providerThreadId: "thread",
      recipientHeaders: recipients,
      replyTo: nil,
      rfcMessageId: nil,
      snippet: "",
      subject: "Subject"
    )
  }
}

private final class InMemorySendingIdentityChallengeStore:
  SendingIdentityChallengePersisting
{
  var challenge: SendingIdentityVerificationChallenge?

  func load(
    productAccountId _: String,
    recordScope _: MailProfileRecordScope
  ) throws -> SendingIdentityVerificationChallenge? {
    challenge
  }

  func save(
    _ challenge: SendingIdentityVerificationChallenge?,
    productAccountId _: String,
    recordScope _: MailProfileRecordScope
  ) throws {
    self.challenge = challenge
  }
}

private enum TestVerificationError: LocalizedError {
  case rejected

  var errorDescription: String? { "Provider verification failed." }
}

private actor ScriptedSendingIdentitySyncService: SendingIdentitySyncing {
  private var conflict: SendingIdentitySyncSnapshot?
  private var snapshot: SendingIdentitySyncSnapshot?

  func load(
    session _: ProductAccountSessionSnapshot
  ) async throws -> SendingIdentitySyncSnapshot? {
    snapshot
  }

  func save(
    _ preferences: SendingIdentityPreferences,
    expectedUpdatedAt _: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> SendingIdentityConditionalSaveResult {
    if let conflict {
      self.conflict = nil
      snapshot = conflict
      return .conflict(conflict)
    }
    let committed = SendingIdentitySyncSnapshot(
      preferences: preferences,
      updatedAt: (snapshot?.updatedAt ?? 0) + 1
    )
    snapshot = committed
    return .committed(committed)
  }

  func conflictOnce(with preferences: SendingIdentityPreferences) {
    conflict = SendingIdentitySyncSnapshot(
      preferences: preferences,
      updatedAt: (snapshot?.updatedAt ?? 0) + 1
    )
  }

  func setSnapshot(_ preferences: SendingIdentityPreferences) {
    snapshot = SendingIdentitySyncSnapshot(preferences: preferences, updatedAt: 1)
  }

  func savedPreferences() -> SendingIdentityPreferences? {
    snapshot?.preferences
  }
}

private actor SuspendingSendingIdentitySyncService: SendingIdentitySyncing {
  private var shouldSuspendNextSave = false
  private var snapshot: SendingIdentitySyncSnapshot
  private var suspendedSaveContinuation: CheckedContinuation<Void, Never>?
  private var suspendedSaveStarted = false
  private var suspendedSaveStartWaiters: [CheckedContinuation<Void, Never>] = []

  init(preferences: SendingIdentityPreferences) {
    snapshot = SendingIdentitySyncSnapshot(preferences: preferences, updatedAt: 1)
  }

  func load(
    session _: ProductAccountSessionSnapshot
  ) async throws -> SendingIdentitySyncSnapshot? {
    snapshot
  }

  func save(
    _ preferences: SendingIdentityPreferences,
    expectedUpdatedAt _: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> SendingIdentityConditionalSaveResult {
    if shouldSuspendNextSave {
      shouldSuspendNextSave = false
      suspendedSaveStarted = true
      let waiters = suspendedSaveStartWaiters
      suspendedSaveStartWaiters = []
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        suspendedSaveContinuation = continuation
      }
    }
    snapshot = SendingIdentitySyncSnapshot(
      preferences: preferences,
      updatedAt: (snapshot.updatedAt ?? 0) + 1
    )
    return .committed(snapshot)
  }

  func suspendNextSave() {
    shouldSuspendNextSave = true
    suspendedSaveStarted = false
  }

  func waitUntilSuspendedSaveStarts() async {
    guard !suspendedSaveStarted else { return }
    await withCheckedContinuation { continuation in
      suspendedSaveStartWaiters.append(continuation)
    }
  }

  func resumeSuspendedSave() {
    suspendedSaveContinuation?.resume()
    suspendedSaveContinuation = nil
  }

  func savedPreferences() -> SendingIdentityPreferences {
    snapshot.preferences
  }
}
