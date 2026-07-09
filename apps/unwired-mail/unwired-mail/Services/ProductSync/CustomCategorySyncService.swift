import Foundation

struct CustomCategory: Codable, Equatable, Identifiable {
  let id: String
  var name: String
  var description: String?

  init(
    id: String = CustomCategorySyncPayload.primaryIdentifier,
    name: String,
    description: String?
  ) {
    self.id = id
    self.name = name
    self.description = description?.isEmpty == true ? nil : description
  }
}

protocol ProductSyncPayloadTransport {
  func getEncryptedProductSyncPayload(
    identityToken: String,
    payloadIdentifier: String
  ) async throws -> EncryptedProductSyncPayload?
  func listEncryptedProductSyncPayloads(identityToken: String) async throws
    -> [EncryptedProductSyncPayload]
  func putEncryptedProductSyncPayload(
    identityToken: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId: String
  ) async throws -> EncryptedProductSyncPayload
}

protocol CustomCategorySyncing {
  func deleteCategory(session: ProductAccountSessionSnapshot) async throws
  func loadCategory(session: ProductAccountSessionSnapshot) async throws -> CustomCategory?
  func saveCategory(_ category: CustomCategory, session: ProductAccountSessionSnapshot) async throws
    -> CustomCategory
}

enum CustomCategorySyncError: LocalizedError, Equatable {
  case missingProductSyncKeyMaterial

  var errorDescription: String? {
    switch self {
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing this synced category."
    }
  }
}

struct CustomCategorySyncPayload: Codable, Equatable {
  static let primaryIdentifier = "custom-category-primary"

  let deleted: Bool
  let description: String?
  let name: String
  let schemaVersion: Int

  init(category: CustomCategory) {
    deleted = false
    description = category.description
    name = category.name
    schemaVersion = 1
  }

  init(deleted: Bool) {
    self.deleted = deleted
    description = nil
    name = ""
    schemaVersion = 1
  }

  var category: CustomCategory? {
    guard !deleted else {
      return nil
    }

    return CustomCategory(name: name, description: description)
  }
}

final class CustomCategorySyncService: CustomCategorySyncing {
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let transport: ProductSyncPayloadTransport

  init(
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    transport: ProductSyncPayloadTransport = ConvexClient()
  ) {
    self.keyMaterialStore = keyMaterialStore
    self.transport = transport
  }

  func loadCategory(session: ProductAccountSessionSnapshot) async throws -> CustomCategory? {
    guard let syncedPayload = try await loadRemotePayload(session: session) else {
      return nil
    }

    guard let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw CustomCategorySyncError.missingProductSyncKeyMaterial
    }
    let plaintext = try material.decryptPayload(
      syncedPayload.encryptedPayload,
      associatedData: associatedData
    )
    return try decoder.decode(CustomCategorySyncPayload.self, from: plaintext).category
  }

  @discardableResult
  func saveCategory(_ category: CustomCategory, session: ProductAccountSessionSnapshot) async throws
    -> CustomCategory
  {
    try await putPayload(CustomCategorySyncPayload(category: category), session: session)
    return category
  }

  func deleteCategory(session: ProductAccountSessionSnapshot) async throws {
    try await putPayload(CustomCategorySyncPayload(deleted: true), session: session)
  }

  private func putPayload(
    _ payload: CustomCategorySyncPayload,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let material = try await keyMaterialForWrite(session: session)
    let plaintext = try encoder.encode(payload)
    let encryptedPayload = try material.encryptPayload(plaintext, associatedData: associatedData)

    _ = try await transport.putEncryptedProductSyncPayload(
      identityToken: session.identityToken,
      payloadIdentifier: CustomCategorySyncPayload.primaryIdentifier,
      encryptedPayload: encryptedPayload,
      trustedDeviceId: session.trustedDeviceId
    )
  }

  private var associatedData: Data {
    Data(CustomCategorySyncPayload.primaryIdentifier.utf8)
  }

  private func keyMaterialForWrite(
    session: ProductAccountSessionSnapshot
  ) async throws -> ProductSyncKeyMaterial {
    if let material = try keyMaterialStore.load(productAccountId: session.productAccountId) {
      return material
    }

    if try await loadRemotePayload(session: session) != nil {
      throw CustomCategorySyncError.missingProductSyncKeyMaterial
    }

    return try keyMaterialStore.ensureMaterial(productAccountId: session.productAccountId)
  }

  private func loadRemotePayload(
    session: ProductAccountSessionSnapshot
  ) async throws -> EncryptedProductSyncPayload? {
    try await transport.getEncryptedProductSyncPayload(
      identityToken: session.identityToken,
      payloadIdentifier: CustomCategorySyncPayload.primaryIdentifier
    )
  }
}

extension ConvexClient: ProductSyncPayloadTransport {}
