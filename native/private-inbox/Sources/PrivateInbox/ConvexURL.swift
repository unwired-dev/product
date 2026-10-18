import Foundation

enum ConvexURL {
  static func site(_ base: URL, path: String) -> URL? {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
      components.scheme == "https", let host = components.host, components.user == nil,
      components.password == nil, components.query == nil, components.fragment == nil,
      host.hasSuffix(".convex.cloud") || host.hasSuffix(".convex.site")
    else { return nil }
    if host.hasSuffix(".convex.cloud") {
      components.host = String(host.dropLast(".convex.cloud".count)) + ".convex.site"
    }
    components.path = path
    return components.url
  }
}
