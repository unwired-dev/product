import SwiftUI

// swiftlint:disable file_length

struct AccountView: View {
  let session: ProductAccountSession
  let snapshot: ProductAccountSessionSnapshot
  private let messageReader: MailboxMessageReading

  @Environment(\.scenePhase) private var scenePhase

  @State private var categoryViewModel: CustomCategoryViewModel
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var genericMailSetupViewModel: GenericMailSetupViewModel
  @State private var gmailViewModel: GmailProviderConnectionViewModel
  @State private var inboxViewModel: GmailInboxViewModel
  @State private var inboxLoadTask: Task<Void, Never>?
  @State private var mailActionViewModel: GmailMailActionViewModel
  @State private var mailShellSelection = MailShellSelectionModel()
  @State private var notificationRuleViewModel: NotificationRuleViewModel
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
  @State private var showsAccountSettings = false

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
        bodyPrefetcher: mailboxConnection,
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
    NavigationSplitView(
      columnVisibility: $columnVisibility,
      preferredCompactColumn: $preferredCompactColumn
    ) {
      MailShellSidebar(
        connections: gmailViewModel.connections,
        errorMessage: gmailViewModel.errorMessage,
        isLoading: gmailViewModel.isLoading,
        selectedMailbox: selectedMailboxBinding,
        showAccountSettings: { showsAccountSettings = true }
      )
    } content: {
      MailShellThreadList(
        connection: selectedConnection,
        isConnectionBusy: gmailViewModel.isEditingDisabled,
        items: mailShellSelection.threadListItems(connections: gmailViewModel.connections),
        mailboxSelection: mailShellSelection.selectedMailbox,
        selectedThreadId: selectedThreadBinding,
        viewModel: inboxViewModel
      )
    } detail: {
      MailShellConversationReader(
        connections: gmailViewModel.connections,
        inboxViewModel: inboxViewModel,
        isConnectionBusy: gmailViewModel.isEditingDisabled,
        mailActionViewModel: mailActionViewModel,
        messageReader: messageReader,
        selection: mailShellSelection
      )
    }
    .navigationSplitViewStyle(.balanced)
    .sheet(isPresented: $showsAccountSettings) {
      accountSettings
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
      await gmailViewModel.load()
      await genericMailSetupViewModel.loadSyncedDefinitions()
      if mailShellSelection.selectedMailbox == nil {
        if let connection = gmailViewModel.connection {
          mailShellSelection.selectMailbox(connectionId: connection.id)
        }
        if let connection = gmailViewModel.connection,
          connection.authorizationState == .authorized
        {
          await inboxViewModel.loadAfterConnectionChange(connection: connection)
        }
      } else if mailShellSelection.selectedMailbox == .unifiedInbox {
        loadUnifiedInbox()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task {
        await gmailViewModel.load()
        await genericMailSetupViewModel.loadSyncedDefinitions()
        if mailShellSelection.selectedMailbox == .unifiedInbox {
          loadUnifiedInbox()
        }
      }
    }
    .onChange(of: gmailViewModel.connection?.id) { _, _ in
      guard mailShellSelection.selectedMailbox != .unifiedInbox else { return }
      guard let connection = gmailViewModel.connection else {
        mailShellSelection.clearSelection()
        inboxViewModel.clear()
        return
      }
      selectConnection(connection)
    }
    .onChange(of: gmailViewModel.connections) { _, _ in
      guard mailShellSelection.selectedMailbox == .unifiedInbox else { return }
      loadUnifiedInbox()
    }
    .onChange(of: gmailViewModel.connection?.authorizationState) { _, authorizationState in
      guard mailShellSelection.selectedMailbox != .unifiedInbox else { return }
      guard
        let connection = gmailViewModel.connection,
        authorizationState == .authorized
      else {
        inboxViewModel.clear()
        return
      }
      loadInbox(for: connection)
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
    .onChange(of: inboxViewModel.threads) { _, threads in
      if mailShellSelection.selectedMailbox == .unifiedInbox {
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
      preferredCompactColumn = mailShellSelection.preferredCompactColumn
    }
  }

  private var selectedConnection: MailboxConnection? {
    guard let connectionId = mailShellSelection.selectedConnectionId else { return nil }
    return gmailViewModel.connections.first { $0.id == connectionId }
  }

  private var selectedThreadBinding: Binding<MailboxThreadIdentity?> {
    Binding(
      get: { mailShellSelection.selectedThreadId },
      set: { threadId in
        guard let threadId else {
          mailShellSelection.clearThreadSelection()
          return
        }
        mailShellSelection.selectThread(threadId)
      }
    )
  }

  private func loadInbox(for connection: MailboxConnection) {
    inboxLoadTask?.cancel()
    inboxLoadTask = Task {
      await inboxViewModel.loadAfterConnectionChange(connection: connection)
    }
  }

  private func loadUnifiedInbox() {
    inboxLoadTask?.cancel()
    let connections = gmailViewModel.connections
    inboxLoadTask = Task {
      await inboxViewModel.loadUnifiedInbox(connections: connections)
    }
  }

  private func selectConnection(_ connection: MailboxConnection) {
    gmailViewModel.selectedConnectionId = connection.id
    inboxViewModel.clear()
    mailShellSelection.selectMailbox(connectionId: connection.id)
    guard connection.authorizationState == .authorized else { return }
    loadInbox(for: connection)
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
        if mailbox == .unifiedInbox {
          inboxViewModel.clear()
          mailShellSelection.replaceUnifiedThreads([], connectionIds: [])
          mailShellSelection.selectUnifiedInbox()
          loadUnifiedInbox()
          return
        }
        guard case .connection(let connectionId) = mailbox else { return }
        guard
          gmailViewModel.connections.contains(where: { $0.id == connectionId })
        else { return }
        let isCurrentConnection = gmailViewModel.selectedConnectionId == connectionId
        if !isCurrentConnection {
          mailShellSelection.selectMailbox(connectionId: connectionId)
        }
        gmailViewModel.selectedConnectionId = connectionId
        guard isCurrentConnection else { return }
        guard let connection = gmailViewModel.connection,
          connection.id == connectionId
        else { return }
        selectConnection(connection)
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
            selectMailbox: selectConnection
          )

          GenericMailSetupPanel(viewModel: genericMailSetupViewModel)

          if mailShellSelection.selectedMailbox != .unifiedInbox {
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
          }

          SmokeView(service: ConvexBackendHealthService())

          Button("Sign Out", role: .destructive) {
            genericMailSetupViewModel.invalidate()
            Task {
              await inboxViewModel.prepareForSignOut()
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

enum MailShellMailboxSelection: Hashable {
  case unifiedInbox
  case connection(MailboxConnectionId)
}

struct MailShellThreadListItem: Equatable, Identifiable {
  let sourceConnectionDisplayName: String
  let thread: MailboxThread

  var id: MailboxThreadIdentity {
    thread.id
  }
}

@MainActor
@Observable
final class MailShellSelectionModel {
  private(set) var expandedMessageIds: Set<StableProviderMessageIdentity> = []
  private(set) var selectedMailbox: MailShellMailboxSelection?
  private(set) var selectedThreadId: MailboxThreadIdentity?
  private var threadsByConnection: [MailboxConnectionId: [MailboxThread]] = [:]

  var selectedConnectionId: MailboxConnectionId? {
    guard case .connection(let connectionId) = selectedMailbox else { return nil }
    return connectionId
  }

  var threads: [MailboxThread] {
    switch selectedMailbox {
    case .unifiedInbox:
      return threadsByConnection.values.flatMap { $0 }.sorted(by: Self.ordersBefore)
    case .connection(let connectionId):
      return threadsByConnection[connectionId] ?? []
    case nil:
      return []
    }
  }

  var navigationLevel: MailShellNavigationLevel {
    if selectedThreadId != nil {
      return .conversation
    }
    if selectedMailbox != nil {
      return .threadList
    }
    return .mailboxList
  }

  var preferredCompactColumn: NavigationSplitViewColumn {
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
    threads.first { $0.id == selectedThreadId }
  }

  func clearSelection() {
    selectedMailbox = nil
    selectedThreadId = nil
    threadsByConnection = [:]
    expandedMessageIds = []
  }

  func clearThreadSelection() {
    selectedThreadId = nil
    expandedMessageIds = []
  }

  func selectMailbox(connectionId: MailboxConnectionId) {
    let mailbox = MailShellMailboxSelection.connection(connectionId)
    guard selectedMailbox != mailbox else { return }
    selectedMailbox = mailbox
    selectedThreadId = nil
    expandedMessageIds = []
  }

  func selectUnifiedInbox() {
    guard selectedMailbox != .unifiedInbox else { return }
    selectedMailbox = .unifiedInbox
    selectedThreadId = nil
    expandedMessageIds = []
  }

  func selectThread(_ threadId: MailboxThreadIdentity) {
    guard let thread = threads.first(where: { $0.id == threadId }) else { return }
    selectedThreadId = threadId
    expandedMessageIds = [thread.latestMessage.id]
  }

  func updateThreads(
    _ threads: [MailboxThread],
    for connectionId: MailboxConnectionId
  ) {
    threadsByConnection[connectionId] = threads.filter { $0.id.connectionId == connectionId }
    guard selectedMailbox == .unifiedInbox || selectedConnectionId == connectionId else { return }
    reconcileSelectedThread()
  }

  func replaceUnifiedThreads(
    _ threads: [MailboxThread],
    connectionIds: Set<MailboxConnectionId>
  ) {
    threadsByConnection = Dictionary(
      grouping: threads.filter { connectionIds.contains($0.id.connectionId) },
      by: { $0.id.connectionId }
    )
    reconcileSelectedThread()
  }

  private func reconcileSelectedThread() {
    guard let selectedThreadId else { return }
    guard let selectedThread = self.threads.first(where: { $0.id == selectedThreadId }) else {
      self.selectedThreadId = nil
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
  let connectionId: MailboxConnectionId
  let id = UUID()
  var recipient: String
  let replyToMessage: MailboxMessageMetadata?
  let sourceMessage: MailboxMessageMetadata
  var subject: String

  var sourceMailboxIdentity: StableProviderMailboxIdentity {
    sourceMessage.connectionId.providerMailboxIdentity
  }

  var sourceThreadId: MailboxThreadIdentity {
    sourceMessage.threadIdentity
  }

  var forwardSourceMessage: MailboxMessageMetadata? {
    replyToMessage == nil ? sourceMessage : nil
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
  let connections: [MailboxConnection]
  let errorMessage: String?
  let isLoading: Bool
  @Binding var selectedMailbox: MailShellMailboxSelection?
  let showAccountSettings: () -> Void

  var body: some View {
    List(selection: $selectedMailbox) {
      Section("Mailboxes") {
        NavigationLink(value: MailShellMailboxSelection.unifiedInbox) {
          Label("Unified Inbox", systemImage: "tray.2")
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
            NavigationLink(value: MailShellMailboxSelection.connection(connection.id)) {
              Label {
                VStack(alignment: .leading, spacing: 2) {
                  Text("Inbox")
                  Text(connection.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  if connection.authorizationState == .required {
                    Text("Authorization required")
                      .font(.caption2)
                      .foregroundStyle(.orange)
                  }
                }
              } icon: {
                Image(
                  systemName: connection.authorizationState == .authorized
                    ? "tray.full" : "lock.trianglebadge.exclamationmark"
                )
              }
            }
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
  }
}

private struct MailShellThreadList: View {
  let connection: MailboxConnection?
  let isConnectionBusy: Bool
  let items: [MailShellThreadListItem]
  let mailboxSelection: MailShellMailboxSelection?
  @Binding var selectedThreadId: MailboxThreadIdentity?
  @Bindable var viewModel: GmailInboxViewModel

  var body: some View {
    Group {
      if mailboxSelection != nil {
        if let connection, connection.authorizationState == .required {
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
          List(selection: $selectedThreadId) {
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
                    showsSourceConnection: mailboxSelection == .unifiedInbox
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
    .navigationTitle(
      mailboxSelection == .unifiedInbox ? "Unified Inbox" : connection?.displayName ?? "Inbox"
    )
    .toolbar {
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
      if viewModel.isLoading || viewModel.isSyncing {
        ProgressView(viewModel.isSyncing ? "Syncing mailbox…" : "Loading inbox…")
          .padding()
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
    }
  }

  private var emptyInboxDescription: String {
    if mailboxSelection == .unifiedInbox {
      return "Authorized Mailbox Connections have no locally observed Inbox threads yet."
    }
    return "This Mailbox Connection has no locally observed Inbox threads yet."
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

private struct MailShellConversationReader: View {
  let connections: [MailboxConnection]
  @Bindable var inboxViewModel: GmailInboxViewModel
  let isConnectionBusy: Bool
  @Bindable var mailActionViewModel: GmailMailActionViewModel
  let messageReader: MailboxMessageReading
  @Bindable var selection: MailShellSelectionModel

  @State private var compositionDraft: MailShellCompositionDraft?
  @State private var readerErrorMessage: String?

  var body: some View {
    Group {
      if let thread = selection.selectedThread,
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
                loadBody: {
                  try await inboxViewModel.loadMessageBody(message, using: messageReader)
                },
                message: message,
                reply: { compositionDraft = .reply(to: message) },
                forward: { await prepareForward(message) },
                toggleExpansion: {
                  selection.toggleMessageExpansion(message, in: thread)
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
    .sheet(item: $compositionDraft) { draft in
      MailShellComposer(
        draft: draft,
        isSending: mailActionViewModel.isPerformingAction,
        send: send
      )
    }
    .alert("Mail action failed", isPresented: readerErrorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(readerErrorMessage ?? "The mail action could not be completed.")
    }
    .onChange(of: selection.selectedThreadId) { _, _ in
      compositionDraft = nil
      readerErrorMessage = nil
      mailActionViewModel.clearError()
    }
  }

  private var readerErrorBinding: Binding<Bool> {
    Binding(
      get: { readerErrorMessage != nil },
      set: { isPresented in
        if !isPresented { readerErrorMessage = nil }
      }
    )
  }

  private func connection(for thread: MailboxThread) -> MailboxConnection? {
    connections.first { $0.id == thread.id.connectionId }
  }

  @ViewBuilder
  private func providerActionMenu(
    thread: MailboxThread,
    connection: MailboxConnection
  ) -> some View {
    if !connection.capabilities.providerActions.isEmpty {
      Menu {
        if connection.capabilities.supports(.markRead) {
          Button("Mark Read") { perform(.markRead, thread: thread, connection: connection) }
        }
        if connection.capabilities.supports(.markUnread) {
          Button("Mark Unread") { perform(.markUnread, thread: thread, connection: connection) }
        }
        if connection.capabilities.supports(.archive) {
          Button("Archive") { perform(.archive, thread: thread, connection: connection) }
        }
        if connection.capabilities.supports(.delete) {
          Button("Delete", role: .destructive) {
            perform(.delete, thread: thread, connection: connection)
          }
        }
        if connection.capabilities.supports(.star) {
          Button("Star") { perform(.star, thread: thread, connection: connection) }
        }
        if connection.capabilities.supports(.unstar) {
          Button("Unstar") { perform(.unstar, thread: thread, connection: connection) }
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

  private func perform(
    _ action: ProviderMailAction,
    thread: MailboxThread,
    connection: MailboxConnection
  ) {
    Task {
      let didPerform = await mailActionViewModel.perform(
        action,
        for: thread.inboxMessages,
        connection: connection
      )
      if didPerform {
        _ = await inboxViewModel.refresh(connection: connection)
      } else if let errorMessage = mailActionViewModel.errorMessage {
        readerErrorMessage = errorMessage
      }
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
      let connection = connections.first(where: { $0.id == draft.connectionId }),
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
}

private struct MailShellConversationMessage: View {
  let canForward: Bool
  let canReply: Bool
  let isExpanded: Bool
  let isLatest: Bool
  let loadBody: () async throws -> MailboxMessageBody
  let message: MailboxMessageMetadata
  let reply: () -> Void
  let forward: () async -> Void
  let toggleExpansion: () -> Void

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
          if canReply {
            Button("Reply", action: reply)
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
  @State private var draft: MailShellCompositionDraft
  let isSending: Bool
  let send: (MailShellCompositionDraft) async -> Bool
  @Environment(\.dismiss) private var dismiss

  init(
    draft: MailShellCompositionDraft,
    isSending: Bool,
    send: @escaping (MailShellCompositionDraft) async -> Bool
  ) {
    _draft = State(initialValue: draft)
    self.isSending = isSending
    self.send = send
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("To", text: $draft.recipient)
          .textInputAutocapitalization(.never)
        TextField("Subject", text: $draft.subject)
        TextField("Message", text: $draft.body, axis: .vertical)
          .lineLimit(8...24)
      }
      .navigationTitle(draft.replyToMessage == nil ? "Forward" : "Reply")
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
            isSending || draft.recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
        }
      }
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
final class GmailMailActionViewModel {
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
  private var unifiedConnectionIds: Set<MailboxConnectionId> = []
  private var unifiedLoadId: UUID?
  private let searchService: MailboxMessageSearching
  private let service: MailboxMetadataSyncing
  private let session: ProductAccountSessionSnapshot

  init(
    bodyPrefetcher: MailboxMessageBodyPrefetching? = nil,
    service: MailboxMetadataSyncing,
    searchService: MailboxMessageSearching,
    session: ProductAccountSessionSnapshot
  ) {
    self.bodyPrefetcher = bodyPrefetcher
    self.searchService = searchService
    self.service = service
    self.session = session
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
    cancelBackfill()
    currentConnectionId = nil
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
        loadId: loadId,
        connectionIds: connectionIds,
        threadsByConnection: &loadedThreadsByConnection
      )
    else { return }
    guard
      let syncResult = await syncUnifiedInboxes(
        for: authorizedConnections,
        loadId: loadId,
        connectionIds: connectionIds,
        threadsByConnection: &loadedThreadsByConnection
      )
    else { return }
    guard
      let backfillErrors = await continueUnifiedInboxBackfill(
        for: syncResult.connectionsNeedingBackfill,
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
    loadId: UUID,
    connectionIds: Set<MailboxConnectionId>,
    threadsByConnection: inout [MailboxConnectionId: [MailboxThread]]
  ) async -> [String]? {
    var errors: [String] = []
    for connection in connections {
      do {
        let result = try await service.loadInbox(connection: connection, session: session)
        guard
          applyUnifiedInboxResult(
            result.threads,
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
    loadId: UUID,
    connectionIds: Set<MailboxConnectionId>,
    threadsByConnection: inout [MailboxConnectionId: [MailboxThread]]
  ) async throws -> Bool? {
    let syncedResult = try await service.syncInbox(connection: connection, session: session)
    guard
      applyUnifiedInboxResult(
        syncedResult.threads,
        for: connection.id,
        loadId: loadId,
        connectionIds: connectionIds,
        threadsByConnection: &threadsByConnection
      )
    else { return nil }
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
    loadId: UUID,
    connectionIds: Set<MailboxConnectionId>,
    threadsByConnection: inout [MailboxConnectionId: [MailboxThread]]
  ) async -> [String]? {
    var errors: [String] = []
    for connection in connections {
      do {
        let backfillResult = try await service.continueHistoricalBackfill(
          connection: connection,
          session: session
        )
        guard
          applyUnifiedInboxResult(
            backfillResult.threads,
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
      guard !hasSignedOut, currentConnectionId == connection.id
      else {
        return
      }
      threads = result.threads
      errorMessage = nil
      if result.hasInitialMailboxAvailability && !result.historicalMetadataBackfillIsComplete {
        startBodyPrefetch(connection: connection)
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
    _ updatedThreads: [MailboxThread],
    for connectionId: MailboxConnectionId,
    loadId: UUID,
    connectionIds: Set<MailboxConnectionId>,
    threadsByConnection: inout [MailboxConnectionId: [MailboxThread]]
  ) -> Bool {
    guard !Task.isCancelled, unifiedLoadId == loadId, unifiedConnectionIds == connectionIds else {
      return false
    }
    updateUnifiedThreads(updatedThreads, for: connectionId, in: &threadsByConnection)
    return true
  }

  func loadAfterConnectionChange(connection: MailboxConnection) async {
    if currentConnectionId != connection.id {
      cancelBackfill()
      currentConnectionId = connection.id
      unifiedConnectionIds = []
      unifiedLoadId = nil
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
      let result = try await service.syncInbox(
        connection: connection,
        session: session
      )
      guard currentConnectionId == connection.id
      else {
        return false
      }
      threads = result.threads
      errorMessage = nil
      if result.hasInitialMailboxAvailability {
        startBodyPrefetch(connection: connection)
      }
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
          !hasSignedOut,
          currentConnectionId == connection.id
        else { return }
        threads = backfill.threads
        startBodyPrefetch(connection: connection)
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, backfillTaskId == taskId else { return }
        errorMessage = error.localizedDescription
      }
    }
  }

  private func startBodyPrefetch(connection: MailboxConnection) {
    guard let bodyPrefetcher else { return }
    bodyPrefetchTask?.cancel()
    bodyPrefetchTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await bodyPrefetcher.prefetchMessageBodies(
          connection: connection,
          pinnedMessageIds: [],
          referenceDate: Date(),
          session: self.session
        )
      } catch {
        // Prefetch is best effort and must not block cached mailbox use.
      }
    }
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
      let result = try await service.syncInbox(connection: connection, session: session)
      guard unifiedConnectionIds.contains(connection.id) else { return false }

      let otherMessages =
        threads
        .filter { $0.id.connectionId != connection.id }
        .flatMap(\.messages)

      threads = MailboxThread.group(otherMessages + result.threads.flatMap(\.messages))
      errorMessage = nil
      if !result.historicalMetadataBackfillIsComplete {
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

  private func cancelBackfill() {
    backfillTask?.cancel()
    backfillTask = nil
    backfillTaskId = nil
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
        let backfill = try await service.continueHistoricalBackfill(
          connection: connection,
          session: session
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
  let cancelBodyPrefetch: () async -> Void
  @Bindable var viewModel: GmailProviderConnectionViewModel
  let isMailboxBusy: Bool
  let selectMailbox: (MailboxConnection) -> Void
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
            selectMailbox(connection)
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
        for: thread.inboxMessages,
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
