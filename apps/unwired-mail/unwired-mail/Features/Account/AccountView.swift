import SwiftUI

// swiftlint:disable file_length

struct AccountView: View {
  let session: ProductAccountSession
  let snapshot: ProductAccountSessionSnapshot
  private let messageReader: MailboxMessageReading

  @Environment(\.scenePhase) private var scenePhase

  @State private var categoryViewModel: CustomCategoryViewModel
  @State private var genericMailSetupViewModel: GenericMailSetupViewModel
  @State private var gmailViewModel: GmailProviderConnectionViewModel
  @State private var inboxViewModel: GmailInboxViewModel
  @State private var mailActionViewModel: GmailMailActionViewModel
  @State private var notificationRuleViewModel: NotificationRuleViewModel

  @MainActor
  init(
    session: ProductAccountSession,
    snapshot: ProductAccountSessionSnapshot,
    categorySyncService: CustomCategorySyncing = CustomCategorySyncService(),
    mailboxConnection: MailboxConnectionAdapter = GmailMailboxConnectionAdapter(),
    notificationAuthorization: NotificationAuthorizationRequesting = UserNotificationService(),
    notificationRuleSync: NotificationRuleSyncing = NotificationRuleSyncService()
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
        isSessionCurrent: { session.isCurrent(snapshot) },
        syncSession: snapshot
      )
    )
    _gmailViewModel = State(
      initialValue: GmailProviderConnectionViewModel(
        service: mailboxConnection,
        isSessionCurrent: { session.isCurrent($0) },
        session: snapshot
      )
    )
    _inboxViewModel = State(
      initialValue: GmailInboxViewModel(
        service: mailboxConnection,
        searchService: mailboxConnection,
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
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Unwired Mail")
            .font(.largeTitle.bold())
          Text("Product Account")
            .font(.title2)
            .foregroundStyle(.secondary)
        }

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
          viewModel: gmailViewModel,
          isMailboxBusy: inboxViewModel.isBusy || mailActionViewModel.isPerformingAction
        )

        GenericMailSetupPanel(viewModel: genericMailSetupViewModel)

        GmailInboxPanel(
          categoryChoices: MessageCategoryChoice.available(
            customCategory: categoryViewModel.category
          ),
          connection: gmailViewModel.connection?.authorizationState == .authorized
            ? gmailViewModel.connection : nil,
          isConnectionBusy: gmailViewModel.isEditingDisabled,
          mailActionViewModel: mailActionViewModel,
          messageReader: messageReader,
          session: snapshot,
          viewModel: inboxViewModel
        )

        SmokeView(service: ConvexBackendHealthService())

        Button("Sign Out", role: .destructive) {
          genericMailSetupViewModel.invalidate()
          Task {
            await session.signOut()
          }
        }
        .buttonStyle(.bordered)
      }
      .padding(32)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
      await gmailViewModel.load()
      await genericMailSetupViewModel.loadSyncedDefinitions()
      if let connection = gmailViewModel.connection,
        connection.authorizationState == .authorized
      {
        await inboxViewModel.loadAfterConnectionChange(connection: connection)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task {
        await gmailViewModel.load()
        await genericMailSetupViewModel.loadSyncedDefinitions()
      }
    }
    .onChange(of: gmailViewModel.connection?.id) { _, _ in
      guard
        let connection = gmailViewModel.connection,
        connection.authorizationState == .authorized
      else { return }
      Task {
        await inboxViewModel.loadAfterConnectionChange(connection: connection)
      }
    }
    .onChange(of: gmailViewModel.connection?.authorizationState) { _, authorizationState in
      guard
        let connection = gmailViewModel.connection,
        authorizationState == .authorized
      else {
        inboxViewModel.clear()
        return
      }
      Task {
        await inboxViewModel.loadAfterConnectionChange(connection: connection)
      }
    }
    .onChange(of: gmailViewModel.defaultSendingConnectionId) { _, _ in
      Task {
        await genericMailSetupViewModel.loadSyncedDefinitions()
      }
    }
    .onChange(of: genericMailSetupViewModel.defaultSendingConnectionId) { _, _ in
      Task {
        await gmailViewModel.load()
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
private final class GmailMailActionViewModel {
  var errorMessage: String?
  var isPerformingAction = false

  private let service: MailboxProviderMailActing
  private let session: ProductAccountSessionSnapshot

  init(service: MailboxProviderMailActing, session: ProductAccountSessionSnapshot) {
    self.service = service
    self.session = session
  }

  func clearError() {
    errorMessage = nil
  }

  func perform(
    _ action: ProviderMailAction,
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
      try await service.send(
        OutgoingMessage(
          body: body,
          recipient: recipient,
          subject: subject,
          inReplyTo: replyTo?.rfcMessageId,
          providerThreadId: replyTo?.rfcMessageId == nil ? nil : replyTo?.providerThreadId
        ),
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
}

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class GmailInboxViewModel {
  private var backfillTask: Task<Void, Never>?
  private var backfillTaskId: UUID?
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

  private var currentConnectionId: MailboxConnectionId?
  private let searchService: MailboxMessageSearching
  private let service: MailboxMetadataSyncing
  private let session: ProductAccountSessionSnapshot

  init(
    service: MailboxMetadataSyncing,
    searchService: MailboxMessageSearching,
    session: ProductAccountSessionSnapshot
  ) {
    self.searchService = searchService
    self.service = service
    self.session = session
  }

  var isRefreshDisabled: Bool {
    isCategorizingHistorical || isLoading || isSearching || isSyncing || backfillTask != nil
  }

  var isBusy: Bool {
    isAssigningCategory || isCategorizingHistorical || isLoading || isLoadingMessageBody
      || isSearching || isSyncing
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
    currentConnectionId = nil
    threads = []
    searchQuery = ""
    searchResult = nil
    errorMessage = nil
  }

  func load(connection: MailboxConnection) async {
    isLoading = true
    defer {
      isLoading = false
    }

    do {
      let result = try await service.loadInbox(
        connection: connection,
        session: session
      )
      try Task.checkCancellation()
      guard currentConnectionId == connection.id
      else {
        return
      }
      threads = result.threads
      errorMessage = nil
      if result.hasInitialMailboxAvailability && !result.historicalMetadataBackfillIsComplete {
        startHistoricalBackfill(connection: connection)
      }
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func loadAfterConnectionChange(connection: MailboxConnection) async {
    if currentConnectionId != connection.id {
      cancelBackfill()
      currentConnectionId = connection.id
      threads = []
      searchQuery = ""
      searchResult = nil
      errorMessage = nil
    }

    await load(connection: connection)
    guard
      !Task.isCancelled,
      currentConnectionId == connection.id
    else {
      return
    }
    if backfillTask == nil {
      _ = await sync(connection: connection)
    }
  }

  func sync(connection: MailboxConnection) async -> Bool {
    cancelBackfill()
    if currentConnectionId != connection.id {
      currentConnectionId = connection.id
      threads = []
      errorMessage = nil
    }

    isSyncing = true
    defer {
      isSyncing = false
    }

    do {
      var result = try await service.syncInbox(
        connection: connection,
        session: session
      )
      guard currentConnectionId == connection.id
      else {
        return false
      }
      threads = result.threads
      errorMessage = nil
      if !result.historicalMetadataBackfillIsComplete {
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
        let backfill = try await service.continueHistoricalBackfill(
          connection: connection,
          session: session
        )
        guard
          !Task.isCancelled,
          backfillTaskId == taskId,
          currentConnectionId == connection.id
        else { return }
        threads = backfill.threads
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, backfillTaskId == taskId else { return }
        errorMessage = error.localizedDescription
      }
    }
  }

  func refresh(connection: MailboxConnection) async -> Bool {
    guard currentConnectionId == connection.id else {
      return false
    }
    return await sync(connection: connection)
  }

  private func cancelBackfill() {
    backfillTask?.cancel()
    backfillTask = nil
    backfillTaskId = nil
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
final class GmailProviderConnectionViewModel {
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

  func load() async {
    isLoading = true
    defer {
      isLoading = false
    }

    do {
      try await refreshConnections()
      if !connections.contains(where: { $0.id == selectedConnectionId }) {
        if defaultSendingConnectionId?.providerId == .gmail {
          selectedConnectionId = connections.first { $0.id == defaultSendingConnectionId }?.id
        } else {
          selectedConnectionId = connections.first?.id
        }
      }
      pushStatusMessages = pushStatusMessages.filter { connectionId, _ in
        connections.contains { $0.id == connectionId }
      }
      errorMessage = nil
      for connection in connections {
        await refreshPushWatch(connection: connection)
      }
    } catch {
      try? await refreshConnections()
      errorMessage = error.localizedDescription
    }
  }

  func connect(expectedConnection: MailboxConnection? = nil) async {
    guard canConnect else { return }

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
      }
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
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
  @Bindable var viewModel: GmailProviderConnectionViewModel
  let isMailboxBusy: Bool
  @State private var connectTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Gmail")
            .font(.headline)
          if viewModel.connections.isEmpty {
            Text("Not connected")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          } else {
            Text(
              "\(viewModel.connections.count) mailbox connection\(viewModel.connections.count == 1 ? "" : "s")"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
          }
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

      ForEach(viewModel.connections) { connection in
        HStack {
          Button {
            viewModel.selectedConnectionId = connection.id
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Label(
                connection.displayName,
                systemImage: viewModel.connection?.id == connection.id
                  ? "checkmark.circle.fill" : "circle"
              )
              Text(connection.providerMailboxIdentity.value)
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(
                connection.authorizationState == .authorized
                  ? "Authorized on this device" : "Authorization required on this device"
              )
              .font(.caption)
              .foregroundStyle(
                connection.authorizationState == .authorized ? Color.secondary : Color.orange
              )
              if viewModel.defaultSendingConnectionId == connection.id {
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
                  await viewModel.connect(expectedConnection: connection)
                }
              }
            } else {
              Button("Set as Default Sending Connection") {
                Task {
                  await viewModel.setDefaultSendingConnection(connection)
                }
              }
              .disabled(viewModel.defaultSendingConnectionId == connection.id)

              Button("Remove Device Authorization", role: .destructive) {
                Task {
                  await viewModel.removeLocalAuthorization(connection)
                }
              }
            }
            Divider()
            Button("Remove Mailbox Connection Everywhere", role: .destructive) {
              Task {
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
          await viewModel.connect()
        }
      } label: {
        Label(
          viewModel.connections.isEmpty ? "Sign in with Google" : "Connect another Gmail",
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
            ? "Connecting Gmail..."
            : (viewModel.isRemoving
              ? "Removing Gmail..."
              : (viewModel.isRenewingPushWatch ? "Renewing Gmail push..." : "Loading Gmail..."))
        )
      }

      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .font(.footnote)
      }

      if let pushStatusMessage = viewModel.pushStatusMessage {
        Text(pushStatusMessage)
          .foregroundStyle(.orange)
          .font(.footnote)
      }
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
  let isConnectionBusy: Bool
  @Bindable var mailActionViewModel: GmailMailActionViewModel
  let messageReader: MailboxMessageReading
  let session: ProductAccountSessionSnapshot
  @Bindable var viewModel: GmailInboxViewModel
  @State private var searchTask: Task<Void, Never>?
  @State private var syncTask: Task<Void, Never>?
  @State private var cacheErrorMessage: String?
  @State private var composeBody = ""
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
        if connection.capabilities.canSend {
          GmailComposePanel(
            cancelReply: {
              replyToMessage = nil
              recipient = ""
              subject = ""
              composeBody = ""
            },
            messageBody: $composeBody,
            isDisabled: mailActionViewModel.isPerformingAction || isConnectionBusy,
            isReplying: replyToMessage != nil,
            recipient: $recipient,
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
                  if await viewModel.refresh(connection: connection) {
                    mailActionViewModel.clearError()
                  }
                },
                reply: { message in
                  replyToMessage = message
                  recipient = message.replyTo ?? message.from ?? ""
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
      viewModel.clear()
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
              Task { await setCategory(choice.id, thread.latestMessage) }
            } label: {
              if choice.id == thread.latestMessage.categoryId {
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
            .disabled(thread.latestMessage.rfcMessageId == nil)
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
    guard let categoryId = thread.latestMessage.categoryId else {
      return "Uncategorized"
    }
    return categoryChoices.first { $0.id == categoryId }?.name ?? "Categorized"
  }

  private func perform(_ action: ProviderMailAction) {
    Task {
      let didPerformAction = await mailActionViewModel.perform(
        action,
        for: thread.messages,
        connection: connection
      )
      if didPerformAction && !Task.isCancelled {
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
