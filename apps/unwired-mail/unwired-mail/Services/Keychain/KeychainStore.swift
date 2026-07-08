import Foundation
import Security

enum KeychainStoreError: LocalizedError, Equatable {
  case unexpectedData
  case unhandledStatus(OSStatus)

  var errorDescription: String? {
    switch self {
    case .unexpectedData:
      return "Keychain returned unexpected data."
    case .unhandledStatus(let status):
      return "Keychain operation failed with status \(status)."
    }
  }
}

enum KeychainStore {
  static func readString(service: String, account: String) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)

    if status == errSecItemNotFound {
      return nil
    }

    guard status == errSecSuccess else {
      throw KeychainStoreError.unhandledStatus(status)
    }

    guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }

    return value
  }

  static func writeString(_ value: String, service: String, account: String) throws {
    let data = Data(value.utf8)

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]

    let attributes: [String: Any] = [
      kSecValueData as String: data
    ]

    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }

    if updateStatus == errSecItemNotFound {
      var addQuery = query
      addQuery[kSecValueData as String] = data
      let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw KeychainStoreError.unhandledStatus(addStatus)
      }
      return
    }

    throw KeychainStoreError.unhandledStatus(updateStatus)
  }

  static func delete(service: String, account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]

    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainStoreError.unhandledStatus(status)
    }
  }
}
