import SwiftUI
import Translation

/// Presents explicit language selection, system download consent, and ephemeral review.
struct MailTranslationView: View {
  let presentation: MailTranslationPresentation
  @Bindable var assistanceViewModel: MailAssistanceViewModel
  let currentInputVersion: () -> MailAssistanceInputVersion
  let applyDraftTranslation: ((String) -> Bool)?

  @Environment(\.dismiss) private var dismiss
  @State private var configuration: TranslationSession.Configuration?
  @State private var pendingRequest: MailTranslationRequest?
  @State private var sourceLanguage: Locale.Language?
  @State private var targetLanguage: Locale.Language?
  @State private var viewModel: MailTranslationViewModel

  @MainActor
  init(
    presentation: MailTranslationPresentation,
    assistanceViewModel: MailAssistanceViewModel,
    currentInputVersion: @escaping () -> MailAssistanceInputVersion,
    applyDraftTranslation: ((String) -> Bool)? = nil,
    availabilityChecker: any MailTranslationAvailabilityChecking =
      SystemMailTranslationAvailabilityChecker()
  ) {
    self.presentation = presentation
    self.assistanceViewModel = assistanceViewModel
    self.currentInputVersion = currentInputVersion
    self.applyDraftTranslation = applyDraftTranslation
    _targetLanguage = State(initialValue: Locale.current.language)
    _viewModel = State(
      initialValue: MailTranslationViewModel(availabilityChecker: availabilityChecker)
    )
  }

  var body: some View {
    @Bindable var viewModel = viewModel
    NavigationStack {
      Form {
        Section("Languages") {
          Picker("From", selection: $sourceLanguage) {
            Text("Detect Automatically").tag(Optional<Locale.Language>.none)
            ForEach(viewModel.supportedLanguages, id: \.minimalIdentifier) { language in
              Text(languageName(language)).tag(Optional(language))
            }
          }
          Picker("To", selection: $targetLanguage) {
            ForEach(viewModel.supportedLanguages, id: \.minimalIdentifier) { language in
              Text(languageName(language)).tag(Optional(language))
            }
          }
        }

        Section("Availability") {
          if viewModel.phase == .checkingAvailability {
            ProgressView("Checking language availability…")
          } else {
            Label(availabilityMessage, systemImage: availabilityImage)
          }
        }

        if viewModel.phase == .translating {
          Section {
            ProgressView("Preparing and translating on this device…")
              .accessibilityLabel("Preparing and translating on this device")
          }
        }

        if let result = viewModel.result {
          Section {
            if result.applicationStatus(
              profileId: assistanceViewModel.activeProfileId,
              inputVersion: currentInputVersion()
            ) == .stale {
              ContentUnavailableView {
                Label("Source text changed", systemImage: "arrow.clockwise")
              } description: {
                Text("Translate the current text again before using the result.")
              }
            } else {
              MailTranslationComparisonView(result: result)
              Text("Translations can be inaccurate. Check the original before relying on them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
        }

        if let errorMessage = viewModel.errorMessage {
          Section("Translation unavailable") {
            Label(errorMessage, systemImage: "exclamationmark.circle")
              .foregroundStyle(.red)
          }
        }

        Section {
          Button(translateButtonTitle, action: startTranslation)
            .disabled(translateIsDisabled)
          if presentation.contentKind == .draftSelection, viewModel.result != nil {
            Button("Replace Selection", action: replaceSelection)
              .buttonStyle(.borderedProminent)
            Button("Keep Original", action: dismiss.callAsFunction)
          }
        }
      }
      .navigationTitle(
        presentation.contentKind == .draftSelection ? "Translate Selection" : "Translate Message"
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close", action: dismiss.callAsFunction)
        }
      }
    }
    .translationTask(configuration) { session in
      guard let pendingRequest else { return }
      await viewModel.perform(pendingRequest, using: SystemMailTranslationSession(session))
      self.pendingRequest = nil
    }
    .task {
      await viewModel.loadSupportedLanguages()
      selectAvailableTargetIfNeeded()
    }
    .task(id: languageSelectionIdentifier) {
      guard let targetLanguage else { return }
      await viewModel.refreshAvailability(
        sourceText: presentation.sourceText,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage
      )
    }
    .onChange(of: assistanceViewModel.contentIsConcealed) { _, isConcealed in
      if isConcealed { cancelAndDismiss() }
    }
    .onChange(of: assistanceViewModel.activeProfileId) { _, activeProfileId in
      if activeProfileId != presentation.profileId { cancelAndDismiss() }
    }
    .onDisappear(perform: destroyEphemeralState)
  }

  private var availabilityImage: String {
    switch viewModel.availability {
    case .downloadable:
      "arrow.down.circle"
    case .installed:
      "checkmark.circle"
    case .unsupported, nil:
      "exclamationmark.circle"
    }
  }

  private var availabilityMessage: String {
    switch viewModel.availability {
    case .downloadable:
      "An on-device language download is required. The system will ask before downloading."
    case .installed:
      "This language pair is ready on this device."
    case .unsupported:
      "This language pair is unavailable on this device."
    case nil:
      "Choose source and target languages to check availability."
    }
  }

  private var languageSelectionIdentifier: String {
    "\(sourceLanguage?.minimalIdentifier ?? "automatic")>\(targetLanguage?.minimalIdentifier ?? "none")"
  }

  private var translateButtonTitle: String {
    viewModel.availability == .downloadable ? "Download and Translate" : "Translate"
  }

  private var translateIsDisabled: Bool {
    targetLanguage == nil || viewModel.availability == nil
      || viewModel.availability == .unsupported || viewModel.phase == .checkingAvailability
      || viewModel.phase == .translating
  }

  private func startTranslation() {
    guard let targetLanguage else { return }
    do {
      let request = try viewModel.beginTranslation(
        presentation: presentation,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        validation: MailTranslationValidationContext(
          contentIsConcealed: assistanceViewModel.contentIsConcealed,
          inputVersion: currentInputVersion(),
          isEnabled: assistanceViewModel.isEnabled,
          profileId: assistanceViewModel.activeProfileId
        )
      )
      pendingRequest = request
      var nextConfiguration = TranslationSession.Configuration(
        source: sourceLanguage,
        target: targetLanguage
      )
      if configuration != nil { nextConfiguration.invalidate() }
      configuration = nextConfiguration
    } catch {
      viewModel.record(error)
    }
  }

  private func replaceSelection() {
    guard let result = viewModel.result,
      result.applicationStatus(
        profileId: assistanceViewModel.activeProfileId,
        inputVersion: currentInputVersion()
      ) == .current,
      applyDraftTranslation?(result.targetText) == true
    else {
      viewModel.applicationFailed()
      return
    }
    destroyEphemeralState()
    dismiss()
  }

  private func selectAvailableTargetIfNeeded() {
    guard !viewModel.supportedLanguages.isEmpty else {
      targetLanguage = nil
      return
    }
    if let targetLanguage,
      viewModel.supportedLanguages.contains(where: { $0.isEquivalent(to: targetLanguage) })
    {
      return
    }
    targetLanguage = viewModel.supportedLanguages.first
  }

  private func languageName(_ language: Locale.Language) -> String {
    Locale.current.localizedString(forIdentifier: language.minimalIdentifier)
      ?? language.minimalIdentifier
  }

  private func cancelAndDismiss() {
    destroyEphemeralState()
    dismiss()
  }

  private func destroyEphemeralState() {
    pendingRequest = nil
    configuration = nil
    viewModel.cancelAndDestroy()
  }
}
