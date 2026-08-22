import Foundation

struct SendReminderInterruptionPolicy: Equatable, Sendable {
  let isDeviceQuietAtDueTime: Bool
  let isProfileLocked: Bool
  let isProfileQuietAtDueTime: Bool
  let returnToAttentionEnabled: Bool

  var allowsInterruption: Bool {
    returnToAttentionEnabled && !isDeviceQuietAtDueTime && !isProfileLocked
      && !isProfileQuietAtDueTime
  }
}

enum SendReminderSyncError: LocalizedError, Equatable {
  case concurrentModification
  case invalidPayload

  var errorDescription: String? {
    switch self {
    case .concurrentModification:
      return "Send Reminder changed on another device. Reload and try again."
    case .invalidPayload:
      return "A synchronized Send Reminder could not be verified."
    }
  }
}

struct SendReminderSyncSnapshot: Equatable, Sendable {
  let remindersByDraftId: [UUID: SendReminder]
  let removedDraftIds: Set<UUID>
}

enum SendReminderSyncMutation: Equatable, Sendable {
  case accepted(SendReminder?)
  case authoritative(SendReminder?)
}

protocol SendReminderSyncing: Sendable {
  func cancel(
    draftId: UUID,
    expectedRevision: UUID?,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> SendReminderSyncMutation

  func claimNotificationOwnership(
    draftId: UUID,
    expectedRevision: UUID,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> SendReminder?

  func load(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> SendReminderSyncSnapshot

  func synchronize(
    _ reminder: SendReminder,
    draftId: UUID,
    draftUpdatedAtMilliseconds: Int64,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> SendReminderSyncMutation
}

private struct SendReminderSyncRecordId: Hashable, Sendable {
  let draftId: UUID
  let profileId: MailProfileId
}

private struct SendReminderSyncPayload: Codable, Equatable, Sendable {
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let createdAtMilliseconds: Int64
  let draftId: UUID
  let dueAtMilliseconds: Int64
  let isActive: Bool
  let notificationOwnerDeviceId: String
  let originalTimeZoneIdentifier: String
  let profileId: String
  let reminderId: UUID
  let revision: UUID
  let schemaVersion: Int

  var reminder: SendReminder {
    SendReminder(
      dueAt: Date(timeIntervalSince1970: TimeInterval(dueAtMilliseconds) / 1_000),
      originatingDeviceId: notificationOwnerDeviceId,
      originalTimeZoneIdentifier: originalTimeZoneIdentifier,
      createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtMilliseconds) / 1_000),
      id: reminderId,
      revision: revision,
      changedAtMilliseconds: changedAtMilliseconds,
      changedByTrustedDeviceId: changedByTrustedDeviceId,
      isSynchronizationPending: false,
      notificationOwnerDeviceId: notificationOwnerDeviceId
    )
  }

  func isNewer(than other: Self) -> Bool {
    if changedAtMilliseconds != other.changedAtMilliseconds {
      return changedAtMilliseconds > other.changedAtMilliseconds
    }
    return changedByTrustedDeviceId > other.changedByTrustedDeviceId
  }
}

actor SendReminderSyncService: SendReminderSyncing {
  static let payloadIdentifierPrefix = "send-reminder.v1."

  private var lastChangeAtMilliseconds: Int64 = 0
  private let nowMilliseconds: @Sendable () -> Int64
  private let records:
    ProductSyncRecordFamilyHandle<SendReminderSyncRecordId, SendReminderSyncPayload>

  init(
    nowMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64(Date.now.timeIntervalSince1970 * 1_000)
    },
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()
  ) {
    self.nowMilliseconds = nowMilliseconds
    records = recordBoundary.family(
      ProductSyncRecordFamilyDefinition(
        identifier: { Self.payloadIdentifier($0) },
        identifierPrefix: Self.payloadIdentifierPrefix,
        recordId: { Self.recordId($0) },
        cachePolicy: .authoritative
      )
    )
  }

  func load(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> SendReminderSyncSnapshot {
    let listed = try await records.list(session: session)
    var remindersByDraftId: [UUID: SendReminder] = [:]
    var removedDraftIds: Set<UUID> = []
    for (recordId, record) in listed where recordId.profileId == profileId {
      try Task.checkCancellation()
      try validate(record.value, recordId: recordId)
      advanceChangeClock(to: record.value.changedAtMilliseconds)
      if record.value.isActive {
        remindersByDraftId[recordId.draftId] = record.value.reminder
      } else {
        removedDraftIds.insert(recordId.draftId)
      }
    }
    return SendReminderSyncSnapshot(
      remindersByDraftId: remindersByDraftId,
      removedDraftIds: removedDraftIds
    )
  }

  func synchronize(
    _ reminder: SendReminder,
    draftId: UUID,
    draftUpdatedAtMilliseconds: Int64,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> SendReminderSyncMutation {
    let changedAtMilliseconds = max(
      reminder.changedAtMilliseconds,
      draftUpdatedAtMilliseconds
    )
    let proposed = payload(
      reminder,
      draftId: draftId,
      changedAtMilliseconds: changedAtMilliseconds,
      isActive: true,
      profileId: profileId
    )
    let recordId = SendReminderSyncRecordId(draftId: draftId, profileId: profileId)
    let record = try await records.update(recordId, session: session) { currentRecord in
      guard let currentRecord else { return .write(proposed) }
      try self.validate(currentRecord.value, recordId: recordId)
      self.advanceChangeClock(to: currentRecord.value.changedAtMilliseconds)
      if proposed == currentRecord.value { return .acceptAuthoritative }
      return proposed.isNewer(than: currentRecord.value)
        ? .write(proposed) : .acceptAuthoritative
    }
    guard let record else { throw SendReminderSyncError.invalidPayload }
    try validate(record.value, recordId: recordId)
    advanceChangeClock(to: record.value.changedAtMilliseconds)
    if record.value == proposed {
      return .accepted(record.value.reminder)
    }
    return .authoritative(record.value.isActive ? record.value.reminder : nil)
  }

  func claimNotificationOwnership(
    draftId: UUID,
    expectedRevision: UUID,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> SendReminder? {
    let recordId = SendReminderSyncRecordId(draftId: draftId, profileId: profileId)
    let record = try await records.update(recordId, session: session) { currentRecord in
      guard let currentRecord else { return .acceptAuthoritative }
      let current = currentRecord.value
      try self.validate(current, recordId: recordId)
      self.advanceChangeClock(to: current.changedAtMilliseconds)
      guard current.isActive, current.revision == expectedRevision else {
        return .acceptAuthoritative
      }
      guard current.notificationOwnerDeviceId != session.trustedDeviceId else {
        return .acceptAuthoritative
      }
      return .write(
        self.payload(
          current.reminder.claimingNotificationOwnership(
            for: session.trustedDeviceId,
            changedAtMilliseconds: self.nextChangeAtMilliseconds()
          ),
          draftId: draftId,
          isActive: true,
          profileId: profileId
        )
      )
    }
    guard let record, record.value.isActive, record.value.revision == expectedRevision else {
      return nil
    }
    try validate(record.value, recordId: recordId)
    advanceChangeClock(to: record.value.changedAtMilliseconds)
    return record.value.reminder
  }

  func cancel(
    draftId: UUID,
    expectedRevision: UUID?,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> SendReminderSyncMutation {
    let recordId = SendReminderSyncRecordId(draftId: draftId, profileId: profileId)
    let record = try await records.update(recordId, session: session) { currentRecord in
      guard let currentRecord else { return .acceptAuthoritative }
      let current = currentRecord.value
      try self.validate(current, recordId: recordId)
      self.advanceChangeClock(to: current.changedAtMilliseconds)
      guard current.isActive else { return .acceptAuthoritative }
      guard expectedRevision == nil || current.revision == expectedRevision else {
        return .acceptAuthoritative
      }
      return .write(
        SendReminderSyncPayload(
          changedAtMilliseconds: self.nextChangeAtMilliseconds(),
          changedByTrustedDeviceId: session.trustedDeviceId,
          createdAtMilliseconds: current.createdAtMilliseconds,
          draftId: current.draftId,
          dueAtMilliseconds: current.dueAtMilliseconds,
          isActive: false,
          notificationOwnerDeviceId: session.trustedDeviceId,
          originalTimeZoneIdentifier: current.originalTimeZoneIdentifier,
          profileId: current.profileId,
          reminderId: current.reminderId,
          revision: current.revision,
          schemaVersion: current.schemaVersion
        )
      )
    }
    guard let record else { return .accepted(nil) }
    try validate(record.value, recordId: recordId)
    advanceChangeClock(to: record.value.changedAtMilliseconds)
    if record.value.isActive {
      return .authoritative(record.value.reminder)
    }
    return .accepted(nil)
  }

  private func payload(
    _ reminder: SendReminder,
    draftId: UUID,
    changedAtMilliseconds: Int64? = nil,
    isActive: Bool,
    profileId: MailProfileId
  ) -> SendReminderSyncPayload {
    SendReminderSyncPayload(
      changedAtMilliseconds: changedAtMilliseconds ?? reminder.changedAtMilliseconds,
      changedByTrustedDeviceId: reminder.changedByTrustedDeviceId,
      createdAtMilliseconds: reminder.createdAtMilliseconds,
      draftId: draftId,
      dueAtMilliseconds: reminder.dueAtMilliseconds,
      isActive: isActive,
      notificationOwnerDeviceId: reminder.notificationOwnerDeviceId,
      originalTimeZoneIdentifier: reminder.originalTimeZoneIdentifier,
      profileId: profileId.rawValue,
      reminderId: reminder.id,
      revision: reminder.revision,
      schemaVersion: 1
    )
  }

  private func validate(
    _ payload: SendReminderSyncPayload,
    recordId: SendReminderSyncRecordId
  ) throws {
    guard payload.schemaVersion == 1,
      payload.draftId == recordId.draftId,
      payload.profileId == recordId.profileId.rawValue,
      payload.createdAtMilliseconds > 0,
      payload.changedAtMilliseconds >= payload.createdAtMilliseconds,
      payload.dueAtMilliseconds > 0,
      !payload.changedByTrustedDeviceId.isEmpty,
      !payload.notificationOwnerDeviceId.isEmpty,
      !payload.originalTimeZoneIdentifier.isEmpty
    else { throw SendReminderSyncError.invalidPayload }
  }

  private func advanceChangeClock(to changedAtMilliseconds: Int64) {
    lastChangeAtMilliseconds = max(lastChangeAtMilliseconds, changedAtMilliseconds)
  }

  private func nextChangeAtMilliseconds() -> Int64 {
    let next = max(nowMilliseconds(), lastChangeAtMilliseconds + 1)
    lastChangeAtMilliseconds = next
    return next
  }

  private static func payloadIdentifier(_ recordId: SendReminderSyncRecordId) -> String {
    payloadIdentifierPrefix + encoded(recordId.profileId.rawValue) + "."
      + recordId.draftId.uuidString.lowercased()
  }

  private static func recordId(_ identifier: String) -> SendReminderSyncRecordId? {
    guard identifier.hasPrefix(payloadIdentifierPrefix) else { return nil }
    let parts = identifier.dropFirst(payloadIdentifierPrefix.count).split(
      separator: ".",
      omittingEmptySubsequences: false
    )
    guard parts.count == 2,
      let profileId = decoded(String(parts[0])),
      let draftId = UUID(uuidString: String(parts[1]))
    else { return nil }
    return SendReminderSyncRecordId(
      draftId: draftId,
      profileId: MailProfileId(rawValue: profileId)
    )
  }

  private static func encoded(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
      .replacing("+", with: "-")
      .replacing("/", with: "_")
      .replacing("=", with: "")
  }

  private static func decoded(_ value: String) -> String? {
    let base64 = value.replacing("-", with: "+").replacing("_", with: "/")
    let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: padded) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
