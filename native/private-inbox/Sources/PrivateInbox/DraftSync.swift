import CryptoKit
import Foundation

// One Draft's Product Sync record: the Draft's identifier, the record's write count and the Draft's
// JSON, sealed together so a record cannot be moved to another Draft or served as a newer one.
struct DraftRecord: Codable, Equatable {
  static let schemaVersion = 1
  let id: String
  let version: Int
  let draft: String?
}

// The signed-in Trusted Device's Product Sync of its Drafts: everything it needs, read once under
// the registration gate, so network work runs without holding Draft storage or Gmail. TypeScript
// merges the Drafts; this only seals, opens and moves records and asset chunks.
@MainActor struct DraftSync {
  // Chunks stay well within a Convex document once sealed and base64-encoded.
  static let chunkSize = 512 * 1024
  static let chunkSchemaVersion = 1
  let backend: ProductSyncBackend
  let session: ProductSignInIdentity
  let product: ProductRegistrationReceipt
  let ring: ProductSyncKeyRing
  var owner: String { product.productAccountId }

  func identifier(draft id: String) throws -> String { try ring.identifier("draft", id) }

  // Every chunk is bound to its asset's identifier and digest and to its position.
  func identifiers(asset id: String, digest: String, size: Int) throws -> [String] {
    let base = try ring.identifier("draft-asset", id + "\n" + digest)
    return (0..<max(1, (size + Self.chunkSize - 1) / Self.chunkSize)).map { base + ".\($0)" }
  }

  // Records that open for this account under their own Draft's identifier. A record of a `known`
  // Draft that exists but does not open is reported as unreadable rather than absent, so it is
  // never taken for a deletion.
  func pull(known: [String]) async throws -> [String: Any] {
    let knownIds = Dictionary(
      try known.map { (try identifier(draft: $0), $0) }, uniquingKeysWith: { first, _ in first })
    var records: [[String: Any]] = []
    var unreadable: [String] = []
    for stored in try await backend.list(session, product, "draft.") {
      let record = try? JSONDecoder().decode(
        DraftRecord.self,
        from: ring.open(
          record: stored.encryptedPayload, account: owner, identifier: stored.payloadIdentifier,
          schemaVersion: DraftRecord.schemaVersion))
      guard let record, try identifier(draft: record.id) == stored.payloadIdentifier else {
        if let id = knownIds[stored.payloadIdentifier] { unreadable.append(id) }
        continue
      }
      records.append([
        "id": record.id, "version": record.version, "updatedAt": stored.updatedAt,
        "draft": record.draft as Any? ?? NSNull(),
      ])
    }
    return ["owner": owner, "records": records, "unreadable": unreadable]
  }

  // A nil Draft is a sealed deletion tombstone retaining its version and identifier. Every write
  // compares `expected`; a lost reply is reconciled by the next pull.
  func push(id: String, version: Int, draft: String?, expected: Double?) async throws
    -> [String: Any]
  {
    let identifier = try identifier(draft: id)
    let sealed = try ring.seal(
      record: JSONEncoder().encode(DraftRecord(id: id, version: version, draft: draft)),
      account: owner, identifier: identifier, schemaVersion: DraftRecord.schemaVersion)
    let stored: StoredPayload
    do {
      stored = try await backend.put(session, product, identifier, sealed, expected)
    } catch {
      // Convex refuses a compare-and-set against a record that was deleted meanwhile.
      if error as? RegistrationError == .revoked || error as? RegistrationError == .deleted {
        throw error
      }
      guard expected != nil else { throw error }
      return ["owner": owner, "committed": false]
    }
    guard stored.payloadIdentifier == identifier, stored.encryptedPayload == sealed else {
      return ["owner": owner, "committed": false]
    }
    return ["owner": owner, "committed": true, "updatedAt": stored.updatedAt]
  }

  // Seals verified bytes in chunks. A chunk already stored is kept rather than replaced; its
  // content is checked against the digest when it is downloaded.
  func upload(_ bytes: Data, id: String, digest: String) async throws {
    for (index, identifier) in try identifiers(asset: id, digest: digest, size: bytes.count)
      .enumerated()
    {
      let start = bytes.startIndex + index * Self.chunkSize
      let chunk = bytes[start..<min(start + Self.chunkSize, bytes.endIndex)]
      let sealed = try ring.seal(
        record: Data(chunk), account: owner, identifier: identifier,
        schemaVersion: Self.chunkSchemaVersion)
      let stored = try await backend.put(session, product, identifier, sealed, nil)
      guard stored.payloadIdentifier == identifier,
        let opened = try? ring.open(
          record: stored.encryptedPayload, account: owner, identifier: identifier,
          schemaVersion: Self.chunkSchemaVersion), opened == Data(chunk)
      else { throw PrivateInboxError.attachmentMissing }
    }
  }

  // The asset's bytes, only when every chunk opens in place and together they match its size and
  // digest. Anything less is missing: the file stays incomplete on this device.
  func download(id: String, digest: String, size: Int) async throws -> Data {
    guard size <= PrivateInboxStore.draftAssetLimit else { throw PrivateInboxError.tooLarge }
    var bytes = Data()
    for identifier in try identifiers(asset: id, digest: digest, size: size) {
      guard let stored = try await backend.get(session, product, identifier),
        let chunk = try? ring.open(
          record: stored.encryptedPayload, account: owner, identifier: identifier,
          schemaVersion: Self.chunkSchemaVersion),
        bytes.count + chunk.count <= size
      else { throw PrivateInboxError.attachmentMissing }
      bytes.append(chunk)
    }
    guard bytes.count == size,
      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest
    else { throw PrivateInboxError.attachmentMissing }
    return bytes
  }


}

extension RegistrationStore {
  // Only a Trusted Device holding the account's published keys and a Product Sign-In session
  // synchronizes Drafts, and only for the account signed in now.
  func draftSync(owner: String) throws -> DraftSync {
    guard let backend = productSync, let session, let saved = try load(),
      saved.accountRemoval == nil, let product = saved.product, product.pending != true,
      let vault = try loadVault(product.productAccountId), vault.published
    else { throw RegistrationError.unavailable }
    guard product.productAccountId == owner else { throw PrivateInboxError.mailboxInvalidated }
    return DraftSync(backend: backend, session: session, product: product, ring: vault.ring)
  }

  // Credential-only revocation runs before using a cached session or key ring.
  func prepareDraftSync(owner: String) async throws -> DraftSync {
    let sync = try draftSync(owner: owner)
    do {
      try await requireNotRevoked(sync.product)
    } catch {
      try await draftSyncFailure(owner: owner, error: error)
    }
    return sync
  }

  // A rejection from suspended work must never purge a different account opened meanwhile.
  func draftSyncFailure(owner: String, error: any Error) async throws {
    guard (try load())?.product?.productAccountId == owner else {
      throw PrivateInboxError.mailboxInvalidated
    }
    switch error {
    case RegistrationError.revoked: _ = try await purge()
    case RegistrationError.deleted: _ = try await purge(notice: "deleted")
    default: break
    }
    throw error
  }

  // A complete asset's verified bytes, to upload.
  func draftAssetBytes(owner: String, id: String, digest: String) async throws -> Data {
    let (_, bytes) = try await draftWork { store, current in
      guard owner == current else { throw PrivateInboxError.mailboxInvalidated }
      return try store.readDraftAsset(owner: owner, id: id, digest: digest)
    }
    return bytes
  }

  // Stores downloaded bytes as an import would, for the account that is still signed in.
  func storeDraftAsset(owner: String, id: String, bytes: Data) async throws -> [String: Any] {
    let (_, stored) = try await draftWork { store, current in
      guard owner == current else { throw PrivateInboxError.mailboxInvalidated }
      return try store.importDraftAsset(owner: owner, id: id, bytes: bytes)
    }
    return ["owner": owner, "size": stored.size, "digest": stored.digest]
  }
}
