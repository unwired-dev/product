import XCTest

// Synthetic completion proxy: reject failed writes and unfinished saves/syncs at each action.
// Optimistic rows and the encrypted cache alone cannot prove that Gmail accepted a change.
private func assertGmailActionsSettled(_ window: XCUIElement) {
  let unconfirmed = window.descendants(matching: .any).matching(
    NSPredicate(
      format: "label MATCHES %@",
      "(?s).*(Gmail could not|Gmail has not confirmed|Gmail needs your permission|"
        + "waits? for Gmail|Organizing mail waits).*"))
  XCTAssertFalse(unconfirmed.firstMatch.waitForExistence(timeout: 5))
  let unfinished = window.descendants(matching: .any).matching(
    NSPredicate(
      format: "label CONTAINS %@ OR label CONTAINS %@",
      "Saving the change on this device", "Checking Gmail"))
  XCTAssertTrue(unfinished.firstMatch.waitForNonExistence(timeout: 10))
  XCTAssertFalse(unconfirmed.firstMatch.exists)
}

final class WindowTests: XCTestCase {
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
    XCTAssertTrue(text("Private sync is on", in: first).exists)
    app.terminate()
    app.launch()
    let resumed = app.windows["Inbox 1"]
    XCTAssertTrue(text("Private sync is on", in: resumed).waitForExistence(timeout: 15))
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
    XCTAssertTrue(resumed.buttons["Check for approval"].exists)
    XCTAssertFalse(resumed.buttons["Gmail"].exists)
    XCTAssertFalse(text("This device cannot join", in: resumed).exists)
    // Signing out of the gate leaves nothing of the account on this device.
    resumed.buttons["Sign out of this device"].click()
    XCTAssertTrue(text("Your other devices", in: resumed).waitForExistence(timeout: 15))
    resumed.buttons["Sign out of this device"].click()
    XCTAssertTrue(text("Your mail,", in: resumed).waitForExistence(timeout: 15))
  }

  // Sign-out keeps nothing of the account on this device; deletion ends the account everywhere.
  private func removalJourney(_ app: XCUIApplication, first: XCUIElement) {
    XCTAssertTrue(first.buttons["Continue"].waitForExistence(timeout: 20))
    first.buttons["Continue"].click()
    first.buttons["Sign in with Google"].click()
    XCTAssertTrue(recoveryKey(in: first).waitForExistence(timeout: 15))
    let key = recoveryKey(in: first).value as? String ?? ""
    let entry = first.textFields["Last four characters"]
    entry.click()
    entry.typeText(String(key.suffix(4)))
    first.buttons["Confirm Recovery Key"].click()
    XCTAssertTrue(text("Private sync is on", in: first).waitForExistence(timeout: 15))
    first.buttons["Sign out of this device"].click()
    XCTAssertTrue(text("Your other devices", in: first).waitForExistence(timeout: 15))
    first.buttons["Sign out of this device"].click()
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
    resumed.buttons["Delete Product Account"].click()
    XCTAssertTrue(text("cannot be undone", in: resumed).waitForExistence(timeout: 15))
    resumed.buttons["Delete permanently"].click()
    XCTAssertTrue(text("Product Account deleted", in: resumed).waitForExistence(timeout: 15))
    // The deleted account cannot be reopened, and this device keeps nothing of it.
    resumed.buttons["Sign in with Google"].click()
    XCTAssertTrue(text("Product Account deleted", in: resumed).waitForExistence(timeout: 15))
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
    resumed.buttons[apple ? "Gmail" : "Choose another Google mailbox"].click()
    XCTAssertTrue(text("connected on this device", in: resumed).waitForExistence(timeout: 15))
    let entry = resumed.textFields["Last four characters"]
    entry.click()
    entry.typeText(String(presented.suffix(4)))
    resumed.buttons["Confirm Recovery Key"].click()
    // Confirmed setup opens the synchronized Gmail Inbox, listed over two Gmail pages.
    let rowan = "Unread. Rowan Hale. Garden plans for spring"
    XCTAssertTrue(resumed.buttons[rowan].waitForExistence(timeout: 20))
    XCTAssertTrue(
      resumed.buttons["test@example.invalid. Welcome to your synthetic Inbox"].waitForExistence(
        timeout: 15))
    resumed.buttons[rowan].click()
    XCTAssertTrue(
      resumed.textViews.matching(NSPredicate(format: "value == %@", "rowan@example.invalid"))
        .firstMatch.waitForExistence(timeout: 10))
    // The opened body arrives from Gmail as text; its image is not loaded.
    XCTAssertTrue(
      text("Images in this message are not loaded.", in: resumed).waitForExistence(timeout: 15))
    // The sanitized HTML renders inside the isolated WebKit view.
    XCTAssertTrue(
      resumed.webViews.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "seed order"))
        .firstMatch.waitForExistence(timeout: 15))
    // Organizing goes through the packaged native Gmail modify: a star, then an archive and Undo.
    resumed.buttons["Star"].click()
    XCTAssertTrue(resumed.buttons["Remove star"].waitForExistence(timeout: 10))
    assertGmailActionsSettled(resumed)
    XCTAssertTrue(resumed.buttons["Remove star"].exists)
    resumed.buttons["Archive"].click()
    XCTAssertTrue(resumed.buttons["Undo"].waitForExistence(timeout: 10))
    assertGmailActionsSettled(resumed)
    XCTAssertTrue(resumed.buttons["Undo"].exists)
    XCTAssertFalse(resumed.buttons[rowan].exists)
    resumed.buttons["Undo"].click()
    XCTAssertTrue(resumed.buttons[rowan].waitForExistence(timeout: 15))
    assertGmailActionsSettled(resumed)
    XCTAssertTrue(resumed.buttons[rowan].exists)
    XCTAssertFalse(recoveryKey(in: resumed).exists)
    app.terminate()
    app.launch()
    // Relaunch reopens the encrypted cache, then setup stays reachable from the Inbox.
    let relaunched = app.windows["Inbox 1"]
    XCTAssertTrue(relaunched.buttons[rowan].waitForExistence(timeout: 20))
    relaunched.buttons[rowan].click()
    relaunched.buttons["Account"].click()
    let settings = app.windows["settings-window"]
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    XCTAssertTrue(text("connected on this device", in: settings).waitForExistence(timeout: 15))
    XCTAssertTrue(text("Private sync is on", in: settings).exists)
    XCTAssertFalse(recoveryKey(in: settings).exists)
    app.typeKey(",", modifierFlags: .command)
    XCTAssertEqual(app.windows.matching(identifier: "settings-window").count, 1)
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(settings.waitForNonExistence(timeout: 10))
    XCTAssertTrue(relaunched.buttons[rowan].exists)
    XCTAssertTrue(
      relaunched.textViews.matching(NSPredicate(format: "value == %@", "rowan@example.invalid"))
        .firstMatch.exists)
  }

  // The Tiptap evaluation editor (#818): a new Draft is typed into the packaged page, saved through
  // the encrypted Draft store, and reopened after relaunch. Focus, resize and teardown are recorded.
  private func draftEditorJourney(_ app: XCUIApplication, first: XCUIElement) {
    XCTAssertTrue(first.buttons["Continue"].waitForExistence(timeout: 20))
    first.buttons["Continue"].click()
    XCTAssertTrue(first.buttons["Sign in with Google"].waitForExistence(timeout: 20))
    first.buttons["Sign in with Google"].click()
    XCTAssertTrue(recoveryKey(in: first).waitForExistence(timeout: 15))
    let presented = recoveryKey(in: first).value as? String ?? ""
    first.buttons["Choose another Google mailbox"].click()
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
    // Assistance in the editor needs Mail Assistance Enablement; this build's model is synthetic.
    first.buttons["Account"].click()
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
    corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: -160, dy: 0)))
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
    nativeCloseJourney(app, window: relaunched)
  }

  private func nativeCloseJourney(_ app: XCUIApplication, window: XCUIElement) {
    let subject = window.textFields["Subject"]
    subject.click()
    subject.typeText("Native close")
    window.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(window.buttons["Save"].waitForExistence(timeout: 10))
    window.buttons["Cancel"].click()
    XCTAssertTrue(window.webViews.textViews["Message body"].exists)
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(window.buttons["Save"].waitForExistence(timeout: 10))
    window.buttons["Cancel"].click()
    // Saving later must not revive a cancelled Quit.
    saveOnClose(window)
    XCTAssertTrue(window.buttons["New Message"].waitForExistence(timeout: 10))
    window.buttons["New Message"].click()
    XCTAssertTrue(window.buttons["Undo"].waitForExistence(timeout: 30))
    window.textFields["Subject"].click()
    window.textFields["Subject"].typeText("First guarded window")
    app.typeKey("n", modifierFlags: .command)
    let second = app.windows["Inbox 2"]
    XCTAssertTrue(second.buttons["New Message"].waitForExistence(timeout: 15))
    second.buttons["New Message"].click()
    XCTAssertTrue(second.buttons["Undo"].waitForExistence(timeout: 30))
    second.textFields["Subject"].click()
    second.textFields["Subject"].typeText("Second guarded window")
    app.typeKey("q", modifierFlags: .command)
    // One Quit asks each window, then actually stops the process.
    let saving = app.windows.containing(.button, identifier: "Save").firstMatch
    XCTAssertTrue(saving.waitForExistence(timeout: 10))
    saving.buttons["Save"].click()
    waitUntil { app.windows.count == 1 }
    let remaining = app.windows.firstMatch
    XCTAssertTrue(remaining.buttons["Don’t Save"].waitForExistence(timeout: 10))
    remaining.buttons["Don’t Save"].click()
    waitUntil { app.state == .notRunning }
  }

  private func webText(_ value: String, in window: XCUIElement) -> XCUIElement {
    window.webViews.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", value))
      .firstMatch
  }

  private func writingTool(_ name: String, in window: XCUIElement) -> XCUIElement {
    let tools = window.buttons["Writing tools"]
    XCTAssertTrue(tools.waitForExistence(timeout: 30))
    tools.click()
    let action = window.buttons[name]
    XCTAssertTrue(action.waitForExistence(timeout: 15))
    return action
  }

  private func saveOnClose(_ window: XCUIElement) {
    window.buttons["Close"].click()
    let save = window.buttons["Save"]
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    save.click()
    waitUntil { window.webViews.count == 0 }
  }

  // #819: Command-B formats the selection in the page, Command-Z and Shift-Command-Z step the
  // page's history, and an accepted rewrite is one edit that one Undo reverts.
  private func formattingJourney(_ app: XCUIApplication, typed: XCUIElement) {
    let window = app.windows["Inbox 1"]
    // Select the whole body, so every word of it is bold when the Draft reopens.
    typed.click()
    window.typeKey("a", modifierFlags: .command)
    window.typeKey("b", modifierFlags: .command)
    let numbered = window.buttons["Numbered list"]
    numbered.click()
    let paragraph = window.webViews.staticTexts.matching(
      NSPredicate(format: "value == %@", "Evaluation paragraph")
    ).firstMatch
    XCTAssertTrue(paragraph.waitForNonExistence(timeout: 10))
    window.typeKey("z", modifierFlags: .command)
    window.typeKey("z", modifierFlags: .command)
    XCTAssertTrue(paragraph.waitForExistence(timeout: 10))
    window.typeKey("z", modifierFlags: [.command, .shift])
    window.typeKey("z", modifierFlags: [.command, .shift])
    XCTAssertTrue(paragraph.waitForNonExistence(timeout: 10))
    reopenDraft(app)
    webText("Evaluation paragraph", in: window).doubleClick()
    waitUntil { window.buttons["Bold"].isSelected && window.buttons["Numbered list"].isSelected }
    assistanceRoundTrips(app, result: "Synthetic rewrite of local mail.", apply: "Replace your text with this rewrite", boldAfterApply: true) {
      window.webViews.staticTexts.firstMatch.doubleClick()
      self.writingTool("Rewrite the selected text", in: window).click()
    }
    assistanceRoundTrips(app, result: "Synthetic rewrite of local mail.", apply: "Replace your text with this rewrite", boldAfterApply: false) {
      window.webViews.textViews["Message body"].click()
      self.writingTool("Rewrite the message body", in: window).click()
    }
    assistanceRoundTrips(app, result: "Synthetic translation of local mail.", apply: "Replace the selected text with this translation", boldAfterApply: false) {
      window.webViews.staticTexts.firstMatch.doubleClick()
      let translate = self.writingTool("Translate the selected text", in: window)
      waitUntil { translate.isEnabled }
      translate.click()
      window.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Translate into German"))
        .firstMatch.click()
    }
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
      self.writingTool("Suggest a reply to the quoted message", in: window).click()
    }
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
    let draft = window.buttons.matching(
      title.isEmpty
        ? NSPredicate(format: "label BEGINSWITH %@", "Draft.")
        : NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Draft.", title)
    ).firstMatch
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
    for leaveUndone in [true, false] {
      let original = window.webViews.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? "" }
      let originalBold = window.buttons["Bold"].isSelected
      start()
      XCTAssertTrue(text(result, in: window).waitForExistence(timeout: 15))
      let accept = window.buttons[apply]
      XCTAssertTrue(accept.waitForExistence(timeout: 15))
      accept.click()
      waitUntil { window.webViews.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? "" } != original }
      waitUntil { window.webViews.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? "" }.joined(separator: " ").contains(result) }
      let accepted = window.webViews.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? "" }
      waitUntil { window.buttons["Numbered list"].isSelected == numbered && window.buttons["Bold"].isSelected == boldAfterApply }
      waitUntil { window.buttons["Undo"].isEnabled }
      window.buttons["Undo"].click()
      waitUntil { window.webViews.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? "" } == original }
      waitUntil { window.buttons["Numbered list"].isSelected == numbered && window.buttons["Bold"].isSelected == originalBold }
      if !leaveUndone {
        waitUntil { window.buttons["Redo"].isEnabled }
        window.buttons["Redo"].click()
        waitUntil { window.webViews.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? "" } == accepted }
        waitUntil { window.buttons["Numbered list"].isSelected == numbered && window.buttons["Bold"].isSelected == boldAfterApply }
      }
      reopenDraft(app, titled: title)
      // The reopened page replaces any editor shown at launch once it has loaded.
      let expected = leaveUndone ? original : accepted
      waitUntil {
        window.webViews.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? "" }
          == expected
      }
      let expectedBold = leaveUndone ? originalBold : boldAfterApply
      waitUntil {
        window.buttons["Numbered list"].isSelected == numbered
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
    XCTAssertFalse(first.buttons["Choose another Google mailbox"].exists)
    let mailboxes = "Encrypted mailbox list: alex@example.invalid."
    XCTAssertFalse(text(mailboxes, in: first).exists)
    // The synthetic trusted device approves with the code shown on this device.
    first.buttons["Check for approval"].click()
    XCTAssertTrue(text("Private sync is on", in: first).waitForExistence(timeout: 15))
    XCTAssertTrue(text(mailboxes, in: first).exists)
    // Gmail on this device still needs its own authorization.
    XCTAssertTrue(first.buttons["Gmail"].exists)
    app.terminate()
    app.launch()
    let relaunched = app.windows["Inbox 1"]
    XCTAssertTrue(text("Private sync is on", in: relaunched).waitForExistence(timeout: 15))
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
      text("does not unlock this Product Account", in: first).waitForExistence(timeout: 15))
    XCTAssertTrue(text("Approve this device", in: first).exists)
    entry.click()
    entry.typeKey("a", modifierFlags: .command)
    entry.typeText("000G-40R4-0M30-E209-185G-R38E-1W81-24GK-2GAH-C5RR-34D1-P70X-3RFG")
    first.buttons["Unlock with Recovery Key"].click()
    XCTAssertTrue(text("Private sync is on", in: first).waitForExistence(timeout: 15))
    XCTAssertTrue(text(mailboxes, in: first).exists)
    XCTAssertFalse(enrollmentCode(in: first).exists)
    // Gmail on this device still needs its own authorization.
    XCTAssertTrue(first.buttons["Gmail"].exists)
    app.terminate()
    app.launch()
    let relaunched = app.windows["Inbox 1"]
    XCTAssertTrue(text("Private sync is on", in: relaunched).waitForExistence(timeout: 15))
    XCTAssertTrue(text(mailboxes, in: relaunched).waitForExistence(timeout: 15))
    XCTAssertFalse(relaunched.textFields["Recovery Key"].exists)
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
    XCTAssertTrue(text("Only Apple opens this Product Account", in: first).exists)
    first.buttons["Link Google sign-in"].click()
    let linked = "Sign in with Apple or Google to open this Product Account."
    XCTAssertTrue(text(linked, in: first).waitForExistence(timeout: 15))
    XCTAssertFalse(first.buttons["Link Google sign-in"].exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(text(linked, in: app.windows["Inbox 1"]).waitForExistence(timeout: 15))
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
      draftEditorJourney(app, first: first)
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
    app.typeKey("n", modifierFlags: .command)
    let second = app.windows["Inbox 2"]
    XCTAssertTrue(second.waitForExistence(timeout: 10))
    let oliver = second.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Oliver Park"))
      .firstMatch
    XCTAssertTrue(oliver.waitForExistence(timeout: 10))
    oliver.click()
    XCTAssertTrue(address(second, "oliver@example.com").waitForExistence(timeout: 10))
    XCTAssertTrue(address(first, "maya@example.com").exists)
    XCTAssertTrue(oliver.label.hasPrefix("Unread."))
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
    XCTAssertTrue(app.windows["Inbox 1"].buttons["Mark as unread"].waitForExistence(timeout: 10))

  }
}
