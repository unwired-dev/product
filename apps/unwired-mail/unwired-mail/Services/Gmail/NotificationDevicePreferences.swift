import Foundation

struct NotificationDeliveryContext: Equatable, Sendable {
  static let connectionIdUserInfoKey = "mailboxConnectionId"
  static let productAccountIdUserInfoKey = "productAccountId"
  static let profileIdUserInfoKey = "mailProfileId"
  static let settingsDestinationUserInfoKey = "settingsDestination"

  let connectionId: MailboxConnectionId
  let isActiveProfile: Bool
  let isProfileQuiet: Bool
  let profileId: MailProfileId
  let profileName: String
}

struct NotificationDeepLink: Equatable, Sendable {
  let connectionId: MailboxConnectionId
  let productAccountId: String
  let profileId: MailProfileId

  init?(userInfo: [AnyHashable: Any]) {
    guard
      let connectionId = userInfo[NotificationDeliveryContext.connectionIdUserInfoKey] as? String,
      !connectionId.isEmpty,
      let productAccountId =
        userInfo[NotificationDeliveryContext.productAccountIdUserInfoKey] as? String,
      !productAccountId.isEmpty,
      let profileId = userInfo[NotificationDeliveryContext.profileIdUserInfoKey] as? String,
      !profileId.isEmpty,
      let separator = connectionId.firstIndex(of: ":")
    else { return nil }
    let provider = String(connectionId[..<separator])
    let providerAccountIdentifier = String(connectionId[connectionId.index(after: separator)...])
    guard !provider.isEmpty, !providerAccountIdentifier.isEmpty else { return nil }
    self.connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: provider),
        value: providerAccountIdentifier
      )
    )
    self.productAccountId = productAccountId
    self.profileId = MailProfileId(rawValue: profileId)
  }
}

@MainActor
final class PendingNotificationDeepLinkStore {
  static let shared = PendingNotificationDeepLinkStore()

  private var pendingDeepLink: NotificationDeepLink?

  func remember(_ deepLink: NotificationDeepLink) {
    pendingDeepLink = deepLink
  }

  func take(productAccountId: String) -> NotificationDeepLink? {
    guard pendingDeepLink?.productAccountId == productAccountId else { return nil }
    defer { pendingDeepLink = nil }
    return pendingDeepLink
  }
}

extension Notification.Name {
  static let categoryNotificationDeepLink = Notification.Name(
    "CategoryNotificationDeepLink"
  )
}

protocol ProfileAwareNotificationDelivering {
  func deliver(
    message: GmailMessageMetadata,
    productAccountId: String,
    context: NotificationDeliveryContext
  ) async throws
}

extension CategoryAwareNotificationDelivering {
  func deliver(
    message: GmailMessageMetadata,
    productAccountId: String,
    context: NotificationDeliveryContext
  ) async throws {
    guard let delivery = self as? ProfileAwareNotificationDelivering else {
      try await deliver(message: message, productAccountId: productAccountId)
      return
    }
    try await delivery.deliver(
      message: message,
      productAccountId: productAccountId,
      context: context
    )
  }
}

enum NotificationLockScreenContentLevel: String, CaseIterable, Codable, Identifiable, Sendable {
  case countOnly
  case fullPreview
  case sender
  case senderAndSubject

  var id: Self { self }

  var title: String {
    switch self {
    case .countOnly:
      return "Count Only"
    case .sender:
      return "Sender"
    case .senderAndSubject:
      return "Sender and Subject"
    case .fullPreview:
      return "Full Preview"
    }
  }
}

struct NotificationQuietSchedule: Codable, Equatable, Sendable {
  let allowedCategoryIds: [String]
  let endMinute: Int
  let isEnabled: Bool
  let startMinute: Int

  init(
    isEnabled: Bool = false,
    startMinute: Int = 22 * 60,
    endMinute: Int = 7 * 60,
    allowedCategoryIds: [String] = []
  ) {
    self.allowedCategoryIds = Array(Set(allowedCategoryIds.filter { !$0.isEmpty })).sorted()
    self.endMinute = min(max(endMinute, 0), 24 * 60 - 1)
    self.isEnabled = isEnabled
    self.startMinute = min(max(startMinute, 0), 24 * 60 - 1)
  }

  func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
    guard isEnabled else { return false }
    let components = calendar.dateComponents([.hour, .minute], from: date)
    let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
    if startMinute == endMinute { return true }
    if startMinute < endMinute {
      return minute >= startMinute && minute < endMinute
    }
    return minute >= startMinute || minute < endMinute
  }
}

struct NotificationDevicePreferences: Codable, Equatable, Sendable {
  static let `default` = NotificationDevicePreferences()

  let isBadgeEnabled: Bool
  let isSoundEnabled: Bool
  let lockScreenContentLevel: NotificationLockScreenContentLevel
  let quietSchedule: NotificationQuietSchedule

  init(
    isBadgeEnabled: Bool = true,
    isSoundEnabled: Bool = true,
    lockScreenContentLevel: NotificationLockScreenContentLevel = .countOnly,
    quietSchedule: NotificationQuietSchedule = NotificationQuietSchedule()
  ) {
    self.isBadgeEnabled = isBadgeEnabled
    self.isSoundEnabled = isSoundEnabled
    self.lockScreenContentLevel = lockScreenContentLevel
    self.quietSchedule = quietSchedule
  }
}

protocol NotificationDevicePreferencePersisting {
  func clear(productAccountId: String)
  func load(productAccountId: String) -> NotificationDevicePreferences
  func save(_ preferences: NotificationDevicePreferences, productAccountId: String)
}

struct UserDefaultsNotificationPreferenceStore: NotificationDevicePreferencePersisting {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(productAccountId: String) {
    defaults.removeObject(forKey: key(productAccountId))
  }

  func load(productAccountId: String) -> NotificationDevicePreferences {
    guard
      let data = defaults.data(forKey: key(productAccountId)),
      let preferences = try? JSONDecoder().decode(NotificationDevicePreferences.self, from: data)
    else {
      return .default
    }
    return preferences
  }

  func save(_ preferences: NotificationDevicePreferences, productAccountId: String) {
    defaults.set(try? JSONEncoder().encode(preferences), forKey: key(productAccountId))
  }

  private func key(_ productAccountId: String) -> String {
    "notification-device-preferences.\(productAccountId)"
  }
}
