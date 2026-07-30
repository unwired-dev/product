import XCTest

@testable import unwired_mail

final class SettingsDestinationRegistryTests: XCTestCase {
  @MainActor
  func testManualProviderRefreshNotifiesMailShellAfterLoadCompletes() async {
    var events: [String] = []

    await MailboxProviderConnectionPanel.performManualRefresh(
      load: { events.append("load") },
      connectionsDidChange: { events.append("notify") }
    )

    XCTAssertEqual(events, ["load", "notify"])
  }

  @MainActor
  func testSharedMailboxManualRefreshLoadsOnlyOnce() async {
    var loadCount = 0

    await MailboxProviderConnectionPanel.performManualRefresh(
      load: { loadCount += 1 },
      connectionsDidChange: {}
    )

    XCTAssertEqual(loadCount, 1)
  }

  func testSynchronizationIsDisabledForPartialSnapshot() {
    XCTAssertTrue(
      mailboxSynchronizationIsDisabled(
        isMailboxBusy: false,
        isAuthorized: true,
        snapshotIsAuthoritative: false,
        isSynchronizing: false
      )
    )
    XCTAssertFalse(
      mailboxSynchronizationIsDisabled(
        isMailboxBusy: false,
        isAuthorized: true,
        snapshotIsAuthoritative: true,
        isSynchronizing: false
      )
    )
  }

  func testProviderMutationsAreDisabledWhileRoutedConnectionsLoad() {
    XCTAssertTrue(
      providerMutationIsDisabled(
        isMailboxBusy: false,
        isRoutedConnectionsLoading: true
      )
    )
    XCTAssertFalse(
      providerMutationIsDisabled(
        isMailboxBusy: false,
        isRoutedConnectionsLoading: false
      )
    )
  }

  @MainActor
  func testEmailAccountsStartsRoutedAndGenericLoadsTogether() async {
    let routedLoad = TestRendezvous()
    let genericLoad = TestRendezvous()
    let loadTask = Task {
      await EmailAccountsSettingsView.loadInitialConnections(
        loadRoutedConnections: {
          await routedLoad.hold()
          return true
        },
        loadGenericConnections: {
          await genericLoad.hold()
        }
      )
    }

    await routedLoad.waitUntilHeld()
    await genericLoad.waitUntilHeld()
    await routedLoad.release()
    await genericLoad.release()

    let connectionsAreAuthoritative = await loadTask.value
    XCTAssertTrue(connectionsAreAuthoritative)
  }

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

  func testSignedOutSettingsHideUnavailableDestinations() {
    XCTAssertTrue(
      SettingsDestinationRegistry.implementedGroups(isSignedIn: false).isEmpty
    )
    XCTAssertTrue(
      SettingsDestinationRegistry.destinations(in: .accounts, isSignedIn: false).isEmpty
    )
  }

  @MainActor
  func testMailboxWorkCoordinatorSharesBusyStateAndCancellation() async {
    let coordinator = MailboxWorkCoordinator()
    let firstRegistrationId = UUID()
    let secondRegistrationId = UUID()
    var cancelledWindows: Set<String> = []

    coordinator.register(
      productAccountId: "product-account",
      registrationId: firstRegistrationId,
      cancelBodyPrefetch: { cancelledWindows.insert("first") },
      isBusy: true
    )
    coordinator.register(
      productAccountId: "product-account",
      registrationId: secondRegistrationId,
      cancelBodyPrefetch: { cancelledWindows.insert("second") },
      isBusy: false
    )

    XCTAssertTrue(coordinator.isBusy(productAccountId: "product-account"))
    await coordinator.cancelBodyPrefetch(productAccountId: "product-account")
    XCTAssertEqual(cancelledWindows, ["first", "second"])

    coordinator.unregister(
      productAccountId: "product-account",
      registrationId: secondRegistrationId
    )
    XCTAssertTrue(coordinator.isBusy(productAccountId: "product-account"))
    coordinator.unregister(
      productAccountId: "product-account",
      registrationId: firstRegistrationId
    )
    XCTAssertFalse(coordinator.isBusy(productAccountId: "product-account"))
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
