import SwiftUI

struct PrivacyDataSettingsView: View {
  let connections: [MailboxConnection]
  let storageSession: ProductAccountSessionSnapshot?
  let storageViewModel: StorageDataSettingsViewModel?

  @Environment(MessageContentPreferences.self) private var preferences

  init(
    connections: [MailboxConnection],
    storageSession: ProductAccountSessionSnapshot? = nil,
    storageViewModel: StorageDataSettingsViewModel? = nil
  ) {
    self.connections = connections
    self.storageSession = storageSession
    self.storageViewModel = storageViewModel
  }

  var body: some View {
    @Bindable var preferences = preferences

    Form {
      Section {
        Picker("Remote Message Content", selection: $preferences.remoteContentPolicy) {
          ForEach(RemoteContentLoadPolicy.allCases) { policy in
            Text(policy.title).tag(policy)
          }
        }
      } footer: {
        Text(
          "Loading remote content reveals this device's IP address and may tell the sender "
            + "that you opened the message. Ask applies consent to one message view only."
        )
      }

      if !connections.isEmpty {
        Section("Connection Overrides") {
          ForEach(sortedConnections) { connection in
            Picker(
              connection.displayName,
              selection: remoteContentOverrideBinding(for: connection.id)
            ) {
              Text("Use \(preferences.remoteContentPolicy.title)")
                .tag(Optional<RemoteContentLoadPolicy>.none)
              ForEach(RemoteContentLoadPolicy.allCases) { policy in
                Text(policy.title).tag(Optional(policy))
              }
            }
          }
        }
      }

      Section {
        Label("Known Tracking Pixels Blocked", systemImage: "checkmark.shield")
      } footer: {
        Text("Known Tracking Pixels stay blocked for every remote-content policy.")
      }

      Section {
        Picker("Attachment Downloads", selection: $preferences.attachmentDownloadPolicy) {
          ForEach(AttachmentDownloadPolicy.allCases) { policy in
            Text(policy.title).tag(policy)
          }
        }
      } footer: {
        Text(
          "On Demand downloads only after you choose an attachment. Wi-Fi and Always "
            + "allow automatic downloads only while the selected network is available."
        )
      }

      Section {
        if let storageSession, let storageViewModel {
          NavigationLink {
            StorageDataSettingsView(
              session: storageSession,
              viewModel: storageViewModel
            )
          } label: {
            Label("Storage & Product Sync Data", systemImage: "externaldrive")
          }
        } else {
          Label("Sign in to inspect storage and export Product Sync data", systemImage: "lock")
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("Storage & Export")
      } footer: {
        Text(
          "Inspect device-local mail storage, clear downloadable copies, and export "
            + "end-to-end encrypted Product Sync data on a Trusted Device."
        )
      }

      Section("Privacy Boundary") {
        Text("Message content is never sent to the product backend for AI processing.")
      }
    }
  }

  private var sortedConnections: [MailboxConnection] {
    connections.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  private func remoteContentOverrideBinding(
    for connectionId: MailboxConnectionId
  ) -> Binding<RemoteContentLoadPolicy?> {
    Binding(
      get: { preferences.remoteContentOverride(for: connectionId) },
      set: { preferences.setRemoteContentOverride($0, for: connectionId) }
    )
  }
}
