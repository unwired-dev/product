import Foundation

/// Non-secret, device-local metadata required to choose a Share Extension Draft owner.
struct ShareExtensionCatalog: Codable, Equatable, Sendable {
  let productAccountId: String
  let profiles: [ShareExtensionProfile]
  let startupProfileId: String
  let updatedAtMilliseconds: Int64

  /// Returns the configured Startup Profile, falling back to the first available Profile.
  var startupProfile: ShareExtensionProfile? {
    profiles.first { $0.id == startupProfileId } ?? profiles.first
  }
}

/// One device-local Mail Profile projection available to the Share Extension.
struct ShareExtensionProfile: Codable, Equatable, Identifiable, Sendable {
  let colorName: String
  let defaultSendingIdentityId: String?
  let id: String
  let isLocked: Bool
  let name: String
  let sendingIdentities: [ShareExtensionSendingIdentity]
  let symbolName: String

  /// Returns the Profile default when it remains available.
  var defaultSendingIdentity: ShareExtensionSendingIdentity? {
    defaultSendingIdentityId.flatMap { identityId in
      sendingIdentities.first { $0.id == identityId }
    } ?? sendingIdentities.first
  }
}

/// One non-secret From address projected into the Share Extension.
struct ShareExtensionSendingIdentity: Codable, Equatable, Identifiable, Sendable {
  let address: String
  let connectionId: String
  let displayName: String?
  let id: String

  /// Returns a concise picker label consistent with the main composer.
  var title: String {
    displayName.map { "\($0) · \(address)" } ?? address
  }
}
