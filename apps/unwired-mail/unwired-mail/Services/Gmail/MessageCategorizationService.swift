import CryptoKit
import Foundation

// swiftlint:disable file_length

struct MinimizedClassificationInput: Equatable {
  let from: String?
  let replyTo: String?
  let snippet: String
  let subject: String
}

struct ClassificationInput: Equatable {
  let bodyText: String?
  let minimized: MinimizedClassificationInput
}

struct MessageClassificationCategory: Equatable {
  let id: String
  let keywords: [String]

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
  let stableProviderMessageId: String
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
  /// Loads and decrypts the assignment addressed by Stable Provider Message Identity.
  func loadAssignment(
    stableProviderMessageId: String,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment?

  /// Encrypts a new assignment locally before writing it to Product Sync.
  func saveAssignment(
    _ assignment: MessageCategoryAssignment,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment
}

enum MessageCategoryAssignmentSyncError: LocalizedError, Equatable {
  case invalidStableProviderMessageIdentity
  case missingProductSyncKeyMaterial

  var errorDescription: String? {
    switch self {
    case .invalidStableProviderMessageIdentity:
      return "The synced Message Category did not match this Gmail message."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before syncing Message Categories."
    }
  }
}

final class MessageCategoryAssignmentSyncService: MessageCategoryAssignmentSyncing {
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

  private func decryptedAssignment(
    from payload: EncryptedProductSyncPayload,
    identifier: String,
    material: ProductSyncKeyMaterial,
    stableProviderMessageId: String
  ) throws -> MessageCategoryAssignment {
    let plaintext = try material.decryptPayload(
      payload.encryptedPayload,
      associatedData: Data(identifier.utf8)
    )
    let assignment = try decoder.decode(MessageCategoryAssignment.self, from: plaintext)
    guard assignment.stableProviderMessageId == stableProviderMessageId else {
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
}

struct GmailMessageCategorizationService: GmailMessageCategorizing {
  private let assignmentSync: MessageCategoryAssignmentSyncing
  private let bodyReader: GmailCachedMessageBodyReading
  private let categorySync: CustomCategorySyncing
  private let engine: ClassificationEngine

  init(
    assignmentSync: MessageCategoryAssignmentSyncing = MessageCategoryAssignmentSyncService(),
    bodyReader: GmailCachedMessageBodyReading = GmailMessageBodyService(),
    categorySync: CustomCategorySyncing = CustomCategorySyncService(),
    engine: ClassificationEngine = RuleBasedClassificationEngine()
  ) {
    self.assignmentSync = assignmentSync
    self.bodyReader = bodyReader
    self.categorySync = categorySync
    self.engine = engine
  }

  func categorize(
    messages: [GmailMessageMetadata],
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    var categories: [MessageClassificationCategory]?
    var categorizedMessages: [GmailMessageMetadata] = []
    for message in messages {
      guard message.categoryId == nil else {
        categorizedMessages.append(message)
        continue
      }
      do {
        if let assignment = try await assignmentSync.loadAssignment(
          stableProviderMessageId: message.stableProviderMessageId,
          session: session
        ) {
          categorizedMessages.append(message.assigningCategory(assignment.categoryId))
          continue
        }

        guard !message.isHistorical else {
          categorizedMessages.append(message)
          continue
        }

        if categories == nil {
          categories = try await classificationCategories(session: session)
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

  private func classifiedCategoryId(
    for message: GmailMessageMetadata,
    categories: [MessageClassificationCategory],
    session: ProductAccountSessionSnapshot
  ) async throws -> String? {
    let minimizedInput = MinimizedClassificationInput(
      from: message.from,
      replyTo: message.replyTo,
      snippet: message.snippet,
      subject: message.subject
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
    guard case .assigned(let categoryId) = decision else {
      return nil
    }
    return categoryId
  }

  private func classificationCategories(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MessageClassificationCategory] {
    let customCategory = try await categorySync.loadCategory(session: session)
    let customClassificationCategory = customCategory.map { category in
      MessageClassificationCategory(
        id: category.id,
        keywords: classificationKeywords(for: category)
      )
    }
    return (customClassificationCategory.map { [$0] } ?? [])
      + MessageClassificationCategory.systemCategories
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

extension GmailMessageMetadata {
  fileprivate func assigningCategory(_ categoryId: String) -> GmailMessageMetadata {
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
