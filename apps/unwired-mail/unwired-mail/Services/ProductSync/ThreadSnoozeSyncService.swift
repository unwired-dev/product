import CryptoKit
import Foundation

// swiftlint:disable file_length

enum ThreadSnoozeRepeatedTimePolicy: Sendable {
  case first
  case last
}

enum ThreadSnoozeDueDateResolver {
  static func resolve(
    localComponents: DateComponents,
    timeZone: TimeZone,
    repeatedTimePolicy: ThreadSnoozeRepeatedTimePolicy
  ) throws -> Date {
    guard let year = localComponents.year,
      let month = localComponents.month,
      let day = localComponents.day,
      let hour = localComponents.hour,
      let minute = localComponents.minute
    else {
      throw ThreadSnoozeSyncError.invalidDueTime
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let dayComponents = DateComponents(year: year, month: month, day: day)
    guard let dayStart = calendar.date(from: dayComponents) else {
      throw ThreadSnoozeSyncError.invalidDueTime
    }
    let matchingComponents = DateComponents(
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute
    )
    let repeatedPolicy: Calendar.RepeatedTimePolicy =
      repeatedTimePolicy == .first ? .first : .last
    guard
      let resolved = calendar.nextDate(
        after: dayStart.addingTimeInterval(-1),
        matching: matchingComponents,
        matchingPolicy: .nextTime,
        repeatedTimePolicy: repeatedPolicy,
        direction: .forward
      )
    else {
      throw ThreadSnoozeSyncError.invalidDueTime
    }
    return resolved
  }
}

enum ThreadSnoozeInterruptionDecision: Equatable, Sendable {
  case generic
  case revealing(String)
  case suppress
}

struct ThreadSnoozeInterruptionPolicy: Equatable, Sendable {
  let allowsLockScreenContent: Bool
  let isOSAuthorized: Bool
  let isProfileLocked: Bool
  let isQuiet: Bool
  let returnToAttentionEnabled: Bool
  let trustedDeviceId: String

  func decision(
    for snooze: ThreadSnooze,
    subject: String
  ) -> ThreadSnoozeInterruptionDecision {
    guard returnToAttentionEnabled,
      isOSAuthorized,
      !isProfileLocked,
      !isQuiet,
      snooze.notificationOwnerDeviceId == trustedDeviceId
    else { return .suppress }
    return allowsLockScreenContent ? .revealing(subject) : .generic
  }
}

protocol ThreadSnoozeSyncing {
  func load(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadSnoozeSnapshot

  func snooze(
    thread: MailboxThread,
    dueAtMilliseconds: Int64,
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
  ) async throws -> ThreadSnoozeSnapshot

  func loadPreferences(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadSnoozePreferences

  func setReturnToAttentionEnabled(
    _ isEnabled: Bool,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws
}

enum ThreadSnoozeSyncError: LocalizedError, Equatable {
  case concurrentModification
  case invalidDueTime
  case invalidPayload
  case missingProductSyncKeyMaterial

  var errorDescription: String? {
    switch self {
    case .concurrentModification:
      return "Snooze changed on another device. Refresh and try again."
    case .invalidDueTime:
      return "Choose a future time to snooze this Thread."
    case .invalidPayload:
      return "A synchronized Snooze could not be verified."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing Snooze."
    }
  }
}

struct ThreadSnooze: Equatable, Sendable {
  let anchorMessageId: StableProviderMessageIdentity
  let anchorReceivedAtMilliseconds: Int64
  let dueAtMilliseconds: Int64
  let notificationOwnerDeviceId: String
  let profileId: MailProfileId
  let threadId: StableThreadIdentity
}

struct ThreadSnoozeSnapshot: Equatable, Sendable {
  let snoozes: [StableThreadIdentity: ThreadSnooze]

  func activeThreadIds(atMilliseconds nowMilliseconds: Int64) -> Set<StableThreadIdentity> {
    Set(
      snoozes.values.compactMap {
        $0.dueAtMilliseconds > nowMilliseconds ? $0.threadId : nil
      }
    )
  }
}

struct ThreadSnoozePreferences: Equatable, Sendable {
  var returnToAttentionEnabled: Bool

  static let defaults = ThreadSnoozePreferences(returnToAttentionEnabled: true)
}

private struct ThreadSnoozePreferenceSyncPayload: Codable, Equatable, Sendable {
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let profileId: String
  let returnToAttentionEnabled: Bool
  let schemaVersion: Int
}

private struct ThreadSnoozeSyncPayload: Codable, Equatable, Sendable {
  let anchorProviderMessageId: String
  let anchorReceivedAtMilliseconds: Int64
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let dueAtMilliseconds: Int64
  let isSnoozed: Bool
  let notificationOwnerDeviceId: String
  let profileId: String
  let provider: String
  let providerAccountIdentifier: String
  let providerThreadId: String
  let schemaVersion: Int

  var snooze: ThreadSnooze {
    ThreadSnooze(
      anchorMessageId: StableProviderMessageIdentity(
        connectionId: threadId.connectionId,
        providerMessageId: anchorProviderMessageId
      ),
      anchorReceivedAtMilliseconds: anchorReceivedAtMilliseconds,
      dueAtMilliseconds: dueAtMilliseconds,
      notificationOwnerDeviceId: notificationOwnerDeviceId,
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

// swiftlint:disable:next type_body_length
final class ThreadSnoozeSyncService: ThreadSnoozeSyncing {
  static let payloadIdentifierPrefix = "thread-snooze-v1-"
  static let preferenceIdentifier = "thread-snooze-preferences-v1"

  private let lastChangeLock = NSLock()
  private var lastChangeAtMilliseconds: Int64 = 0
  private let nowMilliseconds: @Sendable () -> Int64
  private let recordBoundary: ProductSyncRecordBoundary

  init(
    nowMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()
  ) {
    self.nowMilliseconds = nowMilliseconds
    self.recordBoundary = recordBoundary
  }

  func load(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadSnoozeSnapshot {
    do {
      let records = try await records(for: profileId, session: session).list(session: session)
      let snoozes = try records.reduce(into: [StableThreadIdentity: ThreadSnooze]()) {
        let (identifier, record) = $1
        try validate(record.value, identifier: identifier, profileId: profileId)
        advanceChangeClock(to: record.value.changedAtMilliseconds)
        if record.value.isSnoozed {
          $0[record.value.threadId] = record.value.snooze
        }
      }
      return ThreadSnoozeSnapshot(snoozes: snoozes)
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func snooze(
    thread: MailboxThread,
    dueAtMilliseconds: Int64,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws {
    guard dueAtMilliseconds > nowMilliseconds() else {
      throw ThreadSnoozeSyncError.invalidDueTime
    }
    let proposed = makePayload(
      thread: thread,
      dueAtMilliseconds: dueAtMilliseconds,
      profileId: profileId,
      session: session
    )
    let identifier = payloadIdentifier(for: thread.id, profileId: profileId, session: session)
    do {
      let records = records(for: profileId, session: session)
      _ = try await records.update(identifier, session: session) { currentRecord in
        guard let currentRecord else { return .write(proposed) }
        try self.validate(currentRecord.value, identifier: identifier, profileId: profileId)
        self.advanceChangeClock(to: currentRecord.value.changedAtMilliseconds)
        guard proposed.isNewer(than: currentRecord.value) else {
          if currentRecord.value.dueAtMilliseconds != proposed.dueAtMilliseconds
            || !currentRecord.value.isSnoozed
          {
            throw ThreadSnoozeSyncError.concurrentModification
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
    try await cancel(
      threadId: threadId,
      expectedAnchorMessageId: nil,
      profileId: profileId,
      session: session
    )
  }

  func reconcile(
    with messages: [MailboxMessageMetadata],
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadSnoozeSnapshot {
    let snapshot = try await load(profileId: profileId, session: session)
    let latestMessages = Dictionary(
      uniqueKeysWithValues: MailboxThread.group(messages).map { ($0.id, $0.latestMessage) }
    )
    let now = nowMilliseconds()
    for snooze in snapshot.snoozes.values where snooze.dueAtMilliseconds > now {
      guard let latest = latestMessages[snooze.threadId] else { continue }
      let isNewMessage =
        latest.providerInternalDateMilliseconds > snooze.anchorReceivedAtMilliseconds
        || (latest.providerInternalDateMilliseconds == snooze.anchorReceivedAtMilliseconds
          && latest.id != snooze.anchorMessageId)
      guard isNewMessage else { continue }
      try await cancel(
        threadId: snooze.threadId,
        expectedAnchorMessageId: snooze.anchorMessageId,
        profileId: profileId,
        session: session
      )
    }
    return try await load(profileId: profileId, session: session)
  }

  func loadPreferences(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadSnoozePreferences {
    do {
      guard
        let record = try await preferenceRecord(for: profileId, session: session).read(
          [Self.preferenceIdentifier],
          session: session
        )[Self.preferenceIdentifier]
      else { return .defaults }
      try validate(record.value, profileId: profileId)
      advanceChangeClock(to: record.value.changedAtMilliseconds)
      return ThreadSnoozePreferences(
        returnToAttentionEnabled: record.value.returnToAttentionEnabled
      )
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func setReturnToAttentionEnabled(
    _ isEnabled: Bool,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let proposed = ThreadSnoozePreferenceSyncPayload(
      changedAtMilliseconds: nextChangeAtMilliseconds(),
      changedByTrustedDeviceId: session.trustedDeviceId,
      profileId: profileId.rawValue,
      returnToAttentionEnabled: isEnabled,
      schemaVersion: 1
    )
    do {
      _ = try await preferenceRecord(for: profileId, session: session).update(
        Self.preferenceIdentifier,
        session: session
      ) { currentRecord in
        if let currentRecord {
          try self.validate(currentRecord.value, profileId: profileId)
          self.advanceChangeClock(to: currentRecord.value.changedAtMilliseconds)
          if currentRecord.value.changedAtMilliseconds > proposed.changedAtMilliseconds
            || (currentRecord.value.changedAtMilliseconds == proposed.changedAtMilliseconds
              && currentRecord.value.changedByTrustedDeviceId
                >= proposed.changedByTrustedDeviceId)
          {
            guard currentRecord.value.returnToAttentionEnabled == isEnabled else {
              throw ThreadSnoozeSyncError.concurrentModification
            }
            return .acceptAuthoritative
          }
        }
        return .write(proposed)
      }
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func cancel(
    threadId: StableThreadIdentity,
    expectedAnchorMessageId: StableProviderMessageIdentity?,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let identifier = payloadIdentifier(for: threadId, profileId: profileId, session: session)
    do {
      let records = records(for: profileId, session: session)
      _ = try await records.update(identifier, session: session) { currentRecord in
        guard let currentRecord else { return .acceptAuthoritative }
        let current = currentRecord.value
        try self.validate(current, identifier: identifier, profileId: profileId)
        self.advanceChangeClock(to: current.changedAtMilliseconds)
        guard current.isSnoozed else { return .acceptAuthoritative }
        if let expectedAnchorMessageId,
          current.snooze.anchorMessageId != expectedAnchorMessageId
        {
          return .acceptAuthoritative
        }
        return .write(
          ThreadSnoozeSyncPayload(
            anchorProviderMessageId: current.anchorProviderMessageId,
            anchorReceivedAtMilliseconds: current.anchorReceivedAtMilliseconds,
            changedAtMilliseconds: self.nextChangeAtMilliseconds(),
            changedByTrustedDeviceId: session.trustedDeviceId,
            dueAtMilliseconds: current.dueAtMilliseconds,
            isSnoozed: false,
            notificationOwnerDeviceId: session.trustedDeviceId,
            profileId: current.profileId,
            provider: current.provider,
            providerAccountIdentifier: current.providerAccountIdentifier,
            providerThreadId: current.providerThreadId,
            schemaVersion: current.schemaVersion
          )
        )
      }
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func records(
    for profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> ProductSyncRecordFamilyHandle<String, ThreadSnoozeSyncPayload> {
    let prefix = identifierPrefix(for: profileId, session: session)
    return recordBoundary.family(
      ProductSyncRecordFamilyDefinition<String, ThreadSnoozeSyncPayload>(
        identifier: { $0 },
        identifierPrefix: prefix,
        recordId: { $0.hasPrefix(prefix) ? $0 : nil },
        cachePolicy: .authoritative
      )
    )
  }

  private func preferenceRecord(
    for profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> ProductSyncRecordFamilyHandle<String, ThreadSnoozePreferenceSyncPayload> {
    let identifier = recordScope(for: profileId, session: session)
      .productSyncIdentifier(Self.preferenceIdentifier)
    return recordBoundary.family(
      ProductSyncRecordFamilyDefinition<String, ThreadSnoozePreferenceSyncPayload>(
        identifier: { _ in identifier },
        identifierPrefix: identifier,
        recordId: { $0 == identifier ? Self.preferenceIdentifier : nil },
        cachePolicy: .authoritative
      )
    )
  }

  private func makePayload(
    thread: MailboxThread,
    dueAtMilliseconds: Int64,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) -> ThreadSnoozeSyncPayload {
    ThreadSnoozeSyncPayload(
      anchorProviderMessageId: thread.latestMessage.providerMessageId,
      anchorReceivedAtMilliseconds: thread.latestMessage.providerInternalDateMilliseconds,
      changedAtMilliseconds: nextChangeAtMilliseconds(),
      changedByTrustedDeviceId: session.trustedDeviceId,
      dueAtMilliseconds: dueAtMilliseconds,
      isSnoozed: true,
      notificationOwnerDeviceId: session.trustedDeviceId,
      profileId: profileId.rawValue,
      provider: thread.id.connectionId.providerId.rawValue,
      providerAccountIdentifier: thread.id.connectionId.providerMailboxIdentity.value,
      providerThreadId: thread.id.providerThreadId,
      schemaVersion: 1
    )
  }

  private func validate(
    _ payload: ThreadSnoozeSyncPayload,
    identifier: String,
    profileId: MailProfileId
  ) throws {
    guard payload.schemaVersion == 1,
      payload.profileId == profileId.rawValue,
      payload.anchorReceivedAtMilliseconds >= 0,
      payload.dueAtMilliseconds > 0,
      !payload.notificationOwnerDeviceId.isEmpty,
      identifier.hasSuffix(payloadIdentifierSuffix(for: payload.threadId))
    else {
      throw ThreadSnoozeSyncError.invalidPayload
    }
  }

  private func validate(
    _ payload: ThreadSnoozePreferenceSyncPayload,
    profileId: MailProfileId
  ) throws {
    guard payload.schemaVersion == 1,
      payload.profileId == profileId.rawValue,
      !payload.changedByTrustedDeviceId.isEmpty
    else {
      throw ThreadSnoozeSyncError.invalidPayload
    }
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
    let scope = recordScope(for: profileId, session: session)
    return scope.productSyncIdentifier(Self.payloadIdentifierPrefix)
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
    let digest = SHA256.hash(data: Data(canonicalIdentity.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return digest
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
      return ThreadSnoozeSyncError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      return ThreadSnoozeSyncError.concurrentModification
    case .incompletePagination, .invalidPayloadIdentifier:
      return ThreadSnoozeSyncError.invalidPayload
    }
  }
}
