import Foundation

struct MailboxConnectionRemovalTombstone: Codable, Equatable, Sendable {
  let authorizationGeneration: Int
  let provider: String
  let providerAccountIdentifier: String
  let removedAt: Int64

  init(
    authorizationGeneration: Int,
    provider: String,
    providerAccountIdentifier: String,
    removedAt: Int64
  ) {
    self.authorizationGeneration = authorizationGeneration
    self.provider = provider
    self.providerAccountIdentifier = providerAccountIdentifier
    self.removedAt = removedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    authorizationGeneration =
      try container.decodeIfPresent(Int.self, forKey: .authorizationGeneration) ?? 1
    provider = try container.decode(String.self, forKey: .provider)
    providerAccountIdentifier = try container.decode(
      String.self,
      forKey: .providerAccountIdentifier
    )
    removedAt = try container.decode(Int64.self, forKey: .removedAt)
  }

  var connectionId: MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: provider),
        value: providerAccountIdentifier
      )
    )
  }

  func withAuthorizationGeneration(_ authorizationGeneration: Int) -> Self {
    MailboxConnectionRemovalTombstone(
      authorizationGeneration: authorizationGeneration,
      provider: provider,
      providerAccountIdentifier: providerAccountIdentifier,
      removedAt: removedAt
    )
  }

  private enum CodingKeys: String, CodingKey {
    case authorizationGeneration
    case provider
    case providerAccountIdentifier
    case removedAt
  }
}

struct MailboxAuthorizationGenerationFloor: Codable, Equatable, Sendable {
  let authorizationGeneration: Int
  let isCommitted: Bool
  let provider: String
  let providerAccountIdentifier: String

  init(
    authorizationGeneration: Int,
    isCommitted: Bool = true,
    provider: String,
    providerAccountIdentifier: String
  ) {
    self.authorizationGeneration = authorizationGeneration
    self.isCommitted = isCommitted
    self.provider = provider
    self.providerAccountIdentifier = providerAccountIdentifier
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    authorizationGeneration = try container.decode(Int.self, forKey: .authorizationGeneration)
    isCommitted = try container.decodeIfPresent(Bool.self, forKey: .isCommitted) ?? true
    provider = try container.decode(String.self, forKey: .provider)
    providerAccountIdentifier = try container.decode(
      String.self,
      forKey: .providerAccountIdentifier
    )
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
