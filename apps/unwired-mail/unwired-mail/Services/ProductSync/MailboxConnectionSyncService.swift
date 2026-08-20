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
  private let profileRecordBoundary: ProductSyncRecordBoundary
  private let productSyncKeyRotationReconciler: ProductSyncKeyRotationReconciling

  init(
    cacheStore: MailboxConnectionSyncCachePersisting =
      KeychainMailboxConnectionSyncCacheStore(),
    cleanupReceiptStore: MailboxCleanupReceiptPersisting =
      KeychainMailboxCleanupReceiptStore(),
    clock: @escaping () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary(),
    productSyncKeyRotationReconciler: ProductSyncKeyRotationReconciling =
      ConvexProductAccountService()
  ) {
    self.cleanupReceiptStore = cleanupReceiptStore
    self.clock = clock
    profileRecordBoundary = recordBoundary
    self.productSyncKeyRotationReconciler = productSyncKeyRotationReconciler
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
        try? await connectionRecord.clearCache(session: session)
      }
      throw mapBoundaryError(error)
    }
  }

  func loadCachedSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot? {
    guard let record = try await connectionRecord.readCached(session: session) else {
      return nil
    }
    return payloadCodec.snapshot(
      record.value,
      updatedAt: record.revision.legacyUpdatedAt
    )
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
      removedConnectionIds: connectionSnapshot.removedConnectionIds,
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
      removedConnectionIds: connectionSnapshot.removedConnectionIds,
      session: session
    )
    return try profileSnapshot.connections(
      in: profileId,
      from: connectionSnapshot.connections
    )
  }

  func createProfile(
    id requestedId: MailProfileId? = nil,
    name: String,
    appearance: MailProfileAppearance,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    let connectionSnapshot = try await loadSnapshot(session: session)
    let profileId = requestedId ?? MailProfileId(rawValue: UUID().uuidString.lowercased())
    return try await updateProfiles(session: session) { payload in
      _ = payload.migrateLegacyProductAccount(
        productAccountId: session.productAccountId,
        activeConnectionIds: connectionSnapshot.connections.map(\.id),
        removedConnectionIds: connectionSnapshot.removedConnectionIds
      )
      let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard (1...40).contains(normalizedName.count) else {
        throw MailProfileSyncError.invalidProfileName
      }
      if let existing = payload.profiles.first(where: { $0.id == profileId }) {
        guard existing.recordScope == .profile(profileId) else {
          throw MailProfileSyncError.invalidLifecycleReview
        }
        return false
      }
      guard
        !payload.profiles.contains(where: {
          $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        })
      else {
        throw MailProfileSyncError.invalidProfileName
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

  // The reviewed record scan and atomic commit stay together so copied state cannot drift.
  // swiftlint:disable:next function_body_length
  func duplicateProfile(
    from review: MailProfileDuplicationReview,
    name: String,
    appearance: MailProfileAppearance,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    _ = try await loadProfileSnapshot(session: session)
    do {
      guard let current = try await profileRecord.readAuthoritative(session: session) else {
        throw MailProfileSyncError.invalidProfileState
      }
      let duplicateId = MailProfileId.duplication(
        productAccountId: session.productAccountId,
        reviewId: review.id
      )
      if current.value.profiles.contains(where: { $0.id == duplicateId }) {
        return try Self.profileSnapshot(current.value, revision: current.revision)
      }
      guard
        current.revision.legacyUpdatedAt == review.expectedProfileUpdatedAt,
        let source = current.value.profiles.first(where: { $0.id == review.sourceProfileId }),
        !review.id.isEmpty
      else {
        throw MailProfileSyncError.invalidLifecycleReview
      }
      let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      try Self.validateNewProfileName(normalizedName, in: current.value)
      var updated = current.value
      updated.profiles.append(
        MailProfileDefinition(
          id: duplicateId,
          appearance: appearance,
          name: normalizedName,
          recordScope: .profile(duplicateId),
          quietState: .inactive
        )
      )
      updated.sort()
      try Self.validateProfilePayload(updated)

      let sourcePrefix = source.recordScope.productSyncIdentifier("")
      let destinationScope = MailProfileRecordScope.profile(duplicateId)
      let sourcePayloads = try await profileRecordBoundary.listEncryptedPayloads(
        session: session,
        identifierPrefix: sourcePrefix
      ).filter { payload in
        let relativeIdentifier = String(payload.payloadIdentifier.dropFirst(sourcePrefix.count))
        return Self.configurationKind(for: relativeIdentifier).map(
          review.configuration.contains
        ) == true
      }
      guard sourcePayloads.count * 2 + 1 <= 100 else {
        throw MailProfileSyncError.transactionTooLarge
      }
      _ = try await productSyncKeyRotationReconciler.reconcileProductSyncKeyRotation(
        identityToken: session.identityToken,
        productAccountId: session.productAccountId,
        trustedDeviceId: session.trustedDeviceId
      )
      var writes = try sourcePayloads.map { payload in
        let relativeIdentifier = String(payload.payloadIdentifier.dropFirst(sourcePrefix.count))
        let destinationIdentifier = destinationScope.productSyncIdentifier(relativeIdentifier)
        return ProductSyncAtomicWrite(
          encryptedPayload: try profileRecordBoundary.reencryptedPayload(
            payload,
            as: destinationIdentifier,
            session: session
          ),
          expectedUpdatedAt: nil,
          payloadIdentifier: destinationIdentifier
        )
      }
      writes.append(
        ProductSyncAtomicWrite(
          encryptedPayload: try profileRecordBoundary.encryptedPayload(
            for: updated,
            identifier: MailProfileSyncPayload.primaryIdentifier,
            session: session
          ),
          expectedUpdatedAt: current.revision.legacyUpdatedAt,
          payloadIdentifier: MailProfileSyncPayload.primaryIdentifier
        )
      )
      try Task.checkCancellation()
      let result = try await profileRecordBoundary.putEncryptedPayloadsAtomically(
        session: session,
        writes: writes,
        deletes: [],
        checks: sourcePayloads.map {
          ProductSyncAtomicCheck(
            expectedUpdatedAt: $0.updatedAt,
            payloadIdentifier: $0.payloadIdentifier
          )
        }
      )
      guard result.committed,
        let profilePayload = result.payloads.first(where: {
          $0.payloadIdentifier == MailProfileSyncPayload.primaryIdentifier
        })
      else {
        throw MailProfileSyncError.concurrentModification
      }
      let written = try profileRecord.decode(profilePayload, session: session)
      return try Self.profileSnapshot(written.value, revision: written.revision)
    } catch {
      throw mapProfileBoundaryError(error)
    }
  }

  // Transfer validates every ownership and category-copy invariant before one atomic commit.
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func transferConnection(
    _ review: MailProfileConnectionTransferReview,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    let connectionSnapshot = try await loadSnapshot(session: session)
    _ = try await loadProfileSnapshot(
      activeConnectionIds: connectionSnapshot.connections.map(\.id),
      removedConnectionIds: connectionSnapshot.removedConnectionIds,
      session: session
    )
    do {
      guard connectionSnapshot.connections.contains(where: { $0.id == review.connectionId }) else {
        throw MailProfileSyncError.invalidLifecycleReview
      }
      guard let current = try await profileRecord.readAuthoritative(session: session) else {
        throw MailProfileSyncError.invalidProfileState
      }
      guard
        let source = current.value.profiles.first(where: { $0.id == review.sourceProfileId }),
        let destination = current.value.profiles.first(where: {
          $0.id == review.destinationProfileId
        }),
        source.id != destination.id
      else {
        throw MailProfileSyncError.invalidLifecycleReview
      }
      guard
        current.revision.legacyUpdatedAt == review.expectedProfileUpdatedAt,
        let assignmentIndex = current.value.assignments.firstIndex(where: {
          $0.connectionId == review.connectionId
        }),
        [source.id, destination.id].contains(current.value.assignments[assignmentIndex].profileId),
        let connectionUpdatedAt = connectionSnapshot.updatedAt
      else {
        throw MailProfileSyncError.concurrentModification
      }
      let sourceIdentifiers = review.customCategoryCopies.map {
        CustomCategorySyncService.collectionPayloadIdentifier(
          $0.sourceCategoryId,
          recordScope: source.recordScope
        )
      }
      guard Set(sourceIdentifiers).count == sourceIdentifiers.count else {
        throw MailProfileSyncError.invalidLifecycleReview
      }
      let sourceCategories = try await profileRecordBoundary.readEncryptedPayloads(
        session: session,
        identifiers: sourceIdentifiers
      )
      guard sourceCategories.count == sourceIdentifiers.count else {
        throw MailProfileSyncError.invalidLifecycleReview
      }
      var updated = current.value
      updated.assignments[assignmentIndex].profileId = destination.id
      updated.sort()
      try Self.validateProfilePayload(updated)
      _ = try await productSyncKeyRotationReconciler.reconcileProductSyncKeyRotation(
        identityToken: session.identityToken,
        productAccountId: session.productAccountId,
        trustedDeviceId: session.trustedDeviceId
      )
      let orderedSourceCategories = try sourceIdentifiers.map { sourceIdentifier in
        guard
          let sourcePayload = sourceCategories.first(where: {
            $0.payloadIdentifier == sourceIdentifier
          })
        else {
          throw MailProfileSyncError.invalidLifecycleReview
        }
        return sourcePayload
      }
      var writes =
        if review.customCategoryCopies.isEmpty {
          [ProductSyncAtomicWrite]()
        } else {
          try await CustomCategorySyncService(
            recordScope: destination.recordScope,
            recordBoundary: profileRecordBoundary
          ).categoryCopyWrites(
            reviews: review.customCategoryCopies,
            sourcePayloads: orderedSourceCategories,
            session: session
          )
        }
      guard Set(writes.map(\.payloadIdentifier)).count == writes.count else {
        throw MailProfileSyncError.invalidLifecycleReview
      }
      guard review.customCategoryCopies.count * 2 + 3 <= 100 else {
        throw MailProfileSyncError.transactionTooLarge
      }
      writes.append(
        ProductSyncAtomicWrite(
          encryptedPayload: try profileRecordBoundary.encryptedPayload(
            for: updated,
            identifier: MailProfileSyncPayload.primaryIdentifier,
            session: session
          ),
          expectedUpdatedAt: current.revision.legacyUpdatedAt,
          payloadIdentifier: MailProfileSyncPayload.primaryIdentifier
        )
      )
      try Task.checkCancellation()
      let result = try await profileRecordBoundary.putEncryptedPayloadsAtomically(
        session: session,
        writes: writes,
        deletes: [],
        checks: sourceCategories.map {
          ProductSyncAtomicCheck(
            expectedUpdatedAt: $0.updatedAt,
            payloadIdentifier: $0.payloadIdentifier
          )
        } + [
          ProductSyncAtomicCheck(
            expectedUpdatedAt: connectionUpdatedAt,
            payloadIdentifier: MailboxConnectionSyncPayload.primaryIdentifier
          )
        ]
      )
      guard result.committed,
        let profilePayload = result.payloads.first(where: {
          $0.payloadIdentifier == MailProfileSyncPayload.primaryIdentifier
        })
      else {
        throw MailProfileSyncError.concurrentModification
      }
      let written = try profileRecord.decode(profilePayload, session: session)
      return try Self.profileSnapshot(written.value, revision: written.revision)
    } catch {
      throw mapProfileBoundaryError(error)
    }
  }

  // Deletion intentionally couples readiness, scoped cleanup, and the Profile removal write.
  // swiftlint:disable:next function_body_length
  func deleteProfile(
    _ review: MailProfileDeletionReview,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    _ = try await loadProfileSnapshot(session: session)
    do {
      guard let current = try await profileRecord.readAuthoritative(session: session) else {
        throw MailProfileSyncError.invalidProfileState
      }
      guard
        current.revision.legacyUpdatedAt == review.expectedProfileUpdatedAt,
        let profile = current.value.profiles.first(where: { $0.id == review.profileId })
      else {
        throw MailProfileSyncError.invalidLifecycleReview
      }
      guard current.value.profiles.count > 1 else {
        throw MailProfileSyncError.finalProfileCannotBeDeleted
      }
      guard
        review.isReady,
        !current.value.assignments.contains(where: { $0.profileId == profile.id })
      else {
        throw MailProfileSyncError.profileHasUnresolvedState
      }
      var updated = current.value
      updated.profiles.removeAll { $0.id == profile.id }
      updated.conflicts.removeAll { $0.profileId == profile.id }
      if updated.defaultProfileId == profile.id {
        updated.defaultProfileId = updated.profiles.map(\.id).min {
          $0.rawValue < $1.rawValue
        }
      }
      updated.sort()
      try Self.validateProfilePayload(updated)
      let prefix = profile.recordScope.productSyncIdentifier("")
      let scopedPayloads = try await profileRecordBoundary.listEncryptedPayloads(
        session: session,
        identifierPrefix: prefix
      ).filter { payload in
        guard profile.recordScope.namespace == nil else { return true }
        let relativeIdentifier = String(payload.payloadIdentifier.dropFirst(prefix.count))
        return Self.configurationKind(for: relativeIdentifier) != nil
      }
      var remainingPayloads = scopedPayloads
      while remainingPayloads.count > 99 {
        try Task.checkCancellation()
        let chunk = Array(remainingPayloads.prefix(99))
        let chunkResult = try await profileRecordBoundary.putEncryptedPayloadsAtomically(
          session: session,
          writes: [],
          deletes: chunk.map {
            ProductSyncAtomicDelete(
              expectedUpdatedAt: $0.updatedAt,
              payloadIdentifier: $0.payloadIdentifier
            )
          },
          checks: [
            ProductSyncAtomicCheck(
              expectedUpdatedAt: current.revision.legacyUpdatedAt,
              payloadIdentifier: MailProfileSyncPayload.primaryIdentifier
            )
          ]
        )
        guard chunkResult.committed else {
          throw MailProfileSyncError.concurrentModification
        }
        remainingPayloads.removeFirst(chunk.count)
      }
      try Task.checkCancellation()
      let result = try await profileRecordBoundary.putEncryptedPayloadsAtomically(
        session: session,
        writes: [
          ProductSyncAtomicWrite(
            encryptedPayload: try profileRecordBoundary.encryptedPayload(
              for: updated,
              identifier: MailProfileSyncPayload.primaryIdentifier,
              session: session
            ),
            expectedUpdatedAt: current.revision.legacyUpdatedAt,
            payloadIdentifier: MailProfileSyncPayload.primaryIdentifier
          )
        ],
        deletes: remainingPayloads.map {
          ProductSyncAtomicDelete(
            expectedUpdatedAt: $0.updatedAt,
            payloadIdentifier: $0.payloadIdentifier
          )
        },
        checks: []
      )
      guard result.committed,
        let profilePayload = result.payloads.first(where: {
          $0.payloadIdentifier == MailProfileSyncPayload.primaryIdentifier
        })
      else {
        throw MailProfileSyncError.concurrentModification
      }
      let written = try profileRecord.decode(profilePayload, session: session)
      return try Self.profileSnapshot(written.value, revision: written.revision)
    } catch {
      throw mapProfileBoundaryError(error)
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
      let conflict = payload.conflicts[conflictIndex]
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
        guard payload.profiles[profileIndex].set(conflict.competingValue, for: conflict.field)
        else {
          throw MailProfileSyncError.invalidProfileState
        }
      }
      payload.conflicts.remove(at: conflictIndex)
      return true
    }
  }

  private func loadProfileSnapshot(
    activeConnectionIds: [MailboxConnectionId],
    removedConnectionIds: [MailboxConnectionId],
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot {
    try await updateProfiles(session: session) { payload in
      payload.migrateLegacyProductAccount(
        productAccountId: session.productAccountId,
        activeConnectionIds: activeConnectionIds,
        removedConnectionIds: removedConnectionIds
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
        payload.sort()
        resolvedPayload = payload
        guard changed else { return .acceptAuthoritative }
        try Self.validateProfilePayload(payload)
        return .write(payload)
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
      })
    else {
      throw MailProfileSyncError.invalidProfileName
    }
    guard
      payload.profiles.allSatisfy({ profile in
        profile.appearance.isCurated
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

  private static func validateNewProfileName(
    _ name: String,
    in payload: MailProfileSyncPayload
  ) throws {
    guard (1...40).contains(name.count),
      !payload.profiles.contains(where: {
        $0.name.caseInsensitiveCompare(name) == .orderedSame
      })
    else {
      throw MailProfileSyncError.invalidProfileName
    }
  }

  private static func profileSnapshot(
    _ payload: MailProfileSyncPayload,
    revision: ProductSyncRecordRevision
  ) throws -> MailProfileSyncSnapshot {
    guard let defaultProfileId = payload.defaultProfileId else {
      throw MailProfileSyncError.invalidProfileState
    }
    return MailProfileSyncSnapshot(
      assignments: Dictionary(
        payload.assignments.map { ($0.connectionId, $0.profileId) },
        uniquingKeysWith: { first, _ in first }
      ),
      conflicts: payload.conflicts,
      defaultProfileId: defaultProfileId,
      profiles: payload.profiles,
      updatedAt: revision.legacyUpdatedAt
    )
  }

  private static func configurationKind(
    for relativeIdentifier: String
  ) -> MailProfileDuplicableConfiguration? {
    switch relativeIdentifier {
    case "mail-workflow-preferences:inbox":
      return .mailViews
    case "mail-workflow-preferences:templates":
      return .templates
    case "category-configuration-primary", "custom-category-primary":
      return .categories
    default:
      if relativeIdentifier.hasPrefix("custom-category-v2:") { return .categories }
      if relativeIdentifier.hasPrefix("mail-template-v1:") { return .templates }
      return nil
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

  @discardableResult
  fileprivate mutating func set(
    _ value: MailProfileFieldValue,
    for field: MailProfileEditableField
  ) -> Bool {
    switch (field, value) {
    case (.appearance, .appearance(let appearance)):
      self.appearance = appearance
      return true
    case (.name, .name(let name)):
      self.name = name
      return true
    case (.quietState, .quietState(let quietState)):
      self.quietState = quietState
      return true
    default:
      return false
    }
  }
}
