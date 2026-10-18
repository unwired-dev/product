import Foundation

// The bridge persists and forwards only this projection, never SDK dictionaries or serialized events.
struct ReportingFrame: Codable, Sendable {
  let kind: String
  var line: Int?
  var column: Int?
  var address: String?
  var imageUuid: String?
  var imageAddress: String?

  var valid: Bool {
    if kind == "javascript" {
      return (0...100_000_000).contains(line ?? -1) && (0...100_000_000).contains(column ?? -1)
        && address == nil
        && imageUuid == nil && imageAddress == nil
    }
    return kind == "native" && line == nil && column == nil
      && Self.hex(address) && Self.hex(imageAddress)
      && imageUuid.flatMap(UUID.init(uuidString:)) != nil
  }

  static func hex(_ value: String?) -> Bool {
    guard let value, value.hasPrefix("0x"), value.count <= 18, value.count > 2 else { return false }
    return value.dropFirst(2).allSatisfy { $0.isHexDigit && $0.isASCII }
  }
}

struct ReportingCause: Codable, Sendable {
  let name: String
  var message: String?
  var valid: Bool {
    ReportingReport.names.contains(name)
      && (message == nil || ReportingReport.messages.contains(message!))
  }
}

struct ReportingBreadcrumb: Codable, Sendable {
  let operation: String
  let stage: String
  var elapsedMs: Double?
  var status: Int?
  var valid: Bool {
    ["app", "send", "sync", "sign-in", "account", "draft", "reader", "settings"].contains(operation)
      && ["open", "start", "complete", "failed", "retry"].contains(stage)
      && (elapsedMs == nil
        || (elapsedMs!.isFinite && elapsedMs!.rounded(.down) == elapsedMs! && elapsedMs! >= 0
          && elapsedMs! <= 86_400_000))
      && (status == nil || (100...599).contains(status!))
  }
}

struct ReportingReport: Codable, Sendable {
  let id: String
  let createdAt: Double
  let code: String
  let name: String
  var message: String?
  let frames: [ReportingFrame]
  let causes: [ReportingCause]
  let breadcrumbs: [ReportingBreadcrumb]

  static let names: Set<String> = [
    "Error", "TypeError", "RangeError", "ReferenceError", "SyntaxError", "URIError", "NSException",
    "NSInvalidArgumentException", "NSRangeException", "NSInternalInconsistencyException",
    "NativeCrash", "OperationError",
  ]
  static let messages: Set<String> = [
    "Cannot convert undefined value to object", "Cannot convert undefined or null to object",
    "Maximum call stack size exceeded", "Invalid array length", "Invalid time value",
    "URI malformed",
    "Native bridge failed", "Synthetic native crash",
  ]
  func valid(now: Date) -> Bool {
    UUID(uuidString: id) != nil && createdAt.isFinite && createdAt.rounded(.down) == createdAt
      && createdAt <= 9_007_199_254_740_991
      && createdAt > now.timeIntervalSince1970 * 1000 - 86_400_000
      && createdAt <= now.timeIntervalSince1970 * 1000 + 60_000
      && [
        "unhandled-js", "native-crash", "send-failed", "sync-failed", "sign-in-failed",
        "operation-failed", "backend-failed",
      ].contains(code)
      && ReportingCause(name: name, message: message).valid
      && frames.count <= 64 && frames.allSatisfy(\.valid)
      && causes.count <= 8 && causes.allSatisfy(\.valid)
      && breadcrumbs.count <= 50 && breadcrumbs.allSatisfy(\.valid)
  }
}

struct ReportingDocument: Codable {
  var version = 1
  var queue: [ReportingReport] = []
  var deletion = "idle"

  static func decode(_ text: String?, now: Date) -> Self {
    guard let text, text.utf8.count <= 1_048_576,
      var document = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
      document.version == 1,
      ["idle", "pending", "offline", "failed", "complete", "missing"].contains(document.deletion)
    else { return Self() }
    document.queue = Array(document.queue.filter { $0.valid(now: now) }.suffix(100))
    return document
  }

  func encoded() throws -> String {
    String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
  }
}

struct ReportingMetadata: Codable, Equatable, Sendable {
  let platform: String
  let appVersion: String
  let build: String
  let osVersion: String
  let channel: String
}

enum ReportingError: Error, Equatable { case unavailable, disabled, stale, invalid, retry, offline }
