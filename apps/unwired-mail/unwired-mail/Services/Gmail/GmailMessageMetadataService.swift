import Foundation
import SwiftData

// swiftlint:disable file_length type_body_length

struct GmailMessageMetadata: Codable, Equatable, Identifiable {
  var id: StableProviderMessageIdentity {
    stableIdentity
  }

  let categoryId: String?
  let from: String?
  var hasAttachments: Bool? = .none
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
  var bccRecipients: [String]? = .none
  var calendarInvitation: CalendarInvitationDescriptor? = .none
  let rfcMessageId: String?
  var categoryIds: [String]? = .none
  var unsubscribeSuggestion: UnsubscribeSuggestion? = .none

  var messageCategoryIds: [String] {
    Array(Set([categoryId].compactMap { $0 } + (categoryIds ?? []))).sorted()
  }
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
  let categorizedMessageCount: Int
  let hasInitialMailboxAvailability: Bool
  let historyIsExpired: Bool
  let hasUnlistedNewMessages: Bool
  let historicalMetadataBackfillCanResume: Bool
  let historicalMetadataBackfillIsComplete: Bool
  let messages: [GmailMessageMetadata]
  let newMessageIds: Set<String>?
  let threads: [GmailInboxThread]

  init(
    categorizedMessageCount: Int = 0,
    hasInitialMailboxAvailability: Bool = true,
    historyIsExpired: Bool = false,
    hasUnlistedNewMessages: Bool = false,
    historicalMetadataBackfillCanResume: Bool = true,
    historicalMetadataBackfillIsComplete: Bool = true,
    messages: [GmailMessageMetadata],
    newMessageIds: Set<String>? = nil,
    threads: [GmailInboxThread]
  ) {
    self.categorizedMessageCount = categorizedMessageCount
    self.hasInitialMailboxAvailability = hasInitialMailboxAvailability
    self.historyIsExpired = historyIsExpired
    self.hasUnlistedNewMessages = hasUnlistedNewMessages
    self.historicalMetadataBackfillCanResume = historicalMetadataBackfillCanResume
    self.historicalMetadataBackfillIsComplete = historicalMetadataBackfillIsComplete
    self.messages = messages
    self.newMessageIds = newMessageIds
    self.threads = threads
  }
}

extension GmailMetadataSyncResult {
  func projected(to collection: MailboxMessageCollection) -> GmailMetadataSyncResult {
    let observedMessages = Dictionary(
      (threads.flatMap(\.messages) + messages).map {
        ($0.stableProviderMessageId, $0)
      },
      uniquingKeysWith: { first, _ in first }
    ).values
    let visibleMessages =
      observedMessages
      .filter {
        collection.contains(providerStateIds: $0.providerLabelIds, isSnoozed: false)
      }
      .sorted(by: Self.messagesAreOrdered)
    let visibleThreadIds = Set(visibleMessages.map(\.providerThreadId))
    let visibleThreads = GmailInboxThread.group(Array(observedMessages))
      .filter { visibleThreadIds.contains($0.providerThreadId) }
    return GmailMetadataSyncResult(
      categorizedMessageCount: categorizedMessageCount,
      hasInitialMailboxAvailability: hasInitialMailboxAvailability,
      historyIsExpired: historyIsExpired,
      hasUnlistedNewMessages: hasUnlistedNewMessages,
      historicalMetadataBackfillCanResume: historicalMetadataBackfillCanResume,
      historicalMetadataBackfillIsComplete: historicalMetadataBackfillIsComplete,
      messages: visibleMessages,
      newMessageIds: newMessageIds,
      threads: visibleThreads
    )
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

private struct GmailSyncTokens {
  let providerTokens: GmailProviderTokens
  let usedLegacyTokens: Bool

  var accessToken: String {
    providerTokens.accessToken
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

  func loadInboxThreadMessages(
    additionalProviderMessageIds: Set<String>,
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

enum GmailMessageMetadataStoreError: LocalizedError {
  case inboxIndexMigrationPending

  var errorDescription: String? {
    switch self {
    case .inboxIndexMigrationPending:
      "Preparing cached Gmail Inbox metadata."
    }
  }
}

extension GmailMessageMetadataPersisting {
  func loadInboxThreadMessages(
    additionalProviderMessageIds: Set<String>,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> [GmailMessageMetadata] {
    let messages = try loadMessages(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    let inboxThreadIds = Set(
      messages
        .filter {
          ($0.providerLabelIds?.contains("INBOX") ?? true)
            || additionalProviderMessageIds.contains($0.providerMessageId)
        }
        .map(\.providerThreadId)
    )
    return messages.filter { inboxThreadIds.contains($0.providerThreadId) }
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

  func loadInboxProjectionCandidates(
    additionalProviderMessageIds: Set<String>,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult

  func loadProviderMailboxes(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> [ProviderMailbox]

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

  func setCategories(
    _ categoryIds: [String],
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
  func loadInboxProjectionCandidates(
    additionalProviderMessageIds _: Set<String>,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    try await loadMailbox(.role(.inbox), connection: connection, session: session)
  }

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    try await loadInbox(connection: connection, session: session)
      .projected(to: collection)
  }

  func loadProviderMailboxes(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> [ProviderMailbox] {
    let result = try await loadMailbox(.allObserved, connection: connection, session: session)
    return MailboxMessageCollection.providerMailboxIds(
      in: result.messages.map {
        $0.mailboxMetadata(connectionId: $0.mailboxConnectionId)
      }
    ).map { ProviderMailbox(id: $0, title: $0) }
  }

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
  case move(sourceProviderMailboxId: String, targetProviderMailboxId: String)
  case notSpam
  case restore
  case spam
  case star
  case unstar
}

struct GmailOutgoingMessage: Equatable {
  let bccRecipients: String?
  let body: String
  let ccRecipients: String?
  let htmlBody: String?
  let recipient: String
  let requestsReadReceipt: Bool
  let rfcMessageId: String?
  let subject: String
  let inReplyTo: String?
  let threadId: String?

  init(
    body: String,
    recipient: String,
    subject: String,
    htmlBody: String? = nil,
    ccRecipients: String? = nil,
    bccRecipients: String? = nil,
    inReplyTo: String? = nil,
    threadId: String? = nil,
    rfcMessageId: String? = nil,
    requestsReadReceipt: Bool = false
  ) {
    self.bccRecipients = bccRecipients
    self.body = body
    self.ccRecipients = ccRecipients
    self.htmlBody = htmlBody
    self.recipient = recipient
    self.requestsReadReceipt = requestsReadReceipt
    self.rfcMessageId = rfcMessageId
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
  static let currentMetadataIndexVersion = 2

  @Attribute(.unique) var storageKey: String
  var encodedMessage: Data
  var isInboxVisible: Bool = false
  var metadataIndexVersion: Int = 0
  var productAccountId: String
  var pendingRemovalScanId: String?
  var providerAccountIdentifier: String
  var providerThreadId: String = ""
  var stableProviderMessageId: String

  init(
    encodedMessage: Data,
    isInboxVisible: Bool,
    productAccountId: String,
    providerAccountIdentifier: String,
    providerThreadId: String,
    stableProviderMessageId: String,
    storageKey: String
  ) {
    self.storageKey = storageKey
    self.encodedMessage = encodedMessage
    self.isInboxVisible = isInboxVisible
    metadataIndexVersion = Self.currentMetadataIndexVersion
    self.productAccountId = productAccountId
    self.providerAccountIdentifier = providerAccountIdentifier
    self.providerThreadId = providerThreadId
    self.stableProviderMessageId = stableProviderMessageId
    pendingRemovalScanId = nil
  }

  func message() throws -> GmailMessageMetadata {
    try JSONDecoder().decode(GmailMessageMetadata.self, from: encodedMessage)
  }

  func update(from message: GmailMessageMetadata) throws {
    encodedMessage = try JSONEncoder().encode(message)
    isInboxVisible = message.providerLabelIds?.contains("INBOX") ?? true
    metadataIndexVersion = Self.currentMetadataIndexVersion
    providerThreadId = message.providerThreadId
  }
}

@Model
final class DurableGmailThreadLookupRecord {
  @Attribute(.unique) var storageKey: String
  var encodedInboxMessageStorageKeys: Data
  var encodedMessageStorageKeys: Data
  var productAccountId: String
  var providerAccountIdentifier: String
  var providerThreadId: String

  init(
    inboxMessageStorageKeys: Set<String>,
    messageStorageKeys: Set<String>,
    productAccountId: String,
    providerAccountIdentifier: String,
    providerThreadId: String,
    storageKey: String
  ) throws {
    self.storageKey = storageKey
    self.productAccountId = productAccountId
    self.providerAccountIdentifier = providerAccountIdentifier
    self.providerThreadId = providerThreadId
    encodedInboxMessageStorageKeys = Data()
    encodedMessageStorageKeys = Data()
    try update(
      inboxMessageStorageKeys: inboxMessageStorageKeys,
      messageStorageKeys: messageStorageKeys
    )
  }

  func inboxMessageStorageKeys() throws -> Set<String> {
    Set(try JSONDecoder().decode([String].self, from: encodedInboxMessageStorageKeys))
  }

  func messageStorageKeys() throws -> Set<String> {
    Set(try JSONDecoder().decode([String].self, from: encodedMessageStorageKeys))
  }

  func update(
    inboxMessageStorageKeys: Set<String>,
    messageStorageKeys: Set<String>
  ) throws {
    encodedInboxMessageStorageKeys = try JSONEncoder().encode(
      inboxMessageStorageKeys.sorted()
    )
    encodedMessageStorageKeys = try JSONEncoder().encode(messageStorageKeys.sorted())
  }
}

@Model
final class DurableGmailInboxLookupRecord {
  @Attribute(.unique) var storageKey: String
  var encodedThreadStorageKeys: Data
  var productAccountId: String
  var providerAccountIdentifier: String

  init(
    productAccountId: String,
    providerAccountIdentifier: String,
    storageKey: String,
    threadStorageKeys: Set<String>
  ) throws {
    self.storageKey = storageKey
    self.productAccountId = productAccountId
    self.providerAccountIdentifier = providerAccountIdentifier
    encodedThreadStorageKeys = Data()
    try update(threadStorageKeys: threadStorageKeys)
  }

  func threadStorageKeys() throws -> Set<String> {
    Set(try JSONDecoder().decode([String].self, from: encodedThreadStorageKeys))
  }

  func update(threadStorageKeys: Set<String>) throws {
    encodedThreadStorageKeys = try JSONEncoder().encode(threadStorageKeys.sorted())
  }
}

private struct GmailThreadLookupMutation {
  let messageStorageKey: String
  let newIsInboxVisible: Bool?
  let newProviderThreadId: String?
  let oldIsInboxVisible: Bool?
  let oldProviderThreadId: String?
}

private struct GmailThreadLookupState {
  var inboxMessageStorageKeys: Set<String>
  var messageStorageKeys: Set<String>
  let providerThreadId: String
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
  private static let threadFetchBatchSize = 500

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
    let threadLookupDescriptor = FetchDescriptor<DurableGmailThreadLookupRecord>(
      predicate: #Predicate { $0.productAccountId == productAccountId }
    )
    for lookup in try context.fetch(threadLookupDescriptor) {
      context.delete(lookup)
    }
    let inboxLookupDescriptor = FetchDescriptor<DurableGmailInboxLookupRecord>(
      predicate: #Predicate { $0.productAccountId == productAccountId }
    )
    for lookup in try context.fetch(inboxLookupDescriptor) {
      context.delete(lookup)
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
    for lookup in try fetchThreadLookups(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      context: context
    ) {
      context.delete(lookup)
    }
    if let inboxLookup = try fetchInboxLookup(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      context: context
    ) {
      context.delete(inboxLookup)
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
    try migrateLegacyMessagesIfNeeded(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    let context = try makeContext()
    let records = try fetchRecords(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      context: context
    )
    var lookupMutations: [GmailThreadLookupMutation] = []
    let messages = try records.map { record in
      let message = try record.message()
      if record.metadataIndexVersion < DurableGmailMessageMetadataRecord.currentMetadataIndexVersion
      {
        if record.metadataIndexVersion < 1 {
          try record.update(from: message)
        } else {
          record.metadataIndexVersion =
            DurableGmailMessageMetadataRecord.currentMetadataIndexVersion
        }
        lookupMutations.append(
          GmailThreadLookupMutation(
            messageStorageKey: record.storageKey,
            newIsInboxVisible: record.isInboxVisible,
            newProviderThreadId: record.providerThreadId,
            oldIsInboxVisible: nil,
            oldProviderThreadId: nil
          )
        )
      }
      return message
    }
    if !lookupMutations.isEmpty {
      try applyThreadLookupMutations(
        lookupMutations,
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier,
        context: context
      )
      try context.save()
    }
    return messages.sorted(by: Self.messagesAreOrdered)
  }

  // swiftlint:disable:next function_body_length
  func loadInboxThreadMessages(
    additionalProviderMessageIds: Set<String>,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> [GmailMessageMetadata] {
    try migrateLegacyMessagesIfNeeded(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    let context = try makeContext()
    guard
      try rebuildOneInboxIndexBatch(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier,
        context: context
      )
    else {
      throw GmailMessageMetadataStoreError.inboxIndexMigrationPending
    }
    let inboxLookup = try fetchInboxLookup(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      context: context
    )
    var threadStorageKeys = try inboxLookup?.threadStorageKeys() ?? []
    let stableProviderMessageIds = additionalProviderMessageIds.map {
      "gmail:\(providerAccountIdentifier):\($0)"
    }
    let additionalRecords: [DurableGmailMessageMetadataRecord] =
      if stableProviderMessageIds.isEmpty {
        []
      } else {
        try fetchRecords(
          productAccountId: productAccountId,
          providerAccountIdentifier: providerAccountIdentifier,
          stableProviderMessageIds: Set(stableProviderMessageIds),
          context: context
        )
      }
    for record in additionalRecords {
      threadStorageKeys.insert(
        Self.threadStorageKey(
          productAccountId: productAccountId,
          providerAccountIdentifier: providerAccountIdentifier,
          providerThreadId: record.providerThreadId
        )
      )
    }
    let threadLookups = try fetchThreadLookups(
      storageKeys: threadStorageKeys,
      context: context
    )
    let messageStorageKeys = try threadLookups.reduce(into: Set<String>()) {
      $0.formUnion(try $1.messageStorageKeys())
    }
    let visibleRecords = try fetchRecords(storageKeys: messageStorageKeys, context: context)
    return
      try visibleRecords
      .map { try $0.message() }
      .sorted(by: Self.messagesAreOrdered)
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
    var lookupMutations: [GmailThreadLookupMutation] = []
    for message in messages {
      if let record = existingByStableId[message.stableProviderMessageId] {
        let oldIsInboxVisible = record.isInboxVisible
        let oldProviderThreadId = record.providerThreadId
        try record.update(
          from: message.preservingHistoricalBoundary(from: try record.message())
        )
        record.pendingRemovalScanId = nil
        lookupMutations.append(
          GmailThreadLookupMutation(
            messageStorageKey: record.storageKey,
            newIsInboxVisible: record.isInboxVisible,
            newProviderThreadId: record.providerThreadId,
            oldIsInboxVisible: oldIsInboxVisible,
            oldProviderThreadId: oldProviderThreadId
          )
        )
      } else {
        let record = DurableGmailMessageMetadataRecord(
          encodedMessage: try JSONEncoder().encode(message),
          isInboxVisible: message.providerLabelIds?.contains("INBOX") ?? true,
          productAccountId: productAccountId,
          providerAccountIdentifier: providerAccountIdentifier,
          providerThreadId: message.providerThreadId,
          stableProviderMessageId: message.stableProviderMessageId,
          storageKey: Self.storageKey(
            productAccountId: productAccountId,
            providerAccountIdentifier: providerAccountIdentifier,
            stableProviderMessageId: message.stableProviderMessageId
          )
        )
        context.insert(record)
        lookupMutations.append(
          GmailThreadLookupMutation(
            messageStorageKey: record.storageKey,
            newIsInboxVisible: record.isInboxVisible,
            newProviderThreadId: record.providerThreadId,
            oldIsInboxVisible: nil,
            oldProviderThreadId: nil
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
        lookupMutations.append(
          GmailThreadLookupMutation(
            messageStorageKey: record.storageKey,
            newIsInboxVisible: nil,
            newProviderThreadId: nil,
            oldIsInboxVisible: record.isInboxVisible,
            oldProviderThreadId: record.providerThreadId
          )
        )
        context.delete(record)
      }
    }
    try applyThreadLookupMutations(
      lookupMutations,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      context: context
    )
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

  // swiftlint:disable:next function_body_length
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
    var lookupMutations: [GmailThreadLookupMutation] = []

    for message in messages {
      if let record = existingByStableId.removeValue(forKey: message.stableProviderMessageId) {
        let oldIsInboxVisible = record.isInboxVisible
        let oldProviderThreadId = record.providerThreadId
        try record.update(from: message)
        lookupMutations.append(
          GmailThreadLookupMutation(
            messageStorageKey: record.storageKey,
            newIsInboxVisible: record.isInboxVisible,
            newProviderThreadId: record.providerThreadId,
            oldIsInboxVisible: oldIsInboxVisible,
            oldProviderThreadId: oldProviderThreadId
          )
        )
      } else {
        let record = DurableGmailMessageMetadataRecord(
          encodedMessage: try JSONEncoder().encode(message),
          isInboxVisible: message.providerLabelIds?.contains("INBOX") ?? true,
          productAccountId: productAccountId,
          providerAccountIdentifier: providerAccountIdentifier,
          providerThreadId: message.providerThreadId,
          stableProviderMessageId: message.stableProviderMessageId,
          storageKey: Self.storageKey(
            productAccountId: productAccountId,
            providerAccountIdentifier: providerAccountIdentifier,
            stableProviderMessageId: message.stableProviderMessageId
          )
        )
        context.insert(record)
        lookupMutations.append(
          GmailThreadLookupMutation(
            messageStorageKey: record.storageKey,
            newIsInboxVisible: record.isInboxVisible,
            newProviderThreadId: record.providerThreadId,
            oldIsInboxVisible: nil,
            oldProviderThreadId: nil
          )
        )
      }
    }
    for record in existingByStableId.values {
      lookupMutations.append(
        GmailThreadLookupMutation(
          messageStorageKey: record.storageKey,
          newIsInboxVisible: nil,
          newProviderThreadId: nil,
          oldIsInboxVisible: record.isInboxVisible,
          oldProviderThreadId: record.providerThreadId
        )
      )
      context.delete(record)
    }
    try applyThreadLookupMutations(
      lookupMutations,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      context: context
    )
    try context.save()
  }

  static let schema = Schema([
    DurableGmailMessageMetadataRecord.self,
    DurableGmailThreadLookupRecord.self,
    DurableGmailInboxLookupRecord.self,
    GmailMetadataSyncCheckpointRecord.self,
  ])

  private func makeContext() throws -> ModelContext {
    try ModelContext(containerResult.get())
  }

  private func migrateLegacyMessagesIfNeeded(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    let context = try makeContext()
    var descriptor = FetchDescriptor<DurableGmailMessageMetadataRecord>(
      predicate: #Predicate {
        $0.productAccountId == productAccountId
          && $0.providerAccountIdentifier == providerAccountIdentifier
      }
    )
    descriptor.fetchLimit = 1
    guard try context.fetch(descriptor).isEmpty else { return }
    let legacyMessages = try legacyStore.loadMessages(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    guard !legacyMessages.isEmpty else { return }
    try saveMessages(
      legacyMessages,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    try legacyStore.clearMessages(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
  }

  private func rebuildOneInboxIndexBatch(
    productAccountId: String,
    providerAccountIdentifier: String,
    context: ModelContext
  ) throws -> Bool {
    let currentMetadataIndexVersion =
      DurableGmailMessageMetadataRecord.currentMetadataIndexVersion
    var descriptor = FetchDescriptor<DurableGmailMessageMetadataRecord>(
      predicate: #Predicate {
        $0.productAccountId == productAccountId
          && $0.providerAccountIdentifier == providerAccountIdentifier
          && $0.metadataIndexVersion < currentMetadataIndexVersion
      }
    )
    descriptor.fetchLimit = Self.threadFetchBatchSize
    let records = try context.fetch(descriptor)
    var lookupMutations: [GmailThreadLookupMutation] = []
    for record in records {
      if record.metadataIndexVersion < 1 {
        try record.update(from: record.message())
      } else {
        record.metadataIndexVersion =
          DurableGmailMessageMetadataRecord.currentMetadataIndexVersion
      }
      lookupMutations.append(
        GmailThreadLookupMutation(
          messageStorageKey: record.storageKey,
          newIsInboxVisible: record.isInboxVisible,
          newProviderThreadId: record.providerThreadId,
          oldIsInboxVisible: nil,
          oldProviderThreadId: nil
        )
      )
    }
    if !records.isEmpty {
      try applyThreadLookupMutations(
        lookupMutations,
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier,
        context: context
      )
      try context.save()
    }
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).isEmpty
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
      let storageKeys = Set(
        stableProviderMessageIds.map {
          Self.storageKey(
            productAccountId: productAccountId,
            providerAccountIdentifier: providerAccountIdentifier,
            stableProviderMessageId: $0
          )
        }
      )
      descriptor.predicate = #Predicate {
        storageKeys.contains($0.storageKey)
      }
    }
    return try context.fetch(descriptor)
  }

  private func fetchRecords(
    storageKeys: Set<String>,
    context: ModelContext
  ) throws -> [DurableGmailMessageMetadataRecord] {
    var records: [DurableGmailMessageMetadataRecord] = []
    let sortedStorageKeys = storageKeys.sorted()
    for startIndex in stride(
      from: 0,
      to: sortedStorageKeys.count,
      by: Self.threadFetchBatchSize
    ) {
      let endIndex = min(startIndex + Self.threadFetchBatchSize, sortedStorageKeys.count)
      let batchStorageKeys = Set(sortedStorageKeys[startIndex..<endIndex])
      let descriptor = FetchDescriptor<DurableGmailMessageMetadataRecord>(
        predicate: #Predicate { batchStorageKeys.contains($0.storageKey) }
      )
      records += try context.fetch(descriptor)
    }
    return records
  }

  private func fetchInboxLookup(
    productAccountId: String,
    providerAccountIdentifier: String,
    context: ModelContext
  ) throws -> DurableGmailInboxLookupRecord? {
    let storageKey = Self.checkpointStorageKey(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    var descriptor = FetchDescriptor<DurableGmailInboxLookupRecord>(
      predicate: #Predicate { $0.storageKey == storageKey }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  private func fetchThreadLookups(
    productAccountId: String,
    providerAccountIdentifier: String,
    context: ModelContext
  ) throws -> [DurableGmailThreadLookupRecord] {
    let descriptor = FetchDescriptor<DurableGmailThreadLookupRecord>(
      predicate: #Predicate {
        $0.productAccountId == productAccountId
          && $0.providerAccountIdentifier == providerAccountIdentifier
      }
    )
    return try context.fetch(descriptor)
  }

  private func fetchThreadLookups(
    storageKeys: Set<String>,
    context: ModelContext
  ) throws -> [DurableGmailThreadLookupRecord] {
    var records: [DurableGmailThreadLookupRecord] = []
    let sortedStorageKeys = storageKeys.sorted()
    for startIndex in stride(
      from: 0,
      to: sortedStorageKeys.count,
      by: Self.threadFetchBatchSize
    ) {
      let endIndex = min(startIndex + Self.threadFetchBatchSize, sortedStorageKeys.count)
      let batchStorageKeys = Set(sortedStorageKeys[startIndex..<endIndex])
      let descriptor = FetchDescriptor<DurableGmailThreadLookupRecord>(
        predicate: #Predicate { batchStorageKeys.contains($0.storageKey) }
      )
      records += try context.fetch(descriptor)
    }
    return records
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func applyThreadLookupMutations(
    _ mutations: [GmailThreadLookupMutation],
    productAccountId: String,
    providerAccountIdentifier: String,
    context: ModelContext
  ) throws {
    guard !mutations.isEmpty else { return }
    var providerThreadIdsByStorageKey: [String: String] = [:]
    for mutation in mutations {
      for providerThreadId in [mutation.oldProviderThreadId, mutation.newProviderThreadId]
        .compactMap({ $0 })
      {
        providerThreadIdsByStorageKey[
          Self.threadStorageKey(
            productAccountId: productAccountId,
            providerAccountIdentifier: providerAccountIdentifier,
            providerThreadId: providerThreadId
          )
        ] = providerThreadId
      }
    }
    let affectedStorageKeys = Set(providerThreadIdsByStorageKey.keys)
    let lookupRecords = try fetchThreadLookups(
      storageKeys: affectedStorageKeys,
      context: context
    )
    var lookupRecordsByStorageKey = Dictionary(
      uniqueKeysWithValues: lookupRecords.map { ($0.storageKey, $0) }
    )
    var statesByStorageKey = try Dictionary(
      uniqueKeysWithValues: lookupRecords.map {
        (
          $0.storageKey,
          GmailThreadLookupState(
            inboxMessageStorageKeys: try $0.inboxMessageStorageKeys(),
            messageStorageKeys: try $0.messageStorageKeys(),
            providerThreadId: $0.providerThreadId
          )
        )
      }
    )
    for mutation in mutations {
      if let oldProviderThreadId = mutation.oldProviderThreadId {
        let storageKey = Self.threadStorageKey(
          productAccountId: productAccountId,
          providerAccountIdentifier: providerAccountIdentifier,
          providerThreadId: oldProviderThreadId
        )
        var state =
          statesByStorageKey[storageKey]
          ?? GmailThreadLookupState(
            inboxMessageStorageKeys: [],
            messageStorageKeys: [],
            providerThreadId: oldProviderThreadId
          )
        state.messageStorageKeys.remove(mutation.messageStorageKey)
        if mutation.oldIsInboxVisible == true {
          state.inboxMessageStorageKeys.remove(mutation.messageStorageKey)
        }
        statesByStorageKey[storageKey] = state
      }
      if let newProviderThreadId = mutation.newProviderThreadId {
        let storageKey = Self.threadStorageKey(
          productAccountId: productAccountId,
          providerAccountIdentifier: providerAccountIdentifier,
          providerThreadId: newProviderThreadId
        )
        var state =
          statesByStorageKey[storageKey]
          ?? GmailThreadLookupState(
            inboxMessageStorageKeys: [],
            messageStorageKeys: [],
            providerThreadId: newProviderThreadId
          )
        state.messageStorageKeys.insert(mutation.messageStorageKey)
        if mutation.newIsInboxVisible == true {
          state.inboxMessageStorageKeys.insert(mutation.messageStorageKey)
        } else {
          state.inboxMessageStorageKeys.remove(mutation.messageStorageKey)
        }
        statesByStorageKey[storageKey] = state
      }
    }

    let inboxLookup = try fetchInboxLookup(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier,
      context: context
    )
    var inboxThreadStorageKeys = try inboxLookup?.threadStorageKeys() ?? []
    for storageKey in affectedStorageKeys {
      guard let state = statesByStorageKey[storageKey], !state.messageStorageKeys.isEmpty else {
        if let lookup = lookupRecordsByStorageKey.removeValue(forKey: storageKey) {
          context.delete(lookup)
        }
        inboxThreadStorageKeys.remove(storageKey)
        continue
      }
      if state.inboxMessageStorageKeys.isEmpty {
        inboxThreadStorageKeys.remove(storageKey)
      } else {
        inboxThreadStorageKeys.insert(storageKey)
      }
      if let lookup = lookupRecordsByStorageKey[storageKey] {
        try lookup.update(
          inboxMessageStorageKeys: state.inboxMessageStorageKeys,
          messageStorageKeys: state.messageStorageKeys
        )
      } else {
        context.insert(
          try DurableGmailThreadLookupRecord(
            inboxMessageStorageKeys: state.inboxMessageStorageKeys,
            messageStorageKeys: state.messageStorageKeys,
            productAccountId: productAccountId,
            providerAccountIdentifier: providerAccountIdentifier,
            providerThreadId: state.providerThreadId,
            storageKey: storageKey
          )
        )
      }
    }
    if let inboxLookup {
      try inboxLookup.update(threadStorageKeys: inboxThreadStorageKeys)
    } else {
      context.insert(
        try DurableGmailInboxLookupRecord(
          productAccountId: productAccountId,
          providerAccountIdentifier: providerAccountIdentifier,
          storageKey: Self.checkpointStorageKey(
            productAccountId: productAccountId,
            providerAccountIdentifier: providerAccountIdentifier
          ),
          threadStorageKeys: inboxThreadStorageKeys
        )
      )
    }
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

  private static func threadStorageKey(
    productAccountId: String,
    providerAccountIdentifier: String,
    providerThreadId: String
  ) -> String {
    [productAccountId, providerAccountIdentifier, providerThreadId]
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
  private static let recipientHeaderNames = ["Cc", "To"]
  private static let bccHeaderName = "Bcc"
  private static let unsubscribeHeaderNames = [
    "List-ID", "List-Unsubscribe", "List-Unsubscribe-Post",
  ]
  private static let metadataHeaderNames =
    recipientHeaderNames + [bccHeaderName] + unsubscribeHeaderNames

  private let categorizer: GmailMessageCategorizing
  private let gmailBaseURL: URL
  private let notificationEligibilityStore: GmailPushEligibilityPersisting
  private let oauthClientId: String?
  private let profileResolver: NotificationProfileResolving
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
    profileResolver: NotificationProfileResolving = LegacyNotificationProfileResolver(),
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
    self.profileResolver = profileResolver
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
    try await loadMailbox(.role(.inbox), connection: connection, session: session)
  }

  func loadInboxProjectionCandidates(
    additionalProviderMessageIds: Set<String>,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    let productAccountId = session.productAccountId
    let providerAccountIdentifier = connection.providerAccountIdentifier
    let messages = try store.loadInboxThreadMessages(
      additionalProviderMessageIds: additionalProviderMessageIds,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    let state = try store.loadSyncState(
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    return GmailMetadataSyncResult(
      hasInitialMailboxAvailability: state != nil || !messages.isEmpty,
      historicalMetadataBackfillCanResume: state != nil,
      historicalMetadataBackfillIsComplete:
        state?.historicalMetadataBackfillIsComplete ?? false,
      messages: messages,
      threads: GmailInboxThread.group(messages)
    )
  }

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    let messages =
      if collection == .role(.inbox) {
        try store.loadInboxThreadMessages(
          additionalProviderMessageIds: [],
          productAccountId: session.productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        )
      } else {
        try store.loadMessages(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        )
      }
    let state = try store.loadSyncState(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    return GmailMetadataSyncResult(
      hasInitialMailboxAvailability: state != nil || !messages.isEmpty,
      historicalMetadataBackfillCanResume: state != nil,
      historicalMetadataBackfillIsComplete:
        state?.historicalMetadataBackfillIsComplete ?? false,
      messages: messages,
      threads: GmailInboxThread.group(messages)
    )
    .projected(to: collection)
  }

  func loadProviderMailboxes(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> [ProviderMailbox] {
    let accessToken = try await authorizedAccessToken(
      connection: connection,
      session: session,
      requiredScopes: [
        "https://mail.google.com/",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.readonly",
      ]
    )
    let response = try await sendAuthorizedRequest(
      url: gmailBaseURL.appendingPathComponent("users/me/labels"),
      accessToken: accessToken,
      responseType: GmailListLabelsResponse.self
    )
    return (response.labels ?? [])
      .filter { MailboxMessageCollection.isProviderMailboxId($0.id) }
      .map { ProviderMailbox(id: $0.id, title: $0.name) }
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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
    let categorizedMessages = try await categorizer.categorizeHistorical(
      messages: messages,
      scope: scope,
      recordScope: try await categoryRecordScope(connection: connection, session: session),
      session: session
    )
    let previousCategoryIdsByMessageId = Dictionary(
      messages.map { ($0.stableProviderMessageId, $0.messageCategoryIds) },
      uniquingKeysWith: { first, _ in first }
    )
    let categorizedMessageCount = categorizedMessages.count { message in
      message.messageCategoryIds
        != previousCategoryIdsByMessageId[message.stableProviderMessageId]
    }
    try store.saveMessages(
      categorizedMessages,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let visibleMessages = inboxMessages(categorizedMessages)
    return GmailMetadataSyncResult(
      categorizedMessageCount: categorizedMessageCount,
      messages: visibleMessages,
      threads: inboxThreads(categorizedMessages)
    )
  }

  private func categoryRecordScope(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileRecordScope {
    try await profileResolver.resolve(
      connectionId: connection.mailboxConnectionId,
      session: session
    ).recordScope
  }

  // swiftlint:disable:next function_body_length
  func syncInbox(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMetadataSyncResult {
    let existingMessages = try store.loadMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let tokens = try await tokensForSync(
      connection: connection,
      deferPersistence: false,
      session: session
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
      recordScope: try await categoryRecordScope(connection: connection, session: session),
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
      threads: inboxThreads(storedMessages)
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
        threads: inboxThreads(messages)
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
        threads: inboxThreads(messages)
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
        recordScope: try await categoryRecordScope(connection: connection, session: session),
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
      threads: inboxThreads(storedMessages)
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
      _ = try await syncInbox(
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
        threads: inboxThreads(storedMessages)
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
      recordScope: try await categoryRecordScope(connection: connection, session: session),
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
        tokens.providerTokens,
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      if tokens.usedLegacyTokens {
        try tokenStore.clearLegacy(productAccountId: session.productAccountId)
      }
    }
    try store.saveMessages(
      fetchedMessages,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    let historicalMetadataBackfillIsComplete =
      try store.loadSyncState(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )?.historicalMetadataBackfillIsComplete ?? false
    let addedMessageIds = inboxHistoryChanges?.addedMessageIds
    let visibleMessages = inboxMessages(fetchedMessages)
    return GmailMetadataSyncResult(
      hasUnlistedNewMessages: addedMessageIds.map {
        !$0.isSubset(of: currentInboxMessageIds)
      } ?? false,
      historicalMetadataBackfillIsComplete: historicalMetadataBackfillIsComplete,
      messages: visibleMessages,
      newMessageIds: addedMessageIds?.intersection(currentInboxMessageIds),
      threads: inboxThreads(fetchedMessages)
    )
  }

  private func tokensForSync(
    connection: GmailProviderConnectionStatus,
    deferPersistence: Bool,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailSyncTokens {
    let scopedTokens = try tokenStore.load(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let legacyTokens =
      try scopedTokens == nil
      ? tokenStore.loadLegacy(productAccountId: session.productAccountId)
      : nil
    guard let storedTokens = scopedTokens ?? legacyTokens else {
      throw GmailMessageMetadataSyncError.missingLocalGmailTokens
    }
    let tokens = try await refreshedTokens(
      storedTokens,
      persist: scopedTokens != nil && !deferPersistence,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    try await validateRefreshedToken(tokens.accessToken, matches: connection)
    if legacyTokens != nil, !deferPersistence {
      try tokenStore.save(
        tokens,
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
      try tokenStore.clearLegacy(productAccountId: session.productAccountId)
    }
    return GmailSyncTokens(
      providerTokens: tokens,
      usedLegacyTokens: legacyTokens != nil
    )
  }

  func refreshProviderTokens(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailProviderTokens {
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
      persist: true,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    try await validateRefreshedToken(tokens.accessToken, matches: connection)
    return tokens
  }

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
    let overriddenMessage = try await categorizer.setCategories(
      categoryIds,
      for: message,
      session: session
    )
    var didReplaceMessage = false
    var persistedMessage = overriddenMessage
    var messages = try store.loadMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: message.providerAccountIdentifier
    ).map { storedMessage in
      guard storedMessage.stableProviderMessageId == message.stableProviderMessageId else {
        return storedMessage
      }
      didReplaceMessage = true
      persistedMessage = storedMessage.assigningCategories(overriddenMessage.messageCategoryIds)
      return persistedMessage
    }
    if !didReplaceMessage {
      messages.append(overriddenMessage)
    }
    try store.saveMessages(
      messages,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: message.providerAccountIdentifier
    )
    return persistedMessage
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
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
          url: url.appendingPathComponent("trash"),
          accessToken: accessToken,
          method: "POST",
          providerActionRequest: true
        )
      case .archive, .markRead, .markUnread, .move, .notSpam, .restore, .spam, .star, .unstar:
        let labels: (add: [String], remove: [String])
        switch action {
        case .archive:
          labels = ([], ["INBOX"])
        case .markRead:
          labels = ([], ["UNREAD"])
        case .markUnread:
          labels = (["UNREAD"], [])
        case .move(let sourceProviderMailboxId, let targetProviderMailboxId):
          labels = ([targetProviderMailboxId], [sourceProviderMailboxId])
        case .notSpam:
          labels = (["INBOX"], ["SPAM"])
        case .restore:
          labels = (["INBOX"], ["TRASH"])
        case .spam:
          labels = (["SPAM"], ["INBOX"])
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
          body: body,
          providerActionRequest: true
        )
      }
    }
  }

  // swiftlint:disable:next function_body_length
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
    ]
    let mimeBody: String
    if let htmlBody = message.htmlBody {
      let boundary = "unwired-alternative-\(UUID().uuidString.lowercased())"
      let encodedHTML = Data(htmlBody.utf8).base64EncodedString(
        options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
      )
      headers.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
      mimeBody = [
        "--\(boundary)",
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: 8bit",
        "",
        message.body,
        "--\(boundary)",
        "Content-Type: text/html; charset=utf-8",
        "Content-Transfer-Encoding: base64",
        "",
        encodedHTML,
        "--\(boundary)--",
      ].joined(separator: "\r\n")
    } else {
      headers.append("Content-Type: text/plain; charset=utf-8")
      headers.append("Content-Transfer-Encoding: 8bit")
      mimeBody = message.body
    }
    if let ccRecipients = message.ccRecipients?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ), !ccRecipients.isEmpty {
      headers.append("Cc: \(try mailboxHeaderValue(ccRecipients))")
    }
    if let bccRecipients = message.bccRecipients?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ), !bccRecipients.isEmpty {
      headers.append("Bcc: \(try mailboxHeaderValue(bccRecipients))")
    }
    if let inReplyTo = message.inReplyTo {
      let replyHeader = try headerValue(inReplyTo)
      headers.append("In-Reply-To: \(replyHeader)")
      headers.append("References: \(replyHeader)")
    }
    if let rfcMessageId = message.rfcMessageId {
      headers.append("Message-ID: \(try headerValue(rfcMessageId))")
    }
    if message.requestsReadReceipt {
      headers.append("Disposition-Notification-To: \(sender)")
    }
    let mimeMessage = (headers + ["", mimeBody]).joined(separator: "\r\n")
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
      body: body,
      providerActionRequest: true
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
      } else {
        queryItems.append(URLQueryItem(name: "includeSpamTrash", value: "true"))
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
      URLQueryItem(name: "maxResults", value: "50"),
      URLQueryItem(name: "includeSpamTrash", value: "true"),
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
        URLQueryItem(name: "startHistoryId", value: sinceHistoryId)
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

  // swiftlint:disable:next function_body_length
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
        URLQueryItem(name: "format", value: "full"),
        URLQueryItem(
          name: "fields",
          value:
            "id,threadId,labelIds,snippet,internalDate,"
            + "payload(body(attachmentId,size),filename,headers,mimeType,partId,"
            + "parts(body(attachmentId,size),filename,headers,mimeType,partId,"
            + "parts(body(attachmentId,size),filename,headers,mimeType,partId,"
            + "parts(body(attachmentId,size),filename,headers,mimeType,partId,"
            + "parts(body(attachmentId,size),filename,headers,mimeType,partId)))))"
        ),
        URLQueryItem(name: "metadataHeaders", value: "From"),
        URLQueryItem(name: "metadataHeaders", value: "Message-ID"),
        URLQueryItem(name: "metadataHeaders", value: "Reply-To"),
        URLQueryItem(name: "metadataHeaders", value: "Subject"),
      ]
      + Self.metadataHeaderNames.map {
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
    let stableProviderMessageId =
      "gmail:\(connection.providerAccountIdentifier):\(response.id)"

    return GmailMessageMetadata(
      categoryId: nil,
      from: response.payload?.headers.first {
        $0.name.caseInsensitiveCompare("From") == .orderedSame
      }?.value,
      hasAttachments: response.payload?.hasAttachments == true ? true : nil,
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
      stableProviderMessageId: stableProviderMessageId,
      subject: subject?.isEmpty == false ? subject! : "(No subject)",
      recipientHeaders: recipientHeaders(in: response),
      bccRecipients: bccRecipients(in: response),
      calendarInvitation: response.calendarInvitation(
        providerMessageIdentity: stableProviderMessageId
      ),
      rfcMessageId: response.payload?.headers.first {
        $0.name.caseInsensitiveCompare("Message-ID") == .orderedSame
      }?.value,
      unsubscribeSuggestion: UnsubscribeSuggestionParser.suggestion(
        headers: response.payload?.headers.map { ($0.name, $0.value) } ?? []
      )
    )
  }

  private func recipientHeaders(in response: GmailMessageMetadataResponse) -> [String]? {
    response.payload?.headers.filter { header in
      Self.recipientHeaderNames.contains {
        header.name.caseInsensitiveCompare($0) == .orderedSame
      }
    }.map(\.value)
  }

  private func bccRecipients(in response: GmailMessageMetadataResponse) -> [String]? {
    response.payload?.headers.filter {
      $0.name.caseInsensitiveCompare(Self.bccHeaderName) == .orderedSame
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
    body: Data? = nil,
    providerActionRequest: Bool = false
  ) async throws {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    if body != nil {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw GmailMessageMetadataSyncError.gmailRequestFailed
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      if providerActionRequest {
        if httpResponse.statusCode == 403, hasRateLimitReason(in: data) {
          throw GmailProviderMailActionError.rateLimitedResponseStatus(httpResponse.statusCode)
        }
        throw GmailProviderMailActionError.responseStatus(httpResponse.statusCode)
      }
      throw GmailMessageMetadataSyncError.gmailRequestFailed
    }
  }

  private func hasRateLimitReason(in data: Data) -> Bool {
    guard
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = payload["error"] as? [String: Any],
      let errors = error["errors"] as? [[String: Any]]
    else {
      return false
    }

    return errors.contains {
      guard let reason = $0["reason"] as? String else { return false }
      return reason == "rateLimitExceeded" || reason == "userRateLimitExceeded"
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

  private func inboxThreads(
    _ messages: [GmailMessageMetadata]
  ) -> [GmailInboxThread] {
    let visibleThreadIds = Set(inboxMessages(messages).map(\.providerThreadId))
    return GmailInboxThread.group(
      messages.filter { visibleThreadIds.contains($0.providerThreadId) }
    )
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
    guard let httpResponse = response as? HTTPURLResponse else {
      throw GmailMessageMetadataSyncError.refreshTokenRejected
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw GmailMessageMetadataSyncError.oauthResponseStatus(httpResponse.statusCode)
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
    guard let httpResponse = response as? HTTPURLResponse else {
      throw GmailMessageMetadataSyncError.refreshedTokenAccountMismatch
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw GmailMessageMetadataSyncError.oauthResponseStatus(httpResponse.statusCode)
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
  case oauthResponseStatus(Int)
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
    case .oauthResponseStatus(let status):
      return "Gmail OAuth request failed with HTTP status \(status)."
    case .refreshedTokenAccountMismatch:
      return "Local Gmail tokens belong to a different Google account."
    case .refreshTokenRejected:
      return "Gmail did not refresh local mail access for this account."
    case .staleLocalConnection:
      return "The Gmail connection changed while mailbox sync was running."
    }
  }
}

enum GmailProviderMailActionError: LocalizedError, Equatable {
  case responseStatus(Int)
  case rateLimitedResponseStatus(Int)

  var errorDescription: String? {
    switch self {
    case .responseStatus(let status), .rateLimitedResponseStatus(let status):
      return "Gmail rejected the message action (HTTP \(status))."
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
      bccRecipients: bccRecipients,
      calendarInvitation: calendarInvitation?.preservingDismissalIdentifier(
        from: existingMessage.calendarInvitation
      ),
      rfcMessageId: rfcMessageId,
      categoryIds: categoryIds,
      unsubscribeSuggestion: unsubscribeSuggestion
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
      bccRecipients: bccRecipients,
      calendarInvitation: calendarInvitation?.preservingDismissalIdentifier(
        from: existingMessage.calendarInvitation
      ),
      rfcMessageId: rfcMessageId,
      categoryIds: existingMessage.categoryIds,
      unsubscribeSuggestion: unsubscribeSuggestion
    )
  }
}

private struct GmailListMessagesResponse: Decodable {
  let messages: [GmailListedMessage]?
  let nextPageToken: String?
}

private struct GmailListLabelsResponse: Decodable {
  let labels: [GmailLabel]?
}

private struct GmailLabel: Decodable {
  let id: String
  let name: String
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
      stateChangedMessageIds.insert(addition.message.id)
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

struct GmailMessageMetadataResponse: Decodable {
  let id: String
  let internalDate: String
  let labelIds: [String]?
  fileprivate let payload: GmailMessagePayload?
  let snippet: String
  let threadId: String

  func calendarInvitation(
    providerMessageIdentity: String
  ) -> CalendarInvitationDescriptor? {
    payload?.calendarInvitation(providerMessageIdentity: providerMessageIdentity)
  }
}

private struct GmailMessagePayload: Decodable {
  let body: GmailMessagePayloadBody?
  let filename: String?
  let headers: [GmailMessageHeader]
  let mimeType: String?
  let partId: String?
  let parts: [GmailMessagePayload]?

  var hasAttachments: Bool {
    filename?.isEmpty == false || parts?.contains(where: \.hasAttachments) == true
  }

  func calendarInvitation(
    providerMessageIdentity: String,
    isRoot: Bool = true
  ) -> CalendarInvitationDescriptor? {
    let normalizedMIMEType = mimeType?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let stablePartId = partId ?? ""
    if let normalizedMIMEType,
      ["application/ics", "text/calendar", "text/x-vcalendar"].contains(normalizedMIMEType),
      isRoot || !stablePartId.isEmpty
    {
      return CalendarInvitationDescriptor(
        byteCount: body?.size ?? 0,
        mimeType: normalizedMIMEType,
        providerAttachmentId: body?.attachmentId,
        providerMessageIdentity: providerMessageIdentity,
        providerPartId: stablePartId
      )
    }
    return parts?.compactMap {
      $0.calendarInvitation(providerMessageIdentity: providerMessageIdentity, isRoot: false)
    }.first
  }
}

private struct GmailMessagePayloadBody: Decodable {
  let attachmentId: String?
  let size: Int?
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
