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
}

private final class RecordingProductSyncTransport: ProductSyncPayloadTransport {
  private(set) var writeHistory: [EncryptedProductSyncPayload] = []
  private(set) var writes: [EncryptedProductSyncPayload] = []

  func listEncryptedProductSyncPayloads(identityToken: String) async throws
    -> [EncryptedProductSyncPayload]
  {
    _ = identityToken
    return writes
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
}
