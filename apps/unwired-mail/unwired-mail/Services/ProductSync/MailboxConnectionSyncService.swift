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
  private static let maximumWriteAttempts = 5
  private static let providerAccessGate = MailboxConnectionProviderAccessGate()

  static func providerAccessWaiterCountForTesting(productAccountId: String) async -> Int {
    await providerAccessGate.waiterCount(productAccountId: productAccountId)
  }

  private let cacheStore: MailboxConnectionSyncCachePersisting
  private let cleanupReceiptStore: MailboxCleanupReceiptPersisting
  private let clock: () -> Int64
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let payloadCodec: MailboxConnectionSyncPayloadCodec
  private let transport: ProductSyncPayloadTransport

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
    self.cacheStore = cacheStore
    self.cleanupReceiptStore = cleanupReceiptStore
    self.clock = clock
    self.keyMaterialStore = keyMaterialStore
    payloadCodec = MailboxConnectionSyncPayloadCodec(
      cacheStore: cacheStore,
      keyMaterialStore: keyMaterialStore
    )
    self.transport = transport
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
    let cachedPayloadBeforeLoad = try? cacheStore.load(
      productAccountId: session.productAccountId
    )
    let (remotePayload, generationPayload) = try await payloadCodec.loadPayloads(
      session: session,
      transport: transport
    )
    let payload: MailboxConnectionSyncPayload
    do {
      payload = try payloadCodec.decrypt(remotePayload, session: session)
        .applyingGenerationFloors(
          try decryptGenerationLedger(generationPayload, session: session)
        )
    } catch {
      try? cacheStore.clear(productAccountId: session.productAccountId)
      throw error
    }
    try? payloadCodec.refreshCache(
      payload,
      remotePayload: remotePayload,
      cachedPayloadBeforeLoad: cachedPayloadBeforeLoad,
      session: session
    )
    return payloadCodec.snapshot(payload, updatedAt: remotePayload?.updatedAt)
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
    let cachedPayloadBeforeLoad = try? cacheStore.load(
      productAccountId: session.productAccountId
    )
    let remotePayload: EncryptedProductSyncPayload?
    let generationPayload: EncryptedProductSyncPayload?
    do {
      (remotePayload, generationPayload) = try await payloadCodec.loadPayloads(
        session: session,
        transport: transport
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard let cachedPayload = try cacheStore.load(productAccountId: session.productAccountId)
      else {
        throw error
      }
      let cached = try payloadCodec.decrypt(cachedPayload, session: session)
      return payloadCodec.snapshot(cached, updatedAt: cachedPayload.updatedAt)
    }
    let payload = try payloadCodec.decrypt(remotePayload, session: session)
      .applyingGenerationFloors(
        try decryptGenerationLedger(generationPayload, session: session)
      )
    try? payloadCodec.refreshCache(
      payload,
      remotePayload: remotePayload,
      cachedPayloadBeforeLoad: cachedPayloadBeforeLoad,
      session: session
    )
    return payloadCodec.snapshot(payload, updatedAt: remotePayload?.updatedAt)
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
    for attempt in 0..<Self.maximumWriteAttempts {
      let (remotePayload, generationPayload) = try await payloadCodec.loadPayloads(
        session: session,
        transport: transport
      )
      let storedPayload = try payloadCodec.decrypt(remotePayload, session: session)
      var payload = storedPayload.applyingGenerationFloors(
        try decryptGenerationLedger(generationPayload, session: session)
      )
      let changed: Bool
      do {
        changed = try await mutation(&payload, storedPayload)
      } catch {
        try? payloadCodec.refreshCache(payload, remotePayload: remotePayload, session: session)
        throw error
      }
      guard changed else {
        try? payloadCodec.refreshCache(payload, remotePayload: remotePayload, session: session)
        return payloadCodec.snapshot(payload, updatedAt: remotePayload?.updatedAt)
      }
      payload.sort()

      let material = try await payloadCodec.keyMaterialForWrite(
        session: session,
        remotePayloadExists: remotePayload != nil,
        transport: transport
      )
      let plaintext = try encoder.encode(payload)
      let encryptedPayload = try material.encryptPayload(
        plaintext,
        associatedData: payloadCodec.associatedData
      )
      let writtenPayload = try await transport.putEncryptedProductSyncPayloadIfUnchanged(
        identityToken: session.identityToken,
        payloadIdentifier: MailboxConnectionSyncPayload.primaryIdentifier,
        encryptedPayload: encryptedPayload,
        trustedDeviceId: session.trustedDeviceId,
        expectedUpdatedAt: remotePayload?.updatedAt
      )
      guard writtenPayload.encryptedPayload == encryptedPayload else {
        let isLastAttempt = (attempt == Self.maximumWriteAttempts - 1)
        if !isLastAttempt {
          let jitterNanoseconds = UInt64.random(in: 50_000_000...150_000_000)
          try await Task.sleep(nanoseconds: jitterNanoseconds)
        }
        continue
      }
      try? payloadCodec.refreshCache(payload, remotePayload: writtenPayload, session: session)
      return payloadCodec.snapshot(payload, updatedAt: writtenPayload.updatedAt)
    }
    throw MailboxConnectionSyncError.concurrentModification
  }

  private func decryptGenerationLedger(
    _ remotePayload: EncryptedProductSyncPayload?,
    session: ProductAccountSessionSnapshot
  ) throws -> MailboxAuthorizationGenerationLedger {
    guard let remotePayload else { return .empty }
    guard let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw MailboxConnectionSyncError.missingProductSyncKeyMaterial
    }
    let plaintext = try material.decryptPayload(
      remotePayload.encryptedPayload,
      associatedData: generationAssociatedData
    )
    return try decoder.decode(MailboxAuthorizationGenerationLedger.self, from: plaintext)
  }

  private func loadGenerationRemotePayload(
    session: ProductAccountSessionSnapshot
  ) async throws -> EncryptedProductSyncPayload? {
    try await transport.getEncryptedProductSyncPayload(
      identityToken: session.identityToken,
      payloadIdentifier: MailboxAuthorizationGenerationLedger.primaryIdentifier
    )
  }

  private func publishedRemovalGeneration(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> Int? {
    let remotePayload = try await transport.getEncryptedProductSyncPayload(
      identityToken: session.identityToken,
      payloadIdentifier: MailboxConnectionSyncPayload.primaryIdentifier
    )
    let payload = try payloadCodec.decrypt(remotePayload, session: session)
    guard !payload.connections.contains(where: { $0.id == connectionId }) else {
      return nil
    }
    return payload.removals.first {
      $0.connectionId == connectionId
    }?.authorizationGeneration
  }

  // swiftlint:disable:next function_body_length
  private func retainGenerationFloor(
    _ connectionId: MailboxConnectionId,
    minimumGeneration: Int,
    isCommitted: Bool = true,
    commitsOnlyMinimumGeneration: Bool = false,
    session: ProductAccountSessionSnapshot
  ) async throws -> Int {
    guard let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw MailboxConnectionSyncError.missingProductSyncKeyMaterial
    }
    for attempt in 0..<Self.maximumWriteAttempts {
      let remotePayload = try await loadGenerationRemotePayload(session: session)
      var ledger = try decryptGenerationLedger(remotePayload, session: session)
      let existingFloor = ledger.floors.first { $0.connectionId == connectionId }
      let generation = max(
        minimumGeneration,
        existingFloor?.authorizationGeneration ?? 0
      )
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
      let plaintext = try encoder.encode(ledger)
      let encryptedPayload = try material.encryptPayload(
        plaintext,
        associatedData: generationAssociatedData
      )
      let writtenPayload = try await transport.putEncryptedProductSyncPayloadIfUnchanged(
        identityToken: session.identityToken,
        payloadIdentifier: MailboxAuthorizationGenerationLedger.primaryIdentifier,
        encryptedPayload: encryptedPayload,
        trustedDeviceId: session.trustedDeviceId,
        expectedUpdatedAt: remotePayload?.updatedAt
      )
      if writtenPayload.encryptedPayload == encryptedPayload {
        return generation
      }
      let isLastAttempt = (attempt == Self.maximumWriteAttempts - 1)
      if !isLastAttempt {
        let jitterNanoseconds = UInt64.random(in: 50_000_000...150_000_000)
        try await Task.sleep(nanoseconds: jitterNanoseconds)
      }
    }
    throw MailboxConnectionSyncError.concurrentModification
  }

  private var generationAssociatedData: Data {
    Data(MailboxAuthorizationGenerationLedger.primaryIdentifier.utf8)
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
