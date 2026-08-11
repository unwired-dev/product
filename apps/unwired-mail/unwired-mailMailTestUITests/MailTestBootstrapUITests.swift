import Foundation
import XCTest

// swiftlint:disable file_length

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
  private let composeSubject = "Mail Test Compose Send"
  private let markReadSubject = "Mail Test Mark Read"
  private let moveSubject = "Mail Test Move"
  private let openSubject = "Mail Test Open"
  private let replySubject = "Re: Mail Test Reply Source"
  private let replySourceSubject = "Mail Test Reply Source"
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

  func testComposeAndSendThroughVisibleClient() throws {
    let app = launchApplication()
    let compose = try requireComposeAction(in: app)
    compose.tap()

    let recipient = try requireElement(
      identifier: "mail-compose-recipient",
      in: app,
      failure: "MAIL_TEST_FAILURE:ui: The recipient field was not visible."
    )
    recipient.tap()
    recipient.typeText("recipient@synthetic.invalid")
    let subject = try requireElement(
      identifier: "mail-compose-subject",
      in: app,
      failure: "MAIL_TEST_FAILURE:ui: The subject field was not visible."
    )
    subject.tap()
    subject.typeText(composeSubject)
    let body = try requireElement(
      identifier: "mail-compose-body",
      in: app,
      failure: "MAIL_TEST_FAILURE:ui: The message body was not visible."
    )
    body.tap()
    body.typeText("Synthetic compose delivery")

    try sendVisibleDraft(step: "compose-send", in: app)
  }

  func testReplyThroughVisibleClient() throws {
    let app = launchApplication()
    let inbox = element(identifier: "mail-mailbox-inbox", in: app)
    if !inbox.exists {
      let sidebar = app.navigationBars.buttons.firstMatch
      XCTAssertTrue(
        sidebar.waitForExistence(timeout: 5),
        "MAIL_TEST_FAILURE:ui: The mailbox sidebar could not be opened."
      )
      sidebar.tap()
    }
    XCTAssertTrue(
      inbox.waitForExistence(timeout: 5),
      "MAIL_TEST_FAILURE:ui: Inbox was not available for the reply source."
    )
    inbox.tap()
    let source = try requireThread(replySourceSubject, in: app)
    source.tap()
    XCTAssertTrue(
      element(identifier: "mail-conversation-reader", in: app).waitForExistence(timeout: 15),
      "MAIL_TEST_FAILURE:ui: The seeded reply source did not open."
    )

    let reply = element(identifier: "mail-reply", in: app)
    guard reply.waitForExistence(timeout: 3) else {
      throw XCTSkip("MAIL_TEST_CAPABILITY_UNAVAILABLE:reply")
    }
    reply.tap()
    let body = try requireElement(
      identifier: "mail-compose-body",
      in: app,
      failure: "MAIL_TEST_FAILURE:ui: The reply composer did not open."
    )
    body.tap()
    body.typeText("Synthetic visible reply")

    try sendVisibleDraft(step: "reply", in: app)
    try verifyReplyConversation(in: app)
  }

  private func launchApplication() -> XCUIApplication {
    let app = XCUIApplication()
    app.launch()
    return app
  }

  private func requireComposeAction(in app: XCUIApplication) throws -> XCUIElement {
    let compose = button(identifier: "mail-compose", label: "New Message", in: app)
    if !compose.exists {
      let sidebar = app.navigationBars.buttons.firstMatch
      XCTAssertTrue(
        sidebar.waitForExistence(timeout: 5),
        "MAIL_TEST_FAILURE:ui: The mailbox sidebar could not be opened."
      )
      sidebar.tap()
    }
    return try XCTUnwrap(
      compose.waitForExistence(timeout: 5) ? compose : nil,
      "MAIL_TEST_FAILURE:ui: New Message was not available."
    )
  }

  private func sendVisibleDraft(
    step: String,
    in app: XCUIApplication
  ) throws {
    let send = button(identifier: "mail-compose-send", label: "Send", in: app)
    guard send.waitForExistence(timeout: 15) else {
      XCTFail("MAIL_TEST_FAILURE:ui: The Send action was not visible.")
      return
    }
    let enabledDeadline = Date().addingTimeInterval(5)
    while !send.isEnabled, Date() < enabledDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    guard send.isEnabled else {
      throw XCTSkip("MAIL_TEST_CAPABILITY_UNAVAILABLE:\(step)")
    }
    send.tap()
    XCTAssertTrue(
      send.waitForNonExistence(timeout: 10),
      "MAIL_TEST_FAILURE:outbox: The visible composer did not admit the message to Outbox."
    )
  }

  private func verifyReplyConversation(in app: XCUIApplication) throws {
    let back = app.navigationBars.buttons.firstMatch
    XCTAssertTrue(
      back.waitForExistence(timeout: 5),
      "MAIL_TEST_FAILURE:threading: The reply conversation could not be closed."
    )
    back.tap()
    let refresh = app.buttons["unified-inbox-refresh"]
    XCTAssertTrue(
      refresh.waitForExistence(timeout: 5),
      "MAIL_TEST_FAILURE:threading: Unified Inbox could not be refreshed."
    )
    refresh.tap()
    let conversation = try requireThread(replySubject, in: app)
    conversation.tap()
    XCTAssertTrue(
      element(identifier: "mail-conversation-reader", in: app).waitForExistence(timeout: 15),
      "MAIL_TEST_FAILURE:threading: The replied-to conversation did not open."
    )
    XCTAssertEqual(
      app.descendants(matching: .any)
        .matching(identifier: "mail-conversation-message").count,
      2,
      "MAIL_TEST_FAILURE:threading: The client did not place the source and Sent copy in one conversation."
    )
  }

  private func requireThread(
    _ subject: String,
    in app: XCUIApplication
  ) throws -> XCUIElement {
    let row = app.buttons.matching(identifier: "mail-thread-row")
      .matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
    let deadline = Date().addingTimeInterval(60)
    while !row.waitForExistence(timeout: 2), Date() < deadline {
      app.swipeUp()
    }
    return try XCTUnwrap(
      row.exists ? row : nil,
      "MAIL_TEST_FAILURE:ui: The production mail path did not present \(subject)."
    )
  }

  private func requireElement(
    identifier: String,
    in app: XCUIApplication,
    failure: String
  ) throws -> XCUIElement {
    let candidate = element(identifier: identifier, in: app)
    return try XCTUnwrap(
      candidate.waitForExistence(timeout: 15) ? candidate : nil,
      failure
    )
  }

  private func element(
    identifier: String,
    in app: XCUIApplication
  ) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func button(
    identifier: String,
    label: String,
    in app: XCUIApplication
  ) -> XCUIElement {
    app.buttons.matching(
      NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)
    ).firstMatch
  }

  @MainActor
  func testIncrementalArrivalRefreshesExistingMailbox() async throws {
    let app = XCUIApplication()
    app.launch()
    assertInitialIncrementalState(in: app)
    try await requestIncrementalInjection()
    let refresh = app.buttons["unified-inbox-refresh"]
    XCTAssertTrue(
      refresh.waitForExistence(timeout: 10),
      "Synchronization phase could not find the production refresh control."
    )
    refresh.tap()
    try await waitForRefreshToFinish(refresh)
    let updatedThreadRow = assertIncrementalPresentation(in: app)
    refresh.tap()
    try await waitForRefreshToFinish(refresh)
    assertNoIncrementalDuplicates(in: app, updatedThreadRow: updatedThreadRow)
  }

  private func assertInitialIncrementalState(in app: XCUIApplication) {
    let initialRow = app.buttons.containing(
      .staticText,
      identifier: "Incremental conversation"
    ).firstMatch
    XCTAssertTrue(
      initialRow.waitForExistence(timeout: 60),
      "Initial-synchronization phase did not present the initial conversation."
    )
    XCTAssertFalse(
      initialRow.staticTexts["2"].exists,
      "Initial-synchronization phase presented a duplicate conversation message."
    )
  }

  private func requestIncrementalInjection() async throws {
    let coordinationValue = try XCTUnwrap(
      ProcessInfo.processInfo.environment["MAIL_TEST_COORDINATION_URL"],
      "Injection phase requires the external harness coordination endpoint."
    )
    let coordinationURL = try XCTUnwrap(URL(string: coordinationValue))
    XCTAssertEqual(coordinationURL.scheme, "http")
    XCTAssertEqual(coordinationURL.host, "127.0.0.1")
    var request = URLRequest(url: coordinationURL)
    request.httpMethod = "POST"
    let (_, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual(
      (response as? HTTPURLResponse)?.statusCode,
      204,
      "Injection or provider-observation phase failed before client refresh."
    )
  }

  private func assertIncrementalPresentation(in app: XCUIApplication) -> XCUIElement {
    let newMessageRow = app.buttons.containing(
      .staticText,
      identifier: "New after initial synchronization"
    ).firstMatch
    XCTAssertTrue(
      newMessageRow.waitForExistence(timeout: 60),
      "Reconciliation phase did not present newly arrived mail."
    )
    let updatedThreadRow = app.buttons
      .containing(.staticText, identifier: "Re: Incremental conversation")
      .containing(.staticText, identifier: "2")
      .firstMatch
    XCTAssertTrue(
      updatedThreadRow.waitForExistence(timeout: 60),
      "Visible-presentation phase did not reconcile the reply into the existing conversation."
    )
    return updatedThreadRow
  }

  private func assertNoIncrementalDuplicates(
    in app: XCUIApplication,
    updatedThreadRow: XCUIElement
  ) {
    XCTAssertEqual(
      app.buttons.containing(
        .staticText,
        identifier: "New after initial synchronization"
      ).count,
      1,
      "Repeated-refresh phase duplicated the newly arrived message."
    )
    XCTAssertFalse(
      updatedThreadRow.staticTexts["3"].exists,
      "Repeated-refresh phase duplicated the existing conversation reply."
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
    assertReturnedFromReader(step: "archive", in: app)
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
    assertReturnedFromReader(step: "move", in: app)
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
    assertReturnedFromReader(step: "trash", in: app)
  }

  private func requireRow(
    _ subject: String,
    in app: XCUIApplication
  ) throws -> XCUIElement {
    let row = app.buttons.matching(identifier: "mail-thread-row")
      .matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
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

  private func assertReturnedFromReader(
    step: String,
    in app: XCUIApplication
  ) {
    let reader = app.scrollViews["mail-conversation-reader"]
    if reader.exists {
      app.navigationBars.buttons.firstMatch.tap()
    }
    XCTAssertTrue(
      reader.waitForNonExistence(timeout: 15),
      "Step \(step) did not return from the visible conversation reader."
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
    let hasInlineContent = fixtureHasExpectedInlineContent(fixture, in: app)
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
        XCTFail(
          "[fixture: remote-content] Remote content became user-loadable after text extraction.")
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

  private func fixtureHasExpectedInlineContent(
    _ fixture: MessageContentExpectations.Fixture,
    in app: XCUIApplication
  ) -> Bool {
    let inlineContent = app.descendants(matching: .any)["message-inline-content"]
    return fixture.expectedInlineContent
      ? inlineContent.waitForExistence(timeout: 5)
      : inlineContent.exists
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

  @MainActor
  private func waitForRefreshToFinish(_ refresh: XCUIElement) async throws {
    let disabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == false"),
      object: refresh
    )
    await fulfillment(of: [disabled], timeout: 60)
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"),
      object: refresh
    )
    await fulfillment(of: [enabled], timeout: 60)
  }

}
