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

struct BackgroundCategorizationSenderContext: Codable, Equatable {
  let cachedAtMilliseconds: Int64
  let learningSignals: [FutureLearningSignal]
}

struct BackgroundCategorizationContextCache: Codable, Equatable {
  let customCategory: CustomCategory?
  let customCategoryCachedAtMilliseconds: Int64
  let learningSignalsBySender: [String: BackgroundCategorizationSenderContext]
  let schemaVersion: Int

  init(
    customCategory: CustomCategory?,
    customCategoryCachedAtMilliseconds: Int64,
    learningSignalsBySender: [String: BackgroundCategorizationSenderContext]
  ) {
    self.customCategory = customCategory
    self.customCategoryCachedAtMilliseconds = customCategoryCachedAtMilliseconds
    self.learningSignalsBySender = learningSignalsBySender
    schemaVersion = 1
  }
}

private struct BackgroundClassificationContext {
  let learningSignalSenderAddresses: [String]
  let cachedLearningSignals: [FutureLearningSignal]
}

protocol BackgroundContextCachePersisting {
  func clear(productAccountId: String) throws
  func clear(productAccountId: String, providerAccountIdentifier: String) throws
  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> BackgroundCategorizationContextCache?
  func save(
    _ cache: BackgroundCategorizationContextCache,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws
}

struct KeychainBackgroundContextCacheStore:
  BackgroundContextCachePersisting
{
  static let serviceName = "dev.unwired.mail.background-categorization-context"

  private static let associatedData = Data(
    "dev.unwired.mail.background-categorization-context.v1".utf8
  )

  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting

  init(
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore()
  ) {
    self.keyMaterialStore = keyMaterialStore
  }

  func clear(productAccountId: String) throws {
    for providerAccountIdentifier in try providerAccountIdentifiers(
      productAccountId: productAccountId
    ) {
      try KeychainStore.delete(
        service: Self.serviceName,
        account: accountName(
          productAccountId: productAccountId,
          providerAccountIdentifier: providerAccountIdentifier
        )
      )
    }
    try KeychainStore.delete(service: Self.serviceName, account: manifestName(productAccountId))
    try KeychainStore.delete(service: Self.serviceName, account: productAccountId)
  }

  func clear(productAccountId: String, providerAccountIdentifier: String) throws {
    try KeychainStore.delete(
      service: Self.serviceName,
      account: accountName(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      )
    )
    var identifiers = try providerAccountIdentifiers(productAccountId: productAccountId)
    identifiers.remove(providerAccountIdentifier)
    try saveProviderAccountIdentifiers(identifiers, productAccountId: productAccountId)
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> BackgroundCategorizationContextCache? {
    if let rawValue = try KeychainStore.readString(
      service: Self.serviceName,
      account: accountName(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      )
    ) {
      return try decode(rawValue, productAccountId: productAccountId)
    }
    guard
      let legacyRawValue = try KeychainStore.readString(
        service: Self.serviceName,
        account: productAccountId
      )
    else {
      return nil
    }
    let cache = try decode(legacyRawValue, productAccountId: productAccountId)
    try save(
      cache,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    try KeychainStore.delete(service: Self.serviceName, account: productAccountId)
    return cache
  }

  private func decode(
    _ rawValue: String,
    productAccountId: String
  ) throws -> BackgroundCategorizationContextCache {
    guard let data = rawValue.data(using: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    guard let material = try keyMaterialStore.load(productAccountId: productAccountId) else {
      throw MessageCategoryAssignmentSyncError.missingProductSyncKeyMaterial
    }
    let encryptedPayload = try decoder.decode(ProductSyncEncryptedPayload.self, from: data)
    let plaintext = try material.decryptPayload(
      encryptedPayload,
      associatedData: Self.associatedData
    )
    return try decoder.decode(BackgroundCategorizationContextCache.self, from: plaintext)
  }

  func save(
    _ cache: BackgroundCategorizationContextCache,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    guard let material = try keyMaterialStore.load(productAccountId: productAccountId) else {
      throw MessageCategoryAssignmentSyncError.missingProductSyncKeyMaterial
    }
    let plaintext = try encoder.encode(cache)
    let encryptedPayload = try material.encryptPayload(
      plaintext,
      associatedData: Self.associatedData
    )
    let data = try encoder.encode(encryptedPayload)
    guard let rawValue = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    let previousIdentifiers = try providerAccountIdentifiers(productAccountId: productAccountId)
    var identifiers = previousIdentifiers
    identifiers.insert(providerAccountIdentifier)
    try saveProviderAccountIdentifiers(identifiers, productAccountId: productAccountId)
    do {
      try KeychainStore.writeString(
        rawValue,
        service: Self.serviceName,
        account: accountName(
          productAccountId: productAccountId,
          providerAccountIdentifier: providerAccountIdentifier
        ),
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      )
    } catch {
      try? saveProviderAccountIdentifiers(
        previousIdentifiers,
        productAccountId: productAccountId
      )
      throw error
    }
  }

  private func accountName(
    productAccountId: String,
    providerAccountIdentifier: String
  ) -> String {
    "gmail.\(gmailSafeFileComponent(productAccountId))."
      + gmailSafeFileComponent(providerAccountIdentifier)
  }

  private func manifestName(_ productAccountId: String) -> String {
    "gmail-identities.\(gmailSafeFileComponent(productAccountId))"
  }

  private func providerAccountIdentifiers(productAccountId: String) throws -> Set<String> {
    guard
      let rawValue = try KeychainStore.readString(
        service: Self.serviceName,
        account: manifestName(productAccountId)
      ),
      let data = rawValue.data(using: .utf8)
    else {
      return []
    }
    return try JSONDecoder().decode(Set<String>.self, from: data)
  }

  private func saveProviderAccountIdentifiers(
    _ identifiers: Set<String>,
    productAccountId: String
  ) throws {
    guard !identifiers.isEmpty else {
      try KeychainStore.delete(
        service: Self.serviceName,
        account: manifestName(productAccountId)
      )
      return
    }
    let data = try JSONEncoder().encode(identifiers)
    guard let rawValue = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(
      rawValue,
      service: Self.serviceName,
      account: manifestName(productAccountId),
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }
}

private enum FutureLearningSignalPayload {
  static let identifierPrefix = "message-category-learning-signal:"
}

enum MessageCategoryAssignmentSource: String, Codable {
  case system
  case userOverride
}

struct GmailHistoricalCategorizationScope: Equatable {
  let receivedAtOrAfterMilliseconds: Int64
  let receivedBeforeMilliseconds: Int64

  static func isValidDateRange(
    startDate: Date,
    endDate: Date,
    calendar: Calendar
  ) -> Bool {
    calendar.startOfDay(for: startDate) <= calendar.startOfDay(for: endDate)
  }

  func contains(_ message: GmailMessageMetadata) -> Bool {
    message.isHistorical
      && message.providerInternalDateMilliseconds >= receivedAtOrAfterMilliseconds
      && message.providerInternalDateMilliseconds < receivedBeforeMilliseconds
  }
}

private enum GmailCategorizationMode {
  case boundedHistorical(GmailHistoricalCategorizationScope)
  case newMailOnly

  func includes(_ message: GmailMessageMetadata) -> Bool {
    switch self {
    case .boundedHistorical(let scope):
      return scope.contains(message)
    case .newMailOnly:
      return !message.isHistorical
    }
  }
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
  case mixedProviderAccounts

  var errorDescription: String? {
    switch self {
    case .conditionalWriteRetryLimitExceeded:
      return "Message Category sync remained busy after several retries."
    case .invalidStableProviderMessageIdentity:
      return "The synced Message Category did not match this Gmail message."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before syncing Message Categories."
    case .mixedProviderAccounts:
      return "Categorize Gmail messages one Mailbox Connection at a time."
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
      payloadIdentifiers: Array(identifiers.keys),
      trustedDeviceId: session.trustedDeviceId
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
        payloadIdentifier: identifier,
        trustedDeviceId: session.trustedDeviceId
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
    let identifierKeys = [material.accountKeyData] + material.legacyAccountKeysData.values
    let identifiers = Array(
      Set(
        identifierKeys.flatMap { keyData in
          senderAddresses.map {
            learningSignalPayloadIdentifier(for: $0, keyData: keyData)
          }
        }
      )
    )
    var payloads: [EncryptedProductSyncPayload] = []
    for startIndex in stride(from: 0, to: identifiers.count, by: Self.payloadReadBatchSize) {
      let endIndex = min(startIndex + Self.payloadReadBatchSize, identifiers.count)
      payloads.append(
        contentsOf: try await transport.getEncryptedProductSyncPayloads(
          identityToken: session.identityToken,
          payloadIdentifiers: Array(identifiers[startIndex..<endIndex]),
          trustedDeviceId: session.trustedDeviceId
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
      payloadIdentifier: identifier,
      trustedDeviceId: session.trustedDeviceId
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
      payloadIdentifier: identifier,
      trustedDeviceId: session.trustedDeviceId
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
    learningSignalPayloadIdentifier(for: senderAddress, keyData: material.accountKeyData)
  }

  private func learningSignalPayloadIdentifier(
    for senderAddress: String,
    keyData: Data
  ) -> String {
    let digest = HMAC<SHA256>.authenticationCode(
      for: Data(senderAddress.utf8),
      using: SymmetricKey(data: keyData)
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

  /// Categorizes notification candidates without persisting an assignment when Product Sync is
  /// unavailable. Implementations may use device-only cached classification context here only.
  func categorizeForBackgroundNotification(
    messages: [GmailMessageMetadata],
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata]

  /// Categorizes only historical messages inside an explicit user-selected scope.
  func categorizeHistorical(
    messages: [GmailMessageMetadata],
    scope: GmailHistoricalCategorizationScope,
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata]

  /// Applies and syncs a user-owned Message Category regardless of message age.
  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata
}

extension GmailMessageCategorizing {
  func categorizeForBackgroundNotification(
    messages: [GmailMessageMetadata],
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    try await categorize(messages: messages, session: session)
  }
}

struct GmailMessageCategorizationService: GmailMessageCategorizing {
  private static let assignmentPrefetchBatchSize = 4_000
  private static let backgroundContextTimeToLiveMilliseconds: Int64 = 86_400_000
  private let assignmentSync: MessageCategoryAssignmentSyncing
  private let backgroundContextCacheStore: BackgroundContextCachePersisting
  private let bodyReader: GmailCachedMessageBodyReading
  private let categorySync: CustomCategorySyncing
  private let currentTimeMilliseconds: () -> Int64
  private let engine: ClassificationEngine

  init(
    assignmentSync: MessageCategoryAssignmentSyncing = MessageCategoryAssignmentSyncService(),
    backgroundContextCacheStore: BackgroundContextCachePersisting =
      KeychainBackgroundContextCacheStore(),
    bodyReader: GmailCachedMessageBodyReading = GmailMessageBodyService(),
    categorySync: CustomCategorySyncing = CustomCategorySyncService(),
    currentTimeMilliseconds: @escaping () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    engine: ClassificationEngine = RuleBasedClassificationEngine()
  ) {
    self.assignmentSync = assignmentSync
    self.backgroundContextCacheStore = backgroundContextCacheStore
    self.bodyReader = bodyReader
    self.categorySync = categorySync
    self.currentTimeMilliseconds = currentTimeMilliseconds
    self.engine = engine
  }
}

extension GmailMessageCategorizationService {
  func categorize(
    messages: [GmailMessageMetadata],
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    try await categorize(messages: messages, mode: .newMailOnly, session: session)
  }

  func categorizeForBackgroundNotification(
    messages: [GmailMessageMetadata],
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    guard messages.contains(where: { !$0.isHistorical && $0.categoryId == nil }) else {
      return messages
    }
    let senderAddresses = learningSignalSenders(
      in: messages,
      excluding: [:],
      mode: .newMailOnly
    )
    let remoteCategories: [MessageClassificationCategory]?
    do {
      remoteCategories = try await classificationCategories(
        learningSignalSenderAddresses: senderAddresses,
        providerAccountIdentifier: try providerAccountIdentifier(in: messages),
        session: session
      )
    } catch {
      try Task.checkCancellation()
      guard backgroundAuthenticationIsUnavailable(error) else { return messages }
      remoteCategories = nil
    }

    var categorizedMessages: [GmailMessageMetadata] = []
    for message in messages {
      do {
        categorizedMessages.append(
          try await backgroundCategorizedMessage(
            message,
            remoteCategories: remoteCategories,
            session: session
          )
        )
      } catch {
        try Task.checkCancellation()
        categorizedMessages.append(message)
      }
    }
    return categorizedMessages
  }

  private func backgroundCategorizedMessage(
    _ message: GmailMessageMetadata,
    remoteCategories: [MessageClassificationCategory]?,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    guard !message.isHistorical, message.categoryId == nil else { return message }
    guard
      let categories = try backgroundClassificationCategories(
        for: message,
        remoteCategories: remoteCategories,
        session: session
      ),
      let categoryId = try await classifiedCategoryId(
        for: message,
        categories: categories,
        session: session
      )
    else {
      return message
    }
    return message.assigningCategory(categoryId)
  }

  private func backgroundClassificationCategories(
    for message: GmailMessageMetadata,
    remoteCategories: [MessageClassificationCategory]?,
    session: ProductAccountSessionSnapshot
  ) throws -> [MessageClassificationCategory]? {
    if let remoteCategories { return remoteCategories }
    let messageSenders = MessageSenderAddressParser.addresses(
      in: [message.from].compactMap { $0 }
    )
    guard messageSenders.count == 1 else { return nil }
    return try cachedClassificationCategories(
      senderAddress: messageSenders[0],
      productAccountId: session.productAccountId,
      providerAccountIdentifier: message.providerAccountIdentifier
    )
  }

  func categorizeHistorical(
    messages: [GmailMessageMetadata],
    scope: GmailHistoricalCategorizationScope,
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    let scopedMessages = messages.filter(scope.contains)
    let categorizedMessages = try await categorize(
      messages: scopedMessages,
      mode: .boundedHistorical(scope),
      session: session
    )
    let categoriesByStableProviderMessageId = Dictionary(
      uniqueKeysWithValues: categorizedMessages.compactMap { message in
        message.categoryId.map { (message.stableProviderMessageId, $0) }
      }
    )
    return messages.map { message in
      guard
        let categoryId = categoriesByStableProviderMessageId[message.stableProviderMessageId]
      else {
        return message
      }
      return message.assigningCategory(categoryId)
    }
  }

  private func categorize(
    messages: [GmailMessageMetadata],
    mode: GmailCategorizationMode,
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    var categories: [MessageClassificationCategory]?
    var categorizedMessages: [GmailMessageMetadata] = []
    let assignments = try await prefetchedAssignments(messages: messages, session: session)
    let signalSenders = learningSignalSenders(
      in: messages,
      excluding: assignments,
      mode: mode
    )
    let cachedLearningSignals = assignments.values.compactMap { assignment in
      assignment.source == .userOverride ? assignment.learningSignal : nil
    }
    let classificationContext = BackgroundClassificationContext(
      learningSignalSenderAddresses: signalSenders,
      cachedLearningSignals: cachedLearningSignals
    )
    for message in messages {
      let assignment = assignments[message.stableProviderMessageId]
      guard mode.includes(message) || assignment != nil else {
        categorizedMessages.append(message)
        continue
      }
      categorizedMessages.append(
        try await categorizedMessage(
          message,
          assignment: assignment,
          categories: &categories,
          classificationContext: classificationContext,
          session: session
        )
      )
    }
    return categorizedMessages
  }

  private func categorizedMessage(
    _ message: GmailMessageMetadata,
    assignment: MessageCategoryAssignment?,
    categories: inout [MessageClassificationCategory]?,
    classificationContext: BackgroundClassificationContext,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    if let assignment,
      message.categoryId == nil || assignment.source == .userOverride
    {
      return message.assigningCategory(assignment.categoryId)
    }
    guard message.categoryId == nil else {
      return message
    }
    do {
      if categories == nil {
        categories = try await classificationCategories(
          learningSignalSenderAddresses: classificationContext.learningSignalSenderAddresses,
          cachedLearningSignals: classificationContext.cachedLearningSignals,
          providerAccountIdentifier: message.providerAccountIdentifier,
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
        return message
      }
      let savedAssignment = try await assignmentSync.saveAssignment(
        MessageCategoryAssignment(
          categoryId: categoryId,
          stableProviderMessageId: message.stableProviderMessageId
        ),
        session: session
      )
      return message.assigningCategory(savedAssignment.categoryId)
    } catch {
      try Task.checkCancellation()
      return message
    }
  }

  private func learningSignalSenders(
    in messages: [GmailMessageMetadata],
    excluding assignments: [String: MessageCategoryAssignment],
    mode: GmailCategorizationMode
  ) -> [String] {
    MessageSenderAddressParser.addresses(
      in: messages.compactMap { message in
        guard
          message.categoryId == nil,
          mode.includes(message),
          assignments[message.stableProviderMessageId] == nil
        else {
          return nil
        }
        return message.from
      }
    )
  }
}

extension GmailMessageCategorizationService {
  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    let overrideTimestamp = currentTimeMilliseconds()
    let senderAddresses = MessageSenderAddressParser.addresses(
      in: [message.from].compactMap { $0 }
    )
    try backgroundContextCacheStore.clear(productAccountId: session.productAccountId)
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
    cachedLearningSignals: [FutureLearningSignal] = [],
    providerAccountIdentifier: String,
    session: ProductAccountSessionSnapshot
  ) async throws -> [MessageClassificationCategory] {
    let customCategory = try await categorySync.loadCategory(session: session)
    let learningSignals: [FutureLearningSignal]
    do {
      learningSignals = try await assignmentSync.loadFutureLearningSignals(
        senderAddresses: learningSignalSenderAddresses,
        session: session
      )
    } catch {
      try? backgroundContextCacheStore.clear(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      )
      throw error
    }
    let cachedSenderAddresses = Array(
      Set(learningSignalSenderAddresses + cachedLearningSignals.flatMap(\.senderAddresses))
    )
    try? refreshBackgroundContextCache(
      customCategory: customCategory,
      learningSignals: learningSignals + cachedLearningSignals,
      senderAddresses: cachedSenderAddresses,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    return classificationCategories(
      customCategory: customCategory,
      learningSignals: learningSignals
    )
  }

  private func cachedClassificationCategories(
    senderAddress: String,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> [MessageClassificationCategory]? {
    guard
      let cache = try backgroundContextCacheStore.load(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      ),
      cache.schemaVersion == 1,
      cacheIsFresh(cachedAtMilliseconds: cache.customCategoryCachedAtMilliseconds),
      let senderContext = cache.learningSignalsBySender[senderAddress],
      cacheIsFresh(cachedAtMilliseconds: senderContext.cachedAtMilliseconds),
      senderContext.learningSignals.allSatisfy({ $0.senderAddresses == [senderAddress] })
    else {
      return nil
    }
    return classificationCategories(
      customCategory: cache.customCategory,
      learningSignals: senderContext.learningSignals
    )
  }

  private func classificationCategories(
    customCategory: CustomCategory?,
    learningSignals: [FutureLearningSignal]
  ) -> [MessageClassificationCategory] {
    let customClassificationCategory = customCategory.map { category in
      MessageClassificationCategory(
        id: category.id,
        keywords: classificationKeywords(for: category)
      )
    }
    let categories =
      (customClassificationCategory.map { [$0] } ?? [])
      + MessageClassificationCategory.systemCategories
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

  private func refreshBackgroundContextCache(
    customCategory: CustomCategory?,
    learningSignals: [FutureLearningSignal],
    senderAddresses: [String],
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    let cachedAtMilliseconds = currentTimeMilliseconds()
    var learningSignalsBySender =
      (try? backgroundContextCacheStore.load(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      ))?
      .learningSignalsBySender ?? [:]
    learningSignalsBySender = learningSignalsBySender.filter { _, context in
      let age = cachedAtMilliseconds - context.cachedAtMilliseconds
      return age >= 0 && age <= Self.backgroundContextTimeToLiveMilliseconds
    }
    for senderAddress in senderAddresses {
      let exactSenderSignals: [FutureLearningSignal] = learningSignals.compactMap { signal in
        guard signal.senderAddresses.contains(senderAddress) else { return nil }
        return FutureLearningSignal(
          appliesAfterTimestamp: signal.appliesAfterTimestamp,
          categoryId: signal.categoryId,
          overrideTimestamp: signal.overrideTimestamp,
          senderAddresses: [senderAddress]
        )
      }
      learningSignalsBySender[senderAddress] = BackgroundCategorizationSenderContext(
        cachedAtMilliseconds: cachedAtMilliseconds,
        learningSignals: exactSenderSignals
      )
    }
    try backgroundContextCacheStore.clear(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    try backgroundContextCacheStore.save(
      BackgroundCategorizationContextCache(
        customCategory: customCategory,
        customCategoryCachedAtMilliseconds: cachedAtMilliseconds,
        learningSignalsBySender: learningSignalsBySender
      ),
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
  }

  private func providerAccountIdentifier(in messages: [GmailMessageMetadata]) throws -> String {
    guard
      let providerAccountIdentifier = messages.first?.providerAccountIdentifier,
      messages.allSatisfy({
        $0.providerAccountIdentifier == providerAccountIdentifier
      })
    else {
      throw MessageCategoryAssignmentSyncError.mixedProviderAccounts
    }
    return providerAccountIdentifier
  }

  private func cacheIsFresh(cachedAtMilliseconds: Int64) -> Bool {
    let age = currentTimeMilliseconds() - cachedAtMilliseconds
    return age >= 0 && age <= Self.backgroundContextTimeToLiveMilliseconds
  }

  private func backgroundAuthenticationIsUnavailable(_ error: Error) -> Bool {
    if let urlError = error as? URLError {
      return urlError.code == .userAuthenticationRequired
    }
    switch error as? ConvexClientError {
    case .httpError(let statusCode):
      return statusCode == 401 || statusCode == 403
    case .convexFailure(_, let message):
      return message == "Authentication required"
    default:
      return false
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
      providerLabelIds: providerLabelIds,
      providerMessageId: providerMessageId,
      providerThreadId: providerThreadId,
      replyTo: replyTo,
      snippet: snippet,
      stableProviderMessageId: stableProviderMessageId,
      subject: subject,
      recipientHeaders: recipientHeaders,
      bccRecipients: bccRecipients,
      rfcMessageId: rfcMessageId
    )
  }
}
