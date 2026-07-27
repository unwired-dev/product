import SwiftUI

@MainActor
@Observable
final class EWSSetupViewModel {
  var authorizationMethod = MailAuthorizationMethod.password
  private(set) var connections: [MailboxConnection] = []
  var credential = ""
  private(set) var defaultSendingConnectionId: MailboxConnectionId?
  var emailAddress = ""
  var endpoint = ""
  var errorMessage: String?
  var isWorking = false
  var username = ""

  private let adapter: EWSMailboxConnectionAdapter
  private let authorizationStore: EWSAuthorizationPersisting
  private let definitionSyncService: MailboxConnectionDefinitionSyncing
  private var definitionsByConnectionId: [MailboxConnectionId: EWSConnectionDefinition] = [:]
  private let isSessionCurrent: (ProductAccountSessionSnapshot) -> Bool
  private let service: EWSSetupService
  private let session: ProductAccountSessionSnapshot

  init(
    adapter: EWSMailboxConnectionAdapter = EWSMailboxConnectionAdapter(),
    authorizationStore: EWSAuthorizationPersisting = KeychainEWSAuthorizationStore(),
    definitionSyncService: MailboxConnectionDefinitionSyncing =
      MailboxConnectionSyncService(),
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool,
    service: EWSSetupService = EWSSetupService(),
    session: ProductAccountSessionSnapshot
  ) {
    self.adapter = adapter
    self.authorizationStore = authorizationStore
    self.definitionSyncService = definitionSyncService
    self.isSessionCurrent = isSessionCurrent
    self.service = service
    self.session = session
  }

  func load() async {
    guard !isWorking, isSessionCurrent(session) else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      let snapshot = try await definitionSyncService.loadSnapshot(session: session)
      definitionsByConnectionId = Dictionary(
        snapshot.connections.compactMap {
          $0.ewsDefinition.map { ($0.connectionId, $0) }
        },
        uniquingKeysWith: { _, latest in latest }
      )
      defaultSendingConnectionId = snapshot.defaultSendingConnectionId
      connections = try await adapter.loadConnections(session: session)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func connect() async -> MailboxConnection? {
    guard !isWorking, isSessionCurrent(session) else { return nil }
    isWorking = true
    defer { isWorking = false }
    do {
      let connection = try await service.connect(
        authorizationMethod: authorizationMethod,
        credential: credential,
        emailAddress: emailAddress,
        endpoint: endpoint,
        username: username,
        session: session,
        isSessionCurrent: isSessionCurrent
      )
      credential = ""
      try await reloadAfterMutation()
      errorMessage = nil
      return connection
    } catch is CancellationError {
      return nil
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func select(_ connection: MailboxConnection) async {
    credential = ""
    let authorization = try? authorizationStore.load(
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
    guard let definition = authorization?.definition ?? definitionsByConnectionId[connection.id]
    else { return }
    authorizationMethod = definition.authorizationMethod
    emailAddress = definition.emailAddress
    endpoint = definition.endpoint.absoluteString
    username = definition.username
  }

  func removeLocal(_ connection: MailboxConnection) async {
    await remove(connection) {
      try await adapter.clearLocalConnection(connection, session: session)
    }
  }

  func removeEverywhere(_ connection: MailboxConnection) async {
    await remove(connection) {
      try await adapter.removeMailboxConnectionEverywhere(connection, session: session)
    }
  }

  func setDefaultSendingConnection(_ connection: MailboxConnection) async -> Bool {
    guard !isWorking, isSessionCurrent(session) else { return false }
    isWorking = true
    defer { isWorking = false }
    do {
      try await adapter.setDefaultSendingConnection(connection, session: session)
      defaultSendingConnectionId = connection.id
      errorMessage = nil
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func remove(
    _ connection: MailboxConnection,
    operation: () async throws -> Void
  ) async {
    guard !isWorking, isSessionCurrent(session) else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      try await operation()
      try await reloadAfterMutation()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func reloadAfterMutation() async throws {
    let snapshot = try await definitionSyncService.loadSnapshot(session: session)
    let connections = try await adapter.loadConnections(session: session)
    definitionsByConnectionId = Dictionary(
      snapshot.connections.compactMap {
        $0.ewsDefinition.map { ($0.connectionId, $0) }
      },
      uniquingKeysWith: { _, latest in latest }
    )
    defaultSendingConnectionId = snapshot.defaultSendingConnectionId
    self.connections = connections
  }
}

struct EWSSetupPanel: View {
  @Bindable var viewModel: EWSSetupViewModel
  var cancelBodyPrefetch: () async -> Void = {}
  var connectionDidConnect: (MailboxConnection) -> Void = { _ in }
  var connectionsDidChange: () -> Void = {}
  var isMailboxBusy = false
  @State private var task: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("On-Premises Exchange")
          .font(.headline)
        Text(
          "Connect an organization-hosted EWS endpoint. Microsoft 365 mailboxes use "
            + "Microsoft Graph. Credentials remain on this device."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }

      ForEach(viewModel.connections, id: \.id) { connection in
        HStack {
          Button {
            Task { await viewModel.select(connection) }
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(connection.displayName)
              Text(
                connection.authorizationState == .authorized
                  ? "Authorized on this device" : "Authorization required on this device"
              )
              .font(.caption)
              .foregroundStyle(
                connection.authorizationState == .authorized ? Color.secondary : Color.orange
              )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
          Menu("Manage") {
            if connection.authorizationState == .authorized {
              Button("Set as Default Sending Connection") {
                Task {
                  if await viewModel.setDefaultSendingConnection(connection) {
                    connectionsDidChange()
                  }
                }
              }
              .disabled(viewModel.defaultSendingConnectionId == connection.id)
              Button("Remove Device Authorization", role: .destructive) {
                Task {
                  await cancelBodyPrefetch()
                  await viewModel.removeLocal(connection)
                  connectionsDidChange()
                }
              }
            }
            Button("Remove Mailbox Connection Everywhere", role: .destructive) {
              Task {
                await cancelBodyPrefetch()
                await viewModel.removeEverywhere(connection)
                connectionsDidChange()
              }
            }
          }
          .disabled(viewModel.isWorking || isMailboxBusy)
        }
      }

      TextField("Mailbox email address", text: $viewModel.emailAddress)
        .textContentType(.emailAddress)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      TextField("EWS endpoint URL", text: $viewModel.endpoint)
        .textContentType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      TextField("Username (for example, DOMAIN\\user)", text: $viewModel.username)
        .textContentType(.username)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      Picker("Authorization", selection: $viewModel.authorizationMethod) {
        ForEach(MailAuthorizationMethod.allCases) { method in
          Text(method.displayName).tag(method)
        }
      }
      SecureField(viewModel.authorizationMethod.displayName, text: $viewModel.credential)
        .textContentType(.password)

      Button {
        task?.cancel()
        task = Task {
          if let connection = await viewModel.connect() {
            connectionDidConnect(connection)
            connectionsDidChange()
          }
        }
      } label: {
        Label("Verify and Save on This Device", systemImage: "lock.shield")
      }
      .buttonStyle(.borderedProminent)
      .disabled(viewModel.isWorking)

      if viewModel.isWorking {
        ProgressView("Contacting Exchange securely...")
      }
      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    }
    .task { await viewModel.load() }
    .onDisappear { task?.cancel() }
  }
}
