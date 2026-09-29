import CryptoKit
import Foundation

public struct SyntheticCredential {
  private let keychain: DeviceKeychain

  public init(service: String) {
    keychain = DeviceKeychain(service: service + ".synthetic-credential")
  }

  public func store() throws {
    if try keychain.read("secret") != nil { return }
    let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    try keychain.insert(secret, account: "secret")
  }

  public func use() throws -> String {
    guard let secret = try keychain.read("secret") else { throw PrivateInboxError.locked }
    let proof = HMAC<SHA256>.authenticationCode(
      for: Data("synthetic-local-challenge".utf8),
      using: SymmetricKey(data: secret))
    return Data(proof).base64EncodedString()
  }

  public func remove() throws {
    try keychain.remove("secret")
  }
}
