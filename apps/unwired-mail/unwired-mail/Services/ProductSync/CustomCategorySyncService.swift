import Foundation

// swiftlint:disable file_length

struct CustomCategory: Codable, Equatable, Identifiable, Sendable {
  static let allowedColorNames = [
    "blue", "cyan", "green", "indigo", "orange", "pink", "purple", "red", "teal",
  ]
  static let allowedSymbolNames = [
    "bookmark.fill", "briefcase.fill", "cart.fill", "folder.fill", "heart.fill",
    "house.fill", "person.2.fill", "star.fill", "tag.fill", "tray.full.fill",
  ]

  let id: String
  var colorName: String
  var description: String?
  var isEnabled: Bool
  var name: String
  var symbolName: String

  init(
    id: String = CustomCategorySyncPayload.primaryIdentifier,
    name: String,
    description: String?,
    symbolName: String = "tag.fill",
    colorName: String = "blue",
    isEnabled: Bool = true
  ) {
    self.id = id
    self.colorName = colorName
    self.description = description?.isEmpty == true ? nil : description
    self.isEnabled = isEnabled
    self.name = name
    self.symbolName = symbolName
  }

  private enum CodingKeys: String, CodingKey {
    case colorName
    case description
    case id
    case isEnabled
    case name
    case symbolName
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id =
      try container.decodeIfPresent(String.self, forKey: .id)
      ?? CustomCategorySyncPayload.primaryIdentifier
    colorName = try container.decodeIfPresent(String.self, forKey: .colorName) ?? "blue"
    description = try container.decodeIfPresent(String.self, forKey: .description)
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    name = try container.decode(String.self, forKey: .name)
    symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName) ?? "tag.fill"
  }
}

protocol CustomCategorySyncing {
  func deleteCategory(id: String, session: ProductAccountSessionSnapshot) async throws
  func deleteCategory(session: ProductAccountSessionSnapshot) async throws
  func loadCategories(session: ProductAccountSessionSnapshot) async throws -> [CustomCategory]
  func loadCategory(session: ProductAccountSessionSnapshot) async throws -> CustomCategory?
  func saveCategory(_ category: CustomCategory, session: ProductAccountSessionSnapshot) async throws
    -> CustomCategory
}

extension CustomCategorySyncing {
  func deleteCategory(id: String, session: ProductAccountSessionSnapshot) async throws {
    guard id == CustomCategorySyncPayload.primaryIdentifier else {
      throw CustomCategorySyncError.invalidPayload
    }
    try await deleteCategory(session: session)
  }

  func loadCategories(session: ProductAccountSessionSnapshot) async throws -> [CustomCategory] {
    try await loadCategory(session: session).map { [$0] } ?? []
  }
}

enum CustomCategorySyncError: LocalizedError, Equatable {
  case categoryWasDeleted
  case descriptionIsTooLong
  case duplicateName
  case invalidAppearance
  case invalidName
  case invalidPayload
  case missingProductSyncKeyMaterial
  case syncRemainedBusy

  var errorDescription: String? {
    switch self {
    case .categoryWasDeleted:
      return "This Custom Category was deleted on another device."
    case .descriptionIsTooLong:
      return "Custom Category descriptions must contain at most 500 characters."
    case .duplicateName:
      return "Choose a name that is not already used by another Category."
    case .invalidAppearance:
      return "Choose a supported Custom Category icon and color."
    case .invalidName:
      return "Custom Category names must contain between 1 and 40 characters."
    case .invalidPayload:
      return "A synchronized Custom Category could not be verified."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing this synced category."
    case .syncRemainedBusy:
      return "Custom Categories changed on another device. Reload and try again."
    }
  }
}

/// The deployed singleton payload retained for mixed-version compatibility.
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
    guard !deleted else { return nil }
    return CustomCategory(name: name, description: description)
  }
}

private struct CustomCategoryCollectionPayload: Codable, Equatable, Sendable {
  static let schemaVersion = 2

  let category: CustomCategory?
  let categoryId: String
  let deleted: Bool
  let schemaVersion: Int

  init(category: CustomCategory) {
    self.category = category
    categoryId = category.id
    deleted = false
    schemaVersion = Self.schemaVersion
  }

  init(deletedCategoryId: String) {
    category = nil
    categoryId = deletedCategoryId
    deleted = true
    schemaVersion = Self.schemaVersion
  }
}

final class CustomCategorySyncService: CustomCategorySyncing {
  private static let collectionIdentifierPrefix = "custom-category-v2:"
  private static let reservedNames = Set([
    "all", "flights", "important", "invites", "newsletters & promotions", "orders", "people",
  ])

  private let backgroundContextCacheStore: BackgroundContextCachePersisting
  private let categoryRecords:
    ProductSyncRecordFamilyHandle<String, CustomCategoryCollectionPayload>
  private let legacyCategoryRecord: ProductSyncSingletonHandle<CustomCategorySyncPayload>

  init(
    backgroundContextCacheStore: BackgroundContextCachePersisting =
      KeychainBackgroundContextCacheStore(),
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()
  ) {
    self.backgroundContextCacheStore = backgroundContextCacheStore
    legacyCategoryRecord = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: CustomCategorySyncPayload.primaryIdentifier,
        cachePolicy: .authoritative
      )
    )
    categoryRecords = recordBoundary.family(
      ProductSyncRecordFamilyDefinition(
        identifier: { Self.payloadIdentifier($0) },
        identifierPrefix: Self.collectionIdentifierPrefix,
        recordId: { Self.categoryId($0) },
        cachePolicy: .authoritative
      )
    )
  }

  func loadCategories(session: ProductAccountSessionSnapshot) async throws -> [CustomCategory] {
    do {
      var records = try await categoryRecords.list(session: session)
      let legacyRecord = try await legacyCategoryRecord.read(session: session)
      if let legacyRecord,
        let legacyCategory = legacyRecord.value.category,
        shouldMigrateLegacy(
          legacyRecord: legacyRecord,
          collectionRecord: records[CustomCategorySyncPayload.primaryIdentifier]
        )
      {
        let category = migratedLegacyCategory(legacyCategory, collectionRecords: records)
        let migrated = try await writeCategory(category, session: session)
        if let migrated { records[category.id] = migrated }
      }
      return try records.values.compactMap { record in
        try validatedCategory(record.value)
      }.sorted(by: Self.categoriesAreOrdered)
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func loadCategory(session: ProductAccountSessionSnapshot) async throws -> CustomCategory? {
    let categories = try await loadCategories(session: session)
    return categories.first { $0.id == CustomCategorySyncPayload.primaryIdentifier }
      ?? categories.first
  }

  @discardableResult
  func saveCategory(_ category: CustomCategory, session: ProductAccountSessionSnapshot) async throws
    -> CustomCategory
  {
    do {
      let normalized = try normalizedCategory(category)
      let existingCategories = try await loadCategories(session: session)
      guard
        !existingCategories.contains(where: {
          $0.id != normalized.id
            && Self.normalizedName($0.name) == Self.normalizedName(normalized.name)
        })
      else {
        throw CustomCategorySyncError.duplicateName
      }
      try legacyCategoryRecord.validateWriteAccess(session: session)
      try backgroundContextCacheStore.clear(productAccountId: session.productAccountId)
      guard try await writeCategory(normalized, session: session) != nil else {
        throw CustomCategorySyncError.invalidPayload
      }
      if normalized.id == CustomCategorySyncPayload.primaryIdentifier {
        _ = try await legacyCategoryRecord.update(session: session) { _ in
          .write(CustomCategorySyncPayload(category: normalized))
        }
      }
      return normalized
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func deleteCategory(id: String, session: ProductAccountSessionSnapshot) async throws {
    do {
      try legacyCategoryRecord.validateWriteAccess(session: session)
      try backgroundContextCacheStore.clear(productAccountId: session.productAccountId)
      _ = try await categoryRecords.update(id, session: session) { current in
        if current?.value.deleted == true { return .acceptAuthoritative }
        return .write(CustomCategoryCollectionPayload(deletedCategoryId: id))
      }
      if id == CustomCategorySyncPayload.primaryIdentifier {
        _ = try await legacyCategoryRecord.update(session: session) { _ in
          .write(CustomCategorySyncPayload(deleted: true))
        }
      }
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func deleteCategory(session: ProductAccountSessionSnapshot) async throws {
    try await deleteCategory(id: CustomCategorySyncPayload.primaryIdentifier, session: session)
  }

  private func writeCategory(
    _ category: CustomCategory,
    session: ProductAccountSessionSnapshot
  ) async throws -> ProductSyncRecord<CustomCategoryCollectionPayload>? {
    try await categoryRecords.update(category.id, session: session) { current in
      guard current?.value.deleted != true else {
        throw CustomCategorySyncError.categoryWasDeleted
      }
      return .write(CustomCategoryCollectionPayload(category: category))
    }
  }

  private func shouldMigrateLegacy(
    legacyRecord: ProductSyncRecord<CustomCategorySyncPayload>,
    collectionRecord: ProductSyncRecord<CustomCategoryCollectionPayload>?
  ) -> Bool {
    guard let collectionRecord else { return true }
    return legacyRecord.revision.legacyUpdatedAt > collectionRecord.revision.legacyUpdatedAt
  }

  private func migratedLegacyCategory(
    _ category: CustomCategory,
    collectionRecords: [String: ProductSyncRecord<CustomCategoryCollectionPayload>]
  ) -> CustomCategory {
    let existingNames: Set<String> = Set(
      collectionRecords.compactMap { entry in
        guard entry.key != category.id else { return nil }
        guard !entry.value.value.deleted else { return nil }
        return entry.value.value.category.map { Self.normalizedName($0.name) }
      })
    let originalName = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      Self.reservedNames.contains(Self.normalizedName(originalName))
        || existingNames.contains(Self.normalizedName(originalName))
    else { return category }

    var suffix = " (Custom)"
    var index = 2
    while true {
      let prefix = String(originalName.prefix(40 - suffix.count))
      let candidate = prefix + suffix
      let normalizedCandidate = Self.normalizedName(candidate)
      if !Self.reservedNames.contains(normalizedCandidate),
        !existingNames.contains(normalizedCandidate)
      {
        return CustomCategory(
          id: category.id,
          name: candidate,
          description: category.description,
          symbolName: category.symbolName,
          colorName: category.colorName,
          isEnabled: category.isEnabled
        )
      }
      suffix = " (Custom \(index))"
      index += 1
    }
  }

  private func validatedCategory(
    _ payload: CustomCategoryCollectionPayload
  ) throws -> CustomCategory? {
    guard
      payload.schemaVersion == CustomCategoryCollectionPayload.schemaVersion,
      payload.deleted || payload.category?.id == payload.categoryId
    else {
      throw CustomCategorySyncError.invalidPayload
    }
    guard !payload.deleted else { return nil }
    guard let category = payload.category else { throw CustomCategorySyncError.invalidPayload }
    return try normalizedCategory(category)
  }

  private func normalizedCategory(_ category: CustomCategory) throws -> CustomCategory {
    let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...40).contains(name.count) else { throw CustomCategorySyncError.invalidName }
    guard !Self.reservedNames.contains(Self.normalizedName(name)) else {
      throw CustomCategorySyncError.duplicateName
    }
    let description = category.description?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (description?.count ?? 0) <= 500 else {
      throw CustomCategorySyncError.descriptionIsTooLong
    }
    guard
      CustomCategory.allowedSymbolNames.contains(category.symbolName),
      CustomCategory.allowedColorNames.contains(category.colorName)
    else {
      throw CustomCategorySyncError.invalidAppearance
    }
    return CustomCategory(
      id: category.id,
      name: name,
      description: description?.isEmpty == true ? nil : description,
      symbolName: category.symbolName,
      colorName: category.colorName,
      isEnabled: category.isEnabled
    )
  }

  private func mapBoundaryError(_ error: Error) -> Error {
    guard let boundaryError = error as? ProductSyncRecordBoundaryError else { return error }
    switch boundaryError {
    case .missingProductSyncKeyMaterial:
      return CustomCategorySyncError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      return CustomCategorySyncError.syncRemainedBusy
    case .incompletePagination, .invalidPayloadIdentifier:
      return CustomCategorySyncError.invalidPayload
    }
  }

  private static func normalizedName(_ name: String) -> String {
    name.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    ).lowercased()
  }

  private static func categoriesAreOrdered(_ lhs: CustomCategory, _ rhs: CustomCategory) -> Bool {
    let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
    if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
    return lhs.id < rhs.id
  }

  private static func payloadIdentifier(_ categoryId: String) -> String {
    collectionIdentifierPrefix
      + Data(categoryId.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func categoryId(_ payloadIdentifier: String) -> String? {
    guard payloadIdentifier.hasPrefix(collectionIdentifierPrefix) else { return nil }
    var encoded = String(payloadIdentifier.dropFirst(collectionIdentifierPrefix.count))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
