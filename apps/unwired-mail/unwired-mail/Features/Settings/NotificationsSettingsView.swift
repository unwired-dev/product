import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

// swiftlint:disable type_body_length
struct NotificationsSettingsView: View {
  let categoryChoices: [MessageCategoryChoice]
  let connections: [MailboxConnection]
  let hasLoadedCategory: Bool
  var interruptionViewModel: MailProfileInterruptionViewModel?
  var navigationRequest: SettingsRouteRequest?
  @Bindable var viewModel: NotificationRuleViewModel

  @Environment(\.openURL) private var openURL
  @State private var showsSystemSettingsError = false

  var body: some View {
    Form {
      if let interruptionViewModel {
        Section("Profile Interruptions") {
          NavigationLink {
            MailProfileInterruptionSettingsView(viewModel: interruptionViewModel)
          } label: {
            Label("Quiet & Profile Lock", systemImage: "lock.shield")
          }
        }
      }

      Section {
        LabeledContent("Authorization", value: authorizationTitle)
          .id(SettingsRouteContext.notificationPermission)
        if viewModel.authorizationState == .denied {
          Button("Open System Settings") {
            openNotificationSettings()
          }
        } else if viewModel.authorizationState == .notDetermined {
          Button("Request Notification Permission") {
            Task { await viewModel.requestNotificationAuthorization() }
          }
        }
      } footer: {
        Text(
          "Operating-system permission is device-local. Notification content and rules never "
            + "pass through Product Sync in plaintext."
        )
      }

      Section {
        if viewModel.profiles.count > 1 {
          Picker(
            "Mail Profile",
            selection: Binding(
              get: { viewModel.selectedProfileId },
              set: { profileId in
                guard let profileId else { return }
                Task {
                  await viewModel.selectProfile(
                    profileId,
                    categoryIds: hasLoadedCategory ? Set(categoryChoices.map(\.id)) : nil
                  )
                }
              }
            )
          ) {
            ForEach(viewModel.profiles) { profile in
              Text(profile.name).tag(Optional(profile.id))
            }
          }
          .disabled(viewModel.isEditingDisabled || viewModel.hasUnsavedChanges)
        }

        Toggle(
          "Enable Category-Aware Notifications",
          isOn: Binding(
            get: { viewModel.isNotificationEnabled },
            set: viewModel.setNotificationEnabled
          )
        )
        .disabled(viewModel.isEditingDisabled)

        ForEach(categoryChoices) { category in
          Toggle(
            category.name,
            isOn: Binding(
              get: { viewModel.isEnabled(categoryId: category.id) },
              set: { viewModel.setEnabled($0, categoryId: category.id) }
            )
          )
          .disabled(viewModel.isEditingDisabled || !viewModel.isNotificationEnabled)
        }
      } header: {
        Text(selectedProfilePolicyTitle)
      } footer: {
        Text(
          "The global switch, eligible Categories, and connection overrides synchronize as "
            + "end-to-end encrypted Mail Workflow Preferences."
        )
      }

      if !profileConnections.isEmpty {
        Section("Mailbox Connection Overrides") {
          ForEach(profileConnections) { connection in
            DisclosureGroup(connection.displayName) {
              Toggle(
                "Use Default Profile Policy",
                isOn: Binding(
                  get: { viewModel.usesProfilePolicy(connectionId: connection.id) },
                  set: {
                    viewModel.setUsesProfilePolicy($0, connectionId: connection.id)
                  }
                )
              )
              if let policy = viewModel.connectionPolicies[connection.id.rawValue] {
                Toggle(
                  "Allow Notifications",
                  isOn: Binding(
                    get: { policy.isEnabled },
                    set: { viewModel.setConnectionEnabled($0, connectionId: connection.id) }
                  )
                )
                ForEach(categoryChoices) { category in
                  Toggle(
                    category.name,
                    isOn: Binding(
                      get: { policy.categoryIds.contains(category.id) },
                      set: {
                        viewModel.setConnectionCategoryEnabled(
                          $0,
                          categoryId: category.id,
                          connectionId: connection.id
                        )
                      }
                    )
                  )
                  .disabled(!policy.isEnabled)
                }
              }
            }
          }
        }
        .disabled(viewModel.isEditingDisabled)
      }

      Section("On This Device") {
        Picker("Lock Screen", selection: lockScreenContentLevel) {
          ForEach(NotificationLockScreenContentLevel.allCases) { level in
            Text(level.title).tag(level)
          }
        }
        Toggle("Sound", isOn: isSoundEnabled)
        Toggle("Badge", isOn: isBadgeEnabled)
        Toggle("Quiet Schedule", isOn: quietScheduleEnabled)
        if viewModel.devicePreferences.quietSchedule.isEnabled {
          Picker("Starts", selection: quietScheduleStartMinute) {
            ForEach(quietScheduleMinutes, id: \.self) { minute in
              Text(quietScheduleTitle(minute)).tag(minute)
            }
          }
          Picker("Ends", selection: quietScheduleEndMinute) {
            ForEach(quietScheduleMinutes, id: \.self) { minute in
              Text(quietScheduleTitle(minute)).tag(minute)
            }
          }
          DisclosureGroup("Allowed During Quiet Schedule") {
            ForEach(categoryChoices) { category in
              Toggle(category.name, isOn: quietScheduleCategory(category.id))
            }
          }
        }
        Toggle(
          "Generic Notification Fallback",
          isOn: Binding(
            get: { viewModel.isGenericNotificationFallbackEnabled },
            set: { value in
              Task { await viewModel.setGenericNotificationFallbackEnabled(value) }
            }
          )
        )
      }

      Section {
        Button("Preview Sample Notification") {
          Task { await viewModel.deliverPreview(connectionId: profileConnections.first?.id) }
        }
        Button("Save Synchronized Notification Policy") {
          Task { await viewModel.save() }
        }
        .disabled(!viewModel.canSave || !viewModel.hasUnsavedChanges)

        if viewModel.isSyncing || viewModel.isSaving {
          ProgressView(viewModel.isSaving ? "Saving policy…" : "Loading policy…")
        }
        if let previewMessage = viewModel.previewMessage {
          Text(previewMessage)
            .foregroundStyle(.secondary)
        }
        if let errorMessage = viewModel.errorMessage {
          SettingsInlineErrorView(
            message: errorMessage,
            isRetrying: viewModel.isSyncing || viewModel.isSaving
          ) {
            Task {
              if viewModel.hasUnsavedChanges {
                await viewModel.save()
              } else {
                await viewModel.loadProfiles(
                  categoryIds: hasLoadedCategory ? Set(categoryChoices.map(\.id)) : nil
                )
              }
            }
          }
        }
        if let fallbackErrorMessage = viewModel.fallbackErrorMessage {
          Text(fallbackErrorMessage)
            .foregroundStyle(.red)
        }
      } footer: {
        Text(
          "Quiet schedule, lock-screen detail, sound, badge, and fallback stay on this device. "
            + "A sample uses local placeholder mail and never sends a message."
        )
      }
    }
    .navigationTitle("Notifications")
    .task {
      await viewModel.loadProfiles(
        categoryIds: hasLoadedCategory ? Set(categoryChoices.map(\.id)) : nil
      )
    }
    .onChange(of: Set(categoryChoices.map(\.id)), initial: false) { _, categoryIds in
      Task { await viewModel.prune(categoryIds: categoryIds) }
    }
    .onChange(of: hasLoadedCategory) { _, hasLoadedCategory in
      guard hasLoadedCategory else { return }
      Task { await viewModel.prune(categoryIds: Set(categoryChoices.map(\.id))) }
    }
    .alert("Unable to Open System Settings", isPresented: $showsSystemSettingsError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Open System Settings manually to change notification permission.")
    }
  }

  private var authorizationTitle: String {
    switch viewModel.authorizationState {
    case .authorized:
      return "Allowed"
    case .denied:
      return "Denied"
    case .notDetermined:
      return "Not Requested"
    }
  }

  private var profileConnections: [MailboxConnection] {
    viewModel.connectionsForSelectedProfile(connections)
  }

  private var selectedProfilePolicyTitle: String {
    guard
      let selectedProfileId = viewModel.selectedProfileId,
      let profile = viewModel.profiles.first(where: { $0.id == selectedProfileId })
    else { return "Mail Profile Policy" }
    return "\(profile.name) Policy"
  }

  private var isBadgeEnabled: Binding<Bool> {
    Binding(
      get: { viewModel.devicePreferences.isBadgeEnabled },
      set: { updateDevicePreferences(isBadgeEnabled: $0) }
    )
  }

  private var isSoundEnabled: Binding<Bool> {
    Binding(
      get: { viewModel.devicePreferences.isSoundEnabled },
      set: { updateDevicePreferences(isSoundEnabled: $0) }
    )
  }

  private var lockScreenContentLevel: Binding<NotificationLockScreenContentLevel> {
    Binding(
      get: { viewModel.devicePreferences.lockScreenContentLevel },
      set: { updateDevicePreferences(lockScreenContentLevel: $0) }
    )
  }

  private var quietScheduleEnabled: Binding<Bool> {
    Binding(
      get: { viewModel.devicePreferences.quietSchedule.isEnabled },
      set: { updateQuietSchedule(isEnabled: $0) }
    )
  }

  private var quietScheduleStartMinute: Binding<Int> {
    Binding(
      get: { viewModel.devicePreferences.quietSchedule.startMinute },
      set: { updateQuietSchedule(startMinute: $0) }
    )
  }

  private var quietScheduleEndMinute: Binding<Int> {
    Binding(
      get: { viewModel.devicePreferences.quietSchedule.endMinute },
      set: { updateQuietSchedule(endMinute: $0) }
    )
  }

  private var quietScheduleMinutes: [Int] {
    Array(stride(from: 0, to: 24 * 60, by: 30))
  }

  private func quietScheduleCategory(_ categoryId: String) -> Binding<Bool> {
    Binding(
      get: {
        viewModel.devicePreferences.quietSchedule.allowedCategoryIds.contains(categoryId)
      },
      set: { isEnabled in
        var categoryIds = Set(
          viewModel.devicePreferences.quietSchedule.allowedCategoryIds
        )
        if isEnabled {
          categoryIds.insert(categoryId)
        } else {
          categoryIds.remove(categoryId)
        }
        updateQuietSchedule(allowedCategoryIds: Array(categoryIds))
      }
    )
  }

  private func updateDevicePreferences(
    isBadgeEnabled: Bool? = nil,
    isSoundEnabled: Bool? = nil,
    lockScreenContentLevel: NotificationLockScreenContentLevel? = nil
  ) {
    let current = viewModel.devicePreferences
    viewModel.setDevicePreferences(
      NotificationDevicePreferences(
        isBadgeEnabled: isBadgeEnabled ?? current.isBadgeEnabled,
        isSoundEnabled: isSoundEnabled ?? current.isSoundEnabled,
        lockScreenContentLevel: lockScreenContentLevel ?? current.lockScreenContentLevel,
        quietSchedule: current.quietSchedule
      )
    )
  }

  private func updateQuietSchedule(
    isEnabled: Bool? = nil,
    startMinute: Int? = nil,
    endMinute: Int? = nil,
    allowedCategoryIds: [String]? = nil
  ) {
    let current = viewModel.devicePreferences
    viewModel.setDevicePreferences(
      NotificationDevicePreferences(
        isBadgeEnabled: current.isBadgeEnabled,
        isSoundEnabled: current.isSoundEnabled,
        lockScreenContentLevel: current.lockScreenContentLevel,
        quietSchedule: NotificationQuietSchedule(
          isEnabled: isEnabled ?? current.quietSchedule.isEnabled,
          startMinute: startMinute ?? current.quietSchedule.startMinute,
          endMinute: endMinute ?? current.quietSchedule.endMinute,
          allowedCategoryIds: allowedCategoryIds
            ?? current.quietSchedule.allowedCategoryIds
        )
      )
    )
  }

  private func quietScheduleTitle(_ minute: Int) -> String {
    let hour = minute / 60
    let minute = minute % 60
    return String(format: "%02d:%02d", hour, minute)
  }

  private func openNotificationSettings() {
    #if canImport(UIKit)
      guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else {
        showsSystemSettingsError = true
        return
      }
      openURL(url) { accepted in
        if !accepted {
          showsSystemSettingsError = true
        }
      }
    #else
      showsSystemSettingsError = true
    #endif
  }
}
