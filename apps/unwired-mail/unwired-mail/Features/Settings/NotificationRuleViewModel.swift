import Foundation
import Observation

// The synchronized and device-local notification controls intentionally share one view model.
// swiftlint:disable file_length type_body_length
@MainActor
@Observable
final class NotificationRuleViewModel {
  var authorizationState: NotificationAuthorizationState = .notDetermined
  var connectionPolicies: [String: NotificationConnectionPolicy] = [:]
  var devicePreferences: NotificationDevicePreferences
  var enabledCategoryIds: Set<String> = []
  var errorMessage: String?
  var fallbackErrorMessage: String?
  private var fallbackChangeGeneration = 0
  var isGenericNotificationFallbackEnabled: Bool
  var isNotificationEnabled = false
  var isSaving = false
  var isSyncing = false
  var profiles: [MailProfileDefinition] = []
  var previewMessage: String?
  var selectedProfileId: MailProfileId?

  private let authorization: NotificationAuthorizationRequesting
  private let devicePreferenceStore: NotificationDevicePreferencePersisting
  private let genericNotificationFallbackStore: GenericNotificationFallbackPersisting
  private var hasLoadedRules = false
  private var pendingPruneCategoryIds: Set<String>?
  private let previewDelivery: NotificationPreviewDelivering
  private var defaultProfileId: MailProfileId?
  private let profileLoader: NotificationProfilePolicyLoading?
  private var profileAssignments: [MailboxConnectionId: MailProfileId] = [:]
  private let profileServiceFactory: ((MailProfileRecordScope) -> NotificationRuleSyncing)?
  private var rulesUpdatedAt: Int64?
  private var syncedRules = NotificationRules(categoryIds: [])
  private var service: NotificationRuleSyncing
  private var session: ProductAccountSessionSnapshot

  init(
    authorization: NotificationAuthorizationRequesting,
    devicePreferenceStore: NotificationDevicePreferencePersisting =
      UserDefaultsNotificationPreferenceStore(),
    genericNotificationFallbackStore: GenericNotificationFallbackPersisting =
      UserDefaultsFallbackStore(),
    previewDelivery: NotificationPreviewDelivering = UserNotificationService(),
    profileLoader: NotificationProfilePolicyLoading? = nil,
    profileServiceFactory: ((MailProfileRecordScope) -> NotificationRuleSyncing)? = nil,
    service: NotificationRuleSyncing,
    session: ProductAccountSessionSnapshot
  ) {
    self.authorization = authorization
    self.devicePreferenceStore = devicePreferenceStore
    self.genericNotificationFallbackStore = genericNotificationFallbackStore
    devicePreferences = devicePreferenceStore.load(productAccountId: session.productAccountId)
    isGenericNotificationFallbackEnabled = genericNotificationFallbackStore.isEnabled(
      productAccountId: session.productAccountId
    )
    self.previewDelivery = previewDelivery
    self.profileLoader = profileLoader
    self.profileServiceFactory = profileServiceFactory
    self.service = service
    self.session = session
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    let productAccountIdDidChange = session.productAccountId != self.session.productAccountId
    self.session = session
    guard productAccountIdDidChange else { return }
    devicePreferences = devicePreferenceStore.load(productAccountId: session.productAccountId)
    isGenericNotificationFallbackEnabled = genericNotificationFallbackStore.isEnabled(
      productAccountId: session.productAccountId
    )
  }

  func loadProfiles(categoryIds: Set<String>? = nil) async {
    guard let profileLoader, let profileServiceFactory else {
      await load(categoryIds: categoryIds)
      return
    }
    do {
      let snapshot = try await profileLoader.loadNotificationProfileSnapshot(session: session)
      profiles = snapshot.profiles
      profileAssignments = snapshot.assignments
      defaultProfileId = snapshot.defaultProfileId
      let profileId =
        selectedProfileId.flatMap { selected in
          profiles.contains(where: { $0.id == selected }) ? selected : nil
        }
        ?? snapshot.defaultProfileId
      guard let profile = profiles.first(where: { $0.id == profileId }) else {
        throw MailProfileSyncError.profileNotFound
      }
      selectedProfileId = profile.id
      service = profileServiceFactory(profile.recordScope)
      await load(categoryIds: categoryIds)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func selectProfile(_ profileId: MailProfileId, categoryIds: Set<String>? = nil) async {
    guard
      !hasUnsavedChanges,
      let profile = profiles.first(where: { $0.id == profileId }),
      let profileServiceFactory
    else { return }
    selectedProfileId = profileId
    service = profileServiceFactory(profile.recordScope)
    await load(categoryIds: categoryIds)
  }

  func connectionsForSelectedProfile(_ connections: [MailboxConnection]) -> [MailboxConnection] {
    guard let selectedProfileId else { return connections }
    return connections.filter { profileAssignments[$0.id] == selectedProfileId }
  }

  var canSave: Bool {
    hasLoadedRules && !isSaving && !isSyncing
  }

  var isEditingDisabled: Bool {
    isSaving || isSyncing
  }

  var hasUnsavedChanges: Bool {
    editedRules != syncedRules
  }

  func isEnabled(categoryId: String) -> Bool {
    enabledCategoryIds.contains(categoryId)
  }

  func prune(categoryIds: Set<String>) async {
    guard !isSaving && !isSyncing else {
      pendingPruneCategoryIds = categoryIds
      return
    }
    let categoryIdsBeforePruning = enabledCategoryIds
    enabledCategoryIds.formIntersection(categoryIds)
    let syncedRulesAfterPruning = pruning(syncedRules, to: categoryIds)
    connectionPolicies = Dictionary(
      connectionPolicies.values.map { policy in
        let pruned = NotificationConnectionPolicy(
          connectionId: policy.connectionId,
          isEnabled: policy.isEnabled,
          categoryIds: policy.categoryIds.filter(categoryIds.contains)
        )
        return (pruned.connectionId, pruned)
      },
      uniquingKeysWith: { _, last in last }
    )
    guard
      hasLoadedRules,
      enabledCategoryIds != categoryIdsBeforePruning
        || syncedRules != syncedRulesAfterPruning
    else { return }
    isSaving = true
    defer { finishSaving() }

    do {
      let snapshot = try await service.saveRules(
        syncedRulesAfterPruning,
        expectedUpdatedAt: rulesUpdatedAt,
        session: session
      )
      syncedRules = snapshot.rules
      rulesUpdatedAt = snapshot.updatedAt
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func load(categoryIds: Set<String>? = nil) async {
    isSyncing = true

    do {
      var snapshot = try await service.loadRules(session: session)
      apply(snapshot.rules)
      rulesUpdatedAt = snapshot.updatedAt
      if let categoryIds {
        let prunedRules = pruning(snapshot.rules, to: categoryIds)
        apply(prunedRules)
        if prunedRules != snapshot.rules {
          snapshot = try await service.saveRules(
            prunedRules,
            expectedUpdatedAt: rulesUpdatedAt,
            session: session
          )
          apply(snapshot.rules)
          rulesUpdatedAt = snapshot.updatedAt
        }
      }
      syncedRules = snapshot.rules
      hasLoadedRules = true
      await refreshAuthorizationState()
      if authorizationState == .denied, snapshot.rules.isEnabled {
        errorMessage =
          "Rules are enabled, but visible notifications are disabled in system settings."
      } else {
        errorMessage = nil
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    isSyncing = false
    await replayPendingPrune()
  }

  func save(requestingNotificationAuthorization: Bool = true) async {
    guard canSave else { return }
    isSaving = true
    defer { finishSaving() }

    do {
      let snapshot = try await service.saveRules(
        editedRules,
        expectedUpdatedAt: rulesUpdatedAt,
        session: session
      )
      apply(snapshot.rules)
      syncedRules = snapshot.rules
      rulesUpdatedAt = snapshot.updatedAt
      if requestingNotificationAuthorization,
        snapshot.rules.isEnabled,
        try await !authorization.requestAuthorization()
      {
        authorizationState = .denied
        errorMessage =
          "Rules were saved, but visible notifications are disabled in system settings."
      } else {
        await refreshAuthorizationState()
        errorMessage = nil
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setEnabled(_ isEnabled: Bool, categoryId: String) {
    if isEnabled {
      enabledCategoryIds.insert(categoryId)
    } else {
      enabledCategoryIds.remove(categoryId)
    }
  }

  func setNotificationEnabled(_ isEnabled: Bool) {
    isNotificationEnabled = isEnabled
  }

  func discardUnsavedChanges() {
    apply(syncedRules)
    errorMessage = nil
  }

  func usesProfilePolicy(connectionId: MailboxConnectionId) -> Bool {
    connectionPolicies[connectionId.rawValue] == nil
  }

  func setUsesProfilePolicy(_ usesProfilePolicy: Bool, connectionId: MailboxConnectionId) {
    guard !isEditingDisabled else { return }
    if usesProfilePolicy {
      connectionPolicies[connectionId.rawValue] = nil
    } else {
      connectionPolicies[connectionId.rawValue] = NotificationConnectionPolicy(
        connectionId: connectionId.rawValue,
        isEnabled: true,
        categoryIds: Array(enabledCategoryIds)
      )
    }
  }

  func setConnectionEnabled(_ isEnabled: Bool, connectionId: MailboxConnectionId) {
    guard !isEditingDisabled else { return }
    let current = connectionPolicies[connectionId.rawValue]
    connectionPolicies[connectionId.rawValue] = NotificationConnectionPolicy(
      connectionId: connectionId.rawValue,
      isEnabled: isEnabled,
      categoryIds: current?.categoryIds ?? Array(enabledCategoryIds)
    )
  }

  func setConnectionCategoryEnabled(
    _ isEnabled: Bool,
    categoryId: String,
    connectionId: MailboxConnectionId
  ) {
    guard !isEditingDisabled else { return }
    let current =
      connectionPolicies[connectionId.rawValue]
      ?? NotificationConnectionPolicy(
        connectionId: connectionId.rawValue,
        isEnabled: true,
        categoryIds: Array(enabledCategoryIds)
      )
    var categoryIds = Set(current.categoryIds)
    if isEnabled {
      categoryIds.insert(categoryId)
    } else {
      categoryIds.remove(categoryId)
    }
    connectionPolicies[connectionId.rawValue] = NotificationConnectionPolicy(
      connectionId: connectionId.rawValue,
      isEnabled: current.isEnabled,
      categoryIds: Array(categoryIds)
    )
  }

  func setDevicePreferences(_ preferences: NotificationDevicePreferences) {
    devicePreferences = preferences
    devicePreferenceStore.save(preferences, productAccountId: session.productAccountId)
  }

  func requestNotificationAuthorization() async {
    do {
      authorizationState = try await authorization.requestAuthorization() ? .authorized : .denied
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func deliverPreview(connectionId: MailboxConnectionId?) async {
    guard let connectionId else {
      previewMessage = "Connect a mailbox before previewing a notification."
      return
    }
    do {
      guard try await authorization.requestAuthorization() else {
        authorizationState = .denied
        previewMessage = "Visible notifications are disabled in system settings."
        return
      }
      authorizationState = .authorized
      let profile =
        selectedProfileId.flatMap { selectedProfileId in
          profiles.first(where: { $0.id == selectedProfileId })
        }
        ?? MailProfileDefinition.defaultProfile(productAccountId: session.productAccountId)
      try await previewDelivery.deliverSample(
        productAccountId: session.productAccountId,
        categoryIds: Array(enabledCategoryIds),
        context: NotificationDeliveryContext(
          connectionId: connectionId,
          isActiveProfile: defaultProfileId.map { $0 == profile.id } ?? true,
          isProfileQuiet: false,
          profileId: profile.id,
          profileName: profile.name
        )
      )
      previewMessage = "Sample notification scheduled on this device."
    } catch {
      previewMessage = error.localizedDescription
    }
  }

  func setGenericNotificationFallbackEnabled(_ isEnabled: Bool) async {
    fallbackChangeGeneration += 1
    let generation = fallbackChangeGeneration
    genericNotificationFallbackStore.setEnabled(
      isEnabled,
      productAccountId: session.productAccountId
    )
    isGenericNotificationFallbackEnabled = isEnabled
    fallbackErrorMessage = nil
    guard isEnabled else { return }
    do {
      let authorized = try await authorization.requestAuthorization()
      guard
        generation == fallbackChangeGeneration,
        isGenericNotificationFallbackEnabled
      else { return }
      if !authorized {
        fallbackErrorMessage =
          "Fallback is enabled, but visible notifications are disabled in system settings."
      }
    } catch {
      guard
        generation == fallbackChangeGeneration,
        isGenericNotificationFallbackEnabled
      else { return }
      fallbackErrorMessage = error.localizedDescription
    }
  }

  private func finishSaving() {
    isSaving = false
    Task {
      await replayPendingPrune()
    }
  }

  private var editedRules: NotificationRules {
    NotificationRules(
      isEnabled: isNotificationEnabled,
      categoryIds: Array(enabledCategoryIds),
      connectionPolicies: Array(connectionPolicies.values)
    )
  }

  private func apply(_ rules: NotificationRules) {
    isNotificationEnabled = rules.isEnabled
    enabledCategoryIds = Set(rules.categoryIds)
    connectionPolicies = Dictionary(
      rules.connectionPolicies.map { ($0.connectionId, $0) },
      uniquingKeysWith: { _, last in last }
    )
  }

  private func pruning(_ rules: NotificationRules, to categoryIds: Set<String>)
    -> NotificationRules
  {
    NotificationRules(
      isEnabled: rules.isEnabled,
      categoryIds: rules.categoryIds.filter(categoryIds.contains),
      connectionPolicies: rules.connectionPolicies.map { policy in
        NotificationConnectionPolicy(
          connectionId: policy.connectionId,
          isEnabled: policy.isEnabled,
          categoryIds: policy.categoryIds.filter(categoryIds.contains)
        )
      }
    )
  }

  private func refreshAuthorizationState() async {
    guard let checker = authorization as? NotificationAuthorizationStateChecking else {
      return
    }
    authorizationState = await checker.notificationAuthorizationState()
  }

  private func replayPendingPrune() async {
    guard let categoryIds = pendingPruneCategoryIds else { return }
    pendingPruneCategoryIds = nil
    await prune(categoryIds: categoryIds)
  }
}

protocol NotificationProfilePolicyLoading {
  func loadNotificationProfileSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot
}

extension MailboxConnectionSyncService: NotificationProfilePolicyLoading {
  func loadNotificationProfileSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    try await loadProfileSnapshot(session: session)
  }
}
