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
  let isPeopleFallback: Bool
  let keywords: [String]
  let learningSignals: [FutureLearningSignal]

  init(
    id: String,
    keywords: [String],
    learningSignals: [FutureLearningSignal] = [],
    isPeopleFallback: Bool = false
  ) {
    self.id = id
    self.isPeopleFallback = isPeopleFallback
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
    MessageClassificationCategory(
      id: "system:people",
      keywords: [],
      isPeopleFallback: true
    ),
  ]
}

enum ClassificationDecision: Equatable {
  case assigned(categoryIds: [String])
  case needsBody
  case uncategorized
}

struct FutureLearningSignal: Codable, Equatable, Sendable {
  let appliesAfterTimestamp: Int64
  let categoryId: String
  let isPositive: Bool
  let overrideTimestamp: Int64?
  let senderAddresses: [String]

  init(
    appliesAfterTimestamp: Int64,
    categoryId: String,
    isPositive: Bool = true,
    overrideTimestamp: Int64? = nil,
    senderAddresses: [String]
  ) {
    self.appliesAfterTimestamp = appliesAfterTimestamp
    self.categoryId = categoryId
    self.isPositive = isPositive
    self.overrideTimestamp = overrideTimestamp
    self.senderAddresses = senderAddresses
  }

  private enum CodingKeys: String, CodingKey {
    case appliesAfterTimestamp
    case categoryId
    case isPositive
    case overrideTimestamp
    case senderAddresses
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    appliesAfterTimestamp = try container.decode(Int64.self, forKey: .appliesAfterTimestamp)
    categoryId = try container.decode(String.self, forKey: .categoryId)
    isPositive = try container.decodeIfPresent(Bool.self, forKey: .isPositive) ?? true
    overrideTimestamp = try container.decodeIfPresent(Int64.self, forKey: .overrideTimestamp)
    senderAddresses = try container.decode([String].self, forKey: .senderAddresses)
  }

  var identities: [FutureLearningSignalIdentity] {
    senderAddresses.map {
      FutureLearningSignalIdentity(categoryId: categoryId, senderAddress: $0)
    }
  }
}

struct FutureLearningSignalIdentity: Hashable, Sendable {
  let categoryId: String
  let senderAddress: String
}

struct BackgroundCategorizationSenderContext: Codable, Equatable {
  let cachedAtMilliseconds: Int64
  let learningSignals: [FutureLearningSignal]
}

struct BackgroundCategorizationContextCache: Codable, Equatable {
  let automaticCategorizationEnabled: Bool
  let customCategories: [CustomCategory]
  let customCategoryCachedAtMilliseconds: Int64
  let enabledSystemCategoryIds: [String]
  let learningResetAtMilliseconds: Int64?
  let learningSignalsBySender: [String: BackgroundCategorizationSenderContext]
  let schemaVersion: Int

  init(
    customCategories: [CustomCategory],
    customCategoryCachedAtMilliseconds: Int64,
    learningSignalsBySender: [String: BackgroundCategorizationSenderContext],
    configuration: CategoryConfiguration = .default
  ) {
    automaticCategorizationEnabled = configuration.automaticCategorizationEnabled
    self.customCategories = customCategories
    self.customCategoryCachedAtMilliseconds = customCategoryCachedAtMilliseconds
    enabledSystemCategoryIds = SystemCategoryDefinition.all.map(\.id).filter(
      configuration.isSystemCategoryEnabled
    )
    learningResetAtMilliseconds = configuration.learningResetAtMilliseconds
    self.learningSignalsBySender = learningSignalsBySender
    schemaVersion = 2
  }

  init(
    customCategory: CustomCategory?,
    customCategoryCachedAtMilliseconds: Int64,
    learningSignalsBySender: [String: BackgroundCategorizationSenderContext]
  ) {
    self.init(
      customCategories: customCategory.map { [$0] } ?? [],
      customCategoryCachedAtMilliseconds: customCategoryCachedAtMilliseconds,
      learningSignalsBySender: learningSignalsBySender
    )
  }

  var customCategory: CustomCategory? {
    customCategories.first
  }

  private enum CodingKeys: String, CodingKey {
    case customCategories
    case customCategory
    case customCategoryCachedAtMilliseconds
    case automaticCategorizationEnabled
    case enabledSystemCategoryIds
    case learningResetAtMilliseconds
    case learningSignalsBySender
    case schemaVersion
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    automaticCategorizationEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .automaticCategorizationEnabled) ?? true
    customCategories =
      try container.decodeIfPresent(
        [CustomCategory].self,
        forKey: .customCategories
      ) ?? container.decodeIfPresent(CustomCategory.self, forKey: .customCategory).map { [$0] }
      ?? []
    customCategoryCachedAtMilliseconds = try container.decode(
      Int64.self,
      forKey: .customCategoryCachedAtMilliseconds
    )
    enabledSystemCategoryIds =
      try container.decodeIfPresent([String].self, forKey: .enabledSystemCategoryIds)
      ?? SystemCategoryDefinition.all.map(\.id)
    learningResetAtMilliseconds = try container.decodeIfPresent(
      Int64.self,
      forKey: .learningResetAtMilliseconds
    )
    learningSignalsBySender = try container.decode(
      [String: BackgroundCategorizationSenderContext].self,
      forKey: .learningSignalsBySender
    )
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(automaticCategorizationEnabled, forKey: .automaticCategorizationEnabled)
    try container.encode(customCategories, forKey: .customCategories)
    try container.encodeIfPresent(customCategory, forKey: .customCategory)
    try container.encode(
      customCategoryCachedAtMilliseconds, forKey: .customCategoryCachedAtMilliseconds)
    try container.encode(enabledSystemCategoryIds, forKey: .enabledSystemCategoryIds)
    try container.encodeIfPresent(
      learningResetAtMilliseconds,
      forKey: .learningResetAtMilliseconds
    )
    try container.encode(learningSignalsBySender, forKey: .learningSignalsBySender)
    try container.encode(schemaVersion, forKey: .schemaVersion)
  }
}

private struct BackgroundClassificationContext {
  let learningSignalSenderAddresses: [String]
  let cachedLearningSignals: [FutureLearningSignal]
  let limitedToCategoryIds: Set<String>?
}

private struct CategorizationBatchContext {
  let classification: BackgroundClassificationContext
  let configuration: CategoryConfiguration?
}

private struct ClassificationCategorySnapshot {
  let categories: [MessageClassificationCategory]
  let configuration: CategoryConfiguration
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

enum MessageCategoryAssignmentSource: String, Codable, Sendable {
  case system
  case userOverride
}

struct GmailHistoricalCategorizationScope: Equatable {
  var categoryIds: Set<String>?
  var collection: MailboxMessageCollection = .role(.inbox)
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
      && collection.contains(providerStateIds: message.providerLabelIds)
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

  var categoryIds: Set<String>? {
    switch self {
    case .boundedHistorical(let scope):
      return scope.categoryIds
    case .newMailOnly:
      return nil
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
    let minimizedTokens = ClassificationTokenizer.tokens(
      in: [
        input.minimized.from,
        input.minimized.replyTo,
        input.minimized.snippet,
        input.minimized.subject,
      ].compactMap { $0 }.joined(separator: " ")
    )
    let minimizedCategoryIds = matchingCategoryIds(
      input: input,
      inputTokens: minimizedTokens,
      senderAddresses: senderAddresses,
      categories: categories,
      allowsPeopleFallback: false
    )
    if !minimizedCategoryIds.isEmpty {
      return .assigned(categoryIds: minimizedCategoryIds)
    }

    guard let bodyText = input.bodyText else {
      return .needsBody
    }
    let bodyCategoryIds = matchingCategoryIds(
      input: input,
      inputTokens: ClassificationTokenizer.tokens(in: bodyText),
      senderAddresses: senderAddresses,
      categories: categories,
      allowsPeopleFallback: true
    )
    guard !bodyCategoryIds.isEmpty else {
      return .uncategorized
    }
    return .assigned(categoryIds: bodyCategoryIds)
  }

  private func matchingCategoryIds(
    input: ClassificationInput,
    inputTokens: Set<String>,
    senderAddresses: Set<String>,
    categories: [MessageClassificationCategory],
    allowsPeopleFallback: Bool
  ) -> [String] {
    var matchedCategoryIds: Set<String> = []
    for category in categories where !category.isPeopleFallback {
      let learnedSignal = category.learningSignals
        .filter { signal in
          input.minimized.providerInternalDateMilliseconds > signal.appliesAfterTimestamp
            && !senderAddresses.isDisjoint(with: signal.senderAddresses)
        }
        .max { learningSignalOrderTimestamp($0) < learningSignalOrderTimestamp($1) }
      if let learnedSignal {
        if learnedSignal.isPositive { matchedCategoryIds.insert(category.id) }
        continue
      }
      if !inputTokens.isDisjoint(with: category.keywords.map { $0.lowercased() }) {
        matchedCategoryIds.insert(category.id)
      }
    }
    if allowsPeopleFallback,
      matchedCategoryIds.isEmpty,
      let fallbackCategory = categories.first(where: \.isPeopleFallback),
      isDirectCorrespondence(input: input, senderAddresses: senderAddresses)
    {
      matchedCategoryIds.insert(fallbackCategory.id)
    }
    return matchedCategoryIds.sorted()
  }

  private func isDirectCorrespondence(
    input: ClassificationInput,
    senderAddresses: Set<String>
  ) -> Bool {
    guard senderAddresses.count == 1, let senderAddress = senderAddresses.first else {
      return false
    }
    let automatedMarkers = [
      "automated", "campaign", "digest", "marketing", "newsletter", "no-reply", "noreply",
      "notification", "notifications", "promo", "support", "updates",
    ]
    let localPart = senderAddress.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
    let minimizedTokens = ClassificationTokenizer.tokens(
      in: [input.minimized.subject, input.minimized.snippet, localPart].joined(separator: " ")
    )
    return minimizedTokens.isDisjoint(with: automatedMarkers)
  }
}

struct MessageCategoryMembership: Codable, Equatable, Sendable {
  let categoryId: String
  let isIncluded: Bool
  let learningSignal: FutureLearningSignal?
  let overrideTimestamp: Int64?
  let source: MessageCategoryAssignmentSource

  init(
    categoryId: String,
    isIncluded: Bool = true,
    learningSignal: FutureLearningSignal? = nil,
    overrideTimestamp: Int64? = nil,
    source: MessageCategoryAssignmentSource = .system
  ) {
    self.categoryId = categoryId
    self.isIncluded = isIncluded
    self.learningSignal = learningSignal
    self.overrideTimestamp = overrideTimestamp
    self.source = source
  }
}

/// An encrypted Product Sync record that associates one message identity with Category memberships.
///
/// Example:
/// ```swift
/// let assignment = MessageCategoryAssignment(
///   categoryId: "system:flights",
///   stableProviderMessageId: "gmail:account:message-001"
/// )
/// ```
struct MessageCategoryAssignment: Codable, Equatable, Sendable {
  let memberships: [MessageCategoryMembership]
  let schemaVersion: Int
  let stableProviderMessageId: String

  var categoryIds: [String] {
    memberships.filter(\.isIncluded).map(\.categoryId).uniquedAndSorted()
  }

  var categoryId: String {
    categoryIds.first ?? memberships.map(\.categoryId).sorted().first ?? ""
  }

  var learningSignal: FutureLearningSignal? {
    primaryMembership?.learningSignal
  }

  var overrideTimestamp: Int64? {
    primaryMembership?.overrideTimestamp
  }

  var source: MessageCategoryAssignmentSource {
    primaryMembership?.source ?? .system
  }

  private var primaryMembership: MessageCategoryMembership? {
    memberships.first { $0.categoryId == categoryId }
  }

  init(
    categoryId: String,
    learningSignal: FutureLearningSignal? = nil,
    overrideTimestamp: Int64? = nil,
    source: MessageCategoryAssignmentSource = .system,
    stableProviderMessageId: String
  ) {
    memberships = [
      MessageCategoryMembership(
        categoryId: categoryId,
        learningSignal: learningSignal,
        overrideTimestamp: overrideTimestamp,
        source: source
      )
    ]
    schemaVersion = 2
    self.stableProviderMessageId = stableProviderMessageId
  }

  init(
    memberships: [MessageCategoryMembership],
    stableProviderMessageId: String
  ) {
    self.memberships = Dictionary(
      memberships.map { ($0.categoryId, $0) },
      uniquingKeysWith: { _, latest in latest }
    ).values.sorted { $0.categoryId < $1.categoryId }
    schemaVersion = 2
    self.stableProviderMessageId = stableProviderMessageId
  }

  private enum CodingKeys: String, CodingKey {
    case categoryId
    case learningSignal
    case memberships
    case overrideTimestamp
    case schemaVersion
    case source
    case stableProviderMessageId
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    stableProviderMessageId = try container.decode(String.self, forKey: .stableProviderMessageId)
    if let decodedMemberships = try container.decodeIfPresent(
      [MessageCategoryMembership].self,
      forKey: .memberships
    ) {
      memberships = decodedMemberships
      schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
      return
    }
    let categoryId = try container.decode(String.self, forKey: .categoryId)
    memberships = [
      MessageCategoryMembership(
        categoryId: categoryId,
        learningSignal: try container.decodeIfPresent(
          FutureLearningSignal.self,
          forKey: .learningSignal
        ),
        overrideTimestamp: try container.decodeIfPresent(
          Int64.self,
          forKey: .overrideTimestamp
        ),
        source: try container.decodeIfPresent(
          MessageCategoryAssignmentSource.self,
          forKey: .source
        ) ?? .system
      )
    ]
    schemaVersion = 1
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(memberships, forKey: .memberships)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(stableProviderMessageId, forKey: .stableProviderMessageId)
  }
}

extension Sequence where Element == String {
  fileprivate func uniquedAndSorted() -> [String] {
    Array(Set(self)).sorted()
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
    identities: [FutureLearningSignalIdentity],
    session: ProductAccountSessionSnapshot
  ) async throws -> [FutureLearningSignal]

  /// Saves a new assignment through the typed Product Sync record family.
  func saveAssignment(
    _ assignment: MessageCategoryAssignment,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment

  /// Replaces an assignment through the typed Product Sync record family after a user action.
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
  private static let assignmentIdentifierPrefix = "message-categories-v2:"
  private static let legacyAssignmentIdentifierPrefix = "message-category:"
  private static let learningSignalIdentifierPrefix = "message-category-learning-signal-v2:"

  private let assignmentRecords: ProductSyncRecordFamilyHandle<String, MessageCategoryAssignment>
  private let legacyAssignmentRecords:
    ProductSyncRecordFamilyHandle<String, MessageCategoryAssignment>
  private let legacyLearningSignalRecords:
    ProductSyncKeyedRecordFamilyHandle<FutureLearningSignalIdentity, FutureLearningSignal>
  private let learningSignalRecords:
    ProductSyncKeyedRecordFamilyHandle<
      FutureLearningSignalIdentity,
      FutureLearningSignal
    >

  init(
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()
  ) {
    let boundary = recordBoundary
    assignmentRecords = boundary.family(
      ProductSyncRecordFamilyDefinition(
        identifier: { $0 },
        identifierPrefix: Self.assignmentIdentifierPrefix,
        recordId: { identifier in
          identifier.hasPrefix(Self.assignmentIdentifierPrefix) ? identifier : nil
        },
        cachePolicy: .authoritative
      )
    )
    legacyAssignmentRecords = boundary.family(
      ProductSyncRecordFamilyDefinition(
        identifier: { $0 },
        identifierPrefix: Self.legacyAssignmentIdentifierPrefix,
        recordId: { identifier in
          identifier.hasPrefix(Self.legacyAssignmentIdentifierPrefix) ? identifier : nil
        },
        cachePolicy: .authoritative
      )
    )
    learningSignalRecords = boundary.keyedFamily(
      ProductSyncKeyedRecordFamilyDefinition(
        identifierData: { identity in
          Data(
            "\(identity.categoryId.utf8.count):\(identity.categoryId)"
              .appending("\(identity.senderAddress.utf8.count):\(identity.senderAddress)").utf8
          )
        },
        identifierPrefix: Self.learningSignalIdentifierPrefix,
        cachePolicy: .authoritative
      )
    )
    legacyLearningSignalRecords = boundary.keyedFamily(
      ProductSyncKeyedRecordFamilyDefinition(
        identifierData: { Data($0.senderAddress.utf8) },
        identifierPrefix: FutureLearningSignalPayload.identifierPrefix,
        cachePolicy: .authoritative
      )
    )
  }

  func loadAssignments(
    stableProviderMessageIds: [String],
    session: ProductAccountSessionSnapshot
  ) async throws -> [String: MessageCategoryAssignment] {
    guard !stableProviderMessageIds.isEmpty else { return [:] }
    let stableProviderMessageIdsByIdentifier = Dictionary(
      stableProviderMessageIds.map { (payloadIdentifier(for: $0), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let legacyMessageIdsByIdentifier = Dictionary(
      stableProviderMessageIds.map { (legacyPayloadIdentifier(for: $0), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    do {
      let records = try await assignmentRecords.readValid(
        Array(stableProviderMessageIdsByIdentifier.keys),
        session: session
      )
      let legacyRecords = try await legacyAssignmentRecords.readValid(
        Array(legacyMessageIdsByIdentifier.keys),
        session: session
      )
      var assignments: [String: MessageCategoryAssignment] = [:]
      for (identifier, stableProviderMessageId) in stableProviderMessageIdsByIdentifier {
        guard let record = records[identifier] else { continue }
        do {
          assignments[stableProviderMessageId] = try validatedAssignment(
            record.value,
            identifier: identifier,
            stableProviderMessageId: stableProviderMessageId
          )
        } catch {
          try Task.checkCancellation()
        }
      }
      for (identifier, stableProviderMessageId) in legacyMessageIdsByIdentifier
      where assignments[stableProviderMessageId] == nil {
        guard let record = legacyRecords[identifier] else { continue }
        do {
          assignments[stableProviderMessageId] = try validatedAssignment(
            record.value,
            identifier: identifier,
            stableProviderMessageId: stableProviderMessageId,
            identifierPrefix: Self.legacyAssignmentIdentifierPrefix
          )
        } catch {
          try Task.checkCancellation()
        }
      }
      return assignments
    } catch {
      throw mapAssignmentBoundaryError(error)
    }
  }

  func loadAssignment(
    stableProviderMessageId: String,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment? {
    let identifier = payloadIdentifier(for: stableProviderMessageId)
    let legacyIdentifier = legacyPayloadIdentifier(for: stableProviderMessageId)
    do {
      if let record = try await assignmentRecords.read([identifier], session: session)[identifier] {
        return try validatedAssignment(
          record.value,
          identifier: identifier,
          stableProviderMessageId: stableProviderMessageId
        )
      }
      guard
        let record = try await legacyAssignmentRecords.read(
          [legacyIdentifier],
          session: session
        )[legacyIdentifier]
      else { return nil }
      return try validatedAssignment(
        record.value,
        identifier: legacyIdentifier,
        stableProviderMessageId: stableProviderMessageId,
        identifierPrefix: Self.legacyAssignmentIdentifierPrefix
      )
    } catch {
      throw mapAssignmentBoundaryError(error)
    }
  }

  func loadFutureLearningSignals(
    identities: [FutureLearningSignalIdentity],
    session: ProductAccountSessionSnapshot
  ) async throws -> [FutureLearningSignal] {
    guard !identities.isEmpty else { return [] }
    let requestedIdentities = Set(identities)
    let records: [ProductSyncRecord<FutureLearningSignal>]
    let legacyRecords: [ProductSyncRecord<FutureLearningSignal>]
    do {
      records = try await learningSignalRecords.readValid(identities, session: session)
      legacyRecords = try await legacyLearningSignalRecords.readValid(identities, session: session)
    } catch {
      throw mapAssignmentBoundaryError(error)
    }
    var signalsByIdentity: [FutureLearningSignalIdentity: FutureLearningSignal] = [:]
    for signal in (legacyRecords + records).map(\.value) {
      for senderAddress in signal.senderAddresses {
        let identity = FutureLearningSignalIdentity(
          categoryId: signal.categoryId,
          senderAddress: senderAddress
        )
        guard requestedIdentities.contains(identity) else { continue }
        if let existing = signalsByIdentity[identity],
          learningSignalOrderTimestamp(existing) >= learningSignalOrderTimestamp(signal)
        {
          continue
        }
        signalsByIdentity[identity] = signal
      }
    }
    return requestedIdentities.sorted {
      if $0.categoryId != $1.categoryId { return $0.categoryId < $1.categoryId }
      return $0.senderAddress < $1.senderAddress
    }.compactMap {
      signalsByIdentity[$0]
    }
  }

  func saveAssignment(
    _ assignment: MessageCategoryAssignment,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment {
    let identifier = payloadIdentifier(for: assignment.stableProviderMessageId)
    let legacyAssignment = try await loadLegacyAssignment(
      stableProviderMessageId: assignment.stableProviderMessageId,
      session: session
    )
    do {
      let record = try await assignmentRecords.update(identifier, session: session) { existing in
        let current =
          try existing.map {
            try self.validatedAssignment(
              $0.value,
              identifier: identifier,
              stableProviderMessageId: assignment.stableProviderMessageId
            )
          } ?? legacyAssignment
        let merged = self.mergedAssignment(
          current,
          with: assignment,
          afterConcurrentWrite: false
        )
        return merged == current ? .acceptAuthoritative : .write(merged)
      }
      guard let record else {
        throw MessageCategoryAssignmentSyncError.invalidStableProviderMessageIdentity
      }
      return try validatedAssignment(
        record.value,
        identifier: identifier,
        stableProviderMessageId: assignment.stableProviderMessageId
      )
    } catch {
      throw mapAssignmentBoundaryError(error)
    }
  }
}

extension MessageCategoryAssignmentSyncService {
  func saveUserOverride(
    _ assignment: MessageCategoryAssignment,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment {
    let storedAssignment = try await saveNewestUserOverride(
      assignment,
      session: session
    )
    for signal in storedAssignment.memberships.compactMap(\.learningSignal)
    where !signal.senderAddresses.isEmpty {
      try await saveLearningSignal(signal, session: session)
    }
    return storedAssignment
  }

  private func saveNewestUserOverride(
    _ assignment: MessageCategoryAssignment,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment {
    let identifier = payloadIdentifier(for: assignment.stableProviderMessageId)
    let legacyAssignment = try await loadLegacyAssignment(
      stableProviderMessageId: assignment.stableProviderMessageId,
      session: session
    )
    var foundConcurrentWrite = false
    do {
      let record = try await assignmentRecords.update(identifier, session: session) { existing in
        let existingAssignment =
          try existing.map {
            try self.validatedAssignment(
              $0.value,
              identifier: identifier,
              stableProviderMessageId: assignment.stableProviderMessageId
            )
          } ?? legacyAssignment
        let merged = self.mergedAssignment(
          existingAssignment,
          with: assignment,
          afterConcurrentWrite: foundConcurrentWrite
        )
        if merged == existingAssignment { return .acceptAuthoritative }
        foundConcurrentWrite = true
        return .write(merged)
      }
      guard let record else {
        throw MessageCategoryAssignmentSyncError.invalidStableProviderMessageIdentity
      }
      return try validatedAssignment(
        record.value,
        identifier: identifier,
        stableProviderMessageId: assignment.stableProviderMessageId
      )
    } catch {
      throw mapAssignmentBoundaryError(error)
    }
  }

  private func mergedAssignment(
    _ existingAssignment: MessageCategoryAssignment?,
    with assignment: MessageCategoryAssignment,
    afterConcurrentWrite: Bool
  ) -> MessageCategoryAssignment {
    guard let existingAssignment else { return assignment.withoutSystemPeopleConflict() }
    var membershipsByCategoryId = Dictionary(
      existingAssignment.memberships.map { ($0.categoryId, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    for proposed in assignment.memberships {
      guard let existing = membershipsByCategoryId[proposed.categoryId] else {
        membershipsByCategoryId[proposed.categoryId] = proposed
        continue
      }
      membershipsByCategoryId[proposed.categoryId] = mergedMembership(
        existing,
        with: proposed,
        afterConcurrentWrite: afterConcurrentWrite
      )
    }
    return MessageCategoryAssignment(
      memberships: Array(membershipsByCategoryId.values),
      stableProviderMessageId: assignment.stableProviderMessageId
    ).withoutSystemPeopleConflict()
  }

  private func mergedMembership(
    _ existing: MessageCategoryMembership,
    with proposed: MessageCategoryMembership,
    afterConcurrentWrite: Bool
  ) -> MessageCategoryMembership {
    if existing.source != proposed.source {
      return existing.source == .userOverride ? existing : proposed
    }
    if existing.source == .system { return existing }
    if afterConcurrentWrite, existing.isIncluded != proposed.isIncluded {
      return existing.isIncluded ? proposed : existing
    }
    switch (existing.overrideTimestamp, proposed.overrideTimestamp) {
    case (let existingTimestamp?, let assignmentTimestamp?):
      if existingTimestamp != assignmentTimestamp {
        return existingTimestamp > assignmentTimestamp ? existing : proposed
      }
    case (nil, _?):
      return proposed
    case (_?, nil):
      return existing
    case (nil, nil):
      break
    }
    if existing.isIncluded != proposed.isIncluded {
      return existing.isIncluded ? proposed : existing
    }
    return existing
  }

  private func saveLearningSignal(
    _ signal: FutureLearningSignal,
    session: ProductAccountSessionSnapshot
  ) async throws {
    for senderAddress in signal.senderAddresses {
      let exactSignal = FutureLearningSignal(
        appliesAfterTimestamp: signal.appliesAfterTimestamp,
        categoryId: signal.categoryId,
        isPositive: signal.isPositive,
        overrideTimestamp: signal.overrideTimestamp,
        senderAddresses: [senderAddress]
      )
      do {
        try await learningSignalRecords.update(
          FutureLearningSignalIdentity(
            categoryId: signal.categoryId,
            senderAddress: senderAddress
          ),
          session: session
        ) { existing in
          guard
            let storedSignal = learningSignalsBySaving(
              exactSignal,
              in: existing.map(\.value)
            )?.first
          else {
            return .acceptAuthoritative
          }
          return .write(storedSignal)
        }
      } catch {
        throw mapAssignmentBoundaryError(error)
      }
    }
  }

  private func validatedAssignment(
    _ assignment: MessageCategoryAssignment,
    identifier: String,
    stableProviderMessageId: String,
    identifierPrefix: String = MessageCategoryAssignmentSyncService.assignmentIdentifierPrefix
  ) throws -> MessageCategoryAssignment {
    guard
      (1...2).contains(assignment.schemaVersion),
      assignment.stableProviderMessageId == stableProviderMessageId,
      payloadIdentifier(for: assignment.stableProviderMessageId, prefix: identifierPrefix)
        == identifier,
      !assignment.memberships.contains(where: { membership in
        membership.categoryId.isEmpty
          || membership.learningSignal.map { $0.categoryId != membership.categoryId } == true
      }),
      Set(assignment.memberships.map(\.categoryId)).count == assignment.memberships.count
    else {
      throw MessageCategoryAssignmentSyncError.invalidStableProviderMessageIdentity
    }
    return assignment
  }

  private func mapAssignmentBoundaryError(_ error: Error) -> Error {
    guard let boundaryError = error as? ProductSyncRecordBoundaryError else { return error }
    switch boundaryError {
    case .invalidPayloadIdentifier:
      return MessageCategoryAssignmentSyncError.invalidStableProviderMessageIdentity
    case .missingProductSyncKeyMaterial:
      return MessageCategoryAssignmentSyncError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      return MessageCategoryAssignmentSyncError.conditionalWriteRetryLimitExceeded
    case .incompletePagination:
      return error
    }
  }

  private func payloadIdentifier(for stableProviderMessageId: String) -> String {
    payloadIdentifier(for: stableProviderMessageId, prefix: Self.assignmentIdentifierPrefix)
  }

  private func legacyPayloadIdentifier(for stableProviderMessageId: String) -> String {
    payloadIdentifier(for: stableProviderMessageId, prefix: Self.legacyAssignmentIdentifierPrefix)
  }

  private func payloadIdentifier(for stableProviderMessageId: String, prefix: String) -> String {
    let digest = SHA256.hash(data: Data(stableProviderMessageId.utf8))
    return prefix + digest.map { String(format: "%02x", $0) }.joined()
  }

  private func loadLegacyAssignment(
    stableProviderMessageId: String,
    session: ProductAccountSessionSnapshot
  ) async throws -> MessageCategoryAssignment? {
    let identifier = legacyPayloadIdentifier(for: stableProviderMessageId)
    guard
      let record = try await legacyAssignmentRecords.read([identifier], session: session)[
        identifier]
    else {
      return nil
    }
    return try? validatedAssignment(
      record.value,
      identifier: identifier,
      stableProviderMessageId: stableProviderMessageId,
      identifierPrefix: Self.legacyAssignmentIdentifierPrefix
    )
  }
}

extension MessageCategoryAssignment {
  fileprivate func withoutSystemPeopleConflict() -> MessageCategoryAssignment {
    let hasPurposeSpecificSystemMembership = memberships.contains {
      $0.isIncluded && $0.categoryId.hasPrefix("system:") && $0.categoryId != "system:people"
    }
    guard hasPurposeSpecificSystemMembership else { return self }
    return MessageCategoryAssignment(
      memberships: memberships.filter {
        !($0.categoryId == "system:people" && $0.source == .system)
      },
      stableProviderMessageId: stableProviderMessageId
    )
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

  /// Applies one transactional User Override to the complete membership set.
  func setCategories(
    _ categoryIds: [String],
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

  /// Compatibility fallback for conformers that still support one Category per message.
  /// It applies only `categoryIds.first` and ignores an empty collection.
  func setCategories(
    _ categoryIds: [String],
    for message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    guard let categoryId = categoryIds.first else { return message }
    return try await overrideCategory(categoryId, for: message, session: session)
  }
}

struct GmailMessageCategorizationService: GmailMessageCategorizing {
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
    guard messages.contains(where: { !$0.isHistorical && $0.messageCategoryIds.isEmpty }) else {
      return messages
    }
    let senderAddresses = learningSignalSenders(
      in: messages,
      excluding: [:],
      mode: .newMailOnly
    )
    let remoteCategories: [MessageClassificationCategory]?
    do {
      remoteCategories = try await classificationCategorySnapshot(
        context: BackgroundClassificationContext(
          learningSignalSenderAddresses: senderAddresses,
          cachedLearningSignals: [],
          limitedToCategoryIds: nil
        ),
        providerAccountIdentifier: try providerAccountIdentifier(in: messages),
        session: session
      ).categories
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
    guard !message.isHistorical, message.messageCategoryIds.isEmpty else { return message }
    guard
      let categories = try backgroundClassificationCategories(
        for: message,
        remoteCategories: remoteCategories,
        session: session
      ),
      let categoryIds = try await classifiedCategoryIds(
        for: message,
        categories: categories,
        session: session
      )
    else {
      return message
    }
    return message.assigningCategories(categoryIds)
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
    let categoryIdsByStableProviderMessageId = Dictionary(
      categorizedMessages.compactMap { message in
        message.messageCategoryIds.isEmpty
          ? nil
          : (message.stableProviderMessageId, message.messageCategoryIds)
      },
      uniquingKeysWith: { first, _ in first }
    )
    return messages.map { message in
      guard
        let categoryIds = categoryIdsByStableProviderMessageId[message.stableProviderMessageId]
      else {
        return message
      }
      return message.assigningCategories(categoryIds)
    }
  }

  private func categorize(
    messages: [GmailMessageMetadata],
    mode: GmailCategorizationMode,
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    var categorySnapshot: ClassificationCategorySnapshot?
    var categorizedMessages: [GmailMessageMetadata] = []
    let assignments = try await prefetchedAssignments(messages: messages, session: session)
    let signalSenders = learningSignalSenders(
      in: messages,
      excluding: assignments,
      mode: mode
    )
    let cachedLearningSignals = assignments.values.flatMap { assignment in
      assignment.memberships.compactMap { membership in
        membership.source == .userOverride ? membership.learningSignal : nil
      }
    }
    let classificationContext = BackgroundClassificationContext(
      learningSignalSenderAddresses: signalSenders,
      cachedLearningSignals: cachedLearningSignals,
      limitedToCategoryIds: mode.categoryIds
    )
    let currentConfiguration: CategoryConfiguration?
    do {
      currentConfiguration = try await categorySync.loadConfiguration(session: session)
    } catch {
      try Task.checkCancellation()
      currentConfiguration = nil
    }
    let batchContext = CategorizationBatchContext(
      classification: classificationContext,
      configuration: currentConfiguration
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
          categorySnapshot: &categorySnapshot,
          batchContext: batchContext,
          session: session
        )
      )
    }
    return categorizedMessages
  }

  private func categorizedMessage(
    _ message: GmailMessageMetadata,
    assignment: MessageCategoryAssignment?,
    categorySnapshot: inout ClassificationCategorySnapshot?,
    batchContext: CategorizationBatchContext,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    if let assignment { return message.assigningCategories(assignment.categoryIds) }
    guard message.messageCategoryIds.isEmpty else {
      return message
    }
    guard let currentConfiguration = batchContext.configuration else { return message }
    do {
      if categorySnapshot == nil {
        categorySnapshot = try await classificationCategorySnapshot(
          context: batchContext.classification,
          configuration: currentConfiguration,
          providerAccountIdentifier: message.providerAccountIdentifier,
          session: session
        )
      }
      guard let categorySnapshot, !categorySnapshot.categories.isEmpty else { return message }
      guard
        let categoryIds = try await classifiedCategoryIds(
          for: message,
          categories: categorySnapshot.categories,
          session: session
        )
      else {
        return message
      }
      guard
        currentConfiguration.automaticCategorizationEnabled,
        currentConfiguration.learningGeneration
          == categorySnapshot.configuration.learningGeneration,
        categoryIds.allSatisfy({ categoryId in
          !categoryId.hasPrefix("system:")
            || currentConfiguration.isSystemCategoryEnabled(categoryId)
        })
      else {
        return message
      }
      let savedAssignment = try await assignmentSync.saveAssignment(
        MessageCategoryAssignment(
          memberships: categoryIds.map { MessageCategoryMembership(categoryId: $0) },
          stableProviderMessageId: message.stableProviderMessageId
        ),
        session: session
      )
      return message.assigningCategories(savedAssignment.categoryIds)
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
          message.messageCategoryIds.isEmpty,
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
    try await setCategories([categoryId], for: message, session: session)
  }

  func setCategories(
    _ categoryIds: [String],
    for message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    let overrideTimestamp = currentTimeMilliseconds()
    let senderAddresses = MessageSenderAddressParser.addresses(
      in: [message.from].compactMap { $0 }
    )
    let desiredCategoryIds = Set(categoryIds.filter { !$0.isEmpty })
    let existingAssignment = try await assignmentSync.loadAssignment(
      stableProviderMessageId: message.stableProviderMessageId,
      session: session
    )
    let existingMemberships =
      existingAssignment?.memberships
      ?? message.messageCategoryIds.map { MessageCategoryMembership(categoryId: $0) }
    let existingCategoryIds = Set(existingMemberships.filter(\.isIncluded).map(\.categoryId))
    var membershipsByCategoryId = Dictionary(
      existingMemberships.map { ($0.categoryId, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    for categoryId in desiredCategoryIds.symmetricDifference(existingCategoryIds) {
      let isIncluded = desiredCategoryIds.contains(categoryId)
      membershipsByCategoryId[categoryId] = MessageCategoryMembership(
        categoryId: categoryId,
        isIncluded: isIncluded,
        learningSignal: FutureLearningSignal(
          appliesAfterTimestamp: max(
            overrideTimestamp,
            message.providerInternalDateMilliseconds
          ),
          categoryId: categoryId,
          isPositive: isIncluded,
          overrideTimestamp: overrideTimestamp,
          senderAddresses: senderAddresses
        ),
        overrideTimestamp: overrideTimestamp,
        source: .userOverride
      )
    }
    try backgroundContextCacheStore.clear(productAccountId: session.productAccountId)
    let assignment = try await assignmentSync.saveUserOverride(
      MessageCategoryAssignment(
        memberships: Array(membershipsByCategoryId.values),
        stableProviderMessageId: message.stableProviderMessageId
      ),
      session: session
    )
    return message.assigningCategories(assignment.categoryIds)
  }

  private func prefetchedAssignments(
    messages: [GmailMessageMetadata],
    session: ProductAccountSessionSnapshot
  ) async throws -> [String: MessageCategoryAssignment] {
    let stableProviderMessageIds = messages.map(\.stableProviderMessageId)
    do {
      return try await assignmentSync.loadAssignments(
        stableProviderMessageIds: stableProviderMessageIds,
        session: session
      )
    } catch {
      try Task.checkCancellation()
      return [:]
    }
  }

  private func classifiedCategoryIds(
    for message: GmailMessageMetadata,
    categories: [MessageClassificationCategory],
    session: ProductAccountSessionSnapshot
  ) async throws -> [String]? {
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
      case .assigned(let categoryIds) = decision,
      !categoryIds.isEmpty,
      categoryIds.allSatisfy({ categoryId in categories.contains(where: { $0.id == categoryId }) })
    else {
      return nil
    }
    return categoryIds.uniquedAndSorted()
  }

  private func classificationCategorySnapshot(
    context: BackgroundClassificationContext,
    providerAccountIdentifier: String,
    session: ProductAccountSessionSnapshot
  ) async throws -> ClassificationCategorySnapshot {
    let configuration = try await categorySync.loadConfiguration(session: session)
    return try await classificationCategorySnapshot(
      context: context,
      configuration: configuration,
      providerAccountIdentifier: providerAccountIdentifier,
      session: session
    )
  }

  private func classificationCategorySnapshot(
    context: BackgroundClassificationContext,
    configuration: CategoryConfiguration,
    providerAccountIdentifier: String,
    session: ProductAccountSessionSnapshot
  ) async throws -> ClassificationCategorySnapshot {
    let customCategories = try await categorySync.loadCategories(session: session)
      .filter(\.isEnabled)
    let categoryIds = availableAutomaticCategoryIds(
      customCategories: customCategories,
      configuration: configuration,
      limitedToCategoryIds: context.limitedToCategoryIds
    )
    let learningSignalIdentities = learningSignalIdentities(
      senderAddresses: context.learningSignalSenderAddresses,
      categoryIds: categoryIds
    )
    let learningSignals: [FutureLearningSignal]
    do {
      learningSignals = try await assignmentSync.loadFutureLearningSignals(
        identities: learningSignalIdentities,
        session: session
      )
    } catch {
      try? backgroundContextCacheStore.clear(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      )
      throw error
    }
    let validLearningSignals = (learningSignals + context.cachedLearningSignals).filter {
      learningSignalIsCurrent($0, configuration: configuration)
    }
    let cachedSenderAddresses = cachedSenderAddresses(context: context)
    try? refreshBackgroundContextCache(
      customCategories: customCategories,
      learningSignals: validLearningSignals,
      senderAddresses: cachedSenderAddresses,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      configuration: configuration
    )
    return ClassificationCategorySnapshot(
      categories: classificationCategories(
        customCategories: customCategories,
        learningSignals: validLearningSignals,
        configuration: configuration,
        limitedToCategoryIds: context.limitedToCategoryIds
      ),
      configuration: configuration
    )
  }

  private func learningSignalIdentities(
    senderAddresses: [String],
    categoryIds: [String]
  ) -> [FutureLearningSignalIdentity] {
    senderAddresses.flatMap { senderAddress in
      categoryIds.map {
        FutureLearningSignalIdentity(categoryId: $0, senderAddress: senderAddress)
      }
    }
  }

  private func cachedSenderAddresses(context: BackgroundClassificationContext) -> [String] {
    Array(
      Set(
        context.learningSignalSenderAddresses
          + context.cachedLearningSignals.flatMap(\.senderAddresses)
      )
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
      (1...2).contains(cache.schemaVersion),
      cacheIsFresh(cachedAtMilliseconds: cache.customCategoryCachedAtMilliseconds),
      let senderContext = cache.learningSignalsBySender[senderAddress],
      cacheIsFresh(cachedAtMilliseconds: senderContext.cachedAtMilliseconds),
      senderContext.learningSignals.allSatisfy({ $0.senderAddresses == [senderAddress] })
    else {
      return nil
    }
    let configuration = CategoryConfiguration(
      automaticCategorizationEnabled: cache.automaticCategorizationEnabled,
      disabledSystemCategoryIds: SystemCategoryDefinition.all.map(\.id).filter {
        !cache.enabledSystemCategoryIds.contains($0)
      },
      learningResetAtMilliseconds: cache.learningResetAtMilliseconds
    )
    return classificationCategories(
      customCategories: cache.customCategories,
      learningSignals: senderContext.learningSignals.filter {
        learningSignalIsCurrent($0, configuration: configuration)
      },
      configuration: configuration,
      limitedToCategoryIds: nil
    )
  }

  private func classificationCategories(
    customCategories: [CustomCategory],
    learningSignals: [FutureLearningSignal],
    configuration: CategoryConfiguration,
    limitedToCategoryIds: Set<String>?
  ) -> [MessageClassificationCategory] {
    guard configuration.automaticCategorizationEnabled else { return [] }
    let customClassificationCategories = customCategories.map { category in
      MessageClassificationCategory(
        id: category.id,
        keywords: classificationKeywords(for: category)
      )
    }
    let categories =
      customClassificationCategories
      + MessageClassificationCategory.systemCategories.filter {
        configuration.isSystemCategoryEnabled($0.id)
      }
    return categories.map { category in
      MessageClassificationCategory(
        id: category.id,
        keywords: category.keywords,
        learningSignals:
          learningSignals
          .filter { $0.categoryId == category.id },
        isPeopleFallback: category.isPeopleFallback
      )
    }.filter { limitedToCategoryIds?.contains($0.id) ?? true }
  }

  private func availableAutomaticCategoryIds(
    customCategories: [CustomCategory],
    configuration: CategoryConfiguration,
    limitedToCategoryIds: Set<String>?
  ) -> [String] {
    guard configuration.automaticCategorizationEnabled else { return [] }
    return (customCategories.map(\.id) + SystemCategoryDefinition.all.map(\.id))
      .filter { categoryId in
        (!categoryId.hasPrefix("system:") || configuration.isSystemCategoryEnabled(categoryId))
          && (limitedToCategoryIds?.contains(categoryId) ?? true)
      }
  }

  private func learningSignalIsCurrent(
    _ signal: FutureLearningSignal,
    configuration: CategoryConfiguration
  ) -> Bool {
    guard let resetAt = configuration.learningResetAtMilliseconds else { return true }
    return learningSignalOrderTimestamp(signal) >= resetAt
  }

  // swiftlint:disable:next function_parameter_count
  private func refreshBackgroundContextCache(
    customCategories: [CustomCategory],
    learningSignals: [FutureLearningSignal],
    senderAddresses: [String],
    productAccountId: String,
    providerAccountIdentifier: String,
    configuration: CategoryConfiguration
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
          isPositive: signal.isPositive,
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
        customCategories: customCategories,
        customCategoryCachedAtMilliseconds: cachedAtMilliseconds,
        learningSignalsBySender: learningSignalsBySender,
        configuration: configuration
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
      isPositive: signal.isPositive,
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
    assigningCategories([categoryId])
  }

  func assigningCategories(_ categoryIds: [String]) -> GmailMessageMetadata {
    let categoryIds = normalizedMessageCategoryIds(categoryIds)
    return GmailMessageMetadata(
      categoryId: categoryIds.first,
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
      rfcMessageId: rfcMessageId,
      categoryIds: categoryIds
    )
  }
}
