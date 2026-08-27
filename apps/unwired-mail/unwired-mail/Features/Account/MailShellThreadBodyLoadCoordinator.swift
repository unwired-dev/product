import CoreGraphics
import Foundation

/// Owns viewport priority and load cancellation for one expanded Thread reader.
@MainActor
final class MailShellThreadBodyLoadCoordinator {
  static let maximumConcurrentLoads = 2

  private var activeRequests: [StableProviderMessageIdentity: UUID] = [:]
  private var completedMessageIds: Set<StableProviderMessageIdentity> = []
  private var frames: [StableProviderMessageIdentity: CGRect] = [:]
  private var isActive = false
  private var messageOrder: [StableProviderMessageIdentity: Int] = [:]
  private var queuedMessageIds: Set<StableProviderMessageIdentity> = []
  private var registrations: [StableProviderMessageIdentity: MailShellThreadBodyLoadRegistration] =
    [:]
  private var viewportFrame = CGRect.zero

  func registration(
    for messageId: StableProviderMessageIdentity
  ) -> MailShellThreadBodyLoadRegistration {
    if let registration = registrations[messageId] { return registration }
    let registration = MailShellThreadBodyLoadRegistration(messageId: messageId)
    registrations[messageId] = registration
    queuedMessageIds.insert(messageId)
    return registration
  }

  func synchronize(_ messageIds: [StableProviderMessageIdentity]) {
    let retainedMessageIds = Set(messageIds)
    let removedMessageIds = registrations.keys.filter { !retainedMessageIds.contains($0) }
    for messageId in removedMessageIds {
      registrations[messageId]?.cancelLoad()
      registrations[messageId] = nil
      frames[messageId] = nil
      activeRequests[messageId] = nil
      completedMessageIds.remove(messageId)
      queuedMessageIds.remove(messageId)
    }
    messageOrder = Dictionary(
      uniqueKeysWithValues: messageIds.enumerated().map { ($0.element, $0.offset) }
    )
    for messageId in messageIds where !completedMessageIds.contains(messageId) {
      _ = registration(for: messageId)
      if activeRequests[messageId] == nil {
        queuedMessageIds.insert(messageId)
      }
    }
    reprioritize()
  }

  func activate() {
    isActive = true
    reprioritize()
  }

  func reset() {
    isActive = false
    for registration in registrations.values {
      registration.cancelLoad()
      registration.updateRemoteContentEligibility(false)
    }
    activeRequests.removeAll()
    completedMessageIds.removeAll()
    frames.removeAll()
    messageOrder.removeAll()
    queuedMessageIds.removeAll()
    registrations.removeAll()
    viewportFrame = .zero
  }

  func updateViewport(_ frame: CGRect) {
    viewportFrame = frame
    updateRemoteContentEligibility()
    reprioritize()
  }

  /// Updates one message's measured frame and returns the scroll compensation for growth above
  /// the viewport.
  @discardableResult
  func updateFrame(
    _ frame: CGRect,
    for messageId: StableProviderMessageIdentity
  ) -> CGFloat {
    let previousFrame = frames[messageId]
    frames[messageId] = frame
    registration(for: messageId).updateRemoteContentEligibility(
      isInsideRemoteContentMargin(frame)
    )
    reprioritize()
    guard let previousFrame else { return 0 }
    return Self.scrollOffsetAdjustment(
      previousFrame: previousFrame,
      newFrame: frame,
      viewportFrame: viewportFrame
    )
  }

  func finishLoad(
    for messageId: StableProviderMessageIdentity,
    requestId: UUID,
    shouldRetry: Bool
  ) {
    guard activeRequests[messageId] == requestId else { return }
    activeRequests[messageId] = nil
    registrations[messageId]?.finishLoad(requestId)
    if shouldRetry {
      queuedMessageIds.insert(messageId)
    } else {
      completedMessageIds.insert(messageId)
      queuedMessageIds.remove(messageId)
    }
    reprioritize()
  }

  func retry(_ messageId: StableProviderMessageIdentity) {
    completedMessageIds.remove(messageId)
    queuedMessageIds.insert(messageId)
    reprioritize()
  }

  static func scrollOffsetAdjustment(
    previousFrame: CGRect,
    newFrame: CGRect,
    viewportFrame: CGRect
  ) -> CGFloat {
    guard isMeasurable(previousFrame), isMeasurable(newFrame), isMeasurable(viewportFrame),
      previousFrame.maxY <= viewportFrame.minY
    else { return 0 }
    return newFrame.height - previousFrame.height
  }

  private func reprioritize() {
    guard isActive, Self.isMeasurable(viewportFrame) else { return }
    promoteNewlyVisibleLoads()
    preemptOffscreenLoadsForVisibleWork()
    while activeRequests.count < Self.maximumConcurrentLoads,
      let messageId = nextQueuedMessageId(),
      let registration = registrations[messageId]
    {
      queuedMessageIds.remove(messageId)
      let priority: MailLoadPriority = isVisible(frames[messageId]) ? .interactive : .speculative
      activeRequests[messageId] = registration.beginLoad(priority: priority)
    }
  }

  private func promoteNewlyVisibleLoads() {
    let promotedMessageIds = activeRequests.keys.filter { messageId in
      isVisible(frames[messageId])
        && registrations[messageId]?.loadPriority == .speculative
    }
    for messageId in promotedMessageIds {
      activeRequests[messageId] = nil
      registrations[messageId]?.cancelLoad()
      queuedMessageIds.insert(messageId)
    }
  }

  private func preemptOffscreenLoadsForVisibleWork() {
    guard activeRequests.count >= Self.maximumConcurrentLoads,
      queuedMessageIds.contains(where: { isVisible(frames[$0]) })
    else { return }
    let offscreenActiveMessageIds = activeRequests.keys.filter {
      !isVisible(frames[$0])
    }
    guard
      let messageId = offscreenActiveMessageIds.max(by: {
        distanceFromViewport(frames[$0]) < distanceFromViewport(frames[$1])
      })
    else { return }
    activeRequests[messageId] = nil
    registrations[messageId]?.cancelLoad()
    queuedMessageIds.insert(messageId)
  }

  private func nextQueuedMessageId() -> StableProviderMessageIdentity? {
    let orderedMessageIds =
      queuedMessageIds
      .filter { Self.isMeasurable(frames[$0] ?? .zero) }
      .sorted { first, second in
        let firstIsVisible = isVisible(frames[first])
        let secondIsVisible = isVisible(frames[second])
        if firstIsVisible != secondIsVisible { return firstIsVisible }
        let firstDistance = distanceFromViewport(frames[first])
        let secondDistance = distanceFromViewport(frames[second])
        if firstDistance != secondDistance { return firstDistance < secondDistance }
        return messageOrder[first, default: .max] < messageOrder[second, default: .max]
      }
    if let visibleMessageId = orderedMessageIds.first(where: { isVisible(frames[$0]) }) {
      return visibleMessageId
    }
    guard activeRequests.keys.contains(where: { isVisible(frames[$0]) }) == false else {
      return nil
    }
    return orderedMessageIds.first
  }

  private func updateRemoteContentEligibility() {
    for (messageId, registration) in registrations {
      registration.updateRemoteContentEligibility(
        isInsideRemoteContentMargin(frames[messageId])
      )
    }
  }

  private func isVisible(_ frame: CGRect?) -> Bool {
    guard let frame, Self.isMeasurable(frame) else { return false }
    let intersection = frame.intersection(viewportFrame)
    return !intersection.isNull && intersection.width > 0 && intersection.height > 0
  }

  private func isInsideRemoteContentMargin(_ frame: CGRect?) -> Bool {
    guard let frame, Self.isMeasurable(frame), Self.isMeasurable(viewportFrame) else {
      return false
    }
    let prefetchFrame = viewportFrame.insetBy(dx: 0, dy: -viewportFrame.height)
    let intersection = frame.intersection(prefetchFrame)
    return !intersection.isNull && intersection.width > 0 && intersection.height > 0
  }

  private func distanceFromViewport(_ frame: CGRect?) -> CGFloat {
    guard let frame, Self.isMeasurable(frame) else { return .greatestFiniteMagnitude }
    if isVisible(frame) { return 0 }
    if frame.maxY < viewportFrame.minY { return viewportFrame.minY - frame.maxY }
    return max(0, frame.minY - viewportFrame.maxY)
  }

  private static func isMeasurable(_ frame: CGRect) -> Bool {
    !frame.isNull && frame.width > 0 && frame.height > 0
  }
}
