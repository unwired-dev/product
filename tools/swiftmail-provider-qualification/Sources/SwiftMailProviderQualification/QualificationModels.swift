import Foundation

public enum QualificationProvider: String, Codable, CaseIterable, Sendable {
  case fastmail
  case icloud

  public var displayName: String {
    switch self {
    case .fastmail: "Fastmail"
    case .icloud: "iCloud Mail"
    }
  }
}

public enum QualificationError: Error, Sendable {
  case failed(String)
  case missingEnvironmentVariable(String)
}

extension QualificationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .failed(let message): message
    case .missingEnvironmentVariable(let name):
      "Missing protected-environment value: \(name)"
    }
  }
}

public struct QualificationCheck: Codable, Equatable, Sendable {
  public let name: String
  public let passed: Bool
  public let detail: String

  public init(name: String, passed: Bool, detail: String) {
    self.name = name
    self.passed = passed
    self.detail = detail
  }
}

public struct QualificationMetrics: Codable, Equatable, Sendable {
  public let decodedBytes: Int
  public let mainThreadStallMilliseconds: Double
  public let maximumPageSize: Int
  public let peakResidentMemoryIncreaseBytes: Int64
  public let processCPUSeconds: Double
  public let providerAndNetworkSeconds: Double
  public let requestCount: Int
  public let wallClockSeconds: Double

  public init(
    decodedBytes: Int,
    mainThreadStallMilliseconds: Double,
    maximumPageSize: Int,
    peakResidentMemoryIncreaseBytes: Int64,
    processCPUSeconds: Double,
    providerAndNetworkSeconds: Double,
    requestCount: Int,
    wallClockSeconds: Double
  ) {
    self.decodedBytes = decodedBytes
    self.mainThreadStallMilliseconds = mainThreadStallMilliseconds
    self.maximumPageSize = maximumPageSize
    self.peakResidentMemoryIncreaseBytes = peakResidentMemoryIncreaseBytes
    self.processCPUSeconds = processCPUSeconds
    self.providerAndNetworkSeconds = providerAndNetworkSeconds
    self.requestCount = requestCount
    self.wallClockSeconds = wallClockSeconds
  }
}

public struct QualificationReport: Codable, Equatable, Sendable {
  public static let swiftMailCommit = "c907f871bb23812895274f4c7ae17bf343171c1e"
  public static let swiftMailVersion = "1.10.0"

  public let checks: [QualificationCheck]
  public let completedAt: Date
  public let metrics: [String: QualificationMetrics]
  public let passed: Bool
  public let preparedDataset: Bool
  public let provider: QualificationProvider
  public let startedAt: Date
  public let swiftMailCommit: String
  public let swiftMailVersion: String

  public init(
    checks: [QualificationCheck],
    completedAt: Date,
    metrics: [String: QualificationMetrics],
    passed: Bool,
    preparedDataset: Bool,
    provider: QualificationProvider,
    startedAt: Date
  ) {
    self.checks = checks
    self.completedAt = completedAt
    self.metrics = metrics
    self.passed = passed
    self.preparedDataset = preparedDataset
    self.provider = provider
    self.startedAt = startedAt
    swiftMailCommit = Self.swiftMailCommit
    swiftMailVersion = Self.swiftMailVersion
  }

  public func write(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(self).write(to: url, options: .atomic)
  }
}

public struct QualificationBudget: Equatable, Sendable {
  public static let adr0027 = QualificationBudget(
    maximumDecodedBytes: 5 * 1024 * 1024,
    maximumMainThreadStallMilliseconds: 100,
    maximumPageSize: 500,
    maximumPeakResidentMemoryIncreaseBytes: 100 * 1024 * 1024,
    maximumRequestCount: 20
  )

  public let maximumDecodedBytes: Int
  public let maximumMainThreadStallMilliseconds: Double
  public let maximumPageSize: Int
  public let maximumPeakResidentMemoryIncreaseBytes: Int64
  public let maximumRequestCount: Int

  public func violations(in metrics: QualificationMetrics) -> [String] {
    var violations: [String] = []
    if metrics.decodedBytes > maximumDecodedBytes {
      violations.append("decoded metadata exceeded 5 MiB")
    }
    if metrics.mainThreadStallMilliseconds > maximumMainThreadStallMilliseconds {
      violations.append("main-thread stall exceeded 100 ms")
    }
    if metrics.maximumPageSize > maximumPageSize {
      violations.append("page size exceeded 500 messages")
    }
    if metrics.peakResidentMemoryIncreaseBytes > maximumPeakResidentMemoryIncreaseBytes {
      violations.append("peak resident-memory increase exceeded 100 MiB")
    }
    if metrics.requestCount > maximumRequestCount {
      violations.append("request count exceeded 20")
    }
    return violations
  }
}
