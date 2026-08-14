import SwiftUI

struct InboxSettingsView: View {
  @Bindable var store: InboxPreferenceStore
  @Bindable var featureSuggestionStore: FeatureSuggestionPreferenceStore
  var categoryChoices: [MessageCategoryChoice]
  var navigationRequest: SettingsRouteRequest?

  @State private var highlightTask: Task<Void, Never>?
  @State private var highlightedField: InboxPreferenceField?

  init(
    store: InboxPreferenceStore,
    featureSuggestionStore: FeatureSuggestionPreferenceStore,
    categoryChoices: [MessageCategoryChoice] = MessageCategoryChoice.available(
      customCategories: []
    ),
    navigationRequest: SettingsRouteRequest? = nil
  ) {
    self.store = store
    self.featureSuggestionStore = featureSuggestionStore
    self.categoryChoices = categoryChoices
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
          DisclosureGroup("Important Categories") {
            ForEach(categoryChoices) { choice in
              Toggle(choice.name, isOn: importantCategoryBinding(choice.id))
            }
          }

          ForEach(0..<MailViewConfiguration.configurableSlotCount, id: \.self) { index in
            VStack(alignment: .leading, spacing: 8) {
              Picker("View \(index + 1)", selection: categorySlotBinding(index)) {
                Text("Empty").tag(String?.none)
                ForEach(categoryChoices) { choice in
                  Text(choice.name)
                    .tag(Optional(choice.id))
                    .disabled(isCategoryUsedInAnotherSlot(choice.id, excluding: index))
                }
              }
              HStack {
                Button("Move Earlier", systemImage: "arrow.up") {
                  store.moveMailViewCategory(from: index, to: index - 1)
                }
                .disabled(index == 0)
                Button("Move Later", systemImage: "arrow.down") {
                  store.moveMailViewCategory(from: index, to: index + 1)
                }
                .disabled(index == MailViewConfiguration.configurableSlotCount - 1)
              }
              .labelStyle(.iconOnly)
            }
          }
        } header: {
          Text("Mail Views")
        } footer: {
          Text(
            "Important and All stay first. Choose up to three unique Category views; "
              + "the same configuration applies to every mailbox in this Mail Profile."
          )
        }
        .id(InboxPreferenceField.mailViews)
        .settingsHighlight(highlightedField == .mailViews)

        Section {
          Toggle("Suggest Calendar Events", isOn: suggestsCalendarEvents)
          Toggle("Suggest Add to Contacts", isOn: suggestsContacts)
          Toggle("Suggest Inbox Cleanup", isOn: suggestsInboxCleanup)
          Toggle("Suggest Unsubscribe", isOn: suggestsUnsubscribe)
        } header: {
          Text("Suggestions")
        } footer: {
          Text(
            "Calendar invitations, Contact Candidates, Inbox Cleanup proposals, and unsubscribe "
              + "suggestions are detected on this device. Candidate messages, extracted contact "
              + "and event values, Contacts and Calendar contents, requests, and message content "
              + "are never sent to the product backend."
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
}

extension InboxSettingsView {
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

  private var suggestsCalendarEvents: Binding<Bool> {
    Binding(
      get: { featureSuggestionStore.preferences.isEnabled(.addToCalendar) },
      set: { featureSuggestionStore.setEnabled($0, feature: .addToCalendar) }
    )
  }

  private var suggestsContacts: Binding<Bool> {
    Binding(
      get: { featureSuggestionStore.preferences.isEnabled(.addToContacts) },
      set: { featureSuggestionStore.setEnabled($0, feature: .addToContacts) }
    )
  }

  private var suggestsInboxCleanup: Binding<Bool> {
    Binding(
      get: { featureSuggestionStore.preferences.isEnabled(.inboxCleanup) },
      set: { featureSuggestionStore.setEnabled($0, feature: .inboxCleanup) }
    )
  }

  private func importantCategoryBinding(_ categoryId: String) -> Binding<Bool> {
    Binding(
      get: { store.preferences.mailViewConfiguration.importantCategoryIds.contains(categoryId) },
      set: { store.setImportantMailViewCategory($0, categoryId: categoryId) }
    )
  }

  private func categorySlotBinding(_ index: Int) -> Binding<String?> {
    Binding(
      get: { store.preferences.mailViewConfiguration.categorySlots[index] },
      set: { store.setMailViewCategory($0, at: index) }
    )
  }

  private func isCategoryUsedInAnotherSlot(_ categoryId: String, excluding index: Int) -> Bool {
    store.preferences.mailViewConfiguration.categorySlots.enumerated().contains {
      $0.offset != index && $0.element == categoryId
    }
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
