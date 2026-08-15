import Foundation
import Testing

@testable import unwired_mail

@MainActor
struct MailAssistanceEnablementTests {
  private let productAccountId = "product-account"
  private let profileId = MailProfileId(rawValue: "profile")

  @Test
  func enablementDefaultsOffAndStaysDeviceAndProfileScoped() throws {
    let firstDeviceSuite = "MailAssistanceEnablementTests.first.\(UUID().uuidString)"
    let secondDeviceSuite = "MailAssistanceEnablementTests.second.\(UUID().uuidString)"
    let firstDeviceDefaults = try #require(UserDefaults(suiteName: firstDeviceSuite))
    let secondDeviceDefaults = try #require(UserDefaults(suiteName: secondDeviceSuite))
    defer {
      firstDeviceDefaults.removePersistentDomain(forName: firstDeviceSuite)
      secondDeviceDefaults.removePersistentDomain(forName: secondDeviceSuite)
    }
    let firstDeviceStore = UserDefaultsMailAssistanceStore(
      defaults: firstDeviceDefaults
    )
    let secondDeviceStore = UserDefaultsMailAssistanceStore(
      defaults: secondDeviceDefaults
    )
    let otherProfileId = MailProfileId(rawValue: "other-profile")

    #expect(
      firstDeviceStore.isEnabled(
        productAccountId: productAccountId,
        profileId: profileId
      ) == false
    )
    firstDeviceStore.setEnabled(
      true,
      productAccountId: productAccountId,
      profileId: profileId
    )

    #expect(
      firstDeviceStore.isEnabled(
        productAccountId: productAccountId,
        profileId: profileId
      )
    )
    #expect(
      firstDeviceStore.isEnabled(
        productAccountId: productAccountId,
        profileId: otherProfileId
      ) == false
    )
    #expect(
      secondDeviceStore.isEnabled(
        productAccountId: productAccountId,
        profileId: profileId
      ) == false
    )

  }

  @Test
  func enablementStoreClearsOnlyTheRequestedProductAccount() throws {
    let suiteName = "MailAssistanceEnablementTests.clear.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsMailAssistanceStore(defaults: defaults)
    store.setEnabled(true, productAccountId: productAccountId, profileId: profileId)
    store.setEnabled(true, productAccountId: "other-account", profileId: profileId)

    store.clear(productAccountId: productAccountId)

    #expect(store.isEnabled(productAccountId: productAccountId, profileId: profileId) == false)
    #expect(store.isEnabled(productAccountId: "other-account", profileId: profileId))
  }

  @Test
  func enablementStoreDoesNotClearAnAccountWhoseIdentifierExtendsAnother() throws {
    let suiteName = "MailAssistanceEnablementTests.prefix-clear.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsMailAssistanceStore(defaults: defaults)
    let extendedProductAccountId = productAccountId + ".profile"
    store.setEnabled(true, productAccountId: productAccountId, profileId: profileId)
    store.setEnabled(true, productAccountId: extendedProductAccountId, profileId: profileId)

    store.clear(productAccountId: productAccountId)

    #expect(store.isEnabled(productAccountId: productAccountId, profileId: profileId) == false)
    #expect(store.isEnabled(productAccountId: extendedProductAccountId, profileId: profileId))
  }

  @Test
  func enablingAndAvailabilityChecksNeverGenerateWithoutAnExplicitRequest() async {
    let recorder = MailAssistanceEngineRecorder()
    let viewModel = MailAssistanceViewModel(
      productAccountId: productAccountId,
      profileId: profileId,
      store: RecordingMailAssistanceEnablementStore(),
      engine: RecordingMailAssistanceEngine(recorder: recorder)
    )

    viewModel.isEnabled = true
    #expect(await recorder.availabilityRequestCount == 0)
    #expect(await recorder.generationRequestCount == 0)

    await viewModel.refreshAvailability()
    #expect(await recorder.availabilityRequestCount == 1)
    #expect(await recorder.generationRequestCount == 0)

    let preview = await viewModel.perform(makeRequest())
    #expect(preview?.content == "Generated preview")
    #expect(await recorder.generationRequestCount == 1)
  }

  @Test(
    arguments: [
      (
        MailAssistanceUnavailableReason.deviceNotEligible,
        "Mail Assistance is unavailable on this device."
      ),
      (
        MailAssistanceUnavailableReason.appleIntelligenceNotEnabled,
        "Turn on Apple Intelligence to use Mail Assistance."
      ),
      (
        MailAssistanceUnavailableReason.modelNotReady,
        "The on-device model is not ready yet."
      ),
      (
        MailAssistanceUnavailableReason.unsupportedLanguageOrRegion(
          localeIdentifier: "zz_ZZ"
        ),
        "Mail Assistance is unavailable for the current language or region."
      ),
    ]
  )
  func availabilityExplainsEveryPreflightReason(
    reason: MailAssistanceUnavailableReason,
    expectedMessage: String
  ) async {
    let viewModel = makeEnabledViewModel(
      engine: DeterministicMailAssistanceEngine(
        availability: .unavailable(reason),
        outcome: .success("unused")
      )
    )

    await viewModel.refreshAvailability()

    #expect(viewModel.statusMessage == expectedMessage)
  }

  @Test
  func resourceFailureHasASpecificExplanationWithoutRetainingMail() async {
    let viewModel = makeEnabledViewModel(
      engine: DeterministicMailAssistanceEngine(
        outcome: .failure(.resourcesUnavailable)
      )
    )

    #expect(await viewModel.perform(makeRequest()) == nil)
    #expect(
      viewModel.statusMessage == "The on-device model does not currently have enough resources."
    )
    #expect(viewModel.hasRetainedSensitiveContent == false)
  }

  @Test
  func lockingDuringAvailabilityCheckCancelsAndClearsTheSession() async {
    let viewModel = makeEnabledViewModel(engine: SuspendingAvailabilityEngine())
    let check = Task { await viewModel.refreshAvailability() }
    await wait(for: .checkingAvailability, in: viewModel)

    viewModel.profileDidLock()
    await check.value

    #expect(viewModel.phase == .idle)
    #expect(viewModel.hasRetainedSensitiveContent == false)
    #expect(viewModel.availability == nil)
  }

  @Test
  func lockingDuringGenerationOrPreviewDestroysEphemeralContentAcrossReauthentication() async {
    let generatingViewModel = makeEnabledViewModel(
      engine: DeterministicMailAssistanceEngine(outcome: .suspendUntilCancelled)
    )
    let generation = Task { await generatingViewModel.perform(makeRequest()) }
    await wait(for: .generating, in: generatingViewModel)

    generatingViewModel.profileDidLock()
    #expect(await generation.value == nil)
    generatingViewModel.profileDidUnlock()

    #expect(generatingViewModel.phase == .idle)
    #expect(generatingViewModel.hasRetainedSensitiveContent == false)

    let previewingViewModel = makeEnabledViewModel(
      engine: DeterministicMailAssistanceEngine(outcome: .success("Unaccepted preview"))
    )
    #expect(await previewingViewModel.perform(makeRequest())?.content == "Unaccepted preview")
    #expect(previewingViewModel.phase == .previewing)
    #expect(previewingViewModel.hasRetainedSensitiveContent)

    previewingViewModel.profileDidLock()
    previewingViewModel.profileDidUnlock()

    #expect(previewingViewModel.phase == .idle)
    #expect(previewingViewModel.preview == nil)
    #expect(previewingViewModel.hasRetainedSensitiveContent == false)
  }

  @Test
  func switchingProfilesCancelsGenerationAndDestroysEphemeralState() async {
    let otherProfileId = MailProfileId(rawValue: "other-profile")
    let store = RecordingMailAssistanceEnablementStore()
    store.setEnabled(true, productAccountId: productAccountId, profileId: profileId)
    store.setEnabled(true, productAccountId: productAccountId, profileId: otherProfileId)
    let viewModel = MailAssistanceViewModel(
      productAccountId: productAccountId,
      profileId: profileId,
      store: store,
      engine: DeterministicMailAssistanceEngine(outcome: .suspendUntilCancelled)
    )
    let generation = Task { await viewModel.perform(makeRequest()) }
    await wait(for: .generating, in: viewModel)

    viewModel.activateProfile(otherProfileId, contentIsConcealed: false)

    #expect(await generation.value == nil)
    #expect(viewModel.activeProfileId == otherProfileId)
    #expect(viewModel.phase == .idle)
    #expect(viewModel.hasRetainedSensitiveContent == false)
    #expect(viewModel.preview == nil)
    #expect(viewModel.availability == nil)
  }

  @Test
  func quietSuppressesProactiveSuggestionsButNotExplicitAssistance() async {
    let policy = MailProfileInterruptionPolicy(
      quietState: .quiet(until: nil),
      hasAuthoritativeQuietState: true,
      contentIsConcealed: false,
      now: .now
    )
    let viewModel = makeEnabledViewModel(
      engine: DeterministicMailAssistanceEngine(outcome: .success("Explicit result"))
    )

    #expect(policy.allowsProactiveSuggestions == false)
    #expect(policy.allowsContentReveal)
    #expect(await viewModel.perform(makeRequest())?.content == "Explicit result")
  }

  private func makeEnabledViewModel(
    engine: any MailAssistanceEngine
  ) -> MailAssistanceViewModel {
    let store = RecordingMailAssistanceEnablementStore()
    store.setEnabled(true, productAccountId: productAccountId, profileId: profileId)
    return MailAssistanceViewModel(
      productAccountId: productAccountId,
      profileId: profileId,
      store: store,
      engine: engine
    )
  }

  private func makeRequest() -> MailAssistanceRequest {
    MailAssistanceRequest(
      context: MailAssistanceContext(
        draft: MailAssistanceDraftContext(
          authoredBody: "Thanks for the note.",
          selectedText: nil,
          subject: "Re: Planning"
        ),
        inputVersion: MailAssistanceInputVersion(
          draftRevision: "draft-1",
          selectionRevision: "selection-1",
          threadRevision: "thread-1"
        ),
        profileId: profileId,
        recipientDisplayNames: ["A. Person"],
        sourceMessages: [
          MailAssistanceSourceMessage(
            body: "Can we meet next week?",
            senderDisplayName: "A. Person"
          )
        ]
      ),
      localeIdentifier: "en_US",
      operation: .respond(instruction: "Draft a concise reply")
    )
  }

  private func wait(
    for phase: MailAssistanceViewModel.Phase,
    in viewModel: MailAssistanceViewModel
  ) async {
    for _ in 0..<100 where viewModel.phase != phase {
      await Task.yield()
    }
    #expect(viewModel.phase == phase)
  }
}

private final class RecordingMailAssistanceEnablementStore:
  MailAssistanceEnablementPersisting
{
  private var enabledProfiles: Set<String> = []

  func clear(productAccountId: String) {
    enabledProfiles = enabledProfiles.filter { !$0.hasPrefix(productAccountId + ".") }
  }

  func isEnabled(productAccountId: String, profileId: MailProfileId) -> Bool {
    enabledProfiles.contains(key(productAccountId: productAccountId, profileId: profileId))
  }

  func setEnabled(
    _ isEnabled: Bool,
    productAccountId: String,
    profileId: MailProfileId
  ) {
    let key = key(productAccountId: productAccountId, profileId: profileId)
    if isEnabled {
      enabledProfiles.insert(key)
    } else {
      enabledProfiles.remove(key)
    }
  }

  private func key(productAccountId: String, profileId: MailProfileId) -> String {
    productAccountId + "." + profileId.rawValue
  }
}

private actor MailAssistanceEngineRecorder {
  private(set) var availabilityRequestCount = 0
  private(set) var generationRequestCount = 0

  func recordAvailabilityRequest() {
    availabilityRequestCount += 1
  }

  func recordGenerationRequest() {
    generationRequestCount += 1
  }
}

private struct RecordingMailAssistanceEngine: MailAssistanceEngine {
  let recorder: MailAssistanceEngineRecorder

  func availability(for _: String) async -> MailAssistanceAvailability {
    await recorder.recordAvailabilityRequest()
    return .available
  }

  func generate(_ request: MailAssistanceRequest) async throws -> MailAssistancePreview {
    await recorder.recordGenerationRequest()
    return MailAssistancePreview(
      content: "Generated preview",
      inputVersion: request.context.inputVersion,
      kind: .content,
      profileId: request.context.profileId
    )
  }
}

private struct SuspendingAvailabilityEngine: MailAssistanceEngine {
  func availability(for _: String) async -> MailAssistanceAvailability {
    do {
      try await Task.sleep(for: .seconds(3_600))
      return .available
    } catch {
      return .unavailable(.modelNotReady)
    }
  }

  func generate(_: MailAssistanceRequest) async throws -> MailAssistancePreview {
    throw MailAssistanceError.generationFailed
  }
}
