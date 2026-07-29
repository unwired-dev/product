import SwiftUI

struct EmailAccountsSettingsView: View {
  @Bindable var ewsViewModel: EWSSetupViewModel
  @Bindable var genericMailViewModel: GenericMailSetupViewModel
  @Bindable var gmailViewModel: MailboxProviderConnectionViewModel
  @Bindable var microsoftGraphViewModel: MailboxProviderConnectionViewModel
  @Bindable var freshnessViewModel: MailboxFreshnessViewModel

  let cancelBodyPrefetch: () async -> Void
  let connectionsDidChange: () -> Void
  let isMailboxBusy: Bool

  @State private var detailTarget: MailProviderId?
  @State private var syncTask: Task<Void, Never>?

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          connectionSummary

          Divider()

          GmailProviderConnectionPanel(
            cancelBodyPrefetch: cancelBodyPrefetch,
            viewModel: gmailViewModel,
            isMailboxBusy: isMailboxBusy,
            selectMailbox: { gmailViewModel.selectedConnectionId = $0.id }
          )
          .id(MailProviderId.gmail)

          MicrosoftGraphConnectionPanel(
            cancelBodyPrefetch: cancelBodyPrefetch,
            connectionsDidChange: providerConnectionsDidChange,
            connectionDidConnect: {
              microsoftGraphViewModel.selectedConnectionId = $0.id
            },
            isMailboxBusy: isMailboxBusy,
            selectMailbox: { microsoftGraphViewModel.selectedConnectionId = $0.id },
            viewModel: microsoftGraphViewModel
          )
          .id(MailProviderId.microsoftGraph)

          EWSSetupPanel(
            viewModel: ewsViewModel,
            cancelBodyPrefetch: cancelBodyPrefetch,
            connectionsDidChange: providerConnectionsDidChange,
            isMailboxBusy: isMailboxBusy
          )
          .id(MailProviderId.exchangeWebServices)

          GenericMailSetupPanel(
            viewModel: genericMailViewModel,
            connectionsDidChange: providerConnectionsDidChange
          )
          .id(MailProviderId.imapSMTP)
        }
        .padding(24)
        .frame(maxWidth: 760, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
      }
      .onChange(of: detailTarget) { _, providerId in
        guard let providerId else { return }
        withAnimation {
          proxy.scrollTo(providerSectionId(for: providerId), anchor: .top)
        }
        detailTarget = nil
      }
    }
    .task {
      let connectionsAreAuthoritative = await gmailViewModel.load()
      freshnessViewModel.updateConnections(
        gmailViewModel.connections,
        prunesPersistedState: connectionsAreAuthoritative
      )
      await genericMailViewModel.loadSyncedDefinitions()
    }
    .onChange(of: gmailViewModel.connections) { _, connections in
      freshnessViewModel.updateConnections(connections, prunesPersistedState: false)
      connectionsDidChange()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .mailboxMetadataDidSynchronize)
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
          notification.userInfo?[MailboxSyncNotificationUserInfoKey.successfulSyncAt] as? Date
      )
    }
    .onDisappear {
      syncTask?.cancel()
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

      if gmailViewModel.connections.isEmpty, !gmailViewModel.isLoading {
        ContentUnavailableView(
          "No Mailbox Connections",
          systemImage: "tray",
          description: Text("Use a provider setup section below to add one.")
        )
      } else {
        ForEach(gmailViewModel.connections) { connection in
          SettingsMailboxConnectionRow(
            connection: connection,
            isDefaultSender: gmailViewModel.defaultSendingConnectionId == connection.id,
            isHistoricalBackfillActive:
              freshnessViewModel.isHistoricalBackfillActive(for: connection),
            isMailboxBusy: isMailboxBusy || gmailViewModel.isEditingDisabled,
            status: freshnessViewModel.status(for: connection),
            showDetails: { showDetails(for: connection) },
            synchronize: {
              syncTask?.cancel()
              syncTask = Task {
                await freshnessViewModel.synchronizeFully(connections: [connection])
              }
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

  private func providerSectionId(for providerId: MailProviderId) -> MailProviderId {
    switch providerId {
    case .imapSMTP, .pop3SMTP:
      return .imapSMTP
    default:
      return providerId
    }
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

  private func providerConnectionsDidChange() {
    Task {
      _ = await gmailViewModel.load()
      connectionsDidChange()
    }
  }
}

private struct SettingsMailboxConnectionRow: View {
  let connection: MailboxConnection
  let isDefaultSender: Bool
  let isHistoricalBackfillActive: Bool
  let isMailboxBusy: Bool
  let status: MailboxSyncStatus
  let showDetails: () -> Void
  let synchronize: () -> Void

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
          Button("Synchronize", action: synchronize)
            .disabled(
              isMailboxBusy
                || connection.authorizationState != .authorized
                || status.phase == .syncing
            )
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
