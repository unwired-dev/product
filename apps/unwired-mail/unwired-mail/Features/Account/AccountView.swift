import Combine
import SwiftUI

// swiftlint:disable file_length

extension Notification.Name {
  static let mailboxConnectionsDidChange = Notification.Name(
    "MailboxConnectionsDidChange"
  )
  static let mailboxMetadataDidSynchronize = Notification.Name(
    "MailboxMetadataDidSynchronize"
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

struct MailboxSyncStatus: Equatable {
  let lastSuccessfulSyncAt: Date?
  let phase: MailboxSyncPhase

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
    now: @escaping () -> Date = Date.init,
    successStore: MailboxSyncSuccessPersisting? = nil,
    sleep: @escaping (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
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
    return MailboxSyncStatus(lastSuccessfulSyncAt: lastSuccessfulSyncAt, phase: .syncing)
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
      phase: reportedPhase
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
      scope: .full
    )
  }

  private func syncRecentInbox(
    connection: MailboxConnection,
    session requestedSession: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await synchronizeInbox(
      connection: connection,
      session: requestedSession,
      scope: .recent
    )
  }

  // swiftlint:disable:next function_body_length
  private func synchronizeInbox(
    connection: MailboxConnection,
    session requestedSession: ProductAccountSessionSnapshot,
    scope: SyncScope
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
    statuses[connection.id] = MailboxSyncStatus(
      lastSuccessfulSyncAt: priorStatus.lastSuccessfulSyncAt,
      phase: .syncing
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
      let result = try await task.value
      guard isSessionCurrent(session), knownConnections[connection.id] != nil else {
        throw CancellationError()
      }
      removeSync(key: syncKey, syncId: syncId)
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
      phase: .syncing
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
      phase: .syncing
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

func newlyFailedConnectionIds(
  from oldIds: [MailboxConnectionId],
  to newIds: [MailboxConnectionId],
  mailboxObserversAreActive: Bool
) -> [MailboxConnectionId] {
  guard mailboxObserversAreActive else { return [] }
  return newIds.filter { !oldIds.contains($0) }
}

@MainActor
final class MailShellReleaseBudgetDriver {
  private var selectionHandlerOwner: UUID?
  fileprivate var selectMailboxHandler: ((MailShellMailboxSelection) -> Void)?
  private(set) var renderedItemIds: Set<MailboxThreadIdentity> = []

  func installSelectionHandler(
    owner: UUID,
    _ handler: @escaping (MailShellMailboxSelection) -> Void
  ) {
    selectionHandlerOwner = owner
    renderedItemIds = []
    selectMailboxHandler = handler
  }

  func removeSelectionHandler(owner: UUID) {
    guard selectionHandlerOwner == owner else { return }
    selectionHandlerOwner = nil
    selectMailboxHandler = nil
  }

  func selectMailbox(_ mailbox: MailShellMailboxSelection) {
    renderedItemIds = []
    selectMailboxHandler?(mailbox)
  }

  func recordRenderedItemId(_ itemId: MailboxThreadIdentity, owner: UUID) {
    guard selectionHandlerOwner == owner else { return }
    renderedItemIds.insert(itemId)
  }
}

// swiftlint:disable:next type_body_length
struct AccountView: View {
  let session: ProductAccountSession
  let snapshot: ProductAccountSessionSnapshot
  private let initialLaunchDidFinish: () -> Void
  private let mailboxConnection: MailboxConnectionAdapter
  private let messageReader: MailboxMessageReading
  private let releaseBudgetDriver: MailShellReleaseBudgetDriver?

  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.editMode) private var editMode
  @Environment(\.openWindow) private var openWindow
  @Environment(SettingsRouter.self) private var settingsRouter

  @State private var categoryViewModel: CustomCategoryViewModel
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var compositionDraft: MailShellCompositionDraft?
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
  @State private var mailShellSelection = MailShellSelectionModel()
  @State private var notificationRuleViewModel: NotificationRuleViewModel
  @State private var pinViewModel: PinViewModel
  @State private var readingPreferenceStore: ReadingPreferenceStore
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
  @State private var showsBlockedActionAlert = false
  @State private var showsAccountSettings = false
  @State private var showsDevelopmentSettings = false
  @State private var mailboxWorkCoordinator = MailboxWorkCoordinator.shared

  @MainActor
  // swiftlint:disable:next function_body_length
  init(
    session: ProductAccountSession,
    snapshot: ProductAccountSessionSnapshot,
    categorySyncService: CustomCategorySyncing = CustomCategorySyncService(),
    genericMailSetupService: GenericMailSetupService = GenericMailSetupService(),
    inboxPreferenceSync: InboxPreferenceSyncing = InboxPreferenceSyncService(),
    swipePreferenceSync: SwipePreferenceSyncing = SwipePreferenceSyncService(),
    mailboxConnection: MailboxConnectionAdapter = MailboxConnectionRouter(),
    notificationAuthorization: NotificationAuthorizationRequesting = UserNotificationService(),
    notificationRuleSync: NotificationRuleSyncing = NotificationRuleSyncService(),
    pinSyncService: PinSyncing = PinSyncService(),
    readingPreferenceSync: ReadingPreferenceSyncing = ReadingPreferenceSyncService(),
    initialLaunchDidFinish: @escaping () -> Void = {},
    releaseBudgetDriver: MailShellReleaseBudgetDriver? = nil
  ) {
    self.session = session
    self.snapshot = snapshot
    self.initialLaunchDidFinish = initialLaunchDidFinish
    self.mailboxConnection = mailboxConnection
    self.messageReader = mailboxConnection
    self.releaseBudgetDriver = releaseBudgetDriver
    let revalidateTrustedDevice = {
      await session.revalidateTrustedDeviceAfterForegrounding()
    }
    _categoryViewModel = State(
      initialValue: CustomCategoryViewModel(
        service: categorySyncService,
        session: snapshot
      )
    )
    _inboxPreferenceStore = State(
      initialValue: InboxPreferenceStore(
        session: snapshot,
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
      service: mailboxConnection
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
        service: notificationRuleSync,
        session: snapshot
      )
    )
    _pinViewModel = State(
      initialValue: PinViewModel(service: pinSyncService, session: snapshot)
    )
    _readingPreferenceStore = State(
      initialValue: ReadingPreferenceStore(
        session: snapshot,
        syncService: readingPreferenceSync
      )
    )
  }

  var body: some View {
    mailShell
  }

  private var genericMailReloadKey: [String] {
    genericMailSetupViewModel.connectionReloadKey
  }

  private var adaptiveSettingsAttentions: [SettingsAttention] {
    let connections = EmailAccountsSettingsView.makeSummaryConnections(
      routedConnections: gmailViewModel.connections,
      genericDefinitions: genericMailSetupViewModel.syncedDefinitions,
      authorizedGenericConnectionIds: genericMailSetupViewModel.authorizedSyncedConnectionIds,
      session: snapshot
    )
    let syncFailure = connections.lazy.compactMap { connection -> String? in
      guard case .failed(let message) = mailboxFreshnessViewModel.status(for: connection).phase
      else {
        return nil
      }
      return message
    }.first
    guard
      let attention = SettingsAttention.emailAccounts(
        authorizationRequired: connections.contains {
          $0.authorizationState == .required
        },
        syncFailureMessage: syncFailure
      )
    else {
      return []
    }
    return [attention]
  }

  private var mailShell: some View {
    mailboxWorkCoordinatedMailShell
      .onAppear {
        releaseBudgetDriver?.installSelectionHandler(owner: releaseBudgetDriverOwner) {
          selectedMailboxBinding.wrappedValue = $0
        }
      }
      .onDisappear {
        releaseBudgetDriver?.removeSelectionHandler(owner: releaseBudgetDriverOwner)
      }
      .onChange(of: pinViewModel.pinnedMessageIds) { oldValue, newValue in
        updateProductMailboxState()
        inboxViewModel.refreshBodyPrefetch(
          afterChanging: oldValue.symmetricDifference(newValue),
          connections: gmailViewModel.connections
        )
      }
      .onChange(of: mailActionViewModel.outboxItems) { _, _ in
        updateProductMailboxState()
      }
      .onChange(of: mailActionViewModel.pendingFailureConnectionId) { _, connectionId in
        showsBlockedActionAlert = connectionId != nil
      }
      .onChange(of: snapshot) { _, refreshedSnapshot in
        categoryViewModel.updateSession(refreshedSnapshot)
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
        pinViewModel.updateSession(refreshedSnapshot)
        readingPreferenceStore.updateSession(refreshedSnapshot)
      }
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
              let connection = gmailViewModel.connections.first(where: { $0.id == connectionId })
            else { continue }
            _ = await inboxViewModel.reloadLocal(connection: connection)
          }
          await inboxViewModel.loadNavigation(connections: gmailViewModel.connections)
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
          await inboxViewModel.loadNavigation(connections: gmailViewModel.connections)
        }
        guard mailShellSelection.selectedMailbox?.isUnified == true else { return }
        loadUnifiedMailbox()
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
        #if DEBUG && !targetEnvironment(macCatalyst)
          guard !showsDevelopmentSettings else { return }
        #endif
        Task {
          _ = await gmailViewModel.load()
        }
      }
      .onChange(of: inboxViewModel.threads) { _, threads in
        if mailShellSelection.selectedMailbox?.isUnified == true {
          if let connectionId = inboxViewModel.currentConnectionId {
            mailShellSelection.updateThreads(threads, for: connectionId)
          } else {
            mailShellSelection.replaceUnifiedThreads(
              threads,
              connectionIds: Set(gmailViewModel.connections.map(\.id))
            )
          }
        } else if let connectionId = mailShellSelection.selectedConnectionId {
          mailShellSelection.updateThreads(threads, for: connectionId)
        }
      }
      .onChange(of: mailShellSelection.navigationLevel) { _, _ in
        updatePreferredCompactColumn()
      }
      .onChange(of: editMode?.wrappedValue) { _, _ in
        updatePreferredCompactColumn()
      }
      .onDisappear {
        inboxLoadTask?.cancel()
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

  private var mailShellWithCoreLifecycleHandlers: some View {
    NavigationSplitView(
      columnVisibility: $columnVisibility,
      preferredCompactColumn: $preferredCompactColumn
    ) {
      MailShellSidebar(
        compose: {
          compositionDraft = .new(
            defaultSendingConnectionId: gmailViewModel.defaultSendingConnectionId
          )
        },
        connections: gmailViewModel.connections,
        errorMessage: gmailViewModel.errorMessage ?? pinViewModel.errorMessage
          ?? mailActionViewModel.errorMessage,
        isLoading: gmailViewModel.isLoading,
        isRefreshing: mailboxFreshnessViewModel.isSynchronizing,
        lastSuccessfulSyncAt: mailboxFreshnessViewModel.lastSuccessfulSyncAt,
        navigationSnapshot: inboxViewModel.navigationSnapshot,
        openSettings: { openSettings($0) },
        refreshMailboxes: {
          Task {
            guard await session.revalidateTrustedDeviceAfterForegrounding() else { return }
            guard session.isCurrentSessionIdentity(snapshot) else { return }
            await synchronizeMailboxesFully()
          }
        },
        selectedMailbox: selectedMailboxBinding,
        showAccountSettings: { showsAccountSettings = true },
        showDevelopmentSettings: { openSettings(nil) },
        syncStatus: mailboxFreshnessViewModel.status
      )
    } content: {
      MailShellThreadList(
        connection: selectedConnection,
        connections: gmailViewModel.connections,
        isConnectionBusy: gmailViewModel.isEditingDisabled,
        items: mailShellSelection.threadListItems(connections: gmailViewModel.connections),
        mailActionViewModel: mailActionViewModel,
        mailboxSelection: mailShellSelection.selectedMailbox,
        navigationSnapshot: inboxViewModel.navigationSnapshot,
        openSettings: openSettings,
        pinViewModel: pinViewModel,
        selectedThreadIds: selectedThreadsBinding,
        swipePreferences: swipePreferenceStore.preferences,
        viewModel: inboxViewModel,
        selectSearchResult: selectSearchResult,
        categoryChoices: MessageCategoryChoice.available(
          customCategory: categoryViewModel.category
        ),
        inboxPreferences: inboxPreferenceStore.preferences,
        readingPreferences: readingPreferenceStore.preferences,
        clearCachedBodies: {
          await inboxViewModel.cancelBodyPrefetch()
          guard !inboxViewModel.isLoadingMessageBody else { return }
          if let selectedConnection {
            try messageReader.clearCachedMessageBodies(
              connection: selectedConnection,
              session: snapshot
            )
          } else {
            try messageReader.clearCachedMessageBodies(session: snapshot)
          }
          inboxViewModel.discardLoadedMessageBodies(
            connectionId: selectedConnection?.id
          )
        },
        revalidateTrustedDevice: {
          guard await session.revalidateTrustedDeviceAfterForegrounding() else { return false }
          return session.isCurrentSessionIdentity(snapshot)
        },
        itemDidRender: {
          releaseBudgetDriver?.recordRenderedItemId($0.id, owner: releaseBudgetDriverOwner)
        }
      )
    } detail: {
      MailShellConversationReader(
        connections: gmailViewModel.connections,
        inboxViewModel: inboxViewModel,
        isConnectionBusy: gmailViewModel.isEditingDisabled,
        mailActionViewModel: mailActionViewModel,
        messageReader: messageReader,
        pinViewModel: pinViewModel,
        selection: mailShellSelection,
        session: snapshot,
        readingPreferences: readingPreferenceStore.preferences,
        revalidateTrustedDevice: {
          guard await session.revalidateTrustedDeviceAfterForegrounding() else { return false }
          return session.isCurrentSessionIdentity(snapshot)
        },
        categoryChoices: MessageCategoryChoice.available(
          customCategory: categoryViewModel.category
        )
      )
    }
    .navigationSplitViewStyle(.balanced)
    .sheet(isPresented: $showsAccountSettings) {
      accountSettings
    }
    #if DEBUG && !targetEnvironment(macCatalyst)
      .fullScreenCover(isPresented: $showsDevelopmentSettings) {
        AdaptiveSettingsScene(
          isSignedIn: true,
          showsDismissButton: true,
          attentions: adaptiveSettingsAttentions,
          hasUnsavedChanges: {
            ewsSetupViewModel.hasUnsavedChanges
              || genericMailSetupViewModel.hasUnsavedChanges
          },
          canDiscardChanges: {
            SettingsNavigationPolicy.canDiscardChanges(
              isSetupWorking: ewsSetupViewModel.isWorking
                || genericMailSetupViewModel.isConnecting
            )
          },
          discardChanges: {
            ewsSetupViewModel.discardUnsavedChanges()
            genericMailSetupViewModel.discardUnsavedChanges()
          },
          destinationContent: { destination, request in
            switch destination {
            case .accountAndDevices:
              AccountAndDevicesSettingsView(
                session: session,
                snapshot: snapshot,
                signOut: signOut
              )
            case .advanced:
              advancedSettings
            case .emailAccounts:
              EmailAccountsSettingsView(
                ewsViewModel: ewsSetupViewModel,
                genericMailViewModel: genericMailSetupViewModel,
                gmailViewModel: gmailViewModel,
                microsoftGraphViewModel: microsoftGraphViewModel,
                freshnessViewModel: mailboxFreshnessViewModel,
                cancelBodyPrefetch: {
                  await mailboxWorkCoordinator.cancelBodyPrefetch(
                    productAccountId: snapshot.productAccountId
                  )
                },
                connectionsDidChange: {},
                gmailConnectionsDidChange: {},
                isMailboxBusy: mailboxWorkCoordinator.isBusy(
                  productAccountId: snapshot.productAccountId
                ),
                navigationRequest: request
              )
            case .inbox:
              InboxSettingsView(
                store: inboxPreferenceStore,
                navigationRequest: request
              )
            case .reading:
              ReadingSettingsView(
                connections: gmailViewModel.connections,
                store: readingPreferenceStore,
                navigationRequest: request
              )
            case .swipes:
              SwipeSettingsView(store: swipePreferenceStore)
            case .appearance:
              AppearanceSettingsView()
            case .privacyAndData:
              PrivacyDataSettingsView(connections: gmailViewModel.connections)
            default:
              EmptyView()
            }
          }
        )
      }
    #endif
    .sheet(item: $compositionDraft) { draft in
      MailShellComposer(
        connections: gmailViewModel.connections,
        draft: draft,
        isSending: mailActionViewModel.isPerformingAction,
        readingPreferences: readingPreferenceStore.preferences,
        send: sendNewMessage
      )
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
    .task {
      #if canImport(UIKit)
        requestDevicePushRegistration()
      #endif
      await categoryViewModel.load()
      await inboxPreferenceStore.synchronize()
      await readingPreferenceStore.synchronize()
      await swipePreferenceStore.synchronize()
      await notificationRuleViewModel.load(
        categoryIds: categoryViewModel.hasLoadedCategory
          ? Set(
            MessageCategoryChoice.available(customCategory: categoryViewModel.category).map(\.id)
          )
          : nil
      )
      await reloadSyncedMailState()
      if mailShellSelection.selectedMailbox?.isUnified == true {
        loadUnifiedMailbox(synchronizes: false)
        await waitForCurrentMailboxLoad {
          (inboxLoadTask, inboxLoadGeneration)
        }
      } else if let connection = selectedConnection,
        connection.authorizationState == .authorized
      {
        let collection = mailShellSelection.selectedMailbox?.collection ?? .role(.inbox)
        let connections = gmailViewModel.connections
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
      mailboxObserversAreActive = true
      await mailboxFreshnessViewModel.synchronize(
        connections: gmailViewModel.connections,
        snapshotIsAuthoritative: gmailViewModel.connectionsSnapshotIsAuthoritative
      )
      await reloadObservedMailboxes()
      inboxViewModel.refreshPinnedBodyPrefetch(connections: gmailViewModel.connections)
      initialLaunchDidFinish()
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
        await inboxPreferenceStore.synchronize()
        await readingPreferenceStore.synchronize()
        await swipePreferenceStore.synchronize()
        await reloadSyncedMailState()
        await synchronizeMailboxes()
        inboxViewModel.refreshPinnedBodyPrefetch(connections: gmailViewModel.connections)
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
      NotificationCenter.default.publisher(for: .mailboxConnectionsDidChange)
        .receive(on: RunLoop.main)
    ) { notification in
      guard
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.productAccountId]
          as? String == snapshot.productAccountId
      else { return }
      Task { await reloadSyncedMailState() }
    }
  }

  private func openSettings(_ route: SettingsRoute?) {
    #if DEBUG
      settingsRouter.open(route)
      #if targetEnvironment(macCatalyst)
        openWindow(id: "development-settings")
      #else
        showsDevelopmentSettings = true
      #endif
    #else
      showsAccountSettings = true
    #endif
  }

  private func updateProductMailboxState() {
    inboxViewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: mailActionViewModel.outboxStates,
        pinnedMessageIds: pinViewModel.pinnedMessageIds
      )
    )
  }

  private func reloadSyncedMailState() async {
    await pinViewModel.load()
    updateProductMailboxState()
    let connectionsAreAuthoritative = await gmailViewModel.load()
    mailboxFreshnessViewModel.updateConnections(
      gmailViewModel.connections,
      snapshotIsAuthoritative: connectionsAreAuthoritative,
      prunesPersistedState: connectionsAreAuthoritative
    )
    await mailActionViewModel.resume(connections: gmailViewModel.connections)
    updateProductMailboxState()
    showsBlockedActionAlert = mailActionViewModel.pendingFailureConnectionId != nil
    await genericMailSetupViewModel.loadSyncedDefinitions()
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
    return gmailViewModel.connections.first { $0.id == connectionId }
  }

  private func acknowledgePendingActionFailure(connection: MailboxConnection) {
    Task {
      await mailActionViewModel.acknowledgeFailures(connection: connection)
      await inboxViewModel.loadNavigation(connections: gmailViewModel.connections)
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
      await inboxViewModel.loadNavigation(connections: gmailViewModel.connections)
      showsBlockedActionAlert = mailActionViewModel.pendingFailureConnectionId != nil
    }
  }

  private var selectedConnection: MailboxConnection? {
    guard let connectionId = mailShellSelection.selectedConnectionId else { return nil }
    return gmailViewModel.connections.first { $0.id == connectionId }
  }

  private func updatePreferredCompactColumn() {
    preferredCompactColumn = mailShellSelection.compactColumn(
      isEditing: editMode?.wrappedValue == .active
    )
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
    let connections = gmailViewModel.connections
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
      connections: gmailViewModel.connections,
      snapshotIsAuthoritative: gmailViewModel.connectionsSnapshotIsAuthoritative
    )
    await reloadObservedMailboxes()
  }

  private func reloadObservedMailboxes() async {
    await inboxViewModel.loadNavigation(connections: gmailViewModel.connections)
    if mailShellSelection.selectedMailbox?.isUnified == true {
      loadUnifiedMailbox(synchronizes: false)
    } else if let connection = selectedConnection,
      connection.authorizationState == .authorized
    {
      loadMailbox(for: connection, synchronizes: false)
    }
  }

  private func sendNewMessage(_ draft: MailShellCompositionDraft) async -> Bool {
    guard await session.revalidateTrustedDeviceAfterForegrounding() else { return false }
    guard session.isCurrentSessionIdentity(snapshot) else { return false }
    guard
      let connectionId = draft.connectionId,
      let connection = gmailViewModel.connections.first(where: { $0.id == connectionId })
    else {
      return false
    }
    return await mailActionViewModel.send(
      recipient: draft.recipient,
      subject: draft.subject,
      body: draft.body,
      replyTo: nil,
      connection: connection,
      requestsReadReceipt: draft.requestsReadReceipt
    )
  }

  private func handleThreadsChange(_ threads: [MailboxThread]) {
    if mailShellSelection.selectedMailbox?.isUnified == true {
      if let connectionId = inboxViewModel.currentConnectionId {
        mailShellSelection.updateThreads(threads, for: connectionId)
      } else {
        mailShellSelection.replaceUnifiedThreads(
          threads,
          connectionIds: Set(gmailViewModel.connections.map(\.id))
        )
      }
    } else if let connectionId = mailShellSelection.selectedConnectionId {
      mailShellSelection.updateThreads(threads, for: connectionId)
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
      let connection = gmailViewModel.connections.first(where: { $0.id == message.connectionId }),
      gmailViewModel.selectedConnectionId != connection.id
    {
      selectConnection(connection)
    }
    mailShellSelection.selectSearchResult(message)
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
          gmailViewModel.connections.contains(where: { $0.id == connectionId })
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

  fileprivate var accountSettings: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          VStack(alignment: .leading, spacing: 8) {
            Label("Signed in with Apple", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .font(.headline)
            Text("Product account: \(snapshot.productAccountId)")
            Text("Trusted device: \(snapshot.trustedDeviceId)")
              .foregroundStyle(.secondary)
          }

          NavigationLink {
            AccountAndDevicesSettingsView(
              session: session,
              snapshot: snapshot,
              signOut: signOut
            )
          } label: {
            Label("Account & Devices", systemImage: "person.2")
          }

          NavigationLink {
            InboxSettingsView(store: inboxPreferenceStore)
          } label: {
            Label("Inbox", systemImage: "tray")
          }

          NavigationLink {
            ReadingSettingsView(
              connections: gmailViewModel.connections,
              store: readingPreferenceStore
            )
          } label: {
            Label("Reading", systemImage: "text.book.closed")
          }

          NavigationLink {
            SwipeSettingsView(store: swipePreferenceStore)
          } label: {
            Label("Swipes", systemImage: "hand.draw")
          }

          NavigationLink {
            advancedSettings
          } label: {
            Label("Advanced", systemImage: "wrench.and.screwdriver")
          }

          CustomCategoryPanel(viewModel: categoryViewModel)

          NotificationRulePanel(
            categoryChoices: MessageCategoryChoice.available(
              customCategory: categoryViewModel.category
            ),
            hasLoadedCategory: categoryViewModel.hasLoadedCategory,
            viewModel: notificationRuleViewModel
          )

          GmailProviderConnectionPanel(
            cancelBodyPrefetch: { await inboxViewModel.cancelBodyPrefetch() },
            viewModel: gmailViewModel,
            isMailboxBusy: inboxViewModel.isBusy || mailActionViewModel.isPerformingAction,
            selectMailbox: { selectConnection($0) }
          )

          MicrosoftGraphConnectionPanel(
            cancelBodyPrefetch: { await inboxViewModel.cancelBodyPrefetch() },
            connectionsDidChange: {
              Task {
                _ = await gmailViewModel.load()
              }
            },
            connectionDidConnect: { selectConnection($0) },
            isMailboxBusy: inboxViewModel.isBusy || mailActionViewModel.isPerformingAction,
            selectMailbox: { selectConnection($0) },
            viewModel: microsoftGraphViewModel
          )

          EWSSetupPanel(
            viewModel: ewsSetupViewModel,
            cancelBodyPrefetch: { await inboxViewModel.cancelBodyPrefetch() },
            connectionDidConnect: { selectConnection($0) },
            connectionsDidChange: {
              Task { _ = await gmailViewModel.load() }
            },
            isMailboxBusy: inboxViewModel.isBusy || mailActionViewModel.isPerformingAction
          )

          GenericMailSetupPanel(viewModel: genericMailSetupViewModel)

          SmokeView(service: ConvexBackendHealthService())

          if let signOutErrorMessage = session.signOutErrorMessage {
            SignOutErrorBanner(message: signOutErrorMessage)
          }

          Button("Sign Out", role: .destructive) {
            signOut()
          }
          .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .navigationTitle("Account Settings")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { showsAccountSettings = false }
        }
      }
    }
  }

  private var advancedSettings: some View {
    AdvancedSettingsView(
      connections: gmailViewModel.connections,
      productSyncHealth: .current(session: snapshot),
      status: mailboxFreshnessViewModel.status,
      backendHealth: { try await ConvexBackendHealthService().health() },
      rebuildIndexes: {
        try await performAdvancedMaintenance(.rebuildIndexes)
      },
      clearAndResynchronize: {
        try await performAdvancedMaintenance(.clearAndResynchronize)
      }
    )
    .task {
      let isAuthoritative = await gmailViewModel.load()
      mailboxFreshnessViewModel.updateConnections(
        gmailViewModel.connections,
        snapshotIsAuthoritative: isAuthoritative
      )
    }
  }

  private func performAdvancedMaintenance(
    _ operation: AdvancedMaintenanceOperation
  ) async throws -> AdvancedMaintenanceOutcome {
    mailboxFreshnessViewModel.cancelAll()
    await mailboxWorkCoordinator.cancelBodyPrefetch(
      productAccountId: snapshot.productAccountId
    )
    switch operation {
    case .clearAndResynchronize:
      try await mailboxConnection.clearLocalMailboxData(session: snapshot)
    case .rebuildIndexes:
      try await mailboxConnection.rebuildLocalIndexes(session: snapshot)
    }
    try Task.checkCancellation()
    guard session.isCurrent(snapshot) else { throw CancellationError() }

    let connectionsAreAuthoritative = await gmailViewModel.load()
    let connections = gmailViewModel.connections
    mailboxFreshnessViewModel.clearPersistedState()
    mailboxFreshnessViewModel.updateConnections(
      connections,
      snapshotIsAuthoritative: connectionsAreAuthoritative
    )
    guard connectionsAreAuthoritative else {
      return .pending(
        "Local maintenance completed. Connection status could not be confirmed, so resynchronization is pending."
      )
    }
    await mailboxFreshnessViewModel.synchronizeFully(connections: connections)
    return advancedMaintenanceOutcome(for: connections)
  }

  private func advancedMaintenanceOutcome(
    for connections: [MailboxConnection]
  ) -> AdvancedMaintenanceOutcome {
    let phases = connections.map { mailboxFreshnessViewModel.status(for: $0).phase }
    if phases.contains(where: { if case .offline = $0 { true } else { false } }) {
      return .pending(
        "Local maintenance completed. Resynchronization will resume when this device is online."
      )
    }
    if phases.contains(where: { if case .authorizationRequired = $0 { true } else { false } }) {
      return .pending(
        "Local maintenance completed. Authorize the affected Mailbox Connection to resynchronize it."
      )
    }
    if phases.contains(where: { if case .failed = $0 { true } else { false } }) {
      return .pending(
        "Local maintenance completed. One or more Mailbox Connections need attention "
          + "before resynchronization can finish."
      )
    }
    if phases.contains(where: { if case .backfillPending = $0 { true } else { false } }) {
      return .pending(
        "Recent mail is available. Historical metadata rebuilding will continue in the background."
      )
    }
    return .completed("Local maintenance and resynchronization completed.")
  }

  private func signOut() {
    coordinateProductAccountSignOut(
      session: session,
      mailActionViewModel: mailActionViewModel
    ) {
      ewsSetupViewModel.invalidate()
      genericMailSetupViewModel.invalidate()
      mailboxFreshnessViewModel.cancelAll()
      mailboxFreshnessViewModel.clearPersistedState()
      await inboxViewModel.prepareForSignOut()
    }
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
  let pinnedMessageIds: Set<StableProviderMessageIdentity>

  static let empty = MailShellProductMailboxState(
    outboxStates: [],
    pinnedMessageIds: []
  )
}

struct MailboxNavigationSnapshot: Equatable {
  let messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]]
  let pinnedMessageIds: Set<StableProviderMessageIdentity>
  let outboxStates: [MailShellOutboxState]
  let providerMailboxesByConnection: [MailboxConnectionId: [ProviderMailbox]]

  init(
    messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]],
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
    outboxStates: [MailShellOutboxState],
    providerMailboxesByConnection: [MailboxConnectionId: [ProviderMailbox]] = [:]
  ) {
    self.messagesByConnection = messagesByConnection
    self.outboxStates = outboxStates
    self.pinnedMessageIds = pinnedMessageIds
    self.providerMailboxesByConnection = providerMailboxesByConnection
  }

  var outboxItemCount: Int {
    outboxStates.count { $0 != .sent }
  }

  var showsOutbox: Bool {
    outboxItemCount > 0
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
        isPinned: pinnedMessageIds.contains($0.id)
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
    pinnedMessageIds: [],
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
}

extension UnifiedMailbox {
  var systemImage: String {
    switch self {
    case .inbox:
      return "tray.2"
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

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class MailShellSelectionModel {
  private(set) var expandedMessageIds: Set<StableProviderMessageIdentity> = []
  private(set) var selectedMailbox: MailShellMailboxSelection? = .unified(.inbox)
  private(set) var selectedThreadIds: Set<MailboxThreadIdentity> = []
  private var retainedSearchResultThread: MailboxThread?
  private var threadsByConnection: [MailboxConnectionId: [MailboxThread]] = [:]

  var selectedThreadId: MailboxThreadIdentity? {
    selectedThreadIds.count == 1 ? selectedThreadIds.first : nil
  }

  var selectedConnectionId: MailboxConnectionId? {
    guard case .connection(let connectionId, _) = selectedMailbox else { return nil }
    return connectionId
  }

  var threads: [MailboxThread] {
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

  func clearSelection() {
    selectedMailbox = nil
    selectedThreadIds = []
    retainedSearchResultThread = nil
    threadsByConnection = [:]
    expandedMessageIds = []
  }

  func clearThreadSelection() {
    selectedThreadIds = []
    retainedSearchResultThread = nil
    expandedMessageIds = []
  }

  func selectMailbox(
    connectionId: MailboxConnectionId,
    collection: MailboxMessageCollection = .role(.inbox)
  ) {
    let mailbox = MailShellMailboxSelection.connection(connectionId, collection)
    guard selectedMailbox != mailbox else { return }
    selectedMailbox = mailbox
    selectedThreadIds = []
    retainedSearchResultThread = nil
    expandedMessageIds = []
  }

  func selectUnifiedInbox() {
    selectUnifiedMailbox(.inbox)
  }

  func selectUnifiedMailbox(_ mailbox: UnifiedMailbox) {
    let selection = MailShellMailboxSelection.unified(mailbox)
    guard selectedMailbox != selection else { return }
    selectedMailbox = selection
    selectedThreadIds = []
    retainedSearchResultThread = nil
    expandedMessageIds = []
  }

  func selectOutbox() {
    guard selectedMailbox != .outbox else { return }
    selectedMailbox = .outbox
    selectedThreadIds = []
    retainedSearchResultThread = nil
    expandedMessageIds = []
  }

  func selectThread(_ threadId: MailboxThreadIdentity) {
    guard let thread = threads.first(where: { $0.id == threadId }) else { return }
    retainedSearchResultThread = nil
    selectedThreadIds = [threadId]
    expandedMessageIds = [thread.latestMessage.id]
  }

  func selectThreads(_ threadIds: Set<MailboxThreadIdentity>) {
    if retainedSearchResultThread.map({ !threadIds.contains($0.id) }) == true {
      retainedSearchResultThread = nil
    }
    let availableThreadIds = Set(threads.map(\.id))
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
    retainedSearchResultThread = thread
    selectedThreadIds = [thread.id]
    expandedMessageIds = [message.id]
  }

  func updateThreads(
    _ threads: [MailboxThread],
    for connectionId: MailboxConnectionId
  ) {
    var connectionThreads = threads.filter { $0.id.connectionId == connectionId }
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
    let availableThreadIds = Set(threads.map(\.id))
    selectedThreadIds.formIntersection(availableThreadIds)
    guard selectedThreadIds.count == 1, let selectedThreadId = selectedThreadIds.first,
      let selectedThread = threads.first(where: { $0.id == selectedThreadId })
    else {
      expandedMessageIds = []
      return
    }
    let availableMessageIds = Set(selectedThread.messages.map(\.id))
    expandedMessageIds.formIntersection(availableMessageIds)
    expandedMessageIds.insert(selectedThread.latestMessage.id)
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
    pinnedMessageIds: Set<StableProviderMessageIdentity>
  ) -> [MailboxMessageMetadata] {
    guard let collection = selectedMailbox?.collection else { return [] }
    return thread.messages.filter {
      collection.contains(
        providerStateIds: $0.providerStateIds,
        isPinned: pinnedMessageIds.contains($0.id)
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
    pinnedMessageIds: Set<StableProviderMessageIdentity>
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
            selectedMailboxMessages(in: $0, pinnedMessageIds: pinnedMessageIds)
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

  func isMessageExpanded(
    _ message: MailboxMessageMetadata,
    in thread: MailboxThread
  ) -> Bool {
    message.id == thread.latestMessage.id || expandedMessageIds.contains(message.id)
  }

  func toggleMessageExpansion(
    _ message: MailboxMessageMetadata,
    in thread: MailboxThread
  ) {
    guard message.id != thread.latestMessage.id else { return }
    if expandedMessageIds.contains(message.id) {
      expandedMessageIds.remove(message.id)
    } else {
      expandedMessageIds.insert(message.id)
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

struct MailShellCompositionDraft: Identifiable {
  var body: String
  var connectionId: MailboxConnectionId?
  var hasExplicitReadReceiptChoice = false
  let id = UUID()
  var recipient: String
  let replyToMessage: MailboxMessageMetadata?
  var requestsReadReceipt = false
  let sourceMessage: MailboxMessageMetadata?
  var subject: String

  var sourceMailboxIdentity: StableProviderMailboxIdentity? {
    sourceMessage?.connectionId.providerMailboxIdentity
  }

  var sourceThreadId: MailboxThreadIdentity? {
    sourceMessage?.threadIdentity
  }

  var forwardSourceMessage: MailboxMessageMetadata? {
    replyToMessage == nil ? sourceMessage : nil
  }

  var title: String {
    if replyToMessage != nil { return "Reply" }
    return sourceMessage == nil ? "New Message" : "Forward"
  }

  mutating func applyInitialReadReceiptPolicy(_ policy: OutgoingReadReceiptPolicy) {
    switch policy {
    case .never:
      requestsReadReceipt = false
    case .askWhileSending:
      break
    case .requestByDefault:
      if !hasExplicitReadReceiptChoice {
        requestsReadReceipt = true
      }
    }
  }

  static func new(defaultSendingConnectionId: MailboxConnectionId?) -> MailShellCompositionDraft {
    MailShellCompositionDraft(
      body: "",
      connectionId: defaultSendingConnectionId,
      recipient: "",
      replyToMessage: nil,
      requestsReadReceipt: false,
      sourceMessage: nil,
      subject: ""
    )
  }

  static func editing(_ attempt: OutgoingDeliveryAttempt) -> MailShellCompositionDraft {
    var draft = MailShellCompositionDraft(
      body: attempt.message.body,
      connectionId: attempt.mailboxConnectionId,
      recipient: attempt.message.recipient,
      replyToMessage: nil,
      requestsReadReceipt: attempt.message.requestsReadReceipt == true,
      sourceMessage: nil,
      subject: attempt.message.subject
    )
    draft.hasExplicitReadReceiptChoice = true
    return draft
  }

  static func reply(to message: MailboxMessageMetadata) -> MailShellCompositionDraft {
    return MailShellCompositionDraft(
      body: "",
      connectionId: message.connectionId,
      recipient: replyRecipient(for: message),
      replyToMessage: message,
      requestsReadReceipt: false,
      sourceMessage: message,
      subject: prefixedSubject("Re:", subject: message.subject)
    )
  }

  static func replyAll(
    to message: MailboxMessageMetadata,
    senderAddress: String
  ) -> MailShellCompositionDraft {
    let senderAliases = Set(
      [normalizedMailboxAddress(senderAddress)]
        + (message.providerStateIds?.contains("SENT") == true
          ? mailboxValues(in: message.from ?? "").map(normalizedMailboxAddress)
          : [])
    )
    let isLegacyGmailSent =
      message.connectionId.providerId == .gmail
      && message.providerStateIds?.contains("SENT") == true
      && message.bccRecipients == nil
    let candidates =
      isLegacyGmailSent
      ? []
      : [message.replyTo ?? message.from].compactMap(\.self)
        + (message.recipientHeaders ?? []).flatMap(mailboxValues)
    var seenAddresses: Set<String> = []
    let recipients = candidates.filter { address in
      let normalizedAddress = normalizedMailboxAddress(address)
      guard !normalizedAddress.isEmpty, !senderAliases.contains(normalizedAddress) else {
        return false
      }
      return seenAddresses.insert(normalizedAddress).inserted
    }
    var draft = reply(to: message)
    draft.recipient =
      recipients.isEmpty && !isLegacyGmailSent
      ? message.replyTo ?? message.from ?? ""
      : recipients.joined(separator: ", ")
    return draft
  }

  private static func mailboxValues(in value: String) -> [String] {
    var mailboxes: [String] = []
    var mailbox = ""
    var isEscaped = false
    var isQuoted = false
    var angleBracketDepth = 0

    for character in value {
      if isEscaped {
        mailbox.append(character)
        isEscaped = false
        continue
      }
      if character == "\\" && isQuoted {
        mailbox.append(character)
        isEscaped = true
        continue
      }
      switch character {
      case "\"":
        isQuoted.toggle()
      case "<":
        angleBracketDepth += 1
      case ">":
        angleBracketDepth = max(0, angleBracketDepth - 1)
      case "," where !isQuoted && angleBracketDepth == 0:
        mailboxes.append(mailbox.trimmingCharacters(in: .whitespacesAndNewlines))
        mailbox = ""
        continue
      default:
        break
      }
      mailbox.append(character)
    }
    mailboxes.append(mailbox.trimmingCharacters(in: .whitespacesAndNewlines))
    return mailboxes
  }

  private static func normalizedMailboxAddress(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let opening = trimmed.lastIndex(of: "<"),
      let closing = trimmed.lastIndex(of: ">"),
      opening < closing
    else {
      return trimmed.lowercased()
    }
    return String(trimmed[trimmed.index(after: opening)..<closing])
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  static func replyRecipient(for message: MailboxMessageMetadata) -> String {
    if message.providerStateIds?.contains("SENT") == true {
      return message.recipientHeaders?.first ?? message.replyTo ?? message.from ?? ""
    }
    return message.replyTo ?? message.from ?? ""
  }

  static func forward(
    _ message: MailboxMessageMetadata,
    body: String
  ) -> MailShellCompositionDraft {
    MailShellCompositionDraft(
      body: "\n\nForwarded message from \(message.from ?? "Unknown sender"):\n\(body)",
      connectionId: message.connectionId,
      recipient: "",
      replyToMessage: nil,
      requestsReadReceipt: false,
      sourceMessage: message,
      subject: prefixedSubject("Fwd:", subject: message.subject)
    )
  }

  private static func prefixedSubject(_ prefix: String, subject: String) -> String {
    let trimmedSubject = subject == "(No subject)" ? "" : subject
    guard !trimmedSubject.isEmpty else { return prefix }
    guard trimmedSubject.range(of: prefix, options: [.caseInsensitive, .anchored]) == nil else {
      return trimmedSubject
    }
    return "\(prefix) \(trimmedSubject)"
  }
}

private struct MailShellSidebar: View {
  let compose: () -> Void
  let connections: [MailboxConnection]
  let errorMessage: String?
  let isLoading: Bool
  let isRefreshing: Bool
  let lastSuccessfulSyncAt: Date?
  let navigationSnapshot: MailboxNavigationSnapshot
  let openSettings: (SettingsRoute) -> Void
  let refreshMailboxes: () -> Void
  @Binding var selectedMailbox: MailShellMailboxSelection?
  let showAccountSettings: () -> Void
  let showDevelopmentSettings: () -> Void
  let syncStatus: (MailboxConnection) -> MailboxSyncStatus

  var body: some View {
    List(selection: $selectedMailbox) {
      Section("Mailboxes") {
        ForEach(UnifiedMailbox.allCases, id: \.self) { mailbox in
          NavigationLink(value: MailShellMailboxSelection.unified(mailbox)) {
            MailShellMailboxLabel(
              count: navigationSnapshot.count(for: mailbox),
              systemImage: mailbox.systemImage,
              title: mailbox.title
            )
          }
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
        }
        if connections.isEmpty {
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
        } else {
          ForEach(connections) { connection in
            Section(connection.displayName) {
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
                id: \.self
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
              let status = syncStatus(connection)
              if let route = MailboxStatusSettingsLink.route(
                for: status,
                connectionId: connection.id
              ) {
                Button {
                  openSettings(route)
                } label: {
                  Text(status.summary)
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(statusColor(for: status))
              } else {
                Text(status.summary)
                  .font(.caption2)
                  .foregroundStyle(statusColor(for: status))
              }
            }
          }
        }
      }

      if !connections.isEmpty {
        Section("Synchronization") {
          if let lastSuccessfulSyncAt {
            Text(
              "Last successful sync "
                + lastSuccessfulSyncAt.formatted(date: .abbreviated, time: .shortened)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          } else {
            Text("No successful synchronization yet")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      if !connections.isEmpty, let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
      }

      Section {
        ForEach(SettingsEntryPointRegistry.currentEntries) { entryPoint in
          switch entryPoint {
          case .accountSettings:
            Button(action: showAccountSettings) {
              Label("Account Settings", systemImage: "gearshape")
            }
          case .adaptiveSettings:
            #if DEBUG
              Button(action: showDevelopmentSettings) {
                Label("Development Settings", systemImage: "gearshape.2")
              }
            #endif
          }
        }
      }
    }
    .navigationTitle("Unwired Mail")
    .toolbar {
      if !connections.isEmpty {
        ToolbarItem(placement: .primaryAction) {
          Button(action: compose) {
            Label("New Message", systemImage: "square.and.pencil")
          }
        }
        ToolbarItem(placement: .primaryAction) {
          Button(action: refreshMailboxes) {
            Label("Refresh All Mailboxes", systemImage: "arrow.clockwise")
          }
          .disabled(
            isLoading || isRefreshing
              || !connections.contains {
                $0.authorizationState == .authorized
                  && $0.capabilities.canSynchronizeMetadata
              }
          )
        }
      }
    }
  }

  private func statusColor(for status: MailboxSyncStatus) -> Color {
    switch status.phase {
    case .authorizationRequired, .backfillPending, .offline:
      return .orange
    case .failed:
      return .red
    case .idle, .syncing:
      return .secondary
    }
  }
}

private struct MailShellMailboxLabel: View {
  let count: MailboxItemCount
  let systemImage: String
  let title: String

  var body: some View {
    Label {
      HStack {
        Text(title)
        Spacer()
        if count.unreadCount > 0 {
          Text("\(count.unreadCount) unread")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Text("\(count.itemCount)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: systemImage)
    }
  }
}

// swiftlint:disable:next type_body_length
struct MailShellThreadList: View {
  let connection: MailboxConnection?
  let connections: [MailboxConnection]
  let isConnectionBusy: Bool
  let items: [MailShellThreadListItem]
  @Bindable var mailActionViewModel: GmailMailActionViewModel
  let mailboxSelection: MailShellMailboxSelection?
  let navigationSnapshot: MailboxNavigationSnapshot
  var openSettings: (SettingsRoute) -> Void = { _ in }
  @Bindable var pinViewModel: PinViewModel
  @Binding var selectedThreadIds: Set<MailboxThreadIdentity>
  var swipePreferences: SwipePreferences = .defaults
  @Bindable var viewModel: GmailInboxViewModel
  var selectSearchResult: (MailboxMessageMetadata) -> Void = { _ in }
  var categoryChoices: [MessageCategoryChoice] = []
  var inboxPreferences: InboxPreferences = .defaults
  var readingPreferences: ReadingPreferences = .defaults
  var clearCachedBodies: () async throws -> Void = {}
  var revalidateTrustedDevice: () async -> Bool = { true }
  var itemDidRender: (MailShellThreadListItem) -> Void = { _ in }
  @State private var editingAttempt: OutgoingDeliveryAttempt?
  @State private var pendingMoveItem: MailShellThreadListItem?
  @State private var showsMailboxTools = false

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
        } else if items.isEmpty && !viewModel.isLoading && !viewModel.isSyncing {
          ContentUnavailableView(
            "No inbox messages",
            systemImage: "tray",
            description: Text(emptyInboxDescription)
          )
        } else {
          List(selection: $selectedThreadIds) {
            if let errorMessage = viewModel.errorMessage {
              Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                  .foregroundStyle(.orange)
              }
            }
            Section {
              ForEach(items) { item in
                let leadingActions = resolvedSwipeActions(for: item, edge: .leading)
                let trailingActions = resolvedSwipeActions(for: item, edge: .trailing)
                NavigationLink(value: item.thread.id) {
                  MailShellThreadRow(
                    categoryNamesById: categoryNamesById,
                    item: item,
                    preferences: inboxPreferences,
                    showsSourceConnection: mailboxSelection?.isUnified == true
                  )
                  .onAppear { itemDidRender(item) }
                  .onChange(of: item.id) { _, _ in itemDidRender(item) }
                }
                .swipeActions(
                  edge: .leading,
                  allowsFullSwipe: SwipeActionResolver.allowsFullSwipe(
                    preferences: swipePreferences,
                    edge: .leading,
                    resolvedActions: leadingActions
                  )
                ) {
                  ForEach(leadingActions) { action in
                    swipeButton(action, item: item)
                  }
                }
                .swipeActions(
                  edge: .trailing,
                  allowsFullSwipe: SwipeActionResolver.allowsFullSwipe(
                    preferences: swipePreferences,
                    edge: .trailing,
                    resolvedActions: trailingActions
                  )
                ) {
                  ForEach(trailingActions) { action in
                    swipeButton(action, item: item)
                  }
                }
              }
            }
          }
        }
      } else {
        ContentUnavailableView(
          "Select a mailbox",
          systemImage: "sidebar.left",
          description: Text("Choose a Mailbox Connection from the sidebar.")
        )
      }
    }
    .navigationTitle(navigationTitle)
    .toolbar {
      if mailboxSelection?.isUnified == true, !items.isEmpty {
        ToolbarItem(placement: .secondaryAction) {
          EditButton()
        }
      }
      if Self.showsUnifiedInboxRefreshButton(
        mailboxSelection: mailboxSelection,
        connections: connections
      ) {
        ToolbarItem(placement: .primaryAction) {
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
        }
      }
      if let connection, connection.authorizationState == .authorized,
        connection.capabilities.canSynchronizeMetadata
      {
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task {
              guard await revalidateTrustedDevice() else { return }
              _ = await viewModel.refresh(connection: connection)
            }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .disabled(viewModel.isRefreshDisabled || isConnectionBusy)
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
    .overlay {
      if mailboxSelection != .outbox, viewModel.isLoading || viewModel.isSyncing {
        ProgressView(viewModel.isSyncing ? "Syncing mailbox…" : "Loading inbox…")
          .padding()
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
    }
    .sheet(item: $editingAttempt) { attempt in
      MailShellComposer(
        connections: connections,
        draft: .editing(attempt),
        isSending: mailActionViewModel.isPerformingAction,
        readingPreferences: readingPreferences,
        send: { draft in
          guard
            let connectionId = draft.connectionId,
            let connection = connections.first(where: { $0.id == connectionId })
          else { return false }
          return await mailActionViewModel.editOutboxAttempt(
            attempt,
            recipient: draft.recipient,
            subject: draft.subject,
            body: draft.body,
            connection: connection,
            requestsReadReceipt: draft.requestsReadReceipt
          )
        }
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
  }

  @ViewBuilder
  private func swipeButton(
    _ action: ResolvedSwipeAction,
    item: MailShellThreadListItem
  ) -> some View {
    Button(role: destructiveRole(for: action)) {
      switch action.execution {
      case .pin:
        let messageId = pinTargetMessageId(for: item)
        Task { await pinViewModel.togglePin(messageId) }
      case .provider(.move):
        pendingMoveItem = item
      case .provider(let providerAction):
        performProviderAction(providerAction, item: item)
      }
    } label: {
      Label(action.title, systemImage: action.systemImage)
    }
    .disabled(isSwipeActionDisabled(action, item: item))
  }

  private func resolvedSwipeActions(
    for item: MailShellThreadListItem,
    edge: SwipeEdge
  ) -> [ResolvedSwipeAction] {
    guard let connection = connection(for: item) else { return [] }
    let messages = mailboxMessages(for: item)
    let contextualActions = MailShellConversationReader.contextualProviderActions(
      supported: connection.capabilities.providerActions,
      messages: messages,
      collection: mailboxSelection?.collection,
      allowsMove: !moveDestinations(for: item).isEmpty,
      allowsProviderMailboxMove: MailShellConversationReader.allowsMoveFromProviderMailbox(
        connection.providerId
      )
    )
    return SwipeActionResolver.resolve(
      configuredActions: swipePreferences.actions(for: edge),
      context: SwipeActionContext(
        messages: messages,
        pinTargetMessageId: pinTargetMessageId(for: item),
        pinnedMessageIds: pinViewModel.pinnedMessageIds,
        providerActions: contextualActions
      ),
      platform: .current
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
        isPinned: pinViewModel.pinnedMessageIds.contains($0.id)
      )
    }
  }

  private func pinTargetMessageId(
    for item: MailShellThreadListItem
  ) -> StableProviderMessageIdentity {
    Self.pinTargetMessageId(
      visibleMessages: mailboxMessages(for: item),
      latestMessageId: item.thread.latestMessage.id,
      collection: mailboxSelection?.collection
    )
  }

  static func pinTargetMessageId(
    visibleMessages: [MailboxMessageMetadata],
    latestMessageId: StableProviderMessageIdentity,
    collection: MailboxMessageCollection?
  ) -> StableProviderMessageIdentity {
    guard collection == .pins else { return latestMessageId }
    return visibleMessages.first?.id ?? latestMessageId
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
      return pinViewModel.isUpdating(pinTargetMessageId(for: item))
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
    if mailActionViewModel.outboxItems.isEmpty {
      ContentUnavailableView(
        "Outbox is empty",
        systemImage: "paperplane",
        description: Text("Pending, retrying, and failed deliveries appear here.")
      )
    } else {
      List {
        ForEach(mailActionViewModel.outboxItems) { attempt in
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(attempt.message.subject.isEmpty ? "(No subject)" : attempt.message.subject)
                .font(.headline)
              Spacer()
              Text(outboxStateTitle(attempt.state))
                .font(.caption)
                .foregroundStyle(attempt.state == .failed ? .red : .secondary)
            }
            Text("To: \(attempt.message.recipient)")
              .font(.subheadline)
            if let connection = connections.first(where: {
              $0.id == attempt.mailboxConnectionId
            }) {
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
                Button("Cancel", role: .destructive) {
                  Task { await mailActionViewModel.cancelOutboxAttempt(attempt) }
                }
              }
              if attempt.state == .failed || attempt.state == .userActionRequired {
                Button("Retry") {
                  Task { await mailActionViewModel.retryOutboxAttempt(attempt) }
                }
              }
              if attempt.state == .outcomeUnknown {
                Button("Mark Sent") {
                  Task {
                    await mailActionViewModel.resolveUnknownOutboxAttempt(
                      attempt,
                      asDelivered: true
                    )
                  }
                }
                Button("Not Sent") {
                  Task {
                    await mailActionViewModel.resolveUnknownOutboxAttempt(
                      attempt,
                      asDelivered: false
                    )
                  }
                }
              }
            }
            .buttonStyle(.bordered)
          }
          .padding(.vertical, 4)
        }
      }
    }
  }

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
  let categoryNamesById: [String: String]
  let item: MailShellThreadListItem
  let preferences: InboxPreferences
  let showsSourceConnection: Bool

  private var thread: MailboxThread {
    item.thread
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      if preferences.showsContactImages {
        contactImage
      }

      VStack(alignment: .leading, spacing: rowSpacing) {
        HStack(alignment: .firstTextBaseline) {
          Text(thread.latestMessage.from ?? "Unknown sender")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Spacer()
          Text(receivedDate)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack {
          Text(thread.latestMessage.subject)
            .font(.subheadline)
            .lineLimit(1)
          if thread.messages.count > 1 {
            Text("\(thread.messages.count)")
              .font(.caption2.bold())
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.secondary.opacity(0.15), in: Capsule())
          }
          if preferences.showsAttachmentIndicators,
            thread.latestMessage.hasAttachments
          {
            Image(systemName: "paperclip")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Has attachments")
          }
        }

        if preferences.showsCategoryBadges,
          let categoryId = thread.latestMessage.categoryId,
          let categoryName = categoryNamesById[categoryId]
        {
          Text(categoryName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.12), in: Capsule())
        }

        if showsSourceConnection {
          Label(item.sourceConnectionDisplayName, systemImage: "tray")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        if preferences.previewLength != .none {
          Text(thread.latestMessage.snippet)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(preferences.previewLength.rawValue)
        }
      }
    }
    .padding(.vertical, verticalPadding)
  }

  private var contactImage: some View {
    Circle()
      .fill(.tint.opacity(0.16))
      .frame(width: contactImageSize, height: contactImageSize)
      .overlay {
        Text(senderInitial)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tint)
      }
      .accessibilityHidden(true)
  }

  private var contactImageSize: CGFloat {
    switch preferences.threadDensity {
    case .compact:
      return 26
    case .comfortable:
      return 32
    case .spacious:
      return 38
    }
  }

  private var rowSpacing: CGFloat {
    switch preferences.threadDensity {
    case .compact:
      return 2
    case .comfortable:
      return 6
    case .spacious:
      return 10
    }
  }

  private var senderInitial: String {
    let sender = thread.latestMessage.from?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return sender.first.map { String($0).uppercased() } ?? "?"
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
    .formatted(date: .abbreviated, time: .omitted)
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
    }
    if actions.contains(.markUnread) {
      Button("Mark Unread") { perform(.markUnread, nil) }
    }
    if actions.contains(.archive) {
      Button("Archive") { perform(.archive, nil) }
    }
    if actions.contains(.move), !moveDestinations.isEmpty {
      Menu("Move to") {
        ForEach(moveDestinations, id: \.id) { mailbox in
          Button(mailbox.title) { perform(.move, mailbox) }
        }
      }
    }
    if actions.contains(.delete) {
      Button("Delete", role: .destructive) { perform(.delete, nil) }
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

struct MailShellReadTaskOwners {
  private var owners: [StableProviderMessageIdentity: UUID] = [:]

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

// swiftlint:disable:next type_body_length
struct MailShellConversationReader: View {
  enum MessageHorizontalPlacement: Equatable {
    case leading
    case trailing
  }

  enum SubjectPresentation: Equatable {
    case catalystHeader
    case navigationTitle
  }

  let connections: [MailboxConnection]
  @Bindable var inboxViewModel: GmailInboxViewModel
  let isConnectionBusy: Bool
  @Bindable var mailActionViewModel: GmailMailActionViewModel
  let messageReader: MailboxMessageReading
  @Bindable var pinViewModel: PinViewModel
  @Bindable var selection: MailShellSelectionModel
  let session: ProductAccountSessionSnapshot
  var readingPreferences: ReadingPreferences = .defaults
  var revalidateTrustedDevice: () async -> Bool = { true }
  var categoryChoices: [MessageCategoryChoice] = []

  @State private var compositionDraft: MailShellCompositionDraft?
  @State private var readerErrorConnectionId: MailboxConnectionId?
  @State private var readerErrorMessage: String?
  @State private var readerErrorSource: MailShellReaderErrorSource?
  @State private var readTaskOwners = MailShellReadTaskOwners()
  @State private var readTasks: [StableProviderMessageIdentity: Task<Void, Never>] = [:]

  var body: some View {
    Group {
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
                pinnedMessageIds: inboxViewModel.navigationSnapshot.pinnedMessageIds
              )
            )
          }
        }
      } else if let thread = selection.selectedThread,
        let connection = connection(for: thread)
      {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(thread.messages.reversed())) { message in
              VStack(alignment: .leading, spacing: 12) {
                MailShellConversationMessage(
                  canForward: connection.capabilities.canForward,
                  canReply: connection.capabilities.canReply,
                  clearBodySignal: inboxViewModel.loadedMessageBodyClearSignal(for: message.id),
                  isExpanded: selection.isMessageExpanded(message, in: thread),
                  isForwardDisabled: inboxViewModel.isLoadingMessageBody
                    || !inboxViewModel.hasLoadedMessageBodyText(for: message.id),
                  isRemoveCachedBodyDisabled: inboxViewModel.isLoadingMessageBody,
                  isLatest: message.id == thread.latestMessage.id,
                  isPinned: pinViewModel.pinnedMessageIds.contains(message.id),
                  isUpdatingPin: pinViewModel.isUpdating(message.id),
                  loadBody: {
                    guard await revalidateTrustedDevice() else { throw CancellationError() }
                    return try await inboxViewModel.loadMessageBody(
                      message,
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
                    try await inboxViewModel.loadRemoteMessageContent($0, for: message.id)
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
                  removeCachedBody: {
                    do {
                      try messageReader.removeCachedMessageBody(message: message, session: session)
                      inboxViewModel.discardLoadedMessageBody(for: message.id)
                      readerErrorMessage = nil
                      readerErrorSource = nil
                      return true
                    } catch {
                      readerErrorConnectionId = connection.id
                      readerErrorMessage = error.localizedDescription
                      readerErrorSource = .other
                      return false
                    }
                  },
                  releaseBodyPresentation: {
                    inboxViewModel.discardLoadedMessageBodyPresentation(for: message.id)
                  },
                  releaseRemoteContent: {
                    inboxViewModel.discardLoadedRemoteImages(for: message.id)
                  },
                  reply: { compositionDraft = .reply(to: message) },
                  replyAll: {
                    compositionDraft = .replyAll(
                      to: message,
                      senderAddress: connection.displayName
                    )
                  },
                  forward: { await prepareForward(message) },
                  toggleExpansion: {
                    selection.toggleMessageExpansion(message, in: thread)
                  },
                  togglePin: {
                    Task {
                      await togglePin(message.id)
                      if let errorMessage = pinViewModel.errorMessage {
                        readerErrorMessage = errorMessage
                        readerErrorSource = .other
                      }
                    }
                  }
                )
                if Self.showsCategoryMenu(
                  providerId: connection.providerId,
                  providerStateIds: message.providerStateIds
                ) {
                  MessageCategoryMenu(
                    categoryChoices: categoryChoices,
                    currentCategoryId: message.categoryId,
                    isDisabled: Self.isCategoryMenuDisabled(
                      isConnectionBusy: isConnectionBusy,
                      isAssigningCategory: inboxViewModel.isAssigningCategory
                    ),
                    setCategory: { categoryId in
                      let selectedThreadId = selection.selectedThreadId
                      inboxViewModel.clearCategoryOverrideError()
                      await inboxViewModel.overrideCategory(categoryId, for: message)
                      let errorMessage = inboxViewModel.categoryOverrideErrorMessage
                      inboxViewModel.clearCategoryOverrideError()
                      guard selectedThreadId == message.threadIdentity,
                        selection.selectedThreadId == selectedThreadId
                      else { return }
                      if let errorMessage {
                        readerErrorConnectionId = connection.id
                        readerErrorMessage = errorMessage
                        readerErrorSource = .categoryOverride
                      } else if readerErrorSource == .categoryOverride {
                        readerErrorConnectionId = nil
                        readerErrorMessage = nil
                        readerErrorSource = nil
                      }
                    }
                  )
                }
              }
              .containerRelativeFrame(.horizontal) { length, _ in length * 0.9 }
              .frame(
                maxWidth: .infinity,
                alignment: Self.messageHorizontalPlacement(
                  providerStateIds: message.providerStateIds
                ) == .trailing ? .trailing : .leading
              )
            }
          }
          .padding()
          .frame(maxWidth: .infinity, alignment: .top)
        }
        #if targetEnvironment(macCatalyst)
          .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
              HStack {
                Text(thread.latestMessage.subject)
                .font(.headline)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("mail-detail-subject")
                Spacer()
              }
              .padding(.horizontal)
              .frame(minHeight: 44)
              Divider()
            }
            .background(.background)
          }
        #endif
        #if targetEnvironment(macCatalyst)
          .navigationTitle("")
        #else
          .navigationTitle(thread.latestMessage.subject)
        #endif
        .toolbar {
          ToolbarItemGroup(placement: .primaryAction) {
            if connection.capabilities.canReply {
              Button {
                compositionDraft = .reply(to: thread.latestMessage)
              } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
              }
              .disabled(
                isConnectionBusy || mailActionViewModel.isPerformingAction
              )
              Button {
                compositionDraft = .replyAll(
                  to: thread.latestMessage,
                  senderAddress: connection.displayName
                )
              } label: {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
              }
              .disabled(
                isConnectionBusy || mailActionViewModel.isPerformingAction
              )
            }
            if connection.capabilities.canForward {
              Button {
                Task { await prepareForward(thread.latestMessage) }
              } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
              }
              .disabled(
                isConnectionBusy || mailActionViewModel.isPerformingAction
                  || inboxViewModel.isLoadingMessageBody
                  || !inboxViewModel.hasLoadedMessageBodyText(
                    for: thread.latestMessage.id
                  )
              )
            }
            providerActionMenu(thread: thread, connection: connection)
          }
        }
      } else {
        ContentUnavailableView(
          "Select a thread",
          systemImage: "envelope.open",
          description: Text("Choose a thread to read its complete conversation.")
        )
      }
    }
    .overlay {
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
    .sheet(item: $compositionDraft) { draft in
      MailShellComposer(
        connections: connections,
        draft: draft,
        isSending: mailActionViewModel.isPerformingAction,
        readingPreferences: readingPreferences,
        send: send
      )
    }
    .alert("Message action failed", isPresented: readerErrorBinding) {
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
    } message: {
      Text(readerErrorMessage ?? "The message action could not be completed.")
    }
    .onChange(of: selection.selectedThreadIds) { _, _ in
      compositionDraft = nil
      for task in readTasks.values { task.cancel() }
      readTasks.removeAll()
      readTaskOwners.removeAll()
      readerErrorConnectionId = nil
      readerErrorMessage = nil
      readerErrorSource = nil
      mailActionViewModel.clearError()
      pinViewModel.clearError()
    }
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

  static func messageHorizontalPlacement(
    providerStateIds: [String]?
  ) -> MessageHorizontalPlacement {
    MailboxMessageCollection.role(.sent).contains(providerStateIds: providerStateIds)
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

  static func subjectPresentation(isMacCatalyst: Bool) -> SubjectPresentation {
    isMacCatalyst ? .catalystHeader : .navigationTitle
  }

  func togglePin(_ messageId: StableProviderMessageIdentity) async {
    await pinViewModel.togglePin(messageId)
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
      .disabled(
        batches.isEmpty || inboxViewModel.areCachedMetadataActionsDisabled || isConnectionBusy
          || inboxViewModel.areProviderActionsDisabledDuringHistoricalBackfill(
            for: batches.map(\.connection)
          )
          || mailActionViewModel.isPerformingAction
      )
    }
  }

  @ViewBuilder
  private func providerActionMenu(
    thread: MailboxThread,
    connection: MailboxConnection
  ) -> some View {
    let messages = selection.selectedMailboxMessages(
      in: thread,
      pinnedMessageIds: inboxViewModel.navigationSnapshot.pinnedMessageIds
    )
    let actions = Self.contextualProviderActions(
      supported: connection.capabilities.providerActions,
      messages: messages,
      collection: selection.selectedMailbox?.collection,
      allowsMove: true,
      allowsProviderMailboxMove: Self.allowsMoveFromProviderMailbox(connection.providerId)
    )
    if !actions.isEmpty {
      Menu {
        let providerMailboxes = inboxViewModel.navigationSnapshot.providerMailboxes(
          for: connection.id
        ).filter {
          $0.isMoveDestination && MailboxMessageCollection.isProviderMailboxId($0.id)
        }
        ProviderMailActionButtons(
          actions: actions,
          moveDestinations: providerMailboxes
        ) { action, targetProviderMailbox in
          perform(
            action,
            targetProviderMailboxId: targetProviderMailbox?.id,
            targetProviderStateIds: targetProviderMailbox?.providerStateIds ?? [],
            thread: thread,
            connection: connection
          )
        }
      } label: {
        Label("Actions", systemImage: "ellipsis.circle")
      }
      .disabled(
        inboxViewModel.areCachedMetadataActionsDisabled || isConnectionBusy
          || inboxViewModel.areProviderActionsDisabledDuringHistoricalBackfill(for: [connection])
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
            pinnedMessageIds: inboxViewModel.navigationSnapshot.pinnedMessageIds
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
      let bodyText = try await inboxViewModel.loadMessageBodyText(message, using: messageReader)
      guard !Task.isCancelled, selectedThreadId == message.threadIdentity,
        selection.selectedThreadId == selectedThreadId
      else { return }
      compositionDraft = .forward(message, body: bodyText)
      readerErrorMessage = nil
      readerErrorSource = nil
    } catch is CancellationError {
    } catch {
      readerErrorMessage = error.localizedDescription
      readerErrorSource = .other
    }
  }

  private func send(_ draft: MailShellCompositionDraft) async -> Bool {
    guard await revalidateTrustedDevice() else { return false }
    guard
      let connectionId = draft.connectionId,
      let connection = connections.first(where: { $0.id == connectionId }),
      connection.authorizationState == .authorized
    else {
      readerErrorMessage = "Authorize the source Mailbox Connection before sending."
      readerErrorSource = .other
      return false
    }
    let replyThreadMessages = draft.replyToMessage.flatMap { replyMessage in
      selection.threads.first { $0.id == replyMessage.threadIdentity }?.messages
    }
    let didSend = await mailActionViewModel.send(
      recipient: draft.recipient,
      subject: draft.subject,
      body: draft.body,
      replyTo: draft.replyToMessage,
      sourceMessage: draft.sourceMessage,
      connection: connection,
      requestsReadReceipt: draft.requestsReadReceipt
    )
    if !didSend {
      readerErrorMessage = mailActionViewModel.errorMessage
      readerErrorSource = readerErrorMessage == nil ? nil : .mailAction
    } else if readingPreferences.marksReadOnReply,
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

  private func scheduleMarkRead(
    _ message: MailboxMessageMetadata,
    connection: MailboxConnection
  ) {
    guard message.isUnread,
      connection.capabilities.supports(.markRead),
      let delay = readingPreferences.markReadAfter.delay
    else { return }
    cancelMarkRead(message.id)
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
      let markedRead = await mailActionViewModel.perform(
        .markRead,
        for: [message],
        connection: connection
      )
      if markedRead {
        _ = await inboxViewModel.reloadLocal(connection: connection)
      }
    }
  }

  private func cancelMarkRead(_ messageId: StableProviderMessageIdentity) {
    readTasks[messageId]?.cancel()
    readTasks[messageId] = nil
    readTaskOwners.cancel(messageId)
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

private struct MailShellConversationMessage: View {
  let canForward: Bool
  let canReply: Bool
  let clearBodySignal: UUID?
  let isExpanded: Bool
  let isForwardDisabled: Bool
  let isRemoveCachedBodyDisabled: Bool
  let isLatest: Bool
  let isPinned: Bool
  let isUpdatingPin: Bool
  let loadBody: () async throws -> MailboxMessageBody
  let loadAttachment: (MailboxMessageAttachment) async throws -> Data
  let loadRemoteContent: (SanitizedMessageHTML) async throws -> RemoteMessageContentLoadResult
  let markBodyDisplayed: () -> Void
  let markBodyHidden: () -> Void
  let message: MailboxMessageMetadata
  let removeCachedBody: () -> Bool
  let releaseBodyPresentation: () -> Void
  let releaseRemoteContent: () -> Void
  let reply: () -> Void
  let replyAll: () -> Void
  let forward: () async -> Void
  let toggleExpansion: () -> Void
  let togglePin: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(action: toggleExpansion) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .frame(width: 12, height: 20)
          VStack(alignment: .leading, spacing: 4) {
            Text(message.from ?? "Unknown sender")
              .font(.headline)
            Text(message.subject)
              .font(.subheadline)
            Text(receivedDate)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if isLatest {
            Text("Latest")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        Divider()
        MailShellMessageBody(
          clearSignal: clearBodySignal,
          connectionId: message.connectionId,
          messageId: message.id,
          onDisplay: markBodyDisplayed,
          onDismiss: markBodyHidden,
          onRelease: releaseBodyPresentation,
          onReleaseRemoteContent: releaseRemoteContent,
          loadAttachment: loadAttachment,
          loadRemoteContent: loadRemoteContent,
          load: loadBody
        )
        HStack {
          Button(action: togglePin) {
            Label(
              isPinned ? "Unpin" : "Pin",
              systemImage: isPinned ? "pin.slash" : "pin"
            )
          }
          .buttonStyle(.bordered)
          .disabled(isUpdatingPin)
          if canReply {
            Button("Reply", action: reply)
              .buttonStyle(.bordered)
            Button("Reply All", action: replyAll)
              .buttonStyle(.bordered)
          }
          if canForward {
            Button("Forward") {
              Task { await forward() }
            }
            .buttonStyle(.bordered)
            .disabled(isForwardDisabled)
          }
          Button("Remove Cached Body", role: .destructive) {
            _ = removeCachedBody()
          }
          .buttonStyle(.bordered)
          .disabled(isRemoveCachedBodyDisabled)
        }
      }
    }
    .padding()
    .background(.background, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.separator.opacity(0.5), lineWidth: 1)
    }
  }

  private var receivedDate: String {
    Date(timeIntervalSince1970: TimeInterval(message.providerInternalDateMilliseconds) / 1_000)
      .formatted(date: .abbreviated, time: .shortened)
  }
}

struct MailShellMessageBody: View {
  let clearSignal: UUID?
  let connectionId: MailboxConnectionId?
  let messageId: StableProviderMessageIdentity?
  let load: () async throws -> MailboxMessageBody
  let loadAttachment: (MailboxMessageAttachment) async throws -> Data
  let onDisplay: () -> Void
  let onDismiss: () -> Void
  let onLoaded: () -> Void
  let onRelease: () -> Void
  let onReleaseRemoteContent: () -> Void
  let loadRemoteContent: (SanitizedMessageHTML) async throws -> RemoteMessageContentLoadResult
  @State private var loadedContent: MailShellLoadedMessageContent?
  @State private var errorMessage: String?
  @State private var isCleared = false
  @State private var isLoading = false
  @State private var isPresentationRetained = false
  @State private var loadGeneration = UUID()

  init(
    clearSignal: UUID? = nil,
    connectionId: MailboxConnectionId? = nil,
    messageId: StableProviderMessageIdentity? = nil,
    onDisplay: @escaping () -> Void = {},
    onDismiss: @escaping () -> Void = {},
    onLoaded: @escaping () -> Void = {},
    onRelease: @escaping () -> Void = {},
    onReleaseRemoteContent: @escaping () -> Void = {},
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
    self.clearSignal = clearSignal
    self.connectionId = connectionId
    self.messageId = messageId
    self.load = load
    self.loadAttachment = loadAttachment
    self.onDisplay = onDisplay
    self.onDismiss = onDismiss
    self.onLoaded = onLoaded
    self.onRelease = onRelease
    self.onReleaseRemoteContent = onReleaseRemoteContent
    self.loadRemoteContent = loadRemoteContent
  }

  var body: some View {
    Group {
      if let loadedContent {
        MailShellMessageContent(
          connectionId: connectionId,
          loadedContent: loadedContent,
          messageId: messageId,
          loadAttachment: loadAttachment,
          loadRemoteContent: loadRemoteContent,
          onResetRemoteContent: onReleaseRemoteContent,
          onRenderingFailure: {
            self.loadedContent = MailShellLoadedMessageContent(
              attachments: loadedContent.attachments,
              fallbackText: loadedContent.fallbackText,
              presentation: .plainText(loadedContent.fallbackText)
            )
          }
        )
      } else if isCleared {
        Text("Cached body removed.")
          .foregroundStyle(.secondary)
      } else if isLoading {
        ProgressView("Loading message…")
      } else if let errorMessage {
        ContentUnavailableView(
          "Message unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text(errorMessage)
        )
      } else {
        ProgressView("Loading message…")
      }
    }
    .task {
      let generation = loadGeneration
      isLoading = true
      defer {
        if generation == loadGeneration {
          isLoading = false
        }
      }
      do {
        let loadedMessageBody = try await load()
        isPresentationRetained = true
        guard generation == loadGeneration else {
          releasePresentation()
          return
        }
        let presentation = try await MessageHTMLPresentation.prepare(body: loadedMessageBody)
        guard generation == loadGeneration else {
          releasePresentation()
          return
        }
        loadedContent = MailShellLoadedMessageContent(
          attachments: loadedMessageBody.attachments,
          fallbackText: loadedMessageBody.text,
          presentation: presentation
        )
        errorMessage = nil
        isCleared = false
        onLoaded()
      } catch is CancellationError {
        releasePresentation()
      } catch {
        releasePresentation()
        guard generation == loadGeneration else { return }
        errorMessage = error.localizedDescription
      }
    }
    .onAppear {
      onDisplay()
    }
    .onChange(of: clearSignal) {
      releasePresentation()
      loadGeneration = UUID()
      loadedContent = nil
      errorMessage = nil
      isCleared = true
      isLoading = false
    }
    .onDisappear {
      onDismiss()
      loadGeneration = UUID()
      loadedContent = nil
      isLoading = false
      releasePresentation()
    }
  }

  private func releasePresentation() {
    guard isPresentationRetained else { return }
    isPresentationRetained = false
    onRelease()
  }
}

private struct MailShellLoadedMessageContent {
  let attachments: [MailboxMessageAttachment]
  let fallbackText: String
  let presentation: MessageHTMLPresentation
}

private struct MailShellMessageContent: View {
  let connectionId: MailboxConnectionId?
  let loadedContent: MailShellLoadedMessageContent
  let messageId: StableProviderMessageIdentity?
  let loadAttachment: (MailboxMessageAttachment) async throws -> Data
  let loadRemoteContent: (SanitizedMessageHTML) async throws -> RemoteMessageContentLoadResult
  let onResetRemoteContent: () -> Void
  let onRenderingFailure: () -> Void
  @Environment(AppearancePreferences.self) private var appearancePreferences: AppearancePreferences?
  @ScaledMetric(relativeTo: .body) private var bodyPointSize = 17

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      switch loadedContent.presentation {
      case .html(let html):
        MessageHTMLView(
          connectionId: connectionId,
          html: html,
          onRenderingFailure: onRenderingFailure,
          onResetRemoteContent: onResetRemoteContent,
          loadRemoteContent: loadRemoteContent
        )
      case .plainText(let text):
        Text(text)
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
      if !loadedContent.attachments.isEmpty, let messageId {
        MessageAttachmentsView(
          attachments: loadedContent.attachments,
          messageId: messageId,
          download: loadAttachment
        )
      }
    }
  }
}

struct MailShellComposer: View {
  let connections: [MailboxConnection]
  @State private var draft: MailShellCompositionDraft
  let isSending: Bool
  let readingPreferences: ReadingPreferences
  let send: (MailShellCompositionDraft) async -> Bool
  @Environment(\.dismiss) private var dismiss

  init(
    connections: [MailboxConnection],
    draft: MailShellCompositionDraft,
    isSending: Bool,
    readingPreferences: ReadingPreferences = .defaults,
    send: @escaping (MailShellCompositionDraft) async -> Bool
  ) {
    self.connections = connections
    var initialDraft = draft
    if let connectionId = draft.connectionId {
      initialDraft.applyInitialReadReceiptPolicy(
        readingPreferences.outgoingReadReceiptPolicy(for: connectionId)
      )
    }
    _draft = State(initialValue: initialDraft)
    self.isSending = isSending
    self.readingPreferences = readingPreferences
    self.send = send
  }

  var body: some View {
    NavigationStack {
      Form {
        Picker("From", selection: $draft.connectionId) {
          Text("Choose a Mailbox Connection")
            .tag(Optional<MailboxConnectionId>.none)
          ForEach(connections) { connection in
            Text(connection.displayName)
              .tag(Optional(connection.id))
              .disabled(
                connection.authorizationState != .authorized
                  || !connection.capabilities.canSend
              )
          }
        }
        if let selectedConnection, !selectedConnectionCanSend {
          Text(
            selectedConnection.authorizationState == .required
              ? "Authorize this Mailbox Connection on this device before sending."
              : "This Mailbox Connection cannot send mail."
          )
          .font(.footnote)
          .foregroundStyle(.orange)
        }
        TextField("To", text: $draft.recipient)
          .textInputAutocapitalization(.never)
        TextField("Subject", text: $draft.subject)
        TextField("Message", text: $draft.body, axis: .vertical)
          .lineLimit(8...24)
        if selectedConnection?.capabilities.canRequestReadReceipts == true {
          if effectiveOutgoingReadReceiptPolicy == .never {
            LabeledContent("Read Receipt", value: "Not Requested")
              .foregroundStyle(.secondary)
          } else {
            Toggle("Request Read Receipt", isOn: $draft.requestsReadReceipt)
          }
        }
      }
      .onChange(of: draft.connectionId) { _, connectionId in
        guard let connectionId else {
          draft.requestsReadReceipt = false
          return
        }
        draft.requestsReadReceipt =
          readingPreferences.outgoingReadReceiptPolicy(for: connectionId) == .requestByDefault
      }
      .navigationTitle(draft.title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Send") {
            Task {
              if await send(draft) {
                dismiss()
              }
            }
          }
          .disabled(
            isSending || !selectedConnectionCanSend
              || draft.recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
        }
      }
    }
  }

  private var selectedConnection: MailboxConnection? {
    guard let connectionId = draft.connectionId else { return nil }
    return connections.first { $0.id == connectionId }
  }

  private var selectedConnectionCanSend: Bool {
    selectedConnection?.authorizationState == .authorized
      && selectedConnection?.capabilities.canSend == true
  }

  private var effectiveOutgoingReadReceiptPolicy: OutgoingReadReceiptPolicy {
    guard let connectionId = draft.connectionId else { return .never }
    return readingPreferences.outgoingReadReceiptPolicy(for: connectionId)
  }
}

@MainActor
@Observable
final class PinViewModel {
  var errorMessage: String?
  private(set) var pinnedMessageIds: Set<StableProviderMessageIdentity> = []

  private let service: PinSyncing
  private var session: ProductAccountSessionSnapshot
  private var completedToggleGenerations: [StableProviderMessageIdentity: Int] = [:]
  private var updatingMessageIds: Set<StableProviderMessageIdentity> = []

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
      let loadedMessageIds = try await service.loadPinnedMessageIds(session: session)
      let changedMessageIds = Set(
        completedToggleGenerations.compactMap { messageId, generation in
          generation == generationsAtLoadStart[messageId, default: 0] ? nil : messageId
        }
      )
      pinnedMessageIds = Set(
        loadedMessageIds.filter {
          !updatingMessageIds.contains($0) && !changedMessageIds.contains($0)
        }
      ).union(
        pinnedMessageIds.filter {
          updatingMessageIds.contains($0) || changedMessageIds.contains($0)
        }
      )
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func togglePin(_ messageId: StableProviderMessageIdentity) async {
    guard !updatingMessageIds.contains(messageId) else { return }
    let wasPinned = pinnedMessageIds.contains(messageId)
    let shouldPin = !wasPinned
    setPinnedLocally(shouldPin, messageId: messageId)
    updatingMessageIds.insert(messageId)
    errorMessage = nil
    defer { updatingMessageIds.remove(messageId) }

    do {
      try await service.setPinned(
        shouldPin,
        messageId: messageId,
        session: session
      )
      completedToggleGenerations[messageId, default: 0] += 1
    } catch is CancellationError {
      setPinnedLocally(wasPinned, messageId: messageId)
    } catch {
      setPinnedLocally(wasPinned, messageId: messageId)
      errorMessage = error.localizedDescription
    }
  }

  func isUpdating(_ messageId: StableProviderMessageIdentity) -> Bool {
    updatingMessageIds.contains(messageId)
  }

  func clearError() {
    errorMessage = nil
  }

  private func setPinnedLocally(
    _ isPinned: Bool,
    messageId: StableProviderMessageIdentity
  ) {
    if isPinned {
      pinnedMessageIds.insert(messageId)
    } else {
      pinnedMessageIds.remove(messageId)
    }
  }
}

@MainActor
@Observable
final class NotificationRuleViewModel {
  var enabledCategoryIds: Set<String> = []
  var errorMessage: String?
  var fallbackErrorMessage: String?
  private var fallbackChangeGeneration = 0
  var isGenericNotificationFallbackEnabled: Bool
  var isSaving = false
  var isSyncing = false

  private let authorization: NotificationAuthorizationRequesting
  private let genericNotificationFallbackStore: GenericNotificationFallbackPersisting
  private var hasLoadedRules = false
  private var pendingPruneCategoryIds: Set<String>?
  private var rulesUpdatedAt: Int64?
  private var syncedCategoryIds: Set<String> = []
  private let service: NotificationRuleSyncing
  private var session: ProductAccountSessionSnapshot

  init(
    authorization: NotificationAuthorizationRequesting,
    genericNotificationFallbackStore: GenericNotificationFallbackPersisting =
      UserDefaultsFallbackStore(),
    service: NotificationRuleSyncing,
    session: ProductAccountSessionSnapshot
  ) {
    self.authorization = authorization
    self.genericNotificationFallbackStore = genericNotificationFallbackStore
    isGenericNotificationFallbackEnabled = genericNotificationFallbackStore.isEnabled(
      productAccountId: session.productAccountId
    )
    self.service = service
    self.session = session
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    self.session = session
  }

  var canSave: Bool {
    hasLoadedRules && !isSaving && !isSyncing
  }

  var isEditingDisabled: Bool {
    isSaving || isSyncing
  }

  var hasUnsavedChanges: Bool {
    enabledCategoryIds != syncedCategoryIds
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
    let syncedCategoryIdsAfterPruning = syncedCategoryIds.intersection(categoryIds)
    guard
      hasLoadedRules,
      enabledCategoryIds != categoryIdsBeforePruning
        || syncedCategoryIds != syncedCategoryIdsAfterPruning
    else { return }
    isSaving = true
    defer { finishSaving() }

    do {
      let snapshot = try await service.saveRules(
        NotificationRules(categoryIds: Array(syncedCategoryIdsAfterPruning)),
        expectedUpdatedAt: rulesUpdatedAt,
        session: session
      )
      syncedCategoryIds = Set(snapshot.rules.categoryIds)
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
      enabledCategoryIds = Set(snapshot.rules.categoryIds)
      rulesUpdatedAt = snapshot.updatedAt
      if let categoryIds {
        enabledCategoryIds.formIntersection(categoryIds)
        if enabledCategoryIds != Set(snapshot.rules.categoryIds) {
          snapshot = try await service.saveRules(
            NotificationRules(categoryIds: Array(enabledCategoryIds)),
            expectedUpdatedAt: rulesUpdatedAt,
            session: session
          )
          enabledCategoryIds = Set(snapshot.rules.categoryIds)
          rulesUpdatedAt = snapshot.updatedAt
        }
      }
      syncedCategoryIds = enabledCategoryIds
      hasLoadedRules = true
      if !enabledCategoryIds.isEmpty, try await !authorization.requestAuthorization() {
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
        NotificationRules(categoryIds: Array(enabledCategoryIds)),
        expectedUpdatedAt: rulesUpdatedAt,
        session: session
      )
      enabledCategoryIds = Set(snapshot.rules.categoryIds)
      syncedCategoryIds = enabledCategoryIds
      rulesUpdatedAt = snapshot.updatedAt
      if requestingNotificationAuthorization,
        !snapshot.rules.categoryIds.isEmpty,
        try await !authorization.requestAuthorization()
      {
        errorMessage =
          "Rules were saved, but visible notifications are disabled in system settings."
      } else {
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

  private func replayPendingPrune() async {
    guard let categoryIds = pendingPruneCategoryIds else { return }
    pendingPruneCategoryIds = nil
    await prune(categoryIds: categoryIds)
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
    outboxItems.map {
      switch $0.state {
      case .handingOff, .pending:
        .pending
      case .reconciling, .retrying:
        .retrying
      case .failed, .outcomeUnknown, .userActionRequired:
        .failed
      case .cancelled, .sent, .superseded:
        .sent
      }
    }
  }

  init(
    service: MailboxProviderMailActing,
    session: ProductAccountSessionSnapshot,
    outboxService: OutboxDeliveryService = .shared,
    revalidateTrustedDevice: @escaping @MainActor @Sendable () async -> Bool = { true }
  ) {
    self.outboxService = outboxService
    self.revalidateTrustedDevice = revalidateTrustedDevice
    self.service = service
    self.session = session
  }

  func clearError() {
    errorMessage = nil
  }

  func startPendingAction(
    _ operation: @escaping @MainActor @Sendable () async -> Void
  ) {
    guard !isPreparingForSignOut else { return }
    let taskId = UUID()
    pendingActionTasks[taskId] = Task { [weak self] in
      await Self.$currentPendingActionTaskId.withValue(taskId) {
        await operation()
      }
      self?.pendingActionTasks[taskId] = nil
    }
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

  func send(
    recipient: String,
    subject: String,
    body: String,
    replyTo: MailboxMessageMetadata?,
    sourceMessage: MailboxMessageMetadata? = nil,
    connection: MailboxConnection,
    requestsReadReceipt: Bool = false
  ) async -> Bool {
    guard !isPreparingForSignOut else { return false }
    guard connection.capabilities.canSend else { return false }
    guard !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    guard !isPerformingAction else { return false }
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

    do {
      let selectedSourceMessage =
        sourceMessage?.connectionId == connection.id ? sourceMessage : nil
      _ = try await outboxService.enqueue(
        OutgoingMessage(
          body: body,
          recipient: recipient,
          subject: subject,
          inReplyTo: replyTo?.rfcMessageId,
          kind: selectedSourceMessage == nil
            ? .new : (replyTo != nil ? .reply : .forward),
          providerThreadId: replyTo?.connectionId == connection.id && replyTo?.rfcMessageId != nil
            ? replyTo?.providerThreadId : nil,
          requestsReadReceipt: requestsReadReceipt
            && connection.capabilities.canRequestReadReceipts,
          sourceProviderMessageId: selectedSourceMessage?.providerMessageId
        ),
        connection: connection,
        session: session,
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
      await refreshOutbox()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func editOutboxAttempt(
    _ attempt: OutgoingDeliveryAttempt,
    recipient: String,
    subject: String,
    body: String,
    connection: MailboxConnection,
    requestsReadReceipt: Bool = false
  ) async -> Bool {
    guard connection.authorizationState == .authorized, connection.capabilities.canSend else {
      return false
    }
    do {
      _ = try await outboxService.edit(
        attempt.id,
        message: OutgoingMessage(
          body: body,
          recipient: recipient,
          subject: subject,
          inReplyTo: attempt.message.inReplyTo,
          kind: attempt.mailboxConnectionId == connection.id ? attempt.message.kind : nil,
          providerThreadId: attempt.mailboxConnectionId == connection.id
            ? attempt.message.providerThreadId : nil,
          requestsReadReceipt: requestsReadReceipt
            && connection.capabilities.canRequestReadReceipts,
          sourceProviderMessageId: attempt.mailboxConnectionId == connection.id
            ? attempt.message.sourceProviderMessageId : nil
        ),
        connection: connection,
        session: session,
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
  private static var loadedImageBudgets: [String: LoadedMessageImageBudget] = [:]
  private static let maximumLoadedAttachmentByteCount = 25 * 1_024 * 1_024
  private static let maximumLoadedInlineImageByteCount = 20 * 1_024 * 1_024
  private static let maximumLoadedInlineImagePixelCount = 32 * 1_024 * 1_024
  private static let maximumLoadedMessageBodyTextByteCount = 5 * 1_024 * 1_024
  private var backfillTask: Task<Void, Never>?
  private var backfillTaskId: UUID?
  private let bodyPrefetcher: MailboxMessageBodyPrefetching?
  private var bodyPrefetchTask: Task<Void, Never>?
  private var hasSignedOut = false
  private var displayedMessageBodyIds: Set<StableProviderMessageIdentity> = []
  private var loadedAttachmentByteCounts: [StableProviderMessageIdentity: Int] = [:]
  private var loadedInlineImageByteCounts: [StableProviderMessageIdentity: Int] = [:]
  private var loadedInlineImagePixelCounts: [StableProviderMessageIdentity: Int] = [:]
  private var loadedRemoteImageByteCounts: [StableProviderMessageIdentity: Int] = [:]
  private var loadedRemoteImagePixelCounts: [StableProviderMessageIdentity: Int] = [:]
  private let loadedImageBudget: LoadedMessageImageBudget
  private var loadedMessageBodyClearSignals: [StableProviderMessageIdentity: UUID] = [:]
  private var loadedMessageBodyTextByteCount = 0
  private var loadedMessageBodyTextOrder: [StableProviderMessageIdentity] = []
  private var loadedMessageBodyTexts: [StableProviderMessageIdentity: String] = [:]
  private var unavailableLoadedMessageBodyTextIds: Set<StableProviderMessageIdentity> = []
  private(set) var categoryOverrideErrorMessage: String?
  var errorMessage: String?
  var isAssigningCategory = false
  var isCategorizingHistorical = false
  var isLoading = false
  private var loadingMessageBodyCount = 0

  var isLoadingMessageBody: Bool {
    loadingMessageBodyCount > 0
  }
  var isSearching = false
  var isSyncing = false
  var searchQuery = ""
  var searchResult: GmailSearchResult?
  var threads: [MailboxThread] = []

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
    bodyPrefetcher: MailboxMessageBodyPrefetching? = nil,
    service: MailboxMetadataSyncing,
    searchService: MailboxMessageSearching,
    syncCoordinator: MailboxFreshnessViewModel? = nil,
    session: ProductAccountSessionSnapshot,
    productMailboxState: MailShellProductMailboxState = .empty
  ) {
    let loadedImageBudget =
      Self.loadedImageBudgets[session.productAccountId] ?? LoadedMessageImageBudget()
    Self.loadedImageBudgets[session.productAccountId] = loadedImageBudget
    self.loadedImageBudget = loadedImageBudget
    self.bodyPrefetcher = bodyPrefetcher
    navigationSnapshot = MailboxNavigationSnapshot(
      messagesByConnection: [:],
      pinnedMessageIds: productMailboxState.pinnedMessageIds,
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
    isAssigningCategory || isCategorizingHistorical || isLoading || isLoadingMessageBody
      || isSearching || isSyncing || backfillTask != nil
  }

  func loadMessageBody(
    _ message: MailboxMessageMetadata,
    using reader: MailboxMessageReading
  ) async throws -> MailboxMessageBody {
    loadingMessageBodyCount += 1
    defer { loadingMessageBodyCount -= 1 }
    let loadedBody = try await withLoadGate(loadedImageBudget.bodyLoadGate) {
      try await reader.loadMessageBody(message: message, session: session)
    }
    try Task.checkCancellation()
    let hasPresentationResources =
      !loadedBody.inlineImages.isEmpty
      || loadedBody.attachments.contains { $0.presentationData != nil }
    let body: MailboxMessageBody
    if hasPresentationResources {
      body = try await withRemoteImageAdmissionGate {
        try Task.checkCancellation()
        return try retainLoadedBodyPresentation(loadedBody, for: message.id)
      }
    } else {
      discardLoadedMessageBodyPresentation(for: message.id)
      body = loadedBody
    }
    retainLoadedMessageBodyText(body.text, for: message.id)
    return body
  }

  func loadMessageBodyText(
    _ message: MailboxMessageMetadata,
    using reader: MailboxMessageReading
  ) async throws -> String {
    if let loadedBodyText = loadedMessageBodyTexts[message.id] {
      return loadedBodyText
    }
    loadingMessageBodyCount += 1
    defer { loadingMessageBodyCount -= 1 }
    return try await reader.loadMessageBodyText(message: message, session: session)
  }

  // swiftlint:disable:next function_body_length
  func loadRemoteMessageContent(
    _ html: SanitizedMessageHTML,
    for messageId: StableProviderMessageIdentity,
    maximumLoadDuration: TimeInterval = 30,
    using loader: (
      (SanitizedMessageHTML, Int, Int) async throws
        -> RemoteMessageContentLoadResult
    )? = nil
  ) async throws -> RemoteMessageContentLoadResult {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(maximumLoadDuration))
    let maximumWaitDuration = clock.now.duration(to: deadline)
    guard
      await loadedImageBudget.loadGate.acquire(
        maximumWaitDuration: maximumWaitDuration
      )
    else {
      try Task.checkCancellation()
      return RemoteMessageContentLoadResult(
        failedImageCount: html.remoteImageReferences.count,
        html: html,
        loadedImageCount: 0
      )
    }
    do {
      try Task.checkCancellation()
      let remainingDuration = clock.now.duration(to: deadline)
      guard remainingDuration > .zero else {
        await loadedImageBudget.loadGate.release()
        return RemoteMessageContentLoadResult(
          failedImageCount: html.remoteImageReferences.count,
          html: html,
          loadedImageCount: 0
        )
      }
      let durationComponents = remainingDuration.components
      let remainingLoadDuration =
        Double(durationComponents.seconds)
        + Double(durationComponents.attoseconds) / 1_000_000_000_000_000_000
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
          maximumLoadDuration: remainingLoadDuration,
          maximumTotalByteCount: requestedMaximumByteCount,
          maximumTotalPixelCount: requestedMaximumPixelCount
        ).load(html)
      }
      try Task.checkCancellation()
      let remainingByteCount =
        Self.maximumLoadedInlineImageByteCount - loadedImageBudget.inlineByteCount
        - loadedImageBudget.remoteByteCount
      let remainingPixelCount =
        Self.maximumLoadedInlineImagePixelCount - loadedImageBudget.inlinePixelCount
        - loadedImageBudget.remotePixelCount
      let retainedResult: RemoteMessageContentLoadResult
      if result.loadedByteCount <= remainingByteCount,
        result.loadedPixelCount <= remainingPixelCount
      {
        loadedRemoteImageByteCounts[messageId, default: 0] += result.loadedByteCount
        loadedImageBudget.remoteByteCount += result.loadedByteCount
        loadedRemoteImagePixelCounts[messageId, default: 0] += result.loadedPixelCount
        loadedImageBudget.remotePixelCount += result.loadedPixelCount
        retainedResult = result
      } else {
        retainedResult = RemoteMessageContentLoadResult(
          failedImageCount: html.remoteImageReferences.count,
          html: html,
          loadedImageCount: 0
        )
      }
      await loadedImageBudget.loadGate.release()
      return retainedResult
    } catch {
      await loadedImageBudget.loadGate.release()
      throw error
    }
  }

  private func withRemoteImageAdmissionGate<Result>(
    _ operation: () async throws -> Result
  ) async throws -> Result {
    try await withLoadGate(loadedImageBudget.loadGate, operation)
  }

  private func withLoadGate<Result>(
    _ gate: RemoteMessageContentLoadGate,
    _ operation: () async throws -> Result
  ) async throws -> Result {
    guard await gate.acquire() else {
      throw CancellationError()
    }
    do {
      let result = try await operation()
      await gate.release()
      return result
    } catch {
      await gate.release()
      throw error
    }
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
    loadedMessageBodyClearSignals[messageId] = UUID()
  }

  func discardLoadedMessageBodies(connectionId: MailboxConnectionId?) {
    let messageIds = Set(loadedMessageBodyTexts.keys)
      .union(loadedInlineImagePixelCounts.keys)
      .union(loadedRemoteImagePixelCounts.keys)
      .union(displayedMessageBodyIds)
      .filter { connectionId == nil || $0.connectionId == connectionId }
    for messageId in messageIds {
      discardLoadedMessageBody(for: messageId)
    }
  }

  func discardLoadedMessageBodyPresentation(
    for messageId: StableProviderMessageIdentity
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
    discardLoadedRemoteImages(for: messageId)
  }

  func discardLoadedRemoteImages(for messageId: StableProviderMessageIdentity) {
    loadedImageBudget.remoteByteCount -=
      loadedRemoteImageByteCounts.removeValue(forKey: messageId) ?? 0
    loadedImageBudget.remotePixelCount -=
      loadedRemoteImagePixelCounts.removeValue(forKey: messageId) ?? 0
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
    discardLoadedMessageBodyPresentation(for: messageId)
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

  func clear() {
    cancelBackfill()
    bodyPrefetchTask?.cancel()
    bodyPrefetchTask = nil
    currentConnectionId = nil
    displayedMessageBodyIds = []
    unifiedConnectionIds = []
    unifiedLoadId = nil
    isLoading = false
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
    loadedMessageBodyClearSignals = [:]
    loadedMessageBodyTextByteCount = 0
    loadedMessageBodyTextOrder = []
    loadedMessageBodyTexts = [:]
    unavailableLoadedMessageBodyTextIds = []
    threads = []
    searchQuery = ""
    searchResult = nil
    errorMessage = nil
  }

  func loadUnifiedInbox(connections: [MailboxConnection]) async {
    await loadUnifiedMailbox(.inbox, connections: connections)
  }

  func updateProductMailboxState(_ state: MailShellProductMailboxState) {
    navigationSnapshot = MailboxNavigationSnapshot(
      messagesByConnection: navigationSnapshot.messagesByConnection,
      pinnedMessageIds: state.pinnedMessageIds,
      outboxStates: state.outboxStates,
      providerMailboxesByConnection: navigationSnapshot.providerMailboxesByConnection
    )
    reprojectPinsIfNeeded()
  }

  func refreshBodyPrefetch(
    afterChanging messageIds: Set<StableProviderMessageIdentity>,
    connections: [MailboxConnection]
  ) {
    guard !messageIds.isEmpty else { return }
    let connectionIds = Set(messageIds.map(\.connectionId))
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
      pinnedMessageIds: navigationSnapshot.pinnedMessageIds,
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
      applyUnifiedInboxResults(
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
      applyUnifiedInboxResults(
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
      applyUnifiedInboxResults(
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
      let result = try await service.loadMailbox(
        collection,
        connection: connection,
        session: session
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
  ) -> Bool {
    guard isCurrentUnifiedLoad(loadId: loadId, connectionIds: connectionIds) else { return false }
    for outcome in outcomes {
      if let result = outcome.phaseResult.result {
        threadsByConnection[outcome.connection.id] = result.threads
      }
    }
    if unifiedCollection == .pins {
      let messages = threadsByConnection.values.flatMap { $0 }.flatMap(\.messages)
      let pinnedThreadIds = Set(
        messages
          .filter { navigationSnapshot.pinnedMessageIds.contains($0.id) }
          .map(\.threadIdentity)
      )
      threads = MailboxThread.group(
        messages.filter { pinnedThreadIds.contains($0.threadIdentity) }
      )
    } else {
      threads = MailboxThread.group(
        threadsByConnection.values.flatMap { $0 }.flatMap(\.messages)
      )
    }
    return true
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
    connection: MailboxConnection,
    pinnedMessageIds: Set<StableProviderMessageIdentity>
  ) async throws -> MailboxMetadataSyncResult {
    try await Self.loadProjectedMailbox(
      collection,
      connection: connection,
      pinnedMessageIds: pinnedMessageIds,
      service: service,
      session: session
    )
  }

  nonisolated private static func loadProjectedMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
    service: MailboxMetadataSyncing,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    guard collection == .pins else {
      return try await service.loadMailbox(
        collection,
        connection: connection,
        session: session
      )
    }
    return try await service.loadMailbox(
      .allObserved,
      connection: connection,
      session: session
    )
    .projected(to: .pins, pinnedMessageIds: pinnedMessageIds)
  }

  private func performUnifiedMailboxPhase(
    _ phase: UnifiedMailboxPhase,
    connections: [MailboxConnection],
    collection: MailboxMessageCollection
  ) async -> [UnifiedMailboxPhaseOutcome] {
    let pinnedMessageIds = navigationSnapshot.pinnedMessageIds
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
            pinnedMessageIds: pinnedMessageIds,
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
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
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
      let result =
        if collection == .pins {
          try await service.loadMailbox(
            .allObserved,
            connection: connection,
            session: session
          )
        } else {
          try await loadProjectedMailbox(
            collection,
            connection: connection,
            pinnedMessageIds: pinnedMessageIds,
            service: service,
            session: session
          )
        }
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

  // swiftlint:disable:next function_body_length
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
      let result = try await service.loadMailbox(
        currentCollection,
        connection: connection,
        session: session
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
      if let result = try? await service.loadMailbox(
        currentCollection,
        connection: connection,
        session: session
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
        let backfill = try await service.loadMailbox(
          currentCollection,
          connection: connection,
          session: session
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
          try await bodyPrefetcher.prefetchMessageBodies(
            connection: connection,
            pinnedMessageIds: navigationSnapshot.pinnedMessageIds,
            referenceDate: Date(),
            session: self.session
          )
        } catch {
          // Prefetch is best effort and must not block cached mailbox use.
        }
      }
    }
  }

  private func reprojectPinsIfNeeded() {
    let connectionIds: Set<MailboxConnectionId>
    if unifiedCollection == .pins, !unifiedConnectionIds.isEmpty {
      connectionIds = unifiedConnectionIds
    } else if currentCollection == .pins, let currentConnectionId {
      connectionIds = [currentConnectionId]
    } else {
      return
    }
    let messages = connectionIds.flatMap {
      navigationSnapshot.messagesByConnection[$0] ?? []
    }
    let pinnedThreadIds = Set(
      messages
        .filter { navigationSnapshot.pinnedMessageIds.contains($0.id) }
        .map(\.threadIdentity)
    )
    threads = MailboxThread.group(
      messages.filter { pinnedThreadIds.contains($0.threadIdentity) }
    )
  }

  func cancelBodyPrefetch() async {
    guard let task = bodyPrefetchTask else { return }
    bodyPrefetchTask = nil
    task.cancel()
    await task.value
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
        connection: connection,
        pinnedMessageIds: navigationSnapshot.pinnedMessageIds
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
          connection: connection,
          pinnedMessageIds: navigationSnapshot.pinnedMessageIds
        )
        guard !hasSignedOut, currentConnectionId == connection.id else { return false }
        threads = result.threads
      } else {
        guard unifiedConnectionIds.contains(connection.id) else { return false }
        let result = try await loadProjectedMailbox(
          unifiedCollection,
          connection: connection,
          pinnedMessageIds: navigationSnapshot.pinnedMessageIds
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
          connection: connection,
          pinnedMessageIds: navigationSnapshot.pinnedMessageIds
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
      pinnedMessageIds: navigationSnapshot.pinnedMessageIds,
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
      threads = result.threads
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
    categoryOverrideErrorMessage = nil
    guard !isAssigningCategory else { return }
    isAssigningCategory = true
    defer { isAssigningCategory = false }

    do {
      let overriddenMessage = try await service.overrideCategory(
        categoryId,
        for: message,
        session: session
      )
      guard
        currentConnectionId == message.connectionId
          || (currentConnectionId == nil && unifiedConnectionIds.contains(message.connectionId))
      else {
        return
      }
      let messages = threads.flatMap(\.messages).map { existingMessage in
        existingMessage.stableProviderMessageId == overriddenMessage.stableProviderMessageId
          ? overriddenMessage : existingMessage
      }
      threads = MailboxThread.group(messages)
      categoryOverrideErrorMessage = nil
    } catch is CancellationError {
    } catch {
      categoryOverrideErrorMessage = error.localizedDescription
    }
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
    guard await revalidateTrustedDevice(), isSessionCurrent(session) else { return false }

    do {
      let connectionsAreAuthoritative = try await refreshConnections()
      await completeLoadingConnections()
      return connectionsAreAuthoritative
    } catch {
      let originalError = error
      do {
        let connectionsAreAuthoritative = try await refreshConnections()
        await completeLoadingConnections()
        return connectionsAreAuthoritative
      } catch let error as MailboxConnectionLoadError {
        await completeLoadingConnections()
        errorMessage = error.localizedDescription
        return false
      } catch {
        await completeLoadingConnections()
        errorMessage = originalError.localizedDescription
        return false
      }
    }
  }

  func refreshSnapshot() async -> Bool {
    do {
      let connectionsAreAuthoritative = try await refreshConnections()
      restoreSelection()
      errorMessage = nil
      return connectionsAreAuthoritative
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func completeLoadingConnections() async {
    if connectionsSnapshotIsAuthoritative { restoreSelection() }
    pushStatusMessages = pushStatusMessages.filter { connectionId, _ in
      connections.contains { $0.id == connectionId }
    }
    errorMessage = nil
    for connection in connections {
      await refreshPushWatch(connection: connection)
    }
  }

  private func restoreSelection() {
    if !connections.contains(where: { $0.id == selectedConnectionId }) {
      selectedConnectionId =
        connections.first { $0.id == defaultSendingConnectionId }?.id
        ?? connections.first?.id
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
    connectionsSnapshotIsAuthoritative = snapshot.isAuthoritative
    connections = loadedConnections
    let loadedDefaultSendingConnectionId = try await service.loadDefaultSendingConnectionId(
      session: session
    )
    defaultSendingConnectionId = loadedDefaultSendingConnectionId
    if let loadErrorDescription = snapshot.loadErrorDescription {
      throw MailboxConnectionLoadError.partialProviderLoad(loadErrorDescription)
    }
    return snapshot.isAuthoritative
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

@MainActor
@Observable
private final class CustomCategoryViewModel {
  var category: CustomCategory?
  var description = ""
  var errorMessage: String?
  var isSaving = false
  var isSyncing = false
  var name = ""

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
      let syncedCategory = try await service.loadCategory(session: session)
      apply(syncedCategory)
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
          name: trimmedName,
          description: trimmedDescription.isEmpty ? nil : trimmedDescription
        ),
        session: session
      )
      apply(savedCategory)
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
      try await service.deleteCategory(session: session)
      apply(nil)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func apply(_ syncedCategory: CustomCategory?) {
    category = syncedCategory
    name = syncedCategory?.name ?? ""
    description = syncedCategory?.description ?? ""
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

      VStack(alignment: .leading, spacing: 12) {
        TextField("Category name", text: $viewModel.name)
          .textFieldStyle(.roundedBorder)
          .disabled(viewModel.isEditingDisabled)

        TextField("Optional category description", text: $viewModel.description, axis: .vertical)
          .lineLimit(2...4)
          .textFieldStyle(.roundedBorder)
          .disabled(viewModel.isEditingDisabled)
      }

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

      ForEach(categoryChoices) { category in
        Toggle(
          category.name,
          isOn: Binding(
            get: { viewModel.isEnabled(categoryId: category.id) },
            set: { viewModel.setEnabled($0, categoryId: category.id) }
          )
        )
        .disabled(viewModel.isEditingDisabled)
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
              Task {
                await Self.performDestructiveAction(
                  cancelMailboxWork: cancelBodyPrefetch,
                  action: { await viewModel.removeEverywhere(connection) },
                  connectionsDidChange: connectionsDidChange
                )
              }
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

      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .font(.footnote)
      }

      if configuration.showsPushStatus, let pushStatusMessage = viewModel.pushStatusMessage {
        Text(pushStatusMessage)
          .foregroundStyle(.orange)
          .font(.footnote)
      }
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

  static func available(customCategory: CustomCategory?) -> [MessageCategoryChoice] {
    var choices = [
      MessageCategoryChoice(id: "system:promotions", name: "Promotions"),
      MessageCategoryChoice(id: "system:invites", name: "Invites"),
      MessageCategoryChoice(id: "system:invoices", name: "Invoices"),
      MessageCategoryChoice(id: "system:flights", name: "Flights"),
    ]
    if let customCategory {
      choices.append(MessageCategoryChoice(id: customCategory.id, name: customCategory.name))
    }
    return choices
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

private struct MessageCategoryMenu: View {
  let categoryChoices: [MessageCategoryChoice]
  let currentCategoryId: String?
  let isDisabled: Bool
  let setCategory: (String) async -> Void

  var body: some View {
    Menu {
      ForEach(categoryChoices) { choice in
        Button {
          Task { await setCategory(choice.id) }
        } label: {
          if choice.id == currentCategoryId {
            Label(choice.name, systemImage: "checkmark")
          } else {
            Text(choice.name)
          }
        }
      }
    } label: {
      Label("Set Category", systemImage: "tag")
    }
    .disabled(isDisabled)
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
  .environment(MessageContentPreferences())
}
