import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length

@MainActor
@Suite(.serialized)
final class SignatureSyncServiceTests {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user",
    identityToken: "identity-token",
    productAccountId: "product-account",
    trustedDeviceId: "trusted-device"
  )

  @Test
  func testFormattedDocumentProducesSafeHTMLAndPlainTextAlternative() {
    let document = SignatureDocument(
      runs: [
        SignatureTextRun("Jan & Co", isBold: true),
        SignatureTextRun("\nWebsite", isItalic: true, link: "https://example.com/about"),
      ]
    )

    #expect(document.plainText == "Jan & Co\nWebsite")
    #expect(
      document.html
        == "<strong>Jan &amp; Co</strong><em><a href=\"https://example.com/about\"><br>Website</a></em>"
    )
    #expect(!document.html.contains("<img"))
  }

  @Test
  func testStoreRejectsEmptyBodiesDuplicateNamesAndUnsafeLinks() throws {
    let store = makeStore()
    try store.saveSignature(signature(id: "first", name: "Work", body: "Jan"))

    #expect(throws: SignatureSyncError.duplicateName) {
      try store.saveSignature(signature(id: "second", name: " work ", body: "Other"))
    }
    #expect(throws: SignatureSyncError.emptyBody) {
      try store.saveSignature(signature(id: "empty", name: "Empty", body: "  \n"))
    }
    #expect(throws: SignatureSyncError.invalidLink) {
      try store.saveSignature(
        MailSignature(
          id: "unsafe",
          name: "Unsafe",
          document: SignatureDocument(text: "Open", link: "data:text/html,tracking")
        )
      )
    }
  }

  @Test
  func testLegacySingleSignaturePayloadMigratesIntoCollection() throws {
    let data = Data(
      #"""
      {"signature":{"id":"legacy","document":{"runs":[{"isBold":false,
      "isItalic":false,"isUnderlined":false,"text":"Regards"}]},"name":"Legacy"}}
      """#.utf8
    )

    let preferences = try JSONDecoder().decode(SignaturePreferences.self, from: data)

    #expect(preferences.signatures.map(\.id) == ["legacy"])
    #expect(preferences.signatures.first?.document.plainText == "Regards")
  }

  @Test
  func testOfflineEditsAndConnectionAssignmentsSynchronizeAfterReconnect() async throws {
    let localStateStore = InMemorySignatureStateStore()
    let syncService = InMemorySignaturePreferenceSyncService()
    syncService.loadError = URLError(.notConnectedToInternet)
    let store = makeStore(syncService: syncService, localStateStore: localStateStore)
    let work = signature(id: "work", name: "Work", body: "Regards")
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "mailbox"
      )
    )

    try store.saveSignature(work)
    store.setDefault(work.id, connectionId: connectionId, context: .newMessage)
    store.setDefault(work.id, connectionId: connectionId, context: .replyOrForward)
    await store.synchronize()

    #expect(store.hasPendingChanges)
    syncService.loadError = nil
    let restored = makeStore(syncService: syncService, localStateStore: localStateStore)
    await restored.synchronize()

    #expect(!restored.hasPendingChanges)
    #expect(
      syncService.snapshot?.preferences.signature(for: connectionId, context: .newMessage) == work
    )
    #expect(
      syncService.snapshot?.preferences.signature(
        for: connectionId,
        context: .replyOrForward
      ) == work
    )
  }

  @Test
  func testConcurrentSameSignatureEditsMaterializeConflictCopy() async throws {
    let syncService = InMemorySignaturePreferenceSyncService()
    let base = signature(id: "shared", name: "Work", body: "Regards")
    syncService.snapshot = SignaturePreferenceSyncSnapshot(
      preferences: SignaturePreferences(signatures: [base]),
      updatedAt: 1
    )
    let store = makeStore(syncService: syncService)
    await store.synchronize()
    try store.saveSignature(signature(id: base.id, name: base.name, body: "Local Regards"))
    syncService.snapshot = SignaturePreferenceSyncSnapshot(
      preferences: SignaturePreferences(
        signatures: [signature(id: base.id, name: base.name, body: "Remote Regards")]
      ),
      updatedAt: 2
    )

    await store.synchronize()

    let signatures = store.preferences.signatures
    #expect(signatures.count == 2)
    #expect(signatures.first { $0.id == base.id }?.document.plainText == "Remote Regards")
    let conflictCopy = signatures.first { $0.conflictSourceId == base.id }
    #expect(conflictCopy?.name == "Work (Conflict)")
    #expect(conflictCopy?.document.plainText == "Local Regards")
    #expect(syncService.snapshot?.preferences.signatures == signatures)
  }

  @Test
  func testComposerPlacesSelectedSignatureAboveQuotedText() {
    let message = MailboxMessageMetadata(
      categoryId: nil,
      connectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .gmail,
          value: "mailbox"
        )
      ),
      from: "sender@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: 100,
      providerMessageId: "message",
      providerStateIds: ["INBOX"],
      providerThreadId: "thread",
      recipientHeaders: nil,
      replyTo: "sender@example.com",
      rfcMessageId: "<message@example.com>",
      snippet: "Earlier message",
      subject: "Subject"
    )
    var draft = MailShellCompositionDraft.reply(to: message, quotedText: "Earlier message")
    draft.body = "Reply"
    draft.signature = signature(id: "work", name: "Work", body: "Regards")

    #expect(draft.deliveryBody == "Reply\n\n-- \nRegards\n\n> Earlier message")
  }

  @Test
  func testServiceEncryptsSignatureContentBeforeProductSyncWrite() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingSignaturePreferenceTransport()
    let service = SignatureSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore,
        transport: transport
      )
    )
    let preferences = SignaturePreferences(
      signatures: [signature(id: "private", name: "Private", body: "Secret signature")]
    )

    _ = try await service.savePreferences(
      preferences,
      expectedUpdatedAt: nil,
      session: session
    )

    let payload = try #require(transport.payload)
    let ciphertext = try #require(Data(base64Encoded: payload.encryptedPayload.ciphertextBase64))
    #expect(!ciphertext.contains(Data("Secret signature".utf8)))
    #expect(payload.payloadIdentifier == SignaturePreferences.primaryIdentifier)
  }

  private func makeStore(
    syncService: InMemorySignaturePreferenceSyncService =
      InMemorySignaturePreferenceSyncService(),
    localStateStore: InMemorySignatureStateStore =
      InMemorySignatureStateStore()
  ) -> SignatureStore {
    SignatureStore(
      session: session,
      syncService: syncService,
      localStateStore: localStateStore,
      automaticallySynchronizes: false
    )
  }

  private func makeStore(conflict: SignaturePreferenceConflict) throws -> SignatureStore {
    let localStateStore = InMemorySignatureStateStore()
    try localStateStore.save(
      SignaturePreferenceLocalState(
        conflicts: [conflict.field: conflict],
        pendingChanges: [:],
        preferences: .empty
      ),
      productAccountId: session.productAccountId
    )
    return makeStore(localStateStore: localStateStore)
  }

  private func connectionId(_ value: String) -> MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: value
      )
    )
  }

  private func signature(id: String, name: String, body: String) -> MailSignature {
    MailSignature(id: id, name: name, document: SignatureDocument(text: body))
  }
}

extension SignatureSyncServiceTests {
  @Test
  func testResolveConflictKeepsOnlyDifferingLocalValuesPending() throws {
    let field = SignaturePreferenceField.newMessage("connection")
    let localValue = SignaturePreferenceValue.identifier("local")
    let remoteValue = SignaturePreferenceValue.identifier("remote")
    let differingStore = try makeStore(
      conflict: SignaturePreferenceConflict(
        field: field,
        localValue: localValue,
        remoteValue: remoteValue
      )
    )

    differingStore.resolveConflict(field, useLocalValue: true)

    #expect(differingStore.preferences.value(for: field) == localValue)
    #expect(differingStore.hasPendingChanges)

    let matchingStore = try makeStore(
      conflict: SignaturePreferenceConflict(
        field: field,
        localValue: localValue,
        remoteValue: localValue
      )
    )

    matchingStore.resolveConflict(field, useLocalValue: true)

    #expect(matchingStore.preferences.value(for: field) == localValue)
    #expect(!matchingStore.hasPendingChanges)
  }

  @Test
  func testResolveConflictCanSelectSyncedValue() throws {
    let field = SignaturePreferenceField.replyOrForward("connection")
    let remoteValue = SignaturePreferenceValue.identifier("remote")
    let store = try makeStore(
      conflict: SignaturePreferenceConflict(
        field: field,
        localValue: .identifier("local"),
        remoteValue: remoteValue
      )
    )

    store.resolveConflict(field, useLocalValue: false)

    #expect(store.preferences.value(for: field) == remoteValue)
    #expect(!store.hasPendingChanges)
  }

  @Test
  func testDeleteSignatureClearsEveryReferencingAssignment() throws {
    let store = makeStore()
    let deleted = signature(id: "deleted", name: "Deleted", body: "Delete me")
    let retained = signature(id: "retained", name: "Retained", body: "Keep me")
    let firstConnection = connectionId("first")
    let secondConnection = connectionId("second")
    try store.saveSignature(deleted)
    try store.saveSignature(retained)
    store.setDefault(deleted.id, connectionId: firstConnection, context: .newMessage)
    store.setDefault(deleted.id, connectionId: firstConnection, context: .replyOrForward)
    store.setDefault(deleted.id, connectionId: secondConnection, context: .newMessage)
    store.setDefault(retained.id, connectionId: secondConnection, context: .replyOrForward)

    store.deleteSignature(deleted.id)

    #expect(store.preferences.signatures == [retained])
    #expect(
      store.preferences.assignments[firstConnection.rawValue]?.newMessageSignatureId == nil
    )
    #expect(
      store.preferences.assignments[firstConnection.rawValue]?.replyOrForwardSignatureId == nil
    )
    #expect(
      store.preferences.assignments[secondConnection.rawValue]?.newMessageSignatureId == nil
    )
    #expect(
      store.preferences.assignments[secondConnection.rawValue]?.replyOrForwardSignatureId
        == retained.id
    )
  }

  @Test
  func testInMemorySyncServiceRejectsInvalidPreferences() async {
    let syncService = InMemorySignaturePreferenceSyncService()
    let invalid = SignaturePreferences(
      signatures: [
        signature(id: "first", name: "Duplicate", body: "First"),
        signature(id: "second", name: " duplicate ", body: "Second"),
      ]
    )

    await #expect(throws: SignatureSyncError.duplicateName) {
      _ = try await syncService.savePreferences(
        invalid,
        expectedUpdatedAt: nil,
        session: session
      )
    }
  }
}

private final class InMemorySignatureStateStore:
  SignaturePreferenceLocalStatePersisting
{
  private var states: [String: SignaturePreferenceLocalState] = [:]

  func clear(productAccountId: String) throws {
    states[productAccountId] = nil
  }

  func load(productAccountId: String) throws -> SignaturePreferenceLocalState? {
    states[productAccountId]
  }

  func save(_ state: SignaturePreferenceLocalState, productAccountId: String) throws {
    states[productAccountId] = state
  }
}

private final class InMemorySignaturePreferenceSyncService: SignaturePreferenceSyncing {
  var loadError: Error?
  var snapshot: SignaturePreferenceSyncSnapshot?

  func loadPreferences(
    session _: ProductAccountSessionSnapshot
  ) async throws -> SignaturePreferenceSyncSnapshot? {
    if let loadError { throw loadError }
    return snapshot
  }

  func savePreferences(
    _ preferences: SignaturePreferences,
    expectedUpdatedAt: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> SignaturePreferenceConditionalSaveResult {
    let validatedPreferences = try preferences.validated()
    guard snapshot?.updatedAt == expectedUpdatedAt else {
      return .conflict(
        snapshot ?? SignaturePreferenceSyncSnapshot(preferences: .empty, updatedAt: nil)
      )
    }
    let committed = SignaturePreferenceSyncSnapshot(
      preferences: validatedPreferences,
      updatedAt: (snapshot?.updatedAt ?? 0) + 1
    )
    snapshot = committed
    return .committed(committed)
  }
}

private final class RecordingSignaturePreferenceTransport: ProductSyncRecordTransport {
  private(set) var payload: EncryptedProductSyncPayload?

  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor _: String?,
    limit _: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    let page =
      payload.map { $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) ? [$0] : [] } ?? []
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
