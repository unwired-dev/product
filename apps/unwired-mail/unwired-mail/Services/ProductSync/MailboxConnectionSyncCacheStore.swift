import Foundation
import Security

protocol MailboxConnectionSyncCachePersisting {
  func clear(productAccountId: String) throws
  func clearIfUnchanged(
    _ payload: EncryptedProductSyncPayload?,
    productAccountId: String
  ) throws
  func load(productAccountId: String) throws -> EncryptedProductSyncPayload?
  func replaceIfNotOlder(_ payload: EncryptedProductSyncPayload, productAccountId: String) throws
  func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) throws
}

protocol MailboxCleanupReceiptPersisting {
  func clear(productAccountId: String) throws
  func generation(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> Int?
  func record(
    generation: Int,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws
}

struct MailboxConnectionSyncCiphertextCache: ProductSyncCiphertextCaching {
  private let store: MailboxConnectionSyncCachePersisting

  init(store: MailboxConnectionSyncCachePersisting) {
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
    guard payloadIdentifier == MailboxConnectionSyncPayload.primaryIdentifier else {
      return nil
    }
    return try store.load(productAccountId: productAccountId)
  }

  func remove(productAccountId: String, payloadIdentifier: String) async throws {
    guard payloadIdentifier == MailboxConnectionSyncPayload.primaryIdentifier else { return }
    try store.clear(productAccountId: productAccountId)
  }

  func removeIfUnchanged(
    _ payload: EncryptedProductSyncPayload?,
    productAccountId: String,
    payloadIdentifier: String
  ) async throws {
    guard payloadIdentifier == MailboxConnectionSyncPayload.primaryIdentifier else { return }
    try store.clearIfUnchanged(payload, productAccountId: productAccountId)
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
    guard payload.payloadIdentifier == MailboxConnectionSyncPayload.primaryIdentifier else {
      throw ProductSyncRecordBoundaryError.invalidPayloadIdentifier
    }
    try store.replaceIfNotOlder(payload, productAccountId: productAccountId)
  }
}

struct KeychainMailboxCleanupReceiptStore:
  MailboxCleanupReceiptPersisting
{
  private static let lock = NSLock()
  private let service = "dev.unwired.mail.mailbox-connection-cleanup-receipts"

  func clear(productAccountId: String) throws {
    try Self.lock.withLock {
      try KeychainStore.delete(service: service, account: productAccountId)
    }
  }

  func generation(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> Int? {
    try Self.lock.withLock {
      try load(productAccountId: productAccountId)[connectionId.rawValue]
    }
  }

  func record(
    generation: Int,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    try Self.lock.withLock {
      var generations = try load(productAccountId: productAccountId)
      generations[connectionId.rawValue] = max(
        generation,
        generations[connectionId.rawValue] ?? 0
      )
      let data = try JSONEncoder().encode(generations)
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

  private func load(productAccountId: String) throws -> [String: Int] {
    guard
      let rawValue = try KeychainStore.readString(service: service, account: productAccountId),
      let data = rawValue.data(using: .utf8)
    else {
      return [:]
    }
    return try JSONDecoder().decode([String: Int].self, from: data)
  }
}

struct KeychainMailboxConnectionSyncCacheStore: MailboxConnectionSyncCachePersisting {
  private static let lock = NSLock()
  private let service = "dev.unwired.mail.mailbox-connection-sync-cache"

  func clear(productAccountId: String) throws {
    try Self.lock.withLock {
      try KeychainStore.delete(service: service, account: productAccountId)
    }
  }

  func clearIfUnchanged(
    _ payload: EncryptedProductSyncPayload?,
    productAccountId: String
  ) throws {
    try Self.lock.withLock {
      let existing: EncryptedProductSyncPayload?
      if let rawValue = try KeychainStore.readString(service: service, account: productAccountId),
        let data = rawValue.data(using: .utf8)
      {
        existing = try JSONDecoder().decode(
          EncryptedProductSyncPayload.self,
          from: data
        )
      } else {
        existing = nil
      }
      guard existing == payload else { return }
      try KeychainStore.delete(service: service, account: productAccountId)
    }
  }

  func load(productAccountId: String) throws -> EncryptedProductSyncPayload? {
    try Self.lock.withLock {
      guard
        let rawValue = try KeychainStore.readString(service: service, account: productAccountId),
        let data = rawValue.data(using: .utf8)
      else {
        return nil
      }
      return try JSONDecoder().decode(EncryptedProductSyncPayload.self, from: data)
    }
  }

  func replaceIfNotOlder(
    _ payload: EncryptedProductSyncPayload,
    productAccountId: String
  ) throws {
    try Self.lock.withLock {
      if let rawValue = try KeychainStore.readString(service: service, account: productAccountId),
        let data = rawValue.data(using: .utf8),
        let existing = try? JSONDecoder().decode(EncryptedProductSyncPayload.self, from: data),
        existing.updatedAt > payload.updatedAt
      {
        return
      }
      try saveUnlocked(payload, productAccountId: productAccountId)
    }
  }

  func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) throws {
    try Self.lock.withLock {
      try saveUnlocked(payload, productAccountId: productAccountId)
    }
  }

  private func saveUnlocked(
    _ payload: EncryptedProductSyncPayload,
    productAccountId: String
  ) throws {
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

#if DEBUG || TESTING
  final class InMemoryMailboxCleanupReceiptStore:
    MailboxCleanupReceiptPersisting
  {
    private var generations: [String: Int] = [:]

    func clear(productAccountId: String) throws {
      let prefix = "\(productAccountId)\0"
      generations = generations.filter { !$0.key.hasPrefix(prefix) }
    }

    func generation(
      productAccountId: String,
      connectionId: MailboxConnectionId
    ) throws -> Int? {
      generations[key(productAccountId, connectionId)]
    }

    func record(
      generation: Int,
      productAccountId: String,
      connectionId: MailboxConnectionId
    ) throws {
      let key = key(productAccountId, connectionId)
      generations[key] = max(generation, generations[key] ?? 0)
    }

    private func key(
      _ productAccountId: String,
      _ connectionId: MailboxConnectionId
    ) -> String {
      "\(productAccountId)\0\(connectionId.rawValue)"
    }
  }

  final class InMemoryMailboxConnectionSyncCacheStore: MailboxConnectionSyncCachePersisting {
    private var payloads: [String: EncryptedProductSyncPayload] = [:]

    func clear(productAccountId: String) throws {
      payloads[productAccountId] = nil
    }

    func clearIfUnchanged(
      _ payload: EncryptedProductSyncPayload?,
      productAccountId: String
    ) throws {
      guard payloads[productAccountId] == payload else { return }
      payloads[productAccountId] = nil
    }

    func load(productAccountId: String) throws -> EncryptedProductSyncPayload? {
      payloads[productAccountId]
    }

    func replaceIfNotOlder(
      _ payload: EncryptedProductSyncPayload,
      productAccountId: String
    ) throws {
      guard (payloads[productAccountId]?.updatedAt ?? .min) <= payload.updatedAt else {
        return
      }
      payloads[productAccountId] = payload
    }

    func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) throws {
      payloads[productAccountId] = payload
    }
  }
#endif
