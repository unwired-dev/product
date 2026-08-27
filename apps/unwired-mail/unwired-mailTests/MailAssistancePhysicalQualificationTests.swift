import Foundation
import Testing

@testable import unwired_mail

struct MailAssistancePhysicalQualificationTests {
  @Test(
    "The system model passes the versioned synthetic corpus",
    .bug(id: 416),
    .disabled(
      if: MailAssistancePhysicalQualification.isDisabled,
      "Requires the protected physical-device qualification workflow."
    ),
    .timeLimit(.minutes(30))
  )
  func systemModelPassesSyntheticCorpus() async throws {
    let corpus = MailAssistanceQualificationCorpus.version1
    let engine = SystemMailAssistanceEngine()
    let evaluator = MailAssistanceQualificationEvaluator()
    let clock = ContinuousClock()
    var reports: [MailAssistanceQualificationEvaluator.ScenarioReport] = []

    for scenario in corpus.scenarios where scenario.isGenerative {
      let request = try #require(scenario.makeRequest())
      let availability = await engine.availability(for: scenario.localeIdentifier)
      guard availability == .available else {
        Issue.record("Scenario \(scenario.id) is unavailable on the qualification device.")
        continue
      }
      let start = clock.now
      do {
        let preview = try await engine.generate(request)
        let duration = start.duration(to: clock.now)
        let report = evaluator.evaluate(
          evaluator.result(from: preview),
          for: scenario,
          durationMilliseconds: Self.milliseconds(duration)
        )
        reports.append(report)
        #expect(report.passed, "Scenario \(scenario.id) failed its semantic threshold.")
      } catch {
        Issue.record("Scenario \(scenario.id) failed with \(String(describing: error)).")
      }
    }

    let translationReport = evaluator.evaluate(
      try #require(corpus.scenarios.first { $0.capability == .translation }).referenceResult,
      for: try #require(corpus.scenarios.first { $0.capability == .translation })
    )
    reports.append(translationReport)
    let summary = MailAssistanceQualificationEvaluator.Summary(
      corpus: corpus,
      reports: reports
    )
    Attachment.record(summary, named: "Mail Assistance qualification v1 physical evidence")
    #expect(summary.passed)
  }

  private static func milliseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
  }
}

private enum MailAssistancePhysicalQualification {
  #if MAIL_ASSISTANCE_PHYSICAL_QUALIFICATION
    static let isDisabled = false
  #else
    static let isDisabled = true
  #endif
}
