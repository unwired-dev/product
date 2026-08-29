import Foundation
import Testing

@testable import unwired_mail

@MainActor
@Suite(.serialized)
// swiftlint:disable:next type_body_length
final class ComposePreferenceSyncServiceTests {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user",
    identityToken: "identity-token",
    productAccountId: "product-account",
    trustedDeviceId: "trusted-device"
  )

  @Test
  func testDefaultsMatchComposeProductDecisions() {
    #expect(ComposePreferences.defaults.undoSendWindow == .tenSeconds)
    #expect(ComposePreferences.defaults.showsFormattingToolbar)
    #expect(ComposePreferences.defaults.includesQuotedText)
    #expect(ComposePreferences.defaults.includesForwardedAttachments)
    #expect(ComposePreferences.defaults.schemaVersion == 2)
  }

  @Test
  func testDecodingLegacyPayloadIgnoresRetiredPresentationAndFillsNewDefaults() throws {
    let data = Data(
      #"{"undoSendWindow":20,"presentation":"fullScreen","showsFormattingToolbar":false}"#.utf8
    )

    let preferences = try JSONDecoder().decode(ComposePreferences.self, from: data)

    #expect(preferences.undoSendWindow == .twentySeconds)
    #expect(!(preferences.showsFormattingToolbar))
    #expect(preferences.includesQuotedText)
    #expect(preferences.includesForwardedAttachments)
    #expect(preferences.schemaVersion == 2)
  }

  @Test
  func testDecodingFutureSchemaFails() {
    let data = Data(#"{"schemaVersion":3,"undoSendWindow":10}"#.utf8)

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ComposePreferences.self, from: data)
    }
  }

  @Test
  func testDecodingUnknownUndoSendWindowFallsBackToDefault() throws {
    let data = Data(
      #"{"undoSendWindow":45,"presentation":"expanded","showsFormattingToolbar":false}"#.utf8
    )

    let preferences = try JSONDecoder().decode(ComposePreferences.self, from: data)

    #expect(preferences.undoSendWindow == .tenSeconds)
    #expect(!(preferences.showsFormattingToolbar))
  }

  @Test
  func testDecodingMalformedBooleansPreservesValidFields() throws {
    let data = Data(
      #"""
      {"undoSendWindow":20,"presentation":"fullScreen","showsFormattingToolbar":"yes",
      "includesQuotedText":1,"includesForwardedAttachments":{}}
      """#.utf8
    )

    let preferences = try JSONDecoder().decode(ComposePreferences.self, from: data)

    #expect(preferences.undoSendWindow == .twentySeconds)
    #expect(preferences.showsFormattingToolbar)
    #expect(preferences.includesQuotedText)
    #expect(preferences.includesForwardedAttachments)
  }

  @Test(.bug(id: 566))
  func testCurrentPayloadOmitsPresentationAndFencesLegacyClients() throws {
    let data = try JSONEncoder().encode(ComposePreferences(undoSendWindow: .twentySeconds))
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(payload["schemaVersion"] as? Int == 2)
    #expect(payload["presentation"] == nil)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(LegacyComposePreferences.self, from: data)
    }
  }

  @Test
  func testCorruptLocalStateIsRemovedAndTreatedAsMissing() throws {
    let suiteName = "ComposePreferenceSyncServiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let key = "mail-workflow-preferences.compose.\(session.productAccountId)"
    defaults.set(Data("not-json".utf8), forKey: key)
    let localStore = UserDefaultsComposePreferenceStateStore(defaults: defaults)

    let restored = try localStore.load(productAccountId: session.productAccountId)

    #expect(restored == nil)
    #expect(defaults.data(forKey: key) == nil)
  }

  @Test(.bug(id: 566))
  func testLegacyLocalStateDropsOnlyRetiredPresentationEdits() throws {
    let suiteName = "ComposePreferenceSyncServiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let key = "mail-workflow-preferences.compose.\(session.productAccountId)"
    let legacy = LegacyComposePreferenceLocalState(
      conflicts: [:],
      pendingChanges: [
        .formattingToolbar: .init(baseValue: .boolean(true), localValue: .boolean(false)),
        .presentation: .init(
          baseValue: .presentation(.partial),
          localValue: .presentation(.fullScreen)
        ),
      ],
      preferences: ComposePreferences(showsFormattingToolbar: false)
    )
    defaults.set(try JSONEncoder().encode(legacy), forKey: key)
    let localStore = UserDefaultsComposePreferenceStateStore(defaults: defaults)

    let loaded = try localStore.load(productAccountId: session.productAccountId)
    let restored = try #require(loaded)

    #expect(restored.preferences.showsFormattingToolbar == false)
    #expect(Set(restored.pendingChanges.keys) == [.formattingToolbar])
    let migratedData = try #require(defaults.data(forKey: key))
    #expect(
      try JSONDecoder().decode(ComposePreferenceLocalState.self, from: migratedData) == restored
    )
  }

  @Test
  func testOfflineEditPersistsAndSynchronizesAfterReconnect() async {
    let localStore = InMemoryComposePreferenceLocalStateStore()
    let syncService = InMemoryComposePreferenceSyncService()
    syncService.loadError = URLError(.notConnectedToInternet)
    let store = ComposePreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: localStore,
      automaticallySynchronizes: false
    )

    store.setUndoSendWindow(.thirtySeconds)
    await store.synchronize()

    #expect(store.preferences.undoSendWindow == .thirtySeconds)
    #expect(store.hasPendingChanges)

    syncService.loadError = nil
    let restored = ComposePreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: localStore,
      automaticallySynchronizes: false
    )
    await restored.synchronize()

    #expect(syncService.snapshot?.preferences.undoSendWindow == .thirtySeconds)
    #expect(!(restored.hasPendingChanges))
  }

  @Test
  func testProfileScopeKeepsLocalPreferencesSeparateFromMigratedDefaultProfile() {
    let localStore = InMemoryComposePreferenceLocalStateStore()
    let workProfileId = MailProfileId(rawValue: "work")
    let migratedStore = ComposePreferenceStore(
      session: session,
      syncService: InMemoryComposePreferenceSyncService(),
      localStateStore: localStore,
      automaticallySynchronizes: false
    )
    migratedStore.setUndoSendWindow(.thirtySeconds)

    let workStore = ComposePreferenceStore(
      session: session,
      syncService: InMemoryComposePreferenceSyncService(),
      localStateStore: localStore,
      recordScope: .profile(workProfileId),
      automaticallySynchronizes: false
    )

    #expect(workStore.preferences.undoSendWindow == .tenSeconds)
    workStore.setUndoSendWindow(.off)

    let restoredMigratedStore = ComposePreferenceStore(
      session: session,
      syncService: InMemoryComposePreferenceSyncService(),
      localStateStore: localStore,
      automaticallySynchronizes: false
    )
    let restoredWorkStore = ComposePreferenceStore(
      session: session,
      syncService: InMemoryComposePreferenceSyncService(),
      localStateStore: localStore,
      recordScope: .profile(workProfileId),
      automaticallySynchronizes: false
    )

    #expect(restoredMigratedStore.preferences.undoSendWindow == .thirtySeconds)
    #expect(restoredWorkStore.preferences.undoSendWindow == .off)
  }

  @Test
  func testNonOverlappingChangesMergeAndSameFieldConflictRequiresResolution() async {
    let syncService = InMemoryComposePreferenceSyncService()
    let store = ComposePreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: InMemoryComposePreferenceLocalStateStore(),
      automaticallySynchronizes: false
    )
    store.setShowsFormattingToolbar(false)
    syncService.snapshot = ComposePreferenceSyncSnapshot(
      preferences: ComposePreferences(
        undoSendWindow: .twentySeconds
      ),
      updatedAt: 3
    )

    await store.synchronize()

    #expect(store.preferences.undoSendWindow == .twentySeconds)
    #expect(!(store.preferences.showsFormattingToolbar))
    #expect(store.conflicts.isEmpty)

    store.setUndoSendWindow(.thirtySeconds)
    syncService.snapshot = ComposePreferenceSyncSnapshot(
      preferences: ComposePreferences(undoSendWindow: .off, showsFormattingToolbar: false),
      updatedAt: 5
    )
    await store.synchronize()

    let conflict = store.conflicts.first
    #expect(conflict?.field == .undoSend)
    #expect(conflict?.localValue == .undoSend(.thirtySeconds))
    #expect(conflict?.remoteValue == .undoSend(.off))

    store.resolveConflict(.undoSend, useLocalValue: true)
    await store.synchronize()

    #expect(store.conflicts.isEmpty)
    #expect(syncService.snapshot?.preferences.undoSendWindow == .thirtySeconds)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testUpdateSessionLoadsOnlyTheNewProductAccountsLocalState() throws {
    let localStore = InMemoryComposePreferenceLocalStateStore()
    let otherSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "other-apple-user",
      identityToken: "other-identity-token",
      productAccountId: "other-product-account",
      trustedDeviceId: "other-trusted-device"
    )
    try localStore.save(
      ComposePreferenceLocalState(
        conflicts: [
          .quotedText: ComposePreferenceConflict(
            field: .quotedText,
            localValue: .boolean(false),
            remoteValue: .boolean(true)
          )
        ],
        pendingChanges: [
          .formattingToolbar: ComposePreferencePendingChange(
            baseValue: .boolean(true),
            localValue: .boolean(false)
          )
        ],
        preferences: ComposePreferences(includesQuotedText: false)
      ),
      productAccountId: session.productAccountId
    )
    try localStore.save(
      ComposePreferenceLocalState(
        conflicts: [
          .quotedText: ComposePreferenceConflict(
            field: .quotedText,
            localValue: .boolean(false),
            remoteValue: .boolean(true)
          )
        ],
        pendingChanges: [
          .undoSend: ComposePreferencePendingChange(
            baseValue: .undoSend(.tenSeconds),
            localValue: .undoSend(.off)
          )
        ],
        preferences: ComposePreferences(undoSendWindow: .off, includesQuotedText: false)
      ),
      productAccountId: otherSession.productAccountId
    )
    let store = ComposePreferenceStore(
      session: session,
      syncService: InMemoryComposePreferenceSyncService(),
      localStateStore: localStore,
      automaticallySynchronizes: false
    )

    store.updateSession(otherSession)

    #expect(store.preferences.undoSendWindow == .off)
    #expect(store.preferences.includesQuotedText == false)
    #expect(store.hasPendingChanges)
    #expect(store.conflicts.map(\.field) == [.quotedText])
  }

}

private struct LegacyComposePreferences: Decodable {
  let schemaVersion: Int

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard schemaVersion <= 1 else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Compose preference schema is newer than this client supports."
      )
    }
  }
}

private final class InMemoryComposePreferenceLocalStateStore:
  ComposePreferenceLocalStatePersisting
{
  private var states: [String: ComposePreferenceLocalState] = [:]

  func clear(productAccountId: String) throws {
    states[productAccountId] = nil
  }

  func load(productAccountId: String) throws -> ComposePreferenceLocalState? {
    states[productAccountId]
  }

  func save(_ state: ComposePreferenceLocalState, productAccountId: String) throws {
    states[productAccountId] = state
  }
}

private final class InMemoryComposePreferenceSyncService: ComposePreferenceSyncing {
  var loadError: Error?
  var snapshot: ComposePreferenceSyncSnapshot?

  func loadPreferences(
    session _: ProductAccountSessionSnapshot
  ) async throws -> ComposePreferenceSyncSnapshot? {
    if let loadError { throw loadError }
    return snapshot
  }

  func savePreferences(
    _ preferences: ComposePreferences,
    expectedUpdatedAt: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ComposePreferenceConditionalSaveResult {
    guard snapshot?.updatedAt == expectedUpdatedAt else {
      return .conflict(
        snapshot ?? ComposePreferenceSyncSnapshot(preferences: .defaults, updatedAt: nil)
      )
    }
    let committed = ComposePreferenceSyncSnapshot(
      preferences: preferences,
      updatedAt: (snapshot?.updatedAt ?? 0) + 1
    )
    snapshot = committed
    return .committed(committed)
  }
}
