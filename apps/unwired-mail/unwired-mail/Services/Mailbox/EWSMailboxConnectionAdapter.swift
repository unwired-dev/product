import CryptoKit
import Foundation
import Security
import SwiftData

// swiftlint:disable file_length function_parameter_count type_body_length

extension MailProviderId {
  static let exchangeWebServices = MailProviderId(rawValue: "exchange-web-services")
}

enum EWSSetupError: LocalizedError, Equatable {
  case authenticationFailed
  case invalidMailboxIdentity
  case missingRequiredMailboxRole
  case onPremisesEndpointRequired
  case unsupportedServerVersion

  var errorDescription: String? {
    switch self {
    case .authenticationFailed:
      return "Exchange Web Services did not accept this mailbox authorization."
    case .invalidMailboxIdentity:
      return "Exchange Web Services did not return a stable mailbox identity."
    case .missingRequiredMailboxRole:
      return "Exchange did not expose every mailbox required for full mail support."
    case .onPremisesEndpointRequired:
      return
        "Enter an HTTPS Exchange Web Services endpoint hosted by your organization. "
        + "Exchange Online and Microsoft 365 must use Microsoft Graph."
    case .unsupportedServerVersion:
      return "This Exchange server is not a supported on-premises EWS version."
    }
  }
}

struct EWSAmbiguousProviderActionError: LocalizedError {
  var errorDescription: String? {
    "Exchange may have applied this action. Reconcile the mailbox before retrying."
  }
}

enum EWSServerVersion: String, Codable, CaseIterable, Equatable, Sendable {
  case exchange2013SP1
  case exchange2016
  case exchange2019

  var requestVersion: String {
    switch self {
    case .exchange2013SP1, .exchange2016, .exchange2019:
      return "Exchange2013_SP1"
    }
  }
}

struct EWSAccount: Equatable, Sendable {
  let displayName: String
  let primaryEmailAddress: String
  let serverVersion: EWSServerVersion
}

/// Synchronizable, credential-free configuration for one on-premises EWS mailbox.
///
/// Example:
/// ```swift
/// let connectionId = definition.connectionId
/// ```
struct EWSConnectionDefinition: Codable, Equatable, Sendable {
  let authorizationMethod: MailAuthorizationMethod
  let emailAddress: String
  let endpoint: URL
  let providerAccountIdentifier: String
  let serverVersion: EWSServerVersion
  let username: String

  var connectionId: MailboxConnectionId {
    return MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .exchangeWebServices,
        value: providerAccountIdentifier
      )
    )
  }

  static func validatedEndpoint(_ value: String) throws -> URL {
    guard
      let endpoint = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
      endpoint.scheme?.lowercased() == "https",
      let host = endpoint.host?.lowercased(),
      !host.isEmpty,
      endpoint.user == nil,
      endpoint.password == nil,
      endpoint.query == nil,
      endpoint.fragment == nil,
      !exchangeOnlineHosts.contains(host),
      !exchangeOnlineHostSuffixes.contains(where: host.hasSuffix)
    else {
      throw EWSSetupError.onPremisesEndpointRequired
    }
    return endpoint
  }

  static func stableProviderAccountIdentifier(
    endpoint: URL,
    primaryEmailAddress: String
  ) throws -> String {
    guard
      let host = endpoint.host?.lowercased(),
      !host.isEmpty,
      !primaryEmailAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw EWSSetupError.invalidMailboxIdentity
    }
    let identityInput = [
      host,
      String(effectivePort(endpoint) ?? 443),
      endpoint.path,
      primaryEmailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
    ].joined(separator: "\0")
    return Data(SHA256.hash(data: Data(identityInput.utf8)))
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func hasSameOrigin(_ candidate: URL, as endpoint: URL) -> Bool {
    candidate.scheme?.lowercased() == endpoint.scheme?.lowercased()
      && candidate.host?.lowercased() == endpoint.host?.lowercased()
      && effectivePort(candidate) == effectivePort(endpoint)
  }

  private static func effectivePort(_ url: URL) -> Int? {
    url.port ?? (url.scheme?.lowercased() == "https" ? 443 : nil)
  }

  private static let exchangeOnlineHosts: Set<String> = [
    "outlook.office.de",
    "outlook.office.com",
    "outlook.office365.com",
    "outlook.office365.us",
    "partner.outlook.cn",
    "webmail.apps.mil",
  ]

  private static let exchangeOnlineHostSuffixes = [
    ".microsoftonline.com",
    ".office.com",
    ".office.de",
    ".office365.com",
    ".office365.us",
    ".outlook.com",
    ".outlook.cn",
    ".apps.mil",
  ]
}

/// Combines an opaque device-held credential with its credential-free EWS definition.
///
/// This value belongs only in Keychain-backed device storage and must never enter Product Sync.
///
/// Example:
/// ```swift
/// try store.save(authorization, productAccountId: accountId)
/// ```
struct DeviceLocalEWSAuthorization: Codable, Equatable, Sendable {
  let credential: String
  let definition: EWSConnectionDefinition
}

/// Performs device-local EWS operations without sending credentials or mailbox data to Product Sync.
///
/// Example:
/// ```swift
/// let account = try await client.verify(authorization)
/// ```
protocol EWSClient: Sendable {
  /// Verifies authorization and returns the stable mailbox identity and supported server version.
  func verify(_ authorization: DeviceLocalEWSAuthorization) async throws -> EWSAccount
  /// Loads provider folders and maps recognized Exchange distinguished roles.
  func loadFolders(
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSFolder]
  /// Loads one resumable metadata page without fetching message bodies.
  func loadMessagePage(
    folder: EWSFolder,
    offset: Int,
    pageSize: Int,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> EWSMessagePage
  /// Fetches one message body from the on-premises provider.
  func loadMessageBody(
    itemId: String,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> String
  /// Reloads current item ids and change keys immediately before a mutation.
  func refreshMessageIdentities(
    _ messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSProviderMessage]
  /// Applies one provider mutation for an already persisted pending action.
  func perform(
    _ action: ProviderMailAction,
    targetFolderId: String?,
    messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSMovedItemIdentity]
  /// Sends one Outbox message through the on-premises provider.
  func send(
    _ message: OutgoingMessage,
    authorization: DeviceLocalEWSAuthorization
  ) async throws
  /// Reconciles an Outbox idempotency key against Sent Items.
  func deliveryStatus(
    rfcMessageId: String,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> MailboxDeliveryStatus
}

extension EWSClient {
  func loadFolders(
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> [EWSFolder] {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func loadMessagePage(
    folder _: EWSFolder,
    offset _: Int,
    pageSize _: Int,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> EWSMessagePage {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func loadMessageBody(
    itemId _: String,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> String {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func refreshMessageIdentities(
    _ messages: [EWSProviderMessage],
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> [EWSProviderMessage] {
    messages
  }

  func perform(
    _ action: ProviderMailAction,
    targetFolderId _: String?,
    messages _: [EWSProviderMessage],
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> [EWSMovedItemIdentity] {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func send(
    _ message: OutgoingMessage,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func deliveryStatus(
    rfcMessageId _: String,
    authorization _: DeviceLocalEWSAuthorization
  ) async throws -> MailboxDeliveryStatus {
    .unknown
  }
}

/// Persists EWS authorization only in this device's protected credential store.
///
/// Example:
/// ```swift
/// try store.save(authorization, productAccountId: session.productAccountId)
/// ```
protocol EWSAuthorizationPersisting {
  /// Clears one device-local authorization.
  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws
  /// Clears all EWS authorizations for one Product Account on this device.
  func clearAll(productAccountId: String) throws
  /// Loads one authorization from device-local protected storage.
  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> DeviceLocalEWSAuthorization?
  /// Saves one authorization without synchronizing the credential.
  func save(
    _ authorization: DeviceLocalEWSAuthorization,
    productAccountId: String
  ) throws
}

struct KeychainEWSAuthorizationStore: EWSAuthorizationPersisting {
  private let service = "dev.unwired.mail.exchange-web-services-authorization"

  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    try KeychainStore.delete(service: service, account: account(productAccountId, connectionId))
    var ids = try connectionIds(productAccountId: productAccountId)
    ids.remove(connectionId.rawValue)
    try saveConnectionIds(ids, productAccountId: productAccountId)
  }

  func clearAll(productAccountId: String) throws {
    for rawValue in try connectionIds(productAccountId: productAccountId) {
      try KeychainStore.delete(service: service, account: "\(productAccountId)-\(rawValue)")
    }
    try KeychainStore.delete(service: service, account: manifestAccount(productAccountId))
  }

  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> DeviceLocalEWSAuthorization? {
    guard
      let json = try KeychainStore.readString(
        service: service,
        account: account(productAccountId, connectionId)
      ),
      let data = json.data(using: .utf8)
    else { return nil }
    return try JSONDecoder().decode(DeviceLocalEWSAuthorization.self, from: data)
  }

  func save(
    _ authorization: DeviceLocalEWSAuthorization,
    productAccountId: String
  ) throws {
    let data = try JSONEncoder().encode(authorization)
    guard let json = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    let previousIds = try connectionIds(productAccountId: productAccountId)
    var ids = previousIds
    ids.insert(authorization.definition.connectionId.rawValue)
    try saveConnectionIds(ids, productAccountId: productAccountId)
    do {
      try KeychainStore.writeString(
        json,
        service: service,
        account: account(productAccountId, authorization.definition.connectionId),
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      )
    } catch {
      try? saveConnectionIds(previousIds, productAccountId: productAccountId)
      throw error
    }
  }

  private func connectionIds(productAccountId: String) throws -> Set<String> {
    guard
      let json = try KeychainStore.readString(
        service: service,
        account: manifestAccount(productAccountId)
      ),
      let data = json.data(using: .utf8)
    else { return [] }
    return Set(try JSONDecoder().decode([String].self, from: data))
  }

  private func saveConnectionIds(
    _ ids: Set<String>,
    productAccountId: String
  ) throws {
    guard !ids.isEmpty else {
      try KeychainStore.delete(service: service, account: manifestAccount(productAccountId))
      return
    }
    let data = try JSONEncoder().encode(ids.sorted())
    guard let json = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(
      json,
      service: service,
      account: manifestAccount(productAccountId),
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }

  private func account(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId
  ) -> String {
    "\(productAccountId)-\(connectionId.rawValue)"
  }

  private func manifestAccount(_ productAccountId: String) -> String {
    "connections-\(productAccountId)"
  }
}

#if DEBUG || TESTING
  final class InMemoryEWSAuthorizationStore: EWSAuthorizationPersisting {
    private var values: [String: DeviceLocalEWSAuthorization] = [:]

    func clear(
      productAccountId: String,
      connectionId: MailboxConnectionId
    ) throws {
      values[key(productAccountId, connectionId)] = nil
    }

    func clearAll(productAccountId: String) throws {
      let prefix = "\(productAccountId)\0"
      values = values.filter { !$0.key.hasPrefix(prefix) }
    }

    func load(
      productAccountId: String,
      connectionId: MailboxConnectionId
    ) throws -> DeviceLocalEWSAuthorization? {
      values[key(productAccountId, connectionId)]
    }

    func save(
      _ authorization: DeviceLocalEWSAuthorization,
      productAccountId: String
    ) throws {
      values[key(productAccountId, authorization.definition.connectionId)] = authorization
    }

    private func key(
      _ productAccountId: String,
      _ connectionId: MailboxConnectionId
    ) -> String {
      "\(productAccountId)\0\(connectionId.rawValue)"
    }
  }
#endif

extension MailboxConnectionCapabilities {
  static let exchangeWebServices = MailboxConnectionCapabilities(
    canCategorizeHistorical: false,
    canForward: true,
    canReadMessages: true,
    canRegisterPush: false,
    canReply: true,
    canSearchProvider: false,
    canSend: true,
    canSynchronizeMetadata: true,
    providerActions: Set(ProviderMailAction.allCases)
  )
}

/// Connects a verified full-capability on-premises EWS mailbox without syncing its credential.
///
/// Example:
/// ```swift
/// let connection = try await service.connect(
///   authorizationMethod: .password,
///   credential: password,
///   emailAddress: email,
///   endpoint: endpoint,
///   username: username,
///   session: session,
///   isSessionCurrent: { $0 == session }
/// )
/// ```
struct EWSSetupService {
  private let authorizationStore: EWSAuthorizationPersisting
  private let client: EWSClient
  private let definitionSyncService: MailboxConnectionDefinitionSyncing
  private let now: () -> Date

  init(
    authorizationStore: EWSAuthorizationPersisting = KeychainEWSAuthorizationStore(),
    client: EWSClient = SystemEWSClient(),
    definitionSyncService: MailboxConnectionDefinitionSyncing =
      MailboxConnectionSyncService(),
    now: @escaping () -> Date = Date.init
  ) {
    self.authorizationStore = authorizationStore
    self.client = client
    self.definitionSyncService = definitionSyncService
    self.now = now
  }

  // swiftlint:disable function_body_length
  /// Verifies the server, mailbox identity, version, and required roles before persisting setup.
  func connect(
    authorizationMethod: MailAuthorizationMethod,
    credential: String,
    emailAddress: String,
    endpoint endpointValue: String,
    username: String,
    session: ProductAccountSessionSnapshot,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection {
    guard isSessionCurrent(session) else { throw CancellationError() }
    let endpoint = try EWSConnectionDefinition.validatedEndpoint(endpointValue)
    let emailAddress = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !emailAddress.isEmpty, !username.isEmpty else {
      throw EWSSetupError.invalidMailboxIdentity
    }
    guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw EWSSetupError.authenticationFailed
    }

    let provisionalIdentifier = try EWSConnectionDefinition.stableProviderAccountIdentifier(
      endpoint: endpoint,
      primaryEmailAddress: emailAddress
    )
    let provisionalDefinition = EWSConnectionDefinition(
      authorizationMethod: authorizationMethod,
      emailAddress: emailAddress,
      endpoint: endpoint,
      providerAccountIdentifier: provisionalIdentifier,
      serverVersion: .exchange2013SP1,
      username: username
    )
    let account = try await client.verify(
      DeviceLocalEWSAuthorization(
        credential: credential,
        definition: provisionalDefinition
      )
    )
    guard isSessionCurrent(session) else { throw CancellationError() }

    let providerAccountIdentifier =
      try EWSConnectionDefinition.stableProviderAccountIdentifier(
        endpoint: endpoint,
        primaryEmailAddress: account.primaryEmailAddress
      )
    let definition = EWSConnectionDefinition(
      authorizationMethod: authorizationMethod,
      emailAddress: account.primaryEmailAddress,
      endpoint: endpoint,
      providerAccountIdentifier: providerAccountIdentifier,
      serverVersion: account.serverVersion,
      username: username
    )
    let authorization = DeviceLocalEWSAuthorization(
      credential: credential,
      definition: definition
    )
    let requiredRoles = Set(EWSFolderRole.allCases)
    let resolvedRoles = Set(
      try await client.loadFolders(authorization: authorization).compactMap(\.role)
    )
    guard requiredRoles.isSubset(of: resolvedRoles) else {
      throw EWSSetupError.missingRequiredMailboxRole
    }
    guard isSessionCurrent(session) else { throw CancellationError() }
    try Task.checkCancellation()

    let previous = try authorizationStore.load(
      productAccountId: session.productAccountId,
      connectionId: definition.connectionId
    )
    try authorizationStore.save(authorization, productAccountId: session.productAccountId)
    do {
      _ = try await definitionSyncService.saveDefinition(
        definition.synchronizedDefinition(
          connectedAt: Int64(now().timeIntervalSince1970 * 1_000),
          displayName: account.primaryEmailAddress
        ),
        session: session
      )
    } catch {
      if let previous {
        try? authorizationStore.save(previous, productAccountId: session.productAccountId)
      } else {
        try? authorizationStore.clear(
          productAccountId: session.productAccountId,
          connectionId: definition.connectionId
        )
      }
      throw error
    }

    let timestamp = Int64(now().timeIntervalSince1970 * 1_000)
    return MailboxConnection(
      authorizationState: .authorized,
      capabilities: .exchangeWebServices,
      connectedAt: timestamp,
      displayName: account.primaryEmailAddress,
      id: definition.connectionId,
      lastVerifiedAt: timestamp,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: timestamp
    )
  }
  // swiftlint:enable function_body_length
}

enum EWSFolderRole: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
  case archive
  case drafts
  case inbox
  case sent
  case spam
  case trash

  var mailboxRole: MailboxRole {
    switch self {
    case .archive: return .archive
    case .drafts: return .drafts
    case .inbox: return .inbox
    case .sent: return .sent
    case .spam: return .spam
    case .trash: return .trash
    }
  }
}

struct EWSFolder: Codable, Equatable, Hashable, Sendable {
  let changeKey: String?
  let displayName: String
  let id: String
  let isSearchFolder: Bool?
  let role: EWSFolderRole?

  init(
    changeKey: String?,
    displayName: String,
    id: String,
    isSearchFolder: Bool? = nil,
    role: EWSFolderRole?
  ) {
    self.changeKey = changeKey
    self.displayName = displayName
    self.id = id
    self.isSearchFolder = isSearchFolder
    self.role = role
  }
}

struct EWSProviderMessage: Codable, Equatable, Sendable {
  var bccRecipients: [String]
  var categoryId: String?
  let ccRecipients: [String]
  var changeKey: String
  let conversationId: String?
  let from: String?
  let internetMessageId: String?
  let isDraft: Bool
  var isFlagged: Bool
  var isRead: Bool
  var itemId: String
  var parentFolderId: String
  let receivedAtMilliseconds: Int64
  let replyTo: [String]
  var stableProviderId: String
  let subject: String
  let summary: String
  let toRecipients: [String]

  init(
    bccRecipients: [String],
    categoryId: String? = nil,
    ccRecipients: [String],
    changeKey: String,
    conversationId: String?,
    from: String?,
    internetMessageId: String?,
    isDraft: Bool,
    isFlagged: Bool = false,
    isRead: Bool,
    itemId: String,
    parentFolderId: String,
    receivedAtMilliseconds: Int64,
    replyTo: [String],
    stableProviderId: String,
    subject: String,
    summary: String,
    toRecipients: [String]
  ) {
    self.bccRecipients = bccRecipients
    self.categoryId = categoryId
    self.ccRecipients = ccRecipients
    self.changeKey = changeKey
    self.conversationId = conversationId
    self.from = from
    self.internetMessageId = internetMessageId
    self.isDraft = isDraft
    self.isFlagged = isFlagged
    self.isRead = isRead
    self.itemId = itemId
    self.parentFolderId = parentFolderId
    self.receivedAtMilliseconds = receivedAtMilliseconds
    self.replyTo = replyTo
    self.stableProviderId = stableProviderId
    self.subject = subject
    self.summary = summary
    self.toRecipients = toRecipients
  }

  func mailboxMetadata(
    connection: MailboxConnection,
    foldersById: [String: EWSFolder]
  ) -> MailboxMessageMetadata {
    let folder = foldersById[parentFolderId]
    var states: [String] = []
    if !isRead { states.append("UNREAD") }
    if isFlagged { states.append("STARRED") }
    if isDraft { states.append("DRAFT") }
    if let role = folder?.role {
      states.append(Self.providerStateId(role.mailboxRole))
    } else {
      states.append(Self.customFolderStateId(parentFolderId))
    }
    return MailboxMessageMetadata(
      categoryId: categoryId,
      connectionId: connection.id,
      from: from,
      isHistorical: receivedAtMilliseconds < connection.connectedAt,
      providerInternalDateMilliseconds: receivedAtMilliseconds,
      providerMessageId: stableProviderId,
      providerStateIds: states.sorted(),
      providerThreadId: Self.nonEmpty(conversationId)
        ?? Self.nonEmpty(internetMessageId)
        ?? "message:\(connection.id.rawValue):\(stableProviderId)",
      recipientHeaders: toRecipients + ccRecipients,
      replyTo: replyTo.first,
      rfcMessageId: internetMessageId,
      snippet: summary,
      subject: Self.nonEmpty(subject) ?? "(No subject)",
      bccRecipients: bccRecipients
    )
  }

  private static func providerStateId(_ role: MailboxRole) -> String {
    switch role {
    case .inbox: return "INBOX"
    case .drafts: return "DRAFT"
    case .sent: return "SENT"
    case .archive: return "ARCHIVE"
    case .spam: return "SPAM"
    case .trash: return "TRASH"
    }
  }

  static func customFolderStateId(_ id: String) -> String {
    let encoded = Data(id.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "ews-folder:\(encoded)"
  }

  static func folderId(fromProviderStateId stateId: String) -> String? {
    let prefix = "ews-folder:"
    guard stateId.hasPrefix(prefix) else { return nil }
    var value = String(stateId.dropFirst(prefix.count))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    guard let data = Data(base64Encoded: value) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }
}

struct EWSMessagePage: Equatable, Sendable {
  let messages: [EWSProviderMessage]
  let nextOffset: Int?
}

struct EWSMovedItemIdentity: Equatable, Sendable {
  let changeKey: String
  let itemId: String
  let stableProviderId: String
}

/// Captures connection-scoped EWS metadata and resumable full-scan reconciliation state.
///
/// Example:
/// ```swift
/// let complete = snapshot.historicalMetadataBackfillIsComplete
/// ```
struct EWSMetadataSnapshot: Codable, Equatable, Sendable {
  var folders: [EWSFolder]
  var messages: [EWSProviderMessage]
  var nextOffsetsByFolderId: [String: Int]
  var reconciliationMessageIdsByFolderId: [String: Set<String>] = [:]
  var hasInitialMailboxAvailability: Bool

  var historicalMetadataBackfillIsComplete: Bool {
    hasInitialMailboxAvailability && nextOffsetsByFolderId.isEmpty
  }
}

/// Persists device-local EWS metadata while excluding message bodies and credentials.
///
/// Example:
/// ```swift
/// try store.save(snapshot, productAccountId: accountId, connectionId: connectionId)
/// ```
protocol EWSMetadataPersisting {
  /// Clears all body-free EWS metadata for one Product Account.
  func clear(productAccountId: String) throws
  /// Clears body-free EWS metadata for one connection.
  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws
  /// Loads a connection's resumable metadata snapshot.
  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> EWSMetadataSnapshot?
  /// Saves a connection's resumable metadata snapshot.
  func save(
    _ snapshot: EWSMetadataSnapshot,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws
}

/// SwiftData record for one connection's encoded, body-free EWS metadata snapshot.
///
/// Example:
/// ```swift
/// let record = DurableEWSMetadataSnapshotRecord(
///   connectionIdRawValue: connectionId.rawValue,
///   encodedSnapshot: data,
///   productAccountId: accountId,
///   storageKey: key
/// )
/// ```
@Model
final class DurableEWSMetadataSnapshotRecord {
  var connectionIdRawValue: String
  var encodedSnapshot: Data
  var productAccountId: String
  @Attribute(.unique) var storageKey: String

  init(
    connectionIdRawValue: String,
    encodedSnapshot: Data,
    productAccountId: String,
    storageKey: String
  ) {
    self.connectionIdRawValue = connectionIdRawValue
    self.encodedSnapshot = encodedSnapshot
    self.productAccountId = productAccountId
    self.storageKey = storageKey
  }

  func snapshot() throws -> EWSMetadataSnapshot {
    try JSONDecoder().decode(EWSMetadataSnapshot.self, from: encodedSnapshot)
  }
}

/// Stores body-free EWS metadata in a connection-scoped SwiftData container.
///
/// Example:
/// ```swift
/// try store.save(snapshot, productAccountId: accountId, connectionId: connectionId)
/// ```
struct SwiftDataEWSMetadataStore: EWSMetadataPersisting {
  private let containerResult: Result<ModelContainer, Error>

  init(container: ModelContainer? = nil) {
    containerResult = Result {
      if let container { return container }
      let schema = Schema([DurableEWSMetadataSnapshotRecord.self])
      let configuration = ModelConfiguration("EWSMetadata", schema: schema)
      return try ModelContainer(for: schema, configurations: [configuration])
    }
  }

  /// Deletes every EWS snapshot for a Product Account from the local database.
  func clear(productAccountId: String) throws {
    let context = try makeContext()
    let records = try context.fetch(
      FetchDescriptor<DurableEWSMetadataSnapshotRecord>(
        predicate: #Predicate { $0.productAccountId == productAccountId }
      )
    )
    for record in records { context.delete(record) }
    try context.save()
  }

  /// Deletes one connection's EWS snapshot from the local database.
  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    let context = try makeContext()
    if let record = try record(productAccountId, connectionId, context: context) {
      context.delete(record)
      try context.save()
    }
  }

  /// Loads one connection's body-free snapshot from the local database.
  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> EWSMetadataSnapshot? {
    try record(productAccountId, connectionId, context: makeContext())?.snapshot()
  }

  /// Atomically inserts or updates one connection's body-free snapshot.
  func save(
    _ snapshot: EWSMetadataSnapshot,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    let context = try makeContext()
    let encodedSnapshot = try JSONEncoder().encode(snapshot)
    if let existing = try record(productAccountId, connectionId, context: context) {
      existing.encodedSnapshot = encodedSnapshot
    } else {
      context.insert(
        DurableEWSMetadataSnapshotRecord(
          connectionIdRawValue: connectionId.rawValue,
          encodedSnapshot: encodedSnapshot,
          productAccountId: productAccountId,
          storageKey: Self.storageKey(productAccountId, connectionId)
        )
      )
    }
    try context.save()
  }

  private func makeContext() throws -> ModelContext {
    try ModelContext(containerResult.get())
  }

  private func record(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws -> DurableEWSMetadataSnapshotRecord? {
    let connectionIdRawValue = connectionId.rawValue
    var descriptor = FetchDescriptor<DurableEWSMetadataSnapshotRecord>(
      predicate: #Predicate {
        $0.productAccountId == productAccountId
          && $0.connectionIdRawValue == connectionIdRawValue
      }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  private static func storageKey(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId
  ) -> String {
    "\(productAccountId)\0\(connectionId.rawValue)"
  }
}

#if DEBUG || TESTING
  final class InMemoryEWSMetadataStore: EWSMetadataPersisting {
    private let lock = NSLock()
    private var snapshots: [String: EWSMetadataSnapshot] = [:]

    func clear(productAccountId: String) throws {
      let prefix = "\(productAccountId)\0"
      lock.withLock {
        snapshots = snapshots.filter { !$0.key.hasPrefix(prefix) }
      }
    }

    func clear(
      productAccountId: String,
      connectionId: MailboxConnectionId
    ) throws {
      lock.withLock {
        snapshots[key(productAccountId, connectionId)] = nil
      }
    }

    func load(
      productAccountId: String,
      connectionId: MailboxConnectionId
    ) throws -> EWSMetadataSnapshot? {
      lock.withLock {
        snapshots[key(productAccountId, connectionId)]
      }
    }

    func save(
      _ snapshot: EWSMetadataSnapshot,
      productAccountId: String,
      connectionId: MailboxConnectionId
    ) throws {
      lock.withLock {
        snapshots[key(productAccountId, connectionId)] = snapshot
      }
    }

    private func key(
      _ productAccountId: String,
      _ connectionId: MailboxConnectionId
    ) -> String {
      "\(productAccountId)\0\(connectionId.rawValue)"
    }
  }
#endif

struct EWSMessageBodyService {
  private let cache: GmailMessageBodyCaching
  private let client: EWSClient
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting

  init(
    cache: GmailMessageBodyCaching,
    client: EWSClient,
    keyMaterialStore: ProductSyncKeyMaterialPersisting
  ) {
    self.cache = cache
    self.client = client
    self.keyMaterialStore = keyMaterialStore
  }

  func clear(session: ProductAccountSessionSnapshot) throws {
    try cache.clearMessageBodies(productAccountId: session.productAccountId)
  }

  func clear(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    try cache.clearMessageBodies(
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
  }

  func load(
    message: MailboxMessageMetadata,
    providerMessage: EWSProviderMessage,
    authorization: DeviceLocalEWSAuthorization,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    if let cached = try loadCached(
      message: message,
      providerMessage: providerMessage,
      session: session
    ) {
      try? cache.recordMessageBodyAccess(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId,
        accessedAt: Date()
      )
      return cached
    }
    let text = try await client.loadMessageBody(
      itemId: providerMessage.itemId,
      authorization: authorization
    )
    if let material = try? keyMaterialStore.load(productAccountId: session.productAccountId) {
      try? cache.saveMessageBody(
        material.encryptPayload(
          Data(text.utf8),
          associatedData: associatedData(
            message.stableProviderMessageId,
            changeKey: providerMessage.changeKey
          )
        ),
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
    }
    return MailboxMessageBody(text: text)
  }

  func prefetch(
    messages: [(MailboxMessageMetadata, EWSProviderMessage)],
    connection: MailboxConnection,
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
    authorization: DeviceLocalEWSAuthorization,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let protectedIds = Set(messages.map { $0.0.stableProviderMessageId })
    try cache.reconcileSelection(
      productAccountId: session.productAccountId,
      connectionId: connection.id,
      protectedMessageIds: protectedIds,
      pinnedMessageIds: Set(pinnedMessageIds.map(\.rawValue))
    )
    guard let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw ProductSyncKeyMaterialStoreError.recoveryRequired
    }
    for (message, providerMessage) in messages
    where
      try loadCached(
        message: message,
        providerMessage: providerMessage,
        session: session
      ) == nil
    {
      try Task.checkCancellation()
      let text = try await client.loadMessageBody(
        itemId: providerMessage.itemId,
        authorization: authorization
      )
      _ = try cache.saveMessageBody(
        GmailMessageBodyCacheWrite(
          cachedAt: Date(
            timeIntervalSince1970: TimeInterval(message.providerInternalDateMilliseconds) / 1_000
          ),
          isPinned: pinnedMessageIds.contains(message.id),
          isProtected: true,
          payload: material.encryptPayload(
            Data(text.utf8),
            associatedData: associatedData(
              message.stableProviderMessageId,
              changeKey: providerMessage.changeKey
            )
          ),
          retention: .prefetched
        ),
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
    }
  }

  func remove(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws {
    try cache.removeMessageBody(
      productAccountId: session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId
    )
  }

  private func loadCached(
    message: MailboxMessageMetadata,
    providerMessage: EWSProviderMessage,
    session: ProductAccountSessionSnapshot
  ) throws -> MailboxMessageBody? {
    guard
      let payload = try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      ),
      let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else { return nil }
    do {
      let data = try material.decryptPayload(
        payload,
        associatedData: associatedData(
          message.stableProviderMessageId,
          changeKey: providerMessage.changeKey
        )
      )
      guard let text = String(data: data, encoding: .utf8) else { return nil }
      return MailboxMessageBody(text: text)
    } catch {
      try? cache.removeMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
      return nil
    }
  }

  private func associatedData(
    _ stableProviderMessageId: String,
    changeKey: String
  ) -> Data {
    Data("exchange-web-services-body-cache:\(stableProviderMessageId):\(changeKey)".utf8)
  }
}

private typealias EWSBodyCandidate = (MailboxMessageMetadata, EWSProviderMessage)

// swiftlint:disable:next type_body_length
struct EWSMailboxConnectionAdapter: MailboxConnectionAdapter {
  static let initialPageSize = 50

  private let authorizationStore: EWSAuthorizationPersisting
  private let bodyService: EWSMessageBodyService
  private let client: EWSClient
  private let definitionSyncService: MailboxConnectionDefinitionSyncing
  private let metadataStore: EWSMetadataPersisting
  private let outboxService: OutboxDeliveryService
  private let pendingActionService: PendingProviderActionService
  private let syncGate: MailboxConnectionSyncGate

  init(
    authorizationStore: EWSAuthorizationPersisting = KeychainEWSAuthorizationStore(),
    cache: GmailMessageBodyCaching = FileGmailMessageBodyCache(),
    client: EWSClient = SystemEWSClient(),
    definitionSyncService: MailboxConnectionDefinitionSyncing =
      MailboxConnectionSyncService(),
    metadataStore: EWSMetadataPersisting = SwiftDataEWSMetadataStore(),
    outboxService: OutboxDeliveryService = .shared,
    pendingActionService: PendingProviderActionService = .shared,
    syncGate: MailboxConnectionSyncGate = .shared,
    keyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore()
  ) {
    self.authorizationStore = authorizationStore
    bodyService = EWSMessageBodyService(
      cache: cache,
      client: client,
      keyMaterialStore: keyMaterialStore
    )
    self.client = client
    self.definitionSyncService = definitionSyncService
    self.metadataStore = metadataStore
    self.outboxService = outboxService
    self.pendingActionService = pendingActionService
    self.syncGate = syncGate
  }

  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws {
    try authorizationStore.clearAll(productAccountId: session.productAccountId)
    try metadataStore.clear(productAccountId: session.productAccountId)
    try await pendingActionService.clear(session: session)
    try await outboxService.clear(session: session)
    try bodyService.clear(session: session)
  }

  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try validate(connection, session: session, requiresAuthorization: false)
    try await syncGate.withLock(connection.id) {
      try await clearLocalConnectionWithoutLock(connection, session: session)
    }
  }

  private func clearLocalConnectionWithoutLock(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await clearLocalConnectionWithoutLock(connection.id, session: session)
  }

  private func clearLocalConnectionWithoutLock(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try authorizationStore.clear(
      productAccountId: session.productAccountId,
      connectionId: connectionId
    )
    try metadataStore.clear(
      productAccountId: session.productAccountId,
      connectionId: connectionId
    )
    let connection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: .exchangeWebServices,
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
    try bodyService.clear(connection: connection, session: session)
  }

  @MainActor
  func connect(
    expectedConnectionId _: MailboxConnectionId?,
    session _: ProductAccountSessionSnapshot,
    isSessionCurrent _: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection? {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    for connectionId in snapshot.removedConnectionIds
    where connectionId.providerId == .exchangeWebServices {
      try await syncGate.withLock(connectionId) {
        try await clearLocalConnectionWithoutLock(connectionId, session: session)
      }
    }
    return snapshot.connections.compactMap { definition in
      guard
        definition.provider == MailProviderId.exchangeWebServices.rawValue,
        let ewsDefinition = definition.ewsDefinition
      else { return nil }
      let authorized =
        (try? authorizationStore.load(
          productAccountId: session.productAccountId,
          connectionId: definition.id
        ))?.definition == ewsDefinition
      return MailboxConnection(
        authorizationState: authorized ? .authorized : .required,
        capabilities: authorized ? .exchangeWebServices : .none,
        connectedAt: definition.connectedAt,
        displayName: definition.displayName,
        id: definition.id,
        lastVerifiedAt: authorized ? definition.connectedAt : 0,
        productAccountId: ProductAccountId(session.productAccountId),
        trustedDeviceId: session.trustedDeviceId,
        updatedAt: snapshot.updatedAt ?? definition.connectedAt
      )
    }
  }

  func loadDefaultSendingConnectionId(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionId? {
    try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
      .defaultSendingConnectionId
  }

  func removeMailboxConnectionEverywhere(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await clearLocalConnection(connection, session: session)
    _ = try await definitionSyncService.removeConnection(connection.id, session: session)
  }

  func setDefaultSendingConnection(
    _ connection: MailboxConnection?,
    session: ProductAccountSessionSnapshot
  ) async throws {
    if let connection {
      try validate(connection, session: session, requiresAuthorization: false)
    }
    _ = try await definitionSyncService.setDefaultSendingConnection(
      connection?.id,
      session: session
    )
  }

  func categorizeHistorical(
    scope _: HistoricalCategorizationScope,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await continueHistoricalBackfill(connection: connection, session: session)
  }

  func loadInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await loadResult(.role(.inbox), connection: connection, session: session)
  }

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await loadResult(collection, connection: connection, session: session)
  }

  func loadProviderMailboxes(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [ProviderMailbox] {
    try validate(connection, session: session, requiresAuthorization: true)
    return try metadataStore.load(
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )?.folders.compactMap {
      guard $0.role == nil, $0.isSearchFolder != true else { return nil }
      return ProviderMailbox(
        id: EWSProviderMessage.customFolderStateId($0.id),
        title: $0.displayName
      )
    } ?? []
  }

  func continueHistoricalBackfill(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await syncGate.withLock(connection.id) {
      try await continueHistoricalBackfillWithoutLock(connection: connection, session: session)
    }
  }

  // swiftlint:disable:next function_body_length
  private func continueHistoricalBackfillWithoutLock(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let authorization = try await authorizationForProviderAccess(
      connection,
      session: session,
      isWithinSyncGate: true
    )
    guard
      var snapshot = try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    else {
      return try await syncInbox(
        connection: connection,
        session: session,
        shouldPersist: { true }
      )
    }
    while let folder = snapshot.folders.first(where: {
      snapshot.nextOffsetsByFolderId[$0.id] != nil
    }) {
      var offset = snapshot.nextOffsetsByFolderId[folder.id] ?? 0
      while true {
        try Task.checkCancellation()
        let page = try await client.loadMessagePage(
          folder: folder,
          offset: offset,
          pageSize: Self.initialPageSize,
          authorization: authorization
        )
        let observedIds = upsert(page.messages, into: &snapshot.messages)
        snapshot.reconciliationMessageIdsByFolderId[folder.id, default: []]
          .formUnion(observedIds)
        if let nextOffset = page.nextOffset {
          offset = nextOffset
          snapshot.nextOffsetsByFolderId[folder.id] = nextOffset
        } else {
          snapshot.nextOffsetsByFolderId[folder.id] = nil
          finishReconciliation(for: folder.id, snapshot: &snapshot, deleteUnobserved: false)
        }
        try metadataStore.save(
          snapshot,
          productAccountId: session.productAccountId,
          connectionId: connection.id
        )
        if page.nextOffset == nil { break }
      }
    }
    return try await projectedResult(
      snapshot,
      .role(.inbox),
      connection: connection,
      session: session
    )
  }

  func syncInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await syncGate.withLock(connection.id) {
      try await syncInbox(
        connection: connection,
        session: session,
        shouldPersist: { true }
      )
    }
  }

  // swiftlint:disable:next function_body_length
  private func syncInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    shouldPersist: () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    let authorization = try await authorizationForProviderAccess(
      connection,
      session: session,
      isWithinSyncGate: true
    )
    if try metadataStore.load(
      productAccountId: session.productAccountId,
      connectionId: connection.id
    ) != nil {
      let snapshot = try await refreshRecentSnapshot(
        connection,
        authorization: authorization,
        session: session,
        shouldPersist: shouldPersist
      )
      let rawResult = try result(snapshot, .allObserved, connection: connection)
      try await pendingActionService.reconcileProviderSync(
        messages: rawResult.messages,
        connection: connection,
        session: session
      )
      return try await projectedResult(
        snapshot,
        .role(.inbox),
        connection: connection,
        session: session
      )
    }
    let folders = try await client.loadFolders(authorization: authorization)
    var snapshot = EWSMetadataSnapshot(
      folders: folders,
      messages: [],
      nextOffsetsByFolderId: [:],
      hasInitialMailboxAvailability: false
    )
    for folder in folders {
      let page = try await client.loadMessagePage(
        folder: folder,
        offset: 0,
        pageSize: Self.initialPageSize,
        authorization: authorization
      )
      let observedIds = upsert(page.messages, into: &snapshot.messages)
      snapshot.reconciliationMessageIdsByFolderId[folder.id] =
        observedIds
      if let nextOffset = page.nextOffset {
        snapshot.nextOffsetsByFolderId[folder.id] = nextOffset
      } else {
        finishReconciliation(for: folder.id, snapshot: &snapshot)
      }
    }
    snapshot.hasInitialMailboxAvailability = true
    guard shouldPersist() else { throw CancellationError() }
    try metadataStore.save(
      snapshot,
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
    return try await projectedResult(
      snapshot,
      .role(.inbox),
      connection: connection,
      session: session
    )
  }

  func syncRecentInbox(
    connection: MailboxConnection,
    includingHistoryCandidates _: Bool,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId _: String?,
    throughHistoryId _: String?,
    shouldPersist: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    try await syncGate.withLock(connection.id) {
      guard shouldPersist() else { throw CancellationError() }
      let authorization = try await authorizationForProviderAccess(
        connection,
        session: session,
        isWithinSyncGate: true
      )
      guard
        try metadataStore.load(
          productAccountId: session.productAccountId,
          connectionId: connection.id
        ) != nil
      else {
        return try await syncInbox(
          connection: connection,
          session: session,
          shouldPersist: shouldPersist
        )
      }
      let snapshot = try await refreshRecentSnapshot(
        connection,
        authorization: authorization,
        session: session,
        shouldPersist: shouldPersist
      )
      let rawResult = try result(snapshot, .allObserved, connection: connection)
      try await pendingActionService.reconcileProviderSync(
        messages: rawResult.messages,
        connection: connection,
        session: session
      )
      return try await projectedResult(
        snapshot,
        .role(.inbox),
        connection: connection,
        session: session
      )
    }
  }

  func overrideCategory(
    _ categoryId: String,
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    let connection = try await requiredConnection(message.connectionId, session: session)
    return try await syncGate.withLock(connection.id) {
      guard
        var snapshot = try metadataStore.load(
          productAccountId: session.productAccountId,
          connectionId: connection.id
        ),
        let index = snapshot.messages.firstIndex(where: {
          $0.stableProviderId == message.providerMessageId
        })
      else { throw MailboxConnectionAdapterError.connectionRemoved }
      snapshot.messages[index].categoryId = categoryId
      try metadataStore.save(
        snapshot,
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
      return snapshot.messages[index].mailboxMetadata(
        connection: connection,
        foldersById: Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
      )
    }
  }

  func searchProvider(
    query: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata] {
    let result = try await loadResult(.allObserved, connection: connection, session: session)
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    return result.messages.filter {
      [$0.subject, $0.snippet, $0.from ?? ""].contains {
        $0.localizedCaseInsensitiveContains(query)
      }
    }
  }

  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws {
    try bodyService.clear(session: session)
  }

  func clearCachedMessageBodies(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    try validate(connection, session: session, requiresAuthorization: false)
    try bodyService.clear(connection: connection, session: session)
  }

  func loadMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    let connection = try await requiredConnection(message.connectionId, session: session)
    let authorization = try await authorizationForProviderAccess(connection, session: session)
    let providerMessage = try storedMessage(message, session: session)
    return try await bodyService.load(
      message: message,
      providerMessage: providerMessage,
      authorization: authorization,
      session: session
    )
  }

  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
    referenceDate: Date,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let authorization = try await authorizationForProviderAccess(connection, session: session)
    let snapshot = try requiredSnapshot(connection, session: session)
    let folders = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
    let lowerBound =
      Int64(referenceDate.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970)
      * 1_000
    let upperBound = Int64(referenceDate.timeIntervalSince1970 * 1_000)
    let storedMessages = snapshot.messages
    let candidates = storedMessages.compactMap { providerMessage -> EWSBodyCandidate? in
      let message = providerMessage.mailboxMetadata(connection: connection, foldersById: folders)
      let states = Set(message.providerStateIds ?? [])
      guard states.isDisjoint(with: ["DRAFT", "SPAM", "TRASH"]) else { return nil }
      let isPinned = pinnedMessageIds.contains(message.id)
      let isRecent =
        (lowerBound...upperBound).contains(message.providerInternalDateMilliseconds)
        && !states.isDisjoint(with: ["INBOX", "SENT"])
      return isPinned || isRecent ? (message, providerMessage) : nil
    }.sorted {
      $0.0.providerInternalDateMilliseconds > $1.0.providerInternalDateMilliseconds
    }
    let recentIds = Set(
      candidates.filter { !pinnedMessageIds.contains($0.0.id) }.prefix(500).map { $0.0.id }
    )
    let selected = candidates.filter {
      pinnedMessageIds.contains($0.0.id) || recentIds.contains($0.0.id)
    }
    try await bodyService.prefetch(
      messages: selected,
      connection: connection,
      pinnedMessageIds: pinnedMessageIds,
      authorization: authorization,
      session: session
    )
  }

  func removeCachedMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws {
    guard message.connectionId.providerId == .exchangeWebServices else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    try bodyService.remove(message: message, session: session)
  }

  func registerOrRenewPush(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func perform(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await perform(
      action,
      targetProviderMailboxId: nil,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    _ = try await authorizationForProviderAccess(connection, session: session)
    if action == .move, targetProviderMailboxId == nil {
      throw MailboxConnectionAdapterError.providerMailboxTargetRequired
    }
    try await pendingActionService.enqueue(
      action,
      targetProviderMailboxId: targetProviderMailboxId,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    let results = await withTaskGroup(of: (Int, String?).self) { group in
      for (index, connection) in connections.enumerated() {
        group.addTask {
          (index, await resumePendingActions(connection: connection, session: session))
        }
      }
      var values: [(Int, String?)] = []
      for await value in group { values.append(value) }
      return values.sorted { $0.0 < $1.0 }
    }
    let errors = results.compactMap(\.1)
    return errors.isEmpty ? nil : errors.joined(separator: "\n")
  }

  func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    do {
      try await pendingActionService.resume(
        connection: connection,
        session: session,
        provider: pendingActionPerformer(connection: connection, session: session)
      )
      return try await pendingActionService.failureDescription(
        connection: connection,
        session: session
      )
    } catch is CancellationError {
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resolveBlockedAction(connection: connection, session: session, discard: false)
  }

  func discardBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resolveBlockedAction(connection: connection, session: session, discard: true)
  }

  func blockedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    var ids: [MailboxConnectionId] = []
    for connection in connections
    where
      (try? await pendingActionService.hasBlockedAction(
        connection: connection,
        session: session
      )) == true
    {
      ids.append(connection.id)
    }
    return ids
  }

  func failedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    var ids: [MailboxConnectionId] = []
    for connection in connections
    where
      (try? await pendingActionService.hasFailedAction(
        connection: connection,
        session: session
      )) == true
    {
      ids.append(connection.id)
    }
    return ids
  }

  func pendingActionFailureDetails(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxProviderActionFailureDetail]? {
    try? await pendingActionService.failureDetails(
      action,
      messageIds: Set(messages.map(\.providerMessageId)),
      connection: connection,
      session: session
    )
  }

  func waitForPendingActionRetries(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    for connection in connections {
      await pendingActionService.waitForScheduledRetries(
        connection: connection,
        session: session
      )
    }
    return await resumePendingActions(connections: connections, session: session)
  }

  func waitForPendingActionRetries(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await pendingActionService.waitForScheduledRetries(
      connection: connection,
      session: session
    )
    return await resumePendingActions(connection: connection, session: session)
  }

  func acknowledgePendingActionFailures(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async {
    try? await pendingActionService.acknowledgeFailures(
      connection: connection,
      session: session
    )
  }

  func send(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let authorization = try await authorizationForProviderAccess(connection, session: session)
    try await client.send(
      message,
      authorization: authorization
    )
  }

  func deliveryStatus(
    idempotencyKey: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxDeliveryStatus {
    let authorization = try await authorizationForProviderAccess(connection, session: session)
    return try await client.deliveryStatus(
      rfcMessageId: OutgoingMessage.rfcMessageId(for: idempotencyKey),
      authorization: authorization
    )
  }

  // swiftlint:disable:next function_body_length
  private func pendingActionPerformer(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) -> PendingProviderActionPerformer {
    { action, targetFolderId, messageIds in
      try await syncGate.withLock(connection.id) {
        let authorization = try await authorizationForProviderAccess(
          connection,
          session: session,
          isWithinSyncGate: true
        )
        let refreshedSnapshot = try await refreshRecentSnapshot(
          connection,
          authorization: authorization,
          session: session
        )
        if actionIsConfirmed(
          action,
          targetFolderId: targetFolderId,
          messageIds: messageIds,
          snapshot: refreshedSnapshot,
          connection: connection
        ) {
          return
        }
        let snapshot = try requiredSnapshot(connection, session: session)
        let messages = snapshot.messages.filter { messageIds.contains($0.stableProviderId) }
        guard messages.count == messageIds.count else {
          throw MailboxConnectionAdapterError.connectionRemoved
        }
        let currentMessages = try await client.refreshMessageIdentities(
          messages,
          authorization: authorization
        )
        let movedItems: [EWSMovedItemIdentity]
        do {
          movedItems = try await client.perform(
            action,
            targetFolderId: targetFolderId.flatMap {
              EWSProviderMessage.folderId(fromProviderStateId: $0)
            } ?? targetFolderId,
            messages: currentMessages,
            authorization: authorization
          )
        } catch let error as URLError {
          if error.code == .cancelled || Task.isCancelled {
            throw CancellationError()
          }
          if Self.isDefinitePreDeliveryNetworkFailure(error) {
            throw error
          }
          throw EWSAmbiguousProviderActionError()
        } catch EWSServiceError.invalidResponse {
          throw EWSAmbiguousProviderActionError()
        }
        try applyConfirmedAction(
          action,
          targetFolderId: targetFolderId,
          messageIds: messageIds,
          movedItems: movedItems,
          connection: connection,
          session: session
        )
        _ = try await refreshRecentSnapshot(
          connection,
          authorization: authorization,
          session: session
        )
      }
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  private func actionIsConfirmed(
    _ action: ProviderMailAction,
    targetFolderId: String?,
    messageIds: [String],
    snapshot: EWSMetadataSnapshot,
    connection: MailboxConnection
  ) -> Bool {
    let foldersById = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
    let messages = snapshot.messages
      .filter { messageIds.contains($0.stableProviderId) }
      .map { $0.mailboxMetadata(connection: connection, foldersById: foldersById) }
    guard messages.count == messageIds.count else { return false }
    return messages.allSatisfy { message in
      let states = Set(message.providerStateIds ?? [])
      switch action {
      case .archive: return states.contains("ARCHIVE")
      case .delete: return states.contains("TRASH")
      case .markRead: return !states.contains("UNREAD")
      case .markUnread: return states.contains("UNREAD")
      case .move:
        guard let targetFolderId else { return false }
        return states.contains(targetFolderId)
          && (targetFolderId == "INBOX" || !states.contains("INBOX"))
      case .notSpam: return !states.contains("SPAM") && states.contains("INBOX")
      case .restore: return !states.contains("TRASH") && states.contains("INBOX")
      case .spam: return !states.contains("INBOX") && states.contains("SPAM")
      case .star: return states.contains("STARRED")
      case .unstar: return !states.contains("STARRED")
      }
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  private func applyConfirmedAction(
    _ action: ProviderMailAction,
    targetFolderId: String?,
    messageIds: [String],
    movedItems: [EWSMovedItemIdentity],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    var snapshot = try requiredSnapshot(connection, session: session)
    let destinationRole: EWSFolderRole? =
      switch action {
      case .archive: .archive
      case .delete: .trash
      case .notSpam, .restore: .inbox
      case .spam: .spam
      default: nil
      }
    let destinationId =
      targetFolderId.flatMap { EWSProviderMessage.folderId(fromProviderStateId: $0) }
      ?? targetFolderId
      ?? destinationRole.flatMap { role in
        snapshot.folders.first(where: { $0.role == role })?.id
      }
    for index in snapshot.messages.indices
    where messageIds.contains(snapshot.messages[index].stableProviderId) {
      if let moved = movedItems.first(where: {
        $0.stableProviderId == snapshot.messages[index].stableProviderId
      }) {
        snapshot.messages[index].itemId = moved.itemId
        snapshot.messages[index].changeKey = moved.changeKey
      }
      switch action {
      case .markRead:
        snapshot.messages[index].isRead = true
      case .markUnread:
        snapshot.messages[index].isRead = false
      case .star:
        snapshot.messages[index].isFlagged = true
      case .unstar:
        snapshot.messages[index].isFlagged = false
      case .archive, .delete, .move, .notSpam, .restore, .spam:
        if let destinationId {
          snapshot.messages[index].parentFolderId = destinationId
        }
      }
    }
    try metadataStore.save(
      snapshot,
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
  }

  // swiftlint:disable:next function_body_length
  private func refreshRecentSnapshot(
    _ connection: MailboxConnection,
    authorization: DeviceLocalEWSAuthorization,
    session: ProductAccountSessionSnapshot,
    shouldPersist: () -> Bool = { true }
  ) async throws -> EWSMetadataSnapshot {
    var snapshot = try requiredSnapshot(connection, session: session)
    let folders = try await client.loadFolders(authorization: authorization)
    var recentPagesByFolderId: [String: EWSMessagePage] = [:]
    var recentObservedIdsByFolderId: [String: Set<String>] = [:]
    for folder in folders {
      let page = try await client.loadMessagePage(
        folder: folder,
        offset: 0,
        pageSize: Self.initialPageSize,
        authorization: authorization
      )
      recentPagesByFolderId[folder.id] = page
      let observedIds = upsert(page.messages, into: &snapshot.messages)
      recentObservedIdsByFolderId[folder.id] = observedIds
      let scanIsInProgress =
        snapshot.nextOffsetsByFolderId[folder.id] != nil
        || snapshot.reconciliationMessageIdsByFolderId[folder.id] != nil
      if !scanIsInProgress {
        snapshot.reconciliationMessageIdsByFolderId[folder.id] = observedIds
        if let nextOffset = page.nextOffset {
          snapshot.nextOffsetsByFolderId[folder.id] = nextOffset
        } else {
          finishReconciliation(for: folder.id, snapshot: &snapshot)
        }
      }
    }
    let activeFolderIds = Set(folders.map(\.id))
    snapshot.folders = folders
    snapshot.messages.removeAll { !activeFolderIds.contains($0.parentFolderId) }
    for folder in folders {
      guard
        let page = recentPagesByFolderId[folder.id],
        let observedIds = recentObservedIdsByFolderId[folder.id]
      else { continue }
      let observedCutoff = page.messages.map(\.receivedAtMilliseconds).min()
      snapshot.messages.removeAll { message in
        guard message.parentFolderId == folder.id, !observedIds.contains(message.stableProviderId)
        else { return false }
        if page.nextOffset == nil { return true }
        return observedCutoff.map { message.receivedAtMilliseconds > $0 } ?? false
      }
    }
    snapshot.nextOffsetsByFolderId = snapshot.nextOffsetsByFolderId.filter {
      activeFolderIds.contains($0.key)
    }
    snapshot.reconciliationMessageIdsByFolderId =
      snapshot.reconciliationMessageIdsByFolderId.filter {
        activeFolderIds.contains($0.key)
      }
    guard shouldPersist() else { throw CancellationError() }
    try metadataStore.save(
      snapshot,
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
    return snapshot
  }

  private static func isDefinitePreDeliveryNetworkFailure(_ error: URLError) -> Bool {
    switch error.code {
    case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
      return true
    default:
      return false
    }
  }

  private func finishReconciliation(
    for folderId: String,
    snapshot: inout EWSMetadataSnapshot,
    deleteUnobserved: Bool = true
  ) {
    guard let observedIds = snapshot.reconciliationMessageIdsByFolderId[folderId] else {
      return
    }
    if deleteUnobserved {
      snapshot.messages.removeAll {
        $0.parentFolderId == folderId && !observedIds.contains($0.stableProviderId)
      }
    }
    snapshot.reconciliationMessageIdsByFolderId[folderId] = nil
  }

  private func resolveBlockedAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    discard: Bool
  ) async -> String? {
    do {
      let performer = pendingActionPerformer(connection: connection, session: session)
      if discard {
        try await pendingActionService.discardBlockedAction(
          connection: connection,
          session: session,
          provider: performer
        )
      } else {
        try await pendingActionService.retryBlockedAction(
          connection: connection,
          session: session,
          provider: performer
        )
      }
      return try await pendingActionService.failureDescription(
        connection: connection,
        session: session
      )
    } catch {
      return error.localizedDescription
    }
  }

  private func authorizationForProviderAccess(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    isWithinSyncGate: Bool = false
  ) async throws -> DeviceLocalEWSAuthorization {
    try validate(connection, session: session, requiresAuthorization: true)
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    if snapshot.removedConnectionIds.contains(connection.id) {
      if isWithinSyncGate {
        try await clearLocalConnectionWithoutLock(connection, session: session)
      } else {
        try await clearLocalConnection(connection, session: session)
      }
      throw MailboxConnectionAdapterError.connectionRemoved
    }
    guard
      let authorization = try authorizationStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    else { throw MailboxConnectionAdapterError.authorizationRequired }
    guard
      let definition = snapshot.connections.first(where: { $0.id == connection.id })?
        .ewsDefinition
    else { throw MailboxConnectionAdapterError.connectionRemoved }
    guard authorization.definition == definition else {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    return DeviceLocalEWSAuthorization(
      credential: authorization.credential,
      definition: definition
    )
  }

  private func loadResult(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try validate(connection, session: session, requiresAuthorization: true)
    let snapshot =
      try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
      ?? EWSMetadataSnapshot(
        folders: [],
        messages: [],
        nextOffsetsByFolderId: [:],
        hasInitialMailboxAvailability: false
      )
    return try await projectedResult(
      snapshot,
      collection,
      connection: connection,
      session: session
    )
  }

  private func projectedResult(
    _ snapshot: EWSMetadataSnapshot,
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await pendingActionService.project(
      result(snapshot, .allObserved, connection: connection),
      collection: collection,
      connection: connection,
      session: session
    )
  }

  private func requiredSnapshot(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws -> EWSMetadataSnapshot {
    guard
      let snapshot = try metadataStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    else { throw MailboxConnectionAdapterError.connectionRemoved }
    return snapshot
  }

  private func storedMessage(
    _ message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws -> EWSProviderMessage {
    let snapshot = try requiredSnapshot(
      MailboxConnection(
        authorizationState: .authorized,
        capabilities: .exchangeWebServices,
        connectedAt: 0,
        displayName: "",
        id: message.connectionId,
        lastVerifiedAt: 0,
        productAccountId: ProductAccountId(session.productAccountId),
        trustedDeviceId: session.trustedDeviceId,
        updatedAt: 0
      ),
      session: session
    )
    guard
      let stored = snapshot.messages.first(where: {
        $0.stableProviderId == message.providerMessageId
      })
    else { throw MailboxConnectionAdapterError.connectionRemoved }
    return stored
  }

  private func result(
    _ snapshot: EWSMetadataSnapshot,
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection
  ) throws -> MailboxMetadataSyncResult {
    let foldersById = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
    let allMessages = snapshot.messages.map {
      $0.mailboxMetadata(connection: connection, foldersById: foldersById)
    }.sorted {
      if $0.providerInternalDateMilliseconds == $1.providerInternalDateMilliseconds {
        return $0.providerMessageId < $1.providerMessageId
      }
      return $0.providerInternalDateMilliseconds > $1.providerInternalDateMilliseconds
    }
    let messages = allMessages.filter {
      collection.contains(providerStateIds: $0.providerStateIds)
    }
    let visibleThreadIds = Set(messages.map(\.threadIdentity))
    let threads = MailboxThread.group(allMessages).filter { visibleThreadIds.contains($0.id) }
    return MailboxMetadataSyncResult(
      hasUnlistedNewMessages: false,
      messages: messages,
      newMessageIds: nil,
      providerCursorIsExpired: false,
      threads: threads,
      hasInitialMailboxAvailability: snapshot.hasInitialMailboxAvailability,
      historicalMetadataBackfillIsComplete: snapshot.historicalMetadataBackfillIsComplete
    )
  }

  @discardableResult
  private func upsert(
    _ messages: [EWSProviderMessage],
    into existing: inout [EWSProviderMessage]
  ) -> Set<String> {
    var observedIds: Set<String> = []
    for message in messages {
      if let index = existing.firstIndex(where: {
        $0.stableProviderId == message.stableProviderId || $0.itemId == message.itemId
      }) {
        var updated = message
        updated.categoryId = updated.categoryId ?? existing[index].categoryId
        updated.stableProviderId = existing[index].stableProviderId
        existing[index] = updated
        observedIds.insert(updated.stableProviderId)
      } else {
        existing.append(message)
        observedIds.insert(message.stableProviderId)
      }
    }
    return observedIds
  }

  private func requiredConnection(
    _ id: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnection {
    guard let connection = try await loadConnections(session: session).first(where: { $0.id == id })
    else { throw MailboxConnectionAdapterError.connectionRemoved }
    return connection
  }

  private func validate(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    requiresAuthorization: Bool
  ) throws {
    guard connection.productAccountId == ProductAccountId(session.productAccountId) else {
      throw MailboxConnectionAdapterError.productAccountMismatch
    }
    guard connection.providerId == .exchangeWebServices else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    if requiresAuthorization, connection.authorizationState != .authorized {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
  }
}
