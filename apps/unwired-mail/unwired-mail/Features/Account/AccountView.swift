import Combine
import SwiftUI

// swiftlint:disable file_length

extension Notification.Name {
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

  private static let activePollInterval = Duration.seconds(300)

  private var inFlightSyncs: [MailboxConnectionId: InFlightSync] = [:]
  private let changeObserver: MailboxChangeObserving?
  private let isSessionCurrent: (ProductAccountSessionSnapshot) -> Bool
  private let now: () -> Date
  private let service: MailboxMetadataSyncing
  private let session: ProductAccountSessionSnapshot
  private let sleep: (Duration) async throws -> Void
  private let successStore: MailboxSyncSuccessPersisting
  private var historicalBackfills: [MailboxConnectionId: HistoricalBackfill] = [:]
  private var knownConnections: [MailboxConnectionId: MailboxConnection] = [:]
  private var statuses: [MailboxConnectionId: MailboxSyncStatus] = [:]

  init(
    service: MailboxMetadataSyncing,
    session: ProductAccountSessionSnapshot,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool,
    changeObserver: MailboxChangeObserving? = nil,
    now: @escaping () -> Date = Date.init,
    successStore: MailboxSyncSuccessPersisting? = nil,
    sleep: @escaping (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.changeObserver = changeObserver
    self.isSessionCurrent = isSessionCurrent
    self.now = now
    self.service = service
    self.session = session
    self.sleep = sleep
    self.successStore = successStore ?? UserDefaultsMailboxSyncSuccessStore()
  }

  var isSynchronizing: Bool {
    !inFlightSyncs.isEmpty
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
    return statuses[connection.id]
      ?? MailboxSyncStatus(lastSuccessfulSyncAt: lastSuccessfulSyncAt, phase: .idle)
  }

  func recordExternalSync(
    connectionIdRawValue: String,
    phase: MailboxSyncPhase,
    successfulSyncAt: Date?
  ) {
    guard
      let connection = knownConnections.values.first(where: {
        $0.id.rawValue == connectionIdRawValue
      })
    else { return }
    let currentStatus = status(for: connection)
    if let successfulSyncAt {
      successStore.save(
        successfulSyncAt,
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    }
    let reportedPhase =
      if inFlightSyncs[connection.id] != nil, phase != .syncing {
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
    for connectionId in inFlightSyncs.keys where !activeConnectionIds.contains(connectionId) {
      inFlightSyncs[connectionId]?.task.cancel()
      inFlightSyncs[connectionId] = nil
    }
    for connectionId in statuses.keys where !connectionIds.contains(connectionId) {
      statuses[connectionId] = nil
    }
    knownConnections = updatedConnections
  }

  func clearPersistedState() {
    successStore.clear(productAccountId: session.productAccountId)
    knownConnections.removeAll()
    statuses.removeAll()
  }

  func synchronize(connections: [MailboxConnection]) async {
    guard isSessionCurrent(session) else {
      cancelAll()
      return
    }
    updateConnections(connections, prunesPersistedState: false)
    let connectionIds = Set(connections.map(\.id))
    statuses = statuses.filter { connectionIds.contains($0.key) }
    for connection in connections {
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
        let result = try await syncInbox(connection: connection, session: session)
        if !result.historicalMetadataBackfillIsComplete {
          startHistoricalBackfill(connection: connection)
        }
      } catch is CancellationError {
        return
      } catch IMAPMailboxError.authorizationRejected {
        statuses[connection.id] = .authorizationRequired(
          lastSuccessfulSyncAt: statuses[connection.id]?.lastSuccessfulSyncAt
        )
      } catch {
        continue
      }
    }
  }

  // swiftlint:disable:next function_body_length
  func syncInbox(
    connection: MailboxConnection,
    session requestedSession: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    guard requestedSession == session, isSessionCurrent(session) else {
      throw CancellationError()
    }
    await cancelHistoricalBackfill(connectionId: connection.id)
    if let inFlightSync = inFlightSyncs[connection.id] {
      return try await inFlightSync.task.value
    }

    let priorStatus = status(for: connection)
    statuses[connection.id] = MailboxSyncStatus(
      lastSuccessfulSyncAt: priorStatus.lastSuccessfulSyncAt,
      phase: .syncing
    )
    let syncId = UUID()
    let task = Task {
      try await service.syncInbox(
        connection: connection,
        session: requestedSession
      )
    }
    inFlightSyncs[connection.id] = InFlightSync(id: syncId, task: task)

    do {
      let result = try await task.value
      guard isSessionCurrent(session), knownConnections[connection.id] != nil else {
        throw CancellationError()
      }
      removeSync(connectionId: connection.id, syncId: syncId)
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
      removeSync(connectionId: connection.id, syncId: syncId)
      statuses[connection.id] = MailboxSyncStatus(
        lastSuccessfulSyncAt: status(for: connection).lastSuccessfulSyncAt,
        phase: .idle
      )
      throw CancellationError()
    } catch {
      removeSync(connectionId: connection.id, syncId: syncId)
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
        priorStatus: priorStatus,
        result: .success(result)
      )
      return result
    } catch {
      if Task.isCancelled || error is CancellationError || Self.isCancellation(error) {
        if historicalBackfills[connection.id]?.id == backfillId {
          statuses[connection.id] = priorStatus
        }
        throw CancellationError()
      }
      finishHistoricalBackfill(
        connection: connection,
        priorStatus: priorStatus,
        result: .failure(error)
      )
      throw error
    }
  }

  func pollWhileActive(
    connections: @escaping () -> [MailboxConnection],
    didSynchronize: @escaping () async -> Void
  ) async {
    let idleTasks: [Task<Void, Never>] =
      if let changeObserver {
        connections()
          .filter {
            $0.authorizationState == .authorized
              && $0.providerId == .imapSMTP
              && $0.capabilities.canRegisterPush
          }
          .map { connection in
            Task { [weak self] in
              guard let self else { return }
              await observeIMAPChanges(
                connection: connection,
                observer: changeObserver,
                didSynchronize: didSynchronize
              )
            }
          }
      } else {
        []
      }
    defer {
      for task in idleTasks { task.cancel() }
    }
    while isSessionCurrent(session) {
      do {
        try await sleep(Self.activePollInterval)
      } catch {
        return
      }
      guard !Task.isCancelled, isSessionCurrent(session) else { return }
      await synchronize(connections: connections())
      guard !Task.isCancelled, isSessionCurrent(session) else { return }
      await didSynchronize()
    }
  }

  private func observeIMAPChanges(
    connection: MailboxConnection,
    observer: MailboxChangeObserving,
    didSynchronize: @escaping () async -> Void
  ) async {
    while !Task.isCancelled, isSessionCurrent(session) {
      do {
        try await observer.waitForMailboxChange(
          connection: connection,
          session: session
        )
        guard !Task.isCancelled, knownConnections[connection.id] != nil else { return }
        let result = try await syncInbox(connection: connection, session: session)
        if !result.historicalMetadataBackfillIsComplete {
          startHistoricalBackfill(connection: connection)
        }
        await didSynchronize()
      } catch is CancellationError {
        return
      } catch IMAPMailboxError.idleUnsupported {
        return
      } catch IMAPMailboxError.authorizationRejected {
        statuses[connection.id] = .authorizationRequired(
          lastSuccessfulSyncAt: statuses[connection.id]?.lastSuccessfulSyncAt
        )
        return
      } catch {
        do {
          try await sleep(.seconds(5))
        } catch {
          return
        }
      }
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

  private func removeSync(connectionId: MailboxConnectionId, syncId: UUID) {
    guard inFlightSyncs[connectionId]?.id == syncId else { return }
    inFlightSyncs[connectionId] = nil
  }

  private func startHistoricalBackfill(connection: MailboxConnection) {
    guard historicalBackfills[connection.id] == nil else { return }
    let priorStatus = status(for: connection)
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
          priorStatus: priorStatus,
          result: .success(result)
        )
      } catch {
        self?.finishHistoricalBackfill(
          connection: connection,
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

  private func finishHistoricalBackfill(
    connection: MailboxConnection,
    priorStatus: MailboxSyncStatus,
    result: Result<MailboxMetadataSyncResult, Error>
  ) {
    guard
      !Task.isCancelled,
      isSessionCurrent(session),
      knownConnections[connection.id] != nil
    else { return }
    let successfulSyncAt: Date?
    switch result {
    case .success(let result):
      let completionDate = now()
      successfulSyncAt = completionDate
      successStore.save(
        completionDate,
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
      statuses[connection.id] = MailboxSyncStatus(
        lastSuccessfulSyncAt: completionDate,
        phase: result.historicalMetadataBackfillIsComplete ? .idle : .backfillPending
      )
    case .failure(let error):
      guard !Self.isCancellation(error) else { return }
      successfulSyncAt = nil
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

  private static func isCancellation(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == NSURLErrorDomain
      && error.code == URLError.cancelled.rawValue
  }
}
// swiftlint:enable type_body_length

// swiftlint:disable:next type_body_length
struct AccountView: View {
  let session: ProductAccountSession
  let snapshot: ProductAccountSessionSnapshot
  private let messageReader: MailboxMessageReading

  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.editMode) private var editMode

  @State private var categoryViewModel: CustomCategoryViewModel
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var compositionDraft: MailShellCompositionDraft?
  @State private var genericMailSetupViewModel: GenericMailSetupViewModel
  @State private var gmailViewModel: MailboxProviderConnectionViewModel
  @State private var microsoftGraphViewModel: MailboxProviderConnectionViewModel
  @State private var mailboxFreshnessViewModel: MailboxFreshnessViewModel
  @State private var inboxViewModel: GmailInboxViewModel
  @State private var inboxLoadTask: Task<Void, Never>?
  @State private var mailActionViewModel: GmailMailActionViewModel
  @State private var mailShellSelection = MailShellSelectionModel()
  @State private var notificationRuleViewModel: NotificationRuleViewModel
  @State private var pinViewModel: PinViewModel
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
  @State private var showsBlockedActionAlert = false
  @State private var showsAccountSettings = false

  @MainActor
  // swiftlint:disable:next function_body_length
  init(
    session: ProductAccountSession,
    snapshot: ProductAccountSessionSnapshot,
    categorySyncService: CustomCategorySyncing = CustomCategorySyncService(),
    mailboxConnection: MailboxConnectionAdapter = MailboxConnectionRouter(),
    notificationAuthorization: NotificationAuthorizationRequesting = UserNotificationService(),
    notificationRuleSync: NotificationRuleSyncing = NotificationRuleSyncService(),
    pinSyncService: PinSyncing = PinSyncService()
  ) {
    self.session = session
    self.snapshot = snapshot
    self.messageReader = mailboxConnection
    _categoryViewModel = State(
      initialValue: CustomCategoryViewModel(
        service: categorySyncService,
        session: snapshot
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
        isSessionCurrent: { session.isCurrent(snapshot) },
        syncSession: snapshot
      )
    )
    _gmailViewModel = State(
      initialValue: MailboxProviderConnectionViewModel(
        service: mailboxConnection,
        isSessionCurrent: { session.isCurrent($0) },
        session: snapshot
      )
    )
    _microsoftGraphViewModel = State(
      initialValue: MailboxProviderConnectionViewModel(
        service: MicrosoftGraphMailboxConnectionAdapter(),
        isSessionCurrent: { session.isCurrent($0) },
        session: snapshot
      )
    )
    let mailboxFreshnessViewModel = MailboxFreshnessViewModel(
      service: mailboxConnection,
      session: snapshot,
      isSessionCurrent: { session.isCurrent($0) },
      changeObserver: mailboxConnection as? MailboxChangeObserving
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
      initialValue: GmailMailActionViewModel(
        service: mailboxConnection,
        session: snapshot
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
  }

  var body: some View {
    mailShell
  }

  private var genericMailReloadKey: [String] {
    genericMailSetupViewModel.connectionReloadKey
  }

  private var mailboxActivePollingTaskId: MailboxActivePollingTaskId {
    MailboxActivePollingTaskId(
      idleConnectionIds: gmailViewModel.connections
        .filter {
          $0.authorizationState == .authorized
            && $0.providerId == .imapSMTP
            && $0.capabilities.canRegisterPush
        }
        .map(\.id)
        .sorted { $0.rawValue < $1.rawValue },
      scenePhase: scenePhase
    )
  }

  private var mailShell: some View {
    mailShellWithCoreLifecycleHandlers
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
      .onChange(of: mailActionViewModel.failedConnectionIds) { oldIds, newIds in
        let newlyFailedIds = newIds.filter { !oldIds.contains($0) }
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
          prunesPersistedState: false
        )
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
        mailboxFreshnessViewModel.cancelAll()
      }
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
        refreshMailboxes: {
          Task { await synchronizeMailboxes() }
        },
        selectedMailbox: selectedMailboxBinding,
        showAccountSettings: { showsAccountSettings = true },
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
        selectedThreadIds: selectedThreadsBinding,
        viewModel: inboxViewModel
      )
    } detail: {
      MailShellConversationReader(
        connections: gmailViewModel.connections,
        inboxViewModel: inboxViewModel,
        isConnectionBusy: gmailViewModel.isEditingDisabled,
        mailActionViewModel: mailActionViewModel,
        messageReader: messageReader,
        pinViewModel: pinViewModel,
        selection: mailShellSelection
      )
    }
    .navigationSplitViewStyle(.balanced)
    .sheet(isPresented: $showsAccountSettings) {
      accountSettings
    }
    .sheet(item: $compositionDraft) { draft in
      MailShellComposer(
        connections: gmailViewModel.connections,
        draft: draft,
        isSending: mailActionViewModel.isPerformingAction,
        send: sendNewMessage,
        saveDraft: saveNewDraft
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
      await notificationRuleViewModel.load(
        categoryIds: categoryViewModel.hasLoadedCategory
          ? Set(
            MessageCategoryChoice.available(customCategory: categoryViewModel.category).map(\.id)
          )
          : nil
      )
      await reloadSyncedMailState()
      if mailShellSelection.selectedMailbox == nil {
        if let connection = gmailViewModel.connection {
          mailShellSelection.selectMailbox(connectionId: connection.id)
        }
        if let connection = gmailViewModel.connection,
          connection.authorizationState == .authorized
        {
          await inboxViewModel.loadAfterConnectionChange(
            connection: connection,
            synchronizes: false
          )
        }
      } else if mailShellSelection.selectedMailbox?.isUnified == true {
        loadUnifiedMailbox(synchronizes: false)
      }
      await mailboxFreshnessViewModel.synchronize(connections: gmailViewModel.connections)
      await reloadObservedMailboxes()
      inboxViewModel.refreshPinnedBodyPrefetch(connections: gmailViewModel.connections)
    }
    .task(id: mailboxActivePollingTaskId) {
      guard scenePhase == .active else { return }
      await mailboxFreshnessViewModel.pollWhileActive(
        connections: { gmailViewModel.connections },
        didSynchronize: { await reloadObservedMailboxes() }
      )
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task {
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
        successfulSyncAt: successfulSyncAt
      )
      let reloadObservedMetadata =
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.reloadObservedMetadata]
        as? Bool == true
      guard successfulSyncAt != nil || reloadObservedMetadata else { return }
      Task { await reloadObservedMailboxes() }
    }
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
      prunesPersistedState: connectionsAreAuthoritative
    )
    await inboxViewModel.loadNavigation(connections: gmailViewModel.connections)
    await mailActionViewModel.resume(connections: gmailViewModel.connections)
    updateProductMailboxState()
    showsBlockedActionAlert = mailActionViewModel.pendingFailureConnectionId != nil
    await inboxViewModel.loadNavigation(connections: gmailViewModel.connections)
    await genericMailSetupViewModel.loadSyncedDefinitions()
  }
}

private struct MailboxActivePollingTaskId: Equatable {
  let idleConnectionIds: [MailboxConnectionId]
  let scenePhase: ScenePhase
}

extension AccountView {
  private static func clearGenericMailLocalData(
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
    synchronizes: Bool = true
  ) {
    inboxLoadTask?.cancel()
    let collection = mailShellSelection.selectedMailbox?.collection ?? .role(.inbox)
    inboxLoadTask = Task {
      await inboxViewModel.loadAfterConnectionChange(
        connection: connection,
        collection: collection,
        synchronizes: synchronizes
      )
    }
  }

  private func loadUnifiedMailbox(synchronizes: Bool = true) {
    guard case .unified(let mailbox) = mailShellSelection.selectedMailbox else { return }
    inboxLoadTask?.cancel()
    let connections = gmailViewModel.connections
    inboxLoadTask = Task {
      await inboxViewModel.loadUnifiedMailbox(
        mailbox,
        connections: connections,
        synchronizes: synchronizes
      )
    }
  }

  private func synchronizeMailboxes() async {
    await mailboxFreshnessViewModel.synchronize(connections: gmailViewModel.connections)
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
      connection: connection
    )
  }

  private func saveNewDraft(_ draft: MailShellCompositionDraft) async -> Bool {
    guard
      let connectionId = draft.connectionId,
      let connection = gmailViewModel.connections.first(where: { $0.id == connectionId })
    else {
      return false
    }
    return await mailActionViewModel.saveDraft(
      OutgoingMessage(
        body: draft.body,
        recipient: draft.recipient,
        subject: draft.subject,
        idempotencyKey: draft.id.uuidString.lowercased()
      ),
      connection: connection
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
    collection: MailboxMessageCollection = .role(.inbox)
  ) {
    gmailViewModel.selectedConnectionId = connection.id
    microsoftGraphViewModel.selectedConnectionId = connection.id
    inboxViewModel.clear()
    mailShellSelection.selectMailbox(connectionId: connection.id, collection: collection)
    guard connection.authorizationState == .authorized else { return }
    loadMailbox(for: connection)
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
          loadUnifiedMailbox()
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
        guard isCurrentConnection else { return }
        guard let connection = gmailViewModel.connection,
          connection.id == connectionId
        else { return }
        mailShellSelection.selectMailbox(connectionId: connectionId, collection: collection)
        inboxViewModel.clear()
        guard connection.authorizationState == .authorized else { return }
        loadMailbox(for: connection)
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

          GenericMailSetupPanel(viewModel: genericMailSetupViewModel)

          if case .connection(_, .role(.inbox)) = mailShellSelection.selectedMailbox {
            GmailInboxPanel(
              categoryChoices: MessageCategoryChoice.available(
                customCategory: categoryViewModel.category
              ),
              connection: gmailViewModel.connection?.authorizationState == .authorized
                ? gmailViewModel.connection : nil,
              defaultSendingConnectionId: gmailViewModel.defaultSendingConnectionId,
              isConnectionBusy: gmailViewModel.isEditingDisabled,
              mailActionViewModel: mailActionViewModel,
              messageReader: messageReader,
              session: snapshot,
              viewModel: inboxViewModel
            )
          }

          SmokeView(service: ConvexBackendHealthService())

          Button("Sign Out", role: .destructive) {
            genericMailSetupViewModel.invalidate()
            mailboxFreshnessViewModel.cancelAll()
            mailboxFreshnessViewModel.clearPersistedState()
            Task {
              await inboxViewModel.prepareForSignOut()
              await mailActionViewModel.prepareForSignOut()
              await session.signOut()
            }
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
  let targetProviderMailboxId: String?

  init(
    connection: MailboxConnection,
    messages: [MailboxMessageMetadata],
    targetProviderMailboxId: String? = nil
  ) {
    self.connection = connection
    self.messages = messages
    self.targetProviderMailboxId = targetProviderMailboxId
  }
}

struct MailboxBulkMoveDestination: Equatable, Identifiable, Sendable {
  struct Identity: Equatable, Hashable, Sendable {
    let normalizedTitle: String
  }

  let id: Identity
  let providerMailboxIdsByConnection: [MailboxConnectionId: String]
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
          targetProviderMailboxId: providerMailboxId
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
  let failures: [MailboxBulkActionFailure]
  let succeededConnectionIds: [MailboxConnectionId]
}

struct MailboxBulkActionProgress: Equatable, Sendable {
  let action: ProviderMailAction
  let completedConnectionCount: Int
  let totalConnectionCount: Int
}

private struct MailboxBulkActionBatchOutcome: Sendable {
  let batchIndex: Int
  let connection: MailboxConnection
  let errorDescription: String?
  let failureDetails: [MailboxProviderActionFailureDetail]?
  let messages: [MailboxMessageMetadata]
}

@MainActor
@Observable
final class MailShellSelectionModel {
  private(set) var expandedMessageIds: Set<StableProviderMessageIdentity> = []
  private(set) var selectedMailbox: MailShellMailboxSelection?
  private(set) var selectedThreadIds: Set<MailboxThreadIdentity> = []
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
    threadsByConnection = [:]
    expandedMessageIds = []
  }

  func clearThreadSelection() {
    selectedThreadIds = []
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
    expandedMessageIds = []
  }

  func selectOutbox() {
    guard selectedMailbox != .outbox else { return }
    selectedMailbox = .outbox
    selectedThreadIds = []
    expandedMessageIds = []
  }

  func selectThread(_ threadId: MailboxThreadIdentity) {
    guard let thread = threads.first(where: { $0.id == threadId }) else { return }
    selectedThreadIds = [threadId]
    expandedMessageIds = [thread.latestMessage.id]
  }

  func selectThreads(_ threadIds: Set<MailboxThreadIdentity>) {
    let availableThreadIds = Set(threads.map(\.id))
    selectedThreadIds = threadIds.intersection(availableThreadIds)
    reconcileSelectedThreads()
  }

  func updateThreads(
    _ threads: [MailboxThread],
    for connectionId: MailboxConnectionId
  ) {
    threadsByConnection[connectionId] = threads.filter { $0.id.connectionId == connectionId }
    guard selectedMailbox?.isUnified == true || selectedConnectionId == connectionId else {
      return
    }
    reconcileSelectedThreads()
  }

  func replaceUnifiedThreads(
    _ threads: [MailboxThread],
    connectionIds: Set<MailboxConnectionId>
  ) {
    threadsByConnection = Dictionary(
      grouping: threads.filter { connectionIds.contains($0.id.connectionId) },
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
        return MailboxBulkActionBatch(connection: connection, messages: messages)
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
  let id = UUID()
  var recipient: String
  let replyToMessage: MailboxMessageMetadata?
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

  var hasDraftContent: Bool {
    [recipient, subject, body].contains {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  var title: String {
    if replyToMessage != nil { return "Reply" }
    return sourceMessage == nil ? "New Message" : "Forward"
  }

  static func new(defaultSendingConnectionId: MailboxConnectionId?) -> MailShellCompositionDraft {
    MailShellCompositionDraft(
      body: "",
      connectionId: defaultSendingConnectionId,
      recipient: "",
      replyToMessage: nil,
      sourceMessage: nil,
      subject: ""
    )
  }

  static func editing(_ attempt: OutgoingDeliveryAttempt) -> MailShellCompositionDraft {
    MailShellCompositionDraft(
      body: attempt.message.body,
      connectionId: attempt.mailboxConnectionId,
      recipient: attempt.message.recipient,
      replyToMessage: nil,
      sourceMessage: nil,
      subject: attempt.message.subject
    )
  }

  static func reply(to message: MailboxMessageMetadata) -> MailShellCompositionDraft {
    return MailShellCompositionDraft(
      body: "",
      connectionId: message.connectionId,
      recipient: replyRecipient(for: message),
      replyToMessage: message,
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
  let refreshMailboxes: () -> Void
  @Binding var selectedMailbox: MailShellMailboxSelection?
  let showAccountSettings: () -> Void
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
              Text(syncStatus(connection).summary)
                .font(.caption2)
                .foregroundStyle(statusColor(for: connection))
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
        Button(action: showAccountSettings) {
          Label("Account Settings", systemImage: "gearshape")
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

  private func statusColor(for connection: MailboxConnection) -> Color {
    switch syncStatus(connection).phase {
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

private struct MailShellThreadList: View {
  let connection: MailboxConnection?
  let connections: [MailboxConnection]
  let isConnectionBusy: Bool
  let items: [MailShellThreadListItem]
  @Bindable var mailActionViewModel: GmailMailActionViewModel
  let mailboxSelection: MailShellMailboxSelection?
  let navigationSnapshot: MailboxNavigationSnapshot
  @Binding var selectedThreadIds: Set<MailboxThreadIdentity>
  @Bindable var viewModel: GmailInboxViewModel
  @State private var editingAttempt: OutgoingDeliveryAttempt?

  var body: some View {
    Group {
      if mailboxSelection != nil {
        if mailboxSelection == .outbox {
          outboxContent
        } else if let connection, connection.authorizationState == .required {
          ContentUnavailableView(
            "Authorization required",
            systemImage: "lock.trianglebadge.exclamationmark",
            description: Text("Open Account Settings to authorize this mailbox on this device.")
          )
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
                NavigationLink(value: item.thread.id) {
                  MailShellThreadRow(
                    item: item,
                    showsSourceConnection: mailboxSelection?.isUnified == true
                  )
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
      if let connection, connection.authorizationState == .authorized,
        connection.capabilities.canSynchronizeMetadata
      {
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { _ = await viewModel.refresh(connection: connection) }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .disabled(viewModel.isRefreshDisabled || isConnectionBusy)
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
        allowsDraftSaving: false,
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
            connection: connection
          )
        },
        saveDraft: { _ in false }
      )
    }
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
              }
              if attempt.canCancel {
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

private struct MailShellThreadRow: View {
  let item: MailShellThreadListItem
  let showsSourceConnection: Bool

  private var thread: MailboxThread {
    item.thread
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
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
      }

      if showsSourceConnection {
        Label(item.sourceConnectionDisplayName, systemImage: "tray")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Text(thread.latestMessage.snippet)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(.vertical, 4)
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
  let perform: (ProviderMailAction, String?) -> Void

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
          Button(mailbox.title) { perform(.move, mailbox.id) }
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

// swiftlint:disable:next type_body_length
struct MailShellConversationReader: View {
  let connections: [MailboxConnection]
  @Bindable var inboxViewModel: GmailInboxViewModel
  let isConnectionBusy: Bool
  @Bindable var mailActionViewModel: GmailMailActionViewModel
  let messageReader: MailboxMessageReading
  @Bindable var pinViewModel: PinViewModel
  @Bindable var selection: MailShellSelectionModel

  @State private var compositionDraft: MailShellCompositionDraft?
  @State private var readerErrorConnectionId: MailboxConnectionId?
  @State private var readerErrorMessage: String?

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
              MailShellConversationMessage(
                canForward: connection.capabilities.canForward,
                canReply: connection.capabilities.canReply,
                isExpanded: selection.isMessageExpanded(message, in: thread),
                isLatest: message.id == thread.latestMessage.id,
                isPinned: pinViewModel.pinnedMessageIds.contains(message.id),
                isUpdatingPin: pinViewModel.isUpdating(message.id),
                loadBody: {
                  try await inboxViewModel.loadMessageBody(message, using: messageReader)
                },
                message: message,
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
                    }
                  }
                }
              )
            }
          }
          .padding()
          .frame(maxWidth: 760, alignment: .topLeading)
          .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(thread.latestMessage.subject)
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
              .disabled(isConnectionBusy || mailActionViewModel.isPerformingAction)
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
        send: send,
        saveDraft: saveDraft
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
      readerErrorConnectionId = nil
      readerErrorMessage = nil
      mailActionViewModel.clearError()
      pinViewModel.clearError()
    }
  }

  private var readerErrorBinding: Binding<Bool> {
    Binding(
      get: { readerErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          readerErrorConnectionId = nil
          readerErrorMessage = nil
        }
      }
    )
  }

  private func connection(for thread: MailboxThread) -> MailboxConnection? {
    connections.first { $0.id == thread.id.connectionId }
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
    let actions = contextualProviderActions(
      supported: selection.bulkProviderActions(connections: connections),
      messages: messages,
      allowsMove: !moveDestinations.isEmpty
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
        batches.isEmpty || inboxViewModel.isRefreshDisabled || isConnectionBusy
          || mailActionViewModel.isPerformingAction
      )
    }
  }

  @ViewBuilder
  private func providerActionMenu(
    thread: MailboxThread,
    connection: MailboxConnection
  ) -> some View {
    let actions = contextualProviderActions(
      supported: connection.capabilities.providerActions,
      messages: thread.messages,
      allowsMove: true
    )
    if !actions.isEmpty {
      Menu {
        let providerMailboxes = inboxViewModel.navigationSnapshot.providerMailboxes(
          for: connection.id
        ).filter { MailboxMessageCollection.isProviderMailboxId($0.id) }
        ProviderMailActionButtons(
          actions: actions,
          moveDestinations: providerMailboxes
        ) { action, targetProviderMailboxId in
          perform(
            action,
            targetProviderMailboxId: targetProviderMailboxId,
            thread: thread,
            connection: connection
          )
        }
      } label: {
        Label("Actions", systemImage: "ellipsis.circle")
      }
      .disabled(
        inboxViewModel.isRefreshDisabled || isConnectionBusy
          || mailActionViewModel.isPerformingAction
      )
    }
  }

  private func contextualProviderActions(
    supported: Set<ProviderMailAction>,
    messages: [MailboxMessageMetadata],
    allowsMove: Bool
  ) -> Set<ProviderMailAction> {
    var actions = supported
    let collection = selection.selectedMailbox?.collection
    if collection != .role(.inbox) {
      actions.subtract([.archive, .move])
    } else if !allowsMove {
      actions.remove(.move)
    }
    if collection != .role(.trash) {
      actions.remove(.restore)
    }
    if collection != .role(.spam) {
      actions.remove(.notSpam)
    }
    if collection == .role(.trash) || collection == .role(.spam)
      || collection == .role(.sent)
      || messages.contains(where: { $0.belongs(to: .drafts) || $0.belongs(to: .sent) })
    {
      actions.remove(.spam)
    }
    return actions
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
            .filter { MailboxMessageCollection.isProviderMailboxId($0.id) }
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
    thread: MailboxThread,
    connection: MailboxConnection
  ) {
    Task {
      let didPerform = await mailActionViewModel.perform(
        action,
        targetProviderMailboxId: targetProviderMailboxId,
        sourceProviderMailboxId: selection.selectedMailbox?.collection?
          .providerActionSourceMailboxId,
        for: selection.selectedMailboxMessages(
          in: thread,
          pinnedMessageIds: inboxViewModel.navigationSnapshot.pinnedMessageIds
        ),
        connection: connection
      )
      if didPerform {
        _ = await inboxViewModel.reloadLocal(connection: connection)
        await mailActionViewModel.resume(connections: [connection])
        _ = await inboxViewModel.reloadLocal(connection: connection)
        if let errorMessage = mailActionViewModel.errorMessage {
          readerErrorConnectionId = connection.id
          readerErrorMessage = errorMessage
        }
      } else if let errorMessage = mailActionViewModel.errorMessage {
        readerErrorConnectionId = connection.id
        readerErrorMessage = errorMessage
      }
    }
  }

  private func performBulk(
    _ action: ProviderMailAction,
    batches: [MailboxBulkActionBatch]
  ) {
    Task {
      guard
        let result = await mailActionViewModel.performBulk(
          action,
          batches: batches,
          sourceProviderMailboxId: selection.selectedMailbox?.collection?
            .providerActionSourceMailboxId,
          onEnqueued: { connection in
            _ = await inboxViewModel.reloadLocal(connection: connection)
          }
        )
      else { return }
      let attemptedConnections = batches.map(\.connection)
      let errorMessage = mailActionViewModel.errorMessage
      for connection in attemptedConnections {
        _ = await inboxViewModel.reloadLocal(connection: connection)
      }
      guard let errorMessage else { return }
      readerErrorConnectionId = result.failures.first?.connectionId
      readerErrorMessage = errorMessage
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
    }
  }

  private func acknowledgePendingActionFailure(connection: MailboxConnection) {
    Task {
      await mailActionViewModel.acknowledgeFailures(connection: connection)
      _ = await inboxViewModel.reloadLocal(connection: connection)
      readerErrorConnectionId = nil
      readerErrorMessage = nil
    }
  }

  private func prepareForward(_ message: MailboxMessageMetadata) async {
    let selectedThreadId = selection.selectedThreadId
    do {
      let body = try await inboxViewModel.loadMessageBody(message, using: messageReader)
      guard !Task.isCancelled, selectedThreadId == message.threadIdentity,
        selection.selectedThreadId == selectedThreadId
      else { return }
      compositionDraft = .forward(message, body: body.text)
      readerErrorMessage = nil
    } catch is CancellationError {
    } catch {
      readerErrorMessage = error.localizedDescription
    }
  }

  private func send(_ draft: MailShellCompositionDraft) async -> Bool {
    guard
      let connectionId = draft.connectionId,
      let connection = connections.first(where: { $0.id == connectionId }),
      connection.authorizationState == .authorized
    else {
      readerErrorMessage = "Authorize the source Mailbox Connection before sending."
      return false
    }
    let didSend = await mailActionViewModel.send(
      recipient: draft.recipient,
      subject: draft.subject,
      body: draft.body,
      replyTo: draft.replyToMessage,
      connection: connection
    )
    if !didSend {
      readerErrorMessage = mailActionViewModel.errorMessage
    }
    return didSend
  }

  private func saveDraft(_ draft: MailShellCompositionDraft) async -> Bool {
    guard
      let connectionId = draft.connectionId,
      let connection = connections.first(where: { $0.id == connectionId }),
      connection.authorizationState == .authorized
    else {
      readerErrorMessage = "Authorize the source Mailbox Connection before saving."
      return false
    }
    let didSave = await mailActionViewModel.saveDraft(
      OutgoingMessage(
        body: draft.body,
        recipient: draft.recipient,
        subject: draft.subject,
        inReplyTo: draft.replyToMessage?.rfcMessageId,
        providerThreadId: draft.replyToMessage?.providerThreadId,
        idempotencyKey: draft.id.uuidString.lowercased()
      ),
      connection: connection
    )
    if !didSave {
      readerErrorMessage = mailActionViewModel.errorMessage
    }
    return didSave
  }
}

private struct MailShellConversationMessage: View {
  let canForward: Bool
  let canReply: Bool
  let isExpanded: Bool
  let isLatest: Bool
  let isPinned: Bool
  let isUpdatingPin: Bool
  let loadBody: () async throws -> MailboxMessageBody
  let message: MailboxMessageMetadata
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
        MailShellMessageBody(load: loadBody)
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
          }
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

private struct MailShellMessageBody: View {
  let load: () async throws -> MailboxMessageBody
  @State private var messageBody: MailboxMessageBody?
  @State private var errorMessage: String?
  @State private var isLoading = false

  var body: some View {
    Group {
      if let messageBody {
        Text(messageBody.text)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
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
      isLoading = true
      defer { isLoading = false }
      do {
        messageBody = try await load()
        errorMessage = nil
      } catch is CancellationError {
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

private struct MailShellComposer: View {
  let allowsDraftSaving: Bool
  let connections: [MailboxConnection]
  @State private var draft: MailShellCompositionDraft
  let isSending: Bool
  let send: (MailShellCompositionDraft) async -> Bool
  let saveDraft: (MailShellCompositionDraft) async -> Bool
  @Environment(\.dismiss) private var dismiss

  init(
    connections: [MailboxConnection],
    draft: MailShellCompositionDraft,
    isSending: Bool,
    allowsDraftSaving: Bool = true,
    send: @escaping (MailShellCompositionDraft) async -> Bool,
    saveDraft: @escaping (MailShellCompositionDraft) async -> Bool
  ) {
    self.allowsDraftSaving = allowsDraftSaving
    self.connections = connections
    _draft = State(initialValue: draft)
    self.isSending = isSending
    self.send = send
    self.saveDraft = saveDraft
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
      }
      .navigationTitle(draft.title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        if allowsDraftSaving, selectedConnection?.providerId == .imapSMTP {
          ToolbarItem {
            Button("Save Draft") {
              Task {
                if await saveDraft(draft) {
                  dismiss()
                }
              }
            }
            .disabled(isSending || !draft.hasDraftContent)
          }
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
}

@MainActor
@Observable
final class PinViewModel {
  var errorMessage: String?
  private(set) var pinnedMessageIds: Set<StableProviderMessageIdentity> = []

  private let service: PinSyncing
  private let session: ProductAccountSessionSnapshot
  private var completedToggleGenerations: [StableProviderMessageIdentity: Int] = [:]
  private var updatingMessageIds: Set<StableProviderMessageIdentity> = []

  init(
    service: PinSyncing,
    session: ProductAccountSessionSnapshot
  ) {
    self.service = service
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
  private let session: ProductAccountSessionSnapshot

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
@Observable
// swiftlint:disable:next type_body_length
final class GmailMailActionViewModel {
  private(set) var blockedConnectionIds: [MailboxConnectionId] = []
  private(set) var bulkActionProgress: MailboxBulkActionProgress?
  var errorMessage: String?
  private(set) var failedConnectionIds: [MailboxConnectionId] = []
  var isPerformingAction = false
  private(set) var outboxItems: [OutgoingDeliveryAttempt] = []

  private var knownConnections: [MailboxConnection] = []
  private let outboxService: OutboxDeliveryService
  private var outboxRetryObservationTask: Task<Void, Never>?
  private var retryObservationTask: Task<Void, Never>?
  private let service: MailboxProviderMailActing
  private let session: ProductAccountSessionSnapshot

  var blockedConnectionId: MailboxConnectionId? {
    blockedConnectionIds.first
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
    outboxService: OutboxDeliveryService = .shared
  ) {
    self.outboxService = outboxService
    self.service = service
    self.session = session
  }

  func clearError() {
    errorMessage = nil
  }

  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String? = nil,
    sourceProviderMailboxId: String? = nil,
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
        targetProviderMailboxId: targetProviderMailboxId,
        sourceProviderMailboxId: sourceProviderMailboxId,
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

  func resume(connections: [MailboxConnection]) async {
    for connection in connections {
      remember(connection)
    }
    retryObservationTask?.cancel()
    errorMessage = await service.resumePendingActions(
      connections: connections,
      session: session
    )
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
      session: session
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
    connection: MailboxConnection
  ) async -> Bool {
    guard connection.capabilities.canSend else { return false }
    guard !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    guard !isPerformingAction else { return false }
    isPerformingAction = true
    defer { isPerformingAction = false }

    do {
      _ = try await outboxService.enqueue(
        OutgoingMessage(
          body: body,
          recipient: recipient,
          subject: subject,
          inReplyTo: replyTo?.rfcMessageId,
          providerThreadId: replyTo?.connectionId == connection.id && replyTo?.rfcMessageId != nil
            ? replyTo?.providerThreadId : nil
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

  func saveDraft(_ message: OutgoingMessage, connection: MailboxConnection) async -> Bool {
    guard
      connection.providerId == .imapSMTP,
      connection.authorizationState == .authorized,
      connection.capabilities.canSend,
      !isPerformingAction
    else { return false }
    isPerformingAction = true
    defer { isPerformingAction = false }
    do {
      try await service.saveDraft(message, connection: connection, session: session)
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
    connection: MailboxConnection
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
          providerThreadId: attempt.mailboxConnectionId == connection.id
            ? attempt.message.providerThreadId : nil
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

  func prepareForSignOut() async {
    outboxRetryObservationTask?.cancel()
    retryObservationTask?.cancel()
    do {
      try await outboxService.clear(session: session)
      outboxItems = []
    } catch {
      errorMessage = error.localizedDescription
    }
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
  func performBulk(
    _ action: ProviderMailAction,
    batches: [MailboxBulkActionBatch],
    sourceProviderMailboxId: String? = nil,
    onEnqueued: @escaping @Sendable (MailboxConnection) async -> Void = { _ in }
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
    let outcomes = await performBulkBatches(
      action,
      batches: batches,
      sourceProviderMailboxId: sourceProviderMailboxId,
      onEnqueued: onEnqueued
    )
    await refreshFailureConnections(knownConnections)
    let result = bulkActionResult(outcomes)
    errorMessage =
      result.failures.isEmpty
      ? nil
      : result.failures.map(Self.failureDescription).joined(separator: "\n")
    return result
  }

  private func performBulkBatches(
    _ action: ProviderMailAction,
    batches: [MailboxBulkActionBatch],
    sourceProviderMailboxId: String?,
    onEnqueued: @escaping @Sendable (MailboxConnection) async -> Void
  ) async -> [MailboxBulkActionBatchOutcome] {
    let service = self.service
    let session = self.session
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
            sourceProviderMailboxId: sourceProviderMailboxId,
            onEnqueued: onEnqueued
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

  // swiftlint:disable:next function_parameter_count
  nonisolated private static func performBulkBatch(
    _ action: ProviderMailAction,
    batch: MailboxBulkActionBatch,
    batchIndex: Int,
    service: MailboxProviderMailActing,
    session: ProductAccountSessionSnapshot,
    sourceProviderMailboxId: String?,
    onEnqueued: @escaping @Sendable (MailboxConnection) async -> Void
  ) async -> MailboxBulkActionBatchOutcome {
    do {
      try await service.perform(
        action,
        targetProviderMailboxId: batch.targetProviderMailboxId,
        sourceProviderMailboxId: sourceProviderMailboxId,
        messages: batch.messages,
        connection: batch.connection,
        session: session
      )
      await onEnqueued(batch.connection)
      let resumeError = await service.resumePendingActions(
        connection: batch.connection,
        session: session
      )
      let retryError = await service.waitForPendingActionRetries(
        connection: batch.connection,
        session: session
      )
      let failureDetails = await service.pendingActionFailureDetails(
        action,
        messages: batch.messages,
        connection: batch.connection,
        session: session
      )
      return bulkActionOutcome(
        batch,
        index: batchIndex,
        errorDescription: failureDetails?.isEmpty != false
          ? combinedErrorDescription([resumeError, retryError]) : nil,
        failureDetails: failureDetails
      )
    } catch {
      return bulkActionOutcome(
        batch,
        index: batchIndex,
        errorDescription: error.localizedDescription,
        failureDetails: nil
      )
    }
  }

  nonisolated private static func combinedErrorDescription(_ errors: [String?]) -> String? {
    let descriptions = errors.compactMap { $0 }.reduce(into: [String]()) {
      if !$0.contains($1) {
        $0.append($1)
      }
    }
    return descriptions.isEmpty ? nil : descriptions.joined(separator: "\n")
  }

  nonisolated private static func bulkActionOutcome(
    _ batch: MailboxBulkActionBatch,
    index: Int,
    errorDescription: String?,
    failureDetails: [MailboxProviderActionFailureDetail]?
  ) -> MailboxBulkActionBatchOutcome {
    MailboxBulkActionBatchOutcome(
      batchIndex: index,
      connection: batch.connection,
      errorDescription: errorDescription,
      failureDetails: failureDetails,
      messages: batch.messages
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
  private var backfillTask: Task<Void, Never>?
  private var backfillTaskId: UUID?
  private let bodyPrefetcher: MailboxMessageBodyPrefetching?
  private var bodyPrefetchTask: Task<Void, Never>?
  private var hasSignedOut = false
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
  private let session: ProductAccountSessionSnapshot
  private let syncCoordinator: MailboxFreshnessViewModel?

  init(
    bodyPrefetcher: MailboxMessageBodyPrefetching? = nil,
    service: MailboxMetadataSyncing,
    searchService: MailboxMessageSearching,
    syncCoordinator: MailboxFreshnessViewModel? = nil,
    session: ProductAccountSessionSnapshot,
    productMailboxState: MailShellProductMailboxState = .empty
  ) {
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

  var isRefreshDisabled: Bool {
    isCategorizingHistorical || isLoading || isSearching || isSyncing || backfillTask != nil
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
    return try await reader.loadMessageBody(message: message, session: session)
  }

  var messageCount: Int {
    threads.reduce(0) { count, thread in
      count + thread.messages.count
    }
  }

  func clear() {
    cancelBackfill()
    bodyPrefetchTask?.cancel()
    bodyPrefetchTask = nil
    currentConnectionId = nil
    unifiedConnectionIds = []
    unifiedLoadId = nil
    isLoading = false
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
    var errors: [String] = []
    for connection in connections {
      do {
        let result = try await loadProjectedMailbox(
          collection,
          connection: connection,
          pinnedMessageIds: navigationSnapshot.pinnedMessageIds
        )
        guard
          applyUnifiedInboxResult(
            result,
            for: connection.id,
            loadId: loadId,
            connectionIds: connectionIds,
            threadsByConnection: &threadsByConnection
          )
        else { return nil }
      } catch is CancellationError {
        return nil
      } catch {
        errors.append("\(connection.displayName): \(error.localizedDescription)")
      }
    }
    return errors
  }

  private func syncUnifiedInboxes(
    for connections: [MailboxConnection],
    collection: MailboxMessageCollection,
    loadId: UUID,
    connectionIds: Set<MailboxConnectionId>,
    threadsByConnection: inout [MailboxConnectionId: [MailboxThread]]
  ) async -> (connectionsNeedingBackfill: [MailboxConnection], errors: [String])? {
    var connectionsNeedingBackfill: [MailboxConnection] = []
    var errors: [String] = []
    for connection in connections {
      do {
        guard
          let needsBackfill = try await syncUnifiedInbox(
            for: connection,
            collection: collection,
            loadId: loadId,
            connectionIds: connectionIds,
            threadsByConnection: &threadsByConnection
          )
        else { return nil }
        if needsBackfill {
          connectionsNeedingBackfill.append(connection)
        }
      } catch is CancellationError {
        return nil
      } catch {
        errors.append("\(connection.displayName): \(error.localizedDescription)")
      }
    }
    return (connectionsNeedingBackfill, errors)
  }

  private func syncUnifiedInbox(
    for connection: MailboxConnection,
    collection: MailboxMessageCollection,
    loadId: UUID,
    connectionIds: Set<MailboxConnectionId>,
    threadsByConnection: inout [MailboxConnectionId: [MailboxThread]]
  ) async throws -> Bool? {
    let syncedResult = try await synchronizeInbox(connection: connection)
    let projectedResult = try await loadProjectedMailbox(
      collection,
      connection: connection,
      pinnedMessageIds: navigationSnapshot.pinnedMessageIds
    )
    guard
      applyUnifiedInboxResult(
        projectedResult,
        for: connection.id,
        loadId: loadId,
        connectionIds: connectionIds,
        threadsByConnection: &threadsByConnection
      )
    else { return nil }
    await refreshNavigationSnapshot(for: connection)
    return !syncedResult.historicalMetadataBackfillIsComplete
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
    var errors: [String] = []
    for connection in connections {
      do {
        _ = try await continueHistoricalBackfill(connection: connection)
        let backfillResult = try await loadProjectedMailbox(
          collection,
          connection: connection,
          pinnedMessageIds: navigationSnapshot.pinnedMessageIds
        )
        guard
          applyUnifiedInboxResult(
            backfillResult,
            for: connection.id,
            loadId: loadId,
            connectionIds: connectionIds,
            threadsByConnection: &threadsByConnection
          )
        else { return nil }
      } catch is CancellationError {
        return nil
      } catch {
        errors.append("\(connection.displayName): \(error.localizedDescription)")
      }
    }
    return errors
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
      errorMessage = error.localizedDescription
    }
  }

  private func updateUnifiedThreads(
    _ updatedThreads: [MailboxThread],
    for connectionId: MailboxConnectionId,
    in threadsByConnection: inout [MailboxConnectionId: [MailboxThread]]
  ) {
    threadsByConnection[connectionId] = updatedThreads
    threads = MailboxThread.group(
      threadsByConnection.values.flatMap { $0 }.flatMap(\.messages)
    )
  }

  private func applyUnifiedInboxResult(
    _ result: MailboxMetadataSyncResult,
    for connectionId: MailboxConnectionId,
    loadId: UUID,
    connectionIds: Set<MailboxConnectionId>,
    threadsByConnection: inout [MailboxConnectionId: [MailboxThread]]
  ) -> Bool {
    guard !Task.isCancelled, unifiedLoadId == loadId, unifiedConnectionIds == connectionIds else {
      return false
    }
    updateUnifiedThreads(result.threads, for: connectionId, in: &threadsByConnection)
    return true
  }

  private func loadProjectedMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    pinnedMessageIds: Set<StableProviderMessageIdentity>
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
      errorMessage = error.localizedDescription
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

  func reloadLocal(connection: MailboxConnection) async -> Bool {
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
      await refreshNavigationSnapshot(for: connection)
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
    guard !isAssigningCategory else { return }
    isAssigningCategory = true
    defer { isAssigningCategory = false }

    do {
      let overriddenMessage = try await service.overrideCategory(
        categoryId,
        for: message,
        session: session
      )
      guard currentConnectionId == message.connectionId else {
        return
      }
      let messages = threads.flatMap(\.messages).map { existingMessage in
        existingMessage.stableProviderMessageId == overriddenMessage.stableProviderMessageId
          ? overriddenMessage : existingMessage
      }
      threads = MailboxThread.group(messages)
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

@MainActor
@Observable
final class MailboxProviderConnectionViewModel {
  var connections: [MailboxConnection] = []
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
  private let service: MailboxConnectionAdapter
  private let session: ProductAccountSessionSnapshot
  private var pushStatusMessages: [MailboxConnectionId: String] = [:]

  init(
    service: MailboxConnectionAdapter,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool,
    session: ProductAccountSessionSnapshot
  ) {
    self.isSessionCurrent = isSessionCurrent
    self.service = service
    self.session = session
  }

  var canConnect: Bool {
    !isConnecting && !isLoading && !isRemoving && !isRenewingPushWatch
  }

  var isEditingDisabled: Bool {
    isConnecting || isLoading || isRemoving || isRenewingPushWatch
  }

  var connection: MailboxConnection? {
    connections.first { $0.id == selectedConnectionId }
  }

  func load() async -> Bool {
    isLoading = true
    defer {
      isLoading = false
    }

    do {
      try await refreshConnections()
      await completeLoadingConnections()
      return true
    } catch {
      let originalError = error
      do {
        try await refreshConnections()
        await completeLoadingConnections()
        return true
      } catch {
        errorMessage = originalError.localizedDescription
        return false
      }
    }
  }

  private func completeLoadingConnections() async {
    if !connections.contains(where: { $0.id == selectedConnectionId }) {
      selectedConnectionId =
        connections.first { $0.id == defaultSendingConnectionId }?.id
        ?? connections.first?.id
    }
    pushStatusMessages = pushStatusMessages.filter { connectionId, _ in
      connections.contains { $0.id == connectionId }
    }
    errorMessage = nil
    for connection in connections {
      await refreshPushWatch(connection: connection)
    }
  }

  func connect(expectedConnection: MailboxConnection? = nil) async -> MailboxConnection? {
    guard canConnect else { return nil }

    isConnecting = true
    defer {
      isConnecting = false
    }

    do {
      let connected = try await service.connect(
        expectedConnectionId: expectedConnection?.id,
        session: session,
        isSessionCurrent: isSessionCurrent
      )
      errorMessage = nil
      if let connected {
        try await refreshConnections()
        selectedConnectionId = connected.id
        await refreshPushWatch(connection: connected)
        return connected
      }
    } catch is CancellationError {
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

  func removeLocalAuthorization(_ connection: MailboxConnection) async {
    guard !isEditingDisabled else { return }
    isRemoving = true
    defer { isRemoving = false }
    do {
      try await service.clearLocalConnection(connection, session: session)
      try await refreshConnections()
      pushStatusMessages[connection.id] = nil
      selectedConnectionId = connection.id
      errorMessage = nil
    } catch {
      if let refreshedConnections = try? await service.loadConnections(session: session) {
        connections = refreshedConnections.sorted {
          $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        pushStatusMessages = pushStatusMessages.filter { connectionId, _ in
          connections.contains { $0.id == connectionId }
        }
        if selectedConnectionId == connection.id {
          selectedConnectionId = connections.first?.id
        }
      }
      errorMessage = error.localizedDescription
    }
  }

  func removeEverywhere(_ connection: MailboxConnection) async {
    guard !isEditingDisabled else { return }
    isRemoving = true
    defer { isRemoving = false }
    do {
      try await service.removeMailboxConnectionEverywhere(connection, session: session)
      try await refreshConnections()
      pushStatusMessages[connection.id] = nil
      if selectedConnectionId == connection.id {
        selectedConnectionId = connections.first?.id
      }
      errorMessage = nil
    } catch {
      try? await refreshConnections()
      errorMessage = error.localizedDescription
    }
  }

  func setDefaultSendingConnection(_ connection: MailboxConnection) async {
    guard !isEditingDisabled else { return }
    do {
      try await service.setDefaultSendingConnection(connection, session: session)
      defaultSendingConnectionId = connection.id
      selectedConnectionId = connection.id
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func refreshConnections() async throws {
    let loadedConnections = try await service.loadConnections(session: session)
      .sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
    connections = loadedConnections
    defaultSendingConnectionId = try await service.loadDefaultSendingConnectionId(session: session)
  }

  private func refreshPushWatch(connection: MailboxConnection) async {
    guard connection.capabilities.canRegisterPush else {
      pushStatusMessages[connection.id] = nil
      return
    }
    do {
      try Task.checkCancellation()
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
  private let session: ProductAccountSessionSnapshot

  init(service: CustomCategorySyncing, session: ProductAccountSessionSnapshot) {
    self.service = service
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

private struct GmailProviderConnectionPanel: View {
  let cancelBodyPrefetch: () async -> Void
  @Bindable var viewModel: MailboxProviderConnectionViewModel
  let isMailboxBusy: Bool
  let selectMailbox: (MailboxConnection) -> Void

  var body: some View {
    MailboxProviderConnectionPanel(
      cancelBodyPrefetch: cancelBodyPrefetch,
      configuration: .gmail,
      isMailboxBusy: isMailboxBusy,
      selectMailbox: selectMailbox,
      viewModel: viewModel
    )
  }
}

private struct MicrosoftGraphConnectionPanel: View {
  let cancelBodyPrefetch: () async -> Void
  let connectionsDidChange: () -> Void
  let connectionDidConnect: (MailboxConnection) -> Void
  let isMailboxBusy: Bool
  let selectMailbox: (MailboxConnection) -> Void
  @Bindable var viewModel: MailboxProviderConnectionViewModel

  var body: some View {
    MailboxProviderConnectionPanel(
      cancelBodyPrefetch: cancelBodyPrefetch,
      configuration: .microsoftGraph,
      connectionsDidChange: connectionsDidChange,
      connectionDidConnect: connectionDidConnect,
      isMailboxBusy: isMailboxBusy,
      selectMailbox: selectMailbox,
      viewModel: viewModel
    )
  }
}

private struct MailboxProviderConnectionPanel: View {
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
      allowsDefaultSender: false,
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
          Task { _ = await viewModel.load() }
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
                  }
                }
              }
            } else {
              if configuration.allowsDefaultSender {
                Button("Set as Default Sending Connection") {
                  Task {
                    await viewModel.setDefaultSendingConnection(connection)
                  }
                }
                .disabled(viewModel.defaultSendingConnectionId == connection.id)
              }
              Button("Remove Device Authorization", role: .destructive) {
                Task {
                  await cancelBodyPrefetch()
                  await viewModel.removeLocalAuthorization(connection)
                }
              }
            }
            Divider()
            Button("Remove Mailbox Connection Everywhere", role: .destructive) {
              Task {
                await cancelBodyPrefetch()
                await viewModel.removeEverywhere(connection)
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
          }
        }
      } label: {
        Label(
          connections.isEmpty
            ? configuration.emptyConnectTitle : configuration.otherConnectTitle,
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
    .onChange(of: viewModel.connections) { _, _ in
      connectionsDidChange()
    }
    .onDisappear {
      connectTask?.cancel()
    }
  }
}

private struct MessageCategoryChoice: Identifiable {
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

private struct GmailSearchPanel: View {
  @Binding var query: String
  let result: GmailSearchResult?
  let allowsProviderSearch: Bool
  let isDisabled: Bool
  let isSearching: Bool
  let providerDisplayName: String
  let clear: () -> Void
  let open: (MailboxMessageMetadata) -> Void
  let searchLocal: () -> Void
  let searchProvider: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Search")
        .font(.subheadline.bold())
      TextField(
        "Sender, recipient, subject, date, state, or Category",
        text: $query
      )
      .textFieldStyle(.roundedBorder)

      HStack {
        Button("Search Local Metadata", action: searchLocal)
          .buttonStyle(.borderedProminent)
          .disabled(isDisabled || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if allowsProviderSearch {
          Button("Search \(providerDisplayName) Full Text", action: searchProvider)
            .buttonStyle(.bordered)
            .disabled(isDisabled || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if result != nil {
          Button("Clear Search", action: clear)
            .buttonStyle(.plain)
        }
      }

      Text(searchPrivacyDescription)
        .font(.footnote)
        .foregroundStyle(.secondary)

      if isSearching {
        ProgressView("Searching \(providerDisplayName)...")
      }

      if let result {
        Label(
          "\(result.messages.count) results from \(result.source.title(providerDisplayName: providerDisplayName))",
          systemImage: result.source == .localMetadata ? "internaldrive" : "cloud"
        )
        .font(.subheadline.bold())

        if result.messages.isEmpty {
          Text("No matching messages.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
          ForEach(result.messages) { message in
            Button {
              open(message)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(message.subject)
                  .font(.subheadline.bold())
                Text(message.from ?? "Unknown sender")
                  .font(.footnote)
                  .foregroundStyle(.secondary)
                Text(message.snippet)
                  .font(.footnote)
                  .lineLimit(2)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private var searchPrivacyDescription: String {
    guard allowsProviderSearch else {
      return "Local search stays on this device."
    }
    return "Local search stays on this device. \(providerDisplayName) full-text search sends only "
      + "this query to \(providerDisplayName)."
  }
}

// swiftlint:disable:next type_body_length
private struct GmailInboxPanel: View {
  let categoryChoices: [MessageCategoryChoice]
  let connection: MailboxConnection?
  let defaultSendingConnectionId: MailboxConnectionId?
  let isConnectionBusy: Bool
  @Bindable var mailActionViewModel: GmailMailActionViewModel
  let messageReader: MailboxMessageReading
  let session: ProductAccountSessionSnapshot
  @Bindable var viewModel: GmailInboxViewModel
  @State private var searchTask: Task<Void, Never>?
  @State private var syncTask: Task<Void, Never>?
  @State private var cacheErrorMessage: String?
  @State private var composeBody = ""
  @State private var isReplyOrForward = false
  @State private var recipient = ""
  @State private var replyToMessage: MailboxMessageMetadata?
  @State private var selectedMessage: MailboxMessageMetadata?
  @State private var subject = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Inbox")
            .font(.headline)
          Text(summaryText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if connection?.capabilities.canReadMessages != false {
          Button("Remove Cached Bodies", role: .destructive) {
            Task {
              do {
                await viewModel.cancelBodyPrefetch()
                if let connection {
                  try messageReader.clearCachedMessageBodies(
                    connection: connection,
                    session: session
                  )
                } else {
                  try messageReader.clearCachedMessageBodies(session: session)
                }
                cacheErrorMessage = nil
              } catch {
                cacheErrorMessage = error.localizedDescription
              }
            }
          }
          .buttonStyle(.bordered)
          .disabled(isConnectionBusy || mailActionViewModel.isPerformingAction)
        }

        if let connection, connection.capabilities.canSynchronizeMetadata {
          Button {
            syncTask?.cancel()
            syncTask = Task {
              if await viewModel.sync(connection: connection) {
                mailActionViewModel.clearError()
              }
            }
          } label: {
            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
          }
          .buttonStyle(.bordered)
          .disabled(
            viewModel.isRefreshDisabled
              || viewModel.isAssigningCategory
              || mailActionViewModel.isPerformingAction
              || isConnectionBusy
          )
        }
      }

      if let connection {
        if connection.capabilities.canSend,
          connection.id == defaultSendingConnectionId || isReplyOrForward
        {
          GmailComposePanel(
            cancelReply: {
              replyToMessage = nil
              isReplyOrForward = false
              recipient = ""
              subject = ""
              composeBody = ""
            },
            messageBody: $composeBody,
            isDisabled: mailActionViewModel.isPerformingAction || isConnectionBusy,
            isReplying: replyToMessage != nil,
            recipient: $recipient,
            senderDisplayName: connection.displayName,
            subject: $subject,
            send: {
              Task {
                if await mailActionViewModel.send(
                  recipient: recipient,
                  subject: subject,
                  body: composeBody,
                  replyTo: replyToMessage,
                  connection: connection
                ) {
                  replyToMessage = nil
                  isReplyOrForward = false
                  recipient = ""
                  subject = ""
                  composeBody = ""
                }
              }
            }
          )
        }

        if connection.capabilities.canCategorizeHistorical {
          HistoricalCategorizationPanel(
            isDisabled: viewModel.isRefreshDisabled
              || viewModel.isAssigningCategory
              || mailActionViewModel.isPerformingAction
              || isConnectionBusy,
            isWorking: viewModel.isCategorizingHistorical,
            categorize: { scope in
              Task {
                await viewModel.categorizeHistorical(
                  scope: scope,
                  connection: connection
                )
              }
            }
          )
        }

        GmailSearchPanel(
          query: $viewModel.searchQuery,
          result: viewModel.searchResult,
          allowsProviderSearch: connection.capabilities.canSearchProvider,
          isDisabled: viewModel.isRefreshDisabled
            || viewModel.isAssigningCategory
            || mailActionViewModel.isPerformingAction
            || isConnectionBusy,
          isSearching: viewModel.isSearching,
          providerDisplayName: connection.providerId.rawValue.capitalized,
          clear: viewModel.clearSearch,
          open: { message in
            selectedMessage = message
          },
          searchLocal: {
            viewModel.searchLocal(
              categoryNamesById: Dictionary(
                uniqueKeysWithValues: categoryChoices.map { ($0.id, $0.name) }
              )
            )
          },
          searchProvider: {
            searchTask?.cancel()
            searchTask = Task {
              await viewModel.searchProvider(connection: connection)
            }
          }
        )

        if viewModel.threads.isEmpty && !viewModel.isLoading && !viewModel.isSyncing {
          Text("No local inbox metadata yet.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(viewModel.threads) { thread in
              GmailInboxThreadRow(
                connection: connection,
                categoryChoices: categoryChoices,
                isDisabled: mailActionViewModel.isPerformingAction
                  || viewModel.isRefreshDisabled
                  || viewModel.isAssigningCategory
                  || isConnectionBusy,
                mailActionViewModel: mailActionViewModel,
                refreshInbox: {
                  if await viewModel.reloadLocal(connection: connection) {
                    mailActionViewModel.clearError()
                  }
                },
                reply: { message in
                  isReplyOrForward = true
                  replyToMessage = message
                  recipient = MailShellCompositionDraft.replyRecipient(for: message)
                  subject = message.subject == "(No subject)" ? "" : "Re: \(message.subject)"
                  composeBody = "\n\nOn \(message.from ?? "Unknown sender"):\n\(message.snippet)"
                },
                setCategory: { categoryId, message in
                  await viewModel.overrideCategory(categoryId, for: message)
                },
                thread: thread,
                forward: { message in
                  do {
                    let body = try await viewModel.loadMessageBody(
                      message,
                      using: messageReader
                    )
                    guard !Task.isCancelled else { return }
                    cacheErrorMessage = nil
                    isReplyOrForward = true
                    replyToMessage = nil
                    recipient = ""
                    subject = "Fwd: \(message.subject)"
                    composeBody =
                      "\n\nForwarded message from \(message.from ?? "Unknown sender"):\n\(body.text)"
                  } catch is CancellationError {
                    return
                  } catch {
                    cacheErrorMessage = error.localizedDescription
                  }
                },
                open: { message in
                  selectedMessage = message
                }
              )
              ForEach(thread.messages.dropFirst()) { message in
                HStack {
                  Button {
                    selectedMessage = message
                  } label: {
                    Text(message.subject)
                      .font(.footnote)
                      .frame(maxWidth: .infinity, alignment: .leading)
                  }
                  .buttonStyle(.plain)
                  if thread.inboxMessages.contains(message) {
                    MessageCategoryMenu(
                      categoryChoices: categoryChoices,
                      currentCategoryId: message.categoryId,
                      isDisabled: mailActionViewModel.isPerformingAction
                        || viewModel.isRefreshDisabled
                        || viewModel.isAssigningCategory
                        || isConnectionBusy,
                      setCategory: { categoryId in
                        await viewModel.overrideCategory(categoryId, for: message)
                      }
                    )
                  }
                }
              }
              Divider()
            }
          }
        }
      } else {
        Text("Connect Gmail to sync inbox metadata.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      if viewModel.isLoading || viewModel.isSyncing {
        ProgressView(viewModel.isSyncing ? "Syncing Gmail metadata..." : "Loading inbox...")
      }

      if let errorMessage = viewModel.errorMessage ?? mailActionViewModel.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .font(.footnote)
      }
      if let cacheErrorMessage {
        Text(cacheErrorMessage)
          .foregroundStyle(.red)
          .font(.footnote)
      }
    }
    .task(id: connection?.id) {
      searchTask?.cancel()
      syncTask?.cancel()
      mailActionViewModel.clearError()
      replyToMessage = nil
      isReplyOrForward = false
      recipient = ""
      subject = ""
      composeBody = ""
      guard let connection else {
        viewModel.clear()
        return
      }

      await viewModel.loadAfterConnectionChange(connection: connection)
    }
    .onDisappear {
      searchTask?.cancel()
      syncTask?.cancel()
    }
    .sheet(item: $selectedMessage) { message in
      GmailMessageBodySheet(
        message: message,
        reader: messageReader,
        session: session,
        loadMessageBody: {
          try await viewModel.loadMessageBody(message, using: messageReader)
        }
      )
    }
  }

  private var summaryText: String {
    guard connection != nil else {
      return "Gmail metadata stays local on this trusted device."
    }

    return "\(viewModel.threads.count) threads, \(viewModel.messageCount) messages"
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

      HStack {
        DatePicker("From", selection: $startDate, displayedComponents: .date)
        DatePicker("Through", selection: $endDate, displayedComponents: .date)
      }

      Button("Categorize Selected Old Emails") {
        categorize(scope)
      }
      .buttonStyle(.borderedProminent)
      .disabled(
        !HistoricalCategorizationScope.isValidDateRange(
          startDate: startDate,
          endDate: endDate,
          calendar: .current
        ) || isDisabled
      )

      if isWorking {
        ProgressView("Categorizing selected old emails...")
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

private struct GmailMessageBodySheet: View {
  let message: MailboxMessageMetadata
  @Environment(\.dismiss) private var dismiss
  @State private var viewModel: GmailMessageBodyViewModel

  init(
    message: MailboxMessageMetadata,
    reader: MailboxMessageReading,
    session: ProductAccountSessionSnapshot,
    loadMessageBody: @escaping () async throws -> MailboxMessageBody
  ) {
    self.message = message
    _viewModel = State(
      initialValue: GmailMessageBodyViewModel(
        message: message,
        reader: reader,
        session: session,
        loadMessageBody: loadMessageBody
      )
    )
  }

  var body: some View {
    NavigationStack {
      Group {
        if let body = viewModel.body {
          ScrollView {
            Text(body.text)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
              .padding()
          }
        } else if viewModel.isLoading {
          ProgressView("Loading message…")
        } else if let errorMessage = viewModel.errorMessage {
          ContentUnavailableView(
            "Message unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text(errorMessage)
          )
        } else if viewModel.didRemoveCachedBody {
          ContentUnavailableView(
            "Cached body removed",
            systemImage: "trash",
            description: Text("Reopen this message to fetch it again.")
          )
        }
      }
      .navigationTitle(message.subject)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        if viewModel.body != nil {
          ToolbarItem(placement: .primaryAction) {
            Button("Remove Cached Body", role: .destructive) {
              viewModel.removeCachedBody()
            }
          }
        }
      }
      .task { await viewModel.load() }
    }
  }
}

@MainActor
@Observable
private final class GmailMessageBodyViewModel {
  var body: MailboxMessageBody?
  var didRemoveCachedBody = false
  var errorMessage: String?
  var isLoading = false

  private let message: MailboxMessageMetadata
  private let loadMessageBody: () async throws -> MailboxMessageBody
  private let reader: MailboxMessageReading
  private let session: ProductAccountSessionSnapshot

  init(
    message: MailboxMessageMetadata,
    reader: MailboxMessageReading,
    session: ProductAccountSessionSnapshot,
    loadMessageBody: @escaping () async throws -> MailboxMessageBody
  ) {
    self.loadMessageBody = loadMessageBody
    self.message = message
    self.reader = reader
    self.session = session
  }

  func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      body = try await loadMessageBody()
      didRemoveCachedBody = false
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func removeCachedBody() {
    do {
      try reader.removeCachedMessageBody(message: message, session: session)
      body = nil
      didRemoveCachedBody = true
      errorMessage = nil
    } catch {
      body = nil
      didRemoveCachedBody = false
      errorMessage = error.localizedDescription
    }
  }
}

private struct GmailComposePanel: View {
  let cancelReply: () -> Void
  @Binding var messageBody: String
  let isDisabled: Bool
  let isReplying: Bool
  @Binding var recipient: String
  let senderDisplayName: String
  @Binding var subject: String
  let send: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Compose")
        .font(.subheadline.bold())
      if isReplying {
        Button("Cancel Reply", action: cancelReply)
          .buttonStyle(.borderless)
      }
      LabeledContent("From", value: senderDisplayName)
      TextField("To", text: $recipient)
        .textFieldStyle(.roundedBorder)
      TextField("Subject", text: $subject)
        .textFieldStyle(.roundedBorder)
      TextField("Message", text: $messageBody, axis: .vertical)
        .lineLimit(3...6)
        .textFieldStyle(.roundedBorder)
      Button("Send", action: send)
        .buttonStyle(.borderedProminent)
        .disabled(isDisabled || recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .disabled(isDisabled)
  }
}

private struct GmailInboxThreadRow: View {
  let connection: MailboxConnection
  let categoryChoices: [MessageCategoryChoice]
  let isDisabled: Bool
  @Bindable var mailActionViewModel: GmailMailActionViewModel
  let refreshInbox: () async -> Void
  let reply: (MailboxMessageMetadata) -> Void
  let setCategory: (String, MailboxMessageMetadata) async -> Void
  let thread: MailboxThread
  let forward: (MailboxMessageMetadata) async -> Void
  let open: (MailboxMessageMetadata) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text(thread.latestMessage.subject)
            .font(.subheadline.bold())
          if let from = thread.latestMessage.from {
            Text(from)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 4) {
          Text(categoryState)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
          if thread.messages.count > 1 {
            Text("\(thread.messages.count) messages")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      if !thread.latestMessage.snippet.isEmpty {
        Text(thread.latestMessage.snippet)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Menu("Actions") {
        if connection.capabilities.canReadMessages {
          Button("Open Message") { open(thread.latestMessage) }
        }
        Menu("Set Category") {
          ForEach(categoryChoices) { choice in
            Button {
              Task { await setCategory(choice.id, categoryMessage) }
            } label: {
              if choice.id == categoryMessage.categoryId {
                Label(choice.name, systemImage: "checkmark")
              } else {
                Text(choice.name)
              }
            }
          }
        }
        Divider()
        if connection.capabilities.canReply {
          Button("Reply") { reply(thread.latestMessage) }
        }
        if connection.capabilities.canForward {
          Button("Forward") {
            Task { await forward(thread.latestMessage) }
          }
        }
        if connection.capabilities.canReply || connection.capabilities.canForward {
          Divider()
        }
        if connection.capabilities.supports(.markRead) {
          Button("Mark Read") { perform(.markRead) }
        }
        if connection.capabilities.supports(.markUnread) {
          Button("Mark Unread") { perform(.markUnread) }
        }
        if connection.capabilities.supports(.star) {
          Button("Star") { perform(.star) }
        }
        if connection.capabilities.supports(.unstar) {
          Button("Unstar") { perform(.unstar) }
        }
        if connection.capabilities.supports(.archive) {
          Button("Archive") { perform(.archive) }
        }
        if connection.capabilities.supports(.delete) {
          Button("Delete", role: .destructive) { perform(.delete) }
        }
      }
      .disabled(isDisabled)
    }
  }

  private var categoryState: String {
    guard let categoryId = categoryMessage.categoryId else {
      return "Uncategorized"
    }
    return categoryChoices.first { $0.id == categoryId }?.name ?? "Categorized"
  }

  private var categoryMessage: MailboxMessageMetadata {
    thread.inboxMessages.first ?? thread.latestMessage
  }

  private func perform(_ action: ProviderMailAction) {
    Task {
      let didPerformAction = await mailActionViewModel.perform(
        action,
        sourceProviderMailboxId: "INBOX",
        for: thread.inboxMessages,
        connection: connection
      )
      if didPerformAction && !Task.isCancelled {
        await refreshInbox()
        await mailActionViewModel.resume(connections: [connection])
        await refreshInbox()
      }
    }
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
        .labelStyle(.iconOnly)
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
}
