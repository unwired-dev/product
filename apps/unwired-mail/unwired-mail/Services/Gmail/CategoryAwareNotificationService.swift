import UserNotifications

// The notification delivery boundary keeps authorization, privacy, and presentation policy together.
// swiftlint:disable file_length

/// Delivers a visible notification only after a trusted device has categorized the message.
///
/// Example:
/// ```swift
/// let delivery: CategoryAwareNotificationDelivering = UserNotificationService()
/// try await delivery.deliver(message: categorizedMessage, productAccountId: productAccountId)
/// ```
protocol CategoryAwareNotificationDelivering {
  func deliver(message: GmailMessageMetadata, productAccountId: String) async throws
}

/// Delivers a content-free visible notification when device processing cannot finish in time.
protocol GenericNotificationDelivering {
  func deliverGeneric(identifier: String, productAccountId: String) async throws
}

/// Stores the device-local opt-in for Generic Notification Fallback.
protocol GenericNotificationFallbackPersisting {
  func isEnabled(productAccountId: String) -> Bool
  func setEnabled(_ isEnabled: Bool, productAccountId: String)
}

protocol GenericNotificationFallbackClearing {
  func clear(productAccountId: String)
}

protocol UserNotificationClearing {
  func clear(productAccountId: String)
}

protocol LegacyUserNotificationMigrating {
  func migrateLegacyIdentifiers(
    productAccountId: String,
    gmailProviderAccountIdentifiers: Set<String>
  ) async
}

protocol UserNotificationIdentifierPersisting {
  func allIdentifiers() -> Set<String>
  func identifiers(productAccountId: String) -> Set<String>
  func record(identifier: String, productAccountId: String)
  func clear(productAccountId: String)
}

final class UserDefaultsNotificationIdentifierStore: UserNotificationIdentifierPersisting {
  private static let maximumIdentifierCount = 512
  private let defaults: UserDefaults
  private let lock = NSLock()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func allIdentifiers() -> Set<String> {
    lock.withLock {
      defaults.dictionaryRepresentation().reduce(into: Set<String>()) { identifiers, entry in
        guard
          entry.key.hasPrefix("notification-identifiers."),
          let values = entry.value as? [String]
        else { return }
        identifiers.formUnion(values)
      }
    }
  }

  func identifiers(productAccountId: String) -> Set<String> {
    lock.withLock {
      Set(defaults.stringArray(forKey: key(productAccountId)) ?? [])
    }
  }

  func record(identifier: String, productAccountId: String) {
    lock.withLock {
      var identifiers = defaults.stringArray(forKey: key(productAccountId)) ?? []
      identifiers.removeAll { $0 == identifier }
      identifiers.append(identifier)
      defaults.set(
        Array(identifiers.suffix(Self.maximumIdentifierCount)),
        forKey: key(productAccountId)
      )
    }
  }

  func clear(productAccountId: String) {
    lock.withLock {
      defaults.removeObject(forKey: key(productAccountId))
    }
  }

  private func key(_ productAccountId: String) -> String {
    "notification-identifiers.\(productAccountId)"
  }
}

struct UserDefaultsFallbackStore:
  GenericNotificationFallbackPersisting,
  GenericNotificationFallbackClearing
{
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

  func clear(productAccountId: String) {
    defaults.removeObject(forKey: key(productAccountId: productAccountId))
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

enum NotificationAuthorizationState: Equatable, Sendable {
  case authorized
  case denied
  case notDetermined
}

protocol NotificationAuthorizationStateChecking {
  func notificationAuthorizationState() async -> NotificationAuthorizationState
}

protocol NotificationPreviewDelivering {
  func deliverSample(
    productAccountId: String,
    categoryIds: [String],
    context: NotificationDeliveryContext
  ) async throws
}

protocol UserNotificationCenterClient {
  func add(_ request: UNNotificationRequest) async throws
  func deliveredNotificationRequestsForOwnership() async -> [UNNotificationRequest]
  func pendingNotificationRequestsForOwnership() async -> [UNNotificationRequest]
  func removeDeliveredNotifications(withIdentifiers identifiers: [String])
  func removePendingNotificationRequests(withIdentifiers identifiers: [String])
  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
  func notificationAuthorizationState() async -> NotificationAuthorizationState
}

extension UserNotificationCenterClient {
  func deliveredNotificationRequestsForOwnership() async -> [UNNotificationRequest] { [] }
  func pendingNotificationRequestsForOwnership() async -> [UNNotificationRequest] { [] }
  func notificationAuthorizationState() async -> NotificationAuthorizationState {
    .notDetermined
  }
}

extension UNUserNotificationCenter: UserNotificationCenterClient {
  func deliveredNotificationRequestsForOwnership() async -> [UNNotificationRequest] {
    await withCheckedContinuation { continuation in
      getDeliveredNotifications {
        continuation.resume(returning: $0.map(\.request))
      }
    }
  }

  func pendingNotificationRequestsForOwnership() async -> [UNNotificationRequest] {
    await withCheckedContinuation { continuation in
      getPendingNotificationRequests { continuation.resume(returning: $0) }
    }
  }

  func notificationAuthorizationState() async -> NotificationAuthorizationState {
    switch await notificationSettings().authorizationStatus {
    case .authorized, .ephemeral, .provisional:
      return .authorized
    case .denied:
      return .denied
    case .notDetermined:
      return .notDetermined
    @unknown default:
      return .notDetermined
    }
  }
}

/// Uses the local notification center without sending message or category data to the backend.
///
/// Example:
/// ```swift
/// let notifications = UserNotificationService()
/// try await notifications.deliver(
///   message: categorizedMessage,
///   productAccountId: productAccountId
/// )
/// ```
struct UserNotificationService:
  CategoryAwareNotificationDelivering, GenericNotificationDelivering,
  LegacyUserNotificationMigrating, NotificationAuthorizationRequesting,
  NotificationAuthorizationStateChecking, NotificationPreviewDelivering,
  ProfileAwareNotificationDelivering, UserNotificationClearing
{
  private let center: UserNotificationCenterClient
  private let identifierStore: UserNotificationIdentifierPersisting
  private let now: () -> Date
  private let preferenceStore: NotificationDevicePreferencePersisting

  init(
    center: UserNotificationCenterClient = UNUserNotificationCenter.current(),
    identifierStore: UserNotificationIdentifierPersisting =
      UserDefaultsNotificationIdentifierStore(),
    now: @escaping () -> Date = Date.init,
    preferenceStore: NotificationDevicePreferencePersisting =
      UserDefaultsNotificationPreferenceStore()
  ) {
    self.center = center
    self.identifierStore = identifierStore
    self.now = now
    self.preferenceStore = preferenceStore
  }

  func requestAuthorization() async throws -> Bool {
    try await center.requestAuthorization(options: [.alert, .badge, .sound])
  }

  func notificationAuthorizationState() async -> NotificationAuthorizationState {
    await center.notificationAuthorizationState()
  }

  func migrateLegacyIdentifiers(
    productAccountId: String,
    gmailProviderAccountIdentifiers: Set<String>
  ) async {
    let knownIdentifiers = identifierStore.allIdentifiers()
    async let deliveredRequests = center.deliveredNotificationRequestsForOwnership()
    async let pendingRequests = center.pendingNotificationRequestsForOwnership()
    let legacyIdentifiers = await (deliveredRequests + pendingRequests)
      .map(\.identifier)
      .filter {
        isOwnedLegacyIdentifier(
          $0,
          gmailProviderAccountIdentifiers: gmailProviderAccountIdentifiers
        ) && !knownIdentifiers.contains($0)
      }
    for identifier in legacyIdentifiers {
      identifierStore.record(identifier: identifier, productAccountId: productAccountId)
    }
  }

  func clear(productAccountId: String) {
    let identifiers = Array(identifierStore.identifiers(productAccountId: productAccountId))
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
    center.removeDeliveredNotifications(withIdentifiers: identifiers)
    identifierStore.clear(productAccountId: productAccountId)
  }

  func deliver(message: GmailMessageMetadata, productAccountId: String) async throws {
    let preferences = preferenceStore.load(productAccountId: productAccountId)
    let content = UNMutableNotificationContent()
    applyPresentation(message: message, content: content, preferences: preferences)
    content.badge = preferences.isBadgeEnabled ? 1 : nil
    content.sound = preferences.isSoundEnabled ? .default : nil
    try await add(
      UNNotificationRequest(
        identifier: identifier(message.stableProviderMessageId, productAccountId),
        content: content,
        trigger: nil
      ),
      productAccountId: productAccountId
    )
  }

  func deliver(
    message: GmailMessageMetadata,
    productAccountId: String,
    context: NotificationDeliveryContext
  ) async throws {
    let preferences = preferenceStore.load(productAccountId: productAccountId)
    if context.isProfileQuiet
      || (preferences.quietSchedule.isQuiet(at: now())
        && Set(message.messageCategoryIds).isDisjoint(
          with: Set(preferences.quietSchedule.allowedCategoryIds)
        ))
    {
      return
    }
    let content = UNMutableNotificationContent()
    applyPresentation(message: message, content: content, preferences: preferences)
    if !context.isActiveProfile {
      content.title += " · \(context.profileName)"
    }
    content.badge = preferences.isBadgeEnabled ? 1 : nil
    content.sound = preferences.isSoundEnabled ? .default : nil
    content.userInfo = [
      NotificationDeliveryContext.connectionIdUserInfoKey: context.connectionId.rawValue,
      NotificationDeliveryContext.productAccountIdUserInfoKey: productAccountId,
      NotificationDeliveryContext.profileIdUserInfoKey: context.profileId.rawValue,
      NotificationDeliveryContext.settingsDestinationUserInfoKey:
        "notifications",
    ]
    try await add(
      UNNotificationRequest(
        identifier: identifier(message.stableProviderMessageId, productAccountId),
        content: content,
        trigger: nil
      ),
      productAccountId: productAccountId
    )
  }

  func deliverSample(
    productAccountId: String,
    categoryIds: [String],
    context: NotificationDeliveryContext
  ) async throws {
    let sample = GmailMessageMetadata(
      categoryId: categoryIds.first,
      from: "Alex Morgan <alex@example.com>",
      isHistorical: false,
      providerAccountIdentifier: "notification-preview",
      providerInternalDateMilliseconds: Int64(now().timeIntervalSince1970 * 1_000),
      providerMessageId: "notification-preview",
      providerThreadId: "notification-preview",
      replyTo: nil,
      snippet: "This is how a private mail notification will look on this device.",
      stableProviderMessageId: "notification-preview-\(UUID().uuidString)",
      subject: "Notification preview",
      rfcMessageId: nil,
      categoryIds: categoryIds
    )
    let preferences = preferenceStore.load(productAccountId: productAccountId)
    let content = UNMutableNotificationContent()
    applyPresentation(message: sample, content: content, preferences: preferences)
    if !context.isActiveProfile {
      content.title += " · \(context.profileName)"
    }
    content.badge = preferences.isBadgeEnabled ? 1 : nil
    content.sound = preferences.isSoundEnabled ? .default : nil
    content.userInfo = [
      NotificationDeliveryContext.connectionIdUserInfoKey: context.connectionId.rawValue,
      NotificationDeliveryContext.productAccountIdUserInfoKey: productAccountId,
      NotificationDeliveryContext.profileIdUserInfoKey: context.profileId.rawValue,
      NotificationDeliveryContext.settingsDestinationUserInfoKey: "notifications",
    ]
    try await add(
      UNNotificationRequest(
        identifier: identifier(sample.stableProviderMessageId, productAccountId),
        content: content,
        trigger: nil
      ),
      productAccountId: productAccountId
    )
  }

  func deliverGeneric(identifier: String, productAccountId: String) async throws {
    let preferences = preferenceStore.load(productAccountId: productAccountId)
    guard !preferences.quietSchedule.isQuiet(at: now()) else { return }
    let content = UNMutableNotificationContent()
    content.body = "New mail is available."
    content.badge = preferences.isBadgeEnabled ? 1 : nil
    content.sound = preferences.isSoundEnabled ? .default : nil
    content.title = "New mail"
    try await add(
      UNNotificationRequest(
        identifier: self.identifier(identifier, productAccountId),
        content: content,
        trigger: nil
      ),
      productAccountId: productAccountId
    )
  }

  private func add(
    _ request: UNNotificationRequest,
    productAccountId: String
  ) async throws {
    identifierStore.record(identifier: request.identifier, productAccountId: productAccountId)
    try await center.add(request)
  }

  private func applyPresentation(
    message: GmailMessageMetadata,
    content: UNMutableNotificationContent,
    preferences: NotificationDevicePreferences
  ) {
    let sender = message.from?.trimmingCharacters(in: .whitespacesAndNewlines)
    let safeSender = sender?.isEmpty == false ? sender! : "New mail"
    switch preferences.lockScreenContentLevel {
    case .countOnly:
      content.title = "New mail"
      content.body = "1 new message"
    case .sender:
      content.title = safeSender
      content.body = "New mail"
    case .senderAndSubject:
      content.title = safeSender
      content.body = message.subject
    case .fullPreview:
      content.title = safeSender
      content.subtitle = message.subject
      content.body = message.snippet
    }
  }

  private func identifier(_ identifier: String, _ productAccountId: String) -> String {
    "\(productAccountId):\(identifier)"
  }

  private func isOwnedLegacyIdentifier(
    _ identifier: String,
    gmailProviderAccountIdentifiers: Set<String>
  ) -> Bool {
    let prefix = "gmail:"
    guard identifier.hasPrefix(prefix) else { return false }
    let remainder = identifier.dropFirst(prefix.count)
    guard let separator = remainder.firstIndex(of: ":") else { return false }
    return gmailProviderAccountIdentifiers.contains(String(remainder[..<separator]))
  }
}
