import Foundation
import Observation

// swiftlint:disable file_length

struct SignaturePreferencePendingChange: Codable, Equatable, Sendable {
  let baseValue: SignaturePreferenceValue
  var localValue: SignaturePreferenceValue
}

struct SignaturePreferenceConflict: Codable, Equatable, Identifiable, Sendable {
  let field: SignaturePreferenceField
  let localValue: SignaturePreferenceValue
  let remoteValue: SignaturePreferenceValue

  var id: SignaturePreferenceField { field }
}

struct SignaturePreferenceLocalState: Codable, Equatable, Sendable {
  var conflicts: [SignaturePreferenceField: SignaturePreferenceConflict]
  var pendingChanges: [SignaturePreferenceField: SignaturePreferencePendingChange]
  var preferences: SignaturePreferences

  static let empty = SignaturePreferenceLocalState(
    conflicts: [:],
    pendingChanges: [:],
    preferences: .empty
  )
}

protocol SignaturePreferenceLocalStatePersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> SignaturePreferenceLocalState?
  func save(_ state: SignaturePreferenceLocalState, productAccountId: String) throws
}

struct KeychainSignatureStateStore: SignaturePreferenceLocalStatePersisting {
  private static let service = "dev.unwired.mail.signature-preferences"

  func clear(productAccountId: String) throws {
    try KeychainStore.delete(service: Self.service, account: productAccountId)
  }

  func load(productAccountId: String) throws -> SignaturePreferenceLocalState? {
    guard
      let encoded = try KeychainStore.readString(
        service: Self.service,
        account: productAccountId
      ),
      let data = encoded.data(using: .utf8)
    else { return nil }
    do {
      return try JSONDecoder().decode(SignaturePreferenceLocalState.self, from: data)
    } catch {
      try KeychainStore.delete(service: Self.service, account: productAccountId)
      return nil
    }
  }

  func save(_ state: SignaturePreferenceLocalState, productAccountId: String) throws {
    let data = try JSONEncoder().encode(state)
    guard let encoded = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(encoded, service: Self.service, account: productAccountId)
  }
}

@MainActor
@Observable
final class SignatureStore {
  private(set) var errorMessage: String?
  private(set) var isSynchronizing = false
  private(set) var preferences: SignaturePreferences
  private let automaticallySynchronizes: Bool
  private var editRevision = 0
  private var fieldEditRevisions: [SignaturePreferenceField: Int] = [:]
  private var localState: SignaturePreferenceLocalState
  private let localStateStore: SignaturePreferenceLocalStatePersisting
  private var restorationSucceeded = true
  private var session: ProductAccountSessionSnapshot
  private var sessionGeneration = 0
  private var synchronizingGeneration: Int?
  private let syncService: SignaturePreferenceSyncing
  private var syncTask: Task<Void, Never>?

  var conflicts: [SignaturePreferenceConflict] {
    localState.conflicts.values.sorted { $0.field.rawValue < $1.field.rawValue }
  }

  var hasPendingChanges: Bool {
    !localState.pendingChanges.isEmpty
  }

  init(
    session: ProductAccountSessionSnapshot,
    syncService: SignaturePreferenceSyncing = SignatureSyncService(),
    localStateStore: SignaturePreferenceLocalStatePersisting =
      KeychainSignatureStateStore(),
    automaticallySynchronizes: Bool = true
  ) {
    self.session = session
    self.syncService = syncService
    self.localStateStore = localStateStore
    self.automaticallySynchronizes = automaticallySynchronizes
    do {
      let restored = try localStateStore.load(productAccountId: session.productAccountId) ?? .empty
      localState = restored
      preferences = restored.preferences
    } catch {
      localState = .empty
      preferences = .empty
      restorationSucceeded = false
      errorMessage = error.localizedDescription
    }
  }

  func saveSignature(_ signature: MailSignature) throws {
    var candidate = preferences
    candidate.set(.signature(signature), for: .signature(signature.id))
    let normalized = try candidate.validated()
    guard let signature = normalized.signatures.first(where: { $0.id == signature.id }) else {
      throw SignatureSyncError.emptyBody
    }
    edit(.signature(signature.id), value: .signature(signature))
  }

  func deleteSignature(_ signatureId: String) {
    edit(.signature(signatureId), value: .signature(nil))
    for (connectionId, assignment) in preferences.assignments {
      if assignment.newMessageSignatureId == signatureId {
        edit(.newMessage(connectionId), value: .identifier(nil))
      }
      if assignment.replyOrForwardSignatureId == signatureId {
        edit(.replyOrForward(connectionId), value: .identifier(nil))
      }
    }
  }

  func setDefault(
    _ signatureId: String?,
    connectionId: MailboxConnectionId,
    context: SignatureComposeContext
  ) {
    let field =
      context == .newMessage
      ? SignaturePreferenceField.newMessage(connectionId.rawValue)
      : SignaturePreferenceField.replyOrForward(connectionId.rawValue)
    edit(field, value: .identifier(signatureId))
  }

  func resolveConflict(_ field: SignaturePreferenceField, useLocalValue: Bool) {
    guard let conflict = localState.conflicts.removeValue(forKey: field) else { return }
    recordEdit(to: field)
    let selectedValue = useLocalValue ? conflict.localValue : conflict.remoteValue
    preferences.set(selectedValue, for: field)
    localState.preferences = preferences
    if useLocalValue, conflict.localValue != conflict.remoteValue {
      localState.pendingChanges[field] = SignaturePreferencePendingChange(
        baseValue: conflict.remoteValue,
        localValue: conflict.localValue
      )
    } else {
      localState.pendingChanges[field] = nil
    }
    persist()
    scheduleSyncIfNeeded()
  }

  func updateSession(_ session: ProductAccountSessionSnapshot) {
    guard session.productAccountId != self.session.productAccountId else {
      self.session = session
      return
    }
    syncTask?.cancel()
    syncTask = nil
    sessionGeneration += 1
    synchronizingGeneration = nil
    isSynchronizing = false
    self.session = session
    do {
      localState = try localStateStore.load(productAccountId: session.productAccountId) ?? .empty
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

  func retire() {
    syncTask?.cancel()
    syncTask = nil
    sessionGeneration += 1
    synchronizingGeneration = nil
    isSynchronizing = false
    restorationSucceeded = false
  }

  func synchronize() async {
    guard restorationSucceeded, synchronizingGeneration == nil else { return }
    let generation = sessionGeneration
    let synchronizationSession = session
    synchronizingGeneration = generation
    isSynchronizing = true
    defer {
      if synchronizingGeneration == generation {
        synchronizingGeneration = nil
        isSynchronizing = false
      }
    }

    do {
      let remote =
        try await syncService.loadPreferences(session: synchronizationSession)
        ?? SignaturePreferenceSyncSnapshot(preferences: .empty, updatedAt: nil)
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
    remote initialRemote: SignaturePreferenceSyncSnapshot,
    generation: Int,
    session: ProductAccountSessionSnapshot
  ) async throws {
    var remote = initialRemote
    for attempt in 1...5 {
      let merged = reconcile(with: remote.preferences)
      persist()
      guard !localState.pendingChanges.isEmpty else {
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

      guard attempt < 5 else { throw SignatureSyncError.retryLimitExceeded }
    }
  }

  private func edit(_ field: SignaturePreferenceField, value: SignaturePreferenceValue) {
    recordEdit(to: field)
    let baseValue =
      localState.pendingChanges[field]?.baseValue
      ?? localState.conflicts[field]?.remoteValue
      ?? preferences.value(for: field)
    localState.conflicts[field] = nil
    localState.pendingChanges[field] =
      value == baseValue
      ? nil
      : SignaturePreferencePendingChange(baseValue: baseValue, localValue: value)
    preferences.set(value, for: field)
    localState.preferences = preferences
    if restorationSucceeded { errorMessage = nil }
    persist()
    scheduleSyncIfNeeded()
  }

  private func recordEdit(to field: SignaturePreferenceField) {
    editRevision += 1
    fieldEditRevisions[field] = editRevision
  }

  private func persist() {
    guard restorationSucceeded else { return }
    do {
      try localStateStore.save(localState, productAccountId: session.productAccountId)
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

extension SignatureStore {
  fileprivate func reconcile(
    with remotePreferences: SignaturePreferences,
    preservingEditsAfter savingRevision: Int? = nil
  ) -> SignaturePreferences {
    var merged = remotePreferences
    var presented = remotePreferences
    let fields = preferenceFields(remote: remotePreferences)

    for field in fields {
      if let savingRevision, fieldEditRevisions[field, default: 0] > savingRevision {
        let localValue = preferences.value(for: field)
        let remoteValue = remotePreferences.value(for: field)
        localState.conflicts[field] = nil
        localState.pendingChanges[field] =
          localValue == remoteValue
          ? nil
          : SignaturePreferencePendingChange(baseValue: remoteValue, localValue: localValue)
        merged.set(localValue, for: field)
        presented.set(localValue, for: field)
        continue
      }
      if let conflict = localState.conflicts[field] {
        presented.set(conflict.localValue, for: field)
        continue
      }
      guard let pending = localState.pendingChanges[field] else { continue }
      let remoteValue = remotePreferences.value(for: field)
      if remoteValue == pending.localValue {
        localState.pendingChanges[field] = nil
        presented.set(remoteValue, for: field)
      } else if remoteValue == pending.baseValue {
        merged.set(pending.localValue, for: field)
        presented.set(pending.localValue, for: field)
      } else if case .signature = field.kind {
        materializeConflictCopy(
          field: field,
          localValue: pending.localValue,
          remoteValue: remoteValue,
          merged: &merged,
          presented: &presented
        )
      } else {
        localState.pendingChanges[field] = nil
        localState.conflicts[field] = SignaturePreferenceConflict(
          field: field,
          localValue: pending.localValue,
          remoteValue: remoteValue
        )
        presented.set(pending.localValue, for: field)
      }
    }

    preferences = presented
    localState.preferences = presented
    return merged
  }

  private func preferenceFields(remote: SignaturePreferences) -> [SignaturePreferenceField] {
    var fields = Set(localState.pendingChanges.keys)
    fields.formUnion(localState.conflicts.keys)
    for signature in preferences.signatures + remote.signatures {
      fields.insert(.signature(signature.id))
    }
    for connectionId in Set(preferences.assignments.keys).union(remote.assignments.keys) {
      fields.insert(.newMessage(connectionId))
      fields.insert(.replyOrForward(connectionId))
    }
    return fields.sorted { $0.rawValue < $1.rawValue }
  }

  private func materializeConflictCopy(
    field: SignaturePreferenceField,
    localValue: SignaturePreferenceValue,
    remoteValue: SignaturePreferenceValue,
    merged: inout SignaturePreferences,
    presented: inout SignaturePreferences
  ) {
    localState.pendingChanges[field] = nil
    presented.set(remoteValue, for: field)
    guard case .signature(let localSignature) = localValue, var localSignature else { return }

    let sourceId: String
    switch field.kind {
    case .signature(let id):
      sourceId = id
    default:
      return
    }
    localSignature = conflictCopy(
      of: localSignature,
      sourceId: sourceId,
      existing: presented.signatures
    )
    let copyField = SignaturePreferenceField.signature(localSignature.id)
    let copyValue = SignaturePreferenceValue.signature(localSignature)
    merged.set(copyValue, for: copyField)
    presented.set(copyValue, for: copyField)
    localState.pendingChanges[copyField] = SignaturePreferencePendingChange(
      baseValue: .signature(nil),
      localValue: copyValue
    )
  }

  private func conflictCopy(
    of signature: MailSignature,
    sourceId: String,
    existing: [MailSignature]
  ) -> MailSignature {
    let existingNames = Set(
      existing.map { $0.name.folding(options: .caseInsensitive, locale: .current) }
    )
    var suffix = " (Conflict)"
    var index = 2
    var name = String(signature.name.prefix(max(1, 80 - suffix.count))) + suffix
    while existingNames.contains(name.folding(options: .caseInsensitive, locale: .current)) {
      suffix = " (Conflict \(index))"
      name = String(signature.name.prefix(max(1, 80 - suffix.count))) + suffix
      index += 1
    }
    return MailSignature(
      id: UUID().uuidString,
      name: name,
      document: signature.document,
      conflictSourceId: sourceId
    )
  }
}
