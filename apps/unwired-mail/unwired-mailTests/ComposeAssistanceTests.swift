import Foundation
import SwiftUI
import Testing

@testable import unwired_mail

// swiftlint:disable file_length

@MainActor
// swiftlint:disable:next type_body_length
struct ComposeAssistanceTests {
  private let profileId = MailProfileId(rawValue: "profile")

  @Test(arguments: ComposeAssistancePreset.allCases)
  func everyPresetHasDistinctVisibleCopyAndPreservationInstructions(
    preset: ComposeAssistancePreset
  ) {
    #expect(!preset.title.isEmpty)
    #expect(!preset.instruction.isEmpty)
    #expect(preset.instruction.localizedCaseInsensitiveContains("fact"))
    #expect(ComposeAssistancePreset.allCases.map(\.title).count == 8)
    #expect(Set(ComposeAssistancePreset.allCases.map(\.title)).count == 8)
  }

  @Test
  func requestUsesOnlyAuthoredContentSelectionSubjectAndRecipientIdentities() throws {
    let document = SemanticMessageDocument(
      blocks: [
        .init(runs: [.init("Hello "), .init("Taylor", isBold: true), .init(".")])
      ]
    )
    let editor = SemanticMessageEditorModel(document: document)
    let lower = editor.attributedText.characters.index(
      editor.attributedText.startIndex,
      offsetBy: 6
    )
    let upper = editor.attributedText.characters.index(lower, offsetBy: 6)
    editor.selection = AttributedTextSelection(range: lower..<upper)
    let target = editor.composeAssistanceTarget()

    let request = try makeRequest(
      action: .transform(.professional),
      target: target,
      subject: "Planning",
      recipients: ["Taylor"]
    )

    #expect(target.scope == .selection)
    #expect(request.context.draft?.authoredBody == "Hello Taylor.")
    #expect(request.context.draft?.selectedText == "Taylor")
    #expect(request.context.draft?.formattedTarget == target.targetDocument)
    #expect(request.context.draft?.subject == "Planning")
    #expect(request.context.recipientDisplayNames == ["Taylor"])
    #expect(request.context.sourceMessages.isEmpty)
    #expect(request.context.understandingScope == nil)
    #expect(
      request.operation
        == .transform(instruction: ComposeAssistancePreset.professional.instruction)
    )
  }

  @Test
  func promptToDraftAndSubjectSuggestionRemainSeparateOperations() throws {
    let target = target(for: SemanticMessageDocument(plainText: "Existing body"))
    let body = try makeRequest(
      action: .generateBody(prompt: "Confirm Tuesday's appointment"),
      target: target
    )
    let subject = try makeRequest(action: .suggestSubject, target: target)

    #expect(body.operation == .compose(prompt: "Confirm Tuesday's appointment"))
    #expect(ComposeAssistanceAction.generateBody(prompt: "Body").application == .insert)
    #expect(subject.operation == .suggestSubject)
    #expect(ComposeAssistanceAction.suggestSubject.application == .replaceSubject)
  }

  @Test("Slash assistance actions stay explicit and context-bound", .bug(id: 564))
  func slashAssistanceActionsMapToExistingOperations() {
    let commands = SemanticMessageSlashCommand.AssistanceCommand.allCases

    #expect(
      commands == [
        .ask,
        .draftFromPrompt,
        .rewriteSelection,
        .proofread,
        .shorten,
        .changeTone,
        .suggestSubject,
      ]
    )
    #expect(
      commands.filter(\.requiresSelection)
        == [.rewriteSelection, .proofread, .shorten, .changeTone]
    )
    #expect(
      SemanticMessageSlashCommand.AssistanceCommand.ask.makeAction(
        instruction: "Keep the request clear",
        tone: .neutral
      ) == .refine(instruction: "Keep the request clear")
    )
    #expect(
      SemanticMessageSlashCommand.AssistanceCommand.draftFromPrompt.makeAction(
        instruction: "Confirm Tuesday",
        tone: .neutral
      ) == .generateBody(prompt: "Confirm Tuesday")
    )
    #expect(
      SemanticMessageSlashCommand.AssistanceCommand.shorten.makeAction(
        instruction: "",
        tone: .neutral
      ) == .transform(.shorten)
    )
    #expect(
      SemanticMessageSlashCommand.AssistanceCommand.rewriteSelection.makeAction(
        instruction: "Tighten this paragraph",
        tone: .neutral
      ) == .refine(instruction: "Tighten this paragraph")
    )
    #expect(
      SemanticMessageSlashCommand.AssistanceCommand.proofread.makeAction(
        instruction: "",
        tone: .neutral
      ) == .proofread
    )
    #expect(
      SemanticMessageSlashCommand.AssistanceCommand.changeTone.makeAction(
        instruction: "",
        tone: .friendly
      ) == .transform(.friendly)
    )
    #expect(
      SemanticMessageSlashCommand.AssistanceCommand.suggestSubject.makeAction(
        instruction: "",
        tone: .neutral
      ) == .suggestSubject
    )
  }

  @Test("Body targets ignore a selection and preserve the requested insertion", .bug(id: 564))
  func bodyTargetUsesFullAuthoredDocument() {
    let document = SemanticMessageDocument(plainText: "Alpha Beta")
    let editor = SemanticMessageEditorModel(document: document)
    let lower = editor.attributedText.characters.index(
      editor.attributedText.startIndex,
      offsetBy: 6
    )
    editor.selection = AttributedTextSelection(range: lower..<editor.attributedText.endIndex)

    let target = editor.composeAssistanceBodyTarget(insertionOffset: 3)

    #expect(target.scope == .authoredBody)
    #expect(target.range == nil)
    #expect(target.insertionOffset == 3)
    #expect(target.sourceDocument == document)
    #expect(target.targetDocument == document)
  }

  @Test("Compose Assistance insertion anchors follow preceding edits", .bug(id: 564))
  func composeAssistanceInsertionAnchorRebases() {
    #expect(
      SemanticMessageEditorModel.rebasedComposeAssistanceInsertionOffset(
        6,
        replacing: 1..<1,
        withCharacterCount: 3
      ) == 9
    )
    #expect(
      SemanticMessageEditorModel.rebasedComposeAssistanceInsertionOffset(
        6,
        replacing: 4..<8,
        withCharacterCount: 1
      ) == 5
    )
    #expect(
      SemanticMessageEditorModel.rebasedComposeAssistanceInsertionOffset(
        6,
        replacing: 8..<9,
        withCharacterCount: 2
      ) == 6
    )
  }

  @Test
  // swiftlint:disable:next function_body_length
  func inputVersionChangesWithDraftSubjectRecipientsAndSelection() {
    let original = SemanticMessageDocument(plainText: "Alpha Beta")
    let firstTarget = ComposeAssistanceTarget(
      insertionOffset: 0,
      range: 0..<5,
      scope: .selection,
      sourceDocument: original,
      targetDocument: SemanticMessageDocument(plainText: "Alpha")
    )
    let secondTarget = ComposeAssistanceTarget(
      insertionOffset: 6,
      range: 6..<10,
      scope: .selection,
      sourceDocument: original,
      targetDocument: SemanticMessageDocument(plainText: "Beta")
    )
    let baseline = ComposeAssistanceRequestBuilder.inputVersion(
      document: original,
      target: firstTarget,
      subject: "Subject",
      recipientDisplayNames: ["Taylor"]
    )

    #expect(
      baseline
        != ComposeAssistanceRequestBuilder.inputVersion(
          document: SemanticMessageDocument(plainText: "Alpha changed"),
          target: firstTarget,
          subject: "Subject",
          recipientDisplayNames: ["Taylor"]
        )
    )
    #expect(
      baseline
        != ComposeAssistanceRequestBuilder.inputVersion(
          document: original,
          target: firstTarget,
          subject: "Other subject",
          recipientDisplayNames: ["Taylor"]
        )
    )
    #expect(
      baseline
        != ComposeAssistanceRequestBuilder.inputVersion(
          document: original,
          target: firstTarget,
          subject: "Subject",
          recipientDisplayNames: ["Morgan"]
        )
    )
    #expect(
      baseline
        != ComposeAssistanceRequestBuilder.inputVersion(
          document: original,
          target: secondTarget,
          subject: "Subject",
          recipientDisplayNames: ["Taylor"]
        )
    )
  }

  @Test
  func refinementIsEphemeralAndRemainsBoundToTheOriginalInput() throws {
    let original = try makeRequest(
      action: .transform(.friendly),
      target: target(for: SemanticMessageDocument(plainText: "Original"))
    )
    let previewDocument = SemanticMessageDocument(plainText: "Current preview")
    let preview = MailAssistancePreview(
      content: previewDocument.plainText,
      inputVersion: original.context.inputVersion,
      kind: .content,
      profileId: profileId,
      semanticDocument: previewDocument
    )

    let refinement = try ComposeAssistanceRequestBuilder().makeRefinementRequest(
      instruction: "Make this warmer",
      preview: preview,
      originalRequest: original
    )

    #expect(refinement.context.inputVersion == original.context.inputVersion)
    #expect(refinement.context.sourceMessages.isEmpty)
    #expect(refinement.context.draft?.authoredBody == "Current preview")
    #expect(refinement.context.draft?.formattedTarget == previewDocument)
    guard case .refine(let instruction) = refinement.operation else {
      Issue.record("Expected a refinement operation")
      return
    }
    #expect(instruction == "Make this warmer")
  }

  @Test
  func subjectRefinementRetainsSubjectOperationAndOriginalBody() throws {
    let original = try makeRequest(
      action: .suggestSubject,
      target: target(for: SemanticMessageDocument(plainText: "Original")),
      subject: "Old subject"
    )
    let preview = MailAssistancePreview(
      content: "Suggested subject",
      inputVersion: original.context.inputVersion,
      kind: .content,
      profileId: profileId
    )

    let refinement = try ComposeAssistanceRequestBuilder().makeRefinementRequest(
      instruction: "Make it shorter",
      preview: preview,
      originalRequest: original
    )

    #expect(refinement.context.draft?.authoredBody == "Original")
    #expect(refinement.context.draft?.subject == "Suggested subject")
    guard case .refineSubject(let instruction) = refinement.operation else {
      Issue.record("Expected a subject refinement operation")
      return
    }
    #expect(instruction == "Make it shorter")
  }

  @Test
  func composeClarificationRetainsComposePromptAndAnswer() throws {
    let original = try makeRequest(
      action: .generateBody(prompt: "Draft a concise reply"),
      target: target(for: SemanticMessageDocument(plainText: "Original"))
    )
    let preview = MailAssistancePreview(
      content: "What deadline should I mention?",
      inputVersion: original.context.inputVersion,
      kind: .clarification,
      profileId: profileId
    )

    let refinement = try ComposeAssistanceRequestBuilder().makeRefinementRequest(
      instruction: "Mention Tuesday",
      preview: preview,
      originalRequest: original
    )

    #expect(refinement.context.draft == original.context.draft)
    guard case .compose(let prompt) = refinement.operation else {
      Issue.record("Expected the clarification to remain a compose operation")
      return
    }
    #expect(
      prompt == "Draft a concise reply\nClarification question: What deadline should I mention?\n"
        + "Answer: Mention Tuesday"
    )
  }

  @Test
  func subjectClarificationRetainsSubjectOperationAndOriginalDraft() throws {
    let original = try makeRequest(
      action: .suggestSubject,
      target: target(for: SemanticMessageDocument(plainText: "Original")),
      subject: "Old subject"
    )
    let preview = MailAssistancePreview(
      content: "What is the topic?",
      inputVersion: original.context.inputVersion,
      kind: .clarification,
      profileId: profileId
    )

    let refinement = try ComposeAssistanceRequestBuilder().makeRefinementRequest(
      instruction: "The launch",
      preview: preview,
      originalRequest: original
    )

    #expect(refinement.context.draft == original.context.draft)
    guard case .refineSubject(let instruction) = refinement.operation else {
      Issue.record("Expected the clarification to remain a subject refinement")
      return
    }
    #expect(instruction == "Clarification question: What is the topic?\nAnswer: The launch")
  }

  @Test
  func outputValidationPreservesFormattingAndHighRiskFacts() throws {
    let source = factualDocument(prefix: "I will pay")
    let request = try makeRequest(
      action: .transform(.direct),
      target: target(for: source)
    )
    let valid = factualDocument(prefix: "I will promptly pay")

    try ComposeAssistanceOutputValidator.validate(valid, for: request)

    #expect(throws: MailAssistanceError.guardrailViolation) {
      try ComposeAssistanceOutputValidator.validate(
        factualDocument(prefix: "I will promptly pay", amount: "$75"),
        for: request
      )
    }
    #expect(throws: MailAssistanceError.guardrailViolation) {
      try ComposeAssistanceOutputValidator.validate(
        factualDocument(prefix: "I will promptly pay", amount: "$500"),
        for: request
      )
    }
    #expect(throws: MailAssistanceError.guardrailViolation) {
      var changedFormatting = valid
      changedFormatting.blocks[0].runs[0].isBold = false
      try ComposeAssistanceOutputValidator.validate(changedFormatting, for: request)
    }
    #expect(throws: MailAssistanceError.guardrailViolation) {
      try ComposeAssistanceOutputValidator.validate(
        factualDocument(prefix: "Please pay", question: "."),
        for: request
      )
    }
  }

  @Test
  func replacingSelectionPreservesSurroundingFormattingAndCreatesOneUndoStep() {
    let original = SemanticMessageDocument(
      blocks: [
        .init(
          runs: [
            .init("Before ", isItalic: true),
            .init("selected", isBold: true),
            .init(" after", isUnderlined: true),
          ]
        )
      ]
    )
    let editor = SemanticMessageEditorModel(document: original)
    let lower = editor.attributedText.characters.index(
      editor.attributedText.startIndex,
      offsetBy: 7
    )
    let upper = editor.attributedText.characters.index(lower, offsetBy: 8)
    editor.selection = AttributedTextSelection(range: lower..<upper)
    let captured = editor.composeAssistanceTarget()
    let replacement = SemanticMessageDocument(
      blocks: [.init(runs: [.init("updated", isBold: true)])]
    )

    #expect(
      editor.applyAssistanceDocument(
        replacement,
        application: .replaceTarget,
        target: captured
      )
    )
    #expect(
      editor.document.blocks[0].runs == [
        .init("Before ", isItalic: true),
        .init("updated", isBold: true),
        .init(" after", isUnderlined: true),
      ]
    )
    editor.undo()
    #expect(editor.document == original)
    #expect(!editor.canUndo)
  }

  @Test
  func insertingCreatesOneUndoStepAndStaleReplacementIsRejected() {
    let original = SemanticMessageDocument(plainText: "Existing")
    let editor = SemanticMessageEditorModel(document: original)
    let insertion = editor.composeAssistanceTarget()

    #expect(
      editor.applyAssistanceDocument(
        SemanticMessageDocument(plainText: " addition"),
        application: .insert,
        target: insertion
      )
    )
    #expect(editor.document.plainText == "Existing addition")
    editor.undo()
    #expect(editor.document == original)
    #expect(!editor.canUndo)

    let staleTarget = editor.composeAssistanceTarget()
    editor.attributedText = AttributedString("Changed")
    editor.textDidChange()
    #expect(
      !editor.applyAssistanceDocument(
        SemanticMessageDocument(plainText: "Replacement"),
        application: .replaceTarget,
        target: staleTarget
      )
    )
    #expect(editor.document.plainText == "Changed")
  }

  @Test
  func acceptingAuthoredBodyLeavesEnvelopeSignatureQuoteAndAttachmentsUnchanged() {
    let asset = MailDraftAsset(
      data: Data("attachment".utf8),
      filename: "notes.txt",
      mediaType: "text/plain"
    )
    let signature = MailSignature(
      name: "Default",
      document: SignatureDocument(text: "Sender")
    )
    var draft = MailShellCompositionDraft(
      body: "Original",
      connectionId: nil,
      recipient: "Taylor <taylor@example.com>",
      replyToMessage: nil,
      sourceMessage: nil,
      subject: "Planning",
      bccRecipients: "hidden@example.com",
      ccRecipients: "copy@example.com",
      quotedText: "Earlier message",
      signature: signature,
      assets: [asset]
    )
    let originalMetadata = draft
    let editor = SemanticMessageEditorModel(document: draft.document)
    let captured = editor.composeAssistanceTarget()

    #expect(
      editor.applyAssistanceDocument(
        SemanticMessageDocument(plainText: "Rewritten"),
        application: .replaceTarget,
        target: captured
      )
    )
    draft.document = editor.document

    #expect(draft.recipient == originalMetadata.recipient)
    #expect(draft.ccRecipients == originalMetadata.ccRecipients)
    #expect(draft.bccRecipients == originalMetadata.bccRecipients)
    #expect(draft.subject == originalMetadata.subject)
    #expect(draft.signature == originalMetadata.signature)
    #expect(draft.quotedText == originalMetadata.quotedText)
    #expect(draft.assets == originalMetadata.assets)
    #expect(draft.deliveryBody.contains("Rewritten"))
    #expect(draft.deliveryBody.contains("Sender"))
    #expect(draft.deliveryBody.contains("Earlier message"))
  }

  @Test
  func composeInstructionsRequireClarificationAndProtectDeliveryState() {
    let instructions = SystemMailAssistanceEngine.composeInstructions

    #expect(instructions.contains("clarification"))
    #expect(instructions.contains("Never change or generate recipients"))
    #expect(instructions.contains("signatures"))
    #expect(instructions.contains("attachments"))
    #expect(instructions.contains("send action"))
    #expect(instructions.contains("preserve every factual claim"))
    #expect(instructions.contains("author's voice"))
    #expect(instructions.contains("exact input block count"))
  }

  private func makeRequest(
    action: ComposeAssistanceAction,
    target: ComposeAssistanceTarget,
    subject: String = "Subject",
    recipients: [String] = ["Taylor"]
  ) throws -> MailAssistanceRequest {
    try ComposeAssistanceRequestBuilder().makeRequest(
      action: action,
      target: target,
      subject: subject,
      recipientDisplayNames: recipients,
      profileId: profileId,
      localeIdentifier: "en_US"
    )
  }

  private func target(for document: SemanticMessageDocument) -> ComposeAssistanceTarget {
    ComposeAssistanceTarget(
      insertionOffset: document.attributedText.characters.count,
      range: nil,
      scope: .authoredBody,
      sourceDocument: document,
      targetDocument: document
    )
  }

  private func factualDocument(
    prefix: String,
    amount: String = "$50",
    question: String = "?"
  ) -> SemanticMessageDocument {
    SemanticMessageDocument(
      blocks: [
        .init(
          runs: [
            .init("\(prefix) \(amount) on 2026-09-01. ", isBold: true),
            .init("https://example.com", link: "https://example.com"),
            .init(" says \"Approved\". Can you confirm\(question)"),
          ]
        )
      ]
    )
  }
}
