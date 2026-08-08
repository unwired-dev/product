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
    #expect(MailboxConnectionCapabilities.microsoftGraph.canRespondToReadReceipts)
    #expect(MailboxConnectionCapabilities.exchangeWebServices.canRequestReadReceipts)
    #expect(MailboxConnectionCapabilities.exchangeWebServices.canRespondToReadReceipts)
    #expect(!(MailboxConnectionCapabilities.imapRead.canRequestReadReceipts))
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
  func testServiceEncryptsPreferencesBeforeProductSyncWrite() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingReadingPreferenceTransport()
    let service = ReadingPreferenceSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore,
        transport: transport
      )
    )
    let preferences = ReadingPreferences(
      markReadAfter: .afterFiveSeconds,
      outgoingReadReceipts: .requestByDefault
    )

    let result = try await service.savePreferences(
      preferences,
      expectedUpdatedAt: nil,
      session: session
    )

    guard case .committed(let snapshot) = result else {
      Issue.record("Expected committed Reading preferences")
      return
    }
    #expect(snapshot.preferences == preferences)
    let written = try #require(transport.payload)
    let encoded = try JSONEncoder().encode(preferences)
    let ciphertext = try #require(Data(base64Encoded: written.encryptedPayload.ciphertextBase64))
    #expect(!(ciphertext.contains(encoded)))
    #expect(!(ciphertext.contains(Data("requestByDefault".utf8))))
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
  var loadError: Error?
  var snapshot: ReadingPreferenceSyncSnapshot?

  func loadPreferences(
    session _: ProductAccountSessionSnapshot
  ) async throws -> ReadingPreferenceSyncSnapshot? {
    if let loadError { throw loadError }
    return snapshot
  }

  func savePreferences(
    _ preferences: ReadingPreferences,
    expectedUpdatedAt: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ReadingPreferenceConditionalSaveResult {
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

private final class RecordingReadingPreferenceTransport: ProductSyncRecordTransport {
  private(set) var payload: EncryptedProductSyncPayload?

  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor _: String?,
    limit _: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    let page =
      payload.map {
        $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) ? [$0] : []
      } ?? []
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
    if let payload, payload.updatedAt != expectedUpdatedAt { return payload }
    let written = EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: (payload?.updatedAt ?? 0) + 1
    )
    payload = written
    return written
  }
}
