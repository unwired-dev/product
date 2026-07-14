import SwiftUI

@main
struct UnwiredMailApp: App {
  #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var appDelegate
  #endif

  init() {
    #if DEBUG
      DotEnvFile.loadDefaultsIfPresent()
    #endif
  }

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}
