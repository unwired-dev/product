import Foundation

// swiftlint:disable file_length

/// The scheduling class for a read-only mail operation.
enum MailLoadPriority: Equatable {
  case interactive
  case speculative
}

/// Coordinates read-only mail work for every window in one Product Account.
@MainActor
// swiftlint:disable:next type_body_length
final class ProductAccountMailLoadScheduler {
  /// The maximum number of message-body pipelines that may run for one Product Account.
  nonisolated static let maximumConcurrentBodyPipelines = 4

  /// The maximum number of message-body pipelines that may run for one Mailbox Connection.
  nonisolated static let maximumBodyPipelinesPerConnection = 2

  /// The remote-image request pool shared by every window in the Product Account.
  nonisolated let remoteImageRequests = ProductAccountRemoteImageRequestGate()

  private struct BodyPermitWaiter {
    let connectionId: MailboxConnectionId
    let continuation: CheckedContinuation<MailLoadPriority?, Never>
    let id: UUID
    let loadId: UUID?
    let maximumConcurrentPipelines: Int
    let priority: MailLoadPriority
  }

  private struct SharedBodyLoad {
    let id: UUID
    var priority: MailLoadPriority
    let task: Task<Void, Never>
    var waiters: [UUID: CheckedContinuation<MailboxMessageBody, any Error>]
  }

  #if DEBUG || TESTING
    private struct BodyPermitCountWaiter {
      let count: Int
      let continuation: CheckedContinuation<Void, Never>
    }

    private struct SharedBodyConsumerWaiter {
      let messageId: StableProviderMessageIdentity
      let count: Int
      let continuation: CheckedContinuation<Void, Never>
    }
  #endif

  private var activeBodyPipelineCount = 0
  private var activeBodyPipelineCounts: [MailboxConnectionId: Int] = [:]
  private var activeSpeculativePipelineCounts: [MailboxConnectionId: Int] = [:]
  private var bodyPermitWaiters: [BodyPermitWaiter] = []
  private var sharedBodyLoads: [StableProviderMessageIdentity: SharedBodyLoad] = [:]
  #if DEBUG || TESTING
    private var bodyPermitCountWaiters: [BodyPermitCountWaiter] = []
    private var sharedBodyConsumerWaiters: [SharedBodyConsumerWaiter] = []
  #endif

  /// Loads one message body, sharing the provider task with duplicate consumers.
  ///
  /// - Parameters:
  ///   - messageId: The stable provider identity used to deduplicate the load.
  ///   - maximumConcurrentPipelines: A provider-specific connection limit, capped at two.
  ///   - operation: The provider load and cache-write operation.
  /// - Returns: The body returned by the single shared provider operation.
  func loadMessageBody(
    for messageId: StableProviderMessageIdentity,
    maximumConcurrentPipelines: Int = maximumBodyPipelinesPerConnection,
    priority: MailLoadPriority = .interactive,
    operation: @escaping () async throws -> MailboxMessageBody
  ) async throws -> MailboxMessageBody {
    try Task.checkCancellation()
    let waiterId = UUID()
    if sharedBodyLoads[messageId] == nil {
      startSharedBodyLoad(
        for: messageId,
        maximumConcurrentPipelines: maximumConcurrentPipelines,
        priority: priority,
        operation: operation
      )
    } else if priority == .interactive,
      var load = sharedBodyLoads[messageId],
      load.priority == .speculative
    {
      load.priority = .interactive
      sharedBodyLoads[messageId] = load
      promoteBodyPermitWaiter(loadId: load.id)
    }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          cancelSharedBodyLoadIfUnobserved(messageId)
          return
        }
        guard var load = sharedBodyLoads[messageId] else {
          continuation.resume(throwing: CancellationError())
          return
        }
        load.waiters[waiterId] = continuation
        sharedBodyLoads[messageId] = load
        #if DEBUG || TESTING
          resumeSharedBodyConsumerWaiters(for: messageId)
        #endif
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancelBodyWaiter(waiterId, messageId: messageId)
      }
    }
  }

  /// Performs user-visible body work within the Product Account and connection limits.
  func performInteractiveWork<Result>(
    connectionId: MailboxConnectionId,
    maximumConcurrentPipelines: Int = maximumBodyPipelinesPerConnection,
    operation: () async throws -> Result
  ) async throws -> Result {
    try await performWork(
      connectionId: connectionId,
      maximumConcurrentPipelines: maximumConcurrentPipelines,
      priority: .interactive,
      operation: operation
    )
  }

  /// Performs prefetch or historical work after queued interactive body work.
  func performSpeculativeWork(
    connectionId: MailboxConnectionId,
    maximumConcurrentPipelines: Int = maximumBodyPipelinesPerConnection,
    operation: () async throws -> Void
  ) async throws {
    try await performWork(
      connectionId: connectionId,
      maximumConcurrentPipelines: maximumConcurrentPipelines,
      priority: .speculative,
      operation: operation
    )
  }

  #if DEBUG || TESTING
    func waitUntilSharedBodyConsumerCountForTesting(
      _ count: Int,
      messageId: StableProviderMessageIdentity
    ) async {
      guard (sharedBodyLoads[messageId]?.waiters.count ?? 0) < count else { return }
      await withCheckedContinuation { continuation in
        sharedBodyConsumerWaiters.append(
          SharedBodyConsumerWaiter(
            messageId: messageId,
            count: count,
            continuation: continuation
          ))
      }
    }

    func waitUntilBodyPermitWaiterCountForTesting(_ count: Int) async {
      guard bodyPermitWaiters.count < count else { return }
      await withCheckedContinuation { continuation in
        bodyPermitCountWaiters.append(
          BodyPermitCountWaiter(count: count, continuation: continuation)
        )
      }
    }
  #endif

  private func startSharedBodyLoad(
    for messageId: StableProviderMessageIdentity,
    maximumConcurrentPipelines: Int,
    priority: MailLoadPriority,
    operation: @escaping () async throws -> MailboxMessageBody
  ) {
    let loadId = UUID()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      let result: Result<MailboxMessageBody, any Error>
      do {
        let effectivePriority =
          sharedBodyLoads[messageId]?.id == loadId
          ? sharedBodyLoads[messageId]?.priority ?? priority
          : priority
        result = .success(
          try await performWork(
            connectionId: messageId.connectionId,
            loadId: loadId,
            maximumConcurrentPipelines: maximumConcurrentPipelines,
            priority: effectivePriority,
            operation: operation
          ))
      } catch {
        result = .failure(error)
      }
      completeSharedBodyLoad(messageId, loadId: loadId, result: result)
    }
    sharedBodyLoads[messageId] = SharedBodyLoad(
      id: loadId,
      priority: priority,
      task: task,
      waiters: [:]
    )
  }

  private func completeSharedBodyLoad(
    _ messageId: StableProviderMessageIdentity,
    loadId: UUID,
    result: Result<MailboxMessageBody, any Error>
  ) {
    guard let load = sharedBodyLoads[messageId], load.id == loadId else { return }
    sharedBodyLoads[messageId] = nil
    for continuation in load.waiters.values {
      continuation.resume(with: result)
    }
  }

  private func cancelBodyWaiter(
    _ waiterId: UUID,
    messageId: StableProviderMessageIdentity
  ) {
    guard var load = sharedBodyLoads[messageId],
      let continuation = load.waiters.removeValue(forKey: waiterId)
    else { return }
    continuation.resume(throwing: CancellationError())
    if load.waiters.isEmpty {
      sharedBodyLoads[messageId] = nil
      load.task.cancel()
    } else {
      sharedBodyLoads[messageId] = load
    }
  }

  private func cancelSharedBodyLoadIfUnobserved(
    _ messageId: StableProviderMessageIdentity
  ) {
    guard let load = sharedBodyLoads[messageId], load.waiters.isEmpty else { return }
    sharedBodyLoads[messageId] = nil
    load.task.cancel()
  }

  #if DEBUG || TESTING
    private func resumeSharedBodyConsumerWaiters(
      for messageId: StableProviderMessageIdentity
    ) {
      let consumerCount = sharedBodyLoads[messageId]?.waiters.count ?? 0
      let ready = sharedBodyConsumerWaiters.filter {
        $0.messageId == messageId && consumerCount >= $0.count
      }
      sharedBodyConsumerWaiters.removeAll {
        $0.messageId == messageId && consumerCount >= $0.count
      }
      for waiter in ready {
        waiter.continuation.resume()
      }
    }
  #endif

  private func performWork<Result>(
    connectionId: MailboxConnectionId,
    loadId: UUID? = nil,
    maximumConcurrentPipelines: Int,
    priority: MailLoadPriority,
    operation: () async throws -> Result
  ) async throws -> Result {
    guard
      let acquiredPriority = await acquireBodyPermit(
        connectionId: connectionId,
        loadId: loadId,
        maximumConcurrentPipelines: maximumConcurrentPipelines,
        priority: priority
      )
    else { throw CancellationError() }
    do {
      try Task.checkCancellation()
      let result = try await operation()
      try Task.checkCancellation()
      releaseBodyPermit(connectionId: connectionId, priority: acquiredPriority)
      return result
    } catch {
      releaseBodyPermit(connectionId: connectionId, priority: acquiredPriority)
      throw error
    }
  }

  private func acquireBodyPermit(
    connectionId: MailboxConnectionId,
    loadId: UUID?,
    maximumConcurrentPipelines: Int,
    priority: MailLoadPriority
  ) async -> MailLoadPriority? {
    let maximumConcurrentPipelines = effectiveConnectionLimit(maximumConcurrentPipelines)
    if canStart(
      connectionId: connectionId,
      maximumConcurrentPipelines: maximumConcurrentPipelines,
      priority: priority
    ) {
      beginBodyPipeline(connectionId: connectionId, priority: priority)
      return priority
    }

    let waiterId = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: nil)
          return
        }
        bodyPermitWaiters.append(
          BodyPermitWaiter(
            connectionId: connectionId,
            continuation: continuation,
            id: waiterId,
            loadId: loadId,
            maximumConcurrentPipelines: maximumConcurrentPipelines,
            priority: priority
          ))
        #if DEBUG || TESTING
          resumeBodyPermitCountWaiters()
        #endif
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancelBodyPermitWaiter(waiterId)
      }
    }
  }

  private func releaseBodyPermit(
    connectionId: MailboxConnectionId,
    priority: MailLoadPriority
  ) {
    activeBodyPipelineCount -= 1
    let remainingConnectionCount = activeBodyPipelineCounts[connectionId, default: 1] - 1
    activeBodyPipelineCounts[connectionId] =
      remainingConnectionCount > 0 ? remainingConnectionCount : nil
    if priority == .speculative {
      let remainingSpeculativeCount =
        activeSpeculativePipelineCounts[connectionId, default: 1] - 1
      activeSpeculativePipelineCounts[connectionId] =
        remainingSpeculativeCount > 0 ? remainingSpeculativeCount : nil
    }
    resumeBodyPermitWaiters()
  }

  private func resumeBodyPermitWaiters() {
    while activeBodyPipelineCount < Self.maximumConcurrentBodyPipelines {
      let nextIndex = [.interactive, .speculative].compactMap { priority in
        bodyPermitWaiters.firstIndex {
          $0.priority == priority
            && canStart(
              connectionId: $0.connectionId,
              maximumConcurrentPipelines: $0.maximumConcurrentPipelines,
              priority: $0.priority
            )
        }
      }.first
      guard let nextIndex else { return }
      let waiter = bodyPermitWaiters.remove(at: nextIndex)
      beginBodyPipeline(connectionId: waiter.connectionId, priority: waiter.priority)
      waiter.continuation.resume(returning: waiter.priority)
    }
  }

  private func canStart(
    connectionId: MailboxConnectionId,
    maximumConcurrentPipelines: Int,
    priority: MailLoadPriority
  ) -> Bool {
    guard activeBodyPipelineCount < Self.maximumConcurrentBodyPipelines,
      activeBodyPipelineCounts[connectionId, default: 0] < maximumConcurrentPipelines
    else { return false }
    return priority != .speculative
      || activeSpeculativePipelineCounts[connectionId, default: 0] == 0
  }

  private func beginBodyPipeline(
    connectionId: MailboxConnectionId,
    priority: MailLoadPriority
  ) {
    activeBodyPipelineCount += 1
    activeBodyPipelineCounts[connectionId, default: 0] += 1
    if priority == .speculative {
      activeSpeculativePipelineCounts[connectionId, default: 0] += 1
    }
  }

  private func cancelBodyPermitWaiter(_ waiterId: UUID) {
    guard let index = bodyPermitWaiters.firstIndex(where: { $0.id == waiterId }) else { return }
    bodyPermitWaiters.remove(at: index).continuation.resume(returning: nil)
  }

  #if DEBUG || TESTING
    private func resumeBodyPermitCountWaiters() {
      let ready = bodyPermitCountWaiters.filter { bodyPermitWaiters.count >= $0.count }
      bodyPermitCountWaiters.removeAll { bodyPermitWaiters.count >= $0.count }
      for waiter in ready {
        waiter.continuation.resume()
      }
    }
  #endif

  private func promoteBodyPermitWaiter(loadId: UUID) {
    guard let index = bodyPermitWaiters.firstIndex(where: { $0.loadId == loadId }),
      bodyPermitWaiters[index].priority == .speculative
    else { return }
    let waiter = bodyPermitWaiters[index]
    bodyPermitWaiters[index] = BodyPermitWaiter(
      connectionId: waiter.connectionId,
      continuation: waiter.continuation,
      id: waiter.id,
      loadId: waiter.loadId,
      maximumConcurrentPipelines: waiter.maximumConcurrentPipelines,
      priority: .interactive
    )
    resumeBodyPermitWaiters()
  }

  private func effectiveConnectionLimit(_ requestedLimit: Int) -> Int {
    max(1, min(requestedLimit, Self.maximumBodyPipelinesPerConnection))
  }
}

/// Limits remote-image transfers across all windows in one Product Account.
actor ProductAccountRemoteImageRequestGate {
  /// The maximum number of simultaneous remote-image requests in one Product Account.
  static let maximumConcurrentRequests = 12

  /// The maximum number of simultaneous remote-image requests for one open message.
  static let maximumConcurrentRequestsPerMessage = 6

  private struct Waiter {
    let continuation: CheckedContinuation<Bool, Never>
    let id: UUID
    let messageId: StableProviderMessageIdentity
  }

  private struct SharedRequest {
    var consumerIds: Set<UUID>
    let id: UUID
    let messageId: StableProviderMessageIdentity
    let task: Task<RemoteMessageContentNetworkLoad, Error>
  }

  private struct SharedRequestConsumer {
    let consumerId: UUID
    let requestId: UUID
    let task: Task<RemoteMessageContentNetworkLoad, Error>
  }

  #if DEBUG || TESTING
    private struct SharedConsumerWaiter {
      let url: URL
      let count: Int
      let continuation: CheckedContinuation<Void, Never>
    }

    private struct WaiterCountWaiter {
      let count: Int
      let continuation: CheckedContinuation<Void, Never>
    }
  #endif

  private var activeRequestCount = 0
  private var activeRequestCounts: [StableProviderMessageIdentity: Int] = [:]
  private var sharedRequests: [URL: SharedRequest] = [:]
  private var waiters: [Waiter] = []
  #if DEBUG || TESTING
    private var sharedConsumerWaiters: [SharedConsumerWaiter] = []
    private var waiterCountWaiters: [WaiterCountWaiter] = []
  #endif

  /// Loads one remote resource once while allowing every consumer to await the result.
  func loadResource(
    for request: URLRequest,
    messageId: StableProviderMessageIdentity,
    deadline: TimeInterval? = nil,
    monotonicTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    operation: @Sendable @escaping () async throws -> RemoteMessageContentNetworkLoad
  ) async throws -> RemoteMessageContentNetworkLoad {
    guard let url = request.url else { return try await operation() }
    try requireTimeRemaining(until: deadline, monotonicTime: monotonicTime)
    if let request = joinSharedRequest(url) {
      let result = try await awaitSharedRequest(request, url: url)
      try requireTimeRemaining(until: deadline, monotonicTime: monotonicTime)
      return result
    }
    guard await acquire(for: messageId) else { throw CancellationError() }
    do {
      try requireTimeRemaining(until: deadline, monotonicTime: monotonicTime)
    } catch {
      release(for: messageId)
      throw error
    }
    if let request = joinSharedRequest(url) {
      release(for: messageId)
      let result = try await awaitSharedRequest(request, url: url)
      try requireTimeRemaining(until: deadline, monotonicTime: monotonicTime)
      return result
    }

    let requestId = UUID()
    let consumerId = UUID()
    let task = Task { try await operation() }
    sharedRequests[url] = SharedRequest(
      consumerIds: [consumerId],
      id: requestId,
      messageId: messageId,
      task: task
    )
    #if DEBUG || TESTING
      resumeSharedConsumerWaiters(for: url)
    #endif
    return try await awaitSharedRequest(
      SharedRequestConsumer(consumerId: consumerId, requestId: requestId, task: task),
      url: url
    )
  }

  private func requireTimeRemaining(
    until deadline: TimeInterval?,
    monotonicTime: () -> TimeInterval
  ) throws {
    guard let deadline else { return }
    guard monotonicTime() < deadline else { throw URLError(.timedOut) }
  }

  #if DEBUG || TESTING
    func waitUntilSharedConsumerCountForTesting(_ count: Int, url: URL) async {
      guard (sharedRequests[url]?.consumerIds.count ?? 0) < count else { return }
      await withCheckedContinuation { continuation in
        sharedConsumerWaiters.append(
          SharedConsumerWaiter(url: url, count: count, continuation: continuation)
        )
      }
    }

    func waitUntilWaiterCountForTesting(_ count: Int) async {
      guard waiters.count < count else { return }
      await withCheckedContinuation { continuation in
        waiterCountWaiters.append(WaiterCountWaiter(count: count, continuation: continuation))
      }
    }
  #endif

  /// Acquires one request slot, returning `false` when the waiting task is cancelled.
  func acquire(for messageId: StableProviderMessageIdentity) async -> Bool {
    if canStart(messageId) {
      beginRequest(messageId)
      return true
    }
    let waiterId = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        waiters.append(Waiter(continuation: continuation, id: waiterId, messageId: messageId))
        #if DEBUG || TESTING
          resumeWaiterCountWaiters()
        #endif
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterId) }
    }
  }

  /// Releases one request slot and resumes queued requests in FIFO order.
  func release(for messageId: StableProviderMessageIdentity) {
    guard activeRequestCounts[messageId] != nil else { return }
    activeRequestCount = max(0, activeRequestCount - 1)
    let remainingCount = activeRequestCounts[messageId, default: 1] - 1
    activeRequestCounts[messageId] = remainingCount > 0 ? remainingCount : nil
    resumeWaiters()
  }

  private func canStart(_ messageId: StableProviderMessageIdentity) -> Bool {
    activeRequestCount < Self.maximumConcurrentRequests
      && activeRequestCounts[messageId, default: 0] < Self.maximumConcurrentRequestsPerMessage
  }

  private func beginRequest(_ messageId: StableProviderMessageIdentity) {
    activeRequestCount += 1
    activeRequestCounts[messageId, default: 0] += 1
  }

  private func resumeWaiters() {
    while activeRequestCount < Self.maximumConcurrentRequests,
      let index = waiters.firstIndex(where: { canStart($0.messageId) })
    {
      let waiter = waiters.remove(at: index)
      beginRequest(waiter.messageId)
      waiter.continuation.resume(returning: true)
    }
  }

  private func cancelWaiter(_ waiterId: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == waiterId }) else { return }
    waiters.remove(at: index).continuation.resume(returning: false)
  }

  #if DEBUG || TESTING
    private func resumeWaiterCountWaiters() {
      let ready = waiterCountWaiters.filter { waiters.count >= $0.count }
      waiterCountWaiters.removeAll { waiters.count >= $0.count }
      for waiter in ready {
        waiter.continuation.resume()
      }
    }
  #endif

  private func joinSharedRequest(
    _ url: URL
  ) -> SharedRequestConsumer? {
    guard var request = sharedRequests[url] else { return nil }
    let consumerId = UUID()
    request.consumerIds.insert(consumerId)
    sharedRequests[url] = request
    #if DEBUG || TESTING
      resumeSharedConsumerWaiters(for: url)
    #endif
    return SharedRequestConsumer(
      consumerId: consumerId,
      requestId: request.id,
      task: request.task
    )
  }

  #if DEBUG || TESTING
    private func resumeSharedConsumerWaiters(for url: URL) {
      let consumerCount = sharedRequests[url]?.consumerIds.count ?? 0
      let ready = sharedConsumerWaiters.filter {
        $0.url == url && consumerCount >= $0.count
      }
      sharedConsumerWaiters.removeAll {
        $0.url == url && consumerCount >= $0.count
      }
      for waiter in ready {
        waiter.continuation.resume()
      }
    }
  #endif

  private func awaitSharedRequest(
    _ request: SharedRequestConsumer,
    url: URL
  ) async throws -> RemoteMessageContentNetworkLoad {
    try await withTaskCancellationHandler {
      do {
        let result = try await request.task.value
        finishSharedRequestConsumer(
          url,
          requestId: request.requestId,
          consumerId: request.consumerId
        )
        try Task.checkCancellation()
        return result
      } catch {
        finishSharedRequestConsumer(
          url,
          requestId: request.requestId,
          consumerId: request.consumerId
        )
        throw error
      }
    } onCancel: {
      Task {
        await self.finishSharedRequestConsumer(
          url,
          requestId: request.requestId,
          consumerId: request.consumerId
        )
      }
    }
  }

  private func finishSharedRequestConsumer(
    _ url: URL,
    requestId: UUID,
    consumerId: UUID
  ) {
    guard var request = sharedRequests[url], request.id == requestId,
      request.consumerIds.remove(consumerId) != nil
    else { return }
    guard request.consumerIds.isEmpty else {
      sharedRequests[url] = request
      return
    }
    request.task.cancel()
    sharedRequests[url] = nil
    release(for: request.messageId)
  }
}

/// Defines provider-local body concurrency without affecting peer Mailbox Connections.
enum MailLoadConcurrencyPolicy {
  /// Returns the maximum number of body pipelines for one connection of the provider.
  static func maximumConcurrentBodyPipelines(for providerId: MailProviderId) -> Int {
    switch providerId {
    case .exchangeWebServices, .imapSMTP, .pop3SMTP:
      1
    default:
      ProductAccountMailLoadScheduler.maximumBodyPipelinesPerConnection
    }
  }
}
