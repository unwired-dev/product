import Foundation

struct CustomCategory: Codable, Equatable, Identifiable, Sendable {
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

struct CustomCategorySyncPayload: Codable, Equatable, Sendable {
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
  private let backgroundContextCacheStore: BackgroundContextCachePersisting
  private let categoryRecord: ProductSyncSingletonHandle<CustomCategorySyncPayload>

  init(
    backgroundContextCacheStore: BackgroundContextCachePersisting =
      KeychainBackgroundContextCacheStore(),
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()
  ) {
    self.backgroundContextCacheStore = backgroundContextCacheStore
    categoryRecord = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: CustomCategorySyncPayload.primaryIdentifier,
        cachePolicy: .authoritative
      )
    )
  }

  func loadCategory(session: ProductAccountSessionSnapshot) async throws -> CustomCategory? {
    do {
      return try await categoryRecord.read(session: session)?.value.category
    } catch {
      throw mapBoundaryError(error)
    }
  }

  @discardableResult
  func saveCategory(_ category: CustomCategory, session: ProductAccountSessionSnapshot) async throws
    -> CustomCategory
  {
    do {
      try categoryRecord.validateWriteAccess(session: session)
      try backgroundContextCacheStore.clear(productAccountId: session.productAccountId)
      _ = try await categoryRecord.update(session: session) { _ in
        .write(CustomCategorySyncPayload(category: category))
      }
      return category
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func deleteCategory(session: ProductAccountSessionSnapshot) async throws {
    do {
      try categoryRecord.validateWriteAccess(session: session)
      try backgroundContextCacheStore.clear(productAccountId: session.productAccountId)
      _ = try await categoryRecord.update(session: session) { _ in
        .write(CustomCategorySyncPayload(deleted: true))
      }
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func mapBoundaryError(_ error: Error) -> Error {
    guard error as? ProductSyncRecordBoundaryError == .missingProductSyncKeyMaterial else {
      return error
    }
    return CustomCategorySyncError.missingProductSyncKeyMaterial
  }
}
