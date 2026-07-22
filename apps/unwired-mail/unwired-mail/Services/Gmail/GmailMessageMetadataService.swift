import Foundation
import SwiftData

// swiftlint:disable file_length type_body_length

struct GmailMessageMetadata: Codable, Equatable, Identifiable {
  var id: StableProviderMessageIdentity {
    stableIdentity
  }

  let categoryId: String?
  let from: String?
  let isHistorical: Bool
  let providerAccountIdentifier: String
  let providerInternalDateMilliseconds: Int64
  var providerLabelIds: [String]? = .none
  let providerMessageId: String
  let providerThreadId: String
  let replyTo: String?
  let snippet: String
  let stableProviderMessageId: String
  let subject: String
  var recipientHeaders: [String]? = .none
  let rfcMessageId: String?
}

struct GmailLocalMetadataSearch {
  static func messages(
    in messages: [GmailMessageMetadata],
    matching query: String,
    categoryNamesById: [String: String]
  ) -> [GmailMessageMetadata] {
    MailboxLocalMetadataSearch.messages(
      in: messages.map { $0.mailboxMetadata(connectionId: $0.mailboxConnectionId) },
      matching: query,
      categoryNamesById: categoryNamesById
    ).map(\.gmailMetadata)
  }
}

struct GmailInboxThread: Equatable, Identifiable {
  var id: MailboxThreadIdentity {
    latestMessage.threadIdentity
  }

  let latestMessage: GmailMessageMetadata
  let messages: [GmailMessageMetadata]
  let providerThreadId: String
}

struct GmailMetadataSyncResult: Equatable {
  let hasInitialMailboxAvailability: Bool
  let historyIsExpired: Bool
  let hasUnlistedNewMessages: Bool
  let historicalMetadataBackfillIsComplete: Bool
  let messages: [GmailMessageMetadata]
  let newMessageIds: Set<String>?
  let threads: [GmailInboxThread]

  init(
    hasInitialMailboxAvailability: Bool = true,
    historyIsExpired: Bool = false,
    hasUnlistedNewMessages: Bool = false,
    historicalMetadataBackfillIsComplete: Bool = true,
    messages: [GmailMessageMetadata],
    newMessageIds: Set<String>? = nil,
    threads: [GmailInboxThread]
  ) {
    self.hasInitialMailboxAvailability = hasInitialMailboxAvailability
    self.historyIsExpired = historyIsExpired
    self.hasUnlistedNewMessages = hasUnlistedNewMessages
    self.historicalMetadataBackfillIsComplete = historicalMetadataBackfillIsComplete
    self.messages = messages
    self.newMessageIds = newMessageIds
    self.threads = threads
  }
}

struct GmailMetadataSyncState: Equatable {
  let historicalMetadataBackfillIsComplete: Bool
  let initialHistoricalCutoffMilliseconds: Int64?
  let nextPageToken: String?
  let scanId: String

  init(
    historicalMetadataBackfillIsComplete: Bool,
    initialHistoricalCutoffMilliseconds: Int64? = nil,
    nextPageToken: String?,
    scanId: String
  ) {
    self.historicalMetadataBackfillIsComplete = historicalMetadataBackfillIsComplete
    self.initialHistoricalCutoffMilliseconds = initialHistoricalCutoffMilliseconds
    self.nextPageToken = nextPageToken
    self.scanId = scanId
  }
}

protocol GmailMessageMetadataPersisting {
  func clearMessages(productAccountId: String) throws

  func clearMessages(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws

  func loadMessages(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> [GmailMessageMetadata]

  func loadSyncState(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailMetadataSyncState?

  func saveSyncPage(
    _ messages: [GmailMessageMetadata],
    state: GmailMetadataSyncState,
    isFirstPage: Bool,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws

  func saveMessages(
    _ messages: [GmailMessageMetadata],
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws
}

extension GmailMessageMetadataPersisting {
  func clearMessages(
    productAccountId: String,
    providerAccountIdentifier _: String
  ) throws {
    try clearMessages(productAccountId: productAccountId)
  }

  func loadSyncState(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> GmailMetadataSyncState? {
    nil
  }

  func saveSyncPage(
    _ messages: [GmailMessageMetadata],
    state: GmailMetadataSyncState,
    isFirstPage: Bool,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    let storedMessages: [GmailMessageMetadata]
    if isFirstPage && state.historicalMetadataBackfillIsComplete {
      storedMessages = messages
    } else {
      let existingMessages = try loadMessages(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      )
      var messagesByStableId = Dictionary(
        uniqueKeysWithValues: existingMessages.map { ($0.stableProviderMessageId, $0) }
      )
      for message in messages {
        if let existingMessage = messagesByStableId[message.stableProviderMessageId] {
          messagesByStableId[message.stableProviderMessageId] =
            message
            .preservingCategoryStateAndHistoricalBoundary(
              from: existingMessage
            )
        } else {
          messagesByStableId[message.stableProviderMessageId] = message
        }
      }
      storedMessages = messagesByStableId.values.sorted {
        if $0.providerInternalDateMilliseconds == $1.providerInternalDateMilliseconds {
          return $0.providerMessageId < $1.providerMessageId
        }
        return $0.providerInternalDateMilliseconds > $1.providerInternalDateMilliseconds
      }
    }
    try saveMessages(
      storedMessages,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
  }
}

protocol GmailMessageMetadataSyncing {
  func categorizeHistorical(
    scope: GmailHistoricalCategorizationScope,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult

  func loadInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult

  func continueHistoricalBackfill(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult

  func syncInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection: GmailProviderConnectionStatus,
    includingHistoryCandidates: Bool,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId: String?,
    throughHistoryId: String?,
    shouldPersist: @escaping () -> Bool
  ) async throws -> GmailMetadataSyncResult

  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata
}

protocol GmailMessageSearching {
  func searchProvider(
    query: String,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata]
}

extension GmailMessageMetadataSyncing {
  func continueHistoricalBackfill(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    try await syncInbox(connection: connection, session: session)
  }

  func syncRecentInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    try await syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: true,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )
  }

}

enum GmailProviderMailAction: Equatable {
  case archive
  case delete
  case markRead
  case markUnread
  case star
  case unstar
}

struct GmailOutgoingMessage: Equatable {
  let body: String
  let recipient: String
  let subject: String
  let inReplyTo: String?
  let threadId: String?

  init(
    body: String,
    recipient: String,
    subject: String,
    inReplyTo: String? = nil,
    threadId: String? = nil
  ) {
    self.body = body
    self.recipient = recipient
    self.subject = subject
    self.inReplyTo = inReplyTo
    self.threadId = threadId
  }
}

protocol GmailProviderMailActing {
  func perform(
    _ action: GmailProviderMailAction,
    messageIds: [String],
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws

  func send(
    _ message: GmailOutgoingMessage,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws
}

struct FileGmailMessageMetadataStore {
  private let fileManager: FileManager
  private let rootDirectory: URL

  init(
    fileManager: FileManager = .default,
    rootDirectory: URL? = nil
  ) {
    self.fileManager = fileManager
    self.rootDirectory =
      rootDirectory
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("UnwiredMail/GmailMetadata", isDirectory: true)
  }

  func clearMessages(productAccountId: String) throws {
    guard fileManager.fileExists(atPath: rootDirectory.path) else {
      return
    }

    let prefixes = [
      "\(gmailSafeFileComponent(productAccountId))-",
      "\(legacyGmailSafeFileComponent(productAccountId))-",
    ]
    let fileURLs = try fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: nil
    )
    for fileURL in fileURLs
    where prefixes.contains(where: { fileURL.lastPathComponent.hasPrefix($0) }) {
      try fileManager.removeItem(at: fileURL)
    }
  }

  func clearMessages(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    let fileURL = metadataFileURL(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    if fileManager.fileExists(atPath: fileURL.path) {
      try fileManager.removeItem(at: fileURL)
    }

    // Legacy sanitized filenames can collide, so only remove one after its contents prove ownership.
    let legacyFileURL = legacyMetadataFileURL(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    guard
      fileManager.fileExists(atPath: legacyFileURL.path),
      let messages = try? JSONDecoder().decode(
        [GmailMessageMetadata].self,
        from: Data(contentsOf: legacyFileURL)
      ),
      !messages.isEmpty,
      messages.allSatisfy({ $0.providerAccountIdentifier == providerAccountIdentifier })
    else {
      return
    }
    try fileManager.removeItem(at: legacyFileURL)
  }

  func loadMessages(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> [GmailMessageMetadata] {
    let fileURL = metadataFileURL(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    if fileManager.fileExists(atPath: fileURL.path) {
      let data = try Data(contentsOf: fileURL)
      return try JSONDecoder().decode([GmailMessageMetadata].self, from: data)
    }
    let legacyFileURL = legacyMetadataFileURL(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    guard fileManager.fileExists(atPath: legacyFileURL.path) else {
      return []
    }
    let messages = try JSONDecoder().decode(
      [GmailMessageMetadata].self,
      from: Data(contentsOf: legacyFileURL)
    )
    guard
      !messages.isEmpty,
      messages.allSatisfy({ $0.providerAccountIdentifier == providerAccountIdentifier })
    else {
      return []
    }
    try saveMessages(
      messages,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    try fileManager.removeItem(at: legacyFileURL)
    return messages
  }

  func saveMessages(
    _ messages: [GmailMessageMetadata],
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    try fileManager.createDirectory(
      at: rootDirectory,
      withIntermediateDirectories: true
    )
    let fileURL = metadataFileURL(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    let data = try JSONEncoder().encode(messages)
    try data.write(to: fileURL, options: [.atomic])
  }

  private func metadataFileURL(
    productAccountId: String,
    providerAccountIdentifier: String
  ) -> URL {
    return rootDirectory.appendingPathComponent(
      "\(gmailSafeFileComponent(productAccountId))-\(gmailSafeFileComponent(providerAccountIdentifier)).json"
    )
  }

  private func legacyMetadataFileURL(
    productAccountId: String,
    providerAccountIdentifier: String
  ) -> URL {
    let productAccount = legacyGmailSafeFileComponent(productAccountId)
    let providerAccount = legacyGmailSafeFileComponent(providerAccountIdentifier)
    return rootDirectory.appendingPathComponent(
      "\(productAccount)-\(providerAccount).json"
    )
  }
}

@Model
final class DurableGmailMessageMetadataRecord {
  @Attribute(.unique) var storageKey: String
  var encodedMessage: Data
  var productAccountId: String
  var pendingRemovalScanId: String?
  var providerAccountIdentifier: String
  var stableProviderMessageId: String

  init(
    encodedMessage: Data,
    productAccountId: String,
    providerAccountIdentifier: String,
    stableProviderMessageId: String,
    storageKey: String
  ) {
    self.storageKey = storageKey
    self.encodedMessage = encodedMessage
    self.productAccountId = productAccountId
    self.providerAccountIdentifier = providerAccountIdentifier
    self.stableProviderMessageId = stableProviderMessageId
    pendingRemovalScanId = nil
  }

  func message() throws -> GmailMessageMetadata {
    try JSONDecoder().decode(GmailMessageMetadata.self, from: encodedMessage)
  }
}

@Model
final class GmailMetadataSyncCheckpointRecord {
  @Attribute(.unique) var storageKey: String
  var historicalMetadataBackfillIsComplete: Bool
  var initialHistoricalCutoffMilliseconds: Int64?
  var nextPageToken: String?
  var productAccountId: String
  var providerAccountIdentifier: String
  var scanId: String

  init(
    productAccountId: String,
    providerAccountIdentifier: String,
    state: GmailMetadataSyncState,
    storageKey: String
  ) {
    self.storageKey = storageKey
    self.productAccountId = productAccountId
    self.providerAccountIdentifier = providerAccountIdentifier
    historicalMetadataBackfillIsComplete = state.historicalMetadataBackfillIsComplete
    initialHistoricalCutoffMilliseconds = state.initialHistoricalCutoffMilliseconds
    nextPageToken = state.nextPageToken
    scanId = state.scanId
  }

  var state: GmailMetadataSyncState {
    GmailMetadataSyncState(
      historicalMetadataBackfillIsComplete: historicalMetadataBackfillIsComplete,
      initialHistoricalCutoffMilliseconds: initialHistoricalCutoffMilliseconds,
      nextPageToken: nextPageToken,
      scanId: scanId
    )
  }

  func update(from state: GmailMetadataSyncState) {
    historicalMetadataBackfillIsComplete = state.historicalMetadataBackfillIsComplete
    initialHistoricalCutoffMilliseconds = state.initialHistoricalCutoffMilliseconds
    nextPageToken = state.nextPageToken
    scanId = state.scanId
  }
}

struct SwiftDataGmailMessageMetadataStore: GmailMessageMetadataPersisting {
  private let containerResult: Result<ModelContainer, Error>
  private let legacyStore: FileGmailMessageMetadataStore

  init(
    container: ModelContainer? = nil,
    legacyStore: FileGmailMessageMetadataStore = FileGmailMessageMetadataStore()
  ) {
    self.legacyStore = legacyStore
    containerResult = Result {
      if let container {
        return container
      }
      let schema = Self.schema
      let configuration = ModelConfiguration("GmailMetadata", schema: schema)
      return try ModelContainer(for: schema, configurations: [configuration])
    }
  }

  static func inMemory(
    legacyStore: FileGmailMessageMetadataStore = FileGmailMessageMetadataStore()
  ) throws -> SwiftDataGmailMessageMetadataStore {
    let schema = Self.schema
    let configuration = ModelConfiguration(
      "GmailMetadataTests",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return SwiftDataGmailMessageMetadataStore(
      container: container,
      legacyStore: legacyStore
    )
  }

  func clearMessages(productAccountId: String) throws {
    let context = try makeContext()
    let descriptor = FetchDescriptor<DurableGmailMessageMetadataRecord>(
      predicate: #Predicate { $0.productAccountId == productAccountId }
    )
    for record in try context.fetch(descriptor) {
      context.delete(record)
    }
    let checkpointDescriptor = FetchDescriptor<GmailMetadataSyncCheckpointRecord>(
      predicate: #Predicate { $0.productAccountId == productAccountId }
    )
    for checkpoint in try context.fetch(checkpointDescriptor) {
      context.delete(checkpoint)
    }
    try context.save()
    try legacyStore.clearMessages(productAccountId: productAccountId)
  }

  func clearMessages(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    let context = try makeContext()
    for record in try fetchRecords(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      context: context
    ) {
      context.delete(record)
    }
    if let checkpoint = try fetchCheckpoint(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      context: context
    ) {
      context.delete(checkpoint)
    }
    try context.save()
    try legacyStore.clearMessages(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
  }

  func loadMessages(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> [GmailMessageMetadata] {
    let context = try makeContext()
    let messages = try fetchRecords(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      context: context
    )
    .map { try $0.message() }
    .sorted(by: Self.messagesAreOrdered)
    guard messages.isEmpty else { return messages }
    let legacyMessages = try legacyStore.loadMessages(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    guard !legacyMessages.isEmpty else { return [] }
    try saveMessages(
      legacyMessages,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    try legacyStore.clearMessages(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    return legacyMessages.sorted(by: Self.messagesAreOrdered)
  }

  func loadSyncState(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> GmailMetadataSyncState? {
    let context = try makeContext()
    return try fetchCheckpoint(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      context: context
    )?.state
  }

  // swiftlint:disable:next function_body_length
  func saveSyncPage(
    _ messages: [GmailMessageMetadata],
    state: GmailMetadataSyncState,
    isFirstPage: Bool,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    let context = try makeContext()
    let existingRecords = try fetchRecords(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      stableProviderMessageIds: isFirstPage ? nil : Set(messages.map(\.stableProviderMessageId)),
      context: context
    )
    if isFirstPage {
      for record in existingRecords {
        record.pendingRemovalScanId = state.scanId
      }
    }
    let existingByStableId = Dictionary(
      uniqueKeysWithValues: existingRecords.map { ($0.stableProviderMessageId, $0) }
    )
    for message in messages {
      if let record = existingByStableId[message.stableProviderMessageId] {
        record.encodedMessage = try JSONEncoder().encode(
          message.preservingHistoricalBoundary(from: try record.message())
        )
        record.pendingRemovalScanId = nil
      } else {
        context.insert(
          DurableGmailMessageMetadataRecord(
            encodedMessage: try JSONEncoder().encode(message),
            productAccountId: productAccountId,
            providerAccountIdentifier: providerAccountIdentifier,
            stableProviderMessageId: message.stableProviderMessageId,
            storageKey: Self.storageKey(
              productAccountId: productAccountId,
              providerAccountIdentifier: providerAccountIdentifier,
              stableProviderMessageId: message.stableProviderMessageId
            )
          )
        )
      }
    }
    if state.historicalMetadataBackfillIsComplete {
      let pendingRemovalRecords = try fetchRecords(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier,
        context: context
      )
      for record in pendingRemovalRecords where record.pendingRemovalScanId == state.scanId {
        context.delete(record)
      }
    }
    if let checkpoint = try fetchCheckpoint(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      context: context
    ) {
      checkpoint.update(from: state)
    } else {
      context.insert(
        GmailMetadataSyncCheckpointRecord(
          productAccountId: productAccountId,
          providerAccountIdentifier: providerAccountIdentifier,
          state: state,
          storageKey: Self.checkpointStorageKey(
            productAccountId: productAccountId,
            providerAccountIdentifier: providerAccountIdentifier
          )
        )
      )
    }
    try context.save()
  }

  func saveMessages(
    _ messages: [GmailMessageMetadata],
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    let context = try makeContext()
    let existingRecords = try fetchRecords(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      context: context
    )
    var existingByStableId = Dictionary(
      uniqueKeysWithValues: existingRecords.map { ($0.stableProviderMessageId, $0) }
    )

    for message in messages {
      if let record = existingByStableId.removeValue(forKey: message.stableProviderMessageId) {
        record.encodedMessage = try JSONEncoder().encode(message)
      } else {
        context.insert(
          DurableGmailMessageMetadataRecord(
            encodedMessage: try JSONEncoder().encode(message),
            productAccountId: productAccountId,
            providerAccountIdentifier: providerAccountIdentifier,
            stableProviderMessageId: message.stableProviderMessageId,
            storageKey: Self.storageKey(
              productAccountId: productAccountId,
              providerAccountIdentifier: providerAccountIdentifier,
              stableProviderMessageId: message.stableProviderMessageId
            )
          )
        )
      }
    }
    for record in existingByStableId.values {
      context.delete(record)
    }
    try context.save()
  }

  private static let schema = Schema([
    DurableGmailMessageMetadataRecord.self,
    GmailMetadataSyncCheckpointRecord.self,
  ])

  private func makeContext() throws -> ModelContext {
    try ModelContext(containerResult.get())
  }

  private func fetchCheckpoint(
    productAccountId: String,
    providerAccountIdentifier: String,
    context: ModelContext
  ) throws -> GmailMetadataSyncCheckpointRecord? {
    var descriptor = FetchDescriptor<GmailMetadataSyncCheckpointRecord>(
      predicate: #Predicate {
        $0.productAccountId == productAccountId
          && $0.providerAccountIdentifier == providerAccountIdentifier
      }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  private func fetchRecords(
    productAccountId: String,
    providerAccountIdentifier: String,
    stableProviderMessageIds: Set<String>? = nil,
    context: ModelContext
  ) throws -> [DurableGmailMessageMetadataRecord] {
    var descriptor = FetchDescriptor<DurableGmailMessageMetadataRecord>(
      predicate: #Predicate {
        $0.productAccountId == productAccountId
          && $0.providerAccountIdentifier == providerAccountIdentifier
      }
    )
    if let stableProviderMessageIds {
      descriptor.predicate = #Predicate {
        $0.productAccountId == productAccountId
          && $0.providerAccountIdentifier == providerAccountIdentifier
          && stableProviderMessageIds.contains($0.stableProviderMessageId)
      }
    }
    return try context.fetch(descriptor)
  }

  private static func messagesAreOrdered(
    _ lhs: GmailMessageMetadata,
    _ rhs: GmailMessageMetadata
  ) -> Bool {
    if lhs.providerInternalDateMilliseconds == rhs.providerInternalDateMilliseconds {
      return lhs.providerMessageId < rhs.providerMessageId
    }
    return lhs.providerInternalDateMilliseconds > rhs.providerInternalDateMilliseconds
  }

  private static func storageKey(
    productAccountId: String,
    providerAccountIdentifier: String,
    stableProviderMessageId: String
  ) -> String {
    [productAccountId, providerAccountIdentifier, stableProviderMessageId]
      .map(gmailSafeFileComponent)
      .joined(separator: "-")
  }

  private static func checkpointStorageKey(
    productAccountId: String,
    providerAccountIdentifier: String
  ) -> String {
    [productAccountId, providerAccountIdentifier]
      .map(gmailSafeFileComponent)
      .joined(separator: "-")
  }
}

func gmailSafeFileComponent(_ value: String) -> String {
  Data(value.utf8).map { String(format: "%02x", $0) }.joined()
}

func legacyGmailSafeFileComponent(_ value: String) -> String {
  value
    .map { character in
      character.isLetter || character.isNumber || character == "-" ? character : "_"
    }
    .reduce(into: "") { partialResult, character in
      partialResult.append(character)
    }
}

struct GmailMessageMetadataService:
  GmailMessageMetadataSyncing, GmailMessageSearching, GmailProviderMailActing,
  GmailProviderTokenRefreshing
{
  private static let recipientHeaderNames = ["Bcc", "Cc", "To"]

  private let categorizer: GmailMessageCategorizing
  private let gmailBaseURL: URL
  private let notificationEligibilityStore: GmailPushEligibilityPersisting
  private let oauthClientId: String?
  private let session: URLSession
  private let shouldContinueHistoricalBackfill: () -> Bool
  private let store: GmailMessageMetadataPersisting
  private let tokenStore: GmailProviderTokenPersisting
  private let tokenInfoURL: URL
  private let tokenRefreshURL: URL

  init(
    categorizer: GmailMessageCategorizing = GmailMessageCategorizationService(),
    gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1")!,
    notificationEligibilityStore: GmailPushEligibilityPersisting = GmailPushEligibilityStore(),
    oauthClientId: String? =
      ProcessInfo.processInfo.environment["GMAIL_OAUTH_CLIENT_ID"]
      ?? DotEnvFile.value(for: "GMAIL_OAUTH_CLIENT_ID")
      ?? GmailOAuthClientIdConfiguration.bundledValue(),
    session: URLSession = .shared,
    shouldContinueHistoricalBackfill: @escaping () -> Bool = {
      !ProcessInfo.processInfo.isLowPowerModeEnabled
    },
    store: GmailMessageMetadataPersisting = SwiftDataGmailMessageMetadataStore(),
    tokenStore: GmailProviderTokenPersisting = KeychainGmailProviderTokenStore(),
    tokenInfoURL: URL = URL(string: "https://oauth2.googleapis.com/tokeninfo")!,
    tokenRefreshURL: URL = URL(string: "https://oauth2.googleapis.com/token")!
  ) {
    self.categorizer = categorizer
    self.gmailBaseURL = gmailBaseURL
    self.notificationEligibilityStore = notificationEligibilityStore
    self.oauthClientId = oauthClientId
    self.session = session
    self.shouldContinueHistoricalBackfill = shouldContinueHistoricalBackfill
    self.store = store
    self.tokenStore = tokenStore
    self.tokenInfoURL = tokenInfoURL
    self.tokenRefreshURL = tokenRefreshURL
  }

  func loadInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    let messages = try store.loadMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let state = try store.loadSyncState(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let visibleMessages = inboxMessages(messages)
    return GmailMetadataSyncResult(
      hasInitialMailboxAvailability: state != nil || !messages.isEmpty,
      historicalMetadataBackfillIsComplete:
        state?.historicalMetadataBackfillIsComplete ?? false,
      messages: visibleMessages,
      threads: GmailInboxThread.group(visibleMessages)
    )
  }

  func searchProvider(
    query: String,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }

    let tokens = try await tokensForSync(
      connection: connection,
      deferPersistence: false,
      session: session
    )
    let listedMessages = try await listProviderSearchMessages(
      accessToken: tokens.accessToken,
      query: query
    )
    return try await fetchListedMessageMetadata(
      accessToken: tokens.accessToken,
      categorizationBoundary: Date(
        timeIntervalSince1970: TimeInterval(connection.updatedAt) / 1_000
      ),
      connection: connection,
      listedMessages: listedMessages
    )
  }

  func categorizeHistorical(
    scope: GmailHistoricalCategorizationScope,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    let messages = try store.loadMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let categorizedInboxMessages = try await categorizer.categorizeHistorical(
      messages: inboxMessages(messages),
      scope: scope,
      session: session
    )
    let categorizedMessages = merging(categorizedInboxMessages, into: messages)
    try store.saveMessages(
      categorizedMessages,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let visibleMessages = inboxMessages(categorizedMessages)
    return GmailMetadataSyncResult(
      messages: visibleMessages,
      threads: GmailInboxThread.group(visibleMessages)
    )
  }

  // swiftlint:disable:next function_body_length
  func syncInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    let tokens = try await tokensForSync(
      connection: connection,
      deferPersistence: false,
      session: session
    )
    let existingMessages = try store.loadMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let existingMessagesByStableId = Dictionary(
      uniqueKeysWithValues: existingMessages.map { ($0.stableProviderMessageId, $0) }
    )
    let existingState = try store.loadSyncState(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let page = try await listProviderMessagePage(
      accessToken: tokens.accessToken,
      pageToken: nil
    )
    let incompleteBackfillCutoffMilliseconds = existingState.flatMap { state in
      state.historicalMetadataBackfillIsComplete
        ? nil
        : state.initialHistoricalCutoffMilliseconds
    }

    let initialHistoricalCutoffMilliseconds =
      incompleteBackfillCutoffMilliseconds
      ?? historicalCutoffMilliseconds(
        connection: connection,
        hasLocalMetadata: !existingMessages.isEmpty
      )
    var messages = try await fetchListedMessageMetadata(
      accessToken: tokens.accessToken,
      categorizationBoundary: historicalCutoff(
        milliseconds: initialHistoricalCutoffMilliseconds
      ),
      connection: connection,
      listedMessages: page.messages ?? []
    )
    messages = sortedMessages(
      messages,
      preservingExistingStateFrom: existingMessagesByStableId
    )
    try Task.checkCancellation()
    let categorizedInboxMessages = try await categorizer.categorize(
      messages: inboxMessages(messages),
      session: session
    )
    messages = merging(categorizedInboxMessages, into: messages)
    try Task.checkCancellation()
    let state = GmailMetadataSyncState(
      historicalMetadataBackfillIsComplete: page.nextPageToken == nil,
      initialHistoricalCutoffMilliseconds: initialHistoricalCutoffMilliseconds,
      nextPageToken: page.nextPageToken,
      scanId: UUID().uuidString
    )
    try store.saveSyncPage(
      messages,
      state: state,
      isFirstPage: true,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let storedMessages = mergedMessages(
      messages,
      with: existingMessages,
      replacingAll: state.historicalMetadataBackfillIsComplete
    )
    let visibleMessages = inboxMessages(storedMessages)
    return GmailMetadataSyncResult(
      historicalMetadataBackfillIsComplete: state.historicalMetadataBackfillIsComplete,
      messages: visibleMessages,
      threads: GmailInboxThread.group(visibleMessages)
    )
  }

  func continueHistoricalBackfill(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    try await continueHistoricalBackfill(
      connection: connection,
      session: session,
      allowsPageTokenReset: true
    )
  }

  // swiftlint:disable:next function_body_length
  private func continueHistoricalBackfill(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot,
    allowsPageTokenReset: Bool
  ) async throws -> GmailMetadataSyncResult {
    guard
      var state = try store.loadSyncState(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
    else {
      let refreshed = try await syncInbox(connection: connection, session: session)
      guard !refreshed.historicalMetadataBackfillIsComplete else { return refreshed }
      return try await continueHistoricalBackfill(
        connection: connection,
        session: session,
        allowsPageTokenReset: allowsPageTokenReset
      )
    }
    guard !state.historicalMetadataBackfillIsComplete else {
      let messages = try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      let visibleMessages = inboxMessages(messages)
      return GmailMetadataSyncResult(
        messages: visibleMessages,
        threads: GmailInboxThread.group(visibleMessages)
      )
    }

    guard shouldContinueHistoricalBackfill() else {
      let messages = try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      let visibleMessages = inboxMessages(messages)
      return GmailMetadataSyncResult(
        historicalMetadataBackfillIsComplete: false,
        messages: visibleMessages,
        threads: GmailInboxThread.group(visibleMessages)
      )
    }

    let tokens = try await tokensForSync(
      connection: connection,
      deferPersistence: false,
      session: session
    )
    var storedMessages = try store.loadMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    while let pageToken = state.nextPageToken {
      try Task.checkCancellation()
      guard shouldContinueHistoricalBackfill() else { break }
      let page: GmailListMessagesResponse
      do {
        page = try await listProviderMessagePage(
          accessToken: tokens.accessToken,
          pageToken: pageToken
        )
      } catch GmailMessageMetadataSyncError.invalidGmailPageToken {
        guard allowsPageTokenReset else {
          throw GmailMessageMetadataSyncError.gmailRequestFailed
        }
        let refreshed = try await syncInbox(connection: connection, session: session)
        guard !refreshed.historicalMetadataBackfillIsComplete else { return refreshed }
        return try await continueHistoricalBackfill(
          connection: connection,
          session: session,
          allowsPageTokenReset: false
        )
      }
      let existingMessagesByStableId = Dictionary(
        uniqueKeysWithValues: storedMessages.map { ($0.stableProviderMessageId, $0) }
      )
      var pageMessages = try await fetchListedMessageMetadata(
        accessToken: tokens.accessToken,
        categorizationBoundary: historicalCutoff(
          milliseconds: state.initialHistoricalCutoffMilliseconds
            ?? historicalCutoffMilliseconds(connection: connection, hasLocalMetadata: true)
        ),
        connection: connection,
        listedMessages: page.messages ?? []
      )
      pageMessages = sortedMessages(
        pageMessages,
        preservingExistingStateFrom: existingMessagesByStableId
      )
      try Task.checkCancellation()
      let categorizedInboxMessages = try await categorizer.categorize(
        messages: inboxMessages(pageMessages),
        session: session
      )
      pageMessages = merging(categorizedInboxMessages, into: pageMessages)
      try Task.checkCancellation()
      guard shouldContinueHistoricalBackfill() else { break }
      state = GmailMetadataSyncState(
        historicalMetadataBackfillIsComplete: page.nextPageToken == nil,
        initialHistoricalCutoffMilliseconds: state.initialHistoricalCutoffMilliseconds,
        nextPageToken: page.nextPageToken,
        scanId: state.scanId
      )
      try store.saveSyncPage(
        pageMessages,
        state: state,
        isFirstPage: false,
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      storedMessages = mergedMessages(pageMessages, with: storedMessages)
    }
    storedMessages = try store.loadMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let visibleMessages = inboxMessages(storedMessages)
    return GmailMetadataSyncResult(
      historicalMetadataBackfillIsComplete: state.historicalMetadataBackfillIsComplete,
      messages: visibleMessages,
      threads: GmailInboxThread.group(visibleMessages)
    )
  }

  func syncRecentInbox(
    connection: GmailProviderConnectionStatus,
    includingHistoryCandidates: Bool = true,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId: String?,
    throughHistoryId: String?,
    shouldPersist: @escaping () -> Bool
  ) async throws -> GmailMetadataSyncResult {
    do {
      return try await syncInbox(
        connection: connection,
        includingHistoryCandidates: includingHistoryCandidates,
        listingAllMessages: false,
        maximumPages: 1,
        preservingUnlistedMessages: true,
        sinceHistoryId: sinceHistoryId,
        throughHistoryId: throughHistoryId,
        session: session,
        shouldPersist: shouldPersist
      )
    } catch GmailMessageMetadataSyncError.expiredGmailHistoryId {
      let result = try await syncInbox(
        connection: connection,
        includingHistoryCandidates: false,
        listingAllMessages: true,
        maximumPages: nil,
        preservingUnlistedMessages: false,
        sinceHistoryId: nil,
        throughHistoryId: nil,
        session: session,
        shouldPersist: shouldPersist
      )
      let storedMessages = try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      try store.saveSyncPage(
        storedMessages,
        state: GmailMetadataSyncState(
          historicalMetadataBackfillIsComplete: true,
          initialHistoricalCutoffMilliseconds: nil,
          nextPageToken: nil,
          scanId: UUID().uuidString
        ),
        isFirstPage: true,
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      let visibleMessages = inboxMessages(storedMessages)
      return GmailMetadataSyncResult(
        historyIsExpired: true,
        messages: visibleMessages,
        newMessageIds: [],
        threads: GmailInboxThread.group(visibleMessages)
      )
    }
  }

  // swiftlint:disable:next function_body_length function_parameter_count
  private func syncInbox(
    connection: GmailProviderConnectionStatus,
    includingHistoryCandidates: Bool,
    listingAllMessages: Bool,
    maximumPages: Int?,
    preservingUnlistedMessages: Bool,
    sinceHistoryId: String?,
    throughHistoryId: String?,
    session: ProductAccountSessionSnapshot,
    shouldPersist: (() -> Bool)?
  ) async throws -> GmailMetadataSyncResult {
    let tokens = try await tokensForSync(
      connection: connection,
      deferPersistence: shouldPersist != nil,
      session: session
    )
    let existingMessages = try store.loadMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let existingMessagesByStableId = Dictionary(
      uniqueKeysWithValues: existingMessages.map { ($0.stableProviderMessageId, $0) }
    )
    let categorizationBoundary = historicalCutoff(
      milliseconds: historicalCutoffMilliseconds(
        connection: connection,
        hasLocalMetadata: !existingMessages.isEmpty
      )
    )
    let inboxHistoryChanges: GmailInboxHistoryChanges?
    if let sinceHistoryId {
      inboxHistoryChanges = try await fetchInboxHistoryChanges(
        accessToken: tokens.accessToken,
        sinceHistoryId: sinceHistoryId,
        throughHistoryId: throughHistoryId
      )
    } else {
      inboxHistoryChanges = nil
    }
    var listedMessages = try await listProviderMessages(
      accessToken: tokens.accessToken,
      inboxOnly: !listingAllMessages,
      maximumPages: maximumPages,
      including: includingHistoryCandidates ? inboxHistoryChanges?.addedMessageIds : nil
    )
    if let inboxHistoryChanges {
      let listedMessageIds = Set(listedMessages.map(\.id))
      listedMessages += inboxHistoryChanges.stateChangedMessageIds
        .subtracting(inboxHistoryChanges.deletedMessageIds)
        .subtracting(listedMessageIds)
        .map { GmailListedMessage(id: $0) }
    }
    var fetchedMessages = try await fetchListedMessageMetadata(
      accessToken: tokens.accessToken,
      categorizationBoundary: categorizationBoundary,
      connection: connection,
      listedMessages: listedMessages
    )
    fetchedMessages = sortedMessages(
      fetchedMessages,
      preservingExistingStateFrom: existingMessagesByStableId
    )
    try Task.checkCancellation()
    guard shouldPersist?() ?? true else {
      throw GmailMessageMetadataSyncError.staleLocalConnection
    }
    let categorizedInboxMessages = try await categorizer.categorize(
      messages: inboxMessages(fetchedMessages),
      session: session
    )
    fetchedMessages = merging(categorizedInboxMessages, into: fetchedMessages)
    let currentInboxMessageIds = Set(
      inboxMessages(fetchedMessages).map(\.providerMessageId)
    )
    if preservingUnlistedMessages {
      let fetchedStableIds = Set(fetchedMessages.map(\.stableProviderMessageId))
      let unlistedMessages = existingMessages.filter {
        !fetchedStableIds.contains($0.stableProviderMessageId)
          && !(inboxHistoryChanges?.deletedMessageIds.contains($0.providerMessageId) ?? false)
      }
      fetchedMessages = sortedMessages(
        fetchedMessages + unlistedMessages,
        preservingExistingStateFrom: existingMessagesByStableId
      )
    }

    try Task.checkCancellation()
    guard shouldPersist?() ?? true else {
      throw GmailMessageMetadataSyncError.staleLocalConnection
    }
    if includingHistoryCandidates,
      let throughHistoryId,
      let addedMessageIds = inboxHistoryChanges?.addedMessageIds
    {
      let eligibleMessages = fetchedMessages.filter { message in
        !message.isHistorical
          && currentInboxMessageIds.contains(message.providerMessageId)
          && addedMessageIds.contains(message.providerMessageId)
      }
      try notificationEligibilityStore.record(
        eligibleMessages,
        throughHistoryId: throughHistoryId,
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
    }
    if shouldPersist != nil {
      try tokenStore.save(
        tokens,
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
    }
    try store.saveMessages(
      fetchedMessages,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    let addedMessageIds = inboxHistoryChanges?.addedMessageIds
    let visibleMessages = inboxMessages(fetchedMessages)
    return GmailMetadataSyncResult(
      hasUnlistedNewMessages: addedMessageIds.map {
        !$0.isSubset(of: currentInboxMessageIds)
      } ?? false,
      messages: visibleMessages,
      newMessageIds: addedMessageIds?.intersection(currentInboxMessageIds),
      threads: GmailInboxThread.group(visibleMessages)
    )
  }

  private func tokensForSync(
    connection: GmailProviderConnectionStatus,
    deferPersistence: Bool,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderTokens {
    let scopedTokens = try tokenStore.load(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    var storedTokens = scopedTokens
    if storedTokens == nil {
      storedTokens = try tokenStore.loadLegacy(productAccountId: session.productAccountId)
    }

    guard let storedTokens else {
      throw GmailMessageMetadataSyncError.missingLocalGmailTokens
    }
    let tokens = try await refreshedTokens(
      storedTokens,
      persist: scopedTokens != nil && !deferPersistence,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    try await validateRefreshedToken(tokens.accessToken, matches: connection)
    if scopedTokens == nil {
      try tokenStore.save(
        tokens,
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      try tokenStore.clearLegacy(productAccountId: session.productAccountId)
    }
    return tokens
  }

  func refreshProviderTokens(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderTokens {
    let scopedTokens = try tokenStore.load(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    var storedTokens = scopedTokens
    if storedTokens == nil {
      storedTokens = try tokenStore.loadLegacy(productAccountId: session.productAccountId)
    }
    guard let storedTokens else {
      throw GmailMessageMetadataSyncError.missingLocalGmailTokens
    }

    let tokens = try await refreshedTokens(
      storedTokens,
      persist: scopedTokens != nil,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    try await validateRefreshedToken(tokens.accessToken, matches: connection)
    if scopedTokens == nil {
      try tokenStore.save(
        tokens,
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      try tokenStore.clearLegacy(productAccountId: session.productAccountId)
    }
    return tokens
  }

  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    let overriddenMessage = try await categorizer.overrideCategory(
      categoryId,
      for: message,
      session: session
    )
    var didReplaceMessage = false
    var messages = try store.loadMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: message.providerAccountIdentifier
    ).map { storedMessage in
      guard storedMessage.stableProviderMessageId == message.stableProviderMessageId else {
        return storedMessage
      }
      didReplaceMessage = true
      return overriddenMessage
    }
    if !didReplaceMessage {
      messages.append(overriddenMessage)
    }
    try store.saveMessages(
      messages,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: message.providerAccountIdentifier
    )
    return overriddenMessage
  }

  func perform(
    _ action: GmailProviderMailAction,
    messageIds: [String],
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let accessToken = try await authorizedAccessToken(
      connection: connection,
      session: session,
      requiredScopes: [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://mail.google.com/",
      ]
    )
    for messageId in messageIds {
      let url = gmailBaseURL.appendingPathComponent("users/me/messages/\(messageId)")

      switch action {
      case .delete:
        try await sendAuthorizedRequest(
          url: url.appendingPathComponent("trash"), accessToken: accessToken, method: "POST")
      case .archive, .markRead, .markUnread, .star, .unstar:
        let labels: (add: [String], remove: [String])
        switch action {
        case .archive:
          labels = ([], ["INBOX"])
        case .markRead:
          labels = ([], ["UNREAD"])
        case .markUnread:
          labels = (["UNREAD"], [])
        case .star:
          labels = (["STARRED"], [])
        case .unstar:
          labels = ([], ["STARRED"])
        case .delete:
          fatalError("Handled above")
        }
        let body = try JSONEncoder().encode([
          "addLabelIds": labels.add,
          "removeLabelIds": labels.remove,
        ])
        try await sendAuthorizedRequest(
          url: url.appendingPathComponent("modify"),
          accessToken: accessToken,
          method: "POST",
          body: body
        )
      }
    }
  }

  func send(
    _ message: GmailOutgoingMessage,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let accessToken = try await authorizedAccessToken(
      connection: connection,
      session: session,
      requiredScopes: [
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.compose",
        "https://mail.google.com/",
      ]
    )
    let sender = try headerValue(connection.emailAddress)
    let recipient = try mailboxHeaderValue(message.recipient)
    let subject = try encodedHeaderValue(message.subject)
    var headers = [
      "To: \(recipient)",
      "From: \(sender)",
      "Subject: \(subject)",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=utf-8",
      "Content-Transfer-Encoding: 8bit",
    ]
    if let inReplyTo = message.inReplyTo {
      let replyHeader = try headerValue(inReplyTo)
      headers.append("In-Reply-To: \(replyHeader)")
      headers.append("References: \(replyHeader)")
    }
    let mimeMessage = (headers + ["", message.body]).joined(separator: "\r\n")
    let raw = Data(mimeMessage.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    var payload: [String: String] = ["raw": raw]
    if let threadId = message.threadId {
      payload["threadId"] = threadId
    }
    let body = try JSONEncoder().encode(payload)
    try await sendAuthorizedRequest(
      url: gmailBaseURL.appendingPathComponent("users/me/messages/send"),
      accessToken: accessToken,
      method: "POST",
      body: body
    )
  }

  private func authorizedAccessToken(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot,
    requiredScopes: Set<String>
  ) async throws -> String {
    guard
      let storedTokens = try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
    else {
      throw GmailMessageMetadataSyncError.missingLocalGmailTokens
    }
    let tokens = try await refreshedTokens(
      storedTokens,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    try await validateRefreshedToken(
      tokens.accessToken,
      matches: connection,
      requiredScopes: requiredScopes
    )
    return tokens.accessToken
  }

  private func listProviderMessages(
    accessToken: String,
    inboxOnly: Bool,
    maximumPages: Int?,
    including requiredMessageIds: Set<String>?
  ) async throws -> [GmailListedMessage] {
    var listedMessages: [GmailListedMessage] = []
    var nextPageToken: String?
    var pageCount = 0

    while true {
      var components = URLComponents(
        url: gmailBaseURL.appendingPathComponent("users/me/messages"),
        resolvingAgainstBaseURL: false
      )
      var queryItems = [
        URLQueryItem(name: "maxResults", value: "25")
      ]
      if inboxOnly {
        queryItems.insert(URLQueryItem(name: "labelIds", value: "INBOX"), at: 0)
      }
      if let nextPageToken {
        queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
      }
      components?.queryItems = queryItems
      guard let url = components?.url else {
        throw GmailMessageMetadataSyncError.invalidGmailRequest
      }

      let response = try await sendAuthorizedRequest(
        url: url,
        accessToken: accessToken,
        responseType: GmailListMessagesResponse.self
      )
      listedMessages.append(contentsOf: response.messages ?? [])
      nextPageToken = response.nextPageToken
      pageCount += 1
      try Task.checkCancellation()
      guard nextPageToken != nil else { break }
      let listedMessageIds = Set(listedMessages.map(\.id))
      let hasListedRequiredMessages =
        requiredMessageIds.map {
          $0.isSubset(of: listedMessageIds)
        } ?? true
      guard maximumPages.map({ pageCount < $0 }) ?? true || !hasListedRequiredMessages else {
        break
      }
    }

    return listedMessages
  }

  private func listProviderMessagePage(
    accessToken: String,
    pageToken: String?
  ) async throws -> GmailListMessagesResponse {
    var components = URLComponents(
      url: gmailBaseURL.appendingPathComponent("users/me/messages"),
      resolvingAgainstBaseURL: false
    )
    var queryItems = [
      URLQueryItem(name: "maxResults", value: "50")
    ]
    if let pageToken {
      queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
    }
    components?.queryItems = queryItems
    guard let url = components?.url else {
      throw GmailMessageMetadataSyncError.invalidGmailRequest
    }
    return try await sendAuthorizedRequest(
      url: url,
      accessToken: accessToken,
      responseType: GmailListMessagesResponse.self
    )
  }

  private func listProviderSearchMessages(
    accessToken: String,
    query: String
  ) async throws -> [GmailListedMessage] {
    let maximumResults = 100
    var listedMessages: [GmailListedMessage] = []
    var nextPageToken: String?

    repeat {
      var components = URLComponents(
        url: gmailBaseURL.appendingPathComponent("users/me/messages"),
        resolvingAgainstBaseURL: false
      )
      var queryItems = [
        URLQueryItem(
          name: "maxResults",
          value: String(min(100, maximumResults - listedMessages.count))
        ),
        URLQueryItem(name: "q", value: query),
      ]
      if let nextPageToken {
        queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
      }
      components?.queryItems = queryItems
      guard let url = components?.url else {
        throw GmailMessageMetadataSyncError.invalidGmailRequest
      }
      let response = try await sendAuthorizedRequest(
        url: url,
        accessToken: accessToken,
        responseType: GmailListMessagesResponse.self
      )
      listedMessages.append(contentsOf: response.messages ?? [])
      nextPageToken = response.nextPageToken
      try Task.checkCancellation()
    } while nextPageToken != nil && listedMessages.count < maximumResults

    return listedMessages
  }

  private func fetchInboxHistoryChanges(
    accessToken: String,
    sinceHistoryId: String,
    throughHistoryId: String?
  ) async throws -> GmailInboxHistoryChanges {
    var changes = GmailInboxHistoryChangesAccumulator()
    var nextPageToken: String?

    var reachedWakeBoundary = false
    repeat {
      var components = URLComponents(
        url: gmailBaseURL.appendingPathComponent("users/me/history"),
        resolvingAgainstBaseURL: false
      )
      var queryItems = [
        URLQueryItem(name: "startHistoryId", value: sinceHistoryId),
        URLQueryItem(name: "labelId", value: "INBOX"),
      ]
      if let nextPageToken {
        queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
      }
      components?.queryItems = queryItems
      guard let url = components?.url else {
        throw GmailMessageMetadataSyncError.invalidGmailRequest
      }

      let response = try await sendAuthorizedRequest(
        url: url,
        accessToken: accessToken,
        responseType: GmailListHistoryResponse.self
      )
      for record in response.history ?? [] {
        if let throughHistoryId, let recordId = record.id,
          gmailHistoryIdIsNewer(recordId, than: throughHistoryId)
        {
          reachedWakeBoundary = true
          break
        }
        changes.apply(record)
      }
      nextPageToken = response.nextPageToken
      try Task.checkCancellation()
    } while nextPageToken != nil && !reachedWakeBoundary

    return changes.result
  }

  private func fetchListedMessageMetadata(
    accessToken: String,
    categorizationBoundary: Date,
    connection: GmailProviderConnectionStatus,
    listedMessages: [GmailListedMessage]
  ) async throws -> [GmailMessageMetadata] {
    var messages: [GmailMessageMetadata] = []
    for listedMessage in listedMessages {
      messages.append(
        try await fetchMessageMetadata(
          accessToken: accessToken,
          categorizationBoundary: categorizationBoundary,
          connection: connection,
          providerMessageId: listedMessage.id
        )
      )
    }
    return messages
  }

  private func fetchMessageMetadata(
    accessToken: String,
    categorizationBoundary: Date,
    connection: GmailProviderConnectionStatus,
    providerMessageId: String
  ) async throws -> GmailMessageMetadata {
    var components = URLComponents(
      url: gmailBaseURL.appendingPathComponent("users/me/messages/\(providerMessageId)"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems =
      [
        URLQueryItem(name: "format", value: "metadata"),
        URLQueryItem(name: "metadataHeaders", value: "From"),
        URLQueryItem(name: "metadataHeaders", value: "Message-ID"),
        URLQueryItem(name: "metadataHeaders", value: "Reply-To"),
        URLQueryItem(name: "metadataHeaders", value: "Subject"),
      ]
      + Self.recipientHeaderNames.map {
        URLQueryItem(name: "metadataHeaders", value: $0)
      }
    guard let url = components?.url else {
      throw GmailMessageMetadataSyncError.invalidGmailRequest
    }

    let response = try await sendAuthorizedRequest(
      url: url,
      accessToken: accessToken,
      responseType: GmailMessageMetadataResponse.self
    )
    let internalDateMilliseconds = Int64(response.internalDate) ?? 0
    let internalDate = Date(timeIntervalSince1970: TimeInterval(internalDateMilliseconds) / 1_000)
    let subject = response.payload?.headers.first {
      $0.name.caseInsensitiveCompare("Subject") == .orderedSame
    }?.value

    return GmailMessageMetadata(
      categoryId: nil,
      from: response.payload?.headers.first {
        $0.name.caseInsensitiveCompare("From") == .orderedSame
      }?.value,
      isHistorical: internalDate <= categorizationBoundary,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      providerInternalDateMilliseconds: internalDateMilliseconds,
      providerLabelIds: response.labelIds ?? [],
      providerMessageId: response.id,
      providerThreadId: response.threadId,
      replyTo: response.payload?.headers.first {
        $0.name.caseInsensitiveCompare("Reply-To") == .orderedSame
      }?.value,
      snippet: response.snippet,
      stableProviderMessageId: "gmail:\(connection.providerAccountIdentifier):\(response.id)",
      subject: subject?.isEmpty == false ? subject! : "(No subject)",
      recipientHeaders: recipientHeaders(in: response),
      rfcMessageId: response.payload?.headers.first {
        $0.name.caseInsensitiveCompare("Message-ID") == .orderedSame
      }?.value
    )
  }

  private func recipientHeaders(in response: GmailMessageMetadataResponse) -> [String]? {
    response.payload?.headers.filter { header in
      Self.recipientHeaderNames.contains {
        header.name.caseInsensitiveCompare($0) == .orderedSame
      }
    }.map(\.value)
  }

  private func sendAuthorizedRequest<Response: Decodable>(
    url: URL,
    accessToken: String,
    responseType: Response.Type
  ) async throws -> Response {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      if (response as? HTTPURLResponse)?.statusCode == 404,
        url.path.hasSuffix("/users/me/history")
      {
        throw GmailMessageMetadataSyncError.expiredGmailHistoryId
      }
      if url.path.hasSuffix("/users/me/messages"),
        url.query?.contains("pageToken=") == true,
        let error = try? JSONDecoder().decode(GmailAPIErrorResponse.self, from: data),
        error.error.message.localizedCaseInsensitiveContains("page token")
      {
        throw GmailMessageMetadataSyncError.invalidGmailPageToken
      }
      throw GmailMessageMetadataSyncError.gmailRequestFailed
    }

    return try JSONDecoder().decode(Response.self, from: data)
  }

  private func headerValue(_ value: String) throws -> String {
    guard !value.unicodeScalars.contains(where: { $0.value == 0x0A || $0.value == 0x0D }) else {
      throw GmailMessageMetadataSyncError.invalidMessageHeader
    }
    return value
  }

  private func encodedHeaderValue(_ value: String) throws -> String {
    let value = try headerValue(value)
    guard value.unicodeScalars.contains(where: { $0.value > 127 }) else {
      return value
    }
    return "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
  }

  private func mailboxHeaderValue(_ value: String) throws -> String {
    let value = try headerValue(value)
    return try mailboxValues(in: value)
      .map { try encodedMailboxHeaderValue($0) }
      .joined(separator: ", ")
  }

  private func mailboxValues(in value: String) -> [String] {
    var mailboxes: [String] = []
    var mailbox = ""
    var isEscaped = false
    var isQuoted = false
    var angleBracketDepth = 0

    for character in value {
      if isEscaped {
        mailbox.append(character)
        isEscaped = false
        continue
      }

      if character == "\\" && isQuoted {
        mailbox.append(character)
        isEscaped = true
        continue
      }

      switch character {
      case "\"":
        isQuoted.toggle()
      case "<":
        angleBracketDepth += 1
      case ">":
        angleBracketDepth = max(0, angleBracketDepth - 1)
      case "," where !isQuoted && angleBracketDepth == 0:
        mailboxes.append(mailbox)
        mailbox = ""
        continue
      default:
        break
      }

      mailbox.append(character)
    }

    mailboxes.append(mailbox)
    return mailboxes
  }

  private func encodedMailboxHeaderValue(_ value: String) throws -> String {
    let value = value.trimmingCharacters(in: .whitespaces)
    guard let addressStart = value.lastIndex(of: "<"), value.hasSuffix(">") else {
      return value
    }
    let displayName = value[..<addressStart].trimmingCharacters(in: .whitespaces)
    guard !displayName.isEmpty else {
      return String(value[addressStart...])
    }
    return "\(try encodedHeaderValue(displayName)) \(value[addressStart...])"
  }

  private func sendAuthorizedRequest(
    url: URL,
    accessToken: String,
    method: String,
    body: Data? = nil
  ) async throws {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    if body != nil {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let (_, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailMessageMetadataSyncError.gmailRequestFailed
    }
  }

  private func sortedMessages(
    _ messages: [GmailMessageMetadata],
    preservingExistingStateFrom existingMessagesByStableId: [String: GmailMessageMetadata]
  ) -> [GmailMessageMetadata] {
    messages
      .map { message in
        guard let existingMessage = existingMessagesByStableId[message.stableProviderMessageId]
        else {
          return message
        }

        return message.preservingCategoryStateAndHistoricalBoundary(from: existingMessage)
      }
      .sorted {
        if $0.providerInternalDateMilliseconds == $1.providerInternalDateMilliseconds {
          return $0.providerMessageId < $1.providerMessageId
        }
        return $0.providerInternalDateMilliseconds > $1.providerInternalDateMilliseconds
      }
  }

  private func mergedMessages(
    _ messages: [GmailMessageMetadata],
    with existingMessages: [GmailMessageMetadata],
    replacingAll: Bool = false
  ) -> [GmailMessageMetadata] {
    guard !replacingAll else { return messages }
    var messagesByStableId = Dictionary(
      uniqueKeysWithValues: existingMessages.map { ($0.stableProviderMessageId, $0) }
    )
    for message in messages {
      messagesByStableId[message.stableProviderMessageId] = message
    }
    return messagesByStableId.values.sorted {
      if $0.providerInternalDateMilliseconds == $1.providerInternalDateMilliseconds {
        return $0.providerMessageId < $1.providerMessageId
      }
      return $0.providerInternalDateMilliseconds > $1.providerInternalDateMilliseconds
    }
  }

  private func historicalCutoffMilliseconds(
    connection: GmailProviderConnectionStatus,
    hasLocalMetadata: Bool
  ) -> Int64 {
    hasLocalMetadata ? connection.connectedAt : connection.updatedAt
  }

  private func historicalCutoff(milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
  }

  private func inboxMessages(
    _ messages: [GmailMessageMetadata]
  ) -> [GmailMessageMetadata] {
    messages.filter { $0.providerLabelIds?.contains("INBOX") ?? true }
  }

  private func merging(
    _ categorizedMessages: [GmailMessageMetadata],
    into messages: [GmailMessageMetadata]
  ) -> [GmailMessageMetadata] {
    let categorizedMessagesByStableId = Dictionary(
      uniqueKeysWithValues: categorizedMessages.map { ($0.stableProviderMessageId, $0) }
    )
    return messages.map {
      categorizedMessagesByStableId[$0.stableProviderMessageId] ?? $0
    }
  }

  private func refreshedTokens(
    _ tokens: GmailProviderTokens,
    persist: Bool = true,
    productAccountId: String,
    providerAccountIdentifier: String
  ) async throws -> GmailProviderTokens {
    guard let oauthClientId, !oauthClientId.isEmpty else {
      throw GmailMessageMetadataSyncError.missingOAuthClientId
    }

    var request = URLRequest(url: tokenRefreshURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formURLEncodedBody([
      "client_id": oauthClientId,
      "grant_type": "refresh_token",
      "refresh_token": tokens.refreshToken,
    ])

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailMessageMetadataSyncError.refreshTokenRejected
    }

    let tokenResponse = try JSONDecoder().decode(GmailRefreshTokenResponse.self, from: data)
    guard !tokenResponse.accessToken.isEmpty else {
      throw GmailMessageMetadataSyncError.refreshTokenRejected
    }

    let refreshedTokens = GmailProviderTokens(
      accessToken: tokenResponse.accessToken,
      refreshToken: tokens.refreshToken,
      idToken: tokenResponse.idToken ?? tokens.idToken
    )
    if persist {
      try tokenStore.save(
        refreshedTokens,
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      )
    }
    return refreshedTokens
  }

  private func validateRefreshedToken(
    _ accessToken: String,
    matches connection: GmailProviderConnectionStatus,
    requiredScopes: Set<String>? = nil
  ) async throws {
    var components = URLComponents(url: tokenInfoURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "access_token", value: accessToken)
    ]
    guard let url = components?.url else {
      throw GmailMessageMetadataSyncError.invalidGmailRequest
    }

    let (data, response) = try await session.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailMessageMetadataSyncError.refreshedTokenAccountMismatch
    }

    let tokenInfo = try JSONDecoder().decode(GmailTokenInfoResponse.self, from: data)
    guard let subject = tokenInfo.sub, subject == connection.providerAccountIdentifier else {
      throw GmailMessageMetadataSyncError.refreshedTokenAccountMismatch
    }
    if let email = tokenInfo.email, !email.isEmpty {
      guard email.caseInsensitiveCompare(connection.emailAddress) == .orderedSame else {
        throw GmailMessageMetadataSyncError.refreshedTokenAccountMismatch
      }
    }
    if let requiredScopes {
      guard !tokenInfo.scopes.isDisjoint(with: requiredScopes) else {
        throw GmailMessageMetadataSyncError.insufficientGmailScope
      }
    }
  }

  private func formURLEncodedBody(_ fields: [String: String]) -> Data {
    fields
      .map { key, value in
        "\(formURLEncode(key))=\(formURLEncode(value))"
      }
      .joined(separator: "&")
      .data(using: .utf8) ?? Data()
  }

  private func formURLEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}

enum GmailMessageMetadataSyncError: LocalizedError, Equatable {
  case expiredGmailHistoryId
  case invalidGmailPageToken
  case invalidMessageHeader
  case gmailRequestFailed
  case invalidGmailRequest
  case insufficientGmailScope
  case missingLocalGmailTokens
  case missingOAuthClientId
  case refreshedTokenAccountMismatch
  case refreshTokenRejected
  case staleLocalConnection

  var errorDescription: String? {
    switch self {
    case .expiredGmailHistoryId:
      return "The Gmail history cursor expired."
    case .invalidGmailPageToken:
      return "The saved Gmail message page token is invalid."
    case .invalidMessageHeader:
      return "Message recipients and subjects cannot contain line breaks."
    case .gmailRequestFailed:
      return "Gmail message metadata sync failed."
    case .invalidGmailRequest:
      return "Gmail message metadata request could not be created."
    case .insufficientGmailScope:
      return "Reconnect Gmail with permission to send and manage mail."
    case .missingLocalGmailTokens:
      return "Gmail is connected on the backend, but this device has no local Gmail tokens."
    case .missingOAuthClientId:
      return "Gmail OAuth client id is not configured."
    case .refreshedTokenAccountMismatch:
      return "Local Gmail tokens belong to a different Google account."
    case .refreshTokenRejected:
      return "Gmail did not refresh local mail access for this account."
    case .staleLocalConnection:
      return "The Gmail connection changed while mailbox sync was running."
    }
  }
}

private struct GmailAPIErrorResponse: Decodable {
  let error: GmailAPIError
}

private struct GmailAPIError: Decodable {
  let message: String
}

extension GmailInboxThread {
  static func group(_ messages: [GmailMessageMetadata]) -> [GmailInboxThread] {
    Dictionary(grouping: messages, by: \.providerThreadId)
      .map { providerThreadId, threadMessages in
        let sortedMessages = threadMessages.sorted {
          if $0.providerInternalDateMilliseconds == $1.providerInternalDateMilliseconds {
            return $0.providerMessageId < $1.providerMessageId
          }
          return $0.providerInternalDateMilliseconds > $1.providerInternalDateMilliseconds
        }
        return GmailInboxThread(
          latestMessage: sortedMessages[0],
          messages: sortedMessages,
          providerThreadId: providerThreadId
        )
      }
      .sorted {
        if $0.latestMessage.providerInternalDateMilliseconds
          == $1.latestMessage.providerInternalDateMilliseconds
        {
          return $0.providerThreadId < $1.providerThreadId
        }
        return $0.latestMessage.providerInternalDateMilliseconds
          > $1.latestMessage.providerInternalDateMilliseconds
      }
  }
}

extension GmailMessageMetadata {
  fileprivate func preservingHistoricalBoundary(
    from existingMessage: GmailMessageMetadata
  ) -> GmailMessageMetadata {
    GmailMessageMetadata(
      categoryId: categoryId,
      from: from,
      isHistorical: existingMessage.isHistorical,
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
      rfcMessageId: rfcMessageId
    )
  }

  fileprivate func preservingCategoryStateAndHistoricalBoundary(
    from existingMessage: GmailMessageMetadata
  ) -> GmailMessageMetadata {
    GmailMessageMetadata(
      categoryId: existingMessage.categoryId,
      from: from,
      isHistorical: existingMessage.isHistorical,
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
      rfcMessageId: rfcMessageId
    )
  }
}

private struct GmailListMessagesResponse: Decodable {
  let messages: [GmailListedMessage]?
  let nextPageToken: String?
}

private struct GmailListHistoryResponse: Decodable {
  let history: [GmailHistoryRecord]?
  let nextPageToken: String?
}

private struct GmailInboxHistoryChanges {
  let addedMessageIds: Set<String>
  let deletedMessageIds: Set<String>
  let removedFromInboxMessageIds: Set<String>
  let stateChangedMessageIds: Set<String>

  init(
    addedMessageIds: Set<String>,
    deletedMessageIds: Set<String>,
    removedFromInboxMessageIds: Set<String>,
    stateChangedMessageIds: Set<String>
  ) {
    self.addedMessageIds =
      addedMessageIds
      .subtracting(deletedMessageIds)
      .subtracting(removedFromInboxMessageIds)
    self.deletedMessageIds = deletedMessageIds
    self.removedFromInboxMessageIds = removedFromInboxMessageIds
    self.stateChangedMessageIds = stateChangedMessageIds
  }
}

private struct GmailInboxHistoryChangesAccumulator {
  private var addedMessageIds: Set<String> = []
  private var deletedMessageIds: Set<String> = []
  private var historyAddedMessageIds: Set<String> = []
  private var removedFromInboxMessageIds: Set<String> = []
  private var stateChangedMessageIds: Set<String> = []

  var result: GmailInboxHistoryChanges {
    GmailInboxHistoryChanges(
      addedMessageIds: addedMessageIds,
      deletedMessageIds: deletedMessageIds,
      removedFromInboxMessageIds: removedFromInboxMessageIds,
      stateChangedMessageIds: stateChangedMessageIds
    )
  }

  mutating func apply(_ record: GmailHistoryRecord) {
    for addition in record.messagesAdded ?? [] {
      if addition.message.labelIds?.contains("INBOX") != false {
        addedMessageIds.insert(addition.message.id)
        historyAddedMessageIds.insert(addition.message.id)
      }
      deletedMessageIds.remove(addition.message.id)
      removedFromInboxMessageIds.remove(addition.message.id)
    }
    for removal in record.labelsRemoved ?? [] {
      stateChangedMessageIds.insert(removal.message.id)
      if removal.labelIds.contains("INBOX") {
        removedFromInboxMessageIds.insert(removal.message.id)
        addedMessageIds.remove(removal.message.id)
      }
    }
    for addition in record.labelsAdded ?? [] {
      stateChangedMessageIds.insert(addition.message.id)
      if addition.labelIds.contains("INBOX") {
        if historyAddedMessageIds.contains(addition.message.id) {
          addedMessageIds.insert(addition.message.id)
        }
        deletedMessageIds.remove(addition.message.id)
        removedFromInboxMessageIds.remove(addition.message.id)
      }
    }
    for deletion in record.messagesDeleted ?? [] {
      deletedMessageIds.insert(deletion.message.id)
      removedFromInboxMessageIds.remove(deletion.message.id)
      stateChangedMessageIds.remove(deletion.message.id)
      addedMessageIds.remove(deletion.message.id)
      historyAddedMessageIds.remove(deletion.message.id)
    }
  }
}

private struct GmailHistoryRecord: Decodable {
  let id: String?
  let labelsAdded: [GmailHistoryLabelChange]?
  let labelsRemoved: [GmailHistoryLabelChange]?
  let messagesAdded: [GmailHistoryMessageChange]?
  let messagesDeleted: [GmailHistoryMessageChange]?
}

private struct GmailHistoryLabelChange: Decodable {
  let labelIds: [String]
  let message: GmailHistoryMessage
}

private struct GmailHistoryMessageChange: Decodable {
  let message: GmailHistoryMessage
}

private struct GmailHistoryMessage: Decodable {
  let id: String
  let labelIds: [String]?
}

private struct GmailListedMessage: Decodable {
  let id: String
}

private struct GmailMessageMetadataResponse: Decodable {
  let id: String
  let internalDate: String
  let labelIds: [String]?
  let payload: GmailMessagePayload?
  let snippet: String
  let threadId: String
}

private struct GmailMessagePayload: Decodable {
  let headers: [GmailMessageHeader]
}

private struct GmailMessageHeader: Decodable {
  let name: String
  let value: String
}

private struct GmailRefreshTokenResponse: Decodable {
  let accessToken: String
  let idToken: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case idToken = "id_token"
  }
}

private struct GmailTokenInfoResponse: Decodable {
  let email: String?
  let scope: String?
  let sub: String?

  var scopes: Set<String> {
    Set((scope ?? "").split(separator: " ").map(String.init))
  }
}
