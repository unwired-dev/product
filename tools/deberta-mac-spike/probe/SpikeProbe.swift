import CoreGraphics
import XCTest

// Drives the categorization spike page in the packaged Mac host: every candidate and precision
// checks its golden outputs, classifies a sample and benchmarks, then Cancel and window dismissal
// stop a running benchmark. The app records each result in its own evidence file; this probe
// captures the window states the design review compares.
final class SpikeProbe: XCTestCase {
  private let environment = ProcessInfo.processInfo.environment
  private var app: XCUIApplication!
  private var window: XCUIElement { app.windows.firstMatch }

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["SPIKE_APP"])))
    app.launch()
    XCTAssertTrue(label("Categorization spike").waitForExistence(timeout: 60))
  }

  override func tearDown() {
    app.terminate()
  }

  private func label(_ value: String) -> XCUIElement {
    window.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value))
      .firstMatch
  }

  private func choose(_ popUp: String, _ choice: String) {
    window.buttons[popUp].click()
    let item = window.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", choice))
      .firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 10), "\(popUp): \(choice)")
    item.click()
  }

  // The app's evidence file: one JSON line per finished request, cancellation or release.
  private func evidenceLines() -> Int {
    let bundle = environment["SPIKE_BUNDLE"] ?? ""
    let file = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Containers/\(bundle)/Data/tmp/categorization-spike.jsonl")
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").count
  }

  // Runs one action and waits until the app has recorded its outcome and accepts actions again;
  // an enabled button alone can be sampled before the request has even started.
  private func run(_ action: String, timeout: TimeInterval = 1800) {
    let before = evidenceLines()
    window.buttons[action].click()
    let recorded = NSPredicate { [unowned self] _, _ in evidenceLines() > before }
    expectation(for: recorded, evaluatedWith: nil)
    waitForExpectations(timeout: timeout)
    let ready = NSPredicate(format: "exists == true AND isEnabled == true")
    expectation(for: ready, evaluatedWith: window.buttons["Classify"])
    waitForExpectations(timeout: 60)
    XCTAssertFalse(label("could not run on this Mac").exists, action)
  }

  // Window captures through screencapture: XCTest screenshots fail on multi-display hosts.
  private func capture(_ name: String) throws {
    let directory = try XCTUnwrap(environment["SPIKE_EVIDENCE"])
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
      as? [[String: Any]] ?? []
    let id = try XCTUnwrap(
      windows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == pid() }?[
        kCGWindowNumber as String] as? Int)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l\(id)", "\(directory)/\(name).png"]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }

  private func pid() -> Int32 {
    NSRunningApplication.runningApplications(withBundleIdentifier: environment["SPIKE_BUNDLE"] ?? "")
      .first?.processIdentifier ?? -1
  }

  private let candidates = [
    "System · DeBERTa v3 XSmall", "System · mDeBERTa v3 Base",
    "Custom · adapted DeBERTa v3 XSmall", "Custom · adapted mDeBERTa v3 Base",
  ]

  func testMatrix() throws {
    for candidate in candidates {
      choose("Candidate", candidate)
      let custom = candidate.hasPrefix("Custom")
      for precision in ["FP16", "INT8"] {
        choose("Precision", precision)
        run("Check Golden Outputs")
        run("Classify")
        if custom {
          for count in ["5 categories", "20 categories", "50 categories"] {
            choose("Custom Categories", count)
            run("Benchmark")
          }
          choose("Custom Categories", "6 golden categories")
        } else {
          run("Benchmark")
        }
      }
      choose("Precision", "FP16")
      run("Compute Plan")
      choose("Compute units", "CPU and Neural Engine")
      run("Compute Plan")
      choose("Compute units", "CPU, GPU and Neural Engine")
    }
    // Compute-unit comparison for the smallest System candidate.
    choose("Candidate", candidates[0])
    for units in ["CPU only", "CPU and GPU", "CPU and Neural Engine"] {
      choose("Compute units", units)
      run("Benchmark")
    }
  }

  func testDesignStates() throws {
    choose("Candidate", candidates[0])
    choose("Sample", "Your change fee receipt")
    run("Classify")
    try capture("system-result")
    choose("Candidate", candidates[2])
    choose("Precision", "INT8")
    choose("Compute units", "CPU and Neural Engine")
    run("Classify")
    try capture("custom-uncategorized")
    choose("Candidate", candidates[3])
    choose("Precision", "FP16")
    choose("Custom Categories", "20 categories")
    window.buttons["Benchmark"].click()
    XCTAssertTrue(label("Sample 2 of").waitForExistence(timeout: 300))
    try capture("benchmarking")
    window.buttons["Cancel"].click()
    XCTAssertTrue(label("Cancelled before the next model pass").waitForExistence(timeout: 60))
    XCTAssertFalse(label("RESULT").exists)
    // Closing the window while a benchmark runs dismisses the page mid-request.
    choose("Custom Categories", "50 categories")
    window.buttons["Benchmark"].click()
    XCTAssertTrue(label("Sample 1 of").waitForExistence(timeout: 300))
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(window.waitForNonExistence(timeout: 30))
  }

  // Run against a copy of the app without its models.
  func testUnavailable() throws {
    XCTAssertTrue(label("No exported models in this build").waitForExistence(timeout: 30))
    XCTAssertFalse(window.buttons["Classify"].exists)
    try capture("unavailable")
  }
}
