import Foundation
import Testing

@testable import unwired_mail

@MainActor
@Suite(.serialized)
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
    #expect(ComposePreferences.defaults.presentation == .partial)
    #expect(ComposePreferences.defaults.showsFormattingToolbar)
    #expect(ComposePreferences.defaults.includesQuotedText)
    #expect(ComposePreferences.defaults.includesForwardedAttachments)
  }

  @Test
  func testDecodingOlderPayloadPreservesChoicesAndFillsNewDefaults() throws {
    let data = Data(
      #"{"undoSendWindow":20,"presentation":"fullScreen","showsFormattingToolbar":false}"#.utf8
    )

    let preferences = try JSONDecoder().decode(ComposePreferences.self, from: data)

    #expect(preferences.undoSendWindow == .twentySeconds)
    #expect(preferences.presentation == .fullScreen)
    #expect(!(preferences.showsFormattingToolbar))
    #expect(preferences.includesQuotedText)
    #expect(preferences.includesForwardedAttachments)
  }

  @Test
  func testDecodingFutureSchemaFails() {
    let data = Data(#"{"schemaVersion":2,"undoSendWindow":10}"#.utf8)

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ComposePreferences.self, from: data)
    }
  }

  @Test
  func testDecodingUnknownEnumValuesFallsBackToDefaults() throws {
    let data = Data(
      #"{"undoSendWindow":45,"presentation":"expanded","showsFormattingToolbar":false}"#.utf8
    )

    let preferences = try JSONDecoder().decode(ComposePreferences.self, from: data)

    #expect(preferences.undoSendWindow == .tenSeconds)
    #expect(preferences.presentation == .partial)
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
    #expect(preferences.presentation == .fullScreen)
    #expect(preferences.showsFormattingToolbar)
    #expect(preferences.includesQuotedText)
    #expect(preferences.includesForwardedAttachments)
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
  func testNonOverlappingChangesMergeAndSameFieldConflictRequiresResolution() async {
    let syncService = InMemoryComposePreferenceSyncService()
    let store = ComposePreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: InMemoryComposePreferenceLocalStateStore(),
      automaticallySynchronizes: false
    )
    store.setPresentation(.fullScreen)
    syncService.snapshot = ComposePreferenceSyncSnapshot(
      preferences: ComposePreferences(
        undoSendWindow: .twentySeconds,
        showsFormattingToolbar: false
      ),
      updatedAt: 3
    )

    await store.synchronize()

    #expect(store.preferences.presentation == .fullScreen)
    #expect(store.preferences.undoSendWindow == .twentySeconds)
    #expect(!(store.preferences.showsFormattingToolbar))
    #expect(store.conflicts.isEmpty)

    store.setUndoSendWindow(.thirtySeconds)
    syncService.snapshot = ComposePreferenceSyncSnapshot(
      preferences: ComposePreferences(undoSendWindow: .off, presentation: .fullScreen),
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
        preferences: ComposePreferences(presentation: .fullScreen)
      ),
      productAccountId: session.productAccountId
    )
    try localStore.save(
      ComposePreferenceLocalState(
        conflicts: [
          .presentation: ComposePreferenceConflict(
            field: .presentation,
            localValue: .presentation(.partial),
            remoteValue: .presentation(.fullScreen)
          )
        ],
        pendingChanges: [
          .undoSend: ComposePreferencePendingChange(
            baseValue: .undoSend(.tenSeconds),
            localValue: .undoSend(.off)
          )
        ],
        preferences: ComposePreferences(undoSendWindow: .off)
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
    #expect(store.preferences.presentation == .partial)
    #expect(store.hasPendingChanges)
    #expect(store.conflicts.map(\.field) == [.presentation])
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
