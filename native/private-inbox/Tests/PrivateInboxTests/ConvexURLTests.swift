import Foundation
import Testing

@testable import PrivateInbox

struct ConvexURLTests {
  @Test(arguments: ["https://synthetic.convex.cloud", "https://synthetic.convex.site"])
  func siteKeepsTheDeploymentAndReplacesThePath(base: String) throws {
    let base = try #require(URL(string: base + "/old-path"))
    #expect(
      ConvexURL.site(base, path: "/api/error-reporting/enable")?.absoluteString
        == "https://synthetic.convex.site/api/error-reporting/enable")
  }

  @Test(arguments: [
    "http://synthetic.convex.cloud", "https://example.invalid", "https://convex.cloud",
    "https://synthetic.convex.cloud.example.invalid", "https://user@synthetic.convex.cloud",
    "https://user:secret@synthetic.convex.site", "https://synthetic.convex.cloud?secret=value",
    "https://synthetic.convex.site#secret",
  ])
  func siteRefusesUntrustedOrCredentialBearingBases(base: String) throws {
    #expect(ConvexURL.site(try #require(URL(string: base)), path: "/api") == nil)
  }
}
