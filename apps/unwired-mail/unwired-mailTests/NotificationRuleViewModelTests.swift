import XCTest

@testable import unwired_mail

@MainActor
final class NotificationRuleViewModelTests: XCTestCase {
  func testReplaysPruneQueuedDuringRuleLoad() async {
    let service = DelayedNotificationRuleSync(
      rules: NotificationRules(categoryIds: ["custom-category-primary", "system:flights"])
    )
    let viewModel = NotificationRuleViewModel(
      authorization: StubNotificationAuthorization(),
      service: service,
      session: ProductAccountSessionSnapshot(
        appleUserIdentifier: "apple-user-preview",
        identityToken: "apple-token",
        productAccountId: "productAccountFixtureId",
        trustedDeviceId: "trustedDeviceFixtureId"
      )
    )

    let loadTask = Task { await viewModel.load() }
    await service.waitUntilLoading()
    await viewModel.prune(categoryIds: ["system:flights"])
    await service.finishLoading()
    await loadTask.value

    XCTAssertEqual(viewModel.enabledCategoryIds, ["system:flights"])
    let savedRules = await service.loadSavedRules()
    XCTAssertEqual(savedRules, NotificationRules(categoryIds: ["system:flights"]))
  }
}

private final class StubNotificationAuthorization: NotificationAuthorizationRequesting {
  func requestAuthorization() async throws -> Bool { true }
}

private actor DelayedNotificationRuleSync: NotificationRuleSyncing {
  private let loadedRules: NotificationRules
  private var loadContinuation: CheckedContinuation<Void, Never>?
  private(set) var savedRules: NotificationRules?

  init(rules: NotificationRules) {
    loadedRules = rules
  }

  func loadRules(
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    await withCheckedContinuation { continuation in
      loadContinuation = continuation
    }
    return NotificationRuleSyncSnapshot(rules: loadedRules, updatedAt: 1)
  }

  func saveRules(
    _ rules: NotificationRules,
    expectedUpdatedAt _: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    savedRules = rules
    return NotificationRuleSyncSnapshot(rules: rules, updatedAt: 2)
  }

  func waitUntilLoading() async {
    while loadContinuation == nil {
      await Task.yield()
    }
  }

  func finishLoading() {
    loadContinuation?.resume()
    loadContinuation = nil
  }

  func loadSavedRules() -> NotificationRules? {
    savedRules
  }
}
