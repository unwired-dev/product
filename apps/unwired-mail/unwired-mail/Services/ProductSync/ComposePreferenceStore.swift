import Foundation
import Observation

// swiftlint:disable file_length

struct ComposePreferencePendingChange: Codable, Equatable, Sendable {
  let baseValue: ComposePreferenceValue
  var localValue: ComposePreferenceValue
}

struct ComposePreferenceConflict: Codable, Equatable, Identifiable, Sendable {
  let field: ComposePreferenceField
  let localValue: ComposePreferenceValue
  let remoteValue: ComposePreferenceValue

  var id: ComposePreferenceField { field }
}

struct ComposePreferenceLocalState: Codable, Equatable, Sendable {
  var conflicts: [ComposePreferenceField: ComposePreferenceConflict]
  var pendingChanges: [ComposePreferenceField: ComposePreferencePendingChange]
  var preferences: ComposePreferences

  static let empty = ComposePreferenceLocalState(
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
    conflicts: [ComposePreferenceField: ComposePreferenceConflict],
    pendingChanges: [ComposePreferenceField: ComposePreferencePendingChange],
    preferences: ComposePreferences
  ) {
    self.conflicts = conflicts
    self.pendingChanges = pendingChanges
    self.preferences = preferences
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    conflicts =
      try container.decodeIfPresent(
        [ComposePreferenceField: ComposePreferenceConflict].self,
        forKey: .conflicts
      ) ?? [:]
    pendingChanges =
      try container.decodeIfPresent(
        [ComposePreferenceField: ComposePreferencePendingChange].self,
        forKey: .pendingChanges
      ) ?? [:]
    preferences =
      try container.decodeIfPresent(ComposePreferences.self, forKey: .preferences) ?? .defaults
  }
}

protocol ComposePreferenceLocalStatePersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> ComposePreferenceLocalState?
  func save(_ state: ComposePreferenceLocalState, productAccountId: String) throws
}

struct UserDefaultsComposePreferenceStateStore: ComposePreferenceLocalStatePersisting {
  private static let keyPrefix = "mail-workflow-preferences.compose."
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(productAccountId: String) throws {
    defaults.removeObject(forKey: key(productAccountId))
  }

  func load(productAccountId: String) throws -> ComposePreferenceLocalState? {
    guard let data = defaults.data(forKey: key(productAccountId)) else { return nil }
    do {
      return try JSONDecoder().decode(ComposePreferenceLocalState.self, from: data)
    } catch {
      defaults.removeObject(forKey: key(productAccountId))
      return nil
    }
  }

  func save(_ state: ComposePreferenceLocalState, productAccountId: String) throws {
    defaults.set(try JSONEncoder().encode(state), forKey: key(productAccountId))
  }

  private func key(_ productAccountId: String) -> String {
    Self.keyPrefix + productAccountId
  }
}

@MainActor
@Observable
final class ComposePreferenceStore {
  private(set) var errorMessage: String?
  private(set) var isSynchronizing = false
  private(set) var preferences: ComposePreferences
  private let automaticallySynchronizes: Bool
  private var localState: ComposePreferenceLocalState
  private let localStateStore: ComposePreferenceLocalStatePersisting
  private let recordScope: MailProfileRecordScope
  private var session: ProductAccountSessionSnapshot
  private let syncService: ComposePreferenceSyncing
  private var syncTask: Task<Void, Never>?
  private var editRevision = 0
  private var fieldEditRevisions: [ComposePreferenceField: Int] = [:]
  private var sessionGeneration = 0
  private var restorationSucceeded = true
  private var synchronizingGeneration: Int?

  var conflicts: [ComposePreferenceConflict] {
    localState.conflicts.values.sorted { $0.field.rawValue < $1.field.rawValue }
  }

  var hasPendingChanges: Bool {
    !localState.pendingChanges.isEmpty
  }

  init(
    session: ProductAccountSessionSnapshot,
    syncService: ComposePreferenceSyncing? = nil,
    localStateStore: ComposePreferenceLocalStatePersisting =
      UserDefaultsComposePreferenceStateStore(),
    recordScope: MailProfileRecordScope = .legacyProductAccount,
    automaticallySynchronizes: Bool = true
  ) {
    self.session = session
    self.syncService = syncService ?? ComposePreferenceSyncService(recordScope: recordScope)
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

  func setUndoSendWindow(_ value: UndoSendWindow) {
    edit(.undoSend, value: .undoSend(value))
  }

  func setPresentation(_ value: ComposePresentationPreference) {
    edit(.presentation, value: .presentation(value))
  }

  func setShowsFormattingToolbar(_ value: Bool) {
    edit(.formattingToolbar, value: .boolean(value))
  }

  func setIncludesQuotedText(_ value: Bool) {
    edit(.quotedText, value: .boolean(value))
  }

  func setIncludesForwardedAttachments(_ value: Bool) {
    edit(.forwardedAttachments, value: .boolean(value))
  }

  func resolveConflict(_ field: ComposePreferenceField, useLocalValue: Bool) {
    guard let conflict = localState.conflicts.removeValue(forKey: field) else { return }
    recordEdit(to: field)
    let selectedValue = useLocalValue ? conflict.localValue : conflict.remoteValue
    preferences.set(selectedValue, for: field)
    localState.preferences = preferences
    if useLocalValue, conflict.localValue != conflict.remoteValue {
      localState.pendingChanges[field] = ComposePreferencePendingChange(
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
        ?? ComposePreferenceSyncSnapshot(preferences: .defaults, updatedAt: nil)
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
    remote initialRemote: ComposePreferenceSyncSnapshot,
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
        throw ComposePreferenceSyncError.retryLimitExceeded
      }
    }
  }

  private func edit(_ field: ComposePreferenceField, value: ComposePreferenceValue) {
    recordEdit(to: field)
    let baseValue =
      localState.pendingChanges[field]?.baseValue
      ?? localState.conflicts[field]?.remoteValue
      ?? preferences.value(for: field)
    localState.conflicts[field] = nil
    if value == baseValue {
      localState.pendingChanges[field] = nil
    } else {
      localState.pendingChanges[field] = ComposePreferencePendingChange(
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

  private func recordEdit(to field: ComposePreferenceField) {
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

extension ComposePreferenceStore {
  fileprivate func reconcile(
    with remotePreferences: ComposePreferences,
    preservingEditsAfter savingRevision: Int? = nil
  ) -> ComposePreferences {
    var merged = remotePreferences
    var presented = remotePreferences

    for field in ComposePreferenceField.allCases {
      if let savingRevision,
        fieldEditRevisions[field, default: 0] > savingRevision
      {
        let localValue = preferences.value(for: field)
        let remoteValue = remotePreferences.value(for: field)
        localState.conflicts[field] = nil
        localState.pendingChanges[field] =
          localValue == remoteValue
          ? nil
          : ComposePreferencePendingChange(baseValue: remoteValue, localValue: localValue)
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
        localState.conflicts[field] = ComposePreferenceConflict(
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
