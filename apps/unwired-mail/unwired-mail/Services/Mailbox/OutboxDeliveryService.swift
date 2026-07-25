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
  case superseded
  case userActionRequired

  var isActionable: Bool {
    switch self {
    case .failed, .handingOff, .outcomeUnknown, .pending, .reconciling, .retrying,
      .userActionRequired:
      true
    case .cancelled, .sent, .superseded:
      false
    }
  }

  var canEditOrCancel: Bool {
    switch self {
    case .failed, .pending, .retrying, .userActionRequired:
      true
    case .cancelled, .handingOff, .outcomeUnknown, .reconciling, .sent, .superseded:
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
  let productAccountId: ProductAccountId
  var reconciliationAttemptCount: Int
  var state: OutgoingDeliveryState

  var mailboxConnectionId: MailboxConnectionId {
    connectionId
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

enum MailboxDeliveryStatus: Equatable, Sendable {
  case notSent
  case sent
  case unknown
}

enum OutboxDeliveryFailureDisposition: Sendable {
  case ambiguous
  case permanent
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

private let defaultOutboxFailureDisposition: @Sendable (Error) -> OutboxDeliveryFailureDisposition =
  { error in
    if let urlError = error as? URLError {
      switch urlError.code {
      case .dataNotAllowed, .internationalRoamingOff, .notConnectedToInternet:
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
    if case .rateLimitedResponseStatus = error as? GmailProviderMailActionError {
      return .ambiguous
    }
    if case .responseStatus(let status) = error as? GmailProviderMailActionError {
      if status == 401 || status == 403 {
        return .userActionRequired
      }
      if status == 408 || status == 409 || status == 425 || status == 429 || status >= 500 {
        return .ambiguous
      }
    }
    return .permanent
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
  private var processingConnectionIds: Set<String> = []
  private let retryDelayNanoseconds: @Sendable (Int) -> UInt64
  private var retryTasks: [UUID: Task<Void, Never>] = [:]
  private var retryTaskTokens: [UUID: UUID] = [:]
  private let store: OutboxDeliveryPersisting

  init(
    failureDisposition: @escaping @Sendable (Error) -> OutboxDeliveryFailureDisposition =
      defaultOutboxFailureDisposition,
    handoffDelayNanoseconds: UInt64 = defaultOutboxHandoffDelay,
    maximumAge: TimeInterval = 7 * 24 * 60 * 60,
    maximumAttempts: Int = 10,
    now: @escaping @Sendable () -> Date = { Date() },
    retryDelayNanoseconds: @escaping @Sendable (Int) -> UInt64 =
      defaultOutboxRetryDelay,
    store: OutboxDeliveryPersisting = FileOutboxDeliveryStore()
  ) {
    self.failureDisposition = failureDisposition
    self.handoffDelayNanoseconds = handoffDelayNanoseconds
    self.maximumAge = maximumAge
    self.maximumAttempts = maximumAttempts
    self.now = now
    self.retryDelayNanoseconds = retryDelayNanoseconds
    self.store = store
  }

  @discardableResult
  func enqueue(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws -> OutgoingDeliveryAttempt {
    try validate(connection: connection, session: session)
    let attempt = newAttempt(
      message: message,
      connection: connection,
      session: session
    )
    var attempts = try store.load(productAccountId: session.productAccountId)
    attempts.append(attempt)
    try store.save(attempts, productAccountId: session.productAccountId)
    if handoffDelayNanoseconds == 0 {
      try await process(
        connectionId: connection.id,
        productAccountId: session.productAccountId,
        provider: provider,
        reconcile: reconcile
      )
    } else {
      scheduleRetry(
        attempt,
        delay: handoffDelayNanoseconds,
        provider: provider,
        reconcile: reconcile
      )
    }
    return try requiredAttempt(attempt.id, productAccountId: session.productAccountId)
  }

  func items(session: ProductAccountSessionSnapshot) throws -> [OutgoingDeliveryAttempt] {
    try store.load(productAccountId: session.productAccountId)
      .sorted { $0.createdAtMilliseconds < $1.createdAtMilliseconds }
  }

  func actionableItems(
    session: ProductAccountSessionSnapshot
  ) throws -> [OutgoingDeliveryAttempt] {
    try items(session: session).filter(\.state.isActionable)
  }

  func resume(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws {
    var attempts = try store.load(productAccountId: session.productAccountId)
    var recoveredInterruptedHandoff = false
    for index in attempts.indices where attempts[index].state == .handingOff {
      attempts[index].state = .reconciling
      attempts[index].lastErrorDescription =
        "Confirming delivery after the app stopped during provider handoff."
      attempts[index].nextRetryAtMilliseconds = nil
      recoveredInterruptedHandoff = true
    }
    if recoveredInterruptedHandoff {
      try store.save(attempts, productAccountId: session.productAccountId)
    }

    for attempt in attempts
    where
      attempt.state == .pending || attempt.state == .retrying || attempt.state == .reconciling
    {
      let fallbackScheduledAtMilliseconds =
        attempt.state == .pending
        ? attempt.createdAtMilliseconds + Int64(handoffDelayNanoseconds / 1_000_000)
        : milliseconds(now())
      let scheduledAtMilliseconds =
        attempt.nextRetryAtMilliseconds ?? fallbackScheduledAtMilliseconds
      let remainingMilliseconds = max(
        0,
        scheduledAtMilliseconds - milliseconds(now())
      )
      if remainingMilliseconds > 0 {
        scheduleRetry(
          attempt,
          delay: UInt64(remainingMilliseconds) * 1_000_000,
          provider: provider,
          reconcile: reconcile
        )
      }
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for connection in connections where connection.authorizationState == .authorized {
        group.addTask {
          try await self.process(
            connectionId: connection.id,
            productAccountId: session.productAccountId,
            provider: provider,
            reconcile: reconcile
          )
        }
      }
      try await group.waitForAll()
    }
  }

  @discardableResult
  func cancel(
    _ attemptId: UUID,
    session: ProductAccountSessionSnapshot
  ) throws -> OutgoingDeliveryAttempt {
    try replaceEligibleAttempt(
      attemptId,
      connection: nil,
      session: session,
      replacementState: .cancelled
    )
  }

  @discardableResult
  // swiftlint:disable:next function_parameter_count
  func edit(
    _ attemptId: UUID,
    message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws -> OutgoingDeliveryAttempt {
    try validate(connection: connection, session: session)
    var attempts = try store.load(productAccountId: session.productAccountId)
    guard let index = attempts.firstIndex(where: { $0.id == attemptId }),
      attempts[index].state.canEditOrCancel
    else {
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    retryTasks.removeValue(forKey: attemptId)?.cancel()
    let replacement = newAttempt(
      message: message,
      connection: connection,
      session: session
    )
    attempts[index].state = .superseded
    attempts[index].nextRetryAtMilliseconds = nil
    attempts.append(replacement)
    try store.save(attempts, productAccountId: session.productAccountId)
    let delay = handoffDelayNanoseconds
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
    return try requiredAttempt(replacement.id, productAccountId: session.productAccountId)
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
  ) throws -> OutgoingDeliveryAttempt {
    let attempt = try requiredAttempt(attemptId, productAccountId: session.productAccountId)
    guard attempt.state == .outcomeUnknown else {
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    try update(
      attemptId,
      productAccountId: session.productAccountId,
      state: asDelivered ? .sent : .failed,
      errorDescription: asDelivered ? nil : "You confirmed that this message was not delivered."
    )
    return try requiredAttempt(attemptId, productAccountId: session.productAccountId)
  }

  func clear(session: ProductAccountSessionSnapshot) throws {
    for task in retryTasks.values {
      task.cancel()
    }
    retryTasks.removeAll()
    retryTaskTokens.removeAll()
    try store.clear(productAccountId: session.productAccountId)
  }

  func waitForScheduledRetries() async -> Bool {
    guard !Task.isCancelled, !retryTasks.isEmpty else { return false }
    await withTaskGroup(of: Void.self) { group in
      for task in retryTasks.values {
        group.addTask { await task.value }
      }
      await group.next()
      group.cancelAll()
    }
    return true
  }

  private func newAttempt(
    message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) -> OutgoingDeliveryAttempt {
    let id = UUID()
    return OutgoingDeliveryAttempt(
      attemptCount: 0,
      connectionId: connection.id,
      createdAtMilliseconds: milliseconds(now()),
      firstAttemptAtMilliseconds: nil,
      id: id,
      idempotencyKey: "unwired-\(id.uuidString.lowercased())",
      lastErrorDescription: nil,
      message: message,
      nextRetryAtMilliseconds: nil,
      productAccountId: ProductAccountId(session.productAccountId),
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
    var attempts = try store.load(productAccountId: session.productAccountId)
    guard let index = attempts.firstIndex(where: { $0.id == attemptId }) else {
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    guard attempts[index].state.canEditOrCancel else {
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    if let connection {
      try validate(connection: connection, session: session)
    }
    retryTasks.removeValue(forKey: attemptId)?.cancel()
    attempts[index].state = replacementState
    attempts[index].nextRetryAtMilliseconds = nil
    try store.save(attempts, productAccountId: session.productAccountId)
    return attempts[index]
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func process(
    connectionId: MailboxConnectionId,
    productAccountId: String,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) async throws {
    guard processingConnectionIds.insert(connectionId.rawValue).inserted else {
      let currentMilliseconds = milliseconds(now())
      let dueAttempts = try store.load(productAccountId: productAccountId).filter {
        guard $0.connectionId == connectionId else { return false }
        if $0.state == .pending {
          return $0.createdAtMilliseconds
            + Int64(handoffDelayNanoseconds / 1_000_000) <= currentMilliseconds
        }
        return ($0.state == .retrying || $0.state == .reconciling)
          && ($0.nextRetryAtMilliseconds == nil
            || $0.nextRetryAtMilliseconds! <= currentMilliseconds)
      }
      for attempt in dueAttempts {
        scheduleRetry(attempt, delay: 100_000_000, provider: provider, reconcile: reconcile)
      }
      return
    }
    defer { processingConnectionIds.remove(connectionId.rawValue) }

    while true {
      var attempts = try store.load(productAccountId: productAccountId)
      guard
        let index =
          (attempts.indices
            .filter {
              attempts[$0].connectionId == connectionId
                && ((attempts[$0].state == .pending
                  && attempts[$0].createdAtMilliseconds
                    + Int64(handoffDelayNanoseconds / 1_000_000) <= milliseconds(now()))
                  || ((attempts[$0].state == .retrying
                    || attempts[$0].state == .reconciling)
                    && (attempts[$0].nextRetryAtMilliseconds == nil
                      || attempts[$0].nextRetryAtMilliseconds! <= milliseconds(now()))))
            }
            .min(by: {
              attempts[$0].createdAtMilliseconds < attempts[$1].createdAtMilliseconds
            }))
      else { return }

      let attemptId = attempts[index].id
      retryTasks.removeValue(forKey: attemptId)?.cancel()
      if attempts[index].state == .reconciling {
        let reconcilingAttempt = attempts[index]
        do {
          switch try await reconcile(
            reconcilingAttempt.idempotencyKey,
            reconcilingAttempt.mailboxConnectionId
          ) {
          case .sent:
            try update(
              attemptId,
              productAccountId: productAccountId,
              state: .sent,
              errorDescription: nil
            )
          case .notSent:
            if reconcilingAttempt.reconciliationAttemptCount > 0 {
              try handleTransientFailure(
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
            return
          case .unknown:
            try update(
              attemptId,
              productAccountId: productAccountId,
              state: .outcomeUnknown,
              errorDescription: "Delivery outcome is unknown. Resolve it before sending again."
            )
          }
        } catch {
          try handleReconciliationFailure(
            attemptId,
            error: error,
            productAccountId: productAccountId,
            provider: provider,
            reconcile: reconcile
          )
          return
        }
        continue
      }
      if attempts[index].state == .retrying, retryLimitReached(attempts[index]) {
        attempts[index].state = .failed
        attempts[index].lastErrorDescription = "Automatic delivery retry limit reached."
        attempts[index].nextRetryAtMilliseconds = nil
        try store.save(attempts, productAccountId: productAccountId)
        continue
      }
      attempts[index].state = .handingOff
      attempts[index].attemptCount += 1
      attempts[index].firstAttemptAtMilliseconds =
        attempts[index].firstAttemptAtMilliseconds ?? milliseconds(now())
      attempts[index].nextRetryAtMilliseconds = nil
      attempts[index].reconciliationAttemptCount = 0
      try store.save(attempts, productAccountId: productAccountId)
      let claimedAttempt = attempts[index]

      do {
        try await provider(
          claimedAttempt.message,
          claimedAttempt.idempotencyKey,
          claimedAttempt.mailboxConnectionId
        )
        try update(
          attemptId,
          productAccountId: productAccountId,
          state: .sent,
          errorDescription: nil
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
            return
          }
          switch status {
          case .sent:
            try update(
              attemptId,
              productAccountId: productAccountId,
              state: .sent,
              errorDescription: nil
            )
          case .notSent:
            try handleReconciliationFailure(
              attemptId,
              error: error,
              productAccountId: productAccountId,
              provider: provider,
              reconcile: reconcile
            )
            return
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
        case .transient:
          try handleTransientFailure(
            attemptId,
            error: error,
            productAccountId: productAccountId,
            provider: provider,
            reconcile: reconcile
          )
          return
        case .userActionRequired:
          try update(
            attemptId,
            productAccountId: productAccountId,
            state: .userActionRequired,
            errorDescription: error.localizedDescription
          )
        }
      }
    }
  }

  private func handleTransientFailure(
    _ attemptId: UUID,
    error: Error,
    productAccountId: String,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) throws {
    var attempts = try store.load(productAccountId: productAccountId)
    guard let index = attempts.firstIndex(where: { $0.id == attemptId }) else { return }
    guard !retryLimitReached(attempts[index]) else {
      attempts[index].state = .failed
      attempts[index].lastErrorDescription = error.localizedDescription
      attempts[index].nextRetryAtMilliseconds = nil
      try store.save(attempts, productAccountId: productAccountId)
      return
    }
    attempts[index].state = .retrying
    attempts[index].lastErrorDescription = error.localizedDescription
    let delay = retryDelayNanoseconds(attempts[index].attemptCount)
    attempts[index].nextRetryAtMilliseconds =
      milliseconds(now()) + Int64(delay / 1_000_000)
    try store.save(attempts, productAccountId: productAccountId)
    scheduleRetry(attempts[index], delay: delay, provider: provider, reconcile: reconcile)
  }

  private func handleReconciliationFailure(
    _ attemptId: UUID,
    error: Error,
    productAccountId: String,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) throws {
    var attempts = try store.load(productAccountId: productAccountId)
    guard let index = attempts.firstIndex(where: { $0.id == attemptId }) else { return }
    attempts[index].reconciliationAttemptCount += 1
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

  private func scheduleRetry(
    _ attempt: OutgoingDeliveryAttempt,
    delay: UInt64,
    provider: @escaping OutboxDeliveryPerformer,
    reconcile: @escaping OutboxDeliveryReconciler
  ) {
    retryTasks.removeValue(forKey: attempt.id)?.cancel()
    let token = UUID()
    retryTaskTokens[attempt.id] = token
    retryTasks[attempt.id] = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: delay)
        guard let self else { return }
        await self.finishRetry(attempt.id, token: token)
        try await self.process(
          connectionId: attempt.mailboxConnectionId,
          productAccountId: attempt.productAccountId.rawValue,
          provider: provider,
          reconcile: reconcile
        )
      } catch {
        await self?.finishRetry(attempt.id, token: token)
      }
    }
  }

  private func finishRetry(_ attemptId: UUID, token: UUID) {
    guard retryTaskTokens[attemptId] == token else { return }
    retryTasks[attemptId] = nil
    retryTaskTokens[attemptId] = nil
  }

  private func requiredAttempt(
    _ attemptId: UUID,
    productAccountId: String
  ) throws -> OutgoingDeliveryAttempt {
    guard
      let attempt = try store.load(productAccountId: productAccountId)
        .first(where: { $0.id == attemptId })
    else {
      throw OutboxDeliveryError.attemptCannotBeChanged
    }
    return attempt
  }

  private func update(
    _ attemptId: UUID,
    productAccountId: String,
    state: OutgoingDeliveryState,
    errorDescription: String?
  ) throws {
    var attempts = try store.load(productAccountId: productAccountId)
    guard let index = attempts.firstIndex(where: { $0.id == attemptId }) else { return }
    attempts[index].state = state
    attempts[index].lastErrorDescription = errorDescription
    attempts[index].nextRetryAtMilliseconds = nil
    try store.save(attempts, productAccountId: productAccountId)
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
