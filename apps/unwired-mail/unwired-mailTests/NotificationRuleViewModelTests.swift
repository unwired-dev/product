import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
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
  func testDisablesEditingWhileProfilesLoad() async {
    let defaultProfile = MailProfileDefinition.defaultProfile(
      productAccountId: session.productAccountId
    )
    let profileLoader = DelayedNotificationProfilePolicyLoader(
      snapshot: MailProfileSyncSnapshot(
        assignments: [:],
        conflicts: [],
        defaultProfileId: defaultProfile.id,
        profiles: [defaultProfile],
        updatedAt: 1
      )
    )
    let service = ImmediateNotificationRuleSync(rules: NotificationRules(categoryIds: []))
    let viewModel = NotificationRuleViewModel(
      authorization: StubNotificationAuthorization(),
      profileLoader: profileLoader,
      profileServiceFactory: { _ in service },
      service: service,
      session: session
    )

    let loadTask = Task { await viewModel.loadProfiles() }
    await profileLoader.waitUntilLoading()

    #expect(viewModel.isEditingDisabled)

    await profileLoader.finishLoading()
    await loadTask.value
    #expect(!viewModel.isEditingDisabled)
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

  @Test
  func testAccountChangeReloadsDeviceLocalNotificationState() {
    let accountAPreferences = NotificationDevicePreferences(isBadgeEnabled: false)
    let accountBPreferences = NotificationDevicePreferences(isSoundEnabled: false)
    let preferenceStore = RecordingNotificationPreferenceStore(
      preferencesByProductAccountId: [
        "account-a": accountAPreferences,
        "account-b": accountBPreferences,
      ]
    )
    let fallbackStore = RecordingFallbackStore(values: ["account-b": true])
    let accountASession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-preview",
      identityToken: "apple-token-a",
      productAccountId: "account-a",
      trustedDeviceId: "trusted-device-a"
    )
    let accountBSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-preview",
      identityToken: "apple-token-b",
      productAccountId: "account-b",
      trustedDeviceId: "trusted-device-b"
    )
    let viewModel = NotificationRuleViewModel(
      authorization: StubNotificationAuthorization(),
      devicePreferenceStore: preferenceStore,
      genericNotificationFallbackStore: fallbackStore,
      service: ImmediateNotificationRuleSync(rules: NotificationRules(categoryIds: [])),
      session: accountASession
    )

    viewModel.updateSession(accountBSession)

    #expect(viewModel.devicePreferences == accountBPreferences)
    #expect(viewModel.isGenericNotificationFallbackEnabled)
  }

  @Test
  func testLoadReadsAuthorizationStateWithoutRequestingPermission() async {
    let authorization = RecordingFallbackAuthorization(authorizationState: .denied)
    let viewModel = NotificationRuleViewModel(
      authorization: authorization,
      service: ImmediateNotificationRuleSync(
        rules: NotificationRules(
          isEnabled: true,
          categoryIds: ["system:flights"],
          connectionPolicies: []
        )
      ),
      session: session
    )

    await viewModel.load()

    #expect(viewModel.authorizationState == .denied)
    #expect(authorization.requestCount == 0)
    #expect(authorization.statusReadCount == 1)
  }

  @Test
  func testPermissionRequestDoesNotSchedulePreview() async {
    let authorization = RecordingFallbackAuthorization()
    let previewDelivery = RecordingNotificationPreviewDelivery()
    let viewModel = NotificationRuleViewModel(
      authorization: authorization,
      previewDelivery: previewDelivery,
      service: ImmediateNotificationRuleSync(rules: NotificationRules(categoryIds: [])),
      session: session
    )

    await viewModel.requestNotificationAuthorization()

    #expect(authorization.requestCount == 1)
    #expect(previewDelivery.context == nil)
  }

  @Test
  func testSavesGlobalSwitchAndPerConnectionCategoryOverride() async {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "primary@example.com"
      )
    )
    let service = ImmediateNotificationRuleSync(rules: NotificationRules(categoryIds: []))
    let viewModel = NotificationRuleViewModel(
      authorization: StubNotificationAuthorization(),
      service: service,
      session: session
    )
    await viewModel.load()

    viewModel.setNotificationEnabled(true)
    viewModel.setEnabled(true, categoryId: "system:flights")
    viewModel.setUsesProfilePolicy(false, connectionId: connectionId)
    viewModel.setConnectionCategoryEnabled(
      true,
      categoryId: "system:invites",
      connectionId: connectionId
    )
    await viewModel.save(requestingNotificationAuthorization: false)

    let savedRules = await service.loadSavedRules()
    #expect(savedRules?.isEnabled == true)
    #expect(savedRules?.categoryIds == ["system:flights"])
    #expect(savedRules?.connectionPolicies.first?.connectionId == connectionId.rawValue)
    #expect(
      savedRules?.connectionPolicies.first?.categoryIds
        == ["system:flights", "system:invites"]
    )
  }

  @Test
  func testConnectionOverrideEditsAreIgnoredWhileSaving() async {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "primary@example.com"
      )
    )
    let service = DelayedSaveNotificationRuleSync(
      rules: NotificationRules(categoryIds: ["system:flights"])
    )
    let viewModel = NotificationRuleViewModel(
      authorization: StubNotificationAuthorization(),
      service: service,
      session: session
    )
    await viewModel.load()
    viewModel.setUsesProfilePolicy(false, connectionId: connectionId)

    let saveTask = Task { await viewModel.save(requestingNotificationAuthorization: false) }
    await service.waitUntilSaving()
    let policiesWhileSaving = viewModel.connectionPolicies

    viewModel.setConnectionEnabled(false, connectionId: connectionId)
    viewModel.setUsesProfilePolicy(true, connectionId: connectionId)
    viewModel.setConnectionCategoryEnabled(
      false,
      categoryId: "system:flights",
      connectionId: connectionId
    )

    #expect(viewModel.connectionPolicies == policiesWhileSaving)
    await service.finishSaving()
    await saveTask.value
  }

  @Test
  func testDevicePresentationPreferencesSaveWithoutRuleSynchronization() async {
    let preferenceStore = RecordingNotificationPreferenceStore()
    let service = ImmediateNotificationRuleSync(rules: NotificationRules(categoryIds: []))
    let viewModel = NotificationRuleViewModel(
      authorization: StubNotificationAuthorization(),
      devicePreferenceStore: preferenceStore,
      service: service,
      session: session
    )
    let preferences = NotificationDevicePreferences(
      isBadgeEnabled: false,
      isSoundEnabled: false,
      lockScreenContentLevel: .senderAndSubject,
      quietSchedule: NotificationQuietSchedule(
        isEnabled: true,
        startMinute: 21 * 60,
        endMinute: 8 * 60,
        allowedCategoryIds: ["system:invites"]
      )
    )

    viewModel.setDevicePreferences(preferences)

    #expect(preferenceStore.savedPreferences == preferences)
    #expect(preferenceStore.savedProductAccountId == session.productAccountId)
    #expect(await service.loadSavedRules() == nil)
  }

  @Test
  func testSelectsAndSavesAnIndependentPolicyForEachMailProfile() async {
    let defaultProfile = MailProfileDefinition.defaultProfile(
      productAccountId: session.productAccountId
    )
    let workProfile = MailProfileDefinition(
      id: MailProfileId(rawValue: "profile-work"),
      appearance: .default,
      name: "Work",
      recordScope: .profile(MailProfileId(rawValue: "profile-work")),
      quietState: .inactive
    )
    let defaultService = ImmediateNotificationRuleSync(
      rules: NotificationRules(
        isEnabled: true, categoryIds: ["system:flights"], connectionPolicies: [])
    )
    let workService = ImmediateNotificationRuleSync(rules: NotificationRules(categoryIds: []))
    let viewModel = NotificationRuleViewModel(
      authorization: StubNotificationAuthorization(),
      profileLoader: StubNotificationProfilePolicyLoader(
        snapshot: MailProfileSyncSnapshot(
          assignments: [:],
          conflicts: [],
          defaultProfileId: defaultProfile.id,
          profiles: [defaultProfile, workProfile],
          updatedAt: 1
        )
      ),
      profileServiceFactory: { scope in
        scope == workProfile.recordScope ? workService : defaultService
      },
      service: defaultService,
      session: session
    )

    await viewModel.loadProfiles(categoryIds: ["system:flights", "system:invites"])
    #expect(viewModel.selectedProfileId == defaultProfile.id)
    #expect(viewModel.enabledCategoryIds == ["system:flights"])

    await viewModel.selectProfile(
      workProfile.id,
      categoryIds: ["system:flights", "system:invites"]
    )
    viewModel.setNotificationEnabled(true)
    viewModel.setEnabled(true, categoryId: "system:invites")
    await viewModel.save(requestingNotificationAuthorization: false)

    #expect(viewModel.selectedProfileId == workProfile.id)
    #expect(await workService.loadSavedRules()?.categoryIds == ["system:invites"])
    #expect(await defaultService.loadSavedRules() == nil)
  }

  @Test
  func testFailedProfileSwitchDoesNotExposePreviousPolicy() async {
    let defaultProfile = MailProfileDefinition.defaultProfile(
      productAccountId: session.productAccountId
    )
    let workProfile = MailProfileDefinition(
      id: MailProfileId(rawValue: "profile-work"),
      appearance: .default,
      name: "Work",
      recordScope: .profile(MailProfileId(rawValue: "profile-work")),
      quietState: .inactive
    )
    let defaultService = ImmediateNotificationRuleSync(
      rules: NotificationRules(
        isEnabled: true,
        categoryIds: ["system:flights"],
        connectionPolicies: [
          NotificationConnectionPolicy(
            connectionId: "connection-primary",
            isEnabled: true,
            categoryIds: ["system:flights"]
          )
        ]
      )
    )
    let failingService = FailingNotificationRuleSync()
    let viewModel = NotificationRuleViewModel(
      authorization: StubNotificationAuthorization(),
      profileLoader: StubNotificationProfilePolicyLoader(
        snapshot: MailProfileSyncSnapshot(
          assignments: [:],
          conflicts: [],
          defaultProfileId: defaultProfile.id,
          profiles: [defaultProfile, workProfile],
          updatedAt: 1
        )
      ),
      profileServiceFactory: { scope in
        scope == workProfile.recordScope
          ? failingService as NotificationRuleSyncing : defaultService
      },
      service: defaultService,
      session: session
    )

    await viewModel.loadProfiles()
    await viewModel.selectProfile(workProfile.id)

    #expect(viewModel.selectedProfileId == workProfile.id)
    #expect(!viewModel.isNotificationEnabled)
    #expect(viewModel.enabledCategoryIds.isEmpty)
    #expect(viewModel.connectionPolicies.isEmpty)
    #expect(!viewModel.canSave)
    #expect(viewModel.errorMessage != nil)
  }

  @Test
  func testPreviewUsesSelectedMailProfileContext() async {
    let defaultProfile = MailProfileDefinition.defaultProfile(
      productAccountId: session.productAccountId
    )
    let workProfile = MailProfileDefinition(
      id: MailProfileId(rawValue: "profile-work"),
      appearance: .default,
      name: "Work",
      recordScope: .profile(MailProfileId(rawValue: "profile-work")),
      quietState: .inactive
    )
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "work@example.com"
      )
    )
    let previewDelivery = RecordingNotificationPreviewDelivery()
    let service = ImmediateNotificationRuleSync(rules: NotificationRules(categoryIds: []))
    let viewModel = NotificationRuleViewModel(
      authorization: StubNotificationAuthorization(),
      previewDelivery: previewDelivery,
      profileLoader: StubNotificationProfilePolicyLoader(
        snapshot: MailProfileSyncSnapshot(
          assignments: [connectionId: workProfile.id],
          conflicts: [],
          defaultProfileId: defaultProfile.id,
          profiles: [defaultProfile, workProfile],
          updatedAt: 1
        )
      ),
      profileServiceFactory: { _ in service },
      service: service,
      session: session
    )

    await viewModel.loadProfiles()
    await viewModel.selectProfile(workProfile.id)
    await viewModel.deliverPreview(connectionId: connectionId)

    #expect(previewDelivery.context?.profileId == workProfile.id)
    #expect(previewDelivery.context?.profileName == "Work")
    #expect(previewDelivery.context?.isActiveProfile == false)
    #expect(previewDelivery.context?.connectionId == connectionId)
  }

  @Test
  func testOvernightQuietScheduleHonorsCategoryAllowlist() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let schedule = NotificationQuietSchedule(
      isEnabled: true,
      startMinute: 22 * 60,
      endMinute: 7 * 60,
      allowedCategoryIds: ["system:invites"]
    )
    let lateEvening = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 23))
    )
    let midday = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 12))
    )

    #expect(schedule.isQuiet(at: lateEvening, calendar: calendar))
    #expect(!schedule.isQuiet(at: midday, calendar: calendar))
    #expect(schedule.allowedCategoryIds == ["system:invites"])
  }

  private var session: ProductAccountSessionSnapshot {
    ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-preview",
      identityToken: "apple-token",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
  }
}

private final class RecordingFallbackAuthorization:
  NotificationAuthorizationRequesting, NotificationAuthorizationStateChecking
{
  private let authorizationState: NotificationAuthorizationState
  private(set) var requestCount = 0
  private(set) var statusReadCount = 0

  init(authorizationState: NotificationAuthorizationState = .authorized) {
    self.authorizationState = authorizationState
  }

  func requestAuthorization() async throws -> Bool {
    requestCount += 1
    return true
  }

  func notificationAuthorizationState() async -> NotificationAuthorizationState {
    statusReadCount += 1
    return authorizationState
  }
}

private struct StubNotificationProfilePolicyLoader: NotificationProfilePolicyLoading {
  let snapshot: MailProfileSyncSnapshot

  func loadNotificationProfileSnapshot(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    snapshot
  }
}

private actor DelayedNotificationProfilePolicyLoader: NotificationProfilePolicyLoading {
  private var loadContinuation: CheckedContinuation<Void, Never>?
  private let snapshot: MailProfileSyncSnapshot

  init(snapshot: MailProfileSyncSnapshot) {
    self.snapshot = snapshot
  }

  func loadNotificationProfileSnapshot(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    await withCheckedContinuation { continuation in
      loadContinuation = continuation
    }
    return snapshot
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
}

private final class RecordingFallbackStore:
  GenericNotificationFallbackPersisting
{
  var savedProductAccountId: String?
  var savedValue: Bool?
  private var values: [String: Bool]

  init(values: [String: Bool] = [:]) {
    self.values = values
  }

  func isEnabled(productAccountId: String) -> Bool {
    values[productAccountId] ?? false
  }

  func setEnabled(_ isEnabled: Bool, productAccountId: String) {
    values[productAccountId] = isEnabled
    savedProductAccountId = productAccountId
    savedValue = isEnabled
  }
}

private final class StubNotificationAuthorization: NotificationAuthorizationRequesting {
  func requestAuthorization() async throws -> Bool { true }
}

private final class RecordingNotificationPreferenceStore:
  NotificationDevicePreferencePersisting
{
  var savedPreferences: NotificationDevicePreferences?
  var savedProductAccountId: String?
  private var preferencesByProductAccountId: [String: NotificationDevicePreferences]

  init(preferencesByProductAccountId: [String: NotificationDevicePreferences] = [:]) {
    self.preferencesByProductAccountId = preferencesByProductAccountId
  }

  func clear(productAccountId _: String) {}

  func load(productAccountId: String) -> NotificationDevicePreferences {
    preferencesByProductAccountId[productAccountId] ?? .default
  }

  func save(_ preferences: NotificationDevicePreferences, productAccountId: String) {
    preferencesByProductAccountId[productAccountId] = preferences
    savedPreferences = preferences
    savedProductAccountId = productAccountId
  }
}

private final class RecordingNotificationPreviewDelivery: NotificationPreviewDelivering {
  private(set) var context: NotificationDeliveryContext?

  func deliverSample(
    productAccountId _: String,
    categoryIds _: [String],
    context: NotificationDeliveryContext
  ) async throws {
    self.context = context
  }
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

private actor DelayedSaveNotificationRuleSync: NotificationRuleSyncing {
  private let loadedRules: NotificationRules
  private var saveContinuation: CheckedContinuation<Void, Never>?

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
    await withCheckedContinuation { continuation in
      saveContinuation = continuation
    }
    return NotificationRuleSyncSnapshot(rules: rules, updatedAt: 2)
  }

  func waitUntilSaving() async {
    while saveContinuation == nil {
      await Task.yield()
    }
  }

  func finishSaving() {
    saveContinuation?.resume()
    saveContinuation = nil
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

private actor FailingNotificationRuleSync: NotificationRuleSyncing {
  func loadRules(
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    throw URLError(.cannotConnectToHost)
  }

  func saveRules(
    _: NotificationRules,
    expectedUpdatedAt _: Int64?,
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    throw URLError(.cannotConnectToHost)
  }
}
