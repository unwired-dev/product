import Foundation

/// Shared identifiers and filesystem locations used by the app and its Share Extension.
enum ShareExtensionConfiguration {
  static let appGroupIdentifier = "group.dev.unwired.mail"
  static let keychainAccessGroupInfoKey = "ShareExtensionKeychainAccessGroup"

  /// Returns the shared root used for encrypted Draft intake on supported Apple platforms.
  static func sharedRootDirectory(fileManager: FileManager = .default) -> URL? {
    #if os(iOS) && !targetEnvironment(macCatalyst)
      fileManager.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
      )?.appending(path: "UnwiredMail", directoryHint: .isDirectory)
    #else
      nil
    #endif
  }

  /// Returns the build-expanded keychain group shared only by the app and extension.
  static func keychainAccessGroup(bundle: Bundle = .main) -> String? {
    guard
      let value = bundle.object(forInfoDictionaryKey: keychainAccessGroupInfoKey) as? String,
      !value.isEmpty,
      !value.contains("$(")
    else { return nil }
    return value
  }
}
