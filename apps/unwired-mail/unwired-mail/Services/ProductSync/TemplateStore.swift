import Foundation
import Observation
import Security

// swiftlint:disable file_length

/// One offline edit based on a known synchronized template value.
struct TemplatePreferencePendingChange: Codable, Equatable, Sendable {
  let baseValue: MailTemplate?
  var localValue: MailTemplate?
}

/// Device-local template edits for one Mail Profile.
struct TemplatePreferenceLocalState: Codable, Equatable, Sendable {
  var pendingChanges: [String: TemplatePreferencePendingChange]
  var preferences: TemplatePreferences

  static let empty = TemplatePreferenceLocalState(
    pendingChanges: [:],
    preferences: .empty
  )
}

/// Persists device-local template edits separately for every Mail Profile.
protocol TemplatePreferenceLocalStatePersisting {
  func clear(productAccountId: String) throws
  func load(
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws -> TemplatePreferenceLocalState?
  func save(
    _ state: TemplatePreferenceLocalState,
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws
}

/// Stores offline template state in the Keychain until encrypted Product Sync accepts it.
struct KeychainTemplateStateStore: TemplatePreferenceLocalStatePersisting {
  private struct Collection: Codable {
    var states: [String: TemplatePreferenceLocalState]
  }

  private static let service = "dev.unwired.mail.template-preferences"

  func clear(productAccountId: String) throws {
    try KeychainStore.delete(service: Self.service, account: productAccountId)
  }

  func load(
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws -> TemplatePreferenceLocalState? {
    try loadCollection(productAccountId: productAccountId).states[scopeKey(recordScope)]
  }

  func save(
    _ state: TemplatePreferenceLocalState,
    productAccountId: String,
    recordScope: MailProfileRecordScope
  ) throws {
    var collection = try loadCollection(productAccountId: productAccountId)
    collection.states[scopeKey(recordScope)] = state
    let data = try JSONEncoder().encode(collection)
    guard let encoded = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(
      encoded,
      service: Self.service,
      account: productAccountId,
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }

  private func loadCollection(productAccountId: String) throws -> Collection {
    guard
      let encoded = try KeychainStore.readString(
        service: Self.service,
        account: productAccountId
      ),
      let data = encoded.data(using: .utf8)
    else { return Collection(states: [:]) }
    do {
      return try JSONDecoder().decode(Collection.self, from: data)
    } catch {
      return Collection(states: [:])
    }
  }

  private func scopeKey(_ recordScope: MailProfileRecordScope) -> String {
    recordScope.namespace ?? "legacy"
  }
}

/// Owns one Mail Profile's offline template state and synchronization lifecycle.
@MainActor
@Observable
final class TemplateStore {
  private(set) var errorMessage: String?
  private(set) var isSynchronizing = false
  private(set) var preferences: TemplatePreferences

  private let automaticallySynchronizes: Bool
  private var editRevision = 0
  private var entityEditRevisions: [String: Int] = [:]
  private var localState: TemplatePreferenceLocalState
  private let localStateStore: TemplatePreferenceLocalStatePersisting
  private let recordScope: MailProfileRecordScope
  private var restorationSucceeded = true
  private var session: ProductAccountSessionSnapshot
  private var sessionGeneration = 0
  private var synchronizationRequestedRevision: Int?
  private var synchronizingGeneration: Int?
  private let syncService: TemplatePreferenceSyncing
  private var syncTask: Task<Void, Never>?

  var hasPendingChanges: Bool {
    localState.pendingChanges.isEmpty == false
  }

  /// Creates a store for one stable Mail Profile record namespace.
  init(
    session: ProductAccountSessionSnapshot,
    recordScope: MailProfileRecordScope,
    syncService: TemplatePreferenceSyncing? = nil,
    localStateStore: TemplatePreferenceLocalStatePersisting = KeychainTemplateStateStore(),
    automaticallySynchronizes: Bool = true
  ) {
    self.session = session
    self.recordScope = recordScope
    self.syncService = syncService ?? TemplateSyncService(recordScope: recordScope)
    self.localStateStore = localStateStore
    self.automaticallySynchronizes = automaticallySynchronizes
    do {
      let restored =
        try localStateStore.load(
          productAccountId: session.productAccountId,
          recordScope: recordScope
        ) ?? .empty
      localState = restored
      preferences = restored.preferences
    } catch {
      localState = .empty
      preferences = .empty
      restorationSucceeded = false
      errorMessage = error.localizedDescription
    }
  }

  /// Creates or updates one template after validating the complete collection.
  func saveTemplate(_ template: MailTemplate) throws {
    try saveTemplate(template, basedOn: nil)
  }

  func saveTemplate(_ template: MailTemplate, basedOn original: MailTemplate?) throws {
    var candidate = preferences
    candidate.set(template, id: template.id)
    let normalized = try candidate.validated()
    guard let savedTemplate = normalized.template(id: template.id) else {
      throw TemplateSyncError.invalidIdentifier
    }
    edit(template.id, value: savedTemplate, basedOn: original)
  }

  /// Deletes one template without affecting Drafts previously created from it.
  func deleteTemplate(_ templateId: String) {
    edit(templateId, value: nil)
  }

  /// Updates the Product Account session while retaining this store's Mail Profile scope.
  func updateSession(_ session: ProductAccountSessionSnapshot) {
    guard session.productAccountId != self.session.productAccountId else {
      self.session = session
      return
    }
    syncTask?.cancel()
    syncTask = nil
    sessionGeneration += 1
    synchronizingGeneration = nil
    synchronizationRequestedRevision = nil
    isSynchronizing = false
    self.session = session
    do {
      localState =
        try localStateStore.load(
          productAccountId: session.productAccountId,
          recordScope: recordScope
        ) ?? .empty
      preferences = localState.preferences
      restorationSucceeded = true
      errorMessage = nil
    } catch {
      localState = .empty
      preferences = .empty
      restorationSucceeded = false
      errorMessage = error.localizedDescription
    }
  }

  /// Cancels work when the owning Mail Profile store is replaced or signed out.
  func retire() {
    syncTask?.cancel()
    syncTask = nil
    sessionGeneration += 1
    synchronizingGeneration = nil
    synchronizationRequestedRevision = nil
    isSynchronizing = false
    restorationSucceeded = false
  }

  /// Reconciles offline edits with the latest encrypted Product Sync revision.
  func synchronize() async {
    guard restorationSucceeded else { return }
    if synchronizingGeneration != nil {
      synchronizationRequestedRevision = editRevision
      return
    }
    let generation = sessionGeneration
    let synchronizationRevision = editRevision
    let synchronizationSession = session
    synchronizingGeneration = generation
    isSynchronizing = true
    defer {
      if synchronizingGeneration == generation {
        synchronizingGeneration = nil
        isSynchronizing = false
        let shouldReschedule =
          synchronizationRequestedRevision.map { $0 > synchronizationRevision } ?? false
        synchronizationRequestedRevision = nil
        if shouldReschedule { scheduleSyncIfNeeded() }
      }
    }

    do {
      let remote =
        try await syncService.loadPreferences(session: synchronizationSession)
        ?? TemplatePreferenceSyncSnapshot(preferences: .empty, updatedAt: nil)
      guard generation == sessionGeneration else { return }
      try await synchronize(
        remote: remote,
        generation: generation,
        session: synchronizationSession
      )
    } catch is CancellationError {
    } catch {
      guard generation == sessionGeneration else { return }
      errorMessage = error.localizedDescription
      persist()
    }
  }

  private func synchronize(
    remote initialRemote: TemplatePreferenceSyncSnapshot,
    generation: Int,
    session: ProductAccountSessionSnapshot
  ) async throws {
    var remote = initialRemote
    for attempt in 1...5 {
      let merged = reconcile(with: remote.preferences)
      persist()
      guard localState.pendingChanges.isEmpty == false else {
        errorMessage = nil
        return
      }

      let savingRevision = editRevision
      switch try await syncService.savePreferences(
        merged,
        expectedUpdatedAt: remote.updatedAt,
        session: session
      ) {
      case .committed(let snapshot):
        guard generation == sessionGeneration else { return }
        _ = reconcile(with: snapshot.preferences, preservingEditsAfter: savingRevision)
        persist()
        errorMessage = nil
        return
      case .conflict(let snapshot):
        guard generation == sessionGeneration else { return }
        _ = reconcile(with: snapshot.preferences, preservingEditsAfter: savingRevision)
        persist()
        remote = snapshot
      }

      guard attempt < 5 else { throw TemplateSyncError.retryLimitExceeded }
    }
  }

  private func edit(
    _ templateId: String,
    value: MailTemplate?,
    basedOn original: MailTemplate? = nil
  ) {
    recordEdit(to: templateId)
    let baseValue =
      localState.pendingChanges[templateId]?.baseValue
      ?? original
      ?? preferences.template(id: templateId)
    localState.pendingChanges[templateId] =
      value == baseValue
      ? nil
      : TemplatePreferencePendingChange(baseValue: baseValue, localValue: value)
    preferences.set(value, id: templateId)
    localState.preferences = preferences
    if restorationSucceeded { errorMessage = nil }
    persist()
    scheduleSyncIfNeeded()
  }

  private func recordEdit(to templateId: String) {
    editRevision += 1
    entityEditRevisions[templateId] = editRevision
  }

  private func persist() {
    guard restorationSucceeded else { return }
    do {
      try localStateStore.save(
        localState,
        productAccountId: session.productAccountId,
        recordScope: recordScope
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func scheduleSyncIfNeeded() {
    guard automaticallySynchronizes, restorationSucceeded, syncTask == nil else { return }
    let scheduledRevision = editRevision
    let scheduledGeneration = sessionGeneration
    syncTask = Task { [weak self] in
      guard let self else { return }
      await synchronize()
      guard sessionGeneration == scheduledGeneration else { return }
      syncTask = nil
      if editRevision != scheduledRevision { scheduleSyncIfNeeded() }
    }
  }
}

extension TemplateStore {
  fileprivate func reconcile(
    with remotePreferences: TemplatePreferences,
    preservingEditsAfter savingRevision: Int? = nil
  ) -> TemplatePreferences {
    var merged = remotePreferences
    var presented = remotePreferences
    let templateIds = Set(
      preferences.templates.map(\.id)
        + remotePreferences.templates.map(\.id)
        + Array(localState.pendingChanges.keys)
    ).sorted()

    for templateId in templateIds {
      reconcile(
        templateId,
        remotePreferences: remotePreferences,
        preservingEditsAfter: savingRevision,
        merged: &merged,
        presented: &presented
      )
    }

    preferences = presented
    localState.preferences = presented
    return merged
  }

  private func reconcile(
    _ templateId: String,
    remotePreferences: TemplatePreferences,
    preservingEditsAfter savingRevision: Int?,
    merged: inout TemplatePreferences,
    presented: inout TemplatePreferences
  ) {
    if let savingRevision, entityEditRevisions[templateId, default: 0] > savingRevision {
      let localValue = preferences.template(id: templateId)
      let remoteValue = remotePreferences.template(id: templateId)
      localState.pendingChanges[templateId] =
        localValue == remoteValue
        ? nil
        : TemplatePreferencePendingChange(baseValue: remoteValue, localValue: localValue)
      merged.set(localValue, id: templateId)
      presented.set(localValue, id: templateId)
      return
    }
    guard let pending = localState.pendingChanges[templateId] else { return }
    let remoteValue = remotePreferences.template(id: templateId)
    if pending.baseValue == nil,
      let localValue = pending.localValue,
      remoteValue == nil,
      remotePreferences.templates.contains(where: {
        $0.id != templateId && foldedName($0.name) == foldedName(localValue.name)
      })
    {
      materializeConflictCopy(
        sourceId: templateId,
        localValue: localValue,
        remoteValue: nil,
        merged: &merged,
        presented: &presented
      )
      return
    }
    if remoteValue == pending.localValue {
      localState.pendingChanges[templateId] = nil
      presented.set(remoteValue, id: templateId)
    } else if remoteValue == pending.baseValue {
      merged.set(pending.localValue, id: templateId)
      presented.set(pending.localValue, id: templateId)
    } else {
      materializeConflictCopy(
        sourceId: templateId,
        localValue: pending.localValue,
        remoteValue: remoteValue,
        merged: &merged,
        presented: &presented
      )
    }
  }

  private func materializeConflictCopy(
    sourceId: String,
    localValue: MailTemplate?,
    remoteValue: MailTemplate?,
    merged: inout TemplatePreferences,
    presented: inout TemplatePreferences
  ) {
    localState.pendingChanges[sourceId] = nil
    presented.set(remoteValue, id: sourceId)
    guard let localValue else { return }

    let copy = conflictCopy(
      of: localValue,
      sourceId: sourceId,
      existing: presented.templates
    )
    merged.set(copy, id: copy.id)
    presented.set(copy, id: copy.id)
    localState.pendingChanges[copy.id] = TemplatePreferencePendingChange(
      baseValue: nil,
      localValue: copy
    )
  }

  private func conflictCopy(
    of template: MailTemplate,
    sourceId: String,
    existing: [MailTemplate]
  ) -> MailTemplate {
    let existingNames = Set(
      existing.map { foldedName($0.name) }
    )
    var suffix = " (Conflict)"
    var index = 2
    var name = String(template.name.prefix(max(1, 80 - suffix.count))) + suffix
    while existingNames.contains(
      foldedName(name)
    ) {
      suffix = " (Conflict \(index))"
      name = String(template.name.prefix(max(1, 80 - suffix.count))) + suffix
      index += 1
    }
    return MailTemplate(
      id: UUID().uuidString,
      name: name,
      subject: template.subject,
      document: template.document,
      conflictSourceId: sourceId
    )
  }

  private func foldedName(_ name: String) -> String {
    name.folding(
      options: .caseInsensitive,
      locale: Locale(identifier: "en_US_POSIX")
    )
  }
}
