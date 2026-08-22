import Foundation
import Observation

enum MailComposerSaveState: Equatable {
  case failed(String)
  case idle
  case pending
  case saved
  case saving

  var blocksDismissal: Bool {
    switch self {
    case .failed, .pending, .saving:
      true
    case .idle, .saved:
      false
    }
  }
}

enum MailComposerSendResult: Equatable {
  case needsSubjectConfirmation
  case notSent
  case sent
}

enum MailComposerReminderState: Equatable {
  case failed(String)
  case idle
  case saved(SendReminderNotificationOutcome)
  case saving
}

@MainActor
@Observable
final class MailComposerViewModel {
  typealias DeleteDraft = @MainActor (UUID) async throws -> Void
  typealias CancelReminder = @MainActor (SendReminder, UUID) async -> Void
  typealias SaveDraft = @MainActor (MailShellCompositionDraft) async throws -> Void
  typealias ScheduleReminder =
    @MainActor (MailShellCompositionDraft) async throws -> SendReminderNotificationOutcome
  typealias SendDraft = @MainActor (MailShellCompositionDraft) async -> Bool

  var draft: MailShellCompositionDraft
  var presentation: ComposePresentationPreference
  private(set) var reminderState: MailComposerReminderState = .idle
  private(set) var saveState: MailComposerSaveState = .idle

  private let calendar: Calendar
  private let cancelReminder: CancelReminder
  private let deleteDraft: DeleteDraft
  private var editRevision = 0
  private var hasConfirmedMissingSubject = false
  private var lastSavedDraft: MailShellCompositionDraft?
  private let now: () -> Date
  private let reminderOwnerDeviceId: String
  private let saveDraft: SaveDraft
  private let scheduleReminder: ScheduleReminder
  private let sendDraft: SendDraft
  private var autosaveTask: Task<Void, Never>?

  init(
    draft: MailShellCompositionDraft,
    presentation: ComposePresentationPreference,
    reminderOwnerDeviceId: String = "local-device",
    calendar: Calendar = .current,
    now: @escaping () -> Date = Date.init,
    saveDraft: @escaping SaveDraft = { _ in },
    deleteDraft: @escaping DeleteDraft = { _ in },
    cancelReminder: @escaping CancelReminder = { _, _ in },
    scheduleReminder: @escaping ScheduleReminder = { _ in .unavailable },
    sendDraft: @escaping SendDraft
  ) {
    self.calendar = calendar
    self.cancelReminder = cancelReminder
    self.deleteDraft = deleteDraft
    self.draft = draft
    self.presentation = presentation
    self.now = now
    self.reminderOwnerDeviceId = reminderOwnerDeviceId
    self.saveDraft = saveDraft
    self.scheduleReminder = scheduleReminder
    self.sendDraft = sendDraft
  }

  var canSend: Bool {
    draft.connectionId != nil && draft.recipientsAreValid && draft.assetsAreReady
      && !saveState.blocksDismissal
  }

  var canCreateSendReminder: Bool {
    draft.kind != .editing && draft.hasUserState && !saveState.blocksDismissal
  }

  var hasUnsavedChanges: Bool {
    lastSavedDraft != draft
  }

  func draftChanged() {
    guard lastSavedDraft != draft else { return }
    editRevision += 1
    hasConfirmedMissingSubject = false
    let previousAutosaveTask = autosaveTask
    autosaveTask?.cancel()
    guard draft.hasUserState else {
      autosaveTask = Task {
        await previousAutosaveTask?.value
      }
      saveState = .idle
      return
    }
    saveState = .pending
    let revision = editRevision
    autosaveTask = Task {
      await previousAutosaveTask?.value
      do {
        try await Task.sleep(for: .milliseconds(150))
        try Task.checkCancellation()
        _ = await persistCurrentDraft(revision: revision)
      } catch is CancellationError {
      } catch {
        guard revision == editRevision else { return }
        saveState = .failed(error.localizedDescription)
      }
    }
  }

  func close() async -> Bool {
    guard draft.hasUserState else { return await discard() }
    return await flushAutosave()
  }

  func discard() async -> Bool {
    editRevision += 1
    let pendingAutosaveTask = autosaveTask
    autosaveTask = nil
    pendingAutosaveTask?.cancel()
    await pendingAutosaveTask?.value
    do {
      try await deleteDraft(draft.id)
      await cancelCurrentReminder()
      saveState = .saved
      return true
    } catch {
      saveState = .failed(error.localizedDescription)
      return false
    }
  }

  func retryAutosave() {
    editRevision += 1
    saveState = .pending
    let revision = editRevision
    let previousAutosaveTask = autosaveTask
    autosaveTask?.cancel()
    autosaveTask = Task {
      await previousAutosaveTask?.value
      _ = await persistCurrentDraft(revision: revision)
    }
  }

  func send() async -> MailComposerSendResult {
    guard draft.connectionId != nil, draft.recipientsAreValid, draft.assetsAreReady else {
      return .notSent
    }
    if draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !hasConfirmedMissingSubject
    {
      return .needsSubjectConfirmation
    }
    guard await flushAutosave() else { return .notSent }
    guard await sendDraft(draft) else { return .notSent }
    await cancelCurrentReminder()
    do {
      try await deleteDraft(draft.id)
      saveState = .saved
    } catch {
      do {
        try await deleteDraft(draft.id)
        saveState = .saved
      } catch {
        saveState = .failed("Message queued, but its local Draft could not be removed.")
      }
    }
    return .sent
  }

  func sendWithoutSubject() async -> MailComposerSendResult {
    hasConfirmedMissingSubject = true
    return await send()
  }

  func remind(at dueAt: Date, timeZoneIdentifier: String) async -> Bool {
    guard canCreateSendReminder,
      SendReminderSchedule.isValid(dueAt: dueAt, now: now(), calendar: calendar)
    else { return false }

    editRevision += 1
    let pendingAutosaveTask = autosaveTask
    autosaveTask = nil
    pendingAutosaveTask?.cancel()
    await pendingAutosaveTask?.value

    var candidate = draft
    if let existing = candidate.sendReminder {
      candidate.sendReminder = existing.rescheduled(
        to: dueAt,
        originalTimeZoneIdentifier: timeZoneIdentifier,
        changedByTrustedDeviceId: reminderOwnerDeviceId,
        changedAt: now()
      )
    } else {
      candidate.sendReminder = SendReminder(
        dueAt: dueAt,
        originatingDeviceId: reminderOwnerDeviceId,
        originalTimeZoneIdentifier: timeZoneIdentifier,
        createdAt: now()
      )
    }
    candidate.markEdited(now: now())
    reminderState = .saving
    saveState = .saving
    do {
      try await saveDraft(candidate)
      lastSavedDraft = candidate
      draft = candidate
      saveState = .saved
    } catch {
      saveState = .failed(error.localizedDescription)
      reminderState = .failed(error.localizedDescription)
      return false
    }

    do {
      reminderState = .saved(try await scheduleReminder(candidate))
    } catch {
      reminderState = .failed(
        "Reminder saved, but this device could not schedule its notification."
      )
    }
    return true
  }

  func togglePresentation() {
    presentation = presentation == .partial ? .fullScreen : .partial
  }

  private func flushAutosave() async -> Bool {
    editRevision += 1
    let pendingAutosaveTask = autosaveTask
    autosaveTask = nil
    pendingAutosaveTask?.cancel()
    await pendingAutosaveTask?.value
    return await persistCurrentDraft(revision: editRevision)
  }

  private func cancelCurrentReminder() async {
    guard let reminder = draft.sendReminder else { return }
    await cancelReminder(reminder, draft.id)
  }

  private func persistCurrentDraft(revision: Int) async -> Bool {
    guard revision == editRevision else { return false }
    saveState = .saving
    var candidate = draft
    candidate.markEdited()
    do {
      try await saveDraft(candidate)
      guard revision == editRevision else { return false }
      lastSavedDraft = draft
      saveState = .saved
      return true
    } catch is CancellationError {
      guard revision == editRevision else { return false }
      saveState = .pending
      return false
    } catch {
      guard revision == editRevision else { return false }
      saveState = .failed(error.localizedDescription)
      return false
    }
  }
}
