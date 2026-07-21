import Foundation

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
  let provider: String
  let providerAccountIdentifier: String
  let removedAt: Int64

  var connectionId: MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: provider),
        value: providerAccountIdentifier
      )
    )
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
    let payload = try decrypt(remotePayload, session: session)
    try refreshCache(remotePayload, productAccountId: session.productAccountId)
    return snapshot(payload, updatedAt: remotePayload?.updatedAt)
  }

  func loadSnapshotForProviderAccess(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    let remotePayload: EncryptedProductSyncPayload?
    do {
      remotePayload = try await loadRemotePayload(session: session)
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
    let payload = try decrypt(remotePayload, session: session)
    try refreshCache(remotePayload, productAccountId: session.productAccountId)
    return snapshot(payload, updatedAt: remotePayload?.updatedAt)
  }

  func reconcileConnections(
    _ connections: [MailboxConnectionDefinition],
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    try await update(session: session) { payload in
      var changed = false
      let removedIds = Set(payload.removals.map(\.connectionId))
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
    try await update(session: session) { payload in
      let hadConnection = payload.connections.contains { $0.id == connectionId }
      let hadRemoval = payload.removals.contains { $0.connectionId == connectionId }
      guard hadConnection || !hadRemoval else { return false }

      payload.connections.removeAll { $0.id == connectionId }
      payload.removals.removeAll { $0.connectionId == connectionId }
      payload.removals.append(
        MailboxConnectionRemovalTombstone(
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
    return try await update(session: session) { payload in
      payload.connections.removeAll { $0.id == definition.id }
      payload.connections.append(definition)
      payload.removals.removeAll { $0.connectionId == definition.id }
      return true
    }
  }

  func setDefaultSendingConnection(
    _ connectionId: MailboxConnectionId?,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    try await update(session: session) { payload in
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
    mutation: (inout MailboxConnectionSyncPayload) throws -> Bool
  ) async throws -> MailboxConnectionSyncSnapshot {
    for attempt in 0..<Self.maximumWriteAttempts {
      let remotePayload = try await loadRemotePayload(session: session)
      var payload = try decrypt(remotePayload, session: session)
      guard try mutation(&payload) else {
        try refreshCache(remotePayload, productAccountId: session.productAccountId)
        return snapshot(payload, updatedAt: remotePayload?.updatedAt)
      }
      payload.sort()

      let material = try keyMaterialForWrite(
        session: session,
        remotePayloadExists: remotePayload != nil
      )
      let plaintext = try encoder.encode(payload)
      let encryptedPayload = try material.encryptPayload(
        plaintext,
        associatedData: associatedData
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
      try? refreshCache(writtenPayload, productAccountId: session.productAccountId)
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
      associatedData: associatedData
    )
    return try decoder.decode(MailboxConnectionSyncPayload.self, from: plaintext)
  }

  private func keyMaterialForWrite(
    session: ProductAccountSessionSnapshot,
    remotePayloadExists: Bool
  ) throws -> ProductSyncKeyMaterial {
    if let material = try keyMaterialStore.load(productAccountId: session.productAccountId) {
      return material
    }
    guard !remotePayloadExists else {
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

  private func refreshCache(
    _ payload: EncryptedProductSyncPayload?,
    productAccountId: String
  ) throws {
    try cacheStore.clear(productAccountId: productAccountId)
    if let payload {
      try cacheStore.save(payload, productAccountId: productAccountId)
    }
  }

  private func snapshot(
    _ payload: MailboxConnectionSyncPayload,
    updatedAt: Int64?
  ) -> MailboxConnectionSyncSnapshot {
    MailboxConnectionSyncSnapshot(
      connections: payload.connections.sorted { $0.id.rawValue < $1.id.rawValue },
      defaultSendingConnectionId: payload.defaultSendingConnectionId,
      removedConnectionIds: payload.removals.map(\.connectionId).sorted {
        $0.rawValue < $1.rawValue
      },
      updatedAt: updatedAt
    )
  }

  private var associatedData: Data {
    Data(MailboxConnectionSyncPayload.primaryIdentifier.utf8)
  }
}
