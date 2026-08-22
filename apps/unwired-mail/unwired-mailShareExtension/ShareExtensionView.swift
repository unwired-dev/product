import SwiftUI

/// Native Share Extension UI that saves a Draft without exposing a send action.
struct ShareExtensionView: View {
  @State private var viewModel: ShareExtensionViewModel
  let cancel: () -> Void
  let openDraft: (URL) -> Void

  /// Creates the extension view with one owned MVVM boundary.
  init(
    viewModel: ShareExtensionViewModel,
    cancel: @escaping () -> Void,
    openDraft: @escaping (URL) -> Void
  ) {
    _viewModel = State(initialValue: viewModel)
    self.cancel = cancel
    self.openDraft = openDraft
  }

  var body: some View {
    NavigationStack {
      Group {
        switch viewModel.loadState {
        case .idle, .loading:
          ProgressView("Preparing Draft…")
            .accessibilityIdentifier("share-extension-loading")
        case .ready:
          ShareExtensionDraftForm(viewModel: viewModel)
        case .failed:
          ContentUnavailableView(
            "Draft Unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text(viewModel.errorMessage ?? "Open Unwired Mail and try again.")
          )
        }
      }
      .navigationTitle("New Draft")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: cancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save Draft", action: saveDraft)
            .disabled(!viewModel.canSave)
            .accessibilityIdentifier("share-extension-save-draft")
        }
      }
    }
    .task { await viewModel.load() }
  }

  private func saveDraft() {
    Task {
      if let url = await viewModel.save() {
        openDraft(url)
      }
    }
  }
}
