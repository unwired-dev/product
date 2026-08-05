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

private struct PinSyncPayload: Codable, Equatable, Sendable {
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

  private let lastChangeLock = NSLock()
  private let nowMilliseconds: @Sendable () -> Int64
  private let records: ProductSyncRecordFamilyHandle<String, PinSyncPayload>
  private var lastChangeAtMilliseconds: Int64 = 0

  init(
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    nowMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    transport: ProductSyncPayloadTransport = ConvexClient()
  ) {
    self.nowMilliseconds = nowMilliseconds
    records = ProductSyncRecordBoundary(
      keyMaterialStore: keyMaterialStore,
      transport: ProductSyncPayloadRecordTransport(transport)
    ).family(
      ProductSyncRecordFamilyDefinition<String, PinSyncPayload>(
        identifier: { $0 },
        identifierPrefix: Self.payloadIdentifierPrefix,
        recordId: { identifier in
          identifier.hasPrefix(Self.payloadIdentifierPrefix) ? identifier : nil
        },
        cachePolicy: .authoritative
      )
    )
  }

  func loadPinnedMessageIds(
    session: ProductAccountSessionSnapshot
  ) async throws -> Set<StableProviderMessageIdentity> {
    do {
      let storedRecords = try await records.list(session: session)
      return try Set(
        storedRecords.compactMap { identifier, record in
          let payload = record.value
          try validate(payload, identifier: identifier)
          advanceChangeClock(to: payload.changedAtMilliseconds)
          return payload.isPinned ? payload.messageId : nil
        }
      )
    } catch {
      throw mapBoundaryError(error)
    }
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
    do {
      _ = try await records.update(payloadIdentifier, session: session) { currentRecord in
        if let currentRecord {
          let current = currentRecord.value
          try self.validate(current, identifier: payloadIdentifier)
          self.advanceChangeClock(to: current.changedAtMilliseconds)
          if !proposedPayload.isNewer(than: current) {
            guard current.isPinned == isPinned else {
              throw PinSyncError.concurrentModification
            }
            return .acceptAuthoritative
          }
        }
        return .write(proposedPayload)
      }
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func nextChangeAtMilliseconds() -> Int64 {
    lastChangeLock.lock()
    defer { lastChangeLock.unlock() }
    lastChangeAtMilliseconds = max(nowMilliseconds(), lastChangeAtMilliseconds + 1)
    return lastChangeAtMilliseconds
  }

  private func advanceChangeClock(to changedAtMilliseconds: Int64) {
    lastChangeLock.lock()
    defer { lastChangeLock.unlock() }
    lastChangeAtMilliseconds = max(lastChangeAtMilliseconds, changedAtMilliseconds)
  }

  private func validate(_ payload: PinSyncPayload, identifier: String) throws {
    guard
      payload.schemaVersion == 1,
      identifier == Self.payloadIdentifier(for: payload.messageId)
    else {
      throw PinSyncError.invalidPayload
    }
  }

  private func mapBoundaryError(_ error: Error) -> Error {
    guard let boundaryError = error as? ProductSyncRecordBoundaryError else { return error }
    switch boundaryError {
    case .missingProductSyncKeyMaterial:
      return PinSyncError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      return PinSyncError.concurrentModification
    case .incompletePagination, .invalidPayloadIdentifier:
      return PinSyncError.invalidPayload
    }
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
