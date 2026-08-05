struct ProductSyncRecordFamilyDefinition<
  RecordID: Hashable & Sendable,
  Value: Codable & Sendable
>: Sendable {
  let cachePolicy: ProductSyncRecordCachePolicy
  let identifier: @Sendable (RecordID) -> String
  let identifierPrefix: String
  let recordId: @Sendable (String) -> RecordID?

  init(
    identifier: @escaping @Sendable (RecordID) -> String,
    identifierPrefix: String,
    recordId: @escaping @Sendable (String) -> RecordID?,
    cachePolicy: ProductSyncRecordCachePolicy
  ) {
    self.identifier = identifier
    self.identifierPrefix = identifierPrefix
    self.recordId = recordId
    self.cachePolicy = cachePolicy
  }
}

struct ProductSyncRecordFamilyHandle<
  RecordID: Hashable & Sendable,
  Value: Codable & Sendable
> {
  private let boundary: ProductSyncRecordBoundary
  private let definition: ProductSyncRecordFamilyDefinition<RecordID, Value>

  init(
    boundary: ProductSyncRecordBoundary,
    definition: ProductSyncRecordFamilyDefinition<RecordID, Value>
  ) {
    self.boundary = boundary
    self.definition = definition
  }

  func read(
    _ recordIds: [RecordID],
    session: ProductAccountSessionSnapshot
  ) async throws -> [RecordID: ProductSyncRecord<Value>] {
    let identifiers = recordIds.map(definition.identifier)
    do {
      let payloads = try await boundary.readEncryptedPayloads(
        session: session,
        identifiers: identifiers
      )
      if definition.cachePolicy.allowsCiphertextFallback {
        let returnedIdentifiers = Set(payloads.map(\.payloadIdentifier))
        for payload in payloads {
          try Task.checkCancellation()
          try? await boundary.cache?.save(payload, productAccountId: session.productAccountId)
        }
        for identifier in identifiers where !returnedIdentifiers.contains(identifier) {
          try Task.checkCancellation()
          try? await boundary.cache?.remove(
            productAccountId: session.productAccountId,
            payloadIdentifier: identifier
          )
        }
      }
      return try await decode(payloads, session: session)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard definition.cachePolicy.allowsCiphertextFallback else { throw error }
      var cachedPayloads: [EncryptedProductSyncPayload] = []
      for identifier in identifiers {
        try Task.checkCancellation()
        if let payload = try await boundary.cache?.load(
          productAccountId: session.productAccountId,
          payloadIdentifier: identifier
        ) {
          cachedPayloads.append(payload)
        }
      }
      guard !cachedPayloads.isEmpty else { throw error }
      return try await decode(cachedPayloads, session: session)
    }
  }

  func list(
    session: ProductAccountSessionSnapshot
  ) async throws -> [RecordID: ProductSyncRecord<Value>] {
    do {
      let payloads = try await listPayloads(session: session)
      if definition.cachePolicy.allowsCiphertextFallback {
        try? await boundary.cache?.replaceFamily(
          payloads,
          productAccountId: session.productAccountId,
          payloadIdentifierPrefix: definition.identifierPrefix
        )
      }
      return try await decode(payloads, session: session)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard
        definition.cachePolicy.allowsCiphertextFallback,
        let cachedPayloads = try await boundary.cache?.loadFamily(
          productAccountId: session.productAccountId,
          payloadIdentifierPrefix: definition.identifierPrefix
        )
      else {
        throw error
      }
      return try await decode(cachedPayloads, session: session)
    }
  }

  private func listPayloads(
    session: ProductAccountSessionSnapshot
  ) async throws -> [EncryptedProductSyncPayload] {
    var cursor: String?
    var payloads: [EncryptedProductSyncPayload] = []
    var visitedCursors: Set<String> = []
    repeat {
      try Task.checkCancellation()
      let page = try await boundary.transport.listEncryptedProductSyncPayloads(
        session: session,
        payloadIdentifierPrefix: definition.identifierPrefix,
        cursor: cursor,
        limit: ProductSyncRecordBoundary.listPageSize
      )
      for payload in page.page {
        try Task.checkCancellation()
        guard (try? recordId(for: payload.payloadIdentifier)) != nil else { continue }
        payloads.append(payload)
      }
      if page.isDone {
        cursor = nil
      } else {
        guard
          !page.continueCursor.isEmpty,
          visitedCursors.insert(page.continueCursor).inserted
        else {
          throw ProductSyncRecordBoundaryError.incompletePagination
        }
        cursor = page.continueCursor
      }
    } while cursor != nil
    return payloads
  }

  func update(
    _ recordId: RecordID,
    session: ProductAccountSessionSnapshot,
    decide: (ProductSyncRecord<Value>?) async throws -> ProductSyncRecordUpdate<Value>
  ) async throws -> ProductSyncRecord<Value>? {
    try await singleton(for: definition.identifier(recordId)).update(
      session: session,
      decide: decide
    )
  }

  private func decode(
    _ payloads: [EncryptedProductSyncPayload],
    session: ProductAccountSessionSnapshot
  ) async throws -> [RecordID: ProductSyncRecord<Value>] {
    var records: [RecordID: ProductSyncRecord<Value>] = [:]
    for payload in payloads {
      try Task.checkCancellation()
      let recordId = try recordId(for: payload.payloadIdentifier)
      records[recordId] = try singleton(for: payload.payloadIdentifier).decode(
        payload,
        session: session
      )
    }
    return records
  }

  private func recordId(for identifier: String) throws -> RecordID {
    guard
      identifier.hasPrefix(definition.identifierPrefix),
      let recordId = definition.recordId(identifier),
      definition.identifier(recordId) == identifier
    else {
      throw ProductSyncRecordBoundaryError.invalidPayloadIdentifier
    }
    return recordId
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

extension ProductSyncSingletonHandle {
  func validateWriteAccess(session: ProductAccountSessionSnapshot) throws {
    try boundary.validateWriteAccess(session: session)
  }

  func readRefreshingCache<OtherValue: Codable & Sendable>(
    with other: ProductSyncSingletonHandle<OtherValue>,
    session: ProductAccountSessionSnapshot,
    transform: (Value, OtherValue?) throws -> Value
  ) async throws -> (ProductSyncRecord<Value>?, ProductSyncRecord<OtherValue>?) {
    let cachedPayloadBeforeRead = try await loadCachedPayloadPreservingCancellation(
      session: session
    )
    let (record, otherRecord) = try await readAuthoritative(with: other, session: session)
    guard let record else {
      try await removeCachedPayloadPreservingCancellation(
        cachedPayloadBeforeRead,
        session: session
      )
      return (nil, otherRecord)
    }
    let transformed = ProductSyncRecord(
      revision: record.revision,
      value: try transform(record.value, otherRecord?.value)
    )
    try await saveToCachePreservingCancellation(transformed, session: session)
    return (transformed, otherRecord)
  }

  func readRefreshingCache(
    session: ProductAccountSessionSnapshot,
    transform: (Value) throws -> Value
  ) async throws -> ProductSyncRecord<Value>? {
    let cachedPayloadBeforeRead = try await loadCachedPayloadPreservingCancellation(
      session: session
    )
    guard let record = try await readAuthoritative(session: session) else {
      try await removeCachedPayloadPreservingCancellation(
        cachedPayloadBeforeRead,
        session: session
      )
      return nil
    }
    let transformed = ProductSyncRecord(
      revision: record.revision,
      value: try transform(record.value)
    )
    try await saveToCachePreservingCancellation(transformed, session: session)
    return transformed
  }

  private func loadCachedPayloadPreservingCancellation(
    session: ProductAccountSessionSnapshot
  ) async throws -> EncryptedProductSyncPayload? {
    do {
      return try await boundary.cache?.load(
        productAccountId: session.productAccountId,
        payloadIdentifier: definition.identifier
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return nil
    }
  }

  private func removeCachedPayloadPreservingCancellation(
    _ payload: EncryptedProductSyncPayload?,
    session: ProductAccountSessionSnapshot
  ) async throws {
    do {
      try await boundary.cache?.removeIfUnchanged(
        payload,
        productAccountId: session.productAccountId,
        payloadIdentifier: definition.identifier
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {}
  }

  private func saveToCachePreservingCancellation(
    _ record: ProductSyncRecord<Value>,
    session: ProductAccountSessionSnapshot
  ) async throws {
    do {
      try await saveToCache(record, session: session)
    } catch is CancellationError {
      throw CancellationError()
    } catch {}
  }

  func readCached(
    session: ProductAccountSessionSnapshot
  ) async throws -> ProductSyncRecord<Value>? {
    guard
      let cached = try await boundary.cache?.load(
        productAccountId: session.productAccountId,
        payloadIdentifier: definition.identifier
      )
    else {
      return nil
    }
    return try decode(cached, session: session)
  }

  func clearCache(session: ProductAccountSessionSnapshot) async {
    try? await boundary.cache?.remove(
      productAccountId: session.productAccountId,
      payloadIdentifier: definition.identifier
    )
  }

  func refreshCache(
    _ record: ProductSyncRecord<Value>,
    session: ProductAccountSessionSnapshot
  ) async {
    try? await saveToCache(record, session: session)
  }
}
