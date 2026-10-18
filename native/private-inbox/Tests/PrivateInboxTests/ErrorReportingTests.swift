import Foundation
import Sentry
import Testing

@testable import PrivateInbox

@MainActor private final class ReportingMemory {
  var data: Data?
  var locked = false
  var persistence: ReportingPersistence {
    ReportingPersistence(
      read: {
        if self.locked { throw PrivateInboxError.locked }
        return self.data
      },
      write: {
        if self.locked { throw PrivateInboxError.locked }
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
    let document = ReportingDocument.decode(off["document"] as? String, now: date)
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
    #expect(ReportingHTTPProtocol.recording.captured().isEmpty)
    store.disableForAccountRemoval()
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
    let document = ReportingDocument.decode(off["document"] as? String, now: date)
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
    let document = ReportingDocument.decode(reopened.read()["document"] as? String, now: date)
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
    let document = ReportingDocument.decode(off["document"] as? String, now: date)
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
    #expect(ReportingDocument.decode(after["document"] as? String, now: date).deletion == "idle")
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
    store.disableForAccountRemoval()
    #expect(!collector.active)
    memory.locked = false
    #expect(store.read()["enabled"] as? Bool == false)
    let reopened = self.store(memory, directory: directory, collector: ReportingTestCollector())
    #expect(reopened.read()["enabled"] as? Bool == false)
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
    store.disableForAccountRemoval()
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
