import SwiftUI

// swiftlint:disable file_length

enum EmailAccountsNavigationFocus: Equatable {
  case connection(String)
  case genericMail
  case provider(String)
  case summary
}

/// Couples the Sending Identity store with the provider-backed verification sender it requires.
struct SendingIdentitySettingsDependencies {
  let sendVerification: SendingIdentityStore.VerificationSender
  let store: SendingIdentityStore
}

// swiftlint:disable:next type_body_length
struct EmailAccountsSettingsView: View {
  @Bindable var ewsViewModel: EWSSetupViewModel
  @Bindable var genericMailViewModel: GenericMailSetupViewModel
  @Bindable var gmailViewModel: MailboxProviderConnectionViewModel
  @Bindable var microsoftGraphViewModel: MailboxProviderConnectionViewModel
  @Bindable var freshnessViewModel: MailboxFreshnessViewModel
  var sendingIdentityDependencies: SendingIdentitySettingsDependencies?

  let cancelBodyPrefetch: () async -> Void
  let connectionsDidChange: () -> Void
  let gmailConnectionsDidChange: () -> Void
  let isMailboxBusy: Bool
  var navigationRequest: SettingsRouteRequest?

  @State private var connectionsAreAuthoritative = false
  @State private var detailTarget: MailProviderId?
  @State private var highlightTask: Task<Void, Never>?
  @State private var highlightedAnchor: NavigationAnchor?
  @State private var pendingDetailsConnection: MailboxConnection?

  private enum NavigationAnchor: Hashable {
    case exchangeWebServices
    case genericMail
    case gmail
    case microsoftGraph
    case summary
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          connectionSummary
            .id(NavigationAnchor.summary)
            .settingsHighlight(highlightedAnchor == .summary)

          Divider()

          if let sendingIdentityDependencies {
            SendingIdentitySettingsSection(
              connections: summaryConnections,
              sendVerification: sendingIdentityDependencies.sendVerification,
              store: sendingIdentityDependencies.store
            )
          }

          Divider()

          GmailProviderConnectionPanel(
            cancelBodyPrefetch: cancelBodyPrefetch,
            viewModel: gmailViewModel,
            isMailboxBusy: isMailboxBusy,
            selectMailbox: { gmailViewModel.selectedConnectionId = $0.id },
            connectionsDidChange: gmailProviderConnectionsDidChange,
            manualRefreshDidComplete: gmailProviderConnectionsDidChange
          )
          .id(NavigationAnchor.gmail)
          .settingsHighlight(highlightedAnchor == .gmail)

          MicrosoftGraphConnectionPanel(
            cancelBodyPrefetch: cancelBodyPrefetch,
            connectionsDidChange: providerConnectionsDidChange,
            connectionDidConnect: {
              microsoftGraphViewModel.selectedConnectionId = $0.id
            },
            isMailboxBusy: isMailboxBusy,
            manualRefreshDidComplete: microsoftManualRefreshDidComplete,
            selectMailbox: { microsoftGraphViewModel.selectedConnectionId = $0.id },
            viewModel: microsoftGraphViewModel
          )
          .disabled(providerMutationsAreDisabled)
          .id(NavigationAnchor.microsoftGraph)
          .settingsHighlight(highlightedAnchor == .microsoftGraph)

          EWSSetupPanel(
            viewModel: ewsViewModel,
            cancelBodyPrefetch: cancelBodyPrefetch,
            connectionsDidChange: providerConnectionsDidChange,
            isMailboxBusy: isMailboxBusy
          )
          .disabled(providerMutationsAreDisabled)
          .id(NavigationAnchor.exchangeWebServices)
          .settingsHighlight(highlightedAnchor == .exchangeWebServices)

          GenericMailSetupPanel(
            viewModel: genericMailViewModel,
            cancelMailboxWork: cancelBodyPrefetch,
            isMailboxBusy: isMailboxBusy,
            connectionsDidChange: providerConnectionsDidChange,
            routedConnections: gmailViewModel.connections
          )
          .disabled(providerMutationsAreDisabled)
          .id(NavigationAnchor.genericMail)
          .settingsHighlight(highlightedAnchor == .genericMail)
        }
        .padding(24)
        .frame(maxWidth: 760, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
      }
      .onChange(of: detailTarget) { _, providerId in
        guard let providerId else { return }
        withAnimation {
          proxy.scrollTo(navigationAnchor(for: providerId), anchor: .top)
        }
        detailTarget = nil
      }
      .onChange(of: navigationRequest?.id, initial: true) { _, _ in
        applyNavigation(navigationRequest?.route, proxy: proxy)
      }
      .task {
        connectionsAreAuthoritative = await Self.loadInitialConnections(
          loadRoutedConnections: gmailViewModel.load,
          loadGenericConnections: genericMailViewModel.loadSyncedDefinitions,
          loadEWSConnections: ewsViewModel.load
        )
        Self.updateFreshnessConnections(
          gmailViewModel.connections,
          connectionsAreAuthoritative: connectionsAreAuthoritative,
          freshnessViewModel: freshnessViewModel
        )
        applyNavigation(navigationRequest?.route, proxy: proxy)
      }
    }
    .onChange(of: gmailViewModel.connections) { _, connections in
      connectionsAreAuthoritative = gmailViewModel.connectionsSnapshotIsAuthoritative
      Self.updateFreshnessConnections(
        connections,
        connectionsAreAuthoritative: connectionsAreAuthoritative,
        freshnessViewModel: freshnessViewModel
      )
    }
    .onChange(of: gmailViewModel.connectionsSnapshotIsAuthoritative) { _, isAuthoritative in
      connectionsAreAuthoritative = isAuthoritative
      Self.updateFreshnessConnections(
        gmailViewModel.connections,
        connectionsAreAuthoritative: isAuthoritative,
        freshnessViewModel: freshnessViewModel
      )
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .mailboxMetadataDidSynchronize)
        .receive(on: RunLoop.main)
    ) { notification in
      guard
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.productAccountId]
          as? String == productAccountId,
        let connectionId =
          notification.userInfo?[MailboxSyncNotificationUserInfoKey.connectionId] as? String,
        let phase =
          notification.userInfo?[MailboxSyncNotificationUserInfoKey.phase] as? MailboxSyncPhase
      else { return }
      freshnessViewModel.recordExternalSync(
        connectionIdRawValue: connectionId,
        phase: phase,
        successfulSyncAt:
          notification.userInfo?[MailboxSyncNotificationUserInfoKey.successfulSyncAt] as? Date,
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
    }
    .onDisappear {
      highlightTask?.cancel()
    }
    .confirmDiscardSelection($pendingDetailsConnection) { connection in
      ewsViewModel.discardUnsavedChanges()
      genericMailViewModel.discardUnsavedChanges()
      showDetails(for: connection)
    }
  }

  @MainActor
  static func loadInitialConnections(
    loadRoutedConnections: () async -> Bool,
    loadGenericConnections: () async -> Void,
    loadEWSConnections: () async -> Void
  ) async -> Bool {
    async let routedConnectionsAreAuthoritative = loadRoutedConnections()
    async let genericConnectionsLoad: Void = loadGenericConnections()
    async let ewsConnectionsLoad: Void = loadEWSConnections()
    let connectionsAreAuthoritative = await routedConnectionsAreAuthoritative
    _ = await (genericConnectionsLoad, ewsConnectionsLoad)
    return connectionsAreAuthoritative
  }

  @MainActor
  static func refreshConnectionAuthority(
    loadRoutedConnections: () async -> Bool,
    loadGenericConnections: () async -> Void,
    loadMicrosoftConnections: () async -> Bool,
    loadEWSConnections: () async -> Void,
    connectionsDidChange: () -> Void
  ) async {
    async let routedConnectionsAreAuthoritative = loadRoutedConnections()
    async let genericConnectionsLoad: Void = loadGenericConnections()
    async let microsoftConnectionsAreAuthoritative = loadMicrosoftConnections()
    async let ewsConnectionsLoad: Void = loadEWSConnections()
    _ = await (
      routedConnectionsAreAuthoritative,
      genericConnectionsLoad,
      microsoftConnectionsAreAuthoritative,
      ewsConnectionsLoad
    )
    connectionsDidChange()
  }

  @MainActor
  static func refreshConnectionAuthorityAfterRoutedMutation(
    loadGenericConnections: () async -> Void,
    loadMicrosoftConnections: () async -> Bool,
    loadEWSConnections: () async -> Void,
    connectionsDidChange: () -> Void
  ) async {
    async let genericConnectionsLoad: Void = loadGenericConnections()
    async let microsoftConnectionsAreAuthoritative = loadMicrosoftConnections()
    async let ewsConnectionsLoad: Void = loadEWSConnections()
    _ = await (
      genericConnectionsLoad,
      microsoftConnectionsAreAuthoritative,
      ewsConnectionsLoad
    )
    connectionsDidChange()
  }

  @MainActor
  static func refreshConnectionAuthorityAfterMicrosoftRefresh(
    loadRoutedConnections: () async -> Bool,
    loadGenericConnections: () async -> Void,
    loadEWSConnections: () async -> Void,
    connectionsDidChange: () -> Void
  ) async {
    async let routedConnectionsAreAuthoritative = loadRoutedConnections()
    async let genericConnectionsLoad: Void = loadGenericConnections()
    async let ewsConnectionsLoad: Void = loadEWSConnections()
    _ = await (
      routedConnectionsAreAuthoritative,
      genericConnectionsLoad,
      ewsConnectionsLoad
    )
    connectionsDidChange()
  }

  @MainActor
  static func updateFreshnessConnections(
    _ connections: [MailboxConnection],
    connectionsAreAuthoritative: Bool,
    freshnessViewModel: MailboxFreshnessViewModel
  ) {
    freshnessViewModel.updateConnections(
      connections,
      snapshotIsAuthoritative: connectionsAreAuthoritative
    )
  }

  static func navigationFocus(for route: SettingsRoute?) -> EmailAccountsNavigationFocus? {
    guard
      let route,
      route.destination == .emailAccounts,
      let context = route.context
    else {
      return nil
    }

    switch context {
    case .authorization(let connectionId), .synchronization(let connectionId):
      return connectionId.map(EmailAccountsNavigationFocus.connection) ?? .summary
    case .mailboxRoles(let connectionId):
      return connectionId.map(EmailAccountsNavigationFocus.connection) ?? .genericMail
    case .defaultSendingConnection, .mailboxConnections:
      return .summary
    case .mailboxConnection(let connectionId):
      return .connection(connectionId)
    case .provider(let providerId):
      return .provider(providerId)
    case .appearance, .missingSignature, .notificationPermission, .preferenceConflict,
      .readReceipt, .storage, .templateEditor:
      return nil
    }
  }

  @ViewBuilder
  private var connectionSummary: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Mailbox Connections")
        .font(.title2.bold())
      Text(
        "Provider authorization stays on this device. Non-secret connection settings "
          + "synchronize end-to-end between Trusted Devices."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)

      if summaryConnections.isEmpty, !gmailViewModel.isLoading,
        !genericMailViewModel.isLoadingSyncedDefinitions
      {
        ContentUnavailableView(
          "No Mailbox Connections",
          systemImage: "tray",
          description: Text("Use a provider setup section below to add one.")
        )
      } else {
        ForEach(summaryConnections) { connection in
          SettingsMailboxConnectionRow(
            connection: connection,
            isDefaultSender: gmailViewModel.defaultSendingConnectionId == connection.id,
            isHistoricalBackfillActive:
              freshnessViewModel.isHistoricalBackfillActive(for: connection),
            isSynchronizationDisabled: synchronizationIsDisabled(for: connection),
            status: freshnessViewModel.status(for: connection),
            showDetails: { requestDetails(for: connection) },
            synchronize: {
              await freshnessViewModel.synchronizeFully(
                connection: connection,
                among: gmailViewModel.connections,
                snapshotIsAuthoritative: gmailViewModel.connectionsSnapshotIsAuthoritative
              )
            }
          )
        }
      }
    }
  }

  private var productAccountId: String {
    gmailViewModel.connections.first?.productAccountId.rawValue
      ?? gmailViewModel.sessionSnapshot.productAccountId
  }

  private var providerMutationsAreDisabled: Bool {
    providerMutationIsDisabled(
      isMailboxBusy: isMailboxBusy,
      isRoutedConnectionsLoading: gmailViewModel.isLoading
    )
  }

  private var summaryConnections: [MailboxConnection] {
    Self.makeSummaryConnections(
      routedConnections: gmailViewModel.connections,
      genericDefinitions: genericMailViewModel.syncedDefinitions,
      authorizedGenericConnectionIds: genericMailViewModel.authorizedSyncedConnectionIds,
      session: gmailViewModel.sessionSnapshot
    )
  }

  static func makeSummaryConnections(
    routedConnections: [MailboxConnection],
    genericDefinitions: [GenericMailConnectionDefinition],
    authorizedGenericConnectionIds: Set<MailboxConnectionId>,
    session: ProductAccountSessionSnapshot
  ) -> [MailboxConnection] {
    let routedConnectionIds = Set(routedConnections.map(\.id))
    let pop3Connections: [MailboxConnection] = genericDefinitions.compactMap { definition in
      guard
        definition.connectionId.providerId == .pop3SMTP,
        !routedConnectionIds.contains(definition.connectionId)
      else { return nil }
      return MailboxConnection(
        authorizationState: authorizedGenericConnectionIds.contains(definition.connectionId)
          ? .authorized : .required,
        capabilities: .none,
        connectedAt: 0,
        displayName: definition.emailAddress,
        id: definition.connectionId,
        lastVerifiedAt: 0,
        productAccountId: ProductAccountId(session.productAccountId),
        trustedDeviceId: session.trustedDeviceId,
        updatedAt: 0
      )
    }
    return (routedConnections + pop3Connections).sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  private func navigationAnchor(for providerId: MailProviderId) -> NavigationAnchor {
    switch providerId {
    case .imapSMTP, .pop3SMTP:
      return .genericMail
    case .exchangeWebServices:
      return .exchangeWebServices
    case .gmail:
      return .gmail
    case .microsoftGraph:
      return .microsoftGraph
    default:
      return .summary
    }
  }

  private func applyNavigation(
    _ route: SettingsRoute?,
    proxy: ScrollViewProxy
  ) {
    guard let focus = Self.navigationFocus(for: route) else { return }

    let anchor: NavigationAnchor
    switch focus {
    case .connection(let connectionId):
      if let connection = connection(matching: connectionId) {
        requestDetails(for: connection)
        anchor = navigationAnchor(for: connection.providerId)
      } else {
        anchor = .summary
      }
    case .genericMail:
      anchor = .genericMail
    case .provider(let providerId):
      anchor = navigationAnchor(for: MailProviderId(rawValue: providerId))
    case .summary:
      anchor = .summary
    }

    withAnimation {
      proxy.scrollTo(anchor, anchor: .top)
      highlightedAnchor = anchor
    }
    highlightTask?.cancel()
    highlightTask = Task {
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else { return }
      withAnimation {
        highlightedAnchor = nil
      }
    }
  }

  private func connection(matching rawValue: String) -> MailboxConnection? {
    return summaryConnections.first { $0.id.rawValue == rawValue }
  }

  private func showDetails(for connection: MailboxConnection) {
    switch connection.providerId {
    case .gmail:
      gmailViewModel.selectedConnectionId = connection.id
      detailTarget = .gmail
    case .microsoftGraph:
      microsoftGraphViewModel.selectedConnectionId = connection.id
      detailTarget = .microsoftGraph
    case .exchangeWebServices:
      Task {
        await ewsViewModel.select(connection)
        detailTarget = .exchangeWebServices
      }
    case .imapSMTP, .pop3SMTP:
      guard
        let definition = genericMailViewModel.syncedDefinitions.first(where: {
          $0.connectionId == connection.id
        })
      else { return }
      genericMailViewModel.selectSyncedDefinition(definition)
      detailTarget = .imapSMTP
    default:
      break
    }
  }

  private func requestDetails(for connection: MailboxConnection) {
    guard
      SettingsNavigationPolicy.canDiscardChanges(
        isSetupWorking: ewsViewModel.isWorking || genericMailViewModel.isConnecting
      )
    else { return }
    if ewsViewModel.hasUnsavedChanges || genericMailViewModel.hasUnsavedChanges {
      pendingDetailsConnection = connection
    } else {
      showDetails(for: connection)
    }
  }

  private func providerConnectionsDidChange() {
    Task {
      connectionsAreAuthoritative = false
      await Self.refreshConnectionAuthority(
        loadRoutedConnections: gmailViewModel.load,
        loadGenericConnections: genericMailViewModel.loadSyncedDefinitions,
        loadMicrosoftConnections: microsoftGraphViewModel.load,
        loadEWSConnections: ewsViewModel.load,
        connectionsDidChange: gmailConnectionsDidChange
      )
      connectionsAreAuthoritative = gmailViewModel.connectionsSnapshotIsAuthoritative
      Self.updateFreshnessConnections(
        gmailViewModel.connections,
        connectionsAreAuthoritative: connectionsAreAuthoritative,
        freshnessViewModel: freshnessViewModel
      )
    }
  }

  private func gmailProviderConnectionsDidChange() {
    Task {
      await Self.refreshConnectionAuthorityAfterRoutedMutation(
        loadGenericConnections: genericMailViewModel.loadSyncedDefinitions,
        loadMicrosoftConnections: microsoftGraphViewModel.load,
        loadEWSConnections: ewsViewModel.load,
        connectionsDidChange: gmailConnectionsDidChange
      )
    }
  }

  private func microsoftManualRefreshDidComplete() {
    Task {
      await Self.refreshConnectionAuthorityAfterMicrosoftRefresh(
        loadRoutedConnections: gmailViewModel.load,
        loadGenericConnections: genericMailViewModel.loadSyncedDefinitions,
        loadEWSConnections: ewsViewModel.load,
        connectionsDidChange: gmailConnectionsDidChange
      )
    }
  }
}

private struct SendingIdentitySettingsSection: View {
  let connections: [MailboxConnection]
  let sendVerification: SendingIdentityStore.VerificationSender
  @Bindable var store: SendingIdentityStore

  @State private var aliasAddress = ""
  @State private var isSendingVerification = false
  @State private var selectedConnectionId: MailboxConnectionId?
  @State private var verificationCode = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Sending Identities")
        .font(.title2.bold())
      Text(
        "From addresses belong to this Mail Profile. Identity definitions synchronize "
          + "end-to-end; provider authorization stays on this device."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)

      if store.preferences.identities.isEmpty {
        ContentUnavailableView(
          "No Sending Identities",
          systemImage: "person.crop.circle.badge.exclamationmark",
          description: Text("Authorize a sending Mailbox Connection to add its primary address.")
        )
      } else {
        Picker(
          "Default From Address",
          selection: Binding(
            get: { store.preferences.defaultIdentityId },
            set: { identityId in
              guard let identityId else { return }
              Task { await store.setDefault(identityId) }
            }
          )
        ) {
          ForEach(store.preferences.identities) { identity in
            Text(identity.title).tag(Optional(identity.id))
          }
        }

        ForEach(store.preferences.identities) { identity in
          LabeledContent(identity.title) {
            Text(
              identity.verification == .providerConfirmed
                ? "Provider confirmed" : "Verified on this device"
            )
            .foregroundStyle(.secondary)
          }
        }
      }

      Divider()

      Text("Verify a Manual Alias")
        .font(.headline)
      Text(
        "A self-addressed test confirms that the provider accepts this From address. "
          + "The alias and one-time code never pass through the Unwired backend."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)

      Picker("Mailbox Connection", selection: $selectedConnectionId) {
        Text("Choose a Mailbox Connection").tag(Optional<MailboxConnectionId>.none)
        ForEach(eligibleConnections) { connection in
          Text(connection.displayName).tag(Optional(connection.id))
        }
      }
      TextField("Alias email address", text: $aliasAddress)
        .textInputAutocapitalization(.never)
        .textContentType(.emailAddress)
        .accessibilityIdentifier("sending-identity-alias")
      Button("Send Verification Code") {
        guard let connection = selectedConnection else { return }
        isSendingVerification = true
        Task {
          defer { isSendingVerification = false }
          if await store.beginManualVerification(
            address: aliasAddress,
            connection: connection,
            send: sendVerification
          ) {
            verificationCode = ""
          }
        }
      }
      .disabled(selectedConnection == nil || aliasAddress.isEmpty || isSendingVerification)

      if let verificationAddress = store.verificationAddress {
        Text("Enter the code sent to \(verificationAddress).")
          .font(.subheadline)
        TextField("One-time code", text: $verificationCode)
          .textContentType(.oneTimeCode)
          .accessibilityIdentifier("sending-identity-code")
        Button("Verify From Address") {
          Task {
            if await store.completeManualVerification(code: verificationCode) {
              aliasAddress = ""
              verificationCode = ""
            }
          }
        }
        .disabled(verificationCode.isEmpty)
      }

      if let errorMessage = store.errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .accessibilityLabel("Sending Identity error: \(errorMessage)")
      }
    }
  }

  private var eligibleConnections: [MailboxConnection] {
    connections.filter {
      $0.authorizationState == .authorized && $0.capabilities.canSend
    }
  }

  private var selectedConnection: MailboxConnection? {
    guard let selectedConnectionId else { return nil }
    return eligibleConnections.first { $0.id == selectedConnectionId }
  }
}

extension EmailAccountsSettingsView {
  fileprivate func synchronizationIsDisabled(for connection: MailboxConnection) -> Bool {
    mailboxSynchronizationIsDisabled(
      isMailboxBusy: isMailboxBusy || gmailViewModel.isEditingDisabled,
      isAuthorized: connection.authorizationState == .authorized,
      snapshotIsAuthoritative: connectionsAreAuthoritative,
      isSynchronizing: freshnessViewModel.status(for: connection).phase == .syncing
    )
  }
}

func mailboxSynchronizationIsDisabled(
  isMailboxBusy: Bool,
  isAuthorized: Bool,
  snapshotIsAuthoritative: Bool,
  isSynchronizing: Bool
) -> Bool {
  isMailboxBusy || !isAuthorized || !snapshotIsAuthoritative || isSynchronizing
}

func providerMutationIsDisabled(
  isMailboxBusy: Bool,
  isRoutedConnectionsLoading: Bool
) -> Bool {
  isMailboxBusy || isRoutedConnectionsLoading
}

private struct SettingsMailboxConnectionRow: View {
  let connection: MailboxConnection
  let isDefaultSender: Bool
  let isHistoricalBackfillActive: Bool
  let isSynchronizationDisabled: Bool
  let status: MailboxSyncStatus
  let showDetails: () -> Void
  let synchronize: () async -> Void

  @State private var syncTask: Task<Void, Never>?

  var body: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        LabeledContent("Provider", value: providerTitle)
        LabeledContent("Address", value: connection.mailboxAddress)
        LabeledContent(
          "Authorization",
          value: connection.authorizationState == .authorized
            ? "Authorized on this device" : "Required on this device"
        )
        LabeledContent("Sync health", value: status.summary)

        if connection.capabilities.canSynchronizeMetadata {
          Label(historicalBackfillSummary, systemImage: "clock.arrow.circlepath")
            .font(.caption)
        }

        if isDefaultSender {
          Label("Default Sending Connection", systemImage: "paperplane.fill")
            .font(.caption)
        } else if !connection.capabilities.canSend {
          Text("This connection does not support sending, so it cannot be the default sender.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if connection.capabilities.canSynchronizeMetadata {
          Button("Synchronize") {
            syncTask?.cancel()
            syncTask = Task {
              await synchronize()
            }
          }
          .disabled(isSynchronizationDisabled)
        } else {
          Text(manualSynchronizationExplanation)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Text(connectionSettingsExplanation)
          .font(.caption)
          .foregroundStyle(.secondary)

        Button("Open Connection Details", action: showDetails)
      }
      .padding(.top, 8)
    } label: {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text(connection.displayName)
            .font(.headline)
          Text(providerTitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Label(
          connection.authorizationState == .authorized ? "Authorized" : "Authorization required",
          systemImage: connection.authorizationState == .authorized
            ? "checkmark.shield" : "lock.trianglebadge.exclamationmark"
        )
        .font(.caption)
        .foregroundStyle(
          connection.authorizationState == .authorized ? Color.secondary : Color.orange
        )
      }
    }
    .padding(12)
    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }

  private var providerTitle: String {
    switch connection.providerId {
    case .gmail:
      return "Gmail"
    case .microsoftGraph:
      return "Microsoft 365"
    case .exchangeWebServices:
      return "On-Premises Exchange"
    case .imapSMTP:
      return "IMAP and SMTP"
    case .pop3SMTP:
      return "Legacy POP3 and SMTP"
    default:
      return connection.providerId.rawValue
    }
  }

  private var connectionSettingsExplanation: String {
    switch connection.providerId {
    case .exchangeWebServices:
      return
        "The On-Premises Exchange detail below exposes its non-secret endpoint and username."
    case .imapSMTP:
      return
        "The Other Mail Server detail below exposes non-secret endpoints and Mailbox Role mapping."
    case .pop3SMTP:
      return
        "The Other Mail Server detail below exposes non-secret endpoints. POP3 uses "
        + "product-owned roles because server folder mapping is unsupported."
    case .gmail, .microsoftGraph:
      return
        "This OAuth provider has no editable server endpoint or Mailbox Role mapping."
    default:
      return "This provider has no additional non-secret settings."
    }
  }
  private var manualSynchronizationExplanation: String {
    if connection.authorizationState == .required {
      return "Manual synchronization is unavailable until this device is authorized."
    }
    return "This provider does not support manual metadata synchronization."
  }

  private var historicalBackfillSummary: String {
    if isHistoricalBackfillActive {
      return "Historical metadata backfill in progress"
    }
    if status.phase == .backfillPending {
      return "Historical metadata backfill pending"
    }
    return "No historical metadata backfill pending"
  }
}

extension View {
  func settingsHighlight(_ isHighlighted: Bool) -> some View {
    overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(isHighlighted ? Color.accentColor : Color.clear, lineWidth: 2)
    }
    .animation(.easeOut(duration: 0.2), value: isHighlighted)
  }
}
