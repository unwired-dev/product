import Foundation
import Testing

@testable import unwired_mail

@MainActor
struct TemplateSyncServiceTests {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user",
    identityToken: "identity-token",
    productAccountId: "product-account",
    trustedDeviceId: "trusted-device"
  )

  @Test
  func legacyPlainTextTemplateMigratesToSemanticDocument() throws {
    let data = Data(
      #"{"id":"legacy","name":"Welcome","subject":"Hello","body":"First\nSecond"}"#.utf8
    )

    let template = try JSONDecoder().decode(MailTemplate.self, from: data)

    #expect(template.document.plainText == "First\nSecond")
    #expect(template.document.schemaVersion == SemanticMessageDocument.supportedSchemaVersion)
  }

  @Test
  func collectionRejectsDuplicateNamesAndFutureSchemaVersions() throws {
    let first = template(id: "first", name: "Welcome", body: "First")
    let second = template(id: "second", name: " welcome ", body: "Second")

    #expect(throws: TemplateSyncError.duplicateName) {
      try TemplatePreferences(templates: [first, second]).validated()
    }
    #expect(throws: TemplateSyncError.unsupportedVersion) {
      try JSONDecoder().decode(
        TemplatePreferences.self,
        from: Data(#"{"schemaVersion":2,"templates":[]}"#.utf8)
      )
    }
  }

  @Test
  func offlineEditsRestoreAndSynchronizeWithinTheirProfile() async throws {
    let localStateStore = InMemoryTemplateStateStore()
    let scope = MailProfileRecordScope.profile(MailProfileId(rawValue: "work"))
    let sharedSyncStorage = InMemoryTemplatePreferenceSyncStorage()
    let syncService = InMemoryTemplatePreferenceSyncService(
      scope: scope,
      storage: sharedSyncStorage
    )
    syncService.loadError = URLError(.notConnectedToInternet)
    let store = makeStore(
      scope: scope,
      syncService: syncService,
      localStateStore: localStateStore
    )
    try store.saveTemplate(template(id: "welcome", name: "Welcome", body: "Hello"))
    await store.synchronize()

    #expect(store.hasPendingChanges)
    syncService.loadError = nil
    let restored = makeStore(
      scope: scope,
      syncService: syncService,
      localStateStore: localStateStore
    )
    let otherProfileScope = MailProfileRecordScope.profile(MailProfileId(rawValue: "personal"))
    let otherProfile = makeStore(
      scope: otherProfileScope,
      syncService: InMemoryTemplatePreferenceSyncService(
        scope: otherProfileScope,
        storage: sharedSyncStorage
      ),
      localStateStore: localStateStore
    )
    await restored.synchronize()
    await otherProfile.synchronize()

    #expect(!restored.hasPendingChanges)
    #expect(restored.preferences.templates.map(\.id) == ["welcome"])
    #expect(otherProfile.preferences == .empty)
  }

  @Test
  func concurrentEditsMaterializeLocalConflictCopy() async throws {
    let syncService = InMemoryTemplatePreferenceSyncService()
    let base = template(id: "shared", name: "Welcome", body: "Original")
    syncService.snapshot = TemplatePreferenceSyncSnapshot(
      preferences: TemplatePreferences(templates: [base]),
      updatedAt: 1
    )
    let store = makeStore(syncService: syncService)
    await store.synchronize()
    try store.saveTemplate(template(id: base.id, name: base.name, body: "Local"))
    syncService.snapshot = TemplatePreferenceSyncSnapshot(
      preferences: TemplatePreferences(
        templates: [template(id: base.id, name: base.name, body: "Remote")]
      ),
      updatedAt: 2
    )

    await store.synchronize()

    #expect(store.preferences.templates.count == 2)
    #expect(store.preferences.template(id: base.id)?.document.plainText == "Remote")
    let copy = store.preferences.templates.first { $0.conflictSourceId == base.id }
    #expect(copy?.name == "Welcome (Conflict)")
    #expect(copy?.document.plainText == "Local")
    #expect(syncService.snapshot?.preferences == store.preferences)
  }

  @Test
  func serviceEncryptsProfileScopedTemplatePayload() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingTemplateTransport()
    let scope = MailProfileRecordScope.profile(MailProfileId(rawValue: "work"))
    let service = TemplateSyncService(
      recordScope: scope,
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore,
        transport: transport
      )
    )

    _ = try await service.savePreferences(
      TemplatePreferences(
        templates: [template(id: "private", name: "Private", body: "Secret body")]
      ),
      expectedUpdatedAt: nil,
      session: session
    )

    let payload = try #require(transport.payload)
    let ciphertext = try #require(Data(base64Encoded: payload.encryptedPayload.ciphertextBase64))
    #expect(!ciphertext.contains(Data("Secret body".utf8)))
    #expect(
      payload.payloadIdentifier
        == scope.productSyncIdentifier(TemplatePreferences.primaryIdentifier)
    )
  }

  @Test
  func newDraftUsesTemplateWithoutChangingSendingIdentity() {
    let identityId = SendingIdentityId(rawValue: "identity")
    let document = SemanticMessageDocument(
      blocks: [
        .init(kind: .heading(level: 2), runs: [.init("Welcome", isBold: true)]),
        .init(kind: .bulletedListItem, runs: [.init("First")]),
      ]
    )
    let template = MailTemplate(
      id: "welcome",
      name: "Welcome",
      subject: "Hello",
      document: document
    )

    let draft = MailShellCompositionDraft.new(
      defaultSendingConnectionId: nil,
      defaultSendingIdentityId: identityId,
      template: template
    )

    #expect(draft.subject == "Hello")
    #expect(draft.document == document)
    #expect(draft.sendingIdentityId == identityId)
    #expect(draft.recipient.isEmpty)
  }

  @Test
  func insertingTemplatePreservesExistingSubjectAndSemanticFormatting() {
    let document = SemanticMessageDocument(
      blocks: [.init(kind: .blockquote, runs: [.init("Quoted", isItalic: true)])]
    )
    let template = MailTemplate(
      id: "reply",
      name: "Reply",
      subject: "Template subject",
      document: document
    )
    var draft = MailShellCompositionDraft(
      body: "Existing",
      connectionId: nil,
      recipient: "",
      replyToMessage: nil,
      sourceMessage: nil,
      subject: "Authored subject"
    )
    let editor = SemanticMessageEditorModel(document: draft.document)

    draft.applyTemplateSubjectIfEmpty(template)
    editor.insertAtEnd(template.document)

    #expect(draft.subject == "Authored subject")
    #expect(editor.document.blocks.last?.kind == .blockquote)
    #expect(editor.document.blocks.last?.runs.first?.isItalic == true)
    #expect(editor.document.plainText == "Existing\n\n> Quoted")
  }

  @Test
  func insertingTemplateReusesTrailingEmptyParagraph() {
    let editor = SemanticMessageEditorModel(
      document: SemanticMessageDocument(
        blocks: [
          .init(runs: [.init("Existing")]),
          .init(runs: [.init("")]),
        ]
      )
    )

    editor.insertAtEnd(SemanticMessageDocument(plainText: "Template"))

    #expect(editor.document.plainText == "Existing\nTemplate")
  }

  @Test
  func insertingTemplatePreservesEmptyNonParagraphBlock() {
    let editor = SemanticMessageEditorModel(
      document: SemanticMessageDocument(
        blocks: [
          .init(runs: [.init("Existing")]),
          .init(kind: .heading(level: 2), runs: [.init("")]),
        ]
      )
    )

    editor.insertAtEnd(SemanticMessageDocument(plainText: "Template"))

    #expect(editor.document.plainText == "Existing\n\n\nTemplate")
    #expect(
      editor.document.html
        == "<!doctype html><html><body><p>Existing</p><h2></h2>"
          + "<p><br></p><p>Template</p></body></html>"
    )
  }

  private func makeStore(
    scope: MailProfileRecordScope = .legacyProductAccount,
    syncService: InMemoryTemplatePreferenceSyncService = InMemoryTemplatePreferenceSyncService(),
    localStateStore: InMemoryTemplateStateStore = InMemoryTemplateStateStore()
  ) -> TemplateStore {
    TemplateStore(
      session: session,
      recordScope: scope,
      syncService: syncService,
      localStateStore: localStateStore,
      automaticallySynchronizes: false
    )
  }

  private func template(id: String, name: String, body: String) -> MailTemplate {
    MailTemplate(
      id: id,
      name: name,
      subject: "Subject",
      document: SemanticMessageDocument(plainText: body)
    )
  }
}

private final class InMemoryTemplateStateStore: TemplatePreferenceLocalStatePersisting {
  private var states: [String: TemplatePreferenceLocalState] = [:]

  func clear(productAccountId: String) throws {
    states = states.filter { !$0.key.hasPrefix("\(productAccountId).") }
  }

  func load(
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws -> TemplatePreferenceLocalState? {
    states[key(productAccountId, recordScope)]
  }

  func save(
    _ state: TemplatePreferenceLocalState,
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws {
    states[key(productAccountId, recordScope)] = state
  }

  private func key(_ productAccountId: String, _ recordScope: MailProfileRecordScope) -> String {
    "\(productAccountId).\(recordScope.namespace ?? "legacy")"
  }
}

private final class InMemoryTemplatePreferenceSyncStorage {
  var snapshots: [String: TemplatePreferenceSyncSnapshot] = [:]
}

private final class InMemoryTemplatePreferenceSyncService: TemplatePreferenceSyncing {
  private let scope: MailProfileRecordScope
  private let storage: InMemoryTemplatePreferenceSyncStorage
  var loadError: Error?

  var snapshot: TemplatePreferenceSyncSnapshot? {
    get { storage.snapshots[key] }
    set { storage.snapshots[key] = newValue }
  }

  init(
    scope: MailProfileRecordScope = .legacyProductAccount,
    storage: InMemoryTemplatePreferenceSyncStorage = InMemoryTemplatePreferenceSyncStorage()
  ) {
    self.scope = scope
    self.storage = storage
  }

  func loadPreferences(
    session _: ProductAccountSessionSnapshot
  ) async throws -> TemplatePreferenceSyncSnapshot? {
    if let loadError { throw loadError }
    return snapshot
  }

  func savePreferences(
    _ preferences: TemplatePreferences,
    expectedUpdatedAt: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> TemplatePreferenceConditionalSaveResult {
    let preferences = try preferences.validated()
    guard snapshot?.updatedAt == expectedUpdatedAt else {
      return .conflict(
        snapshot ?? TemplatePreferenceSyncSnapshot(preferences: .empty, updatedAt: nil)
      )
    }
    let committed = TemplatePreferenceSyncSnapshot(
      preferences: preferences,
      updatedAt: (snapshot?.updatedAt ?? 0) + 1
    )
    snapshot = committed
    return .committed(committed)
  }

  private var key: String {
    scope.namespace ?? "legacy"
  }
}

private final class RecordingTemplateTransport: ProductSyncRecordTransport {
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
