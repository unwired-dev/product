import Foundation

enum DotEnvFile {
  private static var loadedValues: [String: String] = [:]

  static func value(for key: String) -> String? {
    loadedValues[key]
  }

  static func load(at url: URL) throws {
    let contents = try String(contentsOf: url, encoding: .utf8)
    merge(parse(contents))
  }

  static func loadIfPresent(at url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return
    }

    try? load(at: url)
  }

  #if DEBUG
    static func loadDefaultsIfPresent() {
      let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

      for fileName in [".env.local", ".env"] {
        loadIfPresent(at: projectRoot.appendingPathComponent(fileName))
      }
    }

    static func resetForTesting() {
      loadedValues = [:]
    }
  #endif

  static func parse(_ contents: String) -> [String: String] {
    var result: [String: String] = [:]

    for line in contents.split(whereSeparator: \.isNewline) {
      var trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") {
        continue
      }

      if trimmed.hasPrefix("export ") {
        trimmed = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
      }

      guard let separator = trimmed.firstIndex(of: "=") else {
        continue
      }

      let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
      var value = String(trimmed[trimmed.index(after: separator)...])
        .trimmingCharacters(in: .whitespaces)
      value = unquote(value)

      if !key.isEmpty {
        result[key] = value
      }
    }

    return result
  }

  private static func merge(_ variables: [String: String]) {
    for (key, value) in variables {
      if let existing = ProcessInfo.processInfo.environment[key], !existing.isEmpty {
        continue
      }

      loadedValues[key] = value
    }
  }

  private static func unquote(_ value: String) -> String {
    guard value.count >= 2 else {
      return value
    }

    let first = value.first!
    let last = value.last!
    if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
      return String(value.dropFirst().dropLast())
    }

    return value
  }
}
