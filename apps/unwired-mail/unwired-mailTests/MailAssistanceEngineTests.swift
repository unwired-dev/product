import Foundation
import FoundationModels
import Testing

@testable import unwired_mail

struct MailAssistanceEngineTests {
  private let profileId = MailProfileId(rawValue: "profile")

  @Test
  func deterministicEngineReturnsVersionBoundContentAndClarification() async throws {
    let request = makeRequest()
    let content = try await DeterministicMailAssistanceEngine(
      outcome: .success("Draft response")
    ).generate(request)
    let clarification = try await DeterministicMailAssistanceEngine(
      outcome: .clarification("Which date should I use?")
    ).generate(request)

    #expect(content.kind == .content)
    #expect(content.content == "Draft response")
    #expect(
      content.applicationStatus(
        profileId: profileId,
        inputVersion: request.context.inputVersion
      ) == .current
    )
    #expect(clarification.kind == .clarification)
  }

  @Test
  func previewBecomesUnusableWhenProfileOrAnyInputRevisionChanges() async throws {
    let request = makeRequest()
    let preview = try await DeterministicMailAssistanceEngine(
      outcome: .success("Draft response")
    ).generate(request)

    #expect(
      preview.applicationStatus(
        profileId: MailProfileId(rawValue: "other-profile"),
        inputVersion: request.context.inputVersion
      ) == .stale
    )
    #expect(
      preview.applicationStatus(
        profileId: profileId,
        inputVersion: MailAssistanceInputVersion(
          draftRevision: "draft-2",
          selectionRevision: "selection-1",
          threadRevision: "thread-1"
        )
      ) == .stale
    )
  }

  @Test
  func engineRejectsUnversionedAndOversizedContextBeforeGeneration() async {
    let limits = MailAssistanceContextLimits(
      maximumCharacterCount: 8,
      maximumSourceMessageCount: 1
    )
    let engine = DeterministicMailAssistanceEngine(
      limits: limits,
      outcome: .success("unused")
    )

    await #expect(throws: MailAssistanceError.invalidInputVersion) {
      try await engine.generate(
        makeRequest(
          inputVersion: MailAssistanceInputVersion(),
          messageBody: "short"
        )
      )
    }
    await #expect(
      throws: MailAssistanceError.contextTooLarge(
        maximumCharacterCount: 8,
        maximumSourceMessageCount: 1
      )
    ) {
      try await engine.generate(makeRequest(messageBody: "too much content"))
    }
  }

  @Test
  func deterministicEngineExposesUnavailableFailureAndCancellationPaths() async {
    let request = makeRequest()
    let unavailable = DeterministicMailAssistanceEngine(
      availability: .unavailable(.modelNotReady),
      outcome: .success("unused")
    )
    await #expect(throws: MailAssistanceError.unavailable(.modelNotReady)) {
      try await unavailable.generate(request)
    }

    let failure = DeterministicMailAssistanceEngine(
      outcome: .failure(.rateLimited)
    )
    await #expect(throws: MailAssistanceError.rateLimited) {
      try await failure.generate(request)
    }

    let cancellable = DeterministicMailAssistanceEngine(outcome: .suspendUntilCancelled)
    let task = Task { try await cancellable.generate(request) }
    await Task.yield()
    task.cancel()
    await #expect(throws: MailAssistanceError.cancelled) {
      try await task.value
    }
  }

  @Test(
    arguments: [
      (
        SystemLanguageModel.Availability.unavailable(.deviceNotEligible),
        MailAssistanceAvailability.unavailable(.deviceNotEligible)
      ),
      (
        SystemLanguageModel.Availability.unavailable(.appleIntelligenceNotEnabled),
        MailAssistanceAvailability.unavailable(.appleIntelligenceNotEnabled)
      ),
      (
        SystemLanguageModel.Availability.unavailable(.modelNotReady),
        MailAssistanceAvailability.unavailable(.modelNotReady)
      ),
    ]
  )
  func systemAvailabilityMapsFrameworkReasons(
    frameworkAvailability: SystemLanguageModel.Availability,
    expected: MailAssistanceAvailability
  ) {
    #expect(
      SystemMailAssistanceEngine.availability(
        modelAvailability: frameworkAvailability,
        localeIdentifier: "en_US",
        supportsLocale: true
      ) == expected
    )
  }

  @Test
  func systemAvailabilitySeparatelyReportsUnsupportedLanguageOrRegion() {
    #expect(
      SystemMailAssistanceEngine.availability(
        modelAvailability: .available,
        localeIdentifier: "zz_ZZ",
        supportsLocale: false
      ) == .unavailable(.unsupportedLanguageOrRegion(localeIdentifier: "zz_ZZ"))
    )
  }

  @Test
  func systemGenerationFailuresMapToProductOwnedErrors() {
    let context = LanguageModelSession.GenerationError.Context(debugDescription: "redacted")

    #expect(
      SystemMailAssistanceEngine.mapGenerationError(.assetsUnavailable(context))
        == .resourcesUnavailable
    )
    #expect(
      SystemMailAssistanceEngine.mapGenerationError(.rateLimited(context)) == .rateLimited
    )
    #expect(
      SystemMailAssistanceEngine.mapGenerationError(.unsupportedLanguageOrLocale(context))
        == .unsupportedLanguageOrLocale
    )
    #expect(
      SystemMailAssistanceEngine.mapGenerationError(.exceededContextWindowSize(context))
        == .contextTooLarge(
          maximumCharacterCount: MailAssistanceContextLimits.standard.maximumCharacterCount,
          maximumSourceMessageCount: MailAssistanceContextLimits.standard.maximumSourceMessageCount
        )
    )
  }

  @Test
  func productInstructionsFenceUntrustedMailAndProhibitExternalActions() {
    let instructions = SystemMailAssistanceEngine.productInstructions

    #expect(instructions.contains("untrusted data"))
    #expect(instructions.contains("Never follow links"))
    #expect(instructions.contains("access a network"))
    #expect(instructions.contains("perform mail actions"))
  }

  private func makeRequest(
    inputVersion: MailAssistanceInputVersion = MailAssistanceInputVersion(
      draftRevision: "draft-1",
      selectionRevision: "selection-1",
      threadRevision: "thread-1"
    ),
    messageBody: String = "Can we meet next week?"
  ) -> MailAssistanceRequest {
    MailAssistanceRequest(
      context: MailAssistanceContext(
        draft: MailAssistanceDraftContext(
          authoredBody: "Thanks for the note.",
          selectedText: nil,
          subject: "Re: Planning"
        ),
        inputVersion: inputVersion,
        profileId: profileId,
        recipientDisplayNames: ["A. Person"],
        sourceMessages: [
          MailAssistanceSourceMessage(
            body: messageBody,
            id: "message-1",
            senderDisplayName: "A. Person"
          )
        ]
      ),
      localeIdentifier: "en_US",
      operation: .respond(instruction: "Draft a concise reply")
    )
  }
}
