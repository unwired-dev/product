import Foundation
import Testing

@testable import unwired_mail

struct MailAssistanceQualificationTests {
  @Test("Version 1 covers every accepted assistance qualification risk", .bug(id: 416))
  func corpusCoverageIsComplete() {
    let corpus = MailAssistanceQualificationCorpus.version1
    let coverage = corpus.scenarios.reduce(into: Set<MailAssistanceQualificationCorpus.Coverage>())
    {
      $0.formUnion($1.coverage)
    }
    let rewritePresets = Set(
      corpus.scenarios.compactMap { scenario -> ComposeAssistancePreset? in
        guard case .rewrite(let preset) = scenario.operation else { return nil }
        return preset
      }
    )
    let locales = Set(corpus.scenarios.map(\.localeIdentifier))

    #expect(corpus.version == 1)
    #expect(coverage == Set(MailAssistanceQualificationCorpus.Coverage.allCases))
    #expect(rewritePresets == Set(ComposeAssistancePreset.allCases))
    #expect(locales.isSuperset(of: ["en_US", "de_DE", "fr_FR", "es_ES", "ja_JP"]))
  }

  @Test("Deterministic engines pass the shared semantic qualification contract", .bug(id: 416))
  func deterministicEnginesPassQualification() async throws {
    let corpus = MailAssistanceQualificationCorpus.version1
    let evaluator = MailAssistanceQualificationEvaluator()
    var reports: [MailAssistanceQualificationEvaluator.ScenarioReport] = []

    for scenario in corpus.scenarios {
      if scenario.isGenerative {
        let request = try #require(scenario.makeRequest())
        let outcome = try #require(scenario.deterministicOutcome())
        let preview = try await DeterministicMailAssistanceEngine(outcome: outcome).generate(
          request)
        reports.append(evaluator.evaluate(evaluator.result(from: preview), for: scenario))
      } else {
        reports.append(evaluator.evaluate(scenario.referenceResult, for: scenario))
      }
    }

    let summary = MailAssistanceQualificationEvaluator.Summary(
      corpus: corpus,
      reports: reports
    )
    Attachment.record(summary, named: "Mail Assistance qualification v1 deterministic evidence")
    #expect(summary.passed)
  }

  @Test("Qualification evidence excludes every synthetic input and output", .bug(id: 416))
  func evidenceIsContentFree() throws {
    let corpus = MailAssistanceQualificationCorpus.version1
    let evaluator = MailAssistanceQualificationEvaluator()
    let reports = corpus.scenarios.map {
      evaluator.evaluate($0.referenceResult, for: $0, durationMilliseconds: 12)
    }
    let summary = MailAssistanceQualificationEvaluator.Summary(
      corpus: corpus,
      reports: reports
    )
    let encoded = try JSONEncoder().encode(summary)
    let evidence = try #require(String(data: encoded, encoding: .utf8))
    let contentBearingValues = corpus.scenarios.flatMap { scenario in
      [scenario.authoredBody, scenario.subject, scenario.referenceResult.text]
        + scenario.sourceMessages.map(\.body)
    }.filter { $0.isEmpty == false }

    for content in contentBearingValues {
      #expect(evidence.contains(content) == false)
    }
  }

  @Test("The scorer rejects invented facts, missing sources, and collapsed replies", .bug(id: 416))
  func semanticFailuresAreScoredWithoutCapturingContent() throws {
    let corpus = MailAssistanceQualificationCorpus.version1
    let responseScenario = try #require(
      corpus.scenarios.first { $0.id == "response-budget-and-venue" }
    )
    let badResult = MailAssistanceQualificationCorpus.CandidateResult(
      text: "The budget is EUR 1,500 on Thursday.",
      suggestions: [
        .init(intent: "Repeat", text: "Same reply"),
        .init(intent: "Repeat", text: "Same reply"),
        .init(intent: "Repeat", text: "Same reply"),
      ]
    )
    let report = MailAssistanceQualificationEvaluator().evaluate(
      badResult,
      for: responseScenario
    )
    let failedChecks = Set(report.checks.filter { $0.passed == false }.map(\.check))

    #expect(report.passed == false)
    #expect(failedChecks.contains(.forbiddenTerms))
    #expect(failedChecks.contains(.requiredSourceAttribution))
    #expect(failedChecks.contains(.requiredTermRecall))
    #expect(failedChecks.contains(.responseDiversity))
    #expect(failedChecks.contains(.unresolvedQuestion))
  }

  @MainActor
  @Test("No model generation starts before the explicit assistance action", .bug(id: 416))
  func lifecycleRequiresExplicitGeneration() async throws {
    let probe = GenerationProbe()
    let engine = ProbeEngine(probe: probe)
    let corpus = MailAssistanceQualificationCorpus.version1
    let request = try #require(corpus.scenarios.first?.makeRequest())

    #expect(await probe.generationCount == 0)
    _ = await engine.availability(for: request.localeIdentifier)
    #expect(await probe.generationCount == 0)
    _ = try await engine.generate(request)
    #expect(await probe.generationCount == 1)
  }

  private actor GenerationProbe {
    private(set) var generationCount = 0

    func recordGeneration() {
      generationCount += 1
    }
  }

  private struct ProbeEngine: MailAssistanceEngine {
    let probe: GenerationProbe

    func availability(for _: String) async -> MailAssistanceAvailability {
      .available
    }

    func generate(_ request: MailAssistanceRequest) async throws -> MailAssistancePreview {
      await probe.recordGeneration()
      return MailAssistancePreview(
        content: "Synthetic result",
        inputVersion: request.context.inputVersion,
        kind: .content,
        profileId: request.context.profileId
      )
    }
  }
}
