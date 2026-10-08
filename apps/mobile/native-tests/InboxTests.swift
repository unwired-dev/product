import XCTest

// Synthetic completion proxy: reject failed writes and unfinished saves/syncs at each action.
// Optimistic rows and the encrypted cache alone cannot prove that Gmail accepted a change.
private func assertGmailActionsSettled(_ app: XCUIApplication) {
  let unconfirmed = app.staticTexts.matching(
    NSPredicate(
      format: "label MATCHES %@",
      "(?s).*(Gmail could not|Gmail has not confirmed|Gmail needs your permission|"
        + "waits? for Gmail|Organizing mail waits).*"))
  XCTAssertFalse(unconfirmed.firstMatch.waitForExistence(timeout: 5))
  let unfinished = app.staticTexts.matching(
    NSPredicate(
      format: "label CONTAINS %@ OR label CONTAINS %@",
      "Saving the change on this device", "Checking Gmail"))
  XCTAssertTrue(unfinished.firstMatch.waitForNonExistence(timeout: 10))
  XCTAssertFalse(unconfirmed.firstMatch.exists)
}

final class InboxTests: XCTestCase {
  private func registrationJourney(_ app: XCUIApplication) throws {
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["Connect your Gmail"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["Gmail connected"].exists)
    // A new Product Account presents its Recovery Key until setup is confirmed.
    let recoveryKey = app.staticTexts["recovery-key"]
    XCTAssertTrue(recoveryKey.waitForExistence(timeout: 15))
    let presented = recoveryKey.label
    XCTAssertEqual(presented.count, 64)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Connect your Gmail"].waitForExistence(timeout: 15))
    // Relaunch keeps the device-held keys; nothing is regenerated.
    XCTAssertEqual(app.staticTexts["recovery-key"].label, presented)
    app.buttons["Choose another Google mailbox"].tap()
    XCTAssertTrue(app.staticTexts["Gmail connected"].waitForExistence(timeout: 15))
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "other@example.invalid"))
        .firstMatch.exists)
    let entry = app.textFields["Last four characters"]
    entry.tap()
    entry.typeText(String(presented.suffix(4)) + "\n")
    app.buttons["Confirm Recovery Key"].tap()
    // Confirmed setup opens the synchronized Gmail Inbox, listed over two Gmail pages.
    let rowan = app.buttons["Unread. Rowan Hale. Garden plans for spring"]
    XCTAssertTrue(rowan.waitForExistence(timeout: 20))
    XCTAssertTrue(
      app.buttons["test@example.invalid. Welcome to your synthetic Inbox"].waitForExistence(
        timeout: 15))
    XCTAssertFalse(app.staticTexts["recovery-key"].exists)
    rowan.tap()
    XCTAssertTrue(app.staticTexts["rowan@example.invalid"].waitForExistence(timeout: 10))
    // The opened body arrives from Gmail as text; its image is not loaded.
    XCTAssertTrue(
      app.staticTexts["Images in this message are not loaded."].waitForExistence(timeout: 15))
    // The sanitized HTML renders inside the isolated WebKit view.
    XCTAssertTrue(
      app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "seed order"))
        .firstMatch.waitForExistence(timeout: 15))
    let bodyLink = app.descendants(matching: .any)
      .matching(identifier: "Open link: garden plan").firstMatch
    XCTAssertTrue(bodyLink.waitForExistence(timeout: 10))
    bodyLink.tap()
    XCTAssertTrue(app.staticTexts["Open this link in your browser?"].waitForExistence(timeout: 10))
    app.buttons["Cancel"].tap()
    // Organizing goes through the packaged native Gmail modify: a star, then an archive and Undo.
    app.buttons["Star"].tap()
    XCTAssertTrue(app.buttons["Remove star"].waitForExistence(timeout: 10))
    assertGmailActionsSettled(app)
    XCTAssertTrue(app.buttons["Remove star"].exists)
    app.buttons["Archive"].tap()
    XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 10))
    assertGmailActionsSettled(app)
    XCTAssertTrue(app.buttons["Undo"].exists)
    XCTAssertFalse(rowan.exists)
    app.buttons["Undo"].tap()
    XCTAssertTrue(rowan.waitForExistence(timeout: 15))
    assertGmailActionsSettled(app)
    XCTAssertTrue(rowan.exists)
    let inbox = XCTAttachment(screenshot: app.screenshot())
    inbox.name = "Synchronized Gmail Inbox"
    inbox.lifetime = .keepAlways
    add(inbox)
    app.terminate()
    app.launch()
    // Relaunch reopens the encrypted cache, then setup stays reachable from the Inbox.
    XCTAssertTrue(
      app.buttons["Unread. Rowan Hale. Garden plans for spring"].waitForExistence(timeout: 20))
    app.buttons["Account"].tap()
    XCTAssertTrue(app.staticTexts["Gmail connected"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Private sync is on"].exists)
    // The mailbox descriptor is read back and decrypted from Product Sync after relaunch.
    XCTAssertTrue(
      app.staticTexts["Encrypted mailbox list: other@example.invalid."].waitForExistence(
        timeout: 15))
    XCTAssertFalse(app.staticTexts["recovery-key"].exists)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Resumed Gmail registration"
    shot.lifetime = .keepAlways
    add(shot)
  }

  // Apple identifies the Product Account; Gmail access still needs its own Google grant.
  private func appleRegistrationJourney(_ app: XCUIApplication) {
    app.buttons["Sign in with Apple"].tap()
    XCTAssertTrue(app.staticTexts["Connect your Gmail"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["Gmail connected"].exists)
    let contact = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "relay@privaterelay.example.invalid")
    ).firstMatch
    XCTAssertTrue(contact.exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Connect your Gmail"].waitForExistence(timeout: 15))
    app.buttons["Authorize Gmail"].tap()
    XCTAssertTrue(app.staticTexts["Gmail connected"].waitForExistence(timeout: 15))
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "other@example.invalid"))
        .firstMatch.exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Gmail connected"].waitForExistence(timeout: 15))
    XCTAssertTrue(contact.exists)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Apple registration with Gmail"
    shot.lifetime = .keepAlways
    add(shot)
  }

  // Linking verifies both identities; the Gmail grant never becomes a sign-in method.
  private func linkJourney(_ app: XCUIApplication) {
    app.buttons["Sign in with Apple"].tap()
    XCTAssertTrue(app.staticTexts["Gmail connected"].waitForExistence(timeout: 15))
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "Only Apple opens this Product Account")
      ).firstMatch.exists)
    app.buttons["Link Google sign-in"].tap()
    let linked = app.staticTexts["Sign in with Apple or Google to open this Product Account."]
    XCTAssertTrue(linked.waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["Link Google sign-in"].exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(linked.waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Gmail connected"].exists)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Linked Apple and Google sign-in"
    shot.lifetime = .keepAlways
    add(shot)
  }

  // A new device of an existing account waits until a trusted device approves it; signing in alone
  // admits nothing, so Gmail authorization appears only afterwards.
  private func enrollmentJourney(_ app: XCUIApplication) {
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["Approve this device"].waitForExistence(timeout: 15))
    let code = app.staticTexts["enrollment-code"]
    XCTAssertTrue(code.exists)
    XCTAssertEqual(code.label.count, 69)
    XCTAssertFalse(app.staticTexts["recovery-key"].exists)
    XCTAssertFalse(app.buttons["Authorize Gmail"].exists)
    XCTAssertFalse(app.buttons["Choose another Google mailbox"].exists)
    let mailboxes = app.staticTexts["Encrypted mailbox list: alex@example.invalid."]
    XCTAssertFalse(mailboxes.exists)
    // The synthetic trusted device approves with the code shown on this device.
    app.buttons["Check for approval"].tap()
    XCTAssertTrue(app.staticTexts["Private sync is on"].waitForExistence(timeout: 15))
    XCTAssertTrue(mailboxes.exists)
    XCTAssertFalse(code.exists)
    // Gmail on this device still needs its own authorization.
    XCTAssertTrue(app.staticTexts["Connect your Gmail"].exists)
    XCTAssertTrue(app.buttons["Authorize Gmail"].exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Private sync is on"].waitForExistence(timeout: 15))
    XCTAssertTrue(mailboxes.waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["enrollment-code"].exists)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Approved new device"
    shot.lifetime = .keepAlways
    add(shot)
  }

  // Without a trusted device, the Recovery Key admits this device and unlocks the account's keys.
  private func recoveryJourney(_ app: XCUIApplication) {
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["Use your Recovery Key"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["enrollment-code"].exists)
    XCTAssertFalse(app.buttons["Authorize Gmail"].exists)
    let mailboxes = app.staticTexts["Encrypted mailbox list: alex@example.invalid."]
    XCTAssertFalse(mailboxes.exists)
    // The synthetic account's written Recovery Key, typed as the person would.
    let entry = app.textFields["Recovery Key"]
    entry.tap()
    entry.typeText("000G-40R4-0M30-E209-185G-R38E-1W81-24GK-2GAH-C5RR-34D1-P70X-3RFG\n")
    app.buttons["Unlock with Recovery Key"].tap()
    XCTAssertTrue(app.staticTexts["Private sync is on"].waitForExistence(timeout: 15))
    XCTAssertTrue(mailboxes.exists)
    XCTAssertFalse(app.staticTexts["enrollment-code"].exists)
    // Gmail on this device still needs its own authorization.
    XCTAssertTrue(app.buttons["Authorize Gmail"].exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Private sync is on"].waitForExistence(timeout: 15))
    XCTAssertTrue(mailboxes.waitForExistence(timeout: 15))
    XCTAssertFalse(app.textFields["Recovery Key"].exists)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Recovered with the Recovery Key"
    shot.lifetime = .keepAlways
    add(shot)
  }

  private func text(_ value: String, in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
  }

  // This device created the keys; removing the account's iPad rotates them and replaces the
  // Recovery Key, which is confirmed like the first one.
  private func revocationJourney(_ app: XCUIApplication) {
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["recovery-key"].waitForExistence(timeout: 15))
    let first = app.staticTexts["recovery-key"].label
    let initialEntry = app.textFields["Last four characters"]
    initialEntry.tap()
    initialEntry.typeText(String(first.suffix(4)) + "\n")
    app.buttons["Confirm Recovery Key"].tap()
    XCTAssertTrue(app.buttons["Remove iPad"].waitForExistence(timeout: 15))
    app.buttons["Remove iPad"].tap()
    XCTAssertTrue(text("cannot be erased remotely", in: app).waitForExistence(timeout: 15))
    app.buttons["Remove iPad"].tap()
    XCTAssertTrue(text("The device was removed.", in: app).waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["Remove iPad"].exists)
    let replaced = app.staticTexts["recovery-key"].label
    XCTAssertEqual(replaced.count, 64)
    XCTAssertNotEqual(replaced, first)
    let entry = app.textFields["Last four characters"]
    entry.tap()
    entry.typeText(String(replaced.suffix(4)) + "\n")
    app.buttons["Confirm Recovery Key"].tap()
    XCTAssertTrue(app.staticTexts["Private sync is on"].waitForExistence(timeout: 15))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Private sync is on"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["Remove iPad"].exists)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Removed another trusted device"
    shot.lifetime = .keepAlways
    add(shot)
  }

  // Another device removed this one: the relaunch purges the account and explains it.
  private func revokedJourney(_ app: XCUIApplication) {
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["Connect your Gmail"].waitForExistence(timeout: 15))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["This device was removed"].waitForExistence(timeout: 20))
    XCTAssertTrue(text("cannot be erased remotely", in: app).exists)
    XCTAssertFalse(app.staticTexts["recovery-key"].exists)
    let removed = XCTAttachment(screenshot: app.screenshot())
    removed.name = "Removed by another trusted device"
    removed.lifetime = .keepAlways
    add(removed)
    // A fresh sign-in mints a new device identifier, which waits for a trusted device or the
    // Recovery Key like any new device; it gets no mailbox access meanwhile.
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["Approve this device"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["enrollment-code"].exists)
    XCTAssertTrue(app.staticTexts["Use your Recovery Key"].exists)
    XCTAssertTrue(app.buttons["Check for approval"].exists)
    XCTAssertFalse(app.buttons["Authorize Gmail"].exists)
    XCTAssertFalse(text("This device cannot join", in: app).exists)
    let gate = XCTAttachment(screenshot: app.screenshot())
    gate.name = "New device waiting for approval after a removal"
    gate.lifetime = .keepAlways
    add(gate)
    // Signing out of the gate leaves nothing of the account on this device.
    app.buttons["Sign out of this device"].tap()
    XCTAssertTrue(text("Your other devices", in: app).waitForExistence(timeout: 15))
    app.buttons["Sign out of this device"].tap()
    XCTAssertTrue(app.staticTexts["Welcome to Unwired Mail"].waitForExistence(timeout: 15))
  }

  // Sign-out keeps nothing of the account on this device; deletion ends the account everywhere.
  private func removalJourney(_ app: XCUIApplication) {
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["recovery-key"].waitForExistence(timeout: 15))
    let key = app.staticTexts["recovery-key"].label
    let entry = app.textFields["Last four characters"]
    entry.tap()
    entry.typeText(String(key.suffix(4)) + "\n")
    app.buttons["Confirm Recovery Key"].tap()
    XCTAssertTrue(app.staticTexts["Private sync is on"].waitForExistence(timeout: 15))
    app.buttons["Sign out of this device"].tap()
    XCTAssertTrue(text("Your other devices", in: app).waitForExistence(timeout: 15))
    app.buttons["Sign out of this device"].tap()
    XCTAssertTrue(app.staticTexts["Welcome to Unwired Mail"].waitForExistence(timeout: 15))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Welcome to Unwired Mail"].waitForExistence(timeout: 20))
    // The keys left with the sign-out, so the account must approve this device again.
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["Approve this device"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["recovery-key"].exists)
    app.buttons["Delete Product Account"].tap()
    XCTAssertTrue(text("cannot be undone", in: app).waitForExistence(timeout: 15))
    app.buttons["Delete permanently"].tap()
    XCTAssertTrue(app.staticTexts["Product Account deleted"].waitForExistence(timeout: 15))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Welcome to Unwired Mail"].waitForExistence(timeout: 20))
    // The deleted account cannot be reopened, and this device keeps nothing of it.
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["Product Account deleted"].waitForExistence(timeout: 15))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Deleted Product Account"
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testSelectAndReplaceMessage() throws {
    continueAfterFailure = false
    let identifier = try XCTUnwrap(ProcessInfo.processInfo.environment["UNWIRED_BUNDLE_ID"])
    let app = XCUIApplication(bundleIdentifier: identifier)
    addTeardownBlock { if app.state != .notRunning { app.terminate() } }
    app.launch()
    if ProcessInfo.processInfo.environment["UNWIRED_TEST_SCENARIO"]?.hasPrefix("registration-")
      == true
    {
      XCTAssertTrue(app.staticTexts["Welcome to Unwired Mail"].waitForExistence(timeout: 20))
      switch ProcessInfo.processInfo.environment["UNWIRED_TEST_SCENARIO"] {
      case "registration-apple": appleRegistrationJourney(app)
      case "registration-link": linkJourney(app)
      case "registration-enrollment": enrollmentJourney(app)
      case "registration-recovery": recoveryJourney(app)
      case "registration-revocation": revocationJourney(app)
      case "registration-revoked": revokedJourney(app)
      case "registration-removal": removalJourney(app)
      default:
        try registrationJourney(app)
      }
      return
    }
    inboxJourney(app)
  }

  private func inboxJourney(_ app: XCUIApplication) {
    XCTAssertTrue(app.staticTexts["Inbox"].waitForExistence(timeout: 20))
    let maya = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Maya Chen"))
      .firstMatch
    XCTAssertTrue(maya.waitForExistence(timeout: 10))
    XCTAssertTrue(maya.label.hasPrefix("Unread."))
    maya.tap()
    let sender = app.staticTexts.matching(identifier: "maya@example.com").firstMatch
    XCTAssertTrue(sender.waitForExistence(timeout: 10))
    if UIDevice.current.userInterfaceIdiom == .pad {
      XCTAssertGreaterThan(sender.frame.minX, maya.frame.maxX)
    }
    // A summary runs only when asked, through the packaged assistance bridge, whose synthetic
    // model answers in this build.
    app.buttons["Summarize this message"].tap()
    XCTAssertTrue(app.staticTexts["Synthetic summary of local mail."].waitForExistence(timeout: 10))
    app.buttons["Dismiss summary"].tap()
    XCTAssertTrue(app.buttons["Summarize this message"].waitForExistence(timeout: 10))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Selected message"
    shot.lifetime = .keepAlways
    add(shot)
    let oliver = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Oliver Park"))
      .firstMatch
    if !oliver.exists || !oliver.isHittable {
      let back = app.navigationBars.buttons.firstMatch
      XCTAssertTrue(back.exists)
      back.tap()
    }
    XCTAssertTrue(oliver.isHittable)
    XCTAssertTrue(oliver.label.hasPrefix("Unread."))
    oliver.tap()
    XCTAssertTrue(app.staticTexts["oliver@example.com"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["maya@example.com"].exists)
    app.buttons["Mark as read"].tap()
    XCTAssertTrue(app.buttons["Mark as unread"].waitForExistence(timeout: 10))
    let committed = XCTAttachment(screenshot: app.screenshot())
    committed.name = "Committed read state"
    committed.lifetime = .keepAlways
    add(committed)
    app.terminate()
    app.launch()
    let restored = app.buttons["Oliver Park. Saturday, by the river?"]
    XCTAssertTrue(restored.waitForExistence(timeout: 20))
    XCTAssertFalse(restored.label.hasPrefix("Unread."))
    restored.tap()
    XCTAssertTrue(app.buttons["Mark as unread"].waitForExistence(timeout: 10))
    let recovered = XCTAttachment(screenshot: app.screenshot())
    recovered.name = "Read state after relaunch"
    recovered.lifetime = .keepAlways
    add(recovered)
  }
}
