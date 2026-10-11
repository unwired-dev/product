import Foundation

// Mail Assistance Enablement: the Mail Profiles of the signed-in Product Account that permit
// On-Device Mail Assistance on this device. It is a device-only Keychain item, never synchronized,
// and every account purge removes it, so sign-out, deletion and device removal turn it off.
extension RegistrationStore {
  func mailAssistanceAccount(_ productAccountId: String) -> String {
    "mail-assistance." + productAccountId
  }

  // The signed-in, admitted Product Account, unless its removal began; otherwise nothing is enabled.
  func mailAssistanceOwner() throws -> String? {
    guard let saved = try load(), saved.accountRemoval == nil, let product = saved.product,
      product.pending != true
    else { return nil }
    return product.productAccountId
  }

  func mailAssistance() throws -> [String: Any] {
    guard let owner = try mailAssistanceOwner() else {
      return ["owner": NSNull(), "profiles": [String]()]
    }
    let profiles =
      try keys.read(mailAssistanceAccount(owner)).map {
        try JSONDecoder().decode([String].self, from: $0)
      } ?? []
    return ["owner": owner, "profiles": profiles]
  }

  // A change read for another Product Account, or after its removal began, changes nothing.
  func setMailAssistance(owner: String, profiles: [String]) throws -> [String: Any] {
    guard try mailAssistanceOwner() == owner else { throw PrivateInboxError.mailboxInvalidated }
    try keys.save(JSONEncoder().encode(profiles), account: mailAssistanceAccount(owner))
    return ["owner": owner, "profiles": profiles]
  }
}
