import Foundation
import Security

protocol MailboxConnectionSyncCachePersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> EncryptedProductSyncPayload?
  func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) throws
}

protocol MailboxCleanupReceiptPersisting {
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

struct KeychainMailboxCleanupReceiptStore:
  MailboxCleanupReceiptPersisting
{
  private static let lock = NSLock()
  private let service = "dev.unwired.mail.mailbox-connection-cleanup-receipts"

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
  private let service = "dev.unwired.mail.mailbox-connection-sync-cache"

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

#if DEBUG || TESTING
  final class InMemoryMailboxCleanupReceiptStore:
    MailboxCleanupReceiptPersisting
  {
    private var generations: [String: Int] = [:]

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

    func load(productAccountId: String) throws -> EncryptedProductSyncPayload? {
      payloads[productAccountId]
    }

    func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) throws {
      payloads[productAccountId] = payload
    }
  }
#endif
