import Foundation
import Security

public enum PrivateInboxError: Error, Equatable {
  case locked
  case invalidStore
  case unavailable
}

struct DeviceKeychain {
  let service: String

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
      throw PrivateInboxError.locked
    }
    return data
  }

  func insert(_ data: Data, account: String) throws {
    var request = query(account)
    request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    request[kSecValueData as String] = data
    guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else {
      throw PrivateInboxError.locked
    }
  }

  func remove(_ account: String) throws {
    let status = SecItemDelete(query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PrivateInboxError.locked
    }
  }
}
