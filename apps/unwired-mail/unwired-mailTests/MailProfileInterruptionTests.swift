import Foundation
import Testing

@testable import unwired_mail

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

    viewModel.applicationEnteredBackground()
    #expect(viewModel.contentIsConcealed)
    clock.now = clock.now.addingTimeInterval(299)
    await viewModel.applicationBecameActive()
    #expect(!viewModel.contentIsConcealed)
    #expect(authenticator.reasons.count == 1)

    viewModel.applicationEnteredBackground()
    clock.now = clock.now.addingTimeInterval(301)
    await viewModel.applicationBecameActive()
    #expect(!viewModel.contentIsConcealed)
    #expect(authenticator.reasons.count == 2)

    await viewModel.lockExplicitly()
    #expect(viewModel.contentIsConcealed)
    #expect(searchIndex.profileIds.last == profile.id)
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

private final class MutableMailProfileClock {
  var now: Date

  init(now: Date) {
    self.now = now
  }
}
