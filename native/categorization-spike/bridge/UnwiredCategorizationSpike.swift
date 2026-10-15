import Foundation
import React

// Spike #831: classifies bundled public/synthetic samples with the frozen DeBERTa candidates
// through Core ML inside the Mac host. Compiled only into the `categorization-spike` Mock Mail
// Session build; it reads no mailbox, changes no assignment and has no cloud fallback.
@objc(UnwiredCategorizationSpike)
final class UnwiredCategorizationSpike: NSObject {
  private static let queue = DispatchQueue(label: "dev.unwired.categorization-spike")
  private static let resources = Bundle.main.resourceURL!.appending(path: "CategorizationSpike")
  // Every result, one JSON object per line, inside the app's own container.
  private static let evidence = FileManager.default.temporaryDirectory
    .appending(path: "categorization-spike.jsonl")
  // Guarded by `queue`: the one loaded candidate and the requests cancelled so far.
  private static var loaded: (key: String, candidate: Candidate)?
  private static let cancelled = NSLock()
  nonisolated(unsafe) private static var cancelledRequests: Set<String> = []
  nonisolated(unsafe) private static var activeRequests: Set<String> = []
  // Benchmark progress by request, guarded by `cancelled`'s lock: samples done and planned.
  nonisolated(unsafe) private static var progress: [String: (done: Int, total: Int)] = [:]

  @objc static func requiresMainQueueSetup() -> Bool { false }

  private struct Request: Decodable {
    let run: String
    let precision: Precision
    let units: Units
    let message: String?
    let categories: [String]?
    let categoryCount: Int?
    let rounds: Int?
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: resources.appending(path: name)))
  }

  private static func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
  }

  private static func encoded<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
  }

  private static func isCancelled(_ request: String) -> Bool {
    cancelled.withLock { cancelledRequests.contains(request) }
  }

  // Loads the requested candidate, replacing any other so only one stays resident.
  private static func candidate(_ request: Request) throws -> (Candidate, cold: Bool) {
    let key = "\(request.run)/\(request.precision.rawValue)/\(request.units.rawValue)"
    if let loaded, loaded.key == key { return (loaded.candidate, false) }
    loaded = nil
    let candidate = try Candidate(
      directory: resources.appending(path: "models/\(request.run)"), precision: request.precision,
      units: request.units)
    loaded = (key, candidate)
    return (candidate, true)
  }

  private static func perform(
    _ request: String, _ body: String, _ resolve: @escaping RCTPromiseResolveBlock,
    _ reject: @escaping RCTPromiseRejectBlock,
    _ work: @escaping (Request, Candidate, Bool) throws -> [String: Any]
  ) {
    cancelled.withLock { _ = activeRequests.insert(request) }
    queue.async {
      defer {
        cancelled.withLock {
          activeRequests.remove(request)
          cancelledRequests.remove(request)
        }
      }
      let sampler = Measurement.Sampler()
      do {
        if isCancelled(request) { throw SpikeError.cancelled }
        let parsed = try JSONDecoder().decode(Request.self, from: Data(body.utf8))
        let (candidate, cold) = try candidate(parsed)
        var result = try work(parsed, candidate, cold)
        if isCancelled(request) { throw SpikeError.cancelled }
        result["request"] = ["run": parsed.run, "precision": parsed.precision.rawValue, "units": parsed.units.rawValue]
        result["loadMs"] = cold ? candidate.loadMilliseconds : nil
        result["process"] = sampler.stop()
        let line = try json(result)
        try? (line + "\n").append(to: evidence)
        resolve(line)
      } catch {
        _ = sampler.stop()
        // Cancellations and failures are evidence too: dismissal must stop work, not hide it.
        if let line = try? json(["request": request, "error": code(error)]) {
          try? (line + "\n").append(to: evidence)
        }
        reject(code(error), "The categorization spike could not produce a result.", nil)
      }
    }
  }

  private static func code(_ error: any Error) -> String {
    switch error {
    case SpikeError.cancelled: "cancelled"
    case SpikeError.missing: "unavailable"
    default: "failed"
    }
  }

  // Candidates, samples and Custom Categories the page may offer, and where evidence goes.
  @objc(catalog:rejecter:)
  func catalog(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
    Self.queue.async {
      do {
        let models = Self.resources.appending(path: "models")
        let runs = (try? FileManager.default.contentsOfDirectory(atPath: models.path)) ?? []
        let candidates: [[String: Any]] = try runs.sorted().compactMap { run in
          let directory = models.appending(path: run)
          guard let data = try? Data(contentsOf: directory.appending(path: "manifest.json")) else { return nil }
          let manifest = try JSONDecoder().decode(Manifest.self, from: data)
          let precisions = Precision.allCases.filter {
            FileManager.default.fileExists(atPath: directory.appending(path: "\($0.rawValue).mlmodelc").path)
          }
          let size = Precision.allCases.reduce(into: [String: Int]()) { sizes, precision in
            let url = directory.appending(path: "\(precision.rawValue).mlmodelc")
            let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            sizes[precision.rawValue] = (files?.allObjects as? [URL] ?? []).reduce(0) {
              $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
          }
          return [
            "run": run, "mode": manifest.mode, "maxLength": manifest.max_length,
            "precisions": precisions.map(\.rawValue), "bytes": size,
          ]
        }
        let golden = try Self.decode(Golden.self, "golden-v1.json")
        let categories = try Self.decode([CustomCategory].self, "categories-v1.json")
        // A launch-selected unattended run for hosts without UI automation.
        let autorun: Any = ProcessInfo.processInfo.environment["UNWIRED_SPIKE_AUTORUN"] ?? NSNull()
        resolve(
          try Self.json([
            "candidates": candidates,
            "messages": try Self.encoded(golden.messages),
            "categories": try Self.encoded(categories),
            "host": [
              "model": Self.hardwareModel(),
              "os": ProcessInfo.processInfo.operatingSystemVersionString,
              "memoryGB": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
              "processors": ProcessInfo.processInfo.activeProcessorCount,
            ],
            "evidence": Self.evidence.path,
            "autorun": autorun,
          ]))
      } catch {
        reject("unavailable", "The categorization spike resources are missing.", nil)
      }
    }
  }

  private static func hardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(cString: model)
  }

  private static func categories(_ request: Request) throws -> [CustomCategory] {
    let all = try decode([CustomCategory].self, "categories-v1.json")
    if let ids = request.categories { return ids.compactMap { id in all.first { $0.id == id } } }
    return Array(all.prefix(request.categoryCount ?? 0))
  }

  // One sample through one candidate.
  @objc(classify:body:resolver:rejecter:)
  func classify(
    _ request: String, body: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    Self.perform(request, body, resolve, reject) { parsed, candidate, cold in
      let golden = try Self.decode(Golden.self, "golden-v1.json")
      guard let message = golden.messages.first(where: { $0.id == parsed.message }) else {
        throw SpikeError.missing("message")
      }
      let result = try candidate.classify(message, categories: try Self.categories(parsed)) {
        Self.isCancelled(request)
      }
      return [
        "input": Input.text(message), "classification": try Self.encoded(result), "cold": cold,
      ]
    }
  }

  // Every sample through one candidate for several rounds: sustained latency and throughput.
  @objc(benchmark:body:resolver:rejecter:)
  func benchmark(
    _ request: String, body: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    Self.perform(request, body, resolve, reject) { parsed, candidate, _ in
      let messages = try Self.decode(Golden.self, "golden-v1.json").messages
      let categories = try Self.categories(parsed)
      var passes: [Double] = []
      var classified = 0
      let start = ContinuousClock.now
      let total = (parsed.rounds ?? 1) * messages.count
      defer { Self.cancelled.withLock { _ = Self.progress.removeValue(forKey: request) } }
      for _ in 0..<(parsed.rounds ?? 1) {
        for message in messages {
          passes += try candidate.classify(message, categories: categories) {
            Self.isCancelled(request)
          }.milliseconds
          classified += 1
          Self.cancelled.withLock { Self.progress[request] = (classified, total) }
        }
      }
      let seconds = Candidate.milliseconds(ContinuousClock.now - start) / 1000
      return [
        "messages": classified, "passes": passes.count, "categoryCount": categories.count,
        "seconds": seconds, "messagesPerSecond": Double(classified) / seconds,
        "passMs": [
          "p50": Measurement.percentile(passes, 0.5), "p95": Measurement.percentile(passes, 0.95),
          "first": passes.first ?? 0,
        ],
      ]
    }
  }

  // Tokenizer, reference-score and decision parity against the frozen golden outputs.
  @objc(golden:body:resolver:rejecter:)
  func golden(
    _ request: String, body: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    Self.perform(request, body, resolve, reject) { parsed, candidate, _ in
      let golden = try Self.decode(Golden.self, "golden-v1.json")
      let all = try Self.decode([CustomCategory].self, "categories-v1.json")
      let report = try GoldenCheck.run(
        candidate, golden: golden, categories: all, cancelled: { Self.isCancelled(request) })
      return ["golden": try Self.encoded(report)]
    }
  }

  @objc(computePlan:body:resolver:rejecter:)
  func computePlan(
    _ request: String, body: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    Self.perform(request, body, resolve, reject) { _, candidate, _ in
      let semaphore = DispatchSemaphore(value: 0)
      nonisolated(unsafe) var outcome: Result<[String: Any], any Error>!
      Task.detached {
        do { outcome = .success(try await candidate.computePlan()) } catch { outcome = .failure(error) }
        semaphore.signal()
      }
      semaphore.wait()
      return ["plan": try outcome.get()]
    }
  }

  // How far a running benchmark is, or null once it has finished.
  @objc(progress:resolver:rejecter:)
  func progress(
    _ request: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    let current = Self.cancelled.withLock { Self.progress[request] }
    resolve(current.map { ["done": $0.done, "total": $0.total] })
  }

  // Stops a request before its next model pass; the page never shows its partial result.
  @objc(cancel:resolver:rejecter:)
  func cancel(
    _ request: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    Self.cancelled.withLock {
      if Self.activeRequests.contains(request) { Self.cancelledRequests.insert(request) }
    }
    resolve(nil)
  }

  // Releases the loaded model when the page closes, and reports the footprint afterwards.
  @objc(release:rejecter:)
  func release(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    Self.queue.async {
      let before = Measurement.footprintBytes()
      Self.loaded = nil
      let line = try? Self.json([
        "release": [
          "footprintBeforeMB": Double(before) / 1_048_576,
          "footprintAfterMB": Double(Measurement.footprintBytes()) / 1_048_576,
        ]
      ])
      if let line { try? (line + "\n").append(to: Self.evidence) }
      resolve(line)
    }
  }
}

private extension String {
  func append(to url: URL) throws {
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(utf8))
    } else {
      try Data(utf8).write(to: url)
    }
  }
}
