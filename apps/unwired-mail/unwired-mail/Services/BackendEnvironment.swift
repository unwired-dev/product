import Foundation

enum BackendEnvironment {
  static var convexURL: URL? {
    let rawValue =
      ProcessInfo.processInfo.environment["CONVEX_URL"]
      ?? DotEnvFile.value(for: "CONVEX_URL")

    guard let rawValue, !rawValue.isEmpty else {
      return nil
    }

    return URL(string: rawValue)
  }
}
