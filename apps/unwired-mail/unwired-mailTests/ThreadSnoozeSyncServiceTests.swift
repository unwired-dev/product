import Foundation
import Testing

@testable import unwired_mail

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
  @MainActor
  func testOfflineRestartLoadsSnoozeAndRescheduledTimerDoesNotResurfaceEarly() async throws {
    let services = try makeServices()
    let firstViewModel = ThreadSnoozeViewModel(
      service: services.firstDevice,
      session: firstDeviceSession
    )
    try await firstViewModel.snooze(Self.thread, until: .now.addingTimeInterval(0.1))
    try await firstViewModel.snooze(Self.thread, until: .now.addingTimeInterval(0.5))

    let restartedViewModel = ThreadSnoozeViewModel(
      service: services.secondDevice,
      session: secondDeviceSession
    )
    await restartedViewModel.load()
    #expect(restartedViewModel.snoozedThreadIds == [Self.thread.id])

    try await Task.sleep(for: .milliseconds(200))
    #expect(firstViewModel.snoozedThreadIds == [Self.thread.id])
    try await Task.sleep(for: .milliseconds(400))
    #expect(firstViewModel.snoozedThreadIds.isEmpty)
  }

  private func makeServices() throws -> (
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
    let transport = InMemoryProductSyncRecordTransport()
    return (
      ThreadSnoozeSyncService(
        nowMilliseconds: { 1_781_200_000_001 },
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: firstStore,
          transport: transport
        )
      ),
      ThreadSnoozeSyncService(
        nowMilliseconds: { 1_781_200_000_002 },
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: secondStore,
          transport: transport
        )
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
    receivedAtMilliseconds: Int64
  ) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: nil,
      connectionId: connectionId,
      from: "sender@example.com",
      isHistorical: false,
      providerInternalDateMilliseconds: receivedAtMilliseconds,
      providerMessageId: id,
      providerStateIds: ["INBOX", "UNREAD"],
      providerThreadId: "thread-001",
      recipientHeaders: nil,
      replyTo: nil,
      rfcMessageId: nil,
      snippet: "Preview",
      subject: "Subject"
    )
  }
}
