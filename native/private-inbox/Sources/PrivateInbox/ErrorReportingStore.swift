import Foundation
import Security

private final class ReportingHTTPDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

@MainActor protocol ReportingCollector: AnyObject {
  func start(
    generation: Int, receive: @escaping @MainActor @Sendable (Int, ReportingReport) -> Void) throws
  func stop()
}

@MainActor struct ReportingPersistence {
  let read: () throws -> Data?
  let write: (Data) throws -> Void

  init(keys: DeviceKeychain) {
    read = { try keys.read("installation") }
    write = { try keys.save($0, account: "installation") }
  }
  init(read: @escaping () throws -> Data?, write: @escaping (Data) throws -> Void) {
    self.read = read
    self.write = write
  }
}

@MainActor final class ErrorReportingStore {
  private struct State: Codable {
    var installationId: String
    var credential: String
    var generation = 0
    var enabled = false
    var everEnabled = false
    var revocationPending = false
    var document: String?
    var native: [ReportingReport] = []
  }
  private let persistence: ReportingPersistence
  private let directory: URL
  private let base: URL?
  private let available: Bool
  private let nativeQualified: Bool
  private let metadata: ReportingMetadata
  private let collector: any ReportingCollector
  private let session: URLSession
  private let now: () -> Date
  private var startedGeneration: Int?
  private var tasks: [UUID: (String, URLSessionDataTask)] = [:]
  private var blocked = false
  private var unreadable = false
  private var revokingGeneration: Int?

  init(
    persistence: ReportingPersistence, directory: URL, base: URL?, available: Bool,
    nativeQualified: Bool, metadata: ReportingMetadata, collector: any ReportingCollector,
    session: URLSession = URLSession(
      configuration: .ephemeral, delegate: ReportingHTTPDelegate(), delegateQueue: nil),
    now: @escaping () -> Date = Date.init
  ) {
    self.persistence = persistence
    self.directory = directory
    self.base = base
    self.available = available && base != nil
    self.nativeQualified = nativeQualified
    self.metadata = metadata
    self.collector = collector
    self.session = session
    self.now = now
  }

  private var marker: URL { directory.appendingPathComponent("withdrawn") }
  var cache: URL { directory.appendingPathComponent("collector", isDirectory: true) }

  private func fresh() throws -> State {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw ReportingError.unavailable
    }
    return State(
      installationId: UUID().uuidString.lowercased(),
      credential: bytes.map { String(format: "%02x", $0) }.joined())
  }

  private func load() throws -> State {
    var value: State
    let stored = try persistence.read()
    if let data = stored {
      value = try JSONDecoder().decode(State.self, from: data)
      guard UUID(uuidString: value.installationId) != nil, value.credential.count == 64,
        value.credential.allSatisfy({ $0.isASCII && $0.isHexDigit }),
        value.generation >= 0, value.generation < 9_007_199_254_740_991
      else { throw ReportingError.unavailable }
    } else {
      value = try fresh()
    }
    let hasMarker = FileManager.default.fileExists(atPath: marker.path)
    let markerGeneration = (try? String(contentsOf: marker, encoding: .utf8)).flatMap(Int.init)
    let pendingWithdrawal =
      hasMarker && (markerGeneration == nil || markerGeneration! >= value.generation)
    var document = ReportingDocument.decode(value.document, now: now())
    let pendingDeletion = ["pending", "offline", "failed"].contains(document.deletion)
    if pendingDeletion { blockCollection() }
    if (pendingWithdrawal || !available || blocked) && value.enabled {
      value.enabled = false
      value.generation += 1
      value.revocationPending = value.revocationPending || (pendingDeletion && value.everEnabled)
      document.queue = []
      value.document = try document.encoded()
      value.native = []
      try persist(value)
      if hasMarker { try? Data(String(value.generation).utf8).write(to: marker, options: .atomic) }
    } else if stored == nil {
      try persist(value)
    }
    unreadable = false
    return value
  }

  private func persist(_ value: State) throws {
    try persistence.write(JSONEncoder().encode(value))
  }

  private func advance(_ value: inout State) throws {
    guard value.generation < 9_007_199_254_740_990 else { throw ReportingError.unavailable }
    value.generation += 1
  }

  private func snapshot(_ value: State?, usable: Bool) -> [String: Any] {
    [
      "enabled": usable && !blocked && !unreadable && value?.enabled == true,
      "generation": value?.generation ?? 0,
      "document": value?.document as Any? ?? NSNull(),
      "available": usable,
      "nativeAvailable": usable && nativeQualified,
      "identityAvailable": value != nil,
      "metadata": [
        "appNamespace": metadata.appNamespace,
        "platform": metadata.platform, "appVersion": metadata.appVersion,
        "build": metadata.build, "osVersion": metadata.osVersion, "channel": metadata.channel,
      ],
    ]
  }

  func read() -> [String: Any] {
    do {
      let value = try load()
      try synchronizeCollector(value)
      retryWithdrawal(value)
      return snapshot(value, usable: available)
    } catch {
      unreadable = true
      stopCollection()
      try? purgeCache()
      return snapshot(nil, usable: false)
    }
  }

  private func blockCollection() {
    blocked = true
    stopCollection()
  }

  private func stopCollection() {
    startedGeneration = nil
    for (_, (operation, task)) in tasks where operation == "capture" || operation == "enable" {
      task.cancel()
    }
    collector.stop()
  }

  // An independent marker survives a locked Keychain or interrupted account cleanup.
  func disableForAccountRemoval() {
    _ = try? consent(enabled: false, renewIdentity: false)
    if let value = try? load() { retryWithdrawal(value) }
  }

  private func retryWithdrawal(_ value: State) {
    guard available, value.everEnabled, !value.enabled,
      value.revocationPending || FileManager.default.fileExists(atPath: marker.path),
      revokingGeneration != value.generation
    else { return }
    revokingGeneration = value.generation
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { if self.revokingGeneration == value.generation { self.revokingGeneration = nil } }
      _ = try? await self.request(operation: "revoke", body: "{}", generation: value.generation)
    }
  }

  func consent(enabled: Bool, renewIdentity: Bool, expectedGeneration: Int? = nil) throws -> [String: Any] {
    var value: State
    var purgeFailed = false
    if !enabled {
      let previous = try? load()
      blocked = true
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? Data().write(to: marker, options: .atomic)
      blockCollection()
      do { try purgeCache() } catch { purgeFailed = true }
      value = try previous ?? load()
    } else {
      value = try load()
    }
    guard !enabled || available else { throw ReportingError.unavailable }
    if enabled, let expectedGeneration, expectedGeneration != value.generation {
      throw ReportingError.stale
    }
    var document = ReportingDocument.decode(value.document, now: now())
    if enabled && ["pending", "offline", "failed"].contains(document.deletion) {
      throw ReportingError.disabled
    }
    if renewIdentity {
      guard enabled, !value.enabled, document.deletion == "complete" else {
        throw ReportingError.invalid
      }
      let identity = try fresh()
      value.installationId = identity.installationId
      value.credential = identity.credential
      document = ReportingDocument()
    }
    try advance(&value)
    value.enabled = enabled
    value.everEnabled = value.everEnabled || enabled
    if !enabled && value.everEnabled { value.revocationPending = true }
    value.native = []
    document.queue = []
    value.document = try document.encoded()
    try persist(value)
    if enabled {
      blocked = false
      try synchronizeCollector(value)
    } else {
      try? Data(String(value.generation).utf8).write(to: marker, options: .atomic)
    }
    if purgeFailed { throw ReportingError.unavailable }
    return snapshot(value, usable: available)
  }

  func save(generation: Int, document: String) throws -> Bool {
    var value = try load()
    guard generation == value.generation else { return false }
    guard document.utf8.count <= 1_048_576,
      var decoded = try? JSONDecoder().decode(ReportingDocument.self, from: Data(document.utf8)),
      decoded.version == 1,
      ["idle", "pending", "offline", "failed", "complete", "missing"].contains(decoded.deletion),
      decoded.queue.count <= 100, decoded.queue.allSatisfy({ $0.valid(now: now()) }),
      (value.enabled && !blocked && !unreadable) || decoded.queue.isEmpty
    else { return false }
    let pendingDeletion = ["pending", "offline", "failed"].contains(decoded.deletion)
    if pendingDeletion {
      if !["pending", "offline", "failed"].contains(
        ReportingDocument.decode(value.document, now: now()).deletion)
      {
        try advance(&value)
      }
      value.enabled = false
      value.revocationPending = value.revocationPending || value.everEnabled
      decoded.queue = []
      value.native = []
    }
    value.document = try decoded.encoded()
    try persist(value)
    if pendingDeletion {
      blockCollection()
      try purgeCache()
    }
    return true
  }

  private func synchronizeCollector(_ value: State) throws {
    guard value.enabled && available && nativeQualified && !blocked && !unreadable else {
      collector.stop()
      startedGeneration = nil
      try purgeCache()
      return
    }
    guard startedGeneration != value.generation else { return }
    collector.stop()
    try pruneCache()
    startedGeneration = value.generation
    do {
      try collector.start(generation: value.generation) { [weak self] generation, report in
        self?.receive(generation: generation, report: report)
      }
    } catch {
      startedGeneration = nil
      collector.stop()
      try? purgeCache()
      throw ReportingError.unavailable
    }
  }

  private func receive(generation: Int, report: ReportingReport) {
    guard var value = try? load(), value.enabled, !blocked, !unreadable, nativeQualified,
      value.generation == generation, report.valid(now: now())
    else { return }
    value.native = Array((value.native.filter { $0.valid(now: now()) } + [report]).suffix(32))
    do { try persist(value) } catch {
      blockCollection()
      try? purgeCache()
    }
  }

  func takeNative() throws -> [String: Any] {
    var value = try load()
    let reports =
      value.enabled && !blocked && !unreadable && nativeQualified
      ? value.native.filter { $0.valid(now: now()) } : []
    value.native = []
    try persist(value)
    let data = try JSONEncoder().encode(reports)
    return ["reports": try JSONSerialization.jsonObject(with: data)]
  }

  private func purgeCache() throws {
    if FileManager.default.fileExists(atPath: cache.path) {
      try FileManager.default.removeItem(at: cache)
    }
  }

  // Raw crash reports are processed by the SDK at start, so prune before installing it.
  func pruneCache() throws {
    guard
      let files = FileManager.default.enumerator(
        at: cache,
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
    else { return }
    var entries: [(URL, Date, Int)] = []
    for case let url as URL in files {
      let properties = try url.resourceValues(forKeys: [
        .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
      ])
      guard properties.isRegularFile == true else { continue }
      entries.append(
        (url, properties.contentModificationDate ?? .distantPast, properties.fileSize ?? 0))
    }
    var bytes = 0
    var count = 0
    for (url, date, size) in entries.sorted(by: { $0.1 > $1.1 }) {
      if date <= now().addingTimeInterval(-86_400) || date > now().addingTimeInterval(60)
        || bytes + size > 8_388_608 || count >= 64
      {
        try FileManager.default.removeItem(at: url)
      } else {
        bytes += size
        count += 1
      }
    }
  }

  func request(operation: String, body: String, generation: Int) async throws -> [String: Any] {
    guard ["enable", "capture", "revoke", "delete", "status"].contains(operation),
      body.utf8.count <= 1_048_576, let base
    else { throw ReportingError.invalid }
    let value = try load()
    guard value.generation == generation else { throw ReportingError.stale }
    guard available else { throw ReportingError.unavailable }
    // An installation that never opted in has no reporting authority to withdraw remotely.
    if !value.everEnabled {
      if operation == "revoke" { return ["status": "disabled"] }
      if operation == "delete" || operation == "status" { return ["status": "complete"] }
    }
    if operation == "enable" || operation == "capture" {
      guard value.enabled && !blocked && !unreadable else { throw ReportingError.disabled }
    }
    var payload: [String: Any] = [:]
    if operation == "capture" {
      struct Capture: Decodable { let reports: [ReportingReport] }
      let capture = try JSONDecoder().decode(Capture.self, from: Data(body.utf8))
      guard !capture.reports.isEmpty, capture.reports.count <= 10,
        capture.reports.allSatisfy({ $0.valid(now: now()) })
      else { throw ReportingError.invalid }
      payload["reports"] = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(capture.reports))
      payload["metadata"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata))
    } else {
      guard let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
        object.isEmpty
      else {
        throw ReportingError.invalid
      }
    }
    payload["installationId"] = value.installationId
    payload["credential"] = value.credential
    payload["generation"] = generation
    guard let url = ConvexURL.site(base, path: "/api/error-reporting/" + operation) else {
      throw ReportingError.unavailable
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 10
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let identifier = UUID()
    defer { tasks.removeValue(forKey: identifier) }
    let (data, status): (Data, Int)
    do {
      (data, status) = try await withCheckedThrowingContinuation { continuation in
        let task = session.dataTask(with: request) { data, response, error in
          if let error {
            let offline = (error as? URLError).map {
              [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                .internationalRoamingOff].contains($0.code)
            } ?? false
            continuation.resume(throwing: offline ? ReportingError.offline : ReportingError.retry)
            return
          }
          guard let data, data.count <= 16_384, let response = response as? HTTPURLResponse else {
            continuation.resume(throwing: ReportingError.retry)
            return
          }
          continuation.resume(returning: (data, response.statusCode))
        }
        tasks[identifier] = (operation, task)
        task.resume()
      }
    } catch {
      guard try load().generation == generation else { throw ReportingError.stale }
      throw error
    }
    guard try load().generation == generation else { throw ReportingError.stale }
    guard (200...299).contains(status) else { throw ReportingError.retry }
    struct Reply: Decodable {
      let status: String
      var retryAfterMs: Int?
    }
    guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
      ["enabled", "disabled", "accepted", "pending", "complete", "retry"].contains(reply.status)
    else { throw ReportingError.retry }
    if (operation == "revoke" && ["disabled", "complete"].contains(reply.status))
      || (operation == "enable" && reply.status == "enabled")
    {
      var current = try load()
      guard current.generation == generation else { throw ReportingError.stale }
      current.revocationPending = false
      try persist(current)
      try? FileManager.default.removeItem(at: marker)
    }
    var result: [String: Any] = ["status": reply.status]
    if let delay = reply.retryAfterMs, delay >= 0, delay <= 86_400_000 {
      result["retryAfterMs"] = delay
    }
    return result
  }
}
