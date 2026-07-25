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

  func testWaitForScheduledRetriesReturnsFalseWhenIdle() async {
    let service = OutboxDeliveryService(store: InMemoryOutboxDeliveryStore())

    let waitedForRetry = await service.waitForScheduledRetries()
    XCTAssertFalse(waitedForRetry)
  }

  func testScheduledHandoffDoesNotCancelItsDeliveryTask() async throws {
    let cancellationRecorder = DeliveryCancellationRecorder()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 1_000_000,
      store: InMemoryOutboxDeliveryStore()
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in
        await cancellationRecorder.record(Task.isCancelled)
      },
      reconcile: { _, _ in .notSent }
    )

    let waitedForRetry = await service.waitForScheduledRetries()
    let deliveryWasCancelled = await cancellationRecorder.wasCancelled()
    let deliveredAttempts = try await service.items(session: session)

    XCTAssertTrue(waitedForRetry)
    XCTAssertFalse(deliveryWasCancelled)
    XCTAssertEqual(deliveredAttempts.first?.state, .sent)
  }

  func testClearCancelsAnInFlightScheduledHandoff() async throws {
    let delivery = SuspendingDelivery()
    let store = InMemoryOutboxDeliveryStore()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 1_000_000,
      store: store
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in
        await delivery.started()
        do {
          try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch is CancellationError {
          await delivery.cancelled()
          throw CancellationError()
        }
      },
      reconcile: { _, _ in .notSent }
    )
    await delivery.waitUntilStarted()

    try await service.clear(session: session)
    await delivery.waitUntilCancelled()

    XCTAssertTrue(try store.load(productAccountId: session.productAccountId).isEmpty)
  }

  func testClearCancelsAnImmediatelyResumedHandoff() async throws {
    let delivery = SuspendingDelivery()
    let store = InMemoryOutboxDeliveryStore()
    let queuedService = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: store
    )
    _ = try await queuedService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .unknown }
    )
    let resumedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    let resumeTask = Task {
      try await resumedService.resume(
        connections: [connection],
        session: session,
        provider: { _, _, _ in
          await delivery.started()
          do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
          } catch is CancellationError {
            await delivery.cancelled()
            throw CancellationError()
          }
        },
        reconcile: { _, _ in .unknown }
      )
    }
    await delivery.waitUntilStarted()

    try await resumedService.clear(session: session)
    await delivery.waitUntilCancelled()
    _ = try? await resumeTask.value

    XCTAssertTrue(try store.load(productAccountId: session.productAccountId).isEmpty)
  }

  func testClearConnectionRemovesOnlyThatConnectionsQueuedAttempts() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
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
    try await service.clear(connection: connection, session: session)

    XCTAssertTrue(try store.load(productAccountId: session.productAccountId).isEmpty)
  }

  func testTerminalAttemptsRedactMessageContent() async throws {
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: InMemoryOutboxDeliveryStore()
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )

    let attempt = try await service.items(session: session).first
    XCTAssertEqual(attempt?.state, .sent)
    XCTAssertEqual(attempt?.message.body, "")
    XCTAssertEqual(attempt?.message.recipient, "")
    XCTAssertEqual(attempt?.message.subject, "")
  }

  func testCancellingAttemptRedactsMessageContent() async throws {
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: InMemoryOutboxDeliveryStore()
    )

    let queued = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    _ = try await service.cancel(queued.id, session: session)

    let attempt = try await service.items(session: session).first
    XCTAssertEqual(attempt?.state, .cancelled)
    XCTAssertEqual(attempt?.message.body, "")
    XCTAssertEqual(attempt?.message.recipient, "")
    XCTAssertEqual(attempt?.message.subject, "")
  }

  func testScheduledHandoffRetriesWhenPersistingItsClaimFails() async throws {
    let store = FailingOutboxDeliveryStore(failingSaveNumber: 2)
    let deliveries = DeliveryCounter()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 1_000_000,
      retryDelayNanoseconds: { _ in 1_000_000 },
      store: store
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )
    let waitedForRetry = await service.waitForScheduledRetries()
    let deliveryCount = await deliveries.currentValue()
    let attempts = try await service.items(session: session)

    XCTAssertTrue(waitedForRetry)
    XCTAssertEqual(deliveryCount, 1)
    XCTAssertEqual(attempts.first?.state, .sent)
  }

  func testResumeReturnsAfterSchedulingFutureRetry() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let seedService = OutboxDeliveryService(
      handoffDelayNanoseconds: 60_000_000_000,
      store: store
    )
    _ = try await seedService.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    var attempts = try store.load(productAccountId: session.productAccountId)
    attempts[0].state = .retrying
    attempts[0].nextRetryAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000) + 60_000
    try store.save(attempts, productAccountId: session.productAccountId)

    let service = OutboxDeliveryService(store: store)
    let completed = expectation(description: "resume returns after scheduling")
    Task {
      try? await service.resume(
        connections: [connection],
        session: session,
        provider: { _, _, _ in },
        reconcile: { _, _ in .notSent }
      )
      completed.fulfill()
    }

    await fulfillment(of: [completed], timeout: 1)
    try await service.clear(session: session)
  }

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

  func testEditKeepsOriginalScheduledHandoffWhenReplacementCannotBePersisted() async throws {
    let store = FailingOutboxDeliveryStore(failingSaveNumber: 2)
    let deliveries = DeliveryCounter()
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 1_000_000,
      store: store
    )

    let queued = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in await deliveries.increment() },
      reconcile: { _, _ in .notSent }
    )

    do {
      _ = try await service.edit(
        queued.id,
        message: OutgoingMessage(
          body: "Corrected body",
          recipient: self.message.recipient,
          subject: self.message.subject
        ),
        connection: self.connection,
        session: self.session,
        provider: { _, _, _ in await deliveries.increment() },
        reconcile: { _, _ in .notSent }
      )
      XCTFail("Expected replacement persistence to fail")
    } catch TestOutboxError.persistenceFailed {
      // The original scheduled handoff must remain active after this failure.
    } catch {
      XCTFail("Expected persistence failure, got \(error)")
    }

    let waitedForRetry = await service.waitForScheduledRetries()
    let deliveryCount = await deliveries.currentValue()
    let attempts = try await service.items(session: session)

    XCTAssertTrue(waitedForRetry)
    XCTAssertEqual(deliveryCount, 1)
    XCTAssertEqual(attempts.first?.state, .sent)
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

  func testRestartReconcilesProviderSuccessWhenPersistingSentStateFails() async throws {
    let store = FailingOutboxDeliveryStore(failingSaveNumber: 3)
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )

    do {
      _ = try await service.enqueue(
        message,
        connection: connection,
        session: session,
        provider: { _, _, _ in },
        reconcile: { _, _ in .notSent }
      )
      XCTFail("Persisting successful delivery should fail.")
    } catch TestOutboxError.persistenceFailed {}

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
    let attempts = try await restartedService.items(session: session)
    XCTAssertEqual(deliveryCount, 0)
    XCTAssertEqual(attempts.first?.state, .sent)
  }

  func testWaitingForScheduledRetryCompletesAfterDeliveryStateIsStored() async throws {
    let service = OutboxDeliveryService(
      handoffDelayNanoseconds: 1_000_000,
      store: InMemoryOutboxDeliveryStore()
    )

    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in .notSent }
    )
    let waited = await service.waitForScheduledRetries()

    let attempts = try await service.items(session: session)
    XCTAssertTrue(waited)
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

  func testReconciliationAuthorizationFailureRequiresUserAction() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let seedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
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
      failureDisposition: { _ in .userActionRequired },
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in throw TestOutboxError.deliveryRejected }
    )

    let attempts = try await service.items(session: session)
    XCTAssertEqual(attempts.first?.state, .userActionRequired)
    XCTAssertNil(attempts.first?.nextRetryAtMilliseconds)
  }

  func testRetryResumesPausedReconciliationWithOriginalIdempotencyKey() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let seedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    let seeded = try await seedService.enqueue(
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
      failureDisposition: { _ in .userActionRequired },
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in throw TestOutboxError.deliveryRejected }
    )

    let retried = try await service.retry(
      seeded.id,
      connection: connection,
      session: session,
      provider: { _, _, _ in XCTFail("Retry must reconcile before sending.") },
      reconcile: { _, _ in .sent }
    )

    XCTAssertEqual(retried.id, seeded.id)
    XCTAssertEqual(retried.idempotencyKey, seeded.idempotencyKey)
    XCTAssertEqual(retried.state, .sent)
  }

  func testEditRejectsPausedReconciliation() async throws {
    let store = InMemoryOutboxDeliveryStore()
    let seedService = OutboxDeliveryService(
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    let seeded = try await seedService.enqueue(
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
      failureDisposition: { _ in .userActionRequired },
      handoffDelayNanoseconds: immediateHandoffDelay,
      store: store
    )
    try await service.resume(
      connections: [connection],
      session: session,
      provider: { _, _, _ in },
      reconcile: { _, _ in throw TestOutboxError.deliveryRejected }
    )

    let pausedAttempts = try await service.items(session: session)
    let pausedAttempt = try XCTUnwrap(pausedAttempts.first)
    XCTAssertFalse(pausedAttempt.canEditOrCancel)

    do {
      _ = try await service.edit(
        seeded.id,
        message: message,
        connection: connection,
        session: session,
        provider: { _, _, _ in },
        reconcile: { _, _ in .notSent }
      )
      XCTFail("Editing must not replace an authorization-paused reconciliation.")
    } catch {
      XCTAssertEqual(error as? OutboxDeliveryError, .attemptCannotBeChanged)
    }
  }

  func testCollidedPendingAttemptReschedulesAfterReconciliationStops() async throws {
    let reconciliation = ReconciliationGate()
    let deliveredIds = DeliveryIdRecorder()
    let service = OutboxDeliveryService(
      failureDisposition: { _ in .ambiguous },
      handoffDelayNanoseconds: 1_000_000,
      maximumAttempts: 1,
      store: InMemoryOutboxDeliveryStore()
    )
    _ = try await service.enqueue(
      message,
      connection: connection,
      session: session,
      provider: { _, _, _ in throw URLError(.timedOut) },
      reconcile: { _, _ in
        await reconciliation.waitForRelease()
        throw TestOutboxError.deliveryRejected
      }
    )
    await reconciliation.waitUntilStarted()

    let second = try await service.enqueue(
      OutgoingMessage(
        body: "Second message",
        recipient: message.recipient,
        subject: message.subject
      ),
      connection: connection,
      session: session,
      provider: { _, idempotencyKey, _ in await deliveredIds.append(idempotencyKey) },
      reconcile: { _, _ in .notSent }
    )
    try await Task.sleep(nanoseconds: 20_000_000)
    await reconciliation.release()
    try await Task.sleep(nanoseconds: 250_000_000)

    let attempts = try await service.items(session: session)
    let secondAttempt = try XCTUnwrap(attempts.first(where: { $0.id == second.id }))
    let delivered = await deliveredIds.values
    XCTAssertEqual(secondAttempt.state, .sent)
    XCTAssertEqual(delivered, [second.idempotencyKey])
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
  case persistenceFailed
}

private final class FailingOutboxDeliveryStore: OutboxDeliveryPersisting, @unchecked Sendable {
  private let backingStore = InMemoryOutboxDeliveryStore()
  private let failingSaveNumber: Int
  private var saveCount = 0

  init(failingSaveNumber: Int) {
    self.failingSaveNumber = failingSaveNumber
  }

  func load(productAccountId: String) throws -> [OutgoingDeliveryAttempt] {
    try backingStore.load(productAccountId: productAccountId)
  }

  func save(
    _ attempts: [OutgoingDeliveryAttempt],
    productAccountId: String
  ) throws {
    saveCount += 1
    guard saveCount != failingSaveNumber else { throw TestOutboxError.persistenceFailed }
    try backingStore.save(attempts, productAccountId: productAccountId)
  }
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

private actor DeliveryCancellationRecorder {
  private var cancelled = false

  func record(_ value: Bool) {
    cancelled = value
  }

  func wasCancelled() -> Bool {
    cancelled
  }
}

private actor SuspendingDelivery {
  private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
  private var wasCancelled = false
  private var wasStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func started() {
    wasStarted = true
    for waiter in startWaiters {
      waiter.resume()
    }
    startWaiters.removeAll()
  }

  func cancelled() {
    wasCancelled = true
    for waiter in cancellationWaiters {
      waiter.resume()
    }
    cancellationWaiters.removeAll()
  }

  func waitUntilCancelled() async {
    guard !wasCancelled else { return }
    await withCheckedContinuation { cancellationWaiters.append($0) }
  }

  func waitUntilStarted() async {
    guard !wasStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
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

private actor ReconciliationGate {
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
