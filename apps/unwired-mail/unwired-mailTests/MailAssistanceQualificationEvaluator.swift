import Foundation
import Testing

@testable import unwired_mail

struct MailAssistanceQualificationEvaluator {
  enum Check: String, Codable, CaseIterable, Sendable {
    case expectedKind
    case forbiddenTerms
    case requiredSourceAttribution
    case requiredTermRecall
    case responseDiversity
    case unresolvedQuestion
  }

  struct CheckResult: Codable, Equatable, Sendable {
    let check: Check
    let passed: Bool
  }

  struct ScenarioReport: Codable, Equatable, Sendable {
    let capability: MailAssistanceQualificationCorpus.Capability
    let checks: [CheckResult]
    let durationMilliseconds: Int64
    let passed: Bool
    let scenarioId: String
    let score: Double
  }

  struct Summary: Attachable, Codable, Equatable, Sendable {
    let aggregateScore: Double
    let corpusVersion: Int
    let minimumAggregateScore: Double
    let passed: Bool
    let scenarios: [ScenarioReport]

    init(
      corpus: MailAssistanceQualificationCorpus,
      reports: [ScenarioReport]
    ) {
      aggregateScore =
        reports.isEmpty
        ? 0
        : reports.reduce(0) { $0 + $1.score } / Double(reports.count)
      corpusVersion = corpus.version
      minimumAggregateScore = corpus.minimumAggregateScore
      passed =
        reports.count == corpus.scenarios.count
        && reports.allSatisfy(\.passed)
        && aggregateScore >= corpus.minimumAggregateScore
      scenarios = reports
    }
  }

  func evaluate(
    _ result: MailAssistanceQualificationCorpus.CandidateResult,
    for scenario: MailAssistanceQualificationCorpus.Scenario,
    durationMilliseconds: Int64 = 0
  ) -> ScenarioReport {
    let normalizedText = normalized(result.text)
    let rememberedTerms = scenario.requiredTerms.count { term in
      normalizedText.contains(normalized(term))
    }
    let recall =
      scenario.requiredTerms.isEmpty
      ? 1
      : Double(rememberedTerms) / Double(scenario.requiredTerms.count)
    let forbiddenTermsAreAbsent = scenario.forbiddenTerms.allSatisfy { term in
      normalizedText.contains(normalized(term)) == false
    }
    let distinctIntents = Set(result.suggestions.map { normalized($0.intent) })
    let distinctSuggestions = Set(result.suggestions.map { normalized($0.text) })
    let responseIsDiverse =
      scenario.minimumDistinctSuggestions == 0
      || (distinctIntents.count >= scenario.minimumDistinctSuggestions
        && distinctSuggestions.count >= scenario.minimumDistinctSuggestions)
    let sourceAttributionPasses = scenario.requiredSourceMessageIds.isSubset(
      of: result.sourceMessageIds
    )
    let hasUnresolvedQuestion =
      scenario.requiresUnresolvedCompletenessItem == false
      || result.completenessItems.contains { $0.status == .unresolved }
    let checks = [
      CheckResult(check: .expectedKind, passed: result.kind == scenario.expectedKind),
      CheckResult(check: .forbiddenTerms, passed: forbiddenTermsAreAbsent),
      CheckResult(check: .requiredSourceAttribution, passed: sourceAttributionPasses),
      CheckResult(check: .requiredTermRecall, passed: recall >= scenario.minimumTermRecall),
      CheckResult(check: .responseDiversity, passed: responseIsDiverse),
      CheckResult(check: .unresolvedQuestion, passed: hasUnresolvedQuestion),
    ]
    let score = Double(checks.count(where: \.passed)) / Double(checks.count)
    return ScenarioReport(
      capability: scenario.capability,
      checks: checks,
      durationMilliseconds: durationMilliseconds,
      passed: checks.allSatisfy(\.passed),
      scenarioId: scenario.id,
      score: score
    )
  }

  func result(
    from preview: MailAssistancePreview
  ) -> MailAssistanceQualificationCorpus.CandidateResult {
    let suggestions =
      preview.response?.suggestions.map {
        MailAssistanceQualificationCorpus.Suggestion(
          intent: $0.intent,
          text: $0.document.plainText
        )
      } ?? []
    let completenessItems =
      preview.response?.completenessItems.map {
        MailAssistanceQualificationCorpus.CompletenessItem(
          kind: $0.kind,
          sourceMessageIds: $0.sourceMessageIds,
          status: $0.status,
          text: $0.text
        )
      } ?? []
    let responseSourceIds = completenessItems.flatMap(\.sourceMessageIds)
    let understandingSourceIds = preview.understanding?.items.flatMap(\.sourceMessageIds) ?? []
    return MailAssistanceQualificationCorpus.CandidateResult(
      text: preview.content,
      kind: preview.kind == .clarification ? .clarification : .content,
      suggestions: suggestions,
      completenessItems: completenessItems,
      sourceMessageIds: Set(responseSourceIds + understandingSourceIds)
    )
  }

  private func normalized(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }
}
