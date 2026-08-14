import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length

@Suite(.serialized)
// swiftlint:disable:next type_body_length
final class ThreadSnoozeSyncServiceTests {
  private let firstDeviceSession = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "first-device-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )
  private let secondDeviceSession = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "second-device-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-002"
  )

  @Test
  func testSnoozeSynchronizesWithinOneProfileAndMailboxConnection() async throws {
    let services = try makeServices()
    let dueAtMilliseconds: Int64 = 1_781_286_400_000

    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: dueAtMilliseconds,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let snapshot = try await services.secondDevice.load(
      profileId: Self.profileId,
      session: secondDeviceSession
    )

    #expect(snapshot.activeThreadIds(atMilliseconds: dueAtMilliseconds - 1) == [Self.thread.id])
    #expect(snapshot.activeThreadIds(atMilliseconds: dueAtMilliseconds) == [])
    #expect(snapshot.snoozes[Self.thread.id]?.notificationOwnerDeviceId == "trusted-device-001")
  }

  @Test
  func testOfflineRestartLoadsActiveSnoozesFromCiphertextCache() async throws {
    let keyMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 7, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 8, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    try keyMaterialStore.save(
      keyMaterial,
      productAccountId: firstDeviceSession.productAccountId
    )
    let cache = InMemoryProductSyncCiphertextCache()
    let onlineService = ThreadSnoozeSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyMaterialStore,
        transport: InMemoryProductSyncRecordTransport()
      ),
      ciphertextCache: cache
    )
    try await onlineService.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_286_400_000,
      profileId: Self.profileId,
      session: firstDeviceSession
    )

    let restartedOfflineService = ThreadSnoozeSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyMaterialStore,
        transport: FailingThreadSnoozeProductSyncRecordTransport()
      ),
      ciphertextCache: cache
    )
    let snapshot = try await restartedOfflineService.load(
      profileId: Self.profileId,
      session: firstDeviceSession
    )

    #expect(snapshot.snoozes[Self.thread.id]?.dueAtMilliseconds == 1_781_286_400_000)
  }

  @Test
  func testRescheduleTransfersNotificationOwnershipAndCancelConverges() async throws {
    let services = try makeServices()
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_286_400_000,
      profileId: Self.profileId,
      session: firstDeviceSession
    )

    try await services.secondDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_372_800_000,
      profileId: Self.profileId,
      session: secondDeviceSession
    )
    let rescheduled = try await services.firstDevice.load(
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    #expect(rescheduled.snoozes[Self.thread.id]?.dueAtMilliseconds == 1_781_372_800_000)
    #expect(
      rescheduled.snoozes[Self.thread.id]?.notificationOwnerDeviceId == "trusted-device-002")

    try await services.firstDevice.cancel(
      threadId: Self.thread.id,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let cancelled = try await services.secondDevice.load(
      profileId: Self.profileId,
      session: secondDeviceSession
    )
    #expect(cancelled.snoozes.isEmpty)
  }

  @Test
  func testNewMessageEndsSnoozeBeforeItsDueInstant() async throws {
    let services = try makeServices()
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_286_400_000,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let newMessage = Self.message(
      id: "message-002",
      receivedAtMilliseconds: 1_781_200_000_000
    )

    let reconciled = try await services.secondDevice.reconcile(
      with: Self.thread.messages + [newMessage],
      profileId: Self.profileId,
      session: secondDeviceSession
    )

    #expect(reconciled.snoozes.isEmpty)
    #expect(
      try await services.firstDevice.load(
        profileId: Self.profileId,
        session: firstDeviceSession
      ).snoozes.isEmpty)
  }

  @Test
  func testNewMessageReconcilePreservesConcurrentlyRescheduledSnooze() async throws {
    let transport = SnoozeReconcileRaceTransport()
    let services = try makeServices(transport: transport)
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_286_400_000,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let newMessage = Self.message(
      id: "message-002",
      receivedAtMilliseconds: 1_781_200_000_000
    )
    let updatedThread = try #require(
      MailboxThread.group(Self.thread.messages + [newMessage]).first
    )
    await transport.holdNextList()

    let reconcile = Task {
      try await services.firstDevice.reconcile(
        with: updatedThread.messages,
        profileId: Self.profileId,
        session: firstDeviceSession
      )
    }
    await transport.waitUntilListIsHeld()
    try await services.secondDevice.snooze(
      thread: updatedThread,
      dueAtMilliseconds: 1_781_372_800_000,
      profileId: Self.profileId,
      session: secondDeviceSession
    )
    await transport.releaseList()
    let reconciled = try await reconcile.value

    #expect(reconciled.snoozes[updatedThread.id]?.anchorMessageId == newMessage.id)
    #expect(reconciled.snoozes[updatedThread.id]?.dueAtMilliseconds == 1_781_372_800_000)
  }

  @Test
  func testEqualTimestampMessageEndsSnoozeEvenWhenAnchorSortsFirst() async throws {
    let services = try makeServices()
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_286_400_000,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let sameTimestampMessage = Self.message(
      id: "message-999",
      receivedAtMilliseconds: Self.thread.latestMessage.providerInternalDateMilliseconds
    )

    let reconciled = try await services.secondDevice.reconcile(
      with: Self.thread.messages + [sameTimestampMessage],
      profileId: Self.profileId,
      session: secondDeviceSession
    )

    #expect(reconciled.snoozes.isEmpty)
  }

  @Test
  func testPreexistingEqualTimestampMessageDoesNotEndSnooze() async throws {
    let services = try makeServices()
    let existingMessage = Self.message(
      id: "message-000",
      receivedAtMilliseconds: Self.thread.latestMessage.providerInternalDateMilliseconds
    )
    let initialThread = try #require(
      MailboxThread.group(Self.thread.messages + [existingMessage]).first
    )
    try await services.firstDevice.snooze(
      thread: initialThread,
      dueAtMilliseconds: 1_781_286_400_000,
      profileId: Self.profileId,
      session: firstDeviceSession
    )

    let reconciled = try await services.secondDevice.reconcile(
      with: initialThread.messages,
      profileId: Self.profileId,
      session: secondDeviceSession
    )

    #expect(reconciled.snoozes[initialThread.id] != nil)
  }

  @Test
  func testProviderThreadIdentityChangeMigratesSnoozeByAnchor() async throws {
    let services = try makeServices()
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_286_400_000,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let movedAnchor = Self.message(
      id: Self.thread.latestMessage.providerMessageId,
      receivedAtMilliseconds: Self.thread.latestMessage.providerInternalDateMilliseconds,
      threadId: "thread-002"
    )
    let movedThread = try #require(MailboxThread.group([movedAnchor]).first)

    let reconciled = try await services.secondDevice.reconcile(
      with: [movedAnchor],
      profileId: Self.profileId,
      session: secondDeviceSession
    )
    let reloaded = try await services.firstDevice.load(
      profileId: Self.profileId,
      session: firstDeviceSession
    )

    #expect(reconciled.snoozes[Self.thread.id] == nil)
    #expect(reconciled.snoozes[movedThread.id]?.anchorMessageId == movedAnchor.id)
    #expect(reloaded == reconciled)
  }

  @Test
  func testMigrationPreservesConcurrentlyRescheduledSourceSnooze() async throws {
    let transport = SnoozeReconcileRaceTransport()
    let services = try makeServices(transport: transport)
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_286_400_000,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let movedAnchor = Self.message(
      id: Self.thread.latestMessage.providerMessageId,
      receivedAtMilliseconds: Self.thread.latestMessage.providerInternalDateMilliseconds,
      threadId: "thread-002"
    )
    let movedThread = try #require(MailboxThread.group([movedAnchor]).first)
    await transport.holdNextList()

    let reconcile = Task {
      try await services.firstDevice.reconcile(
        with: [movedAnchor],
        profileId: Self.profileId,
        session: firstDeviceSession
      )
    }
    await transport.waitUntilListIsHeld()
    try await services.secondDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_372_800_000,
      profileId: Self.profileId,
      session: secondDeviceSession
    )
    await transport.releaseList()
    let reconciled = try await reconcile.value
    let reloaded = try await services.firstDevice.load(
      profileId: Self.profileId,
      session: firstDeviceSession
    )

    #expect(reconciled.snoozes[Self.thread.id] == nil)
    #expect(reconciled.snoozes[movedThread.id]?.dueAtMilliseconds == 1_781_372_800_000)
    #expect(
      reconciled.snoozes[movedThread.id]?.notificationOwnerDeviceId
        == secondDeviceSession.trustedDeviceId)
    #expect(reloaded == reconciled)
  }

  @Test
  func testMigrationCancelsSnoozeWhenNewThreadAlreadyContainsNewMail() async throws {
    let services = try makeServices()
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_286_400_000,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let movedAnchor = Self.message(
      id: Self.thread.latestMessage.providerMessageId,
      receivedAtMilliseconds: Self.thread.latestMessage.providerInternalDateMilliseconds,
      threadId: "thread-002"
    )
    let newMessage = Self.message(
      id: "message-002",
      receivedAtMilliseconds: movedAnchor.providerInternalDateMilliseconds + 1,
      threadId: "thread-002"
    )

    let reconciled = try await services.secondDevice.reconcile(
      with: [movedAnchor, newMessage],
      profileId: Self.profileId,
      session: secondDeviceSession
    )

    #expect(reconciled.snoozes.isEmpty)
  }

  @Test
  func testMigrationPreservesNewerTargetSnooze() async throws {
    let services = try makeServices(
      firstNowMilliseconds: 1_781_200_000_001,
      secondNowMilliseconds: 1_781_200_000_002
    )
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_286_400_000,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let targetAnchor = Self.message(
      id: "target-anchor",
      receivedAtMilliseconds: Self.thread.latestMessage.providerInternalDateMilliseconds + 10,
      threadId: "thread-002"
    )
    let targetThread = try #require(MailboxThread.group([targetAnchor]).first)
    try await services.secondDevice.snooze(
      thread: targetThread,
      dueAtMilliseconds: 1_781_372_800_000,
      profileId: Self.profileId,
      session: secondDeviceSession
    )
    let movedAnchor = Self.message(
      id: Self.thread.latestMessage.providerMessageId,
      receivedAtMilliseconds: Self.thread.latestMessage.providerInternalDateMilliseconds,
      threadId: targetThread.id.providerThreadId
    )

    let reconciled = try await services.firstDevice.reconcile(
      with: [movedAnchor, targetAnchor],
      profileId: Self.profileId,
      session: firstDeviceSession
    )

    #expect(reconciled.snoozes[Self.thread.id] == nil)
    #expect(reconciled.snoozes[targetThread.id]?.dueAtMilliseconds == 1_781_372_800_000)
    #expect(
      reconciled.snoozes[targetThread.id]?.notificationOwnerDeviceId
        == secondDeviceSession.trustedDeviceId)
  }

  @Test
  func testStaleConcurrentSnoozeAndPreferenceWritesAreRejected() async throws {
    let services = try makeServices(
      firstNowMilliseconds: 1_781_200_000_200,
      secondNowMilliseconds: 1_781_200_000_100
    )
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_286_400_000,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    await #expect(throws: ThreadSnoozeSyncError.concurrentModification) {
      try await services.secondDevice.snooze(
        thread: Self.thread,
        dueAtMilliseconds: 1_781_372_800_000,
        profileId: Self.profileId,
        session: secondDeviceSession
      )
    }

    let preferenceServices = try makeServices(
      firstNowMilliseconds: 1_781_200_000_400,
      secondNowMilliseconds: 1_781_200_000_300
    )
    try await preferenceServices.firstDevice.setReturnToAttentionEnabled(
      false,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    await #expect(throws: ThreadSnoozeSyncError.concurrentModification) {
      try await preferenceServices.secondDevice.setReturnToAttentionEnabled(
        true,
        profileId: Self.profileId,
        session: secondDeviceSession
      )
    }
  }

  @Test
  func testStaleSameDueSnoozeWriteIsRejected() async throws {
    let services = try makeServices(
      firstNowMilliseconds: 1_781_200_000_200,
      secondNowMilliseconds: 1_781_200_000_100
    )
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_286_400_000,
      profileId: Self.profileId,
      session: firstDeviceSession
    )

    await #expect(throws: ThreadSnoozeSyncError.concurrentModification) {
      try await services.secondDevice.snooze(
        thread: Self.thread,
        dueAtMilliseconds: 1_781_286_400_000,
        profileId: Self.profileId,
        session: secondDeviceSession
      )
    }
  }

  @Test
  func testLocalDueTimeResolvesDSTGapAndRepeatedHourExplicitly() throws {
    let timeZone = try #require(TimeZone(identifier: "Europe/Prague"))
    let gap = try ThreadSnoozeDueDateResolver.resolve(
      localComponents: DateComponents(
        year: 2026,
        month: 3,
        day: 29,
        hour: 2,
        minute: 30
      ),
      timeZone: timeZone,
      repeatedTimePolicy: .first
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let gapComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: gap)
    #expect(gapComponents == DateComponents(year: 2026, month: 3, day: 29, hour: 3, minute: 0))

    let repeatedComponents = DateComponents(
      year: 2026,
      month: 10,
      day: 25,
      hour: 2,
      minute: 30
    )
    let first = try ThreadSnoozeDueDateResolver.resolve(
      localComponents: repeatedComponents,
      timeZone: timeZone,
      repeatedTimePolicy: .first
    )
    let last = try ThreadSnoozeDueDateResolver.resolve(
      localComponents: repeatedComponents,
      timeZone: timeZone,
      repeatedTimePolicy: .last
    )
    #expect(last.timeIntervalSince(first) == 3_600)
  }

  @Test
  func testLaterTodayFallsBackToTomorrowMorningAcrossMidnight() throws {
    let timeZone = try #require(TimeZone(identifier: "Europe/Prague"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let lateEvening = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 23))
    )

    let dueDate = try ThreadSnoozePreset.laterToday.dueDate(
      after: lateEvening,
      calendar: calendar
    )

    #expect(
      calendar.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        == DateComponents(year: 2026, month: 8, day: 14, hour: 9, minute: 0)
    )
  }

  @Test
  func testReturnToAttentionPreferenceDefaultsOnAndSynchronizesPerProfile() async throws {
    let services = try makeServices()
    #expect(
      try await services.firstDevice.loadPreferences(
        profileId: Self.profileId,
        session: firstDeviceSession
      ).returnToAttentionEnabled)

    try await services.firstDevice.setReturnToAttentionEnabled(
      false,
      profileId: Self.profileId,
      session: firstDeviceSession
    )

    #expect(
      try await !services.secondDevice.loadPreferences(
        profileId: Self.profileId,
        session: secondDeviceSession
      ).returnToAttentionEnabled)
    #expect(
      try await services.secondDevice.loadPreferences(
        profileId: MailProfileId(rawValue: "profile-002"),
        session: secondDeviceSession
      ).returnToAttentionEnabled)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testInterruptionPolicyHonorsOwnerQuietLockPermissionAndPreviewPolicy() throws {
    let snooze = ThreadSnooze(
      anchorMessageId: Self.thread.latestMessage.id,
      anchorReceivedAtMilliseconds: Self.thread.latestMessage.providerInternalDateMilliseconds,
      dueAtMilliseconds: 1_781_286_400_000,
      notificationOwnerDeviceId: firstDeviceSession.trustedDeviceId,
      profileId: Self.profileId,
      threadId: Self.thread.id
    )
    let allowed = ThreadSnoozeInterruptionPolicy(
      allowsLockScreenContent: true,
      isOSAuthorized: true,
      isProfileLocked: false,
      isQuiet: false,
      returnToAttentionEnabled: true,
      trustedDeviceId: firstDeviceSession.trustedDeviceId
    )
    #expect(
      allowed.decision(for: snooze, subject: "Private subject") == .revealing("Private subject"))
    #expect(
      ThreadSnoozeInterruptionPolicy(
        allowsLockScreenContent: false,
        isOSAuthorized: true,
        isProfileLocked: false,
        isQuiet: false,
        returnToAttentionEnabled: true,
        trustedDeviceId: firstDeviceSession.trustedDeviceId
      ).decision(for: snooze, subject: "Private subject") == .generic)

    for blocked in [
      ThreadSnoozeInterruptionPolicy(
        allowsLockScreenContent: true,
        isOSAuthorized: true,
        isProfileLocked: false,
        isQuiet: true,
        returnToAttentionEnabled: true,
        trustedDeviceId: firstDeviceSession.trustedDeviceId
      ),
      ThreadSnoozeInterruptionPolicy(
        allowsLockScreenContent: true,
        isOSAuthorized: true,
        isProfileLocked: true,
        isQuiet: false,
        returnToAttentionEnabled: true,
        trustedDeviceId: firstDeviceSession.trustedDeviceId
      ),
      ThreadSnoozeInterruptionPolicy(
        allowsLockScreenContent: true,
        isOSAuthorized: false,
        isProfileLocked: false,
        isQuiet: false,
        returnToAttentionEnabled: true,
        trustedDeviceId: firstDeviceSession.trustedDeviceId
      ),
      ThreadSnoozeInterruptionPolicy(
        allowsLockScreenContent: true,
        isOSAuthorized: true,
        isProfileLocked: false,
        isQuiet: false,
        returnToAttentionEnabled: false,
        trustedDeviceId: firstDeviceSession.trustedDeviceId
      ),
      ThreadSnoozeInterruptionPolicy(
        allowsLockScreenContent: true,
        isOSAuthorized: true,
        isProfileLocked: false,
        isQuiet: false,
        returnToAttentionEnabled: true,
        trustedDeviceId: secondDeviceSession.trustedDeviceId
      ),
    ] {
      #expect(blocked.decision(for: snooze, subject: "Private subject") == .suppress)
    }
  }

  @Test
  func testSnoozedThreadLeavesInboxButRemainsInSnoozedAndAllMail() {
    let states = Self.thread.latestMessage.providerStateIds
    #expect(
      !MailboxMessageCollection.role(.inbox).contains(
        providerStateIds: states,
        isSnoozed: true
      ))
    #expect(
      MailboxMessageCollection.snoozed.contains(
        providerStateIds: states,
        isSnoozed: true
      ))
    #expect(
      MailboxMessageCollection.allMail.contains(
        providerStateIds: states,
        isSnoozed: true
      ))
  }

  @Test
  func testSnoozedMailboxCountGroupsMessagesByThread() {
    let secondMessage = Self.message(
      id: "message-002",
      receivedAtMilliseconds: 1_781_199_500_000
    )
    let snapshot = MailboxNavigationSnapshot(
      messagesByConnection: [Self.connectionId: Self.thread.messages + [secondMessage]],
      pinnedThreadIds: [],
      snoozedThreadIds: [Self.thread.id],
      outboxStates: []
    )

    #expect(snapshot.count(for: .snoozed) == MailboxItemCount(itemCount: 1, unreadCount: 1))
  }

  @Test
  @MainActor
  func testViewModelSwitchesSnoozeProjectionWithActiveProfile() async throws {
    let services = try makeServices()
    let scheduler = ManualThreadSnoozeScheduler(nowMilliseconds: 1_781_200_000_010)
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_200_000_500,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let viewModel = ThreadSnoozeViewModel(
      notificationAuthorization: DeniedNotificationAuthorizationState(),
      scheduler: scheduler.scheduler,
      service: services.firstDevice,
      session: firstDeviceSession,
      profileId: Self.profileId
    )

    await viewModel.load()
    #expect(viewModel.snoozedThreadIds == [Self.thread.id])

    viewModel.updateProfile(MailProfileId(rawValue: "profile-002"))
    await viewModel.load()
    #expect(viewModel.snoozedThreadIds.isEmpty)
  }

  @Test
  @MainActor
  func testOfflineRestartLoadsSnoozeAndRescheduledTimerDoesNotResurfaceEarly() async throws {
    let services = try makeServices()
    let scheduler = ManualThreadSnoozeScheduler(nowMilliseconds: 1_781_200_000_010)
    let attentionDelivery = RecordingThreadSnoozeAttentionDelivery()
    let firstViewModel = ThreadSnoozeViewModel(
      attentionDelivery: attentionDelivery,
      notificationAuthorization: DeniedNotificationAuthorizationState(),
      scheduler: scheduler.scheduler,
      service: services.firstDevice,
      session: firstDeviceSession
    )
    try await firstViewModel.snooze(
      Self.thread,
      until: Date(timeIntervalSince1970: 1_781_200_000.1)
    )
    try await firstViewModel.snooze(
      Self.thread,
      until: Date(timeIntervalSince1970: 1_781_200_000.5)
    )

    let restartedViewModel = ThreadSnoozeViewModel(
      attentionDelivery: attentionDelivery,
      notificationAuthorization: DeniedNotificationAuthorizationState(),
      scheduler: scheduler.scheduler,
      service: services.secondDevice,
      session: secondDeviceSession
    )
    await restartedViewModel.load()
    #expect(restartedViewModel.snoozedThreadIds == [Self.thread.id])

    await scheduler.waitUntilSleeping()
    #expect(firstViewModel.snoozedThreadIds == [Self.thread.id])
    await scheduler.release()
    for _ in 0..<20 where !firstViewModel.snoozedThreadIds.isEmpty {
      await Task.yield()
    }
    #expect(firstViewModel.snoozedThreadIds.isEmpty)
  }

  @Test
  @MainActor
  func testRepeatedLoadKeepsWakeTaskAndDeliversAttentionOnce() async throws {
    let services = try makeServices()
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_200_000_500,
      profileId: .defaultProfile(productAccountId: firstDeviceSession.productAccountId),
      session: firstDeviceSession
    )
    let scheduler = ManualThreadSnoozeScheduler(nowMilliseconds: 1_781_200_000_010)
    let delivery = RecordingThreadSnoozeAttentionDelivery()
    let viewModel = ThreadSnoozeViewModel(
      attentionDelivery: delivery,
      notificationAuthorization: AuthorizedNotificationState(),
      notificationPreferenceStore: DefaultNotificationPreferenceStore(),
      profileLoader: InactiveNotificationProfilePolicyLoader(),
      scheduler: scheduler.scheduler,
      service: services.firstDevice,
      session: firstDeviceSession
    )

    await viewModel.load()
    await scheduler.waitUntilSleeping()
    await viewModel.load()
    #expect(scheduler.sleepInvocationCount == 1)

    await scheduler.release()
    await delivery.waitUntilDelivered()
    #expect(await delivery.deliveryCount == 1)
    #expect(viewModel.snoozedThreadIds.isEmpty)
  }

  @Test
  @MainActor
  func testWakeReloadSuppressesAttentionAfterRemoteCancellation() async throws {
    let services = try makeServices()
    let profileId = MailProfileId.defaultProfile(
      productAccountId: firstDeviceSession.productAccountId
    )
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_200_000_500,
      profileId: profileId,
      session: firstDeviceSession
    )
    let scheduler = ManualThreadSnoozeScheduler(nowMilliseconds: 1_781_200_000_010)
    let delivery = RecordingThreadSnoozeAttentionDelivery()
    let viewModel = ThreadSnoozeViewModel(
      attentionDelivery: delivery,
      notificationAuthorization: AuthorizedNotificationState(),
      notificationPreferenceStore: DefaultNotificationPreferenceStore(),
      profileLoader: InactiveNotificationProfilePolicyLoader(),
      scheduler: scheduler.scheduler,
      service: services.firstDevice,
      session: firstDeviceSession
    )
    await viewModel.load()
    await scheduler.waitUntilSleeping()

    try await services.secondDevice.cancel(
      threadId: Self.thread.id,
      profileId: profileId,
      session: secondDeviceSession
    )
    await scheduler.release()
    for _ in 0..<20 where !viewModel.snoozedThreadIds.isEmpty {
      await Task.yield()
    }

    #expect(await delivery.deliveryCount == 0)
    #expect(viewModel.snoozedThreadIds.isEmpty)
  }

  @Test
  @MainActor
  func testStaleWakePreservesRemoteReschedule() async throws {
    let services = try makeServices()
    let profileId = MailProfileId.defaultProfile(
      productAccountId: firstDeviceSession.productAccountId
    )
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_200_000_500,
      profileId: profileId,
      session: firstDeviceSession
    )
    let scheduler = ManualThreadSnoozeScheduler(nowMilliseconds: 1_781_200_000_010)
    let viewModel = ThreadSnoozeViewModel(
      notificationAuthorization: DeniedNotificationAuthorizationState(),
      scheduler: scheduler.scheduler,
      service: services.firstDevice,
      session: firstDeviceSession
    )
    await viewModel.load()
    await scheduler.waitUntilSleeping()

    try await services.secondDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_200_001_500,
      profileId: profileId,
      session: secondDeviceSession
    )
    await scheduler.releaseFirstSleep()
    await scheduler.waitUntilRescheduledSleepStarts()
    for _ in 0..<20 {
      await Task.yield()
    }

    #expect(viewModel.snoozedThreadIds == [Self.thread.id])
    await scheduler.release()
  }

  @Test
  @MainActor
  func testWakeReloadSuppressesAttentionAfterRemotePreferenceChange() async throws {
    let services = try makeServices()
    let profileId = MailProfileId.defaultProfile(
      productAccountId: firstDeviceSession.productAccountId
    )
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: 1_781_200_000_500,
      profileId: profileId,
      session: firstDeviceSession
    )
    let scheduler = ManualThreadSnoozeScheduler(nowMilliseconds: 1_781_200_000_010)
    let delivery = RecordingThreadSnoozeAttentionDelivery()
    let viewModel = ThreadSnoozeViewModel(
      attentionDelivery: delivery,
      notificationAuthorization: AuthorizedNotificationState(),
      notificationPreferenceStore: DefaultNotificationPreferenceStore(),
      profileLoader: InactiveNotificationProfilePolicyLoader(),
      scheduler: scheduler.scheduler,
      service: services.firstDevice,
      session: firstDeviceSession
    )
    await viewModel.load()
    await scheduler.waitUntilSleeping()

    try await services.secondDevice.setReturnToAttentionEnabled(
      false,
      profileId: profileId,
      session: secondDeviceSession
    )
    await scheduler.release()
    for _ in 0..<20 where !viewModel.snoozedThreadIds.isEmpty {
      await Task.yield()
    }

    #expect(await delivery.deliveryCount == 0)
    #expect(viewModel.snoozedThreadIds.isEmpty)
  }

  @Test
  @MainActor
  func testOwnershipOnlyRescheduleReplacesWakeTask() async throws {
    let dueAtMilliseconds: Int64 = 1_781_200_000_500
    let services = try makeServices()
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: dueAtMilliseconds,
      profileId: .defaultProfile(productAccountId: firstDeviceSession.productAccountId),
      session: firstDeviceSession
    )
    let scheduler = ManualThreadSnoozeScheduler(nowMilliseconds: 1_781_200_000_010)
    let delivery = RecordingThreadSnoozeAttentionDelivery()
    let viewModel = ThreadSnoozeViewModel(
      attentionDelivery: delivery,
      notificationAuthorization: AuthorizedNotificationState(),
      notificationPreferenceStore: DefaultNotificationPreferenceStore(),
      profileLoader: InactiveNotificationProfilePolicyLoader(),
      scheduler: scheduler.scheduler,
      service: services.firstDevice,
      session: firstDeviceSession
    )
    await viewModel.load()
    await scheduler.waitUntilSleeping()

    try await services.secondDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: dueAtMilliseconds,
      profileId: .defaultProfile(productAccountId: secondDeviceSession.productAccountId),
      session: secondDeviceSession
    )
    await viewModel.load()
    await scheduler.waitUntilRescheduledSleepStarts()
    #expect(scheduler.sleepInvocationCount == 2)

    await scheduler.release()
    await delivery.waitUntilDelivered()
    #expect(await delivery.deliveryCount == 0)
    #expect(viewModel.snoozedThreadIds.isEmpty)
  }

  @Test
  @MainActor
  func testSessionRevisionReschedulesUnchangedWakeTask() async throws {
    let dueAtMilliseconds: Int64 = 1_781_200_000_500
    let services = try makeServices()
    try await services.firstDevice.snooze(
      thread: Self.thread,
      dueAtMilliseconds: dueAtMilliseconds,
      profileId: Self.profileId,
      session: firstDeviceSession
    )
    let scheduler = ManualThreadSnoozeScheduler(nowMilliseconds: 1_781_200_000_010)
    let viewModel = ThreadSnoozeViewModel(
      notificationAuthorization: DeniedNotificationAuthorizationState(),
      scheduler: scheduler.scheduler,
      service: services.firstDevice,
      session: firstDeviceSession,
      profileId: Self.profileId
    )
    await viewModel.load()
    await scheduler.waitUntilSleeping()

    viewModel.updateSession(firstDeviceSession)
    await viewModel.load()
    await scheduler.waitUntilRescheduledSleepStarts()

    #expect(scheduler.sleepInvocationCount == 2)
    await scheduler.release()
  }

  @Test
  @MainActor
  func testWakeLoadFailureStillExpiresLocalSnooze() async throws {
    let dueAtMilliseconds: Int64 = 1_781_200_000_500
    let service = WakeLoadFailureService(
      snooze: ThreadSnooze(
        anchorMessageId: Self.thread.latestMessage.id,
        anchorReceivedAtMilliseconds: Self.thread.latestMessage.providerInternalDateMilliseconds,
        dueAtMilliseconds: dueAtMilliseconds,
        notificationOwnerDeviceId: firstDeviceSession.trustedDeviceId,
        profileId: Self.profileId,
        threadId: Self.thread.id
      )
    )
    let scheduler = ManualThreadSnoozeScheduler(nowMilliseconds: 1_781_200_000_010)
    let delivery = RecordingThreadSnoozeAttentionDelivery()
    let viewModel = ThreadSnoozeViewModel(
      attentionDelivery: delivery,
      notificationAuthorization: AuthorizedNotificationState(),
      notificationPreferenceStore: DefaultNotificationPreferenceStore(),
      profileLoader: InactiveNotificationProfilePolicyLoader(),
      scheduler: scheduler.scheduler,
      service: service,
      session: firstDeviceSession,
      profileId: Self.profileId
    )
    await viewModel.load()
    await scheduler.waitUntilSleeping()

    await scheduler.release()
    for _ in 0..<20 where !viewModel.snoozedThreadIds.isEmpty {
      await Task.yield()
    }

    #expect(await delivery.deliveryCount == 0)
    #expect(viewModel.snoozedThreadIds.isEmpty)
  }

  @Test
  @MainActor
  func testOlderLoadCannotOverwriteNewerSnoozeMutation() async throws {
    let gate = TestRendezvous()
    let service = StaleLoadThreadSnoozeService(gate: gate)
    let scheduler = ManualThreadSnoozeScheduler(nowMilliseconds: 1_781_200_000_010)
    let viewModel = ThreadSnoozeViewModel(
      notificationAuthorization: DeniedNotificationAuthorizationState(),
      scheduler: scheduler.scheduler,
      service: service,
      session: firstDeviceSession
    )

    let staleLoad = Task { await viewModel.load() }
    await gate.waitUntilHeld()
    try await viewModel.snooze(
      Self.thread,
      until: Date(timeIntervalSince1970: 1_781_200_001)
    )
    await gate.release()
    await staleLoad.value

    #expect(viewModel.snoozedThreadIds == [Self.thread.id])
    await scheduler.release()
  }

  private func makeServices(
    firstNowMilliseconds: Int64 = 1_781_200_000_001,
    secondNowMilliseconds: Int64 = 1_781_200_000_002,
    transport: (any ProductSyncRecordTransport)? = nil
  ) throws -> (
    firstDevice: ThreadSnoozeSyncService,
    secondDevice: ThreadSnoozeSyncService
  ) {
    let keyMaterial = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 7, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 8, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let firstStore = InMemoryProductSyncKeyMaterialStore()
    let secondStore = InMemoryProductSyncKeyMaterialStore()
    try firstStore.save(keyMaterial, productAccountId: firstDeviceSession.productAccountId)
    try secondStore.save(keyMaterial, productAccountId: secondDeviceSession.productAccountId)
    let transport = transport ?? InMemoryProductSyncRecordTransport()
    let firstCache = InMemoryProductSyncCiphertextCache()
    let secondCache = InMemoryProductSyncCiphertextCache()
    return (
      ThreadSnoozeSyncService(
        nowMilliseconds: { firstNowMilliseconds },
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: firstStore,
          transport: transport
        ),
        ciphertextCache: firstCache
      ),
      ThreadSnoozeSyncService(
        nowMilliseconds: { secondNowMilliseconds },
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: secondStore,
          transport: transport
        ),
        ciphertextCache: secondCache
      )
    )
  }

  private static let profileId = MailProfileId(rawValue: "profile-001")
  private static let connectionId = MailboxConnectionId(
    providerMailboxIdentity: StableProviderMailboxIdentity(
      providerId: .gmail,
      value: "gmail-user-001"
    )
  )
  private static let thread = MailboxThread.group([
    message(id: "message-001", receivedAtMilliseconds: 1_781_199_000_000)
  ])[0]

  private static func message(
    id: String,
    receivedAtMilliseconds: Int64,
    threadId: String = "thread-001"
  ) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: nil,
      connectionId: connectionId,
      from: "sender@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: receivedAtMilliseconds,
      providerMessageId: id,
      providerStateIds: ["INBOX", "UNREAD"],
      providerThreadId: threadId,
      recipientHeaders: nil,
      replyTo: nil,
      rfcMessageId: nil,
      snippet: "Preview",
      subject: "Subject"
    )
  }
}

private actor SnoozeReconcileRaceTransport: ProductSyncRecordTransport {
  private let backing = InMemoryProductSyncRecordTransport()
  private let listGate = TestRendezvous()
  private var shouldHoldNextList = false

  func holdNextList() {
    shouldHoldNextList = true
  }

  func waitUntilListIsHeld() async {
    await listGate.waitUntilHeld()
  }

  func releaseList() async {
    await listGate.release()
  }

  func listEncryptedProductSyncPayloads(
    session: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor: String?,
    limit: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    let page = try await backing.listEncryptedProductSyncPayloads(
      session: session,
      payloadIdentifierPrefix: payloadIdentifierPrefix,
      cursor: cursor,
      limit: limit
    )
    if shouldHoldNextList {
      shouldHoldNextList = false
      await listGate.hold()
    }
    return page
  }

  func getEncryptedProductSyncPayloads(
    session: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    try await backing.getEncryptedProductSyncPayloads(
      session: session,
      payloadIdentifiers: payloadIdentifiers
    )
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    try await backing.putEncryptedProductSyncPayloadIfUnchanged(
      session: session,
      payloadIdentifier: payloadIdentifier,
      encryptedPayload: encryptedPayload,
      expectedUpdatedAt: expectedUpdatedAt
    )
  }
}

private struct FailingThreadSnoozeProductSyncRecordTransport: ProductSyncRecordTransport {
  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix _: String,
    cursor _: String?,
    limit _: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    throw URLError(.notConnectedToInternet)
  }

  func getEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifiers _: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    throw URLError(.notConnectedToInternet)
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier _: String,
    encryptedPayload _: ProductSyncEncryptedPayload,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    throw URLError(.notConnectedToInternet)
  }
}

private final class ManualThreadSnoozeScheduler: @unchecked Sendable {
  private let firstSleepStarted = expectation(description: "first Snooze sleep started")
  private let firstSleepGate = TestRendezvous()
  private let lock = NSLock()
  private let nowMilliseconds: Int64
  private let rescheduledSleepGate = TestRendezvous()
  private let rescheduledSleepStarted = expectation(description: "rescheduled Snooze sleep started")
  private var sleepInvocations = 0

  init(nowMilliseconds: Int64) {
    self.nowMilliseconds = nowMilliseconds
  }

  var scheduler: ThreadSnoozeScheduler {
    ThreadSnoozeScheduler(
      nowMilliseconds: { [nowMilliseconds] in nowMilliseconds },
      sleepUntilMilliseconds: { [weak self] _ in
        guard let self else { return }
        let invocation = self.lock.withLock {
          self.sleepInvocations += 1
          return self.sleepInvocations
        }
        if invocation == 1 {
          self.firstSleepStarted.fulfill()
        } else if invocation == 2 {
          self.rescheduledSleepStarted.fulfill()
        }
        if invocation == 1 {
          await self.firstSleepGate.hold()
        } else {
          await self.rescheduledSleepGate.hold()
        }
      }
    )
  }

  var sleepInvocationCount: Int {
    lock.withLock { sleepInvocations }
  }

  func waitUntilSleeping() async {
    await fulfillment(of: [firstSleepStarted])
  }

  func waitUntilRescheduledSleepStarts() async {
    await fulfillment(of: [rescheduledSleepStarted])
  }

  func releaseFirstSleep() async {
    await firstSleepGate.release()
  }

  func release() async {
    await firstSleepGate.release()
    await rescheduledSleepGate.release()
  }
}

private actor RecordingThreadSnoozeAttentionDelivery: ThreadSnoozeAttentionDelivering {
  private(set) var deliveryCount = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func deliverThreadSnoozeAttention(
    decision: ThreadSnoozeInterruptionDecision,
    snooze _: ThreadSnooze,
    productAccountId _: String
  ) {
    if decision != .suppress {
      deliveryCount += 1
    }
    let pendingWaiters = waiters
    waiters.removeAll()
    for waiter in pendingWaiters {
      waiter.resume()
    }
  }

  func waitUntilDelivered() async {
    guard deliveryCount == 0 else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

private struct InactiveNotificationProfilePolicyLoader: NotificationProfilePolicyLoading {
  func loadNotificationProfileSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    let profile = MailProfileDefinition.defaultProfile(
      productAccountId: session.productAccountId
    )
    return MailProfileSyncSnapshot(
      assignments: [:],
      conflicts: [],
      defaultProfileId: profile.id,
      profiles: [profile],
      updatedAt: nil
    )
  }
}

private struct DefaultNotificationPreferenceStore: NotificationDevicePreferencePersisting {
  func clear(productAccountId _: String) {}

  func load(productAccountId _: String) -> NotificationDevicePreferences {
    .default
  }

  func save(_: NotificationDevicePreferences, productAccountId _: String) {}
}

private struct AuthorizedNotificationState: NotificationAuthorizationStateChecking {
  func notificationAuthorizationState() async -> NotificationAuthorizationState {
    .authorized
  }
}

private struct DeniedNotificationAuthorizationState: NotificationAuthorizationStateChecking {
  func notificationAuthorizationState() async -> NotificationAuthorizationState {
    .denied
  }
}

private actor StaleLoadThreadSnoozeService: ThreadSnoozeSyncing {
  private let gate: TestRendezvous
  private var loadCount = 0
  private var snapshot = ThreadSnoozeSnapshot(snoozes: [:])

  init(gate: TestRendezvous) {
    self.gate = gate
  }

  func load(
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async -> ThreadSnoozeSnapshot {
    loadCount += 1
    if loadCount == 1 {
      await gate.hold()
      return ThreadSnoozeSnapshot(snoozes: [:])
    }
    return snapshot
  }

  func snooze(
    thread: MailboxThread,
    dueAtMilliseconds: Int64,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) {
    let snooze = ThreadSnooze(
      anchorMessageId: thread.latestMessage.id,
      anchorReceivedAtMilliseconds: thread.latestMessage.providerInternalDateMilliseconds,
      dueAtMilliseconds: dueAtMilliseconds,
      notificationOwnerDeviceId: session.trustedDeviceId,
      profileId: profileId,
      threadId: thread.id
    )
    snapshot = ThreadSnoozeSnapshot(snoozes: [thread.id: snooze])
  }

  func cancel(
    threadId: StableThreadIdentity,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) {
    snapshot = ThreadSnoozeSnapshot(snoozes: snapshot.snoozes.filter { $0.key != threadId })
  }

  func reconcile(
    with _: [MailboxMessageMetadata],
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) -> ThreadSnoozeSnapshot {
    snapshot
  }

  func loadPreferences(
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) -> ThreadSnoozePreferences {
    .defaults
  }

  func setReturnToAttentionEnabled(
    _: Bool,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) {}
}

private actor WakeLoadFailureService: ThreadSnoozeSyncing {
  private enum Failure: Error {
    case load
  }

  private var loadCount = 0
  private let snapshot: ThreadSnoozeSnapshot

  init(snooze: ThreadSnooze) {
    snapshot = ThreadSnoozeSnapshot(snoozes: [snooze.threadId: snooze])
  }

  func load(
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) throws -> ThreadSnoozeSnapshot {
    loadCount += 1
    guard loadCount == 1 else { throw Failure.load }
    return snapshot
  }

  func snooze(
    thread _: MailboxThread,
    dueAtMilliseconds _: Int64,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) {}

  func cancel(
    threadId _: StableThreadIdentity,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) {}

  func reconcile(
    with _: [MailboxMessageMetadata],
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) -> ThreadSnoozeSnapshot {
    snapshot
  }

  func loadPreferences(
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) -> ThreadSnoozePreferences {
    .defaults
  }

  func setReturnToAttentionEnabled(
    _: Bool,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) {}
}
