import Foundation
import SwiftUI
import Testing

@testable import unwired_mail

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
    #expect(instruction.contains("Current preview"))
    #expect(instruction.contains("Make this warmer"))
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
