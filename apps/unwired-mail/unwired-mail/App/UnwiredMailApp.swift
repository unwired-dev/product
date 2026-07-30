import SwiftUI

@main
struct UnwiredMailApp: App {
  @State private var session: ProductAccountSession
  @State private var settingsRouter = SettingsRouter()

  #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var appDelegate
  #endif

  init() {
    #if DEBUG
      DotEnvFile.loadDefaultsIfPresent()
    #endif
    _session = State(
      initialValue: ProductAccountSession(
        appleSignInService: SignInWithAppleService(),
        productAccountService: ConvexProductAccountService()
      )
    )
  }

  var body: some Scene {
    #if DEBUG && targetEnvironment(macCatalyst)
      WindowGroup {
        RootView(session: session)
          .environment(settingsRouter)
      }
      .commands {
        DevelopmentSettingsCommands(settingsRouter: settingsRouter)
      }

      WindowGroup("Settings", id: "development-settings") {
        DevelopmentSettingsRootView(session: session)
          .environment(settingsRouter)
      }
      .defaultSize(width: 920, height: 720)
    #else
      WindowGroup {
        RootView(session: session)
          .environment(settingsRouter)
      }
    #endif
  }
}

#if DEBUG && targetEnvironment(macCatalyst)
  private struct DevelopmentSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let settingsRouter: SettingsRouter

    var body: some Commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
          settingsRouter.open(nil)
          openWindow(id: "development-settings")
        }
        .keyboardShortcut(",", modifiers: .command)
      }
    }
  }
#endif
