import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length

@MainActor
@Suite(.serialized)
final class InboxPreferenceSyncServiceTests {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user",
    identityToken: "identity-token",
    productAccountId: "product-account",
    trustedDeviceId: "trusted-device"
  )

  @Test
  func testDefaultsMatchInboxProductDecisions() {
    #expect(InboxPreferences.defaults.threadDensity == .comfortable)
    #expect(InboxPreferences.defaults.previewLength == .two)
    #expect(InboxPreferences.defaults.showsContactImages)
    #expect(InboxPreferences.defaults.showsCategoryBadges)
    #expect(InboxPreferences.defaults.showsAttachmentIndicators)
  }

  @Test
  func testDecodingOlderPayloadFillsMissingFieldsWithoutResettingExistingValues() throws {
    let data = Data(
      #"{"threadDensity":"compact","showsContactImages":false}"#.utf8
    )

    let preferences = try JSONDecoder().decode(InboxPreferences.self, from: data)

    #expect(preferences.threadDensity == .compact)
    #expect(!(preferences.showsContactImages))
    #expect(preferences.previewLength == .two)
    #expect(preferences.showsCategoryBadges)
    #expect(preferences.showsAttachmentIndicators)
  }

  @Test
  func testDecodingFutureSchemaFails() {
    let data = Data(#"{"schemaVersion":2,"threadDensity":"compact"}"#.utf8)

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(InboxPreferences.self, from: data)
    }
  }

  @Test
  func testDecodingOlderLocalStatePreservesPreferencesAndDefaultsMissingCollections() throws {
    let data = Data(
      #"{"preferences":{"threadDensity":"compact","showsContactImages":false}}"#.utf8
    )

    let state = try JSONDecoder().decode(InboxPreferenceLocalState.self, from: data)

    #expect(state.preferences.threadDensity == .compact)
    #expect(!(state.preferences.showsContactImages))
    #expect(state.pendingChanges.isEmpty)
    #expect(state.conflicts.isEmpty)
  }

  @Test
  func testFailedLocalRestorationDoesNotOverwriteStoredState() async {
    let localStore = InMemoryInboxPreferenceLocalStateStore()
    localStore.loadError = CocoaError(.fileReadCorruptFile)
    let syncService = InMemoryInboxPreferenceSyncService()
    let store = InboxPreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: localStore
    )

    store.setPreviewLength(.three)
    await store.synchronize()

    #expect(localStore.saveCount == 0)
    #expect(syncService.loadCount == 0)
    #expect(store.errorMessage != nil)
  }

  @Test
  func testOfflineEditPersistsLocallyAndRemainsPending() async {
    let localStore = InMemoryInboxPreferenceLocalStateStore()
    let syncService = InMemoryInboxPreferenceSyncService()
    syncService.loadError = URLError(.notConnectedToInternet)
    let store = InboxPreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: localStore,
      automaticallySynchronizes: false
    )

    store.setPreviewLength(.three)
    await store.synchronize()

    #expect(store.preferences.previewLength == .three)
    #expect(store.hasPendingChanges)
    #expect(store.errorMessage != nil)

    let restored = InboxPreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: localStore,
      automaticallySynchronizes: false
    )
    #expect(restored.preferences.previewLength == .three)
    #expect(restored.hasPendingChanges)
  }

  @Test
  func testNonOverlappingRemoteAndLocalChangesMergeAutomatically() async {
    let localStore = InMemoryInboxPreferenceLocalStateStore()
    let syncService = InMemoryInboxPreferenceSyncService()
    let store = InboxPreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: localStore,
      automaticallySynchronizes: false
    )
    store.setPreviewLength(.three)
    syncService.snapshot = InboxPreferenceSyncSnapshot(
      preferences: InboxPreferences(threadDensity: .spacious),
      updatedAt: 4
    )

    await store.synchronize()

    #expect(store.preferences.previewLength == .three)
    #expect(store.preferences.threadDensity == .spacious)
    #expect(!(store.hasPendingChanges))
    #expect(store.conflicts.isEmpty)
    #expect(syncService.snapshot?.preferences == store.preferences)
  }

  @Test
  func testSameFieldChangesPreserveBothValuesForExplicitResolution() async {
    let syncService = InMemoryInboxPreferenceSyncService()
    let store = InboxPreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: InMemoryInboxPreferenceLocalStateStore(),
      automaticallySynchronizes: false
    )
    store.setPreviewLength(.three)
    syncService.snapshot = InboxPreferenceSyncSnapshot(
      preferences: InboxPreferences(previewLength: .one),
      updatedAt: 9
    )

    await store.synchronize()

    let conflict = store.conflicts.first
    #expect(store.preferences.previewLength == .three)
    #expect(conflict?.field == .previewLength)
    #expect(conflict?.localValue == .previewLength(.three))
    #expect(conflict?.remoteValue == .previewLength(.one))
    #expect(syncService.saveCount == 0)

    store.resolveConflict(.previewLength, useLocalValue: true)
    await store.synchronize()

    #expect(store.conflicts.isEmpty)
    #expect(!(store.hasPendingChanges))
    #expect(syncService.snapshot?.preferences.previewLength == .three)
  }

  @Test
  func testOpeningWithNoRemoteRecordDoesNotCreateOne() async {
    let syncService = InMemoryInboxPreferenceSyncService()
    let store = InboxPreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: InMemoryInboxPreferenceLocalStateStore(),
      automaticallySynchronizes: false
    )

    await store.synchronize()

    #expect(store.preferences == .defaults)
    #expect(syncService.saveCount == 0)
  }

  @Test
  func testAutomaticSyncReschedulesAnEditMadeDuringSave() async {
    let saveGate = InboxPreferenceSaveGate()
    let syncService = InMemoryInboxPreferenceSyncService()
    syncService.beforeSave = { await saveGate.holdFirstSave() }
    let store = InboxPreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: InMemoryInboxPreferenceLocalStateStore()
    )

    store.setPreviewLength(.three)
    await saveGate.waitUntilHeld()
    store.setThreadDensity(.compact)
    await saveGate.release()
    for _ in 0..<1_000 {
      if syncService.saveCount == 2, !store.isSynchronizing, !store.hasPendingChanges {
        break
      }
      await Task.yield()
    }

    #expect(syncService.saveCount == 2)
    #expect(syncService.snapshot?.preferences.previewLength == .three)
    #expect(syncService.snapshot?.preferences.threadDensity == .compact)
    #expect(!(store.hasPendingChanges))
  }

  @Test
  func testAccountSwitchDuringLoadDoesNotApplyOrSaveOldAccountState() async throws {
    let loadGate = InboxPreferenceLoadGate()
    let syncService = InMemoryInboxPreferenceSyncService()
    syncService.beforeLoad = { await loadGate.holdFirstLoad() }
    syncService.snapshot = InboxPreferenceSyncSnapshot(
      preferences: InboxPreferences(threadDensity: .spacious),
      updatedAt: 3
    )
    let localStore = InMemoryInboxPreferenceLocalStateStore()
    let otherSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "other-apple-user",
      identityToken: "other-identity-token",
      productAccountId: "other-product-account",
      trustedDeviceId: "other-trusted-device"
    )
    try localStore.save(
      InboxPreferenceLocalState(
        conflicts: [:],
        pendingChanges: [:],
        preferences: InboxPreferences(threadDensity: .compact)
      ),
      productAccountId: otherSession.productAccountId
    )
    let initialSaveCount = localStore.saveCount
    let store = InboxPreferenceStore(
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

    #expect(store.preferences.threadDensity == .compact)
    #expect(syncService.saveCount == 0)
    #expect(localStore.saveCount == initialSaveCount)
    #expect(syncService.loadedProductAccountIds == [session.productAccountId])
  }

}

extension InboxPreferenceSyncServiceTests {
  @Test(arguments: [InboxPreviewLength.one, InboxPreviewLength.two])
  fileprivate func testAutomaticSyncPreservesSameFieldEditMadeDuringSave(
    latestValue: InboxPreviewLength
  ) async {
    let saveGate = InboxPreferenceSaveGate()
    let syncService = InMemoryInboxPreferenceSyncService()
    syncService.beforeSave = { await saveGate.holdFirstSave() }
    let store = InboxPreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: InMemoryInboxPreferenceLocalStateStore()
    )

    store.setPreviewLength(.three)
    await saveGate.waitUntilHeld()
    store.setPreviewLength(latestValue)
    await saveGate.release()
    for _ in 0..<1_000 {
      if syncService.saveCount == 2, !store.isSynchronizing, !store.hasPendingChanges {
        break
      }
      await Task.yield()
    }

    #expect(syncService.saveCount == 2)
    #expect(syncService.snapshot?.preferences.previewLength == latestValue)
    #expect(store.preferences.previewLength == latestValue)
    #expect(store.conflicts.isEmpty)
    #expect(!(store.hasPendingChanges))
  }
}

private final class InMemoryInboxPreferenceLocalStateStore:
  InboxPreferenceLocalStatePersisting
{
  private var states: [String: InboxPreferenceLocalState] = [:]
  var loadError: Error?
  private(set) var saveCount = 0

  func clear(productAccountId: String) throws {
    states[productAccountId] = nil
  }

  func load(productAccountId: String) throws -> InboxPreferenceLocalState? {
    if let loadError { throw loadError }
    return states[productAccountId]
  }

  func save(_ state: InboxPreferenceLocalState, productAccountId: String) throws {
    saveCount += 1
    states[productAccountId] = state
  }
}

private final class InMemoryInboxPreferenceSyncService: InboxPreferenceSyncing {
  var beforeSave: (() async -> Void)?
  var beforeLoad: (() async -> Void)?
  var loadError: Error?
  private(set) var loadCount = 0
  private(set) var loadedProductAccountIds: [String] = []
  private(set) var saveCount = 0
  var snapshot: InboxPreferenceSyncSnapshot?

  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> InboxPreferenceSyncSnapshot? {
    await beforeLoad?()
    loadCount += 1
    loadedProductAccountIds.append(session.productAccountId)
    if let loadError { throw loadError }
    return snapshot
  }

  func savePreferences(
    _ preferences: InboxPreferences,
    expectedUpdatedAt: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> InboxPreferenceConditionalSaveResult {
    await beforeSave?()
    saveCount += 1
    guard snapshot?.updatedAt == expectedUpdatedAt else {
      return .conflict(
        snapshot ?? InboxPreferenceSyncSnapshot(preferences: .defaults, updatedAt: nil)
      )
    }
    let committed = InboxPreferenceSyncSnapshot(
      preferences: preferences,
      updatedAt: (snapshot?.updatedAt ?? 0) + 1
    )
    snapshot = committed
    return .committed(committed)
  }
}

private actor InboxPreferenceLoadGate {
  private var heldContinuation: CheckedContinuation<Void, Never>?
  private var isHeld = false
  private var isReleased = false
  private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

  func holdFirstLoad() async {
    guard !isReleased else { return }
    isHeld = true
    for continuation in waitingContinuations {
      continuation.resume()
    }
    waitingContinuations = []
    await withCheckedContinuation { heldContinuation = $0 }
  }

  func waitUntilHeld() async {
    guard !isHeld else { return }
    await withCheckedContinuation { waitingContinuations.append($0) }
  }

  func release() {
    isReleased = true
    heldContinuation?.resume()
    heldContinuation = nil
  }
}

private actor InboxPreferenceSaveGate {
  private var heldContinuation: CheckedContinuation<Void, Never>?
  private var isHeld = false
  private var isReleased = false
  private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

  func holdFirstSave() async {
    guard !isReleased else { return }
    isHeld = true
    for continuation in waitingContinuations {
      continuation.resume()
    }
    waitingContinuations = []
    await withCheckedContinuation { heldContinuation = $0 }
  }

  func waitUntilHeld() async {
    guard !isHeld else { return }
    await withCheckedContinuation { waitingContinuations.append($0) }
  }

  func release() {
    isReleased = true
    heldContinuation?.resume()
    heldContinuation = nil
  }
}
