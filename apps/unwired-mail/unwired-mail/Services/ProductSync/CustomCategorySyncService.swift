import Foundation

// swiftlint:disable file_length type_body_length

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

struct SystemCategoryDefinition: Equatable, Identifiable, Sendable {
  let colorName: String
  let id: String
  let name: String
  let symbolName: String

  static let all = [
    SystemCategoryDefinition(
      colorName: "purple",
      id: "system:people",
      name: "People",
      symbolName: "person.2.fill"
    ),
    SystemCategoryDefinition(
      colorName: "blue",
      id: "system:invites",
      name: "Invites",
      symbolName: "calendar"
    ),
    SystemCategoryDefinition(
      colorName: "orange",
      id: "system:invoices",
      name: "Orders",
      symbolName: "cart.fill"
    ),
    SystemCategoryDefinition(
      colorName: "pink",
      id: "system:promotions",
      name: "Newsletters & Promotions",
      symbolName: "newspaper.fill"
    ),
    SystemCategoryDefinition(
      colorName: "teal",
      id: "system:flights",
      name: "Flights",
      symbolName: "airplane"
    ),
  ]
}

struct CategoryConfiguration: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1
  static let `default` = CategoryConfiguration()

  let automaticCategorizationEnabled: Bool
  let disabledSystemCategoryIds: [String]
  let learningGeneration: Int
  let learningResetAtMilliseconds: Int64?
  let schemaVersion: Int

  init(
    automaticCategorizationEnabled: Bool = true,
    disabledSystemCategoryIds: [String] = [],
    learningGeneration: Int = 0,
    learningResetAtMilliseconds: Int64? = nil
  ) {
    self.automaticCategorizationEnabled = automaticCategorizationEnabled
    self.disabledSystemCategoryIds = Array(Set(disabledSystemCategoryIds)).sorted()
    self.learningGeneration = learningGeneration
    self.learningResetAtMilliseconds = learningResetAtMilliseconds
    schemaVersion = Self.currentSchemaVersion
  }

  func isSystemCategoryEnabled(_ id: String) -> Bool {
    !disabledSystemCategoryIds.contains(id)
  }
}

protocol CustomCategorySyncing {
  func loadConfiguration(session: ProductAccountSessionSnapshot) async throws
    -> CategoryConfiguration
  func resetLearning(session: ProductAccountSessionSnapshot) async throws
    -> CategoryConfiguration
  func setAutomaticCategorizationEnabled(
    _ enabled: Bool,
    session: ProductAccountSessionSnapshot
  ) async throws -> CategoryConfiguration
  func setSystemCategoryEnabled(
    _ enabled: Bool,
    categoryId: String,
    session: ProductAccountSessionSnapshot
  ) async throws -> CategoryConfiguration
  func deleteCategory(id: String, session: ProductAccountSessionSnapshot) async throws
  func deleteCategory(session: ProductAccountSessionSnapshot) async throws
  func loadCategories(session: ProductAccountSessionSnapshot) async throws -> [CustomCategory]
  func loadCategory(session: ProductAccountSessionSnapshot) async throws -> CustomCategory?
  func saveCategory(_ category: CustomCategory, session: ProductAccountSessionSnapshot) async throws
    -> CustomCategory
}

extension CustomCategorySyncing {
  func loadConfiguration(session _: ProductAccountSessionSnapshot) async throws
    -> CategoryConfiguration
  {
    .default
  }

  func resetLearning(session _: ProductAccountSessionSnapshot) async throws
    -> CategoryConfiguration
  {
    .default
  }

  func setAutomaticCategorizationEnabled(
    _ enabled: Bool,
    session _: ProductAccountSessionSnapshot
  ) async throws -> CategoryConfiguration {
    CategoryConfiguration(automaticCategorizationEnabled: enabled)
  }

  func setSystemCategoryEnabled(
    _ enabled: Bool,
    categoryId: String,
    session _: ProductAccountSessionSnapshot
  ) async throws -> CategoryConfiguration {
    CategoryConfiguration(
      disabledSystemCategoryIds: enabled ? [] : [categoryId]
    )
  }

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
  private static let configurationIdentifier = "category-configuration-primary"
  private static let legacyCollectionIdentifierPrefix = "custom-category-v2:"
  private static let reservedNames = Set([
    "all", "flights", "important", "invites", "newsletters & promotions", "orders", "people",
  ])

  private let backgroundContextCacheStore: BackgroundContextCachePersisting
  private let categoryRecords:
    ProductSyncRecordFamilyHandle<String, CustomCategoryCollectionPayload>
  private let configurationRecord: ProductSyncSingletonHandle<CategoryConfiguration>
  private let currentTimeMilliseconds: () -> Int64
  private let legacyCategoryRecord: ProductSyncSingletonHandle<CustomCategorySyncPayload>
  private let collectionIdentifierPrefix: String

  init(
    backgroundContextCacheStore: BackgroundContextCachePersisting =
      KeychainBackgroundContextCacheStore(),
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary(),
    recordScope: MailProfileRecordScope = .legacyProductAccount,
    currentTimeMilliseconds: @escaping () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    }
  ) {
    self.backgroundContextCacheStore = backgroundContextCacheStore
    self.currentTimeMilliseconds = currentTimeMilliseconds
    collectionIdentifierPrefix = recordScope.productSyncIdentifier(
      Self.legacyCollectionIdentifierPrefix
    )
    configurationRecord = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: recordScope.productSyncIdentifier(Self.configurationIdentifier),
        cachePolicy: .authoritative
      )
    )
    legacyCategoryRecord = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: recordScope.productSyncIdentifier(CustomCategorySyncPayload.primaryIdentifier),
        cachePolicy: .authoritative
      )
    )
    categoryRecords = recordBoundary.family(
      ProductSyncRecordFamilyDefinition(
        identifier: { [collectionIdentifierPrefix] in
          Self.payloadIdentifier($0, identifierPrefix: collectionIdentifierPrefix)
        },
        identifierPrefix: collectionIdentifierPrefix,
        recordId: { [collectionIdentifierPrefix] in
          Self.categoryId($0, identifierPrefix: collectionIdentifierPrefix)
        },
        cachePolicy: .authoritative
      )
    )
  }

  func loadConfiguration(session: ProductAccountSessionSnapshot) async throws
    -> CategoryConfiguration
  {
    do {
      let configuration = try await configurationRecord.read(session: session)?.value ?? .default
      return try validatedConfiguration(configuration)
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func setAutomaticCategorizationEnabled(
    _ enabled: Bool,
    session: ProductAccountSessionSnapshot
  ) async throws -> CategoryConfiguration {
    try await updateConfiguration(session: session) { current in
      CategoryConfiguration(
        automaticCategorizationEnabled: enabled,
        disabledSystemCategoryIds: current.disabledSystemCategoryIds,
        learningGeneration: current.learningGeneration,
        learningResetAtMilliseconds: current.learningResetAtMilliseconds
      )
    }
  }

  func setSystemCategoryEnabled(
    _ enabled: Bool,
    categoryId: String,
    session: ProductAccountSessionSnapshot
  ) async throws -> CategoryConfiguration {
    guard SystemCategoryDefinition.all.contains(where: { $0.id == categoryId }) else {
      throw CustomCategorySyncError.invalidPayload
    }
    return try await updateConfiguration(session: session) { current in
      var disabledIds = Set(current.disabledSystemCategoryIds)
      if enabled {
        disabledIds.remove(categoryId)
      } else {
        disabledIds.insert(categoryId)
      }
      return CategoryConfiguration(
        automaticCategorizationEnabled: current.automaticCategorizationEnabled,
        disabledSystemCategoryIds: Array(disabledIds),
        learningGeneration: current.learningGeneration,
        learningResetAtMilliseconds: current.learningResetAtMilliseconds
      )
    }
  }

  func resetLearning(session: ProductAccountSessionSnapshot) async throws
    -> CategoryConfiguration
  {
    try await updateConfiguration(session: session) { current in
      CategoryConfiguration(
        automaticCategorizationEnabled: current.automaticCategorizationEnabled,
        disabledSystemCategoryIds: current.disabledSystemCategoryIds,
        learningGeneration: current.learningGeneration + 1,
        learningResetAtMilliseconds: currentTimeMilliseconds()
      )
    }
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
        let category = try normalizedCategory(
          migratedLegacyCategory(legacyCategory, collectionRecords: records)
        )
        let migrated = try await writeCategory(category, session: session)
        if let migrated { records[category.id] = migrated }
      }
      return records.values.compactMap { record in
        try? validatedCategory(record.value)
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

  private func updateConfiguration(
    session: ProductAccountSessionSnapshot,
    mutation: (CategoryConfiguration) -> CategoryConfiguration
  ) async throws -> CategoryConfiguration {
    do {
      try backgroundContextCacheStore.clear(productAccountId: session.productAccountId)
      let record = try await configurationRecord.update(session: session) { current in
        .write(try self.validatedConfiguration(mutation(current?.value ?? .default)))
      }
      guard let record else { throw CustomCategorySyncError.invalidPayload }
      return try validatedConfiguration(record.value)
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func validatedConfiguration(
    _ configuration: CategoryConfiguration
  ) throws -> CategoryConfiguration {
    let systemCategoryIds = Set(SystemCategoryDefinition.all.map(\.id))
    guard
      configuration.schemaVersion == CategoryConfiguration.currentSchemaVersion,
      configuration.learningGeneration >= 0,
      Set(configuration.disabledSystemCategoryIds).isSubset(of: systemCategoryIds)
    else {
      throw CustomCategorySyncError.invalidPayload
    }
    return CategoryConfiguration(
      automaticCategorizationEnabled: configuration.automaticCategorizationEnabled,
      disabledSystemCategoryIds: configuration.disabledSystemCategoryIds,
      learningGeneration: configuration.learningGeneration,
      learningResetAtMilliseconds: configuration.learningResetAtMilliseconds
    )
  }

  private func shouldMigrateLegacy(
    legacyRecord: ProductSyncRecord<CustomCategorySyncPayload>,
    collectionRecord: ProductSyncRecord<CustomCategoryCollectionPayload>?
  ) -> Bool {
    guard collectionRecord?.value.deleted != true else { return false }
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

  private static func payloadIdentifier(
    _ categoryId: String,
    identifierPrefix: String
  ) -> String {
    identifierPrefix
      + Data(categoryId.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func categoryId(
    _ payloadIdentifier: String,
    identifierPrefix: String
  ) -> String? {
    guard payloadIdentifier.hasPrefix(identifierPrefix) else { return nil }
    var encoded = String(payloadIdentifier.dropFirst(identifierPrefix.count))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
