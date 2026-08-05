import Foundation

/// User-owned category preferences that control visible new-mail notifications.
///
/// The category identifiers are encrypted on the trusted device before Product Sync sees them.
/// An empty rule set is the default and never enables a generic notification fallback.
///
/// Example:
/// ```swift
/// let rules = NotificationRules(categoryIds: ["system:flights"])
/// if rules.allows(categoryId: "system:flights") {
///   // This category may produce a visible notification after local categorization.
/// }
/// ```
struct NotificationRules: Codable, Equatable, Sendable {
  static let primaryIdentifier = "notification-rules-primary"

  let categoryIds: [String]
  let schemaVersion: Int

  init(categoryIds: [String]) {
    self.categoryIds = Array(Set(categoryIds.filter { !$0.isEmpty })).sorted()
    schemaVersion = 1
  }

  func allows(categoryId: String) -> Bool {
    categoryIds.contains(categoryId)
  }
}

struct NotificationRuleSyncSnapshot: Equatable {
  let rules: NotificationRules
  private let revision: ProductSyncRecordRevision?

  var updatedAt: Int64? {
    revision?.legacyUpdatedAt
  }

  init(rules: NotificationRules, updatedAt: Int64?) {
    self.rules = rules
    revision = updatedAt.map(ProductSyncRecordRevision.init(legacyUpdatedAt:))
  }

  init(rules: NotificationRules, revision: ProductSyncRecordRevision?) {
    self.rules = rules
    self.revision = revision
  }
}

/// Synchronizes Notification Rules as opaque encrypted user data.
///
/// Example:
/// ```swift
/// let snapshot = try await NotificationRuleSyncService().loadRules(session: session)
/// if snapshot.rules.allows(categoryId: "system:flights") {
///   // A trusted device may show a category-aware notification.
/// }
/// ```
protocol NotificationRuleSyncing {
  func loadRules(
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot

  func loadRulesForBackground(
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot

  @discardableResult
  func saveRules(
    _ rules: NotificationRules,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot
}

extension NotificationRuleSyncing {
  func loadRulesForBackground(
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    try await loadRules(session: session)
  }
}

enum NotificationRuleSyncError: LocalizedError, Equatable {
  case concurrentModification
  case missingProductSyncKeyMaterial

  var errorDescription: String? {
    switch self {
    case .concurrentModification:
      return "Notification Rules changed on another device. Refresh before saving again."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing Notification Rules."
    }
  }
}

protocol NotificationRuleCachePersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> EncryptedProductSyncPayload?
  func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) throws
}

struct KeychainNotificationRuleCacheStore: NotificationRuleCachePersisting {
  private let service = "dev.unwired.mail.notification-rule-cache"

  func clear(productAccountId: String) throws {
    try KeychainStore.delete(service: service, account: productAccountId)
  }

  func load(productAccountId: String) throws -> EncryptedProductSyncPayload? {
    guard
      let rawValue = try KeychainStore.readString(service: service, account: productAccountId),
      let data = rawValue.data(using: .utf8)
    else {
      return nil
    }
    return try JSONDecoder().decode(EncryptedProductSyncPayload.self, from: data)
  }

  func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) throws {
    let data = try JSONEncoder().encode(payload)
    guard let rawValue = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(
      rawValue,
      service: service,
      account: productAccountId,
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }
}

private struct NotificationRuleSyncCiphertextCache: ProductSyncCiphertextCaching {
  private let store: NotificationRuleCachePersisting

  init(store: NotificationRuleCachePersisting) {
    self.store = store
  }

  func loadFamily(
    productAccountId _: String,
    payloadIdentifierPrefix _: String
  ) async throws -> [EncryptedProductSyncPayload]? {
    throw ProductSyncRecordBoundaryError.invalidPayloadIdentifier
  }

  func load(
    productAccountId: String,
    payloadIdentifier: String
  ) async throws -> EncryptedProductSyncPayload? {
    guard payloadIdentifier == NotificationRules.primaryIdentifier else { return nil }
    return try store.load(productAccountId: productAccountId)
  }

  func remove(productAccountId: String, payloadIdentifier: String) async throws {
    guard payloadIdentifier == NotificationRules.primaryIdentifier else { return }
    try store.clear(productAccountId: productAccountId)
  }

  func removeIfUnchanged(
    _ payload: EncryptedProductSyncPayload?,
    productAccountId: String,
    payloadIdentifier: String
  ) async throws {
    guard
      payloadIdentifier == NotificationRules.primaryIdentifier,
      try store.load(productAccountId: productAccountId) == payload
    else {
      return
    }
    try store.clear(productAccountId: productAccountId)
  }

  func replaceFamily(
    _: [EncryptedProductSyncPayload],
    productAccountId _: String,
    payloadIdentifierPrefix _: String
  ) async throws {
    throw ProductSyncRecordBoundaryError.invalidPayloadIdentifier
  }

  func save(
    _ payload: EncryptedProductSyncPayload,
    productAccountId: String
  ) async throws {
    guard payload.payloadIdentifier == NotificationRules.primaryIdentifier else {
      throw ProductSyncRecordBoundaryError.invalidPayloadIdentifier
    }
    try store.save(payload, productAccountId: productAccountId)
  }
}

final class NotificationRuleSyncService: NotificationRuleSyncing {
  private let authorizationStateChecker: ProductAccountAuthorizationStateChecking
  private let notificationRecord: ProductSyncSingletonHandle<NotificationRules>
  private let now: () -> Date

  init(
    authorizationStateChecker: ProductAccountAuthorizationStateChecking =
      AppleAuthorizationStateChecker(),
    cacheStore: NotificationRuleCachePersisting = KeychainNotificationRuleCacheStore(),
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    now: @escaping () -> Date = Date.init,
    transport: ProductSyncPayloadTransport = ConvexClient()
  ) {
    self.authorizationStateChecker = authorizationStateChecker
    self.now = now
    notificationRecord = ProductSyncRecordBoundary(
      cache: NotificationRuleSyncCiphertextCache(store: cacheStore),
      keyMaterialStore: keyMaterialStore,
      transport: ProductSyncPayloadRecordTransport(transport)
    ).singleton(
      ProductSyncSingletonDefinition(
        identifier: NotificationRules.primaryIdentifier,
        cachePolicy: .invalidateBeforeWriteAndRefresh
      )
    )
  }

  func loadRules(
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    do {
      return try await loadAuthoritativeRules(
        session: session,
        cacheSaveFailuresAreFatal: false
      )
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func loadRulesForBackground(
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    do {
      return try await loadAuthoritativeRules(
        session: session,
        cacheSaveFailuresAreFatal: true
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard
        error as? ConvexClientError == .httpError(statusCode: 401),
        session.identityTokenState(at: now()) == .expired,
        await authorizationStateChecker.authorizationState(
          forAppleUserIdentifier: session.appleUserIdentifier
        ) == .authorized,
        let cachedRecord = try await notificationRecord.readCached(session: session)
      else {
        throw mapBoundaryError(error)
      }
      return NotificationRuleSyncSnapshot(
        rules: cachedRecord.value,
        revision: cachedRecord.revision
      )
    }
  }

  private func loadAuthoritativeRules(
    session: ProductAccountSessionSnapshot,
    cacheSaveFailuresAreFatal: Bool
  ) async throws -> NotificationRuleSyncSnapshot {
    guard
      let record = try await notificationRecord.readAuthoritativeRefreshingCache(
        session: session,
        cacheSaveFailuresAreFatal: cacheSaveFailuresAreFatal
      )
    else {
      return NotificationRuleSyncSnapshot(
        rules: NotificationRules(categoryIds: []),
        revision: nil
      )
    }
    return NotificationRuleSyncSnapshot(
      rules: record.value,
      revision: record.revision
    )
  }

  @discardableResult
  func saveRules(
    _ rules: NotificationRules,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    do {
      let expectedRevision = expectedUpdatedAt.map(
        ProductSyncRecordRevision.init(legacyUpdatedAt:)
      )
      switch try await notificationRecord.writeIfUnchanged(
        rules,
        expectedRevision: expectedRevision,
        session: session
      ) {
      case .committed(let record):
        return NotificationRuleSyncSnapshot(rules: record.value, revision: record.revision)
      case .conflict:
        throw NotificationRuleSyncError.concurrentModification
      }
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func mapBoundaryError(_ error: Error) -> Error {
    guard error as? ProductSyncRecordBoundaryError == .missingProductSyncKeyMaterial else {
      return error
    }
    return NotificationRuleSyncError.missingProductSyncKeyMaterial
  }
}
