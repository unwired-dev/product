import Foundation
import XCTest

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
    let updatedThreadRow = assertIncrementalPresentation(in: app)
    try await waitForRefreshToFinish(refresh)
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
    try await Task.sleep(for: .seconds(1))
    guard !refresh.isEnabled else { return }
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"),
      object: refresh
    )
    await fulfillment(of: [enabled], timeout: 60)
  }
}
