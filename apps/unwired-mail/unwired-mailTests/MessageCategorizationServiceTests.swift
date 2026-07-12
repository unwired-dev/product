import XCTest

@testable import unwired_mail

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

  func testAssignmentSyncEncryptsCategoryByStableProviderMessageIdentity() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
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

  private func message(
    categoryId: String? = nil,
    isHistorical: Bool = false,
    messageId: String = "message-001"
  ) -> GmailMessageMetadata {
    GmailMessageMetadata(
      categoryId: categoryId,
      from: "Sender <sender@example.com>",
      isHistorical: isHistorical,
      providerAccountIdentifier: "account",
      providerInternalDateMilliseconds: 1_781_300_000_000,
      providerMessageId: messageId,
      providerThreadId: "thread-001",
      replyTo: nil,
      snippet: "Message snippet",
      stableProviderMessageId: "gmail:account:\(messageId)",
      subject: "Message subject",
      rfcMessageId: nil
    )
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
  private(set) var loadedMessageIds: [String] = []
  private(set) var savedAssignments: [MessageCategoryAssignment] = []

  func loadAssignment(
    stableProviderMessageId: String,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment? {
    loadedMessageIds.append(stableProviderMessageId)
    return assignmentsByMessageId[stableProviderMessageId]
  }

  func saveAssignment(
    _ assignment: MessageCategoryAssignment,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment {
    savedAssignments.append(assignment)
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

private final class RecordingCategorySyncTransport: ProductSyncPayloadTransport {
  private(set) var writes: [EncryptedProductSyncPayload] = []

  func getEncryptedProductSyncPayload(
    identityToken _: String,
    payloadIdentifier: String
  ) async throws -> EncryptedProductSyncPayload? {
    writes.first { $0.payloadIdentifier == payloadIdentifier }
  }

  func listEncryptedProductSyncPayloads(
    identityToken _: String
  ) async throws -> [EncryptedProductSyncPayload] {
    writes
  }

  func putEncryptedProductSyncPayload(
    identityToken _: String,
    payloadIdentifier: String,
    encryptedPayload: ProductSyncEncryptedPayload,
    trustedDeviceId _: String
  ) async throws -> EncryptedProductSyncPayload {
    let payload = EncryptedProductSyncPayload(
      encryptedPayload: encryptedPayload,
      payloadIdentifier: payloadIdentifier,
      updatedAt: 1_781_300_000_000
    )
    writes.removeAll { $0.payloadIdentifier == payloadIdentifier }
    writes.append(payload)
    return payload
  }
}
