import XCTest

@testable import unwired_mail

final class DotEnvFileTests: XCTestCase {
  override func tearDown() {
    DotEnvFile.resetForTesting()
    super.tearDown()
  }

  func testParseSkipsCommentsAndEmptyLines() {
    let parsed = DotEnvFile.parse(
      """
      # comment

      CONVEX_URL=https://example.convex.cloud
      """
    )

    XCTAssertEqual(parsed, ["CONVEX_URL": "https://example.convex.cloud"])
  }

  func testParseHandlesExportPrefixAndQuotedValues() {
    let parsed = DotEnvFile.parse(
      """
      export CONVEX_URL="https://example.convex.cloud"
      OTHER='single quoted'
      """
    )

    XCTAssertEqual(
      parsed,
      [
        "CONVEX_URL": "https://example.convex.cloud",
        "OTHER": "single quoted",
      ]
    )
  }

  func testLoadStoresParsedValues() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let envFile = directory.appendingPathComponent(".env.local")
    try """
    DOTENV_TEST_KEY=https://example.convex.cloud
    """.write(to: envFile, atomically: true, encoding: .utf8)

    try DotEnvFile.load(at: envFile)

    XCTAssertEqual(DotEnvFile.value(for: "DOTENV_TEST_KEY"), "https://example.convex.cloud")
  }
}
