import Darwin
import Foundation

struct MeasuredValue<Value: Sendable>: Sendable {
  let metrics: QualificationMetrics
  let value: Value
}

enum QualificationMetricsRecorder {
  static func measure<Value: Sendable>(
    decodedBytes: @escaping @Sendable (Value) -> Int,
    maximumPageSize: @escaping @Sendable (Value) -> Int,
    requestCount: @escaping @Sendable (Value) -> Int,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> MeasuredValue<Value> {
    let clock = ContinuousClock()
    let start = clock.now
    let startingCPU = processCPUSeconds()
    let startingMemory = peakResidentMemoryBytes()
    let stallRecorder = StallRecorder()
    let heartbeat = Task { @MainActor in
      while !Task.isCancelled {
        let tick = clock.now
        try? await Task.sleep(for: .milliseconds(10))
        let elapsed = milliseconds(tick.duration(to: clock.now))
        await stallRecorder.record(max(0, elapsed - 10))
      }
    }

    do {
      let value = try await operation()
      heartbeat.cancel()
      _ = await heartbeat.result
      let wall = seconds(start.duration(to: clock.now))
      let cpu = max(0, processCPUSeconds() - startingCPU)
      let metrics = QualificationMetrics(
        decodedBytes: decodedBytes(value),
        mainThreadStallMilliseconds: await stallRecorder.maximum,
        maximumPageSize: maximumPageSize(value),
        peakResidentMemoryIncreaseBytes: max(0, peakResidentMemoryBytes() - startingMemory),
        processCPUSeconds: cpu,
        providerAndNetworkSeconds: max(0, wall - cpu),
        requestCount: requestCount(value),
        wallClockSeconds: wall
      )
      return MeasuredValue(metrics: metrics, value: value)
    } catch {
      heartbeat.cancel()
      _ = await heartbeat.result
      throw error
    }
  }

  private static func processCPUSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return timevalSeconds(usage.ru_utime) + timevalSeconds(usage.ru_stime)
  }

  private static func peakResidentMemoryBytes() -> Int64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Int64(usage.ru_maxrss)
  }

  private static func timevalSeconds(_ value: timeval) -> Double {
    Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
  }

  private static func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    seconds(duration) * 1_000
  }
}

private actor StallRecorder {
  private(set) var maximum: Double = 0

  func record(_ milliseconds: Double) {
    maximum = max(maximum, milliseconds)
  }
}
