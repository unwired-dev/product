import XCTest

@testable import unwired_mail

final class SettingsDestinationRegistryTests: XCTestCase {
  func testProductionKeepsOnlyExistingAccountSettingsEntryPoint() {
    XCTAssertEqual(
      SettingsEntryPointRegistry.entries(isDevelopmentBuild: false),
      [.accountSettings]
    )
    XCTAssertEqual(
      SettingsEntryPointRegistry.entries(isDevelopmentBuild: true),
      [.accountSettings, .adaptiveSettings]
    )
  }

  func testDevelopmentRegistryContainsOnlyCompleteDestinations() {
    XCTAssertEqual(SettingsDestinationRegistry.implementedDestinations, [.emailAccounts])
    XCTAssertEqual(SettingsDestinationRegistry.implementedGroups, [.accounts])
    XCTAssertEqual(
      SettingsDestinationRegistry.destinations(in: .accounts),
      [.emailAccounts]
    )
  }

  func testEmailAccountsMetadataDrivesNavigationAndSearch() {
    let destination = SettingsDestination.emailAccounts

    XCTAssertEqual(destination.group, .accounts)
    XCTAssertEqual(destination.title, "Email Accounts")
    XCTAssertEqual(destination.systemImage, "at")
    XCTAssertEqual(destination.route, .emailAccounts)
    XCTAssertFalse(destination.isAvailableWhenSignedOut)
    XCTAssertEqual(
      destination.searchTerms,
      [
        "Mailbox Connections",
        "Authorization",
        "Default Sending Connection",
        "Synchronize",
        "Mailbox Roles",
      ]
    )
  }

  func testSignedInSettingsDefaultsToEmailAccounts() {
    XCTAssertEqual(SettingsDestinationRegistry.defaultDestination(isSignedIn: true), .emailAccounts)
    XCTAssertNil(SettingsDestinationRegistry.defaultDestination(isSignedIn: false))
  }

  func testStoredDestinationFallsBackToFirstAvailableDestination() {
    XCTAssertEqual(
      SettingsDestinationRegistry.resolveDestination(
        storedRawValue: SettingsDestination.emailAccounts.rawValue,
        isSignedIn: true
      ),
      .emailAccounts
    )
    XCTAssertEqual(
      SettingsDestinationRegistry.resolveDestination(
        storedRawValue: "removed-destination",
        isSignedIn: true
      ),
      .emailAccounts
    )
    XCTAssertNil(
      SettingsDestinationRegistry.resolveDestination(
        storedRawValue: SettingsDestination.emailAccounts.rawValue,
        isSignedIn: false
      )
    )
  }
}
