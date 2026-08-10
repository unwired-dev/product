import CryptoKit
import Foundation

// swiftlint:disable file_length type_body_length

enum GenericMailProtocol: String, CaseIterable, Codable, Identifiable, Sendable {
  case imap
  case pop3
  case smtp

  var id: String { rawValue }

  var displayName: String { rawValue.uppercased() }
}

enum MailTransportSecurity: String, CaseIterable, Codable, Identifiable, Sendable {
  case implicitTLS
  case startTLS

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .implicitTLS:
      return "Implicit TLS"
    case .startTLS:
      return "STARTTLS"
    }
  }
}

enum MailAuthorizationMethod: String, CaseIterable, Codable, Identifiable, Sendable {
  case oauth
  case appPassword
  case password

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .oauth:
      return "OAuth access token"
    case .appPassword:
      return "App-specific password"
    case .password:
      return "Password"
    }
  }
}

enum CanonicalMailboxRole: String, CaseIterable, Codable, Identifiable, Sendable {
  case archive
  case drafts
  case sent
  case spam
  case trash

  var id: String { rawValue }

  var displayName: String { rawValue.capitalized }
}

struct GenericMailEndpoint: Codable, Equatable, Identifiable, Sendable {
  let mailProtocol: GenericMailProtocol
  var hostname: String
  var port: Int
  var security: MailTransportSecurity

  var id: GenericMailProtocol { mailProtocol }
}

struct GenericMailDiscoveryResult: Equatable, Sendable {
  let incomingEndpoints: [GenericMailEndpoint]
  let outgoingEndpoint: GenericMailEndpoint
  let preferredAuthorizationMethod: MailAuthorizationMethod
  let sourceName: String
}

struct GenericMailSetupDraft: Equatable, Sendable {
  var authorizationMethod: MailAuthorizationMethod
  var emailAddress: String
  var incomingEndpoint: GenericMailEndpoint
  var outgoingEndpoint: GenericMailEndpoint
  var roleMappings: [CanonicalMailboxRole: String]
  var username: String
}

struct GenericMailConnectionDefinition: Codable, Equatable, Sendable {
  let authorizationMethod: MailAuthorizationMethod
  let emailAddress: String
  let incomingEndpoint: GenericMailEndpoint
  let outgoingEndpoint: GenericMailEndpoint
  let roleMappings: [CanonicalMailboxRole: String]
  let username: String

  var connectionId: MailboxConnectionId {
    let provider = MailProviderId(
      rawValue: incomingEndpoint.mailProtocol == .pop3 ? "pop3-smtp" : "imap-smtp"
    )
    let identityInput = [
      username,
      incomingEndpoint.mailProtocol.rawValue,
      incomingEndpoint.hostname.lowercased(),
      String(incomingEndpoint.port),
      incomingEndpoint.security.rawValue,
      outgoingEndpoint.mailProtocol.rawValue,
      outgoingEndpoint.hostname.lowercased(),
      String(outgoingEndpoint.port),
      outgoingEndpoint.security.rawValue,
    ].joined(separator: "\0")
    let stableIdentity = Data(SHA256.hash(data: Data(identityInput.utf8)))
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: provider,
        value: stableIdentity
      )
    )
  }
}

struct DeviceLocalGenericMailAuthorization: Codable, Equatable, Sendable {
  let authorizationGeneration: Int
  let credential: String
  let definition: GenericMailConnectionDefinition

  init(
    authorizationGeneration: Int = 0,
    credential: String,
    definition: GenericMailConnectionDefinition
  ) {
    self.authorizationGeneration = authorizationGeneration
    self.credential = credential
    self.definition = definition
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    authorizationGeneration =
      try container.decodeIfPresent(Int.self, forKey: .authorizationGeneration) ?? 0
    credential = try container.decode(String.self, forKey: .credential)
    definition = try container.decode(GenericMailConnectionDefinition.self, forKey: .definition)
  }

  private enum CodingKeys: String, CodingKey {
    case authorizationGeneration
    case credential
    case definition
  }
}

struct SyncedGenericMailConnectionDefinition: Equatable, Sendable {
  let authorizationGeneration: Int
  let definition: GenericMailConnectionDefinition
}

protocol GenericMailLocalStateClearing {
  func clear(
    connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws
}

struct GenericMailLocalStateCleaner: GenericMailLocalStateClearing {
  private let authorizationStore: GenericMailAuthorizationPersisting
  private let cache: GmailMessageBodyCaching
  private let metadataStore: IMAPMessageMetadataPersisting
  private let outboxService: OutboxDeliveryService
  private let pendingActionService: PendingProviderActionService

  init(
    authorizationStore: GenericMailAuthorizationPersisting =
      KeychainGenericMailAuthorizationStore(),
    cache: GmailMessageBodyCaching = FileGmailMessageBodyCache(),
    metadataStore: IMAPMessageMetadataPersisting = SwiftDataIMAPMessageMetadataStore(),
    outboxService: OutboxDeliveryService = .shared,
    pendingActionService: PendingProviderActionService = .shared
  ) {
    self.authorizationStore = authorizationStore
    self.cache = cache
    self.metadataStore = metadataStore
    self.outboxService = outboxService
    self.pendingActionService = pendingActionService
  }

  func clear(
    connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try metadataStore.clear(
      productAccountId: session.productAccountId,
      connectionId: connectionId
    )
    try cache.clearMessageBodies(
      productAccountId: session.productAccountId,
      connectionId: connectionId
    )
    let connection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: .none,
      connectedAt: 0,
      displayName: "",
      id: connectionId,
      lastVerifiedAt: 0,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 0
    )
    try await pendingActionService.clear(connection: connection, session: session)
    try await outboxService.clear(connection: connection, session: session)
    try authorizationStore.remove(
      productAccountId: ProductAccountId(session.productAccountId),
      connectionId: connectionId
    )
  }
}

enum MailTransportVersion: Int, Equatable, Sendable {
  case olderThanTLS12
  case tls12OrNewer
}

struct GenericMailEndpointVerification: Equatable, Sendable {
  let authenticated: Bool
  let discoveredRoleMappings: [CanonicalMailboxRole: String]
  let transportVersion: MailTransportVersion

  init(
    authenticated: Bool,
    discoveredRoleMappings: [CanonicalMailboxRole: String] = [:],
    transportVersion: MailTransportVersion
  ) {
    self.authenticated = authenticated
    self.discoveredRoleMappings = discoveredRoleMappings
    self.transportVersion = transportVersion
  }
}

struct GenericMailServerMailbox: Equatable, Sendable {
  let canonicalName: String
  let displayName: String
}

struct GenericMailConnectionVerification: Equatable, Sendable {
  let discoveredRoleMappings: [CanonicalMailboxRole: String]
  let mailboxes: [GenericMailServerMailbox]

  func canonicalMailboxName(matching value: String) -> String? {
    let matches = Set(
      mailboxes.compactMap { mailbox -> String? in
        if mailbox.canonicalName == value || mailbox.displayName == value {
          return mailbox.canonicalName
        }
        if mailbox.canonicalName.caseInsensitiveCompare("INBOX") == .orderedSame,
          value.caseInsensitiveCompare("INBOX") == .orderedSame
        {
          return mailbox.canonicalName
        }
        return nil
      }
    )
    return matches.count == 1 ? matches.first : nil
  }
}

enum GenericMailSetupError: LocalizedError, Equatable {
  case ambiguousSavedSetup
  case authenticationFailed(GenericMailProtocol)
  case invalidEmailAddress
  case invalidEndpoint(GenericMailProtocol)
  case invalidRoleMapping(CanonicalMailboxRole)
  case missingCredential
  case missingIncomingEndpoint
  case missingRoleMappings(
    discovered: [CanonicalMailboxRole: String],
    missing: [CanonicalMailboxRole]
  )
  case secureTransportRequired(GenericMailProtocol)

  var errorDescription: String? {
    switch self {
    case .ambiguousSavedSetup:
      return "Multiple saved setups use this address. Select the mailbox connection to load."
    case .authenticationFailed(let mailProtocol):
      return "\(mailProtocol.displayName) did not accept the mailbox authorization."
    case .invalidEmailAddress:
      return "Enter a valid mailbox email address."
    case .invalidEndpoint(let mailProtocol):
      return "Enter a valid \(mailProtocol.displayName) hostname and port."
    case .invalidRoleMapping(let role):
      return "Choose a \(role.displayName) mailbox returned by the IMAP server."
    case .missingCredential:
      return "Enter the credential required by the selected authorization method."
    case .missingIncomingEndpoint:
      return "Choose either IMAP or POP3 for incoming mail."
    case .missingRoleMappings(_, let missing):
      let names = missing.map(\.displayName).joined(separator: ", ")
      return "Choose the provider mailbox used for: \(names)."
    case .secureTransportRequired(let mailProtocol):
      return "\(mailProtocol.displayName) must negotiate TLS 1.2 or newer before authentication."
    }
  }
}

protocol GenericMailEndpointDiscovering {
  func discover(emailAddress: String) -> GenericMailDiscoveryResult?
}

protocol GenericMailEndpointVerifying {
  func verify(
    endpoint: GenericMailEndpoint,
    username: String,
    credential: String,
    authorizationMethod: MailAuthorizationMethod
  ) async throws -> GenericMailEndpointVerification
}

protocol GenericMailConnectionVerifying {
  func verify(
    definition: GenericMailConnectionDefinition,
    credential: String
  ) async throws -> GenericMailConnectionVerification
}

protocol GenericMailAuthorizationPersisting {
  func clearAll(productAccountId: ProductAccountId) throws
  func connectionIds(productAccountId: ProductAccountId) throws -> [MailboxConnectionId]
  func load(
    productAccountId: ProductAccountId,
    emailAddress: String
  ) throws -> DeviceLocalGenericMailAuthorization?
  func load(
    productAccountId: ProductAccountId,
    connectionId: MailboxConnectionId
  ) throws -> DeviceLocalGenericMailAuthorization?
  func remove(
    productAccountId: ProductAccountId,
    connectionId: MailboxConnectionId
  ) throws
  func save(
    _ authorization: DeviceLocalGenericMailAuthorization,
    productAccountId: ProductAccountId
  ) throws
}

extension GenericMailAuthorizationPersisting {
  func connectionIds(productAccountId _: ProductAccountId) throws -> [MailboxConnectionId] { [] }
}

private struct GenericMailAuthorizationLease: Sendable {
  let productAccountId: ProductAccountId
}

private actor GenericMailAuthorizationGate {
  private struct Entry {
    var cleanupGeneration: UInt64 = 0
    var isLocked = false
    var retainCount = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
    #if DEBUG || TESTING
      var contentionObservers: [UUID: CheckedContinuation<Bool, Never>] = [:]
    #endif

    var hasContentionObservers: Bool {
      #if DEBUG || TESTING
        !contentionObservers.isEmpty
      #else
        false
      #endif
    }
  }

  private var entries: [ProductAccountId: Entry] = [:]

  func retain(productAccountId: ProductAccountId) -> GenericMailAuthorizationLease {
    var entry = entries[productAccountId, default: Entry()]
    entry.retainCount += 1
    entries[productAccountId] = entry
    return GenericMailAuthorizationLease(productAccountId: productAccountId)
  }

  func release(_ lease: GenericMailAuthorizationLease) {
    guard var entry = entries[lease.productAccountId] else { return }
    entry.retainCount -= 1
    entries[lease.productAccountId] = entry
    removeEntryIfIdle(productAccountId: lease.productAccountId)
  }

  func acquire(_ lease: GenericMailAuthorizationLease) async -> UInt64 {
    var entry = entries[lease.productAccountId, default: Entry()]
    if !entry.isLocked {
      entry.isLocked = true
      entries[lease.productAccountId] = entry
      return entry.cleanupGeneration
    }

    await withCheckedContinuation { continuation in
      entry.waiters.append(continuation)
      #if DEBUG || TESTING
        let observers = entry.contentionObservers.values
        entry.contentionObservers.removeAll()
      #endif
      entries[lease.productAccountId] = entry
      #if DEBUG || TESTING
        for observer in observers {
          observer.resume(returning: true)
        }
      #endif
    }
    return entries[lease.productAccountId]?.cleanupGeneration ?? 0
  }

  func releaseLock(
    _ lease: GenericMailAuthorizationLease,
    advancesCleanupGeneration: Bool
  ) {
    guard var entry = entries[lease.productAccountId] else { return }
    if advancesCleanupGeneration {
      entry.cleanupGeneration &+= 1
    }
    if entry.waiters.isEmpty {
      entry.isLocked = false
      entries[lease.productAccountId] = entry
      removeEntryIfIdle(productAccountId: lease.productAccountId)
    } else {
      let waiter = entry.waiters.removeFirst()
      entries[lease.productAccountId] = entry
      waiter.resume()
    }
  }

  #if DEBUG || TESTING
    func waitUntilContended(productAccountId: ProductAccountId) async throws {
      let observerId = UUID()
      let didContend = await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          guard !Task.isCancelled else {
            continuation.resume(returning: false)
            return
          }
          if let entry = entries[productAccountId], !entry.waiters.isEmpty {
            continuation.resume(returning: true)
            return
          }
          var entry = entries[productAccountId, default: Entry()]
          entry.contentionObservers[observerId] = continuation
          entries[productAccountId] = entry
        }
      } onCancel: {
        Task {
          await self.cancelContentionObserver(
            observerId,
            productAccountId: productAccountId
          )
        }
      }
      guard didContend else { throw CancellationError() }
    }

    private func cancelContentionObserver(
      _ observerId: UUID,
      productAccountId: ProductAccountId
    ) {
      guard
        var entry = entries[productAccountId],
        let observer = entry.contentionObservers.removeValue(forKey: observerId)
      else { return }
      entries[productAccountId] = entry
      removeEntryIfIdle(productAccountId: productAccountId)
      observer.resume(returning: false)
    }
  #endif

  private func removeEntryIfIdle(productAccountId: ProductAccountId) {
    guard
      let entry = entries[productAccountId],
      entry.retainCount == 0,
      !entry.isLocked,
      entry.waiters.isEmpty,
      !entry.hasContentionObservers
    else { return }
    entries.removeValue(forKey: productAccountId)
  }
}

final class GenericMailAuthorizationCoordinator: Sendable {
  static let shared = GenericMailAuthorizationCoordinator()

  private let gate = GenericMailAuthorizationGate()

  fileprivate func retain(
    productAccountId: ProductAccountId
  ) async -> GenericMailAuthorizationLease {
    await gate.retain(productAccountId: productAccountId)
  }

  fileprivate func release(_ lease: GenericMailAuthorizationLease) async {
    await gate.release(lease)
  }

  fileprivate func withLock<Result>(
    lease: GenericMailAuthorizationLease,
    advancesCleanupGeneration: Bool = false,
    operation: (UInt64) throws -> Result
  ) async rethrows -> Result {
    let cleanupGeneration = await gate.acquire(lease)
    do {
      let result = try operation(cleanupGeneration)
      await gate.releaseLock(
        lease,
        advancesCleanupGeneration: advancesCleanupGeneration
      )
      return result
    } catch {
      await gate.releaseLock(lease, advancesCleanupGeneration: false)
      throw error
    }
  }

  func withLock<Result>(
    productAccountId: ProductAccountId,
    advancesCleanupGeneration: Bool = false,
    operation: (UInt64) throws -> Result
  ) async rethrows -> Result {
    let lease = await retain(productAccountId: productAccountId)
    do {
      let result = try await withLock(
        lease: lease,
        advancesCleanupGeneration: advancesCleanupGeneration,
        operation: operation
      )
      await release(lease)
      return result
    } catch {
      await release(lease)
      throw error
    }
  }

  #if DEBUG || TESTING
    func waitUntilContended(productAccountId: ProductAccountId) async throws {
      try await gate.waitUntilContended(productAccountId: productAccountId)
    }
  #endif
}

struct GenericMailSetupService {
  private let authorizationStore: GenericMailAuthorizationPersisting
  private let authorizationCoordinator: GenericMailAuthorizationCoordinator
  private let clock: () -> Int64
  private let definitionSyncService: MailboxConnectionDefinitionSyncing
  private let discovery: GenericMailEndpointDiscovering
  private let localStateCleaner: GenericMailLocalStateClearing
  private let syncGate: MailboxConnectionSyncGate
  private let connectionVerifier: (any GenericMailConnectionVerifying)?
  private let verifier: GenericMailEndpointVerifying

  init(
    authorizationStore: GenericMailAuthorizationPersisting =
      KeychainGenericMailAuthorizationStore(),
    authorizationCoordinator: GenericMailAuthorizationCoordinator = .shared,
    clock: @escaping () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    definitionSyncService: MailboxConnectionDefinitionSyncing =
      MailboxConnectionSyncService(),
    discovery: GenericMailEndpointDiscovering = BundledMailProviderCatalog(),
    localStateCleaner: GenericMailLocalStateClearing? = nil,
    syncGate: MailboxConnectionSyncGate = .shared,
    verifier: GenericMailEndpointVerifying? = nil,
    connectionVerifier: (any GenericMailConnectionVerifying)? = nil
  ) {
    self.authorizationStore = authorizationStore
    self.authorizationCoordinator = authorizationCoordinator
    self.clock = clock
    self.definitionSyncService = definitionSyncService
    self.discovery = discovery
    self.localStateCleaner =
      localStateCleaner ?? GenericMailLocalStateCleaner(authorizationStore: authorizationStore)
    self.syncGate = syncGate
    let endpointVerifier = verifier ?? SystemGenericMailEndpointVerifier()
    self.verifier = endpointVerifier
    self.connectionVerifier =
      connectionVerifier
      ?? (verifier == nil
        ? SwiftMailGenericMailConnectionVerifier()
        : nil)
  }

  func discover(emailAddress: String) -> GenericMailDiscoveryResult? {
    discovery.discover(emailAddress: emailAddress)
  }

  func loadAuthorization(
    emailAddress: String,
    productAccountId: ProductAccountId
  ) throws -> DeviceLocalGenericMailAuthorization? {
    try authorizationStore.load(
      productAccountId: productAccountId,
      emailAddress: emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    )
  }

  func clearLocalAuthorizations(productAccountId: ProductAccountId) async throws {
    try await authorizationCoordinator.withLock(
      productAccountId: productAccountId,
      advancesCleanupGeneration: true
    ) { _ in
      try authorizationStore.clearAll(productAccountId: productAccountId)
    }
  }

  func loadDefaultSendingConnectionId(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionId? {
    try await definitionSyncService.loadSnapshot(session: session).defaultSendingConnectionId
  }

  func removeLocalAuthorization(
    _ definition: GenericMailConnectionDefinition,
    productAccountId: ProductAccountId
  ) throws {
    try authorizationStore.remove(
      productAccountId: productAccountId,
      connectionId: definition.connectionId
    )
  }

  func removeEverywhere(
    _ definition: GenericMailConnectionDefinition,
    session: ProductAccountSessionSnapshot,
    shouldRemoveLocalAuthorization: Bool = true
  ) async throws {
    if shouldRemoveLocalAuthorization {
      try removeLocalAuthorization(
        definition,
        productAccountId: ProductAccountId(session.productAccountId)
      )
    }
    _ = try await definitionSyncService.removeConnection(
      definition.connectionId,
      session: session
    )
  }

  func setDefaultSendingConnection(
    _ definition: GenericMailConnectionDefinition,
    session: ProductAccountSessionSnapshot
  ) async throws {
    _ = try await definitionSyncService.setDefaultSendingConnection(
      definition.connectionId,
      session: session
    )
  }

  func authorize(
    draft: GenericMailSetupDraft,
    credential: String,
    productAccountId: ProductAccountId,
    saveIntent: MailboxConnectionDefinitionSaveIntent = .authorizeExisting,
    syncSession: ProductAccountSessionSnapshot? = nil,
    isSessionCurrent: () -> Bool = { true }
  ) async throws -> GenericMailConnectionDefinition {
    guard isSessionCurrent() else { throw CancellationError() }
    let definition = try validatedDefinition(draft)
    guard !credential.isEmpty else { throw GenericMailSetupError.missingCredential }

    let verification = try await verifyEndpoints(
      definition: definition,
      credential: credential,
      isSessionCurrent: isSessionCurrent
    )
    let verifiedDefinition = try applyingRoleMappings(
      verification,
      to: definition
    )

    try Task.checkCancellation()
    guard isSessionCurrent() else { throw CancellationError() }
    try await persistAuthorizationAndDefinition(
      verifiedDefinition,
      credential: credential,
      productAccountId: productAccountId,
      saveIntent: saveIntent,
      syncSession: syncSession,
      isSessionCurrent: isSessionCurrent
    )
    return verifiedDefinition
  }

  func connectionId(for draft: GenericMailSetupDraft) throws -> MailboxConnectionId {
    try validatedDefinition(draft).connectionId
  }

  private func verifyEndpoints(
    definition: GenericMailConnectionDefinition,
    credential: String,
    isSessionCurrent: () -> Bool
  ) async throws -> GenericMailConnectionVerification {
    if definition.incomingEndpoint.mailProtocol == .imap, let connectionVerifier {
      try Task.checkCancellation()
      guard isSessionCurrent() else { throw CancellationError() }
      return try await connectionVerifier.verify(
        definition: definition,
        credential: credential
      )
    }

    var discoveredRoleMappings: [CanonicalMailboxRole: String] = [:]
    for endpoint in [definition.incomingEndpoint, definition.outgoingEndpoint] {
      try Task.checkCancellation()
      guard isSessionCurrent() else { throw CancellationError() }
      let verification = try await verifier.verify(
        endpoint: endpoint,
        username: definition.username,
        credential: credential,
        authorizationMethod: definition.authorizationMethod
      )
      guard verification.transportVersion == .tls12OrNewer else {
        throw GenericMailSetupError.secureTransportRequired(endpoint.mailProtocol)
      }
      guard verification.authenticated else {
        throw GenericMailSetupError.authenticationFailed(endpoint.mailProtocol)
      }
      if endpoint.mailProtocol == .imap {
        discoveredRoleMappings = verification.discoveredRoleMappings
      }
    }
    return GenericMailConnectionVerification(
      discoveredRoleMappings: discoveredRoleMappings,
      mailboxes: []
    )
  }

  private func applyingRoleMappings(
    _ verification: GenericMailConnectionVerification,
    to definition: GenericMailConnectionDefinition
  ) throws -> GenericMailConnectionDefinition {
    guard definition.incomingEndpoint.mailProtocol == .imap else { return definition }
    var roleMappings = verification.discoveredRoleMappings
    for (role, mailbox) in definition.roleMappings {
      if verification.mailboxes.isEmpty {
        roleMappings[role] = mailbox
      } else if let canonicalName = verification.canonicalMailboxName(matching: mailbox) {
        roleMappings[role] = canonicalName
      } else {
        throw GenericMailSetupError.invalidRoleMapping(role)
      }
    }
    let missingRoles = CanonicalMailboxRole.allCases.filter { roleMappings[$0] == nil }
    guard missingRoles.isEmpty else {
      throw GenericMailSetupError.missingRoleMappings(
        discovered: verification.discoveredRoleMappings,
        missing: missingRoles
      )
    }
    return GenericMailConnectionDefinition(
      authorizationMethod: definition.authorizationMethod,
      emailAddress: definition.emailAddress,
      incomingEndpoint: definition.incomingEndpoint,
      outgoingEndpoint: definition.outgoingEndpoint,
      roleMappings: roleMappings,
      username: definition.username
    )
  }

  private func validatedDefinition(
    _ draft: GenericMailSetupDraft
  ) throws -> GenericMailConnectionDefinition {
    let emailAddress = draft.emailAddress
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard
      emailAddress.split(separator: "@", omittingEmptySubsequences: false).count == 2,
      !emailAddress.hasPrefix("@"),
      !emailAddress.hasSuffix("@")
    else { throw GenericMailSetupError.invalidEmailAddress }

    guard
      draft.incomingEndpoint.mailProtocol == .imap
        || draft.incomingEndpoint.mailProtocol == .pop3
    else { throw GenericMailSetupError.missingIncomingEndpoint }

    let incomingEndpoint = try validatedEndpoint(draft.incomingEndpoint)
    let outgoingEndpoint = try validatedEndpoint(draft.outgoingEndpoint)
    guard outgoingEndpoint.mailProtocol == .smtp else {
      throw GenericMailSetupError.invalidEndpoint(outgoingEndpoint.mailProtocol)
    }

    var roleMappings: [CanonicalMailboxRole: String] = [:]
    if incomingEndpoint.mailProtocol == .imap {
      for role in CanonicalMailboxRole.allCases {
        let mailbox = draft.roleMappings[role]?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if let mailbox, !mailbox.isEmpty { roleMappings[role] = mailbox }
      }
    }

    let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !username.isEmpty else { throw GenericMailSetupError.invalidEmailAddress }

    return GenericMailConnectionDefinition(
      authorizationMethod: draft.authorizationMethod,
      emailAddress: emailAddress,
      incomingEndpoint: incomingEndpoint,
      outgoingEndpoint: outgoingEndpoint,
      roleMappings: roleMappings,
      username: username
    )
  }

  private func validatedEndpoint(
    _ endpoint: GenericMailEndpoint
  ) throws -> GenericMailEndpoint {
    let hostname = endpoint.hostname
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !hostname.isEmpty, (1...65_535).contains(endpoint.port) else {
      throw GenericMailSetupError.invalidEndpoint(endpoint.mailProtocol)
    }
    return GenericMailEndpoint(
      mailProtocol: endpoint.mailProtocol,
      hostname: hostname,
      port: endpoint.port,
      security: endpoint.security
    )
  }
}

extension GenericMailSetupService {
  func hasLocalAuthorization(
    _ syncedDefinition: SyncedGenericMailConnectionDefinition,
    productAccountId: ProductAccountId
  ) throws -> Bool {
    guard
      let authorization = try authorizationStore.load(
        productAccountId: productAccountId,
        connectionId: syncedDefinition.definition.connectionId
      )
    else {
      return false
    }
    return authorization.authorizationGeneration == syncedDefinition.authorizationGeneration
  }

  func loadSyncedDefinitions(
    session: ProductAccountSessionSnapshot
  ) async throws -> [SyncedGenericMailConnectionDefinition] {
    let snapshot = try await definitionSyncService.loadSnapshot(session: session)
    for connectionId in snapshot.connectionIdsRequiringLocalCleanup
    where connectionId.providerId == .imapSMTP || connectionId.providerId == .pop3SMTP {
      try await syncGate.withLock(connectionId) {
        let currentSnapshot = try await definitionSyncService.loadSnapshot(session: session)
        let authorizationGeneration = try authorizationStore.load(
          productAccountId: ProductAccountId(session.productAccountId),
          connectionId: connectionId
        )?.authorizationGeneration
        guard
          try definitionSyncService.requiresLocalCleanup(
            in: currentSnapshot,
            connectionId: connectionId,
            localAuthorizationGeneration: authorizationGeneration,
            session: session
          )
        else {
          return
        }
        try await localStateCleaner.clear(
          connectionId: connectionId,
          session: session
        )
        try definitionSyncService.recordLocalCleanup(
          in: currentSnapshot,
          connectionId: connectionId,
          session: session
        )
      }
    }
    return snapshot.connections.compactMap { connection in
      guard let definition = connection.genericMailDefinition else { return nil }
      return SyncedGenericMailConnectionDefinition(
        authorizationGeneration: connection.authorizationGeneration,
        definition: definition
      )
    }
  }

  // swiftlint:disable:next function_body_length function_parameter_count
  fileprivate func persistAuthorizationAndDefinition(
    _ definition: GenericMailConnectionDefinition,
    credential: String,
    productAccountId: ProductAccountId,
    saveIntent: MailboxConnectionDefinitionSaveIntent,
    syncSession: ProductAccountSessionSnapshot?,
    isSessionCurrent: () -> Bool
  ) async throws {
    var previousAuthorization: DeviceLocalGenericMailAuthorization?
    let lease = await authorizationCoordinator.retain(productAccountId: productAccountId)
    do {
      let persistenceCleanupGeneration = try await authorizationCoordinator.withLock(
        lease: lease
      ) { cleanupGeneration in
        try Task.checkCancellation()
        guard isSessionCurrent() else { throw CancellationError() }
        previousAuthorization = try authorizationStore.load(
          productAccountId: productAccountId,
          connectionId: definition.connectionId
        )
        return cleanupGeneration
      }
      if let syncSession {
        let snapshot = try await saveSynchronizedDefinition(
          definition,
          authorizationGeneration: previousAuthorization?.authorizationGeneration ?? 0,
          intent: saveIntent,
          session: syncSession
        )
        let authorizationGeneration =
          snapshot.connections.first(where: { $0.id == definition.connectionId })?
          .authorizationGeneration
          ?? 0
        try await syncGate.withLock(definition.connectionId) {
          if try definitionSyncService.requiresLocalCleanup(
            in: snapshot,
            connectionId: definition.connectionId,
            localAuthorizationGeneration: previousAuthorization?.authorizationGeneration,
            session: syncSession
          ) {
            try await localStateCleaner.clear(
              connectionId: definition.connectionId,
              session: syncSession
            )
            try definitionSyncService.recordLocalCleanup(
              in: snapshot,
              connectionId: definition.connectionId,
              session: syncSession
            )
          }
          let currentSnapshot = try await definitionSyncService.loadSnapshot(
            session: syncSession
          )
          guard
            !currentSnapshot.removedConnectionIds.contains(definition.connectionId),
            let currentDefinition = currentSnapshot.connections.first(where: {
              $0.id == definition.connectionId
            })
          else {
            throw MailboxConnectionAdapterError.connectionRemoved
          }
          if try definitionSyncService.requiresLocalCleanup(
            in: currentSnapshot,
            connectionId: definition.connectionId,
            localAuthorizationGeneration: authorizationGeneration,
            session: syncSession
          ) {
            try await localStateCleaner.clear(
              connectionId: definition.connectionId,
              session: syncSession
            )
            try definitionSyncService.recordLocalCleanup(
              in: currentSnapshot,
              connectionId: definition.connectionId,
              session: syncSession
            )
          }
          try await authorizationCoordinator.withLock(lease: lease) { cleanupGeneration in
            guard cleanupGeneration == persistenceCleanupGeneration else {
              throw CancellationError()
            }
            try authorizationStore.save(
              DeviceLocalGenericMailAuthorization(
                authorizationGeneration: currentDefinition.authorizationGeneration,
                credential: credential,
                definition: definition
              ),
              productAccountId: productAccountId
            )
          }
        }
      } else {
        try await authorizationCoordinator.withLock(lease: lease) { cleanupGeneration in
          guard cleanupGeneration == persistenceCleanupGeneration else {
            throw CancellationError()
          }
          try authorizationStore.save(
            DeviceLocalGenericMailAuthorization(
              authorizationGeneration: previousAuthorization?.authorizationGeneration ?? 0,
              credential: credential,
              definition: definition
            ),
            productAccountId: productAccountId
          )
        }
      }
      await authorizationCoordinator.release(lease)
    } catch {
      await authorizationCoordinator.release(lease)
      throw error
    }
  }

  private func saveSynchronizedDefinition(
    _ definition: GenericMailConnectionDefinition,
    authorizationGeneration: Int,
    intent: MailboxConnectionDefinitionSaveIntent,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    let synchronizedDefinition = definition.synchronizedDefinition(
      authorizationGeneration: authorizationGeneration,
      connectedAt: clock()
    )
    switch intent {
    case .add(let removalObservation):
      return try await definitionSyncService.recreateDefinition(
        synchronizedDefinition,
        after: removalObservation,
        session: session
      )
    case .authorizeExisting:
      return try await definitionSyncService.saveDefinition(
        synchronizedDefinition,
        session: session
      )
    }
  }
}

struct ProductAccountMailboxConnectionClearer: MailboxConnectionClearing {
  private let backgroundContextCacheStore: BackgroundContextCachePersisting
  private let genericMailSetupService: GenericMailSetupService
  private let gmailConnection: MailboxConnectionClearing

  init(
    backgroundContextCacheStore: BackgroundContextCachePersisting =
      KeychainBackgroundContextCacheStore(),
    genericMailSetupService: GenericMailSetupService = GenericMailSetupService(),
    gmailConnection: MailboxConnectionClearing = MailboxConnectionRouter()
  ) {
    self.backgroundContextCacheStore = backgroundContextCacheStore
    self.genericMailSetupService = genericMailSetupService
    self.gmailConnection = gmailConnection
  }

  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws {
    var firstError: Error?
    do {
      try await gmailConnection.clearLocalConnection(session: session)
    } catch {
      firstError = error
    }
    do {
      try await genericMailSetupService.clearLocalAuthorizations(
        productAccountId: ProductAccountId(session.productAccountId)
      )
    } catch {
      if firstError == nil { firstError = error }
    }
    do {
      try backgroundContextCacheStore.clear(productAccountId: session.productAccountId)
    } catch {
      if firstError == nil { firstError = error }
    }
    if let firstError { throw firstError }
  }

  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await gmailConnection.clearLocalConnection(connection, session: session)
  }
}
