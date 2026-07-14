import Foundation

// swiftlint:disable file_length

#if canImport(UIKit)
  import OSLog
  import UIKit
#endif

struct GmailPushWatchStatus: Codable, Equatable {
  let expirationMilliseconds: Int64
  let historyId: String
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

protocol GmailPushWatchRegistering {
  func registerOrRenew(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailPushWatchStatus
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

struct GmailPushWatchService: GmailPushWatchRegistering {
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
    if let existing = try currentWatch(
      connection: connection,
      productSession: productSession
    ) {
      if try await verifyWatch(existing, productSession: productSession) {
        return existing
      }
    }

    let topicName = try requiredTopicName()
    let tokens = try await verifiedTokens(
      connection: connection,
      productSession: productSession
    )
    let status = try await registerWatch(
      accessToken: tokens.accessToken,
      topicName: topicName
    )
    try store.save(
      status,
      productAccountId: productSession.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    _ = try await verifyWatch(status, productSession: productSession)
    return status
  }

  private func verifyWatch(
    _ status: GmailPushWatchStatus,
    productSession: ProductAccountSessionSnapshot
  ) async throws -> Bool {
    let response = try await verificationTransport.verifyGmailPushWatch(
      historyId: status.historyId,
      identityToken: productSession.identityToken,
      trustedDeviceId: productSession.trustedDeviceId
    )
    return response.verified
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
  private let sessionStore: ProductAccountSessionPersisting
  private let syncService: GmailMessageMetadataSyncing

  init(
    connectionStore: GmailPushConnectionPersisting = KeychainGmailPushConnectionStore(),
    sessionStore: ProductAccountSessionPersisting = KeychainProductAccountSessionStore(),
    syncService: GmailMessageMetadataSyncing = GmailMessageMetadataService()
  ) {
    self.connectionStore = connectionStore
    self.sessionStore = sessionStore
    self.syncService = syncService
  }

  func handle(userInfo: [AnyHashable: Any]) async throws -> Bool {
    guard
      userInfo["provider"] as? String == "gmail",
      let historyId = userInfo["historyId"] as? String,
      !historyId.isEmpty,
      let productSession = try sessionStore.load(),
      let connection = try connectionStore.load(
        productAccountId: productSession.productAccountId
      ),
      connection.provider == "gmail",
      connection.trustedDeviceId == productSession.trustedDeviceId
    else {
      return false
    }

    _ = try await syncService.syncInbox(
      connection: connection,
      session: productSession
    )
    return true
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

  var errorDescription: String? {
    switch self {
    case .invalidWatchResponse:
      return "Gmail returned an invalid push watch response."
    case .missingTopicName:
      return "Gmail Pub/Sub topic is not configured."
    case .watchRegistrationFailed:
      return "Gmail push watch registration failed."
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
    func application(
      _: UIApplication,
      didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
      Task { @MainActor in
        guard let session = try? ProductAccountSessionStore.load() else {
          return
        }
        #if DEBUG
          let environment = DevicePushEnvironment.sandbox
        #else
          let environment = DevicePushEnvironment.production
        #endif
        do {
          try await DevicePushRegistrationService(environment: environment).register(
            deviceToken: deviceToken,
            session: session
          )
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
