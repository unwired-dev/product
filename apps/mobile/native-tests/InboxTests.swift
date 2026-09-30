import XCTest

final class InboxTests: XCTestCase {
  func testSelectAndReplaceMessage() {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.unwired.mail.preview")
    app.launch()
    XCTAssertTrue(app.staticTexts["Inbox"].waitForExistence(timeout: 20))
    verifyLanguagePreference(in: app)
    let maya = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Maya Chen"))
      .firstMatch
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
    let oliver = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Oliver Park"))
      .firstMatch
    if !oliver.isHittable {
      let back = app.navigationBars.buttons.firstMatch
      XCTAssertTrue(back.exists)
      back.tap()
    }
    XCTAssertTrue(oliver.isHittable)
    oliver.tap()
    XCTAssertTrue(app.staticTexts["oliver@example.com"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["maya@example.com"].exists)
    app.buttons["Mark as read"].tap()
    XCTAssertTrue(app.buttons["Mark as unread"].waitForExistence(timeout: 10))
    app.terminate()
    app.launch()
    let restored = app.buttons["Oliver Park. Saturday, by the river?"]
    XCTAssertTrue(restored.waitForExistence(timeout: 20))
    restored.tap()
    XCTAssertTrue(app.buttons["Mark as unread"].waitForExistence(timeout: 10))
  }

  private func verifyLanguagePreference(in app: XCUIApplication) {
    let english = app.descendants(matching: .any)["language-en"]
    XCTAssertTrue(english.waitForExistence(timeout: 10))
    english.tap()
    let checked = NSPredicate(format: "value CONTAINS 'checked' AND NOT value CONTAINS 'unchecked'")
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: checked, object: english)], timeout: 10),
      .completed)
    app.terminate()
    app.launch()
    XCTAssertTrue(english.waitForExistence(timeout: 20))
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: checked, object: english)], timeout: 10),
      .completed)
    let system = app.descendants(matching: .any)["language-system"]
    system.tap()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: checked, object: system)], timeout: 10),
      .completed)
  }

}
