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

  init(
    cacheStore: MailboxConnectionSyncCachePersisting =
      KeychainMailboxConnectionSyncCacheStore(),
    cleanupReceiptStore: MailboxCleanupReceiptPersisting =
      KeychainMailboxCleanupReceiptStore(),
    clock: @escaping () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    transport: ProductSyncPayloadTransport = ConvexClient()
  ) {
    self.cleanupReceiptStore = cleanupReceiptStore
    self.clock = clock
    let boundary = ProductSyncRecordBoundary(
      cache: MailboxConnectionSyncCiphertextCache(store: cacheStore),
      keyMaterialStore: keyMaterialStore,
      transport: ProductSyncPayloadRecordTransport(transport)
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
    } catch {
      await connectionRecord.clearCache(session: session)
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
