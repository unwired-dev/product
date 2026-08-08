import Foundation
import SwiftMail
import Testing

@testable import SwiftMailProviderQualification

@Test
func configurationNamesMissingProtectedValuesWithoutEchoingSecrets() throws {
  #expect(throws: QualificationError.self) {
    try QualificationConfiguration.load(provider: .icloud, environment: [:])
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
