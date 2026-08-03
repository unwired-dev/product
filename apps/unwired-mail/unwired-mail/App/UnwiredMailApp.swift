import SwiftUI

@main
struct UnwiredMailApp: App {
  @State private var appearancePreferences: AppearancePreferences
  @State private var attachmentNetworkMonitor: AttachmentDownloadNetworkMonitor
  @State private var messageContentPreferences: MessageContentPreferences
  @State private var session: ProductAccountSession
  @State private var settingsRouter = SettingsRouter()

  #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var appDelegate
  #endif

  init() {
    #if DEBUG
      DotEnvFile.loadDefaultsIfPresent()
    #endif
    _appearancePreferences = State(initialValue: AppearancePreferences())
    _attachmentNetworkMonitor = State(initialValue: AttachmentDownloadNetworkMonitor())
    let messageContentPreferences = MessageContentPreferences()
    _messageContentPreferences = State(initialValue: messageContentPreferences)
    _session = State(
      initialValue: ProductAccountSession(
        appleSignInService: SignInWithAppleService(),
        productAccountService: ConvexProductAccountService(),
        messageContentPreferences: messageContentPreferences
      )
    )
  }

  var body: some Scene {
    #if DEBUG && targetEnvironment(macCatalyst)
      WindowGroup {
        RootView(session: session)
          .environment(settingsRouter)
          .deviceAppearance(appearancePreferences)
          .environment(appearancePreferences)
          .environment(attachmentNetworkMonitor)
          .environment(messageContentPreferences)
      }
      .commands {
        DevelopmentSettingsCommands(settingsRouter: settingsRouter)
      }

      WindowGroup("Settings", id: "development-settings") {
        DevelopmentSettingsRootView(session: session)
          .environment(settingsRouter)
          .deviceAppearance(appearancePreferences)
          .environment(appearancePreferences)
          .environment(attachmentNetworkMonitor)
          .environment(messageContentPreferences)
      }
      .defaultSize(width: 920, height: 720)
    #else
      WindowGroup {
        RootView(session: session)
          .environment(settingsRouter)
          .deviceAppearance(appearancePreferences)
          .environment(appearancePreferences)
          .environment(attachmentNetworkMonitor)
          .environment(messageContentPreferences)
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
