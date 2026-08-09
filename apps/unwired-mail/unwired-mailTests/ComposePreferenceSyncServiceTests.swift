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
  func testServiceEncryptsPreferencesBeforeProductSyncWrite() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingComposePreferenceTransport()
    let service = ComposePreferenceSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore,
        transport: transport
      )
    )
    let preferences = ComposePreferences(
      undoSendWindow: .thirtySeconds,
      presentation: .fullScreen,
      showsFormattingToolbar: false
    )

    let result = try await service.savePreferences(
      preferences,
      expectedUpdatedAt: nil,
      session: session
    )

    guard case .committed(let snapshot) = result else {
      Issue.record("Expected committed Compose preferences")
      return
    }
    #expect(snapshot.preferences == preferences)
    let written = try #require(transport.payload)
    let encoded = try JSONEncoder().encode(preferences)
    let ciphertext = try #require(Data(base64Encoded: written.encryptedPayload.ciphertextBase64))
    #expect(!(ciphertext.contains(encoded)))
    #expect(!(ciphertext.contains(Data("fullScreen".utf8))))
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

private final class RecordingComposePreferenceTransport: ProductSyncRecordTransport {
  private(set) var payload: EncryptedProductSyncPayload?

  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor _: String?,
    limit _: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    let page =
      payload.map { $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) ? [$0] : [] }
      ?? []
    return EncryptedProductSyncPayloadPage(continueCursor: "", isDone: true, page: page)
  }

  func getEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    guard let payload, payloadIdentifiers.contains(payload.payloadIdentifier) else { return [] }
    return [payload]
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    if let payload, payload.updatedAt != expectedUpdatedAt {
      return payload
    }
    let written = EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: (payload?.updatedAt ?? 0) + 1
    )
    payload = written
    return written
  }
}
