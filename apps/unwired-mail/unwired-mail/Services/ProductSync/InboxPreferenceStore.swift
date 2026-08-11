import Foundation
import Observation

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
  private let recordScope: MailProfileRecordScope
  private var session: ProductAccountSessionSnapshot
  private let syncService: InboxPreferenceSyncing
  private var syncTask: Task<Void, Never>?
  private var editRevision = 0
  private var fieldEditRevisions: [InboxPreferenceField: Int] = [:]
  private var sessionGeneration = 0
  private var restorationSucceeded = true
  private var synchronizingGeneration: Int?

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
    recordScope: MailProfileRecordScope = .legacyProductAccount,
    automaticallySynchronizes: Bool = true
  ) {
    self.session = session
    self.syncService = syncService
    self.localStateStore = localStateStore
    self.recordScope = recordScope
    self.automaticallySynchronizes = automaticallySynchronizes
    do {
      let restored =
        try localStateStore.load(
          productAccountId: Self.localStateScope(for: session, recordScope: recordScope)
        ) ?? .empty
      localState = restored
      preferences = restored.preferences
    } catch {
      localState = .empty
      preferences = .defaults
      restorationSucceeded = false
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
    recordEdit(to: field)
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
    sessionGeneration += 1
    synchronizingGeneration = nil
    isSynchronizing = false
    self.session = session
    do {
      localState =
        try localStateStore.load(
          productAccountId: Self.localStateScope(for: session, recordScope: recordScope)
        ) ?? .empty
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

  func retire() {
    syncTask?.cancel()
    syncTask = nil
    sessionGeneration += 1
    synchronizingGeneration = nil
    isSynchronizing = false
    restorationSucceeded = false
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
        ?? InboxPreferenceSyncSnapshot(preferences: .defaults, updatedAt: nil)
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
    remote initialRemote: InboxPreferenceSyncSnapshot,
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
        throw InboxPreferenceSyncError.retryLimitExceeded
      }
    }
  }

  private func edit(_ field: InboxPreferenceField, value: InboxPreferenceValue) {
    recordEdit(to: field)
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
    if restorationSucceeded {
      errorMessage = nil
    }
    persist()
    scheduleSyncIfNeeded()
  }

  func editMailViewConfiguration(_ configuration: MailViewConfiguration) {
    edit(.mailViews, value: .mailViewConfiguration(configuration))
  }

  private func recordEdit(to field: InboxPreferenceField) {
    editRevision += 1
    fieldEditRevisions[field] = editRevision
  }

  private func persist() {
    guard restorationSucceeded else { return }
    do {
      try localStateStore.save(
        localState,
        productAccountId: Self.localStateScope(for: session, recordScope: recordScope)
      )
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

  private static func localStateScope(
    for session: ProductAccountSessionSnapshot,
    recordScope: MailProfileRecordScope
  ) -> String {
    guard let namespace = recordScope.namespace else { return session.productAccountId }
    return "\(session.productAccountId).mail-profile.\(namespace)"
  }
}

extension InboxPreferenceStore {
  fileprivate func reconcile(
    with remotePreferences: InboxPreferences,
    preservingEditsAfter savingRevision: Int? = nil
  ) -> InboxPreferences {
    var merged = remotePreferences
    var presented = remotePreferences

    for field in InboxPreferenceField.allCases {
      if let savingRevision,
        fieldEditRevisions[field, default: 0] > savingRevision
      {
        let localValue = preferences.value(for: field)
        let remoteValue = remotePreferences.value(for: field)
        localState.conflicts[field] = nil
        localState.pendingChanges[field] =
          localValue == remoteValue
          ? nil
          : InboxPreferencePendingChange(baseValue: remoteValue, localValue: localValue)
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
}
