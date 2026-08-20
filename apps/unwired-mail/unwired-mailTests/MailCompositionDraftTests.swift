import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
@MainActor
@Suite(.serialized)
final class MailCompositionDraftTests {
  private let connectionId = MailboxConnectionId(
    providerMailboxIdentity: StableProviderMailboxIdentity(
      providerId: .gmail,
      value: "sender@example.com"
    )
  )

  @Test
  func encryptedStoreRoundTripsDraftsWithoutExposingMessageContent() throws {
    let rootDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let keyMaterialStore = try keyedStore(productAccountId: "account")
    let store = FileMailCompositionDraftStore(
      keyMaterialStore: keyMaterialStore,
      rootDirectory: rootDirectory
    )
    let profileId = MailProfileId(rawValue: "profile-a")
    let draft = MailShellCompositionDraft(
      body: "Private body fixture",
      connectionId: connectionId,
      recipient: "Recipient <recipient@example.com>",
      replyToMessage: nil,
      sourceMessage: nil,
      subject: "Private subject fixture"
    )

    try store.save(draft, productAccountId: "account", profileId: profileId)

    #expect(
      try store.load(productAccountId: "account", profileId: profileId) == [draft]
    )
    #expect(
      try store.load(
        productAccountId: "account",
        profileId: MailProfileId(rawValue: "profile-b")
      ).isEmpty
    )
    let encryptedFile = try #require(
      FileManager.default.enumerator(at: rootDirectory, includingPropertiesForKeys: nil)?
        .allObjects.compactMap { $0 as? URL }
        .first { $0.pathExtension == "json" }
    )
    let encryptedData = try Data(contentsOf: encryptedFile)
    #expect(encryptedData.range(of: Data("Private body fixture".utf8)) == nil)
    #expect(encryptedData.range(of: Data("Private subject fixture".utf8)) == nil)
    #expect(encryptedData.range(of: Data("recipient@example.com".utf8)) == nil)
  }

  @Test
  func storeUpdatesAndRemovesOnlyTheSelectedDraft() throws {
    let rootDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let store = FileMailCompositionDraftStore(
      keyMaterialStore: try keyedStore(productAccountId: "account"),
      rootDirectory: rootDirectory
    )
    let profileId = MailProfileId(rawValue: "profile")
    var first = draft(recipient: "first@example.com")
    let second = draft(recipient: "second@example.com")

    try store.save(first, productAccountId: "account", profileId: profileId)
    try store.save(second, productAccountId: "account", profileId: profileId)
    first.document = SemanticMessageDocument(plainText: "Updated")
    try store.save(first, productAccountId: "account", profileId: profileId)
    try store.remove(first.id, productAccountId: "account", profileId: profileId)

    #expect(
      try store.load(productAccountId: "account", profileId: profileId) == [second]
    )
  }

  @Test
  func storeRecoversUnreadableFilesWhileRetainingQuarantineOutsideTheStorageLimit() throws {
    let rootDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let store = FileMailCompositionDraftStore(
      keyMaterialStore: try keyedStore(productAccountId: "account"),
      rootDirectory: rootDirectory,
      storageLimit: 1_000_000
    )
    let profileId = MailProfileId(rawValue: "profile")
    let first = draft(recipient: "first@example.com")
    let second = draft(recipient: "second@example.com")

    try store.save(first, productAccountId: "account", profileId: profileId)
    let currentFile = try #require(
      draftFiles(in: rootDirectory).first { $0.pathExtension == "json" })
    try Data(repeating: 0, count: 999_500).write(to: currentFile)
    #expect(throws: DecodingError.self) {
      try store.load(productAccountId: "account", profileId: profileId)
    }

    try store.save(second, productAccountId: "account", profileId: profileId)
    #expect(try store.load(productAccountId: "account", profileId: profileId) == [second])
    let replacementFile = try #require(
      draftFiles(in: rootDirectory).first { $0.pathExtension == "json" })
    try Data(repeating: 0, count: 999_500).write(to: replacementFile)
    try store.remove(second.id, productAccountId: "account", profileId: profileId)

    #expect(try store.load(productAccountId: "account", profileId: profileId).isEmpty)
    #expect(
      draftFiles(in: rootDirectory)
        .filter { $0.lastPathComponent.contains(".unreadable-") }.count == 2
    )
  }

  @Test
  func storeRejectsDraftsAboveTheConfiguredStorageLimit() throws {
    let rootDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let store = FileMailCompositionDraftStore(
      keyMaterialStore: try keyedStore(productAccountId: "account"),
      rootDirectory: rootDirectory,
      storageLimit: 1
    )

    #expect(throws: MailCompositionDraftStoreError.storageLimitExceeded) {
      try store.save(
        draft(recipient: "recipient@example.com"),
        productAccountId: "account",
        profileId: MailProfileId(rawValue: "profile")
      )
    }
  }

  @Test
  func separateStoreInstancesSerializeConcurrentDraftUpdates() async throws {
    let rootDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let keyMaterialStore = try keyedStore(productAccountId: "account")
    let stores = (0..<2).map { _ in
      FileMailCompositionDraftStore(
        keyMaterialStore: keyMaterialStore,
        rootDirectory: rootDirectory
      )
    }
    let profileId = MailProfileId(rawValue: "profile")
    let drafts = (0..<24).map { draft(recipient: "recipient-\($0)@example.com") }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for (index, draft) in drafts.enumerated() {
        let store = stores[index % stores.count]
        group.addTask {
          try store.save(draft, productAccountId: "account", profileId: profileId)
        }
      }
      try await group.waitForAll()
    }

    #expect(
      Set(try stores[0].load(productAccountId: "account", profileId: profileId).map(\.id))
        == Set(drafts.map(\.id))
    )
  }

  @Test
  func inactiveProfileDraftRefreshDoesNotInvalidateActiveLoad() throws {
    let inactiveProfileId = MailProfileId(rawValue: "profile-a")
    let activeProfileId = MailProfileId(rawValue: "profile-b")
    var gate = MailCompositionDraftLoadGate()
    let activeLoad = gate.begin(profileId: activeProfileId, activeProfileId: activeProfileId)
    let activeLoadGeneration = try #require(activeLoad).generation

    let inactiveLoad = gate.begin(
      profileId: inactiveProfileId,
      activeProfileId: activeProfileId
    )
    #expect(inactiveLoad?.generation == nil)
    #expect(gate.generation == activeLoadGeneration)
  }

  @Test
  func draftLoadGateMarksProfileTransitionsForImmediateClearing() throws {
    let firstProfileId = MailProfileId(rawValue: "profile-a")
    let secondProfileId = MailProfileId(rawValue: "profile-b")
    var gate = MailCompositionDraftLoadGate()

    let firstLoadCandidate = gate.begin(
      profileId: firstProfileId,
      activeProfileId: firstProfileId
    )
    let firstLoad = try #require(firstLoadCandidate)
    let refreshCandidate = gate.begin(
      profileId: firstProfileId,
      activeProfileId: firstProfileId
    )
    let refresh = try #require(refreshCandidate)
    let switchedLoadCandidate = gate.begin(
      profileId: secondProfileId,
      activeProfileId: secondProfileId
    )
    let switchedLoad = try #require(switchedLoadCandidate)

    #expect(firstLoad.clearsExistingDrafts)
    #expect(refresh.clearsExistingDrafts == false)
    #expect(switchedLoad.clearsExistingDrafts)
  }

  @Test
  func viewModelFlushesLatestEditAndDeletesOnlyAfterOutboxAdmission() async {
    var savedDrafts: [MailShellCompositionDraft] = []
    var deletedDraftIds: [UUID] = []
    var admittedDrafts: [MailShellCompositionDraft] = []
    var initialDraft = draft(recipient: "recipient@example.com")
    initialDraft.subject = "Subject"
    let viewModel = MailComposerViewModel(
      draft: initialDraft,
      presentation: .partial,
      saveDraft: { savedDrafts.append($0) },
      deleteDraft: { deletedDraftIds.append($0) },
      sendDraft: {
        admittedDrafts.append($0)
        return true
      }
    )

    viewModel.draft.document = SemanticMessageDocument(plainText: "First edit")
    viewModel.draftChanged()
    viewModel.draft.document = SemanticMessageDocument(plainText: "Latest edit")
    viewModel.draftChanged()

    #expect(await viewModel.send() == .sent)
    #expect(savedDrafts.last?.body == "Latest edit")
    #expect(admittedDrafts.last?.body == "Latest edit")
    #expect(deletedDraftIds == [initialDraft.id])
    #expect(viewModel.saveState == .saved)
  }

  @Test
  func viewModelWaitsForCancelledAutosaveBeforeFlushingLatestDraft() async {
    let saver = ControlledDraftSaver()
    var initialDraft = draft(recipient: "recipient@example.com")
    initialDraft.document = SemanticMessageDocument(plainText: "First edit")
    let viewModel = MailComposerViewModel(
      draft: initialDraft,
      presentation: .partial,
      saveDraft: { await saver.save($0) },
      sendDraft: { _ in true }
    )

    viewModel.draftChanged()
    await saver.waitForFirstSave()
    viewModel.draft.document = SemanticMessageDocument(plainText: "Latest edit")
    viewModel.draftChanged()
    let closeTask = Task { await viewModel.close() }
    await saver.waitForFirstSaveCancellation()

    #expect(saver.startedBodies == ["First edit"])
    saver.releaseFirstSave()
    #expect(await closeTask.value)
    #expect(saver.completedBodies == ["First edit", "Latest edit"])
  }

  @Test
  func emptyDraftDoesNotAutosaveAndCloseRemovesAnyStoredCopy() async {
    var savedDrafts: [MailShellCompositionDraft] = []
    var deletedDraftIds: [UUID] = []
    let initialDraft = MailShellCompositionDraft.new(defaultSendingConnectionId: connectionId)
    let viewModel = MailComposerViewModel(
      draft: initialDraft,
      presentation: .partial,
      saveDraft: { savedDrafts.append($0) },
      deleteDraft: { deletedDraftIds.append($0) },
      sendDraft: { _ in true }
    )

    viewModel.draftChanged()
    #expect(viewModel.saveState == .idle)
    #expect(await viewModel.close())
    #expect(savedDrafts.isEmpty)
    #expect(deletedDraftIds == [initialDraft.id])
  }

  @Test
  func admittedSendRemainsSentWhenDraftCleanupFails() async {
    var deleteAttempts = 0
    var initialDraft = draft(recipient: "recipient@example.com")
    initialDraft.subject = "Subject"
    let viewModel = MailComposerViewModel(
      draft: initialDraft,
      presentation: .partial,
      deleteDraft: { _ in
        deleteAttempts += 1
        throw DraftFixtureError.deleteFailed
      },
      sendDraft: { _ in true }
    )

    #expect(await viewModel.send() == .sent)
    #expect(deleteAttempts == 2)
    guard case .failed = viewModel.saveState else {
      Issue.record("Expected the Draft cleanup failure to remain recorded")
      return
    }
  }

  @Test
  func failedDraftSaveBlocksCloseAndCanBeRetried() async {
    var shouldFail = true
    var draft = draft(recipient: "recipient@example.com")
    draft.subject = "Subject"
    let viewModel = MailComposerViewModel(
      draft: draft,
      presentation: .partial,
      saveDraft: { _ in
        if shouldFail { throw DraftFixtureError.saveFailed }
      },
      sendDraft: { _ in true }
    )

    viewModel.draft.document = SemanticMessageDocument(plainText: "Edited")
    viewModel.draftChanged()
    #expect(!(await viewModel.close()))
    guard case .failed = viewModel.saveState else {
      Issue.record("Expected the failed save to remain visible")
      return
    }

    shouldFail = false
    #expect(await viewModel.close())
    #expect(viewModel.saveState == .saved)
  }

  @Test
  func missingSubjectConfirmsOnceAndInvalidRecipientsNeverSend() async {
    var sendCount = 0
    let viewModel = MailComposerViewModel(
      draft: draft(recipient: "recipient@example.com"),
      presentation: .partial,
      sendDraft: { _ in
        sendCount += 1
        return true
      }
    )

    #expect(await viewModel.send() == .needsSubjectConfirmation)
    #expect(await viewModel.sendWithoutSubject() == .sent)
    #expect(sendCount == 1)

    var invalidDraft = draft(recipient: "not an address")
    invalidDraft.subject = "Subject"
    let invalidViewModel = MailComposerViewModel(
      draft: invalidDraft,
      presentation: .partial,
      sendDraft: { _ in
        sendCount += 1
        return true
      }
    )
    #expect(await invalidViewModel.send() == .notSent)
    #expect(sendCount == 1)
  }

  @Test
  func recipientValidationCoversToCcAndBcc() {
    var draft = draft(recipient: "Recipient <recipient@example.com>")
    draft.ccRecipients = "copy@example.com"
    draft.bccRecipients = "Hidden <hidden@example.com>"

    #expect(draft.recipientsAreValid)
    #expect(
      draft.deliveryRecipientHeader
        == "Recipient <recipient@example.com>, copy@example.com, Hidden <hidden@example.com>"
    )

    draft.bccRecipients = "unfinished@"
    #expect(!(draft.recipientsAreValid))
  }

  @Test(.bug(id: 162))
  func deliveryDocumentCombinesSignatureAndQuotedTextWithoutEmptyLeadingBlock() {
    var emptyDraft = draft(recipient: "recipient@example.com")
    emptyDraft.signature = MailSignature(
      name: "Default",
      document: SignatureDocument(text: "Sender")
    )

    #expect(emptyDraft.deliveryDocument.plainText == "-- \nSender")

    let reply = MailShellCompositionDraft(
      body: "Reply",
      connectionId: connectionId,
      recipient: "recipient@example.com",
      replyToMessage: nil,
      sourceMessage: nil,
      subject: "Subject",
      quotedText: "Earlier\nmessage",
      signature: MailSignature(
        name: "Default",
        document: SignatureDocument(text: "Sender")
      )
    )

    #expect(reply.deliveryDocument.plainText == "Reply\n\n-- \nSender\n\n> Earlier\n> message")
    #expect(reply.deliveryDocument.blocks.suffix(2).allSatisfy { $0.kind == .blockquote })
  }

  @Test
  func recipientSuggestionsPreferLocalRecentsAndDeduplicateProviderResults() async {
    let recent = message(
      from: "sender@example.com",
      providerMessageId: "sent",
      providerStateIds: ["SENT"],
      recipientHeaders: ["Alice Fixture <alice161fixture@example.com>"],
      receivedAt: 200
    )
    let correspondent = message(
      from: "Alice Fixture <alice161fixture@example.com>",
      providerMessageId: "received",
      providerStateIds: ["INBOX"],
      recipientHeaders: ["sender@example.com"],
      receivedAt: 100
    )
    let provider = FixtureProviderDirectory(
      values: [
        MailRecipientSuggestion(
          displayName: "Provider Duplicate",
          emailAddress: "alice161fixture@example.com",
          source: .providerDirectory
        ),
        MailRecipientSuggestion(
          displayName: "Provider Result",
          emailAddress: "alice161fixture-directory@example.com",
          source: .providerDirectory
        ),
      ]
    )
    let service = MailRecipientSuggestionService(providerDirectory: provider)

    let suggestions = await service.suggestions(
      matching: "alice161fixture",
      messages: [correspondent, recent]
    )

    #expect(suggestions.first?.emailAddress == "alice161fixture@example.com")
    #expect(suggestions.first?.source == .recent)
    #expect(suggestions.map(\.emailAddress).count == Set(suggestions.map(\.emailAddress)).count)
    #expect(suggestions.contains { $0.source == .providerDirectory })
  }

  @Test
  func recipientSuggestionEscapesQuotedNamesAndProducesACompleteMailboxList() {
    let suggestion = MailRecipientSuggestion(
      displayName: #"Path\Name "Alias""#,
      emailAddress: "alias@example.com",
      source: .contact
    )

    #expect(suggestion.headerValue == #""Path\\Name \"Alias\"" <alias@example.com>"#)
    let value = MailRecipientText.applying(suggestion, to: "first@example.com, ali")
    #expect(value == #"first@example.com, "Path\\Name \"Alias\"" <alias@example.com>"#)
    #expect(RFCMailboxHeaderParser.mailboxes(in: value) != nil)
  }

  @Test
  func explicitReadReceiptChoiceSurvivesSenderPolicyChanges() {
    var draft = draft(recipient: "recipient@example.com")

    draft.recordReadReceiptChoice(false)
    draft.applyInitialReadReceiptPolicy(.requestByDefault)

    #expect(draft.hasExplicitReadReceiptChoice)
    #expect(!(draft.requestsReadReceipt))
  }

  private func draft(recipient: String) -> MailShellCompositionDraft {
    MailShellCompositionDraft(
      body: "",
      connectionId: connectionId,
      recipient: recipient,
      replyToMessage: nil,
      sourceMessage: nil,
      subject: ""
    )
  }

  private func keyedStore(
    productAccountId: String
  ) throws -> InMemoryProductSyncKeyMaterialStore {
    let store = InMemoryProductSyncKeyMaterialStore()
    _ = try store.ensureMaterial(productAccountId: productAccountId, allowCreation: true)
    return store
  }

  private func message(
    from: String,
    providerMessageId: String,
    providerStateIds: [String],
    recipientHeaders: [String],
    receivedAt: Int64
  ) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: nil,
      connectionId: connectionId,
      from: from,
      isHistorical: false,
      providerInternalDateMilliseconds: receivedAt,
      providerMessageId: providerMessageId,
      providerStateIds: providerStateIds,
      providerThreadId: "thread-\(providerMessageId)",
      recipientHeaders: recipientHeaders,
      replyTo: nil,
      rfcMessageId: "<\(providerMessageId)@example.com>",
      snippet: "Message",
      subject: "Subject"
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "MailCompositionDraftTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }

  private func draftFiles(in rootDirectory: URL) -> [URL] {
    FileManager.default.enumerator(at: rootDirectory, includingPropertiesForKeys: nil)?
      .allObjects.compactMap { $0 as? URL } ?? []
  }
}

@MainActor
private final class ControlledDraftSaver {
  private(set) var completedBodies: [String] = []
  private(set) var startedBodies: [String] = []
  private let firstSaveCancellationContinuation: AsyncStream<Void>.Continuation
  private let firstSaveCancellationStream: AsyncStream<Void>
  private var firstSaveContinuation: CheckedContinuation<Void, Never>?

  init() {
    let stream = AsyncStream<Void>.makeStream()
    firstSaveCancellationStream = stream.stream
    firstSaveCancellationContinuation = stream.continuation
  }

  func save(_ draft: MailShellCompositionDraft) async {
    startedBodies.append(draft.body)
    if startedBodies.count == 1 {
      let cancellationContinuation = firstSaveCancellationContinuation
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          firstSaveContinuation = continuation
        }
      } onCancel: {
        cancellationContinuation.yield(())
      }
    }
    completedBodies.append(draft.body)
  }

  func waitForFirstSave() async {
    while startedBodies.isEmpty {
      await Task.yield()
    }
  }

  func waitForFirstSaveCancellation() async {
    for await _ in firstSaveCancellationStream {
      return
    }
  }

  func releaseFirstSave() {
    firstSaveContinuation?.resume()
    firstSaveContinuation = nil
  }
}

private enum DraftFixtureError: Error {
  case deleteFailed
  case saveFailed
}

private struct FixtureProviderDirectory: MailProviderDirectorySearching {
  let values: [MailRecipientSuggestion]

  func suggestions(matching query: String) async -> [MailRecipientSuggestion] {
    values.filter {
      $0.emailAddress.localizedCaseInsensitiveContains(query)
        || $0.displayName?.localizedCaseInsensitiveContains(query) == true
    }
  }
}
