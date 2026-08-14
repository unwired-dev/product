import Foundation

protocol ThreadMuteSyncing {
  func load(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadMuteSnapshot

  func isMutedAuthoritatively(
    _ threadId: StableThreadIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool

  func reconcile(
    with messages: [MailboxMessageMetadata],
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadMuteSnapshot

  func setMuted(
    _ isMuted: Bool,
    threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws
}

enum ThreadMuteSyncError: LocalizedError, Equatable {
  case invalidPayload
  case missingProductSyncKeyMaterial
  case temporarilyUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidPayload:
      return "A synchronized Muted Thread could not be verified."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing Muted Threads."
    case .temporarilyUnavailable:
      return "Muted Threads could not synchronize. The change will retry."
    }
  }
}

struct ThreadMute: Equatable, Sendable {
  let anchorMessageId: StableProviderMessageIdentity
  let profileId: MailProfileId
  let threadId: StableThreadIdentity
}

struct ThreadMuteSnapshot: Equatable, Sendable {
  let mutes: [StableThreadIdentity: ThreadMute]

  static let empty = ThreadMuteSnapshot(mutes: [:])

  var mutedThreadIds: Set<StableThreadIdentity> {
    Set(mutes.keys)
  }
}

final class ThreadMuteSyncService: ThreadMuteSyncing {
  private static let operationLockIdentifier = "thread-mute-local-state-operation"
  private static let operationLocks = ProductSyncRecordLockRegistry()
  static let payloadIdentifierPrefix = "thread-mute-v1-"
  static let redirectIdentifierPrefix = "thread-mute-redirect-v1-"

  let lastChangeLock = NSLock()
  private let localStateStore: ThreadMuteLocalStatePersisting
  let nowMilliseconds: @Sendable () -> Int64
  let recordBoundary: ProductSyncRecordBoundary
  var lastChangeAtMilliseconds: Int64 = 0

  init(
    nowMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary(),
    localStateStore: ThreadMuteLocalStatePersisting = KeychainThreadMuteLocalStateStore()
  ) {
    self.nowMilliseconds = nowMilliseconds
    self.recordBoundary = recordBoundary
    self.localStateStore = localStateStore
  }

  func load(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadMuteSnapshot {
    try await withOperationLock(productAccountId: session.productAccountId) {
      try await self.loadUnlocked(profileId: profileId, session: session)
    }
  }

  func loadUnlocked(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadMuteSnapshot {
    let profileKey = profileId.rawValue
    var localState = try localStateStore.load(productAccountId: session.productAccountId) ?? .empty
    let cached = localState.cachedRecordsByProfile[profileKey] ?? [:]
    let pending = localState.pendingRecordsByProfile[profileKey] ?? [:]
    let remote: [String: ThreadMuteSyncPayload]
    let redirects: [String: ThreadMuteRedirectPayload]
    do {
      remote = try await loadRecords(profileId: profileId, session: session)
      redirects = try await loadRedirects(profileId: profileId, session: session)
      localState.cachedRecordsByProfile[profileKey] = remote
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ThreadMuteSyncError {
      throw error
    } catch {
      return try snapshot(
        records: merge(cached, pending),
        redirects: [:],
        profileId: profileId
      )
    }

    var merged = merge(remote, pending)
    var remainingPending = pending
    for (identifier, payload) in pending {
      do {
        let authoritative = try await write(payload, profileId: profileId, session: session)
        merged[identifier] = authoritative
        localState.cachedRecordsByProfile[profileKey, default: [:]][identifier] = authoritative
        remainingPending[identifier] = nil
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as ThreadMuteSyncError {
        throw error
      } catch {
        break
      }
    }
    localState.pendingRecordsByProfile[profileKey] = remainingPending
    try localStateStore.save(localState, productAccountId: session.productAccountId)
    return try snapshot(
      records: merged,
      redirects: redirects,
      profileId: profileId
    )
  }

  func isMutedAuthoritatively(
    _ threadId: StableThreadIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool {
    try await withOperationLock(productAccountId: session.productAccountId) {
      try await self.isMutedAuthoritativelyUnlocked(
        threadId,
        profileId: profileId,
        session: session
      )
    }
  }

  private func isMutedAuthoritativelyUnlocked(
    _ threadId: StableThreadIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool {
    let localState = try localStateStore.load(productAccountId: session.productAccountId) ?? .empty
    let profilePending = localState.pendingRecordsByProfile[profileId.rawValue] ?? [:]
    let redirects = try await loadRedirects(profileId: profileId, session: session)
    let resolved = resolveRedirect(for: threadId, redirects: redirects, profileId: profileId)
    if let pending = profilePending[
      payloadIdentifier(
        for: resolved,
        profileId: profileId,
        session: session
      )]
    {
      return pending.isMuted
    }
    let identifier = payloadIdentifier(for: resolved, profileId: profileId, session: session)
    guard
      let record = try await records(for: profileId, session: session).read(
        [identifier],
        session: session
      )[identifier]
    else { return false }
    try validate(record.value, identifier: identifier, profileId: profileId)
    advanceChangeClock(to: record.value.changedAtMilliseconds)
    return record.value.isMuted
  }

  func setMuted(
    _ isMuted: Bool,
    threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await withOperationLock(productAccountId: session.productAccountId) {
      try await self.setMutedUnlocked(
        isMuted,
        threadId: threadId,
        anchorMessageId: anchorMessageId,
        profileId: profileId,
        session: session
      )
    }
  }

  func setMutedUnlocked(
    _ isMuted: Bool,
    threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot,
    resolvedThreadId knownResolvedThreadId: StableThreadIdentity? = nil
  ) async throws {
    guard anchorMessageId.connectionId == threadId.connectionId else {
      throw ThreadMuteSyncError.invalidPayload
    }
    let resolvedThreadId: StableThreadIdentity
    if let knownResolvedThreadId {
      resolvedThreadId = knownResolvedThreadId
    } else {
      do {
        resolvedThreadId = resolveRedirect(
          for: threadId,
          redirects: try await loadRedirects(profileId: profileId, session: session),
          profileId: profileId
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as ThreadMuteSyncError {
        throw error
      } catch {
        resolvedThreadId = threadId
      }
    }
    let payload = makePayload(
      isMuted: isMuted,
      threadId: resolvedThreadId,
      anchorMessageId: anchorMessageId,
      profileId: profileId,
      session: session
    )
    let identifier = payloadIdentifier(
      for: resolvedThreadId,
      profileId: profileId,
      session: session
    )
    var localState = try localStateStore.load(productAccountId: session.productAccountId) ?? .empty
    localState.pendingRecordsByProfile[profileId.rawValue, default: [:]][identifier] = payload
    try localStateStore.save(localState, productAccountId: session.productAccountId)
    do {
      let authoritative = try await write(payload, profileId: profileId, session: session)
      localState.cachedRecordsByProfile[profileId.rawValue, default: [:]][identifier] =
        authoritative
      localState.pendingRecordsByProfile[profileId.rawValue]?[identifier] = nil
      try localStateStore.save(localState, productAccountId: session.productAccountId)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ThreadMuteSyncError {
      guard error != .temporarilyUnavailable else {
        // The local mutation remains durable and will retry on the next load.
        return
      }
      localState.pendingRecordsByProfile[profileId.rawValue]?[identifier] = nil
      try? localStateStore.save(localState, productAccountId: session.productAccountId)
      throw error
    } catch {
      // The local mutation remains durable and will retry on the next load.
    }
  }

  func reconcile(
    with messages: [MailboxMessageMetadata],
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadMuteSnapshot {
    try await withOperationLock(productAccountId: session.productAccountId) {
      try await self.reconcileUnlocked(
        with: messages,
        profileId: profileId,
        session: session
      )
    }
  }

  private func withOperationLock<T>(
    productAccountId: String,
    _ operation: () async throws -> T
  ) async throws -> T {
    let operationLock = await Self.operationLocks.lock(
      for: ProductSyncRecordKey(
        productAccountId: productAccountId,
        payloadIdentifier: Self.operationLockIdentifier
      )
    )
    try await operationLock.acquire()
    do {
      let result = try await operation()
      await operationLock.release()
      return result
    } catch {
      await operationLock.release()
      throw error
    }
  }
}
