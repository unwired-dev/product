import Foundation
import Testing

@testable import unwired_mail

@Suite(.serialized)
final class DotEnvFileTests {
  @Test
  func testParseSkipsCommentsAndEmptyLines() {
    let parsed = DotEnvFile.parse(
      """
      # comment

      CONVEX_URL=https://example.convex.cloud
      """
    )

    #expect(parsed == ["CONVEX_URL": "https://example.convex.cloud"])
  }

  @Test
  func testParseHandlesExportPrefixAndQuotedValues() {
    let parsed = DotEnvFile.parse(
      """
      export CONVEX_URL="https://example.convex.cloud"
      OTHER='single quoted'
      """
    )

    #expect(
      parsed == [
        "CONVEX_URL": "https://example.convex.cloud",
        "OTHER": "single quoted",
      ])
  }

  @Test
  func testLoadStoresParsedValues() throws {
    defer { DotEnvFile.resetForTesting() }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let envFile = directory.appendingPathComponent(".env.local")
    try """
    DOTENV_TEST_KEY=https://example.convex.cloud
    """.write(to: envFile, atomically: true, encoding: .utf8)

    try DotEnvFile.load(at: envFile)

    #expect(DotEnvFile.value(for: "DOTENV_TEST_KEY") == "https://example.convex.cloud")
  }

  @Test
  func testAppleClientValuesExcludeBackendSecrets() {
    let values = DotEnvFile.parseAppleClientValues(
      """
      CONVEX_SITE_URL=https://example.convex.site
      CONVEX_URL=https://example.convex.cloud
      EWS_OAUTH_AUTHORIZATION_ENDPOINT=https://login.corp.example/authorize
      EWS_OAUTH_CLIENT_ID=ews-client-id
      EWS_OAUTH_SCOPE=openid offline_access EWS.AccessAsUser.All
      EWS_OAUTH_TOKEN_ENDPOINT=https://login.corp.example/token
      GMAIL_OAUTH_CLIENT_ID=client-id.apps.googleusercontent.com
      GMAIL_PUBSUB_TOPIC=projects/example/topics/gmail-push
      MICROSOFT_GRAPH_CLIENT_ID=microsoft-client-id
      APNS_PRIVATE_KEY=backend-secret
      GMAIL_PUSH_VERIFICATION_TOKEN=backend-secret
      """
    )

    #expect(
      values == [
        "CONVEX_SITE_URL": "https://example.convex.site",
        "CONVEX_URL": "https://example.convex.cloud",
        "EWS_OAUTH_AUTHORIZATION_ENDPOINT": "https://login.corp.example/authorize",
        "EWS_OAUTH_CLIENT_ID": "ews-client-id",
        "EWS_OAUTH_SCOPE": "openid offline_access EWS.AccessAsUser.All",
        "EWS_OAUTH_TOKEN_ENDPOINT": "https://login.corp.example/token",
        "GMAIL_OAUTH_CLIENT_ID": "client-id.apps.googleusercontent.com",
        "GMAIL_PUBSUB_TOPIC": "projects/example/topics/gmail-push",
        "MICROSOFT_GRAPH_CLIENT_ID": "microsoft-client-id",
      ])
  }

  @Test
  func testExplicitConvexSiteURLTakesPrecedenceOverDerivedURL() {
    #expect(
      BackendEnvironment.resolveConvexSiteURL(
        explicitValue: "https://custom.example.test",
        convexURL: URL(string: "https://example.convex.cloud")
      ) == URL(string: "https://custom.example.test"))
  }

  @Test
  func testConvexSiteURLFallsBackToDerivedDeploymentSite() {
    #expect(
      BackendEnvironment.resolveConvexSiteURL(
        explicitValue: nil,
        convexURL: URL(string: "https://example.convex.cloud")
      ) == URL(string: "https://example.convex.site"))
  }
}
