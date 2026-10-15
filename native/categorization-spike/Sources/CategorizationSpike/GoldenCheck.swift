import Foundation

// The frozen #829 golden outputs: committed synthetic messages, token ids and fp32 scores.
public struct Golden: Decodable, Sendable {
  public struct Run: Decodable, Sendable {
    public let run: String
    public let outputs: [Output]
  }
  public struct Output: Decodable, Sendable {
    public let message: String
    public let category: String?
    public let input_ids: [Int32]
    public let probabilities: [String: Double]?
    public let categories: [String]?
    public let entailment_probability: Double?
    public let member: Bool?
  }
  public let messages: [Message]
  public let custom: [Run]
  public let system: [Run]
}

// Compares a loaded candidate with its golden outputs: token ids, scores and decisions.
public enum GoldenCheck {
  public struct Report: Encodable, Sendable {
    public var checked = 0
    public var tokenMismatches: [String] = []
    public var maxAbsProbabilityDifference = 0.0
    public var decisionChanges: [String] = []
  }

  public static func run(
    _ candidate: Candidate, golden: Golden, categories: [CustomCategory],
    cancelled: () -> Bool = { false }
  ) throws -> Report {
    var report = Report()
    let run = candidate.manifest.run
    for message in golden.messages {
      if let system = golden.system.first(where: { $0.run == run }),
        let output = system.outputs.first(where: { $0.message == message.id })
      {
        if candidate.systemIds(message) != output.input_ids { report.tokenMismatches.append(message.id) }
        let result = try candidate.classify(message, cancelled: cancelled)
        for score in result.scores {
          report.compare(score.probability, output.probabilities?[score.category])
        }
        if result.categories != output.categories {
          report.decisionChanges.append("\(message.id): \(result.categories)")
        }
        report.checked += 1
      }
      if let custom = golden.custom.first(where: { $0.run == run }) {
        let outputs = custom.outputs.filter { $0.message == message.id }
        let wanted = outputs.compactMap { output in categories.first { $0.id == output.category } }
        for (category, output) in zip(wanted, outputs)
        where try candidate.pairIds(message, category) != output.input_ids {
          report.tokenMismatches.append("\(message.id) \(category.id)")
        }
        let result = try candidate.classify(message, categories: wanted, cancelled: cancelled)
        for (score, output) in zip(result.scores, outputs) {
          report.compare(score.probability, output.entailment_probability)
          if score.member != output.member {
            report.decisionChanges.append("\(message.id) \(score.category): \(score.member)")
          }
          report.checked += 1
        }
      }
    }
    return report
  }
}

extension GoldenCheck.Report {
  fileprivate mutating func compare(_ probability: Double, _ expected: Double?) {
    maxAbsProbabilityDifference = max(
      maxAbsProbabilityDifference, abs(probability - (expected ?? .infinity)))
  }
}
