import Foundation
import Testing

@testable import unwired_mail

@Suite(.serialized)
final class AdvancedSettingsTests {
  @Test
  func testOverallMailboxHealthSurfacesTheMostActionableState() {
    #expect(AdvancedMailboxSyncHealth.current([]) == .noConnections)
    #expect(
      AdvancedMailboxSyncHealth.current([
        MailboxSyncStatus(lastSuccessfulSyncAt: nil, phase: .idle),
        MailboxSyncStatus(lastSuccessfulSyncAt: nil, phase: .backfillPending),
      ]) == .synchronizing)
    #expect(
      AdvancedMailboxSyncHealth.current([
        MailboxSyncStatus(lastSuccessfulSyncAt: nil, phase: .offline),
        MailboxSyncStatus(lastSuccessfulSyncAt: nil, phase: .failed("private failure")),
      ]) == .attentionRequired)
  }

  @Test
  func testDiagnosticReportUsesAllowlistedMailboxFields() {
    let connection = makeConnection(displayName: "private@example.com")
    let snapshot = AdvancedDiagnosticsSnapshot(
      appVersion: "1.2.3",
      buildVersion: "45",
      generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      mailboxes: AdvancedMailboxDiagnostic.make(connections: [connection]) { _ in
        MailboxSyncStatus(
          lastSuccessfulSyncAt: Date(timeIntervalSince1970: 1_600_000_000),
          phase: .failed("token secret@example.com category Finance")
        )
      },
      operatingSystemVersion: "Test OS 1",
      productSyncHealth: .available
    )

    let report = AdvancedDiagnosticsReport(
      snapshot: snapshot,
      backendHealth: HealthResponse(
        bootstrapVersion: 7,
        serverTime: 1,
        service: "private-email-api",
        status: "ok"
      )
    ).text

    #expect(report.contains("Mailbox 1: provider=Gmail; state=failed"))
    #expect(report.contains("Backend schema: 7"))
    #expect(!report.contains("private@example.com"))
    #expect(!report.contains("secret"))
    #expect(!report.contains("Finance"))
    #expect(!report.contains("product-account-private"))
    #expect(!report.contains("trusted-device-private"))
  }

  @MainActor
  @Test
  func testUnavailableBackendStillProducesLocalDiagnosticReport() async {
    struct PrivateBackendError: LocalizedError {
      var errorDescription: String? { "backend secret token" }
    }
    let viewModel = AdvancedSettingsViewModel(
      backendHealth: { throw PrivateBackendError() }
    )
    let snapshot = AdvancedDiagnosticsSnapshot(
      appVersion: "1.2.3",
      buildVersion: "45",
      generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      mailboxes: [],
      operatingSystemVersion: "Test OS 1",
      productSyncHealth: .signedOut
    )

    await viewModel.runDiagnostics(snapshot: snapshot)

    #expect(viewModel.report?.contains("Backend: unavailable") == true)
    #expect(
      viewModel.diagnosticsNotice
        == "The backend health check was unavailable. Local diagnostics are complete.")
    #expect(viewModel.report?.contains("secret") == false)
    #expect(viewModel.backendSchemaVersion == nil)
  }

  @MainActor
  @Test(.bug(id: 132))
  func signedOutDiagnosticsNeverContactOrDescribeAccountServices() async {
    var backendRequestCount = 0
    let viewModel = AdvancedSettingsViewModel(
      backendHealth: {
        backendRequestCount += 1
        return HealthResponse(
          bootstrapVersion: 7,
          serverTime: 1,
          service: "private-email-api",
          status: "ok"
        )
      }
    )
    let snapshot = AdvancedDiagnosticsSnapshot(
      appVersion: "1.2.3",
      buildVersion: "45",
      generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      mailboxes: [],
      operatingSystemVersion: "Test OS 1",
      productSyncHealth: .signedOut
    )

    await viewModel.runDiagnostics(snapshot: snapshot, includesAccountHealth: false)

    #expect(backendRequestCount == 0)
    #expect(viewModel.report?.contains("App version: 1.2.3") == true)
    #expect(viewModel.report?.contains("Operating system: Test OS 1") == true)
    #expect(viewModel.report?.contains("Product Sync") == false)
    #expect(viewModel.report?.contains("Backend") == false)
    #expect(viewModel.report?.contains("Mailbox connections") == false)
  }

  @MainActor
  @Test
  func testOfflineMaintenanceOutcomeRemainsPending() async {
    var rebuildCount = 0
    let viewModel = AdvancedSettingsViewModel(
      rebuildIndexes: {
        rebuildCount += 1
        return .pending("Resynchronization will resume when this device is online.")
      },
      clearAndResynchronize: {
        Issue.record("Unexpected clear operation")
        return .completed("Unexpected")
      }
    )

    await viewModel.perform(.rebuildIndexes)

    #expect(rebuildCount == 1)
    #expect(
      viewModel.maintenanceOutcome
        == .pending("Resynchronization will resume when this device is online."))
    #expect(viewModel.maintenanceError == nil)
    #expect(viewModel.activeMaintenance == nil)
  }

  @MainActor
  @Test
  func testMaintenanceFailureIsVisibleAndRetryable() async {
    struct MaintenanceError: LocalizedError {
      var errorDescription: String? { "Local metadata store is unavailable." }
    }
    var attempts = 0
    let viewModel = AdvancedSettingsViewModel(
      rebuildIndexes: {
        attempts += 1
        if attempts == 1 { throw MaintenanceError() }
        return .completed("Rebuilt")
      },
      clearAndResynchronize: { .completed("Cleared") }
    )

    await viewModel.perform(.rebuildIndexes)
    #expect(viewModel.maintenanceError == "Local metadata store is unavailable.")

    await viewModel.perform(.rebuildIndexes)
    #expect(viewModel.maintenanceOutcome == .completed("Rebuilt"))
    #expect(viewModel.maintenanceError == nil)
    #expect(attempts == 2)
  }

  @Test
  func testDestructiveConfirmationExplainsPreservedData() {
    let message = AdvancedMaintenancePresentation.confirmationMessage(.clearAndResynchronize)

    #expect(AdvancedMaintenancePresentation.isDestructive(.clearAndResynchronize))
    #expect(!AdvancedMaintenancePresentation.isDestructive(.rebuildIndexes))
    #expect(message.contains("Provider mail"))
    #expect(message.contains("credentials"))
    #expect(message.contains("Drafts"))
    #expect(message.contains("Product Sync data"))
    #expect(message.contains("Pending Provider Actions"))
    #expect(message.contains("Outbox deliveries"))
  }

  @Test
  func testAdvancedActionsHaveDistinctAccessibilityLabels() {
    let labels = [
      AdvancedSettingsAccessibility.runDiagnostics,
      AdvancedSettingsAccessibility.exportReport,
      AdvancedSettingsAccessibility.rebuildIndexes,
      AdvancedSettingsAccessibility.clearAndResynchronize,
    ]

    #expect(Set(labels).count == labels.count)
    #expect(AdvancedSettingsAccessibility.exportReport.contains("Redacted"))
    #expect(AdvancedSettingsAccessibility.clearAndResynchronize.contains("Resynchronize"))
  }

  private func makeConnection(displayName: String) -> MailboxConnection {
    MailboxConnection(
      authorizationState: .authorized,
      capabilities: .none,
      connectedAt: 1,
      displayName: displayName,
      id: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .gmail,
          value: displayName
        )
      ),
      lastVerifiedAt: 1,
      productAccountId: ProductAccountId("product-account-private"),
      trustedDeviceId: "trusted-device-private",
      updatedAt: 1
    )
  }
}
