import UserNotifications

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
  func migrateLegacyIdentifiers(productAccountId: String) async
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

protocol UserNotificationCenterClient {
  func add(_ request: UNNotificationRequest) async throws
  func deliveredNotificationRequestsForOwnership() async -> [UNNotificationRequest]
  func pendingNotificationRequestsForOwnership() async -> [UNNotificationRequest]
  func removeDeliveredNotifications(withIdentifiers identifiers: [String])
  func removePendingNotificationRequests(withIdentifiers identifiers: [String])
  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
}

extension UserNotificationCenterClient {
  func deliveredNotificationRequestsForOwnership() async -> [UNNotificationRequest] { [] }
  func pendingNotificationRequestsForOwnership() async -> [UNNotificationRequest] { [] }
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
  UserNotificationClearing
{
  private let center: UserNotificationCenterClient
  private let identifierStore: UserNotificationIdentifierPersisting

  init(
    center: UserNotificationCenterClient = UNUserNotificationCenter.current(),
    identifierStore: UserNotificationIdentifierPersisting =
      UserDefaultsNotificationIdentifierStore()
  ) {
    self.center = center
    self.identifierStore = identifierStore
  }

  func requestAuthorization() async throws -> Bool {
    try await center.requestAuthorization(options: [.alert, .badge, .sound])
  }

  func migrateLegacyIdentifiers(productAccountId: String) async {
    let knownIdentifiers = identifierStore.allIdentifiers()
    async let deliveredRequests = center.deliveredNotificationRequestsForOwnership()
    async let pendingRequests = center.pendingNotificationRequestsForOwnership()
    let legacyIdentifiers = await (deliveredRequests + pendingRequests)
      .map(\.identifier)
      .filter { isLegacyIdentifier($0) && !knownIdentifiers.contains($0) }
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
    let content = UNMutableNotificationContent()
    content.body = "A message matched your notification rules."
    content.sound = .default
    content.title = "New mail"
    try await add(
      UNNotificationRequest(
        identifier: identifier(message.stableProviderMessageId, productAccountId),
        content: content,
        trigger: nil
      ),
      productAccountId: productAccountId
    )
  }

  func deliverGeneric(identifier: String, productAccountId: String) async throws {
    let content = UNMutableNotificationContent()
    content.body = "New mail is available."
    content.sound = .default
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

  private func identifier(_ identifier: String, _ productAccountId: String) -> String {
    "\(productAccountId):\(identifier)"
  }

  private func isLegacyIdentifier(_ identifier: String) -> Bool {
    identifier.hasPrefix("gmail:") || identifier.hasPrefix("gmail-generic-fallback:")
  }
}
