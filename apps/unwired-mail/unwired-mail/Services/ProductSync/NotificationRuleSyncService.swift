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
struct NotificationRules: Codable, Equatable {
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
  let updatedAt: Int64?
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

final class NotificationRuleSyncService: NotificationRuleSyncing {
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()
  private let cacheStore: NotificationRuleCachePersisting
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let transport: ProductSyncPayloadTransport

  init(
    cacheStore: NotificationRuleCachePersisting = KeychainNotificationRuleCacheStore(),
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    transport: ProductSyncPayloadTransport = ConvexClient()
  ) {
    self.cacheStore = cacheStore
    self.keyMaterialStore = keyMaterialStore
    self.transport = transport
  }

  func loadRules(
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    let syncedPayload = try await loadRemotePayload(session: session)
    return try refreshCacheAndDecrypt(syncedPayload, session: session)
  }

  func loadRulesForBackground(
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    let syncedPayload: EncryptedProductSyncPayload?
    do {
      syncedPayload = try await loadRemotePayload(session: session)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard let cachedPayload = try cacheStore.load(productAccountId: session.productAccountId)
      else {
        throw error
      }
      return try decrypt(cachedPayload, session: session)
    }
    return try refreshCacheAndDecrypt(syncedPayload, session: session)
  }

  private func refreshCacheAndDecrypt(
    _ syncedPayload: EncryptedProductSyncPayload?,
    session: ProductAccountSessionSnapshot
  ) throws -> NotificationRuleSyncSnapshot {
    guard let syncedPayload else {
      try cacheStore.clear(productAccountId: session.productAccountId)
      return NotificationRuleSyncSnapshot(
        rules: NotificationRules(categoryIds: []),
        updatedAt: nil
      )
    }
    let snapshot = try decrypt(syncedPayload, session: session)
    try cacheStore.save(syncedPayload, productAccountId: session.productAccountId)
    return snapshot
  }

  private func decrypt(
    _ syncedPayload: EncryptedProductSyncPayload,
    session: ProductAccountSessionSnapshot
  ) throws -> NotificationRuleSyncSnapshot {
    guard let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw NotificationRuleSyncError.missingProductSyncKeyMaterial
    }
    let plaintext = try material.decryptPayload(
      syncedPayload.encryptedPayload,
      associatedData: associatedData
    )
    return NotificationRuleSyncSnapshot(
      rules: try decoder.decode(NotificationRules.self, from: plaintext),
      updatedAt: syncedPayload.updatedAt
    )
  }

  @discardableResult
  func saveRules(
    _ rules: NotificationRules,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> NotificationRuleSyncSnapshot {
    let material = try await keyMaterialForWrite(session: session)
    let plaintext = try encoder.encode(rules)
    let encryptedPayload = try material.encryptPayload(plaintext, associatedData: associatedData)
    let writtenPayload = try await transport.putEncryptedProductSyncPayloadIfUnchanged(
      identityToken: session.identityToken,
      payloadIdentifier: NotificationRules.primaryIdentifier,
      encryptedPayload: encryptedPayload,
      trustedDeviceId: session.trustedDeviceId,
      expectedUpdatedAt: expectedUpdatedAt
    )
    guard writtenPayload.encryptedPayload == encryptedPayload else {
      throw NotificationRuleSyncError.concurrentModification
    }
    try cacheStore.save(writtenPayload, productAccountId: session.productAccountId)
    return NotificationRuleSyncSnapshot(rules: rules, updatedAt: writtenPayload.updatedAt)
  }

  private var associatedData: Data {
    Data(NotificationRules.primaryIdentifier.utf8)
  }

  private func keyMaterialForWrite(
    session: ProductAccountSessionSnapshot
  ) async throws -> ProductSyncKeyMaterial {
    if let material = try keyMaterialStore.load(productAccountId: session.productAccountId) {
      return material
    }
    throw NotificationRuleSyncError.missingProductSyncKeyMaterial
  }

  private func loadRemotePayload(
    session: ProductAccountSessionSnapshot
  ) async throws -> EncryptedProductSyncPayload? {
    try await transport.getEncryptedProductSyncPayload(
      identityToken: session.identityToken,
      payloadIdentifier: NotificationRules.primaryIdentifier
    )
  }
}
