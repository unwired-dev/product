import SwiftUI

// swiftlint:disable file_length

enum SettingsEntryPoint: CaseIterable, Hashable, Identifiable {
  case accountSettings
  case adaptiveSettings

  var id: Self { self }
}

enum SettingsEntryPointRegistry {
  static var currentEntries: [SettingsEntryPoint] {
    #if DEBUG
      entries(isDevelopmentBuild: true)
    #else
      entries(isDevelopmentBuild: false)
    #endif
  }

  static func entries(isDevelopmentBuild: Bool) -> [SettingsEntryPoint] {
    isDevelopmentBuild ? SettingsEntryPoint.allCases : [.accountSettings]
  }
}

enum SettingsGroup: String, CaseIterable, Identifiable {
  case accounts

  var id: Self { self }

  var title: String {
    switch self {
    case .accounts:
      return "Accounts"
    }
  }
}

enum SettingsRoute: Hashable {
  case emailAccounts
}

enum SettingsDestination: String, CaseIterable, Identifiable {
  case emailAccounts

  var id: Self { self }

  var group: SettingsGroup {
    switch self {
    case .emailAccounts:
      return .accounts
    }
  }

  var title: String {
    switch self {
    case .emailAccounts:
      return "Email Accounts"
    }
  }

  var systemImage: String {
    switch self {
    case .emailAccounts:
      return "at"
    }
  }

  var route: SettingsRoute {
    switch self {
    case .emailAccounts:
      return .emailAccounts
    }
  }

  var searchTerms: [String] {
    switch self {
    case .emailAccounts:
      return [
        "Mailbox Connections",
        "Authorization",
        "Default Sending Connection",
        "Synchronize",
        "Mailbox Roles",
      ]
    }
  }

  var isAvailableWhenSignedOut: Bool {
    switch self {
    case .emailAccounts:
      return false
    }
  }
}

enum SettingsDestinationRegistry {
  static let implementedDestinations = SettingsDestination.allCases

  static var implementedGroups: [SettingsGroup] {
    implementedGroups(isSignedIn: true)
  }

  static func implementedGroups(isSignedIn: Bool) -> [SettingsGroup] {
    SettingsGroup.allCases.filter {
      !destinations(in: $0, isSignedIn: isSignedIn).isEmpty
    }
  }

  static func destinations(
    in group: SettingsGroup,
    isSignedIn: Bool = true
  ) -> [SettingsDestination] {
    implementedDestinations.filter {
      $0.group == group && (isSignedIn || $0.isAvailableWhenSignedOut)
    }
  }

  static func defaultDestination(isSignedIn: Bool) -> SettingsDestination? {
    guard isSignedIn else { return nil }
    return implementedDestinations.first
  }

  static func resolveDestination(
    storedRawValue: String,
    isSignedIn: Bool
  ) -> SettingsDestination? {
    guard isSignedIn else { return nil }
    if let stored = SettingsDestination(rawValue: storedRawValue),
      implementedDestinations.contains(stored)
    {
      return stored
    }
    return defaultDestination(isSignedIn: true)
  }
}

struct AdaptiveSettingsScene<DestinationContent: View>: View {
  let isSignedIn: Bool
  let showsDismissButton: Bool
  private let destinationContent: (SettingsDestination) -> DestinationContent

  @AppStorage("settings.lastDestination") private var storedDestination = ""
  @Environment(\.dismiss) private var dismiss
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var selection: SettingsDestination?

  init(
    isSignedIn: Bool,
    showsDismissButton: Bool,
    @ViewBuilder destinationContent: @escaping (SettingsDestination) -> DestinationContent
  ) {
    self.isSignedIn = isSignedIn
    self.showsDismissButton = showsDismissButton
    self.destinationContent = destinationContent
  }

  var body: some View {
    Group {
      if horizontalSizeClass == .compact {
        compactNavigation
      } else {
        splitNavigation
      }
    }
    .onAppear {
      selection = SettingsDestinationRegistry.resolveDestination(
        storedRawValue: storedDestination,
        isSignedIn: isSignedIn
      )
    }
    .onChange(of: selection) { _, destination in
      if let destination {
        storedDestination = destination.rawValue
      }
    }
  }

  private var compactNavigation: some View {
    NavigationStack(path: compactPath) {
      settingsList { destination in
        NavigationLink(value: destination) {
          destinationLabel(destination)
        }
      }
      .navigationTitle("Settings")
      .navigationDestination(for: SettingsDestination.self) { destination in
        detail(destination)
      }
      .toolbar { dismissToolbar }
    }
  }

  private var compactPath: Binding<[SettingsDestination]> {
    Binding(
      get: { selection.map { [$0] } ?? [] },
      set: { selection = $0.last }
    )
  }

  private var splitNavigation: some View {
    NavigationSplitView {
      List(selection: $selection) {
        ForEach(SettingsDestinationRegistry.implementedGroups(isSignedIn: isSignedIn)) { group in
          Section(group.title) {
            ForEach(
              SettingsDestinationRegistry.destinations(in: group, isSignedIn: isSignedIn)
            ) { destination in
              destinationLabel(destination)
                .tag(destination)
            }
          }
        }
      }
      .navigationTitle("Settings")
      .toolbar { dismissToolbar }
    } detail: {
      if let selection {
        detail(selection)
      } else {
        ContentUnavailableView(
          "Select a destination",
          systemImage: "gearshape",
          description: Text("Choose a Settings destination from the sidebar.")
        )
      }
    }
    .navigationSplitViewStyle(.balanced)
  }

  private func settingsList<Row: View>(
    @ViewBuilder row: @escaping (SettingsDestination) -> Row
  ) -> some View {
    List {
      ForEach(SettingsDestinationRegistry.implementedGroups(isSignedIn: isSignedIn)) { group in
        Section(group.title) {
          ForEach(
            SettingsDestinationRegistry.destinations(in: group, isSignedIn: isSignedIn)
          ) { destination in
            row(destination)
          }
        }
      }
    }
  }

  private func destinationLabel(_ destination: SettingsDestination) -> some View {
    Label(destination.title, systemImage: destination.systemImage)
  }

  private func detail(_ destination: SettingsDestination) -> some View {
    destinationContent(destination)
      .navigationTitle(destination.title)
  }

  @ToolbarContentBuilder
  private var dismissToolbar: some ToolbarContent {
    if showsDismissButton {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }
      }
    }
  }
}
#if DEBUG
  @MainActor
  struct DevelopmentSettingsRootView: View {
    let session: ProductAccountSession

    var body: some View {
      Group {
        switch session.state {
        case .loading:
          ProgressView("Loading Settings…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
          ContentUnavailableView(
            "Sign in required",
            systemImage: "person.crop.circle.badge.exclamationmark",
            description: Text("Email Accounts is available after Product Account sign-in.")
          )
        case .failed(let message):
          ContentUnavailableView(
            "Settings unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text(message)
          )
        case .signedIn(let snapshot):
          DevelopmentEmailAccountsSettingsHost(
            session: session,
            snapshot: snapshot
          )
        }
      }
    }
  }

  @MainActor
  private struct DevelopmentEmailAccountsSettingsHost: View {
    let session: ProductAccountSession
    let snapshot: ProductAccountSessionSnapshot

    @State private var ewsViewModel: EWSSetupViewModel
    @State private var freshnessViewModel: MailboxFreshnessViewModel
    @State private var genericMailViewModel: GenericMailSetupViewModel
    @State private var gmailViewModel: MailboxProviderConnectionViewModel
    @State private var microsoftGraphViewModel: MailboxProviderConnectionViewModel
    @State private var mailboxWorkCoordinator = MailboxWorkCoordinator.shared

    init(
      session: ProductAccountSession,
      snapshot: ProductAccountSessionSnapshot
    ) {
      self.session = session
      self.snapshot = snapshot
      let mailboxConnection = MailboxConnectionRouter()
      _ewsViewModel = State(
        initialValue: EWSSetupViewModel(
          isSessionCurrent: { session.isCurrent($0) },
          session: snapshot
        )
      )
      _freshnessViewModel = State(
        initialValue: session.sharedMailboxFreshnessViewModel(
          for: snapshot,
          service: mailboxConnection
        )
      )
      _genericMailViewModel = State(
        initialValue: GenericMailSetupViewModel(
          productAccountId: ProductAccountId(snapshot.productAccountId),
          clearLocalData: { definition, requestedSession in
            try await AccountView.clearGenericMailLocalData(
              definition,
              session: requestedSession,
              mailboxConnection: mailboxConnection
            )
          },
          isSessionCurrent: { session.isCurrent(snapshot) },
          syncSession: snapshot
        )
      )
      _gmailViewModel = State(
        initialValue: MailboxProviderConnectionViewModel(
          service: mailboxConnection,
          isSessionCurrent: { session.isCurrent($0) },
          session: snapshot
        )
      )
      _microsoftGraphViewModel = State(
        initialValue: MailboxProviderConnectionViewModel(
          service: MicrosoftGraphMailboxConnectionAdapter(),
          isSessionCurrent: { session.isCurrent($0) },
          session: snapshot
        )
      )
    }

    var body: some View {
      AdaptiveSettingsScene(
        isSignedIn: true,
        showsDismissButton: false
      ) { destination in
        switch destination {
        case .emailAccounts:
          EmailAccountsSettingsView(
            ewsViewModel: ewsViewModel,
            genericMailViewModel: genericMailViewModel,
            gmailViewModel: gmailViewModel,
            microsoftGraphViewModel: microsoftGraphViewModel,
            freshnessViewModel: freshnessViewModel,
            cancelBodyPrefetch: {
              await mailboxWorkCoordinator.cancelBodyPrefetch(
                productAccountId: snapshot.productAccountId
              )
            },
            connectionsDidChange: refreshGenericConnectionsAndNotify,
            isMailboxBusy: mailboxWorkCoordinator.isBusy(
              productAccountId: snapshot.productAccountId
            )
          )
        }
      }
      .onDisappear {
        ewsViewModel.invalidate()
        genericMailViewModel.invalidate()
      }
    }

    private func refreshGenericConnectionsAndNotify() {
      Task {
        await EmailAccountsSettingsView.refreshGenericConnections(
          loadGenericConnections: genericMailViewModel.loadSyncedDefinitions,
          connectionsDidChange: notifyConnectionsDidChange
        )
      }
    }

    private func notifyConnectionsDidChange() {
      NotificationCenter.default.post(
        name: .mailboxConnectionsDidChange,
        object: nil,
        userInfo: [
          MailboxSyncNotificationUserInfoKey.productAccountId: snapshot.productAccountId
        ]
      )
    }
  }
#endif
