import SwiftUI

// swiftlint:disable file_length

struct AccountView: View {
  let session: ProductAccountSession
  let snapshot: ProductAccountSessionSnapshot
  private let gmailMessageBodyService: GmailMessageReading

  @Environment(\.scenePhase) private var scenePhase

  @State private var categoryViewModel: CustomCategoryViewModel
  @State private var gmailViewModel: GmailProviderConnectionViewModel
  @State private var inboxViewModel: GmailInboxViewModel
  @State private var mailActionViewModel: GmailMailActionViewModel
  @State private var notificationRuleViewModel: NotificationRuleViewModel

  init(
    session: ProductAccountSession,
    snapshot: ProductAccountSessionSnapshot,
    categorySyncService: CustomCategorySyncing = CustomCategorySyncService(),
    gmailConnectionService: GmailProviderConnecting = GmailProviderConnectionService(),
    gmailCredentialVerifier: GmailProviderCredentialVerifying =
      GoogleGmailProviderCredentialVerifier(),
    gmailPushWatchService: GmailPushWatchRegistering = GmailPushWatchService(),
    gmailMessageMetadataService: GmailMessageMetadataSyncing = GmailMessageMetadataService(),
    gmailMessageBodyService: GmailMessageReading = GmailMessageBodyService(),
    gmailMailActionService: GmailProviderMailActing = GmailMessageMetadataService(),
    notificationAuthorization: NotificationAuthorizationRequesting = UserNotificationService(),
    notificationRuleSync: NotificationRuleSyncing = NotificationRuleSyncService()
  ) {
    self.session = session
    self.snapshot = snapshot
    self.gmailMessageBodyService = gmailMessageBodyService
    _categoryViewModel = State(
      initialValue: CustomCategoryViewModel(
        service: categorySyncService,
        session: snapshot
      )
    )
    _gmailViewModel = State(
      initialValue: GmailProviderConnectionViewModel(
        credentialVerifier: gmailCredentialVerifier,
        pushWatchService: gmailPushWatchService,
        service: gmailConnectionService,
        isSessionCurrent: { session.isCurrent($0) },
        session: snapshot
      )
    )
    _inboxViewModel = State(
      initialValue: GmailInboxViewModel(
        service: gmailMessageMetadataService,
        session: snapshot
      )
    )
    _mailActionViewModel = State(
      initialValue: GmailMailActionViewModel(
        service: gmailMailActionService,
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
          viewModel: notificationRuleViewModel
        )

        GmailProviderConnectionPanel(viewModel: gmailViewModel)

        GmailInboxPanel(
          categoryChoices: MessageCategoryChoice.available(
            customCategory: categoryViewModel.category
          ),
          connection: gmailViewModel.connection,
          isConnectionBusy: gmailViewModel.isEditingDisabled,
          mailActionViewModel: mailActionViewModel,
          messageReader: gmailMessageBodyService,
          session: snapshot,
          viewModel: inboxViewModel
        )

        SmokeView(service: ConvexBackendHealthService())

        Button("Sign Out", role: .destructive) {
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
        categoryIds: Set(
          MessageCategoryChoice.available(customCategory: categoryViewModel.category).map(\.id)
        )
      )
      await gmailViewModel.load()
      if let connection = gmailViewModel.connection {
        await inboxViewModel.load(connection: connection)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task {
        await gmailViewModel.renewPushWatch()
      }
    }
  }
}

@MainActor
@Observable
final class NotificationRuleViewModel {
  var enabledCategoryIds: Set<String> = []
  var errorMessage: String?
  var isSaving = false
  var isSyncing = false

  private let authorization: NotificationAuthorizationRequesting
  private var hasLoadedRules = false
  private var rulesUpdatedAt: Int64?
  private let service: NotificationRuleSyncing
  private let session: ProductAccountSessionSnapshot

  init(
    authorization: NotificationAuthorizationRequesting,
    service: NotificationRuleSyncing,
    session: ProductAccountSessionSnapshot
  ) {
    self.authorization = authorization
    self.service = service
    self.session = session
  }

  var canSave: Bool {
    hasLoadedRules && !isSaving && !isSyncing
  }

  var isEditingDisabled: Bool {
    isSaving || isSyncing
  }

  func isEnabled(categoryId: String) -> Bool {
    enabledCategoryIds.contains(categoryId)
  }

  func prune(categoryIds: Set<String>) {
    enabledCategoryIds.formIntersection(categoryIds)
  }

  func load(categoryIds: Set<String> = []) async {
    isSyncing = true
    defer { isSyncing = false }

    do {
      let snapshot = try await service.loadRules(session: session)
      enabledCategoryIds = Set(snapshot.rules.categoryIds)
      rulesUpdatedAt = snapshot.updatedAt
      prune(categoryIds: categoryIds)
      hasLoadedRules = true
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func save() async {
    guard canSave else { return }
    isSaving = true
    defer { isSaving = false }

    do {
      let snapshot = try await service.saveRules(
        NotificationRules(categoryIds: Array(enabledCategoryIds)),
        expectedUpdatedAt: rulesUpdatedAt,
        session: session
      )
      enabledCategoryIds = Set(snapshot.rules.categoryIds)
      rulesUpdatedAt = snapshot.updatedAt
      if !snapshot.rules.categoryIds.isEmpty, try await !authorization.requestAuthorization() {
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
}

@MainActor
@Observable
private final class GmailMailActionViewModel {
  var errorMessage: String?
  var isPerformingAction = false

  private let service: GmailProviderMailActing
  private let session: ProductAccountSessionSnapshot

  init(service: GmailProviderMailActing, session: ProductAccountSessionSnapshot) {
    self.service = service
    self.session = session
  }

  func clearError() {
    errorMessage = nil
  }

  func perform(
    _ action: GmailProviderMailAction,
    for messages: [GmailMessageMetadata],
    connection: GmailProviderConnectionStatus
  ) async -> Bool {
    guard !isPerformingAction else { return false }
    isPerformingAction = true
    defer { isPerformingAction = false }

    do {
      try await service.perform(
        action,
        messageIds: messages.map(\.providerMessageId),
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
    replyTo: GmailMessageMetadata?,
    connection: GmailProviderConnectionStatus
  ) async -> Bool {
    guard !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    guard !isPerformingAction else { return false }
    isPerformingAction = true
    defer { isPerformingAction = false }

    do {
      try await service.send(
        GmailOutgoingMessage(
          body: body,
          recipient: recipient,
          subject: subject,
          inReplyTo: replyTo?.rfcMessageId,
          threadId: replyTo?.rfcMessageId == nil ? nil : replyTo?.providerThreadId
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
final class GmailInboxViewModel {
  var errorMessage: String?
  var isAssigningCategory = false
  var isCategorizingHistorical = false
  var isLoading = false
  var isSyncing = false
  var threads: [GmailInboxThread] = []

  private var currentProviderAccountIdentifier: String?
  private let service: GmailMessageMetadataSyncing
  private let session: ProductAccountSessionSnapshot

  init(
    service: GmailMessageMetadataSyncing,
    session: ProductAccountSessionSnapshot
  ) {
    self.service = service
    self.session = session
  }

  var isRefreshDisabled: Bool {
    isCategorizingHistorical || isLoading || isSyncing
  }

  var messageCount: Int {
    threads.reduce(0) { count, thread in
      count + thread.messages.count
    }
  }

  func clear() {
    currentProviderAccountIdentifier = nil
    threads = []
    errorMessage = nil
  }

  func load(connection: GmailProviderConnectionStatus) async {
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
      guard currentProviderAccountIdentifier == connection.providerAccountIdentifier
      else {
        return
      }
      threads = result.threads
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func loadAfterConnectionChange(connection: GmailProviderConnectionStatus) async {
    if currentProviderAccountIdentifier != connection.providerAccountIdentifier {
      currentProviderAccountIdentifier = connection.providerAccountIdentifier
      threads = []
      errorMessage = nil
    }

    await load(connection: connection)
  }

  func sync(connection: GmailProviderConnectionStatus) async -> Bool {
    if currentProviderAccountIdentifier != connection.providerAccountIdentifier {
      currentProviderAccountIdentifier = connection.providerAccountIdentifier
      threads = []
      errorMessage = nil
    }

    isSyncing = true
    defer {
      isSyncing = false
    }

    do {
      let result = try await service.syncInbox(
        connection: connection,
        session: session
      )
      guard currentProviderAccountIdentifier == connection.providerAccountIdentifier
      else {
        return false
      }
      threads = result.threads
      errorMessage = nil
      return true
    } catch is CancellationError {
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func refresh(connection: GmailProviderConnectionStatus) async -> Bool {
    guard currentProviderAccountIdentifier == connection.providerAccountIdentifier else {
      return false
    }
    return await sync(connection: connection)
  }

  func categorizeHistorical(
    scope: GmailHistoricalCategorizationScope,
    connection: GmailProviderConnectionStatus
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
      guard currentProviderAccountIdentifier == connection.providerAccountIdentifier else {
        return
      }
      threads = result.threads
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      guard currentProviderAccountIdentifier == connection.providerAccountIdentifier else {
        return
      }
      errorMessage = error.localizedDescription
    }
  }

  func overrideCategory(_ categoryId: String, for message: GmailMessageMetadata) async {
    guard !isAssigningCategory else { return }
    isAssigningCategory = true
    defer { isAssigningCategory = false }

    do {
      let overriddenMessage = try await service.overrideCategory(
        categoryId,
        for: message,
        session: session
      )
      guard currentProviderAccountIdentifier == message.providerAccountIdentifier else {
        return
      }
      let messages = threads.flatMap(\.messages).map { existingMessage in
        existingMessage.stableProviderMessageId == overriddenMessage.stableProviderMessageId
          ? overriddenMessage : existingMessage
      }
      threads = GmailInboxThread.group(messages)
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

@MainActor
@Observable
private final class GmailProviderConnectionViewModel {
  var accessToken = ""
  var connection: GmailProviderConnectionStatus?
  var emailAddress = ""
  var errorMessage: String?
  var isConnecting = false
  var isLoading = false
  var providerAccountIdentifier = ""
  var pushStatusMessage: String?
  var refreshToken = ""

  private let credentialVerifier: GmailProviderCredentialVerifying
  private let isSessionCurrent: (ProductAccountSessionSnapshot) -> Bool
  private let pushWatchService: GmailPushWatchRegistering
  private let service: GmailProviderConnecting
  private let session: ProductAccountSessionSnapshot

  init(
    credentialVerifier: GmailProviderCredentialVerifying,
    pushWatchService: GmailPushWatchRegistering,
    service: GmailProviderConnecting,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool,
    session: ProductAccountSessionSnapshot
  ) {
    self.credentialVerifier = credentialVerifier
    self.pushWatchService = pushWatchService
    self.isSessionCurrent = isSessionCurrent
    self.service = service
    self.session = session
  }

  var canConnect: Bool {
    !isConnecting
      && !isLoading
      && !emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !providerAccountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !accessToken.isEmpty
      && !refreshToken.isEmpty
  }

  var isEditingDisabled: Bool {
    isConnecting || isLoading
  }

  func load() async {
    isLoading = true
    defer {
      isLoading = false
    }

    do {
      connection = try await service.loadConnection(session: session)
      errorMessage = nil
      if let connection {
        await refreshPushWatch(connection: connection)
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func connect() async {
    let trimmedEmailAddress = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedProviderAccountIdentifier = providerAccountIdentifier.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard
      !trimmedEmailAddress.isEmpty,
      !trimmedProviderAccountIdentifier.isEmpty,
      !accessToken.isEmpty,
      !refreshToken.isEmpty
    else {
      return
    }

    isConnecting = true
    defer {
      isConnecting = false
    }

    do {
      let verifiedAccount = try await credentialVerifier.verify(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expectedEmailAddress: trimmedEmailAddress,
        expectedProviderAccountIdentifier: trimmedProviderAccountIdentifier
      )
      try Task.checkCancellation()
      guard isSessionCurrent(session) else {
        return
      }
      connection = try await service.completeConnection(
        verifiedAccount: verifiedAccount,
        session: session
      )
      accessToken = ""
      refreshToken = ""
      errorMessage = nil
      if let connection {
        await refreshPushWatch(connection: connection)
      }
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func renewPushWatch() async {
    guard let connection else { return }

    await refreshPushWatch(connection: connection)
  }

  private func refreshPushWatch(connection: GmailProviderConnectionStatus) async {
    do {
      try Task.checkCancellation()
      guard isSessionCurrent(session), self.connection == connection else {
        return
      }
      _ = try await pushWatchService.registerOrRenew(
        connection: connection,
        session: session
      )
      pushStatusMessage = nil
    } catch is CancellationError {
    } catch {
      pushStatusMessage =
        "Gmail is connected, but push wakeups are unavailable: \(error.localizedDescription)"
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

  private var hasLoadedCategory = false
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
  @Bindable var viewModel: NotificationRuleViewModel

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
          Task {
            await viewModel.load()
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
    }
    .onChange(of: Set(categoryChoices.map(\.id)), initial: true) { _, categoryIds in
      viewModel.prune(categoryIds: categoryIds)
    }
  }
}

private struct GmailProviderConnectionPanel: View {
  @Bindable var viewModel: GmailProviderConnectionViewModel
  @State private var connectTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Gmail")
            .font(.headline)
          if let connection = viewModel.connection {
            Label(connection.emailAddress, systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .font(.subheadline)
            Text("Provider account: \(connection.providerAccountIdentifier)")
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else {
            Text("Not connected")
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

      VStack(alignment: .leading, spacing: 12) {
        TextField("Gmail address", text: $viewModel.emailAddress)
          .textFieldStyle(.roundedBorder)
          .disabled(viewModel.isEditingDisabled)

        TextField("Gmail account ID", text: $viewModel.providerAccountIdentifier)
          .textFieldStyle(.roundedBorder)
          .disabled(viewModel.isEditingDisabled)

        SecureField("Access token", text: $viewModel.accessToken)
          .textFieldStyle(.roundedBorder)
          .disabled(viewModel.isEditingDisabled)

        SecureField("Refresh token", text: $viewModel.refreshToken)
          .textFieldStyle(.roundedBorder)
          .disabled(viewModel.isEditingDisabled)
      }

      Button(viewModel.connection == nil ? "Connect Gmail" : "Update Gmail") {
        connectTask?.cancel()
        connectTask = Task {
          await viewModel.connect()
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!viewModel.canConnect)

      if viewModel.isLoading || viewModel.isConnecting {
        ProgressView(viewModel.isConnecting ? "Connecting Gmail..." : "Loading Gmail...")
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

private struct GmailInboxPanel: View {
  let categoryChoices: [MessageCategoryChoice]
  let connection: GmailProviderConnectionStatus?
  let isConnectionBusy: Bool
  @Bindable var mailActionViewModel: GmailMailActionViewModel
  let messageReader: GmailMessageReading
  let session: ProductAccountSessionSnapshot
  @Bindable var viewModel: GmailInboxViewModel
  @State private var syncTask: Task<Void, Never>?
  @State private var cacheErrorMessage: String?
  @State private var composeBody = ""
  @State private var recipient = ""
  @State private var replyToMessage: GmailMessageMetadata?
  @State private var selectedMessage: GmailMessageMetadata?
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

        Button("Remove Cached Bodies", role: .destructive) {
          Task {
            do {
              try messageReader.clearCachedMessageBodies(session: session)
              cacheErrorMessage = nil
            } catch {
              cacheErrorMessage = error.localizedDescription
            }
          }
        }
        .buttonStyle(.bordered)
        .disabled(isConnectionBusy || mailActionViewModel.isPerformingAction)

        if let connection {
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
                    let body = try await messageReader.loadMessageBody(
                      message: message,
                      session: session
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
    .task(id: connection?.providerAccountIdentifier) {
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
      syncTask?.cancel()
    }
    .sheet(item: $selectedMessage) { message in
      GmailMessageBodySheet(
        message: message,
        reader: messageReader,
        session: session
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
  let categorize: (GmailHistoricalCategorizationScope) -> Void
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
        !GmailHistoricalCategorizationScope.isValidDateRange(
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

  private var scope: GmailHistoricalCategorizationScope {
    let calendar = Calendar.current
    let receivedAtOrAfterDate = calendar.startOfDay(for: startDate)
    let selectedEndDate = calendar.startOfDay(for: endDate)
    let receivedBeforeDate =
      calendar.date(byAdding: .day, value: 1, to: selectedEndDate) ?? selectedEndDate
    return GmailHistoricalCategorizationScope(
      receivedAtOrAfterMilliseconds: Int64(receivedAtOrAfterDate.timeIntervalSince1970 * 1_000),
      receivedBeforeMilliseconds: Int64(receivedBeforeDate.timeIntervalSince1970 * 1_000)
    )
  }
}

private struct GmailMessageBodySheet: View {
  let message: GmailMessageMetadata
  @Environment(\.dismiss) private var dismiss
  @State private var viewModel: GmailMessageBodyViewModel

  init(
    message: GmailMessageMetadata,
    reader: GmailMessageReading,
    session: ProductAccountSessionSnapshot
  ) {
    self.message = message
    _viewModel = State(
      initialValue: GmailMessageBodyViewModel(message: message, reader: reader, session: session)
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
  var body: GmailMessageBody?
  var didRemoveCachedBody = false
  var errorMessage: String?
  var isLoading = false

  private let message: GmailMessageMetadata
  private let reader: GmailMessageReading
  private let session: ProductAccountSessionSnapshot

  init(
    message: GmailMessageMetadata,
    reader: GmailMessageReading,
    session: ProductAccountSessionSnapshot
  ) {
    self.message = message
    self.reader = reader
    self.session = session
  }

  func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      body = try await reader.loadMessageBody(message: message, session: session)
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
  let connection: GmailProviderConnectionStatus
  let categoryChoices: [MessageCategoryChoice]
  let isDisabled: Bool
  @Bindable var mailActionViewModel: GmailMailActionViewModel
  let refreshInbox: () async -> Void
  let reply: (GmailMessageMetadata) -> Void
  let setCategory: (String, GmailMessageMetadata) async -> Void
  let thread: GmailInboxThread
  let forward: (GmailMessageMetadata) async -> Void
  let open: (GmailMessageMetadata) -> Void

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
        Button("Open Message") { open(thread.latestMessage) }
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
        Button("Reply") { reply(thread.latestMessage) }
          .disabled(thread.latestMessage.rfcMessageId == nil)
        Button("Forward") {
          Task { await forward(thread.latestMessage) }
        }
        Divider()
        Button("Mark Read") { perform(.markRead) }
        Button("Mark Unread") { perform(.markUnread) }
        Button("Star") { perform(.star) }
        Button("Unstar") { perform(.unstar) }
        Button("Archive") { perform(.archive) }
        Button("Delete", role: .destructive) { perform(.delete) }
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

  private func perform(_ action: GmailProviderMailAction) {
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
