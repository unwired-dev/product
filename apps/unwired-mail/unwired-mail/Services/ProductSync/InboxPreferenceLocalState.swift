import Foundation

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

  private enum CodingKeys: String, CodingKey {
    case conflicts
    case pendingChanges
    case preferences
  }

  init(
    conflicts: [InboxPreferenceField: InboxPreferenceConflict],
    pendingChanges: [InboxPreferenceField: InboxPreferencePendingChange],
    preferences: InboxPreferences
  ) {
    self.conflicts = conflicts
    self.pendingChanges = pendingChanges
    self.preferences = preferences
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    conflicts =
      try container.decodeIfPresent(
        [InboxPreferenceField: InboxPreferenceConflict].self,
        forKey: .conflicts
      ) ?? [:]
    pendingChanges =
      try container.decodeIfPresent(
        [InboxPreferenceField: InboxPreferencePendingChange].self,
        forKey: .pendingChanges
      ) ?? [:]
    preferences =
      try container.decodeIfPresent(InboxPreferences.self, forKey: .preferences) ?? .defaults
  }
}
