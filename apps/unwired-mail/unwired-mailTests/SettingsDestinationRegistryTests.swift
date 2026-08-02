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
      [.emailAccounts, .accountAndDevices, .appearance, .privacyAndData]
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
      [.appearance, .privacyAndData]
    )
  }

  @MainActor
  func testMessageContentPreferencesPersistDeviceLocalPoliciesAndConnectionOverrides() {
    let suiteName = "MessageContentPreferencesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "private@example.com"
      )
    )
    let preferences = MessageContentPreferences(defaults: defaults)

    XCTAssertEqual(preferences.remoteContentPolicy, .ask)
    XCTAssertEqual(preferences.attachmentDownloadPolicy, .onDemand)
    XCTAssertNil(preferences.remoteContentOverride(for: connectionId))

    preferences.remoteContentPolicy = .alwaysLoad
    preferences.attachmentDownloadPolicy = .wifi
    preferences.setRemoteContentOverride(.never, for: connectionId)

    let restored = MessageContentPreferences(defaults: defaults)
    XCTAssertEqual(restored.remoteContentPolicy, .alwaysLoad)
    XCTAssertEqual(restored.attachmentDownloadPolicy, .wifi)
    XCTAssertEqual(restored.remoteContentOverride(for: connectionId), .never)
    XCTAssertEqual(restored.remoteContentPolicy(for: connectionId), .never)

    restored.setRemoteContentOverride(nil, for: connectionId)
    XCTAssertEqual(restored.remoteContentPolicy(for: connectionId), .alwaysLoad)
  }

  @MainActor
  func testMessageContentPreferencesFailClosedForInvalidStoredPolicies() {
    let suiteName = "InvalidMessageContentPreferencesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "private@example.com"
      )
    )
    defaults.set(
      "invalid", forKey: MessageContentPreferences.StorageKey.remoteContentPolicy.rawValue)
    defaults.set(
      "invalid",
      forKey: MessageContentPreferences.StorageKey.attachmentDownloadPolicy.rawValue
    )
    defaults.set(
      [connectionId.rawValue: "invalid"],
      forKey: MessageContentPreferences.StorageKey.remoteContentOverrides.rawValue
    )

    let preferences = MessageContentPreferences(defaults: defaults)

    XCTAssertEqual(preferences.remoteContentPolicy(for: connectionId), .ask)
    XCTAssertEqual(preferences.attachmentDownloadPolicy, .onDemand)
    XCTAssertNil(preferences.remoteContentOverride(for: connectionId))
  }

  func testAttachmentDownloadPolicyHonorsCurrentNetwork() {
    XCTAssertFalse(AttachmentDownloadPolicy.onDemand.allowsAutomaticDownload(on: .wifi))
    XCTAssertTrue(AttachmentDownloadPolicy.wifi.allowsAutomaticDownload(on: .wifi))
    XCTAssertFalse(AttachmentDownloadPolicy.wifi.allowsAutomaticDownload(on: .cellular))
    XCTAssertTrue(AttachmentDownloadPolicy.always.allowsAutomaticDownload(on: .cellular))
    XCTAssertFalse(AttachmentDownloadPolicy.always.allowsAutomaticDownload(on: .offline))
  }

  func testAttachmentDownloadGateRequiresManualConsentForOnDemand() async throws {
    var requestCount = 0

    do {
      _ = try await AttachmentDownloadGate.download(
        policy: .onDemand,
        network: .wifi,
        trigger: .automatic,
        expectedByteCount: 3
      ) {
        requestCount += 1
        return Data("PDF".utf8)
      }
      XCTFail("Expected automatic On Demand download to be blocked")
    } catch AttachmentDownloadError.blockedByPolicy {
    }
    XCTAssertEqual(requestCount, 0)

    let data = try await AttachmentDownloadGate.download(
      policy: .onDemand,
      network: .cellular,
      trigger: .userInitiated,
      expectedByteCount: 3
    ) {
      requestCount += 1
      return Data("PDF".utf8)
    }
    XCTAssertEqual(data, Data("PDF".utf8))
    XCTAssertEqual(requestCount, 1)
  }

  func testAttachmentDownloadGateEnforcesAutomaticNetworkPolicyAndFailureRetry() async {
    var requestCount = 0
    for network in [AttachmentDownloadNetwork.cellular, .wifi] {
      do {
        _ = try await AttachmentDownloadGate.download(
          policy: .wifi,
          network: network,
          trigger: .automatic,
          expectedByteCount: 3
        ) {
          requestCount += 1
          if requestCount == 1 { throw URLError(.cannotConnectToHost) }
          return Data("PDF".utf8)
        }
        XCTFail("Expected \(network) automatic download to fail")
      } catch AttachmentDownloadError.blockedByPolicy {
        XCTAssertEqual(network, .cellular)
      } catch let error as URLError {
        XCTAssertEqual(network, .wifi)
        XCTAssertEqual(error.code, .cannotConnectToHost)
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(requestCount, 1)

    let retry = try? await AttachmentDownloadGate.download(
      policy: .wifi,
      network: .wifi,
      trigger: .automatic,
      expectedByteCount: 3
    ) {
      requestCount += 1
      return Data("PDF".utf8)
    }
    XCTAssertEqual(retry, Data("PDF".utf8))
    XCTAssertEqual(requestCount, 2)
  }

  func testAttachmentDownloadGatePropagatesCancellation() async {
    let task = Task {
      try await AttachmentDownloadGate.download(
        policy: .always,
        network: .wifi,
        trigger: .automatic,
        expectedByteCount: 3
      ) {
        try await Task.sleep(for: .seconds(10))
        return Data("PDF".utf8)
      }
    }
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testManualAttachmentDownloadConsentIsConsumedOnce() {
    var tracker = AttachmentDownloadRequestTracker()

    XCTAssertEqual(tracker.consumeTrigger(), .automatic)
    tracker.request()
    XCTAssertEqual(tracker.consumeTrigger(), .userInitiated)
    XCTAssertEqual(tracker.consumeTrigger(), .automatic)
  }

  @MainActor
  func testAutomaticAttachmentDownloadCoordinatorBoundsConcurrentWork() async {
    let coordinator = AutomaticAttachmentDownloadCoordinator(maximumConcurrentDownloads: 1)
    await coordinator.acquire()
    var secondDownloadStarted = false
    let secondDownload = Task { @MainActor in
      await coordinator.acquire()
      secondDownloadStarted = true
    }

    await Task.yield()
    XCTAssertFalse(secondDownloadStarted)

    coordinator.release()
    await secondDownload.value
    XCTAssertTrue(secondDownloadStarted)
    coordinator.release()
  }

  func testDownloadedAttachmentStoreReusesBoundedLocalFile() throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("DownloadedAttachmentStoreTests.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let store = DownloadedAttachmentStore(rootDirectory: rootDirectory)
    let messageId = StableProviderMessageIdentity(
      connectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .gmail,
          value: "private@example.com"
        )
      ),
      providerMessageId: "message-001"
    )
    let attachment = MailboxMessageAttachment(
      byteCount: 3,
      filename: "receipt.pdf",
      id: "file-001",
      mimeType: "application/pdf"
    )

    let savedURL = try store.save(
      Data("PDF".utf8),
      attachment: attachment,
      messageId: messageId
    )

    XCTAssertEqual(store.existingURL(attachment: attachment, messageId: messageId), savedURL)
    XCTAssertEqual(try Data(contentsOf: savedURL), Data("PDF".utf8))
    XCTAssertTrue(savedURL.standardizedFileURL.path.hasPrefix(rootDirectory.path + "/"))
    let protection =
      try FileManager.default.attributesOfItem(atPath: savedURL.path)[.protectionKey]
      as? FileProtectionType
    #if targetEnvironment(simulator)
      XCTAssertTrue(protection == nil || protection == .complete)
    #else
      XCTAssertEqual(protection, .complete)
    #endif
    XCTAssertEqual(
      try savedURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
      true
    )
  }

  func testDownloadedAttachmentStoreEvictsOldFilesAndClearsConnectionData() throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("DownloadedAttachmentStoreTests.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let store = DownloadedAttachmentStore(
      rootDirectory: rootDirectory,
      maximumStoredByteCount: 3
    )
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "private@example.com"
      )
    )
    let firstMessageId = StableProviderMessageIdentity(
      connectionId: connectionId,
      providerMessageId: "message-001"
    )
    let secondMessageId = StableProviderMessageIdentity(
      connectionId: connectionId,
      providerMessageId: "message-002"
    )
    let attachment = MailboxMessageAttachment(
      byteCount: 3,
      filename: "receipt.pdf",
      id: "file-001",
      mimeType: "application/pdf"
    )

    _ = try store.save(Data("ONE".utf8), attachment: attachment, messageId: firstMessageId)
    _ = try store.save(Data("TWO".utf8), attachment: attachment, messageId: secondMessageId)

    XCTAssertNil(store.existingURL(attachment: attachment, messageId: firstMessageId))
    XCTAssertNotNil(store.existingURL(attachment: attachment, messageId: secondMessageId))

    try store.clear(connectionId: connectionId)

    XCTAssertNil(store.existingURL(attachment: attachment, messageId: secondMessageId))
  }

  @MainActor
  func testMessagePresentationUsesConnectionOverrideAndNoticePolicy() {
    let suiteName = "MessagePresentationPolicy.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "private@example.com"
      )
    )
    let preferences = MessageContentPreferences(defaults: defaults)
    preferences.remoteContentPolicy = .alwaysLoad
    preferences.setRemoteContentOverride(.never, for: connectionId)

    XCTAssertEqual(preferences.remoteContentPolicy(for: connectionId), .never)
    XCTAssertFalse(
      RemoteMessageContentNotice(policy: .never, requestLoad: {}, state: .blocked)
        .showsLoadButton
    )
    XCTAssertTrue(
      RemoteMessageContentNotice(policy: .ask, requestLoad: {}, state: .blocked)
        .showsLoadButton
    )
  }

  func testPrivacyAndDataMetadataDrivesSignedOutNavigationAndSearch() {
    let destination = SettingsDestination.privacyAndData

    XCTAssertEqual(destination.group, .application)
    XCTAssertEqual(destination.title, "Privacy & Data")
    XCTAssertEqual(destination.systemImage, "hand.raised")
    XCTAssertTrue(destination.isAvailableWhenSignedOut)
    XCTAssertEqual(
      destination.searchItems.map(\.title),
      ["Remote Message Content", "Connection Overrides", "Attachment Downloads"]
    )
    XCTAssertEqual(
      SettingsDestinationRegistry.search(matching: "tracking pixels", isSignedIn: false)
        .map(\.route),
      [destination.route]
    )
  }

  func testAccountAndDevicesAccessibilityDistinguishesDeviceActions() {
    XCTAssertEqual(
      AccountAndDevicesAccessibility.currentDevice,
      "Current Trusted Device"
    )
    XCTAssertEqual(
      AccountAndDevicesAccessibility.renameDevice("Desk Mac"),
      "Rename Desk Mac"
    )
    XCTAssertNotEqual(
      AccountAndDevicesAccessibility.renameDevice("Desk Mac"),
      AccountAndDevicesAccessibility.renameDevice("Travel iPhone")
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
      [.emailAccounts, .accountAndDevices, .appearance, .privacyAndData]
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
      [.appearance, .privacyAndData]
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
