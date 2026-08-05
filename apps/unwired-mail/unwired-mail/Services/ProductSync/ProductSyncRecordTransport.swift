import Foundation

extension ProductSyncRecordBoundary {
  static func defaultRetryDelay(afterAttempt attempt: Int) async throws {
    try Task.checkCancellation()
    let milliseconds = min(50 * (1 << max(0, attempt - 1)), 800)
    try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
  }
}

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

struct ProductSyncPayloadRecordTransport: ProductSyncRecordTransport {
  private let transport: ProductSyncPayloadTransport

  init(_ transport: ProductSyncPayloadTransport) {
    self.transport = transport
  }

  func listEncryptedProductSyncPayloads(
    session: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor: String?,
    limit: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    let payloads = try await transport.listEncryptedProductSyncPayloads(
      identityToken: session.identityToken,
      payloadIdentifierPrefix: payloadIdentifierPrefix,
      trustedDeviceId: session.trustedDeviceId
    )
    .filter { $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) }
    .sorted { $0.payloadIdentifier < $1.payloadIdentifier }
    guard limit > 0 else {
      return EncryptedProductSyncPayloadPage(continueCursor: "", isDone: true, page: [])
    }
    let requestedStart = Int(cursor ?? "") ?? 0
    let start = min(max(requestedStart, 0), payloads.count)
    let end = start + min(limit, payloads.count - start)
    return EncryptedProductSyncPayloadPage(
      continueCursor: end == payloads.count ? "" : String(end),
      isDone: end == payloads.count,
      page: Array(payloads[start..<end])
    )
  }

  func getEncryptedProductSyncPayloads(
    session: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    return try await transport.getEncryptedProductSyncPayloads(
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
    try await transport.putEncryptedProductSyncPayloadIfUnchanged(
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
  private struct Waiter {
    let continuation: CheckedContinuation<Bool, Never>
    let id: UUID
  }

  private var isHeld = false
  private var queuedObservers: [CheckedContinuation<Void, Never>] = []
  private var waiters: [Waiter] = []

  func acquire() async throws {
    try Task.checkCancellation()
    guard isHeld else {
      isHeld = true
      return
    }
    let waiterId = UUID()
    let acquired = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        waiters.append(Waiter(continuation: continuation, id: waiterId))
        let observers = queuedObservers
        queuedObservers.removeAll()
        for observer in observers { observer.resume() }
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterId) }
    }
    guard acquired else { throw CancellationError() }
    if Task.isCancelled {
      release()
      throw CancellationError()
    }
  }

  func waitUntilQueued() async {
    guard waiters.isEmpty else { return }
    await withCheckedContinuation { queuedObservers.append($0) }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(returning: false)
  }

  func release() {
    guard !waiters.isEmpty else {
      isHeld = false
      return
    }
    waiters.removeFirst().continuation.resume(returning: true)
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

    func removeIfUnchanged(
      _ payload: EncryptedProductSyncPayload?,
      productAccountId: String,
      payloadIdentifier: String
    ) async throws {
      let key = ProductSyncRecordKey(
        productAccountId: productAccountId,
        payloadIdentifier: payloadIdentifier
      )
      guard payloads[key] == payload else { return }
      payloads[key] = nil
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
    private var payloads: [ProductSyncRecordKey: EncryptedProductSyncPayload] = [:]
    private var updatedAt: Int64 = 0

    init(pageSize: Int = 100) {
      self.pageSize = pageSize
    }

    func listEncryptedProductSyncPayloads(
      session: ProductAccountSessionSnapshot,
      payloadIdentifierPrefix: String,
      cursor: String?,
      limit: Int
    ) async throws -> EncryptedProductSyncPayloadPage {
      let matching = payloads.compactMap { key, payload in
        key.belongs(to: session.productAccountId, prefix: payloadIdentifierPrefix)
          ? payload
          : nil
      }
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
      session: ProductAccountSessionSnapshot,
      payloadIdentifiers: [String]
    ) async throws -> [EncryptedProductSyncPayload] {
      payloadIdentifiers.compactMap {
        payloads[
          ProductSyncRecordKey(
            productAccountId: session.productAccountId,
            payloadIdentifier: $0
          )
        ]
      }
    }

    func putEncryptedProductSyncPayloadIfUnchanged(
      session: ProductAccountSessionSnapshot,
      payloadIdentifier: String,
      encryptedPayload: ProductSyncEncryptedPayload,
      expectedUpdatedAt: Int64?
    ) async throws -> EncryptedProductSyncPayload {
      let key = ProductSyncRecordKey(
        productAccountId: session.productAccountId,
        payloadIdentifier: payloadIdentifier
      )
      let existing = payloads[key]
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
      payloads[key] = written
      return written
    }
  }
#endif
