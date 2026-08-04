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
      var cursor: String?
      var payloads: [EncryptedProductSyncPayload] = []
      repeat {
        try Task.checkCancellation()
        let page = try await boundary.transport.listEncryptedProductSyncPayloads(
          session: session,
          payloadIdentifierPrefix: definition.identifierPrefix,
          cursor: cursor,
          limit: 100
        )
        for payload in page.page {
          try Task.checkCancellation()
          _ = try recordId(for: payload.payloadIdentifier)
          payloads.append(payload)
        }
        cursor = page.isDone ? nil : page.continueCursor
      } while cursor != nil
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

  func update(
    _ recordId: RecordID,
    session: ProductAccountSessionSnapshot,
    decide: (ProductSyncRecord<Value>?) throws -> ProductSyncRecordUpdate<Value>
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
