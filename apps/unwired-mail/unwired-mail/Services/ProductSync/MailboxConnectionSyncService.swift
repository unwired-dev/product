import Foundation

// swiftlint:disable:next type_body_length
final class MailboxConnectionSyncService: MailboxConnectionDefinitionSyncing {
  private static let maximumWriteAttempts = 5

  private let cacheStore: MailboxConnectionSyncCachePersisting
  private let clock: () -> Int64
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let payloadCodec: MailboxConnectionSyncPayloadCodec
  private let transport: ProductSyncPayloadTransport

  init(
    cacheStore: MailboxConnectionSyncCachePersisting =
      KeychainMailboxConnectionSyncCacheStore(),
    clock: @escaping () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    transport: ProductSyncPayloadTransport = ConvexClient()
  ) {
    self.cacheStore = cacheStore
    self.clock = clock
    self.keyMaterialStore = keyMaterialStore
    payloadCodec = MailboxConnectionSyncPayloadCodec(
      cacheStore: cacheStore,
      keyMaterialStore: keyMaterialStore
    )
    self.transport = transport
  }

  func loadSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    let (remotePayload, generationPayload) = try await payloadCodec.loadPayloads(
      session: session,
      transport: transport
    )
    let payload: MailboxConnectionSyncPayload
    do {
      payload = applyGenerationFloors(
        try payloadCodec.decrypt(remotePayload, session: session),
        ledger: try decryptGenerationLedger(generationPayload, session: session)
      )
    } catch {
      try? cacheStore.clear(productAccountId: session.productAccountId)
      throw error
    }
    try? payloadCodec.refreshCache(payload, remotePayload: remotePayload, session: session)
    return payloadCodec.snapshot(payload, updatedAt: remotePayload?.updatedAt)
  }

  func loadSnapshotForProviderAccess(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
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
    let payload = applyGenerationFloors(
      try payloadCodec.decrypt(remotePayload, session: session),
      ledger: try decryptGenerationLedger(generationPayload, session: session)
    )
    try? payloadCodec.refreshCache(payload, remotePayload: remotePayload, session: session)
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
          removedAt: clock()
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
      let removalGeneration = payload.removals.first {
        $0.connectionId == definition.id
      }?.authorizationGeneration
      var generation =
        existingGeneration
        ?? removalGeneration
        ?? definition.authorizationGeneration
      if let removalGeneration {
        generation = try await retainGenerationFloor(
          definition.id,
          minimumGeneration: max(generation, removalGeneration),
          session: session
        )
      }
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
      var payload = applyGenerationFloors(
        storedPayload,
        ledger: try decryptGenerationLedger(generationPayload, session: session)
      )
      guard try await mutation(&payload, storedPayload) else {
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

  private func retainGenerationFloor(
    _ connectionId: MailboxConnectionId,
    minimumGeneration: Int,
    isCommitted: Bool = true,
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
      ledger.floors.removeAll { $0.connectionId == connectionId }
      ledger.floors.append(
        MailboxAuthorizationGenerationFloor(
          authorizationGeneration: generation,
          isCommitted: existingFloor?.isCommitted == true || isCommitted,
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

  private func applyGenerationFloors(
    _ payload: MailboxConnectionSyncPayload,
    ledger: MailboxAuthorizationGenerationLedger
  ) -> MailboxConnectionSyncPayload {
    var payload = payload
    for floor in ledger.floors where floor.isCommitted {
      if let connectionIndex = payload.connections.firstIndex(where: {
        $0.id == floor.connectionId
      }) {
        let connection = payload.connections[connectionIndex]
        payload.connections[connectionIndex] = connection.withAuthorizationGeneration(
          max(connection.authorizationGeneration, floor.authorizationGeneration)
        )
        continue
      }
      if let removalIndex = payload.removals.firstIndex(where: {
        $0.connectionId == floor.connectionId
      }) {
        let removal = payload.removals[removalIndex]
        payload.removals[removalIndex] = removal.withAuthorizationGeneration(
          max(removal.authorizationGeneration, floor.authorizationGeneration)
        )
        continue
      }
      payload.removals.append(
        MailboxConnectionRemovalTombstone(
          authorizationGeneration: floor.authorizationGeneration,
          provider: floor.provider,
          providerAccountIdentifier: floor.providerAccountIdentifier,
          removedAt: 0
        )
      )
    }
    return payload
  }

  private var generationAssociatedData: Data {
    Data(MailboxAuthorizationGenerationLedger.primaryIdentifier.utf8)
  }
}
