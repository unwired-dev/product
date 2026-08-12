import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
@Suite(.serialized)
final class SettingsDestinationRegistryTests {
  @Test
  func testHistoricalCategorizationScopeUsesWholeSelectedDaysAndAllCategories() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let startDate = Date(timeIntervalSince1970: 3_600)
    let endDate = Date(timeIntervalSince1970: 86_400 + 82_800)

    let scope = CategoryHistoricalSettingsSupport.scope(
      startDate: startDate,
      endDate: endDate,
      categoryId: "",
      collection: .allMail,
      calendar: calendar
    )

    #expect(scope.categoryIds == nil)
    #expect(scope.collection == .allMail)
    #expect(scope.receivedAtOrAfterMilliseconds == 0)
    #expect(scope.receivedBeforeMilliseconds == 172_800_000)
  }

  @Test
  func testHistoricalCategorizationScopeUsesSelectedCategory() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let scope = CategoryHistoricalSettingsSupport.scope(
      startDate: Date(timeIntervalSince1970: 0),
      endDate: Date(timeIntervalSince1970: 0),
      categoryId: "system:flights",
      collection: .role(.inbox),
      calendar: calendar
    )

    #expect(scope.categoryIds == ["system:flights"])
  }

  @Test
  func testHistoricalCategorizationRunMessagesDescribeCompletionAndCancellation() {
    #expect(
      CategoryHistoricalSettingsSupport.completedMessage(categorizedCount: 3)
        == "Historical categorization completed for 3 messages."
    )
    #expect(
      CategoryHistoricalSettingsSupport.cancelledMessage
        == "Historical categorization cancelled; completed assignments were kept."
    )
  }

  @MainActor
  @Test
  func testManualProviderRefreshNotifiesMailShellAfterLoadCompletes() async {
    var events: [String] = []

    await MailboxProviderConnectionPanel.performManualRefresh(
      load: { events.append("load") },
      connectionsDidChange: { events.append("notify") }
    )

    #expect(events == ["load", "notify"])
  }

  @MainActor
  @Test
  func testSharedMailboxManualRefreshLoadsOnlyOnce() async {
    var loadCount = 0

    await MailboxProviderConnectionPanel.performManualRefresh(
      load: { loadCount += 1 },
      connectionsDidChange: {}
    )

    #expect(loadCount == 1)
  }

  @MainActor
  @Test
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

    #expect(events == ["cancel", "remove"])
  }

  @MainActor
  @Test
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

    #expect(events == ["cancel", "remove", "notify"])
  }

  @MainActor
  @Test
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

    #expect(
      Set(events.dropLast()) == [
        "load routed",
        "load generic",
        "load Microsoft",
        "load EWS",
      ])
    #expect(events.last == "notify")
  }

  @MainActor
  @Test
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

    #expect(
      Set(events.dropLast()) == [
        "load generic",
        "load Microsoft",
        "load EWS",
      ])
    #expect(events.last == "notify")
  }

  @Test
  func testSynchronizationIsDisabledForPartialSnapshot() {
    #expect(
      mailboxSynchronizationIsDisabled(
        isMailboxBusy: false,
        isAuthorized: true,
        snapshotIsAuthoritative: false,
        isSynchronizing: false
      ))
    #expect(
      !(mailboxSynchronizationIsDisabled(
        isMailboxBusy: false,
        isAuthorized: true,
        snapshotIsAuthoritative: true,
        isSynchronizing: false
      )))
  }

  @Test
  func testProviderMutationsAreDisabledWhileRoutedConnectionsLoad() {
    #expect(
      providerMutationIsDisabled(
        isMailboxBusy: false,
        isRoutedConnectionsLoading: true
      ))
    #expect(
      !(providerMutationIsDisabled(
        isMailboxBusy: false,
        isRoutedConnectionsLoading: false
      )))
  }

  @MainActor
  @Test
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
    #expect(connectionsAreAuthoritative)
  }

  @Test
  func testProductionKeepsOnlyExistingAccountSettingsEntryPoint() {
    #expect(SettingsEntryPointRegistry.entries(isDevelopmentBuild: false) == [.accountSettings])
    #expect(
      SettingsEntryPointRegistry.entries(isDevelopmentBuild: true) == [
        .accountSettings, .adaptiveSettings,
      ])
  }

  @Test
  func testAppEnablesMultipleScenesForProfileScopedWindows() {
    let sceneManifest =
      Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any]

    #expect(sceneManifest?["UIApplicationSupportsMultipleScenes"] as? Bool == true)
  }

  @Test
  func testAppDeclaresModernLaunchScreen() {
    #expect(Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen") != nil)
  }

  @Test
  func testDevelopmentRegistryContainsOnlyCompleteDestinations() {
    #expect(
      SettingsDestinationRegistry.implementedDestinations == [
        .emailAccounts, .accountAndDevices, .appearance, .privacyAndData, .advanced, .inbox,
        .reading,
        .signatures,
        .swipes,
        .categories,
      ])
    #expect(
      SettingsDestinationRegistry.implementedGroups == [
        .accounts, .application, .automation, .composing, .mail,
      ])
    #expect(
      SettingsDestinationRegistry.destinations(in: .accounts) == [
        .emailAccounts, .accountAndDevices,
      ])
  }

  @Test
  func testCategoriesDestinationExposesCompleteAutomationControls() {
    let destination = SettingsDestination.categories

    #expect(destination.group == .automation)
    #expect(destination.title == "Categories")
    #expect(destination.systemImage == "tag")
    #expect(!(destination.isAvailableWhenSignedOut))
    #expect(
      destination.searchItems.map(\.title) == [
        "Automatic Categorization",
        "Custom Categories",
        "Historical Categorization",
        "Reset Learned Senders",
      ])
    #expect(
      SettingsDestinationRegistry.destinations(in: .automation) == [.categories]
    )
    #expect(
      SettingsDestinationRegistry.search(matching: "learning signals", isSignedIn: true)
        .contains { $0.route.destination == .categories }
    )
  }

  @Test
  func testAccountAndDevicesMetadataDrivesNavigationAndSearch() {
    let destination = SettingsDestination.accountAndDevices

    #expect(destination.group == .accounts)
    #expect(destination.title == "Account & Devices")
    #expect(destination.systemImage == "person.2")
    #expect(!(destination.isAvailableWhenSignedOut))
    #expect(
      destination.searchItems.map(\.title) == [
        "Product Account", "Trusted Devices", "Recovery Key", "Sign Out",
      ])
    #expect(
      SettingsDestinationRegistry.destinations(in: .application) == [
        .appearance, .privacyAndData, .advanced,
      ])
    #expect(SettingsDestinationRegistry.destinations(in: .mail) == [.inbox, .reading, .swipes])
  }

  @Test
  func testSwipeSettingsSearchFindsAssignmentsAndFullSwipe() {
    #expect(
      SettingsDestinationRegistry.search(matching: "archive", isSignedIn: true).contains {
        $0.route.destination == .swipes
      })
    #expect(
      SettingsDestinationRegistry.search(matching: "outermost", isSignedIn: true).contains {
        $0.route.destination == .swipes
      })
  }

  @MainActor
  @Test
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

    #expect(preferences.remoteContentPolicy == .ask)
    #expect(preferences.attachmentDownloadPolicy == .onDemand)
    #expect(preferences.remoteContentOverride(for: connectionId) == nil)

    preferences.remoteContentPolicy = .alwaysLoad
    preferences.attachmentDownloadPolicy = .wifi
    preferences.setRemoteContentOverride(.never, for: connectionId)

    let restored = MessageContentPreferences(defaults: defaults)
    #expect(restored.remoteContentPolicy == .alwaysLoad)
    #expect(restored.attachmentDownloadPolicy == .wifi)
    #expect(restored.remoteContentOverride(for: connectionId) == .never)
    #expect(restored.remoteContentPolicy(for: connectionId) == .never)

    restored.setRemoteContentOverride(nil, for: connectionId)
    #expect(restored.remoteContentPolicy(for: connectionId) == .alwaysLoad)
  }

  @MainActor
  @Test
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

    #expect(preferences.remoteContentPolicy(for: connectionId) == .ask)
    #expect(preferences.attachmentDownloadPolicy == .onDemand)
    #expect(preferences.remoteContentOverride(for: connectionId) == nil)
  }

  @Test
  func testAttachmentDownloadPolicyHonorsCurrentNetwork() {
    #expect(!(AttachmentDownloadPolicy.onDemand.allowsAutomaticDownload(on: .wifi)))
    #expect(AttachmentDownloadPolicy.wifi.allowsAutomaticDownload(on: .wifi))
    #expect(!(AttachmentDownloadPolicy.wifi.allowsAutomaticDownload(on: .cellular)))
    #expect(AttachmentDownloadPolicy.always.allowsAutomaticDownload(on: .cellular))
    #expect(!(AttachmentDownloadPolicy.always.allowsAutomaticDownload(on: .offline)))
  }

  @Test
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
      Issue.record("Expected automatic On Demand download to be blocked")
    } catch AttachmentDownloadError.blockedByPolicy {
    }
    #expect(requestCount == 0)

    let data = try await AttachmentDownloadGate.download(
      policy: .onDemand,
      network: .cellular,
      trigger: .userInitiated,
      expectedByteCount: 3
    ) {
      requestCount += 1
      return Data("PDF".utf8)
    }
    #expect(data == Data("PDF".utf8))
    #expect(requestCount == 1)
  }

  @Test
  func testAttachmentDownloadGateAllowsLocallyBackedAttachmentOffline() async throws {
    var requestCount = 0

    let data = try await AttachmentDownloadGate.download(
      policy: .onDemand,
      network: .offline,
      trigger: .userInitiated,
      expectedByteCount: 3,
      isLocallyAvailable: true
    ) {
      requestCount += 1
      return Data("PDF".utf8)
    }

    #expect(data == Data("PDF".utf8))
    #expect(requestCount == 1)
  }

  @Test
  func testAttachmentDownloadGateRequiresConsentForAutomaticLocallyBackedAttachment() async {
    var requestCount = 0

    do {
      _ = try await AttachmentDownloadGate.download(
        policy: .onDemand,
        network: .offline,
        trigger: .automatic,
        expectedByteCount: 3,
        isLocallyAvailable: true
      ) {
        requestCount += 1
        return Data("PDF".utf8)
      }
      Issue.record("Expected automatic On Demand download to be blocked")
    } catch AttachmentDownloadError.blockedByPolicy {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(requestCount == 0)
  }

  @Test
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
        Issue.record("Expected \(network) automatic download to fail")
      } catch AttachmentDownloadError.blockedByPolicy {
        #expect(network == .cellular)
      } catch let error as URLError {
        #expect(network == .wifi)
        #expect(error.code == .cannotConnectToHost)
      } catch {
        Issue.record("Unexpected error: \(error)")
      }
    }
    #expect(requestCount == 1)

    let retry = try? await AttachmentDownloadGate.download(
      policy: .wifi,
      network: .wifi,
      trigger: .automatic,
      expectedByteCount: 3
    ) {
      requestCount += 1
      return Data("PDF".utf8)
    }
    #expect(retry == Data("PDF".utf8))
    #expect(requestCount == 2)
  }

  @Test
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
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected CancellationError, got \(error)")
    }
  }

  @Test
  func testManualAttachmentDownloadConsentIsConsumedOnce() {
    var tracker = AttachmentDownloadRequestTracker()

    #expect(tracker.consumeTrigger() == .automatic)
    tracker.request()
    #expect(tracker.consumeTrigger() == .userInitiated)
    #expect(tracker.consumeTrigger() == .userInitiated)
    tracker.finish(requestCount: tracker.requestCount)
    #expect(tracker.consumeTrigger() == .automatic)
  }

  @Test
  func testCancelledAttachmentDownloadDoesNotConsumeNewerRequest() {
    var tracker = AttachmentDownloadRequestTracker()
    tracker.request()
    let cancelledRequestCount = tracker.requestCount
    #expect(tracker.consumeTrigger() == .userInitiated)

    tracker.request()
    tracker.finish(requestCount: cancelledRequestCount)

    #expect(tracker.consumeTrigger() == .userInitiated)
    tracker.finish(requestCount: tracker.requestCount)
    #expect(tracker.consumeTrigger() == .automatic)
  }

  @MainActor
  @Test
  func testAutomaticAttachmentDownloadCoordinatorBoundsConcurrentWork() async {
    let coordinator = AutomaticAttachmentDownloadCoordinator(maximumConcurrentDownloads: 1)
    _ = await coordinator.acquire()
    var secondDownloadStarted = false
    let secondDownload = Task { @MainActor in
      secondDownloadStarted = await coordinator.acquire()
    }

    await Task.yield()
    #expect(!(secondDownloadStarted))

    coordinator.release()
    await secondDownload.value
    #expect(secondDownloadStarted)
    coordinator.release()
  }

  @Test
  func testAttachmentPreviewAvailabilityUsesPassiveFormatsOnly() {
    let image = MailboxMessageAttachment(
      byteCount: 3,
      filename: "photo.png",
      id: "image",
      mimeType: "image/png"
    )
    let pdf = MailboxMessageAttachment(
      byteCount: 3,
      filename: "receipt.pdf",
      id: "pdf",
      mimeType: "application/pdf"
    )
    let text = MailboxMessageAttachment(
      byteCount: 3,
      filename: "notes.txt",
      id: "text",
      mimeType: "text/plain"
    )
    let archive = MailboxMessageAttachment(
      byteCount: 3,
      filename: "files.zip",
      id: "archive",
      mimeType: "application/zip"
    )
    let genericPDF = MailboxMessageAttachment(
      byteCount: 3,
      filename: "receipt.pdf",
      id: "generic-pdf",
      mimeType: "application/octet-stream"
    )

    #expect(AttachmentPreviewAvailability(attachment: image) == .thumbnailAndQuickLook)
    #expect(AttachmentPreviewAvailability(attachment: pdf) == .thumbnailAndQuickLook)
    #expect(AttachmentPreviewAvailability(attachment: text) == .quickLook)
    #expect(AttachmentPreviewAvailability(attachment: archive) == .unavailable)
    #expect(AttachmentPreviewAvailability(attachment: genericPDF) == .thumbnailAndQuickLook)
  }

  @Test
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

    #expect(store.existingURL(attachment: attachment, messageId: messageId) == savedURL)
    #expect(try Data(contentsOf: savedURL) == Data("PDF".utf8))
    #expect(savedURL.standardizedFileURL.path.hasPrefix(rootDirectory.path + "/"))
    let protection =
      try FileManager.default.attributesOfItem(atPath: savedURL.path)[.protectionKey]
      as? FileProtectionType
    #if targetEnvironment(simulator)
      #expect(protection == nil || protection == .complete)
    #else
      #expect(protection == .complete)
    #endif
    #expect(
      try savedURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
  }

  @Test
  func testAttachmentPreviewAccessUpdatesRecencyWithoutCreatingCache() throws {
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
    let oldDate = Date(timeIntervalSince1970: 1_000)
    try FileManager.default.setAttributes(
      [.modificationDate: oldDate],
      ofItemAtPath: savedURL.path
    )
    let pathsBeforeAccess = try Set(
      FileManager.default.subpathsOfDirectory(atPath: rootDirectory.path))
    let accessedAt = Date(timeIntervalSince1970: 2_000)

    let previewURL = try store.previewURL(
      attachment: attachment,
      messageId: messageId,
      accessedAt: accessedAt
    )

    #expect(previewURL == savedURL)
    #expect(
      try savedURL.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate == accessedAt)
    #expect(
      try Set(FileManager.default.subpathsOfDirectory(atPath: rootDirectory.path))
        == pathsBeforeAccess)
  }

  @Test
  func testDownloadedAttachmentStoreCountsHiddenFilesTowardsQuota() throws {
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
    let hiddenAttachment = MailboxMessageAttachment(
      byteCount: 3,
      filename: ".private.pdf",
      id: "hidden-file",
      mimeType: "application/pdf"
    )
    let visibleAttachment = MailboxMessageAttachment(
      byteCount: 3,
      filename: "visible.pdf",
      id: "visible-file",
      mimeType: "application/pdf"
    )

    _ = try store.save(
      Data("ONE".utf8),
      attachment: hiddenAttachment,
      messageId: firstMessageId
    )
    _ = try store.save(
      Data("TWO".utf8),
      attachment: visibleAttachment,
      messageId: secondMessageId
    )

    #expect(store.existingURL(attachment: hiddenAttachment, messageId: firstMessageId) == nil)
    #expect(store.existingURL(attachment: visibleAttachment, messageId: secondMessageId) != nil)
  }

  @Test
  func testDownloadedAttachmentStoreRejectsWriteStartedBeforeConnectionClear() throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("DownloadedAttachmentStoreTests.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let store = DownloadedAttachmentStore(rootDirectory: rootDirectory)
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "private@example.com"
      )
    )
    let messageId = StableProviderMessageIdentity(
      connectionId: connectionId,
      providerMessageId: "message-001"
    )
    let attachment = MailboxMessageAttachment(
      byteCount: 3,
      filename: "private.pdf",
      id: "file-001",
      mimeType: "application/pdf"
    )
    let writePermit = store.makeWritePermit(connectionId: connectionId)

    try store.clear(connectionId: connectionId)

    #expect {
      try store.save(
        Data("PDF".utf8),
        attachment: attachment,
        messageId: messageId,
        writePermit: writePermit
      )
    } throws: { error in
      #expect(error is CancellationError)
      return true
    }
    #expect(store.existingURL(attachment: attachment, messageId: messageId) == nil)
  }

  @Test
  func testDownloadedAttachmentStoreBoundsPersistedFilename() throws {
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
      filename: String(repeating: "a", count: 300) + ".pdf",
      id: "file-001",
      mimeType: "application/pdf"
    )

    let savedURL = try store.save(
      Data("PDF".utf8),
      attachment: attachment,
      messageId: messageId
    )

    #expect(savedURL.lastPathComponent.utf8.count <= 255)
    #expect(savedURL.pathExtension == "pdf")
    #expect(try Data(contentsOf: savedURL) == Data("PDF".utf8))
  }

  @Test
  func testDownloadedAttachmentStoreReplacesSeparatorOnlyFilename() throws {
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
      filename: "/",
      id: "file-001",
      mimeType: "application/pdf"
    )

    let savedURL = try store.save(
      Data("PDF".utf8),
      attachment: attachment,
      messageId: messageId
    )

    #expect(savedURL.lastPathComponent == "Attachment")
    #expect(try Data(contentsOf: savedURL) == Data("PDF".utf8))
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testDownloadedAttachmentStoreEvictsOldFilesAndClearsConnectionData() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("DownloadedAttachmentStoreTests.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let notificationCenter = NotificationCenter()
    let store = DownloadedAttachmentStore(
      rootDirectory: rootDirectory,
      maximumStoredByteCount: 3,
      notificationCenter: notificationCenter
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
    let evictionNotifications = expectation(description: "Attachment evictions are published")
    evictionNotifications.expectedFulfillmentCount = 2
    let observer = notificationCenter.addObserver(
      forName: .downloadedAttachmentStoreDidEvict,
      object: nil,
      queue: nil
    ) { _ in
      evictionNotifications.fulfill()
    }
    defer { notificationCenter.removeObserver(observer) }

    _ = try store.save(Data("ONE".utf8), attachment: attachment, messageId: firstMessageId)
    _ = try store.save(Data("TWO".utf8), attachment: attachment, messageId: secondMessageId)

    #expect(store.existingURL(attachment: attachment, messageId: firstMessageId) == nil)
    #expect(store.existingURL(attachment: attachment, messageId: secondMessageId) != nil)

    try store.clear(connectionId: connectionId)

    #expect(store.existingURL(attachment: attachment, messageId: secondMessageId) == nil)

    let otherMessageId = StableProviderMessageIdentity(
      connectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .gmail,
          value: "other@example.com"
        )
      ),
      providerMessageId: "message-003"
    )
    _ = try store.save(Data("ONE".utf8), attachment: attachment, messageId: firstMessageId)
    _ = try store.save(Data("TWO".utf8), attachment: attachment, messageId: otherMessageId)
    await fulfillment(of: [evictionNotifications], timeout: 1)
    try store.clearAll()

    #expect(store.existingURL(attachment: attachment, messageId: firstMessageId) == nil)
    #expect(store.existingURL(attachment: attachment, messageId: otherMessageId) == nil)
  }

  @MainActor
  @Test
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

    #expect(preferences.remoteContentPolicy(for: connectionId) == .never)
    #expect(
      !(RemoteMessageContentNotice(policy: .never, requestLoad: {}, state: .blocked)
        .showsLoadButton))
    #expect(
      RemoteMessageContentNotice(policy: .ask, requestLoad: {}, state: .blocked)
        .showsLoadButton)
  }

  @Test
  func testPrivacyAndDataMetadataDrivesSignedOutNavigationAndSearch() {
    let destination = SettingsDestination.privacyAndData

    #expect(destination.group == .application)
    #expect(destination.title == "Privacy & Data")
    #expect(destination.systemImage == "hand.raised")
    #expect(destination.isAvailableWhenSignedOut)
    #expect(
      destination.searchItems.map(\.title) == [
        "Remote Message Content", "Connection Overrides", "Attachment Downloads",
      ])
    #expect(
      SettingsDestinationRegistry.search(matching: "tracking pixels", isSignedIn: false)
        .map(\.route) == [destination.route])
  }

  @Test
  func testAdvancedMetadataDrivesSignedOutNavigationAndSearch() {
    let destination = SettingsDestination.advanced

    #expect(destination.group == .application)
    #expect(destination.title == "Advanced")
    #expect(destination.systemImage == "wrench.and.screwdriver")
    #expect(destination.isAvailableWhenSignedOut)
    #expect(
      destination.searchItems.map(\.title) == [
        "Synchronization Health", "Diagnostics", "Local Maintenance",
      ])
    #expect(
      SettingsDestinationRegistry.search(matching: "redacted report", isSignedIn: false)
        .map(\.route) == [destination.route])
  }

  @Test
  func testAccountAndDevicesAccessibilityDistinguishesDeviceActions() {
    #expect(AccountAndDevicesAccessibility.currentDevice == "Current Trusted Device")
    #expect(AccountAndDevicesAccessibility.renameDevice("Desk Mac") == "Rename Desk Mac")
    #expect(AccountAndDevicesAccessibility.revokeDevice("Desk Mac") == "Revoke Desk Mac")
    #expect(
      AccountAndDevicesAccessibility.renameDevice("Desk Mac")
        != AccountAndDevicesAccessibility.renameDevice("Travel iPhone"))
    #expect(
      AccountAndDevicesAccessibility.revokeDevice("Desk Mac")
        != AccountAndDevicesAccessibility.revokeDevice("Travel iPhone"))
  }

  @Test
  func testEmailAccountsMetadataDrivesNavigationAndSearch() {
    let destination = SettingsDestination.emailAccounts

    #expect(destination.group == .accounts)
    #expect(destination.title == "Email Accounts")
    #expect(destination.systemImage == "at")
    #expect(destination.route == .emailAccounts)
    #expect(!(destination.isAvailableWhenSignedOut))
    #expect(
      destination.searchItems.map(\.title) == [
        "Mailbox Connections",
        "Authorization",
        "Default Sending Connection",
        "Synchronize",
        "Mailbox Roles",
        "Gmail",
        "Microsoft 365",
        "On-Premises Exchange",
        "Other Mail Server",
      ])
  }

  @Test
  func testAppearanceMetadataDrivesSignedOutNavigationAndSearch() {
    let destination = SettingsDestination.appearance

    #expect(destination.group == .application)
    #expect(destination.title == "Appearance")
    #expect(destination.systemImage == "paintbrush")
    #expect(destination.route == SettingsRoute(destination: .appearance))
    #expect(destination.isAvailableWhenSignedOut)
    #expect(
      destination.searchItems.map(\.title) == [
        "Theme", "Reading Text Size", "Message Body", "Increased Contrast",
      ])
    #expect(
      SettingsDestinationRegistry.search(matching: "serif", isSignedIn: false)
        .map(\.route) == [.appearance(.messageBody)])
    #expect(
      destination.searchItems.map(\.route) == [
        .appearance(.theme),
        .appearance(.readingTextSize),
        .appearance(.messageBody),
        .appearance(.increasedContrast),
      ])
  }

  @Test
  func testSearchMatchesDestinationGroupSectionAndControlLabels() {
    #expect(
      SettingsDestinationRegistry.search(matching: "email accounts", isSignedIn: true) == [
        SettingsSearchResult(
          title: "Email Accounts",
          subtitle: "Accounts",
          route: .mailboxConnections
        )
      ])
    #expect(
      SettingsDestinationRegistry.search(matching: "accounts", isSignedIn: true)
        .contains { $0.route == .mailboxConnections })
    #expect(
      SettingsDestinationRegistry.search(matching: "mailbox connections", isSignedIn: true)
        .map(\.route) == [.mailboxConnections])
    #expect(
      SettingsDestinationRegistry.search(matching: "AuThOrIzAtIoN", isSignedIn: true)
        .map(\.route) == [.authorization(connectionId: nil)])
    #expect(
      SettingsDestinationRegistry.search(matching: "on premises", isSignedIn: true)
        .map(\.route) == [.provider(.exchangeWebServices)])
    #expect(
      SettingsDestinationRegistry.search(matching: "manually", isSignedIn: true)
        .contains { $0.title == "Mark Opened Messages Read" })
    #expect(
      SettingsDestinationRegistry.search(matching: "read receipts", isSignedIn: true)
        .map(\.route) == [
          .readReceipt(connectionId: nil, field: .incoming),
          .readReceipt(connectionId: nil, field: .outgoing),
        ])
  }

  @Test
  func testSearchResultsHaveUniqueIdentitiesWhenRoutesOverlap() {
    let results = SettingsDestinationRegistry.search(matching: "mail", isSignedIn: true)

    #expect(Set(results.map(\.id)).count == results.count)
  }

  @Test
  func testSearchUsesOnlyStaticMetadata() {
    #expect(
      SettingsDestinationRegistry.search(
        matching: "private@example.com",
        isSignedIn: true
      ).isEmpty)
    #expect(
      SettingsDestinationRegistry.search(
        matching: "signature body",
        isSignedIn: true
      ).isEmpty)
    #expect(
      SettingsDestinationRegistry.search(
        matching: "diagnostic report contents",
        isSignedIn: true
      ).isEmpty)
    #expect(
      SettingsDestinationRegistry.search(
        matching: "Authorization",
        isSignedIn: false
      ).isEmpty)
  }

  @Test
  func testContextualRoutesMapToTheirFutureDestinationsWithoutMakingThemVisible() {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "account"
      )
    )

    #expect(SettingsRoute.authorization(connectionId: connectionId).destination == .emailAccounts)
    #expect(SettingsRoute.notificationPermission.destination == .notifications)
    #expect(SettingsRoute.missingSignature(connectionId: connectionId).destination == .signatures)
    #expect(
      SettingsRoute.readReceipt(connectionId: connectionId, field: .incoming).destination
        == .reading)
    #expect(SettingsRoute.storage.destination == .privacyAndData)
    #expect(
      SettingsRoute.preferenceConflict(destination: .inbox, field: "previewLength").destination
        == .inbox)
    #expect(
      SettingsDestinationRegistry.resolveRoute(
        .preferenceConflict(destination: .inbox, field: "previewLength"),
        isSignedIn: true
      ) == .preferenceConflict(destination: .inbox, field: "previewLength"))
    #expect(
      SettingsDestinationRegistry.resolveRoute(
        .notificationPermission,
        isSignedIn: true
      ) == nil)
    #expect(
      SettingsDestinationRegistry.resolveRoute(
        .authorization(connectionId: connectionId),
        isSignedIn: true
      ) == .authorization(connectionId: connectionId))
    #expect(
      SettingsDestinationRegistry.implementedDestinations == [
        .emailAccounts, .accountAndDevices, .appearance, .privacyAndData, .advanced, .inbox,
        .reading,
        .signatures,
        .swipes,
        .categories,
      ])
  }

  @Test
  func testUnsavedChangesRequireConfirmationBeforeChangingContext() {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "account"
      )
    )
    let current = SettingsRoute.emailAccounts
    let requested = SettingsRoute.authorization(connectionId: connectionId)

    #expect(
      SettingsNavigationPolicy.decision(
        currentRoute: current,
        requestedRoute: requested,
        hasUnsavedChanges: true,
        isSignedIn: true
      ) == .confirmDiscard(requested))
    #expect(
      SettingsNavigationPolicy.decision(
        currentRoute: current,
        requestedRoute: requested,
        hasUnsavedChanges: false,
        isSignedIn: true
      ) == .navigate(requested))
    #expect(
      SettingsNavigationPolicy.decision(
        currentRoute: requested,
        requestedRoute: requested,
        hasUnsavedChanges: true,
        isSignedIn: true
      ) == .navigate(requested))
  }

  @Test
  func testDiscardIsBlockedWhileSetupIsWorking() {
    #expect(!(SettingsNavigationPolicy.canDiscardChanges(isSetupWorking: true)))
    #expect(SettingsNavigationPolicy.canDiscardChanges(isSetupWorking: false))
  }

  @Test
  func testUnavailableDeepLinksDoNotReplaceTheCurrentDestination() {
    #expect(
      SettingsNavigationPolicy.decision(
        currentRoute: .emailAccounts,
        requestedRoute: .notificationPermission,
        hasUnsavedChanges: false,
        isSignedIn: true
      ) == .unavailable)
  }

  @Test
  func testEmailAccountAttentionIncludesOnlyActionableFailures() {
    #expect(
      SettingsAttention.emailAccounts(
        authorizationRequired: true,
        syncFailureMessage: "Server rejected the request."
      )
        == SettingsAttention(
          destination: .emailAccounts,
          kind: .authorization,
          message: "One or more Mailbox Connections require authorization on this device."
        ))
    #expect(
      SettingsAttention.emailAccounts(
        authorizationRequired: false,
        syncFailureMessage: "Server rejected the request."
      )
        == SettingsAttention(
          destination: .emailAccounts,
          kind: .sync,
          message: "Mailbox synchronization failed: Server rejected the request."
        ))
    #expect(
      SettingsAttention.emailAccounts(
        authorizationRequired: false,
        syncFailureMessage: nil
      ) == nil)
  }

  @Test
  func testNavigationLayoutUsesCompactStackOnlyForCompactWidth() {
    #expect(SettingsNavigationLayout.resolve(.compact) == .compact)
    #expect(SettingsNavigationLayout.resolve(.regular) == .split)
    #expect(SettingsNavigationLayout.resolve(nil) == .split)
  }

  @Test
  func testEmailAccountRoutesChooseFocusAndHighlightTargets() {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "account"
      )
    )

    #expect(EmailAccountsSettingsView.navigationFocus(for: .mailboxConnections) == .summary)
    #expect(
      EmailAccountsSettingsView.navigationFocus(
        for: .authorization(connectionId: connectionId)
      ) == .connection(connectionId.rawValue))
    #expect(
      EmailAccountsSettingsView.navigationFocus(for: .mailboxRoles(connectionId: nil))
        == .genericMail)
    #expect(
      EmailAccountsSettingsView.navigationFocus(for: .provider(.microsoftGraph))
        == .provider(MailProviderId.microsoftGraph.rawValue))
    #expect(EmailAccountsSettingsView.navigationFocus(for: .notificationPermission) == nil)
  }

  @Test
  func testActionableMailboxStatusesLinkToTheAffectedConnection() {
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "account"
      )
    )

    #expect(
      MailboxStatusSettingsLink.route(
        for: .authorizationRequired(lastSuccessfulSyncAt: nil),
        connectionId: connectionId
      ) == .authorization(connectionId: connectionId))
    #expect(
      MailboxStatusSettingsLink.route(
        for: MailboxSyncStatus(
          lastSuccessfulSyncAt: nil,
          phase: .failed("Server rejected the request.")
        ),
        connectionId: connectionId
      ) == .synchronization(connectionId: connectionId))
    #expect(
      MailboxStatusSettingsLink.route(
        for: MailboxSyncStatus(lastSuccessfulSyncAt: nil, phase: .offline),
        connectionId: connectionId
      ) == nil)
  }

  @MainActor
  @Test
  func testRouterPublishesRepeatedRequestsForTheSameRoute() {
    let router = SettingsRouter()

    router.open(.emailAccounts)
    let firstRequest = router.request
    router.open(.emailAccounts)

    #expect(firstRequest?.route == .emailAccounts)
    #expect(router.request?.route == .emailAccounts)
    #expect(firstRequest?.id != router.request?.id)
  }

  @Test
  func testSignedInSettingsDefaultsToEmailAccounts() {
    #expect(SettingsDestinationRegistry.defaultDestination(isSignedIn: true) == .emailAccounts)
    #expect(SettingsDestinationRegistry.defaultDestination(isSignedIn: false) == .appearance)
  }

  @Test
  func testSignedOutSettingsHideUnavailableDestinations() {
    #expect(SettingsDestinationRegistry.implementedGroups(isSignedIn: false) == [.application])
    #expect(SettingsDestinationRegistry.destinations(in: .accounts, isSignedIn: false).isEmpty)
    #expect(
      SettingsDestinationRegistry.destinations(in: .application, isSignedIn: false) == [
        .appearance, .privacyAndData, .advanced,
      ])
  }

  @MainActor
  @Test
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

    #expect(coordinator.isBusy(productAccountId: "product-account"))
    await coordinator.cancelBodyPrefetch(productAccountId: "product-account")
    #expect(cancelledWindows == ["first", "second"])

    coordinator.unregister(
      productAccountId: "product-account",
      registrationId: secondRegistrationId
    )
    #expect(coordinator.isBusy(productAccountId: "product-account"))
    coordinator.unregister(
      productAccountId: "product-account",
      registrationId: firstRegistrationId
    )
    #expect(!(coordinator.isBusy(productAccountId: "product-account")))
  }

  @Test
  func testStoredDestinationFallsBackToFirstAvailableDestination() {
    #expect(
      SettingsDestinationRegistry.resolveDestination(
        storedRawValue: SettingsDestination.emailAccounts.rawValue,
        isSignedIn: true
      ) == .emailAccounts)
    #expect(
      SettingsDestinationRegistry.resolveDestination(
        storedRawValue: "removed-destination",
        isSignedIn: true
      ) == .emailAccounts)
    #expect(
      SettingsDestinationRegistry.resolveDestination(
        storedRawValue: SettingsDestination.emailAccounts.rawValue,
        isSignedIn: false
      ) == .appearance)
    #expect(
      SettingsDestinationRegistry.resolveDestination(
        storedRawValue: SettingsDestination.appearance.rawValue,
        isSignedIn: false
      ) == .appearance)
  }
}

@Suite(.serialized)
final class AppearancePreferencesTests {
  @MainActor
  @Test
  func testDefaultsAreDeviceLocalSystemAppearanceValues() {
    withIsolatedDefaults { defaults in
      let preferences = AppearancePreferences(defaults: defaults)

      #expect(preferences.theme == .system)
      #expect(preferences.readingTextSize == .standard)
      #expect(preferences.messageBodyTypeface == .senderFormatting)
      #expect(!(preferences.increasedContrast))
    }
  }

  @MainActor
  @Test
  func testChangesPersistWithoutNetworkOrAccountState() {
    withIsolatedDefaults { defaults in
      let preferences = AppearancePreferences(defaults: defaults)
      preferences.theme = .dark
      preferences.readingTextSize = .large
      preferences.messageBodyTypeface = .systemSerif
      preferences.increasedContrast = true

      let reloaded = AppearancePreferences(defaults: defaults)

      #expect(reloaded.theme == .dark)
      #expect(reloaded.readingTextSize == .large)
      #expect(reloaded.messageBodyTypeface == .systemSerif)
      #expect(reloaded.increasedContrast)
    }
  }

  @MainActor
  @Test
  func testInvalidStoredValuesFallBackIndependently() {
    withIsolatedDefaults { defaults in
      defaults.set("invalid", forKey: AppearancePreferences.StorageKey.theme.rawValue)
      defaults.set("invalid", forKey: AppearancePreferences.StorageKey.readingTextSize.rawValue)
      defaults.set("invalid", forKey: AppearancePreferences.StorageKey.messageBodyTypeface.rawValue)
      defaults.set(true, forKey: AppearancePreferences.StorageKey.increasedContrast.rawValue)

      let preferences = AppearancePreferences(defaults: defaults)

      #expect(preferences.theme == .system)
      #expect(preferences.readingTextSize == .standard)
      #expect(preferences.messageBodyTypeface == .senderFormatting)
      #expect(preferences.increasedContrast)
    }
  }

  @MainActor
  private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
    let suiteName = "AppearancePreferencesTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Expected isolated UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    body(defaults)
  }
}

@Suite(.serialized)
final class SettingsConnectionRefreshTests {
  @MainActor
  @Test
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

    #expect(
      Set(events.dropLast()) == [
        "load routed",
        "load generic",
        "load EWS",
      ])
    #expect(events.last == "notify")
  }
}
