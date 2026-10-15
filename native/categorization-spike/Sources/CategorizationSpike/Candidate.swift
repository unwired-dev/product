import CoreML
import Foundation

// What tools/deberta-mac-spike/export.py writes beside each compiled candidate.
public struct Manifest: Codable, Sendable {
  public enum Labels: Codable, Sendable {
    case system([String])
    case custom(entailment: Int, negative: Int)

    private struct Pair: Codable { let entailment: Int; let negative: Int }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let names = try? container.decode([String].self) {
        self = .system(names)
      } else {
        let pair = try container.decode(Pair.self)
        self = .custom(entailment: pair.entailment, negative: pair.negative)
      }
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .system(let names): try container.encode(names)
      case .custom(let entailment, let negative):
        try container.encode(Pair(entailment: entailment, negative: negative))
      }
    }
  }

  public let run: String
  public let mode: String
  public let max_length: Int
  public let thresholds: [String: Double]
  public let labels: Labels
  public let hypothesis: [String: String]?
}

// One score and decision per System or Custom Category.
public struct Score: Codable, Sendable, Equatable {
  public let category: String
  public let probability: Double
  public let threshold: Double
  public let member: Bool
}

// Category decisions for one message, with the evidence of how they were produced.
public struct Classification: Codable, Sendable {
  public let message: String
  public let scores: [Score]
  // Empty means the Uncategorized State: the candidate abstains.
  public let categories: [String]
  public let tokens: [Int]
  public let passes: Int
  public let milliseconds: [Double]
}

public enum Precision: String, Codable, Sendable, CaseIterable { case fp16, int8 }

public enum Units: String, Codable, Sendable, CaseIterable {
  case cpuOnly, cpuAndGPU, cpuAndNeuralEngine, all

  var computeUnits: MLComputeUnits {
    switch self {
    case .cpuOnly: .cpuOnly
    case .cpuAndGPU: .cpuAndGPU
    case .cpuAndNeuralEngine: .cpuAndNeuralEngine
    case .all: .all
    }
  }
}

// A loaded candidate: its tokenizer, policy and Core ML model on the chosen compute units.
public final class Candidate: @unchecked Sendable {
  public let manifest: Manifest
  public let precision: Precision
  public let units: Units
  public let loadMilliseconds: Double
  let tokenizer: Tokenizer
  let model: MLModel
  let url: URL

  public init(directory: URL, precision: Precision, units: Units) throws {
    let manifestURL = directory.appending(path: "manifest.json")
    let modelURL = directory.appending(path: "\(precision.rawValue).mlmodelc")
    guard FileManager.default.fileExists(atPath: modelURL.path),
      FileManager.default.fileExists(atPath: manifestURL.path)
    else { throw SpikeError.missing(directory.lastPathComponent) }
    manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    self.precision = precision
    self.units = units
    url = modelURL
    let start = ContinuousClock.now
    tokenizer = try Tokenizer(contentsOf: directory.appending(path: "tokenizer.json"))
    let configuration = MLModelConfiguration()
    configuration.computeUnits = units.computeUnits
    model = try MLModel(contentsOf: modelURL, configuration: configuration)
    loadMilliseconds = Self.milliseconds(ContinuousClock.now - start)
  }

  static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }

  public func systemIds(_ message: Message) -> [Int32] {
    Encoding.single(tokenizer.encode(Input.text(message)), maxLength: manifest.max_length)
  }

  public func pairIds(_ message: Message, _ category: CustomCategory) throws -> [Int32] {
    let hypothesis = Input.hypothesis(
      category, language: message.language, template: manifest.hypothesis ?? [:])
    return try Encoding.pair(
      premise: tokenizer.encode(Input.text(message)), hypothesis: tokenizer.encode(hypothesis),
      maxLength: manifest.max_length)
  }

  // Raw logits for one padded pass.
  public func logits(_ ids: [Int32]) throws -> [Double] {
    let length = manifest.max_length
    let input = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
    let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
    for index in 0..<length {
      input[index] = NSNumber(value: index < ids.count ? ids[index] : Tokenizer.pad)
      mask[index] = NSNumber(value: index < ids.count ? 1 : 0)
    }
    let features = try MLDictionaryFeatureProvider(dictionary: [
      "input_ids": MLFeatureValue(multiArray: input),
      "attention_mask": MLFeatureValue(multiArray: mask),
    ])
    guard let output = try model.prediction(from: features).featureValue(for: "logits")?.multiArrayValue
    else { throw SpikeError.unsupported("model returned no logits") }
    return (0..<output.count).map { output[$0].doubleValue }
  }

  // Classifies one message; `cancelled` is checked before every model pass so dismissal stops
  // work between passes and never publishes a partial result.
  public func classify(
    _ message: Message, categories: [CustomCategory] = [], cancelled: () -> Bool = { false }
  ) throws -> Classification {
    var milliseconds: [Double] = []
    func pass(_ ids: [Int32]) throws -> [Double] {
      if cancelled() { throw SpikeError.cancelled }
      let start = ContinuousClock.now
      let logits = try logits(ids)
      milliseconds.append(Self.milliseconds(ContinuousClock.now - start))
      guard logits.allSatisfy(\.isFinite) else { throw SpikeError.unsupported("non-finite logits") }
      return logits
    }
    switch manifest.labels {
    case .system(let names):
      let ids = systemIds(message)
      let probabilities = try pass(ids).map { 1 / (1 + exp(-$0)) }
      let scores = Policy.system(names: names, probabilities: probabilities, thresholds: manifest.thresholds)
      return Classification(
        message: message.id, scores: scores, categories: scores.filter(\.member).map(\.category),
        tokens: [ids.count], passes: 1, milliseconds: milliseconds)
    case .custom(let entailment, let negative):
      let threshold = manifest.thresholds[message.language] ?? 1
      var scores: [Score] = []
      var tokens: [Int] = []
      for category in categories {
        let ids = try pairIds(message, category)
        tokens.append(ids.count)
        let logits = try pass(ids)
        let probability = Policy.entailment(logits[entailment], logits[negative])
        scores.append(
          Score(
            category: category.id, probability: probability, threshold: threshold,
            member: probability >= threshold))
      }
      return Classification(
        message: message.id, scores: scores, categories: scores.filter(\.member).map(\.category),
        tokens: tokens, passes: categories.count, milliseconds: milliseconds)
    }
  }

  // Where Core ML plans to run each operation, and which ones the Neural Engine cannot take.
  public func computePlan() async throws -> [String: Any] {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = units.computeUnits
    let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
    guard case .program(let program) = plan.modelStructure, let main = program.functions["main"]
    else { throw SpikeError.unsupported("model structure") }
    var preferred: [String: Int] = [:]
    var withoutNeuralEngine: [String: Int] = [:]
    for operation in main.block.operations where operation.operatorName != "const" {
      guard let usage = plan.deviceUsage(for: operation) else { continue }
      preferred[Self.name(usage.preferred), default: 0] += 1
      if !usage.supported.contains(where: { if case .neuralEngine = $0 { true } else { false } }) {
        withoutNeuralEngine[operation.operatorName, default: 0] += 1
      }
    }
    return ["preferred": preferred, "withoutNeuralEngine": withoutNeuralEngine]
  }

  private static func name(_ device: MLComputeDevice) -> String {
    switch device {
    case .cpu: "cpu"
    case .gpu: "gpu"
    case .neuralEngine: "neuralEngine"
    @unknown default: "unknown"
    }
  }
}

// The benchmark's category policy (run.py `decide`, custom_report.py membership).
public enum Policy {
  // Independent purpose decisions; People only as the fallback when no purpose applies.
  public static func system(names: [String], probabilities: [Double], thresholds: [String: Double])
    -> [Score]
  {
    var scores = zip(names, probabilities).map { name, probability in
      let threshold = thresholds[name] ?? 1
      return Score(
        category: name, probability: probability, threshold: threshold,
        member: probability >= threshold)
    }
    if let people = names.firstIndex(of: "People"),
      scores.enumerated().contains(where: { $0.offset != people && $0.element.member })
    {
      let score = scores[people]
      scores[people] = Score(
        category: score.category, probability: score.probability, threshold: score.threshold,
        member: false)
    }
    return scores
  }

  // Softmax over the entailment and negative logits only, as custom_report.py scores them.
  public static func entailment(_ entailment: Double, _ negative: Double) -> Double {
    let top = max(entailment, negative)
    let e = exp(entailment - top)
    return e / (e + exp(negative - top))
  }
}
