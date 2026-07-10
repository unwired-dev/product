import SwiftUI

// swiftlint:disable file_length

struct AccountView: View {
  let session: ProductAccountSession
  let snapshot: ProductAccountSessionSnapshot

  @State private var categoryViewModel: CustomCategoryViewModel
  @State private var gmailViewModel: GmailProviderConnectionViewModel
  @State private var inboxViewModel: GmailInboxViewModel
  @State private var mailActionViewModel: GmailMailActionViewModel

  init(
    session: ProductAccountSession,
    snapshot: ProductAccountSessionSnapshot,
    categorySyncService: CustomCategorySyncing = CustomCategorySyncService(),
    gmailConnectionService: GmailProviderConnecting = GmailProviderConnectionService(),
    gmailCredentialVerifier: GmailProviderCredentialVerifying =
      GoogleGmailProviderCredentialVerifier(),
    gmailMessageMetadataService: GmailMessageMetadataSyncing = GmailMessageMetadataService(),
    gmailMailActionService: GmailProviderMailActing = GmailMessageMetadataService()
  ) {
    self.session = session
    self.snapshot = snapshot
    _categoryViewModel = State(
      initialValue: CustomCategoryViewModel(
        service: categorySyncService,
        session: snapshot
      )
    )
    _gmailViewModel = State(
      initialValue: GmailProviderConnectionViewModel(
        credentialVerifier: gmailCredentialVerifier,
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

        GmailProviderConnectionPanel(viewModel: gmailViewModel)

        GmailInboxPanel(
          connection: gmailViewModel.connection,
          isConnectionBusy: gmailViewModel.isEditingDisabled,
          mailActionViewModel: mailActionViewModel,
          viewModel: inboxViewModel
        )

        SmokeView(service: ConvexBackendHealthService())

        Button("Sign Out", role: .destructive) {
          session.signOut()
        }
        .buttonStyle(.bordered)
      }
      .padding(32)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      await categoryViewModel.load()
      await gmailViewModel.load()
      if let connection = gmailViewModel.connection {
        await inboxViewModel.load(connection: connection)
      }
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
private final class GmailInboxViewModel {
  var errorMessage: String?
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
    isLoading || isSyncing
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

  func sync(connection: GmailProviderConnectionStatus) async {
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
        return
      }
      threads = result.threads
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func refresh(connection: GmailProviderConnectionStatus) async {
    guard currentProviderAccountIdentifier == connection.providerAccountIdentifier else {
      return
    }
    await sync(connection: connection)
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
  var refreshToken = ""

  private let credentialVerifier: GmailProviderCredentialVerifying
  private let isSessionCurrent: (ProductAccountSessionSnapshot) -> Bool
  private let service: GmailProviderConnecting
  private let session: ProductAccountSessionSnapshot

  init(
    credentialVerifier: GmailProviderCredentialVerifying,
    service: GmailProviderConnecting,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool,
    session: ProductAccountSessionSnapshot
  ) {
    self.credentialVerifier = credentialVerifier
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
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
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
    }
    .onDisappear {
      connectTask?.cancel()
    }
  }
}

private struct GmailInboxPanel: View {
  let connection: GmailProviderConnectionStatus?
  let isConnectionBusy: Bool
  @Bindable var mailActionViewModel: GmailMailActionViewModel
  @Bindable var viewModel: GmailInboxViewModel
  @State private var syncTask: Task<Void, Never>?
  @State private var composeBody = ""
  @State private var recipient = ""
  @State private var replyToMessage: GmailMessageMetadata?
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

        if let connection {
          Button {
            syncTask?.cancel()
            syncTask = Task {
              await viewModel.sync(connection: connection)
            }
          } label: {
            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
          }
          .buttonStyle(.bordered)
          .disabled(viewModel.isRefreshDisabled || isConnectionBusy)
        }
      }

      if let connection {
        GmailComposePanel(
          cancelReply: { replyToMessage = nil },
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

        if viewModel.threads.isEmpty && !viewModel.isLoading && !viewModel.isSyncing {
          Text("No local inbox metadata yet.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(viewModel.threads) { thread in
              GmailInboxThreadRow(
                connection: connection,
                isDisabled: mailActionViewModel.isPerformingAction
                  || viewModel.isRefreshDisabled
                  || isConnectionBusy,
                mailActionViewModel: mailActionViewModel,
                refreshInbox: { await viewModel.refresh(connection: connection) },
                reply: { message in
                  replyToMessage = message
                  recipient = message.replyTo ?? message.from ?? ""
                  subject = "Re: \(message.subject)"
                  composeBody = "\n\nOn \(message.from ?? "Unknown sender"):\n\(message.snippet)"
                },
                thread: thread,
                forward: { message in
                  replyToMessage = nil
                  recipient = ""
                  subject = "Fwd: \(message.subject)"
                  composeBody =
                    "\n\nForwarded message from \(message.from ?? "Unknown sender"):\n\(message.snippet)"
                }
              )
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
    }
    .task(id: connection?.providerAccountIdentifier) {
      syncTask?.cancel()
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
  }

  private var summaryText: String {
    guard connection != nil else {
      return "Gmail metadata stays local on this trusted device."
    }

    return "\(viewModel.threads.count) threads, \(viewModel.messageCount) messages"
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
  let isDisabled: Bool
  @Bindable var mailActionViewModel: GmailMailActionViewModel
  let refreshInbox: () async -> Void
  let reply: (GmailMessageMetadata) -> Void
  let thread: GmailInboxThread
  let forward: (GmailMessageMetadata) -> Void

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
        Button("Reply") { reply(thread.latestMessage) }
          .disabled(thread.latestMessage.rfcMessageId == nil)
        Button("Forward") { forward(thread.latestMessage) }
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
    thread.messages.allSatisfy { $0.categoryId == nil } ? "Uncategorized" : "Categorized"
  }

  private func perform(_ action: GmailProviderMailAction) {
    Task {
      _ = await mailActionViewModel.perform(
        action,
        for: thread.messages,
        connection: connection
      )
      if !Task.isCancelled {
        await refreshInbox()
      }
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
}
