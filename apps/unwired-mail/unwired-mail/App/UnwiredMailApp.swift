import SwiftUI

@main
struct UnwiredMailApp: App {
  @State private var session = ProductAccountSession(
    appleSignInService: SignInWithAppleService(),
    productAccountService: ConvexProductAccountService()
  )

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
        RootView(session: session)
      }
      .commands {
        DevelopmentSettingsCommands()
      }

      WindowGroup("Settings", id: "development-settings") {
        DevelopmentSettingsRootView(session: session)
      }
      .defaultSize(width: 920, height: 720)
    #else
      WindowGroup {
        RootView(session: session)
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
