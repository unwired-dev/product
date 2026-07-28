import CryptoKit
import Foundation

struct MailboxConnectionDefinition: Codable, Equatable, Identifiable, Sendable {
  let authorizationGeneration: Int
  let connectedAt: Int64
  let displayName: String
  let ewsDefinition: EWSConnectionDefinition?
  let genericMailDefinition: GenericMailConnectionDefinition?
  let provider: String
  let providerAccountIdentifier: String
  /// A versioned hash derived from `provider` and `providerAccountIdentifier`.
  /// Retained for backward compatibility with persisted/synced connection definitions.
  let stableProviderConnectionKey: String

  init(
    authorizationGeneration: Int = 0,
    connectedAt: Int64,
    displayName: String,
    ewsDefinition: EWSConnectionDefinition? = nil,
    genericMailDefinition: GenericMailConnectionDefinition? = nil,
    provider: String,
    providerAccountIdentifier: String,
    stableProviderConnectionKey: String
  ) {
    self.authorizationGeneration = authorizationGeneration
    self.connectedAt = connectedAt
    self.displayName = displayName
    self.ewsDefinition = ewsDefinition
    self.genericMailDefinition = genericMailDefinition
    self.provider = provider
    self.providerAccountIdentifier = providerAccountIdentifier
    self.stableProviderConnectionKey = stableProviderConnectionKey
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    authorizationGeneration =
      try container.decodeIfPresent(Int.self, forKey: .authorizationGeneration) ?? 0
    connectedAt = try container.decode(Int64.self, forKey: .connectedAt)
    displayName = try container.decode(String.self, forKey: .displayName)
    ewsDefinition = try container.decodeIfPresent(
      EWSConnectionDefinition.self,
      forKey: .ewsDefinition
    )
    genericMailDefinition = try container.decodeIfPresent(
      GenericMailConnectionDefinition.self,
      forKey: .genericMailDefinition
    )
    provider = try container.decode(String.self, forKey: .provider)
    providerAccountIdentifier = try container.decode(
      String.self,
      forKey: .providerAccountIdentifier
    )
    stableProviderConnectionKey = try container.decode(
      String.self,
      forKey: .stableProviderConnectionKey
    )
  }

  var id: MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: provider),
        value: providerAccountIdentifier
      )
    )
  }

  func withAuthorizationGeneration(_ authorizationGeneration: Int) -> Self {
    MailboxConnectionDefinition(
      authorizationGeneration: authorizationGeneration,
      connectedAt: connectedAt,
      displayName: displayName,
      ewsDefinition: ewsDefinition,
      genericMailDefinition: genericMailDefinition,
      provider: provider,
      providerAccountIdentifier: providerAccountIdentifier,
      stableProviderConnectionKey: stableProviderConnectionKey
    )
  }

  private enum CodingKeys: String, CodingKey {
    case authorizationGeneration
    case connectedAt
    case displayName
    case ewsDefinition
    case genericMailDefinition
    case provider
    case providerAccountIdentifier
    case stableProviderConnectionKey
  }
}

extension MailboxConnection {
  var definition: MailboxConnectionDefinition {
    return MailboxConnectionDefinition(
      authorizationGeneration: authorizationGeneration,
      connectedAt: connectedAt,
      displayName: displayName,
      provider: providerId.rawValue,
      providerAccountIdentifier: providerMailboxIdentity.value,
      stableProviderConnectionKey: stableMailboxConnectionKey(
        provider: providerId.rawValue,
        providerAccountIdentifier: providerMailboxIdentity.value
      )
    )
  }
}

extension GenericMailConnectionDefinition {
  func synchronizedDefinition(
    authorizationGeneration: Int = 0,
    connectedAt: Int64
  ) -> MailboxConnectionDefinition {
    MailboxConnectionDefinition(
      authorizationGeneration: authorizationGeneration,
      connectedAt: connectedAt,
      displayName: emailAddress,
      genericMailDefinition: self,
      provider: connectionId.providerId.rawValue,
      providerAccountIdentifier: connectionId.providerMailboxIdentity.value,
      stableProviderConnectionKey: stableMailboxConnectionKey(
        provider: connectionId.providerId.rawValue,
        providerAccountIdentifier: connectionId.providerMailboxIdentity.value
      )
    )
  }
}

extension EWSConnectionDefinition {
  func synchronizedDefinition(
    authorizationGeneration: Int = 0,
    connectedAt: Int64,
    displayName: String
  ) -> MailboxConnectionDefinition {
    MailboxConnectionDefinition(
      authorizationGeneration: authorizationGeneration,
      connectedAt: connectedAt,
      displayName: displayName,
      ewsDefinition: self,
      provider: connectionId.providerId.rawValue,
      providerAccountIdentifier: connectionId.providerMailboxIdentity.value,
      stableProviderConnectionKey: stableMailboxConnectionKey(
        provider: connectionId.providerId.rawValue,
        providerAccountIdentifier: connectionId.providerMailboxIdentity.value
      )
    )
  }
}

private func stableMailboxConnectionKey(
  provider: String,
  providerAccountIdentifier: String
) -> String {
  let keyInput = Data(
    "dev.unwired.mail.connection-key.v1\0\(provider)\0\(providerAccountIdentifier)".utf8
  )
  return Data(SHA256.hash(data: keyInput)).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

extension MailboxConnectionDefinition {
  func mailboxConnection(
    productAccountId: String,
    trustedDeviceId: String
  ) -> MailboxConnection {
    MailboxConnection(
      authorizationGeneration: authorizationGeneration,
      authorizationState: .required,
      capabilities: .none,
      connectedAt: connectedAt,
      displayName: displayName,
      id: id,
      lastVerifiedAt: 0,
      productAccountId: ProductAccountId(productAccountId),
      trustedDeviceId: trustedDeviceId,
      updatedAt: connectedAt
    )
  }
}

struct MailboxConnectionSyncSnapshot: Equatable, Sendable {
  let connections: [MailboxConnectionDefinition]
  let defaultSendingConnectionId: MailboxConnectionId?
  let removedConnectionIds: [MailboxConnectionId]
  let updatedAt: Int64?

  var hasAuthoritativeState: Bool {
    updatedAt != nil
  }
}

protocol MailboxConnectionDefinitionSyncing {
  func loadSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot

  func loadSnapshotForProviderAccess(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot

  @discardableResult
  func reconcileConnections(
    _ connections: [MailboxConnectionDefinition],
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot

  @discardableResult
  func removeConnection(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot

  @discardableResult
  func saveConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot

  @discardableResult
  func saveDefinition(
    _ definition: MailboxConnectionDefinition,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot

  @discardableResult
  func setDefaultSendingConnection(
    _ connectionId: MailboxConnectionId?,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot
}

extension MailboxConnectionDefinitionSyncing {
  func loadSnapshotForProviderAccess(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    try await loadSnapshot(session: session)
  }
}
