import Foundation

public enum QualificationEvidenceVerifier {
  static let requiredCheckNames: Set<String> = [
    "IDLE renewal and cancellation",
    "SMTP delivery and verified Sent append",
    "authentication",
    "complete-history backfill",
    "incremental reconciliation",
    "missing-role creation state",
    "newest-50 metadata",
    "permitted missing-role creation",
    "provider-backed body search",
    "read and unread mutations",
    "run-scoped cleanup",
    "selected body-part fetch",
    "spam-state mutation",
    "trustworthy mailbox-role discovery",
  ]

  static let requiredMetricNames: Set<String> = [
    "100-message-reconciliation",
    "complete-history-backfill",
    "initial-mailbox-availability",
    "no-change-reconciliation",
  ]

  public static func verify(reportURLs: [URL]) throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    try verify(
      reports: reportURLs.map { url in
        try decoder.decode(QualificationReport.self, from: Data(contentsOf: url))
      }
    )
  }

  public static func verify(reports: [QualificationReport]) throws {
    guard reports.count == QualificationProvider.allCases.count,
      QualificationProvider.allCases.allSatisfy({ provider in
        reports.count(where: { $0.provider == provider }) == 1
      })
    else {
      throw QualificationError.failed(
        "Final evidence requires exactly one iCloud Mail report and one Fastmail report."
      )
    }

    for report in reports {
      try verify(report: report)
    }
  }

  private static func verify(report: QualificationReport) throws {
    guard report.swiftMailVersion == QualificationReport.swiftMailVersion,
      report.swiftMailCommit == QualificationReport.swiftMailCommit
    else {
      throw QualificationError.failed(
        "\(report.provider.displayName) evidence does not match the qualified SwiftMail pin."
      )
    }
    guard !report.preparedDataset else {
      throw QualificationError.failed(
        "\(report.provider.displayName) evidence came from dataset preparation, not a final run."
      )
    }
    guard report.startedAt <= report.completedAt else {
      throw QualificationError.failed(
        "\(report.provider.displayName) evidence has an invalid time range."
      )
    }
    guard report.passed, !report.checks.isEmpty, report.checks.allSatisfy(\.passed) else {
      throw QualificationError.failed(
        "\(report.provider.displayName) evidence contains a failed qualification check."
      )
    }

    let missingChecks = requiredCheckNames.subtracting(report.checks.map(\.name))
    guard missingChecks.isEmpty else {
      throw QualificationError.failed(
        "\(report.provider.displayName) evidence is missing required checks: "
          + missingChecks.sorted().joined(separator: ", ")
      )
    }

    let missingMetrics = requiredMetricNames.subtracting(report.metrics.keys)
    guard missingMetrics.isEmpty else {
      throw QualificationError.failed(
        "\(report.provider.displayName) evidence is missing required metrics: "
          + missingMetrics.sorted().joined(separator: ", ")
      )
    }
    for metricName in requiredMetricNames {
      guard let metrics = report.metrics[metricName] else {
        throw QualificationError.failed(
          "\(report.provider.displayName) evidence violates ADR 0027 for \(metricName)."
        )
      }
      var violations = QualificationBudget.adr0027.violations(in: metrics)
      if metricName == "complete-history-backfill" {
        violations.removeAll { $0 == "request count exceeded 20" }
        let pageCount = Int(
          ceil(Double(QualificationConfiguration.datasetMessageCount) / 500)
        )
        if metrics.requestCount > pageCount * 2 + 10 {
          violations.append("complete-history request count exceeded the page budget")
        }
      }
      guard violations.isEmpty else {
        throw QualificationError.failed(
          "\(report.provider.displayName) evidence violates ADR 0027 for \(metricName)."
        )
      }
    }
  }
}
