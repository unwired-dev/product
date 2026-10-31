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
    // The deletion's reply is lost (#1173). After relaunch, retrying it confirms the deletion and
    // leaves its confirmation for Welcome.
    XCTAssertTrue(
      text("Deletion could not be confirmed", in: resumed).waitForExistence(timeout: 15))
    app.terminate()
    app.launch()
    let pending = app.windows["Inbox 1"]
    XCTAssertTrue(text("Confirm account deletion", in: pending).waitForExistence(timeout: 20))
    pending.buttons["Delete permanently"].click()
    XCTAssertTrue(text("Product Account deleted", in: pending).waitForExistence(timeout: 15))
    // The deleted account cannot be reopened, and this device keeps nothing of it.
    pending.buttons["Sign in with Google"].click()
    XCTAssertTrue(text("Product Account deleted", in: pending).waitForExistence(timeout: 15))
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
    opensMenu("Archive", from: resumed.buttons[rowan])
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
    // Organizing goes through the packaged native Gmail modify: a star, then an archive and Undo.
    resumed.buttons["Star"].click()
    XCTAssertTrue(resumed.buttons["Remove star"].waitForExistence(timeout: 10))
    assertProviderActionsSettled(resumed)
    XCTAssertTrue(resumed.buttons["Remove star"].exists)
    // The starred row names its flag.
    let starred = rowan + ". Flagged"
    resumed.buttons["Archive"].click()
    XCTAssertTrue(resumed.buttons["Undo"].waitForExistence(timeout: 10))
    assertProviderActionsSettled(resumed)
    XCTAssertTrue(resumed.buttons["Undo"].exists)
    XCTAssertFalse(resumed.buttons[starred].exists)
    resumed.buttons["Undo"].click()
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
    XCTAssertTrue(relaunched.buttons[starred].exists)
    XCTAssertTrue(text("rowan@example.invalid", in: relaunched).exists)
    if apple { composerMenuJourney(app, first: relaunched) }
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
    app.typeKey("n", modifierFlags: .command)
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
    nativeCloseJourney(app, window: relaunched)
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
    to.click()
    to.typeText("invalid-address")
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
    let saving = app.sheets.firstMatch
    XCTAssertTrue(saving.buttons["Save"].waitForExistence(timeout: 10))
    saving.buttons["Save"].click()
    waitUntil { app.windows.count == 1 }
    let remaining = app.windows.firstMatch.sheets.firstMatch
    XCTAssertTrue(remaining.buttons["Don’t Save"].waitForExistence(timeout: 10))
    remaining.buttons["Don’t Save"].click()
    waitUntil { app.state == .notRunning }
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
    let numbered = window.buttons["Numbered list"]
    numbered.click()
    // The paragraph's text stays in the list item, beside the item's number marker.
    let marker = window.webViews.otherElements.matching(NSPredicate(format: "value == %@", "1"))
      .firstMatch
    XCTAssertTrue(marker.waitForExistence(timeout: 10))
    window.typeKey("z", modifierFlags: .command)
    window.typeKey("z", modifierFlags: .command)
    XCTAssertTrue(marker.waitForNonExistence(timeout: 10))
    window.typeKey("z", modifierFlags: [.command, .shift])
    window.typeKey("z", modifierFlags: [.command, .shift])
    XCTAssertTrue(marker.waitForExistence(timeout: 10))
    reopenDraft(app)
    webText("Evaluation paragraph", in: window).doubleClick()
    waitUntil { window.buttons["Bold"].isSelected && window.buttons["Numbered list"].isSelected }
    // #1568: Select All starts outside the list item, and the bar still shows the list selected.
    window.typeKey("a", modifierFlags: .command)
    for _ in 0..<3 {
      RunLoop.current.run(until: Date().addingTimeInterval(1))
      XCTAssertTrue(window.buttons["Numbered list"].isSelected)
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
      waitUntil { window.buttons["Numbered list"].isSelected == numbered && window.buttons["Bold"].isSelected == boldAfterApply }
      waitUntil { window.buttons["Undo"].isEnabled }
      window.buttons["Undo"].click()
      waitUntil { body() == original }
      waitUntil { window.buttons["Numbered list"].isSelected == numbered && window.buttons["Bold"].isSelected == originalBold }
      if !leaveUndone {
        waitUntil { window.buttons["Redo"].isEnabled }
        window.buttons["Redo"].click()
        waitUntil { body() == accepted }
        waitUntil { window.buttons["Numbered list"].isSelected == numbered && window.buttons["Bold"].isSelected == boldAfterApply }
      }
      reopenDraft(app, titled: title)
      // The reopened page replaces any editor shown at launch once it has loaded.
      let expected = leaveUndone ? original : accepted
      waitUntil { body() == expected }
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

  // #1130: a link asks in an AppKit sheet on its own window, showing the full destination as
  // selectable text. Escape and Cancel close it without acting, and Command-P stays closed behind
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
        buttons: ["Open link", "Cancel"])
    app.typeKey("p", modifierFlags: .command)
    XCTAssertFalse(window.textFields["Type a command"].waitForExistence(timeout: 2))
    XCTAssertTrue(sheet.exists)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    ask("garden plan", title: "Open this link in your browser?", destination: garden,
        buttons: ["Open link", "Cancel"])
    sheet.buttons["Cancel"].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    let flagged = "https://garden.example.invalid/order"
    let seeds = "https://seeds.example.invalid/order"
    let caution = "This link may not be what it seems"
    for key in [XCUIKeyboardKey.escape, .return] {
      ask(flagged, title: caution, destination: seeds, buttons: ["Cancel", "Copy link", "Proceed"])
      if key == .escape { try audit(app, "Link sheet") }
      app.typeKey(key, modifierFlags: [])
      XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }
    // Focus returns to the window, whose Command Palette opens again.
    app.typeKey("p", modifierFlags: .command)
    XCTAssertTrue(window.textFields["Type a command"].waitForExistence(timeout: 10))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(window.textFields["Type a command"].waitForNonExistence(timeout: 10))
  }

  // #1225: removing a Mail Profile asks in a sheet on Settings, where Cancel is the default button
  // that Escape and Return answer; only Remove removes it.
  private func profileRemovalJourney(_ app: XCUIApplication, settings: XCUIElement) {
    let sheet = settings.sheets.firstMatch
    settings.buttons["Mail Profiles"].click()
    settings.buttons["Add Mail Profile…"].click()
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
    let remove = settings.buttons["Remove Mail Profile…"]
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
    XCTAssertTrue(text("Only Apple opens this Product Account", in: first).exists)
    first.buttons["Link Google sign-in"].click()
    let linked = "Sign in with Apple or Google to open this Product Account."
    XCTAssertTrue(text(linked, in: first).waitForExistence(timeout: 15))
    XCTAssertFalse(first.buttons["Link Google sign-in"].exists)
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
    // Every launch starts from one new window, whatever AppKit saved at the previous quit.
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
    app.typeKey("n", modifierFlags: .command)
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
    // Every launch starts from one new window, whatever AppKit saved at the previous quit.
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
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
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
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
    window.buttons["All inboxes"].click()

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
      return (start, until(row("Jordan Lee"), from: start, and: window.buttons["All inboxes"]))
    }
    // All inboxes aggregates every listed Thread of both mailboxes.
    let views = [
      (inbox("casey@example.invalid"), "Outlook update 001", "Gmail update 001"),
      (inbox("other@example.invalid"), "Gmail update 001", "Outlook update 001"),
      (window.buttons["All inboxes"], "Outlook update 001", "Rowan Hale"),
    ]
    measure("cached-mailbox-switch", budget: 200, count: 21) { index in
      let (view, shown, required) = views[index % views.count]
      let start = uptime()
      view.click()
      // A mailbox's own Inbox no longer shows the other mailbox; All inboxes shows both.
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
    // Typing and formatting feedback: each sample runs from the key press or format bar button
    // release the app recorded to its first recorded edit of the body that begins with the
    // expected text and marks (bold 1, italic 2, underline 4 per character), so a later input
    // cannot hide a late result. The budget is the frame interval the app recorded.
    window.buttons["New Message"].click()
    let message = window.textViews.matching(NSPredicate(format: "label == %@", "Message")).firstMatch
    XCTAssertTrue(message.waitForExistence(timeout: 10))
    message.click()
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
    let overhead = queryOverhead(window.buttons["New Message"])
    // The running app keeps appending probe records; read them only after it quits.
    app.terminate()
    try reportPerformance(groups, evidence: evidence, overhead: overhead)
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
    app.launchArguments +=
      appearance == "Dark"
      ? ["-AppleInterfaceStyle", "Dark"] : ["-NSRequiresAquaSystemAppearance", "YES"]
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
    app.typeKey("p", modifierFlags: .command)
    let command = window.textFields["Type a command"]
    waitForFocus(command)
    assertPaletteDrawn(in: window, beneath: command, over: closed)
    try audit(app, "Command Palette")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(command.waitForNonExistence(timeout: 10))
    waitForFocus(search)
    // Down reaches Account, then two Up presses return to the interior Search Mail command.
    // If Up does nothing, Return opens Settings instead, so focus cannot return to search.
    app.typeKey("p", modifierFlags: .command)
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
    // #1196: so is the interface language.
    settings.buttons["Language"].click()
    let language = settings.popUpButtons["Language"]
    XCTAssertTrue(language.waitForExistence(timeout: 15))
    XCTAssertEqual(language.value as? String, "System Default")
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
    // #1211: the reader's toolbar above the docked reply takes clicks. Folders opens its menu and
    // the read toggle flips, and the reply keeps its text.
    move.click()
    XCTAssertTrue(projects.waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(projects.waitForNonExistence(timeout: 5))
    let read = window.buttons["Mark as read"]
    let unread = window.buttons["Mark as unread"]
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
    // Only Save stores the reply (#1609); Close asks first.
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

    // Window commands: a new Inbox, cycling, Show Inbox and closing, each window with its own view.
    app.typeKey("n", modifierFlags: .command)
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
    // overlay; Command-W closes that window, and the app keeps running.
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
    to.click()
    to.typeText("unfinished")
    waitUntil { to.value as? String == "unfinished" }
    let question = composer.sheets.firstMatch
    composer.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(question.buttons["Save"].waitForExistence(timeout: 10))
    question.buttons["Save"].click()
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
    composer.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(question.buttons["Save"].waitForExistence(timeout: 10))
    question.buttons["Save"].click()
    XCTAssertTrue(composer.waitForNonExistence(timeout: 10))
    // A composer unmount aborted the host within seconds before (#1174).
    Thread.sleep(forTimeInterval: 5)
    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertTrue(row("Draft. Re: Outlook update 003").exists)
    // The refused Quit was cancelled, so it did not terminate after the later successful Close.
    // A fresh New Message window also permits Quit through its own successful save/close guard.
    row("Draft. Re: Outlook update 003").click()
    XCTAssertTrue(typed.waitForExistence(timeout: 15))
    window.buttons["Expand"].click()
    let quittingComposer = app.windows["composer-window-2"]
    XCTAssertTrue(quittingComposer.waitForExistence(timeout: 15))
    XCTAssertTrue(quittingComposer.buttons["Send"].waitForExistence(timeout: 15))
    quittingComposer.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
  }

  // Opens the key window's Command Palette, narrows it to one command and runs it with Return.
  private func runCommand(_ name: String, in app: XCUIApplication) {
    app.typeKey("p", modifierFlags: .command)
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
      let gap = self.knownAccessibilityGap(issue, screen: screen, textFocused: textFocused)
      print("ACCESSIBILITY " + self.json([
        "screen": screen, "audit": issue.compactDescription, "textFocused": textFocused,
        "elementType": issue.element?.elementType.rawValue ?? -1,
        "label": issue.element?.label ?? "", "knownGap": gap ?? "",
      ]))
      return gap != nil
    }
  }

  // Text the contrast audit still flags after #1195's solid colours, by the issue that owns it. The
  // audits cover every open window, so these list labels rather than screens.
  private let contrastGaps: [String: Set<String>] = [
    // Dark secondary text on sidebar glass, lightened by whatever is behind the window.
    "#1574": ["Accounts", "Application", "Automation", "Gmail · other@example.invalid"],
    // Their captured pixels pass, yet the audit flags them: the Inbox window's labels while
    // Settings or a sheet is in front, small text, including AppKit's own, and the Command
    // Palette's headers on its glass panel.
    "#1550": [
      "", "16 September 2025 at 00:20 UTC", "30 September 2025 at 08:00 UTC", "App",
      "Also used for the menu bar and window titles. System Default follows the language set in System Settings.",
      "Colleague 003, colleague003@example.invalid", "Favorites",
      "Go To", "Known Tracking Pixels stay blocked for every remote-content policy.",
      "Loading remote images shows the sender your device's IP address and when you opened a message. Known tracking pixels are never loaded. These choices apply to this device only.",
      "Mailboxes", "Microsoft · casey@example.invalid", "On-device assistance is off.",
      "Rowan Hale, rowan@example.invalid", "Search. 1 message · All inboxes", "Selected Message",
      "September 2025",
      "Your product data is end-to-end encrypted. Only your trusted devices can read it.",
      "casey@example.invalid, other@example.invalid are connected on this device.",
    ],
  ]

  // The issue that owns each accessibility gap the audits still find, or why it is not the app's.
  private func knownAccessibilityGap(
    _ issue: XCUIAccessibilityAuditIssue, screen: String, textFocused: Bool
  ) -> String? {
    let type = issue.element?.elementType
    let label = issue.element?.label ?? ""
    // AppKit's Touch Bar for a focused text view.
    let touchBar =
      type == .touchBar || (type == .popUpButton && ["list style", "text alignment"].contains(label))
    switch issue.auditType {
    case .contrast where type == .staticText:
      return contrastGaps.first { $0.value.contains(label) }?.key
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
      && ["relay@privaterelay.example.invalid", "casey@example.invalid", "other@example.invalid"]
        .contains(label):
      return "email address"
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
    XCTAssertTrue(settings.buttons["Add another Gmail mailbox"].waitForExistence(timeout: 15))
    settings.buttons["Add another Gmail mailbox"].click()
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

  private func reportPerformance(
    _ groups: [PerformanceGroup],
    evidence: URL, overhead: Double
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
    let edits = records.filter { $0.event == "text-edit" }
    let draws = records.filter { $0.event == "text-drawn" }
    let presses = try times("mouse-down")
    let releases = try times("mouse-up")
    // Body requests the synthetic providers answered; priming the cache must have made some.
    let providerBodies = try times("provider-body")
    XCTAssertFalse(providerBodies.isEmpty, "The probe recorded no provider body request")
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
          let edit = try XCTUnwrap(
            edits.first {
              ($0.uptime ?? 0) >= start && $0.text?.hasPrefix(shown.text) == true
                && $0.marks?.hasPrefix(shown.marks) == true
            }, "No edit showed \(shown) for \(group.name)")
          let end = try XCTUnwrap(edit.uptime)
          let draw = try XCTUnwrap(
            draws.first { ($0.uptime ?? 0) >= end }, "No draw after \(shown) for \(group.name)")
          let drawEnd = try XCTUnwrap(draw.uptime)
          // A draw shows the body's latest edit; a result a later input replaced first never showed.
          let drawnEdit = edits.last { ($0.uptime ?? 0) <= drawEnd }
          XCTAssertTrue(
            drawnEdit?.text?.hasPrefix(shown.text) == true
              && drawnEdit?.marks?.hasPrefix(shown.marks) == true,
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
    attachment.name = "Warm-cache performance"
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
