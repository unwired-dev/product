import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

@Suite(.serialized)
@MainActor
struct MailProfileInterruptionTests {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user",
    identityToken: "token",
    productAccountId: "product-account",
    trustedDeviceId: "trusted-device"
  )

  @Test
  func quietPolicyExpiresAtTheAbsoluteSynchronizedInstant() {
    let end = Date(timeIntervalSince1970: 2_000)
    let quiet = MailProfileQuietState.quiet(until: end)

    #expect(quiet.isActive(at: end.addingTimeInterval(-0.001)))
    #expect(!quiet.isActive(at: end))
    #expect(
      !MailProfileInterruptionPolicy(
        quietState: quiet,
        hasAuthoritativeQuietState: true,
        contentIsConcealed: false,
        now: end.addingTimeInterval(-1)
      ).allowsVisibleNotifications
    )
    #expect(
      MailProfileInterruptionPolicy(
        quietState: quiet,
        hasAuthoritativeQuietState: true,
        contentIsConcealed: false,
        now: end
      ).allowsVisibleNotifications
    )
  }

  @Test
  func policyConcealsContentAndSuggestionsWithoutStoppingBackgroundWork() {
    let policy = MailProfileInterruptionPolicy(
      quietState: .inactive,
      hasAuthoritativeQuietState: true,
      contentIsConcealed: true,
      now: .now
    )

    #expect(!policy.allowsContentReveal)
    #expect(!policy.allowsProactiveSuggestions)
    #expect(policy.allowsVisibleNotifications)
    #expect(policy.allowsBackgroundWork)
  }

  @Test
  func profileLockDismissesEveryContentBearingPresentationPath() {
    var showsRootMessageActionAlert = true
    var composerNavigation = MailShellComposerNavigationState()
    composerNavigation.present(.new(defaultSendingConnectionId: nil))
    var composerSendErrorMessage = "Previous send failed."
    var showsComposerSendError = true
    MailProfileContentPresentationDismissal.dismissRoot(
      showsMessageActionAlert: &showsRootMessageActionAlert,
      composerNavigation: &composerNavigation,
      composerSendErrorMessage: &composerSendErrorMessage,
      showsComposerSendError: &showsComposerSendError
    )

    var categorySelection: String? = "category"
    var readerMessageActionError: String? = "failed"
    MailProfileContentPresentationDismissal.dismissReader(
      categorySelection: &categorySelection,
      messageActionError: &readerMessageActionError
    )

    #expect(showsRootMessageActionAlert == false)
    #expect(composerNavigation.draft == nil)
    #expect(composerSendErrorMessage.isEmpty)
    #expect(showsComposerSendError == false)
    #expect(categorySelection == nil)
    #expect(readerMessageActionError == nil)
  }

  @Test
  func notificationResolverFailsClosedForMissingOwnershipAndHonorsQuietExpiration() async throws {
    let profile = MailProfileDefinition.defaultProfile(productAccountId: session.productAccountId)
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "provider-account"
      )
    )
    let service = StubMailProfileInterruptionSyncService(
      snapshot: snapshot(profile: profile, assignments: [:])
    )
    let resolver = ProductSyncMailProfileNotificationGate(
      service: service,
      lockStore: RecordingMailProfileLockStore(),
      now: { Date(timeIntervalSince1970: 2_000) }
    )

    #expect(
      try await resolver.visibleNotificationsAreSuppressed(
        for: connectionId,
        session: session
      )
    )

    var quietProfile = profile
    quietProfile.quietState = .quiet(until: Date(timeIntervalSince1970: 1_999))
    service.snapshot = snapshot(
      profile: quietProfile,
      assignments: [connectionId: quietProfile.id]
    )

    #expect(
      try await !resolver.visibleNotificationsAreSuppressed(
        for: connectionId,
        session: session
      )
    )
  }

  @Test
  func notificationResolverConcealsPreviewsForDeviceLocalProfileLock() async throws {
    let profile = MailProfileDefinition.defaultProfile(productAccountId: session.productAccountId)
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "provider-account"
      )
    )
    let lockStore = RecordingMailProfileLockStore()
    lockStore.configurations[profile.id] = MailProfileLockConfiguration(
      backgroundGracePeriod: .fiveMinutes,
      isEnabled: true
    )
    let resolver = ProductSyncMailProfileNotificationGate(
      service: StubMailProfileInterruptionSyncService(
        snapshot: snapshot(profile: profile, assignments: [connectionId: profile.id])
      ),
      lockStore: lockStore
    )

    #expect(
      try await resolver.visibleNotificationsAreSuppressed(
        for: connectionId,
        session: session
      )
    )
  }

  @Test
  func profileLockSettingsStayDeviceLocalAndProfileScoped() throws {
    let suiteName = "MailProfileInterruptionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsMailProfileLockStore(defaults: defaults)
    let firstProfile = MailProfileId(rawValue: "first")
    let secondProfile = MailProfileId(rawValue: "second")
    let configuration = MailProfileLockConfiguration(
      backgroundGracePeriod: .oneMinute,
      isEnabled: true
    )

    store.save(configuration, productAccountId: session.productAccountId, profileId: firstProfile)

    #expect(
      store.load(productAccountId: session.productAccountId, profileId: firstProfile)
        == configuration
    )
    #expect(
      store.load(productAccountId: session.productAccountId, profileId: secondProfile)
        == .disabled
    )

    store.clear(productAccountId: session.productAccountId)
    #expect(
      store.load(productAccountId: session.productAccountId, profileId: firstProfile)
        == .disabled
    )
  }

  @Test
  func spotlightPreferenceDefaultsOffAndStaysDeviceLocalAndProfileScoped() throws {
    let suiteName = "MailProfileSpotlightTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsMailProfileSpotlightStore(defaults: defaults)
    let firstProfile = MailProfileId(rawValue: "first")
    let secondProfile = MailProfileId(rawValue: "second")

    #expect(!store.isEnabled(productAccountId: "first-account", profileId: firstProfile))
    store.setEnabled(true, productAccountId: "first-account", profileId: firstProfile)

    #expect(store.isEnabled(productAccountId: "first-account", profileId: firstProfile))
    #expect(!store.isEnabled(productAccountId: "first-account", profileId: secondProfile))
    #expect(!store.isEnabled(productAccountId: "second-account", profileId: firstProfile))
  }

  @Test
  func spotlightIndexUsesOnlyBoundedMetadataAndExactDeepLinks() throws {
    let profile = MailProfileDefinition.defaultProfile(productAccountId: session.productAccountId)
    let connection = spotlightConnection()
    let message = spotlightMessage(id: "message-1", snippet: "private body sentinel")

    let item = MailProfileSpotlightIndex.item(
      message: message,
      profile: profile,
      connection: connection
    )
    let deepLink = try #require(MailMessageDeepLink(url: item.contentURL))

    #expect(item.subject == "Subject message-1")
    #expect(item.sender == "Sender")
    #expect(item.recipients == ["recipient@example.com"])
    #expect(item.profileName == profile.name)
    #expect(item.connectionName == connection.displayName)
    #expect(!String(reflecting: item).contains("private body sentinel"))
    #expect(deepLink.productAccountId == session.productAccountId)
    #expect(deepLink.profileId == profile.id)
    #expect(deepLink.connectionId == connection.id)
    #expect(deepLink.providerMessageId == message.providerMessageId)
    #expect(deepLink.message(in: [connection.id: [message]]) == message)
    #expect(deepLink.message(in: [connection.id: []]) == nil)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func spotlightIndexReconcilesChangesDeletionRevocationTransferAndProfileDeletion() async throws {
    let suiteName = "MailProfileSpotlightIndexTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let backend = RecordingMailProfileSpotlightBackend()
    let index = MailProfileSpotlightIndex(backend: backend, defaults: defaults)
    let firstProfile = MailProfileDefinition.defaultProfile(
      productAccountId: session.productAccountId
    )
    let secondProfile = MailProfileDefinition(
      id: MailProfileId(rawValue: "second-profile"),
      appearance: .default,
      name: "Second",
      recordScope: .profile(MailProfileId(rawValue: "second-profile")),
      quietState: .inactive
    )
    let connection = spotlightConnection()
    let first = spotlightMessage(id: "first")
    let second = spotlightMessage(id: "second")

    try await index.reconcile(
      productAccountId: session.productAccountId,
      profile: firstProfile,
      profiles: [firstProfile, secondProfile],
      messagesByConnection: [connection.id: [first, second]],
      connections: [connection]
    )
    #expect(
      backend.deletedDomains.last == [
        MailProfileSpotlightIndex.domainIdentifier(
          profileId: firstProfile.id
        )
      ])
    #expect(backend.indexedBatches.map(\.count) == [2])

    try await index.reconcile(
      productAccountId: session.productAccountId,
      profile: firstProfile,
      profiles: [firstProfile, secondProfile],
      messagesByConnection: [connection.id: [first, second]],
      connections: [connection]
    )
    #expect(backend.indexedBatches.map(\.count) == [2])

    let changed = spotlightMessage(id: "first", subject: "Changed")
    try await index.reconcile(
      productAccountId: session.productAccountId,
      profile: firstProfile,
      profiles: [firstProfile, secondProfile],
      messagesByConnection: [connection.id: [changed]],
      connections: [connection]
    )
    #expect(backend.deletedItemIdentifiers.last?.count == 1)
    #expect(backend.indexedBatches.map(\.count) == [2, 1])

    let revokedConnection = MailboxConnection(
      authorizationState: .required,
      capabilities: .none,
      connectedAt: 0,
      displayName: connection.displayName,
      id: connection.id,
      lastVerifiedAt: 0,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 0
    )
    try await index.reconcile(
      productAccountId: session.productAccountId,
      profile: firstProfile,
      profiles: [firstProfile, secondProfile],
      messagesByConnection: [connection.id: [changed]],
      connections: [revokedConnection]
    )
    #expect(backend.deletedItemIdentifiers.last?.count == 1)
    let deletionCount = backend.deletedItemIdentifiers.count
    let domainDeletionCount = backend.deletedDomains.count
    try await index.reconcile(
      productAccountId: session.productAccountId,
      profile: firstProfile,
      profiles: [firstProfile, secondProfile],
      messagesByConnection: [connection.id: [changed]],
      connections: [revokedConnection]
    )
    #expect(backend.deletedItemIdentifiers.count == deletionCount)
    #expect(backend.deletedDomains.count == domainDeletionCount)

    try await index.reconcile(
      productAccountId: session.productAccountId,
      profile: secondProfile,
      profiles: [firstProfile, secondProfile],
      messagesByConnection: [connection.id: [first]],
      connections: [connection]
    )
    #expect(
      backend.deletedDomains.contains([
        MailProfileSpotlightIndex.domainIdentifier(profileId: firstProfile.id)
      ])
    )

    try await index.reconcile(
      productAccountId: session.productAccountId,
      profile: secondProfile,
      profiles: [secondProfile],
      messagesByConnection: [:],
      connections: []
    )
    #expect(
      backend.deletedDomains.contains([
        MailProfileSpotlightIndex.domainIdentifier(profileId: firstProfile.id)
      ])
    )
  }

  @Test
  func spotlightIndexBatchesLargeUpdatesAndUsesCompleteFileProtection() async throws {
    let suiteName = "MailProfileSpotlightBatchTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let backend = RecordingMailProfileSpotlightBackend()
    let index = MailProfileSpotlightIndex(backend: backend, defaults: defaults)
    let profile = MailProfileDefinition.defaultProfile(productAccountId: session.productAccountId)
    let connection = spotlightConnection()

    try await index.reconcile(
      productAccountId: session.productAccountId,
      profile: profile,
      profiles: [profile],
      messagesByConnection: [
        connection.id: (0..<251).map { spotlightMessage(id: "message-\($0)") }
      ],
      connections: [connection]
    )

    #expect(backend.indexedBatches.map(\.count).sorted() == [1, 250])
    #expect(SystemMailProfileSpotlightIndexBackend.protectionClass == .complete)
  }

  @Test
  func spotlightReconciliationDoesNotIndexConcealedProfilesAndRetriesDisabledCleanup()
    async throws
  {
    let suiteName = "MailProfileSpotlightCleanupTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profile = MailProfileDefinition.defaultProfile(productAccountId: session.productAccountId)
    let connection = spotlightConnection()
    let backend = RecordingMailProfileSpotlightBackend()
    let index = MailProfileSpotlightIndex(backend: backend, defaults: defaults)
    let lockStore = RecordingMailProfileLockStore()
    lockStore.configurations[profile.id] = MailProfileLockConfiguration(
      backgroundGracePeriod: .fiveMinutes,
      isEnabled: true
    )
    let viewModel = MailProfileInterruptionViewModel(
      session: session,
      syncService: StubMailProfileInterruptionSyncService(
        snapshot: snapshot(profile: profile)
      ),
      lockStore: lockStore,
      spotlightIndex: index,
      spotlightPreferenceStore: UserDefaultsMailProfileSpotlightStore(defaults: defaults)
    )

    await viewModel.reconcileSpotlight(
      profiles: [profile],
      messagesByConnection: [connection.id: [spotlightMessage(id: "locked")]],
      connectionsByProfile: [profile.id: [connection]]
    )
    #expect(backend.indexedBatches.isEmpty)

    lockStore.configurations[profile.id] = .disabled
    await viewModel.load()
    defaults.set(
      [profile.id.rawValue],
      forKey: "mail-profile-spotlight-indexed.v1.\(session.productAccountId)"
    )
    await viewModel.reconcileSpotlight(
      profiles: [profile],
      messagesByConnection: [:],
      connectionsByProfile: [profile.id: []]
    )
    #expect(
      backend.deletedDomains.contains([
        MailProfileSpotlightIndex.domainIdentifier(profileId: profile.id)
      ])
    )
  }

  @Test
  func lockReengagesExplicitlyAndAfterTheConfiguredBackgroundGrace() async {
    let clock = MutableMailProfileClock(now: Date(timeIntervalSince1970: 1_000))
    let profile = MailProfileDefinition.defaultProfile(productAccountId: session.productAccountId)
    let lockStore = RecordingMailProfileLockStore()
    lockStore.configurations[profile.id] = MailProfileLockConfiguration(
      backgroundGracePeriod: .fiveMinutes,
      isEnabled: true
    )
    let authenticator = RecordingMailProfileLockAuthenticator(results: [true, true])
    let searchIndex = RecordingMailProfileSearchIndex()
    let viewModel = MailProfileInterruptionViewModel(
      session: session,
      syncService: StubMailProfileInterruptionSyncService(
        snapshot: snapshot(profile: profile)
      ),
      lockStore: lockStore,
      authenticator: authenticator,
      searchIndex: searchIndex,
      clock: { clock.now }
    )

    #expect(viewModel.contentIsConcealed)
    await viewModel.load()
    #expect(!viewModel.contentIsConcealed)

    await viewModel.applicationEnteredBackground()
    #expect(viewModel.contentIsConcealed)
    clock.now = clock.now.addingTimeInterval(299)
    await viewModel.applicationBecameActive()
    #expect(!viewModel.contentIsConcealed)
    #expect(authenticator.reasons.count == 1)

    await viewModel.applicationEnteredBackground()
    clock.now = clock.now.addingTimeInterval(301)
    await viewModel.applicationBecameActive()
    #expect(!viewModel.contentIsConcealed)
    #expect(authenticator.reasons.count == 2)

    await viewModel.lockExplicitly()
    #expect(viewModel.contentIsConcealed)
    #expect(searchIndex.profileIds.last == profile.id)
  }

  @Test
  func foregroundRefreshesQuietStateChangedByAnotherTrustedDevice() async {
    let profile = MailProfileDefinition.defaultProfile(productAccountId: session.productAccountId)
    let service = StubMailProfileInterruptionSyncService(snapshot: snapshot(profile: profile))
    let viewModel = MailProfileInterruptionViewModel(
      session: session,
      syncService: service,
      lockStore: RecordingMailProfileLockStore(),
      authenticator: RecordingMailProfileLockAuthenticator(results: []),
      searchIndex: RecordingMailProfileSearchIndex()
    )
    await viewModel.load()

    var remotelyQuietProfile = profile
    remotelyQuietProfile.quietState = .quiet(until: nil)
    service.snapshot = snapshot(profile: remotelyQuietProfile)
    await viewModel.applicationBecameActive()

    #expect(viewModel.quietIsActive)
    #expect(!viewModel.policy.allowsVisibleNotifications)
  }

  @Test
  func inactiveConcealsWithoutConsumingBackgroundGraceAndBackgroundConcealsSpotlight() async {
    let clock = MutableMailProfileClock(now: Date(timeIntervalSince1970: 1_000))
    let profile = MailProfileDefinition.defaultProfile(productAccountId: session.productAccountId)
    let lockStore = RecordingMailProfileLockStore()
    lockStore.configurations[profile.id] = MailProfileLockConfiguration(
      backgroundGracePeriod: .fiveMinutes,
      isEnabled: true
    )
    let authenticator = RecordingMailProfileLockAuthenticator(results: [true, true])
    let searchIndex = RecordingMailProfileSearchIndex()
    let viewModel = MailProfileInterruptionViewModel(
      session: session,
      syncService: StubMailProfileInterruptionSyncService(snapshot: snapshot(profile: profile)),
      lockStore: lockStore,
      authenticator: authenticator,
      searchIndex: searchIndex,
      clock: { clock.now }
    )
    await viewModel.load()

    await viewModel.applicationBecameInactive()
    #expect(viewModel.contentIsConcealed)
    #expect(searchIndex.profileIds == [profile.id])
    clock.now = clock.now.addingTimeInterval(301)
    await viewModel.applicationBecameActive()
    #expect(authenticator.reasons.count == 1)
    #expect(!viewModel.contentIsConcealed)

    await viewModel.applicationEnteredBackground()
    #expect(searchIndex.profileIds == [profile.id, profile.id])
    clock.now = clock.now.addingTimeInterval(301)
    await viewModel.applicationBecameActive()
    #expect(authenticator.reasons.count == 2)
  }

  @Test
  func concurrentUnlockRequestsShareOneAuthenticationAttempt() async {
    let profile = MailProfileDefinition.defaultProfile(productAccountId: session.productAccountId)
    let lockStore = RecordingMailProfileLockStore()
    lockStore.configurations[profile.id] = MailProfileLockConfiguration(
      backgroundGracePeriod: .fiveMinutes,
      isEnabled: true
    )
    let authenticator = SuspendingMailProfileLockAuthenticator()
    let viewModel = MailProfileInterruptionViewModel(
      session: session,
      syncService: StubMailProfileInterruptionSyncService(snapshot: snapshot(profile: profile)),
      lockStore: lockStore,
      authenticator: authenticator,
      searchIndex: RecordingMailProfileSearchIndex()
    )

    let load = Task { await viewModel.load() }
    await authenticator.waitUntilAuthenticationStarts()
    let unlock = Task { await viewModel.unlock() }
    await Task.yield()
    #expect(authenticator.reasons.count == 1)

    authenticator.completeAuthentication(with: true)
    await load.value
    await unlock.value

    #expect(authenticator.reasons.count == 1)
    #expect(!viewModel.contentIsConcealed)
  }

  @Test
  func deviceLockAndAuthenticationFailureKeepEveryContentSurfaceConcealed() async {
    let profile = MailProfileDefinition.defaultProfile(productAccountId: session.productAccountId)
    let lockStore = RecordingMailProfileLockStore()
    lockStore.configurations[profile.id] = MailProfileLockConfiguration(
      backgroundGracePeriod: .fiveMinutes,
      isEnabled: true
    )
    let authenticator = RecordingMailProfileLockAuthenticator(results: [true, false])
    let viewModel = MailProfileInterruptionViewModel(
      session: session,
      syncService: StubMailProfileInterruptionSyncService(
        snapshot: snapshot(profile: profile)
      ),
      lockStore: lockStore,
      authenticator: authenticator,
      searchIndex: RecordingMailProfileSearchIndex()
    )

    await viewModel.load()
    #expect(viewModel.policy.allowsContentReveal)

    await viewModel.protectedDataWillBecomeUnavailable()
    await viewModel.unlock()

    #expect(!viewModel.policy.allowsContentReveal)
    #expect(!viewModel.policy.allowsProactiveSuggestions)
    #expect(viewModel.policy.allowsBackgroundWork)
  }

  private func snapshot(
    profile: MailProfileDefinition,
    assignments: [MailboxConnectionId: MailProfileId] = [:]
  ) -> MailProfileSyncSnapshot {
    MailProfileSyncSnapshot(
      assignments: assignments,
      conflicts: [],
      defaultProfileId: profile.id,
      profiles: [profile],
      updatedAt: 1
    )
  }

  private func spotlightConnection() -> MailboxConnection {
    MailboxConnection(
      authorizationState: .authorized,
      capabilities: .none,
      connectedAt: 0,
      displayName: "Inbox Connection",
      id: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .gmail,
          value: "provider-account"
        )
      ),
      lastVerifiedAt: 0,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 0
    )
  }

  private func spotlightMessage(
    id: String,
    snippet: String = "snippet",
    subject: String? = nil
  ) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: nil,
      connectionId: spotlightConnection().id,
      from: "sender@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: 1_000,
      providerMessageId: id,
      providerStateIds: ["INBOX"],
      providerThreadId: "thread-\(id)",
      recipientHeaders: ["recipient@example.com"],
      replyTo: nil,
      rfcMessageId: nil,
      snippet: snippet,
      subject: subject ?? "Subject \(id)",
      sender: "Sender"
    )
  }
}

private final class StubMailProfileInterruptionSyncService: MailProfileInterruptionSyncing {
  var snapshot: MailProfileSyncSnapshot

  init(snapshot: MailProfileSyncSnapshot) {
    self.snapshot = snapshot
  }

  func loadProfileSnapshot(
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    snapshot
  }

  func saveProfile(
    _ profile: MailProfileDefinition,
    basedOn _: MailProfileDefinition,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    snapshot = MailProfileSyncSnapshot(
      assignments: snapshot.assignments,
      conflicts: snapshot.conflicts,
      defaultProfileId: snapshot.defaultProfileId,
      profiles: snapshot.profiles.map { $0.id == profile.id ? profile : $0 },
      updatedAt: (snapshot.updatedAt ?? 0) + 1
    )
    return snapshot
  }
}

private final class RecordingMailProfileLockStore: MailProfileLockPersisting {
  var configurations: [MailProfileId: MailProfileLockConfiguration] = [:]

  func clear(productAccountId _: String) {
    configurations = [:]
  }

  func load(
    productAccountId _: String,
    profileId: MailProfileId
  ) -> MailProfileLockConfiguration {
    configurations[profileId] ?? .disabled
  }

  func save(
    _ configuration: MailProfileLockConfiguration,
    productAccountId _: String,
    profileId: MailProfileId
  ) {
    configurations[profileId] = configuration
  }
}

@MainActor
private final class RecordingMailProfileLockAuthenticator: MailProfileLockAuthenticating {
  private var results: [Bool]
  private(set) var reasons: [String] = []

  init(results: [Bool]) {
    self.results = results
  }

  func authenticate(reason: String) async throws -> Bool {
    reasons.append(reason)
    return results.isEmpty ? false : results.removeFirst()
  }
}

@MainActor
private final class RecordingMailProfileSearchIndex: MailProfileSearchIndexConcealing {
  private(set) var profileIds: [MailProfileId] = []

  func conceal(profileId: MailProfileId) async throws {
    profileIds.append(profileId)
  }
}

@MainActor
private final class RecordingMailProfileSpotlightBackend: MailProfileSpotlightIndexBackend {
  private(set) var deletedDomains: [[String]] = []
  private(set) var deletedItemIdentifiers: [[String]] = []
  private(set) var indexedBatches: [[MailProfileSpotlightItem]] = []

  func delete(domainIdentifiers: [String]) async throws {
    deletedDomains.append(domainIdentifiers)
  }

  func delete(itemIdentifiers: [String]) async throws {
    deletedItemIdentifiers.append(itemIdentifiers)
  }

  func index(_ items: [MailProfileSpotlightItem]) async throws {
    indexedBatches.append(items)
  }
}

@MainActor
private final class SuspendingMailProfileLockAuthenticator: MailProfileLockAuthenticating {
  private var authenticationContinuation: CheckedContinuation<Bool, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var reasons: [String] = []

  func authenticate(reason: String) async throws -> Bool {
    reasons.append(reason)
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    return await withCheckedContinuation { continuation in
      authenticationContinuation = continuation
    }
  }

  func waitUntilAuthenticationStarts() async {
    guard reasons.isEmpty else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func completeAuthentication(with result: Bool) {
    authenticationContinuation?.resume(returning: result)
    authenticationContinuation = nil
  }
}

private final class MutableMailProfileClock {
  var now: Date

  init(now: Date) {
    self.now = now
  }
}
