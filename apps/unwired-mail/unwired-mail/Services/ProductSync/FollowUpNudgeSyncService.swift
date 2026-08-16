import CryptoKit
import Foundation
import Observation
import Security

// swiftlint:disable file_length

enum FollowUpNudgeCreationSource: String, Codable, Equatable, Sendable {
  case scheduled
  case suggestionAccepted
}

enum FollowUpNudgeSyncError: LocalizedError, Equatable {
  case concurrentModification
  case ineligibleThread
  case invalidDueTime
  case invalidPayload
  case missingProductSyncKeyMaterial

  var errorDescription: String? {
    switch self {
    case .concurrentModification:
      return "Follow-Up Nudge changed on another device. Refresh and try again."
    case .ineligibleThread:
      return "Choose a Thread whose latest message was sent from an authorized identity."
    case .invalidDueTime:
      return "Choose a future time for the Follow-Up Nudge."
    case .invalidPayload:
      return "A synchronized Follow-Up Nudge could not be verified."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing a Follow-Up Nudge."
    }
  }
}

struct FollowUpNudgeInterruptionPolicy: Equatable, Sendable {
  let allowsLockScreenContent: Bool
  let isOSAuthorized: Bool
  let isProfileLocked: Bool
  let isQuiet: Bool
  let returnToAttentionEnabled: Bool
  let trustedDeviceId: String

  func decision(
    for nudge: FollowUpNudge,
    subject: String
  ) -> ThreadSnoozeInterruptionDecision {
    guard returnToAttentionEnabled,
      isOSAuthorized,
      !isProfileLocked,
      !isQuiet,
      nudge.notificationOwnerDeviceId == trustedDeviceId
    else { return .suppress }
    return allowsLockScreenContent ? .revealing(subject) : .generic
  }
}

protocol FollowUpNudgeAttentionDelivering {
  func deliverFollowUpNudgeAttention(
    decision: ThreadSnoozeInterruptionDecision,
    nudge: FollowUpNudge,
    productAccountId: String
  ) async throws
}

protocol FollowUpNudgeSyncing {
  func load(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> FollowUpNudgeSnapshot

  // swiftlint:disable:next function_parameter_count
  func schedule(
    thread: MailboxThread,
    dueAtMilliseconds: Int64,
    authorizedSendingAddresses: Set<String>,
    source: FollowUpNudgeCreationSource,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws

  func cancel(
    threadId: StableThreadIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws

  func reconcile(
    with messages: [MailboxMessageMetadata],
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> FollowUpNudgeSnapshot
}

struct FollowUpNudge: Equatable, Sendable {
  let anchorMessageId: StableProviderMessageIdentity
  let anchorSentAtMilliseconds: Int64
  let authorizedSendingAddresses: Set<String>
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let dueAtMilliseconds: Int64
  let notificationOwnerDeviceId: String
  let observedMessageIds: Set<StableProviderMessageIdentity>
  let profileId: MailProfileId
  let source: FollowUpNudgeCreationSource
  let threadId: StableThreadIdentity
}

struct FollowUpNudgeSnapshot: Equatable, Sendable {
  let nudges: [StableThreadIdentity: FollowUpNudge]

  func overdueThreadIds(atMilliseconds nowMilliseconds: Int64) -> Set<StableThreadIdentity> {
    Set(
      nudges.values.compactMap {
        $0.dueAtMilliseconds <= nowMilliseconds ? $0.threadId : nil
      }
    )
  }
}

enum FollowUpNudgeEligibility {
  static func anchor(
    in thread: MailboxThread,
    authorizedSendingAddresses: Set<String>
  ) -> MailboxMessageMetadata? {
    let normalizedAddresses = normalizedAddresses(authorizedSendingAddresses)
    guard
      !normalizedAddresses.isEmpty,
      thread.latestMessage.belongs(to: .sent),
      let sender = normalizedAddress(thread.latestMessage.from),
      normalizedAddresses.contains(sender)
    else { return nil }
    return thread.latestMessage
  }

  static func hasQualifyingReply(
    in messages: [MailboxMessageMetadata],
    to nudge: FollowUpNudge
  ) -> Bool {
    messages.contains { message in
      guard
        message.id != nudge.anchorMessageId,
        !nudge.observedMessageIds.contains(message.id),
        message.providerInternalDateMilliseconds >= nudge.anchorSentAtMilliseconds,
        !message.belongs(to: .sent)
      else { return false }
      guard let sender = normalizedAddress(message.from) else { return false }
      return !nudge.authorizedSendingAddresses.contains(sender)
    }
  }

  static func normalizedAddresses(_ values: Set<String>) -> Set<String> {
    Set(values.compactMap(normalizedAddress))
  }

  static func normalizedAddress(_ value: String?) -> String? {
    guard var value else { return nil }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let opening = value.lastIndex(of: "<"),
      let closing = value.lastIndex(of: ">"),
      opening < closing
    {
      value = String(value[value.index(after: opening)..<closing])
    }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.hasPrefix("mailto:") { value.removeFirst("mailto:".count) }
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    guard
      parts.count == 2,
      !parts[0].isEmpty,
      !parts[1].isEmpty,
      !value.contains(where: { $0.isWhitespace || "<>,;()".contains($0) })
    else { return nil }
    return value
  }
}

private struct FollowUpNudgeSyncPayload: Codable, Equatable, Sendable {
  let anchorProviderMessageId: String
  let anchorSentAtMilliseconds: Int64
  let authorizedSendingAddresses: [String]
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let dueAtMilliseconds: Int64
  let isActive: Bool
  let notificationOwnerDeviceId: String
  let observedProviderMessageIds: [String]
  let profileId: String
  let provider: String
  let providerAccountIdentifier: String
  let providerThreadId: String
  let schemaVersion: Int
  let source: FollowUpNudgeCreationSource

  var nudge: FollowUpNudge {
    FollowUpNudge(
      anchorMessageId: StableProviderMessageIdentity(
        connectionId: threadId.connectionId,
        providerMessageId: anchorProviderMessageId
      ),
      anchorSentAtMilliseconds: anchorSentAtMilliseconds,
      authorizedSendingAddresses: Set(authorizedSendingAddresses),
      changedAtMilliseconds: changedAtMilliseconds,
      changedByTrustedDeviceId: changedByTrustedDeviceId,
      dueAtMilliseconds: dueAtMilliseconds,
      notificationOwnerDeviceId: notificationOwnerDeviceId,
      observedMessageIds: Set(
        observedProviderMessageIds.map {
          StableProviderMessageIdentity(
            connectionId: threadId.connectionId,
            providerMessageId: $0
          )
        }
      ),
      profileId: MailProfileId(rawValue: profileId),
      source: source,
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

struct KeychainFollowUpNudgeSyncCiphertextCache: ProductSyncCiphertextCaching {
  private let service = "dev.unwired.mail.follow-up-nudge-sync-cache"

  func clear(productAccountId: String) throws {
    try KeychainStore.delete(service: service, account: productAccountId)
  }

  func loadFamily(
    productAccountId: String,
    payloadIdentifierPrefix: String
  ) async throws -> [EncryptedProductSyncPayload]? {
    let payloads = try loadPayloads(productAccountId: productAccountId).values.filter {
      $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix)
    }
    guard !payloads.isEmpty else { return nil }
    return payloads.sorted { $0.payloadIdentifier < $1.payloadIdentifier }
  }

  func load(
    productAccountId: String,
    payloadIdentifier: String
  ) async throws -> EncryptedProductSyncPayload? {
    try loadPayloads(productAccountId: productAccountId)[payloadIdentifier]
  }

  func remove(productAccountId: String, payloadIdentifier: String) async throws {
    var payloads = try loadPayloads(productAccountId: productAccountId)
    payloads[payloadIdentifier] = nil
    try savePayloads(payloads, productAccountId: productAccountId)
  }

  func removeIfUnchanged(
    _ payload: EncryptedProductSyncPayload?,
    productAccountId: String,
    payloadIdentifier: String
  ) async throws {
    var payloads = try loadPayloads(productAccountId: productAccountId)
    guard payloads[payloadIdentifier] == payload else { return }
    payloads[payloadIdentifier] = nil
    try savePayloads(payloads, productAccountId: productAccountId)
  }

  func replaceFamily(
    _ replacement: [EncryptedProductSyncPayload],
    productAccountId: String,
    payloadIdentifierPrefix: String
  ) async throws {
    var payloads = try loadPayloads(productAccountId: productAccountId)
    payloads = payloads.filter { !$0.key.hasPrefix(payloadIdentifierPrefix) }
    for payload in replacement {
      guard payload.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) else {
        throw ProductSyncRecordBoundaryError.invalidPayloadIdentifier
      }
      payloads[payload.payloadIdentifier] = payload
    }
    try savePayloads(payloads, productAccountId: productAccountId)
  }

  func save(
    _ payload: EncryptedProductSyncPayload,
    productAccountId: String
  ) async throws {
    var payloads = try loadPayloads(productAccountId: productAccountId)
    if let existing = payloads[payload.payloadIdentifier], existing.updatedAt > payload.updatedAt {
      return
    }
    payloads[payload.payloadIdentifier] = payload
    try savePayloads(payloads, productAccountId: productAccountId)
  }

  private func loadPayloads(
    productAccountId: String
  ) throws -> [String: EncryptedProductSyncPayload] {
    guard
      let rawValue = try KeychainStore.readString(service: service, account: productAccountId),
      let data = rawValue.data(using: .utf8)
    else { return [:] }
    return try JSONDecoder().decode([String: EncryptedProductSyncPayload].self, from: data)
  }

  private func savePayloads(
    _ payloads: [String: EncryptedProductSyncPayload],
    productAccountId: String
  ) throws {
    guard !payloads.isEmpty else {
      try KeychainStore.delete(service: service, account: productAccountId)
      return
    }
    let data = try JSONEncoder().encode(payloads)
    guard let rawValue = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(
      rawValue,
      service: service,
      account: productAccountId,
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }
}

// swiftlint:disable:next type_body_length
final class FollowUpNudgeSyncService: FollowUpNudgeSyncing {
  static let payloadIdentifierPrefix = "follow-up-nudge-v1-"

  private let lastChangeLock = NSLock()
  private var lastChangeAtMilliseconds: Int64 = 0
  private let nowMilliseconds: @Sendable () -> Int64
  private let recordBoundary: ProductSyncRecordBoundary

  init(
    nowMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary(),
    ciphertextCache: ProductSyncCiphertextCaching = KeychainFollowUpNudgeSyncCiphertextCache()
  ) {
    self.nowMilliseconds = nowMilliseconds
    self.recordBoundary = recordBoundary.caching(ciphertextCache)
  }

  func load(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> FollowUpNudgeSnapshot {
    do {
      let listed = try await records(for: profileId, session: session).list(session: session)
      let nudges = try listed.reduce(into: [StableThreadIdentity: FollowUpNudge]()) {
        let (identifier, record) = $1
        try validate(record.value, identifier: identifier, profileId: profileId)
        advanceChangeClock(to: record.value.changedAtMilliseconds)
        if record.value.isActive { $0[record.value.threadId] = record.value.nudge }
      }
      return FollowUpNudgeSnapshot(nudges: nudges)
    } catch {
      throw mapBoundaryError(error)
    }
  }

  // swiftlint:disable:next function_parameter_count
  func schedule(
    thread: MailboxThread,
    dueAtMilliseconds: Int64,
    authorizedSendingAddresses: Set<String>,
    source: FollowUpNudgeCreationSource,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws {
    guard dueAtMilliseconds > nowMilliseconds() else {
      throw FollowUpNudgeSyncError.invalidDueTime
    }
    let addresses = FollowUpNudgeEligibility.normalizedAddresses(authorizedSendingAddresses)
    guard
      let anchor = FollowUpNudgeEligibility.anchor(
        in: thread,
        authorizedSendingAddresses: addresses
      )
    else { throw FollowUpNudgeSyncError.ineligibleThread }
    let proposed = makePayload(
      thread: thread,
      anchor: anchor,
      dueAtMilliseconds: dueAtMilliseconds,
      authorizedSendingAddresses: addresses,
      source: source,
      profileId: profileId,
      session: session
    )
    let identifier = payloadIdentifier(for: thread.id, profileId: profileId, session: session)
    do {
      _ = try await records(for: profileId, session: session).update(
        identifier,
        session: session
      ) { currentRecord in
        guard let currentRecord else { return .write(proposed) }
        try self.validate(currentRecord.value, identifier: identifier, profileId: profileId)
        self.advanceChangeClock(to: currentRecord.value.changedAtMilliseconds)
        guard proposed.isNewer(than: currentRecord.value) else {
          if currentRecord.value != proposed {
            throw FollowUpNudgeSyncError.concurrentModification
          }
          return .acceptAuthoritative
        }
        return .write(proposed)
      }
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func cancel(
    threadId: StableThreadIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws {
    _ = try await cancel(
      threadId: threadId,
      expectedChangedAtMilliseconds: nil,
      profileId: profileId,
      session: session
    )
  }

  func reconcile(
    with messages: [MailboxMessageMetadata],
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> FollowUpNudgeSnapshot {
    var snapshot = try await load(profileId: profileId, session: session)
    let messagesByThread = Dictionary(
      uniqueKeysWithValues: MailboxThread.group(messages).map { ($0.id, $0.messages) }
    )
    let threadIdByMessageId = Dictionary(
      uniqueKeysWithValues: messages.map { ($0.id, $0.threadIdentity) })
    for nudge in snapshot.nudges.values {
      var reconciledNudge = nudge
      if let currentThreadId = threadIdByMessageId[nudge.anchorMessageId],
        currentThreadId != nudge.threadId
      {
        guard
          let migrated = try await migrate(
            nudge,
            to: currentThreadId,
            profileId: profileId,
            session: session
          )
        else {
          snapshot = FollowUpNudgeSnapshot(
            nudges: snapshot.nudges.filter {
              $0.key != nudge.threadId && $0.key != currentThreadId
            }
          )
          continue
        }
        reconciledNudge = migrated
        snapshot = FollowUpNudgeSnapshot(
          nudges: snapshot.nudges.merging([currentThreadId: migrated]) { _, migrated in migrated }
            .filter { $0.key != nudge.threadId }
        )
      }
      guard let threadMessages = messagesByThread[reconciledNudge.threadId],
        FollowUpNudgeEligibility.hasQualifyingReply(
          in: threadMessages,
          to: reconciledNudge
        )
      else { continue }
      let authoritativeNudge = try await cancel(
        threadId: reconciledNudge.threadId,
        expectedChangedAtMilliseconds: reconciledNudge.changedAtMilliseconds,
        profileId: profileId,
        session: session
      )
      var nudges = snapshot.nudges
      nudges[reconciledNudge.threadId] = authoritativeNudge
      snapshot = FollowUpNudgeSnapshot(nudges: nudges)
    }
    return snapshot
  }

  private func cancel(
    threadId: StableThreadIdentity,
    expectedChangedAtMilliseconds: Int64?,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> FollowUpNudge? {
    let identifier = payloadIdentifier(for: threadId, profileId: profileId, session: session)
    do {
      let record = try await records(for: profileId, session: session).update(
        identifier,
        session: session
      ) { currentRecord in
        guard let currentRecord else { return .acceptAuthoritative }
        let current = currentRecord.value
        try self.validate(current, identifier: identifier, profileId: profileId)
        self.advanceChangeClock(to: current.changedAtMilliseconds)
        guard current.isActive else { return .acceptAuthoritative }
        if let expectedChangedAtMilliseconds,
          expectedChangedAtMilliseconds != current.changedAtMilliseconds
        {
          return .acceptAuthoritative
        }
        return .write(self.tombstone(from: current, session: session))
      }
      guard let record else { return nil }
      try validate(record.value, identifier: identifier, profileId: profileId)
      advanceChangeClock(to: record.value.changedAtMilliseconds)
      return record.value.isActive ? record.value.nudge : nil
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func migrate(
    _ nudge: FollowUpNudge,
    to threadId: StableThreadIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot,
    retryCount: Int = 0
  ) async throws -> FollowUpNudge? {
    let migratedPayload = payload(from: nudge, threadId: threadId)
    let identifier = payloadIdentifier(for: threadId, profileId: profileId, session: session)
    do {
      let record = try await records(for: profileId, session: session).update(
        identifier,
        session: session
      ) { currentRecord in
        if let currentRecord {
          try self.validate(currentRecord.value, identifier: identifier, profileId: profileId)
          self.advanceChangeClock(to: currentRecord.value.changedAtMilliseconds)
          guard migratedPayload.isNewer(than: currentRecord.value) else {
            return .acceptAuthoritative
          }
        }
        return .write(migratedPayload)
      }
      guard let record else { throw FollowUpNudgeSyncError.invalidPayload }
      if let newerSource = try await cancel(
        threadId: nudge.threadId,
        expectedChangedAtMilliseconds: nudge.changedAtMilliseconds,
        profileId: profileId,
        session: session
      ) {
        guard retryCount < 3 else { throw FollowUpNudgeSyncError.concurrentModification }
        return try await migrate(
          newerSource,
          to: threadId,
          profileId: profileId,
          session: session,
          retryCount: retryCount + 1
        )
      }
      return record.value.isActive ? record.value.nudge : nil
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func records(
    for profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> ProductSyncRecordFamilyHandle<String, FollowUpNudgeSyncPayload> {
    let prefix = identifierPrefix(for: profileId, session: session)
    return recordBoundary.family(
      ProductSyncRecordFamilyDefinition<String, FollowUpNudgeSyncPayload>(
        identifier: { $0 },
        identifierPrefix: prefix,
        recordId: { $0.hasPrefix(prefix) ? $0 : nil },
        cachePolicy: .authoritativeWithCiphertextFallback
      )
    )
  }

  // swiftlint:disable:next function_parameter_count
  private func makePayload(
    thread: MailboxThread,
    anchor: MailboxMessageMetadata,
    dueAtMilliseconds: Int64,
    authorizedSendingAddresses: Set<String>,
    source: FollowUpNudgeCreationSource,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> FollowUpNudgeSyncPayload {
    FollowUpNudgeSyncPayload(
      anchorProviderMessageId: anchor.providerMessageId,
      anchorSentAtMilliseconds: anchor.providerInternalDateMilliseconds,
      authorizedSendingAddresses: authorizedSendingAddresses.sorted(),
      changedAtMilliseconds: nextChangeAtMilliseconds(),
      changedByTrustedDeviceId: session.trustedDeviceId,
      dueAtMilliseconds: dueAtMilliseconds,
      isActive: true,
      notificationOwnerDeviceId: session.trustedDeviceId,
      observedProviderMessageIds: thread.messages.map(\.providerMessageId).sorted(),
      profileId: profileId.rawValue,
      provider: thread.id.connectionId.providerId.rawValue,
      providerAccountIdentifier: thread.id.connectionId.providerMailboxIdentity.value,
      providerThreadId: thread.id.providerThreadId,
      schemaVersion: 1,
      source: source
    )
  }

  private func payload(
    from nudge: FollowUpNudge,
    threadId: StableThreadIdentity
  ) -> FollowUpNudgeSyncPayload {
    FollowUpNudgeSyncPayload(
      anchorProviderMessageId: nudge.anchorMessageId.providerMessageId,
      anchorSentAtMilliseconds: nudge.anchorSentAtMilliseconds,
      authorizedSendingAddresses: nudge.authorizedSendingAddresses.sorted(),
      changedAtMilliseconds: nudge.changedAtMilliseconds,
      changedByTrustedDeviceId: nudge.changedByTrustedDeviceId,
      dueAtMilliseconds: nudge.dueAtMilliseconds,
      isActive: true,
      notificationOwnerDeviceId: nudge.notificationOwnerDeviceId,
      observedProviderMessageIds: nudge.observedMessageIds.map(\.providerMessageId).sorted(),
      profileId: nudge.profileId.rawValue,
      provider: threadId.connectionId.providerId.rawValue,
      providerAccountIdentifier: threadId.connectionId.providerMailboxIdentity.value,
      providerThreadId: threadId.providerThreadId,
      schemaVersion: 1,
      source: nudge.source
    )
  }

  private func tombstone(
    from payload: FollowUpNudgeSyncPayload,
    session: ProductAccountSessionSnapshot
  ) -> FollowUpNudgeSyncPayload {
    FollowUpNudgeSyncPayload(
      anchorProviderMessageId: payload.anchorProviderMessageId,
      anchorSentAtMilliseconds: payload.anchorSentAtMilliseconds,
      authorizedSendingAddresses: payload.authorizedSendingAddresses,
      changedAtMilliseconds: nextChangeAtMilliseconds(),
      changedByTrustedDeviceId: session.trustedDeviceId,
      dueAtMilliseconds: payload.dueAtMilliseconds,
      isActive: false,
      notificationOwnerDeviceId: payload.notificationOwnerDeviceId,
      observedProviderMessageIds: payload.observedProviderMessageIds,
      profileId: payload.profileId,
      provider: payload.provider,
      providerAccountIdentifier: payload.providerAccountIdentifier,
      providerThreadId: payload.providerThreadId,
      schemaVersion: payload.schemaVersion,
      source: payload.source
    )
  }

  private func validate(
    _ payload: FollowUpNudgeSyncPayload,
    identifier: String,
    profileId: MailProfileId
  ) throws {
    let addresses = FollowUpNudgeEligibility.normalizedAddresses(
      Set(payload.authorizedSendingAddresses)
    )
    guard payload.schemaVersion == 1,
      payload.profileId == profileId.rawValue,
      !payload.anchorProviderMessageId.isEmpty,
      payload.anchorSentAtMilliseconds >= 0,
      addresses.count == payload.authorizedSendingAddresses.count,
      addresses == Set(payload.authorizedSendingAddresses),
      !payload.changedByTrustedDeviceId.isEmpty,
      payload.dueAtMilliseconds > 0,
      !payload.notificationOwnerDeviceId.isEmpty,
      payload.observedProviderMessageIds.contains(payload.anchorProviderMessageId),
      !payload.observedProviderMessageIds.contains(where: \.isEmpty),
      identifier.hasSuffix(payloadIdentifierSuffix(for: payload.threadId))
    else { throw FollowUpNudgeSyncError.invalidPayload }
  }

  private func nextChangeAtMilliseconds() -> Int64 {
    lastChangeLock.lock()
    defer { lastChangeLock.unlock() }
    lastChangeAtMilliseconds = max(nowMilliseconds(), lastChangeAtMilliseconds + 1)
    return lastChangeAtMilliseconds
  }

  private func advanceChangeClock(to changedAtMilliseconds: Int64) {
    lastChangeLock.lock()
    defer { lastChangeLock.unlock() }
    lastChangeAtMilliseconds = max(lastChangeAtMilliseconds, changedAtMilliseconds)
  }

  private func identifierPrefix(
    for profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> String {
    recordScope(for: profileId, session: session)
      .productSyncIdentifier(Self.payloadIdentifierPrefix)
  }

  private func payloadIdentifier(
    for threadId: StableThreadIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> String {
    identifierPrefix(for: profileId, session: session) + payloadIdentifierSuffix(for: threadId)
  }

  private func payloadIdentifierSuffix(for threadId: StableThreadIdentity) -> String {
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

  private func mapBoundaryError(_ error: Error) -> Error {
    guard let boundaryError = error as? ProductSyncRecordBoundaryError else { return error }
    switch boundaryError {
    case .missingProductSyncKeyMaterial:
      return FollowUpNudgeSyncError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      return FollowUpNudgeSyncError.concurrentModification
    case .incompletePagination, .invalidPayloadIdentifier:
      return FollowUpNudgeSyncError.invalidPayload
    }
  }
}

enum FollowUpNudgePreset: String, CaseIterable, Identifiable {
  case tomorrowMorning
  case nextWeek
  case twoWeeks

  var id: Self { self }

  var title: String {
    switch self {
    case .tomorrowMorning:
      return "Tomorrow Morning"
    case .nextWeek:
      return "Next Week"
    case .twoWeeks:
      return "In Two Weeks"
    }
  }

  func dueDate(after now: Date = .now, calendar: Calendar = .current) throws -> Date {
    let days =
      switch self {
      case .tomorrowMorning: 1
      case .nextWeek: 7
      case .twoWeeks: 14
      }
    guard let targetDay = calendar.date(byAdding: .day, value: days, to: now) else {
      throw FollowUpNudgeSyncError.invalidDueTime
    }
    let day = calendar.dateComponents([.year, .month, .day], from: targetDay)
    return try ThreadSnoozeDueDateResolver.resolve(
      localComponents: DateComponents(
        year: day.year,
        month: day.month,
        day: day.day,
        hour: 9,
        minute: 0
      ),
      timeZone: calendar.timeZone,
      repeatedTimePolicy: .first
    )
  }
}

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class FollowUpNudgeViewModel {
  typealias PreferenceLoader =
    @Sendable (
      MailProfileId,
      ProductAccountSessionSnapshot
    ) async throws -> ThreadSnoozePreferences

  var errorMessage: String?
  private(set) var nudgeThreadIds: Set<StableThreadIdentity> = []
  private(set) var overdueThreadIds: Set<StableThreadIdentity> = []
  private(set) var suggestedThreadIds: Set<StableThreadIdentity> = []

  private let attentionDelivery: FollowUpNudgeAttentionDelivering
  private let notificationAuthorization: NotificationAuthorizationStateChecking
  private let notificationPreferenceStore: NotificationDevicePreferencePersisting
  private let preferenceLoader: PreferenceLoader
  private let profileLockStore: MailProfileLockPersisting
  private let profileLoader: NotificationProfilePolicyLoading
  private let scheduler: ThreadSnoozeScheduler
  private let service: FollowUpNudgeSyncing
  private var addressesByConnectionId: [MailboxConnectionId: Set<String>] = [:]
  private var deliveredNudges: [StableThreadIdentity: FollowUpNudge] = [:]
  private(set) var preferences = ThreadSnoozePreferences.defaults
  private var profileId: MailProfileId
  private var session: ProductAccountSessionSnapshot
  private var snapshot = FollowUpNudgeSnapshot(nudges: [:])
  private var stateRevision = 0
  private var subjectsByThreadId: [StableThreadIdentity: String] = [:]
  private var updatingThreadIds: Set<StableThreadIdentity> = []
  private var wakeTasks: [StableThreadIdentity: Task<Void, Never>] = [:]

  init(
    attentionDelivery: FollowUpNudgeAttentionDelivering = UserNotificationService(),
    notificationAuthorization: NotificationAuthorizationStateChecking = UserNotificationService(),
    notificationPreferenceStore: NotificationDevicePreferencePersisting =
      UserDefaultsNotificationPreferenceStore(),
    preferenceLoader: @escaping PreferenceLoader = { profileId, session in
      try await ThreadSnoozeSyncService().loadPreferences(
        profileId: profileId,
        session: session
      )
    },
    profileLockStore: MailProfileLockPersisting = UserDefaultsMailProfileLockStore(),
    profileLoader: NotificationProfilePolicyLoading = MailboxConnectionSyncService(),
    scheduler: ThreadSnoozeScheduler = .continuous,
    service: FollowUpNudgeSyncing,
    session: ProductAccountSessionSnapshot,
    profileId: MailProfileId? = nil
  ) {
    self.attentionDelivery = attentionDelivery
    self.notificationAuthorization = notificationAuthorization
    self.notificationPreferenceStore = notificationPreferenceStore
    self.preferenceLoader = preferenceLoader
    self.profileLockStore = profileLockStore
    self.profileLoader = profileLoader
    self.scheduler = scheduler
    self.service = service
    self.session = session
    self.profileId = profileId ?? .defaultProfile(productAccountId: session.productAccountId)
  }

  isolated deinit {
    for task in wakeTasks.values { task.cancel() }
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    stateRevision += 1
    self.session = session
    rescheduleFutureWakes()
  }

  func updateProfile(_ profileId: MailProfileId) {
    guard profileId != self.profileId else { return }
    stateRevision += 1
    self.profileId = profileId
    snapshot = FollowUpNudgeSnapshot(nudges: [:])
    nudgeThreadIds = []
    overdueThreadIds = []
    suggestedThreadIds = []
    addressesByConnectionId = [:]
    deliveredNudges = [:]
    subjectsByThreadId = [:]
    updatingThreadIds = []
    for task in wakeTasks.values { task.cancel() }
    wakeTasks = [:]
    errorMessage = nil
  }

  func load() async {
    let revision = stateRevision
    let session = session
    do {
      async let loadedSnapshot = service.load(profileId: profileId, session: session)
      async let loadedPreferences = preferenceLoader(profileId, session)
      let snapshot = try await loadedSnapshot
      guard revision == stateRevision else { return }
      apply(snapshot)
      let preferences = try await loadedPreferences
      guard revision == stateRevision else { return }
      self.preferences = preferences
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      guard revision == stateRevision else { return }
      errorMessage = error.localizedDescription
    }
  }

  func reconcile(
    with messages: [MailboxMessageMetadata],
    connections: [MailboxConnection]
  ) async {
    let revision = stateRevision
    let session = session
    addressesByConnectionId = Dictionary(
      uniqueKeysWithValues: connections.map {
        ($0.id, FollowUpNudgeEligibility.normalizedAddresses([$0.mailboxAddress]))
      }
    )
    let threads = MailboxThread.group(messages)
    subjectsByThreadId.merge(
      Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0.latestMessage.subject) })
    ) { _, latest in latest }
    refreshSuggestions(threads: threads)
    do {
      let reconciled = try await service.reconcile(
        with: messages,
        profileId: profileId,
        session: session
      )
      guard revision == stateRevision else { return }
      apply(reconciled)
      refreshSuggestions(threads: threads)
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      guard revision == stateRevision else { return }
      errorMessage = error.localizedDescription
    }
  }

  func schedule(
    _ thread: MailboxThread,
    preset: FollowUpNudgePreset,
    connection: MailboxConnection,
    source: FollowUpNudgeCreationSource = .scheduled
  ) async {
    do {
      try await schedule(
        thread,
        until: preset.dueDate(),
        authorizedSendingAddresses: [connection.mailboxAddress],
        source: source
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func acceptSuggestion(_ thread: MailboxThread, connection: MailboxConnection) async {
    await schedule(
      thread,
      preset: .tomorrowMorning,
      connection: connection,
      source: .suggestionAccepted
    )
  }

  func schedule(
    _ thread: MailboxThread,
    until dueDate: Date,
    authorizedSendingAddresses: Set<String>,
    source: FollowUpNudgeCreationSource
  ) async throws {
    guard !updatingThreadIds.contains(thread.id) else { return }
    stateRevision += 1
    rescheduleFutureWakes()
    let revision = stateRevision
    let session = session
    updatingThreadIds.insert(thread.id)
    subjectsByThreadId[thread.id] = thread.latestMessage.subject
    defer { updatingThreadIds.remove(thread.id) }
    do {
      try await service.schedule(
        thread: thread,
        dueAtMilliseconds: Int64(dueDate.timeIntervalSince1970 * 1_000),
        authorizedSendingAddresses: authorizedSendingAddresses,
        source: source,
        profileId: profileId,
        session: session
      )
      let loaded = try await service.load(profileId: profileId, session: session)
      guard revision == stateRevision else { return }
      apply(loaded)
      suggestedThreadIds.remove(thread.id)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func cancel(_ threadId: StableThreadIdentity) async {
    guard !updatingThreadIds.contains(threadId) else { return }
    stateRevision += 1
    rescheduleFutureWakes()
    let revision = stateRevision
    let session = session
    updatingThreadIds.insert(threadId)
    defer { updatingThreadIds.remove(threadId) }
    do {
      try await service.cancel(threadId: threadId, profileId: profileId, session: session)
      let loaded = try await service.load(profileId: profileId, session: session)
      guard revision == stateRevision else { return }
      apply(loaded)
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func isEligible(_ thread: MailboxThread, connection: MailboxConnection) -> Bool {
    FollowUpNudgeEligibility.anchor(
      in: thread,
      authorizedSendingAddresses: [connection.mailboxAddress]
    ) != nil
  }

  func isUpdating(_ threadId: StableThreadIdentity) -> Bool {
    updatingThreadIds.contains(threadId)
  }

  func clearError() {
    errorMessage = nil
  }

  private func refreshSuggestions(threads: [MailboxThread]) {
    let now = scheduler.nowMilliseconds()
    let minimumAge = Int64(2 * 24 * 60 * 60 * 1_000)
    suggestedThreadIds = Set(
      threads.compactMap { thread in
        guard snapshot.nudges[thread.id] == nil,
          let addresses = addressesByConnectionId[thread.id.connectionId],
          let anchor = FollowUpNudgeEligibility.anchor(
            in: thread,
            authorizedSendingAddresses: addresses
          ),
          now - anchor.providerInternalDateMilliseconds >= minimumAge
        else { return nil }
        return thread.id
      }
    )
  }

  private func rescheduleFutureWakes() {
    let now = scheduler.nowMilliseconds()
    for nudge in snapshot.nudges.values where nudge.dueAtMilliseconds > now {
      wakeTasks[nudge.threadId]?.cancel()
      wakeTasks[nudge.threadId] = nil
      deliveredNudges[nudge.threadId] = nil
      scheduleAttentionIfNeeded(for: nudge, sleepsUntilDue: true)
    }
  }

  private func apply(_ snapshot: FollowUpNudgeSnapshot) {
    self.snapshot = snapshot
    nudgeThreadIds = Set(snapshot.nudges.keys)
    overdueThreadIds = snapshot.overdueThreadIds(atMilliseconds: scheduler.nowMilliseconds())
    for (threadId, task) in wakeTasks where snapshot.nudges[threadId] == nil {
      task.cancel()
      wakeTasks[threadId] = nil
      deliveredNudges[threadId] = nil
    }
    for nudge in snapshot.nudges.values {
      if nudge.dueAtMilliseconds <= scheduler.nowMilliseconds() {
        scheduleAttentionIfNeeded(for: nudge, sleepsUntilDue: false)
      } else if deliveredNudges[nudge.threadId] != nudge {
        scheduleAttentionIfNeeded(for: nudge, sleepsUntilDue: true)
      }
    }
  }

  private func scheduleAttentionIfNeeded(
    for nudge: FollowUpNudge,
    sleepsUntilDue: Bool
  ) {
    guard deliveredNudges[nudge.threadId] != nudge else { return }
    wakeTasks[nudge.threadId]?.cancel()
    deliveredNudges[nudge.threadId] = nudge
    let profileId = profileId
    let revision = stateRevision
    let session = session
    wakeTasks[nudge.threadId] = Task { [weak self] in
      guard let self else { return }
      if sleepsUntilDue {
        do {
          try await scheduler.sleepUntilMilliseconds(nudge.dueAtMilliseconds)
        } catch { return }
      }
      guard
        await revalidateScheduledWake(
          nudge,
          profileId: profileId,
          revision: revision,
          session: session
        ),
        !Task.isCancelled,
        revision == stateRevision,
        snapshot.nudges[nudge.threadId] == nudge
      else { return }
      overdueThreadIds.insert(nudge.threadId)
      await deliverAttention(for: nudge)
      if revision == stateRevision { wakeTasks[nudge.threadId] = nil }
    }
  }

  private func revalidateScheduledWake(
    _ nudge: FollowUpNudge,
    profileId: MailProfileId,
    revision: Int,
    session: ProductAccountSessionSnapshot
  ) async -> Bool {
    guard !Task.isCancelled, revision == stateRevision else { return false }
    async let loadedSnapshot = service.load(profileId: profileId, session: session)
    async let loadedPreferences = preferenceLoader(profileId, session)
    guard
      let (authoritativeSnapshot, authoritativePreferences) = try? await (
        loadedSnapshot,
        loadedPreferences
      )
    else { return false }
    guard !Task.isCancelled, revision == stateRevision else { return false }
    preferences = authoritativePreferences
    guard authoritativeSnapshot.nudges[nudge.threadId] == nudge else {
      apply(authoritativeSnapshot)
      return false
    }
    return true
  }

  private func deliverAttention(for nudge: FollowUpNudge) async {
    guard await notificationAuthorization.notificationAuthorizationState() == .authorized else {
      return
    }
    let productAccountId = session.productAccountId
    let devicePreferences = notificationPreferenceStore.load(productAccountId: productAccountId)
    guard
      let loadedProfiles = try? await profileLoader.loadNotificationProfileSnapshot(
        session: session
      ),
      let profile = loadedProfiles.profiles.first(where: { $0.id == nudge.profileId })
    else { return }
    let quietUntil = profile.quietState.quietUntil
    let isProfileQuiet =
      profile.quietState.isQuiet
      && (quietUntil.map { $0 > scheduler.nowMilliseconds() } ?? true)
    let allowsLockScreenContent =
      switch devicePreferences.lockScreenContentLevel {
      case .senderAndSubject, .fullPreview: true
      case .countOnly, .sender: false
      }
    let profileLock = profileLockStore.load(
      productAccountId: productAccountId,
      profileId: nudge.profileId
    )
    let policy = FollowUpNudgeInterruptionPolicy(
      allowsLockScreenContent: allowsLockScreenContent,
      isOSAuthorized: true,
      isProfileLocked: profileLock.isEnabled,
      isQuiet: isProfileQuiet || devicePreferences.quietSchedule.isQuiet(at: .now),
      returnToAttentionEnabled: preferences.returnToAttentionEnabled,
      trustedDeviceId: session.trustedDeviceId
    )
    do {
      try await attentionDelivery.deliverFollowUpNudgeAttention(
        decision: policy.decision(
          for: nudge,
          subject: subjectsByThreadId[nudge.threadId] ?? "A sent Thread needs follow-up."
        ),
        nudge: nudge,
        productAccountId: productAccountId
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
