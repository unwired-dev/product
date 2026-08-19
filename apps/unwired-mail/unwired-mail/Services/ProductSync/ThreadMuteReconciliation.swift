import Foundation

extension ThreadMuteSyncService {
  func reconcileUnlocked(
    with messages: [MailboxMessageMetadata],
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadMuteSnapshot {
    let current = try await loadUnlocked(profileId: profileId, session: session)
    let threadIdByMessageId = Dictionary(
      messages.map { ($0.id, $0.threadIdentity) },
      uniquingKeysWith: { first, _ in first }
    )
    let redirects = try await loadRedirects(profileId: profileId, session: session)
    var redirectTargets = redirectTargetsByFormerThreadId(
      redirects: redirects,
      profileId: profileId
    )
    var repaired = false
    for mute in current.mutes.values {
      guard let target = threadIdByMessageId[mute.anchorMessageId], target != mute.threadId else {
        continue
      }
      let resolvedTarget = resolveRedirect(
        for: target,
        targetsByFormerThreadId: redirectTargets
      )
      try await setMutedUnlocked(
        true,
        threadId: resolvedTarget,
        anchorMessageId: mute.anchorMessageId,
        profileId: profileId,
        session: session,
        resolvedThreadId: resolvedTarget
      )
      _ = try await writeRedirect(
        formerThreadId: mute.threadId,
        targetThreadId: resolvedTarget,
        profileId: profileId,
        session: session
      )
      redirectTargets[mute.threadId] = resolvedTarget
      repaired = true
    }
    return repaired
      ? try await loadUnlocked(profileId: profileId, session: session)
      : current
  }
}
