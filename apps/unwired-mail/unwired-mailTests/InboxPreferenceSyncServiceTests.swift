import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length

@Test
func testDecodingPartialMailViewConfigurationDefaultsMissingCollections() throws {
  let payloads = [
    #"{"schemaVersion":2,"mailViewConfiguration":{"categorySlots":["system:flights"]}}"#,
    #"{"schemaVersion":2,"mailViewConfiguration":{"importantCategoryIds":["system:people"]}}"#,
  ]

  let preferences = try payloads.map { payload in
    try JSONDecoder().decode(InboxPreferences.self, from: Data(payload.utf8))
  }

  #expect(preferences[0].mailViewConfiguration.importantCategoryIds.isEmpty)
  #expect(preferences[0].mailViewConfiguration.categorySlots == ["system:flights", nil, nil])
  #expect(preferences[1].mailViewConfiguration.importantCategoryIds == ["system:people"])
  #expect(preferences[1].mailViewConfiguration.categorySlots == [nil, nil, nil])
}

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
    #expect(
      InboxPreferences.defaults.mailViewConfiguration.categorySlots == [
        "system:invoices",
        "system:promotions",
        "system:flights",
      ]
    )
    #expect(
      Set(InboxPreferences.defaults.mailViewConfiguration.importantCategoryIds) == [
        "system:people",
        "system:invites",
        "system:invoices",
        "system:flights",
      ]
    )
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
  func testDecodingMailViewConfigurationNormalizesMalformedValuesAndShortSlots() throws {
    let data = Data(
      #"""
      {
        "schemaVersion": 2,
        "mailViewConfiguration": {
          "importantCategoryIds": ["", "system:people", "system:people"],
          "categorySlots": ["system:flights", "system:flights"]
        }
      }
      """#.utf8
    )

    let preferences = try JSONDecoder().decode(InboxPreferences.self, from: data)

    #expect(preferences.mailViewConfiguration.importantCategoryIds == ["system:people"])
    #expect(
      preferences.mailViewConfiguration.categorySlots == ["system:flights", nil, nil]
    )
  }

  @Test
  func testDecodingFutureSchemaFails() {
    let data = Data(#"{"schemaVersion":3,"threadDensity":"compact"}"#.utf8)

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
  @Test
  func testServiceEncryptsPreferencesBeforeProductSyncWrite() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingInboxPreferenceTransport()
    let service = InboxPreferenceSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore,
        transport: transport
      )
    )
    let preferences = InboxPreferences(
      threadDensity: .compact,
      previewLength: .three,
      showsContactImages: false
    )

    let result = try await service.savePreferences(
      preferences,
      expectedUpdatedAt: nil,
      session: session
    )

    guard case .committed(let snapshot) = result else {
      Issue.record("Expected committed Inbox preferences")
      return
    }
    #expect(snapshot.preferences == preferences)
    let written = try #require(transport.payload)
    let encoded = try JSONEncoder().encode(preferences)
    let ciphertext = try #require(Data(base64Encoded: written.encryptedPayload.ciphertextBase64))
    #expect(!(ciphertext.contains(encoded)))
    #expect(!(ciphertext.contains(Data("compact".utf8))))
  }

  @Test
  func testMailViewConfigurationRejectsDuplicateSlotsAndRemovesUnavailableCategories() {
    let configuration = MailViewConfiguration(
      importantCategoryIds: ["system:people", "custom:removed"],
      categorySlots: ["system:flights", "system:flights", "custom:removed"]
    )

    #expect(configuration.categorySlots == ["system:flights", nil, "custom:removed"])
    #expect(
      configuration.retainingCategories(in: ["system:people", "system:flights"])
        == MailViewConfiguration(
          importantCategoryIds: ["system:people"],
          categorySlots: ["system:flights", nil, nil]
        )
    )
  }

  @Test
  func testMailViewPreferencesAreIsolatedByMailProfileScope() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingInboxPreferenceTransport()
    let boundary = ProductSyncRecordBoundary(
      keyMaterialStore: keyStore,
      transport: transport
    )
    let defaultService = InboxPreferenceSyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: boundary
    )
    let profileId = MailProfileId(rawValue: "profile-two")
    let secondService = InboxPreferenceSyncService(
      recordScope: .profile(profileId),
      recordBoundary: boundary
    )
    let defaultPreferences = InboxPreferences(
      mailViewConfiguration: MailViewConfiguration(
        importantCategoryIds: ["system:people"],
        categorySlots: ["system:invoices", nil, nil]
      )
    )
    let secondPreferences = InboxPreferences(
      mailViewConfiguration: MailViewConfiguration(
        importantCategoryIds: ["system:flights"],
        categorySlots: ["system:flights", nil, nil]
      )
    )

    _ = try await defaultService.savePreferences(
      defaultPreferences,
      expectedUpdatedAt: nil,
      session: session
    )
    _ = try await secondService.savePreferences(
      secondPreferences,
      expectedUpdatedAt: nil,
      session: session
    )

    #expect(
      try await defaultService.loadPreferences(session: session)?.preferences == defaultPreferences)
    #expect(
      try await secondService.loadPreferences(session: session)?.preferences == secondPreferences)
    #expect(
      Set(transport.payloads.keys) == [
        InboxPreferences.primaryIdentifier,
        MailProfileRecordScope.profile(profileId).productSyncIdentifier(
          InboxPreferences.primaryIdentifier
        ),
      ]
    )
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

private final class RecordingInboxPreferenceTransport: ProductSyncRecordTransport {
  private(set) var payloads: [String: EncryptedProductSyncPayload] = [:]

  var payload: EncryptedProductSyncPayload? {
    payloads.values.first
  }

  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor _: String?,
    limit _: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    let page = payloads.values.filter { $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) }
    return EncryptedProductSyncPayloadPage(continueCursor: "", isDone: true, page: page)
  }

  func getEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    return payloadIdentifiers.compactMap { payloads[$0] }
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    if let payload = payloads[payloadIdentifier], payload.updatedAt != expectedUpdatedAt {
      return payload
    }
    let written = EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: (payloads[payloadIdentifier]?.updatedAt ?? 0) + 1
    )
    payloads[payloadIdentifier] = written
    return written
  }
}
