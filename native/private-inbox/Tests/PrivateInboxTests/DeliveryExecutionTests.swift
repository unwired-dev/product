import Testing

@testable import PrivateInbox

// Background time an admitted Send holds: expiry withdraws handoff permission before the system
// time ends, and denial never counts as permission.
@MainActor struct DeliveryExecutionTests {
  @Test func expiryWithdrawsPermissionBeforeEndingTheTime() {
    var expire: (@MainActor () -> Void)?
    var ended: [Int] = []
    var heldWhenEnded: [Bool] = []
    var results: [Bool] = []
    var execution: DeliveryExecution!
    execution = DeliveryExecution(
      begin: { handler in
        expire = handler
        return 7
      },
      end: { task in
        ended.append(task)
        heldWhenEnded.append(execution.held)
      })

    execution.hold { results.append($0) }
    #expect(execution.held)
    expire?()

    #expect(!execution.held)
    #expect(results == [false])
    #expect(ended == [7])
    #expect(heldWhenEnded == [false])
    // A late expiry or release of time already ended changes nothing.
    expire?()
    execution.release()
    #expect(results == [false])
    #expect(ended == [7])
  }

  @Test func deniedTimeEndsTheHoldAtOnce() {
    var ended: [Int] = []
    var results: [Bool] = []
    let execution = DeliveryExecution(begin: { _ in nil }, end: { ended.append($0) })

    execution.hold { results.append($0) }

    #expect(!execution.held)
    #expect(results == [false])
    #expect(ended.isEmpty)
  }

  @Test func releaseEndsTheTimeAndANewerHoldReplacesTheWaiter() {
    var begun = 0
    var ended: [Int] = []
    var results: [String] = []
    let execution = DeliveryExecution(
      begin: { _ in
        begun += 1
        return begun
      },
      end: { ended.append($0) })

    execution.hold { results.append("first \($0)") }
    execution.hold { results.append("second \($0)") }
    #expect(results == ["first true"])
    #expect(begun == 1)
    execution.release()

    #expect(!execution.held)
    #expect(results == ["first true", "second true"])
    #expect(ended == [1])
  }
}
