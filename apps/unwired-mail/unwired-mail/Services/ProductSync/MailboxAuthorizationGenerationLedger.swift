import Foundation

struct MailboxConnectionRemovalTombstone: Codable, Equatable, Sendable {
  let authorizationGeneration: Int
  let hasExplicitAuthorizationGeneration: Bool
  let provider: String
  let providerAccountIdentifier: String
  let removedAt: Int64
  let tombstoneIdentifier: String?

  init(
    authorizationGeneration: Int,
    provider: String,
    providerAccountIdentifier: String,
    removedAt: Int64,
    tombstoneIdentifier: String? = nil
  ) {
    self.authorizationGeneration = authorizationGeneration
    hasExplicitAuthorizationGeneration = true
    self.provider = provider
    self.providerAccountIdentifier = providerAccountIdentifier
    self.removedAt = removedAt
    self.tombstoneIdentifier = tombstoneIdentifier
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedAuthorizationGeneration = try container.decodeIfPresent(
      Int.self,
      forKey: .authorizationGeneration
    )
    // Legacy tombstones decode at generation 1 (definitions decode at 0) so a
    // generation-unaware re-add stays fenced until a generation-aware write.
    authorizationGeneration = decodedAuthorizationGeneration ?? 1
    hasExplicitAuthorizationGeneration = decodedAuthorizationGeneration != nil
    provider = try container.decode(String.self, forKey: .provider)
    providerAccountIdentifier = try container.decode(
      String.self,
      forKey: .providerAccountIdentifier
    )
    removedAt = try container.decode(Int64.self, forKey: .removedAt)
    tombstoneIdentifier = try container.decodeIfPresent(
      String.self,
      forKey: .tombstoneIdentifier
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(authorizationGeneration, forKey: .authorizationGeneration)
    try container.encode(provider, forKey: .provider)
    try container.encode(providerAccountIdentifier, forKey: .providerAccountIdentifier)
    try container.encode(removedAt, forKey: .removedAt)
    try container.encodeIfPresent(tombstoneIdentifier, forKey: .tombstoneIdentifier)
  }

  var connectionId: MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: provider),
        value: providerAccountIdentifier
      )
    )
  }

  var observation: MailboxConnectionRemovalObservation {
    MailboxConnectionRemovalObservation(
      connectionId: connectionId,
      removedAt: removedAt,
      tombstoneIdentifier: tombstoneIdentifier
    )
  }

  func withAuthorizationGeneration(_ authorizationGeneration: Int) -> Self {
    MailboxConnectionRemovalTombstone(
      authorizationGeneration: authorizationGeneration,
      provider: provider,
      providerAccountIdentifier: providerAccountIdentifier,
      removedAt: removedAt,
      tombstoneIdentifier: tombstoneIdentifier
    )
  }

  private enum CodingKeys: String, CodingKey {
    case authorizationGeneration
    case provider
    case providerAccountIdentifier
    case removedAt
    case tombstoneIdentifier
  }
}

struct MailboxAuthorizationGenerationFloor: Codable, Equatable, Sendable {
  let authorizationGeneration: Int
  let committedAuthorizationGeneration: Int?
  let provider: String
  let providerAccountIdentifier: String

  init(
    authorizationGeneration: Int,
    committedAuthorizationGeneration: Int? = nil,
    provider: String,
    providerAccountIdentifier: String
  ) {
    self.authorizationGeneration = authorizationGeneration
    self.committedAuthorizationGeneration = committedAuthorizationGeneration
    self.provider = provider
    self.providerAccountIdentifier = providerAccountIdentifier
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    authorizationGeneration = try container.decode(Int.self, forKey: .authorizationGeneration)
    if container.contains(.committedAuthorizationGeneration) {
      committedAuthorizationGeneration = try container.decodeIfPresent(
        Int.self,
        forKey: .committedAuthorizationGeneration
      )
    } else {
      let isCommitted = try container.decodeIfPresent(Bool.self, forKey: .isCommitted) ?? true
      committedAuthorizationGeneration = isCommitted ? authorizationGeneration : nil
    }
    provider = try container.decode(String.self, forKey: .provider)
    providerAccountIdentifier = try container.decode(
      String.self,
      forKey: .providerAccountIdentifier
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(authorizationGeneration, forKey: .authorizationGeneration)
    try container.encodeIfPresent(
      committedAuthorizationGeneration,
      forKey: .committedAuthorizationGeneration
    )
    try container.encode(
      committedAuthorizationGeneration == authorizationGeneration,
      forKey: .isCommitted
    )
    try container.encode(provider, forKey: .provider)
    try container.encode(providerAccountIdentifier, forKey: .providerAccountIdentifier)
  }

  var connectionId: MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: provider),
        value: providerAccountIdentifier
      )
    )
  }

  private enum CodingKeys: String, CodingKey {
    case authorizationGeneration
    case committedAuthorizationGeneration
    case isCommitted
    case provider
    case providerAccountIdentifier
  }
}

struct MailboxAuthorizationGenerationLedger: Codable, Equatable, Sendable {
  static let primaryIdentifier = "mailbox-authorization-generations-v1"

  var floors: [MailboxAuthorizationGenerationFloor]
  let schemaVersion: Int

  static let empty = MailboxAuthorizationGenerationLedger(floors: [], schemaVersion: 1)

  mutating func sort() {
    floors.sort { $0.connectionId.rawValue < $1.connectionId.rawValue }
  }
}
