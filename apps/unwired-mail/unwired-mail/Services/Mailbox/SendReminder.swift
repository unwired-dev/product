import Foundation

// swiftlint:disable file_length

enum SendReminderNotificationOutcome: Equatable, Sendable {
  case scheduled
  case unavailable
}

enum SendReminderRepeatedTimeChoice: String, CaseIterable, Codable, Sendable {
  case first
  case second
}

enum SendReminderLocalTimeError: LocalizedError, Equatable {
  case nonexistent

  var errorDescription: String? {
    switch self {
    case .nonexistent:
      "That local time does not exist because the clock moves forward. Choose another time."
    }
  }
}

struct SendReminderLocalTimeOption: Equatable, Identifiable, Sendable {
  let choice: SendReminderRepeatedTimeChoice
  let date: Date
  let label: String

  var id: SendReminderRepeatedTimeChoice { choice }
}

enum SendReminderPresetKind: String, Sendable {
  case laterToday
  case nextMondayMorning
  case tomorrowMorning
}

struct SendReminderPreset: Equatable, Identifiable, Sendable {
  let dueAt: Date
  let kind: SendReminderPresetKind
  let title: String

  var id: SendReminderPresetKind { kind }
}

enum SendReminderSchedule {
  static func isValid(dueAt: Date, now: Date, calendar: Calendar) -> Bool {
    guard let maximumDate = calendar.date(byAdding: .year, value: 1, to: now) else {
      return false
    }
    return dueAt >= now.addingTimeInterval(60) && dueAt <= maximumDate
  }

  static func presets(now: Date, calendar: Calendar) -> [SendReminderPreset] {
    var presets: [SendReminderPreset] = []
    if calendar.component(.hour, from: now) < 21 {
      let threeHoursLater = now.addingTimeInterval(3 * 60 * 60)
      let roundedInterval = ceil(threeHoursLater.timeIntervalSince1970 / 1_800) * 1_800
      let rounded = Date(timeIntervalSince1970: roundedInterval)
      if calendar.isDate(rounded, inSameDayAs: now) {
        presets.append(
          SendReminderPreset(dueAt: rounded, kind: .laterToday, title: "Later Today")
        )
      }
    }

    let startOfTomorrow = calendar.date(
      byAdding: .day,
      value: 1,
      to: calendar.startOfDay(for: now)
    )
    if let tomorrowMorning = startOfTomorrow.flatMap({
      calendar.date(bySettingHour: 8, minute: 0, second: 0, of: $0)
    }) {
      presets.append(
        SendReminderPreset(
          dueAt: tomorrowMorning,
          kind: .tomorrowMorning,
          title: "Tomorrow Morning"
        )
      )
    }

    var nextMondayComponents = DateComponents()
    nextMondayComponents.weekday = 2
    nextMondayComponents.hour = 8
    nextMondayComponents.minute = 0
    nextMondayComponents.second = 0
    if let tomorrow = startOfTomorrow,
      let nextMonday = calendar.nextDate(
        after: tomorrow.addingTimeInterval(-1),
        matching: nextMondayComponents,
        matchingPolicy: .nextTime,
        direction: .forward
      )
    {
      presets.append(
        SendReminderPreset(
          dueAt: nextMonday,
          kind: .nextMondayMorning,
          title: "Next Monday Morning"
        )
      )
    }
    return presets
  }

  static func localComponents(
    for date: Date,
    timeZone: TimeZone
  ) -> DateComponents {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
  }

  static func repeatedTimeOptions(
    localComponents: DateComponents,
    timeZone: TimeZone
  ) throws -> [SendReminderLocalTimeOption] {
    let dates = try matchingDates(localComponents: localComponents, timeZone: timeZone)
    return dates.enumerated().map { index, date in
      let choice: SendReminderRepeatedTimeChoice = index == 0 ? .first : .second
      return SendReminderLocalTimeOption(
        choice: choice,
        date: date,
        label: timeZoneLabel(timeZone, at: date)
      )
    }
  }

  static func resolve(
    localComponents: DateComponents,
    timeZone: TimeZone,
    repeatedTimeChoice: SendReminderRepeatedTimeChoice
  ) throws -> Date {
    let dates = try matchingDates(localComponents: localComponents, timeZone: timeZone)
    switch repeatedTimeChoice {
    case .first:
      return dates[0]
    case .second:
      return dates.count == 2 ? dates[1] : dates[0]
    }
  }

  private static func matchingDates(
    localComponents: DateComponents,
    timeZone: TimeZone
  ) throws -> [Date] {
    guard
      let year = localComponents.year,
      let month = localComponents.month,
      let day = localComponents.day,
      let hour = localComponents.hour,
      let minute = localComponents.minute
    else { throw SendReminderLocalTimeError.nonexistent }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let requested = DateComponents(
      timeZone: timeZone,
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute
    )
    guard
      let startOfRequestedDay = calendar.date(
        from: DateComponents(timeZone: timeZone, year: year, month: month, day: day)
      ),
      let searchAnchor = calendar.date(byAdding: .day, value: -1, to: startOfRequestedDay)
    else { throw SendReminderLocalTimeError.nonexistent }

    let candidates = [
      calendar.nextDate(
        after: searchAnchor,
        matching: requested,
        matchingPolicy: .strict,
        repeatedTimePolicy: .first,
        direction: .forward
      ),
      calendar.nextDate(
        after: searchAnchor,
        matching: requested,
        matchingPolicy: .strict,
        repeatedTimePolicy: .last,
        direction: .forward
      ),
    ]
    .compactMap(\.self)
    .filter {
      calendar.dateComponents([.year, .month, .day, .hour, .minute], from: $0)
        == DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    }
    .sorted()
    let dates = candidates.reduce(into: [Date]()) { result, candidate in
      if result.last != candidate { result.append(candidate) }
    }
    guard !dates.isEmpty else { throw SendReminderLocalTimeError.nonexistent }
    return dates
  }

  private static func timeZoneLabel(_ timeZone: TimeZone, at date: Date) -> String {
    let abbreviation = timeZone.abbreviation(for: date) ?? timeZone.identifier
    let seconds = timeZone.secondsFromGMT(for: date)
    let sign = seconds < 0 ? "−" : "+"
    let absoluteMinutes = abs(seconds) / 60
    let hours = absoluteMinutes / 60
    let minutes = absoluteMinutes % 60
    let offset = minutes == 0 ? "UTC\(sign)\(hours)" : "UTC\(sign)\(hours):\(minutes)"
    return "\(abbreviation) (\(offset))"
  }
}

struct SendReminder: Codable, Equatable, Identifiable, Sendable {
  var changedAtMilliseconds: Int64
  var changedByTrustedDeviceId: String
  let createdAtMilliseconds: Int64
  var dueAtMilliseconds: Int64
  let id: UUID
  var isSynchronizationPending: Bool
  var notificationOwnerDeviceId: String
  var originatingDeviceId: String
  var originalTimeZoneIdentifier: String
  var revision: UUID

  init(
    dueAt: Date,
    originatingDeviceId: String,
    originalTimeZoneIdentifier: String,
    createdAt: Date = .now,
    id: UUID = UUID(),
    revision: UUID = UUID(),
    changedAtMilliseconds: Int64? = nil,
    changedByTrustedDeviceId: String? = nil,
    isSynchronizationPending: Bool = true,
    notificationOwnerDeviceId: String? = nil
  ) {
    let createdAtMilliseconds = Int64(createdAt.timeIntervalSince1970 * 1_000)
    self.changedAtMilliseconds = changedAtMilliseconds ?? createdAtMilliseconds
    self.changedByTrustedDeviceId = changedByTrustedDeviceId ?? originatingDeviceId
    self.createdAtMilliseconds = createdAtMilliseconds
    dueAtMilliseconds = Int64(dueAt.timeIntervalSince1970 * 1_000)
    self.id = id
    self.isSynchronizationPending = isSynchronizationPending
    self.notificationOwnerDeviceId = notificationOwnerDeviceId ?? originatingDeviceId
    self.originatingDeviceId = originatingDeviceId
    self.originalTimeZoneIdentifier = originalTimeZoneIdentifier
    self.revision = revision
  }

  var dueAt: Date {
    Date(timeIntervalSince1970: TimeInterval(dueAtMilliseconds) / 1_000)
  }

  func isOverdue(at date: Date = .now) -> Bool {
    dueAt <= date
  }

  func rescheduled(
    to dueAt: Date,
    originalTimeZoneIdentifier: String,
    changedByTrustedDeviceId: String,
    changedAt: Date = .now
  ) -> Self {
    var reminder = self
    reminder.changedAtMilliseconds = Int64(changedAt.timeIntervalSince1970 * 1_000)
    reminder.changedByTrustedDeviceId = changedByTrustedDeviceId
    reminder.dueAtMilliseconds = Int64(dueAt.timeIntervalSince1970 * 1_000)
    reminder.isSynchronizationPending = true
    reminder.notificationOwnerDeviceId = changedByTrustedDeviceId
    // Older clients use this field as their notification-ownership fence.
    reminder.originatingDeviceId = changedByTrustedDeviceId
    reminder.originalTimeZoneIdentifier = originalTimeZoneIdentifier
    reminder.revision = UUID()
    return reminder
  }

  func claimingNotificationOwnership(
    for trustedDeviceId: String,
    changedAtMilliseconds: Int64
  ) -> Self {
    guard notificationOwnerDeviceId != trustedDeviceId else { return self }
    var reminder = self
    reminder.changedAtMilliseconds = changedAtMilliseconds
    reminder.changedByTrustedDeviceId = trustedDeviceId
    reminder.isSynchronizationPending = false
    reminder.notificationOwnerDeviceId = trustedDeviceId
    // Preserve the ownership handoff for clients that predate the additive record family.
    reminder.originatingDeviceId = trustedDeviceId
    return reminder
  }

  func synchronized() -> Self {
    var reminder = self
    reminder.isSynchronizationPending = false
    return reminder
  }

  private enum CodingKeys: String, CodingKey {
    case changedAtMilliseconds
    case changedByTrustedDeviceId
    case createdAtMilliseconds
    case dueAtMilliseconds
    case id
    case isSynchronizationPending
    case notificationOwnerDeviceId
    case originatingDeviceId
    case originalTimeZoneIdentifier
    case revision
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    createdAtMilliseconds = try container.decode(Int64.self, forKey: .createdAtMilliseconds)
    dueAtMilliseconds = try container.decode(Int64.self, forKey: .dueAtMilliseconds)
    id = try container.decode(UUID.self, forKey: .id)
    originatingDeviceId = try container.decode(String.self, forKey: .originatingDeviceId)
    originalTimeZoneIdentifier = try container.decode(
      String.self,
      forKey: .originalTimeZoneIdentifier
    )
    revision = try container.decode(UUID.self, forKey: .revision)
    changedAtMilliseconds =
      try container.decodeIfPresent(Int64.self, forKey: .changedAtMilliseconds)
      ?? createdAtMilliseconds
    changedByTrustedDeviceId =
      try container.decodeIfPresent(String.self, forKey: .changedByTrustedDeviceId)
      ?? originatingDeviceId
    isSynchronizationPending =
      try container.decodeIfPresent(Bool.self, forKey: .isSynchronizationPending)
      ?? true
    notificationOwnerDeviceId =
      try container.decodeIfPresent(String.self, forKey: .notificationOwnerDeviceId)
      ?? originatingDeviceId
  }
}

protocol SendReminderNotificationScheduling {
  func cancelSendReminder(
    _ reminder: SendReminder,
    draftId: UUID,
    productAccountId: String,
    profileId: MailProfileId
  )
  func scheduleSendReminder(
    _ reminder: SendReminder,
    draftId: UUID,
    productAccountId: String,
    profileId: MailProfileId
  ) async throws -> SendReminderNotificationOutcome
}

struct SendReminderDeepLink: Equatable, Sendable {
  static let draftIdUserInfoKey = "sendReminderDraftId"
  static let reminderIdUserInfoKey = "sendReminderId"
  static let reminderRevisionUserInfoKey = "sendReminderRevision"

  let draftId: UUID
  let productAccountId: String
  let profileId: MailProfileId
  let reminderId: UUID
  let reminderRevision: UUID

  init?(userInfo: [AnyHashable: Any]) {
    guard
      let draftId = (userInfo[Self.draftIdUserInfoKey] as? String).flatMap(UUID.init(uuidString:)),
      let productAccountId =
        userInfo[NotificationDeliveryContext.productAccountIdUserInfoKey] as? String,
      !productAccountId.isEmpty,
      let profileId = userInfo[NotificationDeliveryContext.profileIdUserInfoKey] as? String,
      !profileId.isEmpty,
      let reminderId = (userInfo[Self.reminderIdUserInfoKey] as? String).flatMap(
        UUID.init(uuidString:)
      ),
      let reminderRevision = (userInfo[Self.reminderRevisionUserInfoKey] as? String).flatMap(
        UUID.init(uuidString:)
      )
    else { return nil }
    self.draftId = draftId
    self.productAccountId = productAccountId
    self.profileId = MailProfileId(rawValue: profileId)
    self.reminderId = reminderId
    self.reminderRevision = reminderRevision
  }
}

@MainActor
final class PendingSendReminderDeepLinkStore {
  static let shared = PendingSendReminderDeepLinkStore()

  private var pendingDeepLink: SendReminderDeepLink?

  func remember(_ deepLink: SendReminderDeepLink) {
    pendingDeepLink = deepLink
  }

  func take(productAccountId: String) -> SendReminderDeepLink? {
    guard pendingDeepLink?.productAccountId == productAccountId else { return nil }
    defer { pendingDeepLink = nil }
    return pendingDeepLink
  }
}

extension Notification.Name {
  static let sendReminderDeepLink = Notification.Name("SendReminderDeepLink")
}
