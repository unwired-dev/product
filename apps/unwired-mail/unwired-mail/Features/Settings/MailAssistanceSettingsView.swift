import SwiftUI

struct MailAssistanceSettingsView: View {
  let profileName: String
  @Bindable var viewModel: MailAssistanceViewModel

  var body: some View {
    Form {
      Section {
        Toggle("Mail Assistance", isOn: $viewModel.isEnabled)
          .accessibilityHint(
            "Controls Mail Assistance only for this Mail Profile on this device."
          )

        LabeledContent("Mail Profile", value: profileName)
      } header: {
        Text("Enablement")
      } footer: {
        Text(
          "The choice stays on this device. Turning it on never starts background analysis, "
            + "indexing, inference, or model preparation."
        )
      }

      Section("Availability") {
        if viewModel.phase == .checkingAvailability {
          ProgressView(viewModel.statusMessage)
        } else {
          Label(
            viewModel.statusMessage,
            systemImage: viewModel.availability == .available
              ? "checkmark.circle" : "exclamationmark.circle"
          )
        }

        Button("Check Availability", systemImage: "arrow.clockwise") {
          Task { await viewModel.refreshAvailability() }
        }
        .disabled(!viewModel.isEnabled || viewModel.contentIsConcealed)
      }

      Section("Use") {
        Text(
          "Assistance runs only when you explicitly request it. Quiet suppresses proactive "
            + "suggestions but never blocks a request you make yourself."
        )
        Text(
          "Locking this Mail Profile cancels active assistance and discards its prompt, "
            + "transcript, and unaccepted preview."
        )
      }
    }
    .navigationTitle("Mail Assistance")
    .task(id: viewModel.activeProfileId) {
      await viewModel.refreshAvailability()
    }
  }
}
