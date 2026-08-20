import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

@Suite(.serialized)
final class CustomCategorySyncServiceTests {
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

  @Test
  func testCategoryConfigurationDefaultsToAutomaticSystemCategorization() async throws {
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: recordBoundary(
        keyMaterialStore: try keyedStore(),
        transport: RecordingProductSyncTransport()
      )
    )

    let configuration = try await service.loadConfiguration(session: session)

    #expect(configuration == .default)
    #expect(
      SystemCategoryDefinition.all.allSatisfy {
        configuration.isSystemCategoryEnabled($0.id)
      })
  }

  @Test
  func testCategoryConfigurationUpdatesMergeIndependentControls() async throws {
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: recordBoundary(
        keyMaterialStore: try keyedStore(),
        transport: RecordingProductSyncTransport()
      )
    )

    _ = try await service.setSystemCategoryEnabled(
      false,
      categoryId: "system:people",
      session: session
    )
    let configuration = try await service.setAutomaticCategorizationEnabled(
      false,
      session: session
    )

    #expect(!configuration.automaticCategorizationEnabled)
    #expect(!configuration.isSystemCategoryEnabled("system:people"))
    #expect(configuration.isSystemCategoryEnabled("system:flights"))
  }

  @Test
  func testLearningResetAdvancesGenerationAndInvalidatesBackgroundContext() async throws {
    let cacheStore = RecordingBackgroundContextCacheStore()
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      backgroundContextCacheStore: cacheStore,
      recordBoundary: recordBoundary(
        keyMaterialStore: try keyedStore(),
        transport: RecordingProductSyncTransport()
      ),
      currentTimeMilliseconds: { 1_786_464_000_000 }
    )

    let first = try await service.resetLearning(session: session)
    let second = try await service.resetLearning(session: session)

    #expect(first.learningGeneration == 1)
    #expect(second.learningGeneration == 2)
    #expect(second.learningResetAtMilliseconds == 1_786_464_000_000)
    #expect(
      cacheStore.clearedProductAccountIds == [
        session.productAccountId, session.productAccountId,
      ])
  }

  @Test
  func testLearningResetRejectsMaximumGenerationBeforeIncrementing() async throws {
    let boundary = recordBoundary(
      keyMaterialStore: try keyedStore(),
      transport: RecordingProductSyncTransport()
    )
    let configurationRecord = boundary.singleton(
      ProductSyncSingletonDefinition<CategoryConfiguration>(
        identifier: "category-configuration-primary",
        cachePolicy: .authoritative
      )
    )
    _ = try await configurationRecord.update(session: session) { _ in
      .write(CategoryConfiguration(learningGeneration: Int.max))
    }
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: boundary
    )

    await #expect(throws: CustomCategorySyncError.invalidPayload) {
      try await service.resetLearning(session: session)
    }
  }

  @Test
  func testCategoryRecordsCanUseANonDefaultProfileScope() async throws {
    let transport = RecordingProductSyncTransport()
    let profileId = MailProfileId(rawValue: "profile-fixture")
    let service = CustomCategorySyncService(
      recordScope: .profile(profileId),
      recordBoundary: recordBoundary(keyMaterialStore: try keyedStore(), transport: transport)
    )

    _ = try await service.saveCategory(
      CustomCategory(id: "custom:travel", name: "Travel", description: nil),
      session: session
    )
    _ = try await service.setAutomaticCategorizationEnabled(false, session: session)

    #expect(
      transport.writes.allSatisfy {
        $0.payloadIdentifier.hasPrefix("mail-profile-v1.profile-fixture.")
      })
  }

  @Test(
    "Category state is isolated between Profiles",
    .bug("https://github.com/unwired-dev/product/issues/450")
  )
  func categoryStateIsIsolatedBetweenProfiles() async throws {
    let transport = RecordingProductSyncTransport()
    let keyMaterialStore = try keyedStore()
    let cacheStore = RecordingBackgroundContextCacheStore()
    let firstService = CustomCategorySyncService(
      recordScope: .profile(MailProfileId(rawValue: "profile-work")),
      backgroundContextCacheStore: cacheStore,
      recordBoundary: recordBoundary(keyMaterialStore: keyMaterialStore, transport: transport)
    )
    let secondService = CustomCategorySyncService(
      recordScope: .profile(MailProfileId(rawValue: "profile-personal")),
      backgroundContextCacheStore: cacheStore,
      recordBoundary: recordBoundary(keyMaterialStore: keyMaterialStore, transport: transport)
    )

    _ = try await firstService.setAutomaticCategorizationEnabled(false, session: session)
    _ = try await firstService.resetLearning(session: session)
    _ = try await firstService.saveCategory(
      CustomCategory(id: "custom:work", name: "Work", description: nil),
      session: session
    )

    #expect(try await secondService.loadConfiguration(session: session) == .default)
    #expect(try await secondService.loadCategories(session: session).isEmpty)

    _ = try await secondService.setSystemCategoryEnabled(
      false,
      categoryId: "system:people",
      session: session
    )
    _ = try await secondService.resetLearning(session: session)
    _ = try await secondService.resetLearning(session: session)
    _ = try await secondService.saveCategory(
      CustomCategory(id: "custom:personal", name: "Personal", description: nil),
      session: session
    )

    let firstConfiguration = try await firstService.loadConfiguration(session: session)
    let secondConfiguration = try await secondService.loadConfiguration(session: session)
    #expect(firstConfiguration.automaticCategorizationEnabled == false)
    #expect(firstConfiguration.isSystemCategoryEnabled("system:people"))
    #expect(firstConfiguration.learningGeneration == 1)
    #expect(try await firstService.loadCategories(session: session).map(\.id) == ["custom:work"])
    #expect(secondConfiguration.automaticCategorizationEnabled)
    #expect(secondConfiguration.isSystemCategoryEnabled("system:people") == false)
    #expect(secondConfiguration.learningGeneration == 2)
    #expect(
      try await secondService.loadCategories(session: session).map(\.id) == ["custom:personal"]
    )
  }

  @Test
  func testSaveUsesExistingProductSyncRecordIdentifier() async throws {
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: recordBoundary(keyMaterialStore: try keyedStore(), transport: transport)
    )

    _ = try await service.saveCategory(
      CustomCategory(name: "Travel", description: "Trips and bookings"),
      session: session
    )

    #expect(transport.writes.count == 2)
    #expect(
      Set(transport.writes.map(\.payloadIdentifier)) == [
        CustomCategorySyncPayload.primaryIdentifier,
        "custom-category-v2:Y3VzdG9tLWNhdGVnb3J5LXByaW1hcnk",
      ])
  }

  @Test
  func testLoadDecryptsCategoryFromProductSync() async throws {
    let store = try keyedStore()
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: recordBoundary(keyMaterialStore: store, transport: transport)
    )
    let savedCategory = CustomCategory(name: "Receipts", description: "Purchases")
    _ = try await service.saveCategory(savedCategory, session: session)

    let loadedCategory = try await service.loadCategory(session: session)

    #expect(loadedCategory == savedCategory)
  }

  @Test
  func testLoadsMultipleCategoriesAndDeletesOnlyTargetedCategory() async throws {
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: recordBoundary(
        keyMaterialStore: try keyedStore(),
        transport: RecordingProductSyncTransport()
      )
    )
    let travel = CustomCategory(
      id: "custom:travel",
      name: "Travel",
      description: "Trips",
      symbolName: "briefcase.fill",
      colorName: "indigo"
    )
    let school = CustomCategory(
      id: "custom:school",
      name: "School",
      description: nil,
      symbolName: "bookmark.fill",
      colorName: "green"
    )

    _ = try await service.saveCategory(travel, session: session)
    _ = try await service.saveCategory(school, session: session)
    try await service.deleteCategory(id: travel.id, session: session)

    #expect(try await service.loadCategories(session: session) == [school])
  }

  @Test
  func testRejectsDuplicateAndReservedNames() async throws {
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: recordBoundary(
        keyMaterialStore: try keyedStore(),
        transport: RecordingProductSyncTransport()
      )
    )
    _ = try await service.saveCategory(
      CustomCategory(id: "custom:travel", name: "Travel", description: nil),
      session: session
    )

    await #expect(throws: CustomCategorySyncError.duplicateName) {
      _ = try await service.saveCategory(
        CustomCategory(id: "custom:other", name: " travel ", description: nil),
        session: session
      )
    }
    await #expect(throws: CustomCategorySyncError.duplicateName) {
      _ = try await service.saveCategory(
        CustomCategory(id: "custom:orders", name: "Orders", description: nil),
        session: session
      )
    }
  }

  @Test
  func testRejectsInvalidAppearanceAndOverlongDescription() async throws {
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: recordBoundary(
        keyMaterialStore: try keyedStore(),
        transport: RecordingProductSyncTransport()
      )
    )

    await #expect(throws: CustomCategorySyncError.invalidAppearance) {
      _ = try await service.saveCategory(
        CustomCategory(
          id: "custom:invalid-appearance",
          name: "Invalid Appearance",
          description: nil,
          symbolName: "unsupported"
        ),
        session: session
      )
    }
    _ = try await service.saveCategory(
      CustomCategory(
        id: "custom:description-boundary",
        name: "Description Boundary",
        description: String(repeating: "a", count: 500)
      ),
      session: session
    )
    await #expect(throws: CustomCategorySyncError.descriptionIsTooLong) {
      _ = try await service.saveCategory(
        CustomCategory(
          id: "custom:description-boundary",
          name: "Description Boundary",
          description: String(repeating: "a", count: 501)
        ),
        session: session
      )
    }
  }

  @Test
  func testSaveRejectsAuthoritativeCategoryTombstone() async throws {
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: recordBoundary(
        keyMaterialStore: try keyedStore(),
        transport: RecordingProductSyncTransport()
      )
    )
    let category = CustomCategory(
      id: "custom:deleted",
      name: "Deleted",
      description: nil
    )
    _ = try await service.saveCategory(category, session: session)
    try await service.deleteCategory(id: category.id, session: session)

    await #expect(throws: CustomCategorySyncError.categoryWasDeleted) {
      _ = try await service.saveCategory(category, session: session)
    }
  }

  @Test
  func testLegacySingletonMigrationRenamesSystemCategoryCollision() async throws {
    let store = try keyedStore()
    let transport = RecordingProductSyncTransport()
    let boundary = recordBoundary(keyMaterialStore: store, transport: transport)
    let legacyRecord: ProductSyncSingletonHandle<CustomCategorySyncPayload> = boundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: CustomCategorySyncPayload.primaryIdentifier,
        cachePolicy: .authoritative
      )
    )
    _ = try await legacyRecord.update(session: session) { _ in
      .write(
        CustomCategorySyncPayload(
          category: CustomCategory(name: "Orders", description: "Legacy purchases")
        ))
    }
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: boundary
    )

    let categories = try await service.loadCategories(session: session)

    #expect(categories.count == 1)
    #expect(categories[0].id == CustomCategorySyncPayload.primaryIdentifier)
    #expect(categories[0].name == "Orders (Custom)")
    #expect(categories[0].description == "Legacy purchases")
  }

  @Test
  func testNewerLegacyCategoryDoesNotOverrideCollectionTombstone() async throws {
    let store = try keyedStore()
    let transport = RecordingProductSyncTransport()
    let boundary = recordBoundary(keyMaterialStore: store, transport: transport)
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: boundary
    )
    _ = try await service.saveCategory(
      CustomCategory(name: "Finance", description: nil),
      session: session
    )
    try await service.deleteCategory(session: session)
    let legacyRecord: ProductSyncSingletonHandle<CustomCategorySyncPayload> = boundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: CustomCategorySyncPayload.primaryIdentifier,
        cachePolicy: .authoritative
      )
    )
    _ = try await legacyRecord.update(session: session) { _ in
      .write(
        CustomCategorySyncPayload(
          category: CustomCategory(name: "Legacy Finance", description: nil)
        ))
    }

    let categories = try await service.loadCategories(session: session)

    #expect(categories.isEmpty)
  }

  @Test
  func testDeletePersistsCategoryAsMissing() async throws {
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: recordBoundary(keyMaterialStore: try keyedStore(), transport: transport)
    )
    _ = try await service.saveCategory(
      CustomCategory(name: "Finance", description: nil),
      session: session
    )
    let initialUpdatedAt = try requireValue(transport.writes.first?.updatedAt)

    try await service.deleteCategory(session: session)

    let loadedCategory = try await service.loadCategory(session: session)

    #expect(loadedCategory == nil)
    #expect(try requireValue(transport.writes.first?.updatedAt) > initialUpdatedAt)
  }

  @Test
  func testCategoryWritesClearBackgroundCategorizationContext() async throws {
    let cacheStore = RecordingBackgroundContextCacheStore()
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
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

    #expect(
      cacheStore.clearedProductAccountIds == [session.productAccountId, session.productAccountId])
  }

  @Test
  func testCategoryWriteDoesNotReachProductSyncWhenBackgroundContextCannotBeCleared()
    async throws
  {
    let cacheStore = RecordingBackgroundContextCacheStore()
    cacheStore.clearError = KeychainStoreError.unexpectedData
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      backgroundContextCacheStore: cacheStore,
      recordBoundary: recordBoundary(keyMaterialStore: try keyedStore(), transport: transport)
    )

    do {
      _ = try await service.saveCategory(
        CustomCategory(name: "Finance", description: nil),
        session: session
      )
      Issue.record("Expected background context clear failure")
    } catch {}

    #expect(transport.writes.isEmpty)
  }

  @Test
  func testCategoryDeleteDoesNotReachProductSyncWhenBackgroundContextCannotBeCleared()
    async throws
  {
    let cacheStore = RecordingBackgroundContextCacheStore()
    cacheStore.clearError = KeychainStoreError.unexpectedData
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      backgroundContextCacheStore: cacheStore,
      recordBoundary: recordBoundary(keyMaterialStore: try keyedStore(), transport: transport)
    )

    do {
      try await service.deleteCategory(session: session)
      Issue.record("Expected background context clear failure")
    } catch {}

    #expect(transport.writes.isEmpty)
  }

  @Test
  func testLoadExistingRemoteCategoryRequiresLocalKeyMaterial() async throws {
    let firstStore = try keyedStore()
    let transport = RecordingProductSyncTransport()
    let firstDeviceService = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: recordBoundary(keyMaterialStore: firstStore, transport: transport)
    )
    _ = try await firstDeviceService.saveCategory(
      CustomCategory(name: "Finance", description: nil),
      session: session
    )
    let freshDeviceService = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: recordBoundary(
        keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
        transport: transport
      )
    )

    do {
      _ = try await freshDeviceService.loadCategory(session: session)
      Issue.record("Expected missing Product Sync key material")
    } catch let error as CustomCategorySyncError {
      #expect(error == .missingProductSyncKeyMaterial)
    }
  }

  @Test
  func testSaveWithoutRemoteCategoryRequiresLocalKeyMaterial() async throws {
    let store = InMemoryProductSyncKeyMaterialStore()
    let cacheStore = RecordingBackgroundContextCacheStore()
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      backgroundContextCacheStore: cacheStore,
      recordBoundary: recordBoundary(keyMaterialStore: store, transport: transport)
    )

    do {
      _ = try await service.saveCategory(
        CustomCategory(name: "Travel", description: nil),
        session: session
      )
      Issue.record("Expected missing Product Sync key material")
    } catch let error as CustomCategorySyncError {
      #expect(error == .missingProductSyncKeyMaterial)
    }

    #expect(store.saveCount == 0)
    #expect(cacheStore.clearedProductAccountIds.isEmpty)
    #expect(transport.writes.isEmpty)
  }

  @Test
  func testDeleteWithoutRemoteCategoryRequiresLocalKeyMaterial() async throws {
    let store = InMemoryProductSyncKeyMaterialStore()
    let cacheStore = RecordingBackgroundContextCacheStore()
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      backgroundContextCacheStore: cacheStore,
      recordBoundary: recordBoundary(keyMaterialStore: store, transport: transport)
    )

    do {
      try await service.deleteCategory(session: session)
      Issue.record("Expected missing Product Sync key material")
    } catch let error as CustomCategorySyncError {
      #expect(error == .missingProductSyncKeyMaterial)
    }

    #expect(store.saveCount == 0)
    #expect(cacheStore.clearedProductAccountIds.isEmpty)
    #expect(transport.writes.isEmpty)
  }

  @Test
  func testSaveDoesNotOverwriteRemoteCategoryWithoutLocalKeyMaterial() async throws {
    let firstStore = try keyedStore()
    let transport = RecordingProductSyncTransport()
    let firstDeviceService = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
      recordBoundary: recordBoundary(keyMaterialStore: firstStore, transport: transport)
    )
    _ = try await firstDeviceService.saveCategory(
      CustomCategory(name: "Finance", description: nil),
      session: session
    )
    let freshDeviceService = CustomCategorySyncService(
      recordScope: .legacyProductAccount,
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
      Issue.record("Expected missing Product Sync key material")
    } catch let error as CustomCategorySyncError {
      #expect(error == .missingProductSyncKeyMaterial)
    }

    let loadedCategory = try await firstDeviceService.loadCategory(session: session)
    #expect(loadedCategory?.name == "Finance")
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
