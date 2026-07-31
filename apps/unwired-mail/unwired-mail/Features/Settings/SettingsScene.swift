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
  case application
  case automation
  case composing
  case mail

  var id: Self { self }

  var title: String {
    switch self {
    case .accounts:
      return "Accounts"
    case .application:
      return "Application"
    case .automation:
      return "Automation"
    case .composing:
      return "Composing"
    case .mail:
      return "Mail"
    }
  }
}

enum AppearanceSettingsControl: String, Hashable {
  case increasedContrast
  case messageBody
  case readingTextSize
  case theme
}

enum SettingsRouteContext: Hashable {
  case appearance(AppearanceSettingsControl)
  case authorization(String?)
  case defaultSendingConnection
  case mailboxConnection(String)
  case mailboxConnections
  case mailboxRoles(String?)
  case missingSignature(String?)
  case notificationPermission
  case preferenceConflict(String)
  case provider(String)
  case readReceipt(String?)
  case storage
  case synchronization(String?)
}

enum SettingsDestination: String, CaseIterable, Identifiable {
  case about
  case accountAndDevices
  case advanced
  case appearance
  case categories
  case compose
  case emailAccounts
  case inbox
  case notifications
  case privacyAndData
  case reading
  case signatures
  case swipes
  case templates

  var id: Self { self }

  var group: SettingsGroup {
    switch self {
    case .accountAndDevices, .emailAccounts:
      return .accounts
    case .appearance, .privacyAndData, .advanced, .about:
      return .application
    case .categories, .notifications:
      return .automation
    case .compose, .signatures, .templates:
      return .composing
    case .inbox, .reading, .swipes:
      return .mail
    }
  }

  var title: String {
    switch self {
    case .about:
      return "About"
    case .accountAndDevices:
      return "Account & Devices"
    case .advanced:
      return "Advanced"
    case .appearance:
      return "Appearance"
    case .categories:
      return "Categories"
    case .compose:
      return "Compose"
    case .emailAccounts:
      return "Email Accounts"
    case .inbox:
      return "Inbox"
    case .notifications:
      return "Notifications"
    case .privacyAndData:
      return "Privacy & Data"
    case .reading:
      return "Reading"
    case .signatures:
      return "Signatures"
    case .swipes:
      return "Swipes"
    case .templates:
      return "Templates"
    }
  }

  var systemImage: String {
    switch self {
    case .about:
      return "info.circle"
    case .accountAndDevices:
      return "person.2"
    case .advanced:
      return "wrench.and.screwdriver"
    case .appearance:
      return "paintbrush"
    case .categories:
      return "tag"
    case .compose:
      return "square.and.pencil"
    case .emailAccounts:
      return "at"
    case .inbox:
      return "tray"
    case .notifications:
      return "bell"
    case .privacyAndData:
      return "hand.raised"
    case .reading:
      return "text.book.closed"
    case .signatures:
      return "signature"
    case .swipes:
      return "hand.draw"
    case .templates:
      return "doc.on.doc"
    }
  }

  var route: SettingsRoute {
    SettingsRoute(destination: self)
  }

  var searchRoute: SettingsRoute {
    switch self {
    case .emailAccounts:
      return .mailboxConnections
    default:
      return route
    }
  }

  var searchItems: [SettingsSearchItem] {
    switch self {
    case .accountAndDevices:
      return [
        SettingsSearchItem(
          title: "Product Account",
          keywords: ["Sign in with Apple"],
          route: route
        ),
        SettingsSearchItem(title: "Trusted Devices", keywords: ["Rename device"], route: route),
        SettingsSearchItem(title: "Recovery Key", keywords: ["Encryption"], route: route),
        SettingsSearchItem(title: "Sign Out", route: route),
      ]
    case .emailAccounts:
      return [
        SettingsSearchItem(title: "Mailbox Connections", route: .mailboxConnections),
        SettingsSearchItem(
          title: "Authorization",
          keywords: ["Authorize", "Reauthorize", "Remove Device Authorization"],
          route: .authorization(connectionId: nil)
        ),
        SettingsSearchItem(
          title: "Default Sending Connection",
          keywords: ["Default sender"],
          route: .defaultSendingConnection
        ),
        SettingsSearchItem(
          title: "Synchronize",
          keywords: ["Sync health", "Historical Metadata Backfill"],
          route: .synchronization(connectionId: nil)
        ),
        SettingsSearchItem(title: "Mailbox Roles", route: .mailboxRoles(connectionId: nil)),
        SettingsSearchItem(title: "Gmail", route: .provider(.gmail)),
        SettingsSearchItem(title: "Microsoft 365", route: .provider(.microsoftGraph)),
        SettingsSearchItem(
          title: "On-Premises Exchange",
          keywords: ["EWS"],
          route: .provider(.exchangeWebServices)
        ),
        SettingsSearchItem(
          title: "Other Mail Server",
          keywords: ["IMAP", "SMTP", "POP3"],
          route: .provider(.imapSMTP)
        ),
      ]
    case .appearance:
      return [
        SettingsSearchItem(title: "Theme", route: .appearance(.theme)),
        SettingsSearchItem(title: "Reading Text Size", route: .appearance(.readingTextSize)),
        SettingsSearchItem(
          title: "Message Body",
          keywords: ["Sender Formatting", "System Serif", "System Sans Serif"],
          route: .appearance(.messageBody)
        ),
        SettingsSearchItem(title: "Increased Contrast", route: .appearance(.increasedContrast)),
      ]
    default:
      return []
    }
  }

  var isAvailableWhenSignedOut: Bool {
    switch self {
    case .about, .advanced, .appearance, .privacyAndData:
      return true
    case .accountAndDevices, .categories, .compose, .emailAccounts, .inbox, .notifications,
      .reading, .signatures, .swipes, .templates:
      return false
    }
  }
}

struct SettingsRoute: Hashable {
  let destination: SettingsDestination
  let context: SettingsRouteContext?

  init(
    destination: SettingsDestination,
    context: SettingsRouteContext? = nil
  ) {
    self.destination = destination
    self.context = context
  }

  static let defaultSendingConnection = SettingsRoute(
    destination: .emailAccounts,
    context: .defaultSendingConnection
  )
  static let emailAccounts = SettingsRoute(destination: .emailAccounts)
  static let mailboxConnections = SettingsRoute(
    destination: .emailAccounts,
    context: .mailboxConnections
  )
  static let notificationPermission = SettingsRoute(
    destination: .notifications,
    context: .notificationPermission
  )
  static let storage = SettingsRoute(
    destination: .privacyAndData,
    context: .storage
  )

  static func appearance(_ control: AppearanceSettingsControl) -> SettingsRoute {
    SettingsRoute(
      destination: .appearance,
      context: .appearance(control)
    )
  }

  static func authorization(connectionId: MailboxConnectionId?) -> SettingsRoute {
    SettingsRoute(
      destination: .emailAccounts,
      context: .authorization(connectionId?.rawValue)
    )
  }

  static func mailboxConnection(_ connectionId: MailboxConnectionId) -> SettingsRoute {
    SettingsRoute(
      destination: .emailAccounts,
      context: .mailboxConnection(connectionId.rawValue)
    )
  }

  static func mailboxRoles(connectionId: MailboxConnectionId?) -> SettingsRoute {
    SettingsRoute(
      destination: .emailAccounts,
      context: .mailboxRoles(connectionId?.rawValue)
    )
  }

  static func missingSignature(connectionId: MailboxConnectionId?) -> SettingsRoute {
    SettingsRoute(
      destination: .signatures,
      context: .missingSignature(connectionId?.rawValue)
    )
  }

  static func preferenceConflict(
    destination: SettingsDestination,
    field: String
  ) -> SettingsRoute {
    SettingsRoute(
      destination: destination,
      context: .preferenceConflict(field)
    )
  }

  static func provider(_ providerId: MailProviderId) -> SettingsRoute {
    SettingsRoute(
      destination: .emailAccounts,
      context: .provider(providerId.rawValue)
    )
  }

  static func readReceipt(connectionId: MailboxConnectionId?) -> SettingsRoute {
    SettingsRoute(
      destination: .reading,
      context: .readReceipt(connectionId?.rawValue)
    )
  }

  static func synchronization(connectionId: MailboxConnectionId?) -> SettingsRoute {
    SettingsRoute(
      destination: .emailAccounts,
      context: .synchronization(connectionId?.rawValue)
    )
  }
}

struct SettingsSearchItem: Equatable {
  let title: String
  let keywords: [String]
  let route: SettingsRoute

  init(
    title: String,
    keywords: [String] = [],
    route: SettingsRoute
  ) {
    self.title = title
    self.keywords = keywords
    self.route = route
  }
}

struct SettingsSearchResult: Equatable, Identifiable {
  struct Identity: Hashable {
    let route: SettingsRoute
    let subtitle: String
    let title: String
  }

  let title: String
  let subtitle: String
  let route: SettingsRoute

  var id: Identity {
    Identity(route: route, subtitle: subtitle, title: title)
  }
}

struct SettingsAttention: Equatable, Identifiable {
  enum Kind: String {
    case authorization
    case conflict
    case permission
    case recovery
    case sync
  }

  let destination: SettingsDestination
  let kind: Kind
  let message: String

  var id: SettingsDestination { destination }

  static func emailAccounts(
    authorizationRequired: Bool,
    syncFailureMessage: String?
  ) -> SettingsAttention? {
    if authorizationRequired {
      return SettingsAttention(
        destination: .emailAccounts,
        kind: .authorization,
        message: "One or more Mailbox Connections require authorization on this device."
      )
    }
    if let syncFailureMessage {
      return SettingsAttention(
        destination: .emailAccounts,
        kind: .sync,
        message: "Mailbox synchronization failed: \(syncFailureMessage)"
      )
    }
    return nil
  }
}

enum SettingsNavigationDecision: Equatable {
  case confirmDiscard(SettingsRoute)
  case navigate(SettingsRoute)
  case unavailable
}

enum SettingsNavigationPolicy {
  static func canDiscardChanges(isSetupWorking: Bool) -> Bool {
    !isSetupWorking
  }

  static func decision(
    currentRoute: SettingsRoute?,
    requestedRoute: SettingsRoute,
    hasUnsavedChanges: Bool,
    isSignedIn: Bool
  ) -> SettingsNavigationDecision {
    guard
      let route = SettingsDestinationRegistry.resolveRoute(
        requestedRoute,
        isSignedIn: isSignedIn
      )
    else {
      return .unavailable
    }
    guard hasUnsavedChanges, currentRoute != route else {
      return .navigate(route)
    }
    return .confirmDiscard(route)
  }
}

enum SettingsNavigationLayout: Equatable {
  case compact
  case split

  static func resolve(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Self {
    horizontalSizeClass == .compact ? .compact : .split
  }
}

struct SettingsRouteRequest: Equatable {
  let id: UUID
  let route: SettingsRoute?

  init(
    id: UUID = UUID(),
    route: SettingsRoute?
  ) {
    self.id = id
    self.route = route
  }
}

@MainActor
@Observable
final class SettingsRouter {
  private(set) var request: SettingsRouteRequest?

  func open(_ route: SettingsRoute?) {
    request = SettingsRouteRequest(route: route)
  }
}

extension View {
  func confirmDiscardSelection<Selection>(
    _ selection: Binding<Selection?>,
    discardAndSelect: @escaping (Selection) -> Void
  ) -> some View {
    confirmationDialog(
      "Discard unsaved changes?",
      isPresented: Binding(
        get: { selection.wrappedValue != nil },
        set: { isPresented in
          if !isPresented {
            selection.wrappedValue = nil
          }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("Discard Changes", role: .destructive) {
        guard let value = selection.wrappedValue else { return }
        selection.wrappedValue = nil
        discardAndSelect(value)
      }
      Button("Keep Editing", role: .cancel) {
        selection.wrappedValue = nil
      }
    }
  }
}

enum SettingsDestinationRegistry {
  static let implementedDestinations: [SettingsDestination] = [
    .emailAccounts,
    .accountAndDevices,
    .appearance,
  ]

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
    isSignedIn ? .emailAccounts : .appearance
  }

  static func resolveRoute(
    _ route: SettingsRoute,
    isSignedIn: Bool
  ) -> SettingsRoute? {
    guard
      implementedDestinations.contains(route.destination),
      isSignedIn || route.destination.isAvailableWhenSignedOut
    else {
      return nil
    }
    return route
  }

  static func resolveDestination(
    storedRawValue: String,
    isSignedIn: Bool
  ) -> SettingsDestination? {
    if let stored = SettingsDestination(rawValue: storedRawValue),
      implementedDestinations.contains(stored),
      isSignedIn || stored.isAvailableWhenSignedOut
    {
      return stored
    }
    return defaultDestination(isSignedIn: isSignedIn)
  }

  static func search(
    matching query: String,
    isSignedIn: Bool
  ) -> [SettingsSearchResult] {
    let query = normalizedSearchText(query)
    guard !query.isEmpty else { return [] }

    return implementedDestinations.flatMap { destination -> [SettingsSearchResult] in
      guard isSignedIn || destination.isAvailableWhenSignedOut else { return [] }
      var results: [SettingsSearchResult] = []
      if normalizedSearchText(
        [destination.title, destination.group.title].joined(separator: " ")
      ).contains(query) {
        results.append(
          SettingsSearchResult(
            title: destination.title,
            subtitle: destination.group.title,
            route: destination.searchRoute
          )
        )
      }
      results += destination.searchItems.compactMap { item in
        let searchableText = normalizedSearchText(
          [item.title] + item.keywords
        )
        guard searchableText.contains(query) else { return nil }
        return SettingsSearchResult(
          title: item.title,
          subtitle: destination.title,
          route: item.route
        )
      }
      return results
    }
  }

  private static func normalizedSearchText(_ values: [String]) -> String {
    normalizedSearchText(values.joined(separator: " "))
  }

  private static func normalizedSearchText(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}

struct AdaptiveSettingsScene<DestinationContent: View>: View {
  let isSignedIn: Bool
  let showsDismissButton: Bool
  let attentions: [SettingsAttention]
  private let canDiscardChanges: () -> Bool
  private let discardChanges: () -> Void
  private let hasUnsavedChanges: () -> Bool
  private let destinationContent: (SettingsDestination, SettingsRouteRequest?) -> DestinationContent

  @AppStorage("settings.lastDestination") private var storedDestination = ""
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dismissSearch) private var dismissSearch
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(SettingsRouter.self) private var router
  @State private var activeRequest: SettingsRouteRequest?
  @State private var pendingAction: PendingAction?
  @State private var searchQuery = ""
  @State private var selection: SettingsDestination?

  private enum PendingAction {
    case dismiss
    case navigate(SettingsRouteRequest)
    case showList
  }

  init(
    isSignedIn: Bool,
    showsDismissButton: Bool,
    attentions: [SettingsAttention] = [],
    hasUnsavedChanges: @escaping () -> Bool = { false },
    canDiscardChanges: @escaping () -> Bool = { true },
    discardChanges: @escaping () -> Void = {},
    @ViewBuilder destinationContent:
      @escaping (SettingsDestination, SettingsRouteRequest?) -> DestinationContent
  ) {
    self.isSignedIn = isSignedIn
    self.showsDismissButton = showsDismissButton
    self.attentions = attentions
    self.hasUnsavedChanges = hasUnsavedChanges
    self.canDiscardChanges = canDiscardChanges
    self.discardChanges = discardChanges
    self.destinationContent = destinationContent
  }

  var body: some View {
    Group {
      if SettingsNavigationLayout.resolve(horizontalSizeClass) == .compact {
        compactNavigation
      } else {
        splitNavigation
      }
    }
    .onAppear {
      handleRouterRequest()
    }
    .onChange(of: router.request?.id) { _, _ in
      handleRouterRequest()
    }
    .confirmationDialog(
      "Discard unsaved changes?",
      isPresented: Binding(
        get: { pendingAction != nil },
        set: { isPresented in
          if !isPresented {
            pendingAction = nil
          }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("Discard Changes", role: .destructive) {
        guard let action = pendingAction else { return }
        pendingAction = nil
        discardChanges()
        perform(action)
      }
      .disabled(!canDiscardChanges())
      Button("Keep Editing", role: .cancel) {
        pendingAction = nil
      }
    }
    .interactiveDismissDisabled(hasUnsavedChanges())
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
      set: { path in
        if let destination = path.last {
          requestNavigation(destination.route)
        } else {
          requestShowList()
        }
      }
    )
  }

  private var splitNavigation: some View {
    NavigationSplitView {
      settingsList { destination in
        Button {
          requestNavigation(destination.route)
        } label: {
          destinationLabel(destination)
        }
        .buttonStyle(.plain)
        .listRowBackground(
          selection == destination ? Color.accentColor.opacity(0.14) : Color.clear
        )
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
      if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        ForEach(SettingsDestinationRegistry.implementedGroups(isSignedIn: isSignedIn)) { group in
          Section(group.title) {
            ForEach(
              SettingsDestinationRegistry.destinations(in: group, isSignedIn: isSignedIn)
            ) { destination in
              row(destination)
            }
          }
        }
      } else {
        Section("Search Results") {
          if searchResults.isEmpty {
            Text("No Settings controls found")
              .foregroundStyle(.secondary)
          } else {
            ForEach(searchResults) { result in
              Button {
                requestNavigation(result.route)
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                    Text(result.subtitle)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
    .searchable(text: $searchQuery, prompt: "Search Settings")
  }

  private func destinationLabel(_ destination: SettingsDestination) -> some View {
    HStack {
      Label(destination.title, systemImage: destination.systemImage)
      Spacer()
      if attention(for: destination) != nil {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(.orange)
          .accessibilityLabel("Action required")
      }
    }
    .contentShape(Rectangle())
  }

  private func detail(_ destination: SettingsDestination) -> some View {
    VStack(spacing: 0) {
      if let attention = attention(for: destination) {
        Label(attention.message, systemImage: "exclamationmark.circle.fill")
          .font(.callout)
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
          .background(.orange.opacity(0.1))
      }
      destinationContent(
        destination,
        activeRequest?.route?.destination == destination ? activeRequest : nil
      )
    }
    .navigationTitle(destination.title)
  }

  @ToolbarContentBuilder
  private var dismissToolbar: some ToolbarContent {
    if showsDismissButton {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done", action: requestDismiss)
      }
    }
  }
}

extension AdaptiveSettingsScene {
  private var searchResults: [SettingsSearchResult] {
    SettingsDestinationRegistry.search(
      matching: searchQuery,
      isSignedIn: isSignedIn
    )
  }

  private func attention(for destination: SettingsDestination) -> SettingsAttention? {
    attentions.first { $0.destination == destination }
  }

  private func handleRouterRequest() {
    guard let request = router.request, request.route != nil else {
      guard selection == nil else { return }
      restoreSelection()
      return
    }
    requestNavigation(request)
  }

  private func restoreSelection() {
    guard
      let destination = SettingsDestinationRegistry.resolveDestination(
        storedRawValue: storedDestination,
        isSignedIn: isSignedIn
      )
    else {
      selection = nil
      activeRequest = nil
      return
    }
    apply(SettingsRouteRequest(route: destination.route))
  }

  private func requestNavigation(_ route: SettingsRoute) {
    requestNavigation(SettingsRouteRequest(route: route))
  }

  private func requestNavigation(_ request: SettingsRouteRequest) {
    guard let requestedRoute = request.route else { return }
    switch SettingsNavigationPolicy.decision(
      currentRoute: activeRequest?.route,
      requestedRoute: requestedRoute,
      hasUnsavedChanges: hasUnsavedChanges(),
      isSignedIn: isSignedIn
    ) {
    case .confirmDiscard(let route):
      pendingAction = .navigate(SettingsRouteRequest(id: request.id, route: route))
    case .navigate(let route):
      apply(SettingsRouteRequest(id: request.id, route: route))
    case .unavailable:
      break
    }
  }

  private func requestShowList() {
    guard selection != nil else { return }
    if hasUnsavedChanges() {
      pendingAction = .showList
    } else {
      perform(.showList)
    }
  }

  private func requestDismiss() {
    if hasUnsavedChanges() {
      pendingAction = .dismiss
    } else {
      dismiss()
    }
  }

  private func perform(_ action: PendingAction) {
    switch action {
    case .dismiss:
      dismiss()
    case .navigate(let route):
      apply(route)
    case .showList:
      selection = nil
      activeRequest = nil
    }
  }

  private func apply(_ request: SettingsRouteRequest) {
    guard let route = request.route else { return }
    selection = route.destination
    activeRequest = request
    storedDestination = route.destination.rawValue
    searchQuery = ""
    dismissSearch()
  }
}

@MainActor
@Observable
final class AccountAndDevicesViewModel {
  private(set) var devices: [TrustedDeviceSummary] = []
  private(set) var errorMessage: String?
  private(set) var isLoading = false
  private(set) var isWorking = false
  private(set) var recoveryKeyStatus = RecoveryKeyStatus.unavailable
  private(set) var revealedRecoveryKey: String?

  private let service: AccountAndDevicesService

  init(service: AccountAndDevicesService = AccountAndDevicesService()) {
    self.service = service
  }

  func load(
    session: ProductAccountSessionSnapshot,
    recentIdentityToken: () async throws -> String
  ) async {
    isLoading = true
    defer { isLoading = false }
    do {
      let identityToken =
        if session.identityTokenState() == .active {
          session.identityToken
        } else {
          try await recentIdentityToken()
        }
      let snapshot = try await service.load(
        session: session,
        identityToken: identityToken
      )
      devices = snapshot.devices
      recoveryKeyStatus = snapshot.recoveryKeyStatus
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func rename(
    _ device: TrustedDeviceSummary,
    displayName: String,
    session: ProductAccountSessionSnapshot,
    recentIdentityToken: () async throws -> String
  ) async {
    isWorking = true
    defer { isWorking = false }
    do {
      let identityToken = try await recentIdentityToken()
      let renamed = try await service.renameDevice(
        device,
        displayName: displayName,
        session: session,
        identityToken: identityToken
      )
      if let index = devices.firstIndex(where: { $0.id == renamed.id }) {
        devices[index] = renamed
      }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func presentRecoveryKey(
    session: ProductAccountSessionSnapshot,
    recentIdentityToken: () async throws -> String,
    isSessionCurrent: () -> Bool,
    recoveryKeyPublished: (String) throws -> Void = { _ in },
    recoveryKeyRejected: (String) -> Void = { _ in },
    replacingCurrent: Bool = false
  ) async {
    isWorking = true
    defer { isWorking = false }
    do {
      let identityToken = try await recentIdentityToken()
      var publicationError: Error?
      let retainPublishedRecoveryKey = { (recoveryKey: String) in
        do {
          try recoveryKeyPublished(recoveryKey)
        } catch {
          publicationError = error
        }
      }
      let recoveryKey =
        if recoveryKeyStatus == .current, !replacingCurrent {
          try await service.revealCurrentRecoveryKey(
            session: session,
            recentIdentityToken: identityToken,
            recoveryKeyPublished: retainPublishedRecoveryKey
          )
        } else {
          try await service.replaceRecoveryKey(
            session: session,
            recentIdentityToken: identityToken,
            isSessionCurrent: isSessionCurrent,
            recoveryKeyPublished: recoveryKeyPublished,
            recoveryKeyRejected: recoveryKeyRejected
          )
        }
      recoveryKeyStatus = .current
      revealedRecoveryKey = recoveryKey.rawValue
      if let publicationError { throw publicationError }
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func clearError() {
    errorMessage = nil
  }

  func hideRecoveryKey() {
    revealedRecoveryKey = nil
  }

  func acknowledgeRecoveryKey(using acknowledgement: () throws -> Void) {
    do {
      try acknowledgement()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func presentPreservedRecoveryKey(_ recoveryKey: String?) {
    revealedRecoveryKey = recoveryKeyStatus == .current ? recoveryKey : nil
  }
}

enum AccountAndDevicesAccessibility {
  static let currentDevice = "Current Trusted Device"

  static func renameDevice(_ displayName: String) -> String {
    "Rename \(displayName)"
  }
}

@MainActor
struct AccountAndDevicesSettingsView: View {
  let session: ProductAccountSession
  let snapshot: ProductAccountSessionSnapshot
  let signOut: @MainActor () -> Void

  @State private var confirmsRecoveryReplacement = false
  @State private var confirmsCurrentRecoveryReplacement = false
  @State private var confirmsSignOut = false
  @State private var deviceToRename: TrustedDeviceSummary?
  @State private var renameDraft = ""
  @State private var viewModel: AccountAndDevicesViewModel

  init(
    session: ProductAccountSession,
    snapshot: ProductAccountSessionSnapshot,
    signOut: @escaping @MainActor () -> Void,
    service: AccountAndDevicesService = AccountAndDevicesService()
  ) {
    self.session = session
    self.snapshot = snapshot
    self.signOut = signOut
    _viewModel = State(
      initialValue: AccountAndDevicesViewModel(service: service)
    )
  }

  var body: some View {
    Form {
      Section("Product Account") {
        Label("Signed in with Apple", systemImage: "person.crop.circle.badge.checkmark")
        LabeledContent("Product Account") {
          Text(snapshot.productAccountId)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        Text("Mailbox Connections are managed separately in Email Accounts.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Trusted Devices") {
        if viewModel.isLoading, viewModel.devices.isEmpty {
          ProgressView("Loading Trusted Devices…")
        } else {
          ForEach(viewModel.devices) { device in
            trustedDeviceRow(device)
          }
        }
      }

      Section("Recovery Key") {
        Label(recoveryStatusTitle, systemImage: recoveryStatusImage)
        Text(recoveryStatusDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
        Button(recoveryActionTitle) {
          confirmsRecoveryReplacement = true
        }
        .disabled(
          viewModel.isWorking || viewModel.recoveryKeyStatus == .unavailable
        )
        if viewModel.recoveryKeyStatus == .current {
          Button("Replace Recovery Key", role: .destructive) {
            confirmsCurrentRecoveryReplacement = true
          }
          .disabled(viewModel.isWorking)
        }
      }

      Section {
        if let signOutErrorMessage = session.signOutErrorMessage {
          SignOutErrorBanner(message: signOutErrorMessage)
        }
        Button("Sign Out on This Device", role: .destructive) {
          confirmsSignOut = true
        }
        .disabled(viewModel.isWorking)
      } footer: {
        Text(
          "Signing out unregisters this device's push routing and clears its local "
            + "mailbox credentials and cached mail. It does not remove provider mail."
        )
      }
    }
    .navigationTitle("Account & Devices")
    .task(id: snapshot.trustedDeviceId) {
      await viewModel.load(
        session: snapshot,
        recentIdentityToken: {
          try await session.recentIdentityToken(for: snapshot)
        }
      )
      viewModel.presentPreservedRecoveryKey(session.unacknowledgedRecoveryKey)
    }
    .onDisappear {
      viewModel.hideRecoveryKey()
    }
    .refreshable {
      await viewModel.load(
        session: snapshot,
        recentIdentityToken: {
          try await session.recentIdentityToken(for: snapshot)
        }
      )
    }
    .alert(
      "Account & Devices unavailable",
      isPresented: Binding(
        get: { viewModel.errorMessage != nil },
        set: { isPresented in
          if !isPresented { viewModel.clearError() }
        }
      )
    ) {
      Button("OK") { viewModel.clearError() }
    } message: {
      Text(viewModel.errorMessage ?? "")
    }
    .alert(
      "Rename Trusted Device",
      isPresented: Binding(
        get: { deviceToRename != nil },
        set: { isPresented in
          if !isPresented { deviceToRename = nil }
        }
      )
    ) {
      TextField("Device name", text: $renameDraft)
      Button("Save") {
        guard let device = deviceToRename else { return }
        deviceToRename = nil
        Task {
          await viewModel.rename(
            device,
            displayName: renameDraft,
            session: snapshot,
            recentIdentityToken: {
              try await session.recentIdentityToken(for: snapshot)
            }
          )
        }
      }
      Button("Cancel", role: .cancel) {
        deviceToRename = nil
      }
    } message: {
      Text("Use a name that helps you recognize this Trusted Device.")
    }
    .confirmationDialog(
      recoveryActionTitle,
      isPresented: $confirmsRecoveryReplacement,
      titleVisibility: .visible
    ) {
      Button(recoveryActionTitle) {
        Task {
          await viewModel.presentRecoveryKey(
            session: snapshot,
            recentIdentityToken: {
              try await session.recentIdentityToken(for: snapshot)
            },
            isSessionCurrent: { session.isCurrent(snapshot) },
            recoveryKeyPublished: session.preserveUnacknowledgedRecoveryKey,
            recoveryKeyRejected: { recoveryKey in
              try? session.acknowledgeRecoveryKey(
                recoveryKey,
                productAccountId: snapshot.productAccountId
              )
            }
          )
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(recoveryConfirmationMessage)
    }
    .confirmationDialog(
      "Sign out on this device?",
      isPresented: $confirmsSignOut,
      titleVisibility: .visible
    ) {
      Button("Sign Out", role: .destructive) {
        signOut()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Your Product Account and provider mail remain available on other devices.")
    }
    .confirmationDialog(
      "Replace Recovery Key?",
      isPresented: $confirmsCurrentRecoveryReplacement,
      titleVisibility: .visible
    ) {
      Button("Replace Recovery Key", role: .destructive) {
        Task {
          await viewModel.presentRecoveryKey(
            session: snapshot,
            recentIdentityToken: {
              try await session.recentIdentityToken(for: snapshot)
            },
            isSessionCurrent: { session.isCurrent(snapshot) },
            recoveryKeyPublished: session.preserveUnacknowledgedRecoveryKey,
            recoveryKeyRejected: { recoveryKey in
              try? session.acknowledgeRecoveryKey(
                recoveryKey,
                productAccountId: snapshot.productAccountId
              )
            },
            replacingCurrent: true
          )
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Sign in with Apple will confirm your identity. The current Recovery Key "
          + "will stop working after the replacement is saved."
      )
    }
    .sheet(
      isPresented: Binding(
        get: { viewModel.revealedRecoveryKey != nil },
        set: { isPresented in
          if !isPresented {
            let recoveryKey = viewModel.revealedRecoveryKey
            viewModel.hideRecoveryKey()
            if let recoveryKey {
              viewModel.acknowledgeRecoveryKey {
                try session.acknowledgeRecoveryKey(
                  recoveryKey,
                  productAccountId: snapshot.productAccountId
                )
              }
            }
          }
        }
      )
    ) {
      RecoveryKeyPresentation(
        recoveryKey: viewModel.revealedRecoveryKey ?? ""
      )
    }
  }
}

extension AccountAndDevicesSettingsView {
  @ViewBuilder
  fileprivate func trustedDeviceRow(_ device: TrustedDeviceSummary) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: device.platform == "macos" ? "desktopcomputer" : "iphone")
        .font(.title3)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(device.displayName)
            .font(.headline)
          if device.id == snapshot.trustedDeviceId {
            Text("Current Device")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
              .accessibilityLabel(AccountAndDevicesAccessibility.currentDevice)
          }
        }
        Text(
          "Last connected "
            + Date(timeIntervalSince1970: Double(device.lastSeenAt) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Rename") {
        renameDraft = device.displayName
        deviceToRename = device
      }
      .disabled(viewModel.isWorking)
      .accessibilityLabel(
        AccountAndDevicesAccessibility.renameDevice(device.displayName)
      )
    }
  }

  fileprivate var recoveryActionTitle: String {
    switch viewModel.recoveryKeyStatus {
    case .current:
      return "View Recovery Key"
    case .notBackedUp:
      return "Generate Recovery Key"
    case .replacedOnAnotherDevice, .unavailable:
      return "Replace Recovery Key"
    }
  }

  fileprivate var recoveryStatusTitle: String {
    switch viewModel.recoveryKeyStatus {
    case .current:
      return "Recovery Key available"
    case .notBackedUp:
      return "Recovery Key setup required"
    case .replacedOnAnotherDevice:
      return "Recovery Key replaced elsewhere"
    case .unavailable:
      return "Recovery Key unavailable"
    }
  }

  fileprivate var recoveryConfirmationMessage: String {
    if viewModel.recoveryKeyStatus == .current {
      return
        "Sign in with Apple will confirm your identity before the Recovery Key is shown."
    }
    return
      "Sign in with Apple will confirm your identity. Replacing the Recovery Key "
      + "invalidates the previous key, but never sends the new key or decrypted "
      + "Product Sync data to the backend."
  }

  fileprivate var recoveryStatusImage: String {
    switch viewModel.recoveryKeyStatus {
    case .current:
      return "checkmark.shield"
    case .notBackedUp, .replacedOnAnotherDevice:
      return "exclamationmark.shield"
    case .unavailable:
      return "xmark.shield"
    }
  }

  fileprivate var recoveryStatusDescription: String {
    switch viewModel.recoveryKeyStatus {
    case .current:
      return
        "The backend stores only an encrypted account-key wrapper. Keep the user-held "
        + "Recovery Key somewhere safe."
    case .notBackedUp:
      return
        "Generate a user-held Recovery Key so Product Sync can be recovered without "
        + "making plaintext available to the backend."
    case .replacedOnAnotherDevice:
      return
        "This device holds an older Recovery Key. Replace it here to make a new key current."
    case .unavailable:
      return "Restore Product Sync key material before managing recovery."
    }
  }
}

private struct RecoveryKeyPresentation: View {
  let recoveryKey: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("New Recovery Key") {
          Text(recoveryKey)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .accessibilityLabel("New Recovery Key")
            .accessibilityValue(recoveryKey)
        }
        Section {
          Text(
            "Save this key somewhere secure. The product backend and support cannot "
              + "recover it for you."
          )
        }
      }
      .navigationTitle("Recovery Key")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
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
          AdaptiveSettingsScene(
            isSignedIn: false,
            showsDismissButton: false,
            destinationContent: { destination, request in
              if destination == .appearance {
                AppearanceSettingsView(navigationRequest: request)
              }
            }
          )
        case .failed(let message):
          AdaptiveSettingsScene(
            isSignedIn: false,
            showsDismissButton: false,
            attentions: [
              SettingsAttention(
                destination: .appearance,
                kind: .recovery,
                message: message
              )
            ],
            destinationContent: { destination, request in
              if destination == .appearance {
                AppearanceSettingsView(navigationRequest: request)
              }
            }
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
    @State private var inboxViewModel: GmailInboxViewModel
    @State private var mailActionViewModel: GmailMailActionViewModel
    @State private var microsoftGraphViewModel: MailboxProviderConnectionViewModel
    @State private var mailboxWorkCoordinator = MailboxWorkCoordinator.shared

    // swiftlint:disable:next function_body_length
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
      _inboxViewModel = State(
        initialValue: GmailInboxViewModel(
          bodyPrefetcher: mailboxConnection,
          service: mailboxConnection,
          searchService: mailboxConnection,
          syncCoordinator: session.sharedMailboxFreshnessViewModel(
            for: snapshot,
            service: mailboxConnection
          ),
          session: snapshot
        )
      )
      _mailActionViewModel = State(
        initialValue: GmailMailActionViewModel(
          service: mailboxConnection,
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
        showsDismissButton: false,
        attentions: settingsAttentions,
        hasUnsavedChanges: {
          ewsViewModel.hasUnsavedChanges || genericMailViewModel.hasUnsavedChanges
        },
        canDiscardChanges: {
          SettingsNavigationPolicy.canDiscardChanges(
            isSetupWorking: ewsViewModel.isWorking || genericMailViewModel.isConnecting
          )
        },
        discardChanges: {
          ewsViewModel.discardUnsavedChanges()
          genericMailViewModel.discardUnsavedChanges()
        },
        destinationContent: { destination, request in
          switch destination {
          case .accountAndDevices:
            AccountAndDevicesSettingsView(
              session: session,
              snapshot: snapshot,
              signOut: signOut
            )
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
              connectionsDidChange: refreshConnectionAuthorityAndNotify,
              gmailConnectionsDidChange: notifyConnectionsDidChange,
              isMailboxBusy: mailboxWorkCoordinator.isBusy(
                productAccountId: snapshot.productAccountId
              ),
              navigationRequest: request
            )
          case .appearance:
            AppearanceSettingsView(navigationRequest: request)
          default:
            EmptyView()
          }
        }
      )
      .onDisappear {
        ewsViewModel.invalidate()
        genericMailViewModel.invalidate()
      }
    }

    private var settingsAttentions: [SettingsAttention] {
      let connections = EmailAccountsSettingsView.makeSummaryConnections(
        routedConnections: gmailViewModel.connections,
        genericDefinitions: genericMailViewModel.syncedDefinitions,
        authorizedGenericConnectionIds: genericMailViewModel.authorizedSyncedConnectionIds,
        session: snapshot
      )
      let syncFailure = connections.lazy.compactMap { connection -> String? in
        guard case .failed(let message) = freshnessViewModel.status(for: connection).phase else {
          return nil
        }
        return message
      }.first
      guard
        let attention = SettingsAttention.emailAccounts(
          authorizationRequired: connections.contains {
            $0.authorizationState == .required
          },
          syncFailureMessage: syncFailure
        )
      else {
        return []
      }
      return [attention]
    }

    private func signOut() {
      ewsViewModel.invalidate()
      genericMailViewModel.invalidate()
      Task {
        await session.signOut {
          await mailActionViewModel.prepareForSignOut()
          freshnessViewModel.cancelAll()
          freshnessViewModel.clearPersistedState()
          await mailboxWorkCoordinator.cancelBodyPrefetch(
            productAccountId: snapshot.productAccountId
          )
          await inboxViewModel.prepareForSignOut()
        }
      }
    }

    private func refreshConnectionAuthorityAndNotify() {
      Task {
        await EmailAccountsSettingsView.refreshConnectionAuthority(
          loadRoutedConnections: gmailViewModel.load,
          loadGenericConnections: genericMailViewModel.loadSyncedDefinitions,
          loadMicrosoftConnections: microsoftGraphViewModel.load,
          loadEWSConnections: ewsViewModel.load,
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
