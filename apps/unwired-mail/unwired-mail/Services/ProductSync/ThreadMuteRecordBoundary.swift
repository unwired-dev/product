import CryptoKit
import Foundation

extension ThreadMuteSyncService {
  func loadRecords(
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

  func loadRedirects(
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

  func write(
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

  func writeRedirect(
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

  func snapshot(
    records: [String: ThreadMuteSyncPayload],
    redirects: [String: ThreadMuteRedirectPayload],
    profileId: MailProfileId
  ) throws -> ThreadMuteSnapshot {
    let redirectTargets = redirectTargetsByFormerThreadId(
      redirects: redirects,
      profileId: profileId
    )
    var newestPayloadByTarget: [StableThreadIdentity: ThreadMuteSyncPayload] = [:]
    for payload in records.values {
      let target = resolveRedirect(
        for: payload.threadId,
        targetsByFormerThreadId: redirectTargets
      )
      if let current = newestPayloadByTarget[target], !payload.isNewer(than: current) {
        continue
      }
      newestPayloadByTarget[target] = payload
    }
    let mutes = newestPayloadByTarget.reduce(
      into: [StableThreadIdentity: ThreadMute]()
    ) { result, entry in
      let (target, payload) = entry
      guard payload.isMuted else { return }
      result[target] = ThreadMute(
        anchorMessageId: payload.mute.anchorMessageId,
        profileId: profileId,
        threadId: target
      )
    }
    return ThreadMuteSnapshot(mutes: mutes)
  }

  func merge(
    _ first: [String: ThreadMuteSyncPayload],
    _ second: [String: ThreadMuteSyncPayload]
  ) -> [String: ThreadMuteSyncPayload] {
    first.merging(second) { left, right in right.isNewer(than: left) ? right : left }
  }

  func resolveRedirect(
    for threadId: StableThreadIdentity,
    redirects: [String: ThreadMuteRedirectPayload],
    profileId: MailProfileId
  ) -> StableThreadIdentity {
    resolveRedirect(
      for: threadId,
      targetsByFormerThreadId: redirectTargetsByFormerThreadId(
        redirects: redirects,
        profileId: profileId
      )
    )
  }

  func resolveRedirect(
    for threadId: StableThreadIdentity,
    targetsByFormerThreadId: [StableThreadIdentity: StableThreadIdentity]
  ) -> StableThreadIdentity {
    var current = threadId
    var path: [StableThreadIdentity] = []
    var indexes: [StableThreadIdentity: Int] = [:]
    while let target = targetsByFormerThreadId[current] {
      if let cycleStart = indexes[current] {
        return path[cycleStart...].min { $0.rawValue < $1.rawValue } ?? current
      }
      indexes[current] = path.count
      path.append(current)
      current = target
    }
    return current
  }

  func redirectTargetsByFormerThreadId(
    redirects: [String: ThreadMuteRedirectPayload],
    profileId: MailProfileId
  ) -> [StableThreadIdentity: StableThreadIdentity] {
    var newestRedirectByFormerThreadId: [StableThreadIdentity: ThreadMuteRedirectPayload] = [:]
    for redirect in redirects.values where redirect.profileId == profileId.rawValue {
      if let current = newestRedirectByFormerThreadId[redirect.formerThreadId],
        !redirect.isNewer(than: current)
      {
        continue
      }
      newestRedirectByFormerThreadId[redirect.formerThreadId] = redirect
    }
    return newestRedirectByFormerThreadId.mapValues(\.targetThreadId)
  }

  func records(
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

  func redirectRecords(
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

  func makePayload(
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

  func validate(
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

  func validate(
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

  func payloadIdentifier(
    for threadId: StableThreadIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> String {
    recordScope(for: profileId, session: session)
      .productSyncIdentifier(Self.payloadIdentifierPrefix) + identityDigest(for: threadId)
  }

  func redirectIdentifier(
    for threadId: StableThreadIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> String {
    recordScope(for: profileId, session: session)
      .productSyncIdentifier(Self.redirectIdentifierPrefix) + identityDigest(for: threadId)
  }

  func identityDigest(for threadId: StableThreadIdentity) -> String {
    let canonicalIdentity = [
      threadId.connectionId.providerId.rawValue,
      threadId.connectionId.providerMailboxIdentity.value,
      threadId.providerThreadId,
    ].map { "\($0.utf8.count):\($0)" }.joined()
    return SHA256.hash(data: Data(canonicalIdentity.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  func recordScope(
    for profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> MailProfileRecordScope {
    profileId == .defaultProfile(productAccountId: session.productAccountId)
      ? .legacyProductAccount : .profile(profileId)
  }

  func nextChangeAtMilliseconds() -> Int64 {
    lastChangeLock.lock()
    defer { lastChangeLock.unlock() }
    lastChangeAtMilliseconds = max(nowMilliseconds(), lastChangeAtMilliseconds + 1)
    return lastChangeAtMilliseconds
  }

  func advanceChangeClock(to milliseconds: Int64) {
    lastChangeLock.lock()
    defer { lastChangeLock.unlock() }
    lastChangeAtMilliseconds = max(lastChangeAtMilliseconds, milliseconds)
  }

  func mapBoundaryError(_ error: Error) -> Error {
    guard let boundaryError = error as? ProductSyncRecordBoundaryError else { return error }
    switch boundaryError {
    case .missingProductSyncKeyMaterial:
      return ThreadMuteSyncError.missingProductSyncKeyMaterial
    case .invalidPayloadIdentifier:
      return ThreadMuteSyncError.invalidPayload
    case .incompletePagination, .retryLimitExceeded:
      return ThreadMuteSyncError.temporarilyUnavailable
    }
  }
}
