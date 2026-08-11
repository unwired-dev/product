import Foundation

private actor MailboxConnectionProviderAccessGate {
  private typealias WaiterContinuation = CheckedContinuation<Void, Error>

  private struct Waiter {
    let continuation: WaiterContinuation
    let id: UUID
  }

  private var lockedAccounts: Set<String> = []
  private var waiters: [String: [Waiter]] = [:]

  func acquire(productAccountId: String) async throws {
    try Task.checkCancellation()
    guard lockedAccounts.contains(productAccountId) else {
      lockedAccounts.insert(productAccountId)
      return
    }
    let waiterId = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: WaiterContinuation) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        waiters[productAccountId, default: []].append(
          Waiter(continuation: continuation, id: waiterId)
        )
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterId, productAccountId: productAccountId) }
    }
  }

  private func cancelWaiter(_ waiterId: UUID, productAccountId: String) {
    guard var accountWaiters = waiters[productAccountId],
      let index = accountWaiters.firstIndex(where: { $0.id == waiterId })
    else { return }
    let waiter = accountWaiters.remove(at: index)
    waiters[productAccountId] = accountWaiters.isEmpty ? nil : accountWaiters
    waiter.continuation.resume(throwing: CancellationError())
  }

  func waiterCount(productAccountId: String) -> Int {
    waiters[productAccountId]?.count ?? 0
  }

  func release(productAccountId: String) {
    guard var accountWaiters = waiters[productAccountId], !accountWaiters.isEmpty else {
      lockedAccounts.remove(productAccountId)
      waiters[productAccountId] = nil
      return
    }
    let next = accountWaiters.removeFirst()
    waiters[productAccountId] = accountWaiters.isEmpty ? nil : accountWaiters
    next.continuation.resume()
  }
}

// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
final class MailboxConnectionSyncService: MailboxConnectionDefinitionSyncing {
  private static let providerAccessGate = MailboxConnectionProviderAccessGate()

  static func providerAccessWaiterCountForTesting(productAccountId: String) async -> Int {
    await providerAccessGate.waiterCount(productAccountId: productAccountId)
  }

  private let cleanupReceiptStore: MailboxCleanupReceiptPersisting
  private let clock: () -> Int64
  private let connectionRecord: ProductSyncSingletonHandle<MailboxConnectionSyncPayload>
  private let generationRecord: ProductSyncSingletonHandle<MailboxAuthorizationGenerationLedger>
  private let payloadCodec = MailboxConnectionSyncPayloadCodec()
  private let profileRecord: ProductSyncSingletonHandle<MailProfileSyncPayload>

  init(
    cacheStore: MailboxConnectionSyncCachePersisting =
      KeychainMailboxConnectionSyncCacheStore(),
    cleanupReceiptStore: MailboxCleanupReceiptPersisting =
      KeychainMailboxCleanupReceiptStore(),
    clock: @escaping () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()
  ) {
    self.cleanupReceiptStore = cleanupReceiptStore
    self.clock = clock
    let boundary = recordBoundary.caching(
      MailboxConnectionSyncCiphertextCache(store: cacheStore)
    )
    connectionRecord = boundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: MailboxConnectionSyncPayload.primaryIdentifier,
        cachePolicy: .refreshAfterCommit
      )
    )
    generationRecord = boundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: MailboxAuthorizationGenerationLedger.primaryIdentifier,
        cachePolicy: .authoritative
      )
    )
    profileRecord = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: MailProfileSyncPayload.primaryIdentifier,
        cachePolicy: .authoritative
      )
    )
  }

  func completedLocalCleanupGeneration(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) throws -> Int? {
    try cleanupReceiptStore.generation(
      productAccountId: session.productAccountId,
      connectionId: connectionId
    )
  }

  func recordLocalCleanup(
    _ connectionId: MailboxConnectionId,
    generation: Int,
    session: ProductAccountSessionSnapshot
  ) throws {
    try cleanupReceiptStore.record(
      generation: generation,
      productAccountId: session.productAccountId,
      connectionId: connectionId
    )
  }

  func loadSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    do {
      return try await loadAuthoritativeSnapshot(session: session)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Self.invalidatesCiphertextCache(error) {
        await connectionRecord.clearCache(session: session)
      }
      throw mapBoundaryError(error)
    }
  }

  func loadSnapshotForProviderAccess(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    try await Self.providerAccessGate.acquire(productAccountId: session.productAccountId)
    do {
      try Task.checkCancellation()
      let snapshot = try await loadSnapshotForProviderAccessWithoutGate(session: session)
      await Self.providerAccessGate.release(productAccountId: session.productAccountId)
      return snapshot
    } catch {
      await Self.providerAccessGate.release(productAccountId: session.productAccountId)
      throw error
    }
  }

  private func loadSnapshotForProviderAccessWithoutGate(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    do {
      return try await loadAuthoritativeSnapshot(session: session)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      do {
        guard let cachedRecord = try await connectionRecord.readCached(session: session) else {
          throw error
        }
        return payloadCodec.snapshot(
          cachedRecord.value,
          updatedAt: cachedRecord.revision.legacyUpdatedAt
        )
      } catch {
        throw mapBoundaryError(error)
      }
    }
  }

  private func loadAuthoritativeSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    let (record, ledgerRecord) = try await connectionRecord.readRefreshingCache(
      with: generationRecord,
      session: session,
      transform: { payload, ledger in
        payload.applyingGenerationFloors(ledger ?? .empty)
      }
    )
    let ledger = ledgerRecord?.value ?? .empty
    let payload =
      record?.value
      ?? MailboxConnectionSyncPayload.empty.applyingGenerationFloors(ledger)
    return payloadCodec.snapshot(payload, updatedAt: record?.revision.legacyUpdatedAt)
  }

  func reconcileConnections(
    _ connections: [MailboxConnectionDefinition],
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    return try await update(session: session) { payload, _ in
      var changed = false
      let activeIds = Set(payload.connections.map(\.id))
      let removedIds = Set(
        payload.removals.lazy.map(\.connectionId).filter { !activeIds.contains($0) }
      )
      var existingIds = Set(payload.connections.map(\.id))
      for connection in connections
      where !removedIds.contains(connection.id) && !existingIds.contains(connection.id) {
        payload.connections.append(connection)
        existingIds.insert(connection.id)
        changed = true
      }
      return changed
    }
  }

  // swiftlint:disable:next function_body_length
  func removeConnection(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    let current = try await loadSnapshot(session: session)
    guard
      current.connections.contains(where: { $0.id == connectionId })
        || !current.removedConnectionIds.contains(connectionId)
    else {
      if let removalGeneration = try await publishedRemovalGeneration(
        connectionId,
        session: session
      ) {
        _ = try await retainGenerationFloor(
          connectionId,
          minimumGeneration: removalGeneration,
          isCommitted: true,
          commitsOnlyMinimumGeneration: true,
          session: session
        )
      }
      return current
    }
    let currentGeneration =
      current.connections.first { $0.id == connectionId }?.authorizationGeneration ?? 0
    let generation = try await retainGenerationFloor(
      connectionId,
      minimumGeneration: currentGeneration + 1,
      isCommitted: false,
      session: session
    )
    var finalGeneration = generation
    let snapshot = try await update(session: session) { payload, storedPayload in
      let connection = payload.connections.first { $0.id == connectionId }
      let storedConnection = storedPayload.connections.first { $0.id == connectionId }
      let removal = payload.removals.first { $0.connectionId == connectionId }
      let hadConnection = connection != nil
      let hadRemoval = removal != nil
      guard hadConnection || !hadRemoval else { return false }

      let retainedGeneration = try await retainGenerationFloor(
        connectionId,
        minimumGeneration: max(
          generation,
          (storedConnection?.authorizationGeneration ?? 0) + 1
        ),
        isCommitted: false,
        session: session
      )
      finalGeneration = retainedGeneration
      payload.connections.removeAll { $0.id == connectionId }
      payload.removals.removeAll { $0.connectionId == connectionId }
      payload.removals.append(
        MailboxConnectionRemovalTombstone(
          authorizationGeneration: max(
            retainedGeneration,
            removal?.authorizationGeneration ?? retainedGeneration
          ),
          provider: connectionId.providerId.rawValue,
          providerAccountIdentifier: connectionId.providerMailboxIdentity.value,
          removedAt: clock(),
          tombstoneIdentifier: UUID().uuidString
        )
      )
      if payload.defaultSendingConnectionId == connectionId {
        payload.defaultSendingConnectionProvider = nil
        payload.defaultSendingProviderAccountIdentifier = nil
      }
      return true
    }
    _ = try await retainGenerationFloor(
      connectionId,
      minimumGeneration: finalGeneration,
      isCommitted: true,
      commitsOnlyMinimumGeneration: true,
      session: session
    )
    return snapshot
  }

  func saveConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    try await saveDefinition(connection.definition, session: session)
  }

  func saveDefinition(
    _ definition: MailboxConnectionDefinition,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    return try await update(session: session) { payload, _ in
      let existingGeneration = payload.connections.first {
        $0.id == definition.id
      }?.authorizationGeneration
      if let removal = payload.removals.first(where: { $0.connectionId == definition.id }),
        existingGeneration == nil
          || (existingGeneration ?? 0) < removal.authorizationGeneration
      {
        throw MailboxConnectionSyncError.connectionRemoved(removal.observation)
      }
      let generation = existingGeneration ?? definition.authorizationGeneration
      payload.connections.removeAll { $0.id == definition.id }
      payload.connections.append(definition.withAuthorizationGeneration(generation))
      return true
    }
  }

  func setDefaultSendingConnection(
    _ connectionId: MailboxConnectionId?,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    try await update(session: session) { payload, _ in
      if let connectionId,
        !payload.connections.contains(where: { $0.id == connectionId })
      {
        throw MailboxConnectionSyncError.invalidDefaultSendingConnection
      }
      guard payload.defaultSendingConnectionId != connectionId else { return false }
      payload.defaultSendingConnectionProvider = connectionId?.providerId.rawValue
      payload.defaultSendingProviderAccountIdentifier =
        connectionId?.providerMailboxIdentity.value
      return true
    }
  }

  private func update(
    session: ProductAccountSessionSnapshot,
    mutation:
      (inout MailboxConnectionSyncPayload, MailboxConnectionSyncPayload) async throws -> Bool
  ) async throws -> MailboxConnectionSyncSnapshot {
    do {
      var resolvedPayload = MailboxConnectionSyncPayload.empty
      let record = try await connectionRecord.update(session: session) { currentRecord in
        let storedPayload = currentRecord?.value ?? .empty
        let ledger = try await self.generationRecord.read(session: session)?.value ?? .empty
        var payload = storedPayload.applyingGenerationFloors(ledger)
        let changed: Bool
        do {
          changed = try await mutation(&payload, storedPayload)
        } catch {
          if let currentRecord {
            await self.connectionRecord.refreshCache(
              ProductSyncRecord(revision: currentRecord.revision, value: payload),
              session: session
            )
          }
          throw error
        }
        if changed {
          payload.sort()
          resolvedPayload = payload
          return .write(payload)
        }
        resolvedPayload = payload
        return .acceptAuthoritative
      }
      if let record {
        await connectionRecord.refreshCache(
          ProductSyncRecord(revision: record.revision, value: resolvedPayload),
          session: session
        )
      }
      return payloadCodec.snapshot(
        resolvedPayload,
        updatedAt: record?.revision.legacyUpdatedAt
      )
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func publishedRemovalGeneration(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> Int? {
    let payload: MailboxConnectionSyncPayload
    do {
      payload = try await connectionRecord.read(session: session)?.value ?? .empty
    } catch {
      throw mapBoundaryError(error)
    }
    guard !payload.connections.contains(where: { $0.id == connectionId }) else {
      return nil
    }
    return payload.removals.first {
      $0.connectionId == connectionId
    }?.authorizationGeneration
  }

  private func retainGenerationFloor(
    _ connectionId: MailboxConnectionId,
    minimumGeneration: Int,
    isCommitted: Bool = true,
    commitsOnlyMinimumGeneration: Bool = false,
    session: ProductAccountSessionSnapshot
  ) async throws -> Int {
    do {
      var retainedGeneration = minimumGeneration
      _ = try await generationRecord.update(session: session) { currentRecord in
        var ledger = currentRecord?.value ?? .empty
        let existingFloor = ledger.floors.first { $0.connectionId == connectionId }
        let generation = max(
          minimumGeneration,
          existingFloor?.authorizationGeneration ?? 0
        )
        retainedGeneration = generation
        let commitsRetainedGeneration =
          isCommitted
          && (!commitsOnlyMinimumGeneration || generation == minimumGeneration)
        let committedGeneration =
          if commitsRetainedGeneration {
            max(
              minimumGeneration,
              existingFloor?.committedAuthorizationGeneration ?? 0
            )
          } else {
            existingFloor?.committedAuthorizationGeneration
          }
        ledger.floors.removeAll { $0.connectionId == connectionId }
        ledger.floors.append(
          MailboxAuthorizationGenerationFloor(
            authorizationGeneration: generation,
            committedAuthorizationGeneration: committedGeneration,
            provider: connectionId.providerId.rawValue,
            providerAccountIdentifier: connectionId.providerMailboxIdentity.value
          )
        )
        ledger.sort()
        return .write(ledger)
      }
      return retainedGeneration
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func mapBoundaryError(_ error: Error) -> Error {
    guard let boundaryError = error as? ProductSyncRecordBoundaryError else { return error }
    switch boundaryError {
    case .missingProductSyncKeyMaterial:
      return MailboxConnectionSyncError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      return MailboxConnectionSyncError.concurrentModification
    case .incompletePagination, .invalidPayloadIdentifier:
      return error
    }
  }

  private static func invalidatesCiphertextCache(_ error: Error) -> Bool {
    if error is ProductSyncEncryptionError || error is DecodingError {
      return true
    }
    return error as? ProductSyncRecordBoundaryError == .missingProductSyncKeyMaterial
  }
}

extension MailboxConnectionSyncService {
  func recreateDefinition(
    _ definition: MailboxConnectionDefinition,
    after removalObservation: MailboxConnectionRemovalObservation?,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    try await update(session: session) { payload, _ in
      if payload.connections.contains(where: { $0.id == definition.id }) {
        guard removalObservation?.connectionId != definition.id else {
          throw MailboxConnectionSyncError.concurrentModification
        }
        return false
      }
      guard let removal = payload.removals.first(where: { $0.connectionId == definition.id })
      else {
        guard removalObservation?.connectionId != definition.id else {
          throw MailboxConnectionSyncError.concurrentModification
        }
        let generation =
          payload.connections.first(where: { $0.id == definition.id })?
          .authorizationGeneration
          ?? definition.authorizationGeneration
        payload.connections.removeAll { $0.id == definition.id }
        payload.connections.append(definition.withAuthorizationGeneration(generation))
        return true
      }
      guard removal.observation == removalObservation else {
        throw MailboxConnectionSyncError.connectionRemoved(removal.observation)
      }
      let generation = try await retainGenerationFloor(
        definition.id,
        minimumGeneration: max(
          definition.authorizationGeneration,
          removal.authorizationGeneration
        ),
        session: session
      )
      payload.connections.removeAll { $0.id == definition.id }
      payload.connections.append(definition.withAuthorizationGeneration(generation))
      return true
    }
  }
}

extension MailboxConnectionSyncService {
  func loadProfileSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    let connectionSnapshot = try await loadSnapshot(session: session)
    return try await loadProfileSnapshot(
      activeConnectionIds: connectionSnapshot.connections.map(\.id),
      session: session
    )
  }

  func loadConnections(
    in profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnectionDefinition] {
    let connectionSnapshot = try await loadSnapshot(session: session)
    let profileSnapshot = try await loadProfileSnapshot(
      activeConnectionIds: connectionSnapshot.connections.map(\.id),
      session: session
    )
    return try profileSnapshot.connections(
      in: profileId,
      from: connectionSnapshot.connections
    )
  }

  func createProfile(
    name: String,
    appearance: MailProfileAppearance,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    let connectionSnapshot = try await loadSnapshot(session: session)
    let profileId = MailProfileId(rawValue: UUID().uuidString.lowercased())
    return try await updateProfiles(session: session) { payload in
      _ = payload.migrateLegacyProductAccount(
        productAccountId: session.productAccountId,
        activeConnectionIds: connectionSnapshot.connections.map(\.id)
      )
      let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalizedName.isEmpty else {
        throw MailProfileSyncError.invalidProfileState
      }
      guard
        !payload.profiles.contains(where: {
          $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        })
      else {
        throw MailProfileSyncError.concurrentModification
      }
      payload.profiles.append(
        MailProfileDefinition(
          id: profileId,
          appearance: appearance,
          name: normalizedName,
          recordScope: .profile(profileId),
          quietState: .inactive
        )
      )
      return true
    }
  }

  func saveProfile(
    _ profile: MailProfileDefinition,
    basedOn base: MailProfileDefinition,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    guard profile.id == base.id, profile.recordScope == base.recordScope else {
      throw MailProfileSyncError.invalidProfileState
    }
    return try await updateProfiles(session: session) { payload in
      guard let index = payload.profiles.firstIndex(where: { $0.id == profile.id }) else {
        throw MailProfileSyncError.profileNotFound
      }
      let synchronized = payload.profiles[index]
      var merged = synchronized
      var changed = false
      for field in MailProfileEditableField.allCases {
        let baseValue = base.value(for: field)
        let competingValue = profile.value(for: field)
        guard competingValue != baseValue else { continue }
        let synchronizedValue = synchronized.value(for: field)
        if synchronizedValue == baseValue || synchronizedValue == competingValue {
          if synchronizedValue != competingValue {
            merged.set(competingValue, for: field)
            changed = true
          }
        } else if !payload.conflicts.contains(where: {
          $0.profileId == profile.id && $0.field == field
            && $0.competingValue == competingValue
            && $0.synchronizedValue == synchronizedValue
        }) {
          payload.conflicts.append(
            MailProfileConflictCopy(
              baseValue: baseValue,
              competingValue: competingValue,
              field: field,
              id: UUID().uuidString.lowercased(),
              profileId: profile.id,
              synchronizedValue: synchronizedValue
            )
          )
          changed = true
        }
      }
      if merged != synchronized {
        payload.profiles[index] = merged
        changed = true
      }
      return changed
    }
  }

  func resolveProfileConflict(
    _ conflictId: String,
    useCompetingValue: Bool,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    try await updateProfiles(session: session) { payload in
      guard let conflictIndex = payload.conflicts.firstIndex(where: { $0.id == conflictId }) else {
        throw MailProfileSyncError.concurrentModification
      }
      let conflict = payload.conflicts.remove(at: conflictIndex)
      guard
        let profileIndex = payload.profiles.firstIndex(where: {
          $0.id == conflict.profileId
        })
      else {
        throw MailProfileSyncError.profileNotFound
      }
      if useCompetingValue {
        guard
          payload.profiles[profileIndex].value(for: conflict.field)
            == conflict.synchronizedValue
        else {
          throw MailProfileSyncError.concurrentModification
        }
        payload.profiles[profileIndex].set(conflict.competingValue, for: conflict.field)
      }
      return true
    }
  }

  private func loadProfileSnapshot(
    activeConnectionIds: [MailboxConnectionId],
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    try await updateProfiles(session: session) { payload in
      payload.migrateLegacyProductAccount(
        productAccountId: session.productAccountId,
        activeConnectionIds: activeConnectionIds
      )
    }
  }

  private func updateProfiles(
    session: ProductAccountSessionSnapshot,
    mutation: (inout MailProfileSyncPayload) async throws -> Bool
  ) async throws -> MailProfileSyncSnapshot {
    do {
      var resolvedPayload = MailProfileSyncPayload.empty
      let record = try await profileRecord.update(session: session) { currentRecord in
        var payload = currentRecord?.value ?? .empty
        let changed = try await mutation(&payload)
        try Self.validateProfilePayload(payload)
        payload.sort()
        resolvedPayload = payload
        return changed ? .write(payload) : .acceptAuthoritative
      }
      guard let defaultProfileId = resolvedPayload.defaultProfileId else {
        throw MailProfileSyncError.invalidProfileState
      }
      return MailProfileSyncSnapshot(
        assignments: Dictionary(
          resolvedPayload.assignments.map { ($0.connectionId, $0.profileId) },
          uniquingKeysWith: { first, _ in first }
        ),
        conflicts: resolvedPayload.conflicts,
        defaultProfileId: defaultProfileId,
        profiles: resolvedPayload.profiles,
        updatedAt: record?.revision.legacyUpdatedAt
      )
    } catch {
      throw mapProfileBoundaryError(error)
    }
  }

  private static func validateProfilePayload(_ payload: MailProfileSyncPayload) throws {
    guard
      let defaultProfileId = payload.defaultProfileId,
      payload.profiles.contains(where: { $0.id == defaultProfileId })
    else {
      throw MailProfileSyncError.invalidProfileState
    }
    let profileIds = payload.profiles.map(\.id)
    guard Set(profileIds).count == profileIds.count else {
      throw MailProfileSyncError.invalidProfileState
    }
    let names = payload.profiles.map {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    guard
      Set(names).count == names.count,
      zip(payload.profiles, names).allSatisfy({ profile, normalizedName in
        profile.name == profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
          && (1...40).contains(normalizedName.count)
          && !profile.appearance.colorName.isEmpty
          && !profile.appearance.symbolName.isEmpty
          && (profile.quietState.isQuiet || profile.quietState.quietUntil == nil)
      })
    else {
      throw MailProfileSyncError.invalidProfileState
    }
    let connectionIds = payload.assignments.map(\.connectionId)
    guard Set(connectionIds).count == connectionIds.count else {
      throw MailProfileSyncError.invalidProfileState
    }
    guard payload.assignments.allSatisfy({ profileIds.contains($0.profileId) }) else {
      throw MailProfileSyncError.invalidProfileState
    }
  }

  private func mapProfileBoundaryError(_ error: Error) -> Error {
    if error is MailProfileSyncError { return error }
    guard let boundaryError = error as? ProductSyncRecordBoundaryError else { return error }
    switch boundaryError {
    case .missingProductSyncKeyMaterial:
      return MailProfileSyncError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      return MailProfileSyncError.concurrentModification
    case .incompletePagination, .invalidPayloadIdentifier:
      return error
    }
  }
}

extension MailProfileDefinition {
  fileprivate func value(for field: MailProfileEditableField) -> MailProfileFieldValue {
    switch field {
    case .appearance:
      return .appearance(appearance)
    case .name:
      return .name(name)
    case .quietState:
      return .quietState(quietState)
    }
  }

  fileprivate mutating func set(_ value: MailProfileFieldValue, for field: MailProfileEditableField)
  {
    switch (field, value) {
    case (.appearance, .appearance(let appearance)):
      self.appearance = appearance
    case (.name, .name(let name)):
      self.name = name
    case (.quietState, .quietState(let quietState)):
      self.quietState = quietState
    default:
      break
    }
  }
}
