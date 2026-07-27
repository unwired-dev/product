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
    let explicitValue =
      ProcessInfo.processInfo.environment["CONVEX_SITE_URL"]
      ?? DotEnvFile.value(for: "CONVEX_SITE_URL")
    return resolveConvexSiteURL(explicitValue: explicitValue, convexURL: convexURL)
  }

  static func resolveConvexSiteURL(explicitValue: String?, convexURL: URL?) -> URL? {
    if let explicitValue, !explicitValue.isEmpty {
      return URL(string: explicitValue)
    }
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
