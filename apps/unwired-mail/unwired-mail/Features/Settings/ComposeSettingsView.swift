import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct ComposeSettingsView: View {
  @Bindable var store: ComposePreferenceStore
  var navigationRequest: SettingsRouteRequest?

  @Environment(\.openURL) private var openURL
  @State private var highlightTask: Task<Void, Never>?
  @State private var highlightedField: ComposePreferenceField?
  @State private var showsSystemSettingsError = false

  init(
    store: ComposePreferenceStore,
    navigationRequest: SettingsRouteRequest? = nil
  ) {
    self.store = store
    self.navigationRequest = navigationRequest
  }

  var body: some View {
    ScrollViewReader { proxy in
      Form {
        Section {
          Picker("Undo Send", selection: undoSendWindow) {
            ForEach(UndoSendWindow.allCases) { window in
              Text(window.title).tag(window)
            }
          }
          .id(ComposePreferenceField.undoSend)
          .settingsHighlight(highlightedField == .undoSend)
        } footer: {
          Text(
            "Undo Send delays provider handoff. Cancelling during this window prevents delivery; "
              + "it does not recall mail already accepted by a provider."
          )
        }

        Section("Presentation") {
          Picker("Composer", selection: presentation) {
            ForEach(ComposePresentationPreference.allCases) { presentation in
              Text(presentation.title).tag(presentation)
            }
          }
          .pickerStyle(.segmented)
          .id(ComposePreferenceField.presentation)
          .settingsHighlight(highlightedField == .presentation)

          Toggle("Show Formatting Toolbar", isOn: showsFormattingToolbar)
            .id(ComposePreferenceField.formattingToolbar)
            .settingsHighlight(highlightedField == .formattingToolbar)
        }

        Section {
          Toggle("Include Quoted Text", isOn: includesQuotedText)
            .id(ComposePreferenceField.quotedText)
            .settingsHighlight(highlightedField == .quotedText)
          Toggle("Include Attachments When Forwarding", isOn: includesForwardedAttachments)
            .id(ComposePreferenceField.forwardedAttachments)
            .settingsHighlight(highlightedField == .forwardedAttachments)
        } header: {
          Text("Replies & Forwards")
        } footer: {
          Text("Reply remains the primary action. Quoted text starts collapsed in the composer.")
        }

        Section {
          LabeledContent("Message Format", value: "Rich Text & Plain Text")
          Button("Open System Settings") {
            if let systemSettingsURL {
              openURL(systemSettingsURL) { accepted in
                if !accepted {
                  showsSystemSettingsError = true
                }
              }
            }
          }
          .disabled(systemSettingsURL == nil)
        } footer: {
          Text(
            systemSettingsFooter
              + " Hiding the toolbar does not disable Markdown shortcuts, keyboard or context-menu "
              + "formatting, stored formatting, attachments, or rich delivery."
          )
        }

        synchronizationSection

        if !store.conflicts.isEmpty {
          Section {
            ForEach(store.conflicts) { conflict in
              conflictView(conflict)
                .id(conflict.field)
                .settingsHighlight(highlightedField == conflict.field)
            }
          } header: {
            Text("Resolve Conflicts")
          } footer: {
            Text("Both values are preserved until you choose which one should synchronize.")
          }
        }
      }
      .onChange(of: navigationRequest?.id, initial: true) { _, _ in
        applyNavigation(navigationRequest?.route, proxy: proxy)
      }
    }
    .navigationTitle("Compose")
    .alert("Unable to Open System Settings", isPresented: $showsSystemSettingsError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Open System Settings manually to change spelling and correction preferences.")
    }
    .onDisappear {
      highlightTask?.cancel()
    }
  }

  @ViewBuilder
  private var synchronizationSection: some View {
    if store.isSynchronizing || store.hasPendingChanges || store.errorMessage != nil {
      Section("Synchronization") {
        if store.isSynchronizing {
          Label("Synchronizing encrypted preferences…", systemImage: "arrow.triangle.2.circlepath")
        } else if store.hasPendingChanges {
          Label("Changes are saved on this device and waiting to sync.", systemImage: "clock")
        }
        if let errorMessage = store.errorMessage {
          SettingsInlineErrorView(message: errorMessage, isRetrying: store.isSynchronizing) {
            Task { await store.synchronize() }
          }
        }
      }
    }
  }

  private func conflictView(_ conflict: ComposePreferenceConflict) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(conflict.field.title)
        .font(.headline)
      LabeledContent("This Device", value: conflict.localValue.title)
      LabeledContent("Synced", value: conflict.remoteValue.title)
      HStack {
        Button("Use This Device") {
          store.resolveConflict(conflict.field, useLocalValue: true)
        }
        .buttonStyle(.borderedProminent)
        Button("Use Synced") {
          store.resolveConflict(conflict.field, useLocalValue: false)
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(.vertical, 4)
  }

  private var undoSendWindow: Binding<UndoSendWindow> {
    Binding(
      get: { store.preferences.undoSendWindow },
      set: store.setUndoSendWindow
    )
  }

  private var presentation: Binding<ComposePresentationPreference> {
    Binding(
      get: { store.preferences.presentation },
      set: store.setPresentation
    )
  }

  private var showsFormattingToolbar: Binding<Bool> {
    Binding(
      get: { store.preferences.showsFormattingToolbar },
      set: store.setShowsFormattingToolbar
    )
  }

  private var includesQuotedText: Binding<Bool> {
    Binding(
      get: { store.preferences.includesQuotedText },
      set: store.setIncludesQuotedText
    )
  }

  private var includesForwardedAttachments: Binding<Bool> {
    Binding(
      get: { store.preferences.includesForwardedAttachments },
      set: store.setIncludesForwardedAttachments
    )
  }

  private var systemSettingsURL: URL? {
    #if os(macOS)
      URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    #elseif canImport(UIKit)
      URL(string: UIApplication.openSettingsURLString)
    #else
      nil
    #endif
  }

  private var systemSettingsFooter: String {
    #if os(macOS)
      "Open System Settings attempts to show the Keyboard settings pane."
    #elseif canImport(UIKit)
      "Open System Settings shows this app's page in the Settings app."
    #else
      "Spelling and correction preferences are managed by the operating system."
    #endif
  }

  private func applyNavigation(
    _ route: SettingsRoute?,
    proxy: ScrollViewProxy
  ) {
    guard case .preferenceConflict(let rawField) = route?.context,
      let field = ComposePreferenceField(rawValue: rawField)
    else { return }

    withAnimation {
      proxy.scrollTo(field, anchor: .center)
      highlightedField = field
    }
    highlightTask?.cancel()
    highlightTask = Task {
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else { return }
      withAnimation {
        highlightedField = nil
      }
    }
  }
}
