import Foundation

// swiftlint:disable file_length

enum MailboxConnectionSyncError: LocalizedError, Equatable {
  case concurrentModification
  case invalidDefaultSendingConnection
  case missingProductSyncKeyMaterial

  var errorDescription: String? {
    switch self {
    case .concurrentModification:
      return "Mailbox Connections changed on another device. Refresh and try again."
    case .invalidDefaultSendingConnection:
      return "Choose an existing Mailbox Connection as the default sender."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing Mailbox Connections."
    }
  }
}

private struct MailboxConnectionRemovalTombstone: Codable, Equatable, Sendable {
  let authorizationGeneration: Int
  let provider: String
  let providerAccountIdentifier: String
  let removedAt: Int64

  init(
    authorizationGeneration: Int,
    provider: String,
    providerAccountIdentifier: String,
    removedAt: Int64
  ) {
    self.authorizationGeneration = authorizationGeneration
    self.provider = provider
    self.providerAccountIdentifier = providerAccountIdentifier
    self.removedAt = removedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    authorizationGeneration =
      try container.decodeIfPresent(Int.self, forKey: .authorizationGeneration) ?? 1
    provider = try container.decode(String.self, forKey: .provider)
    providerAccountIdentifier = try container.decode(
      String.self,
      forKey: .providerAccountIdentifier
    )
    removedAt = try container.decode(Int64.self, forKey: .removedAt)
  }

  var connectionId: MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: provider),
        value: providerAccountIdentifier
      )
    )
  }

  func withAuthorizationGeneration(_ authorizationGeneration: Int) -> Self {
    MailboxConnectionRemovalTombstone(
      authorizationGeneration: authorizationGeneration,
      provider: provider,
      providerAccountIdentifier: providerAccountIdentifier,
      removedAt: removedAt
    )
  }

  private enum CodingKeys: String, CodingKey {
    case authorizationGeneration
    case provider
    case providerAccountIdentifier
    case removedAt
  }
}

private struct MailboxAuthorizationGenerationFloor: Codable, Equatable, Sendable {
  let authorizationGeneration: Int
  let provider: String
  let providerAccountIdentifier: String

  var connectionId: MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: provider),
        value: providerAccountIdentifier
      )
    )
  }
}

private struct MailboxAuthorizationGenerationLedger: Codable, Equatable, Sendable {
  static let primaryIdentifier = "mailbox-authorization-generations-v1"

  var floors: [MailboxAuthorizationGenerationFloor]
  let schemaVersion: Int

  static let empty = MailboxAuthorizationGenerationLedger(floors: [], schemaVersion: 1)

  mutating func sort() {
    floors.sort { $0.connectionId.rawValue < $1.connectionId.rawValue }
  }
}

private struct MailboxConnectionSyncPayload: Codable, Equatable, Sendable {
  static let primaryIdentifier = "mailbox-connections-primary"

  var connections: [MailboxConnectionDefinition]
  var defaultSendingConnectionProvider: String?
  var defaultSendingProviderAccountIdentifier: String?
  var removals: [MailboxConnectionRemovalTombstone]
  let schemaVersion: Int

  static let empty = MailboxConnectionSyncPayload(
    connections: [],
    defaultSendingConnectionProvider: nil,
    defaultSendingProviderAccountIdentifier: nil,
    removals: [],
    schemaVersion: 1
  )

  var defaultSendingConnectionId: MailboxConnectionId? {
    guard
      let defaultSendingConnectionProvider,
      let defaultSendingProviderAccountIdentifier
    else {
      return nil
    }
    return MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: defaultSendingConnectionProvider),
        value: defaultSendingProviderAccountIdentifier
      )
    )
  }

  mutating func sort() {
    connections.sort { $0.id.rawValue < $1.id.rawValue }
    removals.sort { $0.connectionId.rawValue < $1.connectionId.rawValue }
  }
}

// swiftlint:disable:next type_body_length
final class MailboxConnectionSyncService: MailboxConnectionDefinitionSyncing {
  private static let maximumWriteAttempts = 5

  private let cacheStore: MailboxConnectionSyncCachePersisting
  private let clock: () -> Int64
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
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
    self.transport = transport
  }

  func loadSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    let remotePayload = try await loadRemotePayload(session: session)
    let generationPayload = try await loadGenerationRemotePayload(session: session)
    let payload: MailboxConnectionSyncPayload
    do {
      payload = applyGenerationFloors(
        try decrypt(remotePayload, session: session),
        ledger: try decryptGenerationLedger(generationPayload, session: session)
      )
    } catch {
      try? cacheStore.clear(productAccountId: session.productAccountId)
      throw error
    }
    try? refreshCache(payload, remotePayload: remotePayload, session: session)
    return snapshot(payload, updatedAt: remotePayload?.updatedAt)
  }

  func loadSnapshotForProviderAccess(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    let remotePayload: EncryptedProductSyncPayload?
    let generationPayload: EncryptedProductSyncPayload?
    do {
      let payloads = try await transport.getEncryptedProductSyncPayloads(
        identityToken: session.identityToken,
        payloadIdentifiers: [
          MailboxConnectionSyncPayload.primaryIdentifier,
          MailboxAuthorizationGenerationLedger.primaryIdentifier,
        ]
      )
      remotePayload = payloads.first {
        $0.payloadIdentifier == MailboxConnectionSyncPayload.primaryIdentifier
      }
      generationPayload = payloads.first {
        $0.payloadIdentifier == MailboxAuthorizationGenerationLedger.primaryIdentifier
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard let cachedPayload = try cacheStore.load(productAccountId: session.productAccountId)
      else {
        throw error
      }
      let cached = try decrypt(cachedPayload, session: session)
      return snapshot(cached, updatedAt: cachedPayload.updatedAt)
    }
    let payload = applyGenerationFloors(
      try decrypt(remotePayload, session: session),
      ledger: try decryptGenerationLedger(generationPayload, session: session)
    )
    try? refreshCache(payload, remotePayload: remotePayload, session: session)
    return snapshot(payload, updatedAt: remotePayload?.updatedAt)
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
      session: session
    )
    return try await update(session: session) { payload, storedPayload in
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
        session: session
      )
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
      payload.removals.removeAll { $0.connectionId == definition.id }
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
      let remotePayload = try await loadRemotePayload(session: session)
      let generationPayload = try await loadGenerationRemotePayload(session: session)
      let storedPayload = try decrypt(remotePayload, session: session)
      var payload = applyGenerationFloors(
        storedPayload,
        ledger: try decryptGenerationLedger(generationPayload, session: session)
      )
      guard try await mutation(&payload, storedPayload) else {
        try refreshCache(payload, remotePayload: remotePayload, session: session)
        return snapshot(payload, updatedAt: remotePayload?.updatedAt)
      }
      payload.sort()

      let material = try await keyMaterialForWrite(
        session: session,
        remotePayloadExists: remotePayload != nil
      )
      let plaintext = try encoder.encode(payload)
      let encryptedPayload = try material.encryptPayload(
        plaintext,
        associatedData: primaryAssociatedData
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
      try? refreshCache(payload, remotePayload: writtenPayload, session: session)
      return snapshot(payload, updatedAt: writtenPayload.updatedAt)
    }
    throw MailboxConnectionSyncError.concurrentModification
  }

  private func decrypt(
    _ remotePayload: EncryptedProductSyncPayload?,
    session: ProductAccountSessionSnapshot
  ) throws -> MailboxConnectionSyncPayload {
    guard let remotePayload else { return .empty }
    guard let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw MailboxConnectionSyncError.missingProductSyncKeyMaterial
    }
    let plaintext = try material.decryptPayload(
      remotePayload.encryptedPayload,
      associatedData: primaryAssociatedData
    )
    return try decoder.decode(MailboxConnectionSyncPayload.self, from: plaintext)
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

  private func keyMaterialForWrite(
    session: ProductAccountSessionSnapshot,
    remotePayloadExists: Bool
  ) async throws -> ProductSyncKeyMaterial {
    if let material = try keyMaterialStore.load(productAccountId: session.productAccountId) {
      return material
    }
    guard !remotePayloadExists else {
      throw MailboxConnectionSyncError.missingProductSyncKeyMaterial
    }
    let existingPayloads = try await transport.listEncryptedProductSyncPayloads(
      identityToken: session.identityToken,
      payloadIdentifierPrefix: nil
    )
    guard existingPayloads.isEmpty else {
      throw MailboxConnectionSyncError.missingProductSyncKeyMaterial
    }
    return try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
  }

  private func loadRemotePayload(
    session: ProductAccountSessionSnapshot
  ) async throws -> EncryptedProductSyncPayload? {
    try await transport.getEncryptedProductSyncPayload(
      identityToken: session.identityToken,
      payloadIdentifier: MailboxConnectionSyncPayload.primaryIdentifier
    )
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
    session: ProductAccountSessionSnapshot
  ) async throws -> Int {
    guard let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw MailboxConnectionSyncError.missingProductSyncKeyMaterial
    }
    for attempt in 0..<Self.maximumWriteAttempts {
      let remotePayload = try await loadGenerationRemotePayload(session: session)
      var ledger = try decryptGenerationLedger(remotePayload, session: session)
      let generation = max(
        minimumGeneration,
        ledger.floors.first { $0.connectionId == connectionId }?.authorizationGeneration ?? 0
      )
      ledger.floors.removeAll { $0.connectionId == connectionId }
      ledger.floors.append(
        MailboxAuthorizationGenerationFloor(
          authorizationGeneration: generation,
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
    for floor in ledger.floors {
      if let connectionIndex = payload.connections.firstIndex(where: {
        $0.id == floor.connectionId
      }) {
        let connection = payload.connections[connectionIndex]
        let requiresLocalCleanup =
          connection.authorizationGeneration < floor.authorizationGeneration
        payload.connections[connectionIndex] = connection.withAuthorizationGeneration(
          max(connection.authorizationGeneration, floor.authorizationGeneration)
        )
        if requiresLocalCleanup,
          !payload.removals.contains(where: { $0.connectionId == floor.connectionId })
        {
          payload.removals.append(
            MailboxConnectionRemovalTombstone(
              authorizationGeneration: floor.authorizationGeneration,
              provider: floor.provider,
              providerAccountIdentifier: floor.providerAccountIdentifier,
              removedAt: 0
            )
          )
        }
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

  private func refreshCache(
    _ payload: MailboxConnectionSyncPayload,
    remotePayload: EncryptedProductSyncPayload?,
    session: ProductAccountSessionSnapshot
  ) throws {
    try cacheStore.clear(productAccountId: session.productAccountId)
    guard let remotePayload else { return }
    guard let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw MailboxConnectionSyncError.missingProductSyncKeyMaterial
    }
    let encryptedPayload = try material.encryptPayload(
      encoder.encode(payload),
      associatedData: primaryAssociatedData
    )
    try cacheStore.save(
      EncryptedProductSyncPayload(
        encryptedPayload: encryptedPayload,
        payloadIdentifier: remotePayload.payloadIdentifier,
        updatedAt: remotePayload.updatedAt
      ),
      productAccountId: session.productAccountId
    )
  }

  private func snapshot(
    _ payload: MailboxConnectionSyncPayload,
    updatedAt: Int64?
  ) -> MailboxConnectionSyncSnapshot {
    return MailboxConnectionSyncSnapshot(
      connections: payload.connections.sorted { $0.id.rawValue < $1.id.rawValue },
      defaultSendingConnectionId: payload.defaultSendingConnectionId,
      removedConnectionIds:
        payload.removals.map(\.connectionId)
        .sorted { $0.rawValue < $1.rawValue },
      updatedAt: updatedAt
    )
  }

  private var primaryAssociatedData: Data {
    Data(MailboxConnectionSyncPayload.primaryIdentifier.utf8)
  }

  private var generationAssociatedData: Data {
    Data(MailboxAuthorizationGenerationLedger.primaryIdentifier.utf8)
  }
}
