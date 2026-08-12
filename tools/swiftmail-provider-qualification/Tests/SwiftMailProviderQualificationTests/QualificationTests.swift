import Foundation
import SwiftMail
import Testing

@testable import SwiftMailProviderQualification

@Test
func configurationNamesMissingProtectedValuesWithoutEchoingSecrets() throws {
  let secret = "private-password"
  do {
    _ = try QualificationConfiguration.load(
      provider: .icloud,
      environment: ["ICLOUD_QUALIFICATION_PASSWORD": secret]
    )
    Issue.record("Expected the missing iCloud email value to fail configuration.")
  } catch {
    #expect(error.localizedDescription.contains("ICLOUD_QUALIFICATION_EMAIL"))
    #expect(!error.localizedDescription.contains(secret))
  }

  let configuration = try QualificationConfiguration.load(
    provider: .fastmail,
    environment: [
      "FASTMAIL_QUALIFICATION_EMAIL": "fixture@example.test",
      "FASTMAIL_QUALIFICATION_PASSWORD": "private-password",
    ]
  )
  #expect(configuration.provider == .fastmail)
  #expect(configuration.datasetMailbox == "Unwired Qualification Dataset")
}

@Test
func datasetMessageHasExactSizeAndFixtureMarker() {
  let message = QualificationMessages.datasetMessage(
    index: 42,
    recipient: "fixture@example.test"
  )
  #expect(message.utf8.count == QualificationConfiguration.datasetMessageSize)
  #expect(message.contains("X-Unwired-Qualification-Dataset: v1"))
  #expect(message.contains("dataset-00042@qualification.invalid"))
  #expect(message.contains("Date: Thu, 1 Jan 1970 00:00:00 +0000\r\n"))
}

@Test
func roleResolutionUsesAttributesOrExactMappingsOnly() throws {
  let mailboxes = [
    Mailbox.Info(name: "INBOX", attributes: [], hierarchyDelimiter: "/"),
    Mailbox.Info(name: "Localized Sent", attributes: [.sent], hierarchyDelimiter: "/"),
    Mailbox.Info(name: "Mapped Junk", attributes: [], hierarchyDelimiter: "/"),
    Mailbox.Info(name: "Looks Like Junk", attributes: [], hierarchyDelimiter: "/"),
  ]

  let sent = try MailboxRoleResolver.resolve(.sent, from: mailboxes, explicitName: nil)
  let junk = try MailboxRoleResolver.resolve(
    .junk,
    from: mailboxes,
    explicitName: "Mapped Junk"
  )
  #expect(sent.source == "special-use")
  #expect(junk.source == "explicit-validated")
  #expect(throws: QualificationError.self) {
    try MailboxRoleResolver.resolve(.junk, from: mailboxes, explicitName: nil)
  }
}

@Test
func adrBudgetReportsEveryExceededLimit() {
  let metrics = QualificationMetrics(
    decodedBytes: 5 * 1024 * 1024 + 1,
    mainThreadStallMilliseconds: 101,
    maximumPageSize: 501,
    peakResidentMemoryIncreaseBytes: 100 * 1024 * 1024 + 1,
    processCPUSeconds: 1,
    providerAndNetworkSeconds: 2,
    requestCount: 21,
    wallClockSeconds: 3
  )
  #expect(QualificationBudget.adr0027.violations(in: metrics).count == 5)
}

@Test
func evidenceContainsTheExactPinAndNoCredentials() throws {
  let report = QualificationReport(
    checks: [QualificationCheck(name: "authentication", passed: true, detail: "passed")],
    completedAt: Date(timeIntervalSince1970: 2),
    metrics: [:],
    passed: true,
    preparedDataset: false,
    provider: .icloud,
    startedAt: Date(timeIntervalSince1970: 1)
  )
  let data = try JSONEncoder().encode(report)
  let text = try #require(String(data: data, encoding: .utf8))
  #expect(text.contains("1.10.0"))
  #expect(text.contains(QualificationReport.swiftMailCommit))
  #expect(!text.contains("password"))
  #expect(!text.contains("fixture@example.test"))
}

@Test
func finalEvidenceRequiresCompleteNonPreparationReportsForBothProviders() throws {
  let icloud = completeReport(provider: .icloud)
  let fastmail = completeReport(provider: .fastmail)

  try QualificationEvidenceVerifier.verify(reports: [icloud, fastmail])
  #expect(throws: QualificationError.self) {
    try QualificationEvidenceVerifier.verify(
      reports: [icloud, completeReport(provider: .fastmail, preparedDataset: true)]
    )
  }
  #expect(throws: QualificationError.self) {
    try QualificationEvidenceVerifier.verify(reports: [icloud, icloud])
  }

  try QualificationEvidenceVerifier.verify(
    reports: [icloud, completeReport(provider: .fastmail, completeHistoryRequestCount: 21)]
  )
  #expect(throws: QualificationError.self) {
    try QualificationEvidenceVerifier.verify(
      reports: [icloud, completeReport(provider: .fastmail, completeHistoryRequestCount: 51)]
    )
  }
}

private func completeReport(
  provider: QualificationProvider,
  preparedDataset: Bool = false,
  completeHistoryRequestCount: Int = 0
) -> QualificationReport {
  let checks = QualificationEvidenceVerifier.requiredCheckNames.map {
    QualificationCheck(name: $0, passed: true, detail: "passed")
  }
  let metrics = Dictionary(
    uniqueKeysWithValues: QualificationEvidenceVerifier.requiredMetricNames.map {
      (
        $0,
        QualificationMetrics(
          decodedBytes: 0,
          mainThreadStallMilliseconds: 0,
          maximumPageSize: 0,
          peakResidentMemoryIncreaseBytes: 0,
          processCPUSeconds: 0,
          providerAndNetworkSeconds: 0,
          requestCount: $0 == "complete-history-backfill" ? completeHistoryRequestCount : 0,
          wallClockSeconds: 0
        )
      )
    }
  )
  return QualificationReport(
    checks: checks,
    completedAt: Date(timeIntervalSince1970: 2),
    metrics: metrics,
    passed: true,
    preparedDataset: preparedDataset,
    provider: provider,
    startedAt: Date(timeIntervalSince1970: 1)
  )
}
