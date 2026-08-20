import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length

@Suite(.serialized)
final class MessageCategorizationServiceTests {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "apple-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  @Test
  func testRuleBasedEngineAssignsSystemCategoryFromMinimizedInput() async throws {
    let engine = RuleBasedClassificationEngine()

    let decision = try await engine.classify(
      input: ClassificationInput(
        bodyText: nil,
        minimized: MinimizedClassificationInput(
          from: "Airline <updates@airline.example>",
          replyTo: nil,
          snippet: "Your itinerary is ready",
          subject: "Flight confirmation"
        )
      ),
      categories: MessageClassificationCategory.systemCategories
    )

    #expect(decision == .assigned(categoryIds: ["system:flights"]))
  }

  @Test
  func testRuleBasedEngineCanAssignCustomCategory() async throws {
    let engine = RuleBasedClassificationEngine()
    let customCategory = MessageClassificationCategory(
      id: "custom-category-primary",
      keywords: ["school", "classroom"]
    )

    let decision = try await engine.classify(
      input: ClassificationInput(
        bodyText: nil,
        minimized: MinimizedClassificationInput(
          from: "teacher@example.com",
          replyTo: nil,
          snippet: "Classroom update",
          subject: "School newsletter"
        )
      ),
      categories: [customCategory] + MessageClassificationCategory.systemCategories
    )

    #expect(decision == .assigned(categoryIds: [customCategory.id]))
  }

  @Test
  func testRuleBasedEngineAssignsEveryMatchingPurposeCategory() async throws {
    let decision = try await RuleBasedClassificationEngine().classify(
      input: ClassificationInput(
        bodyText: nil,
        minimized: MinimizedClassificationInput(
          from: "Shop <orders@merchant.example>",
          replyTo: nil,
          snippet: "Your order includes a discount",
          subject: "Receipt and sale offer"
        )
      ),
      categories: MessageClassificationCategory.systemCategories
    )

    #expect(decision == .assigned(categoryIds: ["system:invoices", "system:promotions"]))
  }

  @Test
  func testRuleBasedEngineUsesPeopleOnlyAsFallback() async throws {
    let engine = RuleBasedClassificationEngine()
    let directMessage = ClassificationInput(
      bodyText: "Dinner plans for tomorrow.",
      minimized: MinimizedClassificationInput(
        from: "Alice <alice@example.com>",
        replyTo: nil,
        snippet: "See you tomorrow",
        subject: "Dinner"
      )
    )

    #expect(
      try await engine.classify(
        input: ClassificationInput(bodyText: nil, minimized: directMessage.minimized),
        categories: MessageClassificationCategory.systemCategories
      ) == .needsBody
    )
    #expect(
      try await engine.classify(
        input: directMessage,
        categories: MessageClassificationCategory.systemCategories
      ) == .assigned(categoryIds: ["system:people"])
    )
    #expect(
      try await engine.classify(
        input: ClassificationInput(
          bodyText: nil,
          minimized: MinimizedClassificationInput(
            from: "Alice <alice@example.com>",
            replyTo: nil,
            snippet: "Your flight itinerary",
            subject: "Dinner after landing"
          )
        ),
        categories: MessageClassificationCategory.systemCategories
      ) == .assigned(categoryIds: ["system:flights"])
    )
  }

  @Test
  func testNegativeLearningSignalSuppressesOnlyItsCategory() async throws {
    let input = ClassificationInput(
      bodyText: nil,
      minimized: MinimizedClassificationInput(
        from: "Shop <orders@merchant.example>",
        replyTo: nil,
        snippet: "Order discount",
        subject: "Receipt sale",
        providerInternalDateMilliseconds: 200
      )
    )
    let categories = MessageClassificationCategory.systemCategories.map { category in
      guard category.id == "system:promotions" else { return category }
      return MessageClassificationCategory(
        id: category.id,
        keywords: category.keywords,
        learningSignals: [
          FutureLearningSignal(
            appliesAfterTimestamp: 100,
            categoryId: category.id,
            isPositive: false,
            senderAddresses: ["orders@merchant.example"]
          )
        ]
      )
    }

    #expect(
      try await RuleBasedClassificationEngine().classify(input: input, categories: categories)
        == .assigned(categoryIds: ["system:invoices"])
    )
  }

  @Test
  func testLegacyAssignmentDecodesWithoutCollapsingNewAssignments() throws {
    let legacy = try JSONDecoder().decode(
      MessageCategoryAssignment.self,
      from: Data(
        (#"{"categoryId":"system:flights","schemaVersion":1,"source":"system","#
          + #""stableProviderMessageId":"gmail:account:message-001"}"#).utf8
      )
    )
    #expect(legacy.categoryIds == ["system:flights"])
    #expect(legacy.schemaVersion == 1)

    let current = MessageCategoryAssignment(
      memberships: [
        MessageCategoryMembership(categoryId: "system:flights"),
        MessageCategoryMembership(categoryId: "system:invoices"),
      ],
      stableProviderMessageId: "gmail:account:message-001"
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
    )
    #expect(object["categoryId"] == nil)
    #expect((object["memberships"] as? [[String: Any]])?.count == 2)
  }

  @Test
  func testCategorizationLoadsBodyOnlyWhenMinimizedInputNeedsIt() async throws {
    let engine = RecordingClassificationEngine(
      decisions: [.needsBody, .assigned(categoryIds: ["system:invoices"])]
    )
    let bodyReader = RecordingCachedBodyReader(
      bodyHTML: "<p>HTML must not reach categorization</p>",
      bodyText: "Invoice total: 42 EUR"
    )
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: bodyReader,
      categorySync: StubCustomCategorySync(),
      engine: engine
    )

    let categorized = try await service.categorize(
      messages: [message()],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(engine.inputs.map(\.bodyText) == [nil, "Invoice total: 42 EUR"])
    #expect(bodyReader.loadedMessageIds == ["gmail:account:message-001"])
    #expect(categorized[0].categoryId == "system:invoices")
    #expect(
      assignmentSync.savedAssignments == [
        MessageCategoryAssignment(
          categoryId: "system:invoices",
          stableProviderMessageId: "gmail:account:message-001"
        )
      ])
  }

  @Test
  func testCategorizationDoesNotLoadBodyWhenMinimizedInputAssignsCategory() async throws {
    let engine = RecordingClassificationEngine(
      decisions: [.assigned(categoryIds: ["system:promotions"])]
    )
    let bodyReader = RecordingCachedBodyReader(bodyText: "Unused body")
    let service = GmailMessageCategorizationService(
      assignmentSync: RecordingMessageCategoryAssignmentSync(),
      bodyReader: bodyReader,
      categorySync: StubCustomCategorySync(),
      engine: engine
    )

    let categorized = try await service.categorize(
      messages: [message()],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(engine.inputs.count == 1)
    #expect(bodyReader.loadedMessageIds.isEmpty)
    #expect(categorized[0].categoryId == "system:promotions")
  }

  @Test
  func testCategorizationLoadsConfigurationOncePerBatch() async throws {
    let categorySync = CountingCustomCategorySync()
    let service = GmailMessageCategorizationService(
      assignmentSync: RecordingMessageCategoryAssignmentSync(),
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: categorySync,
      engine: RecordingClassificationEngine(
        decisions: [
          .assigned(categoryIds: ["system:promotions"]),
          .assigned(categoryIds: ["system:invoices"]),
        ]
      )
    )

    _ = try await service.categorize(
      messages: [message(messageId: "message-001"), message(messageId: "message-002")],
      recordScope: .legacyProductAccount, session: session
    )

    let loadConfigurationCount = await categorySync.loadConfigurationCount
    #expect(loadConfigurationCount == 1)
  }

  @Test
  func testAutomaticCategorizationGlobalSwitchPreservesUncategorizedMail() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let engine = RecordingClassificationEngine(
      decisions: [.assigned(categoryIds: ["system:flights"])]
    )
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(
        configuration: CategoryConfiguration(automaticCategorizationEnabled: false)
      ),
      engine: engine
    )

    let categorized = try await service.categorize(
      messages: [message()], recordScope: .legacyProductAccount, session: session)

    #expect(categorized[0].messageCategoryIds.isEmpty)
    #expect(engine.inputs.isEmpty)
    #expect(assignmentSync.savedAssignments.isEmpty)
  }

  @Test
  func testDisabledSystemCategoryIsUnavailableToAutomaticClassification() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let engine = RecordingClassificationEngine(
      decisions: [.assigned(categoryIds: ["system:invoices"])]
    )
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(
        configuration: CategoryConfiguration(
          disabledSystemCategoryIds: ["system:invoices"]
        )
      ),
      engine: engine
    )

    let categorized = try await service.categorize(
      messages: [message()], recordScope: .legacyProductAccount, session: session)

    #expect(categorized[0].messageCategoryIds.isEmpty)
    #expect(engine.categoryIds.count == 1)
    #expect(!(engine.categoryIds.first?.contains("system:invoices") ?? true))
    #expect(assignmentSync.savedAssignments.isEmpty)
  }

  @Test
  func testLearningResetIgnoresOlderPositiveAndNegativeSignals() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let signal = FutureLearningSignal(
      appliesAfterTimestamp: 100,
      categoryId: "system:invoices",
      isPositive: true,
      overrideTimestamp: 100,
      senderAddresses: ["sender@example.com"]
    )
    assignmentSync.assignmentsByMessageId["gmail:account:older-override"] =
      MessageCategoryAssignment(
        memberships: [
          MessageCategoryMembership(
            categoryId: "system:invoices",
            learningSignal: signal,
            overrideTimestamp: 100,
            source: .userOverride
          )
        ],
        stableProviderMessageId: "gmail:account:older-override"
      )
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(
        configuration: CategoryConfiguration(
          learningGeneration: 1,
          learningResetAtMilliseconds: 200
        )
      ),
      engine: RuleBasedClassificationEngine()
    )

    let categorized = try await service.categorize(
      messages: [message(providerInternalDateMilliseconds: 300)],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized[0].messageCategoryIds.isEmpty)
  }

  @Test
  func testCategorizationLeavesMessageUncategorizedWhenNoBodyIsCached() async throws {
    let engine = RecordingClassificationEngine(decisions: [.needsBody])
    let bodyReader = RecordingCachedBodyReader(bodyText: nil)
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: bodyReader,
      categorySync: StubCustomCategorySync(),
      engine: engine
    )

    let categorized = try await service.categorize(
      messages: [message()],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized[0].categoryId == nil)
    #expect(bodyReader.loadedMessageIds == ["gmail:account:message-001"])
    #expect(assignmentSync.savedAssignments.isEmpty)
  }

  @Test
  func testCategorizationLeavesMessageUncategorizedWhenClassificationFails() async throws {
    let service = GmailMessageCategorizationService(
      assignmentSync: RecordingMessageCategoryAssignmentSync(),
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: FailingClassificationEngine()
    )

    let categorized = try await service.categorize(
      messages: [message()],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized[0].categoryId == nil)
  }

  @Test
  func testCategorizationPreservesHistoricalAndAssignedMessages() async throws {
    let engine = RecordingClassificationEngine(decisions: [])
    let bodyReader = RecordingCachedBodyReader(bodyText: "Unused body")
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: bodyReader,
      categorySync: StubCustomCategorySync(),
      engine: engine
    )
    let historical = message(isHistorical: true)
    let assigned = message(categoryId: "system:flights", messageId: "message-002")

    let categorized = try await service.categorize(
      messages: [historical, assigned],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized == [historical, assigned])
    #expect(engine.inputs.isEmpty)
    #expect(bodyReader.loadedMessageIds.isEmpty)
    #expect(
      assignmentSync.loadedAssignmentBatches == [
        [historical.stableProviderMessageId, assigned.stableProviderMessageId]
      ])
    #expect(assignmentSync.loadedMessageIds.isEmpty)
    #expect(assignmentSync.savedAssignments.isEmpty)
  }

  @Test
  func testCategorizationUsesSyncedAssignmentBeforeRunningEngine() async throws {
    let engine = RecordingClassificationEngine(decisions: [])
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    assignmentSync.assignmentsByMessageId["gmail:account:message-001"] =
      MessageCategoryAssignment(
        categoryId: "custom-category-primary",
        stableProviderMessageId: "gmail:account:message-001"
      )
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: "Unused body"),
      categorySync: StubCustomCategorySync(),
      engine: engine
    )

    let categorized = try await service.categorize(
      messages: [message()],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized[0].categoryId == "custom-category-primary")
    #expect(engine.inputs.isEmpty)
    #expect(assignmentSync.savedAssignments.isEmpty)
  }

  @Test
  func testCategorizationAppliesSyncedAssignmentToHistoricalMessage() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    assignmentSync.assignmentsByMessageId["gmail:account:message-001"] =
      MessageCategoryAssignment(
        categoryId: "system:flights",
        stableProviderMessageId: "gmail:account:message-001"
      )
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: "Unused body"),
      categorySync: StubCustomCategorySync(),
      engine: RecordingClassificationEngine(decisions: [])
    )

    let categorized = try await service.categorize(
      messages: [message(isHistorical: true)],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized[0].categoryId == "system:flights")
    #expect(assignmentSync.savedAssignments.isEmpty)
  }
}

extension MessageCategorizationServiceTests {
  @Test
  func testHistoricalCategorizationOnlyClassifiesMessagesInSelectedDateRange() async throws {
    let engine = RecordingClassificationEngine(
      decisions: [.assigned(categoryIds: ["system:promotions"])]
    )
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: engine
    )
    let beforeScope = message(
      isHistorical: true,
      messageId: "message-001",
      providerInternalDateMilliseconds: 100
    )
    let inScope = message(
      isHistorical: true,
      messageId: "message-002",
      providerInternalDateMilliseconds: 200
    )
    let afterScope = message(
      isHistorical: true,
      messageId: "message-003",
      providerInternalDateMilliseconds: 300
    )
    let current = message(
      messageId: "message-004",
      providerInternalDateMilliseconds: 200
    )

    let categorized = try await service.categorizeHistorical(
      messages: [beforeScope, inScope, afterScope, current],
      scope: GmailHistoricalCategorizationScope(
        receivedAtOrAfterMilliseconds: 150,
        receivedBeforeMilliseconds: 250
      ),
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized.map(\.categoryId) == [nil, "system:promotions", nil, nil])
    #expect(engine.inputs.map(\.minimized.providerInternalDateMilliseconds) == [200])
    #expect(assignmentSync.loadedAssignmentBatches == [[inScope.stableProviderMessageId]])
    #expect(
      assignmentSync.savedAssignments == [
        MessageCategoryAssignment(
          categoryId: "system:promotions",
          stableProviderMessageId: inScope.stableProviderMessageId
        )
      ])
  }

  @Test
  func testHistoricalCategorizationRestrictsMailboxAndCategoryTarget() async throws {
    let engine = RecordingClassificationEngine(
      decisions: [.assigned(categoryIds: ["system:flights"])]
    )
    let service = GmailMessageCategorizationService(
      assignmentSync: RecordingMessageCategoryAssignmentSync(),
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: engine
    )
    var selectedMailboxMessage = message(
      isHistorical: true,
      messageId: "message-001",
      providerInternalDateMilliseconds: 200
    )
    selectedMailboxMessage.providerLabelIds = ["Label_Travel"]
    var otherMailboxMessage = message(
      isHistorical: true,
      messageId: "message-002",
      providerInternalDateMilliseconds: 200
    )
    otherMailboxMessage.providerLabelIds = ["INBOX"]

    let categorized = try await service.categorizeHistorical(
      messages: [selectedMailboxMessage, otherMailboxMessage],
      scope: GmailHistoricalCategorizationScope(
        categoryIds: ["system:flights"],
        collection: .providerMailbox("Label_Travel"),
        receivedAtOrAfterMilliseconds: 100,
        receivedBeforeMilliseconds: 300
      ),
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized.map(\.messageCategoryIds) == [["system:flights"], []])
    #expect(engine.categoryIds == [["system:flights"]])
  }

  @Test
  func testHistoricalCategorizationPreservesExistingAndSyncedUserOverrideCategories()
    async throws
  {
    let engine = RecordingClassificationEngine(decisions: [])
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let userOverridden = message(
      isHistorical: true,
      messageId: "message-002",
      providerInternalDateMilliseconds: 200
    )
    assignmentSync.assignmentsByMessageId[userOverridden.stableProviderMessageId] =
      MessageCategoryAssignment(
        categoryId: "system:promotions",
        source: .userOverride,
        stableProviderMessageId: userOverridden.stableProviderMessageId
      )
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: engine
    )
    let assigned = message(
      categoryId: "system:flights",
      isHistorical: true,
      providerInternalDateMilliseconds: 200
    )

    let categorized = try await service.categorizeHistorical(
      messages: [assigned, userOverridden],
      scope: GmailHistoricalCategorizationScope(
        receivedAtOrAfterMilliseconds: 100,
        receivedBeforeMilliseconds: 300
      ),
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized.map(\.categoryId) == ["system:flights", "system:promotions"])
    #expect(engine.inputs.isEmpty)
    #expect(assignmentSync.savedAssignments.isEmpty)
  }

  @Test
  func testHistoricalCategorizationDateRangeIgnoresTimeComponents() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    let selectedDay = Date(timeIntervalSince1970: 0)

    #expect(
      GmailHistoricalCategorizationScope.isValidDateRange(
        startDate: selectedDay.addingTimeInterval(82_800),
        endDate: selectedDay.addingTimeInterval(3_600),
        calendar: calendar
      ))
    #expect(
      !(GmailHistoricalCategorizationScope.isValidDateRange(
        startDate: selectedDay.addingTimeInterval(86_400),
        endDate: selectedDay,
        calendar: calendar
      )))
  }
}

extension MessageCategorizationServiceTests {
  @Test
  func testUserCanOverrideHistoricalUncategorizedMessage() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let cacheStore = InMemoryBackgroundContextCacheStore()
    cacheStore.caches["\(session.productAccountId):account"] = backgroundContextCache(
      cachedAtMilliseconds: 1_781_300_000_000
    )
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      backgroundContextCacheStore: cacheStore,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      currentTimeMilliseconds: { 1_781_300_000_000 },
      engine: RecordingClassificationEngine(decisions: [])
    )

    let overridden = try await service.overrideCategory(
      "system:invoices",
      for: message(isHistorical: true),
      session: session
    )

    #expect(overridden.categoryId == "system:invoices")
    #expect(cacheStore.caches["\(session.productAccountId):account"] == nil)
    #expect(
      assignmentSync.savedUserOverrides == [
        MessageCategoryAssignment(
          categoryId: "system:invoices",
          learningSignal: FutureLearningSignal(
            appliesAfterTimestamp: 1_781_300_000_000,
            categoryId: "system:invoices",
            overrideTimestamp: 1_781_300_000_000,
            senderAddresses: ["sender@example.com"]
          ),
          overrideTimestamp: 1_781_300_000_000,
          source: .userOverride,
          stableProviderMessageId: "gmail:account:message-001"
        )
      ])
  }

  @Test
  func testUserOverrideDoesNotSaveWhenBackgroundContextCannotBeCleared() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let cacheStore = InMemoryBackgroundContextCacheStore()
    cacheStore.clearError = KeychainStoreError.unexpectedData
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      backgroundContextCacheStore: cacheStore,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: RecordingClassificationEngine(decisions: [])
    )

    do {
      _ = try await service.overrideCategory("system:invoices", for: message(), session: session)
      Issue.record("Expected background context clear failure")
    } catch {}

    #expect(assignmentSync.savedUserOverrides.isEmpty)
  }

  @Test
  func testSetCategoriesRecordsIndependentAddAndRemoveSignals() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      currentTimeMilliseconds: { 200 },
      engine: RecordingClassificationEngine(decisions: [])
    )

    let updated = try await service.setCategories(
      ["system:promotions"],
      for: message(categoryId: "system:flights", providerInternalDateMilliseconds: 100),
      session: session
    )

    let memberships = try #require(assignmentSync.savedUserOverrides.first?.memberships)
    #expect(updated.messageCategoryIds == ["system:promotions"])
    #expect(
      memberships.first { $0.categoryId == "system:flights" }?.learningSignal?.isPositive == false
    )
    #expect(
      memberships.first { $0.categoryId == "system:promotions" }?.learningSignal?.isPositive == true
    )
  }

  @Test
  func testFutureLearningSignalInfluencesOnlyMessagesReceivedAfterOverride() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      currentTimeMilliseconds: { 100 },
      engine: RuleBasedClassificationEngine()
    )
    _ = try await service.overrideCategory(
      "system:invoices",
      for: message(
        from: "Billing <updates@merchant.example>",
        providerInternalDateMilliseconds: 100
      ),
      session: session
    )
    let priorMessage = message(
      from: "Billing <updates@merchant.example>",
      messageId: "message-002",
      providerInternalDateMilliseconds: 90,
      snippet: "Your earlier statement is ready",
      subject: "Earlier account update"
    )
    let futureMessage = message(
      from: "Billing <updates@merchant.example>",
      messageId: "message-003",
      providerInternalDateMilliseconds: 110,
      snippet: "Your monthly statement is ready",
      subject: "Account update"
    )
    let replyTargetMessage = message(
      from: "Different sender <other@merchant.example>",
      messageId: "message-004",
      providerInternalDateMilliseconds: 115,
      replyTo: "Billing <updates@merchant.example>"
    )
    let existingMessage = message(
      categoryId: "system:flights",
      from: "Billing <updates@merchant.example>",
      messageId: "message-005",
      providerInternalDateMilliseconds: 120
    )

    let categorized = try await service.categorize(
      messages: [priorMessage, futureMessage, replyTargetMessage, existingMessage],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized[0].categoryId == nil)
    #expect(categorized[1].categoryId == "system:invoices")
    #expect(categorized[2].categoryId == nil)
    #expect(categorized[3].categoryId == "system:flights")
  }

  @Test
  func testMatchingFutureLearningSignalsApplyIndependentlyAcrossCategories() async throws {
    let decision = try await RuleBasedClassificationEngine().classify(
      input: ClassificationInput(
        bodyText: nil,
        minimized: MinimizedClassificationInput(
          from: "Billing <updates@merchant.example>",
          replyTo: nil,
          snippet: "Account update",
          subject: "Account update",
          providerInternalDateMilliseconds: 300
        )
      ),
      categories: [
        MessageClassificationCategory(
          id: "system:promotions",
          keywords: [],
          learningSignals: [
            FutureLearningSignal(
              appliesAfterTimestamp: 100,
              categoryId: "system:promotions",
              senderAddresses: ["updates@merchant.example"]
            )
          ]
        ),
        MessageClassificationCategory(
          id: "system:flights",
          keywords: [],
          learningSignals: [
            FutureLearningSignal(
              appliesAfterTimestamp: 200,
              categoryId: "system:flights",
              senderAddresses: ["updates@merchant.example"]
            )
          ]
        ),
      ]
    )

    #expect(decision == .assigned(categoryIds: ["system:flights", "system:promotions"]))
  }

  @Test
  func testUserOverrideLearnsOnlyActualFromMailbox() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      currentTimeMilliseconds: { 100 },
      engine: RecordingClassificationEngine(decisions: [])
    )

    _ = try await service.overrideCategory(
      "system:invoices",
      for: message(from: "\"Alice <alice@example.com> via Shop\" <receipts@shop.example>"),
      session: session
    )

    #expect(
      assignmentSync.savedUserOverrides.first?.learningSignal?.senderAddresses == [
        "receipts@shop.example"
      ])
  }

  @Test
  func testUserOverrideLearningStartsNoEarlierThanOverriddenMessage() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      currentTimeMilliseconds: { 100 },
      engine: RecordingClassificationEngine(decisions: [])
    )

    _ = try await service.overrideCategory(
      "system:invoices",
      for: message(providerInternalDateMilliseconds: 200),
      session: session
    )

    #expect(assignmentSync.savedUserOverrides.first?.learningSignal?.appliesAfterTimestamp == 200)
  }

  @Test
  func testUserOverrideLearningUsesActionTimeWhenLaterThanMessage() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      currentTimeMilliseconds: { 200 },
      engine: RecordingClassificationEngine(decisions: [])
    )

    _ = try await service.overrideCategory(
      "system:invoices",
      for: message(providerInternalDateMilliseconds: 100),
      session: session
    )

    #expect(assignmentSync.savedUserOverrides.first?.learningSignal?.appliesAfterTimestamp == 200)
  }

  @Test
  func testSyncedUserOverrideReplacesExistingSystemCategory() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    assignmentSync.assignmentsByMessageId["gmail:account:message-001"] =
      MessageCategoryAssignment(
        categoryId: "system:invoices",
        learningSignal: FutureLearningSignal(
          appliesAfterTimestamp: 1_781_300_000_000,
          categoryId: "system:invoices",
          senderAddresses: ["sender@example.com"]
        ),
        source: .userOverride,
        stableProviderMessageId: "gmail:account:message-001"
      )
    let engine = RecordingClassificationEngine(decisions: [])
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: engine
    )

    let categorized = try await service.categorize(
      messages: [message(categoryId: "system:flights")],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized[0].categoryId == "system:invoices")
    #expect(engine.inputs.isEmpty)
  }

  @Test
  func testSystemAssignmentCannotOverwriteSyncedUserOverride() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let syncService = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let userOverride = MessageCategoryAssignment(
      categoryId: "system:invoices",
      learningSignal: FutureLearningSignal(
        appliesAfterTimestamp: 1_781_300_000_000,
        categoryId: "system:invoices",
        senderAddresses: ["sender@example.com"]
      ),
      source: .userOverride,
      stableProviderMessageId: "gmail:account:message-001"
    )
    _ = try await syncService.saveUserOverride(userOverride, session: session)

    let systemResult = try await syncService.saveAssignment(
      MessageCategoryAssignment(
        categoryId: "system:flights",
        stableProviderMessageId: userOverride.stableProviderMessageId
      ),
      session: session
    )
    let synced = try await syncService.loadAssignment(
      stableProviderMessageId: userOverride.stableProviderMessageId,
      session: session
    )

    #expect(systemResult.categoryIds == ["system:flights", "system:invoices"])
    #expect(synced?.categoryIds == ["system:flights", "system:invoices"])
    #expect(
      synced?.memberships.first { $0.categoryId == "system:invoices" }?.source == .userOverride)
    #expect(!(transport.writes[0].encryptedPayload.ciphertextBase64.contains("userOverride")))
  }

  @Test
  func testSystemPeopleMembershipIsRemovedWhenPurposeCategoryIsIncluded() async throws {
    let service = categoryAssignmentSync(
      keyStore: try preparedCategorySyncKeyStore(),
      transport: RecordingCategorySyncTransport()
    )

    let result = try await service.saveAssignment(
      MessageCategoryAssignment(
        memberships: [
          MessageCategoryMembership(categoryId: "system:people"),
          MessageCategoryMembership(categoryId: "system:flights"),
        ],
        stableProviderMessageId: "gmail:account:system-people"
      ),
      session: session
    )

    #expect(result.categoryIds == ["system:flights"])
    #expect(!result.memberships.contains { $0.categoryId == "system:people" })
  }

  @Test
  func testUserPeopleMembershipIsRetainedWhenPurposeCategoryIsIncluded() async throws {
    let service = categoryAssignmentSync(
      keyStore: try preparedCategorySyncKeyStore(),
      transport: RecordingCategorySyncTransport()
    )

    let result = try await service.saveUserOverride(
      MessageCategoryAssignment(
        memberships: [
          MessageCategoryMembership(
            categoryId: "system:people",
            overrideTimestamp: 100,
            source: .userOverride
          ),
          MessageCategoryMembership(categoryId: "system:flights"),
        ],
        stableProviderMessageId: "gmail:account:user-people"
      ),
      session: session
    )

    #expect(result.categoryIds == ["system:flights", "system:people"])
    #expect(
      result.memberships.first { $0.categoryId == "system:people" }?.source == .userOverride)
  }

  @Test
  func testUserRemovalWinsSameCategoryAndRejectsLaterSystemAddition() async throws {
    let keyStore = try preparedCategorySyncKeyStore()
    let service = categoryAssignmentSync(
      keyStore: keyStore,
      transport: RecordingCategorySyncTransport()
    )
    let messageId = "gmail:account:message-001"
    _ = try await service.saveAssignment(
      MessageCategoryAssignment(
        categoryId: "system:flights",
        stableProviderMessageId: messageId
      ),
      session: session
    )
    _ = try await service.saveUserOverride(
      MessageCategoryAssignment(
        memberships: [
          MessageCategoryMembership(
            categoryId: "system:flights",
            isIncluded: false,
            overrideTimestamp: 100,
            source: .userOverride
          )
        ],
        stableProviderMessageId: messageId
      ),
      session: session
    )

    let result = try await service.saveAssignment(
      MessageCategoryAssignment(
        categoryId: "system:flights",
        stableProviderMessageId: messageId
      ),
      session: session
    )

    #expect(result.categoryIds.isEmpty)
    #expect(
      result.memberships == [
        MessageCategoryMembership(
          categoryId: "system:flights",
          isIncluded: false,
          overrideTimestamp: 100,
          source: .userOverride
        )
      ])
  }

  @Test
  func testDelayedSystemAssignmentsMergeDifferentCategories() async throws {
    let keyStore = try preparedCategorySyncKeyStore()
    let transport = RecordingCategorySyncTransport()
    let firstDevice = categoryAssignmentSync(keyStore: keyStore, transport: transport)
    let delayedDevice = categoryAssignmentSync(keyStore: keyStore, transport: transport)
    let firstAssignment = MessageCategoryAssignment(
      categoryId: "system:flights",
      stableProviderMessageId: "gmail:account:message-001"
    )

    _ = try await firstDevice.saveAssignment(firstAssignment, session: session)
    let delayedResult = try await delayedDevice.saveAssignment(
      MessageCategoryAssignment(
        categoryId: "system:promotions",
        stableProviderMessageId: firstAssignment.stableProviderMessageId
      ),
      session: session
    )
    let syncedAssignment = try await delayedDevice.loadAssignment(
      stableProviderMessageId: firstAssignment.stableProviderMessageId,
      session: session
    )

    #expect(delayedResult.categoryIds == ["system:flights", "system:promotions"])
    #expect(syncedAssignment?.categoryIds == ["system:flights", "system:promotions"])
  }

  @Test
  func testDelayedUserAssignmentBeatsConcurrentSystemAssignment() async throws {
    let keyStore = try preparedCategorySyncKeyStore()
    let concurrentTransport = RecordingCategorySyncTransport()
    let concurrentDevice = categoryAssignmentSync(
      keyStore: keyStore,
      transport: concurrentTransport
    )
    let stableProviderMessageId = "gmail:account:message-001"
    _ = try await concurrentDevice.saveAssignment(
      MessageCategoryAssignment(
        categoryId: "system:promotions",
        stableProviderMessageId: stableProviderMessageId
      ),
      session: session
    )

    let transport = RecordingCategorySyncTransport()
    transport.conditionalConflictPayload = concurrentTransport.writes.first {
      $0.payloadIdentifier.hasPrefix("message-categories-v2:")
    }
    let delayedDevice = categoryAssignmentSync(keyStore: keyStore, transport: transport)
    let userAssignment = MessageCategoryAssignment(
      categoryId: "system:invoices",
      learningSignal: FutureLearningSignal(
        appliesAfterTimestamp: 200,
        categoryId: "system:invoices",
        overrideTimestamp: 200,
        senderAddresses: ["sender@example.com"]
      ),
      overrideTimestamp: 200,
      source: .userOverride,
      stableProviderMessageId: stableProviderMessageId
    )

    let delayedResult = try await delayedDevice.saveUserOverride(userAssignment, session: session)
    let syncedAssignment = try await delayedDevice.loadAssignment(
      stableProviderMessageId: stableProviderMessageId,
      session: session
    )

    #expect(delayedResult.categoryIds == ["system:invoices", "system:promotions"])
    #expect(syncedAssignment?.categoryIds == ["system:invoices", "system:promotions"])
    #expect(
      syncedAssignment?.memberships.first { $0.categoryId == "system:invoices" }?.source
        == .userOverride)
  }

  @Test
  func testDelayedCompetingUserAssignmentsKeepFirstAssignment() async throws {
    let keyStore = try preparedCategorySyncKeyStore()
    let concurrentTransport = RecordingCategorySyncTransport()
    let concurrentDevice = categoryAssignmentSync(
      keyStore: keyStore,
      transport: concurrentTransport
    )
    let stableProviderMessageId = "gmail:account:message-001"
    let firstAssignment = MessageCategoryAssignment(
      categoryId: "system:flights",
      overrideTimestamp: 100,
      source: .userOverride,
      stableProviderMessageId: stableProviderMessageId
    )
    _ = try await concurrentDevice.saveUserOverride(firstAssignment, session: session)

    let transport = RecordingCategorySyncTransport()
    transport.conditionalConflictPayload = concurrentTransport.writes.first {
      $0.payloadIdentifier.hasPrefix("message-categories-v2:")
    }
    let delayedDevice = categoryAssignmentSync(keyStore: keyStore, transport: transport)
    let delayedResult = try await delayedDevice.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: "system:invoices",
        overrideTimestamp: 200,
        source: .userOverride,
        stableProviderMessageId: stableProviderMessageId
      ),
      session: session
    )
    let syncedAssignment = try await delayedDevice.loadAssignment(
      stableProviderMessageId: stableProviderMessageId,
      session: session
    )

    #expect(delayedResult.categoryIds == ["system:flights", "system:invoices"])
    #expect(syncedAssignment?.categoryIds == ["system:flights", "system:invoices"])
  }

  @Test
  func testCompetingUserAssignmentsWithSameTimestampKeepFirstAssignment() async throws {
    let keyStore = try preparedCategorySyncKeyStore()
    let transport = RecordingCategorySyncTransport()
    let firstDevice = categoryAssignmentSync(keyStore: keyStore, transport: transport)
    let delayedDevice = categoryAssignmentSync(keyStore: keyStore, transport: transport)
    let stableProviderMessageId = "gmail:account:message-001"
    let firstAssignment = MessageCategoryAssignment(
      categoryId: "system:flights",
      overrideTimestamp: 100,
      source: .userOverride,
      stableProviderMessageId: stableProviderMessageId
    )
    _ = try await firstDevice.saveUserOverride(firstAssignment, session: session)

    let delayedResult = try await delayedDevice.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: "system:invoices",
        overrideTimestamp: 100,
        source: .userOverride,
        stableProviderMessageId: stableProviderMessageId
      ),
      session: session
    )
    let syncedAssignment = try await delayedDevice.loadAssignment(
      stableProviderMessageId: stableProviderMessageId,
      session: session
    )

    #expect(delayedResult.categoryIds == ["system:flights", "system:invoices"])
    #expect(syncedAssignment?.categoryIds == ["system:flights", "system:invoices"])
  }

  @Test
  func testSaveUserOverrideKeepsFirstSystemSourcedAssignmentAgainstCompetingSystemSource()
    async throws
  {
    let keyStore = try preparedCategorySyncKeyStore()
    let transport = RecordingCategorySyncTransport()
    let service = categoryAssignmentSync(keyStore: keyStore, transport: transport)
    let stableProviderMessageId = "gmail:account:message-001"
    let firstAssignment = MessageCategoryAssignment(
      categoryId: "system:flights",
      source: .system,
      stableProviderMessageId: stableProviderMessageId
    )
    _ = try await service.saveUserOverride(firstAssignment, session: session)

    let result = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: "system:promotions",
        source: .system,
        stableProviderMessageId: stableProviderMessageId
      ),
      session: session
    )
    let synced = try await service.loadAssignment(
      stableProviderMessageId: stableProviderMessageId,
      session: session
    )

    #expect(result.categoryIds == ["system:flights", "system:promotions"])
    #expect(synced?.categoryIds == ["system:flights", "system:promotions"])
  }

  @Test
  func testFinalCompetingUserAssignmentResolvesWithoutExhaustingRetries() async throws {
    let keyStore = try preparedCategorySyncKeyStore()
    let systemTransport = RecordingCategorySyncTransport()
    let systemDevice = categoryAssignmentSync(keyStore: keyStore, transport: systemTransport)
    let userTransport = RecordingCategorySyncTransport()
    let userDevice = categoryAssignmentSync(keyStore: keyStore, transport: userTransport)
    let stableProviderMessageId = "gmail:account:message-001"
    _ = try await systemDevice.saveAssignment(
      MessageCategoryAssignment(
        categoryId: "system:promotions",
        stableProviderMessageId: stableProviderMessageId
      ),
      session: session
    )
    let firstUserAssignment = MessageCategoryAssignment(
      categoryId: "system:flights",
      overrideTimestamp: 100,
      source: .userOverride,
      stableProviderMessageId: stableProviderMessageId
    )
    _ = try await userDevice.saveUserOverride(firstUserAssignment, session: session)

    let transport = RecordingCategorySyncTransport()
    transport.conditionalConflictPayloads = [
      systemTransport.writes[0],
      systemTransport.writes[0],
      userTransport.writes[0],
    ]
    let delayedDevice = categoryAssignmentSync(keyStore: keyStore, transport: transport)
    let delayedResult = try await delayedDevice.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: "system:invoices",
        overrideTimestamp: 200,
        source: .userOverride,
        stableProviderMessageId: stableProviderMessageId
      ),
      session: session
    )
    let syncedAssignment = try await delayedDevice.loadAssignment(
      stableProviderMessageId: stableProviderMessageId,
      session: session
    )

    #expect(delayedResult.categoryIds == ["system:flights", "system:invoices"])
    #expect(syncedAssignment?.categoryIds == ["system:flights", "system:invoices"])
  }

  @Test
  func testSaveUserOverrideRejectsSystemSourcedAssignmentOverExistingUserOverride() async throws {
    let keyStore = try preparedCategorySyncKeyStore()
    let transport = RecordingCategorySyncTransport()
    let service = categoryAssignmentSync(keyStore: keyStore, transport: transport)
    let stableProviderMessageId = "gmail:account:message-001"
    let userOverride = MessageCategoryAssignment(
      categoryId: "system:invoices",
      overrideTimestamp: 100,
      source: .userOverride,
      stableProviderMessageId: stableProviderMessageId
    )
    _ = try await service.saveUserOverride(userOverride, session: session)

    let result = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: "system:flights",
        source: .system,
        stableProviderMessageId: stableProviderMessageId
      ),
      session: session
    )
    let synced = try await service.loadAssignment(
      stableProviderMessageId: stableProviderMessageId,
      session: session
    )

    #expect(result.categoryIds == ["system:flights", "system:invoices"])
    #expect(synced?.categoryIds == ["system:flights", "system:invoices"])
    #expect(
      synced?.memberships.first { $0.categoryId == "system:invoices" }?.source == .userOverride)
  }

  @Test
  func testAssignmentSyncStopsRetryingPersistentCategoryAssignmentConflicts() async throws {
    let keyStore = try preparedCategorySyncKeyStore()
    let concurrentTransport = RecordingCategorySyncTransport()
    let concurrentDevice = categoryAssignmentSync(
      keyStore: keyStore,
      transport: concurrentTransport
    )
    let stableProviderMessageId = "gmail:account:message-001"
    _ = try await concurrentDevice.saveAssignment(
      MessageCategoryAssignment(
        categoryId: "system:promotions",
        stableProviderMessageId: stableProviderMessageId
      ),
      session: session
    )

    let transport = RecordingCategorySyncTransport()
    transport.conditionalConflictPayload = concurrentTransport.writes.first {
      $0.payloadIdentifier.hasPrefix("message-categories-v2:")
    }
    transport.repeatsConditionalConflictPayload = true
    let delayedDevice = categoryAssignmentSync(keyStore: keyStore, transport: transport)

    do {
      _ = try await delayedDevice.saveUserOverride(
        MessageCategoryAssignment(
          categoryId: "system:invoices",
          overrideTimestamp: 200,
          source: .userOverride,
          stableProviderMessageId: stableProviderMessageId
        ),
        session: session
      )
      Issue.record("Expected conditional write retries to be bounded")
    } catch let error as MessageCategoryAssignmentSyncError {
      #expect(error == .conditionalWriteRetryLimitExceeded)
    }
  }

  @Test
  func testAssignmentSyncEncryptsCategoryByStableProviderMessageIdentity() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let assignment = MessageCategoryAssignment(
      categoryId: "system:flights",
      stableProviderMessageId: "gmail:account:message-001"
    )

    _ = try await service.saveAssignment(assignment, session: session)

    #expect(
      transport.writes[0].payloadIdentifier
        == "message-categories-v2:c4eb5f942e6e9253e3b111ad5568b02a09e47acce70aa36936854bb59e33bcc1")
    #expect(!(transport.writes[0].encryptedPayload.ciphertextBase64.contains("flights")))
    let loadedAssignment = try await service.loadAssignment(
      stableProviderMessageId: assignment.stableProviderMessageId,
      session: session
    )
    #expect(loadedAssignment == assignment)
  }

  @Test
  func testAssignmentSyncRejectsMismatchedDecodedMessageIdentity() async throws {
    let keyStore = try preparedCategorySyncKeyStore()
    let material = try requireValue(keyStore.load(productAccountId: session.productAccountId))
    let transport = RecordingCategorySyncTransport()
    let identifier =
      "message-categories-v2:c4eb5f942e6e9253e3b111ad5568b02a09e47acce70aa36936854bb59e33bcc1"
    _ = try await transport.putEncryptedProductSyncPayloadIfUnchanged(
      session: session,
      payloadIdentifier: identifier,
      encryptedPayload: try material.encryptPayload(
        JSONEncoder().encode(
          MessageCategoryAssignment(
            categoryId: "system:flights",
            stableProviderMessageId: "gmail:account:other-message"
          )
        ),
        associatedData: Data(identifier.utf8)
      ),
      expectedUpdatedAt: nil
    )
    let service = categoryAssignmentSync(keyStore: keyStore, transport: transport)

    do {
      _ = try await service.loadAssignment(
        stableProviderMessageId: "gmail:account:message-001",
        session: session
      )
      Issue.record("Expected the decoded message identity mismatch to be rejected")
    } catch let error as MessageCategoryAssignmentSyncError {
      #expect(error == .invalidStableProviderMessageIdentity)
    }
  }

  @Test
  func testAssignmentWritesIgnoreInvalidLegacyRecord() async throws {
    let keyStore = try preparedCategorySyncKeyStore()
    let material = try requireValue(keyStore.load(productAccountId: session.productAccountId))
    let transport = RecordingCategorySyncTransport()
    let legacyIdentifier =
      "message-category:c4eb5f942e6e9253e3b111ad5568b02a09e47acce70aa36936854bb59e33bcc1"
    _ = try await transport.putEncryptedProductSyncPayloadIfUnchanged(
      session: session,
      payloadIdentifier: legacyIdentifier,
      encryptedPayload: try material.encryptPayload(
        JSONEncoder().encode(
          MessageCategoryAssignment(
            categoryId: "system:people",
            stableProviderMessageId: "gmail:account:other-message"
          )
        ),
        associatedData: Data(legacyIdentifier.utf8)
      ),
      expectedUpdatedAt: nil
    )
    let service = categoryAssignmentSync(keyStore: keyStore, transport: transport)

    _ = try await service.saveAssignment(
      MessageCategoryAssignment(
        categoryId: "system:flights",
        stableProviderMessageId: "gmail:account:message-001"
      ),
      session: session
    )
    let result = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: "system:invoices",
        overrideTimestamp: 100,
        source: .userOverride,
        stableProviderMessageId: "gmail:account:message-001"
      ),
      session: session
    )

    #expect(result.categoryIds == ["system:flights", "system:invoices"])
  }

  @Test
  func testAssignmentSyncStoresOneEncryptedSignalPayloadPerCategoryAndSender() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let newestSignal = FutureLearningSignal(
      appliesAfterTimestamp: 200,
      categoryId: "system:flights",
      senderAddresses: ["updates@merchant.example"]
    )
    _ = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: newestSignal.categoryId,
        learningSignal: FutureLearningSignal(
          appliesAfterTimestamp: newestSignal.appliesAfterTimestamp,
          categoryId: newestSignal.categoryId,
          senderAddresses: ["updates@merchant.example"]
        ),
        source: .userOverride,
        stableProviderMessageId: "gmail:account:message-001"
      ),
      session: session
    )
    _ = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: "system:promotions",
        learningSignal: FutureLearningSignal(
          appliesAfterTimestamp: 100,
          categoryId: "system:promotions",
          senderAddresses: ["updates@merchant.example"]
        ),
        source: .userOverride,
        stableProviderMessageId: "gmail:account:message-002"
      ),
      session: session
    )

    let signals = try await service.loadFutureLearningSignals(
      identities: newestSignal.identities,
      session: session
    )

    #expect(signals == [newestSignal])
    #expect(
      transport.writes.filter {
        $0.payloadIdentifier.hasPrefix("message-category-learning-signal-v2:")
      }.count == 2)
  }

  @Test
  func testAssignmentSyncLoadsLearningSignalCreatedBeforeKeyRotation() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    let original = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let signal = FutureLearningSignal(
      appliesAfterTimestamp: 100,
      categoryId: "system:invoices",
      senderAddresses: ["billing@example.com"]
    )
    _ = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: signal.categoryId,
        learningSignal: signal,
        source: .userOverride,
        stableProviderMessageId: "gmail:account:message-before-rotation"
      ),
      session: session
    )
    try keyStore.save(
      original.rotatingAccountKey(
        toVersion: 2,
        accountKeyData: Data(repeating: 7, count: ProductSyncKeyMaterial.keyByteCount)
      ),
      productAccountId: session.productAccountId
    )

    let signals = try await service.loadFutureLearningSignals(
      identities: signal.identities,
      session: session
    )

    #expect(signals == [signal])
    #expect(transport.loadedPayloadIdentifierBatches.last?.count == 2)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testAssignmentSyncSkipsCorruptOtherCategorySignalAfterKeyRotation()
    async throws
  {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    let original = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let senderAddresses = ["billing@example.com"]
    _ = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: "system:invoices",
        learningSignal: FutureLearningSignal(
          appliesAfterTimestamp: 300,
          categoryId: "system:invoices",
          senderAddresses: senderAddresses
        ),
        source: .userOverride,
        stableProviderMessageId: "gmail:account:message-before-rotation"
      ),
      session: session
    )
    try keyStore.save(
      original.rotatingAccountKey(
        toVersion: 2,
        accountKeyData: Data(repeating: 7, count: ProductSyncKeyMaterial.keyByteCount)
      ),
      productAccountId: session.productAccountId
    )
    transport.corruptLastPayload()
    let replacement = FutureLearningSignal(
      appliesAfterTimestamp: 100,
      categoryId: "system:flights",
      overrideTimestamp: 400,
      senderAddresses: senderAddresses
    )

    _ = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: replacement.categoryId,
        learningSignal: replacement,
        source: .userOverride,
        stableProviderMessageId: "gmail:account:message-after-rotation"
      ),
      session: session
    )
    let learningSignalPayloads = transport.writes.filter {
      $0.payloadIdentifier.hasPrefix("message-category-learning-signal-v2:")
    }
    #expect(learningSignalPayloads.count == 2)
    #expect(Set(learningSignalPayloads.map(\.encryptedPayload.keyVersion)) == [1, 2])
    let signals = try await service.loadFutureLearningSignals(
      identities: replacement.identities,
      session: session
    )

    #expect(signals == [replacement])
  }

  @Test
  func testAssignmentSyncLoadsOnlyRequestedLearningSignals() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let requestedSignal = FutureLearningSignal(
      appliesAfterTimestamp: 100,
      categoryId: "system:invoices",
      senderAddresses: ["requested@example.com"]
    )
    let unrelatedSignal = FutureLearningSignal(
      appliesAfterTimestamp: 200,
      categoryId: "system:promotions",
      senderAddresses: ["unrelated@example.com"]
    )
    for (index, signal) in [requestedSignal, unrelatedSignal].enumerated() {
      _ = try await service.saveUserOverride(
        MessageCategoryAssignment(
          categoryId: signal.categoryId,
          learningSignal: signal,
          source: .userOverride,
          stableProviderMessageId: "gmail:account:message-\(index)"
        ),
        session: session
      )
    }

    let signals = try await service.loadFutureLearningSignals(
      identities: requestedSignal.identities,
      session: session
    )

    #expect(signals == [requestedSignal])
    #expect(transport.loadedPayloadIdentifierBatches.last?.count == 1)
  }

  @Test
  func testAssignmentSyncPreservesNewestPerMessageOverride() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let newestOverride = MessageCategoryAssignment(
      categoryId: "system:flights",
      learningSignal: FutureLearningSignal(
        appliesAfterTimestamp: 200,
        categoryId: "system:flights",
        senderAddresses: ["updates@merchant.example"]
      ),
      source: .userOverride,
      stableProviderMessageId: "gmail:account:message-001"
    )
    _ = try await service.saveUserOverride(newestOverride, session: session)

    let staleResult = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: "system:promotions",
        learningSignal: FutureLearningSignal(
          appliesAfterTimestamp: 100,
          categoryId: "system:promotions",
          senderAddresses: ["updates@merchant.example"]
        ),
        source: .userOverride,
        stableProviderMessageId: newestOverride.stableProviderMessageId
      ),
      session: session
    )
    let synced = try await service.loadAssignment(
      stableProviderMessageId: newestOverride.stableProviderMessageId,
      session: session
    )

    #expect(staleResult.categoryIds == ["system:flights", "system:promotions"])
    #expect(synced?.categoryIds == ["system:flights", "system:promotions"])
  }

  @Test
  func testAssignmentSyncOrdersOverridesSeparatelyFromClampedLearningBoundary() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let stableProviderMessageId = "gmail:account:message-001"
    _ = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: "system:invoices",
        learningSignal: FutureLearningSignal(
          appliesAfterTimestamp: 200,
          categoryId: "system:invoices",
          senderAddresses: ["updates@merchant.example"]
        ),
        overrideTimestamp: 100,
        source: .userOverride,
        stableProviderMessageId: stableProviderMessageId
      ),
      session: session
    )

    let newestOverride = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: "system:flights",
        learningSignal: FutureLearningSignal(
          appliesAfterTimestamp: 200,
          categoryId: "system:flights",
          senderAddresses: ["updates@merchant.example"]
        ),
        overrideTimestamp: 150,
        source: .userOverride,
        stableProviderMessageId: stableProviderMessageId
      ),
      session: session
    )

    #expect(newestOverride.categoryId == "system:flights")
    #expect(newestOverride.overrideTimestamp == 150)
    #expect(newestOverride.learningSignal?.appliesAfterTimestamp == 200)
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testAssignmentSyncOrdersSenderSignalsByOverrideTimestamp() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore, transport: RecordingCategorySyncTransport())
    )
    let senderAddresses = ["updates@merchant.example"]
    _ = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: "system:invoices",
        learningSignal: FutureLearningSignal(
          appliesAfterTimestamp: 300,
          categoryId: "system:invoices",
          overrideTimestamp: 100,
          senderAddresses: senderAddresses
        ),
        source: .userOverride,
        stableProviderMessageId: "gmail:account:later-message"
      ),
      session: session
    )

    _ = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: "system:flights",
        learningSignal: FutureLearningSignal(
          appliesAfterTimestamp: 200,
          categoryId: "system:flights",
          overrideTimestamp: 150,
          senderAddresses: senderAddresses
        ),
        source: .userOverride,
        stableProviderMessageId: "gmail:account:earlier-message"
      ),
      session: session
    )

    let signals = try await service.loadFutureLearningSignals(
      identities: ["system:invoices", "system:flights"].map {
        FutureLearningSignalIdentity(categoryId: $0, senderAddress: senderAddresses[0])
      },
      session: session
    )

    #expect(
      signals == [
        FutureLearningSignal(
          appliesAfterTimestamp: 200,
          categoryId: "system:flights",
          overrideTimestamp: 150,
          senderAddresses: senderAddresses
        ),
        FutureLearningSignal(
          appliesAfterTimestamp: 300,
          categoryId: "system:invoices",
          overrideTimestamp: 100,
          senderAddresses: senderAddresses
        ),
      ])
  }

  @Test
  func testAssignmentSyncPreservesOriginalLowerBoundForUnchangedCategory() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let originalSignal = FutureLearningSignal(
      appliesAfterTimestamp: 100,
      categoryId: "system:invoices",
      senderAddresses: ["updates@merchant.example"]
    )
    _ = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: originalSignal.categoryId,
        learningSignal: originalSignal,
        source: .userOverride,
        stableProviderMessageId: "gmail:account:message-001"
      ),
      session: session
    )
    _ = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: originalSignal.categoryId,
        learningSignal: FutureLearningSignal(
          appliesAfterTimestamp: 200,
          categoryId: originalSignal.categoryId,
          senderAddresses: originalSignal.senderAddresses
        ),
        source: .userOverride,
        stableProviderMessageId: "gmail:account:message-002"
      ),
      session: session
    )

    let signals = try await service.loadFutureLearningSignals(
      identities: originalSignal.identities,
      session: session
    )

    #expect(signals == [originalSignal])
  }

  @Test
  func testAssignmentSyncPreservesEarlierSameCategorySignalAfterConcurrentUpdate() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let concurrentTransport = RecordingCategorySyncTransport()
    let concurrentService = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore, transport: concurrentTransport)
    )
    let laterSignal = FutureLearningSignal(
      appliesAfterTimestamp: 200,
      categoryId: "system:invoices",
      senderAddresses: ["updates@merchant.example"]
    )
    _ = try await concurrentService.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: laterSignal.categoryId,
        learningSignal: laterSignal,
        source: .userOverride,
        stableProviderMessageId: "gmail:account:later-message"
      ),
      session: session
    )

    let transport = RecordingCategorySyncTransport()
    transport.conditionalConflictPayload = concurrentTransport.writes.first {
      $0.payloadIdentifier.hasPrefix("message-category-learning-signal-v2:")
    }
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let earlierSignal = FutureLearningSignal(
      appliesAfterTimestamp: 100,
      categoryId: laterSignal.categoryId,
      senderAddresses: laterSignal.senderAddresses
    )
    _ = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: earlierSignal.categoryId,
        learningSignal: earlierSignal,
        source: .userOverride,
        stableProviderMessageId: "gmail:account:earlier-message"
      ),
      session: session
    )

    let signals = try await service.loadFutureLearningSignals(
      identities: earlierSignal.identities,
      session: session
    )

    #expect(signals == [earlierSignal])
  }

  @Test
  func testAssignmentSyncDoesNotConflictAcrossCategorySignals() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let concurrentTransport = RecordingCategorySyncTransport()
    let concurrentService = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore, transport: concurrentTransport)
    )
    let concurrentSignal = FutureLearningSignal(
      appliesAfterTimestamp: 100,
      categoryId: "system:promotions",
      senderAddresses: ["offers@merchant.example"]
    )
    _ = try await concurrentService.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: concurrentSignal.categoryId,
        learningSignal: concurrentSignal,
        source: .userOverride,
        stableProviderMessageId: "gmail:account:concurrent-message"
      ),
      session: session
    )

    let transport = RecordingCategorySyncTransport()
    transport.conditionalConflictPayload = concurrentTransport.writes.first {
      $0.payloadIdentifier.hasPrefix("message-category-learning-signal-v2:")
    }
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    )

    let localSignal = FutureLearningSignal(
      appliesAfterTimestamp: 200,
      categoryId: "system:flights",
      senderAddresses: concurrentSignal.senderAddresses
    )
    _ = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: localSignal.categoryId,
        learningSignal: localSignal,
        source: .userOverride,
        stableProviderMessageId: "gmail:account:local-message"
      ),
      session: session
    )

    #expect(
      try await service.loadFutureLearningSignals(
        identities: localSignal.identities,
        session: session
      ) == [localSignal]
    )
  }

  @Test
  func testAssignmentSyncRetriesConcurrentLearningSignalUpdate() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let concurrentTransport = RecordingCategorySyncTransport()
    let concurrentService = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore, transport: concurrentTransport)
    )
    let concurrentSignal = FutureLearningSignal(
      appliesAfterTimestamp: 100,
      categoryId: "system:promotions",
      senderAddresses: ["offers@merchant.example"]
    )
    _ = try await concurrentService.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: concurrentSignal.categoryId,
        learningSignal: concurrentSignal,
        source: .userOverride,
        stableProviderMessageId: "gmail:account:concurrent-message"
      ),
      session: session
    )

    let transport = RecordingCategorySyncTransport()
    transport.conditionalConflictPayload = concurrentTransport.writes.first {
      $0.payloadIdentifier.hasPrefix("message-category-learning-signal-v2:")
    }
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let localSignal = FutureLearningSignal(
      appliesAfterTimestamp: 200,
      categoryId: "system:flights",
      senderAddresses: concurrentSignal.senderAddresses
    )
    _ = try await service.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: localSignal.categoryId,
        learningSignal: localSignal,
        source: .userOverride,
        stableProviderMessageId: "gmail:account:local-message"
      ),
      session: session
    )

    let signals = try await service.loadFutureLearningSignals(
      identities: localSignal.identities,
      session: session
    )

    #expect(signals == [localSignal])
  }

  @Test
  func testConditionalWriteRejectsStaleExpectationWhenPayloadIsMissing() async {
    let transport = RecordingCategorySyncTransport()

    do {
      _ = try await transport.putEncryptedProductSyncPayloadIfUnchanged(
        session: session,
        payloadIdentifier: "message-category-learning-signals",
        encryptedPayload: ProductSyncEncryptedPayload(
          algorithm: ProductSyncEncryptedPayload.algorithmName,
          ciphertextBase64: "ciphertext",
          keyVersion: 1,
          nonceBase64: "nonce",
          schemaVersion: 1,
          tagBase64: "tag"
        ),
        expectedUpdatedAt: 1
      )
      Issue.record("Expected a stale conditional write to fail")
    } catch let error as URLError {
      #expect(error.code == .badServerResponse)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(transport.writes.isEmpty)
  }

  @Test
  func testAssignmentSyncRequiresExistingProductSyncKeyMaterial() async throws {
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
        transport: RecordingCategorySyncTransport())
    )

    do {
      _ = try await service.saveAssignment(
        MessageCategoryAssignment(
          categoryId: "system:flights",
          stableProviderMessageId: "gmail:account:message-001"
        ),
        session: session
      )
      Issue.record("Expected Product Sync key material recovery to be required")
    } catch let error as MessageCategoryAssignmentSyncError {
      #expect(error == .missingProductSyncKeyMaterial)
    }
  }

  private func message(
    categoryId: String? = nil,
    from: String? = "Sender <sender@example.com>",
    isHistorical: Bool = false,
    messageId: String = "message-001",
    providerInternalDateMilliseconds: Int64 = 1_781_300_000_000,
    replyTo: String? = nil,
    snippet: String = "Message snippet",
    subject: String = "Message subject"
  ) -> GmailMessageMetadata {
    GmailMessageMetadata(
      categoryId: categoryId,
      from: from,
      isHistorical: isHistorical,
      providerAccountIdentifier: "account",
      providerInternalDateMilliseconds: providerInternalDateMilliseconds,
      providerMessageId: messageId,
      providerThreadId: "thread-001",
      replyTo: replyTo,
      snippet: snippet,
      stableProviderMessageId: "gmail:account:\(messageId)",
      subject: subject,
      rfcMessageId: nil
    )
  }

  private func preparedCategorySyncKeyStore() throws -> InMemoryProductSyncKeyMaterialStore {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    return keyStore
  }

  private func categoryAssignmentSync(
    keyStore: InMemoryProductSyncKeyMaterialStore,
    transport: RecordingCategorySyncTransport
  ) -> MessageCategoryAssignmentSyncService {
    MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(
        keyMaterialStore: keyStore,
        transport: transport
      )
    )
  }

  private func backgroundContextCache(
    cachedAtMilliseconds: Int64,
    learningSignals: [FutureLearningSignal] = [],
    senderAddress: String = "sender@example.com"
  ) -> BackgroundCategorizationContextCache {
    BackgroundCategorizationContextCache(
      customCategory: nil,
      customCategoryCachedAtMilliseconds: cachedAtMilliseconds,
      learningSignalsBySender: [
        senderAddress: BackgroundCategorizationSenderContext(
          cachedAtMilliseconds: cachedAtMilliseconds,
          learningSignals: learningSignals
        )
      ]
    )
  }

  private func assertBackgroundCategorizationFailsClosed(
    _ testCase: InvalidBackgroundContextCase
  ) async throws {
    let cacheStore = InMemoryBackgroundContextCacheStore()
    cacheStore.caches["\(session.productAccountId):account"] = testCase.cache
    cacheStore.loadError = testCase.loadError
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    assignmentSync.shouldFailLearningSignalLoad = true
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      backgroundContextCacheStore: cacheStore,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: FailingCustomCategorySync(),
      currentTimeMilliseconds: { testCase.now },
      engine: RuleBasedClassificationEngine()
    )
    let categorized = try await service.categorizeForBackgroundNotification(
      messages: [message(subject: "Flight confirmation")],
      recordScope: .legacyProductAccount, session: session
    )
    #expect(categorized[0].categoryId == nil, Comment(rawValue: testCase.name))
  }
}

extension MessageCategorizationServiceTests {
  @Test
  func testAuthenticatedCategorizationRefreshesBackgroundContextWithExplicitAbsence()
    async throws
  {
    let cacheStore = InMemoryBackgroundContextCacheStore()
    cacheStore.caches["\(session.productAccountId):account"] =
      BackgroundCategorizationContextCache(
        customCategory: CustomCategory(name: "Private", description: "Encrypted"),
        customCategoryCachedAtMilliseconds: 1,
        learningSignalsBySender: [
          "sender@example.com": BackgroundCategorizationSenderContext(
            cachedAtMilliseconds: 1,
            learningSignals: [
              FutureLearningSignal(
                appliesAfterTimestamp: 1,
                categoryId: "custom-category-primary",
                senderAddresses: ["sender@example.com"]
              )
            ]
          )
        ]
      )
    let service = GmailMessageCategorizationService(
      assignmentSync: RecordingMessageCategoryAssignmentSync(),
      backgroundContextCacheStore: cacheStore,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      currentTimeMilliseconds: { 1_781_400_000_000 },
      engine: RecordingClassificationEngine(decisions: [.uncategorized])
    )

    _ = try await service.categorize(
      messages: [message()], recordScope: .legacyProductAccount, session: session)

    #expect(
      cacheStore.caches["\(session.productAccountId):account"]
        == BackgroundCategorizationContextCache(
          customCategory: nil,
          customCategoryCachedAtMilliseconds: 1_781_400_000_000,
          learningSignalsBySender: [
            "sender@example.com": BackgroundCategorizationSenderContext(
              cachedAtMilliseconds: 1_781_400_000_000,
              learningSignals: []
            )
          ]
        ))
  }

  @Test
  func testAuthenticatedCategorizationCachesLearningSignalsFromPrefetchedOverrides()
    async throws
  {
    let cacheStore = InMemoryBackgroundContextCacheStore()
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    assignmentSync.assignmentsByMessageId["gmail:account:message-001"] = MessageCategoryAssignment(
      categoryId: "system:flights",
      learningSignal: FutureLearningSignal(
        appliesAfterTimestamp: 1,
        categoryId: "system:flights",
        senderAddresses: ["override@example.com"]
      ),
      source: .userOverride,
      stableProviderMessageId: "gmail:account:message-001"
    )
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      backgroundContextCacheStore: cacheStore,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      currentTimeMilliseconds: { 1_781_400_000_000 },
      engine: RecordingClassificationEngine(decisions: [.uncategorized])
    )

    _ = try await service.categorize(
      messages: [
        message(from: "Override <override@example.com>", messageId: "message-001"),
        message(from: "Other <other@example.com>", messageId: "message-002"),
      ],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(
      cacheStore.caches["\(session.productAccountId):account"]?
        .learningSignalsBySender["override@example.com"]?
        .learningSignals == [
          FutureLearningSignal(
            appliesAfterTimestamp: 1,
            categoryId: "system:flights",
            senderAddresses: ["override@example.com"]
          )
        ])
  }

  @Test
  func testForegroundCategorizationContinuesWhenBackgroundContextCacheCannotBeSaved()
    async throws
  {
    let cacheStore = InMemoryBackgroundContextCacheStore()
    cacheStore.saveError = KeychainStoreError.unexpectedData
    let service = GmailMessageCategorizationService(
      assignmentSync: RecordingMessageCategoryAssignmentSync(),
      backgroundContextCacheStore: cacheStore,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: RecordingClassificationEngine(decisions: [.assigned(categoryIds: ["system:flights"])])
    )

    let categorized = try await service.categorize(
      messages: [message()], recordScope: .legacyProductAccount, session: session)

    #expect(categorized[0].categoryId == "system:flights")
  }

  @Test
  func testBackgroundCategorizationUsesFreshExactSenderContextWhenProductSyncFails()
    async throws
  {
    let cacheStore = InMemoryBackgroundContextCacheStore()
    cacheStore.caches["\(session.productAccountId):account"] =
      BackgroundCategorizationContextCache(
        customCategory: nil,
        customCategoryCachedAtMilliseconds: 1_781_400_000_000,
        learningSignalsBySender: [
          "sender@example.com": BackgroundCategorizationSenderContext(
            cachedAtMilliseconds: 1_781_400_000_000,
            learningSignals: [
              FutureLearningSignal(
                appliesAfterTimestamp: 1_781_300_000_000,
                categoryId: "system:flights",
                senderAddresses: ["sender@example.com"]
              )
            ]
          )
        ]
      )
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    assignmentSync.shouldFailLearningSignalLoad = true
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      backgroundContextCacheStore: cacheStore,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: FailingCustomCategorySync(),
      currentTimeMilliseconds: { 1_781_400_000_001 },
      engine: RuleBasedClassificationEngine()
    )

    let categorized = try await service.categorizeForBackgroundNotification(
      messages: [
        message(
          providerInternalDateMilliseconds: 1_781_300_000_001,
          snippet: "A neutral update",
          subject: "Account update"
        )
      ],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized[0].categoryId == "system:flights")
    #expect(assignmentSync.savedAssignments.isEmpty)
  }

  @Test
  func testBackgroundCategorizationClearsCacheWhenLearningSignalsAuthenticationFails()
    async throws
  {
    let cacheStore = InMemoryBackgroundContextCacheStore()
    cacheStore.caches["\(session.productAccountId):account"] = backgroundContextCache(
      cachedAtMilliseconds: 1_781_400_000_000,
      learningSignals: [
        FutureLearningSignal(
          appliesAfterTimestamp: 1,
          categoryId: "system:flights",
          senderAddresses: ["sender@example.com"]
        )
      ]
    )
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    assignmentSync.learningSignalLoadError = ConvexClientError.convexFailure(
      status: "error",
      message: "Authentication required"
    )
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      backgroundContextCacheStore: cacheStore,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      currentTimeMilliseconds: { 1_781_400_000_000 },
      engine: RuleBasedClassificationEngine()
    )

    let categorized = try await service.categorizeForBackgroundNotification(
      messages: [message(subject: "Flight confirmation")],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized[0].categoryId == nil)
    #expect(cacheStore.caches["\(session.productAccountId):account"] == nil)
  }

  @Test
  func testBackgroundCategorizationClearsCacheWhenLearningSignalsLoadFails() async throws {
    let cacheStore = InMemoryBackgroundContextCacheStore()
    cacheStore.caches["\(session.productAccountId):account"] = backgroundContextCache(
      cachedAtMilliseconds: 1_781_400_000_000
    )
    cacheStore.caches["\(session.productAccountId):other-account"] = backgroundContextCache(
      cachedAtMilliseconds: 1_781_400_000_000
    )
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    assignmentSync.learningSignalLoadError = URLError(.cannotConnectToHost)
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      backgroundContextCacheStore: cacheStore,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      currentTimeMilliseconds: { 1_781_400_000_000 },
      engine: RuleBasedClassificationEngine()
    )

    _ = try await service.categorizeForBackgroundNotification(
      messages: [message(subject: "Flight confirmation")],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(cacheStore.caches["\(session.productAccountId):account"] == nil)
    #expect(cacheStore.caches["\(session.productAccountId):other-account"] != nil)
  }

  @Test
  func testBackgroundCategorizationDoesNotUseCacheForNonAuthenticationFailure() async throws {
    let cachedAtMilliseconds: Int64 = 1_781_400_000_000
    let cacheStore = InMemoryBackgroundContextCacheStore()
    cacheStore.caches["\(session.productAccountId):account"] = backgroundContextCache(
      cachedAtMilliseconds: cachedAtMilliseconds,
      learningSignals: [
        FutureLearningSignal(
          appliesAfterTimestamp: 1_781_300_000_000,
          categoryId: "system:flights",
          senderAddresses: ["sender@example.com"]
        )
      ]
    )
    let service = GmailMessageCategorizationService(
      assignmentSync: RecordingMessageCategoryAssignmentSync(),
      backgroundContextCacheStore: cacheStore,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: FailingCustomCategorySync(loadError: URLError(.cannotConnectToHost)),
      currentTimeMilliseconds: { cachedAtMilliseconds },
      engine: RuleBasedClassificationEngine()
    )

    let categorized = try await service.categorizeForBackgroundNotification(
      messages: [message(subject: "Flight confirmation")],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized[0].categoryId == nil)
  }

  @Test
  func testBackgroundCategorizationFailsClosedForInvalidCachedContext() async throws {
    let cachedAtMilliseconds: Int64 = 1_781_400_000_000
    let validCache = backgroundContextCache(cachedAtMilliseconds: cachedAtMilliseconds)
    let cases: [InvalidBackgroundContextCase] = [
      .init(name: "missing", cache: nil, now: cachedAtMilliseconds),
      .init(name: "expired", cache: validCache, now: cachedAtMilliseconds + 86_400_001),
      .init(
        name: "corrupt",
        cache: validCache,
        loadError: URLError(.cannotDecodeContentData),
        now: cachedAtMilliseconds
      ),
      .init(
        name: "other sender",
        cache: backgroundContextCache(
          cachedAtMilliseconds: cachedAtMilliseconds,
          senderAddress: "other@example.com"
        ),
        now: cachedAtMilliseconds
      ),
      .init(
        name: "mismatched signal",
        cache: backgroundContextCache(
          cachedAtMilliseconds: cachedAtMilliseconds,
          learningSignals: [
            FutureLearningSignal(
              appliesAfterTimestamp: 1,
              categoryId: "system:flights",
              senderAddresses: ["other@example.com"]
            )
          ]
        ),
        now: cachedAtMilliseconds
      ),
    ]

    for testCase in cases {
      try await assertBackgroundCategorizationFailsClosed(testCase)
    }
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testBackgroundCategorizationContextIsEncryptedAndConnectionScopedInKeychain() throws {
    let productAccountId = "background-categorization-\(UUID().uuidString)"
    let otherProductAccountId = "background-categorization-\(UUID().uuidString)"
    let providerAccountIdentifier = "gmail-user-001"
    let otherProviderAccountIdentifier = "gmail-user-002"
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: productAccountId,
      allowCreation: true
    )
    _ = try keyMaterialStore.ensureMaterial(
      productAccountId: otherProductAccountId,
      allowCreation: true
    )
    let store = KeychainBackgroundContextCacheStore(
      keyMaterialStore: keyMaterialStore
    )
    let cache = BackgroundCategorizationContextCache(
      customCategory: CustomCategory(name: "Private", description: "Encrypted category"),
      customCategoryCachedAtMilliseconds: 1_781_400_000_000,
      learningSignalsBySender: [
        "sender@example.com": BackgroundCategorizationSenderContext(
          cachedAtMilliseconds: 1_781_400_000_000,
          learningSignals: []
        )
      ]
    )
    defer {
      try? store.clear(productAccountId: productAccountId)
      try? store.clear(productAccountId: otherProductAccountId)
    }

    try store.save(
      cache,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    let otherCache = BackgroundCategorizationContextCache(
      customCategory: nil,
      customCategoryCachedAtMilliseconds: 1_781_400_000_001,
      learningSignalsBySender: [:]
    )
    try store.save(
      otherCache,
      productAccountId: productAccountId,
      providerAccountIdentifier: otherProviderAccountIdentifier
    )

    let rawValue = try requireValue(
      KeychainStore.readString(
        service: KeychainBackgroundContextCacheStore.serviceName,
        account: "gmail.\(gmailSafeFileComponent(productAccountId))."
          + gmailSafeFileComponent(providerAccountIdentifier)
      ))
    #expect(!(rawValue.contains("Private")))
    #expect(!(rawValue.contains("sender@example.com")))
    #expect(
      try store.load(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      ) == cache)
    #expect(
      try store.load(
        productAccountId: productAccountId,
        providerAccountIdentifier: otherProviderAccountIdentifier
      ) == otherCache)
    #expect(
      try store.load(
        productAccountId: otherProductAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      ) == nil)
    try store.clear(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    #expect(
      try store.load(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      ) == nil)
    #expect(
      try store.load(
        productAccountId: productAccountId,
        providerAccountIdentifier: otherProviderAccountIdentifier
      ) == otherCache)
  }

  @Test
  func testBackgroundCategorizationMigratesLegacyAccountCacheToConnectionScope() throws {
    let productAccountId = "background-categorization-legacy-\(UUID().uuidString)"
    let providerAccountIdentifier = "gmail-user-001"
    let keyMaterialStore = InMemoryProductSyncKeyMaterialStore()
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: productAccountId,
      allowCreation: true
    )
    let store = KeychainBackgroundContextCacheStore(
      keyMaterialStore: keyMaterialStore
    )
    let cache = BackgroundCategorizationContextCache(
      customCategory: CustomCategory(name: "Legacy", description: "Migrated category"),
      customCategoryCachedAtMilliseconds: 1_781_400_000_000,
      learningSignalsBySender: [:]
    )
    let encryptedPayload = try material.encryptPayload(
      JSONEncoder().encode(cache),
      associatedData: Data(
        "dev.unwired.mail.background-categorization-context.v1".utf8
      )
    )
    let rawValue = try requireValue(
      String(data: JSONEncoder().encode(encryptedPayload), encoding: .utf8))
    defer {
      try? store.clear(productAccountId: productAccountId)
    }
    try KeychainStore.writeString(
      rawValue,
      service: KeychainBackgroundContextCacheStore.serviceName,
      account: productAccountId,
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )

    #expect(
      try store.load(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      ) == cache)
    #expect(
      try KeychainStore.readString(
        service: KeychainBackgroundContextCacheStore.serviceName,
        account: productAccountId
      ) == nil)
    #expect(
      try store.load(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      ) == cache)
  }

  @Test
  func testAssignmentSyncKeepsValidAssignmentsWhenAnotherPayloadIsCorrupt() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let validAssignment = MessageCategoryAssignment(
      categoryId: "system:flights",
      stableProviderMessageId: "gmail:account:message-001"
    )
    let corruptAssignment = MessageCategoryAssignment(
      categoryId: "system:invoices",
      stableProviderMessageId: "gmail:account:message-002"
    )
    _ = try await service.saveAssignment(validAssignment, session: session)
    _ = try await service.saveAssignment(corruptAssignment, session: session)
    transport.corruptLastPayload()

    let assignments = try await service.loadAssignments(
      stableProviderMessageIds: [
        validAssignment.stableProviderMessageId,
        corruptAssignment.stableProviderMessageId,
      ],
      session: session
    )

    #expect(assignments == [validAssignment.stableProviderMessageId: validAssignment])
  }

  @Test
  func testAssignmentSyncAcceptsDuplicateStableProviderMessageIdentities() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      recordBoundary: ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    )
    let assignment = MessageCategoryAssignment(
      categoryId: "system:flights",
      stableProviderMessageId: "gmail:account:message-001"
    )
    _ = try await service.saveAssignment(assignment, session: session)

    let assignments = try await service.loadAssignments(
      stableProviderMessageIds: [
        assignment.stableProviderMessageId,
        assignment.stableProviderMessageId,
      ],
      session: session
    )

    #expect(assignments == [assignment.stableProviderMessageId: assignment])
    #expect(transport.loadedPayloadIdentifierBatches.last?.count == 1)
  }

  @Test
  func testCategorizationDelegatesLargeAssignmentPrefetchAsOneDomainRead() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: FailingClassificationEngine()
    )
    let messages = (0...4_000).map { message(messageId: "message-\($0)") }

    _ = try await service.categorize(
      messages: messages, recordScope: .legacyProductAccount, session: session)

    #expect(assignmentSync.loadedAssignmentBatches.map(\.count) == [4_001])
  }

  @Test
  func testCategorizationContinuesWhenAssignmentPrefetchFails() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    assignmentSync.shouldFailBatchLoad = true
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: FailingClassificationEngine()
    )

    let categorized = try await service.categorize(
      messages: [message()],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized[0].categoryId == nil)
  }

  @Test
  func testCategorizationStopsWhenLearningSignalsFailToLoad() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    assignmentSync.shouldFailLearningSignalLoad = true
    let engine = RecordingClassificationEngine(
      decisions: [.assigned(categoryIds: ["system:promotions"])]
    )
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: engine
    )

    let categorized = try await service.categorize(
      messages: [message()],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized[0].categoryId == nil)
    #expect(engine.inputs.isEmpty)
    #expect(assignmentSync.savedAssignments.isEmpty)
  }

  @Test
  func testCategorizationStopsWhenCustomCategoryLoadFails() async throws {
    let engine = RecordingClassificationEngine(
      decisions: [.assigned(categoryIds: ["system:flights"])]
    )
    let service = GmailMessageCategorizationService(
      assignmentSync: RecordingMessageCategoryAssignmentSync(),
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: FailingCustomCategorySync(),
      engine: engine
    )

    let categorized = try await service.categorize(
      messages: [message(subject: "Flight confirmation")],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized[0].categoryId == nil)
    #expect(engine.inputs.isEmpty)
  }

  @Test
  func testCategorizationStopsWhenAssignmentSaveFails() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    assignmentSync.saveError = URLError(.userAuthenticationRequired)
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: RecordingClassificationEngine(decisions: [.assigned(categoryIds: ["system:flights"])])
    )

    let categorized = try await service.categorize(
      messages: [message(subject: "Flight confirmation")],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(categorized[0].categoryId == nil)
  }

  @Test
  func testCategorizationLoadsSignalsOnlyForEligibleCurrentSenders() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: RecordingClassificationEngine(decisions: [.uncategorized])
    )

    _ = try await service.categorize(
      messages: [
        message(from: "Current <current@example.com>"),
        message(
          categoryId: "system:invoices",
          from: "Categorized <categorized@example.com>",
          messageId: "message-002"
        ),
        message(
          from: "Historical <historical@example.com>",
          isHistorical: true,
          messageId: "message-003"
        ),
      ],
      recordScope: .legacyProductAccount, session: session
    )

    #expect(assignmentSync.loadedLearningSignalSenderAddresses == ["current@example.com"])
  }
}

private struct InvalidBackgroundContextCase {
  let name: String
  let cache: BackgroundCategorizationContextCache?
  let loadError: Error?
  let now: Int64

  init(
    name: String,
    cache: BackgroundCategorizationContextCache?,
    loadError: Error? = nil,
    now: Int64
  ) {
    self.name = name
    self.cache = cache
    self.loadError = loadError
    self.now = now
  }
}

private final class RecordingClassificationEngine: ClassificationEngine {
  private var decisions: [ClassificationDecision]
  private(set) var categoryIds: [[String]] = []
  private(set) var inputs: [ClassificationInput] = []

  init(decisions: [ClassificationDecision]) {
    self.decisions = decisions
  }

  func classify(
    input: ClassificationInput,
    categories: [MessageClassificationCategory]
  ) async throws -> ClassificationDecision {
    inputs.append(input)
    categoryIds.append(categories.map(\.id))
    return decisions.removeFirst()
  }
}

private struct FailingClassificationEngine: ClassificationEngine {
  func classify(
    input _: ClassificationInput,
    categories _: [MessageClassificationCategory]
  ) async throws -> ClassificationDecision {
    throw URLError(.cannotDecodeContentData)
  }
}

private final class RecordingCachedBodyReader: GmailCachedMessageBodyReading {
  private let bodyHTML: String?
  private(set) var loadedMessageIds: [String] = []
  private let bodyText: String?

  init(bodyHTML: String? = nil, bodyText: String?) {
    self.bodyHTML = bodyHTML
    self.bodyText = bodyText
  }

  func loadCachedMessageBody(
    message: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws -> GmailMessageBody? {
    loadedMessageIds.append(message.stableProviderMessageId)
    return bodyText.map { GmailMessageBody(text: $0, html: bodyHTML) }
  }
}

private final class RecordingMessageCategoryAssignmentSync: MessageCategoryAssignmentSyncing {
  var assignmentsByMessageId: [String: MessageCategoryAssignment] = [:]
  var shouldFailBatchLoad = false
  var shouldFailLearningSignalLoad = false
  var learningSignalLoadError: Error?
  private(set) var loadedAssignmentBatches: [[String]] = []
  private(set) var loadedLearningSignalSenderAddresses: [String] = []
  private(set) var loadedMessageIds: [String] = []
  private(set) var savedAssignments: [MessageCategoryAssignment] = []
  private(set) var savedUserOverrides: [MessageCategoryAssignment] = []
  var saveError: Error?

  func loadAssignments(
    stableProviderMessageIds: [String],
    session _: ProductAccountSessionSnapshot
  ) async throws -> [String: MessageCategoryAssignment] {
    loadedAssignmentBatches.append(stableProviderMessageIds)
    if shouldFailBatchLoad {
      throw URLError(.cannotConnectToHost)
    }
    return assignmentsByMessageId
  }

  func loadAssignment(
    stableProviderMessageId: String,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment? {
    loadedMessageIds.append(stableProviderMessageId)
    return assignmentsByMessageId[stableProviderMessageId]
  }

  func loadFutureLearningSignals(
    identities: [FutureLearningSignalIdentity],
    session _: ProductAccountSessionSnapshot
  ) async throws -> [FutureLearningSignal] {
    loadedLearningSignalSenderAddresses = Array(Set(identities.map(\.senderAddress))).sorted()
    if let learningSignalLoadError {
      throw learningSignalLoadError
    }
    if shouldFailLearningSignalLoad {
      throw URLError(.cannotConnectToHost)
    }
    return assignmentsByMessageId.values.flatMap(\.memberships).compactMap { membership in
      guard membership.source == .userOverride, let signal = membership.learningSignal else {
        return nil
      }
      return signal.identities.contains(where: Set(identities).contains) ? signal : nil
    }
  }

  func saveAssignment(
    _ assignment: MessageCategoryAssignment,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment {
    if let saveError {
      throw saveError
    }
    savedAssignments.append(assignment)
    assignmentsByMessageId[assignment.stableProviderMessageId] = assignment
    return assignment
  }

  func saveUserOverride(
    _ assignment: MessageCategoryAssignment,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment {
    savedUserOverrides.append(assignment)
    assignmentsByMessageId[assignment.stableProviderMessageId] = assignment
    return assignment
  }
}

private final class InMemoryBackgroundContextCacheStore:
  BackgroundContextCachePersisting
{
  var caches: [String: BackgroundCategorizationContextCache] = [:]
  var clearError: Error?
  var loadError: Error?
  var saveError: Error?

  func clear(productAccountId: String) throws {
    if let clearError { throw clearError }
    caches = caches.filter { !$0.key.hasPrefix("\(productAccountId):") }
  }

  func clear(productAccountId: String, providerAccountIdentifier: String) throws {
    if let clearError { throw clearError }
    caches["\(productAccountId):\(providerAccountIdentifier)"] = nil
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> BackgroundCategorizationContextCache? {
    if let loadError { throw loadError }
    return caches["\(productAccountId):\(providerAccountIdentifier)"]
  }

  func save(
    _ cache: BackgroundCategorizationContextCache,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    if let saveError { throw saveError }
    caches["\(productAccountId):\(providerAccountIdentifier)"] = cache
  }
}

private struct StubCustomCategorySync: CustomCategorySyncing {
  let configuration: CategoryConfiguration

  init(configuration: CategoryConfiguration = .default) {
    self.configuration = configuration
  }

  func loadConfiguration(session _: ProductAccountSessionSnapshot) async throws
    -> CategoryConfiguration
  {
    configuration
  }

  func deleteCategory(session _: ProductAccountSessionSnapshot) async throws {}

  func loadCategory(session _: ProductAccountSessionSnapshot) async throws -> CustomCategory? {
    nil
  }

  func saveCategory(
    _ category: CustomCategory,
    session _: ProductAccountSessionSnapshot
  ) async throws -> CustomCategory {
    category
  }
}

private actor CountingCustomCategorySync: CustomCategorySyncing {
  private(set) var loadConfigurationCount = 0

  func loadConfiguration(session _: ProductAccountSessionSnapshot) async throws
    -> CategoryConfiguration
  {
    loadConfigurationCount += 1
    return .default
  }

  func deleteCategory(session _: ProductAccountSessionSnapshot) async throws {}

  func loadCategory(session _: ProductAccountSessionSnapshot) async throws -> CustomCategory? {
    nil
  }

  func saveCategory(
    _ category: CustomCategory,
    session _: ProductAccountSessionSnapshot
  ) async throws -> CustomCategory {
    category
  }
}

private struct FailingCustomCategorySync: CustomCategorySyncing {
  let loadError: Error

  init(
    loadError: Error = ConvexClientError.convexFailure(
      status: "error",
      message: "Authentication required"
    )
  ) {
    self.loadError = loadError
  }

  func deleteCategory(session _: ProductAccountSessionSnapshot) async throws {}

  func loadCategory(session _: ProductAccountSessionSnapshot) async throws -> CustomCategory? {
    throw loadError
  }

  func saveCategory(
    _ category: CustomCategory,
    session _: ProductAccountSessionSnapshot
  ) async throws -> CustomCategory {
    category
  }
}

private final class RecordingCategorySyncTransport: ProductSyncRecordTransport {
  var conditionalConflictPayload: EncryptedProductSyncPayload?
  var conditionalConflictPayloads: [EncryptedProductSyncPayload] = []
  var repeatsConditionalConflictPayload = false
  private(set) var loadedPayloadIdentifierBatches: [[String]] = []
  private(set) var writes: [EncryptedProductSyncPayload] = []
  private var updatedAt: Int64 = 1_781_300_000_000

  func corruptLastPayload() {
    let payload = writes.removeLast()
    writes.append(
      EncryptedProductSyncPayload(
        encryptedPayload: ProductSyncEncryptedPayload(
          algorithm: payload.encryptedPayload.algorithm,
          ciphertextBase64: "invalid",
          keyVersion: payload.encryptedPayload.keyVersion,
          nonceBase64: payload.encryptedPayload.nonceBase64,
          schemaVersion: payload.encryptedPayload.schemaVersion,
          tagBase64: payload.encryptedPayload.tagBase64
        ),
        payloadIdentifier: payload.payloadIdentifier,
        updatedAt: payload.updatedAt
      )
    )
  }

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
    loadedPayloadIdentifierBatches.append(payloadIdentifiers)
    return writes.filter { payloadIdentifiers.contains($0.payloadIdentifier) }
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    session _: ProductAccountSessionSnapshot,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    expectedUpdatedAt: Int64?
  ) async throws -> EncryptedProductSyncPayload {
    if !conditionalConflictPayloads.isEmpty {
      let conflictPayload = conditionalConflictPayloads.removeFirst()
      writes.removeAll { $0.payloadIdentifier == payloadIdentifier }
      writes.append(conflictPayload)
      return conflictPayload
    }
    if let conflictPayload = conditionalConflictPayload,
      conflictPayload.payloadIdentifier == payloadIdentifier
    {
      if !repeatsConditionalConflictPayload {
        conditionalConflictPayload = nil
      }
      writes.removeAll { $0.payloadIdentifier == payloadIdentifier }
      writes.append(conflictPayload)
      return conflictPayload
    }
    let existingPayload = writes.first { $0.payloadIdentifier == payloadIdentifier }
    if existingPayload == nil, expectedUpdatedAt != nil {
      throw URLError(.badServerResponse)
    }
    if let existingPayload, existingPayload.updatedAt != expectedUpdatedAt {
      return existingPayload
    }
    updatedAt += 1
    let payload = EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: updatedAt
    )
    writes.removeAll { $0.payloadIdentifier == payloadIdentifier }
    writes.append(payload)
    return payload
  }
}
