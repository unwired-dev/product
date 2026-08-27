import CoreGraphics
import Foundation
import Observation

/// Per-message presentation state updated by the Thread reader's viewport scheduler.
@MainActor
@Observable
final class MailShellThreadBodyLoadRegistration {
  let messageId: StableProviderMessageIdentity
  private(set) var allowsAutomaticRemoteContent = false
  private(set) var loadPriority = MailLoadPriority.speculative
  private(set) var loadRequestId: UUID?

  init(messageId: StableProviderMessageIdentity) {
    self.messageId = messageId
  }

  func beginLoad(priority: MailLoadPriority) -> UUID {
    let requestId = UUID()
    loadPriority = priority
    loadRequestId = requestId
    return requestId
  }

  func finishLoad(_ requestId: UUID) {
    guard loadRequestId == requestId else { return }
    loadRequestId = nil
  }

  func cancelLoad() {
    loadRequestId = nil
  }

  func updateRemoteContentEligibility(_ isEligible: Bool) {
    allowsAutomaticRemoteContent = isEligible
  }
}
