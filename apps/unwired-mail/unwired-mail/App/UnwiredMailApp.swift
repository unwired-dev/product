import SwiftUI

@main
struct UnwiredMailApp: App {
  @State private var appearancePreferences: AppearancePreferences
  @State private var attachmentNetworkMonitor: AttachmentDownloadNetworkMonitor
  @State private var messageContentPreferences: MessageContentPreferences
  @State private var session: ProductAccountSession
  @State private var settingsRouter = SettingsRouter()
  #if targetEnvironment(macCatalyst)
    @State private var showsSettings = false
  #endif
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
    #if targetEnvironment(macCatalyst)
      WindowGroup {
        MailProfileSceneRoot { profileDeepLinkRouter in
          rootView(profileDeepLinkRouter: profileDeepLinkRouter)
            .onChange(of: settingsRouter.request?.id) { _, requestId in
              if requestId != nil {
                showsSettings = true
              }
            }
            .sheet(isPresented: $showsSettings) {
              catalystSettings
            }
        }
        .environment(settingsRouter)
        .deviceAppearance(appearancePreferences)
        .environment(appearancePreferences)
        .environment(attachmentNetworkMonitor)
        .environment(messageContentPreferences)
      }
      .commands {
        CatalystSettingsCommands(settingsRouter: settingsRouter)
      }
    #else
      WindowGroup {
        MailProfileSceneRoot { profileDeepLinkRouter in
          rootView(profileDeepLinkRouter: profileDeepLinkRouter)
        }
        .environment(settingsRouter)
        .deviceAppearance(appearancePreferences)
        .environment(appearancePreferences)
        .environment(attachmentNetworkMonitor)
        .environment(messageContentPreferences)
      }
    #endif
  }

  @ViewBuilder
  private var catalystSettings: some View {
    SettingsRootView(session: session)
      .frame(minWidth: 640, idealWidth: 920, minHeight: 480, idealHeight: 720)
  }

  @ViewBuilder
  private func rootView(profileDeepLinkRouter: MailProfileDeepLinkRouter) -> some View {
    #if MAIL_TEST_BOOTSTRAP
      if let mailTestRuntime {
        RootView(session: session) { snapshot in
          AccountView(
            session: session,
            snapshot: snapshot,
            composePreferenceSync: mailTestRuntime.composePreferenceSync,
            genericMailSetupService: mailTestRuntime.genericMailSetupService,
            mailboxConnection: mailTestRuntime.mailboxConnection,
            snoozeSyncService: mailTestRuntime.snoozeSyncService,
            profileSnapshotLoader: mailTestRuntime.profileSnapshotLoader,
            profileDeepLinkRouter: profileDeepLinkRouter
          )
        }
      } else {
        RootView(session: session, profileDeepLinkRouter: profileDeepLinkRouter)
      }
    #else
      RootView(session: session, profileDeepLinkRouter: profileDeepLinkRouter)
    #endif
  }
}

private struct MailProfileSceneRoot<Content: View>: View {
  @State private var profileDeepLinkRouter = MailProfileDeepLinkRouter()
  let content: (MailProfileDeepLinkRouter) -> Content

  var body: some View {
    content(profileDeepLinkRouter)
      .tint(MailTheme.accent)
      .background(MailTheme.canvas)
      .onOpenURL { profileDeepLinkRouter.route($0) }
  }
}

#if targetEnvironment(macCatalyst)
  private struct CatalystSettingsCommands: Commands {
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
