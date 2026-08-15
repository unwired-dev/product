import Foundation

struct UserDefaultsMailAssistanceStore: MailAssistanceEnablementPersisting {
  private static let keyPrefix = "mail-assistance-enablement.v1."
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(productAccountId: String) {
    let prefix = Self.keyPrefix + productAccountId + "."
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
      defaults.removeObject(forKey: key)
    }
  }

  func isEnabled(
    productAccountId: String,
    profileId: MailProfileId
  ) -> Bool {
    defaults.object(
      forKey: key(productAccountId: productAccountId, profileId: profileId)
    ) as? Bool ?? false
  }

  func setEnabled(
    _ isEnabled: Bool,
    productAccountId: String,
    profileId: MailProfileId
  ) {
    defaults.set(
      isEnabled,
      forKey: key(productAccountId: productAccountId, profileId: profileId)
    )
  }

  private func key(productAccountId: String, profileId: MailProfileId) -> String {
    Self.keyPrefix + productAccountId + "." + profileId.rawValue
  }
}
