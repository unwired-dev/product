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

enum ReadReceiptSettingsField: String, Hashable {
  case incoming
  case outgoing
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
  case readReceipt(String?, ReadReceiptSettingsField)
  case storage
  case templateEditor
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
}

extension SettingsDestination {
  var searchItems: [SettingsSearchItem] {
    switch self {
    case .advanced:
      return [
        SettingsSearchItem(
          title: "Diagnostics",
          keywords: ["Redacted report", "Export", "Versions"],
          route: route
        ),
        SettingsSearchItem(
          title: "Local Maintenance",
          keywords: ["Rebuild indexes", "Clear", "Resynchronize"],
          route: route
        ),
      ]
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
    case .privacyAndData:
      return [
        SettingsSearchItem(
          title: "Remote Message Content",
          keywords: ["Remote images", "Tracking Pixels", "IP address"],
          route: route
        ),
        SettingsSearchItem(
          title: "Connection Overrides",
          keywords: ["Mailbox Connection"],
          route: route
        ),
        SettingsSearchItem(
          title: "Attachment Downloads",
          keywords: ["On Demand", "Wi-Fi", "Always"],
          route: route
        ),
      ]
    case .inbox:
      return [
        SettingsSearchItem(
          title: "Thread-List Density",
          keywords: ["Compact", "Comfortable", "Spacious"],
          route: route
        ),
        SettingsSearchItem(
          title: "Preview Length",
          keywords: ["Snippet", "Lines"],
          route: route
        ),
        SettingsSearchItem(title: "Contact Images", keywords: ["Avatars"], route: route),
        SettingsSearchItem(title: "Category Badges", route: route),
        SettingsSearchItem(title: "Attachment Indicators", route: route),
      ]
    case .compose:
      return [
        SettingsSearchItem(title: "Undo Send", keywords: ["Outbox delay"], route: route),
        SettingsSearchItem(
          title: "Composer Presentation",
          keywords: ["Partial", "Full Screen"],
          route: route
        ),
        SettingsSearchItem(title: "Formatting Toolbar", route: route),
        SettingsSearchItem(title: "Quoted Text", keywords: ["Reply"], route: route),
        SettingsSearchItem(
          title: "Forwarded Attachments",
          keywords: ["Forward"],
          route: route
        ),
      ]
    case .signatures:
      return [
        SettingsSearchItem(
          title: "Signatures", keywords: ["Formatted", "Plain Text"], route: route),
        SettingsSearchItem(
          title: "New Message Signature",
          keywords: ["Mailbox Connection", "Default"],
          route: route
        ),
        SettingsSearchItem(
          title: "Replies & Forwards Signature",
          keywords: ["Mailbox Connection", "Default"],
          route: route
        ),
      ]
    case .templates:
      return [
        SettingsSearchItem(
          title: "Templates",
          keywords: ["Formatted Message", "Product Sync"],
          route: route
        ),
        SettingsSearchItem(
          title: "New Template",
          keywords: ["Create", "Subject", "Message Body"],
          route: .newTemplate
        ),
      ]
    case .reading:
      return [
        SettingsSearchItem(
          title: "Mark Opened Messages Read",
          keywords: [
            "Immediately", "After 1 Second", "After 3 Seconds", "After 5 Seconds", "Manually",
          ],
          route: route
        ),
        SettingsSearchItem(title: "Mark Read After Replying", route: route),
        SettingsSearchItem(title: "Mark Read After Archive or Delete", route: route),
        SettingsSearchItem(
          title: "Incoming Read Receipts",
          keywords: ["Ask Every Time", "Never"],
          route: .readReceipt(connectionId: nil, field: .incoming)
        ),
        SettingsSearchItem(
          title: "Outgoing Read Receipts",
          keywords: ["Ask While Sending", "Request by Default", "Never"],
          route: .readReceipt(connectionId: nil, field: .outgoing)
        ),
      ]
    case .swipes:
      return [
        SettingsSearchItem(
          title: "Leading Actions",
          keywords: SwipeAction.allCases.map(\.title),
          route: route
        ),
        SettingsSearchItem(
          title: "Trailing Actions",
          keywords: SwipeAction.allCases.map(\.title),
          route: route
        ),
        SettingsSearchItem(
          title: "Full Swipe",
          keywords: ["Outermost action"],
          route: route
        ),
      ]
    case .categories:
      return [
        SettingsSearchItem(
          title: "Automatic Categorization",
          keywords: ["New Mail", "System Categories"],
          route: route
        ),
        SettingsSearchItem(
          title: "Custom Categories",
          keywords: ["Create", "Edit", "Delete", "Icon", "Color"],
          route: route
        ),
        SettingsSearchItem(
          title: "Historical Categorization",
          keywords: ["Date Range", "Mailbox", "Category Target"],
          route: route
        ),
        SettingsSearchItem(
          title: "Reset Learned Senders",
          keywords: ["Learning Signals"],
          route: route
        ),
      ]
    case .notifications:
      return [
        SettingsSearchItem(
          title: "Quiet",
          keywords: ["Resume", "Until", "Interruptions", "Suggestions"],
          route: route
        ),
        SettingsSearchItem(
          title: "Profile Lock",
          keywords: ["Face ID", "Touch ID", "Passcode", "Background Grace"],
          route: route
        ),
        SettingsSearchItem(
          title: "Notification Permission",
          keywords: ["System Settings", "Denied", "Authorization"],
          route: .notificationPermission
        ),
        SettingsSearchItem(
          title: "Category-Aware Notifications",
          keywords: ["Categories", "Mailbox Connection", "Profile"],
          route: route
        ),
        SettingsSearchItem(
          title: "Lock Screen Content",
          keywords: ["Count", "Sender", "Subject", "Preview"],
          route: route
        ),
        SettingsSearchItem(
          title: "Quiet Schedule",
          keywords: ["Sound", "Badge", "Allowlist"],
          route: route
        ),
        SettingsSearchItem(
          title: "Generic Notification Fallback",
          keywords: ["Content-free", "Device local"],
          route: route
        ),
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
  static let newTemplate = SettingsRoute(
    destination: .templates,
    context: .templateEditor
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

  static func readReceipt(
    connectionId: MailboxConnectionId?,
    field: ReadReceiptSettingsField
  ) -> SettingsRoute {
    SettingsRoute(
      destination: .reading,
      context: .readReceipt(connectionId?.rawValue, field)
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
    .privacyAndData,
    .advanced,
    .inbox,
    .reading,
    .signatures,
    .swipes,
    .categories,
    .notifications,
    .templates,
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
    .interactiveDismissDisabled(showsDismissButton || hasUnsavedChanges())
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
      .toolbar(removing: .sidebarToggle)
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
      ToolbarItem(placement: .cancellationAction) {
        Button(action: requestDismiss) {
          Label("Close Settings", systemImage: "xmark")
            .labelStyle(.iconOnly)
        }
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
  private(set) var pendingKeyRotationDeviceCount = 0
  private(set) var recoveryKeyStatus = RecoveryKeyStatus.unavailable
  private(set) var revealedRecoveryKey: String?

  private let service: AccountAndDevicesService

  var canRevokeTrustedDevices: Bool {
    recoveryKeyStatus == .current
      || (pendingKeyRotationDeviceCount > 0 && recoveryKeyStatus == .replacedOnAnotherDevice)
  }

  init(service: AccountAndDevicesService = AccountAndDevicesService()) {
    self.service = service
  }

  func load(
    session: ProductAccountSessionSnapshot,
    recentIdentityToken: () async throws -> String,
    trustedDeviceRevoked: () async -> Void = {}
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
      pendingKeyRotationDeviceCount = snapshot.pendingKeyRotationDeviceCount
      recoveryKeyStatus = snapshot.recoveryKeyStatus
      errorMessage = nil
    } catch ProductAccountServiceError.trustedDeviceRevoked {
      await trustedDeviceRevoked()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func revoke(
    _ device: TrustedDeviceSummary,
    session: ProductAccountSessionSnapshot,
    recentIdentityToken: () async throws -> String,
    trustedDeviceRevoked: () async -> Void = {}
  ) async {
    isWorking = true
    defer { isWorking = false }
    do {
      guard canRevokeTrustedDevices else {
        throw AccountAndDevicesServiceError.recoveryKeyUnavailableForRevocation
      }
      let response = try await service.revokeDevice(
        device,
        session: session,
        recentIdentityToken: try await recentIdentityToken()
      )
      devices.removeAll { $0.id == device.id }
      pendingKeyRotationDeviceCount = response.pendingDeviceCount
      if response.pendingDeviceCount == 0 {
        recoveryKeyStatus = .current
      }
      errorMessage = nil
    } catch is CancellationError {
    } catch ProductAccountServiceError.trustedDeviceRevoked {
      await trustedDeviceRevoked()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func rename(
    _ device: TrustedDeviceSummary,
    displayName: String,
    session: ProductAccountSessionSnapshot,
    recentIdentityToken: () async throws -> String,
    trustedDeviceRevoked: () async -> Void = {}
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
    } catch ProductAccountServiceError.trustedDeviceRevoked {
      await trustedDeviceRevoked()
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
    recoveryKeyRejected: (String) throws -> Void = { _ in },
    trustedDeviceRevoked: () async -> Void = {},
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
      if let publicationError { throw publicationError }
      recoveryKeyStatus = .current
      revealedRecoveryKey = recoveryKey.rawValue
      errorMessage = nil
    } catch is CancellationError {
    } catch AccountAndDevicesServiceError.recoveryMaterialUnverified {
      recoveryKeyStatus = .unverified
      revealedRecoveryKey = nil
      errorMessage = nil
    } catch ProductAccountServiceError.trustedDeviceRevoked {
      await trustedDeviceRevoked()
      errorMessage = nil
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

  @discardableResult
  func acknowledgeRecoveryKey(using acknowledgement: () throws -> Void) -> Bool {
    do {
      try acknowledgement()
      errorMessage = nil
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
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

  static func revokeDevice(_ displayName: String) -> String {
    "Revoke \(displayName)"
  }
}

@MainActor
// swiftlint:disable:next type_body_length
struct AccountAndDevicesSettingsView: View {
  private static let trustedDevicesFooter =
    "Revocation immediately blocks this device from Unwired and future Product Sync data. "
    + "Remote erasure is impossible while it is offline; local data is purged when it "
    + "reconnects. For full account protection, also revoke Gmail or Microsoft sessions in "
    + "the provider's security settings. Key rotation completes after every remaining "
    + "Trusted Device connects."

  let session: ProductAccountSession
  let snapshot: ProductAccountSessionSnapshot
  let signOut: @MainActor () -> Void

  @State private var confirmsRecoveryReplacement = false
  @State private var confirmsCurrentRecoveryReplacement = false
  @State private var confirmsProductAccountDeletion = false

  private func rejectRecoveryKey(_ recoveryKey: String) throws {
    try session.rejectUnacknowledgedRecoveryKey(
      recoveryKey,
      productAccountId: snapshot.productAccountId
    )
  }
  @State private var confirmsSignOut = false
  @State private var deviceToRename: TrustedDeviceSummary?
  @State private var deviceToRevoke: TrustedDeviceSummary?
  @State private var renameDraft = ""
  @State private var viewModel: AccountAndDevicesViewModel

  init(
    session: ProductAccountSession,
    snapshot: ProductAccountSessionSnapshot,
    signOut: @escaping @MainActor () -> Void,
    service: AccountAndDevicesService? = nil
  ) {
    self.session = session
    self.snapshot = snapshot
    self.signOut = signOut
    let resolvedService =
      service
      ?? AccountAndDevicesService(
        recoveryMarkerCleared: { [weak session] productAccountId in
          session?.reloadUnacknowledgedRecoveryKey(productAccountId: productAccountId)
        }
      )
    _viewModel = State(
      initialValue: AccountAndDevicesViewModel(service: resolvedService)
    )
  }

  private var productAccountDeletionSection: some View {
    Section {
      if let deletionErrorMessage = session.deletionErrorMessage {
        SignOutErrorBanner(message: deletionErrorMessage)
      }
      Button("Delete Product Account", role: .destructive) {
        confirmsProductAccountDeletion = true
      }
      .disabled(viewModel.isWorking || session.isDeletingProductAccount)
    } header: {
      Text("Delete Product Account")
    } footer: {
      Text(
        "Deletion immediately removes Product Account data, encrypted Product Sync data, "
          + "Trusted Devices, and push routes. Provider mail is not deleted, and provider "
          + "authorization is managed separately. An internet connection is required."
      )
    }
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

      trustedDevicesSection

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
            || viewModel.recoveryKeyStatus == .unverified
            || viewModel.pendingKeyRotationDeviceCount > 0
        )
        if viewModel.recoveryKeyStatus == .current {
          Button("Replace Recovery Key", role: .destructive) {
            confirmsCurrentRecoveryReplacement = true
          }
          .disabled(viewModel.isWorking || viewModel.pendingKeyRotationDeviceCount > 0)
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

      productAccountDeletionSection
    }
    .navigationTitle("Account & Devices")
    .task(id: snapshot.trustedDeviceId) {
      await viewModel.load(
        session: snapshot,
        recentIdentityToken: {
          try await session.recentIdentityToken(for: snapshot)
        },
        trustedDeviceRevoked: {
          await session.handleTrustedDeviceRevocation(snapshot)
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
        },
        trustedDeviceRevoked: {
          await session.handleTrustedDeviceRevocation(snapshot)
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
            },
            trustedDeviceRevoked: {
              await session.handleTrustedDeviceRevocation(snapshot)
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
      "Revoke Trusted Device?",
      isPresented: Binding(
        get: { deviceToRevoke != nil },
        set: { isPresented in
          if !isPresented { deviceToRevoke = nil }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("Revoke", role: .destructive) {
        guard let device = deviceToRevoke else { return }
        deviceToRevoke = nil
        Task {
          await viewModel.revoke(
            device,
            session: snapshot,
            recentIdentityToken: {
              try await session.recentIdentityToken(for: snapshot)
            },
            trustedDeviceRevoked: {
              await session.handleTrustedDeviceRevocation(snapshot)
            }
          )
        }
      }
      Button("Cancel", role: .cancel) { deviceToRevoke = nil }
    } message: {
      Text(
        "This immediately cuts off Unwired access and rotates Product Sync keys. "
          + "The device's local data cannot be erased remotely while it is offline."
      )
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
            recoveryKeyRejected: rejectRecoveryKey,
            trustedDeviceRevoked: {
              await session.handleTrustedDeviceRevocation(snapshot)
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
      "Permanently delete this Product Account?",
      isPresented: $confirmsProductAccountDeletion,
      titleVisibility: .visible
    ) {
      Button("Delete Product Account", role: .destructive) {
        Task { await session.deleteProductAccount() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Sign in with Apple will confirm your identity. This cannot be undone. "
          + "Your provider mail will remain at the provider, and provider authorization "
          + "must be removed separately."
      )
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
            recoveryKeyRejected: rejectRecoveryKey,
            trustedDeviceRevoked: {
              await session.handleTrustedDeviceRevocation(snapshot)
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
            viewModel.hideRecoveryKey()
          }
        }
      )
    ) {
      RecoveryKeyPresentation(
        recoveryKey: viewModel.revealedRecoveryKey ?? "",
        acknowledge: {
          guard let recoveryKey = viewModel.revealedRecoveryKey else { return }
          let acknowledged = viewModel.acknowledgeRecoveryKey {
            try session.acknowledgeRecoveryKey(
              recoveryKey,
              productAccountId: snapshot.productAccountId
            )
          }
          if acknowledged { viewModel.hideRecoveryKey() }
        }
      )
      .interactiveDismissDisabled()
    }
  }
}

extension AccountAndDevicesSettingsView {
  @ViewBuilder
  fileprivate var trustedDevicesSection: some View {
    Section {
      if viewModel.pendingKeyRotationDeviceCount > 0 {
        Label(
          "Waiting for \(viewModel.pendingKeyRotationDeviceCount) Trusted Device(s) to connect",
          systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
        )
        .font(.caption)
      }
      if viewModel.isLoading, viewModel.devices.isEmpty {
        ProgressView("Loading Trusted Devices…")
      } else {
        ForEach(viewModel.devices) { device in
          trustedDeviceRow(device)
        }
      }
    } header: {
      Text("Trusted Devices")
    } footer: {
      Text(Self.trustedDevicesFooter)
    }
  }

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
      if device.id != snapshot.trustedDeviceId {
        Button("Revoke", role: .destructive) {
          deviceToRevoke = device
        }
        .disabled(viewModel.isWorking || !viewModel.canRevokeTrustedDevices)
        .accessibilityLabel(
          AccountAndDevicesAccessibility.revokeDevice(device.displayName)
        )
      }
    }
  }

  fileprivate var recoveryActionTitle: String {
    switch viewModel.recoveryKeyStatus {
    case .current:
      return "View Recovery Key"
    case .notBackedUp:
      return "Generate Recovery Key"
    case .unverified:
      return "Verification Pending"
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
    case .unverified:
      return "Recovery Key verification pending"
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
    case .notBackedUp, .unverified, .replacedOnAnotherDevice:
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
    case .unverified:
      return
        "The replacement is stored only on this device until the backend confirms it. "
        + "Reconnect and refresh before using or replacing this Recovery Key."
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
  let acknowledge: () -> Void

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
          Button("Done", action: acknowledge)
        }
      }
    }
  }
}

struct CategoriesSettingsView: View {
  @Bindable var viewModel: CustomCategoryViewModel
  let connections: [MailboxConnection]
  let loadProviderMailboxes: (MailboxConnection) async throws -> [ProviderMailbox]
  let categorizeHistorical: (HistoricalCategorizationScope, MailboxConnection) async throws -> Int

  @State private var categoryPendingDeletion: CustomCategory?
  @State private var editingCategory: CustomCategory?
  @State private var isCreatingCategory = false
  @State private var showsLearningResetConfirmation = false

  var body: some View {
    Form {
      Section("Automatic Categorization") {
        Toggle(
          "Categorize new mail automatically",
          isOn: Binding(
            get: { viewModel.configuration.automaticCategorizationEnabled },
            set: { enabled in
              Task { await viewModel.setAutomaticCategorizationEnabled(enabled) }
            }
          )
        )
        Text(
          "Turning this off leaves existing Message Categories unchanged. Manual Categories "
            + "remain available."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section("System Categories") {
        ForEach(SystemCategoryDefinition.all) { category in
          Toggle(
            isOn: Binding(
              get: { viewModel.configuration.isSystemCategoryEnabled(category.id) },
              set: { enabled in
                Task {
                  await viewModel.setSystemCategoryEnabled(
                    enabled,
                    categoryId: category.id
                  )
                }
              }
            )
          ) {
            Label(category.name, systemImage: category.symbolName)
          }
        }
        Text("Disabled Categories stop future automatic assignment without removing old matches.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Section("Custom Categories") {
        ForEach(viewModel.categories) { category in
          HStack {
            Toggle(
              isOn: Binding(
                get: { category.isEnabled },
                set: { enabled in
                  Task { await viewModel.setEnabled(enabled, for: category) }
                }
              )
            ) {
              VStack(alignment: .leading, spacing: 2) {
                Label(category.name, systemImage: category.symbolName)
                if let description = category.description {
                  Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }

            Menu {
              Button("Edit") { editingCategory = category }
              Button("Delete", role: .destructive) {
                categoryPendingDeletion = category
              }
            } label: {
              Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Manage \(category.name)")
            }
          }
        }

        Button {
          isCreatingCategory = true
        } label: {
          Label("Add Custom Category", systemImage: "plus")
        }
      }

      CategoryHistoricalSettingsSection(
        categories: automaticCategoryChoices,
        connections: connections.filter(\.capabilities.canCategorizeHistorical),
        loadProviderMailboxes: loadProviderMailboxes,
        categorize: categorizeHistorical
      )

      Section("Learning") {
        Button("Reset Learned Senders", role: .destructive) {
          showsLearningResetConfirmation = true
        }
        Text(
          "Resetting positive and negative sender learning changes only future categorization."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      if viewModel.isSyncing || viewModel.isSaving {
        Section {
          ProgressView("Synchronizing Categories…")
        }
      }

      if let errorMessage = viewModel.errorMessage {
        Section {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }
    }
    .task { await viewModel.load() }
    .sheet(isPresented: $isCreatingCategory) {
      CustomCategorySettingsEditor(title: "New Custom Category") { draft in
        _ = try await viewModel.create(draft)
      }
    }
    .sheet(item: $editingCategory) { category in
      CustomCategorySettingsEditor(
        category: category,
        title: "Edit Custom Category"
      ) { draft in
        _ = try await viewModel.save(category, draft: draft)
      }
    }
    .confirmationDialog(
      "Delete this Custom Category?",
      isPresented: Binding(
        get: { categoryPendingDeletion != nil },
        set: { if !$0 { categoryPendingDeletion = nil } }
      ),
      presenting: categoryPendingDeletion
    ) { category in
      Button("Delete \(category.name)", role: .destructive) {
        Task { await viewModel.delete(id: category.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text(
        "Existing message memberships are preserved. Views that depend on this Category will "
          + "require a new explicit selection."
      )
    }
    .confirmationDialog(
      "Reset learned sender signals?",
      isPresented: $showsLearningResetConfirmation
    ) {
      Button("Reset Learning", role: .destructive) {
        Task { await viewModel.resetLearning() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Existing Message Categories stay unchanged. Future categorization starts fresh.")
    }
  }

  private var automaticCategoryChoices: [MessageCategoryChoice] {
    let enabledSystemIds = Set(
      SystemCategoryDefinition.all.filter {
        viewModel.configuration.isSystemCategoryEnabled($0.id)
      }.map(\.id)
    )
    return MessageCategoryChoice.available(customCategories: viewModel.categories).filter {
      !$0.id.hasPrefix("system:") || enabledSystemIds.contains($0.id)
    }
  }
}

private struct CustomCategorySettingsEditor: View {
  let title: String
  let save: (CustomCategoryEditorDraft) async throws -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var draft: CustomCategoryEditorDraft
  @State private var errorMessage: String?
  @State private var isSaving = false
  private let initialDraft: CustomCategoryEditorDraft

  init(
    category: CustomCategory? = nil,
    title: String,
    save: @escaping (CustomCategoryEditorDraft) async throws -> Void
  ) {
    let draft = CustomCategoryEditorDraft(category: category)
    self.title = title
    self.save = save
    initialDraft = draft
    _draft = State(initialValue: draft)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          CustomCategoryEditorFields(
            colorName: $draft.colorName,
            description: $draft.description,
            isDisabled: isSaving,
            name: $draft.name,
            symbolName: $draft.symbolName
          )
        }
        if let errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            Task {
              isSaving = true
              defer { isSaving = false }
              do {
                try await save(draft)
                dismiss()
              } catch {
                errorMessage = error.localizedDescription
              }
            }
          }
          .disabled(!draft.canSave || isSaving)
        }
      }
      .interactiveDismissDisabled(isSaving || draft != initialDraft)
    }
  }
}

private struct HistoricalMailboxChoice: Identifiable {
  let collection: MailboxMessageCollection
  let id: String
  let title: String

  static let inbox = HistoricalMailboxChoice(
    collection: .role(.inbox),
    id: "inbox",
    title: "Inbox"
  )
  static let allMail = HistoricalMailboxChoice(
    collection: .allMail,
    id: "all-mail",
    title: "All Mail"
  )
}

enum CategoryHistoricalSettingsSupport {
  static func scope(
    startDate: Date,
    endDate: Date,
    categoryId: String,
    collection: MailboxMessageCollection,
    calendar: Calendar
  ) -> HistoricalCategorizationScope {
    let start = calendar.startOfDay(for: startDate)
    let end = calendar.startOfDay(for: endDate)
    let receivedBefore = calendar.date(byAdding: .day, value: 1, to: end) ?? end
    return HistoricalCategorizationScope(
      categoryIds: categoryId.isEmpty ? nil : [categoryId],
      collection: collection,
      receivedAtOrAfterMilliseconds: Int64(start.timeIntervalSince1970 * 1_000),
      receivedBeforeMilliseconds: Int64(receivedBefore.timeIntervalSince1970 * 1_000)
    )
  }

  static func completedMessage(categorizedCount: Int) -> String {
    "Historical categorization completed for \(categorizedCount) messages."
  }

  static let cancelledMessage =
    "Historical categorization cancelled; completed assignments were kept."
}

private struct CategoryHistoricalSettingsSection: View {
  let categories: [MessageCategoryChoice]
  let connections: [MailboxConnection]
  let loadProviderMailboxes: (MailboxConnection) async throws -> [ProviderMailbox]
  let categorize: (HistoricalCategorizationScope, MailboxConnection) async throws -> Int

  @State private var endDate = Date()
  @State private var errorMessage: String?
  @State private var mailboxChoices: [HistoricalMailboxChoice] = [.inbox, .allMail]
  @State private var resultMessage: String?
  @State private var refreshGeneration = 0
  @State private var refreshTask: Task<Void, Never>?
  @State private var runTask: Task<Void, Never>?
  @State private var selectedCategoryId = ""
  @State private var selectedConnectionId: MailboxConnectionId?
  @State private var selectedMailboxId = HistoricalMailboxChoice.inbox.id
  @State private var startDate =
    Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()

  var body: some View {
    Section("Historical Categorization") {
      if connections.isEmpty {
        Text("No authorized Mailbox Connection supports historical categorization on this device.")
          .foregroundStyle(.secondary)
      } else {
        Picker("Mailbox Connection", selection: $selectedConnectionId) {
          ForEach(connections) { connection in
            Text(connection.displayName).tag(Optional(connection.id))
          }
        }

        Picker("Mailbox", selection: $selectedMailboxId) {
          ForEach(mailboxChoices) { choice in
            Text(choice.title).tag(choice.id)
          }
        }

        Picker("Category Target", selection: $selectedCategoryId) {
          Text("All Enabled Categories").tag("")
          ForEach(categories) { category in
            Text(category.name).tag(category.id)
          }
        }

        DatePicker("From", selection: $startDate, displayedComponents: .date)
        DatePicker("Through", selection: $endDate, displayedComponents: .date)

        if runTask == nil {
          Button("Categorize Selected Old Mail") { start() }
            .disabled(!canStart)
        } else {
          ProgressView("Categorizing selected old mail…")
          Button("Cancel Historical Categorization", role: .destructive) {
            runTask?.cancel()
          }
        }

        if let resultMessage {
          Text(resultMessage)
            .foregroundStyle(.secondary)
        }
        if let errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }

      Text(
        "Only the selected connection, mailbox, date range, and Category target are processed. "
          + "Completed assignments remain when a run is cancelled."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
    .task {
      if !selectFirstConnectionIfNeeded() {
        startMailboxRefresh()
      }
    }
    .onChange(of: selectedConnectionId) { _, _ in
      selectedMailboxId = HistoricalMailboxChoice.inbox.id
      startMailboxRefresh()
    }
    .onChange(of: categories.map(\.id)) { _, categoryIds in
      if !selectedCategoryId.isEmpty, !categoryIds.contains(selectedCategoryId) {
        selectedCategoryId = ""
      }
    }
    .onDisappear {
      refreshTask?.cancel()
      refreshTask = nil
      runTask?.cancel()
      runTask = nil
    }
  }

  private var canStart: Bool {
    selectedConnection != nil
      && HistoricalCategorizationScope.isValidDateRange(
        startDate: startDate,
        endDate: endDate,
        calendar: .current
      )
      && runTask == nil
  }

  private var selectedConnection: MailboxConnection? {
    connections.first { $0.id == selectedConnectionId }
  }

  private func selectFirstConnectionIfNeeded() -> Bool {
    guard !connections.contains(where: { $0.id == selectedConnectionId }) else { return false }
    selectedConnectionId = connections.first?.id
    return true
  }

  private func startMailboxRefresh() {
    refreshTask?.cancel()
    refreshGeneration += 1
    let generation = refreshGeneration
    guard let connection = selectedConnection else {
      mailboxChoices = [.inbox, .allMail]
      refreshTask = nil
      return
    }
    let connectionId = connection.id
    refreshTask = Task {
      await refreshMailboxChoices(
        connection: connection,
        connectionId: connectionId,
        generation: generation
      )
    }
  }

  private func refreshMailboxChoices(
    connection: MailboxConnection,
    connectionId: MailboxConnectionId,
    generation: Int
  ) async {
    do {
      let providerMailboxes = try await loadProviderMailboxes(connection)
      try Task.checkCancellation()
      guard generation == refreshGeneration, selectedConnectionId == connectionId else { return }
      mailboxChoices =
        [.inbox, .allMail]
        + providerMailboxes.map {
          HistoricalMailboxChoice(
            collection: .providerMailbox($0.id),
            id: "provider:\($0.id)",
            title: $0.title
          )
        }
      if !mailboxChoices.contains(where: { $0.id == selectedMailboxId }) {
        selectedMailboxId = HistoricalMailboxChoice.inbox.id
      }
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      guard generation == refreshGeneration, selectedConnectionId == connectionId else { return }
      mailboxChoices = [.inbox, .allMail]
      errorMessage = error.localizedDescription
    }
    if generation == refreshGeneration { refreshTask = nil }
  }

  private func start() {
    guard let connection = selectedConnection,
      let mailbox = mailboxChoices.first(where: { $0.id == selectedMailboxId })
    else { return }
    errorMessage = nil
    resultMessage = nil
    let scope = historicalScope(collection: mailbox.collection)
    runTask = Task {
      defer { runTask = nil }
      do {
        let categorizedCount = try await categorize(scope, connection)
        try Task.checkCancellation()
        resultMessage = CategoryHistoricalSettingsSupport.completedMessage(
          categorizedCount: categorizedCount
        )
      } catch is CancellationError {
        resultMessage = CategoryHistoricalSettingsSupport.cancelledMessage
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func historicalScope(
    collection: MailboxMessageCollection
  ) -> HistoricalCategorizationScope {
    CategoryHistoricalSettingsSupport.scope(
      startDate: startDate,
      endDate: endDate,
      categoryId: selectedCategoryId,
      collection: collection,
      calendar: .current
    )
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
            showsDismissButton: true,
            destinationContent: { destination, request in
              if destination == .appearance {
                AppearanceSettingsView(navigationRequest: request)
              } else if destination == .privacyAndData {
                PrivacyDataSettingsView(connections: [])
              } else if destination == .advanced {
                AdvancedSettingsView(
                  connections: [],
                  productSyncHealth: .signedOut,
                  status: { _ in .idle }
                )
              }
            }
          )
        case .failed(let message):
          AdaptiveSettingsScene(
            isSignedIn: false,
            showsDismissButton: true,
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
              } else if destination == .privacyAndData {
                PrivacyDataSettingsView(connections: [])
              } else if destination == .advanced {
                AdvancedSettingsView(
                  connections: [],
                  productSyncHealth: .signedOut,
                  status: { _ in .idle }
                )
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
  // swiftlint:disable:next type_body_length
  private struct DevelopmentEmailAccountsSettingsHost: View {
    let session: ProductAccountSession
    let snapshot: ProductAccountSessionSnapshot
    private let mailboxConnection: MailboxConnectionRouter

    @State private var categoryViewModel: CustomCategoryViewModel
    @State private var ewsViewModel: EWSSetupViewModel
    @State private var composePreferenceStore: ComposePreferenceStore
    @State private var featureSuggestionPreferenceStore: FeatureSuggestionPreferenceStore
    @State private var signatureStore: SignatureStore
    @State private var templateStore: TemplateStore
    @State private var freshnessViewModel: MailboxFreshnessViewModel
    @State private var genericMailViewModel: GenericMailSetupViewModel
    @State private var gmailViewModel: MailboxProviderConnectionViewModel
    @State private var inboxPreferenceStore: InboxPreferenceStore
    @State private var swipePreferenceStore: SwipePreferenceStore
    @State private var inboxViewModel: GmailInboxViewModel
    @State private var mailActionViewModel: GmailMailActionViewModel
    @State private var microsoftGraphViewModel: MailboxProviderConnectionViewModel
    @State private var notificationRuleViewModel: NotificationRuleViewModel
    @State private var mailboxWorkCoordinator = MailboxWorkCoordinator.shared

    // swiftlint:disable:next function_body_length
    init(
      session: ProductAccountSession,
      snapshot: ProductAccountSessionSnapshot
    ) {
      self.session = session
      self.snapshot = snapshot
      let mailboxConnection = MailboxConnectionRouter()
      self.mailboxConnection = mailboxConnection
      let defaultProfile = MailProfileDefinition.defaultProfile(
        productAccountId: snapshot.productAccountId
      )
      let revalidateTrustedDevice = {
        await session.revalidateTrustedDeviceAfterForegrounding()
      }
      _categoryViewModel = State(
        initialValue: CustomCategoryViewModel(
          service: CustomCategorySyncService(recordScope: defaultProfile.recordScope),
          session: snapshot
        )
      )
      _ewsViewModel = State(
        initialValue: EWSSetupViewModel(
          isSessionCurrent: { session.isCurrent($0) },
          revalidateTrustedDevice: revalidateTrustedDevice,
          session: snapshot
        )
      )
      _composePreferenceStore = State(
        initialValue: session.sharedComposePreferenceStore(for: snapshot)
      )
      _featureSuggestionPreferenceStore = State(
        initialValue: session.sharedFeatureSuggestionPreferenceStore(for: snapshot)
      )
      _signatureStore = State(
        initialValue: session.sharedSignatureStore(for: snapshot)
      )
      _templateStore = State(
        initialValue: session.sharedTemplateStore(
          for: snapshot,
          recordScope: defaultProfile.recordScope
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
          isSyncSessionCurrent: { candidate in
            candidate.map(session.isCurrent) ?? false
          },
          revalidateTrustedDevice: revalidateTrustedDevice,
          syncSession: snapshot
        )
      )
      _gmailViewModel = State(
        initialValue: MailboxProviderConnectionViewModel(
          service: mailboxConnection,
          isSessionCurrent: { session.isCurrent($0) },
          revalidateTrustedDevice: revalidateTrustedDevice,
          session: snapshot
        )
      )
      _inboxPreferenceStore = State(
        initialValue: session.sharedInboxPreferenceStore(for: snapshot)
      )
      _swipePreferenceStore = State(
        initialValue: SwipePreferenceStore(session: snapshot)
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
        initialValue: session.sharedMailActionViewModel(
          for: snapshot,
          service: mailboxConnection
        )
      )
      _microsoftGraphViewModel = State(
        initialValue: MailboxProviderConnectionViewModel(
          service: MicrosoftGraphMailboxConnectionAdapter(),
          isSessionCurrent: { session.isCurrent($0) },
          revalidateTrustedDevice: revalidateTrustedDevice,
          session: snapshot
        )
      )
      _notificationRuleViewModel = State(
        initialValue: NotificationRuleViewModel(
          authorization: UserNotificationService(),
          profileLoader: MailboxConnectionSyncService(),
          profileServiceFactory: { scope in
            NotificationRuleSyncService(recordScope: scope)
          },
          service: NotificationRuleSyncService(),
          session: snapshot
        )
      )
    }

    var body: some View {
      AdaptiveSettingsScene(
        isSignedIn: true,
        showsDismissButton: true,
        attentions: settingsAttentions,
        hasUnsavedChanges: {
          ewsViewModel.hasUnsavedChanges || genericMailViewModel.hasUnsavedChanges
            || notificationRuleViewModel.hasUnsavedChanges
        },
        canDiscardChanges: {
          SettingsNavigationPolicy.canDiscardChanges(
            isSetupWorking: ewsViewModel.isWorking || genericMailViewModel.isConnecting
              || notificationRuleViewModel.isSaving
          )
        },
        discardChanges: {
          ewsViewModel.discardUnsavedChanges()
          genericMailViewModel.discardUnsavedChanges()
          notificationRuleViewModel.discardUnsavedChanges()
        },
        destinationContent: { destination, request in
          switch destination {
          case .accountAndDevices:
            AccountAndDevicesSettingsView(
              session: session,
              snapshot: snapshot,
              signOut: signOut
            )
          case .advanced:
            AdvancedSettingsView(
              connections: gmailViewModel.connections,
              productSyncHealth: .current(session: snapshot),
              status: freshnessViewModel.status,
              backendHealth: { try await ConvexBackendHealthService().health() },
              rebuildIndexes: {
                try await performMaintenance(.rebuildIndexes)
              },
              clearAndResynchronize: {
                try await performMaintenance(.clearAndResynchronize)
              }
            )
            .task {
              let isAuthoritative = await gmailViewModel.load()
              freshnessViewModel.updateConnections(
                gmailViewModel.connections,
                snapshotIsAuthoritative: isAuthoritative
              )
            }
          case .categories:
            CategoriesSettingsView(
              viewModel: categoryViewModel,
              connections: gmailViewModel.connections,
              loadProviderMailboxes: { connection in
                try await mailboxConnection.loadProviderMailboxes(
                  connection: connection,
                  session: snapshot
                )
              },
              categorizeHistorical: { scope, connection in
                let result = try await mailboxConnection.categorizeHistorical(
                  scope: scope,
                  connection: connection,
                  session: snapshot
                )
                _ = await inboxViewModel.reloadLocal(connection: connection)
                return result.categorizedMessageCount
              }
            )
            .task { _ = await gmailViewModel.load() }
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
          case .inbox:
            InboxSettingsView(
              store: inboxPreferenceStore,
              featureSuggestionStore: featureSuggestionPreferenceStore,
              navigationRequest: request
            )
          case .notifications:
            NotificationsSettingsView(
              categoryChoices: MessageCategoryChoice.available(
                customCategories: categoryViewModel.categories
              ),
              connections: gmailViewModel.connections,
              hasLoadedCategory: categoryViewModel.hasLoadedCategory,
              interruptionViewModel: nil,
              navigationRequest: request,
              viewModel: notificationRuleViewModel
            )
            .task {
              async let categories: Void = categoryViewModel.load()
              async let connections: Bool = gmailViewModel.load()
              _ = await (categories, connections)
            }
          case .compose:
            ComposeSettingsView(
              store: composePreferenceStore,
              navigationRequest: request
            )
          case .signatures:
            SignatureSettingsView(
              connections: gmailViewModel.connections,
              store: signatureStore,
              navigationRequest: request
            )
            .task { _ = await gmailViewModel.load() }
          case .templates:
            TemplateSettingsView(store: templateStore, navigationRequest: request)
          case .swipes:
            SwipeSettingsView(store: swipePreferenceStore)
          case .appearance:
            AppearanceSettingsView(navigationRequest: request)
          case .privacyAndData:
            PrivacyDataSettingsView(connections: gmailViewModel.connections)
              .task { _ = await gmailViewModel.load() }
          default:
            EmptyView()
          }
        }
      )
      .task {
        await composePreferenceStore.synchronize()
        await featureSuggestionPreferenceStore.synchronize()
        await signatureStore.synchronize()
        await templateStore.synchronize()
        await inboxPreferenceStore.synchronize()
        await swipePreferenceStore.synchronize()
      }
      .onChange(of: snapshot) { _, refreshedSnapshot in
        categoryViewModel.updateSession(refreshedSnapshot)
        ewsViewModel.updateSession(refreshedSnapshot)
        composePreferenceStore.updateSession(refreshedSnapshot)
        featureSuggestionPreferenceStore.updateSession(refreshedSnapshot)
        signatureStore.updateSession(refreshedSnapshot)
        templateStore.updateSession(refreshedSnapshot)
        freshnessViewModel.updateSession(refreshedSnapshot)
        genericMailViewModel.updateSession(refreshedSnapshot)
        gmailViewModel.sessionSnapshot = refreshedSnapshot
        inboxPreferenceStore.updateSession(refreshedSnapshot)
        swipePreferenceStore.updateSession(refreshedSnapshot)
        inboxViewModel.updateSession(refreshedSnapshot)
        mailActionViewModel.updateSession(refreshedSnapshot)
        microsoftGraphViewModel.sessionSnapshot = refreshedSnapshot
        notificationRuleViewModel.updateSession(refreshedSnapshot)
      }
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
      coordinateProductAccountSignOut(
        session: session,
        mailActionViewModel: mailActionViewModel
      ) {
        ewsViewModel.invalidate()
        genericMailViewModel.invalidate()
        freshnessViewModel.cancelAll()
        freshnessViewModel.clearPersistedState()
        await mailboxWorkCoordinator.cancelBodyPrefetch(
          productAccountId: snapshot.productAccountId
        )
        await inboxViewModel.prepareForSignOut()
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

    private func performMaintenance(
      _ operation: AdvancedMaintenanceOperation
    ) async throws -> AdvancedMaintenanceOutcome {
      freshnessViewModel.cancelAll()
      await mailboxWorkCoordinator.cancelBodyPrefetch(
        productAccountId: snapshot.productAccountId
      )
      switch operation {
      case .clearAndResynchronize:
        try await mailboxConnection.clearLocalMailboxData(session: snapshot)
      case .rebuildIndexes:
        try await mailboxConnection.rebuildLocalIndexes(session: snapshot)
      }
      try Task.checkCancellation()
      guard session.isCurrent(snapshot) else { throw CancellationError() }

      let connectionsAreAuthoritative = await gmailViewModel.load()
      let connections = gmailViewModel.connections
      freshnessViewModel.clearPersistedState()
      freshnessViewModel.updateConnections(
        connections,
        snapshotIsAuthoritative: connectionsAreAuthoritative
      )
      guard connectionsAreAuthoritative else {
        return .pending(
          "Local maintenance completed. Connection status could not be confirmed, so resynchronization is pending."
        )
      }
      await freshnessViewModel.synchronizeFully(connections: connections)
      return maintenanceOutcome(for: connections)
    }

    private func maintenanceOutcome(
      for connections: [MailboxConnection]
    ) -> AdvancedMaintenanceOutcome {
      let phases = connections.map { freshnessViewModel.status(for: $0).phase }
      if phases.contains(where: { if case .offline = $0 { true } else { false } }) {
        return .pending(
          "Local maintenance completed. Resynchronization will resume when this device is online."
        )
      }
      if phases.contains(where: { if case .authorizationRequired = $0 { true } else { false } }) {
        return .pending(
          "Local maintenance completed. Authorize the affected Mailbox Connection to resynchronize it."
        )
      }
      if phases.contains(where: { if case .failed = $0 { true } else { false } }) {
        return .pending(
          "Local maintenance completed. One or more Mailbox Connections need attention "
            + "before resynchronization can finish."
        )
      }
      if phases.contains(where: { if case .backfillPending = $0 { true } else { false } }) {
        return .pending(
          "Recent mail is available. Historical metadata rebuilding will continue in the background."
        )
      }
      return .completed("Local maintenance and resynchronization completed.")
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
