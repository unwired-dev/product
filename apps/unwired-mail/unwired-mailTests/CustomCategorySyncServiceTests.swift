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

  private func keyedStore() throws -> InMemoryProductSyncKeyMaterialStore {
    let store = InMemoryProductSyncKeyMaterialStore()
    _ = try store.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    return store
  }

  private func recordBoundary(
    keyMaterialStore: ProductSyncKeyMaterialPersisting,
    transport: ProductSyncRecordTransport
  ) -> ProductSyncRecordBoundary {
    ProductSyncRecordBoundary(keyMaterialStore: keyMaterialStore, transport: transport)
  }

  func testSaveUsesExistingProductSyncRecordIdentifier() async throws {
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      recordBoundary: recordBoundary(keyMaterialStore: try keyedStore(), transport: transport)
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
  }

  func testLoadDecryptsCategoryFromProductSync() async throws {
    let store = try keyedStore()
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      recordBoundary: recordBoundary(keyMaterialStore: store, transport: transport)
    )
    let savedCategory = CustomCategory(name: "Receipts", description: "Purchases")
    _ = try await service.saveCategory(savedCategory, session: session)

    let loadedCategory = try await service.loadCategory(session: session)

    XCTAssertEqual(loadedCategory, savedCategory)
  }

  func testDeletePersistsCategoryAsMissing() async throws {
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      recordBoundary: recordBoundary(keyMaterialStore: try keyedStore(), transport: transport)
    )
    _ = try await service.saveCategory(
      CustomCategory(name: "Finance", description: nil),
      session: session
    )
    let initialUpdatedAt = try XCTUnwrap(transport.writes.first?.updatedAt)

    try await service.deleteCategory(session: session)

    let loadedCategory = try await service.loadCategory(session: session)

    XCTAssertNil(loadedCategory)
    XCTAssertGreaterThan(try XCTUnwrap(transport.writes.first?.updatedAt), initialUpdatedAt)
  }

  func testCategoryWritesClearBackgroundCategorizationContext() async throws {
    let cacheStore = RecordingBackgroundContextCacheStore()
    let service = CustomCategorySyncService(
      backgroundContextCacheStore: cacheStore,
      recordBoundary: recordBoundary(
        keyMaterialStore: try keyedStore(),
        transport: RecordingProductSyncTransport()
      )
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
      recordBoundary: recordBoundary(keyMaterialStore: try keyedStore(), transport: transport)
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

  func testCategoryDeleteDoesNotReachProductSyncWhenBackgroundContextCannotBeCleared()
    async throws
  {
    let cacheStore = RecordingBackgroundContextCacheStore()
    cacheStore.clearError = KeychainStoreError.unexpectedData
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      backgroundContextCacheStore: cacheStore,
      recordBoundary: recordBoundary(keyMaterialStore: try keyedStore(), transport: transport)
    )

    do {
      try await service.deleteCategory(session: session)
      XCTFail("Expected background context clear failure")
    } catch {}

    XCTAssertTrue(transport.writes.isEmpty)
  }

  func testLoadExistingRemoteCategoryRequiresLocalKeyMaterial() async throws {
    let firstStore = try keyedStore()
    let transport = RecordingProductSyncTransport()
    let firstDeviceService = CustomCategorySyncService(
      recordBoundary: recordBoundary(keyMaterialStore: firstStore, transport: transport)
    )
    _ = try await firstDeviceService.saveCategory(
      CustomCategory(name: "Finance", description: nil),
      session: session
    )
    let freshDeviceService = CustomCategorySyncService(
      recordBoundary: recordBoundary(
        keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
        transport: transport
      )
    )

    do {
      _ = try await freshDeviceService.loadCategory(session: session)
      XCTFail("Expected missing Product Sync key material")
    } catch let error as CustomCategorySyncError {
      XCTAssertEqual(error, .missingProductSyncKeyMaterial)
    }
  }

  func testSaveWithoutRemoteCategoryRequiresLocalKeyMaterial() async throws {
    let store = InMemoryProductSyncKeyMaterialStore()
    let cacheStore = RecordingBackgroundContextCacheStore()
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      backgroundContextCacheStore: cacheStore,
      recordBoundary: recordBoundary(keyMaterialStore: store, transport: transport)
    )

    do {
      _ = try await service.saveCategory(
        CustomCategory(name: "Travel", description: nil),
        session: session
      )
      XCTFail("Expected missing Product Sync key material")
    } catch let error as CustomCategorySyncError {
      XCTAssertEqual(error, .missingProductSyncKeyMaterial)
    }

    XCTAssertEqual(store.saveCount, 0)
    XCTAssertTrue(cacheStore.clearedProductAccountIds.isEmpty)
    XCTAssertTrue(transport.writes.isEmpty)
  }

  func testDeleteWithoutRemoteCategoryRequiresLocalKeyMaterial() async throws {
    let store = InMemoryProductSyncKeyMaterialStore()
    let cacheStore = RecordingBackgroundContextCacheStore()
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      backgroundContextCacheStore: cacheStore,
      recordBoundary: recordBoundary(keyMaterialStore: store, transport: transport)
    )

    do {
      try await service.deleteCategory(session: session)
      XCTFail("Expected missing Product Sync key material")
    } catch let error as CustomCategorySyncError {
      XCTAssertEqual(error, .missingProductSyncKeyMaterial)
    }

    XCTAssertEqual(store.saveCount, 0)
    XCTAssertTrue(cacheStore.clearedProductAccountIds.isEmpty)
    XCTAssertTrue(transport.writes.isEmpty)
  }

  func testSaveDoesNotOverwriteRemoteCategoryWithoutLocalKeyMaterial() async throws {
    let firstStore = try keyedStore()
    let transport = RecordingProductSyncTransport()
    let firstDeviceService = CustomCategorySyncService(
      recordBoundary: recordBoundary(keyMaterialStore: firstStore, transport: transport)
    )
    _ = try await firstDeviceService.saveCategory(
      CustomCategory(name: "Finance", description: nil),
      session: session
    )
    let freshDeviceService = CustomCategorySyncService(
      recordBoundary: recordBoundary(
        keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
        transport: transport
      )
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

  func clear(productAccountId _: String, providerAccountIdentifier _: String) throws {}

  func load(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> BackgroundCategorizationContextCache? {
    nil
  }

  func save(
    _ cache: BackgroundCategorizationContextCache,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {}
}

private final class RecordingProductSyncTransport: ProductSyncRecordTransport {
  private var nextUpdatedAt: Int64 = 1_781_200_000_000
  private(set) var writes: [EncryptedProductSyncPayload] = []

  func listEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor _: String?,
    limit _: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    EncryptedProductSyncPayloadPage(
      continueCursor: "",
      isDone: true,
      page: writes.filter { $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) }
    )
  }

  func getEncryptedProductSyncPayloads(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    writes.filter { payloadIdentifiers.contains($0.payloadIdentifier) }
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    if let existing = writes.first(where: { $0.payloadIdentifier == payloadIdentifier }),
      existing.updatedAt != expectedUpdatedAt
    {
      return existing
    }
    nextUpdatedAt += 1
    let payload = EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: nextUpdatedAt
    )

    writes.removeAll { $0.payloadIdentifier == payloadIdentifier }
    writes.append(payload)
    return payload
  }
}
