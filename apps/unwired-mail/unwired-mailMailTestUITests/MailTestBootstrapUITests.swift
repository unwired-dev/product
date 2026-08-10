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

final class MailTestBootstrapUITests: XCTestCase {
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
