import Combine
import Contacts
import ContactsUI
import CoreFoundation
import EventKitUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

#if canImport(UIKit)
  import UIKit
#endif

// swiftlint:disable file_length

extension View {
  @ViewBuilder
  fileprivate func mailShellPrivacySensitive() -> some View {
    #if MAIL_TEST_BOOTSTRAP
      self
    #else
      privacySensitive()
    #endif
  }
}

extension Notification.Name {
  static let mailboxConnectionsDidChange = Notification.Name(
    "MailboxConnectionsDidChange"
  )
  static let mailboxMetadataDidSynchronize = Notification.Name(
    "MailboxMetadataDidSynchronize"
  )
  static let standardsMailIdleDidChange = Notification.Name(
    "StandardsMailIdleDidChange"
  )
}

enum MailboxSyncNotificationUserInfoKey {
  static let connectionId = "connectionId"
  static let phase = "phase"
  static let productAccountId = "productAccountId"
  static let reloadObservedMetadata = "reloadObservedMetadata"
  static let successfulSyncAt = "successfulSyncAt"
  static let supersedesHistoricalBackfill = "supersedesHistoricalBackfill"
  static let updatesExternalStatusRevision = "updatesExternalStatusRevision"
}

@Observable
final class MailProfileDeepLinkRouter {
  enum Target: Equatable {
    case message(MailMessageDeepLink)
    case profile(MailProfileDeepLink)

    var profileId: MailProfileId {
      switch self {
      case .message(let deepLink): deepLink.profileId
      case .profile(let deepLink): deepLink.profileId
      }
    }
  }

  private(set) var pendingTarget: Target?

  var targetedProfileId: MailProfileId? { pendingTarget?.profileId }

  func route(_ url: URL) {
    if let deepLink = MailMessageDeepLink(url: url) {
      pendingTarget = .message(deepLink)
    } else if let deepLink = MailProfileDeepLink(url: url) {
      pendingTarget = .profile(deepLink)
    }
  }

  func route(profileId: MailProfileId) {
    route(MailProfileDeepLink(profileId: profileId).url)
  }

  func consumeTargetedProfileId() -> MailProfileId? {
    consumeTarget()?.profileId
  }

  func consumeTarget() -> Target? {
    defer { pendingTarget = nil }
    return pendingTarget
  }

}

private actor RemoteMessageContentLoadGate {
  private struct Waiter {
    let continuation: CheckedContinuation<Bool, Never>
    let id: UUID
  }

  private var isAcquired = false
  private var waiters: [Waiter] = []

  func acquire() async -> Bool {
    await acquire(maximumWaitDuration: nil)
  }

  func acquire(maximumWaitDuration: Duration) async -> Bool {
    await acquire(maximumWaitDuration: Optional(maximumWaitDuration))
  }

  private func acquire(maximumWaitDuration: Duration?) async -> Bool {
    guard isAcquired else {
      isAcquired = true
      return true
    }
    if let maximumWaitDuration, maximumWaitDuration <= .zero { return false }
    let waiterId = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        waiters.append(Waiter(continuation: continuation, id: waiterId))
        guard let maximumWaitDuration else { return }
        Task {
          try? await Task.sleep(for: maximumWaitDuration)
          self.cancelWaiter(waiterId)
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterId) }
    }
  }

  func release() {
    guard !waiters.isEmpty else {
      isAcquired = false
      return
    }
    waiters.removeFirst().continuation.resume(returning: true)
  }

  private func cancelWaiter(_ waiterId: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == waiterId }) else { return }
    waiters.remove(at: index).continuation.resume(returning: false)
  }
}

@MainActor
private final class LoadedMessageImageBudget {
  var attachmentByteCount = 0
  let bodyLoadGate = RemoteMessageContentLoadGate()
  var inlineByteCount = 0
  var inlinePixelCount = 0
  var remoteByteCount = 0
  var remotePixelCount = 0
  let loadGate = RemoteMessageContentLoadGate()
}

struct SignOutErrorBanner: View {
  let message: String

  var body: some View {
    Text(message)
      .font(.caption)
      .foregroundStyle(.red)
  }
}

@MainActor
@Observable
final class MailboxWorkCoordinator {
  static let shared = MailboxWorkCoordinator()

  private struct Registration {
    let cancelBodyPrefetch: () async -> Void
    let isBusy: Bool
  }

  private var registrations: [String: [UUID: Registration]] = [:]

  func register(
    productAccountId: String,
    registrationId: UUID,
    cancelBodyPrefetch: @escaping () async -> Void,
    isBusy: Bool
  ) {
    registrations[productAccountId, default: [:]][registrationId] = Registration(
      cancelBodyPrefetch: cancelBodyPrefetch,
      isBusy: isBusy
    )
  }

  func unregister(productAccountId: String, registrationId: UUID) {
    registrations[productAccountId]?[registrationId] = nil
    if registrations[productAccountId]?.isEmpty == true {
      registrations[productAccountId] = nil
    }
  }

  func cancelBodyPrefetch(productAccountId: String) async {
    guard let productRegistrations = registrations[productAccountId] else { return }
    for registration in productRegistrations.values {
      await registration.cancelBodyPrefetch()
    }
  }

  func isBusy(productAccountId: String) -> Bool {
    registrations[productAccountId]?.values.contains(where: \.isBusy) ?? false
  }
}

@MainActor
protocol MailboxSyncSuccessPersisting {
  func clear(
    productAccountId: String
  )

  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  )

  func clear(
    productAccountId: String,
    except connectionIds: Set<MailboxConnectionId>
  )

  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) -> Date?

  func save(
    _ date: Date,
    productAccountId: String,
    connectionId: MailboxConnectionId
  )
}

struct UserDefaultsMailboxSyncSuccessStore: MailboxSyncSuccessPersisting {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(productAccountId: String) {
    let prefix = keyPrefix(productAccountId)
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
      defaults.removeObject(forKey: key)
    }
  }

  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) {
    defaults.removeObject(forKey: key(productAccountId, connectionId))
  }

  func clear(
    productAccountId: String,
    except connectionIds: Set<MailboxConnectionId>
  ) {
    let retainedKeys = Set(connectionIds.map { key(productAccountId, $0) })
    let prefix = keyPrefix(productAccountId)
    for key in defaults.dictionaryRepresentation().keys
    where key.hasPrefix(prefix) && !retainedKeys.contains(key) {
      defaults.removeObject(forKey: key)
    }
  }

  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) -> Date? {
    defaults.object(forKey: key(productAccountId, connectionId)) as? Date
  }

  func save(
    _ date: Date,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) {
    defaults.set(date, forKey: key(productAccountId, connectionId))
  }

  private func key(
    _ productAccountId: String,
    _ connectionId: MailboxConnectionId
  ) -> String {
    "\(keyPrefix(productAccountId))\(connectionId.rawValue)"
  }

  private func keyPrefix(_ productAccountId: String) -> String {
    "mailbox-sync-success.\(productAccountId)."
  }
}

enum MailboxSyncPhase: Equatable {
  case authorizationRequired
  case backfillPending
  case idle
  case syncing
  case offline
  case failed(String)

  static func failure(for error: Error) -> MailboxSyncPhase {
    let error = error as NSError
    guard error.domain == NSURLErrorDomain else {
      return .failed(error.localizedDescription)
    }
    let offlineCodes: Set<URLError.Code> = [
      .dataNotAllowed,
      .internationalRoamingOff,
      .networkConnectionLost,
      .notConnectedToInternet,
    ]
    return offlineCodes.contains(URLError.Code(rawValue: error.code))
      ? .offline : .failed(error.localizedDescription)
  }
}

enum MailboxSyncActivity: Equatable {
  case automatic
  case historicalBackfill
  case initialAvailability
  case userRefresh
}

struct MailboxSyncProgress: Equatable {
  let completedUnitCount: Int
  let totalUnitCount: Int

  var fractionCompleted: Double? {
    guard totalUnitCount > 0 else { return nil }
    return min(1, max(0, Double(completedUnitCount) / Double(totalUnitCount)))
  }
}

struct MailboxSyncStatus: Equatable {
  let activity: MailboxSyncActivity?
  let lastSuccessfulSyncAt: Date?
  let phase: MailboxSyncPhase
  let progress: MailboxSyncProgress?
  let visibleAfter: Date?

  init(
    lastSuccessfulSyncAt: Date?,
    phase: MailboxSyncPhase,
    activity: MailboxSyncActivity? = nil,
    progress: MailboxSyncProgress? = nil,
    visibleAfter: Date? = nil
  ) {
    self.activity = activity
    self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    self.phase = phase
    self.progress = progress
    self.visibleAfter = visibleAfter
  }

  static let idle = MailboxSyncStatus(
    lastSuccessfulSyncAt: nil,
    phase: .idle
  )

  static func authorizationRequired(lastSuccessfulSyncAt: Date?) -> MailboxSyncStatus {
    MailboxSyncStatus(
      lastSuccessfulSyncAt: lastSuccessfulSyncAt,
      phase: .authorizationRequired
    )
  }

  var summary: String {
    switch phase {
    case .authorizationRequired:
      return "Authorization required"
    case .backfillPending:
      return lastSuccessfulSummary(prefix: "Backfill pending")
    case .syncing:
      return "Syncing…"
    case .offline:
      return lastSuccessfulSummary(prefix: "Offline")
    case .failed(let message):
      return lastSuccessfulSummary(prefix: "Sync failed: \(message)")
    case .idle:
      return lastSuccessfulSummary(prefix: nil)
    }
  }

  private func lastSuccessfulSummary(prefix: String?) -> String {
    let lastSuccess =
      if let lastSuccessfulSyncAt {
        "Last synced \(lastSuccessfulSyncAt.formatted(date: .abbreviated, time: .shortened))"
      } else {
        "Not yet synced"
      }
    guard let prefix else { return lastSuccess }
    return "\(prefix) · \(lastSuccess)"
  }
}

enum MailboxStatusSettingsLink {
  static func route(
    for status: MailboxSyncStatus,
    connectionId: MailboxConnectionId
  ) -> SettingsRoute? {
    switch status.phase {
    case .authorizationRequired:
      return .authorization(connectionId: connectionId)
    case .failed:
      return .synchronization(connectionId: connectionId)
    case .backfillPending, .idle, .offline, .syncing:
      return nil
    }
  }
}

struct MailboxSyncOverlayConnection: Equatable, Identifiable {
  let id: MailboxConnectionId
  let name: String
  let status: MailboxSyncStatus
}

struct MailboxSyncOverlayState: Equatable {
  let connections: [MailboxSyncOverlayConnection]
  let progress: Double?
  let retryConnectionIds: [MailboxConnectionId]
  let title: String

  static func aggregate(
    connections: [MailboxSyncOverlayConnection],
    isLoadingInitialAvailability: Bool,
    now: Date
  ) -> Self? {
    let activeConnections = connections.filter { connection in
      guard connection.status.visibleAfter.map({ $0 <= now }) ?? true else { return false }
      return connection.status.phase != .idle
    }
    if activeConnections.isEmpty, isLoadingInitialAvailability {
      return MailboxSyncOverlayState(
        connections: [],
        progress: nil,
        retryConnectionIds: [],
        title: "Making recent mail available…"
      )
    }
    guard !activeConnections.isEmpty else { return nil }

    let retryConnectionIds = activeConnections.compactMap { connection in
      switch connection.status.phase {
      case .failed, .offline:
        return connection.id
      case .authorizationRequired, .backfillPending, .idle, .syncing:
        return nil
      }
    }
    let failures = activeConnections.count { connection in
      switch connection.status.phase {
      case .authorizationRequired, .failed, .offline:
        return true
      case .backfillPending, .idle, .syncing:
        return false
      }
    }
    let progressValues = activeConnections.compactMap { $0.status.progress?.fractionCompleted }
    let progress =
      progressValues.count == activeConnections.count
      ? progressValues.reduce(0, +) / Double(progressValues.count)
      : nil
    return MailboxSyncOverlayState(
      connections: activeConnections,
      progress: progress,
      retryConnectionIds: retryConnectionIds,
      title: title(for: activeConnections, failures: failures)
    )
  }

  private static func title(
    for connections: [MailboxSyncOverlayConnection],
    failures: Int
  ) -> String {
    if failures > 0 {
      return failures == 1
        ? "1 connection needs attention" : "\(failures) connections need attention"
    }
    if connections.contains(where: { $0.status.activity == .historicalBackfill }) {
      return connections.count == 1 ? "Loading older mail…" : "Loading older mailboxes…"
    }
    if connections.contains(where: { $0.status.activity == .initialAvailability }) {
      return "Making recent mail available…"
    }
    if connections.contains(where: { $0.status.activity == .userRefresh }) {
      return connections.count == 1 ? "Refreshing mailbox…" : "Refreshing mailboxes…"
    }
    if connections.contains(where: { $0.status.phase == .backfillPending }) {
      return "Older mail will continue loading"
    }
    return connections.count == 1 ? "Synchronizing mailbox…" : "Synchronizing mailboxes…"
  }
}

// swiftlint:disable type_body_length
@MainActor
@Observable
final class MailboxFreshnessViewModel {
  private struct HistoricalBackfill {
    let cancel: () -> Void
    let completion: Task<Void, Never>
    let id: UUID
  }

  private struct InFlightSync {
    let id: UUID
    let task: Task<MailboxMetadataSyncResult, Error>
  }

  private struct InFlightSyncKey: Hashable {
    let connectionId: MailboxConnectionId
    let scope: SyncScope
  }

  private enum SyncScope: Hashable {
    case full
    case recent
  }

  private static let activePollInterval = Duration.seconds(300)

  private let blockedSenderEnforcer: BlockedSenderEnforcing
  private var inFlightSyncs: [InFlightSyncKey: InFlightSync] = [:]
  private let isSessionCurrent: (ProductAccountSessionSnapshot) -> Bool
  private let isSessionIdentityCurrent: (ProductAccountSessionSnapshot) -> Bool
  private let now: () -> Date
  private let service: MailboxMetadataSyncing
  private var session: ProductAccountSessionSnapshot
  private let sleep: (Duration) async throws -> Void
  private let successStore: MailboxSyncSuccessPersisting
  private var externalStatusRevisions: [MailboxConnectionId: UInt64] = [:]
  private var externalSyncRevisions: [MailboxConnectionId: UInt64] = [:]
  private var historicalBackfills: [MailboxConnectionId: HistoricalBackfill] = [:]
  private var knownConnections: [MailboxConnectionId: MailboxConnection] = [:]
  private var statuses: [MailboxConnectionId: MailboxSyncStatus] = [:]

  init(
    service: MailboxMetadataSyncing,
    session: ProductAccountSessionSnapshot,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool,
    isSessionIdentityCurrent: ((ProductAccountSessionSnapshot) -> Bool)? = nil,
    blockedSenderEnforcer: BlockedSenderEnforcing = NoopBlockedSenderEnforcer(),
    now: @escaping () -> Date = Date.init,
    successStore: MailboxSyncSuccessPersisting? = nil,
    sleep: @escaping (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.blockedSenderEnforcer = blockedSenderEnforcer
    self.isSessionCurrent = isSessionCurrent
    self.isSessionIdentityCurrent = isSessionIdentityCurrent ?? isSessionCurrent
    self.now = now
    self.service = service
    self.session = session
    self.sleep = sleep
    self.successStore = successStore ?? UserDefaultsMailboxSyncSuccessStore()
  }

  var isSynchronizing: Bool {
    !inFlightSyncs.isEmpty
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    self.session = session
  }

  func isHistoricalBackfillRunning(for connectionIds: Set<MailboxConnectionId>) -> Bool {
    !connectionIds.isDisjoint(with: historicalBackfills.keys)
  }

  func historicalBackfillConnectionIds(
    in connectionIds: Set<MailboxConnectionId>
  ) -> Set<MailboxConnectionId> {
    connectionIds.intersection(historicalBackfills.keys)
  }

  var lastSuccessfulSyncAt: Date? {
    knownConnections.values.compactMap { status(for: $0).lastSuccessfulSyncAt }.max()
  }

  func status(for connection: MailboxConnection) -> MailboxSyncStatus {
    let lastSuccessfulSyncAt =
      statuses[connection.id]?.lastSuccessfulSyncAt
      ?? successStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    if connection.authorizationState == .required {
      return .authorizationRequired(lastSuccessfulSyncAt: lastSuccessfulSyncAt)
    }
    let status =
      statuses[connection.id]
      ?? MailboxSyncStatus(lastSuccessfulSyncAt: lastSuccessfulSyncAt, phase: .idle)
    guard hasInFlightSync(connectionId: connection.id), status.phase != .syncing else {
      return status
    }
    return MailboxSyncStatus(
      lastSuccessfulSyncAt: lastSuccessfulSyncAt,
      phase: .syncing,
      activity: status.activity,
      progress: status.progress,
      visibleAfter: status.visibleAfter
    )
  }

  func isHistoricalBackfillActive(for connection: MailboxConnection) -> Bool {
    historicalBackfills[connection.id] != nil
  }

  func recordExternalSync(
    connectionIdRawValue: String,
    phase: MailboxSyncPhase,
    successfulSyncAt: Date?,
    supersedesHistoricalBackfill: Bool = true,
    updatesExternalStatusRevision: Bool = true
  ) {
    guard
      let connection = knownConnections.values.first(where: {
        $0.id.rawValue == connectionIdRawValue
      })
    else { return }
    if updatesExternalStatusRevision {
      externalStatusRevisions[connection.id, default: 0] += 1
    }
    if supersedesHistoricalBackfill {
      externalSyncRevisions[connection.id, default: 0] += 1
    }
    let currentStatus = status(for: connection)
    if let successfulSyncAt {
      successStore.save(
        successfulSyncAt,
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    }
    let reportedPhase =
      if hasInFlightSync(connectionId: connection.id), phase != .syncing {
        MailboxSyncPhase.syncing
      } else {
        phase
      }
    statuses[connection.id] = MailboxSyncStatus(
      lastSuccessfulSyncAt: successfulSyncAt ?? currentStatus.lastSuccessfulSyncAt,
      phase: reportedPhase,
      activity: reportedPhase == .syncing ? .automatic : nil,
      visibleAfter: reportedPhase == .syncing ? now().addingTimeInterval(1) : nil
    )
  }

  func updateConnections(
    _ connections: [MailboxConnection],
    prunesPersistedState: Bool = true
  ) {
    let updatedConnections = Dictionary(
      uniqueKeysWithValues: connections.map { ($0.id, $0) }
    )
    let connectionIds = Set(updatedConnections.keys)
    let activeConnectionIds = Set(
      connections.lazy
        .filter { $0.authorizationState == .authorized }
        .map(\.id)
    )
    if prunesPersistedState {
      successStore.clear(
        productAccountId: session.productAccountId,
        except: connectionIds
      )
    }
    for connectionId in historicalBackfills.keys where !activeConnectionIds.contains(connectionId) {
      historicalBackfills[connectionId]?.cancel()
      historicalBackfills[connectionId] = nil
    }
    for key in inFlightSyncs.keys where !activeConnectionIds.contains(key.connectionId) {
      inFlightSyncs[key]?.task.cancel()
      inFlightSyncs[key] = nil
    }
    for connectionId in statuses.keys where !connectionIds.contains(connectionId) {
      statuses[connectionId] = nil
    }
    knownConnections = updatedConnections
  }

  func updateConnections(
    _ connections: [MailboxConnection],
    snapshotIsAuthoritative: Bool,
    prunesPersistedState: Bool = true
  ) {
    guard snapshotIsAuthoritative else { return }
    updateConnections(connections, prunesPersistedState: prunesPersistedState)
  }

  func clearPersistedState() {
    successStore.clear(productAccountId: session.productAccountId)
    knownConnections.removeAll()
    statuses.removeAll()
  }

  func synchronize(
    connections: [MailboxConnection],
    snapshotIsAuthoritative: Bool = true
  ) async {
    guard snapshotIsAuthoritative else { return }
    _ = await synchronize(connections: connections, gmailScope: .recent)
  }

  func synchronizeFully(
    connections: [MailboxConnection],
    snapshotIsAuthoritative: Bool = true
  ) async {
    guard snapshotIsAuthoritative else { return }
    _ = await synchronize(connections: connections, gmailScope: .full)
  }

  func synchronizeFully(
    connection: MailboxConnection,
    among connections: [MailboxConnection],
    snapshotIsAuthoritative: Bool = true
  ) async {
    guard snapshotIsAuthoritative else { return }
    let synchronizedConnectionIds = await synchronize(
      connections: connections,
      targetConnections: [connection],
      gmailScope: .full
    )
    guard synchronizedConnectionIds.contains(connection.id) else { return }
    let status = status(for: connection)
    var userInfo: [AnyHashable: Any] = [
      MailboxSyncNotificationUserInfoKey.connectionId: connection.id.rawValue,
      MailboxSyncNotificationUserInfoKey.phase: status.phase,
      MailboxSyncNotificationUserInfoKey.productAccountId: session.productAccountId,
      MailboxSyncNotificationUserInfoKey.reloadObservedMetadata: true,
      MailboxSyncNotificationUserInfoKey.supersedesHistoricalBackfill: false,
      MailboxSyncNotificationUserInfoKey.updatesExternalStatusRevision: false,
    ]
    if let successfulSyncAt = status.lastSuccessfulSyncAt {
      userInfo[MailboxSyncNotificationUserInfoKey.successfulSyncAt] = successfulSyncAt
    }
    NotificationCenter.default.post(
      name: .mailboxMetadataDidSynchronize,
      object: nil,
      userInfo: userInfo
    )
  }

  private func synchronize(
    connections: [MailboxConnection],
    targetConnections: [MailboxConnection]? = nil,
    gmailScope: SyncScope
  ) async -> Set<MailboxConnectionId> {
    guard isSessionCurrent(session) else {
      cancelAll()
      return []
    }
    var synchronizedConnectionIds: Set<MailboxConnectionId> = []
    updateConnections(connections, prunesPersistedState: false)
    let connectionIds = Set(connections.map(\.id))
    statuses = statuses.filter { connectionIds.contains($0.key) }
    for connection in targetConnections ?? connections {
      guard connection.authorizationState == .authorized else {
        statuses[connection.id] = .authorizationRequired(
          lastSuccessfulSyncAt: successStore.load(
            productAccountId: session.productAccountId,
            connectionId: connection.id
          )
        )
        continue
      }
      guard connection.capabilities.canSynchronizeMetadata else { continue }
      do {
        let result =
          if connection.providerId == .gmail, gmailScope == .recent {
            try await syncRecentInbox(connection: connection, session: session)
          } else {
            try await syncInbox(connection: connection, session: session)
          }
        if result.historicalMetadataBackfillCanResume,
          !result.historicalMetadataBackfillIsComplete
        {
          startHistoricalBackfill(connection: connection)
        }
        synchronizedConnectionIds.insert(connection.id)
      } catch is CancellationError {
        return synchronizedConnectionIds
      } catch {
        continue
      }
    }
    return synchronizedConnectionIds
  }

  func syncInbox(
    connection: MailboxConnection,
    session requestedSession: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await synchronizeInbox(
      connection: connection,
      session: requestedSession,
      scope: .full,
      activity: nil
    )
  }

  private func syncRecentInbox(
    connection: MailboxConnection,
    session requestedSession: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await synchronizeInbox(
      connection: connection,
      session: requestedSession,
      scope: .recent,
      activity: .automatic
    )
  }

  // swiftlint:disable:next function_body_length
  private func synchronizeInbox(
    connection: MailboxConnection,
    session requestedSession: ProductAccountSessionSnapshot,
    scope: SyncScope,
    activity requestedActivity: MailboxSyncActivity?
  ) async throws -> MailboxMetadataSyncResult {
    guard requestedSession == session, isSessionCurrent(session) else {
      throw CancellationError()
    }
    await cancelHistoricalBackfill(connectionId: connection.id)
    let syncKey = InFlightSyncKey(connectionId: connection.id, scope: scope)
    if let inFlightSync = inFlightSyncs[syncKey] {
      return try await inFlightSync.task.value
    }

    let priorStatus = status(for: connection)
    let activity =
      requestedActivity
      ?? (priorStatus.lastSuccessfulSyncAt == nil ? .initialAvailability : .userRefresh)
    statuses[connection.id] = MailboxSyncStatus(
      lastSuccessfulSyncAt: priorStatus.lastSuccessfulSyncAt,
      phase: .syncing,
      activity: activity,
      visibleAfter: activity == .automatic ? now().addingTimeInterval(1) : nil
    )
    let syncId = UUID()
    let task = Task {
      switch scope {
      case .full:
        try await service.syncInbox(
          connection: connection,
          session: requestedSession
        )
      case .recent:
        try await service.syncRecentInbox(
          connection: connection,
          includingHistoryCandidates: false,
          session: requestedSession,
          sinceHistoryId: nil,
          throughHistoryId: nil,
          shouldPersist: { !Task.isCancelled }
        )
      }
    }
    inFlightSyncs[syncKey] = InFlightSync(id: syncId, task: task)

    do {
      let synchronizedResult = try await task.value
      guard isSessionCurrent(session), knownConnections[connection.id] != nil else {
        throw CancellationError()
      }
      let result = await blockedSenderEnforcer.enforce(
        synchronizedResult,
        connection: connection,
        session: requestedSession
      )
      guard isSessionCurrent(session), knownConnections[connection.id] != nil else {
        throw CancellationError()
      }
      removeSync(key: syncKey, syncId: syncId)
      if !Task.isCancelled, connection.providerId == .imapSMTP,
        connection.capabilities.canRegisterPush,
        let pushService = service as? any MailboxPushRegistering
      {
        Task {
          try? await pushService.registerOrRenewPush(
            connection: connection,
            session: requestedSession
          )
        }
      }
      let completionDate = now()
      successStore.save(
        completionDate,
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
      statuses[connection.id] = MailboxSyncStatus(
        lastSuccessfulSyncAt: completionDate,
        phase: .idle
      )
      try Task.checkCancellation()
      return result
    } catch is CancellationError {
      removeSync(key: syncKey, syncId: syncId)
      statuses[connection.id] = MailboxSyncStatus(
        lastSuccessfulSyncAt: status(for: connection).lastSuccessfulSyncAt,
        phase: .idle
      )
      throw CancellationError()
    } catch {
      removeSync(key: syncKey, syncId: syncId)
      if Self.isCancellation(error) {
        statuses[connection.id] = MailboxSyncStatus(
          lastSuccessfulSyncAt: status(for: connection).lastSuccessfulSyncAt,
          phase: .idle
        )
        throw CancellationError()
      }
      statuses[connection.id] = MailboxSyncStatus(
        lastSuccessfulSyncAt: status(for: connection).lastSuccessfulSyncAt,
        phase: .failure(for: error)
      )
      throw error
    }
  }

  // swiftlint:disable:next function_body_length
  func continueHistoricalBackfill(
    connection: MailboxConnection,
    session requestedSession: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    guard requestedSession == session, isSessionCurrent(session) else {
      throw CancellationError()
    }
    await cancelHistoricalBackfill(connectionId: connection.id)
    let priorStatus = status(for: connection)
    let externalStatusRevision = externalStatusRevisions[connection.id, default: 0]
    let externalSyncRevision = externalSyncRevisions[connection.id, default: 0]
    statuses[connection.id] = MailboxSyncStatus(
      lastSuccessfulSyncAt: priorStatus.lastSuccessfulSyncAt,
      phase: .syncing,
      activity: .historicalBackfill,
      visibleAfter: now().addingTimeInterval(1)
    )
    let backfillId = UUID()
    let resultTask = Task {
      let result = try await service.continueHistoricalBackfill(
        connection: connection,
        session: requestedSession
      )
      try Task.checkCancellation()
      return result
    }
    let completion = Task {
      _ = try? await resultTask.value
    }
    historicalBackfills[connection.id] = HistoricalBackfill(
      cancel: { resultTask.cancel() },
      completion: completion,
      id: backfillId
    )
    defer {
      removeHistoricalBackfill(connectionId: connection.id, backfillId: backfillId)
    }

    do {
      let result = try await withTaskCancellationHandler {
        try await resultTask.value
      } onCancel: {
        resultTask.cancel()
      }
      guard isSessionCurrent(session) else {
        throw CancellationError()
      }
      finishHistoricalBackfill(
        connection: connection,
        externalStatusRevision: externalStatusRevision,
        externalSyncRevision: externalSyncRevision,
        priorStatus: priorStatus,
        result: .success(result)
      )
      return result
    } catch {
      if Task.isCancelled || error is CancellationError || Self.isCancellation(error) {
        finishHistoricalBackfill(
          connection: connection,
          externalStatusRevision: externalStatusRevision,
          externalSyncRevision: externalSyncRevision,
          priorStatus: priorStatus,
          result: .failure(error)
        )
        throw CancellationError()
      }
      finishHistoricalBackfill(
        connection: connection,
        externalStatusRevision: externalStatusRevision,
        externalSyncRevision: externalSyncRevision,
        priorStatus: priorStatus,
        result: .failure(error)
      )
      throw error
    }
  }

  func pollWhileActive(
    connections: @escaping () -> [MailboxConnection],
    snapshotIsAuthoritative: @escaping () -> Bool = { true },
    revalidateTrustedDevice: @escaping () async -> Bool = { true },
    didSynchronize: @escaping () async -> Void
  ) async {
    while isSessionIdentityCurrent(session) {
      do {
        try await sleep(Self.activePollInterval)
      } catch {
        return
      }
      guard !Task.isCancelled, isSessionIdentityCurrent(session) else { return }
      guard await revalidateTrustedDevice() else { return }
      guard !Task.isCancelled, isSessionIdentityCurrent(session) else { return }
      guard snapshotIsAuthoritative() else { continue }
      await synchronize(connections: connections(), snapshotIsAuthoritative: true)
      guard !Task.isCancelled, isSessionIdentityCurrent(session) else { return }
      await didSynchronize()
    }
  }

  func cancelAll() {
    for sync in inFlightSyncs.values {
      sync.task.cancel()
    }
    for backfill in historicalBackfills.values {
      backfill.cancel()
    }
    inFlightSyncs.removeAll()
    historicalBackfills.removeAll()
    statuses = statuses.mapValues { status in
      guard status.phase == .syncing else { return status }
      return MailboxSyncStatus(
        lastSuccessfulSyncAt: status.lastSuccessfulSyncAt,
        phase: .idle
      )
    }
  }

  private func hasInFlightSync(connectionId: MailboxConnectionId) -> Bool {
    inFlightSyncs.keys.contains { $0.connectionId == connectionId }
  }

  private func removeSync(key: InFlightSyncKey, syncId: UUID) {
    guard inFlightSyncs[key]?.id == syncId else { return }
    inFlightSyncs[key] = nil
  }

  private func startHistoricalBackfill(connection: MailboxConnection) {
    guard historicalBackfills[connection.id] == nil else { return }
    let priorStatus = status(for: connection)
    let externalStatusRevision = externalStatusRevisions[connection.id, default: 0]
    let externalSyncRevision = externalSyncRevisions[connection.id, default: 0]
    statuses[connection.id] = MailboxSyncStatus(
      lastSuccessfulSyncAt: priorStatus.lastSuccessfulSyncAt,
      phase: .syncing,
      activity: .historicalBackfill,
      visibleAfter: now().addingTimeInterval(1)
    )
    let backfillId = UUID()
    let service = service
    let session = session
    let task = Task { [weak self, service, session] in
      defer {
        self?.removeHistoricalBackfill(
          connectionId: connection.id,
          backfillId: backfillId
        )
      }
      do {
        let result = try await service.continueHistoricalBackfill(
          connection: connection,
          session: session
        )
        self?.finishHistoricalBackfill(
          connection: connection,
          externalStatusRevision: externalStatusRevision,
          externalSyncRevision: externalSyncRevision,
          priorStatus: priorStatus,
          result: .success(result)
        )
      } catch {
        self?.finishHistoricalBackfill(
          connection: connection,
          externalStatusRevision: externalStatusRevision,
          externalSyncRevision: externalSyncRevision,
          priorStatus: priorStatus,
          result: .failure(error)
        )
      }
    }
    historicalBackfills[connection.id] = HistoricalBackfill(
      cancel: { task.cancel() },
      completion: task,
      id: backfillId
    )
  }

  private func removeHistoricalBackfill(
    connectionId: MailboxConnectionId,
    backfillId: UUID
  ) {
    guard historicalBackfills[connectionId]?.id == backfillId else { return }
    historicalBackfills[connectionId] = nil
  }

  private func cancelHistoricalBackfill(connectionId: MailboxConnectionId) async {
    guard let backfill = historicalBackfills[connectionId] else { return }
    backfill.cancel()
    await backfill.completion.value
    removeHistoricalBackfill(connectionId: connectionId, backfillId: backfill.id)
  }

  // swiftlint:disable:next function_body_length
  private func finishHistoricalBackfill(
    connection: MailboxConnection,
    externalStatusRevision: UInt64,
    externalSyncRevision: UInt64,
    priorStatus: MailboxSyncStatus,
    result: Result<MailboxMetadataSyncResult, Error>
  ) {
    guard
      isSessionCurrent(session),
      knownConnections[connection.id]?.authorizationGeneration
        == connection.authorizationGeneration
    else { return }
    var successfulSyncAt: Date?
    var supersedesHistoricalBackfill = true
    switch result {
    case .success(let result):
      let completionDate = now()
      successfulSyncAt = completionDate
      successStore.save(
        completionDate,
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
      if Task.isCancelled
        || !externalSyncRevisionIsCurrent(externalSyncRevision, for: connection.id)
      {
        supersedesHistoricalBackfill = false
      } else {
        statuses[connection.id] = MailboxSyncStatus(
          lastSuccessfulSyncAt: completionDate,
          phase: result.historicalMetadataBackfillIsComplete ? .idle : .backfillPending
        )
      }
    case .failure(let error):
      if Task.isCancelled || Self.isCancellation(error) {
        if externalSyncRevisionIsCurrent(externalSyncRevision, for: connection.id),
          externalStatusIsCurrent(externalStatusRevision, for: connection.id)
        {
          statuses[connection.id] = priorStatus
        }
        supersedesHistoricalBackfill = false
        break
      }
      guard
        externalSyncRevisionIsCurrent(externalSyncRevision, for: connection.id),
        externalStatusIsCurrent(externalStatusRevision, for: connection.id)
      else {
        supersedesHistoricalBackfill = false
        break
      }
      statuses[connection.id] = MailboxSyncStatus(
        lastSuccessfulSyncAt: priorStatus.lastSuccessfulSyncAt,
        phase: .failure(for: error)
      )
    }
    var userInfo: [AnyHashable: Any] = [
      MailboxSyncNotificationUserInfoKey.connectionId: connection.id.rawValue,
      MailboxSyncNotificationUserInfoKey.phase: statuses[connection.id]?.phase
        ?? MailboxSyncPhase.idle,
      MailboxSyncNotificationUserInfoKey.productAccountId: session.productAccountId,
      MailboxSyncNotificationUserInfoKey.reloadObservedMetadata: true,
      MailboxSyncNotificationUserInfoKey.supersedesHistoricalBackfill:
        supersedesHistoricalBackfill,
    ]
    if let successfulSyncAt {
      userInfo[MailboxSyncNotificationUserInfoKey.successfulSyncAt] = successfulSyncAt
    }
    NotificationCenter.default.post(
      name: .mailboxMetadataDidSynchronize,
      object: nil,
      userInfo: userInfo
    )
  }

  private func externalSyncRevisionIsCurrent(
    _ revision: UInt64,
    for connectionId: MailboxConnectionId
  ) -> Bool {
    externalSyncRevisions[connectionId, default: 0] == revision
  }

  private func externalStatusIsCurrent(
    _ revision: UInt64,
    for connectionId: MailboxConnectionId
  ) -> Bool {
    externalStatusRevisions[connectionId, default: 0] == revision
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
      return true
    }
    let error = error as NSError
    return error.domain == NSURLErrorDomain
      && error.code == URLError.cancelled.rawValue
  }
}
// swiftlint:enable type_body_length

@MainActor
func waitForCurrentMailboxLoad(
  _ currentLoad: () -> (task: Task<Void, Never>?, generation: Int)
) async {
  while true {
    let load = currentLoad()
    guard let task = load.task else { return }
    await task.value
    guard currentLoad().generation != load.generation else { return }
  }
}

@MainActor
private final class MainRunLoopCycleWaiter {
  private var continuation: CheckedContinuation<Void, Never>?
  private var observer: CFRunLoopObserver?
  private var timer: CFRunLoopTimer?

  func wait() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume()
          return
        }
        self.continuation = continuation
        let observer = CFRunLoopObserverCreateWithHandler(
          nil,
          CFRunLoopActivity.afterWaiting.rawValue,
          false,
          0
        ) { [weak self] _, _ in
          Task { @MainActor in self?.finish() }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let timer = CFRunLoopTimerCreateWithHandler(
          nil,
          CFAbsoluteTimeGetCurrent() + 0.05,
          0,
          0,
          0
        ) { [weak self] _ in
          Task { @MainActor in self?.finish() }
        }
        self.timer = timer
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish() }
    }
  }

  private func finish() {
    guard let continuation else { return }
    self.continuation = nil
    if let observer {
      CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
      self.observer = nil
    }
    if let timer {
      CFRunLoopRemoveTimer(CFRunLoopGetMain(), timer, .commonModes)
      self.timer = nil
    }
    continuation.resume()
  }
}

@MainActor
func waitForNextMainRunLoopCycle() async {
  await MainRunLoopCycleWaiter().wait()
}

func newlyFailedConnectionIds(
  from oldIds: [MailboxConnectionId],
  to newIds: [MailboxConnectionId],
  mailboxObserversAreActive: Bool
) -> [MailboxConnectionId] {
  guard mailboxObserversAreActive else { return [] }
  return newIds.filter { !oldIds.contains($0) }
}

func profileScopedOutboxItems(
  _ items: [OutgoingDeliveryAttempt],
  connectionIds: Set<MailboxConnectionId>
) -> [OutgoingDeliveryAttempt] {
  items.filter { connectionIds.contains($0.mailboxConnectionId) }
}

func profileScopedScheduledSendItems(
  _ items: [ManagedScheduledSend],
  profileId: MailProfileId
) -> [ManagedScheduledSend] {
  items.filter { $0.record.profileId == profileId }
}

func standardsMailIdleConnection(
  rawConnectionId: String,
  accountConnections: [MailboxConnection]
) -> MailboxConnection? {
  accountConnections.first { $0.id.rawValue == rawConnectionId }
}

func profileScopedCacheClearConnections(
  selectedConnection: MailboxConnection?,
  profileConnections: [MailboxConnection]
) -> [MailboxConnection] {
  selectedConnection.map { [$0] } ?? profileConnections
}

func compositionDraftCanBePresented(
  originatingProfileId: MailProfileId,
  activeProfileId: MailProfileId?
) -> Bool {
  originatingProfileId == activeProfileId
}

@MainActor
func profileConnectionAfterActivation(
  _ connectionId: MailboxConnectionId,
  activate: () async -> Bool,
  connections: () -> [MailboxConnection]
) async -> MailboxConnection? {
  guard await activate() else { return nil }
  return connections().first { $0.id == connectionId }
}

@MainActor
final class MailShellReleaseBudgetDriver {
  private var mailViewSelectionHandler: ((MailViewSelection) -> Void)?
  private var profileSelectionHandler: ((MailProfileId) async -> Void)?
  private var selectionHandlerOwner: UUID?
  fileprivate var selectMailboxHandler: ((MailShellMailboxSelection) -> Void)?
  private(set) var activeProfileId: MailProfileId?
  private(set) var activeProfileRecordScope: MailProfileRecordScope?
  private(set) var renderedItemIds: Set<MailboxThreadIdentity> = []

  func installSelectionHandler(
    owner: UUID,
    mailbox handler: @escaping (MailShellMailboxSelection) -> Void,
    mailView: @escaping (MailViewSelection) -> Void
  ) {
    selectionHandlerOwner = owner
    renderedItemIds = []
    selectMailboxHandler = handler
    mailViewSelectionHandler = mailView
  }

  func removeSelectionHandler(owner: UUID) {
    guard selectionHandlerOwner == owner else { return }
    selectionHandlerOwner = nil
    selectMailboxHandler = nil
    mailViewSelectionHandler = nil
    profileSelectionHandler = nil
    activeProfileId = nil
    activeProfileRecordScope = nil
  }

  func installProfileSelectionHandler(
    owner: UUID,
    handler: @escaping (MailProfileId) async -> Void
  ) {
    guard selectionHandlerOwner == owner else { return }
    profileSelectionHandler = handler
  }

  func selectMailbox(_ mailbox: MailShellMailboxSelection) {
    renderedItemIds = []
    selectMailboxHandler?(mailbox)
  }

  func selectMailView(_ mailView: MailViewSelection) {
    renderedItemIds = []
    mailViewSelectionHandler?(mailView)
  }

  func selectProfile(_ profileId: MailProfileId) async {
    renderedItemIds = []
    await profileSelectionHandler?(profileId)
  }

  func recordActiveProfileId(_ profileId: MailProfileId?, owner: UUID) {
    guard selectionHandlerOwner == owner else { return }
    activeProfileId = profileId
  }

  func recordActiveProfileRecordScope(_ scope: MailProfileRecordScope?, owner: UUID) {
    guard selectionHandlerOwner == owner else { return }
    activeProfileRecordScope = scope
  }

  func recordRenderedItemId(_ itemId: MailboxThreadIdentity, owner: UUID) {
    guard selectionHandlerOwner == owner else { return }
    renderedItemIds.insert(itemId)
  }
}

enum MailProfileContentPresentationDismissal {
  static func dismissRoot(
    showsMessageActionAlert: inout Bool,
    composerNavigation: inout MailShellComposerNavigationState,
    composerSendErrorMessage: inout String,
    showsComposerSendError: inout Bool,
    compactSettingsIsPresented: inout Bool
  ) {
    if showsMessageActionAlert {
      showsMessageActionAlert = false
    }
    composerNavigation.dismissAll()
    if !composerSendErrorMessage.isEmpty {
      composerSendErrorMessage = ""
    }
    if showsComposerSendError {
      showsComposerSendError = false
    }
    if compactSettingsIsPresented {
      compactSettingsIsPresented = false
    }
  }

  static func dismissReader<CategorySelection>(
    categorySelection: inout CategorySelection?,
    messageActionError: inout String?
  ) {
    if categorySelection != nil {
      categorySelection = nil
    }
    if messageActionError != nil {
      messageActionError = nil
    }
  }
}

protocol MailProfileSnapshotLoading {
  func loadProfileSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot
}

extension MailboxConnectionSyncService: MailProfileSnapshotLoading {}

@MainActor
@Observable
final class MailProfileWorkspaceViewModel {
  private(set) var errorMessage: String?
  private(set) var isLoading = false
  private(set) var selection: MailProfileWorkspaceSelection?
  private(set) var startupProfileId: MailProfileId?

  private var session: ProductAccountSessionSnapshot
  private var loadGeneration = 0
  private let snapshotLoader: MailProfileSnapshotLoading
  private let startupStore: MailProfileStartupSelectionPersisting

  init(
    session: ProductAccountSessionSnapshot,
    snapshotLoader: MailProfileSnapshotLoading = MailboxConnectionSyncService(),
    startupStore: MailProfileStartupSelectionPersisting =
      UserDefaultsMailProfileStartupStore()
  ) {
    self.session = session
    self.snapshotLoader = snapshotLoader
    self.startupStore = startupStore
    startupProfileId = startupStore.load(productAccountId: session.productAccountId)
  }

  var activeProfile: MailProfileDefinition? { selection?.activeProfile }
  var activeProfileId: MailProfileId? { selection?.activeProfileId }

  var profiles: [MailProfileDefinition] {
    selection?.snapshot.profiles.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    } ?? []
  }

  var profileSnapshot: MailProfileSyncSnapshot? { selection?.snapshot }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    loadGeneration += 1
    isLoading = false
    self.session = session
    startupProfileId = startupStore.load(productAccountId: session.productAccountId)
  }

  func load(
    restoredProfileId: MailProfileId?,
    targetedProfileId: MailProfileId? = nil
  ) async {
    loadGeneration += 1
    let generation = loadGeneration
    isLoading = true
    defer {
      if generation == loadGeneration {
        isLoading = false
      }
    }
    do {
      let snapshot = try await snapshotLoader.loadProfileSnapshot(session: session)
      guard generation == loadGeneration else { return }
      selection = MailProfileWorkspaceSelection(
        snapshot: snapshot,
        targetedProfileId: targetedProfileId,
        restoredProfileId: restoredProfileId,
        startupProfileId: startupProfileId
      )
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func loadCached(
    connectionIds: [MailboxConnectionId],
    restoredProfileId: MailProfileId?,
    targetedProfileId: MailProfileId? = nil
  ) async {
    let defaultProfile = MailProfileDefinition.defaultProfile(
      productAccountId: session.productAccountId
    )
    let snapshot = MailProfileSyncSnapshot(
      assignments: Dictionary(
        uniqueKeysWithValues: connectionIds.map { ($0, defaultProfile.id) }
      ),
      conflicts: [],
      defaultProfileId: defaultProfile.id,
      profiles: [defaultProfile],
      updatedAt: nil
    )
    selection = MailProfileWorkspaceSelection(
      snapshot: snapshot,
      targetedProfileId: targetedProfileId,
      restoredProfileId: restoredProfileId,
      startupProfileId: startupProfileId
    )
  }

  func activate(
    _ profileId: MailProfileId,
    parkCurrentDraft: () throws -> Void = {}
  ) throws {
    guard let selection else { throw MailProfileSyncError.invalidProfileState }
    loadGeneration += 1
    isLoading = false
    self.selection = try selection.activating(
      profileId,
      parkCurrentDraft: parkCurrentDraft
    )
    errorMessage = nil
  }

  func connections(from connections: [MailboxConnection]) -> [MailboxConnection] {
    selection?.connections(from: connections) ?? []
  }

  func connections(
    for profileId: MailProfileId,
    from connections: [MailboxConnection]
  ) -> [MailboxConnection] {
    selection?.connections(for: profileId, from: connections) ?? []
  }

  func owns(_ connectionId: MailboxConnectionId) -> Bool {
    selection?.owns(connectionId) == true
  }

  func setStartupProfile(_ profileId: MailProfileId) {
    guard profiles.contains(where: { $0.id == profileId }) else { return }
    startupStore.save(profileId, productAccountId: session.productAccountId)
    startupProfileId = profileId
  }

  func show(_ error: Error) {
    errorMessage = error.localizedDescription
  }
}

private struct DuplicateProseEventAlertModifier: ViewModifier {
  @Binding var calendarReview: CalendarEventReview?
  @Binding var proseDuplicateReview: CalendarEventReview?

  func body(content: Content) -> some View {
    content.alert(
      "Possible Duplicate Event",
      isPresented: Binding(
        get: { proseDuplicateReview != nil },
        set: { if !$0 { proseDuplicateReview = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) { proseDuplicateReview = nil }
      Button("Review Anyway") {
        calendarReview = proseDuplicateReview
        proseDuplicateReview = nil
      }
    } message: {
      Text(
        "This prose event matches one previously added on this device. "
          + "Review it as a new event; no invitation or existing Calendar event will be replaced."
      )
    }
  }
}

// swiftlint:disable:next type_body_length
struct AccountView: View {
  let session: ProductAccountSession
  let snapshot: ProductAccountSessionSnapshot
  private let initialLaunchDidFinish: () -> Void
  private let initialStartupDidFinish: () -> Void
  private let mailboxConnection: MailboxConnectionAdapter
  private let messageReader: MailboxMessageReading
  private let blockedSenderSyncServiceFactory: (MailProfileRecordScope) -> BlockedSenderSyncing
  private let categorySyncServiceFactory: (MailProfileRecordScope) -> CustomCategorySyncing
  private let composePreferenceSyncFactory: (MailProfileRecordScope) -> ComposePreferenceSyncing
  private let featureSuggestionPreferenceSyncFactory:
    (MailProfileRecordScope) -> FeatureSuggestionPreferenceSyncing
  private let inboxPreferenceSyncFactory: (MailProfileRecordScope) -> InboxPreferenceSyncing
  private let sendingIdentitySyncFactory: (MailProfileRecordScope) -> SendingIdentitySyncing
  private let signaturePreferenceSyncFactory: (MailProfileRecordScope) -> SignaturePreferenceSyncing
  private let templatePreferenceSyncFactory: (MailProfileRecordScope) -> TemplatePreferenceSyncing
  private let compositionDraftRepository: MailCompositionDraftRepository
  private let notificationPreferenceStore: NotificationDevicePreferencePersisting
  private let sendReminderNotificationScheduler: any SendReminderNotificationScheduling
  private let profileDeepLinkRouter: MailProfileDeepLinkRouter
  private let releaseBudgetDriver: MailShellReleaseBudgetDriver?
  private let shareExtensionCatalogSynchronizer: ShareExtensionCatalogSynchronizer?
  private let shareExtensionDraftImporter: ShareExtensionDraftImporter?

  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.editMode) private var editMode
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(MessageContentPreferences.self) private var messageContentPreferences:
    MessageContentPreferences?
  @Environment(SettingsRouter.self) private var settingsRouter
  @Environment(SettingsMailProfileContext.self) private var settingsMailProfileContext

  #if CI_PERFORMANCE_BUDGET
    // The Release fixture uses UIHostingController outside the SwiftUI App lifecycle.
    @State private var restoredProfileIdRawValue: String?
  #else
    @SceneStorage("mail-profile.active-id") private var restoredProfileIdRawValue: String?
  #endif

  @State private var blockedSenderStore: BlockedSenderStore
  @State private var categoryViewModel: CustomCategoryViewModel
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var composePreferenceStore: ComposePreferenceStore
  @State private var featureSuggestionPreferenceStore: FeatureSuggestionPreferenceStore
  @State private var mailAssistanceViewModel: MailAssistanceViewModel
  @State private var followUpNudgeReconcileTask: Task<Void, Never>?
  @State private var followUpNudgeViewModel: FollowUpNudgeViewModel
  @State private var signatureStore: SignatureStore
  @State private var templateStore: TemplateStore
  @State private var composerNavigation = MailShellComposerNavigationState()
  @State private var composerViewModels: [MailProfileId: MailComposerViewModel] = [:]
  @State private var composerSendErrorMessage = ""
  @State private var showsComposerSendError = false
  @State private var showsMailboxTools = false
  @State private var compositionDraftLoadGate = MailCompositionDraftLoadGate()
  @State private var savedCompositionDrafts: [MailShellCompositionDraft] = []
  @State private var contentPresentationDismissal =
    MailPresentationDismissalCoordinator()
  @State private var ewsSetupViewModel: EWSSetupViewModel
  @State private var genericMailSetupViewModel: GenericMailSetupViewModel
  @State private var gmailViewModel: MailboxProviderConnectionViewModel
  @State private var microsoftGraphViewModel: MailboxProviderConnectionViewModel
  @State private var mailboxFreshnessViewModel: MailboxFreshnessViewModel
  @State private var releaseBudgetDriverOwner = UUID()
  @State private var inboxPreferenceStore: InboxPreferenceStore
  @State private var swipePreferenceStore: SwipePreferenceStore
  @State private var inboxViewModel: GmailInboxViewModel
  @State private var inboxLoadGeneration = 0
  @State private var inboxLoadTask: Task<Void, Never>?
  @State private var mailboxObserversAreActive = false
  @State private var mailboxWorkRegistrationId = UUID()
  @State private var mailActionViewModel: GmailMailActionViewModel
  @State private var mailShellBottomBarHeight: CGFloat = 0
  #if MAIL_TEST_BOOTSTRAP
    @State private var mailShellSelection = MailShellSelectionModel(initialMailView: .all)
  #else
    @State private var mailShellSelection = MailShellSelectionModel(initialMailView: .important)
  #endif
  @State private var notificationRuleViewModel: NotificationRuleViewModel
  @State private var pendingNotificationDeepLink: NotificationDeepLink?
  @State private var pendingSendReminderDeepLink: SendReminderDeepLink?
  @State private var muteReconcileTask: Task<Void, Never>?
  @State private var muteViewModel: ThreadMuteViewModel
  @State private var pinReconcileTask: Task<Void, Never>?
  @State private var pinViewModel: PinViewModel
  @State private var snoozeReconcileTask: Task<Void, Never>?
  @State private var snoozeViewModel: ThreadSnoozeViewModel
  @State private var spotlightReconcileTask: Task<Void, Never>?
  @State private var profileInterruptionViewModel: MailProfileInterruptionViewModel
  @State private var parkedComposerProfileIds: Set<MailProfileId> = []
  @State private var profileSwitchGate = MailProfileSwitchGate()
  @State private var profilePreferenceRecordScope: MailProfileRecordScope = .legacyProductAccount
  @State private var profileViewModel: MailProfileWorkspaceViewModel
  @State private var readingPreferenceStore: ReadingPreferenceStore
  @State private var sendingIdentityStore: SendingIdentityStore
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .content
  @State private var showsBlockedActionAlert = false
  @State private var compactSettingsIsPresented = false
  @State private var settingsPresentationOwnerID = UUID()
  @State private var mailboxWorkCoordinator = MailboxWorkCoordinator.shared

  @MainActor
  // swiftlint:disable:next function_body_length
  init(
    session: ProductAccountSession,
    snapshot: ProductAccountSessionSnapshot,
    blockedSenderSyncService: BlockedSenderSyncing = BlockedSenderSyncService(),
    blockedSenderSyncServiceFactory: ((MailProfileRecordScope) -> BlockedSenderSyncing)? = nil,
    categorySyncServiceFactory: ((MailProfileRecordScope) -> CustomCategorySyncing)? = nil,
    composePreferenceSync: ComposePreferenceSyncing = ComposePreferenceSyncService(),
    composePreferenceSyncFactory:
      ((MailProfileRecordScope) -> ComposePreferenceSyncing)? = nil,
    compositionDraftStore: any MailCompositionDraftPersisting = FileMailCompositionDraftStore(),
    sendReminderSyncService: any SendReminderSyncing = SendReminderSyncService(),
    sendReminderNotificationScheduler: any SendReminderNotificationScheduling =
      UserNotificationService(),
    notificationPreferenceStore: NotificationDevicePreferencePersisting =
      UserDefaultsNotificationPreferenceStore(),
    featureSuggestionPreferenceSync: FeatureSuggestionPreferenceSyncing =
      FeatureSuggestionPreferenceSyncService(),
    featureSuggestionPreferenceSyncFactory:
      ((MailProfileRecordScope) -> FeatureSuggestionPreferenceSyncing)? = nil,
    signaturePreferenceSync: SignaturePreferenceSyncing = SignatureSyncService(),
    signaturePreferenceSyncFactory:
      ((MailProfileRecordScope) -> SignaturePreferenceSyncing)? = nil,
    templatePreferenceSync: TemplatePreferenceSyncing = TemplateSyncService(),
    templatePreferenceSyncFactory:
      ((MailProfileRecordScope) -> TemplatePreferenceSyncing)? = nil,
    genericMailSetupService: GenericMailSetupService = GenericMailSetupService(),
    inboxPreferenceSync: InboxPreferenceSyncing = InboxPreferenceSyncService(),
    inboxPreferenceSyncFactory: ((MailProfileRecordScope) -> InboxPreferenceSyncing)? = nil,
    swipePreferenceSync: SwipePreferenceSyncing = SwipePreferenceSyncService(),
    mailboxConnection: MailboxConnectionAdapter = MailboxConnectionRouter(),
    notificationAuthorization: NotificationAuthorizationRequesting = UserNotificationService(),
    notificationRuleSync: NotificationRuleSyncing = NotificationRuleSyncService(),
    notificationProfileLoader: NotificationProfilePolicyLoading = MailboxConnectionSyncService(),
    notificationProfileServiceFactory:
      @escaping (MailProfileRecordScope) -> NotificationRuleSyncing =
      { NotificationRuleSyncService(recordScope: $0) },
    pinSyncService: PinSyncing = PinSyncService(),
    threadMuteSyncService: ThreadMuteSyncing = ThreadMuteSyncService(),
    snoozeSyncService: ThreadSnoozeSyncing = ThreadSnoozeSyncService(),
    followUpNudgeSyncService: FollowUpNudgeSyncing = FollowUpNudgeSyncService(),
    mailAssistanceEnablementStore: MailAssistanceEnablementPersisting =
      UserDefaultsMailAssistanceStore(),
    mailAssistanceEngine: any MailAssistanceEngine = SystemMailAssistanceEngine(),
    profileInterruptionSync: MailProfileInterruptionSyncing = MailboxConnectionSyncService(),
    profileLockStore: MailProfileLockPersisting = UserDefaultsMailProfileLockStore(),
    profileLockAuthenticator: MailProfileLockAuthenticating? = nil,
    profileSearchIndex: MailProfileSearchIndexConcealing? = nil,
    profileSpotlightIndex: MailProfileSpotlightIndexing? = nil,
    profileSpotlightPreferenceStore: MailProfileSpotlightPreferencePersisting =
      UserDefaultsMailProfileSpotlightStore(),
    profileSnapshotLoader: MailProfileSnapshotLoading = MailboxConnectionSyncService(),
    profileStartupStore: MailProfileStartupSelectionPersisting =
      UserDefaultsMailProfileStartupStore(),
    profileDeepLinkRouter: MailProfileDeepLinkRouter = MailProfileDeepLinkRouter(),
    readingPreferenceSync: ReadingPreferenceSyncing = ReadingPreferenceSyncService(),
    sendingIdentitySync: SendingIdentitySyncing = SendingIdentitySyncService(),
    sendingIdentitySyncFactory: ((MailProfileRecordScope) -> SendingIdentitySyncing)? = nil,
    initialLaunchDidFinish: @escaping () -> Void = {},
    initialStartupDidFinish: @escaping () -> Void = {},
    releaseBudgetDriver: MailShellReleaseBudgetDriver? = nil
  ) {
    self.session = session
    self.snapshot = snapshot
    self.initialLaunchDidFinish = initialLaunchDidFinish
    self.initialStartupDidFinish = initialStartupDidFinish
    self.mailboxConnection = mailboxConnection
    self.messageReader = mailboxConnection
    self.compositionDraftRepository = MailCompositionDraftRepository(
      store: compositionDraftStore,
      reminderSyncService: sendReminderSyncService
    )
    self.notificationPreferenceStore = notificationPreferenceStore
    self.sendReminderNotificationScheduler = sendReminderNotificationScheduler
    if let shareExtensionStore = try? ShareExtensionStore.live() {
      self.shareExtensionCatalogSynchronizer = ShareExtensionCatalogSynchronizer(
        store: shareExtensionStore,
        lockStore: profileLockStore,
        identitySyncFactory: sendingIdentitySyncFactory ?? {
          SendingIdentitySyncService(recordScope: $0)
        }
      )
      self.shareExtensionDraftImporter = ShareExtensionDraftImporter(
        store: shareExtensionStore,
        repository: compositionDraftRepository
      )
    } else {
      self.shareExtensionCatalogSynchronizer = nil
      self.shareExtensionDraftImporter = nil
    }
    self.blockedSenderSyncServiceFactory =
      blockedSenderSyncServiceFactory ?? { scope in
        scope == .legacyProductAccount
          ? blockedSenderSyncService
          : BlockedSenderSyncService(recordScope: scope)
      }
    let categorySyncServiceFactory =
      categorySyncServiceFactory ?? { CustomCategorySyncService(recordScope: $0) }
    self.categorySyncServiceFactory = categorySyncServiceFactory
    self.composePreferenceSyncFactory =
      composePreferenceSyncFactory ?? { scope in
        scope == .legacyProductAccount
          ? composePreferenceSync
          : ComposePreferenceSyncService(recordScope: scope)
      }
    self.featureSuggestionPreferenceSyncFactory =
      featureSuggestionPreferenceSyncFactory ?? { scope in
        scope == .legacyProductAccount
          ? featureSuggestionPreferenceSync
          : FeatureSuggestionPreferenceSyncService(recordScope: scope)
      }
    self.inboxPreferenceSyncFactory =
      inboxPreferenceSyncFactory ?? { scope in
        scope == .legacyProductAccount
          ? inboxPreferenceSync
          : InboxPreferenceSyncService(recordScope: scope)
      }
    self.sendingIdentitySyncFactory =
      sendingIdentitySyncFactory ?? { scope in
        scope == .legacyProductAccount
          ? sendingIdentitySync
          : SendingIdentitySyncService(recordScope: scope)
      }
    self.signaturePreferenceSyncFactory =
      signaturePreferenceSyncFactory ?? { scope in
        scope == .legacyProductAccount
          ? signaturePreferenceSync
          : SignatureSyncService(recordScope: scope)
      }
    self.templatePreferenceSyncFactory =
      templatePreferenceSyncFactory ?? { scope in
        scope == .legacyProductAccount
          ? templatePreferenceSync
          : TemplateSyncService(recordScope: scope)
      }
    self.profileDeepLinkRouter = profileDeepLinkRouter
    self.releaseBudgetDriver = releaseBudgetDriver
    let revalidateTrustedDevice = {
      await session.revalidateTrustedDeviceAfterForegrounding()
    }
    let initialBlockedSenderStore = BlockedSenderStore(
      session: snapshot,
      syncService: blockedSenderSyncService
    )
    _blockedSenderStore = State(initialValue: initialBlockedSenderStore)
    let defaultProfile = MailProfileDefinition.defaultProfile(
      productAccountId: snapshot.productAccountId
    )
    _categoryViewModel = State(
      initialValue: CustomCategoryViewModel(
        service: categorySyncServiceFactory(defaultProfile.recordScope),
        session: snapshot
      )
    )
    _composePreferenceStore = State(
      initialValue: session.sharedComposePreferenceStore(
        for: snapshot,
        recordScope: defaultProfile.recordScope,
        syncService: composePreferenceSync
      )
    )
    _featureSuggestionPreferenceStore = State(
      initialValue: session.sharedFeatureSuggestionPreferenceStore(
        for: snapshot,
        recordScope: defaultProfile.recordScope,
        syncService: featureSuggestionPreferenceSync
      )
    )
    let defaultProfileId = defaultProfile.id
    _mailAssistanceViewModel = State(
      initialValue: MailAssistanceViewModel(
        productAccountId: snapshot.productAccountId,
        profileId: defaultProfileId,
        store: mailAssistanceEnablementStore,
        engine: mailAssistanceEngine
      )
    )
    _signatureStore = State(
      initialValue: session.sharedSignatureStore(
        for: snapshot,
        recordScope: defaultProfile.recordScope,
        syncService: signaturePreferenceSync
      )
    )
    _templateStore = State(
      initialValue: session.sharedTemplateStore(
        for: snapshot,
        recordScope: defaultProfile.recordScope,
        syncService: templatePreferenceSync
      )
    )
    _sendingIdentityStore = State(
      initialValue: SendingIdentityStore(
        session: snapshot,
        recordScope: defaultProfile.recordScope,
        syncService: sendingIdentitySync
      )
    )
    _inboxPreferenceStore = State(
      initialValue: session.sharedInboxPreferenceStore(
        for: snapshot,
        syncService: inboxPreferenceSync
      )
    )
    _swipePreferenceStore = State(
      initialValue: SwipePreferenceStore(
        session: snapshot,
        syncService: swipePreferenceSync
      )
    )
    _genericMailSetupViewModel = State(
      initialValue: GenericMailSetupViewModel(
        productAccountId: ProductAccountId(snapshot.productAccountId),
        clearLocalData: { definition, session in
          try await AccountView.clearGenericMailLocalData(
            definition,
            session: session,
            mailboxConnection: mailboxConnection
          )
        },
        isSessionCurrent: { session.isCurrentSessionIdentity(snapshot) },
        isSyncSessionCurrent: { candidate in
          candidate.map(session.isCurrentSessionIdentity) ?? false
        },
        revalidateTrustedDevice: revalidateTrustedDevice,
        service: genericMailSetupService,
        syncSession: snapshot
      )
    )
    _ewsSetupViewModel = State(
      initialValue: EWSSetupViewModel(
        isSessionCurrent: { session.isCurrent($0) },
        revalidateTrustedDevice: revalidateTrustedDevice,
        session: snapshot
      )
    )
    _gmailViewModel = State(
      initialValue: MailboxProviderConnectionViewModel(
        service: mailboxConnection,
        isSessionCurrent: { session.isCurrent($0) },
        revalidateTrustedDevice: revalidateTrustedDevice,
        session: snapshot
      )
    )
    _microsoftGraphViewModel = State(
      initialValue: MailboxProviderConnectionViewModel(
        service: MicrosoftGraphMailboxConnectionAdapter(),
        isSessionCurrent: { session.isCurrent($0) },
        revalidateTrustedDevice: revalidateTrustedDevice,
        session: snapshot
      )
    )
    let mailboxFreshnessViewModel = session.sharedMailboxFreshnessViewModel(
      for: snapshot,
      service: mailboxConnection,
      blockedSenderEnforcer: BlockedSenderEnforcementService(actionService: mailboxConnection)
    )
    _mailboxFreshnessViewModel = State(initialValue: mailboxFreshnessViewModel)
    _inboxViewModel = State(
      initialValue: GmailInboxViewModel(
        bodyPrefetcher: mailboxConnection,
        service: mailboxConnection,
        searchService: mailboxConnection,
        syncCoordinator: mailboxFreshnessViewModel,
        session: snapshot
      )
    )
    _mailActionViewModel = State(
      initialValue: session.sharedMailActionViewModel(
        for: snapshot,
        service: mailboxConnection
      )
    )
    _notificationRuleViewModel = State(
      initialValue: NotificationRuleViewModel(
        authorization: notificationAuthorization,
        profileLoader: notificationProfileLoader,
        profileServiceFactory: notificationProfileServiceFactory,
        service: notificationRuleSync,
        session: snapshot
      )
    )
    _pinViewModel = State(
      initialValue: PinViewModel(service: pinSyncService, session: snapshot)
    )
    _muteViewModel = State(
      initialValue: ThreadMuteViewModel(
        service: threadMuteSyncService,
        session: snapshot
      )
    )
    _snoozeViewModel = State(
      initialValue: ThreadSnoozeViewModel(
        notificationPreferenceStore: notificationPreferenceStore,
        profileLockStore: profileLockStore,
        service: snoozeSyncService,
        session: snapshot
      )
    )
    _followUpNudgeViewModel = State(
      initialValue: FollowUpNudgeViewModel(
        profileLockStore: profileLockStore,
        service: followUpNudgeSyncService,
        session: snapshot
      )
    )
    _profileInterruptionViewModel = State(
      initialValue: MailProfileInterruptionViewModel(
        session: snapshot,
        syncService: profileInterruptionSync,
        lockStore: profileLockStore,
        authenticator: profileLockAuthenticator,
        searchIndex: profileSearchIndex,
        spotlightIndex: profileSpotlightIndex,
        spotlightPreferenceStore: profileSpotlightPreferenceStore
      )
    )
    _profileViewModel = State(
      initialValue: MailProfileWorkspaceViewModel(
        session: snapshot,
        snapshotLoader: profileSnapshotLoader,
        startupStore: profileStartupStore
      )
    )
    _readingPreferenceStore = State(
      initialValue: ReadingPreferenceStore(
        session: snapshot,
        syncService: readingPreferenceSync
      )
    )
  }

  var body: some View {
    ZStack {
      MailTheme.canvas
        .ignoresSafeArea()

      mailShell
        .opacity(profileInterruptionViewModel.policy.allowsContentReveal ? 1 : 0)
        .allowsHitTesting(profileInterruptionViewModel.policy.allowsContentReveal)
        .accessibilityHidden(!profileInterruptionViewModel.policy.allowsContentReveal)
        .mailShellPrivacySensitive()

      if !profileInterruptionViewModel.policy.allowsContentReveal {
        MailProfileLockedView(viewModel: profileInterruptionViewModel)
      }
    }
    .background(MailTheme.canvas)
    .task {
      await profileInterruptionViewModel.load()
    }
    .onAppear(perform: presentPendingCompactSettingsRequest)
    .onAppear(perform: updateSettingsMailProfileContext)
    .onChange(of: settingsRouter.request?.id) { _, _ in
      presentPendingCompactSettingsRequest()
    }
    .onChange(of: profileInterruptionViewModel.policy.allowsContentReveal) { _, allowsReveal in
      if allowsReveal {
        mailAssistanceViewModel.profileDidUnlock()
        Task {
          await loadCompositionDrafts(profileId: activeDraftProfileId)
        }
        reconcileSpotlight()
        return
      }
      mailAssistanceViewModel.profileDidLock()
      MailProfileContentPresentationDismissal.dismissRoot(
        showsMessageActionAlert: &showsBlockedActionAlert,
        composerNavigation: &composerNavigation,
        composerSendErrorMessage: &composerSendErrorMessage,
        showsComposerSendError: &showsComposerSendError,
        compactSettingsIsPresented: &compactSettingsIsPresented
      )
      contentPresentationDismissal.dismissPresentations()
    }
    .onChange(of: profileViewModel.activeProfileId) { _, profileId in
      updateSettingsMailProfileContext()
      guard let profileId else {
        mailAssistanceViewModel.profileDidLock()
        return
      }
      mailAssistanceViewModel.activateProfile(profileId, contentIsConcealed: true)
      Task {
        await profileInterruptionViewModel.load(profileId: profileId)
        guard profileViewModel.activeProfileId == profileId else { return }
        if profileInterruptionViewModel.policy.allowsContentReveal {
          mailAssistanceViewModel.profileDidUnlock()
          reconcileSpotlight()
        } else {
          mailAssistanceViewModel.profileDidLock()
        }
      }
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        Task { await profileInterruptionViewModel.applicationBecameActive() }
      case .inactive:
        Task { await profileInterruptionViewModel.applicationBecameInactive() }
      case .background:
        Task { await profileInterruptionViewModel.applicationEnteredBackground() }
      @unknown default:
        Task { await profileInterruptionViewModel.applicationBecameInactive() }
      }
    }
    #if canImport(UIKit)
      .onReceive(
        NotificationCenter.default.publisher(
          for: UIApplication.protectedDataWillBecomeUnavailableNotification
        )
        .receive(on: RunLoop.main)
      ) { _ in
        Task { await profileInterruptionViewModel.protectedDataWillBecomeUnavailable() }
      }
    #endif
  }

  private var genericMailReloadKey: [String] {
    genericMailSetupViewModel.connectionReloadKey
  }

  private var profileConnections: [MailboxConnection] {
    profileViewModel.connections(from: gmailViewModel.connections)
  }

  private var profileSendingIdentities: [SendingIdentity] {
    let connectionIds = Set(profileConnections.map(\.id))
    return sendingIdentityStore.preferences.identities
      .filter { connectionIds.contains($0.connectionId) }
      .sorted { $0.title < $1.title }
  }

  private var sendingIdentitySynchronizationKey: [String] {
    [
      profileViewModel.activeProfile?.recordScope.namespace ?? "default",
      profileDefaultSendingConnectionId?.rawValue ?? "no-default",
      "authoritative:\(gmailViewModel.connectionsSnapshotIsAuthoritative)",
    ]
      + profileConnections.map {
        "\($0.id.rawValue):\($0.authorizationState):\($0.capabilities.canSend)"
      }
  }

  private var shareExtensionCatalogSynchronizationKey: [String] {
    [
      snapshot.productAccountId,
      profileViewModel.startupProfileId?.rawValue ?? "no-startup-profile",
    ]
      + profileViewModel.profiles.flatMap { profile in
        [
          profile.id.rawValue,
          profile.name,
          profile.appearance.colorName,
          profile.appearance.symbolName,
        ]
      }
      + profileSendingIdentities.flatMap { identity in
        [
          identity.id.rawValue,
          identity.connectionId.rawValue,
          identity.address,
          identity.displayName ?? "",
        ]
      }
  }

  private var profileOutboxItems: [OutgoingDeliveryAttempt] {
    profileScopedOutboxItems(
      mailActionViewModel.outboxItems,
      connectionIds: Set(profileConnections.map(\.id))
    )
  }

  private var profileScheduledSendItems: [ManagedScheduledSend] {
    profileScopedScheduledSendItems(
      mailActionViewModel.scheduledSendItems,
      profileId: activeDraftProfileId
    )
  }

  private var profileDefaultSendingConnectionId: MailboxConnectionId? {
    if let defaultSendingConnectionId = gmailViewModel.defaultSendingConnectionId,
      profileViewModel.owns(defaultSendingConnectionId)
    {
      return defaultSendingConnectionId
    }
    return profileConnections.first {
      $0.authorizationState == .authorized && $0.capabilities.canSend
    }?.id
  }

  private var mailShell: some View {
    mailShellWithPreferenceObservers
      .onChange(of: mailActionViewModel.failedConnectionIds) { oldIds, newIds in
        let newlyFailedIds = newlyFailedConnectionIds(
          from: oldIds,
          to: newIds,
          mailboxObserversAreActive: mailboxObserversAreActive
        )
        guard !newlyFailedIds.isEmpty else { return }
        Task {
          for connectionId in newlyFailedIds {
            guard
              profileViewModel.owns(connectionId),
              let connection = profileConnections.first(where: { $0.id == connectionId })
            else { continue }
            _ = await inboxViewModel.reloadLocal(connection: connection)
          }
          await inboxViewModel.loadNavigation(connections: profileConnections)
          showsBlockedActionAlert = true
        }
      }
      .onChange(of: gmailViewModel.connection?.id) { _, _ in
        guard mailboxObserversAreActive else { return }
        guard mailShellSelection.selectedMailbox?.isUnified != true else { return }
        guard let connection = gmailViewModel.connection else {
          mailShellSelection.clearSelection()
          inboxViewModel.clear()
          return
        }
        let collection: MailboxMessageCollection
        if case .connection(let selectedConnectionId, let selectedCollection) =
          mailShellSelection.selectedMailbox,
          selectedConnectionId == connection.id
        {
          collection = selectedCollection
        } else {
          collection = .role(.inbox)
        }
        selectConnection(connection, collection: collection)
      }
      .onChange(of: gmailViewModel.connections) { _, _ in
        mailboxFreshnessViewModel.updateConnections(
          gmailViewModel.connections,
          snapshotIsAuthoritative: gmailViewModel.connectionsSnapshotIsAuthoritative,
          prunesPersistedState: false
        )
        guard mailboxObserversAreActive else { return }
        Task {
          let reloadsUnifiedMailbox = mailShellSelection.selectedMailbox?.isUnified == true
          await profileViewModel.load(
            restoredProfileId: profileViewModel.activeProfileId
          )
          restoredProfileIdRawValue = profileViewModel.activeProfileId?.rawValue
          await inboxViewModel.loadNavigation(connections: profileConnections)
          if reloadsUnifiedMailbox,
            mailShellSelection.selectedMailbox?.isUnified == true
          {
            loadUnifiedMailbox()
          }
        }
      }
      .onChange(of: gmailViewModel.connection?.authorizationState) { _, authorizationState in
        if authorizationState == .authorized {
          Task {
            await mailActionViewModel.resume(connections: gmailViewModel.connections)
          }
        }
        guard mailShellSelection.selectedMailbox?.isUnified != true else { return }
        guard mailboxObserversAreActive else { return }
        guard
          let connection = gmailViewModel.connection,
          authorizationState == .authorized
        else {
          inboxViewModel.clear()
          return
        }
        loadMailbox(for: connection)
      }
      .onChange(of: gmailViewModel.defaultSendingConnectionId) { _, _ in
        Task {
          await genericMailSetupViewModel.loadSyncedDefinitions()
        }
      }
      .onChange(of: genericMailSetupViewModel.connectionReloadKey) { _, _ in
        Task {
          _ = await gmailViewModel.load()
        }
      }
      .background {
        MailShellThreadProjectionObserver(
          inboxViewModel: inboxViewModel,
          mailShellSelection: mailShellSelection,
          connectionIds: Set(profileConnections.map(\.id))
        )
      }
      .onChange(of: mailShellSelection.navigationLevel) { _, _ in
        updatePreferredCompactColumn()
      }
      .onChange(of: composerNavigation.draft?.id) { _, _ in
        updatePreferredCompactColumn()
      }
      .onChange(of: horizontalSizeClass) { _, _ in
        updatePreferredCompactColumn()
      }
      .onChange(of: editMode?.wrappedValue) { _, _ in
        updatePreferredCompactColumn()
      }
      .onDisappear {
        inboxLoadTask?.cancel()
      }
  }

  private var mailShellWithPreferenceObservers: some View {
    mailShellWithReleaseBudgetLifecycle
      .onChange(of: pinViewModel.pinnedThreadIds) { oldValue, newValue in
        updateProductMailboxState()
        inboxViewModel.refreshBodyPrefetch(
          afterChanging: oldValue.symmetricDifference(newValue),
          connections: profileConnections
        )
      }
      .onChange(of: snoozeViewModel.snoozedThreadIds) { _, _ in
        updateProductMailboxState()
      }
      .onChange(of: mailActionViewModel.outboxItems) { _, _ in
        updateProductMailboxState()
      }
      .onChange(of: mailActionViewModel.scheduledSendItems) { _, _ in
        updateProductMailboxState()
      }
      .onChange(of: mailActionViewModel.pendingFailureConnectionId) { _, connectionId in
        showsBlockedActionAlert = connectionId != nil
      }
      .onChange(of: snapshot) { _, refreshedSnapshot in
        blockedSenderStore.updateSession(refreshedSnapshot)
        categoryViewModel.updateSession(refreshedSnapshot)
        composePreferenceStore.updateSession(refreshedSnapshot)
        featureSuggestionPreferenceStore.updateSession(refreshedSnapshot)
        followUpNudgeViewModel.updateSession(refreshedSnapshot)
        signatureStore.updateSession(refreshedSnapshot)
        templateStore.updateSession(refreshedSnapshot)
        ewsSetupViewModel.updateSession(refreshedSnapshot)
        genericMailSetupViewModel.updateSession(refreshedSnapshot)
        gmailViewModel.sessionSnapshot = refreshedSnapshot
        inboxPreferenceStore.updateSession(refreshedSnapshot)
        swipePreferenceStore.updateSession(refreshedSnapshot)
        inboxViewModel.updateSession(refreshedSnapshot)
        mailActionViewModel.updateSession(refreshedSnapshot)
        mailboxFreshnessViewModel.updateSession(refreshedSnapshot)
        microsoftGraphViewModel.sessionSnapshot = refreshedSnapshot
        notificationRuleViewModel.updateSession(refreshedSnapshot)
        muteViewModel.updateSession(refreshedSnapshot)
        pinViewModel.updateSession(refreshedSnapshot)
        snoozeViewModel.updateSession(refreshedSnapshot)
        profileInterruptionViewModel.updateSession(refreshedSnapshot)
        profileViewModel.updateSession(refreshedSnapshot)
        readingPreferenceStore.updateSession(refreshedSnapshot)
      }
      .onChange(of: inboxPreferenceStore.preferences.mailViewConfiguration) { _, _ in
        updateMailViews()
      }
      .onChange(of: categoryViewModel.categories) { _, _ in
        updateMailViews()
      }
      .onChange(of: categoryViewModel.configuration) { _, _ in
        updateMailViews()
      }
      .onChange(of: categoryViewModel.hasLoadedCategory) { _, _ in
        updateMailViews()
      }
  }

  private var mailShellWithReleaseBudgetLifecycle: some View {
    pinReconciledMailShell
      .onAppear {
        releaseBudgetDriver?.installSelectionHandler(owner: releaseBudgetDriverOwner) {
          selectedMailboxBinding.wrappedValue = $0
        } mailView: {
          selectedMailViewBinding.wrappedValue = $0
        }
        releaseBudgetDriver?.installProfileSelectionHandler(owner: releaseBudgetDriverOwner) {
          _ = await switchProfileAndWait(to: $0)
        }
        releaseBudgetDriver?.recordActiveProfileId(
          profileViewModel.activeProfileId,
          owner: releaseBudgetDriverOwner
        )
        releaseBudgetDriver?.recordActiveProfileRecordScope(
          profileViewModel.activeProfile?.recordScope,
          owner: releaseBudgetDriverOwner
        )
      }
      .onChange(of: profileViewModel.activeProfileId) { _, profileId in
        releaseBudgetDriver?.recordActiveProfileId(profileId, owner: releaseBudgetDriverOwner)
      }
      .onDisappear {
        muteReconcileTask?.cancel()
        muteReconcileTask = nil
        pinReconcileTask?.cancel()
        pinReconcileTask = nil
        followUpNudgeReconcileTask?.cancel()
        followUpNudgeReconcileTask = nil
        snoozeReconcileTask?.cancel()
        snoozeReconcileTask = nil
        spotlightReconcileTask?.cancel()
        spotlightReconcileTask = nil
        releaseBudgetDriver?.removeSelectionHandler(owner: releaseBudgetDriverOwner)
      }
  }

  private var pinReconciledMailShell: some View {
    mailboxWorkCoordinatedMailShell
      .onChange(of: inboxViewModel.navigationSnapshot.messagesByConnection) { _, messages in
        reconcilePins(with: messages)
        reconcileMutes(with: messages)
        reconcileSnoozes(with: messages)
        reconcileFollowUpNudges(with: messages)
        reconcileSpotlight(messagesByConnection: messages)
      }
      .onChange(of: profileViewModel.profiles) { _, _ in
        reconcileSpotlight()
      }
      .onChange(of: profileInterruptionViewModel.spotlightIndexingIsEnabled) { _, _ in
        reconcileSpotlight()
      }
  }

  private var mailboxWorkCoordinatedMailShell: some View {
    mailShellWithCoreLifecycleHandlers
      .onAppear {
        updateMailboxWorkCoordination()
      }
      .onChange(of: isMailboxWorkBusy) { _, _ in
        updateMailboxWorkCoordination()
      }
      .onDisappear {
        mailboxWorkCoordinator.unregister(
          productAccountId: snapshot.productAccountId,
          registrationId: mailboxWorkRegistrationId
        )
      }
  }

  private var isMailboxWorkBusy: Bool {
    inboxViewModel.isBusy || mailActionViewModel.isPerformingAction
  }

  private func updateMailboxWorkCoordination() {
    mailboxWorkCoordinator.register(
      productAccountId: snapshot.productAccountId,
      registrationId: mailboxWorkRegistrationId,
      cancelBodyPrefetch: { await inboxViewModel.cancelBodyPrefetch() },
      isBusy: isMailboxWorkBusy
    )
  }

  private var mailShellPresentation: some View {
    NavigationSplitView(
      columnVisibility: $columnVisibility,
      preferredCompactColumn: $preferredCompactColumn
    ) {
      MailShellSidebar(
        beginComposition: beginNewMessage,
        canCompose: composerViewModels[activeDraftProfileId]?.isSwitchingDraft != true
          && !profileConnections.isEmpty,
        connections: profileConnections,
        profiles: profileViewModel.profiles,
        activeProfileId: profileViewModel.activeProfileId,
        startupProfileId: profileViewModel.startupProfileId,
        selectProfile: switchProfile,
        setStartupProfile: profileViewModel.setStartupProfile,
        errorMessage: profileViewModel.errorMessage ?? gmailViewModel.errorMessage
          ?? muteViewModel.errorMessage,
        generalErrorMessage: profileViewModel.errorMessage ?? gmailViewModel.errorMessage
          ?? muteViewModel.errorMessage
          ?? pinViewModel.errorMessage
          ?? snoozeViewModel.errorMessage
          ?? followUpNudgeViewModel.errorMessage
          ?? mailActionViewModel.errorMessage,
        isLoading: gmailViewModel.isLoading || profileViewModel.isLoading,
        navigationSnapshot: inboxViewModel.navigationSnapshot,
        openSettings: { openSettings($0) },
        selectedMailbox: selectedMailboxBinding,
        showSearch: { showsMailboxTools = true },
        showSettings: { openSettings(nil) },
        syncStatus: mailboxFreshnessViewModel.status
      )
      .mailShellBottomInset(isEnabled: horizontalSizeClass == .compact) {
        mailShellBottomBar
      }
    } content: {
      MailShellThreadList(
        connection: selectedConnection,
        connections: profileConnections,
        composePreferences: composePreferenceStore.preferences,
        featureSuggestionStore: featureSuggestionPreferenceStore,
        isConnectionBusy: gmailViewModel.isEditingDisabled,
        items: mailShellSelection.threadListItems(connections: profileConnections),
        mailAssistanceViewModel: mailAssistanceViewModel,
        mailActionViewModel: mailActionViewModel,
        outboxItems: profileOutboxItems,
        scheduledSendItems: profileScheduledSendItems,
        sendingIdentities: profileSendingIdentities,
        mailboxSelection: mailShellSelection.selectedMailbox,
        navigationSnapshot: inboxViewModel.navigationSnapshot,
        openSettings: openSettings,
        muteViewModel: muteViewModel,
        pinViewModel: pinViewModel,
        partialSearchResultThreadId: mailShellSelection.partialSearchResultThreadId,
        snoozeViewModel: snoozeViewModel,
        selectedThreadIds: selectedThreadsBinding,
        showsMailboxTools: $showsMailboxTools,
        swipePreferences: swipePreferenceStore.preferences,
        viewModel: inboxViewModel,
        selectSearchResult: selectSearchResult,
        categoryChoices: MessageCategoryChoice.available(
          customCategories: categoryViewModel.categories
        ),
        inboxPreferences: inboxPreferenceStore.preferences,
        readingPreferences: readingPreferenceStore.preferences,
        allowsProactiveSuggestions:
          profileInterruptionViewModel.policy.allowsProactiveSuggestions,
        clearCachedBodies: {
          await inboxViewModel.cancelBodyPrefetch()
          guard !inboxViewModel.isLoadingMessageBody else { return }
          for connection in profileScopedCacheClearConnections(
            selectedConnection: selectedConnection,
            profileConnections: profileConnections
          ) {
            try messageReader.clearCachedMessageBodies(
              connection: connection,
              session: snapshot
            )
          }
          inboxViewModel.discardLoadedMessageBodies(
            connectionId: selectedConnection?.id
          )
        },
        revalidateTrustedDevice: {
          guard await session.revalidateTrustedDeviceAfterForegrounding() else { return false }
          return session.isCurrentSessionIdentity(snapshot)
        },
        saveDraft: { [profileId = activeDraftProfileId] draft in
          try await saveCompositionDraft(draft, profileId: profileId)
        },
        deleteDraft: { [profileId = activeDraftProfileId] draftId in
          try await deleteCompositionDraft(draftId, profileId: profileId)
        },
        reminderOwnerDeviceId: snapshot.trustedDeviceId,
        cancelReminder: { [profileId = activeDraftProfileId] reminder, draftId in
          cancelSendReminder(reminder, draftId: draftId, profileId: profileId)
        },
        scheduleReminder: { [profileId = activeDraftProfileId] draft in
          try await scheduleSendReminder(for: draft, profileId: profileId)
        },
        itemDidRender: { item in
          releaseBudgetDriver?.recordRenderedItemId(item.id, owner: releaseBudgetDriverOwner)
        },
        contentPresentationDismissal: contentPresentationDismissal
      )
      .mailShellBottomInset(isEnabled: horizontalSizeClass == .compact) {
        mailShellBottomBar
      }
      .anchorPreference(
        key: MailShellThreadColumnBoundsPreferenceKey.self,
        value: .bounds
      ) { $0 }
    } detail: {
      MailShellConversationReader(
        blockedSenderStore: blockedSenderStore,
        bottomScrollContentMargin: horizontalSizeClass == .compact
          ? 0 : mailShellBottomBarHeight,
        connections: profileConnections,
        composePreferences: composePreferenceStore.preferences,
        featureSuggestionStore: featureSuggestionPreferenceStore,
        followUpNudgeViewModel: followUpNudgeViewModel,
        inboxViewModel: inboxViewModel,
        isConnectionBusy: gmailViewModel.isEditingDisabled,
        mailAssistanceViewModel: mailAssistanceViewModel,
        mailActionViewModel: mailActionViewModel,
        messageReader: messageReader,
        muteViewModel: muteViewModel,
        pinViewModel: pinViewModel,
        snoozeViewModel: snoozeViewModel,
        selection: mailShellSelection,
        session: snapshot,
        profileId: activeDraftProfileId,
        readingPreferences: readingPreferenceStore.preferences,
        revalidateTrustedDevice: {
          guard await session.revalidateTrustedDeviceAfterForegrounding() else { return false }
          return session.isCurrentSessionIdentity(snapshot)
        },
        allowsProactiveSuggestions:
          profileInterruptionViewModel.policy.allowsProactiveSuggestions,
        allowsContentReveal: profileInterruptionViewModel.policy.allowsContentReveal,
        contentPresentationDismissal: contentPresentationDismissal,
        categoryChoices: MessageCategoryChoice.available(
          customCategories: categoryViewModel.categories
        ),
        createCustomCategory: { draft in
          try await categoryViewModel.create(draft)
        },
        presentCompositionDraft: { draft in
          presentComposerDraft(draft)
        },
        signatures: signatureStore.preferences,
        sendingIdentities: profileSendingIdentities
      )
      .mailShellBottomInset(isEnabled: horizontalSizeClass == .compact) {
        mailShellBottomBar
      }
      .anchorPreference(
        key: MailShellDetailColumnBoundsPreferenceKey.self,
        value: .bounds
      ) { $0 }
    }
    .navigationSplitViewStyle(.balanced)
    .navigationDestination(isPresented: $compactSettingsIsPresented) {
      SettingsRootView(
        session: session,
        usesParentCompactNavigation: true
      )
    }
    .overlayPreferenceValue(MailShellThreadColumnBoundsPreferenceKey.self) { bounds in
      GeometryReader { proxy in
        if let bounds {
          let frame = proxy[bounds]
          Rectangle()
            .fill(MailTheme.separator)
            .frame(width: 1, height: proxy.size.height)
            .position(x: frame.maxX + 0.5, y: proxy.size.height / 2)
        }
      }
      .ignoresSafeArea(.container, edges: .vertical)
      .allowsHitTesting(false)
    }
    .toolbarBackground(.thinMaterial, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbar {
      if let activeProfile = profileViewModel.activeProfile {
        ToolbarItem(placement: .principal) {
          MailProfileBadge(profile: activeProfile)
        }
      }
    }
    .mailShellBottomInset(isEnabled: horizontalSizeClass != .compact) {
      mailShellBottomBar
    }
    .overlay(alignment: .bottomTrailing) {
      if showsComposeButton {
        VStack(alignment: .trailing, spacing: 8) {
          if !savedCompositionDrafts.isEmpty {
            MailShellSavedDraftsButton(
              drafts: savedCompositionDrafts,
              open: openCompositionDraft
            )
          }
          if !templateStore.preferences.templates.isEmpty {
            MailShellTemplateDraftsButton(
              templates: templateStore.preferences.templates,
              open: { beginNewMessage(using: $0) }
            )
          }
          if horizontalSizeClass == .compact {
            MailShellComposeButton(action: beginNewMessage)
          }
        }
        .padding(16)
        .padding(.bottom, horizontalSizeClass == .compact ? 48 : 0)
      }
    }
    .overlayPreferenceValue(MailShellDetailColumnBoundsPreferenceKey.self) { bounds in
      GeometryReader { proxy in
        if composerNavigation.draft != nil,
          let composerViewModel = composerViewModels[activeDraftProfileId]
        {
          let containerFrame = CGRect(origin: .zero, size: proxy.size)
          let detailColumnFrame = bounds.map { proxy[$0] }
          let layout = MailShellComposerPresentationLayout(
            containerFrame: containerFrame,
            detailColumnFrame: detailColumnFrame,
            isCompact: usesCompactComposerPresentation,
            isExpanded: composerNavigation.isExpanded
          )
          ZStack {
            if layout.mode == .detailOverlay, let detailColumnFrame {
              Rectangle()
                .fill(MailTheme.canvas.opacity(0.001))
                .frame(width: detailColumnFrame.width, height: detailColumnFrame.height)
                .position(x: detailColumnFrame.midX, y: detailColumnFrame.midY)
                .accessibilityHidden(true)
            }

            MailShellComposer(
              connections: profileConnections,
              viewModel: composerViewModel,
              preferences: composePreferenceStore.preferences,
              signatures: signatureStore.preferences,
              templates: templateStore.preferences,
              isSending: mailActionViewModel.isPerformingAction,
              mailAssistanceViewModel: mailAssistanceViewModel,
              readingPreferences: readingPreferenceStore.preferences,
              profileName: profileViewModel.activeProfile?.name ?? "Mail Profile",
              recipientMessages: mailShellSelection.threads.flatMap(\.messages),
              responseAssistanceContext: responseAssistanceContext(for: composerViewModel.draft),
              sendingIdentities: profileSendingIdentities,
              navigation: MailShellComposerNavigation(
                drafts: savedCompositionDrafts,
                isExpanded: composerNavigation.isExpanded,
                showsExpansionControl: layout.mode != .compactDestination,
                dismiss: dismissCompositionDraft,
                newMessage: beginNewMessage,
                openDraft: openCompositionDraft,
                toggleExpansion: toggleCompositionDraftExpansion
              ),
              draftDidChange: { composerNavigation.updatePresentedDraft($0) }
            )
            .frame(width: layout.frame.width, height: layout.frame.height)
            .background(MailTheme.canvas)
            .clipShape(
              .rect(cornerRadius: layout.mode == .detailOverlay ? 12 : 0)
            )
            .position(x: layout.frame.midX, y: layout.frame.midY)
            .accessibilityIdentifier("mail-shell-composer-\(layout.mode)")
            .alert("Message Not Sent", isPresented: $showsComposerSendError) {
              Button("Keep Editing", role: .cancel) {}
            } message: {
              Text(composerSendErrorMessage)
            }
          }
        }
      }
      .ignoresSafeArea(.container)
    }
    .alert(
      "Pending message action requires attention",
      isPresented: $showsBlockedActionAlert
    ) {
      if let connection = pendingActionFailureConnection {
        if mailActionViewModel.blockedConnectionId == connection.id {
          Button("Retry") {
            resolveBlockedAction(connection: connection, discard: false)
          }
          Button("Discard", role: .destructive) {
            resolveBlockedAction(connection: connection, discard: true)
          }
        } else {
          Button("Acknowledge") {
            acknowledgePendingActionFailure(connection: connection)
          }
        }
      }
      Button("Later", role: .cancel) {}
    } message: {
      Text(mailActionViewModel.errorMessage ?? "Reconnect or discard the pending action.")
    }
  }

  private var mailShellWithCoreLifecycleHandlers: some View {
    mailShellPresentation
      .task {
        #if canImport(UIKit)
          requestDevicePushRegistration()
        #endif
        let deepLinkTarget = profileDeepLinkRouter.consumeTarget()
        let targetedProfileId = deepLinkTarget?.profileId
        let targetedDraftId: UUID? =
          if case .profile(let deepLink) = deepLinkTarget {
            deepLink.draftId
          } else {
            nil
          }
        await loadCachedMailState(targetedProfileId: targetedProfileId)
        await loadCurrentMailboxFromCache()
        initialLaunchDidFinish()
        await categoryViewModel.load()
        await composePreferenceStore.synchronize()
        await featureSuggestionPreferenceStore.synchronize()
        await signatureStore.synchronize()
        await inboxPreferenceStore.synchronize()
        updateMailViews()
        await readingPreferenceStore.synchronize()
        await swipePreferenceStore.synchronize()
        await notificationRuleViewModel.load(
          categoryIds: categoryViewModel.hasLoadedCategory
            ? Set(
              MessageCategoryChoice.available(customCategories: categoryViewModel.categories).map(
                \.id)
            )
            : nil
        )
        await reloadSyncedMailState(
          targetedProfileId: targetedProfileId
        )
        await importShareExtensionDrafts()
        await loadCompositionDrafts(profileId: activeDraftProfileId)
        openSavedDraft(targetedDraftId)
        await loadCurrentMailboxFromCache()
        mailboxObserversAreActive = true
        await mailboxFreshnessViewModel.synchronize(
          connections: gmailViewModel.connections,
          snapshotIsAuthoritative: gmailViewModel.connectionsSnapshotIsAuthoritative
        )
        await reloadObservedMailboxes()
        if case .message(let deepLink) = deepLinkTarget {
          await openSpotlightMessage(deepLink)
        }
        inboxViewModel.refreshPinnedBodyPrefetch(connections: profileConnections)
        initialStartupDidFinish()
        await blockedSenderStore.synchronize()
      }
      .task(id: sendingIdentitySynchronizationKey) {
        guard await session.revalidateTrustedDeviceAfterForegrounding() else { return }
        guard session.isCurrentSessionIdentity(snapshot) else { return }
        let eligibleConnections = profileConnections.filter {
          $0.authorizationState == .authorized && $0.capabilities.canSend
        }
        var providerConfirmedAddresses: [MailboxConnectionId: [String]] = [:]
        var providerDiscoveryFailures: [String] = []
        await withTaskGroup(
          of: (MailboxConnectionId, [String]?, String?).self
        ) { group in
          for connection in eligibleConnections {
            group.addTask { @MainActor in
              do {
                let addresses =
                  try await mailboxConnection.loadProviderConfirmedSendingAddresses(
                    connection: connection,
                    session: snapshot
                  )
                return (connection.id, addresses, nil)
              } catch is CancellationError {
                return (connection.id, nil, nil)
              } catch {
                return (
                  connection.id,
                  nil,
                  "\(connection.displayName): \(error.localizedDescription)"
                )
              }
            }
          }
          for await (connectionId, addresses, failure) in group {
            if let addresses { providerConfirmedAddresses[connectionId] = addresses }
            if let failure { providerDiscoveryFailures.append(failure) }
          }
        }
        guard !Task.isCancelled, session.isCurrentSessionIdentity(snapshot) else { return }
        await sendingIdentityStore.synchronize(
          connections: profileConnections,
          connectionsAreAuthoritative: gmailViewModel.connectionsSnapshotIsAuthoritative,
          legacyDefaultConnectionId: profileDefaultSendingConnectionId,
          providerConfirmedAddresses: providerConfirmedAddresses,
          providerDiscoveryErrorDescription: providerDiscoveryFailures.isEmpty
            ? nil
            : providerDiscoveryFailures.sorted().joined(separator: "\n")
        )
      }
      .task(id: shareExtensionCatalogSynchronizationKey) {
        await synchronizeShareExtensionCatalog()
      }
      .onChange(of: profileDeepLinkRouter.pendingTarget) { _, _ in
        guard let target = profileDeepLinkRouter.consumeTarget() else { return }
        Task {
          switch target {
          case .message(let deepLink):
            await openSpotlightMessage(deepLink)
          case .profile(let deepLink):
            await handleProfileDeepLink(
              profileId: deepLink.profileId,
              draftId: deepLink.draftId
            )
          }
        }
      }
      .task(id: scenePhase) {
        guard scenePhase == .active else { return }
        await session.revalidateProductAccountAfterForegrounding()
        guard session.isCurrentSessionIdentity(snapshot) else { return }
        await mailboxFreshnessViewModel.pollWhileActive(
          connections: { gmailViewModel.connections },
          snapshotIsAuthoritative: { gmailViewModel.connectionsSnapshotIsAuthoritative },
          revalidateTrustedDevice: {
            await session.revalidateTrustedDeviceAfterForegrounding()
          },
          didSynchronize: { await reloadObservedMailboxes() }
        )
      }
      .onChange(of: scenePhase) { _, phase in
        guard phase == .active else { return }
        Task {
          guard await session.revalidateTrustedDeviceAfterForegrounding() else { return }
          guard session.isCurrentSessionIdentity(snapshot) else { return }
          await blockedSenderStore.synchronize()
          await composePreferenceStore.synchronize()
          await featureSuggestionPreferenceStore.synchronize()
          await signatureStore.synchronize()
          await templateStore.synchronize()
          await inboxPreferenceStore.synchronize()
          await readingPreferenceStore.synchronize()
          await swipePreferenceStore.synchronize()
          await reloadSyncedMailState()
          await synchronizeMailboxes()
          inboxViewModel.refreshPinnedBodyPrefetch(connections: profileConnections)
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: .mailboxMetadataDidSynchronize)
          .receive(on: RunLoop.main)
      ) { notification in
        guard
          notification.userInfo?[MailboxSyncNotificationUserInfoKey.productAccountId]
            as? String == snapshot.productAccountId,
          let connectionId =
            notification.userInfo?[MailboxSyncNotificationUserInfoKey.connectionId] as? String,
          let phase = notification.userInfo?[MailboxSyncNotificationUserInfoKey.phase]
            as? MailboxSyncPhase
        else { return }
        let successfulSyncAt =
          notification.userInfo?[MailboxSyncNotificationUserInfoKey.successfulSyncAt] as? Date
        mailboxFreshnessViewModel.recordExternalSync(
          connectionIdRawValue: connectionId,
          phase: phase,
          successfulSyncAt: successfulSyncAt,
          supersedesHistoricalBackfill:
            notification.userInfo?[
              MailboxSyncNotificationUserInfoKey.supersedesHistoricalBackfill
            ] as? Bool
            ?? true,
          updatesExternalStatusRevision:
            notification.userInfo?[
              MailboxSyncNotificationUserInfoKey.updatesExternalStatusRevision
            ] as? Bool
            ?? true
        )
        let reloadObservedMetadata =
          notification.userInfo?[MailboxSyncNotificationUserInfoKey.reloadObservedMetadata]
          as? Bool == true
        guard successfulSyncAt != nil || reloadObservedMetadata else { return }
        Task {
          if successfulSyncAt != nil {
            let connectionsAreAuthoritative = await gmailViewModel.refreshSnapshot()
            mailboxFreshnessViewModel.updateConnections(
              gmailViewModel.connections,
              snapshotIsAuthoritative: connectionsAreAuthoritative,
              prunesPersistedState: connectionsAreAuthoritative
            )
          }
          await reloadObservedMailboxes()
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: .standardsMailIdleDidChange)
          .receive(on: RunLoop.main)
      ) { notification in
        guard
          notification.userInfo?[MailboxSyncNotificationUserInfoKey.productAccountId]
            as? String == snapshot.productAccountId,
          let rawConnectionId =
            notification.userInfo?[MailboxSyncNotificationUserInfoKey.connectionId] as? String,
          let connection = standardsMailIdleConnection(
            rawConnectionId: rawConnectionId,
            accountConnections: gmailViewModel.connections
          )
        else { return }
        Task {
          guard await session.revalidateTrustedDeviceAfterForegrounding() else { return }
          guard session.isCurrentSessionIdentity(snapshot) else { return }
          _ = try? await mailboxFreshnessViewModel.syncInbox(
            connection: connection,
            session: snapshot
          )
          await reloadObservedMailboxes()
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: .mailboxConnectionsDidChange)
          .receive(on: RunLoop.main)
      ) { notification in
        guard
          notification.userInfo?[MailboxSyncNotificationUserInfoKey.productAccountId]
            as? String == snapshot.productAccountId
        else { return }
        Task { await reloadSyncedMailState() }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: .categoryNotificationDeepLink)
          .receive(on: RunLoop.main)
      ) { notification in
        guard
          let deepLink =
            notification.object as? NotificationDeepLink
            ?? NotificationDeepLink(userInfo: notification.userInfo ?? [:])
        else { return }
        handleNotificationDeepLink(
          PendingNotificationDeepLinkStore.shared.take(
            productAccountId: snapshot.productAccountId
          ) ?? deepLink
        )
      }
      .onReceive(
        NotificationCenter.default.publisher(for: .sendReminderDeepLink)
          .receive(on: RunLoop.main)
      ) { handleSendReminderDeepLinkNotification($0) }
  }

  private func openSettings(_ route: SettingsRoute?) {
    settingsRouter.open(route)
  }

  private func updateSettingsMailProfileContext() {
    settingsMailProfileContext.update(
      activeProfile: profileViewModel.activeProfile
    ) { preferredProfileId in
      await reloadSyncedMailState(targetedProfileId: preferredProfileId)
      updateSettingsMailProfileContext()
    }
  }

  private func presentPendingCompactSettingsRequest() {
    #if !targetEnvironment(macCatalyst)
      guard
        SettingsNavigationLayout.resolve(horizontalSizeClass) == .compact,
        let request = settingsRouter.request,
        settingsRouter.claimPresentation(request.id, ownerID: settingsPresentationOwnerID)
      else { return }
      compactSettingsIsPresented = true
    #endif
  }

  private func updateProductMailboxState() {
    inboxViewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: profileOutboxItems.map(GmailMailActionViewModel.outboxState)
          + profileScheduledSendItems.map { item in
            item.state == .needsAttention ? .failed : .pending
          },
        pinnedThreadIds: pinViewModel.pinnedThreadIds,
        snoozedThreadIds: snoozeViewModel.snoozedThreadIds
      )
    )
  }

  private func reconcilePins(
    with messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]]
  ) {
    let messages =
      messagesByConnection
      .filter { profileViewModel.owns($0.key) }
      .values
      .flatMap { $0 }
    pinReconcileTask?.cancel()
    pinReconcileTask = Task {
      await pinViewModel.reconcile(with: messages)
    }
  }

  private func reconcileMutes(
    with messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]]
  ) {
    let messages =
      messagesByConnection
      .filter { profileViewModel.owns($0.key) }
      .values
      .flatMap { $0 }
    muteReconcileTask?.cancel()
    muteReconcileTask = Task {
      await muteViewModel.reconcile(with: messages)
    }
  }

  private func reconcileSnoozes(
    with messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]]
  ) {
    let messages =
      messagesByConnection
      .filter { profileViewModel.owns($0.key) }
      .values
      .flatMap { $0 }
    snoozeReconcileTask?.cancel()
    snoozeReconcileTask = Task {
      await snoozeViewModel.reconcile(with: messages)
    }
  }

  private func reconcileFollowUpNudges(
    with messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]]
  ) {
    let messages =
      messagesByConnection
      .filter { profileViewModel.owns($0.key) }
      .values
      .flatMap { $0 }
    followUpNudgeReconcileTask?.cancel()
    followUpNudgeReconcileTask = Task {
      await followUpNudgeViewModel.reconcile(
        with: messages,
        connections: profileConnections
      )
    }
  }

  private func reconcileSpotlight(
    messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]]? = nil
  ) {
    let messagesByConnection =
      messagesByConnection ?? inboxViewModel.navigationSnapshot.messagesByConnection
    let connectionsByProfile = Dictionary(
      uniqueKeysWithValues: profileViewModel.profiles.map { profile in
        (
          profile.id,
          profileViewModel.connections(for: profile.id, from: gmailViewModel.connections)
        )
      }
    )
    spotlightReconcileTask?.cancel()
    spotlightReconcileTask = Task {
      await profileInterruptionViewModel.reconcileSpotlight(
        profiles: profileViewModel.profiles,
        messagesByConnection: messagesByConnection,
        connectionsByProfile: connectionsByProfile
      )
    }
  }

  private func openSpotlightMessage(_ deepLink: MailMessageDeepLink) async {
    guard deepLink.productAccountId == snapshot.productAccountId else { return }
    guard await switchProfileAndWait(to: deepLink.profileId) else { return }
    await profileInterruptionViewModel.load(profileId: deepLink.profileId)
    guard
      profileViewModel.activeProfileId == deepLink.profileId,
      profileInterruptionViewModel.policy.allowsContentReveal,
      profileViewModel.owns(deepLink.connectionId)
    else { return }
    await inboxViewModel.loadNavigation(connections: profileConnections)
    guard
      let message = deepLink.message(
        in: inboxViewModel.navigationSnapshot.messagesByConnection
      )
    else { return }
    selectSearchResult(message)
  }

  private func switchProfile(to profileId: MailProfileId) {
    Task { _ = await switchProfileAndWait(to: profileId) }
  }

  private func switchProfileAndWait(to profileId: MailProfileId) async -> Bool {
    let switchGeneration = profileSwitchGate.begin()
    guard let sourceProfileId = profileViewModel.activeProfileId else {
      return await loadProfileAndWait(to: profileId, switchGeneration: switchGeneration)
    }
    guard sourceProfileId != profileId else {
      return await refreshProfileAndWait(profileId, switchGeneration: switchGeneration)
    }
    return await activateProfileAndWait(
      from: sourceProfileId,
      to: profileId,
      switchGeneration: switchGeneration
    )
  }

  private func loadProfileAndWait(
    to profileId: MailProfileId,
    switchGeneration: Int
  ) async -> Bool {
    await profileViewModel.load(
      restoredProfileId: restoredProfileIdRawValue.map(MailProfileId.init(rawValue:)),
      targetedProfileId: profileId
    )
    guard isCurrentProfileSwitch(switchGeneration, profileId: profileId) else { return false }
    await reloadProfileScopedStoresIfNeeded()
    guard isCurrentProfileSwitch(switchGeneration, profileId: profileId) else { return false }
    prepareProfilePresentationForSwitch()
    prepareProfileThreadState(for: profileId)
    await reloadPreparedProfileThreadState(for: profileId)
    guard profileViewModel.activeProfileId == profileId else { return false }
    return profileSwitchGate.performIfCurrent(switchGeneration) {
      finishProfileSwitch(to: profileId)
      return true
    } ?? false
  }

  private func refreshProfileAndWait(
    _ profileId: MailProfileId,
    switchGeneration: Int
  ) async -> Bool {
    restoredProfileIdRawValue = profileId.rawValue
    await reloadProfileScopedStoresIfNeeded()
    guard profileSwitchGate.isCurrent(switchGeneration) else { return false }
    await loadActiveProfileMutes()
    return profileSwitchGate.isCurrent(switchGeneration)
  }

  private func activateProfileAndWait(
    from sourceProfileId: MailProfileId,
    to profileId: MailProfileId,
    switchGeneration: Int
  ) async -> Bool {
    do {
      // Present the reset shell in stages so its observed mutations do not share a frame.
      guard
        await prepareStagedProfilePresentationForSwitch(
          from: sourceProfileId,
          switchGeneration: switchGeneration
        )
      else { return false }
      guard
        !Task.isCancelled,
        profileSwitchGate.isCurrent(switchGeneration),
        profileViewModel.activeProfileId == sourceProfileId
      else { return false }
      try profileViewModel.activate(profileId) {
        if composerNavigation.draft != nil {
          parkedComposerProfileIds.insert(sourceProfileId)
          composerNavigation.park()
        }
      }
      await waitForNextMainRunLoopCycle()
      guard
        !Task.isCancelled,
        profileSwitchGate.isCurrent(switchGeneration),
        profileViewModel.activeProfileId == profileId
      else { return false }
      let preparedProfileRecordScope = await prepareProfileScopedStoresIfNeeded()
      await waitForNextMainRunLoopCycle()
      guard
        !Task.isCancelled,
        profileSwitchGate.isCurrent(switchGeneration),
        profileViewModel.activeProfileId == profileId
      else { return false }
      prepareProfileThreadState(for: profileId)
      await waitForNextMainRunLoopCycle()
      guard
        !Task.isCancelled,
        profileSwitchGate.isCurrent(switchGeneration),
        profileViewModel.activeProfileId == profileId
      else { return false }
      finishProfileSwitch(to: profileId)
      if let preparedProfileRecordScope {
        Task {
          await synchronizePreparedProfileScopedStores(for: preparedProfileRecordScope)
        }
      }
      Task { await reloadPreparedProfileThreadState(for: profileId) }
      return true
    } catch {
      profileViewModel.show(error)
      return false
    }
  }

  private func isCurrentProfileSwitch(
    _ switchGeneration: Int,
    profileId: MailProfileId
  ) -> Bool {
    profileSwitchGate.isCurrent(switchGeneration)
      && profileViewModel.activeProfileId == profileId
  }

  private func prepareProfilePresentationForSwitch() {
    mailShellSelection.selectUnifiedInbox()
    inboxViewModel.prepareForProfileSwitch()
  }

  private func prepareStagedProfilePresentationForSwitch(
    from sourceProfileId: MailProfileId,
    switchGeneration: Int
  ) async -> Bool {
    contentPresentationDismissal.dismissPresentations()
    mailShellSelection.clearThreadSelection()
    mailShellSelection.selectUnifiedInbox()
    await waitForNextMainRunLoopCycle()
    guard
      !Task.isCancelled,
      profileSwitchGate.isCurrent(switchGeneration),
      profileViewModel.activeProfileId == sourceProfileId
    else { return false }
    inboxViewModel.clearVisibleThreadsForProfileSwitch()
    await waitForNextMainRunLoopCycle()
    guard
      !Task.isCancelled,
      profileSwitchGate.isCurrent(switchGeneration),
      profileViewModel.activeProfileId == sourceProfileId
    else { return false }
    inboxViewModel.prepareNavigationForProfileSwitch()
    await waitForNextMainRunLoopCycle()
    guard
      !Task.isCancelled,
      profileSwitchGate.isCurrent(switchGeneration),
      profileViewModel.activeProfileId == sourceProfileId
    else { return false }
    inboxViewModel.clearNavigationSnapshotForProfileSwitch()
    await waitForNextMainRunLoopCycle()
    guard
      !Task.isCancelled,
      profileSwitchGate.isCurrent(switchGeneration),
      profileViewModel.activeProfileId == sourceProfileId
    else { return false }
    inboxViewModel.prepareTransientStateForProfileSwitch()
    await waitForNextMainRunLoopCycle()
    guard
      !Task.isCancelled,
      profileSwitchGate.isCurrent(switchGeneration),
      profileViewModel.activeProfileId == sourceProfileId
    else { return false }
    return true
  }

  private func finishProfileSwitch(to profileId: MailProfileId) {
    restoredProfileIdRawValue = profileId.rawValue
    gmailViewModel.selectedConnectionId = profileConnections.first?.id
    if parkedComposerProfileIds.remove(profileId) != nil,
      let viewModel = composerViewModels[profileId]
    {
      composerNavigation.present(viewModel.draft)
    }
    loadUnifiedMailbox(synchronizes: false)
    Task {
      await waitForCurrentMailboxLoad {
        (inboxLoadTask, inboxLoadGeneration)
      }
      await Task.yield()
      guard profileViewModel.activeProfileId == profileId else { return }
      await inboxViewModel.loadNavigation(connections: profileConnections)
      guard profileViewModel.activeProfileId == profileId else { return }
      await loadCompositionDrafts(profileId: profileId)
    }
  }

  private func prepareProfileThreadState(for profileId: MailProfileId) {
    muteViewModel.updateProfile(profileId)
    snoozeViewModel.updateProfile(profileId)
    followUpNudgeViewModel.updateProfile(profileId)
    updateProductMailboxState()
  }

  private func reloadPreparedProfileThreadState(for profileId: MailProfileId) async {
    guard profileViewModel.activeProfileId == profileId else { return }
    await muteViewModel.load()
    guard profileViewModel.activeProfileId == profileId else { return }
    await snoozeViewModel.load()
    guard profileViewModel.activeProfileId == profileId else { return }
    await followUpNudgeViewModel.load()
    guard profileViewModel.activeProfileId == profileId else { return }
    let messages =
      inboxViewModel.navigationSnapshot.messagesByConnection
      .filter { profileViewModel.owns($0.key) }
      .values
      .flatMap { $0 }
    await snoozeViewModel.reconcile(with: messages)
    guard profileViewModel.activeProfileId == profileId else { return }
    await followUpNudgeViewModel.reconcile(
      with: messages,
      connections: profileConnections
    )
    guard profileViewModel.activeProfileId == profileId else { return }
    updateProductMailboxState()
  }

  private func reloadProfileScopedStoresIfNeeded() async {
    guard let recordScope = await prepareProfileScopedStoresIfNeeded() else { return }
    await synchronizePreparedProfileScopedStores(for: recordScope)
  }

  // swiftlint:disable:next function_body_length
  private func prepareProfileScopedStoresIfNeeded() async -> MailProfileRecordScope? {
    guard let recordScope = profileViewModel.activeProfile?.recordScope,
      recordScope != profilePreferenceRecordScope
    else { return nil }

    let pacesPreparation = profilePreferenceRecordScope != .legacyProductAccount
    func shouldContinuePreparation() async -> Bool {
      if pacesPreparation {
        await waitForNextMainRunLoopCycle()
      }
      return profileViewModel.activeProfile?.recordScope == recordScope
    }

    let blockedSenderStore = BlockedSenderStore(
      session: snapshot,
      recordScope: recordScope,
      syncService: blockedSenderSyncServiceFactory(recordScope)
    )
    guard await shouldContinuePreparation() else { return nil }
    let categoryViewModel = CustomCategoryViewModel(
      service: categorySyncServiceFactory(recordScope),
      session: snapshot
    )
    guard await shouldContinuePreparation() else { return nil }
    let composePreferenceStore = session.sharedComposePreferenceStore(
      for: snapshot,
      recordScope: recordScope,
      syncService: composePreferenceSyncFactory(recordScope)
    )
    guard await shouldContinuePreparation() else { return nil }
    let featureSuggestionPreferenceStore = session.sharedFeatureSuggestionPreferenceStore(
      for: snapshot,
      recordScope: recordScope,
      syncService: featureSuggestionPreferenceSyncFactory(recordScope)
    )
    guard await shouldContinuePreparation() else { return nil }
    let inboxPreferenceStore = session.sharedInboxPreferenceStore(
      for: snapshot,
      recordScope: recordScope,
      syncService: inboxPreferenceSyncFactory(recordScope)
    )
    guard await shouldContinuePreparation() else { return nil }
    let sendingIdentityStore = SendingIdentityStore(
      session: snapshot,
      recordScope: recordScope,
      syncService: sendingIdentitySyncFactory(recordScope)
    )
    guard await shouldContinuePreparation() else { return nil }
    let signatureStore = session.sharedSignatureStore(
      for: snapshot,
      recordScope: recordScope,
      syncService: signaturePreferenceSyncFactory(recordScope)
    )
    guard await shouldContinuePreparation() else { return nil }
    let templateStore = session.sharedTemplateStore(
      for: snapshot,
      recordScope: recordScope,
      syncService: templatePreferenceSyncFactory(recordScope)
    )
    guard await shouldContinuePreparation() else { return nil }
    self.blockedSenderStore.retire()
    self.blockedSenderStore = blockedSenderStore
    self.categoryViewModel = categoryViewModel
    self.composePreferenceStore = composePreferenceStore
    self.featureSuggestionPreferenceStore = featureSuggestionPreferenceStore
    self.inboxPreferenceStore = inboxPreferenceStore
    self.sendingIdentityStore = sendingIdentityStore
    self.signatureStore = signatureStore
    self.templateStore = templateStore
    profilePreferenceRecordScope = recordScope
    releaseBudgetDriver?.recordActiveProfileRecordScope(
      recordScope,
      owner: releaseBudgetDriverOwner
    )
    return recordScope
  }

  private func synchronizePreparedProfileScopedStores(
    for recordScope: MailProfileRecordScope
  ) async {
    guard profilePreferenceRecordScope == recordScope else { return }
    let blockedSenderStore = self.blockedSenderStore
    let categoryViewModel = self.categoryViewModel
    let composePreferenceStore = self.composePreferenceStore
    let featureSuggestionPreferenceStore = self.featureSuggestionPreferenceStore
    let inboxPreferenceStore = self.inboxPreferenceStore
    let sendingIdentityStore = self.sendingIdentityStore
    let signatureStore = self.signatureStore
    let templateStore = self.templateStore
    let storesAreCurrent = {
      self.profilePreferenceRecordScope == recordScope
        && self.blockedSenderStore === blockedSenderStore
        && self.categoryViewModel === categoryViewModel
        && self.composePreferenceStore === composePreferenceStore
        && self.featureSuggestionPreferenceStore === featureSuggestionPreferenceStore
        && self.inboxPreferenceStore === inboxPreferenceStore
        && self.sendingIdentityStore === sendingIdentityStore
        && self.signatureStore === signatureStore
        && self.templateStore === templateStore
    }
    await blockedSenderStore.synchronize()
    guard storesAreCurrent() else { return }
    await categoryViewModel.load()
    guard storesAreCurrent() else { return }
    await composePreferenceStore.synchronize()
    guard storesAreCurrent() else { return }
    await featureSuggestionPreferenceStore.synchronize()
    guard storesAreCurrent() else { return }
    await inboxPreferenceStore.synchronize()
    guard storesAreCurrent() else { return }
    await sendingIdentityStore.synchronize(
      connections: profileConnections,
      legacyDefaultConnectionId: profileDefaultSendingConnectionId
    )
    guard storesAreCurrent() else { return }
    await signatureStore.synchronize()
    guard storesAreCurrent() else { return }
    updateMailViews()
    await templateStore.synchronize()
    guard storesAreCurrent() else { return }
  }

  private func reloadSyncedMailState(
    targetedProfileId: MailProfileId? = nil
  ) async {
    await pinViewModel.load()
    let connectionsAreAuthoritative = await gmailViewModel.load()
    await profileViewModel.load(
      restoredProfileId: restoredProfileIdRawValue.map(MailProfileId.init(rawValue:)),
      targetedProfileId: targetedProfileId
    )
    await reloadProfileScopedStoresIfNeeded()
    restoredProfileIdRawValue = profileViewModel.activeProfileId?.rawValue
    if let profileId = profileViewModel.activeProfileId {
      prepareProfileThreadState(for: profileId)
      await reloadPreparedProfileThreadState(for: profileId)
    }
    mailboxFreshnessViewModel.updateConnections(
      gmailViewModel.connections,
      snapshotIsAuthoritative: connectionsAreAuthoritative,
      prunesPersistedState: connectionsAreAuthoritative
    )
    await mailActionViewModel.resume(connections: gmailViewModel.connections)
    if let storedSendReminderDeepLink = PendingSendReminderDeepLinkStore.shared.take(
      productAccountId: snapshot.productAccountId
    ) {
      handleSendReminderDeepLink(storedSendReminderDeepLink)
    } else if let pendingSendReminderDeepLink {
      handleSendReminderDeepLink(pendingSendReminderDeepLink)
    }
    if let storedDeepLink = PendingNotificationDeepLinkStore.shared.take(
      productAccountId: snapshot.productAccountId
    ) {
      handleNotificationDeepLink(storedDeepLink)
    } else if let pendingNotificationDeepLink {
      handleNotificationDeepLink(pendingNotificationDeepLink)
    }
    updateProductMailboxState()
    showsBlockedActionAlert = mailActionViewModel.pendingFailureConnectionId != nil
    await genericMailSetupViewModel.loadSyncedDefinitions()
  }

  private func loadActiveProfileMutes() async {
    guard let profileId = profileViewModel.activeProfileId else { return }
    muteViewModel.updateProfile(profileId)
    await muteViewModel.load()
  }

  private func loadCachedMailState(targetedProfileId: MailProfileId?) async {
    await gmailViewModel.loadCachedConnections()
    guard !gmailViewModel.connections.isEmpty else { return }
    await profileViewModel.loadCached(
      connectionIds: gmailViewModel.connections.map(\.id),
      restoredProfileId: restoredProfileIdRawValue.map(MailProfileId.init(rawValue:)),
      targetedProfileId: targetedProfileId
    )
    mailboxFreshnessViewModel.updateConnections(
      gmailViewModel.connections,
      snapshotIsAuthoritative: false,
      prunesPersistedState: false
    )
  }

  private func loadCurrentMailboxFromCache() async {
    if mailShellSelection.selectedMailbox?.isUnified == true {
      loadUnifiedMailbox(synchronizes: false)
      await waitForCurrentMailboxLoad {
        (inboxLoadTask, inboxLoadGeneration)
      }
    } else if let connection = selectedConnection,
      connection.authorizationState == .authorized
    {
      let collection = mailShellSelection.selectedMailbox?.collection ?? .role(.inbox)
      let connections = profileConnections
      let initialLoadTask = Task {
        await inboxViewModel.loadInitialMailboxThenNavigation(
          connection: connection,
          collection: collection,
          connections: connections
        )
      }
      inboxLoadGeneration += 1
      inboxLoadTask = initialLoadTask
      await waitForCurrentMailboxLoad {
        (inboxLoadTask, inboxLoadGeneration)
      }
    }
  }

  private func handleNotificationDeepLink(_ deepLink: NotificationDeepLink) {
    guard deepLink.productAccountId == snapshot.productAccountId else { return }
    guard gmailViewModel.connections.contains(where: { $0.id == deepLink.connectionId }) else {
      pendingNotificationDeepLink = deepLink
      return
    }
    pendingNotificationDeepLink = nil
    Task {
      guard
        let connection = await profileConnectionAfterActivation(
          deepLink.connectionId,
          activate: { await switchProfileAndWait(to: deepLink.profileId) },
          connections: { profileConnections }
        )
      else {
        pendingNotificationDeepLink = deepLink
        return
      }
      selectConnection(connection)
    }
  }

  private func handleSendReminderDeepLink(_ deepLink: SendReminderDeepLink) {
    guard deepLink.productAccountId == snapshot.productAccountId else { return }
    pendingSendReminderDeepLink = nil
    Task {
      guard await switchProfileAndWait(to: deepLink.profileId) else {
        pendingSendReminderDeepLink = deepLink
        return
      }
      do {
        let drafts = try await compositionDraftRepository.drafts(
          productAccountId: snapshot.productAccountId,
          profileId: deepLink.profileId,
          session: snapshot
        )
        guard
          compositionDraftCanBePresented(
            originatingProfileId: deepLink.profileId,
            activeProfileId: profileViewModel.activeProfileId
          )
        else { return }
        guard var draft = drafts.first(where: { $0.id == deepLink.draftId }) else { return }
        if let reminder = draft.sendReminder,
          reminder.id == deepLink.reminderId,
          reminder.revision == deepLink.reminderRevision
        {
          draft.sendReminder = nil
          draft.markEdited()
          try await saveCompositionDraft(draft, profileId: deepLink.profileId)
          guard
            compositionDraftCanBePresented(
              originatingProfileId: deepLink.profileId,
              activeProfileId: profileViewModel.activeProfileId
            )
          else { return }
          cancelSendReminder(reminder, draftId: draft.id, profileId: deepLink.profileId)
        }
        presentComposerDraft(draft)
      } catch {
        profileViewModel.show(error)
      }
    }
  }

  private func handleSendReminderDeepLinkNotification(_ notification: Notification) {
    guard
      let deepLink = notification.object as? SendReminderDeepLink
        ?? SendReminderDeepLink(userInfo: notification.userInfo ?? [:])
    else { return }
    handleSendReminderDeepLink(
      PendingSendReminderDeepLinkStore.shared.take(
        productAccountId: snapshot.productAccountId
      ) ?? deepLink
    )
  }
}

extension AccountView {
  static func clearGenericMailLocalData(
    _ definition: GenericMailConnectionDefinition,
    session: ProductAccountSessionSnapshot,
    mailboxConnection: MailboxConnectionAdapter
  ) async throws -> Bool {
    guard definition.connectionId.providerMailboxIdentity.providerId == .imapSMTP else {
      return false
    }
    let connection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: .none,
      connectedAt: 0,
      displayName: definition.emailAddress,
      id: definition.connectionId,
      lastVerifiedAt: 0,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 0
    )
    try await mailboxConnection.clearLocalConnection(connection, session: session)
    return true
  }

  private var pendingActionFailureConnection: MailboxConnection? {
    guard let connectionId = mailActionViewModel.pendingFailureConnectionId else { return nil }
    return profileConnections.first { $0.id == connectionId }
  }

  private func acknowledgePendingActionFailure(connection: MailboxConnection) {
    Task {
      await mailActionViewModel.acknowledgeFailures(connection: connection)
      await inboxViewModel.loadNavigation(connections: profileConnections)
      showsBlockedActionAlert = mailActionViewModel.pendingFailureConnectionId != nil
    }
  }

  private func resolveBlockedAction(
    connection: MailboxConnection,
    discard: Bool
  ) {
    Task {
      if discard {
        await mailActionViewModel.discardBlockedAction(connection: connection)
      } else {
        await mailActionViewModel.retryBlockedAction(connection: connection)
      }
      _ = await inboxViewModel.reloadLocal(connection: connection)
      await inboxViewModel.loadNavigation(connections: profileConnections)
      showsBlockedActionAlert = mailActionViewModel.pendingFailureConnectionId != nil
    }
  }

  private var selectedConnection: MailboxConnection? {
    guard let connectionId = mailShellSelection.selectedConnectionId else { return nil }
    return profileConnections.first { $0.id == connectionId }
  }

  private var availableCategoryChoices: [MessageCategoryChoice] {
    MessageCategoryChoice.available(
      customCategories: categoryViewModel.categories,
      configuration: categoryViewModel.configuration
    )
  }

  private var selectedMailViewBinding: Binding<MailViewSelection> {
    Binding(
      get: { mailShellSelection.selectedMailView },
      set: {
        mailShellSelection.selectMailView($0)
        preferredCompactColumn = .content
      }
    )
  }

  private var mailShellBottomBar: some View {
    VStack(spacing: 0) {
      if mailShellSelection.selectedMailbox != .outbox {
        MailboxSynchronizationOverlay(
          connections: selectedSynchronizationConnections,
          isLoadingInitialAvailability: inboxViewModel.isLoading,
          retry: retrySynchronization
        )
      }
      if mailShellSelection.selectedMailbox != nil, !profileConnections.isEmpty {
        MailShellMailViewBar(
          presentations: mailShellSelection.mailViewPresentations(
            categoryChoices: availableCategoryChoices
          ),
          selection: selectedMailViewBinding
        )
      }
    }
    .frame(maxWidth: .infinity)
    .onGeometryChange(for: CGFloat.self) { geometry in
      geometry.size.height
    } action: { height in
      mailShellBottomBarHeight = height
    }
  }

  private var showsComposeButton: Bool {
    composerNavigation.draft == nil
      && mailShellSelection.selectedMailbox != nil
      && !profileConnections.isEmpty
      && (horizontalSizeClass != .compact || mailShellSelection.navigationLevel == .threadList)
  }

  private func beginNewMessage() {
    beginNewMessage(using: nil)
  }

  private func beginNewMessage(using template: MailTemplate?) {
    let defaultIdentity = sendingIdentityStore.preferences.defaultIdentity
    presentComposerDraft(
      .new(
        defaultSendingConnectionId:
          defaultIdentity?.connectionId ?? profileDefaultSendingConnectionId,
        defaultSendingIdentityId: defaultIdentity?.id,
        signatures: signatureStore.preferences,
        template: template
      ))
  }

  private var selectedSynchronizationConnections: [MailboxSyncOverlayConnection] {
    let connections: [MailboxConnection] =
      if mailShellSelection.selectedMailbox?.isUnified == true {
        profileConnections
      } else if let selectedConnection {
        [selectedConnection]
      } else {
        []
      }
    return connections.map {
      MailboxSyncOverlayConnection(
        id: $0.id,
        name: $0.displayName,
        status: mailboxFreshnessViewModel.status(for: $0)
      )
    }
  }

  private func updateMailViews() {
    if categoryViewModel.hasLoadedCategory {
      let categoryIds = Set(availableCategoryChoices.map(\.id))
      inboxPreferenceStore.retainAvailableMailViewCategories(categoryIds)
    }
    mailShellSelection.updateMailViews(
      configuration: inboxPreferenceStore.preferences.mailViewConfiguration
    )
  }

  private func retrySynchronization(_ connectionIds: [MailboxConnectionId]) async {
    guard await session.revalidateTrustedDeviceAfterForegrounding() else { return }
    guard session.isCurrentSessionIdentity(snapshot) else { return }
    for connection in gmailViewModel.connections where connectionIds.contains(connection.id) {
      await mailboxFreshnessViewModel.synchronizeFully(
        connection: connection,
        among: gmailViewModel.connections,
        snapshotIsAuthoritative: gmailViewModel.connectionsSnapshotIsAuthoritative
      )
    }
    await reloadObservedMailboxes()
  }

  private func updatePreferredCompactColumn() {
    if composerNavigation.draft != nil, usesCompactComposerPresentation {
      preferredCompactColumn = .detail
      return
    }
    preferredCompactColumn = mailShellSelection.compactColumn(
      isEditing: editMode?.wrappedValue == .active
    )
  }

  private func dismissCompositionDraft() {
    let profileId = activeDraftProfileId
    if composerViewModels[profileId]?.isFinished == true {
      composerViewModels[profileId] = nil
    }
    composerNavigation.dismiss()
  }

  private func presentComposerDraft(_ draft: MailShellCompositionDraft) {
    composerSendErrorMessage = ""
    showsComposerSendError = false
    let profileId = activeDraftProfileId
    let preparedDraft = preparedCompositionDraft(draft)
    if let viewModel = composerViewModels[profileId] {
      Task {
        guard await viewModel.switchDraft(to: preparedDraft) else { return }
        guard activeDraftProfileId == profileId else { return }
        composerNavigation.present(viewModel.draft)
      }
    } else {
      let viewModel = makeComposerViewModel(draft: preparedDraft, profileId: profileId)
      composerViewModels[profileId] = viewModel
      composerNavigation.present(viewModel.draft)
    }
  }

  private func preparedCompositionDraft(
    _ draft: MailShellCompositionDraft
  ) -> MailShellCompositionDraft {
    var result = draft
    if result.signature == nil {
      result.applyDefaultSignature(from: signatureStore.preferences)
    }
    if let connectionId = result.connectionId {
      result.applyInitialReadReceiptPolicy(
        readingPreferenceStore.preferences.outgoingReadReceiptPolicy(for: connectionId)
      )
    }
    return result
  }

  private func makeComposerViewModel(
    draft: MailShellCompositionDraft,
    profileId: MailProfileId
  ) -> MailComposerViewModel {
    MailComposerViewModel(
      draft: draft,
      presentation: composePreferenceStore.preferences.presentation,
      reminderOwnerDeviceId: snapshot.trustedDeviceId,
      saveDraft: { draft in
        try await saveCompositionDraft(draft, profileId: profileId)
      },
      deleteDraft: { draftId in
        try await deleteCompositionDraft(draftId, profileId: profileId)
      },
      cancelReminder: { reminder, draftId in
        cancelSendReminder(reminder, draftId: draftId, profileId: profileId)
      },
      scheduleReminder: { draft in
        try await scheduleSendReminder(for: draft, profileId: profileId)
      },
      scheduleSend: { draft, dueAt, timeZone in
        await scheduleNewMessage(
          draft,
          profileId: profileId,
          dueAt: dueAt,
          originalTimeZoneIdentifier: timeZone
        )
      },
      sendDraft: { draft in
        mailActionViewModel.clearError()
        composerSendErrorMessage = ""
        showsComposerSendError = false
        let didSend = await sendCompositionDraft(draft)
        if let message = Self.composerSendErrorMessage(
          didSend: didSend,
          actionErrorMessage: mailActionViewModel.errorMessage,
          attemptedDraftId: draft.id,
          presentedDraftId: composerNavigation.draft?.id
        ) {
          composerSendErrorMessage = message
          showsComposerSendError = true
        }
        return didSend
      }
    )
  }

  private func toggleCompositionDraftExpansion() {
    composerNavigation.toggleExpansion()
  }

  private var usesCompactComposerPresentation: Bool {
    #if MAIL_TEST_BOOTSTRAP
      switch ProcessInfo.processInfo.environment["COMPOSER_UI_TEST_LAYOUT"] {
      case "compact": return true
      case "regular": return false
      default: break
      }
    #endif
    return horizontalSizeClass == .compact
  }

  private var selectedThreadsBinding: Binding<Set<MailboxThreadIdentity>> {
    Binding(
      get: { mailShellSelection.selectedThreadIds },
      set: { mailShellSelection.selectThreads($0) }
    )
  }

  private func loadMailbox(
    for connection: MailboxConnection,
    synchronizes: Bool = true,
    revalidatesTrustedDevice: Bool = false
  ) {
    inboxLoadTask?.cancel()
    let collection = mailShellSelection.selectedMailbox?.collection ?? .role(.inbox)
    inboxLoadGeneration += 1
    inboxLoadTask = Task {
      if revalidatesTrustedDevice {
        guard await session.revalidateTrustedDeviceAfterForegrounding() else { return }
        guard session.isCurrentSessionIdentity(snapshot), !Task.isCancelled else { return }
      }
      await inboxViewModel.loadAfterConnectionChange(
        connection: connection,
        collection: collection,
        synchronizes: synchronizes
      )
    }
  }

  private func loadUnifiedMailbox(
    synchronizes: Bool = true,
    revalidatesTrustedDevice: Bool = false
  ) {
    guard case .unified(let mailbox) = mailShellSelection.selectedMailbox else { return }
    inboxLoadTask?.cancel()
    let connections = profileConnections
    inboxLoadGeneration += 1
    inboxLoadTask = Task {
      if revalidatesTrustedDevice {
        guard await session.revalidateTrustedDeviceAfterForegrounding() else { return }
        guard session.isCurrentSessionIdentity(snapshot), !Task.isCancelled else { return }
      }
      await inboxViewModel.loadUnifiedMailbox(
        mailbox,
        connections: connections,
        synchronizes: synchronizes
      )
    }
  }

  private func synchronizeMailboxes() async {
    await mailboxFreshnessViewModel.synchronize(
      connections: gmailViewModel.connections,
      snapshotIsAuthoritative: gmailViewModel.connectionsSnapshotIsAuthoritative
    )
    await reloadObservedMailboxes()
  }

  private func synchronizeMailboxesFully() async {
    await mailboxFreshnessViewModel.synchronizeFully(
      connections: profileConnections,
      snapshotIsAuthoritative: gmailViewModel.connectionsSnapshotIsAuthoritative
    )
    await reloadObservedMailboxes()
  }

  private func reloadObservedMailboxes() async {
    await inboxViewModel.loadNavigation(connections: profileConnections)
    if mailShellSelection.selectedMailbox?.isUnified == true {
      loadUnifiedMailbox(synchronizes: false)
    } else if let connection = selectedConnection,
      connection.authorizationState == .authorized
    {
      loadMailbox(for: connection, synchronizes: false)
    }
  }

  private func sendCompositionDraft(_ draft: MailShellCompositionDraft) async -> Bool {
    guard await session.revalidateTrustedDeviceAfterForegrounding() else { return false }
    guard session.isCurrentSessionIdentity(snapshot) else { return false }
    guard
      let connectionId = draft.connectionId,
      let connection = profileConnections.first(where: { $0.id == connectionId }),
      let identity = profileSendingIdentities.first(where: { $0.id == draft.sendingIdentityId }),
      connection.authorizationState == .authorized,
      connection.capabilities.canSend,
      identity.connectionId == connectionId
    else {
      return false
    }
    let replyThreadMessages = replyThread(for: draft)?.messages
    let didSend = await mailActionViewModel.send(
      recipient: draft.recipient,
      subject: draft.subject,
      body: draft.deliveryBody,
      document: draft.deliveryDocument,
      assets: draft.assets,
      ccRecipients: draft.ccRecipients,
      bccRecipients: draft.bccRecipients,
      fromAddress: identity.headerValue,
      sendingIdentityId: identity.id,
      replyTo: draft.replyToMessage,
      sourceMessage: draft.sourceMessage,
      connection: connection,
      requestsReadReceipt: draft.requestsReadReceipt,
      undoSendWindow: composePreferenceStore.preferences.undoSendWindow
    )
    if didSend, readingPreferenceStore.preferences.marksReadOnReply,
      let unreadMessages = replyThreadMessages?.filter({
        $0.isUnread && $0.connectionId == connection.id
      }),
      !unreadMessages.isEmpty,
      connection.capabilities.supports(.markRead)
    {
      _ = await mailActionViewModel.perform(
        .markRead,
        for: unreadMessages,
        connection: connection
      )
      _ = await inboxViewModel.reloadLocal(connection: connection)
    }
    return didSend
  }

  private func responseAssistanceContext(
    for draft: MailShellCompositionDraft
  ) -> ResponseAssistanceContext? {
    guard let threadId = draft.replyToMessage?.threadIdentity,
      inboxViewModel.navigationSnapshot.thread(threadId) != nil
    else { return nil }
    let inboxViewModel = inboxViewModel
    return ResponseAssistanceContext(
      localBodyText: inboxViewModel.loadedMessageBodyText(for:),
      thread: {
        inboxViewModel.navigationSnapshot.thread(threadId)
      }
    )
  }

  private func replyThread(for draft: MailShellCompositionDraft) -> MailboxThread? {
    guard let threadId = draft.replyToMessage?.threadIdentity else { return nil }
    return inboxViewModel.navigationSnapshot.thread(threadId)
  }

  /// Returns the error to present after a Mail Shell composer send attempt.
  static func composerSendErrorMessage(
    didSend: Bool,
    actionErrorMessage: String?,
    attemptedDraftId: UUID? = nil,
    presentedDraftId: UUID? = nil
  ) -> String? {
    if let attemptedDraftId, attemptedDraftId != presentedDraftId { return nil }
    guard !didSend else { return nil }
    return actionErrorMessage
      ?? "The message could not be added to Outbox. Keep editing and try again."
  }

  /// Presents a draft in the Mail Shell host's navigation state.
  static func presentCompositionDraft(
    _ draft: MailShellCompositionDraft,
    in navigation: inout MailShellComposerNavigationState
  ) {
    navigation.present(draft)
  }

  private func scheduleNewMessage(
    _ draft: MailShellCompositionDraft,
    profileId: MailProfileId,
    dueAt: Date,
    originalTimeZoneIdentifier: String
  ) async -> Bool {
    guard await session.revalidateTrustedDeviceAfterForegrounding() else { return false }
    guard session.isCurrentSessionIdentity(snapshot) else { return false }
    guard
      let connectionId = draft.connectionId,
      let connection = profileConnections.first(where: { $0.id == connectionId }),
      let identity = profileSendingIdentities.first(where: { $0.id == draft.sendingIdentityId }),
      connection.authorizationState == .authorized,
      connection.providerId.supportsProductOwnedScheduledSend,
      connection.capabilities.canSend,
      identity.connectionId == connectionId
    else {
      return false
    }
    return await mailActionViewModel.scheduleSend(
      recipient: draft.recipient,
      subject: draft.subject,
      body: draft.deliveryBody,
      document: draft.deliveryDocument,
      assets: draft.assets,
      ccRecipients: draft.ccRecipients,
      bccRecipients: draft.bccRecipients,
      fromAddress: identity.headerValue,
      sendingIdentityId: identity.id,
      replyTo: draft.replyToMessage,
      sourceMessage: draft.sourceMessage,
      connection: connection,
      requestsReadReceipt: draft.requestsReadReceipt,
      draftId: draft.id,
      profileId: profileId,
      dueAt: dueAt,
      originalTimeZoneIdentifier: originalTimeZoneIdentifier,
      undoSendWindow: composePreferenceStore.preferences.undoSendWindow
    )
  }

  private var activeDraftProfileId: MailProfileId {
    profileViewModel.activeProfileId
      ?? MailProfileId.defaultProfile(productAccountId: snapshot.productAccountId)
  }

  private func saveCompositionDraft(
    _ draft: MailShellCompositionDraft,
    profileId: MailProfileId
  ) async throws {
    do {
      try await compositionDraftRepository.save(
        draft,
        productAccountId: snapshot.productAccountId,
        profileId: profileId,
        session: snapshot
      )
      await loadCompositionDrafts(profileId: profileId)
    } catch let conflict as MailCompositionDraftSaveConflict {
      await loadCompositionDrafts(profileId: profileId)
      throw conflict
    }
  }

  private func deleteCompositionDraft(
    _ draftId: UUID,
    profileId: MailProfileId
  ) async throws {
    try await compositionDraftRepository.remove(
      draftId,
      productAccountId: snapshot.productAccountId,
      profileId: profileId,
      session: snapshot
    )
    await loadCompositionDrafts(profileId: profileId)
  }

  private func loadCompositionDrafts(profileId: MailProfileId) async {
    guard
      let load = compositionDraftLoadGate.begin(
        profileId: profileId,
        activeProfileId: activeDraftProfileId
      )
    else { return }
    if load.clearsExistingDrafts {
      savedCompositionDrafts = []
    }
    do {
      let claimsNotificationOwnership =
        await sendReminderNotificationAuthorizationState() == .authorized
      let drafts = try await compositionDraftRepository.drafts(
        productAccountId: snapshot.productAccountId,
        profileId: profileId,
        session: snapshot,
        claimsNotificationOwnership: claimsNotificationOwnership
      )
      guard load.generation == compositionDraftLoadGate.generation,
        profileId == activeDraftProfileId
      else { return }
      cancelConflictSourceReminders(in: drafts, profileId: profileId)
      savedCompositionDrafts = drafts
      await reconcileSendReminders(drafts, profileId: profileId)
    } catch {
      guard load.generation == compositionDraftLoadGate.generation,
        profileId == activeDraftProfileId
      else { return }
      savedCompositionDrafts = []
      profileViewModel.show(error)
    }
  }

  private func synchronizeShareExtensionCatalog() async {
    guard let shareExtensionCatalogSynchronizer,
      let profileSnapshot = profileViewModel.profileSnapshot
    else { return }
    do {
      try await shareExtensionCatalogSynchronizer.synchronize(
        session: snapshot,
        profileSnapshot: profileSnapshot,
        startupProfileId: profileViewModel.startupProfileId
      )
    } catch is CancellationError {
    } catch {
      profileViewModel.show(error)
    }
  }

  private func importShareExtensionDrafts() async {
    guard let shareExtensionDraftImporter else { return }
    do {
      _ = try await shareExtensionDraftImporter.importPendingDrafts(session: snapshot)
    } catch is CancellationError {
    } catch {
      profileViewModel.show(error)
    }
  }

  private func openSavedDraft(_ draftId: UUID?) {
    guard let draftId,
      let draft = savedCompositionDrafts.first(where: { $0.id == draftId })
    else { return }
    presentComposerDraft(draft)
  }

  private func handleProfileDeepLink(
    profileId: MailProfileId,
    draftId: UUID?
  ) async {
    await importShareExtensionDrafts()
    guard await switchProfileAndWait(to: profileId) else { return }
    await loadCompositionDrafts(profileId: profileId)
    openSavedDraft(draftId)
  }

  private func scheduleSendReminder(
    for draft: MailShellCompositionDraft,
    profileId: MailProfileId
  ) async throws -> SendReminderNotificationOutcome {
    guard let reminder = draft.sendReminder else { return .unavailable }
    guard reminder.isSynchronizationPending == false,
      reminder.notificationOwnerDeviceId == snapshot.trustedDeviceId,
      sendReminderInterruptionPolicy(for: reminder).allowsInterruption
    else {
      cancelSendReminder(reminder, draftId: draft.id, profileId: profileId)
      return .unavailable
    }
    return try await sendReminderNotificationScheduler.scheduleSendReminder(
      reminder,
      draftId: draft.id,
      productAccountId: snapshot.productAccountId,
      profileId: profileId
    )
  }

  private func cancelSendReminder(
    _ reminder: SendReminder,
    draftId: UUID,
    profileId: MailProfileId
  ) {
    sendReminderNotificationScheduler.cancelSendReminder(
      reminder,
      draftId: draftId,
      productAccountId: snapshot.productAccountId,
      profileId: profileId
    )
  }

  private func reconcileSendReminders(
    _ drafts: [MailShellCompositionDraft],
    profileId: MailProfileId
  ) async {
    for draft in drafts {
      guard let reminder = draft.sendReminder else { continue }
      if reminder.notificationOwnerDeviceId == snapshot.trustedDeviceId {
        _ = try? await scheduleSendReminder(for: draft, profileId: profileId)
      } else {
        cancelSendReminder(reminder, draftId: draft.id, profileId: profileId)
      }
    }
  }

  private func cancelConflictSourceReminders(
    in drafts: [MailShellCompositionDraft],
    profileId: MailProfileId
  ) {
    for draft in drafts {
      guard let sourceId = draft.conflictSourceId, let reminder = draft.sendReminder else {
        continue
      }
      cancelSendReminder(reminder, draftId: sourceId, profileId: profileId)
    }
  }

  private func sendReminderNotificationAuthorizationState() async
    -> NotificationAuthorizationState
  {
    guard
      let authorization =
        sendReminderNotificationScheduler as? any NotificationAuthorizationStateChecking
    else { return .denied }
    return await authorization.notificationAuthorizationState()
  }

  private func sendReminderInterruptionPolicy(
    for reminder: SendReminder
  ) -> SendReminderInterruptionPolicy {
    let preferences = notificationPreferenceStore.load(
      productAccountId: snapshot.productAccountId
    )
    return SendReminderInterruptionPolicy(
      isDeviceQuietAtDueTime: preferences.quietSchedule.isQuiet(at: reminder.dueAt),
      isProfileLocked: !profileInterruptionViewModel.policy.allowsContentReveal,
      isProfileQuietAtDueTime:
        profileInterruptionViewModel.activeProfile.quietState.isActive(at: reminder.dueAt),
      returnToAttentionEnabled: snoozeViewModel.preferences.returnToAttentionEnabled
    )
  }

  private func openCompositionDraft(_ draft: MailShellCompositionDraft) {
    guard let reminder = draft.sendReminder, reminder.isOverdue() else {
      presentComposerDraft(draft)
      return
    }
    let profileId = activeDraftProfileId
    Task {
      var candidate = draft
      candidate.sendReminder = nil
      candidate.markEdited()
      do {
        try await saveCompositionDraft(candidate, profileId: profileId)
        guard
          compositionDraftCanBePresented(
            originatingProfileId: profileId,
            activeProfileId: profileViewModel.activeProfileId
          )
        else { return }
        cancelSendReminder(reminder, draftId: draft.id, profileId: profileId)
        presentComposerDraft(candidate)
      } catch {
        profileViewModel.show(error)
      }
    }
  }

  private func selectConnection(
    _ connection: MailboxConnection,
    collection: MailboxMessageCollection = .role(.inbox),
    synchronizes: Bool = true,
    revalidatesTrustedDevice: Bool = false
  ) {
    gmailViewModel.selectedConnectionId = connection.id
    microsoftGraphViewModel.selectedConnectionId = connection.id
    inboxViewModel.clear()
    mailShellSelection.selectMailbox(connectionId: connection.id, collection: collection)
    guard connection.authorizationState == .authorized else { return }
    loadMailbox(
      for: connection,
      synchronizes: synchronizes,
      revalidatesTrustedDevice: revalidatesTrustedDevice
    )
  }

  private func selectSearchResult(_ message: MailboxMessageMetadata) {
    if mailShellSelection.selectedMailbox?.isUnified != true,
      let connection = profileConnections.first(where: { $0.id == message.connectionId }),
      gmailViewModel.selectedConnectionId != connection.id
    {
      selectConnection(connection)
    }
    mailShellSelection.selectSearchResult(message)
  }
}

@MainActor
final class MailProfileSwitchGate {
  private var generation = 0

  func begin() -> Int {
    generation &+= 1
    return generation
  }

  func isCurrent(_ generation: Int) -> Bool {
    self.generation == generation
  }

  func performIfCurrent<Result>(
    _ generation: Int,
    _ operation: () -> Result
  ) -> Result? {
    guard isCurrent(generation) else { return nil }
    return operation()
  }
}

struct MailCompositionDraftLoadGate {
  private(set) var generation = 0
  private var profileId: MailProfileId?

  mutating func begin(
    profileId: MailProfileId,
    activeProfileId: MailProfileId
  ) -> (generation: Int, clearsExistingDrafts: Bool)? {
    guard profileId == activeProfileId else { return nil }
    generation &+= 1
    let clearsExistingDrafts = self.profileId != profileId
    self.profileId = profileId
    return (generation, clearsExistingDrafts)
  }
}

extension AccountView {
  private var selectedMailboxBinding: Binding<MailShellMailboxSelection?> {
    Binding(
      get: { mailShellSelection.selectedMailbox },
      set: { mailbox in
        guard let mailbox else {
          mailShellSelection.clearSelection()
          gmailViewModel.selectedConnectionId = nil
          return
        }
        if case .unified(let unifiedMailbox) = mailbox {
          inboxViewModel.clear()
          mailShellSelection.replaceUnifiedThreads([], connectionIds: [])
          mailShellSelection.selectUnifiedMailbox(unifiedMailbox)
          loadUnifiedMailbox(revalidatesTrustedDevice: true)
          return
        }
        if mailbox == .outbox {
          inboxViewModel.clear()
          mailShellSelection.selectOutbox()
          return
        }
        guard case .connection(let connectionId, let collection) = mailbox else { return }
        guard
          profileConnections.contains(where: { $0.id == connectionId })
        else { return }
        let isCurrentConnection = gmailViewModel.selectedConnectionId == connectionId
        if !isCurrentConnection {
          mailShellSelection.selectMailbox(connectionId: connectionId, collection: collection)
        }
        gmailViewModel.selectedConnectionId = connectionId
        if !isCurrentConnection {
          guard
            !mailboxObserversAreActive,
            let connection = gmailViewModel.connection,
            connection.id == connectionId
          else { return }
          selectConnection(
            connection,
            collection: collection,
            synchronizes: false,
            revalidatesTrustedDevice: true
          )
          return
        }
        guard let connection = gmailViewModel.connection,
          connection.id == connectionId
        else { return }
        mailShellSelection.selectMailbox(connectionId: connectionId, collection: collection)
        inboxViewModel.clear()
        guard connection.authorizationState == .authorized else { return }
        loadMailbox(for: connection, revalidatesTrustedDevice: true)
      }
    )
  }

}

enum GmailSearchSource: Equatable {
  case localMetadata
  case providerFullText

  func title(providerDisplayName: String) -> String {
    switch self {
    case .localMetadata:
      return "Local Metadata"
    case .providerFullText:
      return "\(providerDisplayName) Full Text"
    }
  }
}

struct GmailSearchResult: Equatable {
  let messages: [MailboxMessageMetadata]
  let source: GmailSearchSource
}

enum MailShellNavigationLevel: Equatable {
  case mailboxList
  case threadList
  case conversation
}

enum MailShellOutboxState: Hashable {
  case pending
  case retrying
  case failed
  case sent
}

struct MailShellProductMailboxState: Equatable {
  let outboxStates: [MailShellOutboxState]
  let pinnedThreadIds: Set<StableThreadIdentity>
  let snoozedThreadIds: Set<StableThreadIdentity>

  static let empty = MailShellProductMailboxState(
    outboxStates: [],
    pinnedThreadIds: [],
    snoozedThreadIds: []
  )
}

struct MailboxNavigationSnapshot: Equatable {
  let messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]]
  let pinnedThreadIds: Set<StableThreadIdentity>
  let snoozedThreadIds: Set<StableThreadIdentity>
  let outboxStates: [MailShellOutboxState]
  let providerMailboxesByConnection: [MailboxConnectionId: [ProviderMailbox]]

  init(
    messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]],
    pinnedThreadIds: Set<StableThreadIdentity>,
    snoozedThreadIds: Set<StableThreadIdentity>,
    outboxStates: [MailShellOutboxState],
    providerMailboxesByConnection: [MailboxConnectionId: [ProviderMailbox]] = [:]
  ) {
    self.messagesByConnection = messagesByConnection
    self.outboxStates = outboxStates
    self.pinnedThreadIds = pinnedThreadIds
    self.snoozedThreadIds = snoozedThreadIds
    self.providerMailboxesByConnection = providerMailboxesByConnection
  }

  var outboxItemCount: Int {
    outboxStates.count { $0 != .sent }
  }

  var showsOutbox: Bool {
    outboxItemCount > 0
  }

  /// Returns the cached thread matching `identity`, regardless of the selected mailbox.
  func thread(_ identity: StableThreadIdentity) -> MailboxThread? {
    let messages = messagesByConnection[identity.connectionId, default: []]
      .filter { $0.threadIdentity == identity }
    return MailboxThread.group(messages).first
  }

  func count(for mailbox: UnifiedMailbox) -> MailboxItemCount {
    count(for: mailbox.collection, in: nil)
  }

  func count(
    for collection: MailboxMessageCollection,
    in connectionId: MailboxConnectionId
  ) -> MailboxItemCount {
    count(for: collection, in: Optional(connectionId))
  }

  private func count(
    for collection: MailboxMessageCollection,
    in connectionId: MailboxConnectionId?
  ) -> MailboxItemCount {
    let sourceMessages =
      if let connectionId {
        messagesByConnection[connectionId] ?? []
      } else {
        messagesByConnection.values.flatMap { $0 }
      }
    let messages = sourceMessages.filter {
      collection.contains(
        providerStateIds: $0.providerStateIds,
        isPinned: pinnedThreadIds.contains($0.threadIdentity),
        isSnoozed: snoozedThreadIds.contains($0.threadIdentity)
      )
    }
    if collection == .pins || collection == .snoozed {
      let threads = MailboxThread.group(messages)
      return MailboxItemCount(
        itemCount: threads.count,
        unreadCount: threads.count { thread in
          thread.messages.contains { $0.providerStateIds?.contains("UNREAD") == true }
        }
      )
    }
    return MailboxItemCount(
      itemCount: messages.count,
      unreadCount: messages.count { $0.providerStateIds?.contains("UNREAD") == true }
    )
  }

  func providerMailboxes(for connectionId: MailboxConnectionId) -> [ProviderMailbox] {
    var mailboxesById = Dictionary(
      uniqueKeysWithValues: (providerMailboxesByConnection[connectionId] ?? []).map {
        ($0.id, $0)
      }
    )
    for id in MailboxMessageCollection.providerMailboxIds(
      in: messagesByConnection[connectionId] ?? []
    ) where mailboxesById[id] == nil {
      mailboxesById[id] = ProviderMailbox(id: id, title: id)
    }
    return mailboxesById.values.sorted {
      $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
  }

  func providerMailboxIds(for connectionId: MailboxConnectionId) -> [String] {
    providerMailboxes(for: connectionId).map(\.id)
  }

  static let empty = MailboxNavigationSnapshot(
    messagesByConnection: [:],
    pinnedThreadIds: [],
    snoozedThreadIds: [],
    outboxStates: []
  )
}

enum MailShellMailboxSelection: Hashable {
  case unified(UnifiedMailbox)
  case connection(MailboxConnectionId, MailboxMessageCollection)
  case outbox

  var collection: MailboxMessageCollection? {
    switch self {
    case .unified(let mailbox):
      return mailbox.collection
    case .connection(_, let collection):
      return collection
    case .outbox:
      return nil
    }
  }

  var isUnified: Bool {
    if case .unified = self {
      return true
    }
    return false
  }

  var supportsCategoryMailViews: Bool {
    switch self {
    case .outbox, .unified(.drafts), .connection(_, .role(.drafts)):
      return false
    case .connection, .unified:
      return true
    }
  }
}

extension UnifiedMailbox {
  var systemImage: String {
    switch self {
    case .inbox:
      return "tray.2"
    case .snoozed:
      return "clock.arrow.circlepath"
    case .pins:
      return "pin"
    case .drafts:
      return "doc"
    case .sent:
      return "paperplane"
    case .archive:
      return "archivebox"
    case .allMail:
      return "tray.full"
    case .spam:
      return "exclamationmark.octagon"
    case .trash:
      return "trash"
    }
  }

  var title: String {
    switch self {
    case .inbox:
      return "Inbox"
    case .snoozed:
      return "Snoozed"
    case .pins:
      return "Pins"
    case .drafts:
      return "Drafts"
    case .sent:
      return "Sent"
    case .archive:
      return "Archive"
    case .allMail:
      return "All Mail"
    case .spam:
      return "Spam"
    case .trash:
      return "Trash"
    }
  }
}

struct MailShellThreadListItem: Equatable, Identifiable {
  let sourceConnectionDisplayName: String
  let thread: MailboxThread

  var id: MailboxThreadIdentity {
    thread.id
  }
}

struct MailViewPresentation: Equatable, Identifiable {
  let selection: MailViewSelection
  let systemImage: String
  let title: String
  let unreadThreadCount: Int

  var id: String { selection.id }

  var badge: String? {
    guard unreadThreadCount > 0 else { return nil }
    return unreadThreadCount > 99 ? "99+" : String(unreadThreadCount)
  }

}

enum MailViewFilter {
  static func threads(
    _ threads: [MailboxThread],
    matching selection: MailViewSelection,
    configuration: MailViewConfiguration
  ) -> [MailboxThread] {
    threads.filter { matches($0, selection: selection, configuration: configuration) }
  }

  static func unreadThreadCount(
    in threads: [MailboxThread],
    matching selection: MailViewSelection,
    configuration: MailViewConfiguration
  ) -> Int {
    threads.count { thread in
      isUnread(thread)
        && matches(thread, selection: selection, configuration: configuration)
    }
  }

  static func isUnread(_ thread: MailboxThread) -> Bool {
    thread.messages.contains(where: \.isUnread)
  }

  private static func matches(
    _ thread: MailboxThread,
    selection: MailViewSelection,
    configuration: MailViewConfiguration
  ) -> Bool {
    switch selection {
    case .all:
      return true
    case .category(let categoryId):
      return thread.messages.contains { $0.messageCategoryIds.contains(categoryId) }
    case .important:
      let categoryIds = Set(configuration.importantCategoryIds)
      return thread.messages.contains {
        $0.messageCategoryIds.contains(where: categoryIds.contains)
      }
    }
  }
}

struct MailboxBulkActionBatch: Equatable, Sendable {
  let connection: MailboxConnection
  let messages: [MailboxMessageMetadata]
  let sourceProviderMailboxId: String?
  let targetProviderMailboxId: String?
  let targetProviderStateIds: Set<String>

  init(
    connection: MailboxConnection,
    messages: [MailboxMessageMetadata],
    sourceProviderMailboxId: String? = nil,
    targetProviderMailboxId: String? = nil,
    targetProviderStateIds: Set<String> = []
  ) {
    self.connection = connection
    self.messages = messages
    self.sourceProviderMailboxId = sourceProviderMailboxId
    self.targetProviderMailboxId = targetProviderMailboxId
    self.targetProviderStateIds = targetProviderStateIds
  }
}

struct MailboxBulkMoveDestination: Equatable, Identifiable, Sendable {
  struct Identity: Equatable, Hashable, Sendable {
    let normalizedTitle: String
  }

  let id: Identity
  let providerMailboxIdsByConnection: [MailboxConnectionId: String]
  let providerStateIdsByConnection: [MailboxConnectionId: Set<String>]
  let title: String

  static func shared(
    connectionIds: [MailboxConnectionId],
    providerMailboxesByConnection: [MailboxConnectionId: [ProviderMailbox]]
  ) -> [MailboxBulkMoveDestination] {
    let mailboxesByConnection = Dictionary(
      uniqueKeysWithValues: connectionIds.map { connectionId in
        (
          connectionId,
          uniqueMailboxesByTitle(providerMailboxesByConnection[connectionId] ?? [])
        )
      }
    )
    guard
      let firstConnectionId = connectionIds.first,
      let firstMailboxes = mailboxesByConnection[firstConnectionId]
    else { return [] }
    let commonIds = connectionIds.dropFirst().reduce(Set(firstMailboxes.keys)) {
      $0.intersection(Set(mailboxesByConnection[$1]?.keys.map { $0 } ?? []))
    }
    return commonIds.compactMap { id in
      guard let firstMailbox = firstMailboxes[id] else { return nil }
      let providerIds = Dictionary(
        uniqueKeysWithValues: connectionIds.compactMap { connectionId in
          mailboxesByConnection[connectionId]?[id].map { (connectionId, $0.id) }
        }
      )
      guard providerIds.count == connectionIds.count else { return nil }
      return MailboxBulkMoveDestination(
        id: id,
        providerMailboxIdsByConnection: providerIds,
        providerStateIdsByConnection: Dictionary(
          uniqueKeysWithValues: connectionIds.compactMap { connectionId in
            mailboxesByConnection[connectionId]?[id].map {
              (connectionId, $0.providerStateIds)
            }
          }
        ),
        title: firstMailbox.title
      )
    }
    .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  func targeting(_ batches: [MailboxBulkActionBatch]) -> [MailboxBulkActionBatch]? {
    guard Set(batches.map(\.connection.id)) == Set(providerMailboxIdsByConnection.keys) else {
      return nil
    }
    var targetedBatches: [MailboxBulkActionBatch] = []
    for batch in batches {
      guard let providerMailboxId = providerMailboxIdsByConnection[batch.connection.id] else {
        return nil
      }
      targetedBatches.append(
        MailboxBulkActionBatch(
          connection: batch.connection,
          messages: batch.messages,
          sourceProviderMailboxId: batch.sourceProviderMailboxId,
          targetProviderMailboxId: providerMailboxId,
          targetProviderStateIds: providerStateIdsByConnection[batch.connection.id] ?? []
        )
      )
    }
    return targetedBatches
  }

  private static func uniqueMailboxesByTitle(
    _ mailboxes: [ProviderMailbox]
  ) -> [Identity: ProviderMailbox] {
    Dictionary(
      uniqueKeysWithValues: Dictionary(grouping: mailboxes) {
        Identity(normalizedTitle: $0.title.lowercased())
      }.compactMap { id, matches in
        matches.count == 1 ? (id, matches[0]) : nil
      }
    )
  }
}

struct MailboxBulkActionFailure: Equatable, Sendable {
  let connectionId: MailboxConnectionId
  let connectionDisplayName: String
  let description: String
  let messageIds: [StableProviderMessageIdentity]
  let messageCount: Int
  let messageSubjects: [String]
}

struct MailboxBulkActionResult: Equatable, Sendable {
  let deferredConnectionIds: Set<MailboxConnectionId>
  let failures: [MailboxBulkActionFailure]
  let succeededConnectionIds: [MailboxConnectionId]

  func shouldReloadImmediately(_ connectionId: MailboxConnectionId) -> Bool {
    !deferredConnectionIds.contains(connectionId)
  }
}

struct MailboxBulkActionProgress: Equatable, Sendable {
  let action: ProviderMailAction
  let completedConnectionCount: Int
  let totalConnectionCount: Int
}

private struct MailboxBulkActionBatchOutcome: Sendable {
  let batchIndex: Int
  let connection: MailboxConnection
  let deferredPendingAction: Bool
  let errorDescription: String?
  let failureDetails: [MailboxProviderActionFailureDetail]?
  let messages: [MailboxMessageMetadata]
  let selection: MailboxProviderActionSelection?
  let wasEnqueued: Bool
}

private struct MailboxTrackedBulkActionBatch: Sendable {
  let batch: MailboxBulkActionBatch
  let selection: MailboxProviderActionSelection?
}

private enum UnifiedMailboxPhaseResult: Sendable {
  case cancelled
  case failure(String)
  case success(MailboxMetadataSyncResult, needsBackfill: Bool)

  var errorDescription: String? {
    guard case .failure(let description) = self else { return nil }
    return description
  }

  var isCancelled: Bool {
    if case .cancelled = self { return true }
    return false
  }

  var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }

  var needsBackfill: Bool {
    guard case .success(_, let needsBackfill) = self else { return false }
    return needsBackfill
  }

  var result: MailboxMetadataSyncResult? {
    guard case .success(let result, _) = self else { return nil }
    return result
  }
}

private enum UnifiedMailboxPhase: Sendable {
  case cache
  case sync
  case backfill
}

private struct UnifiedMailboxPhaseOutcome: Sendable {
  let connectionIndex: Int
  let connection: MailboxConnection
  let phaseResult: UnifiedMailboxPhaseResult
}

struct MailShellMessageScrollTarget: Equatable {
  let messageId: StableProviderMessageIdentity
  let requestId = UUID()
}

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class MailShellSelectionModel {
  private(set) var selectedMailView: MailViewSelection
  private(set) var selectedMailbox: MailShellMailboxSelection? = .unified(.inbox)
  private(set) var selectedMessageScrollTarget: MailShellMessageScrollTarget?
  private(set) var selectedThreadIds: Set<MailboxThreadIdentity> = []
  private let initialMailView: MailViewSelection
  private var retainedSearchResultThread: MailboxThread?
  private var mailViewConfiguration = MailViewConfiguration.defaults
  private var retainedThreadMailView: MailViewSelection
  private var threadsByConnection: [MailboxConnectionId: [MailboxThread]] = [:]

  init(initialMailView: MailViewSelection = .all) {
    self.initialMailView = initialMailView
    selectedMailView = initialMailView
    retainedThreadMailView = initialMailView
  }

  var selectedThreadId: MailboxThreadIdentity? {
    selectedThreadIds.count == 1 ? selectedThreadIds.first : nil
  }

  var selectedConnectionId: MailboxConnectionId? {
    guard case .connection(let connectionId, _) = selectedMailbox else { return nil }
    return connectionId
  }

  var threads: [MailboxThread] {
    let mailboxThreads = rawThreads
    guard selectedMailbox?.supportsCategoryMailViews == true else { return mailboxThreads }
    var visibleThreads = MailViewFilter.threads(
      mailboxThreads,
      matching: selectedMailView,
      configuration: mailViewConfiguration
    )
    guard let retainedSearchResultThread,
      selectedThreadIds.contains(retainedSearchResultThread.id),
      let retainedThread = mailboxThreads.first(where: { $0.id == retainedSearchResultThread.id }),
      !visibleThreads.contains(where: { $0.id == retainedThread.id })
    else { return visibleThreads }
    visibleThreads.append(retainedThread)
    return visibleThreads.sorted(by: Self.ordersBefore)
  }

  private var rawThreads: [MailboxThread] {
    switch selectedMailbox {
    case .unified:
      return threadsByConnection.values.flatMap { $0 }.sorted(by: Self.ordersBefore)
    case .connection(let connectionId, _):
      return threadsByConnection[connectionId] ?? []
    case .outbox:
      return []
    case nil:
      return []
    }
  }

  var navigationLevel: MailShellNavigationLevel {
    if !selectedThreadIds.isEmpty {
      return .conversation
    }
    if selectedMailbox != nil {
      return .threadList
    }
    return .mailboxList
  }

  var preferredCompactColumn: NavigationSplitViewColumn {
    compactColumn(isEditing: false)
  }

  func compactColumn(isEditing: Bool) -> NavigationSplitViewColumn {
    if isEditing, selectedMailbox != nil {
      return .content
    }
    switch navigationLevel {
    case .mailboxList:
      return .sidebar
    case .threadList:
      return .content
    case .conversation:
      return .detail
    }
  }

  var selectedThread: MailboxThread? {
    guard selectedThreadIds.count == 1 else { return nil }
    return threads.first { $0.id == selectedThreadId }
  }

  var selectedThreads: [MailboxThread] {
    threads.filter { selectedThreadIds.contains($0.id) }
  }

  var partialSearchResultThreadId: MailboxThreadIdentity? {
    guard let retainedSearchResultThread,
      let selectedThread = threadsByConnection[retainedSearchResultThread.id.connectionId]?
        .first(where: { $0.id == retainedSearchResultThread.id })
    else { return nil }
    let selectedMessageIds = Set(selectedThread.messages.map(\.id))
    let retainedMessageIds = Set(retainedSearchResultThread.messages.map(\.id))
    guard selectedMessageIds == retainedMessageIds else { return nil }
    return retainedSearchResultThread.id
  }

  func clearSelection() {
    selectedMailbox = nil
    selectedMessageScrollTarget = nil
    selectedThreadIds = []
    retainedSearchResultThread = nil
    threadsByConnection = [:]
    selectedMailView = initialMailView
    retainedThreadMailView = initialMailView
  }

  func clearThreadSelection() {
    if selectedMessageScrollTarget != nil {
      selectedMessageScrollTarget = nil
    }
    if !selectedThreadIds.isEmpty {
      selectedThreadIds = []
    }
    if retainedSearchResultThread != nil {
      retainedSearchResultThread = nil
    }
  }

  func selectMailbox(
    connectionId: MailboxConnectionId,
    collection: MailboxMessageCollection = .role(.inbox)
  ) {
    let mailbox = MailShellMailboxSelection.connection(connectionId, collection)
    guard selectedMailbox != mailbox else { return }
    prepareMailView(for: mailbox)
    selectedMailbox = mailbox
    selectedMessageScrollTarget = nil
    selectedThreadIds = []
    retainedSearchResultThread = nil
  }

  func selectUnifiedInbox() {
    selectUnifiedMailbox(.inbox)
  }

  func selectUnifiedMailbox(_ mailbox: UnifiedMailbox) {
    let selection = MailShellMailboxSelection.unified(mailbox)
    guard selectedMailbox != selection else { return }
    prepareMailView(for: selection)
    selectedMailbox = selection
    selectedMessageScrollTarget = nil
    selectedThreadIds = []
    retainedSearchResultThread = nil
  }

  func selectOutbox() {
    guard selectedMailbox != .outbox else { return }
    prepareMailView(for: .outbox)
    selectedMailbox = .outbox
    selectedMessageScrollTarget = nil
    selectedThreadIds = []
    retainedSearchResultThread = nil
  }

  func selectThread(_ threadId: MailboxThreadIdentity) {
    guard threads.contains(where: { $0.id == threadId }) else { return }
    retainedSearchResultThread = nil
    selectedMessageScrollTarget = nil
    selectedThreadIds = [threadId]
  }

  func selectMailView(_ selection: MailViewSelection) {
    let resolvedSelection =
      if selectedMailbox?.supportsCategoryMailViews == true,
        mailViewConfiguration.contains(selection)
      {
        selection
      } else {
        MailViewSelection.all
      }
    guard selectedMailView != resolvedSelection else { return }
    selectedMailView = resolvedSelection
    if selectedMailbox?.supportsCategoryMailViews == true {
      retainedThreadMailView = resolvedSelection
    }
    reconcileSelectedThreads()
  }

  func updateMailViews(configuration: MailViewConfiguration) {
    mailViewConfiguration = configuration
    if !configuration.contains(retainedThreadMailView) {
      retainedThreadMailView = .all
    }
    guard selectedMailbox?.supportsCategoryMailViews == true else {
      selectedMailView = .all
      return
    }
    if !configuration.contains(selectedMailView) {
      selectedMailView = .all
      retainedThreadMailView = .all
    }
    reconcileSelectedThreads()
  }

  func mailViewPresentations(
    categoryChoices: [MessageCategoryChoice]
  ) -> [MailViewPresentation] {
    let mailboxThreads = rawThreads
    guard selectedMailbox?.supportsCategoryMailViews == true else {
      return []
    }
    let categoriesById = Dictionary(
      uniqueKeysWithValues: categoryChoices.map { ($0.id, $0) }
    )
    var presentations = [
      presentation(
        for: .important,
        title: "Important",
        systemImage: "bolt",
        threads: mailboxThreads
      ),
      presentation(
        for: .all,
        title: "All",
        systemImage: "tray.full",
        threads: mailboxThreads
      ),
    ]
    presentations += mailViewConfiguration.categorySlots.compactMap { categoryId in
      guard let categoryId, let category = categoriesById[categoryId] else { return nil }
      return presentation(
        for: .category(categoryId),
        title: category.name,
        systemImage: category.systemImage,
        threads: mailboxThreads
      )
    }
    return presentations
  }

  func selectThreads(_ threadIds: Set<MailboxThreadIdentity>) {
    if retainedSearchResultThread.map({ !threadIds.contains($0.id) }) == true {
      retainedSearchResultThread = nil
    }
    let availableThreadIds = Set(threads.map(\.id))
    selectedMessageScrollTarget = nil
    selectedThreadIds = threadIds.intersection(availableThreadIds)
    reconcileSelectedThreads()
  }

  func selectSearchResult(_ message: MailboxMessageMetadata) {
    if selectedMailbox?.isUnified != true {
      selectedMailbox = .connection(
        message.connectionId,
        selectedMailbox?.collection ?? .role(.inbox)
      )
    }
    let thread = MailboxThread.group([message])[0]
    var connectionThreads = threadsByConnection[message.connectionId] ?? []
    if let index = connectionThreads.firstIndex(where: { $0.id == thread.id }) {
      let messages = Dictionary(
        (connectionThreads[index].messages + [message]).map { ($0.id, $0) },
        uniquingKeysWith: { existing, _ in existing }
      ).values
      connectionThreads[index] = MailboxThread.group(Array(messages))[0]
    } else {
      connectionThreads.append(thread)
    }
    threadsByConnection[message.connectionId] = connectionThreads
    let retainedMessages = Dictionary(
      ((retainedSearchResultThread?.id == thread.id
        ? retainedSearchResultThread?.messages ?? [] : []) + [message]).map { ($0.id, $0) },
      uniquingKeysWith: { existing, _ in existing }
    ).values
    retainedSearchResultThread = MailboxThread.group(Array(retainedMessages))[0]
    selectedMessageScrollTarget = MailShellMessageScrollTarget(messageId: message.id)
    selectedThreadIds = [thread.id]
  }

  func clearMessageScrollTarget(_ target: MailShellMessageScrollTarget) {
    guard selectedMessageScrollTarget == target else { return }
    selectedMessageScrollTarget = nil
  }

  func scrollToMessage(_ messageId: StableProviderMessageIdentity) {
    guard selectedThread?.messages.contains(where: { $0.id == messageId }) == true else {
      return
    }
    selectedMessageScrollTarget = MailShellMessageScrollTarget(messageId: messageId)
  }

  func updateThreads(
    _ threads: [MailboxThread],
    for connectionId: MailboxConnectionId
  ) {
    var connectionThreads = threads.filter { $0.id.connectionId == connectionId }
    if let retainedSearchResultThread,
      retainedSearchResultThread.id.connectionId == connectionId,
      connectionThreads.contains(where: { $0.id == retainedSearchResultThread.id })
    {
      self.retainedSearchResultThread = nil
    }
    if let retainedSearchResultThread,
      retainedSearchResultThread.id.connectionId == connectionId,
      selectedThreadIds.contains(retainedSearchResultThread.id),
      !connectionThreads.contains(where: { $0.id == retainedSearchResultThread.id })
    {
      connectionThreads.append(retainedSearchResultThread)
    }
    threadsByConnection[connectionId] = connectionThreads
    guard selectedMailbox?.isUnified == true || selectedConnectionId == connectionId else {
      return
    }
    reconcileSelectedThreads()
  }

  func replaceUnifiedThreads(
    _ threads: [MailboxThread],
    connectionIds: Set<MailboxConnectionId>
  ) {
    var retainedThreads = threads.filter { connectionIds.contains($0.id.connectionId) }
    if let retainedSearchResultThread,
      retainedThreads.contains(where: { $0.id == retainedSearchResultThread.id })
    {
      self.retainedSearchResultThread = nil
    }
    if let retainedSearchResultThread,
      connectionIds.contains(retainedSearchResultThread.id.connectionId),
      selectedThreadIds.contains(retainedSearchResultThread.id),
      !retainedThreads.contains(where: { $0.id == retainedSearchResultThread.id })
    {
      retainedThreads.append(retainedSearchResultThread)
    }
    threadsByConnection = Dictionary(
      grouping: retainedThreads,
      by: { $0.id.connectionId }
    )
    reconcileSelectedThreads()
  }

  private func reconcileSelectedThreads() {
    guard !selectedThreadIds.isEmpty else { return }
    let availableThreadIds = Set(threads.map(\.id))
    selectedThreadIds.formIntersection(availableThreadIds)
  }

  private func prepareMailView(for mailbox: MailShellMailboxSelection) {
    if selectedMailbox?.supportsCategoryMailViews == true {
      retainedThreadMailView = selectedMailView
    }
    selectedMailView =
      if mailbox.supportsCategoryMailViews {
        mailViewConfiguration.contains(retainedThreadMailView)
          ? retainedThreadMailView : .all
      } else {
        .all
      }
  }

  private func presentation(
    for selection: MailViewSelection,
    title: String,
    systemImage: String,
    threads: [MailboxThread]
  ) -> MailViewPresentation {
    MailViewPresentation(
      selection: selection,
      systemImage: systemImage,
      title: title,
      unreadThreadCount: MailViewFilter.unreadThreadCount(
        in: threads,
        matching: selection,
        configuration: mailViewConfiguration
      )
    )
  }

  func threadListItems(connections: [MailboxConnection]) -> [MailShellThreadListItem] {
    let displayNamesByConnection = Dictionary(
      uniqueKeysWithValues: connections.map { ($0.id, $0.displayName) }
    )
    return threads.compactMap { thread in
      guard let sourceConnectionDisplayName = displayNamesByConnection[thread.id.connectionId]
      else { return nil }
      return MailShellThreadListItem(
        sourceConnectionDisplayName: sourceConnectionDisplayName,
        thread: thread
      )
    }
  }

  func selectedMailboxMessages(
    in thread: MailboxThread,
    pinnedThreadIds: Set<StableThreadIdentity>,
    snoozedThreadIds: Set<StableThreadIdentity> = []
  ) -> [MailboxMessageMetadata] {
    guard let collection = selectedMailbox?.collection else { return [] }
    return thread.messages.filter {
      collection.contains(
        providerStateIds: $0.providerStateIds,
        isPinned: pinnedThreadIds.contains($0.threadIdentity),
        isSnoozed: snoozedThreadIds.contains($0.threadIdentity)
      )
    }
  }

  func bulkProviderActions(
    connections: [MailboxConnection]
  ) -> Set<ProviderMailAction> {
    let selectedConnectionIds = Set(selectedThreadIds.map(\.connectionId))
    let selectedConnections = connections.filter { selectedConnectionIds.contains($0.id) }
    guard !selectedConnections.isEmpty,
      selectedConnections.count == selectedConnectionIds.count,
      let firstConnection = selectedConnections.first
    else { return [] }
    return selectedConnections.dropFirst().reduce(firstConnection.capabilities.providerActions) {
      $0.intersection($1.capabilities.providerActions)
    }
  }

  func bulkActionBatches(
    connections: [MailboxConnection],
    pinnedThreadIds: Set<StableThreadIdentity>,
    snoozedThreadIds: Set<StableThreadIdentity> = []
  ) -> [MailboxBulkActionBatch] {
    let connectionsById = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
    let selectedThreads = self.selectedThreads
    return Set(selectedThreads.map(\.id.connectionId))
      .sorted { $0.rawValue < $1.rawValue }
      .compactMap { connectionId in
        guard let connection = connectionsById[connectionId] else { return nil }
        var seenMessageIds: Set<StableProviderMessageIdentity> = []
        let messages =
          selectedThreads
          .filter { $0.id.connectionId == connectionId }
          .flatMap {
            selectedMailboxMessages(
              in: $0,
              pinnedThreadIds: pinnedThreadIds,
              snoozedThreadIds: snoozedThreadIds
            )
          }
          .filter { seenMessageIds.insert($0.id).inserted }
        guard !messages.isEmpty else { return nil }
        return MailboxBulkActionBatch(
          connection: connection,
          messages: messages,
          sourceProviderMailboxId: selectedMailbox?.collection?.providerMailboxMoveSourceId
        )
      }
  }

  private static func ordersBefore(_ lhs: MailboxThread, _ rhs: MailboxThread) -> Bool {
    let lhsDate = lhs.latestMessage.providerInternalDateMilliseconds
    let rhsDate = rhs.latestMessage.providerInternalDateMilliseconds
    if lhsDate != rhsDate {
      return lhsDate > rhsDate
    }
    if lhs.id.connectionId.rawValue != rhs.id.connectionId.rawValue {
      return lhs.id.connectionId.rawValue < rhs.id.connectionId.rawValue
    }
    return lhs.providerThreadId < rhs.providerThreadId
  }
}

extension UnifiedMailbox {
  /// Unified mailboxes shown before provider-specific Mailbox Connections.
  static let primarySidebarMailboxes: [Self] = [.inbox, .snoozed, .pins, .drafts, .sent]

  /// Lower-frequency Unified Mailboxes shown after the primary destinations.
  static let secondarySidebarMailboxes: [Self] = [.archive, .allMail, .spam, .trash]

  var showsSidebarMessageCount: Bool {
    self != .spam && self != .trash
  }
}

private struct MailShellSidebar: View {
  let beginComposition: () -> Void
  let canCompose: Bool
  let connections: [MailboxConnection]
  let profiles: [MailProfileDefinition]
  let activeProfileId: MailProfileId?
  let startupProfileId: MailProfileId?
  let selectProfile: (MailProfileId) -> Void
  let setStartupProfile: (MailProfileId) -> Void
  let errorMessage: String?
  let generalErrorMessage: String?
  let isLoading: Bool
  let navigationSnapshot: MailboxNavigationSnapshot
  let openSettings: (SettingsRoute) -> Void
  @Binding var selectedMailbox: MailShellMailboxSelection?
  let showSearch: () -> Void
  let showSettings: () -> Void
  let syncStatus: (MailboxConnection) -> MailboxSyncStatus

  var body: some View {
    VStack(spacing: 0) {
      List(selection: $selectedMailbox) {
        if let activeProfile {
          Section {
            Menu {
              ForEach(profiles) { profile in
                Button {
                  selectProfile(profile.id)
                } label: {
                  Label(
                    profile.name,
                    systemImage: profile.id == activeProfileId
                      ? "checkmark.circle.fill" : profile.appearance.symbolName
                  )
                }
                .accessibilityLabel(
                  "\(profile.name), \(profile.appearance.accessibilityDescription)"
                )
              }
              Divider()
              Button {
                setStartupProfile(activeProfile.id)
              } label: {
                Label(
                  activeProfile.id == startupProfileId
                    ? "Startup Profile" : "Use for New Windows",
                  systemImage: activeProfile.id == startupProfileId
                    ? "checkmark" : "macwindow.badge.plus"
                )
              }
              .disabled(activeProfile.id == startupProfileId)
            } label: {
              MailProfileSwitcherLabel(profile: activeProfile)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Mail Profile, \(activeProfile.name)")
            .accessibilityHint("Choose a Mail Profile")
            .accessibilityIdentifier("mail-profile-switcher")
            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
          }
        }

        Section {
          Button(action: showSearch) {
            Label("Search", systemImage: "magnifyingglass")
          }
          .accessibilityIdentifier("mail-search")

          Button(action: beginComposition) {
            Label("New Message", systemImage: "square.and.pencil")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(!canCompose)
          .accessibilityIdentifier("mail-compose-sidebar")
        }

        Section("Mailboxes") {
          ForEach(UnifiedMailbox.primarySidebarMailboxes, id: \.self) { mailbox in
            MailShellUnifiedMailboxLink(
              mailbox: mailbox,
              navigationSnapshot: navigationSnapshot
            )
          }
          if navigationSnapshot.showsOutbox {
            NavigationLink(value: MailShellMailboxSelection.outbox) {
              MailShellMailboxLabel(
                count: MailboxItemCount(
                  itemCount: navigationSnapshot.outboxItemCount,
                  unreadCount: 0
                ),
                systemImage: "paperplane.circle",
                title: "Outbox"
              )
            }
            .accessibilityIdentifier("mail-mailbox-outbox")
          }
        }

        Section("More Mailboxes") {
          ForEach(UnifiedMailbox.secondarySidebarMailboxes, id: \.self) { mailbox in
            MailShellUnifiedMailboxLink(
              mailbox: mailbox,
              navigationSnapshot: navigationSnapshot
            )
          }
        }

        if connections.isEmpty {
          Section("Mailbox Connections") {
            if isLoading {
              ProgressView("Loading mailboxes...")
            } else if let errorMessage {
              ContentUnavailableView(
                "Mailboxes unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
              )
            } else {
              Text("No Mailbox Connections")
                .foregroundStyle(.secondary)
            }
          }
        } else {
          Section("Mailbox Connections") {
            ForEach(connections) { connection in
              MailShellConnectionDisclosure(
                connection: connection,
                navigationSnapshot: navigationSnapshot,
                openSettings: openSettings,
                status: syncStatus(connection)
              )
            }
          }
        }

        if let generalErrorMessage {
          Section {
            Label(generalErrorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
      }
      .mailShellTopScrollEdgeEffectHidden()
      .scrollContentBackground(.hidden)

      Divider()
      Button(action: showSettings) {
        Label("Settings", systemImage: "gearshape")
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .accessibilityIdentifier("mail-settings")
    }
    .background(MailTheme.sidebar)
    .navigationTitle(activeProfile?.name ?? "Unwired Mail")
  }

  private var activeProfile: MailProfileDefinition? {
    profiles.first { $0.id == activeProfileId }
  }
}

private struct MailShellUnifiedMailboxLink: View {
  let mailbox: UnifiedMailbox
  let navigationSnapshot: MailboxNavigationSnapshot

  var body: some View {
    NavigationLink(value: MailShellMailboxSelection.unified(mailbox)) {
      MailShellMailboxLabel(
        count: mailbox.showsSidebarMessageCount
          ? navigationSnapshot.count(for: mailbox) : nil,
        systemImage: mailbox.systemImage,
        title: mailbox.title
      )
    }
    .accessibilityIdentifier(accessibilityIdentifier)
  }

  private var accessibilityIdentifier: String {
    switch mailbox {
    case .inbox:
      return "mail-mailbox-inbox"
    case .snoozed:
      return "mail-mailbox-snoozed"
    case .pins:
      return "mail-mailbox-pins"
    case .drafts:
      return "mail-mailbox-drafts"
    case .sent:
      return "mail-mailbox-sent"
    case .archive:
      return "mail-mailbox-archive"
    case .allMail:
      return "mail-mailbox-all"
    case .spam:
      return "mail-mailbox-spam"
    case .trash:
      return "mail-mailbox-trash"
    }
  }
}

private struct MailShellConnectionDisclosure: View {
  let connection: MailboxConnection
  let navigationSnapshot: MailboxNavigationSnapshot
  let openSettings: (SettingsRoute) -> Void
  let status: MailboxSyncStatus

  var body: some View {
    DisclosureGroup {
      NavigationLink(
        value: MailShellMailboxSelection.connection(
          connection.id,
          .role(.inbox)
        )
      ) {
        MailShellMailboxLabel(
          count: navigationSnapshot.count(for: .role(.inbox), in: connection.id),
          systemImage: connection.authorizationState == .authorized
            ? "tray.full" : "lock.trianglebadge.exclamationmark",
          title: "Inbox"
        )
      }
      ForEach(
        navigationSnapshot.providerMailboxes(for: connection.id),
        id: \.id
      ) { providerMailbox in
        NavigationLink(
          value: MailShellMailboxSelection.connection(
            connection.id,
            .providerMailbox(providerMailbox.id)
          )
        ) {
          MailShellMailboxLabel(
            count: navigationSnapshot.count(
              for: .providerMailbox(providerMailbox.id),
              in: connection.id
            ),
            systemImage: "tag",
            title: providerMailbox.title
          )
        }
      }
      if let route = MailboxStatusSettingsLink.route(
        for: status,
        connectionId: connection.id
      ) {
        Button(
          status.phase == .authorizationRequired ? "Fix Authorization" : "Review Sync Settings"
        ) {
          openSettings(route)
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(statusColor)
      }
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Text(connection.displayName)
          .font(.headline)
        if status.phase != .idle {
          Label(status.summary, systemImage: statusSystemImage)
            .font(.caption)
            .foregroundStyle(statusColor)
            .lineLimit(2)
        }
      }
    }
  }

  private var statusColor: Color {
    switch status.phase {
    case .authorizationRequired, .backfillPending, .offline:
      return .orange
    case .failed:
      return .red
    case .idle, .syncing:
      return .secondary
    }
  }

  private var statusSystemImage: String {
    switch status.phase {
    case .authorizationRequired:
      return "lock.trianglebadge.exclamationmark"
    case .backfillPending, .syncing:
      return "arrow.clockwise"
    case .failed:
      return "exclamationmark.triangle"
    case .offline:
      return "wifi.slash"
    case .idle:
      return "checkmark"
    }
  }
}

private struct MailProfileSwitcherLabel: View {
  @Environment(\.colorScheme) private var colorScheme
  let profile: MailProfileDefinition

  var body: some View {
    HStack(spacing: 10) {
      Text(profileInitial)
        .font(.headline.weight(.semibold))
        .foregroundStyle(.primary)
        .frame(width: 36, height: 36)
        .background(profileColor.opacity(avatarOpacity), in: Circle())
        .accessibilityHidden(true)

      Text(profile.name)
        .font(.headline)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 8)

      Image(systemName: "chevron.down")
        .font(.caption2.weight(.bold))
        .foregroundStyle(Color.primary.opacity(0.62))
        .accessibilityHidden(true)
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    .background(
      profileColor.opacity(surfaceOpacity),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(profileColor.opacity(borderOpacity), lineWidth: 1)
    }
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var avatarOpacity: Double {
    colorScheme == .dark ? 0.32 : 0.18
  }

  private var borderOpacity: Double {
    colorScheme == .dark ? 0.48 : 0.32
  }

  private var profileColor: Color {
    profile.appearance.color
  }

  private var profileInitial: String {
    profile.name.first.map { String($0).uppercased() } ?? "P"
  }

  private var surfaceOpacity: Double {
    colorScheme == .dark ? 0.18 : 0.10
  }
}

private struct MailProfileBadge: View {
  let profile: MailProfileDefinition

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(profile.name)
          .font(.headline)
        Text(profile.appearance.accessibilityDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: profile.appearance.symbolName)
        .foregroundStyle(profile.appearance.color)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Mail Profile, \(profile.name), \(profile.appearance.accessibilityDescription)"
    )
  }
}

extension MailProfileAppearance {
  fileprivate var color: Color {
    switch colorName {
    case "blue": return .blue
    case "indigo": return .indigo
    case "purple": return .purple
    case "pink": return .pink
    case "red": return .red
    case "orange": return .orange
    case "teal": return .teal
    default: return .secondary
    }
  }
}

private struct MailShellMailboxLabel: View {
  let count: MailboxItemCount?
  let systemImage: String
  let title: String

  var body: some View {
    Label {
      HStack {
        Text(title)
        Spacer()
        if let count {
          if count.unreadCount > 0 {
            Text("\(count.unreadCount) unread")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          Text("\(count.itemCount)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    } icon: {
      Image(systemName: systemImage)
    }
  }
}

private struct MailShellMailViewBar: View {
  let presentations: [MailViewPresentation]
  @Binding var selection: MailViewSelection

  @ViewBuilder
  var body: some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      GlassEffectContainer(spacing: 12) {
        barContent
      }
    } else {
      barContent
    }
  }

  private var barContent: some View {
    mailViewButtons
      .frame(maxWidth: 560)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity)
  }

  private var mailViewButtons: some View {
    HStack(spacing: 2) {
      ForEach(presentations) { presentation in
        Button {
          selection = presentation.selection
        } label: {
          VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
              Image(systemName: presentation.systemImage)
                .font(.body)
                .frame(width: 24, height: 18)
              if let badge = presentation.badge {
                Text(badge)
                  .font(.system(size: 9, weight: .bold, design: .rounded))
                  .monospacedDigit()
                  .foregroundStyle(.white)
                  .padding(.horizontal, 4)
                  .frame(minWidth: 16, minHeight: 16)
                  .background(.red, in: Capsule())
                  .offset(x: 10, y: -7)
                  .accessibilityHidden(true)
              }
            }
            Text(presentation.title)
              .font(.caption2)
              .lineLimit(1)
              .minimumScaleFactor(0.7)
          }
          .fontWeight(selection == presentation.selection ? .semibold : .regular)
          .foregroundStyle(
            selection == presentation.selection ? Color.accentColor : Color.secondary
          )
          .frame(maxWidth: .infinity, minHeight: 48)
          .padding(.horizontal, 2)
          .background(
            selection == presentation.selection
              ? Color.accentColor.opacity(0.14) : Color.clear,
            in: Capsule()
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          presentation.unreadThreadCount > 0
            ? "\(presentation.title), \(presentation.unreadThreadCount) unread Threads"
            : presentation.title
        )
        .accessibilityValue(
          selection == presentation.selection ? "Selected" : "Not selected"
        )
        .accessibilityIdentifier("mail-view-\(presentation.selection.id)")
      }
    }
    .padding(4)
    .mailShellGlassEffect(in: Capsule())
  }

}

private struct MailShellComposeButton: View {
  let action: () -> Void

  var body: some View {
    Button("New Message", systemImage: "square.and.pencil", action: action)
      .labelStyle(.iconOnly)
      .font(.headline)
      .frame(width: 48, height: 48)
      .contentShape(Circle())
      .buttonStyle(.plain)
      .foregroundStyle(.tint)
      .mailShellGlassEffect(interactive: true, in: Circle())
      .accessibilityIdentifier("mail-compose")
  }
}

private struct MailShellTemplateDraftsButton: View {
  let templates: [MailTemplate]
  let open: (MailTemplate) -> Void

  var body: some View {
    Menu("New Message from Template", systemImage: "doc.on.doc") {
      ForEach(templates) { template in
        Button(template.name) {
          open(template)
        }
      }
    }
    .labelStyle(.iconOnly)
    .font(.headline)
    .frame(width: 48, height: 48)
    .mailShellGlassEffect(in: Circle())
    .accessibilityIdentifier("mail-compose-template")
  }
}

private struct MailShellSavedDraftsButton: View {
  let drafts: [MailShellCompositionDraft]
  let open: (MailShellCompositionDraft) -> Void

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      Menu {
        ForEach(drafts) { draft in
          Button {
            open(draft)
          } label: {
            Label(
              title(for: draft, at: context.date),
              systemImage: icon(for: draft, at: context.date)
            )
          }
        }
      } label: {
        Label("Saved Drafts", systemImage: savedDraftsIcon(at: context.date))
          .labelStyle(.iconOnly)
          .font(.headline)
          .frame(width: 48, height: 48)
          .mailShellGlassEffect(in: Circle())
      }
      .accessibilityIdentifier("mail-saved-drafts")
      .accessibilityLabel(accessibilityLabel(at: context.date))
    }
  }

  private func title(for draft: MailShellCompositionDraft, at date: Date) -> String {
    let title = draft.menuTitle
    guard let reminder = draft.sendReminder else { return title }
    if reminder.isOverdue(at: date) { return "Overdue — \(title)" }
    if reminder.isSynchronizationPending { return "Syncing — \(title)" }
    return "\(title) — Reminder \(reminder.dueAt.formatted(date: .abbreviated, time: .shortened))"
  }

  private func icon(for draft: MailShellCompositionDraft, at date: Date) -> String {
    guard let reminder = draft.sendReminder else { return "doc.text" }
    if reminder.isOverdue(at: date) { return "clock.badge.exclamationmark" }
    return reminder.isSynchronizationPending ? "arrow.triangle.2.circlepath" : "doc.text"
  }

  private func savedDraftsIcon(at date: Date) -> String {
    drafts.contains { $0.sendReminder?.isOverdue(at: date) == true }
      ? "clock.badge.exclamationmark" : "doc.text"
  }

  private func accessibilityLabel(at date: Date) -> String {
    let overdueCount = drafts.count { $0.sendReminder?.isOverdue(at: date) == true }
    let pendingCount = drafts.count { $0.sendReminder?.isSynchronizationPending == true }
    if overdueCount > 0 { return "Saved Drafts, \(overdueCount) overdue" }
    return pendingCount == 0 ? "Saved Drafts" : "Saved Drafts, \(pendingCount) syncing"
  }
}

private struct MailboxSynchronizationOverlay: View {
  let connections: [MailboxSyncOverlayConnection]
  let isLoadingInitialAvailability: Bool
  let retry: ([MailboxConnectionId]) async -> Void
  @State private var isExpanded = false
  @State private var visibilityRefreshGeneration = 0

  var body: some View {
    let now = Date.now
    let nextVisibilityDate = connections.compactMap(\.status.visibleAfter).filter { $0 > now }.min()
    overlay(now: now)
      .id(visibilityRefreshGeneration)
      .task(id: nextVisibilityDate) {
        guard let nextVisibilityDate else { return }
        do {
          try await Task.sleep(
            for: .seconds(max(0, nextVisibilityDate.timeIntervalSinceNow))
          )
        } catch {
          return
        }
        visibilityRefreshGeneration += 1
      }
      .accessibilityIdentifier("mailbox-sync-overlay")
  }

  @ViewBuilder
  // swiftlint:disable:next function_body_length
  private func overlay(now: Date) -> some View {
    if let state = MailboxSyncOverlayState.aggregate(
      connections: connections,
      isLoadingInitialAvailability: isLoadingInitialAvailability,
      now: now
    ) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          if let progress = state.progress {
            ProgressView(value: progress)
              .frame(maxWidth: 80)
          } else if state.retryConnectionIds.isEmpty {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
          Text(state.title)
            .font(.footnote.weight(.medium))
            .lineLimit(2)
          Spacer(minLength: 0)
          if !state.retryConnectionIds.isEmpty {
            Button("Retry") {
              Task { await retry(state.retryConnectionIds) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
          if state.connections.count > 1 {
            Button {
              withAnimation { isExpanded.toggle() }
            } label: {
              Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide connection status" : "Show connection status")
          }
        }
        if isExpanded {
          ForEach(state.connections) { connection in
            LabeledContent(connection.name, value: connection.status.summary)
              .font(.caption)
          }
        }
      }
      .padding(10)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      .shadow(radius: 3, y: 1)
      .padding(.horizontal, 12)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }
}

// swiftlint:disable:next type_body_length
struct MailShellThreadList: View {
  @ScaledMetric(relativeTo: .subheadline) private var unreadIndicatorSize: CGFloat = 7

  let connection: MailboxConnection?
  let connections: [MailboxConnection]
  var composePreferences: ComposePreferences = .defaults
  @Bindable var featureSuggestionStore: FeatureSuggestionPreferenceStore
  let isConnectionBusy: Bool
  let items: [MailShellThreadListItem]
  var mailAssistanceViewModel: MailAssistanceViewModel?
  @Bindable var mailActionViewModel: GmailMailActionViewModel
  var outboxItems: [OutgoingDeliveryAttempt] = []
  var scheduledSendItems: [ManagedScheduledSend] = []
  var sendingIdentities: [SendingIdentity] = []
  let mailboxSelection: MailShellMailboxSelection?
  let navigationSnapshot: MailboxNavigationSnapshot
  var openSettings: (SettingsRoute) -> Void = { _ in }
  @Bindable var muteViewModel: ThreadMuteViewModel
  @Bindable var pinViewModel: PinViewModel
  var partialSearchResultThreadId: MailboxThreadIdentity?
  @Bindable var snoozeViewModel: ThreadSnoozeViewModel
  @Binding var selectedThreadIds: Set<MailboxThreadIdentity>
  @Binding var showsMailboxTools: Bool
  var swipePreferences: SwipePreferences = .defaults
  @Bindable var viewModel: GmailInboxViewModel
  var selectSearchResult: (MailboxMessageMetadata) -> Void = { _ in }
  var categoryChoices: [MessageCategoryChoice] = []
  var inboxPreferences: InboxPreferences = .defaults
  var readingPreferences: ReadingPreferences = .defaults
  var allowsProactiveSuggestions = true
  var clearCachedBodies: () async throws -> Void = {}
  var revalidateTrustedDevice: () async -> Bool = { true }
  var saveDraft: MailComposerViewModel.SaveDraft = { _ in }
  var deleteDraft: MailComposerViewModel.DeleteDraft = { _ in }
  var reminderOwnerDeviceId = "local-device"
  var cancelReminder: MailComposerViewModel.CancelReminder = { _, _ in }
  var scheduleReminder: MailComposerViewModel.ScheduleReminder = { _ in .unavailable }
  var itemDidRender: (MailShellThreadListItem) -> Void = { _ in }
  var contentPresentationDismissal = MailPresentationDismissalCoordinator()
  @State private var editingAttempt: OutgoingDeliveryAttempt?
  @State private var scheduledEditSession: ScheduledSendEditSession?
  @State private var cleanupOutcome: InboxCleanupExecutionOutcome?
  @State private var cleanupProposal: InboxCleanupProposal?
  @State private var cleanupProposalTask: Task<Void, Never>?
  @State private var cleanupReviewModel: InboxCleanupReviewModel?
  @State private var isUndoingCleanup = false
  @State private var pendingMoveItem: MailShellThreadListItem?

  var body: some View {
    Group {
      if mailboxSelection != nil {
        if mailboxSelection == .outbox {
          outboxContent
        } else if let connection, connection.authorizationState == .required {
          ContentUnavailableView {
            Label(
              "Authorization required",
              systemImage: "lock.trianglebadge.exclamationmark"
            )
          } description: {
            Text("Authorize this Mailbox Connection on this device to load its mail.")
          } actions: {
            Button("Open Email Accounts") {
              openSettings(.authorization(connectionId: connection.id))
            }
          }
        } else if let errorMessage = viewModel.errorMessage,
          items.isEmpty,
          !viewModel.isLoading,
          !viewModel.isSyncing
        {
          ContentUnavailableView(
            "Inbox unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text(errorMessage)
          )
        } else if items.isEmpty && cleanupProposal == nil && cleanupOutcome == nil
          && !viewModel.isLoading && !viewModel.isSyncing
        {
          ContentUnavailableView(
            "No inbox messages",
            systemImage: "tray",
            description: Text(emptyInboxDescription)
          )
        } else {
          List(selection: displayedThreadSelection) {
            if let errorMessage = viewModel.errorMessage {
              Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                  .foregroundStyle(.orange)
              }
            }
            if let cleanupOutcome {
              Section {
                InboxCleanupOutcomeCard(
                  outcome: cleanupOutcome,
                  isUndoing: isUndoingCleanup,
                  dismiss: {
                    self.cleanupOutcome = nil
                    refreshCleanupProposal()
                  },
                  undo: { undoCleanup(cleanupOutcome) }
                )
              }
            } else if let cleanupProposal {
              Section {
                InboxCleanupProposalCard(
                  proposal: cleanupProposal,
                  disable: {
                    featureSuggestionStore.setEnabled(false, feature: .inboxCleanup)
                    self.cleanupProposal = nil
                  },
                  dismiss: { dismissCleanupProposal(cleanupProposal) },
                  review: { beginCleanupReview(cleanupProposal) }
                )
              }
            }
            Section {
              let categoryNamesById = categoryNamesById
              let pinnedThreadIds = pinViewModel.pinnedThreadIds
              let moveEnabledConnectionIds = moveEnabledConnectionIds
              ForEach(items) { item in
                let isUnread = MailViewFilter.isUnread(item.thread)
                let swipeActions = resolvedSwipeActions(
                  for: item,
                  moveEnabledConnectionIds: moveEnabledConnectionIds
                )
                NavigationLink(value: item.thread.id) {
                  MailShellThreadRow(
                    categoryNamesById: categoryNamesById,
                    isPinned: pinnedThreadIds.contains(item.thread.id),
                    isUnread: isUnread,
                    item: item,
                    preferences: inboxPreferences,
                    showsSourceConnection: mailboxSelection?.isUnified == true,
                    unreadIndicatorSize: unreadIndicatorSize
                  )
                  .onAppear { itemDidRender(item) }
                  .onChange(of: item.id) { _, _ in itemDidRender(item) }
                }
                .accessibilityIdentifier("mail-thread-row")
                .accessibilityValue(isUnread ? "Unread" : "Read")
                .accessibilityAddTraits(
                  selectedThreadIds.contains(item.thread.id) ? .isSelected : []
                )
                .listRowBackground(threadRowBackground(for: item))
                .contextMenu {
                  Button {
                    Task { await muteViewModel.toggleMute(item.thread) }
                  } label: {
                    Label(
                      muteViewModel.mutedThreadIds.contains(item.thread.id) ? "Unmute" : "Mute",
                      systemImage: muteViewModel.mutedThreadIds.contains(item.thread.id)
                        ? "speaker.wave.2" : "speaker.slash"
                    )
                  }
                  .disabled(muteViewModel.isUpdating(item.thread.id))
                }
                .swipeActions(
                  edge: .leading,
                  allowsFullSwipe: SwipeActionResolver.allowsFullSwipe(
                    preferences: swipePreferences,
                    edge: .leading,
                    resolvedActions: swipeActions.leading
                  )
                ) {
                  ForEach(swipeActions.leading) { action in
                    swipeButton(action, item: item)
                  }
                }
                .swipeActions(
                  edge: .trailing,
                  allowsFullSwipe: SwipeActionResolver.allowsFullSwipe(
                    preferences: swipePreferences,
                    edge: .trailing,
                    resolvedActions: swipeActions.trailing
                  )
                ) {
                  ForEach(swipeActions.trailing) { action in
                    swipeButton(action, item: item)
                  }
                }
                .contextMenu {
                  ThreadSnoozeMenu(
                    thread: item.thread,
                    allowsSnooze: partialSearchResultThreadId != item.thread.id,
                    viewModel: snoozeViewModel
                  )
                }
              }
            }
          }
          .mailShellTopScrollEdgeEffectHidden()
          .listStyle(.plain)
          .tint(MailTheme.accent)
          .scrollContentBackground(.hidden)
          .background(MailTheme.canvas)
        }
      } else {
        ContentUnavailableView(
          "Select a mailbox",
          systemImage: "sidebar.left",
          description: Text("Choose a Mailbox Connection from the sidebar.")
        )
      }
    }
    .background(MailTheme.canvas)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(MailTheme.separator)
        .frame(height: 1)
        .allowsHitTesting(false)
    }
    .navigationTitle(navigationTitle)
    .toolbarBackground(.thinMaterial, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbar {
      if mailboxSelection?.isUnified == true, !items.isEmpty {
        ToolbarItem(placement: .secondaryAction) {
          EditButton()
        }
      }
      if showsRefreshToolbarButton {
        if #available(iOS 26.0, macOS 26.0, *) {
          ToolbarItemGroup(placement: .primaryAction) {
            threadListRefreshToolbarButtons
          }
          .sharedBackgroundVisibility(.hidden)
        } else {
          ToolbarItemGroup(placement: .primaryAction) {
            threadListRefreshToolbarButtons
          }
        }
      }
      if mailboxSelection != nil, mailboxSelection != .outbox {
        ToolbarItem(placement: .secondaryAction) {
          Button {
            showsMailboxTools = true
          } label: {
            Label("Mailbox Tools", systemImage: "ellipsis.circle")
          }
        }
      }
    }
    .composePresentation(
      item: $editingAttempt,
      preference: composePreferences.presentation
    ) { attempt in
      MailShellComposer(
        connections: connections,
        draft: .editing(attempt),
        preferences: composePreferences,
        isSending: mailActionViewModel.isPerformingAction,
        mailAssistanceViewModel: mailAssistanceViewModel,
        readingPreferences: readingPreferences,
        sendingIdentities: sendingIdentities,
        send: { draft in
          guard
            let connectionId = draft.connectionId,
            let connection = connections.first(where: { $0.id == connectionId }),
            let identity = sendingIdentities.first(where: { $0.id == draft.sendingIdentityId }),
            identity.connectionId == connectionId
          else { return false }
          return await mailActionViewModel.editOutboxAttempt(
            attempt,
            recipient: draft.recipient,
            subject: draft.subject,
            body: draft.deliveryBody,
            document: draft.deliveryDocument,
            assets: draft.assets,
            ccRecipients: draft.ccRecipients,
            bccRecipients: draft.bccRecipients,
            fromAddress: identity.headerValue,
            sendingIdentityId: identity.id,
            connection: connection,
            requestsReadReceipt: draft.requestsReadReceipt,
            undoSendWindow: composePreferences.undoSendWindow
          )
        }
      )
    }
    .composePresentation(
      item: $scheduledEditSession,
      preference: composePreferences.presentation
    ) { editSession in
      let dueAt = Date(
        timeIntervalSince1970: Double(editSession.item.record.dueAtMilliseconds) / 1_000
      )
      MailShellComposer(
        connections: connections,
        draft: .editing(editSession.item.record),
        preferences: composePreferences,
        isSending: mailActionViewModel.isPerformingAction,
        mailAssistanceViewModel: mailAssistanceViewModel,
        readingPreferences: readingPreferences,
        sendingIdentities: sendingIdentities,
        saveDraft: { _ in },
        deleteDraft: { _ in },
        reminderOwnerDeviceId: reminderOwnerDeviceId,
        cancelReminder: cancelReminder,
        scheduleReminder: { draft in
          try await saveDraft(draft)
          guard
            await mailActionViewModel.cancelScheduledSend(
              editSession.item,
              editGeneration: editSession.lease.generation
            )
          else {
            try? await deleteDraft(draft.id)
            throw ScheduledSendManagementError.staleRevision
          }
          return try await scheduleReminder(draft)
        },
        scheduleSend: { draft, newDueAt, timeZone in
          await replaceScheduledSend(
            editSession,
            draft: draft,
            dueAt: newDueAt,
            timeZoneIdentifier: timeZone
          )
        },
        scheduledSendDueAt: dueAt,
        sendNow: { draft in
          await replaceScheduledSend(
            editSession,
            draft: draft,
            dueAt: nil,
            timeZoneIdentifier: TimeZone.current.identifier
          )
        },
        send: { draft in
          await replaceScheduledSend(
            editSession,
            draft: draft,
            dueAt: dueAt,
            timeZoneIdentifier: editSession.item.record.originalTimeZoneIdentifier
          )
        }
      )
      .onDisappear {
        Task { await mailActionViewModel.releaseScheduledSendEdit(editSession) }
      }
    }
    .sheet(item: $cleanupReviewModel) { model in
      InboxCleanupReviewSheet(
        model: model,
        connections: connections,
        cancel: cancelCleanupReview,
        confirm: { confirmCleanup(model) }
      )
    }
    .sheet(isPresented: $showsMailboxTools) {
      MailShellMailboxTools(
        categoryChoices: categoryChoices,
        clearCachedBodies: clearCachedBodies,
        connection: connection,
        isConnectionBusy: isConnectionBusy,
        selectMessage: { message in
          selectSearchResult(message)
          showsMailboxTools = false
        },
        revalidateTrustedDevice: revalidateTrustedDevice,
        viewModel: viewModel
      )
    }
    .confirmationDialog(
      "Move to",
      isPresented: Binding(
        get: { pendingMoveItem != nil },
        set: { isPresented in
          if !isPresented { pendingMoveItem = nil }
        }
      ),
      titleVisibility: .visible
    ) {
      if let pendingMoveItem {
        ForEach(moveDestinations(for: pendingMoveItem), id: \.id) { mailbox in
          Button(mailbox.title) {
            performProviderAction(
              .move,
              item: pendingMoveItem,
              targetProviderMailboxId: mailbox.id,
              targetProviderStateIds: mailbox.providerStateIds
            )
            self.pendingMoveItem = nil
          }
        }
      }
      Button("Cancel", role: .cancel) {
        pendingMoveItem = nil
      }
    }
    .background {
      MailContentPresentationDismissalObserver(
        coordinator: contentPresentationDismissal
      ) {
        guard
          editingAttempt != nil || cleanupReviewModel != nil || pendingMoveItem != nil
            || showsMailboxTools
        else { return }
        editingAttempt = nil
        cleanupReviewModel = nil
        pendingMoveItem = nil
        showsMailboxTools = false
      }
    }
    .task {
      refreshCleanupProposal()
    }
    .onChange(of: navigationSnapshot) { _, _ in
      refreshCleanupProposal()
    }
    .onChange(of: mailboxSelection) { _, _ in
      cleanupOutcome = nil
      cleanupProposal = nil
      cleanupReviewModel = nil
      refreshCleanupProposal()
    }
    .onChange(of: featureSuggestionStore.preferences) { _, _ in
      refreshCleanupProposal()
    }
    .onChange(of: allowsProactiveSuggestions) { _, _ in
      refreshCleanupProposal()
    }
  }

  private var showsRefreshToolbarButton: Bool {
    Self.showsUnifiedInboxRefreshButton(
      mailboxSelection: mailboxSelection,
      connections: connections
    )
      || (connection?.authorizationState == .authorized
        && connection?.capabilities.canSynchronizeMetadata == true)
  }

  @ViewBuilder
  private var threadListRefreshToolbarButtons: some View {
    if Self.showsUnifiedInboxRefreshButton(
      mailboxSelection: mailboxSelection,
      connections: connections
    ) {
      Button {
        Task {
          guard await revalidateTrustedDevice() else { return }
          await viewModel.loadUnifiedInbox(connections: connections)
        }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .disabled(
        Self.isUnifiedInboxRefreshDisabled(
          viewModel: viewModel,
          connections: connections,
          isConnectionBusy: isConnectionBusy
        )
      )
      .accessibilityIdentifier("unified-inbox-refresh")
      .mailShellToolbarActionStyle()
    }

    if let connection, connection.authorizationState == .authorized,
      connection.capabilities.canSynchronizeMetadata
    {
      Button {
        Task {
          guard await revalidateTrustedDevice() else { return }
          _ = await viewModel.refresh(connection: connection)
        }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .disabled(viewModel.isRefreshDisabled || isConnectionBusy)
      .mailShellToolbarActionStyle()
    }
  }

  private var displayedThreadSelection: Binding<Set<MailboxThreadIdentity>> {
    $selectedThreadIds
  }

  private func threadRowBackground(for item: MailShellThreadListItem) -> Color {
    #if targetEnvironment(macCatalyst)
      selectedThreadIds.contains(item.thread.id) ? MailTheme.accent.opacity(0.12) : .clear
    #else
      .clear
    #endif
  }

  @ViewBuilder
  private func swipeButton(
    _ action: ResolvedSwipeAction,
    item: MailShellThreadListItem
  ) -> some View {
    Button(role: destructiveRole(for: action)) {
      switch action.execution {
      case .pin:
        Task {
          await pinViewModel.togglePin(
            item.thread.id,
            anchorMessageId: item.thread.latestMessage.id
          )
        }
      case .provider(.move):
        pendingMoveItem = item
      case .provider(let providerAction):
        performProviderAction(providerAction, item: item)
      }
    } label: {
      Label(action.title, systemImage: action.systemImage)
    }
    .accessibilityIdentifier(swipeAccessibilityIdentifier(action))
    .disabled(isSwipeActionDisabled(action, item: item))
  }

  private func swipeAccessibilityIdentifier(_ action: ResolvedSwipeAction) -> String {
    switch action.execution {
    case .pin:
      return "mail-swipe-action-pin"
    case .provider(let providerAction):
      return "mail-swipe-action-\(providerAction.rawValue)"
    }
  }

  private func resolvedSwipeActions(
    for item: MailShellThreadListItem,
    moveEnabledConnectionIds: Set<MailboxConnectionId>
  ) -> (leading: [ResolvedSwipeAction], trailing: [ResolvedSwipeAction]) {
    guard let connection = connection(for: item) else { return ([], []) }
    let messages = mailboxMessages(for: item)
    let contextualActions = MailShellConversationReader.contextualProviderActions(
      supported: connection.capabilities.providerActions,
      messages: messages,
      collection: mailboxSelection?.collection,
      allowsMove: moveEnabledConnectionIds.contains(connection.id),
      allowsProviderMailboxMove: MailShellConversationReader.allowsMoveFromProviderMailbox(
        connection.providerId
      )
    )
    let context = SwipeActionContext(
      messages: messages,
      pinTargetThreadId: item.thread.id,
      pinnedThreadIds: pinViewModel.pinnedThreadIds,
      providerActions: contextualActions
    )
    return (
      leading: SwipeActionResolver.resolve(
        configuredActions: swipePreferences.actions(for: .leading),
        context: context,
        platform: .current
      ),
      trailing: SwipeActionResolver.resolve(
        configuredActions: swipePreferences.actions(for: .trailing),
        context: context,
        platform: .current
      )
    )
  }

  private var moveEnabledConnectionIds: Set<MailboxConnectionId> {
    Set(
      connections.compactMap { connection in
        guard
          navigationSnapshot.providerMailboxes(for: connection.id).contains(where: {
            $0.isMoveDestination && MailboxMessageCollection.isProviderMailboxId($0.id)
          })
        else { return nil }
        return connection.id
      }
    )
  }

  private func connection(for item: MailShellThreadListItem) -> MailboxConnection? {
    connections.first { $0.id == item.thread.id.connectionId }
  }

  private func mailboxMessages(for item: MailShellThreadListItem) -> [MailboxMessageMetadata] {
    guard let collection = mailboxSelection?.collection else { return [] }
    return item.thread.messages.filter {
      collection.contains(
        providerStateIds: $0.providerStateIds,
        isPinned: pinViewModel.pinnedThreadIds.contains($0.threadIdentity),
        isSnoozed: snoozeViewModel.snoozedThreadIds.contains($0.threadIdentity)
      )
    }
  }

  private func moveDestinations(for item: MailShellThreadListItem) -> [ProviderMailbox] {
    guard let connection = connection(for: item) else { return [] }
    return navigationSnapshot.providerMailboxes(for: connection.id).filter {
      $0.isMoveDestination && MailboxMessageCollection.isProviderMailboxId($0.id)
    }
  }

  private func destructiveRole(for action: ResolvedSwipeAction) -> ButtonRole? {
    switch action.execution {
    case .provider(.delete), .provider(.spam):
      return .destructive
    case .pin, .provider:
      return nil
    }
  }

  private func isSwipeActionDisabled(
    _ action: ResolvedSwipeAction,
    item: MailShellThreadListItem
  ) -> Bool {
    switch action.execution {
    case .pin:
      return pinViewModel.isUpdating(item.thread.id)
    case .provider:
      guard let connection = connection(for: item) else { return true }
      return isConnectionBusy || viewModel.areCachedMetadataActionsDisabled
        || viewModel.areProviderActionsDisabledDuringHistoricalBackfill(for: [connection])
        || mailActionViewModel.isPerformingAction
    }
  }

  private func performProviderAction(
    _ action: ProviderMailAction,
    item: MailShellThreadListItem,
    targetProviderMailboxId: String? = nil,
    targetProviderStateIds: Set<String> = []
  ) {
    guard let connection = connection(for: item) else { return }
    let batch = MailboxBulkActionBatch(
      connection: connection,
      messages: mailboxMessages(for: item),
      sourceProviderMailboxId: mailboxSelection?.collection?.providerMailboxMoveSourceId,
      targetProviderMailboxId: targetProviderMailboxId,
      targetProviderStateIds: targetProviderStateIds
    )
    mailActionViewModel.startPendingAction {
      guard await revalidateTrustedDevice() else { return }
      let deferredConnectionIds = viewModel.historicalBackfillConnectionIds(for: [connection])
      guard
        let result = await mailActionViewModel.performBulk(
          action,
          batches: [batch],
          deferredPendingActionConnectionIds: deferredConnectionIds,
          onEnqueued: { enqueuedConnection in
            _ = await viewModel.reloadLocal(
              connection: enqueuedConnection,
              refreshesNavigationSnapshot: !viewModel.isHistoricalBackfillRunning(
                for: [enqueuedConnection]
              )
            )
          },
          onDeferredCompletion: { completedConnection in
            _ = await viewModel.reloadLocal(connection: completedConnection)
          },
          shouldDeferPendingActions: { candidate in
            viewModel.isHistoricalBackfillRunning(for: [candidate])
          }
        )
      else { return }
      if result.shouldReloadImmediately(connection.id) {
        _ = await viewModel.reloadLocal(
          connection: connection,
          refreshesNavigationSnapshot: !deferredConnectionIds.contains(connection.id)
        )
      }
    }
  }

  private func refreshCleanupProposal() {
    cleanupProposalTask?.cancel()
    guard cleanupReviewModel == nil, cleanupOutcome == nil,
      allowsProactiveSuggestions,
      featureSuggestionStore.preferences.isEnabled(.inboxCleanup),
      let scope = InboxCleanupScope(mailboxSelection: mailboxSelection)
    else {
      if cleanupReviewModel == nil, cleanupOutcome == nil {
        cleanupProposal = nil
      }
      return
    }
    let messagesByConnection = navigationSnapshot.messagesByConnection
    let pinnedThreadIds = navigationSnapshot.pinnedThreadIds
    let connections = connections
    cleanupProposalTask = Task {
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      let detectionTask = Task.detached(priority: .utility) {
        InboxCleanupDetector.proposal(
          messagesByConnection: messagesByConnection,
          connections: connections,
          pinnedThreadIds: pinnedThreadIds,
          scope: scope,
          shouldCancel: { Task.isCancelled }
        )
      }
      let detectedProposal = await withTaskCancellationHandler {
        await detectionTask.value
      } onCancel: {
        detectionTask.cancel()
      }
      guard !Task.isCancelled, cleanupReviewModel == nil, cleanupOutcome == nil else { return }
      guard let detectedProposal else {
        cleanupProposal = nil
        return
      }
      applyCleanupProposal(detectedProposal, scope: scope)
    }
  }

  private func applyCleanupProposal(
    _ detectedProposal: InboxCleanupProposal,
    scope: InboxCleanupScope
  ) {
    if cleanupProposal?.scope == scope {
      cleanupProposal = detectedProposal
      return
    }
    switch featureSuggestionStore.inboxCleanupPresentation(
      scopeIdentifier: scope.preferenceIdentifier,
      candidateCount: detectedProposal.eligibleCandidateCount
    ) {
    case .consumeEarlyReturn:
      featureSuggestionStore.recordInboxCleanupDisplay(
        scopeIdentifier: scope.preferenceIdentifier,
        candidateCount: detectedProposal.eligibleCandidateCount
      )
      cleanupProposal = detectedProposal
    case .hidden:
      cleanupProposal = nil
    case .visible:
      cleanupProposal = detectedProposal
    }
  }

  private func beginCleanupReview(_ proposal: InboxCleanupProposal) {
    cleanupProposal = nil
    cleanupReviewModel = InboxCleanupReviewModel(proposal: proposal)
  }

  private func dismissCleanupProposal(_ proposal: InboxCleanupProposal) {
    featureSuggestionStore.recordInboxCleanupDisplay(
      scopeIdentifier: proposal.scope.preferenceIdentifier,
      candidateCount: proposal.eligibleCandidateCount
    )
    cleanupProposal = nil
  }

  private func confirmCleanup(_ model: InboxCleanupReviewModel) {
    guard model.isPerforming == false else { return }
    model.isPerforming = true
    let started = mailActionViewModel.startPendingAction {
      defer { model.isPerforming = false }
      guard await revalidateTrustedDevice() else { return }
      let revalidation = cleanupRevalidation(
        model.selectedMessageIds,
        scope: model.proposal.scope
      )
      guard revalidation.skippedMessageIds.isEmpty else {
        model.apply(revalidation)
        return
      }
      let batches = cleanupBatches(revalidation.eligibleCandidates)
      guard batches.isEmpty == false else { return }
      let deferredConnectionIds = viewModel.historicalBackfillConnectionIds(
        for: batches.map(\.connection)
      )
      guard
        let result = await mailActionViewModel.performBulk(
          .delete,
          batches: batches,
          deferredPendingActionConnectionIds: deferredConnectionIds,
          onEnqueued: { enqueuedConnection in
            _ = await viewModel.reloadLocal(
              connection: enqueuedConnection,
              refreshesNavigationSnapshot: !viewModel.isHistoricalBackfillRunning(
                for: [enqueuedConnection]
              )
            )
          },
          onDeferredCompletion: { completedConnection in
            _ = await viewModel.reloadLocal(connection: completedConnection)
          },
          shouldDeferPendingActions: { candidate in
            viewModel.isHistoricalBackfillRunning(for: [candidate])
          }
        )
      else { return }
      finishCleanup(result: result, batches: batches, model: model)
    }
    guard started else {
      model.isPerforming = false
      return
    }
  }

  private func cancelCleanupReview() {
    cleanupReviewModel = nil
    refreshCleanupProposal()
  }

  private func finishCleanup(
    result: MailboxBulkActionResult,
    batches: [MailboxBulkActionBatch],
    model: InboxCleanupReviewModel
  ) {
    featureSuggestionStore.recordInboxCleanupDisplay(
      scopeIdentifier: model.proposal.scope.preferenceIdentifier,
      candidateCount: model.proposal.eligibleCandidateCount
    )
    cleanupReviewModel = nil
    cleanupOutcome = .deletion(result: result, batches: batches)
  }

  private func undoCleanup(_ outcome: InboxCleanupExecutionOutcome) {
    guard isUndoingCleanup == false else { return }
    isUndoingCleanup = true
    let started = mailActionViewModel.startPendingAction {
      defer { isUndoingCleanup = false }
      guard await revalidateTrustedDevice() else { return }
      let deferredConnectionIds = viewModel.historicalBackfillConnectionIds(
        for: outcome.undoBatches.map(\.connection)
      )
      guard
        let result = await mailActionViewModel.performBulk(
          .restore,
          batches: outcome.undoBatches,
          deferredPendingActionConnectionIds: deferredConnectionIds,
          onEnqueued: { enqueuedConnection in
            _ = await viewModel.reloadLocal(
              connection: enqueuedConnection,
              refreshesNavigationSnapshot: !viewModel.isHistoricalBackfillRunning(
                for: [enqueuedConnection]
              )
            )
          },
          onDeferredCompletion: { completedConnection in
            _ = await viewModel.reloadLocal(connection: completedConnection)
          },
          shouldDeferPendingActions: { candidate in
            viewModel.isHistoricalBackfillRunning(for: [candidate])
          }
        )
      else { return }
      guard result.failures.isEmpty else {
        cleanupOutcome = .restorationFailure(result, batches: outcome.undoBatches)
        return
      }
      cleanupOutcome = nil
      refreshCleanupProposal()
    }
    if started == false {
      isUndoingCleanup = false
    }
  }

  private func cleanupRevalidation(
    _ messageIds: Set<StableProviderMessageIdentity>,
    scope: InboxCleanupScope
  ) -> InboxCleanupRevalidation {
    InboxCleanupDetector.revalidate(
      messageIds,
      messagesByConnection: navigationSnapshot.messagesByConnection,
      connections: connections,
      pinnedThreadIds: navigationSnapshot.pinnedThreadIds,
      scope: scope
    )
  }

  private func cleanupBatches(
    _ candidates: [InboxCleanupCandidate]
  ) -> [MailboxBulkActionBatch] {
    let connectionsById = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
    return Dictionary(grouping: candidates, by: \.message.connectionId)
      .compactMap { connectionId, candidates in
        guard let connection = connectionsById[connectionId] else { return nil }
        return MailboxBulkActionBatch(
          connection: connection,
          messages: candidates.map(\.message),
          sourceProviderMailboxId: mailboxSelection?.collection?.providerMailboxMoveSourceId
        )
      }
      .sorted { $0.connection.id.rawValue < $1.connection.id.rawValue }
  }

  static func showsUnifiedInboxRefreshButton(
    mailboxSelection: MailShellMailboxSelection?,
    connections: [MailboxConnection]
  ) -> Bool {
    guard mailboxSelection == .unified(.inbox) else { return false }
    return connections.contains {
      $0.authorizationState == .authorized && $0.capabilities.canSynchronizeMetadata
    }
  }

  static func isUnifiedInboxRefreshDisabled(
    viewModel: GmailInboxViewModel,
    connections: [MailboxConnection],
    isConnectionBusy: Bool
  ) -> Bool {
    isConnectionBusy || viewModel.isRefreshDisabled
      || viewModel.isHistoricalBackfillRunning(for: connections)
  }

  @ViewBuilder
  private var outboxContent: some View {
    if outboxItems.isEmpty && scheduledSendItems.isEmpty {
      ContentUnavailableView(
        "Outbox is empty",
        systemImage: "paperplane",
        description: Text("Scheduled, sending, and attention-needed deliveries appear here.")
      )
    } else {
      List {
        if !scheduledItems.isEmpty {
          Section("Scheduled") {
            ForEach(scheduledItems) { scheduledSendRow($0) }
          }
        }
        if !sendingScheduledItems.isEmpty || !sendingOutboxItems.isEmpty {
          Section("In Progress") {
            ForEach(sendingScheduledItems) { scheduledSendRow($0) }
            ForEach(sendingOutboxItems) { outboxRow($0) }
          }
        }
        if !attentionScheduledItems.isEmpty || !attentionOutboxItems.isEmpty {
          Section("Needs Attention") {
            ForEach(attentionScheduledItems) { scheduledSendRow($0) }
            ForEach(attentionOutboxItems) { outboxRow($0) }
          }
        }
      }
      .mailShellTopScrollEdgeEffectHidden()
    }
  }

  private var scheduledItems: [ManagedScheduledSend] {
    scheduledSendItems.filter { $0.state == .scheduled }
  }

  private var sendingScheduledItems: [ManagedScheduledSend] {
    scheduledSendItems.filter { $0.state == .sending }
  }

  private var attentionScheduledItems: [ManagedScheduledSend] {
    scheduledSendItems.filter { $0.state == .needsAttention }
  }

  private var sendingOutboxItems: [OutgoingDeliveryAttempt] {
    outboxItems.filter { ![.failed, .outcomeUnknown, .userActionRequired].contains($0.state) }
  }

  private var attentionOutboxItems: [OutgoingDeliveryAttempt] {
    outboxItems.filter { [.failed, .outcomeUnknown, .userActionRequired].contains($0.state) }
  }

  private func scheduledSendRow(_ item: ManagedScheduledSend) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(item.record.message.subject.isEmpty ? "(No subject)" : item.record.message.subject)
        .font(.headline)
      Text("To: \(item.record.message.recipient)")
        .font(.subheadline)
      Text(
        Date(timeIntervalSince1970: Double(item.record.dueAtMilliseconds) / 1_000),
        format: .dateTime.month().day().hour().minute()
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      if let connection = connections.first(where: { $0.id == item.record.connectionId }) {
        Text("From: \(connection.displayName)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if item.state != .sending {
        HStack {
          Button("Edit") {
            Task {
              scheduledEditSession = await mailActionViewModel.beginScheduledSendEdit(item)
            }
          }
          Button("Cancel Scheduled Send", role: .destructive) {
            Task { await cancelScheduledSendAndRestoreDraft(item) }
          }
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(.vertical, 4)
  }

  // swiftlint:disable:next function_body_length
  private func outboxRow(_ attempt: OutgoingDeliveryAttempt) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(attempt.message.subject.isEmpty ? "(No subject)" : attempt.message.subject)
          .font(.headline)
          .accessibilityIdentifier("mail-outbox-subject")
        Spacer()
        Text(outboxStateTitle(attempt.state))
          .font(.caption)
          .foregroundStyle(attempt.state == .failed ? .red : .secondary)
          .accessibilityIdentifier("mail-outbox-state")
      }
      Text("To: \(attempt.message.recipient)")
        .font(.subheadline)
      if let connection = connections.first(where: { $0.id == attempt.mailboxConnectionId }) {
        Text("From: \(connection.displayName)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let lastErrorDescription = attempt.lastErrorDescription {
        Text(lastErrorDescription)
          .font(.caption)
          .foregroundStyle(.orange)
      }
      HStack {
        if attempt.canEditOrCancel {
          Button("Edit") { editingAttempt = attempt }
        }
        if attempt.canCancel {
          Button("Cancel", role: .destructive) {
            Task { await mailActionViewModel.cancelOutboxAttempt(attempt) }
          }
        }
        if attempt.state == .failed || attempt.state == .userActionRequired {
          Button("Retry") { Task { await mailActionViewModel.retryOutboxAttempt(attempt) } }
        }
        if attempt.state == .outcomeUnknown {
          Button("Mark Sent") {
            Task {
              await mailActionViewModel.resolveUnknownOutboxAttempt(attempt, asDelivered: true)
            }
          }
          Button("Not Sent") {
            Task {
              await mailActionViewModel.resolveUnknownOutboxAttempt(attempt, asDelivered: false)
            }
          }
        }
      }
      .buttonStyle(.bordered)
    }
    .padding(.vertical, 4)
  }

  private func cancelScheduledSendAndRestoreDraft(_ item: ManagedScheduledSend) async {
    let restoredDraft = MailShellCompositionDraft.editing(item.record).preservingAsNewDraft()
    do {
      try await saveDraft(restoredDraft)
      guard await mailActionViewModel.cancelScheduledSend(item) else {
        try? await deleteDraft(restoredDraft.id)
        return
      }
    } catch {
      try? await deleteDraft(restoredDraft.id)
      mailActionViewModel.errorMessage = error.localizedDescription
    }
  }

  private func replaceScheduledSend(
    _ editSession: ScheduledSendEditSession,
    draft: MailShellCompositionDraft,
    dueAt: Date?,
    timeZoneIdentifier: String
  ) async -> Bool {
    guard
      let identity = sendingIdentities.first(where: { $0.id == draft.sendingIdentityId }),
      identity.connectionId == draft.connectionId
    else { return false }
    let replaced = await mailActionViewModel.replaceScheduledSend(
      editSession,
      draft: draft,
      fromAddress: identity.headerValue,
      dueAt: dueAt,
      originalTimeZoneIdentifier: timeZoneIdentifier,
      undoSendWindow: composePreferences.undoSendWindow
    )
    if !replaced, mailActionViewModel.scheduledSendEditConflict {
      try? await saveDraft(draft.preservingAsNewDraft())
    }
    return replaced
  }

  // swiftlint:disable:next cyclomatic_complexity
  private func outboxStateTitle(_ state: OutgoingDeliveryState) -> String {
    switch state {
    case .pending:
      "Pending"
    case .handingOff:
      "Sending"
    case .reconciling:
      "Confirming"
    case .retrying:
      "Retrying"
    case .failed:
      "Failed"
    case .userActionRequired:
      "Needs attention"
    case .outcomeUnknown:
      "Outcome unknown"
    case .cancelled:
      "Cancelled"
    case .sent:
      "Sent"
    case .sentCopyPending:
      "Saving Sent copy"
    case .superseded:
      "Edited"
    }
  }

  private var emptyInboxDescription: String {
    if mailboxSelection?.isUnified == true {
      return "Authorized Mailbox Connections have no locally observed messages here yet."
    }
    if mailboxSelection == .outbox {
      return "Pending, retrying, and failed deliveries appear here."
    }
    return "This Mailbox Connection has no locally observed messages here yet."
  }

  private var categoryNamesById: [String: String] {
    Dictionary(uniqueKeysWithValues: categoryChoices.map { ($0.id, $0.name) })
  }

  private var navigationTitle: String {
    switch mailboxSelection {
    case .unified(let mailbox):
      return mailbox == .inbox ? "Unified Inbox" : mailbox.title
    case .connection(_, let collection):
      switch collection {
      case .role(.inbox):
        return connection?.displayName ?? "Inbox"
      case .providerMailbox(let providerMailboxId):
        guard let connection else { return providerMailboxId }
        return navigationSnapshot.providerMailboxes(for: connection.id).first {
          $0.id == providerMailboxId
        }?.title ?? providerMailboxId
      default:
        return connection?.displayName ?? "Mailbox"
      }
    case .outbox:
      return "Outbox"
    case nil:
      return "Inbox"
    }
  }
}

private struct MailShellMailboxTools: View {
  let categoryChoices: [MessageCategoryChoice]
  let clearCachedBodies: () async throws -> Void
  let connection: MailboxConnection?
  let isConnectionBusy: Bool
  let selectMessage: (MailboxMessageMetadata) -> Void
  let revalidateTrustedDevice: () async -> Bool
  @Bindable var viewModel: GmailInboxViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var cacheErrorMessage: String?
  @State private var searchTask: Task<Void, Never>?

  var body: some View {
    NavigationStack {
      Form {
        Section("Search") {
          TextField(
            "Sender, recipient, subject, date, state, or Category",
            text: $viewModel.searchQuery
          )
          Button("Search Local Metadata") {
            viewModel.searchLocal(
              categoryNamesById: Dictionary(
                uniqueKeysWithValues: categoryChoices.map { ($0.id, $0.name) }
              )
            )
          }
          .disabled(areCachedMetadataActionsDisabled || trimmedQuery.isEmpty)
          if connection?.capabilities.canSearchProvider == true {
            Button("Search \(providerDisplayName) Full Text") {
              guard let connection else { return }
              searchTask?.cancel()
              searchTask = Task {
                guard await revalidateTrustedDevice() else { return }
                await viewModel.searchProvider(connection: connection)
              }
            }
            .disabled(isDisabled || trimmedQuery.isEmpty)
          }
          if viewModel.searchResult != nil {
            Button("Clear Search", action: viewModel.clearSearch)
          }
          if viewModel.isSearching {
            ProgressView("Searching \(providerDisplayName)…")
          }
          if let result = viewModel.searchResult {
            Text(
              "\(result.messages.count) results from "
                + result.source.title(providerDisplayName: providerDisplayName)
            )
            .font(.footnote)
            ForEach(result.messages) { message in
              Button {
                selectMessage(message)
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(message.subject)
                  Text(message.from ?? "Unknown sender")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
          Text(
            connection?.capabilities.canSearchProvider == true
              ? "Local search stays on this device. Provider full-text search sends only "
                + "this query to \(providerDisplayName)."
              : "Local search stays on this device."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }

        if let connection, connection.capabilities.canCategorizeHistorical {
          Section {
            HistoricalCategorizationPanel(
              isDisabled: isDisabled,
              isWorking: viewModel.isCategorizingHistorical,
              categorize: { scope in
                Task {
                  await viewModel.categorizeHistorical(scope: scope, connection: connection)
                }
              }
            )
          }
        }

        Section {
          Button("Remove Cached Bodies", role: .destructive) {
            Task {
              do {
                try await clearCachedBodies()
                cacheErrorMessage = nil
              } catch {
                cacheErrorMessage = error.localizedDescription
              }
            }
          }
          .disabled(areCachedBodyActionsDisabled)
          if let cacheErrorMessage {
            Text(cacheErrorMessage)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Mailbox Tools")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .onDisappear { searchTask?.cancel() }
  }

  private var isDisabled: Bool {
    isConnectionBusy || viewModel.isRefreshDisabled || viewModel.isAssigningCategory
  }

  private var areCachedMetadataActionsDisabled: Bool {
    isConnectionBusy || viewModel.areCachedMetadataActionsDisabled
      || viewModel.isAssigningCategory
  }

  private var areCachedBodyActionsDisabled: Bool {
    areCachedMetadataActionsDisabled || viewModel.isHistoricalBackfillRunning
      || viewModel.isLoadingMessageBody
  }

  private var providerDisplayName: String {
    connection?.providerId.rawValue.capitalized ?? "Provider"
  }

  private var trimmedQuery: String {
    viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private struct MailShellThreadRow: View {
  private static let receivedDateFormat = Date.FormatStyle(
    date: .abbreviated,
    time: .omitted
  )

  let categoryNamesById: [String: String]
  let isPinned: Bool
  let isUnread: Bool
  let item: MailShellThreadListItem
  let preferences: InboxPreferences
  let showsSourceConnection: Bool
  let unreadIndicatorSize: CGFloat

  private var thread: MailboxThread {
    item.thread
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      ZStack {
        if isUnread {
          Circle()
            .fill(MailTheme.accent)
            .frame(width: unreadIndicatorSize, height: unreadIndicatorSize)
        }
      }
      .frame(width: unreadIndicatorSize, height: unreadIndicatorSize * 2.5)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: rowSpacing) {
        HStack(alignment: .firstTextBaseline) {
          Text(thread.latestMessage.from ?? "Unknown sender")
            .font(.subheadline.weight(isUnread ? .semibold : .regular))
            .lineLimit(1)
          Spacer()
          Text(receivedDate)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack {
          Text(thread.latestMessage.subject)
            .font(.subheadline.weight(isUnread ? .semibold : .regular))
            .lineLimit(1)
            .accessibilityIdentifier("mail-thread-subject")
            .accessibilityValue(isUnread ? "Unread" : "Read")
          if thread.messages.count > 1 {
            Text("\(thread.messages.count)")
              .font(.caption.bold())
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(.secondary.opacity(0.15), in: Capsule())
              .accessibilityIdentifier("mail-thread-message-count")
          }
        }

        if preferences.previewLength != .none {
          Text(thread.latestMessage.snippet)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(preferences.previewLength.rawValue)
        }

        if showsMetadata {
          HStack(spacing: 8) {
            if showsSourceConnection {
              Label(item.sourceConnectionDisplayName, systemImage: "tray")
                .lineLimit(1)
            }
            if let categoryName {
              Text(categoryName)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(MailTheme.accent.opacity(0.12), in: Capsule())
            }
            if isPinned {
              Image(systemName: "pin.fill")
                .accessibilityLabel("Pinned")
            }
            if showsAttachmentState {
              Image(systemName: "paperclip")
                .accessibilityLabel("Has attachments")
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, verticalPadding)
    .accessibilityIdentifier(
      showsAttachmentState
        ? "mailbox-thread-\(thread.latestMessage.subject)-with-attachments" : "mailbox-thread"
    )
  }

  private var categoryName: String? {
    guard preferences.showsCategoryBadges,
      let categoryId = thread.latestMessage.categoryId
    else { return nil }
    return categoryNamesById[categoryId]
  }

  private var rowSpacing: CGFloat {
    switch preferences.threadDensity {
    case .compact:
      return 4
    case .comfortable:
      return 8
    case .spacious:
      return 12
    }
  }

  private var showsMetadata: Bool {
    showsSourceConnection || categoryName != nil || isPinned || showsAttachmentState
  }

  private var showsAttachmentState: Bool {
    preferences.showsAttachmentIndicators && thread.latestMessage.hasAttachments
  }

  private var verticalPadding: CGFloat {
    switch preferences.threadDensity {
    case .compact:
      return 0
    case .comfortable:
      return 4
    case .spacious:
      return 8
    }
  }

  private var receivedDate: String {
    Date(
      timeIntervalSince1970:
        TimeInterval(thread.latestMessage.providerInternalDateMilliseconds) / 1_000
    )
    .formatted(Self.receivedDateFormat)
  }
}

private struct ThreadSnoozeMenu: View {
  let thread: MailboxThread
  var allowsSnooze = true
  @Bindable var viewModel: ThreadSnoozeViewModel

  @ViewBuilder
  var body: some View {
    Menu {
      ForEach(ThreadSnoozePreset.allCases) { preset in
        Button(preset.title) {
          Task { await viewModel.snooze(thread, preset: preset) }
        }
        .accessibilityIdentifier("mail-snooze-\(preset.rawValue)")
      }
    } label: {
      Label(
        viewModel.snoozedThreadIds.contains(thread.id) ? "Change Snooze" : "Snooze",
        systemImage: "clock.arrow.circlepath"
      )
    }
    .disabled(viewModel.isUpdating(thread.id) || !allowsSnooze)

    if viewModel.snoozedThreadIds.contains(thread.id) {
      Button {
        Task { await viewModel.cancel(thread.id) }
      } label: {
        Label("Cancel Snooze", systemImage: "clock.badge.xmark")
      }
      .accessibilityIdentifier("mail-snooze-cancel")
      .disabled(viewModel.isUpdating(thread.id))
    }
  }
}

private struct FollowUpNudgeMenu: View {
  let connection: MailboxConnection
  let thread: MailboxThread
  let viewModel: FollowUpNudgeViewModel

  @ViewBuilder
  var body: some View {
    if viewModel.isEligible(thread, connection: connection) {
      Menu {
        ForEach(FollowUpNudgePreset.allCases) { preset in
          Button(preset.title) {
            Task {
              await viewModel.schedule(
                thread,
                preset: preset,
                connection: connection
              )
            }
          }
          .accessibilityIdentifier("mail-follow-up-\(preset.rawValue)")
        }
      } label: {
        Label(
          viewModel.nudgeThreadIds.contains(thread.id)
            ? "Change Follow-Up" : "Schedule Follow-Up",
          systemImage: "bell.badge"
        )
      }
      .disabled(viewModel.isUpdating(thread.id))
    }

    if viewModel.nudgeThreadIds.contains(thread.id) {
      Button {
        Task { await viewModel.cancel(thread.id) }
      } label: {
        Label("Cancel Follow-Up", systemImage: "bell.slash")
      }
      .accessibilityIdentifier("mail-follow-up-cancel")
      .disabled(viewModel.isUpdating(thread.id))
    }
  }
}

private struct FollowUpNudgeSuggestionCard: View {
  let accept: () -> Void
  @State private var isDismissed = false

  var body: some View {
    if !isDismissed {
      VStack(alignment: .leading, spacing: 10) {
        Label("Waiting for a reply?", systemImage: "bell.badge")
          .font(.headline)
        Text(
          "Set a private Follow-Up Nudge. It stays on your trusted devices and never sends a message."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        HStack {
          Button("Not Now") { isDismissed = true }
          Button("Remind Me Tomorrow", action: accept)
            .buttonStyle(.borderedProminent)
        }
      }
      .padding()
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
      .accessibilityIdentifier("follow-up-nudge-suggestion")
    }
  }
}

private struct FollowUpNudgeStatusCard: View {
  let thread: MailboxThread
  let viewModel: FollowUpNudgeViewModel

  var body: some View {
    HStack(spacing: 12) {
      Label("Follow-Up Due", systemImage: "bell.badge.fill")
        .font(.headline)
      Spacer()
      Button("Clear") {
        Task { await viewModel.cancel(thread.id) }
      }
      .disabled(viewModel.isUpdating(thread.id))
    }
    .padding()
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    .accessibilityIdentifier("follow-up-nudge-overdue")
  }
}

private struct ThreadSnoozeSettingsPanel: View {
  @Bindable var viewModel: ThreadSnoozeViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Return to Attention")
        .font(.headline)
      Toggle(
        "Return to Attention",
        isOn: Binding(
          get: { viewModel.preferences.returnToAttentionEnabled },
          set: { isEnabled in
            Task { await viewModel.setReturnToAttentionEnabled(isEnabled) }
          }
        )
      )
      .accessibilityIdentifier("mail-snooze-return-to-attention")
      .disabled(viewModel.isUpdatingPreferences)
      Text(
        "Allow due Snoozes, Send Reminders, and Follow-Up Nudges to request attention when "
          + "Profile and device policies permit."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    }
  }
}

private struct ProviderMailActionButtons: View {
  let actions: Set<ProviderMailAction>
  let moveDestinations: [ProviderMailbox]
  let perform: (ProviderMailAction, ProviderMailbox?) -> Void

  @ViewBuilder
  var body: some View {
    if actions.contains(.markRead) {
      Button("Mark Read") { perform(.markRead, nil) }
        .accessibilityIdentifier("mail-action-mark-read")
    }
    if actions.contains(.markUnread) {
      Button("Mark Unread") { perform(.markUnread, nil) }
        .accessibilityIdentifier("mail-action-mark-unread")
    }
    if actions.contains(.archive) {
      Button("Archive") { perform(.archive, nil) }
        .accessibilityIdentifier("mail-action-archive")
    }
    if actions.contains(.move), !moveDestinations.isEmpty {
      Menu("Move to") {
        ForEach(moveDestinations, id: \.id) { mailbox in
          Button(mailbox.title) { perform(.move, mailbox) }
            .accessibilityIdentifier("mail-action-move-destination")
        }
      }
      .accessibilityIdentifier("mail-action-move")
    }
    if actions.contains(.delete) {
      Button("Delete", role: .destructive) { perform(.delete, nil) }
        .accessibilityIdentifier("mail-action-delete")
    }
    if actions.contains(.restore) {
      Button("Restore") { perform(.restore, nil) }
    }
    if actions.contains(.notSpam) {
      Button("Not Spam") { perform(.notSpam, nil) }
    }
    if actions.contains(.spam) {
      Button("Mark as Spam") { perform(.spam, nil) }
    }
    if actions.contains(.star) {
      Button("Star") { perform(.star, nil) }
    }
    if actions.contains(.unstar) {
      Button("Unstar") { perform(.unstar, nil) }
    }
  }
}

private enum MailShellReaderErrorSource {
  case categoryOverride
  case mailAction
  case other
}

private enum UnsubscribeActionExecutionResult {
  case openedPage
  case requestSent
}

private struct UnsubscribeActionExecutionError: LocalizedError {
  let errorDescription: String?
}

struct MailShellReadTaskOwners {
  private var owners: [StableProviderMessageIdentity: UUID] = [:]

  var isEmpty: Bool { owners.isEmpty }

  mutating func begin(_ messageId: StableProviderMessageIdentity) -> UUID {
    let owner = UUID()
    owners[messageId] = owner
    return owner
  }

  mutating func cancel(_ messageId: StableProviderMessageIdentity) {
    owners[messageId] = nil
  }

  mutating func finish(_ messageId: StableProviderMessageIdentity, owner: UUID) -> Bool {
    guard owners[messageId] == owner else { return false }
    owners[messageId] = nil
    return true
  }

  mutating func removeAll() {
    owners.removeAll()
  }
}

struct MailShellPendingReadBatch {
  private var messages: [StableProviderMessageIdentity: MailboxMessageMetadata] = [:]

  var isEmpty: Bool { messages.isEmpty }

  mutating func enqueue(_ message: MailboxMessageMetadata) {
    messages[message.id] = message
  }

  mutating func cancel(_ messageId: StableProviderMessageIdentity) {
    messages[messageId] = nil
  }

  mutating func removeAll() {
    messages.removeAll()
  }

  mutating func takeNextVisible(
    _ visibleMessageIds: Set<StableProviderMessageIdentity>
  ) -> (connectionId: MailboxConnectionId, messages: [MailboxMessageMetadata])? {
    let visibleMessages = messages.values.filter { visibleMessageIds.contains($0.id) }
    messages = Dictionary(uniqueKeysWithValues: visibleMessages.map { ($0.id, $0) })
    guard
      let connectionId = visibleMessages.min(by: {
        $0.providerInternalDateMilliseconds < $1.providerInternalDateMilliseconds
      })?.connectionId
    else { return nil }
    let batch = visibleMessages.filter { $0.connectionId == connectionId }.sorted {
      $0.providerInternalDateMilliseconds < $1.providerInternalDateMilliseconds
    }
    for message in batch {
      messages[message.id] = nil
    }
    return (connectionId, batch)
  }
}

struct MailShellReadBatchTaskOwner {
  private var owner: UUID?

  var hasOwner: Bool { owner != nil }

  mutating func begin() -> UUID {
    let owner = UUID()
    self.owner = owner
    return owner
  }

  mutating func cancel() {
    owner = nil
  }

  mutating func finish(_ owner: UUID) -> Bool {
    guard self.owner == owner else { return false }
    self.owner = nil
    return true
  }
}

enum MailShellMessageReadVisibility {
  static func isEligible(
    isBodyLoaded: Bool,
    bodyFrame: CGRect,
    viewportFrame: CGRect
  ) -> Bool {
    guard isBodyLoaded else { return false }
    let visibleFrame = bodyFrame.intersection(viewportFrame)
    return !visibleFrame.isNull && visibleFrame.width > 0 && visibleFrame.height > 0
  }
}

enum MailShellReaderToolbarAction: Hashable, Identifiable {
  case archive
  case category
  case delete
  case forward
  case more
  case pin
  case reply
  case replyAll

  var id: Self { self }
}

private struct MailShellReaderToolbarContext {
  let actions: [MailShellReaderToolbarAction]
  let thread: MailboxThread
  let connection: MailboxConnection
  let providerActions: Set<ProviderMailAction>
}

enum MailShellReaderToolbarLayout {
  static func usesCompactActions(
    isCompactSizeClass: Bool,
    availableWidth: CGFloat
  ) -> Bool {
    isCompactSizeClass || (availableWidth > 0 && availableWidth < 680)
  }

  // swiftlint:disable:next function_parameter_count
  static func actions(
    isCompact: Bool,
    canReply: Bool,
    canReplyAll: Bool,
    canForward: Bool,
    canCategorize: Bool,
    providerActions: Set<ProviderMailAction>
  ) -> [MailShellReaderToolbarAction] {
    var actions: [MailShellReaderToolbarAction] = []
    if canReply { actions.append(.reply) }
    guard !isCompact else {
      actions.append(.more)
      return actions
    }
    if canReplyAll { actions.append(.replyAll) }
    if canForward { actions.append(.forward) }
    if canCategorize { actions.append(.category) }
    if providerActions.contains(.archive) { actions.append(.archive) }
    if providerActions.contains(.delete) { actions.append(.delete) }
    actions.append(.pin)
    actions.append(.more)
    return actions
  }
}

struct MessageCategorySelection: Identifiable {
  let id: StableProviderMessageIdentity
  let message: MailboxMessageMetadata
  var selectedCategoryIds: Set<String>

  init(message: MailboxMessageMetadata) {
    id = message.id
    self.message = message
    selectedCategoryIds = Set(message.messageCategoryIds)
  }

  mutating func toggle(_ categoryId: String) {
    if selectedCategoryIds.contains(categoryId) {
      selectedCategoryIds.remove(categoryId)
    } else {
      selectedCategoryIds.insert(categoryId)
    }
  }

  mutating func retainAvailableChoices(_ choices: [MessageCategoryChoice]) {
    selectedCategoryIds.formIntersection(choices.map(\.id))
  }

  func filteredChoices(
    _ choices: [MessageCategoryChoice],
    query: String
  ) -> [MessageCategoryChoice] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return choices }
    return choices.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }
}

// swiftlint:disable:next type_body_length
struct MailShellConversationReader: View {
  enum MessageHorizontalPlacement: Equatable {
    case leading
    case trailing
  }

  @Bindable var blockedSenderStore: BlockedSenderStore
  var bottomScrollContentMargin: CGFloat = 0
  let connections: [MailboxConnection]
  var composePreferences: ComposePreferences = .defaults
  @Bindable var featureSuggestionStore: FeatureSuggestionPreferenceStore
  var followUpNudgeViewModel: FollowUpNudgeViewModel?
  @Bindable var inboxViewModel: GmailInboxViewModel
  let isConnectionBusy: Bool
  @Bindable var mailAssistanceViewModel: MailAssistanceViewModel
  @Bindable var mailActionViewModel: GmailMailActionViewModel
  let messageReader: MailboxMessageReading
  @Bindable var muteViewModel: ThreadMuteViewModel
  @Bindable var pinViewModel: PinViewModel
  @Bindable var snoozeViewModel: ThreadSnoozeViewModel
  @Bindable var selection: MailShellSelectionModel
  let session: ProductAccountSessionSnapshot
  var profileId: MailProfileId?
  var readingPreferences: ReadingPreferences = .defaults
  var revalidateTrustedDevice: () async -> Bool = { true }
  var allowsProactiveSuggestions = true
  var allowsContentReveal = true
  var contentPresentationDismissal = MailPresentationDismissalCoordinator()
  var categoryChoices: [MessageCategoryChoice] = []
  var createCustomCategory: (CustomCategoryEditorDraft) async throws -> CustomCategory = { _ in
    throw CustomCategorySyncError.invalidPayload
  }
  /// Presents a prepared reply or forward in the mail-shell-owned composer.
  var presentCompositionDraft: (MailShellCompositionDraft) -> Void = { _ in }
  var signatures: SignaturePreferences = .empty
  var sendingIdentities: [SendingIdentity] = []

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var bodyLoadCoordinator = MailShellThreadBodyLoadCoordinator()
  @State private var calendarReview: CalendarEventReview?
  @State private var calendarReviewDismissalIdentifier: String?
  @State private var calendarReviewService = CalendarEventReviewService()
  @State private var categorySelection: MessageCategorySelection?
  @State private var completedUnsubscribeIdentifiers: Set<String> = []
  @State private var contactReview: ContactReview?
  @State private var contactReviewDismissalIdentifier: String?
  @State private var contactReviewService = ContactReviewService()
  @State private var readerErrorConnectionId: MailboxConnectionId?
  @State private var readerErrorMessage: String?
  @State private var readerErrorSource: MailShellReaderErrorSource?
  @State private var proseCalendarCandidates:
    [StableProviderMessageIdentity: ProseCalendarEventCandidate] = [:]
  @State private var proseCalendarDetectionGenerations: [StableProviderMessageIdentity: UUID] = [:]
  @State private var proseCalendarDetectionTasks:
    [StableProviderMessageIdentity: Task<Void, Never>] = [:]
  @State private var proseDuplicateReview: CalendarEventReview?
  @State private var pendingReadBatch = MailShellPendingReadBatch()
  @State private var readBatchTask: Task<Void, Never>?
  @State private var readBatchTaskOwner = MailShellReadBatchTaskOwner()
  @State private var readTaskOwners = MailShellReadTaskOwners()
  @State private var readTasks: [StableProviderMessageIdentity: Task<Void, Never>] = [:]
  @State private var readerAvailableWidth: CGFloat = 0
  @State private var readerScrollOffsetY: CGFloat = 0
  @State private var readerScrollPosition = ScrollPosition(
    idType: StableProviderMessageIdentity.self
  )
  @State private var readerViewportFrame = CGRect.zero
  @State private var sourceInspectionMessage: MailboxMessageMetadata?
  @State private var translationPresentation: MailTranslationPresentation?
  @State private var showsUnderstandingAssistance = false
  @State private var understandingCurrentInputVersion = MailAssistanceInputVersion()
  @State private var understandingErrorMessage: String?
  @State private var visibleReadMessageIds: Set<StableProviderMessageIdentity> = []

  var body: some View {
    readerSelectionContent
      .background(MailTheme.canvas)
      .overlay {
        bulkActionProgressOverlay
      }
      .sheet(item: $categorySelection) { selection in
        MessageCategorySelector(
          categoryChoices: categoryChoices,
          createCustomCategory: createCustomCategory,
          selection: selection,
          apply: { categoryIds in
            await applyCategories(categoryIds, to: selection.message)
          }
        )
      }
      .alert("Message action failed", isPresented: readerErrorBinding) {
        readerErrorActions
      } message: {
        Text(readerErrorMessage ?? "The message action could not be completed.")
      }
      .onChange(of: selection.selectedThreadIds) { _, _ in
        resetSelectionState()
      }
      .background {
        contentPresentationDismissalObserver
      }
  }

  @ViewBuilder
  private var bulkActionProgressOverlay: some View {
    if let progress = mailActionViewModel.bulkActionProgress {
      VStack(spacing: 8) {
        ProgressView(
          value: Double(progress.completedConnectionCount),
          total: Double(progress.totalConnectionCount)
        )
        Text(
          "\(progress.completedConnectionCount) of \(progress.totalConnectionCount) Mailbox Connections"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding()
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
  }

  private var contentPresentationDismissalObserver: some View {
    MailContentPresentationDismissalObserver(
      coordinator: contentPresentationDismissal
    ) {
      guard
        calendarReview != nil || calendarReviewDismissalIdentifier != nil
          || contactReview != nil || contactReviewDismissalIdentifier != nil
          || categorySelection != nil || readerErrorMessage != nil || !readTasks.isEmpty
          || !readTaskOwners.isEmpty || readerErrorConnectionId != nil
          || readerErrorSource != nil || sourceInspectionMessage != nil
          || translationPresentation != nil || showsUnderstandingAssistance
          || understandingErrorMessage != nil
          || mailAssistanceViewModel.preview != nil
      else { return }
      calendarReview = nil
      calendarReviewDismissalIdentifier = nil
      contactReview = nil
      contactReviewDismissalIdentifier = nil
      MailProfileContentPresentationDismissal.dismissReader(
        categorySelection: &categorySelection,
        messageActionError: &readerErrorMessage
      )
      for task in readTasks.values { task.cancel() }
      readTasks.removeAll()
      readTaskOwners.removeAll()
      readerErrorConnectionId = nil
      readerErrorSource = nil
      sourceInspectionMessage = nil
      translationPresentation = nil
      showsUnderstandingAssistance = false
      understandingErrorMessage = nil
      mailAssistanceViewModel.discardPreview()
    }
  }

  private func resetSelectionState() {
    bodyLoadCoordinator.reset()
    categorySelection = nil
    completedUnsubscribeIdentifiers = []
    contactReview = nil
    contactReviewDismissalIdentifier = nil
    proseCalendarCandidates = [:]
    proseCalendarDetectionGenerations = [:]
    for task in proseCalendarDetectionTasks.values { task.cancel() }
    proseCalendarDetectionTasks.removeAll()
    proseDuplicateReview = nil
    sourceInspectionMessage = nil
    translationPresentation = nil
    showsUnderstandingAssistance = false
    understandingErrorMessage = nil
    mailAssistanceViewModel.discardPreview()
    for task in readTasks.values { task.cancel() }
    readBatchTask?.cancel()
    readBatchTask = nil
    readBatchTaskOwner.cancel()
    readTasks.removeAll()
    readTaskOwners.removeAll()
    pendingReadBatch.removeAll()
    visibleReadMessageIds.removeAll()
    readerErrorConnectionId = nil
    readerErrorMessage = nil
    readerErrorSource = nil
    mailActionViewModel.clearError()
    pinViewModel.clearError()
    snoozeViewModel.clearError()
    followUpNudgeViewModel?.clearError()
  }

  @ViewBuilder
  private var readerErrorActions: some View {
    if let readerErrorConnectionId,
      let connection = connections.first(where: { $0.id == readerErrorConnectionId })
    {
      if mailActionViewModel.blockedConnectionId == connection.id {
        Button("Retry") {
          resolveBlockedAction(connection: connection, discard: false)
        }
        Button("Discard", role: .destructive) {
          resolveBlockedAction(connection: connection, discard: true)
        }
      } else if mailActionViewModel.failedConnectionId == connection.id {
        Button("Acknowledge") {
          acknowledgePendingActionFailure(connection: connection)
        }
      }
    }
    Button("OK", role: .cancel) {}
  }

  @ViewBuilder
  private var readerSelectionContent: some View {
    if selection.selectedThreadIds.count > 1 {
      ContentUnavailableView(
        "\(selection.selectedThreadIds.count) Threads Selected",
        systemImage: "checklist",
        description: Text(
          "Actions apply in separate Mailbox Connection batches. "
            + "Successful batches remain applied if another connection fails."
        )
      )
      .navigationTitle("Bulk Actions")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          bulkProviderActionMenu(
            batches: selection.bulkActionBatches(
              connections: connections,
              pinnedThreadIds: inboxViewModel.navigationSnapshot.pinnedThreadIds,
              snoozedThreadIds: inboxViewModel.navigationSnapshot.snoozedThreadIds
            )
          )
        }
      }
    } else if let thread = selection.selectedThread,
      let connection = connection(for: thread)
    {
      let providerActions = contextualProviderActions(
        thread: thread,
        connection: connection
      )
      let toolbarActions = readerToolbarActions(
        thread: thread,
        connection: connection,
        providerActions: providerActions
      )

      conversationScrollContent(for: thread, connection: connection)
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackground(.thinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
          readerToolbarContent(
            toolbarActions,
            thread: thread,
            connection: connection,
            providerActions: providerActions
          )
        }
        .sheet(item: $calendarReview) { review in
          calendarReviewSheet(for: review)
        }
        .sheet(item: $sourceInspectionMessage) { message in
          MailboxMessageSourceInspector(
            message: message,
            messageReader: messageReader,
            revalidateTrustedDevice: revalidateTrustedDevice,
            session: session
          )
        }
        .sheet(item: $translationPresentation) { presentation in
          MailTranslationView(
            presentation: presentation,
            assistanceViewModel: mailAssistanceViewModel,
            currentInputVersion: {
              guard let messageId = presentation.incomingMessageId else {
                return MailAssistanceInputVersion()
              }
              return MailTranslationRequestBuilder.incomingInputVersion(
                messageId: messageId,
                localBodyText: inboxViewModel.loadedMessageBodyText(for: messageId)
              )
            }
          )
        }
        .sheet(
          isPresented: $showsUnderstandingAssistance,
          onDismiss: {
            understandingErrorMessage = nil
            mailAssistanceViewModel.discardPreview()
          },
          content: {
            understandingAssistanceSheet(for: thread)
          }
        )
        .onChange(of: thread.messages) { _, _ in
          updateUnderstandingInputVersion(for: thread)
        }
        .modifier(
          DuplicateProseEventAlertModifier(
            calendarReview: $calendarReview,
            proseDuplicateReview: $proseDuplicateReview
          )
        )
        .sheet(item: $contactReview) { review in
          contactReviewSheet(for: review)
        }
    } else {
      ContentUnavailableView(
        "Select a thread",
        systemImage: "envelope.open",
        description: Text("Choose a thread to read its complete conversation.")
      )
    }
  }

  private func conversationScrollContent(
    for thread: MailboxThread,
    connection: MailboxConnection
  ) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        MailShellThreadSummary(thread: thread)
        followUpNudge(for: thread, connection: connection)
        Divider()
        conversationMessages(in: thread, connection: connection)
      }
      .scrollTargetLayout()
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .scrollPosition($readerScrollPosition)
    .accessibilityIdentifier("mail-conversation-reader")
    .contentMargins(.bottom, bottomScrollContentMargin, for: .scrollContent)
    .mailShellTopScrollEdgeEffectHidden()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onGeometryChange(for: CGRect.self) { geometry in
      geometry.frame(in: .global)
    } action: { newViewportFrame in
      readerViewportFrame = newViewportFrame
      readerAvailableWidth = newViewportFrame.width
      bodyLoadCoordinator.updateViewport(newViewportFrame)
    }
    .onScrollGeometryChange(for: CGFloat.self) { geometry in
      geometry.contentOffset.y
    } action: { _, newOffsetY in
      readerScrollOffsetY = newOffsetY
    }
    .overlay(alignment: .top) {
      Rectangle()
        .fill(MailTheme.separator)
        .frame(height: 1)
        .allowsHitTesting(false)
    }
    .task(id: thread.id) {
      bodyLoadCoordinator.updateViewport(readerViewportFrame)
      bodyLoadCoordinator.synchronize(thread.messages.map(\.id))
      bodyLoadCoordinator.activate()
    }
    .task(id: selection.selectedMessageScrollTarget) {
      guard let target = selection.selectedMessageScrollTarget else { return }
      await Task.yield()
      readerScrollPosition.scrollTo(id: target.messageId, anchor: .top)
      selection.clearMessageScrollTarget(target)
    }
    .onChange(of: thread.messages.map(\.id)) { _, messageIds in
      bodyLoadCoordinator.synchronize(messageIds)
    }
    .onDisappear {
      bodyLoadCoordinator.reset()
    }
  }

  @ViewBuilder
  private func calendarReviewSheet(for review: CalendarEventReview) -> some View {
    if review.origin.isProse {
      CalendarProseEventEditSheet(
        review: review,
        reviewService: calendarReviewService,
        complete: { didSave in
          if didSave, let calendarReviewDismissalIdentifier {
            featureSuggestionStore.dismiss(
              calendarReviewDismissalIdentifier,
              feature: .addToCalendar
            )
          }
          calendarReview = nil
        }
      )
    } else {
      CalendarEventReviewSheet(
        review: review,
        apply: {
          try calendarReviewService.apply(review)
          if let calendarReviewDismissalIdentifier {
            featureSuggestionStore.dismiss(
              calendarReviewDismissalIdentifier,
              feature: .addToCalendar
            )
          }
        }
      )
    }
  }

  private func understandingAssistanceSheet(for thread: MailboxThread) -> some View {
    UnderstandingAssistanceView(
      viewModel: mailAssistanceViewModel,
      currentInputVersion: understandingCurrentInputVersion,
      localErrorMessage: understandingErrorMessage,
      regenerate: { startUnderstanding(thread) },
      showSource: { showUnderstandingSource($0, in: thread) }
    )
    .presentationDetents([.medium, .large])
  }

  private func contactReviewSheet(for review: ContactReview) -> some View {
    ContactNativeReviewSheet(
      review: review,
      didComplete: {
        if let contactReviewDismissalIdentifier {
          featureSuggestionStore.dismiss(
            contactReviewDismissalIdentifier,
            feature: .addToContacts
          )
        }
        contactReview = nil
      },
      didCancel: {
        contactReview = nil
      }
    )
  }

  private func conversationMessages(
    in thread: MailboxThread,
    connection: MailboxConnection
  ) -> some View {
    ForEach(thread.messages) { message in
      conversationMessage(
        message,
        in: thread,
        connection: connection,
        loadRegistration: bodyLoadCoordinator.registration(for: message.id)
      )
      if message.id != thread.messages.last?.id {
        Divider()
          .padding(.horizontal, 16)
      }
    }
  }

  @ViewBuilder
  private func followUpNudge(
    for thread: MailboxThread,
    connection: MailboxConnection
  ) -> some View {
    if let followUpNudgeViewModel,
      followUpNudgeViewModel.overdueThreadIds.contains(thread.id)
    {
      FollowUpNudgeStatusCard(
        thread: thread,
        viewModel: followUpNudgeViewModel
      )
    } else if let followUpNudgeViewModel,
      allowsProactiveSuggestions,
      followUpNudgeViewModel.suggestedThreadIds.contains(thread.id)
    {
      FollowUpNudgeSuggestionCard(
        accept: {
          Task {
            await followUpNudgeViewModel.acceptSuggestion(
              thread,
              connection: connection
            )
          }
        }
      )
      .id(thread.id)
    }
  }

  private func showUnderstandingSource(
    _ sourceMessageId: String,
    in thread: MailboxThread
  ) {
    guard
      let message = thread.messages.first(where: {
        $0.id.rawValue == sourceMessageId
      })
    else { return }
    showsUnderstandingAssistance = false
    selection.scrollToMessage(message.id)
  }

  private func conversationMessage(
    _ message: MailboxMessageMetadata,
    in thread: MailboxThread,
    connection: MailboxConnection,
    loadRegistration: MailShellThreadBodyLoadRegistration
  ) -> some View {
    conversationMessageContent(
      message,
      in: thread,
      connection: connection,
      loadRegistration: loadRegistration
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("mail-conversation-message")
    .frame(maxWidth: .infinity, alignment: .leading)
    .id(message.id)
  }

  private func conversationMessageContent(
    _ message: MailboxMessageMetadata,
    in thread: MailboxThread,
    connection: MailboxConnection,
    loadRegistration: MailShellThreadBodyLoadRegistration
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      MailShellConversationMessageHeader(
        blockSender: { blockedSenderStore.block($0) },
        isSenderBlocked: blockedSenderStore.isBlocked(message.from),
        isLatest: message.id == thread.latestMessage.id,
        isOwnMessage: Self.messageHorizontalPlacement(
          providerStateIds: message.providerStateIds
        ) == .trailing,
        message: message,
        showSource: { sourceInspectionMessage = message },
        translate: { startTranslation(message) }
      )
      Divider()
        .overlay(Color.white.opacity(0.08))
      VStack(alignment: .leading, spacing: 12) {
        conversationMessageBody(
          message,
          in: thread,
          connection: connection,
          loadRegistration: loadRegistration
        )
        messageSuggestion(for: message, in: thread, connection: connection)
      }
    }
  }

  // swiftlint:disable:next function_body_length
  private func conversationMessageBody(
    _ message: MailboxMessageMetadata,
    in thread: MailboxThread,
    connection: MailboxConnection,
    loadRegistration: MailShellThreadBodyLoadRegistration
  ) -> some View {
    MailShellConversationMessageBody(
      adjustScrollOffset: { adjustment in
        guard adjustment != 0 else { return }
        readerScrollPosition.scrollTo(y: max(0, readerScrollOffsetY + adjustment))
      },
      authorizeLinkOpening: {
        guard allowsContentReveal else { return false }
        return await revalidateTrustedDevice()
      },
      clearBodySignal: inboxViewModel.loadedMessageBodyClearSignal(for: message.id),
      removesQuotedReplies: Self.removesQuotedReplies(from: message, in: thread),
      loadBody: { priority in
        guard await revalidateTrustedDevice() else { throw CancellationError() }
        return try await inboxViewModel.loadMessageBody(
          message,
          priority: priority,
          using: messageReader
        )
      },
      loadAttachment: { attachment in
        try await loadAttachmentAfterRevalidation {
          try await messageReader.loadMessageAttachment(
            attachment,
            message: message,
            session: session
          )
        }
      },
      loadRemoteContent: {
        guard allowsContentReveal, await revalidateTrustedDevice() else {
          throw CancellationError()
        }
        return try await inboxViewModel.loadRemoteMessageContent(
          $0,
          for: message.id,
          profileId: profileId
        )
      },
      promoteBodyLoad: {
        inboxViewModel.promoteMessageBodyLoad(message.id)
      },
      markBodyDisplayed: {
        inboxViewModel.markMessageBodyDisplayed(message.id)
        scheduleMarkRead(message, connection: connection)
      },
      markBodyHidden: {
        inboxViewModel.markMessageBodyHidden(message.id)
        cancelMarkRead(message.id)
      },
      message: message,
      onBodyLoaded: { body in
        detectProseCalendarEvent(in: body, for: message)
        updateUnderstandingInputVersion(for: thread)
      },
      releaseBodyPresentation: {
        inboxViewModel.discardLoadedMessageBodyPresentation(for: message.id)
      },
      releaseRemoteContent: {
        inboxViewModel.discardLoadedRemoteImages(for: message.id)
      },
      loadCoordinator: bodyLoadCoordinator,
      loadRegistration: loadRegistration,
      visibleViewportFrame: readerViewportFrame
    )
  }

  @ViewBuilder
  private func messageSuggestion(
    for message: MailboxMessageMetadata,
    in thread: MailboxThread,
    connection: MailboxConnection
  ) -> some View {
    if !muteViewModel.mutedThreadIds.contains(thread.id),
      let invitation = message.calendarInvitation,
      shouldPresentCalendarInvitation(invitation)
    {
      calendarInvitationSuggestion(invitation, message: message, connection: connection)
    } else if !muteViewModel.mutedThreadIds.contains(thread.id),
      let candidate = proseCalendarCandidates[message.id],
      shouldPresentProseCalendarEvent(candidate)
    {
      proseCalendarSuggestion(candidate, connection: connection)
    } else if !muteViewModel.mutedThreadIds.contains(thread.id),
      let suggestion = message.unsubscribeSuggestion,
      shouldPresentUnsubscribeSuggestion(suggestion)
    {
      unsubscribeSuggestion(suggestion, connection: connection)
    } else if !muteViewModel.mutedThreadIds.contains(thread.id),
      let candidate = ContactCandidateDetector.candidate(
        for: message,
        threadMessages: thread.messages,
        mailboxAddress: connection.mailboxAddress,
        cachedBodyText: inboxViewModel.loadedMessageBodyText(for: message.id)
      ),
      shouldPresentContactCandidate(candidate)
    {
      contactSuggestion(candidate)
    }
  }

  private func calendarInvitationSuggestion(
    _ invitation: CalendarInvitationDescriptor,
    message: MailboxMessageMetadata,
    connection: MailboxConnection
  ) -> some View {
    CalendarInvitationCard(
      loadReview: {
        try await loadCalendarReview(
          invitation,
          message: message,
          connection: connection
        )
      },
      dismiss: {
        featureSuggestionStore.dismiss(
          invitation.dismissalIdentifier,
          feature: .addToCalendar
        )
      },
      disable: {
        featureSuggestionStore.setEnabled(false, feature: .addToCalendar)
      },
      review: {
        calendarReviewDismissalIdentifier = invitation.dismissalIdentifier
        calendarReview = $0
      }
    )
    .id(invitation.dismissalIdentifier)
    .padding(.horizontal, 14)
    .padding(.bottom, 12)
  }

  private func proseCalendarSuggestion(
    _ candidate: ProseCalendarEventCandidate,
    connection: MailboxConnection
  ) -> some View {
    CalendarInvitationCard(
      title: "Calendar Event",
      message:
        "A date and time were found on this device. Review the time zone, "
        + "duration, and location in Calendar.",
      progressTitle: "Preparing Calendar review…",
      accessibilityIdentifier: "calendar-event-candidate-card",
      loadReview: {
        try await loadCalendarReview(candidate, connection: connection)
      },
      dismiss: {
        featureSuggestionStore.dismiss(
          candidate.dismissalIdentifier,
          feature: .addToCalendar
        )
      },
      disable: {
        featureSuggestionStore.setEnabled(false, feature: .addToCalendar)
      },
      review: {
        calendarReviewDismissalIdentifier = candidate.dismissalIdentifier
        if $0.origin.warnsAboutDuplicate {
          proseDuplicateReview = $0
        } else {
          calendarReview = $0
        }
      }
    )
    .id(candidate.dismissalIdentifier)
    .padding(.horizontal, 14)
    .padding(.bottom, 12)
  }

  private func unsubscribeSuggestion(
    _ suggestion: UnsubscribeSuggestion,
    connection: MailboxConnection
  ) -> some View {
    UnsubscribeSuggestionCard(
      suggestion: suggestion,
      perform: { action in
        try await performUnsubscribe(action, connection: connection)
      },
      dismiss: {
        featureSuggestionStore.dismiss(
          suggestion.mailingListIdentity.opaqueDismissalIdentifier,
          feature: .unsubscribe
        )
      },
      disable: {
        featureSuggestionStore.setEnabled(false, feature: .unsubscribe)
      },
      didSendRequest: {
        completedUnsubscribeIdentifiers.insert(
          suggestion.mailingListIdentity.opaqueDismissalIdentifier
        )
        featureSuggestionStore.dismiss(
          suggestion.mailingListIdentity.opaqueDismissalIdentifier,
          feature: .unsubscribe
        )
      }
    )
    .padding(.horizontal, 14)
    .padding(.bottom, 12)
  }

  private func contactSuggestion(_ candidate: ContactCandidate) -> some View {
    ContactCandidateCard(
      candidate: candidate,
      loadReview: {
        try await loadContactReview(candidate)
      },
      dismiss: {
        featureSuggestionStore.dismiss(
          candidate.opaqueDismissalIdentifier,
          feature: .addToContacts
        )
      },
      disable: {
        featureSuggestionStore.setEnabled(false, feature: .addToContacts)
      },
      review: {
        contactReviewDismissalIdentifier = candidate.opaqueDismissalIdentifier
        contactReview = $0
      }
    )
    .id(candidate.opaqueDismissalIdentifier)
    .padding(.horizontal, 14)
    .padding(.bottom, 12)
  }

  func loadAttachmentAfterRevalidation(
    _ load: () async throws -> Data
  ) async throws -> Data {
    guard await revalidateTrustedDevice() else { throw CancellationError() }
    return try await load()
  }

  private var readerErrorBinding: Binding<Bool> {
    Binding(
      get: { readerErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          let clearsMailActionError = readerErrorSource == .mailAction
          readerErrorConnectionId = nil
          readerErrorMessage = nil
          readerErrorSource = nil
          if clearsMailActionError {
            mailActionViewModel.clearError()
          }
        }
      }
    )
  }

  private func connection(for thread: MailboxThread) -> MailboxConnection? {
    connections.first { $0.id == thread.id.connectionId }
  }

  private func loadCalendarReview(
    _ invitation: CalendarInvitationDescriptor,
    message: MailboxMessageMetadata,
    connection: MailboxConnection
  ) async throws -> CalendarEventReview {
    guard await revalidateTrustedDevice() else { throw CancellationError() }
    let candidate = try await messageReader.loadCalendarInvitationCandidate(
      invitation,
      message: message,
      session: session
    )
    return try await calendarReviewService.prepare(
      candidate,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerMailboxIdentity.value
    )
  }

  private func loadContactReview(_ candidate: ContactCandidate) async throws -> ContactReview {
    guard await revalidateTrustedDevice() else { throw CancellationError() }
    return try await contactReviewService.prepare(candidate)
  }

  private func loadCalendarReview(
    _ candidate: ProseCalendarEventCandidate,
    connection: MailboxConnection
  ) async throws -> CalendarEventReview {
    guard await revalidateTrustedDevice() else { throw CancellationError() }
    return try await calendarReviewService.prepare(
      candidate,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerMailboxIdentity.value
    )
  }

  private func detectProseCalendarEvent(
    in body: MailboxMessageBody,
    for message: MailboxMessageMetadata
  ) {
    proseCalendarDetectionTasks[message.id]?.cancel()
    guard message.calendarInvitation == nil else {
      proseCalendarDetectionGenerations[message.id] = nil
      proseCalendarDetectionTasks[message.id] = nil
      proseCalendarCandidates[message.id] = nil
      return
    }
    let generation = UUID()
    proseCalendarDetectionGenerations[message.id] = generation
    let bodyText = body.text
    let subject = message.subject
    let providerMessageIdentity = message.id.rawValue
    proseCalendarDetectionTasks[message.id] = Task { @MainActor in
      let candidate = await Task.detached(priority: .userInitiated) {
        ProseCalendarEventDetector.detect(
          in: bodyText,
          subject: subject,
          providerMessageIdentity: providerMessageIdentity
        )
      }.value
      guard !Task.isCancelled,
        proseCalendarDetectionGenerations[message.id] == generation
      else { return }
      proseCalendarCandidates[message.id] = candidate
      proseCalendarDetectionTasks[message.id] = nil
    }
  }

  private func shouldPresentUnsubscribeSuggestion(
    _ suggestion: UnsubscribeSuggestion
  ) -> Bool {
    guard
      allowsProactiveSuggestions,
      ProactiveMessageCard.highestPriority(
        hasEvent: false,
        hasUnsubscribe: true,
        hasContact: false
      ) == .unsubscribe
    else { return false }
    let identifier = suggestion.mailingListIdentity.opaqueDismissalIdentifier
    return completedUnsubscribeIdentifiers.contains(identifier)
      || featureSuggestionStore.isVisible(
        .unsubscribe,
        dismissalIdentifier: identifier
      )
  }

  private func shouldPresentCalendarInvitation(
    _ invitation: CalendarInvitationDescriptor
  ) -> Bool {
    allowsProactiveSuggestions
      && featureSuggestionStore.isVisible(
        .addToCalendar,
        dismissalIdentifier: invitation.dismissalIdentifier
      )
  }

  private func shouldPresentProseCalendarEvent(
    _ candidate: ProseCalendarEventCandidate
  ) -> Bool {
    featureSuggestionStore.isVisible(
      .addToCalendar,
      dismissalIdentifier: candidate.dismissalIdentifier
    )
  }

  private func shouldPresentContactCandidate(_ candidate: ContactCandidate) -> Bool {
    allowsProactiveSuggestions
      && featureSuggestionStore.isVisible(
        .addToContacts,
        dismissalIdentifier: candidate.opaqueDismissalIdentifier
      )
  }

  private func performUnsubscribe(
    _ action: UnsubscribeAction,
    connection: MailboxConnection
  ) async throws -> UnsubscribeActionExecutionResult {
    guard await revalidateTrustedDevice() else { throw CancellationError() }
    switch action {
    case .oneClick(let url):
      try await UnsubscribeRequestService().sendOneClick(to: url)
      return .requestSent
    case .mailto(let message):
      try await mailActionViewModel.enqueueUnsubscribeEmail(
        message,
        through: connection,
        undoSendWindow: composePreferences.undoSendWindow
      )
      return .requestSent
    case .web:
      return .openedPage
    }
  }

  static func messageHorizontalPlacement(
    providerStateIds: [String]?
  ) -> MessageHorizontalPlacement {
    MailboxMessageCollection.role(.sent).contains(
      providerStateIds: providerStateIds,
      isSnoozed: false
    )
      ? .trailing : .leading
  }

  static func showsCategoryMenu(
    providerId: MailProviderId,
    providerStateIds: [String]?
  ) -> Bool {
    providerId == .gmail && providerStateIds?.contains("INBOX") == true
  }

  static func isCategoryMenuDisabled(
    isConnectionBusy: Bool,
    isAssigningCategory: Bool
  ) -> Bool {
    isConnectionBusy || isAssigningCategory
  }

  static func isForwardDisabled(
    readerMutationIsDisabled: Bool,
    isLoadingMessageBody: Bool
  ) -> Bool {
    readerMutationIsDisabled || isLoadingMessageBody
  }

  static func removesQuotedReplies(
    from message: MailboxMessageMetadata,
    in thread: MailboxThread
  ) -> Bool {
    thread.messages.count > 1 && message.id != thread.messages.last?.id
  }

  private var readerUsesCompactToolbar: Bool {
    MailShellReaderToolbarLayout.usesCompactActions(
      isCompactSizeClass: horizontalSizeClass == .compact,
      availableWidth: readerAvailableWidth
    )
  }

  func togglePin(
    _ threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity
  ) async {
    await pinViewModel.togglePin(threadId, anchorMessageId: anchorMessageId)
  }

  func toggleMute(_ thread: MailboxThread) async {
    await muteViewModel.toggleMute(thread)
  }

  private func readerToolbarActions(
    thread: MailboxThread,
    connection: MailboxConnection,
    providerActions: Set<ProviderMailAction>
  ) -> [MailShellReaderToolbarAction] {
    let message = thread.latestMessage
    let canCategorize = Self.showsCategoryMenu(
      providerId: connection.providerId,
      providerStateIds: message.providerStateIds
    )

    return MailShellReaderToolbarLayout.actions(
      isCompact: readerUsesCompactToolbar,
      canReply: connection.capabilities.canReply,
      canReplyAll: connection.capabilities.canReply
        && MailShellCompositionDraft.replyAllIsApplicable(
          to: message,
          senderAddress: connection.mailboxAddress
        ),
      canForward: connection.capabilities.canForward,
      canCategorize: canCategorize,
      providerActions: providerActions
    )
  }

  @ToolbarContentBuilder
  private func readerToolbarContent(
    _ actions: [MailShellReaderToolbarAction],
    thread: MailboxThread,
    connection: MailboxConnection,
    providerActions: Set<ProviderMailAction>
  ) -> some ToolbarContent {
    let context = MailShellReaderToolbarContext(
      actions: actions,
      thread: thread,
      connection: connection,
      providerActions: providerActions
    )

    if #available(iOS 26.0, macOS 26.0, *) {
      ToolbarItem(placement: .topBarLeading) {
        readerToolbarTitle(thread: thread)
      }
      .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .topBarLeading) {
        readerToolbarTitle(thread: thread)
      }
    }

    readerToolbarItem(.reply, context: context)
    readerToolbarItem(.replyAll, context: context)
    readerToolbarItem(.forward, context: context)
    readerToolbarItem(.category, context: context)
    readerToolbarItem(.archive, context: context)
    readerToolbarItem(.delete, context: context)
    readerToolbarItem(.pin, context: context)
    readerToolbarItem(.more, context: context)
  }

  @ToolbarContentBuilder
  private func readerToolbarItem(
    _ action: MailShellReaderToolbarAction,
    context: MailShellReaderToolbarContext
  ) -> some ToolbarContent {
    if context.actions.contains(action) {
      if #available(iOS 26.0, macOS 26.0, *) {
        ToolbarItem(placement: .topBarTrailing) {
          readerToolbarAction(
            action,
            thread: context.thread,
            connection: context.connection,
            providerActions: context.providerActions
          )
        }
        .sharedBackgroundVisibility(.hidden)
      } else {
        ToolbarItem(placement: .topBarTrailing) {
          readerToolbarAction(
            action,
            thread: context.thread,
            connection: context.connection,
            providerActions: context.providerActions
          )
        }
      }
    }
  }

  private func readerToolbarTitle(thread: MailboxThread) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(thread.latestMessage.subject)
        .font(.title3)
        .bold()
        .lineLimit(1)
        .truncationMode(.tail)
        .help(thread.latestMessage.subject)
        .accessibilityIdentifier("mail-thread-title")
        .accessibilityAddTraits(.isHeader)

      Text(thread.latestMessage.from ?? "Unknown sender")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityIdentifier("mail-thread-sender")
    }
  }

  @ViewBuilder
  private func readerToolbarAction(
    _ action: MailShellReaderToolbarAction,
    thread: MailboxThread,
    connection: MailboxConnection,
    providerActions: Set<ProviderMailAction>
  ) -> some View {
    readerToolbarControl(
      action,
      message: thread.latestMessage,
      thread: thread,
      connection: connection,
      providerActions: providerActions
    )
    .mailShellToolbarActionStyle(
      foregroundStyle: action == .delete ? Color.red : MailTheme.accent
    )
  }

  @ViewBuilder
  private func readerToolbarControl(
    _ action: MailShellReaderToolbarAction,
    message: MailboxMessageMetadata,
    thread: MailboxThread,
    connection: MailboxConnection,
    providerActions: Set<ProviderMailAction>
  ) -> some View {
    switch action {
    case .reply:
      Button {
        Task {
          await prepareReply(
            message,
            replyAll: false,
            senderAddress: connection.mailboxAddress
          )
        }
      } label: {
        Label("Reply", systemImage: "arrowshape.turn.up.left")
      }
      .accessibilityIdentifier("mail-reply")
      .disabled(readerMutationIsDisabled)
    case .replyAll:
      readerReplyAllButton(message: message, connection: connection)
    case .forward:
      readerForwardButton(message: message)
    case .category:
      readerCategoryButton(message: message)
    case .archive:
      Button {
        perform(.archive, thread: thread, connection: connection)
      } label: {
        Label("Archive", systemImage: "archivebox")
      }
      .disabled(providerActionsAreDisabled(for: connection))
    case .delete:
      Button(role: .destructive) {
        perform(.delete, thread: thread, connection: connection)
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .disabled(providerActionsAreDisabled(for: connection))
    case .pin:
      readerPinButton(message: message, thread: thread)
    case .more:
      readerMoreMenu(
        message: message,
        thread: thread,
        connection: connection,
        providerActions: providerActions
      )
    }
  }

  private func readerReplyAllButton(
    message: MailboxMessageMetadata,
    connection: MailboxConnection
  ) -> some View {
    Button {
      Task {
        await prepareReply(
          message,
          replyAll: true,
          senderAddress: connection.mailboxAddress
        )
      }
    } label: {
      Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
    }
    .disabled(readerMutationIsDisabled)
  }

  private func readerForwardButton(message: MailboxMessageMetadata) -> some View {
    Button {
      Task { await prepareForward(message) }
    } label: {
      Label("Forward", systemImage: "arrowshape.turn.up.right")
    }
    .disabled(
      Self.isForwardDisabled(
        readerMutationIsDisabled: readerMutationIsDisabled,
        isLoadingMessageBody: inboxViewModel.isLoadingMessageBody(message.id)
      )
    )
  }

  private func readerCategoryButton(message: MailboxMessageMetadata) -> some View {
    Button {
      categorySelection = MessageCategorySelection(message: message)
    } label: {
      Label("Category", systemImage: "tag")
    }
    .disabled(
      Self.isCategoryMenuDisabled(
        isConnectionBusy: isConnectionBusy,
        isAssigningCategory: inboxViewModel.isAssigningCategory
      )
    )
  }

  private func readerPinButton(
    message: MailboxMessageMetadata,
    thread: MailboxThread
  ) -> some View {
    Button {
      toggleThreadPin(thread, anchorMessage: message)
    } label: {
      Label(
        pinViewModel.pinnedThreadIds.contains(thread.id) ? "Unpin" : "Pin",
        systemImage: pinViewModel.pinnedThreadIds.contains(thread.id) ? "pin.slash" : "pin"
      )
    }
    .disabled(isConnectionBusy || pinViewModel.isUpdating(thread.id))
  }

  private var readerMutationIsDisabled: Bool {
    isConnectionBusy || mailActionViewModel.isPerformingAction
  }

  private func providerActionsAreDisabled(for connection: MailboxConnection) -> Bool {
    inboxViewModel.areCachedMetadataActionsDisabled || isConnectionBusy
      || inboxViewModel.areProviderActionsDisabledDuringHistoricalBackfill(for: [connection])
      || mailActionViewModel.isPerformingAction
  }

  private func contextualProviderActions(
    thread: MailboxThread,
    connection: MailboxConnection
  ) -> Set<ProviderMailAction> {
    Self.contextualProviderActions(
      supported: connection.capabilities.providerActions,
      messages: selection.selectedMailboxMessages(
        in: thread,
        pinnedThreadIds: inboxViewModel.navigationSnapshot.pinnedThreadIds,
        snoozedThreadIds: inboxViewModel.navigationSnapshot.snoozedThreadIds
      ),
      collection: selection.selectedMailbox?.collection,
      allowsMove: true,
      allowsProviderMailboxMove: Self.allowsMoveFromProviderMailbox(connection.providerId)
    )
  }

  private func providerMoveDestinations(for connection: MailboxConnection) -> [ProviderMailbox] {
    inboxViewModel.navigationSnapshot.providerMailboxes(for: connection.id).filter {
      $0.isMoveDestination && MailboxMessageCollection.isProviderMailboxId($0.id)
    }
  }

  private func readerMoreMenu(
    message: MailboxMessageMetadata,
    thread: MailboxThread,
    connection: MailboxConnection,
    providerActions: Set<ProviderMailAction>
  ) -> some View {
    Menu {
      if readerUsesCompactToolbar {
        compactReaderMoreActions(
          message: message,
          thread: thread,
          connection: connection
        )
      }
      ProviderMailActionButtons(
        actions: readerUsesCompactToolbar
          ? providerActions : providerActions.subtracting([.archive, .delete]),
        moveDestinations: providerMoveDestinations(for: connection)
      ) { action, targetProviderMailbox in
        perform(
          action,
          targetProviderMailboxId: targetProviderMailbox?.id,
          targetProviderStateIds: targetProviderMailbox?.providerStateIds ?? [],
          thread: thread,
          connection: connection
        )
      }
      .disabled(providerActionsAreDisabled(for: connection))
      readerMuteButton(thread: thread)
      ThreadSnoozeMenu(
        thread: thread,
        allowsSnooze: selection.partialSearchResultThreadId != thread.id,
        viewModel: snoozeViewModel
      )
      if let followUpNudgeViewModel {
        FollowUpNudgeMenu(
          connection: connection,
          thread: thread,
          viewModel: followUpNudgeViewModel
        )
      }
      Divider()
      readerUnderstandingButton(for: thread)
      Button("Remove Cached Body", role: .destructive) {
        removeCachedBody(message, connection: connection)
      }
      .disabled(inboxViewModel.isLoadingMessageBody)
    } label: {
      Label("More", systemImage: "ellipsis")
    }
    .menuIndicator(.hidden)
    .accessibilityIdentifier("mail-provider-actions")
  }

  private func readerUnderstandingButton(for thread: MailboxThread) -> some View {
    Button {
      startUnderstanding(thread)
    } label: {
      Label("Understand Thread", systemImage: "sparkles")
    }
    .accessibilityIdentifier("mail-understand-thread")
  }

  @ViewBuilder
  private func compactReaderMoreActions(
    message: MailboxMessageMetadata,
    thread: MailboxThread,
    connection: MailboxConnection
  ) -> some View {
    if connection.capabilities.canReply,
      MailShellCompositionDraft.replyAllIsApplicable(
        to: message,
        senderAddress: connection.mailboxAddress
      )
    {
      readerReplyAllButton(message: message, connection: connection)
    }
    if connection.capabilities.canForward {
      readerForwardButton(message: message)
    }
    if Self.showsCategoryMenu(
      providerId: connection.providerId,
      providerStateIds: message.providerStateIds
    ) {
      readerCategoryButton(message: message)
    }
    readerPinButton(message: message, thread: thread)
  }

  private func readerMuteButton(thread: MailboxThread) -> some View {
    Button {
      Task {
        await toggleMute(thread)
        if let errorMessage = muteViewModel.errorMessage {
          readerErrorMessage = errorMessage
          readerErrorSource = .other
        }
      }
    } label: {
      Label(
        muteViewModel.mutedThreadIds.contains(thread.id) ? "Unmute" : "Mute",
        systemImage: muteViewModel.mutedThreadIds.contains(thread.id)
          ? "speaker.wave.2" : "speaker.slash"
      )
    }
    .disabled(muteViewModel.isUpdating(thread.id))
    .accessibilityIdentifier("mail-thread-mute")
  }

  private func toggleThreadPin(
    _ thread: MailboxThread,
    anchorMessage: MailboxMessageMetadata
  ) {
    Task {
      await togglePin(thread.id, anchorMessageId: anchorMessage.id)
      if let errorMessage = pinViewModel.errorMessage {
        readerErrorMessage = errorMessage
        readerErrorSource = .other
      }
    }
  }

  private func removeCachedBody(
    _ message: MailboxMessageMetadata,
    connection: MailboxConnection
  ) {
    do {
      try messageReader.removeCachedMessageBody(message: message, session: session)
      inboxViewModel.discardLoadedMessageBody(for: message.id)
      if let thread = selection.selectedThread {
        updateUnderstandingInputVersion(for: thread)
      }
      readerErrorMessage = nil
      readerErrorSource = nil
    } catch {
      readerErrorConnectionId = connection.id
      readerErrorMessage = error.localizedDescription
      readerErrorSource = .other
    }
  }

  private func startUnderstanding(_ thread: MailboxThread) {
    showsUnderstandingAssistance = true
    understandingErrorMessage = nil
    mailAssistanceViewModel.discardPreview()
    updateUnderstandingInputVersion(for: thread)
    Task {
      do {
        let request = try UnderstandingAssistanceRequestBuilder().makeRequest(
          for: thread,
          profileId: mailAssistanceViewModel.activeProfileId,
          localeIdentifier: Locale.current.identifier,
          localBodyText: inboxViewModel.loadedMessageBodyText(for:)
        )
        understandingCurrentInputVersion = request.context.inputVersion
        _ = await mailAssistanceViewModel.perform(request)
      } catch is CancellationError {
      } catch {
        understandingErrorMessage =
          (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
    }
  }

  private func startTranslation(_ message: MailboxMessageMetadata) {
    do {
      translationPresentation = try MailTranslationRequestBuilder.incomingMessage(
        messageId: message.id,
        localBodyText: inboxViewModel.loadedMessageBodyText(for: message.id),
        profileId: mailAssistanceViewModel.activeProfileId
      )
      readerErrorMessage = nil
      readerErrorSource = nil
    } catch {
      readerErrorMessage =
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      readerErrorSource = .other
    }
  }

  private func updateUnderstandingInputVersion(for thread: MailboxThread) {
    guard showsUnderstandingAssistance || mailAssistanceViewModel.preview != nil else { return }
    understandingCurrentInputVersion = UnderstandingAssistanceRequestBuilder.inputVersion(
      for: thread,
      localBodyText: inboxViewModel.loadedMessageBodyText(for:)
    )
  }

  private func applyCategories(
    _ categoryIds: Set<String>,
    to message: MailboxMessageMetadata
  ) async -> String? {
    let selectedThreadId = selection.selectedThreadId
    inboxViewModel.clearCategoryOverrideError()
    await inboxViewModel.setCategories(Array(categoryIds).sorted(), for: message)
    let errorMessage = inboxViewModel.categoryOverrideErrorMessage
    inboxViewModel.clearCategoryOverrideError()
    guard selectedThreadId == message.threadIdentity,
      selection.selectedThreadId == selectedThreadId
    else { return "The selected conversation changed before categories were applied." }
    if let errorMessage {
      readerErrorConnectionId = message.connectionId
      readerErrorMessage = errorMessage
      readerErrorSource = .categoryOverride
      return errorMessage
    }
    if readerErrorSource == .categoryOverride {
      readerErrorConnectionId = nil
      readerErrorMessage = nil
      readerErrorSource = nil
    }
    return nil
  }

  @ViewBuilder
  private func bulkProviderActionMenu(
    batches: [MailboxBulkActionBatch]
  ) -> some View {
    let messages = batches.flatMap(\.messages)
    let moveDestinations = bulkMoveDestinations(batches: batches)
    let actions = Self.contextualProviderActions(
      supported: selection.bulkProviderActions(connections: connections),
      messages: messages,
      collection: selection.selectedMailbox?.collection,
      allowsMove: !moveDestinations.isEmpty,
      allowsProviderMailboxMove: batches.allSatisfy {
        Self.allowsMoveFromProviderMailbox($0.connection.providerId)
      }
    )
    if !actions.isEmpty {
      Menu {
        ProviderMailActionButtons(
          actions: actions.subtracting([.move]),
          moveDestinations: []
        ) { action, _ in
          performBulk(action, batches: batches)
        }
        if actions.contains(.move) {
          Menu("Move to") {
            ForEach(moveDestinations) { destination in
              Button(destination.title) {
                guard let targetedBatches = destination.targeting(batches) else { return }
                performBulk(.move, batches: targetedBatches)
              }
            }
          }
        }
      } label: {
        Label("Actions", systemImage: "ellipsis.circle")
      }
      .accessibilityIdentifier("mail-provider-actions")
      .disabled(
        batches.isEmpty || inboxViewModel.areCachedMetadataActionsDisabled || isConnectionBusy
          || inboxViewModel.areProviderActionsDisabledDuringHistoricalBackfill(
            for: batches.map(\.connection)
          )
          || mailActionViewModel.isPerformingAction
      )
    }
  }

  static func contextualProviderActions(
    supported: Set<ProviderMailAction>,
    messages: [MailboxMessageMetadata],
    collection: MailboxMessageCollection?,
    allowsMove: Bool,
    allowsProviderMailboxMove: Bool
  ) -> Set<ProviderMailAction> {
    var actions = supported
    if collection != .role(.inbox) {
      actions.remove(.archive)
    }
    let isProviderMailbox =
      if case .some(.providerMailbox) = collection {
        true
      } else {
        false
      }
    if !allowsMove
      || (collection != .role(.inbox)
        && (!isProviderMailbox || !allowsProviderMailboxMove))
    {
      actions.remove(.move)
    }
    let messagesAreTrash =
      !messages.isEmpty && messages.allSatisfy { $0.belongs(to: .trash) }
    let messagesAreSpam =
      !messages.isEmpty && messages.allSatisfy { $0.belongs(to: .spam) }
    if collection != .role(.trash) && !messagesAreTrash {
      actions.remove(.restore)
    }
    if collection != .role(.spam) && !messagesAreSpam {
      actions.remove(.notSpam)
    }
    if collection == .role(.trash) || collection == .role(.spam) || messagesAreTrash
      || messagesAreSpam
      || collection == .role(.sent)
      || messages.contains(where: { $0.belongs(to: .drafts) || $0.belongs(to: .sent) })
    {
      actions.remove(.spam)
    }
    if messages.contains(where: {
      $0.providerStateIds?.contains(EWSProviderMessage.archiveHierarchyStateId) == true
    }) {
      actions.subtract([.move, .restore, .spam])
    }
    return actions
  }

  static func allowsMoveFromProviderMailbox(_ providerId: MailProviderId) -> Bool {
    providerId == .gmail || providerId == .microsoftGraph
      || providerId == .exchangeWebServices
  }

  private func bulkMoveDestinations(
    batches: [MailboxBulkActionBatch]
  ) -> [MailboxBulkMoveDestination] {
    let connectionIds = batches.map(\.connection.id)
    let mailboxesByConnection = Dictionary(
      uniqueKeysWithValues: connectionIds.map { connectionId in
        (
          connectionId,
          inboxViewModel.navigationSnapshot.providerMailboxes(for: connectionId)
            .filter {
              $0.isMoveDestination && MailboxMessageCollection.isProviderMailboxId($0.id)
            }
        )
      }
    )
    return MailboxBulkMoveDestination.shared(
      connectionIds: connectionIds,
      providerMailboxesByConnection: mailboxesByConnection
    )
  }

  private func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String? = nil,
    targetProviderStateIds: Set<String> = [],
    thread: MailboxThread,
    connection: MailboxConnection
  ) {
    performBulk(
      action,
      batches: [
        MailboxBulkActionBatch(
          connection: connection,
          messages: selection.selectedMailboxMessages(
            in: thread,
            pinnedThreadIds: inboxViewModel.navigationSnapshot.pinnedThreadIds,
            snoozedThreadIds: inboxViewModel.navigationSnapshot.snoozedThreadIds
          ),
          sourceProviderMailboxId: selection.selectedMailbox?.collection?
            .providerMailboxMoveSourceId,
          targetProviderMailboxId: targetProviderMailboxId,
          targetProviderStateIds: targetProviderStateIds
        )
      ]
    )
  }

  private func performBulk(
    _ action: ProviderMailAction,
    batches: [MailboxBulkActionBatch]
  ) {
    mailActionViewModel.startPendingAction {
      guard await revalidateTrustedDevice() else { return }
      let deferredConnectionIds = inboxViewModel.historicalBackfillConnectionIds(
        for: batches.map(\.connection)
      )
      guard
        let result = await mailActionViewModel.performBulk(
          action,
          batches: batches,
          deferredPendingActionConnectionIds: deferredConnectionIds,
          onEnqueued: { connection in
            _ = await inboxViewModel.reloadLocal(
              connection: connection,
              refreshesNavigationSnapshot: !inboxViewModel.isHistoricalBackfillRunning(
                for: [connection]
              )
            )
          },
          onDeferredCompletion: { connection in
            _ = await inboxViewModel.reloadLocal(connection: connection)
          },
          shouldDeferPendingActions: { connection in
            inboxViewModel.isHistoricalBackfillRunning(for: [connection])
          }
        )
      else { return }
      if readingPreferences.marksReadOnArchiveOrDelete,
        action == .archive || action == .delete
      {
        await markReadAfterAction(batches, excluding: Set(result.failures.map(\.connectionId)))
      }
      let attemptedConnections = batches.map(\.connection)
      let errorMessage = mailActionViewModel.errorMessage
      for connection in attemptedConnections where result.shouldReloadImmediately(connection.id) {
        _ = await inboxViewModel.reloadLocal(
          connection: connection,
          refreshesNavigationSnapshot: !deferredConnectionIds.contains(connection.id)
        )
      }
      guard let errorMessage else { return }
      readerErrorConnectionId = result.failures.first?.connectionId
      readerErrorMessage = errorMessage
      readerErrorSource = .mailAction
    }
  }

  private func resolveBlockedAction(
    connection: MailboxConnection,
    discard: Bool
  ) {
    Task {
      if discard {
        await mailActionViewModel.discardBlockedAction(connection: connection)
      } else {
        await mailActionViewModel.retryBlockedAction(connection: connection)
      }
      _ = await inboxViewModel.reloadLocal(connection: connection)
      readerErrorMessage = mailActionViewModel.errorMessage
      readerErrorConnectionId = mailActionViewModel.pendingFailureConnectionId
      readerErrorSource = readerErrorMessage == nil ? nil : .mailAction
    }
  }

  private func acknowledgePendingActionFailure(connection: MailboxConnection) {
    Task {
      await mailActionViewModel.acknowledgeFailures(connection: connection)
      _ = await inboxViewModel.reloadLocal(connection: connection)
      readerErrorConnectionId = nil
      readerErrorMessage = nil
      readerErrorSource = nil
    }
  }

  private func prepareForward(_ message: MailboxMessageMetadata) async {
    let selectedThreadId = selection.selectedThreadId
    do {
      let body = try await inboxViewModel.loadMessageBody(message, using: messageReader)
      guard !Task.isCancelled, selectedThreadId == message.threadIdentity,
        selection.selectedThreadId == selectedThreadId
      else { return }
      Self.presentForward(
        message,
        body: body,
        sendingIdentityId: receivingIdentity(for: message)?.id,
        signatures: signatures,
        present: presentCompositionDraft
      )
      readerErrorMessage = nil
      readerErrorSource = nil
    } catch is CancellationError {
    } catch {
      readerErrorMessage = error.localizedDescription
      readerErrorSource = .other
    }
  }

  private func prepareReply(
    _ message: MailboxMessageMetadata,
    replyAll: Bool,
    senderAddress: String
  ) async {
    let selectedThreadId = selection.selectedThreadId
    do {
      let quotedText: String? =
        if composePreferences.includesQuotedText {
          try await inboxViewModel.loadMessageBodyText(message, using: messageReader)
        } else {
          nil
        }
      guard !Task.isCancelled, selectedThreadId == message.threadIdentity,
        selection.selectedThreadId == selectedThreadId
      else { return }
      Self.presentReply(
        to: message,
        replyAll: replyAll,
        senderAddress: senderAddress,
        quotedText: quotedText,
        sendingIdentityId: receivingIdentity(for: message)?.id,
        signatures: signatures,
        present: presentCompositionDraft
      )
      readerErrorMessage = nil
      readerErrorSource = nil
    } catch is CancellationError {
    } catch {
      readerErrorMessage = error.localizedDescription
      readerErrorSource = .other
    }
  }

  private func receivingIdentity(for message: MailboxMessageMetadata) -> SendingIdentity? {
    SendingIdentityPreferences(identities: sendingIdentities).receivingIdentity(for: message)
  }

  // swiftlint:disable function_parameter_count
  /// Presents a reply draft through the Mail Shell composer navigation entry point.
  static func presentReply(
    to message: MailboxMessageMetadata,
    replyAll: Bool,
    senderAddress: String,
    quotedText: String?,
    sendingIdentityId: SendingIdentityId?,
    signatures: SignaturePreferences,
    present: (MailShellCompositionDraft) -> Void
  ) {
    var draft: MailShellCompositionDraft =
      replyAll
      ? .replyAll(
        to: message,
        senderAddress: senderAddress,
        quotedText: quotedText,
        sendingIdentityId: sendingIdentityId
      )
      : .reply(
        to: message,
        quotedText: quotedText,
        sendingIdentityId: sendingIdentityId
      )
    draft.applyDefaultSignature(from: signatures)
    present(draft)
  }
  // swiftlint:enable function_parameter_count

  /// Presents a forward draft through the Mail Shell composer navigation entry point.
  static func presentForward(
    _ message: MailboxMessageMetadata,
    body: MailboxMessageBody,
    sendingIdentityId: SendingIdentityId?,
    signatures: SignaturePreferences,
    present: (MailShellCompositionDraft) -> Void
  ) {
    var draft = MailShellCompositionDraft.forward(
      message,
      body: body.text,
      sendingIdentityId: sendingIdentityId
    )
    draft.includeLocallyAvailableForwardAssets(from: body)
    draft.applyDefaultSignature(from: signatures)
    present(draft)
  }

  private func scheduleMarkRead(
    _ message: MailboxMessageMetadata,
    connection: MailboxConnection
  ) {
    guard message.isUnread,
      connection.capabilities.supports(.markRead),
      let delay = readingPreferences.markReadAfter.delay
    else { return }
    cancelMarkRead(message.id)
    visibleReadMessageIds.insert(message.id)
    let owner = readTaskOwners.begin(message.id)
    readTasks[message.id] = Task {
      defer {
        if readTaskOwners.finish(message.id, owner: owner) {
          readTasks[message.id] = nil
        }
      }
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard !Task.isCancelled, await revalidateTrustedDevice() else { return }
      enqueueMarkRead(message)
    }
  }

  private func cancelMarkRead(_ messageId: StableProviderMessageIdentity) {
    readTasks[messageId]?.cancel()
    readTasks[messageId] = nil
    readTaskOwners.cancel(messageId)
    pendingReadBatch.cancel(messageId)
    visibleReadMessageIds.remove(messageId)
  }

  private func enqueueMarkRead(_ message: MailboxMessageMetadata) {
    guard visibleReadMessageIds.contains(message.id) else { return }
    pendingReadBatch.enqueue(message)
    guard readBatchTask == nil else { return }
    let owner = readBatchTaskOwner.begin()
    readBatchTask = Task {
      defer {
        if readBatchTaskOwner.finish(owner) {
          readBatchTask = nil
        }
      }
      await Task.yield()
      while !Task.isCancelled, !pendingReadBatch.isEmpty {
        guard let batch = pendingReadBatch.takeNextVisible(visibleReadMessageIds) else { continue }
        let messages = batch.messages
        guard let connection = connections.first(where: { $0.id == batch.connectionId }) else {
          continue
        }
        let markedRead = await mailActionViewModel.perform(
          .markRead,
          for: messages,
          connection: connection
        )
        if markedRead {
          visibleReadMessageIds.subtract(messages.map(\.id))
          _ = await inboxViewModel.reloadLocal(connection: connection)
        } else if mailActionViewModel.isPerformingAction {
          for message in messages where visibleReadMessageIds.contains(message.id) {
            pendingReadBatch.enqueue(message)
          }
          do {
            try await Task.sleep(for: .milliseconds(50))
          } catch {
            return
          }
        }
        await Task.yield()
      }
    }
  }

  private func markReadAfterAction(
    _ batches: [MailboxBulkActionBatch],
    excluding failedConnectionIds: Set<MailboxConnectionId>
  ) async {
    for batch in batches
    where !failedConnectionIds.contains(batch.connection.id)
      && batch.connection.capabilities.supports(.markRead)
    {
      let unreadMessages = batch.messages.filter(\.isUnread)
      guard !unreadMessages.isEmpty else { continue }
      _ = await mailActionViewModel.perform(
        .markRead,
        for: unreadMessages,
        connection: batch.connection
      )
    }
  }
}

private struct CalendarInvitationCard: View {
  var title = "Calendar Invitation"
  var message = "Review this structured invitation before changing Calendar."
  var progressTitle = "Reading invitation…"
  var accessibilityIdentifier = "calendar-invitation-card"
  let loadReview: () async throws -> CalendarEventReview
  let dismiss: () -> Void
  let disable: () -> Void
  let review: (CalendarEventReview) -> Void

  @Environment(\.openURL) private var openURL
  @State private var model = CalendarInvitationCardModel()
  @State private var reviewTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: "calendar.badge.plus")
        .font(.headline)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Button("Add to Calendar") {
          reviewTask?.cancel()
          reviewTask = Task { await prepareReview() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isLoading)
        Button("Not Now", action: dismiss)
          .buttonStyle(.bordered)
          .disabled(model.isLoading)
        Menu("Options") {
          if model.canOpenSettings {
            Button("Open Settings") {
              guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
              openURL(url)
            }
          }
          Button("Never Suggest Calendar Events", role: .destructive, action: disable)
        }
        .disabled(model.isLoading)
      }
      if model.isLoading { ProgressView(progressTitle) }
    }
    .padding()
    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.tint.opacity(0.35), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(accessibilityIdentifier)
    .onDisappear { reviewTask?.cancel() }
  }

  private func prepareReview() async {
    await model.prepare(loadReview: loadReview, review: review)
  }
}

private struct CalendarProseEventEditSheet: UIViewControllerRepresentable {
  let review: CalendarEventReview
  let reviewService: CalendarEventReviewService
  let complete: (Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(review: review, reviewService: reviewService, complete: complete)
  }

  func makeUIViewController(context: Context) -> EKEventEditViewController {
    let controller = EKEventEditViewController()
    controller.eventStore = reviewService.eventStoreForEditor
    controller.event = reviewService.editableProseEvent(for: review)
    controller.editViewDelegate = context.coordinator
    return controller
  }

  func updateUIViewController(_: EKEventEditViewController, context _: Context) {}

  @MainActor
  final class Coordinator: NSObject, @preconcurrency EKEventEditViewDelegate {
    let review: CalendarEventReview
    let reviewService: CalendarEventReviewService
    let complete: (Bool) -> Void

    init(
      review: CalendarEventReview,
      reviewService: CalendarEventReviewService,
      complete: @escaping (Bool) -> Void
    ) {
      self.review = review
      self.reviewService = reviewService
      self.complete = complete
    }

    func eventEditViewController(
      _ controller: EKEventEditViewController,
      didCompleteWith action: EKEventEditViewAction
    ) {
      let didSave = action == .saved
      if didSave, let event = controller.event {
        reviewService.recordSavedProseEvent(event, for: review)
      }
      complete(didSave)
    }
  }
}

@MainActor
@Observable
final class CalendarInvitationCardModel {
  private(set) var canOpenSettings = false
  private(set) var errorMessage: String?
  private(set) var isLoading = false

  func prepare(
    loadReview: () async throws -> CalendarEventReview,
    review: (CalendarEventReview) -> Void
  ) async {
    isLoading = true
    canOpenSettings = false
    errorMessage = nil
    defer { isLoading = false }
    do {
      let loadedReview = try await loadReview()
      guard !Task.isCancelled else { return }
      review(loadedReview)
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
      if let reviewError = error as? CalendarEventReviewError,
        case .calendarAccessDenied = reviewError
      {
        canOpenSettings = true
      }
    }
  }
}

private struct ContactCandidateCard: View {
  let candidate: ContactCandidate
  let loadReview: () async throws -> ContactReview
  let dismiss: () -> Void
  let disable: () -> Void
  let review: (ContactReview) -> Void

  @Environment(\.openURL) private var openURL
  @State private var model = ContactCandidateCardModel()
  @State private var reviewTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Contact Candidate", systemImage: "person.crop.circle.badge.plus")
        .font(.headline)
      Text("\(candidate.displayName) · \(candidate.emailAddress)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text("Review this correspondent in Contacts before creating or merging a record.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Button("Add to Contacts") {
          reviewTask?.cancel()
          reviewTask = Task { await model.prepare(loadReview: loadReview, review: review) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isLoading)
        Button("Not Now", action: dismiss)
          .buttonStyle(.bordered)
          .disabled(model.isLoading)
        Menu("Options") {
          if model.canOpenSettings {
            Button("Open Settings") {
              guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
              openURL(url)
            }
          }
          Button("Never Suggest Add to Contacts", role: .destructive, action: disable)
        }
        .disabled(model.isLoading)
      }
      if model.isLoading { ProgressView("Checking Contacts…") }
    }
    .padding()
    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.tint.opacity(0.35), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("contact-candidate-card")
    .onDisappear { reviewTask?.cancel() }
  }
}

@MainActor
@Observable
final class ContactCandidateCardModel {
  private(set) var canOpenSettings = false
  private(set) var errorMessage: String?
  private(set) var isLoading = false

  func prepare(
    loadReview: () async throws -> ContactReview,
    review: (ContactReview) -> Void
  ) async {
    isLoading = true
    canOpenSettings = false
    errorMessage = nil
    defer { isLoading = false }
    do {
      let loadedReview = try await loadReview()
      guard !Task.isCancelled else { return }
      review(loadedReview)
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
      if let reviewError = error as? ContactReviewError,
        case .contactsAccessDenied = reviewError
      {
        canOpenSettings = true
      }
    }
  }
}

private struct ContactNativeReviewSheet: View {
  let review: ContactReview
  let didComplete: () -> Void
  let didCancel: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      if review.matchingContactCount > 0 {
        Text(
          review.matchingContactCount == 1
            ? "One possible email or phone match was found."
            : "\(review.matchingContactCount) possible email or phone matches were found."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding()
        Divider()
      }
      ContactNativeReviewController(
        review: review,
        didComplete: didComplete,
        didCancel: didCancel
      )
    }
  }
}

private struct ContactNativeReviewController: UIViewControllerRepresentable {
  let review: ContactReview
  let didComplete: () -> Void
  let didCancel: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(didComplete: didComplete, didCancel: didCancel)
  }

  func makeUIViewController(context: Context) -> UINavigationController {
    let controller = CNContactViewController(forUnknownContact: nativeContact)
    controller.contactStore = CNContactStore()
    controller.delegate = context.coordinator
    controller.allowsActions = true
    controller.allowsEditing = true
    return UINavigationController(rootViewController: controller)
  }

  func updateUIViewController(_: UINavigationController, context _: Context) {}

  private var nativeContact: CNMutableContact {
    let contact = CNMutableContact()
    let name = PersonNameComponentsFormatter().personNameComponents(
      from: review.candidate.displayName)
    contact.givenName = name?.givenName ?? review.candidate.displayName
    contact.middleName = name?.middleName ?? ""
    contact.familyName = name?.familyName ?? ""
    contact.organizationName = review.candidate.organizationName ?? ""
    contact.emailAddresses = [
      CNLabeledValue(label: CNLabelWork, value: review.candidate.emailAddress as NSString)
    ]
    if let phoneNumber = review.candidate.phoneNumber {
      contact.phoneNumbers = [
        CNLabeledValue(
          label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phoneNumber))
      ]
    }
    if let postalAddress = review.candidate.postalAddress {
      let address = CNMutablePostalAddress()
      address.street = postalAddress
      contact.postalAddresses = [
        CNLabeledValue(label: CNLabelWork, value: address)
      ]
    }
    if let urlString = review.candidate.urlString {
      contact.urlAddresses = [
        CNLabeledValue(label: CNLabelWork, value: urlString as NSString)
      ]
    }
    return contact
  }

  final class Coordinator: NSObject, CNContactViewControllerDelegate {
    private let didComplete: () -> Void
    private let didCancel: () -> Void

    init(didComplete: @escaping () -> Void, didCancel: @escaping () -> Void) {
      self.didComplete = didComplete
      self.didCancel = didCancel
    }

    func contactViewController(
      _: CNContactViewController,
      didCompleteWith contact: CNContact?
    ) {
      if contact == nil {
        didCancel()
      } else {
        didComplete()
      }
    }
  }
}

private struct CalendarEventReviewSheet: View {
  let review: CalendarEventReview
  let apply: () throws -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("Invitation") {
          LabeledContent("Title", value: review.reviewedTitle)
          if let startDate = review.reviewedStartDate {
            LabeledContent("Starts") {
              Text(startDate, format: .dateTime)
            }
          }
          if let endDate = review.reviewedEndDate {
            LabeledContent("Ends") {
              Text(endDate, format: .dateTime)
            }
          }
          if let location = review.candidate.location {
            LabeledContent(
              "Location",
              value: location.isEmpty ? "Remove existing location" : location
            )
          }
          if let notes = review.candidate.notes {
            LabeledContent("Notes", value: notes.isEmpty ? "Remove existing notes" : notes)
          }
        }
        Section("Calendar Change") {
          Text(actionDescription)
          if let errorMessage {
            Text(errorMessage).foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Review Event")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(actionTitle) {
            do {
              try apply()
              dismiss()
            } catch {
              errorMessage = error.localizedDescription
            }
          }
          .disabled(!review.requiresApply)
        }
      }
    }
  }

  private var actionTitle: String {
    switch review.action {
    case .alreadyAdded: "Already Added"
    case .alreadyRemoved: "Already Removed"
    case .create: "Add"
    case .remove: "Remove"
    case .update: "Update"
    }
  }

  private var actionDescription: String {
    switch review.action {
    case .alreadyAdded:
      "This exact invitation is already represented in Calendar."
    case .alreadyRemoved:
      "The cancelled event is not present in Calendar."
    case .create:
      "Add this event to your default calendar after review."
    case .remove:
      "Remove the matching event from Calendar after review."
    case .update:
      "Update the matching event with the reviewed invitation values."
    }
  }
}

private struct UnsubscribeSuggestionCard: View {
  private enum Status: Equatable {
    case failed(String)
    case idle
    case openedPage
    case requestSent
    case uncertain(String)
    case working
  }

  let suggestion: UnsubscribeSuggestion
  let perform: (UnsubscribeAction) async throws -> UnsubscribeActionExecutionResult
  let dismiss: () -> Void
  let disable: () -> Void
  let didSendRequest: () -> Void

  @Environment(\.openURL) private var openURL
  @State private var actionTask: Task<Void, Never>?
  @State private var pendingAction: UnsubscribeAction?
  @State private var status: Status = .idle

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Unsubscribe", systemImage: "envelope.badge.shield.half.filled")
        .font(.headline)
      Text("This message offers a standards-based way to leave its mailing list.")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      statusView

      if status != .requestSent {
        HStack {
          Button("Unsubscribe") {
            pendingAction = suggestion.preferredAction
          }
          .buttonStyle(.borderedProminent)
          .disabled(status == .working || suggestion.preferredAction == nil)

          Button("Not Now", action: dismiss)
            .buttonStyle(.bordered)
            .disabled(status == .working)

          if suggestion.actions.count > 1 {
            Menu("Options") {
              ForEach(
                Array(suggestion.actions.dropFirst().enumerated()),
                id: \.offset
              ) { _, action in
                Button(action.title) {
                  pendingAction = action
                }
              }
              Divider()
              Button("Never Suggest Unsubscribe", role: .destructive, action: disable)
            }
            .disabled(status == .working)
          } else {
            Menu("Options") {
              Button("Never Suggest Unsubscribe", role: .destructive, action: disable)
            }
            .disabled(status == .working)
          }
        }
      }
    }
    .padding()
    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.tint.opacity(0.35), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("unsubscribe-suggestion-card")
    .alert("Confirm Unsubscribe", isPresented: confirmationBinding) {
      Button("Cancel", role: .cancel) {
        pendingAction = nil
      }
      Button("Continue") {
        guard let action = pendingAction else { return }
        pendingAction = nil
        execute(action)
      }
    } message: {
      Text(confirmationMessage)
    }
    .onDisappear {
      guard status != .working else { return }
      actionTask?.cancel()
      actionTask = nil
    }
  }

  @ViewBuilder
  private var statusView: some View {
    switch status {
    case .idle:
      EmptyView()
    case .working:
      ProgressView("Sending request…")
    case .requestSent:
      Label("Unsubscribe request sent", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .openedPage:
      Text("The unsubscribe page opened in your browser.")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .uncertain(let message):
      VStack(alignment: .leading, spacing: 6) {
        Text(message)
          .font(.caption)
          .foregroundStyle(.orange)
        Button("Retry Explicitly") {
          pendingAction = suggestion.preferredAction
        }
        .disabled(suggestion.preferredAction == nil)
      }
    case .failed(let message):
      Text(message)
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  private var confirmationBinding: Binding<Bool> {
    Binding(
      get: { pendingAction != nil },
      set: { isPresented in
        if !isPresented { pendingAction = nil }
      }
    )
  }

  private var confirmationMessage: String {
    switch pendingAction {
    case .oneClick:
      "Send the mailing list's one-click unsubscribe request?"
    case .mailto:
      "Add the mailing list's unsubscribe email to Outbox?"
    case .web:
      "Open the mailing list's unsubscribe page in your browser?"
    case nil:
      "Continue with this unsubscribe action?"
    }
  }

  private func execute(_ action: UnsubscribeAction) {
    actionTask?.cancel()
    status = .working
    actionTask = Task {
      do {
        let result = try await perform(action)
        try Task.checkCancellation()
        switch result {
        case .requestSent:
          status = .requestSent
          didSendRequest()
        case .openedPage:
          guard case .web(let url) = action else {
            throw UnsubscribeActionExecutionError(
              errorDescription: "The unsubscribe page could not be opened."
            )
          }
          let opened = await withCheckedContinuation { continuation in
            openURL(url) { accepted in
              continuation.resume(returning: accepted)
            }
          }
          if opened {
            status = .openedPage
          } else {
            status = .failed("The unsubscribe page could not be opened.")
          }
        }
      } catch is CancellationError {
        status = .idle
      } catch let error as UnsubscribeRequestError where error == .outcomeUncertain {
        status = .uncertain(error.localizedDescription)
      } catch {
        status = .failed(error.localizedDescription)
      }
      actionTask = nil
    }
  }
}

private struct RawMessageSourceDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.emailMessage] }

  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw MailboxMessageSourceError.invalidResponse
    }
    self.data = data
  }

  func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

private struct MailboxMessageSourceInspector: View {
  private static let maximumPreviewByteCount = 256 * 1_024

  private enum Section: String, CaseIterable, Identifiable {
    case headers = "Headers"
    case raw = "Raw"

    var id: Self { self }
  }

  let message: MailboxMessageMetadata
  let messageReader: MailboxMessageReading
  let revalidateTrustedDevice: () async -> Bool
  let session: ProductAccountSessionSnapshot

  @Environment(\.dismiss) private var dismiss
  @State private var copyFeedbackTask: Task<Void, Never>?
  @State private var copiedSource = false
  @State private var errorMessage: String?
  @State private var exportData = Data()
  @State private var isExporting = false
  @State private var isLoading = true
  @State private var section = Section.headers
  @State private var source: MailboxMessageSource?

  var body: some View {
    NavigationStack {
      Group {
        if isLoading {
          ProgressView("Loading message source…")
        } else if let errorMessage {
          ContentUnavailableView {
            Label("Message source unavailable", systemImage: "exclamationmark.triangle")
          } description: {
            Text(errorMessage)
          }
        } else if let source {
          VStack(spacing: 0) {
            Picker("Source View", selection: $section) {
              ForEach(Section.allCases) { section in
                Text(section.rawValue).tag(section)
              }
            }
            .pickerStyle(.segmented)
            .padding()

            switch section {
            case .headers:
              headerList(source)
            case .raw:
              rawView(source.raw)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("Message Source")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
          Button(copiedSource ? "Copied" : "Copy Source", systemImage: "doc.on.doc") {
            copySource()
          }
          .disabled(exactData == nil)
          .accessibilityIdentifier("mail-message-source-copy")

          Button("Export EML", systemImage: "square.and.arrow.up") {
            exportSource()
          }
          .disabled(exactData == nil)
          .accessibilityIdentifier("mail-message-source-export")
        }
      }
    }
    .task(id: message.id) {
      await loadSource()
    }
    .onDisappear {
      copyFeedbackTask?.cancel()
    }
    .fileExporter(
      isPresented: $isExporting,
      document: RawMessageSourceDocument(data: exportData),
      contentType: .emailMessage,
      defaultFilename: exportFilename
    ) { result in
      if case .failure(let error) = result {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func headerList(_ source: MailboxMessageSource) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        Text(
          source.headersAreExact
            ? "Headers parsed from the provider-supplied bytes."
            : "Only provider metadata is available; these fields are not reconstructed MIME."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if source.headers.isEmpty {
          ContentUnavailableView("No readable headers", systemImage: "doc.text")
        } else {
          ForEach(Array(source.headers.enumerated()), id: \.offset) { _, header in
            VStack(alignment: .leading, spacing: 3) {
              Text(header.name)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
              Text(header.value)
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding()
    }
    .accessibilityIdentifier("mail-message-source-headers")
  }

  @ViewBuilder
  private func rawView(_ raw: MailboxRawMessageSource) -> some View {
    switch raw {
    case .exact(let data):
      ScrollView([.horizontal, .vertical]) {
        VStack(alignment: .leading, spacing: 10) {
          if !previewIsExactText(data) {
            Text(
              "Some bytes are not UTF-8 and are replaced only in this preview. "
                + "Copy and Export keep the exact provider bytes."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          if data.count > Self.maximumPreviewByteCount {
            Text(
              "Preview truncated to 256 KB. Copy and Export keep the complete provider bytes."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Text(previewText(for: data))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        }
        .padding()
      }
      .accessibilityIdentifier("mail-message-source-raw")
    case .unavailable(let reason):
      ContentUnavailableView(
        "Exact source unavailable",
        systemImage: "doc.questionmark",
        description: Text(reason)
      )
    }
  }

  private var exactData: Data? {
    guard case .exact(let data) = source?.raw else { return nil }
    return data
  }

  private var exportFilename: String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
    let sanitized = message.subject.unicodeScalars.map {
      allowed.contains($0) ? Character($0) : "-"
    }
    let value = String(sanitized).trimmingCharacters(in: .whitespacesAndNewlines)
    return String((value.isEmpty ? "Message Source" : value).prefix(80))
  }

  private func previewText(for data: Data) -> String {
    // This preview is intentionally lossy; copy and export keep the exact Data.
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: data.prefix(Self.maximumPreviewByteCount), as: UTF8.self)
  }

  private func previewIsExactText(_ data: Data) -> Bool {
    String(bytes: data.prefix(Self.maximumPreviewByteCount), encoding: .utf8) != nil
  }

  private func sourceText(for data: Data) -> String {
    // The plain-text pasteboard flavor is lossy; the email-message flavor keeps the exact Data.
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: data, as: UTF8.self)
  }

  @MainActor
  private func loadSource() async {
    isLoading = true
    errorMessage = nil
    source = nil
    guard await revalidateTrustedDevice() else {
      isLoading = false
      errorMessage = "Unlock this Mail Profile to inspect message source."
      return
    }
    do {
      source = try await messageReader.loadMessageSource(message: message, session: session)
    } catch is CancellationError {
      guard !Task.isCancelled else { return }
      isLoading = false
      return
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  private func copySource() {
    guard let data = exactData else { return }
    Task { @MainActor in
      guard await revalidateTrustedDevice() else { return }
      let rawText = sourceText(for: data)
      UIPasteboard.general.setItems(
        [
          [
            UTType.emailMessage.identifier: data,
            UTType.utf8PlainText.identifier: Data(rawText.utf8),
          ]
        ],
        options: [
          .expirationDate: Date().addingTimeInterval(5 * 60),
          .localOnly: true,
        ]
      )
      copiedSource = true
      copyFeedbackTask?.cancel()
      copyFeedbackTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        copiedSource = false
      }
    }
  }

  private func exportSource() {
    guard let data = exactData else { return }
    Task { @MainActor in
      guard await revalidateTrustedDevice() else { return }
      exportData = data
      isExporting = true
    }
  }
}

struct BlockedSendersSettingsView: View {
  let acknowledgeFailure: (MailboxConnection) async -> Void
  let connections: [MailboxConnection]
  let failedConnectionIds: Set<MailboxConnectionId>
  let pendingConnectionIds: Set<MailboxConnectionId>
  let retry: (MailboxConnection) async -> Void
  @Bindable var store: BlockedSenderStore

  var body: some View {
    Form {
      Section("Blocked Senders") {
        if store.blockedAddresses.isEmpty {
          ContentUnavailableView(
            "No Blocked Senders",
            systemImage: "hand.raised",
            description: Text("Use a message's sender menu to block an exact email address.")
          )
        } else {
          ForEach(store.blockedAddresses, id: \.rawValue) { address in
            HStack {
              Text(address.rawValue)
                .textSelection(.enabled)
              Spacer()
              Button("Unblock", role: .destructive) {
                store.unblock(address)
              }
              .accessibilityLabel("Unblock \(address.rawValue)")
            }
          }
        }
        if store.isSynchronizing {
          ProgressView("Synchronizing blocked senders…")
        }
        if let errorMessage = store.errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }

      Section("Provider Enforcement") {
        if connections.isEmpty {
          Text("No Mailbox Connections belong to this Profile.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(connections) { connection in
            HStack {
              VStack(alignment: .leading) {
                Text(connection.displayName)
                Text(enforcementStatus(for: connection))
                  .font(.caption)
                  .foregroundStyle(statusColor(for: connection))
              }
              Spacer()
              if pendingConnectionIds.contains(connection.id) {
                Button("Retry") {
                  Task { await retry(connection) }
                }
              } else if failedConnectionIds.contains(connection.id) {
                Button("Acknowledge") {
                  Task { await acknowledgeFailure(connection) }
                }
              }
            }
          }
        }
      }

      Section {
        Text(
          "Blocking matches only the normalized exact sender address. Future matching mail "
            + "moves to provider Trash when an authorized trusted device can act. Existing mail "
            + "is unchanged, and restoring mail from Trash remains available. Sender addresses "
            + "synchronize only inside end-to-end encrypted Product Sync."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Blocked Senders")
    .accessibilityIdentifier("blocked-senders-settings")
    .task { await store.synchronize() }
  }

  private func enforcementStatus(for connection: MailboxConnection) -> String {
    if pendingConnectionIds.contains(connection.id) { return "Needs retry" }
    if failedConnectionIds.contains(connection.id) { return "Failed provider move" }
    if connection.authorizationState != .authorized { return "Authorization required" }
    if !connection.capabilities.supports(.delete) { return "Provider Trash unavailable" }
    return "Ready for future matching mail"
  }

  private func statusColor(for connection: MailboxConnection) -> Color {
    if pendingConnectionIds.contains(connection.id) || failedConnectionIds.contains(connection.id) {
      return .red
    }
    if connection.authorizationState != .authorized
      || !connection.capabilities.supports(.delete)
    {
      return .secondary
    }
    return .green
  }
}

private struct MailShellConversationMessageHeader: View {
  let blockSender: (String?) -> Void
  let isSenderBlocked: Bool
  let isLatest: Bool
  let isOwnMessage: Bool
  let message: MailboxMessageMetadata
  let showSource: () -> Void
  let translate: () -> Void
  @State private var recipientsAreExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(message.from ?? "Unknown sender")
            .font(.headline)
            .lineLimit(1)
          Text(receivedDate)
            .font(.caption)
            .foregroundStyle(isOwnMessage ? Color.accentColor : Color.secondary)
        }
        Spacer(minLength: 0)
        if !isOwnMessage, NormalizedSenderAddress(message.from) != nil {
          Menu {
            if isSenderBlocked {
              Label("Sender blocked", systemImage: "hand.raised.fill")
            } else {
              Button("Block Sender", systemImage: "hand.raised", role: .destructive) {
                blockSender(message.from)
              }
            }
          } label: {
            Label("Sender Actions", systemImage: "ellipsis.circle")
              .labelStyle(.iconOnly)
          }
          .accessibilityIdentifier("message-sender-actions")
        }
        if isLatest {
          Text("Latest")
            .font(.caption.bold())
            .foregroundStyle(isOwnMessage ? Color.accentColor : Color.secondary)
        }
        Menu {
          Button("Translate Message", systemImage: "character.bubble", action: translate)
          Button("View Message Source", systemImage: "doc.text.magnifyingglass", action: showSource)
        } label: {
          Label("Message Actions", systemImage: "ellipsis")
            .labelStyle(.iconOnly)
        }
        .accessibilityIdentifier("mail-message-actions")
      }
      if !recipientLines.isEmpty {
        DisclosureGroup(isExpanded: $recipientsAreExpanded) {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(recipientLines, id: \.label) { line in
              LabeledContent(line.label, value: line.value)
            }
          }
          .font(.caption)
          .padding(.top, 4)
        } label: {
          Text(recipientSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .tint(.secondary)
        .accessibilityIdentifier("mail-message-recipients")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var recipientLines: [(label: String, value: String)] {
    var lines: [(label: String, value: String)] = []
    if let recipients = message.recipientHeaders, !recipients.isEmpty {
      lines.append(("To/Cc", recipients.joined(separator: ", ")))
    }
    if let recipients = message.bccRecipients, !recipients.isEmpty {
      lines.append(("Bcc", recipients.joined(separator: ", ")))
    }
    return lines
  }

  private var recipientSummary: String {
    guard let recipients = message.recipientHeaders, let first = recipients.first else {
      return "Recipients"
    }
    let additionalCount = recipients.count - 1 + (message.bccRecipients?.count ?? 0)
    return additionalCount == 0 ? "To/Cc: \(first)" : "To/Cc: \(first) +\(additionalCount)"
  }

  private var receivedDate: String {
    Date(timeIntervalSince1970: TimeInterval(message.providerInternalDateMilliseconds) / 1_000)
      .formatted(date: .abbreviated, time: .shortened)
  }
}

private struct MailShellConversationMessageBody: View {
  let adjustScrollOffset: (CGFloat) -> Void
  let authorizeLinkOpening: () async -> Bool
  let clearBodySignal: UUID?
  let removesQuotedReplies: Bool
  let loadBody: (MailLoadPriority) async throws -> MailboxMessageBody
  let loadAttachment: (MailboxMessageAttachment) async throws -> Data
  let loadRemoteContent: (SanitizedMessageHTML) async throws -> RemoteMessageContentLoadResult
  let promoteBodyLoad: () -> Void
  let markBodyDisplayed: () -> Void
  let markBodyHidden: () -> Void
  let message: MailboxMessageMetadata
  let onBodyLoaded: (MailboxMessageBody) -> Void
  let releaseBodyPresentation: () -> Void
  let releaseRemoteContent: () -> Void
  let loadCoordinator: MailShellThreadBodyLoadCoordinator
  let loadRegistration: MailShellThreadBodyLoadRegistration
  let visibleViewportFrame: CGRect
  @State private var bodyFrame = CGRect.zero
  @State private var isBodyLoaded = false
  @State private var isBodyVisible = false

  var body: some View {
    MailShellMessageBody(
      allowsAutomaticRemoteContent: loadRegistration.allowsAutomaticRemoteContent,
      authorizeLinkOpening: authorizeLinkOpening,
      clearSignal: clearBodySignal,
      connectionId: message.connectionId,
      messageId: message.id,
      messageSubject: message.subject,
      onDismiss: {
        isBodyLoaded = false
        updateBodyVisibility(isBodyLoaded: false)
      },
      onLoaded: {
        isBodyLoaded = true
        updateBodyVisibility(isBodyLoaded: true)
      },
      onBodyLoaded: onBodyLoaded,
      onLoadAttemptFinished: { requestId, shouldRetry in
        loadCoordinator.finishLoad(
          for: message.id,
          requestId: requestId,
          shouldRetry: shouldRetry
        )
      },
      onRetryRequested: {
        loadCoordinator.retry(message.id)
      },
      onRelease: releaseBodyPresentation,
      onReleaseRemoteContent: releaseRemoteContent,
      removesQuotedReplies: removesQuotedReplies,
      loadRequestId: loadRegistration.loadRequestId,
      usesCoordinatedLoading: true,
      loadAttachment: loadAttachment,
      loadRemoteContent: loadRemoteContent,
      load: {
        try await loadBody(loadRegistration.loadPriority)
      }
    )
    .onChange(of: loadRegistration.loadPriority) { _, priority in
      guard priority == .interactive else { return }
      promoteBodyLoad()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .onGeometryChange(for: CGRect.self) { geometry in
      geometry.frame(in: .global)
    } action: { newBodyFrame in
      bodyFrame = newBodyFrame
      adjustScrollOffset(
        loadCoordinator.updateFrame(newBodyFrame, for: message.id)
      )
      updateBodyVisibility(bodyFrame: newBodyFrame)
    }
    .onChange(of: visibleViewportFrame) {
      updateBodyVisibility()
    }
    .onChange(of: clearBodySignal) {
      isBodyLoaded = false
      updateBodyVisibility(isBodyLoaded: false)
    }
  }

  private func updateBodyVisibility(
    isBodyLoaded: Bool? = nil,
    bodyFrame: CGRect? = nil
  ) {
    let resolvedBodyIsLoaded = isBodyLoaded ?? self.isBodyLoaded
    let isVisible = MailShellMessageReadVisibility.isEligible(
      isBodyLoaded: resolvedBodyIsLoaded,
      bodyFrame: bodyFrame ?? self.bodyFrame,
      viewportFrame: visibleViewportFrame
    )
    guard isVisible != isBodyVisible else { return }
    isBodyVisible = isVisible
    if isVisible {
      markBodyDisplayed()
    } else {
      markBodyHidden()
    }
  }
}

struct MailShellMessageBody: View {
  let allowsAutomaticRemoteContent: Bool
  let authorizeLinkOpening: () async -> Bool
  let clearSignal: UUID?
  let connectionId: MailboxConnectionId?
  let messageId: StableProviderMessageIdentity?
  let messageSubject: String?
  let retrySignal: UUID?
  let load: () async throws -> MailboxMessageBody
  let loadAttachment: (MailboxMessageAttachment) async throws -> Data
  let onDisplay: () -> Void
  let onDismiss: () -> Void
  let onLoaded: () -> Void
  let onBodyLoaded: (MailboxMessageBody) -> Void
  let onLoadAttemptFinished: (UUID, Bool) -> Void
  let onRetryRequested: () -> Void
  let onRelease: () -> Void
  let onReleaseRemoteContent: () -> Void
  let removesQuotedReplies: Bool
  let loadRequestId: UUID?
  let usesCoordinatedLoading: Bool
  let loadRemoteContent: (SanitizedMessageHTML) async throws -> RemoteMessageContentLoadResult
  @State private var loadedContent: MailShellLoadedMessageContent?
  @State private var isPresentationRetained = false
  @State private var automaticLoadRequestId = UUID()
  @State private var loadAttempt = 0
  @State private var loadGeneration = UUID()
  @State private var presentationState = MailShellMessageBodyPresentationState.placeholder

  init(
    allowsAutomaticRemoteContent: Bool = true,
    authorizeLinkOpening: @escaping () async -> Bool = { true },
    clearSignal: UUID? = nil,
    connectionId: MailboxConnectionId? = nil,
    messageId: StableProviderMessageIdentity? = nil,
    messageSubject: String? = nil,
    retrySignal: UUID? = nil,
    onDisplay: @escaping () -> Void = {},
    onDismiss: @escaping () -> Void = {},
    onLoaded: @escaping () -> Void = {},
    onBodyLoaded: @escaping (MailboxMessageBody) -> Void = { _ in },
    onLoadAttemptFinished: @escaping (UUID, Bool) -> Void = { _, _ in },
    onRetryRequested: @escaping () -> Void = {},
    onRelease: @escaping () -> Void = {},
    onReleaseRemoteContent: @escaping () -> Void = {},
    removesQuotedReplies: Bool = false,
    loadRequestId: UUID? = nil,
    usesCoordinatedLoading: Bool = false,
    loadAttachment: @escaping (MailboxMessageAttachment) async throws -> Data = { _ in
      throw MailboxMessageAttachmentError.unsupportedProvider
    },
    loadRemoteContent:
      @escaping (SanitizedMessageHTML) async throws
      -> RemoteMessageContentLoadResult = {
        try await RemoteMessageContentLoader().load($0)
      },
    load: @escaping () async throws -> MailboxMessageBody
  ) {
    self.allowsAutomaticRemoteContent = allowsAutomaticRemoteContent
    self.authorizeLinkOpening = authorizeLinkOpening
    self.clearSignal = clearSignal
    self.connectionId = connectionId
    self.messageId = messageId
    self.messageSubject = messageSubject
    self.retrySignal = retrySignal
    self.load = load
    self.loadAttachment = loadAttachment
    self.onDisplay = onDisplay
    self.onDismiss = onDismiss
    self.onLoaded = onLoaded
    self.onBodyLoaded = onBodyLoaded
    self.onLoadAttemptFinished = onLoadAttemptFinished
    self.onRetryRequested = onRetryRequested
    self.onRelease = onRelease
    self.onReleaseRemoteContent = onReleaseRemoteContent
    self.removesQuotedReplies = removesQuotedReplies
    self.loadRequestId = loadRequestId
    self.usesCoordinatedLoading = usesCoordinatedLoading
    self.loadRemoteContent = loadRemoteContent
  }

  var body: some View {
    Group {
      if let loadedContent {
        MailShellMessageContent(
          allowsAutomaticRemoteContent: allowsAutomaticRemoteContent,
          connectionId: connectionId,
          loadedContent: loadedContent,
          messageId: messageId,
          loadAttachment: loadAttachment,
          loadRemoteContent: loadRemoteContent,
          onResetRemoteContent: onReleaseRemoteContent,
          onInitialHTMLDocumentReady: revealPreparedContent,
          onRenderingFailure: {
            let wasRevealed = presentationState.revealsContent
            self.loadedContent = MailShellLoadedMessageContent(
              attachments: loadedContent.attachments,
              fallbackText: loadedContent.fallbackText,
              hasInlineContent: loadedContent.hasInlineContent,
              presentation: .plainText(loadedContent.fallbackText)
            )
            presentationState.didPrepare(.plainText(loadedContent.fallbackText))
            if !wasRevealed {
              onLoaded()
            }
          }
        )
        .opacity(presentationState.revealsContent ? 1 : 0)
        .accessibilityHidden(!presentationState.revealsContent)
        .overlay(alignment: .topLeading) {
          if presentationState == .placeholder {
            MailShellMessageBodyPlaceholder()
          }
        }
      } else if presentationState == .cleared {
        Text("Cached body removed.")
          .foregroundStyle(.secondary)
      } else if case .failed(let errorMessage) = presentationState {
        ContentUnavailableView {
          Label("Message unavailable", systemImage: "exclamationmark.triangle")
        } description: {
          Text(errorMessage)
        } actions: {
          Button("Try Again", action: retryLoad)
            .accessibilityIdentifier("mail-message-body-retry")
        }
      } else {
        MailShellMessageBodyPlaceholder()
      }
    }
    .handlingSuspiciousLinks(
      presentations: loadedContent?.presentation.linkPresentations ?? [],
      authorize: authorizeLinkOpening
    )
    .task(id: loadTaskIdentity) {
      guard let requestId = usesCoordinatedLoading ? loadRequestId : automaticLoadRequestId else {
        return
      }
      var shouldRetry = true
      defer {
        if usesCoordinatedLoading {
          onLoadAttemptFinished(requestId, shouldRetry)
        }
      }
      let generation = loadGeneration
      do {
        let loadedMessageBody = try await load()
        isPresentationRetained = true
        guard generation == loadGeneration else {
          releasePresentation()
          shouldRetry = Task.isCancelled
          return
        }
        let presentation = try await MessageHTMLPresentation.prepare(
          body: loadedMessageBody,
          removesQuotedReplies: removesQuotedReplies,
          sanitizer: { html, removesQuotedReplies in
            try MessageHTMLSanitizer.sanitize(
              html,
              removesQuotedReplies: removesQuotedReplies,
              messageSubject: messageSubject
            )
          }
        )
        guard generation == loadGeneration else {
          releasePresentation()
          shouldRetry = Task.isCancelled
          return
        }
        loadedContent = MailShellLoadedMessageContent(
          attachments: loadedMessageBody.attachments,
          fallbackText: removesQuotedReplies
            ? MessagePlainTextPresentation.withoutQuotedReply(loadedMessageBody.text)
            : loadedMessageBody.text,
          hasInlineContent: !loadedMessageBody.inlineImages.isEmpty,
          presentation: presentation
        )
        onBodyLoaded(loadedMessageBody)
        presentationState.didPrepare(presentation)
        if presentationState.revealsContent {
          onLoaded()
        }
        shouldRetry = false
      } catch is CancellationError {
        releasePresentation()
        shouldRetry = Task.isCancelled
      } catch {
        releasePresentation()
        guard generation == loadGeneration else { return }
        presentationState.didFail(error.localizedDescription)
        shouldRetry = false
      }
    }
    .onAppear {
      onDisplay()
    }
    .onChange(of: retrySignal) {
      guard presentationState.isFailed else { return }
      retryLoad()
    }
    .onChange(of: clearSignal) {
      releasePresentation()
      loadGeneration = UUID()
      loadedContent = nil
      presentationState.didClear()
    }
    .onDisappear {
      onDismiss()
      loadGeneration = UUID()
      loadedContent = nil
      presentationState.retry()
      releasePresentation()
    }
  }

  private func releasePresentation() {
    guard isPresentationRetained else { return }
    isPresentationRetained = false
    onRelease()
  }

  private func retryLoad() {
    presentationState.retry()
    loadGeneration = UUID()
    loadAttempt += 1
    if usesCoordinatedLoading {
      onRetryRequested()
    }
  }

  private var loadTaskIdentity: String {
    let requestIdentity =
      usesCoordinatedLoading ? loadRequestId?.uuidString ?? "waiting" : "automatic"
    return "\(requestIdentity):\(loadAttempt)"
  }

  private func revealPreparedContent() {
    guard presentationState == .placeholder else { return }
    presentationState.didRenderHTML()
    onLoaded()
  }
}

enum MailShellMessageBodyPresentationState: Equatable {
  case cleared
  case failed(String)
  case placeholder
  case revealed

  var isFailed: Bool {
    if case .failed = self { true } else { false }
  }

  var revealsContent: Bool {
    self == .revealed
  }

  mutating func didPrepare(_ presentation: MessageHTMLPresentation) {
    switch presentation {
    case .html:
      self = .placeholder
    case .plainText:
      self = .revealed
    }
  }

  mutating func didRenderHTML() {
    guard self == .placeholder else { return }
    self = .revealed
  }

  mutating func didFail(_ message: String) {
    self = .failed(message)
  }

  mutating func didClear() {
    self = .cleared
  }

  mutating func retry() {
    self = .placeholder
  }
}

private struct MailShellMessageBodyPlaceholder: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Message body loading placeholder")
      Text("Message body loading placeholder")
      Text("Message body")
        .frame(maxWidth: 220, alignment: .leading)
    }
    .font(.body)
    .foregroundStyle(.secondary)
    .redacted(reason: .placeholder)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading message")
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension MessageHTMLPresentation {
  fileprivate var linkPresentations: [MessageHTMLLinkPresentation] {
    guard case .html(let html) = self else { return [] }
    return html.linkPresentations
  }
}

private struct MailShellLoadedMessageContent {
  let attachments: [MailboxMessageAttachment]
  let fallbackText: String
  let hasInlineContent: Bool
  let presentation: MessageHTMLPresentation
}

private struct MailShellPlainMessageText: View {
  let text: String
  @Environment(AppearancePreferences.self) private var appearancePreferences: AppearancePreferences?
  @ScaledMetric(relativeTo: .body) private var bodyPointSize = 17

  var body: some View {
    Text(MessagePlainTextLinks.attributed(text))
      .font(
        .system(
          size: bodyPointSize
            * (appearancePreferences?.readingTextSize ?? .standard).scale,
          design: (appearancePreferences?.messageBodyTypeface ?? .senderFormatting)
            .fontDesign
        )
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
  }
}

enum MessagePlainTextLinks {
  static func attributed(_ text: String) -> AttributedString {
    var attributed = AttributedString(text)
    guard
      let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
      )
    else { return attributed }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    for match in detector.matches(in: text, range: range) {
      guard let url = match.url,
        MessageHTMLLinkPolicy.externalURL(url, isUserActivated: true) != nil,
        let stringRange = Range(match.range, in: text),
        let attributedRange = Range(stringRange, in: attributed)
      else { continue }
      attributed[attributedRange].link = url
    }
    return attributed
  }
}

private struct MailShellMessageContent: View {
  let allowsAutomaticRemoteContent: Bool
  let connectionId: MailboxConnectionId?
  let loadedContent: MailShellLoadedMessageContent
  let messageId: StableProviderMessageIdentity?
  let loadAttachment: (MailboxMessageAttachment) async throws -> Data
  let loadRemoteContent: (SanitizedMessageHTML) async throws -> RemoteMessageContentLoadResult
  let onResetRemoteContent: () -> Void
  let onInitialHTMLDocumentReady: () -> Void
  let onRenderingFailure: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      switch loadedContent.presentation {
      case .html(let html):
        MessageHTMLView(
          allowsAutomaticRemoteContent: allowsAutomaticRemoteContent,
          connectionId: connectionId,
          html: html,
          onInitialDocumentReady: onInitialHTMLDocumentReady,
          onRenderingFailure: onRenderingFailure,
          onResetRemoteContent: onResetRemoteContent,
          loadRemoteContent: loadRemoteContent
        )
      case .plainText(let text):
        MailShellPlainMessageText(text: text)
      }
      if !loadedContent.attachments.isEmpty, let messageId {
        MessageAttachmentsView(
          attachments: loadedContent.attachments,
          messageId: messageId,
          download: loadAttachment
        )
      }
    }
    .accessibilityIdentifier(loadedContent.hasInlineContent ? "message-inline-content" : "")
  }
}

extension View {
  fileprivate func mailShellToolbarActionStyle(
    foregroundStyle: Color = MailTheme.accent
  ) -> some View {
    labelStyle(.iconOnly)
      .buttonStyle(.plain)
      .controlSize(.regular)
      .frame(width: 36, height: 36)
      .contentShape(Circle())
      .foregroundStyle(foregroundStyle)
      .mailShellGlassEffect(interactive: true, in: Circle())
  }

  @ViewBuilder
  fileprivate func mailShellTopScrollEdgeEffectHidden() -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      scrollEdgeEffectHidden(for: .top)
    } else {
      self
    }
  }

  @ViewBuilder
  fileprivate func mailShellBottomInset<BarContent: View>(
    isEnabled: Bool,
    @ViewBuilder content: () -> BarContent
  ) -> some View {
    if isEnabled {
      safeAreaInset(edge: .bottom, spacing: 0, content: content)
    } else {
      self
    }
  }

  @ViewBuilder
  fileprivate func mailShellGlassEffect<S: Shape>(
    interactive: Bool = false,
    in shape: S
  ) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    } else {
      background(.regularMaterial, in: shape)
        .overlay {
          shape.stroke(.separator.opacity(0.35), lineWidth: 0.5)
        }
    }
  }

  @ViewBuilder
  fileprivate func composePresentation<Item: Identifiable, Content: View>(
    item: Binding<Item?>,
    preference: ComposePresentationPreference,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    switch preference {
    case .partial:
      sheet(item: item) { value in
        content(value).id(value.id)
      }
    case .fullScreen:
      fullScreenCover(item: item) { value in
        content(value).id(value.id)
      }
    }
  }
}

@MainActor
@Observable
final class PinViewModel {
  var errorMessage: String?
  private(set) var pinnedThreadIds: Set<StableThreadIdentity> = []

  private let service: PinSyncing
  private var session: ProductAccountSessionSnapshot
  private var completedToggleGenerations: [StableThreadIdentity: Int] = [:]
  private var updatingThreadIds: Set<StableThreadIdentity> = []

  init(
    service: PinSyncing,
    session: ProductAccountSessionSnapshot
  ) {
    self.service = service
    self.session = session
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    self.session = session
  }

  func load() async {
    let generationsAtLoadStart = completedToggleGenerations
    do {
      let loadedThreadIds = try await service.loadPinnedThreadIds(session: session)
      let changedThreadIds = Set(
        completedToggleGenerations.compactMap { threadId, generation in
          generation == generationsAtLoadStart[threadId, default: 0] ? nil : threadId
        }
      )
      applyLoadedThreadIds(loadedThreadIds, preserving: changedThreadIds)
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
    }
  }

  func reconcile(with messages: [MailboxMessageMetadata]) async {
    let generationsAtReconciliationStart = completedToggleGenerations
    do {
      let reconciled = try await service.reconcilePins(with: messages, session: session)
      try Task.checkCancellation()
      let changedThreadIds = Set(
        completedToggleGenerations.compactMap { threadId, generation in
          generation == generationsAtReconciliationStart[threadId, default: 0] ? nil : threadId
        }
      )
      applyLoadedThreadIds(reconciled, preserving: changedThreadIds)
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func applyLoadedThreadIds(
    _ loadedThreadIds: Set<StableThreadIdentity>,
    preserving changedThreadIds: Set<StableThreadIdentity>
  ) {
    pinnedThreadIds = Set(
      loadedThreadIds.filter {
        !updatingThreadIds.contains($0) && !changedThreadIds.contains($0)
      }
    ).union(
      pinnedThreadIds.filter {
        updatingThreadIds.contains($0) || changedThreadIds.contains($0)
      }
    )
  }

  func togglePin(
    _ threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity
  ) async {
    guard !updatingThreadIds.contains(threadId) else { return }
    let wasPinned = pinnedThreadIds.contains(threadId)
    let shouldPin = !wasPinned
    setPinnedLocally(shouldPin, threadId: threadId)
    updatingThreadIds.insert(threadId)
    errorMessage = nil
    defer { updatingThreadIds.remove(threadId) }

    do {
      try await service.setPinned(
        shouldPin,
        threadId: threadId,
        anchorMessageId: anchorMessageId,
        session: session
      )
      completedToggleGenerations[threadId, default: 0] += 1
    } catch is CancellationError {
      setPinnedLocally(wasPinned, threadId: threadId)
    } catch {
      setPinnedLocally(wasPinned, threadId: threadId)
      errorMessage = error.localizedDescription
    }
  }

  func isUpdating(_ threadId: StableThreadIdentity) -> Bool {
    updatingThreadIds.contains(threadId)
  }

  func clearError() {
    errorMessage = nil
  }

  private func setPinnedLocally(
    _ isPinned: Bool,
    threadId: StableThreadIdentity
  ) {
    if isPinned {
      pinnedThreadIds.insert(threadId)
    } else {
      pinnedThreadIds.remove(threadId)
    }
  }
}

@MainActor
@Observable
final class ThreadMuteViewModel {
  var errorMessage: String?
  private(set) var mutedThreadIds: Set<StableThreadIdentity> = []

  private let service: ThreadMuteSyncing
  private var profileId: MailProfileId
  private var session: ProductAccountSessionSnapshot
  private var snapshot = ThreadMuteSnapshot.empty
  private var contextRevision = 0
  private var snapshotRevision = 0
  private var updatingThreadIds: Set<StableThreadIdentity> = []
  private var updateGenerations: [StableThreadIdentity: Int] = [:]
  private var nextUpdateGeneration = 0

  init(
    service: ThreadMuteSyncing,
    session: ProductAccountSessionSnapshot,
    profileId: MailProfileId? = nil
  ) {
    self.service = service
    self.session = session
    self.profileId = profileId ?? .defaultProfile(productAccountId: session.productAccountId)
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    contextRevision += 1
    snapshotRevision += 1
    self.session = session
  }

  func updateProfile(_ profileId: MailProfileId) {
    guard self.profileId != profileId else { return }
    contextRevision += 1
    snapshotRevision += 1
    self.profileId = profileId
    snapshot = .empty
    mutedThreadIds = []
    updatingThreadIds = []
    updateGenerations = [:]
    errorMessage = nil
  }

  func load() async {
    let profileId = profileId
    let revision = snapshotRevision
    let session = session
    do {
      let loaded = try await service.load(profileId: profileId, session: session)
      try Task.checkCancellation()
      guard profileId == self.profileId, revision == snapshotRevision else { return }
      apply(loaded)
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      guard
        !Task.isCancelled,
        profileId == self.profileId,
        revision == snapshotRevision
      else { return }
      errorMessage = error.localizedDescription
    }
  }

  func reconcile(with messages: [MailboxMessageMetadata]) async {
    let revision = snapshotRevision
    do {
      let reconciled = try await service.reconcile(
        with: messages,
        profileId: profileId,
        session: session
      )
      try Task.checkCancellation()
      guard revision == snapshotRevision else { return }
      apply(reconciled)
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      guard !Task.isCancelled, revision == snapshotRevision else { return }
      errorMessage = error.localizedDescription
    }
  }

  func toggleMute(_ thread: MailboxThread) async {
    await setMuted(!mutedThreadIds.contains(thread.id), thread: thread)
  }

  func unmute(_ threadId: StableThreadIdentity) async {
    guard let mute = snapshot.mutes[threadId] else { return }
    await setMuted(
      false,
      threadId: threadId,
      anchorMessageId: mute.anchorMessageId
    )
  }

  func isUpdating(_ threadId: StableThreadIdentity) -> Bool {
    updatingThreadIds.contains(threadId)
  }

  func anchorMessageId(for threadId: StableThreadIdentity) -> StableProviderMessageIdentity? {
    snapshot.mutes[threadId]?.anchorMessageId
  }

  private func setMuted(_ isMuted: Bool, thread: MailboxThread) async {
    await setMuted(
      isMuted,
      threadId: thread.id,
      anchorMessageId: thread.latestMessage.id
    )
  }

  private func setMuted(
    _ isMuted: Bool,
    threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity
  ) async {
    guard !updatingThreadIds.contains(threadId) else { return }
    let profileId = profileId
    let revision = contextRevision
    let session = session
    let wasMuted = mutedThreadIds.contains(threadId)
    setMutedLocally(isMuted, threadId: threadId, anchorMessageId: anchorMessageId)
    nextUpdateGeneration += 1
    let updateGeneration = nextUpdateGeneration
    updatingThreadIds.insert(threadId)
    updateGenerations[threadId] = updateGeneration
    errorMessage = nil
    defer {
      if updateGenerations[threadId] == updateGeneration {
        updatingThreadIds.remove(threadId)
        updateGenerations[threadId] = nil
      }
    }
    do {
      try await service.setMuted(
        isMuted,
        threadId: threadId,
        anchorMessageId: anchorMessageId,
        profileId: profileId,
        session: session
      )
      try Task.checkCancellation()
      guard
        profileId == self.profileId,
        revision == contextRevision,
        updateGenerations[threadId] == updateGeneration
      else { return }
      snapshotRevision += 1
    } catch is CancellationError {
    } catch {
      guard
        !Task.isCancelled,
        profileId == self.profileId,
        revision == contextRevision,
        updateGenerations[threadId] == updateGeneration
      else { return }
      setMutedLocally(wasMuted, threadId: threadId, anchorMessageId: anchorMessageId)
      errorMessage = error.localizedDescription
    }
  }

  private func apply(_ snapshot: ThreadMuteSnapshot) {
    guard !updatingThreadIds.isEmpty else {
      self.snapshot = snapshot
      mutedThreadIds = snapshot.mutedThreadIds
      return
    }
    var mutes = snapshot.mutes.filter { !updatingThreadIds.contains($0.key) }
    for threadId in updatingThreadIds {
      if let inFlight = self.snapshot.mutes[threadId] {
        mutes[threadId] = inFlight
      }
    }
    self.snapshot = ThreadMuteSnapshot(mutes: mutes)
    mutedThreadIds = self.snapshot.mutedThreadIds
  }

  private func setMutedLocally(
    _ isMuted: Bool,
    threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity
  ) {
    if isMuted {
      let mute = ThreadMute(
        anchorMessageId: anchorMessageId,
        profileId: profileId,
        threadId: threadId
      )
      snapshot = ThreadMuteSnapshot(
        mutes: snapshot.mutes.merging([threadId: mute]) { _, new in
          new
        })
    } else {
      snapshot = ThreadMuteSnapshot(mutes: snapshot.mutes.filter { $0.key != threadId })
    }
    mutedThreadIds = snapshot.mutedThreadIds
  }
}

enum ThreadSnoozePreset: String, CaseIterable, Identifiable {
  case laterToday
  case tomorrowMorning
  case nextWeek

  var id: Self { self }

  var title: String {
    switch self {
    case .laterToday:
      return "Later Today"
    case .tomorrowMorning:
      return "Tomorrow Morning"
    case .nextWeek:
      return "Next Week"
    }
  }

  func dueDate(
    after now: Date = .now,
    calendar: Calendar = .current
  ) throws -> Date {
    switch self {
    case .laterToday:
      let laterToday = now.addingTimeInterval(3 * 60 * 60)
      guard calendar.isDate(laterToday, inSameDayAs: now) else {
        return try Self.tomorrowMorning(after: now, calendar: calendar)
      }
      return laterToday
    case .tomorrowMorning, .nextWeek:
      let dayOffset = self == .tomorrowMorning ? 1 : 7
      guard let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: now) else {
        throw ThreadSnoozeSyncError.invalidDueTime
      }
      let day = calendar.dateComponents([.year, .month, .day], from: targetDay)
      return try ThreadSnoozeDueDateResolver.resolve(
        localComponents: DateComponents(
          year: day.year,
          month: day.month,
          day: day.day,
          hour: 9,
          minute: 0
        ),
        timeZone: calendar.timeZone,
        repeatedTimePolicy: .first
      )
    }
  }

  private static func tomorrowMorning(after now: Date, calendar: Calendar) throws -> Date {
    guard let targetDay = calendar.date(byAdding: .day, value: 1, to: now) else {
      throw ThreadSnoozeSyncError.invalidDueTime
    }
    let day = calendar.dateComponents([.year, .month, .day], from: targetDay)
    return try ThreadSnoozeDueDateResolver.resolve(
      localComponents: DateComponents(
        year: day.year,
        month: day.month,
        day: day.day,
        hour: 9,
        minute: 0
      ),
      timeZone: calendar.timeZone,
      repeatedTimePolicy: .first
    )
  }
}

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class ThreadSnoozeViewModel {
  var errorMessage: String?
  private(set) var isUpdatingPreferences = false
  private(set) var preferences = ThreadSnoozePreferences.defaults
  private(set) var snoozedThreadIds: Set<StableThreadIdentity> = []

  private let attentionDelivery: ThreadSnoozeAttentionDelivering
  private let notificationAuthorization: NotificationAuthorizationStateChecking
  private let notificationPreferenceStore: NotificationDevicePreferencePersisting
  private let profileLockStore: MailProfileLockPersisting
  private let profileLoader: NotificationProfilePolicyLoading
  private let scheduler: ThreadSnoozeScheduler
  private let service: ThreadSnoozeSyncing
  private var profileId: MailProfileId
  private var session: ProductAccountSessionSnapshot
  private var snapshot = ThreadSnoozeSnapshot(snoozes: [:])
  private var stateRevision = 0
  private var subjectsByThreadId: [StableThreadIdentity: String] = [:]
  private var updatingThreadIds: Set<StableThreadIdentity> = []
  private var scheduledWakeRevisions: [StableThreadIdentity: Int] = [:]
  private var scheduledWakeSnoozes: [StableThreadIdentity: ThreadSnooze] = [:]
  private var wakeTasks: [StableThreadIdentity: Task<Void, Never>] = [:]

  init(
    attentionDelivery: ThreadSnoozeAttentionDelivering = UserNotificationService(),
    notificationAuthorization: NotificationAuthorizationStateChecking =
      UserNotificationService(),
    notificationPreferenceStore: NotificationDevicePreferencePersisting =
      UserDefaultsNotificationPreferenceStore(),
    profileLockStore: MailProfileLockPersisting = UserDefaultsMailProfileLockStore(),
    profileLoader: NotificationProfilePolicyLoading = MailboxConnectionSyncService(),
    scheduler: ThreadSnoozeScheduler = .continuous,
    service: ThreadSnoozeSyncing,
    session: ProductAccountSessionSnapshot,
    profileId: MailProfileId? = nil
  ) {
    self.attentionDelivery = attentionDelivery
    self.notificationAuthorization = notificationAuthorization
    self.notificationPreferenceStore = notificationPreferenceStore
    self.profileLockStore = profileLockStore
    self.profileLoader = profileLoader
    self.scheduler = scheduler
    self.service = service
    self.session = session
    self.profileId = profileId ?? .defaultProfile(productAccountId: session.productAccountId)
  }

  isolated deinit {
    for task in wakeTasks.values { task.cancel() }
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    stateRevision += 1
    self.session = session
  }

  func updateProfile(_ profileId: MailProfileId) {
    guard self.profileId != profileId else { return }
    stateRevision += 1
    self.profileId = profileId
    snapshot = ThreadSnoozeSnapshot(snoozes: [:])
    snoozedThreadIds = []
    preferences = .defaults
    subjectsByThreadId = [:]
    updatingThreadIds = []
    for task in wakeTasks.values {
      task.cancel()
    }
    scheduledWakeRevisions = [:]
    scheduledWakeSnoozes = [:]
    wakeTasks = [:]
    errorMessage = nil
  }

  func load() async {
    let revision = stateRevision
    let session = session
    do {
      async let loadedSnapshot = service.load(profileId: profileId, session: session)
      async let loadedPreferences = service.loadPreferences(profileId: profileId, session: session)
      let snapshot = try await loadedSnapshot
      guard revision == stateRevision else { return }
      try apply(snapshot)
      do {
        let preferences = try await loadedPreferences
        guard revision == stateRevision else { return }
        self.preferences = preferences
        errorMessage = nil
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, revision == stateRevision else { return }
        errorMessage = error.localizedDescription
      }
    } catch is CancellationError {
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
    }
  }

  func reconcile(with messages: [MailboxMessageMetadata]) async {
    let revision = stateRevision
    let session = session
    subjectsByThreadId.merge(
      Dictionary(
        uniqueKeysWithValues: MailboxThread.group(messages).map {
          ($0.id, $0.latestMessage.subject)
        }
      )
    ) { _, latest in latest }
    do {
      let reconciled = try await service.reconcile(
        with: messages,
        profileId: profileId,
        session: session
      )
      guard revision == stateRevision else { return }
      try apply(reconciled)
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
    }
  }

  func snooze(_ thread: MailboxThread, preset: ThreadSnoozePreset) async {
    do {
      try await snooze(thread, until: preset.dueDate())
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func snooze(_ thread: MailboxThread, until dueDate: Date) async throws {
    guard !updatingThreadIds.contains(thread.id) else { return }
    stateRevision += 1
    let revision = stateRevision
    let session = session
    updatingThreadIds.insert(thread.id)
    subjectsByThreadId[thread.id] = thread.latestMessage.subject
    defer { updatingThreadIds.remove(thread.id) }
    do {
      try await service.snooze(
        thread: thread,
        dueAtMilliseconds: Int64(dueDate.timeIntervalSince1970 * 1_000),
        profileId: profileId,
        session: session
      )
      let loaded = try await service.load(profileId: profileId, session: session)
      guard revision == stateRevision else { return }
      try apply(loaded)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func cancel(_ threadId: StableThreadIdentity) async {
    guard !updatingThreadIds.contains(threadId) else { return }
    stateRevision += 1
    let revision = stateRevision
    let session = session
    updatingThreadIds.insert(threadId)
    defer { updatingThreadIds.remove(threadId) }
    do {
      try await service.cancel(threadId: threadId, profileId: profileId, session: session)
      let loaded = try await service.load(profileId: profileId, session: session)
      guard revision == stateRevision else { return }
      try apply(loaded)
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setReturnToAttentionEnabled(_ isEnabled: Bool) async {
    guard !isUpdatingPreferences else { return }
    isUpdatingPreferences = true
    defer { isUpdatingPreferences = false }
    do {
      try await service.setReturnToAttentionEnabled(
        isEnabled,
        profileId: profileId,
        session: session
      )
      preferences.returnToAttentionEnabled = isEnabled
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func isUpdating(_ threadId: StableThreadIdentity) -> Bool {
    updatingThreadIds.contains(threadId)
  }

  func clearError() {
    errorMessage = nil
  }

  #if DEBUG || TESTING
    func scheduledWakeTaskForTesting(
      _ threadId: StableThreadIdentity
    ) -> Task<Void, Never>? {
      wakeTasks[threadId]
    }
  #endif

  // swiftlint:disable:next function_body_length
  private func apply(_ snapshot: ThreadSnoozeSnapshot) throws {
    try Task.checkCancellation()
    self.snapshot = snapshot
    let nowMilliseconds = scheduler.nowMilliseconds()
    snoozedThreadIds = snapshot.activeThreadIds(atMilliseconds: nowMilliseconds)
    for (threadId, task) in wakeTasks where !snoozedThreadIds.contains(threadId) {
      task.cancel()
      wakeTasks[threadId] = nil
      scheduledWakeRevisions[threadId] = nil
      scheduledWakeSnoozes[threadId] = nil
    }
    for snooze in snapshot.snoozes.values where snoozedThreadIds.contains(snooze.threadId) {
      guard
        scheduledWakeSnoozes[snooze.threadId] != snooze
          || scheduledWakeRevisions[snooze.threadId] != stateRevision
      else { continue }
      wakeTasks[snooze.threadId]?.cancel()
      let dueAtMilliseconds = snooze.dueAtMilliseconds
      let profileId = profileId
      let revision = stateRevision
      let session = session
      scheduledWakeRevisions[snooze.threadId] = revision
      scheduledWakeSnoozes[snooze.threadId] = snooze
      wakeTasks[snooze.threadId] = Task { [weak self] in
        guard let self else { return }
        do {
          try await scheduler.sleepUntilMilliseconds(dueAtMilliseconds)
        } catch {
          return
        }
        let shouldDeliver = await revalidateScheduledWake(
          snooze,
          profileId: profileId,
          revision: revision,
          session: session
        )
        guard
          !Task.isCancelled,
          revision == stateRevision,
          self.snapshot.snoozes[snooze.threadId] == snooze
        else {
          return
        }
        if shouldDeliver {
          await deliverAttention(for: snooze)
          guard
            !Task.isCancelled,
            revision == stateRevision,
            self.snapshot.snoozes[snooze.threadId] == snooze
          else {
            return
          }
        }
        snoozedThreadIds.remove(snooze.threadId)
        wakeTasks[snooze.threadId] = nil
        scheduledWakeRevisions[snooze.threadId] = nil
        scheduledWakeSnoozes[snooze.threadId] = nil
      }
    }
  }

  private func revalidateScheduledWake(
    _ snooze: ThreadSnooze,
    profileId: MailProfileId,
    revision: Int,
    session: ProductAccountSessionSnapshot
  ) async -> Bool {
    guard !Task.isCancelled, revision == stateRevision else { return false }
    async let loadedSnapshot = service.load(profileId: profileId, session: session)
    async let loadedPreferences = service.loadPreferences(profileId: profileId, session: session)
    guard
      let (authoritativeSnapshot, authoritativePreferences) = try? await (
        loadedSnapshot,
        loadedPreferences
      )
    else { return false }
    guard !Task.isCancelled, revision == stateRevision else { return false }
    preferences = authoritativePreferences
    guard authoritativeSnapshot.snoozes[snooze.threadId] == snooze else {
      try? apply(authoritativeSnapshot)
      return false
    }
    return true
  }

  // swiftlint:disable:next function_body_length
  private func deliverAttention(for snooze: ThreadSnooze) async {
    guard await notificationAuthorization.notificationAuthorizationState() == .authorized else {
      return
    }
    let productAccountId = session.productAccountId
    let devicePreferences = notificationPreferenceStore.load(
      productAccountId: productAccountId
    )
    let loadedProfiles: MailProfileSyncSnapshot
    do {
      loadedProfiles = try await profileLoader.loadNotificationProfileSnapshot(session: session)
    } catch {
      return
    }
    guard let profile = loadedProfiles.profiles.first(where: { $0.id == snooze.profileId }) else {
      return
    }
    let quietUntil = profile.quietState.quietUntil
    let isProfileQuiet =
      profile.quietState.isQuiet
      && (quietUntil.map { $0 > scheduler.nowMilliseconds() } ?? true)
    let allowsLockScreenContent =
      switch devicePreferences.lockScreenContentLevel {
      case .senderAndSubject, .fullPreview:
        true
      case .countOnly, .sender:
        false
      }
    let profileLock = profileLockStore.load(
      productAccountId: productAccountId,
      profileId: snooze.profileId
    )
    let policy = ThreadSnoozeInterruptionPolicy(
      allowsLockScreenContent: allowsLockScreenContent,
      isOSAuthorized: true,
      isProfileLocked: profileLock.isEnabled,
      isQuiet: isProfileQuiet || devicePreferences.quietSchedule.isQuiet(at: .now),
      returnToAttentionEnabled: preferences.returnToAttentionEnabled,
      trustedDeviceId: session.trustedDeviceId
    )
    do {
      try await attentionDelivery.deliverThreadSnoozeAttention(
        decision: policy.decision(
          for: snooze,
          subject: subjectsByThreadId[snooze.threadId] ?? "A Thread is ready."
        ),
        snooze: snooze,
        productAccountId: productAccountId
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

@MainActor
func coordinateProductAccountSignOut(
  session: ProductAccountSession,
  mailActionViewModel: GmailMailActionViewModel,
  preparation: @escaping @MainActor () async -> Void
) {
  mailActionViewModel.beginPreparingForSignOut()
  Task {
    await mailActionViewModel.suspendOutboxDelivery()
    await mailActionViewModel.waitForPendingSend()
    await session.signOut(afterRecoveryCheck: preparation)
    if case .signedIn = session.state {
      mailActionViewModel.cancelPreparingForSignOut()
    }
  }
}

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class GmailMailActionViewModel {
  @TaskLocal private static var currentPendingActionTaskId: UUID?

  private(set) var blockedConnectionIds: [MailboxConnectionId] = []
  private(set) var bulkActionProgress: MailboxBulkActionProgress?
  var errorMessage: String?
  private(set) var failedConnectionIds: [MailboxConnectionId] = []
  var isPerformingAction = false
  private(set) var outboxItems: [OutgoingDeliveryAttempt] = []
  private(set) var scheduledSendItems: [ManagedScheduledSend] = []
  private(set) var scheduledSendEditConflict = false

  private var knownConnections: [MailboxConnection] = []
  private var deferredBulkFailures: [UUID: [MailboxBulkActionFailure]] = [:]
  private(set) var isPreparingForSignOut = false
  private var isSending = false
  private var sendCompletionWaiters: [CheckedContinuation<Void, Never>] = []
  private let outboxService: OutboxDeliveryService
  private var pendingActionTasks: [UUID: Task<Void, Never>] = [:]
  private var outboxRetryObservationTask: Task<Void, Never>?
  private var retryObservationTask: Task<Void, Never>?
  private let revalidateTrustedDevice: @MainActor @Sendable () async -> Bool
  private let scheduledSendService: ScheduledSendService
  private let service: MailboxProviderMailActing
  private var session: ProductAccountSessionSnapshot

  var blockedConnectionId: MailboxConnectionId? {
    blockedConnectionIds.first
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    self.session = session
  }

  var failedConnectionId: MailboxConnectionId? {
    failedConnectionIds.first
  }

  var pendingFailureConnectionId: MailboxConnectionId? {
    blockedConnectionId ?? failedConnectionId
  }

  var outboxStates: [MailShellOutboxState] {
    outboxItems.map(Self.outboxState)
      + scheduledSendItems.map { item in
        switch item.state {
        case .scheduled, .sending: .pending
        case .needsAttention: .failed
        }
      }
  }

  static func outboxState(_ attempt: OutgoingDeliveryAttempt) -> MailShellOutboxState {
    switch attempt.state {
    case .handingOff, .pending:
      .pending
    case .reconciling, .retrying, .sentCopyPending:
      .retrying
    case .failed, .outcomeUnknown, .userActionRequired:
      .failed
    case .cancelled, .sent, .superseded:
      .sent
    }
  }

  init(
    service: MailboxProviderMailActing,
    session: ProductAccountSessionSnapshot,
    outboxService: OutboxDeliveryService = .shared,
    scheduledSendService: ScheduledSendService = .shared,
    revalidateTrustedDevice: @escaping @MainActor @Sendable () async -> Bool = { true }
  ) {
    self.outboxService = outboxService
    self.revalidateTrustedDevice = revalidateTrustedDevice
    self.scheduledSendService = scheduledSendService
    self.service = service
    self.session = session
  }

  func clearError() {
    errorMessage = nil
  }

  @discardableResult
  func startPendingAction(
    _ operation: @escaping @MainActor @Sendable () async -> Void
  ) -> Bool {
    guard !isPreparingForSignOut else { return false }
    let taskId = UUID()
    pendingActionTasks[taskId] = Task { [weak self] in
      await Self.$currentPendingActionTaskId.withValue(taskId) {
        await operation()
      }
      self?.pendingActionTasks[taskId] = nil
    }
    return true
  }

  func perform(
    _ action: ProviderMailAction,
    sourceProviderMailboxId: String? = nil,
    targetProviderMailboxId: String? = nil,
    targetProviderStateIds: Set<String> = [],
    for messages: [MailboxMessageMetadata],
    connection: MailboxConnection
  ) async -> Bool {
    guard connection.capabilities.supports(action) else { return false }
    guard !isPerformingAction else { return false }
    isPerformingAction = true
    defer { isPerformingAction = false }

    do {
      try await service.perform(
        action,
        sourceProviderMailboxId: sourceProviderMailboxId,
        targetProviderMailboxId: targetProviderMailboxId,
        targetProviderStateIds: targetProviderStateIds,
        messages: messages,
        connection: connection,
        session: session
      )
      errorMessage = nil
      return true
    } catch is CancellationError {
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func resume(
    connections: [MailboxConnection],
    revalidateProviderAccess: Bool = true
  ) async {
    for connection in connections {
      remember(connection)
    }
    retryObservationTask?.cancel()
    if revalidateProviderAccess {
      errorMessage = await service.resumePendingActions(
        connections: connections,
        session: session,
        revalidateProviderAccess: revalidateTrustedDevice
      )
    } else {
      errorMessage = await service.resumePendingActions(
        connections: connections,
        session: session
      )
    }
    do {
      try await outboxService.resume(
        connections: knownConnections,
        session: session,
        provider: outboxProvider(connections: knownConnections),
        reconcile: outboxReconciler(connections: knownConnections)
      )
    } catch {
      errorMessage = error.localizedDescription
    }
    await refreshOutbox()
    observeOutboxRetries()
    await refreshFailureConnections(knownConnections)
    let service = self.service
    let session = self.session
    let observedConnections = knownConnections
    retryObservationTask = Task { [weak self] in
      let retryError = await service.waitForPendingActionRetries(
        connections: observedConnections,
        session: session
      )
      guard !Task.isCancelled, let self else { return }
      if let retryError {
        errorMessage = retryError
      }
      await refreshFailureConnections(knownConnections)
    }
  }

  func retryBlockedAction(connection: MailboxConnection) async {
    remember(connection)
    let resolutionError = await service.retryBlockedPendingAction(
      connection: connection,
      session: session,
      revalidateProviderAccess: revalidateTrustedDevice
    )
    await refreshAfterResolution(resolutionError)
  }

  func discardBlockedAction(connection: MailboxConnection) async {
    remember(connection)
    let resolutionError = await service.discardBlockedPendingAction(
      connection: connection,
      session: session
    )
    await refreshAfterResolution(resolutionError)
  }

  func acknowledgeFailures(connection: MailboxConnection) async {
    remember(connection)
    await service.acknowledgePendingActionFailures(
      connection: connection,
      session: session
    )
    await refreshAfterResolution(nil)
    if !deferredBulkFailures.isEmpty {
      pruneDeferredBulkFailures()
      updateBulkActionErrorMessage()
    }
  }

  private func refreshAfterResolution(_ resolutionError: String?) async {
    await resume(connections: knownConnections)
    if let resolutionError {
      errorMessage = resolutionError
    }
  }

  private func refreshFailureConnections(_ connections: [MailboxConnection]) async {
    blockedConnectionIds = await service.blockedPendingActionConnectionIds(
      connections: connections,
      session: session
    )
    failedConnectionIds = await service.failedPendingActionConnectionIds(
      connections: connections,
      session: session
    )
  }

  private func remember(_ connection: MailboxConnection) {
    if let index = knownConnections.firstIndex(where: { $0.id == connection.id }) {
      knownConnections[index] = connection
    } else {
      knownConnections.append(connection)
    }
  }

  /// Adds an unsubscribe email to the receiving Mailbox Connection's durable Outbox.
  func enqueueUnsubscribeEmail(
    _ message: UnsubscribeMailtoMessage,
    through connection: MailboxConnection,
    undoSendWindow: UndoSendWindow
  ) async throws {
    guard connection.authorizationState == .authorized else {
      throw UnsubscribeEmailDeliveryError.authorizationRequired
    }
    guard connection.capabilities.canSend else {
      throw UnsubscribeEmailDeliveryError.sendUnavailable
    }
    guard !isPreparingForSignOut, !isPerformingAction else {
      throw UnsubscribeEmailDeliveryError.outboxUnavailable(
        "Another mail action is in progress. Try again."
      )
    }
    let didSend = await send(
      recipient: message.recipient,
      subject: message.subject,
      body: message.body,
      replyTo: nil,
      connection: connection,
      undoSendWindow: undoSendWindow
    )
    guard didSend else {
      if Task.isCancelled { throw CancellationError() }
      throw UnsubscribeEmailDeliveryError.outboxUnavailable(
        errorMessage ?? "The unsubscribe email could not be added to Outbox."
      )
    }
  }

  // swiftlint:disable:next function_body_length function_parameter_count
  func send(
    recipient: String,
    subject: String,
    body: String,
    document: SemanticMessageDocument? = nil,
    assets: [MailDraftAsset] = [],
    ccRecipients: String = "",
    bccRecipients: String = "",
    fromAddress: String? = nil,
    sendingIdentityId: SendingIdentityId? = nil,
    replyTo: MailboxMessageMetadata?,
    sourceMessage: MailboxMessageMetadata? = nil,
    connection: MailboxConnection,
    requestsReadReceipt: Bool = false,
    undoSendWindow: UndoSendWindow
  ) async -> Bool {
    guard !isPreparingForSignOut else { return false }
    guard connection.capabilities.canSend else { return false }
    guard !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    guard !isPerformingAction else { return false }
    guard
      sourceMessage?.connectionId == nil || sourceMessage?.connectionId == connection.id,
      replyTo?.connectionId == nil || replyTo?.connectionId == connection.id
    else {
      errorMessage = "Replies and forwards must use their source Mailbox Connection."
      return false
    }
    isPerformingAction = true
    isSending = true
    defer {
      isPerformingAction = false
      isSending = false
      let waiters = sendCompletionWaiters
      sendCompletionWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
    }

    let trimmedCcRecipients = ccRecipients.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBccRecipients = bccRecipients.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let selectedSourceMessage = sourceMessage
      _ = try await outboxService.enqueue(
        OutgoingMessage(
          body: body,
          recipient: recipient,
          subject: subject,
          htmlBody: document.map { assets.applyingInlineImageMetadata(to: $0.html) },
          semanticDocument: document,
          assets: assets,
          ccRecipients: trimmedCcRecipients.isEmpty ? nil : trimmedCcRecipients,
          bccRecipients: trimmedBccRecipients.isEmpty ? nil : trimmedBccRecipients,
          fromAddress: fromAddress,
          inReplyTo: replyTo?.rfcMessageId,
          kind: selectedSourceMessage == nil
            ? .new : (replyTo != nil ? .reply : .forward),
          providerThreadId: replyTo?.connectionId == connection.id && replyTo?.rfcMessageId != nil
            ? replyTo?.providerThreadId : nil,
          requestsReadReceipt: requestsReadReceipt
            && connection.capabilities.canRequestReadReceipts,
          sendingIdentityId: sendingIdentityId,
          sourceProviderMessageId: selectedSourceMessage?.providerMessageId
        ),
        connection: connection,
        session: session,
        undoSendDelayNanoseconds: undoSendWindow.nanoseconds,
        provider: outboxProvider(connections: knownConnections + [connection]),
        reconcile: outboxReconciler(connections: knownConnections + [connection])
      )
      remember(connection)
      await refreshOutbox()
      observeOutboxRetries()
      errorMessage = nil
      return true
    } catch is CancellationError {
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  // swiftlint:disable:next function_body_length function_parameter_count
  func scheduleSend(
    recipient: String,
    subject: String,
    body: String,
    document: SemanticMessageDocument?,
    assets: [MailDraftAsset],
    ccRecipients: String,
    bccRecipients: String,
    fromAddress: String,
    sendingIdentityId: SendingIdentityId,
    replyTo: MailboxMessageMetadata?,
    sourceMessage: MailboxMessageMetadata?,
    connection: MailboxConnection,
    requestsReadReceipt: Bool,
    draftId: UUID,
    profileId: MailProfileId,
    dueAt: Date,
    originalTimeZoneIdentifier: String,
    undoSendWindow: UndoSendWindow
  ) async -> Bool {
    guard !isPreparingForSignOut, !isPerformingAction else { return false }
    guard connection.providerId.supportsProductOwnedScheduledSend else {
      errorMessage = ScheduledSendAdmissionError.providerUnavailable.localizedDescription
      return false
    }
    isPerformingAction = true
    defer { isPerformingAction = false }
    let trimmedCcRecipients = ccRecipients.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBccRecipients = bccRecipients.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = OutgoingMessage(
      body: body,
      recipient: recipient,
      subject: subject,
      htmlBody: document.map { assets.applyingInlineImageMetadata(to: $0.html) },
      semanticDocument: document,
      assets: assets,
      ccRecipients: trimmedCcRecipients.isEmpty ? nil : trimmedCcRecipients,
      bccRecipients: trimmedBccRecipients.isEmpty ? nil : trimmedBccRecipients,
      fromAddress: fromAddress,
      inReplyTo: replyTo?.rfcMessageId,
      kind: sourceMessage == nil ? .new : (replyTo != nil ? .reply : .forward),
      providerThreadId: replyTo?.connectionId == connection.id && replyTo?.rfcMessageId != nil
        ? replyTo?.providerThreadId : nil,
      requestsReadReceipt: requestsReadReceipt
        && connection.capabilities.canRequestReadReceipts,
      sendingIdentityId: sendingIdentityId,
      sourceProviderMessageId: sourceMessage?.providerMessageId
    )
    do {
      _ = try await scheduledSendService.schedule(
        message,
        connection: connection,
        draftId: draftId,
        profileId: profileId,
        originalTimeZoneIdentifier: originalTimeZoneIdentifier,
        dueAt: dueAt,
        session: session,
        undoSendDelayNanoseconds: undoSendWindow.nanoseconds,
        provider: outboxProvider(connections: knownConnections + [connection]),
        reconcile: outboxReconciler(connections: knownConnections + [connection])
      )
      remember(connection)
      await refreshOutbox()
      observeOutboxRetries()
      errorMessage = nil
      return true
    } catch is CancellationError {
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func cancelOutboxAttempt(_ attempt: OutgoingDeliveryAttempt) async {
    do {
      _ = try await outboxService.cancel(attempt.id, session: session)
      if let scheduleId = attempt.scheduledSendId,
        let revision = attempt.scheduledSendRevision
      {
        try await scheduledSendService.cancel(
          scheduleId: scheduleId,
          revision: revision,
          session: session
        )
      }
      await refreshOutbox()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func beginScheduledSendEdit(_ item: ManagedScheduledSend) async -> ScheduledSendEditSession? {
    guard !isPerformingAction else { return nil }
    isPerformingAction = true
    defer { isPerformingAction = false }
    do {
      let editSession = try await scheduledSendService.beginEditing(item, session: session)
      errorMessage = nil
      return editSession
    } catch {
      errorMessage = error.localizedDescription
      await refreshOutbox()
      return nil
    }
  }

  func releaseScheduledSendEdit(_ editSession: ScheduledSendEditSession) async {
    await scheduledSendService.releaseEditing(editSession, session: session)
  }

  // swiftlint:disable:next function_parameter_count
  func replaceScheduledSend(
    _ editSession: ScheduledSendEditSession,
    draft: MailShellCompositionDraft,
    fromAddress: String,
    dueAt: Date?,
    originalTimeZoneIdentifier: String,
    undoSendWindow: UndoSendWindow
  ) async -> Bool {
    guard !isPerformingAction else { return false }
    guard let connectionId = draft.connectionId,
      let connection = knownConnections.first(where: { $0.id == connectionId })
    else {
      errorMessage = "Authorize this Mailbox Connection before changing the Scheduled Send."
      return false
    }
    isPerformingAction = true
    defer { isPerformingAction = false }
    let message = scheduledOutgoingMessage(
      from: draft,
      fromAddress: fromAddress,
      preserving: editSession.item.record.message
    )
    scheduledSendEditConflict = false
    do {
      if let dueAt {
        _ = try await scheduledSendService.reschedule(
          editSession,
          message: message,
          connection: connection,
          dueAt: dueAt,
          originalTimeZoneIdentifier: originalTimeZoneIdentifier,
          session: session,
          undoSendDelayNanoseconds: undoSendWindow.nanoseconds,
          provider: outboxProvider(connections: knownConnections),
          reconcile: outboxReconciler(connections: knownConnections)
        )
      } else {
        _ = try await scheduledSendService.sendNow(
          editSession,
          message: message,
          connection: connection,
          session: session,
          undoSendDelayNanoseconds: undoSendWindow.nanoseconds,
          provider: outboxProvider(connections: knownConnections),
          reconcile: outboxReconciler(connections: knownConnections)
        )
      }
      await refreshOutbox()
      observeOutboxRetries()
      errorMessage = nil
      return true
    } catch {
      scheduledSendEditConflict = error as? ScheduledSendManagementError == .staleRevision
      errorMessage = error.localizedDescription
      await refreshOutbox()
      return false
    }
  }

  func cancelScheduledSend(_ item: ManagedScheduledSend, editGeneration: Int? = nil) async -> Bool {
    guard !isPerformingAction else { return false }
    isPerformingAction = true
    defer { isPerformingAction = false }
    do {
      try await scheduledSendService.cancel(
        scheduleId: item.id,
        revision: item.record.revision,
        editGeneration: editGeneration,
        session: session
      )
      await refreshOutbox()
      errorMessage = nil
      return true
    } catch {
      errorMessage = error.localizedDescription
      await refreshOutbox()
      return false
    }
  }

  private func scheduledOutgoingMessage(
    from draft: MailShellCompositionDraft,
    fromAddress: String,
    preserving original: OutgoingMessage
  ) -> OutgoingMessage {
    let ccRecipients = draft.ccRecipients.trimmingCharacters(in: .whitespacesAndNewlines)
    let bccRecipients = draft.bccRecipients.trimmingCharacters(in: .whitespacesAndNewlines)
    return OutgoingMessage(
      body: draft.deliveryBody,
      recipient: draft.recipient,
      subject: draft.subject,
      htmlBody: draft.assets.applyingInlineImageMetadata(to: draft.deliveryDocument.html),
      semanticDocument: draft.deliveryDocument,
      assets: draft.assets,
      ccRecipients: ccRecipients.isEmpty ? nil : ccRecipients,
      bccRecipients: bccRecipients.isEmpty ? nil : bccRecipients,
      fromAddress: fromAddress,
      inReplyTo: original.inReplyTo,
      kind: original.kind,
      providerThreadId: original.providerThreadId,
      requestsReadReceipt: draft.requestsReadReceipt,
      sendingIdentityId: draft.sendingIdentityId,
      sourceProviderMessageId: original.sourceProviderMessageId
    )
  }

  // swiftlint:disable:next function_parameter_count
  func editOutboxAttempt(
    _ attempt: OutgoingDeliveryAttempt,
    recipient: String,
    subject: String,
    body: String,
    document: SemanticMessageDocument? = nil,
    assets: [MailDraftAsset] = [],
    ccRecipients: String = "",
    bccRecipients: String = "",
    fromAddress: String? = nil,
    sendingIdentityId: SendingIdentityId? = nil,
    connection: MailboxConnection,
    requestsReadReceipt: Bool = false,
    undoSendWindow: UndoSendWindow
  ) async -> Bool {
    guard connection.authorizationState == .authorized, connection.capabilities.canSend else {
      return false
    }
    let trimmedCcRecipients = ccRecipients.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBccRecipients = bccRecipients.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      _ = try await outboxService.edit(
        attempt.id,
        message: OutgoingMessage(
          body: body,
          recipient: recipient,
          subject: subject,
          htmlBody: document.map { assets.applyingInlineImageMetadata(to: $0.html) },
          semanticDocument: document,
          assets: assets,
          ccRecipients: trimmedCcRecipients.isEmpty ? nil : trimmedCcRecipients,
          bccRecipients: trimmedBccRecipients.isEmpty ? nil : trimmedBccRecipients,
          fromAddress: fromAddress,
          inReplyTo: attempt.message.inReplyTo,
          kind: attempt.mailboxConnectionId == connection.id ? attempt.message.kind : nil,
          providerThreadId: attempt.mailboxConnectionId == connection.id
            ? attempt.message.providerThreadId : nil,
          requestsReadReceipt: requestsReadReceipt
            && connection.capabilities.canRequestReadReceipts,
          sendingIdentityId: sendingIdentityId,
          sourceProviderMessageId: attempt.mailboxConnectionId == connection.id
            ? attempt.message.sourceProviderMessageId : nil
        ),
        connection: connection,
        session: session,
        undoSendDelayNanoseconds: undoSendWindow.nanoseconds,
        provider: outboxProvider(connections: knownConnections + [connection]),
        reconcile: outboxReconciler(connections: knownConnections + [connection])
      )
      remember(connection)
      await refreshOutbox()
      observeOutboxRetries()
      errorMessage = nil
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func retryOutboxAttempt(_ attempt: OutgoingDeliveryAttempt) async {
    guard
      let connection = knownConnections.first(where: {
        $0.id == attempt.mailboxConnectionId
      })
    else {
      errorMessage = "Authorize the sending Mailbox Connection before retrying."
      return
    }
    do {
      _ = try await outboxService.retry(
        attempt.id,
        connection: connection,
        session: session,
        provider: outboxProvider(connections: knownConnections),
        reconcile: outboxReconciler(connections: knownConnections)
      )
      await refreshOutbox()
      observeOutboxRetries()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func resolveUnknownOutboxAttempt(
    _ attempt: OutgoingDeliveryAttempt,
    asDelivered: Bool
  ) async {
    do {
      _ = try await outboxService.resolveUnknownOutcome(
        attempt.id,
        asDelivered: asDelivered,
        session: session
      )
      await refreshOutbox()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func refreshOutbox() async {
    do {
      outboxItems = try await outboxService.actionableItems(session: session)
        .filter { !$0.isScheduledSend }
    } catch {
      errorMessage = error.localizedDescription
    }
    do {
      scheduledSendItems = try await scheduledSendService.managedItems(session: session)
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func beginPreparingForSignOut() {
    isPreparingForSignOut = true
  }

  func cancelPreparingForSignOut() {
    isPreparingForSignOut = false
  }

  func resumeAfterSignOutRollback() async {
    cancelPreparingForSignOut()
    await resume(connections: knownConnections, revalidateProviderAccess: false)
  }

  func waitForPendingSend() async {
    guard isSending else { return }
    await withCheckedContinuation { continuation in
      sendCompletionWaiters.append(continuation)
    }
  }

  func suspendOutboxDelivery() async {
    await outboxService.suspend(productAccountId: session.productAccountId)
  }

  func prepareForSignOut() async {
    beginPreparingForSignOut()
    await waitForPendingSend()
    let pendingTasks = pendingActionTasks.compactMap { taskId, task in
      taskId == Self.currentPendingActionTaskId ? nil : task
    }
    for task in pendingTasks {
      task.cancel()
    }
    for task in pendingTasks {
      await task.value
    }
    pendingActionTasks.removeAll()
    deferredBulkFailures.removeAll()
    outboxRetryObservationTask?.cancel()
    retryObservationTask?.cancel()
    outboxItems = []
    scheduledSendItems = []
  }

  private func observeOutboxRetries() {
    outboxRetryObservationTask?.cancel()
    let outboxService = self.outboxService
    outboxRetryObservationTask = Task { [weak self] in
      while !Task.isCancelled {
        let waitedForRetry = await outboxService.waitForScheduledRetries()
        guard waitedForRetry, !Task.isCancelled, let self else { return }
        await refreshOutbox()
      }
    }
  }

  private func outboxProvider(
    connections: [MailboxConnection]
  ) -> OutboxDeliveryPerformer {
    let service = self.service
    let session = self.session
    let connectionsById = Dictionary(
      connections.map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    return { message, idempotencyKey, connectionId in
      guard await self.revalidateTrustedDevice() else { throw CancellationError() }
      guard let connection = connectionsById[connectionId] else {
        throw MailboxConnectionAdapterError.authorizationRequired
      }
      try await service.send(
        message.withIdempotencyKey(idempotencyKey),
        connection: connection,
        session: session
      )
    }
  }

  private func outboxReconciler(
    connections: [MailboxConnection]
  ) -> OutboxDeliveryReconciler {
    let service = self.service
    let session = self.session
    let connectionsById = Dictionary(
      connections.map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    return { idempotencyKey, connectionId in
      guard await self.revalidateTrustedDevice() else { throw CancellationError() }
      guard let connection = connectionsById[connectionId] else {
        throw MailboxConnectionAdapterError.authorizationRequired
      }
      return try await service.deliveryStatus(
        idempotencyKey: idempotencyKey,
        connection: connection,
        session: session
      )
    }
  }
}

extension GmailMailActionViewModel {
  // swiftlint:disable:next function_body_length
  func performBulk(
    _ action: ProviderMailAction,
    batches: [MailboxBulkActionBatch],
    deferredPendingActionConnectionIds: Set<MailboxConnectionId> = [],
    onEnqueued: @escaping @Sendable (MailboxConnection) async -> Void = { _ in },
    onDeferredCompletion: @escaping @Sendable (MailboxConnection) async -> Void = { _ in },
    shouldDeferPendingActions:
      @escaping @MainActor @Sendable (MailboxConnection) -> Bool = { _ in false }
  ) async -> MailboxBulkActionResult? {
    guard !batches.isEmpty,
      batches.allSatisfy({
        !$0.messages.isEmpty && $0.connection.capabilities.supports(action)
          && (action != .move || $0.targetProviderMailboxId != nil)
      }),
      !isPerformingAction
    else { return nil }
    isPerformingAction = true
    bulkActionProgress = MailboxBulkActionProgress(
      action: action,
      completedConnectionCount: 0,
      totalConnectionCount: batches.count
    )
    defer {
      bulkActionProgress = nil
      isPerformingAction = false
    }

    for batch in batches {
      remember(batch.connection)
    }
    let operationId = UUID()
    let outcomes = await performBulkBatches(
      action,
      batches: batches,
      deferredPendingActionConnectionIds: deferredPendingActionConnectionIds,
      onEnqueued: onEnqueued,
      shouldDeferPendingActions: shouldDeferPendingActions
    )
    await refreshFailureConnections(knownConnections)
    pruneDeferredBulkFailures()
    let result = bulkActionResult(outcomes)
    let activeFailures = result.failures.filter {
      activeFailureConnectionIds.contains($0.connectionId)
    }
    if !activeFailures.isEmpty {
      deferredBulkFailures[operationId] = activeFailures
    }
    updateBulkActionErrorMessage(
      adding: result.failures,
      includesDeferredFailures: errorMessage != nil
    )
    let deferredBatches: [MailboxTrackedBulkActionBatch] = outcomes.compactMap { outcome in
      guard
        outcome.wasEnqueued,
        outcome.deferredPendingAction
      else { return nil }
      return MailboxTrackedBulkActionBatch(
        batch: batches[outcome.batchIndex],
        selection: outcome.selection
      )
    }
    if !deferredBatches.isEmpty {
      await startDeferredPendingActions(
        action,
        batches: deferredBatches,
        taskId: operationId,
        immediateFailures: result.failures,
        onCompleted: onDeferredCompletion
      )
    }
    return result
  }

  private func startDeferredPendingActions(
    _ action: ProviderMailAction,
    batches: [MailboxTrackedBulkActionBatch],
    taskId: UUID,
    immediateFailures: [MailboxBulkActionFailure],
    onCompleted: @escaping @Sendable (MailboxConnection) async -> Void
  ) async {
    guard !isPreparingForSignOut, !Task.isCancelled else {
      await Self.releaseSelections(batches, service: service)
      return
    }
    deferredBulkFailures[taskId] = immediateFailures
    let nonPersistedImmediateFailures = immediateFailures.filter {
      !activeFailureConnectionIds.contains($0.connectionId)
    }
    let service = self.service
    pendingActionTasks[taskId] = Task { [weak self] in
      guard let self else {
        await Self.releaseSelections(batches, service: service)
        return
      }
      await resumeDeferredPendingActions(
        action,
        batches: batches,
        taskId: taskId,
        immediateFailures: immediateFailures,
        nonPersistedImmediateFailures: nonPersistedImmediateFailures,
        onCompleted: onCompleted
      )
      pendingActionTasks[taskId] = nil
    }
  }

  private func performBulkBatches(
    _ action: ProviderMailAction,
    batches: [MailboxBulkActionBatch],
    deferredPendingActionConnectionIds: Set<MailboxConnectionId>,
    onEnqueued: @escaping @Sendable (MailboxConnection) async -> Void,
    shouldDeferPendingActions:
      @escaping @MainActor @Sendable (MailboxConnection) -> Bool
  ) async -> [MailboxBulkActionBatchOutcome] {
    let service = self.service
    let session = self.session
    let revalidateTrustedDevice = self.revalidateTrustedDevice
    return await withTaskGroup(
      of: MailboxBulkActionBatchOutcome.self,
      returning: [MailboxBulkActionBatchOutcome].self
    ) { group in
      for (batchIndex, batch) in batches.enumerated() {
        group.addTask {
          await Self.performBulkBatch(
            action,
            batch: batch,
            batchIndex: batchIndex,
            service: service,
            session: session,
            revalidateTrustedDevice: revalidateTrustedDevice,
            defersPendingActions: deferredPendingActionConnectionIds.contains(
              batch.connection.id
            ),
            onEnqueued: onEnqueued,
            shouldDeferPendingActions: shouldDeferPendingActions
          )
        }
      }
      var completedOutcomes: [MailboxBulkActionBatchOutcome] = []
      for await outcome in group {
        completedOutcomes.append(outcome)
        bulkActionProgress = MailboxBulkActionProgress(
          action: action,
          completedConnectionCount: completedOutcomes.count,
          totalConnectionCount: batches.count
        )
      }
      return completedOutcomes.sorted { $0.batchIndex < $1.batchIndex }
    }
  }

  // swiftlint:disable:next function_body_length function_parameter_count
  nonisolated private static func performBulkBatch(
    _ action: ProviderMailAction,
    batch: MailboxBulkActionBatch,
    batchIndex: Int,
    service: MailboxProviderMailActing,
    session: ProductAccountSessionSnapshot,
    revalidateTrustedDevice: @escaping @MainActor @Sendable () async -> Bool,
    defersPendingActions: Bool,
    onEnqueued: @escaping @Sendable (MailboxConnection) async -> Void,
    shouldDeferPendingActions:
      @escaping @MainActor @Sendable (MailboxConnection) -> Bool
  ) async -> MailboxBulkActionBatchOutcome {
    do {
      let selection = try await service.performTracked(
        action,
        sourceProviderMailboxId: batch.sourceProviderMailboxId,
        targetProviderMailboxId: batch.targetProviderMailboxId,
        targetProviderStateIds: batch.targetProviderStateIds,
        messages: batch.messages,
        connection: batch.connection,
        session: session
      )
      let newlyDefersPendingActions = await shouldDeferPendingActions(batch.connection)
      let defersPendingActions =
        defersPendingActions || newlyDefersPendingActions
      guard !defersPendingActions else {
        return bulkActionOutcome(
          batch,
          index: batchIndex,
          deferredPendingAction: true,
          errorDescription: nil,
          failureDetails: nil,
          selection: selection,
          wasEnqueued: true
        )
      }
      await onEnqueued(batch.connection)
      let resumeError = await service.resumePendingActions(
        connections: [batch.connection],
        session: session,
        revalidateProviderAccess: {
          await revalidateTrustedDevice()
        }
      )
      let retryError = await service.waitForPendingActionRetries(
        connection: batch.connection,
        session: session
      )
      let failureLookup = await service.pendingActionFailureLookup(
        action,
        selection: selection,
        messages: batch.messages,
        connection: batch.connection,
        session: session
      )
      if let selection {
        await service.releasePendingActionSelection(selection, connection: batch.connection)
      }
      let failureEvidence = Self.bulkActionFailureEvidence(
        failureLookup,
        connectionErrors: [resumeError, retryError]
      )
      return bulkActionOutcome(
        batch,
        index: batchIndex,
        deferredPendingAction: false,
        errorDescription: failureEvidence.errorDescription,
        failureDetails: failureEvidence.details,
        selection: selection,
        wasEnqueued: true
      )
    } catch {
      return bulkActionOutcome(
        batch,
        index: batchIndex,
        deferredPendingAction: false,
        errorDescription: error.localizedDescription,
        failureDetails: nil,
        selection: nil,
        wasEnqueued: false
      )
    }
  }

  // swiftlint:disable:next function_body_length function_parameter_count
  private func resumeDeferredPendingActions(
    _ action: ProviderMailAction,
    batches: [MailboxTrackedBulkActionBatch],
    taskId: UUID,
    immediateFailures: [MailboxBulkActionFailure],
    nonPersistedImmediateFailures: [MailboxBulkActionFailure],
    onCompleted: @escaping @Sendable (MailboxConnection) async -> Void
  ) async {
    guard !Task.isCancelled else {
      await Self.releaseSelections(batches, service: service)
      return
    }
    _ = await withTaskGroup(
      of: MailboxBulkActionBatchOutcome.self,
      returning: [MailboxBulkActionBatchOutcome].self
    ) { group in
      let revalidateTrustedDevice = self.revalidateTrustedDevice
      for (batchIndex, trackedBatch) in batches.enumerated() {
        group.addTask { [service, session, revalidateTrustedDevice] in
          let batch = trackedBatch.batch
          let resumeError = await service.resumePendingActions(
            connections: [batch.connection],
            session: session,
            revalidateProviderAccess: {
              await revalidateTrustedDevice()
            }
          )
          let retryError = await service.waitForPendingActionRetries(
            connection: batch.connection,
            session: session
          )
          let failureLookup = await service.pendingActionFailureLookup(
            action,
            selection: trackedBatch.selection,
            messages: batch.messages,
            connection: batch.connection,
            session: session
          )
          if let selection = trackedBatch.selection {
            await service.releasePendingActionSelection(selection, connection: batch.connection)
          }
          let failureEvidence = Self.bulkActionFailureEvidence(
            failureLookup,
            connectionErrors: [resumeError, retryError]
          )
          return Self.bulkActionOutcome(
            batch,
            index: batchIndex,
            deferredPendingAction: true,
            errorDescription: failureEvidence.errorDescription,
            failureDetails: failureEvidence.details,
            selection: trackedBatch.selection,
            wasEnqueued: true
          )
        }
      }
      var outcomes: [MailboxBulkActionBatchOutcome] = []
      for await outcome in group {
        guard !Task.isCancelled else { return outcomes }
        outcomes.append(outcome)
        await recordDeferredOutcome(
          outcome,
          taskId: taskId,
          immediateFailures: immediateFailures,
          nonPersistedImmediateFailures: nonPersistedImmediateFailures,
          onCompleted: onCompleted
        )
      }
      return outcomes.sorted { $0.batchIndex < $1.batchIndex }
    }
  }

  nonisolated private static func releaseSelections(
    _ batches: [MailboxTrackedBulkActionBatch],
    service: MailboxProviderMailActing
  ) async {
    for batch in batches {
      if let selection = batch.selection {
        await service.releasePendingActionSelection(selection, connection: batch.batch.connection)
      }
    }
  }

  private func recordDeferredOutcome(
    _ outcome: MailboxBulkActionBatchOutcome,
    taskId: UUID,
    immediateFailures: [MailboxBulkActionFailure],
    nonPersistedImmediateFailures: [MailboxBulkActionFailure],
    onCompleted: @escaping @Sendable (MailboxConnection) async -> Void
  ) async {
    await refreshFailureConnections(knownConnections)
    let previousOperationFailures = deferredBulkFailures[taskId] ?? []
    pruneDeferredBulkFailures()
    let operationFailures = previousOperationFailures.filter {
      !immediateFailures.contains($0) || activeFailureConnectionIds.contains($0.connectionId)
    }
    let failures =
      operationFailures
      + nonPersistedImmediateFailures
      + bulkActionResult([outcome]).failures
    let uniqueFailures = failures.reduce(into: [MailboxBulkActionFailure]()) {
      if !$0.contains($1) {
        $0.append($1)
      }
    }
    let retainedImmediateFailures = immediateFailures.filter { uniqueFailures.contains($0) }
    let connectionOrder = Dictionary(
      uniqueKeysWithValues: knownConnections.enumerated().map { ($0.element.id, $0.offset) }
    )
    let deferredFailures = uniqueFailures.enumerated().filter {
      !immediateFailures.contains($0.element)
    }.sorted {
      let firstOrder = connectionOrder[$0.element.connectionId] ?? Int.max
      let secondOrder = connectionOrder[$1.element.connectionId] ?? Int.max
      return firstOrder == secondOrder ? $0.offset < $1.offset : firstOrder < secondOrder
    }.map(\.element)
    deferredBulkFailures[taskId] = retainedImmediateFailures + deferredFailures
    updateBulkActionErrorMessage()
    guard !Task.isCancelled else { return }
    await onCompleted(outcome.connection)
  }

  private func pruneDeferredBulkFailures() {
    deferredBulkFailures = deferredBulkFailures.reduce(into: [:]) { retained, entry in
      let failures =
        pendingActionTasks[entry.key] == nil && errorMessage == nil
        ? entry.value.filter { activeFailureConnectionIds.contains($0.connectionId) }
        : entry.value
      if !failures.isEmpty {
        retained[entry.key] = failures
      }
    }
  }

  private var activeFailureConnectionIds: Set<MailboxConnectionId> {
    Set(failedConnectionIds + blockedConnectionIds)
  }

  private func updateBulkActionErrorMessage(
    adding failures: [MailboxBulkActionFailure] = [],
    includesDeferredFailures: Bool = true
  ) {
    let retainedFailures =
      includesDeferredFailures
      ? deferredBulkFailures.values.flatMap { $0 } : []
    let failures = (retainedFailures + failures).reduce(
      into: [MailboxBulkActionFailure]()
    ) {
      if !$0.contains($1) {
        $0.append($1)
      }
    }
    errorMessage =
      failures.isEmpty
      ? nil
      : failures.map(Self.failureDescription).joined(separator: "\n")
  }

  nonisolated private static func combinedErrorDescription(_ errors: [String?]) -> String? {
    let descriptions = errors.compactMap { $0 }.reduce(into: [String]()) {
      if !$0.contains($1) {
        $0.append($1)
      }
    }
    return descriptions.isEmpty ? nil : descriptions.joined(separator: "\n")
  }

  nonisolated private static func bulkActionFailureEvidence(
    _ lookup: MailboxProviderActionFailureLookup?,
    connectionErrors: [String?]
  ) -> (errorDescription: String?, details: [MailboxProviderActionFailureDetail]?) {
    let connectionError =
      lookup?.coversSelectedMessageIds == true
      ? nil : combinedErrorDescription(connectionErrors)
    return (connectionError, connectionError == nil ? lookup?.details : nil)
  }

  // swiftlint:disable:next function_parameter_count
  nonisolated private static func bulkActionOutcome(
    _ batch: MailboxBulkActionBatch,
    index: Int,
    deferredPendingAction: Bool,
    errorDescription: String?,
    failureDetails: [MailboxProviderActionFailureDetail]?,
    selection: MailboxProviderActionSelection?,
    wasEnqueued: Bool
  ) -> MailboxBulkActionBatchOutcome {
    MailboxBulkActionBatchOutcome(
      batchIndex: index,
      connection: batch.connection,
      deferredPendingAction: deferredPendingAction,
      errorDescription: errorDescription,
      failureDetails: failureDetails,
      messages: batch.messages,
      selection: selection,
      wasEnqueued: wasEnqueued
    )
  }

  private func bulkActionResult(
    _ outcomes: [MailboxBulkActionBatchOutcome]
  ) -> MailboxBulkActionResult {
    let failures = outcomes.flatMap { outcome -> [MailboxBulkActionFailure] in
      if let failureDetails = outcome.failureDetails, !failureDetails.isEmpty {
        return failureDetails.map { detail in
          let failedMessages = outcome.messages.filter { detail.messageIds.contains($0.id) }
          return MailboxBulkActionFailure(
            connectionId: outcome.connection.id,
            connectionDisplayName: outcome.connection.displayName,
            description: detail.description,
            messageIds: detail.messageIds,
            messageCount: detail.messageIds.count,
            messageSubjects: failedMessages.map(\.subject)
          )
        }
      }
      guard let errorDescription = outcome.errorDescription else { return [] }
      return [
        MailboxBulkActionFailure(
          connectionId: outcome.connection.id,
          connectionDisplayName: outcome.connection.displayName,
          description: errorDescription,
          messageIds: outcome.messages.map(\.id),
          messageCount: outcome.messages.count,
          messageSubjects: outcome.messages.map(\.subject)
        )
      ]
    }
    return MailboxBulkActionResult(
      deferredConnectionIds: Set(
        outcomes.filter(\.deferredPendingAction).map(\.connection.id)
      ),
      failures: failures,
      succeededConnectionIds: outcomes.compactMap { outcome in
        failures.contains { $0.connectionId == outcome.connection.id } ? nil : outcome.connection.id
      }
    )
  }

  private static func failureDescription(_ failure: MailboxBulkActionFailure) -> String {
    let messageDescription = failure.messageIds.enumerated()
      .map { index, messageId in
        let subject =
          failure.messageSubjects.indices.contains(index)
          ? failure.messageSubjects[index] : "Message"
        return "\(subject) [\(messageId.rawValue)]"
      }
      .joined(separator: ", ")
    return "\(failure.connectionDisplayName) — \(messageDescription): \(failure.description)"
  }
}

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class GmailInboxViewModel {
  private struct LoadedRemoteMessageContentCacheEntry {
    let source: SanitizedMessageHTML
    let result: RemoteMessageContentLoadResult
  }

  private static var loadedImageBudgets: [String: LoadedMessageImageBudget] = [:]
  private static var loadSchedulers: [String: ProductAccountMailLoadScheduler] = [:]
  private static let maximumLoadedAttachmentByteCount = 25 * 1_024 * 1_024
  private static let maximumLoadedInlineImageByteCount = 20 * 1_024 * 1_024
  private static let maximumLoadedInlineImagePixelCount = 32 * 1_024 * 1_024
  private static let maximumLoadedMessageBodyTextByteCount = 5 * 1_024 * 1_024
  private var backfillTask: Task<Void, Never>?
  private var backfillTaskId: UUID?
  private let bodyPrefetcher: MailboxMessageBodyPrefetching?
  private let authorizedRemoteContentCache: AuthorizedRemoteContentCache
  private var bodyPrefetchTask: Task<Void, Never>?
  private var hasSignedOut = false
  private var displayedMessageBodyIds: Set<StableProviderMessageIdentity> = []
  private var loadedAttachmentByteCounts: [StableProviderMessageIdentity: Int] = [:]
  private var loadedInlineImageByteCounts: [StableProviderMessageIdentity: Int] = [:]
  private var loadedInlineImagePixelCounts: [StableProviderMessageIdentity: Int] = [:]
  private var loadedRemoteImageByteCounts: [StableProviderMessageIdentity: Int] = [:]
  private var loadedRemoteMessageContents:
    [StableProviderMessageIdentity: LoadedRemoteMessageContentCacheEntry] = [:]
  private var protectedRemoteContentKeys:
    [StableProviderMessageIdentity: Set<AuthorizedRemoteContentCacheKey>] = [:]
  private var productMailboxStateRevision = 0
  #if DEBUG
    @ObservationIgnored var initialThreadBatchDidPublish: (() async -> Void)?
  #endif
  private var loadedRemoteImagePixelCounts: [StableProviderMessageIdentity: Int] = [:]
  private let loadedImageBudget: LoadedMessageImageBudget
  private let loadScheduler: ProductAccountMailLoadScheduler
  private var loadedMessageBodyClearSignals: [StableProviderMessageIdentity: UUID] = [:]
  private var loadedMessageBodyTextByteCount = 0
  private var loadedMessageBodyTextOrder: [StableProviderMessageIdentity] = []
  private var loadedMessageBodyTexts: [StableProviderMessageIdentity: String] = [:]
  private var unavailableLoadedMessageBodyTextIds: Set<StableProviderMessageIdentity> = []
  private var visibleMessageBodyPrefetches: [StableProviderMessageIdentity: Bool] = [:]
  private var visibleMessageBodyPrefetchTasks:
    [StableThreadIdentity: (id: UUID, task: Task<Void, Never>)] = [:]
  private(set) var categoryOverrideErrorMessage: String?
  var errorMessage: String?
  var isAssigningCategory = false
  var isCategorizingHistorical = false
  var isLoading = false
  private var loadingMessageBodyCounts: [StableProviderMessageIdentity: Int] = [:]

  var isLoadingMessageBody: Bool {
    !loadingMessageBodyCounts.isEmpty
  }
  func isLoadingMessageBody(_ messageId: StableProviderMessageIdentity) -> Bool {
    loadingMessageBodyCounts[messageId, default: 0] > 0
  }
  var isSearching = false
  var isSyncing = false
  var searchQuery = ""
  var searchResult: GmailSearchResult?
  private(set) var threadProjectionRevision = 0
  var threads: [MailboxThread] = [] {
    didSet { threadProjectionRevision &+= 1 }
  }

  private(set) var currentConnectionId: MailboxConnectionId?
  private(set) var navigationSnapshot = MailboxNavigationSnapshot.empty
  private var currentCollection: MailboxMessageCollection = .role(.inbox)
  private var unifiedCollection: MailboxMessageCollection = .role(.inbox)
  private var unifiedConnectionIds: Set<MailboxConnectionId> = []
  private var unifiedLoadId: UUID?
  private var navigationLoadId: UUID?
  private let searchService: MailboxMessageSearching
  private let service: MailboxMetadataSyncing
  private var session: ProductAccountSessionSnapshot
  private let syncCoordinator: MailboxFreshnessViewModel?

  init(
    authorizedRemoteContentCache: AuthorizedRemoteContentCache = AuthorizedRemoteContentCache(),
    bodyPrefetcher: MailboxMessageBodyPrefetching? = nil,
    service: MailboxMetadataSyncing,
    searchService: MailboxMessageSearching,
    syncCoordinator: MailboxFreshnessViewModel? = nil,
    session: ProductAccountSessionSnapshot,
    productMailboxState: MailShellProductMailboxState = .empty
  ) {
    self.authorizedRemoteContentCache = authorizedRemoteContentCache
    let loadedImageBudget =
      Self.loadedImageBudgets[session.productAccountId] ?? LoadedMessageImageBudget()
    Self.loadedImageBudgets[session.productAccountId] = loadedImageBudget
    self.loadedImageBudget = loadedImageBudget
    let loadScheduler =
      Self.loadSchedulers[session.productAccountId] ?? ProductAccountMailLoadScheduler()
    Self.loadSchedulers[session.productAccountId] = loadScheduler
    self.loadScheduler = loadScheduler
    self.bodyPrefetcher = bodyPrefetcher
    navigationSnapshot = MailboxNavigationSnapshot(
      messagesByConnection: [:],
      pinnedThreadIds: productMailboxState.pinnedThreadIds,
      snoozedThreadIds: productMailboxState.snoozedThreadIds,
      outboxStates: productMailboxState.outboxStates
    )
    self.searchService = searchService
    self.service = service
    self.session = session
    self.syncCoordinator = syncCoordinator
  }

  isolated deinit {
    loadedImageBudget.attachmentByteCount -= loadedAttachmentByteCounts.values.reduce(0, +)
    loadedImageBudget.inlineByteCount -= loadedInlineImageByteCounts.values.reduce(0, +)
    loadedImageBudget.inlinePixelCount -= loadedInlineImagePixelCounts.values.reduce(0, +)
    loadedImageBudget.remoteByteCount -= loadedRemoteImageByteCounts.values.reduce(0, +)
    loadedImageBudget.remotePixelCount -= loadedRemoteImagePixelCounts.values.reduce(0, +)
    for keys in protectedRemoteContentKeys.values {
      authorizedRemoteContentCache.release(keys)
    }
  }

  var isRefreshDisabled: Bool {
    isCategorizingHistorical || isLoading || isSearching || isSyncing || backfillTask != nil
  }

  var areCachedMetadataActionsDisabled: Bool {
    isCategorizingHistorical || isLoading || isSearching || isSyncing
  }

  var isHistoricalBackfillRunning: Bool {
    backfillTask != nil
  }

  func historicalBackfillConnectionIds(
    for connections: [MailboxConnection]
  ) -> Set<MailboxConnectionId> {
    let connectionIds = Set(connections.map(\.id))
    var backfillConnectionIds =
      syncCoordinator?.historicalBackfillConnectionIds(in: connectionIds) ?? []
    if isHistoricalBackfillRunning, let currentConnectionId,
      connectionIds.contains(currentConnectionId)
    {
      backfillConnectionIds.insert(currentConnectionId)
    }
    return backfillConnectionIds
  }

  func isHistoricalBackfillRunning(for connections: [MailboxConnection]) -> Bool {
    !historicalBackfillConnectionIds(for: connections).isEmpty
  }

  func areProviderActionsDisabledDuringHistoricalBackfill(
    for connections: [MailboxConnection]
  ) -> Bool {
    let backfillConnectionIds = historicalBackfillConnectionIds(for: connections)
    return connections.contains {
      $0.providerId != .gmail && backfillConnectionIds.contains($0.id)
    }
  }

  var isBusy: Bool {
    isAssigningCategory || isCategorizingHistorical || isLoading || isSearching || isSyncing
  }

  func loadMessageBody(
    _ message: MailboxMessageMetadata,
    priority: MailLoadPriority = .interactive,
    using reader: MailboxMessageReading
  ) async throws -> MailboxMessageBody {
    loadingMessageBodyCounts[message.id, default: 0] += 1
    defer {
      let remainingCount = loadingMessageBodyCounts[message.id, default: 1] - 1
      loadingMessageBodyCounts[message.id] = remainingCount > 0 ? remainingCount : nil
    }
    let loadedBody = try await loadScheduler.loadMessageBody(
      for: message.id,
      maximumConcurrentPipelines: MailLoadConcurrencyPolicy.maximumConcurrentBodyPipelines(
        for: message.connectionId.providerId
      ),
      priority: priority
    ) {
      try await reader.loadMessageBody(message: message, session: self.session)
    }
    try Task.checkCancellation()
    let hasPresentationResources =
      !loadedBody.inlineImages.isEmpty
      || loadedBody.attachments.contains { $0.presentationData != nil }
    let body: MailboxMessageBody
    if hasPresentationResources {
      try Task.checkCancellation()
      body = try retainLoadedBodyPresentation(loadedBody, for: message.id)
    } else {
      discardLoadedMessageBodyPresentation(for: message.id, discardsRemoteContent: false)
      body = loadedBody
    }
    retainLoadedMessageBodyText(body.text, for: message.id)
    return body
  }

  func promoteMessageBodyLoad(_ messageId: StableProviderMessageIdentity) {
    loadScheduler.promoteMessageBodyLoad(for: messageId)
  }

  func loadMessageBodyText(
    _ message: MailboxMessageMetadata,
    using reader: MailboxMessageReading
  ) async throws -> String {
    if let loadedBodyText = loadedMessageBodyTexts[message.id] {
      return loadedBodyText
    }
    loadingMessageBodyCounts[message.id, default: 0] += 1
    defer {
      let remainingCount = loadingMessageBodyCounts[message.id, default: 1] - 1
      loadingMessageBodyCounts[message.id] = remainingCount > 0 ? remainingCount : nil
    }
    return try await loadScheduler.performInteractiveWork(
      connectionId: message.connectionId,
      maximumConcurrentPipelines: MailLoadConcurrencyPolicy.maximumConcurrentBodyPipelines(
        for: message.connectionId.providerId
      )
    ) {
      try await reader.loadMessageBodyText(message: message, session: session)
    }
  }

  // swiftlint:disable:next function_body_length
  func prefetchVisibleMessageBodies(
    in thread: MailboxThread,
    loadsRemoteImages: Bool,
    profileId: MailProfileId? = nil,
    using reader: MailboxMessageReading,
    remoteLoader: (
      (SanitizedMessageHTML, Int, Int) async throws
        -> RemoteMessageContentLoadResult
    )? = nil
  ) async {
    for message in thread.messages {
      guard !Task.isCancelled else { return }
      guard
        visibleMessageBodyPrefetches[message.id] != true,
        loadsRemoteImages || visibleMessageBodyPrefetches[message.id] == nil
      else { continue }
      let previousPrefetch = visibleMessageBodyPrefetches[message.id]
      visibleMessageBodyPrefetches[message.id] = loadsRemoteImages
      do {
        let body = try await loadScheduler.loadMessageBody(
          for: message.id,
          maximumConcurrentPipelines: MailLoadConcurrencyPolicy.maximumConcurrentBodyPipelines(
            for: message.connectionId.providerId
          ),
          priority: .speculative
        ) {
          try Task.checkCancellation()
          return try await reader.loadMessageBody(message: message, session: self.session)
        }
        try Task.checkCancellation()
        if loadsRemoteImages,
          case .html(let html) = try await MessageHTMLPresentation.prepare(
            body: body,
            removesQuotedReplies: MailShellConversationReader.removesQuotedReplies(
              from: message,
              in: thread
            ),
            sanitizer: { html, removesQuotedReplies in
              try MessageHTMLSanitizer.sanitize(
                html,
                removesQuotedReplies: removesQuotedReplies,
                messageSubject: message.subject
              )
            }
          ),
          !html.remoteImageReferences.isEmpty
        {
          let result = try await loadRemoteMessageContent(
            html,
            for: message.id,
            profileId: profileId,
            protectsCachedContent: false,
            using: remoteLoader
          )
          loadedRemoteMessageContents[message.id] = LoadedRemoteMessageContentCacheEntry(
            source: html,
            result: result
          )
        }
        visibleMessageBodyPrefetches[message.id] = loadsRemoteImages
      } catch is CancellationError {
        restoreVisiblePrefetch(previousPrefetch, for: message.id, expected: loadsRemoteImages)
        return
      } catch {
        restoreVisiblePrefetch(previousPrefetch, for: message.id, expected: loadsRemoteImages)
      }
    }
  }

  private func restoreVisiblePrefetch(
    _ previousPrefetch: Bool?,
    for messageId: StableProviderMessageIdentity,
    expected: Bool
  ) {
    if visibleMessageBodyPrefetches[messageId] == expected {
      visibleMessageBodyPrefetches[messageId] = previousPrefetch
    }
  }

  func startVisibleMessageBodyPrefetch(
    in thread: MailboxThread,
    loadsRemoteImages: Bool,
    profileId: MailProfileId? = nil,
    using reader: MailboxMessageReading
  ) {
    visibleMessageBodyPrefetchTasks[thread.id]?.task.cancel()
    let taskId = UUID()
    let task = Task { [weak self] in
      await Task.yield()
      guard !Task.isCancelled else { return }
      guard let self else { return }
      await prefetchVisibleMessageBodies(
        in: thread,
        loadsRemoteImages: loadsRemoteImages,
        profileId: profileId,
        using: reader
      )
      if visibleMessageBodyPrefetchTasks[thread.id]?.id == taskId {
        visibleMessageBodyPrefetchTasks[thread.id] = nil
      }
    }
    visibleMessageBodyPrefetchTasks[thread.id] = (taskId, task)
  }

  // swiftlint:disable:next function_body_length
  func loadRemoteMessageContent(
    _ html: SanitizedMessageHTML,
    for messageId: StableProviderMessageIdentity,
    profileId: MailProfileId? = nil,
    protectsCachedContent: Bool = true,
    maximumLoadDuration: TimeInterval = 30,
    using loader: (
      (SanitizedMessageHTML, Int, Int) async throws
        -> RemoteMessageContentLoadResult
    )? = nil
  ) async throws -> RemoteMessageContentLoadResult {
    if let cached = loadedRemoteMessageContents[messageId], cached.source == html {
      loadedRemoteMessageContents[messageId] = nil
      if protectsCachedContent {
        replaceProtectedRemoteContentKeys(cached.result.cachedKeys, for: messageId)
      }
      return cached.result
    }
    try Task.checkCancellation()
    let requestedMaximumByteCount =
      Self.maximumLoadedInlineImageByteCount - loadedImageBudget.inlineByteCount
      - loadedImageBudget.remoteByteCount
    let requestedMaximumPixelCount =
      Self.maximumLoadedInlineImagePixelCount - loadedImageBudget.inlinePixelCount
      - loadedImageBudget.remotePixelCount
    let result: RemoteMessageContentLoadResult
    if let loader {
      result = try await loader(
        html,
        requestedMaximumByteCount,
        requestedMaximumPixelCount
      )
    } else {
      result = try await RemoteMessageContentLoader(
        cache: authorizedRemoteContentCache,
        cacheContext: profileId.map {
          AuthorizedRemoteContentCacheContext(
            productAccountId: session.productAccountId,
            profileId: $0,
            messageId: messageId,
            html: html
          )
        },
        maximumConcurrentRequestCount:
          ProductAccountRemoteImageRequestGate.maximumConcurrentRequestsPerMessage,
        maximumLoadDuration: maximumLoadDuration,
        maximumTotalByteCount: requestedMaximumByteCount,
        maximumTotalPixelCount: requestedMaximumPixelCount,
        messageId: messageId,
        requestGate: loadScheduler.remoteImageRequests
      ).load(html)
    }
    try Task.checkCancellation()
    let remainingByteCount =
      Self.maximumLoadedInlineImageByteCount - loadedImageBudget.inlineByteCount
      - loadedImageBudget.remoteByteCount
    let remainingPixelCount =
      Self.maximumLoadedInlineImagePixelCount - loadedImageBudget.inlinePixelCount
      - loadedImageBudget.remotePixelCount
    guard result.loadedByteCount <= remainingByteCount,
      result.loadedPixelCount <= remainingPixelCount
    else {
      return RemoteMessageContentLoadResult(
        failedImageCount: html.remoteImageReferences.count,
        html: html,
        loadedImageCount: 0
      )
    }
    loadedRemoteImageByteCounts[messageId, default: 0] += result.loadedByteCount
    loadedImageBudget.remoteByteCount += result.loadedByteCount
    loadedRemoteImagePixelCounts[messageId, default: 0] += result.loadedPixelCount
    loadedImageBudget.remotePixelCount += result.loadedPixelCount
    if protectsCachedContent {
      replaceProtectedRemoteContentKeys(result.cachedKeys, for: messageId)
    }
    return result
  }

  private func replaceProtectedRemoteContentKeys(
    _ keys: Set<AuthorizedRemoteContentCacheKey>,
    for messageId: StableProviderMessageIdentity
  ) {
    if let previousKeys = protectedRemoteContentKeys.removeValue(forKey: messageId) {
      authorizedRemoteContentCache.release(previousKeys)
    }
    guard !keys.isEmpty else { return }
    authorizedRemoteContentCache.protect(keys)
    protectedRemoteContentKeys[messageId] = keys
  }

  func isLoadedMessageBodyTextUnavailable(
    for messageId: StableProviderMessageIdentity
  ) -> Bool {
    unavailableLoadedMessageBodyTextIds.contains(messageId)
  }

  func hasLoadedMessageBodyText(
    for messageId: StableProviderMessageIdentity
  ) -> Bool {
    loadedMessageBodyTexts[messageId] != nil
  }

  func loadedMessageBodyText(
    for messageId: StableProviderMessageIdentity
  ) -> String? {
    loadedMessageBodyTexts[messageId]
  }

  func discardLoadedMessageBodyText(for messageId: StableProviderMessageIdentity) {
    if let discardedText = loadedMessageBodyTexts.removeValue(forKey: messageId) {
      loadedMessageBodyTextByteCount -= discardedText.utf8.count
      loadedMessageBodyTextOrder.removeAll { $0 == messageId }
    }
    unavailableLoadedMessageBodyTextIds.insert(messageId)
  }

  func loadedMessageBodyClearSignal(
    for messageId: StableProviderMessageIdentity
  ) -> UUID? {
    loadedMessageBodyClearSignals[messageId]
  }

  func discardLoadedMessageBody(for messageId: StableProviderMessageIdentity) {
    discardLoadedMessageBodyText(for: messageId)
    visibleMessageBodyPrefetches[messageId] = nil
    loadedMessageBodyClearSignals[messageId] = UUID()
  }

  func discardLoadedMessageBodies(connectionId: MailboxConnectionId?) {
    let messageIds = Set(loadedMessageBodyTexts.keys)
      .union(loadedInlineImagePixelCounts.keys)
      .union(loadedRemoteImagePixelCounts.keys)
      .union(loadedRemoteMessageContents.keys)
      .union(visibleMessageBodyPrefetches.keys)
      .union(displayedMessageBodyIds)
      .filter { connectionId == nil || $0.connectionId == connectionId }
    for messageId in messageIds {
      discardLoadedMessageBody(for: messageId)
      if !displayedMessageBodyIds.contains(messageId) {
        discardLoadedMessageBodyPresentation(for: messageId)
      }
      // Mounted views release inline and attachment presentation resources after clearing.
      discardLoadedRemoteImages(for: messageId)
    }
  }

  func discardLoadedMessageBodyPresentation(
    for messageId: StableProviderMessageIdentity,
    discardsRemoteContent: Bool = true
  ) {
    loadedImageBudget.attachmentByteCount -=
      loadedAttachmentByteCounts.removeValue(forKey: messageId) ?? 0
    loadedImageBudget.inlineByteCount -=
      loadedInlineImageByteCounts.removeValue(
        forKey: messageId
      ) ?? 0
    loadedImageBudget.inlinePixelCount -=
      loadedInlineImagePixelCounts.removeValue(
        forKey: messageId
      ) ?? 0
    if discardsRemoteContent {
      discardLoadedRemoteImages(for: messageId)
    }
  }

  func discardLoadedRemoteImages(for messageId: StableProviderMessageIdentity) {
    loadedImageBudget.remoteByteCount -=
      loadedRemoteImageByteCounts.removeValue(forKey: messageId) ?? 0
    loadedImageBudget.remotePixelCount -=
      loadedRemoteImagePixelCounts.removeValue(forKey: messageId) ?? 0
    loadedRemoteMessageContents[messageId] = nil
    replaceProtectedRemoteContentKeys([], for: messageId)
    if visibleMessageBodyPrefetches[messageId] == true {
      visibleMessageBodyPrefetches[messageId] = false
    }
  }

  func markMessageBodyDisplayed(_ messageId: StableProviderMessageIdentity) {
    displayedMessageBodyIds.insert(messageId)
  }

  func markMessageBodyHidden(_ messageId: StableProviderMessageIdentity) {
    displayedMessageBodyIds.remove(messageId)
  }

  var messageCount: Int {
    threads.reduce(0) { count, thread in
      count + thread.messages.count
    }
  }

  private func retainLoadedMessageBodyText(
    _ text: String,
    for messageId: StableProviderMessageIdentity
  ) {
    unavailableLoadedMessageBodyTextIds.remove(messageId)
    if let replacedText = loadedMessageBodyTexts.removeValue(forKey: messageId) {
      loadedMessageBodyTextByteCount -= replacedText.utf8.count
      loadedMessageBodyTextOrder.removeAll { $0 == messageId }
    }
    let byteCount = text.utf8.count
    guard byteCount <= Self.maximumLoadedMessageBodyTextByteCount else {
      unavailableLoadedMessageBodyTextIds.insert(messageId)
      return
    }
    while loadedMessageBodyTextByteCount + byteCount
      > Self.maximumLoadedMessageBodyTextByteCount,
      let evictedMessageId = loadedMessageBodyTextOrder.first
    {
      loadedMessageBodyTextOrder.removeFirst()
      if let evictedText = loadedMessageBodyTexts.removeValue(forKey: evictedMessageId) {
        loadedMessageBodyTextByteCount -= evictedText.utf8.count
        unavailableLoadedMessageBodyTextIds.insert(evictedMessageId)
      }
    }
    loadedMessageBodyTexts[messageId] = text
    loadedMessageBodyTextOrder.append(messageId)
    loadedMessageBodyTextByteCount += byteCount
  }

  // swiftlint:disable:next function_body_length
  private func retainLoadedBodyPresentation(
    _ body: MailboxMessageBody,
    for messageId: StableProviderMessageIdentity
  ) throws -> MailboxMessageBody {
    discardLoadedMessageBodyPresentation(for: messageId, discardsRemoteContent: false)
    var remainingAttachmentByteCount =
      Self.maximumLoadedAttachmentByteCount - loadedImageBudget.attachmentByteCount
    var retainedAttachmentByteCount = 0
    let attachments = body.attachments.compactMap { attachment in
      guard let presentationData = attachment.presentationData else { return attachment }
      guard presentationData.count <= remainingAttachmentByteCount else {
        return MailboxMessageAttachment(
          byteCount: attachment.byteCount,
          filename: attachment.filename,
          id: attachment.id,
          mimeType: attachment.mimeType
        )
      }
      remainingAttachmentByteCount -= presentationData.count
      retainedAttachmentByteCount += presentationData.count
      return attachment
    }
    guard !body.inlineImages.isEmpty else {
      loadedAttachmentByteCounts[messageId] = retainedAttachmentByteCount
      loadedImageBudget.attachmentByteCount += retainedAttachmentByteCount
      return MailboxMessageBody(
        text: body.text,
        html: body.html,
        inlineImages: [],
        attachments: attachments
      )
    }
    let contentIDOccurrenceList =
      try body.html.map(
        MessageHTMLSanitizer.referencedSanitizedInlineImageContentIDOccurrences
      ) ?? []
    let contentIDOccurrences = Dictionary(
      grouping: contentIDOccurrenceList,
      by: { $0 }
    ).mapValues(\.count)
    var remainingByteCount =
      Self.maximumLoadedInlineImageByteCount - loadedImageBudget.inlineByteCount
      - loadedImageBudget.remoteByteCount
    var remainingPixelCount =
      Self.maximumLoadedInlineImagePixelCount - loadedImageBudget.inlinePixelCount
      - loadedImageBudget.remotePixelCount
    var retainedByteCount = 0
    var retainedPixelCount = 0
    let inlineImages = body.inlineImages.filter { image in
      let normalizedContentID = MessageHTMLSanitizer.normalizedContentID(image.contentID)
      let occurrenceCount = max(normalizedContentID.flatMap { contentIDOccurrences[$0] } ?? 0, 1)
      let (byteCount, byteCountOverflowed) = image.data.count.multipliedReportingOverflow(
        by: occurrenceCount
      )
      let (pixelCount, pixelCountOverflowed) = image.decodedPixelCount
        .multipliedReportingOverflow(by: occurrenceCount)
      guard
        !byteCountOverflowed,
        !pixelCountOverflowed,
        byteCount <= remainingByteCount,
        pixelCount <= remainingPixelCount
      else {
        return false
      }
      remainingByteCount -= byteCount
      remainingPixelCount -= pixelCount
      retainedByteCount += byteCount
      retainedPixelCount += pixelCount
      return true
    }
    loadedAttachmentByteCounts[messageId] = retainedAttachmentByteCount
    loadedImageBudget.attachmentByteCount += retainedAttachmentByteCount
    loadedInlineImageByteCounts[messageId] = retainedByteCount
    loadedImageBudget.inlineByteCount += retainedByteCount
    loadedInlineImagePixelCounts[messageId] = retainedPixelCount
    loadedImageBudget.inlinePixelCount += retainedPixelCount
    return MailboxMessageBody(
      text: body.text,
      html: body.html,
      inlineImages: inlineImages,
      attachments: attachments
    )
  }

  func prepareForProfileSwitch() {
    prepareNavigationForProfileSwitch()
    clearNavigationSnapshotForProfileSwitch()
    clearVisibleThreadsForProfileSwitch()
    prepareTransientStateForProfileSwitch()
  }

  func prepareNavigationForProfileSwitch() {
    cancelBackfill()
    cancelProfileSwitchTasks()
    resetProfileSwitchNavigationState()
  }

  func clearNavigationSnapshotForProfileSwitch() {
    if navigationSnapshot != .empty {
      navigationSnapshot = .empty
    }
    if !visibleMessageBodyPrefetches.isEmpty {
      visibleMessageBodyPrefetches = [:]
    }
  }

  func prepareTransientStateForProfileSwitch() {
    resetProfileSwitchTransientState()
  }

  private func cancelProfileSwitchTasks() {
    if let bodyPrefetchTask {
      bodyPrefetchTask.cancel()
      self.bodyPrefetchTask = nil
    }
    if !visibleMessageBodyPrefetchTasks.isEmpty {
      for prefetch in visibleMessageBodyPrefetchTasks.values {
        prefetch.task.cancel()
      }
      visibleMessageBodyPrefetchTasks = [:]
    }
  }

  private func resetProfileSwitchNavigationState() {
    if currentConnectionId != nil {
      currentConnectionId = nil
    }
    if !displayedMessageBodyIds.isEmpty {
      displayedMessageBodyIds = []
    }
    if !unifiedConnectionIds.isEmpty {
      unifiedConnectionIds = []
    }
    if unifiedLoadId != nil {
      unifiedLoadId = nil
    }
    if navigationLoadId != nil {
      navigationLoadId = nil
    }
    if isLoading {
      isLoading = false
    }
  }

  private func resetProfileSwitchTransientState() {
    if !searchQuery.isEmpty {
      searchQuery = ""
    }
    if searchResult != nil {
      searchResult = nil
    }
    if errorMessage != nil {
      errorMessage = nil
    }
  }

  func clearVisibleThreadsForProfileSwitch() {
    if currentConnectionId != nil {
      currentConnectionId = nil
    }
    guard !threads.isEmpty else { return }
    threads = []
  }

  func clear() {
    prepareForProfileSwitch()
    loadedImageBudget.attachmentByteCount -= loadedAttachmentByteCounts.values.reduce(0, +)
    loadedAttachmentByteCounts = [:]
    loadedImageBudget.inlineByteCount -= loadedInlineImageByteCounts.values.reduce(0, +)
    loadedInlineImageByteCounts = [:]
    loadedImageBudget.inlinePixelCount -= loadedInlineImagePixelCounts.values.reduce(0, +)
    loadedInlineImagePixelCounts = [:]
    loadedImageBudget.remoteByteCount -= loadedRemoteImageByteCounts.values.reduce(0, +)
    loadedRemoteImageByteCounts = [:]
    loadedImageBudget.remotePixelCount -= loadedRemoteImagePixelCounts.values.reduce(0, +)
    loadedRemoteImagePixelCounts = [:]
    loadedRemoteMessageContents = [:]
    for keys in protectedRemoteContentKeys.values {
      authorizedRemoteContentCache.release(keys)
    }
    protectedRemoteContentKeys = [:]
    loadedMessageBodyClearSignals = [:]
    loadedMessageBodyTextByteCount = 0
    loadedMessageBodyTextOrder = []
    loadedMessageBodyTexts = [:]
    unavailableLoadedMessageBodyTextIds = []
  }

  func loadUnifiedInbox(connections: [MailboxConnection]) async {
    await loadUnifiedMailbox(.inbox, connections: connections)
  }

  func updateProductMailboxState(_ state: MailShellProductMailboxState) {
    productMailboxStateRevision &+= 1
    navigationSnapshot = MailboxNavigationSnapshot(
      messagesByConnection: navigationSnapshot.messagesByConnection,
      pinnedThreadIds: state.pinnedThreadIds,
      snoozedThreadIds: state.snoozedThreadIds,
      outboxStates: state.outboxStates,
      providerMailboxesByConnection: navigationSnapshot.providerMailboxesByConnection
    )
    reprojectProductMailboxesIfNeeded()
  }

  func refreshBodyPrefetch(
    afterChanging threadIds: Set<StableThreadIdentity>,
    connections: [MailboxConnection]
  ) {
    guard !threadIds.isEmpty else { return }
    let connectionIds = Set(threadIds.map(\.connectionId))
    startBodyPrefetch(
      connections: connections.filter {
        $0.authorizationState == .authorized && connectionIds.contains($0.id)
      }
    )
  }

  func refreshPinnedBodyPrefetch(connections: [MailboxConnection]) {
    startBodyPrefetch(
      connections: connections.filter { $0.authorizationState == .authorized }
    )
  }

  func loadNavigation(connections: [MailboxConnection]) async {
    let loadId = UUID()
    navigationLoadId = loadId
    var messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]] = [:]
    var providerMailboxesByConnection: [MailboxConnectionId: [ProviderMailbox]] = [:]
    for connection in connections where connection.authorizationState == .authorized {
      await loadNavigation(
        for: connection,
        messagesByConnection: &messagesByConnection,
        providerMailboxesByConnection: &providerMailboxesByConnection
      )
    }
    updateNavigationSnapshot(
      messagesByConnection: messagesByConnection,
      providerMailboxesByConnection: providerMailboxesByConnection,
      loadId: loadId
    )
  }

  func loadInitialMailboxThenNavigation(
    connection: MailboxConnection,
    collection: MailboxMessageCollection,
    connections: [MailboxConnection]
  ) async {
    await loadAfterConnectionChange(
      connection: connection,
      collection: collection,
      synchronizes: false
    )
    guard !Task.isCancelled else { return }
    let retriesInitialMailbox = errorMessage != nil
    await loadNavigation(connections: connections)
    if retriesInitialMailbox, !Task.isCancelled {
      await loadAfterConnectionChange(
        connection: connection,
        collection: collection,
        synchronizes: false
      )
    }
  }

  private func loadNavigation(
    for connection: MailboxConnection,
    messagesByConnection: inout [MailboxConnectionId: [MailboxMessageMetadata]],
    providerMailboxesByConnection: inout [MailboxConnectionId: [ProviderMailbox]]
  ) async {
    if let result = try? await service.loadMailbox(
      .allObserved,
      connection: connection,
      session: session
    ) {
      messagesByConnection[connection.id] = result.messages
    }
    if let providerMailboxes = try? await service.loadProviderMailboxes(
      connection: connection,
      session: session
    ) {
      providerMailboxesByConnection[connection.id] = providerMailboxes
    }
  }

  private func updateNavigationSnapshot(
    messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]],
    providerMailboxesByConnection: [MailboxConnectionId: [ProviderMailbox]],
    loadId: UUID
  ) {
    guard navigationLoadId == loadId else { return }
    navigationSnapshot = MailboxNavigationSnapshot(
      messagesByConnection: messagesByConnection,
      pinnedThreadIds: navigationSnapshot.pinnedThreadIds,
      snoozedThreadIds: navigationSnapshot.snoozedThreadIds,
      outboxStates: navigationSnapshot.outboxStates,
      providerMailboxesByConnection: providerMailboxesByConnection
    )
  }

  // swiftlint:disable:next function_body_length
  func loadUnifiedMailbox(
    _ mailbox: UnifiedMailbox,
    connections: [MailboxConnection],
    synchronizes: Bool = true
  ) async {
    cancelBackfill()
    currentConnectionId = nil
    if unifiedCollection != mailbox.collection { threads = [] }
    unifiedCollection = mailbox.collection
    let authorizedConnections = connections.filter { $0.authorizationState == .authorized }
    let connectionIds = Set(authorizedConnections.map(\.id))
    unifiedConnectionIds = connectionIds
    let loadId = UUID()
    unifiedLoadId = loadId
    errorMessage = nil
    isLoading = true
    defer {
      if unifiedLoadId == loadId {
        isLoading = false
      }
    }

    var loadedThreadsByConnection = unifiedThreads(for: connectionIds)
    threads = MailboxThread.group(
      loadedThreadsByConnection.values.flatMap { $0 }.flatMap(\.messages)
    )
    guard
      let cacheErrors = await loadCachedUnifiedInboxes(
        for: authorizedConnections,
        collection: mailbox.collection,
        loadId: loadId,
        connectionIds: connectionIds,
        threadsByConnection: &loadedThreadsByConnection
      )
    else { return }
    guard synchronizes else {
      errorMessage = cacheErrors.isEmpty ? nil : cacheErrors.joined(separator: "\n")
      return
    }
    guard
      let syncResult = await syncUnifiedInboxes(
        for: authorizedConnections,
        collection: mailbox.collection,
        loadId: loadId,
        connectionIds: connectionIds,
        threadsByConnection: &loadedThreadsByConnection
      )
    else { return }
    isLoading = false
    guard
      let backfillErrors = await continueUnifiedInboxBackfill(
        for: syncResult.connectionsNeedingBackfill,
        collection: mailbox.collection,
        loadId: loadId,
        connectionIds: connectionIds,
        threadsByConnection: &loadedThreadsByConnection
      )
    else { return }
    let errors = cacheErrors + syncResult.errors + backfillErrors
    guard unifiedLoadId == loadId, unifiedConnectionIds == connectionIds else { return }
    errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
  }

  private func loadCachedUnifiedInboxes(
    for connections: [MailboxConnection],
    collection: MailboxMessageCollection,
    loadId: UUID,
    connectionIds: Set<MailboxConnectionId>,
    threadsByConnection: inout [MailboxConnectionId: [MailboxThread]]
  ) async -> [String]? {
    guard isCurrentUnifiedLoad(loadId: loadId, connectionIds: connectionIds) else { return nil }
    let outcomes = await performUnifiedMailboxPhase(
      .cache,
      connections: connections,
      collection: collection
    )
    guard
      !outcomes.contains(where: { $0.phaseResult.isCancelled }),
      await applyUnifiedInboxResults(
        outcomes,
        loadId: loadId,
        connectionIds: connectionIds,
        threadsByConnection: &threadsByConnection
      )
    else { return nil }
    return unifiedMailboxErrors(from: outcomes)
  }

  private func syncUnifiedInboxes(
    for connections: [MailboxConnection],
    collection: MailboxMessageCollection,
    loadId: UUID,
    connectionIds: Set<MailboxConnectionId>,
    threadsByConnection: inout [MailboxConnectionId: [MailboxThread]]
  ) async -> (connectionsNeedingBackfill: [MailboxConnection], errors: [String])? {
    guard isCurrentUnifiedLoad(loadId: loadId, connectionIds: connectionIds) else { return nil }
    let outcomes = await performUnifiedMailboxPhase(
      .sync,
      connections: connections,
      collection: collection
    )
    guard
      !outcomes.contains(where: { $0.phaseResult.isCancelled }),
      await applyUnifiedInboxResults(
        outcomes,
        loadId: loadId,
        connectionIds: connectionIds,
        threadsByConnection: &threadsByConnection
      )
    else { return nil }
    await withTaskGroup(of: Void.self) { group in
      for outcome in outcomes where outcome.phaseResult.isSuccess {
        group.addTask {
          await self.refreshNavigationSnapshot(for: outcome.connection)
        }
      }
    }
    guard isCurrentUnifiedLoad(loadId: loadId, connectionIds: connectionIds) else { return nil }
    return (
      outcomes.compactMap { outcome in
        outcome.phaseResult.needsBackfill ? outcome.connection : nil
      },
      unifiedMailboxErrors(from: outcomes)
    )
  }

  private func unifiedThreads(
    for connectionIds: Set<MailboxConnectionId>
  ) -> [MailboxConnectionId: [MailboxThread]] {
    Dictionary(
      grouping: threads.filter { connectionIds.contains($0.id.connectionId) },
      by: { $0.id.connectionId }
    )
  }

  private func continueUnifiedInboxBackfill(
    for connections: [MailboxConnection],
    collection: MailboxMessageCollection,
    loadId: UUID,
    connectionIds: Set<MailboxConnectionId>,
    threadsByConnection: inout [MailboxConnectionId: [MailboxThread]]
  ) async -> [String]? {
    guard isCurrentUnifiedLoad(loadId: loadId, connectionIds: connectionIds) else { return nil }
    let outcomes = await performUnifiedMailboxPhase(
      .backfill,
      connections: connections,
      collection: collection
    )
    guard
      !outcomes.contains(where: { $0.phaseResult.isCancelled }),
      await applyUnifiedInboxResults(
        outcomes,
        loadId: loadId,
        connectionIds: connectionIds,
        threadsByConnection: &threadsByConnection
      )
    else { return nil }
    return unifiedMailboxErrors(from: outcomes)
  }

  func load(
    connection: MailboxConnection,
    collection: MailboxMessageCollection = .role(.inbox),
    startsBackfill: Bool = true
  ) async {
    isLoading = true
    defer {
      isLoading = false
    }

    do {
      let result = try await loadProjectedMailbox(
        collection,
        connection: connection
      )
      try Task.checkCancellation()
      guard !hasSignedOut, currentConnectionId == connection.id
      else {
        return
      }
      threads = result.threads
      errorMessage = nil
      if startsBackfill,
        result.hasInitialMailboxAvailability,
        !result.historicalMetadataBackfillIsComplete
      {
        startBodyPrefetch(connections: [connection])
        startHistoricalBackfill(connection: connection)
      }
    } catch is CancellationError {
    } catch {
      guard !Task.isCancelled, !hasSignedOut, currentConnectionId == connection.id else {
        return
      }
      errorMessage = error.localizedDescription
    }
  }

  private func applyUnifiedInboxResults(
    _ outcomes: [UnifiedMailboxPhaseOutcome],
    loadId: UUID,
    connectionIds: Set<MailboxConnectionId>,
    threadsByConnection: inout [MailboxConnectionId: [MailboxThread]]
  ) async -> Bool {
    guard isCurrentUnifiedLoad(loadId: loadId, connectionIds: connectionIds) else { return false }
    for outcome in outcomes {
      if let result = outcome.phaseResult.result {
        threadsByConnection[outcome.connection.id] = result.threads
      }
    }
    let messages = threadsByConnection.values.flatMap { $0 }.flatMap(\.messages)
    let collection = unifiedCollection
    let projection = await projectedThreadsForPublication(messages, collection: collection)
    guard isCurrentUnifiedLoad(loadId: loadId, connectionIds: connectionIds) else { return false }
    return await publishInitialUnifiedThreads(
      projection.threads,
      projectionRevision: projection.revision,
      sourceMessages: messages,
      collection: collection,
      loadId: loadId,
      connectionIds: connectionIds
    )
  }

  // swiftlint:disable:next function_parameter_count
  private func publishInitialUnifiedThreads(
    _ initialProjectedThreads: [MailboxThread],
    projectionRevision initialProjectionRevision: Int,
    sourceMessages: [MailboxMessageMetadata],
    collection: MailboxMessageCollection,
    loadId: UUID,
    connectionIds: Set<MailboxConnectionId>
  ) async -> Bool {
    let firstBatchSize = 1
    let batchSize = 2
    guard threads.isEmpty, initialProjectedThreads.count > firstBatchSize else {
      threads = initialProjectedThreads
      return true
    }
    var projectedThreads = initialProjectedThreads
    var projectionRevision = initialProjectionRevision
    var publishedCount = 0
    while true {
      guard isCurrentUnifiedLoad(loadId: loadId, connectionIds: connectionIds) else {
        return false
      }
      if projectionRevision != productMailboxStateRevision {
        let projection = await projectedThreadsForPublication(
          sourceMessages,
          collection: collection
        )
        guard isCurrentUnifiedLoad(loadId: loadId, connectionIds: connectionIds) else {
          return false
        }
        projectedThreads = projection.threads
        projectionRevision = projection.revision
        if projectionRevision != productMailboxStateRevision { continue }
        publishedCount = 0
        threads.removeAll(keepingCapacity: true)
      }
      await waitForNextMainRunLoopCycle()
      guard isCurrentUnifiedLoad(loadId: loadId, connectionIds: connectionIds) else {
        return false
      }
      let nextBatchSize = publishedCount == 0 ? firstBatchSize : batchSize
      let endIndex = min(publishedCount + nextBatchSize, projectedThreads.count)
      threads.append(contentsOf: projectedThreads[publishedCount..<endIndex])
      publishedCount = endIndex
      guard publishedCount < projectedThreads.count else { return true }
      #if DEBUG
        await initialThreadBatchDidPublish?()
      #endif
      // The projection observer also crosses a run-loop boundary. Give every batch time to render
      // before adding the next one, or consecutive revisions can collapse into one frame.
      await waitForNextMainRunLoopCycle()
    }
  }

  private func projectedThreadsForPublication(
    _ messages: [MailboxMessageMetadata],
    collection: MailboxMessageCollection
  ) async -> (revision: Int, threads: [MailboxThread]) {
    let revision = productMailboxStateRevision
    let pinnedThreadIds = navigationSnapshot.pinnedThreadIds
    let snoozedThreadIds = navigationSnapshot.snoozedThreadIds
    let threads = await Task.detached {
      if collection == .pins || collection == .snoozed || collection == .role(.inbox) {
        return Self.projectedThreads(
          messages,
          to: collection,
          pinnedThreadIds: pinnedThreadIds,
          snoozedThreadIds: snoozedThreadIds
        )
      }
      return MailboxThread.group(messages)
    }.value
    return (revision, threads)
  }

  private func isCurrentUnifiedLoad(
    loadId: UUID,
    connectionIds: Set<MailboxConnectionId>
  ) -> Bool {
    !Task.isCancelled && unifiedLoadId == loadId && unifiedConnectionIds == connectionIds
  }

  private func unifiedMailboxErrors(
    from outcomes: [UnifiedMailboxPhaseOutcome]
  ) -> [String] {
    outcomes.compactMap { outcome in
      outcome.phaseResult.errorDescription.map { "\(outcome.connection.displayName): \($0)" }
    }
  }

  private func loadProjectedMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection
  ) async throws -> MailboxMetadataSyncResult {
    let result = try await Self.loadMailboxForProjection(
      collection,
      connection: connection,
      service: service,
      session: session
    )
    return result.projected(
      to: collection,
      pinnedThreadIds: navigationSnapshot.pinnedThreadIds,
      snoozedThreadIds: navigationSnapshot.snoozedThreadIds
    )
  }

  nonisolated private static func loadMailboxForProjection(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    service: MailboxMetadataSyncing,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let sourceCollection: MailboxMessageCollection =
      collection == .pins || collection == .snoozed ? .allObserved : collection
    return try await service.loadMailbox(
      sourceCollection,
      connection: connection,
      session: session
    )
  }

  private func performUnifiedMailboxPhase(
    _ phase: UnifiedMailboxPhase,
    connections: [MailboxConnection],
    collection: MailboxMessageCollection
  ) async -> [UnifiedMailboxPhaseOutcome] {
    let service = service
    let session = session
    let syncCoordinator = syncCoordinator
    return await withTaskGroup(
      of: UnifiedMailboxPhaseOutcome.self,
      returning: [UnifiedMailboxPhaseOutcome].self
    ) { group in
      for (connectionIndex, connection) in connections.enumerated() {
        group.addTask {
          let phaseResult = await Self.performUnifiedMailboxPhaseOperation(
            phase,
            collection: collection,
            connection: connection,
            service: service,
            session: session,
            syncCoordinator: syncCoordinator
          )
          return UnifiedMailboxPhaseOutcome(
            connectionIndex: connectionIndex,
            connection: connection,
            phaseResult: phaseResult
          )
        }
      }

      var outcomes: [UnifiedMailboxPhaseOutcome] = []
      for await outcome in group {
        outcomes.append(outcome)
        if outcome.phaseResult.isCancelled {
          group.cancelAll()
        }
      }
      return outcomes.sorted { $0.connectionIndex < $1.connectionIndex }
    }
  }

  // swiftlint:disable:next function_parameter_count
  nonisolated private static func performUnifiedMailboxPhaseOperation(
    _ phase: UnifiedMailboxPhase,
    collection: MailboxMessageCollection,
    connection: MailboxConnection,
    service: MailboxMetadataSyncing,
    session: ProductAccountSessionSnapshot,
    syncCoordinator: MailboxFreshnessViewModel?
  ) async -> UnifiedMailboxPhaseResult {
    do {
      let needsBackfill: Bool
      switch phase {
      case .cache:
        needsBackfill = false
      case .sync:
        let syncedResult =
          if let syncCoordinator {
            try await syncCoordinator.syncInbox(connection: connection, session: session)
          } else {
            try await service.syncInbox(connection: connection, session: session)
          }
        needsBackfill = !syncedResult.historicalMetadataBackfillIsComplete
      case .backfill:
        if let syncCoordinator {
          _ = try await syncCoordinator.continueHistoricalBackfill(
            connection: connection,
            session: session
          )
        } else {
          _ = try await service.continueHistoricalBackfill(
            connection: connection,
            session: session
          )
        }
        needsBackfill = false
      }
      let sourceCollection: MailboxMessageCollection =
        collection == .pins || collection == .snoozed ? .allObserved : collection
      let result = try await service.loadMailbox(
        sourceCollection,
        connection: connection,
        session: session
      )
      try Task.checkCancellation()
      return .success(result, needsBackfill: needsBackfill)
    } catch is CancellationError {
      return .cancelled
    } catch {
      return .failure(error.localizedDescription)
    }
  }

  func loadAfterConnectionChange(
    connection: MailboxConnection,
    collection: MailboxMessageCollection = .role(.inbox),
    synchronizes: Bool = true
  ) async {
    if currentConnectionId != connection.id || currentCollection != collection {
      cancelBackfill()
      currentConnectionId = connection.id
      currentCollection = collection
      unifiedConnectionIds = []
      unifiedLoadId = nil
      threads = []
      searchQuery = ""
      searchResult = nil
      errorMessage = nil
    }

    await load(
      connection: connection,
      collection: collection,
      startsBackfill: synchronizes
    )
    guard
      !Task.isCancelled,
      currentConnectionId == connection.id
    else {
      return
    }
    if synchronizes, backfillTask == nil {
      _ = await sync(connection: connection)
    }
  }

  func sync(connection: MailboxConnection) async -> Bool {
    cancelBackfill()
    bodyPrefetchTask?.cancel()
    bodyPrefetchTask = nil
    if currentConnectionId != connection.id {
      currentConnectionId = connection.id
      unifiedConnectionIds = []
      unifiedLoadId = nil
      threads = []
      errorMessage = nil
    }

    isSyncing = true
    defer {
      isSyncing = false
    }

    do {
      let syncResult = try await synchronizeInbox(connection: connection)
      let result = try await loadProjectedMailbox(
        currentCollection,
        connection: connection
      )
      guard !hasSignedOut, currentConnectionId == connection.id
      else {
        return false
      }
      threads = result.threads
      await refreshNavigationSnapshot(for: connection)
      errorMessage = nil
      if syncResult.hasInitialMailboxAvailability {
        startBodyPrefetch(connections: [connection])
      }
      if !syncResult.historicalMetadataBackfillIsComplete {
        startHistoricalBackfill(connection: connection)
      }
      return true
    } catch is CancellationError {
      return false
    } catch {
      let syncErrorMessage = error.localizedDescription
      if let result = try? await loadProjectedMailbox(
        currentCollection,
        connection: connection
      ), !Task.isCancelled, !hasSignedOut, currentConnectionId == connection.id {
        threads = result.threads
      }
      guard !Task.isCancelled, !hasSignedOut, currentConnectionId == connection.id else {
        return false
      }
      errorMessage = syncErrorMessage
      return false
    }
  }

  private func startHistoricalBackfill(connection: MailboxConnection) {
    guard backfillTask == nil else { return }
    let taskId = UUID()
    backfillTaskId = taskId
    backfillTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if backfillTaskId == taskId {
          backfillTask = nil
          backfillTaskId = nil
        }
      }
      do {
        _ = try await continueHistoricalBackfill(connection: connection)
        let backfill = try await loadProjectedMailbox(
          currentCollection,
          connection: connection
        )
        guard
          !Task.isCancelled,
          backfillTaskId == taskId,
          !hasSignedOut,
          currentConnectionId == connection.id
        else { return }
        threads = backfill.threads
        await refreshNavigationSnapshot(for: connection)
        startBodyPrefetch(connections: [connection])
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, backfillTaskId == taskId else { return }
        errorMessage = error.localizedDescription
      }
    }
  }

  private func startBodyPrefetch(connections: [MailboxConnection]) {
    guard !connections.isEmpty else { return }
    guard let bodyPrefetcher else { return }
    bodyPrefetchTask?.cancel()
    bodyPrefetchTask = Task { [weak self] in
      guard let self else { return }
      for connection in connections {
        do {
          try await loadScheduler.performSpeculativeWork(
            connectionId: connection.id,
            maximumConcurrentPipelines: MailLoadConcurrencyPolicy.maximumConcurrentBodyPipelines(
              for: connection.providerId
            )
          ) {
            try await bodyPrefetcher.prefetchMessageBodies(
              connection: connection,
              pinnedThreadIds: self.navigationSnapshot.pinnedThreadIds,
              referenceDate: Date(),
              session: self.session
            )
          }
        } catch {
          // Prefetch is best effort and must not block cached mailbox use.
        }
      }
    }
  }

  private func reprojectProductMailboxesIfNeeded() {
    let collection: MailboxMessageCollection
    let connectionIds: Set<MailboxConnectionId>
    if !unifiedConnectionIds.isEmpty {
      collection = unifiedCollection
      connectionIds = unifiedConnectionIds
    } else if let currentConnectionId {
      collection = currentCollection
      connectionIds = [currentConnectionId]
    } else {
      return
    }
    guard collection == .pins || collection == .snoozed || collection == .role(.inbox) else {
      return
    }
    let loadedMessages = connectionIds.flatMap {
      navigationSnapshot.messagesByConnection[$0] ?? []
    }
    let unloadedConnectionIds = connectionIds.filter {
      navigationSnapshot.messagesByConnection[$0] == nil
    }
    let preservedMessages = threads.flatMap(\.messages).filter {
      unloadedConnectionIds.contains($0.connectionId)
    }
    let messages = Dictionary(
      (loadedMessages + preservedMessages).map { ($0.id, $0) },
      uniquingKeysWith: { loaded, _ in loaded }
    ).values
    threads = Self.projectedThreads(
      Array(messages),
      to: collection,
      pinnedThreadIds: navigationSnapshot.pinnedThreadIds,
      snoozedThreadIds: navigationSnapshot.snoozedThreadIds
    )
  }

  nonisolated static func projectedThreads(
    _ messages: [MailboxMessageMetadata],
    to collection: MailboxMessageCollection,
    pinnedThreadIds: Set<StableThreadIdentity>,
    snoozedThreadIds: Set<StableThreadIdentity>
  ) -> [MailboxThread] {
    let visibleThreadIds = Set(
      messages.filter {
        collection.contains(
          providerStateIds: $0.providerStateIds,
          isPinned: pinnedThreadIds.contains($0.threadIdentity),
          isSnoozed: snoozedThreadIds.contains($0.threadIdentity)
        )
      }.map(\.threadIdentity)
    )
    return MailboxThread.group(messages).filter { visibleThreadIds.contains($0.id) }
  }

  func cancelBodyPrefetch() async {
    let task = bodyPrefetchTask
    bodyPrefetchTask = nil
    let visibleTasks = visibleMessageBodyPrefetchTasks.values.map(\.task)
    visibleMessageBodyPrefetchTasks = [:]
    task?.cancel()
    for visibleTask in visibleTasks {
      visibleTask.cancel()
    }
    if let task {
      await task.value
    }
    for visibleTask in visibleTasks {
      await visibleTask.value
    }
  }

  func prepareForSignOut() async {
    hasSignedOut = true
    cancelBackfill()
    await cancelBodyPrefetch()
  }

  func refresh(connection: MailboxConnection) async -> Bool {
    if currentConnectionId == connection.id {
      return await sync(connection: connection)
    }
    guard unifiedConnectionIds.contains(connection.id) else { return false }

    isSyncing = true
    defer { isSyncing = false }
    do {
      let syncResult = try await synchronizeInbox(connection: connection)
      let result = try await loadProjectedMailbox(
        unifiedCollection,
        connection: connection
      )
      guard !hasSignedOut, unifiedConnectionIds.contains(connection.id) else { return false }

      let otherMessages =
        threads
        .filter { $0.id.connectionId != connection.id }
        .flatMap(\.messages)

      threads = MailboxThread.group(otherMessages + result.threads.flatMap(\.messages))
      await refreshNavigationSnapshot(for: connection)
      errorMessage = nil
      if !syncResult.historicalMetadataBackfillIsComplete {
        startUnifiedHistoricalBackfill(connection: connection)
      }
      return true
    } catch is CancellationError {
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func reloadLocal(
    connection: MailboxConnection,
    refreshesNavigationSnapshot: Bool = true
  ) async -> Bool {
    do {
      if currentConnectionId == connection.id {
        let result = try await loadProjectedMailbox(
          currentCollection,
          connection: connection
        )
        guard !hasSignedOut, currentConnectionId == connection.id else { return false }
        threads = result.threads
      } else {
        guard unifiedConnectionIds.contains(connection.id) else { return false }
        let result = try await loadProjectedMailbox(
          unifiedCollection,
          connection: connection
        )
        guard !hasSignedOut, unifiedConnectionIds.contains(connection.id) else { return false }
        let otherMessages =
          threads
          .filter { $0.id.connectionId != connection.id }
          .flatMap(\.messages)
        threads = MailboxThread.group(otherMessages + result.threads.flatMap(\.messages))
      }
      if refreshesNavigationSnapshot {
        await refreshNavigationSnapshot(for: connection)
      }
      errorMessage = nil
      return true
    } catch is CancellationError {
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func cancelBackfill() {
    guard backfillTask != nil || backfillTaskId != nil else { return }
    backfillTask?.cancel()
    backfillTask = nil
    backfillTaskId = nil
  }

  private func synchronizeInbox(
    connection: MailboxConnection
  ) async throws -> MailboxMetadataSyncResult {
    if let syncCoordinator {
      return try await syncCoordinator.syncInbox(connection: connection, session: session)
    }
    return try await service.syncInbox(connection: connection, session: session)
  }

  private func continueHistoricalBackfill(
    connection: MailboxConnection
  ) async throws -> MailboxMetadataSyncResult {
    if let syncCoordinator {
      return try await syncCoordinator.continueHistoricalBackfill(
        connection: connection,
        session: session
      )
    }
    return try await service.continueHistoricalBackfill(
      connection: connection,
      session: session
    )
  }

  private func startUnifiedHistoricalBackfill(connection: MailboxConnection) {
    guard backfillTask == nil else { return }
    let taskId = UUID()
    backfillTaskId = taskId
    backfillTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if backfillTaskId == taskId {
          backfillTask = nil
          backfillTaskId = nil
        }
      }
      do {
        _ = try await continueHistoricalBackfill(connection: connection)
        let backfill = try await loadProjectedMailbox(
          unifiedCollection,
          connection: connection
        )
        guard
          !Task.isCancelled,
          backfillTaskId == taskId,
          unifiedConnectionIds.contains(connection.id)
        else { return }
        let otherMessages =
          threads
          .filter { $0.id.connectionId != connection.id }
          .flatMap(\.messages)
        threads = MailboxThread.group(otherMessages + backfill.threads.flatMap(\.messages))
        await refreshNavigationSnapshot(for: connection)
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, backfillTaskId == taskId else { return }
        errorMessage = error.localizedDescription
      }
    }
  }

  func searchLocal(categoryNamesById: [String: String]) {
    let messages = MailboxLocalMetadataSearch.messages(
      in: threads.flatMap(\.messages),
      matching: searchQuery,
      categoryNamesById: categoryNamesById
    )
    searchResult = GmailSearchResult(messages: messages, source: .localMetadata)
    errorMessage = nil
  }

  func searchProvider(connection: MailboxConnection) async {
    guard currentConnectionId == connection.id else { return }
    isSearching = true
    defer { isSearching = false }
    let query = searchQuery

    do {
      let messages = try await searchService.searchProvider(
        query: query,
        connection: connection,
        session: session
      )
      try Task.checkCancellation()
      guard
        currentConnectionId == connection.id,
        searchQuery == query
      else {
        return
      }
      searchResult = GmailSearchResult(messages: messages, source: .providerFullText)
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      guard
        currentConnectionId == connection.id,
        searchQuery == query
      else {
        return
      }
      errorMessage = error.localizedDescription
    }
  }

  func clearSearch() {
    searchQuery = ""
    searchResult = nil
  }

  private func refreshNavigationSnapshot(for connection: MailboxConnection) async {
    guard
      let result = try? await service.loadMailbox(
        .allObserved,
        connection: connection,
        session: session
      )
    else { return }
    let providerMailboxes = try? await service.loadProviderMailboxes(
      connection: connection,
      session: session
    )
    updateNavigationSnapshot(
      result: result,
      providerMailboxes: providerMailboxes,
      for: connection.id
    )
  }

  private func updateNavigationSnapshot(
    result: MailboxMetadataSyncResult,
    providerMailboxes: [ProviderMailbox]?,
    for connectionId: MailboxConnectionId
  ) {
    var messagesByConnection = navigationSnapshot.messagesByConnection
    if result.messages.allSatisfy({
      $0.connectionId == connectionId
    }) {
      messagesByConnection[connectionId] = result.messages
    }
    var providerMailboxesByConnection = navigationSnapshot.providerMailboxesByConnection
    if let providerMailboxes {
      providerMailboxesByConnection[connectionId] = providerMailboxes
    }
    navigationSnapshot = MailboxNavigationSnapshot(
      messagesByConnection: messagesByConnection,
      pinnedThreadIds: navigationSnapshot.pinnedThreadIds,
      snoozedThreadIds: navigationSnapshot.snoozedThreadIds,
      outboxStates: navigationSnapshot.outboxStates,
      providerMailboxesByConnection: providerMailboxesByConnection
    )
  }

  func categorizeHistorical(
    scope: HistoricalCategorizationScope,
    connection: MailboxConnection
  ) async {
    guard !isCategorizingHistorical else { return }
    isCategorizingHistorical = true
    defer { isCategorizingHistorical = false }

    do {
      let result = try await service.categorizeHistorical(
        scope: scope,
        connection: connection,
        session: session
      )
      guard currentConnectionId == connection.id else {
        return
      }
      let projected = result.projected(
        to: currentCollection,
        snoozedThreadIds: navigationSnapshot.snoozedThreadIds
      )
      threads = projected.threads
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      guard currentConnectionId == connection.id else {
        return
      }
      errorMessage = error.localizedDescription
    }
  }

  func overrideCategory(_ categoryId: String, for message: MailboxMessageMetadata) async {
    await setCategories([categoryId], for: message)
  }

  func setCategories(_ categoryIds: [String], for message: MailboxMessageMetadata) async {
    categoryOverrideErrorMessage = nil
    guard !isAssigningCategory else { return }
    isAssigningCategory = true
    defer { isAssigningCategory = false }

    replaceCategoryMemberships(message.assigningCategories(categoryIds))
    do {
      let overriddenMessage = try await service.setCategories(
        categoryIds,
        for: message,
        session: session
      )
      guard
        currentConnectionId == message.connectionId
          || (currentConnectionId == nil && unifiedConnectionIds.contains(message.connectionId))
      else {
        return
      }
      replaceCategoryMemberships(overriddenMessage)
      categoryOverrideErrorMessage = nil
    } catch is CancellationError {
      replaceCategoryMemberships(message)
    } catch {
      replaceCategoryMemberships(message)
      categoryOverrideErrorMessage = error.localizedDescription
    }
  }

  private func replaceCategoryMemberships(_ message: MailboxMessageMetadata) {
    let messages = threads.flatMap(\.messages).map { existingMessage in
      guard existingMessage.stableProviderMessageId == message.stableProviderMessageId else {
        return existingMessage
      }
      var updatedMessage = existingMessage
      updatedMessage.categoryId = message.categoryId
      updatedMessage.categoryIds = message.categoryIds
      return updatedMessage
    }
    threads = MailboxThread.group(messages)
  }

  func clearCategoryOverrideError() {
    categoryOverrideErrorMessage = nil
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    self.session = session
  }

  func clearError() {
    errorMessage = nil
  }
}

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class MailboxProviderConnectionViewModel {
  var connections: [MailboxConnection] = []
  private(set) var connectionsSnapshotIsAuthoritative = false
  var defaultSendingConnectionId: MailboxConnectionId?
  var errorMessage: String?
  var isConnecting = false
  var isLoading = false
  var isRemoving = false
  var isRenewingPushWatch = false
  var pushStatusMessage: String? {
    let messages = connections.compactMap { pushStatusMessages[$0.id] }
    return messages.isEmpty ? nil : messages.joined(separator: "\n")
  }
  var selectedConnectionId: MailboxConnectionId?

  private let isSessionCurrent: (ProductAccountSessionSnapshot) -> Bool
  private let revalidateTrustedDevice: () async -> Bool
  private var removalObservation: MailboxConnectionRemovalObservation?
  private let service: MailboxConnectionAdapter
  private var session: ProductAccountSessionSnapshot
  private var hasLoadedConnectionSnapshot = false
  private var pushStatusMessages: [MailboxConnectionId: String] = [:]

  init(
    service: MailboxConnectionAdapter,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool,
    revalidateTrustedDevice: @escaping () async -> Bool = { true },
    session: ProductAccountSessionSnapshot
  ) {
    self.isSessionCurrent = isSessionCurrent
    self.revalidateTrustedDevice = revalidateTrustedDevice
    self.service = service
    self.session = session
  }

  var canConnect: Bool {
    !isConnecting && !isLoading && !isRemoving && !isRenewingPushWatch
  }

  var isEditingDisabled: Bool {
    isConnecting || isLoading || isRemoving || isRenewingPushWatch
  }

  var isConfirmingRecreation: Bool { removalObservation != nil }

  var connection: MailboxConnection? {
    connections.first { $0.id == selectedConnectionId }
  }

  var sessionSnapshot: ProductAccountSessionSnapshot {
    get { session }
    set { session = newValue }
  }

  func load() async -> Bool {
    isLoading = true
    defer {
      isLoading = false
    }
    let prefersAuthoritativeDefault = selectedConnectionId == nil
    if !hasLoadedConnectionSnapshot {
      await loadCachedConnections()
    }
    guard await revalidateTrustedDevice(), isSessionCurrent(session) else { return false }

    do {
      let connectionsAreAuthoritative = try await refreshConnections()
      await completeLoadingConnections(prefersDefaultSelection: prefersAuthoritativeDefault)
      return connectionsAreAuthoritative
    } catch {
      let originalError = error
      do {
        let connectionsAreAuthoritative = try await refreshConnections()
        await completeLoadingConnections(prefersDefaultSelection: prefersAuthoritativeDefault)
        return connectionsAreAuthoritative
      } catch let error as MailboxConnectionLoadError {
        await completeLoadingConnections(prefersDefaultSelection: prefersAuthoritativeDefault)
        errorMessage = error.localizedDescription
        return false
      } catch {
        await completeLoadingConnections(prefersDefaultSelection: prefersAuthoritativeDefault)
        errorMessage = originalError.localizedDescription
        return false
      }
    }
  }

  func loadCachedConnections() async {
    guard let cacheLoader = service as? any MailboxConnectionCacheLoading else { return }
    do {
      connections = try await cacheLoader.loadCachedConnections(session: session)
        .sorted {
          $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
      defaultSendingConnectionId =
        try await cacheLoader.loadCachedDefaultSendingConnectionId(session: session)
      connectionsSnapshotIsAuthoritative = false
      hasLoadedConnectionSnapshot = true
      clearUnavailableDefaultSendingConnection()
      if selectedConnectionId == nil { restoreSelection() }
    } catch is CancellationError {
    } catch {
      // A missing or unreadable cache must not prevent the authoritative load.
    }
  }

  func refreshSnapshot() async -> Bool {
    do {
      let connectionsAreAuthoritative = try await refreshConnections()
      clearUnavailableDefaultSendingConnection()
      restoreSelection()
      errorMessage = nil
      return connectionsAreAuthoritative
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func completeLoadingConnections(prefersDefaultSelection: Bool) async {
    clearUnavailableDefaultSendingConnection()
    restoreSelection(prefersDefault: prefersDefaultSelection)
    pushStatusMessages = pushStatusMessages.filter { connectionId, _ in
      connections.contains { $0.id == connectionId }
    }
    errorMessage = nil
    for connection in connections {
      await refreshPushWatch(connection: connection)
    }
  }

  private func clearUnavailableDefaultSendingConnection() {
    if !connections.contains(where: {
      $0.id == defaultSendingConnectionId && $0.authorizationState == .authorized
    }) {
      defaultSendingConnectionId = nil
    }
  }

  private func restoreSelection(prefersDefault: Bool = false) {
    let authorizedConnections = connections.filter { $0.authorizationState == .authorized }
    let selectableConnections = authorizedConnections.isEmpty ? connections : authorizedConnections
    if prefersDefault,
      let defaultSendingConnectionId,
      selectableConnections.contains(where: { $0.id == defaultSendingConnectionId })
    {
      selectedConnectionId = defaultSendingConnectionId
      return
    }
    if !selectableConnections.contains(where: { $0.id == selectedConnectionId }) {
      selectedConnectionId =
        selectableConnections.first { $0.id == defaultSendingConnectionId }?.id
        ?? selectableConnections.first?.id
    }
  }

  func connect(expectedConnection: MailboxConnection? = nil) async -> MailboxConnection? {
    guard canConnect else { return nil }

    isConnecting = true
    defer {
      isConnecting = false
    }
    guard await revalidateTrustedDevice(), isSessionCurrent(session) else { return nil }

    do {
      let connected = try await service.connect(
        expectedConnectionId: expectedConnection?.id,
        removalObservation: expectedConnection == nil ? removalObservation : nil,
        session: session,
        isSessionCurrent: isSessionCurrent
      )
      errorMessage = nil
      if let connected {
        removalObservation = nil
        try await refreshConnections()
        selectedConnectionId = connected.id
        await refreshPushWatch(connection: connected)
        return connected
      }
    } catch is CancellationError {
    } catch let error as MailboxConnectionSyncError {
      switch error {
      case .connectionRemoved(let observation):
        removalObservation = observation
        _ = try? await refreshConnections()
        restoreSelection()
      case .concurrentModification:
        removalObservation = nil
        _ = try? await refreshConnections()
        restoreSelection()
      case .invalidDefaultSendingConnection, .missingProductSyncKeyMaterial:
        break
      }
      errorMessage = error.localizedDescription
    } catch {
      errorMessage = error.localizedDescription
    }
    return nil
  }

  func renewPushWatch() async {
    guard !isEditingDisabled else { return }
    isRenewingPushWatch = true
    defer { isRenewingPushWatch = false }
    for connection in connections {
      await refreshPushWatch(connection: connection)
    }
  }

  func removeLocalAuthorization(_ connection: MailboxConnection) async -> Bool {
    guard !isEditingDisabled else { return false }
    isRemoving = true
    defer { isRemoving = false }
    var removalCompleted = false
    do {
      try await service.clearLocalConnection(connection, session: session)
      removalCompleted = true
      try await refreshConnections()
      pushStatusMessages[connection.id] = nil
      selectedConnectionId = connection.id
      errorMessage = nil
      return true
    } catch {
      _ = try? await refreshConnections()
      pushStatusMessages = pushStatusMessages.filter { connectionId, _ in
        connections.contains { $0.id == connectionId }
      }
      if selectedConnectionId == connection.id {
        selectedConnectionId = connections.first?.id
      }
      errorMessage = error.localizedDescription
      return removalCompleted
    }
  }

  func removeEverywhere(_ connection: MailboxConnection) async -> Bool {
    guard !isEditingDisabled else { return false }
    isRemoving = true
    defer { isRemoving = false }
    var removalCompleted = false
    do {
      try await service.removeMailboxConnectionEverywhere(connection, session: session)
      removalCompleted = true
      try await refreshConnections()
      pushStatusMessages[connection.id] = nil
      if selectedConnectionId == connection.id {
        selectedConnectionId = connections.first?.id
      }
      errorMessage = nil
      return true
    } catch {
      _ = try? await refreshConnections()
      errorMessage = error.localizedDescription
      return removalCompleted
    }
  }

  func setDefaultSendingConnection(_ connection: MailboxConnection) async -> Bool {
    guard !isEditingDisabled else { return false }
    do {
      try await service.setDefaultSendingConnection(connection, session: session)
      defaultSendingConnectionId = connection.id
      selectedConnectionId = connection.id
      errorMessage = nil
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  private func refreshConnections() async throws -> Bool {
    let snapshot =
      if let snapshotLoader = service as? any MailboxConnectionSnapshotLoading {
        try await snapshotLoader.loadConnectionSnapshot(session: session)
      } else {
        MailboxConnectionLoadSnapshot(
          connections: try await service.loadConnections(session: session),
          isAuthoritative: true
        )
      }
    let loadedConnections = snapshot.connections
      .sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
    let hadAuthoritativeSnapshot = connectionsSnapshotIsAuthoritative
    do {
      if let loadErrorDescription = snapshot.loadErrorDescription {
        throw MailboxConnectionLoadError.partialProviderLoad(loadErrorDescription)
      }
      let loadedDefaultSendingConnectionId = try await service.loadDefaultSendingConnectionId(
        session: session
      )
      connectionsSnapshotIsAuthoritative = snapshot.isAuthoritative
      connections = loadedConnections
      hasLoadedConnectionSnapshot = true
      defaultSendingConnectionId = loadedDefaultSendingConnectionId
      return snapshot.isAuthoritative
    } catch {
      if !hadAuthoritativeSnapshot && !connectionsSnapshotIsAuthoritative {
        connectionsSnapshotIsAuthoritative = false
        connections = loadedConnections
        hasLoadedConnectionSnapshot = true
      }
      throw error
    }
  }

  private func refreshPushWatch(connection: MailboxConnection) async {
    guard connection.capabilities.canRegisterPush else {
      pushStatusMessages[connection.id] = nil
      return
    }
    do {
      try Task.checkCancellation()
      guard await revalidateTrustedDevice() else { return }
      guard isSessionCurrent(session), connections.contains(connection) else {
        return
      }
      try await service.registerOrRenewPush(
        connection: connection,
        session: session
      )
      pushStatusMessages[connection.id] = nil
    } catch is CancellationError {
    } catch {
      let providerName = connection.providerId.rawValue.capitalized
      pushStatusMessages[connection.id] =
        "\(providerName) is connected, but push wakeups are unavailable: \(error.localizedDescription)"
    }
  }
}

struct CustomCategoryEditorDraft: Equatable {
  var colorName = "blue"
  var description = ""
  var name = ""
  var symbolName = "tag.fill"

  init(category: CustomCategory? = nil) {
    guard let category else { return }
    colorName = category.colorName
    description = category.description ?? ""
    name = category.name
    symbolName = category.symbolName
  }

  var canSave: Bool {
    (1...40).contains(trimmedName.count) && description.count <= 500
      && CustomCategory.allowedColorNames.contains(colorName)
      && CustomCategory.allowedSymbolNames.contains(symbolName)
  }

  var trimmedDescription: String? {
    let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
    return description.isEmpty ? nil : description
  }

  var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

@MainActor
@Observable
final class CustomCategoryViewModel {
  private(set) var categories: [CustomCategory] = []
  private(set) var configuration = CategoryConfiguration.default
  var colorName = "blue"
  var description = ""
  var errorMessage: String?
  var isSaving = false
  var isSyncing = false
  var name = ""
  var symbolName = "tag.fill"

  var category: CustomCategory? {
    categories.first { $0.id == CustomCategorySyncPayload.primaryIdentifier }
      ?? categories.first
  }

  var hasLoadedCategory = false
  private let service: CustomCategorySyncing
  private var session: ProductAccountSessionSnapshot

  init(service: CustomCategorySyncing, session: ProductAccountSessionSnapshot) {
    self.service = service
    self.session = session
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    self.session = session
  }

  var canSave: Bool {
    let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return hasLoadedCategory && hasName && !isSaving && !isSyncing
  }

  var isEditingDisabled: Bool {
    isSaving || isSyncing
  }

  func load() async {
    isSyncing = true
    defer {
      isSyncing = false
    }

    do {
      async let categories = service.loadCategories(session: session)
      async let configuration = service.loadConfiguration(session: session)
      let (syncedCategories, syncedConfiguration) = try await (categories, configuration)
      apply(syncedCategories)
      self.configuration = syncedConfiguration
      hasLoadedCategory = true
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func save() async {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      return
    }

    let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
    isSaving = true
    defer {
      isSaving = false
    }

    do {
      let savedCategory = try await service.saveCategory(
        CustomCategory(
          id: category?.id ?? CustomCategorySyncPayload.primaryIdentifier,
          name: trimmedName,
          description: trimmedDescription.isEmpty ? nil : trimmedDescription,
          symbolName: symbolName,
          colorName: colorName
        ),
        session: session
      )
      upsert(savedCategory)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func create(_ draft: CustomCategoryEditorDraft) async throws -> CustomCategory {
    guard draft.canSave else { throw CustomCategorySyncError.invalidName }
    guard !isSaving else { throw CustomCategorySyncError.syncRemainedBusy }
    isSaving = true
    defer { isSaving = false }

    do {
      let category = try await service.saveCategory(
        CustomCategory(
          id: UUID().uuidString.lowercased(),
          name: draft.trimmedName,
          description: draft.trimmedDescription,
          symbolName: draft.symbolName,
          colorName: draft.colorName
        ),
        session: session
      )
      upsert(category)
      errorMessage = nil
      return category
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func save(
    _ category: CustomCategory,
    draft: CustomCategoryEditorDraft
  ) async throws -> CustomCategory {
    guard draft.canSave else { throw CustomCategorySyncError.invalidName }
    guard !isSaving else { throw CustomCategorySyncError.syncRemainedBusy }
    isSaving = true
    defer { isSaving = false }

    do {
      let savedCategory = try await service.saveCategory(
        CustomCategory(
          id: category.id,
          name: draft.trimmedName,
          description: draft.trimmedDescription,
          symbolName: draft.symbolName,
          colorName: draft.colorName,
          isEnabled: category.isEnabled
        ),
        session: session
      )
      upsert(savedCategory)
      errorMessage = nil
      return savedCategory
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func setEnabled(_ enabled: Bool, for category: CustomCategory) async {
    do {
      _ = try await service.saveCategory(
        CustomCategory(
          id: category.id,
          name: category.name,
          description: category.description,
          symbolName: category.symbolName,
          colorName: category.colorName,
          isEnabled: enabled
        ),
        session: session
      )
      if let index = categories.firstIndex(where: { $0.id == category.id }) {
        categories[index].isEnabled = enabled
      }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setAutomaticCategorizationEnabled(_ enabled: Bool) async {
    do {
      configuration = try await service.setAutomaticCategorizationEnabled(
        enabled,
        session: session
      )
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setSystemCategoryEnabled(_ enabled: Bool, categoryId: String) async {
    do {
      configuration = try await service.setSystemCategoryEnabled(
        enabled,
        categoryId: categoryId,
        session: session
      )
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func resetLearning() async {
    do {
      configuration = try await service.resetLearning(session: session)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func delete(id: String) async {
    isSaving = true
    defer { isSaving = false }
    do {
      try await service.deleteCategory(id: id, session: session)
      categories.removeAll { $0.id == id }
      apply(category)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func delete() async {
    isSaving = true
    defer {
      isSaving = false
    }

    do {
      guard let category else { return }
      try await service.deleteCategory(id: category.id, session: session)
      categories.removeAll { $0.id == category.id }
      apply(self.category)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func apply(_ syncedCategory: CustomCategory?) {
    name = syncedCategory?.name ?? ""
    description = syncedCategory?.description ?? ""
    symbolName = syncedCategory?.symbolName ?? "tag.fill"
    colorName = syncedCategory?.colorName ?? "blue"
  }

  private func apply(_ syncedCategories: [CustomCategory]) {
    categories = syncedCategories
    apply(category)
  }

  private func upsert(_ category: CustomCategory) {
    categories.removeAll { $0.id == category.id }
    categories.append(category)
    categories.sort {
      let order = $0.name.localizedCaseInsensitiveCompare($1.name)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
    if category.id == self.category?.id {
      apply(category)
    }
  }
}

struct CustomCategoryEditorFields: View {
  @Binding var colorName: String
  @Binding var description: String
  let isDisabled: Bool
  @Binding var name: String
  @Binding var symbolName: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Category name", text: $name)
        .textFieldStyle(.roundedBorder)

      TextField("Optional category description", text: $description, axis: .vertical)
        .lineLimit(2...4)
        .textFieldStyle(.roundedBorder)

      HStack {
        Picker("Icon", selection: $symbolName) {
          ForEach(CustomCategory.allowedSymbolNames, id: \.self) { symbolName in
            Label(symbolName.replacingOccurrences(of: ".fill", with: ""), systemImage: symbolName)
              .tag(symbolName)
          }
        }
        Picker("Color", selection: $colorName) {
          ForEach(CustomCategory.allowedColorNames, id: \.self) { colorName in
            Text(colorName.capitalized).tag(colorName)
          }
        }
      }
      .pickerStyle(.menu)
    }
    .disabled(isDisabled)
  }
}

private struct CustomCategoryPanel: View {
  @Bindable var viewModel: CustomCategoryViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Product Categories")
            .font(.headline)
          Text(
            "Custom categories sync between trusted devices separately from provider folders or labels."
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }

        Spacer()

        Button {
          Task {
            await viewModel.load()
          }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.isEditingDisabled)
      }

      CustomCategoryEditorFields(
        colorName: $viewModel.colorName,
        description: $viewModel.description,
        isDisabled: viewModel.isEditingDisabled,
        name: $viewModel.name,
        symbolName: $viewModel.symbolName
      )

      HStack {
        Button(viewModel.category == nil ? "Create Category" : "Save Category") {
          Task {
            await viewModel.save()
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.canSave)

        if viewModel.category != nil {
          Button("Delete", role: .destructive) {
            Task {
              await viewModel.delete()
            }
          }
          .buttonStyle(.bordered)
          .disabled(viewModel.isEditingDisabled)
        }
      }

      if viewModel.isSyncing {
        ProgressView("Syncing category...")
      }

      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .font(.footnote)
      }

    }
  }
}

private struct NotificationRulePanel: View {
  let categoryChoices: [MessageCategoryChoice]
  let hasLoadedCategory: Bool
  @Bindable var viewModel: NotificationRuleViewModel
  @State private var showsRefreshConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Notification Rules")
            .font(.headline)
          Text(
            "Choose which locally categorized messages can notify you. "
              + "Rules sync encrypted and are disabled by default."
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }

        Spacer()

        Button {
          if viewModel.hasUnsavedChanges {
            showsRefreshConfirmation = true
          } else {
            refresh()
          }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.isEditingDisabled)
      }

      Toggle(
        "Enable Category-Aware Notifications",
        isOn: Binding(
          get: { viewModel.isNotificationEnabled },
          set: viewModel.setNotificationEnabled
        )
      )
      .disabled(viewModel.isEditingDisabled)

      ForEach(categoryChoices) { category in
        Toggle(
          category.name,
          isOn: Binding(
            get: { viewModel.isEnabled(categoryId: category.id) },
            set: { viewModel.setEnabled($0, categoryId: category.id) }
          )
        )
        .disabled(viewModel.isEditingDisabled || !viewModel.isNotificationEnabled)
      }

      Divider()

      Toggle(
        "Generic Notification Fallback",
        isOn: Binding(
          get: { viewModel.isGenericNotificationFallbackEnabled },
          set: { isEnabled in
            Task {
              await viewModel.setGenericNotificationFallbackEnabled(isEnabled)
            }
          }
        )
      )

      Text(
        "When enabled, show a content-free new-mail notification only if category-aware "
          + "processing cannot finish. This device-only setting is off by default."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)

      Button("Save Notification Rules") {
        Task {
          await viewModel.save()
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!viewModel.canSave)

      if viewModel.isSyncing || viewModel.isSaving {
        ProgressView(viewModel.isSaving ? "Saving rules..." : "Syncing rules...")
      }

      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .font(.footnote)
      }

      if let fallbackErrorMessage = viewModel.fallbackErrorMessage {
        Text(fallbackErrorMessage)
          .foregroundStyle(.red)
          .font(.footnote)
      }
    }
    .onChange(of: Set(categoryChoices.map(\.id)), initial: false) { _, categoryIds in
      Task {
        await viewModel.prune(categoryIds: categoryIds)
      }
    }
    .onChange(of: hasLoadedCategory) { _, hasLoadedCategory in
      guard hasLoadedCategory else { return }
      Task {
        await viewModel.prune(categoryIds: Set(categoryChoices.map(\.id)))
      }
    }
    .confirmationDialog(
      "Discard unsaved notification rule changes?",
      isPresented: $showsRefreshConfirmation,
      titleVisibility: .visible
    ) {
      Button("Discard Changes and Refresh", role: .destructive) {
        refresh()
      }
    }
  }

  private func refresh() {
    Task {
      await viewModel.load(
        categoryIds: hasLoadedCategory ? Set(categoryChoices.map(\.id)) : nil
      )
    }
  }
}

struct GmailProviderConnectionPanel: View {
  let cancelBodyPrefetch: () async -> Void
  @Bindable var viewModel: MailboxProviderConnectionViewModel
  let isMailboxBusy: Bool
  let selectMailbox: (MailboxConnection) -> Void
  var connectionsDidChange: () -> Void = {}
  var manualRefreshDidComplete: () -> Void = {}

  var body: some View {
    MailboxProviderConnectionPanel(
      cancelBodyPrefetch: cancelBodyPrefetch,
      configuration: .gmail,
      connectionsDidChange: connectionsDidChange,
      isMailboxBusy: isMailboxBusy,
      manualRefreshDidComplete: manualRefreshDidComplete,
      selectMailbox: selectMailbox,
      viewModel: viewModel
    )
  }
}

struct MicrosoftGraphConnectionPanel: View {
  let cancelBodyPrefetch: () async -> Void
  let connectionsDidChange: () -> Void
  let connectionDidConnect: (MailboxConnection) -> Void
  let isMailboxBusy: Bool
  var manualRefreshDidComplete: () -> Void = {}
  let selectMailbox: (MailboxConnection) -> Void
  @Bindable var viewModel: MailboxProviderConnectionViewModel

  var body: some View {
    MailboxProviderConnectionPanel(
      cancelBodyPrefetch: cancelBodyPrefetch,
      configuration: .microsoftGraph,
      connectionsDidChange: connectionsDidChange,
      connectionDidConnect: connectionDidConnect,
      isMailboxBusy: isMailboxBusy,
      manualRefreshDidComplete: manualRefreshDidComplete,
      selectMailbox: selectMailbox,
      viewModel: viewModel
    )
  }
}

// swiftlint:disable:next type_body_length
struct MailboxProviderConnectionPanel: View {
  struct Configuration {
    let allowsDefaultSender: Bool
    let connectingTitle: String
    let emptyConnectTitle: String
    let loadingTitle: String
    let loadsOnAppear: Bool
    let otherConnectTitle: String
    let providerId: MailProviderId
    let removingTitle: String
    let showsProviderIdentity: Bool
    let showsPushStatus: Bool
    let title: String

    static let gmail = Configuration(
      allowsDefaultSender: true,
      connectingTitle: "Connecting Gmail...",
      emptyConnectTitle: "Sign in with Google",
      loadingTitle: "Loading Gmail...",
      loadsOnAppear: false,
      otherConnectTitle: "Connect another Gmail",
      providerId: .gmail,
      removingTitle: "Removing Gmail...",
      showsProviderIdentity: true,
      showsPushStatus: true,
      title: "Gmail"
    )

    static let microsoftGraph = Configuration(
      allowsDefaultSender: true,
      connectingTitle: "Connecting Microsoft mailbox...",
      emptyConnectTitle: "Sign in with Microsoft",
      loadingTitle: "Loading Microsoft mailboxes...",
      loadsOnAppear: true,
      otherConnectTitle: "Connect another Microsoft mailbox",
      providerId: .microsoftGraph,
      removingTitle: "Removing Microsoft mailbox...",
      showsProviderIdentity: false,
      showsPushStatus: false,
      title: "Microsoft 365"
    )
  }

  let cancelBodyPrefetch: () async -> Void
  let configuration: Configuration
  var connectionsDidChange: () -> Void = {}
  var connectionDidConnect: (MailboxConnection) -> Void = { _ in }
  let isMailboxBusy: Bool
  var manualRefreshDidComplete: () -> Void = {}
  let selectMailbox: (MailboxConnection) -> Void
  @Bindable var viewModel: MailboxProviderConnectionViewModel
  @State private var connectTask: Task<Void, Never>?
  @State private var connectionPendingEverywhereRemoval: MailboxConnection?

  private var connections: [MailboxConnection] {
    viewModel.connections.filter { $0.id.providerId == configuration.providerId }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(configuration.title)
            .font(.headline)
          Text(
            connections.isEmpty
              ? "Not connected"
              : "\(connections.count) mailbox connection\(connections.count == 1 ? "" : "s")"
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }

        Spacer()

        Button {
          Task {
            await Self.performManualRefresh(
              load: { _ = await viewModel.load() },
              connectionsDidChange: manualRefreshDidComplete
            )
          }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.isEditingDisabled)
      }

      ForEach(connections) { connection in
        HStack {
          Button {
            selectMailbox(connection)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Label(
                connection.displayName,
                systemImage: viewModel.connection?.id == connection.id
                  ? "checkmark.circle.fill" : "circle"
              )
              if configuration.showsProviderIdentity {
                Text(connection.providerMailboxIdentity.value)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Text(
                connection.authorizationState == .authorized
                  ? "Authorized on this device" : "Authorization required on this device"
              )
              .font(.caption)
              .foregroundStyle(
                connection.authorizationState == .authorized ? Color.secondary : Color.orange
              )
              if configuration.allowsDefaultSender,
                viewModel.defaultSendingConnectionId == connection.id
              {
                Label("Default sender", systemImage: "paperplane.fill")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)

          Menu {
            if connection.authorizationState == .required {
              Button("Authorize on This Device") {
                viewModel.selectedConnectionId = connection.id
                connectTask?.cancel()
                connectTask = Task {
                  if let connected = await viewModel.connect(expectedConnection: connection) {
                    connectionDidConnect(connected)
                    connectionsDidChange()
                  }
                }
              }
            } else {
              Button("Reauthorize on This Device") {
                viewModel.selectedConnectionId = connection.id
                connectTask?.cancel()
                connectTask = Task {
                  if let connected = await viewModel.connect(expectedConnection: connection) {
                    connectionDidConnect(connected)
                    connectionsDidChange()
                  }
                }
              }
              if configuration.allowsDefaultSender {
                Button("Set as Default Sending Connection") {
                  Task {
                    if await viewModel.setDefaultSendingConnection(connection) {
                      connectionsDidChange()
                    }
                  }
                }
                .disabled(viewModel.defaultSendingConnectionId == connection.id)
              }
              Button("Remove Device Authorization", role: .destructive) {
                Task {
                  await Self.performDestructiveAction(
                    cancelMailboxWork: cancelBodyPrefetch,
                    action: { await viewModel.removeLocalAuthorization(connection) },
                    connectionsDidChange: connectionsDidChange
                  )
                }
              }
            }
            Divider()
            Button("Remove Mailbox Connection Everywhere", role: .destructive) {
              connectionPendingEverywhereRemoval = connection
            }
          } label: {
            Label("Manage", systemImage: "ellipsis.circle")
          }
          .buttonStyle(.bordered)
          .disabled(viewModel.isEditingDisabled || isMailboxBusy)
        }
      }

      Button {
        connectTask?.cancel()
        connectTask = Task {
          if let connected = await viewModel.connect() {
            connectionDidConnect(connected)
            connectionsDidChange()
          }
        }
      } label: {
        Label(
          viewModel.isConfirmingRecreation
            ? "Recreate Removed Mailbox Connection"
            : (connections.isEmpty
              ? configuration.emptyConnectTitle : configuration.otherConnectTitle),
          systemImage: "person.crop.circle.badge.checkmark"
        )
        .frame(minHeight: 32)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!viewModel.canConnect)

      if viewModel.isLoading || viewModel.isConnecting || viewModel.isRemoving
        || viewModel.isRenewingPushWatch
      {
        ProgressView(
          viewModel.isConnecting
            ? configuration.connectingTitle
            : (viewModel.isRemoving
              ? configuration.removingTitle
              : (viewModel.isRenewingPushWatch
                ? "Renewing Gmail push..." : configuration.loadingTitle))
        )
      }

      if configuration.showsPushStatus, let pushStatusMessage = viewModel.pushStatusMessage {
        Text(pushStatusMessage)
          .foregroundStyle(.orange)
          .font(.footnote)
      }
    }
    .confirmationDialog(
      "Remove this Mailbox Connection everywhere?",
      isPresented: Binding(
        get: { connectionPendingEverywhereRemoval != nil },
        set: { isPresented in
          if !isPresented { connectionPendingEverywhereRemoval = nil }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("Cancel Scheduled Sends and Remove Connection", role: .destructive) {
        guard let connection = connectionPendingEverywhereRemoval else { return }
        connectionPendingEverywhereRemoval = nil
        Task {
          await Self.performDestructiveAction(
            cancelMailboxWork: cancelBodyPrefetch,
            action: { await viewModel.removeEverywhere(connection) },
            connectionsDidChange: connectionsDidChange
          )
        }
      }
      Button("Keep Mailbox Connection", role: .cancel) {
        connectionPendingEverywhereRemoval = nil
      }
    } message: {
      Text(
        "This cancels every Scheduled Send for this Mailbox Connection, then removes "
          + "the connection and its authorization from every trusted device. "
          + "Provider mail remains at the provider."
      )
    }
    .task {
      guard configuration.loadsOnAppear else { return }
      _ = await viewModel.load()
    }
    .onDisappear {
      connectTask?.cancel()
    }
  }

  @MainActor
  static func performManualRefresh(
    load: () async -> Void,
    connectionsDidChange: () -> Void
  ) async {
    await load()
    connectionsDidChange()
  }

  @MainActor
  static func performDestructiveAction(
    cancelMailboxWork: () async -> Void,
    action: () async -> Bool,
    connectionsDidChange: () -> Void
  ) async {
    await cancelMailboxWork()
    guard await action() else { return }
    connectionsDidChange()
  }
}

struct MessageCategoryChoice: Identifiable {
  let id: String
  let name: String
  let systemImage: String

  init(id: String, name: String, systemImage: String = "tag") {
    self.id = id
    self.name = name
    self.systemImage = systemImage
  }

  static func available(customCategory: CustomCategory?) -> [MessageCategoryChoice] {
    available(customCategories: customCategory.map { [$0] } ?? [])
  }

  static func available(customCategories: [CustomCategory]) -> [MessageCategoryChoice] {
    var choices = SystemCategoryDefinition.all.map {
      MessageCategoryChoice(id: $0.id, name: $0.name, systemImage: $0.symbolName)
    }
    choices += customCategories.filter(\.isEnabled).map {
      MessageCategoryChoice(id: $0.id, name: $0.name, systemImage: $0.symbolName)
    }
    return choices
  }

  static func available(
    customCategories: [CustomCategory],
    configuration: CategoryConfiguration
  ) -> [MessageCategoryChoice] {
    available(customCategories: customCategories).filter {
      !$0.id.hasPrefix("system:") || configuration.isSystemCategoryEnabled($0.id)
    }
  }
}

private struct HistoricalCategorizationPanel: View {
  let isDisabled: Bool
  let isWorking: Bool
  let categorize: (HistoricalCategorizationScope) -> Void
  @State private var endDate = Date()
  @State private var startDate =
    Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Categorize old emails")
        .font(.subheadline.bold())
      Text(
        "Old email stays Uncategorized by default. Choose a received-date range to process only "
          + "those historical messages."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)

      DatePicker("From", selection: $startDate, displayedComponents: .date)
      DatePicker("Through", selection: $endDate, displayedComponents: .date)

      Button("Categorize Selected Old Emails") {
        categorize(scope)
      }
      .disabled(
        !HistoricalCategorizationScope.isValidDateRange(
          startDate: startDate,
          endDate: endDate,
          calendar: .current
        ) || isDisabled
      )

      if isWorking {
        ProgressView("Categorizing selected old emails…")
      }
    }
  }

  private var scope: HistoricalCategorizationScope {
    let calendar = Calendar.current
    let receivedAtOrAfterDate = calendar.startOfDay(for: startDate)
    let selectedEndDate = calendar.startOfDay(for: endDate)
    let receivedBeforeDate =
      calendar.date(byAdding: .day, value: 1, to: selectedEndDate) ?? selectedEndDate
    return HistoricalCategorizationScope(
      receivedAtOrAfterMilliseconds: Int64(receivedAtOrAfterDate.timeIntervalSince1970 * 1_000),
      receivedBeforeMilliseconds: Int64(receivedBeforeDate.timeIntervalSince1970 * 1_000)
    )
  }
}

private struct MessageCategorySelector: View {
  let categoryChoices: [MessageCategoryChoice]
  let createCustomCategory: (CustomCategoryEditorDraft) async throws -> CustomCategory
  let apply: (Set<String>) async -> String?

  @Environment(\.dismiss) private var dismiss
  @State private var additionalChoices: [MessageCategoryChoice] = []
  @State private var applyErrorMessage: String?
  @State private var isApplying = false
  @State private var query = ""
  @State private var selection: MessageCategorySelection
  @State private var showsCategoryCreation = false

  init(
    categoryChoices: [MessageCategoryChoice],
    createCustomCategory: @escaping (CustomCategoryEditorDraft) async throws -> CustomCategory,
    selection: MessageCategorySelection,
    apply: @escaping (Set<String>) async -> String?
  ) {
    self.categoryChoices = categoryChoices
    self.createCustomCategory = createCustomCategory
    self.apply = apply
    var availableSelection = selection
    availableSelection.retainAvailableChoices(categoryChoices)
    _selection = State(initialValue: availableSelection)
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(filteredChoices) { choice in
          Button {
            selection.toggle(choice.id)
          } label: {
            HStack {
              Text(choice.name)
                .foregroundStyle(.primary)
              Spacer()
              if selection.selectedCategoryIds.contains(choice.id) {
                Image(systemName: "checkmark")
                  .foregroundStyle(.tint)
                  .accessibilityHidden(true)
              }
            }
          }
          .accessibilityValue(
            selection.selectedCategoryIds.contains(choice.id) ? "Selected" : "Not selected"
          )
        }

        Button {
          showsCategoryCreation = true
        } label: {
          Label("Add New Category", systemImage: "plus")
        }
      }
      .navigationTitle("Categories")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, prompt: "Search Categories")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isApplying)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Apply") {
            Task {
              isApplying = true
              defer { isApplying = false }
              if let errorMessage = await apply(selection.selectedCategoryIds) {
                applyErrorMessage = errorMessage
              } else {
                dismiss()
              }
            }
          }
          .disabled(isApplying)
        }
      }
      .overlay {
        if isApplying {
          ProgressView("Applying Categories…")
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
      }
      .interactiveDismissDisabled(isApplying)
      .alert("Couldn’t Apply Categories", isPresented: applyErrorBinding) {
        Button("OK") { applyErrorMessage = nil }
      } message: {
        Text(applyErrorMessage ?? "Categories could not be applied.")
      }
      .sheet(isPresented: $showsCategoryCreation) {
        CustomCategoryCreationView(create: createCustomCategory) { category in
          additionalChoices.removeAll { $0.id == category.id }
          additionalChoices.append(
            MessageCategoryChoice(
              id: category.id,
              name: category.name,
              systemImage: category.symbolName
            )
          )
          selection.selectedCategoryIds.insert(category.id)
        }
      }
    }
  }

  private var filteredChoices: [MessageCategoryChoice] {
    let choices = (categoryChoices + additionalChoices).reduce(
      into: [MessageCategoryChoice](),
      { choices, choice in
        if !choices.contains(where: { $0.id == choice.id }) {
          choices.append(choice)
        }
      }
    )
    return selection.filteredChoices(choices, query: query)
  }

  private var applyErrorBinding: Binding<Bool> {
    Binding(
      get: { applyErrorMessage != nil },
      set: { isPresented in
        if !isPresented { applyErrorMessage = nil }
      }
    )
  }
}

private struct CustomCategoryCreationView: View {
  let create: (CustomCategoryEditorDraft) async throws -> CustomCategory
  let didCreate: (CustomCategory) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var draft = CustomCategoryEditorDraft()
  @State private var errorMessage: String?
  @State private var isSaving = false

  var body: some View {
    NavigationStack {
      ScrollView {
        CustomCategoryEditorFields(
          colorName: $draft.colorName,
          description: $draft.description,
          isDisabled: isSaving,
          name: $draft.name,
          symbolName: $draft.symbolName
        )
        .padding()

        if let errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        }
      }
      .navigationTitle("New Category")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            Task {
              isSaving = true
              defer { isSaving = false }
              do {
                let category = try await create(draft)
                didCreate(category)
                dismiss()
              } catch {
                errorMessage = error.localizedDescription
              }
            }
          }
          .disabled(!draft.canSave || isSaving)
        }
      }
      .interactiveDismissDisabled(isSaving)
    }
  }
}

#Preview {
  AccountView(
    session: ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-preview",
          identityToken: "preview-token"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview)
    ),
    snapshot: ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-preview",
      identityToken: "preview-token",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
  )
  .environment(SettingsRouter())
  .environment(SettingsMailProfileContext())
  .environment(MessageContentPreferences())
}
