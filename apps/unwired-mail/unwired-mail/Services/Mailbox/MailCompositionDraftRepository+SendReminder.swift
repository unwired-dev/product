import Foundation

extension MailCompositionDraftRepository {
  func save(
    _ draft: MailShellCompositionDraft,
    productAccountId: String,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot? = nil
  ) async throws {
    let previousReminder: SendReminder?
    if session == nil {
      previousReminder = nil
    } else {
      previousReminder = try store.load(
        productAccountId: productAccountId,
        profileId: profileId
      ).first { $0.id == draft.id }?.sendReminder
    }
    try store.save(draft, productAccountId: productAccountId, profileId: profileId)
    guard let session else { return }

    do {
      let synchronization = try await synchronizedDraft(
        draft,
        previousReminder: previousReminder,
        profileId: profileId,
        session: session
      )
      let synchronizedDraft = synchronization.draft
      if synchronization.isConflict {
        try store.save(
          synchronizedDraft,
          productAccountId: productAccountId,
          profileId: profileId
        )
        throw SendReminderSyncError.concurrentModification
      }
      try await syncService.save(synchronizedDraft, profileId: profileId, session: session)
      try store.save(
        synchronizedDraft,
        productAccountId: productAccountId,
        profileId: profileId
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch SendReminderSyncError.concurrentModification {
      throw SendReminderSyncError.concurrentModification
    } catch {
      // The local Draft remains authoritative and visibly pending until a later reconciliation.
    }
  }

  func reconcileSendReminders(
    in drafts: [MailShellCompositionDraft],
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot,
    claimsNotificationOwnership: Bool
  ) async -> [MailShellCompositionDraft] {
    let snapshot: SendReminderSyncSnapshot
    do {
      snapshot = try await reminderSyncService.load(profileId: profileId, session: session)
    } catch {
      return drafts
    }

    var result: [MailShellCompositionDraft] = []
    for draft in drafts {
      do {
        result.append(
          try await reconciledDraft(
            draft,
            snapshot: snapshot,
            profileId: profileId,
            session: session,
            claimsNotificationOwnership: claimsNotificationOwnership
          )
        )
      } catch is CancellationError {
        return drafts
      } catch {
        result.append(draft)
      }
    }
    return result
  }

  private func synchronizedDraft(
    _ draft: MailShellCompositionDraft,
    previousReminder: SendReminder?,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> (draft: MailShellCompositionDraft, isConflict: Bool) {
    var synchronizedDraft = draft
    if let reminder = draft.sendReminder {
      let mutation = try await reminderSyncService.synchronize(
        reminder,
        draftId: draft.id,
        draftUpdatedAtMilliseconds: draft.updatedAtMilliseconds,
        profileId: profileId,
        session: session
      )
      let resolution = authoritativeReminder(
        from: mutation,
        proposedRevision: reminder.revision
      )
      synchronizedDraft.sendReminder = resolution.reminder
      return (synchronizedDraft, resolution.isConflict)
    } else if let previousReminder {
      let mutation = try await reminderSyncService.cancel(
        draftId: draft.id,
        expectedRevision: previousReminder.revision,
        profileId: profileId,
        session: session
      )
      let resolution = authoritativeReminder(
        from: mutation,
        proposedRevision: nil
      )
      synchronizedDraft.sendReminder = resolution.reminder
      return (synchronizedDraft, resolution.isConflict)
    }
    return (synchronizedDraft, false)
  }

  private func authoritativeReminder(
    from mutation: SendReminderSyncMutation,
    proposedRevision: UUID?
  ) -> (reminder: SendReminder?, isConflict: Bool) {
    switch mutation {
    case .accepted(let reminder):
      return (reminder?.synchronized(), false)
    case .authoritative(let reminder) where reminder?.revision == proposedRevision:
      return (reminder?.synchronized(), false)
    case .authoritative(let reminder):
      return (reminder?.synchronized(), true)
    }
  }

  private func reconciledDraft(
    _ draft: MailShellCompositionDraft,
    snapshot: SendReminderSyncSnapshot,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot,
    claimsNotificationOwnership: Bool
  ) async throws -> MailShellCompositionDraft {
    var result = try await reminderProjection(
      for: draft,
      snapshot: snapshot,
      profileId: profileId,
      session: session
    )
    if claimsNotificationOwnership, let reminder = result.sendReminder {
      result.sendReminder =
        try await reminderSyncService.claimNotificationOwnership(
          draftId: result.id,
          expectedRevision: reminder.revision,
          profileId: profileId,
          session: session
        ) ?? reminder
    }
    guard result.sendReminder != draft.sendReminder else { return result }
    return try await persistReminderProjection(
      result,
      fallback: draft,
      productAccountId: session.productAccountId,
      profileId: profileId,
      session: session
    )
  }

  private func reminderProjection(
    for draft: MailShellCompositionDraft,
    snapshot: SendReminderSyncSnapshot,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailShellCompositionDraft {
    var result = draft
    if snapshot.removedDraftIds.contains(draft.id) {
      result.sendReminder = nil
    } else if let authoritative = snapshot.remindersByDraftId[draft.id] {
      result.sendReminder = authoritative.synchronized()
    } else if let localReminder = draft.sendReminder {
      let mutation = try await reminderSyncService.synchronize(
        localReminder,
        draftId: draft.id,
        draftUpdatedAtMilliseconds: draft.updatedAtMilliseconds,
        profileId: profileId,
        session: session
      )
      switch mutation {
      case .accepted(let reminder), .authoritative(let reminder):
        result.sendReminder = reminder
      }
    }
    return result
  }

  private func persistReminderProjection(
    _ draft: MailShellCompositionDraft,
    fallback: MailShellCompositionDraft,
    productAccountId: String,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailShellCompositionDraft {
    var result = draft
    do {
      var synchronizedProjection = result
      synchronizedProjection.sendReminder = result.sendReminder?.synchronized()
      try await syncService.save(synchronizedProjection, profileId: profileId, session: session)
      result = synchronizedProjection
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      result.sendReminder?.isSynchronizationPending = true
    }
    do {
      try store.save(result, productAccountId: productAccountId, profileId: profileId)
      return result
    } catch {
      return fallback
    }
  }
}
