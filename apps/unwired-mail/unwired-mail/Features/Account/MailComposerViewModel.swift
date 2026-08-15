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

@MainActor
@Observable
final class MailComposerViewModel {
  typealias DeleteDraft = @MainActor (UUID) async throws -> Void
  typealias SaveDraft = @MainActor (MailShellCompositionDraft) async throws -> Void
  typealias SendDraft = @MainActor (MailShellCompositionDraft) async -> Bool

  var draft: MailShellCompositionDraft
  var presentation: ComposePresentationPreference
  private(set) var saveState: MailComposerSaveState = .idle

  private let deleteDraft: DeleteDraft
  private var editRevision = 0
  private var hasConfirmedMissingSubject = false
  private var lastSavedDraft: MailShellCompositionDraft?
  private let saveDraft: SaveDraft
  private let sendDraft: SendDraft
  private var autosaveTask: Task<Void, Never>?

  init(
    draft: MailShellCompositionDraft,
    presentation: ComposePresentationPreference,
    saveDraft: @escaping SaveDraft = { _ in },
    deleteDraft: @escaping DeleteDraft = { _ in },
    sendDraft: @escaping SendDraft
  ) {
    self.deleteDraft = deleteDraft
    self.draft = draft
    self.presentation = presentation
    self.saveDraft = saveDraft
    self.sendDraft = sendDraft
  }

  var canSend: Bool {
    draft.connectionId != nil && draft.recipientsAreValid && !saveState.blocksDismissal
  }

  var hasUnsavedChanges: Bool {
    lastSavedDraft != draft
  }

  func draftChanged() {
    editRevision += 1
    hasConfirmedMissingSubject = false
    saveState = .pending
    autosaveTask?.cancel()
    let revision = editRevision
    autosaveTask = Task {
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
    await flushAutosave()
  }

  func discard() async -> Bool {
    autosaveTask?.cancel()
    do {
      try await deleteDraft(draft.id)
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
    autosaveTask?.cancel()
    autosaveTask = Task {
      _ = await persistCurrentDraft(revision: revision)
    }
  }

  func send() async -> MailComposerSendResult {
    guard draft.connectionId != nil, draft.recipientsAreValid else { return .notSent }
    if draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !hasConfirmedMissingSubject
    {
      return .needsSubjectConfirmation
    }
    guard await flushAutosave() else { return .notSent }
    guard await sendDraft(draft) else { return .notSent }
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

  func togglePresentation() {
    presentation = presentation == .partial ? .fullScreen : .partial
  }

  private func flushAutosave() async -> Bool {
    autosaveTask?.cancel()
    editRevision += 1
    return await persistCurrentDraft(revision: editRevision)
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
