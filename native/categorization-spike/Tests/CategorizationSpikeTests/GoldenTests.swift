import Foundation
import Testing

@testable import CategorizationSpike

private let root = URL(filePath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent()
private let benchmark = root.appending(path: "tools/system-category-benchmark/custom")
private let models = root.appending(path: "tools/deberta-mac-spike/work/models")
private let golden = try! JSONDecoder().decode(
  Golden.self, from: Data(contentsOf: benchmark.appending(path: "golden-v1.json")))
private let categories = try! JSONDecoder().decode(
  [CustomCategory].self, from: Data(contentsOf: benchmark.appending(path: "categories-v1.json")))
private let runs = (golden.system + golden.custom).map(\.run)
// A sanity bound for the Swift pipeline. export.py reports each export against its own 0.02
// fp16 tolerance; mDeBERTa fp16 exceeds that by up to 0.04 on the GPU without changing decisions.
private let tolerance = 0.05

private func exported(_ run: String) -> Bool {
  FileManager.default.fileExists(atPath: models.appending(path: "\(run)/fp16.mlmodelc").path)
}

@Test func pythonWhitespaceNormalizationCollapsesAndStrips() {
  #expect(Input.normalize("\u{1C} a \t\n b\u{3000}") == "a b")
}

@Test func unknownCharactersFuseIntoOneToken() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appending(path: "tokenizer.json")
  try Data(
    #"{"added_tokens":[],"model":{"type":"Unigram","unk_id":3,"vocab":[["[PAD]",0],["[CLS]",0],["[SEP]",0],["[UNK]",0],["▁",-1],["a",-2]]}}"#
      .utf8
  ).write(to: file)
  #expect(try Tokenizer(contentsOf: file).encode("a\u{1F600}\u{1F601}a") == [4, 5, 3, 5])
}

// Edge cases the golden messages lack, with ids from Hugging Face tokenizers 0.23.3.
@Test func edgeCasesMatchHuggingFace() throws {
  let run = "deberta-xsmall-body256"
  try #require(exported(run), "export \(run) with tools/deberta-mac-spike/export.py first")
  let tokenizer = try Tokenizer(contentsOf: models.appending(path: "\(run)/tokenizer.json"))
  #expect(tokenizer.encode("a\u{1F600}\u{1F601}a") == [266, 124808, 122874, 452])
  #expect(tokenizer.encode("x \u{F00}\u{F01} y") == [1204, 507, 3, 2982])
  #expect(
    tokenizer.encode("Žluťoučký kůň [SEP] test")
      == [72332, 10858, 96546, 795, 99552, 1165, 27301, 4219, 54685, 83893, 2, 1010])
}

// Every golden token id, fp16 score within tolerance and category decision, on the GPU path.
@Test(arguments: runs)
func fp16MatchesGolden(run: String) throws {
  try #require(exported(run), "export \(run) with tools/deberta-mac-spike/export.py first")
  let candidate = try Candidate(
    directory: models.appending(path: run), precision: .fp16, units: .cpuAndGPU)
  let report = try GoldenCheck.run(candidate, golden: golden, categories: categories)
  #expect(report.checked == (run.contains("adapted") ? 72 : 12))
  #expect(report.tokenMismatches.isEmpty)
  #expect(report.maxAbsProbabilityDifference <= tolerance)
  #expect(report.decisionChanges.isEmpty)
}

@Test func cancellationStopsBeforeTheNextPass() throws {
  let run = "xsmall-zs-adapted-body256-description"
  try #require(exported(run), "export \(run) with tools/deberta-mac-spike/export.py first")
  let candidate = try Candidate(
    directory: models.appending(path: run), precision: .fp16, units: .cpuOnly)
  var passes = 0
  #expect(throws: SpikeError.cancelled) {
    try candidate.classify(golden.messages[0], categories: Array(categories.prefix(5))) {
      passes += 1
      return passes > 2
    }
  }
  #expect(passes == 3)
}

// A main-thread probe still queued when the sampler stops and is released must not touch it.
@Test func samplerReleasedWithQueuedProbesDoesNotCrash() async throws {
  for _ in 0..<20 {
    var sampler: CategorizationSpike.Measurement.Sampler? = .init()
    try await Task.sleep(for: .milliseconds(15))
    _ = sampler?.stop()
    sampler = nil
    #expect(sampler == nil)
  }
  // Let the queued probes run against the released samplers.
  for _ in 0..<5 { await MainActor.run {} }
  try await Task.sleep(for: .milliseconds(50))
}
