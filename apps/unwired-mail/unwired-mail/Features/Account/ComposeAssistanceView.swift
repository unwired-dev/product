import SwiftUI

struct ComposeAssistancePresentation: Identifiable {
  let id = UUID()
  let localeIdentifier: String
  let profileId: MailProfileId
  let recipientDisplayNames: [String]
  let subject: String
  let target: ComposeAssistanceTarget
}

// swiftlint:disable:next type_body_length
struct ComposeAssistanceView: View {
  let presentation: ComposeAssistancePresentation
  @Bindable var assistanceViewModel: MailAssistanceViewModel
  let currentInputVersion: () -> MailAssistanceInputVersion
  let applyDocument:
    (SemanticMessageDocument, ComposeAssistanceApplication, ComposeAssistanceTarget) -> Bool
  let applySubject: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var application = ComposeAssistanceApplication.replaceTarget
  @State private var freeformInstruction = ""
  @State private var localErrorMessage: String?
  @State private var originalRequest: MailAssistanceRequest?
  @State private var prompt = ""
  @State private var refinementInstruction = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("Target") {
          LabeledContent("Editing", value: presentation.target.title)
          Text(
            "Only the editable authored body or selected text is included. "
              + "Recipients, signatures, quoted mail, and attachments stay unchanged."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }

        if !assistanceViewModel.isEnabled || assistanceViewModel.contentIsConcealed {
          Section {
            Label(assistanceViewModel.statusMessage, systemImage: "sparkles")
          }
        } else if assistanceViewModel.phase == .checkingAvailability {
          Section {
            ProgressView("Checking On-Device Availability…")
              .accessibilityLabel("Checking On-Device Availability")
          }
        } else if assistanceIsUnavailable {
          Section {
            Label(assistanceViewModel.statusMessage, systemImage: "sparkles")
            Button("Try Again") {
              Task { await assistanceViewModel.refreshAvailability() }
            }
          }
        } else if assistanceViewModel.phase == .generating {
          Section {
            ProgressView("Creating Assistance Preview…")
              .accessibilityLabel("Creating Assistance Preview")
            Button("Cancel", role: .cancel, action: resetPreview)
          }
        } else if let preview = assistanceViewModel.preview {
          previewSections(preview)
        } else {
          actionSections
        }

        if let errorMessage = localErrorMessage ?? assistanceViewModel.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Compose Assistance")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close", action: close)
        }
      }
      .onChange(of: assistanceViewModel.contentIsConcealed) { _, isConcealed in
        if isConcealed { close() }
      }
      .task {
        guard assistanceViewModel.isEnabled,
          !assistanceViewModel.contentIsConcealed,
          assistanceViewModel.availability == nil
        else { return }
        await assistanceViewModel.refreshAvailability()
      }
      .onDisappear(perform: destroyEphemeralState)
    }
  }

  @ViewBuilder
  private var actionSections: some View {
    Section("Draft Body") {
      TextField("Describe the body you want to draft", text: $prompt, axis: .vertical)
        .lineLimit(3...6)
      Button("Generate Body", systemImage: "text.badge.plus") {
        perform(.generateBody(prompt: prompt))
      }
      Button("Suggest Subject", systemImage: "textformat") {
        perform(.suggestSubject)
      }
    }

    Section("Review") {
      Button("Proofread", systemImage: "checkmark.circle") {
        perform(.proofread)
      }
    }

    Section("Rewrite") {
      ForEach(ComposeAssistancePreset.allCases) { preset in
        Button(preset.title) {
          perform(.transform(preset))
        }
      }
      TextField("Describe another change", text: $freeformInstruction, axis: .vertical)
        .lineLimit(2...4)
      Button("Refine Text", systemImage: "slider.horizontal.3") {
        perform(.refine(instruction: freeformInstruction))
      }
    }
  }

  @ViewBuilder
  private func previewSections(_ preview: MailAssistancePreview) -> some View {
    Section {
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
      if previewIsStale(preview) {
        Label(
          "The Draft changed. Generate a new preview before applying it.",
          systemImage: "arrow.clockwise"
        )
        .foregroundStyle(.secondary)
      }
    } header: {
      Text("Preview")
    } footer: {
      Text("This preview is not saved in the Draft until you accept it.")
    }

    Section("Refine Preview") {
      TextField(
        preview.kind == .clarification
          ? "Answer the clarification"
          : "Describe another change",
        text: $refinementInstruction,
        axis: .vertical
      )
      .lineLimit(2...5)
      Button("Refine Preview", systemImage: "arrow.triangle.2.circlepath") {
        refine(preview)
      }
    }

    Section {
      if preview.kind == .content {
        Button(applicationTitle, action: acceptPreview)
          .disabled(previewIsStale(preview))
      }
      Button("Choose Another Action", action: resetPreview)
    }
  }

  private var applicationTitle: String {
    switch application {
    case .insert: "Insert"
    case .replaceSubject: presentation.subject.isEmpty ? "Add Subject" : "Replace Subject"
    case .replaceTarget: "Replace"
    }
  }

  private var assistanceIsUnavailable: Bool {
    if case .unavailable = assistanceViewModel.availability { return true }
    return false
  }

  private func perform(_ action: ComposeAssistanceAction) {
    Task {
      do {
        let request = try ComposeAssistanceRequestBuilder().makeRequest(
          action: action,
          target: presentation.target,
          subject: presentation.subject,
          recipientDisplayNames: presentation.recipientDisplayNames,
          profileId: presentation.profileId,
          localeIdentifier: presentation.localeIdentifier
        )
        originalRequest = request
        application = action.application
        localErrorMessage = nil
        if await assistanceViewModel.perform(request) != nil {
          prompt = ""
          freeformInstruction = ""
        }
      } catch {
        localErrorMessage = error.localizedDescription
      }
    }
  }

  private func refine(_ preview: MailAssistancePreview) {
    guard let originalRequest else {
      localErrorMessage = "Choose an Assistance action before refining its preview."
      return
    }
    Task {
      do {
        let request = try ComposeAssistanceRequestBuilder().makeRefinementRequest(
          instruction: refinementInstruction,
          preview: preview,
          originalRequest: originalRequest
        )
        localErrorMessage = nil
        if await assistanceViewModel.perform(request) != nil {
          refinementInstruction = ""
        }
      } catch {
        localErrorMessage = error.localizedDescription
      }
    }
  }

  private func acceptPreview() {
    guard let preview = assistanceViewModel.preview, !previewIsStale(preview) else {
      localErrorMessage = "The Draft changed. Generate a new preview before applying it."
      return
    }
    let didApply: Bool
    switch application {
    case .replaceSubject:
      applySubject(preview.content)
      didApply = true
    case .insert, .replaceTarget:
      let document =
        preview.semanticDocument
        ?? SemanticMessageDocument(plainText: preview.content)
      didApply = applyDocument(document, application, presentation.target)
    }
    guard didApply else {
      localErrorMessage = "The Draft changed. Generate a new preview before applying it."
      return
    }
    assistanceViewModel.discardPreview()
    dismiss()
  }

  private func previewIsStale(_ preview: MailAssistancePreview) -> Bool {
    preview.applicationStatus(
      profileId: assistanceViewModel.activeProfileId,
      inputVersion: currentInputVersion()
    ) == .stale
  }

  private func resetPreview() {
    assistanceViewModel.discardPreview()
    originalRequest = nil
    localErrorMessage = nil
    refinementInstruction = ""
  }

  private func close() {
    destroyEphemeralState()
    dismiss()
  }

  private func destroyEphemeralState() {
    assistanceViewModel.discardPreview()
    originalRequest = nil
    prompt = ""
    freeformInstruction = ""
    refinementInstruction = ""
  }
}
