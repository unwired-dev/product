import CryptoKit
import Foundation

protocol PinSyncing {
  func loadPinnedMessageIds(
    session: ProductAccountSessionSnapshot
  ) async throws -> Set<StableProviderMessageIdentity>

  func setPinned(
    _ isPinned: Bool,
    messageId: StableProviderMessageIdentity,
    session: ProductAccountSessionSnapshot
  ) async throws
}

enum PinSyncError: LocalizedError, Equatable {
  case concurrentModification
  case invalidPayload
  case missingProductSyncKeyMaterial

  var errorDescription: String? {
    switch self {
    case .concurrentModification:
      return "Pins changed on another device. Refresh and try again."
    case .invalidPayload:
      return "A synchronized Pin could not be verified."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing Pins."
    }
  }
}

private struct PinSyncPayload: Codable, Equatable {
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let isPinned: Bool
  let provider: String
  let providerAccountIdentifier: String
  let providerMessageId: String
  let schemaVersion: Int

  init(
    changedAtMilliseconds: Int64,
    changedByTrustedDeviceId: String,
    isPinned: Bool,
    messageId: StableProviderMessageIdentity
  ) {
    self.changedAtMilliseconds = changedAtMilliseconds
    self.changedByTrustedDeviceId = changedByTrustedDeviceId
    self.isPinned = isPinned
    provider = messageId.connectionId.providerId.rawValue
    providerAccountIdentifier = messageId.connectionId.providerMailboxIdentity.value
    providerMessageId = messageId.providerMessageId
    schemaVersion = 1
  }

  var messageId: StableProviderMessageIdentity {
    StableProviderMessageIdentity(
      connectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: MailProviderId(rawValue: provider),
          value: providerAccountIdentifier
        )
      ),
      providerMessageId: providerMessageId
    )
  }

  func isNewer(than other: PinSyncPayload) -> Bool {
    if changedAtMilliseconds != other.changedAtMilliseconds {
      return changedAtMilliseconds > other.changedAtMilliseconds
    }
    return changedByTrustedDeviceId > other.changedByTrustedDeviceId
  }
}

final class PinSyncService: PinSyncing {
  static let payloadIdentifierPrefix = "pin-v1-"
  private static let maximumWriteAttempts = 5

  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let lastChangeLock = NSLock()
  private let nowMilliseconds: @Sendable () -> Int64
  private let transport: ProductSyncPayloadTransport
  private var lastChangeAtMilliseconds: Int64 = 0

  init(
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    nowMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    transport: ProductSyncPayloadTransport = ConvexClient()
  ) {
    self.keyMaterialStore = keyMaterialStore
    self.nowMilliseconds = nowMilliseconds
    self.transport = transport
  }

  func loadPinnedMessageIds(
    session: ProductAccountSessionSnapshot
  ) async throws -> Set<StableProviderMessageIdentity> {
    let encryptedPayloads = try await transport.listEncryptedProductSyncPayloads(
      identityToken: session.identityToken,
      payloadIdentifierPrefix: Self.payloadIdentifierPrefix
    )
    guard !encryptedPayloads.isEmpty else { return [] }
    guard let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw PinSyncError.missingProductSyncKeyMaterial
    }

    return try Set(
      encryptedPayloads.compactMap { encryptedPayload in
        let payload = try decrypt(encryptedPayload, material: material)
        return payload.isPinned ? payload.messageId : nil
      }
    )
  }

  func setPinned(
    _ isPinned: Bool,
    messageId: StableProviderMessageIdentity,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let payloadIdentifier = Self.payloadIdentifier(for: messageId)
    let proposedPayload = PinSyncPayload(
      changedAtMilliseconds: nextChangeAtMilliseconds(),
      changedByTrustedDeviceId: session.trustedDeviceId,
      isPinned: isPinned,
      messageId: messageId
    )
    for _ in 0..<Self.maximumWriteAttempts {
      let remotePayload = try await transport.getEncryptedProductSyncPayload(
        identityToken: session.identityToken,
        payloadIdentifier: payloadIdentifier
      )
      let material = try await keyMaterialForWrite(
        session: session,
        remotePayloadExists: remotePayload != nil
      )
      if let remotePayload {
        let current = try decrypt(remotePayload, material: material)
        if !proposedPayload.isNewer(than: current) {
          guard current.isPinned == isPinned else {
            throw PinSyncError.concurrentModification
          }
          return
        }
      }

      let plaintext = try encoder.encode(proposedPayload)
      let encryptedPayload = try material.encryptPayload(
        plaintext,
        associatedData: Data(payloadIdentifier.utf8)
      )
      let writtenPayload = try await transport.putEncryptedProductSyncPayloadIfUnchanged(
        identityToken: session.identityToken,
        payloadIdentifier: payloadIdentifier,
        encryptedPayload: encryptedPayload,
        trustedDeviceId: session.trustedDeviceId,
        expectedUpdatedAt: remotePayload?.updatedAt
      )
      guard writtenPayload.encryptedPayload != encryptedPayload else { return }
    }
    throw PinSyncError.concurrentModification
  }

  private func nextChangeAtMilliseconds() -> Int64 {
    lastChangeLock.lock()
    defer { lastChangeLock.unlock() }
    lastChangeAtMilliseconds = max(nowMilliseconds(), lastChangeAtMilliseconds + 1)
    return lastChangeAtMilliseconds
  }

  private func decrypt(
    _ encryptedPayload: EncryptedProductSyncPayload,
    material: ProductSyncKeyMaterial
  ) throws -> PinSyncPayload {
    let plaintext = try material.decryptPayload(
      encryptedPayload.encryptedPayload,
      associatedData: Data(encryptedPayload.payloadIdentifier.utf8)
    )
    let payload = try decoder.decode(PinSyncPayload.self, from: plaintext)
    guard
      payload.schemaVersion == 1,
      encryptedPayload.payloadIdentifier == Self.payloadIdentifier(for: payload.messageId)
    else {
      throw PinSyncError.invalidPayload
    }
    return payload
  }

  private func keyMaterialForWrite(
    session: ProductAccountSessionSnapshot,
    remotePayloadExists: Bool
  ) async throws -> ProductSyncKeyMaterial {
    if let material = try keyMaterialStore.load(productAccountId: session.productAccountId) {
      return material
    }
    guard !remotePayloadExists else {
      throw PinSyncError.missingProductSyncKeyMaterial
    }
    let existingPayloads = try await transport.listEncryptedProductSyncPayloads(
      identityToken: session.identityToken,
      payloadIdentifierPrefix: nil
    )
    guard existingPayloads.isEmpty else {
      throw PinSyncError.missingProductSyncKeyMaterial
    }
    return try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
  }

  private static func payloadIdentifier(
    for messageId: StableProviderMessageIdentity
  ) -> String {
    let components = [
      messageId.connectionId.providerId.rawValue,
      messageId.connectionId.providerMailboxIdentity.value,
      messageId.providerMessageId,
    ]
    let canonicalIdentity = components.map {
      "\($0.utf8.count):\($0)"
    }.joined()
    let digest = SHA256.hash(data: Data(canonicalIdentity.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return payloadIdentifierPrefix + digest
  }
}
