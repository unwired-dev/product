import Foundation
import XCTest

@testable import unwired_mail

// swiftlint:disable file_length

@MainActor
// swiftlint:disable:next type_body_length
final class OutboxDeliveryServiceTests: XCTestCase {
  private let immediateHandoffDelay: UInt64 = 0
  private let connection = MailboxConnection(
    authorizationState: .authorized,
    capabilities: .gmail,
    connectedAt: 1_781_200_000_000,
    displayName: "sender@example.com",
    id: MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-001"
      )
    ),
    lastVerifiedAt: 1_781_200_000_100,
    productAccountId: ProductAccountId("product-account-001"),
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_200
  )
  private let message = OutgoingMessage(
    body: "Queued while offline",
    recipient: "reader@example.com",
    subject: "Offline delivery"
  )
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "product-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  func testOfflineDeliveryPersistsAndResumesAfterRestart() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_781_200_000))
    let firstService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )

    _ = try await firstService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )

    let queued = try await firstService.items(session: session)
    XCTAssertEqual(queued.count, 1)
    XCTAssertEqual(queued.first?.state, .retrying)

    clock.advance(by: 61)
    let restartedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 0 },
      store: store
    )
    let deliveredIds = DeliveryIdRecorder()
    try await restartedService.resume(
      connections: [connection],
      session: session,
      provider: { _, idempotencyKey, _ in await deliveredIds.append(idempotencyKey) },
      reconcile: { _, _ in .notSent }
    )

    let resumed = try await restartedService.items(session: session)
    let recordedIds = await deliveredIds.values
    XCTAssertEqual(recordedIds, [queued[0].idempotencyKey])
    XCTAssertEqual(resumed.first?.state, .sent)
  }

  func testAmbiguousFailureReconcilesSentWithoutDuplicateDelivery() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let deliveries = DeliveryCounter()
    let service = OutboxDeliveryService(
      failureDisposition: { _ in .ambiguous },
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in
        await deliveries.increment()
        throw URLError(.timedOut)
      },
      reconcile: { _, _ in .sent }
    )
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )

    let deliveryCount = await deliveries.value
    let attempts = try await service.items(session: session)
    XCTAssertEqual(deliveryCount, 1)
    XCTAssertEqual(attempts.first?.state, .sent)
  }

  func testPermanentFailureCanBeEditedIntoANewImmutableAttempt() async throws {
    let service = OutboxDeliveryService(
      failureDisposition: { _ in .permanent },
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: InMemoryOutboxDeliveryStore()
    )
    let failed = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw TestOutboxError.deliveryRejected },
      reconcile: { _, _ in .notSent }
    )

    XCTAssertEqual(failed.state, .failed)
    let replacement = try await service.edit(
      failed.id,
      message: OutgoingMessage(
        body: "Corrected body",
        recipient: message.recipient,
        subject: message.subject
      ),
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )

    let attempts = try await service.items(session: session)
    XCTAssertEqual(attempts.count, 2)
    XCTAssertEqual(attempts[0].state, .superseded)
    XCTAssertEqual(attempts[1].state, .sent)
    XCTAssertNotEqual(attempts[0].id, attempts[1].id)
    XCTAssertNotEqual(attempts[0].idempotencyKey, attempts[1].idempotencyKey)
    XCTAssertEqual(replacement.message.body, "Corrected body")
  }

  func testRetryLimitStopsTransientDelivery() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_781_200_000))
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      maximumAttempts: 2,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )

    clock.advance(by: 61)
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )

    let attempts = try await service.items(session: session)
    let attempt = try XCTUnwrap(attempts.first)
    XCTAssertEqual(attempt.attemptCount, 2)
    XCTAssertEqual(attempt.state, .failed)
    XCTAssertNil(attempt.nextRetryAtMilliseconds)
  }

  func testRestartReconcilesInterruptedHandoffWithoutResending() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let firstService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    _ = try await firstService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )
    var persisted = try store.load(productAccountId: session.productAccountId)
    persisted[0].state = .handingOff
    try store.save(persisted, productAccountId: session.productAccountId)
    let deliveries = DeliveryCounter()
    let restartedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )

    try await restartedService.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .sent }
    )

    let deliveryCount = await deliveries.currentValue()
    XCTAssertEqual(deliveryCount, 0)
    let attempts = try await restartedService.items(session: session)
    XCTAssertEqual(attempts.first?.state, .sent)
  }

  func testTemporaryReconciliationFailureRetriesConfirmationWithoutResending() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_781_200_000))
    let seedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    _ = try await seedService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )
    var persisted = try store.load(productAccountId: session.productAccountId)
    persisted[0].state = .handingOff
    try store.save(persisted, productAccountId: session.productAccountId)
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    let deliveries = DeliveryCounter()
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in throw URLError(.notConnectedToInternet) }
    )
    let reconcilingAttempts = try await service.items(session: session)
    XCTAssertEqual(reconcilingAttempts.first?.state, .reconciling)

    clock.advance(by: 61)
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .sent }
    )

    let deliveryCount = await deliveries.currentValue()
    XCTAssertEqual(deliveryCount, 0)
    let sentAttempts = try await service.items(session: session)
    XCTAssertEqual(sentAttempts.first?.state, .sent)
  }

  func testRestartDoesNotSendRetryAfterMaximumAge() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let clock = LockedOutboxClock(Date(timeIntervalSince1970: 1_781_200_000))
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      now: { clock.now() },
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: store
    )
    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )
    clock.advance(by: 8 * 24 * 60 * 60)
    let deliveries = DeliveryCounter()

    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )

    let deliveryCount = await deliveries.currentValue()
    XCTAssertEqual(deliveryCount, 0)
    let failedAttempts = try await service.items(session: session)
    XCTAssertEqual(failedAttempts.first?.state, .failed)
  }

  func testUnknownOutcomeRequiresExplicitResolutionBeforeRetry() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    var attempt = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.timedOut) },
      reconcile: { _, _ in .unknown }
    )
    XCTAssertEqual(attempt.state, .outcomeUnknown)
    XCTAssertFalse(attempt.state.canEditOrCancel)

    attempt = try await service.resolveUnknownOutcome(
      attempt.id,
      asDelivered: false,
      session: session
    )

    XCTAssertEqual(attempt.state, .failed)
    XCTAssertTrue(attempt.state.canEditOrCancel)
  }

  func testEditAndCancelLoseRaceOnceProviderHandoffStarts() async throws {
    let gate = DeliveryHandoffGate()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: InMemoryOutboxDeliveryStore()
    )
    let deliveryTask = Task {
      try await service.enqueue(
        message,
        connection: connection,
        session: session,
        provider: { _, _, _ in await gate.waitForRelease() },
        reconcile: { _, _ in .notSent }
      )
    }
    await gate.waitUntilStarted()
    let attempts = try await service.items(session: session)
    let handingOff = try XCTUnwrap(attempts.first)
    XCTAssertEqual(handingOff.state, .handingOff)

    do {
      _ = try await service.cancel(handingOff.id, session: session)
      XCTFail("Cancelling must not replace an attempt during provider handoff.")
    } catch {
      XCTAssertEqual(error as? OutboxDeliveryError, .attemptCannotBeChanged)
    }
    do {
      _ = try await service.edit(
        handingOff.id,
        message: message,
        connection: connection,
        session: session,
        provider: { _, _, _ in },
        reconcile: { _, _ in .notSent }
      )
      XCTFail("Editing must not replace an attempt during provider handoff.")
    } catch {
      XCTAssertEqual(error as? OutboxDeliveryError, .attemptCannotBeChanged)
    }

    await gate.release()
    let delivered = try await deliveryTask.value
    XCTAssertEqual(delivered.state, .sent)
  }

  func testReceiveOnlyConnectionCannotEnterOutbox() async throws {
    let receiveOnlyConnection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: .imapRead,
      connectedAt: connection.connectedAt,
      displayName: connection.displayName,
      id: connection.id,
      lastVerifiedAt: connection.lastVerifiedAt,
      productAccountId: connection.productAccountId,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: InMemoryOutboxDeliveryStore()
    )

    do {
      _ = try await service.enqueue(
        message,
        connection: receiveOnlyConnection,
        session: session,
        provider: { _, _, _ in },
        reconcile: { _, _ in .notSent }
      )
      XCTFail("Receive-only connections must not be used for sending.")
    } catch {
      XCTAssertEqual(error as? MailboxConnectionAdapterError, .authorizationRequired)
    }
  }

  func testFileStoreEncryptsMessageContentAndClearRemovesIt() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      retryDelayNanoseconds: { _ in 60_000_000_000 },
      store: FileOutboxDeliveryStore(
        keyMaterialStore: keyStore,
        rootDirectory: rootDirectory
      )
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.notConnectedToInternet) },
      reconcile: { _, _ in .notSent }
    )

    let fileURL = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(
        at: rootDirectory,
        includingPropertiesForKeys: nil
      ).first
    )
    let persistedText = try XCTUnwrap(
      String(data: try Data(contentsOf: fileURL), encoding: .utf8)
    )
    XCTAssertFalse(persistedText.contains(message.body))

    try await service.clear(session: session)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(
        at: rootDirectory,
        includingPropertiesForKeys: nil
      ).isEmpty
    )
  }
}

private final class InMemoryOutboxDeliveryStore:
  OutboxDeliveryPersisting, @unchecked Sendable
{
  private var attemptsByProductAccountId: [String: [OutgoingDeliveryAttempt]] = [:]

  func load(productAccountId: String) throws -> [OutgoingDeliveryAttempt] {
    attemptsByProductAccountId[productAccountId] ?? []
  }

  func save(
    _ attempts: [OutgoingDeliveryAttempt],
    productAccountId: String
  ) throws {
    attemptsByProductAccountId[productAccountId] = attempts
  }
}

private enum TestOutboxError: Error {
  case deliveryRejected
}

private actor DeliveryCounter {
  private(set) var value = 0

  func increment() {
    value += 1
  }

  func currentValue() -> Int {
    value
  }
}

private actor DeliveryIdRecorder {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

private actor DeliveryHandoffGate {
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func waitForRelease() async {
    started = true
    for waiter in startWaiters {
      waiter.resume()
    }
    startWaiters.removeAll()
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private final class LockedOutboxClock: @unchecked Sendable {
  private var date: Date
  private let lock = NSLock()

  init(_ date: Date) {
    self.date = date
  }

  func advance(by interval: TimeInterval) {
    lock.withLock {
      date = date.addingTimeInterval(interval)
    }
  }

  func now() -> Date {
    lock.withLock { date }
  }
}
