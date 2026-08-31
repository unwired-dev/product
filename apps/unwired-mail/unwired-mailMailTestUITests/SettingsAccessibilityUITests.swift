import UIKit
import XCTest

final class SettingsAccessibilityUITests: XCTestCase {
  private enum Appearance: String, CaseIterable {
    case system
    case light
    case dark
  }

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
    let row = unavailableRow(identifier: "unavailable-settings-emailAccounts", in: app)

    assertUnavailable(row, in: app)
  }

  func testSplitNavigationDisablesSignedOutDestinations() {
    let app = launchSignedOutSettings(layout: .split)
    let row = unavailableRow(identifier: "unavailable-settings-emailAccounts", in: app)

    assertUnavailable(row, in: app)
  }

  func testSearchDisablesSignedOutDestinations() {
    let app = launchSignedOutSettings(layout: .compact)
    settingsList(in: app).swipeDown(velocity: .slow)
    let search = app.searchFields["Search Settings"]
    XCTAssertTrue(
      search.waitForExistence(timeout: 5),
      "Signed-out Settings did not expose search."
    )
    search.tap()
    search.typeText("Mailbox Connections")

    assertUnavailable(
      unavailableRow(
        identifier: "unavailable-settings-search-emailAccounts-Email Accounts-Mailbox Connections",
        in: app
      ),
      in: app
    )
  }

  func testNativePlatformHierarchyPassesAccessibilityAuditInEveryAppearance() throws {
    for appearance in Appearance.allCases {
      let result = launchSignedOutSettings(appearance: appearance)

      XCTAssertEqual(
        result.layout,
        nativeLayout,
        "The native platform did not use its accepted Settings presentation."
      )
      collapseSearchDrawer(in: result.app)
      try performAccessibilityAudit(in: result.app, for: .all)
      attachEvidence(
        for: result.app,
        appearance: appearance,
        layout: result.layout
      )
      result.app.terminate()
    }
  }

  func testNativePlatformHierarchyRemainsUsableWithAccessibilityTextAndAnimationsDisabled() throws {
    let result = launchSignedOutSettings(
      appearance: .system,
      additionalArguments: [
        "-NSDoubleLocalizedStrings", "YES",
        "-UIPreferredContentSizeCategoryName",
        "UICTContentSizeCategoryAccessibilityXXXL",
      ],
      additionalEnvironment: ["CLIENT_VALIDATION_DISABLE_ANIMATIONS": "1"]
    )

    XCTAssertEqual(
      result.layout,
      nativeLayout,
      "Accessibility text changed the native Settings presentation."
    )
    collapseSearchDrawer(in: result.app)
    try performAccessibilityAudit(
      in: result.app,
      for: [.dynamicType, .hitRegion, .sufficientElementDescription, .textClipped]
    )
    attachEvidence(
      for: result.app,
      appearance: .system,
      layout: result.layout,
      qualifier: "accessibility-text-animations-disabled"
    )
  }

  private func launchSignedOutSettings(layout: SettingsLayout) -> XCUIApplication {
    launchSignedOutSettings(appearance: .system, layout: layout).app
  }

  private func launchSignedOutSettings(
    appearance: Appearance,
    layout: SettingsLayout? = nil,
    additionalArguments: [String] = [],
    additionalEnvironment: [String: String] = [:]
  ) -> (app: XCUIApplication, layout: SettingsLayout) {
    let app = XCUIApplication()
    app.launchArguments += [
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_US",
      "-appearance.theme", appearance.rawValue,
      "-settings.lastDestination", "appearance",
    ]
    app.launchArguments += additionalArguments
    if let layout {
      app.launchEnvironment["SETTINGS_UI_TEST_LAYOUT"] = layout.launchEnvironmentValue
    }
    app.launchEnvironment.merge(additionalEnvironment) { _, replacement in replacement }
    app.launch()

    let settings = app.buttons["signed-out-settings"]
    XCTAssertTrue(
      settings.waitForExistence(timeout: 10),
      "The signed-out screen did not expose Settings."
    )
    settings.tap()

    let list = settingsList(in: app)
    let resolvedLayout: SettingsLayout
    if layout == .compact || !list.waitForExistence(timeout: 3) {
      let back = app.navigationBars.buttons.firstMatch
      XCTAssertTrue(
        back.waitForExistence(timeout: 3),
        "Compact signed-out Settings did not expose its destination list."
      )
      back.tap()
      resolvedLayout = .compact
    } else {
      resolvedLayout = .split
    }
    XCTAssertTrue(
      list.waitForExistence(timeout: 5),
      "Signed-out Settings did not render."
    )
    return (app, resolvedLayout)
  }

  private func unavailableRow(identifier: String, in app: XCUIApplication) -> XCUIElement {
    let row = app.descendants(matching: .any)[identifier].firstMatch
    XCTAssertTrue(
      row.waitForExistence(timeout: 5),
      "Signed-out Settings did not render the unavailable destination."
    )
    return row
  }

  private func assertUnavailable(_ row: XCUIElement, in app: XCUIApplication) {
    XCTAssertNotEqual(
      row.elementType,
      .button,
      "The signed-out destination remained an interactive control."
    )
    let explanation = app.staticTexts[unavailableHint].firstMatch
    XCTAssertTrue(
      explanation.waitForExistence(timeout: 2),
      "The signed-out destination did not show its explanation."
    )
  }

  private var nativeLayout: SettingsLayout {
    #if targetEnvironment(macCatalyst)
      .split
    #else
      UIDevice.current.userInterfaceIdiom == .phone ? .compact : .split
    #endif
  }

  private var platformName: String {
    #if targetEnvironment(macCatalyst)
      "catalyst"
    #else
      switch UIDevice.current.userInterfaceIdiom {
      case .phone:
        "iphone"
      case .pad:
        "ipad"
      default:
        "apple"
      }
    #endif
  }

  private func attachEvidence(
    for app: XCUIApplication,
    appearance: Appearance,
    layout: SettingsLayout,
    qualifier: String? = nil
  ) {
    let evidenceName = [
      platformName,
      String(describing: layout),
      appearance.rawValue,
      qualifier,
    ].compactMap { $0 }

    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = evidenceName.joined(separator: "-")
    screenshot.lifetime = .keepAlways
    add(screenshot)

    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = evidenceName.joined(separator: "-") + "-hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
  }

  private func collapseSearchDrawer(in app: XCUIApplication) {
    let list = settingsList(in: app)
    XCTAssertTrue(
      list.waitForExistence(timeout: 3), "Settings did not expose its destination list.")
    list.swipeUp(velocity: .slow)
  }

  private func settingsList(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["settings-destination-list"].firstMatch
  }
}

extension SettingsAccessibilityUITests {
  private func performAccessibilityAudit(
    in app: XCUIApplication,
    for auditTypes: XCUIAccessibilityAuditType
  ) throws {
    try app.performAccessibilityAudit(for: auditTypes) { issue in
      let details = """
        Type: \(issue.auditType.rawValue)
        Summary: \(issue.compactDescription)
        Details: \(issue.detailedDescription)
        Element: \(issue.element?.debugDescription ?? "None")
        """
      print("ACCESSIBILITY_AUDIT_ISSUE\n\(details)")

      let attachment = XCTAttachment(string: details)
      let isAnonymousSwiftUIArtifact =
        issue.element == nil
        && issue.detailedDescription.contains("SwiftUI.AccessibilityNode")
      let handlesAnonymousSwiftUIArtifact =
        isAnonymousSwiftUIArtifact
        && (issue.auditType == .contrast
          || issue.auditType == .textClipped
            && issue.compactDescription == "Text clipped"
            && issue.detailedDescription
              == "Text of this SwiftUI.AccessibilityNode may be clipped at larger Dynamic Type sizes.")
      let verifiedAppearanceText = [
        "Increased Contrast",
        "Adds contrast beyond the current system setting on this device.",
      ]
      let handlesVerifiedAppearanceTextArtifact =
        issue.auditType == .dynamicType
        && verifiedAppearanceText.contains(issue.element?.label ?? "")
        && issue.compactDescription == "Dynamic Type font sizes are partially unsupported"
        && issue.detailedDescription
          == "User will not be able to change the font size of this SwiftUI.AccessibilityNode"
      let handlesNativeSearchFieldArtifact =
        issue.auditType == .textClipped
        && issue.element?.elementType == .searchField
        && issue.element?.label == "Search Settings"
        && issue.detailedDescription
          == "Text of this UISearchBarTextField may be clipped at larger Dynamic Type sizes."
      let handlesKnownPlatformArtifact =
        handlesAnonymousSwiftUIArtifact || handlesVerifiedAppearanceTextArtifact
        || handlesNativeSearchFieldArtifact
      attachment.name =
        handlesKnownPlatformArtifact
        ? "Handled anonymous SwiftUI accessibility audit issue"
        : "Accessibility audit issue"
      attachment.lifetime = .keepAlways
      self.add(attachment)
      return handlesKnownPlatformArtifact
    }
  }
}
