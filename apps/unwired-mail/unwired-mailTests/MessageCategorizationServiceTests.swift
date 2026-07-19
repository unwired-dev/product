import XCTest

@testable import unwired_mail

// swiftlint:disable file_length

final class MessageCategorizationServiceTests: XCTestCase {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "apple-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

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

    XCTAssertEqual(decision, .assigned(categoryId: "system:flights"))
  }

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

    XCTAssertEqual(decision, .assigned(categoryId: customCategory.id))
  }

  func testCategorizationLoadsBodyOnlyWhenMinimizedInputNeedsIt() async throws {
    let engine = RecordingClassificationEngine(
      decisions: [.needsBody, .assigned(categoryId: "system:invoices")]
    )
    let bodyReader = RecordingCachedBodyReader(bodyText: "Invoice total: 42 EUR")
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: bodyReader,
      categorySync: StubCustomCategorySync(),
      engine: engine
    )

    let categorized = try await service.categorize(
      messages: [message()],
      session: session
    )

    XCTAssertEqual(engine.inputs.map(\.bodyText), [nil, "Invoice total: 42 EUR"])
    XCTAssertEqual(bodyReader.loadedMessageIds, ["gmail:account:message-001"])
    XCTAssertEqual(categorized[0].categoryId, "system:invoices")
    XCTAssertEqual(
      assignmentSync.savedAssignments,
      [
        MessageCategoryAssignment(
          categoryId: "system:invoices",
          stableProviderMessageId: "gmail:account:message-001"
        )
      ]
    )
  }

  func testCategorizationDoesNotLoadBodyWhenMinimizedInputAssignsCategory() async throws {
    let engine = RecordingClassificationEngine(
      decisions: [.assigned(categoryId: "system:promotions")]
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
      session: session
    )

    XCTAssertEqual(engine.inputs.count, 1)
    XCTAssertTrue(bodyReader.loadedMessageIds.isEmpty)
    XCTAssertEqual(categorized[0].categoryId, "system:promotions")
  }

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
      session: session
    )

    XCTAssertNil(categorized[0].categoryId)
    XCTAssertEqual(bodyReader.loadedMessageIds, ["gmail:account:message-001"])
    XCTAssertTrue(assignmentSync.savedAssignments.isEmpty)
  }

  func testCategorizationLeavesMessageUncategorizedWhenClassificationFails() async throws {
    let service = GmailMessageCategorizationService(
      assignmentSync: RecordingMessageCategoryAssignmentSync(),
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: FailingClassificationEngine()
    )

    let categorized = try await service.categorize(
      messages: [message()],
      session: session
    )

    XCTAssertNil(categorized[0].categoryId)
  }

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
      session: session
    )

    XCTAssertEqual(categorized, [historical, assigned])
    XCTAssertTrue(engine.inputs.isEmpty)
    XCTAssertTrue(bodyReader.loadedMessageIds.isEmpty)
    XCTAssertEqual(
      assignmentSync.loadedAssignmentBatches,
      [[historical.stableProviderMessageId, assigned.stableProviderMessageId]]
    )
    XCTAssertTrue(assignmentSync.loadedMessageIds.isEmpty)
    XCTAssertTrue(assignmentSync.savedAssignments.isEmpty)
  }

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
      session: session
    )

    XCTAssertEqual(categorized[0].categoryId, "custom-category-primary")
    XCTAssertTrue(engine.inputs.isEmpty)
    XCTAssertTrue(assignmentSync.savedAssignments.isEmpty)
  }

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
      session: session
    )

    XCTAssertEqual(categorized[0].categoryId, "system:flights")
    XCTAssertTrue(assignmentSync.savedAssignments.isEmpty)
  }
}

extension MessageCategorizationServiceTests {
  func testHistoricalCategorizationOnlyClassifiesMessagesInSelectedDateRange() async throws {
    let engine = RecordingClassificationEngine(
      decisions: [.assigned(categoryId: "system:promotions")]
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
      session: session
    )

    XCTAssertEqual(categorized.map(\.categoryId), [nil, "system:promotions", nil, nil])
    XCTAssertEqual(engine.inputs.map(\.minimized.providerInternalDateMilliseconds), [200])
    XCTAssertEqual(assignmentSync.loadedAssignmentBatches, [[inScope.stableProviderMessageId]])
    XCTAssertEqual(
      assignmentSync.savedAssignments,
      [
        MessageCategoryAssignment(
          categoryId: "system:promotions",
          stableProviderMessageId: inScope.stableProviderMessageId
        )
      ]
    )
  }

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
      session: session
    )

    XCTAssertEqual(categorized.map(\.categoryId), ["system:flights", "system:promotions"])
    XCTAssertTrue(engine.inputs.isEmpty)
    XCTAssertTrue(assignmentSync.savedAssignments.isEmpty)
  }

  func testHistoricalCategorizationDateRangeIgnoresTimeComponents() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    let selectedDay = Date(timeIntervalSince1970: 0)

    XCTAssertTrue(
      GmailHistoricalCategorizationScope.isValidDateRange(
        startDate: selectedDay.addingTimeInterval(82_800),
        endDate: selectedDay.addingTimeInterval(3_600),
        calendar: calendar
      )
    )
    XCTAssertFalse(
      GmailHistoricalCategorizationScope.isValidDateRange(
        startDate: selectedDay.addingTimeInterval(86_400),
        endDate: selectedDay,
        calendar: calendar
      )
    )
  }
}

extension MessageCategorizationServiceTests {
  func testUserCanOverrideHistoricalUncategorizedMessage() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
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

    XCTAssertEqual(overridden.categoryId, "system:invoices")
    XCTAssertEqual(
      assignmentSync.savedUserOverrides,
      [
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
      ]
    )
  }

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
      session: session
    )

    XCTAssertNil(categorized[0].categoryId)
    XCTAssertEqual(categorized[1].categoryId, "system:invoices")
    XCTAssertNil(categorized[2].categoryId)
    XCTAssertEqual(categorized[3].categoryId, "system:flights")
  }

  func testNewestMatchingFutureLearningSignalWinsAcrossCategories() async throws {
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

    XCTAssertEqual(decision, .assigned(categoryId: "system:flights"))
  }

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

    XCTAssertEqual(
      assignmentSync.savedUserOverrides.first?.learningSignal?.senderAddresses,
      ["receipts@shop.example"]
    )
  }

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

    XCTAssertEqual(
      assignmentSync.savedUserOverrides.first?.learningSignal?.appliesAfterTimestamp,
      200
    )
  }

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

    XCTAssertEqual(
      assignmentSync.savedUserOverrides.first?.learningSignal?.appliesAfterTimestamp,
      200
    )
  }

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
      session: session
    )

    XCTAssertEqual(categorized[0].categoryId, "system:invoices")
    XCTAssertTrue(engine.inputs.isEmpty)
  }

  func testSystemAssignmentCannotOverwriteSyncedUserOverride() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let syncService = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: transport
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

    XCTAssertEqual(systemResult, userOverride)
    XCTAssertEqual(synced, userOverride)
    XCTAssertFalse(transport.writes[0].encryptedPayload.ciphertextBase64.contains("userOverride"))
  }

  func testDelayedSystemAssignmentsKeepFirstAssignment() async throws {
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

    XCTAssertEqual(delayedResult, firstAssignment)
    XCTAssertEqual(syncedAssignment, firstAssignment)
  }

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
      $0.payloadIdentifier.hasPrefix("message-category:")
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

    XCTAssertEqual(delayedResult, userAssignment)
    XCTAssertEqual(syncedAssignment, userAssignment)
  }

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
      $0.payloadIdentifier.hasPrefix("message-category:")
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

    XCTAssertEqual(delayedResult, firstAssignment)
    XCTAssertEqual(syncedAssignment, firstAssignment)
  }

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

    XCTAssertEqual(delayedResult, firstAssignment)
    XCTAssertEqual(syncedAssignment, firstAssignment)
  }

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

    XCTAssertEqual(result, firstAssignment)
    XCTAssertEqual(synced, firstAssignment)
  }

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

    XCTAssertEqual(delayedResult, firstUserAssignment)
    XCTAssertEqual(syncedAssignment, firstUserAssignment)
  }

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

    XCTAssertEqual(result, userOverride)
    XCTAssertEqual(synced, userOverride)
  }

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
      $0.payloadIdentifier.hasPrefix("message-category:")
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
      XCTFail("Expected conditional write retries to be bounded")
    } catch let error as MessageCategoryAssignmentSyncError {
      XCTAssertEqual(error, .conditionalWriteRetryLimitExceeded)
    }
  }

  func testAssignmentSyncEncryptsCategoryByStableProviderMessageIdentity() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: transport
    )
    let assignment = MessageCategoryAssignment(
      categoryId: "system:flights",
      stableProviderMessageId: "gmail:account:message-001"
    )

    _ = try await service.saveAssignment(assignment, session: session)

    XCTAssertEqual(
      transport.writes[0].payloadIdentifier,
      "message-category:c4eb5f942e6e9253e3b111ad5568b02a09e47acce70aa36936854bb59e33bcc1"
    )
    XCTAssertFalse(transport.writes[0].encryptedPayload.ciphertextBase64.contains("flights"))
    let loadedAssignment = try await service.loadAssignment(
      stableProviderMessageId: assignment.stableProviderMessageId,
      session: session
    )
    XCTAssertEqual(loadedAssignment, assignment)
  }

  func testAssignmentSyncStoresOneBoundedEncryptedSignalPayloadPerSender() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: transport
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
      senderAddresses: newestSignal.senderAddresses,
      session: session
    )

    XCTAssertEqual(signals, [newestSignal])
    XCTAssertEqual(
      transport.writes.filter {
        $0.payloadIdentifier.hasPrefix("message-category-learning-signal:")
      }.count,
      1
    )
  }

  func testAssignmentSyncLoadsOnlyRequestedLearningSignals() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: transport
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
      senderAddresses: requestedSignal.senderAddresses,
      session: session
    )

    XCTAssertEqual(signals, [requestedSignal])
    XCTAssertEqual(transport.loadedPayloadIdentifierBatches.map(\.count), [1])
  }

  func testAssignmentSyncPreservesNewestPerMessageOverride() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: transport
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

    XCTAssertEqual(staleResult, newestOverride)
    XCTAssertEqual(synced, newestOverride)
  }

  func testAssignmentSyncOrdersOverridesSeparatelyFromClampedLearningBoundary() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: transport
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

    XCTAssertEqual(newestOverride.categoryId, "system:flights")
    XCTAssertEqual(newestOverride.overrideTimestamp, 150)
    XCTAssertEqual(newestOverride.learningSignal?.appliesAfterTimestamp, 200)
  }

  func testAssignmentSyncOrdersSenderSignalsByOverrideTimestamp() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let service = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: RecordingCategorySyncTransport()
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
      senderAddresses: senderAddresses,
      session: session
    )

    XCTAssertEqual(
      signals,
      [
        FutureLearningSignal(
          appliesAfterTimestamp: 200,
          categoryId: "system:flights",
          overrideTimestamp: 150,
          senderAddresses: senderAddresses
        )
      ]
    )
  }

  func testAssignmentSyncPreservesOriginalLowerBoundForUnchangedCategory() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: transport
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
      senderAddresses: originalSignal.senderAddresses,
      session: session
    )

    XCTAssertEqual(signals, [originalSignal])
  }

  func testAssignmentSyncPreservesEarlierSameCategorySignalAfterConcurrentUpdate() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let concurrentTransport = RecordingCategorySyncTransport()
    let concurrentService = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: concurrentTransport
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
      $0.payloadIdentifier.hasPrefix("message-category-learning-signal:")
    }
    let service = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: transport
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
      senderAddresses: earlierSignal.senderAddresses,
      session: session
    )

    XCTAssertEqual(signals, [earlierSignal])
  }

  func testAssignmentSyncStopsRetryingPersistentConditionalWriteConflicts() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let concurrentTransport = RecordingCategorySyncTransport()
    let concurrentService = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: concurrentTransport
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
      $0.payloadIdentifier.hasPrefix("message-category-learning-signal:")
    }
    transport.repeatsConditionalConflictPayload = true
    let service = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: transport
    )

    do {
      _ = try await service.saveUserOverride(
        MessageCategoryAssignment(
          categoryId: "system:flights",
          learningSignal: FutureLearningSignal(
            appliesAfterTimestamp: 200,
            categoryId: "system:flights",
            senderAddresses: concurrentSignal.senderAddresses
          ),
          source: .userOverride,
          stableProviderMessageId: "gmail:account:local-message"
        ),
        session: session
      )
      XCTFail("Expected conditional write retries to be bounded")
    } catch let error as MessageCategoryAssignmentSyncError {
      XCTAssertEqual(error, .conditionalWriteRetryLimitExceeded)
    }
  }

  func testAssignmentSyncRetriesConcurrentLearningSignalUpdate() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let concurrentTransport = RecordingCategorySyncTransport()
    let concurrentService = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: concurrentTransport
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
      $0.payloadIdentifier.hasPrefix("message-category-learning-signal:")
    }
    let service = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: transport
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
      senderAddresses: localSignal.senderAddresses,
      session: session
    )

    XCTAssertEqual(signals, [localSignal])
  }

  func testConditionalWriteRejectsStaleExpectationWhenPayloadIsMissing() async {
    let transport = RecordingCategorySyncTransport()

    do {
      _ = try await transport.putEncryptedProductSyncPayloadIfUnchanged(
        identityToken: "apple-token",
        payloadIdentifier: "message-category-learning-signals",
        encryptedPayload: ProductSyncEncryptedPayload(
          algorithm: ProductSyncEncryptedPayload.algorithmName,
          ciphertextBase64: "ciphertext",
          keyVersion: 1,
          nonceBase64: "nonce",
          schemaVersion: 1,
          tagBase64: "tag"
        ),
        trustedDeviceId: "trusted-device-001",
        expectedUpdatedAt: 1
      )
      XCTFail("Expected a stale conditional write to fail")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .badServerResponse)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertTrue(transport.writes.isEmpty)
  }

  func testAssignmentSyncRequiresExistingProductSyncKeyMaterial() async throws {
    let service = MessageCategoryAssignmentSyncService(
      keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
      transport: RecordingCategorySyncTransport()
    )

    do {
      _ = try await service.saveAssignment(
        MessageCategoryAssignment(
          categoryId: "system:flights",
          stableProviderMessageId: "gmail:account:message-001"
        ),
        session: session
      )
      XCTFail("Expected Product Sync key material recovery to be required")
    } catch let error as ProductSyncKeyMaterialStoreError {
      XCTAssertEqual(error, .recoveryRequired)
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
    MessageCategoryAssignmentSyncService(keyMaterialStore: keyStore, transport: transport)
  }
}

extension MessageCategorizationServiceTests {
  func testAssignmentSyncKeepsValidAssignmentsWhenAnotherPayloadIsCorrupt() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = RecordingCategorySyncTransport()
    let service = MessageCategoryAssignmentSyncService(
      keyMaterialStore: keyStore,
      transport: transport
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

    XCTAssertEqual(assignments, [validAssignment.stableProviderMessageId: validAssignment])
  }

  func testCategorizationBatchesLargeAssignmentPrefetches() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: FailingClassificationEngine()
    )
    let messages = (0...4_000).map { message(messageId: "message-\($0)") }

    _ = try await service.categorize(messages: messages, session: session)

    XCTAssertEqual(assignmentSync.loadedAssignmentBatches.map(\.count), [4_000, 1])
  }

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
      session: session
    )

    XCTAssertNil(categorized[0].categoryId)
  }

  func testCategorizationStopsWhenLearningSignalsFailToLoad() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    assignmentSync.shouldFailLearningSignalLoad = true
    let engine = RecordingClassificationEngine(
      decisions: [.assigned(categoryId: "system:promotions")]
    )
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: engine
    )

    let categorized = try await service.categorize(
      messages: [message()],
      session: session
    )

    XCTAssertNil(categorized[0].categoryId)
    XCTAssertTrue(engine.inputs.isEmpty)
    XCTAssertTrue(assignmentSync.savedAssignments.isEmpty)
  }

  func testCategorizationStopsWhenCustomCategoryLoadFails() async throws {
    let engine = RecordingClassificationEngine(
      decisions: [.assigned(categoryId: "system:flights")]
    )
    let service = GmailMessageCategorizationService(
      assignmentSync: RecordingMessageCategoryAssignmentSync(),
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: FailingCustomCategorySync(),
      engine: engine
    )

    let categorized = try await service.categorize(
      messages: [message(subject: "Flight confirmation")],
      session: session
    )

    XCTAssertNil(categorized[0].categoryId)
    XCTAssertTrue(engine.inputs.isEmpty)
  }

  func testCategorizationStopsWhenAssignmentSaveFails() async throws {
    let assignmentSync = RecordingMessageCategoryAssignmentSync()
    assignmentSync.saveError = URLError(.userAuthenticationRequired)
    let service = GmailMessageCategorizationService(
      assignmentSync: assignmentSync,
      bodyReader: RecordingCachedBodyReader(bodyText: nil),
      categorySync: StubCustomCategorySync(),
      engine: RecordingClassificationEngine(decisions: [.assigned(categoryId: "system:flights")])
    )

    let categorized = try await service.categorize(
      messages: [message(subject: "Flight confirmation")],
      session: session
    )

    XCTAssertNil(categorized[0].categoryId)
  }

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
      session: session
    )

    XCTAssertEqual(assignmentSync.loadedLearningSignalSenderAddresses, ["current@example.com"])
  }
}

private final class RecordingClassificationEngine: ClassificationEngine {
  private var decisions: [ClassificationDecision]
  private(set) var inputs: [ClassificationInput] = []

  init(decisions: [ClassificationDecision]) {
    self.decisions = decisions
  }

  func classify(
    input: ClassificationInput,
    categories _: [MessageClassificationCategory]
  ) async throws -> ClassificationDecision {
    inputs.append(input)
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
  private(set) var loadedMessageIds: [String] = []
  private let bodyText: String?

  init(bodyText: String?) {
    self.bodyText = bodyText
  }

  func loadCachedMessageBody(
    message: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws -> GmailMessageBody? {
    loadedMessageIds.append(message.stableProviderMessageId)
    return bodyText.map(GmailMessageBody.init(text:))
  }
}

private final class RecordingMessageCategoryAssignmentSync: MessageCategoryAssignmentSyncing {
  var assignmentsByMessageId: [String: MessageCategoryAssignment] = [:]
  var shouldFailBatchLoad = false
  var shouldFailLearningSignalLoad = false
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
    senderAddresses: [String],
    session _: ProductAccountSessionSnapshot
  ) async throws -> [FutureLearningSignal] {
    loadedLearningSignalSenderAddresses = senderAddresses
    if shouldFailLearningSignalLoad {
      throw URLError(.cannotConnectToHost)
    }
    return assignmentsByMessageId.values.compactMap { assignment in
      guard assignment.source == .userOverride, let signal = assignment.learningSignal else {
        return nil
      }
      return Set(signal.senderAddresses).isDisjoint(with: Set(senderAddresses)) ? nil : signal
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

private struct StubCustomCategorySync: CustomCategorySyncing {
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
  func deleteCategory(session _: ProductAccountSessionSnapshot) async throws {}

  func loadCategory(session _: ProductAccountSessionSnapshot) async throws -> CustomCategory? {
    throw URLError(.userAuthenticationRequired)
  }

  func saveCategory(
    _ category: CustomCategory,
    session _: ProductAccountSessionSnapshot
  ) async throws -> CustomCategory {
    category
  }
}

private final class RecordingCategorySyncTransport: ProductSyncPayloadTransport {
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

  func getEncryptedProductSyncPayload(
    identityToken _: String,
    payloadIdentifier: String
  ) async throws -> EncryptedProductSyncPayload? {
    writes.first { $0.payloadIdentifier == payloadIdentifier }
  }

  func listEncryptedProductSyncPayloads(
    identityToken _: String,
    payloadIdentifierPrefix: String?
  ) async throws -> [EncryptedProductSyncPayload] {
    guard let payloadIdentifierPrefix else { return writes }
    return writes.filter { $0.payloadIdentifier.hasPrefix(payloadIdentifierPrefix) }
  }

  func getEncryptedProductSyncPayloads(
    identityToken _: String,
    payloadIdentifiers: [String]
  ) async throws -> [EncryptedProductSyncPayload] {
    loadedPayloadIdentifierBatches.append(payloadIdentifiers)
    return writes.filter { payloadIdentifiers.contains($0.payloadIdentifier) }
  }

  func putEncryptedProductSyncPayload(
    identityToken _: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload {
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

  func putEncryptedProductSyncPayloadIfAbsent(
    identityToken _: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload {
    if let existingPayload = writes.first(where: { $0.payloadIdentifier == payloadIdentifier }) {
      return existingPayload
    }
    let payload = EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: 1_781_300_000_000
    )
    writes.append(payload)
    return payload
  }

  func putEncryptedProductSyncPayloadIfUnchanged(
    identityToken _: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId _: String,
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
