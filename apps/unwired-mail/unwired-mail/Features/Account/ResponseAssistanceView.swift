import SwiftUI

struct ResponseAssistanceContext {
  let localBodyText: (StableProviderMessageIdentity) -> String?
  let thread: () -> MailboxThread?
}

struct ResponseAssistancePresentation: Identifiable {
  let context: ResponseAssistanceContext
  let id = UUID()
  let localeIdentifier: String
  let profileId: MailProfileId
}

private struct ResponseAssistanceSourcePresentation: Identifiable {
  let body: String
  let id: String
}

// swiftlint:disable:next type_body_length
struct ResponseAssistanceView: View {
  let presentation: ResponseAssistancePresentation
  @Bindable var assistanceViewModel: MailAssistanceViewModel
  let draft: () -> MailShellCompositionDraft
  let applyDocument: (SemanticMessageDocument) -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var editablePreview: ResponseAssistancePreviewSelection?
  @State private var localErrorMessage: String?
  @State private var originalRequest: MailAssistanceRequest?
  @State private var sourceMessage: ResponseAssistanceSourcePresentation?

  var body: some View {
    NavigationStack {
      Group {
        if assistanceViewModel.phase == .generating {
          ProgressView("Preparing response options…")
            .accessibilityLabel("Preparing response options")
        } else if let localErrorMessage {
          unavailableContent(message: localErrorMessage)
        } else if let errorMessage = assistanceViewModel.errorMessage {
          unavailableContent(message: errorMessage)
        } else if let preview = assistanceViewModel.preview {
          previewContent(preview)
        } else {
          unavailableContent(message: assistanceViewModel.statusMessage)
        }
      }
      .navigationTitle("Response Assistance")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close", action: close)
        }
      }
      .task { generate() }
      .onDisappear(perform: destroyEphemeralState)
      .sheet(item: $editablePreview) { selection in
        ResponseAssistancePreviewView(
          selection: selection,
          isStale: { previewIsStale(inputVersion: selection.inputVersion) },
          apply: applyDocument
        )
      }
      .sheet(item: $sourceMessage) { source in
        NavigationStack {
          ScrollView {
            Text(source.body)
              .textSelection(.enabled)
              .padding(16)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .navigationTitle("Local Source")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { sourceMessage = nil }
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func previewContent(_ preview: MailAssistancePreview) -> some View {
    if previewIsStale(inputVersion: preview.inputVersion) {
      ContentUnavailableView {
        Label("Draft or Thread changed", systemImage: "arrow.clockwise")
      } description: {
        Text("Generate new response options before using this result.")
      } actions: {
        Button("Regenerate", action: generate)
          .buttonStyle(.borderedProminent)
      }
    } else if preview.kind == .clarification {
      ContentUnavailableView {
        Label("More detail needed", systemImage: "questionmark.bubble")
      } description: {
        Text(preview.content)
      } actions: {
        Button("Edit Draft", action: close)
          .buttonStyle(.borderedProminent)
      }
    } else if let result = preview.response {
      resultContent(result, inputVersion: preview.inputVersion)
    } else {
      unavailableContent(message: "No response options were produced.")
    }
  }

  private func resultContent(
    _ result: ResponseAssistanceResult,
    inputVersion: MailAssistanceInputVersion
  ) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 6) {
          Label("Choose a response direction", systemImage: "sparkles")
            .font(.headline)
          Text(
            "Each choice opens an identified, editable preview. Nothing is inserted or sent yet."
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }

        ForEach(result.suggestions) { suggestion in
          responseButton(
            title: suggestion.intent,
            document: suggestion.document,
            inputVersion: inputVersion
          )
        }

        responseButton(
          title: "Full Contextual Reply",
          document: result.fullReply,
          inputVersion: inputVersion
        )

        completenessSection(result)
        scopeSection(result.scope)
      }
      .padding(16)
    }
  }

  private func responseButton(
    title: String,
    document: SemanticMessageDocument,
    inputVersion: MailAssistanceInputVersion
  ) -> some View {
    Button {
      editablePreview = ResponseAssistancePreviewSelection(
        document: document,
        inputVersion: inputVersion,
        title: title
      )
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        Label(title, systemImage: "text.bubble")
          .font(.headline)
        Text(document.attributedText)
          .lineLimit(4)
          .foregroundStyle(.primary)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens an editable Assistance Preview")
  }

  private func completenessSection(_ result: ResponseAssistanceResult) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Answer Completeness")
        .font(.headline)
      Text("Read-only check of explicit questions and requests in the analyzed local sources.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if result.completenessItems.isEmpty {
        Text("No explicit questions or requests were identified.")
          .foregroundStyle(.secondary)
      }
      ForEach(result.completenessItems) { item in
        VStack(alignment: .leading, spacing: 8) {
          Label(
            item.status == .addressed ? "Addressed" : "Unresolved",
            systemImage: item.status == .addressed ? "checkmark.circle" : "questionmark.circle"
          )
          .font(.subheadline)
          Text(item.text)
          ForEach(item.sourceMessageIds, id: \.self) { sourceMessageId in
            if let source = result.scope.includedSources.first(where: {
              $0.messageId == sourceMessageId
            }) {
              sourceButton(source)
            }
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
      }
    }
  }

  private func sourceButton(_ source: ResponseAssistanceSource) -> some View {
    Button {
      guard
        let source = originalRequest?.context.sourceMessages.first(where: {
          $0.sourceMessageId == source.messageId
        })
      else { return }
      sourceMessage = ResponseAssistanceSourcePresentation(
        body: source.body,
        id: source.sourceMessageId ?? UUID().uuidString
      )
    } label: {
      Label(source.senderDisplayName ?? "Unknown sender", systemImage: "arrow.up.message")
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(source.accessibilityLabel)
  }

  private func scopeSection(_ scope: ResponseAssistanceScope) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Analyzed Sources")
        .font(.headline)
      Text("Analyzed \(scope.includedSources.count) of \(scope.totalThreadMessageCount) messages.")
      if scope.unavailableLocalMessageCount > 0 {
        Text(
          "\(scope.unavailableLocalMessageCount) message bodies were unavailable locally and were not fetched."
        )
      }
      if scope.omittedForLimitMessageCount > 0 {
        Text(
          "\(scope.omittedForLimitMessageCount) older local messages were outside the on-device limit."
        )
      }
      if scope.hasOmittedContent {
        Text("This result does not cover the full Thread.")
          .bold()
      }
    }
    .font(.subheadline)
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: .rect(cornerRadius: 10))
  }

  private func unavailableContent(message: String) -> some View {
    ContentUnavailableView {
      Label("Response Assistance unavailable", systemImage: "sparkles")
    } description: {
      Text(message)
    } actions: {
      Button("Try Again", action: generate)
        .buttonStyle(.borderedProminent)
    }
  }

  private func generate() {
    assistanceViewModel.discardPreview()
    editablePreview = nil
    localErrorMessage = nil
    Task {
      do {
        let request = try makeRequest()
        originalRequest = request
        _ = await assistanceViewModel.perform(request)
      } catch is CancellationError {
      } catch {
        localErrorMessage =
          (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
    }
  }

  private func makeRequest() throws -> MailAssistanceRequest {
    guard let thread = presentation.context.thread() else {
      throw MailAssistanceError.invalidInputVersion
    }
    return try ResponseAssistanceRequestBuilder().makeRequest(
      for: thread,
      draft: draft(),
      profileId: presentation.profileId,
      localeIdentifier: presentation.localeIdentifier,
      localBodyText: presentation.context.localBodyText
    )
  }

  private func previewIsStale(inputVersion: MailAssistanceInputVersion) -> Bool {
    guard let request = try? makeRequest() else { return true }
    return inputVersion != request.context.inputVersion
      || presentation.profileId != assistanceViewModel.activeProfileId
  }

  private func close() {
    destroyEphemeralState()
    dismiss()
  }

  private func destroyEphemeralState() {
    assistanceViewModel.discardPreview()
    editablePreview = nil
    originalRequest = nil
    sourceMessage = nil
  }
}
