import Foundation
import XCTest

@testable import unwired_mail

final class CustomCategorySyncServiceTests: XCTestCase {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-preview",
    identityToken: "apple-token",
    productAccountId: "productAccountFixtureId",
    trustedDeviceId: "trustedDeviceFixtureId"
  )

  func testSaveEncryptsCategoryBeforeWritingToProductSync() async throws {
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      transport: transport
    )

    _ = try await service.saveCategory(
      CustomCategory(name: "Travel", description: "Trips and bookings"),
      session: session
    )

    XCTAssertEqual(transport.writes.count, 1)
    XCTAssertEqual(
      transport.writes[0].payloadIdentifier,
      CustomCategorySyncPayload.primaryIdentifier
    )
    XCTAssertFalse(transport.writes[0].encryptedPayload.ciphertextBase64.contains("Travel"))
    XCTAssertFalse(
      transport.writes[0].encryptedPayload.ciphertextBase64.contains("Trips and bookings")
    )
  }

  func testLoadDecryptsCategoryFromProductSync() async throws {
    let store = InMemoryProductSyncKeyMaterialStore()
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      keyMaterialStore: store,
      transport: transport
    )
    let savedCategory = CustomCategory(name: "Receipts", description: "Purchases")
    _ = try await service.saveCategory(savedCategory, session: session)

    let loadedCategory = try await service.loadCategory(session: session)

    XCTAssertEqual(loadedCategory, savedCategory)
  }

  func testDeleteWritesEncryptedTombstone() async throws {
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      transport: transport
    )
    _ = try await service.saveCategory(
      CustomCategory(name: "Finance", description: nil),
      session: session
    )

    try await service.deleteCategory(session: session)

    let loadedCategory = try await service.loadCategory(session: session)

    XCTAssertNil(loadedCategory)
    XCTAssertEqual(transport.writeHistory.count, 2)
  }

  func testCategoryWritesClearBackgroundCategorizationContext() async throws {
    let cacheStore = RecordingBackgroundContextCacheStore()
    let service = CustomCategorySyncService(
      backgroundContextCacheStore: cacheStore,
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      transport: RecordingProductSyncTransport()
    )

    _ = try await service.saveCategory(
      CustomCategory(name: "Finance", description: nil),
      session: session
    )
    try await service.deleteCategory(session: session)

    XCTAssertEqual(
      cacheStore.clearedProductAccountIds,
      [session.productAccountId, session.productAccountId]
    )
  }

  func testCategoryWriteDoesNotReachProductSyncWhenBackgroundContextCannotBeCleared()
    async throws
  {
    let cacheStore = RecordingBackgroundContextCacheStore()
    cacheStore.clearError = KeychainStoreError.unexpectedData
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      backgroundContextCacheStore: cacheStore,
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      transport: transport
    )

    do {
      _ = try await service.saveCategory(
        CustomCategory(name: "Finance", description: nil),
        session: session
      )
      XCTFail("Expected background context clear failure")
    } catch {}

    XCTAssertTrue(transport.writes.isEmpty)
  }

  func testLoadExistingRemoteCategoryRequiresLocalKeyMaterial() async throws {
    let firstStore = InMemoryProductSyncKeyMaterialStore()
    let transport = RecordingProductSyncTransport()
    let firstDeviceService = CustomCategorySyncService(
      keyMaterialStore: firstStore,
      transport: transport
    )
    _ = try await firstDeviceService.saveCategory(
      CustomCategory(name: "Finance", description: nil),
      session: session
    )
    let freshDeviceService = CustomCategorySyncService(
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      transport: transport
    )

    do {
      _ = try await freshDeviceService.loadCategory(session: session)
      XCTFail("Expected missing Product Sync key material")
    } catch let error as CustomCategorySyncError {
      XCTAssertEqual(error, .missingProductSyncKeyMaterial)
    }
  }

  func testSaveDoesNotOverwriteRemoteCategoryWithoutLocalKeyMaterial() async throws {
    let firstStore = InMemoryProductSyncKeyMaterialStore()
    let transport = RecordingProductSyncTransport()
    let firstDeviceService = CustomCategorySyncService(
      keyMaterialStore: firstStore,
      transport: transport
    )
    _ = try await firstDeviceService.saveCategory(
      CustomCategory(name: "Finance", description: nil),
      session: session
    )
    let freshDeviceService = CustomCategorySyncService(
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      transport: transport
    )

    do {
      _ = try await freshDeviceService.saveCategory(
        CustomCategory(name: "Travel", description: nil),
        session: session
      )
      XCTFail("Expected missing Product Sync key material")
    } catch let error as CustomCategorySyncError {
      XCTAssertEqual(error, .missingProductSyncKeyMaterial)
    }

    let loadedCategory = try await firstDeviceService.loadCategory(session: session)
    XCTAssertEqual(loadedCategory?.name, "Finance")
  }
}

private final class RecordingBackgroundContextCacheStore: BackgroundContextCachePersisting {
  private(set) var clearedProductAccountIds: [String] = []
  var clearError: Error?

  func clear(productAccountId: String) throws {
    if let clearError { throw clearError }
    clearedProductAccountIds.append(productAccountId)
  }

  func load(productAccountId _: String) throws -> BackgroundCategorizationContextCache? {
    nil
  }

  func save(
    _ cache: BackgroundCategorizationContextCache,
    productAccountId _: String
  ) throws {}
}

private final class RecordingProductSyncTransport: ProductSyncPayloadTransport {
  private(set) var writeHistory: [EncryptedProductSyncPayload] = []
  private(set) var writes: [EncryptedProductSyncPayload] = []

  func listEncryptedProductSyncPayloads(
    identityToken: String,
    payloadIdentifierPrefix: String?
  ) async throws
    -> [EncryptedProductSyncPayload]
  {
    _ = identityToken
    guard let payloadIdentifierPrefix else { return writes }
    return writes.filter { $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) }
  }

  func getEncryptedProductSyncPayload(
    identityToken: String,
    payloadIdentifier: String
  ) async throws -> EncryptedProductSyncPayload? {
    _ = identityToken
    return writes.first { $0.payloadIdentifier == payloadIdentifier }
  }

  func getEncryptedProductSyncPayloads(
    identityToken _: String,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    writes.filter { payloadIdentifiers.contains($0.payloadIdentifier) }
  }

  func putEncryptedProductSyncPayload(
    identityToken: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId: String
  ) async throws -> EncryptedProductSyncPayload {
    _ = identityToken
    _ = trustedDeviceId
    let payload = EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: 1_781_200_000_000
    )

    writes.removeAll { $0.payloadIdentifier == payloadIdentifier }
    writes.append(payload)
    writeHistory.append(payload)
    return payload
  }

  func putEncryptedProductSyncPayloadIfAbsent(
    identityToken: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId: String
  ) async throws -> EncryptedProductSyncPayload {
    if let existingPayload = writes.first(where: { $0.payloadIdentifier == payloadIdentifier }) {
      return existingPayload
    }
    return try await putEncryptedProductSyncPayload(
      identityToken: identityToken,
      payloadIdentifier: payloadIdentifier,
      encryptedPayload: encryptedPayload,
      trustedDeviceId: trustedDeviceId
    )
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    identityToken: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId: String,
    expectedUpdatedAt _: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    try await putEncryptedProductSyncPayload(
      identityToken: identityToken,
      payloadIdentifier: payloadIdentifier,
      encryptedPayload: encryptedPayload,
      trustedDeviceId: trustedDeviceId
    )
  }
}
