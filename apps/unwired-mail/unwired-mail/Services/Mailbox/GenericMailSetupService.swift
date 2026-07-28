import CryptoKit
import Foundation

// swiftlint:disable file_length

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
  let credential: String
  let definition: GenericMailConnectionDefinition
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

enum GenericMailSetupError: LocalizedError, Equatable {
  case ambiguousSavedSetup
  case authenticationFailed(GenericMailProtocol)
  case invalidEmailAddress
  case invalidEndpoint(GenericMailProtocol)
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

protocol GenericMailAuthorizationPersisting {
  func clearAll(productAccountId: ProductAccountId) throws
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

private struct GenericMailAuthorizationLease: Sendable {
  let productAccountId: ProductAccountId
}

private actor GenericMailAuthorizationGate {
  private struct Entry {
    var cleanupGeneration: UInt64 = 0
    var contentionObservers: [CheckedContinuation<Void, Never>] = []
    var isLocked = false
    var retainCount = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
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
      let observers = entry.contentionObservers
      entry.contentionObservers.removeAll()
      entries[lease.productAccountId] = entry
      for observer in observers {
        observer.resume()
      }
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

  func waitUntilContended(productAccountId: ProductAccountId) async {
    if let entry = entries[productAccountId], !entry.waiters.isEmpty { return }
    await withCheckedContinuation { continuation in
      var entry = entries[productAccountId, default: Entry()]
      entry.contentionObservers.append(continuation)
      entries[productAccountId] = entry
    }
  }

  private func removeEntryIfIdle(productAccountId: ProductAccountId) {
    guard
      let entry = entries[productAccountId],
      entry.retainCount == 0,
      !entry.isLocked,
      entry.waiters.isEmpty,
      entry.contentionObservers.isEmpty
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

  func waitUntilContended(productAccountId: ProductAccountId) async {
    await gate.waitUntilContended(productAccountId: productAccountId)
  }
}

struct GenericMailSetupService {
  private let authorizationStore: GenericMailAuthorizationPersisting
  private let authorizationCoordinator: GenericMailAuthorizationCoordinator
  private let clock: () -> Int64
  private let definitionSyncService: MailboxConnectionDefinitionSyncing
  private let discovery: GenericMailEndpointDiscovering
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
    verifier: GenericMailEndpointVerifying = SystemGenericMailEndpointVerifier()
  ) {
    self.authorizationStore = authorizationStore
    self.authorizationCoordinator = authorizationCoordinator
    self.clock = clock
    self.definitionSyncService = definitionSyncService
    self.discovery = discovery
    self.verifier = verifier
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

  func hasLocalAuthorization(
    _ definition: GenericMailConnectionDefinition,
    productAccountId: ProductAccountId
  ) throws -> Bool {
    try authorizationStore.load(
      productAccountId: productAccountId,
      connectionId: definition.connectionId
    ) != nil
  }

  func loadSyncedDefinitions(
    session: ProductAccountSessionSnapshot
  ) async throws -> [GenericMailConnectionDefinition] {
    let snapshot = try await definitionSyncService.loadSnapshot(session: session)
    for connectionId in snapshot.removedConnectionIds
    where connectionId.providerId.rawValue == "imap-smtp"
      || connectionId.providerId.rawValue == "pop3-smtp"
    {
      try authorizationStore.remove(
        productAccountId: ProductAccountId(session.productAccountId),
        connectionId: connectionId
      )
    }
    return snapshot.connections.compactMap(\.genericMailDefinition)
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
    syncSession: ProductAccountSessionSnapshot? = nil,
    isSessionCurrent: () -> Bool = { true }
  ) async throws -> GenericMailConnectionDefinition {
    guard isSessionCurrent() else { throw CancellationError() }
    let definition = try validatedDefinition(draft)
    guard !credential.isEmpty else { throw GenericMailSetupError.missingCredential }

    let discoveredRoleMappings = try await verifyEndpoints(
      definition: definition,
      credential: credential,
      isSessionCurrent: isSessionCurrent
    )
    let verifiedDefinition = try applyingRoleMappings(
      discoveredRoleMappings,
      to: definition
    )

    try Task.checkCancellation()
    guard isSessionCurrent() else { throw CancellationError() }
    try await persistAuthorizationAndDefinition(
      verifiedDefinition,
      credential: credential,
      productAccountId: productAccountId,
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
  ) async throws -> [CanonicalMailboxRole: String] {
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
    return discoveredRoleMappings
  }

  private func applyingRoleMappings(
    _ discovered: [CanonicalMailboxRole: String],
    to definition: GenericMailConnectionDefinition
  ) throws -> GenericMailConnectionDefinition {
    guard definition.incomingEndpoint.mailProtocol == .imap else { return definition }
    var roleMappings = discovered
    for (role, mailbox) in definition.roleMappings { roleMappings[role] = mailbox }
    let missingRoles = CanonicalMailboxRole.allCases.filter { roleMappings[$0] == nil }
    guard missingRoles.isEmpty else {
      throw GenericMailSetupError.missingRoleMappings(
        discovered: discovered,
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
  fileprivate func persistAuthorizationAndDefinition(
    _ definition: GenericMailConnectionDefinition,
    credential: String,
    productAccountId: ProductAccountId,
    syncSession: ProductAccountSessionSnapshot?,
    isSessionCurrent: () -> Bool
  ) async throws {
    var previousAuthorization: DeviceLocalGenericMailAuthorization?
    var persistenceCleanupGeneration: UInt64?
    let lease = await authorizationCoordinator.retain(productAccountId: productAccountId)
    do {
      try await authorizationCoordinator.withLock(lease: lease) { cleanupGeneration in
        try Task.checkCancellation()
        guard isSessionCurrent() else { throw CancellationError() }
        previousAuthorization = try authorizationStore.load(
          productAccountId: productAccountId,
          connectionId: definition.connectionId
        )
        try authorizationStore.save(
          DeviceLocalGenericMailAuthorization(credential: credential, definition: definition),
          productAccountId: productAccountId
        )
        persistenceCleanupGeneration = cleanupGeneration
      }
      if let syncSession {
        do {
          _ = try await definitionSyncService.saveDefinition(
            definition.synchronizedDefinition(connectedAt: clock()),
            session: syncSession
          )
        } catch {
          await authorizationCoordinator.withLock(lease: lease) { cleanupGeneration in
            guard cleanupGeneration == persistenceCleanupGeneration else { return }
            if let previousAuthorization {
              try? authorizationStore.save(
                previousAuthorization,
                productAccountId: productAccountId
              )
            } else {
              try? authorizationStore.remove(
                productAccountId: productAccountId,
                connectionId: definition.connectionId
              )
            }
          }
          throw error
        }
      }
      await authorizationCoordinator.release(lease)
    } catch {
      await authorizationCoordinator.release(lease)
      throw error
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
