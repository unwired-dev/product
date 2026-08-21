import SwiftUI

struct MailProfileInterruptionSettingsView: View {
  @Bindable var viewModel: MailProfileInterruptionViewModel
  @State private var quietUntil = Date.now.addingTimeInterval(60 * 60)

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        profileHeader
        quietControls
        lockControls
        spotlightControls

        if let errorMessage = viewModel.errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityIdentifier("mail-profile-interruption-error")
        }
      }
      .padding(24)
      .frame(maxWidth: 720, alignment: .topLeading)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .navigationTitle("Quiet & Profile Lock")
  }

  private var profileHeader: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(
        viewModel.activeProfile.name, systemImage: viewModel.activeProfile.appearance.symbolName
      )
      .font(.title2.bold())
      Text("Quiet synchronizes between Trusted Devices. Profile Lock stays only on this device.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private var quietControls: some View {
    GroupBox("Quiet") {
      VStack(alignment: .leading, spacing: 12) {
        Text(quietSummary)
          .font(.subheadline)
          .foregroundStyle(.secondary)

        DatePicker(
          "Quiet Until",
          selection: $quietUntil,
          in: Date.now...,
          displayedComponents: [.date, .hourAndMinute]
        )

        HStack {
          Button("Quiet Until Then") {
            Task { await viewModel.setQuiet(until: quietUntil) }
          }
          .buttonStyle(.borderedProminent)
          .disabled(viewModel.isSavingQuietState)

          Button("Quiet Indefinitely") {
            Task { await viewModel.setQuiet(until: nil) }
          }
          .buttonStyle(.bordered)
          .disabled(viewModel.isSavingQuietState)
        }

        Button("Resume Interruptions") {
          Task { await viewModel.resumeInterruptions() }
        }
        .disabled(!viewModel.quietIsActive || viewModel.isSavingQuietState)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
    }
  }

  private var lockControls: some View {
    GroupBox("Profile Lock") {
      VStack(alignment: .leading, spacing: 12) {
        Text(
          "Require Face ID, Touch ID, or the device passcode before this Profile's content "
            + "is shown. Synchronization and delivery continue while locked."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)

        Button(
          viewModel.lockConfiguration.isEnabled ? "Disable Profile Lock" : "Enable Profile Lock"
        ) {
          Task { await viewModel.setLockEnabled(!viewModel.lockConfiguration.isEnabled) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.isAuthenticating)

        Picker(
          "Lock After Backgrounding",
          selection: Binding(
            get: { viewModel.lockConfiguration.backgroundGracePeriod },
            set: { viewModel.setBackgroundGracePeriod($0) }
          )
        ) {
          ForEach(MailProfileBackgroundGracePeriod.allCases, id: \.self) { gracePeriod in
            Text(gracePeriod.title).tag(gracePeriod)
          }
        }
        .disabled(!viewModel.lockConfiguration.isEnabled)

        Button("Lock Now", systemImage: "lock.fill") {
          Task { await viewModel.lockExplicitly() }
        }
        .disabled(!viewModel.lockConfiguration.isEnabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
    }
  }

  private var spotlightControls: some View {
    GroupBox("Spotlight") {
      VStack(alignment: .leading, spacing: 12) {
        Toggle(
          "Show Messages in Spotlight",
          isOn: Binding(
            get: { viewModel.spotlightIndexingIsEnabled },
            set: { isEnabled in
              Task { await viewModel.setSpotlightIndexingEnabled(isEnabled) }
            }
          )
        )

        Text(
          "Indexes sender, recipients, subject, date, Profile, and Mailbox Connection "
            + "on this device. Message bodies and attachments stay out of Spotlight. "
            + "Profile Lock removes this Profile's results while locked."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
    }
  }

  private var quietSummary: String {
    guard viewModel.quietIsActive else {
      return "Interruptions and proactive suggestions are active."
    }
    if let quietEndDate = viewModel.quietEndDate {
      return "Visible notifications and proactive suggestions are quiet until "
        + quietEndDate.formatted(date: .abbreviated, time: .shortened) + "."
    }
    return "Visible notifications and proactive suggestions are quiet until you resume them."
  }
}

struct MailProfileLockedView: View {
  @Bindable var viewModel: MailProfileInterruptionViewModel

  var body: some View {
    ContentUnavailableView {
      Label("Profile Locked", systemImage: "lock.shield")
    } description: {
      Text("Unlock \(viewModel.activeProfile.name) to reveal mail and search.")
    } actions: {
      Button("Unlock \(viewModel.activeProfile.name)") {
        Task { await viewModel.unlock() }
      }
      .buttonStyle(.borderedProminent)
      .disabled(viewModel.isAuthenticating)

      if viewModel.isAuthenticating {
        ProgressView("Authenticating…")
      }

      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    }
    .accessibilityIdentifier("mail-profile-locked")
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }
}
