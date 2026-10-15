import Darwin
import Foundation

// Process measurements for the spike evidence: memory footprint, CPU energy estimate,
// thermal state and how late the main thread answers while work runs elsewhere.
public enum Measurement {
  public static func footprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }

  // The kernel's energy estimate for this process in nanojoules. It does not attribute GPU or
  // Neural Engine energy, so accelerator runs understate their cost.
  public static func energyNanojoules() -> UInt64 {
    var info = rusage_info_v6()
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
      }
    }
    return result == 0 ? info.ri_energy_nj : 0
  }

  public static func thermal() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }

  public static func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
  }

  // Samples peak footprint and main-thread lateness until stopped.
  public final class Sampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.unwired.categorization-spike.sampler")
    private var timer: DispatchSourceTimer?
    private var peak: UInt64 = 0
    private var lags: [Double] = []
    private var pending = false
    private let energy = energyNanojoules()
    private let thermal = Measurement.thermal()

    public init() {
      peak = footprintBytes()
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: .milliseconds(10))
      // A tick or probe can still be queued after stop() releases the sampler; each does nothing then.
      timer.setEventHandler { [weak self] in
        guard let self else { return }
        peak = max(peak, footprintBytes())
        guard !pending else { return }
        pending = true
        let sent = ContinuousClock.now
        DispatchQueue.main.async { [weak self] in
          let lag = Candidate.milliseconds(ContinuousClock.now - sent)
          self?.queue.async { [weak self] in
            self?.lags.append(lag)
            self?.pending = false
          }
        }
      }
      timer.resume()
      self.timer = timer
    }

    public func stop() -> [String: Any] {
      queue.sync {
        timer?.cancel()
        timer = nil
        peak = max(peak, footprintBytes())
        return [
          "peakFootprintMB": Double(peak) / 1_048_576,
          "energyMillijoules": Double(energyNanojoules() &- energy) / 1e6,
          "thermalBefore": thermal,
          "thermalAfter": Measurement.thermal(),
          "mainThreadLagMs": [
            "p50": percentile(lags, 0.5), "p95": percentile(lags, 0.95),
            "max": lags.max() ?? 0, "samples": lags.count,
          ],
        ]
      }
    }
  }
}
