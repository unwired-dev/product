import SwiftUI

/// Profile, identity, content summary, and actionable error controls for share intake.
struct ShareExtensionDraftForm: View {
  @Bindable var viewModel: ShareExtensionViewModel

  var body: some View {
    Form {
      Section {
        LabeledContent("Mail Profile") {
          Menu(
            viewModel.selectedProfile?.name ?? "Choose Profile",
            systemImage: viewModel.selectedProfile?.symbolName ?? "person.crop.circle"
          ) {
            ForEach(viewModel.profiles) { profile in
              Button(profile.name, systemImage: profile.symbolName) {
                Task { await viewModel.selectProfile(profile.id) }
              }
            }
          }
          .accessibilityIdentifier("share-extension-profile")
        }

        if viewModel.selectedProfileIsUnlocked {
          Picker(
            "Sending Identity",
            selection: $viewModel.selectedIdentityId
          ) {
            ForEach(viewModel.selectedProfile?.sendingIdentities ?? []) { identity in
              Text(identity.title).tag(identity.id as String?)
            }
          }
          .accessibilityIdentifier("share-extension-identity")
        } else if let profile = viewModel.selectedProfile {
          LabeledContent {
            Button("Unlock \(profile.name)") {
              Task { await viewModel.unlockSelectedProfile() }
            }
            .buttonStyle(.borderedProminent)
          } label: {
            Label("Profile Locked", systemImage: "lock.shield")
          }
          .accessibilityIdentifier("share-extension-profile-locked")
        }
      } header: {
        Text("Draft Owner")
      } footer: {
        Text(
          "The Draft uses the selected Profile and From address. You can edit it before sending.")
      }

      Section("Shared Content") {
        LabeledContent("Items", value: viewModel.inputCount.formatted())
        Label("Saved as an editable Draft", systemImage: "doc.text")
          .foregroundStyle(.secondary)
      }

      if let errorMessage = viewModel.errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .accessibilityIdentifier("share-extension-error")
        }
      }
    }
    .disabled(viewModel.saveState == .saving)
    .overlay {
      if viewModel.saveState == .saving {
        ProgressView("Saving Draft…")
          .padding()
          .background(.regularMaterial)
          .clipShape(.rect(cornerRadius: 10))
          .accessibilityIdentifier("share-extension-saving")
      }
    }
  }
}
