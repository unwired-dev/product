import Foundation
import Observation

enum FeatureSuggestionKind: String, CaseIterable, Codable, Sendable {
  case addToCalendar
  case addToContacts
  case inboxCleanup
  case unsubscribe
}

struct FeatureSuggestionPreferences: Codable, Equatable, Sendable {
  static let defaults = FeatureSuggestionPreferences()
  static let primaryIdentifier = "mail-workflow-preferences:feature-suggestions"
  static let supportedSchemaVersion = 1

  private var disabledFeatures: Set<FeatureSuggestionKind>
  private var dismissedUntilMilliseconds: [FeatureSuggestionKind: [String: Int64]]
  let schemaVersion: Int

  init(
    disabledFeatures: Set<FeatureSuggestionKind> = [],
    dismissedUntilMilliseconds: [FeatureSuggestionKind: [String: Int64]] = [:]
  ) {
    self.disabledFeatures = disabledFeatures
    self.dismissedUntilMilliseconds = dismissedUntilMilliseconds
    schemaVersion = Self.supportedSchemaVersion
  }

  private enum CodingKeys: String, CodingKey {
    case disabledFeatures
    case dismissedUntilMilliseconds
    case schemaVersion
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSchemaVersion =
      try container.decodeIfPresent(
        Int.self,
        forKey: .schemaVersion
      ) ?? 1
    guard decodedSchemaVersion <= Self.supportedSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Feature suggestion preferences are newer than this client supports."
      )
    }
    disabledFeatures =
      try container.decodeIfPresent(
        Set<FeatureSuggestionKind>.self,
        forKey: .disabledFeatures
      ) ?? []
    dismissedUntilMilliseconds =
      try container.decodeIfPresent(
        [FeatureSuggestionKind: [String: Int64]].self,
        forKey: .dismissedUntilMilliseconds
      ) ?? [:]
    schemaVersion = max(1, decodedSchemaVersion)
  }

  func isEnabled(_ feature: FeatureSuggestionKind) -> Bool {
    !disabledFeatures.contains(feature)
  }

  func isVisible(
    _ feature: FeatureSuggestionKind,
    dismissalIdentifier: String,
    nowMilliseconds: Int64
  ) -> Bool {
    isEnabled(feature)
      && (dismissedUntilMilliseconds[feature]?[dismissalIdentifier] ?? 0) <= nowMilliseconds
  }

  mutating func apply(_ mutation: FeatureSuggestionPreferenceMutation) {
    switch mutation.value {
    case .dismissedUntil(let milliseconds):
      let current = dismissedUntilMilliseconds[mutation.feature]?[mutation.identifier] ?? 0
      dismissedUntilMilliseconds[mutation.feature, default: [:]][mutation.identifier] = max(
        current,
        milliseconds
      )
    case .enabled(let enabled):
      if enabled {
        disabledFeatures.remove(mutation.feature)
      } else {
        disabledFeatures.insert(mutation.feature)
      }
    }
  }

  func applying(_ mutations: [FeatureSuggestionPreferenceMutation]) -> Self {
    var preferences = self
    for mutation in mutations {
      preferences.apply(mutation)
    }
    return preferences
  }
}

struct FeatureSuggestionPreferenceMutation: Codable, Equatable, Sendable {
  enum Value: Codable, Equatable, Sendable {
    case dismissedUntil(Int64)
    case enabled(Bool)
  }

  let feature: FeatureSuggestionKind
  let identifier: String
  let value: Value

  static func setEnabled(
    _ enabled: Bool,
    feature: FeatureSuggestionKind
  ) -> Self {
    Self(feature: feature, identifier: "enabled", value: .enabled(enabled))
  }

  static func dismiss(
    _ identifier: String,
    feature: FeatureSuggestionKind,
    untilMilliseconds: Int64
  ) -> Self {
    Self(
      feature: feature,
      identifier: identifier,
      value: .dismissedUntil(untilMilliseconds)
    )
  }
}

protocol FeatureSuggestionPreferenceSyncing {
  func apply(
    _ mutations: [FeatureSuggestionPreferenceMutation],
    session: ProductAccountSessionSnapshot
  ) async throws -> FeatureSuggestionPreferences

  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> FeatureSuggestionPreferences?
}

final class FeatureSuggestionPreferenceSyncService: FeatureSuggestionPreferenceSyncing {
  private let preferenceRecord: ProductSyncSingletonHandle<FeatureSuggestionPreferences>

  init(recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()) {
    preferenceRecord = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: FeatureSuggestionPreferences.primaryIdentifier,
        cachePolicy: .authoritative
      )
    )
  }

  func apply(
    _ mutations: [FeatureSuggestionPreferenceMutation],
    session: ProductAccountSessionSnapshot
  ) async throws -> FeatureSuggestionPreferences {
    guard !mutations.isEmpty else {
      return try await loadPreferences(session: session) ?? .defaults
    }
    let record = try await preferenceRecord.update(session: session) { current in
      .write((current?.value ?? .defaults).applying(mutations))
    }
    return record?.value ?? .defaults
  }

  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> FeatureSuggestionPreferences? {
    try await preferenceRecord.read(session: session)?.value
  }
}

struct FeatureSuggestionPreferenceLocalState: Codable, Equatable, Sendable {
  var pendingMutations: [FeatureSuggestionPreferenceMutation]
  var preferences: FeatureSuggestionPreferences

  static let empty = FeatureSuggestionPreferenceLocalState(
    pendingMutations: [],
    preferences: .defaults
  )
}

protocol FeatureSuggestionLocalStatePersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> FeatureSuggestionPreferenceLocalState?
  func save(_ state: FeatureSuggestionPreferenceLocalState, productAccountId: String) throws
}

struct UserDefaultsFeatureSuggestionStateStore: FeatureSuggestionLocalStatePersisting {
  private static let keyPrefix = "mail-workflow-preferences.feature-suggestions."
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(productAccountId: String) throws {
    defaults.removeObject(forKey: key(productAccountId))
  }

  func load(productAccountId: String) throws -> FeatureSuggestionPreferenceLocalState? {
    guard let data = defaults.data(forKey: key(productAccountId)) else { return nil }
    do {
      return try JSONDecoder().decode(FeatureSuggestionPreferenceLocalState.self, from: data)
    } catch {
      defaults.removeObject(forKey: key(productAccountId))
      return nil
    }
  }

  func save(
    _ state: FeatureSuggestionPreferenceLocalState,
    productAccountId: String
  ) throws {
    defaults.set(try JSONEncoder().encode(state), forKey: key(productAccountId))
  }

  private func key(_ productAccountId: String) -> String {
    Self.keyPrefix + productAccountId
  }
}

@MainActor
@Observable
final class FeatureSuggestionPreferenceStore {
  private(set) var errorMessage: String?
  private(set) var isSynchronizing = false
  private(set) var preferences: FeatureSuggestionPreferences
  private let automaticallySynchronizes: Bool
  private let localStateStore: FeatureSuggestionLocalStatePersisting
  private var localState: FeatureSuggestionPreferenceLocalState
  private var session: ProductAccountSessionSnapshot
  private var sessionGeneration = 0
  private let syncService: FeatureSuggestionPreferenceSyncing
  private var syncTask: Task<Void, Never>?

  var hasPendingChanges: Bool {
    !localState.pendingMutations.isEmpty
  }

  init(
    session: ProductAccountSessionSnapshot,
    syncService: FeatureSuggestionPreferenceSyncing = FeatureSuggestionPreferenceSyncService(),
    localStateStore: FeatureSuggestionLocalStatePersisting =
      UserDefaultsFeatureSuggestionStateStore(),
    automaticallySynchronizes: Bool = true
  ) {
    self.session = session
    self.syncService = syncService
    self.localStateStore = localStateStore
    self.automaticallySynchronizes = automaticallySynchronizes
    do {
      let state = try localStateStore.load(productAccountId: session.productAccountId) ?? .empty
      localState = state
      preferences = state.preferences
    } catch {
      localState = .empty
      preferences = .defaults
      errorMessage = error.localizedDescription
    }
  }

  func isVisible(
    _ feature: FeatureSuggestionKind,
    dismissalIdentifier: String,
    now: Date = Date()
  ) -> Bool {
    preferences.isVisible(
      feature,
      dismissalIdentifier: dismissalIdentifier,
      nowMilliseconds: milliseconds(now)
    )
  }

  func dismiss(
    _ dismissalIdentifier: String,
    feature: FeatureSuggestionKind,
    now: Date = Date()
  ) {
    let dismissalMilliseconds = Int64(
      (feature == .addToContacts ? 30 : 14) * 24 * 60 * 60 * 1_000
    )
    append(
      .dismiss(
        dismissalIdentifier,
        feature: feature,
        untilMilliseconds: milliseconds(now) + dismissalMilliseconds
      )
    )
  }

  func setEnabled(_ enabled: Bool, feature: FeatureSuggestionKind) {
    append(.setEnabled(enabled, feature: feature))
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    guard session.productAccountId != self.session.productAccountId else {
      self.session = session
      return
    }
    syncTask?.cancel()
    syncTask = nil
    sessionGeneration += 1
    isSynchronizing = false
    self.session = session
    do {
      let state = try localStateStore.load(productAccountId: session.productAccountId) ?? .empty
      localState = state
      preferences = state.preferences
      errorMessage = nil
    } catch {
      localState = .empty
      preferences = .defaults
      errorMessage = error.localizedDescription
    }
  }

  func retire() {
    syncTask?.cancel()
    syncTask = nil
    sessionGeneration += 1
    isSynchronizing = false
  }

  func synchronize() async {
    guard !isSynchronizing else { return }
    isSynchronizing = true
    defer { isSynchronizing = false }
    let generation = sessionGeneration
    let pendingCount = localState.pendingMutations.count
    let pending = Array(localState.pendingMutations.prefix(pendingCount))
    do {
      let synchronized =
        if pending.isEmpty {
          try await syncService.loadPreferences(session: session) ?? .defaults
        } else {
          try await syncService.apply(pending, session: session)
        }
      guard generation == sessionGeneration else { return }
      let currentPrefix = Array(localState.pendingMutations.prefix(pendingCount))
      let remaining =
        currentPrefix == pending
        ? Array(localState.pendingMutations.dropFirst(pendingCount))
        : localState.pendingMutations
      preferences = synchronized.applying(remaining)
      localState = FeatureSuggestionPreferenceLocalState(
        pendingMutations: remaining,
        preferences: preferences
      )
      persist()
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      guard generation == sessionGeneration else { return }
      errorMessage = error.localizedDescription
    }
  }

  private func append(_ mutation: FeatureSuggestionPreferenceMutation) {
    localState.pendingMutations.removeAll {
      $0.feature == mutation.feature && $0.identifier == mutation.identifier
    }
    localState.pendingMutations.append(mutation)
    preferences.apply(mutation)
    localState.preferences = preferences
    persist()
    scheduleSyncIfNeeded()
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
    let generation = sessionGeneration
    syncTask = Task { [weak self] in
      guard let self else { return }
      await synchronize()
      guard generation == sessionGeneration else { return }
      syncTask = nil
      if hasPendingChanges { scheduleSyncIfNeeded() }
    }
  }

  private func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
  }
}
