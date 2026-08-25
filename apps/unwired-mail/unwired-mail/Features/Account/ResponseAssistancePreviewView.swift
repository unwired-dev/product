import SwiftUI

struct ResponseAssistancePreviewSelection: Identifiable {
  let document: SemanticMessageDocument
  let id = UUID()
  let inputVersion: MailAssistanceInputVersion
  let title: String
}

struct ResponseAssistancePreviewView: View {
  let selection: ResponseAssistancePreviewSelection
  let isStale: () -> Bool
  let apply: (SemanticMessageDocument) -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var editorModel: SemanticMessageEditorModel
  @State private var errorMessage: String?

  init(
    selection: ResponseAssistancePreviewSelection,
    isStale: @escaping () -> Bool,
    apply: @escaping (SemanticMessageDocument) -> Bool
  ) {
    self.selection = selection
    self.isStale = isStale
    self.apply = apply
    _editorModel = State(
      initialValue: SemanticMessageEditorModel(document: selection.document)
    )
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          Label("Assistance Preview", systemImage: "sparkles")
            .font(.headline)
          Text(selection.title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text("Edit this preview before adding it to the Draft. Nothing is sent.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)

        Divider()

        TextEditor(text: $editorModel.attributedText, selection: $editorModel.selection)
          .padding(16)
          .accessibilityLabel("Editable \(selection.title) Assistance Preview")
          .onChange(of: editorModel.attributedText, editorModel.textDidChange)
      }
      .navigationTitle("Response Preview")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close", action: dismiss.callAsFunction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Use in Draft", action: accept)
            .disabled(isStale())
        }
      }
      .safeAreaInset(edge: .bottom) {
        if isStale() {
          Label(
            "The Draft or local Thread changed. Choose a new response before applying.",
            systemImage: "arrow.clockwise"
          )
          .font(.footnote)
          .padding(12)
          .frame(maxWidth: .infinity)
          .background(.bar)
        } else if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
      }
    }
  }

  private func accept() {
    guard !isStale() else {
      errorMessage = "The Draft or local Thread changed. Choose a new response."
      return
    }
    guard apply(editorModel.document) else {
      errorMessage = "The Draft changed before the response could be applied."
      return
    }
    dismiss()
  }
}
