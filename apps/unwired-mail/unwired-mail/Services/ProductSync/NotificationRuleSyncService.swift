import Foundation

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
  func clear(productAccountId: String, payloadIdentifier: String) throws
  func load(
    productAccountId: String,
    payloadIdentifier: String
  ) throws -> EncryptedProductSyncPayload?
  func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) throws
}

struct KeychainNotificationRuleCacheStore: NotificationRuleCachePersisting {
  private let service = "dev.unwired.mail.notification-rule-cache"

  func clear(productAccountId: String) throws {
    try KeychainStore.delete(service: service, account: productAccountId)
  }

  func clear(productAccountId: String, payloadIdentifier: String) throws {
    var payloads = try loadPayloads(productAccountId: productAccountId)
    payloads[payloadIdentifier] = nil
    try savePayloads(payloads, productAccountId: productAccountId)
  }

  func load(
    productAccountId: String,
    payloadIdentifier: String
  ) throws -> EncryptedProductSyncPayload? {
    try loadPayloads(productAccountId: productAccountId)[payloadIdentifier]
  }

  func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) throws {
    var payloads = try loadPayloads(productAccountId: productAccountId)
    payloads[payload.payloadIdentifier] = payload
    try savePayloads(payloads, productAccountId: productAccountId)
  }

  private func loadPayloads(
    productAccountId: String
  ) throws -> [String: EncryptedProductSyncPayload] {
    guard
      let rawValue = try KeychainStore.readString(service: service, account: productAccountId),
      let data = rawValue.data(using: .utf8)
    else {
      return [:]
    }
    if let payloads = try? JSONDecoder().decode(
      [String: EncryptedProductSyncPayload].self,
      from: data
    ) {
      return payloads
    }
    let legacyPayload = try JSONDecoder().decode(EncryptedProductSyncPayload.self, from: data)
    return [legacyPayload.payloadIdentifier: legacyPayload]
  }

  private func savePayloads(
    _ payloads: [String: EncryptedProductSyncPayload],
    productAccountId: String
  ) throws {
    guard !payloads.isEmpty else {
      try clear(productAccountId: productAccountId)
      return
    }
    let data = try JSONEncoder().encode(payloads)
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
  private let supportedPayloadIdentifiers: Set<String>

  init(
    store: NotificationRuleCachePersisting,
    supportedPayloadIdentifiers: Set<String>
  ) {
    self.store = store
    self.supportedPayloadIdentifiers = supportedPayloadIdentifiers
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
    guard supportedPayloadIdentifiers.contains(payloadIdentifier) else { return nil }
    return try store.load(
      productAccountId: productAccountId,
      payloadIdentifier: payloadIdentifier
    )
  }

  func remove(productAccountId: String, payloadIdentifier: String) async throws {
    guard supportedPayloadIdentifiers.contains(payloadIdentifier) else { return }
    try store.clear(productAccountId: productAccountId, payloadIdentifier: payloadIdentifier)
  }

  func removeIfUnchanged(
    _ payload: EncryptedProductSyncPayload?,
    productAccountId: String,
    payloadIdentifier: String
  ) async throws {
    guard
      supportedPayloadIdentifiers.contains(payloadIdentifier),
      try store.load(
        productAccountId: productAccountId,
        payloadIdentifier: payloadIdentifier
      ) == payload
    else {
      return
    }
    try store.clear(productAccountId: productAccountId, payloadIdentifier: payloadIdentifier)
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
    guard supportedPayloadIdentifiers.contains(payload.payloadIdentifier) else {
      throw ProductSyncRecordBoundaryError.invalidPayloadIdentifier
    }
    try store.save(payload, productAccountId: productAccountId)
  }
}

final class NotificationRuleSyncService: NotificationRuleSyncing {
  private let authorizationStateChecker: ProductAccountAuthorizationStateChecking
  private let legacyNotificationRecord: ProductSyncSingletonHandle<NotificationRules>?
  private let notificationRecord: ProductSyncSingletonHandle<NotificationRules>
  private let now: () -> Date

  init(
    authorizationStateChecker: ProductAccountAuthorizationStateChecking =
      AppleAuthorizationStateChecker(),
    cacheStore: NotificationRuleCachePersisting = KeychainNotificationRuleCacheStore(),
    now: @escaping () -> Date = Date.init,
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary(),
    recordScope: MailProfileRecordScope = .legacyProductAccount
  ) {
    self.authorizationStateChecker = authorizationStateChecker
    self.now = now
    let payloadIdentifier = recordScope.productSyncIdentifier(NotificationRules.primaryIdentifier)
    let legacyPayloadIdentifier = recordScope.productSyncIdentifier(
      NotificationRules.legacyIdentifier
    )
    let cachedBoundary = recordBoundary.caching(
      NotificationRuleSyncCiphertextCache(
        store: cacheStore,
        supportedPayloadIdentifiers: [payloadIdentifier, legacyPayloadIdentifier]
      )
    )
    notificationRecord = cachedBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: payloadIdentifier,
        cachePolicy: .invalidateBeforeWriteAndRefresh
      )
    )
    legacyNotificationRecord =
      recordScope == .legacyProductAccount
      ? cachedBoundary.singleton(
        ProductSyncSingletonDefinition(
          identifier: legacyPayloadIdentifier,
          cachePolicy: .authoritative
        )
      )
      : nil
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
        ) == .authorized
      else {
        throw mapBoundaryError(error)
      }
      if let cachedRecord = try await notificationRecord.readCached(session: session) {
        return NotificationRuleSyncSnapshot(
          rules: cachedRecord.value,
          revision: cachedRecord.revision
        )
      }
      if let legacyNotificationRecord,
        let cachedRecord = try await legacyNotificationRecord.readCached(session: session)
      {
        return NotificationRuleSyncSnapshot(
          rules: cachedRecord.value,
          revision: cachedRecord.revision
        )
      }
      throw mapBoundaryError(error)
    }
  }

  private func loadAuthoritativeRules(
    session: ProductAccountSessionSnapshot,
    cacheSaveFailuresAreFatal: Bool
  ) async throws -> NotificationRuleSyncSnapshot {
    if let record = try await notificationRecord.readAuthoritativeRefreshingCache(
      session: session,
      cacheSaveFailuresAreFatal: cacheSaveFailuresAreFatal
    ) {
      return NotificationRuleSyncSnapshot(
        rules: record.value,
        revision: record.revision
      )
    }
    guard
      let legacyNotificationRecord,
      let legacyRecord = try await legacyNotificationRecord.read(session: session)
    else {
      return NotificationRuleSyncSnapshot(
        rules: NotificationRules(categoryIds: []),
        revision: nil
      )
    }
    let migratedRules = NotificationRules(
      isEnabled: !legacyRecord.value.categoryIds.isEmpty,
      categoryIds: legacyRecord.value.categoryIds,
      connectionPolicies: []
    )
    switch try await notificationRecord.writeIfUnchanged(
      migratedRules,
      expectedRevision: nil,
      session: session
    ) {
    case .committed(let record):
      await legacyNotificationRecord.clearCache(session: session)
      return NotificationRuleSyncSnapshot(rules: record.value, revision: record.revision)
    case .conflict(let record):
      return NotificationRuleSyncSnapshot(rules: record.value, revision: record.revision)
    }
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
        if let legacyNotificationRecord {
          await legacyNotificationRecord.clearCache(session: session)
        }
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
