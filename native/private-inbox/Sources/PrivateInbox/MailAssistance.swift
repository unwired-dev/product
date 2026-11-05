import Foundation

// Mail Assistance Enablement: the Mail Profiles of the signed-in Product Account that permit
// On-Device Mail Assistance on this device, and those that also permit Private Cloud Mail
// Assistance. It is a device-only Keychain item, never synchronized, and every account purge
// removes it, so sign-out, deletion and device removal turn it off.
extension RegistrationStore {
  struct MailAssistanceChoice: Codable {
    var profiles: [String]
    var privateCloud: [String]
  }

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
      return ["owner": NSNull(), "profiles": [String](), "privateCloud": [String]()]
    }
    let choice =
      try keys.read(mailAssistanceAccount(owner)).map { data in
        // An item saved before Private Cloud consent lists only the local Profiles.
        if let profiles = try? JSONDecoder().decode([String].self, from: data) {
          return MailAssistanceChoice(profiles: profiles, privateCloud: [])
        }
        return try JSONDecoder().decode(MailAssistanceChoice.self, from: data)
      } ?? MailAssistanceChoice(profiles: [], privateCloud: [])
    return ["owner": owner, "profiles": choice.profiles, "privateCloud": choice.privateCloud]
  }

  // A change read for another Product Account, or after its removal began, changes nothing.
  func setMailAssistance(owner: String, profiles: [String], privateCloud: [String]) throws
    -> [String: Any]
  {
    guard try mailAssistanceOwner() == owner else { throw PrivateInboxError.mailboxInvalidated }
    let choice = MailAssistanceChoice(profiles: profiles, privateCloud: privateCloud)
    try keys.save(JSONEncoder().encode(choice), account: mailAssistanceAccount(owner))
    return ["owner": owner, "profiles": profiles, "privateCloud": privateCloud]
  }
}
