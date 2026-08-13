import Foundation

/// User-owned category preferences that control visible new-mail notifications.
///
/// The category identifiers are encrypted on the trusted device before Product Sync sees them.
struct NotificationConnectionPolicy: Codable, Equatable, Identifiable, Sendable {
  let categoryIds: [String]
  let connectionId: String
  let isEnabled: Bool

  var id: String { connectionId }

  init(connectionId: String, isEnabled: Bool, categoryIds: [String]) {
    self.categoryIds = Array(Set(categoryIds.filter { !$0.isEmpty })).sorted()
    self.connectionId = connectionId
    self.isEnabled = isEnabled
  }
}

struct NotificationRules: Codable, Equatable, Sendable {
  static let legacyIdentifier = "notification-rules-primary"
  static let primaryIdentifier = "mail-workflow-preferences:notifications-v2"

  let categoryIds: [String]
  let connectionPolicies: [NotificationConnectionPolicy]
  let isEnabled: Bool
  let schemaVersion: Int

  init(categoryIds: [String]) {
    self.init(
      isEnabled: !categoryIds.isEmpty,
      categoryIds: categoryIds,
      connectionPolicies: []
    )
  }

  init(
    isEnabled: Bool,
    categoryIds: [String],
    connectionPolicies: [NotificationConnectionPolicy]
  ) {
    self.categoryIds = Array(Set(categoryIds.filter { !$0.isEmpty })).sorted()
    self.connectionPolicies = Dictionary(
      connectionPolicies.map { ($0.connectionId, $0) },
      uniquingKeysWith: { _, last in last }
    ).values.sorted { $0.connectionId < $1.connectionId }
    self.isEnabled = isEnabled
    schemaVersion = 2
  }

  func allows(categoryId: String, connectionId: MailboxConnectionId? = nil) -> Bool {
    guard isEnabled else { return false }
    guard
      let connectionId,
      let policy = connectionPolicies.first(where: {
        $0.connectionId == connectionId.rawValue
      })
    else {
      return categoryIds.contains(categoryId)
    }
    return policy.isEnabled && policy.categoryIds.contains(categoryId)
  }

  func allowsNotifications(connectionId: MailboxConnectionId) -> Bool {
    guard isEnabled else { return false }
    guard
      let policy = connectionPolicies.first(where: {
        $0.connectionId == connectionId.rawValue
      })
    else {
      return !categoryIds.isEmpty
    }
    return policy.isEnabled && !policy.categoryIds.isEmpty
  }

  private enum CodingKeys: String, CodingKey {
    case categoryIds
    case connectionPolicies
    case isEnabled
    case schemaVersion
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let categoryIds = try container.decodeIfPresent([String].self, forKey: .categoryIds) ?? []
    self.init(
      isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled)
        ?? !categoryIds.isEmpty,
      categoryIds: categoryIds,
      connectionPolicies: try container.decodeIfPresent(
        [NotificationConnectionPolicy].self,
        forKey: .connectionPolicies
      ) ?? []
    )
  }
}
