import Foundation

struct ConvexProductSyncRecordTransport: ProductSyncRecordTransport {
  private let client: ConvexClient

  init(client: ConvexClient = ConvexClient()) {
    self.client = client
  }

  func listEncryptedProductSyncPayloads(
    session: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor: String?,
    limit: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    try await client.listEncryptedProductSyncPayloadPage(
      identityToken: session.identityToken,
      payloadIdentifierPrefix: payloadIdentifierPrefix,
      trustedDeviceId: session.trustedDeviceId,
      cursor: cursor,
      limit: limit
    )
  }

  func getEncryptedProductSyncPayloads(
    session: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    try await client.getEncryptedProductSyncPayloads(
      identityToken: session.identityToken,
      payloadIdentifiers: payloadIdentifiers,
      trustedDeviceId: session.trustedDeviceId
    )
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    try await client.putEncryptedProductSyncPayloadIfUnchanged(
      identityToken: session.identityToken,
      payloadIdentifier: payloadIdentifier,
      encryptedPayload: encryptedPayload,
      trustedDeviceId: session.trustedDeviceId,
      expectedUpdatedAt: expectedUpdatedAt
    )
  }
}

struct ProductSyncRecordKey: Hashable, Sendable {
  let payloadIdentifier: String
  private let productAccountId: String

  init(productAccountId: String, payloadIdentifier: String) {
    self.payloadIdentifier = payloadIdentifier
    self.productAccountId = productAccountId
  }

  func belongs(to productAccountId: String, prefix: String) -> Bool {
    self.productAccountId == productAccountId && payloadIdentifier.hasPrefix(prefix)
  }
}

private struct ProductSyncRecordFamilyKey: Hashable {
  let payloadIdentifierPrefix: String
  let productAccountId: String
}

actor ProductSyncRecordLockRegistry {
  private var locks: [ProductSyncRecordKey: ProductSyncRecordLock] = [:]

  func lock(for key: ProductSyncRecordKey) -> ProductSyncRecordLock {
    if let lock = locks[key] {
      return lock
    }
    let lock = ProductSyncRecordLock()
    locks[key] = lock
    return lock
  }
}

actor ProductSyncRecordLock {
  private var isHeld = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    guard isHeld else {
      isHeld = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    guard !waiters.isEmpty else {
      isHeld = false
      return
    }
    waiters.removeFirst().resume()
  }
}

#if DEBUG || TESTING
  actor InMemoryProductSyncCiphertextCache: ProductSyncCiphertextCaching {
    private var familySnapshots: Set<ProductSyncRecordFamilyKey> = []
    private var payloads: [ProductSyncRecordKey: EncryptedProductSyncPayload] = [:]

    func loadFamily(
      productAccountId: String,
      payloadIdentifierPrefix: String
    ) async throws -> [EncryptedProductSyncPayload]? {
      let familyKey = ProductSyncRecordFamilyKey(
        payloadIdentifierPrefix: payloadIdentifierPrefix,
        productAccountId: productAccountId
      )
      guard familySnapshots.contains(familyKey) else { return nil }
      return payloads.compactMap { key, payload in
        key.belongs(to: productAccountId, prefix: payloadIdentifierPrefix) ? payload : nil
      }
    }

    func load(
      productAccountId: String,
      payloadIdentifier: String
    ) async throws -> EncryptedProductSyncPayload? {
      payloads[
        ProductSyncRecordKey(
          productAccountId: productAccountId,
          payloadIdentifier: payloadIdentifier
        )
      ]
    }

    func remove(productAccountId: String, payloadIdentifier: String) async throws {
      payloads[
        ProductSyncRecordKey(
          productAccountId: productAccountId,
          payloadIdentifier: payloadIdentifier
        )
      ] = nil
    }

    func replaceFamily(
      _ familyPayloads: [EncryptedProductSyncPayload],
      productAccountId: String,
      payloadIdentifierPrefix: String
    ) async throws {
      payloads = payloads.filter { key, _ in
        !key.belongs(to: productAccountId, prefix: payloadIdentifierPrefix)
      }
      for payload in familyPayloads {
        payloads[
          ProductSyncRecordKey(
            productAccountId: productAccountId,
            payloadIdentifier: payload.payloadIdentifier
          )
        ] = payload
      }
      familySnapshots.insert(
        ProductSyncRecordFamilyKey(
          payloadIdentifierPrefix: payloadIdentifierPrefix,
          productAccountId: productAccountId
        )
      )
    }

    func save(_ payload: EncryptedProductSyncPayload, productAccountId: String) async throws {
      payloads[
        ProductSyncRecordKey(
          productAccountId: productAccountId,
          payloadIdentifier: payload.payloadIdentifier
        )
      ] = payload
    }
  }

  actor InMemoryProductSyncRecordTransport: ProductSyncRecordTransport {
    private let pageSize: Int
    private var payloads: [String: EncryptedProductSyncPayload] = [:]
    private var updatedAt: Int64 = 0

    init(pageSize: Int = 100) {
      self.pageSize = pageSize
    }

    func listEncryptedProductSyncPayloads(
      session _: ProductAccountSessionSnapshot,
      payloadIdentifierPrefix: String,
      cursor: String?,
      limit: Int
    ) async throws -> EncryptedProductSyncPayloadPage {
      let matching = payloads.values
        .filter { $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) }
        .sorted { $0.payloadIdentifier < $1.payloadIdentifier }
      let start = Int(cursor ?? "") ?? 0
      let end = min(start + min(pageSize, limit), matching.count)
      return EncryptedProductSyncPayloadPage(
        continueCursor: end == matching.count ? "" : String(end),
        isDone: end == matching.count,
        page: Array(matching[start..<end])
      )
    }

    func getEncryptedProductSyncPayloads(
      session _: ProductAccountSessionSnapshot,
      payloadIdentifiers: [String]
    ) async throws -> [EncryptedProductSyncPayload] {
      payloadIdentifiers.compactMap { payloads[$0] }
    }

    func putEncryptedProductSyncPayloadIfUnchanged(
      session _: ProductAccountSessionSnapshot,
      payloadIdentifier: String,
      encryptedPayload: ProductSyncEncryptedPayload,
      expectedUpdatedAt: Int64?
    ) async throws -> EncryptedProductSyncPayload {
      let existing = payloads[payloadIdentifier]
      guard existing?.updatedAt == expectedUpdatedAt else {
        guard let existing else {
          throw ProductSyncRecordBoundaryError.invalidPayloadIdentifier
        }
        return existing
      }
      updatedAt += 1
      let written = EncryptedProductSyncPayload(
        encryptedPayload: encryptedPayload,
        payloadIdentifier: payloadIdentifier,
        updatedAt: updatedAt
      )
      payloads[payloadIdentifier] = written
      return written
    }
  }
#endif
