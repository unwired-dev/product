import XCTest

final class WindowTests: XCTestCase {
  struct Event: Decodable {
    let event: String
    let pid: Int
    let session: String
    let windows: Int
    let workTicks: Int
  }

  // Keep language changes, window menus, and relaunch in one native journey.
  // swiftlint:disable:next function_body_length
  func testLanguagePreferenceAcrossWindowsAndRelaunch() throws {
    continueAfterFailure = false
    let appURL = URL(
      fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["UNWIRED_APP_PATH"]))
    let app = XCUIApplication(url: appURL)
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let first = app.windows["Inbox 1"]
    let english = first.descendants(matching: .any)["language-en"]
    XCTAssertTrue(english.waitForExistence(timeout: 30))
    english.click()
    let checked = NSPredicate(
      format: "value CONTAINS 'checked' AND NOT value CONTAINS 'unchecked'")
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: checked, object: english)], timeout: 10),
      .completed)
    app.typeKey("n", modifierFlags: .command)
    let second = app.windows["Inbox 2"]
    let secondEnglish = second.descendants(matching: .any)["language-en"]
    XCTAssertTrue(secondEnglish.waitForExistence(timeout: 10))
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: checked, object: secondEnglish)], timeout: 10),
      .completed)
    for preference in ["language-system", "language-en", "language-system", "language-en"] {
      let selection = second.descendants(matching: .any)[preference]
      selection.click()
      XCTAssertEqual(
        XCTWaiter.wait(
          for: [XCTNSPredicateExpectation(predicate: checked, object: selection)], timeout: 10),
        .completed)
      assertWindowMenu(app, titles: ["Inbox 1", "Inbox 2"])
    }
    app.menuBars.menuBarItems["Window"].click()
    app.menuItems["Inbox 2"].click()
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(second.waitForNonExistence(timeout: 10))
    assertWindowMenu(app, titles: ["Inbox 1"])
    app.terminate()
    app.launch()
    XCTAssertTrue(english.waitForExistence(timeout: 30))
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: checked, object: english)], timeout: 10),
      .completed)
    let system = first.descendants(matching: .any)["language-system"]
    system.click()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: checked, object: system)], timeout: 10),
      .completed)
    app.menuBars.menuBarItems["File"].click()
    XCTAssertTrue(app.menuItems["New Window"].exists)
    app.typeKey(.escape, modifierFlags: [])
  }

  private func assertWindowMenu(
    _ app: XCUIApplication, titles: [String], file: StaticString = #filePath, line: UInt = #line
  ) {
    app.menuBars.menuBarItems["Window"].click()
    let entries = app.menuItems.matching(NSPredicate(format: "label BEGINSWITH %@", "Inbox "))
    XCTAssertEqual(entries.count, titles.count, file: file, line: line)
    for title in titles {
      XCTAssertEqual(entries.matching(identifier: title).count, 1, file: file, line: line)
    }
    app.typeKey(.escape, modifierFlags: [])
  }

  // Keep the existing single-process lifecycle journey together.
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
    let maya = first.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Maya Chen"))
      .firstMatch
    XCTAssertTrue(maya.waitForExistence(timeout: 20))
    maya.click()
    XCTAssertTrue(address(first, "maya@example.com").waitForExistence(timeout: 10))
    app.typeKey("n", modifierFlags: .command)
    let second = app.windows["Inbox 2"]
    XCTAssertTrue(second.waitForExistence(timeout: 10))
    let oliver = second.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Oliver Park"))
      .firstMatch
    XCTAssertTrue(oliver.waitForExistence(timeout: 10))
    oliver.click()
    XCTAssertTrue(address(second, "oliver@example.com").waitForExistence(timeout: 10))
    XCTAssertTrue(address(first, "maya@example.com").exists)
    // Start from either read state so repeated runs remain independent of prior fixture changes.
    let markUnread = second.buttons["Mark as unread"]
    if markUnread.exists { markUnread.click() }
    XCTAssertTrue(second.buttons["Mark as read"].waitForExistence(timeout: 10))
    second.buttons["Mark as read"].click()
    XCTAssertTrue(second.buttons["Mark as unread"].waitForExistence(timeout: 10))
    XCTAssertTrue(
      first.buttons["Oliver Park. Saturday, by the river?"].waitForExistence(timeout: 10))
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
    let workContinues = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        guard let records = try? events() else { return false }
        return records.contains {
          $0.event == "work" && $0.windows == 0 && $0.workTicks > lastClose.workTicks
        }
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
    XCTAssertTrue(
      reopened.descendants(matching: .any).matching(
        NSPredicate(format: "label == %@", "Select a message to start reading.")
      ).firstMatch.waitForExistence(timeout: 10))
    reopened.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Oliver Park")).firstMatch
      .click()
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
    restored.click()
    XCTAssertTrue(app.windows["Inbox 1"].buttons["Mark as unread"].waitForExistence(timeout: 10))
  }
}
