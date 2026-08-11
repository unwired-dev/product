import Foundation
import Testing

@testable import unwired_mail

@MainActor
@Suite(.serialized)
final class ReadingPreferenceSyncServiceTests {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user",
    identityToken: "identity-token",
    productAccountId: "product-account",
    trustedDeviceId: "trusted-device"
  )

  @Test
  func testDefaultsMatchReadingProductDecisions() {
    #expect(ReadingPreferences.defaults.markReadAfter == .immediately)
    #expect(ReadingPreferences.defaults.marksReadOnReply)
    #expect(!(ReadingPreferences.defaults.marksReadOnArchiveOrDelete))
    #expect(ReadingPreferences.defaults.incomingReadReceipts == .askEveryTime)
    #expect(ReadingPreferences.defaults.outgoingReadReceipts == .never)
    #expect(ReadingPreferences.defaults.connectionOverrides.isEmpty)
  }

  @Test
  func testSupportedReadDelaysAndManualBehaviorAreExplicit() {
    #expect(MessageReadTiming.immediately.delay == .zero)
    #expect(MessageReadTiming.afterOneSecond.delay == .seconds(1))
    #expect(MessageReadTiming.afterThreeSeconds.delay == .seconds(3))
    #expect(MessageReadTiming.afterFiveSeconds.delay == .seconds(5))
    #expect(MessageReadTiming.manually.delay == nil)
  }

  @Test
  func testDecodingOlderPayloadUsesSafeReceiptDefaults() throws {
    let data = Data(#"{"markReadAfter":"afterThreeSeconds","marksReadOnReply":false}"#.utf8)

    let preferences = try JSONDecoder().decode(ReadingPreferences.self, from: data)

    #expect(preferences.markReadAfter == .afterThreeSeconds)
    #expect(!(preferences.marksReadOnReply))
    #expect(!(preferences.marksReadOnArchiveOrDelete))
    #expect(preferences.incomingReadReceipts == .askEveryTime)
    #expect(preferences.outgoingReadReceipts == .never)
  }

  @Test
  func testDecodingFutureSchemaFails() {
    let data = Data(#"{"schemaVersion":2}"#.utf8)

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ReadingPreferences.self, from: data)
    }
  }

  @Test
  func testConnectionOverridesFallBackIndependentlyToGlobalPolicies() {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .microsoftGraph,
        value: "graph-user"
      )
    )
    let preferences = ReadingPreferences(
      connectionOverrides: [
        connectionId.rawValue: ReadingConnectionPreferences(
          outgoingReadReceipts: .requestByDefault
        )
      ],
      incomingReadReceipts: .never,
      outgoingReadReceipts: .askWhileSending
    )

    #expect(preferences.incomingReadReceiptPolicy(for: connectionId) == .never)
    #expect(preferences.outgoingReadReceiptPolicy(for: connectionId) == .requestByDefault)
  }

  @Test
  func testProviderReceiptCapabilitiesRemainExplicit() {
    #expect(!(MailboxConnectionCapabilities.gmail.canRequestReadReceipts))
    #expect(!(MailboxConnectionCapabilities.gmail.canRespondToReadReceipts))
    #expect(MailboxConnectionCapabilities.microsoftGraph.canRequestReadReceipts)
    #expect(!(MailboxConnectionCapabilities.microsoftGraph.canRespondToReadReceipts))
    #expect(MailboxConnectionCapabilities.exchangeWebServices.canRequestReadReceipts)
    #expect(!(MailboxConnectionCapabilities.exchangeWebServices.canRespondToReadReceipts))
    #expect(!(MailboxConnectionCapabilities.imapRead.canRequestReadReceipts))
  }

  @Test
  func testOlderReadTaskCannotClearANewerTaskOwner() {
    let messageId = StableProviderMessageIdentity(
      connectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .gmail,
          value: "account"
        )
      ),
      providerMessageId: "message"
    )
    var owners = MailShellReadTaskOwners()
    let first = owners.begin(messageId)
    let second = owners.begin(messageId)

    let firstFinished = owners.finish(messageId, owner: first)
    let secondFinished = owners.finish(messageId, owner: second)

    #expect(!firstFinished)
    #expect(secondFinished)
  }

  @Test
  func testOfflineEditPersistsLocallyAndRemainsPending() async {
    let localStore = InMemoryReadingPreferenceLocalStateStore()
    let syncService = InMemoryReadingPreferenceSyncService()
    syncService.loadError = URLError(.notConnectedToInternet)
    let store = ReadingPreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: localStore,
      automaticallySynchronizes: false
    )

    store.setMarkReadAfter(.afterFiveSeconds)
    await store.synchronize()

    #expect(store.preferences.markReadAfter == .afterFiveSeconds)
    #expect(store.hasPendingChanges)
    #expect(store.errorMessage != nil)

    let restored = ReadingPreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: localStore,
      automaticallySynchronizes: false
    )
    #expect(restored.preferences.markReadAfter == .afterFiveSeconds)
    #expect(restored.hasPendingChanges)
  }

  @Test
  func testNonOverlappingGlobalAndConnectionChangesMergeAutomatically() async {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .exchangeWebServices,
        value: "ews-user"
      )
    )
    let syncService = InMemoryReadingPreferenceSyncService()
    let store = ReadingPreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: InMemoryReadingPreferenceLocalStateStore(),
      automaticallySynchronizes: false
    )
    store.setMarkReadAfter(.afterThreeSeconds)
    syncService.snapshot = ReadingPreferenceSyncSnapshot(
      preferences: ReadingPreferences(
        connectionOverrides: [
          connectionId.rawValue: ReadingConnectionPreferences(
            incomingReadReceipts: .never
          )
        ]
      ),
      updatedAt: 4
    )

    await store.synchronize()

    #expect(store.preferences.markReadAfter == .afterThreeSeconds)
    #expect(store.preferences.incomingReadReceiptPolicy(for: connectionId) == .never)
    #expect(!(store.hasPendingChanges))
    #expect(store.conflicts.isEmpty)
  }

  @Test
  func testSameFieldChangesPreserveBothValuesForExplicitResolution() async {
    let syncService = InMemoryReadingPreferenceSyncService()
    let store = ReadingPreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: InMemoryReadingPreferenceLocalStateStore(),
      automaticallySynchronizes: false
    )
    store.setOutgoingReadReceipts(.requestByDefault)
    syncService.snapshot = ReadingPreferenceSyncSnapshot(
      preferences: ReadingPreferences(outgoingReadReceipts: .askWhileSending),
      updatedAt: 2
    )

    await store.synchronize()

    let conflict = store.conflicts.first
    #expect(conflict?.field == .outgoingReadReceipts)
    #expect(conflict?.localValue == .outgoingReadReceipts(.requestByDefault))
    #expect(conflict?.remoteValue == .outgoingReadReceipts(.askWhileSending))

    store.resolveConflict(.outgoingReadReceipts, useLocalValue: true)
    await store.synchronize()

    #expect(store.conflicts.isEmpty)
    #expect(syncService.snapshot?.preferences.outgoingReadReceipts == .requestByDefault)
  }

  @Test
  func testAccountSwitchDuringLoadKeepsTheNewAccountsRestoredPreferences() async throws {
    let loadGate = TestRendezvous()
    let syncService = InMemoryReadingPreferenceSyncService()
    syncService.beforeLoad = { await loadGate.hold() }
    syncService.snapshot = ReadingPreferenceSyncSnapshot(
      preferences: ReadingPreferences(markReadAfter: .afterThreeSeconds),
      updatedAt: 3
    )
    let localStore = InMemoryReadingPreferenceLocalStateStore()
    let otherSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "other-apple-user",
      identityToken: "other-identity-token",
      productAccountId: "other-product-account",
      trustedDeviceId: "other-trusted-device"
    )
    try localStore.save(
      ReadingPreferenceLocalState(
        conflicts: [:],
        pendingChanges: [:],
        preferences: ReadingPreferences(markReadAfter: .afterFiveSeconds)
      ),
      productAccountId: otherSession.productAccountId
    )
    let store = ReadingPreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: localStore,
      automaticallySynchronizes: false
    )

    let synchronization = Task { await store.synchronize() }
    await loadGate.waitUntilHeld()
    store.updateSession(otherSession)
    await loadGate.release()
    await synchronization.value

    #expect(store.preferences.markReadAfter == .afterFiveSeconds)
    #expect(!(store.isSynchronizing))
  }

  @Test
  func testSynchronizationStopsAfterTheRetryLimit() async {
    let syncService = InMemoryReadingPreferenceSyncService()
    syncService.alwaysConflicts = true
    syncService.snapshot = ReadingPreferenceSyncSnapshot(preferences: .defaults, updatedAt: 1)
    let store = ReadingPreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: InMemoryReadingPreferenceLocalStateStore(),
      automaticallySynchronizes: false
    )
    store.setMarkReadAfter(.afterFiveSeconds)

    await store.synchronize()

    #expect(syncService.saveCount == 5)
    #expect(
      store.errorMessage == ReadingPreferenceSyncError.retryLimitExceeded.localizedDescription)
    #expect(!(store.isSynchronizing))
  }

  @Test
  func testOlderOutboxMessageDecodesWithoutReceiptRequest() throws {
    let data = Data(
      #"{"body":"Hello","recipient":"person@example.com","subject":"Hi"}"#.utf8
    )

    let message = try JSONDecoder().decode(OutgoingMessage.self, from: data)

    #expect(message.requestsReadReceipt != true)
  }
}

private final class InMemoryReadingPreferenceLocalStateStore:
  ReadingPreferenceLocalStatePersisting
{
  private var states: [String: ReadingPreferenceLocalState] = [:]

  func clear(productAccountId: String) throws {
    states[productAccountId] = nil
  }

  func load(productAccountId: String) throws -> ReadingPreferenceLocalState? {
    states[productAccountId]
  }

  func save(_ state: ReadingPreferenceLocalState, productAccountId: String) throws {
    states[productAccountId] = state
  }
}

private final class InMemoryReadingPreferenceSyncService: ReadingPreferenceSyncing {
  var alwaysConflicts = false
  var beforeLoad: (() async -> Void)?
  var loadError: Error?
  private(set) var saveCount = 0
  var snapshot: ReadingPreferenceSyncSnapshot?

  func loadPreferences(
    session _: ProductAccountSessionSnapshot
  ) async throws -> ReadingPreferenceSyncSnapshot? {
    await beforeLoad?()
    if let loadError { throw loadError }
    return snapshot
  }

  func savePreferences(
    _ preferences: ReadingPreferences,
    expectedUpdatedAt: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ReadingPreferenceConditionalSaveResult {
    saveCount += 1
    if alwaysConflicts {
      let conflicted = ReadingPreferenceSyncSnapshot(
        preferences: snapshot?.preferences ?? .defaults,
        updatedAt: (snapshot?.updatedAt ?? 0) + 1
      )
      snapshot = conflicted
      return .conflict(conflicted)
    }
    guard snapshot?.updatedAt == expectedUpdatedAt else {
      return .conflict(
        snapshot ?? ReadingPreferenceSyncSnapshot(preferences: .defaults, updatedAt: nil)
      )
    }
    let committed = ReadingPreferenceSyncSnapshot(
      preferences: preferences,
      updatedAt: (snapshot?.updatedAt ?? 0) + 1
    )
    snapshot = committed
    return .committed(committed)
  }
}
