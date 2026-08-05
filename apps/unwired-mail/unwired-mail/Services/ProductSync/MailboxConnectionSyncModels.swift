import Foundation

enum MailboxConnectionSyncError: LocalizedError, Equatable {
  case concurrentModification
  case connectionRemoved(MailboxConnectionRemovalObservation)
  case invalidDefaultSendingConnection
  case missingProductSyncKeyMaterial

  var errorDescription: String? {
    switch self {
    case .concurrentModification:
      return "Mailbox Connections changed on another device. Refresh and try again."
    case .connectionRemoved:
      return "This Mailbox Connection was removed on another device. Refresh, then add it again."
    case .invalidDefaultSendingConnection:
      return "Choose an existing Mailbox Connection as the default sender."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing Mailbox Connections."
    }
  }
}

struct MailboxConnectionSyncPayload: Codable, Equatable, Sendable {
  static let primaryIdentifier = "mailbox-connections-primary"

  var connections: [MailboxConnectionDefinition]
  var defaultSendingConnectionProvider: String?
  var defaultSendingProviderAccountIdentifier: String?
  var removals: [MailboxConnectionRemovalTombstone]
  let schemaVersion: Int

  static let empty = MailboxConnectionSyncPayload(
    connections: [],
    defaultSendingConnectionProvider: nil,
    defaultSendingProviderAccountIdentifier: nil,
    removals: [],
    schemaVersion: 1
  )

  var defaultSendingConnectionId: MailboxConnectionId? {
    guard
      let defaultSendingConnectionProvider,
      let defaultSendingProviderAccountIdentifier
    else {
      return nil
    }
    return MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: defaultSendingConnectionProvider),
        value: defaultSendingProviderAccountIdentifier
      )
    )
  }

  mutating func sort() {
    connections.sort { $0.id.rawValue < $1.id.rawValue }
    removals.sort { $0.connectionId.rawValue < $1.connectionId.rawValue }
  }
}

struct MailboxConnectionSyncPayloadCodec {
  func snapshot(
    _ payload: MailboxConnectionSyncPayload,
    updatedAt: Int64?
  ) -> MailboxConnectionSyncSnapshot {
    let activeConnectionsById = Dictionary(
      payload.connections.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let removedConnections = payload.removals.filter { removal in
      guard let activeConnection = activeConnectionsById[removal.connectionId] else {
        return true
      }
      return activeConnection.authorizationGeneration < removal.authorizationGeneration
    }
    let authorizationCleanupConnections = payload.removals.filter { removal in
      activeConnectionsById[removal.connectionId]?.authorizationGeneration
        == removal.authorizationGeneration
    }
    let localCleanupGenerations = Dictionary(
      (removedConnections + authorizationCleanupConnections).map {
        ($0.connectionId, $0.authorizationGeneration)
      },
      uniquingKeysWith: max
    )
    return MailboxConnectionSyncSnapshot(
      connections: payload.connections.sorted { $0.id.rawValue < $1.id.rawValue },
      defaultSendingConnectionId: payload.defaultSendingConnectionId,
      removedConnectionIds: removedConnections.map(\.connectionId)
        .sorted { $0.rawValue < $1.rawValue },
      updatedAt: updatedAt,
      authorizationCleanupConnectionIds: authorizationCleanupConnections.map(\.connectionId)
        .sorted { $0.rawValue < $1.rawValue },
      localCleanupGenerations: localCleanupGenerations
    )
  }
}

extension MailboxConnectionSyncPayload {
  // swiftlint:disable:next function_body_length
  func applyingGenerationFloors(
    _ ledger: MailboxAuthorizationGenerationLedger
  ) -> MailboxConnectionSyncPayload {
    var payload = self
    for floor in ledger.floors {
      guard let committedGeneration = floor.committedAuthorizationGeneration else {
        continue
      }
      if let connectionIndex = payload.connections.firstIndex(where: {
        $0.id == floor.connectionId
      }) {
        let connection = payload.connections[connectionIndex]
        let existingRemoval = payload.removals.first {
          $0.connectionId == floor.connectionId
        }
        let hasLegacyRemoval = existingRemoval?.hasExplicitAuthorizationGeneration == false
        let requiredGeneration =
          if hasLegacyRemoval {
            max(connection.authorizationGeneration, committedGeneration + 1)
          } else {
            committedGeneration
          }
        guard connection.authorizationGeneration < requiredGeneration || hasLegacyRemoval else {
          continue
        }
        payload.connections[connectionIndex] = connection.withAuthorizationGeneration(
          requiredGeneration
        )
        payload.removals.removeAll { $0.connectionId == floor.connectionId }
        payload.removals.append(
          MailboxConnectionRemovalTombstone(
            // Equality keeps the active connection in the local-cleanup set, not the removed set.
            authorizationGeneration: requiredGeneration,
            provider: floor.provider,
            providerAccountIdentifier: floor.providerAccountIdentifier,
            removedAt: existingRemoval?.removedAt ?? 0,
            tombstoneIdentifier: existingRemoval?.tombstoneIdentifier
          )
        )
        continue
      }
      if let removalIndex = payload.removals.firstIndex(where: {
        $0.connectionId == floor.connectionId
      }) {
        let removal = payload.removals[removalIndex]
        let requiredGeneration =
          if removal.hasExplicitAuthorizationGeneration {
            committedGeneration
          } else {
            committedGeneration + 1
          }
        payload.removals[removalIndex] = removal.withAuthorizationGeneration(
          max(removal.authorizationGeneration, requiredGeneration)
        )
        continue
      }
      payload.removals.append(
        MailboxConnectionRemovalTombstone(
          authorizationGeneration: committedGeneration,
          provider: floor.provider,
          providerAccountIdentifier: floor.providerAccountIdentifier,
          removedAt: 0
        )
      )
    }
    return payload
  }
}
