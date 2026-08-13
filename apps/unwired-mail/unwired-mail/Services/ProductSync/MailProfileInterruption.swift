import CoreSpotlight
import Foundation
import LocalAuthentication
import Observation

// swiftlint:disable file_length type_body_length

extension MailProfileQuietState {
  static func quiet(until date: Date?) -> Self {
    MailProfileQuietState(
      isQuiet: true,
      quietUntil: date.map { Int64($0.timeIntervalSince1970 * 1_000) }
    )
  }

  func isActive(at date: Date) -> Bool {
    guard isQuiet else { return false }
    guard let quietUntil else { return true }
    return quietUntil > Int64(date.timeIntervalSince1970 * 1_000)
  }

  var endDate: Date? {
    quietUntil.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
  }
}

struct MailProfileInterruptionPolicy: Equatable, Sendable {
  let allowsContentReveal: Bool
  let allowsProactiveSuggestions: Bool
  let allowsVisibleNotifications: Bool

  /// Profile Lock and Quiet never suspend mail work; they only govern presentation.
  let allowsBackgroundWork = true

  init(
    quietState: MailProfileQuietState,
    hasAuthoritativeQuietState: Bool,
    contentIsConcealed: Bool,
    now: Date
  ) {
    let quietIsActive = !hasAuthoritativeQuietState || quietState.isActive(at: now)
    allowsContentReveal = !contentIsConcealed
    allowsProactiveSuggestions = !quietIsActive && !contentIsConcealed
    allowsVisibleNotifications = !quietIsActive
  }
}

protocol MailProfileInterruptionSyncing {
  func loadProfileSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot

  func saveProfile(
    _ profile: MailProfileDefinition,
    basedOn base: MailProfileDefinition,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot
}

extension MailboxConnectionSyncService: MailProfileInterruptionSyncing {}

@MainActor
protocol MailProfileNotificationGate {
  func visibleNotificationsAreSuppressed(
    for connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool
}

@MainActor
struct ProductSyncMailProfileNotificationGate:
  MailProfileNotificationGate
{
  private let lockStore: MailProfileLockPersisting
  private let now: () -> Date
  private let service: MailProfileInterruptionSyncing

  init(
    service: MailProfileInterruptionSyncing = MailboxConnectionSyncService(),
    lockStore: MailProfileLockPersisting = UserDefaultsMailProfileLockStore(),
    now: @escaping () -> Date = { .now }
  ) {
    self.service = service
    self.lockStore = lockStore
    self.now = now
  }

  func visibleNotificationsAreSuppressed(
    for connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool {
    let snapshot = try await service.loadProfileSnapshot(session: session)
    guard
      let profileId = snapshot.assignments[connectionId],
      let profile = snapshot.profiles.first(where: { $0.id == profileId })
    else {
      return true
    }
    let lockConfiguration = lockStore.load(
      productAccountId: session.productAccountId,
      profileId: profile.id
    )
    return profile.quietState.isActive(at: now()) || lockConfiguration.isEnabled
  }
}

enum MailProfileBackgroundGracePeriod: Int, CaseIterable, Codable, Sendable {
  case immediately = 0
  case oneMinute = 60
  case fiveMinutes = 300
  case fifteenMinutes = 900

  var title: String {
    switch self {
    case .immediately:
      return "Immediately"
    case .oneMinute:
      return "After 1 Minute"
    case .fiveMinutes:
      return "After 5 Minutes"
    case .fifteenMinutes:
      return "After 15 Minutes"
    }
  }
}

struct MailProfileLockConfiguration: Codable, Equatable, Sendable {
  var backgroundGracePeriod: MailProfileBackgroundGracePeriod
  var isEnabled: Bool

  static let disabled = MailProfileLockConfiguration(
    backgroundGracePeriod: .fiveMinutes,
    isEnabled: false
  )
}

protocol MailProfileLockPersisting {
  func clear(productAccountId: String)
  func load(productAccountId: String, profileId: MailProfileId) -> MailProfileLockConfiguration
  func save(
    _ configuration: MailProfileLockConfiguration,
    productAccountId: String,
    profileId: MailProfileId
  )
}

struct UserDefaultsMailProfileLockStore: MailProfileLockPersisting {
  private static let keyPrefix = "mail-profile-lock.v1."
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(productAccountId: String) {
    let prefix = Self.keyPrefix + productAccountId + "."
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
      defaults.removeObject(forKey: key)
    }
  }

  func load(
    productAccountId: String,
    profileId: MailProfileId
  ) -> MailProfileLockConfiguration {
    let key = key(productAccountId: productAccountId, profileId: profileId)
    guard let data = defaults.data(forKey: key) else { return .disabled }
    do {
      return try JSONDecoder().decode(MailProfileLockConfiguration.self, from: data)
    } catch {
      defaults.removeObject(forKey: key)
      return .disabled
    }
  }

  func save(
    _ configuration: MailProfileLockConfiguration,
    productAccountId: String,
    profileId: MailProfileId
  ) {
    let key = key(productAccountId: productAccountId, profileId: profileId)
    if let data = try? JSONEncoder().encode(configuration) {
      defaults.set(data, forKey: key)
    }
  }

  private func key(productAccountId: String, profileId: MailProfileId) -> String {
    Self.keyPrefix + productAccountId + "." + profileId.rawValue
  }
}

@MainActor
protocol MailProfileLockAuthenticating {
  func authenticate(reason: String) async throws -> Bool
}

@MainActor
struct LocalMailProfileLockAuthenticator: MailProfileLockAuthenticating {
  func authenticate(reason: String) async throws -> Bool {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      throw error ?? LAError(.authenticationFailed)
    }
    return try await context.evaluatePolicy(
      .deviceOwnerAuthentication,
      localizedReason: reason
    )
  }
}

@MainActor
protocol MailProfileSearchIndexConcealing {
  func conceal(profileId: MailProfileId) async throws
}

@MainActor
struct SystemMailProfileSearchIndexConcealer: MailProfileSearchIndexConcealing {
  static func domainIdentifier(profileId: MailProfileId) -> String {
    "dev.unwired.mail.profile.\(profileId.rawValue)"
  }

  func conceal(profileId: MailProfileId) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      CSSearchableIndex.default().deleteSearchableItems(
        withDomainIdentifiers: [Self.domainIdentifier(profileId: profileId)]
      ) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }
}

@MainActor
@Observable
final class MailProfileInterruptionViewModel {
  private(set) var activeProfile: MailProfileDefinition
  private(set) var contentIsConcealed: Bool
  private(set) var errorMessage: String?
  private(set) var hasAuthoritativeQuietState = false
  private(set) var isAuthenticating = false
  private(set) var isSavingQuietState = false
  private(set) var lockConfiguration: MailProfileLockConfiguration
  private(set) var now: Date

  private let authenticator: MailProfileLockAuthenticating
  private var authenticationWaiters: [CheckedContinuation<Bool, Never>] = []
  private var backgroundedAt: Date?
  private let clock: () -> Date
  private let lockStore: MailProfileLockPersisting
  private var quietExpirationTask: Task<Void, Never>?
  private var requiresAuthentication: Bool
  private let searchIndex: MailProfileSearchIndexConcealing
  private var session: ProductAccountSessionSnapshot
  private let syncService: MailProfileInterruptionSyncing

  init(
    session: ProductAccountSessionSnapshot,
    syncService: MailProfileInterruptionSyncing = MailboxConnectionSyncService(),
    lockStore: MailProfileLockPersisting = UserDefaultsMailProfileLockStore(),
    authenticator: MailProfileLockAuthenticating? = nil,
    searchIndex: MailProfileSearchIndexConcealing? = nil,
    clock: @escaping () -> Date = { .now }
  ) {
    self.session = session
    self.syncService = syncService
    self.lockStore = lockStore
    self.authenticator = authenticator ?? LocalMailProfileLockAuthenticator()
    self.searchIndex = searchIndex ?? SystemMailProfileSearchIndexConcealer()
    self.clock = clock
    let profile = MailProfileDefinition.defaultProfile(productAccountId: session.productAccountId)
    activeProfile = profile
    let configuration = lockStore.load(
      productAccountId: session.productAccountId,
      profileId: profile.id
    )
    lockConfiguration = configuration
    contentIsConcealed = configuration.isEnabled
    requiresAuthentication = configuration.isEnabled
    now = clock()
  }

  var policy: MailProfileInterruptionPolicy {
    MailProfileInterruptionPolicy(
      quietState: activeProfile.quietState,
      hasAuthoritativeQuietState: hasAuthoritativeQuietState,
      contentIsConcealed: contentIsConcealed,
      now: now
    )
  }

  var quietEndDate: Date? { activeProfile.quietState.endDate }

  var quietIsActive: Bool {
    hasAuthoritativeQuietState && activeProfile.quietState.isActive(at: now)
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    guard session.productAccountId != self.session.productAccountId else {
      self.session = session
      return
    }
    quietExpirationTask?.cancel()
    self.session = session
    let profile = MailProfileDefinition.defaultProfile(productAccountId: session.productAccountId)
    activateLocalProfile(profile)
    hasAuthoritativeQuietState = false
  }

  func load(profileId: MailProfileId? = nil) async {
    do {
      let snapshot = try await syncService.loadProfileSnapshot(session: session)
      let selectedProfileId = profileId ?? snapshot.defaultProfileId
      guard let profile = snapshot.profiles.first(where: { $0.id == selectedProfileId }) else {
        throw MailProfileSyncError.profileNotFound
      }
      activateLocalProfile(profile)
      hasAuthoritativeQuietState = true
      errorMessage = nil
      scheduleQuietExpirationRefresh()
      if lockConfiguration.isEnabled {
        await unlock()
      }
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setQuiet(until date: Date?) async {
    await saveQuietState(.quiet(until: date))
  }

  func resumeInterruptions() async {
    await saveQuietState(.inactive)
  }

  func setLockEnabled(_ isEnabled: Bool) async {
    guard isEnabled != lockConfiguration.isEnabled else { return }
    guard
      await authenticate(
        reason: isEnabled
          ? "Enable Profile Lock for \(activeProfile.name)."
          : "Disable Profile Lock for \(activeProfile.name)."
      )
    else { return }
    lockConfiguration.isEnabled = isEnabled
    persistLockConfiguration()
    requiresAuthentication = false
    contentIsConcealed = false
    backgroundedAt = nil
    if isEnabled {
      await concealSearchIndex()
    }
  }

  func setBackgroundGracePeriod(_ gracePeriod: MailProfileBackgroundGracePeriod) {
    lockConfiguration.backgroundGracePeriod = gracePeriod
    persistLockConfiguration()
  }

  func lockExplicitly() async {
    guard lockConfiguration.isEnabled else { return }
    requiresAuthentication = true
    contentIsConcealed = true
    backgroundedAt = nil
    await concealSearchIndex()
  }

  func protectedDataWillBecomeUnavailable() async {
    await lockExplicitly()
  }

  func applicationBecameInactive() async {
    guard lockConfiguration.isEnabled, !isAuthenticating else { return }
    contentIsConcealed = true
    await concealSearchIndex()
  }

  func applicationEnteredBackground() async {
    guard lockConfiguration.isEnabled else { return }
    backgroundedAt = backgroundedAt ?? clock()
    contentIsConcealed = true
    await concealSearchIndex()
  }

  func applicationBecameActive() async {
    await refreshQuietState()
    guard lockConfiguration.isEnabled else {
      contentIsConcealed = false
      backgroundedAt = nil
      return
    }
    let gracePeriod = TimeInterval(lockConfiguration.backgroundGracePeriod.rawValue)
    let graceExpired = backgroundedAt.map { now.timeIntervalSince($0) >= gracePeriod } ?? false
    backgroundedAt = nil
    if requiresAuthentication || graceExpired {
      requiresAuthentication = true
      contentIsConcealed = true
      await concealSearchIndex()
      await unlock()
    } else {
      contentIsConcealed = false
    }
  }

  func unlock() async {
    guard lockConfiguration.isEnabled else {
      contentIsConcealed = false
      requiresAuthentication = false
      return
    }
    guard await authenticate(reason: "Unlock \(activeProfile.name).") else { return }
    requiresAuthentication = false
    contentIsConcealed = false
  }

  private func activateLocalProfile(_ profile: MailProfileDefinition) {
    activeProfile = profile
    lockConfiguration = lockStore.load(
      productAccountId: session.productAccountId,
      profileId: profile.id
    )
    requiresAuthentication = lockConfiguration.isEnabled
    contentIsConcealed = lockConfiguration.isEnabled
    now = clock()
  }

  private func saveQuietState(_ quietState: MailProfileQuietState) async {
    guard hasAuthoritativeQuietState else {
      errorMessage = "Refresh Mail Profiles before changing Quiet."
      return
    }
    isSavingQuietState = true
    defer { isSavingQuietState = false }
    let base = activeProfile
    var edited = base
    edited.quietState = quietState
    do {
      let snapshot = try await syncService.saveProfile(
        edited,
        basedOn: base,
        session: session
      )
      guard let profile = snapshot.profiles.first(where: { $0.id == base.id }) else {
        throw MailProfileSyncError.profileNotFound
      }
      activeProfile = profile
      now = clock()
      scheduleQuietExpirationRefresh()
      if snapshot.conflicts.contains(where: { $0.profileId == base.id && $0.field == .quietState })
      {
        errorMessage = "Quiet changed on another device. Review the synchronized Profile conflict."
      } else {
        errorMessage = nil
      }
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func authenticate(reason: String) async -> Bool {
    if isAuthenticating {
      return await withCheckedContinuation { continuation in
        authenticationWaiters.append(continuation)
      }
    }
    isAuthenticating = true
    let authenticated: Bool
    do {
      authenticated = try await authenticator.authenticate(reason: reason)
      if authenticated {
        errorMessage = nil
      } else {
        errorMessage = "Authentication did not complete."
      }
    } catch is CancellationError {
      authenticated = false
    } catch {
      errorMessage = error.localizedDescription
      authenticated = false
    }
    isAuthenticating = false
    let waiters = authenticationWaiters
    authenticationWaiters.removeAll()
    waiters.forEach { $0.resume(returning: authenticated) }
    return authenticated
  }

  private func refreshQuietState() async {
    now = clock()
    do {
      let snapshot = try await syncService.loadProfileSnapshot(session: session)
      guard let profile = snapshot.profiles.first(where: { $0.id == activeProfile.id }) else {
        throw MailProfileSyncError.profileNotFound
      }
      activeProfile.quietState = profile.quietState
      hasAuthoritativeQuietState = true
      errorMessage = nil
      scheduleQuietExpirationRefresh()
    } catch is CancellationError {
    } catch {
      hasAuthoritativeQuietState = false
      errorMessage = error.localizedDescription
    }
  }

  private func concealSearchIndex() async {
    do {
      try await searchIndex.conceal(profileId: activeProfile.id)
    } catch {
      errorMessage =
        "Profile Lock is active, but Spotlight cleanup must be retried: \(error.localizedDescription)"
    }
  }

  private func persistLockConfiguration() {
    lockStore.save(
      lockConfiguration,
      productAccountId: session.productAccountId,
      profileId: activeProfile.id
    )
  }

  private func scheduleQuietExpirationRefresh() {
    quietExpirationTask?.cancel()
    let scheduledAt = clock()
    now = scheduledAt
    guard let endDate = activeProfile.quietState.endDate, endDate > scheduledAt else { return }
    let remainingDuration = endDate.timeIntervalSince(scheduledAt)
    quietExpirationTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: .seconds(remainingDuration))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self.now = self.clock()
    }
  }
}
