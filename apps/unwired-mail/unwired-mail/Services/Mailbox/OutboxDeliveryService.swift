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
  var state: OutgoingDeliveryState

  var mailboxConnectionId: MailboxConnectionId {
    connectionId
  }

  var canEditOrCancel: Bool {
    state.canEditOrCancel && reconciliationPausedForAuthorization != true
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

// swiftlint:disable:next type_body_length
actor OutboxDeliveryService {
  static let shared = OutboxDeliveryService()

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
    store: OutboxDeliveryPersisting = FileOutboxDeliveryStore()
  ) {
    self.failureDisposition = failureDisposition
    self.handoffDelayNanoseconds = handoffDelayNanoseconds
    self.maximumAge = maximumAge
    self.maximumAttempts = maximumAttempts
    self.now = now
    self.providerDraftCleaner = providerDraftCleaner
    self.retryDelayNanoseconds = retryDelayNanoseconds
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

  func items(session: ProductAccountSessionSnapshot) throws -> [OutgoingDeliveryAttempt] {
    try loadPruningTerminalAttempts(productAccountId: session.productAccountId)
      .sorted { $0.createdAtMilliseconds < $1.createdAtMilliseconds }
  }

  func actionableItems(
    session: ProductAccountSessionSnapshot
  ) throws -> [OutgoingDeliveryAttempt] {
    try items(session: session).filter(\.state.isActionable)
  }

  // swiftlint:disable:next function_body_length
  func resume(
    connections _: [MailboxConnection],
    session: ProductAccountSessionSnapshot,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws {
    var attempts = try loadPruningTerminalAttempts(productAccountId: session.productAccountId)
    for attempt in attempts where attempt.providerDraftRequiresCleanup {
      scheduleProviderDraftCleanup(attempt)
    }
    let interruptedHandoffs = attempts.filter {
      $0.state == .handingOff && inFlightRetryTasks[$0.id] == nil
    }
    var recoveredInterruptedHandoff = false
    for index in attempts.indices
    where attempts[index].state == .handingOff && inFlightRetryTasks[attempts[index].id] == nil {
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
      attempt.state == .pending || attempt.state == .retrying || attempt.state == .reconciling
      || attempt.state == .sentCopyPending
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
    handoffDelayNanoseconds: UInt64
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
      state: .pending
    )
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
      let isSentCopyRecovery = attempts[index].state == .sentCopyPending
      if attempts[index].state == .reconciling || isSentCopyRecovery {
        let reconcilingAttempt = attempts[index]
        do {
          switch try await reconcile(
            reconcilingAttempt.idempotencyKey,
            reconcilingAttempt.mailboxConnectionId
          ) {
          case .sent:
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
      attempts[index].state = .handingOff
      attempts[index].attemptCount += 1
      attempts[index].firstAttemptAtMilliseconds =
        attempts[index].firstAttemptAtMilliseconds ?? milliseconds(now())
      attempts[index].nextRetryAtMilliseconds = nil
      attempts[index].reconciliationAttemptCount = 0
      attempts[index].notSentConfirmationCount = nil
      attempts[index].reconciliationPausedForAuthorization = nil
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
      let claimedAttempt = attempts[index]

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
          try update(
            attemptId,
            productAccountId: productAccountId,
            state: .userActionRequired,
            errorDescription: error.localizedDescription
          )
        }
        continue
      }
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
    attempts[index].state = .sentCopyPending
    attempts[index].lastErrorDescription =
      errorDescription ?? "Message delivered. Saving its copy to the Sent mailbox."
    let delay = retryDelayNanoseconds(attempts[index].reconciliationAttemptCount)
    attempts[index].nextRetryAtMilliseconds = milliseconds(now()) + Int64(delay / 1_000_000)
    try store.save(attempts, productAccountId: productAccountId)
    notifyRetryWaiters()
    scheduleRetry(attempts[index], delay: delay, provider: provider, reconcile: reconcile)
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
