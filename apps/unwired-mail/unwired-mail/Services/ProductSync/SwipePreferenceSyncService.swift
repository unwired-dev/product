import Foundation

enum SwipeAction: String, CaseIterable, Codable, Identifiable, Sendable {
  case archive
  case move
  case pinUnpin
  case readUnread
  case spamNotSpam
  case trash

  var id: Self { self }

  var title: String {
    switch self {
    case .archive:
      return "Archive"
    case .move:
      return "Move"
    case .pinUnpin:
      return "Pin / Unpin"
    case .readUnread:
      return "Read / Unread"
    case .spamNotSpam:
      return "Spam / Not Spam"
    case .trash:
      return "Trash"
    }
  }
}

enum SwipeEdge: String, CaseIterable, Codable, Identifiable, Sendable {
  case leading
  case trailing

  var id: Self { self }

  var title: String {
    rawValue.capitalized
  }
}

struct SwipePreferences: Codable, Equatable, Sendable {
  static let defaults = SwipePreferences(
    leadingActions: [.readUnread],
    trailingActions: [.archive, .trash],
    allowsFullSwipe: true
  )
  static let primaryIdentifier = "mail-workflow-preferences:swipes"
  static let supportedSchemaVersion = 1

  private(set) var leadingActions: [SwipeAction]
  private(set) var trailingActions: [SwipeAction]
  var allowsFullSwipe: Bool
  let schemaVersion: Int

  init(
    leadingActions: [SwipeAction] = SwipePreferences.defaults.leadingActions,
    trailingActions: [SwipeAction] = SwipePreferences.defaults.trailingActions,
    allowsFullSwipe: Bool = SwipePreferences.defaults.allowsFullSwipe
  ) {
    self.leadingActions = Self.normalized(leadingActions)
    self.trailingActions = Self.normalized(trailingActions)
    self.allowsFullSwipe = allowsFullSwipe
    schemaVersion = Self.supportedSchemaVersion
  }

  private enum CodingKeys: String, CodingKey {
    case allowsFullSwipe
    case leadingActions
    case schemaVersion
    case trailingActions
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSchemaVersion =
      try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard decodedSchemaVersion <= Self.supportedSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Swipe preference schema is newer than this client supports."
      )
    }
    leadingActions = Self.normalized(
      try container.decodeIfPresent([SwipeAction].self, forKey: .leadingActions)
        ?? Self.defaults.leadingActions
    )
    trailingActions = Self.normalized(
      try container.decodeIfPresent([SwipeAction].self, forKey: .trailingActions)
        ?? Self.defaults.trailingActions
    )
    allowsFullSwipe =
      try container.decodeIfPresent(Bool.self, forKey: .allowsFullSwipe)
      ?? Self.defaults.allowsFullSwipe
    schemaVersion = max(1, decodedSchemaVersion)
  }

  func actions(for edge: SwipeEdge) -> [SwipeAction] {
    switch edge {
    case .leading:
      return leadingActions
    case .trailing:
      return trailingActions
    }
  }

  mutating func setActions(_ actions: [SwipeAction], for edge: SwipeEdge) {
    switch edge {
    case .leading:
      leadingActions = Self.normalized(actions)
    case .trailing:
      trailingActions = Self.normalized(actions)
    }
  }

  private static func normalized(_ actions: [SwipeAction]) -> [SwipeAction] {
    var seen: Set<SwipeAction> = []
    return actions.filter { seen.insert($0).inserted }.prefix(2).map { $0 }
  }
}

enum SwipePreferenceField: String, CaseIterable, Codable, Identifiable, Sendable {
  case allowsFullSwipe
  case leadingActions
  case trailingActions

  var id: Self { self }

  var title: String {
    switch self {
    case .allowsFullSwipe:
      return "Full Swipe"
    case .leadingActions:
      return "Leading Actions"
    case .trailingActions:
      return "Trailing Actions"
    }
  }
}

enum SwipePreferenceValue: Codable, Equatable, Sendable {
  case actions([SwipeAction])
  case boolean(Bool)

  var title: String {
    switch self {
    case .actions(let actions):
      return actions.isEmpty ? "None" : actions.map(\.title).joined(separator: ", ")
    case .boolean(let value):
      return value ? "On" : "Off"
    }
  }
}

extension SwipePreferences {
  func value(for field: SwipePreferenceField) -> SwipePreferenceValue {
    switch field {
    case .allowsFullSwipe:
      return .boolean(allowsFullSwipe)
    case .leadingActions:
      return .actions(leadingActions)
    case .trailingActions:
      return .actions(trailingActions)
    }
  }

  mutating func set(_ value: SwipePreferenceValue, for field: SwipePreferenceField) {
    switch (field, value) {
    case (.allowsFullSwipe, .boolean(let enabled)):
      allowsFullSwipe = enabled
    case (.leadingActions, .actions(let actions)):
      setActions(actions, for: .leading)
    case (.trailingActions, .actions(let actions)):
      setActions(actions, for: .trailing)
    default:
      assertionFailure("Swipe preference field and value did not match")
    }
  }
}

struct SwipePreferenceSyncSnapshot: Equatable, Sendable {
  let preferences: SwipePreferences
  let updatedAt: Int64?

  init(preferences: SwipePreferences, updatedAt: Int64?) {
    self.preferences = preferences
    self.updatedAt = updatedAt
  }

  init(preferences: SwipePreferences, revision: ProductSyncRecordRevision) {
    self.preferences = preferences
    updatedAt = revision.legacyUpdatedAt
  }
}

enum SwipePreferenceConditionalSaveResult: Equatable, Sendable {
  case committed(SwipePreferenceSyncSnapshot)
  case conflict(SwipePreferenceSyncSnapshot)
}

protocol SwipePreferenceSyncing {
  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> SwipePreferenceSyncSnapshot?

  func savePreferences(
    _ preferences: SwipePreferences,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> SwipePreferenceConditionalSaveResult
}

enum SwipePreferenceSyncError: LocalizedError, Equatable {
  case missingProductSyncKeyMaterial
  case retryLimitExceeded

  var errorDescription: String? {
    switch self {
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing swipe preferences."
    case .retryLimitExceeded:
      return "Swipe preferences kept changing on another device. Try syncing again."
    }
  }
}

final class SwipePreferenceSyncService: SwipePreferenceSyncing {
  private let preferenceRecord: ProductSyncSingletonHandle<SwipePreferences>

  init(recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()) {
    preferenceRecord = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: SwipePreferences.primaryIdentifier,
        cachePolicy: .authoritative
      )
    )
  }

  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> SwipePreferenceSyncSnapshot? {
    do {
      guard let record = try await preferenceRecord.read(session: session) else { return nil }
      return SwipePreferenceSyncSnapshot(
        preferences: record.value,
        revision: record.revision
      )
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func savePreferences(
    _ preferences: SwipePreferences,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> SwipePreferenceConditionalSaveResult {
    do {
      let expectedRevision = expectedUpdatedAt.map(
        ProductSyncRecordRevision.init(legacyUpdatedAt:)
      )
      switch try await preferenceRecord.writeIfUnchanged(
        preferences,
        expectedRevision: expectedRevision,
        session: session
      ) {
      case .committed(let record):
        return .committed(
          SwipePreferenceSyncSnapshot(
            preferences: record.value,
            revision: record.revision
          ))
      case .conflict(let record):
        return .conflict(
          SwipePreferenceSyncSnapshot(
            preferences: record.value,
            revision: record.revision
          ))
      }
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func mapBoundaryError(_ error: Error) -> Error {
    switch error as? ProductSyncRecordBoundaryError {
    case .missingProductSyncKeyMaterial:
      return SwipePreferenceSyncError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      return SwipePreferenceSyncError.retryLimitExceeded
    default:
      return error
    }
  }
}
