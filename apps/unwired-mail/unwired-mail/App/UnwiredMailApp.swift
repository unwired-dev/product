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
    #if DEBUG && targetEnvironment(macCatalyst)
      WindowGroup {
        RootView()
      }
      .commands {
        DevelopmentSettingsCommands()
      }

      WindowGroup("Settings", id: "development-settings") {
        DevelopmentSettingsRootView()
      }
      .defaultSize(width: 920, height: 720)
    #else
      WindowGroup {
        RootView()
      }
    #endif
  }
}

#if DEBUG && targetEnvironment(macCatalyst)
  private struct DevelopmentSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
          openWindow(id: "development-settings")
        }
        .keyboardShortcut(",", modifiers: .command)
      }
    }
  }
#endif
