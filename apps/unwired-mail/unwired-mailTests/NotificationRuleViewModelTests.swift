import XCTest

@testable import unwired_mail

@MainActor
final class NotificationRuleViewModelTests: XCTestCase {
  func testGenericNotificationFallbackStartsDisabledAndPersistsOptIn() async {
    let authorization = RecordingFallbackAuthorization()
    let fallbackStore = RecordingFallbackStore()
    let viewModel = NotificationRuleViewModel(
      authorization: authorization,
      genericNotificationFallbackStore: fallbackStore,
      service: ImmediateNotificationRuleSync(rules: NotificationRules(categoryIds: [])),
      session: ProductAccountSessionSnapshot(
        appleUserIdentifier: "apple-user-preview",
        identityToken: "apple-token",
        productAccountId: "productAccountFixtureId",
        trustedDeviceId: "trustedDeviceFixtureId"
      )
    )

    XCTAssertFalse(viewModel.isGenericNotificationFallbackEnabled)

    await viewModel.setGenericNotificationFallbackEnabled(true)

    XCTAssertTrue(viewModel.isGenericNotificationFallbackEnabled)
    XCTAssertEqual(fallbackStore.savedProductAccountId, "productAccountFixtureId")
    XCTAssertEqual(fallbackStore.savedValue, true)
    XCTAssertEqual(authorization.requestCount, 1)
  }

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

  func testPruneRemovesDisabledDeletedCategoryFromSyncedRules() async throws {
    let service = ImmediateNotificationRuleSync(
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

    await viewModel.load()
    viewModel.setEnabled(false, categoryId: "custom-category-primary")
    await viewModel.prune(categoryIds: ["system:flights"])

    let savedRules = await service.loadSavedRules()
    XCTAssertEqual(
      savedRules,
      NotificationRules(categoryIds: ["system:flights"])
    )
  }
}

private final class RecordingFallbackAuthorization:
  NotificationAuthorizationRequesting
{
  private(set) var requestCount = 0

  func requestAuthorization() async throws -> Bool {
    requestCount += 1
    return true
  }
}

private final class RecordingFallbackStore:
  GenericNotificationFallbackPersisting
{
  var savedProductAccountId: String?
  var savedValue: Bool?

  func isEnabled(productAccountId _: String) -> Bool {
    false
  }

  func setEnabled(_ isEnabled: Bool, productAccountId: String) {
    savedProductAccountId = productAccountId
    savedValue = isEnabled
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

private actor ImmediateNotificationRuleSync: NotificationRuleSyncing {
  private let loadedRules: NotificationRules
  private(set) var savedRules: NotificationRules?

  init(rules: NotificationRules) {
    loadedRules = rules
  }

  func loadRules(
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    NotificationRuleSyncSnapshot(rules: loadedRules, updatedAt: 1)
  }

  func saveRules(
    _ rules: NotificationRules,
    expectedUpdatedAt _: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    savedRules = rules
    return NotificationRuleSyncSnapshot(rules: rules, updatedAt: 2)
  }

  func loadSavedRules() -> NotificationRules? {
    savedRules
  }
}
