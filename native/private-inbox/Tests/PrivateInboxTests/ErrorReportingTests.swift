import Foundation
import Sentry
import Testing

@testable import PrivateInbox

@MainActor private final class ReportingMemory {
  var data: Data?
  var locked = false
  var writeFails = false
  var persistence: ReportingPersistence {
    ReportingPersistence(
      read: {
        if self.locked { throw PrivateInboxError.locked }
        return self.data
      },
      write: {
        if self.locked { throw PrivateInboxError.locked }
        if self.writeFails { throw PrivateInboxError.unavailable }
        self.data = $0
      })
  }
}

@MainActor private final class ReportingTestCollector: ReportingCollector {
  var callbacks: [(Int, @MainActor @Sendable (Int, ReportingReport) -> Void)] = []
  var active = false
  func start(
    generation: Int, receive: @escaping @MainActor @Sendable (Int, ReportingReport) -> Void
  ) {
    active = true
    callbacks.append((generation, receive))
  }
  func stop() { active = false }
  func deliver(_ report: ReportingReport, from index: Int) {
    let (generation, receive) = callbacks[index]
    receive(generation, report)
  }
}

private final class ReportingHTTP: @unchecked Sendable {
  let lock = NSLock()
  var requests: [URLRequest] = []
  var hold = false
  var reply = "accepted"
  var status = 200
  var failure: URLError.Code?
  var started: (@Sendable () -> Void)?
  func accept(_ original: URLRequest) -> Bool {
    var request = original
    if request.httpBody == nil, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while data.count < 1_048_576 {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
      }
      request.httpBody = data
    }
    lock.lock()
    requests.append(request)
    let callback = started
    let held = hold
    lock.unlock()
    callback?()
    return held
  }
  func reset(
    hold: Bool = false, reply: String = "accepted", status: Int = 200,
    failure: URLError.Code? = nil,
    started: (@Sendable () -> Void)? = nil
  ) {
    lock.lock()
    defer { lock.unlock() }
    requests = []
    self.hold = hold
    self.reply = reply
    self.status = status
    self.failure = failure
    self.started = started
  }
  func response() -> (String, Int, URLError.Code?) {
    lock.lock()
    defer { lock.unlock() }
    return (reply, status, failure)
  }
  func captured() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}

private final class ReportingHTTPProtocol: URLProtocol, @unchecked Sendable {
  static let recording = ReportingHTTP()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    if Self.recording.accept(request) { return }
    let (reply, status, failure) = Self.recording.response()
    if let failure {
      client?.urlProtocol(self, didFailWithError: URLError(failure))
      return
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("{\"status\":\"\(reply)\"}".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct ErrorReportingTests {
  let date = Date(timeIntervalSince1970: 1_800_000_000)
  let metadata = ReportingMetadata(
    appNamespace: "dev.unwired.mail", platform: "macos", appVersion: "1", build: "1", osVersion: "27", channel: "qualification")

  func report(createdAt: Double? = nil) -> ReportingReport {
    ReportingReport(
      id: UUID().uuidString, createdAt: createdAt ?? date.timeIntervalSince1970 * 1000,
      code: "native-crash", name: "NativeCrash", frames: [], causes: [], breadcrumbs: [])
  }

  private func store(
    _ memory: ReportingMemory, directory: URL, collector: ReportingTestCollector,
    session: URLSession? = nil
  ) -> ErrorReportingStore {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReportingHTTPProtocol.self]
    return ErrorReportingStore(
      persistence: memory.persistence, directory: directory,
      base: URL(string: "https://synthetic.convex.cloud")!, available: true, nativeQualified: true,
      metadata: metadata, collector: collector,
      session: session ?? URLSession(configuration: configuration), now: { date })
  }

  @Test(
    arguments: [
      "malformed-json", "version", "shape", "unknown-field", "optional-null", "report-id",
      "report-shape", "pending-queue", "pending-phase", "queue-limit", "oversized",
    ], [false, true])
  func malformedPersistedDocumentsStayUnavailableAcrossReadAndRelaunch(
    _ corruption: String, _ wasEnabled: Bool
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let memory = ReportingMemory()
    let collector = ReportingTestCollector()
    let store = store(memory, directory: directory, collector: collector)
    let initial: [String: Any]
    if wasEnabled {
      initial = try store.consent(enabled: true, renewIdentity: false)
    } else {
      initial = store.read()
    }
    let generation = try #require(initial["generation"] as? Int)
    if wasEnabled { collector.deliver(report(), from: 0) }
    let reportObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report()))
    var document: [String: Any] = ["version": 1, "queue": [reportObject], "deletion": "idle"]
    switch corruption {
    case "version": document["version"] = 2
    case "shape": document.removeValue(forKey: "deletion")
    case "unknown-field": document["unknown"] = true
    case "optional-null":
      var invalid = try #require(reportObject as? [String: Any])
      invalid["message"] = NSNull()
      document["queue"] = [invalid]
    case "report-id":
      var invalid = try #require(reportObject as? [String: Any])
      invalid["id"] = "00000000-0000-0000-0000-000000000000"
      document["queue"] = [invalid]
    case "report-shape":
      var invalid = try #require(reportObject as? [String: Any])
      invalid["frames"] = [["kind": "javascript", "line": 1, "column": 1, "unknown": true]]
      document["queue"] = [invalid]
    case "pending-queue":
      document["deletion"] = "pending"
      document["queue"] = [["id": "retained-invalid-report"]]
    case "pending-phase": document["deletion"] = "unknown"
    case "queue-limit": document["queue"] = Array(repeating: reportObject, count: 101)
    default: break
    }
    let malformed: String
    if corruption == "malformed-json" {
      malformed = "{"
    } else if corruption == "oversized" {
      malformed = String(repeating: " ", count: 1_048_577)
    } else {
      malformed = String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }
    let before = try #require(memory.data)
    var state = try #require(try JSONSerialization.jsonObject(with: before) as? [String: Any])
    state["document"] = malformed
    memory.data = try JSONSerialization.data(withJSONObject: state)
    let retained = memory.data
    try FileManager.default.createDirectory(at: store.cache, withIntermediateDirectories: true)
    try Data("synthetic raw report".utf8).write(to: store.cache.appendingPathComponent("raw.json"))

    for _ in 0..<2 {
      let unavailable = store.read()
      #expect(unavailable["enabled"] as? Bool == false)
      #expect(unavailable["available"] as? Bool == false)
      #expect(unavailable["nativeAvailable"] as? Bool == false)
      #expect(!collector.active)
      #expect(!FileManager.default.fileExists(atPath: store.cache.path))
    }
    if wasEnabled { collector.deliver(report(), from: 0) }
    #expect(collector.callbacks.count == (wasEnabled ? 1 : 0))
    let reopenedCollector = ReportingTestCollector()
    let reopened = self.store(memory, directory: directory, collector: reopenedCollector)
    try FileManager.default.createDirectory(at: reopened.cache, withIntermediateDirectories: true)
    try Data("synthetic startup report".utf8).write(to: reopened.cache.appendingPathComponent("raw.json"))
    #expect(reopened.read()["available"] as? Bool == false)
    #expect(reopened.read()["enabled"] as? Bool == false)
    #expect(reopenedCollector.callbacks.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: reopened.cache.path))
    #expect(throws: ReportingError.unavailable) { try reopened.takeNative() }
    #expect(throws: ReportingError.unavailable) {
      try reopened.save(generation: generation, document: ReportingDocument().encoded())
    }
    #expect(throws: ReportingError.unavailable) {
      try reopened.consent(enabled: true, renewIdentity: true, expectedGeneration: generation)
    }
    #expect(throws: ReportingError.unavailable) {
      try reopened.consent(enabled: false, renewIdentity: false)
    }
    ReportingHTTPProtocol.recording.reset()
    for operation in ["enable", "capture", "revoke", "delete", "status"] {
      await #expect(throws: ReportingError.unavailable) {
        try await reopened.request(operation: operation, body: "{}", generation: generation)
      }
    }
    #expect(ReportingHTTPProtocol.recording.captured().isEmpty)
    #expect(memory.data == retained)
  }

  @Test(arguments: ["absent", "idle", "queued", "numeric", "expired"])
  func validPersistedDocumentsStillStartCollectionOnRead(_ kind: String) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let memory = ReportingMemory()
    let seed = store(memory, directory: directory, collector: ReportingTestCollector())
    _ = try seed.consent(enabled: true, renewIdentity: false)
    let before = try #require(memory.data)
    var state = try #require(try JSONSerialization.jsonObject(with: before) as? [String: Any])
    var document = ReportingDocument()
    if kind == "expired" {
      document.queue = [report(createdAt: date.timeIntervalSince1970 * 1000 - 86_400_001)]
    } else if kind == "queued" {
      document.queue = [
        ReportingReport(
          id: UUID().uuidString, createdAt: date.timeIntervalSince1970 * 1000,
          code: "native-crash", name: "NativeCrash", message: "Synthetic native crash",
          frames: [
            ReportingFrame(kind: "javascript", line: 1, column: 0),
            ReportingFrame(
              kind: "native", address: "0x1001", imageUuid: UUID().uuidString, imageAddress: "0x1000"),
          ],
          causes: [
            ReportingCause(name: "TypeError", message: "Invalid array length"),
            ReportingCause(name: "Error"),
          ],
          breadcrumbs: [
            ReportingBreadcrumb(operation: "sync", stage: "failed", elapsedMs: 10, status: 503),
            ReportingBreadcrumb(operation: "app", stage: "open"),
          ])
      ]
    }
    if kind == "absent" {
      state["document"] = NSNull()
    } else if kind == "numeric" {
      state["document"] = """
        {
          "version": 1e0,
          "queue": [{
            "id": "12345678-1234-4234-8234-123456789abc",
            "createdAt": 1.8e12,
            "code": "native-crash",
            "name": "NativeCrash",
            "frames": [{"kind": "javascript", "line": 1e0, "column": 0.0}],
            "causes": [],
            "breadcrumbs": [{
              "operation": "sync", "stage": "failed", "elapsedMs": 1e1, "status": 5.03e2
            }]
          }],
          "deletion": "idle"
        }
        """
    } else {
      state["document"] = try document.encoded()
    }
    memory.data = try JSONSerialization.data(withJSONObject: state)
    let retained = memory.data
    let collector = ReportingTestCollector()
    let reopened = store(memory, directory: directory, collector: collector)
    let enabled = reopened.read()
    #expect(enabled["available"] as? Bool == true)
    #expect(enabled["enabled"] as? Bool == true)
    #expect(collector.active && collector.callbacks.count == 1)
    let decoded = try ReportingDocument.decode(enabled["document"] as? String, now: date)
    #expect(decoded.queue.count == (["queued", "numeric"].contains(kind) ? 1 : 0))
    #expect(reopened.read()["enabled"] as? Bool == true)
    #expect(collector.callbacks.count == 1)
    #expect(memory.data == retained)
  }

  @Test func freshOffCASWithdrawalAndDeletionCredentialSurviveRelaunch() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let memory = ReportingMemory()
    let collector = ReportingTestCollector()
    let store = store(memory, directory: directory, collector: collector)
    let fresh = store.read()
    #expect(fresh["enabled"] as? Bool == false)
    #expect(fresh["document"] is NSNull)
    #expect(collector.callbacks.isEmpty)
    let identityData = try #require(memory.data)
    let identity = try #require(
      try JSONSerialization.jsonObject(with: identityData) as? [String: Any])
    #expect(fresh["installationId"] == nil && fresh["credential"] == nil)
    let enabled = try store.consent(enabled: true, renewIdentity: false)
    let generation = try #require(enabled["generation"] as? Int)
    let pending = try ReportingDocument(queue: [report()], deletion: "pending").encoded()
    #expect(try store.save(generation: generation, document: pending))
    _ = try store.consent(enabled: false, renewIdentity: false)
    #expect(!collector.active)
    #expect(try store.save(generation: generation, document: pending) == false)
    let off = store.read()
    let current = try #require(off["generation"] as? Int)
    #expect(try store.save(generation: current, document: pending) == false)
    let document = try ReportingDocument.decode(off["document"] as? String, now: date)
    #expect(document.queue.isEmpty && document.deletion == "pending")
    let reopened = self.store(memory, directory: directory, collector: ReportingTestCollector())
    #expect(reopened.read()["enabled"] as? Bool == false)
    let afterData = try #require(memory.data)
    let after = try #require(try JSONSerialization.jsonObject(with: afterData) as? [String: Any])
    #expect(after["installationId"] as? String == identity["installationId"] as? String)
    #expect(after["credential"] as? String == identity["credential"] as? String)
    #expect((after["generation"] as? Int ?? 0) > generation)
  }

  @Test func freshOffCleanupDoesNotTransmitAnInstallationIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let memory = ReportingMemory()
    let store = store(memory, directory: directory, collector: ReportingTestCollector())
    ReportingHTTPProtocol.recording.reset(reply: "disabled")
    _ = store.read()
    let off = try store.consent(enabled: false, renewIdentity: false)
    let generation = try #require(off["generation"] as? Int)
    _ = try await store.request(operation: "revoke", body: "{}", generation: generation)
    let pending = ReportingDocument(queue: [], deletion: "pending")
    #expect(try store.save(generation: generation, document: pending.encoded()))
    let deleting = try #require(store.read()["generation"] as? Int)
    let reply = try await store.request(operation: "delete", body: "{}", generation: deleting)
    #expect(reply["status"] as? String == "complete")
    let completed = ReportingDocument(queue: [], deletion: "complete")
    #expect(try store.save(generation: deleting, document: completed.encoded()))
    let reopened = self.store(memory, directory: directory, collector: ReportingTestCollector())
    let status = try await reopened.request(operation: "status", body: "{}", generation: deleting)
    #expect(status["status"] as? String == "complete")
    #expect(ReportingHTTPProtocol.recording.captured().isEmpty)
    try store.disableForAccountRemoval()
    #expect(store.read()["enabled"] as? Bool == false)
    #expect(ReportingHTTPProtocol.recording.captured().isEmpty)
  }

  @Test func pendingDeletionClosesNativeCollectionBeforeWithdrawalAndSurvivesRelaunch() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let memory = ReportingMemory()
    let collector = ReportingTestCollector()
    let store = store(memory, directory: directory, collector: collector)
    let enabled = try store.consent(enabled: true, renewIdentity: false)
    let generation = try #require(enabled["generation"] as? Int)
    collector.deliver(report(), from: 0)
    try FileManager.default.createDirectory(at: store.cache, withIntermediateDirectories: true)
    try Data("synthetic raw report".utf8).write(to: store.cache.appendingPathComponent("raw.json"))
    let pending = try ReportingDocument(deletion: "pending").encoded()
    #expect(try store.save(generation: generation, document: pending))
    #expect(!collector.active)
    #expect(!FileManager.default.fileExists(atPath: store.cache.path))
    let reopenedCollector = ReportingTestCollector()
    let reopened = self.store(memory, directory: directory, collector: reopenedCollector)
    let off = reopened.read()
    #expect(off["enabled"] as? Bool == false)
    #expect((off["generation"] as? Int ?? 0) > generation)
    #expect(reopenedCollector.callbacks.isEmpty)
    let document = try ReportingDocument.decode(off["document"] as? String, now: date)
    #expect(document.deletion == "pending" && document.queue.isEmpty)
    collector.deliver(report(), from: 0)
    #expect((try reopened.takeNative()["reports"] as? [Any])?.isEmpty == true)
    #expect(
      try store.save(generation: generation, document: ReportingDocument().encoded()) == false)
    #expect(throws: ReportingError.stale) {
      try reopened.consent(
        enabled: true, renewIdentity: false, expectedGeneration: generation)
    }
  }

  @Test func pendingDeletionWhileAlreadyOffFencesQueuedEnablesAndSaves() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let memory = ReportingMemory()
    let collector = ReportingTestCollector()
    let store = store(memory, directory: directory, collector: collector)
    let generation = try #require(store.read()["generation"] as? Int)
    let pending = try ReportingDocument(deletion: "pending").encoded()
    #expect(try store.save(generation: generation, document: pending))
    #expect(throws: ReportingError.stale) {
      try store.consent(enabled: true, renewIdentity: false, expectedGeneration: generation)
    }
    #expect(
      try store.save(generation: generation, document: ReportingDocument().encoded()) == false)
    let off = store.read()
    let current = try #require(off["generation"] as? Int)
    #expect(current > generation)
    #expect(try store.save(generation: current, document: pending))
    #expect(store.read()["generation"] as? Int == current)
    #expect(throws: ReportingError.disabled) {
      try store.consent(enabled: true, renewIdentity: false, expectedGeneration: current)
    }
    #expect(off["enabled"] as? Bool == false)
    #expect(collector.callbacks.isEmpty)
    let reopened = self.store(memory, directory: directory, collector: ReportingTestCollector())
    let document = try ReportingDocument.decode(reopened.read()["document"] as? String, now: date)
    #expect(document.deletion == "pending" && document.queue.isEmpty)
  }

  @Test func deletionIntentSurvivesCommittedWithdrawalWhenRawCachePurgeFails() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let memory = ReportingMemory()
    let collector = ReportingTestCollector()
    let store = store(memory, directory: directory, collector: collector)
    defer {
      try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: store.cache.path)
      try? FileManager.default.removeItem(at: directory)
    }
    let enabled = try store.consent(enabled: true, renewIdentity: false)
    let generation = try #require(enabled["generation"] as? Int)
    collector.deliver(report(), from: 0)
    try FileManager.default.createDirectory(at: store.cache, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: store.cache.path)
    #expect(throws: (any Error).self) {
      try store.save(generation: generation, document: ReportingDocument(deletion: "pending").encoded())
    }
    #expect(!collector.active)
    #expect(throws: ReportingError.unavailable) {
      try store.consent(enabled: false, renewIdentity: false)
    }
    let data = try #require(memory.data)
    let persisted = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(persisted["enabled"] as? Bool == false)
    #expect((persisted["generation"] as? Int ?? 0) > generation)
    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: store.cache.path)
    let reopened = self.store(memory, directory: directory, collector: ReportingTestCollector())
    let off = reopened.read()
    let document = try ReportingDocument.decode(off["document"] as? String, now: date)
    #expect(off["enabled"] as? Bool == false)
    #expect(document.deletion == "pending" && document.queue.isEmpty)
    #expect((try reopened.takeNative()["reports"] as? [Any])?.isEmpty == true)
    #expect(!FileManager.default.fileExists(atPath: store.cache.path))
  }

  @Test func staleEnableCannotRestoreCollectionAfterWithdrawal() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let collector = ReportingTestCollector()
    let store = store(ReportingMemory(), directory: directory, collector: collector)
    let generation = try #require(store.read()["generation"] as? Int)
    _ = try store.consent(enabled: false, renewIdentity: false)
    #expect(throws: ReportingError.stale) {
      try store.consent(enabled: true, renewIdentity: false, expectedGeneration: generation)
    }
    #expect(store.read()["enabled"] as? Bool == false)
    #expect(!collector.active)
  }

  @Test func identityRenewsOnlyAfterConfirmedDeletionAndExplicitEnable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let memory = ReportingMemory()
    let store = store(memory, directory: directory, collector: ReportingTestCollector())
    _ = try store.consent(enabled: true, renewIdentity: false)
    #expect(throws: ReportingError.invalid) {
      try store.consent(enabled: true, renewIdentity: true)
    }
    _ = try store.consent(enabled: false, renewIdentity: false)
    let beforeData = try #require(memory.data)
    let before = try #require(try JSONSerialization.jsonObject(with: beforeData) as? [String: Any])
    let generation = try #require(store.read()["generation"] as? Int)
    #expect(
      try store.save(
        generation: generation, document: ReportingDocument(deletion: "complete").encoded()))
    _ = try store.consent(enabled: true, renewIdentity: true)
    let afterData = try #require(memory.data)
    let after = try #require(try JSONSerialization.jsonObject(with: afterData) as? [String: Any])
    #expect(before["installationId"] as? String != after["installationId"] as? String)
    #expect(before["credential"] as? String != after["credential"] as? String)
    #expect((after["generation"] as? Int ?? 0) > generation)
    #expect(try ReportingDocument.decode(after["document"] as? String, now: date).deletion == "idle")
  }

  @Test func lateNativeCallbacksCannotSurviveWithdrawalOrReenable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let collector = ReportingTestCollector()
    let store = store(ReportingMemory(), directory: directory, collector: collector)
    _ = try store.consent(enabled: true, renewIdentity: false)
    collector.deliver(report(), from: 0)
    _ = try store.consent(enabled: false, renewIdentity: false)
    collector.deliver(report(), from: 0)
    #expect((try store.takeNative()["reports"] as? [Any])?.isEmpty == true)
    _ = try store.consent(enabled: true, renewIdentity: false)
    collector.deliver(report(), from: 0)
    #expect((try store.takeNative()["reports"] as? [Any])?.isEmpty == true)
    for _ in 0..<40 { collector.deliver(report(), from: 1) }
    collector.deliver(report(createdAt: date.timeIntervalSince1970 * 1000 - 86_400_001), from: 1)
    #expect((try store.takeNative()["reports"] as? [Any])?.count == 32)
    #expect((try store.takeNative()["reports"] as? [Any])?.isEmpty == true)
  }

  @Test func rawCacheExpiresBeforeCollectorStartAndWithdrawalPurgesEverything() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = store(ReportingMemory(), directory: directory, collector: ReportingTestCollector())
    _ = store.read()
    try FileManager.default.createDirectory(at: store.cache, withIntermediateDirectories: true)
    let expired = store.cache.appendingPathComponent("raw-expired.json")
    try Data("synthetic raw report".utf8).write(to: expired)
    try FileManager.default.setAttributes(
      [.modificationDate: date.addingTimeInterval(-86_401)], ofItemAtPath: expired.path)
    for index in 0..<70 {
      let file = store.cache.appendingPathComponent("raw-\(index).json")
      try Data("synthetic".utf8).write(to: file)
      try FileManager.default.setAttributes(
        [.modificationDate: date.addingTimeInterval(Double(-index))], ofItemAtPath: file.path)
    }
    _ = try store.consent(enabled: true, renewIdentity: false)
    #expect(!FileManager.default.fileExists(atPath: expired.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.cache.path).count == 64)
    _ = try store.consent(enabled: false, renewIdentity: false)
    #expect(!FileManager.default.fileExists(atPath: store.cache.path))
  }

  @Test func keychainFailureKeepsIdentityUnavailableAndDurableWithdrawalOverridesOldConsent() throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let memory = ReportingMemory()
    memory.locked = true
    let collector = ReportingTestCollector()
    let store = store(memory, directory: directory, collector: collector)
    #expect(store.read()["available"] as? Bool == false)
    #expect(store.read()["identityAvailable"] as? Bool == false)
    #expect(throws: (any Error).self) { try store.consent(enabled: true, renewIdentity: false) }
    #expect(collector.callbacks.isEmpty)
    memory.locked = false
    let enabled = try store.consent(enabled: true, renewIdentity: false)
    let stored = memory.data
    memory.locked = true
    #expect(store.read()["available"] as? Bool == false)
    #expect(!collector.active)
    #expect(memory.data == stored)
    memory.locked = false
    let recovered = store.read()
    #expect(recovered["enabled"] as? Bool == true)
    #expect(recovered["generation"] as? Int == enabled["generation"] as? Int)
    #expect(collector.active)
    #expect(memory.data == stored)
    memory.locked = true
    try store.disableForAccountRemoval()
    #expect(!collector.active)
    memory.locked = false
    #expect(store.read()["enabled"] as? Bool == false)
    let reopened = self.store(memory, directory: directory, collector: ReportingTestCollector())
    #expect(reopened.read()["enabled"] as? Bool == false)
  }

  @Test func accountWithdrawalUsesDisabledCustodyWhenTheMarkerCannotBeWritten() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let memory = ReportingMemory()
    let collector = ReportingTestCollector()
    let store = store(memory, directory: directory, collector: collector)
    _ = try store.consent(enabled: true, renewIdentity: false)
    try Data("blocked directory".utf8).write(to: directory)
    try store.disableForAccountRemoval()
    #expect(!collector.active)
    let reopenedCollector = ReportingTestCollector()
    let reopened = self.store(memory, directory: directory, collector: reopenedCollector)
    #expect(reopened.read()["enabled"] as? Bool == false)
    #expect(reopenedCollector.callbacks.isEmpty)
  }

  @Test(arguments: ["directory", "marker", "stale-marker"])
  func accountWithdrawalRequiresADurableFenceBeforeCleanup(_ filesystemBlocker: String) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: directory)
    }
    let memory = ReportingMemory()
    let collector = ReportingTestCollector()
    let store = store(memory, directory: directory, collector: collector)
    let enabled = try store.consent(enabled: true, renewIdentity: false)
    let generation = try #require(enabled["generation"] as? Int)
    let stored = memory.data
    let marker = directory.appendingPathComponent("withdrawn")
    if filesystemBlocker == "directory" {
      try Data("blocked directory".utf8).write(to: directory)
    } else if filesystemBlocker == "marker" {
      try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
    } else {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(String(generation - 1).utf8).write(to: marker, options: .atomic)
      try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: directory.path)
    }
    memory.locked = filesystemBlocker != "stale-marker"
    memory.writeFails = filesystemBlocker == "stale-marker"
    #expect(throws: (any Error).self) { try store.disableForAccountRemoval() }
    #expect(!collector.active)
    #expect(memory.data == stored)
    #expect(store.read()["enabled"] as? Bool == false)
    if filesystemBlocker == "stale-marker" {
      #expect(try String(contentsOf: marker, encoding: .utf8) == String(generation - 1))
      try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path)
    }
    try FileManager.default.removeItem(at: directory)
    try store.disableForAccountRemoval()
    #expect(!collector.active)
    #expect(memory.data == stored)
    memory.locked = false
    memory.writeFails = false
    let reopenedCollector = ReportingTestCollector()
    let reopened = self.store(memory, directory: directory, collector: reopenedCollector)
    #expect(reopened.read()["enabled"] as? Bool == false)
    #expect(reopenedCollector.callbacks.isEmpty)
  }

  @Test func publicNativeProjectionExcludesArbitraryMessagesPathsAndImageNames() throws {
    let event = Event()
    event.timestamp = date
    let exception = Exception(
      value: "secret-mailbox@example.invalid", type: "PrivateUserTextException")
    let frames = (0..<100).map { index in
      let frame = Frame()
      frame.instructionAddress = "0x" + String(0x1000 + index, radix: 16)
      frame.imageAddress = "0x1000"
      frame.fileName = "/Users/private/mailbox.eml"
      frame.function = "credential-containing-function"
      return frame
    }
    exception.stacktrace = SentryStacktrace(
      frames: frames, registers: ["private-register": "secret-register-value"])
    event.exceptions = [exception]
    let image = DebugMeta()
    image.debugID = UUID().uuidString
    image.imageAddress = "0x1000"
    event.debugMeta = [image]
    let projection = try #require(SentryReportingCollector.project(event, now: date))
    #expect(projection.name == "NativeCrash" && projection.message == nil)
    #expect(projection.frames.count == 64)
    let encoded = try JSONEncoder().encode(projection)
    let serialized = try JSONDecoder().decode(ReportingReport.self, from: encoded)
    let expected = (36..<100).map { "0x" + String(0x1000 + $0, radix: 16) }
    #expect(serialized.frames.compactMap(\.address) == expected)
    #expect(serialized.frames.last?.address == "0x1063")
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains("mailbox") && !text.contains("credential") && !text.contains("/Users"))
    #expect(!text.contains("register"))
    event.timestamp = date.addingTimeInterval(-86_401)
    #expect(SentryReportingCollector.project(event, now: date) == nil)
  }

  @Test func nativeWithdrawalKeepsMarkerUntilServerAcknowledges() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let memory = ReportingMemory()
    let collector = ReportingTestCollector()
    let store = store(memory, directory: directory, collector: collector)
    _ = try store.consent(enabled: true, renewIdentity: false)
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    ReportingHTTPProtocol.recording.reset(status: 503, started: { continuation.yield() })
    try store.disableForAccountRemoval()
    for await _ in stream { break }
    let marker = directory.appendingPathComponent("withdrawn")
    #expect(FileManager.default.fileExists(atPath: marker.path))
    let generation = try #require(store.read()["generation"] as? Int)
    await #expect(throws: ReportingError.retry) {
      _ = try await store.request(operation: "revoke", body: "{}", generation: generation)
    }
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(
      ReportingHTTPProtocol.recording.captured().allSatisfy {
        $0.url?.path == "/api/error-reporting/revoke"
      })
    ReportingHTTPProtocol.recording.reset(reply: "disabled")
    _ = try await store.request(operation: "revoke", body: "{}", generation: generation)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(store.read()["enabled"] as? Bool == false)
  }

  @Test func deletionDistinguishesOfflineFromServerFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = store(ReportingMemory(), directory: directory, collector: ReportingTestCollector())
    let on = try store.consent(enabled: true, renewIdentity: false)
    let generation = try #require(on["generation"] as? Int)
    ReportingHTTPProtocol.recording.reset(failure: .notConnectedToInternet)
    await #expect(throws: ReportingError.offline) {
      _ = try await store.request(operation: "delete", body: "{}", generation: generation)
    }
    ReportingHTTPProtocol.recording.reset(status: 503)
    await #expect(throws: ReportingError.retry) {
      _ = try await store.request(operation: "delete", body: "{}", generation: generation)
    }
  }

  @Test func HTTPAllowlistGenerationCredentialInjectionAndCancelledCapture() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReportingHTTPProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let memory = ReportingMemory()
    let store = store(
      memory, directory: directory, collector: ReportingTestCollector(), session: session)
    ReportingHTTPProtocol.recording.reset()
    _ = store.read()
    await #expect(throws: ReportingError.disabled) {
      _ = try await store.request(operation: "capture", body: "{}", generation: 0)
    }
    await #expect(throws: ReportingError.invalid) {
      _ = try await store.request(operation: "unknown", body: "{}", generation: 0)
    }
    let on = try store.consent(enabled: true, renewIdentity: false)
    let generation = try #require(on["generation"] as? Int)
    await #expect(throws: ReportingError.stale) {
      _ = try await store.request(operation: "status", body: "{}", generation: generation - 1)
    }
    _ = try await store.request(operation: "enable", body: "{}", generation: generation)
    let request = try #require(ReportingHTTPProtocol.recording.captured().last)
    #expect(
      request.url?.absoluteString == "https://synthetic.convex.site/api/error-reporting/enable")
    let bodyData = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(UUID(uuidString: try #require(body["installationId"] as? String)) != nil)
    #expect((body["credential"] as? String)?.count == 64)
    let capture = String(decoding: try JSONEncoder().encode(["reports": [report()]]), as: UTF8.self)
    _ = try await store.request(operation: "capture", body: capture, generation: generation)
    let sent = try #require(ReportingHTTPProtocol.recording.captured().last?.httpBody)
    let sentBody = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
    let sentMetadata = try #require(sentBody["metadata"] as? [String: Any])
    #expect(sentMetadata["appNamespace"] as? String == "dev.unwired.mail")
    #expect(sentMetadata["appVersion"] as? String == "1")
    #expect(sentMetadata["build"] as? String == "1")
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    ReportingHTTPProtocol.recording.reset(hold: true, started: { continuation.yield() })
    let task = Task {
      _ = try await store.request(operation: "capture", body: capture, generation: generation)
    }
    for await _ in stream { break }
    _ = try store.consent(enabled: false, renewIdentity: false)
    let result = await task.result
    if case .success = result {
      Issue.record("Cancelled capture must not return a successful response")
    }
    #expect(store.read()["enabled"] as? Bool == false)
  }
}
