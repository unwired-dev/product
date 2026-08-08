import Foundation
import Testing

@testable import unwired_mail

@MainActor
@Suite(.serialized)
final class NotificationRuleViewModelTests {
  @Test
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

    #expect(!(viewModel.isGenericNotificationFallbackEnabled))

    await viewModel.setGenericNotificationFallbackEnabled(true)

    #expect(viewModel.isGenericNotificationFallbackEnabled)
    #expect(fallbackStore.savedProductAccountId == "productAccountFixtureId")
    #expect(fallbackStore.savedValue == true)
    #expect(authorization.requestCount == 1)
  }

  @Test
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

    #expect(viewModel.enabledCategoryIds == ["system:flights"])
    let savedRules = await service.loadSavedRules()
    #expect(savedRules == NotificationRules(categoryIds: ["system:flights"]))
  }

  @Test
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
    #expect(savedRules == NotificationRules(categoryIds: ["system:flights"]))
  }

  @Test
  func testUsesRefreshedSessionWithoutResettingEditedRules() async {
    let service = ImmediateNotificationRuleSync(rules: NotificationRules(categoryIds: []))
    let originalSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-preview",
      identityToken: "original-token",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
    let refreshedSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: originalSession.appleUserIdentifier,
      identityToken: "refreshed-token",
      productAccountId: originalSession.productAccountId,
      trustedDeviceId: originalSession.trustedDeviceId
    )
    let viewModel = NotificationRuleViewModel(
      authorization: StubNotificationAuthorization(),
      service: service,
      session: originalSession
    )

    await viewModel.load()
    viewModel.setEnabled(true, categoryId: "system:flights")
    viewModel.updateSession(refreshedSession)
    await viewModel.save(requestingNotificationAuthorization: false)

    #expect(viewModel.isEnabled(categoryId: "system:flights"))
    let savedSession = await service.loadSavedSession()
    #expect(savedSession == refreshedSession)
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
  private var savedSession: ProductAccountSessionSnapshot?
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
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    savedRules = rules
    savedSession = session
    return NotificationRuleSyncSnapshot(rules: rules, updatedAt: 2)
  }

  func loadSavedRules() -> NotificationRules? {
    savedRules
  }

  func loadSavedSession() -> ProductAccountSessionSnapshot? {
    savedSession
  }
}
