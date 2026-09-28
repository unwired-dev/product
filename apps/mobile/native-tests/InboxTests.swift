import XCTest

final class InboxTests: XCTestCase {
  func testSelectAndReplaceMessage() {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.unwired.mail.preview")
    app.launch()
    XCTAssertTrue(app.staticTexts["Inbox"].waitForExistence(timeout: 20))
    let maya = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Maya Chen")).firstMatch
    XCTAssertTrue(maya.waitForExistence(timeout: 10))
    maya.tap()
    let sender = app.staticTexts.matching(identifier: "maya@example.com").firstMatch
    XCTAssertTrue(sender.waitForExistence(timeout: 10))
    if UIDevice.current.userInterfaceIdiom == .pad {
      XCTAssertGreaterThan(sender.frame.minX, maya.frame.maxX)
    }
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Selected message"
    shot.lifetime = .keepAlways
    add(shot)
    let oliver = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Oliver Park")).firstMatch
    if !oliver.isHittable {
      let back = app.navigationBars.buttons.firstMatch
      XCTAssertTrue(back.exists)
      back.tap()
    }
    XCTAssertTrue(oliver.isHittable)
    oliver.tap()
    XCTAssertTrue(app.staticTexts["oliver@example.com"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["maya@example.com"].exists)
  }
}
