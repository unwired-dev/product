import Foundation
import Sentry

// This session is local to the collector. Never register this protocol globally or use mailSession.
private final class ReportingBlockedProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
  }
  override func stopLoading() {}
}

@MainActor final class SentryReportingCollector: ReportingCollector {
  private let cache: URL
  private var started = false

  init(cache: URL) { self.cache = cache }

  func start(
    generation: Int, receive: @escaping @MainActor @Sendable (Int, ReportingReport) -> Void
  ) throws {
    guard !started else { return }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReportingBlockedProtocol.self]
    SentrySDK.start { options in
      // A syntactically valid local DSN; every SDK request is permanently blocked before a socket.
      options.dsn = "http://local-collector@127.0.0.1:1/1"
      options.urlSession = URLSession(configuration: configuration)
      options.cacheDirectoryPath = self.cache.path
      options.enableAutoSessionTracking = false
      options.enableWatchdogTerminationTracking = false
      options.enableAutoPerformanceTracing = false
      options.enableAppHangTracking = false
      options.enableSwizzling = false
      options.enableNetworkTracking = false
      options.enableFileIOTracing = false
      options.enableMetrics = false
      options.enableAutoBreadcrumbTracking = false
      options.enableNetworkBreadcrumbs = false
      options.enableCaptureFailedRequests = false
      options.enablePersistingTracesWhenCrashing = false
      options.enableMemoryIntrospection = false
      options.sendDefaultPii = false
      options.attachStacktrace = true
      options.maxBreadcrumbs = 0
      options.maxCacheItems = 32
      options.shutdownTimeInterval = 0
      options.beforeBreadcrumb = { _ in nil }
      options.beforeSend = { event in
        if let projection = Self.project(event, now: Date()) {
          Task { @MainActor in receive(generation, projection) }
        }
        return nil
      }
    }
    started = true
  }

  func stop() {
    guard started else { return }
    started = false
    // close flushes, so the permanently blocked SDK session is required even during teardown.
    SentrySDK.close()
  }

  nonisolated static func project(_ event: Event, now: Date) -> ReportingReport? {
    guard let timestamp = event.timestamp, timestamp > now.addingTimeInterval(-86_400),
      timestamp <= now.addingTimeInterval(60), let exception = event.exceptions?.first
    else { return nil }
    let nativeNames: Set<String> = [
      "NSException", "NSInvalidArgumentException", "NSRangeException",
      "NSInternalInconsistencyException",
    ]
    let name = exception.type.flatMap { nativeNames.contains($0) ? $0 : nil } ?? "NativeCrash"
    let message = exception.value.flatMap { ReportingReport.messages.contains($0) ? $0 : nil }
    let images = event.debugMeta ?? []
    let stack =
      exception.stacktrace?.frames
      ?? event.threads?.first(where: { $0.crashed?.boolValue == true })?.stacktrace?.frames ?? []
    let frames: [ReportingFrame] = stack.compactMap { frame in
      guard ReportingFrame.hex(frame.instructionAddress), ReportingFrame.hex(frame.imageAddress),
        let image = images.first(where: { $0.imageAddress == frame.imageAddress }),
        let uuid = image.debugID, UUID(uuidString: uuid) != nil
      else { return nil }
      return ReportingFrame(
        kind: "native", address: frame.instructionAddress,
        imageUuid: uuid.lowercased(), imageAddress: frame.imageAddress)
    }
    return ReportingReport(
      id: UUID().uuidString.lowercased(),
      createdAt: (timestamp.timeIntervalSince1970 * 1000).rounded(.down),
      code: "native-crash", name: name, message: message, frames: Array(frames.prefix(64)),
      causes: [], breadcrumbs: [])
  }
}

@MainActor enum ErrorReportingRuntime {
  static let shared: ErrorReportingStore = {
    let bundle = Bundle.main
    let identifier = bundle.bundleIdentifier ?? "dev.unwired.mail"
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(identifier).appendingPathComponent(
        "ErrorReporting", isDirectory: true)
    let base = (bundle.object(forInfoDictionaryKey: "UnwiredConvexURL") as? String)
      .flatMap(URL.init(string:)).flatMap { ConvexURL.site($0, path: "/") }
    let qualification =
      bundle.object(forInfoDictionaryKey: "UnwiredErrorReportingQualification") as? Bool == true
    #if DEBUG
      let available = qualification
    #else
      let available =
        qualification || bundle.object(forInfoDictionaryKey: "UnwiredMockScenario") == nil
    #endif
    let configured = bundle.object(forInfoDictionaryKey: "UnwiredErrorReportingChannel") as? String
    let channel =
      ["production", "testflight", "qualification"].contains(configured ?? "")
      ? configured! : "production"
    #if os(iOS)
      let platform = "ios"
    #else
      let platform = "macos"
    #endif
    return ErrorReportingStore(
      persistence: ReportingPersistence(
        keys: DeviceKeychain(service: identifier + ".error-reporting")),
      directory: directory, base: base, available: available,
      nativeQualified: bundle.object(forInfoDictionaryKey: "UnwiredNativeErrorReportingQualified")
        as? Bool == true,
      metadata: ReportingMetadata(
        platform: platform,
        appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
          ?? "0",
        build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
        osVersion:
          "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.patchVersion)",
        channel: channel),
      collector: SentryReportingCollector(
        cache: directory.appendingPathComponent("collector", isDirectory: true)))
  }()
}
