import Foundation
import Security

public enum PrivateInboxError: Error, Equatable {
  case locked
  case invalidStore
  case unavailable
  // The mailbox cache changed since the caller read it.
  case conflict
  case mailboxInvalidated
  // A Downloaded Attachment or Draft asset the device no longer has.
  case attachmentMissing
  // A Draft asset over the per-file limit or the Outgoing Content Store's remaining space.
  case tooLarge
  // A message send failed after its request may have reached Gmail, so it may have been sent.
  case deliveryUnknown
}

struct DeviceKeychain {
  let service: String

  // Only an unavailable protected-data state recovers on unlock; other failures do not.
  static func failure(_ status: OSStatus) -> PrivateInboxError {
    status == errSecInteractionNotAllowed ? .locked : .unavailable
  }

  func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  func read(_ account: String) throws -> Data? {
    var request = query(account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw Self.failure(status)
    }
    return data
  }

  func insert(_ data: Data, account: String) throws {
    var request = query(account)
    request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    request[kSecValueData as String] = data
    let status = SecItemAdd(request as CFDictionary, nil)
    guard status == errSecSuccess else { throw Self.failure(status) }
  }

  func remove(_ account: String) throws {
    let status = SecItemDelete(query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Self.failure(status)
    }
  }

  func save(_ data: Data, account: String) throws {
    let status = SecItemUpdate(
      query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      try insert(data, account: account)
      return
    }
    guard status == errSecSuccess else { throw Self.failure(status) }
  }
}
