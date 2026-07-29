import SwiftUI

// swiftlint:disable file_length

typealias GenericMailLocalDataClearing = (
  GenericMailConnectionDefinition,
  ProductAccountSessionSnapshot
) async throws -> Bool

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class GenericMailSetupViewModel {
  var authorizationMethod = MailAuthorizationMethod.password
  var authorizedSyncedConnectionIds: Set<MailboxConnectionId> = []
  var connectedDefinition: GenericMailConnectionDefinition?
  var credential = ""
  var defaultSendingConnectionId: MailboxConnectionId?
  private var discoveredIncomingEndpoints: [GenericMailEndpoint] = []
  var discoverySource: String?
  var emailAddress = ""
  var errorMessage: String?
  var incomingHostname = ""
  var incomingPort = "993"
  var incomingProtocol = GenericMailProtocol.imap
  var incomingSecurity = MailTransportSecurity.implicitTLS
  var isConnecting = false
  var isLoadingSyncedDefinitions = false
  private var hasLoadedSyncedDefinitions = false
  private var locallyLoadedConnectionId: MailboxConnectionId?
  private var removalObservation: MailboxConnectionRemovalObservation?
  var outgoingHostname = ""
  var outgoingPort = "465"
  var outgoingSecurity = MailTransportSecurity.implicitTLS
  var roleMappings = Dictionary(
    uniqueKeysWithValues: CanonicalMailboxRole.allCases.map { ($0, "") }
  )
  var rolesRequiringMapping: [CanonicalMailboxRole] = []
  private var selectedSyncedConnectionId: MailboxConnectionId?
  var syncedDefinitions: [GenericMailConnectionDefinition] = []
  var username = ""

  var connectionReloadKey: [String] {
    [defaultSendingConnectionId?.rawValue ?? ""]
      + syncedDefinitions.map { definition in
        [
          definition.authorizationMethod.rawValue,
          definition.emailAddress,
          definition.incomingEndpoint.mailProtocol.rawValue,
          definition.incomingEndpoint.hostname,
          String(definition.incomingEndpoint.port),
          definition.incomingEndpoint.security.rawValue,
          definition.outgoingEndpoint.mailProtocol.rawValue,
          definition.outgoingEndpoint.hostname,
          String(definition.outgoingEndpoint.port),
          definition.outgoingEndpoint.security.rawValue,
          definition.username,
          definition.roleMappings
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }
            .joined(separator: "\0"),
        ].joined(separator: "\0")
      }
      + authorizedSyncedConnectionIds.map(\.rawValue).sorted()
  }

  private let productAccountId: ProductAccountId
  private let clearLocalData: GenericMailLocalDataClearing
  private let isSessionCurrent: () -> Bool
  private var isValid = true
  private var roleMappingEmailAddress: String?
  private var roleMappingEndpoint: GenericMailEndpoint?
  private let service: GenericMailSetupService
  private let syncSession: ProductAccountSessionSnapshot?

  init(
    productAccountId: ProductAccountId,
    clearLocalData: @escaping GenericMailLocalDataClearing = { _, _ in false },
    isSessionCurrent: @escaping () -> Bool,
    service: GenericMailSetupService = GenericMailSetupService(),
    syncSession: ProductAccountSessionSnapshot? = nil
  ) {
    self.productAccountId = productAccountId
    self.clearLocalData = clearLocalData
    self.isSessionCurrent = isSessionCurrent
    self.service = service
    self.syncSession = syncSession
  }

  var credentialLabel: String { authorizationMethod.displayName }

  var isConfirmingRecreation: Bool { removalObservation != nil }

  var showsMailboxRoles: Bool {
    incomingProtocol == .imap
      && roleMappingEmailAddress == normalizedEmailAddress
      && !rolesRequiringMapping.isEmpty
  }

  func discover() {
    let trimmedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    connectedDefinition = nil
    locallyLoadedConnectionId = nil
    removalObservation = nil
    selectedSyncedConnectionId = nil
    credential = ""
    resetRoleMappingState()
    username = trimmedEmail
    guard let result = service.discover(emailAddress: trimmedEmail) else {
      discoveredIncomingEndpoints = []
      authorizationMethod = .password
      incomingHostname = ""
      incomingPort = ""
      incomingProtocol = .imap
      incomingSecurity = .implicitTLS
      outgoingHostname = ""
      outgoingPort = ""
      outgoingSecurity = .implicitTLS
      discoverySource = "No reviewed provider entry found. Enter server settings manually."
      errorMessage = nil
      return
    }

    discoveredIncomingEndpoints = result.incomingEndpoints
    if let incoming = discoveredIncomingEndpoints.first {
      incomingProtocol = incoming.mailProtocol
      incomingHostname = incoming.hostname
      incomingPort = String(incoming.port)
      incomingSecurity = incoming.security
    }
    outgoingHostname = result.outgoingEndpoint.hostname
    outgoingPort = String(result.outgoingEndpoint.port)
    outgoingSecurity = result.outgoingEndpoint.security
    authorizationMethod = result.preferredAuthorizationMethod
    discoverySource = result.sourceName
    errorMessage = nil
  }

  func loadSaved() {
    do {
      guard
        let authorization = try service.loadAuthorization(
          emailAddress: emailAddress,
          productAccountId: productAccountId
        )
      else {
        clearLoadedSetup()
        errorMessage = "No device-local setup is saved for this address."
        return
      }
      discoveredIncomingEndpoints = []
      apply(authorization.definition)
      connectedDefinition = authorization.definition
      locallyLoadedConnectionId = authorization.definition.connectionId
      removalObservation = nil
      selectedSyncedConnectionId = nil
      credential = ""
      discoverySource = "Loaded saved settings. Re-enter authorization to verify changes."
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func selectIncomingProtocol(_ mailProtocol: GenericMailProtocol) {
    incomingProtocol = mailProtocol
    rolesRequiringMapping = []
    guard
      let endpoint = discoveredIncomingEndpoints.first(where: {
        $0.mailProtocol == mailProtocol
      })
    else { return }
    incomingHostname = endpoint.hostname
    incomingPort = String(endpoint.port)
    incomingSecurity = endpoint.security
  }

  func connect() async {
    guard !isConnecting, isValid, isSessionCurrent() else { return }
    connectedDefinition = nil
    let incomingEndpoint = GenericMailEndpoint(
      mailProtocol: incomingProtocol,
      hostname: incomingHostname,
      port: Int(incomingPort) ?? 0,
      security: incomingSecurity
    )
    if roleMappingEndpoint != incomingEndpoint {
      resetRoleMappingState()
    }
    let draft = makeDraft(incomingEndpoint: incomingEndpoint)
    guard matchesSelectedSyncedConnection(draft) else { return }
    isConnecting = true
    defer { isConnecting = false }

    do {
      let definition = try await service.authorize(
        draft: draft,
        credential: credential,
        productAccountId: productAccountId,
        saveIntent: saveIntent(for: draft),
        syncSession: syncSession,
        isSessionCurrent: { self.isValid && self.isSessionCurrent() }
      )
      connectedDefinition = definition
      locallyLoadedConnectionId = nil
      removalObservation = nil
      selectedSyncedConnectionId = definition.connectionId
      credential = ""
      rolesRequiringMapping = []
      errorMessage = nil
      await loadSyncedDefinitions()
    } catch let GenericMailSetupError.missingRoleMappings(discovered, missing) {
      applyMissingRoleMappings(discovered, missing: missing, endpoint: incomingEndpoint)
    } catch is CancellationError {
    } catch let error as MailboxConnectionSyncError {
      await handleSyncError(error)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func invalidate() {
    isValid = false
  }

  private func apply(_ definition: GenericMailConnectionDefinition) {
    authorizationMethod = definition.authorizationMethod
    emailAddress = definition.emailAddress
    incomingHostname = definition.incomingEndpoint.hostname
    incomingPort = String(definition.incomingEndpoint.port)
    incomingProtocol = definition.incomingEndpoint.mailProtocol
    incomingSecurity = definition.incomingEndpoint.security
    outgoingHostname = definition.outgoingEndpoint.hostname
    outgoingPort = String(definition.outgoingEndpoint.port)
    outgoingSecurity = definition.outgoingEndpoint.security
    roleMappings = definition.roleMappings
    roleMappingEmailAddress = definition.emailAddress
    roleMappingEndpoint = definition.incomingEndpoint
    rolesRequiringMapping = CanonicalMailboxRole.allCases
    username = definition.username
  }

  private var normalizedEmailAddress: String {
    emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private var hasManualSetupDraft: Bool {
    !emailAddress.isEmpty || !incomingHostname.isEmpty || !outgoingHostname.isEmpty
  }

  private func resetRoleMappingState() {
    roleMappingEmailAddress = nil
    roleMappingEndpoint = nil
    roleMappings = [:]
    rolesRequiringMapping = []
  }

  private func clearLoadedSetup() {
    connectedDefinition = nil
    locallyLoadedConnectionId = nil
    removalObservation = nil
    selectedSyncedConnectionId = nil
    credential = ""
    discoveredIncomingEndpoints = []
    authorizationMethod = .password
    incomingHostname = ""
    incomingPort = ""
    incomingProtocol = .imap
    incomingSecurity = .implicitTLS
    outgoingHostname = ""
    outgoingPort = ""
    outgoingSecurity = .implicitTLS
    resetRoleMappingState()
    username = ""
    discoverySource = nil
  }

  private func matchesSelectedSyncedConnection(_ draft: GenericMailSetupDraft) -> Bool {
    do {
      let draftConnectionId = try service.connectionId(for: draft)
      guard selectedSyncedConnectionId == nil || draftConnectionId == selectedSyncedConnectionId
      else {
        errorMessage = "The mailbox settings no longer match the selected synced connection."
        return false
      }
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func saveIntent(
    for draft: GenericMailSetupDraft
  ) -> MailboxConnectionDefinitionSaveIntent {
    guard selectedSyncedConnectionId == nil else { return .authorizeExisting }
    guard let locallyLoadedConnectionId else { return .add(after: removalObservation) }
    guard let draftConnectionId = try? service.connectionId(for: draft) else {
      return .authorizeExisting
    }
    return draftConnectionId == locallyLoadedConnectionId
      ? .authorizeExisting : .add(after: removalObservation)
  }

  private func makeDraft(incomingEndpoint: GenericMailEndpoint) -> GenericMailSetupDraft {
    GenericMailSetupDraft(
      authorizationMethod: authorizationMethod,
      emailAddress: emailAddress,
      incomingEndpoint: incomingEndpoint,
      outgoingEndpoint: GenericMailEndpoint(
        mailProtocol: .smtp,
        hostname: outgoingHostname,
        port: Int(outgoingPort) ?? 0,
        security: outgoingSecurity
      ),
      roleMappings: roleMappingEmailAddress == normalizedEmailAddress ? roleMappings : [:],
      username: username
    )
  }

  private func handleSyncError(_ error: MailboxConnectionSyncError) async {
    switch error {
    case .connectionRemoved(let observation):
      locallyLoadedConnectionId = nil
      removalObservation = observation
      selectedSyncedConnectionId = nil
      await loadSyncedDefinitions()
    case .concurrentModification:
      locallyLoadedConnectionId = nil
      removalObservation = nil
      selectedSyncedConnectionId = nil
      await loadSyncedDefinitions()
    default:
      break
    }
    errorMessage = error.localizedDescription
  }

  private func applyMissingRoleMappings(
    _ discovered: [CanonicalMailboxRole: String],
    missing: [CanonicalMailboxRole],
    endpoint: GenericMailEndpoint
  ) {
    if roleMappingEmailAddress != normalizedEmailAddress {
      resetRoleMappingState()
    }
    for (role, mailbox) in discovered {
      roleMappings[role] = mailbox
    }
    roleMappingEmailAddress = normalizedEmailAddress
    roleMappingEndpoint = endpoint
    rolesRequiringMapping = missing
    let names = missing.map(\.displayName).joined(separator: ", ")
    errorMessage = "Map the remaining provider mailboxes: \(names)."
  }
}

extension GenericMailSetupViewModel {
  func isAuthorized(_ definition: GenericMailConnectionDefinition) -> Bool {
    authorizedSyncedConnectionIds.contains(definition.connectionId)
  }

  func loadSyncedDefinitions() async {
    guard let syncSession else { return }
    isLoadingSyncedDefinitions = true
    defer { isLoadingSyncedDefinitions = false }
    do {
      let syncedConnections = try await service.loadSyncedDefinitions(session: syncSession)
        .sorted {
          $0.definition.emailAddress.localizedCaseInsensitiveCompare(
            $1.definition.emailAddress
          ) == .orderedAscending
        }
      let definitions = syncedConnections.map(\.definition)
      defaultSendingConnectionId = try await service.loadDefaultSendingConnectionId(
        session: syncSession
      )
      syncedDefinitions = definitions
      authorizedSyncedConnectionIds = try Set(
        syncedConnections.compactMap { syncedDefinition in
          try service.hasLocalAuthorization(
            syncedDefinition,
            productAccountId: productAccountId
          ) ? syncedDefinition.definition.connectionId : nil
        }
      )
      if let selectedSyncedConnectionId,
        !definitions.contains(where: { $0.connectionId == selectedSyncedConnectionId })
      {
        clearLoadedSetup()
      }
      if !hasLoadedSyncedDefinitions,
        selectedSyncedConnectionId == nil,
        !hasManualSetupDraft,
        let selected = definitions.first(where: { $0.connectionId == defaultSendingConnectionId })
          ?? definitions.first
      {
        selectSyncedDefinition(selected)
      }
      hasLoadedSyncedDefinitions = true
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func removeEverywhere(_ definition: GenericMailConnectionDefinition) async {
    guard let syncSession else { return }
    do {
      let clearedLocalData = try await clearLocalData(definition, syncSession)
      if !clearedLocalData {
        try service.removeLocalAuthorization(definition, productAccountId: productAccountId)
      }
      try await service.removeEverywhere(
        definition,
        session: syncSession,
        shouldRemoveLocalAuthorization: false
      )
      if connectedDefinition?.connectionId == definition.connectionId {
        connectedDefinition = nil
      }
      await loadSyncedDefinitions()
    } catch {
      authorizedSyncedConnectionIds.remove(definition.connectionId)
      if connectedDefinition?.connectionId == definition.connectionId {
        connectedDefinition = nil
      }
      await loadSyncedDefinitions()
      errorMessage = error.localizedDescription
    }
  }

  func removeLocalAuthorization(_ definition: GenericMailConnectionDefinition) async {
    do {
      let clearedLocalData =
        if let syncSession {
          try await clearLocalData(definition, syncSession)
        } else {
          false
        }
      if !clearedLocalData {
        try service.removeLocalAuthorization(definition, productAccountId: productAccountId)
      }
      if connectedDefinition?.connectionId == definition.connectionId {
        connectedDefinition = nil
      }
      authorizedSyncedConnectionIds.remove(definition.connectionId)
      await loadSyncedDefinitions()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setDefaultSendingConnection(_ definition: GenericMailConnectionDefinition) async {
    guard let syncSession, isAuthorized(definition) else { return }
    do {
      try await service.setDefaultSendingConnection(definition, session: syncSession)
      defaultSendingConnectionId = definition.connectionId
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func selectSyncedDefinition(_ definition: GenericMailConnectionDefinition) {
    discoveredIncomingEndpoints = []
    apply(definition)
    locallyLoadedConnectionId = nil
    removalObservation = nil
    selectedSyncedConnectionId = definition.connectionId
    connectedDefinition = isAuthorized(definition) ? definition : nil
    credential = ""
    discoverySource =
      isAuthorized(definition)
      ? "Loaded device-authorized settings."
      : "Loaded encrypted synced settings. Authorize this mailbox on this device."
    errorMessage = nil
  }
}

struct GenericMailSetupPanel: View {
  @Bindable var viewModel: GenericMailSetupViewModel
  var cancelMailboxWork: () async -> Void = {}
  var isMailboxBusy = false
  var connectionsDidChange: () -> Void = {}
  @State private var connectTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Other Mail Server")
          .font(.headline)
        Text("Encrypted server settings sync; credentials stay on this device.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      if !viewModel.syncedDefinitions.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Synced Mailbox Connections")
            .font(.subheadline.bold())
          ForEach(viewModel.syncedDefinitions, id: \.connectionId) { definition in
            HStack {
              Button {
                viewModel.selectSyncedDefinition(definition)
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text(definition.emailAddress)
                  Text(
                    viewModel.isAuthorized(definition)
                      ? "Authorized on this device" : "Authorization required on this device"
                  )
                  .font(.caption)
                  .foregroundStyle(
                    viewModel.isAuthorized(definition) ? Color.secondary : Color.orange
                  )
                  if viewModel.defaultSendingConnectionId == definition.connectionId {
                    Label("Default sender", systemImage: "paperplane.fill")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .buttonStyle(.plain)

              Menu("Manage") {
                if viewModel.isAuthorized(definition) {
                  Button("Reauthorize on This Device") {
                    viewModel.selectSyncedDefinition(definition)
                  }
                  Button("Remove Device Authorization", role: .destructive) {
                    Task {
                      await Self.performDestructiveAction(
                        cancelMailboxWork: cancelMailboxWork
                      ) {
                        await viewModel.removeLocalAuthorization(definition)
                        connectionsDidChange()
                      }
                    }
                  }
                } else {
                  Button("Authorize on This Device") {
                    viewModel.selectSyncedDefinition(definition)
                  }
                }
                Button("Remove Mailbox Connection Everywhere", role: .destructive) {
                  Task {
                    await Self.performDestructiveAction(
                      cancelMailboxWork: cancelMailboxWork
                    ) {
                      await viewModel.removeEverywhere(definition)
                      connectionsDidChange()
                    }
                  }
                }
              }
              .disabled(viewModel.isConnecting || isMailboxBusy)
            }
          }
        }
      }

      HStack {
        TextField("Mailbox email address", text: $viewModel.emailAddress)
          .textContentType(.emailAddress)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Discover Settings") {
          viewModel.discover()
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.isConnecting)
      }

      Button("Load Saved Setup") {
        viewModel.loadSaved()
      }
      .buttonStyle(.bordered)
      .disabled(viewModel.isConnecting)

      if let discoverySource = viewModel.discoverySource {
        Text(discoverySource)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      TextField("Username", text: $viewModel.username)
        .textContentType(.username)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()

      Picker(
        "Incoming protocol",
        selection: Binding(
          get: { viewModel.incomingProtocol },
          set: { viewModel.selectIncomingProtocol($0) }
        )
      ) {
        Text("IMAP").tag(GenericMailProtocol.imap)
        Text("POP3 (legacy)").tag(GenericMailProtocol.pop3)
      }
      .pickerStyle(.segmented)

      endpointEditor(
        title: viewModel.incomingProtocol.displayName,
        hostname: $viewModel.incomingHostname,
        port: $viewModel.incomingPort,
        security: $viewModel.incomingSecurity
      )
      endpointEditor(
        title: "SMTP",
        hostname: $viewModel.outgoingHostname,
        port: $viewModel.outgoingPort,
        security: $viewModel.outgoingSecurity
      )

      if viewModel.showsMailboxRoles {
        VStack(alignment: .leading, spacing: 8) {
          Text("Mailbox Roles")
            .font(.subheadline.bold())
          Text("Map only the roles the provider did not identify unambiguously.")
            .font(.footnote)
            .foregroundStyle(.secondary)
          ForEach(viewModel.rolesRequiringMapping) { role in
            TextField(
              role.displayName,
              text: Binding(
                get: { viewModel.roleMappings[role] ?? "" },
                set: { viewModel.roleMappings[role] = $0 }
              )
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          }
        }
      } else if viewModel.incomingProtocol == .pop3 {
        Text("POP3 uses product-owned local roles and does not claim server folder support.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Picker("Authorization", selection: $viewModel.authorizationMethod) {
        ForEach(MailAuthorizationMethod.allCases) { method in
          Text(method.displayName).tag(method)
        }
      }
      SecureField(viewModel.credentialLabel, text: $viewModel.credential)
        .textContentType(.password)

      Button {
        connectTask?.cancel()
        connectTask = Task {
          await viewModel.connect()
          connectionsDidChange()
        }
      } label: {
        Label(
          viewModel.isConfirmingRecreation
            ? "Recreate Removed Mailbox Connection" : "Verify and Save on This Device",
          systemImage: "lock.shield"
        )
        .frame(minHeight: 32)
      }
      .buttonStyle(.borderedProminent)
      .disabled(viewModel.isConnecting)

      if viewModel.isConnecting {
        ProgressView("Verifying secure mail transport...")
      }

      if let definition = viewModel.connectedDefinition {
        Label(
          "Saved \(definition.emailAddress) on this device",
          systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(.green)
        .font(.subheadline)
      }

      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .font(.footnote)
      }
    }
    .disabled(viewModel.isConnecting)
    .onDisappear {
      connectTask?.cancel()
    }
  }

  private func endpointEditor(
    title: String,
    hostname: Binding<String>,
    port: Binding<String>,
    security: Binding<MailTransportSecurity>
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.subheadline.bold())
      HStack {
        TextField("Server hostname", text: hostname)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("Port", text: port)
          .frame(width: 80)
      }
      Picker("Transport security", selection: security) {
        ForEach(MailTransportSecurity.allCases) { option in
          Text(option.displayName).tag(option)
        }
      }
      .pickerStyle(.segmented)
    }
  }

  static func performDestructiveAction(
    cancelMailboxWork: () async -> Void,
    action: () async -> Void
  ) async {
    await cancelMailboxWork()
    await action()
  }
}
