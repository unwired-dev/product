import Foundation
import Security

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

enum TrustedDeviceIdentity {
  private static let service = "dev.unwired.mail.trusted-device"
  private static let account = "device-identifier"

  static func currentIdentifier() throws -> String {
    if let existing = try KeychainStore.readString(service: service, account: account) {
      return existing
    }

    let identifier = UUID().uuidString
    try KeychainStore.writeString(
      identifier,
      service: service,
      account: account,
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
    return identifier
  }

  static var platform: String {
    #if targetEnvironment(macCatalyst)
      return "macos"
    #else
      return "ios"
    #endif
  }

  static var displayName: String {
    #if canImport(UIKit)
      let name = UIDevice.current.name
    #elseif canImport(AppKit)
      let name = Host.current().localizedName ?? ""
    #else
      let name = ""
    #endif
    return normalizedDisplayName(name, platform: platform)
  }

  static func normalizedDisplayName(_ name: String, platform: String) -> String {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      return platform == "macos" ? "This Mac" : "This Apple Device"
    }
    var remainingUTF16Units = 80
    return String(
      normalizedName.prefix { character in
        let unitCount = String(character).utf16.count
        guard unitCount <= remainingUTF16Units else { return false }
        remainingUTF16Units -= unitCount
        return true
      }
    )
  }
}
