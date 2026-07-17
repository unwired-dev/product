import UserNotifications

/// Delivers a visible notification only after a trusted device has categorized the message.
///
/// Example:
/// ```swift
/// let delivery: CategoryAwareNotificationDelivering = UserNotificationService()
/// try await delivery.deliver(message: categorizedMessage)
/// ```
protocol CategoryAwareNotificationDelivering {
  func deliver(message: GmailMessageMetadata) async throws
}

/// Delivers a content-free visible notification when device processing cannot finish in time.
protocol GenericNotificationDelivering {
  func deliverGeneric(identifier: String) async throws
}

/// Stores the device-local opt-in for Generic Notification Fallback.
protocol GenericNotificationFallbackPersisting {
  func isEnabled(productAccountId: String) -> Bool
  func setEnabled(_ isEnabled: Bool, productAccountId: String)
}

struct UserDefaultsFallbackStore: GenericNotificationFallbackPersisting {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func isEnabled(productAccountId: String) -> Bool {
    defaults.bool(forKey: key(productAccountId: productAccountId))
  }

  func setEnabled(_ isEnabled: Bool, productAccountId: String) {
    defaults.set(isEnabled, forKey: key(productAccountId: productAccountId))
  }

  private func key(productAccountId: String) -> String {
    "generic-notification-fallback.\(productAccountId)"
  }
}

/// Requests the local alert permission needed to make matching Notification Rules visible.
///
/// Example:
/// ```swift
/// let authorization: NotificationAuthorizationRequesting = UserNotificationService()
/// let granted = try await authorization.requestAuthorization()
/// ```
protocol NotificationAuthorizationRequesting {
  func requestAuthorization() async throws -> Bool
}

protocol UserNotificationCenterClient {
  func add(_ request: UNNotificationRequest) async throws
  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
}

extension UNUserNotificationCenter: UserNotificationCenterClient {}

/// Uses the local notification center without sending message or category data to the backend.
///
/// Example:
/// ```swift
/// let notifications = UserNotificationService()
/// try await notifications.deliver(message: categorizedMessage)
/// ```
struct UserNotificationService:
  CategoryAwareNotificationDelivering, GenericNotificationDelivering,
  NotificationAuthorizationRequesting
{
  private let center: UserNotificationCenterClient

  init(center: UserNotificationCenterClient = UNUserNotificationCenter.current()) {
    self.center = center
  }

  func requestAuthorization() async throws -> Bool {
    try await center.requestAuthorization(options: [.alert, .badge, .sound])
  }

  func deliver(message: GmailMessageMetadata) async throws {
    let content = UNMutableNotificationContent()
    content.body = "A message matched your notification rules."
    content.sound = .default
    content.title = "New mail"
    try await center.add(
      UNNotificationRequest(
        identifier: message.stableProviderMessageId,
        content: content,
        trigger: nil
      )
    )
  }

  func deliverGeneric(identifier: String) async throws {
    let content = UNMutableNotificationContent()
    content.body = "New mail is available."
    content.sound = .default
    content.title = "New mail"
    try await center.add(
      UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    )
  }
}
