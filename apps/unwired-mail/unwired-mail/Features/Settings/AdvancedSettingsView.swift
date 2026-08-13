import SwiftUI

// swiftlint:disable file_length

enum AdvancedProductSyncHealth: String, Equatable {
  case available
  case recoveryRequired
  case signedOut
  case unavailable

  var title: String {
    switch self {
    case .available:
      return "Available on this trusted device"
    case .recoveryRequired:
      return "Recovery required"
    case .signedOut:
      return "Sign in to inspect Product Sync"
    case .unavailable:
      return "Unavailable"
    }
  }

  static func current(
    session: ProductAccountSessionSnapshot?,
    keyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore()
  ) -> Self {
    guard let session else { return .signedOut }
    do {
      return try keyMaterialStore.load(productAccountId: session.productAccountId) == nil
        ? .recoveryRequired : .available
    } catch {
      return .unavailable
    }
  }
}

enum AdvancedMailboxSyncHealth: Equatable {
  case attentionRequired
  case noConnections
  case offline
  case synchronizing
  case upToDate

  var title: String {
    switch self {
    case .attentionRequired:
      return "Attention required"
    case .noConnections:
      return "No Mailbox Connections"
    case .offline:
      return "Offline"
    case .synchronizing:
      return "Synchronizing"
    case .upToDate:
      return "Up to date"
    }
  }

  static func current(_ statuses: [MailboxSyncStatus]) -> Self {
    guard !statuses.isEmpty else { return .noConnections }
    if statuses.contains(where: {
      switch $0.phase {
      case .authorizationRequired, .failed:
        return true
      default:
        return false
      }
    }) {
      return .attentionRequired
    }
    if statuses.contains(where: { if case .offline = $0.phase { true } else { false } }) {
      return .offline
    }
    if statuses.contains(where: {
      switch $0.phase {
      case .backfillPending, .syncing:
        return true
      default:
        return false
      }
    }) {
      return .synchronizing
    }
    return .upToDate
  }
}

struct AdvancedMailboxDiagnostic: Equatable {
  let lastSuccessfulSyncAt: Date?
  let provider: String
  let state: String

  static func make(
    connections: [MailboxConnection],
    status: (MailboxConnection) -> MailboxSyncStatus
  ) -> [Self] {
    connections.sorted { $0.id.rawValue < $1.id.rawValue }.map { connection in
      let status = status(connection)
      return AdvancedMailboxDiagnostic(
        lastSuccessfulSyncAt: status.lastSuccessfulSyncAt,
        provider: providerName(connection.providerId),
        state: diagnosticState(status.phase)
      )
    }
  }

  private static func diagnosticState(_ phase: MailboxSyncPhase) -> String {
    switch phase {
    case .authorizationRequired:
      return "authorization-required"
    case .backfillPending:
      return "backfill-pending"
    case .failed:
      return "failed"
    case .idle:
      return "idle"
    case .offline:
      return "offline"
    case .syncing:
      return "syncing"
    }
  }

  private static func providerName(_ providerId: MailProviderId) -> String {
    switch providerId {
    case .exchangeWebServices:
      return "Exchange Web Services"
    case .gmail:
      return "Gmail"
    case .imapSMTP:
      return "IMAP and SMTP"
    case .microsoftGraph:
      return "Microsoft Graph"
    case .pop3SMTP:
      return "POP3 and SMTP"
    default:
      return "Other"
    }
  }
}

struct AdvancedDiagnosticsSnapshot: Equatable {
  let appVersion: String
  let buildVersion: String
  let generatedAt: Date
  let mailboxes: [AdvancedMailboxDiagnostic]
  let operatingSystemVersion: String
  let productSyncHealth: AdvancedProductSyncHealth

  static func current(
    connections: [MailboxConnection],
    productSyncHealth: AdvancedProductSyncHealth,
    status: (MailboxConnection) -> MailboxSyncStatus,
    bundle: Bundle = .main,
    generatedAt: Date = Date(),
    operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
  ) -> Self {
    AdvancedDiagnosticsSnapshot(
      appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "Unknown",
      buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ?? "Unknown",
      generatedAt: generatedAt,
      mailboxes: AdvancedMailboxDiagnostic.make(connections: connections, status: status),
      operatingSystemVersion: operatingSystemVersion,
      productSyncHealth: productSyncHealth
    )
  }
}

struct AdvancedDiagnosticsReport: Equatable {
  let text: String

  init(snapshot: AdvancedDiagnosticsSnapshot, backendHealth: HealthResponse?) {
    var lines = [
      "Unwired Diagnostics",
      "Generated: \(snapshot.generatedAt.ISO8601Format())",
      "App version: \(snapshot.appVersion)",
      "Build: \(snapshot.buildVersion)",
      "Operating system: \(snapshot.operatingSystemVersion)",
      "Product Sync: \(snapshot.productSyncHealth.rawValue)",
      "Backend: \(backendHealth == nil ? "unavailable" : "healthy")",
      "Backend schema: \(backendHealth.map { String($0.bootstrapVersion) } ?? "unavailable")",
      "Mailbox connections: \(snapshot.mailboxes.count)",
    ]
    for (index, mailbox) in snapshot.mailboxes.enumerated() {
      let lastSuccess = mailbox.lastSuccessfulSyncAt?.ISO8601Format() ?? "never"
      lines.append(
        "Mailbox \(index + 1): provider=\(mailbox.provider); state=\(mailbox.state); "
          + "last-success=\(lastSuccess)"
      )
    }
    text = lines.joined(separator: "\n")
  }
}

enum AdvancedMaintenanceOperation: Equatable {
  case clearAndResynchronize
  case rebuildIndexes
}

enum AdvancedMaintenancePresentation {
  static func actionTitle(_ operation: AdvancedMaintenanceOperation) -> String {
    switch operation {
    case .clearAndResynchronize:
      return "Clear and Resynchronize"
    case .rebuildIndexes:
      return "Rebuild Indexes"
    }
  }

  static func confirmationMessage(_ operation: AdvancedMaintenanceOperation) -> String {
    switch operation {
    case .clearAndResynchronize:
      return
        "This removes device-local mailbox metadata, cached message bodies, and downloaded "
        + "incoming attachments, then resynchronizes. Provider mail, credentials, Drafts, "
        + "Product Sync data, Pending Provider Actions, and Outbox deliveries remain."
    case .rebuildIndexes:
      return
        "This removes only local search and metadata indexes, then fetches provider metadata "
        + "again. Cached bodies, attachments, credentials, Drafts, Product Sync data, queued "
        + "actions, Outbox deliveries, and provider mail remain."
    }
  }

  static func isDestructive(_ operation: AdvancedMaintenanceOperation) -> Bool {
    operation == .clearAndResynchronize
  }
}

enum AdvancedSettingsAccessibility {
  static let clearAndResynchronize = "Clear Local Mailbox Data and Resynchronize"
  static let exportReport = "Export Redacted Diagnostics Report"
  static let rebuildIndexes = "Rebuild Local Search and Metadata Indexes"
  static let runDiagnostics = "Run Privacy-Safe Diagnostics"
}

enum AdvancedMaintenanceOutcome: Equatable {
  case completed(String)
  case pending(String)

  var message: String {
    switch self {
    case .completed(let message), .pending(let message):
      return message
    }
  }
}

@MainActor
@Observable
final class AdvancedSettingsViewModel {
  typealias Maintenance = () async throws -> AdvancedMaintenanceOutcome

  private let backendHealth: (() async throws -> HealthResponse)?
  private let clearAndResynchronize: Maintenance?
  private let rebuildIndexes: Maintenance?

  private(set) var activeMaintenance: AdvancedMaintenanceOperation?
  private(set) var backendSchemaVersion: String?
  private(set) var diagnosticsAreRunning = false
  private(set) var diagnosticsNotice: String?
  private(set) var maintenanceError: String?
  private(set) var maintenanceOutcome: AdvancedMaintenanceOutcome?
  private(set) var report: String?

  init(
    backendHealth: (() async throws -> HealthResponse)? = nil,
    rebuildIndexes: Maintenance? = nil,
    clearAndResynchronize: Maintenance? = nil
  ) {
    self.backendHealth = backendHealth
    self.rebuildIndexes = rebuildIndexes
    self.clearAndResynchronize = clearAndResynchronize
  }

  var maintenanceIsAvailable: Bool {
    rebuildIndexes != nil && clearAndResynchronize != nil
  }

  func runDiagnostics(snapshot: AdvancedDiagnosticsSnapshot) async {
    guard !diagnosticsAreRunning else { return }
    diagnosticsAreRunning = true
    diagnosticsNotice = nil
    defer { diagnosticsAreRunning = false }

    let health: HealthResponse?
    if let backendHealth {
      do {
        health = try await backendHealth()
        backendSchemaVersion = health.map { String($0.bootstrapVersion) }
      } catch is CancellationError {
        return
      } catch {
        health = nil
        backendSchemaVersion = nil
        diagnosticsNotice =
          "The backend health check was unavailable. Local diagnostics are complete."
      }
    } else {
      health = nil
      backendSchemaVersion = nil
    }
    report = AdvancedDiagnosticsReport(snapshot: snapshot, backendHealth: health).text
  }

  func perform(_ operation: AdvancedMaintenanceOperation) async {
    guard activeMaintenance == nil else { return }
    let action =
      switch operation {
      case .clearAndResynchronize:
        clearAndResynchronize
      case .rebuildIndexes:
        rebuildIndexes
      }
    guard let action else { return }

    activeMaintenance = operation
    maintenanceError = nil
    maintenanceOutcome = nil
    defer { activeMaintenance = nil }
    do {
      maintenanceOutcome = try await action()
    } catch is CancellationError {
      return
    } catch {
      maintenanceError = error.localizedDescription
    }
  }
}

struct AdvancedSettingsView: View {
  let connections: [MailboxConnection]
  let productSyncHealth: AdvancedProductSyncHealth
  let status: (MailboxConnection) -> MailboxSyncStatus

  @State private var confirmation: AdvancedMaintenanceOperation?
  @State private var viewModel: AdvancedSettingsViewModel

  init(
    connections: [MailboxConnection],
    productSyncHealth: AdvancedProductSyncHealth,
    status: @escaping (MailboxConnection) -> MailboxSyncStatus,
    backendHealth: (() async throws -> HealthResponse)? = nil,
    rebuildIndexes: AdvancedSettingsViewModel.Maintenance? = nil,
    clearAndResynchronize: AdvancedSettingsViewModel.Maintenance? = nil
  ) {
    self.connections = connections
    self.productSyncHealth = productSyncHealth
    self.status = status
    _viewModel = State(
      initialValue: AdvancedSettingsViewModel(
        backendHealth: backendHealth,
        rebuildIndexes: rebuildIndexes,
        clearAndResynchronize: clearAndResynchronize
      )
    )
  }

  var body: some View {
    Form {
      diagnosticsSection
      maintenanceSection
      versionsSection
    }
    .confirmationDialog(
      confirmationTitle,
      isPresented: Binding(
        get: { confirmation != nil },
        set: { if !$0 { confirmation = nil } }
      ),
      titleVisibility: .visible,
      presenting: confirmation
    ) { operation in
      Button(
        AdvancedMaintenancePresentation.actionTitle(operation),
        role: AdvancedMaintenancePresentation.isDestructive(operation) ? .destructive : nil
      ) {
        confirmation = nil
        Task { await viewModel.perform(operation) }
      }
      Button("Cancel", role: .cancel) { confirmation = nil }
    } message: { operation in
      Text(AdvancedMaintenancePresentation.confirmationMessage(operation))
    }
  }

  private var diagnosticsSection: some View {
    Section {
      Button {
        Task { await viewModel.runDiagnostics(snapshot: diagnosticsSnapshot) }
      } label: {
        if viewModel.diagnosticsAreRunning {
          ProgressView()
        } else {
          Label("Run Diagnostics", systemImage: "stethoscope")
        }
      }
      .disabled(viewModel.diagnosticsAreRunning)
      .accessibilityLabel(AdvancedSettingsAccessibility.runDiagnostics)

      if let report = viewModel.report {
        ShareLink(item: report) {
          Label("Export Redacted Report", systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel(AdvancedSettingsAccessibility.exportReport)
      }
      if let notice = viewModel.diagnosticsNotice {
        Text(notice)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Diagnostics")
    } footer: {
      Text(
        "The report includes only allowlisted versions and health states. It excludes message "
          + "content, addresses, provider credentials, Categories, identifiers, and Product Sync plaintext."
      )
    }
  }

  @ViewBuilder
  private var maintenanceSection: some View {
    if viewModel.maintenanceIsAvailable {
      Section("Local Maintenance") {
        Button("Rebuild Local Search and Metadata Indexes") {
          confirmation = .rebuildIndexes
        }
        .disabled(viewModel.activeMaintenance != nil)
        .accessibilityLabel(AdvancedSettingsAccessibility.rebuildIndexes)

        Button("Clear Local Mailbox Data and Resynchronize", role: .destructive) {
          confirmation = .clearAndResynchronize
        }
        .disabled(viewModel.activeMaintenance != nil)
        .accessibilityLabel(AdvancedSettingsAccessibility.clearAndResynchronize)

        if viewModel.activeMaintenance != nil {
          ProgressView("Working…")
        }
        if let outcome = viewModel.maintenanceOutcome {
          Label(
            outcome.message,
            systemImage: outcomeImage(outcome)
          )
          .foregroundStyle(outcomeColor(outcome))
        }
        if let error = viewModel.maintenanceError {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
    }
  }

  private var versionsSection: some View {
    Section("Versions") {
      LabeledContent("App", value: diagnosticsSnapshot.appVersion)
      LabeledContent("Build", value: diagnosticsSnapshot.buildVersion)
      LabeledContent("Backend Schema", value: viewModel.backendSchemaVersion ?? "Run Diagnostics")
    }
  }

  private var diagnosticsSnapshot: AdvancedDiagnosticsSnapshot {
    .current(
      connections: connections,
      productSyncHealth: productSyncHealth,
      status: status
    )
  }

  private var confirmationTitle: String {
    guard let confirmation else { return "Local Maintenance" }
    return AdvancedMaintenancePresentation.actionTitle(confirmation)
  }

  private func outcomeColor(_ outcome: AdvancedMaintenanceOutcome) -> Color {
    switch outcome {
    case .completed:
      return .green
    case .pending:
      return .orange
    }
  }

  private func outcomeImage(_ outcome: AdvancedMaintenanceOutcome) -> String {
    switch outcome {
    case .completed:
      return "checkmark.circle"
    case .pending:
      return "clock.arrow.circlepath"
    }
  }
}
