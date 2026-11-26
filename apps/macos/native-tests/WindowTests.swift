import AppKit
import XCTest

// Synthetic completion proxy: reject failed writes and unfinished saves/syncs at each action.
// Optimistic rows and the encrypted cache alone cannot prove that a provider accepted a change.
private func assertProviderActionsSettled(_ window: XCUIElement, provider: String = "Gmail") {
  let unconfirmed = window.descendants(matching: .any).matching(
    NSPredicate(
      format: "label MATCHES %@",
      "(?s).*(\(provider) could not|\(provider) has not confirmed|\(provider) needs your permission|"
        + "waits? for \(provider)|could not be saved|Organizing mail waits).*"))
  XCTAssertFalse(unconfirmed.firstMatch.waitForExistence(timeout: 5))
  let unfinished = window.descendants(matching: .any).matching(
    NSPredicate(
      format: "label CONTAINS %@ OR label CONTAINS %@",
      "Saving the change on this device", "Checking \(provider)"))
  XCTAssertTrue(unfinished.firstMatch.waitForNonExistence(timeout: 10))
  XCTAssertFalse(unconfirmed.firstMatch.exists)
}

final class WindowTests: XCTestCase {
  func testSearchMailReceivesClicksOverComposer() throws {
    continueAfterFailure = false
    let env = ProcessInfo.processInfo.environment
    let appURL = URL(fileURLWithPath: try XCTUnwrap(env["UNWIRED_APP_PATH"]))
    let app = XCUIApplication(url: appURL)
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en"]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    window.buttons["New Message"].click()
    XCTAssertTrue(window.textFields["Subject"].waitForExistence(timeout: 10))
    runCommand("Search Mail", in: app)
    let search = window.textFields["Search senders and subjects"]
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
    app.typeText("Outlook update 003")
    XCTAssertEqual(search.value as? String, "Outlook update 003")
    XCTAssertTrue(window.textFields["Subject"].exists)
  }

  // #2271: @ in an empty body opens Recipient Suggestions under it without a Contacts prompt;
  // Return adds the first to To with a greeting, and one Undo restores the @.
  func testBodyRecipientShortcut() throws {
    try bodyRecipientShortcut(appearance: "Light")
  }

  func testBodyRecipientShortcutDark() throws {
    try bodyRecipientShortcut(appearance: "Dark")
  }

  private func bodyRecipientShortcut(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    app.launchArguments += [
      "-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en",
      "-UnwiredAppearance", appearance.lowercased(),
    ]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    func attach(_ name: String) {
      let attachment = XCTAttachment(screenshot: window.screenshot())
      attachment.name = "\(name) (\(appearance))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    window.buttons["New Message"].click()
    // The body is the window's only text view; it reads its placeholder as a label while empty.
    let body = window.textViews.firstMatch
    XCTAssertTrue(body.waitForExistence(timeout: 15))
    XCTAssertTrue(window.buttons["Undo"].waitForExistence(timeout: 30))
    body.click()
    body.typeText("@")
    // The menu's rows are its accessible elements; the newest correspondent comes first.
    let menu = window.buttons["Jordan Lee, jordan@example.invalid"]
    XCTAssertTrue(menu.waitForExistence(timeout: 10))
    XCTAssertGreaterThan(menu.frame.minY, body.frame.minY)
    attach("Body Recipient Shortcut")
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(menu.waitForNonExistence(timeout: 10))
    waitUntil { (body.value as? String ?? "").hasPrefix("Hi") }
    let token = window.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "To: "))
    XCTAssertEqual(token.count, 1)
    attach("Body Recipient Shortcut greeting")
    // The typed caret follows the greeting's empty paragraph.
    app.typeText("Thanks")
    waitUntil { (body.value as? String ?? "").hasSuffix("\n\nThanks") }
    // Undo takes back the typing, then the greeting and the recipient together.
    app.typeKey("z", modifierFlags: .command)
    waitUntil { !(body.value as? String ?? "").hasSuffix("Thanks") }
    app.typeKey("z", modifierFlags: .command)
    waitUntil { body.value as? String == "@" }
    XCTAssertEqual(token.count, 0)
  }

  // #2597: Outdent and Indent follow the list buttons; Format › Increase Indent (Command-]) and
  // Decrease Indent (Command-[) and Tab and Shift-Tab nest the item three levels deep, Indent
  // switches off at the third, and each change is one Undo step.
  func testListIndent() throws {
    try listIndent(appearance: "Light")
  }

  func testListIndentDark() throws {
    try listIndent(appearance: "Dark")
  }

  private func listIndent(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    app.launchArguments += [
      "-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en",
      "-UnwiredAppearance", appearance.lowercased(),
    ]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    func attach(_ name: String) {
      let attachment = XCTAttachment(screenshot: window.screenshot())
      attachment.name = "\(name) (\(appearance))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    window.buttons["New Message"].click()
    let body = window.textViews.firstMatch
    XCTAssertTrue(body.waitForExistence(timeout: 15))
    XCTAssertTrue(window.buttons["Undo"].waitForExistence(timeout: 30))
    body.click()
    body.typeText("Plan")
    app.typeKey(.return, modifierFlags: [])
    app.typeText("Seats")
    app.typeKey("a", modifierFlags: .command)
    window.buttons["Bulleted List"].click()
    app.typeKey(.rightArrow, modifierFlags: [])
    let nesting = "\u{2003}\u{2002}"
    func shows(_ levels: Int) {
      waitUntil {
        body.value as? String == "• Plan\n\(String(repeating: nesting, count: levels))• Seats"
      }
    }
    shows(0)
    let outdent = window.buttons["Outdent"]
    let indent = window.buttons["Indent"]
    XCTAssertFalse(outdent.isEnabled)
    XCTAssertTrue(indent.isEnabled)
    let format = app.menuBars.menuBarItems["Format"]
    func menuItem(_ title: String) -> XCUIElement { format.menuItems[title] }
    app.typeKey("]", modifierFlags: .command)
    shows(1)
    XCTAssertTrue(outdent.isEnabled)
    attach("List Indent")
    format.click()
    menuItem("Increase Indent").click()
    shows(2)
    XCTAssertFalse(indent.isEnabled)
    format.click()
    XCTAssertFalse(menuItem("Increase Indent").isEnabled)
    XCTAssertTrue(menuItem("Decrease Indent").isEnabled)
    app.typeKey(.escape, modifierFlags: [])
    attach("List Indent third level")
    // One Undo takes back one level; Shift-Tab and Tab outdent and indent; Command-[ outdents.
    app.typeKey("z", modifierFlags: .command)
    shows(1)
    app.typeKey(.tab, modifierFlags: .shift)
    shows(0)
    app.typeKey(.tab, modifierFlags: [])
    shows(1)
    app.typeKey("[", modifierFlags: .command)
    shows(0)
  }

  // #2350: Send stays unavailable until the Draft has a complete recipient, and To says why.
  func testSendBlockedReason() throws {
    try sendBlockedReason(appearance: "Light")
  }

  func testSendBlockedReasonDark() throws {
    try sendBlockedReason(appearance: "Dark")
  }

  private func sendBlockedReason(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    app.launchArguments += [
      "-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en",
      "-UnwiredAppearance", appearance.lowercased(),
    ]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    func attach(_ name: String) {
      let attachment = XCTAttachment(screenshot: window.screenshot())
      attachment.name = "\(name) (\(appearance))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    window.buttons["New Message"].click()
    XCTAssertTrue(window.buttons["Undo"].waitForExistence(timeout: 30))
    let send = window.buttons["Send"].firstMatch
    XCTAssertTrue(text("Add a recipient to send.", in: window).waitForExistence(timeout: 10))
    XCTAssertFalse(send.isEnabled)
    attach("Send blocked without a recipient")
    let to = window.textFields["To"]
    typeRecipient(to, "not an address")
    window.textFields["Subject"].click()
    XCTAssertTrue(
      text("“not an address” is not a complete address. Correct it to send.", in: window)
        .waitForExistence(timeout: 10))
    XCTAssertFalse(send.isEnabled)
    attach("Send blocked by an incomplete address")
    to.click()
    window.typeKey("a", modifierFlags: .command)
    window.typeKey(.delete, modifierFlags: [])
    to.typeText("jordan@example.invalid")
    // The address's contact suggestion covers Subject; Return accepts it.
    window.typeKey(.return, modifierFlags: [])
    waitUntil { send.isEnabled }
    XCTAssertFalse(text("not a complete address", in: window).exists)
  }

  // #2594: Send's menu offers Send Now, which hands the message to the Outbox with no Undo Send
  // Window, so it never waits as "Sending soon".
  func testSendNow() throws {
    try sendNow(appearance: "Light")
  }

  func testSendNowDark() throws {
    try sendNow(appearance: "Dark")
  }

  private func sendNow(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    app.launchArguments += [
      "-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en",
      "-UnwiredAppearance", appearance.lowercased(),
    ]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    func attach(_ screenshot: XCUIScreenshot, _ name: String) {
      let attachment = XCTAttachment(screenshot: screenshot)
      attachment.name = "\(name) (\(appearance))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    window.buttons["New Message"].click()
    XCTAssertTrue(window.buttons["Undo"].waitForExistence(timeout: 30))
    let send = window.buttons["Send"].firstMatch
    typeRecipient(window.textFields["To"], "jordan@example.invalid")
    // The address's contact suggestion covers Subject; Return accepts it.
    window.typeKey(.return, modifierFlags: [])
    let subject = window.textFields["Subject"]
    subject.click()
    subject.typeText("Send Now check")
    waitUntil { send.isEnabled }
    send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    // AppKit names the item by its title and subtitle.
    let item = app.menuItems["Send Now, No Undo"]
    XCTAssertTrue(item.waitForExistence(timeout: 5))
    XCTAssertTrue(item.isEnabled)
    // The menu's own element has an empty frame, so the screen is captured.
    attach(XCUIScreen.main.screenshot(), "Send menu with Send Now")
    // Send keeps the sidebar's Outbox for its 10-second Undo Send Window; within 8 seconds of the
    // click, Send Now's composer closes and its delivered message leaves the Outbox.
    let deadline = Date().addingTimeInterval(8)
    item.click()
    XCTAssertTrue(subject.waitForNonExistence(timeout: deadline.timeIntervalSinceNow))
    XCTAssertTrue(
      window.buttons["Outbox"].waitForNonExistence(timeout: max(0, deadline.timeIntervalSinceNow)))
    attach(window.screenshot(), "After Send Now")
  }

  // #2406: a force quit mid-typing keeps the New Message's unsaved edits, which Restore recovers
  // after the relaunch; Discard removes them, so the next launch offers nothing.
  func testComposerRecoveryAfterForceQuit() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let appURL = URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"]))
    let app = XCUIApplication(url: appURL)
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en"]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    // The sandboxed copy may read and write only its run directory, beside Mock.app.
    let file = appURL.deletingLastPathComponent().appendingPathComponent("recovery-note.txt")
    try Data("Attached before the force quit".utf8).write(to: file)
    addTeardownBlock { try? FileManager.default.removeItem(at: file) }
    // Pasting the file attaches it; give the person their pasteboard back.
    let pasteboard = NSPasteboard.general
    let saved = (pasteboard.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) { copy.setData(data, forType: type) }
      }
      return copy
    }
    pasteboard.clearContents()
    pasteboard.writeObjects([file as NSURL])
    let written = pasteboard.changeCount
    addTeardownBlock {
      guard pasteboard.changeCount == written else { return }
      pasteboard.clearContents()
      pasteboard.writeObjects(saved)
    }

    window.buttons["New Message"].click()
    XCTAssertTrue(window.buttons["Undo"].waitForExistence(timeout: 30))
    typeRecipient(window.textFields["To"], "jordan@example.invalid")
    // The address matches a contact, whose suggestion covers Subject; Return accepts it as a token.
    let suggestion = window.buttons["Jordan Lee, jordan@example.invalid"]
    XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(suggestion.waitForNonExistence(timeout: 10))
    let recipient = window.buttons.matching(
      NSPredicate(
        format: "label BEGINSWITH %@ AND label CONTAINS %@", "To: ", "jordan@example.invalid"))
    waitUntil { recipient.count == 1 }
    let subject = window.textFields["Subject"]
    subject.click()
    subject.typeText("Recovered after a force quit")
    // The body is the window's only text view.
    let body = window.textViews.firstMatch
    body.click()
    body.typeText("Typed just before the app ended")
    body.typeKey("v", modifierFlags: .command)
    // An imported attachment shows its size; a failed one adds why.
    let attachment = window.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", "recovery-note.txt, 30 bytes")).firstMatch
    XCTAssertTrue(attachment.waitForExistence(timeout: 15))
    // The composer journals 2 s after the last edit; nothing on screen shows the write.
    Thread.sleep(forTimeInterval: 5)

    // Restore opens the composer on the recovered edits.
    let offer = window.sheets.firstMatch
    forceQuitAndRelaunch(app, at: appURL)
    XCTAssertTrue(offer.buttons["Restore"].waitForExistence(timeout: 45))
    assertRecoveryOffer(offer)
    let capture = XCTAttachment(screenshot: window.screenshot())
    capture.name = "Recover unsaved message"
    capture.lifetime = .keepAlways
    add(capture)
    offer.buttons["Restore"].click()
    XCTAssertTrue(offer.waitForNonExistence(timeout: 10))
    XCTAssertTrue(subject.waitForExistence(timeout: 30))
    XCTAssertEqual(subject.value as? String, "Recovered after a force quit")
    XCTAssertEqual(recipient.count, 1)
    XCTAssertEqual(body.value as? String, "Typed just before the app ended")
    XCTAssertTrue(attachment.waitForExistence(timeout: 15))
    // The row shows the size before its bytes are read again; a damaged or missing file then
    // adds why, so look again once that check has had time to finish.
    Thread.sleep(forTimeInterval: 5)
    XCTAssertTrue(attachment.exists)
    let restored = XCTAttachment(screenshot: window.screenshot())
    restored.name = "Restored composer"
    restored.lifetime = .keepAlways
    add(restored)

    // The restored composer leaves the record until a Save, Send or Discard; Discard removes it.
    forceQuitAndRelaunch(app, at: appURL)
    XCTAssertTrue(offer.buttons["Discard"].waitForExistence(timeout: 45))
    assertRecoveryOffer(offer)
    offer.buttons["Discard"].click()
    XCTAssertTrue(offer.waitForNonExistence(timeout: 10))
    XCTAssertFalse(subject.exists)
    // The record's removal follows the answer; nothing on screen shows it.
    Thread.sleep(forTimeInterval: 5)
    forceQuitAndRelaunch(app, at: appURL)
    let newMessage = window.buttons["New Message"]
    XCTAssertTrue(newMessage.waitForExistence(timeout: 45))
    waitUntil { newMessage.isEnabled }
    // The offer above came once the Drafts opened; give this launch as long.
    XCTAssertFalse(offer.waitForExistence(timeout: 45))
  }

  // Ends the app as a crash would, with SIGKILL, so no Close, Quit or save runs, then relaunches.
  private func forceQuitAndRelaunch(_ app: XCUIApplication, at url: URL) {
    let running = NSWorkspace.shared.runningApplications.filter {
      $0.bundleURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
    }
    XCTAssertEqual(running.count, 1)
    XCTAssertTrue(running.allSatisfy { $0.forceTerminate() })
    waitUntil { app.state == .notRunning }
    app.launch()
  }

  // The offer names no message details; NSAlert's texts match by value.
  private func assertRecoveryOffer(_ offer: XCUIElement) {
    for value in ["Recover unsaved message?", "Your unsaved changes were kept on this device."] {
      XCTAssertTrue(
        offer.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch.exists)
    }
    let titles = Set(offer.buttons.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty })
    XCTAssertEqual(titles, ["Restore", "Discard"])
  }

  // #2933: a force quit keeps the Draft editor page's unsaved edits, which Restore reopens in the
  // page after the relaunch; Discard removes them, so the next launch offers nothing.
  func testDraftEditorRecoveryAfterForceQuit() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-draft-editor")
    let appURL = URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"]))
    let app = XCUIApplication(url: appURL)
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en"]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    XCTAssertTrue(window.waitForExistence(timeout: 30))
    draftEditorSignIn(window)

    window.buttons["New Message"].click()
    let body = window.webViews.textViews["Message body"]
    XCTAssertTrue(body.waitForExistence(timeout: 15))
    // The toolbar appears once the page is ready and moves the page down; focus it after that.
    XCTAssertTrue(window.buttons["Undo"].waitForExistence(timeout: 30))
    let subject = window.textFields["Subject"]
    subject.click()
    subject.typeText("Recovered in the page")
    body.click()
    body.typeText("Typed just before the app ended")
    let typed = webText("Typed just before the app ended", in: window)
    XCTAssertTrue(typed.waitForExistence(timeout: 10))
    // The editor journals 2 s after the last edit; nothing on screen shows the write.
    Thread.sleep(forTimeInterval: 5)

    // Restore opens the page, not the current composer, on the recovered edits.
    let offer = window.sheets.firstMatch
    forceQuitAndRelaunch(app, at: appURL)
    XCTAssertTrue(offer.buttons["Restore"].waitForExistence(timeout: 45))
    assertRecoveryOffer(offer)
    offer.buttons["Restore"].click()
    XCTAssertTrue(offer.waitForNonExistence(timeout: 10))
    XCTAssertTrue(typed.waitForExistence(timeout: 30))
    XCTAssertEqual(subject.value as? String, "Recovered in the page")
    let restored = XCTAttachment(screenshot: window.screenshot())
    restored.name = "Restored Draft editor page"
    restored.lifetime = .keepAlways
    add(restored)

    // The restored editor leaves the record until a Save, Send or Discard; Discard removes it.
    forceQuitAndRelaunch(app, at: appURL)
    XCTAssertTrue(offer.buttons["Discard"].waitForExistence(timeout: 45))
    assertRecoveryOffer(offer)
    offer.buttons["Discard"].click()
    XCTAssertTrue(offer.waitForNonExistence(timeout: 10))
    XCTAssertFalse(body.exists)
    // The record's removal follows the answer; nothing on screen shows it.
    Thread.sleep(forTimeInterval: 5)
    forceQuitAndRelaunch(app, at: appURL)
    let newMessage = window.buttons["New Message"]
    XCTAssertTrue(newMessage.waitForExistence(timeout: 45))
    waitUntil { newMessage.isEnabled }
    // The offer above came once the Drafts opened; give this launch as long.
    XCTAssertFalse(offer.waitForExistence(timeout: 45))
  }

  // Moving the entry into the reader must keep the open query and command rows in the window.
  func testCommandPaletteWindowBounds() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    let appURL = URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"]))
    let app = XCUIApplication(url: appURL)
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en"]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    app.typeKey("k", modifierFlags: .command)
    let query = window.textFields["Type a command"]
    XCTAssertTrue(query.waitForExistence(timeout: 15))
    let command = window.buttons["Reply. Select a Thread"]
    XCTAssertTrue(command.waitForExistence(timeout: 10))
    func assertBounds() {
      for element in [query, command] {
        XCTAssertGreaterThanOrEqual(element.frame.minX, window.frame.minX)
        XCTAssertLessThanOrEqual(element.frame.maxX, window.frame.maxX)
      }
    }
    assertBounds()
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(query.waitForNonExistence(timeout: 10))
    window.buttons["Open Command Palette"].click()
    XCTAssertTrue(query.waitForExistence(timeout: 10))
    window.buttons["Search Mail"].click()
    XCTAssertTrue(query.waitForNonExistence(timeout: 10))
    XCTAssertTrue(window.textFields["Search senders and subjects"].exists)
  }

  struct Event: Decodable {
    let event: String
    let pid: Int
    let session: String
    let windows: Int
    let workTicks: Int
  }

  // React Native macOS exposes registration text as the label of its enclosing element.
  private func text(_ value: String, in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value))
      .firstMatch
  }

  // A composer's first recipient keystroke asks for Apple Contacts in a UserNotificationCenter
  // alert, which takes keyboard focus and outlives the app; each run's disposable identity asks
  // again (#2198). Decline only this app's prompt, so suggestions stay synthetic and another
  // app's permission stays untouched, then type the rest.
  private func typeRecipient(_ field: XCUIElement, _ text: String) {
    field.click()
    field.typeText(String(text.prefix(1)))
    let prompt = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter").dialogs
      .containing(
        NSPredicate(
          format: "(label CONTAINS %@ AND label CONTAINS[c] %@) OR (value CONTAINS %@ AND value CONTAINS[c] %@)",
          "Unwired Mail", "contacts", "Unwired Mail", "contacts")
      ).firstMatch
    if prompt.waitForExistence(timeout: 10) {
      prompt.buttons.matching(NSPredicate(format: "title BEGINSWITH %@", "Don")).firstMatch.click()
      XCTAssertTrue(prompt.waitForNonExistence(timeout: 10))
      field.click()
      // Focusing the field again selects what it holds; replace that with the whole text.
      field.typeKey("a", modifierFlags: .command)
      field.typeText(text)
      return
    }
    field.typeText(String(text.dropFirst()))
  }

  // Selectable keys are native text views holding the grouped characters as their value.
  // Enrollment codes display their groups separated by spaces so they wrap; Recovery Keys keep
  // hyphens.
  private func key(groups: Int, in window: XCUIElement) -> XCUIElement {
    window.textViews.matching(
      NSPredicate(format: "value MATCHES %@", "([0-9A-Z]{4}[- ]){\(groups - 1)}[0-9A-Z]{4}")
    ).firstMatch
  }

  private func recoveryKey(in window: XCUIElement) -> XCUIElement {
    key(groups: 13, in: window)
  }

  private func enrollmentCode(in window: XCUIElement) -> XCUIElement {
    key(groups: 14, in: window)
  }

  // This device created the keys; removing the account's iPad first proposes a replacement
  // Recovery Key, and only its confirmation removes the device and rotates the keys.
  private func revocationJourney(_ app: XCUIApplication, first: XCUIElement) {
    XCTAssertTrue(first.buttons["Continue"].waitForExistence(timeout: 20))
    first.buttons["Continue"].click()
    first.buttons["Sign in with Google"].click()
    XCTAssertTrue(recoveryKey(in: first).waitForExistence(timeout: 15))
    let presented = recoveryKey(in: first).value as? String ?? ""
    let initialEntry = first.textFields["Last four characters"]
    initialEntry.click()
    initialEntry.typeText(String(presented.suffix(4)))
    first.buttons["Confirm Recovery Key"].click()
    // Private sync is ready, so the only selectable key is the proposed replacement.
    func prepare() {
      XCTAssertTrue(first.buttons["Remove iPad"].waitForExistence(timeout: 15))
      first.buttons["Remove iPad"].click()
      XCTAssertTrue(first.alerts.firstMatch.waitForExistence(timeout: 15))
      XCTAssertTrue(text("cannot be erased remotely", in: first).exists)
      first.alerts.firstMatch.buttons["Remove iPad"].click()
      XCTAssertTrue(recoveryKey(in: first).waitForExistence(timeout: 15))
    }
    prepare()
    // Cancelling the prepared removal keeps the device.
    first.buttons["Cancel"].click()
    XCTAssertTrue(recoveryKey(in: first).waitForNonExistence(timeout: 15))
    prepare()
    let replaced = recoveryKey(in: first).value as? String ?? ""
    XCTAssertEqual(replaced.count, 64)
    XCTAssertNotEqual(replaced, presented)
    let entry = first.textFields["Last four characters of the new Recovery Key"]
    entry.click()
    entry.typeText(String(replaced.suffix(4)))
    first.buttons["Remove iPad"].click()
    XCTAssertTrue(text("The device was removed.", in: first).waitForExistence(timeout: 15))
    XCTAssertFalse(first.buttons["Remove iPad"].exists)
    XCTAssertFalse(recoveryKey(in: first).exists)
    XCTAssertTrue(text("Sync is on", in: first).exists)
    app.terminate()
    app.launch()
    let resumed = app.windows["Inbox 1"]
    XCTAssertTrue(text("Sync is on", in: resumed).waitForExistence(timeout: 15))
    XCTAssertFalse(resumed.buttons["Remove iPad"].exists)
  }

  // Another device removed this one: the relaunch purges the account and explains it.
  private func revokedJourney(_ app: XCUIApplication, first: XCUIElement) {
    XCTAssertTrue(first.buttons["Continue"].waitForExistence(timeout: 20))
    first.buttons["Continue"].click()
    first.buttons["Sign in with Google"].click()
    XCTAssertTrue(first.buttons["Gmail"].waitForExistence(timeout: 15))
    app.terminate()
    app.launch()
    let resumed = app.windows["Inbox 1"]
    XCTAssertTrue(text("This device was removed", in: resumed).waitForExistence(timeout: 20))
    XCTAssertTrue(text("cannot be erased remotely", in: resumed).exists)
    XCTAssertFalse(recoveryKey(in: resumed).exists)
    // A fresh sign-in mints a new device identifier, which waits for a trusted device or the
    // Recovery Key like any new device; it gets no mailbox access meanwhile.
    resumed.buttons["Sign in with Google"].click()
    XCTAssertTrue(text("Approve this device", in: resumed).waitForExistence(timeout: 15))
    XCTAssertTrue(enrollmentCode(in: resumed).exists)
    XCTAssertTrue(text("Use your Recovery Key", in: resumed).exists)
    XCTAssertTrue(resumed.buttons["Check for Approval"].exists)
    XCTAssertFalse(resumed.buttons["Gmail"].exists)
    XCTAssertFalse(text("This device cannot join", in: resumed).exists)
    // Signing out of the gate leaves nothing of the account on this device.
    resumed.buttons["Sign Out of This Device"].click()
    XCTAssertTrue(text("Your other devices", in: resumed).waitForExistence(timeout: 15))
    resumed.buttons["Sign Out of This Device"].click()
    XCTAssertTrue(text("Your mail,", in: resumed).waitForExistence(timeout: 15))
  }

  // Sign-out keeps nothing of the account on this device; deletion ends the account everywhere.
  private func removalJourney(_ app: XCUIApplication, first: XCUIElement) {
    XCTAssertTrue(first.buttons["Continue"].waitForExistence(timeout: 20))
    first.buttons["Continue"].click()
    // At the narrowest window the sign-in actions stay whole beside the brand panel.
    let google = first.buttons["Sign in with Google"]
    XCTAssertTrue(google.waitForExistence(timeout: 10))
    let corner = first.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
      .withOffset(CGVector(dx: -2, dy: -2))
    corner.click(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: -600, dy: 0)))
    XCTAssertEqual(first.frame.width, 760, accuracy: 1)
    XCTAssertLessThanOrEqual(google.frame.maxX, first.frame.maxX)
    google.click()
    XCTAssertTrue(recoveryKey(in: first).waitForExistence(timeout: 15))
    let key = recoveryKey(in: first).value as? String ?? ""
    let entry = first.textFields["Last four characters"]
    entry.click()
    entry.typeText(String(key.suffix(4)))
    first.buttons["Confirm Recovery Key"].click()
    XCTAssertTrue(text("Sync is on", in: first).waitForExistence(timeout: 15))
    first.buttons["Sign Out of This Device"].click()
    XCTAssertTrue(text("Your other devices", in: first).waitForExistence(timeout: 15))
    first.buttons["Sign Out of This Device"].click()
    XCTAssertTrue(text("Your mail,", in: first).waitForExistence(timeout: 15))
    app.terminate()
    app.launch()
    let resumed = app.windows["Inbox 1"]
    XCTAssertTrue(text("Your mail,", in: resumed).waitForExistence(timeout: 20))
    // The keys left with the sign-out, so the account must approve this device again.
    XCTAssertTrue(resumed.buttons["Continue"].waitForExistence(timeout: 20))
    resumed.buttons["Continue"].click()
    resumed.buttons["Sign in with Google"].click()
    XCTAssertTrue(text("Approve this device", in: resumed).waitForExistence(timeout: 15))
    XCTAssertFalse(recoveryKey(in: resumed).exists)
    resumed.buttons["Delete Unwired Account"].click()
    XCTAssertTrue(text("cannot be undone", in: resumed).waitForExistence(timeout: 15))
    resumed.buttons["Delete Permanently"].click()
    // The deletion's reply is lost (#1173). After relaunch, retrying it confirms the deletion and
    // leaves its confirmation for Welcome.
    XCTAssertTrue(
      text("Deletion could not be confirmed", in: resumed).waitForExistence(timeout: 15))
    app.terminate()
    app.launch()
    let pending = app.windows["Inbox 1"]
    XCTAssertTrue(text("Confirm account deletion", in: pending).waitForExistence(timeout: 20))
    pending.buttons["Delete Permanently"].click()
    XCTAssertTrue(text("Unwired account deleted", in: pending).waitForExistence(timeout: 15))
    // The deleted account cannot be reopened, and this device keeps nothing of it.
    pending.buttons["Sign in with Google"].click()
    XCTAssertTrue(text("Unwired account deleted", in: pending).waitForExistence(timeout: 15))
  }

  private func registrationJourney(_ app: XCUIApplication, first: XCUIElement, apple: Bool) {
    // Apple identifies the Product Account; Gmail access still needs its own Google grant.
    let signIn = apple ? "Sign in with Apple" : "Sign in with Google"
    XCTAssertTrue(first.buttons["Continue"].waitForExistence(timeout: 20))
    first.buttons["Continue"].click()
    XCTAssertTrue(first.buttons[signIn].waitForExistence(timeout: 20))
    first.buttons[signIn].click()
    XCTAssertTrue(first.buttons["Gmail"].waitForExistence(timeout: 15))
    // Sign-in connects no mailbox; Gmail and Microsoft mail are offered alike.
    XCTAssertTrue(first.buttons["Microsoft 365 and Outlook"].exists)
    XCTAssertFalse(text("connected on this device", in: first).exists)
    if apple {
      XCTAssertTrue(text("relay@privaterelay.example.invalid", in: first).exists)
    }
    // A new Product Account presents its Recovery Key until setup is confirmed.
    XCTAssertTrue(recoveryKey(in: first).waitForExistence(timeout: 15))
    let presented = recoveryKey(in: first).value as? String ?? ""
    XCTAssertEqual(presented.count, 64)
    app.terminate()
    app.launch()
    let resumed = app.windows["Inbox 1"]
    XCTAssertTrue(resumed.buttons["Gmail"].waitForExistence(timeout: 15))
    // Relaunch keeps the device-held keys; nothing is regenerated.
    XCTAssertEqual(recoveryKey(in: resumed).value as? String, presented)
    resumed.buttons[apple ? "Gmail" : "Choose Another Google Mailbox"].click()
    XCTAssertTrue(text("connected on this device", in: resumed).waitForExistence(timeout: 15))
    let entry = resumed.textFields["Last four characters"]
    entry.click()
    entry.typeText(String(presented.suffix(4)))
    resumed.buttons["Confirm Recovery Key"].click()
    // Confirmed setup opens the synchronized Gmail Inbox, listed over two Gmail pages. An Apple
    // account's account page stays open until Open Inbox.
    if apple {
      XCTAssertTrue(resumed.buttons["Open Inbox"].waitForExistence(timeout: 15))
      resumed.buttons["Open Inbox"].click()
    }
    let rowan = "Unread. Rowan Hale. Garden plans for spring"
    XCTAssertTrue(resumed.buttons[rowan].waitForExistence(timeout: 20))
    XCTAssertTrue(
      resumed.buttons["test@example.invalid. Welcome to your synthetic Inbox"].waitForExistence(
        timeout: 15))
    resumed.buttons[rowan].click()
    XCTAssertTrue(text("rowan@example.invalid", in: resumed).waitForExistence(timeout: 10))
    // Opening it read it.
    let opened = "Rowan Hale. Garden plans for spring"
    XCTAssertTrue(resumed.buttons[opened].waitForExistence(timeout: 15))
    // The opened body arrives from Gmail as text; its image is not loaded.
    XCTAssertTrue(
      text("Images in this message are not loaded.", in: resumed).waitForExistence(timeout: 15))
    // The sanitized HTML renders inside the isolated WebKit view.
    let seedOrder = webText("seed order", in: resumed)
    XCTAssertTrue(seedOrder.waitForExistence(timeout: 15))
    // #1191: a secondary click opens the context menus of the row, the reader's sender and a link.
    func opensMenu(_ item: String, from target: XCUIElement) {
      target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
      XCTAssertTrue(app.menuItems[item].waitForExistence(timeout: 5))
      app.typeKey(.escape, modifierFlags: [])
      XCTAssertTrue(app.menuItems[item].waitForNonExistence(timeout: 5))
    }
    opensMenu("Archive", from: resumed.buttons[opened])
    // The sender's label repeats on its inner text, so it is clicked by position.
    opensMenu(
      "Copy Address", from: resumed.staticTexts["Rowan Hale, rowan@example.invalid"].firstMatch)
    opensMenu(
      "Copy Link",
      from: resumed.links.matching(identifier: "message-link-control")
        .matching(NSPredicate(format: "label == %@", "garden plan")).firstMatch)
    // #1217: a letter the read-only page leaves unhandled must not abort the app.
    seedOrder.click()
    resumed.typeKey("j", modifierFlags: [])
    XCTAssertTrue(seedOrder.waitForExistence(timeout: 5))
    XCTAssertEqual(app.state, .runningForeground)
    // Organizing goes through the packaged native Gmail modify: a star from the Command Palette,
    // the only place that offers it (#2084), then an archive and Undo, chosen as Edit › Undo,
    // Command-Z (#2188).
    XCTAssertFalse(resumed.buttons["Star"].exists)
    let query = resumed.textFields["Type a command"]
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(query.waitForExistence(timeout: 15))
    resumed.buttons["Star"].click()
    XCTAssertTrue(query.waitForNonExistence(timeout: 10))
    assertProviderActionsSettled(resumed)
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(
      resumed.buttons.matching(NSPredicate(format: "label ==[c] %@", "Remove Star")).firstMatch
        .waitForExistence(timeout: 10))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(query.waitForNonExistence(timeout: 10))
    // The row carries no star marker.
    let starred = opened
    resumed.buttons["Archive"].click()
    XCTAssertTrue(resumed.buttons["Undo"].waitForExistence(timeout: 10))
    assertProviderActionsSettled(resumed)
    XCTAssertTrue(resumed.buttons["Undo"].exists)
    XCTAssertFalse(resumed.buttons[starred].exists)
    app.typeKey("z", modifierFlags: .command)
    XCTAssertTrue(resumed.buttons[starred].waitForExistence(timeout: 15))
    assertProviderActionsSettled(resumed)
    XCTAssertTrue(resumed.buttons[starred].exists)
    XCTAssertFalse(recoveryKey(in: resumed).exists)
    app.terminate()
    app.launch()
    // An Apple relaunch has no backend session to read the mailbox back from private sync, so the
    // account page opens first. Relaunch reopens the encrypted cache, then setup stays reachable
    // from the Inbox.
    let relaunched = app.windows["Inbox 1"]
    if apple {
      XCTAssertTrue(
        text("Your Gmail mailbox changes are still waiting", in: relaunched).waitForExistence(
          timeout: 20))
      waitUntil { relaunched.buttons["Open Inbox"].isEnabled }
      relaunched.buttons["Open Inbox"].click()
    }
    XCTAssertTrue(relaunched.buttons[starred].waitForExistence(timeout: 20))
    relaunched.buttons[starred].click()
    relaunched.buttons["Settings"].click()
    let settings = app.windows["settings-window"]
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    XCTAssertTrue(text("connected on this device", in: settings).waitForExistence(timeout: 15))
    XCTAssertTrue(text("Sync is on", in: settings).exists)
    XCTAssertFalse(recoveryKey(in: settings).exists)
    app.typeKey(",", modifierFlags: .command)
    XCTAssertEqual(app.windows.matching(identifier: "settings-window").count, 1)
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(settings.waitForNonExistence(timeout: 10))
    XCTAssertTrue(relaunched.buttons[starred].exists)
    XCTAssertTrue(text("rowan@example.invalid", in: relaunched).exists)
    if apple { composerMenuJourney(app, first: relaunched) }
  }

  // #1915: Lena Fischer's Gmail invitation is answered in the reader, in Dark and then in Light.
  // Dark captures the unanswered card, Accept and Decline; Light starts from Decline and accepts.
  private func invitationJourney(_ app: XCUIApplication, first: XCUIElement) {
    XCTAssertTrue(first.buttons["Continue"].waitForExistence(timeout: 20))
    first.buttons["Continue"].click()
    XCTAssertTrue(first.buttons["Sign in with Google"].waitForExistence(timeout: 20))
    first.buttons["Sign in with Google"].click()
    XCTAssertTrue(recoveryKey(in: first).waitForExistence(timeout: 15))
    let presented = recoveryKey(in: first).value as? String ?? ""
    first.buttons["Choose Another Google Mailbox"].click()
    XCTAssertTrue(text("connected on this device", in: first).waitForExistence(timeout: 15))
    let entry = first.textFields["Last four characters"]
    entry.click()
    entry.typeText(String(presented.suffix(4)))
    first.buttons["Confirm Recovery Key"].click()
    XCTAssertTrue(
      first.buttons["Unread. Rowan Hale. Garden plans for spring"].waitForExistence(timeout: 20))
    for appearance in ["Dark", "Light"] {
      app.terminate()
      app.launchArguments = [
        "-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en",
        "-UnwiredAppearance", appearance.lowercased(),
      ]
      app.launch()
      let window = app.windows["Inbox 1"]
      // Opens Lena Fischer's invitation with `subject`; the row starts with Unread. until read.
      func open(_ subject: String) {
        let row = window.buttons.matching(
          NSPredicate(format: "label CONTAINS %@", "Lena Fischer. " + subject)
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), subject)
        row.click()
      }
      open("Invitation: Q4 roadmap review")
      func capture(_ state: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Invitation \(state) \(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      func respond(_ button: String, _ status: String) {
        window.buttons[button].click()
        XCTAssertTrue(
          text("\(status). Gmail confirmed", in: window).waitForExistence(timeout: 20))
        XCTAssertTrue(window.buttons[status].exists)
        capture(status)
      }
      if appearance == "Dark" {
        XCTAssertTrue(window.buttons["Accept"].waitForExistence(timeout: 20))
        XCTAssertTrue(window.buttons["Maybe"].exists)
        XCTAssertTrue(window.buttons["Decline"].exists)
        capture("card")
        respond("Accept", "Accepted")
        respond("Decline", "Declined")
      } else {
        // The answer Gmail confirmed is kept across the relaunch.
        XCTAssertTrue(
          text("Declined. Gmail confirmed", in: window).waitForExistence(timeout: 20))
        capture("Declined")
        respond("Accept", "Accepted")
        // The revision below names the declined answer, as on iPhone and iPad.
        window.buttons["Decline"].click()
        XCTAssertTrue(
          text("Declined. Gmail confirmed", in: window).waitForExistence(timeout: 20))
      }
      // #1921: each other invitation states why it can't be answered, or which meetings of a
      // series a response answers.
      for (subject, status, answerable, name) in [
        ("Invitation: Hiring sync", "You can’t respond from here", false, "not your address"),
        ("Cancelled: Budget check-in", "This meeting was cancelled", false, "cancelled"),
        ("Invitation: Weekly design review", "applies to every meeting", true, "whole series"),
        (
          "Updated invitation: Weekly design review on 20 Nov", "applies only to", true,
          "one meeting"
        ),
        ("Updated series: Weekly design review", "can’t tell which meeting", false, "ambiguous"),
        ("Invitation: Daily launch check", "can’t read this invitation", false, "unreadable"),
      ] {
        open(subject)
        XCTAssertTrue(text(status, in: window).waitForExistence(timeout: 20), subject)
        XCTAssertEqual(window.buttons["Accept"].exists, answerable, subject)
        capture(name)
      }
      guard appearance == "Light" else { continue }
      // The Q4 roadmap review moved after the declined answer: the revision names it, and
      // answering it makes the original an older version whose Show Latest opens it.
      open("Updated invitation: Q4 roadmap review")
      XCTAssertTrue(text("Lena Fischer changed the time", in: window).waitForExistence(timeout: 20))
      XCTAssertTrue(text("You declined the earlier time", in: window).exists)
      capture("updated time")
      respond("Accept", "Accepted")
      open("Invitation: Q4 roadmap review")
      XCTAssertTrue(
        text("There’s a newer version of this invitation", in: window)
          .waitForExistence(timeout: 20))
      XCTAssertFalse(window.buttons["Accept"].exists)
      capture("older version")
      window.buttons["Show Latest"].click()
      XCTAssertTrue(text("Accepted. Gmail confirmed", in: window).waitForExistence(timeout: 20))
      // Gmail fails each response to the supplier walkthrough in turn: offline, refused, then
      // delivery unknown, whose Check Again finds nothing in Sent, and after Respond Again a
      // sign-in.
      open("Invitation: Supplier walkthrough")
      for (status, name) in [
        ("You’re offline", "offline"), ("Not sent", "not sent"), ("Delivery unknown", "unknown"),
      ] {
        window.buttons["Accept"].click()
        XCTAssertTrue(text(status, in: window).waitForExistence(timeout: 20), name)
        capture(name)
      }
      window.buttons["Check Again"].click()
      XCTAssertTrue(text("Checking with Gmail", in: window).waitForExistence(timeout: 5))
      capture("checking sent")
      XCTAssertTrue(text("Delivery unknown", in: window).waitForExistence(timeout: 20))
      window.buttons["Respond Again…"].click()
      let confirm = window.sheets.firstMatch.buttons["Respond Again"]
      XCTAssertTrue(confirm.waitForExistence(timeout: 5))
      confirm.click()
      XCTAssertTrue(
        text("Gmail needs you to sign in again", in: window).waitForExistence(timeout: 20))
      XCTAssertTrue(window.buttons["Sign In…"].exists)
      capture("sign-in needed")
    }
  }

  // #1076: the composer's Text style, From and actions pop-ups open AppKit menus that the system
  // dismisses, and each choice changes only the Draft of the window that opened the menu.
  private func composerMenuJourney(_ app: XCUIApplication, first: XCUIElement) {
    func compose(in window: XCUIElement) -> XCUIElement {
      window.buttons["New Message"].click()
      let style = window.popUpButtons["Text style"]
      XCTAssertTrue(style.waitForExistence(timeout: 15))
      return style
    }
    // XCUITest does not expose an AppKit menu's checkmark (isSelected is the pointer highlight),
    // so each pop-up reports its current choice as its accessibility value.
    func shows(_ control: XCUIElement, _ choice: String) {
      waitUntil { (control.value as? String) == choice }
    }
    let style = compose(in: first)
    shows(style, "Body")
    style.click()
    let heading = app.menuItems["Heading 1"]
    XCTAssertTrue(heading.waitForExistence(timeout: 5))
    // Escape and a click outside the menu dismiss it without a choice.
    first.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(heading.waitForNonExistence(timeout: 5))
    style.click()
    XCTAssertTrue(heading.waitForExistence(timeout: 5))
    first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).click()
    XCTAssertTrue(heading.waitForNonExistence(timeout: 5))
    shows(style, "Body")
    style.click()
    heading.click()
    XCTAssertTrue(heading.waitForNonExistence(timeout: 5))
    shows(style, "Heading 1")
    // The sender menu lists the Profile's mailboxes.
    let from = first.popUpButtons.matching(NSPredicate(format: "label BEGINSWITH %@", "Send from"))
      .firstMatch
    XCTAssertTrue(from.waitForExistence(timeout: 5))
    let sender = from.label.replacingOccurrences(of: "Send from ", with: "")
    from.click()
    XCTAssertTrue(app.menuItems[sender].waitForExistence(timeout: 5))
    first.typeKey(.escape, modifierFlags: [])
    // A second window's Draft keeps its own text style.
    app.typeKey("n", modifierFlags: [.command, .option])
    let second = app.windows["Inbox 2"]
    // A new window may open on the confirmed-setup account page (#1189).
    if second.buttons["Open Inbox"].waitForExistence(timeout: 10) { second.buttons["Open Inbox"].click() }
    XCTAssertTrue(second.buttons["New Message"].waitForExistence(timeout: 15))
    let secondStyle = compose(in: second)
    shows(secondStyle, "Body")
    secondStyle.click()
    app.menuItems["Quote"].click()
    shows(secondStyle, "Quote")
    shows(style, "Heading 1")
    // Discard is the destructive action and asks before removing the Draft.
    first.click()
    first.menuButtons["Compose actions"].click()
    let discard = app.menuItems["Discard"]
    XCTAssertTrue(discard.waitForExistence(timeout: 5))
    discard.click()
    XCTAssertTrue(first.buttons["Discard Draft"].waitForExistence(timeout: 5))
    first.buttons["Keep Editing"].click()
    XCTAssertTrue(second.popUpButtons["Text style"].exists)
    app.terminate()
  }


  // Signs the registration-draft-editor build in with Google and confirms the Recovery Key, which
  // opens the Inbox.
  private func draftEditorSignIn(_ first: XCUIElement) {
    XCTAssertTrue(first.buttons["Continue"].waitForExistence(timeout: 20))
    first.buttons["Continue"].click()
    XCTAssertTrue(first.buttons["Sign in with Google"].waitForExistence(timeout: 20))
    first.buttons["Sign in with Google"].click()
    XCTAssertTrue(recoveryKey(in: first).waitForExistence(timeout: 15))
    let presented = recoveryKey(in: first).value as? String ?? ""
    first.buttons["Choose Another Google Mailbox"].click()
    XCTAssertTrue(text("connected on this device", in: first).waitForExistence(timeout: 15))
    let entry = first.textFields["Last four characters"]
    entry.click()
    // Confirm each character reached the controlled field before sending the next one.
    var confirmation = ""
    for character in presented.suffix(4) {
      entry.typeText(String(character))
      confirmation += String(character)
      let entered = NSPredicate(format: "value == %@", confirmation)
      XCTAssertEqual(
        XCTWaiter.wait(
          for: [XCTNSPredicateExpectation(predicate: entered, object: entry)], timeout: 5),
        .completed)
    }
    first.buttons["Confirm Recovery Key"].click()
    XCTAssertTrue(
      first.buttons["Unread. Rowan Hale. Garden plans for spring"].waitForExistence(timeout: 20))
  }

  // The Tiptap evaluation editor (#818): a new Draft is typed into the packaged page, saved through
  // the encrypted Draft store, and reopened after relaunch. Focus, resize and teardown are recorded.
  private func draftEditorJourney(_ app: XCUIApplication, first: XCUIElement) {
    draftEditorSignIn(first)
    // Assistance in the editor needs Mail Assistance Enablement; this build's model is synthetic.
    first.buttons["Settings"].click()
    let settings = app.windows["settings-window"]
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    XCTAssertTrue(settings.buttons["Privacy & Data"].waitForExistence(timeout: 15))
    settings.buttons["Privacy & Data"].click()
    settings.switches["Mail Assistance"].click()
    XCTAssertTrue(text("On-device assistance is on.", in: settings).waitForExistence(timeout: 15))
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(settings.waitForNonExistence(timeout: 10))
    // The disposable Draft belongs to this run's synthetic Product Account only.
    first.buttons["New Message"].click()
    let body = first.webViews.textViews["Message body"]
    XCTAssertTrue(body.waitForExistence(timeout: 15))
    // The toolbar appears once the page is ready and moves the page down; focus it after that.
    XCTAssertTrue(first.buttons["Undo"].waitForExistence(timeout: 30))
    // Focus: typing reaches the page only once its editable body holds keyboard focus.
    body.click()
    body.typeText("Evaluation paragraph")
    let typed = first.webViews.staticTexts.matching(
      NSPredicate(format: "value == %@", "Evaluation paragraph")
    ).firstMatch
    XCTAssertTrue(typed.waitForExistence(timeout: 10))
    // Settings opens beside an unfinished editor without offering its Save/Delete decision.
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    XCTAssertFalse(first.buttons["Save"].exists)
    app.typeKey(",", modifierFlags: .command)
    XCTAssertEqual(app.windows.matching(identifier: "settings-window").count, 1)
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(settings.waitForNonExistence(timeout: 10))
    XCTAssertTrue(typed.exists)
    // Resize: the page follows a narrower window without reloading or losing its text.
    let before = first.webViews.firstMatch.frame
    let corner = first.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
      .withOffset(CGVector(dx: -2, dy: -2))
    corner.click(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: -160, dy: 0)))
    let resized = NSPredicate { _, _ in first.webViews.firstMatch.frame.width != before.width }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: resized, object: nil)], timeout: 10),
      .completed)
    XCTAssertTrue(typed.exists)
    formattingJourney(app, typed: typed)
    // The last round trip reopened the Draft unchanged, so Close needs no save choice.
    first.buttons["Close"].click()
    waitUntil { first.webViews.count == 0 }
    XCTAssertFalse(first.buttons["Save"].exists)
    app.terminate()
    app.launch()
    let relaunched = app.windows["Inbox 1"]
    let draft = relaunched.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Draft."))
      .firstMatch
    XCTAssertTrue(draft.waitForExistence(timeout: 20))
    draft.click()
    // The accepted reply body reopens as it was saved.
    XCTAssertTrue(
      webText("Synthetic reply to local mail.", in: relaunched).waitForExistence(timeout: 15))
    pastedImageJourney(app, window: relaunched)
    nativeCloseJourney(app, window: relaunched)
  }

  // #2929: an image pasted into the page is read from the pasteboard by native code, goes inline
  // with its verified thumbnail, and keeps its place through Save, relaunch and reopening.
  private func pastedImageJourney(_ app: XCUIApplication, window: XCUIElement) {
    let image = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
      NSColor.systemTeal.setFill()
      rect.fill()
      return true
    }
    let png = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
      .representation(using: .png, properties: [:])
    XCTAssertNotNil(png)
    // Give the person their pasteboard back afterwards.
    let pasteboard = NSPasteboard.general
    let before = pasteboard.changeCount
    let saved = (pasteboard.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) { copy.setData(data, forType: type) }
      }
      return copy
    }
    // A pasted file that is not an image becomes an Attachment. The sandboxed copy may read only
    // its run directory, beside Mock.app.
    let appURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["UNWIRED_APP_PATH"] ?? "")
    let file = appURL.deletingLastPathComponent().appendingPathComponent("paste-note.txt")
    XCTAssertNoThrow(try Data("Pasted into the page".utf8).write(to: file))
    addTeardownBlock { try? FileManager.default.removeItem(at: file) }
    guard pasteboard.changeCount == before else {
      XCTFail("Another app wrote to the pasteboard during the journey")
      return
    }
    // The count clearContents returns is ours: a later copy by another app changes it.
    var written = pasteboard.clearContents()
    pasteboard.writeObjects([file as NSURL])
    addTeardownBlock {
      guard pasteboard.changeCount == written else { return }
      pasteboard.clearContents()
      pasteboard.writeObjects(saved)
    }
    let body = window.webViews.textViews["Message body"]
    webText("Synthetic reply to local mail.", in: window).click()
    window.typeKey(.downArrow, modifierFlags: .command)
    window.typeKey("v", modifierFlags: .command)
    let note = window.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "paste-note.txt, ")).firstMatch
    XCTAssertTrue(note.waitForExistence(timeout: 30))
    XCTAssertEqual(body.images.count, 0)
    // Another app's newer copy is never overwritten.
    guard pasteboard.changeCount == written else {
      XCTFail("Another app wrote to the pasteboard during the journey")
      return
    }
    written = pasteboard.clearContents()
    pasteboard.setData(png, forType: .png)
    window.typeKey("v", modifierFlags: .command)
    let row = window.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Pasted image, ")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 30))
    let inline = body.images.firstMatch
    XCTAssertTrue(inline.waitForExistence(timeout: 30))
    // The placeholder gives way to the native thumbnail once the bytes verify.
    waitUntil { inline.frame.width > 60 }
    let pasted = XCTAttachment(screenshot: window.screenshot())
    pasted.name = "Evaluation editor pasted image"
    pasted.lifetime = .keepAlways
    add(pasted)
    reopenDraft(app)
    XCTAssertTrue(
      webText("Synthetic reply to local mail.", in: window).waitForExistence(timeout: 15))
    let reopened = window.webViews.textViews["Message body"].images.firstMatch
    XCTAssertTrue(reopened.waitForExistence(timeout: 30))
    waitUntil { reopened.frame.width > 60 }
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    XCTAssertTrue(note.exists)
    let shot = XCTAttachment(screenshot: window.screenshot())
    shot.name = "Evaluation Draft with pasted image after relaunch"
    shot.lifetime = .keepAlways
    add(shot)
  }

  private func nativeCloseJourney(_ app: XCUIApplication, window: XCUIElement) {
    let subject = window.textFields["Subject"]
    subject.click()
    subject.typeText("Native close")
    let body = window.webViews.textViews["Message body"]
    body.click()
    window.typeKey("w", modifierFlags: .command)
    // The question is an AppKit alert sheet on this window; Escape answers Cancel.
    let sheet = window.sheets.firstMatch
    XCTAssertTrue(sheet.buttons["Save"].waitForExistence(timeout: 10))
    XCTAssertTrue(sheet.buttons["Don’t Save"].exists)
    window.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
    // Typing continues in the body, where the sheet returned keyboard focus.
    app.typeText(" Resumed")
    XCTAssertTrue(webText("Resumed", in: window).waitForExistence(timeout: 10))
    // A refused Save must also return typing to the body, rather than an unfocused WebView.
    let to = window.textFields["To"]
    typeRecipient(to, "invalid-address")
    body.click()
    window.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(sheet.buttons["Save"].waitForExistence(timeout: 10))
    sheet.buttons["Save"].click()
    XCTAssertTrue(
      text("Correct or remove the invalid address to close this Draft.", in: window)
        .waitForExistence(timeout: 10))
    app.typeText(" After refusal")
    XCTAssertTrue(webText("After refusal", in: window).waitForExistence(timeout: 10))
    to.click()
    window.typeKey("a", modifierFlags: .command)
    window.typeKey(.delete, modifierFlags: [])
    body.click()
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(sheet.buttons["Save"].waitForExistence(timeout: 10))
    sheet.buttons["Cancel"].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
    // Saving later must not revive a cancelled Quit.
    saveOnClose(window)
    XCTAssertTrue(window.buttons["New Message"].waitForExistence(timeout: 10))
    // File › New Message, Command-N, starts a Draft as the button does.
    app.typeKey("n", modifierFlags: .command)
    XCTAssertTrue(window.buttons["Undo"].waitForExistence(timeout: 30))
    window.textFields["Subject"].click()
    window.textFields["Subject"].typeText("First guarded window")
    app.typeKey("n", modifierFlags: [.command, .option])
    let second = app.windows["Inbox 2"]
    XCTAssertTrue(second.buttons["New Message"].waitForExistence(timeout: 15))
    second.buttons["New Message"].click()
    XCTAssertTrue(second.buttons["Undo"].waitForExistence(timeout: 30))
    second.textFields["Subject"].click()
    second.textFields["Subject"].typeText("Second guarded window")
    app.typeKey("q", modifierFlags: .command)
    // One Quit asks each window, then actually stops the process.
    let saving = app.sheets.firstMatch
    XCTAssertTrue(saving.buttons["Save"].waitForExistence(timeout: 10))
    saving.buttons["Save"].click()
    waitUntil { app.windows.count == 1 }
    let remaining = app.windows.firstMatch.sheets.firstMatch
    XCTAssertTrue(remaining.buttons["Don’t Save"].waitForExistence(timeout: 10))
    remaining.buttons["Don’t Save"].click()
    waitUntil { app.state == .notRunning }
    twoWindowJourney(app)
  }

  // #2938: two windows edit one saved Draft in the page. The window that saves second keeps its
  // version as a conflicting copy, and its close button asks as Command-W does.
  private func twoWindowJourney(_ app: XCUIApplication) {
    app.launch()
    let first = app.windows["Inbox 1"]
    let original = NSPredicate(
      format: "label BEGINSWITH %@ AND label CONTAINS %@", "Draft.", "Native close")
    let copy = NSPredicate(
      format: "label BEGINSWITH %@ AND label CONTAINS %@", "Conflicting Draft.", "Native close")
    openDraft(first, original)
    app.typeKey("n", modifierFlags: [.command, .option])
    let second = app.windows["Inbox 2"]
    XCTAssertTrue(second.waitForExistence(timeout: 15))
    openDraft(second, original)
    // The saved body, which each version must keep beside its own text.
    func keepsBody(_ window: XCUIElement) {
      for saved in ["Synthetic reply to local mail.", "Resumed", "After refusal"] {
        XCTAssertTrue(webText(saved, in: window).waitForExistence(timeout: 15))
      }
    }
    // Typing reaches the page of the window in front, at the end of its body.
    func append(_ value: String, in window: XCUIElement) {
      window.webViews.textViews["Message body"].click()
      window.typeKey(.downArrow, modifierFlags: .command)
      app.typeText(value)
      XCTAssertTrue(webText(value, in: window).waitForExistence(timeout: 10))
      keepsBody(window)
    }
    append(" Window B", in: second)
    app.menuBars.menuBarItems["Window"].click()
    app.menuItems["Inbox 1"].click()
    append(" Window A", in: first)
    saveOnClose(first)
    XCTAssertFalse(webText("Window A", in: second).exists)
    // Inbox 1 overlaps the close button of the window behind it.
    app.menuBars.menuBarItems["Window"].click()
    app.menuItems["Inbox 2"].click()
    let close = second.buttons[XCUIIdentifierCloseWindow]
    close.click()
    let sheet = second.sheets.firstMatch
    XCTAssertTrue(sheet.buttons["Save"].waitForExistence(timeout: 10))
    XCTAssertTrue(sheet.buttons["Don’t Save"].exists)
    sheet.buttons["Cancel"].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
    XCTAssertTrue(webText("Window B", in: second).exists)
    keepsBody(second)
    close.click()
    XCTAssertTrue(sheet.buttons["Save"].waitForExistence(timeout: 10))
    sheet.buttons["Save"].click()
    XCTAssertTrue(second.waitForNonExistence(timeout: 20))
    XCTAssertTrue(first.buttons.matching(copy).firstMatch.waitForExistence(timeout: 20))
    // Both versions survive a relaunch, each in its own Draft.
    app.terminate()
    app.launch()
    openDraft(first, copy)
    XCTAssertTrue(webText("Window B", in: first).waitForExistence(timeout: 15))
    XCTAssertFalse(webText("Window A", in: first).exists)
    keepsBody(first)
    // Unchanged since it opened, so Close needs no save choice.
    first.buttons["Close"].click()
    waitUntil { first.webViews.count == 0 }
    openDraft(first, original)
    XCTAssertTrue(webText("Window A", in: first).waitForExistence(timeout: 15))
    XCTAssertFalse(webText("Window B", in: first).exists)
    keepsBody(first)
  }

  private func webText(_ value: String, in window: XCUIElement) -> XCUIElement {
    window.webViews.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", value))
      .firstMatch
  }

  // A Writing tools item of the AppKit menu the sparkles button opens. The menu shows the page
  // state from when it opened, so it reopens until a selection reported since enables the item.
  private func writingTool(
    _ name: String, in window: XCUIElement, of app: XCUIApplication
  ) -> XCUIElement {
    let tools = window.menuButtons["Writing tools"]
    XCTAssertTrue(tools.waitForExistence(timeout: 30))
    let action = app.menuItems[name]
    for _ in 0..<5 {
      tools.click()
      if action.waitForExistence(timeout: 5) && action.isEnabled { return action }
      window.typeKey(.escape, modifierFlags: [])
    }
    XCTFail("Writing tools never offered \(name)")
    return action
  }

  private func saveOnClose(_ window: XCUIElement) {
    window.buttons["Close"].click()
    let save = window.sheets.firstMatch.buttons["Save"]
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    save.click()
    // A reader beside a reply keeps its own web view, so wait for the editor's body to go.
    XCTAssertTrue(window.webViews.textViews["Message body"].waitForNonExistence(timeout: 20))
  }

  // #819: Command-B formats the selection in the page, Command-Z and Shift-Command-Z step the
  // page's history, and an accepted rewrite is one edit that one Undo reverts.
  private func formattingJourney(_ app: XCUIApplication, typed: XCUIElement) {
    let window = app.windows["Inbox 1"]
    // Select the whole body, so every word of it is bold when the Draft reopens.
    typed.click()
    window.typeKey("a", modifierFlags: .command)
    window.typeKey("b", modifierFlags: .command)
    let numbered = window.buttons["Numbered List"]
    numbered.click()
    // The page draws the number with CSS (#2884), so the bar's selected list shows the list item.
    waitUntil { numbered.isSelected }
    window.typeKey("z", modifierFlags: .command)
    window.typeKey("z", modifierFlags: .command)
    waitUntil { !numbered.isSelected }
    window.typeKey("z", modifierFlags: [.command, .shift])
    window.typeKey("z", modifierFlags: [.command, .shift])
    waitUntil { numbered.isSelected }
    reopenDraft(app)
    webText("Evaluation paragraph", in: window).doubleClick()
    waitUntil { window.buttons["Bold"].isSelected && window.buttons["Numbered List"].isSelected }
    // #1568: Select All starts outside the list item, and the bar still shows the list selected.
    window.typeKey("a", modifierFlags: .command)
    for _ in 0..<3 {
      RunLoop.current.run(until: Date().addingTimeInterval(1))
      XCTAssertTrue(window.buttons["Numbered List"].isSelected)
    }
    // The text's centre falls on the space between its words, which selects no text.
    let firstWord = {
      window.webViews.staticTexts.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
    }
    assistanceRoundTrips(app, result: "Synthetic rewrite of local mail.", apply: "Replace your text with this rewrite", boldAfterApply: true) {
      firstWord().doubleClick()
      self.writingTool("Rewrite the selected text", in: window, of: app).click()
    }
    assistanceRoundTrips(app, result: "Synthetic rewrite of local mail.", apply: "Replace your text with this rewrite", boldAfterApply: false) {
      window.webViews.textViews["Message body"].click()
      self.writingTool("Rewrite the message body", in: window, of: app).click()
    }
    // #1625: Generate a Draft asks from its prompt alone and inserts the result at the caret.
    assistanceRoundTrips(app, result: "Synthetic rewrite of local mail.", apply: "Insert this draft at the cursor", boldAfterApply: false) {
      window.webViews.textViews["Message body"].click()
      self.writingTool("Generate a draft from a description of what to write", in: window, of: app).click()
      let generate = app.buttons["Generate a draft from this description"]
      XCTAssertTrue(generate.waitForExistence(timeout: 10))
      XCTAssertFalse(generate.isEnabled)
      // The prompt field has keyboard focus when the popover opens.
      app.typeText("confirm Thursday")
      waitUntil { generate.isEnabled }
      app.typeText("\r")
    }
    assistanceRoundTrips(app, result: "Synthetic translation of local mail.", apply: "Replace the selected text with this translation", boldAfterApply: false) {
      firstWord().doubleClick()
      // Translate To opens its submenu of the device's languages.
      self.writingTool("Translate the selected text", in: window, of: app).hover()
      let german = app.menuItems["Translate into German"]
      XCTAssertTrue(german.waitForExistence(timeout: 10))
      german.click()
    }
    evaluationLinkJourney(app)
    window.buttons["Close"].click()
    waitUntil { window.webViews.count == 0 }
    window.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Garden plans for spring"))
      .firstMatch.click()
    window.buttons["Reply"].click()
    XCTAssertTrue(window.buttons["Undo"].waitForExistence(timeout: 30))
    assistanceRoundTrips(
      app, result: "Synthetic reply to local mail.", apply: "Replace your reply with this suggestion",
      draft: "Garden plans for spring", numbered: false, boldAfterApply: false
    ) {
      self.writingTool("Suggest a reply to the quoted message", in: window, of: app).click()
    }
  }

  // #2876: the Link Editor links the translated paragraph as one edit that one Undo reverts and
  // Redo restores, and the link and its destination survive Save, relaunch and reopening.
  private func evaluationLinkJourney(_ app: XCUIApplication) {
    let window = app.windows["Inbox 1"]
    let body = window.webViews.textViews["Message body"]
    let pageText = { body.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? "" } }
    // WebKit reads the list item's CSS number (#2884) as texts before the paragraph's, "1" and ".".
    let paragraph = { (texts: [String]) in String(texts.joined().trimmingPrefix("1.")) }
    let unlinked = pageText()
    let link = body.links.firstMatch
    // The one link in the page holds the whole paragraph, not part of it.
    let linked = {
      body.links.count == 1
        && link.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? "" }.joined()
          == paragraph(unlinked)
    }
    let addLink = window.buttons["Add Link"]
    let edit = window.buttons["Edit Link"]
    let destination = app.textFields["Link"]
    // Select the paragraph from its first character to its last, inside its one block.
    webText("Synthetic translation of local mail.", in: window).click()
    window.typeKey(.upArrow, modifierFlags: .command)
    window.typeKey(.downArrow, modifierFlags: [.command, .shift])
    waitUntil { addLink.isEnabled }
    addLink.click()
    XCTAssertTrue(destination.waitForExistence(timeout: 10))
    waitForFocus(destination)
    XCTAssertEqual(destination.value as? String, "")
    XCTAssertEqual(app.textFields["Text"].value as? String, paragraph(unlinked))
    XCTAssertFalse(app.buttons["Remove Link"].exists)
    app.typeText("https://example.com/evaluation")
    let apply = app.buttons["Apply"]
    waitUntil { apply.isEnabled }
    apply.click()
    XCTAssertTrue(destination.waitForNonExistence(timeout: 10))
    waitUntil(linked)
    // Edit Link offers Remove Link and the saved destination; Escape changes nothing.
    let editLink = { (shot: String) in
      self.waitUntil { edit.isEnabled }
      edit.click()
      XCTAssertTrue(app.buttons["Remove Link"].waitForExistence(timeout: 10))
      XCTAssertEqual(destination.value as? String, "https://example.com/evaluation")
      let capture = XCTAttachment(screenshot: window.screenshot())
      capture.name = shot
      capture.lifetime = .keepAlways
      self.add(capture)
      app.typeKey(.escape, modifierFlags: [])
      XCTAssertTrue(destination.waitForNonExistence(timeout: 10))
    }
    editLink("Evaluation Edit Link")
    waitUntil { window.buttons["Undo"].isEnabled }
    window.buttons["Undo"].click()
    waitUntil { !link.exists && pageText() == unlinked }
    waitUntil { window.buttons["Redo"].isEnabled }
    window.buttons["Redo"].click()
    waitUntil(linked)
    reopenDraft(app)
    waitUntil(linked)
    // A click puts the caret in the reopened link, which the page never opens.
    link.click()
    editLink("Evaluation Edit Link after relaunch")
  }

  private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 20) {
    let met = NSPredicate { _, _ in condition() }
    XCTAssertEqual(
      XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: met, object: nil)], timeout: timeout),
      .completed)
  }

  private func reopenDraft(_ app: XCUIApplication, titled title: String = "") {
    let window = app.windows["Inbox 1"]
    saveOnClose(window)
    app.terminate()
    app.launch()
    // A Draft row names its subject; without a title, the only Draft so far.
    // CONTAINS never matches an empty string, so an untitled reopen matches the prefix alone.
    openDraft(
      window,
      title.isEmpty
        ? NSPredicate(format: "label BEGINSWITH %@", "Draft.")
        : NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Draft.", title))
  }

  private func openDraft(_ window: XCUIElement, _ label: NSPredicate) {
    let draft = window.buttons.matching(label).firstMatch
    // Restoring the session after a launch can take a while on a loaded host.
    XCTAssertTrue(draft.waitForExistence(timeout: 45))
    // Rows can still move while the restored list settles; tap the row once it stays in place.
    var placed = draft.frame
    for _ in 0..<10 {
      RunLoop.current.run(until: Date().addingTimeInterval(1))
      if draft.frame == placed { break }
      placed = draft.frame
    }
    draft.click()
    XCTAssertTrue(window.buttons["Undo"].waitForExistence(timeout: 30))
  }

  private func assistanceRoundTrips(
    _ app: XCUIApplication, result: String, apply: String, draft title: String = "",
    numbered: Bool = true, boldAfterApply: Bool, start: () -> Void
  ) {
    let window = app.windows["Inbox 1"]
    // The editor's text alone: a reader beside a reply shows its message in a web view too.
    let body = {
      window.webViews.textViews["Message body"].staticTexts.allElementsBoundByIndex
        .map { $0.value as? String ?? "" }
    }
    for leaveUndone in [true, false] {
      let original = body()
      let originalBold = window.buttons["Bold"].isSelected
      start()
      // The selectable result is a native text view holding it as its value.
      let shown = window.textViews.matching(NSPredicate(format: "value == %@", result)).firstMatch
      XCTAssertTrue(shown.waitForExistence(timeout: 15))
      let accept = window.buttons[apply]
      XCTAssertTrue(accept.waitForExistence(timeout: 15))
      accept.click()
      waitUntil { body() != original }
      waitUntil { body().joined(separator: " ").contains(result) }
      let accepted = body()
      waitUntil { window.buttons["Numbered List"].isSelected == numbered && window.buttons["Bold"].isSelected == boldAfterApply }
      waitUntil { window.buttons["Undo"].isEnabled }
      window.buttons["Undo"].click()
      waitUntil { body() == original }
      waitUntil { window.buttons["Numbered List"].isSelected == numbered && window.buttons["Bold"].isSelected == originalBold }
      if !leaveUndone {
        waitUntil { window.buttons["Redo"].isEnabled }
        window.buttons["Redo"].click()
        waitUntil { body() == accepted }
        waitUntil { window.buttons["Numbered List"].isSelected == numbered && window.buttons["Bold"].isSelected == boldAfterApply }
      }
      reopenDraft(app, titled: title)
      // The reopened page replaces any editor shown at launch once it has loaded.
      let expected = leaveUndone ? original : accepted
      waitUntil { body() == expected }
      let expectedBold = leaveUndone ? originalBold : boldAfterApply
      waitUntil {
        window.buttons["Numbered List"].isSelected == numbered
          && window.buttons["Bold"].isSelected == expectedBold
      }
    }
  }

  // A new device of an existing account waits until a trusted device approves it; signing in alone
  // admits nothing, so Gmail authorization appears only afterwards.
  private func enrollmentJourney(_ app: XCUIApplication, first: XCUIElement) {
    XCTAssertTrue(first.buttons["Continue"].waitForExistence(timeout: 20))
    first.buttons["Continue"].click()
    XCTAssertTrue(first.buttons["Sign in with Google"].waitForExistence(timeout: 20))
    first.buttons["Sign in with Google"].click()
    XCTAssertTrue(text("Approve this device", in: first).waitForExistence(timeout: 15))
    XCTAssertTrue(enrollmentCode(in: first).exists)
    XCTAssertFalse(recoveryKey(in: first).exists)
    XCTAssertFalse(first.buttons["Gmail"].exists)
    XCTAssertFalse(first.buttons["Choose Another Google Mailbox"].exists)
    let mailboxes = "Encrypted mailbox list: alex@example.invalid."
    XCTAssertFalse(text(mailboxes, in: first).exists)
    // The synthetic trusted device approves with the code shown on this device.
    first.buttons["Check for Approval"].click()
    XCTAssertTrue(text("Sync is on", in: first).waitForExistence(timeout: 15))
    XCTAssertTrue(text(mailboxes, in: first).exists)
    // Gmail on this device still needs its own authorization.
    XCTAssertTrue(first.buttons["Gmail"].exists)
    app.terminate()
    app.launch()
    let relaunched = app.windows["Inbox 1"]
    XCTAssertTrue(text("Sync is on", in: relaunched).waitForExistence(timeout: 15))
    XCTAssertTrue(text(mailboxes, in: relaunched).waitForExistence(timeout: 15))
    XCTAssertFalse(enrollmentCode(in: relaunched).exists)
  }

  // Without a trusted device, the Recovery Key admits this device and unlocks the account's keys.
  private func recoveryJourney(_ app: XCUIApplication, first: XCUIElement) {
    XCTAssertTrue(first.buttons["Continue"].waitForExistence(timeout: 20))
    first.buttons["Continue"].click()
    XCTAssertTrue(first.buttons["Sign in with Google"].waitForExistence(timeout: 20))
    first.buttons["Sign in with Google"].click()
    XCTAssertTrue(text("Use your Recovery Key", in: first).waitForExistence(timeout: 15))
    XCTAssertTrue(enrollmentCode(in: first).exists)
    XCTAssertFalse(first.buttons["Gmail"].exists)
    let mailboxes = "Encrypted mailbox list: alex@example.invalid."
    XCTAssertFalse(text(mailboxes, in: first).exists)
    let entry = first.textFields["Recovery Key"]
    // A key with one changed character unlocks nothing.
    entry.click()
    entry.typeText("100G-40R4-0M30-E209-185G-R38E-1W81-24GK-2GAH-C5RR-34D1-P70X-3RFG")
    first.buttons["Unlock with Recovery Key"].click()
    XCTAssertTrue(
      text("does not unlock this Unwired account", in: first).waitForExistence(timeout: 15))
    XCTAssertTrue(text("Approve this device", in: first).exists)
    entry.click()
    entry.typeKey("a", modifierFlags: .command)
    entry.typeText("000G-40R4-0M30-E209-185G-R38E-1W81-24GK-2GAH-C5RR-34D1-P70X-3RFG")
    first.buttons["Unlock with Recovery Key"].click()
    XCTAssertTrue(text("Sync is on", in: first).waitForExistence(timeout: 15))
    XCTAssertTrue(text(mailboxes, in: first).exists)
    XCTAssertFalse(enrollmentCode(in: first).exists)
    // Gmail on this device still needs its own authorization.
    XCTAssertTrue(first.buttons["Gmail"].exists)
    app.terminate()
    app.launch()
    let relaunched = app.windows["Inbox 1"]
    XCTAssertTrue(text("Sync is on", in: relaunched).waitForExistence(timeout: 15))
    XCTAssertTrue(text(mailboxes, in: relaunched).waitForExistence(timeout: 15))
    XCTAssertFalse(relaunched.textFields["Recovery Key"].exists)
  }

  // #1130: a link asks in an AppKit sheet on its own window, showing the full destination as
  // selectable text. Escape and Cancel close it without acting, and Command-K stays closed behind
  // it. A flagged link's first button, Cancel, is the default and answers Escape too. Nothing is
  // opened or copied: either would reach the desktop's browser or pasteboard.
  private func linkSheetJourney(_ app: XCUIApplication, window: XCUIElement) throws {
    let sheet = window.sheets.firstMatch
    // AppKit exposes the alert's texts as values.
    func shows(_ value: String) -> Bool {
      sheet.descendants(matching: .any).matching(NSPredicate(format: "value == %@", value))
        .firstMatch.exists
    }
    func ask(_ link: String, title: String, destination: String, buttons: [String]) {
      window.links.matching(identifier: "message-link-control")
        .matching(NSPredicate(format: "label == %@", link)).firstMatch.click()
      XCTAssertTrue(sheet.waitForExistence(timeout: 10))
      XCTAssertTrue(shows(title))
      XCTAssertTrue(shows(destination))
      // AppKit lists the buttons in no fixed order, beside an untitled scroller.
      XCTAssertEqual(
        Set(sheet.buttons.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }), Set(buttons))
    }
    let garden = "https://example.invalid/garden"
    ask("garden plan", title: "Open this link in your browser?", destination: garden,
        buttons: ["Open Link", "Cancel"])
    app.typeKey("k", modifierFlags: .command)
    XCTAssertFalse(window.textFields["Type a command"].waitForExistence(timeout: 2))
    XCTAssertTrue(sheet.exists)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    ask("garden plan", title: "Open this link in your browser?", destination: garden,
        buttons: ["Open Link", "Cancel"])
    sheet.buttons["Cancel"].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    let flagged = "https://garden.example.invalid/order"
    let seeds = "https://seeds.example.invalid/order"
    let caution = "This link may not be what it seems"
    for key in [XCUIKeyboardKey.escape, .return] {
      ask(flagged, title: caution, destination: seeds, buttons: ["Cancel", "Copy Link", "Proceed"])
      if key == .escape { try audit(app, "Link sheet") }
      app.typeKey(key, modifierFlags: [])
      XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }
    // Focus returns to the window, whose Command Palette opens again.
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(window.textFields["Type a command"].waitForExistence(timeout: 10))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(window.textFields["Type a command"].waitForNonExistence(timeout: 10))
  }

  // #1225: removing a Mail Profile asks in a sheet on Settings, where Cancel is the default button
  // that Escape and Return answer; only Remove removes it.
  private func profileRemovalJourney(_ app: XCUIApplication, settings: XCUIElement) {
    let sheet = settings.sheets.firstMatch
    settings.buttons["Profiles"].click()
    settings.buttons["Add Profile…"].click()
    XCTAssertTrue(sheet.waitForExistence(timeout: 10))
    sheet.textFields.firstMatch.click()
    sheet.typeText("Travel")
    sheet.buttons["Create"].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    let travel = settings.buttons["Travel"]
    XCTAssertTrue(travel.waitForExistence(timeout: 15))
    travel.click()
    // #1619: a new Mail Profile is Graphite with its First Letter; each pop-up's AppKit menu
    // owns the choice.
    for (label, from, to) in [("Color", "Graphite", "Blue"), ("Icon", "First Letter", "Airplane")] {
      let popUp = settings.popUpButtons[label]
      XCTAssertTrue(popUp.waitForExistence(timeout: 15))
      XCTAssertEqual(popUp.value as? String, from)
      popUp.click()
      let item = app.menuItems[to]
      XCTAssertTrue(item.waitForExistence(timeout: 5))
      item.click()
      waitUntil { popUp.value as? String == to }
    }
    let remove = settings.buttons["Remove Profile…"]
    func ask() {
      XCTAssertTrue(remove.waitForExistence(timeout: 15))
      remove.click()
      XCTAssertTrue(sheet.waitForExistence(timeout: 10))
      // AppKit exposes the alert's texts as values.
      XCTAssertTrue(
        sheet.descendants(matching: .any).matching(NSPredicate(format: "value == %@", "Remove “Travel”?"))
          .firstMatch.exists)
      XCTAssertEqual(
        Set(sheet.buttons.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }),
        ["Cancel", "Remove"])
    }
    for key in [XCUIKeyboardKey.escape, .return] {
      ask()
      app.typeKey(key, modifierFlags: [])
      XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
      XCTAssertTrue(travel.exists)
    }
    ask()
    sheet.buttons["Remove"].click()
    XCTAssertTrue(travel.waitForNonExistence(timeout: 15))
  }

  // Linking verifies both identities; the Gmail grant never becomes a sign-in method.
  private func linkJourney(_ app: XCUIApplication, first: XCUIElement) {
    XCTAssertTrue(first.buttons["Continue"].waitForExistence(timeout: 20))
    first.buttons["Continue"].click()
    XCTAssertTrue(first.buttons["Sign in with Apple"].waitForExistence(timeout: 20))
    first.buttons["Sign in with Apple"].click()
    XCTAssertTrue(first.buttons["Gmail"].waitForExistence(timeout: 15))
    first.buttons["Gmail"].click()
    XCTAssertTrue(text("connected on this device", in: first).waitForExistence(timeout: 15))
    XCTAssertTrue(text("Only Apple opens this Unwired account", in: first).exists)
    first.buttons["Link Google Sign-In"].click()
    let linked = "Sign in with Apple or Google to open this Unwired account."
    XCTAssertTrue(text(linked, in: first).waitForExistence(timeout: 15))
    XCTAssertFalse(first.buttons["Link Google Sign-In"].exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(text(linked, in: app.windows["Inbox 1"]).waitForExistence(timeout: 15))
  }

  // Keep language changes, window menus, and relaunch in one native journey, through the sign-in
  // page's Language pop-up, whose AppKit menu owns the choice (#1196).
  // swiftlint:disable:next function_body_length
  func testLanguagePreferenceAcrossWindowsAndRelaunch() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(
      url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    // Every launch starts from one new window, whatever AppKit saved at the previous quit. Unlike
    // the other journeys, it leaves `interfaceLanguage` unpinned: the pop-up's choice must apply.
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    // Past Welcome, the sign-in page of `window` ends with the Language pop-up.
    func language(in window: XCUIElement) -> XCUIElement {
      XCTAssertTrue(window.buttons["Continue"].waitForExistence(timeout: 30))
      window.buttons["Continue"].click()
      let popUp = window.popUpButtons["Language"]
      XCTAssertTrue(popUp.waitForExistence(timeout: 15))
      return popUp
    }
    func choose(_ title: String, from popUp: XCUIElement) {
      popUp.click()
      let item = app.menuItems[title]
      XCTAssertTrue(item.waitForExistence(timeout: 5))
      item.click()
      waitUntil { popUp.value as? String == title }
    }
    let first = app.windows["Inbox 1"]
    let firstLanguage = language(in: first)
    choose("English", from: firstLanguage)
    app.typeKey("n", modifierFlags: [.command, .option])
    let second = app.windows["Inbox 2"]
    let secondLanguage = language(in: second)
    XCTAssertEqual(secondLanguage.value as? String, "English")
    for preference in ["System Default", "English", "System Default", "English"] {
      choose(preference, from: secondLanguage)
      waitUntil { firstLanguage.value as? String == preference }
      assertWindowMenu(app, titles: ["Inbox 1", "Inbox 2"])
    }
    app.menuBars.menuBarItems["Window"].click()
    app.menuItems["Inbox 2"].click()
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(second.waitForNonExistence(timeout: 10))
    assertWindowMenu(app, titles: ["Inbox 1"])
    app.terminate()
    app.launch()
    let relaunched = language(in: first)
    XCTAssertEqual(relaunched.value as? String, "English")
    choose("System Default", from: relaunched)
    app.menuBars.menuBarItems["File"].click()
    XCTAssertTrue(app.menuItems["New Window"].exists)
    app.typeKey(.escape, modifierFlags: [])
  }

  private func assertWindowMenu(
    _ app: XCUIApplication, titles: [String], file: StaticString = #filePath, line: UInt = #line
  ) {
    app.menuBars.menuBarItems["Window"].click()
    // A window's entry carries its name as the title, with no label, and its action as the
    // identifier.
    let entries = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Inbox "))
    XCTAssertEqual(entries.count, titles.count, file: file, line: line)
    for title in titles {
      let entry = entries.matching(NSPredicate(format: "title == %@", title))
      XCTAssertEqual(entry.count, 1, file: file, line: line)
    }
    XCTAssertFalse(app.menuItems["Merge All Windows"].exists, file: file, line: line)
    app.typeKey(.escape, modifierFlags: [])
  }

  // Keep the existing single-process lifecycle journey together.
  // swiftlint:disable:next function_body_length
  func testIndependentWindowsCloseReopenAndQuit() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    let appURL = URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"]))
    // The sandboxed session writes the runner-created record; this external probe only reads it.
    let evidence = appURL.deletingLastPathComponent().appendingPathComponent("lifecycle.jsonl")
    addTeardownBlock { [self] in
      if let data = try? Data(contentsOf: evidence) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Lifecycle events"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }
    let app = XCUIApplication(url: appURL)
    // Every launch starts from one new window, whatever AppKit saved at the previous quit.
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en"]
    app.launchEnvironment["UNWIRED_LIFECYCLE_PATH"] = evidence.path
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }

    // The reader names its sender as one text, "Maya Chen, maya@example.com".
    func address(_ window: XCUIElement, _ value: String) -> XCUIElement {
      window.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", ", " + value)).firstMatch
    }
    let first = app.windows["Inbox 1"]
    XCTAssertTrue(first.waitForExistence(timeout: 30))
    if environment["UNWIRED_TEST_SCENARIO"] == "registration-link" {
      linkJourney(app, first: first)
      return
    }
    if environment["UNWIRED_TEST_SCENARIO"] == "registration-enrollment" {
      enrollmentJourney(app, first: first)
      return
    }
    if environment["UNWIRED_TEST_SCENARIO"] == "registration-recovery" {
      recoveryJourney(app, first: first)
      return
    }
    if environment["UNWIRED_TEST_SCENARIO"] == "registration-revocation" {
      revocationJourney(app, first: first)
      return
    }
    if environment["UNWIRED_TEST_SCENARIO"] == "registration-revoked" {
      revokedJourney(app, first: first)
      return
    }
    if environment["UNWIRED_TEST_SCENARIO"] == "registration-removal" {
      removalJourney(app, first: first)
      return
    }
    if environment["UNWIRED_TEST_SCENARIO"] == "registration-draft-editor" {
      // XCTest's default ten minutes stays below the runner's maximum otherwise.
      executionTimeAllowance = 900
      draftEditorJourney(app, first: first)
      return
    }
    if environment["UNWIRED_TEST_SCENARIO"] == "registration-invitation" {
      invitationJourney(app, first: first)
      return
    }
    if environment["UNWIRED_TEST_SCENARIO"]?.hasPrefix("registration-") == true {
      registrationJourney(
        app, first: first, apple: environment["UNWIRED_TEST_SCENARIO"] == "registration-apple")
      return
    }
    let maya = first.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Maya Chen"))
      .firstMatch
    XCTAssertTrue(maya.waitForExistence(timeout: 20))
    maya.click()
    XCTAssertTrue(address(first, "maya@example.com").waitForExistence(timeout: 10))
    // A summary runs only when asked, through the packaged assistance bridge, whose synthetic
    // model answers in this build.
    first.buttons["Summarize this message"].click()
    let summary = NSPredicate(format: "value == %@", "Synthetic summary of local mail.")
    XCTAssertTrue(first.textViews.matching(summary).firstMatch.waitForExistence(timeout: 10))
    // Translate is one click into the app language; its arrow chooses another, which it names.
    func shows(_ text: String) -> Bool {
      first.textViews.matching(NSPredicate(format: "value == %@", text)).firstMatch
        .waitForExistence(timeout: 10)
    }
    first.buttons["Translate this message"].click()
    XCTAssertTrue(text("Translation into English · On device", in: first).waitForExistence(timeout: 10))
    XCTAssertTrue(shows("Synthetic translation of local mail."))
    first.buttons["Translate Into"].click()
    XCTAssertFalse(app.menuItems["Translate into English"].exists)
    app.menuItems["Translate into German"].click()
    XCTAssertTrue(text("Translation into German · On device", in: first).waitForExistence(timeout: 10))
    XCTAssertTrue(first.buttons["Translate into German"].exists)
    first.buttons["Show the original message and forget the translation"].click()
    XCTAssertTrue(first.buttons["Translate Into"].waitForExistence(timeout: 10))
    app.typeKey("n", modifierFlags: [.command, .option])
    let second = app.windows["Inbox 2"]
    XCTAssertTrue(second.waitForExistence(timeout: 10))
    let oliver = second.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Oliver Park"))
      .firstMatch
    XCTAssertTrue(oliver.waitForExistence(timeout: 10))
    oliver.click()
    XCTAssertTrue(address(second, "oliver@example.com").waitForExistence(timeout: 10))
    XCTAssertTrue(address(first, "maya@example.com").exists)
    // Opening it read it, in both windows.
    XCTAssertTrue(second.buttons["Mark as Unread"].waitForExistence(timeout: 10))
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
    app.menuBars.menuBarItems["Unwired Mail"].click()
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
    XCTAssertTrue(app.windows["Inbox 1"].buttons["Mark as Unread"].waitForExistence(timeout: 10))

  }

  // #626: warm encrypted-cache timings on this Mac for the local-mail budgets, over the
  // registration-performance build's Gmail and Microsoft Inboxes and their 250 added Threads.
  // A click sample runs from the release the app recorded to the first accessibility query that
  // finds the rendered result; a launch sample from the launch request. Both include XCUITest's
  // queries, so they are upper bounds. A key or format bar sample runs from the key press or
  // button release to the body edit showing its result, all recorded by the app. The app also
  // records each main-thread stall of 100 ms or longer, which the samples' windows attribute.
  // swiftlint:disable:next function_body_length
  func testWarmCachePerformance() throws {
    continueAfterFailure = false
    executionTimeAllowance = 1200
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let appURL = URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"]))
    let evidence = appURL.deletingLastPathComponent().appendingPathComponent("lifecycle.jsonl")
    let app = XCUIApplication(url: appURL)
    // Every launch starts from one new window, whatever AppKit saved at the previous quit.
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en"]
    app.launchEnvironment["UNWIRED_LIFECYCLE_PATH"] = evidence.path
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    func row(_ subject: String) -> XCUIElement {
      window.buttons.matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
    }
    func inbox(_ address: String) -> XCUIElement { window.buttons["Inbox. In \(address)"] }
    // Each mailbox's Inbox, its own messages the window shows, and the other mailbox's.
    let samples = [
      ("casey@example.invalid", "Outlook", "Gmail"), ("other@example.invalid", "Gmail", "Outlook"),
    ]
      .map { address, own, other in
        (address, (1...5).map { String(format: "\(own) update %03d", $0) }, "\(other) update")
      }
    func show(_ address: String, _ messages: [String], without other: String) {
      inbox(address).click()
      _ = until(row(messages[0]), from: uptime(), without: row(other))
    }
    // Opening each sample message once saves its body in the encrypted cache.
    for (address, messages, other) in samples {
      show(address, messages, without: other)
      for message in messages {
        row(message).click()
        XCTAssertTrue(body("\(message) body.", in: window).waitForExistence(timeout: 15))
      }
    }
    window.buttons["All Inboxes"].click()

    var groups: [PerformanceGroup] = []
    func measure(
      _ name: String, budget: Double, count: Int = 20, _ sample: (Int) -> (Double, Double)
    ) {
      let before = firstQueryResults
      let windows = (0..<count).map(sample)
      groups.append((name, budget, windows, firstQueryResults - before, []))
    }
    // Each relaunch reopens the encrypted cache of both mailboxes.
    measure("launch-to-first-list", budget: 1000, count: 10) { _ in
      app.terminate()
      let start = uptime()
      app.launch()
      return (start, until(row("Jordan Lee"), from: start, and: window.buttons["All Inboxes"]))
    }
    // All Inboxes aggregates every listed Thread of both mailboxes.
    let views = [
      (inbox("casey@example.invalid"), "Outlook update 001", "Gmail update 001"),
      (inbox("other@example.invalid"), "Gmail update 001", "Outlook update 001"),
      (window.buttons["All Inboxes"], "Outlook update 001", "Rowan Hale"),
    ]
    measure("cached-mailbox-switch", budget: 200, count: 21) { index in
      let (view, shown, required) = views[index % views.count]
      let start = uptime()
      view.click()
      // A mailbox's own Inbox no longer shows the other mailbox; All Inboxes shows both.
      return index % views.count == 2
        ? (start, until(row(shown), from: start, and: row(required)))
        : (start, until(row(shown), from: start, without: row(required)))
    }
    // Changing selection releases the previous reader's body; each open reads the encrypted cache.
    for (address, messages, other) in samples {
      show(address, messages, without: other)
      measure("cached-body \(address)", budget: 200, count: 10) { index in
        let message = messages[index % messages.count]
        let start = uptime()
        row(message).click()
        return (start, until(body("\(message) body.", in: window), from: start))
      }
    }
    // Each composer sample ends with Close; closing a composer used to abort this host (#1174).
    let subject = window.textFields["Subject"]
    func close() {
      window.buttons["Close"].click()
      XCTAssertTrue(subject.waitForNonExistence(timeout: 10))
    }
    measure("empty-composer", budget: 300, count: 10) { _ in
      let start = uptime()
      window.buttons["New Message"].click()
      let end = until(subject, from: start)
      close()
      return (start, end)
    }
    window.buttons["New Message"].click()
    XCTAssertTrue(subject.waitForExistence(timeout: 10))
    subject.click()
    subject.typeText("Warm composer")
    // Close asks to save the edit, and the Inbox lists the Draft once Save stores it (#1609).
    window.buttons["Close"].click()
    let save = window.sheets.firstMatch.buttons["Save"]
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    save.click()
    XCTAssertTrue(subject.waitForNonExistence(timeout: 10))
    XCTAssertTrue(row("Draft. Warm composer").waitForExistence(timeout: 10))
    measure("warm-composer", budget: 200, count: 10) { _ in
      let start = uptime()
      row("Warm composer").click()
      let end = until(
        window.textFields.matching(NSPredicate(format: "value == %@", "Warm composer")).firstMatch,
        from: start)
      close()
      return (start, end)
    }
    window.buttons["New Message"].click()
    let message = window.textViews.matching(NSPredicate(format: "label == %@", "Message")).firstMatch
    XCTAssertTrue(message.waitForExistence(timeout: 10))
    groups += typingSamples(app, window: window, body: message)
    let overhead = queryOverhead(window.buttons["New Message"])
    // The running app keeps appending probe records; read them only after it quits.
    app.terminate()
    try reportPerformance(groups, evidence: evidence, overhead: overhead)
  }

  // #2962: the performance journey's typing and formatting feedback in either composer, from the
  // same empty new message: the current composer in a registration-performance build, the Draft
  // editor page in a registration-draft-editor build. The page's injected probe writes its edits
  // and their rendering updates as the text view probe does (page-typing-probe.ts).
  func testTypingResponse() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    let page = environment["UNWIRED_TEST_SCENARIO"] == "registration-draft-editor"
    if !page { XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance") }
    let appURL = URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"]))
    let evidence = appURL.deletingLastPathComponent().appendingPathComponent("lifecycle.jsonl")
    let app = XCUIApplication(url: appURL)
    // With the system's inline predictions on, the three synthesized key presses after "feedb"
    // reached the page about 5 s late and never reached the app’s key monitor (#2966). Both
    // composers run with them off, so they type the same way.
    app.launchArguments += [
      "-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en",
      "-NSAutomaticInlinePredictionEnabled", "NO",
    ]
    app.launchEnvironment["UNWIRED_LIFECYCLE_PATH"] = evidence.path
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    XCTAssertTrue(window.waitForExistence(timeout: 30))
    if page { draftEditorSignIn(window) } else { performanceSetup(app, window: window) }
    window.buttons["New Message"].click()
    let body = page
      ? window.webViews.textViews["Message body"]
      : window.textViews.matching(NSPredicate(format: "label == %@", "Message")).firstMatch
    XCTAssertTrue(body.waitForExistence(timeout: 15))
    // The page's toolbar appears once the page is ready and moves the page down.
    XCTAssertTrue(window.buttons["Undo"].waitForExistence(timeout: 30))
    let groups = typingSamples(app, window: window, body: body)
    let overhead = queryOverhead(window.buttons["New Message"])
    // The running app keeps appending probe records; read them only after it quits.
    app.terminate()
    try reportPerformance(
      groups, evidence: evidence, overhead: overhead,
      name: page ? "Typing response, Draft editor page" : "Typing response, current composer")
  }

  // #2955: opening a new message and a saved Draft, in the current composer
  // (registration-performance) or the Draft editor page (registration-draft-editor). A sample runs
  // from the click release the app records to the first accessibility query that finds the body
  // ready: the body and the format bar's Undo, which the page shows once it is ready, and for the
  // Draft the body's saved paragraph. Samples include XCUITest's queries, so they are upper bounds.
  func testComposerOpening() throws {
    continueAfterFailure = false
    executionTimeAllowance = 600
    let environment = ProcessInfo.processInfo.environment
    let page = environment["UNWIRED_TEST_SCENARIO"] == "registration-draft-editor"
    XCTAssertTrue(page || environment["UNWIRED_TEST_SCENARIO"] == "registration-performance")
    let appURL = URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"]))
    let evidence = appURL.deletingLastPathComponent().appendingPathComponent("lifecycle.jsonl")
    let app = XCUIApplication(url: appURL)
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en"]
    app.launchEnvironment["UNWIRED_LIFECYCLE_PATH"] = evidence.path
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    if page {
      XCTAssertTrue(window.waitForExistence(timeout: 30))
      draftEditorSignIn(window)
    } else {
      performanceSetup(app, window: window)
      // The Draft's row is listed with both mailboxes' Threads.
      window.buttons["All Inboxes"].click()
    }
    let body =
      page
      ? window.webViews.textViews["Message body"]
      : window.textViews.matching(NSPredicate(format: "label == %@", "Message")).firstMatch
    let undo = window.buttons["Undo"]
    let paragraph = "Warm composer paragraph"
    // The current composer's body is labelled Message only while it is empty.
    let saved =
      page
      ? webText(paragraph, in: window)
      : window.textViews.matching(NSPredicate(format: "value CONTAINS %@", paragraph)).firstMatch
    // The page hides Undo when Close begins; the composer is gone once Subject is.
    let subject = window.textFields["Subject"]
    func close() {
      window.buttons["Close"].click()
      XCTAssertTrue(subject.waitForNonExistence(timeout: 10))
      XCTAssertFalse(undo.exists)
    }

    var groups: [PerformanceGroup] = []
    func measure(_ name: String, budget: Double, _ open: () -> Void, ready: XCUIElement) {
      let before = firstQueryResults
      let windows = (0..<10).map { _ -> (start: Double, end: Double) in
        let start = uptime()
        open()
        let end = until(ready, from: start, and: undo)
        close()
        return (start, end)
      }
      groups.append((name, budget, windows, firstQueryResults - before, []))
    }
    XCTAssertFalse(subject.exists)
    measure("empty-composer", budget: 300, { window.buttons["New Message"].click() }, ready: body)
    // Close asks to save the edit, and the Inbox lists the Draft once Save stores it.
    window.buttons["New Message"].click()
    XCTAssertTrue(undo.waitForExistence(timeout: 30))
    subject.click()
    subject.typeText("Warm composer")
    body.click()
    body.typeText(paragraph)
    XCTAssertTrue(saved.waitForExistence(timeout: 10))
    window.buttons["Close"].click()
    let save = window.sheets.firstMatch.buttons["Save"]
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    save.click()
    XCTAssertTrue(subject.waitForNonExistence(timeout: 10))
    let draft = window.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "Draft. Warm composer")
    ).firstMatch
    XCTAssertTrue(draft.waitForExistence(timeout: 10))
    measure("warm-composer", budget: 200, { draft.click() }, ready: saved)
    let overhead = queryOverhead(window.buttons["New Message"])
    // The running app keeps appending probe records; read them only after it quits.
    app.terminate()
    try reportPerformance(
      groups, evidence: evidence, overhead: overhead, composer: page ? "page" : "current")
  }

  // #626: the core mail loop by keyboard where the Mac app offers a keyboard path, over the
  // registration-performance build's Gmail and Microsoft mailboxes, with XCTest's accessibility
  // audit of each screen. Opening a row, placing the caret in a new reply, sending and moving
  // between controls with Tab still need the pointer (#849).
  // Every audit issue is printed, and one outside knownAccessibilityGap fails the journey.
  // The journey sets its appearance, so the desktop's does not change what the audits measure.
  func testKeyboardAndAccessibility() throws {
    try keyboardAndAccessibility(appearance: "Light")
  }

  func testKeyboardAndAccessibilityDark() throws {
    try keyboardAndAccessibility(appearance: "Dark")
  }

  // #1923: an IMAP server that marks no Spam or Trash folder keeps its connection out of All Mail
  // until both are chosen, in a sheet from the All Mail notice or from Settings › Email Accounts.
  func testImapSpamAndTrashFolders() throws {
    try imapSpamAndTrashFolders(appearance: "Light")
  }

  func testImapSpamAndTrashFoldersDark() throws {
    try imapSpamAndTrashFolders(appearance: "Dark")
  }

  // swiftlint:disable:next function_body_length
  private func imapSpamAndTrashFolders(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    app.launchArguments += [
      "-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en",
      "-UnwiredAppearance", appearance.lowercased(),
    ]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    let settings = app.windows["settings-window"]
    let address = "pat@example.invalid"
    let notice = "\(address) isn’t included"
    func row(_ subject: String) -> XCUIElement {
      window.buttons.matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
    }
    func choose(_ popUp: XCUIElement, _ folder: String) {
      popUp.click()
      app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", folder)).firstMatch.click()
      waitUntil { popUp.value as? String == folder }
    }
    func attach(_ element: XCUIElement, _ name: String) {
      let attachment = XCTAttachment(screenshot: element.screenshot())
      attachment.name = "\(name) (\(appearance))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    func openSettings() {
      app.typeKey(",", modifierFlags: .command)
      XCTAssertTrue(settings.waitForExistence(timeout: 15))
      settings.buttons["Email Accounts"].click()
    }

    // Settings › Email Accounts connects the synthetic IMAP server, which marks only Sent.
    openSettings()
    settings.buttons["Add an IMAP Mailbox"].click()
    settings.buttons["Other IMAP Account"].click()
    // #2176: an address at a catalogued provider fills in its servers and says so; clearing it
    // empties them again for manual entry.
    let email = settings.textFields["Email address"]
    XCTAssertTrue(email.waitForExistence(timeout: 15))
    email.click()
    email.typeText("pat@seznam.cz")
    let found = text("Found server settings for seznam.cz.", in: settings)
    XCTAssertTrue(found.waitForExistence(timeout: 15))
    XCTAssertEqual(settings.textFields["IMAP server"].value as? String, "imap.seznam.cz")
    XCTAssertEqual(settings.textFields["SMTP server"].value as? String, "smtp.seznam.cz")
    // The note is below the fold of the Settings window.
    let page = settings.scrollViews.firstMatch
    page.scroll(byDeltaX: 0, deltaY: -400)
    attach(settings, "Catalogued provider found")
    page.scroll(byDeltaX: 0, deltaY: 400)
    email.typeKey("a", modifierFlags: .command)
    email.typeKey(.delete, modifierFlags: [])
    XCTAssertTrue(found.waitForNonExistence(timeout: 15))
    XCTAssertEqual(settings.textFields["IMAP server"].value as? String, "")
    for (label, value) in [
      ("Email address", address), ("User name", "pat"), ("IMAP server", "imap.example.invalid"),
      ("SMTP server", "smtp.example.invalid"),
    ] {
      let field = settings.textFields[label]
      XCTAssertTrue(field.waitForExistence(timeout: 15))
      field.click()
      field.typeText(value)
    }
    let password = settings.secureTextFields["Password"]
    password.click()
    password.typeText("synthetic")
    // Connect appears once the password reaches the form (#1924 kept it out on macOS 27).
    XCTAssertTrue(settings.buttons["Connect"].waitForExistence(timeout: 15))
    settings.buttons["Connect"].click()
    XCTAssertTrue(settings.buttons["Choose Folders… \(address)"].waitForExistence(timeout: 60))
    XCTAssertTrue(text("Spam and Trash not chosen · not in All Mail", in: settings).exists)
    attach(settings, "Settings before choosing")
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(settings.waitForNonExistence(timeout: 10))

    // All Mail leaves the connection out and says so; Choose Folders… opens the choice as a sheet,
    // which Save stays disabled in until both folders are chosen, and Escape cancels.
    let allMail = window.buttons["All Mail. In All Mailboxes"]
    XCTAssertTrue(allMail.waitForExistence(timeout: 30))
    allMail.click()
    XCTAssertTrue(text(notice, in: window).waitForExistence(timeout: 30))
    XCTAssertFalse(row("Welcome to IMAP").exists)
    attach(window, "All Mail notice")
    try audit(app, "All Mail notice")
    let sheet = window.sheets.firstMatch
    window.buttons["Choose Folders…"].click()
    XCTAssertTrue(sheet.waitForExistence(timeout: 15))
    XCTAssertTrue(text("Choose Spam and Trash Folders", in: sheet).exists)
    let spam = sheet.popUpButtons["Spam"]
    let trash = sheet.popUpButtons["Trash"]
    XCTAssertEqual(spam.value as? String, "Choose a Folder")
    XCTAssertEqual(trash.value as? String, "Choose a Folder")
    XCTAssertFalse(sheet.buttons["Save"].isEnabled)
    try audit(app, "Choose Spam and Trash Folders")
    attach(sheet, "Choose sheet")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
    XCTAssertTrue(text(notice, in: window).exists)

    // Return saves both choices: All Mail then lists the Inbox message but not Spam's or Trash's.
    window.buttons["Choose Folders…"].click()
    XCTAssertTrue(sheet.waitForExistence(timeout: 15))
    choose(spam, "Bulk Mail")
    choose(trash, "Deleted Messages")
    XCTAssertTrue(sheet.buttons["Save"].isEnabled)
    attach(sheet, "Choose sheet ready to save")
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 30))
    XCTAssertTrue(row("Welcome to IMAP").waitForExistence(timeout: 30))
    waitUntil {
      !self.text(notice, in: window).exists && !row("Unwanted offer").exists
        && !row("Old receipt").exists
    }
    attach(window, "All Mail with the connection")

    // Settings shows the chosen folders; Change… opens them pre-filled, and Escape keeps them.
    openSettings()
    let chosen = "Spam: Bulk Mail · Trash: Deleted Messages · chosen by you"
    XCTAssertTrue(text(chosen, in: settings).waitForExistence(timeout: 15))
    attach(settings, "Settings after choosing")
    try audit(app, "Email Accounts")
    settings.buttons["Change… \(address)"].click()
    let change = settings.sheets.firstMatch
    XCTAssertTrue(change.waitForExistence(timeout: 15))
    XCTAssertEqual(change.popUpButtons["Spam"].value as? String, "Bulk Mail")
    XCTAssertEqual(change.popUpButtons["Trash"].value as? String, "Deleted Messages")
    try audit(app, "Spam and Trash Folders")
    attach(change, "Change sheet")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(change.waitForNonExistence(timeout: 10))
    XCTAssertTrue(text(chosen, in: settings).exists)
  }

  // #2235: a Mailbox Connection's problem stays beside its sidebar header, expanded and collapsed.
  func testSidebarConnectionProblem() throws {
    try sidebarConnectionProblem(appearance: "Light")
  }

  func testSidebarConnectionProblemDark() throws {
    try sidebarConnectionProblem(appearance: "Dark")
  }

  private func sidebarConnectionProblem(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    app.launchArguments += [
      "-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en",
      "-UnwiredAppearance", appearance.lowercased(),
    ]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    func attach(_ name: String) {
      let attachment = XCTAttachment(screenshot: window.screenshot())
      attachment.name = "\(name) (\(appearance))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    // The synthetic IMAP server accepts this password, then cannot be reached.
    let address = "pat@example.invalid"
    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["settings-window"]
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    settings.buttons["Email Accounts"].click()
    settings.buttons["Add an IMAP Mailbox"].click()
    settings.buttons["Other IMAP Account"].click()
    for (label, value) in [
      ("Email address", address), ("User name", "pat"), ("IMAP server", "imap.example.invalid"),
      ("SMTP server", "smtp.example.invalid"),
    ] {
      let field = settings.textFields[label]
      XCTAssertTrue(field.waitForExistence(timeout: 15))
      field.click()
      field.typeText(value)
    }
    let password = settings.secureTextFields["Password"]
    password.click()
    password.typeText("unreachable")
    XCTAssertTrue(settings.buttons["Connect"].waitForExistence(timeout: 15))
    settings.buttons["Connect"].click()
    XCTAssertTrue(settings.buttons["Choose Folders… \(address)"].waitForExistence(timeout: 60))
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(settings.waitForNonExistence(timeout: 10))

    // The header names the problem with its title, expanded and collapsed. The connection was never
    // listed, so its section has no folder rows to keep.
    let problem = "The mail server could not be reached"
    let header = window.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "IMAP · \(address)")
    ).firstMatch
    XCTAssertTrue(header.waitForExistence(timeout: 30))
    waitUntil { header.label.contains(problem) }
    XCTAssertEqual(header.value as? String, "expanded")
    // The new section is last; scroll the sidebar to it so the captures show the header.
    header.scroll(byDeltaX: 0, deltaY: -600)
    attach("Expanded with a problem")
    try audit(app, "Sidebar with a problem")
    header.click()
    waitUntil { header.value as? String == "Collapsed" }
    XCTAssertTrue(header.label.contains(problem))
    attach("Collapsed with a problem")
    header.click()
    waitUntil { header.value as? String == "expanded" }
    XCTAssertTrue(header.label.contains(problem))
  }

  // #2738: Gmail's timed usage limit is said in the sidebar, and Sync Status keeps Try Again
  // unavailable until Gmail's time.
  func testGmailPaused() throws {
    try gmailPaused(appearance: "Light")
  }

  func testGmailPausedDark() throws {
    try gmailPaused(appearance: "Dark")
  }

  private func gmailPaused(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-sync-status-paused")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    // Settings › Appearance for this launch, which the app applies whatever the Mac's appearance.
    app.launchArguments += [
      "-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en",
      "-UnwiredAppearance", appearance.lowercased(),
    ]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    func attach(_ name: String) {
      let attachment = XCTAttachment(screenshot: window.screenshot())
      attachment.name = "\(name) (\(appearance))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    // The mock's fixed retry time, in the app's interface language and this Mac's time zone.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en")
    formatter.timeStyle = .short
    // Foundation and Intl can use different spaces before AM or PM.
    func normalized(_ label: String) -> String {
      label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    let retryTime = normalized(
      formatter.string(from: try XCTUnwrap(ISO8601DateFormatter().date(from: "2099-07-02T12:20:00Z"))))

    XCTAssertTrue(window.buttons["Continue"].waitForExistence(timeout: 30))
    window.buttons["Continue"].click()
    XCTAssertTrue(window.buttons["Sign in with Google"].waitForExistence(timeout: 20))
    window.buttons["Sign in with Google"].click()
    XCTAssertTrue(recoveryKey(in: window).waitForExistence(timeout: 15))
    let presented = recoveryKey(in: window).value as? String ?? ""
    window.buttons["Choose Another Google Mailbox"].click()
    XCTAssertTrue(text("connected on this device", in: window).waitForExistence(timeout: 15))
    let entry = window.textFields["Last four characters"]
    entry.click()
    entry.typeText(String(presented.suffix(4)))
    window.buttons["Confirm Recovery Key"].click()
    // The first history page stays listed while Gmail pauses the rest.
    XCTAssertTrue(
      window.buttons["Unread. Rowan Hale. Garden plans for spring"].waitForExistence(timeout: 20))
    let paused = window.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Gmail paused")
    ).firstMatch
    XCTAssertTrue(paused.waitForExistence(timeout: 30))
    print("Expected retry time \(retryTime). Sidebar shows \(paused.label).")
    XCTAssertEqual(normalized(paused.label), "Gmail paused, until \(retryTime)")
    attach("Gmail paused")
    try audit(app, "Gmail paused")

    paused.click()
    let title = text("Sync Status", in: window)
    XCTAssertTrue(title.waitForExistence(timeout: 10))
    // The popover opens beside the sidebar, not over it.
    XCTAssertGreaterThan(title.frame.minX, paused.frame.maxX)
    let available = window.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Available at ")
    ).firstMatch
    XCTAssertTrue(available.waitForExistence(timeout: 10))
    XCTAssertEqual(normalized(available.label), "Available at \(retryTime)")
    let tryAgain = window.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Try Again for Gmail")
    ).firstMatch
    XCTAssertTrue(tryAgain.exists)
    XCTAssertFalse(tryAgain.isEnabled)
    let footer = text(
      "Mail already on this Mac stays readable. Sending has its own status in Outbox.", in: window)
    XCTAssertTrue(footer.exists)
    // Level with the warning, the popover stays within the window.
    XCTAssertLessThanOrEqual(footer.frame.maxY, window.frame.maxY)
    attach("Paused Sync Status popover")
    try audit(app, "Paused Sync Status")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(available.waitForNonExistence(timeout: 10))
  }

  // #2593: Edit Favorites hides a row and reorders two, and the sidebar keeps them after a relaunch.
  func testEditFavorites() throws {
    try editFavorites(appearance: "Light")
  }

  func testEditFavoritesDark() throws {
    try editFavorites(appearance: "Dark")
  }

  private func editFavorites(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    app.launchArguments += [
      "-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en",
      "-UnwiredAppearance", appearance.lowercased(),
    ]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    func attach(_ name: String) {
      let attachment = XCTAttachment(screenshot: window.screenshot())
      attachment.name = "\(name) (\(appearance))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    // The sidebar's Favorites rows from top to bottom.
    func favorites() -> [String] {
      let names = ["All Inboxes", "Sent", "Archive", "All Mail", "Spam", "Trash"]
      return window.buttons.allElementsBoundByIndex
        .map { ($0.label.replacingOccurrences(of: ". In All Mailboxes", with: ""), $0.frame.minY) }
        .filter { names.contains($0.0) }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    let header = window.buttons["Favorites"]
    XCTAssertTrue(header.waitForExistence(timeout: 15))
    header.rightClick()
    XCTAssertTrue(app.menuItems["Edit Favorites…"].waitForExistence(timeout: 5))
    app.menuItems["Edit Favorites…"].click()
    let done = window.buttons["Done"]
    XCTAssertTrue(done.waitForExistence(timeout: 10))
    let spam = window.buttons["Spam"]
    XCTAssertEqual(spam.value as? String, "Shown")
    attach("Edit Favorites")
    try audit(app, "Edit Favorites")
    spam.click()
    waitUntil { spam.value as? String == "Hidden" }
    // Trash's handle, at the row's trailing end, drags it two rows up, above Spam and All Mail.
    let trash = window.buttons["Trash"]
    let allMail = window.buttons["All Mail"]
    let handle = trash.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
      .withOffset(CGVector(dx: -12, dy: 0))
    handle.click(forDuration: 0.3, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: -56)))
    waitUntil { trash.frame.minY < allMail.frame.minY }
    attach("Spam hidden, Trash above All Mail")
    done.click()
    XCTAssertTrue(done.waitForNonExistence(timeout: 10))
    let edited = ["All Inboxes", "Sent", "Archive", "Trash", "All Mail"]
    waitUntil { favorites() == edited }
    attach("Edited Favorites")

    app.typeKey("q", modifierFlags: .command)
    waitUntil { app.state == .notRunning }
    app.launch()
    XCTAssertTrue(window.buttons["All Inboxes"].waitForExistence(timeout: 45))
    waitUntil { favorites() == edited }
    attach("Edited Favorites after a relaunch")
  }

  // #1901: moving the Microsoft mailbox into a Work Mail Profile takes its messages, Search
  // results and Drafts to Work's window only, beside a Primary Profile window that keeps the
  // Gmail mailbox; moving it back restores them to the Primary Profile.
  // swiftlint:disable:next function_body_length
  func testMailProfileIsolation() throws {
    continueAfterFailure = false
    // Two Inbox windows at their 760-point minimum width need a display at least twice as wide.
    let half = try XCTUnwrap(NSScreen.main?.visibleFrame.width) / 2
    try XCTSkipIf(half - 20 < 760, "The display is too narrow for two Inbox windows side by side")
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let primary = app.windows["Inbox 1"]
    performanceSetup(app, window: primary)
    let settings = app.windows["settings-window"]
    let microsoft = ("casey@example.invalid", "Outlook update")
    let gmail = ("other@example.invalid", "Gmail update")
    func row(_ window: XCUIElement, _ label: String) -> XCUIElement {
      window.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }
    let draft = NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Draft.", "Work agenda")
    // A window lists its Profile's mailbox and messages and none of the other mailbox's.
    func lists(_ window: XCUIElement, _ own: (String, String), without other: (String, String)) {
      XCTAssertTrue(window.buttons["Inbox. In \(own.0)"].waitForExistence(timeout: 30))
      XCTAssertTrue(row(window, own.1).waitForExistence(timeout: 30))
      waitUntil { !window.buttons["Inbox. In \(other.0)"].exists && !row(window, other.1).exists }
    }
    // Search Mail runs in the key window; an empty query shows the whole list again.
    func search(_ window: XCUIElement, _ query: String) {
      window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).click()
      runCommand("Search Mail", in: app)
      let field = window.textFields["Search senders and subjects"]
      waitForFocus(field)
      app.typeKey("a", modifierFlags: .command)
      if query.isEmpty { app.typeKey(.delete, modifierFlags: []) } else { app.typeText(query) }
      waitUntil { field.value as? String == query }
    }
    // Settings › Mail Profiles moves the Microsoft mailbox out of the selected Profile.
    func move(from source: String, to target: String) {
      settings.buttons[source].click()
      let popUp = settings.popUpButtons["Profile for \(microsoft.0)"]
      XCTAssertTrue(popUp.waitForExistence(timeout: 15))
      popUp.click()
      app.menuItems[target].click()
      XCTAssertTrue(popUp.waitForNonExistence(timeout: 30))
    }
    func attach(_ window: XCUIElement, _ name: String) {
      let attachment = XCTAttachment(screenshot: window.screenshot())
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    settings.buttons["Profiles"].click()
    settings.buttons["Add Profile…"].click()
    let sheet = settings.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 10))
    sheet.textFields.firstMatch.click()
    sheet.typeText("Work")
    sheet.buttons["Create"].click()
    XCTAssertTrue(settings.buttons["Work"].waitForExistence(timeout: 15))
    move(from: "Primary Profile", to: "Work")
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(settings.waitForNonExistence(timeout: 10))
    lists(primary, gmail, without: microsoft)

    // A second window opens the Startup Profile, and its switcher's menu switches it to Work.
    app.typeKey("n", modifierFlags: [.command, .option])
    let work = app.windows["Inbox 2"]
    let switcher = work.buttons["Profile, Primary Profile"]
    XCTAssertTrue(switcher.waitForExistence(timeout: 15))
    switcher.click()
    // Each Profile Menu item adds its connections and unread count to the Profile's name.
    app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Work, Microsoft")).firstMatch.click()
    XCTAssertTrue(work.buttons["Profile, Work"].waitForExistence(timeout: 15))
    // Each window takes its own half of the screen, so both stay in view side by side. The new
    // window starts in front, offset below the first's title bar: narrow it and move it right,
    // then drag the first by its uncovered title bar to the left and narrow it.
    func narrow(_ window: XCUIElement) {
      let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        .withOffset(CGVector(dx: -2, dy: -2))
      corner.click(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: half - 20 - window.frame.width, dy: 0)))
    }
    func place(_ window: XCUIElement, _ targetX: CGFloat, from grabX: CGFloat) {
      let top = window.coordinate(withNormalizedOffset: CGVector(dx: grabX, dy: 0.01))
      top.click(forDuration: 0.2, thenDragTo: top.withOffset(CGVector(dx: targetX - window.frame.minX, dy: 0)))
    }
    narrow(work)
    place(work, half, from: 0.9)
    place(primary, 10, from: 0.1)
    narrow(primary)
    XCTAssertLessThanOrEqual(primary.frame.maxX, work.frame.minX)
    lists(work, microsoft, without: gmail)
    lists(primary, gmail, without: microsoft)
    for (window, own, other, name) in [
      (work, microsoft, gmail, "Work window"), (primary, gmail, microsoft, "Primary Profile window"),
    ] {
      search(window, "update 003")
      XCTAssertTrue(row(window, "\(own.1) 003").waitForExistence(timeout: 15))
      waitUntil { !row(window, "\(other.1) 003").exists }
      search(window, "")
      attach(window, name)
    }

    work.buttons["New Message"].click()
    let subject = work.textFields["Subject"]
    XCTAssertTrue(subject.waitForExistence(timeout: 30))
    subject.click()
    subject.typeText("Work agenda")
    saveOnClose(work)
    XCTAssertTrue(work.buttons.matching(draft).firstMatch.waitForExistence(timeout: 30))
    lists(primary, gmail, without: microsoft)
    XCTAssertFalse(primary.buttons.matching(draft).firstMatch.exists)
    attach(work, "Work window with its Draft")

    // #1909, #2421: Work's sidebar offers its Outbox after Sent for the Undo Send Window, opening it
    // lists the sent message, the Primary Profile's window shows no Outbox, and delivery then
    // empties it, so the row leaves and the list returns to the Inbox.
    work.buttons["New Message"].click()
    let recipient = work.textFields["To"]
    XCTAssertTrue(recipient.waitForExistence(timeout: 30))
    typeRecipient(recipient, "maya@example.invalid")
    subject.click()
    subject.typeText("Work report")
    let sentAt = Date()
    work.buttons["Send"].click()
    func outbox(_ window: XCUIElement) -> XCUIElement {
      window.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Outbox")).firstMatch
    }
    let sending = NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Work report.", ". Sending soon")
    // Send closes the composer once the Outbox admits the message; the Inbox column lists no Outbox.
    XCTAssertTrue(subject.waitForNonExistence(timeout: 10))
    XCTAssertTrue(work.buttons["Outbox"].waitForExistence(timeout: 5))
    XCTAssertFalse(work.descendants(matching: .any).matching(sending).firstMatch.exists)
    work.buttons["Outbox"].click()
    XCTAssertTrue(work.descendants(matching: .any).matching(sending).firstMatch.waitForExistence(timeout: 5))
    XCTAssertFalse(outbox(primary).exists)
    XCTAssertFalse(primary.descendants(matching: .any).matching(sending).firstMatch.exists)
    attach(work, "Work window with its Outbox")
    attach(primary, "Primary Profile window without an Outbox")
    // Admission follows the click, so the 10 s Undo Send Window outlasts sentAt + 9 s.
    Thread.sleep(forTimeInterval: max(0, 9 - Date().timeIntervalSince(sentAt)))
    XCTAssertTrue(outbox(work).exists)
    XCTAssertTrue(outbox(work).waitForNonExistence(timeout: 40))
    lists(work, microsoft, without: gmail)
    attach(work, "Work window after its Outbox emptied")

    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    settings.buttons["Profiles"].click()
    move(from: "Work", to: "Primary Profile")
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(settings.waitForNonExistence(timeout: 10))
    XCTAssertTrue(primary.buttons["Inbox. In \(microsoft.0)"].waitForExistence(timeout: 30))
    XCTAssertTrue(row(primary, microsoft.1).waitForExistence(timeout: 30))
    XCTAssertTrue(primary.buttons.matching(draft).firstMatch.waitForExistence(timeout: 30))
    waitUntil {
      !work.buttons["Inbox. In \(microsoft.0)"].exists
        && !row(work, microsoft.1).exists && !work.buttons.matching(draft).firstMatch.exists
    }
    attach(primary, "Primary Profile window after moving back")
  }

  // #2141: the reader's sender menu blocks the sender's exact address once its sheet confirms, and
  // Settings › Blocked Senders lists it until − unblocks it, in each appearance.
  func testBlockSender() throws {
    try blockSender(appearance: "Light")
  }

  func testBlockSenderDark() throws {
    try blockSender(appearance: "Dark")
  }

  private func blockSender(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    app.launchArguments += [
      "-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en",
      "-UnwiredAppearance", appearance.lowercased(),
    ]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    let settings = app.windows["settings-window"]
    let address = "sender001@example.invalid"
    func attach(_ element: XCUIElement, _ name: String) {
      let attachment = XCTAttachment(screenshot: element.screenshot())
      attachment.name = "\(name) (\(appearance))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    window.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Gmail update 001")).firstMatch
      .click()
    // The sender's label repeats on its inner text, so it is clicked by position.
    let sender = window.staticTexts["Sender 001, \(address)"].firstMatch
    XCTAssertTrue(sender.waitForExistence(timeout: 15))
    sender.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    XCTAssertTrue(app.menuItems["Block Sender…"].waitForExistence(timeout: 5))
    app.menuItems["Block Sender…"].click()
    let sheet = window.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 10))
    // An alert's title is its text's value.
    XCTAssertTrue(
      sheet.descendants(matching: .any)
        .matching(NSPredicate(format: "value == %@", "Block \(address)?")).firstMatch
        .waitForExistence(timeout: 5))
    attach(window, "Block Sender sheet")
    sheet.buttons["Block Sender"].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))

    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    settings.buttons["Blocked Senders"].click()
    let row = settings.buttons[address]
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    XCTAssertTrue(text("0 since", in: settings).exists)
    row.click()
    attach(settings, "Settings › Blocked Senders")
    settings.buttons["Unblock"].click()
    XCTAssertTrue(row.waitForNonExistence(timeout: 10))
    XCTAssertTrue(text("No Blocked Senders.", in: settings).waitForExistence(timeout: 10))
    attach(settings, "Settings › Blocked Senders empty")
  }

  // #2280: the reader's Pin pins the message's Thread, and its row shows the pinned marker until
  // Unpin.
  func testPinThread() throws {
    try pinThread(appearance: "Light")
  }

  func testPinThreadDark() throws {
    try pinThread(appearance: "Dark")
  }

  private func pinThread(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    app.launchArguments += [
      "-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en",
      "-UnwiredAppearance", appearance.lowercased(),
    ]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    func attach(_ name: String) {
      let attachment = XCTAttachment(screenshot: window.screenshot())
      attachment.name = "\(name) (\(appearance))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    func row(_ format: String) -> XCUIElement {
      window.buttons.matching(NSPredicate(format: format, "Gmail update 001", ". Pinned")).firstMatch
    }

    row("label CONTAINS %@ AND NOT label CONTAINS %@").click()
    XCTAssertTrue(window.buttons["Pin"].waitForExistence(timeout: 15))
    window.buttons["Pin"].click()
    let pinned = row("label CONTAINS %@ AND label CONTAINS %@")
    XCTAssertTrue(pinned.waitForExistence(timeout: 10))
    XCTAssertTrue(window.buttons["Unpin"].waitForExistence(timeout: 5))
    attach("Pinned Thread")

    // The Pin is stored on this device, so the marker and Unpin return after a relaunch.
    app.terminate()
    app.launch()
    XCTAssertTrue(pinned.waitForExistence(timeout: 60))
    pinned.click()
    XCTAssertTrue(window.buttons["Unpin"].waitForExistence(timeout: 15))
    window.buttons["Unpin"].click()
    XCTAssertTrue(pinned.waitForNonExistence(timeout: 10))
    XCTAssertTrue(window.buttons["Pin"].waitForExistence(timeout: 5))
  }

  // #2459: Labels, which More › Labels › New Label… opens below the reader's toolbar, stays inside
  // the window at M1's width and where the toolbar wraps. The captures show the typed name with no
  // placeholder under it.
  func testNewLabelPopover() throws {
    try newLabelPopover(appearance: "Light")
  }

  func testNewLabelPopoverDark() throws {
    try newLabelPopover(appearance: "Dark")
  }

  private func newLabelPopover(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    app.launchArguments += [
      "-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en",
      "-UnwiredAppearance", appearance.lowercased(),
    ]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    window.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Gmail update 001")).firstMatch
      .click()
    let more = window.menuButtons["More"]
    XCTAssertTrue(more.waitForExistence(timeout: 15))
    let labels = app.popovers.firstMatch
    let name = app.textFields["Label name"]
    for width: CGFloat in [1278, 902] {
      // A drag can end several points short, and AppKit ignores one of a few points, so a short
      // drag repeats and the width is about the target.
      for _ in 0..<3 where abs(window.frame.width - width) > 8 {
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
          .withOffset(CGVector(dx: -2, dy: -2))
        corner.click(
          forDuration: 0.2,
          thenDragTo: corner.withOffset(CGVector(dx: width - window.frame.width, dy: 0)))
      }
      XCTAssertEqual(window.frame.width, width, accuracy: 8)
      more.click()
      app.menuItems["Labels"].click()
      app.menuItems["New Label…"].click()
      XCTAssertTrue(name.waitForExistence(timeout: 10))
      name.typeText("Travel/Spain")
      XCTAssertEqual(name.value as? String, "Travel/Spain")
      XCTAssertTrue(
        window.frame.contains(labels.frame), "Labels at \(labels.frame) leaves \(window.frame)")
      let attachment = XCTAttachment(screenshot: window.screenshot())
      attachment.name = "Labels at \(Int(width)) pt (\(appearance))"
      attachment.lifetime = .keepAlways
      add(attachment)
      app.typeKey(.escape, modifierFlags: [])
      XCTAssertTrue(name.waitForNonExistence(timeout: 10))
    }
  }

  // #2359: with the German test catalog, the Inbox with a Thread open, the Command Palette, a New
  // Message window and Settings › Notifications lay out as #2096's frames draw them.
  func testGermanStrings() throws {
    try germanStrings(appearance: "Light")
  }

  func testGermanStringsDark() throws {
    try germanStrings(appearance: "Dark")
  }

  private func germanStrings(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    // Sign-in runs in English even where the Mac prefers German, which this build offers.
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en"]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["inbox-window-1"]
    performanceSetup(app, window: window)
    // The relaunch chooses German and the appearance for this launch only.
    app.terminate()
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "de",
      "-UnwiredAppearance", appearance.lowercased(),
    ]
    app.launch()
    func attach(_ element: XCUIElement, _ name: String) {
      let attachment = XCTAttachment(screenshot: element.screenshot())
      attachment.name = "\(name) (\(appearance))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    // Each element lies inside its window, and no two overlap.
    func assertLaidOut(_ elements: [XCUIElement], in container: XCUIElement, line: UInt = #line) {
      let frames = elements.map { element in
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element)", line: line)
        return element.frame
      }
      for (index, frame) in frames.enumerated() {
        XCTAssertTrue(
          container.frame.insetBy(dx: -1, dy: -1).contains(frame), "\(elements[index])", line: line)
        for (other, next) in frames.enumerated().dropFirst(index + 1) {
          XCTAssertFalse(
            frame.insetBy(dx: 1, dy: 1).intersects(next),
            "\(elements[index]) overlaps \(elements[other])", line: line)
        }
      }
    }

    // The Inbox frame's size.
    let row = window.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Gmail update 001"))
      .firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 60))
    let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
      .withOffset(CGVector(dx: -2, dy: -2))
    // Slow, holding at the end: a quick drag ends before the window catches up.
    corner.click(
      forDuration: 0.2,
      thenDragTo: corner.withOffset(
        CGVector(dx: 1280 - window.frame.width, dy: 800 - window.frame.height)),
      withVelocity: .slow, thenHoldForDuration: 0.5)
    XCTAssertEqual(window.frame.width, 1280, accuracy: 5)
    row.click()
    XCTAssertTrue(window.buttons["Antworten"].waitForExistence(timeout: 15))
    let toolbar = [
      window.buttons["Befehlspalette öffnen"], window.buttons["Archivieren"],
      window.buttons["Löschen"], window.menuButtons["Ordner"], window.buttons["Antworten"],
      window.buttons["Allen antworten"], window.buttons["Weiterleiten"],
      window.buttons["Anheften"], window.buttons["Als ungelesen markieren"],
      window.buttons["In Spam bewegen"], window.menuButtons["Mehr"],
    ]
    assertLaidOut(toolbar, in: window)
    // One toolbar row, as drawn.
    for button in toolbar {
      XCTAssertEqual(button.frame.midY, toolbar[0].frame.midY, accuracy: 3, "\(button)")
    }
    // The heading stays in the list column, clear of the reader's toolbar.
    let heading = window.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Alle Posteingänge. ")
    ).firstMatch
    XCTAssertLessThanOrEqual(heading.frame.maxX, toolbar[0].frame.minX)
    attach(window, "Inbox with a Thread open")

    app.typeKey("k", modifierFlags: .command)
    let query = window.textFields["Befehl eingeben"]
    XCTAssertTrue(query.waitForExistence(timeout: 15))
    let commands = ["Antworten", "Bewegen nach …", "Als ungelesen markieren", "E-Mails durchsuchen"]
      .map { window.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", $0)).firstMatch }
    assertLaidOut([query] + commands, in: window)
    attach(window, "Command Palette")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(query.waitForNonExistence(timeout: 10))

    window.buttons["Neue Nachricht"].click()
    XCTAssertTrue(window.buttons["Erweitern"].waitForExistence(timeout: 15))
    window.buttons["Erweitern"].click()
    let composer = app.windows["composer-window-1"]
    XCTAssertTrue(composer.waitForExistence(timeout: 15))
    XCTAssertEqual(composer.title, "Neue Nachricht")
    // Send grows with its German title, and the title beside the window controls gives way.
    assertLaidOut(
      [
        composer.buttons[XCUIIdentifierCloseWindow], composer.buttons["Befehlspalette öffnen"],
        composer.popUpButtons.matching(NSPredicate(format: "label BEGINSWITH %@", "Senden von"))
          .firstMatch,
        composer.menuButtons["Aktionen zum Verfassen"], composer.buttons["Senden"],
      ], in: composer)
    attach(composer, "New Message")

    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["settings-window"]
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    settings.buttons["Mitteilungen"].click()
    assertLaidOut(
      [
        text("Berechtigung", in: settings), settings.buttons["Erlauben …"],
        text("Absender und Betreff anzeigen", in: settings),
        settings.switches["Absender und Betreff anzeigen"],
        settings.buttons["Befehlspalette öffnen"],
      ], in: settings)
    attach(settings, "Settings › Notifications")
  }

  // #2153: Settings › Appearance switches every window to Light or Dark at once, and a relaunch
  // opens in the saved choice before the first window draws.
  func testAppearance() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en"]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    let settings = app.windows["settings-window"]
    func attach(_ element: XCUIElement, _ name: String) {
      let attachment = XCTAttachment(screenshot: element.screenshot())
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    // The brightness of a window's empty lower-right corner, which shows its content surface.
    func brightness(_ element: XCUIElement) throws -> CGFloat {
      let bitmap = try XCTUnwrap(
        element.screenshot().image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
      let color = try XCTUnwrap(
        bitmap.colorAt(x: bitmap.pixelsWide * 9 / 10, y: bitmap.pixelsHigh * 9 / 10)?
          .usingColorSpace(.deviceRGB))
      return color.brightnessComponent
    }
    // React Native macOS exposes a radio row as a group whose value reads its role and state.
    func row(_ appearance: String) -> XCUIElement { settings.otherElements[appearance] }
    func choose(_ appearance: String) {
      row(appearance).click()
      XCTAssertEqual(row(appearance).value as? String, "radio button, checked")
    }
    // AppKit redraws the windows after the click, so the corner is polled.
    func expect(_ element: XCUIElement, dark: Bool) {
      let drawn = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in
          guard let value = try? brightness(element) else { return false }
          return dark ? value < 0.3 : value > 0.7
        }, object: nil)
      XCTAssertEqual(XCTWaiter().wait(for: [drawn], timeout: 10), .completed)
    }

    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    settings.buttons["Appearance"].click()
    XCTAssertTrue(row("System").waitForExistence(timeout: 10))
    XCTAssertEqual(row("System").value as? String, "radio button, checked")
    XCTAssertTrue(
      text(
        "System follows macOS. Increase Contrast and Reduce Transparency apply in every choice.",
        in: settings
      ).exists)
    choose("Dark")
    expect(settings, dark: true)
    expect(window, dark: true)
    attach(settings, "Settings › Appearance · Dark")
    choose("Light")
    expect(settings, dark: false)
    expect(window, dark: false)
    attach(settings, "Settings › Appearance · Light")
    // #2222: Message list › Preview lines, one line by default; three lines make every row taller.
    let lines = settings.popUpButtons["Preview lines"]
    func preview(_ to: String) {
      lines.click()
      let item = app.menuItems[to]
      XCTAssertTrue(item.waitForExistence(timeout: 5))
      item.click()
      waitUntil { lines.value as? String == to }
    }
    let message = window.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Gmail update 001"))
      .firstMatch
    XCTAssertTrue(lines.waitForExistence(timeout: 10))
    XCTAssertEqual(lines.value as? String, "1 Line")
    XCTAssertTrue(text("Row height follows the macOS sidebar icon size.", in: settings).exists)
    let oneLine = message.frame.height
    preview("3 Lines")
    waitUntil { message.frame.height > oneLine + 20 }
    attach(settings, "Settings › Appearance · 3 preview lines")
    attach(window, "Inbox · 3 preview lines")
    choose("Dark")
    expect(settings, dark: true)

    app.terminate()
    app.launch()
    XCTAssertTrue(window.waitForExistence(timeout: 30))
    expect(window, dark: true)
    XCTAssertTrue(message.waitForExistence(timeout: 60))
    waitUntil { message.frame.height > oneLine + 20 }
    attach(window, "Inbox after relaunch · Dark · 3 preview lines")
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    settings.buttons["Appearance"].click()
    XCTAssertTrue(row("Dark").waitForExistence(timeout: 10))
    XCTAssertEqual(row("Dark").value as? String, "radio button, checked")
    XCTAssertEqual(lines.value as? String, "3 Lines")
    attach(settings, "Settings › Appearance after relaunch · Dark")
    preview("None")
    waitUntil { message.frame.height < oneLine }
    attach(window, "Inbox · no preview · Dark")
    preview("1 Line")
    waitUntil { abs(message.frame.height - oneLine) < 1 }
    choose("System")
  }

  // #2605: Settings › Notifications' Dock badge pop-up chooses Unread in Inbox, asking for
  // notification permission the first time. The runner cannot read the Dock tile's badge, so the
  // count it draws is checked from the shell (docs/native-journeys.md).
  func testDockBadge() throws {
    try dockBadge(appearance: "Light")
  }

  func testDockBadgeDark() throws {
    try dockBadge(appearance: "Dark")
  }

  private func dockBadge(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let path = try XCTUnwrap(environment["UNWIRED_APP_PATH"])
    let app = XCUIApplication(url: URL(fileURLWithPath: path))
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-interfaceLanguage", "en"]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    let settings = app.windows["settings-window"]
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    settings.buttons["Appearance"].click()
    let look = settings.otherElements[appearance]
    XCTAssertTrue(look.waitForExistence(timeout: 10))
    look.click()
    waitUntil { look.value as? String == "radio button, checked" }
    settings.buttons["Notifications"].click()
    let badge = settings.popUpButtons["Dock badge"]
    XCTAssertTrue(badge.waitForExistence(timeout: 15))
    XCTAssertEqual(badge.value as? String, "Off")
    // Each run's disposable identity asks for permission again. Another copy of the app shares
    // its name, so the one request that appears after the choice is this run's.
    let center = XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")
    let requests = center.groups.matching(
      NSPredicate(format: "label BEGINSWITH %@", "“Unwired Mail” Notifications"))
    XCTAssertEqual(requests.count, 0)
    badge.click()
    app.menuItems["Unread in Inbox"].click()
    let request = requests.firstMatch
    XCTAssertTrue(request.waitForExistence(timeout: 15))
    XCTAssertEqual(requests.count, 1)
    // The banner shows Options while the pointer is over it. Its menu (Allow, Don't Allow) is not
    // in the accessibility tree, so Allow is chosen from the keyboard.
    request.hover()
    let options = request.menuButtons["Options"]
    XCTAssertTrue(options.waitForExistence(timeout: 5))
    options.click()
    center.typeKey(.downArrow, modifierFlags: [])
    center.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(text("Allowed", in: settings).waitForExistence(timeout: 30))
    waitUntil { badge.value as? String == "Unread in Inbox" }
    let attachment = XCTAttachment(screenshot: settings.screenshot())
    attachment.name = "Settings › Notifications, Unread in Inbox (\(appearance))"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  // #1538: a window switched to a Mail Profile that owns no mailbox shows No Mailboxes, with
  // Manage Mail Profiles… opening Settings › Mail Profiles, in each appearance.
  func testMailProfileWithoutMailboxes() throws {
    try mailProfileWithoutMailboxes(appearance: "Light")
  }

  func testMailProfileWithoutMailboxesDark() throws {
    try mailProfileWithoutMailboxes(appearance: "Dark")
  }

  private func mailProfileWithoutMailboxes(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"])))
    app.launchArguments += ["-interfaceLanguage", "en", "-UnwiredAppearance", appearance.lowercased()]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    let settings = app.windows["settings-window"]
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    settings.buttons["Profiles"].click()
    settings.buttons["Add Profile…"].click()
    let sheet = settings.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 10))
    sheet.textFields.firstMatch.click()
    sheet.typeText("Work")
    sheet.buttons["Create"].click()
    XCTAssertTrue(settings.buttons["Work"].waitForExistence(timeout: 15))
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(settings.waitForNonExistence(timeout: 10))

    window.buttons["Profile, Primary Profile"].click()
    app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Work")).firstMatch.click()
    XCTAssertTrue(window.buttons["Profile, Work"].waitForExistence(timeout: 15))
    func labelled(_ label: String) -> XCUIElement {
      window.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
    // The heading names the Profile's scope, not Gmail, and the sidebar keeps Favorites only.
    XCTAssertTrue(labelled("All Inboxes. No mailboxes").waitForExistence(timeout: 30))
    XCTAssertTrue(labelled("No Mailboxes").exists)
    XCTAssertTrue(labelled("Move a mailbox into Work from its current Profile.").exists)
    // No mailbox section header or Inbox row names either account.
    XCTAssertFalse(
      window.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS %@", "@example.invalid")).firstMatch.exists)
    let attachment = XCTAttachment(screenshot: window.screenshot())
    attachment.name = "Mail Profile without mailboxes, \(appearance)"
    attachment.lifetime = .keepAlways
    add(attachment)
    try audit(app, "Mail Profile without mailboxes")

    window.buttons["Manage Profiles…"].click()
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    XCTAssertTrue(settings.buttons["Add Profile…"].waitForExistence(timeout: 10))
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(settings.waitForNonExistence(timeout: 10))
  }

  // swiftlint:disable:next function_body_length
  private func keyboardAndAccessibility(appearance: String) throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    XCTAssertEqual(environment["UNWIRED_TEST_SCENARIO"], "registration-performance")
    let appURL = URL(fileURLWithPath: try XCTUnwrap(environment["UNWIRED_APP_PATH"]))
    // Cut and Copy write the desktop's pasteboard; give the person their contents back unless
    // something else has written it since the journey's last write.
    let pasteboard = NSPasteboard.general
    let saved = (pasteboard.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) { copy.setData(data, forType: type) }
      }
      return copy
    }
    var written = pasteboard.changeCount
    addTeardownBlock {
      guard pasteboard.changeCount == written else { return }
      pasteboard.clearContents()
      pasteboard.writeObjects(saved)
    }
    let app = XCUIApplication(url: appURL)
    // Settings › Appearance for this launch, which the app applies whatever the Mac's appearance.
    app.launchArguments += ["-interfaceLanguage", "en", "-UnwiredAppearance", appearance.lowercased()]
    app.launch()
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    let window = app.windows["Inbox 1"]
    performanceSetup(app, window: window)
    func row(_ subject: String) -> XCUIElement {
      window.buttons.matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
    }
    try audit(app, "Inbox")

    // Search Mail focuses the search field, which takes typing, Cut and Paste.
    let search = window.textFields["Search senders and subjects"]
    runCommand("Search Mail", in: app)
    waitForFocus(search)
    app.typeText("Outlook update 003")
    XCTAssertTrue(row("Outlook update 003").waitForExistence(timeout: 15))
    waitUntil { !row("Outlook update 004").exists }
    app.typeKey("a", modifierFlags: .command)
    app.typeKey("x", modifierFlags: .command)
    waitUntil { search.value as? String == "" }
    XCTAssertEqual(pasteboard.string(forType: .string), "Outlook update 003")
    written = pasteboard.changeCount
    app.typeKey("v", modifierFlags: .command)
    waitUntil { search.value as? String == "Outlook update 003" }
    XCTAssertTrue(row("Outlook update 003").waitForExistence(timeout: 15))
    // Escape closes the palette and hands focus back to the control that had it.
    let closed = window.screenshot()
    app.typeKey("k", modifierFlags: .command)
    let command = window.textFields["Type a command"]
    waitForFocus(command)
    assertPaletteDrawn(in: window, beneath: command, over: closed)
    try audit(app, "Command Palette")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(command.waitForNonExistence(timeout: 10))
    waitForFocus(search)
    // Down reaches Account, then two Up presses return to the interior Search Mail command.
    // If Up does nothing, Return opens Settings instead, so focus cannot return to search.
    app.typeKey("k", modifierFlags: .command)
    waitForFocus(command)
    for key in [XCUIKeyboardKey.downArrow, .downArrow, .downArrow, .upArrow, .upArrow] {
      app.typeKey(key, modifierFlags: [])
    }
    // #1194: the highlighted command is the selected element assistive technology reads.
    let highlighted = window.buttons.matching(
      NSPredicate(format: "selected == true AND label BEGINSWITH %@", "Search Mail")
    ).firstMatch
    XCTAssertTrue(highlighted.waitForExistence(timeout: 5))
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(command.waitForNonExistence(timeout: 10))
    waitForFocus(search)
    let settings = app.windows["settings-window"]
    XCTAssertFalse(settings.exists)
    runCommand("Account", in: app)
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    try audit(app, "Settings")
    // #1196: a remote-content policy is a pop-up whose AppKit menu owns the choice and dismissal.
    settings.buttons["Privacy & Data"].click()
    let policy = settings.popUpButtons["On this device"]
    XCTAssertTrue(policy.waitForExistence(timeout: 15))
    XCTAssertEqual(policy.value as? String, "Ask")
    policy.click()
    let never = app.menuItems["Never"]
    XCTAssertTrue(never.waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(never.waitForNonExistence(timeout: 5))
    XCTAssertEqual(policy.value as? String, "Ask")
    policy.click()
    never.click()
    waitUntil { policy.value as? String == "Never" }
    try audit(app, "Privacy & Data")
    // Writing tools in the reply need Mail Assistance Enablement; this build's model is synthetic.
    settings.switches["Mail Assistance"].click()
    XCTAssertTrue(text("On-device assistance is on.", in: settings).waitForExistence(timeout: 15))
    // #1196: so is the interface language.
    settings.buttons["Language"].click()
    let language = settings.popUpButtons["Language"]
    XCTAssertTrue(language.waitForExistence(timeout: 15))
    // The journey launches with `-interfaceLanguage en`, which chooses English (#2359).
    XCTAssertEqual(language.value as? String, "English")
    try audit(app, "Language")
    profileRemovalJourney(app, settings: settings)
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(settings.waitForNonExistence(timeout: 10))

    // #1125: Move's AppKit menu lists the Microsoft mailbox's own folders. Escape and a click
    // outside dismiss it; the keyboard chooses a folder, which moves the message and closes its
    // reader.
    func searchFor(_ query: String) {
      runCommand("Search Mail", in: app)
      waitForFocus(search)
      app.typeKey("a", modifierFlags: .command)
      app.typeText(query)
      XCTAssertTrue(row(query).waitForExistence(timeout: 15))
    }
    searchFor("Garden plans for spring")
    row("Garden plans for spring").click()
    XCTAssertTrue(body("seed order", in: window).waitForExistence(timeout: 15))
    try linkSheetJourney(app, window: window)
    searchFor("Quarterly planning")
    row("Quarterly planning").click()
    let agenda = body("Agenda for Thursday.", in: window)
    XCTAssertTrue(agenda.waitForExistence(timeout: 15))
    let move = window.menuButtons["Folders"]
    let projects = app.menuItems["Projects"]
    move.click()
    XCTAssertTrue(projects.waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(projects.waitForNonExistence(timeout: 5))
    move.click()
    XCTAssertTrue(projects.waitForExistence(timeout: 5))
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).click()
    XCTAssertTrue(projects.waitForNonExistence(timeout: 5))
    XCTAssertTrue(agenda.exists)
    move.click()
    XCTAssertTrue(projects.waitForExistence(timeout: 5))
    app.typeKey(.downArrow, modifierFlags: [])
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(projects.waitForNonExistence(timeout: 5))
    XCTAssertTrue(agenda.waitForNonExistence(timeout: 15))
    let moved = text("Moved: “Quarterly planning”.", in: window)
    XCTAssertTrue(moved.waitForExistence(timeout: 10))
    assertProviderActionsSettled(window, provider: "Microsoft")
    XCTAssertTrue(moved.exists)
    searchFor("Outlook update 003")

    // Reply from the palette starts a Draft beside the reader; it keeps typed text across relaunch.
    row("Outlook update 003").click()
    XCTAssertTrue(body("Outlook update 003 body.", in: window).waitForExistence(timeout: 15))
    waitUntil { row("Outlook update 003").isSelected }
    try audit(app, "Reader")
    runCommand("Reply", in: app)
    // The empty body is labelled with its placeholder; once typed into, it is found by its text.
    let message = window.textViews.matching(NSPredicate(format: "label == %@", "Message")).firstMatch
    XCTAssertTrue(message.waitForExistence(timeout: 15))
    message.click()
    message.typeText("Keyboard reply")
    let typed = window.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Keyboard reply"))
      .firstMatch
    XCTAssertTrue(typed.waitForExistence(timeout: 10))
    // Paste goes through the Edit menu into the body as well.
    app.typeKey("a", modifierFlags: .command)
    app.typeKey("c", modifierFlags: .command)
    waitUntil { pasteboard.string(forType: .string) == "Keyboard reply" }
    written = pasteboard.changeCount
    app.typeKey(.rightArrow, modifierFlags: [])
    app.typeKey("v", modifierFlags: .command)
    waitUntil { typed.value as? String == "Keyboard replyKeyboard reply" }
    try audit(app, "Composer")
    try linkEditorJourney(app, window: window, typed: typed, appearance: appearance)
    // #1211: the reader's toolbar above the docked reply takes clicks. Folders opens its menu and
    // the read toggle flips, and the reply keeps its text.
    move.click()
    XCTAssertTrue(projects.waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(projects.waitForNonExistence(timeout: 5))
    let read = window.buttons["Mark as Read"]
    let unread = window.buttons["Mark as Unread"]
    let (toggle, toggled) = read.exists ? (read, unread) : (unread, read)
    toggle.click()
    XCTAssertTrue(toggled.waitForExistence(timeout: 10))
    assertProviderActionsSettled(window, provider: "Microsoft")
    XCTAssertEqual(typed.value as? String, "Keyboard replyKeyboard reply")
    // The composer hides the search field; Search Mail shows it again. Clearing the query lists
    // the Inbox, with the Draft.
    runCommand("Search Mail", in: app)
    waitForFocus(search)
    app.typeKey("a", modifierFlags: .command)
    app.typeKey(.delete, modifierFlags: [])
    let draft = row("Draft. Re: Outlook update 003")
    XCTAssertTrue(draft.waitForExistence(timeout: 15))
    // Only Save stores the reply (#1609) and its link (#1792); Close asks first.
    window.buttons["Close"].click()
    let save = window.sheets.firstMatch.buttons["Save"]
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    save.click()
    XCTAssertTrue(typed.waitForNonExistence(timeout: 10))
    app.terminate()
    app.launch()
    XCTAssertTrue(draft.waitForExistence(timeout: 30))
    draft.click()
    XCTAssertTrue(typed.waitForExistence(timeout: 15))
    XCTAssertEqual(typed.value as? String, "Keyboard replyKeyboard reply")
    typed.click()
    app.typeKey("a", modifierFlags: .command)
    let edit = window.buttons["Edit Link"]
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.click()
    let destination = app.textFields["Link"]
    XCTAssertTrue(destination.waitForExistence(timeout: 10))
    XCTAssertEqual(destination.value as? String, "https://example.com/garden")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(destination.waitForNonExistence(timeout: 10))
    try detailCheckJourney(app, window: window, typed: typed, appearance: appearance)

    // Window commands: a new Inbox, cycling, Show Inbox and closing, each window with its own view.
    app.typeKey("n", modifierFlags: [.command, .option])
    let second = app.windows["Inbox 2"]
    XCTAssertTrue(second.waitForExistence(timeout: 15))
    XCTAssertTrue(
      second.descendants(matching: .any).matching(
        NSPredicate(format: "label == %@", "Select a message to start reading.")
      ).firstMatch.waitForExistence(timeout: 15))
    XCTAssertTrue(typed.exists)
    // Windows are listed front to back.
    func front(_ identifier: String) {
      waitUntil { app.windows.firstMatch.identifier == identifier }
    }
    front("inbox-window-2")
    app.typeKey("`", modifierFlags: .command)
    front("inbox-window-1")
    app.typeKey("`", modifierFlags: .command)
    front("inbox-window-2")
    app.typeKey("0", modifierFlags: .command)
    front("inbox-window-1")
    app.typeKey("`", modifierFlags: .command)
    front("inbox-window-2")
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(second.waitForNonExistence(timeout: 10))
    front("inbox-window-1")
    XCTAssertTrue(typed.exists)

    // #1266: Expand saves the Draft and moves it into its own New Message window, closing the
    // overlay; Command-W closes that window, and the app keeps running. Its Save Draft returns the
    // Draft to the Inbox window's overlay (#1671).
    window.buttons["Expand"].click()
    let composer = app.windows["composer-window-1"]
    XCTAssertTrue(composer.waitForExistence(timeout: 15))
    XCTAssertEqual(composer.title, "New Message")
    let windowBody = composer.textViews.matching(
      NSPredicate(format: "value CONTAINS %@", "Keyboard reply")
    ).firstMatch
    XCTAssertTrue(windowBody.waitForExistence(timeout: 15))
    XCTAssertEqual(windowBody.value as? String, "Keyboard replyKeyboard reply")
    XCTAssertTrue(typed.waitForNonExistence(timeout: 10))
    XCTAssertFalse(composer.buttons["Expand"].exists)
    // #1286: Send and the Command Palette sit in the toolbar row beside the window controls and
    // take clicks there.
    let send = composer.buttons["Send"]
    XCTAssertTrue(send.waitForExistence(timeout: 10))
    XCTAssertEqual(
      send.frame.midY, composer.buttons[XCUIIdentifierCloseWindow].frame.midY, accuracy: 3)
    // #2094: closed, the Command Input keeps only its symbol and key cap in 75pt.
    XCTAssertEqual(composer.buttons["Open Command Palette"].frame.width, 75, accuracy: 1)
    let composerClosed = composer.screenshot()
    composer.buttons["Open Command Palette"].click()
    let query = composer.textFields.matching(NSPredicate(format: "label == %@", "Type a command"))
      .firstMatch
    XCTAssertTrue(query.waitForExistence(timeout: 10))
    assertPaletteDrawn(in: composer, beneath: query, over: composerClosed)
    composer.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(query.waitForNonExistence(timeout: 10))
    // Both native exits must reach the regular editor's save question and recipient guard (#1609).
    let to = composer.textFields.matching(NSPredicate(format: "label == %@", "To")).firstMatch
    XCTAssertTrue(to.waitForExistence(timeout: 10))
    typeRecipient(to, "unfinished")
    waitUntil { to.value as? String == "unfinished" }
    let question = composer.sheets.firstMatch
    composer.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(question.buttons["Save Draft"].waitForExistence(timeout: 10))
    question.buttons["Save Draft"].click()
    let invalid = text("Correct or remove the invalid address to close this Draft.", in: composer)
    XCTAssertTrue(invalid.waitForExistence(timeout: 10))
    // Quit asks too, and Cancel keeps the app running with the Draft open.
    composer.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(question.buttons["Cancel"].waitForExistence(timeout: 10))
    question.buttons["Cancel"].click()
    XCTAssertTrue(question.waitForNonExistence(timeout: 10))
    XCTAssertEqual(app.state, .runningForeground)
    to.click()
    composer.typeKey("a", modifierFlags: .command)
    composer.typeKey(.delete, modifierFlags: [])
    waitUntil { (to.value as? String ?? "").isEmpty }
    func capture(_ element: XCUIElement, _ name: String) {
      let shot = XCTAttachment(screenshot: element.screenshot())
      shot.name = "#1671 \(name) \(appearance)"
      shot.lifetime = .keepAlways
      add(shot)
    }
    composer.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(question.buttons["Save Draft"].waitForExistence(timeout: 10))
    capture(composer, "C1 Close the New Message window")
    question.buttons["Save Draft"].click()
    XCTAssertTrue(composer.waitForNonExistence(timeout: 10))
    // A composer unmount aborted the host within seconds before (#1174).
    Thread.sleep(forTimeInterval: 5)
    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertTrue(typed.waitForExistence(timeout: 15))
    front("inbox-window-1")
    XCTAssertEqual(typed.value as? String, "Keyboard replyKeyboard reply")
    capture(window, "C2 Back in its Inbox window")
    // The refused Quit was cancelled, so it did not terminate after the later successful Close.
    // A fresh New Message window also permits Quit through its own successful save/close guard.
    window.buttons["Expand"].click()
    let quittingComposer = app.windows["composer-window-2"]
    XCTAssertTrue(quittingComposer.waitForExistence(timeout: 15))
    XCTAssertTrue(quittingComposer.buttons["Send"].waitForExistence(timeout: 15))
    quittingComposer.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
  }

  // #1898: a Writing tools rewrite of the reply says which details it changed. The synthetic
  // rewrite keeps the reply's link, so Replace Text takes the accent tint; once the reply has a
  // time the rewrite drops, Keep Original does. Return stays with the body (#1900).
  private func detailCheckJourney(
    _ app: XCUIApplication, window: XCUIElement, typed: XCUIElement, appearance: String
  ) throws {
    let reply = "Keyboard replyKeyboard reply"
    let replace = window.buttons["Replace your text with this rewrite"]
    let keep = window.buttons["Keep your text and close this suggestion"]
    let withChanges = window.buttons[
      "Replace your text with this rewrite, including its changed details"]
    // Selectable text is a text view holding its words as its value.
    func shown(_ words: String) -> XCUIElement {
      window.textViews.matching(NSPredicate(format: "value CONTAINS %@", words)).firstMatch
    }
    func review(_ state: String) throws {
      // With the caret at the end and no selection, Writing tools rewrite the whole body.
      typed.click()
      app.typeKey(.downArrow, modifierFlags: .command)
      writingTool("Rewrite the message body", in: window, of: app).click()
      XCTAssertTrue(keep.waitForExistence(timeout: 15))
      XCTAssertTrue(window.buttons["Try Again to get writing help"].exists)
      let capture = XCTAttachment(screenshot: window.screenshot())
      capture.name = "Writing tools \(state) \(appearance)"
      capture.lifetime = .keepAlways
      add(capture)
      try audit(app, "Writing tools \(state)")
    }
    try review("W1")
    XCTAssertTrue(shown("Kept: https://example.com/garden").exists)
    XCTAssertTrue(replace.exists)
    XCTAssertFalse(withChanges.exists)
    // Keyboard focus stays in the body, which takes Return for a new line. Like any edit, it
    // closes the result, and Undo removes it.
    app.typeKey(.return, modifierFlags: [])
    waitUntil { typed.value as? String == reply + "\n" }
    XCTAssertTrue(keep.waitForNonExistence(timeout: 10))
    app.typeKey("z", modifierFlags: .command)
    waitUntil { typed.value as? String == reply }
    writingTool("Rewrite the message body", in: window, of: app).click()
    XCTAssertTrue(replace.waitForExistence(timeout: 15))
    replace.click()
    XCTAssertTrue(keep.waitForNonExistence(timeout: 10))
    // With the result closed, only the body holds the rewrite.
    let rewritten = window.textViews.matching(
      NSPredicate(format: "value == %@", "Synthetic rewrite of local mail.")
    ).firstMatch
    XCTAssertTrue(rewritten.waitForExistence(timeout: 10))
    rewritten.click()
    app.typeKey("z", modifierFlags: .command)
    waitUntil { typed.value as? String == reply }
    app.typeKey(.downArrow, modifierFlags: .command)
    app.typeText(" at 9:30")
    waitUntil { typed.value as? String == reply + " at 9:30" }
    try review("W2")
    // #1902: the count line is one text element between the result text and its row.
    let count = shown("1 detail differs from your original. Compare it before using this rewrite.")
    let row = text("Time. Original: 9:30. Rewrite: —. Removed", in: window)
    XCTAssertTrue(count.exists)
    XCTAssertEqual(
      window.textViews.matching(NSPredicate(format: "value CONTAINS %@", "detail differs")).count, 1)
    XCTAssertTrue(row.exists)
    XCTAssertGreaterThan(count.frame.minY, shown("Synthetic rewrite of local mail.").frame.maxY)
    XCTAssertLessThan(count.frame.maxY, row.frame.minY)
    // Queries return elements in accessibility order, which VoiceOver follows.
    let order = window.descendants(matching: .any).matching(
      NSPredicate(
        format: "(elementType == %d AND (value CONTAINS %@ OR value CONTAINS %@))"
          + " OR (elementType == %d AND label CONTAINS %@)",
        XCUIElement.ElementType.textView.rawValue, "Synthetic rewrite", "detail differs",
        XCUIElement.ElementType.staticText.rawValue, ". Original: ")
    ).allElementsBoundByIndex.map { element -> String in
      if element.elementType == .staticText { return "row" }
      return (element.value as? String ?? "").contains("Synthetic") ? "rewrite" : "count"
    }
    XCTAssertEqual(order, ["rewrite", "count", "row"])
    XCTAssertEqual(
      window.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", ". Original: ")).count, 1)
    XCTAssertTrue(withChanges.exists)
    XCTAssertFalse(replace.exists)
    keep.click()
    XCTAssertTrue(keep.waitForNonExistence(timeout: 10))
    XCTAssertEqual(typed.value as? String, reply + " at 9:30")
    typed.click()
    app.typeKey(.downArrow, modifierFlags: .command)
    for _ in 0..<8 { app.typeKey(.delete, modifierFlags: []) }
    waitUntil { typed.value as? String == reply }
  }

  // #1792: the format bar's Link control adds a link to the selected reply text in its native
  // popover, Link focused; an invalid destination says why, Escape keeps the selection, and one
  // Undo reverts the applied link.
  private func linkEditorJourney(
    _ app: XCUIApplication, window: XCUIElement, typed: XCUIElement, appearance: String
  ) throws {
    let body = typed.value as? String
    app.typeKey("a", modifierFlags: .command)
    let addLink = window.buttons["Add Link"]
    waitUntil { addLink.isEnabled }
    addLink.click()
    let destination = app.textFields["Link"]
    XCTAssertTrue(destination.waitForExistence(timeout: 10))
    waitForFocus(destination)
    XCTAssertEqual(destination.value as? String, "")
    XCTAssertEqual(app.textFields["Text"].value as? String, body)
    XCTAssertFalse(app.buttons["Remove Link"].exists)
    let apply = app.buttons["Apply"]
    XCTAssertFalse(apply.isEnabled)
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "Add Link \(appearance)"
    capture.lifetime = .keepAlways
    add(capture)
    try audit(app, "Link Editor")
    app.typeText("not a link\r")
    let reason = text("Enter a valid web, email or phone link.", in: app)
    XCTAssertTrue(reason.waitForExistence(timeout: 10))
    XCTAssertFalse(apply.isEnabled)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(destination.waitForNonExistence(timeout: 10))
    XCTAssertEqual(typed.value as? String, body)
    XCTAssertTrue(addLink.isEnabled)
    addLink.click()
    waitForFocus(destination)
    XCTAssertEqual(app.textFields["Text"].value as? String, body)
    app.typeText("https://example.com/garden")
    waitUntil { apply.isEnabled }
    apply.click()
    XCTAssertTrue(destination.waitForNonExistence(timeout: 10))
    let edit = window.buttons["Edit Link"]
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    XCTAssertEqual(typed.value as? String, body)
    // The format bar's Undo, on Edit Link's row; an earlier move's notice offers its own Undo.
    let undo = try XCTUnwrap(
      window.buttons.matching(identifier: "Undo").allElementsBoundByIndex.first {
        abs($0.frame.midY - edit.frame.midY) < 1
      })
    undo.click()
    // Undo leaves the caret after the text, so Edit Link is unavailable once no link touches it.
    waitUntil { !edit.isEnabled }
    XCTAssertEqual(typed.value as? String, body)
    window.buttons["Redo"].click()
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.click()
    XCTAssertTrue(app.buttons["Remove Link"].waitForExistence(timeout: 10))
    XCTAssertEqual(destination.value as? String, "https://example.com/garden")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(destination.waitForNonExistence(timeout: 10))
    typed.click()
  }

  // Opens the key window's Command Palette, narrows it to one command and runs it with Return.
  private func runCommand(_ name: String, in app: XCUIApplication) {
    app.typeKey("k", modifierFlags: .command)
    let input = app.textFields.matching(NSPredicate(format: "label == %@", "Type a command")).firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    waitForFocus(input)
    app.typeText(name)
    waitUntil { input.value as? String == name }
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(input.waitForNonExistence(timeout: 10))
  }

  // #1573: the open palette's panel draws beneath its query field over what the window showed
  // before it opened, so most points sampled there change colour.
  private func assertPaletteDrawn(
    in window: XCUIElement, beneath query: XCUIElement, over closed: XCUIScreenshot,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    // The panel eases in over 200 ms.
    Thread.sleep(forTimeInterval: 0.5)
    let open = window.screenshot()
    let capture = XCTAttachment(screenshot: open)
    capture.name = "Command Palette open"
    capture.lifetime = .keepAlways
    add(capture)
    func bitmap(_ shot: XCUIScreenshot) -> NSBitmapImageRep? {
      shot.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        .map(NSBitmapImageRep.init(cgImage:))
    }
    guard let before = bitmap(closed), let after = bitmap(open),
      before.pixelsWide == after.pixelsWide, before.pixelsHigh == after.pixelsHigh
    else {
      return XCTFail("the window's captures differ in size", file: file, line: line)
    }
    // The 460pt panel's first rows, inside the window.
    let field = query.frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    let panel = CGRect(x: field.minX + 12, y: field.maxY + 18, width: 436, height: 240)
      .intersection(CGRect(origin: .zero, size: window.frame.size))
    let scale = CGFloat(after.pixelsWide) / window.frame.width
    var sampled = 0
    var changed = 0
    for column in 0..<19 {
      for row in 0..<9 {
        let x = Int((panel.minX + panel.width * (CGFloat(column) + 0.5) / 19) * scale)
        let y = Int((panel.minY + panel.height * (CGFloat(row) + 0.5) / 9) * scale)
        guard let old = before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
          let new = after.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        else { continue }
        sampled += 1
        let distance =
          abs(old.redComponent - new.redComponent) + abs(old.greenComponent - new.greenComponent)
          + abs(old.blueComponent - new.blueComponent)
        if distance > 0.03 { changed += 1 }
      }
    }
    print("PALETTE DRAWN " + json(["changed": changed, "sampled": sampled]))
    // Undrawn, no point changes; over white, the translucent glass changes few besides its rows.
    XCTAssertGreaterThan(
      changed * 10, sampled, "the open palette's panel is not drawn", file: file, line: line)
  }

  private func waitForFocus(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    let focused = NSPredicate(format: "hasKeyboardFocus == true")
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: focused, object: element)], timeout: 10),
      .completed, "\(element) never took keyboard focus", file: file, line: line)
  }

  // Runs every XCTest accessibility audit on the app as shown, prints each issue as an
  // ACCESSIBILITY line and fails on one that no known gap explains.
  private func audit(_ app: XCUIApplication, _ screen: String) throws {
    // AppKit shows its text Touch Bar only while a text input has keyboard focus.
    let focused = app.descendants(matching: .any)
      .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
    let textFocused =
      focused.exists && [.textField, .searchField, .textView].contains(focused.elementType)
    try app.performAccessibilityAudit { issue in
      if issue.auditType == .parentChild && issue.element == nil {
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Accessibility \(screen): \(issue.compactDescription)"
        capture.lifetime = .keepAlways
        self.add(capture)
      }
      let gap = self.knownAccessibilityGap(issue, in: app, screen: screen, textFocused: textFocused)
      print("ACCESSIBILITY " + self.json([
        "screen": screen, "audit": issue.compactDescription, "textFocused": textFocused,
        "elementType": issue.element?.elementType.rawValue ?? -1,
        "label": issue.element?.label ?? "", "knownGap": gap ?? "",
      ]))
      return gap != nil
    }
  }

  // XCTest's contrast audit flags text whose drawn pixels pass, and text that another window or
  // view covers, that a sheet dims in the window it belongs to, or that the list fades under the
  // search bar (#1550). Such text is audited where it is in front; other text passes when its own
  // capture is drawn at WCAG AA.
  private func drawnContrastGap(_ text: XCUIElement, in app: XCUIApplication) -> String? {
    if !text.isHittable { return "Covered" }
    let front = app.windows.firstMatch
    let sheet = front.sheets.firstMatch
    if sheet.exists && front.frame.contains(text.frame) && !sheet.frame.contains(text.frame) {
      return "Dimmed by a sheet"
    }
    // The list fades its last 72pt into the search bar's scroll edge (inbox-bar.tsx); text that
    // reaches above it is measured.
    if front.textFields["Search senders and subjects"].exists
      && text.frame.minY >= front.frame.maxY - 72
      && front.scrollViews.allElementsBoundByIndex.contains(where: {
        $0.frame.maxY == front.frame.maxY && $0.frame.contains(text.frame)
      })
    {
      return "Faded by the scroll edge"
    }
    guard let weakest = weakestWord(text), weakest >= 4.5 else { return nil }
    return String(format: "Weakest word drawn at %.2f:1", weakest)
  }

  // The WCAG contrast of a text's weakest drawn word. Pixels that stand out from the capture's most
  // common colour by 1.1:1 are ink, and ink within 2.5pt along a line forms a word. A word is
  // measured by its strongest pixel against its own backdrop, the most common colour within 1pt
  // of it. A thin stroke that never reaches its ink at 1x so counts with its neighbours, while
  // weaker text sharing the element, such as a secondary run, is its own words.
  private func weakestWord(_ element: XCUIElement) -> Double? {
    // Drawing the capture into an sRGB context converts it from its own colour space.
    guard
      let image = element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = context.data else { return nil }
    let bytes = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
    let width = image.width
    let height = image.height
    let scale = Double(width) / element.frame.width
    func linear(_ channel: UInt8) -> Double {
      let value = Double(channel) / 255
      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    func contrast(_ first: Double, _ second: Double) -> Double {
      (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
    var colors = [Int](repeating: 0, count: width * height)
    var luminances = [Double](repeating: 0, count: width * height)
    for pixel in colors.indices {
      let (red, green, blue) = (bytes[pixel * 4], bytes[pixel * 4 + 1], bytes[pixel * 4 + 2])
      colors[pixel] = Int(red) << 16 | Int(green) << 8 | Int(blue)
      luminances[pixel] = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    // The luminance of the most common colour among these pixels.
    func backdrop(_ pixels: [Int]) -> Double? {
      var counts: [Int: (count: Int, pixel: Int)] = [:]
      for pixel in pixels { counts[colors[pixel], default: (0, pixel)].count += 1 }
      return counts.values.max { $0.count < $1.count }.map { luminances[$0.pixel] }
    }
    guard let background = backdrop(Array(colors.indices)) else { return nil }
    let ink = luminances.map { contrast($0, background) >= 1.1 }
    let reach = Int((2.5 * scale).rounded())
    let margin = Int(scale.rounded())
    var seen = [Bool](repeating: false, count: ink.count)
    var weakest: Double?
    for start in ink.indices where ink[start] && !seen[start] {
      seen[start] = true
      var stack = [start]
      var word: [Int] = []
      while let pixel = stack.popLast() {
        word.append(pixel)
        let (x, y) = (pixel % width, pixel / width)
        for nextY in max(0, y - 1)...min(height - 1, y + 1) {
          for nextX in max(0, x - reach)...min(width - 1, x + reach) {
            let next = nextY * width + nextX
            if ink[next] && !seen[next] {
              seen[next] = true
              stack.append(next)
            }
          }
        }
      }
      // Smaller specks are anti-aliasing fringes and separators such as a middle dot, not words.
      guard Double(word.count) >= 8 * scale * scale else { continue }
      let xs = word.map { $0 % width }
      let ys = word.map { $0 / width }
      let columns = max(0, xs.min()! - margin)...min(width - 1, xs.max()! + margin)
      let around = (max(0, ys.min()! - margin)...min(height - 1, ys.max()! + margin))
        .flatMap { y in columns.map { y * width + $0 } }
      guard let local = backdrop(around) else { continue }
      let strongest = word.map { contrast(luminances[$0], local) }.max()!
      weakest = min(weakest ?? strongest, strongest)
    }
    return weakest
  }

  private static let privateCloudFooter =
    "When you ask, summaries and suggested replies may send the opened message, current-Thread context and readable attachments to Apple Private Cloud Compute. Rewrite sends the text you choose. Translation and background assistance stay on this Mac. Each choice applies only to its Profile on this Mac. Other devices and accounts keep their own choices."

  // The issue that owns each accessibility gap the audits still find, or why it is not the app's.
  private func knownAccessibilityGap(
    _ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication, screen: String, textFocused: Bool
  ) -> String? {
    let type = issue.element?.elementType
    let label = issue.element?.label ?? ""
    // AppKit's Touch Bar for a focused text view.
    let touchBar =
      type == .touchBar || (type == .popUpButton && ["list style", "text alignment"].contains(label))
    switch issue.auditType {
    // Private Cloud's row is dimmed until Mail Assistance is on; WCAG exempts inactive controls.
    case .contrast
    where type == .staticText && screen == "Privacy & Data"
      && ["Use Private Cloud", "Turn on Mail Assistance above to use Private Cloud."].contains(label):
      return "Inactive control"
    case .contrast where type == .staticText:
      return issue.element.flatMap { drawnContrastGap($0, in: app) }
    case .action where touchBar, .sufficientElementDescription where touchBar:
      return "AppKit Touch Bar"
    // The candidate bar's suggestion buttons report a parent that does not list them on these
    // audited screens. XCTest gives these issues no element or specific detail, so the focused
    // text input is the narrowest check. Other unlocated issues fail; xcresults hold captures.
    case .parentChild
    where issue.element == nil && issue.compactDescription == "Parent/Child mismatch"
      && textFocused && ["Command Palette", "Reader", "Composer"].contains(screen):
      return "AppKit Touch Bar"
    // An email address is the readable name of the signed-in account or of a mailbox's row.
    case .sufficientElementDescription
    where type == .staticText
      && [
        "relay@privaterelay.example.invalid", "casey@example.invalid", "other@example.invalid",
        "pat@example.invalid",
      ].contains(label):
      return "email address"
    // The Link Editor's hint, Private Cloud's explanation and the Writing tools result's privacy
    // note are sentences containing the word "text", not labels repeating their role.
    case _ where type == .staticText && issue.compactDescription == "Label duplicates role description"
      && [
        "Enter a web, email or phone link for the selected text.", WindowTests.privateCloudFooter,
        "Written on this device. It may be inaccurate, is not saved, and changes nothing until you use it. Used text takes the style of the text before it.",
      ].contains(label):
      return "sentence"
    // A message link whose text is a web address reads as that address.
    case .sufficientElementDescription
    where type == .link
      && [label, issue.element?.title ?? ""].contains { $0.hasPrefix("https://") }:
      return "web address"
    default:
      return nil
    }
  }

  // Signs in with Apple and connects the synthetic Microsoft mailbox, confirms the Recovery Key,
  // which opens the Inbox, then adds the synthetic Gmail mailbox in Settings.
  private func performanceSetup(_ app: XCUIApplication, window: XCUIElement) {
    XCTAssertTrue(window.buttons["Continue"].waitForExistence(timeout: 30))
    window.buttons["Continue"].click()
    XCTAssertTrue(window.buttons["Sign in with Apple"].waitForExistence(timeout: 20))
    window.buttons["Sign in with Apple"].click()
    XCTAssertTrue(window.buttons["Microsoft 365 and Outlook"].waitForExistence(timeout: 15))
    window.buttons["Microsoft 365 and Outlook"].click()
    XCTAssertTrue(
      text("casey@example.invalid is connected", in: window).waitForExistence(timeout: 15))
    let presented = recoveryKey(in: window).value as? String ?? ""
    let entry = window.textFields["Last four characters"]
    entry.click()
    entry.typeText(String(presented.suffix(4)))
    window.buttons["Confirm Recovery Key"].click()
    XCTAssertTrue(window.buttons["Inbox. In casey@example.invalid"].waitForExistence(timeout: 15))
    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["settings-window"]
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    settings.buttons["Email Accounts"].click()
    XCTAssertTrue(settings.buttons["Add Another Gmail Mailbox"].waitForExistence(timeout: 15))
    settings.buttons["Add Another Gmail Mailbox"].click()
    XCTAssertTrue(text("other@example.invalid", in: settings).waitForExistence(timeout: 15))
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(settings.waitForNonExistence(timeout: 10))
    XCTAssertTrue(window.buttons["Inbox. In other@example.invalid"].waitForExistence(timeout: 30))
    XCTAssertTrue(
      window.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Gmail update 001"))
        .firstMatch.waitForExistence(timeout: 60))
  }

  // A reader's body text: a selectable text view for plain text, static text inside the isolated
  // WebKit view for HTML.
  private func body(_ marker: String, in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any).matching(
      NSPredicate(
        format: "(elementType == %d OR elementType == %d) AND value CONTAINS %@",
        XCUIElement.ElementType.textView.rawValue, XCUIElement.ElementType.staticText.rawValue,
        marker)
    ).firstMatch
  }

  // Samples whose result had rendered before XCUITest's first query: bounded by XCUITest itself.
  private var firstQueryResults = 0

  private func uptime() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6 }

  // When `shown` exists, every `also` exists and `without` does not, querying as fast as XCUITest
  // answers; a result missing after 10 s fails the journey.
  private func until(
    _ shown: XCUIElement, from start: Double, and also: XCUIElement? = nil,
    without hidden: XCUIElement? = nil
  ) -> Double {
    var queries = 1
    defer { if queries == 1 { firstQueryResults += 1 } }
    while !(shown.exists && also?.exists != false && hidden?.exists != true) {
      queries += 1
      if uptime() - start > 10_000 {
        XCTFail("No rendered result within 10 s: \(shown)")
        break
      }
    }
    return uptime()
  }

  // The median time one accessibility query takes, which every sample includes at least once.
  private func queryOverhead(_ element: XCUIElement) -> Double {
    let durations = (0..<20).map { _ in
      let start = uptime()
      _ = element.exists
      return uptime() - start
    }.sorted()
    return durations[durations.count / 2]
  }

  // A key or format bar group's windows bracket its inputs, and `shows` is the body each must reach.
  private typealias PerformanceGroup = (
    name: String, budget: Double, windows: [(start: Double, end: Double)], firstQuery: Int,
    shows: [(text: String, marks: String)]
  )

  // Typing and formatting feedback: each sample runs from the key press or format bar button
  // release the app recorded to its first recorded edit of the body that shows exactly the
  // expected text and marks (bold 1, italic 2, underline 4 per character), so a later input
  // cannot hide a late result. The budget is the frame interval the app recorded.
  private func typingSamples(
    _ app: XCUIApplication, window: XCUIElement, body: XCUIElement
  ) -> [PerformanceGroup] {
    body.click()
    var groups: [PerformanceGroup] = []
    var text = ""
    var marks: [Int] = []
    func press(
      _ name: String, _ keys: [String], _ input: (String) -> Void, _ change: (String) -> Void
    ) {
      var windows: [(start: Double, end: Double)] = []
      var shows: [(text: String, marks: String)] = []
      for key in keys {
        let start = uptime()
        input(key)
        windows.append((start, uptime()))
        change(key)
        shows.append((text, marks.map(String.init).joined()))
      }
      groups.append((name, 0, windows, 0, shows))
    }
    let type = { (key: String) in app.typeKey(key, modifierFlags: []) }
    press("typing", "typing feedback test".map(String.init), type) { key in
      text += key
      marks.append(0)
    }
    // Command-B at the caret marks what is typed next.
    app.typeKey("b", modifierFlags: .command)
    press("marked-typing", " bold words".map(String.init), type) { key in
      text += key
      marks.append(1)
    }
    // Option-Shift-Left selects the last word; each shortcut toggles its mark on it, then back.
    app.typeKey(.leftArrow, modifierFlags: [.option, .shift])
    let bits = ["b": 1, "i": 2, "u": 4]
    let toggles = (0..<12).map { ["b", "i", "u"][$0 / 2 % 3] }
    let toggle = { (key: String) in
      for index in marks.indices.suffix(5) { marks[index] ^= bits[key, default: 0] }
    }
    press("formatting", toggles, { app.typeKey($0, modifierFlags: .command) }, toggle)
    // The format bar's mark buttons toggle the same marks on the still-selected word.
    let buttons = ["b": "Bold", "i": "Italic", "u": "Underline"]
    let click = { (key: String) in window.buttons[buttons[key, default: ""]].firstMatch.click() }
    press("format-bar", toggles, click, toggle)
    // Right collapses the selection at the word's end, so Command-B right after it turns bold off
    // for what is typed next and leaves the word bold (#1229).
    app.typeKey(.rightArrow, modifierFlags: [])
    app.typeKey("b", modifierFlags: .command)
    press("collapsed-typing", " end".map(String.init), type) { key in
      text += key
      marks.append(0)
    }
    return groups
  }

  private func reportPerformance(
    _ groups: [PerformanceGroup],
    evidence: URL, overhead: Double, name: String = "Warm-cache performance",
    composer: String? = nil
  ) throws {
    struct Record: Decodable {
      let event: String
      let milliseconds: Double?
      let uptime: Double?
      let text: String?
      let marks: String?
      let frameStart: Double?
    }
    let records = try String(contentsOf: evidence, encoding: .utf8)
      .split(separator: "\n")
      .map { try JSONDecoder().decode(Record.self, from: Data($0.utf8)) }
    func times(_ event: String) throws -> [Double] {
      try records.filter { $0.event == event }.map { try XCTUnwrap($0.uptime) }
    }
    let keys = records.filter { $0.event == "key-down" }
    // Indices into the evidence, which each source writes in the order it noted them.
    let edits = records.indices.filter { records[$0].event == "text-edit" }
    let draws = records.indices.filter { records[$0].event == "text-drawn" }
    var lastEdit = -1
    let presses = try times("mouse-down")
    let releases = try times("mouse-up")
    // Body requests the synthetic providers answered; priming the cache must have made some.
    let providerBodies = try times("provider-body")
    if groups.contains(where: { $0.name.hasPrefix("cached-body") }) {
      XCTAssertFalse(providerBodies.isEmpty, "The probe recorded no provider body request")
    }
    let stalls = try records.filter { $0.event == "stall" }.map {
      (uptime: try XCTUnwrap($0.uptime), milliseconds: try XCTUnwrap($0.milliseconds))
    }
    var lines: [String] = []
    var pressToRelease: [Double] = []
    // Nearest-rank percentiles.
    func percentile<Value>(_ sorted: [Value], _ rank: Double) -> Value {
      sorted[max(0, Int((rank * Double(sorted.count)).rounded(.up)) - 1)]
    }
    for var group in groups {
      // A key group runs from each recorded key press, and the format bar group from each
      // recorded release, to the first edit showing its result. The body's first draw after that
      // edit falls in the display frame that started last before it; display frames start every
      // interval from any recorded start. Frames late counts the frames that started after the
      // input and before that one: 0 is the next rendered frame.
      var drawn: [Double] = []
      var framesLate: [Int] = []
      if !group.shows.isEmpty {
        let inputs = group.name == "format-bar" ? releases : try times("key-down")
        let starts = try group.windows.map { window in
          try XCTUnwrap(
            inputs.last { $0 >= window.start && $0 <= window.end },
            "Missing input for \(group.name)")
        }
        group.budget = try XCTUnwrap(keys.compactMap(\.milliseconds).max())
        group.windows = try zip(starts, group.shows).map { start, shown in
          // Each input has its own edit, so a later input's result cannot stand in for it.
          let editIndex = try XCTUnwrap(
            edits.first {
              $0 > lastEdit && (records[$0].uptime ?? 0) >= start
                && records[$0].text == shown.text && records[$0].marks == shown.marks
            }, "No edit showed \(shown) for \(group.name)")
          lastEdit = editIndex
          let edit = records[editIndex]
          let end = try XCTUnwrap(edit.uptime)
          let drawIndex = try XCTUnwrap(
            draws.first { $0 > editIndex }, "No draw after \(shown) for \(group.name)")
          let draw = records[drawIndex]
          let drawEnd = try XCTUnwrap(draw.uptime)
          // A draw shows the body's latest edit; a result a later input replaced first never showed.
          let drawnEdit = edits.last { $0 < drawIndex }.map { records[$0] }
          XCTAssertTrue(
            drawnEdit?.text == edit.text && drawnEdit?.marks == edit.marks,
            "\(shown) for \(group.name) was replaced before it was drawn")
          let frameStart = try XCTUnwrap(draw.frameStart)
          let interval = try XCTUnwrap(draw.milliseconds)
          XCTAssertGreaterThan(frameStart, 0, "No display frame before \(group.name)")
          let frame = ((drawEnd - frameStart) / interval).rounded(.down)
          let next = ((start - frameStart) / interval).rounded(.up)
          drawn.append(drawEnd - start)
          framesLate.append(max(0, Int(frame - next)))
          return (start, end)
        }
      }
      // A click selects on release: its sample starts at the release of its last press.
      let windows = try group.windows.map { window -> (start: Double, end: Double) in
        if group.name == "launch-to-first-list" || !group.shows.isEmpty { return window }
        let press = try XCTUnwrap(
          presses.last(where: { $0 >= window.start && $0 <= window.end }),
          "Missing mouse press for \(group.name)")
        let release = try XCTUnwrap(
          releases.first(where: { $0 >= press && $0 <= window.end }),
          "Missing mouse release for \(group.name)")
        pressToRelease.append(release - press)
        return (release, window.end)
      }
      // A cached body is read from the encrypted cache, never from the provider.
      if group.name.hasPrefix("cached-body") {
        XCTAssertFalse(
          providerBodies.contains { body in group.windows.contains { $0.start...$0.end ~= body } },
          "\(group.name) requested a provider body")
      }
      let samples = windows.map { $0.end - $0.start }.sorted()
      let during = stalls.filter { stall in
        windows.contains { stall.uptime <= $0.end && stall.uptime + stall.milliseconds >= $0.start }
      }.map(\.milliseconds)
      var record: [String: Any] = [
        "interaction": group.name, "budgetMs": group.budget, "samplesMs": samples,
        "p50Ms": percentile(samples, 0.5), "p95Ms": percentile(samples, 0.95),
        "maxMs": samples.last ?? 0, "withinBudget": percentile(samples, 0.95) <= group.budget,
        "stallsMs": during, "resultsOnFirstQuery": group.firstQuery,
      ]
      if let composer { record["composer"] = composer }
      if !framesLate.isEmpty {
        framesLate.sort()
        record["drawnMs"] = drawn.sorted()
        record["framesLate"] = framesLate
        record["nextRenderedFrame"] = percentile(framesLate, 0.95) == 0
      }
      lines.append(json(record))
    }
    pressToRelease.sort()
    lines.append(
      json([
        "queryOverheadMs": overhead,
        "pressToReleaseMedianMs": pressToRelease.isEmpty
          ? 0 : pressToRelease[pressToRelease.count / 2],
        "sessionStallsMs": stalls.map(\.milliseconds),
      ]))
    print(lines.map { "PERFORMANCE \($0)" }.joined(separator: "\n"))
    let attachment = XCTAttachment(
      data: Data((lines.joined(separator: "\n") + "\n").utf8), uniformTypeIdentifier: "public.json")
    attachment.name = composer.map { "Composer opening (\($0) composer)" } ?? name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func json(_ object: [String: Any]) -> String {
    // swiftlint:disable:next force_try
    String(
      decoding: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys),
      as: UTF8.self)
  }
}
