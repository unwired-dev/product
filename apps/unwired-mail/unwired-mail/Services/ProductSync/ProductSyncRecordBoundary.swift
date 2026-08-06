import CryptoKit
import Foundation

// swiftlint:disable file_length

struct ProductSyncRecordRevision: Equatable, Sendable {
  fileprivate let updatedAt: Int64

  init(legacyUpdatedAt: Int64) {
    updatedAt = legacyUpdatedAt
  }

  var legacyUpdatedAt: Int64 {
    updatedAt
  }
}

struct ProductSyncRecord<Value: Sendable>: Sendable {
  let revision: ProductSyncRecordRevision
  let value: Value
}

enum ProductSyncRecordUpdate<Value: Sendable>: Sendable {
  case acceptAuthoritative
  case write(Value)
}

enum ProductSyncRecordConditionalWriteResult<Value: Sendable>: Sendable {
  case committed(ProductSyncRecord<Value>)
  case conflict(ProductSyncRecord<Value>)
}

enum ProductSyncRecordCachePolicy: Equatable, Sendable {
  case authoritative
  case authoritativeWithCiphertextFallback
  case invalidateBeforeWrite
  case invalidateBeforeWriteAndRefresh
  case invalidateThenRefresh
  case refreshAfterCommit

  var allowsCiphertextFallback: Bool {
    self == .authoritativeWithCiphertextFallback
  }

  fileprivate var invalidatesBeforeWrite: Bool {
    switch self {
    case .invalidateBeforeWrite, .invalidateBeforeWriteAndRefresh, .invalidateThenRefresh:
      true
    case .authoritative, .authoritativeWithCiphertextFallback, .refreshAfterCommit:
      false
    }
  }

  fileprivate var refreshesAfterCommit: Bool {
    switch self {
    case .authoritativeWithCiphertextFallback, .invalidateBeforeWriteAndRefresh,
      .refreshAfterCommit:
      true
    case .authoritative, .invalidateBeforeWrite, .invalidateThenRefresh:
      false
    }
  }

  fileprivate var refreshesAfterConflict: Bool {
    switch self {
    case .authoritativeWithCiphertextFallback, .invalidateBeforeWriteAndRefresh:
      true
    case .authoritative, .invalidateBeforeWrite, .invalidateThenRefresh, .refreshAfterCommit:
      false
    }
  }
}

protocol ProductSyncCiphertextCaching {
  func loadFamily(
    productAccountId: String,
    payloadIdentifierPrefix: String
  ) async throws -> [EncryptedProductSyncPayload]?
  func load(
    productAccountId: String,
    payloadIdentifier: String
  ) async throws -> EncryptedProductSyncPayload?
  func remove(productAccountId: String, payloadIdentifier: String) async throws
  func removeIfUnchanged(
    _ payload: EncryptedProductSyncPayload?,
    productAccountId: String,
    payloadIdentifier: String
  ) async throws
  func replaceFamily(
    _ payloads: [EncryptedProductSyncPayload],
    productAccountId: String,
    payloadIdentifierPrefix: String
  ) async throws
  func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) async throws
}

struct ProductSyncSingletonDefinition<Value: Codable & Sendable>: Sendable {
  let cachePolicy: ProductSyncRecordCachePolicy
  let identifier: String

  init(identifier: String, cachePolicy: ProductSyncRecordCachePolicy) {
    self.identifier = identifier
    self.cachePolicy = cachePolicy
  }
}

struct ProductSyncKeyedRecordFamilyDefinition<
  RecordID: Hashable & Sendable,
  Value: Codable & Sendable
>: Sendable {
  let cachePolicy: ProductSyncRecordCachePolicy
  let identifierData: @Sendable (RecordID) -> Data
  let identifierPrefix: String

  init(
    identifierData: @escaping @Sendable (RecordID) -> Data,
    identifierPrefix: String,
    cachePolicy: ProductSyncRecordCachePolicy
  ) {
    self.identifierData = identifierData
    self.identifierPrefix = identifierPrefix
    self.cachePolicy = cachePolicy
  }
}

enum ProductSyncRecordBoundaryError: LocalizedError, Equatable {
  case incompletePagination
  case invalidPayloadIdentifier
  case missingProductSyncKeyMaterial
  case retryLimitExceeded

  var errorDescription: String? {
    switch self {
    case .incompletePagination:
      return "Encrypted Product Sync pagination ended before a complete scan."
    case .invalidPayloadIdentifier:
      return "Encrypted Product Sync payload identifier did not match its typed definition."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing synchronized data."
    case .retryLimitExceeded:
      return "Synchronized data kept changing. Reload and try again."
    }
  }
}

protocol ProductSyncRecordTransport {
  func listEncryptedProductSyncPayloads(
    session: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor: String?,
    limit: Int
  ) async throws -> EncryptedProductSyncPayloadPage

  func getEncryptedProductSyncPayloads(
    session: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload]

  func putEncryptedProductSyncPayloadIfUnchanged(
    session: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload
}

final class ProductSyncRecordBoundary {
  fileprivate static let exactReadBatchSize = 100
  static let listPageSize = 100
  fileprivate static let maximumConcurrentExactReads = 4
  fileprivate static let maximumWriteAttempts = 5

  let cache: ProductSyncCiphertextCaching?
  fileprivate let decoder = JSONDecoder()
  fileprivate let encoder = JSONEncoder()
  fileprivate let keyMaterialStore: ProductSyncKeyMaterialPersisting
  let lockRegistry = ProductSyncRecordLockRegistry()
  fileprivate let retryDelay: (Int) async throws -> Void
  let transport: ProductSyncRecordTransport

  init(
    cache: ProductSyncCiphertextCaching? = nil,
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    retryDelay: @escaping (Int) async throws -> Void = ProductSyncRecordBoundary.defaultRetryDelay,
    transport: ProductSyncRecordTransport = ConvexProductSyncRecordTransport()
  ) {
    self.cache = cache
    self.keyMaterialStore = keyMaterialStore
    self.retryDelay = retryDelay
    self.transport = transport
  }

  func singleton<Value: Codable & Sendable>(
    _ definition: ProductSyncSingletonDefinition<Value>
  ) -> ProductSyncSingletonHandle<Value> {
    ProductSyncSingletonHandle(boundary: self, definition: definition)
  }

  func validateWriteAccess(session: ProductAccountSessionSnapshot) throws {
    guard try keyMaterialStore.load(productAccountId: session.productAccountId) != nil else {
      throw ProductSyncRecordBoundaryError.missingProductSyncKeyMaterial
    }
  }

  func family<RecordID: Hashable & Sendable, Value: Codable & Sendable>(
    _ definition: ProductSyncRecordFamilyDefinition<RecordID, Value>
  ) -> ProductSyncRecordFamilyHandle<RecordID, Value> {
    ProductSyncRecordFamilyHandle(boundary: self, definition: definition)
  }

  func keyedFamily<RecordID: Hashable & Sendable, Value: Codable & Sendable>(
    _ definition: ProductSyncKeyedRecordFamilyDefinition<RecordID, Value>
  ) -> ProductSyncKeyedRecordFamilyHandle<RecordID, Value> {
    ProductSyncKeyedRecordFamilyHandle(boundary: self, definition: definition)
  }

  func readEncryptedPayloads(
    session: ProductAccountSessionSnapshot,
    identifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    let batches = stride(from: 0, to: identifiers.count, by: Self.exactReadBatchSize).map {
      Array(identifiers[$0..<min($0 + Self.exactReadBatchSize, identifiers.count)])
    }
    guard !batches.isEmpty else { return [] }

    return try await withThrowingTaskGroup(
      of: [EncryptedProductSyncPayload].self
    ) { group in
      var nextBatch = 0
      var payloads: [EncryptedProductSyncPayload] = []
      func addNextBatch() throws {
        try Task.checkCancellation()
        guard nextBatch < batches.count else { return }
        let batch = batches[nextBatch]
        nextBatch += 1
        group.addTask { [transport] in
          try Task.checkCancellation()
          return try await transport.getEncryptedProductSyncPayloads(
            session: session,
            payloadIdentifiers: batch
          )
        }
      }
      for _ in 0..<min(Self.maximumConcurrentExactReads, batches.count) {
        try addNextBatch()
      }
      while let batchPayloads = try await group.next() {
        payloads.append(contentsOf: batchPayloads)
        try addNextBatch()
      }
      return payloads
    }
  }

}

struct ProductSyncKeyedRecordFamilyHandle<
  RecordID: Hashable & Sendable,
  Value: Codable & Sendable
> {
  private let boundary: ProductSyncRecordBoundary
  private let definition: ProductSyncKeyedRecordFamilyDefinition<RecordID, Value>

  init(
    boundary: ProductSyncRecordBoundary,
    definition: ProductSyncKeyedRecordFamilyDefinition<RecordID, Value>
  ) {
    self.boundary = boundary
    self.definition = definition
  }

  func readValid(
    _ recordIds: [RecordID],
    session: ProductAccountSessionSnapshot
  ) async throws -> [ProductSyncRecord<Value>] {
    let identifiers = try identifiers(for: recordIds, session: session)
    let records = try await readRecords(
      identifiers: identifiers,
      session: session,
      skipsInvalidRecords: true
    )
    return identifiers.compactMap { records[$0] }
  }

  func update(
    _ recordId: RecordID,
    session: ProductAccountSessionSnapshot,
    decide: ([ProductSyncRecord<Value>]) async throws -> ProductSyncRecordUpdate<Value>
  ) async throws {
    let identifiers = try identifiers(for: [recordId], session: session)
    guard let primaryIdentifier = identifiers.first else { return }
    var records = try await readRecords(
      identifiers: identifiers,
      session: session,
      skipsInvalidRecords: false
    )
    for attempt in 1...ProductSyncRecordBoundary.maximumWriteAttempts {
      try Task.checkCancellation()
      switch try await decide(identifiers.compactMap { records[$0] }) {
      case .acceptAuthoritative:
        return
      case .write(let value):
        let writeIdentifiers =
          [primaryIdentifier]
          + identifiers.dropFirst().filter { records[$0] != nil }
        var foundConflict = false
        for identifier in writeIdentifiers {
          let result = try await singleton(for: identifier).writeIfUnchanged(
            value,
            expectedRevision: records[identifier]?.revision,
            session: session
          )
          switch result {
          case .committed(let record):
            records[identifier] = record
          case .conflict(let record):
            records[identifier] = record
            foundConflict = true
          }
          if foundConflict { break }
        }
        if !foundConflict { return }
      }
      guard attempt < ProductSyncRecordBoundary.maximumWriteAttempts else {
        throw ProductSyncRecordBoundaryError.retryLimitExceeded
      }
      try await boundary.retryDelay(attempt)
    }
    throw ProductSyncRecordBoundaryError.retryLimitExceeded
  }

  private func identifiers(
    for recordIds: [RecordID],
    session: ProductAccountSessionSnapshot
  ) throws -> [String] {
    guard
      let material = try boundary.keyMaterialStore.load(
        productAccountId: session.productAccountId
      )
    else {
      throw ProductSyncRecordBoundaryError.missingProductSyncKeyMaterial
    }
    let identifierKeys =
      [material.accountKeyData]
      + material.legacyAccountKeysData.sorted { $0.key > $1.key }.map(\.value)
    var seen: Set<String> = []
    var identifiers: [String] = []
    for recordId in recordIds {
      let identifierData = definition.identifierData(recordId)
      for keyData in identifierKeys {
        let digest = HMAC<SHA256>.authenticationCode(
          for: identifierData,
          using: SymmetricKey(data: keyData)
        )
        let identifier =
          definition.identifierPrefix
          + digest.map { String(format: "%02x", $0) }.joined()
        if seen.insert(identifier).inserted {
          identifiers.append(identifier)
        }
      }
    }
    return identifiers
  }

  private func readRecords(
    identifiers: [String],
    session: ProductAccountSessionSnapshot,
    skipsInvalidRecords: Bool
  ) async throws -> [String: ProductSyncRecord<Value>] {
    let requestedIdentifiers = Set(identifiers)
    let payloads = try await boundary.readEncryptedPayloads(
      session: session,
      identifiers: identifiers
    )
    var records: [String: ProductSyncRecord<Value>] = [:]
    for payload in payloads where requestedIdentifiers.contains(payload.payloadIdentifier) {
      try Task.checkCancellation()
      do {
        records[payload.payloadIdentifier] = try singleton(
          for: payload.payloadIdentifier
        ).decode(payload, session: session)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if !skipsInvalidRecords { throw error }
      }
    }
    return records
  }

  private func singleton(for identifier: String) -> ProductSyncSingletonHandle<Value> {
    boundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: identifier,
        cachePolicy: definition.cachePolicy
      )
    )
  }
}

struct ProductSyncSingletonHandle<Value: Codable & Sendable> {
  let boundary: ProductSyncRecordBoundary
  let definition: ProductSyncSingletonDefinition<Value>

  func read(
    session: ProductAccountSessionSnapshot
  ) async throws -> ProductSyncRecord<Value>? {
    let cachedPayloadBeforeRead: EncryptedProductSyncPayload? =
      if definition.cachePolicy.allowsCiphertextFallback {
        try? await boundary.cache?.load(
          productAccountId: session.productAccountId,
          payloadIdentifier: definition.identifier
        )
      } else {
        nil
      }
    do {
      guard let record = try await readAuthoritative(session: session) else {
        if definition.cachePolicy.allowsCiphertextFallback {
          try? await boundary.cache?.removeIfUnchanged(
            cachedPayloadBeforeRead,
            productAccountId: session.productAccountId,
            payloadIdentifier: definition.identifier
          )
        }
        return nil
      }
      if definition.cachePolicy.allowsCiphertextFallback {
        try? await saveToCache(record, session: session)
      }
      return record
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard
        definition.cachePolicy.allowsCiphertextFallback,
        let cached = try await boundary.cache?.load(
          productAccountId: session.productAccountId,
          payloadIdentifier: definition.identifier
        )
      else {
        throw error
      }
      return try decode(cached, session: session)
    }
  }

  func readAuthoritative(
    session: ProductAccountSessionSnapshot
  ) async throws -> ProductSyncRecord<Value>? {
    let payloads = try await boundary.readEncryptedPayloads(
      session: session,
      identifiers: [definition.identifier]
    )
    guard let payload = payloads.first(where: { $0.payloadIdentifier == definition.identifier })
    else {
      return nil
    }
    return try decode(payload, session: session)
  }

  func readAuthoritative<OtherValue: Codable & Sendable>(
    with other: ProductSyncSingletonHandle<OtherValue>,
    session: ProductAccountSessionSnapshot
  ) async throws -> (ProductSyncRecord<Value>?, ProductSyncRecord<OtherValue>?) {
    precondition(boundary === other.boundary)
    let payloads = try await boundary.readEncryptedPayloads(
      session: session,
      identifiers: [definition.identifier, other.definition.identifier]
    )
    let firstPayload = payloads.first { $0.payloadIdentifier == definition.identifier }
    let otherPayload = payloads.first { $0.payloadIdentifier == other.definition.identifier }
    return try (
      firstPayload.map { try decode($0, session: session) },
      otherPayload.map { try other.decode($0, session: session) }
    )
  }

  func update(
    session: ProductAccountSessionSnapshot,
    decide: (ProductSyncRecord<Value>?) async throws -> ProductSyncRecordUpdate<Value>
  ) async throws -> ProductSyncRecord<Value>? {
    try await withRecordLock(session: session) {
      try await performUpdate(session: session, decide: decide)
    }
  }

  private func withRecordLock<Result>(
    session: ProductAccountSessionSnapshot,
    operation: () async throws -> Result
  ) async throws -> Result {
    let lock = await boundary.lockRegistry.lock(
      for: ProductSyncRecordKey(
        productAccountId: session.productAccountId,
        payloadIdentifier: definition.identifier
      )
    )
    try await lock.acquire()
    do {
      let result = try await operation()
      await lock.release()
      return result
    } catch {
      await lock.release()
      throw error
    }
  }

  private func performUpdate(
    session: ProductAccountSessionSnapshot,
    decide: (ProductSyncRecord<Value>?) async throws -> ProductSyncRecordUpdate<Value>
  ) async throws -> ProductSyncRecord<Value>? {
    var current = try await read(session: session)
    for attempt in 1...ProductSyncRecordBoundary.maximumWriteAttempts {
      try Task.checkCancellation()
      switch try await decide(current) {
      case .acceptAuthoritative:
        return current
      case .write(let value):
        guard
          let material = try boundary.keyMaterialStore.load(
            productAccountId: session.productAccountId
          )
        else {
          throw ProductSyncRecordBoundaryError.missingProductSyncKeyMaterial
        }
        let plaintext = try boundary.encoder.encode(value)
        let encryptedPayload = try material.encryptPayload(
          plaintext,
          associatedData: Data(definition.identifier.utf8)
        )
        if definition.cachePolicy.invalidatesBeforeWrite {
          try await boundary.cache?.remove(
            productAccountId: session.productAccountId,
            payloadIdentifier: definition.identifier
          )
        }
        let written = try await boundary.transport.putEncryptedProductSyncPayloadIfUnchanged(
          session: session,
          payloadIdentifier: definition.identifier,
          encryptedPayload: encryptedPayload,
          expectedUpdatedAt: current?.revision.updatedAt
        )
        current = try decode(written, session: session)
        guard written.encryptedPayload != encryptedPayload else {
          if definition.cachePolicy.refreshesAfterCommit {
            try? await boundary.cache?.save(written, productAccountId: session.productAccountId)
          }
          return current
        }
        if definition.cachePolicy.allowsCiphertextFallback {
          try? await boundary.cache?.save(written, productAccountId: session.productAccountId)
        }
      }
      guard attempt < ProductSyncRecordBoundary.maximumWriteAttempts else {
        throw ProductSyncRecordBoundaryError.retryLimitExceeded
      }
      try await boundary.retryDelay(attempt)
    }
    throw ProductSyncRecordBoundaryError.retryLimitExceeded
  }

  func decode(
    _ payload: EncryptedProductSyncPayload,
    session: ProductAccountSessionSnapshot
  ) throws -> ProductSyncRecord<Value> {
    guard
      let material = try boundary.keyMaterialStore.load(
        productAccountId: session.productAccountId
      )
    else {
      throw ProductSyncRecordBoundaryError.missingProductSyncKeyMaterial
    }
    let plaintext = try material.decryptPayload(
      payload.encryptedPayload,
      associatedData: Data(definition.identifier.utf8)
    )
    return ProductSyncRecord(
      revision: ProductSyncRecordRevision(legacyUpdatedAt: payload.updatedAt),
      value: try boundary.decoder.decode(Value.self, from: plaintext)
    )
  }

  func saveToCache(
    _ record: ProductSyncRecord<Value>,
    session: ProductAccountSessionSnapshot
  ) async throws {
    guard
      let material = try boundary.keyMaterialStore.load(
        productAccountId: session.productAccountId
      )
    else {
      throw ProductSyncRecordBoundaryError.missingProductSyncKeyMaterial
    }
    let plaintext = try boundary.encoder.encode(record.value)
    let encryptedPayload = try material.encryptPayload(
      plaintext,
      associatedData: Data(definition.identifier.utf8)
    )
    try await boundary.cache?.save(
      EncryptedProductSyncPayload(
        encryptedPayload: encryptedPayload,
        payloadIdentifier: definition.identifier,
        updatedAt: record.revision.updatedAt
      ),
      productAccountId: session.productAccountId
    )
    try Task.checkCancellation()
  }
}

extension ProductSyncSingletonHandle {
  func writeIfUnchanged(
    _ value: Value,
    expectedRevision: ProductSyncRecordRevision?,
    session: ProductAccountSessionSnapshot
  ) async throws -> ProductSyncRecordConditionalWriteResult<Value> {
    try await withRecordLock(session: session) {
      try await performConditionalWrite(
        value,
        expectedRevision: expectedRevision,
        session: session
      )
    }
  }

  private func performConditionalWrite(
    _ value: Value,
    expectedRevision: ProductSyncRecordRevision?,
    session: ProductAccountSessionSnapshot
  ) async throws -> ProductSyncRecordConditionalWriteResult<Value> {
    guard
      let material = try boundary.keyMaterialStore.load(
        productAccountId: session.productAccountId
      )
    else {
      throw ProductSyncRecordBoundaryError.missingProductSyncKeyMaterial
    }
    let plaintext = try boundary.encoder.encode(value)
    let encryptedPayload = try material.encryptPayload(
      plaintext,
      associatedData: Data(definition.identifier.utf8)
    )
    if definition.cachePolicy.invalidatesBeforeWrite {
      try await boundary.cache?.remove(
        productAccountId: session.productAccountId,
        payloadIdentifier: definition.identifier
      )
    }
    let written = try await boundary.transport.putEncryptedProductSyncPayloadIfUnchanged(
      session: session,
      payloadIdentifier: definition.identifier,
      encryptedPayload: encryptedPayload,
      expectedUpdatedAt: expectedRevision?.updatedAt
    )
    let record = try decode(written, session: session)
    if written.encryptedPayload == encryptedPayload {
      if definition.cachePolicy.refreshesAfterCommit {
        try? await boundary.cache?.save(written, productAccountId: session.productAccountId)
      }
      return .committed(record)
    }
    if definition.cachePolicy.refreshesAfterConflict {
      try? await boundary.cache?.save(written, productAccountId: session.productAccountId)
    }
    return .conflict(record)
  }
}
