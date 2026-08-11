import SwiftUI

struct InboxSettingsView: View {
  @Bindable var store: InboxPreferenceStore
  @Bindable var featureSuggestionStore: FeatureSuggestionPreferenceStore
  var navigationRequest: SettingsRouteRequest?

  @State private var highlightTask: Task<Void, Never>?
  @State private var highlightedField: InboxPreferenceField?

  init(
    store: InboxPreferenceStore,
    featureSuggestionStore: FeatureSuggestionPreferenceStore,
    navigationRequest: SettingsRouteRequest? = nil
  ) {
    self.store = store
    self.featureSuggestionStore = featureSuggestionStore
    self.navigationRequest = navigationRequest
  }

  var body: some View {
    ScrollViewReader { proxy in
      Form {
        Section {
          Picker("Density", selection: threadDensity) {
            ForEach(InboxThreadDensity.allCases) { density in
              Text(density.title).tag(density)
            }
          }
          .pickerStyle(.segmented)
          .id(InboxPreferenceField.threadDensity)
          .settingsHighlight(highlightedField == .threadDensity)

          Picker("Preview", selection: previewLength) {
            ForEach(InboxPreviewLength.allCases) { length in
              Text(length.title).tag(length)
            }
          }
          .id(InboxPreferenceField.previewLength)
          .settingsHighlight(highlightedField == .previewLength)

          Toggle("Show Contact Images", isOn: showsContactImages)
            .id(InboxPreferenceField.contactImages)
            .settingsHighlight(highlightedField == .contactImages)
          Toggle("Show Category Badges", isOn: showsCategoryBadges)
            .id(InboxPreferenceField.categoryBadges)
            .settingsHighlight(highlightedField == .categoryBadges)
          Toggle("Show Attachment Indicators", isOn: showsAttachmentIndicators)
            .id(InboxPreferenceField.attachmentIndicators)
            .settingsHighlight(highlightedField == .attachmentIndicators)
        } header: {
          Text("Thread List")
        } footer: {
          Text(
            "Thread grouping, newest-message ordering, source Mailbox Connection identity, "
              + "and newest-message expansion stay fixed."
          )
        }

        Section {
          Toggle("Suggest Unsubscribe", isOn: suggestsUnsubscribe)
        } header: {
          Text("Suggestions")
        } footer: {
          Text(
            "Unsubscribe suggestions are detected on this device from mailing-list headers. "
              + "Requests and message content are never sent to the product backend."
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
            Text(
              "Both values are preserved until you choose which one should synchronize."
            )
          }
        }
      }
      .onChange(of: navigationRequest?.id, initial: true) { _, _ in
        applyNavigation(navigationRequest?.route, proxy: proxy)
      }
    }
    .navigationTitle("Inbox")
    .onDisappear {
      highlightTask?.cancel()
    }
  }

  @ViewBuilder
  private var synchronizationSection: some View {
    if store.isSynchronizing || store.hasPendingChanges || store.errorMessage != nil
      || featureSuggestionStore.isSynchronizing
      || featureSuggestionStore.hasPendingChanges
      || featureSuggestionStore.errorMessage != nil
    {
      Section("Synchronization") {
        if store.isSynchronizing || featureSuggestionStore.isSynchronizing {
          Label("Synchronizing encrypted preferences…", systemImage: "arrow.triangle.2.circlepath")
        } else if store.hasPendingChanges || featureSuggestionStore.hasPendingChanges {
          Label("Changes are saved on this device and waiting to sync.", systemImage: "clock")
        }
        if let errorMessage = store.errorMessage ?? featureSuggestionStore.errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
          Button("Try Again") {
            Task {
              await store.synchronize()
              await featureSuggestionStore.synchronize()
            }
          }
          .disabled(store.isSynchronizing || featureSuggestionStore.isSynchronizing)
        }
      }
    }
  }

  private func conflictView(_ conflict: InboxPreferenceConflict) -> some View {
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

  private var threadDensity: Binding<InboxThreadDensity> {
    Binding(
      get: { store.preferences.threadDensity },
      set: store.setThreadDensity
    )
  }

  private var previewLength: Binding<InboxPreviewLength> {
    Binding(
      get: { store.preferences.previewLength },
      set: store.setPreviewLength
    )
  }

  private var showsContactImages: Binding<Bool> {
    Binding(
      get: { store.preferences.showsContactImages },
      set: store.setShowsContactImages
    )
  }

  private var showsCategoryBadges: Binding<Bool> {
    Binding(
      get: { store.preferences.showsCategoryBadges },
      set: store.setShowsCategoryBadges
    )
  }

  private var showsAttachmentIndicators: Binding<Bool> {
    Binding(
      get: { store.preferences.showsAttachmentIndicators },
      set: store.setShowsAttachmentIndicators
    )
  }

  private var suggestsUnsubscribe: Binding<Bool> {
    Binding(
      get: { featureSuggestionStore.preferences.isEnabled(.unsubscribe) },
      set: { featureSuggestionStore.setEnabled($0, feature: .unsubscribe) }
    )
  }

  private func applyNavigation(
    _ route: SettingsRoute?,
    proxy: ScrollViewProxy
  ) {
    guard case .preferenceConflict(let rawField) = route?.context,
      let field = InboxPreferenceField(rawValue: rawField)
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
