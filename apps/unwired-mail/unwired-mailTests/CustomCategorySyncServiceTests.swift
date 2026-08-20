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
    let service = CustomCategorySyncService(recordBoundary: boundary)

    await #expect(throws: CustomCategorySyncError.invalidPayload) {
      try await service.resetLearning(session: session)
    }
  }

  @Test
  func testCategoryRecordsCanUseANonDefaultProfileScope() async throws {
    let transport = RecordingProductSyncTransport()
    let profileId = MailProfileId(rawValue: "profile-fixture")
    let service = CustomCategorySyncService(
      recordBoundary: recordBoundary(keyMaterialStore: try keyedStore(), transport: transport),
      recordScope: .profile(profileId)
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

  @Test
  func testSaveUsesExistingProductSyncRecordIdentifier() async throws {
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
      recordBoundary: recordBoundary(keyMaterialStore: try keyedStore(), transport: transport)
    )

    _ = try await service.saveCategory(
      CustomCategory(name: "Travel", description: "Trips and bookings"),
      session: session
    )

    #expect(transport.writes.count == 3)
    #expect(
      Set(transport.writes.map(\.payloadIdentifier)) == [
        "custom-category-name-reservations-v1",
        CustomCategorySyncPayload.primaryIdentifier,
        "custom-category-v2:Y3VzdG9tLWNhdGVnb3J5LXByaW1hcnk",
      ])
  }

  @Test
  func testLoadDecryptsCategoryFromProductSync() async throws {
    let store = try keyedStore()
    let transport = RecordingProductSyncTransport()
    let service = CustomCategorySyncService(
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

  @Test(
    "Concurrent devices reserve one normalized Custom Category name",
    .bug("https://github.com/unwired-dev/product/issues/451")
  )
  func concurrentDevicesReserveOneNormalizedName() async throws {
    let keyMaterialStore = try keyedStore()
    let transport = InMemoryProductSyncRecordTransport()
    let firstDeviceService = CustomCategorySyncService(
      backgroundContextCacheStore: RecordingBackgroundContextCacheStore(),
      recordBoundary: recordBoundary(keyMaterialStore: keyMaterialStore, transport: transport)
    )
    let secondDeviceService = CustomCategorySyncService(
      backgroundContextCacheStore: RecordingBackgroundContextCacheStore(),
      recordBoundary: recordBoundary(keyMaterialStore: keyMaterialStore, transport: transport)
    )
    let secondDeviceSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: session.appleUserIdentifier,
      identityToken: session.identityToken,
      productAccountId: session.productAccountId,
      trustedDeviceId: "trustedDeviceFixtureId-2"
    )

    async let firstSave = saveResult(
      CustomCategory(id: "custom:travel", name: "Travel", description: nil),
      using: firstDeviceService,
      session: session
    )
    async let secondSave = saveResult(
      CustomCategory(id: "custom:other", name: " travel ", description: nil),
      using: secondDeviceService,
      session: secondDeviceSession
    )
    let results = await [firstSave, secondSave]

    #expect(results.filter { $0 == .saved }.count == 1)
    #expect(results.filter { $0 == .failed(.duplicateName) }.count == 1)
    #expect(try await firstDeviceService.loadCategories(session: session).count == 1)
  }

  @Test("Concurrent devices allow one conflicting Category rename")
  func concurrentDevicesAllowOneConflictingRename() async throws {
    let keyMaterialStore = try keyedStore()
    let transport = InMemoryProductSyncRecordTransport()
    let firstDeviceService = CustomCategorySyncService(
      backgroundContextCacheStore: RecordingBackgroundContextCacheStore(),
      recordBoundary: recordBoundary(keyMaterialStore: keyMaterialStore, transport: transport)
    )
    let secondDeviceService = CustomCategorySyncService(
      backgroundContextCacheStore: RecordingBackgroundContextCacheStore(),
      recordBoundary: recordBoundary(keyMaterialStore: keyMaterialStore, transport: transport)
    )
    let finance = CustomCategory(id: "custom:finance", name: "Finance", description: nil)
    let work = CustomCategory(id: "custom:work", name: "Work", description: nil)
    _ = try await firstDeviceService.saveCategory(finance, session: session)
    _ = try await firstDeviceService.saveCategory(work, session: session)

    async let firstRename = saveResult(
      CustomCategory(id: finance.id, name: "Travel", description: nil),
      using: firstDeviceService,
      session: session
    )
    async let secondRename = saveResult(
      CustomCategory(id: work.id, name: " travel ", description: nil),
      using: secondDeviceService,
      session: session
    )
    let results = await [firstRename, secondRename]
    let categories = try await firstDeviceService.loadCategories(session: session)

    #expect(results.filter { $0 == .saved }.count == 1)
    #expect(results.filter { $0 == .failed(.duplicateName) }.count == 1)
    #expect(categories.count == 2)
    #expect(
      categories.filter { $0.name.caseInsensitiveCompare("Travel") == .orderedSame }.count == 1)
  }

  @Test("Committed writes recover after a lost response and release renamed or deleted names")
  func committedWritesRecoverAndReleaseNames() async throws {
    let transport = CommitThenFailProductSyncTransport()
    let service = CustomCategorySyncService(
      backgroundContextCacheStore: RecordingBackgroundContextCacheStore(),
      recordBoundary: recordBoundary(keyMaterialStore: try keyedStore(), transport: transport)
    )
    let travel = CustomCategory(id: "custom:travel", name: "Travel", description: nil)

    await #expect(throws: SimulatedTransportError.lostResponse) {
      _ = try await service.saveCategory(travel, session: session)
    }
    _ = try await service.saveCategory(travel, session: session)
    let renamedTravel = CustomCategory(id: travel.id, name: "Trips", description: nil)
    _ = try await service.saveCategory(renamedTravel, session: session)
    let replacement = CustomCategory(id: "custom:replacement", name: "Travel", description: nil)
    _ = try await service.saveCategory(replacement, session: session)
    try await service.deleteCategory(id: replacement.id, session: session)
    let finalCategory = CustomCategory(id: "custom:final", name: "Travel", description: nil)
    _ = try await service.saveCategory(finalCategory, session: session)

    #expect(try await service.loadCategories(session: session) == [finalCategory, renamedTravel])
  }

  @Test("Existing duplicate Category records reconcile deterministically without data loss")
  func existingDuplicateRecordsReconcileDeterministically() async throws {
    let keyMaterialStore = try keyedStore()
    let transport = InMemoryProductSyncRecordTransport()
    let boundary = recordBoundary(keyMaterialStore: keyMaterialStore, transport: transport)
    let categories = [
      CustomCategory(id: "custom:first", name: "Travel", description: "First"),
      CustomCategory(id: "custom:second", name: " travel ", description: "Second"),
    ]
    for category in categories {
      let record = boundary.singleton(
        ProductSyncSingletonDefinition<LegacyCustomCategoryCollectionPayload>(
          identifier: CustomCategorySyncService.collectionPayloadIdentifier(
            category.id,
            recordScope: .legacyProductAccount
          ),
          cachePolicy: .authoritative
        ))
      _ = try await record.update(session: session) { _ in
        .write(LegacyCustomCategoryCollectionPayload(category: category))
      }
    }
    let firstDeviceService = CustomCategorySyncService(recordBoundary: boundary)

    let reconciled = try await firstDeviceService.loadCategories(session: session)
    let secondDeviceService = CustomCategorySyncService(
      recordBoundary: recordBoundary(keyMaterialStore: keyMaterialStore, transport: transport)
    )

    #expect(reconciled.map(\.id).sorted() == categories.map(\.id).sorted())
    #expect(Set(reconciled.map(\.name)) == ["Travel", "travel (Custom)"])
    #expect(try await secondDeviceService.loadCategories(session: session) == reconciled)
  }

  @Test("Custom Category name reservations remain isolated by Mail Profile")
  func nameReservationsRemainProfileScoped() async throws {
    let keyMaterialStore = try keyedStore()
    let transport = InMemoryProductSyncRecordTransport()
    let firstProfileService = CustomCategorySyncService(
      backgroundContextCacheStore: RecordingBackgroundContextCacheStore(),
      recordBoundary: recordBoundary(keyMaterialStore: keyMaterialStore, transport: transport),
      recordScope: .profile(MailProfileId(rawValue: "first-profile"))
    )
    let secondProfileService = CustomCategorySyncService(
      backgroundContextCacheStore: RecordingBackgroundContextCacheStore(),
      recordBoundary: recordBoundary(keyMaterialStore: keyMaterialStore, transport: transport),
      recordScope: .profile(MailProfileId(rawValue: "second-profile"))
    )
    let first = CustomCategory(id: "custom:first", name: "Travel", description: nil)
    let second = CustomCategory(id: "custom:second", name: "Travel", description: nil)

    _ = try await firstProfileService.saveCategory(first, session: session)
    _ = try await secondProfileService.saveCategory(second, session: session)

    #expect(try await firstProfileService.loadCategories(session: session) == [first])
    #expect(try await secondProfileService.loadCategories(session: session) == [second])
  }

  @Test
  func testRejectsInvalidAppearanceAndOverlongDescription() async throws {
    let service = CustomCategorySyncService(
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
    let service = CustomCategorySyncService(recordBoundary: boundary)

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
    let service = CustomCategorySyncService(recordBoundary: boundary)
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
      Issue.record("Expected missing Product Sync key material")
    } catch let error as CustomCategorySyncError {
      #expect(error == .missingProductSyncKeyMaterial)
    }

    let loadedCategory = try await firstDeviceService.loadCategory(session: session)
    #expect(loadedCategory?.name == "Finance")
  }

  private func saveResult(
    _ category: CustomCategory,
    using service: CustomCategorySyncService,
    session: ProductAccountSessionSnapshot
  ) async -> CategorySaveResult {
    do {
      _ = try await service.saveCategory(category, session: session)
      return .saved
    } catch let error as CustomCategorySyncError {
      return .failed(error)
    } catch {
      return .unexpectedFailure
    }
  }
}

private enum CategorySaveResult: Equatable {
  case failed(CustomCategorySyncError)
  case saved
  case unexpectedFailure
}

private struct LegacyCustomCategoryCollectionPayload: Codable, Sendable {
  let category: CustomCategory?
  let categoryId: String
  let deleted: Bool
  let schemaVersion: Int

  init(category: CustomCategory) {
    self.category = category
    categoryId = category.id
    deleted = false
    schemaVersion = 2
  }
}

private enum SimulatedTransportError: Error {
  case lostResponse
}

private actor CommitThenFailProductSyncTransport: ProductSyncAtomicRecordTransport {
  private let base = InMemoryProductSyncRecordTransport()
  private var shouldLoseNextCommittedResponse = true

  func listEncryptedProductSyncPayloads(
    session: ProductAccountSessionSnapshot,
    payloadIdentifierPrefix: String,
    cursor: String?,
    limit: Int
  ) async throws -> EncryptedProductSyncPayloadPage {
    try await base.listEncryptedProductSyncPayloads(
      session: session,
      payloadIdentifierPrefix: payloadIdentifierPrefix,
      cursor: cursor,
      limit: limit
    )
  }

  func getEncryptedProductSyncPayloads(
    session: ProductAccountSessionSnapshot,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    try await base.getEncryptedProductSyncPayloads(
      session: session,
      payloadIdentifiers: payloadIdentifiers
    )
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    try await base.putEncryptedProductSyncPayloadIfUnchanged(
      session: session,
      payloadIdentifier: payloadIdentifier,
      encryptedPayload: encryptedPayload,
      expectedUpdatedAt: expectedUpdatedAt
    )
  }

  func putEncryptedProductSyncPayloadsAtomically(
    session: ProductAccountSessionSnapshot,
    writes: [ProductSyncAtomicWrite],
    deletes: [ProductSyncAtomicDelete],
    checks: [ProductSyncAtomicCheck]
  ) async throws -> ProductSyncAtomicWriteResult {
    let result = try await base.putEncryptedProductSyncPayloadsAtomically(
      session: session,
      writes: writes,
      deletes: deletes,
      checks: checks
    )
    if result.committed, shouldLoseNextCommittedResponse {
      shouldLoseNextCommittedResponse = false
      throw SimulatedTransportError.lostResponse
    }
    return result
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

private final class RecordingProductSyncTransport: ProductSyncAtomicRecordTransport {
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

  func putEncryptedProductSyncPayloadsAtomically(
    session _: ProductAccountSessionSnapshot,
    writes newWrites: [ProductSyncAtomicWrite],
    deletes: [ProductSyncAtomicDelete],
    checks: [ProductSyncAtomicCheck]
  ) async throws -> ProductSyncAtomicWriteResult {
    let revisions = Dictionary(
      uniqueKeysWithValues: writes.map { ($0.payloadIdentifier, $0.updatedAt) }
    )
    let revisionsMatch =
      newWrites.allSatisfy { revisions[$0.payloadIdentifier] == $0.expectedUpdatedAt }
      && deletes.allSatisfy { revisions[$0.payloadIdentifier] == $0.expectedUpdatedAt }
      && checks.allSatisfy { revisions[$0.payloadIdentifier] == $0.expectedUpdatedAt }
    guard revisionsMatch else {
      return ProductSyncAtomicWriteResult(committed: false, payloads: writes)
    }
    for deletion in deletes {
      writes.removeAll { $0.payloadIdentifier == deletion.payloadIdentifier }
    }
    var committedPayloads: [EncryptedProductSyncPayload] = []
    for write in newWrites {
      nextUpdatedAt += 1
      let payload = EncryptedProductSyncPayload(
        encryptedPayload: write.encryptedPayload,
        payloadIdentifier: write.payloadIdentifier,
        updatedAt: nextUpdatedAt
      )
      writes.removeAll { $0.payloadIdentifier == write.payloadIdentifier }
      writes.append(payload)
      committedPayloads.append(payload)
    }
    return ProductSyncAtomicWriteResult(committed: true, payloads: committedPayloads)
  }
}
