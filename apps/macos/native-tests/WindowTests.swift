import XCTest

final class WindowTests: XCTestCase {
  struct Event: Decodable {
    let event: String
    let pid: Int
    let session: String
    let windows: Int
    let workTicks: Int
  }

  private func registrationJourney(_ app: XCUIApplication, first: XCUIElement, apple: Bool) {
    // Apple identifies the Product Account; Gmail access still needs its own Google grant.
    let signIn = apple ? "Sign in with Apple" : "Sign in with Google"
    XCTAssertTrue(first.buttons[signIn].waitForExistence(timeout: 20))
    first.buttons[signIn].click()
    XCTAssertTrue(first.buttons["Authorize Gmail"].waitForExistence(timeout: 15))
    XCTAssertFalse(first.staticTexts["Gmail connected"].exists)
    if apple {
      XCTAssertTrue(
        first.staticTexts.matching(
          NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "relay@privaterelay.example.invalid",
            "relay@privaterelay.example.invalid")
        ).firstMatch.exists)
    }
    // A new Product Account presents its Recovery Key until setup is confirmed.
    func recoveryKey(_ window: XCUIElement) -> String {
      let text = window.staticTexts["recovery-key"]
      return text.label.isEmpty ? text.value as? String ?? "" : text.label
    }
    XCTAssertTrue(first.staticTexts["recovery-key"].waitForExistence(timeout: 15))
    let presented = recoveryKey(first)
    XCTAssertEqual(presented.count, 64)
    app.terminate()
    app.launch()
    let resumed = app.windows["Inbox 1"]
    XCTAssertTrue(resumed.buttons["Authorize Gmail"].waitForExistence(timeout: 15))
    // Relaunch keeps the device-held keys; nothing is regenerated.
    XCTAssertEqual(recoveryKey(resumed), presented)
    resumed.buttons[apple ? "Authorize Gmail" : "Choose another Google mailbox"].click()
    XCTAssertTrue(resumed.staticTexts["Gmail connected"].waitForExistence(timeout: 15))
    let entry = resumed.textFields["Last four characters"]
    entry.click()
    entry.typeText(String(presented.suffix(4)))
    resumed.buttons["Confirm Recovery Key"].click()
    XCTAssertTrue(resumed.staticTexts["Private sync is on"].waitForExistence(timeout: 15))
    XCTAssertFalse(resumed.staticTexts["recovery-key"].exists)
    app.terminate()
    app.launch()
    let relaunched = app.windows["Inbox 1"]
    XCTAssertTrue(relaunched.staticTexts["Gmail connected"].waitForExistence(timeout: 15))
    XCTAssertTrue(relaunched.staticTexts["Private sync is on"].exists)
    XCTAssertFalse(relaunched.staticTexts["recovery-key"].exists)
  }

  // Linking verifies both identities; the Gmail grant never becomes a sign-in method.
  private func linkJourney(_ app: XCUIApplication, first: XCUIElement) {
    func text(_ value: String, in window: XCUIElement) -> XCUIElement {
      window.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)
      ).firstMatch
    }
    XCTAssertTrue(first.buttons["Sign in with Apple"].waitForExistence(timeout: 20))
    first.buttons["Sign in with Apple"].click()
    XCTAssertTrue(text("Gmail connected", in: first).waitForExistence(timeout: 15))
    XCTAssertTrue(text("Only Apple opens this Product Account", in: first).exists)
    first.buttons["Link Google sign-in"].click()
    let linked = "Sign in with Apple or Google to open this Product Account."
    XCTAssertTrue(text(linked, in: first).waitForExistence(timeout: 15))
    XCTAssertFalse(first.buttons["Link Google sign-in"].exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(text(linked, in: app.windows["Inbox 1"]).waitForExistence(timeout: 15))
  }

  // Keep the existing window lifecycle journey in one session for its PID and work assertions.
  // swiftlint:disable:next function_body_length
  func testIndependentWindowsCloseReopenAndQuit() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    let appURL = URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"]))
    let evidence = FileManager.default.temporaryDirectory
      .appendingPathComponent("unwired-lifecycle-\(UUID().uuidString).jsonl")
    try Data().write(to: evidence)
    addTeardownBlock { [self] in
      if let data = try? Data(contentsOf: evidence) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Lifecycle events"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      try? FileManager.default.removeItem(at: evidence)
    }
    let app = XCUIApplication(url: appURL)
    app.launchEnvironment["UNWIRED_LIFECYCLE_PATH"] = evidence.path
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }

    func address(_ window: XCUIElement, _ value: String) -> XCUIElement {
      window.textViews.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }
    let first = app.windows["Inbox 1"]
    XCTAssertTrue(first.waitForExistence(timeout: 30))
    if environment["UNWIRED_TEST_SCENARIO"] == "registration-link" {
      linkJourney(app, first: first)
      return
    }
    if environment["UNWIRED_TEST_SCENARIO"]?.hasPrefix("registration-") == true {
      registrationJourney(
        app, first: first, apple: environment["UNWIRED_TEST_SCENARIO"] == "registration-apple")
      return
    }
    let maya = first.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Maya Chen")).firstMatch
    XCTAssertTrue(maya.waitForExistence(timeout: 20))
    maya.click()
    XCTAssertTrue(address(first, "maya@example.com").waitForExistence(timeout: 10))
    app.typeKey("n", modifierFlags: .command)
    let second = app.windows["Inbox 2"]
    XCTAssertTrue(second.waitForExistence(timeout: 10))
    let oliver = second.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Oliver Park")).firstMatch
    XCTAssertTrue(oliver.waitForExistence(timeout: 10))
    oliver.click()
    XCTAssertTrue(address(second, "oliver@example.com").waitForExistence(timeout: 10))
    XCTAssertTrue(address(first, "maya@example.com").exists)
    XCTAssertTrue(oliver.label.hasPrefix("Unread."))
    XCTAssertTrue(second.buttons["Mark as read"].waitForExistence(timeout: 10))
    second.buttons["Mark as read"].click()
    XCTAssertTrue(second.buttons["Mark as unread"].waitForExistence(timeout: 10))
    XCTAssertTrue(first.buttons["Oliver Park. Saturday, by the river?"].waitForExistence(timeout: 10))
    XCTAssertFalse(address(second, "maya@example.com").exists)

    app.menuBars.menuBarItems["Window"].click()
    app.menuItems["Inbox 1"].click()
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(first.waitForNonExistence(timeout: 10))
    XCTAssertTrue(address(second, "oliver@example.com").exists)
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(second.waitForNonExistence(timeout: 10))
    XCTAssertNotEqual(app.state, .notRunning)

    func events() throws -> [Event] {
      try String(contentsOf: evidence, encoding: .utf8).split(separator: "\n").compactMap {
        try? JSONDecoder().decode(Event.self, from: Data($0.utf8))
      }
    }
    let lastClose = try XCTUnwrap(events().last { $0.event == "window-close" })
    let workContinues = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard let records = try? events() else { return false }
      return records.contains { $0.event == "work" && $0.windows == 0 && $0.workTicks > lastClose.workTicks }
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [workContinues], timeout: 10), .completed)

    // Activating an already running app follows the Dock/Finder reopen path.
    let opener = Process()
    opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    opener.arguments = [appURL.path]
    try opener.run()
    opener.waitUntilExit()
    XCTAssertEqual(opener.terminationStatus, 0)
    let reopened = app.windows["Inbox 3"]
    XCTAssertTrue(reopened.waitForExistence(timeout: 10))
    XCTAssertTrue(reopened.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Select a message to start reading.")).firstMatch.waitForExistence(timeout: 10))
    reopened.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Oliver Park")).firstMatch.click()
    XCTAssertTrue(address(reopened, "oliver@example.com").waitForExistence(timeout: 10))
    app.menuBars.menuBarItems["Unwired Mail Preview"].click()
    app.menuItems["Quit Unwired Mail"].click()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    let records = try events()
    let quit = try XCTUnwrap(records.lastIndex { $0.event == "quit" })
    XCTAssertFalse(records.suffix(from: quit).contains { $0.event == "work" })
    XCTAssertEqual(Set(records.map(\.pid)).count, 1)
    XCTAssertEqual(Set(records.map(\.session)).count, 1)
    XCTAssertEqual(records.filter { $0.event == "launch" }.count, 1)
    app.launch()
    let restored = app.windows["Inbox 1"].buttons["Oliver Park. Saturday, by the river?"]
    XCTAssertTrue(restored.waitForExistence(timeout: 30))
    XCTAssertFalse(restored.label.hasPrefix("Unread."))
    restored.click()
    XCTAssertTrue(app.windows["Inbox 1"].buttons["Mark as unread"].waitForExistence(timeout: 10))

  }
}
