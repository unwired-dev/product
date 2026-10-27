#if os(iOS)
  import UIKit
#endif

// Bounded background time an admitted Send may use after its app leaves the foreground. Expiry
// withdraws permission before the system time ends, so no provider handoff starts after it; a
// request already handed over keeps its own outcome.
@MainActor final class DeliveryExecution {
  static let shared = DeliveryExecution()
  // Begins background time and returns its identifier, or nil when the system denies it. The
  // handler runs on the main thread just before the time expires.
  private let begin: (@escaping @MainActor () -> Void) -> Int?
  private let end: (Int) -> Void
  private var task: Int?
  private var waiter: ((Bool) -> Void)?

  init(
    begin: @escaping (@escaping @MainActor () -> Void) -> Int? = { expire in
      #if os(iOS)
        let task = UIApplication.shared.beginBackgroundTask(withName: "Send") {
          MainActor.assumeIsolated { expire() }
        }
        return task == .invalid ? nil : task.rawValue
      #else
        nil
      #endif
    },
    end: @escaping (Int) -> Void = { task in
      #if os(iOS)
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: task))
      #endif
    }
  ) {
    self.begin = begin
    self.end = end
  }

  // Whether background time currently permits a new provider handoff.
  var held: Bool { task != nil }

  // Holds background time until release or expiry. `ended` receives true after a release, false
  // when the time was denied or expired; a newer hold releases an older waiter.
  func hold(_ ended: @escaping (Bool) -> Void) {
    waiter?(true)
    waiter = ended
    guard task == nil else { return }
    task = begin { [weak self] in self?.finish(released: false) }
    if task == nil { finish(released: false) }
  }

  func release() { finish(released: true) }

  private func finish(released: Bool) {
    let task = self.task
    let waiter = self.waiter
    self.task = nil
    self.waiter = nil
    waiter?(released)
    if let task { end(task) }
  }
}
