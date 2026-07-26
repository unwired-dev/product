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

  static var convexSiteURL: URL? {
    guard let convexURL else { return nil }
    if convexURL.host()?.hasSuffix(".convex.cloud") == true {
      var components = URLComponents(url: convexURL, resolvingAgainstBaseURL: false)
      components?.host = convexURL.host()?.replacingOccurrences(
        of: ".convex.cloud",
        with: ".convex.site"
      )
      return components?.url
    }
    return convexURL
  }
}
