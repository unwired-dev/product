import Foundation

protocol MailAssistanceEnablementPersisting {
  func clear(productAccountId: String)
  func isEnabled(productAccountId: String, profileId: MailProfileId) -> Bool
  func setEnabled(
    _ isEnabled: Bool,
    productAccountId: String,
    profileId: MailProfileId
  )
}
