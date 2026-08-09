import Foundation
import Testing

@testable import unwired_mail

@MainActor
@Suite(.serialized)
final class SwipePreferenceSyncServiceTests {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user",
    identityToken: "identity-token",
    productAccountId: "product-account",
    trustedDeviceId: "trusted-device"
  )

  @Test
  func testDefaultsAndNormalizationKeepAtMostTwoUniqueActionsPerEdge() {
    #expect(SwipePreferences.defaults.leadingActions == [.readUnread])
    #expect(SwipePreferences.defaults.trailingActions == [.archive, .trash])
    #expect(SwipePreferences.defaults.allowsFullSwipe)

    let preferences = SwipePreferences(
      leadingActions: [.archive, .archive, .move, .trash],
      trailingActions: [.trash, .move, .archive]
    )

    #expect(preferences.leadingActions == [.archive, .move])
    #expect(preferences.trailingActions == [.trash, .move])
  }

  @Test
  func testDecodingOlderPayloadFillsMissingFieldsAndRejectsFutureSchemas() throws {
    let decoded = try JSONDecoder().decode(
      SwipePreferences.self,
      from: Data(#"{"leadingActions":["move"]}"#.utf8)
    )

    #expect(decoded.leadingActions == [.move])
    #expect(decoded.trailingActions == [.archive, .trash])
    #expect(decoded.allowsFullSwipe)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        SwipePreferences.self,
        from: Data(#"{"schemaVersion":2}"#.utf8)
      )
    }
  }

  @Test
  func testOfflineEditPersistsLocallyAndRemainsPending() async {
    let localStore = InMemorySwipePreferenceLocalStateStore()
    let syncService = InMemorySwipePreferenceSyncService()
    syncService.loadError = URLError(.notConnectedToInternet)
    let store = SwipePreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: localStore,
      automaticallySynchronizes: false
    )

    store.setAction(.move, at: 0, on: .leading)
    await store.synchronize()

    #expect(store.preferences.leadingActions == [.move, .readUnread])
    #expect(store.hasPendingChanges)
    #expect(store.errorMessage != nil)

    let restored = SwipePreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: localStore,
      automaticallySynchronizes: false
    )
    #expect(restored.preferences.leadingActions == [.move, .readUnread])
    #expect(restored.hasPendingChanges)
  }

  @Test
  func testNonOverlappingChangesMergeAndSameFieldChangesRequireResolution() async {
    let syncService = InMemorySwipePreferenceSyncService()
    let store = SwipePreferenceStore(
      session: session,
      syncService: syncService,
      localStateStore: InMemorySwipePreferenceLocalStateStore(),
      automaticallySynchronizes: false
    )
    store.setAction(.pinUnpin, at: 0, on: .leading)
    syncService.snapshot = SwipePreferenceSyncSnapshot(
      preferences: SwipePreferences(trailingActions: [.spamNotSpam]),
      updatedAt: 4
    )

    await store.synchronize()

    #expect(store.preferences.leadingActions == [.pinUnpin, .readUnread])
    #expect(store.preferences.trailingActions == [.spamNotSpam])
    #expect(store.conflicts.isEmpty)
    #expect(!(store.hasPendingChanges))

    store.setAction(.trash, at: 0, on: .leading)
    syncService.snapshot = SwipePreferenceSyncSnapshot(
      preferences: SwipePreferences(
        leadingActions: [.archive],
        trailingActions: [.spamNotSpam]
      ),
      updatedAt: 6
    )
    await store.synchronize()

    let conflict = store.conflicts.first
    #expect(conflict?.field == .leadingActions)
    #expect(conflict?.localValue == .actions([.trash, .pinUnpin]))
    #expect(conflict?.remoteValue == .actions([.archive]))

    store.resolveConflict(.leadingActions, useLocalValue: true)
    await store.synchronize()

    #expect(store.conflicts.isEmpty)
    #expect(syncService.snapshot?.preferences.leadingActions == [.trash, .pinUnpin])
  }

  @Test
  func testEverySupportedGesturePlatformUsesTheSameAdaptiveActions() throws {
    let unread = message(id: "message", states: ["INBOX", "UNREAD"])
    let configured: [SwipeAction] = [
      .readUnread, .archive, .trash, .pinUnpin, .move, .spamNotSpam,
    ]
    let supported: Set<ProviderMailAction> = [
      .archive, .delete, .markRead, .move, .spam,
    ]

    let actionsByPlatform = SwipeGesturePlatform.allCases.map {
      SwipeActionResolver.resolve(
        configuredActions: configured,
        context: SwipeActionContext(
          messages: [unread],
          pinTargetMessageId: unread.id,
          pinnedMessageIds: [],
          providerActions: supported
        ),
        platform: $0
      )
    }

    let expectedTitles = ["Read", "Archive", "Trash", "Pin", "Move", "Spam"]
    #expect(actionsByPlatform.allSatisfy { $0.map(\.title) == expectedTitles })

    let readSpam = message(id: "read-spam", states: ["SPAM"])
    let inverse = SwipeActionResolver.resolve(
      configuredActions: [.readUnread, .pinUnpin, .spamNotSpam],
      context: SwipeActionContext(
        messages: [readSpam],
        pinTargetMessageId: readSpam.id,
        pinnedMessageIds: [readSpam.id],
        providerActions: [.markUnread, .notSpam]
      ),
      platform: .macOSTrackpad
    )
    #expect(inverse.map(\.title) == ["Unread", "Unpin", "Not Spam"])
  }

  @Test
  func testUnsupportedOutermostActionIsOmittedWithoutReplacingFullSwipeMeaning() {
    let message = message(id: "message", states: ["INBOX"])
    let preferences = SwipePreferences(
      leadingActions: [.archive, .trash],
      trailingActions: [],
      allowsFullSwipe: true
    )
    let resolved = SwipeActionResolver.resolve(
      configuredActions: preferences.leadingActions,
      context: SwipeActionContext(
        messages: [message],
        pinTargetMessageId: message.id,
        pinnedMessageIds: [],
        providerActions: [.delete]
      ),
      platform: .iPadTouch
    )

    #expect(resolved.map(\.configuredAction) == [.trash])
    #expect(
      !SwipeActionResolver.allowsFullSwipe(
        preferences: preferences,
        edge: .leading,
        resolvedActions: resolved
      )
    )
  }

  @Test
  func testPinsSwipeTargetsTheVisiblePinnedMessageInsteadOfTheLatestMessage() {
    let latest = message(id: "latest", states: ["INBOX"])
    let pinned = message(id: "older-pinned", states: ["INBOX"])

    #expect(
      MailShellThreadList.pinTargetMessageId(
        visibleMessages: [pinned],
        latestMessageId: latest.id,
        collection: .pins
      ) == pinned.id
    )
    #expect(
      MailShellThreadList.pinTargetMessageId(
        visibleMessages: [pinned],
        latestMessageId: latest.id,
        collection: .inbox
      ) == latest.id
    )
  }

  @Test
  func testServiceEncryptsPreferencesBeforeProductSyncWrite() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingSwipePreferenceTransport()
    let service = SwipePreferenceSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore,
        transport: transport
      )
    )
    let preferences = SwipePreferences(
      leadingActions: [.pinUnpin, .move],
      trailingActions: [.spamNotSpam],
      allowsFullSwipe: false
    )

    let result = try await service.savePreferences(
      preferences,
      expectedUpdatedAt: nil,
      session: session
    )

    guard case .committed(let snapshot) = result else {
      Issue.record("Expected committed swipe preferences")
      return
    }
    #expect(snapshot.preferences == preferences)
    let written = try #require(transport.payload)
    let encoded = try JSONEncoder().encode(preferences)
    let ciphertext = try #require(Data(base64Encoded: written.encryptedPayload.ciphertextBase64))
    #expect(!(ciphertext.contains(encoded)))
    #expect(!(ciphertext.contains(Data("pinUnpin".utf8))))
  }

  private func message(id: String, states: [String]) -> MailboxMessageMetadata {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "account"
      )
    )
    return MailboxMessageMetadata(
      categoryId: nil,
      connectionId: connectionId,
      from: "sender@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: 1,
      providerMessageId: id,
      providerStateIds: states,
      providerThreadId: "thread",
      recipientHeaders: nil,
      replyTo: nil,
      rfcMessageId: nil,
      snippet: "Snippet",
      subject: "Subject"
    )
  }
}

private final class InMemorySwipePreferenceLocalStateStore:
  SwipePreferenceLocalStatePersisting
{
  private var states: [String: SwipePreferenceLocalState] = [:]

  func clear(productAccountId: String) throws {
    states[productAccountId] = nil
  }

  func load(productAccountId: String) throws -> SwipePreferenceLocalState? {
    states[productAccountId]
  }

  func save(_ state: SwipePreferenceLocalState, productAccountId: String) throws {
    states[productAccountId] = state
  }
}

private final class InMemorySwipePreferenceSyncService: SwipePreferenceSyncing {
  var loadError: Error?
  var snapshot: SwipePreferenceSyncSnapshot?

  func loadPreferences(
    session _: ProductAccountSessionSnapshot
  ) async throws -> SwipePreferenceSyncSnapshot? {
    if let loadError { throw loadError }
    return snapshot
  }

  func savePreferences(
    _ preferences: SwipePreferences,
    expectedUpdatedAt: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> SwipePreferenceConditionalSaveResult {
    guard snapshot?.updatedAt == expectedUpdatedAt else {
      return .conflict(
        snapshot ?? SwipePreferenceSyncSnapshot(preferences: .defaults, updatedAt: nil)
      )
    }
    let committed = SwipePreferenceSyncSnapshot(
      preferences: preferences,
      updatedAt: (snapshot?.updatedAt ?? 0) + 1
    )
    snapshot = committed
    return .committed(committed)
  }
}

private final class RecordingSwipePreferenceTransport: ProductSyncRecordTransport {
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
