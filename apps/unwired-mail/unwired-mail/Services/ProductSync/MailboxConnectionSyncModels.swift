import CryptoKit
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

struct MailProfileId: Codable, Hashable, RawRepresentable, Sendable {
  let rawValue: String

  static func defaultProfile(productAccountId: String) -> Self {
    let input = Data("dev.unwired.mail.default-profile.v1\0\(productAccountId)".utf8)
    let digest = Data(SHA256.hash(data: input)).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return MailProfileId(rawValue: digest)
  }
}

struct MailProfileQuietState: Codable, Equatable, Sendable {
  let isQuiet: Bool
  let quietUntil: Int64?

  static let inactive = MailProfileQuietState(isQuiet: false, quietUntil: nil)
}

struct MailProfileRecordScope: Codable, Equatable, Sendable {
  /// `nil` preserves the existing Product Account-scoped identifiers for the migrated profile.
  /// New profiles use their opaque Profile identifier as a namespace.
  let namespace: String?

  static let legacyProductAccount = MailProfileRecordScope(namespace: nil)

  static func profile(_ profileId: MailProfileId) -> Self {
    MailProfileRecordScope(namespace: profileId.rawValue)
  }

  func productSyncIdentifier(_ legacyIdentifier: String) -> String {
    guard let namespace else { return legacyIdentifier }
    return "mail-profile-v1.\(namespace).\(legacyIdentifier)"
  }
}

struct MailProfileDefinition: Codable, Equatable, Identifiable, Sendable {
  let id: MailProfileId
  var appearance: MailProfileAppearance
  var name: String
  let recordScope: MailProfileRecordScope
  var quietState: MailProfileQuietState

  static func defaultProfile(productAccountId: String) -> Self {
    MailProfileDefinition(
      id: .defaultProfile(productAccountId: productAccountId),
      appearance: .default,
      name: "Default Profile",
      recordScope: .legacyProductAccount,
      quietState: .inactive
    )
  }
}

struct MailProfileConnectionAssignment: Codable, Equatable, Sendable {
  let connectionId: MailboxConnectionId
  var profileId: MailProfileId
}

enum MailProfileEditableField: String, Codable, CaseIterable, Sendable {
  case appearance
  case name
  case quietState
}

enum MailProfileFieldValue: Codable, Equatable, Sendable {
  case appearance(MailProfileAppearance)
  case name(String)
  case quietState(MailProfileQuietState)
}

struct MailProfileConflictCopy: Codable, Equatable, Identifiable, Sendable {
  let baseValue: MailProfileFieldValue
  let competingValue: MailProfileFieldValue
  let field: MailProfileEditableField
  let id: String
  let profileId: MailProfileId
  let synchronizedValue: MailProfileFieldValue
}

struct MailProfileSyncPayload: Codable, Equatable, Sendable {
  static let primaryIdentifier = "mail-profiles-primary"

  var assignments: [MailProfileConnectionAssignment]
  var conflicts: [MailProfileConflictCopy]
  var defaultProfileId: MailProfileId?
  var profiles: [MailProfileDefinition]
  let schemaVersion: Int

  static let empty = MailProfileSyncPayload(
    assignments: [],
    conflicts: [],
    defaultProfileId: nil,
    profiles: [],
    schemaVersion: 1
  )

  mutating func migrateLegacyProductAccount(
    productAccountId: String,
    activeConnectionIds: [MailboxConnectionId],
    removedConnectionIds: [MailboxConnectionId]
  ) -> Bool {
    var changed = false
    let defaultProfile = MailProfileDefinition.defaultProfile(productAccountId: productAccountId)
    if profiles.isEmpty {
      profiles = [defaultProfile]
      defaultProfileId = defaultProfile.id
      changed = true
    } else if defaultProfileId == nil {
      if !profiles.contains(where: { $0.id == defaultProfile.id }) {
        profiles.append(defaultProfile)
      }
      defaultProfileId = defaultProfile.id
      changed = true
    }

    var profileIds = Set(profiles.map(\.id))
    if defaultProfileId.map(profileIds.contains) != true {
      if !profileIds.contains(defaultProfile.id) {
        profiles.append(defaultProfile)
        profileIds.insert(defaultProfile.id)
      }
      defaultProfileId = defaultProfile.id
      changed = true
    }
    guard let defaultProfileId else { return changed }
    let removedIds = Set(removedConnectionIds)
    let retainedAssignments = assignments.filter {
      !removedIds.contains($0.connectionId) && profileIds.contains($0.profileId)
    }
    if retainedAssignments != assignments {
      assignments = retainedAssignments
      changed = true
    }
    var assignedIds = Set(assignments.map(\.connectionId))
    for connectionId in activeConnectionIds where !assignedIds.contains(connectionId) {
      assignments.append(
        MailProfileConnectionAssignment(
          connectionId: connectionId,
          profileId: defaultProfileId
        )
      )
      assignedIds.insert(connectionId)
      changed = true
    }
    sort()
    return changed
  }

  mutating func sort() {
    assignments.sort { $0.connectionId.rawValue < $1.connectionId.rawValue }
    conflicts.sort {
      if $0.profileId == $1.profileId { return $0.id < $1.id }
      return $0.profileId.rawValue < $1.profileId.rawValue
    }
    profiles.sort { $0.id.rawValue < $1.id.rawValue }
  }
}

struct MailProfileSyncSnapshot: Equatable, Sendable {
  let assignments: [MailboxConnectionId: MailProfileId]
  let conflicts: [MailProfileConflictCopy]
  let defaultProfileId: MailProfileId
  let profiles: [MailProfileDefinition]
  let updatedAt: Int64?

  func connections(
    in profileId: MailProfileId,
    from connections: [MailboxConnectionDefinition]
  ) throws -> [MailboxConnectionDefinition] {
    guard profiles.contains(where: { $0.id == profileId }) else {
      throw MailProfileSyncError.profileNotFound
    }
    return connections.filter { assignments[$0.id] == profileId }
  }
}

enum MailProfileSyncError: LocalizedError, Equatable {
  case concurrentModification
  case invalidProfileName
  case invalidProfileState
  case missingProductSyncKeyMaterial
  case profileNotFound

  var errorDescription: String? {
    switch self {
    case .concurrentModification:
      return "Mail Profiles changed on another device. Refresh and try again."
    case .invalidProfileName:
      return "Choose a unique Mail Profile name between 1 and 40 characters."
    case .invalidProfileState:
      return "Mail Profile ownership is incomplete. Refresh Product Sync before continuing."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing Mail Profiles."
    case .profileNotFound:
      return "The selected Mail Profile no longer exists."
    }
  }
}
