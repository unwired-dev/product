import Foundation

// swiftlint:disable file_length

enum PendingProviderActionState: String, Codable, Sendable {
  case failed
  case pending
  case providerConfirmed
  case userActionRequired
}

struct PendingProviderAction: Codable, Equatable, Identifiable, Sendable {
  let action: ProviderMailAction
  var attemptCount: Int
  let connectionId: String
  let id: UUID
  var lastErrorDescription: String?
  let messageIds: [String]
  let productAccountId: String
  let providerId: String
  let providerMailboxIdentity: String
  let sequence: UInt64
  var state: PendingProviderActionState
  let targetProviderMailboxId: String?

  var mailboxConnectionId: MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: providerId),
        value: providerMailboxIdentity
      )
    )
  }

  func applies(to message: MailboxMessageMetadata) -> Bool {
    mailboxConnectionId == message.connectionId && messageIds.contains(message.providerMessageId)
  }

  var keepsOptimisticProjection: Bool {
    state == .pending || state == .providerConfirmed || state == .userActionRequired
  }
}

protocol PendingProviderActionPersisting {
  func load(productAccountId: String) throws -> [PendingProviderAction]

  func save(
    _ actions: [PendingProviderAction],
    productAccountId: String
  ) throws
}

struct FilePendingProviderActionStore: PendingProviderActionPersisting {
  private let fileManager: FileManager
  private let rootDirectory: URL

  init(
    fileManager: FileManager = .default,
    rootDirectory: URL? = nil
  ) {
    self.fileManager = fileManager
    self.rootDirectory =
      rootDirectory
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("UnwiredMail/PendingProviderActions", isDirectory: true)
  }

  func load(productAccountId: String) throws -> [PendingProviderAction] {
    let fileURL = fileURL(productAccountId: productAccountId)
    guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
    return try JSONDecoder().decode(
      [PendingProviderAction].self,
      from: Data(contentsOf: fileURL)
    )
  }

  func save(
    _ actions: [PendingProviderAction],
    productAccountId: String
  ) throws {
    try fileManager.createDirectory(
      at: rootDirectory,
      withIntermediateDirectories: true
    )
    try JSONEncoder().encode(actions).write(
      to: fileURL(productAccountId: productAccountId),
      options: [.atomic]
    )
  }

  private func fileURL(productAccountId: String) -> URL {
    rootDirectory.appendingPathComponent(
      "\(gmailSafeFileComponent(productAccountId)).json"
    )
  }
}

enum PendingProviderActionError: LocalizedError, Equatable {
  case connectionMismatch
  case permanentFailure(String)
  case productAccountMismatch
  case retryLimitReached(String)

  var errorDescription: String? {
    switch self {
    case .connectionMismatch:
      return "The selected messages do not belong to this Mailbox Connection."
    case .permanentFailure(let description):
      return description
    case .productAccountMismatch:
      return "The Mailbox Connection does not belong to the current Product Account."
    case .retryLimitReached(let description):
      return description
    }
  }
}

enum PendingProviderActionFailureDisposition {
  case permanent
  case transient
  case userActionRequired
}

struct GraphAmbiguousActionError: LocalizedError {
  var errorDescription: String? {
    "This action may have already been applied and must be confirmed before retrying."
  }
}

typealias PendingProviderActionPerformer =
  @Sendable (
    _ action: ProviderMailAction,
    _ targetProviderMailboxId: String?,
    _ messageIds: [String]
  ) async throws -> Void

private let defaultFailureDisposition:
  @Sendable (Error) -> PendingProviderActionFailureDisposition = { error in
    if error is GraphAmbiguousActionError {
      return .userActionRequired
    }
    if error is URLError {
      return .transient
    }
    if error is EWSAmbiguousProviderActionError {
      return .userActionRequired
    }
    if let serviceError = error as? EWSServiceError {
      switch serviceError {
      case .authenticationRejected:
        return .userActionRequired
      case .invalidResponse:
        return .userActionRequired
      case .response(let code, _):
        let status = code.split(separator: " ").last.flatMap { Int($0) }
        if status == 408 || status == 409 || status == 425 || status == 429
          || status.map({ $0 >= 500 }) == true
          || [
            "ErrorExceededConnectionCount",
            "ErrorADUnavailable",
            "ErrorInternalServerTransientError",
            "ErrorInvalidChangeKey",
            "ErrorIrresolvableConflict",
            "ErrorMailboxStoreUnavailable",
            "ErrorServerBusy",
            "ErrorTimeoutExpired",
          ].contains(code)
        {
          return .transient
        }
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
    if case .tokenExchangeFailed(let status) = error as? MicrosoftGraphOAuthError,
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
        return .userActionRequired
      }
    }
    if case .rateLimitedResponseStatus = error as? GmailProviderMailActionError {
      return .transient
    }
    if case .responseStatus(let status) = error as? GmailProviderMailActionError {
      if status == 401 || status == 403 {
        return .userActionRequired
      }
      if status == 408 || status == 409 || status == 425 || status == 429 || status >= 500 {
        return .transient
      }
    }
    return .permanent
  }

private let defaultRetryDelay: @Sendable (Int) -> UInt64 = { attempt in
  let seconds = min(60, 1 << max(0, attempt - 1))
  let baseDelay = UInt64(seconds) * 1_000_000_000
  return baseDelay + UInt64.random(in: 0...(baseDelay / 4))
}

private struct PendingProviderActionQueueKey: Hashable {
  let connectionId: String
  let productAccountId: String
}

// swiftlint:disable:next type_body_length
actor PendingProviderActionService {
  static let shared = PendingProviderActionService()

  private let failureDisposition: @Sendable (Error) -> PendingProviderActionFailureDisposition
  private let maximumAttempts: Int
  private var processingQueueKeys: Set<PendingProviderActionQueueKey> = []
  private var processingWaiters:
    [PendingProviderActionQueueKey: [UUID: CheckedContinuation<Void, Never>]] = [:]
  private let retryDelayNanoseconds: @Sendable (Int) -> UInt64
  private var retryTasks: [PendingProviderActionQueueKey: Task<Void, Never>] = [:]
  private let store: PendingProviderActionPersisting

  init(
    failureDisposition: @escaping @Sendable (Error) -> PendingProviderActionFailureDisposition =
      defaultFailureDisposition,
    maximumAttempts: Int = 5,
    retryDelayNanoseconds: @escaping @Sendable (Int) -> UInt64 =
      defaultRetryDelay,
    store: PendingProviderActionPersisting = FilePendingProviderActionStore()
  ) {
    self.failureDisposition = failureDisposition
    self.maximumAttempts = maximumAttempts
    self.retryDelayNanoseconds = retryDelayNanoseconds
    self.store = store
  }

  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String? = nil,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    provider: @escaping PendingProviderActionPerformer
  ) async throws {
    try enqueue(
      action,
      targetProviderMailboxId: targetProviderMailboxId,
      messages: messages,
      connection: connection,
      session: session
    )
    try await process(
      connectionId: connection.id,
      productAccountId: session.productAccountId,
      provider: provider
    )
  }

  func enqueue(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String? = nil,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    guard !messages.isEmpty else { return }
    guard connection.productAccountId.rawValue == session.productAccountId else {
      throw PendingProviderActionError.productAccountMismatch
    }
    guard messages.allSatisfy({ $0.connectionId == connection.id }) else {
      throw PendingProviderActionError.connectionMismatch
    }
    var actions = try store.load(productAccountId: session.productAccountId)
    var nextSequence = (actions.map(\.sequence).max() ?? 0) + 1
    for message in messages {
      actions.append(
        PendingProviderAction(
          action: action,
          attemptCount: 0,
          connectionId: connection.id.rawValue,
          id: UUID(),
          lastErrorDescription: nil,
          messageIds: [message.providerMessageId],
          productAccountId: session.productAccountId,
          providerId: connection.providerId.rawValue,
          providerMailboxIdentity: connection.providerMailboxIdentity.value,
          sequence: nextSequence,
          state: .pending,
          targetProviderMailboxId: targetProviderMailboxId
        )
      )
      nextSequence += 1
    }
    try store.save(actions, productAccountId: session.productAccountId)
  }

  func project(
    _ result: MailboxMetadataSyncResult,
    collection: MailboxMessageCollection = .role(.inbox),
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws -> MailboxMetadataSyncResult {
    let pendingActions =
      try store.load(productAccountId: session.productAccountId)
      .filter {
        $0.connectionId == connection.id.rawValue && $0.keepsOptimisticProjection
      }
      .sorted { $0.sequence < $1.sequence }
    guard !pendingActions.isEmpty else { return result.projected(to: collection) }

    let observedMessages = Dictionary(
      (result.threads.flatMap(\.messages) + result.messages).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    ).values
    let projectedMessages = observedMessages.map { message in
      pendingActions.reduce(message) { current, pendingAction in
        guard pendingAction.applies(to: current) else { return current }
        return current.applying(
          pendingAction.action,
          providerId: connection.providerId,
          targetProviderMailboxId: pendingAction.targetProviderMailboxId
        )
      }
    }
    return MailboxMetadataSyncResult(
      hasUnlistedNewMessages: result.hasUnlistedNewMessages,
      messages: projectedMessages,
      newMessageIds: result.newMessageIds,
      providerCursorIsExpired: result.providerCursorIsExpired,
      threads: MailboxThread.group(projectedMessages),
      hasInitialMailboxAvailability: result.hasInitialMailboxAvailability,
      historicalMetadataBackfillIsComplete: result.historicalMetadataBackfillIsComplete
    )
    .projected(to: collection)
  }

  func resume(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    provider: @escaping PendingProviderActionPerformer
  ) async throws {
    try await process(
      connectionId: connection.id,
      productAccountId: session.productAccountId,
      provider: provider
    )
  }

  func retryBlockedAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    provider: @escaping PendingProviderActionPerformer
  ) async throws {
    var actions = try store.load(productAccountId: session.productAccountId)
    guard
      let index = actions.indices.filter({
        actions[$0].connectionId == connection.id.rawValue
          && actions[$0].state == .userActionRequired
      }).min(by: { actions[$0].sequence < actions[$1].sequence })
    else {
      return
    }
    actions[index].attemptCount = 0
    actions[index].lastErrorDescription = nil
    actions[index].state = .pending
    try store.save(actions, productAccountId: session.productAccountId)
    try await process(
      connectionId: connection.id,
      productAccountId: session.productAccountId,
      provider: provider
    )
  }

  func discardBlockedAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    provider: @escaping PendingProviderActionPerformer
  ) async throws {
    var actions = try store.load(productAccountId: session.productAccountId)
    guard
      let index = actions.indices.filter({
        actions[$0].connectionId == connection.id.rawValue
          && actions[$0].state == .userActionRequired
      }).min(by: { actions[$0].sequence < actions[$1].sequence })
    else {
      return
    }
    actions.remove(at: index)
    try store.save(actions, productAccountId: session.productAccountId)
    try await process(
      connectionId: connection.id,
      productAccountId: session.productAccountId,
      provider: provider
    )
  }

  func waitForScheduledRetries(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async {
    let key = queueKey(connection: connection, session: session)
    while !Task.isCancelled {
      if let task = retryTasks[key] {
        await task.value
      } else if processingQueueKeys.contains(key) {
        await waitUntilProcessingFinishes(key: key)
      } else {
        return
      }
    }
  }

  func failureDescription(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws -> String? {
    let actions = try store.load(productAccountId: session.productAccountId)
    let failures = actions.filter {
      $0.connectionId == connection.id.rawValue
        && ($0.state == .failed || $0.state == .userActionRequired)
    }.sorted { $0.sequence < $1.sequence }
    guard !failures.isEmpty else { return nil }
    return failures.compactMap(\.lastErrorDescription).reduce(into: [String]()) {
      if !$0.contains($1) {
        $0.append($1)
      }
    }.joined(separator: "\n")
  }

  func failureDetails(
    _ action: ProviderMailAction,
    messageIds: Set<String>,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws -> [MailboxProviderActionFailureDetail] {
    let actions = try store.load(productAccountId: session.productAccountId)
      .filter {
        $0.action == action && $0.connectionId == connection.id.rawValue
          && !Set($0.messageIds).isDisjoint(with: messageIds)
      }
      .sorted { $0.sequence < $1.sequence }
    var latestActionByMessageId: [String: PendingProviderAction] = [:]
    for pendingAction in actions {
      for messageId in pendingAction.messageIds where messageIds.contains(messageId) {
        latestActionByMessageId[messageId] = pendingAction
      }
    }
    return latestActionByMessageId.keys.sorted().compactMap { messageId in
      guard let pendingAction = latestActionByMessageId[messageId],
        pendingAction.state == .failed || pendingAction.state == .userActionRequired
      else { return nil }
      return MailboxProviderActionFailureDetail(
        description: pendingAction.lastErrorDescription ?? "Waiting for an earlier pending action.",
        messageIds: [
          StableProviderMessageIdentity(
            connectionId: connection.id,
            providerMessageId: messageId
          )
        ]
      )
    }
  }

  func reconcileProviderSync(
    messages: [MailboxMessageMetadata],
    removesContradictedActions: Bool = true,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    isConfirmed: (
      (
        _ action: ProviderMailAction,
        _ targetProviderMailboxId: String?,
        _ messageIds: [String]
      ) -> Bool
    )? = nil
  ) throws {
    var actions = try store.load(productAccountId: session.productAccountId)
    let actionIsConfirmed: (PendingProviderAction) -> Bool = { pendingAction in
      isConfirmed?(
        pendingAction.action,
        pendingAction.targetProviderMailboxId,
        pendingAction.messageIds
      ) ?? pendingAction.isConfirmed(in: messages, providerId: connection.providerId)
    }
    let confirmedActionIds = Set(
      actions.filter { pendingAction in
        return pendingAction.connectionId == connection.id.rawValue
          && (pendingAction.state == .providerConfirmed
            || pendingAction.state == .userActionRequired)
          && actionIsConfirmed(pendingAction)
      }.map(\.id)
    )
    let supersededActionIds = Set(
      actions.filter { action in
        action.connectionId == connection.id.rawValue
          && action.state == .providerConfirmed
          && actions.contains { confirmedAction in
            confirmedActionIds.contains(confirmedAction.id)
              && confirmedAction.sequence > action.sequence
              && !Set(action.messageIds).isDisjoint(with: confirmedAction.messageIds)
              && action.action.isSuperseded(by: confirmedAction.action)
          }
      }.map(\.id)
    )
    let contradictedActionIds = Set(
      actions.filter { action in
        removesContradictedActions
          && action.connectionId == connection.id.rawValue
          && action.state == .providerConfirmed
          && action.messageIds.allSatisfy { messageId in
            messages.contains { $0.providerMessageId == messageId }
          }
          && !actionIsConfirmed(action)
      }.map(\.id)
    )
    actions.removeAll {
      $0.connectionId == connection.id.rawValue
        && (confirmedActionIds.contains($0.id)
          || supersededActionIds.contains($0.id)
          || contradictedActionIds.contains($0.id))
    }
    try store.save(actions, productAccountId: session.productAccountId)
  }

  func pendingActions(
    session: ProductAccountSessionSnapshot
  ) throws -> [PendingProviderAction] {
    try store.load(productAccountId: session.productAccountId)
  }

  func hasBlockedAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws -> Bool {
    try store.load(productAccountId: session.productAccountId).contains {
      $0.connectionId == connection.id.rawValue && $0.state == .userActionRequired
    }
  }

  func hasFailedAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws -> Bool {
    try store.load(productAccountId: session.productAccountId).contains {
      $0.connectionId == connection.id.rawValue && $0.state == .failed
    }
  }

  func acknowledgeFailures(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    var actions = try store.load(productAccountId: session.productAccountId)
    actions.removeAll {
      $0.connectionId == connection.id.rawValue && $0.state == .failed
    }
    try store.save(actions, productAccountId: session.productAccountId)
  }

  func clear(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    retryTasks.removeValue(forKey: queueKey(connection: connection, session: session))?.cancel()
    var actions = try store.load(productAccountId: session.productAccountId)
    actions.removeAll { $0.connectionId == connection.id.rawValue }
    try store.save(actions, productAccountId: session.productAccountId)
  }

  func clear(session: ProductAccountSessionSnapshot) throws {
    let sessionKeys = retryTasks.keys.filter {
      $0.productAccountId == session.productAccountId
    }
    for key in sessionKeys {
      retryTasks.removeValue(forKey: key)?.cancel()
    }
    try store.save([], productAccountId: session.productAccountId)
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func process(
    connectionId: MailboxConnectionId,
    productAccountId: String,
    provider: @escaping PendingProviderActionPerformer
  ) async throws {
    let key = PendingProviderActionQueueKey(
      connectionId: connectionId.rawValue,
      productAccountId: productAccountId
    )
    guard retryTasks[key] == nil else { return }
    guard processingQueueKeys.insert(key).inserted else { return }
    defer { finishProcessing(key: key) }
    var firstPermanentFailure: Error?

    while true {
      var actions = try store.load(productAccountId: productAccountId)
      let connectionActions = actions.indices.filter {
        actions[$0].connectionId == connectionId.rawValue
      }
      if let blockedIndex =
        connectionActions
        .filter({ actions[$0].state == .userActionRequired })
        .min(by: { actions[$0].sequence < actions[$1].sequence })
      {
        throw PendingProviderActionError.retryLimitReached(
          actions[blockedIndex].lastErrorDescription ?? "Provider action requires attention."
        )
      }
      guard
        let index =
          connectionActions
          .filter({ actions[$0].state == .pending })
          .min(by: { actions[$0].sequence < actions[$1].sequence })
      else { break }
      let pendingAction = actions[index]

      do {
        try Task.checkCancellation()
        guard
          try store.load(productAccountId: productAccountId).contains(where: {
            $0.id == pendingAction.id && $0.state == .pending
          })
        else { continue }
        try await provider(
          pendingAction.action,
          pendingAction.targetProviderMailboxId,
          pendingAction.messageIds
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as URLError where error.code == .cancelled {
        throw CancellationError()
      } catch {
        actions = try store.load(productAccountId: productAccountId)
        guard let updatedIndex = actions.firstIndex(where: { $0.id == pendingAction.id }) else {
          continue
        }
        actions[updatedIndex].attemptCount += 1
        actions[updatedIndex].lastErrorDescription = error.localizedDescription
        var disposition = failureDisposition(error)
        if pendingAction.action == .markRead || pendingAction.action == .markUnread,
          case .requestFailed(let status) = error as? MicrosoftGraphClientError,
          status == 408 || status == 409 || status == 425 || status >= 500
        {
          disposition = .transient
        }
        switch disposition {
        case .transient where actions[updatedIndex].attemptCount < maximumAttempts:
          try store.save(actions, productAccountId: productAccountId)
          scheduleRetry(action: actions[updatedIndex], provider: provider)
          return
        case .transient:
          actions[updatedIndex].state = .userActionRequired
          try store.save(actions, productAccountId: productAccountId)
          throw PendingProviderActionError.retryLimitReached(error.localizedDescription)
        case .permanent:
          actions[updatedIndex].state = .failed
          try store.save(actions, productAccountId: productAccountId)
          if firstPermanentFailure == nil {
            firstPermanentFailure = error
          }
        case .userActionRequired:
          actions[updatedIndex].state = .userActionRequired
          try store.save(actions, productAccountId: productAccountId)
          throw PendingProviderActionError.retryLimitReached(error.localizedDescription)
        }
        continue
      }

      actions = try store.load(productAccountId: productAccountId)
      guard let updatedIndex = actions.firstIndex(where: { $0.id == pendingAction.id }) else {
        continue
      }
      actions[updatedIndex].state = .providerConfirmed
      actions[updatedIndex].lastErrorDescription = nil
      try store.save(actions, productAccountId: productAccountId)
    }
    if let firstPermanentFailure {
      throw firstPermanentFailure
    }
  }

  private func scheduleRetry(
    action: PendingProviderAction,
    provider: @escaping PendingProviderActionPerformer
  ) {
    let key = PendingProviderActionQueueKey(
      connectionId: action.connectionId,
      productAccountId: action.productAccountId
    )
    guard retryTasks[key] == nil else { return }
    let delay = retryDelayNanoseconds(action.attemptCount)
    retryTasks[key] = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: delay)
        guard let self else { return }
        await self.waitUntilProcessingFinishes(key: key)
        try await self.runScheduledRetry(
          key: key,
          connectionId: action.mailboxConnectionId,
          productAccountId: action.productAccountId,
          provider: provider
        )
      } catch {
        await self?.finishRetry(key: key)
      }
    }
  }

  private func runScheduledRetry(
    key: PendingProviderActionQueueKey,
    connectionId: MailboxConnectionId,
    productAccountId: String,
    provider: @escaping PendingProviderActionPerformer
  ) async throws {
    retryTasks[key] = nil
    try await process(
      connectionId: connectionId,
      productAccountId: productAccountId,
      provider: provider
    )
  }

  private func waitUntilProcessingFinishes(key: PendingProviderActionQueueKey) async {
    guard processingQueueKeys.contains(key) else { return }
    let waiterId = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled, processingQueueKeys.contains(key) else {
          continuation.resume()
          return
        }
        processingWaiters[key, default: [:]][waiterId] = continuation
      }
    } onCancel: {
      Task {
        await self.cancelProcessingWaiter(key: key, waiterId: waiterId)
      }
    }
  }

  private func cancelProcessingWaiter(
    key: PendingProviderActionQueueKey,
    waiterId: UUID
  ) {
    processingWaiters[key]?.removeValue(forKey: waiterId)?.resume()
    if processingWaiters[key]?.isEmpty == true {
      processingWaiters[key] = nil
    }
  }

  private func finishProcessing(key: PendingProviderActionQueueKey) {
    processingQueueKeys.remove(key)
    let waiters = processingWaiters.removeValue(forKey: key) ?? [:]
    for continuation in waiters.values {
      continuation.resume()
    }
  }

  private func finishRetry(key: PendingProviderActionQueueKey) {
    retryTasks[key] = nil
  }

  private func queueKey(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) -> PendingProviderActionQueueKey {
    PendingProviderActionQueueKey(
      connectionId: connection.id.rawValue,
      productAccountId: session.productAccountId
    )
  }
}

extension PendingProviderAction {
  // swiftlint:disable:next cyclomatic_complexity
  fileprivate func isConfirmed(
    in messages: [MailboxMessageMetadata],
    providerId: MailProviderId
  ) -> Bool {
    messageIds.allSatisfy { messageId in
      guard let message = messages.first(where: { $0.providerMessageId == messageId }) else {
        return false
      }
      let states = Set(message.providerStateIds ?? [])
      switch action {
      case .archive:
        return providerId == .microsoftGraph
          ? states.contains("ARCHIVE")
          : !states.contains("INBOX")
      case .delete:
        return states.contains("TRASH")
      case .markRead:
        return !states.contains("UNREAD")
      case .markUnread:
        return states.contains("UNREAD")
      case .move:
        guard let targetProviderMailboxId else { return false }
        return states.contains(targetProviderMailboxId)
          && (targetProviderMailboxId == "INBOX" || !states.contains("INBOX"))
      case .notSpam:
        return !states.contains("SPAM") && states.contains("INBOX")
      case .restore:
        return !states.contains("TRASH") && states.contains("INBOX")
      case .spam:
        return !states.contains("INBOX") && states.contains("SPAM")
      case .star:
        return states.contains("STARRED")
      case .unstar:
        return !states.contains("STARRED")
      }
    }
  }
}

extension ProviderMailAction {
  fileprivate func isSuperseded(by action: ProviderMailAction) -> Bool {
    switch (self, action) {
    case (.markRead, .markRead), (.markRead, .markUnread),
      (.markUnread, .markRead), (.markUnread, .markUnread),
      (.star, .star), (.star, .unstar),
      (.unstar, .star), (.unstar, .unstar):
      true
    case (.archive, .archive), (.archive, .delete), (.archive, .move),
      (.archive, .notSpam), (.archive, .restore), (.archive, .spam),
      (.delete, .archive), (.delete, .delete), (.delete, .move),
      (.delete, .notSpam), (.delete, .restore), (.delete, .spam),
      (.move, .archive), (.move, .delete), (.move, .move),
      (.move, .notSpam), (.move, .restore), (.move, .spam),
      (.notSpam, .archive), (.notSpam, .delete), (.notSpam, .move),
      (.notSpam, .notSpam), (.notSpam, .restore), (.notSpam, .spam),
      (.restore, .archive), (.restore, .delete), (.restore, .move),
      (.restore, .notSpam), (.restore, .restore), (.restore, .spam),
      (.spam, .archive), (.spam, .delete), (.spam, .move),
      (.spam, .notSpam), (.spam, .restore), (.spam, .spam):
      true
    default:
      false
    }
  }
}

extension MailboxMessageMetadata {
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  fileprivate func applying(
    _ action: ProviderMailAction,
    providerId: MailProviderId,
    targetProviderMailboxId: String?
  ) -> MailboxMessageMetadata {
    var states = Set(providerStateIds ?? ["INBOX"])
    switch action {
    case .archive:
      states.remove("INBOX")
      if providerId == .microsoftGraph {
        states.insert("ARCHIVE")
      }
    case .delete:
      states = states.filter { ["IMPORTANT", "STARRED", "UNREAD"].contains($0) }
      states.insert("TRASH")
    case .markRead:
      states.remove("UNREAD")
    case .markUnread:
      states.insert("UNREAD")
    case .move:
      states.remove("INBOX")
      states = states.filter {
        !$0.hasPrefix("graph-folder:") && !$0.hasPrefix("ews-folder:")
      }
    case .notSpam:
      states.remove("SPAM")
      states.insert("INBOX")
    case .restore:
      states.remove("TRASH")
      states.insert("INBOX")
    case .spam:
      states.remove("INBOX")
      states = states.filter { !$0.hasPrefix("graph-folder:") }
      states.insert("SPAM")
    case .star:
      states.insert("STARRED")
    case .unstar:
      states.remove("STARRED")
    }
    if let targetProviderMailboxId {
      states.insert(targetProviderMailboxId)
    }
    return MailboxMessageMetadata(
      categoryId: categoryId,
      connectionId: connectionId,
      from: from,
      isHistorical: isHistorical,
      providerInternalDateMilliseconds: providerInternalDateMilliseconds,
      providerMessageId: providerMessageId,
      providerStateIds: states.sorted(),
      providerThreadId: providerThreadId,
      recipientHeaders: recipientHeaders,
      replyTo: replyTo,
      rfcMessageId: rfcMessageId,
      snippet: snippet,
      subject: subject,
      bccRecipients: bccRecipients
    )
  }
}
