import XCTest

final class SettingsAccessibilityUITests: XCTestCase {
  private enum SettingsLayout {
    case compact
    case split

    var launchEnvironmentValue: String {
      switch self {
      case .compact: "compact"
      case .split: "split"
      }
    }
  }

  private let unavailableHint = "Sign in to use this setting."

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testCompactNavigationDisablesSignedOutDestinations() {
    let app = launchSignedOutSettings(layout: .compact)
    let row = unavailableRow(named: "Email Accounts", in: app)

    assertUnavailable(row)
  }

  func testSplitNavigationDisablesSignedOutDestinations() {
    let app = launchSignedOutSettings(layout: .split)
    let row = unavailableRow(named: "Email Accounts", in: app)

    assertUnavailable(row)
  }

  func testSearchDisablesSignedOutDestinations() {
    let app = launchSignedOutSettings(layout: .compact)
    let search = app.searchFields["Search Settings"]
    XCTAssertTrue(
      search.waitForExistence(timeout: 5),
      "Signed-out Settings did not expose search."
    )
    search.tap()
    search.typeText("Mailbox Connections")

    assertUnavailable(unavailableRow(named: "Mailbox Connections", in: app))
  }

  private func launchSignedOutSettings(layout: SettingsLayout) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_US",
      "-settings.lastDestination", "appearance",
    ]
    app.launchEnvironment["SETTINGS_UI_TEST_LAYOUT"] = layout.launchEnvironmentValue
    app.launch()

    let settings = app.buttons["Settings"]
    XCTAssertTrue(
      settings.waitForExistence(timeout: 10),
      "The signed-out screen did not expose Settings."
    )
    settings.tap()

    let search = app.searchFields["Search Settings"]
    if layout == .compact {
      let back = app.navigationBars["Appearance"].buttons["Settings"]
      XCTAssertTrue(
        back.waitForExistence(timeout: 3),
        "Compact signed-out Settings did not expose its destination list."
      )
      back.tap()
    }
    XCTAssertTrue(
      search.waitForExistence(timeout: 5),
      "Signed-out Settings did not render."
    )
    return app
  }

  private func unavailableRow(named title: String, in app: XCUIApplication) -> XCUIElement {
    let row = app.buttons.containing(.staticText, identifier: title).firstMatch
    XCTAssertTrue(
      row.waitForExistence(timeout: 5),
      "Signed-out Settings did not render the unavailable \(title) destination."
    )
    return row
  }

  private func assertUnavailable(_ row: XCUIElement) {
    XCTAssertFalse(row.isEnabled, "The signed-out destination remained enabled.")
    let explanation = row.staticTexts[unavailableHint]
    XCTAssertTrue(
      explanation.waitForExistence(timeout: 2),
      "The signed-out destination did not show its explanation."
    )
  }
}
