import SwiftUI

struct SwipeSettingsView: View {
  @Bindable var store: SwipePreferenceStore

  var body: some View {
    Form {
      actionSection(for: .leading)
      actionSection(for: .trailing)

      Section {
        Toggle("Allow Full Swipe", isOn: allowsFullSwipe)
      } header: {
        Text("Full Swipe")
      } footer: {
        Text(
          "A full swipe performs the first action on that edge. If that action is not "
            + "supported for a message, a full swipe does nothing instead of substituting "
            + "another action."
        )
      }

      synchronizationSection

      if !store.conflicts.isEmpty {
        Section {
          ForEach(store.conflicts) { conflict in
            conflictView(conflict)
          }
        } header: {
          Text("Resolve Conflicts")
        } footer: {
          Text("Both values are preserved until you choose which one should synchronize.")
        }
      }
    }
    .navigationTitle("Swipes")
  }

  private func actionSection(for edge: SwipeEdge) -> some View {
    Section {
      Picker("First Action", selection: action(edge: edge, index: 0)) {
        Text("None").tag(nil as SwipeAction?)
        ForEach(availableActions(edge: edge, index: 0)) { action in
          Text(action.title).tag(action as SwipeAction?)
        }
      }

      Picker("Second Action", selection: action(edge: edge, index: 1)) {
        Text("None").tag(nil as SwipeAction?)
        ForEach(availableActions(edge: edge, index: 1)) { action in
          Text(action.title).tag(action as SwipeAction?)
        }
      }
      .disabled(store.preferences.actions(for: edge).isEmpty)
    } header: {
      Text("\(edge.title) Edge")
    } footer: {
      Text(
        "The first action is outermost. Unsupported provider actions are hidden for the "
          + "affected message and are never replaced."
      )
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
          Text(errorMessage)
            .foregroundStyle(.red)
          Button("Try Again") {
            Task { await store.synchronize() }
          }
          .disabled(store.isSynchronizing)
        }
      }
    }
  }

  private func conflictView(_ conflict: SwipePreferenceConflict) -> some View {
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

  private func action(edge: SwipeEdge, index: Int) -> Binding<SwipeAction?> {
    Binding(
      get: {
        let actions = store.preferences.actions(for: edge)
        return actions.indices.contains(index) ? actions[index] : nil
      },
      set: { store.setAction($0, at: index, on: edge) }
    )
  }

  private func availableActions(edge: SwipeEdge, index: Int) -> [SwipeAction] {
    let actions = store.preferences.actions(for: edge)
    let otherAction =
      actions.indices.contains(index == 0 ? 1 : 0)
      ? actions[index == 0 ? 1 : 0]
      : nil
    return SwipeAction.allCases.filter { $0 != otherAction }
  }

  private var allowsFullSwipe: Binding<Bool> {
    Binding(
      get: { store.preferences.allowsFullSwipe },
      set: store.setAllowsFullSwipe
    )
  }
}
