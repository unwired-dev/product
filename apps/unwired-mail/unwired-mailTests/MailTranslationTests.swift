import Foundation
import SwiftUI
import Testing

@testable import unwired_mail

@MainActor
struct MailTranslationTests {
  private let english = Locale.Language(identifier: "en")
  private let german = Locale.Language(identifier: "de")
  private let profileId = MailProfileId(rawValue: "profile")

  @Test(.bug(id: 415))
  func incomingTranslationRequiresAlreadyLocalMessageText() {
    let messageId = messageId()

    #expect(throws: MailTranslationError.noLocalMessageText) {
      try MailTranslationRequestBuilder.incomingMessage(
        messageId: messageId,
        localBodyText: nil,
        profileId: profileId
      )
    }
    #expect(throws: MailTranslationError.noLocalMessageText) {
      try MailTranslationRequestBuilder.incomingMessage(
        messageId: messageId,
        localBodyText: "  \n",
        profileId: profileId
      )
    }
  }

  @Test(.bug(id: 415))
  func draftTranslationRequiresAnExplicitSelection() {
    let document = SemanticMessageDocument(plainText: "Translate only this text")
    let editor = SemanticMessageEditorModel(document: document)

    #expect(throws: MailTranslationError.emptyDraftSelection) {
      try MailTranslationRequestBuilder.draftSelection(
        target: editor.composeAssistanceTarget(),
        inputVersion: inputVersion(),
        profileId: profileId
      )
    }
  }

  @Test(
    .bug(id: 415),
    arguments: [
      MailTranslationAvailability.installed,
      .downloadable,
      .unsupported,
    ])
  func availabilityDistinguishesDevicePairStates(status: MailTranslationAvailability) async {
    let checker = TranslationAvailabilityStub(status: status, languages: [english, german])
    let viewModel = MailTranslationViewModel(availabilityChecker: checker)

    await viewModel.loadSupportedLanguages()
    await viewModel.refreshAvailability(
      sourceText: "Hello",
      sourceLanguage: english,
      targetLanguage: german
    )

    #expect(viewModel.availability == status)
    #expect(viewModel.supportedLanguages == [german, english])
  }

  @Test(.bug(id: 415))
  func correctedLanguagePairIsUsedForTranslation() async throws {
    let presentation = try incomingPresentation(text: "Hallo")
    let checker = TranslationAvailabilityStub(status: .installed, languages: [english, german])
    let viewModel = MailTranslationViewModel(availabilityChecker: checker)
    await viewModel.refreshAvailability(
      sourceText: presentation.sourceText,
      sourceLanguage: german,
      targetLanguage: english
    )

    let request = try viewModel.beginTranslation(
      presentation: presentation,
      sourceLanguage: german,
      targetLanguage: english,
      validation: validation(for: presentation)
    )

    #expect(request.sourceLanguage?.isEquivalent(to: german) == true)
    #expect(request.targetLanguage.isEquivalent(to: english))
  }

  @Test(.bug(id: 415))
  func incomingResultKeepsOriginalBesideTranslation() async throws {
    let presentation = try incomingPresentation(text: "Hello 世界")
    let viewModel = try await readyViewModel(for: presentation)
    let request = try begin(presentation, using: viewModel)
    let session = TranslationSessionStub(
      response: MailTranslationResponse(
        sourceLanguage: english,
        sourceText: presentation.sourceText,
        targetLanguage: german,
        targetText: "Hallo 世界"
      )
    )

    await viewModel.perform(request, using: session)

    #expect(viewModel.result?.sourceText == "Hello 世界")
    #expect(viewModel.result?.targetText == "Hallo 世界")
    #expect(viewModel.result?.contentKind == .incomingMessage)
  }

  @Test(.bug(id: 415))
  func downloadFailureLeavesSourceAvailableAndNoResult() async throws {
    let presentation = try incomingPresentation(text: "Original")
    let viewModel = try await readyViewModel(for: presentation, status: .downloadable)
    let request = try begin(presentation, using: viewModel)
    let session = TranslationSessionStub(
      response: response(for: presentation),
      preparationError: TranslationTestError.downloadDeclined
    )

    await viewModel.perform(request, using: session)

    #expect(presentation.sourceText == "Original")
    #expect(viewModel.result == nil)
    #expect(viewModel.errorMessage != nil)
  }

  @Test(.bug(id: 415))
  func draftAcceptanceIsOneUndoableSelectionReplacement() throws {
    let document = SemanticMessageDocument(plainText: "Hello Taylor")
    let editor = SemanticMessageEditorModel(document: document)
    let lower = editor.attributedText.characters.index(
      editor.attributedText.startIndex,
      offsetBy: 6
    )
    editor.selection = AttributedTextSelection(range: lower..<editor.attributedText.endIndex)
    let target = editor.composeAssistanceTarget()

    #expect(
      editor.applyAssistanceDocument(
        SemanticMessageDocument(plainText: "Tobias"),
        application: .replaceTarget,
        target: target
      )
    )
    #expect(editor.document.plainText == "Hello Tobias")
    #expect(editor.canUndo)

    editor.undo()

    #expect(editor.document == document)
  }

  @Test(.bug(id: 415))
  func changedInputOrProfileMakesResultStale() throws {
    let presentation = try incomingPresentation(text: "Original")
    let result = try MailTranslationResult.validated(
      response: response(for: presentation),
      request: presentation.request(sourceLanguage: english, targetLanguage: german)
    )

    #expect(
      result.applicationStatus(
        profileId: profileId,
        inputVersion: MailTranslationRequestBuilder.incomingInputVersion(
          messageId: messageId(),
          localBodyText: "Changed"
        )
      ) == .stale
    )
    #expect(
      result.applicationStatus(
        profileId: MailProfileId(rawValue: "other"),
        inputVersion: presentation.inputVersion
      ) == .stale
    )
  }

  @Test(.bug(id: 415))
  func concealmentAndDestroyRemoveEphemeralTranslation() async throws {
    let presentation = try incomingPresentation(text: "Private text")
    let viewModel = try await readyViewModel(for: presentation)
    let request = try begin(presentation, using: viewModel)
    await viewModel.perform(
      request,
      using: TranslationSessionStub(response: response(for: presentation))
    )
    #expect(viewModel.hasRetainedMailContent)

    viewModel.cancelAndDestroy()

    #expect(!viewModel.hasRetainedMailContent)
    #expect(viewModel.result == nil)
    #expect(throws: MailTranslationError.unavailable) {
      try viewModel.beginTranslation(
        presentation: presentation,
        sourceLanguage: english,
        targetLanguage: german,
        validation: MailTranslationValidationContext(
          contentIsConcealed: true,
          inputVersion: presentation.inputVersion,
          isEnabled: true,
          profileId: profileId
        )
      )
    }
  }

  private func begin(
    _ presentation: MailTranslationPresentation,
    using viewModel: MailTranslationViewModel
  ) throws -> MailTranslationRequest {
    try viewModel.beginTranslation(
      presentation: presentation,
      sourceLanguage: english,
      targetLanguage: german,
      validation: validation(for: presentation)
    )
  }

  private func incomingPresentation(text: String) throws -> MailTranslationPresentation {
    try MailTranslationRequestBuilder.incomingMessage(
      messageId: messageId(),
      localBodyText: text,
      profileId: profileId
    )
  }

  private func inputVersion() -> MailAssistanceInputVersion {
    MailAssistanceInputVersion(
      draftRevision: "draft",
      selectionRevision: "selection",
      threadRevision: "not-applicable"
    )
  }

  private func messageId() -> StableProviderMessageIdentity {
    StableProviderMessageIdentity(
      connectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .gmail,
          value: "connection"
        )
      ),
      providerMessageId: "message"
    )
  }

  private func readyViewModel(
    for presentation: MailTranslationPresentation,
    status: MailTranslationAvailability = .installed
  ) async throws -> MailTranslationViewModel {
    let viewModel = MailTranslationViewModel(
      availabilityChecker: TranslationAvailabilityStub(
        status: status,
        languages: [english, german]
      )
    )
    await viewModel.refreshAvailability(
      sourceText: presentation.sourceText,
      sourceLanguage: english,
      targetLanguage: german
    )
    return viewModel
  }

  private func response(
    for presentation: MailTranslationPresentation
  ) -> MailTranslationResponse {
    MailTranslationResponse(
      sourceLanguage: english,
      sourceText: presentation.sourceText,
      targetLanguage: german,
      targetText: "Übersetzung"
    )
  }

  private func validation(
    for presentation: MailTranslationPresentation
  ) -> MailTranslationValidationContext {
    MailTranslationValidationContext(
      contentIsConcealed: false,
      inputVersion: presentation.inputVersion,
      isEnabled: true,
      profileId: profileId
    )
  }
}

private enum TranslationTestError: Error {
  case downloadDeclined
}

private actor TranslationAvailabilityStub: MailTranslationAvailabilityChecking {
  let languages: [Locale.Language]
  let status: MailTranslationAvailability

  init(status: MailTranslationAvailability, languages: [Locale.Language]) {
    self.status = status
    self.languages = languages
  }

  func availability(
    for sourceText: String,
    sourceLanguage: Locale.Language?,
    targetLanguage: Locale.Language
  ) -> MailTranslationAvailability {
    status
  }

  func supportedLanguages() -> [Locale.Language] {
    languages
  }
}

private actor TranslationSessionStub: MailTranslationSession {
  let preparationError: TranslationTestError?
  let response: MailTranslationResponse

  init(
    response: MailTranslationResponse,
    preparationError: TranslationTestError? = nil
  ) {
    self.response = response
    self.preparationError = preparationError
  }

  func cancel() {}

  func prepareTranslation() throws {
    if let preparationError { throw preparationError }
  }

  func translate(_ sourceText: String) -> MailTranslationResponse {
    response
  }
}
