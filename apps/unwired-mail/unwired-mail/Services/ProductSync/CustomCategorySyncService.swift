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

/// One normalized Custom Category name reserved for one Category identifier.
private struct CustomCategoryNameReservation: Codable, Equatable, Sendable {
  let categoryId: String
  let normalizedName: String
}

/// The profile-scoped atomic index that owns Custom Category name uniqueness.
private struct CustomCategoryNameReservationPayload: Codable, Equatable, Sendable {
  static let schemaVersion = 1

  let reservations: [CustomCategoryNameReservation]
  let schemaVersion: Int

  init(categories: [CustomCategory]) {
    reservations = categories.map {
      CustomCategoryNameReservation(
        categoryId: $0.id,
        normalizedName: CustomCategorySyncService.normalizedName($0.name)
      )
    }.sorted {
      if $0.normalizedName != $1.normalizedName {
        return $0.normalizedName < $1.normalizedName
      }
      return $0.categoryId < $1.categoryId
    }
    schemaVersion = Self.schemaVersion
  }
}

private struct CustomCategoryRecordSnapshot {
  let categoryRecords: [String: ProductSyncRecord<CustomCategoryCollectionPayload>]
  let legacyRecord: ProductSyncRecord<CustomCategorySyncPayload>?
  let nameReservations: ProductSyncRecord<CustomCategoryNameReservationPayload>?
}

private enum CustomCategoryMutation {
  case delete(String)
  case save(CustomCategory)
}

final class CustomCategorySyncService: CustomCategorySyncing {
  private static let configurationIdentifier = "category-configuration-primary"
  private static let legacyCollectionIdentifierPrefix = "custom-category-v2:"
  private static let maximumAtomicWriteAttempts = 5
  private static let nameReservationIdentifier = "custom-category-name-reservations-v1"
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
  private let nameReservationIdentifier: String
  private let nameReservationRecord:
    ProductSyncSingletonHandle<
      CustomCategoryNameReservationPayload
    >
  private let recordBoundary: ProductSyncRecordBoundary

  static func collectionPayloadIdentifier(
    _ categoryId: String,
    recordScope: MailProfileRecordScope
  ) -> String {
    payloadIdentifier(
      categoryId,
      identifierPrefix: recordScope.productSyncIdentifier(legacyCollectionIdentifierPrefix)
    )
  }

  static func copiedCollectionPayload(
    _ payload: EncryptedProductSyncPayload,
    destinationCategoryId: String,
    destinationIdentifier: String,
    boundary: ProductSyncRecordBoundary,
    session: ProductAccountSessionSnapshot
  ) throws -> ProductSyncEncryptedPayload {
    try boundary.reencryptedPayload(
      payload,
      as: destinationIdentifier,
      session: session
    ) { plaintext in
      let decoder = JSONDecoder()
      let source = try decoder.decode(CustomCategoryCollectionPayload.self, from: plaintext)
      let copied: CustomCategoryCollectionPayload
      if source.deleted {
        copied = CustomCategoryCollectionPayload(deletedCategoryId: destinationCategoryId)
      } else if let category = source.category {
        copied = CustomCategoryCollectionPayload(
          category: CustomCategory(
            id: destinationCategoryId,
            name: category.name,
            description: category.description,
            symbolName: category.symbolName,
            colorName: category.colorName,
            isEnabled: category.isEnabled
          )
        )
      } else {
        throw ProductSyncRecordBoundaryError.invalidPayloadIdentifier
      }
      return try JSONEncoder().encode(copied)
    }
  }

  init(
    recordScope: MailProfileRecordScope,
    backgroundContextCacheStore: BackgroundContextCachePersisting =
      KeychainBackgroundContextCacheStore(),
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary(),
    currentTimeMilliseconds: @escaping () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    }
  ) {
    self.backgroundContextCacheStore = backgroundContextCacheStore
    self.currentTimeMilliseconds = currentTimeMilliseconds
    self.recordBoundary = recordBoundary
    collectionIdentifierPrefix = recordScope.productSyncIdentifier(
      Self.legacyCollectionIdentifierPrefix
    )
    nameReservationIdentifier = recordScope.productSyncIdentifier(Self.nameReservationIdentifier)
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
    nameReservationRecord = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: nameReservationIdentifier,
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
      guard current.learningGeneration < Int.max else {
        throw CustomCategorySyncError.invalidPayload
      }
      return CategoryConfiguration(
        automaticCategorizationEnabled: current.automaticCategorizationEnabled,
        disabledSystemCategoryIds: current.disabledSystemCategoryIds,
        learningGeneration: current.learningGeneration + 1,
        learningResetAtMilliseconds: currentTimeMilliseconds()
      )
    }
  }

  func loadCategories(session: ProductAccountSessionSnapshot) async throws -> [CustomCategory] {
    do {
      return try await categories(after: nil, session: session)
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
      try legacyCategoryRecord.validateWriteAccess(session: session)
      try backgroundContextCacheStore.clear(productAccountId: session.productAccountId)
      _ = try await categories(after: .save(normalized), session: session)
      return normalized
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func deleteCategory(id: String, session: ProductAccountSessionSnapshot) async throws {
    do {
      try legacyCategoryRecord.validateWriteAccess(session: session)
      try backgroundContextCacheStore.clear(productAccountId: session.productAccountId)
      _ = try await categories(after: .delete(id), session: session)
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func deleteCategory(session: ProductAccountSessionSnapshot) async throws {
    try await deleteCategory(id: CustomCategorySyncPayload.primaryIdentifier, session: session)
  }

  private func categories(
    after mutation: CustomCategoryMutation?,
    session: ProductAccountSessionSnapshot
  ) async throws -> [CustomCategory] {
    for attempt in 1...Self.maximumAtomicWriteAttempts {
      try Task.checkCancellation()
      let snapshot = try await stableSnapshot(session: session)
      var categories = try reconciledCategories(snapshot)
      switch mutation {
      case .delete(let categoryId):
        categories.removeAll { $0.id == categoryId }
      case .save(let category):
        guard snapshot.categoryRecords[category.id]?.value.deleted != true else {
          throw CustomCategorySyncError.categoryWasDeleted
        }
        guard
          categories.contains(where: {
            $0.id != category.id
              && Self.normalizedName($0.name) == Self.normalizedName(category.name)
          }) == false
        else {
          throw CustomCategorySyncError.duplicateName
        }
        categories.removeAll { $0.id == category.id }
        categories.append(category)
      case nil:
        break
      }
      categories.sort(by: Self.categoriesAreOrdered)

      let transaction = try atomicTransaction(
        for: categories,
        mutation: mutation,
        snapshot: snapshot,
        session: session
      )
      guard transaction.writes.isEmpty == false else { return categories }
      try Task.checkCancellation()
      let result = try await recordBoundary.putEncryptedPayloadsAtomically(
        session: session,
        writes: transaction.writes,
        deletes: [],
        checks: transaction.checks
      )
      if result.committed { return categories }
      guard attempt < Self.maximumAtomicWriteAttempts else {
        throw ProductSyncRecordBoundaryError.retryLimitExceeded
      }
      try await ProductSyncRecordBoundary.defaultRetryDelay(afterAttempt: attempt)
    }
    throw ProductSyncRecordBoundaryError.retryLimitExceeded
  }

  private func stableSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> CustomCategoryRecordSnapshot {
    for attempt in 1...Self.maximumAtomicWriteAttempts {
      let reservationsBefore = try await nameReservationRecord.readAuthoritative(session: session)
      async let categoryRecords = categoryRecords.list(session: session)
      async let legacyRecord = legacyCategoryRecord.readAuthoritative(session: session)
      let (records, legacy) = try await (categoryRecords, legacyRecord)
      let reservationsAfter = try await nameReservationRecord.readAuthoritative(session: session)
      if reservationsBefore?.revision == reservationsAfter?.revision {
        if let reservationsAfter {
          try validateNameReservations(reservationsAfter.value)
        }
        return CustomCategoryRecordSnapshot(
          categoryRecords: records,
          legacyRecord: legacy,
          nameReservations: reservationsAfter
        )
      }
      guard attempt < Self.maximumAtomicWriteAttempts else {
        throw ProductSyncRecordBoundaryError.retryLimitExceeded
      }
      try await ProductSyncRecordBoundary.defaultRetryDelay(afterAttempt: attempt)
    }
    throw ProductSyncRecordBoundaryError.retryLimitExceeded
  }

  private func atomicTransaction(
    for categories: [CustomCategory],
    mutation: CustomCategoryMutation?,
    snapshot: CustomCategoryRecordSnapshot,
    session: ProductAccountSessionSnapshot
  ) throws -> (writes: [ProductSyncAtomicWrite], checks: [ProductSyncAtomicCheck]) {
    let writes = try atomicWrites(
      for: categories,
      mutation: mutation,
      snapshot: snapshot,
      session: session
    )
    return (
      writes, atomicChecks(snapshot: snapshot, excluding: Set(writes.map(\.payloadIdentifier)))
    )
  }

  // Keep all payloads that participate in the Category transaction visible together.
  // swiftlint:disable:next function_body_length
  private func atomicWrites(
    for categories: [CustomCategory],
    mutation: CustomCategoryMutation?,
    snapshot: CustomCategoryRecordSnapshot,
    session: ProductAccountSessionSnapshot
  ) throws -> [ProductSyncAtomicWrite] {
    var writes: [ProductSyncAtomicWrite] = []
    let reservations = CustomCategoryNameReservationPayload(categories: categories)
    let shouldWriteReservations =
      snapshot.nameReservations != nil || reservations.reservations.isEmpty == false
    if shouldWriteReservations, snapshot.nameReservations?.value != reservations {
      writes.append(
        ProductSyncAtomicWrite(
          encryptedPayload: try recordBoundary.encryptedPayload(
            for: reservations,
            identifier: nameReservationIdentifier,
            session: session
          ),
          expectedUpdatedAt: snapshot.nameReservations?.revision.legacyUpdatedAt,
          payloadIdentifier: nameReservationIdentifier
        ))
    }

    for category in categories {
      let payload = CustomCategoryCollectionPayload(category: category)
      guard snapshot.categoryRecords[category.id]?.value != payload else { continue }
      let identifier = Self.payloadIdentifier(
        category.id,
        identifierPrefix: collectionIdentifierPrefix
      )
      writes.append(
        ProductSyncAtomicWrite(
          encryptedPayload: try recordBoundary.encryptedPayload(
            for: payload,
            identifier: identifier,
            session: session
          ),
          expectedUpdatedAt: snapshot.categoryRecords[category.id]?.revision.legacyUpdatedAt,
          payloadIdentifier: identifier
        ))
    }

    if case .delete(let categoryId) = mutation {
      let payload = CustomCategoryCollectionPayload(deletedCategoryId: categoryId)
      if snapshot.categoryRecords[categoryId]?.value != payload {
        let identifier = Self.payloadIdentifier(
          categoryId,
          identifierPrefix: collectionIdentifierPrefix
        )
        writes.append(
          ProductSyncAtomicWrite(
            encryptedPayload: try recordBoundary.encryptedPayload(
              for: payload,
              identifier: identifier,
              session: session
            ),
            expectedUpdatedAt: snapshot.categoryRecords[categoryId]?.revision.legacyUpdatedAt,
            payloadIdentifier: identifier
          ))
      }
    }

    let legacyPayload: CustomCategorySyncPayload? =
      switch mutation {
      case .delete(CustomCategorySyncPayload.primaryIdentifier):
        CustomCategorySyncPayload(deleted: true)
      case .save(let category) where category.id == CustomCategorySyncPayload.primaryIdentifier:
        CustomCategorySyncPayload(category: category)
      default:
        nil
      }
    if let legacyPayload, snapshot.legacyRecord?.value != legacyPayload {
      writes.append(
        ProductSyncAtomicWrite(
          encryptedPayload: try recordBoundary.encryptedPayload(
            for: legacyPayload,
            identifier: legacyCategoryRecord.definition.identifier,
            session: session
          ),
          expectedUpdatedAt: snapshot.legacyRecord?.revision.legacyUpdatedAt,
          payloadIdentifier: legacyCategoryRecord.definition.identifier
        ))
    }
    return writes
  }

  private func atomicChecks(
    snapshot: CustomCategoryRecordSnapshot,
    excluding writtenIdentifiers: Set<String>
  ) -> [ProductSyncAtomicCheck] {
    let categoryRecords = snapshot.categoryRecords
    var checks: [ProductSyncAtomicCheck] = categoryRecords.compactMap { categoryId, record in
      let identifier = Self.payloadIdentifier(
        categoryId,
        identifierPrefix: collectionIdentifierPrefix
      )
      guard writtenIdentifiers.contains(identifier) == false else { return nil }
      return ProductSyncAtomicCheck(
        expectedUpdatedAt: record.revision.legacyUpdatedAt,
        payloadIdentifier: identifier
      )
    }
    if let reservations = snapshot.nameReservations,
      writtenIdentifiers.contains(nameReservationIdentifier) == false
    {
      checks.append(
        ProductSyncAtomicCheck(
          expectedUpdatedAt: reservations.revision.legacyUpdatedAt,
          payloadIdentifier: nameReservationIdentifier
        ))
    }
    if let legacy = snapshot.legacyRecord,
      writtenIdentifiers.contains(legacyCategoryRecord.definition.identifier) == false
    {
      checks.append(
        ProductSyncAtomicCheck(
          expectedUpdatedAt: legacy.revision.legacyUpdatedAt,
          payloadIdentifier: legacyCategoryRecord.definition.identifier
        ))
    }
    return checks
  }

  private func reconciledCategories(
    _ snapshot: CustomCategoryRecordSnapshot
  ) throws -> [CustomCategory] {
    var candidates: [String: (category: CustomCategory, updatedAt: Int64)] = [:]
    for (categoryId, record) in snapshot.categoryRecords {
      guard
        let category = try? validatedCategory(record.value, allowsReservedName: true)
      else { continue }
      candidates[categoryId] = (category, record.revision.legacyUpdatedAt)
    }
    if let legacyRecord = snapshot.legacyRecord,
      let legacyCategory = legacyRecord.value.category,
      shouldMigrateLegacy(
        legacyRecord: legacyRecord,
        collectionRecord: snapshot.categoryRecords[CustomCategorySyncPayload.primaryIdentifier]
      )
    {
      candidates[legacyCategory.id] = (
        try normalizedCategory(legacyCategory, allowsReservedName: true),
        legacyRecord.revision.legacyUpdatedAt
      )
    }

    var occupiedNames: Set<String> = []
    return try candidates.values.sorted {
      if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
      return $0.category.id < $1.category.id
    }.map { candidate in
      let category = try categoryWithUniqueName(
        candidate.category,
        occupiedNames: occupiedNames
      )
      occupiedNames.insert(Self.normalizedName(category.name))
      return category
    }.sorted(by: Self.categoriesAreOrdered)
  }

  private func validateNameReservations(
    _ payload: CustomCategoryNameReservationPayload
  ) throws {
    let categoryIds = Set(payload.reservations.map(\.categoryId))
    let names = Set(payload.reservations.map(\.normalizedName))
    guard
      payload.schemaVersion == CustomCategoryNameReservationPayload.schemaVersion,
      categoryIds.count == payload.reservations.count,
      names.count == payload.reservations.count,
      payload.reservations.allSatisfy({
        $0.categoryId.isEmpty == false
          && $0.normalizedName.isEmpty == false
          && Self.normalizedName($0.normalizedName) == $0.normalizedName
          && $0.normalizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            == $0.normalizedName
      })
    else {
      throw CustomCategorySyncError.invalidPayload
    }
  }

  private func updateConfiguration(
    session: ProductAccountSessionSnapshot,
    mutation: (CategoryConfiguration) throws -> CategoryConfiguration
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
      configuration.learningGeneration < Int.max,
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

  private func categoryWithUniqueName(
    _ category: CustomCategory,
    occupiedNames: Set<String>
  ) throws -> CustomCategory {
    let normalized = try normalizedCategory(category, allowsReservedName: true)
    let originalName = normalized.name
    guard
      Self.reservedNames.contains(Self.normalizedName(originalName))
        || occupiedNames.contains(Self.normalizedName(originalName))
    else { return normalized }

    var suffix = " (Custom)"
    var index = 2
    while true {
      let prefix = String(originalName.prefix(40 - suffix.count))
      let candidate = prefix + suffix
      let normalizedCandidate = Self.normalizedName(candidate)
      if !Self.reservedNames.contains(normalizedCandidate),
        !occupiedNames.contains(normalizedCandidate)
      {
        return try normalizedCategory(
          CustomCategory(
            id: normalized.id,
            name: candidate,
            description: normalized.description,
            symbolName: normalized.symbolName,
            colorName: normalized.colorName,
            isEnabled: normalized.isEnabled
          )
        )
      }
      suffix = " (Custom \(index))"
      index += 1
    }
  }

  private func validatedCategory(
    _ payload: CustomCategoryCollectionPayload,
    allowsReservedName: Bool = false
  ) throws -> CustomCategory? {
    guard
      payload.schemaVersion == CustomCategoryCollectionPayload.schemaVersion,
      payload.deleted || payload.category?.id == payload.categoryId
    else {
      throw CustomCategorySyncError.invalidPayload
    }
    guard !payload.deleted else { return nil }
    guard let category = payload.category else { throw CustomCategorySyncError.invalidPayload }
    return try normalizedCategory(category, allowsReservedName: allowsReservedName)
  }

  private func normalizedCategory(
    _ category: CustomCategory,
    allowsReservedName: Bool = false
  ) throws -> CustomCategory {
    let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...40).contains(name.count) else { throw CustomCategorySyncError.invalidName }
    guard
      allowsReservedName || !Self.reservedNames.contains(Self.normalizedName(name))
    else {
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

  fileprivate static func normalizedName(_ name: String) -> String {
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
