import Foundation
import Security

protocol MailboxConnectionSyncCachePersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> EncryptedProductSyncPayload?
  func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) throws
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
