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
    let app = launchApplication()

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
    let app = launchApplication()

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
      identifier: "mail-compose-to",
      in: app,
      failure: "MAIL_TEST_FAILURE:ui: The recipient field was not visible."
    )
    try focusAndType(
      "recipient@synthetic.invalid",
      into: recipient,
      failure: "MAIL_TEST_FAILURE:ui: The recipient field did not receive keyboard focus."
    )
    let subject = try requireElement(
      identifier: "mail-compose-subject",
      in: app,
      failure: "MAIL_TEST_FAILURE:ui: The subject field was not visible."
    )
    try focusAndType(
      composeSubject,
      into: subject,
      failure: "MAIL_TEST_FAILURE:ui: The subject field did not receive keyboard focus."
    )
    let body = try requireElement(
      identifier: "mail-compose-body",
      in: app,
      failure: "MAIL_TEST_FAILURE:ui: The message body was not visible."
    )
    try focusAndType(
      "Synthetic compose delivery",
      into: body,
      failure: "MAIL_TEST_FAILURE:ui: The message body did not receive keyboard focus."
    )

    try sendVisibleDraft(step: "compose-send", in: app)
    waitForOutboxToDrain(in: app)
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
    try focusAndType(
      "Synthetic visible reply",
      into: body,
      failure: "MAIL_TEST_FAILURE:ui: The reply body did not receive keyboard focus."
    )

    try sendVisibleDraft(step: "reply", in: app)
    try verifyReplyConversation(in: app)
  }

  private func launchApplication() -> XCUIApplication {
    let app = XCUIApplication()
    app.launch()
    return app
  }

  private func focusAndType(
    _ text: String,
    into element: XCUIElement,
    failure: String
  ) throws {
    let hittable = NSPredicate(format: "hittable == true")
    let hittableExpectation = XCTNSPredicateExpectation(predicate: hittable, object: element)
    guard XCTWaiter.wait(for: [hittableExpectation], timeout: 5) == .completed else {
      XCTFail(failure)
      throw NSError(domain: "MailTestBootstrapUITests", code: 1)
    }

    let focused = NSPredicate(format: "hasKeyboardFocus == true")
    for _ in 0..<3 {
      element.tap()
      let focusExpectation = XCTNSPredicateExpectation(predicate: focused, object: element)
      if XCTWaiter.wait(for: [focusExpectation], timeout: 2) == .completed {
        element.typeText(text)
        return
      }
    }

    XCTFail(failure)
    throw NSError(domain: "MailTestBootstrapUITests", code: 1)
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
      let inbox = element(identifier: "mail-mailbox-inbox", in: app)
      let availableInbox = try XCTUnwrap(
        inbox.waitForExistence(timeout: 5) ? inbox : nil,
        "MAIL_TEST_FAILURE:ui: Inbox was not available for composing."
      )
      availableInbox.tap()
      XCTAssertTrue(
        app.navigationBars["Unified Inbox"].waitForExistence(timeout: 15),
        "MAIL_TEST_FAILURE:ui: Unified Inbox did not become visible for composing."
      )
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

  private func waitForOutboxToDrain(in app: XCUIApplication) {
    let outbox = element(identifier: "mail-mailbox-outbox", in: app)
    if !outbox.exists {
      let sidebar = app.navigationBars.buttons.firstMatch
      if sidebar.waitForExistence(timeout: 5) {
        sidebar.tap()
      }
    }
    guard outbox.waitForExistence(timeout: 2) else { return }
    XCTAssertTrue(
      outbox.waitForNonExistence(timeout: 30),
      "MAIL_TEST_FAILURE:outbox: The admitted message did not leave Outbox."
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
    let rows = app.buttons.matching(identifier: "mail-thread-row")
    _ = try XCTUnwrap(
      rows.firstMatch.waitForExistence(timeout: 60) ? rows.firstMatch : nil,
      "MAIL_TEST_FAILURE:ui: The production mail path did not present any thread rows."
    )
    let row =
      rows
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
    let app = launchApplication()
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

    let app = launchApplication()

    for fixture in expectations.fixtures.reversed() {
      guard assertFixture(fixture, in: app) else {
        return
      }
    }
  }

  func testOpenMessageThroughVisibleClient() throws {
    let app = launchApplication()
    try openMessage(openSubject, step: "open", in: app)
  }

  func testMarkReadThroughVisibleClient() throws {
    let app = launchApplication()
    let row = try requireRow(markReadSubject, step: "mark-read", in: app)
    row.swipeRight()
    let markRead = app.buttons["mail-swipe-action-markRead"]
    guard markRead.waitForExistence(timeout: 3) else {
      throw XCTSkip("MAIL_TEST_CAPABILITY_UNAVAILABLE:mark-read")
    }
    markRead.tap()
    XCTAssertTrue(
      waitForValue("Read", on: row, timeout: 15),
      "MAIL_TEST_FAILURE:mark-read:read-state-not-presented: The row did not show Read."
    )
  }

  func testArchiveThroughVisibleClient() throws {
    let app = launchApplication()
    let row = try requireRow(archiveSubject, step: "archive", in: app)
    openMessage(row, step: "archive", in: app)
    let action = try requireProviderAction(
      "mail-action-archive",
      step: "archive",
      in: app
    )
    action.tap()
    assertReturnedFromReader(step: "archive", in: app)
    assertMessageLeftInbox(archiveSubject, step: "archive", in: app)
  }

  func testMoveThroughVisibleClient() throws {
    let app = launchApplication()
    let row = try requireRow(moveSubject, step: "move", in: app)
    openMessage(row, step: "move", in: app)
    let move = try requireProviderAction("mail-action-move", step: "move", in: app)
    move.tap()
    let destination = app.buttons.matching(
      identifier: "mail-action-move-destination"
    ).matching(NSPredicate(format: "label CONTAINS %@", "Move Target")).firstMatch
    XCTAssertTrue(
      destination.waitForExistence(timeout: 5),
      "MAIL_TEST_FAILURE:move:move-destination-not-presented: Move Target was not available."
    )
    destination.tap()
    assertReturnedFromReader(step: "move", in: app)
    assertMessageLeftInbox(moveSubject, step: "move", in: app)
  }

  func testTrashThroughVisibleClient() throws {
    let app = launchApplication()
    let row = try requireRow(trashSubject, step: "trash", in: app)
    openMessage(row, step: "trash", in: app)
    let action = try requireProviderAction(
      "mail-action-delete",
      step: "trash",
      in: app
    )
    action.tap()
    assertReturnedFromReader(step: "trash", in: app)
    assertMessageLeftInbox(trashSubject, step: "trash", in: app)
  }

  private func requireRow(
    _ subject: String,
    step: String,
    in app: XCUIApplication
  ) throws -> XCUIElement {
    let row = app.buttons.matching(identifier: "mail-thread-row")
      .matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
      if row.waitForExistence(timeout: 2), row.isHittable {
        return row
      }
      app.swipeUp()
    }
    return try XCTUnwrap(
      row.exists && row.isHittable ? row : nil,
      "MAIL_TEST_FAILURE:\(step):message-row-not-presented: The expected synthetic message row did not become interactive."
    )
  }

  private func openMessage(
    _ subject: String,
    step: String,
    in app: XCUIApplication
  ) throws {
    openMessage(try requireRow(subject, step: step, in: app), step: step, in: app)
  }

  private func openMessage(
    _ row: XCUIElement,
    step: String,
    in app: XCUIApplication
  ) {
    row.tap()
    XCTAssertTrue(
      app.scrollViews["mail-conversation-reader"].waitForExistence(timeout: 15),
      "MAIL_TEST_FAILURE:\(step):conversation-reader-not-presented: The conversation reader did not appear."
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
      "MAIL_TEST_FAILURE:\(step):conversation-reader-not-dismissed: The conversation reader remained visible."
    )
  }

  private func assertMessageLeftInbox(
    _ subject: String,
    step: String,
    in app: XCUIApplication
  ) {
    let inbox = element(identifier: "mail-mailbox-inbox", in: app)
    if !inbox.exists {
      let sidebar = app.navigationBars.buttons.firstMatch
      guard sidebar.waitForExistence(timeout: 5) else {
        XCTFail(
          "MAIL_TEST_FAILURE:\(step):mailbox-not-presented: The mailbox sidebar could not be opened."
        )
        return
      }
      sidebar.tap()
    }
    guard inbox.waitForExistence(timeout: 5) else {
      XCTFail(
        "MAIL_TEST_FAILURE:\(step):mailbox-not-presented: Inbox was not available."
      )
      return
    }
    inbox.tap()
    guard app.navigationBars["Unified Inbox"].waitForExistence(timeout: 15) else {
      XCTFail(
        "MAIL_TEST_FAILURE:\(step):mailbox-not-presented: Inbox did not become visible."
      )
      return
    }
    let rows = app.buttons.matching(identifier: "mail-thread-row")
    XCTAssertTrue(
      rows.firstMatch.waitForExistence(timeout: 15),
      "MAIL_TEST_FAILURE:\(step):mailbox-not-presented: Inbox rows did not appear."
    )
    let row =
      rows
      .matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
    XCTAssertTrue(
      row.waitForNonExistence(timeout: 15),
      "MAIL_TEST_FAILURE:\(step):inbox-row-still-present: The message remained visible in Inbox."
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
