import Foundation
import Observation

struct SwipePreferencePendingChange: Codable, Equatable, Sendable {
  let baseValue: SwipePreferenceValue
  var localValue: SwipePreferenceValue
}

struct SwipePreferenceConflict: Codable, Equatable, Identifiable, Sendable {
  let field: SwipePreferenceField
  let localValue: SwipePreferenceValue
  let remoteValue: SwipePreferenceValue

  var id: SwipePreferenceField { field }
}

struct SwipePreferenceLocalState: Codable, Equatable, Sendable {
  var conflicts: [SwipePreferenceField: SwipePreferenceConflict]
  var pendingChanges: [SwipePreferenceField: SwipePreferencePendingChange]
  var preferences: SwipePreferences

  static let empty = SwipePreferenceLocalState(
    conflicts: [:],
    pendingChanges: [:],
    preferences: .defaults
  )

  private enum CodingKeys: String, CodingKey {
    case conflicts
    case pendingChanges
    case preferences
  }

  init(
    conflicts: [SwipePreferenceField: SwipePreferenceConflict],
    pendingChanges: [SwipePreferenceField: SwipePreferencePendingChange],
    preferences: SwipePreferences
  ) {
    self.conflicts = conflicts
    self.pendingChanges = pendingChanges
    self.preferences = preferences
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    conflicts =
      try container.decodeIfPresent(
        [SwipePreferenceField: SwipePreferenceConflict].self,
        forKey: .conflicts
      ) ?? [:]
    pendingChanges =
      try container.decodeIfPresent(
        [SwipePreferenceField: SwipePreferencePendingChange].self,
        forKey: .pendingChanges
      ) ?? [:]
    preferences =
      try container.decodeIfPresent(SwipePreferences.self, forKey: .preferences) ?? .defaults
  }
}

protocol SwipePreferenceLocalStatePersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> SwipePreferenceLocalState?
  func save(_ state: SwipePreferenceLocalState, productAccountId: String) throws
}

struct UserDefaultsSwipePreferenceStateStore: SwipePreferenceLocalStatePersisting {
  private static let keyPrefix = "mail-workflow-preferences.swipes."
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(productAccountId: String) throws {
    defaults.removeObject(forKey: key(productAccountId))
  }

  func load(productAccountId: String) throws -> SwipePreferenceLocalState? {
    guard let data = defaults.data(forKey: key(productAccountId)) else { return nil }
    return try JSONDecoder().decode(SwipePreferenceLocalState.self, from: data)
  }

  func save(_ state: SwipePreferenceLocalState, productAccountId: String) throws {
    defaults.set(try JSONEncoder().encode(state), forKey: key(productAccountId))
  }

  private func key(_ productAccountId: String) -> String {
    Self.keyPrefix + productAccountId
  }
}

@MainActor
@Observable
final class SwipePreferenceStore {
  private(set) var errorMessage: String?
  private(set) var isSynchronizing = false
  private(set) var preferences: SwipePreferences
  private let automaticallySynchronizes: Bool
  private var localState: SwipePreferenceLocalState
  private let localStateStore: SwipePreferenceLocalStatePersisting
  private var session: ProductAccountSessionSnapshot
  private let syncService: SwipePreferenceSyncing
  private var syncTask: Task<Void, Never>?
  private var editRevision = 0
  private var fieldEditRevisions: [SwipePreferenceField: Int] = [:]
  private var sessionGeneration = 0
  private var restorationSucceeded = true
  private var synchronizingGeneration: Int?

  var conflicts: [SwipePreferenceConflict] {
    localState.conflicts.values.sorted { $0.field.rawValue < $1.field.rawValue }
  }

  var hasPendingChanges: Bool {
    !localState.pendingChanges.isEmpty
  }

  init(
    session: ProductAccountSessionSnapshot,
    syncService: SwipePreferenceSyncing = SwipePreferenceSyncService(),
    localStateStore: SwipePreferenceLocalStatePersisting =
      UserDefaultsSwipePreferenceStateStore(),
    automaticallySynchronizes: Bool = true
  ) {
    self.session = session
    self.syncService = syncService
    self.localStateStore = localStateStore
    self.automaticallySynchronizes = automaticallySynchronizes
    do {
      let restored = try localStateStore.load(productAccountId: session.productAccountId) ?? .empty
      localState = restored
      preferences = restored.preferences
    } catch {
      localState = .empty
      preferences = .defaults
      restorationSucceeded = false
      errorMessage = error.localizedDescription
    }
  }

  func setAction(_ action: SwipeAction?, at index: Int, on edge: SwipeEdge) {
    guard (0...1).contains(index) else { return }
    var actions = preferences.actions(for: edge)
    if let action {
      actions.removeAll { $0 == action }
      actions.insert(action, at: min(index, actions.count))
    } else if actions.indices.contains(index) {
      actions.remove(at: index)
    }
    edit(
      edge == .leading ? .leadingActions : .trailingActions,
      value: .actions(Array(actions.prefix(2)))
    )
  }

  func setAllowsFullSwipe(_ value: Bool) {
    edit(.allowsFullSwipe, value: .boolean(value))
  }

  func resolveConflict(_ field: SwipePreferenceField, useLocalValue: Bool) {
    guard let conflict = localState.conflicts.removeValue(forKey: field) else { return }
    recordEdit(to: field)
    let selectedValue = useLocalValue ? conflict.localValue : conflict.remoteValue
    preferences.set(selectedValue, for: field)
    localState.preferences = preferences
    if useLocalValue, conflict.localValue != conflict.remoteValue {
      localState.pendingChanges[field] = SwipePreferencePendingChange(
        baseValue: conflict.remoteValue,
        localValue: conflict.localValue
      )
    } else {
      localState.pendingChanges[field] = nil
    }
    persist()
    scheduleSyncIfNeeded()
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    guard session.productAccountId != self.session.productAccountId else {
      self.session = session
      return
    }
    syncTask?.cancel()
    syncTask = nil
    sessionGeneration += 1
    synchronizingGeneration = nil
    isSynchronizing = false
    self.session = session
    do {
      localState = try localStateStore.load(productAccountId: session.productAccountId) ?? .empty
      preferences = localState.preferences
      restorationSucceeded = true
      errorMessage = nil
    } catch {
      localState = .empty
      preferences = .defaults
      restorationSucceeded = false
      errorMessage = error.localizedDescription
    }
  }

  func synchronize() async {
    guard restorationSucceeded, synchronizingGeneration == nil else { return }
    let generation = sessionGeneration
    let synchronizationSession = session
    synchronizingGeneration = generation
    isSynchronizing = true
    defer {
      if synchronizingGeneration == generation {
        synchronizingGeneration = nil
        isSynchronizing = false
      }
    }

    do {
      let remote =
        try await syncService.loadPreferences(session: synchronizationSession)
        ?? SwipePreferenceSyncSnapshot(preferences: .defaults, updatedAt: nil)
      guard generation == sessionGeneration else { return }
      try await synchronize(
        remote: remote,
        generation: generation,
        session: synchronizationSession
      )
    } catch is CancellationError {
    } catch {
      guard generation == sessionGeneration else { return }
      errorMessage = error.localizedDescription
      persist()
    }
  }

  private func synchronize(
    remote initialRemote: SwipePreferenceSyncSnapshot,
    generation: Int,
    session: ProductAccountSessionSnapshot
  ) async throws {
    var remote = initialRemote
    for attempt in 1...5 {
      let merged = reconcile(with: remote.preferences)
      persist()
      guard !localState.pendingChanges.isEmpty else {
        errorMessage = nil
        return
      }

      let savingRevision = editRevision
      switch try await syncService.savePreferences(
        merged,
        expectedUpdatedAt: remote.updatedAt,
        session: session
      ) {
      case .committed(let snapshot):
        guard generation == sessionGeneration else { return }
        _ = reconcile(
          with: snapshot.preferences,
          preservingEditsAfter: savingRevision
        )
        persist()
        errorMessage = nil
        return
      case .conflict(let snapshot):
        guard generation == sessionGeneration else { return }
        _ = reconcile(
          with: snapshot.preferences,
          preservingEditsAfter: savingRevision
        )
        persist()
        remote = snapshot
      }

      guard attempt < 5 else {
        throw SwipePreferenceSyncError.retryLimitExceeded
      }
    }
  }

  private func edit(_ field: SwipePreferenceField, value: SwipePreferenceValue) {
    recordEdit(to: field)
    let baseValue =
      localState.pendingChanges[field]?.baseValue
      ?? localState.conflicts[field]?.remoteValue
      ?? preferences.value(for: field)
    localState.conflicts[field] = nil
    if value == baseValue {
      localState.pendingChanges[field] = nil
    } else {
      localState.pendingChanges[field] = SwipePreferencePendingChange(
        baseValue: baseValue,
        localValue: value
      )
    }
    preferences.set(value, for: field)
    localState.preferences = preferences
    if restorationSucceeded {
      errorMessage = nil
    }
    persist()
    scheduleSyncIfNeeded()
  }

  private func recordEdit(to field: SwipePreferenceField) {
    editRevision += 1
    fieldEditRevisions[field] = editRevision
  }

  private func persist() {
    guard restorationSucceeded else { return }
    do {
      try localStateStore.save(localState, productAccountId: session.productAccountId)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func scheduleSyncIfNeeded() {
    guard automaticallySynchronizes, restorationSucceeded, syncTask == nil else { return }
    let scheduledRevision = editRevision
    let scheduledGeneration = sessionGeneration
    syncTask = Task { [weak self] in
      guard let self else { return }
      await synchronize()
      guard sessionGeneration == scheduledGeneration else { return }
      syncTask = nil
      if editRevision != scheduledRevision {
        scheduleSyncIfNeeded()
      }
    }
  }
}

extension SwipePreferenceStore {
  fileprivate func reconcile(
    with remotePreferences: SwipePreferences,
    preservingEditsAfter savingRevision: Int? = nil
  ) -> SwipePreferences {
    var merged = remotePreferences
    var presented = remotePreferences

    for field in SwipePreferenceField.allCases {
      if let savingRevision,
        fieldEditRevisions[field, default: 0] > savingRevision
      {
        let localValue = preferences.value(for: field)
        let remoteValue = remotePreferences.value(for: field)
        localState.conflicts[field] = nil
        localState.pendingChanges[field] =
          localValue == remoteValue
          ? nil
          : SwipePreferencePendingChange(baseValue: remoteValue, localValue: localValue)
        merged.set(localValue, for: field)
        presented.set(localValue, for: field)
        continue
      }
      if let conflict = localState.conflicts[field] {
        presented.set(conflict.localValue, for: field)
        continue
      }
      guard let pending = localState.pendingChanges[field] else { continue }
      let remoteValue = remotePreferences.value(for: field)
      if remoteValue == pending.localValue {
        localState.pendingChanges[field] = nil
        presented.set(remoteValue, for: field)
      } else if remoteValue == pending.baseValue {
        merged.set(pending.localValue, for: field)
        presented.set(pending.localValue, for: field)
      } else {
        localState.pendingChanges[field] = nil
        localState.conflicts[field] = SwipePreferenceConflict(
          field: field,
          localValue: pending.localValue,
          remoteValue: remoteValue
        )
        presented.set(pending.localValue, for: field)
      }
    }

    preferences = presented
    localState.preferences = presented
    return merged
  }
}
