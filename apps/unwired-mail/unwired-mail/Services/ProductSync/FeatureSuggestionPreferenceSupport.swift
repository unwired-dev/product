import Foundation

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

  init(
    recordScope: MailProfileRecordScope = .legacyProductAccount,
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()
  ) {
    preferenceRecord = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: recordScope.productSyncIdentifier(
          FeatureSuggestionPreferences.primaryIdentifier
        ),
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
