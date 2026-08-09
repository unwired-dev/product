import XCTest

final class MailTestBootstrapUITests: XCTestCase {
  private let archiveSubject = "Mail Test Archive"
  private let markReadSubject = "Mail Test Mark Read"
  private let moveSubject = "Mail Test Move"
  private let openSubject = "Mail Test Open"
  private let trashSubject = "Mail Test Trash"

  func testOpenMessageThroughVisibleClient() throws {
    let app = launchApplication()
    try openMessage(openSubject, in: app)
  }

  func testMarkReadThroughVisibleClient() throws {
    let app = launchApplication()
    let row = try requireRow(markReadSubject, in: app)
    row.swipeRight()
    let markRead = app.buttons["mail-swipe-action-markRead"]
    guard markRead.waitForExistence(timeout: 3) else {
      throw XCTSkip("MAIL_TEST_CAPABILITY_UNAVAILABLE:mark-read")
    }
    markRead.tap()
    XCTAssertTrue(
      waitForValue("Read", on: row, timeout: 15),
      "Step mark-read did not produce the expected semantic row state."
    )
  }

  func testArchiveThroughVisibleClient() throws {
    let app = launchApplication()
    let row = try requireRow(archiveSubject, in: app)
    openMessage(row, in: app)
    let action = try requireProviderAction(
      "mail-action-archive",
      step: "archive",
      in: app
    )
    action.tap()
    assertRemovedFromVisibleMailbox(row, step: "archive", in: app)
  }

  func testMoveThroughVisibleClient() throws {
    let app = launchApplication()
    let row = try requireRow(moveSubject, in: app)
    openMessage(row, in: app)
    let move = try requireProviderAction("mail-action-move", step: "move", in: app)
    move.tap()
    let destination = app.buttons.matching(
      identifier: "mail-action-move-destination"
    ).matching(NSPredicate(format: "label CONTAINS %@", "Move Target")).firstMatch
    XCTAssertTrue(
      destination.waitForExistence(timeout: 5),
      "Step move did not expose the expected semantic destination."
    )
    destination.tap()
    assertRemovedFromVisibleMailbox(row, step: "move", in: app)
  }

  func testTrashThroughVisibleClient() throws {
    let app = launchApplication()
    let row = try requireRow(trashSubject, in: app)
    openMessage(row, in: app)
    let action = try requireProviderAction(
      "mail-action-delete",
      step: "trash",
      in: app
    )
    action.tap()
    assertRemovedFromVisibleMailbox(row, step: "trash", in: app)
  }

  private func launchApplication() -> XCUIApplication {
    let app = XCUIApplication()
    app.launch()
    return app
  }

  private func requireRow(
    _ subject: String,
    in app: XCUIApplication
  ) throws -> XCUIElement {
    let row = app.staticTexts.matching(identifier: "mail-thread-subject")
      .matching(NSPredicate(format: "label == %@", subject)).firstMatch
    if !row.waitForExistence(timeout: 10) {
      for _ in 0..<5 where !row.exists {
        app.swipeUp()
        _ = row.waitForExistence(timeout: 2)
      }
    }
    return try XCTUnwrap(
      row.exists ? row : nil,
      "The production IMAP path did not present the expected semantic message row."
    )
  }

  private func openMessage(_ subject: String, in app: XCUIApplication) throws {
    openMessage(try requireRow(subject, in: app), in: app)
  }

  private func openMessage(_ row: XCUIElement, in app: XCUIApplication) {
    row.tap()
    XCTAssertTrue(
      app.scrollViews["mail-conversation-reader"].waitForExistence(timeout: 15),
      "Step open did not present the semantic conversation reader."
    )
  }

  private func requireProviderAction(
    _ identifier: String,
    step: String,
    in app: XCUIApplication
  ) throws -> XCUIElement {
    let actions = app.buttons["mail-provider-actions"]
    guard actions.waitForExistence(timeout: 3) else {
      throw XCTSkip("MAIL_TEST_CAPABILITY_UNAVAILABLE:\(step)")
    }
    actions.tap()
    let action = app.buttons[identifier]
    guard action.waitForExistence(timeout: 3) else {
      throw XCTSkip("MAIL_TEST_CAPABILITY_UNAVAILABLE:\(step)")
    }
    return action
  }

  private func assertRemovedFromVisibleMailbox(
    _ row: XCUIElement,
    step: String,
    in app: XCUIApplication
  ) {
    let reader = app.scrollViews["mail-conversation-reader"]
    if reader.exists {
      app.navigationBars.buttons.firstMatch.tap()
    }
    XCTAssertTrue(
      row.waitForNonExistence(timeout: 15),
      "Step \(step) did not remove the row from the visible Inbox."
    )
  }

  private func waitForValue(
    _ expected: String,
    on element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if element.value as? String == expected { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return false
  }
}
