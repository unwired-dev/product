import XCTest

final class MailTestBootstrapUITests: XCTestCase {
  func testSeededMessageAppearsInVisibleMailbox() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(
      app.staticTexts["Synthetic seed"].waitForExistence(timeout: 60),
      "The production IMAP path did not present the seeded synthetic message."
    )
  }
}
