import CoreFoundation
import CryptoKit
import UIKit
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
  private func swipeBack(_ app: XCUIApplication, commit: Bool = true) {
    let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5))
    edge.press(
      forDuration: 0.05,
      thenDragTo:
        app.coordinate(withNormalizedOffset: CGVector(dx: commit ? 0.85 : 0.12, dy: 0.5)),
      withVelocity: commit ? .default : .slow, thenHoldForDuration: commit ? 0 : 0.3)
  }

  private func registrationJourney(_ app: XCUIApplication) throws {
    app.buttons["Continue"].tap()
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["Connect your mail"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["Gmail connected"].exists)
    // A new Product Account presents its Recovery Key until setup is confirmed.
    let recoveryKey = app.staticTexts["recovery-key"]
    XCTAssertTrue(recoveryKey.waitForExistence(timeout: 15))
    let presented = recoveryKey.label
    XCTAssertEqual(presented.count, 64)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Connect your mail"].waitForExistence(timeout: 15))
    // Relaunch keeps the device-held keys; nothing is regenerated.
    XCTAssertEqual(app.staticTexts["recovery-key"].label, presented)
    app.buttons["Choose another Google mailbox"].tap()
    // Pending setup opens Settings on Account & Devices.
    XCTAssertTrue(text("connected on this device", in: app).waitForExistence(timeout: 15))
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "other@example.invalid"))
        .firstMatch.exists)
    let entry = app.textFields["Last four characters"]
    enter(String(presented.suffix(4)), into: entry, in: app)
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
      text("Images in this message are not loaded.", in: app).waitForExistence(timeout: 15))
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
    // Organizing goes through the packaged native Gmail modify: a star from the actions panel, then
    // an archive and Undo.
    let phone = UIDevice.current.userInterfaceIdiom == .phone
    app.buttons[phone ? "Reply" : "More"].tap()
    app.buttons["Star"].tap()
    if phone { app.buttons["Reply"].tap() }
    XCTAssertTrue(app.buttons["Remove star"].waitForExistence(timeout: 10))
    assertGmailActionsSettled(app)
    XCTAssertTrue(app.buttons["Remove star"].exists)
    if phone { app.buttons["Close"].tap() }
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
    // The account page opens from the Mailboxes column; on iPhone that column is one Back away.
    let account = app.buttons["Account"]
    if !account.waitForExistence(timeout: 5) || !account.isHittable {
      if phone { swipeBack(app) } else { app.navigationBars.buttons.firstMatch.tap() }
    }
    XCTAssertTrue(account.waitForExistence(timeout: 10))
    account.tap()
    openSettings("Account & Devices", in: app)
    XCTAssertTrue(text("connected on this device", in: app).waitForExistence(timeout: 15))
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
    if phone {
      swipeBack(app, commit: false)
      XCTAssertFalse(app.buttons["Back to Settings"].waitForNonExistence(timeout: 3))
      swipeBack(app)
      XCTAssertTrue(app.buttons["Account & Devices"].waitForExistence(timeout: 10))
      XCTAssertFalse(app.buttons["Back to Settings"].exists)
      // The detail gesture consumed one level; the native containing stack still dismisses next.
      swipeBack(app)
      XCTAssertTrue(app.buttons["Account"].waitForExistence(timeout: 10))
    }
  }

  // Apple identifies the Product Account; each mailbox needs its own grant. Microsoft mail can be
  // the first one, without Gmail; Gmail is added beside it with a Google grant.
  private func appleRegistrationJourney(_ app: XCUIApplication) {
    app.buttons["Continue"].tap()
    app.buttons["Sign in with Apple"].tap()
    XCTAssertTrue(app.staticTexts["Connect your mail"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["Gmail connected"].exists)
    let contact = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "relay@privaterelay.example.invalid")
    ).firstMatch
    XCTAssertTrue(contact.exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Connect your mail"].waitForExistence(timeout: 15))
    app.buttons["Microsoft 365 and Outlook"].tap()
    XCTAssertTrue(text("connected on this device", in: app).waitForExistence(timeout: 15))
    XCTAssertTrue(text("casey@example.invalid", in: app).exists)
    openSettings("Email Accounts", in: app)
    XCTAssertTrue(app.buttons["Add another Gmail mailbox"].waitForExistence(timeout: 15))
    app.buttons["Add another Gmail mailbox"].tap()
    XCTAssertTrue(text("other@example.invalid", in: app).waitForExistence(timeout: 15))
    openSettings("Account & Devices", in: app)
    // Confirmed setup opens the unified Inbox: the Microsoft message reads through packaged Graph
    // beside Gmail's.
    let entry = app.textFields["Last four characters"]
    enter(String(app.staticTexts["recovery-key"].label.suffix(4)), into: entry, in: app)
    app.buttons["Confirm Recovery Key"].tap()
    // The account page stays open until the person chooses the Inbox.
    XCTAssertTrue(app.staticTexts["Private sync is on"].waitForExistence(timeout: 15))
    app.buttons["Open Inbox"].tap()
    // The unified Inbox names each message's mailbox.
    let jordan = app.buttons.matching(
      NSPredicate(
        format: "label CONTAINS %@", "Jordan Lee. Quarterly planning. In casey@example.invalid")
    ).firstMatch
    XCTAssertTrue(jordan.waitForExistence(timeout: 20))
    XCTAssertTrue(
      app.buttons.matching(
        NSPredicate(
          format: "label CONTAINS %@", "Rowan Hale. Garden plans for spring. In other@example.invalid")
      ).firstMatch.waitForExistence(timeout: 15))
    jordan.tap()
    XCTAssertTrue(app.staticTexts["jordan@example.invalid"].waitForExistence(timeout: 10))
    XCTAssertTrue(text("Agenda for Thursday.", in: app).waitForExistence(timeout: 15))
    if UIDevice.current.userInterfaceIdiom == .phone {
      // Landscape leaves little room above the keyboard; Search and its explanation stay reachable.
      XCUIDevice.shared.orientation = .landscapeLeft
      let landscape = NSPredicate { _, _ in
        app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
      }
      XCTAssertEqual(
        XCTWaiter.wait(
          for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 5),
        .completed)
      app.buttons["Reply"].tap()
      let actions = app.scrollViews.containing(.button, identifier: "Reply All").firstMatch
      let move = actions.buttons["Folders"]
      XCTAssertTrue(move.waitForExistence(timeout: 10))
      move.tap()
      XCTAssertTrue(
        app.staticTexts["Move this message to another folder."].waitForExistence(timeout: 10))
      let search = app.textFields["Search"]
      search.tap()
      let keyboard = app.keyboards.firstMatch
      XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
      for character in "missing folder" { search.typeText(String(character)) }
      let noMatch = text("No folders match your search.", in: app)
      XCTAssertTrue(noMatch.waitForExistence(timeout: 5))
      let folders = app.scrollViews.containing(
        .staticText, identifier: "No folders match your search."
      ).firstMatch
      XCTAssertGreaterThanOrEqual(folders.frame.height, 44)
      // A default swipe across a short viewport can become a tap-length gesture.
      for _ in 0..<5 where !folders.frame.contains(noMatch.frame) {
        folders.swipeUp(velocity: .slow)
        XCTAssertTrue(keyboard.exists)
      }
      XCTAssertTrue(folders.frame.contains(noMatch.frame))
      XCTAssertTrue(noMatch.isHittable)
      XCTAssertLessThanOrEqual(noMatch.frame.maxY, keyboard.frame.minY)
      XCTAssertLessThanOrEqual(search.frame.maxY, keyboard.frame.minY)
      let sheet = XCTAttachment(screenshot: app.screenshot())
      sheet.name = "Move sheet no-match search above the keyboard"
      sheet.lifetime = .keepAlways
      add(sheet)
      app.buttons["Close"].tap()
      XCTAssertTrue(
        app.staticTexts["Move this message to another folder."].waitForNonExistence(timeout: 5))
      XCUIDevice.shared.orientation = .portrait
    }
    app.terminate()
    app.launch()
    // Relaunch reopens the account page, then the encrypted Microsoft cache and its message.
    XCTAssertTrue(text("connected on this device", in: app).waitForExistence(timeout: 20))
    XCTAssertTrue(text("casey@example.invalid", in: app).exists)
    XCTAssertTrue(contact.exists)
    app.buttons["Open Inbox"].tap()
    XCTAssertTrue(jordan.waitForExistence(timeout: 20))
    jordan.tap()
    XCTAssertTrue(app.staticTexts["jordan@example.invalid"].waitForExistence(timeout: 10))
    XCTAssertTrue(text("Agenda for Thursday.", in: app).waitForExistence(timeout: 15))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Apple registration with Microsoft mail and Gmail"
    shot.lifetime = .keepAlways
    add(shot)
  }

  // Linking verifies both identities; the Gmail grant never becomes a sign-in method.
  private func linkJourney(_ app: XCUIApplication) {
    app.buttons["Continue"].tap()
    app.buttons["Sign in with Apple"].tap()
    // Sign-in connects no mailbox; Gmail is chosen explicitly.
    XCTAssertTrue(app.buttons["Gmail"].waitForExistence(timeout: 15))
    app.buttons["Gmail"].tap()
    XCTAssertTrue(text("connected on this device", in: app).waitForExistence(timeout: 15))
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
    XCTAssertTrue(text("connected on this device", in: app).exists)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Linked Apple and Google sign-in"
    shot.lifetime = .keepAlways
    add(shot)
  }

  // A new device of an existing account waits until a trusted device approves it; signing in alone
  // admits nothing, so Gmail authorization appears only afterwards.
  private func enrollmentJourney(_ app: XCUIApplication) {
    app.buttons["Continue"].tap()
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["Approve this device"].waitForExistence(timeout: 15))
    let code = app.staticTexts["enrollment-code"]
    XCTAssertTrue(code.exists)
    XCTAssertEqual(code.label.count, 69)
    XCTAssertFalse(app.staticTexts["recovery-key"].exists)
    XCTAssertFalse(app.buttons["Gmail"].exists)
    XCTAssertFalse(app.buttons["Choose another Google mailbox"].exists)
    let mailboxes = app.staticTexts["Encrypted mailbox list: alex@example.invalid."]
    XCTAssertFalse(mailboxes.exists)
    // The synthetic trusted device approves with the code shown on this device.
    app.buttons["Check for approval"].tap()
    XCTAssertTrue(app.staticTexts["Private sync is on"].waitForExistence(timeout: 15))
    XCTAssertTrue(mailboxes.exists)
    XCTAssertFalse(code.exists)
    // Gmail on this device still needs its own authorization.
    XCTAssertTrue(app.staticTexts["Connect your mail"].exists)
    XCTAssertTrue(app.buttons["Gmail"].exists)
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
    app.buttons["Continue"].tap()
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["Use your Recovery Key"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["enrollment-code"].exists)
    XCTAssertFalse(app.buttons["Gmail"].exists)
    let mailboxes = app.staticTexts["Encrypted mailbox list: alex@example.invalid."]
    XCTAssertFalse(mailboxes.exists)
    // The synthetic account's written Recovery Key, typed as the person would.
    let entry = app.textFields["Recovery Key"]
    enter("000G-40R4-0M30-E209-185G-R38E-1W81-24GK-2GAH-C5RR-34D1-P70X-3RFG", into: entry, in: app)
    app.buttons["Unlock with Recovery Key"].tap()
    XCTAssertTrue(app.staticTexts["Private sync is on"].waitForExistence(timeout: 15))
    XCTAssertTrue(mailboxes.exists)
    XCTAssertFalse(app.staticTexts["enrollment-code"].exists)
    // Gmail on this device still needs its own authorization.
    XCTAssertTrue(app.buttons["Gmail"].exists)
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

  // A long Thread cold-opened from its deep link at an older message: it scrolls to that message,
  // keeps it in place while the taller newer bodies above it load, and mounts a body only while it
  // is within one screen of the visible range.
  private func threadJourney(_ app: XCUIApplication) {
    app.buttons["Continue"].tap()
    app.buttons["Sign in with Google"].tap()
    let recoveryKey = app.staticTexts["recovery-key"]
    XCTAssertTrue(recoveryKey.waitForExistence(timeout: 15))
    let presented = recoveryKey.label
    app.buttons["Choose another Google mailbox"].tap()
    XCTAssertTrue(text("connected on this device", in: app).waitForExistence(timeout: 15))
    enter(String(presented.suffix(4)), into: app.textFields["Last four characters"], in: app)
    app.buttons["Confirm Recovery Key"].tap()
    let rowan = app.buttons["Unread. Rowan Hale. Garden plans for spring"]
    let visibleMessage = {
      app.buttons.matching(
        NSPredicate(
          format: "label CONTAINS %@ OR label CONTAINS %@",
          "Garden plans for spring", "Trail maintenance")
      ).allElementsBoundByIndex.contains { $0.isHittable }
    }
    XCTAssertTrue(rowan.waitForExistence(timeout: 20))
    if UIDevice.current.userInterfaceIdiom == .phone { verifyInboxViewport(app) }
    waitUntil(visibleMessage)
    // Unlike the preview journey, this opens through the production account/Settings container.
    // A completed account must cold-launch on its message list, with no extra Account action.
    app.terminate()
    app.launch()
    XCTAssertTrue(rowan.waitForExistence(timeout: 20))
    if UIDevice.current.userInterfaceIdiom == .phone { verifyInboxViewport(app) }
    waitUntil(visibleMessage)
    if UIDevice.current.userInterfaceIdiom == .phone {
      let back = app.buttons["Back to Mailboxes"]
      let title = app.staticTexts["Inbox"].firstMatch
      let listReady = {
        visibleMessage() && back.isHittable && title.exists && !title.frame.isEmpty
          && app.windows.firstMatch.frame.contains(title.frame)
      }
      waitUntil(listReady)
      let mailboxes = app.otherElements["mailboxes-screen"].firstMatch
      swipeBack(app, commit: false)
      XCTAssertFalse(app.buttons["All inboxes"].waitForExistence(timeout: 3))
      XCTAssertTrue(listReady())
      swipeBack(app)
      waitUntil { app.buttons["All inboxes"].isHittable }
      let viewport = app.windows.firstMatch.frame
      XCTAssertEqual(mailboxes.frame.width, viewport.width, accuracy: 1)
      XCTAssertEqual(mailboxes.frame.height, viewport.height, accuracy: 1)
      let fullScreenMailboxes = XCTAttachment(screenshot: app.screenshot())
      fullScreenMailboxes.name = "Dark full-screen Mailboxes after native Back"
      fullScreenMailboxes.lifetime = .keepAlways
      add(fullScreenMailboxes)
      XCUIDevice.shared.orientation = .landscapeLeft
      waitUntil { app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }
      for destination in ["Mailboxes", "Inbox"] {
        let screen =
          destination == "Mailboxes" ? mailboxes : app.otherElements["inbox-screen"].firstMatch
        let content = app.otherElements[
          destination == "Mailboxes" ? "mailboxes-content" : "inbox-content"
        ].firstMatch
        waitUntil {
          content.exists && content.frame.width > content.frame.height
            && screen.frame == app.windows.firstMatch.frame
        }
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(screen.frame.width, window.width, accuracy: 1)
        XCTAssertEqual(screen.frame.height, window.height, accuracy: 1)
        XCTAssertGreaterThan(content.frame.minX, window.minX)
        XCTAssertLessThan(content.frame.maxX, window.maxX)
        let safeLandscape = XCTAttachment(screenshot: app.screenshot())
        safeLandscape.name = "Landscape \(destination) with horizontal safe insets"
        safeLandscape.lifetime = .keepAlways
        add(safeLandscape)
        if destination == "Mailboxes" {
          app.buttons["All inboxes"].tap()
          verifyInboxViewport(app)
          waitUntil(listReady)
        }
      }
      XCUIDevice.shared.orientation = .portrait
      waitUntil { app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width }
      verifyInboxViewport(app)
      waitUntil(listReady)
      // The reported black screen begins when opening the list, before selecting a message.
      for destination in ["All inboxes", "Account"] {
        back.tap()
        let entry = app.buttons[destination]
        waitUntil { entry.isHittable }
        entry.tap()
        if destination == "Account" {
          let settings = app.staticTexts["Settings"].firstMatch
          XCTAssertTrue(settings.waitForExistence(timeout: 10))
          app.buttons["Account & Devices"].tap()
          XCTAssertTrue(app.buttons["Back to Settings"].waitForExistence(timeout: 10))
          app.buttons["Back to Settings"].tap()
          XCTAssertTrue(settings.waitForExistence(timeout: 10))
          app.buttons["Account & Devices"].tap()
          swipeBack(app)
          XCTAssertTrue(settings.waitForExistence(timeout: 10))
          let openInbox = app.buttons["Open Inbox"]
          waitUntil { openInbox.isHittable }
          openInbox.tap()
        }
        waitUntil(listReady)
        let list = XCTAttachment(screenshot: app.screenshot())
        list.name = "Dark Inbox list after Mailboxes, \(destination)"
        list.lifetime = .keepAlways
        add(list)
      }
      // Mailboxes must return to the same scrolled list, not a fresh initial viewport.
      let messages = app.scrollViews.containing(
        .button, identifier: "Unread. Rowan Hale. Garden plans for spring"
      ).firstMatch
      let initialRowY = rowan.frame.minY
      messages.swipeUp(velocity: .slow)
      waitUntil { rowan.isHittable && abs(rowan.frame.minY - initialRowY) > 1 }
      let retainedRowY = rowan.frame.minY
      back.tap()
      waitUntil { app.buttons["All inboxes"].isHittable }
      app.buttons["All inboxes"].tap()
      verifyInboxViewport(app)
      waitUntil { rowan.isHittable && abs(rowan.frame.minY - retainedRowY) <= 1 }
      XCTAssertEqual(rowan.frame.minY, retainedRowY, accuracy: 1)
      let search = app.searchFields["Search senders and subjects"]
      search.tap()
      search.typeText("Rowan")
      waitUntil { app.buttons["Close Search"].isHittable && rowan.isHittable }
      swipeBack(app)
      waitUntil { app.buttons["All inboxes"].isHittable }
      app.buttons["All inboxes"].tap()
      waitUntil { search.value as? String == "Rowan" && rowan.isHittable }
      XCTAssertTrue(app.buttons["Close Search"].isHittable)
      app.buttons["Close Search"].tap()
    } else {
      let account = app.buttons["Account"]
      if !account.waitForExistence(timeout: 5) || !account.isHittable {
        app.navigationBars.buttons.firstMatch.tap()
      }
      XCTAssertTrue(account.waitForExistence(timeout: 10))
      account.tap()
      XCTAssertTrue(text("connected on this device", in: app).waitForExistence(timeout: 15))
      XCTAssertTrue(app.buttons["Sign out of this device"].exists)
      let accountDetails = XCTAttachment(screenshot: app.screenshot())
      accountDetails.name = "iPad Account opens its default details"
      accountDetails.lifetime = .keepAlways
      add(accountDetails)
      app.buttons["Open Inbox"].tap()
      waitUntil(visibleMessage)
    }
    for attempt in 1...3 {
      let messages = app.scrollViews.containing(
        .button, identifier: "Unread. Rowan Hale. Garden plans for spring"
      ).firstMatch
      for _ in 0..<8 where !rowan.isHittable {
        messages.swipeUp(velocity: .slow)
      }
      XCTAssertTrue(rowan.isHittable)
      rowan.tap()
      let sender = app.staticTexts["rowan@example.invalid"].firstMatch
      XCTAssertTrue(sender.waitForExistence(timeout: 10))
      XCTAssertTrue(app.buttons["Archive"].isHittable)
      XCTAssertTrue(
        app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "seed order"))
          .firstMatch.waitForExistence(timeout: 15))
      let reader = XCTAttachment(screenshot: app.screenshot())
      reader.name = "Dark production reader, open \(attempt)"
      reader.lifetime = .keepAlways
      add(reader)
      if UIDevice.current.userInterfaceIdiom == .phone {
        app.buttons.matching(
          NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Back", "Back,")
        ).firstMatch.tap()
        waitUntil { rowan.isHittable }
        verifyInboxViewport(app)
        XCTAssertFalse(sender.exists)
      } else if attempt < 3 {
        // Selecting the same iPad row keeps its reader, so relaunch before the next opening.
        app.terminate()
        app.launch()
        XCTAssertTrue(rowan.waitForExistence(timeout: 20))
        waitUntil(visibleMessage)
        XCTAssertFalse(sender.exists)
      }
    }
    // The connection's opaque ID, as native code derives it from the synthetic Gmail subject.
    let connection = SHA256.hash(
      data: Data("dev.unwired.mailbox-connection\nsynthetic-alternate-mailbox".utf8)
    ).prefix(16).map { String(format: "%02x", $0) }.joined()
    app.terminate()
    app.open(URL(string: "unwired-mail://thread/19a0c0ffee000013?mailbox=\(connection)")!)
    let opened = app.staticTexts["crew3@example.invalid"].firstMatch
    XCTAssertTrue(opened.waitForExistence(timeout: 20))
    XCTAssertTrue(app.staticTexts["6 Messages"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Crew 3, note 2."].waitForExistence(timeout: 20))
    let window = app.windows.firstMatch.frame
    // On screen by frame: the header's text sits inside its context-menu host, so it is never
    // reported hittable.
    let onScreen = { (element: XCUIElement) in
      element.exists && window.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
    }
    waitUntil { onScreen(opened) }
    let anchored = opened.frame.minY
    XCTAssertLessThan(anchored, window.midY)
    // Drag into Crew 3 while Crew 4's full-body reply is held outside native registration custody.
    XCTAssertFalse(app.staticTexts["Crew 4, note 40."].exists)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
      .press(forDuration: 0.1, thenDragTo:
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
    let visibleText = (2...35).map { app.staticTexts["Crew 3, note \($0)."].firstMatch }
      .first { onScreen($0) && $0.frame.midY > window.midY }
    XCTAssertNotNil(visibleText)
    guard let visibleText else { return }
    let textOffset = visibleText.frame.minY
    let identifier = ProcessInfo.processInfo.environment["UNWIRED_BUNDLE_ID"]!
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName((identifier + ".thread-body-release") as CFString), nil, nil, true)
    XCTAssertTrue(app.staticTexts["Crew 4, note 40."].waitForExistence(timeout: 20))
    waitUntil { abs(visibleText.frame.minY - textOffset) <= 2 }
    XCTAssertEqual(visibleText.frame.minY, textOffset, accuracy: 2)
    // Crew 6 lies more than a screen above once Crew 4 and 5 have loaded, so its body unmounts.
    waitUntil { !app.staticTexts["Crew 6, note 40."].exists }
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Thread opened at an older message"
    shot.lifetime = .keepAlways
    add(shot)
    // Scrolling back to the newest message mounts its body again.
    let newest = app.staticTexts["crew6@example.invalid"].firstMatch
    for _ in 0..<30 where !onScreen(newest) {
      app.swipeDown(velocity: .fast)
    }
    XCTAssertTrue(onScreen(newest))
    XCTAssertTrue(app.staticTexts["Crew 6, note 2."].waitForExistence(timeout: 20))
    let top = XCTAttachment(screenshot: app.screenshot())
    top.name = "Thread scrolled to its newest message"
    top.lifetime = .keepAlways
    add(top)
    if UIDevice.current.userInterfaceIdiom == .phone {
      swipeBack(app)
      XCTAssertTrue(
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Rowan Hale"))
          .firstMatch.waitForExistence(timeout: 10))
      XCTAssertFalse(app.staticTexts["6 Messages"].exists)
    }
  }

  private func text(_ value: String, in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
  }

  // Types into a controlled field one character at a time, confirming each reached it before the
  // next: the software keyboard drops characters typed while the field re-renders.
  private func enter(_ value: String, into field: XCUIElement, in app: XCUIApplication) {
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
    var confirmation = ""
    for character in value {
      field.typeText(String(character))
      confirmation += String(character)
      let entered = NSPredicate(format: "value == %@", confirmation)
      XCTAssertEqual(
        XCTWaiter.wait(
          for: [XCTNSPredicateExpectation(predicate: entered, object: field)], timeout: 5),
        .completed)
    }
    field.typeText("\n")
  }

  // Opens a Settings destination: iPad selects it in the sidebar; iPhone returns to the list of
  // destinations, then pushes it.
  private func openSettings(_ destination: String, in app: XCUIApplication) {
    let back = app.buttons["Back to Settings"]
    if back.exists {
      back.tap()
    }
    let item = app.buttons[destination]
    XCTAssertTrue(item.waitForExistence(timeout: 15))
    item.tap()
  }

  // This device created the keys; removing the account's iPad first proposes a replacement
  // Recovery Key, and only its confirmation removes the device and rotates the keys.
  private func revocationJourney(_ app: XCUIApplication) {
    app.buttons["Continue"].tap()
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["recovery-key"].waitForExistence(timeout: 15))
    let first = app.staticTexts["recovery-key"].label
    let initialEntry = app.textFields["Last four characters"]
    enter(String(first.suffix(4)), into: initialEntry, in: app)
    app.buttons["Confirm Recovery Key"].tap()
    let proposed = app.staticTexts["revocation-recovery-key"]
    func prepare() {
      XCTAssertTrue(app.buttons["Remove iPad"].waitForExistence(timeout: 15))
      app.buttons["Remove iPad"].tap()
      let dialog = app.otherElements["device-removal-confirmation"]
      XCTAssertTrue(dialog.waitForExistence(timeout: 15))
      XCTAssertTrue(text("cannot be erased remotely", in: app).exists)
      dialog.buttons["Remove iPad"].tap()
      XCTAssertTrue(proposed.waitForExistence(timeout: 15))
    }
    prepare()
    // Cancelling the prepared removal keeps the device.
    app.buttons["Cancel"].tap()
    XCTAssertTrue(proposed.waitForNonExistence(timeout: 15))
    prepare()
    let replaced = proposed.label
    XCTAssertEqual(replaced.count, 64)
    XCTAssertNotEqual(replaced, first)
    let entry = app.textFields["Last four characters of the new Recovery Key"]
    enter(String(replaced.suffix(4)), into: entry, in: app)
    app.buttons["Remove iPad"].tap()
    XCTAssertTrue(text("The device was removed.", in: app).waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["Remove iPad"].exists)
    XCTAssertFalse(app.staticTexts["recovery-key"].exists)
    XCTAssertTrue(app.staticTexts["Private sync is on"].exists)
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
    app.buttons["Continue"].tap()
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["Connect your mail"].waitForExistence(timeout: 15))
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
    XCTAssertFalse(app.buttons["Gmail"].exists)
    XCTAssertFalse(text("This device cannot join", in: app).exists)
    let gate = XCTAttachment(screenshot: app.screenshot())
    gate.name = "New device waiting for approval after a removal"
    gate.lifetime = .keepAlways
    add(gate)
    // Signing out of the gate leaves nothing of the account on this device.
    app.buttons["Sign out of this device"].tap()
    XCTAssertTrue(text("Your other devices", in: app).waitForExistence(timeout: 15))
    app.buttons["Sign out of this device"].tap()
    XCTAssertTrue(app.staticTexts["Your mail,\non your devices."].waitForExistence(timeout: 15))
  }

  // Sign-out keeps nothing of the account on this device; deletion ends the account everywhere.
  private func removalJourney(_ app: XCUIApplication) {
    app.buttons["Continue"].tap()
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["recovery-key"].waitForExistence(timeout: 15))
    let key = app.staticTexts["recovery-key"].label
    let entry = app.textFields["Last four characters"]
    enter(String(key.suffix(4)), into: entry, in: app)
    app.buttons["Confirm Recovery Key"].tap()
    XCTAssertTrue(app.staticTexts["Private sync is on"].waitForExistence(timeout: 15))
    app.buttons["Sign out of this device"].tap()
    XCTAssertTrue(text("Your other devices", in: app).waitForExistence(timeout: 15))
    app.buttons["Sign out of this device"].tap()
    XCTAssertTrue(app.staticTexts["Your mail,\non your devices."].waitForExistence(timeout: 15))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Your mail,\non your devices."].waitForExistence(timeout: 20))
    // The keys left with the sign-out, so the account must approve this device again.
    app.buttons["Continue"].tap()
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["Approve this device"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["recovery-key"].exists)
    app.buttons["Delete Product Account"].tap()
    XCTAssertTrue(text("cannot be undone", in: app).waitForExistence(timeout: 15))
    app.buttons["Delete permanently"].tap()
    XCTAssertTrue(app.staticTexts["Product Account deleted"].waitForExistence(timeout: 15))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Your mail,\non your devices."].waitForExistence(timeout: 20))
    // The deleted account cannot be reopened, and this device keeps nothing of it.
    app.buttons["Continue"].tap()
    app.buttons["Sign in with Google"].tap()
    XCTAssertTrue(app.staticTexts["Product Account deleted"].waitForExistence(timeout: 15))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Deleted Product Account"
    shot.lifetime = .keepAlways
    add(shot)
  }

  // The Tiptap evaluation editor (#818, #819, #820): a new Draft is typed into the packaged page,
  // formatted and edited with assistance, saved with Save Draft through the encrypted Draft store,
  // and reopened after relaunch. Focus, resize and teardown are recorded.
  private func draftEditorJourney(_ app: XCUIApplication) {
    app.buttons["Continue"].tap()
    app.buttons["Sign in with Google"].tap()
    let recoveryKey = app.staticTexts["recovery-key"]
    XCTAssertTrue(recoveryKey.waitForExistence(timeout: 15))
    let presented = recoveryKey.label
    app.buttons["Choose another Google mailbox"].tap()
    XCTAssertTrue(text("connected on this device", in: app).waitForExistence(timeout: 15))
    let entry = app.textFields["Last four characters"]
    enter(String(presented.suffix(4)), into: entry, in: app)
    app.buttons["Confirm Recovery Key"].tap()
    XCTAssertTrue(
      app.buttons["Unread. Rowan Hale. Garden plans for spring"].waitForExistence(timeout: 20))
    // Assistance in the editor needs Mail Assistance Enablement; this build's model is synthetic.
    // The account page opens from the Mailboxes column; on iPhone that column is one Back away.
    let account = app.buttons["Account"]
    if !account.waitForExistence(timeout: 5) || !account.isHittable {
      if UIDevice.current.userInterfaceIdiom == .phone {
        app.buttons["Back to Mailboxes"].tap()
      } else {
        app.navigationBars.buttons.firstMatch.tap()
      }
    }
    XCTAssertTrue(account.waitForExistence(timeout: 10))
    account.tap()
    openSettings("Privacy & Data", in: app)
    let assistance = app.switches["Mail Assistance"]
    XCTAssertTrue(assistance.waitForExistence(timeout: 15))
    assistance.tap()
    XCTAssertTrue(app.staticTexts["On-device assistance is on."].waitForExistence(timeout: 15))
    app.buttons["Open Inbox"].tap()
    // The disposable Draft belongs to this run's synthetic Product Account only.
    app.buttons["New Message"].tap()
    let body = app.webViews.textViews["Message body"]
    XCTAssertTrue(body.waitForExistence(timeout: 30))
    // The controls appear once the page is ready and can move the page; focus it after that.
    waitUntil({ self.pageReady(app) }, timeout: 30)
    // Focus: typing reaches the page only once its editable body holds keyboard focus.
    // The empty editor fills the page; focus its first paragraph rather than the blank center.
    // A tap can land before the page's editor takes focus on a loaded host; tap again then.
    let firstParagraph = body.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
      .withOffset(CGVector(dx: 24, dy: 24))
    for _ in 0..<3 where !app.keyboards.firstMatch.exists {
      firstParagraph.tap()
      _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
    }
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    body.typeText("Evaluation paragraph")
    let typed = app.webViews.staticTexts["Evaluation paragraph"]
    XCTAssertTrue(typed.waitForExistence(timeout: 20))
    // Open Settings through the composer's palette without finishing this Draft.
    if UIDevice.current.userInterfaceIdiom == .pad {
      app.buttons["Open Command Palette"].tap()
    } else {
      let heading = app.staticTexts["New Message"].firstMatch
      XCTAssertTrue(heading.exists)
      let start = heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 80)))
    }
    XCTAssertTrue(app.textFields["Type a command"].waitForExistence(timeout: 10))
    app.buttons["Account"].tap()
    XCTAssertTrue(app.buttons["Open Inbox"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["Save Draft"].exists)
    XCTAssertFalse(typed.exists)
    if UIDevice.current.userInterfaceIdiom == .phone {
      // UIKit pops the Settings screen back to the same still-mounted composer.
      let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
      edge.press(forDuration: 0.1, thenDragTo:
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
    } else {
      app.buttons["Open Inbox"].tap()
    }
    XCTAssertTrue(typed.waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["Open Inbox"].exists)
    let focused = XCTAttachment(screenshot: app.screenshot())
    focused.name = "Evaluation editor typed"
    focused.lifetime = .keepAlways
    add(focused)
    // Resize: the page follows a rotation without reloading or losing its text.
    let portrait = app.webViews.firstMatch.frame
    XCUIDevice.shared.orientation = .landscapeLeft
    let rotated = NSPredicate { _, _ in app.webViews.firstMatch.frame.width != portrait.width }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: rotated, object: nil)], timeout: 10),
      .completed)
    XCTAssertTrue(typed.exists)
    let landscape = XCTAttachment(screenshot: app.screenshot())
    landscape.name = "Evaluation editor rotated"
    landscape.lifetime = .keepAlways
    add(landscape)
    // A floating menu can cover the header in landscape; its actions must receive those taps.
    menuControl("Rewrite the message body", from: "Writing tools", in: app).tap()
    XCTAssertTrue(app.buttons["Replace your text with this rewrite"].waitForExistence(timeout: 20))
    XCTAssertFalse(app.staticTexts["Add a recipient before sending."].exists)
    app.buttons["Keep your text and close this suggestion"].tap()
    XCUIDevice.shared.orientation = .portrait
    let restored = NSPredicate { _, _ in app.webViews.firstMatch.frame.width == portrait.width }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: restored, object: nil)], timeout: 10),
      .completed)
    formattingJourney(app, typed: typed)
    // Teardown: the last round trip reopened the Draft unchanged, so Close removes the page's web
    // view without asking.
    app.buttons["Close"].tap()
    waitUntil { app.webViews.count == 0 }
    XCTAssertFalse(app.buttons["Save Draft"].exists)
    app.terminate()
    app.launch()
    let draft = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Draft.")).firstMatch
    XCTAssertTrue(draft.waitForExistence(timeout: 20))
    draft.tap()
    XCTAssertTrue(app.webViews.textViews["Message body"].waitForExistence(timeout: 30))
    // The formatted, rewritten and translated body reopens as it was saved.
    XCTAssertTrue(webText("Synthetic translation of local mail.", in: app).waitForExistence(timeout: 15))
    let reopened = XCTAttachment(screenshot: app.screenshot())
    reopened.name = "Evaluation Draft after relaunch"
    reopened.lifetime = .keepAlways
    add(reopened)
    // An unchanged Draft closes without asking.
    app.buttons["Close"].tap()
    waitUntil { app.webViews.count == 0 }
    replyJourney(app)
    inlineImageJourney(app)
  }

  private func webText(_ value: String, in app: XCUIApplication) -> XCUIElement {
    app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
  }

  // iPhone shows its Format and writing tools controls, and iPad its format bar, once the page is ready.
  private func pageReady(_ app: XCUIApplication) -> Bool {
    app.buttons["Format"].exists || app.buttons["Undo"].exists
  }

  // A formatting or history control: iPad keeps it on the format bar; iPhone opens the Format panel.
  private func formatControl(_ name: String, in app: XCUIApplication) -> XCUIElement {
    let control = app.buttons[name]
    if !control.exists, app.buttons["Format"].exists {
      app.buttons["Format"].tap()
      _ = control.waitForExistence(timeout: 10)
    }
    return control
  }

  // A control in a menu that `menu` opens, such as Writing tools or iPhone's Add files. On iPhone
  // the Format panel takes the menus' place, so it closes first.
  private func menuControl(_ name: String, from menu: String, in app: XCUIApplication) -> XCUIElement {
    let control = app.buttons[name]
    if !control.exists {
      let closeFormat = app.buttons["Close Format"]
      if closeFormat.exists {
        closeFormat.tap()
        _ = app.buttons[menu].waitForExistence(timeout: 10)
      }
      app.buttons[menu].tap()
      _ = control.waitForExistence(timeout: 10)
    }
    return control
  }

  // Close asks before keeping changes; Save Draft stores the Draft and removes the page.
  private func saveOnClose(_ app: XCUIApplication) {
    if UIDevice.current.userInterfaceIdiom == .phone {
      let format = app.buttons["Close Format"]
      if format.exists {
        swipeBack(app)
        XCTAssertTrue(format.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.webViews.firstMatch.exists)
        XCTAssertFalse(app.buttons["Save Draft"].exists)
      }
      swipeBack(app, commit: false)
      XCTAssertFalse(app.buttons["Save Draft"].waitForExistence(timeout: 3))
      swipeBack(app)
      XCTAssertTrue(app.buttons["Save Draft"].waitForExistence(timeout: 10))
      // A second Back cancels the question without losing the editor's unsaved version.
      swipeBack(app)
      XCTAssertTrue(app.buttons["Save Draft"].waitForNonExistence(timeout: 10))
      XCTAssertTrue(app.webViews.firstMatch.exists)
      swipeBack(app)
    } else {
      app.buttons["Close"].tap()
    }
    let save = app.buttons["Save Draft"]
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    let asked = XCTAttachment(screenshot: app.screenshot())
    asked.name = "Evaluation editor Close"
    asked.lifetime = .keepAlways
    add(asked)
    save.tap()
    waitUntil { app.webViews.count == 0 }
  }

  // Double-taps a word in the page until the page reports a selection: a double tap on an already
  // selected word can collapse it instead.
  private func selectWord(_ app: XCUIApplication, selected: @escaping () -> Bool) {
    for _ in 0..<3 where !selected() {
      app.webViews.staticTexts.firstMatch.doubleTap()
      _ = XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in selected() }, object: nil)],
        timeout: 10)
    }
    XCTAssertTrue(selected())
  }

  private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 20) {
    let met = NSPredicate { _, _ in condition() }
    XCTAssertEqual(
      XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: met, object: nil)], timeout: timeout),
      .completed)
  }

  // #819: formatting, Undo and Redo, and reviewed assistance results act on the page's selection;
  // each accepted result is one edit that one Undo reverts and Redo restores.
  private func formattingJourney(_ app: XCUIApplication, typed: XCUIElement) {
    // Select the whole paragraph, so every word of it is bold when the Draft reopens. A triple tap
    // can leave only a caret on a loaded host; the edit menu appears once text is selected.
    let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy"))
      .firstMatch
    for _ in 0..<3 where !copy.exists {
      typed.tap(withNumberOfTaps: 3, numberOfTouches: 1)
      _ = copy.waitForExistence(timeout: 5)
    }
    XCTAssertTrue(copy.exists)
    let bold = formatControl("Bold", in: app)
    bold.tap()
    waitUntil { bold.isSelected }
    let numbered = formatControl("Numbered list", in: app)
    numbered.tap()
    waitUntil { numbered.isSelected }
    formatControl("Undo", in: app).tap()
    waitUntil { !numbered.isSelected }
    formatControl("Redo", in: app).tap()
    waitUntil { numbered.isSelected }
    let formatted = XCTAttachment(screenshot: app.screenshot())
    formatted.name = "Evaluation editor formatted"
    formatted.lifetime = .keepAlways
    add(formatted)

    // Reopen an existing formatted Draft before transformations, then check its selected marks.
    reopenDraft(app)
    webText("Evaluation paragraph", in: app).doubleTap()
    waitUntil {
      self.formatControl("Bold", in: app).isSelected
        && self.formatControl("Numbered list", in: app).isSelected
    }
    assistanceRoundTrips(app, result: "Synthetic rewrite of local mail.", apply: "Replace your text with this rewrite", boldAfterApply: true) {
      selectWord(app) { self.menuControl("Rewrite the selected text", from: "Writing tools", in: app).exists }
      app.buttons["Rewrite the selected text"].tap()
    }
    assistanceRoundTrips(app, result: "Synthetic rewrite of local mail.", apply: "Replace your text with this rewrite", boldAfterApply: false) {
      app.webViews.textViews["Message body"].tap()
      let rewrite = menuControl("Rewrite the message body", from: "Writing tools", in: app)
      XCTAssertTrue(rewrite.waitForExistence(timeout: 15))
      rewrite.tap()
    }
    assistanceRoundTrips(app, result: "Synthetic translation of local mail.", apply: "Replace the selected text with this translation", boldAfterApply: false) {
      selectWord(app) { self.menuControl("Translate the selected text", from: "Writing tools", in: app).isEnabled }
      app.buttons["Translate the selected text"].tap()
      // On a loaded iPad the first tap on a language can be lost; choose it again until it applies.
      let german = app.descendants(matching: .any)
        .matching(NSPredicate(format: "label == %@", "Translate into German")).firstMatch
      for _ in 0..<3 where !app.staticTexts["Synthetic translation of local mail."].exists {
        german.tap()
        _ = app.staticTexts["Synthetic translation of local mail."].waitForExistence(timeout: 10)
      }
    }
    let accepted = XCTAttachment(screenshot: app.screenshot())
    accepted.name = "Evaluation editor after rewrite and translation"
    accepted.lifetime = .keepAlways
    add(accepted)
  }

  // Close, relaunch and reopen through the native encrypted Draft store, not mounted history.
  private func reopenDraft(_ app: XCUIApplication, titled title: String = "") {
    saveOnClose(app)
    app.terminate()
    app.launch()
    // A Draft row names its subject; without a title, the only Draft so far.
    // CONTAINS never matches an empty string, so an untitled reopen matches the prefix alone.
    let draft = app.buttons.matching(
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
    // Right after launch the Inbox can redraw its rows under a tap on a loaded host; tap again then.
    // iPad can restore another open Draft at launch, so the requested row is always tapped first.
    let ready = NSPredicate { _, _ in self.pageReady(app) }
    draft.tap()
    for _ in 0..<2
    where XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 20) != .completed
    {
      if app.webViews.count == 0 {
        draft.tap()
      }
    }
    XCTAssertTrue(pageReady(app))
  }

  // Each operation saves/reopens its undone state, then repeats and saves/reopens its redone state.
  // Comparing all page text also checks surrounding authored content, not only the result substring.
  private func assistanceRoundTrips(
    _ app: XCUIApplication, result: String, apply: String, draft title: String = "",
    numbered: Bool = true, boldAfterApply: Bool, start: () -> Void
  ) {
    for leaveUndone in [true, false] {
      let original = app.webViews.staticTexts.allElementsBoundByIndex.map { $0.label }
      let originalBold = formatControl("Bold", in: app).isSelected
      start()
      XCTAssertTrue(app.staticTexts[result].waitForExistence(timeout: 15))
      let accept = app.buttons[apply]
      XCTAssertTrue(accept.waitForExistence(timeout: 15))
      accept.tap()
      waitUntil { app.webViews.staticTexts.allElementsBoundByIndex.map { $0.label } != original }
      waitUntil { app.webViews.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " ").contains(result) }
      let accepted = app.webViews.staticTexts.allElementsBoundByIndex.map { $0.label }
      waitUntil { self.formatControl("Numbered list", in: app).isSelected == numbered && self.formatControl("Bold", in: app).isSelected == boldAfterApply }
      waitUntil { self.formatControl("Undo", in: app).isEnabled }
      app.buttons["Undo"].tap()
      waitUntil { app.webViews.staticTexts.allElementsBoundByIndex.map { $0.label } == original }
      waitUntil { self.formatControl("Numbered list", in: app).isSelected == numbered && self.formatControl("Bold", in: app).isSelected == originalBold }
      if !leaveUndone {
        waitUntil { self.formatControl("Redo", in: app).isEnabled }
        app.buttons["Redo"].tap()
        waitUntil { app.webViews.staticTexts.allElementsBoundByIndex.map { $0.label } == accepted }
        waitUntil { self.formatControl("Numbered list", in: app).isSelected == numbered && self.formatControl("Bold", in: app).isSelected == boldAfterApply }
      }
      reopenDraft(app, titled: title)
      // The reopened page replaces any editor shown at launch once it has loaded.
      let expected = leaveUndone ? original : accepted
      waitUntil { app.webViews.staticTexts.allElementsBoundByIndex.map { $0.label } == expected }
      let expectedBold = leaveUndone ? originalBold : boldAfterApply
      waitUntil { self.formatControl("Numbered list", in: app).isSelected == numbered && self.formatControl("Bold", in: app).isSelected == expectedBold }
    }
  }

  // A reply suggestion replaces the whole authored body of a Reply Draft in the page.
  private func replyJourney(_ app: XCUIApplication) {
    let message = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "Garden plans for spring")
    ).firstMatch
    // On iPhone the closed composer leaves the reader route; go back to the Inbox.
    let back = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Back", "Back,")).firstMatch
    if !message.waitForExistence(timeout: 5), back.exists {
      back.tap()
    }
    XCTAssertTrue(message.waitForExistence(timeout: 15))
    message.tap()
    app.buttons["Reply"].tap()
    if app.buttons["Reply All"].waitForExistence(timeout: 2) {
      // iPhone's Reply sheet names the sender beside its Close button.
      XCTAssertTrue(app.buttons["Close"].exists)
      let sheet = XCTAttachment(screenshot: app.screenshot())
      sheet.name = "Reply sheet"
      sheet.lifetime = .keepAlways
      add(sheet)
      app.scrollViews.containing(.button, identifier: "Reply All").firstMatch.buttons["Reply"].tap()
    }
    // The controls appear once the page has loaded and can take the accepted reply.
    waitUntil({ self.pageReady(app) }, timeout: 30)
    let suggest = menuControl("Suggest a reply to the quoted message", from: "Writing tools", in: app)
    XCTAssertTrue(suggest.waitForExistence(timeout: 30))
    // Writing tools stay closed until a round trip opens them again.
    app.buttons["Writing tools"].tap()
    assistanceRoundTrips(
      app, result: "Synthetic reply to local mail.", apply: "Replace your reply with this suggestion",
      draft: "Garden plans for spring", numbered: false, boldAfterApply: false
    ) {
      self.menuControl("Suggest a reply to the quoted message", from: "Writing tools", in: app).tap()
    }
    let reply = XCTAttachment(screenshot: app.screenshot())
    reply.name = "Evaluation editor reply suggestion"
    reply.lifetime = .keepAlways
    add(reply)
    app.buttons["Close"].tap()
    waitUntil { app.webViews.count == 0 }
  }

  // #820: a photo from the system picker goes inline through native import. Typing around it, turning it
  // into an Attachment from its context menu and back with Undo and Redo, and reopening after
  // relaunch keep its Draft Asset; the page shows the native thumbnail once its bytes verify.
  private func inlineImageJourney(_ app: XCUIApplication) {
    let newMessage = app.buttons["New Message"]
    let back = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Back", "Back,")).firstMatch
    if !newMessage.waitForExistence(timeout: 5), back.exists {
      back.tap()
    }
    XCTAssertTrue(newMessage.waitForExistence(timeout: 15))
    newMessage.tap()
    waitUntil({ self.pageReady(app) }, timeout: 30)
    let body = app.webViews.textViews["Message body"]
    let firstParagraph = body.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
      .withOffset(CGVector(dx: 24, dy: 24))
    for _ in 0..<3 where !app.keyboards.firstMatch.exists {
      firstParagraph.tap()
      _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
    }
    body.typeText("Before ")
    XCTAssertTrue(webText("Before", in: app).waitForExistence(timeout: 20))
    // The runner adds a 600 × 400 photo to the Simulator's library; any library photo is wider
    // than the page's placeholder once its 256-point thumbnail shows. Insert Image places it at
    // the page's selection.
    menuControl("Insert Image", from: "Add files", in: app).tap()
    let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
    XCTAssertTrue(photo.waitForExistence(timeout: 30))
    photo.tap()
    let addPhoto = app.buttons["Add"]
    if addPhoto.waitForExistence(timeout: 5) {
      addPhoto.tap()
    }
    let image = app.webViews.images.firstMatch
    XCTAssertTrue(image.waitForExistence(timeout: 30))
    waitUntil { image.frame.width > 60 }
    body.typeText(" after")
    XCTAssertTrue(webText("after", in: app).waitForExistence(timeout: 20))
    let inserted = XCTAttachment(screenshot: app.screenshot())
    inserted.name = "Evaluation editor inline image"
    inserted.lifetime = .keepAlways
    add(inserted)
    // The Inline Image becomes an Attachment from its chip's context menu, and back, each one edit
    // Undo and Redo step through.
    let thumbnail = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Inline image ")).firstMatch
    XCTAssertTrue(thumbnail.waitForExistence(timeout: 30))
    let name = String(thumbnail.label.dropFirst("Inline image ".count))
    let chip = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "\(name), ")).firstMatch
    thumbnail.press(forDuration: 1.2)
    let toAttachment = app.buttons["Attach Instead"]
    XCTAssertTrue(toAttachment.waitForExistence(timeout: 15))
    let menu = XCTAttachment(screenshot: app.screenshot())
    menu.name = "Evaluation editor image context menu"
    menu.lifetime = .keepAlways
    add(menu)
    toAttachment.tap()
    waitUntil { app.webViews.images.count == 0 }
    XCTAssertTrue(chip.waitForExistence(timeout: 15))
    chip.press(forDuration: 1.2)
    let toInline = app.buttons["Show Inline"]
    XCTAssertTrue(toInline.waitForExistence(timeout: 15))
    let attached = XCTAttachment(screenshot: app.screenshot())
    attached.name = "Evaluation editor image as Attachment"
    attached.lifetime = .keepAlways
    add(attached)
    toInline.tap()
    waitUntil { app.webViews.images.count == 1 }
    formatControl("Undo", in: app).tap()
    waitUntil { app.webViews.images.count == 0 }
    app.buttons["Redo"].tap()
    waitUntil { app.webViews.images.count == 1 }
    let typed = app.webViews.staticTexts.allElementsBoundByIndex.map { $0.label }
    // Reopened from encrypted storage, the image keeps its place and shows its thumbnail again.
    reopenDraft(app)
    waitUntil { app.webViews.staticTexts.allElementsBoundByIndex.map { $0.label } == typed }
    let reopened = app.webViews.images.firstMatch
    XCTAssertTrue(reopened.waitForExistence(timeout: 30))
    waitUntil { reopened.frame.width > 60 }
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Evaluation Draft with inline image after relaunch"
    shot.lifetime = .keepAlways
    add(shot)
    app.buttons["Close"].tap()
    waitUntil { app.webViews.count == 0 }
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
      XCTAssertTrue(app.staticTexts["Your mail,\non your devices."].waitForExistence(timeout: 20))
      switch ProcessInfo.processInfo.environment["UNWIRED_TEST_SCENARIO"] {
      case "registration-apple": appleRegistrationJourney(app)
      case "registration-link": linkJourney(app)
      case "registration-enrollment": enrollmentJourney(app)
      case "registration-recovery": recoveryJourney(app)
      case "registration-revocation": revocationJourney(app)
      case "registration-revoked": revokedJourney(app)
      case "registration-removal": removalJourney(app)
      case "registration-draft-editor": draftEditorJourney(app)
      case "registration-thread": threadJourney(app)
      default:
        try registrationJourney(app)
      }
      return
    }
    inboxJourney(app)
  }

  private func inboxJourney(_ app: XCUIApplication) {
    let title = UIDevice.current.userInterfaceIdiom == .pad ? "All Inboxes" : "Inbox"
    XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 20))
    verifyCompactInboxHeader(app)
    verifyLanguagePreference(in: app)
    let maya = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Maya Chen"))
      .firstMatch
    XCTAssertTrue(maya.waitForExistence(timeout: 10))
    XCTAssertTrue(maya.label.hasPrefix("Unread."))
    // The floating search field rises above the software keyboard while it is in use.
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
    let aboveKeyboard = NSPredicate { _, _ in search.frame.maxY <= keyboard.frame.minY }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: aboveKeyboard, object: nil)], timeout: 10),
      .completed)
    // Search lists matches under Top Results until Close returns to the Inbox.
    search.typeText("Maya")
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Top Results"))
        .firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(maya.waitForExistence(timeout: 10))
    let results = XCTAttachment(screenshot: app.screenshot())
    results.name = "Search results"
    results.lifetime = .keepAlways
    add(results)
    search.typeText("\n")
    XCTAssertTrue(keyboard.waitForNonExistence(timeout: 10))
    app.buttons["Close Search"].tap()
    XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    maya.tap()
    let sender = app.staticTexts.matching(identifier: "maya@example.com").firstMatch
    XCTAssertTrue(sender.waitForExistence(timeout: 10))
    if UIDevice.current.userInterfaceIdiom == .phone {
      swipeBack(app, commit: false)
      XCTAssertFalse(sender.waitForNonExistence(timeout: 3))
      swipeBack(app)
      waitUntil { maya.isHittable }
      XCTAssertFalse(sender.exists)
      maya.tap()
      XCTAssertTrue(sender.waitForExistence(timeout: 10))
    }
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
      let back = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Back", "Back,")).firstMatch
      XCTAssertTrue(back.exists)
      back.tap()
      verifyCompactInboxHeader(app)
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

  // Native screen frames can fill the window while their React content is still squeezed.
  private func verifyInboxViewport(_ app: XCUIApplication) {
    let content = app.otherElements["inbox-back-navigation"].firstMatch
    XCTAssertTrue(content.waitForExistence(timeout: 10))
    waitUntil { content.frame == app.windows.firstMatch.frame }
  }

  // On iPhone, Back and the Inbox heading share one row in place of the native navigation bar.
  private func verifyCompactInboxHeader(_ app: XCUIApplication) {
    guard UIDevice.current.userInterfaceIdiom == .phone else { return }
    verifyInboxViewport(app)
    let back = app.buttons["Back to Mailboxes"]
    XCTAssertTrue(back.waitForExistence(timeout: 10))
    let title = app.staticTexts["Inbox"].firstMatch
    XCTAssertTrue(title.waitForExistence(timeout: 10))
    let subtitle = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Preview mailbox")
    ).firstMatch
    XCTAssertTrue(subtitle.exists)
    for text in [title, subtitle] {
      XCTAssertLessThan(text.frame.minY, back.frame.maxY)
      XCTAssertGreaterThan(text.frame.maxY, back.frame.minY)
    }
    XCTAssertFalse(app.navigationBars.firstMatch.exists)
  }

  private func verifyLanguagePreference(in app: XCUIApplication) {
    let english = app.descendants(matching: .any)["language-en"]
    XCTAssertTrue(english.waitForExistence(timeout: 10))
    english.tap()
    let checked = NSPredicate(format: "value CONTAINS 'checked' AND NOT value CONTAINS 'unchecked'")
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: checked, object: english)], timeout: 10),
      .completed)
    app.terminate()
    app.launch()
    XCTAssertTrue(english.waitForExistence(timeout: 20))
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: checked, object: english)], timeout: 10),
      .completed)
    let system = app.descendants(matching: .any)["language-system"]
    system.tap()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: checked, object: system)], timeout: 10),
      .completed)
  }

}
