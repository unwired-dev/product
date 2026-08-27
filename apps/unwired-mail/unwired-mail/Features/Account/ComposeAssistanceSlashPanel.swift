import SwiftUI

// swiftlint:disable type_body_length
/// A caret-anchored, nonmodal Compose Assistance workflow opened from the slash catalog.
struct ComposeAssistanceSlashPanel: View {
  let command: SemanticMessageSlashCommand.AssistanceCommand
  let insertionOffset: () -> Int
  @Bindable var editorModel: SemanticMessageEditorModel
  @Bindable var assistanceViewModel: MailAssistanceViewModel
  let currentSubject: () -> String
  let recipientDisplayNames: () -> [String]
  let applySubject: (String) -> Void
  let dismiss: () -> Void

  @State private var application = ComposeAssistanceApplication.replaceTarget
  @State private var clarificationAnswer = ""
  @State private var instruction = ""
  @State private var localErrorMessage: String?
  @State private var originalRequest: MailAssistanceRequest?
  @State private var requestTarget: ComposeAssistanceTarget?
  @State private var selectedTone = ComposeAssistancePreset.professional

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Label(command.title, systemImage: command.systemImage)
          .font(.headline)
        Spacer(minLength: 8)
      }
      .padding(16)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(commandDescription)
            .font(.footnote)
            .foregroundStyle(.secondary)

          if !assistanceViewModel.isEnabled || assistanceViewModel.contentIsConcealed {
            Label(assistanceViewModel.statusMessage, systemImage: "sparkles")
          } else if assistanceViewModel.phase == .checkingAvailability {
            ProgressView("Checking On-Device Availability…")
              .accessibilityLabel("Checking On-Device Availability")
          } else if assistanceIsUnavailable {
            Label(assistanceViewModel.statusMessage, systemImage: "sparkles")
            Button("Try Again", action: refreshAvailability)
          } else if assistanceViewModel.phase == .generating {
            ProgressView("Creating Assistance Preview…")
              .accessibilityLabel("Creating Assistance Preview")
          } else if let preview = assistanceViewModel.preview {
            previewContent(preview)
          } else {
            commandOptions
          }

          if let errorMessage = localErrorMessage ?? assistanceViewModel.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        .padding(16)
      }
      .scrollIndicators(.visible)

      Divider()

      HStack(spacing: 8) {
        Button("Cancel", role: .cancel, action: dismiss)
        Spacer(minLength: 8)
        if let preview = assistanceViewModel.preview {
          if preview.kind == .content {
            Button(applicationTitle, action: acceptPreview)
              .buttonStyle(.borderedProminent)
              .disabled(previewIsStale(preview))
          } else {
            Button("Generate", systemImage: "sparkles", action: answerClarification)
              .buttonStyle(.borderedProminent)
              .disabled(
                clarificationAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              )
          }
        } else {
          Button("Generate", systemImage: "sparkles", action: generate)
            .buttonStyle(.borderedProminent)
            .disabled(!canGenerate)
        }
      }
      .padding(12)
    }
    .background(.regularMaterial)
    .clipShape(.rect(cornerRadius: 12))
    .shadow(radius: 8, y: 4)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Compose Assistance")
    .accessibilityIdentifier("mail-compose-assistance-panel")
    .task {
      await checkAvailability()
    }
    .onChange(of: assistanceViewModel.contentIsConcealed) { _, isConcealed in
      if isConcealed { dismiss() }
    }
  }

  @ViewBuilder
  private var commandOptions: some View {
    if command.requiresSelection, currentTarget.scope != .selection {
      Label("Select text in the Draft to use this action.", systemImage: "selection.pin.in.out")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    if command.requiresInstruction {
      TextField(instructionPrompt, text: $instruction, axis: .vertical)
        .lineLimit(2...5)
        .accessibilityIdentifier("mail-compose-assistance-instruction")
    }

    if command == .changeTone {
      Picker("Tone", selection: $selectedTone) {
        ForEach(tonePresets) { preset in
          Text(preset.title).tag(preset)
        }
      }
      .pickerStyle(.menu)
    }
  }

  @ViewBuilder
  private func previewContent(_ preview: MailAssistancePreview) -> some View {
    Label(
      preview.kind == .clarification ? "Clarification Needed" : "Assistance Preview",
      systemImage: preview.kind == .clarification ? "questionmark.bubble" : "sparkles"
    )
    Text(preview.semanticDocument?.attributedText ?? AttributedString(preview.content))
      .textSelection(.enabled)
      .accessibilityLabel(
        preview.kind == .clarification
          ? "Assistance clarification: \(preview.content)"
          : "Assistance Preview: \(preview.content)"
      )
    if preview.kind == .clarification {
      TextField("Answer the clarification", text: $clarificationAnswer, axis: .vertical)
        .lineLimit(2...5)
        .accessibilityIdentifier("mail-compose-assistance-clarification")
    }
    if previewIsStale(preview) {
      Label(
        "The Draft changed. Generate a new preview before applying it.",
        systemImage: "arrow.clockwise"
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    } else {
      Text("The preview stays outside the Draft until you accept it.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private var currentTarget: ComposeAssistanceTarget {
    switch command {
    case .draftFromPrompt:
      editorModel.composeAssistanceBodyTarget(insertionOffset: insertionOffset())
    case .suggestSubject:
      editorModel.composeAssistanceBodyTarget()
    case .ask, .changeTone, .proofread, .rewriteSelection, .shorten:
      editorModel.composeAssistanceTarget()
    }
  }

  private var canGenerate: Bool {
    guard assistanceViewModel.isEnabled,
      !assistanceViewModel.contentIsConcealed,
      assistanceViewModel.availability == .available,
      assistanceViewModel.phase == .idle,
      assistanceViewModel.preview == nil
    else { return false }
    let target = currentTarget
    if command.requiresSelection, target.scope != .selection { return false }
    if command.requiresInstruction,
      instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return false
    }
    return !target.targetDocument.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty || command == .draftFromPrompt
  }

  private var commandDescription: String {
    switch command {
    case .ask:
      "Uses selected text when available, otherwise only the authored body."
    case .changeTone:
      "Changes the selected text's tone while preserving its facts and meaning."
    case .draftFromPrompt:
      "Previews new text for insertion at the command's caret."
    case .proofread:
      "Mechanically proofreads the selected text without changing its meaning."
    case .rewriteSelection:
      "Rewrites only the selected text using your instruction."
    case .shorten:
      "Shortens the selected text without removing facts or commitments."
    case .suggestSubject:
      "Suggests a separate subject from the authored body."
    }
  }

  private var instructionPrompt: String {
    switch command {
    case .ask: "What do you want help with?"
    case .draftFromPrompt: "Describe the body you want to draft"
    case .rewriteSelection: "Describe how to rewrite the selection"
    case .changeTone, .proofread, .shorten, .suggestSubject: ""
    }
  }

  private var tonePresets: [ComposeAssistancePreset] {
    [.professional, .friendly, .direct, .empathetic, .neutral]
  }

  private var assistanceIsUnavailable: Bool {
    if case .unavailable = assistanceViewModel.availability { return true }
    return false
  }

  private var applicationTitle: String {
    switch application {
    case .insert: "Insert"
    case .replaceSubject: "Use Subject"
    case .replaceTarget: "Replace"
    }
  }

  private func checkAvailability() async {
    guard assistanceViewModel.isEnabled,
      !assistanceViewModel.contentIsConcealed,
      assistanceViewModel.availability == nil
    else { return }
    await assistanceViewModel.refreshAvailability()
  }

  private func refreshAvailability() {
    Task { await assistanceViewModel.refreshAvailability() }
  }

  private func generate() {
    let target = currentTarget
    guard !command.requiresSelection || target.scope == .selection else {
      localErrorMessage = "Select text in the Draft to use this action."
      return
    }
    Task {
      do {
        let action = command.makeAction(instruction: instruction, tone: selectedTone)
        let request = try ComposeAssistanceRequestBuilder().makeRequest(
          action: action,
          target: target,
          subject: currentSubject(),
          recipientDisplayNames: recipientDisplayNames(),
          profileId: assistanceViewModel.activeProfileId,
          localeIdentifier: Locale.current.identifier
        )
        requestTarget = target
        originalRequest = request
        application = action.application
        localErrorMessage = nil
        _ = await assistanceViewModel.perform(request)
      } catch {
        localErrorMessage =
          (error as? LocalizedError)?.errorDescription
          ?? error.localizedDescription
      }
    }
  }

  private func answerClarification() {
    guard let preview = assistanceViewModel.preview, let originalRequest else {
      localErrorMessage = "Choose a Compose Assistance action before continuing."
      return
    }
    Task {
      do {
        let request = try ComposeAssistanceRequestBuilder().makeRefinementRequest(
          instruction: clarificationAnswer,
          preview: preview,
          originalRequest: originalRequest
        )
        localErrorMessage = nil
        if await assistanceViewModel.perform(request) != nil {
          clarificationAnswer = ""
        }
      } catch {
        localErrorMessage =
          (error as? LocalizedError)?.errorDescription
          ?? error.localizedDescription
      }
    }
  }

  private func acceptPreview() {
    guard let preview = assistanceViewModel.preview,
      let requestTarget,
      !previewIsStale(preview)
    else {
      localErrorMessage = "The Draft changed. Generate a new preview before applying it."
      return
    }
    let didApply: Bool
    switch application {
    case .replaceSubject:
      applySubject(preview.content)
      didApply = true
    case .insert, .replaceTarget:
      let document = preview.semanticDocument ?? SemanticMessageDocument(plainText: preview.content)
      didApply = editorModel.applyAssistanceDocument(
        document,
        application: application,
        target: requestTarget
      )
    }
    guard didApply else {
      localErrorMessage = "The Draft changed. Generate a new preview before applying it."
      return
    }
    dismiss()
  }

  private func previewIsStale(_ preview: MailAssistancePreview) -> Bool {
    guard let requestTarget else { return true }
    let inputVersion = ComposeAssistanceRequestBuilder.inputVersion(
      document: editorModel.document,
      target: requestTarget,
      subject: currentSubject(),
      recipientDisplayNames: recipientDisplayNames()
    )
    return preview.applicationStatus(
      profileId: assistanceViewModel.activeProfileId,
      inputVersion: inputVersion
    ) == .stale
  }
}
// swiftlint:enable type_body_length
