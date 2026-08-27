import Foundation
import Testing

@testable import unwired_mail

@MainActor
struct MailShellThreadBodyLoadCoordinatorTests {
  @Test("Visible bodies start before off-screen bodies", .bug(id: 559))
  func visibleBodiesStartFirst() {
    let fixture = Fixture()
    let coordinator = MailShellThreadBodyLoadCoordinator()
    coordinator.synchronize(fixture.messageIds)
    coordinator.updateViewport(CGRect(x: 0, y: 0, width: 600, height: 500))
    coordinator.updateFrame(CGRect(x: 0, y: 900, width: 600, height: 200), for: fixture.first)
    coordinator.updateFrame(CGRect(x: 0, y: 100, width: 600, height: 200), for: fixture.second)
    coordinator.updateFrame(CGRect(x: 0, y: 350, width: 600, height: 200), for: fixture.third)

    coordinator.activate()

    #expect(coordinator.registration(for: fixture.first).loadRequestId == nil)
    #expect(coordinator.registration(for: fixture.second).loadRequestId != nil)
    #expect(coordinator.registration(for: fixture.third).loadRequestId != nil)
    #expect(coordinator.registration(for: fixture.second).loadPriority == .interactive)
  }

  @Test("Off-screen bodies continue by distance after visible work", .bug(id: 559))
  func offscreenBodiesContinueByDistance() throws {
    let fixture = Fixture()
    let fourth = fixture.messageId("fourth")
    let coordinator = MailShellThreadBodyLoadCoordinator()
    coordinator.synchronize(fixture.messageIds + [fourth])
    coordinator.updateViewport(CGRect(x: 0, y: 0, width: 600, height: 500))
    coordinator.updateFrame(CGRect(x: 0, y: 1_100, width: 600, height: 200), for: fixture.first)
    coordinator.updateFrame(CGRect(x: 0, y: 100, width: 600, height: 200), for: fixture.second)
    coordinator.updateFrame(CGRect(x: 0, y: 600, width: 600, height: 200), for: fixture.third)
    coordinator.updateFrame(CGRect(x: 0, y: 1_600, width: 600, height: 200), for: fourth)
    coordinator.activate()
    let visibleRequest = try #require(
      coordinator.registration(for: fixture.second).loadRequestId
    )
    #expect(coordinator.registration(for: fixture.third).loadRequestId == nil)

    coordinator.finishLoad(
      for: fixture.second,
      requestId: visibleRequest,
      shouldRetry: false
    )

    #expect(coordinator.registration(for: fixture.first).loadRequestId != nil)
    #expect(coordinator.registration(for: fixture.third).loadRequestId != nil)
    #expect(coordinator.registration(for: fourth).loadRequestId == nil)
    #expect(coordinator.registration(for: fixture.first).loadPriority == .speculative)
  }

  @Test("Scrolling preempts off-screen loads for newly visible bodies", .bug(id: 559))
  func scrollingReprioritizesImmediately() throws {
    let fixture = Fixture()
    let coordinator = MailShellThreadBodyLoadCoordinator()
    coordinator.synchronize(fixture.messageIds)
    coordinator.updateViewport(CGRect(x: 0, y: 0, width: 600, height: 500))
    coordinator.updateFrame(CGRect(x: 0, y: 100, width: 600, height: 200), for: fixture.first)
    coordinator.updateFrame(CGRect(x: 0, y: 600, width: 600, height: 200), for: fixture.second)
    coordinator.updateFrame(CGRect(x: 0, y: 900, width: 600, height: 200), for: fixture.third)
    coordinator.activate()
    let firstRequest = try #require(coordinator.registration(for: fixture.first).loadRequestId)
    coordinator.finishLoad(for: fixture.first, requestId: firstRequest, shouldRetry: false)
    let secondRequest = try #require(coordinator.registration(for: fixture.second).loadRequestId)
    let offscreenRequest = try #require(
      coordinator.registration(for: fixture.third).loadRequestId
    )

    let fourth = fixture.messageId("fourth")
    coordinator.synchronize(fixture.messageIds + [fourth])
    coordinator.updateFrame(CGRect(x: 0, y: 1_300, width: 600, height: 200), for: fourth)
    coordinator.updateViewport(CGRect(x: 0, y: 1_250, width: 600, height: 500))

    #expect(coordinator.registration(for: fixture.second).loadRequestId == nil)
    #expect(coordinator.registration(for: fixture.second).loadPriority == .speculative)
    #expect(coordinator.registration(for: fixture.third).loadRequestId == offscreenRequest)
    #expect(coordinator.registration(for: fourth).loadRequestId != nil)
    #expect(coordinator.registration(for: fourth).loadPriority == .interactive)
  }

  @Test("Remote content becomes eligible within one viewport margin", .bug(id: 559))
  func remoteContentUsesOneViewportMargin() {
    let fixture = Fixture()
    let coordinator = MailShellThreadBodyLoadCoordinator()
    coordinator.synchronize([fixture.first, fixture.second])
    coordinator.updateViewport(CGRect(x: 0, y: 500, width: 600, height: 400))
    coordinator.updateFrame(CGRect(x: 0, y: 0, width: 600, height: 50), for: fixture.first)
    coordinator.updateFrame(CGRect(x: 0, y: 1_250, width: 600, height: 100), for: fixture.second)

    #expect(
      coordinator.registration(for: fixture.first).allowsAutomaticRemoteContent == false
    )
    #expect(coordinator.registration(for: fixture.second).allowsAutomaticRemoteContent)
  }

  @Test("Visible speculative loads are promoted without replacing their request", .bug(id: 559))
  func visibleSpeculativeLoadPromotesInPlace() throws {
    let fixture = Fixture()
    let coordinator = MailShellThreadBodyLoadCoordinator()
    coordinator.synchronize([fixture.first])
    coordinator.updateViewport(CGRect(x: 0, y: 0, width: 600, height: 500))
    coordinator.updateFrame(CGRect(x: 0, y: 700, width: 600, height: 200), for: fixture.first)
    coordinator.activate()
    let speculativeRequest = try #require(
      coordinator.registration(for: fixture.first).loadRequestId
    )

    coordinator.updateViewport(CGRect(x: 0, y: 600, width: 600, height: 500))

    #expect(coordinator.registration(for: fixture.first).loadRequestId == speculativeRequest)
    #expect(coordinator.registration(for: fixture.first).loadPriority == .interactive)
  }

  @Test("Restoring an unchanged viewport activates a replacement Thread", .bug(id: 559))
  func restoredViewportActivatesReplacementThread() {
    let fixture = Fixture()
    let replacement = fixture.messageId("replacement")
    let viewport = CGRect(x: 0, y: 0, width: 600, height: 500)
    let coordinator = MailShellThreadBodyLoadCoordinator()
    coordinator.synchronize([fixture.first])
    coordinator.updateViewport(viewport)
    coordinator.updateFrame(CGRect(x: 0, y: 100, width: 600, height: 200), for: fixture.first)
    coordinator.activate()

    coordinator.reset()
    coordinator.updateViewport(viewport)
    coordinator.synchronize([replacement])
    coordinator.updateFrame(CGRect(x: 0, y: 100, width: 600, height: 200), for: replacement)
    coordinator.activate()

    #expect(coordinator.registration(for: replacement).loadRequestId != nil)
    #expect(coordinator.registration(for: replacement).loadPriority == .interactive)
  }

  @Test("A retryable finish immediately schedules a replacement request", .bug(id: 559))
  func retryableFinishSchedulesReplacementRequest() throws {
    let (coordinator, fixture) = activeSingleMessageCoordinator()
    let request = try #require(coordinator.registration(for: fixture.first).loadRequestId)

    coordinator.finishLoad(for: fixture.first, requestId: request, shouldRetry: true)

    let replacement = try #require(coordinator.registration(for: fixture.first).loadRequestId)
    #expect(replacement != request)
  }

  @Test("Manual retry schedules a completed message again", .bug(id: 559))
  func manualRetrySchedulesCompletedMessage() throws {
    let (coordinator, fixture) = activeSingleMessageCoordinator()
    let request = try #require(coordinator.registration(for: fixture.first).loadRequestId)
    coordinator.finishLoad(for: fixture.first, requestId: request, shouldRetry: false)
    #expect(coordinator.registration(for: fixture.first).loadRequestId == nil)

    coordinator.retry(fixture.first)

    #expect(coordinator.registration(for: fixture.first).loadRequestId != nil)
  }

  @Test("Reset cancels loads and revokes automatic remote content", .bug(id: 559))
  func resetRevokesLoadingAndRemoteContent() {
    let (coordinator, fixture) = activeSingleMessageCoordinator()
    let registration = coordinator.registration(for: fixture.first)
    #expect(registration.loadRequestId != nil)
    #expect(registration.allowsAutomaticRemoteContent)

    coordinator.reset()

    #expect(registration.loadRequestId == nil)
    #expect(registration.allowsAutomaticRemoteContent == false)
  }

  @Test("Growth above the viewport preserves the visible offset", .bug(id: 559))
  func growthAboveViewportProducesScrollCompensation() {
    let adjustment = MailShellThreadBodyLoadCoordinator.scrollOffsetAdjustment(
      previousFrame: CGRect(x: 0, y: 100, width: 600, height: 100),
      newFrame: CGRect(x: 0, y: 100, width: 600, height: 260),
      viewportFrame: CGRect(x: 0, y: 500, width: 600, height: 400)
    )
    let visibleAdjustment = MailShellThreadBodyLoadCoordinator.scrollOffsetAdjustment(
      previousFrame: CGRect(x: 0, y: 450, width: 600, height: 100),
      newFrame: CGRect(x: 0, y: 450, width: 600, height: 260),
      viewportFrame: CGRect(x: 0, y: 500, width: 600, height: 400)
    )

    #expect(adjustment == 160)
    #expect(visibleAdjustment == 0)
  }

  private func activeSingleMessageCoordinator() -> (
    MailShellThreadBodyLoadCoordinator,
    Fixture
  ) {
    let fixture = Fixture()
    let coordinator = MailShellThreadBodyLoadCoordinator()
    coordinator.synchronize([fixture.first])
    coordinator.updateViewport(CGRect(x: 0, y: 0, width: 600, height: 500))
    coordinator.updateFrame(CGRect(x: 0, y: 100, width: 600, height: 200), for: fixture.first)
    coordinator.activate()
    return (coordinator, fixture)
  }

  private struct Fixture {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "viewport"
      )
    )

    var first: StableProviderMessageIdentity { messageId("first") }
    var second: StableProviderMessageIdentity { messageId("second") }
    var third: StableProviderMessageIdentity { messageId("third") }
    var messageIds: [StableProviderMessageIdentity] { [first, second, third] }

    func messageId(_ value: String) -> StableProviderMessageIdentity {
      StableProviderMessageIdentity(connectionId: connectionId, providerMessageId: value)
    }
  }
}
