import XCTest

final class InboxTests: XCTestCase {
  func testSelectAndReplaceMessage() throws {
    continueAfterFailure = false
    let identifier = try XCTUnwrap(ProcessInfo.processInfo.environment["UNWIRED_BUNDLE_ID"])
    let app = XCUIApplication(bundleIdentifier: identifier)
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    app.launch()
    XCTAssertTrue(app.staticTexts["Inbox"].waitForExistence(timeout: 20))
    let maya = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Maya Chen")).firstMatch
    XCTAssertTrue(maya.waitForExistence(timeout: 10))
    XCTAssertTrue(maya.label.hasPrefix("Unread."))
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
    if !oliver.exists || !oliver.isHittable {
      let back = app.navigationBars.buttons.firstMatch
      XCTAssertTrue(back.exists)
      back.tap()
    }
    XCTAssertTrue(oliver.isHittable)
    XCTAssertTrue(oliver.label.hasPrefix("Unread."))
    oliver.tap()
    XCTAssertTrue(app.staticTexts["oliver@example.com"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["maya@example.com"].exists)
    app.buttons["Mark as read"].tap()
    XCTAssertTrue(app.buttons["Mark as unread"].waitForExistence(timeout: 10))
    let committed = XCTAttachment(screenshot: app.screenshot())
    committed.name = "Committed read state"
    committed.lifetime = .keepAlways
    add(committed)
    app.terminate()
    app.launch()
    let restored = app.buttons["Oliver Park. Saturday, by the river?"]
    XCTAssertTrue(restored.waitForExistence(timeout: 20))
    XCTAssertFalse(restored.label.hasPrefix("Unread."))
    restored.tap()
    XCTAssertTrue(app.buttons["Mark as unread"].waitForExistence(timeout: 10))
    let recovered = XCTAttachment(screenshot: app.screenshot())
    recovered.name = "Read state after relaunch"
    recovered.lifetime = .keepAlways
    add(recovered)
  }
}
