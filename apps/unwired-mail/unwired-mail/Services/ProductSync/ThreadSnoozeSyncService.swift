import CryptoKit
import Foundation
import Security

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

protocol ThreadSnoozeAttentionDelivering {
  func deliverThreadSnoozeAttention(
    decision: ThreadSnoozeInterruptionDecision,
    snooze: ThreadSnooze,
    productAccountId: String
  ) async throws
}

struct ThreadSnoozeScheduler: @unchecked Sendable {
  let nowMilliseconds: @Sendable () -> Int64
  let sleepUntilMilliseconds: @Sendable (Int64) async throws -> Void

  static let continuous = ThreadSnoozeScheduler(
    nowMilliseconds: { Int64(Date.now.timeIntervalSince1970 * 1_000) },
    sleepUntilMilliseconds: { dueAtMilliseconds in
      let delay = max(
        0,
        dueAtMilliseconds - Int64(Date.now.timeIntervalSince1970 * 1_000)
      )
      try await Task.sleep(for: .milliseconds(delay))
    }
  )
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
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let dueAtMilliseconds: Int64
  let notificationOwnerDeviceId: String
  let observedMessageIds: Set<StableProviderMessageIdentity>
  let profileId: MailProfileId
  let threadId: StableThreadIdentity

  init(
    anchorMessageId: StableProviderMessageIdentity,
    anchorReceivedAtMilliseconds: Int64,
    changedAtMilliseconds: Int64 = 0,
    changedByTrustedDeviceId: String = "",
    dueAtMilliseconds: Int64,
    notificationOwnerDeviceId: String,
    observedMessageIds: Set<StableProviderMessageIdentity> = [],
    profileId: MailProfileId,
    threadId: StableThreadIdentity
  ) {
    self.anchorMessageId = anchorMessageId
    self.anchorReceivedAtMilliseconds = anchorReceivedAtMilliseconds
    self.changedAtMilliseconds = changedAtMilliseconds
    self.changedByTrustedDeviceId = changedByTrustedDeviceId
    self.dueAtMilliseconds = dueAtMilliseconds
    self.notificationOwnerDeviceId = notificationOwnerDeviceId
    self.observedMessageIds = observedMessageIds
    self.profileId = profileId
    self.threadId = threadId
  }
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
  let observedProviderMessageIds: [String]?
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
      changedAtMilliseconds: changedAtMilliseconds,
      changedByTrustedDeviceId: changedByTrustedDeviceId,
      dueAtMilliseconds: dueAtMilliseconds,
      notificationOwnerDeviceId: notificationOwnerDeviceId,
      observedMessageIds: Set(
        (observedProviderMessageIds ?? [anchorProviderMessageId]).map {
          StableProviderMessageIdentity(
            connectionId: threadId.connectionId,
            providerMessageId: $0
          )
        }
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

struct KeychainThreadSnoozeSyncCiphertextCache: ProductSyncCiphertextCaching {
  private let service = "dev.unwired.mail.thread-snooze-sync-cache"

  func loadFamily(
    productAccountId: String,
    payloadIdentifierPrefix: String
  ) async throws -> [EncryptedProductSyncPayload]? {
    let payloads = try loadPayloads(productAccountId: productAccountId).values.filter {
      $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix)
    }
    guard !payloads.isEmpty else { return nil }
    return payloads.sorted {
      $0.payloadIdentifier < $1.payloadIdentifier
    }
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
    else {
      return [:]
    }
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
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary(),
    ciphertextCache: ProductSyncCiphertextCaching = KeychainThreadSnoozeSyncCiphertextCache()
  ) {
    self.nowMilliseconds = nowMilliseconds
    self.recordBoundary = recordBoundary.caching(ciphertextCache)
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
          if currentRecord.value != proposed {
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
    _ = try await cancel(
      threadId: threadId,
      expectedAnchorMessageId: nil,
      expectedChangedAtMilliseconds: nil,
      profileId: profileId,
      session: session
    )
  }

  // swiftlint:disable:next function_body_length
  func reconcile(
    with messages: [MailboxMessageMetadata],
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadSnoozeSnapshot {
    var snapshot = try await load(profileId: profileId, session: session)
    let threads = MailboxThread.group(messages)
    let messagesByThread = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0.messages) })
    let threadIdByMessageId = Dictionary(
      uniqueKeysWithValues: messages.map { ($0.id, $0.threadIdentity) }
    )
    let now = nowMilliseconds()
    for snooze in snapshot.snoozes.values where snooze.dueAtMilliseconds > now {
      var reconciledSnooze = snooze
      if let currentThreadId = threadIdByMessageId[snooze.anchorMessageId],
        currentThreadId != snooze.threadId
      {
        guard
          let migrated = try await migrate(
            snooze,
            to: currentThreadId,
            profileId: profileId,
            session: session
          )
        else {
          snapshot = ThreadSnoozeSnapshot(
            snoozes: snapshot.snoozes.filter {
              $0.key != snooze.threadId && $0.key != currentThreadId
            }
          )
          continue
        }
        reconciledSnooze = migrated
        snapshot = ThreadSnoozeSnapshot(
          snoozes: snapshot.snoozes.merging([currentThreadId: migrated]) { _, migrated in
            migrated
          }.filter { $0.key != snooze.threadId }
        )
      }
      guard let threadMessages = messagesByThread[reconciledSnooze.threadId] else { continue }
      let hasNewMessage = threadMessages.contains {
        $0.id != reconciledSnooze.anchorMessageId
          && !reconciledSnooze.observedMessageIds.contains($0.id)
          && $0.providerInternalDateMilliseconds
            >= reconciledSnooze.anchorReceivedAtMilliseconds
      }
      guard hasNewMessage else { continue }
      let authoritativeSnooze = try await cancel(
        threadId: reconciledSnooze.threadId,
        expectedAnchorMessageId: reconciledSnooze.anchorMessageId,
        expectedChangedAtMilliseconds: reconciledSnooze.changedAtMilliseconds,
        profileId: profileId,
        session: session
      )
      var snoozes = snapshot.snoozes
      snoozes[reconciledSnooze.threadId] = authoritativeSnooze
      snapshot = ThreadSnoozeSnapshot(snoozes: snoozes)
    }
    return snapshot
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
    expectedChangedAtMilliseconds: Int64?,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadSnooze? {
    let identifier = payloadIdentifier(for: threadId, profileId: profileId, session: session)
    do {
      let records = records(for: profileId, session: session)
      let record = try await records.update(identifier, session: session) { currentRecord in
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
        if let expectedChangedAtMilliseconds,
          current.changedAtMilliseconds != expectedChangedAtMilliseconds
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
            observedProviderMessageIds: current.observedProviderMessageIds,
            profileId: current.profileId,
            provider: current.provider,
            providerAccountIdentifier: current.providerAccountIdentifier,
            providerThreadId: current.providerThreadId,
            schemaVersion: current.schemaVersion
          )
        )
      }
      guard let record else { return nil }
      try validate(record.value, identifier: identifier, profileId: profileId)
      advanceChangeClock(to: record.value.changedAtMilliseconds)
      return record.value.isSnoozed ? record.value.snooze : nil
    } catch {
      throw mapBoundaryError(error)
    }
  }

  // swiftlint:disable:next function_body_length
  private func migrate(
    _ snooze: ThreadSnooze,
    to threadId: StableThreadIdentity,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot,
    retryCount: Int = 0
  ) async throws -> ThreadSnooze? {
    let migratedPayload = ThreadSnoozeSyncPayload(
      anchorProviderMessageId: snooze.anchorMessageId.providerMessageId,
      anchorReceivedAtMilliseconds: snooze.anchorReceivedAtMilliseconds,
      changedAtMilliseconds: snooze.changedAtMilliseconds,
      changedByTrustedDeviceId: snooze.changedByTrustedDeviceId,
      dueAtMilliseconds: snooze.dueAtMilliseconds,
      isSnoozed: true,
      notificationOwnerDeviceId: snooze.notificationOwnerDeviceId,
      observedProviderMessageIds: snooze.observedMessageIds.map(\.providerMessageId).sorted(),
      profileId: profileId.rawValue,
      provider: threadId.connectionId.providerId.rawValue,
      providerAccountIdentifier: threadId.connectionId.providerMailboxIdentity.value,
      providerThreadId: threadId.providerThreadId,
      schemaVersion: 1
    )
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
      guard let record else { throw ThreadSnoozeSyncError.invalidPayload }
      if let newerSource = try await cancel(
        threadId: snooze.threadId,
        expectedAnchorMessageId: snooze.anchorMessageId,
        expectedChangedAtMilliseconds: snooze.changedAtMilliseconds,
        profileId: profileId,
        session: session
      ) {
        guard retryCount < 3 else { throw ThreadSnoozeSyncError.concurrentModification }
        return try await migrate(
          newerSource,
          to: threadId,
          profileId: profileId,
          session: session,
          retryCount: retryCount + 1
        )
      }
      return record.value.isSnoozed ? record.value.snooze : nil
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
        cachePolicy: .authoritativeWithCiphertextFallback
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
      observedProviderMessageIds: thread.messages.map(\.providerMessageId).sorted(),
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
      !payload.anchorProviderMessageId.isEmpty,
      payload.anchorReceivedAtMilliseconds >= 0,
      !payload.changedByTrustedDeviceId.isEmpty,
      payload.dueAtMilliseconds > 0,
      !payload.notificationOwnerDeviceId.isEmpty,
      payload.observedProviderMessageIds?.contains(where: \.isEmpty) != true,
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
