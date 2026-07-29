import Foundation

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
