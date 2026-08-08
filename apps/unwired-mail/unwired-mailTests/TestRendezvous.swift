import Foundation
import Testing

func requireValue<T>(
  _ expression: @autoclosure () throws -> T?,
  _ comment: @autoclosure () -> Comment? = nil,
  sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
  try #require(try expression(), comment(), sourceLocation: sourceLocation)
}

final class TestExpectation: @unchecked Sendable {
  let description: String

  private let lock = NSLock()
  private var fulfillmentCount = 0
  private var requiredFulfillmentCount = 1
  private var inverted = false

  init(description: String) {
    self.description = description
  }

  var expectedFulfillmentCount: Int {
    get { lock.withLock { requiredFulfillmentCount } }
    set { lock.withLock { requiredFulfillmentCount = newValue } }
  }

  var isInverted: Bool {
    get { lock.withLock { inverted } }
    set { lock.withLock { inverted = newValue } }
  }

  func fulfill() {
    let isOverfulfilled = lock.withLock {
      fulfillmentCount += 1
      return fulfillmentCount > requiredFulfillmentCount
    }
    if isOverfulfilled {
      Issue.record("Expectation over-fulfilled: \(description)")
    }
  }

  fileprivate var state: TestExpectationState {
    lock.withLock {
      TestExpectationState(
        isFulfilled: fulfillmentCount == requiredFulfillmentCount,
        isInverted: inverted,
        isOverfulfilled: fulfillmentCount > requiredFulfillmentCount
      )
    }
  }
}

private struct TestExpectationState {
  let isFulfilled: Bool
  let isInverted: Bool
  let isOverfulfilled: Bool
}

func expectation(description: String) -> TestExpectation {
  TestExpectation(description: description)
}

func fulfillment(
  of expectations: [TestExpectation],
  timeout: TimeInterval = 10
) async {
  let deadline = Date().addingTimeInterval(timeout)

  while true {
    let states = expectations.map { ($0, $0.state) }
    if states.contains(where: { $0.1.isOverfulfilled }) {
      return
    }
    if let unexpected = states.first(where: { $0.1.isInverted && $0.1.isFulfilled }) {
      Issue.record("Inverted expectation fulfilled: \(unexpected.0.description)")
      return
    }

    let nonInverted = states.filter { !$0.1.isInverted }
    let includesInverted = nonInverted.count != states.count
    if !includesInverted, nonInverted.allSatisfy({ $0.1.isFulfilled }) {
      return
    }
    if Date() >= deadline {
      for (expectation, state) in states where !state.isInverted && !state.isFulfilled {
        Issue.record("Expectation timed out: \(expectation.description)")
      }
      return
    }

    if Task.isCancelled { return }
    do {
      try await Task.sleep(for: .milliseconds(1))
    } catch is CancellationError {
      return
    } catch {
      Issue.record("Expectation polling failed: \(error)")
      return
    }
  }
}

@Suite(.serialized)
final class TestExpectationTests {
  @Test
  func testOverFulfillmentRecordsAnIssue() async {
    let testExpectation = expectation(description: "single callback")

    testExpectation.fulfill()
    withKnownIssue {
      testExpectation.fulfill()
    }
    await fulfillment(of: [testExpectation], timeout: 0)
  }

  @Test
  func testFulfillmentReturnsAfterCancellation() async {
    let pending = expectation(description: "never fulfilled")
    let clock = ContinuousClock()
    let startedAt = clock.now
    let waiter = Task {
      await fulfillment(of: [pending], timeout: 1)
    }

    waiter.cancel()
    await waiter.value

    #expect(startedAt.duration(to: clock.now) < .milliseconds(100))
  }
}

actor TestRendezvous {
  private var held = false
  private var heldWaiters: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func hold() async {
    guard !released else { return }
    if !held {
      held = true
      let waiters = heldWaiters
      heldWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
    }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }

  func waitUntilHeld() async {
    guard !held, !released else { return }
    await withCheckedContinuation { continuation in
      heldWaiters.append(continuation)
    }
  }

  func release() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    let pendingHeldWaiters = heldWaiters
    heldWaiters.removeAll()
    for waiter in pendingHeldWaiters {
      waiter.resume()
    }
  }
}

actor TestBarrier {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private let participantCount: Int

  init(participantCount: Int) {
    self.participantCount = participantCount
  }

  func arriveAndWait() async {
    guard continuations.count + 1 < participantCount else {
      let waiting = continuations
      continuations.removeAll()
      for continuation in waiting {
        continuation.resume()
      }
      return
    }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }
}

actor TestFlag {
  private(set) var value = false

  func set() {
    value = true
  }
}
