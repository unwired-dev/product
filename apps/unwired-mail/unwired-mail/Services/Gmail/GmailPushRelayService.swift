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
  func clearAll(productAccountId: String) throws

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

extension GmailPushWatchPersisting {
  func clearAll(productAccountId _: String) throws {}
}

protocol GmailPushConnectionPersisting {
  func clear(productAccountId: String) throws
  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws
  func clearAll(productAccountId: String) throws
  func load(productAccountId: String) throws -> GmailProviderConnectionStatus?
  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailProviderConnectionStatus?
  func loadAll(productAccountId: String) throws -> [GmailProviderConnectionStatus]
  func save(
    _ connection: GmailProviderConnectionStatus,
    productAccountId: String
  ) throws
}

extension GmailPushConnectionPersisting {
  func clear(
    productAccountId: String,
    providerAccountIdentifier _: String
  ) throws {
    try clear(productAccountId: productAccountId)
  }

  func clearAll(productAccountId: String) throws {
    try clear(productAccountId: productAccountId)
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier _: String
  ) throws -> GmailProviderConnectionStatus? {
    try load(productAccountId: productAccountId)
  }

  func loadAll(productAccountId: String) throws -> [GmailProviderConnectionStatus] {
    if let connection = try load(productAccountId: productAccountId) {
      return [connection]
    }
    return []
  }
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

protocol GmailPushEligibilityPersisting {
  func record(
    _ messages: [GmailMessageMetadata],
    throughHistoryId: String,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws
  func eligibleStableMessageIds(
    after historyId: String,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> Set<String>
  func discard(
    through historyId: String,
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
    gmailIdentityToken: String,
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
    defaults.removeObject(forKey: legacyKey(productAccountId, providerAccountIdentifier))
  }

  func clearAll(productAccountId: String) throws {
    let prefixes = [
      "gmail-push-watch.\(gmailSafeFileComponent(productAccountId)).",
      "gmail-push-watch.\(legacyGmailSafeFileComponent(productAccountId)).",
    ]
    for key in defaults.dictionaryRepresentation().keys
    where prefixes.contains(where: { key.hasPrefix($0) }) {
      defaults.removeObject(forKey: key)
    }
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailPushWatchStatus? {
    let scopedKey = key(productAccountId, providerAccountIdentifier)
    if let data = defaults.data(forKey: scopedKey) {
      return try JSONDecoder().decode(GmailPushWatchStatus.self, from: data)
    }
    let previousKey = legacyKey(productAccountId, providerAccountIdentifier)
    guard let data = defaults.data(forKey: previousKey) else {
      return nil
    }
    let status = try JSONDecoder().decode(GmailPushWatchStatus.self, from: data)
    try save(
      status,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    defaults.removeObject(forKey: previousKey)
    return status
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

  private func legacyKey(
    _ productAccountId: String,
    _ providerAccountIdentifier: String
  ) -> String {
    let productAccount = legacyGmailSafeFileComponent(productAccountId)
    let providerAccount = legacyGmailSafeFileComponent(providerAccountIdentifier)
    return "gmail-push-watch.\(productAccount).\(providerAccount)"
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

struct GmailPushEligibilityStore: GmailPushEligibilityPersisting {
  private struct Record: Codable {
    let stableProviderMessageId: String
    let throughHistoryId: String
  }

  private let defaults: UserDefaults
  private static let lock = NSLock()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func record(
    _ messages: [GmailMessageMetadata],
    throughHistoryId: String,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    guard !messages.isEmpty else { return }
    var recordsByMessageId: [String: Record] = [:]
    for record in try records(productAccountId, providerAccountIdentifier) {
      recordsByMessageId[record.stableProviderMessageId] = record
    }
    for message in messages {
      if let existing = recordsByMessageId[message.stableProviderMessageId],
        !gmailHistoryIdIsNewer(throughHistoryId, than: existing.throughHistoryId)
      {
        continue
      }
      recordsByMessageId[message.stableProviderMessageId] = Record(
        stableProviderMessageId: message.stableProviderMessageId,
        throughHistoryId: throughHistoryId
      )
    }
    try save(Array(recordsByMessageId.values), productAccountId, providerAccountIdentifier)
  }

  func eligibleStableMessageIds(
    after historyId: String,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> Set<String> {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    return Set(
      try records(productAccountId, providerAccountIdentifier).compactMap { record in
        gmailHistoryIdIsNewer(record.throughHistoryId, than: historyId)
          ? record.stableProviderMessageId : nil
      }
    )
  }

  func discard(
    through historyId: String,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    let remainingRecords = try records(productAccountId, providerAccountIdentifier).filter {
      gmailHistoryIdIsNewer($0.throughHistoryId, than: historyId)
    }
    try save(remainingRecords, productAccountId, providerAccountIdentifier)
  }

  private func key(_ productAccountId: String, _ providerAccountIdentifier: String) -> String {
    "gmail-push-notification-eligibility.\(gmailSafeFileComponent(productAccountId))."
      + gmailSafeFileComponent(providerAccountIdentifier)
  }

  private func records(
    _ productAccountId: String,
    _ providerAccountIdentifier: String
  ) throws -> [Record] {
    guard let data = defaults.data(forKey: key(productAccountId, providerAccountIdentifier)) else {
      return []
    }
    return try JSONDecoder().decode([Record].self, from: data)
  }

  private func save(
    _ records: [Record],
    _ productAccountId: String,
    _ providerAccountIdentifier: String
  ) throws {
    let key = key(productAccountId, providerAccountIdentifier)
    guard !records.isEmpty else {
      defaults.removeObject(forKey: key)
      return
    }
    defaults.set(try JSONEncoder().encode(records), forKey: key)
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

private struct NoopGmailPushEligibilityStore: GmailPushEligibilityPersisting {
  func record(
    _: [GmailMessageMetadata],
    throughHistoryId _: String,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}

  func eligibleStableMessageIds(
    after _: String,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> Set<String> { [] }

  func discard(
    through _: String,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}
}

struct KeychainGmailPushConnectionStore: GmailPushConnectionPersisting {
  private let service = "private-email.gmail-push-connection"

  func clear(productAccountId: String) throws {
    try clearAll(productAccountId: productAccountId)
  }

  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    try KeychainStore.delete(
      service: service,
      account: key(productAccountId, providerAccountIdentifier)
    )
    var identifiers = try providerAccountIdentifiers(productAccountId: productAccountId)
    identifiers.remove(providerAccountIdentifier)
    try saveProviderAccountIdentifiers(identifiers, productAccountId: productAccountId)
  }

  func clearAll(productAccountId: String) throws {
    for identifier in try providerAccountIdentifiers(productAccountId: productAccountId) {
      try KeychainStore.delete(service: service, account: key(productAccountId, identifier))
    }
    try KeychainStore.delete(service: service, account: manifestKey(productAccountId))
    try KeychainStore.delete(service: service, account: legacyKey(productAccountId))
  }

  func load(productAccountId: String) throws -> GmailProviderConnectionStatus? {
    try loadAll(productAccountId: productAccountId).first
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailProviderConnectionStatus? {
    if let connection = try connection(
      account: key(productAccountId, providerAccountIdentifier)
    ) {
      return connection
    }
    guard
      let legacyConnection = try connection(account: legacyKey(productAccountId)),
      legacyConnection.providerAccountIdentifier == providerAccountIdentifier
    else {
      return nil
    }
    try save(legacyConnection, productAccountId: productAccountId)
    try? KeychainStore.delete(service: service, account: legacyKey(productAccountId))
    return legacyConnection
  }

  func loadAll(productAccountId: String) throws -> [GmailProviderConnectionStatus] {
    let identifiers = try providerAccountIdentifiers(productAccountId: productAccountId)
    if !identifiers.isEmpty {
      return try identifiers.compactMap {
        try load(productAccountId: productAccountId, providerAccountIdentifier: $0)
      }
    }
    guard let legacyConnection = try connection(account: legacyKey(productAccountId)) else {
      return []
    }
    try save(legacyConnection, productAccountId: productAccountId)
    try? KeychainStore.delete(service: service, account: legacyKey(productAccountId))
    return [legacyConnection]
  }

  func save(
    _ connection: GmailProviderConnectionStatus,
    productAccountId: String
  ) throws {
    let data = try JSONEncoder().encode(connection)
    guard let json = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    let previousIdentifiers = try providerAccountIdentifiers(productAccountId: productAccountId)
    var identifiers = previousIdentifiers
    identifiers.insert(connection.providerAccountIdentifier)
    try saveProviderAccountIdentifiers(identifiers, productAccountId: productAccountId)
    do {
      try KeychainStore.writeString(
        json,
        service: service,
        account: key(productAccountId, connection.providerAccountIdentifier),
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      )
    } catch {
      try? saveProviderAccountIdentifiers(
        previousIdentifiers,
        productAccountId: productAccountId
      )
      throw error
    }
  }

  private func key(_ productAccountId: String, _ providerAccountIdentifier: String) -> String {
    let productAccount = gmailSafeFileComponent(productAccountId)
    let providerAccount = gmailSafeFileComponent(providerAccountIdentifier)
    return "gmail-push-connection.\(productAccount).\(providerAccount)"
  }

  private func legacyKey(_ productAccountId: String) -> String {
    "gmail-push-connection.\(gmailSafeFileComponent(productAccountId))"
  }

  private func manifestKey(_ productAccountId: String) -> String {
    "gmail-push-connections.\(gmailSafeFileComponent(productAccountId))"
  }

  private func providerAccountIdentifiers(productAccountId: String) throws -> Set<String> {
    guard
      let json = try KeychainStore.readString(
        service: service,
        account: manifestKey(productAccountId)
      ),
      let data = json.data(using: .utf8)
    else {
      return []
    }
    return Set(try JSONDecoder().decode([String].self, from: data))
  }

  private func connection(account: String) throws -> GmailProviderConnectionStatus? {
    guard
      let json = try KeychainStore.readString(service: service, account: account),
      let data = json.data(using: .utf8)
    else {
      return nil
    }
    return try JSONDecoder().decode(GmailProviderConnectionStatus.self, from: data)
  }

  private func saveProviderAccountIdentifiers(
    _ identifiers: Set<String>,
    productAccountId: String
  ) throws {
    guard !identifiers.isEmpty else {
      try KeychainStore.delete(service: service, account: manifestKey(productAccountId))
      return
    }
    let data = try JSONEncoder().encode(identifiers.sorted())
    guard let json = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(
      json,
      service: service,
      account: manifestKey(productAccountId),
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
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
    let previousWatch = try store.load(
      productAccountId: productSession.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let existing = try currentWatch(
      connection: connection,
      productSession: productSession
    )
    let tokens = try await verifiedTokens(
      connection: connection,
      productSession: productSession
    )
    if let existing {
      let verification = try await verifyWatch(
        existing,
        gmailIdentityToken: try requiredIdentityToken(tokens),
        productSession: productSession
      )
      let verifiedStatus = statusWithRoute(existing, routeId: verification.routeId)
      try saveWatch(verifiedStatus, connection: connection, session: productSession)
      if verification.verified {
        return verifiedStatus
      }
    }

    let topicName = try requiredTopicName()
    let registeredStatus = try await registerWatch(
      accessToken: tokens.accessToken,
      topicName: topicName
    )
    let status = GmailPushWatchStatus(
      expirationMilliseconds: registeredStatus.expirationMilliseconds,
      historyId: registeredStatus.historyId,
      latestSyncedHistoryId: previousWatch?.latestSyncedHistoryId ?? previousWatch?.historyId
    )
    try saveWatch(status, connection: connection, session: productSession)
    let verification = try await verifyWatch(
      status,
      gmailIdentityToken: try requiredIdentityToken(tokens),
      productSession: productSession
    )
    let verifiedStatus = statusWithRoute(status, routeId: verification.routeId)
    try saveWatch(verifiedStatus, connection: connection, session: productSession)
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
    gmailIdentityToken: String,
    productSession: ProductAccountSessionSnapshot
  ) async throws -> GmailPushVerificationResponse {
    try await verificationTransport.verifyGmailPushWatch(
      gmailIdentityToken: gmailIdentityToken,
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

  private func saveWatch(
    _ status: GmailPushWatchStatus,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) throws {
    try store.save(
      status,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    try connectionStore.save(connection, productAccountId: session.productAccountId)
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

  private func requiredIdentityToken(_ tokens: GmailProviderTokens) throws -> String {
    guard let idToken = tokens.idToken, !idToken.isEmpty else {
      throw GmailPushRelayError.missingMailboxOwnershipProof
    }
    return idToken
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

// swiftlint:disable type_body_length
@MainActor
struct GmailPushWakeupHandler {
  private enum CategoryNotificationDeliveryResult {
    case completed
    case failed
    case fallbackDelivered
  }

  private let connectionStore: GmailPushConnectionPersisting
  private let genericNotificationDelivery: GenericNotificationDelivering
  private let genericNotificationFallbackStore: GenericNotificationFallbackPersisting
  private let hasProcessingTimeRemaining: @MainActor () -> Bool
  private let notificationAuthorization: NotificationAuthorizationRequesting
  private let notificationDelivery: CategoryAwareNotificationDelivering
  private let notificationEligibilityStore: GmailPushEligibilityPersisting
  private let notificationReceiptStore: GmailPushNotificationReceiptPersisting
  private let notificationRuleSync: NotificationRuleSyncing
  private let sessionStore: ProductAccountSessionPersisting
  private let syncService: MailboxMetadataSyncing
  private let watchStore: GmailPushWatchPersisting

  init(
    connectionStore: GmailPushConnectionPersisting = KeychainGmailPushConnectionStore(),
    genericNotificationDelivery: GenericNotificationDelivering? = nil,
    genericNotificationFallbackStore: GenericNotificationFallbackPersisting =
      UserDefaultsFallbackStore(),
    hasProcessingTimeRemaining: @escaping @MainActor () -> Bool = {
      #if canImport(UIKit)
        UIApplication.shared.backgroundTimeRemaining > 1
      #else
        true
      #endif
    },
    notificationDelivery: CategoryAwareNotificationDelivering = UserNotificationService(),
    notificationAuthorization: NotificationAuthorizationRequesting? = nil,
    notificationEligibilityStore: GmailPushEligibilityPersisting? = nil,
    notificationReceiptStore: GmailPushNotificationReceiptPersisting? = nil,
    notificationRuleSync: NotificationRuleSyncing = NotificationRuleSyncService(),
    sessionStore: ProductAccountSessionPersisting = KeychainProductAccountSessionStore(),
    syncService: MailboxMetadataSyncing = GmailMailboxConnectionAdapter(),
    watchStore: GmailPushWatchPersisting = UserDefaultsGmailPushWatchStore()
  ) {
    self.connectionStore = connectionStore
    self.genericNotificationDelivery =
      genericNotificationDelivery
      ?? (notificationDelivery as? GenericNotificationDelivering)
      ?? UserNotificationService()
    self.genericNotificationFallbackStore = genericNotificationFallbackStore
    self.hasProcessingTimeRemaining = hasProcessingTimeRemaining
    self.notificationDelivery = notificationDelivery
    self.notificationAuthorization =
      notificationAuthorization
      ?? (notificationDelivery as? NotificationAuthorizationRequesting)
      ?? UserNotificationService()
    self.notificationEligibilityStore =
      notificationEligibilityStore
      ?? (notificationDelivery is UserNotificationService
        ? GmailPushEligibilityStore()
        : NoopGmailPushEligibilityStore())
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
      let productSession = try sessionStore.load()
    else {
      return false
    }
    let connections = try connectionStore.loadAll(productAccountId: productSession.productAccountId)
    guard
      let connection = connections.first(where: { connection in
        (try? watchStore.load(
          productAccountId: productSession.productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        ))?.routeId == routeId
      }),
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
          productAccountId: productSession.productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
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
    let watermarkIsCurrent = {
      guard let currentWatch = currentWatchForRoute() else { return false }
      return gmailHistoryIdIsNewer(
        historyId,
        than: currentWatch.latestSyncedHistoryId ?? currentWatch.historyId
      )
    }
    let scheduleGenericFallback: () async throws -> Bool = {
      try await deliverGenericFallback(
        historyId: historyId,
        productAccountId: productSession.productAccountId,
        routeId: routeId,
        routeIsCurrent: { routeIsCurrent() && watermarkIsCurrent() }
      )
    }
    let advanceWatermark: () throws -> Bool = {
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
      try? notificationEligibilityStore.discard(
        through: nextWatermark,
        productAccountId: productSession.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      return true
    }
    let completeWithGenericFallback: () async throws -> Bool = {
      guard try await scheduleGenericFallback() else { return false }
      return try advanceWatermark()
    }

    let notificationRules = try await failClosed {
      try await notificationRuleSync.loadRulesForBackground(session: productSession).rules
    }
    guard let notificationRules else {
      return false
    }
    guard hasProcessingTimeRemaining() else {
      guard !notificationRules.categoryIds.isEmpty else { return false }
      return try await completeWithGenericFallback()
    }
    guard currentWatchForRoute() != nil else { return false }
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: productSession.productAccountId
    )
    let syncResult: MailboxMetadataSyncResult
    do {
      syncResult = try await syncService.syncRecentInbox(
        connection: mailboxConnection,
        includingHistoryCandidates: !notificationRules.categoryIds.isEmpty,
        session: productSession,
        sinceHistoryId: watchStatus.latestSyncedHistoryId ?? watchStatus.historyId,
        throughHistoryId: historyId,
        shouldPersist: routeIsCurrent
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch GmailMessageMetadataSyncError.staleLocalConnection {
      return false
    } catch {
      let currentNotificationRules = try await failClosed {
        try await notificationRuleSync.loadRulesForBackground(session: productSession).rules
      }
      guard currentNotificationRules?.categoryIds.isEmpty == false else { throw error }
      return try await completeWithGenericFallback()
    }
    guard currentWatchForRoute() != nil else { return false }
    let currentNotificationRules = try await failClosed {
      try await notificationRuleSync.loadRulesForBackground(session: productSession).rules
    }
    guard let currentNotificationRules else { return false }
    guard currentWatchForRoute() != nil else { return false }
    let durableEligibleMessageIds = try notificationEligibilityStore.eligibleStableMessageIds(
      after: watchStatus.latestSyncedHistoryId ?? watchStatus.historyId,
      productAccountId: productSession.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let notificationCandidateIds = Set(
      syncResult.messages.compactMap { message in
        if durableEligibleMessageIds.contains(message.stableProviderMessageId)
          || syncResult.newMessageIds?.contains(message.providerMessageId) == true
        {
          return message.providerMessageId
        }
        return nil
      }
    )
    let deliverableNotificationCandidateIds =
      syncResult.newMessageIds == nil && notificationCandidateIds.isEmpty
      ? nil : notificationCandidateIds
    let canAdvanceWatermark =
      currentNotificationRules.categoryIds.isEmpty
      || (syncResult.newMessageIds != nil && !syncResult.hasUnlistedNewMessages)
    let categoryProcessingIsIncomplete =
      !currentNotificationRules.categoryIds.isEmpty
      && (syncResult.providerCursorIsExpired
        || syncResult.hasUnlistedNewMessages
        || syncResult.newMessageIds == nil
        || syncResult.messages.contains { message in
          !message.isHistorical
            && notificationCandidateIds.contains(message.providerMessageId)
            && message.categoryId == nil
        })
    let notificationDeliveryResult = try await deliverCategoryAwareNotifications(
      for: syncResult.messages.map(\.gmailMetadata),
      including: deliverableNotificationCandidateIds,
      connection: connection,
      productAccountId: productSession.productAccountId,
      rules: currentNotificationRules,
      onProcessingFailure: scheduleGenericFallback,
      routeIsCurrent: routeIsCurrent,
      watermarkIsCurrent: watermarkIsCurrent
    )
    guard notificationDeliveryResult != .failed else { return false }
    let shouldDeliverGenericFallback =
      categoryProcessingIsIncomplete
      && genericNotificationFallbackStore.isEnabled(
        productAccountId: productSession.productAccountId
      )
    let deliveredGenericFallback: Bool
    if notificationDeliveryResult == .fallbackDelivered {
      deliveredGenericFallback = true
    } else if shouldDeliverGenericFallback {
      deliveredGenericFallback = try await scheduleGenericFallback()
    } else {
      deliveredGenericFallback = false
    }
    guard
      deliveredGenericFallback || (!shouldDeliverGenericFallback && canAdvanceWatermark)
    else { return false }
    return try advanceWatermark()
  }

  private func deliverGenericFallback(
    historyId: String,
    productAccountId: String,
    routeId: String,
    routeIsCurrent: () -> Bool
  ) async throws -> Bool {
    guard
      genericNotificationFallbackStore.isEnabled(productAccountId: productAccountId),
      routeIsCurrent(),
      try await failClosed({ try await notificationAuthorization.requestAuthorization() }) == true,
      routeIsCurrent()
    else { return false }
    return try await failClosed {
      try await genericNotificationDelivery.deliverGeneric(
        identifier: "gmail-generic-fallback:\(routeId):\(historyId)"
      )
      return true
    } ?? false
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length function_parameter_count
  private func deliverCategoryAwareNotifications(
    for messages: [GmailMessageMetadata],
    including newMessageIds: Set<String>?,
    connection: GmailProviderConnectionStatus,
    productAccountId: String,
    rules: NotificationRules?,
    onProcessingFailure: () async throws -> Bool,
    routeIsCurrent: () -> Bool,
    watermarkIsCurrent: () -> Bool
  ) async throws -> CategoryNotificationDeliveryResult {
    guard let rules else { return .failed }
    guard !rules.categoryIds.isEmpty else { return .completed }
    guard let newMessageIds else {
      return (try await onProcessingFailure()) ? .fallbackDelivered : .failed
    }
    var notificationAuthorizationGranted = false
    for message in messages
    where !message.isHistorical
      && newMessageIds.contains(message.providerMessageId)
      && message.categoryId.map(rules.allows(categoryId:)) == true
    {
      guard routeIsCurrent(), watermarkIsCurrent() else { return .failed }
      guard hasProcessingTimeRemaining() else {
        return (try await onProcessingFailure()) ? .fallbackDelivered : .failed
      }
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
        return .failed
      }
      if !notificationAuthorizationGranted {
        guard try await notificationAuthorization.requestAuthorization() else {
          try notificationReceiptStore.release(
            message,
            productAccountId: productAccountId,
            providerAccountIdentifier: connection.providerAccountIdentifier
          )
          return .failed
        }
        notificationAuthorizationGranted = true
      }
      guard routeIsCurrent(), watermarkIsCurrent() else {
        try notificationReceiptStore.release(
          message,
          productAccountId: productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        )
        return .failed
      }
      guard hasProcessingTimeRemaining() else {
        try notificationReceiptStore.release(
          message,
          productAccountId: productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        )
        return (try await onProcessingFailure()) ? .fallbackDelivered : .failed
      }
      do {
        try await notificationDelivery.deliver(message: message)
        // Persist successful delivery even if the route changed during the await. A replacement
        // route can then advance its own watermark without showing the same message again.
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
        return (try await onProcessingFailure()) ? .fallbackDelivered : .failed
      }
    }
    return .completed
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
// swiftlint:enable type_body_length

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
  case missingMailboxOwnershipProof
  case missingTopicName
  case watchRegistrationFailed
  case watchStopFailed

  var errorDescription: String? {
    switch self {
    case .invalidWatchResponse:
      return "Gmail returned an invalid push watch response."
    case .missingMailboxOwnershipProof:
      return "Gmail did not return a mailbox ownership proof."
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
