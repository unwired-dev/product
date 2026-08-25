import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

@MainActor
struct MailLoadSchedulerTests {
  @Test("Body pipelines respect Product Account and Mailbox Connection limits", .bug(id: 551))
  func bodyPipelineLimits() async throws {
    let scheduler = ProductAccountMailLoadScheduler()
    let probe = MailLoadConcurrencyProbe()
    let firstConnection = connectionId(provider: .gmail, value: "first")
    let secondConnection = connectionId(provider: .microsoftGraph, value: "second")

    let tasks =
      (0..<6).map { index in
        bodyTask(
          scheduler: scheduler,
          probe: probe,
          label: "first-\(index)",
          messageId: messageId(connection: firstConnection, value: "first-\(index)")
        )
      }
      + (0..<4).map { index in
        bodyTask(
          scheduler: scheduler,
          probe: probe,
          label: "second-\(index)",
          messageId: messageId(connection: secondConnection, value: "second-\(index)")
        )
      }

    await probe.waitUntilStarted(4)
    let snapshot = await probe.snapshot()

    #expect(snapshot.activeCount == 4)
    #expect(snapshot.maximumActiveCount == 4)
    #expect(snapshot.activeCountByConnection[firstConnection] == 2)
    #expect(snapshot.activeCountByConnection[secondConnection] == 2)

    await probe.releaseAll()
    for task in tasks {
      _ = try await task.value
    }
  }

  @Test("A provider-local lower limit does not serialize another connection", .bug(id: 551))
  func providerLimitIsConnectionScoped() async throws {
    let scheduler = ProductAccountMailLoadScheduler()
    let probe = MailLoadConcurrencyProbe()
    let constrainedConnection = connectionId(provider: .exchangeWebServices, value: "ews")
    let peerConnection = connectionId(provider: .gmail, value: "gmail")

    let constrainedTasks = (0..<3).map { index in
      bodyTask(
        scheduler: scheduler,
        probe: probe,
        label: "constrained-\(index)",
        maximumConcurrentPipelines: 1,
        messageId: messageId(connection: constrainedConnection, value: "ews-\(index)")
      )
    }
    let peerTasks = (0..<3).map { index in
      bodyTask(
        scheduler: scheduler,
        probe: probe,
        label: "peer-\(index)",
        messageId: messageId(connection: peerConnection, value: "gmail-\(index)")
      )
    }

    await probe.waitUntilStarted(3)
    let snapshot = await probe.snapshot()

    #expect(snapshot.activeCountByConnection[constrainedConnection] == 1)
    #expect(snapshot.activeCountByConnection[peerConnection] == 2)

    await probe.releaseAll()
    for task in constrainedTasks + peerTasks {
      _ = try await task.value
    }
  }

  @Test("Interactive body work starts before queued speculative work", .bug(id: 551))
  func interactiveWorkPreemptsQueuedSpeculation() async throws {
    let scheduler = ProductAccountMailLoadScheduler()
    let probe = MailLoadConcurrencyProbe()
    let connection = connectionId(provider: .gmail, value: "priority")

    let firstBlocker = bodyTask(
      scheduler: scheduler,
      probe: probe,
      label: "blocker-1",
      messageId: messageId(connection: connection, value: "blocker-1")
    )
    let secondBlocker = bodyTask(
      scheduler: scheduler,
      probe: probe,
      label: "blocker-2",
      messageId: messageId(connection: connection, value: "blocker-2")
    )
    await probe.waitUntilStarted(2)

    let speculative = Task { @MainActor in
      try await scheduler.performSpeculativeWork(connectionId: connection) {
        await probe.run(label: "speculative", connectionId: connection)
      }
    }
    let interactive = Task { @MainActor in
      try await scheduler.performInteractiveWork(connectionId: connection) {
        await probe.run(label: "interactive", connectionId: connection)
        return MailboxMessageBody(text: "interactive")
      }
    }

    await probe.release("blocker-1")
    await probe.waitUntilStarted(3)
    let firstThreeStarts = await probe.startedLabels().prefix(3)
    #expect(firstThreeStarts == ["blocker-1", "blocker-2", "interactive"])

    await probe.releaseAll()
    _ = try await firstBlocker.value
    _ = try await secondBlocker.value
    try await speculative.value
    _ = try await interactive.value
  }

  @Test(
    "Duplicate message loads share one task while consumers cancel independently", .bug(id: 551))
  func duplicateMessageLoadsShareOneTask() async throws {
    let scheduler = ProductAccountMailLoadScheduler()
    let probe = MailLoadConcurrencyProbe()
    let connection = connectionId(provider: .gmail, value: "deduplication")
    let message = messageId(connection: connection, value: "shared")

    let cancelledConsumer = bodyTask(
      scheduler: scheduler,
      probe: probe,
      label: "provider-load",
      messageId: message
    )
    let retainedConsumer = bodyTask(
      scheduler: scheduler,
      probe: probe,
      label: "duplicate-provider-load",
      messageId: message
    )
    await probe.waitUntilStarted(1)

    cancelledConsumer.cancel()
    await #expect(throws: CancellationError.self) {
      _ = try await cancelledConsumer.value
    }
    var snapshot = await probe.snapshot()
    #expect(snapshot.startedCount == 1)

    await probe.releaseAll()
    let body = try await retainedConsumer.value

    #expect(body.text == "provider-load")
    snapshot = await probe.snapshot()
    #expect(snapshot.startedCount == 1)
  }

  @Test("Remote image requests respect per-message and Product Account limits", .bug(id: 551))
  func remoteImageRequestLimits() async throws {
    let scheduler = ProductAccountMailLoadScheduler()
    let probe = RemoteImageRequestProbe()
    let connection = connectionId(provider: .gmail, value: "remote-images")
    let firstMessage = messageId(connection: connection, value: "first")
    let secondMessage = messageId(connection: connection, value: "second")

    let tasks =
      (0..<8).map { index in
        remoteImageTask(
          scheduler: scheduler,
          probe: probe,
          label: "first-\(index)",
          messageId: firstMessage
        )
      }
      + (0..<8).map { index in
        remoteImageTask(
          scheduler: scheduler,
          probe: probe,
          label: "second-\(index)",
          messageId: secondMessage
        )
      }

    await probe.waitUntilStarted(12)
    let snapshot = await probe.snapshot()

    #expect(snapshot.activeCount == 12)
    #expect(snapshot.maximumActiveCount == 12)
    #expect(snapshot.activeCountByMessage[firstMessage] == 6)
    #expect(snapshot.activeCountByMessage[secondMessage] == 6)

    await probe.releaseAll()
    for task in tasks {
      try await task.value
    }
  }

  @Test("Duplicate remote resources share one network task", .bug(id: 551))
  func duplicateRemoteResourcesShareOneTask() async throws {
    let scheduler = ProductAccountMailLoadScheduler()
    let connection = connectionId(provider: .gmail, value: "remote-deduplication")
    let firstMessage = messageId(connection: connection, value: "first")
    let secondMessage = messageId(connection: connection, value: "second")
    let url = try #require(URL(string: "https://images.example.com/shared.png"))
    let response = try #require(
      HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "image/png"]
      ))
    let probe = SharedRemoteResourceProbe(
      result: RemoteMessageContentNetworkLoad(
        data: Data([1, 2, 3]),
        response: response,
        receivedByteCount: 3
      ))
    let request = URLRequest(url: url)

    let firstLoad = Task {
      try await scheduler.remoteImageRequests.loadResource(
        for: request,
        messageId: firstMessage
      ) {
        await probe.load()
      }
    }
    await probe.waitUntilStarted()
    let secondLoad = Task {
      try await scheduler.remoteImageRequests.loadResource(
        for: request,
        messageId: secondMessage
      ) {
        await probe.load()
      }
    }
    for _ in 0..<100 {
      await Task.yield()
    }

    var startedCount = await probe.startedCount
    #expect(startedCount == 1)
    await probe.release()
    let firstResult = try await firstLoad.value
    let secondResult = try await secondLoad.value

    #expect(firstResult.data == Data([1, 2, 3]))
    #expect(secondResult.data == firstResult.data)
    startedCount = await probe.startedCount
    #expect(startedCount == 1)
  }

  private func bodyTask(
    scheduler: ProductAccountMailLoadScheduler,
    probe: MailLoadConcurrencyProbe,
    label: String,
    maximumConcurrentPipelines: Int = 2,
    messageId: StableProviderMessageIdentity
  ) -> Task<MailboxMessageBody, Error> {
    Task { @MainActor in
      try await scheduler.loadMessageBody(
        for: messageId,
        maximumConcurrentPipelines: maximumConcurrentPipelines
      ) {
        await probe.run(label: label, connectionId: messageId.connectionId)
        return MailboxMessageBody(text: label)
      }
    }
  }

  private func remoteImageTask(
    scheduler: ProductAccountMailLoadScheduler,
    probe: RemoteImageRequestProbe,
    label: String,
    messageId: StableProviderMessageIdentity
  ) -> Task<Void, Error> {
    Task {
      guard await scheduler.remoteImageRequests.acquire(for: messageId) else {
        throw CancellationError()
      }
      await probe.run(label: label, messageId: messageId)
      await scheduler.remoteImageRequests.release(for: messageId)
    }
  }

  private func connectionId(provider: MailProviderId, value: String) -> MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: provider,
        value: value
      )
    )
  }

  private func messageId(
    connection: MailboxConnectionId,
    value: String
  ) -> StableProviderMessageIdentity {
    StableProviderMessageIdentity(connectionId: connection, providerMessageId: value)
  }
}

private actor SharedRemoteResourceProbe {
  private let result: RemoteMessageContentNetworkLoad
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var startContinuations: [CheckedContinuation<Void, Never>] = []
  private(set) var startedCount = 0

  init(result: RemoteMessageContentNetworkLoad) {
    self.result = result
  }

  func load() async -> RemoteMessageContentNetworkLoad {
    startedCount += 1
    let continuations = startContinuations
    startContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
    return result
  }

  func waitUntilStarted() async {
    guard startedCount == 0 else { return }
    await withCheckedContinuation { continuation in
      startContinuations.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private actor MailLoadConcurrencyProbe {
  struct Snapshot: Sendable {
    let activeCount: Int
    let activeCountByConnection: [MailboxConnectionId: Int]
    let maximumActiveCount: Int
    let startedCount: Int
  }

  private var activeCount = 0
  private var activeCountByConnection: [MailboxConnectionId: Int] = [:]
  private var maximumActiveCount = 0
  private var released = false
  private var releaseContinuations: [String: CheckedContinuation<Void, Never>] = [:]
  private var releasedLabels: Set<String> = []
  private var startContinuations: [(count: Int, continuation: CheckedContinuation<Void, Never>)] =
    []
  private var starts: [String] = []

  func run(label: String, connectionId: MailboxConnectionId) async {
    activeCount += 1
    activeCountByConnection[connectionId, default: 0] += 1
    maximumActiveCount = max(maximumActiveCount, activeCount)
    starts.append(label)
    resumeSatisfiedStartContinuations()

    if !released, !releasedLabels.contains(label) {
      await withCheckedContinuation { continuation in
        releaseContinuations[label] = continuation
      }
    }

    activeCount -= 1
    let remaining = activeCountByConnection[connectionId, default: 1] - 1
    activeCountByConnection[connectionId] = remaining > 0 ? remaining : nil
  }

  func release(_ label: String) {
    releasedLabels.insert(label)
    releaseContinuations.removeValue(forKey: label)?.resume()
  }

  func releaseAll() {
    released = true
    let continuations = releaseContinuations.values
    releaseContinuations.removeAll()
    releasedLabels.formUnion(starts)
    for continuation in continuations {
      continuation.resume()
    }
  }

  func snapshot() -> Snapshot {
    Snapshot(
      activeCount: activeCount,
      activeCountByConnection: activeCountByConnection,
      maximumActiveCount: maximumActiveCount,
      startedCount: starts.count
    )
  }

  func startedLabels() -> [String] {
    starts
  }

  func waitUntilStarted(_ count: Int) async {
    guard starts.count < count else { return }
    await withCheckedContinuation { continuation in
      startContinuations.append((count, continuation))
    }
  }

  private func resumeSatisfiedStartContinuations() {
    let satisfied = startContinuations.filter { starts.count >= $0.count }
    startContinuations.removeAll { starts.count >= $0.count }
    for waiter in satisfied {
      waiter.continuation.resume()
    }
  }
}

private actor RemoteImageRequestProbe {
  struct Snapshot: Sendable {
    let activeCount: Int
    let activeCountByMessage: [StableProviderMessageIdentity: Int]
    let maximumActiveCount: Int
  }

  private var activeCount = 0
  private var activeCountByMessage: [StableProviderMessageIdentity: Int] = [:]
  private var maximumActiveCount = 0
  private var released = false
  private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
  private var startContinuations: [(count: Int, continuation: CheckedContinuation<Void, Never>)] =
    []
  private var startedCount = 0

  func run(label _: String, messageId: StableProviderMessageIdentity) async {
    activeCount += 1
    activeCountByMessage[messageId, default: 0] += 1
    maximumActiveCount = max(maximumActiveCount, activeCount)
    startedCount += 1
    resumeSatisfiedStartContinuations()

    if !released {
      await withCheckedContinuation { continuation in
        releaseContinuations.append(continuation)
      }
    }

    activeCount -= 1
    let remaining = activeCountByMessage[messageId, default: 1] - 1
    activeCountByMessage[messageId] = remaining > 0 ? remaining : nil
  }

  func releaseAll() {
    released = true
    let continuations = releaseContinuations
    releaseContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }

  func snapshot() -> Snapshot {
    Snapshot(
      activeCount: activeCount,
      activeCountByMessage: activeCountByMessage,
      maximumActiveCount: maximumActiveCount
    )
  }

  func waitUntilStarted(_ count: Int) async {
    guard startedCount < count else { return }
    await withCheckedContinuation { continuation in
      startContinuations.append((count, continuation))
    }
  }

  private func resumeSatisfiedStartContinuations() {
    let satisfied = startContinuations.filter { startedCount >= $0.count }
    startContinuations.removeAll { startedCount >= $0.count }
    for waiter in satisfied {
      waiter.continuation.resume()
    }
  }
}
