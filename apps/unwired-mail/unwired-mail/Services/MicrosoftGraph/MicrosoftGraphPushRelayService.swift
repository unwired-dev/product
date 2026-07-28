import CryptoKit
import Foundation

// swiftlint:disable file_length type_name

struct MicrosoftGraphPushRouteResponse: Decodable, Equatable {
  let routeId: String
}

struct MicrosoftGraphPushRouteConfirmation: Equatable {
  let clientStateDigest: String?
  let expiresAt: Int64
  let routeId: String
  let subscriptionId: String
}

protocol MicrosoftGraphPushRouteTransport {
  func prepareMicrosoftGraphPushRoute(
    clientStateDigest: String,
    identityToken: String,
    opaqueConnectionId: String,
    trustedDeviceId: String
  ) async throws -> MicrosoftGraphPushRouteResponse

  func confirmMicrosoftGraphPushRoute(
    confirmation: MicrosoftGraphPushRouteConfirmation,
    identityToken: String,
    trustedDeviceId: String
  ) async throws -> MicrosoftGraphPushRouteResponse

  func rollbackMicrosoftGraphPushRoute(
    clientStateDigest: String,
    identityToken: String,
    routeId: String,
    trustedDeviceId: String
  ) async throws -> Bool

  func removeMicrosoftGraphPushRoute(
    identityToken: String,
    opaqueConnectionId: String,
    trustedDeviceId: String
  ) async throws -> Bool
}

extension ConvexClient: MicrosoftGraphPushRouteTransport {}

struct MicrosoftGraphPushStatus: Codable, Equatable {
  let clientStateDigest: String?
  let expiresAtMilliseconds: Int64
  let opaqueConnectionId: String
  let providerAccountIdentifier: String
  let routeId: String
  let subscriptionId: String

  init(
    clientStateDigest: String? = nil,
    expiresAtMilliseconds: Int64,
    opaqueConnectionId: String,
    providerAccountIdentifier: String,
    routeId: String,
    subscriptionId: String
  ) {
    self.clientStateDigest = clientStateDigest
    self.expiresAtMilliseconds = expiresAtMilliseconds
    self.opaqueConnectionId = opaqueConnectionId
    self.providerAccountIdentifier = providerAccountIdentifier
    self.routeId = routeId
    self.subscriptionId = subscriptionId
  }
}

protocol MicrosoftGraphPushStatusPersisting {
  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws
  func clearAll(productAccountId: String) throws
  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> MicrosoftGraphPushStatus?
  func load(
    productAccountId: String,
    routeId: String
  ) throws -> MicrosoftGraphPushStatus?
  func loadAll(productAccountId: String) throws -> [MicrosoftGraphPushStatus]
  func save(
    _ status: MicrosoftGraphPushStatus,
    productAccountId: String
  ) throws
}

struct UserDefaultsMicrosoftGraphPushStatusStore: MicrosoftGraphPushStatusPersisting {
  private static let lock = NSLock()
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    try Self.lock.withLock {
      var statuses = try loadStatusesUnlocked(productAccountId: productAccountId)
      statuses[providerAccountIdentifier] = nil
      try saveUnlocked(statuses, productAccountId: productAccountId)
    }
  }

  func clearAll(productAccountId: String) throws {
    Self.lock.withLock {
      defaults.removeObject(forKey: key(productAccountId))
    }
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> MicrosoftGraphPushStatus? {
    try Self.lock.withLock {
      try loadStatusesUnlocked(productAccountId: productAccountId)[providerAccountIdentifier]
    }
  }

  func load(
    productAccountId: String,
    routeId: String
  ) throws -> MicrosoftGraphPushStatus? {
    try Self.lock.withLock {
      try loadStatusesUnlocked(productAccountId: productAccountId).values.first {
        $0.routeId == routeId
      }
    }
  }

  func loadAll(productAccountId: String) throws -> [MicrosoftGraphPushStatus] {
    try Self.lock.withLock {
      Array(try loadStatusesUnlocked(productAccountId: productAccountId).values)
    }
  }

  func save(
    _ status: MicrosoftGraphPushStatus,
    productAccountId: String
  ) throws {
    try Self.lock.withLock {
      var statuses = try loadStatusesUnlocked(productAccountId: productAccountId)
      statuses[status.providerAccountIdentifier] = status
      try saveUnlocked(statuses, productAccountId: productAccountId)
    }
  }

  private func key(_ productAccountId: String) -> String {
    "microsoft-graph-push.\(productAccountId)"
  }

  private func loadStatusesUnlocked(
    productAccountId: String
  ) throws -> [String: MicrosoftGraphPushStatus] {
    guard let data = defaults.data(forKey: key(productAccountId)) else {
      return [:]
    }
    do {
      return try JSONDecoder().decode([String: MicrosoftGraphPushStatus].self, from: data)
    } catch {
      defaults.removeObject(forKey: key(productAccountId))
      return [:]
    }
  }

  private func saveUnlocked(
    _ statuses: [String: MicrosoftGraphPushStatus],
    productAccountId: String
  ) throws {
    defaults.set(
      try JSONEncoder().encode(statuses),
      forKey: key(productAccountId)
    )
  }
}

private struct MicrosoftGraphSubscriptionRequest: Encodable {
  let changeType: String
  let clientState: String
  let expirationDateTime: String
  let notificationUrl: String
  let resource: String
}

private struct MicrosoftGraphSubscriptionRenewalRequest: Encodable {
  let expirationDateTime: String
}

private struct MicrosoftGraphSubscriptionResponse: Decodable {
  let expirationDateTime: String
  let id: String
}

protocol MicrosoftGraphSubscriptionRequesting {
  func create(
    accessToken: String,
    clientState: String,
    expirationDate: Date,
    notificationURL: URL
  ) async throws -> MicrosoftGraphPushStatusProviderResponse

  func renew(
    accessToken: String,
    expirationDate: Date,
    subscriptionId: String
  ) async throws -> MicrosoftGraphPushStatusProviderResponse

  func delete(
    accessToken: String,
    subscriptionId: String
  ) async throws
}

struct MicrosoftGraphPushStatusProviderResponse: Equatable {
  let expirationDate: Date
  let subscriptionId: String
}

struct URLSessionMicrosoftGraphSubscriptionClient: MicrosoftGraphSubscriptionRequesting {
  private let graphBaseURL: URL
  private let session: URLSession

  init(
    graphBaseURL: URL = URL(string: "https://graph.microsoft.com/v1.0")!,
    session: URLSession = .shared
  ) {
    self.graphBaseURL = graphBaseURL
    self.session = session
  }

  func create(
    accessToken: String,
    clientState: String,
    expirationDate: Date,
    notificationURL: URL
  ) async throws -> MicrosoftGraphPushStatusProviderResponse {
    var request = URLRequest(url: graphBaseURL.appending(path: "subscriptions"))
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(
      MicrosoftGraphSubscriptionRequest(
        changeType: "created,updated,deleted",
        clientState: clientState,
        expirationDateTime: Self.dateString(expirationDate),
        notificationUrl: notificationURL.absoluteString,
        resource: "me/messages"
      )
    )
    return try await perform(request, accessToken: accessToken)
  }

  func renew(
    accessToken: String,
    expirationDate: Date,
    subscriptionId: String
  ) async throws -> MicrosoftGraphPushStatusProviderResponse {
    var request = URLRequest(
      url: graphBaseURL.appending(path: "subscriptions/\(subscriptionId)")
    )
    request.httpMethod = "PATCH"
    request.httpBody = try JSONEncoder().encode(
      MicrosoftGraphSubscriptionRenewalRequest(
        expirationDateTime: Self.dateString(expirationDate)
      )
    )
    return try await perform(request, accessToken: accessToken)
  }

  func delete(
    accessToken: String,
    subscriptionId: String
  ) async throws {
    var request = URLRequest(
      url: graphBaseURL.appending(path: "subscriptions/\(subscriptionId)")
    )
    request.httpMethod = "DELETE"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    let (_, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MicrosoftGraphClientError.invalidProviderResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      throw MicrosoftGraphClientError.requestFailed(response.statusCode)
    }
  }

  private func perform(
    _ request: URLRequest,
    accessToken: String
  ) async throws -> MicrosoftGraphPushStatusProviderResponse {
    var request = request
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MicrosoftGraphClientError.invalidProviderResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      throw MicrosoftGraphClientError.requestFailed(response.statusCode)
    }
    let subscription = try JSONDecoder().decode(
      MicrosoftGraphSubscriptionResponse.self,
      from: data
    )
    guard
      let expirationDate = Self.date(from: subscription.expirationDateTime),
      !subscription.id.isEmpty
    else {
      throw MicrosoftGraphClientError.invalidProviderResponse
    }
    return MicrosoftGraphPushStatusProviderResponse(
      expirationDate: expirationDate,
      subscriptionId: subscription.id
    )
  }

  private static func dateString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func date(from value: String) -> Date? {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractionalFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}

enum MicrosoftGraphPushError: LocalizedError {
  case missingNotificationURL

  var errorDescription: String? {
    "Set CONVEX_URL to register Microsoft Graph push notifications."
  }
}

// swiftlint:disable:next type_body_length
struct MicrosoftGraphPushSubscriptionService: MicrosoftGraphPushRegistering {
  static let renewalWindow: TimeInterval = 24 * 60 * 60
  private static let registrationGate = MailboxConnectionSyncGate()
  private static let subscriptionLifetime: TimeInterval = 2 * 24 * 60 * 60

  private let now: () -> Date
  private let siteURL: URL?
  private let statusStore: MicrosoftGraphPushStatusPersisting
  private let subscriptionClient: MicrosoftGraphSubscriptionRequesting
  private let transport: MicrosoftGraphPushRouteTransport

  init(
    now: @escaping () -> Date = Date.init,
    siteURL: URL? = BackendEnvironment.convexSiteURL,
    statusStore: MicrosoftGraphPushStatusPersisting =
      UserDefaultsMicrosoftGraphPushStatusStore(),
    subscriptionClient: MicrosoftGraphSubscriptionRequesting =
      URLSessionMicrosoftGraphSubscriptionClient(),
    transport: MicrosoftGraphPushRouteTransport = ConvexClient()
  ) {
    self.now = now
    self.siteURL = siteURL
    self.statusStore = statusStore
    self.subscriptionClient = subscriptionClient
    self.transport = transport
  }

  func registerOrRenew(
    connection: MailboxConnection,
    accessToken: String,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await Self.registrationGate.withLock(connection.id) {
      try await registerOrRenewLocked(
        connection: connection,
        accessToken: accessToken,
        session: session
      )
    }
  }

  private func registerOrRenewLocked(
    connection: MailboxConnection,
    accessToken: String,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let currentStatus = try statusStore.load(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerMailboxIdentity.value
    )
    if let current = currentStatus,
      Date(timeIntervalSince1970: TimeInterval(current.expiresAtMilliseconds) / 1_000)
        .timeIntervalSince(now()) > Self.renewalWindow
    {
      return
    }

    let expirationDate = now().addingTimeInterval(Self.subscriptionLifetime)
    if let current = currentStatus {
      do {
        let renewed = try await subscriptionClient.renew(
          accessToken: accessToken,
          expirationDate: expirationDate,
          subscriptionId: current.subscriptionId
        )
        try await confirmAndSave(
          current: current,
          providerResponse: renewed,
          session: session
        )
        return
      } catch MicrosoftGraphClientError.requestFailed(404) {
        _ = try? await transport.removeMicrosoftGraphPushRoute(
          identityToken: session.identityToken,
          opaqueConnectionId: current.opaqueConnectionId,
          trustedDeviceId: session.trustedDeviceId
        )
        try statusStore.clear(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: connection.providerMailboxIdentity.value
        )
      }
    }

    try await registerNew(
      connection: connection,
      accessToken: accessToken,
      expirationDate: expirationDate,
      session: session
    )
  }

  private func registerNew(
    connection: MailboxConnection,
    accessToken: String,
    expirationDate: Date,
    session: ProductAccountSessionSnapshot
  ) async throws {
    guard var notificationURL = siteURL?.appending(path: "microsoft-graph/push") else {
      throw MicrosoftGraphPushError.missingNotificationURL
    }
    let clientState = UUID().uuidString
    let clientStateDigest = sha256Hex(clientState)
    let connectionOpaqueId = opaqueConnectionId(connection, session: session)
    let route = try await transport.prepareMicrosoftGraphPushRoute(
      clientStateDigest: clientStateDigest,
      identityToken: session.identityToken,
      opaqueConnectionId: connectionOpaqueId,
      trustedDeviceId: session.trustedDeviceId
    )
    notificationURL.append(queryItems: [URLQueryItem(name: "routeId", value: route.routeId)])
    var createdSubscriptionId: String?
    do {
      let subscription = try await subscriptionClient.create(
        accessToken: accessToken,
        clientState: clientState,
        expirationDate: expirationDate,
        notificationURL: notificationURL
      )
      createdSubscriptionId = subscription.subscriptionId
      try await confirmAndSave(
        current: MicrosoftGraphPushStatus(
          clientStateDigest: clientStateDigest,
          expiresAtMilliseconds: 0,
          opaqueConnectionId: connectionOpaqueId,
          providerAccountIdentifier: connection.providerMailboxIdentity.value,
          routeId: route.routeId,
          subscriptionId: subscription.subscriptionId
        ),
        providerResponse: subscription,
        session: session
      )
    } catch {
      let rolledBack =
        (try? await transport.rollbackMicrosoftGraphPushRoute(
          clientStateDigest: clientStateDigest,
          identityToken: session.identityToken,
          routeId: route.routeId,
          trustedDeviceId: session.trustedDeviceId
        )) == true
      if rolledBack, let createdSubscriptionId {
        try? await subscriptionClient.delete(
          accessToken: accessToken,
          subscriptionId: createdSubscriptionId
        )
      }
      throw error
    }
  }

  func clear(
    accessToken: String?,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await Self.registrationGate.withLock(connection.id) {
      try await clearLocked(
        accessToken: accessToken,
        connection: connection,
        session: session
      )
    }
  }

  private func clearLocked(
    accessToken: String?,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    var firstError: Error?
    let status = try statusStore.load(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerMailboxIdentity.value
    )
    if let status {
      if let accessToken {
        do {
          try await subscriptionClient.delete(
            accessToken: accessToken,
            subscriptionId: status.subscriptionId
          )
        } catch MicrosoftGraphClientError.requestFailed(404) {
        } catch {
          firstError = error
        }
      }
    }
    do {
      _ = try await transport.removeMicrosoftGraphPushRoute(
        identityToken: session.identityToken,
        opaqueConnectionId: status?.opaqueConnectionId
          ?? opaqueConnectionId(connection, session: session),
        trustedDeviceId: session.trustedDeviceId
      )
    } catch {
      firstError = firstError ?? error
    }
    try statusStore.clear(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerMailboxIdentity.value
    )
    if let firstError { throw firstError }
  }

  func clearAll(
    accessTokensByProviderAccountIdentifier: [String: String],
    session: ProductAccountSessionSnapshot
  ) async throws {
    let initialStatuses = try statusStore.loadAll(productAccountId: session.productAccountId)
    let persistedProviderAccountIdentifiers = Set(
      initialStatuses.map(\.providerAccountIdentifier)
    )
    let providerAccountIdentifiers =
      persistedProviderAccountIdentifiers
      .union(accessTokensByProviderAccountIdentifier.keys)
    let connectionIds =
      providerAccountIdentifiers
      .map {
        MailboxConnectionId(
          providerMailboxIdentity: StableProviderMailboxIdentity(
            providerId: .microsoftGraph,
            value: $0
          )
        )
      }
      .sorted { $0.rawValue < $1.rawValue }
    try await withRegistrationLocks(connectionIds[...]) {
      let statuses = try statusStore.loadAll(productAccountId: session.productAccountId)
      try await clearAllLocked(
        accessTokensByProviderAccountIdentifier: accessTokensByProviderAccountIdentifier,
        providerAccountIdentifiers: providerAccountIdentifiers,
        statuses: statuses,
        session: session
      )
    }
  }

  private func clearAllLocked(
    accessTokensByProviderAccountIdentifier: [String: String],
    providerAccountIdentifiers: Set<String>,
    statuses: [MicrosoftGraphPushStatus],
    session: ProductAccountSessionSnapshot
  ) async throws {
    var firstError: Error?
    for providerAccountIdentifier in providerAccountIdentifiers {
      let status = statuses.first {
        $0.providerAccountIdentifier == providerAccountIdentifier
      }
      if let status,
        let accessToken = accessTokensByProviderAccountIdentifier[providerAccountIdentifier]
      {
        do {
          try await subscriptionClient.delete(
            accessToken: accessToken,
            subscriptionId: status.subscriptionId
          )
        } catch MicrosoftGraphClientError.requestFailed(404) {
        } catch {
          firstError = firstError ?? error
        }
      }
      do {
        let connectionId = MailboxConnectionId(
          providerMailboxIdentity: StableProviderMailboxIdentity(
            providerId: .microsoftGraph,
            value: providerAccountIdentifier
          )
        )
        _ = try await transport.removeMicrosoftGraphPushRoute(
          identityToken: session.identityToken,
          opaqueConnectionId: status?.opaqueConnectionId
            ?? opaqueConnectionId(connectionId, session: session),
          trustedDeviceId: session.trustedDeviceId
        )
      } catch {
        firstError = firstError ?? error
      }
    }
    try statusStore.clearAll(productAccountId: session.productAccountId)
    if let firstError { throw firstError }
  }

  private func withRegistrationLocks<T>(
    _ connectionIds: ArraySlice<MailboxConnectionId>,
    operation: @escaping () async throws -> T
  ) async throws -> T {
    guard let connectionId = connectionIds.first else { return try await operation() }
    return try await Self.registrationGate.withLock(connectionId) {
      try await withRegistrationLocks(connectionIds.dropFirst(), operation: operation)
    }
  }

  private func confirmAndSave(
    current: MicrosoftGraphPushStatus,
    providerResponse: MicrosoftGraphPushStatusProviderResponse,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let expiresAt = Int64(providerResponse.expirationDate.timeIntervalSince1970 * 1_000)
    _ = try await transport.confirmMicrosoftGraphPushRoute(
      confirmation: MicrosoftGraphPushRouteConfirmation(
        clientStateDigest: current.clientStateDigest,
        expiresAt: expiresAt,
        routeId: current.routeId,
        subscriptionId: providerResponse.subscriptionId
      ),
      identityToken: session.identityToken,
      trustedDeviceId: session.trustedDeviceId
    )
    try statusStore.save(
      MicrosoftGraphPushStatus(
        clientStateDigest: current.clientStateDigest,
        expiresAtMilliseconds: expiresAt,
        opaqueConnectionId: current.opaqueConnectionId,
        providerAccountIdentifier: current.providerAccountIdentifier,
        routeId: current.routeId,
        subscriptionId: providerResponse.subscriptionId
      ),
      productAccountId: session.productAccountId
    )
  }

  private func opaqueConnectionId(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) -> String {
    opaqueConnectionId(connection.id, session: session)
  }

  private func opaqueConnectionId(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) -> String {
    sha256Hex("\(session.productAccountId)\u{0}\(connectionId.rawValue)")
  }

  private func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

@MainActor
struct MicrosoftGraphPushRenewalHandler {
  private let connectionManager: MailboxConnectionManaging
  private let now: () -> Date
  private let pushService: MailboxPushRegistering
  private let sessionStore: ProductAccountSessionPersisting
  private let statusStore: MicrosoftGraphPushStatusPersisting

  init(
    connectionManager: MailboxConnectionManaging? = nil,
    now: @escaping () -> Date = Date.init,
    pushService: MailboxPushRegistering? = nil,
    sessionStore: ProductAccountSessionPersisting = KeychainProductAccountSessionStore(),
    statusStore: MicrosoftGraphPushStatusPersisting =
      UserDefaultsMicrosoftGraphPushStatusStore()
  ) {
    let adapter = MicrosoftGraphMailboxConnectionAdapter()
    self.connectionManager = connectionManager ?? adapter
    self.now = now
    self.pushService = pushService ?? adapter
    self.sessionStore = sessionStore
    self.statusStore = statusStore
  }

  func handle() async throws -> Bool {
    guard let session = try sessionStore.load() else {
      return false
    }
    let statuses = try statusStore.loadAll(productAccountId: session.productAccountId)
    let renewalBoundary = Int64(
      now().addingTimeInterval(MicrosoftGraphPushSubscriptionService.renewalWindow)
        .timeIntervalSince1970 * 1_000
    )
    let connections = try await connectionManager.loadConnections(session: session)
      .filter { connection in
        connection.providerId == .microsoftGraph
          && connection.authorizationState == .authorized
          && connection.trustedDeviceId == session.trustedDeviceId
          && (statuses.first {
            $0.providerAccountIdentifier == connection.providerMailboxIdentity.value
          }?.expiresAtMilliseconds ?? 0) <= renewalBoundary
      }
    var completedRenewal = false
    var firstError: Error?
    for connection in connections {
      do {
        try await pushService.registerOrRenewPush(connection: connection, session: session)
        completedRenewal = true
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        firstError = firstError ?? error
      }
    }
    if let firstError {
      throw firstError
    }
    return completedRenewal
  }
}

@MainActor
struct MicrosoftGraphPushWakeupHandler {
  private let connectionManager: MailboxConnectionManaging
  private let pushService: MailboxPushRegistering
  private let sessionStore: ProductAccountSessionPersisting
  private let statusStore: MicrosoftGraphPushStatusPersisting
  private let successStore: MailboxSyncSuccessPersisting
  private let syncService: MailboxMetadataSyncing

  init(
    connectionManager: MailboxConnectionManaging? = nil,
    pushService: MailboxPushRegistering? = nil,
    sessionStore: ProductAccountSessionPersisting = KeychainProductAccountSessionStore(),
    statusStore: MicrosoftGraphPushStatusPersisting =
      UserDefaultsMicrosoftGraphPushStatusStore(),
    successStore: MailboxSyncSuccessPersisting? = nil,
    syncService: MailboxMetadataSyncing? = nil
  ) {
    let adapter = MicrosoftGraphMailboxConnectionAdapter()
    self.connectionManager = connectionManager ?? adapter
    self.pushService = pushService ?? adapter
    self.sessionStore = sessionStore
    self.statusStore = statusStore
    self.successStore = successStore ?? UserDefaultsMailboxSyncSuccessStore()
    self.syncService = syncService ?? adapter
  }

  func handle(userInfo: [AnyHashable: Any]) async throws -> Bool {
    guard
      userInfo["provider"] as? String == MailProviderId.microsoftGraph.rawValue,
      let routeId = userInfo["routeId"] as? String,
      !routeId.isEmpty,
      let session = try sessionStore.load(),
      let status = try statusStore.load(
        productAccountId: session.productAccountId,
        routeId: routeId
      )
    else {
      return false
    }
    let connections = try await connectionManager.loadConnections(session: session)
    guard
      let connection = connections.first(where: {
        $0.providerMailboxIdentity.value == status.providerAccountIdentifier
          && $0.trustedDeviceId == session.trustedDeviceId
      })
    else {
      return false
    }
    try? await pushService.registerOrRenewPush(connection: connection, session: session)
    publish(.syncing, connection: connection, session: session)
    do {
      _ = try await syncService.syncRecentInbox(
        connection: connection,
        includingHistoryCandidates: false,
        session: session,
        sinceHistoryId: nil,
        throughHistoryId: nil,
        shouldPersist: { true }
      )
      let successfulSyncAt = Date()
      successStore.save(
        successfulSyncAt,
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
      publish(
        .idle,
        connection: connection,
        session: session,
        successfulSyncAt: successfulSyncAt
      )
      return true
    } catch {
      publish(.failure(for: error), connection: connection, session: session)
      throw error
    }
  }

  private func publish(
    _ phase: MailboxSyncPhase,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    successfulSyncAt: Date? = nil
  ) {
    var userInfo: [AnyHashable: Any] = [
      MailboxSyncNotificationUserInfoKey.connectionId: connection.id.rawValue,
      MailboxSyncNotificationUserInfoKey.phase: phase,
      MailboxSyncNotificationUserInfoKey.productAccountId: session.productAccountId,
      MailboxSyncNotificationUserInfoKey.reloadObservedMetadata: true,
    ]
    userInfo[MailboxSyncNotificationUserInfoKey.successfulSyncAt] = successfulSyncAt
    NotificationCenter.default.post(
      name: .mailboxMetadataDidSynchronize,
      object: nil,
      userInfo: userInfo
    )
  }
}
