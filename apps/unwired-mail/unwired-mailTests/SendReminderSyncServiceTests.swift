import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length function_body_length large_tuple type_body_length

@Suite
struct SendReminderSyncServiceTests {
  private let firstSession = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user",
    identityToken: "token-a",
    productAccountId: "account-a",
    trustedDeviceId: "device-a"
  )
  private let secondSession = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user",
    identityToken: "token-b",
    productAccountId: "account-a",
    trustedDeviceId: "device-b"
  )
  private let profileId = MailProfileId(rawValue: "profile-a")

  @Test(.bug(id: 378))
  func reminderAndDraftSynchronizeWithinOneProfileAndTransferOwnership() async throws {
    let fixture = try makeFixture()
    let firstDirectory = FileManager.default.temporaryDirectory.appending(
      path: "send-reminder-first-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let secondDirectory = FileManager.default.temporaryDirectory.appending(
      path: "send-reminder-second-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer {
      try? FileManager.default.removeItem(at: firstDirectory)
      try? FileManager.default.removeItem(at: secondDirectory)
    }
    let firstRepository = repository(
      rootDirectory: firstDirectory,
      keyStore: fixture.firstKeyStore,
      transport: fixture.transport,
      nowMilliseconds: { 2_000_000_000_001 }
    )
    let secondRepository = repository(
      rootDirectory: secondDirectory,
      keyStore: fixture.secondKeyStore,
      transport: fixture.transport,
      nowMilliseconds: { 2_000_000_000_002 }
    )
    var source = draft(updatedAtMilliseconds: 2_000_000_000_000)
    source.sendReminder = reminder(
      owner: firstSession.trustedDeviceId,
      changedAtMilliseconds: source.updatedAtMilliseconds
    )

    try await firstRepository.save(
      source,
      productAccountId: firstSession.productAccountId,
      profileId: profileId,
      session: firstSession
    )
    let secondDraft = try #require(
      try await secondRepository.drafts(
        productAccountId: secondSession.productAccountId,
        profileId: profileId,
        session: secondSession,
        claimsNotificationOwnership: true
      ).first
    )

    #expect(secondDraft.sendReminder?.notificationOwnerDeviceId == secondSession.trustedDeviceId)
    #expect(secondDraft.sendReminder?.revision == source.sendReminder?.revision)
    #expect(secondDraft.sendReminder?.isSynchronizationPending == false)

    let reconciledFirstDraft = try #require(
      try await firstRepository.drafts(
        productAccountId: firstSession.productAccountId,
        profileId: profileId,
        session: firstSession
      ).first
    )
    #expect(
      reconciledFirstDraft.sendReminder?.notificationOwnerDeviceId
        == secondSession.trustedDeviceId
    )
  }

  @Test(.bug(id: 378))
  func concurrentReschedulesConvergeByChangeClockAndDevice() async throws {
    let fixture = try makeFixture()
    let first = service(
      keyStore: fixture.firstKeyStore,
      transport: fixture.transport,
      nowMilliseconds: { 2_000_000_000_001 }
    )
    let second = service(
      keyStore: fixture.secondKeyStore,
      transport: fixture.transport,
      nowMilliseconds: { 2_000_000_000_001 }
    )
    let draftId = UUID()
    let initial = reminder(owner: firstSession.trustedDeviceId)
    _ = try await first.synchronize(
      initial,
      draftId: draftId,
      draftUpdatedAtMilliseconds: initial.changedAtMilliseconds,
      profileId: profileId,
      session: firstSession
    )
    let changedAt = Date(timeIntervalSince1970: 2_000_000_100)
    let firstReschedule = initial.rescheduled(
      to: Date(timeIntervalSince1970: 2_000_010_000),
      originalTimeZoneIdentifier: "UTC",
      changedByTrustedDeviceId: firstSession.trustedDeviceId,
      changedAt: changedAt
    )
    let secondReschedule = initial.rescheduled(
      to: Date(timeIntervalSince1970: 2_000_020_000),
      originalTimeZoneIdentifier: "Europe/Prague",
      changedByTrustedDeviceId: secondSession.trustedDeviceId,
      changedAt: changedAt
    )

    _ = try await first.synchronize(
      firstReschedule,
      draftId: draftId,
      draftUpdatedAtMilliseconds: firstReschedule.changedAtMilliseconds,
      profileId: profileId,
      session: firstSession
    )
    _ = try await second.synchronize(
      secondReschedule,
      draftId: draftId,
      draftUpdatedAtMilliseconds: secondReschedule.changedAtMilliseconds,
      profileId: profileId,
      session: secondSession
    )
    let staleRetry = try await first.synchronize(
      firstReschedule,
      draftId: draftId,
      draftUpdatedAtMilliseconds: firstReschedule.changedAtMilliseconds,
      profileId: profileId,
      session: firstSession
    )

    #expect(staleRetry == .authoritative(secondReschedule.synchronized()))
    #expect(
      try await first.load(profileId: profileId, session: firstSession)
        .remindersByDraftId[draftId]?.dueAt == secondReschedule.dueAt
    )
  }

  @Test(.bug(id: 378))
  func staleNotificationActionCannotClearANewerRevision() async throws {
    let fixture = try makeFixture()
    let first = service(
      keyStore: fixture.firstKeyStore,
      transport: fixture.transport,
      nowMilliseconds: { 2_000_000_000_001 }
    )
    let second = service(
      keyStore: fixture.secondKeyStore,
      transport: fixture.transport,
      nowMilliseconds: { 2_000_000_000_002 }
    )
    let draftId = UUID()
    let initial = reminder(owner: firstSession.trustedDeviceId)
    _ = try await first.synchronize(
      initial,
      draftId: draftId,
      draftUpdatedAtMilliseconds: initial.changedAtMilliseconds,
      profileId: profileId,
      session: firstSession
    )
    let rescheduled = initial.rescheduled(
      to: Date(timeIntervalSince1970: 2_000_020_000),
      originalTimeZoneIdentifier: "UTC",
      changedByTrustedDeviceId: secondSession.trustedDeviceId,
      changedAt: Date(timeIntervalSince1970: 2_000_000_100)
    )
    _ = try await second.synchronize(
      rescheduled,
      draftId: draftId,
      draftUpdatedAtMilliseconds: rescheduled.changedAtMilliseconds,
      profileId: profileId,
      session: secondSession
    )

    #expect(
      try await first.cancel(
        draftId: draftId,
        expectedRevision: initial.revision,
        profileId: profileId,
        session: firstSession
      ) == .authoritative(rescheduled.synchronized())
    )
    #expect(
      try await second.cancel(
        draftId: draftId,
        expectedRevision: rescheduled.revision,
        profileId: profileId,
        session: secondSession
      ) == .accepted(nil)
    )
    #expect(
      try await first.load(profileId: profileId, session: firstSession)
        .removedDraftIds == [draftId]
    )
  }

  @Test(.bug(id: 378))
  func remindersStayProfileScopedAndOlderFamiliesIgnoreThem() async throws {
    let fixture = try makeFixture()
    let syncService = service(
      keyStore: fixture.firstKeyStore,
      transport: fixture.transport,
      nowMilliseconds: { 2_000_000_000_001 }
    )
    let draftId = UUID()
    let reminder = reminder(owner: firstSession.trustedDeviceId)
    _ = try await syncService.synchronize(
      reminder,
      draftId: draftId,
      draftUpdatedAtMilliseconds: reminder.changedAtMilliseconds,
      profileId: profileId,
      session: firstSession
    )

    #expect(
      try await syncService.load(
        profileId: MailProfileId(rawValue: "profile-b"),
        session: firstSession
      ).remindersByDraftId.isEmpty
    )
    let snoozes = try await ThreadSnoozeSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: fixture.firstKeyStore,
        transport: fixture.transport
      ),
      ciphertextCache: InMemoryProductSyncCiphertextCache()
    ).load(profileId: profileId, session: firstSession)
    #expect(snoozes.snoozes.isEmpty)
  }

  @Test(.bug(id: 378))
  func offlineReminderStaysPendingUntilReconciliationSucceeds() async throws {
    let fixture = try makeFixture()
    let rootDirectory = FileManager.default.temporaryDirectory.appending(
      path: "send-reminder-offline-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let offlineRepository = repository(
      rootDirectory: rootDirectory,
      keyStore: fixture.firstKeyStore,
      transport: OfflineSendReminderTransport(),
      nowMilliseconds: { 2_000_000_000_001 }
    )
    var source = draft(updatedAtMilliseconds: 2_000_000_000_000)
    source.sendReminder = reminder(
      owner: firstSession.trustedDeviceId,
      changedAtMilliseconds: source.updatedAtMilliseconds
    )

    try await offlineRepository.save(
      source,
      productAccountId: firstSession.productAccountId,
      profileId: profileId,
      session: firstSession
    )
    let localStore = FileMailCompositionDraftStore(
      keyMaterialStore: fixture.firstKeyStore,
      rootDirectory: rootDirectory
    )
    #expect(
      try localStore.load(
        productAccountId: firstSession.productAccountId,
        profileId: profileId
      ).first?.sendReminder?.isSynchronizationPending == true
    )

    let onlineRepository = repository(
      rootDirectory: rootDirectory,
      keyStore: fixture.firstKeyStore,
      transport: fixture.transport,
      nowMilliseconds: { 2_000_000_000_002 }
    )
    let reconciled = try #require(
      try await onlineRepository.drafts(
        productAccountId: firstSession.productAccountId,
        profileId: profileId,
        session: firstSession
      ).first
    )
    #expect(reconciled.sendReminder?.isSynchronizationPending == false)
  }

  @Test(.bug(id: 378))
  func interruptionPolicyHonorsEveryPresentationGate() {
    let cases: [(SendReminderInterruptionPolicy, Bool)] = [
      (
        SendReminderInterruptionPolicy(
          isDeviceQuietAtDueTime: false,
          isProfileLocked: false,
          isProfileQuietAtDueTime: false,
          returnToAttentionEnabled: true
        ),
        true
      ),
      (
        SendReminderInterruptionPolicy(
          isDeviceQuietAtDueTime: true,
          isProfileLocked: false,
          isProfileQuietAtDueTime: false,
          returnToAttentionEnabled: true
        ),
        false
      ),
      (
        SendReminderInterruptionPolicy(
          isDeviceQuietAtDueTime: false,
          isProfileLocked: true,
          isProfileQuietAtDueTime: false,
          returnToAttentionEnabled: true
        ),
        false
      ),
      (
        SendReminderInterruptionPolicy(
          isDeviceQuietAtDueTime: false,
          isProfileLocked: false,
          isProfileQuietAtDueTime: true,
          returnToAttentionEnabled: true
        ),
        false
      ),
      (
        SendReminderInterruptionPolicy(
          isDeviceQuietAtDueTime: false,
          isProfileLocked: false,
          isProfileQuietAtDueTime: false,
          returnToAttentionEnabled: false
        ),
        false
      ),
    ]
    for (policy, expected) in cases {
      #expect(policy.allowsInterruption == expected)
    }
  }

  private func makeFixture() throws -> (
    firstKeyStore: InMemoryProductSyncKeyMaterialStore,
    secondKeyStore: InMemoryProductSyncKeyMaterialStore,
    transport: InMemoryProductSyncRecordTransport
  ) {
    let material = try ProductSyncKeyMaterial.create(
      accountKeyData: Data(repeating: 7, count: ProductSyncKeyMaterial.keyByteCount),
      recoveryKeyData: Data(repeating: 8, count: ProductSyncKeyMaterial.keyByteCount)
    )
    let firstKeyStore = InMemoryProductSyncKeyMaterialStore()
    let secondKeyStore = InMemoryProductSyncKeyMaterialStore()
    try firstKeyStore.save(material, productAccountId: firstSession.productAccountId)
    try secondKeyStore.save(material, productAccountId: secondSession.productAccountId)
    return (firstKeyStore, secondKeyStore, InMemoryProductSyncRecordTransport())
  }

  private func service(
    keyStore: InMemoryProductSyncKeyMaterialStore,
    transport: any ProductSyncRecordTransport,
    nowMilliseconds: @escaping @Sendable () -> Int64
  ) -> SendReminderSyncService {
    SendReminderSyncService(
      nowMilliseconds: nowMilliseconds,
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore,
        transport: transport
      )
    )
  }

  private func repository(
    rootDirectory: URL,
    keyStore: InMemoryProductSyncKeyMaterialStore,
    transport: any ProductSyncRecordTransport,
    nowMilliseconds: @escaping @Sendable () -> Int64
  ) -> MailCompositionDraftRepository {
    let boundary = ProductSyncRecordBoundary(
      keyMaterialStore: keyStore,
      transport: transport
    )
    return MailCompositionDraftRepository(
      store: FileMailCompositionDraftStore(
        keyMaterialStore: keyStore,
        rootDirectory: rootDirectory
      ),
      syncService: MailCompositionDraftSyncService(recordBoundary: boundary),
      reminderSyncService: SendReminderSyncService(
        nowMilliseconds: nowMilliseconds,
        recordBoundary: boundary
      )
    )
  }

  private func reminder(
    owner: String,
    changedAtMilliseconds: Int64 = 2_000_000_000_000
  ) -> SendReminder {
    SendReminder(
      dueAt: Date(timeIntervalSince1970: 2_000_010_000),
      originatingDeviceId: owner,
      originalTimeZoneIdentifier: "UTC",
      createdAt: Date(timeIntervalSince1970: 2_000_000_000),
      changedAtMilliseconds: changedAtMilliseconds,
      changedByTrustedDeviceId: owner
    )
  }

  private func draft(updatedAtMilliseconds: Int64) -> MailShellCompositionDraft {
    MailShellCompositionDraft(
      body: "Finish this Draft",
      connectionId: nil,
      recipient: "recipient@example.com",
      replyToMessage: nil,
      sourceMessage: nil,
      subject: "Pending",
      updatedAtMilliseconds: updatedAtMilliseconds
    )
  }
}

private struct OfflineSendReminderTransport: ProductSyncRecordTransport {
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
