import SwiftUI

@main
struct UnwiredMailApp: App {
  @State private var appearancePreferences: AppearancePreferences
  @State private var attachmentNetworkMonitor: AttachmentDownloadNetworkMonitor
  @State private var messageContentPreferences: MessageContentPreferences
  @State private var session: ProductAccountSession
  @State private var settingsRouter = SettingsRouter()
  #if MAIL_TEST_BOOTSTRAP
    private let mailTestRuntime: MailTestBootstrapRuntime?
  #endif

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
    #if MAIL_TEST_BOOTSTRAP
      let mailTestRuntime: MailTestBootstrapRuntime?
      do {
        mailTestRuntime = try MailTestBootstrapConfiguration.load().map {
          try MailTestBootstrapRuntime(
            configuration: $0,
            messageContentPreferences: messageContentPreferences
          )
        }
      } catch {
        fatalError(error.localizedDescription)
      }
      self.mailTestRuntime = mailTestRuntime
      let session =
        mailTestRuntime?.session
        ?? ProductAccountSession(
          appleSignInService: SignInWithAppleService(),
          productAccountService: ConvexProductAccountService(),
          messageContentPreferences: messageContentPreferences
        )
    #else
      let session = ProductAccountSession(
        appleSignInService: SignInWithAppleService(),
        productAccountService: ConvexProductAccountService(),
        messageContentPreferences: messageContentPreferences
      )
    #endif
    _session = State(initialValue: session)
    #if canImport(UIKit)
      appDelegate.configure(productAccountSession: session)
    #endif
  }

  var body: some Scene {
    #if DEBUG && targetEnvironment(macCatalyst)
      WindowGroup {
        rootView
          .environment(settingsRouter)
          .deviceAppearance(appearancePreferences)
          .environment(appearancePreferences)
          .environment(attachmentNetworkMonitor)
          .environment(messageContentPreferences)
      }
      .commands {
        DevelopmentSettingsCommands(settingsRouter: settingsRouter)
      }
    #else
      WindowGroup {
        rootView
          .environment(settingsRouter)
          .deviceAppearance(appearancePreferences)
          .environment(appearancePreferences)
          .environment(attachmentNetworkMonitor)
          .environment(messageContentPreferences)
      }
    #endif
  }

  @ViewBuilder
  private var rootView: some View {
    #if MAIL_TEST_BOOTSTRAP
      if let mailTestRuntime {
        RootView(session: session) { snapshot in
          AccountView(
            session: session,
            snapshot: snapshot,
            composePreferenceSync: mailTestRuntime.composePreferenceSync,
            genericMailSetupService: mailTestRuntime.genericMailSetupService,
            mailboxConnection: mailTestRuntime.mailboxConnection
          )
        }
      } else {
        RootView(session: session)
      }
    #else
      RootView(session: session)
    #endif
  }
}

#if DEBUG && targetEnvironment(macCatalyst)
  private struct DevelopmentSettingsCommands: Commands {
    let settingsRouter: SettingsRouter

    var body: some Commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
          settingsRouter.open(nil)
        }
        .keyboardShortcut(",", modifiers: .command)
      }
    }
  }
#endif
