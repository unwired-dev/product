import Foundation

struct MailProfileAppearance: Codable, Equatable, Sendable {
  static let allowedColorNames = ["blue", "indigo", "purple", "pink", "red", "orange", "teal"]
  static let allowedSymbolNames = [
    "person.crop.circle",
    "briefcase",
    "house",
    "graduationcap",
    "heart",
    "star",
    "building.2",
  ]

  let colorName: String
  let symbolName: String

  static let `default` = MailProfileAppearance(
    colorName: "blue",
    symbolName: "person.crop.circle"
  )

  var accessibilityDescription: String {
    "\(Self.accessibleSymbolName(symbolName)), \(colorName.capitalized)"
  }

  var isCurated: Bool {
    Self.allowedColorNames.contains(colorName) && Self.allowedSymbolNames.contains(symbolName)
  }

  private static func accessibleSymbolName(_ symbolName: String) -> String {
    switch symbolName {
    case "person.crop.circle": return "Personal"
    case "briefcase": return "Work"
    case "house": return "Home"
    case "graduationcap": return "School"
    case "heart": return "Favorite"
    case "star": return "Star"
    case "building.2": return "Organization"
    default: return "Profile"
    }
  }
}

struct MailProfileWorkspaceSelection: Equatable, Sendable {
  let activeProfileId: MailProfileId
  let snapshot: MailProfileSyncSnapshot

  init(
    snapshot: MailProfileSyncSnapshot,
    targetedProfileId: MailProfileId? = nil,
    restoredProfileId: MailProfileId? = nil,
    startupProfileId: MailProfileId? = nil
  ) {
    self.snapshot = snapshot
    let knownProfileIds = Set(snapshot.profiles.map(\.id))
    activeProfileId =
      [targetedProfileId, restoredProfileId, startupProfileId, snapshot.defaultProfileId]
      .compactMap { $0 }
      .first(where: knownProfileIds.contains)
      ?? snapshot.defaultProfileId
  }

  var activeProfile: MailProfileDefinition? {
    snapshot.profiles.first { $0.id == activeProfileId }
  }

  func activating(
    _ profileId: MailProfileId,
    parkCurrentDraft: () throws -> Void = {}
  ) throws -> Self {
    guard snapshot.profiles.contains(where: { $0.id == profileId }) else {
      throw MailProfileSyncError.profileNotFound
    }
    guard profileId != activeProfileId else { return self }
    try parkCurrentDraft()
    return MailProfileWorkspaceSelection(
      snapshot: snapshot,
      targetedProfileId: profileId
    )
  }

  func connections(from connections: [MailboxConnection]) -> [MailboxConnection] {
    connections.filter { snapshot.assignments[$0.id] == activeProfileId }
  }

  func owns(_ connectionId: MailboxConnectionId) -> Bool {
    snapshot.assignments[connectionId] == activeProfileId
  }
}

protocol MailProfileStartupSelectionPersisting {
  func load(productAccountId: String) -> MailProfileId?
  func save(_ profileId: MailProfileId, productAccountId: String)
}

struct UserDefaultsMailProfileStartupStore: MailProfileStartupSelectionPersisting {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load(productAccountId: String) -> MailProfileId? {
    defaults.string(forKey: key(productAccountId)).map(MailProfileId.init(rawValue:))
  }

  func save(_ profileId: MailProfileId, productAccountId: String) {
    defaults.set(profileId.rawValue, forKey: key(productAccountId))
  }

  private func key(_ productAccountId: String) -> String {
    "mail-profile.startup.v1.\(productAccountId)"
  }
}

struct MailProfileDeepLink: Equatable, Sendable {
  static let profileIdQueryName = "profileId"
  static let scheme = "unwired-mail"

  let profileId: MailProfileId

  init(profileId: MailProfileId) {
    self.profileId = profileId
  }

  init?(url: URL) {
    guard url.scheme?.lowercased() == Self.scheme else { return nil }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let queryProfileId = components?.queryItems?.first {
      $0.name.caseInsensitiveCompare(Self.profileIdQueryName) == .orderedSame
    }?.value
    let pathProfileId =
      url.host?.lowercased() == "profile"
      ? url.pathComponents.dropFirst().first
      : nil
    guard let rawValue = queryProfileId ?? pathProfileId, !rawValue.isEmpty else { return nil }
    profileId = MailProfileId(rawValue: rawValue)
  }

  var url: URL {
    var components = URLComponents()
    components.scheme = Self.scheme
    components.host = "mail"
    components.queryItems = [
      URLQueryItem(name: Self.profileIdQueryName, value: profileId.rawValue)
    ]
    return components.url!
  }
}
