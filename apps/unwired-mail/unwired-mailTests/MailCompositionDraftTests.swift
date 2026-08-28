import Foundation
import Testing
import UserNotifications

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
@MainActor
@Suite(.serialized)
final class MailCompositionDraftTests {
  private let connectionId = MailboxConnectionId(
    providerMailboxIdentity: StableProviderMailboxIdentity(
      providerId: .gmail,
      value: "sender@example.com"
    )
  )

  @Test
  func encryptedStoreRoundTripsDraftsWithoutExposingMessageContent() throws {
    let rootDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let keyMaterialStore = try keyedStore(productAccountId: "account")
    let store = FileMailCompositionDraftStore(
      keyMaterialStore: keyMaterialStore,
      rootDirectory: rootDirectory
    )
    let profileId = MailProfileId(rawValue: "profile-a")
    let draft = MailShellCompositionDraft(
      body: "Private body fixture",
      connectionId: connectionId,
      recipient: "Recipient <recipient@example.com>",
      replyToMessage: nil,
      sourceMessage: nil,
      subject: "Private subject fixture"
    )

    try store.save(draft, productAccountId: "account", profileId: profileId)

    #expect(
      try store.load(productAccountId: "account", profileId: profileId) == [draft]
    )
    #expect(
      try store.load(
        productAccountId: "account",
        profileId: MailProfileId(rawValue: "profile-b")
      ).isEmpty
    )
    let encryptedFile = try #require(
      FileManager.default.enumerator(at: rootDirectory, includingPropertiesForKeys: nil)?
        .allObjects.compactMap { $0 as? URL }
        .first { $0.pathExtension == "json" }
    )
    let encryptedData = try Data(contentsOf: encryptedFile)
    #expect(encryptedData.range(of: Data("Private body fixture".utf8)) == nil)
    #expect(encryptedData.range(of: Data("Private subject fixture".utf8)) == nil)
    #expect(encryptedData.range(of: Data("recipient@example.com".utf8)) == nil)
  }

  @Test
  func storeUpdatesAndRemovesOnlyTheSelectedDraft() throws {
    let rootDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let store = FileMailCompositionDraftStore(
      keyMaterialStore: try keyedStore(productAccountId: "account"),
      rootDirectory: rootDirectory
    )
    let profileId = MailProfileId(rawValue: "profile")
    var first = draft(recipient: "first@example.com")
    let second = draft(recipient: "second@example.com")

    try store.save(first, productAccountId: "account", profileId: profileId)
    try store.save(second, productAccountId: "account", profileId: profileId)
    first.document = SemanticMessageDocument(plainText: "Updated")
    try store.save(first, productAccountId: "account", profileId: profileId)
    try store.remove(first.id, productAccountId: "account", profileId: profileId)

    #expect(
      try store.load(productAccountId: "account", profileId: profileId) == [second]
    )
  }

  @Test
  func storeRecoversUnreadableFilesWhileRetainingQuarantineOutsideTheStorageLimit() throws {
    let rootDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let store = FileMailCompositionDraftStore(
      keyMaterialStore: try keyedStore(productAccountId: "account"),
      rootDirectory: rootDirectory,
      storageLimit: 1_000_000
    )
    let profileId = MailProfileId(rawValue: "profile")
    let first = draft(recipient: "first@example.com")
    let second = draft(recipient: "second@example.com")

    try store.save(first, productAccountId: "account", profileId: profileId)
    let currentFile = try #require(
      draftFiles(in: rootDirectory).first { $0.pathExtension == "json" })
    try Data(repeating: 0, count: 999_500).write(to: currentFile)
    #expect(throws: DecodingError.self) {
      try store.load(productAccountId: "account", profileId: profileId)
    }

    try store.save(second, productAccountId: "account", profileId: profileId)
    #expect(try store.load(productAccountId: "account", profileId: profileId) == [second])
    let replacementFile = try #require(
      draftFiles(in: rootDirectory).first { $0.pathExtension == "json" })
    try Data(repeating: 0, count: 999_500).write(to: replacementFile)
    try store.remove(second.id, productAccountId: "account", profileId: profileId)

    #expect(try store.load(productAccountId: "account", profileId: profileId).isEmpty)
    #expect(
      draftFiles(in: rootDirectory)
        .filter { $0.lastPathComponent.contains(".unreadable-") }.count == 2
    )
  }

  @Test
  func storeRejectsDraftsAboveTheConfiguredStorageLimit() throws {
    let rootDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let store = FileMailCompositionDraftStore(
      keyMaterialStore: try keyedStore(productAccountId: "account"),
      rootDirectory: rootDirectory,
      storageLimit: 1
    )

    #expect(throws: MailCompositionDraftStoreError.storageLimitExceeded) {
      try store.save(
        draft(recipient: "recipient@example.com"),
        productAccountId: "account",
        profileId: MailProfileId(rawValue: "profile")
      )
    }
  }

  @Test(.bug(id: 377))
  func sendReminderUsesTheExistingEncryptedDraftQuotaWithoutDuplicatingAssets() throws {
    let rootDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let keyMaterialStore = try keyedStore(productAccountId: "account")
    let profileId = MailProfileId(rawValue: "profile")
    let initialStore = FileMailCompositionDraftStore(
      keyMaterialStore: keyMaterialStore,
      rootDirectory: rootDirectory
    )
    var source = draft(recipient: "recipient@example.com")
    source.assets = [
      MailDraftAsset(
        data: Data(repeating: 0xA5, count: 64),
        filename: "private.bin",
        mediaType: "application/octet-stream"
      )
    ]
    try initialStore.save(source, productAccountId: "account", profileId: profileId)
    let originalSize =
      try #require(
        draftFiles(in: rootDirectory).first { $0.pathExtension == "json" }
      ).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

    source.sendReminder = SendReminder(
      dueAt: Date(timeIntervalSince1970: 2_000_000_000),
      originatingDeviceId: "device-a",
      originalTimeZoneIdentifier: "Europe/Prague"
    )
    let constrainedStore = FileMailCompositionDraftStore(
      keyMaterialStore: keyMaterialStore,
      rootDirectory: rootDirectory,
      storageLimit: originalSize
    )

    #expect(throws: MailCompositionDraftStoreError.storageLimitExceeded) {
      try constrainedStore.save(source, productAccountId: "account", profileId: profileId)
    }
    let retained = try #require(
      constrainedStore.load(productAccountId: "account", profileId: profileId).first
    )
    #expect(retained.sendReminder == nil)
    #expect(retained.assets == source.assets)

    let unconstrainedStore = FileMailCompositionDraftStore(
      keyMaterialStore: keyMaterialStore,
      rootDirectory: rootDirectory
    )
    try unconstrainedStore.save(source, productAccountId: "account", profileId: profileId)
    let restored = try #require(
      unconstrainedStore.load(productAccountId: "account", profileId: profileId).first
    )
    #expect(restored.sendReminder == source.sendReminder)
    #expect(restored.assets == source.assets)
  }

  @Test(.bug(id: 377))
  func sendReminderPresetsAndRangeUseTheSelectedCalendar() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Prague"))
    let now = try #require(
      calendar.date(
        from: DateComponents(year: 2026, month: 8, day: 21, hour: 18, minute: 10)
      )
    )

    let presets = SendReminderSchedule.presets(now: now, calendar: calendar)
    #expect(presets.map(\.kind) == [.laterToday, .tomorrowMorning, .nextMondayMorning])
    #expect(
      calendar.dateComponents([.hour, .minute], from: presets[0].dueAt)
        == DateComponents(hour: 21, minute: 30)
    )
    #expect(
      calendar.dateComponents([.day, .hour, .minute], from: presets[1].dueAt)
        == DateComponents(day: 22, hour: 8, minute: 0)
    )
    #expect(
      calendar.dateComponents([.weekday, .hour, .minute], from: presets[2].dueAt)
        == DateComponents(hour: 8, minute: 0, weekday: 2)
    )

    #expect(
      SendReminderSchedule.isValid(
        dueAt: now.addingTimeInterval(60),
        now: now,
        calendar: calendar
      )
    )
    #expect(
      SendReminderSchedule.isValid(
        dueAt: try #require(calendar.date(byAdding: .year, value: 1, to: now)),
        now: now,
        calendar: calendar
      )
    )
    #expect(
      !SendReminderSchedule.isValid(
        dueAt: now.addingTimeInterval(59),
        now: now,
        calendar: calendar
      )
    )
  }

  @Test(.bug(id: 377))
  func laterTodayPresetIsHiddenAtTheEveningCutoff() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Prague"))
    let afterCutoff = try #require(
      calendar.date(
        from: DateComponents(year: 2026, month: 8, day: 21, hour: 21, minute: 0)
      )
    )

    #expect(
      SendReminderSchedule.presets(now: afterCutoff, calendar: calendar).map(\.kind)
        == [.tomorrowMorning, .nextMondayMorning]
    )
  }

  @Test(.bug(id: 377))
  func localReminderTimeRejectsDSTGapAndDistinguishesRepeatedHour() throws {
    let timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let gap = DateComponents(year: 2026, month: 3, day: 8, hour: 2, minute: 30)

    #expect(throws: SendReminderLocalTimeError.nonexistent) {
      try SendReminderSchedule.resolve(
        localComponents: gap,
        timeZone: timeZone,
        repeatedTimeChoice: .first
      )
    }

    let repeated = DateComponents(year: 2026, month: 11, day: 1, hour: 1, minute: 30)
    let options = try SendReminderSchedule.repeatedTimeOptions(
      localComponents: repeated,
      timeZone: timeZone
    )
    #expect(options.count == 2)
    #expect(options[1].date.timeIntervalSince(options[0].date) == 3_600)
    #expect(options[0].label != options[1].label)
    #expect(
      try SendReminderSchedule.resolve(
        localComponents: repeated,
        timeZone: timeZone,
        repeatedTimeChoice: .second
      ) == options[1].date
    )
  }

  @Test
  func separateStoreInstancesSerializeConcurrentDraftUpdates() async throws {
    let rootDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let keyMaterialStore = try keyedStore(productAccountId: "account")
    let stores = (0..<2).map { _ in
      FileMailCompositionDraftStore(
        keyMaterialStore: keyMaterialStore,
        rootDirectory: rootDirectory
      )
    }
    let profileId = MailProfileId(rawValue: "profile")
    let drafts = (0..<24).map { draft(recipient: "recipient-\($0)@example.com") }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for (index, draft) in drafts.enumerated() {
        let store = stores[index % stores.count]
        group.addTask {
          try store.save(draft, productAccountId: "account", profileId: profileId)
        }
      }
      try await group.waitForAll()
    }

    #expect(
      Set(try stores[0].load(productAccountId: "account", profileId: profileId).map(\.id))
        == Set(drafts.map(\.id))
    )
  }

  @Test
  func inactiveProfileDraftRefreshDoesNotInvalidateActiveLoad() throws {
    let inactiveProfileId = MailProfileId(rawValue: "profile-a")
    let activeProfileId = MailProfileId(rawValue: "profile-b")
    var gate = MailCompositionDraftLoadGate()
    let activeLoad = gate.begin(profileId: activeProfileId, activeProfileId: activeProfileId)
    let activeLoadGeneration = try #require(activeLoad).generation

    let inactiveLoad = gate.begin(
      profileId: inactiveProfileId,
      activeProfileId: activeProfileId
    )
    #expect(inactiveLoad?.generation == nil)
    #expect(gate.generation == activeLoadGeneration)
  }

  @Test
  func draftLoadGateMarksProfileTransitionsForImmediateClearing() throws {
    let firstProfileId = MailProfileId(rawValue: "profile-a")
    let secondProfileId = MailProfileId(rawValue: "profile-b")
    var gate = MailCompositionDraftLoadGate()

    let firstLoadCandidate = gate.begin(
      profileId: firstProfileId,
      activeProfileId: firstProfileId
    )
    let firstLoad = try #require(firstLoadCandidate)
    let refreshCandidate = gate.begin(
      profileId: firstProfileId,
      activeProfileId: firstProfileId
    )
    let refresh = try #require(refreshCandidate)
    let switchedLoadCandidate = gate.begin(
      profileId: secondProfileId,
      activeProfileId: secondProfileId
    )
    let switchedLoad = try #require(switchedLoadCandidate)

    #expect(firstLoad.clearsExistingDrafts)
    #expect(refresh.clearsExistingDrafts == false)
    #expect(switchedLoad.clearsExistingDrafts)
  }

  @Test
  func viewModelFlushesLatestEditAndDeletesOnlyAfterOutboxAdmission() async {
    var savedDrafts: [MailShellCompositionDraft] = []
    var deletedDraftIds: [UUID] = []
    var admittedDrafts: [MailShellCompositionDraft] = []
    var initialDraft = draft(recipient: "recipient@example.com")
    initialDraft.subject = "Subject"
    let viewModel = MailComposerViewModel(
      draft: initialDraft,
      presentation: .partial,
      saveDraft: { savedDrafts.append($0) },
      deleteDraft: { deletedDraftIds.append($0) },
      sendDraft: {
        admittedDrafts.append($0)
        return true
      }
    )

    viewModel.draft.document = SemanticMessageDocument(plainText: "First edit")
    viewModel.draftChanged()
    viewModel.draft.document = SemanticMessageDocument(plainText: "Latest edit")
    viewModel.draftChanged()

    #expect(await viewModel.send() == .sent)
    #expect(savedDrafts.last?.body == "Latest edit")
    #expect(savedDrafts.last == viewModel.draft)
    #expect(admittedDrafts.last?.body == "Latest edit")
    #expect(deletedDraftIds == [initialDraft.id])
    #expect(viewModel.saveState == .saved)
  }

  @Test(
    .bug(id: 377),
    arguments: [
      MailCompositionKind.newMessage,
      .reply,
      .replyAll,
      .forward,
    ]
  )
  func everySendCapableComposerCanSaveAnIncompleteDraftReminder(
    kind: MailCompositionKind
  ) async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var source = MailShellCompositionDraft(
      body: "Unfinished",
      connectionId: connectionId,
      recipient: "",
      replyToMessage: nil,
      sourceMessage: nil,
      subject: "",
      kind: kind
    )
    source.sendReminder = nil
    var savedDrafts: [MailShellCompositionDraft] = []
    var scheduledDrafts: [MailShellCompositionDraft] = []
    let viewModel = MailComposerViewModel(
      draft: source,
      presentation: .partial,
      reminderOwnerDeviceId: "device-a",
      now: { now },
      saveDraft: { savedDrafts.append($0) },
      scheduleReminder: {
        scheduledDrafts.append($0)
        return .scheduled
      },
      sendDraft: { _ in false }
    )

    #expect(viewModel.canCreateSendReminder)
    #expect(
      await viewModel.remind(
        at: now.addingTimeInterval(3_600),
        timeZoneIdentifier: "Europe/Prague"
      )
    )
    let reminder = try #require(viewModel.draft.sendReminder)
    #expect(reminder.originatingDeviceId == "device-a")
    #expect(reminder.dueAt == now.addingTimeInterval(3_600))
    #expect(savedDrafts.last == viewModel.draft)
    #expect(scheduledDrafts.last == viewModel.draft)
    #expect(viewModel.reminderState == .saved(.scheduled))
  }

  @Test(.bug(id: 377))
  func reminderRescheduleAdvancesRevisionAndSendOrDiscardCancelsCurrentRevision() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var source = draft(recipient: "recipient@example.com")
    source.subject = "Subject"
    var cancelled: [(UUID, UUID)] = []
    let viewModel = MailComposerViewModel(
      draft: source,
      presentation: .partial,
      reminderOwnerDeviceId: "device-a",
      now: { now },
      cancelReminder: { reminder, draftId in
        cancelled.append((reminder.revision, draftId))
      },
      scheduleReminder: { _ in .scheduled },
      sendDraft: { _ in true }
    )

    #expect(
      await viewModel.remind(
        at: now.addingTimeInterval(3_600),
        timeZoneIdentifier: "Europe/Prague"
      )
    )
    let first = try #require(viewModel.draft.sendReminder)
    #expect(
      await viewModel.remind(
        at: now.addingTimeInterval(7_200),
        timeZoneIdentifier: "Europe/Prague"
      )
    )
    let second = try #require(viewModel.draft.sendReminder)
    #expect(second.id == first.id)
    #expect(second.revision != first.revision)
    #expect(await viewModel.send() == .sent)
    #expect(cancelled.map(\.0) == [second.revision])
    #expect(cancelled.map(\.1) == [source.id])

    var discardSource = source
    discardSource.sendReminder = first
    let discardViewModel = MailComposerViewModel(
      draft: discardSource,
      presentation: .partial,
      cancelReminder: { reminder, draftId in
        cancelled.append((reminder.revision, draftId))
      },
      sendDraft: { _ in false }
    )
    #expect(await discardViewModel.discard())
    #expect(cancelled.map(\.0) == [second.revision, first.revision])
    #expect(discardViewModel.isFinished)
  }

  @Test(.bug(id: 377))
  func notificationDenialKeepsTheSavedReminderAvailableToBecomeOverdue() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var source = draft(recipient: "")
    source.document = SemanticMessageDocument(plainText: "Finish this")
    var savedDrafts: [MailShellCompositionDraft] = []
    let viewModel = MailComposerViewModel(
      draft: source,
      presentation: .partial,
      reminderOwnerDeviceId: "device-a",
      now: { now },
      saveDraft: { savedDrafts.append($0) },
      scheduleReminder: { _ in .unavailable },
      sendDraft: { _ in false }
    )

    #expect(
      await viewModel.remind(
        at: now.addingTimeInterval(60),
        timeZoneIdentifier: "UTC"
      )
    )
    #expect(savedDrafts.last?.sendReminder != nil)
    #expect(viewModel.reminderState == .saved(.unavailable))
    #expect(viewModel.draft.sendReminder?.isOverdue(at: now.addingTimeInterval(61)) == true)
  }

  @Test(.bug(id: 377))
  func userNotificationServiceSchedulesAnAbsoluteReminderAndRoutesItsDraft() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let center = RecordingSendReminderNotificationCenter()
    center.authorizationState = .authorized
    let identifierStore = RecordingSendReminderIdentifierStore()
    let service = UserNotificationService(
      center: center,
      identifierStore: identifierStore,
      now: { now }
    )
    let reminder = SendReminder(
      dueAt: now.addingTimeInterval(3_600),
      originatingDeviceId: "device-a",
      originalTimeZoneIdentifier: "Europe/Prague"
    )
    let draftId = UUID()
    let profileId = MailProfileId(rawValue: "profile-a")

    #expect(
      try await service.scheduleSendReminder(
        reminder,
        draftId: draftId,
        productAccountId: "account-a",
        profileId: profileId
      ) == .scheduled
    )
    let request = try #require(center.request)
    let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
    #expect(trigger.nextTriggerDate() == reminder.dueAt)
    #expect(request.content.title == "Send Reminder")
    #expect(request.content.body == "A Draft is ready to finish.")
    let deepLink = try #require(SendReminderDeepLink(userInfo: request.content.userInfo))
    #expect(deepLink.draftId == draftId)
    #expect(deepLink.profileId == profileId)
    #expect(deepLink.reminderRevision == reminder.revision)
  }

  @Test(.bug(id: 377))
  func userNotificationServiceCancelsAndKeepsDeniedRemindersLocal() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let center = RecordingSendReminderNotificationCenter()
    center.authorizationState = .authorized
    let service = UserNotificationService(center: center, now: { now })
    let reminder = SendReminder(
      dueAt: now.addingTimeInterval(3_600),
      originatingDeviceId: "device-a",
      originalTimeZoneIdentifier: "Europe/Prague"
    )
    let draftId = UUID()
    let profileId = MailProfileId(rawValue: "profile-a")
    _ = try await service.scheduleSendReminder(
      reminder,
      draftId: draftId,
      productAccountId: "account-a",
      profileId: profileId
    )
    let identifier = try #require(center.request?.identifier)

    service.cancelSendReminder(
      reminder,
      draftId: draftId,
      productAccountId: "account-a",
      profileId: profileId
    )
    #expect(center.removedPendingIdentifiers == [identifier])
    #expect(center.removedDeliveredIdentifiers == [identifier])

    center.authorizationState = .denied
    center.request = nil
    #expect(
      try await service.scheduleSendReminder(
        reminder.rescheduled(
          to: now.addingTimeInterval(7_200),
          originalTimeZoneIdentifier: "UTC",
          changedByTrustedDeviceId: "device-a",
          changedAt: now.addingTimeInterval(1)
        ),
        draftId: draftId,
        productAccountId: "account-a",
        profileId: profileId
      ) == .unavailable
    )
    #expect(center.request == nil)
  }

  @Test
  func viewModelWaitsForCancelledAutosaveBeforeFlushingLatestDraft() async {
    let saver = ControlledDraftSaver()
    var initialDraft = draft(recipient: "recipient@example.com")
    initialDraft.document = SemanticMessageDocument(plainText: "First edit")
    let viewModel = MailComposerViewModel(
      draft: initialDraft,
      presentation: .partial,
      saveDraft: { try await saver.save($0) },
      sendDraft: { _ in true }
    )

    viewModel.draftChanged()
    await saver.waitForFirstSave()
    viewModel.draft.document = SemanticMessageDocument(plainText: "Latest edit")
    viewModel.draftChanged()
    let closeTask = Task { await viewModel.close() }
    await saver.waitForFirstSaveCancellation()

    #expect(saver.startedBodies == ["First edit"])
    saver.releaseFirstSave()
    #expect(await closeTask.value)
    #expect(saver.completedBodies == ["First edit", "Latest edit"])
  }

  @Test(.bug(id: 562))
  func switchingDraftsFlushesFirstAndRestoresItsEditorSession() async {
    var savedDrafts: [MailShellCompositionDraft] = []
    var first = draft(recipient: "first@example.com")
    first.document = SemanticMessageDocument(plainText: "First body")
    var second = draft(recipient: "second@example.com")
    second.document = SemanticMessageDocument(plainText: "Second body")
    let viewModel = MailComposerViewModel(
      draft: first,
      presentation: .partial,
      saveDraft: { savedDrafts.append($0) },
      sendDraft: { _ in false }
    )
    let firstEditor = viewModel.editorModel
    firstEditor.updateSelection(offsets: 0..<5)
    firstEditor.toggleInline(.bold)
    viewModel.editorDocumentChanged()

    #expect(await viewModel.switchDraft(to: second))
    #expect(savedDrafts.map(\.id) == [first.id])
    #expect(viewModel.draft.id == second.id)
    #expect(viewModel.editorModel !== firstEditor)

    var reopenedFirst = first
    reopenedFirst.document = firstEditor.document
    #expect(await viewModel.switchDraft(to: reopenedFirst))
    #expect(savedDrafts.map(\.id) == [first.id, second.id])
    #expect(viewModel.editorModel === firstEditor)
    #expect(viewModel.editorModel.canUndo)
  }

  @Test(.bug(id: 562))
  func switchingToNewerRevisionOfVisibleDraftReplacesItsEditorWithoutSavingStaleContent() async {
    var savedDrafts: [MailShellCompositionDraft] = []
    var visible = draft(recipient: "recipient@example.com")
    visible.document = SemanticMessageDocument(plainText: "Stale body")
    let viewModel = MailComposerViewModel(
      draft: visible,
      presentation: .partial,
      saveDraft: { savedDrafts.append($0) },
      sendDraft: { _ in false }
    )
    let staleEditor = viewModel.editorModel
    var incoming = visible
    incoming.document = SemanticMessageDocument(plainText: "Newer body")
    incoming.markEdited(now: Date.now.addingTimeInterval(1))

    #expect(await viewModel.switchDraft(to: incoming))
    #expect(savedDrafts.isEmpty)
    #expect(viewModel.draft == incoming)
    #expect(viewModel.editorModel !== staleEditor)
    #expect(viewModel.editorModel.document == incoming.document)
  }

  @Test(.bug(id: 562))
  func droppedFileImportTargetsTheVisibleDraft() {
    let draftId = UUID()

    #expect(MailShellComposer.fileImportTargetsActiveDraft(draftId, activeDraftId: draftId))
  }

  @Test(.bug(id: 562))
  func droppedFileImportAfterDraftSwitchIsIgnored() {
    #expect(
      MailShellComposer.fileImportTargetsActiveDraft(UUID(), activeDraftId: UUID()) == false
    )
  }

  @Test(.bug(id: 562))
  func conflictCopyReportsRecoveryAndMovesItsReminderNotification() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var source = draft(recipient: "recipient@example.com")
    source.sendReminder = SendReminder(
      dueAt: now.addingTimeInterval(3_600),
      originatingDeviceId: "device-a",
      originalTimeZoneIdentifier: "UTC"
    )
    let copy = source.preservingAsConflictCopy(now: now)
    var cancelledDraftIds: [UUID] = []
    var scheduledDraftIds: [UUID] = []
    let viewModel = MailComposerViewModel(
      draft: source,
      presentation: .partial,
      saveDraft: { _ in throw MailCompositionDraftSaveConflict(copy: copy) },
      cancelReminder: { _, draftId in cancelledDraftIds.append(draftId) },
      scheduleReminder: {
        scheduledDraftIds.append($0.id)
        return .scheduled
      },
      sendDraft: { _ in false }
    )

    #expect(await viewModel.close())
    #expect(viewModel.draft == copy)
    #expect(
      viewModel.noticeMessage == MailCompositionDraftSaveConflict(copy: copy).errorDescription
    )
    #expect(cancelledDraftIds == [source.id])
    #expect(scheduledDraftIds == [copy.id])
    #expect(viewModel.reminderState == .saved(.scheduled))
  }

  @Test(.bug(id: 562))
  func editingConflictCopyClearsNoticeAndExposesSaveFailure() async {
    var source = draft(recipient: "recipient@example.com")
    source.subject = "Concurrent edits"
    let copy = source.preservingAsConflictCopy()
    var saveAttempt = 0
    let viewModel = MailComposerViewModel(
      draft: source,
      presentation: .partial,
      saveDraft: { _ in
        saveAttempt += 1
        if saveAttempt == 1 {
          throw MailCompositionDraftSaveConflict(copy: copy)
        }
        throw DraftFixtureError.saveFailed
      },
      sendDraft: { _ in false }
    )

    #expect(await viewModel.close())
    #expect(
      viewModel.noticeMessage == MailCompositionDraftSaveConflict(copy: copy).errorDescription
    )
    viewModel.draft.subject = "Retry"
    viewModel.draftChanged()
    #expect(viewModel.noticeMessage == nil)
    #expect(await viewModel.close() == false)
    #expect(viewModel.saveState == .failed(DraftFixtureError.saveFailed.localizedDescription))
  }

  @Test(.bug(id: 562))
  func failedAutosaveBlocksDraftSwitchAndKeepsCurrentEditor() async {
    var first = draft(recipient: "first@example.com")
    first.document = SemanticMessageDocument(plainText: "Unsaved edit")
    let second = draft(recipient: "second@example.com")
    let viewModel = MailComposerViewModel(
      draft: first,
      presentation: .partial,
      saveDraft: { _ in throw DraftFixtureError.saveFailed },
      sendDraft: { _ in false }
    )
    let editor = viewModel.editorModel

    #expect(!(await viewModel.switchDraft(to: second)))
    #expect(viewModel.draft.id == first.id)
    #expect(viewModel.editorModel === editor)
    guard case .failed = viewModel.saveState else {
      Issue.record("Expected the failed autosave to remain inline")
      return
    }
  }

  @Test
  func discardWaitsForCancelledAutosaveBeforeReportingDeletionFailure() async {
    let saver = ControlledDraftSaver()
    var deleteAttempted = false
    var initialDraft = draft(recipient: "recipient@example.com")
    initialDraft.document = SemanticMessageDocument(plainText: "Autosaving")
    let viewModel = MailComposerViewModel(
      draft: initialDraft,
      presentation: .partial,
      saveDraft: { try await saver.save($0) },
      deleteDraft: { _ in
        deleteAttempted = true
        throw DraftFixtureError.deleteFailed
      },
      sendDraft: { _ in true }
    )

    viewModel.draftChanged()
    await saver.waitForFirstSave()
    let discardTask = Task { await viewModel.discard() }
    await saver.waitForFirstSaveCancellation()

    #expect(!deleteAttempted)
    saver.releaseFirstSave()
    #expect(await discardTask.value == false)
    #expect(deleteAttempted)
    guard case .failed = viewModel.saveState else {
      Issue.record("Expected the Draft deletion failure to remain recorded")
      return
    }
  }

  @Test(.bug(id: 377))
  func remindWaitsForCancelledAutosaveBeforeReportingReminderSaveFailure() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let saver = ControlledDraftSaver(failAfterFirstSave: true)
    var initialDraft = draft(recipient: "recipient@example.com")
    initialDraft.document = SemanticMessageDocument(plainText: "Autosaving")
    let viewModel = MailComposerViewModel(
      draft: initialDraft,
      presentation: .partial,
      reminderOwnerDeviceId: "device-a",
      now: { now },
      saveDraft: { try await saver.save($0) },
      sendDraft: { _ in false }
    )

    viewModel.draftChanged()
    await saver.waitForFirstSave()
    let remindTask = Task {
      await viewModel.remind(
        at: now.addingTimeInterval(3_600),
        timeZoneIdentifier: "Europe/Prague"
      )
    }
    await saver.waitForFirstSaveCancellation()

    #expect(saver.startedDrafts.count == 1)
    saver.releaseFirstSave()
    #expect(await remindTask.value == false)
    #expect(saver.startedDrafts.count == 2)
    #expect(saver.startedDrafts.last?.sendReminder != nil)
    #expect(viewModel.draft.sendReminder == nil)
    guard case .failed = viewModel.reminderState else {
      Issue.record("Expected the reminder save failure to remain recorded")
      return
    }
  }

  @Test
  func emptyDraftDoesNotAutosaveAndCloseRemovesAnyStoredCopy() async {
    var savedDrafts: [MailShellCompositionDraft] = []
    var deletedDraftIds: [UUID] = []
    let initialDraft = MailShellCompositionDraft.new(defaultSendingConnectionId: connectionId)
    let viewModel = MailComposerViewModel(
      draft: initialDraft,
      presentation: .partial,
      saveDraft: { savedDrafts.append($0) },
      deleteDraft: { deletedDraftIds.append($0) },
      sendDraft: { _ in true }
    )

    viewModel.draftChanged()
    #expect(viewModel.saveState == .idle)
    #expect(await viewModel.close())
    #expect(savedDrafts.isEmpty)
    #expect(deletedDraftIds == [initialDraft.id])
  }

  @Test
  func admittedSendRemainsSentWhenDraftCleanupFails() async {
    var deleteAttempts = 0
    var initialDraft = draft(recipient: "recipient@example.com")
    initialDraft.subject = "Subject"
    let viewModel = MailComposerViewModel(
      draft: initialDraft,
      presentation: .partial,
      deleteDraft: { _ in
        deleteAttempts += 1
        throw DraftFixtureError.deleteFailed
      },
      sendDraft: { _ in true }
    )

    #expect(await viewModel.send() == .sent)
    #expect(deleteAttempts == 2)
    guard case .failed = viewModel.saveState else {
      Issue.record("Expected the Draft cleanup failure to remain recorded")
      return
    }
  }

  @Test
  func failedDraftSaveBlocksCloseAndCanBeRetried() async {
    var shouldFail = true
    var draft = draft(recipient: "recipient@example.com")
    draft.subject = "Subject"
    let viewModel = MailComposerViewModel(
      draft: draft,
      presentation: .partial,
      saveDraft: { _ in
        if shouldFail { throw DraftFixtureError.saveFailed }
      },
      sendDraft: { _ in true }
    )

    viewModel.draft.document = SemanticMessageDocument(plainText: "Edited")
    viewModel.draftChanged()
    #expect(!(await viewModel.close()))
    guard case .failed = viewModel.saveState else {
      Issue.record("Expected the failed save to remain visible")
      return
    }

    shouldFail = false
    #expect(await viewModel.close())
    #expect(viewModel.saveState == .saved)
  }

  @Test
  func missingSubjectConfirmsOnceAndInvalidRecipientsNeverSend() async {
    var sendCount = 0
    let viewModel = MailComposerViewModel(
      draft: draft(recipient: "recipient@example.com"),
      presentation: .partial,
      sendDraft: { _ in
        sendCount += 1
        return true
      }
    )

    #expect(await viewModel.send() == .needsSubjectConfirmation)
    #expect(await viewModel.sendWithoutSubject() == .sent)
    #expect(sendCount == 1)

    var invalidDraft = draft(recipient: "not an address")
    invalidDraft.subject = "Subject"
    let invalidViewModel = MailComposerViewModel(
      draft: invalidDraft,
      presentation: .partial,
      sendDraft: { _ in
        sendCount += 1
        return true
      }
    )
    #expect(await invalidViewModel.send() == .notSent)
    #expect(sendCount == 1)
  }

  @Test
  func recipientValidationCoversToCcAndBcc() {
    var draft = draft(recipient: "Recipient <recipient@example.com>")
    draft.ccRecipients = "copy@example.com"
    draft.bccRecipients = "Hidden <hidden@example.com>"

    #expect(draft.recipientsAreValid)
    #expect(
      draft.deliveryRecipientHeader
        == "Recipient <recipient@example.com>, copy@example.com, Hidden <hidden@example.com>"
    )

    draft.bccRecipients = "unfinished@"
    #expect(!(draft.recipientsAreValid))
  }

  @Test(.bug(id: 162))
  func deliveryDocumentCombinesSignatureAndQuotedTextWithoutEmptyLeadingBlock() {
    var emptyDraft = draft(recipient: "recipient@example.com")
    emptyDraft.signature = MailSignature(
      name: "Default",
      document: SignatureDocument(text: "Sender")
    )

    #expect(emptyDraft.deliveryDocument.plainText == "-- \nSender")

    let reply = MailShellCompositionDraft(
      body: "Reply",
      connectionId: connectionId,
      recipient: "recipient@example.com",
      replyToMessage: nil,
      sourceMessage: nil,
      subject: "Subject",
      quotedText: "Earlier\nmessage",
      signature: MailSignature(
        name: "Default",
        document: SignatureDocument(text: "Sender")
      )
    )

    #expect(reply.deliveryDocument.plainText == "Reply\n\n-- \nSender\n\n> Earlier\n> message")
    #expect(reply.deliveryDocument.blocks.suffix(2).allSatisfy { $0.kind == .blockquote })
  }

  @Test
  func recipientSuggestionsPreferLocalRecentsAndDeduplicateCorrespondents() async {
    let recent = message(
      from: "sender@example.com",
      providerMessageId: "sent",
      providerStateIds: ["SENT"],
      recipientHeaders: ["Alice Fixture <alice161fixture@example.com>"],
      receivedAt: 200
    )
    let correspondent = message(
      from: "Alice Fixture <alice161fixture@example.com>",
      providerMessageId: "received",
      providerStateIds: ["INBOX"],
      recipientHeaders: ["sender@example.com"],
      receivedAt: 100
    )
    let service = MailRecipientSuggestionService()

    let suggestions = await service.suggestions(
      matching: "alice161fixture",
      messages: [correspondent, recent]
    )

    #expect(suggestions.first?.emailAddress == "alice161fixture@example.com")
    #expect(suggestions.first?.source == .recent)
    #expect(suggestions.map(\.emailAddress).count == Set(suggestions.map(\.emailAddress)).count)
  }

  @Test(.bug(id: 555))
  func recipientEditorCreatesRemovableTokensFromSuggestionsAndSeparators() throws {
    var editor = MailRecipientEditor(to: "first@example.com", cc: "", bcc: "")
    let suggestion = MailRecipientSuggestion(
      displayName: #"Path\Name "Alias""#,
      emailAddress: "alias@example.com",
      source: .contact
    )

    #expect(suggestion.headerValue == #""Path\\Name \"Alias\"" <alias@example.com>"#)
    editor.accept(suggestion, in: .to)
    editor.updatePendingText("copy@example.com;", in: .cc)

    #expect(
      editor.headers.to == #"first@example.com, "Path\\Name \"Alias\"" <alias@example.com>"#
    )
    #expect(editor.headers.cc == "copy@example.com")
    let copyToken = try #require(editor.tokens(in: .cc).first)
    editor.remove(copyToken, from: .cc)
    #expect(editor.headers.cc.isEmpty)
  }

  @Test(.bug(id: 555))
  func recipientEditorKeepsInvalidTextAndRejectsDuplicatesAcrossFields() {
    var editor = MailRecipientEditor(
      to: "Alice <alice@example.com>",
      cc: "copy@example.com",
      bcc: ""
    )

    editor.updatePendingText("unfinished@", in: .bcc)
    editor.commitPendingText(in: .bcc)
    #expect(editor.pendingText(in: .bcc) == "unfinished@")
    #expect(editor.issue(in: .bcc) == .invalidAddress)
    #expect(editor.headers.bcc == "unfinished@")

    editor.updatePendingText("ALICE@example.com,", in: .bcc)
    #expect(editor.tokens(in: .bcc).isEmpty)
    #expect(editor.pendingText(in: .bcc).isEmpty)
    #expect(editor.issue(in: .bcc) == .alreadyAdded)
    #expect(editor.headers.bcc.isEmpty)
  }

  @Test(.bug(id: 555))
  func recipientEditorPreservesAddressCaseAndQuotedSemicolons() {
    var editor = MailRecipientEditor(to: "", cc: "", bcc: "")

    editor.updatePendingText(
      #""Team; West" <CaseSensitive@Example.COM>;"semi;colon"@Example.COM;"#,
      in: .to
    )

    #expect(
      editor.tokens(in: .to).map(\.emailAddress)
        == ["CaseSensitive@Example.COM", #""semi;colon"@Example.COM"#]
    )
    #expect(
      editor.headers.to
        == #""Team; West" <CaseSensitive@Example.COM>, "semi;colon"@Example.COM"#
    )
  }

  @Test(.bug(id: 555))
  func recipientEditorRestoresOptionalRecipientTokensFromDraftHeaders() {
    let editor = MailRecipientEditor(
      to: "to@example.com",
      cc: "Copy <copy@example.com>",
      bcc: "hidden@example.com"
    )

    #expect(editor.hasPopulatedOptionalRecipients)
    #expect(editor.tokens(in: .cc).map(\.emailAddress) == ["copy@example.com"])
    #expect(editor.tokens(in: .bcc).map(\.emailAddress) == ["hidden@example.com"])
    #expect(editor.headers.cc == #""Copy" <copy@example.com>"#)
  }

  @Test
  func explicitReadReceiptChoiceSurvivesSenderPolicyChanges() {
    var draft = draft(recipient: "recipient@example.com")

    draft.recordReadReceiptChoice(false)
    draft.applyInitialReadReceiptPolicy(.requestByDefault)

    #expect(draft.hasExplicitReadReceiptChoice)
    #expect(!(draft.requestsReadReceipt))
  }

  @Test(.bug(id: 163))
  func draftAssetsChunkRoundTripAndFailClosedAfterCorruption() throws {
    let bytes = Data(repeating: 0xA5, count: MailDraftAssetChunk.maximumByteCount + 17)
    let asset = MailDraftAsset(
      data: bytes,
      filename: "diagram.png",
      mediaType: "image/png",
      disposition: .inline
    )

    #expect(asset.chunks.count == 2)
    #expect(asset.data == bytes)
    #expect(asset.isComplete)
    let roundTripped = try JSONDecoder().decode(
      MailDraftAsset.self,
      from: JSONEncoder().encode(asset)
    )
    #expect(roundTripped == asset)

    var corrupted = asset
    corrupted.chunks[0] = MailDraftAssetChunk(data: Data([0]), index: 0)
    #expect(corrupted.data == nil)
    #expect(corrupted.isComplete == false)
  }

  @Test(.bug(id: 163))
  func encryptedDraftAssetChunksSynchronizeAcrossTrustedDevicesAndCleanUp() async throws {
    let accountId = "draft-asset-sync-account"
    let keyMaterialStore = try keyedStore(productAccountId: accountId)
    let transport = InMemoryProductSyncRecordTransport()
    let makeService = {
      MailCompositionDraftSyncService(
        recordBoundary: ProductSyncRecordBoundary(
          keyMaterialStore: keyMaterialStore,
          transport: transport
        )
      )
    }
    let firstSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user",
      identityToken: "token-a",
      productAccountId: accountId,
      trustedDeviceId: "device-a"
    )
    let secondSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user",
      identityToken: "token-b",
      productAccountId: accountId,
      trustedDeviceId: "device-b"
    )
    let profileId = MailProfileId(rawValue: "profile-a")
    var source = draft(recipient: "recipient@example.com")
    source.ccRecipients = "Copy <copy@example.com>"
    source.bccRecipients = "hidden@example.com"
    source.assets = [
      MailDraftAsset(
        data: Data(repeating: 0xA5, count: MailDraftAssetChunk.maximumByteCount + 17),
        filename: "private.bin",
        mediaType: "application/octet-stream"
      )
    ]

    _ = try await makeService().save(source, profileId: profileId, session: firstSession)
    let synchronized = try await makeService().snapshot(
      profileId: profileId,
      session: secondSession
    )

    #expect(synchronized.drafts == [source])
    #expect(synchronized.removedDraftIds.isEmpty)
    try await makeService().remove(source.id, profileId: profileId, session: secondSession)
    let removed = try await makeService().snapshot(
      profileId: profileId,
      session: firstSession
    )
    #expect(removed.drafts.isEmpty)
    #expect(removed.removedDraftIds == [source.id])
  }

  @Test(.bug(id: 562))
  // swiftlint:disable:next function_body_length
  func productSyncDeletionRaceMaterializesAuthoredEditsAsConflictCopy() async throws {
    let rootDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let accountId = "draft-conflict-account"
    let keyMaterialStore = try keyedStore(productAccountId: accountId)
    let transport = InMemoryProductSyncRecordTransport()
    let syncService = MailCompositionDraftSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyMaterialStore,
        transport: transport
      )
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user",
      identityToken: "token",
      productAccountId: accountId,
      trustedDeviceId: "device-a"
    )
    let profileId = MailProfileId(rawValue: "profile-a")
    let store = FileMailCompositionDraftStore(
      keyMaterialStore: keyMaterialStore,
      rootDirectory: rootDirectory
    )
    var source = draft(recipient: "recipient@example.com")
    source.subject = "Concurrent edits"
    source.assets = [
      MailDraftAsset(
        data: Data("private asset".utf8),
        filename: "notes.txt",
        mediaType: "text/plain"
      )
    ]
    try store.save(source, productAccountId: accountId, profileId: profileId)
    _ = try await syncService.save(source, profileId: profileId, session: session)
    try await syncService.remove(source.id, profileId: profileId, session: session)

    source.document = SemanticMessageDocument(plainText: "Edited after remote deletion")
    source.markEdited(now: Date.now.addingTimeInterval(1))
    let repository = MailCompositionDraftRepository(
      store: store,
      syncService: syncService,
      reminderSyncService: OfflineSendReminderSyncService()
    )
    let conflictCopy: MailShellCompositionDraft
    do {
      try await repository.save(
        source,
        productAccountId: accountId,
        profileId: profileId,
        session: session
      )
      Issue.record("Expected the remote deletion to materialize a conflict copy")
      return
    } catch let conflict as MailCompositionDraftSaveConflict {
      conflictCopy = conflict.copy
    }

    #expect(conflictCopy.id != source.id)
    #expect(conflictCopy.conflictSourceId == source.id)
    #expect(conflictCopy.document == source.document)
    #expect(conflictCopy.assets == source.assets)
    let localDrafts = try await repository.drafts(
      productAccountId: accountId,
      profileId: profileId,
      session: session
    )
    #expect(localDrafts == [conflictCopy])
    let remote = try await syncService.snapshot(profileId: profileId, session: session)
    #expect(remote.drafts == [conflictCopy])
    #expect(remote.removedDraftIds == [source.id])
  }

  @Test(.bug(id: 562))
  func idOnlyRemovedDraftSnapshotTreatsTheTombstoneAsAuthoritative() {
    let draftId = UUID()
    let snapshot = MailCompositionDraftSyncSnapshot(
      drafts: [],
      removedDraftIds: [draftId]
    )

    #expect(snapshot.removedDraftUpdatedAtMilliseconds[draftId] == .max)
  }

  @Test(.bug(id: 562))
  func conflictCopyStorageFailureRetainsTheAuthoredDraft() async throws {
    var source = draft(recipient: "recipient@example.com")
    source.document = SemanticMessageDocument(plainText: "Keep this edit")
    source.markEdited(now: Date(timeIntervalSince1970: 2_000_000_000))
    let syncService = RemovedDraftSyncService(
      draftId: source.id,
      removedAt: source.updatedAtMilliseconds - 1
    )
    let repository = MailCompositionDraftRepository(
      store: ReadOnlyDraftStore(drafts: [source]),
      syncService: syncService,
      reminderSyncService: OfflineSendReminderSyncService()
    )
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user",
      identityToken: "token",
      productAccountId: "account",
      trustedDeviceId: "device"
    )

    let drafts = try await repository.drafts(
      productAccountId: "account",
      profileId: MailProfileId(rawValue: "profile"),
      session: session
    )

    #expect(drafts == [source])
    #expect(await syncService.savedDraftIds().isEmpty)
  }

  @Test(.bug(id: 562))
  func conflictCopyReplacementFailureLeavesOriginalDraftIntact() throws {
    let rootDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let accountId = "draft-conflict-replacement-account"
    let profileId = MailProfileId(rawValue: "profile")
    let keyMaterialStore = try keyedStore(productAccountId: accountId)
    let initialStore = FileMailCompositionDraftStore(
      keyMaterialStore: keyMaterialStore,
      rootDirectory: rootDirectory
    )
    let source = draft(recipient: "recipient@example.com")
    try initialStore.save(source, productAccountId: accountId, profileId: profileId)
    let originalSize =
      try #require(
        draftFiles(in: rootDirectory).first { $0.pathExtension == "json" }
      ).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    var copy = source.preservingAsConflictCopy()
    copy.document = SemanticMessageDocument(plainText: String(repeating: "x", count: 4_096))
    let constrainedStore = FileMailCompositionDraftStore(
      keyMaterialStore: keyMaterialStore,
      rootDirectory: rootDirectory,
      storageLimit: originalSize
    )

    #expect(throws: MailCompositionDraftStoreError.storageLimitExceeded) {
      try constrainedStore.replace(
        source.id,
        with: copy,
        productAccountId: accountId,
        profileId: profileId
      )
    }
    #expect(try initialStore.load(productAccountId: accountId, profileId: profileId) == [source])
  }

  @Test(.bug(id: 163))
  func offlineDraftAssetSaveRemainsLocalAndFailedCleanupDoesNotResurrectData() async throws {
    let rootDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let accountId = "offline-draft-account"
    let repository = MailCompositionDraftRepository(
      store: FileMailCompositionDraftStore(
        keyMaterialStore: try keyedStore(productAccountId: accountId),
        rootDirectory: rootDirectory
      ),
      syncService: OfflineDraftSyncService(),
      reminderSyncService: OfflineSendReminderSyncService()
    )
    let profileId = MailProfileId(rawValue: "profile")
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user",
      identityToken: "token",
      productAccountId: accountId,
      trustedDeviceId: "device"
    )
    var source = draft(recipient: "recipient@example.com")
    source.assets = [
      MailDraftAsset(
        data: Data("offline".utf8),
        filename: "offline.txt",
        mediaType: "text/plain"
      )
    ]

    try await repository.save(
      source,
      productAccountId: accountId,
      profileId: profileId,
      session: session
    )
    #expect(
      try await repository.drafts(
        productAccountId: accountId,
        profileId: profileId,
        session: session
      ) == [source]
    )
    await #expect(throws: DraftFixtureError.self) {
      try await repository.remove(
        source.id,
        productAccountId: accountId,
        profileId: profileId,
        session: session
      )
    }
    #expect(
      try await repository.drafts(productAccountId: accountId, profileId: profileId) == [source]
    )
  }

  @Test(.bug(id: 163))
  func draftPersistsAssetsAndBuildsContentIdHTML() throws {
    let asset = MailDraftAsset(
      data: Data("image".utf8),
      filename: "A&B.png",
      mediaType: "image/png",
      disposition: .inline
    )
    var source = draft(recipient: "recipient@example.com")
    source.assets = [asset]
    source.document = SemanticMessageDocument(
      blocks: [.init(runs: [.init("", inlineAssetId: asset.id)])]
    )

    let decoded = try JSONDecoder().decode(
      MailShellCompositionDraft.self,
      from: JSONEncoder().encode(source)
    )

    #expect(decoded.assets == [asset])
    #expect(decoded.deliveryHTML.contains("cid:\(asset.contentId)"))
    #expect(decoded.deliveryHTML.contains("A&amp;B.png"))
    #expect(decoded.hasUserState)
    #expect(decoded.assetsAreReady)

    source.toggleAssetDisposition(asset.id)
    #expect(source.assets[0].disposition == .attachment)
    source.removeAsset(asset.id)
    #expect(source.assets.isEmpty)
  }

  @Test(.bug(id: 163))
  func forwardIncludesAvailableSourceAssetsAndReportsUnavailableAttachments() {
    var source = draft(recipient: "recipient@example.com")
    source.includeLocallyAvailableForwardAssets(
      from: MailboxMessageBody(
        text: "Forwarded body",
        inlineImages: [
          MailboxMessageInlineImage(
            contentID: "source-image",
            data: Data("image".utf8),
            decodedPixelCount: 1,
            mimeType: "image/png"
          )
        ],
        attachments: [
          MailboxMessageAttachment(
            byteCount: 3,
            filename: "available.txt",
            id: "available",
            mimeType: "text/plain",
            presentationData: Data("yes".utf8)
          ),
          MailboxMessageAttachment(
            byteCount: 10,
            filename: "remote.pdf",
            id: "remote",
            mimeType: "application/pdf"
          ),
        ]
      )
    )

    #expect(source.assets.count == 2)
    #expect(source.assets.map(\.disposition) == [.inline, .attachment])
    #expect(source.omittedForwardAttachmentCount == 1)
  }

  @MainActor
  @Test(.bug(id: 163))
  func incompleteAssetBlocksComposerSend() async {
    var source = draft(recipient: "recipient@example.com")
    source.subject = "Subject"
    var asset = MailDraftAsset(
      data: Data("asset".utf8),
      filename: "asset.bin",
      mediaType: "application/octet-stream"
    )
    asset.chunks.removeAll()
    source.assets = [asset]
    var sendCount = 0
    let viewModel = MailComposerViewModel(
      draft: source,
      presentation: .partial,
      sendDraft: { _ in
        sendCount += 1
        return true
      }
    )

    #expect(viewModel.canSend == false)
    #expect(await viewModel.send() == .notSent)
    #expect(sendCount == 0)
  }

  private func draft(recipient: String) -> MailShellCompositionDraft {
    MailShellCompositionDraft(
      body: "",
      connectionId: connectionId,
      recipient: recipient,
      replyToMessage: nil,
      sourceMessage: nil,
      subject: ""
    )
  }

  private func keyedStore(
    productAccountId: String
  ) throws -> InMemoryProductSyncKeyMaterialStore {
    let store = InMemoryProductSyncKeyMaterialStore()
    _ = try store.ensureMaterial(productAccountId: productAccountId, allowCreation: true)
    return store
  }

  private func message(
    from: String,
    providerMessageId: String,
    providerStateIds: [String],
    recipientHeaders: [String],
    receivedAt: Int64
  ) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: nil,
      connectionId: connectionId,
      from: from,
      isHistorical: false,
      providerInternalDateMilliseconds: receivedAt,
      providerMessageId: providerMessageId,
      providerStateIds: providerStateIds,
      providerThreadId: "thread-\(providerMessageId)",
      recipientHeaders: recipientHeaders,
      replyTo: nil,
      rfcMessageId: "<\(providerMessageId)@example.com>",
      snippet: "Message",
      subject: "Subject"
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "MailCompositionDraftTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }

  private func draftFiles(in rootDirectory: URL) -> [URL] {
    FileManager.default.enumerator(at: rootDirectory, includingPropertiesForKeys: nil)?
      .allObjects.compactMap { $0 as? URL } ?? []
  }
}

@MainActor
private final class ControlledDraftSaver {
  private(set) var completedBodies: [String] = []
  private(set) var startedDrafts: [MailShellCompositionDraft] = []
  private(set) var startedBodies: [String] = []
  private let failAfterFirstSave: Bool
  private let firstSaveCancellationContinuation: AsyncStream<Void>.Continuation
  private let firstSaveCancellationStream: AsyncStream<Void>
  private var firstSaveContinuation: CheckedContinuation<Void, Never>?
  private var hasReleasedFirstSave = false

  init(failAfterFirstSave: Bool = false) {
    self.failAfterFirstSave = failAfterFirstSave
    let stream = AsyncStream<Void>.makeStream()
    firstSaveCancellationStream = stream.stream
    firstSaveCancellationContinuation = stream.continuation
  }

  func save(_ draft: MailShellCompositionDraft) async throws {
    startedDrafts.append(draft)
    startedBodies.append(draft.body)
    if startedBodies.count == 1 {
      let cancellationContinuation = firstSaveCancellationContinuation
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          if hasReleasedFirstSave {
            continuation.resume()
          } else {
            firstSaveContinuation = continuation
          }
        }
      } onCancel: {
        cancellationContinuation.yield(())
      }
    }
    if failAfterFirstSave, startedDrafts.count > 1 {
      throw DraftFixtureError.saveFailed
    }
    completedBodies.append(draft.body)
  }

  func waitForFirstSave() async {
    while startedBodies.isEmpty {
      await Task.yield()
    }
  }

  func waitForFirstSaveCancellation() async {
    for await _ in firstSaveCancellationStream {
      return
    }
  }

  func releaseFirstSave() {
    guard !hasReleasedFirstSave else { return }
    hasReleasedFirstSave = true
    firstSaveContinuation?.resume()
    firstSaveContinuation = nil
  }
}

private final class RecordingSendReminderNotificationCenter: UserNotificationCenterClient {
  var authorizationState: NotificationAuthorizationState = .notDetermined
  var request: UNNotificationRequest?
  private(set) var removedDeliveredIdentifiers: [String] = []
  private(set) var removedPendingIdentifiers: [String] = []

  func add(_ request: UNNotificationRequest) async throws {
    self.request = request
  }

  func notificationAuthorizationState() async -> NotificationAuthorizationState {
    authorizationState
  }

  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
    removedDeliveredIdentifiers = identifiers
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
    removedPendingIdentifiers = identifiers
  }

  func requestAuthorization(options _: UNAuthorizationOptions) async throws -> Bool {
    authorizationState == .authorized
  }
}

private final class RecordingSendReminderIdentifierStore: UserNotificationIdentifierPersisting {
  private var storedIdentifiers: Set<String> = []

  func allIdentifiers() -> Set<String> {
    storedIdentifiers
  }

  func identifiers(productAccountId _: String) -> Set<String> {
    storedIdentifiers
  }

  func record(identifier: String, productAccountId _: String) {
    storedIdentifiers.insert(identifier)
  }

  func clear(productAccountId _: String) {
    storedIdentifiers.removeAll()
  }
}

private enum DraftFixtureError: Error {
  case deleteFailed
  case offline
  case saveFailed
}

private struct ReadOnlyDraftStore: MailCompositionDraftPersisting {
  let drafts: [MailShellCompositionDraft]

  func clear(productAccountId _: String) throws {}

  func load(
    productAccountId _: String,
    profileId _: MailProfileId
  ) throws -> [MailShellCompositionDraft] {
    drafts
  }

  func remove(
    _: UUID,
    productAccountId _: String,
    profileId _: MailProfileId
  ) throws {}

  func replace(
    _: UUID,
    with _: MailShellCompositionDraft,
    productAccountId _: String,
    profileId _: MailProfileId
  ) throws {
    throw MailCompositionDraftStoreError.storageLimitExceeded
  }

  func save(
    _: MailShellCompositionDraft,
    productAccountId _: String,
    profileId _: MailProfileId
  ) throws {
    throw MailCompositionDraftStoreError.storageLimitExceeded
  }
}

private actor RemovedDraftSyncService: MailCompositionDraftSyncing {
  let draftId: UUID
  let removedAt: Int64
  private var savedIds: [UUID] = []

  init(draftId: UUID, removedAt: Int64) {
    self.draftId = draftId
    self.removedAt = removedAt
  }

  func snapshot(
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailCompositionDraftSyncSnapshot {
    MailCompositionDraftSyncSnapshot(
      drafts: [],
      removedDraftUpdatedAtMilliseconds: [draftId: removedAt]
    )
  }

  func remove(
    _: UUID,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func save(
    _ draft: MailShellCompositionDraft,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailCompositionDraftSyncSaveResult {
    savedIds.append(draft.id)
    return .saved
  }

  func savedDraftIds() -> [UUID] {
    savedIds
  }
}

private struct OfflineDraftSyncService: MailCompositionDraftSyncing {
  func snapshot(
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailCompositionDraftSyncSnapshot {
    throw DraftFixtureError.offline
  }

  func remove(
    _: UUID,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    throw DraftFixtureError.offline
  }

  func save(
    _: MailShellCompositionDraft,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailCompositionDraftSyncSaveResult {
    throw DraftFixtureError.offline
  }
}

private struct OfflineSendReminderSyncService: SendReminderSyncing {
  func cancel(
    draftId _: UUID,
    expectedRevision _: UUID?,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> SendReminderSyncMutation {
    throw DraftFixtureError.offline
  }

  func claimNotificationOwnership(
    draftId _: UUID,
    expectedRevision _: UUID,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> SendReminder? {
    throw DraftFixtureError.offline
  }

  func load(
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> SendReminderSyncSnapshot {
    throw DraftFixtureError.offline
  }

  func synchronize(
    _: SendReminder,
    draftId _: UUID,
    draftUpdatedAtMilliseconds _: Int64,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> SendReminderSyncMutation {
    throw DraftFixtureError.offline
  }
}
