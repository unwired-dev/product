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
  CategoryAwareNotificationDelivering, NotificationAuthorizationRequesting
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
}
