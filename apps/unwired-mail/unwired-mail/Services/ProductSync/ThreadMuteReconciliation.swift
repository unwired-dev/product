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
    var redirects = try await loadRedirects(profileId: profileId, session: session)
    var repaired = false
    for mute in current.mutes.values {
      guard let target = threadIdByMessageId[mute.anchorMessageId], target != mute.threadId else {
        continue
      }
      let resolvedTarget = resolveRedirect(
        for: target,
        redirects: redirects,
        profileId: profileId
      )
      try await setMutedUnlocked(
        true,
        threadId: resolvedTarget,
        anchorMessageId: mute.anchorMessageId,
        profileId: profileId,
        session: session,
        resolvedThreadId: resolvedTarget
      )
      let redirect = try await writeRedirect(
        formerThreadId: mute.threadId,
        targetThreadId: resolvedTarget,
        profileId: profileId,
        session: session
      )
      redirects[
        redirectIdentifier(for: mute.threadId, profileId: profileId, session: session)
      ] = redirect
      _ = try await write(
        makePayload(
          isMuted: false,
          threadId: mute.threadId,
          anchorMessageId: mute.anchorMessageId,
          profileId: profileId,
          session: session
        ),
        profileId: profileId,
        session: session
      )
      repaired = true
    }
    return repaired
      ? try await loadUnlocked(profileId: profileId, session: session)
      : current
  }
}
