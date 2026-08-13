import CryptoKit
import Foundation

// swiftlint:disable file_length type_body_length

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

  var errorDescription: String? {
    switch self {
    case .invalidPayload:
      return "A synchronized Muted Thread could not be verified."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing Muted Threads."
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

struct ThreadMuteLocalState: Codable, Equatable, Sendable {
  var cachedRecordsByProfile: [String: [String: ThreadMuteSyncPayload]]
  var pendingRecordsByProfile: [String: [String: ThreadMuteSyncPayload]]

  static let empty = ThreadMuteLocalState(
    cachedRecordsByProfile: [:],
    pendingRecordsByProfile: [:]
  )
}

protocol ThreadMuteLocalStatePersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> ThreadMuteLocalState?
  func save(_ state: ThreadMuteLocalState, productAccountId: String) throws
}

struct UserDefaultsThreadMuteLocalStateStore: ThreadMuteLocalStatePersisting {
  private static let keyPrefix = "thread-mute-local-state-v1."
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(productAccountId: String) throws {
    defaults.removeObject(forKey: key(productAccountId))
  }

  func load(productAccountId: String) throws -> ThreadMuteLocalState? {
    guard let data = defaults.data(forKey: key(productAccountId)) else { return nil }
    do {
      return try JSONDecoder().decode(ThreadMuteLocalState.self, from: data)
    } catch {
      defaults.removeObject(forKey: key(productAccountId))
      return nil
    }
  }

  func save(_ state: ThreadMuteLocalState, productAccountId: String) throws {
    defaults.set(try JSONEncoder().encode(state), forKey: key(productAccountId))
  }

  private func key(_ productAccountId: String) -> String {
    Self.keyPrefix + productAccountId
  }
}

struct ThreadMuteSyncPayload: Codable, Equatable, Sendable {
  let anchorProviderMessageId: String
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let isMuted: Bool
  let profileId: String
  let provider: String
  let providerAccountIdentifier: String
  let providerThreadId: String
  let schemaVersion: Int

  var mute: ThreadMute {
    ThreadMute(
      anchorMessageId: StableProviderMessageIdentity(
        connectionId: threadId.connectionId,
        providerMessageId: anchorProviderMessageId
      ),
      profileId: MailProfileId(rawValue: profileId),
      threadId: threadId
    )
  }

  var threadId: StableThreadIdentity {
    StableThreadIdentity(
      connectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: MailProviderId(rawValue: provider),
          value: providerAccountIdentifier
        )
      ),
      providerThreadId: providerThreadId
    )
  }

  func isNewer(than other: Self) -> Bool {
    if changedAtMilliseconds != other.changedAtMilliseconds {
      return changedAtMilliseconds > other.changedAtMilliseconds
    }
    return changedByTrustedDeviceId > other.changedByTrustedDeviceId
  }
}

private struct ThreadMuteRedirectPayload: Codable, Equatable, Sendable {
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let formerProviderThreadId: String
  let profileId: String
  let provider: String
  let providerAccountIdentifier: String
  let schemaVersion: Int
  let targetProviderThreadId: String

  var formerThreadId: StableThreadIdentity {
    StableThreadIdentity(connectionId: connectionId, providerThreadId: formerProviderThreadId)
  }

  var targetThreadId: StableThreadIdentity {
    StableThreadIdentity(connectionId: connectionId, providerThreadId: targetProviderThreadId)
  }

  func isNewer(than other: Self) -> Bool {
    if changedAtMilliseconds != other.changedAtMilliseconds {
      return changedAtMilliseconds > other.changedAtMilliseconds
    }
    return changedByTrustedDeviceId > other.changedByTrustedDeviceId
  }

  private var connectionId: MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: provider),
        value: providerAccountIdentifier
      )
    )
  }
}

// swiftlint:disable:next type_body_length
final class ThreadMuteSyncService: ThreadMuteSyncing {
  static let payloadIdentifierPrefix = "thread-mute-v1-"
  static let redirectIdentifierPrefix = "thread-mute-redirect-v1-"

  private let lastChangeLock = NSLock()
  private let localStateStore: ThreadMuteLocalStatePersisting
  private let nowMilliseconds: @Sendable () -> Int64
  private let recordBoundary: ProductSyncRecordBoundary
  private var lastChangeAtMilliseconds: Int64 = 0

  init(
    nowMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary(),
    localStateStore: ThreadMuteLocalStatePersisting = UserDefaultsThreadMuteLocalStateStore()
  ) {
    self.nowMilliseconds = nowMilliseconds
    self.recordBoundary = recordBoundary
    self.localStateStore = localStateStore
  }

  func load(
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
    let localState = try localStateStore.load(productAccountId: session.productAccountId) ?? .empty
    let profilePending = localState.pendingRecordsByProfile[profileId.rawValue] ?? [:]
    if let pending = profilePending[
      payloadIdentifier(
        for: threadId,
        profileId: profileId,
        session: session
      )]
    {
      return pending.isMuted
    }
    let redirects = try await loadRedirects(profileId: profileId, session: session)
    let resolved = resolveRedirect(for: threadId, redirects: redirects, profileId: profileId)
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
    guard anchorMessageId.connectionId == threadId.connectionId else {
      throw ThreadMuteSyncError.invalidPayload
    }
    let resolvedThreadId: StableThreadIdentity
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
    var current = try await load(profileId: profileId, session: session)
    let threadIdByMessageId = Dictionary(
      messages.map { ($0.id, $0.threadIdentity) },
      uniquingKeysWith: { first, _ in first }
    )
    for mute in current.mutes.values {
      guard let target = threadIdByMessageId[mute.anchorMessageId], target != mute.threadId else {
        continue
      }
      let resolvedTarget = resolveRedirect(
        for: target,
        redirects: try await loadRedirects(profileId: profileId, session: session),
        profileId: profileId
      )
      try await setMuted(
        true,
        threadId: resolvedTarget,
        anchorMessageId: mute.anchorMessageId,
        profileId: profileId,
        session: session
      )
      _ = try await writeRedirect(
        formerThreadId: mute.threadId,
        targetThreadId: resolvedTarget,
        profileId: profileId,
        session: session
      )
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
      current = try await load(profileId: profileId, session: session)
    }
    return current
  }

  private func loadRecords(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> [String: ThreadMuteSyncPayload] {
    try await records(for: profileId, session: session).list(session: session).reduce(into: [:]) {
      let (identifier, record) = $1
      try validate(record.value, identifier: identifier, profileId: profileId)
      advanceChangeClock(to: record.value.changedAtMilliseconds)
      $0[identifier] = record.value
    }
  }

  private func loadRedirects(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> [String: ThreadMuteRedirectPayload] {
    try await redirectRecords(for: profileId, session: session).list(session: session).reduce(
      into: [:]
    ) {
      let (identifier, record) = $1
      try validate(record.value, identifier: identifier, profileId: profileId)
      advanceChangeClock(to: record.value.changedAtMilliseconds)
      $0[identifier] = record.value
    }
  }

  private func write(
    _ proposed: ThreadMuteSyncPayload,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadMuteSyncPayload {
    let identifier = payloadIdentifier(
      for: proposed.threadId,
      profileId: profileId,
      session: session
    )
    do {
      let record = try await records(for: profileId, session: session).update(
        identifier,
        session: session
      ) { currentRecord in
        guard let currentRecord else { return .write(proposed) }
        try self.validate(currentRecord.value, identifier: identifier, profileId: profileId)
        self.advanceChangeClock(to: currentRecord.value.changedAtMilliseconds)
        return proposed.isNewer(than: currentRecord.value)
          ? .write(proposed) : .acceptAuthoritative
      }
      guard let record else { throw ThreadMuteSyncError.invalidPayload }
      return record.value
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func writeRedirect(
    formerThreadId: StableThreadIdentity,
    targetThreadId: StableThreadIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadMuteRedirectPayload {
    guard formerThreadId.connectionId == targetThreadId.connectionId else {
      throw ThreadMuteSyncError.invalidPayload
    }
    let proposed = ThreadMuteRedirectPayload(
      changedAtMilliseconds: nextChangeAtMilliseconds(),
      changedByTrustedDeviceId: session.trustedDeviceId,
      formerProviderThreadId: formerThreadId.providerThreadId,
      profileId: profileId.rawValue,
      provider: formerThreadId.connectionId.providerId.rawValue,
      providerAccountIdentifier: formerThreadId.connectionId.providerMailboxIdentity.value,
      schemaVersion: 1,
      targetProviderThreadId: targetThreadId.providerThreadId
    )
    let identifier = redirectIdentifier(
      for: formerThreadId,
      profileId: profileId,
      session: session
    )
    do {
      let record = try await redirectRecords(for: profileId, session: session).update(
        identifier,
        session: session
      ) { currentRecord in
        guard let currentRecord else { return .write(proposed) }
        try self.validate(currentRecord.value, identifier: identifier, profileId: profileId)
        self.advanceChangeClock(to: currentRecord.value.changedAtMilliseconds)
        return proposed.isNewer(than: currentRecord.value)
          ? .write(proposed) : .acceptAuthoritative
      }
      guard let record else { throw ThreadMuteSyncError.invalidPayload }
      return record.value
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func snapshot(
    records: [String: ThreadMuteSyncPayload],
    redirects: [String: ThreadMuteRedirectPayload],
    profileId: MailProfileId
  ) throws -> ThreadMuteSnapshot {
    var mutes: [StableThreadIdentity: ThreadMute] = [:]
    for payload in records.values where payload.isMuted {
      let target = resolveRedirect(
        for: payload.threadId, redirects: redirects, profileId: profileId)
      let mute = ThreadMute(
        anchorMessageId: payload.mute.anchorMessageId,
        profileId: profileId,
        threadId: target
      )
      mutes[target] = mute
    }
    return ThreadMuteSnapshot(mutes: mutes)
  }

  private func merge(
    _ first: [String: ThreadMuteSyncPayload],
    _ second: [String: ThreadMuteSyncPayload]
  ) -> [String: ThreadMuteSyncPayload] {
    first.merging(second) { left, right in right.isNewer(than: left) ? right : left }
  }

  private func resolveRedirect(
    for threadId: StableThreadIdentity,
    redirects: [String: ThreadMuteRedirectPayload],
    profileId: MailProfileId
  ) -> StableThreadIdentity {
    var current = threadId
    var path: [StableThreadIdentity] = []
    var indexes: [StableThreadIdentity: Int] = [:]
    while let redirect = redirects.values.first(where: {
      $0.formerThreadId == current && $0.profileId == profileId.rawValue
    }) {
      if let cycleStart = indexes[current] {
        return path[cycleStart...].min { $0.rawValue < $1.rawValue } ?? current
      }
      indexes[current] = path.count
      path.append(current)
      current = redirect.targetThreadId
    }
    return current
  }

  private func records(
    for profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> ProductSyncRecordFamilyHandle<String, ThreadMuteSyncPayload> {
    let prefix = recordScope(for: profileId, session: session)
      .productSyncIdentifier(Self.payloadIdentifierPrefix)
    return recordBoundary.family(
      ProductSyncRecordFamilyDefinition<String, ThreadMuteSyncPayload>(
        identifier: { $0 },
        identifierPrefix: prefix,
        recordId: { $0.hasPrefix(prefix) ? $0 : nil },
        cachePolicy: .authoritative
      )
    )
  }

  private func redirectRecords(
    for profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> ProductSyncRecordFamilyHandle<String, ThreadMuteRedirectPayload> {
    let prefix = recordScope(for: profileId, session: session)
      .productSyncIdentifier(Self.redirectIdentifierPrefix)
    return recordBoundary.family(
      ProductSyncRecordFamilyDefinition<String, ThreadMuteRedirectPayload>(
        identifier: { $0 },
        identifierPrefix: prefix,
        recordId: { $0.hasPrefix(prefix) ? $0 : nil },
        cachePolicy: .authoritative
      )
    )
  }

  private func makePayload(
    isMuted: Bool,
    threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> ThreadMuteSyncPayload {
    ThreadMuteSyncPayload(
      anchorProviderMessageId: anchorMessageId.providerMessageId,
      changedAtMilliseconds: nextChangeAtMilliseconds(),
      changedByTrustedDeviceId: session.trustedDeviceId,
      isMuted: isMuted,
      profileId: profileId.rawValue,
      provider: threadId.connectionId.providerId.rawValue,
      providerAccountIdentifier: threadId.connectionId.providerMailboxIdentity.value,
      providerThreadId: threadId.providerThreadId,
      schemaVersion: 1
    )
  }

  private func validate(
    _ payload: ThreadMuteSyncPayload,
    identifier: String,
    profileId: MailProfileId
  ) throws {
    guard payload.schemaVersion == 1,
      payload.profileId == profileId.rawValue,
      !payload.anchorProviderMessageId.isEmpty,
      !payload.changedByTrustedDeviceId.isEmpty,
      identifier.hasSuffix(identityDigest(for: payload.threadId))
    else { throw ThreadMuteSyncError.invalidPayload }
  }

  private func validate(
    _ payload: ThreadMuteRedirectPayload,
    identifier: String,
    profileId: MailProfileId
  ) throws {
    guard payload.schemaVersion == 1,
      payload.profileId == profileId.rawValue,
      !payload.changedByTrustedDeviceId.isEmpty,
      payload.formerThreadId.connectionId == payload.targetThreadId.connectionId,
      identifier.hasSuffix(identityDigest(for: payload.formerThreadId))
    else { throw ThreadMuteSyncError.invalidPayload }
  }

  private func payloadIdentifier(
    for threadId: StableThreadIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> String {
    recordScope(for: profileId, session: session)
      .productSyncIdentifier(Self.payloadIdentifierPrefix) + identityDigest(for: threadId)
  }

  private func redirectIdentifier(
    for threadId: StableThreadIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> String {
    recordScope(for: profileId, session: session)
      .productSyncIdentifier(Self.redirectIdentifierPrefix) + identityDigest(for: threadId)
  }

  private func identityDigest(for threadId: StableThreadIdentity) -> String {
    let canonicalIdentity = [
      threadId.connectionId.providerId.rawValue,
      threadId.connectionId.providerMailboxIdentity.value,
      threadId.providerThreadId,
    ].map { "\($0.utf8.count):\($0)" }.joined()
    return SHA256.hash(data: Data(canonicalIdentity.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private func recordScope(
    for profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> MailProfileRecordScope {
    profileId == .defaultProfile(productAccountId: session.productAccountId)
      ? .legacyProductAccount : .profile(profileId)
  }

  private func nextChangeAtMilliseconds() -> Int64 {
    lastChangeLock.lock()
    defer { lastChangeLock.unlock() }
    lastChangeAtMilliseconds = max(nowMilliseconds(), lastChangeAtMilliseconds + 1)
    return lastChangeAtMilliseconds
  }

  private func advanceChangeClock(to milliseconds: Int64) {
    lastChangeLock.lock()
    defer { lastChangeLock.unlock() }
    lastChangeAtMilliseconds = max(lastChangeAtMilliseconds, milliseconds)
  }

  private func mapBoundaryError(_ error: Error) -> Error {
    guard let boundaryError = error as? ProductSyncRecordBoundaryError else { return error }
    switch boundaryError {
    case .missingProductSyncKeyMaterial:
      return ThreadMuteSyncError.missingProductSyncKeyMaterial
    case .incompletePagination, .invalidPayloadIdentifier, .retryLimitExceeded:
      return ThreadMuteSyncError.invalidPayload
    }
  }
}
