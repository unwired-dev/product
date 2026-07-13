import CryptoKit
import Foundation

// swiftlint:disable file_length

struct MinimizedClassificationInput: Equatable {
  let from: String?
  let providerInternalDateMilliseconds: Int64
  let replyTo: String?
  let snippet: String
  let subject: String

  init(
    from: String?,
    replyTo: String?,
    snippet: String,
    subject: String,
    providerInternalDateMilliseconds: Int64 = .min
  ) {
    self.from = from
    self.providerInternalDateMilliseconds = providerInternalDateMilliseconds
    self.replyTo = replyTo
    self.snippet = snippet
    self.subject = subject
  }
}

struct ClassificationInput: Equatable {
  let bodyText: String?
  let minimized: MinimizedClassificationInput
}

struct MessageClassificationCategory: Equatable {
  let id: String
  let keywords: [String]
  let learningSignals: [FutureLearningSignal]

  init(id: String, keywords: [String], learningSignals: [FutureLearningSignal] = []) {
    self.id = id
    self.keywords = keywords
    self.learningSignals = learningSignals
  }

  static let systemCategories = [
    MessageClassificationCategory(
      id: "system:promotions",
      keywords: ["coupon", "discount", "offer", "promotion", "sale"]
    ),
    MessageClassificationCategory(
      id: "system:invites",
      keywords: ["invitation", "invite", "rsvp"]
    ),
    MessageClassificationCategory(
      id: "system:invoices",
      keywords: ["invoice", "order", "payment", "receipt"]
    ),
    MessageClassificationCategory(
      id: "system:flights",
      keywords: ["airline", "boarding", "flight", "itinerary"]
    ),
  ]
}

enum ClassificationDecision: Equatable {
  case assigned(categoryId: String)
  case needsBody
  case uncategorized
}

struct FutureLearningSignal: Codable, Equatable {
  let appliesAfterTimestamp: Int64
  let categoryId: String
  let overrideTimestamp: Int64?
  let senderAddresses: [String]

  init(
    appliesAfterTimestamp: Int64,
    categoryId: String,
    overrideTimestamp: Int64? = nil,
    senderAddresses: [String]
  ) {
    self.appliesAfterTimestamp = appliesAfterTimestamp
    self.categoryId = categoryId
    self.overrideTimestamp = overrideTimestamp
    self.senderAddresses = senderAddresses
  }
}

private enum FutureLearningSignalPayload {
  static let identifierPrefix = "message-category-learning-signal:"
}

enum MessageCategoryAssignmentSource: String, Codable {
  case system
  case userOverride
}

/// Classifies message data locally without exposing mail or categories to the backend.
///
/// Callers first provide `ClassificationInput` with `bodyText` set to `nil`. An engine
/// returns `.needsBody` only when Minimized Classification Input is insufficient.
///
/// Example:
/// ```swift
/// let input = ClassificationInput(
///   bodyText: nil,
///   minimized: MinimizedClassificationInput(
///     from: "Airline <updates@example.com>",
///     replyTo: nil,
///     snippet: "Your itinerary is ready",
///     subject: "Flight confirmation"
///   )
/// )
/// let decision = try await RuleBasedClassificationEngine().classify(
///   input: input,
///   categories: MessageClassificationCategory.systemCategories
/// )
/// ```
protocol ClassificationEngine {
  func classify(
    input: ClassificationInput,
    categories: [MessageClassificationCategory]
  ) async throws -> ClassificationDecision
}

struct RuleBasedClassificationEngine: ClassificationEngine {
  func classify(
    input: ClassificationInput,
    categories: [MessageClassificationCategory]
  ) async throws -> ClassificationDecision {
    let senderAddresses = Set(
      MessageSenderAddressParser.addresses(
        in: [input.minimized.from].compactMap { $0 }
      )
    )
    let learnedCategory =
      categories
      .flatMap { category in
        category.learningSignals.map { signal in
          (categoryId: category.id, signal: signal)
        }
      }
      .filter { candidate in
        input.minimized.providerInternalDateMilliseconds
          > candidate.signal.appliesAfterTimestamp
          && !senderAddresses.isDisjoint(with: candidate.signal.senderAddresses)
      }
      .max { left, right in
        left.signal.appliesAfterTimestamp < right.signal.appliesAfterTimestamp
      }
    if let learnedCategory {
      return .assigned(categoryId: learnedCategory.categoryId)
    }

    let minimizedTokens = ClassificationTokenizer.tokens(
      in: [
        input.minimized.from,
        input.minimized.replyTo,
        input.minimized.snippet,
        input.minimized.subject,
      ].compactMap { $0 }.joined(separator: " ")
    )
    if let categoryId = matchingCategory(in: minimizedTokens, categories: categories) {
      return .assigned(categoryId: categoryId)
    }

    guard let bodyText = input.bodyText else {
      return .needsBody
    }
    guard
      let categoryId = matchingCategory(
        in: ClassificationTokenizer.tokens(in: bodyText),
        categories: categories
      )
    else {
      return .uncategorized
    }
    return .assigned(categoryId: categoryId)
  }

  private func matchingCategory(
    in inputTokens: Set<String>,
    categories: [MessageClassificationCategory]
  ) -> String? {
    categories.first { category in
      !inputTokens.isDisjoint(with: category.keywords.map { $0.lowercased() })
    }?.id
  }
}

/// An encrypted Product Sync record that associates one message identity with one Category.
///
/// Example:
/// ```swift
/// let assignment = MessageCategoryAssignment(
///   categoryId: "system:flights",
///   stableProviderMessageId: "gmail:account:message-001"
/// )
/// ```
struct MessageCategoryAssignment: Codable, Equatable {
  let categoryId: String
  let learningSignal: FutureLearningSignal?
  let overrideTimestamp: Int64?
  let source: MessageCategoryAssignmentSource
  let stableProviderMessageId: String

  init(
    categoryId: String,
    learningSignal: FutureLearningSignal? = nil,
    overrideTimestamp: Int64? = nil,
    source: MessageCategoryAssignmentSource = .system,
    stableProviderMessageId: String
  ) {
    self.categoryId = categoryId
    self.learningSignal = learningSignal
    self.overrideTimestamp = overrideTimestamp
    self.source = source
    self.stableProviderMessageId = stableProviderMessageId
  }

  private enum CodingKeys: String, CodingKey {
    case categoryId
    case learningSignal
    case overrideTimestamp
    case source
    case stableProviderMessageId
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    categoryId = try container.decode(String.self, forKey: .categoryId)
    learningSignal = try container.decodeIfPresent(
      FutureLearningSignal.self,
      forKey: .learningSignal
    )
    overrideTimestamp = try container.decodeIfPresent(Int64.self, forKey: .overrideTimestamp)
    source =
      try container.decodeIfPresent(
        MessageCategoryAssignmentSource.self,
        forKey: .source
      ) ?? .system
    stableProviderMessageId = try container.decode(String.self, forKey: .stableProviderMessageId)
  }
}

/// Synchronizes Message Category assignments without exposing their plaintext to the backend.
///
/// Example:
/// ```swift
/// func syncedAssignment(
///   for message: GmailMessageMetadata,
///   session: ProductAccountSessionSnapshot
/// ) async throws -> MessageCategoryAssignment? {
///   try await MessageCategoryAssignmentSyncService().loadAssignment(
///     stableProviderMessageId: message.stableProviderMessageId,
///     session: session
///   )
/// }
/// ```
protocol MessageCategoryAssignmentSyncing {
  /// Loads assignments for Stable Provider Message Identities in one Product Sync read.
  func loadAssignments(
    stableProviderMessageIds: [String],
    session: ProductAccountSessionSnapshot
  ) async throws -> [String: MessageCategoryAssignment]

  /// Loads and decrypts the assignment addressed by Stable Provider Message Identity.
  func loadAssignment(
    stableProviderMessageId: String,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment?

  /// Loads only encrypted User Override learning signals from Product Sync.
  func loadFutureLearningSignals(
    senderAddresses: [String],
    session: ProductAccountSessionSnapshot
  ) async throws -> [FutureLearningSignal]

  /// Encrypts a new assignment locally before writing it to Product Sync.
  func saveAssignment(
    _ assignment: MessageCategoryAssignment,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment

  /// Encrypts and replaces an assignment after an explicit user action.
  func saveUserOverride(
    _ assignment: MessageCategoryAssignment,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment
}

enum MessageCategoryAssignmentSyncError: LocalizedError, Equatable {
  case conditionalWriteRetryLimitExceeded
  case invalidStableProviderMessageIdentity
  case missingProductSyncKeyMaterial

  var errorDescription: String? {
    switch self {
    case .conditionalWriteRetryLimitExceeded:
      return "Message Category sync remained busy after several retries."
    case .invalidStableProviderMessageIdentity:
      return "The synced Message Category did not match this Gmail message."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before syncing Message Categories."
    }
  }
}

final class MessageCategoryAssignmentSyncService: MessageCategoryAssignmentSyncing {
  private static let conditionalWriteRetryDelayNanoseconds: UInt64 = 10_000_000
  private static let maximumConditionalWriteAttempts = 3
  private static let payloadReadBatchSize = 4_000

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

  func loadAssignments(
    stableProviderMessageIds: [String],
    session: ProductAccountSessionSnapshot
  ) async throws -> [String: MessageCategoryAssignment] {
    guard !stableProviderMessageIds.isEmpty else { return [:] }
    let identifiers = Dictionary(
      uniqueKeysWithValues: stableProviderMessageIds.map {
        (payloadIdentifier(for: $0), $0)
      }
    )
    let payloads = try await transport.getEncryptedProductSyncPayloads(
      identityToken: session.identityToken,
      payloadIdentifiers: Array(identifiers.keys)
    )
    guard !payloads.isEmpty else { return [:] }
    guard let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw MessageCategoryAssignmentSyncError.missingProductSyncKeyMaterial
    }

    var assignments: [String: MessageCategoryAssignment] = [:]
    for payload in payloads {
      guard let stableProviderMessageId = identifiers[payload.payloadIdentifier] else {
        continue
      }
      do {
        assignments[stableProviderMessageId] = try decryptedAssignment(
          from: payload,
          identifier: payload.payloadIdentifier,
          material: material,
          stableProviderMessageId: stableProviderMessageId
        )
      } catch {
        try Task.checkCancellation()
      }
    }
    return assignments
  }

  func loadAssignment(
    stableProviderMessageId: String,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment? {
    let identifier = payloadIdentifier(for: stableProviderMessageId)
    guard
      let syncedPayload = try await transport.getEncryptedProductSyncPayload(
        identityToken: session.identityToken,
        payloadIdentifier: identifier
      )
    else {
      return nil
    }
    guard let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw MessageCategoryAssignmentSyncError.missingProductSyncKeyMaterial
    }
    return try decryptedAssignment(
      from: syncedPayload,
      identifier: identifier,
      material: material,
      stableProviderMessageId: stableProviderMessageId
    )
  }

  func loadFutureLearningSignals(
    senderAddresses: [String],
    session: ProductAccountSessionSnapshot
  ) async throws -> [FutureLearningSignal] {
    guard !senderAddresses.isEmpty else { return [] }
    guard let material = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw MessageCategoryAssignmentSyncError.missingProductSyncKeyMaterial
    }
    let identifiers = Array(
      Set(senderAddresses.map { learningSignalPayloadIdentifier(for: $0, material: material) })
    )
    var payloads: [EncryptedProductSyncPayload] = []
    for startIndex in stride(from: 0, to: identifiers.count, by: Self.payloadReadBatchSize) {
      let endIndex = min(startIndex + Self.payloadReadBatchSize, identifiers.count)
      payloads.append(
        contentsOf: try await transport.getEncryptedProductSyncPayloads(
          identityToken: session.identityToken,
          payloadIdentifiers: Array(identifiers[startIndex..<endIndex])
        )
      )
    }
    return try payloads.map { payload in
      try decryptedLearningSignal(from: payload, material: material)
    }
  }

  func saveAssignment(
    _ assignment: MessageCategoryAssignment,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment {
    if let existing = try await loadAssignment(
      stableProviderMessageId: assignment.stableProviderMessageId,
      session: session
    ) {
      return existing
    }

    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: false
    )
    let identifier = payloadIdentifier(for: assignment.stableProviderMessageId)
    let plaintext = try encoder.encode(assignment)
    let encryptedPayload = try material.encryptPayload(
      plaintext,
      associatedData: Data(identifier.utf8)
    )
    let storedPayload = try await transport.putEncryptedProductSyncPayloadIfAbsent(
      identityToken: session.identityToken,
      payloadIdentifier: identifier,
      encryptedPayload: encryptedPayload,
      trustedDeviceId: session.trustedDeviceId
    )
    return try decryptedAssignment(
      from: storedPayload,
      identifier: identifier,
      material: material,
      stableProviderMessageId: assignment.stableProviderMessageId
    )
  }
}

extension MessageCategoryAssignmentSyncService {
  func saveUserOverride(
    _ assignment: MessageCategoryAssignment,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment {
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: false
    )
    let identifier = payloadIdentifier(for: assignment.stableProviderMessageId)
    let plaintext = try encoder.encode(assignment)
    let encryptedPayload = try material.encryptPayload(
      plaintext,
      associatedData: Data(identifier.utf8)
    )
    let storedAssignment = try await saveNewestUserOverride(
      assignment,
      encryptedPayload: encryptedPayload,
      identifier: identifier,
      material: material,
      session: session
    )
    if let signal = storedAssignment.learningSignal, !signal.senderAddresses.isEmpty {
      try await saveLearningSignal(signal, material: material, session: session)
    }
    return storedAssignment
  }

  private func saveNewestUserOverride(
    _ assignment: MessageCategoryAssignment,
    encryptedPayload: ProductSyncEncryptedPayload,
    identifier: String,
    material: ProductSyncKeyMaterial,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment {
    var storedPayload = try await transport.getEncryptedProductSyncPayload(
      identityToken: session.identityToken,
      payloadIdentifier: identifier
    )
    var foundConcurrentWrite = false
    for attempt in 1...Self.maximumConditionalWriteAttempts {
      if let storedPayload {
        let existingAssignment = try decryptedAssignment(
          from: storedPayload,
          identifier: identifier,
          material: material,
          stableProviderMessageId: assignment.stableProviderMessageId
        )
        if categoryConflictRuleKeepsExisting(
          existingAssignment,
          over: assignment,
          afterConcurrentWrite: foundConcurrentWrite
        ) {
          return existingAssignment
        }
      }

      let writtenPayload = try await transport.putEncryptedProductSyncPayloadIfUnchanged(
        identityToken: session.identityToken,
        payloadIdentifier: identifier,
        encryptedPayload: encryptedPayload,
        trustedDeviceId: session.trustedDeviceId,
        expectedUpdatedAt: storedPayload?.updatedAt
      )
      let storedAssignment = try decryptedAssignment(
        from: writtenPayload,
        identifier: identifier,
        material: material,
        stableProviderMessageId: assignment.stableProviderMessageId
      )
      if writtenPayload.encryptedPayload == encryptedPayload {
        return storedAssignment
      }
      foundConcurrentWrite = true
      if categoryConflictRuleKeepsExisting(
        storedAssignment,
        over: assignment,
        afterConcurrentWrite: foundConcurrentWrite
      ) {
        return storedAssignment
      }
      guard try await waitBeforeConditionalWriteRetry(afterAttempt: attempt) else { break }
      storedPayload = writtenPayload
    }
    throw MessageCategoryAssignmentSyncError.conditionalWriteRetryLimitExceeded
  }

  private func categoryConflictRuleKeepsExisting(
    _ existingAssignment: MessageCategoryAssignment,
    over assignment: MessageCategoryAssignment,
    afterConcurrentWrite: Bool
  ) -> Bool {
    switch (existingAssignment.source, assignment.source) {
    case (.userOverride, .system):
      return true
    case (.system, .userOverride):
      return false
    case (.system, .system):
      return true
    case (.userOverride, .userOverride):
      if afterConcurrentWrite {
        return true
      }
    }

    switch (existingAssignment.overrideTimestamp, assignment.overrideTimestamp) {
    case (let existingTimestamp?, let assignmentTimestamp?):
      return existingTimestamp >= assignmentTimestamp
    case (nil, _?):
      return false
    case (_?, nil):
      return true
    case (nil, nil):
      return (existingAssignment.learningSignal?.appliesAfterTimestamp ?? .min)
        >= (assignment.learningSignal?.appliesAfterTimestamp ?? .min)
    }
  }

  private func saveLearningSignal(
    _ signal: FutureLearningSignal,
    material: ProductSyncKeyMaterial,
    session: ProductAccountSessionSnapshot
  ) async throws {
    for senderAddress in signal.senderAddresses {
      try await saveLearningSignal(
        FutureLearningSignal(
          appliesAfterTimestamp: signal.appliesAfterTimestamp,
          categoryId: signal.categoryId,
          overrideTimestamp: signal.overrideTimestamp,
          senderAddresses: [senderAddress]
        ),
        for: senderAddress,
        material: material,
        session: session
      )
    }
  }

  private func saveLearningSignal(
    _ signal: FutureLearningSignal,
    for senderAddress: String,
    material: ProductSyncKeyMaterial,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let identifier = learningSignalPayloadIdentifier(
      for: senderAddress,
      material: material
    )
    var storedPayload = try await transport.getEncryptedProductSyncPayload(
      identityToken: session.identityToken,
      payloadIdentifier: identifier
    )
    for attempt in 1...Self.maximumConditionalWriteAttempts {
      let existingSignals =
        try storedPayload.map {
          [try decryptedLearningSignal(from: $0, material: material)]
        } ?? []
      guard let storedSignal = learningSignalsBySaving(signal, in: existingSignals)?.first else {
        return
      }

      let plaintext = try encoder.encode(storedSignal)
      let encryptedPayload = try material.encryptPayload(
        plaintext,
        associatedData: Data(identifier.utf8)
      )
      let writtenPayload = try await transport.putEncryptedProductSyncPayloadIfUnchanged(
        identityToken: session.identityToken,
        payloadIdentifier: identifier,
        encryptedPayload: encryptedPayload,
        trustedDeviceId: session.trustedDeviceId,
        expectedUpdatedAt: storedPayload?.updatedAt
      )
      if writtenPayload.encryptedPayload == encryptedPayload {
        return
      }
      guard try await waitBeforeConditionalWriteRetry(afterAttempt: attempt) else { break }
      storedPayload = writtenPayload
    }
    throw MessageCategoryAssignmentSyncError.conditionalWriteRetryLimitExceeded
  }

  private func waitBeforeConditionalWriteRetry(afterAttempt attempt: Int) async throws -> Bool {
    try Task.checkCancellation()
    guard attempt < Self.maximumConditionalWriteAttempts else { return false }
    try await Task.sleep(nanoseconds: Self.conditionalWriteRetryDelayNanoseconds)
    return true
  }

  private func decryptedAssignment(
    from payload: EncryptedProductSyncPayload,
    identifier: String,
    material: ProductSyncKeyMaterial,
    stableProviderMessageId: String
  ) throws -> MessageCategoryAssignment {
    let assignment = try decryptedAssignment(
      from: payload,
      identifier: identifier,
      material: material
    )
    guard assignment.stableProviderMessageId == stableProviderMessageId else {
      throw MessageCategoryAssignmentSyncError.invalidStableProviderMessageIdentity
    }
    return assignment
  }

  private func decryptedLearningSignal(
    from payload: EncryptedProductSyncPayload,
    material: ProductSyncKeyMaterial
  ) throws -> FutureLearningSignal {
    let plaintext = try material.decryptPayload(
      payload.encryptedPayload,
      associatedData: Data(payload.payloadIdentifier.utf8)
    )
    return try decoder.decode(FutureLearningSignal.self, from: plaintext)
  }

  private func learningSignalPayloadIdentifier(
    for senderAddress: String,
    material: ProductSyncKeyMaterial
  ) -> String {
    let digest = HMAC<SHA256>.authenticationCode(
      for: Data(senderAddress.utf8),
      using: SymmetricKey(data: material.accountKeyData)
    )
    return FutureLearningSignalPayload.identifierPrefix
      + digest.map { String(format: "%02x", $0) }.joined()
  }

  private func decryptedAssignment(
    from payload: EncryptedProductSyncPayload,
    identifier: String,
    material: ProductSyncKeyMaterial
  ) throws -> MessageCategoryAssignment {
    let plaintext = try material.decryptPayload(
      payload.encryptedPayload,
      associatedData: Data(identifier.utf8)
    )
    let assignment = try decoder.decode(MessageCategoryAssignment.self, from: plaintext)
    guard payloadIdentifier(for: assignment.stableProviderMessageId) == identifier else {
      throw MessageCategoryAssignmentSyncError.invalidStableProviderMessageIdentity
    }
    return assignment
  }

  private func payloadIdentifier(for stableProviderMessageId: String) -> String {
    let digest = SHA256.hash(data: Data(stableProviderMessageId.utf8))
    return "message-category:\(digest.map { String(format: "%02x", $0) }.joined())"
  }
}

/// Applies System Categorization locally while preserving historical and assigned messages.
///
/// Example:
/// ```swift
/// func categorizeNewMessages(
///   _ messages: [GmailMessageMetadata],
///   session: ProductAccountSessionSnapshot
/// ) async throws -> [GmailMessageMetadata] {
///   try await GmailMessageCategorizationService().categorize(
///     messages: messages,
///     session: session
///   )
/// }
/// ```
protocol GmailMessageCategorizing {
  /// Categorizes eligible messages and leaves failures in Uncategorized State.
  func categorize(
    messages: [GmailMessageMetadata],
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata]

  /// Applies and syncs a user-owned Message Category regardless of message age.
  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata
}

struct GmailMessageCategorizationService: GmailMessageCategorizing {
  private static let assignmentPrefetchBatchSize = 4_000
  private let assignmentSync: MessageCategoryAssignmentSyncing
  private let bodyReader: GmailCachedMessageBodyReading
  private let categorySync: CustomCategorySyncing
  private let currentTimeMilliseconds: () -> Int64
  private let engine: ClassificationEngine

  init(
    assignmentSync: MessageCategoryAssignmentSyncing = MessageCategoryAssignmentSyncService(),
    bodyReader: GmailCachedMessageBodyReading = GmailMessageBodyService(),
    categorySync: CustomCategorySyncing = CustomCategorySyncService(),
    currentTimeMilliseconds: @escaping () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    engine: ClassificationEngine = RuleBasedClassificationEngine()
  ) {
    self.assignmentSync = assignmentSync
    self.bodyReader = bodyReader
    self.categorySync = categorySync
    self.currentTimeMilliseconds = currentTimeMilliseconds
    self.engine = engine
  }

  func categorize(
    messages: [GmailMessageMetadata],
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    var categories: [MessageClassificationCategory]?
    var categorizedMessages: [GmailMessageMetadata] = []
    let assignments = try await prefetchedAssignments(messages: messages, session: session)
    let signalSenders = learningSignalSenders(in: messages, excluding: assignments)
    for message in messages {
      if let assignment = assignments[message.stableProviderMessageId],
        message.categoryId == nil || assignment.source == .userOverride
      {
        categorizedMessages.append(message.assigningCategory(assignment.categoryId))
        continue
      }
      guard message.categoryId == nil else {
        categorizedMessages.append(message)
        continue
      }
      do {
        guard !message.isHistorical else {
          categorizedMessages.append(message)
          continue
        }

        if categories == nil {
          categories = try await classificationCategories(
            learningSignalSenderAddresses: signalSenders,
            session: session
          )
        }
        guard
          let categoryId = try await classifiedCategoryId(
            for: message,
            categories: categories ?? MessageClassificationCategory.systemCategories,
            session: session
          )
        else {
          categorizedMessages.append(message)
          continue
        }
        let assignment = try await assignmentSync.saveAssignment(
          MessageCategoryAssignment(
            categoryId: categoryId,
            stableProviderMessageId: message.stableProviderMessageId
          ),
          session: session
        )
        categorizedMessages.append(message.assigningCategory(assignment.categoryId))
      } catch {
        try Task.checkCancellation()
        categorizedMessages.append(message)
      }
    }
    return categorizedMessages
  }

  private func learningSignalSenders(
    in messages: [GmailMessageMetadata],
    excluding assignments: [String: MessageCategoryAssignment]
  ) -> [String] {
    MessageSenderAddressParser.addresses(
      in: messages.compactMap { message in
        guard
          message.categoryId == nil,
          !message.isHistorical,
          assignments[message.stableProviderMessageId] == nil
        else {
          return nil
        }
        return message.from
      }
    )
  }

  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    let overrideTimestamp = currentTimeMilliseconds()
    let senderAddresses = MessageSenderAddressParser.addresses(
      in: [message.from].compactMap { $0 }
    )
    let assignment = try await assignmentSync.saveUserOverride(
      MessageCategoryAssignment(
        categoryId: categoryId,
        learningSignal: FutureLearningSignal(
          appliesAfterTimestamp: max(
            overrideTimestamp,
            message.providerInternalDateMilliseconds
          ),
          categoryId: categoryId,
          overrideTimestamp: overrideTimestamp,
          senderAddresses: senderAddresses
        ),
        overrideTimestamp: overrideTimestamp,
        source: .userOverride,
        stableProviderMessageId: message.stableProviderMessageId
      ),
      session: session
    )
    return message.assigningCategory(assignment.categoryId)
  }

  private func prefetchedAssignments(
    messages: [GmailMessageMetadata],
    session: ProductAccountSessionSnapshot
  ) async throws -> [String: MessageCategoryAssignment] {
    let stableProviderMessageIds = messages.map(\.stableProviderMessageId)
    do {
      var assignments: [String: MessageCategoryAssignment] = [:]
      for startIndex in stride(
        from: 0,
        to: stableProviderMessageIds.count,
        by: Self.assignmentPrefetchBatchSize
      ) {
        let endIndex = min(
          startIndex + Self.assignmentPrefetchBatchSize,
          stableProviderMessageIds.count
        )
        let batch = Array(stableProviderMessageIds[startIndex..<endIndex])
        assignments.merge(
          try await assignmentSync.loadAssignments(
            stableProviderMessageIds: batch,
            session: session
          ),
          uniquingKeysWith: { existing, _ in existing }
        )
      }
      return assignments
    } catch {
      try Task.checkCancellation()
      return [:]
    }
  }

  private func classifiedCategoryId(
    for message: GmailMessageMetadata,
    categories: [MessageClassificationCategory],
    session: ProductAccountSessionSnapshot
  ) async throws -> String? {
    let minimizedInput = MinimizedClassificationInput(
      from: message.from,
      replyTo: message.replyTo,
      snippet: message.snippet,
      subject: message.subject,
      providerInternalDateMilliseconds: message.providerInternalDateMilliseconds
    )
    var decision = try await engine.classify(
      input: ClassificationInput(bodyText: nil, minimized: minimizedInput),
      categories: categories
    )
    if decision == .needsBody {
      guard let body = try bodyReader.loadCachedMessageBody(message: message, session: session)
      else {
        return nil
      }
      decision = try await engine.classify(
        input: ClassificationInput(bodyText: body.text, minimized: minimizedInput),
        categories: categories
      )
    }
    guard
      case .assigned(let categoryId) = decision,
      categories.contains(where: { $0.id == categoryId })
    else {
      return nil
    }
    return categoryId
  }

  private func classificationCategories(
    learningSignalSenderAddresses: [String],
    session: ProductAccountSessionSnapshot
  ) async throws -> [MessageClassificationCategory] {
    let customCategory = try await categorySync.loadCategory(session: session)
    let customClassificationCategory = customCategory.map { category in
      MessageClassificationCategory(
        id: category.id,
        keywords: classificationKeywords(for: category)
      )
    }
    let categories =
      (customClassificationCategory.map { [$0] } ?? [])
      + MessageClassificationCategory.systemCategories
    let learningSignals = try await assignmentSync.loadFutureLearningSignals(
      senderAddresses: learningSignalSenderAddresses,
      session: session
    )
    return categories.map { category in
      MessageClassificationCategory(
        id: category.id,
        keywords: category.keywords,
        learningSignals:
          learningSignals
          .filter { $0.categoryId == category.id }
      )
    }
  }

  private func classificationKeywords(for category: CustomCategory) -> [String] {
    [category.name, category.description]
      .compactMap { $0 }
      .flatMap { value in
        ClassificationTokenizer.tokens(in: value)
      }
      .filter { $0.count > 2 }
  }
}

private enum ClassificationTokenizer {
  static func tokens(in value: String) -> Set<String> {
    Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
  }
}

private func learningSignalsBySaving(
  _ signal: FutureLearningSignal,
  in existingSignals: [FutureLearningSignal]
) -> [FutureLearningSignal]? {
  let senderAddresses = Set(signal.senderAddresses)
  if existingSignals.contains(where: { existingSignal in
    !senderAddresses.isDisjoint(with: existingSignal.senderAddresses)
      && existingSignal.categoryId != signal.categoryId
      && learningSignalOrderTimestamp(existingSignal) >= learningSignalOrderTimestamp(signal)
  }) {
    return nil
  }

  let matchingCategorySignals = existingSignals.filter { existingSignal in
    existingSignal.categoryId == signal.categoryId
      && !senderAddresses.isDisjoint(with: existingSignal.senderAddresses)
  }
  let appliesAfterTimestamp = min(
    signal.appliesAfterTimestamp,
    matchingCategorySignals
      .map(\.appliesAfterTimestamp)
      .min() ?? signal.appliesAfterTimestamp
  )
  let overrideTimestamp =
    ([signal] + matchingCategorySignals)
    .compactMap(\.overrideTimestamp)
    .max()
  var signals = existingSignals
  signals.removeAll { existingSignal in
    !senderAddresses.isDisjoint(with: existingSignal.senderAddresses)
  }
  signals.append(
    FutureLearningSignal(
      appliesAfterTimestamp: appliesAfterTimestamp,
      categoryId: signal.categoryId,
      overrideTimestamp: overrideTimestamp,
      senderAddresses: signal.senderAddresses
    )
  )
  return signals
}

private func learningSignalOrderTimestamp(_ signal: FutureLearningSignal) -> Int64 {
  signal.overrideTimestamp ?? signal.appliesAfterTimestamp
}

private enum MessageSenderAddressParser {
  static func addresses(in values: [String]) -> [String] {
    Array(Set(values.compactMap(address(in:)))).sorted()
  }

  private static func address(in value: String) -> String? {
    var angleStart: String.Index?
    var bareValue = ""
    var commentDepth = 0
    var isEscaped = false
    var isQuoted = false
    var index = value.startIndex
    while index < value.endIndex {
      let character = value[index]
      let nextIndex = value.index(after: index)
      var isCommentBoundary = false
      if isEscaped {
        isEscaped = false
      } else if character == "\\" && isQuoted {
        isEscaped = true
      } else if character == "\"" && commentDepth == 0 {
        isQuoted.toggle()
      } else if !isQuoted {
        if character == "(" {
          commentDepth += 1
          isCommentBoundary = true
        } else if character == ")", commentDepth > 0 {
          commentDepth -= 1
          isCommentBoundary = true
        } else if commentDepth == 0, character == "<" {
          angleStart = nextIndex
        } else if commentDepth == 0, character == ">", let angleStart {
          return normalizedMailbox(String(value[angleStart..<index]))
        }
      }
      if commentDepth == 0, !isCommentBoundary {
        bareValue.append(character)
      }
      index = nextIndex
    }
    return normalizedMailbox(bareValue)
  }

  private static func normalizedMailbox(_ value: String) -> String? {
    var address = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if address.hasPrefix("mailto:") {
      address.removeFirst(7)
    }
    let parts = address.split(separator: "@", omittingEmptySubsequences: false)
    guard
      parts.count == 2,
      !parts[0].isEmpty,
      parts[1].contains("."),
      !address.contains(where: { $0.isWhitespace || "<>,;()".contains($0) })
    else {
      return nil
    }
    return address
  }
}

extension GmailMessageMetadata {
  func assigningCategory(_ categoryId: String) -> GmailMessageMetadata {
    GmailMessageMetadata(
      categoryId: categoryId,
      from: from,
      isHistorical: isHistorical,
      providerAccountIdentifier: providerAccountIdentifier,
      providerInternalDateMilliseconds: providerInternalDateMilliseconds,
      providerMessageId: providerMessageId,
      providerThreadId: providerThreadId,
      replyTo: replyTo,
      snippet: snippet,
      stableProviderMessageId: stableProviderMessageId,
      subject: subject,
      rfcMessageId: rfcMessageId
    )
  }
}
