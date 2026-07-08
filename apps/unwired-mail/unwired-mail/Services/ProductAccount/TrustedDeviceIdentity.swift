import Foundation

enum TrustedDeviceIdentity {
  private static let service = "dev.unwired.mail.trusted-device"
  private static let account = "device-identifier"

  static func currentIdentifier() throws -> String {
    if let existing = try KeychainStore.readString(service: service, account: account) {
      return existing
    }

    let identifier = UUID().uuidString
    try KeychainStore.writeString(identifier, service: service, account: account)
    return identifier
  }

  static var platform: String {
    #if targetEnvironment(macCatalyst)
      return "macos"
    #else
      return "ios"
    #endif
  }
}
