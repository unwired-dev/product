import CryptoKit
import Foundation

@testable import PrivateInbox

// A test-only Keychain credential beside the Private Inbox database.
struct SyntheticCredential {
  private let keychain: DeviceKeychain

  init(service: String) {
    keychain = DeviceKeychain(service: service + ".synthetic-credential")
  }

  func store() throws {
    if try keychain.read("secret") != nil { return }
    let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    try keychain.insert(secret, account: "secret")
  }

  func use() throws -> String {
    guard let secret = try keychain.read("secret") else { throw PrivateInboxError.locked }
    let proof = HMAC<SHA256>.authenticationCode(
      for: Data("synthetic-local-challenge".utf8),
      using: SymmetricKey(data: secret))
    return Data(proof).base64EncodedString()
  }

  func remove() throws {
    try keychain.remove("secret")
  }
}
