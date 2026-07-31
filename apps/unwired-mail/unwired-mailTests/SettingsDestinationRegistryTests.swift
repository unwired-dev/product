import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
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

  @MainActor
  func testFailedProviderRemovalDoesNotNotifyConnectionsChanged() async {
    var events: [String] = []

    await MailboxProviderConnectionPanel.performDestructiveAction(
      cancelMailboxWork: { events.append("cancel") },
      action: {
        events.append("remove")
        return false
      },
      connectionsDidChange: { events.append("notify") }
    )

    XCTAssertEqual(events, ["cancel", "remove"])
  }

  @MainActor
  func testSuccessfulProviderRemovalNotifiesConnectionsChanged() async {
    var events: [String] = []

    await MailboxProviderConnectionPanel.performDestructiveAction(
      cancelMailboxWork: { events.append("cancel") },
      action: {
        events.append("remove")
        return true
      },
      connectionsDidChange: { events.append("notify") }
    )

    XCTAssertEqual(events, ["cancel", "remove", "notify"])
  }

  @MainActor
  func testProviderChangeRefreshesEveryDefaultSenderBeforeNotifyingMailShell() async {
    var events: [String] = []

    await EmailAccountsSettingsView.refreshConnectionAuthority(
      loadRoutedConnections: {
        events.append("load routed")
        return true
      },
      loadGenericConnections: { events.append("load generic") },
      loadMicrosoftConnections: {
        events.append("load Microsoft")
        return true
      },
      loadEWSConnections: { events.append("load EWS") },
      connectionsDidChange: { events.append("notify") }
    )

    XCTAssertEqual(
      Set(events.dropLast()),
      [
        "load routed",
        "load generic",
        "load Microsoft",
        "load EWS",
      ])
    XCTAssertEqual(events.last, "notify")
  }

  @MainActor
  func testRoutedProviderMutationRefreshesOtherProvidersWithoutReloadingRoutedProvider() async {
    var events: [String] = []

    await EmailAccountsSettingsView.refreshConnectionAuthorityAfterRoutedMutation(
      loadGenericConnections: { events.append("load generic") },
      loadMicrosoftConnections: {
        events.append("load Microsoft")
        return true
      },
      loadEWSConnections: { events.append("load EWS") },
      connectionsDidChange: { events.append("notify") }
    )

    XCTAssertEqual(
      Set(events.dropLast()),
      [
        "load generic",
        "load Microsoft",
        "load EWS",
      ]
    )
    XCTAssertEqual(events.last, "notify")
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
  func testEmailAccountsWaitsForRoutedGenericAndEWSLoads() async {
    let routedLoad = TestRendezvous()
    let genericLoad = TestRendezvous()
    let ewsLoad = TestRendezvous()
    let loadTask = Task {
      await EmailAccountsSettingsView.loadInitialConnections(
        loadRoutedConnections: {
          await routedLoad.hold()
          return true
        },
        loadGenericConnections: {
          await genericLoad.hold()
        },
        loadEWSConnections: {
          await ewsLoad.hold()
        }
      )
    }

    await routedLoad.waitUntilHeld()
    await genericLoad.waitUntilHeld()
    await ewsLoad.waitUntilHeld()
    await routedLoad.release()
    await genericLoad.release()
    await ewsLoad.release()

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

  func testAppDoesNotEnableMultipleScenesOutsideDevelopmentCatalyst() {
    let sceneManifest =
      Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any]

    XCTAssertEqual(sceneManifest?["UIApplicationSupportsMultipleScenes"] as? Bool, false)
  }

  func testDevelopmentRegistryContainsOnlyCompleteDestinations() {
    XCTAssertEqual(
      SettingsDestinationRegistry.implementedDestinations,
      [.emailAccounts, .accountAndDevices, .appearance]
    )
    XCTAssertEqual(SettingsDestinationRegistry.implementedGroups, [.accounts, .application])
    XCTAssertEqual(
      SettingsDestinationRegistry.destinations(in: .accounts),
      [.emailAccounts, .accountAndDevices]
    )
  }

  func testAccountAndDevicesMetadataDrivesNavigationAndSearch() {
    let destination = SettingsDestination.accountAndDevices

    XCTAssertEqual(destination.group, .accounts)
    XCTAssertEqual(destination.title, "Account & Devices")
    XCTAssertEqual(destination.systemImage, "person.2")
    XCTAssertFalse(destination.isAvailableWhenSignedOut)
    XCTAssertEqual(
      destination.searchItems.map(\.title),
      ["Product Account", "Trusted Devices", "Recovery Key", "Sign Out"]
    )
    XCTAssertEqual(
      SettingsDestinationRegistry.destinations(in: .application),
      [.appearance]
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
      destination.searchItems.map(\.title),
      [
        "Mailbox Connections",
        "Authorization",
        "Default Sending Connection",
        "Synchronize",
        "Mailbox Roles",
        "Gmail",
        "Microsoft 365",
        "On-Premises Exchange",
        "Other Mail Server",
      ]
    )
  }

  func testAppearanceMetadataDrivesSignedOutNavigationAndSearch() {
    let destination = SettingsDestination.appearance

    XCTAssertEqual(destination.group, .application)
    XCTAssertEqual(destination.title, "Appearance")
    XCTAssertEqual(destination.systemImage, "paintbrush")
    XCTAssertEqual(destination.route, SettingsRoute(destination: .appearance))
    XCTAssertTrue(destination.isAvailableWhenSignedOut)
    XCTAssertEqual(
      destination.searchItems.map(\.title),
      ["Theme", "Reading Text Size", "Message Body", "Increased Contrast"]
    )
    XCTAssertEqual(
      SettingsDestinationRegistry.search(matching: "serif", isSignedIn: false)
        .map(\.route),
      [.appearance(.messageBody)]
    )
    XCTAssertEqual(
      destination.searchItems.map(\.route),
      [
        .appearance(.theme),
        .appearance(.readingTextSize),
        .appearance(.messageBody),
        .appearance(.increasedContrast),
      ]
    )
  }

  func testSearchMatchesDestinationGroupSectionAndControlLabels() {
    XCTAssertEqual(
      SettingsDestinationRegistry.search(matching: "email accounts", isSignedIn: true),
      [
        SettingsSearchResult(
          title: "Email Accounts",
          subtitle: "Accounts",
          route: .mailboxConnections
        )
      ]
    )
    XCTAssertTrue(
      SettingsDestinationRegistry.search(matching: "accounts", isSignedIn: true)
        .contains { $0.route == .mailboxConnections }
    )
    XCTAssertEqual(
      SettingsDestinationRegistry.search(matching: "mailbox connections", isSignedIn: true)
        .map(\.route),
      [.mailboxConnections]
    )
    XCTAssertEqual(
      SettingsDestinationRegistry.search(matching: "AuThOrIzAtIoN", isSignedIn: true)
        .map(\.route),
      [.authorization(connectionId: nil)]
    )
    XCTAssertEqual(
      SettingsDestinationRegistry.search(matching: "on premises", isSignedIn: true)
        .map(\.route),
      [.provider(.exchangeWebServices)]
    )
  }

  func testSearchResultsHaveUniqueIdentitiesWhenRoutesOverlap() {
    let results = SettingsDestinationRegistry.search(matching: "mail", isSignedIn: true)

    XCTAssertEqual(Set(results.map(\.id)).count, results.count)
  }

  func testSearchUsesOnlyStaticMetadata() {
    XCTAssertTrue(
      SettingsDestinationRegistry.search(
        matching: "private@example.com",
        isSignedIn: true
      ).isEmpty
    )
    XCTAssertTrue(
      SettingsDestinationRegistry.search(
        matching: "signature body",
        isSignedIn: true
      ).isEmpty
    )
    XCTAssertTrue(
      SettingsDestinationRegistry.search(
        matching: "diagnostic report contents",
        isSignedIn: true
      ).isEmpty
    )
    XCTAssertTrue(
      SettingsDestinationRegistry.search(
        matching: "Authorization",
        isSignedIn: false
      ).isEmpty
    )
  }

  func testContextualRoutesMapToTheirFutureDestinationsWithoutMakingThemVisible() {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "account"
      )
    )

    XCTAssertEqual(
      SettingsRoute.authorization(connectionId: connectionId).destination,
      .emailAccounts
    )
    XCTAssertEqual(SettingsRoute.notificationPermission.destination, .notifications)
    XCTAssertEqual(
      SettingsRoute.missingSignature(connectionId: connectionId).destination,
      .signatures
    )
    XCTAssertEqual(
      SettingsRoute.readReceipt(connectionId: connectionId).destination,
      .reading
    )
    XCTAssertEqual(SettingsRoute.storage.destination, .privacyAndData)
    XCTAssertEqual(
      SettingsRoute.preferenceConflict(destination: .inbox, field: "previewLength").destination,
      .inbox
    )
    XCTAssertNil(
      SettingsDestinationRegistry.resolveRoute(
        .notificationPermission,
        isSignedIn: true
      )
    )
    XCTAssertEqual(
      SettingsDestinationRegistry.resolveRoute(
        .authorization(connectionId: connectionId),
        isSignedIn: true
      ),
      .authorization(connectionId: connectionId)
    )
    XCTAssertEqual(
      SettingsDestinationRegistry.implementedDestinations,
      [.emailAccounts, .accountAndDevices, .appearance]
    )
  }

  func testUnsavedChangesRequireConfirmationBeforeChangingContext() {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "account"
      )
    )
    let current = SettingsRoute.emailAccounts
    let requested = SettingsRoute.authorization(connectionId: connectionId)

    XCTAssertEqual(
      SettingsNavigationPolicy.decision(
        currentRoute: current,
        requestedRoute: requested,
        hasUnsavedChanges: true,
        isSignedIn: true
      ),
      .confirmDiscard(requested)
    )
    XCTAssertEqual(
      SettingsNavigationPolicy.decision(
        currentRoute: current,
        requestedRoute: requested,
        hasUnsavedChanges: false,
        isSignedIn: true
      ),
      .navigate(requested)
    )
    XCTAssertEqual(
      SettingsNavigationPolicy.decision(
        currentRoute: requested,
        requestedRoute: requested,
        hasUnsavedChanges: true,
        isSignedIn: true
      ),
      .navigate(requested)
    )
  }

  func testDiscardIsBlockedWhileSetupIsWorking() {
    XCTAssertFalse(SettingsNavigationPolicy.canDiscardChanges(isSetupWorking: true))
    XCTAssertTrue(SettingsNavigationPolicy.canDiscardChanges(isSetupWorking: false))
  }

  func testUnavailableDeepLinksDoNotReplaceTheCurrentDestination() {
    XCTAssertEqual(
      SettingsNavigationPolicy.decision(
        currentRoute: .emailAccounts,
        requestedRoute: .notificationPermission,
        hasUnsavedChanges: false,
        isSignedIn: true
      ),
      .unavailable
    )
  }

  func testEmailAccountAttentionIncludesOnlyActionableFailures() {
    XCTAssertEqual(
      SettingsAttention.emailAccounts(
        authorizationRequired: true,
        syncFailureMessage: "Server rejected the request."
      ),
      SettingsAttention(
        destination: .emailAccounts,
        kind: .authorization,
        message: "One or more Mailbox Connections require authorization on this device."
      )
    )
    XCTAssertEqual(
      SettingsAttention.emailAccounts(
        authorizationRequired: false,
        syncFailureMessage: "Server rejected the request."
      ),
      SettingsAttention(
        destination: .emailAccounts,
        kind: .sync,
        message: "Mailbox synchronization failed: Server rejected the request."
      )
    )
    XCTAssertNil(
      SettingsAttention.emailAccounts(
        authorizationRequired: false,
        syncFailureMessage: nil
      )
    )
  }

  func testNavigationLayoutUsesCompactStackOnlyForCompactWidth() {
    XCTAssertEqual(SettingsNavigationLayout.resolve(.compact), .compact)
    XCTAssertEqual(SettingsNavigationLayout.resolve(.regular), .split)
    XCTAssertEqual(SettingsNavigationLayout.resolve(nil), .split)
  }

  func testEmailAccountRoutesChooseFocusAndHighlightTargets() {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "account"
      )
    )

    XCTAssertEqual(
      EmailAccountsSettingsView.navigationFocus(for: .mailboxConnections),
      .summary
    )
    XCTAssertEqual(
      EmailAccountsSettingsView.navigationFocus(
        for: .authorization(connectionId: connectionId)
      ),
      .connection(connectionId.rawValue)
    )
    XCTAssertEqual(
      EmailAccountsSettingsView.navigationFocus(for: .mailboxRoles(connectionId: nil)),
      .genericMail
    )
    XCTAssertEqual(
      EmailAccountsSettingsView.navigationFocus(for: .provider(.microsoftGraph)),
      .provider(MailProviderId.microsoftGraph.rawValue)
    )
    XCTAssertNil(
      EmailAccountsSettingsView.navigationFocus(for: .notificationPermission)
    )
  }

  func testActionableMailboxStatusesLinkToTheAffectedConnection() {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "account"
      )
    )

    XCTAssertEqual(
      MailboxStatusSettingsLink.route(
        for: .authorizationRequired(lastSuccessfulSyncAt: nil),
        connectionId: connectionId
      ),
      .authorization(connectionId: connectionId)
    )
    XCTAssertEqual(
      MailboxStatusSettingsLink.route(
        for: MailboxSyncStatus(
          lastSuccessfulSyncAt: nil,
          phase: .failed("Server rejected the request.")
        ),
        connectionId: connectionId
      ),
      .synchronization(connectionId: connectionId)
    )
    XCTAssertNil(
      MailboxStatusSettingsLink.route(
        for: MailboxSyncStatus(lastSuccessfulSyncAt: nil, phase: .offline),
        connectionId: connectionId
      )
    )
  }

  @MainActor
  func testRouterPublishesRepeatedRequestsForTheSameRoute() {
    let router = SettingsRouter()

    router.open(.emailAccounts)
    let firstRequest = router.request
    router.open(.emailAccounts)

    XCTAssertEqual(firstRequest?.route, .emailAccounts)
    XCTAssertEqual(router.request?.route, .emailAccounts)
    XCTAssertNotEqual(firstRequest?.id, router.request?.id)
  }

  func testSignedInSettingsDefaultsToEmailAccounts() {
    XCTAssertEqual(SettingsDestinationRegistry.defaultDestination(isSignedIn: true), .emailAccounts)
    XCTAssertEqual(
      SettingsDestinationRegistry.defaultDestination(isSignedIn: false),
      .appearance
    )
  }

  func testSignedOutSettingsHideUnavailableDestinations() {
    XCTAssertEqual(
      SettingsDestinationRegistry.implementedGroups(isSignedIn: false),
      [.application]
    )
    XCTAssertTrue(
      SettingsDestinationRegistry.destinations(in: .accounts, isSignedIn: false).isEmpty
    )
    XCTAssertEqual(
      SettingsDestinationRegistry.destinations(in: .application, isSignedIn: false),
      [.appearance]
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
    XCTAssertEqual(
      SettingsDestinationRegistry.resolveDestination(
        storedRawValue: SettingsDestination.emailAccounts.rawValue,
        isSignedIn: false
      ),
      .appearance
    )
    XCTAssertEqual(
      SettingsDestinationRegistry.resolveDestination(
        storedRawValue: SettingsDestination.appearance.rawValue,
        isSignedIn: false
      ),
      .appearance
    )
  }
}

final class AppearancePreferencesTests: XCTestCase {
  @MainActor
  func testDefaultsAreDeviceLocalSystemAppearanceValues() {
    withIsolatedDefaults { defaults in
      let preferences = AppearancePreferences(defaults: defaults)

      XCTAssertEqual(preferences.theme, .system)
      XCTAssertEqual(preferences.readingTextSize, .standard)
      XCTAssertEqual(preferences.messageBodyTypeface, .senderFormatting)
      XCTAssertFalse(preferences.increasedContrast)
    }
  }

  @MainActor
  func testChangesPersistWithoutNetworkOrAccountState() {
    withIsolatedDefaults { defaults in
      let preferences = AppearancePreferences(defaults: defaults)
      preferences.theme = .dark
      preferences.readingTextSize = .large
      preferences.messageBodyTypeface = .systemSerif
      preferences.increasedContrast = true

      let reloaded = AppearancePreferences(defaults: defaults)

      XCTAssertEqual(reloaded.theme, .dark)
      XCTAssertEqual(reloaded.readingTextSize, .large)
      XCTAssertEqual(reloaded.messageBodyTypeface, .systemSerif)
      XCTAssertTrue(reloaded.increasedContrast)
    }
  }

  @MainActor
  func testInvalidStoredValuesFallBackIndependently() {
    withIsolatedDefaults { defaults in
      defaults.set("invalid", forKey: AppearancePreferences.StorageKey.theme.rawValue)
      defaults.set("invalid", forKey: AppearancePreferences.StorageKey.readingTextSize.rawValue)
      defaults.set("invalid", forKey: AppearancePreferences.StorageKey.messageBodyTypeface.rawValue)
      defaults.set(true, forKey: AppearancePreferences.StorageKey.increasedContrast.rawValue)

      let preferences = AppearancePreferences(defaults: defaults)

      XCTAssertEqual(preferences.theme, .system)
      XCTAssertEqual(preferences.readingTextSize, .standard)
      XCTAssertEqual(preferences.messageBodyTypeface, .senderFormatting)
      XCTAssertTrue(preferences.increasedContrast)
    }
  }

  @MainActor
  private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
    let suiteName = "AppearancePreferencesTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("Expected isolated UserDefaults suite")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    body(defaults)
  }
}

final class SettingsConnectionRefreshTests: XCTestCase {
  @MainActor
  func testMicrosoftManualRefreshRefreshesOtherProvidersWithoutReloadingMicrosoft() async {
    var events: [String] = []

    await EmailAccountsSettingsView.refreshConnectionAuthorityAfterMicrosoftRefresh(
      loadRoutedConnections: {
        events.append("load routed")
        return true
      },
      loadGenericConnections: { events.append("load generic") },
      loadEWSConnections: { events.append("load EWS") },
      connectionsDidChange: { events.append("notify") }
    )

    XCTAssertEqual(
      Set(events.dropLast()),
      [
        "load routed",
        "load generic",
        "load EWS",
      ]
    )
    XCTAssertEqual(events.last, "notify")
  }
}
