import Foundation

// swiftlint:disable file_length

#if canImport(UIKit)
  import OSLog
  import UIKit
  import UserNotifications
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

protocol GmailLegacyPushWatchOwnershipPersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> String?
  func save(providerAccountIdentifier: String, productAccountId: String) throws
}

extension GmailPushWatchPersisting {
  func clearAll(productAccountId _: String) throws {}
}

protocol GmailPushConnectionPersisting {
  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws
  func clearAll(productAccountId: String) throws
  func clearScoped(productAccountId: String) throws
  func hasLegacyOwnership(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> Bool
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
  func clearScoped(productAccountId: String) throws {
    try clearAll(productAccountId: productAccountId)
  }

  func hasLegacyOwnership(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> Bool { false }
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
    opaqueConnectionId: String,
    trustedDeviceId: String
  ) async throws -> GmailPushVerificationResponse
}

protocol GmailProviderTokenRefreshing {
  func refreshProviderTokens(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderTokens
}

struct KeychainGmailLegacyWatchOwnerStore: GmailLegacyPushWatchOwnershipPersisting {
  private let service = "private-email.gmail-push-watch-legacy-owner"

  func clear(productAccountId: String) throws {
    try KeychainStore.delete(service: service, account: account(productAccountId))
  }

  func load(productAccountId: String) throws -> String? {
    try KeychainStore.readString(service: service, account: account(productAccountId))
  }

  func save(providerAccountIdentifier: String, productAccountId: String) throws {
    try KeychainStore.writeString(
      providerAccountIdentifier,
      service: service,
      account: account(productAccountId),
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }

  private func account(_ productAccountId: String) -> String {
    "gmail-push-watch-owner.\(gmailSafeFileComponent(productAccountId))"
  }
}

struct UserDefaultsGmailPushWatchStore: GmailPushWatchPersisting {
  private let defaults: UserDefaults
  private let legacyOwnershipStore: GmailLegacyPushWatchOwnershipPersisting

  init(
    defaults: UserDefaults = .standard,
    legacyOwnershipStore: GmailLegacyPushWatchOwnershipPersisting =
      KeychainGmailLegacyWatchOwnerStore()
  ) {
    self.defaults = defaults
    self.legacyOwnershipStore = legacyOwnershipStore
  }

  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    defaults.removeObject(forKey: key(productAccountId, providerAccountIdentifier))
    if try legacyOwnershipStore.load(productAccountId: productAccountId)
      == providerAccountIdentifier
    {
      defaults.removeObject(forKey: legacyKey(productAccountId, providerAccountIdentifier))
      try legacyOwnershipStore.clear(productAccountId: productAccountId)
    }
  }

  func clearAll(productAccountId: String) throws {
    let prefix = "gmail-push-watch.\(gmailSafeFileComponent(productAccountId))."
    for key in defaults.dictionaryRepresentation().keys
    where key.hasPrefix(prefix) {
      defaults.removeObject(forKey: key)
    }
    if let legacyOwner = try legacyOwnershipStore.load(productAccountId: productAccountId) {
      defaults.removeObject(forKey: legacyKey(productAccountId, legacyOwner))
      try legacyOwnershipStore.clear(productAccountId: productAccountId)
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
    guard
      try legacyOwnershipStore.load(productAccountId: productAccountId)
        == providerAccountIdentifier
    else {
      return nil
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
    try? legacyOwnershipStore.clear(productAccountId: productAccountId)
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

func clearGmailPushNotificationState(
  productAccountId: String,
  providerAccountIdentifier: String,
  defaults: UserDefaults = .standard
) {
  let suffix =
    "\(gmailSafeFileComponent(productAccountId)).\(gmailSafeFileComponent(providerAccountIdentifier))"
  let legacySuffix =
    "\(legacyGmailSafeFileComponent(productAccountId))."
    + legacyGmailSafeFileComponent(providerAccountIdentifier)
  defaults.removeObject(forKey: "gmail-push-notification-receipts.\(suffix)")
  defaults.removeObject(forKey: "gmail-push-notification-eligibility.\(suffix)")
  clearLegacyNotificationState(
    forKey: "gmail-push-notification-receipts.\(legacySuffix)",
    providerAccountIdentifier: providerAccountIdentifier,
    defaults: defaults
  )
  clearLegacyNotificationState(
    forKey: "gmail-push-notification-eligibility.\(legacySuffix)",
    providerAccountIdentifier: providerAccountIdentifier,
    defaults: defaults
  )
}

func clearGmailPushNotificationState(
  productAccountId: String,
  defaults: UserDefaults = .standard
) {
  let account = gmailSafeFileComponent(productAccountId)
  let legacyAccount = legacyGmailSafeFileComponent(productAccountId)
  let prefixes = [
    "gmail-push-notification-receipts.\(account).",
    "gmail-push-notification-eligibility.\(account).",
    "gmail-push-notification-receipts.\(legacyAccount).",
    "gmail-push-notification-eligibility.\(legacyAccount).",
  ]
  for key in defaults.dictionaryRepresentation().keys
  where prefixes.contains(where: key.hasPrefix) {
    defaults.removeObject(forKey: key)
  }
}

private func clearLegacyNotificationState(
  forKey key: String,
  providerAccountIdentifier: String,
  defaults: UserDefaults
) {
  let prefix = "gmail:\(providerAccountIdentifier):"
  if let receipts = defaults.stringArray(forKey: key),
    receipts.allSatisfy({ $0.hasPrefix(prefix) })
  {
    defaults.removeObject(forKey: key)
    return
  }
  guard
    let data = defaults.data(forKey: key),
    let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
    records.allSatisfy({ ($0["stableProviderMessageId"] as? String)?.hasPrefix(prefix) == true })
  else {
    return
  }
  defaults.removeObject(forKey: key)
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
    let key = key(productAccountId, providerAccountIdentifier)
    if let receipts = defaults.stringArray(forKey: key) {
      return Set(receipts)
    }
    let legacyKey = legacyKey(productAccountId, providerAccountIdentifier)
    guard let receipts = defaults.stringArray(forKey: legacyKey) else {
      return []
    }
    guard
      receipts.allSatisfy({
        $0.hasPrefix("gmail:\(providerAccountIdentifier):")
      })
    else {
      return []
    }
    defaults.set(receipts, forKey: key)
    defaults.removeObject(forKey: legacyKey)
    return Set(receipts)
  }

  private func legacyKey(
    _ productAccountId: String,
    _ providerAccountIdentifier: String
  ) -> String {
    "gmail-push-notification-receipts.\(legacyGmailSafeFileComponent(productAccountId))."
      + legacyGmailSafeFileComponent(providerAccountIdentifier)
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
    let key = key(productAccountId, providerAccountIdentifier)
    if let data = defaults.data(forKey: key) {
      return try JSONDecoder().decode([Record].self, from: data)
    }
    let legacyKey = legacyKey(productAccountId, providerAccountIdentifier)
    guard let data = defaults.data(forKey: legacyKey) else {
      return []
    }
    let records = try JSONDecoder().decode([Record].self, from: data)
    guard
      records.allSatisfy({
        $0.stableProviderMessageId.hasPrefix("gmail:\(providerAccountIdentifier):")
      })
    else {
      return []
    }
    defaults.set(data, forKey: key)
    defaults.removeObject(forKey: legacyKey)
    return records
  }

  private func legacyKey(
    _ productAccountId: String,
    _ providerAccountIdentifier: String
  ) -> String {
    "gmail-push-notification-eligibility.\(legacyGmailSafeFileComponent(productAccountId))."
      + legacyGmailSafeFileComponent(providerAccountIdentifier)
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
  private let readString: (String, String) throws -> String?
  private let legacyWatchOwnershipStore: GmailLegacyPushWatchOwnershipPersisting

  init(
    legacyWatchOwnershipStore: GmailLegacyPushWatchOwnershipPersisting =
      KeychainGmailLegacyWatchOwnerStore(),
    readString: @escaping (String, String) throws -> String? = { service, account in
      try KeychainStore.readString(service: service, account: account)
    }
  ) {
    self.legacyWatchOwnershipStore = legacyWatchOwnershipStore
    self.readString = readString
  }

  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    if try legacyConnection(productAccountId: productAccountId)?
      .providerAccountIdentifier == providerAccountIdentifier
    {
      for account in legacyKeys(productAccountId) {
        try KeychainStore.delete(service: service, account: account)
      }
    }
    if try legacyWatchOwnershipStore.load(productAccountId: productAccountId)
      == providerAccountIdentifier
    {
      try legacyWatchOwnershipStore.clear(productAccountId: productAccountId)
    }
    try KeychainStore.delete(
      service: service,
      account: key(productAccountId, providerAccountIdentifier)
    )
    var identifiers = try providerAccountIdentifiers(productAccountId: productAccountId)
    identifiers.remove(providerAccountIdentifier)
    try saveProviderAccountIdentifiers(identifiers, productAccountId: productAccountId)
  }

  func clearAll(productAccountId: String) throws {
    try clearScoped(productAccountId: productAccountId)
    for account in legacyKeys(productAccountId) {
      try KeychainStore.delete(service: service, account: account)
    }
    try legacyWatchOwnershipStore.clear(productAccountId: productAccountId)
  }

  func clearScoped(productAccountId: String) throws {
    for identifier in try providerAccountIdentifiers(productAccountId: productAccountId) {
      try KeychainStore.delete(service: service, account: key(productAccountId, identifier))
    }
    try KeychainStore.delete(service: service, account: manifestKey(productAccountId))
    do {
      _ = try legacyConnection(productAccountId: productAccountId)
    } catch is DecodingError {
      for account in legacyKeys(productAccountId) {
        try KeychainStore.delete(service: service, account: account)
      }
      try legacyWatchOwnershipStore.clear(productAccountId: productAccountId)
    } catch KeychainStoreError.unexpectedData {
      for account in legacyKeys(productAccountId) {
        try KeychainStore.delete(service: service, account: account)
      }
      try legacyWatchOwnershipStore.clear(productAccountId: productAccountId)
    }
  }

  func hasLegacyOwnership(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> Bool {
    if try legacyWatchOwnershipStore.load(productAccountId: productAccountId)
      == providerAccountIdentifier
    {
      return true
    }
    return try legacyConnection(productAccountId: productAccountId)?
      .providerAccountIdentifier == providerAccountIdentifier
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailProviderConnectionStatus? {
    let scopedConnection = try connection(
      account: key(productAccountId, providerAccountIdentifier)
    )
    guard
      let legacyConnection = try? legacyConnection(productAccountId: productAccountId),
      legacyConnection.providerAccountIdentifier == providerAccountIdentifier
    else {
      return scopedConnection
    }
    try legacyWatchOwnershipStore.save(
      providerAccountIdentifier: providerAccountIdentifier,
      productAccountId: productAccountId
    )
    if scopedConnection == nil {
      try save(legacyConnection, productAccountId: productAccountId)
    }
    for account in legacyKeys(productAccountId) {
      try? KeychainStore.delete(service: service, account: account)
    }
    return scopedConnection ?? legacyConnection
  }

  func loadAll(productAccountId: String) throws -> [GmailProviderConnectionStatus] {
    let identifiers = try providerAccountIdentifiers(productAccountId: productAccountId)
    var connections: [GmailProviderConnectionStatus] = []
    for identifier in identifiers {
      if let connection = try? load(
        productAccountId: productAccountId,
        providerAccountIdentifier: identifier
      ) {
        connections.append(connection)
      }
    }
    guard let legacyConnection = try legacyConnection(productAccountId: productAccountId) else {
      return connections
    }
    try legacyWatchOwnershipStore.save(
      providerAccountIdentifier: legacyConnection.providerAccountIdentifier,
      productAccountId: productAccountId
    )
    if connections.contains(where: {
      $0.providerAccountIdentifier == legacyConnection.providerAccountIdentifier
    }) {
      for account in legacyKeys(productAccountId) {
        try? KeychainStore.delete(service: service, account: account)
      }
      return connections
    }
    try save(legacyConnection, productAccountId: productAccountId)
    for account in legacyKeys(productAccountId) {
      try? KeychainStore.delete(service: service, account: account)
    }
    connections.append(legacyConnection)
    return connections
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
    "gmail-push-connection.\(legacyGmailSafeFileComponent(productAccountId))"
  }

  private func legacyKeys(_ productAccountId: String) -> [String] {
    [
      legacyKey(productAccountId),
      "gmail-push-connection.\(gmailSafeFileComponent(productAccountId))",
    ]
  }

  private func legacyConnection(
    productAccountId: String
  ) throws -> GmailProviderConnectionStatus? {
    for account in legacyKeys(productAccountId) {
      if let connection = try connection(account: account) {
        return connection
      }
    }
    return nil
  }

  private func manifestKey(_ productAccountId: String) -> String {
    "gmail-push-connections.\(gmailSafeFileComponent(productAccountId))"
  }

  private func providerAccountIdentifiers(productAccountId: String) throws -> Set<String> {
    guard
      let json = try readString(service, manifestKey(productAccountId)),
      let data = json.data(using: .utf8)
    else {
      return []
    }
    return Set(try JSONDecoder().decode([String].self, from: data))
  }

  private func connection(account: String) throws -> GmailProviderConnectionStatus? {
    guard
      let json = try readString(service, account),
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
        connection: connection,
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
      connection: connection,
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
    connection: GmailProviderConnectionStatus,
    gmailIdentityToken: String,
    productSession: ProductAccountSessionSnapshot
  ) async throws -> GmailPushVerificationResponse {
    try await verificationTransport.verifyGmailPushWatch(
      gmailIdentityToken: gmailIdentityToken,
      historyId: status.historyId,
      identityToken: productSession.identityToken,
      opaqueConnectionId: opaqueGmailConnectionId(
        productAccountId: productSession.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
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
    try connectionStore.save(connection, productAccountId: session.productAccountId)
    try store.save(
      status,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
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
protocol GmailConnectionAuthorizationChecking {
  func hasActiveAuthorization(
    _ connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> Bool
}

@MainActor
struct BackgroundTrustedDeviceRevalidator {
  private let productAccountService: ProductAccountConnecting
  private let trustedDeviceRevoked: @MainActor (ProductAccountSessionSnapshot) async -> Void

  init(
    productAccountService: ProductAccountConnecting = ConvexProductAccountService(),
    trustedDeviceRevoked:
      @escaping @MainActor (ProductAccountSessionSnapshot) async -> Void = { _ in }
  ) {
    self.productAccountService = productAccountService
    self.trustedDeviceRevoked = trustedDeviceRevoked
  }

  func revalidate(_ session: ProductAccountSessionSnapshot) async -> Bool {
    guard session.identityTokenState() == .active else { return false }
    do {
      let response = try await productAccountService.connect(identityToken: session.identityToken)
      return response.productAccountId == session.productAccountId
        && response.trustedDeviceId == session.trustedDeviceId
    } catch ProductAccountServiceError.trustedDeviceRevoked {
      await trustedDeviceRevoked(session)
      return false
    } catch {
      return false
    }
  }
}

@MainActor
private final class BackgroundRevocationRecorder {
  private(set) var session: ProductAccountSessionSnapshot?

  func record(_ session: ProductAccountSessionSnapshot) {
    self.session = self.session ?? session
  }
}

@MainActor
private func ignoreBackgroundTrustedDeviceRevocation(
  _: ProductAccountSessionSnapshot
) async {}

struct NotificationProfileResolution: Equatable, Sendable {
  let deliveryContext: NotificationDeliveryContext
  let recordScope: MailProfileRecordScope
}

protocol NotificationProfileResolving {
  func resolve(
    connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationProfileResolution
}

struct LegacyNotificationProfileResolver: NotificationProfileResolving {
  func resolve(
    connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationProfileResolution {
    let profile = MailProfileDefinition.defaultProfile(
      productAccountId: session.productAccountId
    )
    return NotificationProfileResolution(
      deliveryContext: NotificationDeliveryContext(
        connectionId: connectionId,
        isActiveProfile: true,
        isProfileQuiet: false,
        profileId: profile.id,
        profileName: profile.name
      ),
      recordScope: profile.recordScope
    )
  }
}

struct ProductSyncNotificationProfileResolver: NotificationProfileResolving {
  private let nowMilliseconds: () -> Int64
  private let service: MailboxConnectionSyncService

  init(
    nowMilliseconds: @escaping () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    service: MailboxConnectionSyncService = MailboxConnectionSyncService()
  ) {
    self.nowMilliseconds = nowMilliseconds
    self.service = service
  }

  func resolve(
    connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationProfileResolution {
    let snapshot = try await service.loadProfileSnapshot(session: session)
    let profile = try Self.profile(for: connectionId, in: snapshot)
    let quietUntil = profile.quietState.quietUntil
    let isQuiet =
      profile.quietState.isQuiet
      && (quietUntil.map { $0 > nowMilliseconds() } ?? true)
    return NotificationProfileResolution(
      deliveryContext: NotificationDeliveryContext(
        connectionId: connectionId,
        isActiveProfile: profile.id == snapshot.defaultProfileId,
        isProfileQuiet: isQuiet,
        profileId: profile.id,
        profileName: profile.name
      ),
      recordScope: profile.recordScope
    )
  }

  static func profile(
    for connectionId: MailboxConnectionId,
    in snapshot: MailProfileSyncSnapshot
  ) throws -> MailProfileDefinition {
    let profileId = snapshot.assignments[connectionId] ?? snapshot.defaultProfileId
    guard let profile = snapshot.profiles.first(where: { $0.id == profileId }) else {
      throw MailProfileSyncError.profileNotFound
    }
    return profile
  }
}

@MainActor
protocol GmailPushWakeupDraining {
  func cancelAndDrain(productAccountId: String) async
  func finishDraining(productAccountId: String)
}

@MainActor
final class GmailPushWakeupCoordinator: GmailPushWakeupDraining {
  static let shared = GmailPushWakeupCoordinator()

  private var drainingProductAccountIds: Set<String> = []
  private var tasks: [String: [UUID: Task<Bool, Error>]] = [:]

  func handle(
    productAccountId: String,
    operation: @escaping @MainActor () async throws -> Bool
  ) async throws -> Bool {
    guard !drainingProductAccountIds.contains(productAccountId) else {
      throw CancellationError()
    }
    let id = UUID()
    let task = Task { try await operation() }
    tasks[productAccountId, default: [:]][id] = task
    defer {
      tasks[productAccountId]?[id] = nil
      if tasks[productAccountId]?.isEmpty == true {
        tasks[productAccountId] = nil
      }
    }
    return try await task.value
  }

  func cancelAndDrain(productAccountId: String) async {
    drainingProductAccountIds.insert(productAccountId)
    let activeTasks = tasks[productAccountId].map { Array($0.values) } ?? []
    for task in activeTasks {
      task.cancel()
    }
    for task in activeTasks {
      _ = await task.result
    }
  }

  func finishDraining(productAccountId: String) {
    drainingProductAccountIds.remove(productAccountId)
  }
}

@MainActor
struct GmailPushWakeupHandler {
  private enum CategoryNotificationDeliveryResult {
    case completed
    case failed
    case fallbackDelivered
  }

  private let backgroundCategorizer: GmailMessageCategorizing
  private let authorizationChecker: GmailConnectionAuthorizationChecking
  private let blockedSenderEnforcer: BlockedSenderEnforcing
  private let connectionStore: GmailPushConnectionPersisting
  private let genericNotificationDelivery: GenericNotificationDelivering
  private let genericNotificationFallbackStore: GenericNotificationFallbackPersisting
  private let hasProcessingTimeRemaining: @MainActor () -> Bool
  private let notificationAuthorization: NotificationAuthorizationRequesting
  private let notificationDelivery: CategoryAwareNotificationDelivering
  private let notificationEligibilityStore: GmailPushEligibilityPersisting
  private let notificationSuppressionResolver: MailProfileNotificationGate?
  private let notificationReceiptStore: GmailPushNotificationReceiptPersisting
  private let notificationRuleSync: NotificationRuleSyncing
  private let profileResolver: NotificationProfileResolving
  private let revalidateTrustedDevice: @MainActor (ProductAccountSessionSnapshot) async -> Bool
  private let sessionStore: ProductAccountSessionPersisting
  private let successStore: MailboxSyncSuccessPersisting
  private let syncService: MailboxMetadataSyncing
  private let threadMuteSync: ThreadMuteSyncing
  private let watchStore: GmailPushWatchPersisting

  init(
    backgroundCategorizer: GmailMessageCategorizing = GmailMessageCategorizationService(),
    blockedSenderEnforcer: BlockedSenderEnforcing? = nil,
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
    notificationSuppressionResolver: MailProfileNotificationGate? = nil,
    notificationReceiptStore: GmailPushNotificationReceiptPersisting? = nil,
    notificationRuleSync: NotificationRuleSyncing = NotificationRuleSyncService(),
    profileResolver: NotificationProfileResolving = LegacyNotificationProfileResolver(),
    revalidateTrustedDevice:
      @escaping @MainActor (ProductAccountSessionSnapshot) async -> Bool = { _ in true },
    sessionStore: ProductAccountSessionPersisting = KeychainProductAccountSessionStore(),
    successStore: MailboxSyncSuccessPersisting? = nil,
    syncService: MailboxMetadataSyncing & GmailConnectionAuthorizationChecking =
      GmailMailboxConnectionAdapter(),
    threadMuteSync: ThreadMuteSyncing = ThreadMuteSyncService(),
    watchStore: GmailPushWatchPersisting = UserDefaultsGmailPushWatchStore()
  ) {
    self.backgroundCategorizer = backgroundCategorizer
    authorizationChecker = syncService
    self.blockedSenderEnforcer =
      blockedSenderEnforcer
      ?? (syncService as? MailboxProviderMailActing).map {
        BlockedSenderEnforcementService(actionService: $0)
      }
      ?? NoopBlockedSenderEnforcer()
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
    self.notificationSuppressionResolver =
      notificationSuppressionResolver
      ?? ((notificationDelivery as? UserNotificationService)?.usesSystemNotificationCenter == true
        ? ProductSyncMailProfileNotificationGate()
        : nil)
    self.notificationReceiptStore =
      notificationReceiptStore
      ?? (notificationDelivery is UserNotificationService
        ? GmailPushNotificationReceiptStore()
        : NoopGmailPushNotificationReceiptStore())
    self.notificationRuleSync = notificationRuleSync
    self.profileResolver = profileResolver
    self.revalidateTrustedDevice = revalidateTrustedDevice
    self.sessionStore = sessionStore
    self.successStore = successStore ?? UserDefaultsMailboxSyncSuccessStore()
    self.syncService = syncService
    self.threadMuteSync = threadMuteSync
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
    guard await revalidateTrustedDevice(productSession) else { return false }
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
    guard
      try await authorizationChecker.hasActiveAuthorization(
        connection,
        session: productSession
      )
    else {
      try watchStore.clear(
        productAccountId: productSession.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      return false
    }
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: productSession.productAccountId,
      authorizationState: .authorized
    )
    var cachedVisibleNotificationSuppression: Bool?
    let visibleNotificationsAreSuppressed: () async throws -> Bool = {
      if let cachedVisibleNotificationSuppression {
        return cachedVisibleNotificationSuppression
      }
      guard let notificationSuppressionResolver else {
        cachedVisibleNotificationSuppression = false
        return false
      }
      do {
        let isSuppressed =
          try await notificationSuppressionResolver
          .visibleNotificationsAreSuppressed(
            for: mailboxConnection.id,
            session: productSession
          )
        cachedVisibleNotificationSuppression = isSuppressed
        return isSuppressed
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        cachedVisibleNotificationSuppression = true
        return true
      }
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
      guard !(try await visibleNotificationsAreSuppressed()) else { return false }
      return try await deliverGenericFallback(
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

    let profileResolution = try await failClosed {
      try await profileResolver.resolve(
        connectionId: mailboxConnection.id,
        session: productSession
      )
    }
    let notificationRules = try await failClosed {
      try await loadNotificationRules(
        profileResolution: profileResolution,
        session: productSession
      )
    }
    guard hasProcessingTimeRemaining() else {
      guard notificationRules?.allowsNotifications(connectionId: mailboxConnection.id) == true
      else { return false }
      return try await completeWithGenericFallback()
    }
    guard currentWatchForRoute() != nil else { return false }
    publishSyncStatus(
      .syncing,
      connection: mailboxConnection,
      productAccountId: productSession.productAccountId,
      supersedesHistoricalBackfill: false
    )
    let syncResult: MailboxMetadataSyncResult
    do {
      let synchronizedResult = try await syncService.syncRecentInbox(
        connection: mailboxConnection,
        includingHistoryCandidates: notificationRules?.allowsNotifications(
          connectionId: mailboxConnection.id
        ) == true,
        session: productSession,
        sinceHistoryId: watchStatus.latestSyncedHistoryId ?? watchStatus.historyId,
        throughHistoryId: historyId,
        shouldPersist: routeIsCurrent,
        didBeginPreemption: {
          publishSyncStatus(
            .syncing,
            connection: mailboxConnection,
            productAccountId: productSession.productAccountId
          )
        }
      )
      syncResult = await blockedSenderEnforcer.enforce(
        synchronizedResult,
        connection: mailboxConnection,
        session: productSession
      )
    } catch is CancellationError {
      publishSyncStatus(
        .idle,
        connection: mailboxConnection,
        productAccountId: productSession.productAccountId,
        supersedesHistoricalBackfill: false
      )
      throw CancellationError()
    } catch GmailMessageMetadataSyncError.staleLocalConnection {
      publishSyncStatus(
        .idle,
        connection: mailboxConnection,
        productAccountId: productSession.productAccountId,
        supersedesHistoricalBackfill: false
      )
      return false
    } catch MailboxConnectionAdapterError.connectionRemoved {
      publishSyncStatus(
        .idle,
        connection: mailboxConnection,
        productAccountId: productSession.productAccountId
      )
      return false
    } catch MailboxConnectionAdapterError.authorizationRequired {
      try watchStore.clear(
        productAccountId: productSession.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      publishSyncStatus(
        .idle,
        connection: mailboxConnection,
        productAccountId: productSession.productAccountId
      )
      return false
    } catch {
      publishSyncStatus(
        .failure(for: error),
        connection: mailboxConnection,
        productAccountId: productSession.productAccountId
      )
      let currentNotificationRules = try await failClosed {
        try await loadNotificationRules(
          profileResolution: profileResolution,
          session: productSession
        )
      }
      guard
        currentNotificationRules?.allowsNotifications(connectionId: mailboxConnection.id) == true
      else { throw error }
      _ = try await scheduleGenericFallback()
      return false
    }
    let successfulSyncAt = Date()
    successStore.save(
      successfulSyncAt,
      productAccountId: productSession.productAccountId,
      connectionId: mailboxConnection.id
    )
    if syncResult.providerCursorIsExpired {
      if try await visibleNotificationsAreSuppressed() {
        _ = try advanceWatermark()
      } else {
        _ = try await completeWithGenericFallback()
      }
      publishSyncStatus(
        .idle,
        connection: mailboxConnection,
        productAccountId: productSession.productAccountId,
        successfulSyncAt: successfulSyncAt
      )
      return false
    }
    publishSyncStatus(
      .idle,
      connection: mailboxConnection,
      productAccountId: productSession.productAccountId,
      successfulSyncAt: successfulSyncAt
    )
    guard currentWatchForRoute() != nil else { return false }
    guard notificationRules != nil else { return false }
    if try await visibleNotificationsAreSuppressed() {
      return try advanceWatermark()
    }
    let currentProfileResolution = try await failClosed {
      try await profileResolver.resolve(
        connectionId: mailboxConnection.id,
        session: productSession
      )
    }
    let currentNotificationRules = try await failClosed {
      try await loadNotificationRules(
        profileResolution: currentProfileResolution,
        session: productSession
      )
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
    guard let currentProfileResolution else { return false }
    var mutedNotificationCandidateIds: Set<String> = []
    for message in syncResult.messages
    where notificationCandidateIds.contains(message.providerMessageId) {
      let threadId = StableThreadIdentity(
        connectionId: mailboxConnection.id,
        providerThreadId: message.providerThreadId
      )
      if try await threadMuteSync.isMutedAuthoritatively(
        threadId,
        profileId: currentProfileResolution.deliveryContext.profileId,
        session: productSession
      ) {
        mutedNotificationCandidateIds.insert(message.providerMessageId)
      }
    }
    let unmutedNotificationCandidateIds = notificationCandidateIds.subtracting(
      mutedNotificationCandidateIds
    )
    let deliverableNotificationCandidateIds =
      syncResult.newMessageIds == nil && notificationCandidateIds.isEmpty
      ? nil : unmutedNotificationCandidateIds
    let notificationMessages: [GmailMessageMetadata]
    let notificationsAreEnabled = currentNotificationRules.allowsNotifications(
      connectionId: mailboxConnection.id
    )
    if !notificationsAreEnabled
      || deliverableNotificationCandidateIds == nil
    {
      notificationMessages = syncResult.messages.map(\.gmailMetadata)
    } else {
      let notificationCandidates = syncResult.messages.compactMap { message in
        deliverableNotificationCandidateIds?.contains(message.providerMessageId) == true
          ? message.gmailMetadata : nil
      }
      do {
        notificationMessages =
          try await backgroundCategorizer
          .categorizeForBackgroundNotification(
            messages: notificationCandidates,
            recordScope: currentProfileResolution.recordScope,
            session: productSession
          )
      } catch {
        try Task.checkCancellation()
        notificationMessages = notificationCandidates
      }
    }
    let canAdvanceWatermark =
      !notificationsAreEnabled
      || (syncResult.newMessageIds != nil && !syncResult.hasUnlistedNewMessages)
    let categoryProcessingIsIncomplete =
      notificationsAreEnabled
      && (syncResult.providerCursorIsExpired
        || syncResult.hasUnlistedNewMessages
        || syncResult.newMessageIds == nil
        || notificationMessages.contains { message in
          !message.isHistorical
            && unmutedNotificationCandidateIds.contains(message.providerMessageId)
            && message.messageCategoryIds.isEmpty
        })
    let notificationDeliveryResult = try await deliverCategoryAwareNotifications(
      for: notificationMessages,
      including: deliverableNotificationCandidateIds,
      connection: connection,
      deliveryContext: currentProfileResolution.deliveryContext,
      productAccountId: productSession.productAccountId,
      rules: currentNotificationRules,
      session: productSession,
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

  private func publishSyncStatus(
    _ phase: MailboxSyncPhase,
    connection: MailboxConnection,
    productAccountId: String,
    successfulSyncAt: Date? = nil,
    supersedesHistoricalBackfill: Bool = true
  ) {
    var userInfo: [AnyHashable: Any] = [
      MailboxSyncNotificationUserInfoKey.connectionId: connection.id.rawValue,
      MailboxSyncNotificationUserInfoKey.phase: phase,
      MailboxSyncNotificationUserInfoKey.productAccountId: productAccountId,
      MailboxSyncNotificationUserInfoKey.supersedesHistoricalBackfill:
        supersedesHistoricalBackfill,
    ]
    userInfo[MailboxSyncNotificationUserInfoKey.successfulSyncAt] = successfulSyncAt
    NotificationCenter.default.post(
      name: .mailboxMetadataDidSynchronize,
      object: nil,
      userInfo: userInfo
    )
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
        identifier: "gmail-generic-fallback:\(routeId):\(historyId)",
        productAccountId: productAccountId
      )
      try Task.checkCancellation()
      return true
    } ?? false
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length function_parameter_count
  private func deliverCategoryAwareNotifications(
    for messages: [GmailMessageMetadata],
    including newMessageIds: Set<String>?,
    connection: GmailProviderConnectionStatus,
    deliveryContext: NotificationDeliveryContext?,
    productAccountId: String,
    rules: NotificationRules?,
    session: ProductAccountSessionSnapshot,
    onProcessingFailure: () async throws -> Bool,
    routeIsCurrent: () -> Bool,
    watermarkIsCurrent: () -> Bool
  ) async throws -> CategoryNotificationDeliveryResult {
    guard let rules else { return .failed }
    let connectionId = connection.mailboxConnectionId
    guard rules.allowsNotifications(connectionId: connectionId) else { return .completed }
    guard let deliveryContext else { return .failed }
    guard let newMessageIds else {
      return (try await onProcessingFailure()) ? .fallbackDelivered : .failed
    }
    var notificationAuthorizationGranted = false
    for message in messages
    where !message.isHistorical
      && newMessageIds.contains(message.providerMessageId)
      && message.messageCategoryIds.contains(where: {
        rules.allows(categoryId: $0, connectionId: connectionId)
      })
    {
      let threadId = StableThreadIdentity(
        connectionId: connectionId,
        providerThreadId: message.providerThreadId
      )
      guard
        try await threadMuteSync.isMutedAuthoritatively(
          threadId,
          profileId: deliveryContext.profileId,
          session: session
        ) == false
      else { continue }
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
      if try await threadMuteSync.isMutedAuthoritatively(
        threadId,
        profileId: deliveryContext.profileId,
        session: session
      ) {
        try notificationReceiptStore.complete(
          message,
          productAccountId: productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        )
        continue
      }
      var notificationDelivered = false
      do {
        try await notificationDelivery.deliver(
          message: message,
          productAccountId: productAccountId,
          context: deliveryContext
        )
        notificationDelivered = true
        try Task.checkCancellation()
        // Persist successful delivery even if the route changed during the await. A replacement
        // route can then advance its own watermark without showing the same message again.
        try notificationReceiptStore.complete(
          message,
          productAccountId: productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        )
      } catch is CancellationError {
        if notificationDelivered {
          try notificationReceiptStore.complete(
            message,
            productAccountId: productAccountId,
            providerAccountIdentifier: connection.providerAccountIdentifier
          )
        } else {
          try notificationReceiptStore.release(
            message,
            productAccountId: productAccountId,
            providerAccountIdentifier: connection.providerAccountIdentifier
          )
        }
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

  private func loadNotificationRules(
    profileResolution: NotificationProfileResolution?,
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationRules {
    guard let profileResolution else {
      throw MailProfileSyncError.profileNotFound
    }
    let rules: NotificationRules
    if profileResolution.recordScope == .legacyProductAccount
      || !(notificationRuleSync is NotificationRuleSyncService)
    {
      rules = try await notificationRuleSync.loadRulesForBackground(session: session).rules
    } else {
      rules = try await NotificationRuleSyncService(
        recordScope: profileResolution.recordScope
      ).loadRulesForBackground(session: session).rules
    }
    guard !profileResolution.deliveryContext.isProfileQuiet else {
      return NotificationRules(
        isEnabled: false,
        categoryIds: rules.categoryIds,
        connectionPolicies: rules.connectionPolicies
      )
    }
    return rules
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
  import BackgroundTasks

  private let pushRegistrationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.unwired.mail",
    category: "push-registration"
  )

  enum MailRefreshBackgroundTask {
    static let identifier = "dev.unwired.mail.refresh"
    static let interval: TimeInterval = 12 * 60 * 60

    @discardableResult
    nonisolated static func run(
      reschedule: () -> Void,
      renewal: @escaping @MainActor () async throws -> Void,
      completion: @escaping @MainActor (Bool) -> Void,
      installExpirationHandler: (@escaping () -> Void) -> Void
    ) -> Task<Void, Never> {
      reschedule()
      let renewalTask = Task { @MainActor in
        do {
          try Task.checkCancellation()
          try await renewal()
          completion(!Task.isCancelled)
        } catch {
          completion(false)
        }
      }
      installExpirationHandler {
        renewalTask.cancel()
      }
      return renewalTask
    }
  }

  @MainActor
  final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate,
    @preconcurrency UNUserNotificationCenterDelegate
  {
    private let registrationRetrier: DevicePushRegistrationRetrier
    private var trustedDeviceRevoked: @MainActor (ProductAccountSessionSnapshot) async -> Void =
      ignoreBackgroundTrustedDeviceRevocation

    override init() {
      #if DEBUG
        registrationRetrier = DevicePushRegistrationRetrier(environment: .sandbox)
      #else
        registrationRetrier = DevicePushRegistrationRetrier(environment: .production)
      #endif
      super.init()
    }

    func configure(productAccountSession: ProductAccountSession) {
      trustedDeviceRevoked = { [weak productAccountSession] snapshot in
        await productAccountSession?.handleBackgroundTrustedDeviceRevocation(snapshot)
      }
    }

    func application(
      _: UIApplication,
      didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
      UNUserNotificationCenter.current().delegate = self
      BGTaskScheduler.shared.register(
        forTaskWithIdentifier: MailRefreshBackgroundTask.identifier,
        using: nil
      ) { task in
        guard let refreshTask = task as? BGAppRefreshTask else {
          task.setTaskCompleted(success: false)
          return
        }
        Self.handle(refreshTask, trustedDeviceRevoked: self.trustedDeviceRevoked)
      }
      Self.scheduleBackgroundRefresh()
      return true
    }

    func userNotificationCenter(
      _: UNUserNotificationCenter,
      didReceive response: UNNotificationResponse,
      withCompletionHandler completionHandler: @escaping () -> Void
    ) {
      let userInfo = response.notification.request.content.userInfo
      guard let deepLink = NotificationDeepLink(userInfo: userInfo) else {
        completionHandler()
        return
      }
      PendingNotificationDeepLinkStore.shared.remember(deepLink)
      NotificationCenter.default.post(
        name: .categoryNotificationDeepLink,
        object: deepLink
      )
      completionHandler()
    }

    func userNotificationCenter(
      _: UNUserNotificationCenter,
      willPresent notification: UNNotification,
      withCompletionHandler completionHandler:
        @escaping (UNNotificationPresentationOptions) ->
        Void
    ) {
      completionHandler(
        Self.foregroundPresentationOptions(
          userInfo: notification.request.content.userInfo
        )
      )
    }

    static func foregroundPresentationOptions(
      userInfo _: [AnyHashable: Any]
    ) -> UNNotificationPresentationOptions {
      [.banner, .badge, .sound]
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
          guard let productAccountId = try ProductAccountSessionStore.load()?.productAccountId
          else {
            completionHandler(.noData)
            return
          }
          let revocationRecorder = BackgroundRevocationRecorder()
          let handled = try await GmailPushWakeupCoordinator.shared.handle(
            productAccountId: productAccountId
          ) {
            let revalidator = BackgroundTrustedDeviceRevalidator(
              trustedDeviceRevoked: revocationRecorder.record
            )
            var handled = try await GmailPushWakeupHandler(
              profileResolver: ProductSyncNotificationProfileResolver(),
              revalidateTrustedDevice: revalidator.revalidate
            ).handle(userInfo: userInfo)
            if !handled {
              handled = try await MicrosoftGraphPushWakeupHandler(
                revalidateTrustedDevice: revalidator.revalidate
              ).handle(userInfo: userInfo)
            }
            return handled
          }
          if let revokedSession = revocationRecorder.session {
            await trustedDeviceRevoked(revokedSession)
          }
          completionHandler(handled ? .newData : .noData)
        } catch {
          completionHandler(.failed)
        }
      }
    }

    nonisolated private static func handle(
      _ refreshTask: BGAppRefreshTask,
      trustedDeviceRevoked:
        @escaping @MainActor (ProductAccountSessionSnapshot) async -> Void
    ) {
      MailRefreshBackgroundTask.run(
        reschedule: scheduleBackgroundRefresh,
        renewal: {
          guard let productAccountId = try ProductAccountSessionStore.load()?.productAccountId
          else { return }
          let revocationRecorder = BackgroundRevocationRecorder()
          _ = try await GmailPushWakeupCoordinator.shared.handle(
            productAccountId: productAccountId
          ) {
            let revalidator = BackgroundTrustedDeviceRevalidator(
              trustedDeviceRevoked: revocationRecorder.record
            )
            var firstError: Error?
            do {
              _ = try await MicrosoftGraphPushRenewalHandler(
                revalidateTrustedDevice: revalidator.revalidate
              ).handle()
            } catch {
              firstError = error
            }
            if !Task.isCancelled {
              do {
                try await StandardsMailBackgroundPoller(
                  revalidateTrustedDevice: revalidator.revalidate
                ).poll()
              } catch {
                firstError = firstError ?? error
              }
            }
            if Task.isCancelled { throw CancellationError() }
            if let firstError { throw firstError }
            return true
          }
          if let revokedSession = revocationRecorder.session {
            await trustedDeviceRevoked(revokedSession)
          }
        },
        completion: { success in
          refreshTask.setTaskCompleted(success: success)
        },
        installExpirationHandler: { expirationHandler in
          refreshTask.expirationHandler = expirationHandler
        }
      )
    }

    nonisolated private static func scheduleBackgroundRefresh() {
      let request = BGAppRefreshTaskRequest(identifier: MailRefreshBackgroundTask.identifier)
      request.earliestBeginDate = Date(
        timeIntervalSinceNow: MailRefreshBackgroundTask.interval
      )
      do {
        try BGTaskScheduler.shared.submit(request)
      } catch {
        pushRegistrationLogger.error(
          "Background refresh scheduling failed: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  @MainActor
  func requestDevicePushRegistration() {
    UIApplication.shared.registerForRemoteNotifications()
  }
#endif
