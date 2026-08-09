import Foundation
import Observation

struct ReadingPreferencePendingChange: Codable, Equatable, Sendable {
  let baseValue: ReadingPreferenceValue
  var localValue: ReadingPreferenceValue
}

struct ReadingPreferenceConflict: Codable, Equatable, Identifiable, Sendable {
  let field: ReadingPreferenceField
  let localValue: ReadingPreferenceValue
  let remoteValue: ReadingPreferenceValue

  var id: ReadingPreferenceField { field }
}

struct ReadingPreferenceLocalState: Codable, Equatable, Sendable {
  var conflicts: [ReadingPreferenceField: ReadingPreferenceConflict]
  var pendingChanges: [ReadingPreferenceField: ReadingPreferencePendingChange]
  var preferences: ReadingPreferences

  static let empty = ReadingPreferenceLocalState(
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
    conflicts: [ReadingPreferenceField: ReadingPreferenceConflict],
    pendingChanges: [ReadingPreferenceField: ReadingPreferencePendingChange],
    preferences: ReadingPreferences
  ) {
    self.conflicts = conflicts
    self.pendingChanges = pendingChanges
    self.preferences = preferences
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    conflicts =
      try container.decodeIfPresent(
        [ReadingPreferenceField: ReadingPreferenceConflict].self,
        forKey: .conflicts
      ) ?? [:]
    pendingChanges =
      try container.decodeIfPresent(
        [ReadingPreferenceField: ReadingPreferencePendingChange].self,
        forKey: .pendingChanges
      ) ?? [:]
    preferences =
      try container.decodeIfPresent(ReadingPreferences.self, forKey: .preferences) ?? .defaults
  }
}

protocol ReadingPreferenceLocalStatePersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> ReadingPreferenceLocalState?
  func save(_ state: ReadingPreferenceLocalState, productAccountId: String) throws
}

struct UserDefaultsReadingPreferenceStateStore: ReadingPreferenceLocalStatePersisting {
  private static let keyPrefix = "mail-workflow-preferences.reading."
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(productAccountId: String) throws {
    defaults.removeObject(forKey: key(productAccountId))
  }

  func load(productAccountId: String) throws -> ReadingPreferenceLocalState? {
    guard let data = defaults.data(forKey: key(productAccountId)) else { return nil }
    return try JSONDecoder().decode(ReadingPreferenceLocalState.self, from: data)
  }

  func save(_ state: ReadingPreferenceLocalState, productAccountId: String) throws {
    defaults.set(try JSONEncoder().encode(state), forKey: key(productAccountId))
  }

  private func key(_ productAccountId: String) -> String {
    Self.keyPrefix + productAccountId
  }
}

@MainActor
@Observable
final class ReadingPreferenceStore {
  private static let maximumSynchronizationAttempts = 5
  private(set) var errorMessage: String?
  private(set) var isSynchronizing = false
  private(set) var preferences: ReadingPreferences
  private let automaticallySynchronizes: Bool
  private var editRevision = 0
  private var fieldEditRevisions: [ReadingPreferenceField: Int] = [:]
  private var localState: ReadingPreferenceLocalState
  private let localStateStore: ReadingPreferenceLocalStatePersisting
  private var restorationSucceeded = true
  private var session: ProductAccountSessionSnapshot
  private var sessionGeneration = 0
  private var synchronizingGeneration: Int?
  private let syncService: ReadingPreferenceSyncing
  private var syncTask: Task<Void, Never>?

  var conflicts: [ReadingPreferenceConflict] {
    localState.conflicts.values.sorted { $0.field.sortKey < $1.field.sortKey }
  }

  var hasPendingChanges: Bool {
    !localState.pendingChanges.isEmpty
  }

  init(
    session: ProductAccountSessionSnapshot,
    syncService: ReadingPreferenceSyncing = ReadingPreferenceSyncService(),
    localStateStore: ReadingPreferenceLocalStatePersisting =
      UserDefaultsReadingPreferenceStateStore(),
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

  func setMarkReadAfter(_ value: MessageReadTiming) {
    edit(.markReadAfter, value: .markReadAfter(value))
  }

  func setMarksReadOnReply(_ value: Bool) {
    edit(.marksReadOnReply, value: .boolean(value))
  }

  func setMarksReadOnArchiveOrDelete(_ value: Bool) {
    edit(.marksReadOnArchiveOrDelete, value: .boolean(value))
  }

  func setIncomingReadReceipts(_ value: IncomingReadReceiptPolicy) {
    edit(.incomingReadReceipts, value: .incomingReadReceipts(value))
  }

  func setOutgoingReadReceipts(_ value: OutgoingReadReceiptPolicy) {
    edit(.outgoingReadReceipts, value: .outgoingReadReceipts(value))
  }

  func setIncomingReadReceipts(
    _ value: IncomingReadReceiptPolicy?,
    connectionId: MailboxConnectionId
  ) {
    edit(
      .connectionIncomingReadReceipts(connectionId.rawValue),
      value: .incomingReadReceipts(value)
    )
  }

  func setOutgoingReadReceipts(
    _ value: OutgoingReadReceiptPolicy?,
    connectionId: MailboxConnectionId
  ) {
    edit(
      .connectionOutgoingReadReceipts(connectionId.rawValue),
      value: .outgoingReadReceipts(value)
    )
  }

  func resolveConflict(_ field: ReadingPreferenceField, useLocalValue: Bool) {
    guard let conflict = localState.conflicts.removeValue(forKey: field) else { return }
    recordEdit(to: field)
    let selectedValue = useLocalValue ? conflict.localValue : conflict.remoteValue
    preferences.set(selectedValue, for: field)
    localState.preferences = preferences
    if useLocalValue, conflict.localValue != conflict.remoteValue {
      localState.pendingChanges[field] = ReadingPreferencePendingChange(
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
        ?? ReadingPreferenceSyncSnapshot(preferences: .defaults, updatedAt: nil)
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
    remote initialRemote: ReadingPreferenceSyncSnapshot,
    generation: Int,
    session: ProductAccountSessionSnapshot
  ) async throws {
    var remote = initialRemote
    for attempt in 1...Self.maximumSynchronizationAttempts {
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
        _ = reconcile(with: snapshot.preferences, preservingEditsAfter: savingRevision)
        persist()
        errorMessage = nil
        return
      case .conflict(let snapshot):
        guard generation == sessionGeneration else { return }
        _ = reconcile(with: snapshot.preferences, preservingEditsAfter: savingRevision)
        persist()
        remote = snapshot
      }

      guard attempt < Self.maximumSynchronizationAttempts else {
        throw ReadingPreferenceSyncError.retryLimitExceeded
      }
    }
  }

  private func edit(_ field: ReadingPreferenceField, value: ReadingPreferenceValue) {
    recordEdit(to: field)
    let baseValue =
      localState.pendingChanges[field]?.baseValue
      ?? localState.conflicts[field]?.remoteValue
      ?? preferences.value(for: field)
    localState.conflicts[field] = nil
    localState.pendingChanges[field] =
      value == baseValue
      ? nil
      : ReadingPreferencePendingChange(baseValue: baseValue, localValue: value)
    preferences.set(value, for: field)
    localState.preferences = preferences
    if restorationSucceeded { errorMessage = nil }
    persist()
    scheduleSyncIfNeeded()
  }

  private func recordEdit(to field: ReadingPreferenceField) {
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
      if editRevision != scheduledRevision { scheduleSyncIfNeeded() }
    }
  }
}

extension ReadingPreferenceStore {
  fileprivate func reconcile(
    with remotePreferences: ReadingPreferences,
    preservingEditsAfter savingRevision: Int? = nil
  ) -> ReadingPreferences {
    // `merged` is the conditional remote-write candidate. `presented` is the device-visible
    // value and may contain unresolved conflict values that must not synchronize.
    var merged = remotePreferences
    var presented = remotePreferences
    let fields = Set(ReadingPreferences.fields(including: preferences))
      .union(ReadingPreferences.fields(including: remotePreferences))
      .union(localState.pendingChanges.keys)
      .union(localState.conflicts.keys)

    for field in fields {
      if let savingRevision, fieldEditRevisions[field, default: 0] > savingRevision {
        let localValue = preferences.value(for: field)
        let remoteValue = remotePreferences.value(for: field)
        localState.conflicts[field] = nil
        localState.pendingChanges[field] =
          localValue == remoteValue
          ? nil
          : ReadingPreferencePendingChange(baseValue: remoteValue, localValue: localValue)
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
        localState.conflicts[field] = ReadingPreferenceConflict(
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
