import Foundation

// swiftlint:disable file_length

#if canImport(UIKit)
  import OSLog
  import UIKit
#endif

struct GmailPushWatchStatus: Codable, Equatable {
  let expirationMilliseconds: Int64
  let historyId: String
  let latestSyncedHistoryId: String?
  let routeId: String?

  init(
    expirationMilliseconds: Int64,
    historyId: String,
    latestSyncedHistoryId: String? = nil,
    routeId: String? = nil
  ) {
    self.expirationMilliseconds = expirationMilliseconds
    self.historyId = historyId
    self.latestSyncedHistoryId = latestSyncedHistoryId
    self.routeId = routeId
  }
}

func gmailHistoryIdIsNewer(_ candidate: String, than current: String) -> Bool {
  guard
    candidate.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
    current.unicodeScalars.allSatisfy({ (48...57).contains($0.value) })
  else {
    return false
  }
  let normalizedCandidate = String(candidate.drop(while: { $0 == "0" }))
  let normalizedCurrent = String(current.drop(while: { $0 == "0" }))
  let comparableCandidate = normalizedCandidate.isEmpty ? "0" : normalizedCandidate
  let comparableCurrent = normalizedCurrent.isEmpty ? "0" : normalizedCurrent
  if comparableCandidate.count != comparableCurrent.count {
    return comparableCandidate.count > comparableCurrent.count
  }
  return comparableCurrent < comparableCandidate
}

private func gmailPushWatchIsSameRoute(
  _ candidate: GmailPushWatchStatus,
  as expected: GmailPushWatchStatus
) -> Bool {
  candidate.expirationMilliseconds == expected.expirationMilliseconds
    && candidate.historyId == expected.historyId
    && candidate.routeId == expected.routeId
}

protocol GmailPushWatchPersisting {
  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws

  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailPushWatchStatus?

  func save(
    _ status: GmailPushWatchStatus,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws
}

protocol GmailPushConnectionPersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> GmailProviderConnectionStatus?
  func save(
    _ connection: GmailProviderConnectionStatus,
    productAccountId: String
  ) throws
}

@MainActor
protocol GmailPushNotificationReceiptPersisting {
  func claim(
    _ message: GmailMessageMetadata,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailPushNotificationReceiptClaim
  func complete(
    _ message: GmailMessageMetadata,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws
  func release(
    _ message: GmailMessageMetadata,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws
}

enum GmailPushNotificationReceiptClaim {
  case claimed
  case completed
  case inFlight
}

@MainActor
private final class GmailPushInFlightReceiptStore {
  static let shared = GmailPushInFlightReceiptStore()

  private var receiptKeys: Set<String> = []

  func claim(_ key: String) -> Bool {
    receiptKeys.insert(key).inserted
  }

  func release(_ key: String) {
    receiptKeys.remove(key)
  }
}

protocol GmailPushWatchRegistering {
  func registerOrRenew(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailPushWatchStatus
}

protocol GmailPushWatchStopping {
  func stop(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot,
    tokens: GmailProviderTokens?
  ) async throws
}

extension GmailPushWatchStopping {
  func stop(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await stop(connection: connection, session: session, tokens: nil)
  }
}

protocol GmailPushVerificationTransport {
  func verifyGmailPushWatch(
    historyId: String,
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> GmailPushVerificationResponse
}

protocol GmailProviderTokenRefreshing {
  func refreshProviderTokens(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderTokens
}

struct UserDefaultsGmailPushWatchStore: GmailPushWatchPersisting {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    defaults.removeObject(forKey: key(productAccountId, providerAccountIdentifier))
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailPushWatchStatus? {
    guard let data = defaults.data(forKey: key(productAccountId, providerAccountIdentifier)) else {
      return nil
    }
    return try JSONDecoder().decode(GmailPushWatchStatus.self, from: data)
  }

  func save(
    _ status: GmailPushWatchStatus,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    defaults.set(
      try JSONEncoder().encode(status),
      forKey: key(productAccountId, providerAccountIdentifier)
    )
  }

  private func key(_ productAccountId: String, _ providerAccountIdentifier: String) -> String {
    "gmail-push-watch.\(gmailSafeFileComponent(productAccountId)).\(gmailSafeFileComponent(providerAccountIdentifier))"
  }
}

struct GmailPushNotificationReceiptStore: GmailPushNotificationReceiptPersisting {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func claim(
    _ message: GmailMessageMetadata,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailPushNotificationReceiptClaim {
    let receiptKey = receiptKey(message, productAccountId, providerAccountIdentifier)
    guard
      !receipts(productAccountId, providerAccountIdentifier)
        .contains(message.stableProviderMessageId)
    else { return .completed }
    return GmailPushInFlightReceiptStore.shared.claim(receiptKey) ? .claimed : .inFlight
  }

  func complete(
    _ message: GmailMessageMetadata,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    var value = receipts(productAccountId, providerAccountIdentifier)
    value.insert(message.stableProviderMessageId)
    defaults.set(Array(value), forKey: key(productAccountId, providerAccountIdentifier))
    GmailPushInFlightReceiptStore.shared.release(
      receiptKey(message, productAccountId, providerAccountIdentifier)
    )
  }

  func release(
    _ message: GmailMessageMetadata,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    GmailPushInFlightReceiptStore.shared.release(
      receiptKey(message, productAccountId, providerAccountIdentifier)
    )
  }

  private func key(_ productAccountId: String, _ providerAccountIdentifier: String) -> String {
    "gmail-push-notification-receipts.\(gmailSafeFileComponent(productAccountId))."
      + gmailSafeFileComponent(providerAccountIdentifier)
  }

  private func receiptKey(
    _ message: GmailMessageMetadata,
    _ productAccountId: String,
    _ providerAccountIdentifier: String
  ) -> String {
    "\(key(productAccountId, providerAccountIdentifier)).\(message.stableProviderMessageId)"
  }

  private func receipts(_ productAccountId: String, _ providerAccountIdentifier: String) -> Set<
    String
  > {
    Set(defaults.stringArray(forKey: key(productAccountId, providerAccountIdentifier)) ?? [])
  }
}

private struct NoopGmailPushNotificationReceiptStore: GmailPushNotificationReceiptPersisting {
  func claim(
    _: GmailMessageMetadata,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> GmailPushNotificationReceiptClaim { .claimed }

  func complete(
    _: GmailMessageMetadata,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}

  func release(
    _: GmailMessageMetadata,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}
}

struct KeychainGmailPushConnectionStore: GmailPushConnectionPersisting {
  private let service = "private-email.gmail-push-connection"

  func clear(productAccountId: String) throws {
    try KeychainStore.delete(service: service, account: key(productAccountId))
  }

  func load(productAccountId: String) throws -> GmailProviderConnectionStatus? {
    guard
      let json = try KeychainStore.readString(service: service, account: key(productAccountId)),
      let data = json.data(using: .utf8)
    else {
      return nil
    }
    return try JSONDecoder().decode(GmailProviderConnectionStatus.self, from: data)
  }

  func save(
    _ connection: GmailProviderConnectionStatus,
    productAccountId: String
  ) throws {
    let data = try JSONEncoder().encode(connection)
    guard let json = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(
      json,
      service: service,
      account: key(productAccountId),
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }

  private func key(_ productAccountId: String) -> String {
    "gmail-push-connection.\(gmailSafeFileComponent(productAccountId))"
  }
}

struct GmailPushWatchService: GmailPushWatchRegistering, GmailPushWatchStopping {
  private static let renewalLeadTimeMilliseconds: Int64 = 86_400_000

  private let gmailBaseURL: URL
  private let connectionStore: GmailPushConnectionPersisting
  private let nowMilliseconds: () -> Int64
  private let session: URLSession
  private let store: GmailPushWatchPersisting
  private let tokenRefresher: GmailProviderTokenRefreshing
  private let topicName: String?
  private let verificationTransport: GmailPushVerificationTransport

  init(
    connectionStore: GmailPushConnectionPersisting = KeychainGmailPushConnectionStore(),
    gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1")!,
    nowMilliseconds: @escaping () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    session: URLSession = .shared,
    store: GmailPushWatchPersisting = UserDefaultsGmailPushWatchStore(),
    tokenRefresher: GmailProviderTokenRefreshing = GmailMessageMetadataService(),
    topicName: String? = GmailPushTopicConfiguration.value(),
    verificationTransport: GmailPushVerificationTransport = ConvexClient()
  ) {
    self.connectionStore = connectionStore
    self.gmailBaseURL = gmailBaseURL
    self.nowMilliseconds = nowMilliseconds
    self.session = session
    self.store = store
    self.tokenRefresher = tokenRefresher
    self.topicName = topicName
    self.verificationTransport = verificationTransport
  }

  func registerOrRenew(
    connection: GmailProviderConnectionStatus,
    session productSession: ProductAccountSessionSnapshot
  ) async throws -> GmailPushWatchStatus {
    try connectionStore.save(connection, productAccountId: productSession.productAccountId)
    let previousWatch = try store.load(
      productAccountId: productSession.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let existing = try currentWatch(
      connection: connection,
      productSession: productSession
    )
    if let existing {
      let verification = try await verifyWatch(existing, productSession: productSession)
      let verifiedStatus = statusWithRoute(existing, routeId: verification.routeId)
      try store.save(
        verifiedStatus,
        productAccountId: productSession.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      if verification.verified {
        return verifiedStatus
      }
    }

    let topicName = try requiredTopicName()
    let tokens = try await verifiedTokens(
      connection: connection,
      productSession: productSession
    )
    let registeredStatus = try await registerWatch(
      accessToken: tokens.accessToken,
      topicName: topicName
    )
    let status = GmailPushWatchStatus(
      expirationMilliseconds: registeredStatus.expirationMilliseconds,
      historyId: registeredStatus.historyId,
      latestSyncedHistoryId: previousWatch?.latestSyncedHistoryId ?? previousWatch?.historyId
    )
    try store.save(
      status,
      productAccountId: productSession.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let verification = try await verifyWatch(status, productSession: productSession)
    let verifiedStatus = statusWithRoute(status, routeId: verification.routeId)
    try store.save(
      verifiedStatus,
      productAccountId: productSession.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    return verifiedStatus
  }

  func stop(
    connection: GmailProviderConnectionStatus,
    session productSession: ProductAccountSessionSnapshot,
    tokens providedTokens: GmailProviderTokens?
  ) async throws {
    let tokens: GmailProviderTokens
    if let providedTokens {
      tokens = providedTokens
    } else {
      tokens = try await verifiedTokens(
        connection: connection,
        productSession: productSession
      )
    }
    var request = URLRequest(
      url: gmailBaseURL.appendingPathComponent("users/me/stop")
    )
    request.httpMethod = "POST"
    request.setValue(
      "Bearer \(tokens.accessToken)",
      forHTTPHeaderField: "Authorization"
    )

    let (_, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailPushRelayError.watchStopFailed
    }
  }

  private func verifyWatch(
    _ status: GmailPushWatchStatus,
    productSession: ProductAccountSessionSnapshot
  ) async throws -> GmailPushVerificationResponse {
    try await verificationTransport.verifyGmailPushWatch(
      historyId: status.historyId,
      identityToken: productSession.identityToken,
      trustedDeviceId: productSession.trustedDeviceId
    )
  }

  private func statusWithRoute(
    _ status: GmailPushWatchStatus,
    routeId: String
  ) -> GmailPushWatchStatus {
    GmailPushWatchStatus(
      expirationMilliseconds: status.expirationMilliseconds,
      historyId: status.historyId,
      latestSyncedHistoryId: status.latestSyncedHistoryId,
      routeId: routeId
    )
  }

  private func currentWatch(
    connection: GmailProviderConnectionStatus,
    productSession: ProductAccountSessionSnapshot
  ) throws -> GmailPushWatchStatus? {
    guard
      let status = try store.load(
        productAccountId: productSession.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      status.expirationMilliseconds - nowMilliseconds()
        > Self.renewalLeadTimeMilliseconds
    else {
      return nil
    }
    return status
  }

  private func requiredTopicName() throws -> String {
    guard let topicName, !topicName.isEmpty else {
      throw GmailPushRelayError.missingTopicName
    }
    return topicName
  }

  private func verifiedTokens(
    connection: GmailProviderConnectionStatus,
    productSession: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderTokens {
    try await tokenRefresher.refreshProviderTokens(
      connection: connection,
      session: productSession
    )
  }

  private func registerWatch(
    accessToken: String,
    topicName: String
  ) async throws -> GmailPushWatchStatus {
    var request = URLRequest(
      url: gmailBaseURL.appendingPathComponent("users/me/watch")
    )
    request.httpMethod = "POST"
    request.setValue(
      "Bearer \(accessToken)",
      forHTTPHeaderField: "Authorization"
    )
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      GmailWatchRequest(
        labelFilterBehavior: "include",
        labelIds: ["INBOX"],
        topicName: topicName
      )
    )

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailPushRelayError.watchRegistrationFailed
    }

    let watchResponse = try JSONDecoder().decode(GmailWatchResponse.self, from: data)
    guard let expirationMilliseconds = Int64(watchResponse.expiration) else {
      throw GmailPushRelayError.invalidWatchResponse
    }
    let status = GmailPushWatchStatus(
      expirationMilliseconds: expirationMilliseconds,
      historyId: watchResponse.historyId
    )
    return status
  }
}

struct DevicePushRegistrationResponse: Decodable, Equatable {
  let registered: Bool
}

struct GmailPushVerificationResponse: Decodable, Equatable {
  let routeId: String
  let verified: Bool
}

protocol DevicePushRegistrationTransport {
  func registerDevicePush(
    apnsEnvironment: String,
    apnsToken: String,
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> DevicePushRegistrationResponse

  func unregisterDevicePush(
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> DevicePushRegistrationResponse
}

protocol DevicePushUnregistering {
  func unregister(session: ProductAccountSessionSnapshot) async throws
}

enum DevicePushEnvironment: String {
  case production
  case sandbox
}

struct DevicePushRegistrationService {
  private let environment: DevicePushEnvironment
  private let transport: DevicePushRegistrationTransport

  init(
    environment: DevicePushEnvironment,
    transport: DevicePushRegistrationTransport = ConvexClient()
  ) {
    self.environment = environment
    self.transport = transport
  }

  func register(
    deviceToken: Data,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    _ = try await transport.registerDevicePush(
      apnsEnvironment: environment.rawValue,
      apnsToken: token,
      identityToken: session.identityToken,
      trustedDeviceId: session.trustedDeviceId
    )
  }
}

@MainActor
final class DevicePushRegistrationRetrier {
  private var deviceToken: Data?
  private let registrationService: DevicePushRegistrationService

  init(
    environment: DevicePushEnvironment,
    transport: DevicePushRegistrationTransport = ConvexClient()
  ) {
    registrationService = DevicePushRegistrationService(
      environment: environment,
      transport: transport
    )
  }

  func remember(deviceToken: Data) {
    self.deviceToken = deviceToken
  }

  func retry(session: ProductAccountSessionSnapshot) async throws {
    guard let deviceToken else { return }
    try await registrationService.register(deviceToken: deviceToken, session: session)
  }
}

extension ConvexClient: DevicePushRegistrationTransport {}
extension ConvexClient: GmailPushVerificationTransport {}

struct DevicePushUnregistrationService: DevicePushUnregistering {
  private let transport: DevicePushRegistrationTransport

  init(transport: DevicePushRegistrationTransport = ConvexClient()) {
    self.transport = transport
  }

  func unregister(session: ProductAccountSessionSnapshot) async throws {
    _ = try await transport.unregisterDevicePush(
      identityToken: session.identityToken,
      trustedDeviceId: session.trustedDeviceId
    )
  }
}

@MainActor
struct GmailPushWakeupHandler {
  private let connectionStore: GmailPushConnectionPersisting
  private let hasProcessingTimeRemaining: @MainActor () -> Bool
  private let notificationAuthorization: NotificationAuthorizationRequesting
  private let notificationDelivery: CategoryAwareNotificationDelivering
  private let notificationReceiptStore: GmailPushNotificationReceiptPersisting
  private let notificationRuleSync: NotificationRuleSyncing
  private let sessionStore: ProductAccountSessionPersisting
  private let syncService: GmailMessageMetadataSyncing
  private let watchStore: GmailPushWatchPersisting

  init(
    connectionStore: GmailPushConnectionPersisting = KeychainGmailPushConnectionStore(),
    hasProcessingTimeRemaining: @escaping @MainActor () -> Bool = {
      #if canImport(UIKit)
        UIApplication.shared.backgroundTimeRemaining > 1
      #else
        true
      #endif
    },
    notificationDelivery: CategoryAwareNotificationDelivering = UserNotificationService(),
    notificationAuthorization: NotificationAuthorizationRequesting? = nil,
    notificationReceiptStore: GmailPushNotificationReceiptPersisting? = nil,
    notificationRuleSync: NotificationRuleSyncing = NotificationRuleSyncService(),
    sessionStore: ProductAccountSessionPersisting = KeychainProductAccountSessionStore(),
    syncService: GmailMessageMetadataSyncing = GmailMessageMetadataService(),
    watchStore: GmailPushWatchPersisting = UserDefaultsGmailPushWatchStore()
  ) {
    self.connectionStore = connectionStore
    self.hasProcessingTimeRemaining = hasProcessingTimeRemaining
    self.notificationDelivery = notificationDelivery
    self.notificationAuthorization =
      notificationAuthorization
      ?? (notificationDelivery as? NotificationAuthorizationRequesting)
      ?? UserNotificationService()
    self.notificationReceiptStore =
      notificationReceiptStore
      ?? (notificationDelivery is UserNotificationService
        ? GmailPushNotificationReceiptStore()
        : NoopGmailPushNotificationReceiptStore())
    self.notificationRuleSync = notificationRuleSync
    self.sessionStore = sessionStore
    self.syncService = syncService
    self.watchStore = watchStore
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func handle(userInfo: [AnyHashable: Any]) async throws -> Bool {
    guard
      userInfo["provider"] as? String == "gmail",
      let historyId = userInfo["historyId"] as? String,
      !historyId.isEmpty,
      let routeId = userInfo["routeId"] as? String,
      !routeId.isEmpty,
      let productSession = try sessionStore.load(),
      let connection = try connectionStore.load(
        productAccountId: productSession.productAccountId
      ),
      connection.provider == "gmail",
      connection.trustedDeviceId == productSession.trustedDeviceId,
      let watchStatus = try watchStore.load(
        productAccountId: productSession.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      watchStatus.routeId == routeId,
      gmailHistoryIdIsNewer(
        historyId,
        than: watchStatus.latestSyncedHistoryId ?? watchStatus.historyId
      )
    else {
      return false
    }

    let currentWatchForRoute: () -> GmailPushWatchStatus? = {
      guard
        let currentSession = try? sessionStore.load(),
        currentSession.appleUserIdentifier == productSession.appleUserIdentifier,
        currentSession.productAccountId == productSession.productAccountId,
        currentSession.trustedDeviceId == productSession.trustedDeviceId,
        let currentConnection = try? connectionStore.load(
          productAccountId: productSession.productAccountId
        ),
        currentConnection == connection,
        let currentWatch = try? watchStore.load(
          productAccountId: productSession.productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        ),
        gmailPushWatchIsSameRoute(currentWatch, as: watchStatus)
      else {
        return nil
      }
      return currentWatch
    }
    let routeIsCurrent = {
      currentWatchForRoute() != nil
    }

    let notificationRules = try await failClosed {
      try await notificationRuleSync.loadRules(session: productSession).rules
    }
    guard let notificationRules else { return false }
    guard currentWatchForRoute() != nil else { return false }
    let syncResult: GmailMetadataSyncResult
    do {
      syncResult = try await syncService.syncRecentInbox(
        connection: connection,
        includingHistoryCandidates: !notificationRules.categoryIds.isEmpty,
        session: productSession,
        sinceHistoryId: watchStatus.latestSyncedHistoryId ?? watchStatus.historyId,
        throughHistoryId: historyId,
        shouldPersist: routeIsCurrent
      )
    } catch GmailMessageMetadataSyncError.staleLocalConnection {
      return false
    }
    guard currentWatchForRoute() != nil else { return false }
    let currentNotificationRules = try await failClosed {
      try await notificationRuleSync.loadRules(session: productSession).rules
    }
    guard let currentNotificationRules else { return false }
    guard currentWatchForRoute() != nil else { return false }
    let canAdvanceWatermark =
      currentNotificationRules.categoryIds.isEmpty || !syncResult.hasUnlistedNewMessages
    guard
      try await deliverCategoryAwareNotifications(
        for: syncResult.messages,
        including: syncResult.newMessageIds,
        connection: connection,
        productAccountId: productSession.productAccountId,
        rules: currentNotificationRules,
        routeIsCurrent: routeIsCurrent,
        watermarkIsCurrent: {
          guard let currentWatch = currentWatchForRoute() else { return false }
          return gmailHistoryIdIsNewer(
            historyId,
            than: currentWatch.latestSyncedHistoryId ?? currentWatch.historyId
          )
        }
      )
    else { return false }
    guard canAdvanceWatermark else { return false }
    guard let currentWatch = currentWatchForRoute() else { return false }
    let currentWatermark = currentWatch.latestSyncedHistoryId ?? currentWatch.historyId
    let nextWatermark =
      gmailHistoryIdIsNewer(historyId, than: currentWatermark)
      ? historyId : currentWatermark
    try watchStore.save(
      GmailPushWatchStatus(
        expirationMilliseconds: currentWatch.expirationMilliseconds,
        historyId: currentWatch.historyId,
        latestSyncedHistoryId: nextWatermark,
        routeId: currentWatch.routeId
      ),
      productAccountId: productSession.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    return true
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length function_parameter_count
  private func deliverCategoryAwareNotifications(
    for messages: [GmailMessageMetadata],
    including newMessageIds: Set<String>?,
    connection: GmailProviderConnectionStatus,
    productAccountId: String,
    rules: NotificationRules?,
    routeIsCurrent: () -> Bool,
    watermarkIsCurrent: () -> Bool
  ) async throws -> Bool {
    guard let rules else { return false }
    guard !rules.categoryIds.isEmpty else { return true }
    guard let newMessageIds else { return false }
    var notificationAuthorizationGranted = false
    for message in messages
    where !message.isHistorical
      && newMessageIds.contains(message.providerMessageId)
      && message.categoryId.map(rules.allows(categoryId:)) == true
    {
      guard
        routeIsCurrent(),
        watermarkIsCurrent(),
        hasProcessingTimeRemaining()
      else { return false }
      switch try notificationReceiptStore.claim(
        message,
        productAccountId: productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) {
      case .claimed:
        break
      case .completed:
        continue
      case .inFlight:
        return false
      }
      if !notificationAuthorizationGranted {
        guard try await notificationAuthorization.requestAuthorization() else {
          try notificationReceiptStore.release(
            message,
            productAccountId: productAccountId,
            providerAccountIdentifier: connection.providerAccountIdentifier
          )
          return false
        }
        notificationAuthorizationGranted = true
      }
      guard
        routeIsCurrent(),
        watermarkIsCurrent(),
        hasProcessingTimeRemaining()
      else {
        try notificationReceiptStore.release(
          message,
          productAccountId: productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        )
        return false
      }
      do {
        try await notificationDelivery.deliver(message: message)
        try notificationReceiptStore.complete(
          message,
          productAccountId: productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        )
      } catch is CancellationError {
        try notificationReceiptStore.release(
          message,
          productAccountId: productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        )
        throw CancellationError()
      } catch {
        try notificationReceiptStore.release(
          message,
          productAccountId: productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        )
        // Visible notification delivery fails closed without adding a generic fallback.
        return false
      }
    }
    return true
  }

  private func failClosed<Value>(
    _ operation: () async throws -> Value
  ) async throws -> Value? {
    do {
      return try await operation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return nil
    }
  }
}

enum GmailPushTopicConfiguration {
  static let infoDictionaryKey = "GmailPubSubTopic"

  static func value(bundle: Bundle = .main) -> String? {
    let value =
      ProcessInfo.processInfo.environment["GMAIL_PUBSUB_TOPIC"]
      ?? DotEnvFile.value(for: "GMAIL_PUBSUB_TOPIC")
      ?? bundle.object(forInfoDictionaryKey: infoDictionaryKey) as? String
    guard let value, !value.isEmpty, !value.contains("$(") else {
      return nil
    }
    return value
  }
}

enum GmailPushRelayError: LocalizedError, Equatable {
  case invalidWatchResponse
  case missingTopicName
  case watchRegistrationFailed
  case watchStopFailed

  var errorDescription: String? {
    switch self {
    case .invalidWatchResponse:
      return "Gmail returned an invalid push watch response."
    case .missingTopicName:
      return "Gmail Pub/Sub topic is not configured."
    case .watchRegistrationFailed:
      return "Gmail push watch registration failed."
    case .watchStopFailed:
      return "Gmail push watch could not be stopped."
    }
  }
}

private struct GmailWatchRequest: Encodable {
  let labelFilterBehavior: String
  let labelIds: [String]
  let topicName: String
}

private struct GmailWatchResponse: Decodable {
  let expiration: String
  let historyId: String
}

#if canImport(UIKit)
  private let pushRegistrationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.unwired.mail",
    category: "push-registration"
  )

  @MainActor
  final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate {
    private let registrationRetrier: DevicePushRegistrationRetrier

    override init() {
      #if DEBUG
        registrationRetrier = DevicePushRegistrationRetrier(environment: .sandbox)
      #else
        registrationRetrier = DevicePushRegistrationRetrier(environment: .production)
      #endif
      super.init()
    }

    func application(
      _: UIApplication,
      didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
      registrationRetrier.remember(deviceToken: deviceToken)
      retryDevicePushRegistration()
    }

    func applicationDidBecomeActive(_: UIApplication) {
      retryDevicePushRegistration()
    }

    private func retryDevicePushRegistration() {
      Task { @MainActor in
        guard let session = try? ProductAccountSessionStore.load() else {
          return
        }
        do {
          try await registrationRetrier.retry(session: session)
        } catch {
          pushRegistrationLogger.error(
            "APNs device-token registration failed: \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }

    func application(
      _: UIApplication,
      didReceiveRemoteNotification userInfo: [AnyHashable: Any],
      fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
      Task { @MainActor in
        do {
          let handled = try await GmailPushWakeupHandler().handle(userInfo: userInfo)
          completionHandler(handled ? .newData : .noData)
        } catch {
          completionHandler(.failed)
        }
      }
    }
  }

  @MainActor
  func requestDevicePushRegistration() {
    UIApplication.shared.registerForRemoteNotifications()
  }
#endif
