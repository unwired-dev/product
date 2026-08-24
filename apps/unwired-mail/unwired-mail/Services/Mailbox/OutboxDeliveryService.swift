import Foundation

// swiftlint:disable file_length

enum OutgoingDeliveryState: String, Codable, Sendable {
  case cancelled
  case failed
  case handingOff
  case outcomeUnknown
  case pending
  case reconciling
  case retrying
  case sent
  case sentCopyPending
  case superseded
  case userActionRequired

  var isActionable: Bool {
    switch self {
    case .failed, .handingOff, .outcomeUnknown, .pending, .reconciling, .retrying,
      .sentCopyPending, .userActionRequired:
      true
    case .cancelled, .sent, .superseded:
      false
    }
  }

  var canEditOrCancel: Bool {
    switch self {
    case .failed, .pending, .retrying, .userActionRequired:
      true
    case .cancelled, .handingOff, .outcomeUnknown, .reconciling, .sent, .sentCopyPending,
      .superseded:
      false
    }
  }
}

struct OutgoingDeliveryAttempt: Codable, Equatable, Identifiable, Sendable {
  var attemptCount: Int
  let connectionId: MailboxConnectionId
  let createdAtMilliseconds: Int64
  var firstAttemptAtMilliseconds: Int64?
  let id: UUID
  let idempotencyKey: String
  var lastErrorDescription: String?
  let message: OutgoingMessage
  var nextRetryAtMilliseconds: Int64?
  var notSentConfirmationCount: Int? = .none
  let productAccountId: ProductAccountId
  var providerDraftCleanupAttemptCount: Int?
  var providerDraftCleanupErrorDescription: String?
  var providerDraftId: String?
  var providerHandoffNotBeforeMilliseconds: Int64? = .none
  var reconciliationAttemptCount: Int
  var reconciliationPausedForAuthorization: Bool? = .none
  var scheduledSendClaimGeneration: Int? = .none
  var scheduledSendClaimOwnerTrustedDeviceId: String? = .none
  var scheduledSendDeadlineMilliseconds: Int64? = .none
  var scheduledSendId: UUID? = .none
  var scheduledSendRevision: Int? = .none
  var scheduledSendAtMilliseconds: Int64? = .none
  var state: OutgoingDeliveryState

  var mailboxConnectionId: MailboxConnectionId {
    connectionId
  }

  var canEditOrCancel: Bool {
    !isScheduledSend
      && canCancel
  }

  var canCancel: Bool {
    state.canEditOrCancel
      && reconciliationPausedForAuthorization != true
  }

  var providerDraftRequiresCleanup: Bool {
    guard providerDraftId != nil else { return false }
    switch state {
    case .cancelled, .failed, .superseded:
      return true
    case .handingOff, .outcomeUnknown, .pending, .reconciling, .retrying, .sent,
      .sentCopyPending, .userActionRequired:
      return false
    }
  }

  var isScheduledSend: Bool {
    scheduledSendId != nil
  }
}

protocol OutboxDeliveryPersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> [OutgoingDeliveryAttempt]
  func save(
    _ attempts: [OutgoingDeliveryAttempt],
    productAccountId: String
  ) throws
}

protocol OutboxDeliveryClearing {
  func clear(session: ProductAccountSessionSnapshot) async throws
  func clear(productAccountId: String) async throws
  func suspend(productAccountId: String) async
}

extension OutboxDeliveryPersisting {
  func clear(productAccountId: String) throws {
    try save([], productAccountId: productAccountId)
  }
}

private struct EncryptedOutboxDeliveryFile: Codable {
  let payload: ProductSyncEncryptedPayload
}

struct FileOutboxDeliveryStore: OutboxDeliveryPersisting {
  private let fileManager: FileManager
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let rootDirectory: URL

  init(
    fileManager: FileManager = .default,
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    rootDirectory: URL? = nil
  ) {
    self.fileManager = fileManager
    self.keyMaterialStore = keyMaterialStore
    self.rootDirectory =
      rootDirectory
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("UnwiredMail/Outbox", isDirectory: true)
  }

  func load(productAccountId: String) throws -> [OutgoingDeliveryAttempt] {
    let fileURL = fileURL(productAccountId: productAccountId)
    guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
    let encryptedFile = try JSONDecoder().decode(
      EncryptedOutboxDeliveryFile.self,
      from: Data(contentsOf: fileURL)
    )
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: productAccountId,
      allowCreation: false
    )
    let plaintext = try material.decryptPayload(
      encryptedFile.payload,
      associatedData: associatedData(productAccountId: productAccountId)
    )
    return try JSONDecoder().decode([OutgoingDeliveryAttempt].self, from: plaintext)
  }

  func clear(productAccountId: String) throws {
    let fileURL = fileURL(productAccountId: productAccountId)
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    try fileManager.removeItem(at: fileURL)
  }

  func save(
    _ attempts: [OutgoingDeliveryAttempt],
    productAccountId: String
  ) throws {
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: productAccountId,
      allowCreation: false
    )
    let payload = try material.encryptPayload(
      JSONEncoder().encode(attempts),
      associatedData: associatedData(productAccountId: productAccountId)
    )
    try fileManager.createDirectory(
      at: rootDirectory,
      withIntermediateDirectories: true
    )
    try JSONEncoder().encode(EncryptedOutboxDeliveryFile(payload: payload)).write(
      to: fileURL(productAccountId: productAccountId),
      options: [.atomic]
    )
  }

  private func associatedData(productAccountId: String) -> Data {
    Data("dev.unwired.mail.outbox.v1.\(productAccountId)".utf8)
  }

  private func fileURL(productAccountId: String) -> URL {
    rootDirectory.appendingPathComponent(
      "\(gmailSafeFileComponent(productAccountId)).json"
    )
  }
}

struct StandardsMailPendingSentCopy: Codable, Equatable, Sendable {
  let connectionId: MailboxConnectionId
  let idempotencyKey: String
  let mailbox: String
  let rawMessage: Data
  let rfcMessageId: String
}

protocol StandardsMailSentCopyPersisting {
  func clear(productAccountId: String) throws

  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws

  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> [StandardsMailPendingSentCopy]

  func save(
    _ copies: [StandardsMailPendingSentCopy],
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws
}

private struct EncryptedStandardsMailSentCopyFile: Codable {
  let payload: ProductSyncEncryptedPayload
}

struct FileStandardsMailSentCopyStore: StandardsMailSentCopyPersisting {
  private let fileManager: FileManager
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let rootDirectory: URL

  init(
    fileManager: FileManager = .default,
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    rootDirectory: URL? = nil
  ) {
    self.fileManager = fileManager
    self.keyMaterialStore = keyMaterialStore
    self.rootDirectory =
      rootDirectory
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("UnwiredMail/StandardsMailSentCopies", isDirectory: true)
  }

  func clear(productAccountId: String) throws {
    let directory = accountDirectory(productAccountId: productAccountId)
    guard fileManager.fileExists(atPath: directory.path) else { return }
    try fileManager.removeItem(at: directory)
  }

  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    let file = fileURL(productAccountId: productAccountId, connectionId: connectionId)
    guard fileManager.fileExists(atPath: file.path) else { return }
    try fileManager.removeItem(at: file)
  }

  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> [StandardsMailPendingSentCopy] {
    let file = fileURL(productAccountId: productAccountId, connectionId: connectionId)
    guard fileManager.fileExists(atPath: file.path) else { return [] }
    let encryptedFile = try JSONDecoder().decode(
      EncryptedStandardsMailSentCopyFile.self,
      from: Data(contentsOf: file)
    )
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: productAccountId,
      allowCreation: false
    )
    let plaintext = try material.decryptPayload(
      encryptedFile.payload,
      associatedData: associatedData(
        productAccountId: productAccountId,
        connectionId: connectionId
      )
    )
    return try JSONDecoder().decode([StandardsMailPendingSentCopy].self, from: plaintext)
  }

  func save(
    _ copies: [StandardsMailPendingSentCopy],
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    guard !copies.isEmpty else {
      try clear(productAccountId: productAccountId, connectionId: connectionId)
      return
    }
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: productAccountId,
      allowCreation: false
    )
    let payload = try material.encryptPayload(
      JSONEncoder().encode(copies),
      associatedData: associatedData(
        productAccountId: productAccountId,
        connectionId: connectionId
      )
    )
    let directory = accountDirectory(productAccountId: productAccountId)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(EncryptedStandardsMailSentCopyFile(payload: payload)).write(
      to: fileURL(productAccountId: productAccountId, connectionId: connectionId),
      options: [.atomic]
    )
  }

  private func accountDirectory(productAccountId: String) -> URL {
    rootDirectory.appendingPathComponent(
      gmailSafeFileComponent(productAccountId),
      isDirectory: true
    )
  }

  private func associatedData(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) -> Data {
    Data(
      "dev.unwired.mail.standards-mail-sent-copy.v1.\(productAccountId).\(connectionId.rawValue)"
        .utf8
    )
  }

  private func fileURL(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) -> URL {
    accountDirectory(productAccountId: productAccountId).appendingPathComponent(
      "\(gmailSafeFileComponent(connectionId.rawValue)).json"
    )
  }
}

enum MailboxDeliveryStatus: Equatable, Sendable {
  case notSent
  case sent
  case sentCopyPending
  case unknown
}

enum OutboxDeliveryFailureDisposition: Sendable {
  case ambiguous
  case permanent
  case sentCopyPending
  case transient
  case userActionRequired
}

enum OutboxDeliveryError: LocalizedError, Equatable {
  case connectionMismatch
  case deliveryNotConfirmed
  case productAccountMismatch
  case attemptCannotBeChanged
  case invalidScheduledWindow
  case scheduledSendClaimUnavailable
  case scheduledSendHandoffRejected

  var errorDescription: String? {
    switch self {
    case .connectionMismatch:
      "The Outbox message does not belong to this Mailbox Connection."
    case .deliveryNotConfirmed:
      "The provider has not yet confirmed whether this message was delivered."
    case .productAccountMismatch:
      "The Mailbox Connection does not belong to the current Product Account."
    case .attemptCannotBeChanged:
      "This delivery is already being handed to the mail provider."
    case .invalidScheduledWindow:
      "Choose a new Scheduled Send time and try again."
    case .scheduledSendClaimUnavailable:
      "Another Trusted Device is preparing this Scheduled Send."
    case .scheduledSendHandoffRejected:
      "Scheduled Send changed before provider handoff."
    }
  }
}

struct OutboxProviderDraftCleanupExhaustedError: LocalizedError {
  let underlyingError: Error

  var errorDescription: String? {
    underlyingError.localizedDescription
  }
}

typealias OutboxDeliveryPerformer =
  @Sendable (
    _ message: OutgoingMessage,
    _ idempotencyKey: String,
    _ connectionId: MailboxConnectionId
  ) async throws -> Void
typealias OutboxDeliveryReconciler =
  @Sendable (
    _ idempotencyKey: String,
    _ connectionId: MailboxConnectionId
  ) async throws -> MailboxDeliveryStatus
typealias OutboxProviderDraftCleaner =
  @Sendable (
    _ providerDraftId: String,
    _ connectionId: MailboxConnectionId,
    _ productAccountId: String
  ) async throws -> Void

private let defaultDraftCleaner: OutboxProviderDraftCleaner = { id, connection, account in
  guard connection.providerId == .microsoftGraph else { return }
  try await MicrosoftGraphMailboxConnectionAdapter().deleteOutboxDraft(
    id,
    connectionId: connection,
    productAccountId: account
  )
}

// swiftlint:disable:next cyclomatic_complexity function_body_length
func outboxFailureDisposition(for error: Error) -> OutboxDeliveryFailureDisposition {
  if let deliveryError = error as? StandardsMailDeliveryError {
    switch deliveryError {
    case .ambiguous:
      return .ambiguous
    case .authenticationRequired, .invalidRecipients:
      return .userActionRequired
    case .permanentlyRejected:
      return .permanent
    case .sentCopyPending:
      return .sentCopyPending
    case .transientlyRejected:
      return .transient
    }
  }
  if let sendError = error as? MicrosoftGraphSendError {
    let disposition = outboxFailureDisposition(for: sendError.underlyingError)
    if sendError.stage == .preparation, disposition == .ambiguous {
      return .transient
    }
    return disposition
  }
  if let urlError = error as? URLError {
    switch urlError.code {
    case .cannotConnectToHost, .cannotFindHost, .dataNotAllowed, .dnsLookupFailed,
      .internationalRoamingOff, .notConnectedToInternet:
      return .transient
    default:
      return .ambiguous
    }
  }
  if let metadataError = error as? GmailMessageMetadataSyncError {
    switch metadataError {
    case .insufficientGmailScope, .missingLocalGmailTokens,
      .refreshedTokenAccountMismatch, .refreshTokenRejected:
      return .userActionRequired
    case .oauthResponseStatus(let status):
      if status == 408 || status == 409 || status == 425 || status == 429 || status >= 500 {
        return .transient
      }
      return .userActionRequired
    default:
      break
    }
  }
  if error as? MailboxConnectionAdapterError == .authorizationRequired {
    return .userActionRequired
  }
  if let ewsError = error as? EWSServiceError {
    switch ewsError {
    case .authenticationRejected:
      return .userActionRequired
    case .invalidResponse:
      return .ambiguous
    case .response(let code, _):
      let status = code.split(separator: " ").last.flatMap { Int($0) }
      if status.map({ $0 >= 500 }) == true
        || status == 408 || status == 409 || status == 425
        || code == "ErrorTimeoutExpired"
      {
        return .ambiguous
      }
      if status == 429
        || [
          "ErrorADUnavailable",
          "ErrorExceededConnectionCount",
          "ErrorInternalServerTransientError",
          "ErrorMailboxStoreUnavailable",
          "ErrorServerBusy",
        ].contains(code)
      {
        return .transient
      }
    }
  }
  if case .tokenExchangeFailed(let status) = error as? MicrosoftGraphOAuthError,
    let status,
    status == 408 || status == 409 || status == 425 || status == 429 || status >= 500
  {
    return .transient
  }
  if case .tokenExchangeFailed(let status) = error as? EWSOAuthError,
    let status,
    status == 408 || status == 409 || status == 425 || status == 429 || status >= 500
  {
    return .transient
  }
  if case .requestFailed(let status) = error as? MicrosoftGraphClientError {
    if status == 401 || status == 403 {
      return .userActionRequired
    }
    if status == 429 {
      return .transient
    }
    if status == 408 || status == 409 || status == 425 || status >= 500 {
      return .ambiguous
    }
  }
  if case .rateLimitedResponseStatus = error as? GmailProviderMailActionError {
    return .transient
  }
  if case .responseStatus(let status) = error as? GmailProviderMailActionError {
    if status == 401 || status == 403 {
      return .userActionRequired
    }
    if status == 429 {
      return .transient
    }
    if status == 408 || status == 409 || status == 425 || status >= 500 {
      return .ambiguous
    }
  }
  return .permanent
}

private let defaultOutboxFailureDisposition: @Sendable (Error) -> OutboxDeliveryFailureDisposition =
  {
    outboxFailureDisposition(for: $0)
  }

private let defaultOutboxRetryDelay: @Sendable (Int) -> UInt64 = { attempt in
  let seconds = min(60, 1 << max(0, attempt - 1))
  return UInt64(seconds) * 1_000_000_000
}

private let defaultOutboxHandoffDelay: UInt64 = 10_000_000_000

struct ScheduledSendRecord: Codable, Equatable, Sendable {
  let connectionId: MailboxConnectionId
  let createdAtMilliseconds: Int64
  let deadlineAtMilliseconds: Int64
  let draftId: UUID
  let dueAtMilliseconds: Int64
  let message: OutgoingMessage
  let originatingDeviceId: String
  let originalTimeZoneIdentifier: String
  let profileId: MailProfileId
  let revision: Int
  let scheduleId: UUID
}

struct ScheduledSendPayloadAcknowledgement: Equatable, Sendable {
  let payloadIdentifier: String
  let updatedAt: Int64
}

struct ScheduledSendPayloadSnapshot: Equatable, Sendable {
  let acknowledgement: ScheduledSendPayloadAcknowledgement
  let record: ScheduledSendRecord
}

struct ScheduledSendOperationalAcknowledgement: Decodable, Equatable, Sendable {
  let dueAt: Int64
  let encryptedPayloadUpdatedAt: Int64
  let revision: Int
  let scheduleId: String
}

enum ScheduledSendClaimPhase: String, Decodable, Equatable, Sendable {
  case handingOff = "handing-off"
  case preHandoff = "pre-handoff"
}

struct ScheduledSendClaim: Equatable, Sendable {
  let authorizationGeneration: Int
  let expiresAt: Int64?
  let generation: Int
  let phase: ScheduledSendClaimPhase
}

enum ScheduledSendClaimResult: Equatable, Sendable {
  case claimed(ScheduledSendClaim)
  case unavailable
}

enum ScheduledSendCompletionState: String, Encodable, Sendable {
  case completed
  case needsAttention = "needs-attention"
}

enum ScheduledSendOperationalState: String, Decodable, Equatable, Sendable {
  case active
  case cancelled
  case completed
  case needsAttention = "needs-attention"
}

struct ScheduledSendOperationalStatus: Decodable, Equatable, Sendable {
  let claimPhase: ScheduledSendClaimPhase?
  let deadlineAt: Int64
  let dueAt: Int64
  let encryptedPayloadIdentifier: String
  let encryptedPayloadUpdatedAt: Int64
  let revision: Int
  let scheduleId: String
  let state: ScheduledSendOperationalState
}

struct ScheduledSendEditLease: Equatable, Sendable {
  let expiresAt: Int64
  let generation: Int
}

enum ScheduledSendEditLeaseResult: Equatable, Sendable {
  case acquired(ScheduledSendEditLease)
  case unavailable
}

enum ManagedScheduledSendState: Equatable, Sendable {
  case needsAttention
  case scheduled
  case sending
}

struct ManagedScheduledSend: Equatable, Identifiable, Sendable {
  let payload: ScheduledSendPayloadAcknowledgement
  let record: ScheduledSendRecord
  let state: ManagedScheduledSendState

  var id: UUID { record.scheduleId }
}

struct ScheduledSendEditSession: Equatable, Identifiable, Sendable {
  let item: ManagedScheduledSend
  let lease: ScheduledSendEditLease

  var id: UUID { item.id }
}

enum ScheduledSendManagementError: LocalizedError, Equatable {
  case editUnavailable
  case scheduledTimePassed
  case staleRevision

  var errorDescription: String? {
    switch self {
    case .editUnavailable:
      "This Scheduled Send is being edited or sent on another device. Reload Outbox."
    case .scheduledTimePassed:
      "The scheduled time passed while you were editing. Choose Send Now or a new time."
    case .staleRevision:
      "This Scheduled Send changed on another device. Reload it before editing again."
    }
  }
}

enum ScheduledDeliveryAuthorizationError: LocalizedError, Equatable {
  case missing

  var errorDescription: String? {
    "Register this trusted device for Scheduled Delivery before claiming due mail."
  }
}

protocol ScheduledSendPayloadSyncing {
  func load(
    scheduleId: UUID,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendRecord?
  func list(session: ProductAccountSessionSnapshot) async throws -> [ScheduledSendPayloadSnapshot]
  func load(
    scheduleId: UUID,
    revision: Int,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendPayloadSnapshot?
  func remove(scheduleId: UUID, session: ProductAccountSessionSnapshot) async throws
  func remove(
    scheduleId: UUID,
    revision: Int,
    session: ProductAccountSessionSnapshot
  ) async throws
  func save(
    _ record: ScheduledSendRecord,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendPayloadAcknowledgement
}

protocol ScheduledSendOperationalTransport {
  func admitScheduledSend(
    _ record: ScheduledSendRecord,
    payload: ScheduledSendPayloadAcknowledgement,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalAcknowledgement

  func cancelScheduledSend(
    scheduleId: UUID,
    revision: Int,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool

  func cancelScheduledSend(
    scheduleId: UUID,
    revision: Int,
    editGeneration: Int?,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool

  func scheduledSendStatus(
    scheduleId: UUID,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalStatus?

  func beginScheduledSendEdit(
    scheduleId: UUID,
    revision: Int,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendEditLeaseResult

  func releaseScheduledSendEdit(
    scheduleId: UUID,
    revision: Int,
    editGeneration: Int,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool

  func rescheduleScheduledSend(
    _: ScheduledSendRecord,
    payload: ScheduledSendPayloadAcknowledgement,
    expectedRevision: Int,
    editGeneration: Int,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalAcknowledgement

  func sendScheduledSendNow(
    _: ScheduledSendRecord,
    payload: ScheduledSendPayloadAcknowledgement,
    expectedRevision: Int,
    editGeneration: Int,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalAcknowledgement

  func registerScheduledDeliveryCapability(
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledDeliveryAuthorization

  func claimScheduledSend(
    scheduleId: UUID,
    revision: Int,
    trustedDeviceId: String
  ) async throws -> ScheduledSendClaimResult

  func advanceScheduledSendClaimToHandoff(
    scheduleId: UUID,
    revision: Int,
    claimGeneration: Int,
    trustedDeviceId: String
  ) async throws -> Bool

  func revalidateScheduledSendClaim(
    scheduleId: UUID,
    revision: Int,
    claimGeneration: Int,
    trustedDeviceId: String
  ) async throws -> ScheduledSendClaimResult

  func releaseScheduledSendClaim(
    scheduleId: UUID,
    revision: Int,
    claimGeneration: Int,
    trustedDeviceId: String
  ) async throws -> Bool

  func completeScheduledSendClaim(
    scheduleId: UUID,
    revision: Int,
    claimGeneration: Int,
    state: ScheduledSendCompletionState,
    trustedDeviceId: String
  ) async throws -> Bool
}

extension ScheduledSendPayloadSyncing {
  func list(
    session _: ProductAccountSessionSnapshot
  ) async throws -> [ScheduledSendPayloadSnapshot] { [] }

  func load(
    scheduleId _: UUID,
    revision _: Int,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendPayloadSnapshot? {
    nil
  }

  func remove(
    scheduleId: UUID,
    revision _: Int,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await remove(scheduleId: scheduleId, session: session)
  }
}

extension ScheduledSendOperationalTransport {
  func cancelScheduledSend(
    scheduleId: UUID,
    revision: Int,
    editGeneration _: Int?,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool {
    try await cancelScheduledSend(
      scheduleId: scheduleId,
      revision: revision,
      session: session
    )
  }

  func scheduledSendStatus(
    scheduleId _: UUID,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalStatus? { nil }

  func beginScheduledSendEdit(
    scheduleId _: UUID,
    revision _: Int,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendEditLeaseResult { .unavailable }

  func releaseScheduledSendEdit(
    scheduleId _: UUID,
    revision _: Int,
    editGeneration _: Int,
    session _: ProductAccountSessionSnapshot
  ) async throws -> Bool { false }

  func rescheduleScheduledSend(
    _ record: ScheduledSendRecord,
    payload _: ScheduledSendPayloadAcknowledgement,
    expectedRevision _: Int,
    editGeneration _: Int,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalAcknowledgement {
    throw ScheduledSendManagementError.staleRevision
  }

  func sendScheduledSendNow(
    _ record: ScheduledSendRecord,
    payload _: ScheduledSendPayloadAcknowledgement,
    expectedRevision _: Int,
    editGeneration _: Int,
    session _: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendOperationalAcknowledgement {
    throw ScheduledSendManagementError.staleRevision
  }
}

private struct ScheduledSendSyncPayload: Codable, Sendable {
  let record: ScheduledSendRecord?
  let updatedAtMilliseconds: Int64
}

private struct ScheduledSendSyncRecordId: Hashable, Sendable {
  let revision: Int
  let scheduleId: UUID
}

actor ScheduledSendSyncService: ScheduledSendPayloadSyncing {
  private static let legacyPrefix = "scheduled-send.v1."
  private static let revisionedPrefix = "scheduled-send.v2."
  private let legacyRecords: ProductSyncRecordFamilyHandle<UUID, ScheduledSendSyncPayload>
  private let revisionedRecords:
    ProductSyncRecordFamilyHandle<ScheduledSendSyncRecordId, ScheduledSendSyncPayload>

  init(recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()) {
    legacyRecords = recordBoundary.family(
      ProductSyncRecordFamilyDefinition(
        identifier: { Self.legacyIdentifier($0) },
        identifierPrefix: Self.legacyPrefix,
        recordId: { Self.legacyRecordId($0) },
        cachePolicy: .authoritative
      )
    )
    revisionedRecords = recordBoundary.family(
      ProductSyncRecordFamilyDefinition(
        identifier: { Self.revisionedIdentifier($0) },
        identifierPrefix: Self.revisionedPrefix,
        recordId: { Self.revisionedRecordId($0) },
        cachePolicy: .authoritative
      )
    )
  }

  func load(
    scheduleId: UUID,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendRecord? {
    let snapshots = try await list(session: session)
    return
      snapshots
      .filter { $0.record.scheduleId == scheduleId }
      .max { $0.record.revision < $1.record.revision }?
      .record
  }

  func load(
    scheduleId: UUID,
    revision: Int,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendPayloadSnapshot? {
    let recordId = ScheduledSendSyncRecordId(revision: revision, scheduleId: scheduleId)
    if let record = try await revisionedRecords.read([recordId], session: session)[recordId],
      let value = record.value.record
    {
      return ScheduledSendPayloadSnapshot(
        acknowledgement: ScheduledSendPayloadAcknowledgement(
          payloadIdentifier: Self.revisionedIdentifier(recordId),
          updatedAt: record.revision.legacyUpdatedAt
        ),
        record: value
      )
    }
    guard revision == 1,
      let legacy = try await legacyRecords.read([scheduleId], session: session)[scheduleId],
      let value = legacy.value.record
    else { return nil }
    return ScheduledSendPayloadSnapshot(
      acknowledgement: ScheduledSendPayloadAcknowledgement(
        payloadIdentifier: Self.legacyIdentifier(scheduleId),
        updatedAt: legacy.revision.legacyUpdatedAt
      ),
      record: value
    )
  }

  func list(
    session: ProductAccountSessionSnapshot
  ) async throws -> [ScheduledSendPayloadSnapshot] {
    let revisioned = try await revisionedRecords.list(session: session)
    var snapshots = revisioned.compactMap { recordId, record in
      record.value.record.map {
        ScheduledSendPayloadSnapshot(
          acknowledgement: ScheduledSendPayloadAcknowledgement(
            payloadIdentifier: Self.revisionedIdentifier(recordId),
            updatedAt: record.revision.legacyUpdatedAt
          ),
          record: $0
        )
      }
    }
    let legacy = try await legacyRecords.list(session: session)
    snapshots.append(
      contentsOf: legacy.compactMap { scheduleId, record in
        record.value.record.map {
          ScheduledSendPayloadSnapshot(
            acknowledgement: ScheduledSendPayloadAcknowledgement(
              payloadIdentifier: Self.legacyIdentifier(scheduleId),
              updatedAt: record.revision.legacyUpdatedAt
            ),
            record: $0
          )
        }
      }
    )
    return snapshots
  }

  func save(
    _ record: ScheduledSendRecord,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendPayloadAcknowledgement {
    let recordId = ScheduledSendSyncRecordId(
      revision: record.revision,
      scheduleId: record.scheduleId
    )
    let identifier = Self.revisionedIdentifier(recordId)
    let committed = try await revisionedRecords.update(recordId, session: session) { current in
      guard current?.value.record == nil || current?.value.record == record else {
        return .acceptAuthoritative
      }
      return .write(
        ScheduledSendSyncPayload(
          record: record,
          updatedAtMilliseconds: record.createdAtMilliseconds
        )
      )
    }
    guard let committed, committed.value.record == record else {
      throw ProductSyncRecordBoundaryError.retryLimitExceeded
    }
    return ScheduledSendPayloadAcknowledgement(
      payloadIdentifier: identifier,
      updatedAt: committed.revision.legacyUpdatedAt
    )
  }

  func remove(scheduleId: UUID, session: ProductAccountSessionSnapshot) async throws {
    let allSnapshots = try await list(session: session)
    let snapshots = allSnapshots.filter { $0.record.scheduleId == scheduleId }
    for snapshot in snapshots {
      try await remove(
        scheduleId: scheduleId,
        revision: snapshot.record.revision,
        session: session
      )
    }
  }

  func remove(
    scheduleId: UUID,
    revision: Int,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let recordId = ScheduledSendSyncRecordId(revision: revision, scheduleId: scheduleId)
    _ = try await revisionedRecords.update(recordId, session: session) { current in
      .write(
        ScheduledSendSyncPayload(
          record: nil,
          updatedAtMilliseconds: max(
            current?.value.updatedAtMilliseconds ?? 0,
            Int64(Date.now.timeIntervalSince1970 * 1_000)
          )
        )
      )
    }
    if revision == 1 {
      _ = try await legacyRecords.update(scheduleId, session: session) { current in
        guard current != nil else { return .acceptAuthoritative }
        return .write(
          ScheduledSendSyncPayload(
            record: nil,
            updatedAtMilliseconds: max(
              current?.value.updatedAtMilliseconds ?? 0,
              Int64(Date.now.timeIntervalSince1970 * 1_000)
            )
          )
        )
      }
    }

  }

  private static func legacyIdentifier(_ scheduleId: UUID) -> String {
    legacyPrefix + scheduleId.uuidString.lowercased()
  }

  private static func legacyRecordId(_ identifier: String) -> UUID? {
    guard identifier.hasPrefix(legacyPrefix) else { return nil }
    return UUID(uuidString: String(identifier.dropFirst(legacyPrefix.count)))
  }

  private static func revisionedIdentifier(_ recordId: ScheduledSendSyncRecordId) -> String {
    revisionedPrefix + recordId.scheduleId.uuidString.lowercased() + "." + String(recordId.revision)
  }

  private static func revisionedRecordId(_ identifier: String) -> ScheduledSendSyncRecordId? {
    guard identifier.hasPrefix(revisionedPrefix) else { return nil }
    let parts = identifier.dropFirst(revisionedPrefix.count).split(separator: ".")
    guard parts.count == 2,
      let scheduleId = UUID(uuidString: String(parts[0])),
      let revision = Int(parts[1]),
      revision > 0
    else { return nil }
    return ScheduledSendSyncRecordId(revision: revision, scheduleId: scheduleId)
  }
}

enum ScheduledSendAdmissionError: LocalizedError, Equatable {
  case incompleteAssets
  case invalidAcknowledgement
  case invalidDueDate
  case invalidRecipients
  case providerUnavailable
  case sizeLimitExceeded

  var errorDescription: String? {
    switch self {
    case .incompleteAssets:
      "Download every Draft asset before scheduling delivery."
    case .invalidAcknowledgement:
      "Scheduled Send could not verify its private payload. The message remains a Draft."
    case .invalidDueDate:
      "Choose a time from one minute through one year from now."
    case .invalidRecipients:
      "Add valid recipients before scheduling delivery."
    case .providerUnavailable:
      "Choose an authorized Gmail, Microsoft 365, or On-Premises Exchange Mailbox Connection for automatic delivery."
    case .sizeLimitExceeded:
      "This message is too large for the selected Mailbox Connection. Remove an attachment before scheduling delivery."
    }
  }
}

extension MailProviderId {
  /// Whether the provider supports product-owned Scheduled Send delivery.
  var supportsProductOwnedScheduledSend: Bool {
    self == .gmail || self == .microsoftGraph || self == .exchangeWebServices
  }
}

// swiftlint:disable:next type_body_length
actor ScheduledSendService {
  static let shared = ScheduledSendService()

  private let now: @Sendable () -> Date
  private let outboxService: OutboxDeliveryService
  private let payloadSync: ScheduledSendPayloadSyncing
  private let transport: ScheduledSendOperationalTransport

  init(
    now: @escaping @Sendable () -> Date = { Date() },
    outboxService: OutboxDeliveryService = .shared,
    payloadSync: ScheduledSendPayloadSyncing = ScheduledSendSyncService(),
    transport: ScheduledSendOperationalTransport = ConvexClient()
  ) {
    self.now = now
    self.outboxService = outboxService
    self.payloadSync = payloadSync
    self.transport = transport
  }

  @discardableResult
  // swiftlint:disable:next function_body_length function_parameter_count
  func schedule(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    draftId: UUID,
    profileId: MailProfileId,
    originalTimeZoneIdentifier: String,
    dueAt: Date,
    session: ProductAccountSessionSnapshot,
    undoSendDelayNanoseconds: UInt64,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws -> OutgoingDeliveryAttempt {
    try validate(message: message, connection: connection, dueAt: dueAt)
    let scheduleId = UUID()
    let dueAtMilliseconds = Int64(dueAt.timeIntervalSince1970 * 1_000)
    let record = ScheduledSendRecord(
      connectionId: connection.id,
      createdAtMilliseconds: Int64(now().timeIntervalSince1970 * 1_000),
      deadlineAtMilliseconds: dueAtMilliseconds + 24 * 60 * 60 * 1_000,
      draftId: draftId,
      dueAtMilliseconds: dueAtMilliseconds,
      message: message,
      originatingDeviceId: session.trustedDeviceId,
      originalTimeZoneIdentifier: originalTimeZoneIdentifier,
      profileId: profileId,
      revision: 1,
      scheduleId: scheduleId
    )
    _ = try await transport.registerScheduledDeliveryCapability(session: session)
    let payload = try await payloadSync.save(record, session: session)
    let acknowledgement: ScheduledSendOperationalAcknowledgement
    do {
      acknowledgement = try await transport.admitScheduledSend(
        record,
        payload: payload,
        session: session
      )
    } catch {
      try? await payloadSync.remove(scheduleId: scheduleId, session: session)
      throw error
    }
    guard acknowledgement.scheduleId == scheduleId.uuidString.lowercased(),
      acknowledgement.revision == record.revision,
      acknowledgement.dueAt == record.dueAtMilliseconds,
      acknowledgement.encryptedPayloadUpdatedAt == payload.updatedAt
    else {
      _ = try? await transport.cancelScheduledSend(
        scheduleId: scheduleId,
        revision: record.revision,
        session: session
      )
      try? await payloadSync.remove(scheduleId: scheduleId, session: session)
      throw ScheduledSendAdmissionError.invalidAcknowledgement
    }
    do {
      return try await outboxService.enqueueScheduled(
        message,
        connection: connection,
        session: session,
        scheduleId: scheduleId,
        revision: record.revision,
        dueAt: dueAt,
        deadline: Date(timeIntervalSince1970: Double(record.deadlineAtMilliseconds) / 1_000),
        undoSendDelayNanoseconds: undoSendDelayNanoseconds,
        provider: provider,
        reconcile: reconcile
      )
    } catch {
      _ = try? await transport.cancelScheduledSend(
        scheduleId: scheduleId,
        revision: record.revision,
        session: session
      )
      try? await payloadSync.remove(scheduleId: scheduleId, session: session)
      throw error
    }
  }

  func managedItems(
    session: ProductAccountSessionSnapshot
  ) async throws -> [ManagedScheduledSend] {
    let snapshots = try await payloadSync.list(session: session)
    let scheduleIds = Set(snapshots.map(\.record.scheduleId))
    var items: [ManagedScheduledSend] = []
    for scheduleId in scheduleIds {
      try Task.checkCancellation()
      guard
        let status = try await transport.scheduledSendStatus(
          scheduleId: scheduleId,
          session: session
        ), status.scheduleId == scheduleId.uuidString.lowercased(),
        let snapshot = try await payloadSync.load(
          scheduleId: scheduleId,
          revision: status.revision,
          session: session
        ),
        status.dueAt == snapshot.record.dueAtMilliseconds,
        status.deadlineAt == snapshot.record.deadlineAtMilliseconds,
        status.encryptedPayloadIdentifier == snapshot.acknowledgement.payloadIdentifier,
        status.encryptedPayloadUpdatedAt == snapshot.acknowledgement.updatedAt
      else { continue }
      let state: ManagedScheduledSendState
      switch status.state {
      case .active:
        state = status.claimPhase == .handingOff ? .sending : .scheduled
      case .needsAttention:
        state = .needsAttention
      case .cancelled, .completed:
        continue
      }
      items.append(
        ManagedScheduledSend(
          payload: snapshot.acknowledgement,
          record: snapshot.record,
          state: state
        )
      )
    }
    return items.sorted {
      if $0.record.dueAtMilliseconds == $1.record.dueAtMilliseconds {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.record.dueAtMilliseconds < $1.record.dueAtMilliseconds
    }
  }

  func beginEditing(
    _ item: ManagedScheduledSend,
    session: ProductAccountSessionSnapshot
  ) async throws -> ScheduledSendEditSession {
    guard item.state != .sending else { throw ScheduledSendManagementError.editUnavailable }
    let result = try await transport.beginScheduledSendEdit(
      scheduleId: item.id,
      revision: item.record.revision,
      session: session
    )
    guard case .acquired(let lease) = result else {
      throw ScheduledSendManagementError.editUnavailable
    }
    return ScheduledSendEditSession(item: item, lease: lease)
  }

  func releaseEditing(
    _ editSession: ScheduledSendEditSession,
    session: ProductAccountSessionSnapshot
  ) async {
    _ = try? await transport.releaseScheduledSendEdit(
      scheduleId: editSession.id,
      revision: editSession.item.record.revision,
      editGeneration: editSession.lease.generation,
      session: session
    )
  }

  @discardableResult
  // swiftlint:disable:next function_parameter_count
  func reschedule(
    _ editSession: ScheduledSendEditSession,
    message: OutgoingMessage,
    connection: MailboxConnection,
    dueAt: Date,
    originalTimeZoneIdentifier: String,
    session: ProductAccountSessionSnapshot,
    undoSendDelayNanoseconds: UInt64,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws -> ManagedScheduledSend {
    guard dueAt >= now().addingTimeInterval(60) else {
      throw ScheduledSendManagementError.scheduledTimePassed
    }
    return try await replace(
      editSession,
      message: message,
      connection: connection,
      dueAt: dueAt,
      originalTimeZoneIdentifier: originalTimeZoneIdentifier,
      sendsImmediately: false,
      session: session,
      undoSendDelayNanoseconds: undoSendDelayNanoseconds,
      provider: provider,
      reconcile: reconcile
    )
  }

  @discardableResult
  // swiftlint:disable:next function_parameter_count
  func sendNow(
    _ editSession: ScheduledSendEditSession,
    message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    undoSendDelayNanoseconds: UInt64,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws -> ManagedScheduledSend {
    let undoSendDelay = TimeInterval(undoSendDelayNanoseconds) / 1_000_000_000
    return try await replace(
      editSession,
      message: message,
      connection: connection,
      dueAt: now().addingTimeInterval(undoSendDelay),
      originalTimeZoneIdentifier: TimeZone.current.identifier,
      sendsImmediately: true,
      session: session,
      undoSendDelayNanoseconds: undoSendDelayNanoseconds,
      provider: provider,
      reconcile: reconcile
    )
  }

  func cancel(
    scheduleId: UUID,
    revision: Int,
    editGeneration: Int? = nil,
    session: ProductAccountSessionSnapshot
  ) async throws {
    guard
      try await transport.cancelScheduledSend(
        scheduleId: scheduleId,
        revision: revision,
        editGeneration: editGeneration,
        session: session
      )
    else { throw OutboxDeliveryError.attemptCannotBeChanged }
    try? await payloadSync.remove(scheduleId: scheduleId, revision: revision, session: session)
    try? await outboxService.cancelScheduledLocally(
      scheduleId: scheduleId,
      revision: revision,
      session: session
    )
  }

  // swiftlint:disable:next function_body_length function_parameter_count
  private func replace(
    _ editSession: ScheduledSendEditSession,
    message: OutgoingMessage,
    connection: MailboxConnection,
    dueAt: Date,
    originalTimeZoneIdentifier: String,
    sendsImmediately: Bool,
    session: ProductAccountSessionSnapshot,
    undoSendDelayNanoseconds: UInt64,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws -> ManagedScheduledSend {
    if !sendsImmediately {
      try validate(message: message, connection: connection, dueAt: dueAt)
    } else {
      try validateMessage(message, connection: connection)
    }
    let current = editSession.item.record
    let dueAtMilliseconds = Int64(dueAt.timeIntervalSince1970 * 1_000)
    let replacement = ScheduledSendRecord(
      connectionId: connection.id,
      createdAtMilliseconds: current.createdAtMilliseconds,
      deadlineAtMilliseconds: dueAtMilliseconds + 24 * 60 * 60 * 1_000,
      draftId: current.draftId,
      dueAtMilliseconds: dueAtMilliseconds,
      message: message,
      originatingDeviceId: current.originatingDeviceId,
      originalTimeZoneIdentifier: originalTimeZoneIdentifier,
      profileId: current.profileId,
      revision: current.revision + 1,
      scheduleId: current.scheduleId
    )
    let payload = try await payloadSync.save(replacement, session: session)
    let acknowledgement: ScheduledSendOperationalAcknowledgement
    do {
      if sendsImmediately {
        acknowledgement = try await transport.sendScheduledSendNow(
          replacement,
          payload: payload,
          expectedRevision: current.revision,
          editGeneration: editSession.lease.generation,
          session: session
        )
      } else {
        acknowledgement = try await transport.rescheduleScheduledSend(
          replacement,
          payload: payload,
          expectedRevision: current.revision,
          editGeneration: editSession.lease.generation,
          session: session
        )
      }
    } catch let replacementError {
      try? await payloadSync.remove(
        scheduleId: replacement.scheduleId,
        revision: replacement.revision,
        session: session
      )
      let status: ScheduledSendOperationalStatus?
      do {
        status = try await transport.scheduledSendStatus(
          scheduleId: current.scheduleId,
          session: session
        )
      } catch {
        throw replacementError
      }
      if status?.revision != current.revision || status?.state == .cancelled
        || status?.state == .completed
      {
        throw ScheduledSendManagementError.staleRevision
      }
      throw replacementError
    }
    guard acknowledgement.scheduleId == replacement.scheduleId.uuidString.lowercased(),
      acknowledgement.revision == replacement.revision,
      acknowledgement.dueAt == replacement.dueAtMilliseconds,
      acknowledgement.encryptedPayloadUpdatedAt == payload.updatedAt
    else {
      throw ScheduledSendAdmissionError.invalidAcknowledgement
    }
    try? await payloadSync.remove(
      scheduleId: current.scheduleId,
      revision: current.revision,
      session: session
    )
    _ = try await outboxService.replaceScheduled(
      replacement,
      connection: connection,
      session: session,
      undoSendDelayNanoseconds: sendsImmediately ? 0 : undoSendDelayNanoseconds,
      provider: provider,
      reconcile: reconcile
    )
    return ManagedScheduledSend(
      payload: payload,
      record: replacement,
      state: .scheduled
    )
  }

  private func validate(
    message: OutgoingMessage,
    connection: MailboxConnection,
    dueAt: Date
  ) throws {
    try validateMessage(message, connection: connection)
    let current = now()
    let maximum = current.addingTimeInterval(365 * 24 * 60 * 60)
    guard dueAt >= current.addingTimeInterval(60), dueAt <= maximum else {
      throw ScheduledSendAdmissionError.invalidDueDate
    }
  }

  private func validateMessage(
    _ message: OutgoingMessage,
    connection: MailboxConnection
  ) throws {
    guard connection.providerId.supportsProductOwnedScheduledSend,
      connection.authorizationState == .authorized,
      connection.capabilities.canSend
    else { throw ScheduledSendAdmissionError.providerUnavailable }
    let optionalRecipientHeaders = [message.ccRecipients, message.bccRecipients].compactMap { $0 }
    let hasValidOptionalRecipients = optionalRecipientHeaders.allSatisfy {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || RFCMailboxHeaderParser.mailboxes(in: $0) != nil
    }
    guard RFCMailboxHeaderParser.mailboxes(in: message.recipient) != nil,
      hasValidOptionalRecipients
    else { throw ScheduledSendAdmissionError.invalidRecipients }
    guard message.assets.allSatisfy(\.isComplete) else {
      throw ScheduledSendAdmissionError.incompleteAssets
    }
    let byteCount = MailDraftTransferBudget.estimatedByteCount(
      body: message.body,
      htmlBody: message.htmlBody ?? "",
      assets: message.assets
    )
    if let limit = MailDraftTransferBudget.knownLimit(for: connection.providerId), byteCount > limit
    {
      throw ScheduledSendAdmissionError.sizeLimitExceeded
    }
  }
}

extension ConvexClient: ScheduledSendOperationalTransport {}

// swiftlint:disable:next type_body_length
actor OutboxDeliveryService {
  static let shared = OutboxDeliveryService(scheduledSendTransport: ConvexClient())

  private static let scheduledSendNeedsAttentionMessage =
    "Scheduled Send did not begin within 24 hours. Send now, reschedule, edit, or cancel."

  private let failureDisposition: @Sendable (Error) -> OutboxDeliveryFailureDisposition
  private let handoffDelayNanoseconds: UInt64
  private let maximumAge: TimeInterval
  private let maximumAttempts: Int
  private let now: @Sendable () -> Date
  private var handoffClaimFailureCounts: [UUID: Int] = [:]
  private var reconciliationStateWriteFailureCounts: [UUID: Int] = [:]
  private var processingConnectionIds: Set<String> = []
  private let retryDelayNanoseconds: @Sendable (Int) -> UInt64
  private var inFlightRetryTaskTokens: [UUID: UUID] = [:]
  private var inFlightRetryTaskConnectionIds: [UUID: MailboxConnectionId] = [:]
  private var inFlightRetryTaskProductAccountIds: [UUID: String] = [:]
  private var inFlightRetryTasks: [UUID: Task<Void, Never>] = [:]
  private var providerDraftCleanupTaskAccountIds: [UUID: String] = [:]
  private var providerDraftCleanupTaskTokens: [UUID: UUID] = [:]
  private var providerDraftCleanupTasks: [UUID: Task<Void, Never>] = [:]
  private let providerDraftCleaner: OutboxProviderDraftCleaner
  private var retryTasks: [UUID: Task<Void, Never>] = [:]
  private var retryTaskConnectionIds: [UUID: MailboxConnectionId] = [:]
  private var retryTaskProductAccountIds: [UUID: String] = [:]
  private var retryTaskTokens: [UUID: UUID] = [:]
  private var retryWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private let sentCopyStore: StandardsMailSentCopyPersisting
  private let scheduledSendTransport: ScheduledSendOperationalTransport?
  private let store: OutboxDeliveryPersisting

  init(
    failureDisposition: @escaping @Sendable (Error) -> OutboxDeliveryFailureDisposition =
      defaultOutboxFailureDisposition,
    handoffDelayNanoseconds: UInt64 = defaultOutboxHandoffDelay,
    maximumAge: TimeInterval = 7 * 24 * 60 * 60,
    maximumAttempts: Int = 10,
    now: @escaping @Sendable () -> Date = { Date() },
    providerDraftCleaner: @escaping OutboxProviderDraftCleaner =
      defaultDraftCleaner,
    retryDelayNanoseconds: @escaping @Sendable (Int) -> UInt64 =
      defaultOutboxRetryDelay,
    scheduledSendTransport: ScheduledSendOperationalTransport? = nil,
    sentCopyStore: StandardsMailSentCopyPersisting = FileStandardsMailSentCopyStore(),
    store: OutboxDeliveryPersisting = FileOutboxDeliveryStore()
  ) {
    self.failureDisposition = failureDisposition
    self.handoffDelayNanoseconds = handoffDelayNanoseconds
    self.maximumAge = maximumAge
    self.maximumAttempts = maximumAttempts
    self.now = now
    self.providerDraftCleaner = providerDraftCleaner
    self.retryDelayNanoseconds = retryDelayNanoseconds
    self.scheduledSendTransport = scheduledSendTransport
    self.sentCopyStore = sentCopyStore
    self.store = store
  }

  @discardableResult
  func enqueue(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    undoSendDelayNanoseconds: UInt64? = nil,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws -> OutgoingDeliveryAttempt {
    try validate(connection: connection, session: session)
    let delay = undoSendDelayNanoseconds ?? handoffDelayNanoseconds
    let attempt = newAttempt(
      message: message,
      connection: connection,
      session: session,
      handoffDelayNanoseconds: delay
    )
    var attempts = try loadPruningTerminalAttempts(productAccountId: session.productAccountId)
    attempts.append(attempt)
    try store.save(attempts, productAccountId: session.productAccountId)
    if delay == 0 {
      let completedAttempt = try await process(
        connectionId: connection.id,
        productAccountId: session.productAccountId,
        provider: provider,
        reconcile: reconcile,
        returning: attempt.id
      )
      return
        try completedAttempt
        ?? requiredAttempt(attempt.id, productAccountId: session.productAccountId)
    } else {
      scheduleRetry(
        attempt,
        delay: delay,
        provider: provider,
        reconcile: reconcile
      )
      return attempt
    }
  }

  @discardableResult
  // swiftlint:disable:next function_body_length function_parameter_count
  func enqueueScheduled(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    scheduleId: UUID,
    revision: Int,
    dueAt: Date,
    deadline: Date,
    undoSendDelayNanoseconds: UInt64,
    claim: ScheduledSendClaim? = nil,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws -> OutgoingDeliveryAttempt {
    try validate(connection: connection, session: session)
    let currentMilliseconds = milliseconds(now())
    let dueAtMilliseconds = milliseconds(dueAt)
    let deadlineMilliseconds = milliseconds(deadline)
    guard revision > 0,
      currentMilliseconds <= deadlineMilliseconds,
      deadlineMilliseconds == dueAtMilliseconds + 24 * 60 * 60 * 1_000
    else {
      throw OutboxDeliveryError.invalidScheduledWindow
    }
    let handoffAtMilliseconds =
      dueAtMilliseconds
      + Int64(undoSendDelayNanoseconds / 1_000_000)
    let delayMilliseconds = max(0, handoffAtMilliseconds - currentMilliseconds)
    let attempt = newAttempt(
      message: message,
      connection: connection,
      session: session,
      handoffDelayNanoseconds: UInt64(delayMilliseconds) * 1_000_000,
      scheduledSendClaimGeneration: claim?.generation,
      scheduledSendClaimOwnerTrustedDeviceId: session.trustedDeviceId,
      scheduledSendDeadlineMilliseconds: deadlineMilliseconds,
      scheduledSendId: scheduleId,
      scheduledSendRevision: revision,
      scheduledSendAtMilliseconds: dueAtMilliseconds
    )
    var attempts = try loadPruningTerminalAttempts(productAccountId: session.productAccountId)
    if let existing = attempts.first(where: {
      $0.scheduledSendId == scheduleId && $0.scheduledSendRevision == revision
    }) {
      return existing
    }
    attempts.append(attempt)
    try store.save(attempts, productAccountId: session.productAccountId)
    if delayMilliseconds == 0 {
      let completedAttempt = try await process(
        connectionId: connection.id,
        productAccountId: session.productAccountId,
        provider: provider,
        reconcile: reconcile,
        returning: attempt.id
      )
      return
        try completedAttempt
        ?? requiredAttempt(attempt.id, productAccountId: session.productAccountId)
    }
    scheduleRetry(
      attempt,
      delay: UInt64(delayMilliseconds) * 1_000_000,
      provider: provider,
      reconcile: reconcile
    )
    return attempt
  }

  func items(session: ProductAccountSessionSnapshot) throws -> [OutgoingDeliveryAttempt] {
    try loadPruningTerminalAttempts(productAccountId: session.productAccountId)
      .sorted { $0.createdAtMilliseconds < $1.createdAtMilliseconds }
  }

  func actionableItems(
    session: ProductAccountSessionSnapshot
  ) throws -> [OutgoingDeliveryAttempt] {
    try items(session: session).filter(\.state.isActionable)
  }

  @discardableResult
  // swiftlint:disable:next function_parameter_count
  func replaceScheduled(
    _ record: ScheduledSendRecord,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    undoSendDelayNanoseconds: UInt64,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws -> OutgoingDeliveryAttempt {
    try validate(connection: connection, session: session)
    var attempts = try loadPruningTerminalAttempts(productAccountId: session.productAccountId)
    let replaced = attempts.filter {
      $0.scheduledSendId == record.scheduleId && $0.state.isActionable
    }
    guard replaced.allSatisfy({ $0.state != .handingOff && $0.state != .reconciling }) else {
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    for attempt in replaced {
      retryTasks.removeValue(forKey: attempt.id)?.cancel()
      inFlightRetryTasks.removeValue(forKey: attempt.id)?.cancel()
    }
    for index in attempts.indices where attempts[index].scheduledSendId == record.scheduleId {
      attempts[index].state = .superseded
      attempts[index].lastErrorDescription = nil
      attempts[index].nextRetryAtMilliseconds = nil
    }
    attempts = pruningTerminalAttempts(attempts)
    let handoffAtMilliseconds =
      record.dueAtMilliseconds + Int64(undoSendDelayNanoseconds / 1_000_000)
    let delayMilliseconds = max(0, handoffAtMilliseconds - milliseconds(now()))
    let replacement = newAttempt(
      message: record.message,
      connection: connection,
      session: session,
      handoffDelayNanoseconds: UInt64(delayMilliseconds) * 1_000_000,
      scheduledSendClaimOwnerTrustedDeviceId: session.trustedDeviceId,
      scheduledSendDeadlineMilliseconds: record.deadlineAtMilliseconds,
      scheduledSendId: record.scheduleId,
      scheduledSendRevision: record.revision,
      scheduledSendAtMilliseconds: record.dueAtMilliseconds
    )
    attempts.append(replacement)
    try store.save(attempts, productAccountId: session.productAccountId)
    for attempt in attempts
    where attempt.scheduledSendId == record.scheduleId && attempt.providerDraftRequiresCleanup {
      scheduleProviderDraftCleanup(attempt)
    }
    scheduleRetry(
      replacement,
      delay: UInt64(delayMilliseconds) * 1_000_000,
      provider: provider,
      reconcile: reconcile
    )
    return replacement
  }

  func cancelScheduledLocally(
    scheduleId: UUID,
    revision: Int,
    session: ProductAccountSessionSnapshot
  ) throws {
    var attempts = try loadPruningTerminalAttempts(productAccountId: session.productAccountId)
    let matchingIds = attempts.filter {
      $0.scheduledSendId == scheduleId && $0.scheduledSendRevision == revision
    }.map(\.id)
    for attemptId in matchingIds {
      retryTasks.removeValue(forKey: attemptId)?.cancel()
      inFlightRetryTasks.removeValue(forKey: attemptId)?.cancel()
    }
    for index in attempts.indices
    where attempts[index].scheduledSendId == scheduleId
      && attempts[index].scheduledSendRevision == revision
    {
      attempts[index].state = .cancelled
      attempts[index].lastErrorDescription = nil
      attempts[index].nextRetryAtMilliseconds = nil
    }
    let retainedAttempts = pruningTerminalAttempts(attempts)
    try store.save(retainedAttempts, productAccountId: session.productAccountId)
    for attempt in retainedAttempts
    where attempt.scheduledSendId == scheduleId
      && attempt.scheduledSendRevision == revision
      && attempt.providerDraftRequiresCleanup
    {
      scheduleProviderDraftCleanup(attempt)
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func resume(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws {
    var attempts = try loadPruningTerminalAttempts(productAccountId: session.productAccountId)
    var assignedScheduledSendOwner = false
    for index in attempts.indices
    where attempts[index].isScheduledSend
      && attempts[index].scheduledSendClaimOwnerTrustedDeviceId == nil
    {
      attempts[index].scheduledSendClaimOwnerTrustedDeviceId = session.trustedDeviceId
      assignedScheduledSendOwner = true
    }
    if assignedScheduledSendOwner {
      try store.save(attempts, productAccountId: session.productAccountId)
    }
    let connectionIds = Set(connections.map(\.id))
    var markedNeedsAttention = false
    for index in attempts.indices
    where connectionIds.contains(attempts[index].connectionId)
      && scheduledSendMissedDeadline(attempts[index])
    {
      attempts[index].state = .userActionRequired
      attempts[index].lastErrorDescription = Self.scheduledSendNeedsAttentionMessage
      attempts[index].nextRetryAtMilliseconds = nil
      markedNeedsAttention = true
    }
    if markedNeedsAttention {
      try store.save(attempts, productAccountId: session.productAccountId)
    }
    for attempt in attempts
    where connectionIds.contains(attempt.connectionId)
      && attempt.providerDraftRequiresCleanup
    {
      scheduleProviderDraftCleanup(attempt)
    }
    let interruptedHandoffs = attempts.filter {
      connectionIds.contains($0.connectionId)
        && $0.state == .handingOff
        && inFlightRetryTasks[$0.id] == nil
    }
    var recoveredInterruptedHandoff = false
    for index in attempts.indices
    where connectionIds.contains(attempts[index].connectionId)
      && attempts[index].state == .handingOff
      && inFlightRetryTasks[attempts[index].id] == nil
    {
      attempts[index].state = .reconciling
      attempts[index].lastErrorDescription =
        "Confirming delivery after the app stopped during provider handoff."
      attempts[index].nextRetryAtMilliseconds = nil
      recoveredInterruptedHandoff = true
    }
    if recoveredInterruptedHandoff {
      do {
        try store.save(attempts, productAccountId: session.productAccountId)
      } catch {
        for attempt in interruptedHandoffs {
          scheduleRetry(
            attempt,
            delay: retryDelayNanoseconds(attempt.attemptCount),
            provider: provider,
            reconcile: reconcile
          )
        }
        throw error
      }
    }

    var immediatelyProcessedConnectionIds = Set<String>()
    var immediateTasks: [Task<Void, Never>] = []
    for attempt in attempts
    where
      connectionIds.contains(attempt.connectionId)
      && (attempt.state == .pending || attempt.state == .retrying || attempt.state == .reconciling
        || attempt.state == .sentCopyPending)
    {
      guard inFlightRetryTasks[attempt.id] == nil else {
        continue
      }
      let fallbackScheduledAtMilliseconds =
        attempt.state == .pending
        ? handoffNotBeforeMilliseconds(for: attempt)
        : milliseconds(now())
      let scheduledAtMilliseconds =
        attempt.nextRetryAtMilliseconds ?? fallbackScheduledAtMilliseconds
      let remainingMilliseconds = max(
        0,
        scheduledAtMilliseconds - milliseconds(now())
      )
      if remainingMilliseconds == 0 {
        if immediatelyProcessedConnectionIds.insert(attempt.connectionId.rawValue).inserted {
          immediateTasks.append(
            scheduleRetry(
              attempt,
              delay: 0,
              provider: provider,
              reconcile: reconcile
            )
          )
        }
      } else {
        scheduleRetry(
          attempt,
          delay: UInt64(remainingMilliseconds) * 1_000_000,
          provider: provider,
          reconcile: reconcile
        )
      }
    }
    for task in immediateTasks {
      await task.value
    }
  }

  @discardableResult
  func cancel(
    _ attemptId: UUID,
    session: ProductAccountSessionSnapshot
  ) async throws -> OutgoingDeliveryAttempt {
    let currentAttempt = try requiredAttempt(
      attemptId,
      productAccountId: session.productAccountId
    )
    if currentAttempt.isScheduledSend,
      let scheduleId = currentAttempt.scheduledSendId,
      let revision = currentAttempt.scheduledSendRevision,
      let scheduledSendTransport
    {
      guard currentAttempt.state.canEditOrCancel,
        currentAttempt.reconciliationPausedForAuthorization != true,
        try await scheduledSendTransport.cancelScheduledSend(
          scheduleId: scheduleId,
          revision: revision,
          session: session
        )
      else { throw OutboxDeliveryError.attemptCannotBeChanged }
    }
    let cancelledAttempt = try replaceEligibleAttempt(
      attemptId,
      connection: nil,
      session: session,
      replacementState: .cancelled
    )
    await cleanProviderDraftOrScheduleRetry(
      attemptId,
      productAccountId: session.productAccountId
    )
    return cancelledAttempt
  }

  @discardableResult
  // swiftlint:disable:next function_body_length function_parameter_count
  func edit(
    _ attemptId: UUID,
    message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    undoSendDelayNanoseconds: UInt64? = nil,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws -> OutgoingDeliveryAttempt {
    try validate(connection: connection, session: session)
    var attempts = try loadPruningTerminalAttempts(productAccountId: session.productAccountId)
    guard var index = attempts.firstIndex(where: { $0.id == attemptId }),
      attempts[index].state.canEditOrCancel,
      !attempts[index].isScheduledSend,
      attempts[index].reconciliationPausedForAuthorization != true
    else {
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    if attempts[index].providerDraftId != nil {
      let priorAttempt = attempts[index]
      retryTasks.removeValue(forKey: attemptId)?.cancel()
      do {
        try await cleanProviderDraft(
          attemptId,
          productAccountId: session.productAccountId,
          schedulesRetry: false
        )
      } catch {
        if let retainedAttempt = try? requiredAttempt(
          attemptId,
          productAccountId: session.productAccountId
        ), retainedAttempt.state.canEditOrCancel {
          scheduleRetry(
            retainedAttempt,
            delay: remainingRetryDelay(for: priorAttempt),
            provider: provider,
            reconcile: reconcile
          )
        }
        throw error
      }
      attempts = try loadPruningTerminalAttempts(productAccountId: session.productAccountId)
      guard let refreshedIndex = attempts.firstIndex(where: { $0.id == attemptId }),
        attempts[refreshedIndex].state.canEditOrCancel,
        !attempts[refreshedIndex].isScheduledSend,
        attempts[refreshedIndex].reconciliationPausedForAuthorization != true
      else {
        throw OutboxDeliveryError.attemptCannotBeChanged
      }
      index = refreshedIndex
    }
    let delay = undoSendDelayNanoseconds ?? handoffDelayNanoseconds
    let replacement = newAttempt(
      message: message,
      connection: connection,
      session: session,
      handoffDelayNanoseconds: delay
    )
    attempts[index].state = .superseded
    attempts[index].nextRetryAtMilliseconds = nil
    attempts.append(replacement)
    try store.save(pruningTerminalAttempts(attempts), productAccountId: session.productAccountId)
    retryTasks.removeValue(forKey: attemptId)?.cancel()
    if delay == 0 {
      try await process(
        connectionId: connection.id,
        productAccountId: session.productAccountId,
        provider: provider,
        reconcile: reconcile
      )
    } else {
      scheduleRetry(replacement, delay: delay, provider: provider, reconcile: reconcile)
    }
    return replacement
  }

  @discardableResult
  func retry(
    _ attemptId: UUID,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws -> OutgoingDeliveryAttempt {
    let prior = try requiredAttempt(attemptId, productAccountId: session.productAccountId)
    guard prior.state == .failed || prior.state == .userActionRequired else {
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    if prior.state == .userActionRequired, prior.reconciliationPausedForAuthorization == true {
      try validate(connection: connection, session: session)
      var attempts = try loadPruningTerminalAttempts(productAccountId: session.productAccountId)
      guard let index = attempts.firstIndex(where: { $0.id == attemptId }) else {
        throw OutboxDeliveryError.attemptCannotBeChanged
      }
      attempts[index].state = .reconciling
      attempts[index].lastErrorDescription = nil
      attempts[index].nextRetryAtMilliseconds = nil
      attempts[index].reconciliationPausedForAuthorization = nil
      try store.save(attempts, productAccountId: session.productAccountId)
      scheduleRetry(attempts[index], delay: 0, provider: provider, reconcile: reconcile)
      return try requiredAttempt(attemptId, productAccountId: session.productAccountId)
    }
    return try await edit(
      attemptId,
      message: prior.message,
      connection: connection,
      session: session,
      provider: provider,
      reconcile: reconcile
    )
  }

  @discardableResult
  func resolveUnknownOutcome(
    _ attemptId: UUID,
    asDelivered: Bool,
    session: ProductAccountSessionSnapshot
  ) async throws -> OutgoingDeliveryAttempt {
    let attempt = try requiredAttempt(attemptId, productAccountId: session.productAccountId)
    guard attempt.state == .outcomeUnknown else {
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    try await completeScheduledSendClaim(
      attempt,
      state: asDelivered ? .completed : .needsAttention
    )
    guard
      let resolvedAttempt = try update(
        attemptId,
        productAccountId: session.productAccountId,
        state: asDelivered ? .sent : .failed,
        errorDescription: asDelivered ? nil : "You confirmed that this message was not delivered."
      )
    else {
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    if !asDelivered {
      await cleanProviderDraftOrScheduleRetry(
        attemptId,
        productAccountId: session.productAccountId
      )
    }
    return resolvedAttempt
  }

  func clear(session: ProductAccountSessionSnapshot) async throws {
    try await clear(productAccountId: session.productAccountId)
  }

  func clear(productAccountId: String) async throws {
    suspend(productAccountId: productAccountId)
    let attempts = try loadPruningTerminalAttempts(productAccountId: productAccountId)
    var firstCleanupError: Error?
    for attempt in attempts where attempt.providerDraftId != nil {
      do {
        try await cleanProviderDraft(
          attempt.id,
          productAccountId: productAccountId,
          schedulesRetry: false
        )
      } catch {
        firstCleanupError = firstCleanupError ?? error
      }
    }
    if let firstCleanupError {
      let retainedAttempts = try loadPruningTerminalAttempts(
        productAccountId: productAccountId
      ).filter { $0.providerDraftId != nil }
      try store.save(retainedAttempts, productAccountId: productAccountId)
      if retainedAttempts.contains(where: {
        ($0.providerDraftCleanupAttemptCount ?? 0) < maximumAttempts
      }) {
        throw firstCleanupError
      }
      throw OutboxProviderDraftCleanupExhaustedError(underlyingError: firstCleanupError)
    }
    try store.clear(productAccountId: productAccountId)
  }

  func suspend(productAccountId: String) {
    for attemptId in retryTasks.keys.filter({
      retryTaskProductAccountIds[$0] == productAccountId
    }) {
      retryTasks.removeValue(forKey: attemptId)?.cancel()
      retryTaskTokens.removeValue(forKey: attemptId)
      retryTaskConnectionIds.removeValue(forKey: attemptId)
      retryTaskProductAccountIds.removeValue(forKey: attemptId)
    }
    for attemptId in inFlightRetryTasks.keys.filter({
      inFlightRetryTaskProductAccountIds[$0] == productAccountId
    }) {
      inFlightRetryTasks.removeValue(forKey: attemptId)?.cancel()
      retryTaskTokens.removeValue(forKey: attemptId)
      inFlightRetryTaskTokens.removeValue(forKey: attemptId)
      inFlightRetryTaskConnectionIds.removeValue(forKey: attemptId)
      inFlightRetryTaskProductAccountIds.removeValue(forKey: attemptId)
    }
    for attemptId in providerDraftCleanupTasks.keys.filter({
      providerDraftCleanupTaskAccountIds[$0] == productAccountId
    }) {
      providerDraftCleanupTasks.removeValue(forKey: attemptId)?.cancel()
      providerDraftCleanupTaskTokens.removeValue(forKey: attemptId)
      providerDraftCleanupTaskAccountIds.removeValue(forKey: attemptId)
    }
  }

  // swiftlint:disable:next function_body_length
  func clear(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    guard connection.productAccountId.rawValue == session.productAccountId else {
      throw OutboxDeliveryError.productAccountMismatch
    }
    var attempts = try loadPruningTerminalAttempts(productAccountId: session.productAccountId)
    var firstCleanupError: Error?
    for attempt in attempts
    where attempt.connectionId == connection.id && attempt.providerDraftId != nil {
      do {
        try await cleanProviderDraft(
          attempt.id,
          productAccountId: session.productAccountId,
          schedulesRetry: true
        )
      } catch {
        firstCleanupError = firstCleanupError ?? error
      }
    }
    attempts = try loadPruningTerminalAttempts(productAccountId: session.productAccountId)
    let attemptIds = Set(
      attempts.filter { $0.connectionId == connection.id }.map(\.id)
    )
    if let firstCleanupError {
      let retainedAttempts = pruningTerminalAttempts(
        attempts.filter {
          $0.connectionId != connection.id || $0.providerDraftId != nil
        }
      )
      try store.save(retainedAttempts, productAccountId: session.productAccountId)
      cancelDeliveryRetryTasks(
        attemptIds: attemptIds,
        connectionId: connection.id,
        productAccountId: session.productAccountId
      )
      notifyRetryWaiters()
      if retainedAttempts.contains(where: {
        $0.connectionId == connection.id
          && ($0.providerDraftCleanupAttemptCount ?? 0) < maximumAttempts
      }) {
        throw firstCleanupError
      }
      throw OutboxProviderDraftCleanupExhaustedError(underlyingError: firstCleanupError)
    }
    try store.save(
      pruningTerminalAttempts(attempts.filter { $0.connectionId != connection.id }),
      productAccountId: session.productAccountId
    )
    cancelDeliveryRetryTasks(
      attemptIds: attemptIds,
      connectionId: connection.id,
      productAccountId: session.productAccountId
    )
    for attemptId in providerDraftCleanupTasks.keys.filter({
      attemptIds.contains($0)
    }) {
      providerDraftCleanupTasks.removeValue(forKey: attemptId)?.cancel()
      providerDraftCleanupTaskTokens.removeValue(forKey: attemptId)
      providerDraftCleanupTaskAccountIds.removeValue(forKey: attemptId)
    }
    notifyRetryWaiters()
  }

  private func cancelDeliveryRetryTasks(
    attemptIds: Set<UUID>,
    connectionId: MailboxConnectionId,
    productAccountId: String
  ) {
    for attemptId in retryTasks.keys.filter({
      attemptIds.contains($0)
        || (retryTaskConnectionIds[$0] == connectionId
          && retryTaskProductAccountIds[$0] == productAccountId)
    }) {
      retryTasks.removeValue(forKey: attemptId)?.cancel()
      retryTaskTokens.removeValue(forKey: attemptId)
      retryTaskConnectionIds.removeValue(forKey: attemptId)
      retryTaskProductAccountIds.removeValue(forKey: attemptId)
    }
    for attemptId in inFlightRetryTasks.keys.filter({
      attemptIds.contains($0)
        || (inFlightRetryTaskConnectionIds[$0] == connectionId
          && inFlightRetryTaskProductAccountIds[$0] == productAccountId)
    }) {
      inFlightRetryTasks.removeValue(forKey: attemptId)?.cancel()
      inFlightRetryTaskTokens.removeValue(forKey: attemptId)
      inFlightRetryTaskConnectionIds.removeValue(forKey: attemptId)
      inFlightRetryTaskProductAccountIds.removeValue(forKey: attemptId)
    }
  }

  func waitForScheduledRetries() async -> Bool {
    guard !Task.isCancelled,
      !retryTasks.isEmpty || !inFlightRetryTasks.isEmpty || !providerDraftCleanupTasks.isEmpty
    else { return false }
    let waiterId = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        retryWaiters[waiterId] = continuation
      }
    } onCancel: {
      Task { await self.cancelRetryWaiter(waiterId) }
    }
    return !Task.isCancelled
  }

  private func newAttempt(
    message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    handoffDelayNanoseconds: UInt64,
    scheduledSendClaimGeneration: Int? = nil,
    scheduledSendClaimOwnerTrustedDeviceId: String? = nil,
    scheduledSendDeadlineMilliseconds: Int64? = nil,
    scheduledSendId: UUID? = nil,
    scheduledSendRevision: Int? = nil,
    scheduledSendAtMilliseconds: Int64? = nil
  ) -> OutgoingDeliveryAttempt {
    let id = UUID()
    let createdAtMilliseconds = milliseconds(now())
    return OutgoingDeliveryAttempt(
      attemptCount: 0,
      connectionId: connection.id,
      createdAtMilliseconds: createdAtMilliseconds,
      firstAttemptAtMilliseconds: nil,
      id: id,
      idempotencyKey: "unwired-\(id.uuidString.lowercased())",
      lastErrorDescription: nil,
      message: message,
      nextRetryAtMilliseconds: nil,
      productAccountId: ProductAccountId(session.productAccountId),
      providerHandoffNotBeforeMilliseconds:
        createdAtMilliseconds + Int64(handoffDelayNanoseconds / 1_000_000),
      reconciliationAttemptCount: 0,
      scheduledSendClaimGeneration: scheduledSendClaimGeneration,
      scheduledSendClaimOwnerTrustedDeviceId: scheduledSendClaimOwnerTrustedDeviceId,
      scheduledSendDeadlineMilliseconds: scheduledSendDeadlineMilliseconds,
      scheduledSendId: scheduledSendId,
      scheduledSendRevision: scheduledSendRevision,
      scheduledSendAtMilliseconds: scheduledSendAtMilliseconds,
      state: .pending
    )
  }

  private func scheduledSendMissedDeadline(_ attempt: OutgoingDeliveryAttempt) -> Bool {
    guard attempt.state == .pending,
      attempt.firstAttemptAtMilliseconds == nil,
      let deadline = attempt.scheduledSendDeadlineMilliseconds
    else { return false }
    return milliseconds(now()) > deadline
  }

  private func replaceEligibleAttempt(
    _ attemptId: UUID,
    connection: MailboxConnection?,
    session: ProductAccountSessionSnapshot,
    replacementState: OutgoingDeliveryState
  ) throws -> OutgoingDeliveryAttempt {
    var attempts = try loadPruningTerminalAttempts(productAccountId: session.productAccountId)
    guard let index = attempts.firstIndex(where: { $0.id == attemptId }) else {
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    guard attempts[index].state.canEditOrCancel else {
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    guard attempts[index].reconciliationPausedForAuthorization != true else {
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    if let connection {
      try validate(connection: connection, session: session)
    }
    attempts[index].state = replacementState
    attempts[index].nextRetryAtMilliseconds = nil
    try store.save(pruningTerminalAttempts(attempts), productAccountId: session.productAccountId)
    retryTasks.removeValue(forKey: attemptId)?.cancel()
    return attempts[index]
  }

  @discardableResult
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func process(
    connectionId: MailboxConnectionId,
    productAccountId: String,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler,
    returning returnedAttemptId: UUID? = nil
  ) async throws -> OutgoingDeliveryAttempt? {
    var returnedAttempt: OutgoingDeliveryAttempt?
    guard processingConnectionIds.insert(connectionId.rawValue).inserted else {
      scheduleDueAttempts(
        connectionId: connectionId,
        productAccountId: productAccountId,
        provider: provider,
        reconcile: reconcile
      )
      return nil
    }
    defer { processingConnectionIds.remove(connectionId.rawValue) }

    while true {
      var attempts = try loadPruningTerminalAttempts(productAccountId: productAccountId)
      guard
        let index =
          (attempts.indices
            .filter {
              attempts[$0].connectionId == connectionId
                && ((attempts[$0].state == .pending
                  && handoffNotBeforeMilliseconds(for: attempts[$0]) <= milliseconds(now()))
                  || ((attempts[$0].state == .retrying
                    || attempts[$0].state == .reconciling
                    || attempts[$0].state == .sentCopyPending)
                    && (attempts[$0].nextRetryAtMilliseconds == nil
                      || attempts[$0].nextRetryAtMilliseconds! <= milliseconds(now()))))
            }
            .min(by: {
              attempts[$0].createdAtMilliseconds < attempts[$1].createdAtMilliseconds
            }))
      else { return returnedAttempt }

      let attemptId = attempts[index].id
      if scheduledSendMissedDeadline(attempts[index]) {
        attempts[index].state = .userActionRequired
        attempts[index].lastErrorDescription = Self.scheduledSendNeedsAttentionMessage
        attempts[index].nextRetryAtMilliseconds = nil
        try store.save(attempts, productAccountId: productAccountId)
        continue
      }
      let isSentCopyRecovery = attempts[index].state == .sentCopyPending
      if isSentCopyRecovery, sentCopyRepairLimitReached(attempts[index]) {
        do {
          try completeExhaustedSentCopyRepair(
            attempts[index],
            productAccountId: productAccountId
          )
        } catch {
          scheduleRetry(
            attempts[index],
            delay: retryDelayNanoseconds(attempts[index].reconciliationAttemptCount),
            provider: provider,
            reconcile: reconcile
          )
          throw error
        }
        continue
      }
      if attempts[index].state == .reconciling || isSentCopyRecovery {
        let reconcilingAttempt = attempts[index]
        do {
          switch try await reconcile(
            reconcilingAttempt.idempotencyKey,
            reconcilingAttempt.mailboxConnectionId
          ) {
          case .sent:
            try await completeScheduledSendClaim(reconcilingAttempt, state: .completed)
            let updatedAttempt = try update(
              attemptId,
              productAccountId: productAccountId,
              state: .sent,
              errorDescription: nil
            )
            if attemptId == returnedAttemptId {
              returnedAttempt = updatedAttempt
            }
          case .sentCopyPending:
            try handleSentCopyPending(
              attemptId,
              productAccountId: productAccountId,
              provider: provider,
              reconcile: reconcile
            )
            return returnedAttempt
          case .notSent:
            if (reconcilingAttempt.notSentConfirmationCount ?? 0) > 0 {
              try await handleTransientFailure(
                attemptId,
                error: OutboxDeliveryError.deliveryNotConfirmed,
                productAccountId: productAccountId,
                provider: provider,
                reconcile: reconcile
              )
            } else {
              try handleReconciliationFailure(
                attemptId,
                error: OutboxDeliveryError.deliveryNotConfirmed,
                productAccountId: productAccountId,
                provider: provider,
                reconcile: reconcile
              )
            }
            return returnedAttempt
          case .unknown:
            try update(
              attemptId,
              productAccountId: productAccountId,
              state: .outcomeUnknown,
              errorDescription: "Delivery outcome is unknown. Resolve it before sending again."
            )
          }
        } catch {
          let disposition = failureDisposition(error)
          if isSentCopyRecovery {
            if case .userActionRequired = disposition {
              // Preserve the authorization-paused reconciliation path below.
            } else {
              try handleSentCopyPending(
                attemptId,
                errorDescription: error.localizedDescription,
                productAccountId: productAccountId,
                provider: provider,
                reconcile: reconcile
              )
              return returnedAttempt
            }
          }
          if case .userActionRequired = disposition {
            attempts = try loadPruningTerminalAttempts(productAccountId: productAccountId)
            guard let refreshedIndex = attempts.firstIndex(where: { $0.id == attemptId }) else {
              return returnedAttempt
            }
            attempts[refreshedIndex].reconciliationPausedForAuthorization = true
            try store.save(attempts, productAccountId: productAccountId)
            try update(
              attemptId,
              productAccountId: productAccountId,
              state: .userActionRequired,
              errorDescription: error.localizedDescription
            )
          } else {
            try handleReconciliationFailure(
              attemptId,
              error: error,
              productAccountId: productAccountId,
              provider: provider,
              reconcile: reconcile
            )
          }
          return returnedAttempt
        }
        continue
      }
      if attempts[index].state == .retrying, retryLimitReached(attempts[index]) {
        attempts[index].state = .failed
        attempts[index].lastErrorDescription = "Automatic delivery retry limit reached."
        attempts[index].nextRetryAtMilliseconds = nil
        try store.save(attempts, productAccountId: productAccountId)
        await cleanProviderDraftOrScheduleRetry(
          attemptId,
          productAccountId: productAccountId
        )
        continue
      }
      let retryAttempt = attempts[index]
      let fencedAttempt: OutgoingDeliveryAttempt
      do {
        fencedAttempt = try await prepareScheduledSendForHandoff(
          retryAttempt,
          productAccountId: productAccountId
        )
      } catch {
        let claimFailureCount = (handoffClaimFailureCounts[attemptId] ?? 0) + 1
        handoffClaimFailureCounts[attemptId] = claimFailureCount
        guard claimFailureCount < maximumAttempts else { return returnedAttempt }
        scheduleRetry(
          retryAttempt,
          delay: retryDelayNanoseconds(claimFailureCount),
          provider: provider,
          reconcile: reconcile
        )
        return returnedAttempt
      }
      attempts = try loadPruningTerminalAttempts(productAccountId: productAccountId)
      guard let fencedIndex = attempts.firstIndex(where: { $0.id == fencedAttempt.id }),
        attempts[fencedIndex].state == .pending || attempts[fencedIndex].state == .retrying
      else { continue }
      attempts[fencedIndex].state = .handingOff
      attempts[fencedIndex].attemptCount += 1
      attempts[fencedIndex].firstAttemptAtMilliseconds =
        attempts[fencedIndex].firstAttemptAtMilliseconds ?? milliseconds(now())
      attempts[fencedIndex].nextRetryAtMilliseconds = nil
      attempts[fencedIndex].reconciliationAttemptCount = 0
      attempts[fencedIndex].notSentConfirmationCount = nil
      attempts[fencedIndex].reconciliationPausedForAuthorization = nil
      do {
        try store.save(attempts, productAccountId: productAccountId)
        handoffClaimFailureCounts[attemptId] = nil
      } catch {
        let claimFailureCount = (handoffClaimFailureCounts[attemptId] ?? 0) + 1
        handoffClaimFailureCounts[attemptId] = claimFailureCount
        guard claimFailureCount < maximumAttempts else { return returnedAttempt }
        scheduleRetry(
          retryAttempt,
          delay: retryDelayNanoseconds(claimFailureCount),
          provider: provider,
          reconcile: reconcile
        )
        return returnedAttempt
      }
      let claimedAttempt = attempts[fencedIndex]

      do {
        try await provider(
          claimedAttempt.message,
          claimedAttempt.idempotencyKey,
          claimedAttempt.mailboxConnectionId
        )
      } catch is CancellationError {
        try update(
          attemptId,
          productAccountId: productAccountId,
          state: .reconciling,
          errorDescription: "Confirming delivery after provider handoff was cancelled."
        )
        throw CancellationError()
      } catch {
        try? recordProviderDraftIdentity(
          from: error,
          attemptId: attemptId,
          productAccountId: productAccountId
        )
        switch failureDisposition(error) {
        case .ambiguous:
          let status: MailboxDeliveryStatus
          do {
            status = try await reconcile(
              claimedAttempt.idempotencyKey,
              claimedAttempt.mailboxConnectionId
            )
          } catch {
            try handleReconciliationFailure(
              attemptId,
              error: error,
              productAccountId: productAccountId,
              provider: provider,
              reconcile: reconcile
            )
            return returnedAttempt
          }
          switch status {
          case .sent:
            try await completeScheduledSendClaim(claimedAttempt, state: .completed)
            let updatedAttempt = try update(
              attemptId,
              productAccountId: productAccountId,
              state: .sent,
              errorDescription: nil
            )
            if attemptId == returnedAttemptId {
              returnedAttempt = updatedAttempt
            }
          case .sentCopyPending:
            try handleSentCopyPending(
              attemptId,
              productAccountId: productAccountId,
              provider: provider,
              reconcile: reconcile
            )
            return returnedAttempt
          case .notSent:
            try handleReconciliationFailure(
              attemptId,
              error: error,
              productAccountId: productAccountId,
              provider: provider,
              reconcile: reconcile
            )
            return returnedAttempt
          case .unknown:
            try update(
              attemptId,
              productAccountId: productAccountId,
              state: .outcomeUnknown,
              errorDescription: "Delivery outcome is unknown. Resolve it before sending again."
            )
          }
        case .permanent:
          try await completeScheduledSendClaim(claimedAttempt, state: .needsAttention)
          try update(
            attemptId,
            productAccountId: productAccountId,
            state: .failed,
            errorDescription: error.localizedDescription
          )
          await cleanProviderDraftOrScheduleRetry(
            attemptId,
            productAccountId: productAccountId
          )
        case .sentCopyPending:
          try handleSentCopyPending(
            attemptId,
            productAccountId: productAccountId,
            provider: provider,
            reconcile: reconcile
          )
          return returnedAttempt
        case .transient:
          try await handleTransientFailure(
            attemptId,
            error: error,
            productAccountId: productAccountId,
            provider: provider,
            reconcile: reconcile
          )
          return returnedAttempt
        case .userActionRequired:
          try await completeScheduledSendClaim(claimedAttempt, state: .needsAttention)
          try update(
            attemptId,
            productAccountId: productAccountId,
            state: .userActionRequired,
            errorDescription: error.localizedDescription
          )
        }
        continue
      }
      try await completeScheduledSendClaim(claimedAttempt, state: .completed)
      let updatedAttempt = try update(
        attemptId,
        productAccountId: productAccountId,
        state: .sent,
        errorDescription: nil
      )
      if attemptId == returnedAttemptId {
        returnedAttempt = updatedAttempt
      }
    }
  }

  // swiftlint:disable:next function_body_length
  private func prepareScheduledSendForHandoff(
    _ attempt: OutgoingDeliveryAttempt,
    productAccountId: String
  ) async throws -> OutgoingDeliveryAttempt {
    guard let scheduleId = attempt.scheduledSendId,
      let revision = attempt.scheduledSendRevision,
      let trustedDeviceId = attempt.scheduledSendClaimOwnerTrustedDeviceId,
      let scheduledSendTransport
    else { return attempt }

    let claimResult: ScheduledSendClaimResult
    if let claimGeneration = attempt.scheduledSendClaimGeneration {
      claimResult = try await scheduledSendTransport.revalidateScheduledSendClaim(
        scheduleId: scheduleId,
        revision: revision,
        claimGeneration: claimGeneration,
        trustedDeviceId: trustedDeviceId
      )
    } else {
      claimResult = try await scheduledSendTransport.claimScheduledSend(
        scheduleId: scheduleId,
        revision: revision,
        trustedDeviceId: trustedDeviceId
      )
    }
    guard case .claimed(let claim) = claimResult else {
      throw OutboxDeliveryError.scheduledSendClaimUnavailable
    }

    var attempts = try loadPruningTerminalAttempts(productAccountId: productAccountId)
    guard let index = attempts.firstIndex(where: { $0.id == attempt.id }),
      attempts[index].state == .pending || attempts[index].state == .retrying,
      attempts[index].scheduledSendId == scheduleId,
      attempts[index].scheduledSendRevision == revision
    else {
      if claim.phase == .preHandoff {
        _ = try? await scheduledSendTransport.releaseScheduledSendClaim(
          scheduleId: scheduleId,
          revision: revision,
          claimGeneration: claim.generation,
          trustedDeviceId: trustedDeviceId
        )
      }
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    attempts[index].scheduledSendClaimGeneration = claim.generation
    try store.save(attempts, productAccountId: productAccountId)

    if claim.phase == .preHandoff {
      guard
        try await scheduledSendTransport.advanceScheduledSendClaimToHandoff(
          scheduleId: scheduleId,
          revision: revision,
          claimGeneration: claim.generation,
          trustedDeviceId: trustedDeviceId
        )
      else { throw OutboxDeliveryError.scheduledSendHandoffRejected }
    }

    attempts = try loadPruningTerminalAttempts(productAccountId: productAccountId)
    guard let refreshed = attempts.first(where: { $0.id == attempt.id }),
      refreshed.state == .pending || refreshed.state == .retrying,
      refreshed.scheduledSendClaimGeneration == claim.generation
    else { throw OutboxDeliveryError.attemptCannotBeChanged }
    return refreshed
  }

  private func completeScheduledSendClaim(
    _ attempt: OutgoingDeliveryAttempt,
    state: ScheduledSendCompletionState
  ) async throws {
    guard let scheduleId = attempt.scheduledSendId,
      let revision = attempt.scheduledSendRevision,
      let claimGeneration = attempt.scheduledSendClaimGeneration,
      let trustedDeviceId = attempt.scheduledSendClaimOwnerTrustedDeviceId,
      let scheduledSendTransport
    else { return }
    guard
      try await scheduledSendTransport.completeScheduledSendClaim(
        scheduleId: scheduleId,
        revision: revision,
        claimGeneration: claimGeneration,
        state: state,
        trustedDeviceId: trustedDeviceId
      )
    else { throw OutboxDeliveryError.scheduledSendHandoffRejected }
  }

  private func handleTransientFailure(
    _ attemptId: UUID,
    error: Error,
    productAccountId: String,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws {
    var attempts = try loadPruningTerminalAttempts(productAccountId: productAccountId)
    guard let index = attempts.firstIndex(where: { $0.id == attemptId }) else { return }
    guard !retryLimitReached(attempts[index]) else {
      try await completeScheduledSendClaim(attempts[index], state: .needsAttention)
      attempts[index].state = .failed
      attempts[index].lastErrorDescription = error.localizedDescription
      attempts[index].nextRetryAtMilliseconds = nil
      try store.save(attempts, productAccountId: productAccountId)
      await cleanProviderDraftOrScheduleRetry(
        attemptId,
        productAccountId: productAccountId
      )
      return
    }
    attempts[index].state = .retrying
    attempts[index].lastErrorDescription = error.localizedDescription
    let delay = retryDelayNanoseconds(attempts[index].attemptCount)
    attempts[index].nextRetryAtMilliseconds =
      milliseconds(now()) + Int64(delay / 1_000_000)
    try store.save(attempts, productAccountId: productAccountId)
    notifyRetryWaiters()
    scheduleRetry(attempts[index], delay: delay, provider: provider, reconcile: reconcile)
  }

  private func handleSentCopyPending(
    _ attemptId: UUID,
    errorDescription: String? = nil,
    productAccountId: String,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) throws {
    var attempts = try loadPruningTerminalAttempts(productAccountId: productAccountId)
    guard let index = attempts.firstIndex(where: { $0.id == attemptId }) else { return }
    attempts[index].reconciliationAttemptCount += 1
    guard
      attempts[index].reconciliationAttemptCount < maximumAttempts,
      !retryAgeLimitReached(attempts[index])
    else {
      attempts[index].state = .sentCopyPending
      attempts[index].lastErrorDescription = nil
      attempts[index].nextRetryAtMilliseconds = nil
      try store.save(attempts, productAccountId: productAccountId)
      do {
        try completeExhaustedSentCopyRepair(
          attempts[index],
          productAccountId: productAccountId
        )
      } catch {
        scheduleRetry(
          attempts[index],
          delay: retryDelayNanoseconds(attempts[index].reconciliationAttemptCount),
          provider: provider,
          reconcile: reconcile
        )
        throw error
      }
      return
    }
    attempts[index].state = .sentCopyPending
    attempts[index].lastErrorDescription =
      errorDescription ?? "Message delivered. Saving its copy to the Sent mailbox."
    let delay = retryDelayNanoseconds(attempts[index].reconciliationAttemptCount)
    attempts[index].nextRetryAtMilliseconds = milliseconds(now()) + Int64(delay / 1_000_000)
    try store.save(attempts, productAccountId: productAccountId)
    notifyRetryWaiters()
    scheduleRetry(attempts[index], delay: delay, provider: provider, reconcile: reconcile)
  }

  private func sentCopyRepairLimitReached(_ attempt: OutgoingDeliveryAttempt) -> Bool {
    attempt.reconciliationAttemptCount >= maximumAttempts || retryAgeLimitReached(attempt)
  }

  private func completeExhaustedSentCopyRepair(
    _ attempt: OutgoingDeliveryAttempt,
    productAccountId: String
  ) throws {
    try removePendingSentCopy(for: attempt, productAccountId: productAccountId)
    try update(
      attempt.id,
      productAccountId: productAccountId,
      state: .sent,
      errorDescription: nil
    )
  }

  private func removePendingSentCopy(
    for attempt: OutgoingDeliveryAttempt,
    productAccountId: String
  ) throws {
    let copies = try sentCopyStore.load(
      productAccountId: productAccountId,
      connectionId: attempt.connectionId
    )
    let remainingCopies = copies.filter { $0.idempotencyKey != attempt.idempotencyKey }
    guard remainingCopies.count != copies.count else { return }
    try sentCopyStore.save(
      remainingCopies,
      productAccountId: productAccountId,
      connectionId: attempt.connectionId
    )
  }

  private func handleReconciliationFailure(
    _ attemptId: UUID,
    error: Error,
    productAccountId: String,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) throws {
    var attempts = try loadPruningTerminalAttempts(productAccountId: productAccountId)
    guard let index = attempts.firstIndex(where: { $0.id == attemptId }) else { return }
    attempts[index].reconciliationAttemptCount += 1
    if error as? OutboxDeliveryError == .deliveryNotConfirmed {
      attempts[index].notSentConfirmationCount =
        (attempts[index].notSentConfirmationCount ?? 0) + 1
    }
    guard
      attempts[index].reconciliationAttemptCount < maximumAttempts,
      !retryAgeLimitReached(attempts[index])
    else {
      attempts[index].state = .outcomeUnknown
      attempts[index].lastErrorDescription =
        "Delivery outcome could not be confirmed: \(error.localizedDescription)"
      attempts[index].nextRetryAtMilliseconds = nil
      try store.save(attempts, productAccountId: productAccountId)
      return
    }
    attempts[index].state = .reconciling
    attempts[index].lastErrorDescription =
      "Delivery confirmation is temporarily unavailable: \(error.localizedDescription)"
    let delay = retryDelayNanoseconds(attempts[index].reconciliationAttemptCount)
    attempts[index].nextRetryAtMilliseconds =
      milliseconds(now()) + Int64(delay / 1_000_000)
    try store.save(attempts, productAccountId: productAccountId)
    notifyRetryWaiters()
    scheduleRetry(attempts[index], delay: delay, provider: provider, reconcile: reconcile)
  }

  private func retryLimitReached(_ attempt: OutgoingDeliveryAttempt) -> Bool {
    attempt.attemptCount >= maximumAttempts || retryAgeLimitReached(attempt)
  }

  private func retryAgeLimitReached(_ attempt: OutgoingDeliveryAttempt) -> Bool {
    guard let firstAttemptAtMilliseconds = attempt.firstAttemptAtMilliseconds else {
      return false
    }
    let firstAttemptDate = Date(
      timeIntervalSince1970: TimeInterval(firstAttemptAtMilliseconds) / 1_000
    )
    return now().timeIntervalSince(firstAttemptDate) >= maximumAge
  }

  private func remainingRetryDelay(for attempt: OutgoingDeliveryAttempt) -> UInt64 {
    guard let nextRetryAtMilliseconds = attempt.nextRetryAtMilliseconds else { return 0 }
    return UInt64(max(0, nextRetryAtMilliseconds - milliseconds(now()))) * 1_000_000
  }

  @discardableResult
  private func scheduleRetry(
    _ attempt: OutgoingDeliveryAttempt,
    delay: UInt64,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) -> Task<Void, Never> {
    retryTasks.removeValue(forKey: attempt.id)?.cancel()
    let token = UUID()
    retryTaskTokens[attempt.id] = token
    retryTaskConnectionIds[attempt.id] = attempt.mailboxConnectionId
    retryTaskProductAccountIds[attempt.id] = attempt.productAccountId.rawValue
    let task = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: delay)
        guard let self else { return }
        guard await self.beginRetry(attempt.id, token: token) else { return }
        try await self.process(
          connectionId: attempt.mailboxConnectionId,
          productAccountId: attempt.productAccountId.rawValue,
          provider: provider,
          reconcile: reconcile
        )
        await self.finishRetry(attempt, token: token, provider: provider, reconcile: reconcile)
      } catch {
        await self?.finishRetry(attempt, token: token, provider: provider, reconcile: reconcile)
      }
    }
    retryTasks[attempt.id] = task
    return task
  }

  private func finishRetry(
    _ attempt: OutgoingDeliveryAttempt,
    token: UUID,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) {
    let attemptId = attempt.id
    if inFlightRetryTaskTokens[attemptId] == token {
      inFlightRetryTasks[attemptId] = nil
      inFlightRetryTaskTokens[attemptId] = nil
      inFlightRetryTaskConnectionIds[attemptId] = nil
      inFlightRetryTaskProductAccountIds[attemptId] = nil
    }
    guard retryTaskTokens[attemptId] == token else { return }
    retryTasks[attemptId] = nil
    retryTaskTokens[attemptId] = nil
    retryTaskConnectionIds[attemptId] = nil
    retryTaskProductAccountIds[attemptId] = nil
    guard recoverInterruptedHandoffs(productAccountId: attempt.productAccountId.rawValue)
    else {
      let failureCount = reconciliationStateWriteFailureCounts[attemptId, default: 0] + 1
      reconciliationStateWriteFailureCounts[attemptId] = failureCount
      guard failureCount < maximumAttempts, !retryAgeLimitReached(attempt) else {
        notifyRetryWaiters()
        return
      }
      scheduleRetry(
        attempt,
        delay: retryDelayNanoseconds(failureCount),
        provider: provider,
        reconcile: reconcile
      )
      return
    }
    reconciliationStateWriteFailureCounts[attemptId] = nil
    notifyRetryWaiters()
    scheduleDueAttempts(
      connectionId: attempt.mailboxConnectionId,
      productAccountId: attempt.productAccountId.rawValue,
      provider: provider,
      reconcile: reconcile
    )
  }

  private func recoverInterruptedHandoffs(productAccountId: String) -> Bool {
    let attempts: [OutgoingDeliveryAttempt]
    do {
      attempts = try loadPruningTerminalAttempts(productAccountId: productAccountId)
    } catch {
      return false
    }
    guard attempts.contains(where: { $0.state == .handingOff }) else { return true }
    var recoveredAttempts = attempts
    for index in recoveredAttempts.indices where recoveredAttempts[index].state == .handingOff {
      recoveredAttempts[index].state = .reconciling
      recoveredAttempts[index].lastErrorDescription =
        "Confirming delivery after provider handoff persistence failed."
      recoveredAttempts[index].nextRetryAtMilliseconds = nil
    }
    do {
      try store.save(recoveredAttempts, productAccountId: productAccountId)
      return true
    } catch {
      return false
    }
  }

  private func scheduleDueAttempts(
    connectionId: MailboxConnectionId,
    productAccountId: String,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) {
    guard let attempts = try? loadPruningTerminalAttempts(productAccountId: productAccountId) else {
      return
    }
    let currentMilliseconds = milliseconds(now())
    for attempt in attempts where attempt.connectionId == connectionId {
      let isDue =
        (attempt.state == .pending
          && handoffNotBeforeMilliseconds(for: attempt) <= currentMilliseconds)
        || ((attempt.state == .retrying || attempt.state == .reconciling
          || attempt.state == .sentCopyPending)
          && (attempt.nextRetryAtMilliseconds == nil
            || attempt.nextRetryAtMilliseconds! <= currentMilliseconds))
      guard
        isDue,
        handoffClaimFailureCounts[attempt.id, default: 0] < maximumAttempts,
        inFlightRetryTasks[attempt.id] == nil,
        retryTasks[attempt.id] == nil
      else {
        continue
      }
      scheduleRetry(
        attempt,
        delay: retryDelayNanoseconds(
          max(
            attempt.reconciliationAttemptCount,
            reconciliationStateWriteFailureCounts[attempt.id, default: 0]
          )
        ),
        provider: provider,
        reconcile: reconcile
      )
    }
  }

  private func handoffNotBeforeMilliseconds(for attempt: OutgoingDeliveryAttempt) -> Int64 {
    attempt.providerHandoffNotBeforeMilliseconds
      ?? attempt.createdAtMilliseconds + Int64(handoffDelayNanoseconds / 1_000_000)
  }

  private func beginRetry(_ attemptId: UUID, token: UUID) -> Bool {
    guard retryTaskTokens[attemptId] == token,
      let task = retryTasks.removeValue(forKey: attemptId)
    else { return false }
    inFlightRetryTasks[attemptId] = task
    inFlightRetryTaskTokens[attemptId] = token
    inFlightRetryTaskConnectionIds[attemptId] = retryTaskConnectionIds[attemptId]
    inFlightRetryTaskProductAccountIds[attemptId] = retryTaskProductAccountIds[attemptId]
    retryTaskConnectionIds[attemptId] = nil
    retryTaskProductAccountIds[attemptId] = nil
    return true
  }

  private func notifyRetryWaiters() {
    let waiters = retryWaiters.values
    retryWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func cancelRetryWaiter(_ waiterId: UUID) {
    retryWaiters.removeValue(forKey: waiterId)?.resume()
  }

  private func recordProviderDraftIdentity(
    from error: Error,
    attemptId: UUID,
    productAccountId: String
  ) throws {
    guard let rawProviderDraftId = (error as? MicrosoftGraphSendError)?.providerDraftId else {
      return
    }
    let providerDraftId = rawProviderDraftId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !providerDraftId.isEmpty else { return }
    var attempts = try loadPruningTerminalAttempts(productAccountId: productAccountId)
    guard let index = attempts.firstIndex(where: { $0.id == attemptId }) else { return }
    attempts[index].providerDraftId = providerDraftId
    attempts[index].providerDraftCleanupAttemptCount = nil
    attempts[index].providerDraftCleanupErrorDescription = nil
    try store.save(attempts, productAccountId: productAccountId)
  }

  private func cleanProviderDraftOrScheduleRetry(
    _ attemptId: UUID,
    productAccountId: String
  ) async {
    try? await cleanProviderDraft(
      attemptId,
      productAccountId: productAccountId,
      schedulesRetry: true
    )
  }

  private func cleanProviderDraft(
    _ attemptId: UUID,
    productAccountId: String,
    schedulesRetry: Bool
  ) async throws {
    let attempt = try requiredAttempt(attemptId, productAccountId: productAccountId)
    guard let providerDraftId = attempt.providerDraftId else { return }
    do {
      try await providerDraftCleaner(
        providerDraftId,
        attempt.connectionId,
        productAccountId
      )
    } catch {
      var attempts = try loadPruningTerminalAttempts(productAccountId: productAccountId)
      guard
        let index = attempts.firstIndex(where: { $0.id == attemptId }),
        attempts[index].providerDraftId == providerDraftId
      else { throw error }
      attempts[index].providerDraftCleanupAttemptCount =
        (attempts[index].providerDraftCleanupAttemptCount ?? 0) + 1
      attempts[index].providerDraftCleanupErrorDescription = error.localizedDescription
      let failedAttempt = attempts[index]
      try store.save(attempts, productAccountId: productAccountId)
      if schedulesRetry, (failedAttempt.providerDraftCleanupAttemptCount ?? 0) < maximumAttempts {
        scheduleProviderDraftCleanup(failedAttempt)
      }
      throw error
    }
    var attempts = try loadPruningTerminalAttempts(productAccountId: productAccountId)
    guard
      let index = attempts.firstIndex(where: { $0.id == attemptId }),
      attempts[index].providerDraftId == providerDraftId
    else { return }
    attempts[index].providerDraftId = nil
    attempts[index].providerDraftCleanupAttemptCount = nil
    attempts[index].providerDraftCleanupErrorDescription = nil
    try store.save(pruningTerminalAttempts(attempts), productAccountId: productAccountId)
    providerDraftCleanupTasks.removeValue(forKey: attemptId)?.cancel()
    providerDraftCleanupTaskTokens.removeValue(forKey: attemptId)
    providerDraftCleanupTaskAccountIds.removeValue(forKey: attemptId)
    notifyRetryWaiters()
  }

  private func scheduleProviderDraftCleanup(_ attempt: OutgoingDeliveryAttempt) {
    providerDraftCleanupTasks.removeValue(forKey: attempt.id)?.cancel()
    let token = UUID()
    providerDraftCleanupTaskTokens[attempt.id] = token
    providerDraftCleanupTaskAccountIds[attempt.id] = attempt.productAccountId.rawValue
    let delay = retryDelayNanoseconds(attempt.providerDraftCleanupAttemptCount ?? 1)
    providerDraftCleanupTasks[attempt.id] = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: delay)
        guard let self else { return }
        try await self.performScheduledProviderDraftCleanup(
          attempt.id,
          productAccountId: attempt.productAccountId.rawValue,
          token: token
        )
      } catch {}
      await self?.finishProviderDraftCleanup(attempt.id, token: token)
    }
  }

  private func performScheduledProviderDraftCleanup(
    _ attemptId: UUID,
    productAccountId: String,
    token: UUID
  ) async throws {
    guard providerDraftCleanupTaskTokens[attemptId] == token else { return }
    try await cleanProviderDraft(
      attemptId,
      productAccountId: productAccountId,
      schedulesRetry: true
    )
  }

  private func finishProviderDraftCleanup(_ attemptId: UUID, token: UUID) {
    guard providerDraftCleanupTaskTokens[attemptId] == token else { return }
    providerDraftCleanupTasks.removeValue(forKey: attemptId)
    providerDraftCleanupTaskTokens.removeValue(forKey: attemptId)
    providerDraftCleanupTaskAccountIds.removeValue(forKey: attemptId)
    notifyRetryWaiters()
  }

  private func requiredAttempt(
    _ attemptId: UUID,
    productAccountId: String
  ) throws -> OutgoingDeliveryAttempt {
    guard
      let attempt = try loadPruningTerminalAttempts(productAccountId: productAccountId)
        .first(where: { $0.id == attemptId })
    else {
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    return attempt
  }

  @discardableResult
  private func update(
    _ attemptId: UUID,
    productAccountId: String,
    state: OutgoingDeliveryState,
    errorDescription: String?
  ) throws -> OutgoingDeliveryAttempt? {
    var attempts = try loadPruningTerminalAttempts(productAccountId: productAccountId)
    guard let index = attempts.firstIndex(where: { $0.id == attemptId }) else { return nil }
    attempts[index].state = state
    attempts[index].lastErrorDescription = errorDescription
    attempts[index].nextRetryAtMilliseconds = nil
    if state == .sent {
      attempts[index].providerDraftId = nil
      attempts[index].providerDraftCleanupAttemptCount = nil
      attempts[index].providerDraftCleanupErrorDescription = nil
    }
    let updatedAttempt = attempts[index]
    try store.save(pruningTerminalAttempts(attempts), productAccountId: productAccountId)
    return updatedAttempt
  }

  private func pruningTerminalAttempts(
    _ attempts: [OutgoingDeliveryAttempt]
  ) -> [OutgoingDeliveryAttempt] {
    attempts.filter { $0.state.isActionable || $0.providerDraftId != nil }
  }

  private func loadPruningTerminalAttempts(
    productAccountId: String
  ) throws -> [OutgoingDeliveryAttempt] {
    let attempts = try store.load(productAccountId: productAccountId)
    let prunedAttempts = pruningTerminalAttempts(attempts)
    if prunedAttempts.count != attempts.count {
      try store.save(prunedAttempts, productAccountId: productAccountId)
    }
    return prunedAttempts
  }

  private func validate(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    guard connection.productAccountId.rawValue == session.productAccountId else {
      throw OutboxDeliveryError.productAccountMismatch
    }
    guard connection.authorizationState == .authorized, connection.capabilities.canSend else {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
  }

  private func milliseconds(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1_000)
  }
}

extension OutboxDeliveryService: OutboxDeliveryClearing {}
