import SwiftUI

// This destination keeps its small, tightly coupled form subviews together.
// swiftlint:disable file_length type_body_length

protocol MailProfileSettingsSyncing: MailProfileLifecycleSyncing, MailProfileSnapshotLoading {
  func deleteProfile(
    _ review: MailProfileDeletionReview,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot

  func duplicateProfile(
    from review: MailProfileDuplicationReview,
    name: String,
    appearance: MailProfileAppearance,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot

  func transferConnection(
    _ review: MailProfileConnectionTransferReview,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot
}

extension MailboxConnectionSyncService: MailProfileSettingsSyncing {}

@MainActor
@Observable
final class MailProfileSettingsViewModel {
  private(set) var changeRevision = 0
  private(set) var errorMessage: String?
  private(set) var isWorking = false
  private(set) var preferredProfileIdAfterChange: MailProfileId?
  private(set) var snapshot: MailProfileSyncSnapshot?

  private let lifecycleStore: MailProfileLifecycleStore
  private let deletionReviewProvider:
    (MailProfileId, MailProfileSyncSnapshot, ProductAccountSessionSnapshot) async throws
      -> MailProfileDeletionReview
  private let service: MailProfileSettingsSyncing
  private let session: ProductAccountSessionSnapshot
  private let startupStore: MailProfileStartupSelectionPersisting
  private let authorizedRemoteContentCache: any AuthorizedRemoteContentCacheClearing

  var hasPendingChanges: Bool { lifecycleStore.hasPendingChanges }

  var profiles: [MailProfileDefinition] {
    lifecycleStore.profiles.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  var startupProfileId: MailProfileId? {
    startupStore.load(productAccountId: session.productAccountId)
  }

  init(
    session: ProductAccountSessionSnapshot,
    service: MailProfileSettingsSyncing = MailboxConnectionSyncService(),
    localStateStore: MailProfileLifecycleLocalStatePersisting =
      KeychainMailProfileStateStore(),
    startupStore: MailProfileStartupSelectionPersisting =
      UserDefaultsMailProfileStartupStore(),
    authorizedRemoteContentCache: any AuthorizedRemoteContentCacheClearing =
      AuthorizedRemoteContentCache(),
    deletionReviewProvider:
      (
        (MailProfileId, MailProfileSyncSnapshot, ProductAccountSessionSnapshot) async throws
          -> MailProfileDeletionReview
      )? = nil
  ) {
    self.session = session
    self.service = service
    self.startupStore = startupStore
    self.authorizedRemoteContentCache = authorizedRemoteContentCache
    self.deletionReviewProvider =
      deletionReviewProvider ?? Self.liveDeletionReview
    lifecycleStore = MailProfileLifecycleStore(
      session: session,
      syncService: service,
      localStateStore: localStateStore
    )
  }

  func load() async {
    guard isWorking == false else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      try retryPendingRemoteContentCleanup()
      try await refreshSnapshot()
      if lifecycleStore.hasPendingChanges {
        try await lifecycleStore.synchronize()
        try await refreshSnapshot()
        recordChange(preferredProfileId: preferredProfileIdAfterChange)
      }
      errorMessage = lifecycleStore.errorMessage
    } catch is CancellationError {
    } catch {
      errorMessage = localSynchronizationMessage(error)
    }
  }

  func createProfile(name: String, appearance: MailProfileAppearance) async -> Bool {
    guard appearance.isCurated else {
      errorMessage = MailProfileSyncError.invalidProfileState.localizedDescription
      return false
    }
    do {
      let profileId = try lifecycleStore.createProfile(name: name, appearance: appearance)
      preferredProfileIdAfterChange = profileId
      await synchronizeLocalChanges(preferredProfileId: profileId)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func saveProfile(
    _ profileId: MailProfileId,
    name: String,
    appearance: MailProfileAppearance
  ) async -> Bool {
    guard appearance.isCurated else {
      errorMessage = MailProfileSyncError.invalidProfileState.localizedDescription
      return false
    }
    do {
      try lifecycleStore.renameProfile(profileId, name: name)
      try lifecycleStore.styleProfile(profileId, appearance: appearance)
      await synchronizeLocalChanges(preferredProfileId: profileId)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func duplicateProfile(
    _ source: MailProfileDefinition,
    name: String,
    appearance: MailProfileAppearance,
    configuration: Set<MailProfileDuplicableConfiguration>
  ) async -> Bool {
    guard appearance.isCurated, let updatedAt = snapshot?.updatedAt else {
      errorMessage = MailProfileSyncError.invalidLifecycleReview.localizedDescription
      return false
    }
    return await performAuthoritativeChange(preferredProfileId: source.id) {
      try await service.duplicateProfile(
        from: MailProfileDuplicationReview(
          configuration: configuration,
          expectedProfileUpdatedAt: updatedAt,
          id: UUID().uuidString.lowercased(),
          sourceProfileId: source.id
        ),
        name: name,
        appearance: appearance,
        session: session
      )
    }
  }

  func transferConnection(
    _ connectionId: MailboxConnectionId,
    from sourceProfileId: MailProfileId,
    to destinationProfileId: MailProfileId
  ) async -> Bool {
    guard let snapshot, let updatedAt = snapshot.updatedAt,
      snapshot.assignments[connectionId] == sourceProfileId,
      sourceProfileId != destinationProfileId
    else {
      errorMessage = MailProfileSyncError.invalidLifecycleReview.localizedDescription
      return false
    }
    return await performAuthoritativeChange(preferredProfileId: sourceProfileId) {
      try await service.transferConnection(
        MailProfileConnectionTransferReview(
          connectionId: connectionId,
          customCategoryCopies: [],
          destinationProfileId: destinationProfileId,
          expectedProfileUpdatedAt: updatedAt,
          sourceProfileId: sourceProfileId
        ),
        session: session
      )
    }
  }

  func deleteProfile(_ profileId: MailProfileId) async -> Bool {
    guard let snapshot, let updatedAt = snapshot.updatedAt,
      snapshot.profiles.count > 1,
      snapshot.assignments.values.contains(profileId) == false
    else {
      errorMessage = MailProfileSyncError.profileHasUnresolvedState.localizedDescription
      return false
    }
    let review: MailProfileDeletionReview
    do {
      review = try await deletionReviewProvider(profileId, snapshot, session)
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
    guard review.profileId == profileId, review.expectedProfileUpdatedAt == updatedAt else {
      errorMessage = MailProfileSyncError.invalidLifecycleReview.localizedDescription
      return false
    }
    let deleted = await performAuthoritativeChange(preferredProfileId: snapshot.defaultProfileId) {
      try await service.deleteProfile(
        review,
        session: session
      )
    }
    if deleted {
      do {
        try lifecycleStore.recordPendingRemoteContentCleanup(profileId: profileId)
        try clearRemoteContent(profileId: profileId)
        try lifecycleStore.finishPendingRemoteContentCleanup(profileId: profileId)
      } catch {
        errorMessage =
          "Profile deleted. Local Remote Message Content will retry cleanup when you reopen Mail Profiles."
        return false
      }
    }
    return deleted
  }

  private func retryPendingRemoteContentCleanup() throws {
    for profileId in lifecycleStore.pendingRemoteContentCleanupProfileIds {
      try clearRemoteContent(profileId: profileId)
      try lifecycleStore.finishPendingRemoteContentCleanup(profileId: profileId)
    }
  }

  private func clearRemoteContent(profileId: MailProfileId) throws {
    try authorizedRemoteContentCache.clear(
      productAccountId: session.productAccountId,
      profileId: profileId
    )
  }

  func connections(in profileId: MailProfileId) -> [MailboxConnectionId] {
    guard let snapshot else { return [] }
    return snapshot.assignments
      .filter { $0.value == profileId }
      .map(\.key)
      .sorted { $0.rawValue < $1.rawValue }
  }

  func setStartupProfile(_ profileId: MailProfileId) {
    guard profiles.contains(where: { $0.id == profileId }) else { return }
    startupStore.save(profileId, productAccountId: session.productAccountId)
  }

  func clearError() {
    errorMessage = nil
  }

  private func synchronizeLocalChanges(preferredProfileId: MailProfileId) async {
    guard isWorking == false else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      try await lifecycleStore.synchronize()
      try await refreshSnapshot()
      recordChange(preferredProfileId: preferredProfileId)
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      errorMessage = localSynchronizationMessage(error)
    }
  }

  private func performAuthoritativeChange(
    preferredProfileId: MailProfileId?,
    _ change: () async throws -> MailProfileSyncSnapshot
  ) async -> Bool {
    guard isWorking == false else { return false }
    isWorking = true
    defer { isWorking = false }
    do {
      let snapshot = try await change()
      try accept(snapshot)
      recordChange(preferredProfileId: preferredProfileId)
      errorMessage = nil
      return true
    } catch is CancellationError {
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func refreshSnapshot() async throws {
    try accept(try await service.loadProfileSnapshot(session: session))
  }

  private func accept(_ snapshot: MailProfileSyncSnapshot) throws {
    self.snapshot = snapshot
    try lifecycleStore.updateFromSnapshot(snapshot)
  }

  private func recordChange(preferredProfileId: MailProfileId?) {
    self.preferredProfileIdAfterChange = preferredProfileId
    changeRevision &+= 1
  }

  private func localSynchronizationMessage(_ error: Error) -> String {
    "Changes are saved on this device and will sync later. \(error.localizedDescription)"
  }

  private static func liveDeletionReview(
    profileId: MailProfileId,
    snapshot: MailProfileSyncSnapshot,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileDeletionReview {
    guard let updatedAt = snapshot.updatedAt else {
      throw MailProfileSyncError.invalidLifecycleReview
    }
    let connectionIds = Set(
      snapshot.assignments.compactMap { connectionId, assignedProfileId in
        assignedProfileId == profileId ? connectionId : nil
      })
    async let drafts = MailCompositionDraftRepository().drafts(
      productAccountId: session.productAccountId,
      profileId: profileId,
      session: session
    )
    async let outboxItems = OutboxDeliveryService.shared.actionableItems(session: session)
    async let pendingActions = PendingProviderActionService.shared.pendingActions(session: session)
    let (resolvedDrafts, resolvedOutboxItems, resolvedPendingActions) =
      try await (drafts, outboxItems, pendingActions)
    return MailProfileDeletionReview(
      expectedProfileUpdatedAt: updatedAt,
      profileId: profileId,
      unresolvedDraftCount: resolvedDrafts.count,
      unresolvedOutboxCount: resolvedOutboxItems.count {
        connectionIds.contains($0.connectionId)
      },
      unresolvedPendingActionCount: resolvedPendingActions.count {
        connectionIds.contains($0.mailboxConnectionId)
      }
    )
  }
}

struct MailProfilesSettingsView: View {
  let connectionName: (MailboxConnectionId) -> String
  let profilesDidChange: (MailProfileId?) async -> Void

  @State private var viewModel: MailProfileSettingsViewModel
  @State private var editingProfile: MailProfileDefinition?
  @State private var showsCreateProfile = false

  init(
    viewModel: MailProfileSettingsViewModel,
    connectionName: @escaping (MailboxConnectionId) -> String,
    profilesDidChange: @escaping (MailProfileId?) async -> Void
  ) {
    _viewModel = State(initialValue: viewModel)
    self.connectionName = connectionName
    self.profilesDidChange = profilesDidChange
  }

  var body: some View {
    List {
      if let errorMessage = viewModel.errorMessage {
        Section {
          SettingsInlineErrorView(message: errorMessage, isRetrying: viewModel.isWorking) {
            Task { await viewModel.load() }
          }
        }
      }

      Section {
        ForEach(viewModel.profiles) { profile in
          Button {
            editingProfile = profile
          } label: {
            MailProfileSettingsRow(
              profile: profile,
              connectionCount: viewModel.connections(in: profile.id).count,
              isStartupProfile: viewModel.startupProfileId == profile.id
            )
          }
          .buttonStyle(.plain)
        }
      } header: {
        Text("Profiles")
      } footer: {
        if viewModel.hasPendingChanges {
          Text("Profile changes are saved on this device and waiting for Product Sync.")
        } else {
          Text("Names, styles, and ownership synchronize through encrypted Product Sync.")
        }
      }
    }
    .navigationTitle("Mail Profiles")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Add Mail Profile", systemImage: "plus") {
          viewModel.clearError()
          showsCreateProfile = true
        }
      }
    }
    .sheet(isPresented: $showsCreateProfile) {
      MailProfileCreateView(viewModel: viewModel)
    }
    .sheet(item: $editingProfile) { profile in
      NavigationStack {
        MailProfileEditView(
          connectionName: connectionName,
          profile: profile,
          viewModel: viewModel
        )
      }
    }
    .task { await viewModel.load() }
    .onChange(of: viewModel.changeRevision) { _, _ in
      Task { await profilesDidChange(viewModel.preferredProfileIdAfterChange) }
    }
    .overlay {
      if viewModel.isWorking && viewModel.profiles.isEmpty {
        ProgressView("Loading Mail Profiles…")
      }
    }
  }
}

private struct MailProfileSettingsRow: View {
  let profile: MailProfileDefinition
  let connectionCount: Int
  let isStartupProfile: Bool

  var body: some View {
    Label {
      VStack(alignment: .leading) {
        Text(profile.name)
        Text(connectionSummary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: profile.appearance.symbolName)
        .foregroundStyle(profile.appearance.settingsColor)
        .accessibilityHidden(true)
    }
    .badge(isStartupProfile ? "Startup" : nil)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(profile.name), \(profile.appearance.accessibilityDescription), \(connectionSummary)"
    )
  }

  private var connectionSummary: String {
    switch connectionCount {
    case 0: "No Mailbox Connections"
    case 1: "1 Mailbox Connection"
    default: "\(connectionCount) Mailbox Connections"
    }
  }
}

private struct MailProfileCreateView: View {
  let viewModel: MailProfileSettingsViewModel

  @Environment(\.dismiss) private var dismiss
  @State private var colorName = MailProfileAppearance.default.colorName
  @State private var name = ""
  @State private var symbolName = MailProfileAppearance.default.symbolName

  var body: some View {
    NavigationStack {
      Form {
        MailProfileIdentityFields(
          name: $name,
          colorName: $colorName,
          symbolName: $symbolName
        )
      }
      .navigationTitle("New Mail Profile")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create Profile") {
            Task {
              if await viewModel.createProfile(name: name, appearance: appearance) {
                dismiss()
              }
            }
          }
          .disabled(viewModel.isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
  }

  private var appearance: MailProfileAppearance {
    MailProfileAppearance(colorName: colorName, symbolName: symbolName)
  }
}

private struct MailProfileEditView: View {
  let connectionName: (MailboxConnectionId) -> String
  let profile: MailProfileDefinition
  let viewModel: MailProfileSettingsViewModel

  @Environment(\.dismiss) private var dismiss
  @State private var colorName: String
  @State private var name: String
  @State private var showsDeleteConfirmation = false
  @State private var showsDuplicateProfile = false
  @State private var symbolName: String

  init(
    connectionName: @escaping (MailboxConnectionId) -> String,
    profile: MailProfileDefinition,
    viewModel: MailProfileSettingsViewModel
  ) {
    self.connectionName = connectionName
    self.profile = profile
    self.viewModel = viewModel
    _colorName = State(initialValue: profile.appearance.colorName)
    _name = State(initialValue: profile.name)
    _symbolName = State(initialValue: profile.appearance.symbolName)
  }

  var body: some View {
    Form {
      MailProfileIdentityFields(
        name: $name,
        colorName: $colorName,
        symbolName: $symbolName
      )

      Section {
        Button("Use for New Windows", systemImage: "macwindow.badge.plus") {
          viewModel.setStartupProfile(profile.id)
        }
        .disabled(viewModel.startupProfileId == profile.id)
      } header: {
        Text("This Device")
      } footer: {
        Text("Window restoration and the Startup Profile stay only on this device.")
      }

      Section {
        let connectionIds = viewModel.connections(in: profile.id)
        if connectionIds.isEmpty {
          Text("No Mailbox Connections")
            .foregroundStyle(.secondary)
        } else {
          ForEach(connectionIds, id: \.self) { connectionId in
            MailProfileConnectionTransferRow(
              connectionId: connectionId,
              connectionName: connectionName(connectionId),
              destinations: viewModel.profiles.filter { $0.id != profile.id },
              sourceProfileId: profile.id,
              viewModel: viewModel
            )
          }
        }
      } header: {
        Text("Mailbox Connections")
      } footer: {
        Text(
          "A transfer moves the connection and its connection-owned work without reauthorization.")
      }

      Section {
        Button("Duplicate Profile", systemImage: "plus.square.on.square") {
          showsDuplicateProfile = true
        }
        Button("Delete \(profile.name)", systemImage: "trash", role: .destructive) {
          showsDeleteConfirmation = true
        }
        .disabled(
          viewModel.profiles.count <= 1 || viewModel.connections(in: profile.id).isEmpty == false
        )
        .confirmationDialog(
          "Delete \(profile.name)?",
          isPresented: $showsDeleteConfirmation,
          titleVisibility: .visible
        ) {
          Button("Delete Mail Profile", role: .destructive) {
            Task {
              if await viewModel.deleteProfile(profile.id) { dismiss() }
            }
          }
          Button("Keep Mail Profile", role: .cancel) {}
        } message: {
          Text("Its Profile-owned settings are permanently removed. Provider mail is not deleted.")
        }
      } footer: {
        Text(
          "Move every Mailbox Connection before deleting a Profile. The final Profile cannot be deleted."
        )
      }
    }
    .navigationTitle(profile.name)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel", role: .cancel) { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save Changes") {
          Task {
            if await viewModel.saveProfile(profile.id, name: name, appearance: appearance) {
              dismiss()
            }
          }
        }
        .disabled(viewModel.isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .sheet(isPresented: $showsDuplicateProfile) {
      MailProfileDuplicateView(source: profile, viewModel: viewModel)
    }
  }

  private var appearance: MailProfileAppearance {
    MailProfileAppearance(colorName: colorName, symbolName: symbolName)
  }
}

private struct MailProfileIdentityFields: View {
  @Binding var name: String
  @Binding var colorName: String
  @Binding var symbolName: String

  var body: some View {
    Section("Identity") {
      TextField("Profile Name", text: $name)
        .textInputAutocapitalization(.words)
      Picker("Icon", selection: $symbolName) {
        ForEach(MailProfileAppearance.allowedSymbolNames, id: \.self) { symbolName in
          Label(symbolTitle(symbolName), systemImage: symbolName)
            .tag(symbolName)
        }
      }
      Picker("Color", selection: $colorName) {
        ForEach(MailProfileAppearance.allowedColorNames, id: \.self) { colorName in
          Label(colorName.capitalized, systemImage: "circle.fill")
            .foregroundStyle(
              MailProfileAppearance(colorName: colorName, symbolName: symbolName).settingsColor
            )
            .tag(colorName)
        }
      }
    }
  }

  private func symbolTitle(_ symbolName: String) -> String {
    MailProfileAppearance(colorName: colorName, symbolName: symbolName)
      .accessibilityDescription
      .components(separatedBy: ",").first ?? "Profile"
  }
}

private struct MailProfileConnectionTransferRow: View {
  let connectionId: MailboxConnectionId
  let connectionName: String
  let destinations: [MailProfileDefinition]
  let sourceProfileId: MailProfileId
  let viewModel: MailProfileSettingsViewModel

  @State private var pendingDestination: MailProfileDefinition?

  var body: some View {
    LabeledContent(connectionName) {
      Menu("Move") {
        ForEach(destinations) { destination in
          Button(destination.name) { pendingDestination = destination }
        }
      }
      .disabled(destinations.isEmpty || viewModel.isWorking)
      .confirmationDialog(
        transferTitle,
        isPresented: Binding(
          get: { pendingDestination != nil },
          set: { if $0 == false { pendingDestination = nil } }
        ),
        titleVisibility: .visible
      ) {
        if let destination = pendingDestination {
          Button("Move to \(destination.name)") {
            pendingDestination = nil
            Task {
              _ = await viewModel.transferConnection(
                connectionId,
                from: sourceProfileId,
                to: destination.id
              )
            }
          }
        }
        Button("Keep in Current Profile", role: .cancel) { pendingDestination = nil }
      } message: {
        Text("Source Profile-wide rules and preferences stay behind.")
      }
    }
  }

  private var transferTitle: String {
    guard let pendingDestination else { return "Move Mailbox Connection?" }
    return "Move \(connectionName) to \(pendingDestination.name)?"
  }
}

private struct MailProfileDuplicateView: View {
  let source: MailProfileDefinition
  let viewModel: MailProfileSettingsViewModel

  @Environment(\.dismiss) private var dismiss
  @State private var copiesCategories = true
  @State private var copiesMailViews = true
  @State private var copiesTemplates = true
  @State private var name: String

  init(source: MailProfileDefinition, viewModel: MailProfileSettingsViewModel) {
    self.source = source
    self.viewModel = viewModel
    _name = State(initialValue: "\(source.name) Copy")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("New Profile") {
          TextField("Profile Name", text: $name)
        }
        Section {
          Toggle("Categories", isOn: $copiesCategories)
          Toggle("Mail Views", isOn: $copiesMailViews)
          Toggle("Templates", isOn: $copiesTemplates)
        } header: {
          Text("Copy")
        } footer: {
          Text(
            "Mailbox Connections, mail, Drafts, Outbox items, Pins, authorizations, and credentials are never copied."
          )
        }
      }
      .navigationTitle("Duplicate \(source.name)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Duplicate Profile") {
            Task {
              if await viewModel.duplicateProfile(
                source,
                name: name,
                appearance: source.appearance,
                configuration: configuration
              ) {
                dismiss()
              }
            }
          }
          .disabled(viewModel.isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
  }

  private var configuration: Set<MailProfileDuplicableConfiguration> {
    var configuration: Set<MailProfileDuplicableConfiguration> = []
    if copiesCategories { configuration.insert(.categories) }
    if copiesMailViews { configuration.insert(.mailViews) }
    if copiesTemplates { configuration.insert(.templates) }
    return configuration
  }
}

extension MailProfileAppearance {
  fileprivate var settingsColor: Color {
    switch colorName {
    case "blue": .blue
    case "indigo": .indigo
    case "purple": .purple
    case "pink": .pink
    case "red": .red
    case "orange": .orange
    case "teal": .teal
    default: .secondary
    }
  }
}
