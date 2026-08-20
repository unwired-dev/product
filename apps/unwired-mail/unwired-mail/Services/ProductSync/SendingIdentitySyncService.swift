import CryptoKit
import Foundation
import Observation
import Security

// swiftlint:disable file_length

/// Identifies one authorized From address within its owning Mailbox Connection.
struct SendingIdentityId: Codable, Hashable, RawRepresentable, Sendable {
  let rawValue: String

  /// Creates a stable opaque identifier for one connection-scoped address.
  static func make(connectionId: MailboxConnectionId, address: String) -> Self {
    let normalizedAddress = SendingIdentity.normalizedAddress(address)
    let input = Data(
      "dev.unwired.mail.sending-identity.v1\0\(connectionId.rawValue)\0\(normalizedAddress)".utf8
    )
    let digest = Data(SHA256.hash(data: input)).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return SendingIdentityId(rawValue: digest)
  }
}

/// Describes how a Sending Identity became eligible for use.
enum SendingIdentityVerification: String, Codable, Sendable {
  case manualProviderTest
  case providerConfirmed
}

/// A non-secret, Profile-owned From address tied to one Mailbox Connection.
struct SendingIdentity: Codable, Equatable, Identifiable, Sendable {
  let address: String
  let connectionId: MailboxConnectionId
  let displayName: String?
  let id: SendingIdentityId
  let verification: SendingIdentityVerification

  /// Creates a normalized Sending Identity.
  init(
    address: String,
    connectionId: MailboxConnectionId,
    displayName: String? = nil,
    verification: SendingIdentityVerification
  ) {
    let normalizedAddress = Self.normalizedAddress(address)
    self.address = normalizedAddress
    self.connectionId = connectionId
    let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.displayName = trimmedDisplayName?.isEmpty == false ? trimmedDisplayName : nil
    id = .make(connectionId: connectionId, address: normalizedAddress)
    self.verification = verification
  }

  /// Returns the RFC mailbox value used in the From header.
  var headerValue: String {
    guard let displayName else { return address }
    return "\(displayName) <\(address)>"
  }

  /// Returns a concise label for pickers and Settings.
  var title: String {
    displayName.map { "\($0) · \(address)" } ?? address
  }

  /// Normalizes an RFC mailbox value for identity comparison.
  static func normalizedAddress(_ value: String) -> String {
    let parsed = RFCMailboxHeaderParser.mailboxes(in: value)?.first?.emailAddress ?? value
    return parsed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

/// The synchronized set of Sending Identities owned by one Mail Profile.
struct SendingIdentityPreferences: Codable, Equatable, Sendable {
  static let supportedSchemaVersion = 1

  var defaultIdentityId: SendingIdentityId?
  var identities: [SendingIdentity]
  let schemaVersion: Int

  /// Creates a normalized preference value.
  init(
    identities: [SendingIdentity] = [],
    defaultIdentityId: SendingIdentityId? = nil
  ) {
    self.defaultIdentityId = defaultIdentityId
    self.identities = identities
    schemaVersion = Self.supportedSchemaVersion
    normalize()
  }

  private enum CodingKeys: String, CodingKey {
    case defaultIdentityId
    case identities
    case schemaVersion
  }

  /// Decodes legacy and current identity preferences conservatively.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard decodedSchemaVersion <= Self.supportedSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Sending Identity data is newer than this client supports."
      )
    }
    defaultIdentityId = try container.decodeIfPresent(
      SendingIdentityId.self,
      forKey: .defaultIdentityId
    )
    identities = try container.decodeIfPresent([SendingIdentity].self, forKey: .identities) ?? []
    schemaVersion = max(1, decodedSchemaVersion)
    normalize()
  }

  /// Returns the selected default identity when it remains available.
  var defaultIdentity: SendingIdentity? {
    defaultIdentityId.flatMap { identityId in identities.first { $0.id == identityId } }
  }

  /// Returns identities belonging to one connection.
  func identities(for connectionId: MailboxConnectionId) -> [SendingIdentity] {
    identities.filter { $0.connectionId == connectionId }
  }

  /// Returns the authorized identity that received a message, if one is unambiguous.
  func receivingIdentity(for message: MailboxMessageMetadata) -> SendingIdentity? {
    let candidateAddresses = Set(
      ((message.recipientHeaders ?? []) + (message.bccRecipients ?? []))
        .flatMap { RFCMailboxHeaderParser.mailboxes(in: $0) ?? [] }
        .map { SendingIdentity.normalizedAddress($0.emailAddress) }
    )
    let matches = identities(for: message.connectionId).filter {
      candidateAddresses.contains($0.address)
    }
    return matches.count == 1 ? matches[0] : nil
  }

  /// Reconciles current connections and provider-confirmed addresses without deleting manual aliases.
  mutating func reconcile(
    connections: [MailboxConnection],
    connectionsAreAuthoritative: Bool = true,
    providerConfirmedAddresses: [MailboxConnectionId: [String]] = [:],
    legacyDefaultConnectionId: MailboxConnectionId?
  ) {
    let connectionIds = Set(connections.map(\.id))
    var identitiesById = Dictionary(
      uniqueKeysWithValues:
        identities
        .filter { identity in
          guard connectionsAreAuthoritative else { return true }
          return connectionIds.contains(identity.connectionId)
        }
        .filter { identity in
          guard identity.verification == .providerConfirmed,
            providerConfirmedAddresses[identity.connectionId] != nil
          else { return true }
          return false
        }
        .map { ($0.id, $0) }
    )
    for connection in connections {
      let primaryAddress = SendingIdentity.normalizedAddress(connection.displayName)
      if RFCMailboxHeaderParser.mailboxes(in: primaryAddress)?.count == 1 {
        let primary = SendingIdentity(
          address: primaryAddress,
          connectionId: connection.id,
          verification: .providerConfirmed
        )
        identitiesById[primary.id] = primary
      }
      for address in providerConfirmedAddresses[connection.id, default: []] {
        guard RFCMailboxHeaderParser.mailboxes(in: address)?.count == 1 else { continue }
        let identity = SendingIdentity(
          address: address,
          connectionId: connection.id,
          verification: .providerConfirmed
        )
        identitiesById[identity.id] = identity
      }
    }
    identities = identitiesById.values.sorted(by: Self.sortIdentities)
    if defaultIdentity == nil {
      defaultIdentityId =
        legacyDefaultConnectionId.flatMap { connectionId in
          identities.first { $0.connectionId == connectionId }?.id
        } ?? identities.first?.id
    }
  }

  /// Adds a manual alias only after its local provider test succeeds.
  mutating func addManuallyVerified(_ identity: SendingIdentity) {
    identities.removeAll { $0.id == identity.id }
    identities.append(identity)
    identities.sort(by: Self.sortIdentities)
    defaultIdentityId = defaultIdentityId ?? identity.id
  }

  /// Selects an available identity as the Profile default.
  mutating func setDefault(_ identityId: SendingIdentityId) throws {
    guard identities.contains(where: { $0.id == identityId }) else {
      throw SendingIdentityError.identityUnavailable
    }
    defaultIdentityId = identityId
  }

  private mutating func normalize() {
    identities = Dictionary(
      identities.map { ($0.id, $0) },
      uniquingKeysWith: { existing, candidate in
        candidate.verification == .providerConfirmed ? candidate : existing
      }
    ).values.sorted(by: Self.sortIdentities)
    if defaultIdentity == nil { defaultIdentityId = identities.first?.id }
  }

  private static func sortIdentities(_ lhs: SendingIdentity, _ rhs: SendingIdentity) -> Bool {
    if lhs.connectionId != rhs.connectionId {
      return lhs.connectionId.rawValue < rhs.connectionId.rawValue
    }
    return lhs.address < rhs.address
  }
}

/// A revisioned synchronized Sending Identity snapshot.
struct SendingIdentitySyncSnapshot: Equatable, Sendable {
  let preferences: SendingIdentityPreferences
  let updatedAt: Int64?
}

/// The result of a conditional Sending Identity save.
enum SendingIdentityConditionalSaveResult: Equatable, Sendable {
  case committed(SendingIdentitySyncSnapshot)
  case conflict(SendingIdentitySyncSnapshot)
}

/// Synchronizes non-secret Sending Identity definitions through encrypted Product Sync.
protocol SendingIdentitySyncing {
  func load(session: ProductAccountSessionSnapshot) async throws -> SendingIdentitySyncSnapshot?
  func save(
    _ preferences: SendingIdentityPreferences,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> SendingIdentityConditionalSaveResult
}

/// Errors surfaced by Sending Identity selection and verification.
enum SendingIdentityError: LocalizedError, Equatable {
  case identityUnavailable
  case invalidAddress
  case invalidVerificationCode
  case missingProductSyncKeyMaterial
  case retryLimitExceeded
  case verificationExpired

  var errorDescription: String? {
    switch self {
    case .identityUnavailable:
      return "Choose an available From address before sending."
    case .invalidAddress:
      return "Enter one valid email address."
    case .invalidVerificationCode:
      return "That verification code does not match."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing Sending Identities."
    case .retryLimitExceeded:
      return "Sending Identities kept changing on another device. Try syncing again."
    case .verificationExpired:
      return "This verification code expired. Send a new code."
    }
  }
}

/// The live encrypted Product Sync implementation for one Mail Profile.
final class SendingIdentitySyncService: SendingIdentitySyncing {
  private let record: ProductSyncSingletonHandle<SendingIdentityPreferences>

  /// Creates a Profile-scoped Sending Identity service.
  init(
    recordScope: MailProfileRecordScope = .legacyProductAccount,
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()
  ) {
    record = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: recordScope.productSyncIdentifier("sending-identities-primary"),
        cachePolicy: .authoritativeWithCiphertextFallback
      )
    )
  }

  func load(
    session: ProductAccountSessionSnapshot
  ) async throws -> SendingIdentitySyncSnapshot? {
    do {
      guard let loaded = try await record.read(session: session) else { return nil }
      return SendingIdentitySyncSnapshot(
        preferences: loaded.value,
        updatedAt: loaded.revision.legacyUpdatedAt
      )
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func save(
    _ preferences: SendingIdentityPreferences,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> SendingIdentityConditionalSaveResult {
    do {
      let expectedRevision = expectedUpdatedAt.map(
        ProductSyncRecordRevision.init(legacyUpdatedAt:)
      )
      switch try await record.writeIfUnchanged(
        preferences,
        expectedRevision: expectedRevision,
        session: session
      ) {
      case .committed(let saved):
        return .committed(
          SendingIdentitySyncSnapshot(
            preferences: saved.value,
            updatedAt: saved.revision.legacyUpdatedAt
          ))
      case .conflict(let current):
        return .conflict(
          SendingIdentitySyncSnapshot(
            preferences: current.value,
            updatedAt: current.revision.legacyUpdatedAt
          ))
      }
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func mapBoundaryError(_ error: Error) -> Error {
    switch error as? ProductSyncRecordBoundaryError {
    case .missingProductSyncKeyMaterial:
      return SendingIdentityError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      return SendingIdentityError.retryLimitExceeded
    default:
      return error
    }
  }
}

/// A device-local one-time-code challenge for a manual alias.
struct SendingIdentityVerificationChallenge: Codable, Equatable, Sendable {
  let address: String
  let code: String
  let connectionId: MailboxConnectionId
  let expiresAtMilliseconds: Int64
}

/// Persists manual alias challenges only on the current device.
protocol SendingIdentityChallengePersisting {
  func load(productAccountId: String, recordScope: MailProfileRecordScope) throws
    -> SendingIdentityVerificationChallenge?
  func save(
    _ challenge: SendingIdentityVerificationChallenge?,
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws
}

/// Stores device-local manual alias challenges in ThisDeviceOnly Keychain storage.
struct KeychainIdentityChallengeStore: SendingIdentityChallengePersisting {
  private static let service = "dev.unwired.mail.sending-identity-challenges"

  func load(
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws -> SendingIdentityVerificationChallenge? {
    let account = key(productAccountId, recordScope)
    removeLegacyChallenge(for: account)
    guard
      let encoded = try KeychainStore.readString(
        service: Self.service,
        account: account
      ),
      let data = encoded.data(using: .utf8)
    else { return nil }
    return try JSONDecoder().decode(SendingIdentityVerificationChallenge.self, from: data)
  }

  func save(
    _ challenge: SendingIdentityVerificationChallenge?,
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws {
    let account = key(productAccountId, recordScope)
    removeLegacyChallenge(for: account)
    if let challenge {
      let data = try JSONEncoder().encode(challenge)
      guard let encoded = String(data: data, encoding: .utf8) else {
        throw KeychainStoreError.unexpectedData
      }
      try KeychainStore.writeString(
        encoded,
        service: Self.service,
        account: account,
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      )
    } else {
      try KeychainStore.delete(service: Self.service, account: account)
    }
  }

  private func key(_ productAccountId: String, _ recordScope: MailProfileRecordScope) -> String {
    "sending-identity-challenge.v1.\(productAccountId).\(recordScope.namespace ?? "default")"
  }

  private func removeLegacyChallenge(for key: String) {
    UserDefaults.standard.removeObject(forKey: key)
  }
}

/// Owns Profile-scoped identity presentation, offline state, and conditional synchronization.
@MainActor
@Observable
final class SendingIdentityStore {
  typealias VerificationSender = @MainActor (OutgoingMessage, MailboxConnection) async throws -> Void

  private struct SynchronizationInput {
    let connections: [MailboxConnection]
    let connectionsAreAuthoritative: Bool
    let legacyDefaultConnectionId: MailboxConnectionId?
    let providerConfirmedAddresses: [MailboxConnectionId: [String]]
    let providerDiscoveryErrorDescription: String?
  }

  private static let maximumSynchronizationAttempts = 5
  private(set) var errorMessage: String?
  private(set) var isSynchronizing = false
  private(set) var preferences: SendingIdentityPreferences
  private(set) var verificationAddress: String?

  private let challengeStore: SendingIdentityChallengePersisting
  private let codeGenerator: () -> String
  private var connections: [MailboxConnection] = []
  private var connectionsAreAuthoritative = false
  private var hasLoadedRemotePreferences = false
  private var legacyDefaultConnectionId: MailboxConnectionId?
  private let now: () -> Date
  private let recordScope: MailProfileRecordScope
  private var session: ProductAccountSessionSnapshot
  private var pendingSynchronization: SynchronizationInput?
  private var preferenceRevision = 0
  private var providerConfirmedAddresses: [MailboxConnectionId: [String]] = [:]
  private var providerDiscoveryErrorDescription: String?
  private let syncService: SendingIdentitySyncing

  /// Creates a store for one Mail Profile.
  init(
    session: ProductAccountSessionSnapshot,
    recordScope: MailProfileRecordScope = .legacyProductAccount,
    syncService: SendingIdentitySyncing? = nil,
    challengeStore: SendingIdentityChallengePersisting =
      KeychainIdentityChallengeStore(),
    codeGenerator: @escaping () -> String = {
      let digits = String(Int.random(in: 0...999_999))
      return String(repeating: "0", count: 6 - digits.count) + digits
    },
    now: @escaping () -> Date = { .now }
  ) {
    self.challengeStore = challengeStore
    self.codeGenerator = codeGenerator
    self.now = now
    self.recordScope = recordScope
    self.session = session
    self.syncService = syncService ?? SendingIdentitySyncService(recordScope: recordScope)
    preferences = .init()
    verificationAddress = try? challengeStore.load(
      productAccountId: session.productAccountId,
      recordScope: recordScope
    )?.address
  }

  /// Returns the selected identity when it belongs to an authorized sending connection.
  func availableIdentity(_ identityId: SendingIdentityId?) -> SendingIdentity? {
    guard let identityId,
      let identity = preferences.identities.first(where: { $0.id == identityId }),
      let connection = connections.first(where: { $0.id == identity.connectionId }),
      connection.authorizationState == .authorized,
      connection.capabilities.canSend
    else { return nil }
    return identity
  }

  /// Reconciles local presentation with current Profile connections and encrypted state.
  func synchronize(
    connections: [MailboxConnection],
    connectionsAreAuthoritative: Bool = true,
    legacyDefaultConnectionId: MailboxConnectionId?,
    providerConfirmedAddresses: [MailboxConnectionId: [String]] = [:],
    providerDiscoveryErrorDescription: String? = nil
  ) async {
    self.connections = connections
    self.connectionsAreAuthoritative = connectionsAreAuthoritative
    self.legacyDefaultConnectionId = legacyDefaultConnectionId
    self.providerConfirmedAddresses = providerConfirmedAddresses
    self.providerDiscoveryErrorDescription = providerDiscoveryErrorDescription
    let input = SynchronizationInput(
      connections: connections,
      connectionsAreAuthoritative: connectionsAreAuthoritative,
      legacyDefaultConnectionId: legacyDefaultConnectionId,
      providerConfirmedAddresses: providerConfirmedAddresses,
      providerDiscoveryErrorDescription: providerDiscoveryErrorDescription
    )
    guard !isSynchronizing else {
      pendingSynchronization = input
      return
    }
    isSynchronizing = true
    defer { isSynchronizing = false }
    var currentInput = input
    while true {
      pendingSynchronization = nil
      await performSynchronization(currentInput)
      guard let nextInput = pendingSynchronization else { return }
      currentInput = nextInput
    }
  }

  private func performSynchronization(_ input: SynchronizationInput) async {
    preferences.reconcile(
      connections: input.connections,
      connectionsAreAuthoritative: input.connectionsAreAuthoritative,
      providerConfirmedAddresses: input.providerConfirmedAddresses,
      legacyDefaultConnectionId: input.legacyDefaultConnectionId
    )
    let startingPreferenceRevision = preferenceRevision
    let preferRemoteDefault = !hasLoadedRemotePreferences
    do {
      var remote =
        try await syncService.load(session: session)
        ?? SendingIdentitySyncSnapshot(preferences: .init(), updatedAt: nil)
      for attempt in 1...Self.maximumSynchronizationAttempts {
        var candidate = merge(
          local: preferences,
          remote: remote.preferences,
          preferRemoteDefault: preferRemoteDefault
        )
        candidate.reconcile(
          connections: input.connections,
          connectionsAreAuthoritative: input.connectionsAreAuthoritative,
          providerConfirmedAddresses: input.providerConfirmedAddresses,
          legacyDefaultConnectionId: input.legacyDefaultConnectionId
        )
        switch try await syncService.save(
          candidate,
          expectedUpdatedAt: remote.updatedAt,
          session: session
        ) {
        case .committed(let snapshot):
          hasLoadedRemotePreferences = true
          if preferenceRevision == startingPreferenceRevision {
            preferences = snapshot.preferences
          }
          errorMessage = input.providerDiscoveryErrorDescription
          return
        case .conflict(let snapshot):
          remote = snapshot
        }
        guard attempt < Self.maximumSynchronizationAttempts else {
          throw SendingIdentityError.retryLimitExceeded
        }
      }
    } catch is CancellationError {
    } catch {
      var local = preferences
      local.reconcile(
        connections: input.connections,
        connectionsAreAuthoritative: input.connectionsAreAuthoritative,
        providerConfirmedAddresses: input.providerConfirmedAddresses,
        legacyDefaultConnectionId: input.legacyDefaultConnectionId
      )
      preferences = local
      errorMessage = error.localizedDescription
    }
  }

  /// Sets the Profile default and synchronizes it when possible.
  func setDefault(_ identityId: SendingIdentityId) async {
    do {
      try preferences.setDefault(identityId)
      preferenceRevision += 1
      await synchronize(
        connections: connections,
        connectionsAreAuthoritative: connectionsAreAuthoritative,
        legacyDefaultConnectionId: legacyDefaultConnectionId,
        providerConfirmedAddresses: providerConfirmedAddresses,
        providerDiscoveryErrorDescription: providerDiscoveryErrorDescription
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Sends a self-addressed provider test without exposing the alias or code to the backend.
  func beginManualVerification(
    address: String,
    connection: MailboxConnection,
    send: VerificationSender
  ) async -> Bool {
    let normalizedAddress = SendingIdentity.normalizedAddress(address)
    guard RFCMailboxHeaderParser.mailboxes(in: normalizedAddress)?.count == 1 else {
      errorMessage = SendingIdentityError.invalidAddress.localizedDescription
      return false
    }
    let code = codeGenerator()
    let challenge = SendingIdentityVerificationChallenge(
      address: normalizedAddress,
      code: code,
      connectionId: connection.id,
      expiresAtMilliseconds: Int64(now().addingTimeInterval(15 * 60).timeIntervalSince1970 * 1_000)
    )
    let message = OutgoingMessage(
      body: "Enter this one-time code in Unwired Mail: \(code)",
      recipient: normalizedAddress,
      subject: "Verify From address",
      fromAddress: normalizedAddress
    )
    do {
      try await send(message, connection)
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
    do {
      try challengeStore.save(
        challenge,
        productAccountId: session.productAccountId,
        recordScope: recordScope
      )
      verificationAddress = normalizedAddress
      errorMessage = nil
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  /// Makes a manual alias available after the locally stored code is entered.
  func completeManualVerification(code: String) async -> Bool {
    do {
      guard
        let challenge = try challengeStore.load(
          productAccountId: session.productAccountId,
          recordScope: recordScope
        )
      else { throw SendingIdentityError.verificationExpired }
      guard challenge.expiresAtMilliseconds >= Int64(now().timeIntervalSince1970 * 1_000) else {
        try challengeStore.save(
          nil,
          productAccountId: session.productAccountId,
          recordScope: recordScope
        )
        verificationAddress = nil
        throw SendingIdentityError.verificationExpired
      }
      guard challenge.code == code.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw SendingIdentityError.invalidVerificationCode
      }
      preferences.addManuallyVerified(
        SendingIdentity(
          address: challenge.address,
          connectionId: challenge.connectionId,
          verification: .manualProviderTest
        )
      )
      preferenceRevision += 1
      try challengeStore.save(
        nil,
        productAccountId: session.productAccountId,
        recordScope: recordScope
      )
      verificationAddress = nil
      await synchronize(
        connections: connections,
        connectionsAreAuthoritative: connectionsAreAuthoritative,
        legacyDefaultConnectionId: legacyDefaultConnectionId,
        providerConfirmedAddresses: providerConfirmedAddresses,
        providerDiscoveryErrorDescription: providerDiscoveryErrorDescription
      )
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func merge(
    local: SendingIdentityPreferences,
    remote: SendingIdentityPreferences,
    preferRemoteDefault: Bool
  ) -> SendingIdentityPreferences {
    var identitiesById = Dictionary(
      remote.identities.map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    for identity in local.identities {
      identitiesById[identity.id] = identity
    }
    let preferredDefault =
      if preferRemoteDefault {
        remote.defaultIdentityId ?? local.defaultIdentityId
      } else {
        local.defaultIdentityId ?? remote.defaultIdentityId
      }
    return SendingIdentityPreferences(
      identities: Array(identitiesById.values),
      defaultIdentityId: preferredDefault
    )
  }
}
