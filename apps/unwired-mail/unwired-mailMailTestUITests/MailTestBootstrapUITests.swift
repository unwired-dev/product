import XCTest

private struct MessageContentExpectations: Decodable {
  struct Fixture: Decodable {
    let expectedAttachmentIndicator: Bool
    let expectedBody: String
    let expectedInlineContent: Bool
    let id: String
    let subject: String
  }

  let fixtures: [Fixture]
  let scenario: String
  let schemaVersion: Int
}

// swiftlint:disable:next type_body_length
final class MailTestBootstrapUITests: XCTestCase {
  private let archiveSubject = "Mail Test Archive"
  private let markReadSubject = "Mail Test Mark Read"
  private let moveSubject = "Mail Test Move"
  private let openSubject = "Mail Test Open"
  private let trashSubject = "Mail Test Trash"

  func testCategorizedFixturesAppearInVisibleMailbox() {
    let app = XCUIApplication()
    app.launch()

    assertVisibleCategory("People", subject: "A quick personal note", in: app)
    assertVisibleCategory("Orders", subject: "Order receipt 4821", in: app)
    assertVisibleCategory(
      "Newsletters & Promotions",
      subject: "Summer discount offer",
      in: app
    )
    assertVisibleCategory("Invites", subject: "Invitation to the design review", in: app)
    assertVisibleCategory("Flights", subject: "Flight itinerary ready", in: app)

    let ambiguousRow = app.buttons.containing(
      .staticText,
      identifier: "Automated account update"
    ).firstMatch
    XCTAssertTrue(
      ambiguousRow.waitForExistence(timeout: 60),
      "The ambiguous synthetic fixture did not appear in the visible mailbox."
    )
    for category in ["People", "Orders", "Newsletters & Promotions", "Invites", "Flights"] {
      XCTAssertFalse(
        ambiguousRow.staticTexts[category].exists,
        "The deliberately ambiguous fixture was over-classified as \(category)."
      )
    }
  }

  func testSeededMessageAppearsInVisibleMailbox() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(
      app.staticTexts["Synthetic seed"].waitForExistence(timeout: 60),
      "The production IMAP path did not present the seeded synthetic message."
    )
  }

  func testMessageContentCorpusInVisibleMailbox() throws {
    let expectations = try messageContentExpectations()
    XCTAssertEqual(expectations.schemaVersion, 1)
    XCTAssertEqual(expectations.scenario, "message-content")

    let app = XCUIApplication()
    app.launch()

    for fixture in expectations.fixtures.reversed() {
      guard assertFixture(fixture, in: app) else {
        return
      }
    }
  }

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

  private func assertFixture(
    _ fixture: MessageContentExpectations.Fixture,
    in app: XCUIApplication
  ) -> Bool {
    let subject = findStaticText(fixture.subject, in: app)
    guard subject.exists else {
      XCTFail("[fixture: \(fixture.id)] The fixture subject did not appear in the visible mailbox.")
      return false
    }
    let attachmentState = app.descendants(matching: .any)[
      "mailbox-thread-\(fixture.subject)-with-attachments"
    ]
    let hasAttachmentState =
      fixture.expectedAttachmentIndicator
      ? attachmentState.waitForExistence(timeout: 5)
      : attachmentState.exists
    guard hasAttachmentState == fixture.expectedAttachmentIndicator else {
      XCTFail("[fixture: \(fixture.id)] The visible mailbox attachment state was incorrect.")
      return false
    }

    subject.tap()
    let body = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", fixture.expectedBody)
    ).firstMatch
    guard body.waitForExistence(timeout: 30) else {
      XCTFail("[fixture: \(fixture.id)] The meaningful fixture body was not presented.")
      return false
    }
    let inlineContent = app.descendants(matching: .any)["message-inline-content"]
    let hasInlineContent =
      fixture.expectedInlineContent
      ? inlineContent.waitForExistence(timeout: 5)
      : inlineContent.exists
    guard hasInlineContent == fixture.expectedInlineContent else {
      XCTFail("[fixture: \(fixture.id)] The inline-content presentation state was incorrect.")
      return false
    }
    if fixture.id == "remote-content" {
      if app.otherElements["remote-message-content-notice"].exists {
        XCTFail("[fixture: remote-content] The text-only path exposed a remote-load control.")
        return false
      }
      if app.buttons["load-remote-message-content"].exists {
        XCTFail("[fixture: remote-content] Remote content became user-loadable after text extraction.")
        return false
      }
    }

    let backButton = app.navigationBars.buttons.firstMatch
    guard backButton.waitForExistence(timeout: 5) else {
      XCTFail("[fixture: \(fixture.id)] The mailbox back action was unavailable.")
      return false
    }
    backButton.tap()
    return true
  }

  private func messageContentExpectations() throws -> MessageContentExpectations {
    let environment = ProcessInfo.processInfo.environment
    let encoded = try XCTUnwrap(
      environment["MAIL_TEST_SCENARIO_FIXTURES"],
      "The harness did not configure message-content expectations."
    )
    let data = try XCTUnwrap(
      Data(base64Encoded: encoded),
      "The harness provided invalid message-content expectations."
    )
    return try JSONDecoder().decode(MessageContentExpectations.self, from: data)
  }

  private func findStaticText(_ label: String, in app: XCUIApplication) -> XCUIElement {
    let element = app.staticTexts.matching(
      NSPredicate(format: "label == %@", label)
    ).firstMatch
    for _ in 0..<8 where !element.exists {
      app.swipeUp()
    }
    return element
  }

  private func assertVisibleCategory(
    _ category: String,
    subject: String,
    in app: XCUIApplication
  ) {
    let row = app.buttons
      .containing(.staticText, identifier: subject)
      .containing(.staticText, identifier: category)
      .firstMatch
    XCTAssertTrue(
      row.waitForExistence(timeout: 60),
      "The visible row for \(subject) did not expose the expected \(category) assignment."
    )
  }
}
