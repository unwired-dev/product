import Foundation
import Observation

struct InboxPreferencePendingChange: Codable, Equatable, Sendable {
  let baseValue: InboxPreferenceValue
  var localValue: InboxPreferenceValue
}

struct InboxPreferenceConflict: Codable, Equatable, Identifiable, Sendable {
  let field: InboxPreferenceField
  let localValue: InboxPreferenceValue
  let remoteValue: InboxPreferenceValue

  var id: InboxPreferenceField { field }
}

struct InboxPreferenceLocalState: Codable, Equatable, Sendable {
  var conflicts: [InboxPreferenceField: InboxPreferenceConflict]
  var pendingChanges: [InboxPreferenceField: InboxPreferencePendingChange]
  var preferences: InboxPreferences

  static let empty = InboxPreferenceLocalState(
    conflicts: [:],
    pendingChanges: [:],
    preferences: .defaults
  )
}

protocol InboxPreferenceLocalStatePersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> InboxPreferenceLocalState?
  func save(_ state: InboxPreferenceLocalState, productAccountId: String) throws
}

struct UserDefaultsInboxPreferenceStateStore: InboxPreferenceLocalStatePersisting {
  private static let keyPrefix = "mail-workflow-preferences.inbox."
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(productAccountId: String) throws {
    defaults.removeObject(forKey: key(productAccountId))
  }

  func load(productAccountId: String) throws -> InboxPreferenceLocalState? {
    guard let data = defaults.data(forKey: key(productAccountId)) else { return nil }
    return try JSONDecoder().decode(InboxPreferenceLocalState.self, from: data)
  }

  func save(_ state: InboxPreferenceLocalState, productAccountId: String) throws {
    defaults.set(try JSONEncoder().encode(state), forKey: key(productAccountId))
  }

  private func key(_ productAccountId: String) -> String {
    Self.keyPrefix + productAccountId
  }
}

@MainActor
@Observable
final class InboxPreferenceStore {
  private(set) var errorMessage: String?
  private(set) var isSynchronizing = false
  private(set) var preferences: InboxPreferences
  private let automaticallySynchronizes: Bool
  private var localState: InboxPreferenceLocalState
  private let localStateStore: InboxPreferenceLocalStatePersisting
  private var session: ProductAccountSessionSnapshot
  private let syncService: InboxPreferenceSyncing
  private var syncTask: Task<Void, Never>?

  var conflicts: [InboxPreferenceConflict] {
    localState.conflicts.values.sorted { $0.field.rawValue < $1.field.rawValue }
  }

  var hasPendingChanges: Bool {
    !localState.pendingChanges.isEmpty
  }

  init(
    session: ProductAccountSessionSnapshot,
    syncService: InboxPreferenceSyncing = InboxPreferenceSyncService(),
    localStateStore: InboxPreferenceLocalStatePersisting =
      UserDefaultsInboxPreferenceStateStore(),
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
      errorMessage = error.localizedDescription
    }
  }

  func setThreadDensity(_ value: InboxThreadDensity) {
    edit(.threadDensity, value: .threadDensity(value))
  }

  func setPreviewLength(_ value: InboxPreviewLength) {
    edit(.previewLength, value: .previewLength(value))
  }

  func setShowsContactImages(_ value: Bool) {
    edit(.contactImages, value: .boolean(value))
  }

  func setShowsCategoryBadges(_ value: Bool) {
    edit(.categoryBadges, value: .boolean(value))
  }

  func setShowsAttachmentIndicators(_ value: Bool) {
    edit(.attachmentIndicators, value: .boolean(value))
  }

  func resolveConflict(_ field: InboxPreferenceField, useLocalValue: Bool) {
    guard let conflict = localState.conflicts.removeValue(forKey: field) else { return }
    let selectedValue = useLocalValue ? conflict.localValue : conflict.remoteValue
    preferences.set(selectedValue, for: field)
    localState.preferences = preferences
    if useLocalValue, conflict.localValue != conflict.remoteValue {
      localState.pendingChanges[field] = InboxPreferencePendingChange(
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
    self.session = session
    do {
      localState = try localStateStore.load(productAccountId: session.productAccountId) ?? .empty
      preferences = localState.preferences
      errorMessage = nil
    } catch {
      localState = .empty
      preferences = .defaults
      errorMessage = error.localizedDescription
    }
  }

  func synchronize() async {
    guard !isSynchronizing else { return }
    isSynchronizing = true
    defer { isSynchronizing = false }

    do {
      var remote =
        try await syncService.loadPreferences(session: session)
        ?? InboxPreferenceSyncSnapshot(preferences: .defaults, updatedAt: nil)
      for attempt in 1...5 {
        let merged = reconcile(with: remote.preferences)
        persist()
        guard !localState.pendingChanges.isEmpty else {
          errorMessage = nil
          return
        }

        switch try await syncService.savePreferences(
          merged,
          expectedUpdatedAt: remote.updatedAt,
          session: session
        ) {
        case .committed(let snapshot):
          _ = reconcile(with: snapshot.preferences)
          persist()
          errorMessage = nil
          return
        case .conflict(let snapshot):
          remote = snapshot
        }

        guard attempt < 5 else {
          throw InboxPreferenceSyncError.retryLimitExceeded
        }
      }
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
      persist()
    }
  }

  private func edit(_ field: InboxPreferenceField, value: InboxPreferenceValue) {
    let baseValue =
      localState.pendingChanges[field]?.baseValue
      ?? localState.conflicts[field]?.remoteValue
      ?? preferences.value(for: field)
    localState.conflicts[field] = nil
    if value == baseValue {
      localState.pendingChanges[field] = nil
    } else {
      localState.pendingChanges[field] = InboxPreferencePendingChange(
        baseValue: baseValue,
        localValue: value
      )
    }
    preferences.set(value, for: field)
    localState.preferences = preferences
    errorMessage = nil
    persist()
    scheduleSyncIfNeeded()
  }

  private func reconcile(with remotePreferences: InboxPreferences) -> InboxPreferences {
    var merged = remotePreferences
    var presented = remotePreferences

    for field in InboxPreferenceField.allCases {
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
        localState.conflicts[field] = InboxPreferenceConflict(
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

  private func persist() {
    do {
      try localStateStore.save(localState, productAccountId: session.productAccountId)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func scheduleSyncIfNeeded() {
    guard automaticallySynchronizes, syncTask == nil else { return }
    syncTask = Task { [weak self] in
      guard let self else { return }
      await synchronize()
      syncTask = nil
    }
  }
}
