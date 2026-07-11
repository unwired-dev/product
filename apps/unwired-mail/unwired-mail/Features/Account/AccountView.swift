import SwiftUI

// swiftlint:disable file_length

struct AccountView: View {
  let session: ProductAccountSession
  let snapshot: ProductAccountSessionSnapshot
  private let gmailMessageBodyService: GmailMessageReading

  @State private var categoryViewModel: CustomCategoryViewModel
  @State private var gmailViewModel: GmailProviderConnectionViewModel
  @State private var inboxViewModel: GmailInboxViewModel

  init(
    session: ProductAccountSession,
    snapshot: ProductAccountSessionSnapshot,
    categorySyncService: CustomCategorySyncing = CustomCategorySyncService(),
    gmailConnectionService: GmailProviderConnecting = GmailProviderConnectionService(),
    gmailCredentialVerifier: GmailProviderCredentialVerifying =
      GoogleGmailProviderCredentialVerifier(),
    gmailMessageMetadataService: GmailMessageMetadataSyncing = GmailMessageMetadataService(),
    gmailMessageBodyService: GmailMessageReading = GmailMessageBodyService()
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
          messageReader: gmailMessageBodyService,
          session: snapshot,
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
  let messageReader: GmailMessageReading
  let session: ProductAccountSessionSnapshot
  @Bindable var viewModel: GmailInboxViewModel
  @State private var syncTask: Task<Void, Never>?
  @State private var selectedMessage: GmailMessageMetadata?
  @State private var cacheErrorMessage: String?

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
        .disabled(isConnectionBusy)

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

      if connection == nil {
        Text("Connect Gmail to sync inbox metadata.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else if viewModel.threads.isEmpty && !viewModel.isLoading && !viewModel.isSyncing {
        Text("No local inbox metadata yet.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(viewModel.threads) { thread in
            Button {
              selectedMessage = thread.latestMessage
            } label: {
              GmailInboxThreadRow(thread: thread)
            }
            .buttonStyle(.plain)
            ForEach(thread.messages.dropFirst()) { message in
              Button {
                selectedMessage = message
              } label: {
                Text(message.subject)
                  .font(.footnote)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .buttonStyle(.plain)
            }
            Divider()
          }
        }
      }

      if viewModel.isLoading || viewModel.isSyncing {
        ProgressView(viewModel.isSyncing ? "Syncing Gmail metadata..." : "Loading inbox...")
      }

      if let errorMessage = viewModel.errorMessage {
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

private struct GmailInboxThreadRow: View {
  let thread: GmailInboxThread

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
    }
  }

  private var categoryState: String {
    thread.messages.allSatisfy { $0.categoryId == nil } ? "Uncategorized" : "Categorized"
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
