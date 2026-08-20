import Foundation
import SwiftData
import Testing

@testable import unwired_mail

// swiftlint:disable file_length function_body_length type_body_length

private final class GmailMetadataURLStub: URLProtocolStub {}

@Suite(.serialized)
final class GmailMessageMetadataServiceTests {
  private struct MessageMetadataOptions {
    let hasAttachments: Bool
    let includesCalendarInvitation: Bool
    let includesUnsubscribeHeaders: Bool
  }

  private let connection = GmailProviderConnectionStatus(
    connectedAt: 1_781_200_000_000,
    emailAddress: "user@example.com",
    lastVerifiedAt: 1_781_200_000_000,
    provider: "gmail",
    providerAccountIdentifier: "gmail-user-001",
    trustedDeviceId: "trusted-device-001",
    updatedAt: 1_781_200_000_000
  )
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "apple-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  @Test
  func testLocalMetadataSearchMatchesSupportedFieldsWithoutBodyIndex() {
    var calendar = Calendar.current
    calendar.timeZone = .current
    let matchingMessage = GmailMessageMetadata(
      categoryId: "system:invoices",
      from: "Billing <billing@example.com>",
      isHistorical: false,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      providerInternalDateMilliseconds: Int64(
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 15))!
          .timeIntervalSince1970 * 1_000
      ),
      providerLabelIds: ["INBOX", "UNREAD"],
      providerMessageId: "message-001",
      providerThreadId: "thread-001",
      replyTo: nil,
      snippet: "This text is not part of local search",
      stableProviderMessageId: "gmail:gmail-user-001:message-001",
      subject: "Quarterly invoice",
      recipientHeaders: [
        "User <user@example.com>",
        "Finance <finance@example.com>",
        "Auditor <auditor@example.com>",
      ],
      bccRecipients: ["Hidden <hidden@example.com>"],
      rfcMessageId: nil
    )
    var otherMessage = metadata(
      messageId: "message-002",
      threadId: "thread-002",
      internalDateMilliseconds: 10
    )
    otherMessage.providerLabelIds = ["INBOX"]
    let messages = [matchingMessage, otherMessage]
    let categoryNamesById = ["system:invoices": "Invoices"]

    for query in [
      "billing@example.com",
      "user@example.com",
      "finance@example.com",
      "auditor@example.com",
      "hidden@example.com",
      "quarterly invoice",
      "2026-07-15",
      "unread",
      "invoices",
    ] {
      #expect(
        GmailLocalMetadataSearch.messages(
          in: messages,
          matching: query,
          categoryNamesById: categoryNamesById
        ) == [matchingMessage], "Expected local metadata search to match \(query)")
    }
    #expect(
      GmailLocalMetadataSearch.messages(
        in: messages,
        matching: "read",
        categoryNamesById: categoryNamesById
      ) == [otherMessage])
    #expect(
      GmailLocalMetadataSearch.messages(
        in: messages,
        matching: "text is not part",
        categoryNamesById: categoryNamesById
      ) == [])
  }

  @Test
  func testLocalMetadataSearchDoesNotInferStatesWhenLabelsAreMissing() {
    let message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    )

    #expect(
      GmailLocalMetadataSearch.messages(
        in: [message],
        matching: "read",
        categoryNamesById: [:]
      ) == [])
    #expect(
      GmailLocalMetadataSearch.messages(
        in: [message],
        matching: "unstarred",
        categoryNamesById: [:]
      ) == [])
  }

  @Test
  func testFileMetadataStoreClearsOnlySelectedMailbox() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let store = FileGmailMessageMetadataStore(rootDirectory: rootDirectory)
    let first = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 1,
      providerAccountIdentifier: "gmail/user"
    )
    let second = metadata(
      messageId: "message-002",
      threadId: "thread-002",
      internalDateMilliseconds: 2,
      providerAccountIdentifier: "gmail:user"
    )
    try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    let legacyProductAccount = legacyGmailSafeFileComponent(session.productAccountId)
    let legacyProviderAccount = legacyGmailSafeFileComponent(first.providerAccountIdentifier)
    let legacyFirstURL = rootDirectory.appendingPathComponent(
      "\(legacyProductAccount)-\(legacyProviderAccount).json"
    )
    let firstData = try JSONEncoder().encode([first])
    try firstData.write(to: legacyFirstURL)
    try store.saveMessages(
      [second],
      productAccountId: session.productAccountId,
      providerAccountIdentifier: second.providerAccountIdentifier
    )
    try store.clearMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: second.providerAccountIdentifier
    )
    #expect(FileManager.default.fileExists(atPath: legacyFirstURL.path))

    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: second.providerAccountIdentifier
      ) == [])
    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: first.providerAccountIdentifier
      ) == [first])
    #expect(!(FileManager.default.fileExists(atPath: legacyFirstURL.path)))

    try firstData.write(to: legacyFirstURL)
    try store.clearMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: first.providerAccountIdentifier
    )
    #expect(!(FileManager.default.fileExists(atPath: legacyFirstURL.path)))
    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: first.providerAccountIdentifier
      ) == [])
  }

  @Test
  func testSwiftDataMetadataStorePersistsMessagesPerMailboxConnection() throws {
    let store = try SwiftDataGmailMessageMetadataStore.inMemory()
    let first = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 1,
      providerAccountIdentifier: "gmail-user-001"
    )
    let second = metadata(
      messageId: "message-002",
      threadId: "thread-002",
      internalDateMilliseconds: 2,
      providerAccountIdentifier: "gmail-user-002"
    )

    try store.saveMessages(
      [first],
      productAccountId: session.productAccountId,
      providerAccountIdentifier: first.providerAccountIdentifier
    )
    try store.saveMessages(
      [second],
      productAccountId: session.productAccountId,
      providerAccountIdentifier: second.providerAccountIdentifier
    )

    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: first.providerAccountIdentifier
      ) == [first])
    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: second.providerAccountIdentifier
      ) == [second])
  }

  @Test
  func testSwiftDataMetadataStoreBackfillsThreadLookupsAfterSchemaMigration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("GmailMetadata.store")
    var inboxMessage = metadata(
      messageId: "message-inbox",
      threadId: "thread-visible",
      internalDateMilliseconds: 3
    )
    inboxMessage.providerLabelIds = ["INBOX"]
    var sentReply = metadata(
      messageId: "message-sent",
      threadId: "thread-visible",
      internalDateMilliseconds: 2
    )
    sentReply.providerLabelIds = ["SENT"]
    var archivedMessage = metadata(
      messageId: "message-archive",
      threadId: "thread-hidden",
      internalDateMilliseconds: 1
    )
    archivedMessage.providerLabelIds = ["ARCHIVE"]
    do {
      let legacySchema = Schema([
        DurableGmailMessageMetadataRecord.self,
        GmailMetadataSyncCheckpointRecord.self,
      ])
      let legacyConfiguration = ModelConfiguration(
        "GmailThreadLookupMigrationTests",
        schema: legacySchema,
        url: storeURL
      )
      let legacyContainer = try ModelContainer(
        for: legacySchema,
        configurations: [legacyConfiguration]
      )
      let context = ModelContext(legacyContainer)
      for message in [inboxMessage, sentReply, archivedMessage] {
        let record = DurableGmailMessageMetadataRecord(
          encodedMessage: try JSONEncoder().encode(message),
          isInboxVisible: message.providerLabelIds?.contains("INBOX") ?? true,
          productAccountId: session.productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier,
          providerThreadId: message.providerThreadId,
          stableProviderMessageId: message.stableProviderMessageId,
          storageKey: [
            session.productAccountId,
            connection.providerAccountIdentifier,
            message.stableProviderMessageId,
          ]
          .map(gmailSafeFileComponent)
          .joined(separator: "-")
        )
        record.metadataIndexVersion = 1
        context.insert(record)
      }
      try context.save()
    }

    let schema = SwiftDataGmailMessageMetadataStore.schema
    let configuration = ModelConfiguration(
      "GmailThreadLookupMigrationTests",
      schema: schema,
      url: storeURL
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let store = SwiftDataGmailMessageMetadataStore(container: container)

    #expect(
      try store.loadInboxThreadMessages(
        additionalProviderMessageIds: [],
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [inboxMessage, sentReply])
    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [inboxMessage, sentReply, archivedMessage])

    let migratedContext = ModelContext(container)
    let threadLookups = try migratedContext.fetch(
      FetchDescriptor<DurableGmailThreadLookupRecord>()
    )
    #expect(threadLookups.count == 2)
    #expect(
      try threadLookups.first { $0.providerThreadId == "thread-visible" }?.messageStorageKeys()
        .count == 2)
    let inboxLookup = try requireValue(
      migratedContext.fetch(FetchDescriptor<DurableGmailInboxLookupRecord>()).first)
    #expect(try inboxLookup.threadStorageKeys().count == 1)
  }

  @Test
  func testSwiftDataInboxLookupPersistsOneIndexedEntryPerVisibleThread() throws {
    let schema = SwiftDataGmailMessageMetadataStore.schema
    let configuration = ModelConfiguration(
      "GmailVisibleThreadLookupTests",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let store = SwiftDataGmailMessageMetadataStore(container: container)
    let visibleMessages = (0..<501).map { index in
      var message = metadata(
        messageId: "message-inbox-\(index)",
        threadId: "thread-inbox-\(index)",
        internalDateMilliseconds: Int64(2_000 + index)
      )
      message.providerLabelIds = ["INBOX"]
      return message
    }
    let archivedMessages = (0..<1_000).map { index in
      var message = metadata(
        messageId: "message-archive-\(index)",
        threadId: "thread-archive-\(index)",
        internalDateMilliseconds: Int64(index)
      )
      message.providerLabelIds = ["ARCHIVE"]
      return message
    }
    try store.saveMessages(
      visibleMessages + archivedMessages,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    let context = ModelContext(container)
    let inboxLookup = try requireValue(
      context.fetch(FetchDescriptor<DurableGmailInboxLookupRecord>()).first)
    #expect(try inboxLookup.threadStorageKeys().count == visibleMessages.count)
    #expect(
      try context.fetch(FetchDescriptor<DurableGmailThreadLookupRecord>()).count == visibleMessages
        .count + archivedMessages.count)
    #expect(
      try store.loadInboxThreadMessages(
        additionalProviderMessageIds: [],
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == Array(visibleMessages.reversed()))
  }

  @Test
  func testSwiftDataMetadataStoreMovesLookupRowsWithExistingMessage() throws {
    let schema = SwiftDataGmailMessageMetadataStore.schema
    let configuration = ModelConfiguration(
      "GmailThreadMoveLookupTests",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let store = SwiftDataGmailMessageMetadataStore(container: container)
    var original = metadata(
      messageId: "message-001",
      threadId: "thread-old",
      internalDateMilliseconds: 1
    )
    original.providerLabelIds = ["INBOX"]
    var moved = metadata(
      messageId: "message-001",
      threadId: "thread-new",
      internalDateMilliseconds: 1
    )
    moved.providerLabelIds = ["INBOX"]

    try store.saveMessages(
      [original],
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    try store.saveMessages(
      [moved],
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    let context = ModelContext(container)
    let messageRecord = try requireValue(
      context.fetch(FetchDescriptor<DurableGmailMessageMetadataRecord>()).first)
    let threadLookups = try context.fetch(FetchDescriptor<DurableGmailThreadLookupRecord>())
    #expect(!(threadLookups.contains { $0.providerThreadId == "thread-old" }))
    let newThreadLookup = try requireValue(
      threadLookups.first { $0.providerThreadId == "thread-new" })
    #expect(try newThreadLookup.messageStorageKeys() == [messageRecord.storageKey])
    let inboxLookup = try requireValue(
      context.fetch(FetchDescriptor<DurableGmailInboxLookupRecord>()).first)
    #expect(try inboxLookup.threadStorageKeys() == [newThreadLookup.storageKey])
  }

  @Test
  func testSwiftDataMetadataStoreClearsLookupRowsWithinRequestedScope() throws {
    let schema = SwiftDataGmailMessageMetadataStore.schema
    let configuration = ModelConfiguration(
      "GmailClearLookupTests",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let store = SwiftDataGmailMessageMetadataStore(container: container)
    let otherProductAccountId = "product-account-002"
    let messages = [
      metadata(
        messageId: "message-001",
        threadId: "thread-001",
        internalDateMilliseconds: 1,
        providerAccountIdentifier: "gmail-user-001"
      ),
      metadata(
        messageId: "message-002",
        threadId: "thread-002",
        internalDateMilliseconds: 2,
        providerAccountIdentifier: "gmail-user-002"
      ),
      metadata(
        messageId: "message-003",
        threadId: "thread-003",
        internalDateMilliseconds: 3,
        providerAccountIdentifier: "gmail-user-003"
      ),
    ]
    for (message, productAccountId) in zip(
      messages,
      [session.productAccountId, session.productAccountId, otherProductAccountId]
    ) {
      try store.saveMessages(
        [message],
        productAccountId: productAccountId,
        providerAccountIdentifier: message.providerAccountIdentifier
      )
    }

    try store.clearMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: messages[0].providerAccountIdentifier
    )

    var context = ModelContext(container)
    var threadLookups = try context.fetch(FetchDescriptor<DurableGmailThreadLookupRecord>())
    var inboxLookups = try context.fetch(FetchDescriptor<DurableGmailInboxLookupRecord>())
    #expect(Set(threadLookups.map(\.providerThreadId)) == ["thread-002", "thread-003"])
    #expect(inboxLookups.count == 2)

    try store.clearMessages(productAccountId: session.productAccountId)

    context = ModelContext(container)
    threadLookups = try context.fetch(FetchDescriptor<DurableGmailThreadLookupRecord>())
    inboxLookups = try context.fetch(FetchDescriptor<DurableGmailInboxLookupRecord>())
    #expect(threadLookups.map(\.providerThreadId) == ["thread-003"])
    #expect(inboxLookups.map(\.productAccountId) == [otherProductAccountId])
  }

  @Test
  func testSwiftDataMetadataStoreMigratesInboxIndexesWithoutDroppingArchivedMetadata() throws {
    let schema = SwiftDataGmailMessageMetadataStore.schema
    let configuration = ModelConfiguration(
      "GmailInboxIndexMigrationTests",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let store = SwiftDataGmailMessageMetadataStore(container: container)
    var inboxMessage = metadata(
      messageId: "message-inbox",
      threadId: "thread-inbox",
      internalDateMilliseconds: 2
    )
    inboxMessage.providerLabelIds = ["INBOX"]
    var archivedMessage = metadata(
      messageId: "message-archive",
      threadId: "thread-archive",
      internalDateMilliseconds: 1
    )
    archivedMessage.providerLabelIds = ["ARCHIVE"]
    try store.saveMessages(
      [inboxMessage, archivedMessage],
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    let legacyContext = ModelContext(container)
    for record in try legacyContext.fetch(FetchDescriptor<DurableGmailMessageMetadataRecord>()) {
      record.isInboxVisible = false
      record.metadataIndexVersion = 0
      record.providerThreadId = ""
    }
    try legacyContext.save()

    #expect(
      try store.loadInboxThreadMessages(
        additionalProviderMessageIds: [],
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [inboxMessage])
    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [inboxMessage, archivedMessage])

    let indexedContext = ModelContext(container)
    let archivedRecord = try requireValue(
      indexedContext.fetch(FetchDescriptor<DurableGmailMessageMetadataRecord>())
        .first { $0.stableProviderMessageId == archivedMessage.stableProviderMessageId })
    archivedRecord.encodedMessage = Data("not-json".utf8)
    try indexedContext.save()

    #expect(
      try store.loadInboxThreadMessages(
        additionalProviderMessageIds: [],
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [inboxMessage])
  }

  @Test
  func testSwiftDataInboxIndexMigrationBoundsWorkPerLoad() throws {
    let schema = SwiftDataGmailMessageMetadataStore.schema
    let configuration = ModelConfiguration(
      "GmailBoundedInboxIndexMigrationTests",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let store = SwiftDataGmailMessageMetadataStore(container: container)
    var inboxMessage = metadata(
      messageId: "message-inbox",
      threadId: "thread-inbox",
      internalDateMilliseconds: 1_000
    )
    inboxMessage.providerLabelIds = ["INBOX"]
    let archivedMessages = (0..<600).map { index in
      var message = metadata(
        messageId: "message-archive-\(index)",
        threadId: "thread-archive-\(index)",
        internalDateMilliseconds: Int64(index)
      )
      message.providerLabelIds = ["ARCHIVE"]
      return message
    }
    try store.saveMessages(
      [inboxMessage] + archivedMessages,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    let legacyContext = ModelContext(container)
    for record in try legacyContext.fetch(FetchDescriptor<DurableGmailMessageMetadataRecord>()) {
      record.metadataIndexVersion = 0
    }
    try legacyContext.save()

    #expect {
      try store.loadInboxThreadMessages(
        additionalProviderMessageIds: ["message-archive-599"],
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
    } throws: { error in
      guard case GmailMessageMetadataStoreError.inboxIndexMigrationPending = error else {
        Issue.record("Expected bounded Inbox index migration to remain pending.")
        return true
      }
      return true
    }

    let migratedContext = ModelContext(container)
    var records = try migratedContext.fetch(
      FetchDescriptor<DurableGmailMessageMetadataRecord>()
    )
    #expect(records.filter { $0.metadataIndexVersion == 0 }.count == 101)

    #expect(
      try store.loadInboxThreadMessages(
        additionalProviderMessageIds: [],
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [inboxMessage])
    let completedContext = ModelContext(container)
    records = try completedContext.fetch(FetchDescriptor<DurableGmailMessageMetadataRecord>())
    #expect(records.filter { $0.metadataIndexVersion == 0 }.count == 0)
  }

  @Test
  func testSwiftDataMetadataStoreResumesBackfillAndReconcilesProviderDeletions() throws {
    let store = try SwiftDataGmailMessageMetadataStore.inMemory()
    let stale = metadata(
      messageId: "message-stale",
      threadId: "thread-stale",
      internalDateMilliseconds: 1
    )
    let newest = metadata(
      messageId: "message-newest",
      threadId: "thread-newest",
      internalDateMilliseconds: 3
    )
    let older = metadata(
      messageId: "message-older",
      threadId: "thread-older",
      internalDateMilliseconds: 2
    )
    try store.saveMessages(
      [stale],
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let interruptedState = GmailMetadataSyncState(
      historicalMetadataBackfillIsComplete: false,
      nextPageToken: "next-page-token",
      scanId: "scan-001"
    )

    try store.saveSyncPage(
      [newest],
      state: interruptedState,
      isFirstPage: true,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    #expect(
      try store.loadSyncState(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == interruptedState)

    let completedState = GmailMetadataSyncState(
      historicalMetadataBackfillIsComplete: true,
      nextPageToken: nil,
      scanId: interruptedState.scanId
    )
    try store.saveSyncPage(
      [older],
      state: completedState,
      isFirstPage: false,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [newest, older])
    #expect(
      try store.loadSyncState(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == completedState)
  }

  @Test
  func testSwiftDataMetadataStoreKeepsRemovalMarkersDuringOrdinarySaves() throws {
    let store = try SwiftDataGmailMessageMetadataStore.inMemory()
    let stale = metadata(
      messageId: "message-stale",
      threadId: "thread-stale",
      internalDateMilliseconds: 1
    )
    let newest = metadata(
      messageId: "message-newest",
      threadId: "thread-newest",
      internalDateMilliseconds: 3
    )
    let older = metadata(
      messageId: "message-older",
      threadId: "thread-older",
      internalDateMilliseconds: 2
    )
    let incompleteState = GmailMetadataSyncState(
      historicalMetadataBackfillIsComplete: false,
      nextPageToken: "next-page-token",
      scanId: "scan-001"
    )
    try store.saveMessages(
      [stale],
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    try store.saveSyncPage(
      [newest],
      state: incompleteState,
      isFirstPage: true,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    try store.saveMessages(
      [newest, stale],
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    try store.saveSyncPage(
      [older],
      state: GmailMetadataSyncState(
        historicalMetadataBackfillIsComplete: true,
        nextPageToken: nil,
        scanId: incompleteState.scanId
      ),
      isFirstPage: false,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [newest, older])
  }

  @Test
  func testSwiftDataMetadataStoreRestoresBackfillCheckpointAfterContainerRecreation() throws {
    let configurationName = "GmailMetadataRestart-\(UUID().uuidString)"
    let schema = SwiftDataGmailMessageMetadataStore.schema
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    try FileManager.default.createDirectory(
      at: rootDirectory,
      withIntermediateDirectories: true
    )
    let configuration = ModelConfiguration(
      configurationName,
      schema: schema,
      url: rootDirectory.appendingPathComponent("metadata.store")
    )
    let message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 1
    )
    let interruptedState = GmailMetadataSyncState(
      historicalMetadataBackfillIsComplete: false,
      nextPageToken: "restart-page-token",
      scanId: "restart-scan"
    )

    do {
      let container = try ModelContainer(for: schema, configurations: [configuration])
      let store = SwiftDataGmailMessageMetadataStore(container: container)
      try store.saveSyncPage(
        [message],
        state: interruptedState,
        isFirstPage: true,
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
    }

    let restartedContainer = try ModelContainer(for: schema, configurations: [configuration])
    let restartedStore = SwiftDataGmailMessageMetadataStore(container: restartedContainer)
    #expect(
      try restartedStore.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [message])
    #expect(
      try restartedStore.loadSyncState(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == interruptedState)
  }

  @Test
  func testSwiftDataMetadataStorePersistsRecategorizedExistingMessage() throws {
    let store = try SwiftDataGmailMessageMetadataStore.inMemory()
    let existing = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 1
    )
    let state = GmailMetadataSyncState(
      historicalMetadataBackfillIsComplete: true,
      nextPageToken: nil,
      scanId: "scan-001"
    )
    try store.saveSyncPage(
      [existing],
      state: state,
      isFirstPage: true,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    try store.saveSyncPage(
      [existing.assigningCategory("system:promotions")],
      state: state,
      isFirstPage: false,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ).first?.categoryId == "system:promotions")
  }

  @Test
  func testSwiftDataMetadataStoreMigratesExistingFileMetadata() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let legacyStore = FileGmailMessageMetadataStore(rootDirectory: rootDirectory)
    let message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 1
    )
    try legacyStore.saveMessages(
      [message],
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let store = try SwiftDataGmailMessageMetadataStore.inMemory(
      legacyStore: legacyStore
    )

    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [message])
    #expect(
      try legacyStore.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [])
    #expect(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [message])
  }

  @Test
  func testSwiftDataMetadataStoreMigratesExistingFileMetadataBeforeInboxLoad() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let legacyStore = FileGmailMessageMetadataStore(rootDirectory: rootDirectory)
    var message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 1
    )
    message.providerLabelIds = ["INBOX"]
    try legacyStore.saveMessages(
      [message],
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let store = try SwiftDataGmailMessageMetadataStore.inMemory(
      legacyStore: legacyStore
    )

    #expect(
      try store.loadInboxThreadMessages(
        additionalProviderMessageIds: [],
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [message])
    #expect(
      try legacyStore.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ) == [])
  }

  @Test
  func testSyncInboxStoresMetadataWithStableProviderIdentityAndNoCategory() async throws {
    let fixture = try makeSyncFixture()

    let result = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    #expect(
      fixture.requestRecorder.paths == [
        "/token",
        "/tokeninfo",
        "/gmail/v1/users/me/messages",
        "/gmail/v1/users/me/messages/message-002",
        "/gmail/v1/users/me/messages/message-001",
      ])
    #expect(result.messages.map(\.providerMessageId) == ["message-002", "message-001"])
    #expect(result.threads.count == 1)
    #expect(result.threads[0].providerThreadId == "thread-001")
    #expect(result.threads[0].messages.count == 2)
    #expect(result.messages[0].stableProviderMessageId == "gmail:gmail-user-001:message-002")
    #expect(result.messages.allSatisfy { $0.isHistorical })
    #expect(result.messages.allSatisfy { $0.categoryId == nil })
    #expect(fixture.store.savedMessages == result.messages)
    #expect(
      try fixture.tokenStore.load(productAccountId: session.productAccountId)
        == GmailProviderTokens(accessToken: "refreshed-access-token", refreshToken: "refresh-token")
    )
  }

  @Test
  func testSyncInboxStoresReplyToHeader() async throws {
    let fixture = try makeSyncFixture(replyTo: "Replies <replies@example.com>")

    let result = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    #expect(
      result.messages.first { $0.providerMessageId == "message-002" }?.replyTo
        == "Replies <replies@example.com>")
  }

  @Test
  func testSyncInboxStoresRecipientAndProviderStateForLocalSearch() async throws {
    let fixture = try makeSyncFixture()

    let result = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    #expect(
      fixture.requestRecorder.queries
        .filter { $0.contains("format=full") }
        .allSatisfy {
          $0.contains("fields=")
            && $0.contains("filename")
            && $0.contains("metadataHeaders=To")
            && $0.contains("metadataHeaders=Cc")
            && $0.contains("metadataHeaders=Bcc")
        })
    #expect(
      result.messages.first?.recipientHeaders == [
        "User <user@example.com>",
        "Finance <finance@example.com>",
      ])
    #expect(
      result.messages.first?.bccRecipients == [
        "Auditor <auditor@example.com>"
      ])
    #expect(result.messages.first?.providerLabelIds == ["INBOX", "UNREAD"])
  }

  @Test
  func testSyncInboxReadsUnsubscribeHeadersWithoutRequestingBodyData() async throws {
    let fixture = try makeSyncFixture(includesUnsubscribeHeaders: true)

    let result = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    #expect(
      fixture.requestRecorder.queries
        .filter { $0.contains("format=full") }
        .allSatisfy {
          $0.contains("metadataHeaders=List-ID")
            && $0.contains("metadataHeaders=List-Unsubscribe")
            && $0.contains("metadataHeaders=List-Unsubscribe-Post")
            && !$0.contains("body(data")
        }
    )
    let suggestion = try requireValue(result.messages.first?.unsubscribeSuggestion)
    #expect(suggestion.mailingListIdentity.rawValue == "list-id:news.example.com")
    #expect(
      suggestion.actions == [
        .oneClick(try requireValue(URL(string: "https://lists.example.com/unsubscribe"))),
        .mailto(
          UnsubscribeMailtoMessage(
            body: "unsubscribe",
            recipient: "leave@example.com",
            subject: "remove"
          )
        ),
        .web(try requireValue(URL(string: "https://lists.example.com/unsubscribe"))),
      ]
    )
  }

  @Test
  func testSyncInboxStoresAttachmentMetadata() async throws {
    let fixture = try makeSyncFixture(hasAttachments: true)

    let result = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    #expect(result.messages.allSatisfy { $0.hasAttachments == true })
  }

  @Test
  func testSyncInboxDetectsCalendarMIMEWithoutRequestingBodyData() async throws {
    let fixture = try makeSyncFixture(includesCalendarInvitation: true)
    var existing = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 1_781_197_200_000
    )
    existing.calendarInvitation = CalendarInvitationDescriptor(
      byteCount: 512,
      dismissalIdentifier: "known-dismissal",
      mimeType: "text/calendar",
      providerAttachmentId: "calendar-001",
      providerPartId: "2"
    )
    fixture.store.messages = [existing]

    let result = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    #expect(
      fixture.requestRecorder.queries
        .filter { $0.contains("format=full") }
        .allSatisfy {
          $0.contains("attachmentId")
            && $0.contains("partId")
            && !$0.contains("body(data")
        }
    )
    let invitation = try requireValue(
      result.messages.first { $0.providerMessageId == "message-001" }?.calendarInvitation
    )
    #expect(invitation.byteCount == 512)
    #expect(invitation.mimeType == "text/calendar")
    #expect(invitation.providerAttachmentId == "calendar-001")
    #expect(invitation.providerPartId == "2")
    #expect(invitation.dismissalIdentifier == "known-dismissal")
  }

  @Test
  func testCalendarInvitationDetectsRootMIMEPartWithoutPartIdentifier() throws {
    let response = try JSONDecoder().decode(
      GmailMessageMetadataResponse.self,
      from: Data(
        """
        {
          "id":"message-001",
          "internalDate":"1781190000000",
          "snippet":"Invitation",
          "threadId":"thread-001",
          "payload":{
            "body":{"size":512},
            "headers":[],
            "mimeType":"text/calendar"
          }
        }
        """.utf8
      )
    )

    let invitation = try requireValue(
      response.calendarInvitation(providerMessageIdentity: response.id)
    )
    #expect(invitation.providerPartId.isEmpty)
    #expect(invitation.mimeType == "text/calendar")
  }

  @Test
  func testProviderFullTextSearchSendsQueryAndDoesNotPersistResults() async throws {
    let store = RecordingGmailMessageMetadataStore()
    let tokenStore = RecordingGmailProviderTokenStore()
    let recorder = GmailMetadataRequestRecorder()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let urlSession = ConvexClientTesting.makeSession(
      protocolClass: GmailMetadataURLStub.self
    ) { request in
      recorder.paths.append(request.url?.path ?? "")
      recorder.queries.append(request.url?.query ?? "")
      switch request.url?.path {
      case "/token":
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      case "/tokeninfo":
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"sub":"gmail-user-001","email":"user@example.com"}"#.utf8)
        )
      case "/gmail/v1/users/me/messages":
        if request.url?.query?.contains("pageToken=next-page-token") == true {
          return (
            Self.httpResponse(for: request, statusCode: 200),
            Data(#"{"messages":[{"id":"message-002"}]}"#.utf8)
          )
        }
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(
            #"{"messages":[{"id":"message-001"}],"nextPageToken":"next-page-token"}"#.utf8
          )
        )
      default:
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Self.messageMetadataResponseData(
            messageId: request.url?.lastPathComponent ?? "",
            internalDate: "1784073600000",
            snippet: "Provider result"
          )
        )
      }
    }
    let service = GmailMessageMetadataService(
      gmailBaseURL: URL(string: "https://gmail.example.test/gmail/v1")!,
      oauthClientId: "gmail-client-id",
      session: urlSession,
      store: store,
      tokenStore: tokenStore,
      tokenInfoURL: URL(string: "https://oauth.example.test/tokeninfo")!,
      tokenRefreshURL: URL(string: "https://oauth.example.test/token")!
    )

    let messages = try await service.searchProvider(
      query: "invoice total",
      connection: connection,
      session: session
    )

    #expect(
      recorder.paths == [
        "/token",
        "/tokeninfo",
        "/gmail/v1/users/me/messages",
        "/gmail/v1/users/me/messages",
        "/gmail/v1/users/me/messages/message-001",
        "/gmail/v1/users/me/messages/message-002",
      ])
    #expect(recorder.queries[2].contains("q=invoice%20total"))
    #expect(messages.map(\.providerMessageId) == ["message-001", "message-002"])
    #expect(store.savedMessages.isEmpty)
  }

  @Test
  func testProviderConfirmedSendingAddressesIncludeOnlyAcceptedSendAsAliases() async throws {
    let recorder = GmailMetadataRequestRecorder()
    let tokenStore = RecordingGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let urlSession = ConvexClientTesting.makeSession(
      protocolClass: GmailMetadataURLStub.self
    ) { request in
      recorder.paths.append(request.url?.path ?? "")
      recorder.authorizationHeaders.append(
        request.value(forHTTPHeaderField: "Authorization")
      )
      switch request.url?.path {
      case "/token":
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      case "/tokeninfo":
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(
            #"""
            {"sub":"gmail-user-001","email":"user@example.com",
            "scope":"https://www.googleapis.com/auth/gmail.modify"}
            """#.utf8
          )
        )
      case "/gmail/v1/users/me/settings/sendAs":
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(
            #"""
            {"sendAs":[
              {"sendAsEmail":"user@example.com"},
              {"sendAsEmail":"alias@example.com","verificationStatus":"accepted"},
              {"sendAsEmail":"pending@example.com","verificationStatus":"pending"}
            ]}
            """#.utf8
          )
        )
      default:
        Issue.record("Unexpected request: \(String(describing: request.url))")
        return (Self.httpResponse(for: request, statusCode: 404), Data())
      }
    }
    let service = GmailMessageMetadataService(
      gmailBaseURL: URL(string: "https://gmail.example.test/gmail/v1")!,
      oauthClientId: "gmail-client-id",
      session: urlSession,
      store: RecordingGmailMessageMetadataStore(),
      tokenStore: tokenStore,
      tokenInfoURL: URL(string: "https://oauth.example.test/tokeninfo")!,
      tokenRefreshURL: URL(string: "https://oauth.example.test/token")!
    )

    let addresses = try await service.loadProviderConfirmedSendingAddresses(
      connection: connection,
      session: session
    )

    #expect(addresses == ["alias@example.com"])
    #expect(
      recorder.paths == [
        "/token",
        "/tokeninfo",
        "/gmail/v1/users/me/settings/sendAs",
      ])
    #expect(recorder.authorizationHeaders[2] == "Bearer refreshed-access-token")
  }

  @Test
  func testLoadInboxGroupsPersistedMessagesIntoThreads() async throws {
    let store = RecordingGmailMessageMetadataStore()
    store.messages = [
      metadata(
        messageId: "message-001",
        threadId: "thread-001",
        internalDateMilliseconds: 10
      ),
      metadata(
        messageId: "message-003",
        threadId: "thread-002",
        internalDateMilliseconds: 30
      ),
      metadata(
        messageId: "message-002",
        threadId: "thread-001",
        internalDateMilliseconds: 20
      ),
    ]
    let service = GmailMessageMetadataService(
      store: store,
      tokenStore: RecordingGmailProviderTokenStore()
    )

    let result = try await service.loadInbox(
      connection: connection,
      session: session
    )

    #expect(result.threads.map(\.providerThreadId) == ["thread-002", "thread-001"])
    #expect(result.threads[1].messages.map(\.providerMessageId) == ["message-002", "message-001"])
  }

  @Test
  func testLoadInboxIncludesLocallyObservedNonInboxMessagesInVisibleConversations() async throws {
    let store = RecordingGmailMessageMetadataStore()
    var inboxMessage = metadata(
      messageId: "message-inbox",
      threadId: "thread-visible",
      internalDateMilliseconds: 10
    )
    inboxMessage.providerLabelIds = ["INBOX"]
    var sentReply = metadata(
      messageId: "message-sent",
      threadId: "thread-visible",
      internalDateMilliseconds: 20
    )
    sentReply.providerLabelIds = ["SENT"]
    var unrelatedSentMessage = metadata(
      messageId: "message-unrelated",
      threadId: "thread-hidden",
      internalDateMilliseconds: 30
    )
    unrelatedSentMessage.providerLabelIds = ["SENT"]
    store.messages = [inboxMessage, sentReply, unrelatedSentMessage]
    let service = GmailMessageMetadataService(
      store: store,
      tokenStore: RecordingGmailProviderTokenStore()
    )

    let result = try await service.loadInbox(
      connection: connection,
      session: session
    )

    #expect(result.messages.map(\.providerMessageId) == ["message-inbox"])
    #expect(result.threads.map(\.providerThreadId) == ["thread-visible"])
    #expect(
      result.threads[0].messages.map(\.providerMessageId) == ["message-sent", "message-inbox"])
  }

  @Test
  func testLoadInboxDoesNotDecodeLargeArchivedMetadataSet() async throws {
    let schema = SwiftDataGmailMessageMetadataStore.schema
    let configuration = ModelConfiguration(
      "GmailInboxScopeTests",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let store = SwiftDataGmailMessageMetadataStore(container: container)
    var inboxMessage = metadata(
      messageId: "message-inbox",
      threadId: "thread-visible",
      internalDateMilliseconds: 2_000
    )
    inboxMessage.providerLabelIds = ["INBOX"]
    var sentReply = metadata(
      messageId: "message-sent",
      threadId: "thread-visible",
      internalDateMilliseconds: 2_001
    )
    sentReply.providerLabelIds = ["SENT"]
    let archivedMessages = (0..<1_000).map { index in
      var message = metadata(
        messageId: "message-archive-\(index)",
        threadId:
          index == 500 || index == 501
          ? "thread-restored"
          : "thread-archive-\(index)",
        internalDateMilliseconds: Int64(index)
      )
      message.providerLabelIds = ["ARCHIVE"]
      return message
    }
    try store.saveMessages(
      [inboxMessage, sentReply] + archivedMessages,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )

    let context = ModelContext(container)
    let archivedRecords = try context.fetch(
      FetchDescriptor<DurableGmailMessageMetadataRecord>()
    ).filter { $0.stableProviderMessageId.contains("message-archive-") }
    for record in archivedRecords {
      if !record.stableProviderMessageId.hasSuffix("message-archive-500")
        && !record.stableProviderMessageId.hasSuffix("message-archive-501")
      {
        record.encodedMessage = Data("not-json".utf8)
      }
    }
    try context.save()

    let service = GmailMessageMetadataService(
      store: store,
      tokenStore: RecordingGmailProviderTokenStore()
    )
    let result = try await service.loadInbox(connection: connection, session: session)

    #expect(result.messages.map(\.providerMessageId) == ["message-inbox"])
    #expect(
      result.threads.first?.messages.map(\.providerMessageId) == ["message-sent", "message-inbox"])

    let projectionCandidates = try await service.loadInboxProjectionCandidates(
      additionalProviderMessageIds: ["message-inbox", "message-archive-500"],
      connection: connection,
      session: session
    )
    #expect(
      projectionCandidates.messages.map(\.providerMessageId) == [
        "message-sent", "message-inbox", "message-archive-501", "message-archive-500",
      ])
  }

  @Test
  func testLoadMailboxProjectsCanonicalRolesAndConnectionScopedLabels() async throws {
    let store = RecordingGmailMessageMetadataStore()
    var inboxMessage = metadata(
      messageId: "message-inbox",
      threadId: "thread-shared",
      internalDateMilliseconds: 10
    )
    inboxMessage.providerLabelIds = ["INBOX", "UNREAD", "Label_projects"]
    var sentReply = metadata(
      messageId: "message-sent",
      threadId: "thread-shared",
      internalDateMilliseconds: 20
    )
    sentReply.providerLabelIds = ["SENT"]
    var archivedMessage = metadata(
      messageId: "message-archived",
      threadId: "thread-archived",
      internalDateMilliseconds: 30
    )
    archivedMessage.providerLabelIds = ["Label_projects"]
    store.messages = [inboxMessage, sentReply, archivedMessage]
    let service = GmailMessageMetadataService(
      store: store,
      tokenStore: RecordingGmailProviderTokenStore()
    )

    let sent = try await service.loadMailbox(
      .role(.sent),
      connection: connection,
      session: session
    )
    let archive = try await service.loadMailbox(
      .role(.archive),
      connection: connection,
      session: session
    )
    let projects = try await service.loadMailbox(
      .providerMailbox("Label_projects"),
      connection: connection,
      session: session
    )

    #expect(sent.messages.map(\.providerMessageId) == ["message-sent"])
    #expect(sent.threads[0].messages.map(\.providerMessageId) == ["message-sent", "message-inbox"])
    #expect(archive.messages.map(\.providerMessageId) == ["message-archived"])
    #expect(projects.messages.map(\.providerMessageId) == ["message-archived", "message-inbox"])
  }

  @Test
  func testLoadProviderMailboxesUsesGmailNamesAndKeepsEmptyLabels() async throws {
    let fixture = try makeSyncFixture()

    let mailboxes = try await fixture.service.loadProviderMailboxes(
      connection: connection,
      session: session
    )

    #expect(
      mailboxes == [
        ProviderMailbox(id: "Label_empty", title: "Empty label"),
        ProviderMailbox(id: "Label_projects", title: "Projects"),
      ])
    #expect(fixture.requestRecorder.paths.contains("/gmail/v1/users/me/labels"))
  }

  @Test
  func testOverrideCategoryPersistsUpdatedMessageMetadata() async throws {
    let message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    )
    let store = RecordingGmailMessageMetadataStore()
    store.messages = [message]
    let categorizer = RecordingGmailMessageCategorizer()
    let service = GmailMessageMetadataService(
      categorizer: categorizer,
      store: store,
      tokenStore: RecordingGmailProviderTokenStore()
    )

    var projectedMessage = message
    projectedMessage.providerLabelIds = []
    let overridden = try await service.overrideCategory(
      "system:invoices",
      for: projectedMessage,
      session: session
    )

    #expect(overridden.categoryId == "system:invoices")
    #expect(overridden.providerLabelIds == message.providerLabelIds)
    #expect(store.savedMessages == [overridden])
  }

  @Test
  func testHistoricalCategorizationPersistsOnlyMessagesInSelectedDateRange() async throws {
    let beforeScope = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 100
    )
    let inScope = metadata(
      messageId: "message-002",
      threadId: "thread-002",
      internalDateMilliseconds: 200
    )
    let afterScope = metadata(
      messageId: "message-003",
      threadId: "thread-003",
      internalDateMilliseconds: 300
    )
    let store = RecordingGmailMessageMetadataStore()
    store.messages = [beforeScope, inScope, afterScope]
    let categorizer = RecordingGmailMessageCategorizer(categoryId: "system:promotions")
    let profileId = MailProfileId(rawValue: "profile-categories")
    let recordScope = MailProfileRecordScope.profile(profileId)
    let service = GmailMessageMetadataService(
      categorizer: categorizer,
      profileResolver: FixedNotificationProfileResolver(
        resolution: NotificationProfileResolution(
          deliveryContext: NotificationDeliveryContext(
            connectionId: connection.mailboxConnectionId,
            isActiveProfile: true,
            isProfileQuiet: false,
            profileId: profileId,
            profileName: "Categories"
          ),
          recordScope: recordScope
        )
      ),
      store: store,
      tokenStore: RecordingGmailProviderTokenStore()
    )
    let scope = GmailHistoricalCategorizationScope(
      receivedAtOrAfterMilliseconds: 150,
      receivedBeforeMilliseconds: 250
    )

    let result = try await service.categorizeHistorical(
      scope: scope,
      connection: connection,
      session: session
    )

    #expect(categorizer.receivedHistoricalScope == scope)
    #expect(categorizer.receivedRecordScopes == [recordScope])
    #expect(result.categorizedMessageCount == 1)
    #expect(result.messages.map(\.categoryId) == [nil, "system:promotions", nil])
    #expect(store.savedMessages == result.messages)
  }

  @MainActor
  @Test
  func testInboxViewModelLoadsUnifiedInboxAcrossAuthorizedConnections() async {
    let fixture = makeUnifiedInboxViewModelFixture()

    await fixture.viewModel.loadUnifiedInbox(connections: fixture.connections)

    #expect(fixture.viewModel.threads.map(\.providerThreadId) == ["thread-second", "thread-first"])
    #expect(Set(fixture.viewModel.threads.map(\.id.connectionId)).count == 2)
    let syncInboxCallCount = await fixture.service.syncInboxCallCount()
    #expect(syncInboxCallCount == fixture.connections.count)
  }

  @MainActor
  @Test
  func testInboxViewModelAppliesCategoryOverrideInUnifiedInbox() async throws {
    let fixture = makeUnifiedInboxViewModelFixture()
    await fixture.viewModel.loadUnifiedInbox(connections: fixture.connections)
    let message = try requireValue(
      fixture.viewModel.threads
        .flatMap(\.messages)
        .first(where: { $0.connectionId == fixture.connections[1].id }))

    let overrideTask = Task {
      await fixture.viewModel.overrideCategory("system:invoices", for: message)
    }
    await fixture.service.waitUntilOverrideStarts()
    await fixture.service.releaseOverride()
    await overrideTask.value

    #expect(
      fixture.viewModel.threads
        .flatMap(\.messages)
        .first(where: { $0.id == message.id })?
        .categoryId == "system:invoices")
  }

  @MainActor
  @Test
  func testInboxViewModelReportsCategoryOverrideFailure() async throws {
    let fixture = makeUnifiedInboxViewModelFixture(
      overrideCategoryErrorDescription: "Category assignment failed"
    )
    await fixture.viewModel.loadUnifiedInbox(connections: fixture.connections)
    let message = try requireValue(fixture.viewModel.threads.first?.latestMessage)

    await fixture.viewModel.overrideCategory("system:invoices", for: message)

    #expect(fixture.viewModel.categoryOverrideErrorMessage == "Category assignment failed")
    #expect(fixture.viewModel.errorMessage == nil)

    fixture.viewModel.clearCategoryOverrideError()

    #expect(fixture.viewModel.categoryOverrideErrorMessage == nil)
  }

  @MainActor
  @Test
  func testInboxViewModelProjectsSuppliedPinsAndOutboxState() async {
    let fixture = makeUnifiedInboxViewModelFixture()
    let pinnedThreadId = StableThreadIdentity(
      connectionId: fixture.connections[1].id,
      providerThreadId: "thread-second"
    )
    fixture.viewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: [.failed],
        pinnedThreadIds: [pinnedThreadId],
        snoozedThreadIds: []
      )
    )

    await fixture.viewModel.loadUnifiedMailbox(.pins, connections: fixture.connections)

    #expect(
      fixture.viewModel.threads.flatMap(\.messages).map(\.id) == [
        StableProviderMessageIdentity(
          connectionId: fixture.connections[1].id,
          providerMessageId: "message-second"
        )
      ])
    #expect(fixture.viewModel.navigationSnapshot.showsOutbox)
  }

  @MainActor
  @Test
  func testInboxViewModelProjectsSuppliedSnoozes() async {
    let fixture = makeUnifiedInboxViewModelFixture()
    let snoozedThreadId = StableThreadIdentity(
      connectionId: fixture.connections[1].id,
      providerThreadId: "thread-second"
    )
    fixture.viewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: [],
        pinnedThreadIds: [],
        snoozedThreadIds: [snoozedThreadId]
      )
    )

    await fixture.viewModel.loadUnifiedMailbox(.inbox, connections: fixture.connections)
    #expect(fixture.viewModel.threads.map(\.providerThreadId) == ["thread-first"])

    await fixture.viewModel.loadUnifiedMailbox(.snoozed, connections: fixture.connections)
    #expect(fixture.viewModel.threads.map(\.providerThreadId) == ["thread-second"])
  }

  @MainActor
  @Test
  func testInboxProjectionPreservesEveryMessageInVisibleThread() {
    var inboxMessage = metadata(
      messageId: "message-inbox",
      threadId: "thread-mixed",
      internalDateMilliseconds: 200
    )
    inboxMessage.providerLabelIds = ["INBOX"]
    var sentMessage = metadata(
      messageId: "message-sent",
      threadId: "thread-mixed",
      internalDateMilliseconds: 100
    )
    sentMessage.providerLabelIds = ["SENT"]
    let connectionId = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    ).id

    let threads = GmailInboxViewModel.projectedThreads(
      [inboxMessage, sentMessage].map { $0.mailboxMetadata(connectionId: connectionId) },
      to: .role(.inbox),
      pinnedThreadIds: [],
      snoozedThreadIds: []
    )

    #expect(threads.count == 1)
    #expect(Set(threads[0].messages.map(\.providerMessageId)) == ["message-inbox", "message-sent"])
  }

  @MainActor
  @Test
  func testInboxViewModelRevalidatesPinsBeforePublishingUnifiedPhaseResults() async {
    let syncStarts = expectation(description: "both pin syncs start")
    syncStarts.expectedFulfillmentCount = 2
    let phaseGate = UnifiedInboxPhaseGate { phase in
      if phase == .sync {
        syncStarts.fulfill()
      }
    }
    let fixture = makeUnifiedInboxViewModelFixture(phaseGate: phaseGate)
    let originalPin = StableThreadIdentity(
      connectionId: fixture.connections[1].id,
      providerThreadId: "thread-second"
    )
    let replacementPin = StableThreadIdentity(
      connectionId: fixture.connections[0].id,
      providerThreadId: "thread-first"
    )
    fixture.viewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: [],
        pinnedThreadIds: [originalPin],
        snoozedThreadIds: []
      )
    )
    await fixture.viewModel.loadNavigation(connections: fixture.connections)

    let loadTask = Task { @MainActor in
      await fixture.viewModel.loadUnifiedMailbox(.pins, connections: fixture.connections)
    }
    await fulfillment(of: [syncStarts], timeout: 1)
    fixture.viewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: [],
        pinnedThreadIds: [replacementPin],
        snoozedThreadIds: []
      )
    )
    await phaseGate.release(.sync)
    await loadTask.value

    #expect(
      fixture.viewModel.threads.flatMap(\.messages).map(\.id) == [
        StableProviderMessageIdentity(
          connectionId: fixture.connections[0].id,
          providerMessageId: "message-first"
        )
      ])
  }

  @MainActor
  @Test
  func testInboxViewModelRevalidatesSnoozesBeforePublishingUnifiedPhaseResults() async {
    let syncStarts = expectation(description: "both snooze syncs start")
    syncStarts.expectedFulfillmentCount = 2
    let phaseGate = UnifiedInboxPhaseGate { phase in
      if phase == .sync {
        syncStarts.fulfill()
      }
    }
    let fixture = makeUnifiedInboxViewModelFixture(phaseGate: phaseGate)
    let originalSnooze = StableThreadIdentity(
      connectionId: fixture.connections[1].id,
      providerThreadId: "thread-second"
    )
    let replacementSnooze = StableThreadIdentity(
      connectionId: fixture.connections[0].id,
      providerThreadId: "thread-first"
    )
    fixture.viewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: [],
        pinnedThreadIds: [],
        snoozedThreadIds: [originalSnooze]
      )
    )

    let loadTask = Task { @MainActor in
      await fixture.viewModel.loadUnifiedMailbox(.snoozed, connections: fixture.connections)
    }
    await fulfillment(of: [syncStarts], timeout: 1)
    fixture.viewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: [],
        pinnedThreadIds: [],
        snoozedThreadIds: [replacementSnooze]
      )
    )
    await phaseGate.release(.sync)
    await loadTask.value

    #expect(
      fixture.viewModel.threads.flatMap(\.messages).map(\.id) == [
        StableProviderMessageIdentity(
          connectionId: fixture.connections[0].id,
          providerMessageId: "message-first"
        )
      ])
  }

  @MainActor
  @Test
  func testInboxViewModelReprojectsUnifiedPinsFromCurrentPhaseData() async {
    let syncStarts = expectation(description: "both pin syncs start")
    syncStarts.expectedFulfillmentCount = 2
    let phaseGate = UnifiedInboxPhaseGate { phase in
      if phase == .sync {
        syncStarts.fulfill()
      }
    }
    let fixture = makeUnifiedInboxViewModelFixture(phaseGate: phaseGate)
    let originalPin = StableThreadIdentity(
      connectionId: fixture.connections[1].id,
      providerThreadId: "thread-second"
    )
    let replacementPin = StableThreadIdentity(
      connectionId: fixture.connections[0].id,
      providerThreadId: "thread-first"
    )
    fixture.viewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: [],
        pinnedThreadIds: [originalPin],
        snoozedThreadIds: []
      )
    )

    let loadTask = Task { @MainActor in
      await fixture.viewModel.loadUnifiedMailbox(.pins, connections: fixture.connections)
    }
    await fulfillment(of: [syncStarts], timeout: 1)
    fixture.viewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: [],
        pinnedThreadIds: [replacementPin],
        snoozedThreadIds: []
      )
    )
    await phaseGate.release(.sync)
    await loadTask.value

    #expect(
      fixture.viewModel.threads.flatMap(\.messages).map(\.id) == [
        StableProviderMessageIdentity(
          connectionId: fixture.connections[0].id,
          providerMessageId: "message-first"
        )
      ])
  }

  @MainActor
  @Test
  func testInboxViewModelLoadsAllUnifiedConnectionsBeforeHistoricalBackfill() async {
    let fixture = makeUnifiedInboxViewModelFixture(
      historicalMessagesByProviderAccount: [
        connection.providerAccountIdentifier: metadata(
          messageId: "message-first-historical",
          threadId: "thread-first-historical",
          internalDateMilliseconds: 50
        )
      ],
      delaysHistoricalBackfill: true
    )

    let loadTask = Task { @MainActor in
      await fixture.viewModel.loadUnifiedInbox(connections: fixture.connections)
    }
    await fixture.service.waitUntilHistoricalBackfillStarts()

    let syncInboxCallCount = await fixture.service.syncInboxCallCount()
    #expect(syncInboxCallCount == fixture.connections.count)
    #expect(Set(fixture.viewModel.threads.map(\.id.connectionId)).count == 2)
    #expect(!(fixture.viewModel.isLoading))
    #expect(!(fixture.viewModel.areCachedMetadataActionsDisabled))

    await fixture.service.releaseHistoricalBackfill()
    await loadTask.value
  }

  @MainActor
  @Test
  func testInboxViewModelLoadsUnifiedInboxPhasesConcurrently() async {
    let cacheStarts = expectation(description: "both cached inbox loads start")
    cacheStarts.expectedFulfillmentCount = 2
    let syncStarts = expectation(description: "both inbox syncs start")
    syncStarts.expectedFulfillmentCount = 2
    let backfillStarts = expectation(description: "both historical backfills start")
    backfillStarts.expectedFulfillmentCount = 2
    let phaseGate = UnifiedInboxPhaseGate { phase in
      switch phase {
      case .cache:
        cacheStarts.fulfill()
      case .sync:
        syncStarts.fulfill()
      case .backfill:
        backfillStarts.fulfill()
      case .navigation:
        break
      }
    }
    let fixture = makeUnifiedInboxViewModelFixture(
      historicalMessagesByProviderAccount: [
        "gmail-user-001": metadata(
          messageId: "message-first-historical",
          threadId: "thread-first-historical",
          internalDateMilliseconds: 300
        ),
        "gmail-user-002": metadata(
          messageId: "message-second-historical",
          threadId: "thread-second-historical",
          internalDateMilliseconds: 400,
          providerAccountIdentifier: "gmail-user-002"
        ),
      ],
      phaseGate: phaseGate
    )

    let loadTask = Task { @MainActor in
      await fixture.viewModel.loadUnifiedInbox(connections: fixture.connections)
    }

    await fulfillment(of: [cacheStarts], timeout: 1)
    #expect(fixture.viewModel.threads.isEmpty)
    await phaseGate.release(.cache)
    await fulfillment(of: [syncStarts], timeout: 1)
    #expect(fixture.viewModel.threads.map(\.providerThreadId) == ["thread-second", "thread-first"])
    await phaseGate.release(.sync)
    await fulfillment(of: [backfillStarts], timeout: 1)
    await phaseGate.release(.backfill)
    await loadTask.value

    #expect(fixture.viewModel.threads.map(\.providerThreadId) == ["thread-second", "thread-first"])
  }

  @MainActor
  @Test
  func testInboxViewModelRejectsStaleLoadBeforeStartingBackfill() async {
    let navigationStarts = expectation(description: "both navigation refreshes start")
    navigationStarts.expectedFulfillmentCount = 2
    let phaseGate = UnifiedInboxPhaseGate { phase in
      if phase == .navigation {
        navigationStarts.fulfill()
      }
    }
    let fixture = makeUnifiedInboxViewModelFixture(
      historicalMessagesByProviderAccount: [
        connection.providerAccountIdentifier: metadata(
          messageId: "message-first-historical",
          threadId: "thread-first-historical",
          internalDateMilliseconds: 50
        )
      ],
      delaysNavigationRefresh: true,
      phaseGate: phaseGate
    )

    let loadTask = Task { @MainActor in
      await fixture.viewModel.loadUnifiedInbox(connections: fixture.connections)
    }
    await phaseGate.release(.cache)
    await phaseGate.release(.sync)
    await fulfillment(of: [navigationStarts], timeout: 1)
    fixture.viewModel.clear()
    await phaseGate.release(.navigation)
    await loadTask.value

    let historicalBackfillCallCount = await fixture.service.historicalBackfillCallCount()
    #expect(historicalBackfillCallCount == 0)
    #expect(fixture.viewModel.threads.isEmpty)
  }

  @MainActor
  @Test
  func testInboxViewModelReportsConcurrentErrorsInConnectionOrder() async {
    let syncStarts = expectation(description: "both inbox syncs start")
    syncStarts.expectedFulfillmentCount = 2
    let phaseGate = UnifiedInboxPhaseGate { phase in
      if phase == .sync {
        syncStarts.fulfill()
      }
    }
    let fixture = makeUnifiedInboxViewModelFixture(
      syncErrorsByProviderAccount: [
        "gmail-user-001": "first failed",
        "gmail-user-002": "second failed",
      ],
      phaseGate: phaseGate
    )

    let loadTask = Task { @MainActor in
      await fixture.viewModel.loadUnifiedInbox(connections: fixture.connections)
    }
    await phaseGate.release(.cache)
    await fulfillment(of: [syncStarts], timeout: 1)
    await phaseGate.release(.sync, for: fixture.connections[1].id)
    await Task.yield()
    await phaseGate.release(.sync, for: fixture.connections[0].id)
    await loadTask.value

    #expect(
      fixture.viewModel.errorMessage
        == [
          "\(fixture.connections[0].displayName): first failed",
          "\(fixture.connections[1].displayName): second failed",
        ].joined(separator: "\n"))
  }

  @MainActor
  @Test
  func testInboxViewModelClearsLoadingWhenUnifiedLoadIsCancelled() async {
    let cacheStarts = expectation(description: "both cached inbox loads start")
    cacheStarts.expectedFulfillmentCount = 2
    let syncStarts = expectation(description: "inbox sync does not start")
    syncStarts.isInverted = true
    let phaseGate = UnifiedInboxPhaseGate { phase in
      switch phase {
      case .cache:
        cacheStarts.fulfill()
      case .sync:
        syncStarts.fulfill()
      case .backfill, .navigation:
        break
      }
    }
    let fixture = makeUnifiedInboxViewModelFixture(phaseGate: phaseGate)

    let loadTask = Task { @MainActor in
      await fixture.viewModel.loadUnifiedInbox(connections: fixture.connections)
    }
    await fulfillment(of: [cacheStarts], timeout: 1)
    loadTask.cancel()
    fixture.viewModel.clear()
    await phaseGate.release(.cache)
    await loadTask.value

    await fulfillment(of: [syncStarts], timeout: 0.1)
    #expect(!(fixture.viewModel.isLoading))
    #expect(fixture.viewModel.threads.isEmpty)
  }

  @MainActor
  @Test
  func testInboxViewModelRefreshesEveryAuthorizedMailboxConnectionInUnifiedInbox() async {
    let fixture = makeUnifiedInboxViewModelFixture()
    await fixture.viewModel.loadUnifiedInbox(connections: fixture.connections)
    let syncInboxCallCount = await fixture.service.syncInboxCallCount()
    let unauthorizedConnection = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: "authorization-required@example.com",
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: "gmail-user-003",
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
    .mailboxConnection(productAccountId: session.productAccountId, authorizationState: .authorized)
    .definition
    .mailboxConnection(
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )
    fixture.viewModel.errorMessage = "Previous refresh failed"

    await fixture.viewModel.loadUnifiedInbox(
      connections: fixture.connections + [unauthorizedConnection]
    )

    #expect(fixture.viewModel.errorMessage == nil)
    let refreshedSyncInboxCallCount = await fixture.service.syncInboxCallCount()
    #expect(refreshedSyncInboxCallCount == syncInboxCallCount + fixture.connections.count)
    #expect(fixture.viewModel.threads.map(\.providerThreadId) == ["thread-second", "thread-first"])
  }

  @MainActor
  @Test
  func testInboxViewModelRefreshesOneUnifiedInboxConnectionWithoutDroppingOthers() async {
    let fixture = makeUnifiedInboxViewModelFixture()
    await fixture.viewModel.loadUnifiedInbox(connections: fixture.connections)
    let syncInboxCallCount = await fixture.service.syncInboxCallCount()
    fixture.viewModel.errorMessage = "Previous refresh failed"

    let didRefresh = await fixture.viewModel.refresh(connection: fixture.connections[0])

    #expect(didRefresh)
    #expect(fixture.viewModel.errorMessage == nil)
    let refreshedSyncInboxCallCount = await fixture.service.syncInboxCallCount()
    #expect(refreshedSyncInboxCallCount == syncInboxCallCount + 1)
    #expect(fixture.viewModel.threads.map(\.providerThreadId) == ["thread-second", "thread-first"])
  }

  @MainActor
  @Test
  func testMailboxFreshnessLaunchRefreshesNewestPageForEveryAuthorizedConnection() async {
    let fixture = makeMailboxFreshnessFixture()
    let unauthorizedConnection = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: "authorization-required@example.com",
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: "gmail-user-003",
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
    .mailboxConnection(productAccountId: session.productAccountId, authorizationState: .authorized)
    .definition
    .mailboxConnection(
      productAccountId: session.productAccountId,
      trustedDeviceId: session.trustedDeviceId
    )

    await fixture.viewModel.synchronize(
      connections: fixture.connections + [unauthorizedConnection]
    )

    let recentConnectionIds = await fixture.service.recentlySyncedConnectionIds()
    let fullySyncedConnectionIds = await fixture.service.syncedConnectionIds()
    let reconciledConnectionIds = await fixture.service.reconciledConnectionIds()
    #expect(recentConnectionIds == fixture.connections.map(\.id))
    #expect(fullySyncedConnectionIds.isEmpty)
    #expect(reconciledConnectionIds.isEmpty)
    #expect(fixture.viewModel.status(for: unauthorizedConnection).phase == .authorizationRequired)
    for connection in fixture.connections {
      #expect(fixture.viewModel.status(for: connection).phase == .idle)
      #expect(fixture.viewModel.status(for: connection).lastSuccessfulSyncAt == fixture.now)
    }
    #expect(fixture.viewModel.lastSuccessfulSyncAt == fixture.now)
  }

  @MainActor
  @Test
  func testMailboxFreshnessManualRefreshRunsFullGmailReconciliation() async {
    let fixture = makeMailboxFreshnessFixture()

    await fixture.viewModel.synchronizeFully(connections: fixture.connections)

    let recentConnectionIds = await fixture.service.recentlySyncedConnectionIds()
    let fullySyncedConnectionIds = await fixture.service.syncedConnectionIds()
    #expect(recentConnectionIds.isEmpty)
    #expect(fullySyncedConnectionIds == fixture.connections.map(\.id))
  }

  @MainActor
  @Test
  func testMailboxFreshnessRowRefreshPreservesOtherConnectionState() async {
    let fixture = makeMailboxFreshnessFixture()
    let selectedConnection = fixture.connections[0]
    let preservedConnection = fixture.connections[1]
    fixture.viewModel.updateConnections(fixture.connections)
    fixture.viewModel.recordExternalSync(
      connectionIdRawValue: preservedConnection.id.rawValue,
      phase: .backfillPending,
      successfulSyncAt: fixture.now
    )
    let reloadPublished = expectation(description: "row synchronization reload published")
    let observer = NotificationCenter.default.addObserver(
      forName: .mailboxMetadataDidSynchronize,
      object: nil,
      queue: .main
    ) { notification in
      guard
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.connectionId]
          as? String == selectedConnection.id.rawValue,
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.reloadObservedMetadata]
          as? Bool == true,
        notification.userInfo?[
          MailboxSyncNotificationUserInfoKey.supersedesHistoricalBackfill
        ] as? Bool == false
      else { return }
      reloadPublished.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    await fixture.viewModel.synchronizeFully(
      connection: selectedConnection,
      among: fixture.connections
    )
    await fulfillment(of: [reloadPublished], timeout: 1)

    let syncedConnectionIds = await fixture.service.syncedConnectionIds()
    #expect(syncedConnectionIds == [selectedConnection.id])
    #expect(fixture.viewModel.status(for: preservedConnection).phase == .backfillPending)
    #expect(fixture.viewModel.status(for: preservedConnection).lastSuccessfulSyncAt == fixture.now)
  }

  @MainActor
  @Test
  func testMailboxFreshnessKeepsNonGmailForegroundSynchronizationUnchanged() async {
    let fixture = makeMailboxFreshnessFixture()
    let connection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: .imapRead,
      connectedAt: 1_781_200_000_000,
      displayName: "IMAP",
      id: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .imapSMTP,
          value: "imap@example.com"
        )
      ),
      lastVerifiedAt: 1_781_200_000_000,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1_781_200_000_000
    )

    await fixture.viewModel.synchronize(connections: [connection])

    let recentConnectionIds = await fixture.service.recentlySyncedConnectionIds()
    let fullySyncedConnectionIds = await fixture.service.syncedConnectionIds()
    #expect(recentConnectionIds.isEmpty)
    #expect(fullySyncedConnectionIds == [connection.id])
  }

  @MainActor
  @Test
  func testMailboxFreshnessCoalescesOverlappingSyncForOneConnection() async throws {
    let fixture = makeMailboxFreshnessFixture(suspendsSync: true)
    let connection = fixture.connections[0]
    fixture.viewModel.updateConnections([connection])

    let first = Task { @MainActor in
      try await fixture.viewModel.syncInbox(connection: connection, session: session)
    }
    await fixture.service.waitUntilSyncStarts()
    let second = Task { @MainActor in
      try await fixture.viewModel.syncInbox(connection: connection, session: session)
    }
    await Task.yield()

    let overlappingCallCount = await fixture.service.syncCallCount()
    #expect(overlappingCallCount == 1)

    await fixture.service.releaseSync()
    _ = try await first.value
    _ = try await second.value
    let completedCallCount = await fixture.service.syncCallCount()
    #expect(completedCallCount == 1)
  }

  @MainActor
  @Test
  func testMailboxFreshnessDoesNotCoalesceFullSyncOntoRecentSync() async throws {
    let fixture = makeMailboxFreshnessFixture(suspendsSync: true)
    let connection = fixture.connections[0]

    let recent = Task { @MainActor in
      await fixture.viewModel.synchronize(connections: [connection])
    }
    await fixture.service.waitUntilSyncStarts()
    let full = Task { @MainActor in
      try await fixture.viewModel.syncInbox(connection: connection, session: session)
    }
    await fixture.service.waitUntilSyncStarts(callCount: 2)

    let recentConnectionIds = await fixture.service.recentlySyncedConnectionIds()
    let fullConnectionIds = await fixture.service.syncedConnectionIds()
    #expect(recentConnectionIds == [connection.id])
    #expect(fullConnectionIds == [connection.id])

    await fixture.service.releaseSync()
    await recent.value
    _ = try await full.value
  }

  @MainActor
  @Test
  func testMailboxFreshnessKeepsSyncingStatusUntilEveryScopeFinishes() async throws {
    let fixture = makeMailboxFreshnessFixture(suspendsSync: true)
    let connection = fixture.connections[0]

    let recent = Task { @MainActor in
      await fixture.viewModel.synchronize(connections: [connection])
    }
    await fixture.service.waitUntilSyncStarts()
    let full = Task { @MainActor in
      try await fixture.viewModel.syncInbox(connection: connection, session: session)
    }
    await fixture.service.waitUntilSyncStarts(callCount: 2)

    await fixture.service.releaseNextSync()
    await recent.value
    #expect(fixture.viewModel.status(for: connection).phase == .syncing)

    await fixture.service.releaseNextSync()
    _ = try await full.value
    #expect(fixture.viewModel.status(for: connection).phase == .idle)
  }

  @MainActor
  @Test
  func testMailboxFreshnessKeepsCoalescedSyncRunningWhenFirstCallerIsCancelled() async throws {
    let fixture = makeMailboxFreshnessFixture(suspendsSync: true)
    let connection = fixture.connections[0]
    fixture.viewModel.updateConnections([connection])

    let first = Task { @MainActor in
      try await fixture.viewModel.syncInbox(connection: connection, session: session)
    }
    await fixture.service.waitUntilSyncStarts()
    let second = Task { @MainActor in
      try await fixture.viewModel.syncInbox(connection: connection, session: session)
    }
    first.cancel()
    await fixture.service.releaseSync()

    do {
      _ = try await first.value
      Issue.record("Expected cancelled caller to stop waiting for the shared sync")
    } catch is CancellationError {
    }
    _ = try await second.value

    let completedCallCount = await fixture.service.syncCallCount()
    #expect(completedCallCount == 1)
    #expect(fixture.viewModel.status(for: connection).lastSuccessfulSyncAt == fixture.now)
  }

  @MainActor
  @Test
  func testMailboxFreshnessForegroundRecoversAfterOfflineFailure() async {
    let fixture = makeMailboxFreshnessFixture(outcomes: [.offline, .success])
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])

    #expect(fixture.viewModel.status(for: connection).phase == .offline)
    #expect(fixture.viewModel.status(for: connection).lastSuccessfulSyncAt == nil)

    await fixture.viewModel.synchronize(connections: [connection])

    #expect(fixture.viewModel.status(for: connection).phase == .idle)
    #expect(fixture.viewModel.status(for: connection).lastSuccessfulSyncAt == fixture.now)
    let syncCallCount = await fixture.service.syncCallCount()
    #expect(syncCallCount == 2)
  }

  @MainActor
  @Test
  func testMailboxFreshnessForegroundCompletesReconciliationAfterMissedPush() async {
    let fixture = makeMailboxFreshnessFixture(
      outcomes: [.incomplete],
      suspendsBackfill: true
    )
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])
    await fixture.service.waitUntilHistoricalBackfillStarts()

    let reconciledConnectionIds = await fixture.service.reconciledConnectionIds()
    #expect(reconciledConnectionIds == [connection.id])
    #expect(fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id]))
    #expect(!(fixture.viewModel.isHistoricalBackfillRunning(for: [fixture.connections[1].id])))
    #expect(fixture.viewModel.status(for: connection).phase == .syncing)
    #expect(fixture.viewModel.status(for: connection).lastSuccessfulSyncAt == fixture.now)

    let statusPublished = expectation(description: "backfill completion status published")
    let observer = NotificationCenter.default.addObserver(
      forName: .mailboxMetadataDidSynchronize,
      object: nil,
      queue: .main
    ) { notification in
      guard
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.connectionId]
          as? String == connection.id.rawValue,
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.phase]
          as? MailboxSyncPhase == .idle,
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.successfulSyncAt] is Date
      else { return }
      statusPublished.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    await fixture.service.releaseHistoricalBackfill()
    await fulfillment(of: [statusPublished], timeout: 1)

    #expect(fixture.viewModel.status(for: connection).phase == .idle)
  }

  @MainActor
  @Test
  func testMailboxFreshnessDoesNotStartBackfillWithoutDurableCheckpoint() async {
    let fixture = makeMailboxFreshnessFixture(outcomes: [.incompleteWithoutCheckpoint])
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])

    let reconciledConnectionIds = await fixture.service.reconciledConnectionIds()
    #expect(reconciledConnectionIds.isEmpty)
    #expect(fixture.viewModel.status(for: connection).phase == .idle)
  }

  @MainActor
  @Test
  func testMailboxFreshnessForegroundResumesInterruptedHistoricalBackfill() async {
    let fixture = makeMailboxFreshnessFixture(
      outcomes: [.incomplete, .incomplete],
      suspendsBackfill: true
    )
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])
    await fixture.service.waitUntilHistoricalBackfillStarts()
    await fixture.viewModel.synchronize(connections: [connection])
    await fixture.service.waitUntilHistoricalBackfillStarts(callCount: 2)

    let recentConnectionIds = await fixture.service.recentlySyncedConnectionIds()
    let reconciledConnectionIds = await fixture.service.reconciledConnectionIds()
    #expect(recentConnectionIds == [connection.id, connection.id])
    #expect(reconciledConnectionIds == [connection.id, connection.id])

    await fixture.service.releaseHistoricalBackfill()
  }

  @MainActor
  @Test
  func testMailboxFreshnessRestoresPriorStatusWhenAutomaticBackfillIsPreempted() async {
    let fixture = makeMailboxFreshnessFixture(
      outcomes: [.incomplete],
      suspendsBackfill: true,
      cancelsBackfill: true
    )
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])
    await fixture.service.waitUntilHistoricalBackfillStarts()
    #expect(fixture.viewModel.status(for: connection).phase == .syncing)

    await fixture.service.releaseHistoricalBackfill()
    for _ in 0..<100
    where fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id]) {
      await Task.yield()
    }

    #expect(!(fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id])))
    #expect(fixture.viewModel.status(for: connection).phase == .idle)
    #expect(fixture.viewModel.status(for: connection).lastSuccessfulSyncAt == fixture.now)
  }

  @MainActor
  @Test
  func testMailboxFreshnessPreservesExternalStatusWhenAutomaticBackfillIsPreempted() async {
    let fixture = makeMailboxFreshnessFixture(
      outcomes: [.incomplete],
      suspendsBackfill: true,
      cancelsBackfill: true
    )
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])
    await fixture.service.waitUntilHistoricalBackfillStarts()
    fixture.viewModel.recordExternalSync(
      connectionIdRawValue: connection.id.rawValue,
      phase: .syncing,
      successfulSyncAt: nil,
      supersedesHistoricalBackfill: false
    )

    await fixture.service.releaseHistoricalBackfill()
    for _ in 0..<100
    where fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id]) {
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(!(fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id])))
    #expect(fixture.viewModel.status(for: connection).phase == .syncing)
  }

  @MainActor
  @Test
  func testMailboxFreshnessPreservesExternalStatusWhenAutomaticBackfillSucceeds() async {
    let fixture = makeMailboxFreshnessFixture(
      outcomes: [.incomplete],
      suspendsBackfill: true
    )
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])
    await fixture.service.waitUntilHistoricalBackfillStarts()
    fixture.viewModel.recordExternalSync(
      connectionIdRawValue: connection.id.rawValue,
      phase: .syncing,
      successfulSyncAt: nil
    )

    await fixture.service.releaseHistoricalBackfill()
    for _ in 0..<100
    where fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id]) {
      await Task.yield()
    }

    #expect(!(fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id])))
    #expect(fixture.viewModel.status(for: connection).phase == .syncing)
  }

  @MainActor
  @Test
  func testMailboxFreshnessFencesSuccessfulBackfillOncePushPreemptionBegins() async {
    let fixture = makeMailboxFreshnessFixture(
      outcomes: [.incomplete],
      suspendsBackfill: true
    )
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])
    await fixture.service.waitUntilHistoricalBackfillStarts()
    let reloadPublished = expectation(description: "completed backfill reload published")
    let observer = NotificationCenter.default.addObserver(
      forName: .mailboxMetadataDidSynchronize,
      object: nil,
      queue: .main
    ) { notification in
      guard
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.connectionId]
          as? String == connection.id.rawValue,
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.reloadObservedMetadata]
          as? Bool == true,
        notification.userInfo?[
          MailboxSyncNotificationUserInfoKey.supersedesHistoricalBackfill
        ] as? Bool == false
      else { return }
      reloadPublished.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    fixture.viewModel.recordExternalSync(
      connectionIdRawValue: connection.id.rawValue,
      phase: .syncing,
      successfulSyncAt: nil,
      supersedesHistoricalBackfill: false
    )
    fixture.viewModel.recordExternalSync(
      connectionIdRawValue: connection.id.rawValue,
      phase: .syncing,
      successfulSyncAt: nil
    )

    await fixture.service.releaseHistoricalBackfill()
    await fulfillment(of: [reloadPublished], timeout: 1)
    for _ in 0..<100
    where fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id]) {
      await Task.yield()
    }

    #expect(!(fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id])))
    #expect(fixture.viewModel.status(for: connection).phase == .syncing)
  }

  @MainActor
  @Test
  func testMailboxFreshnessPreservesExternalStatusWhenAutomaticBackfillFails() async {
    let fixture = makeMailboxFreshnessFixture(
      outcomes: [.incomplete],
      suspendsBackfill: true,
      failsBackfill: true
    )
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])
    await fixture.service.waitUntilHistoricalBackfillStarts()
    fixture.viewModel.recordExternalSync(
      connectionIdRawValue: connection.id.rawValue,
      phase: .syncing,
      successfulSyncAt: nil
    )

    await fixture.service.releaseHistoricalBackfill()
    for _ in 0..<100
    where fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id]) {
      await Task.yield()
    }

    #expect(!(fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id])))
    #expect(fixture.viewModel.status(for: connection).phase == .syncing)
  }

  @MainActor
  @Test
  func testMailboxFreshnessPreservesProvisionalExternalStatusWhenAutomaticBackfillFails() async {
    let fixture = makeMailboxFreshnessFixture(
      outcomes: [.incomplete],
      suspendsBackfill: true,
      failsBackfill: true
    )
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])
    await fixture.service.waitUntilHistoricalBackfillStarts()
    let reloadPublished = expectation(description: "failed backfill reload published")
    let observer = NotificationCenter.default.addObserver(
      forName: .mailboxMetadataDidSynchronize,
      object: nil,
      queue: .main
    ) { notification in
      guard
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.connectionId]
          as? String == connection.id.rawValue,
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.reloadObservedMetadata]
          as? Bool == true,
        notification.userInfo?[
          MailboxSyncNotificationUserInfoKey.supersedesHistoricalBackfill
        ] as? Bool == false
      else { return }
      reloadPublished.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    fixture.viewModel.recordExternalSync(
      connectionIdRawValue: connection.id.rawValue,
      phase: .syncing,
      successfulSyncAt: nil,
      supersedesHistoricalBackfill: false
    )

    await fixture.service.releaseHistoricalBackfill()
    await fulfillment(of: [reloadPublished], timeout: 1)
    for _ in 0..<100
    where fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id]) {
      await Task.yield()
    }

    #expect(!(fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id])))
    #expect(fixture.viewModel.status(for: connection).phase == .syncing)
  }

  @MainActor
  @Test
  func testMailboxFreshnessSettingsReloadDoesNotFenceAutomaticBackfillFailure() async {
    let fixture = makeMailboxFreshnessFixture(
      outcomes: [.incomplete],
      suspendsBackfill: true,
      failsBackfill: true
    )
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])
    await fixture.service.waitUntilHistoricalBackfillStarts()
    fixture.viewModel.recordExternalSync(
      connectionIdRawValue: connection.id.rawValue,
      phase: .syncing,
      successfulSyncAt: fixture.now,
      supersedesHistoricalBackfill: false,
      updatesExternalStatusRevision: false
    )

    await fixture.service.releaseHistoricalBackfill()
    for _ in 0..<100
    where fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id]) {
      await Task.yield()
    }

    #expect(!(fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id])))
    guard case .failed = fixture.viewModel.status(for: connection).phase else {
      Issue.record("Expected the originating backfill to publish its failure")
      return
    }
  }

  @MainActor
  @Test
  func testMailboxFreshnessPublishesBackfillAfterProvisionalExternalStatusEnds() async {
    let fixture = makeMailboxFreshnessFixture(
      outcomes: [.incomplete],
      suspendsBackfill: true,
      completesBackfill: false
    )
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])
    await fixture.service.waitUntilHistoricalBackfillStarts()
    for phase in [MailboxSyncPhase.syncing, .idle] {
      fixture.viewModel.recordExternalSync(
        connectionIdRawValue: connection.id.rawValue,
        phase: phase,
        successfulSyncAt: nil,
        supersedesHistoricalBackfill: false
      )
    }

    await fixture.service.releaseHistoricalBackfill()
    for _ in 0..<100
    where fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id]) {
      await Task.yield()
    }

    #expect(!(fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id])))
    #expect(fixture.viewModel.status(for: connection).phase == .backfillPending)
  }

  @MainActor
  @Test
  func testMailboxFreshnessActivePollUsesFiveMinuteInterval() async {
    let sleeper = OneShotMailboxPollSleeper()
    let fixture = makeMailboxFreshnessFixture(sleep: sleeper.sleep)
    var trustedDeviceRevalidationCount = 0

    await fixture.viewModel.pollWhileActive(
      connections: { fixture.connections },
      revalidateTrustedDevice: {
        trustedDeviceRevalidationCount += 1
        return true
      },
      didSynchronize: {}
    )

    let receivedDurations = await sleeper.receivedDurations()
    let syncCallCount = await fixture.service.syncCallCount()
    #expect(receivedDurations == [.seconds(300), .seconds(300)])
    #expect(trustedDeviceRevalidationCount == 1)
    #expect(syncCallCount == fixture.connections.count)
  }

  @MainActor
  @Test
  func testMailboxFreshnessActivePollSkipsSyncWhenRevalidationFails() async {
    let sleeper = OneShotMailboxPollSleeper()
    let fixture = makeMailboxFreshnessFixture(sleep: sleeper.sleep)

    await fixture.viewModel.pollWhileActive(
      connections: { fixture.connections },
      revalidateTrustedDevice: { false },
      didSynchronize: {}
    )

    let syncCallCount = await fixture.service.syncCallCount()
    #expect(syncCallCount == 0)
  }

  @MainActor
  @Test
  func testMailboxFreshnessCancelAllCancelsInFlightSync() async {
    let fixture = makeMailboxFreshnessFixture(suspendsSync: true)
    let connection = fixture.connections[0]
    let sync = Task { @MainActor in
      try await fixture.viewModel.syncInbox(connection: connection, session: session)
    }
    await fixture.service.waitUntilSyncStarts()

    fixture.viewModel.cancelAll()

    do {
      _ = try await sync.value
      Issue.record("Expected the in-flight mailbox synchronization to be cancelled")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected cancellation, got \(error)")
    }
    #expect(fixture.viewModel.status(for: connection).phase == .idle)
  }

  @MainActor
  @Test
  func testMailboxFreshnessRejectsSynchronizationAfterSessionChanges() async {
    let fixture = makeMailboxFreshnessFixture()
    fixture.sessionState.isCurrent = false

    await fixture.viewModel.synchronize(connections: fixture.connections)

    let syncCallCount = await fixture.service.syncCallCount()
    #expect(syncCallCount == 0)
  }

  @MainActor
  @Test
  func testMailboxFreshnessRestoresLastSuccessAcrossViewModels() async {
    let fixture = makeMailboxFreshnessFixture()
    let connection = fixture.connections[0]
    await fixture.viewModel.synchronize(connections: [connection])
    let restoredViewModel = MailboxFreshnessViewModel(
      service: fixture.service,
      session: session,
      isSessionCurrent: { _ in true },
      successStore: fixture.successStore
    )

    #expect(restoredViewModel.status(for: connection).lastSuccessfulSyncAt == fixture.now)
  }

  @MainActor
  @Test
  func testMailboxFreshnessClearsLastSuccessWhenConnectionIsRemoved() async {
    let fixture = makeMailboxFreshnessFixture()
    let connection = fixture.connections[0]
    await fixture.viewModel.synchronize(connections: [connection])

    fixture.viewModel.updateConnections([])

    #expect(
      fixture.successStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ) == nil)
  }

  @MainActor
  @Test
  func testMailboxFreshnessClearsLastSuccessRemovedBeforeViewModelStarts() {
    let fixture = makeMailboxFreshnessFixture()
    let removedConnection = fixture.connections[0]
    fixture.successStore.save(
      fixture.now,
      productAccountId: session.productAccountId,
      connectionId: removedConnection.id
    )

    fixture.viewModel.updateConnections([fixture.connections[1]])

    #expect(
      fixture.successStore.load(
        productAccountId: session.productAccountId,
        connectionId: removedConnection.id
      ) == nil)
  }

  @MainActor
  @Test
  func testMailboxFreshnessRetainsLastSuccessWhenConnectionsAreNotAuthoritative() async {
    let fixture = makeMailboxFreshnessFixture()
    let connection = fixture.connections[0]
    fixture.successStore.save(
      fixture.now,
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )

    fixture.viewModel.updateConnections([], prunesPersistedState: false)
    await fixture.viewModel.synchronize(connections: [])

    #expect(
      fixture.successStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ) == fixture.now)
  }

  @MainActor
  @Test
  func testMailboxFreshnessKeepsIncompleteBackfillVisible() async {
    let fixture = makeMailboxFreshnessFixture(
      outcomes: [.incomplete],
      suspendsBackfill: true,
      completesBackfill: false
    )
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])
    await fixture.service.waitUntilHistoricalBackfillStarts()
    let statusPublished = expectation(description: "pending backfill status published")
    let observer = NotificationCenter.default.addObserver(
      forName: .mailboxMetadataDidSynchronize,
      object: nil,
      queue: .main
    ) { notification in
      guard
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.connectionId]
          as? String == connection.id.rawValue,
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.phase]
          as? MailboxSyncPhase == .backfillPending
      else { return }
      statusPublished.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    await fixture.service.releaseHistoricalBackfill()
    await fulfillment(of: [statusPublished], timeout: 1)

    #expect(fixture.viewModel.status(for: connection).phase == .backfillPending)
  }

  @MainActor
  @Test
  func testMailboxFreshnessDirectBackfillCancellationRestoresPriorStatus() async {
    let fixture = makeMailboxFreshnessFixture(suspendsBackfill: true)
    let connection = fixture.connections[0]
    fixture.viewModel.updateConnections([connection])
    let backfill = Task { @MainActor in
      try await fixture.viewModel.continueHistoricalBackfill(
        connection: connection,
        session: session
      )
    }
    await fixture.service.waitUntilHistoricalBackfillStarts()
    #expect(fixture.viewModel.status(for: connection).phase == .syncing)

    backfill.cancel()

    do {
      _ = try await backfill.value
      Issue.record("Expected the historical backfill to be cancelled")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected cancellation, got \(error)")
    }
    #expect(fixture.viewModel.status(for: connection).phase == .idle)
  }

  @MainActor
  @Test
  func testMailboxFreshnessIgnoresCancelledBackfillFromOlderAuthorizationGeneration() async {
    let fixture = makeMailboxFreshnessFixture(
      suspendsBackfill: true,
      cancelsBackfill: true
    )
    let connection = fixture.connections[0]
    let replacement = connection.withAuthorizationGeneration(
      connection.authorizationGeneration + 1
    )
    fixture.viewModel.updateConnections([connection])
    let backfill = Task { @MainActor in
      try await fixture.viewModel.continueHistoricalBackfill(
        connection: connection,
        session: session
      )
    }
    await fixture.service.waitUntilHistoricalBackfillStarts()

    fixture.viewModel.updateConnections([replacement])
    fixture.viewModel.recordExternalSync(
      connectionIdRawValue: replacement.id.rawValue,
      phase: .syncing,
      successfulSyncAt: nil,
      supersedesHistoricalBackfill: false,
      updatesExternalStatusRevision: false
    )
    await fixture.service.releaseHistoricalBackfill()

    do {
      _ = try await backfill.value
      Issue.record("Expected the older-generation backfill to be cancelled")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected cancellation, got \(error)")
    }
    #expect(fixture.viewModel.status(for: replacement).phase == .syncing)
  }

  @MainActor
  @Test
  func testFailedSettingsLoadPreservesSharedHistoricalBackfill() async throws {
    let fixture = makeMailboxFreshnessFixture(suspendsBackfill: true)
    let connection = fixture.connections[0]
    fixture.viewModel.updateConnections([connection])
    let backfill = Task { @MainActor in
      try await fixture.viewModel.continueHistoricalBackfill(
        connection: connection,
        session: session
      )
    }
    await fixture.service.waitUntilHistoricalBackfillStarts()

    EmailAccountsSettingsView.updateFreshnessConnections(
      [],
      connectionsAreAuthoritative: false,
      freshnessViewModel: fixture.viewModel
    )
    await fixture.viewModel.synchronize(
      connections: [],
      snapshotIsAuthoritative: false
    )

    #expect(fixture.viewModel.isHistoricalBackfillActive(for: connection))
    await fixture.service.releaseHistoricalBackfill()
    _ = try await backfill.value
  }

  @MainActor
  @Test
  func testMailboxFreshnessPreemptsBackfillForForegroundSync() async throws {
    let fixture = makeMailboxFreshnessFixture(
      suspendsBackfill: true
    )
    let connection = fixture.connections[0]
    fixture.viewModel.updateConnections([connection])
    let backfill = Task { @MainActor in
      try await fixture.viewModel.continueHistoricalBackfill(
        connection: connection,
        session: session
      )
    }
    await fixture.service.waitUntilHistoricalBackfillStarts()
    let reloadPublished = expectation(description: "cancelled backfill reload published")
    let observer = NotificationCenter.default.addObserver(
      forName: .mailboxMetadataDidSynchronize,
      object: nil,
      queue: .main
    ) { notification in
      guard
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.connectionId]
          as? String == connection.id.rawValue,
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.reloadObservedMetadata]
          as? Bool == true,
        notification.userInfo?[
          MailboxSyncNotificationUserInfoKey.supersedesHistoricalBackfill
        ] as? Bool == false
      else { return }
      reloadPublished.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    _ = try await fixture.viewModel.syncInbox(connection: connection, session: session)
    await fulfillment(of: [reloadPublished], timeout: 1)

    let syncCallCount = await fixture.service.syncCallCount()
    #expect(syncCallCount == 1)
    #expect(fixture.viewModel.status(for: connection).phase == .idle)
    do {
      _ = try await backfill.value
      Issue.record("Expected foreground synchronization to cancel historical backfill")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected cancellation, got \(error)")
    }
  }

  @MainActor
  @Test
  func testMailboxFreshnessReloadsObservedMetadataAfterBackfillFailure() async {
    let fixture = makeMailboxFreshnessFixture(
      outcomes: [.incomplete],
      suspendsBackfill: true,
      failsBackfill: true
    )
    let connection = fixture.connections[0]
    await fixture.viewModel.synchronize(connections: [connection])
    await fixture.service.waitUntilHistoricalBackfillStarts()
    let statusPublished = expectation(description: "backfill failure reload published")
    let observer = NotificationCenter.default.addObserver(
      forName: .mailboxMetadataDidSynchronize,
      object: nil,
      queue: .main
    ) { notification in
      guard
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.connectionId]
          as? String == connection.id.rawValue,
        notification.userInfo?[MailboxSyncNotificationUserInfoKey.reloadObservedMetadata]
          as? Bool == true,
        let phase =
          notification.userInfo?[MailboxSyncNotificationUserInfoKey.phase] as? MailboxSyncPhase,
        case .failed = phase
      else { return }
      statusPublished.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    await fixture.service.releaseHistoricalBackfill()
    await fulfillment(of: [statusPublished], timeout: 1)

    guard case .failed = fixture.viewModel.status(for: connection).phase else {
      Issue.record("Expected the partial backfill failure to remain visible")
      return
    }
  }

  @Test
  func testMailboxConnectionSyncGateSerializesPushAndPollForOneConnection() async {
    let gate = MailboxConnectionSyncGate()
    let probe = MailboxSyncGateProbe()
    let connectionId = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    ).id
    let initialAcquired = await gate.acquire(connectionId)
    #expect(initialAcquired)
    let pollAttempted = expectation(description: "poll attempted to acquire sync gate")
    let poll = Task {
      pollAttempted.fulfill()
      let pollAcquired = await gate.acquire(connectionId)
      #expect(pollAcquired)
      await probe.markPollAcquired()
      await gate.release(connectionId)
    }
    await fulfillment(of: [pollAttempted], timeout: 1)
    for _ in 0..<10 {
      await Task.yield()
    }

    let acquiredDuringPush = await probe.pollAcquired
    #expect(!(acquiredDuringPush))

    await gate.release(connectionId)
    await poll.value
    let acquiredAfterPush = await probe.pollAcquired
    #expect(acquiredAfterPush)
  }

  @Test
  func testMailboxConnectionSyncGateKeepsLockWhenQueuedTaskIsCancelled() async {
    let gate = MailboxConnectionSyncGate()
    let probe = MailboxSyncGateProbe()
    let connectionId = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    ).id
    let initialAcquired = await gate.acquire(connectionId)
    #expect(initialAcquired)

    let cancelledWaiter = Task {
      try? await gate.withLock(connectionId) {
        await probe.markPollAcquired()
      }
    }
    for _ in 0..<10 {
      await Task.yield()
    }
    cancelledWaiter.cancel()
    await cancelledWaiter.value

    let nextWaiter = Task {
      let nextAcquired = await gate.acquire(connectionId)
      #expect(nextAcquired)
      await probe.markPollAcquired()
      await gate.release(connectionId)
    }
    for _ in 0..<10 {
      await Task.yield()
    }
    let acquiredBeforeRelease = await probe.pollAcquired
    #expect(!(acquiredBeforeRelease))

    await gate.release(connectionId)
    await nextWaiter.value
    let acquiredAfterRelease = await probe.pollAcquired
    #expect(acquiredAfterRelease)
  }

  @MainActor
  @Test
  func testInboxViewModelIgnoresOverrideResultAfterProviderAccountChanges() async {
    let originalMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    )
    let switchedConnection = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: "other@example.com",
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
    let switchedMessage = GmailMessageMetadata(
      categoryId: nil,
      from: "Other <other@example.com>",
      isHistorical: false,
      providerAccountIdentifier: switchedConnection.providerAccountIdentifier,
      providerInternalDateMilliseconds: 20,
      providerMessageId: "message-002",
      providerThreadId: "thread-002",
      replyTo: nil,
      snippet: "Other snippet",
      stableProviderMessageId: "gmail:gmail-user-002:message-002",
      subject: "Other subject",
      rfcMessageId: nil
    )
    let service = DelayedMailboxSwitchingService(
      messagesByProviderAccountIdentifier: [
        connection.providerAccountIdentifier: originalMessage,
        switchedConnection.providerAccountIdentifier: switchedMessage,
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    await viewModel.loadAfterConnectionChange(
      connection: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized)
    )

    let overrideTask = Task {
      await viewModel.overrideCategory(
        "system:invoices",
        for: originalMessage.mailboxMetadata(connectionId: originalMessage.mailboxConnectionId)
      )
    }
    await service.waitUntilOverrideStarts()
    await viewModel.loadAfterConnectionChange(
      connection: switchedConnection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized)
    )
    await service.releaseOverride()
    await overrideTask.value

    #expect(
      viewModel.threads
        == MailboxThread.group([
          switchedMessage.mailboxMetadata(connectionId: switchedMessage.mailboxConnectionId)
        ]))
  }

  @MainActor
  @Test
  func testInboxViewModelReloadsIndexedCacheWhenProviderSyncFailsAfterUpgrade() async {
    let cachedMessage = metadata(
      messageId: "message-cached",
      threadId: "thread-cached",
      internalDateMilliseconds: 1
    )
    let service = OfflineUpgradeMailboxService(cachedMessage: cachedMessage)
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )

    await viewModel.loadAfterConnectionChange(connection: mailboxConnection)

    #expect(
      viewModel.threads
        == MailboxThread.group([
          cachedMessage.mailboxMetadata(connectionId: mailboxConnection.id)
        ]))
    #expect(viewModel.errorMessage == "Provider unavailable.")
    let callCounts = await service.callCounts
    let navigationCallCounts = await service.navigationCallCounts
    #expect(callCounts.loadInbox == 2)
    #expect(navigationCallCounts.loadNavigation == 0)
    #expect(navigationCallCounts.loadProviderMailboxes == 0)
    #expect(callCounts.syncInbox == 1)
  }

  @MainActor
  @Test
  func testInboxViewModelDiscardsSyncErrorAfterConnectionChangesDuringCacheRecovery() async {
    let switchedConnection = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: "other@example.com",
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
    let switchedMessage = metadata(
      messageId: "message-switched",
      threadId: "thread-switched",
      internalDateMilliseconds: 2,
      providerAccountIdentifier: switchedConnection.providerAccountIdentifier
    )
    let service = StaleSyncRecoveryMailboxService(
      originalProviderAccountIdentifier: connection.providerAccountIdentifier,
      switchedMessage: switchedMessage
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let originalMailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let switchedMailboxConnection = switchedConnection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )

    let originalLoad = Task {
      await viewModel.loadAfterConnectionChange(connection: originalMailboxConnection)
    }
    await service.waitUntilRecoveryStarts()
    await viewModel.loadAfterConnectionChange(
      connection: switchedMailboxConnection,
      synchronizes: false
    )
    await service.releaseRecovery()
    await originalLoad.value

    #expect(
      viewModel.threads
        == MailboxThread.group([
          switchedMessage.mailboxMetadata(connectionId: switchedMailboxConnection.id)
        ]))
    #expect(viewModel.errorMessage == nil)
  }

  @MainActor
  @Test
  func testInboxViewModelLoadsInitialInboxBeforeNavigationMetadata() async {
    let service = RecordingMailboxFreshnessService(
      outcomes: [],
      suspendsSync: false,
      suspendsBackfill: false,
      completesBackfill: true,
      failsBackfill: false,
      cancelsBackfill: false
    )
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: RecordingGmailMessageSearchService(messages: []),
      session: session
    )

    await viewModel.loadInitialMailboxThenNavigation(
      connection: mailboxConnection,
      collection: .role(.inbox),
      connections: [mailboxConnection]
    )

    let loadedCollections = await service.loadedCollections()
    #expect(loadedCollections == [.role(.inbox), .allObserved, .allObserved])
  }

  @MainActor
  @Test
  func testStartupWaitsForEveryReplacementMailboxLoad() async {
    let firstLoad = OverrideGate()
    let secondLoad = OverrideGate()
    var generation = 1
    var currentTask: Task<Void, Never>? = Task {
      await firstLoad.waitForRelease()
    }
    var didFinishWaiting = false
    let waitTask = Task {
      await waitForCurrentMailboxLoad {
        (currentTask, generation)
      }
      didFinishWaiting = true
    }
    await firstLoad.waitUntilStarted()
    currentTask?.cancel()
    generation += 1
    currentTask = Task {
      await secondLoad.waitForRelease()
    }

    await firstLoad.release()
    await secondLoad.waitUntilStarted()
    await Task.yield()

    #expect(!(didFinishWaiting))

    await secondLoad.release()
    await waitTask.value

    #expect(didFinishWaiting)
  }

  @Test
  func testStartupDefersFailedActionReloadsUntilMailboxObserversAreActive() {
    let oldIds = [
      MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .gmail,
          value: "gmail-user-001"
        )
      )
    ]
    let newlyFailedId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .gmail,
        value: "gmail-user-002"
      )
    )
    let newIds = oldIds + [newlyFailedId]

    #expect(
      newlyFailedConnectionIds(
        from: oldIds,
        to: newIds,
        mailboxObserversAreActive: false
      ).isEmpty)
    #expect(
      newlyFailedConnectionIds(
        from: oldIds,
        to: newIds,
        mailboxObserversAreActive: true
      ) == [newlyFailedId])
  }

  @MainActor
  @Test
  func testInboxViewModelRetriesInitialInboxAfterNavigationCompletesIndexUpgrade() async {
    let cachedMessage = metadata(
      messageId: "message-cached",
      threadId: "thread-cached",
      internalDateMilliseconds: 1
    )
    let service = OfflineUpgradeMailboxService(
      cachedMessage: cachedMessage,
      completesIndexUpgradeDuringNavigation: true
    )
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )

    await viewModel.loadInitialMailboxThenNavigation(
      connection: mailboxConnection,
      collection: .role(.inbox),
      connections: [mailboxConnection]
    )

    #expect(
      viewModel.threads
        == MailboxThread.group([
          cachedMessage.mailboxMetadata(connectionId: mailboxConnection.id)
        ]))
    #expect(viewModel.errorMessage == nil)
    let callCounts = await service.callCounts
    let navigationCallCounts = await service.navigationCallCounts
    #expect(callCounts.loadInbox == 2)
    #expect(navigationCallCounts.loadNavigation == 1)
  }

  @MainActor
  @Test
  func testInboxViewModelDistinguishesLocalAndProviderSearchResults() async {
    let localMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    )
    let providerMessage = metadata(
      messageId: "message-002",
      threadId: "thread-002",
      internalDateMilliseconds: 20
    )
    let metadataService = DelayedMailboxSwitchingService(
      messagesByProviderAccountIdentifier: [
        connection.providerAccountIdentifier: localMessage
      ]
    )
    let searchService = RecordingGmailMessageSearchService(messages: [providerMessage])
    let viewModel = GmailInboxViewModel(
      service: metadataService,
      searchService: searchService,
      session: session
    )
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    await viewModel.loadAfterConnectionChange(connection: mailboxConnection)

    viewModel.searchQuery = "subject"
    viewModel.searchLocal(categoryNamesById: [:])

    #expect(viewModel.searchResult?.source == .localMetadata)
    #expect(
      viewModel.searchResult?.messages == [
        localMessage.mailboxMetadata(connectionId: mailboxConnection.id)
      ])

    viewModel.searchQuery = "private body phrase"
    await viewModel.searchProvider(connection: mailboxConnection)

    #expect(searchService.receivedQueries == ["private body phrase"])
    #expect(searchService.receivedConnections == [mailboxConnection])
    #expect(viewModel.searchResult?.source == .providerFullText)
    #expect(
      viewModel.searchResult?.messages == [
        providerMessage.mailboxMetadata(connectionId: mailboxConnection.id)
      ])
  }

  @MainActor
  @Test
  func testInboxViewModelKeepsCachedThreadsVisibleWhileHistoricalBackfillResumes() async {
    let cachedMessage = metadata(
      messageId: "message-cached",
      threadId: "thread-cached",
      internalDateMilliseconds: 1
    )
    let historicalMessage = metadata(
      messageId: "message-historical",
      threadId: "thread-historical",
      internalDateMilliseconds: 2
    )
    let service = DelayedMailboxSwitchingService(
      messagesByProviderAccountIdentifier: [
        connection.providerAccountIdentifier: cachedMessage
      ],
      historicalMessagesByProviderAccount: [
        connection.providerAccountIdentifier: historicalMessage
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )

    await viewModel.loadAfterConnectionChange(
      connection: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized)
    )

    #expect(
      viewModel.threads
        == MailboxThread.group([
          cachedMessage.mailboxMetadata(connectionId: cachedMessage.mailboxConnectionId)
        ]))
  }

  @MainActor
  @Test
  func testInboxViewModelStartsBodyPrefetchAfterPublishingInitialAvailability() async {
    let cachedMessage = metadata(
      messageId: "message-cached",
      threadId: "thread-cached",
      internalDateMilliseconds: 1
    )
    let service = DelayedMailboxSwitchingService(
      messagesByProviderAccountIdentifier: [
        connection.providerAccountIdentifier: cachedMessage
      ]
    )
    let prefetcher = DelayedMailboxBodyPrefetcher()
    let viewModel = GmailInboxViewModel(
      bodyPrefetcher: prefetcher,
      service: service,
      searchService: service,
      session: session
    )
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let pinnedThreadId = StableThreadIdentity(
      connectionId: mailboxConnection.id,
      providerThreadId: "thread-pinned"
    )
    viewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: [],
        pinnedThreadIds: [pinnedThreadId],
        snoozedThreadIds: []
      )
    )

    await viewModel.loadAfterConnectionChange(connection: mailboxConnection)
    await prefetcher.waitUntilStarted()

    #expect(
      viewModel.threads
        == MailboxThread.group([
          cachedMessage.mailboxMetadata(connectionId: cachedMessage.mailboxConnectionId)
        ]))
    #expect(!(viewModel.isBusy))
    let receivedConnectionIds = await prefetcher.receivedConnectionIds()
    #expect(receivedConnectionIds == [mailboxConnection.id])
    let receivedPinnedThreadIds = await prefetcher.receivedPinnedThreadIds()
    #expect(receivedPinnedThreadIds == [[pinnedThreadId]])
    await prefetcher.release()
  }

  @MainActor
  @Test
  func testInboxViewModelReprojectsUnifiedPinsImmediatelyAfterLocalPinChange() async {
    let cachedMessage = metadata(
      messageId: "message-cached",
      threadId: "thread-cached",
      internalDateMilliseconds: 1
    )
    let otherCachedMessage = metadata(
      messageId: "message-other",
      threadId: "thread-other",
      internalDateMilliseconds: 2
    )
    let otherConnection = GmailProviderConnectionStatus(
      connectedAt: 2,
      emailAddress: "other@example.com",
      lastVerifiedAt: 2,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 2
    )
    let service = DelayedMailboxSwitchingService(
      messagesByProviderAccountIdentifier: [
        connection.providerAccountIdentifier: cachedMessage,
        otherConnection.providerAccountIdentifier: otherCachedMessage,
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let otherMailboxConnection = otherConnection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )

    await viewModel.loadNavigation(connections: [mailboxConnection, otherMailboxConnection])
    await viewModel.loadUnifiedMailbox(
      .pins,
      connections: [mailboxConnection, otherMailboxConnection]
    )
    #expect(viewModel.threads.isEmpty)

    let pinnedThreadId = StableThreadIdentity(
      connectionId: mailboxConnection.id,
      providerThreadId: cachedMessage.providerThreadId
    )
    let otherPinnedThreadId = StableThreadIdentity(
      connectionId: otherMailboxConnection.id,
      providerThreadId: otherCachedMessage.providerThreadId
    )
    viewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: [],
        pinnedThreadIds: [pinnedThreadId, otherPinnedThreadId],
        snoozedThreadIds: []
      )
    )

    #expect(
      viewModel.threads
        == MailboxThread.group(
          [
            cachedMessage.mailboxMetadata(connectionId: mailboxConnection.id),
            otherCachedMessage.mailboxMetadata(connectionId: otherMailboxConnection.id),
          ]
        ))
  }

  @MainActor
  @Test
  func testInboxViewModelRefreshesBodyPrefetchAfterLocalPinChange() async {
    let service = DelayedMailboxSwitchingService(
      messagesByProviderAccountIdentifier: [:]
    )
    let prefetcher = DelayedMailboxBodyPrefetcher()
    let viewModel = GmailInboxViewModel(
      bodyPrefetcher: prefetcher,
      service: service,
      searchService: service,
      session: session
    )
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let pinnedThreadId = StableThreadIdentity(
      connectionId: mailboxConnection.id,
      providerThreadId: "thread-pinned"
    )
    viewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: [],
        pinnedThreadIds: [pinnedThreadId],
        snoozedThreadIds: []
      )
    )

    viewModel.refreshBodyPrefetch(
      afterChanging: [pinnedThreadId],
      connections: [mailboxConnection]
    )
    await prefetcher.waitUntilStarted()

    let receivedConnectionIds = await prefetcher.receivedConnectionIds()
    #expect(receivedConnectionIds == [mailboxConnection.id])
    let receivedPinnedThreadIds = await prefetcher.receivedPinnedThreadIds()
    #expect(receivedPinnedThreadIds == [[pinnedThreadId]])
    await prefetcher.release()
  }

  @MainActor
  @Test
  func testInboxViewModelRefreshesSynchronizedPinsAfterConnectionsLoad() async {
    let service = DelayedMailboxSwitchingService(
      messagesByProviderAccountIdentifier: [:]
    )
    let prefetcher = DelayedMailboxBodyPrefetcher()
    let viewModel = GmailInboxViewModel(
      bodyPrefetcher: prefetcher,
      service: service,
      searchService: service,
      session: session
    )
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let pinnedThreadId = StableThreadIdentity(
      connectionId: mailboxConnection.id,
      providerThreadId: "thread-pinned"
    )
    viewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: [],
        pinnedThreadIds: [pinnedThreadId],
        snoozedThreadIds: []
      )
    )

    viewModel.refreshPinnedBodyPrefetch(connections: [mailboxConnection])
    await prefetcher.waitUntilStarted()

    let receivedConnectionIds = await prefetcher.receivedConnectionIds()
    let receivedPinnedThreadIds = await prefetcher.receivedPinnedThreadIds()
    #expect(receivedConnectionIds == [mailboxConnection.id])
    #expect(receivedPinnedThreadIds == [[pinnedThreadId]])
    await prefetcher.release()
  }

  @MainActor
  @Test
  func testInboxViewModelDisablesRefreshButAllowsCachedActionsDuringHistoricalBackfill() async {
    let cachedMessage = metadata(
      messageId: "message-cached",
      threadId: "thread-cached",
      internalDateMilliseconds: 1
    )
    let historicalMessage = metadata(
      messageId: "message-historical",
      threadId: "thread-historical",
      internalDateMilliseconds: 2
    )
    let service = DelayedMailboxSwitchingService(
      messagesByProviderAccountIdentifier: [
        connection.providerAccountIdentifier: cachedMessage
      ],
      historicalMessagesByProviderAccount: [
        connection.providerAccountIdentifier: historicalMessage
      ],
      delaysHistoricalBackfill: true,
      loadResultIsIncomplete: true
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId, authorizationState: .authorized)

    await viewModel.loadAfterConnectionChange(connection: mailboxConnection)
    await service.waitUntilHistoricalBackfillStarts()

    #expect(viewModel.isRefreshDisabled)
    #expect(!(viewModel.areCachedMetadataActionsDisabled))
    #expect(viewModel.isHistoricalBackfillRunning)
    let syncInboxCallCount = await service.syncInboxCallCount()
    #expect(syncInboxCallCount == 0)

    await service.releaseHistoricalBackfill()

    let backfillCompletion = expectation(description: "historical backfill completes")
    Task { @MainActor in
      while viewModel.isRefreshDisabled {
        await Task.yield()
      }
      backfillCompletion.fulfill()
    }
    await fulfillment(of: [backfillCompletion], timeout: 1)

    #expect(!(viewModel.isRefreshDisabled))
    #expect(!(viewModel.areCachedMetadataActionsDisabled))
    #expect(!(viewModel.isHistoricalBackfillRunning))
  }

  @MainActor
  @Test
  func testInboxViewModelObservesCoordinatorHistoricalBackfill() async throws {
    let service = DelayedMailboxSwitchingService(
      messagesByProviderAccountIdentifier: [:],
      delaysHistoricalBackfill: true
    )
    let coordinator = MailboxFreshnessViewModel(
      service: service,
      session: session,
      isSessionCurrent: { _ in true }
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      syncCoordinator: coordinator,
      session: session
    )
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let currentConnection = GmailProviderConnectionStatus(
      connectedAt: 1,
      emailAddress: "current@example.com",
      lastVerifiedAt: 1,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-current",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1
    ).mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    coordinator.updateConnections([mailboxConnection, currentConnection])
    let backfill = Task { @MainActor in
      try await coordinator.continueHistoricalBackfill(
        connection: mailboxConnection,
        session: session
      )
    }
    await service.waitUntilHistoricalBackfillStarts()

    #expect(viewModel.isHistoricalBackfillRunning(for: [mailboxConnection]))
    #expect(
      MailShellThreadList.isUnifiedInboxRefreshDisabled(
        viewModel: viewModel,
        connections: [mailboxConnection],
        isConnectionBusy: false
      ))
    #expect(
      !(viewModel.areProviderActionsDisabledDuringHistoricalBackfill(for: [mailboxConnection])))
    #expect(
      viewModel.historicalBackfillConnectionIds(for: [mailboxConnection, currentConnection]) == [
        mailboxConnection.id
      ])

    await service.releaseHistoricalBackfill()
    _ = try await backfill.value
    #expect(!(viewModel.isHistoricalBackfillRunning(for: [mailboxConnection])))
  }

  @MainActor
  @Test
  func testInboxViewModelDisablesNonGmailActionsDuringHistoricalBackfill() async throws {
    let service = DelayedMailboxSwitchingService(
      messagesByProviderAccountIdentifier: [:],
      delaysHistoricalBackfill: true
    )
    let coordinator = MailboxFreshnessViewModel(
      service: service,
      session: session,
      isSessionCurrent: { _ in true }
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      syncCoordinator: coordinator,
      session: session
    )
    let gmailConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let graphConnection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: gmailConnection.capabilities,
      connectedAt: gmailConnection.connectedAt,
      displayName: "graph@example.com",
      id: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .microsoftGraph,
          value: "graph-user-001"
        )
      ),
      lastVerifiedAt: gmailConnection.lastVerifiedAt,
      productAccountId: gmailConnection.productAccountId,
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: gmailConnection.updatedAt
    )
    coordinator.updateConnections([graphConnection])
    let backfill = Task { @MainActor in
      try await coordinator.continueHistoricalBackfill(
        connection: graphConnection,
        session: session
      )
    }
    await service.waitUntilHistoricalBackfillStarts()

    #expect(viewModel.areProviderActionsDisabledDuringHistoricalBackfill(for: [graphConnection]))

    await service.releaseHistoricalBackfill()
    _ = try await backfill.value
  }

  @MainActor
  @Test
  func testInboxViewModelIsBusyWhileForwardBodyLoads() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let reader = DelayedMailboxMessageReader()
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized
      ).id
    )

    let loadTask = Task {
      try await viewModel.loadMessageBody(message, using: reader)
    }
    await reader.waitUntilLoadStarts()

    #expect(viewModel.isBusy)
    #expect(!(viewModel.hasLoadedMessageBodyText(for: message.id)))
    await reader.releaseLoad()
    let body = try await loadTask.value
    #expect(body == MailboxMessageBody(text: "Body"))
    #expect(!(viewModel.isBusy))
    #expect(viewModel.hasLoadedMessageBodyText(for: message.id))
    viewModel.discardLoadedMessageBodyPresentation(for: message.id)
    #expect(viewModel.loadedMessageBodyText(for: message.id) == "Body")
  }

  @MainActor
  @Test
  func testInboxViewModelSerializesBodyDecodingBeforePresentationAdmission() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let reader = DelayedMailboxMessageReader()
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-002",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)

    let firstLoad = Task { try await viewModel.loadMessageBody(firstMessage, using: reader) }
    await reader.waitUntilLoadStarts()
    let secondLoad = Task { try await viewModel.loadMessageBody(secondMessage, using: reader) }
    for _ in 0..<100 {
      await Task.yield()
    }

    #expect(reader.loadBodyCallCount == 1)

    await reader.releaseLoad()
    _ = try await firstLoad.value
    while reader.loadBodyCallCount < 2 {
      await Task.yield()
    }
    await reader.releaseLoad()
    _ = try await secondLoad.value
    #expect(reader.loadBodyCallCount == 2)
  }

  @MainActor
  @Test
  func testInboxViewModelReusesOpenedBodyTextForForwarding() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let reader = DelayedMailboxMessageReader()
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized
      ).id
    )

    let loadTask = Task {
      try await viewModel.loadMessageBody(message, using: reader)
    }
    await reader.waitUntilLoadStarts()
    await reader.releaseLoad()
    _ = try await loadTask.value

    let bodyText = try await viewModel.loadMessageBodyText(message, using: reader)

    #expect(bodyText == "Body")
    #expect(reader.loadBodyTextCallCount == 0)
  }

  @MainActor
  @Test
  func testInboxViewModelPrefetchesEveryVisibleMessageAndRetainsEnabledRemoteImages() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let body = MailboxMessageBody(
      text: "Newsletter",
      html: #"<p>Newsletter</p><img src="https://images.example.com/hero.png">"#
    )
    let reader = ImmediateMailboxMessageReader(
      bodies: [firstMessage.id: body, secondMessage.id: body]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let thread = try requireValue(MailboxThread.group([firstMessage, secondMessage]).first)
    var remoteLoadCallCount = 0
    var prefetchedHTML: SanitizedMessageHTML?

    await viewModel.prefetchVisibleMessageBodies(
      in: thread,
      loadsRemoteImages: true,
      using: reader
    ) { html, _, _ in
      remoteLoadCallCount += 1
      prefetchedHTML = prefetchedHTML ?? html
      return RemoteMessageContentLoadResult(
        failedImageCount: 0,
        html: html,
        loadedImageCount: 1
      )
    }
    await viewModel.prefetchVisibleMessageBodies(
      in: thread,
      loadsRemoteImages: true,
      using: reader
    ) { html, _, _ in
      Issue.record("Completed visible-message prefetch must be reused")
      return RemoteMessageContentLoadResult(
        failedImageCount: html.remoteImageReferences.count,
        html: html,
        loadedImageCount: 0
      )
    }
    let handedOffResult = try await viewModel.loadRemoteMessageContent(
      try requireValue(prefetchedHTML),
      for: firstMessage.id
    ) { html, _, _ in
      Issue.record("The message view must consume the visible-message prefetch")
      return RemoteMessageContentLoadResult(
        failedImageCount: html.remoteImageReferences.count,
        html: html,
        loadedImageCount: 0
      )
    }

    #expect(reader.loadedBodyMessageIds.count == 2)
    #expect(Set(reader.loadedBodyMessageIds) == Set([firstMessage.id, secondMessage.id]))
    #expect(remoteLoadCallCount == 2)
    #expect(handedOffResult.loadedImageCount == 1)
  }

  @MainActor
  @Test
  func testInboxViewModelPrefetchesVisibleBodiesWithoutRemoteImagesWhenDisabled() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .authorized
      ).id
    )
    let reader = ImmediateMailboxMessageReader(
      bodies: [
        message.id: MailboxMessageBody(
          text: "Newsletter",
          html: #"<img src="https://images.example.com/hero.png">"#
        )
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let thread = try requireValue(MailboxThread.group([message]).first)

    await viewModel.prefetchVisibleMessageBodies(
      in: thread,
      loadsRemoteImages: false,
      using: reader
    ) { html, _, _ in
      Issue.record("Disabled remote images must not be fetched")
      return RemoteMessageContentLoadResult(
        failedImageCount: html.remoteImageReferences.count,
        html: html,
        loadedImageCount: 0
      )
    }

    #expect(reader.loadedBodyMessageIds == [message.id])
  }

  @MainActor
  @Test
  func testInboxViewModelStopsVisibleBodyPrefetchAfterCancellation() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let reader = DelayedMailboxMessageReader(checksCancellationAfterRelease: true)
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let thread = try requireValue(MailboxThread.group([firstMessage, secondMessage]).first)
    #expect(viewModel.isLoadingMessageBody == false)
    let seedReader = ImmediateMailboxMessageReader(bodyTexts: [:])
    await viewModel.prefetchVisibleMessageBodies(
      in: thread,
      loadsRemoteImages: false,
      using: seedReader
    )
    #expect(seedReader.loadedBodyMessageIds == thread.messages.map(\.id))
    let prefetch = Task {
      await viewModel.prefetchVisibleMessageBodies(
        in: thread,
        loadsRemoteImages: true,
        using: reader
      )
    }
    await reader.waitUntilLoadStarts()

    prefetch.cancel()
    await reader.releaseLoad()
    await prefetch.value

    #expect(reader.loadBodyCallCount == 1)
    #expect(viewModel.isLoadingMessageBody == false)

    let reuseReader = ImmediateMailboxMessageReader(bodyTexts: [:])
    await viewModel.prefetchVisibleMessageBodies(
      in: thread,
      loadsRemoteImages: false,
      using: reuseReader
    )
    #expect(reuseReader.loadedBodyMessageIds.isEmpty)
  }

  @MainActor
  @Test
  func testInboxViewModelDoesNotStartGatedBodyLoadAfterCancellation() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let blockingReader = DelayedMailboxMessageReader()
    let cancelledReader = ImmediateMailboxMessageReader(bodyTexts: [:])
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-002",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let blockingLoad = Task {
      try await viewModel.loadMessageBody(firstMessage, using: blockingReader)
    }
    await blockingReader.waitUntilLoadStarts()
    let thread = try requireValue(MailboxThread.group([secondMessage]).first)
    let prefetch = Task {
      await viewModel.prefetchVisibleMessageBodies(
        in: thread,
        loadsRemoteImages: false,
        using: cancelledReader
      )
    }
    for _ in 0..<100 {
      await Task.yield()
    }

    prefetch.cancel()
    await blockingReader.releaseLoad()
    _ = try await blockingLoad.value
    await prefetch.value

    #expect(cancelledReader.loadedBodyMessageIds.isEmpty)
  }

  @MainActor
  @Test
  func testInboxViewModelBoundsOpenedBodyTextRetainedForForwarding() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-002",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let retainedText = String(repeating: "x", count: 3 * 1_024 * 1_024)
    let reader = ImmediateMailboxMessageReader(
      bodyTexts: [
        firstMessage.id: retainedText,
        secondMessage.id: retainedText,
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )

    _ = try await viewModel.loadMessageBody(firstMessage, using: reader)
    _ = try await viewModel.loadMessageBody(secondMessage, using: reader)
    let evictedBodyText = try await viewModel.loadMessageBodyText(firstMessage, using: reader)
    let retainedBodyText = try await viewModel.loadMessageBodyText(secondMessage, using: reader)

    #expect(evictedBodyText == "Provider body text")
    #expect(retainedBodyText == retainedText)
    #expect(reader.loadBodyTextCallCount == 1)
    #expect(viewModel.isLoadedMessageBodyTextUnavailable(for: firstMessage.id))
    #expect(!(viewModel.isLoadedMessageBodyTextUnavailable(for: secondMessage.id)))
  }

  @MainActor
  @Test
  func testInboxViewModelBoundsInlineImagePixelsAcrossLoadedBodies() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let maximumImagePixelCount = 16 * 1_024 * 1_024
    let firstBody = MailboxMessageBody(
      text: "First",
      inlineImages: [
        MailboxMessageInlineImage(
          contentID: "first@example.com",
          data: Data([1]),
          decodedPixelCount: maximumImagePixelCount,
          mimeType: "image/png"
        ),
        MailboxMessageInlineImage(
          contentID: "second@example.com",
          data: Data([2]),
          decodedPixelCount: maximumImagePixelCount,
          mimeType: "image/png"
        ),
      ]
    )
    let secondBody = MailboxMessageBody(
      text: "Second",
      inlineImages: [
        MailboxMessageInlineImage(
          contentID: "third@example.com",
          data: Data([3]),
          decodedPixelCount: 1,
          mimeType: "image/png"
        )
      ]
    )
    let reader = ImmediateMailboxMessageReader(
      bodies: [
        firstMessage.id: firstBody,
        secondMessage.id: secondBody,
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )

    let loadedFirstBody = try await viewModel.loadMessageBody(firstMessage, using: reader)
    let constrainedSecondBody = try await viewModel.loadMessageBody(secondMessage, using: reader)
    viewModel.discardLoadedMessageBodyPresentation(for: firstMessage.id)
    let reloadedSecondBody = try await viewModel.loadMessageBody(secondMessage, using: reader)

    #expect(loadedFirstBody.inlineImages.count == 2)
    #expect(constrainedSecondBody.inlineImages == [])
    #expect(reloadedSecondBody.inlineImages.map(\.contentID) == ["third@example.com"])
  }

  @MainActor
  @Test
  func testInboxViewModelBoundsInlineImageBytesAcrossLoadedBodies() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let imageData = Data(repeating: 1, count: 11 * 1_024 * 1_024)
    let reader = ImmediateMailboxMessageReader(
      bodies: [
        firstMessage.id: MailboxMessageBody(
          text: "First",
          inlineImages: [
            MailboxMessageInlineImage(
              contentID: "first@example.com",
              data: imageData,
              decodedPixelCount: 1,
              mimeType: "image/png"
            )
          ]
        ),
        secondMessage.id: MailboxMessageBody(
          text: "Second",
          inlineImages: [
            MailboxMessageInlineImage(
              contentID: "second@example.com",
              data: imageData,
              decodedPixelCount: 1,
              mimeType: "image/png"
            )
          ]
        ),
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )

    let loadedFirstBody = try await viewModel.loadMessageBody(firstMessage, using: reader)
    let constrainedSecondBody = try await viewModel.loadMessageBody(secondMessage, using: reader)
    viewModel.discardLoadedMessageBodyPresentation(for: firstMessage.id)
    let reloadedSecondBody = try await viewModel.loadMessageBody(secondMessage, using: reader)

    #expect(loadedFirstBody.inlineImages.map(\.contentID) == ["first@example.com"])
    #expect(constrainedSecondBody.inlineImages == [])
    #expect(reloadedSecondBody.inlineImages.map(\.contentID) == ["second@example.com"])
  }

  @MainActor
  @Test
  func testInboxViewModelBoundsAttachmentBytesAcrossLoadedBodies() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let firstAttachment = MailboxMessageAttachment(
      byteCount: 20 * 1_024 * 1_024,
      filename: "first.pdf",
      id: "first",
      mimeType: "application/pdf",
      presentationData: Data(repeating: 1, count: 20 * 1_024 * 1_024)
    )
    let secondAttachment = MailboxMessageAttachment(
      byteCount: 10 * 1_024 * 1_024,
      filename: "second.pdf",
      id: "inline-data-second-digest",
      mimeType: "application/pdf",
      presentationData: Data(repeating: 2, count: 10 * 1_024 * 1_024)
    )
    let reader = ImmediateMailboxMessageReader(
      bodies: [
        firstMessage.id: MailboxMessageBody(text: "First", attachments: [firstAttachment]),
        secondMessage.id: MailboxMessageBody(text: "Second", attachments: [secondAttachment]),
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )

    let loadedFirstBody = try await viewModel.loadMessageBody(firstMessage, using: reader)
    let constrainedSecondBody = try await viewModel.loadMessageBody(secondMessage, using: reader)
    viewModel.discardLoadedMessageBodyPresentation(for: firstMessage.id)
    let reloadedSecondBody = try await viewModel.loadMessageBody(secondMessage, using: reader)

    #expect(loadedFirstBody.attachments.map(\.id) == ["first"])
    #expect(constrainedSecondBody.attachments.map(\.id) == ["inline-data-second-digest"])
    #expect(constrainedSecondBody.attachments.first?.presentationData == nil)
    #expect(reloadedSecondBody.attachments.map(\.id) == ["inline-data-second-digest"])
    #expect(reloadedSecondBody.attachments.first?.presentationData != nil)
  }

  @MainActor
  @Test
  func testInboxViewModelReleasesImageReservationWhenReloadedBodyHasNoImages() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let imageData = Data(repeating: 1, count: 20 * 1_024 * 1_024)
    let firstReader = ImmediateMailboxMessageReader(
      bodies: [
        firstMessage.id: MailboxMessageBody(
          text: "First",
          inlineImages: [
            MailboxMessageInlineImage(
              contentID: "first@example.com",
              data: imageData,
              decodedPixelCount: 1,
              mimeType: "image/png"
            )
          ]
        )
      ]
    )
    let emptyReader = ImmediateMailboxMessageReader(
      bodies: [firstMessage.id: MailboxMessageBody(text: "Updated")]
    )
    let secondReader = ImmediateMailboxMessageReader(
      bodies: [
        secondMessage.id: MailboxMessageBody(
          text: "Second",
          inlineImages: [
            MailboxMessageInlineImage(
              contentID: "second@example.com",
              data: imageData,
              decodedPixelCount: 1,
              mimeType: "image/png"
            )
          ]
        )
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )

    _ = try await viewModel.loadMessageBody(firstMessage, using: firstReader)
    _ = try await viewModel.loadMessageBody(firstMessage, using: emptyReader)
    let secondBody = try await viewModel.loadMessageBody(secondMessage, using: secondReader)

    #expect(secondBody.inlineImages.map(\.contentID) == ["second@example.com"])
  }

  @MainActor
  @Test
  func testInboxViewModelSharesImageBudgetAcrossInlineAndRemotePresentations() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let thirdMessage = metadata(
      messageId: "message-003",
      threadId: "thread-001",
      internalDateMilliseconds: 30
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let reader = ImmediateMailboxMessageReader(
      bodies: [
        firstMessage.id: MailboxMessageBody(
          text: "First",
          inlineImages: [
            MailboxMessageInlineImage(
              contentID: "first@example.com",
              data: Data(repeating: 1, count: 12 * 1_024 * 1_024),
              decodedPixelCount: 1,
              mimeType: "image/png"
            )
          ]
        )
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let remoteReference = RemoteMessageImageReference(
      identifier: "remote-image-0",
      url: try requireValue(URL(string: "https://images.example.com/hero.png"))
    )
    let originalHTML = SanitizedMessageHTML(
      documentHTML:
        #"<html><body><img data-unwired-remote-image="remote-image-0"></body></html>"#,
      remoteImageReferences: [remoteReference]
    )
    let resolvedHTML = SanitizedMessageHTML(
      documentHTML: #"<html><body><img src="data:image/png;base64,AA=="></body></html>"#
    )

    _ = try await viewModel.loadMessageBody(firstMessage, using: reader)
    _ = try await viewModel.loadRemoteMessageContent(
      originalHTML,
      for: secondMessage.id
    ) { _, maximumByteCount, _ in
      #expect(maximumByteCount == 8 * 1_024 * 1_024)
      return RemoteMessageContentLoadResult(
        failedImageCount: 0,
        html: resolvedHTML,
        loadedByteCount: maximumByteCount,
        loadedImageCount: 1,
        loadedPixelCount: 1
      )
    }
    let constrainedResult = try await viewModel.loadRemoteMessageContent(
      originalHTML,
      for: thirdMessage.id
    ) { _, maximumByteCount, _ in
      #expect(maximumByteCount == 0)
      return RemoteMessageContentLoadResult(
        failedImageCount: 0,
        html: resolvedHTML,
        loadedByteCount: 1,
        loadedImageCount: 1,
        loadedPixelCount: 1
      )
    }
    viewModel.discardLoadedMessageBodyPresentation(for: firstMessage.id)
    let releasedResult = try await viewModel.loadRemoteMessageContent(
      originalHTML,
      for: thirdMessage.id
    ) { _, maximumByteCount, _ in
      #expect(maximumByteCount == 12 * 1_024 * 1_024)
      return RemoteMessageContentLoadResult(
        failedImageCount: 0,
        html: resolvedHTML,
        loadedByteCount: 1,
        loadedImageCount: 1,
        loadedPixelCount: 1
      )
    }
    viewModel.discardLoadedMessageBodies(connectionId: nil)
    _ = try await viewModel.loadRemoteMessageContent(
      originalHTML,
      for: secondMessage.id
    ) { _, _, _ in
      RemoteMessageContentLoadResult(
        failedImageCount: 0,
        html: resolvedHTML,
        loadedByteCount: 12 * 1_024 * 1_024,
        loadedImageCount: 1,
        loadedPixelCount: 1
      )
    }
    let reverseOrderConstrainedBody = try await viewModel.loadMessageBody(
      firstMessage, using: reader)

    #expect(constrainedResult.html == originalHTML)
    #expect(constrainedResult.loadedImageCount == 0)
    #expect(releasedResult.html == resolvedHTML)
    #expect(releasedResult.loadedImageCount == 1)
    #expect(reverseOrderConstrainedBody.inlineImages == [])
  }

  @MainActor
  @Test
  func testInboxViewModelSerializesConcurrentRemoteImageBudgetAdmission() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let reference = RemoteMessageImageReference(
      identifier: "remote-image-0",
      url: try requireValue(URL(string: "https://images.example.com/hero.png"))
    )
    let originalHTML = SanitizedMessageHTML(
      documentHTML: #"<img data-unwired-remote-image="remote-image-0">"#,
      remoteImageReferences: [reference]
    )
    let resolvedHTML = SanitizedMessageHTML(
      documentHTML: #"<img src="data:image/png;base64,AA==">"#
    )
    let probe = ConcurrentRemoteMessageContentLoadProbe()

    let firstLoad = Task { @MainActor in
      try await viewModel.loadRemoteMessageContent(
        originalHTML,
        for: firstMessage.id
      ) { _, maximumByteCount, _ in
        await probe.load(
          maximumByteCount: maximumByteCount,
          loadedByteCount: 12 * 1_024 * 1_024,
          resolvedHTML: resolvedHTML
        )
      }
    }
    await probe.waitUntilFirstLoadStarts()
    let secondLoad = Task { @MainActor in
      try await viewModel.loadRemoteMessageContent(
        originalHTML,
        for: secondMessage.id
      ) { _, maximumByteCount, _ in
        await probe.load(
          maximumByteCount: maximumByteCount,
          loadedByteCount: 8 * 1_024 * 1_024,
          resolvedHTML: resolvedHTML
        )
      }
    }
    for _ in 0..<100 {
      await Task.yield()
    }
    let requestCountWhileFirstLoadIsSuspended = await probe.requestCount
    #expect(requestCountWhileFirstLoadIsSuspended == 1)

    await probe.releaseFirstLoad()
    let firstResult = try await firstLoad.value
    let secondResult = try await secondLoad.value
    let requestedMaximumByteCounts = await probe.requestedMaximumByteCounts

    #expect(requestedMaximumByteCounts == [20 * 1_024 * 1_024, 8 * 1_024 * 1_024])
    #expect(firstResult.html == resolvedHTML)
    #expect(secondResult.html == resolvedHTML)
  }

  @MainActor
  @Test
  func testInboxViewModelSerializesInlineImageAdmissionWithRemoteLoads() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let remoteMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .authorized
      ).id
    )
    let inlineMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: remoteMessage.connectionId)
    let reader = ImmediateMailboxMessageReader(
      bodies: [
        inlineMessage.id: MailboxMessageBody(
          text: "Inline",
          inlineImages: [
            MailboxMessageInlineImage(
              contentID: "inline@example.com",
              data: Data(repeating: 1, count: 12 * 1_024 * 1_024),
              decodedPixelCount: 1,
              mimeType: "image/png"
            )
          ]
        )
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let reference = RemoteMessageImageReference(
      identifier: "remote-image-0",
      url: try requireValue(URL(string: "https://images.example.com/hero.png"))
    )
    let originalHTML = SanitizedMessageHTML(
      documentHTML: #"<img data-unwired-remote-image="remote-image-0">"#,
      remoteImageReferences: [reference]
    )
    let resolvedHTML = SanitizedMessageHTML(
      documentHTML: #"<img src="data:image/png;base64,AA==">"#
    )
    let probe = ConcurrentRemoteMessageContentLoadProbe()

    let remoteLoad = Task { @MainActor in
      try await viewModel.loadRemoteMessageContent(
        originalHTML,
        for: remoteMessage.id
      ) { _, maximumByteCount, _ in
        await probe.load(
          maximumByteCount: maximumByteCount,
          loadedByteCount: 12 * 1_024 * 1_024,
          resolvedHTML: resolvedHTML
        )
      }
    }
    await probe.waitUntilFirstLoadStarts()
    let inlineLoad = Task { @MainActor in
      try await viewModel.loadMessageBody(inlineMessage, using: reader)
    }
    for _ in 0..<100 {
      await Task.yield()
    }

    await probe.releaseFirstLoad()
    let remoteResult = try await remoteLoad.value
    let inlineBody = try await inlineLoad.value

    #expect(remoteResult.html == resolvedHTML)
    #expect(inlineBody.inlineImages == [])
  }

  @MainActor
  @Test
  func testInboxViewModelRemoteLoadDeadlineIncludesGateWait() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let reference = RemoteMessageImageReference(
      identifier: "remote-image-0",
      url: try requireValue(URL(string: "https://images.example.com/hero.png"))
    )
    let originalHTML = SanitizedMessageHTML(
      documentHTML: #"<img data-unwired-remote-image="remote-image-0">"#,
      remoteImageReferences: [reference]
    )
    let probe = ConcurrentRemoteMessageContentLoadProbe()
    var didStartSecondLoader = false

    let firstLoad = Task { @MainActor in
      try await viewModel.loadRemoteMessageContent(
        originalHTML,
        for: firstMessage.id
      ) { _, maximumByteCount, _ in
        await probe.load(
          maximumByteCount: maximumByteCount,
          loadedByteCount: 0,
          resolvedHTML: originalHTML
        )
      }
    }
    await probe.waitUntilFirstLoadStarts()
    let secondLoad = Task { @MainActor in
      try await viewModel.loadRemoteMessageContent(
        originalHTML,
        for: secondMessage.id,
        maximumLoadDuration: 0.01,
        using: { _, _, _ in
          didStartSecondLoader = true
          return RemoteMessageContentLoadResult(
            failedImageCount: 0,
            html: originalHTML,
            loadedImageCount: 1
          )
        })
    }
    let secondResult = try await secondLoad.value

    await probe.releaseFirstLoad()
    _ = try await firstLoad.value

    #expect(!(didStartSecondLoader))
    #expect(secondResult.failedImageCount == 1)
    #expect(secondResult.loadedImageCount == 0)
    #expect(secondResult.html == originalHTML)
  }

  @MainActor
  @Test
  func testInboxViewModelRemoteLoadCancellationReleasesGate() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let reference = RemoteMessageImageReference(
      identifier: "remote-image-0",
      url: try requireValue(URL(string: "https://images.example.com/hero.png"))
    )
    let originalHTML = SanitizedMessageHTML(
      documentHTML: #"<img data-unwired-remote-image="remote-image-0">"#,
      remoteImageReferences: [reference]
    )
    let probe = ConcurrentRemoteMessageContentLoadProbe()

    let firstLoad = Task { @MainActor in
      try await viewModel.loadRemoteMessageContent(
        originalHTML,
        for: firstMessage.id
      ) { _, maximumByteCount, _ in
        await probe.load(
          maximumByteCount: maximumByteCount,
          loadedByteCount: 0,
          resolvedHTML: originalHTML
        )
      }
    }
    await probe.waitUntilFirstLoadStarts()
    firstLoad.cancel()
    await probe.releaseFirstLoad()

    do {
      _ = try await firstLoad.value
      Issue.record("Cancelled remote load should throw")
    } catch is CancellationError {
    }

    let secondResult = try await viewModel.loadRemoteMessageContent(
      originalHTML,
      for: secondMessage.id
    ) { html, _, _ in
      RemoteMessageContentLoadResult(
        failedImageCount: 0,
        html: html,
        loadedImageCount: 1
      )
    }

    #expect(secondResult.loadedImageCount == 1)
  }

  @MainActor
  @Test
  func testInboxViewModelLoadsBodyWithoutInlineImagesWhileRemoteGateIsAcquired() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let remoteMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .authorized
      ).id
    )
    let plainMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: remoteMessage.connectionId)
    let reader = ImmediateMailboxMessageReader(
      bodies: [plainMessage.id: MailboxMessageBody(text: "Plain")]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let reference = RemoteMessageImageReference(
      identifier: "remote-image-0",
      url: try requireValue(URL(string: "https://images.example.com/hero.png"))
    )
    let originalHTML = SanitizedMessageHTML(
      documentHTML: #"<img data-unwired-remote-image="remote-image-0">"#,
      remoteImageReferences: [reference]
    )
    let probe = ConcurrentRemoteMessageContentLoadProbe()
    let bodyLoaded = expectation(description: "Body without inline images loaded")

    let remoteLoad = Task { @MainActor in
      try await viewModel.loadRemoteMessageContent(
        originalHTML,
        for: remoteMessage.id
      ) { _, maximumByteCount, _ in
        await probe.load(
          maximumByteCount: maximumByteCount,
          loadedByteCount: 0,
          resolvedHTML: originalHTML
        )
      }
    }
    await probe.waitUntilFirstLoadStarts()
    let plainLoad = Task { @MainActor in
      let body = try await viewModel.loadMessageBody(plainMessage, using: reader)
      bodyLoaded.fulfill()
      return body
    }
    await fulfillment(of: [bodyLoaded], timeout: 1)

    await probe.releaseFirstLoad()
    _ = try await remoteLoad.value
    let plainBody = try await plainLoad.value

    #expect(plainBody.text == "Plain")
  }

  @MainActor
  @Test
  func testInboxViewModelReleasesRemoteImageReservationsOnPolicyReset() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId,
        authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let firstReference = RemoteMessageImageReference(
      identifier: "remote-image-0",
      url: try requireValue(URL(string: "https://images.example.com/first.png"))
    )
    let retryReference = RemoteMessageImageReference(
      identifier: "remote-image-1",
      url: try requireValue(URL(string: "https://images.example.com/retry.png"))
    )
    let originalHTML = SanitizedMessageHTML(
      documentHTML: "<html><body></body></html>",
      remoteImageReferences: [firstReference, retryReference]
    )
    let partialHTML = SanitizedMessageHTML(
      documentHTML: "<html><body></body></html>",
      remoteImageReferences: [retryReference]
    )
    let resolvedHTML = SanitizedMessageHTML(documentHTML: "<html><body></body></html>")
    var requestedMaximumByteCounts: [Int] = []

    let firstResult = try await viewModel.loadRemoteMessageContent(
      originalHTML,
      for: firstMessage.id
    ) { _, maximumByteCount, _ in
      requestedMaximumByteCounts.append(maximumByteCount)
      return RemoteMessageContentLoadResult(
        failedImageCount: 1,
        html: partialHTML,
        loadedByteCount: 12 * 1_024 * 1_024,
        loadedImageCount: 1,
        loadedPixelCount: 12
      )
    }
    let retryResult = try await viewModel.loadRemoteMessageContent(
      partialHTML,
      for: firstMessage.id
    ) { _, maximumByteCount, _ in
      requestedMaximumByteCounts.append(maximumByteCount)
      return RemoteMessageContentLoadResult(
        failedImageCount: 0,
        html: resolvedHTML,
        loadedByteCount: maximumByteCount,
        loadedImageCount: 1,
        loadedPixelCount: 8
      )
    }
    viewModel.discardLoadedRemoteImages(for: firstMessage.id)
    let releasedResult = try await viewModel.loadRemoteMessageContent(
      originalHTML,
      for: secondMessage.id
    ) { _, maximumByteCount, _ in
      requestedMaximumByteCounts.append(maximumByteCount)
      return RemoteMessageContentLoadResult(
        failedImageCount: 2,
        html: originalHTML,
        loadedImageCount: 0
      )
    }

    #expect(
      requestedMaximumByteCounts == [20 * 1_024 * 1_024, 8 * 1_024 * 1_024, 20 * 1_024 * 1_024])
    #expect(firstResult.html == partialHTML)
    #expect(retryResult.html == resolvedHTML)
    #expect(releasedResult.loadedImageCount == 0)
  }

  @MainActor
  @Test
  func testInboxViewModelsShareRemoteImageBudgetAcrossWindows() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let isolatedSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: session.appleUserIdentifier,
      identityToken: session.identityToken,
      productAccountId: "shared-remote-image-budget-test",
      trustedDeviceId: session.trustedDeviceId
    )
    let firstViewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: isolatedSession
    )
    let secondViewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: isolatedSession
    )
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: isolatedSession.productAccountId,
        authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-002",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let reference = RemoteMessageImageReference(
      identifier: "remote-image-0",
      url: try requireValue(URL(string: "https://images.example.com/hero.png"))
    )
    let html = SanitizedMessageHTML(
      documentHTML: #"<img data-unwired-remote-image="remote-image-0">"#,
      remoteImageReferences: [reference]
    )
    var requestedMaximumByteCounts: [Int] = []

    _ = try await firstViewModel.loadRemoteMessageContent(
      html, for: firstMessage.id
    ) { _, maximumByteCount, _ in
      requestedMaximumByteCounts.append(maximumByteCount)
      return RemoteMessageContentLoadResult(
        failedImageCount: 0,
        html: SanitizedMessageHTML(documentHTML: "<html><body></body></html>"),
        loadedByteCount: 12 * 1_024 * 1_024,
        loadedImageCount: 1,
        loadedPixelCount: 12
      )
    }
    _ = try await secondViewModel.loadRemoteMessageContent(
      html, for: secondMessage.id
    ) { _, maximumByteCount, _ in
      requestedMaximumByteCounts.append(maximumByteCount)
      return RemoteMessageContentLoadResult(
        failedImageCount: 1,
        html: html,
        loadedImageCount: 0
      )
    }

    #expect(requestedMaximumByteCounts == [20 * 1_024 * 1_024, 8 * 1_024 * 1_024])
    firstViewModel.clear()
    secondViewModel.clear()
  }

  @MainActor
  @Test
  func testInboxViewModelChargesRepeatedInlineImagesToSharedByteBudget() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let repeatedImageData = Data(repeating: 1, count: 5 * 1_024 * 1_024)
    let repeatedImageHTML = String(
      repeating: #"<img src="cid:repeated@example.com">"#,
      count: 4
    )
    let reader = ImmediateMailboxMessageReader(
      bodies: [
        firstMessage.id: MailboxMessageBody(
          text: "First",
          html: repeatedImageHTML,
          inlineImages: [
            MailboxMessageInlineImage(
              contentID: "repeated@example.com",
              data: repeatedImageData,
              decodedPixelCount: 1,
              mimeType: "image/png"
            )
          ]
        ),
        secondMessage.id: MailboxMessageBody(
          text: "Second",
          inlineImages: [
            MailboxMessageInlineImage(
              contentID: "second@example.com",
              data: Data([2]),
              decodedPixelCount: 1,
              mimeType: "image/png"
            )
          ]
        ),
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )

    let loadedFirstBody = try await viewModel.loadMessageBody(firstMessage, using: reader)
    let constrainedSecondBody = try await viewModel.loadMessageBody(secondMessage, using: reader)

    #expect(loadedFirstBody.inlineImages.map(\.contentID) == ["repeated@example.com"])
    #expect(constrainedSecondBody.inlineImages == [])
  }

  @MainActor
  @Test
  func testInboxViewModelChargesRepeatedInlineImagesToSharedPixelBudget() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized
      ).id
    )
    let repeatedImageHTML = String(
      repeating: #"<img src="cid:repeated@example.com">"#,
      count: 2
    )
    let reader = ImmediateMailboxMessageReader(
      bodies: [
        message.id: MailboxMessageBody(
          text: "Body",
          html: repeatedImageHTML,
          inlineImages: [
            MailboxMessageInlineImage(
              contentID: "repeated@example.com",
              data: Data([1]),
              decodedPixelCount: 16 * 1_024 * 1_024,
              mimeType: "image/png"
            )
          ]
        )
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let originalHTML = SanitizedMessageHTML(
      documentHTML: #"<html><body><img data-unwired-remote-image="remote-image-0"></body></html>"#,
      remoteImageReferences: [
        RemoteMessageImageReference(
          identifier: "remote-image-0",
          url: try requireValue(URL(string: "https://images.example.com/hero.png"))
        )
      ]
    )

    _ = try await viewModel.loadMessageBody(message, using: reader)
    let result = try await viewModel.loadRemoteMessageContent(
      originalHTML,
      for: message.id
    ) { _, _, maximumPixelCount in
      #expect(maximumPixelCount == 0)
      return RemoteMessageContentLoadResult(
        failedImageCount: 0,
        html: originalHTML,
        loadedByteCount: 1,
        loadedImageCount: 1,
        loadedPixelCount: 1
      )
    }

    #expect(result.loadedImageCount == 0)
  }

  @MainActor
  @Test
  func testInboxViewModelIgnoresSanitizedAwayInlineImageOccurrencesInByteBudget() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let hiddenOccurrences = String(
      repeating: #"<div style="display: none"><img src="cid:repeated@example.com"></div>"#,
      count: 4
    )
    let reader = ImmediateMailboxMessageReader(
      bodies: [
        firstMessage.id: MailboxMessageBody(
          text: "First",
          html: #"<img src="cid:repeated@example.com">"# + hiddenOccurrences,
          inlineImages: [
            MailboxMessageInlineImage(
              contentID: "repeated@example.com",
              data: Data(repeating: 1, count: 5 * 1_024 * 1_024),
              decodedPixelCount: 1,
              mimeType: "image/png"
            )
          ]
        ),
        secondMessage.id: MailboxMessageBody(
          text: "Second",
          inlineImages: [
            MailboxMessageInlineImage(
              contentID: "second@example.com",
              data: Data(repeating: 2, count: 15 * 1_024 * 1_024),
              decodedPixelCount: 1,
              mimeType: "image/png"
            )
          ]
        ),
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )

    let loadedFirstBody = try await viewModel.loadMessageBody(firstMessage, using: reader)
    let loadedSecondBody = try await viewModel.loadMessageBody(secondMessage, using: reader)

    #expect(loadedFirstBody.inlineImages.map(\.contentID) == ["repeated@example.com"])
    #expect(loadedSecondBody.inlineImages.map(\.contentID) == ["second@example.com"])
  }

  @MainActor
  @Test
  func testInboxViewModelRetainsPixelReservationUntilClearedViewReleasesIt() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let isolatedSession = ProductAccountSessionSnapshot(
      appleUserIdentifier: session.appleUserIdentifier,
      identityToken: session.identityToken,
      productAccountId: "pixel-reservation-product-account",
      trustedDeviceId: session.trustedDeviceId
    )
    let firstMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: isolatedSession.productAccountId, authorizationState: .authorized
      ).id
    )
    let secondMessage = metadata(
      messageId: "message-002",
      threadId: "thread-001",
      internalDateMilliseconds: 20
    ).mailboxMetadata(connectionId: firstMessage.connectionId)
    let maximumImagePixelCount = 16 * 1_024 * 1_024
    let reader = ImmediateMailboxMessageReader(
      bodies: [
        firstMessage.id: MailboxMessageBody(
          text: "First",
          inlineImages: [
            MailboxMessageInlineImage(
              contentID: "first@example.com",
              data: Data([1]),
              decodedPixelCount: maximumImagePixelCount * 2,
              mimeType: "image/png"
            )
          ]
        ),
        secondMessage.id: MailboxMessageBody(
          text: "Second",
          inlineImages: [
            MailboxMessageInlineImage(
              contentID: "second@example.com",
              data: Data([2]),
              decodedPixelCount: 1,
              mimeType: "image/png"
            )
          ]
        ),
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: isolatedSession
    )

    _ = try await viewModel.loadMessageBody(firstMessage, using: reader)
    viewModel.markMessageBodyDisplayed(firstMessage.id)
    viewModel.discardLoadedMessageBodies(connectionId: firstMessage.connectionId)
    let constrainedSecondBody = try await viewModel.loadMessageBody(secondMessage, using: reader)
    viewModel.markMessageBodyHidden(firstMessage.id)
    viewModel.discardLoadedMessageBodyPresentation(for: firstMessage.id)
    let reloadedSecondBody = try await viewModel.loadMessageBody(secondMessage, using: reader)

    #expect(viewModel.loadedMessageBodyClearSignal(for: firstMessage.id) != nil)
    #expect(constrainedSecondBody.inlineImages == [])
    #expect(reloadedSecondBody.inlineImages.map(\.contentID) == ["second@example.com"])
  }

  @MainActor
  @Test
  func testInboxViewModelSignalsDisplayedFallbackBodyDuringBulkCacheRemoval() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized
      ).id
    )
    let reader = ImmediateMailboxMessageReader(
      bodies: [
        message.id: MailboxMessageBody(
          text: String(repeating: "x", count: 5 * 1_024 * 1_024 + 1),
          inlineImages: [
            MailboxMessageInlineImage(
              contentID: "image@example.com",
              data: Data([1]),
              decodedPixelCount: 1,
              mimeType: "image/png"
            )
          ]
        )
      ]
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    viewModel.markMessageBodyDisplayed(message.id)
    _ = try await viewModel.loadMessageBody(message, using: reader)
    viewModel.discardLoadedMessageBodyPresentation(for: message.id)

    viewModel.discardLoadedMessageBodies(connectionId: message.connectionId)

    #expect(viewModel.loadedMessageBodyClearSignal(for: message.id) != nil)
  }

  @MainActor
  @Test
  func testInboxViewModelDiscardsOpenedBodyTextWhenCachedBodyIsRemoved() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let reader = DelayedMailboxMessageReader()
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized
      ).id
    )

    let loadTask = Task {
      try await viewModel.loadMessageBody(message, using: reader)
    }
    await reader.waitUntilLoadStarts()
    await reader.releaseLoad()
    _ = try await loadTask.value

    viewModel.discardLoadedMessageBodyText(for: message.id)
    let bodyText = try await viewModel.loadMessageBodyText(message, using: reader)

    #expect(bodyText == "Text-only body")
    #expect(reader.loadBodyTextCallCount == 1)
    #expect(viewModel.isLoadedMessageBodyTextUnavailable(for: message.id))
  }

  @MainActor
  @Test
  func testInboxViewModelDiscardsOpenedBodyTextForClearedConnection() async throws {
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let reader = DelayedMailboxMessageReader()
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(
      connectionId: connection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized
      ).id
    )

    let loadTask = Task {
      try await viewModel.loadMessageBody(message, using: reader)
    }
    await reader.waitUntilLoadStarts()
    await reader.releaseLoad()
    _ = try await loadTask.value

    viewModel.discardLoadedMessageBodies(connectionId: message.id.connectionId)
    let bodyText = try await viewModel.loadMessageBodyText(message, using: reader)

    #expect(bodyText == "Text-only body")
    #expect(reader.loadBodyTextCallCount == 1)
    #expect(viewModel.isLoadedMessageBodyTextUnavailable(for: message.id))
  }

  @MainActor
  @Test
  func testInboxViewModelIgnoresProviderSearchResultsWhenQueryChanges() async {
    let providerMessage = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    )
    let metadataService = DelayedMailboxSwitchingService(
      messagesByProviderAccountIdentifier: [:]
    )
    let searchService = DelayedGmailMessageSearchService(messages: [providerMessage])
    let viewModel = GmailInboxViewModel(
      service: metadataService,
      searchService: searchService,
      session: session
    )
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    await viewModel.loadAfterConnectionChange(connection: mailboxConnection)

    viewModel.searchQuery = "invoice"
    let searchTask = Task {
      await viewModel.searchProvider(connection: mailboxConnection)
    }
    await searchService.waitUntilSearchStarts()
    #expect(searchService.receivedConnections == [mailboxConnection])
    viewModel.searchQuery = "flight"
    await searchService.releaseSearch()
    await searchTask.value

    #expect(viewModel.searchResult == nil)
  }

  @MainActor
  @Test
  func testInboxViewModelIgnoresHistoricalCategorizationErrorAfterProviderAccountChanges() async {
    let switchedConnection = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: "other@example.com",
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
    let service = DelayedMailboxSwitchingService(messagesByProviderAccountIdentifier: [:])
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    await viewModel.loadAfterConnectionChange(connection: mailboxConnection)

    let categorizationTask = Task {
      await viewModel.categorizeHistorical(
        scope: HistoricalCategorizationScope(
          receivedAtOrAfterMilliseconds: 0,
          receivedBeforeMilliseconds: 100
        ),
        connection: mailboxConnection
      )
    }
    await service.waitUntilHistoricalCategorizationStarts()
    await viewModel.loadAfterConnectionChange(
      connection: switchedConnection.mailboxConnection(
        productAccountId: session.productAccountId, authorizationState: .authorized)
    )
    await service.releaseHistoricalCategorization()
    await categorizationTask.value

    #expect(viewModel.errorMessage == nil)
  }

  @MainActor
  @Test
  func testInboxViewModelKeepsSnoozedThreadsHiddenAfterHistoricalCategorization() async {
    let mailboxConnection = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    )
    let message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    ).mailboxMetadata(connectionId: mailboxConnection.id)
    let result = MailboxMetadataSyncResult(
      hasUnlistedNewMessages: false,
      messages: [message],
      newMessageIds: nil,
      providerCursorIsExpired: false,
      threads: MailboxThread.group([message])
    )
    let service = DelayedMailboxSwitchingService(
      messagesByProviderAccountIdentifier: [:],
      historicalCategorizationResult: result
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session,
      productMailboxState: MailShellProductMailboxState(
        outboxStates: [],
        pinnedThreadIds: [],
        snoozedThreadIds: [message.threadIdentity]
      )
    )
    await viewModel.loadAfterConnectionChange(connection: mailboxConnection)

    await viewModel.categorizeHistorical(
      scope: HistoricalCategorizationScope(
        receivedAtOrAfterMilliseconds: 0,
        receivedBeforeMilliseconds: 100
      ),
      connection: mailboxConnection
    )

    #expect(viewModel.threads.isEmpty)
  }

  @Test
  func testSyncInboxUsesLatestConnectionUpdateAsFirstSyncHistoricalCutoff() async throws {
    let fixture = try makeSyncFixture()
    let switchedConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_180_000_000,
      emailAddress: connection.emailAddress,
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: 1_781_200_000_000
    )

    let result = try await fixture.service.syncInbox(
      connection: switchedConnection,
      session: session
    )

    #expect(result.messages.allSatisfy { $0.isHistorical })
  }

  @Test
  func testHistoricalBackfillReusesInitialSyncHistoricalCutoff() async throws {
    let fixture = try makeSyncFixture(usesPagination: true)
    let reconnectedConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_180_000_000,
      emailAddress: connection.emailAddress,
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: 1_781_180_000_000
    )

    _ = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )
    let result = try await fixture.service.continueHistoricalBackfill(
      connection: reconnectedConnection,
      session: session
    )

    #expect(result.messages.first { $0.providerMessageId == "message-001" }?.isHistorical == true)
  }

  @Test
  func testSyncInboxPreservesExistingHistoricalStateWhenRefreshingMetadata() async throws {
    let fixture = try makeSyncFixture()
    fixture.store.messages = [
      metadata(
        messageId: "message-002",
        threadId: "thread-001",
        internalDateMilliseconds: 1_781_197_200_000
      )
    ]
    let connectionWithOlderCutoff = GmailProviderConnectionStatus(
      connectedAt: 1_781_180_000_000,
      emailAddress: connection.emailAddress,
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: 1_781_200_000_000
    )

    let result = try await fixture.service.syncInbox(
      connection: connectionWithOlderCutoff,
      session: session
    )

    #expect(result.messages.first { $0.providerMessageId == "message-002" }?.isHistorical == true)
  }

  @Test
  func testSyncInboxCategorizesAndPersistsMessagesAfterAccountInstall() async throws {
    let categorizer = RecordingGmailMessageCategorizer(categoryId: "system:promotions")
    let fixture = try makeSyncFixture(categorizer: categorizer)
    let installedConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_100_000_000,
      emailAddress: connection.emailAddress,
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: 1_781_100_000_000
    )

    let result = try await fixture.service.syncInbox(
      connection: installedConnection,
      session: session
    )

    #expect(categorizer.receivedMessages.allSatisfy { !$0.isHistorical })
    #expect(
      categorizer.receivedMessages.map(\.stableProviderMessageId) == [
        "gmail:gmail-user-001:message-002", "gmail:gmail-user-001:message-001",
      ])
    #expect(result.messages.allSatisfy { $0.categoryId == "system:promotions" })
    #expect(fixture.store.savedMessages == result.messages)
  }

  @Test
  func testSyncInboxDoesNotCategorizeNonInboxMessages() async throws {
    let categorizer = RecordingGmailMessageCategorizer(categoryId: "system:promotions")
    let fixture = try makeSyncFixture(
      categorizer: categorizer,
      messageIdsWithoutLabelIds: ["message-002"]
    )
    let installedConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_100_000_000,
      emailAddress: connection.emailAddress,
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: 1_781_100_000_000
    )

    _ = try await fixture.service.syncInbox(
      connection: installedConnection,
      session: session
    )

    #expect(categorizer.receivedMessages.map(\.providerMessageId) == ["message-001"])
    let savedMessageTwo = try requireValue(
      fixture.store.savedMessages.first { $0.providerMessageId == "message-002" })
    #expect(savedMessageTwo.categoryId == nil)
  }

  @Test
  func testSyncInboxRetainsIncompleteBackfillCutoffWhenRefreshingNewestPage() async throws {
    let fixture = try makeSyncFixture(usesPagination: true)
    let reconnectedConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_000_000_000,
      emailAddress: connection.emailAddress,
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: 1_781_100_000_000
    )

    _ = try await fixture.service.syncInbox(connection: reconnectedConnection, session: session)
    let refreshedConnection = GmailProviderConnectionStatus(
      connectedAt: reconnectedConnection.connectedAt,
      emailAddress: reconnectedConnection.emailAddress,
      lastVerifiedAt: reconnectedConnection.lastVerifiedAt,
      provider: reconnectedConnection.provider,
      providerAccountIdentifier: reconnectedConnection.providerAccountIdentifier,
      trustedDeviceId: reconnectedConnection.trustedDeviceId,
      updatedAt: reconnectedConnection.updatedAt + 1
    )
    _ = try await fixture.service.syncInbox(connection: refreshedConnection, session: session)

    #expect(
      fixture.store.syncState?.initialHistoricalCutoffMilliseconds
        == reconnectedConnection.updatedAt)
  }

  @Test
  func testSyncInboxFollowsGmailPaginationBeforeSavingMetadata() async throws {
    let fixture = try makeSyncFixture(usesPagination: true)

    let initial = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )
    #expect(initial.hasInitialMailboxAvailability)
    #expect(!(initial.historicalMetadataBackfillIsComplete))
    #expect(initial.messages.map(\.providerMessageId) == ["message-003", "message-002"])
    let result = try await fixture.service.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    #expect(result.historicalMetadataBackfillIsComplete)
    #expect(
      result.messages.map(\.providerMessageId) == [
        "message-003",
        "message-002",
        "message-001",
      ])
    #expect(
      fixture.requestRecorder.queries.filter { $0.contains("maxResults=50") } == [
        "maxResults=50&includeSpamTrash=true",
        "maxResults=50&includeSpamTrash=true&pageToken=next-page-token",
      ])
    #expect(
      fixture.store.savedMessages.map(\.providerMessageId) == [
        "message-003",
        "message-002",
        "message-001",
      ])
  }

  @Test
  func testLoadInboxDoesNotTreatCheckpointlessCachedMessagesAsComplete() async throws {
    let fixture = try makeSyncFixture()
    fixture.store.messages = [
      metadata(
        messageId: "message-001",
        threadId: "thread-001",
        internalDateMilliseconds: 1
      )
    ]

    let result = try await fixture.service.loadInbox(connection: connection, session: session)

    #expect(result.hasInitialMailboxAvailability)
    #expect(!(result.historicalMetadataBackfillIsComplete))
  }

  @Test
  func testCheckpointlessCachedMessagesStartWithNewestPageSync() async throws {
    let fixture = try makeSyncFixture(usesPagination: true)
    fixture.store.messages = [
      metadata(
        messageId: "cached-message",
        threadId: "cached-thread",
        internalDateMilliseconds: 1
      )
    ]

    let result = try await fixture.service.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    #expect(result.hasInitialMailboxAvailability)
    #expect(result.historicalMetadataBackfillIsComplete)
    #expect(
      fixture.requestRecorder.queries.filter { $0.contains("maxResults=50") } == [
        "maxResults=50&includeSpamTrash=true",
        "maxResults=50&includeSpamTrash=true&pageToken=next-page-token",
      ])
    #expect(fixture.store.syncState != nil)
  }

  @Test
  func testSyncInboxRefreshesNewestMessagesBeforeResumingBackfill() async throws {
    let fixture = try makeSyncFixture(usesPagination: true)

    _ = try await fixture.service.syncInbox(connection: connection, session: session)
    fixture.requestRecorder.queries = []

    let result = try await fixture.service.syncInbox(connection: connection, session: session)

    #expect(!(result.historicalMetadataBackfillIsComplete))
    #expect(
      fixture.requestRecorder.queries.filter { $0.contains("maxResults=50") } == [
        "maxResults=50&includeSpamTrash=true"
      ])
  }

  @Test
  func testHistoricalBackfillDefersInLowPowerAndResumesFromSavedPage() async throws {
    var shouldContinueBackfill = false
    let fixture = try makeSyncFixture(
      usesPagination: true,
      shouldContinueHistoricalBackfill: { shouldContinueBackfill }
    )
    _ = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    let deferred = try await fixture.service.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    #expect(!(deferred.historicalMetadataBackfillIsComplete))
    #expect(
      fixture.requestRecorder.queries.filter { $0.contains("maxResults=50") } == [
        "maxResults=50&includeSpamTrash=true"
      ])

    shouldContinueBackfill = true
    let resumed = try await fixture.service.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    #expect(resumed.historicalMetadataBackfillIsComplete)
    #expect(
      resumed.messages.map(\.providerMessageId) == [
        "message-003", "message-002", "message-001",
      ])
  }

  @Test
  func testHistoricalBackfillContinuesAfterResettingRejectedPageToken() async throws {
    let fixture = try makeSyncFixture(
      usesPagination: true,
      rejectsFirstHistoricalPageToken: true
    )
    _ = try await fixture.service.syncInbox(connection: connection, session: session)

    let result = try await fixture.service.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    #expect(result.historicalMetadataBackfillIsComplete)
    #expect(
      result.messages.map(\.providerMessageId) == ["message-003", "message-002", "message-001"])
    #expect(
      fixture.requestRecorder.queries.filter { $0.contains("maxResults=50") } == [
        "maxResults=50&includeSpamTrash=true",
        "maxResults=50&includeSpamTrash=true&pageToken=next-page-token",
        "maxResults=50&includeSpamTrash=true",
        "maxResults=50&includeSpamTrash=true&pageToken=next-page-token",
      ])
  }

  @Test
  func testHistoricalBackfillKeepsCheckpointAfterGenericPageFailure() async throws {
    let fixture = try makeSyncFixture(
      usesPagination: true,
      rejectsFirstHistoricalPageToken: true,
      rejectedPageTokenResponseData: Data()
    )
    _ = try await fixture.service.syncInbox(connection: connection, session: session)

    do {
      _ = try await fixture.service.continueHistoricalBackfill(
        connection: connection,
        session: session
      )
      Issue.record("Expected the generic Gmail request failure to preserve the checkpoint.")
    } catch {
      #expect(error as? GmailMessageMetadataSyncError == .gmailRequestFailed)
    }

    #expect(fixture.store.syncState?.nextPageToken == "next-page-token")
  }

  @Test
  func testHistoricalBackfillStoresNonInboxMetadataWithoutShowingItInInbox() async throws {
    let fixture = try makeSyncFixture(
      usesPagination: true,
      messageIdsWithoutLabelIds: ["message-001"]
    )
    _ = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    let result = try await fixture.service.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    #expect(result.messages.map(\.providerMessageId) == ["message-003", "message-002"])
    #expect(
      fixture.store.savedMessages.map(\.providerMessageId) == [
        "message-003", "message-002", "message-001",
      ])
  }

  @Test
  func testHistoricalBackfillDoesNotCategorizeNonInboxMessages() async throws {
    let categorizer = RecordingGmailMessageCategorizer(categoryId: "system:promotions")
    let fixture = try makeSyncFixture(
      categorizer: categorizer,
      usesPagination: true,
      messageIdsWithoutLabelIds: ["message-001"]
    )
    _ = try await fixture.service.syncInbox(connection: connection, session: session)

    _ = try await fixture.service.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    #expect(categorizer.receivedMessages.isEmpty)
    let savedMessageOne = try requireValue(
      fixture.store.savedMessages.first { $0.providerMessageId == "message-001" })
    #expect(savedMessageOne.categoryId == nil)
  }

  @Test
  func testSyncInboxRejectsRefreshedTokenForDifferentGoogleAccount() async throws {
    let fixture = try makeSyncFixture(
      tokenInfoSubject: "different-gmail-user",
      usesLegacyTokens: true
    )

    do {
      _ = try await fixture.service.syncInbox(
        connection: connection,
        session: session
      )
      Issue.record("Expected refreshed token account mismatch")
    } catch GmailMessageMetadataSyncError.refreshedTokenAccountMismatch {
      #expect(fixture.store.savedMessages == [])
      #expect(
        try fixture.tokenStore.load(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        ) == nil)
      #expect(try fixture.tokenStore.loadLegacy(productAccountId: session.productAccountId) != nil)
      #expect(!(fixture.requestRecorder.paths.contains("/gmail/v1/users/me/messages")))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testSyncInboxRequiresDeviceHeldGmailTokens() async throws {
    let service = GmailMessageMetadataService(
      session: ConvexClientTesting.makeSession(
        protocolClass: GmailMetadataURLStub.self
      ) { request in
        Issue.record("Unexpected request: \(String(describing: request.url))")
        return (Self.httpResponse(for: request, statusCode: 200), Data())
      },
      store: RecordingGmailMessageMetadataStore(),
      tokenStore: RecordingGmailProviderTokenStore()
    )

    do {
      _ = try await service.syncInbox(
        connection: connection,
        session: session
      )
      Issue.record("Expected missing local tokens")
    } catch GmailMessageMetadataSyncError.missingLocalGmailTokens {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func testSyncInboxMigratesLegacyDeviceHeldGmailTokens() async throws {
    let fixture = try makeSyncFixture(usesLegacyTokens: true)

    _ = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    #expect(
      try fixture.tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
        == GmailProviderTokens(
          accessToken: "refreshed-access-token",
          refreshToken: "refresh-token"
        ))
    #expect(try fixture.tokenStore.loadLegacy(productAccountId: session.productAccountId) == nil)
  }

  @Test
  func testProviderActionsUseGmailModifyAndTrashEndpoints() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.perform(
      .markUnread,
      messageIds: ["message-001"],
      connection: connection,
      session: session
    )
    try await fixture.service.perform(
      .delete,
      messageIds: ["message-001"],
      connection: connection,
      session: session
    )
    try await fixture.service.perform(
      .move(
        sourceProviderMailboxId: "Label_source",
        targetProviderMailboxId: "Label_projects"
      ),
      messageIds: ["message-001"],
      connection: connection,
      session: session
    )
    try await fixture.service.perform(
      .spam,
      messageIds: ["message-001"],
      connection: connection,
      session: session
    )
    try await fixture.service.perform(
      .notSpam,
      messageIds: ["message-001"],
      connection: connection,
      session: session
    )
    try await fixture.service.perform(
      .restore,
      messageIds: ["message-001"],
      connection: connection,
      session: session
    )

    #expect(
      fixture.recorder.requests.map(\.path) == [
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/modify",
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/trash",
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/modify",
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/modify",
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/modify",
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/modify",
      ])
    #expect(fixture.recorder.requests[2].method == "POST")
    #expect(fixture.recorder.requests[2].jsonBody["addLabelIds"] as? [String] == ["UNREAD"])
    #expect(fixture.recorder.requests[2].jsonBody["removeLabelIds"] as? [String] == [])
    #expect(fixture.recorder.requests[5].method == "POST")
    #expect(fixture.recorder.requests[8].jsonBody["addLabelIds"] as? [String] == ["Label_projects"])
    #expect(
      fixture.recorder.requests[8].jsonBody["removeLabelIds"] as? [String] == ["Label_source"])
    #expect(fixture.recorder.requests[11].jsonBody["addLabelIds"] as? [String] == ["SPAM"])
    #expect(fixture.recorder.requests[11].jsonBody["removeLabelIds"] as? [String] == ["INBOX"])
    #expect(fixture.recorder.requests[14].jsonBody["addLabelIds"] as? [String] == ["INBOX"])
    #expect(fixture.recorder.requests[14].jsonBody["removeLabelIds"] as? [String] == ["SPAM"])
    #expect(fixture.recorder.requests[17].method == "POST")
    #expect(fixture.recorder.requests[17].jsonBody["addLabelIds"] as? [String] == ["INBOX"])
    #expect(fixture.recorder.requests[17].jsonBody["removeLabelIds"] as? [String] == ["TRASH"])
  }

  @Test
  func testProviderThreadActionsAuthorizeOnce() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.perform(
      .archive,
      messageIds: ["message-001", "message-002"],
      connection: connection,
      session: session
    )

    #expect(
      fixture.recorder.requests.map(\.path) == [
        "/token", "/tokeninfo",
        "/gmail/v1/users/me/messages/message-001/modify",
        "/gmail/v1/users/me/messages/message-002/modify",
      ])
  }

  @Test
  func testSyncRecentInboxReadsOnePageAndPreservesUnlistedMessages() async throws {
    let fixture = try makeSyncFixture(usesPagination: true)
    let unlistedMessage = metadata(
      messageId: "message-000",
      threadId: "thread-000",
      internalDateMilliseconds: 1
    )
    fixture.store.messages = [unlistedMessage]

    let result = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session
    )

    #expect(
      fixture.requestRecorder.queries.filter { $0.contains("labelIds=INBOX") } == [
        "labelIds=INBOX&maxResults=25"
      ])
    #expect(
      result.messages.map(\.providerMessageId) == ["message-003", "message-002", "message-000"])
    #expect(fixture.store.savedMessages == result.messages)
  }

  @Test
  func testSyncRecentInboxPreservesIncompleteHistoricalBackfillState() async throws {
    let fixture = try makeSyncFixture(usesPagination: true)
    let initial = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    let recent = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session
    )

    #expect(!(initial.historicalMetadataBackfillIsComplete))
    #expect(!(recent.historicalMetadataBackfillIsComplete))
  }

  @Test
  func testSyncRecentInboxTreatsMissingHistoricalBackfillStateAsIncomplete() async throws {
    let fixture = try makeSyncFixture(usesPagination: true)

    let result = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session
    )

    #expect(!(result.historicalMetadataBackfillIsComplete))
  }

  @Test
  func testSyncRecentInboxRemovesMessagesExcludedByGmailHistory() async throws {
    let fixture = try makeSyncFixture(
      historyResponseData: Data(
        """
        {
          "history": [{
            "labelsRemoved": [{
              "message": {"id": "message-archived"},
              "labelIds": ["INBOX"]
            }],
            "messagesDeleted": [{"message": {"id": "message-deleted"}}]
          }]
        }
        """.utf8
      ),
      labelIdsByMessageId: ["message-archived": ["ARCHIVE"]]
    )
    fixture.store.messages = [
      metadata(
        messageId: "message-preserved", threadId: "thread-preserved", internalDateMilliseconds: 3),
      metadata(
        messageId: "message-archived", threadId: "thread-archived", internalDateMilliseconds: 2),
      metadata(
        messageId: "message-deleted", threadId: "thread-deleted", internalDateMilliseconds: 1),
    ]

    let result = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session,
      sinceHistoryId: "123",
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    #expect(
      fixture.requestRecorder.queries.first { $0.contains("startHistoryId") }
        == "startHistoryId=123")
    #expect(result.messages.contains { $0.providerMessageId == "message-preserved" })
    #expect(!(result.messages.contains { $0.providerMessageId == "message-archived" }))
    #expect(!(result.messages.contains { $0.providerMessageId == "message-deleted" }))
    #expect(
      fixture.store.savedMessages.first { $0.providerMessageId == "message-archived" }?
        .providerLabelIds == ["ARCHIVE"])
    #expect(!(fixture.store.savedMessages.contains { $0.providerMessageId == "message-deleted" }))
  }

  @Test
  func testSyncRecentInboxRefreshesProviderStateChangedByGmailHistory() async throws {
    let fixture = try makeSyncFixture(
      historyResponseData: Data(
        """
        {
          "history": [{
            "labelsAdded": [{
              "message": {"id": "message-preserved"},
              "labelIds": ["STARRED"]
            }]
          }]
        }
        """.utf8
      ),
      labelIdsByMessageId: ["message-preserved": ["INBOX", "STARRED"]]
    )
    fixture.store.messages = [
      metadata(
        messageId: "message-preserved",
        threadId: "thread-preserved",
        internalDateMilliseconds: 1
      )
    ]

    let result = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session,
      sinceHistoryId: "123",
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    #expect(
      result.messages.first { $0.providerMessageId == "message-preserved" }?.providerLabelIds == [
        "INBOX", "STARRED",
      ])
    #expect(
      fixture.store.savedMessages.first { $0.providerMessageId == "message-preserved" }?
        .providerLabelIds == ["INBOX", "STARRED"])
  }

  @Test
  func testSyncRecentInboxFallsBackToFullSyncWhenHistoryIdExpires() async throws {
    let categorizer = RecordingGmailMessageCategorizer(categoryId: "system:promotions")
    let fixture = try makeSyncFixture(
      categorizer: categorizer,
      usesPagination: true,
      historyStatusCode: 404,
      labelIdsByMessageId: ["message-001": ["ARCHIVED"]]
    )
    fixture.store.messages = [
      metadata(
        messageId: "message-stale", threadId: "thread-stale", internalDateMilliseconds: 1)
    ]

    let result = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session,
      sinceHistoryId: "123",
      throughHistoryId: "124",
      shouldPersist: { true }
    )

    #expect(result.newMessageIds == [])
    #expect(result.historyIsExpired)
    #expect(
      fixture.requestRecorder.queries.filter { $0.contains("maxResults=25") } == [
        "maxResults=25&includeSpamTrash=true",
        "maxResults=25&includeSpamTrash=true&pageToken=next-page-token",
      ])
    #expect(fixture.requestRecorder.paths.contains("/gmail/v1/users/me/messages/message-003"))
    #expect(fixture.requestRecorder.paths.contains("/gmail/v1/users/me/messages/message-002"))
    #expect(fixture.requestRecorder.paths.contains("/gmail/v1/users/me/messages/message-001"))
    #expect(!(result.messages.contains { $0.providerMessageId == "message-stale" }))
    #expect(!(fixture.store.savedMessages.contains { $0.providerMessageId == "message-stale" }))
    #expect(fixture.store.savedMessages.contains { $0.providerMessageId == "message-001" })
    #expect(
      categorizer.receivedMessages.allSatisfy { $0.providerLabelIds?.contains("INBOX") == true })
    #expect(fixture.store.syncState?.historicalMetadataBackfillIsComplete == true)
    #expect(fixture.store.syncState?.nextPageToken == nil)
  }

  @Test
  func testSyncRecentInboxDoesNotTreatRestoredInboxMessageAsNew() async throws {
    let fixture = try makeSyncFixture(
      historyResponseData: Data(
        """
        {
          "history": [{
            "labelsAdded": [{
              "message": {"id": "message-002"},
              "labelIds": ["INBOX"]
            }]
          }]
        }
        """.utf8
      )
    )

    let result = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session,
      sinceHistoryId: "123",
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    #expect(result.newMessageIds == [])
  }

  @Test
  func testSyncRecentInboxDropsHistoryAdditionsRemovedBeforeListing() async throws {
    let fixture = try makeSyncFixture(
      historyResponseData: Data(
        """
        {
          "history": [{
            "messagesAdded": [{"message": {"id": "message-002"}}],
            "labelsRemoved": [{
              "message": {"id": "message-002"},
              "labelIds": ["INBOX"]
            }]
          }]
        }
        """.utf8
      )
    )

    let result = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session,
      sinceHistoryId: "123",
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    #expect(result.newMessageIds == [])
  }

  @Test
  func testSyncRecentInboxRestoresNewHistoryAdditionsReaddedToInbox() async throws {
    let fixture = try makeSyncFixture(
      historyResponseData: Data(
        """
        {
          "history": [{
            "messagesAdded": [{"message": {"id": "message-002"}}],
            "labelsRemoved": [{
              "message": {"id": "message-002"},
              "labelIds": ["INBOX"]
            }],
            "labelsAdded": [{
              "message": {"id": "message-002"},
              "labelIds": ["INBOX"]
            }]
          }]
        }
        """.utf8
      )
    )

    let result = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session,
      sinceHistoryId: "123",
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    #expect(result.newMessageIds == ["message-002"])
  }

  @Test
  func testSyncRecentInboxTreatsHistoryAdditionsWithoutLabelsAsNew() async throws {
    let fixture = try makeSyncFixture(
      historyResponseData: Data(
        """
        {
          "history": [{
            "messagesAdded": [{
              "message": {"id": "message-002"}
            }, {
              "message": {"id": "message-sent", "labelIds": ["SENT"]}
            }]
          }]
        }
        """.utf8
      ),
      labelIdsByMessageId: ["message-sent": ["SENT"]]
    )

    let result = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session,
      sinceHistoryId: "123",
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    #expect(result.newMessageIds == ["message-002"])
    #expect(
      fixture.store.savedMessages.first { $0.providerMessageId == "message-sent" }?
        .providerLabelIds == ["SENT"])
    let sent = try await fixture.service.loadMailbox(
      .role(.sent),
      connection: connection,
      session: session
    )
    #expect(sent.messages.map(\.providerMessageId) == ["message-sent"])
  }

  @Test
  func testSyncRecentInboxStopsHistoryCandidatesAtWakeHistoryId() async throws {
    let fixture = try makeSyncFixture(
      historyResponseData: Data(
        """
        {"history":[
          {"id":"124","messagesAdded":[{"message":{"id":"message-002"}}]},
          {"id":"125","messagesAdded":[{"message":{"id":"message-001"}}]}
        ]}
        """.utf8
      )
    )

    let result = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session,
      sinceHistoryId: "123",
      throughHistoryId: "124",
      shouldPersist: { true }
    )

    #expect(result.newMessageIds == ["message-002"])
  }

  @Test
  func testSyncRecentInboxStopsHistoryPaginationAtWakeHistoryId() async throws {
    let fixture = try makeSyncFixture(
      historyResponseData: Data(
        """
        {"history":[
          {"id":"124","messagesAdded":[{"message":{"id":"message-002"}}]},
          {"id":"125","messagesAdded":[{"message":{"id":"message-001"}}]}
        ],"nextPageToken":"next-history-page"}
        """.utf8
      )
    )

    let result = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session,
      sinceHistoryId: "123",
      throughHistoryId: "124",
      shouldPersist: { true }
    )

    #expect(result.newMessageIds == ["message-002"])
    #expect(
      fixture.requestRecorder.queries.filter { $0.contains("startHistoryId") } == [
        "startHistoryId=123"
      ])
  }

  @Test
  func testSyncRecentInboxContinuesPagingForMissingHistoryCandidates()
    async throws
  {
    let fixture = try makeSyncFixture(
      usesPagination: true,
      historyResponseData: Data(
        """
        {"history":[{"id":"124","messagesAdded":[{"message":{"id":"message-001"}}]}]}
        """.utf8
      )
    )

    let result = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session,
      sinceHistoryId: "123",
      throughHistoryId: "124",
      shouldPersist: { true }
    )

    #expect(result.newMessageIds == ["message-001"])
    #expect(!(result.hasUnlistedNewMessages))
    #expect(
      fixture.requestRecorder.queries.filter { $0.contains("labelIds=INBOX") } == [
        "labelIds=INBOX&maxResults=25",
        "labelIds=INBOX&maxResults=25&pageToken=next-page-token",
      ])
  }

  @Test
  func testSyncRecentInboxFindsHistoryAdditionsInLaterPages() async throws {
    let fixture = try makeSyncFixture(
      usesPagination: true,
      historyResponseData: Data(
        """
        {"history":[{"id":"124","messagesAdded":[{"message":{"id":"message-001"}}]}]}
        """.utf8
      )
    )
    fixture.store.messages = [
      metadata(messageId: "message-001", threadId: "thread-001", internalDateMilliseconds: 1)
    ]

    let result = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session,
      sinceHistoryId: "123",
      throughHistoryId: "124",
      shouldPersist: { true }
    )

    #expect(!(result.hasUnlistedNewMessages))
    #expect(result.newMessageIds == ["message-001"])
  }

  @Test
  func testSyncRecentInboxPreservesNotificationEligibilityWhenInboxPersistenceFails()
    async throws
  {
    let notificationConnection = GmailProviderConnectionStatus(
      connectedAt: 1_781_190_000_000,
      emailAddress: "user@example.com",
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: 1_781_190_000_000
    )
    let fixture = try makeSyncFixture(
      historyResponseData: Data(
        #"{"history":[{"id":"124","messagesAdded":[{"message":{"id":"message-002"}}]}]}"#
          .utf8
      )
    )
    fixture.store.saveError = GmailMessageMetadataTestError.interruptedPersistence

    do {
      _ = try await fixture.service.syncRecentInbox(
        connection: notificationConnection,
        includingHistoryCandidates: true,
        session: session,
        sinceHistoryId: "123",
        throughHistoryId: "124",
        shouldPersist: { true }
      )
      Issue.record("Expected interrupted inbox persistence")
    } catch GmailMessageMetadataTestError.interruptedPersistence {
      #expect(
        try fixture.eligibilityStore.eligibleStableMessageIds(
          after: "123",
          productAccountId: session.productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        ) == ["gmail:gmail-user-001:message-002"])
    }
  }

  @Test
  func testSyncRecentInboxDoesNotPersistWhenConnectionChanges() async throws {
    let fixture = try makeSyncFixture()
    let originalTokens = try requireValue(
      fixture.tokenStore.load(productAccountId: session.productAccountId))

    do {
      _ = try await fixture.service.syncRecentInbox(
        connection: connection,
        session: session,
        sinceHistoryId: nil,
        throughHistoryId: nil,
        shouldPersist: { false }
      )
      Issue.record("Expected stale local connection")
    } catch GmailMessageMetadataSyncError.staleLocalConnection {
      #expect(
        try fixture.tokenStore.load(productAccountId: session.productAccountId) == originalTokens)
      #expect(fixture.store.savedMessages.isEmpty)
    }
  }

  @Test
  func testProviderActionsRequireGmailWriteScope() async throws {
    let fixture = try makeMailActionFixture(
      tokenScopes: "https://www.googleapis.com/auth/gmail.readonly"
    )

    do {
      try await fixture.service.perform(
        .archive,
        messageIds: ["message-001"],
        connection: connection,
        session: session
      )
      Issue.record("Expected insufficient Gmail scope")
    } catch GmailMessageMetadataSyncError.insufficientGmailScope {
      #expect(fixture.recorder.requests.map(\.path) == ["/token", "/tokeninfo"])
    }
  }

  @Test
  func testSendAcceptsGmailModifyScope() async throws {
    let fixture = try makeMailActionFixture(
      tokenScopes: "https://www.googleapis.com/auth/gmail.modify"
    )

    try await fixture.service.send(
      GmailOutgoingMessage(body: "Café", recipient: "recipient@example.com", subject: "Subject"),
      connection: connection,
      session: session
    )

    #expect(fixture.recorder.requests.last?.path == "/gmail/v1/users/me/messages/send")
  }

  @Test
  func testSendUsesGmailRawMessageEndpoint() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.send(
      GmailOutgoingMessage(body: "Café", recipient: "recipient@example.com", subject: "Subject"),
      connection: connection,
      session: session
    )

    let sentRequest = fixture.recorder.requests.last
    #expect(sentRequest?.path == "/gmail/v1/users/me/messages/send")
    #expect(sentRequest?.method == "POST")
    let raw = try requireValue(sentRequest?.jsonBody["raw"] as? String)
    let paddedRaw =
      raw.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try requireValue(Data(base64Encoded: paddedRaw))
    let expectedMIME = [
      "To: recipient@example.com",
      "From: user@example.com",
      "Subject: Subject",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=utf-8",
      "Content-Transfer-Encoding: 8bit",
      "",
      "Café",
    ].joined(separator: "\r\n")
    #expect(String(bytes: mime, encoding: .utf8) == expectedMIME)
  }

  @Test
  func testSendPreservesCcAndBccAsDistinctHeaders() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.send(
      GmailOutgoingMessage(
        body: "Body",
        recipient: "recipient@example.com",
        subject: "Subject",
        ccRecipients: "Copy <copy@example.com>",
        bccRecipients: "Hidden <hidden@example.com>"
      ),
      connection: connection,
      session: session
    )

    let raw = try requireValue(fixture.recorder.requests.last?.jsonBody["raw"] as? String)
    let paddedRaw =
      raw.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try requireValue(Data(base64Encoded: paddedRaw))
    let mimeText = try requireValue(String(bytes: mime, encoding: .utf8))
    #expect(mimeText.contains("To: recipient@example.com"))
    #expect(mimeText.contains("Cc: Copy <copy@example.com>"))
    #expect(mimeText.contains("Bcc: Hidden <hidden@example.com>"))
  }

  @Test
  func testSendPreservesProviderStatusForOutboxRetryClassification() async throws {
    let tokenStore = RecordingGmailProviderTokenStore()
    let tokenInfo = """
      {"sub":"gmail-user-001","email":"user@example.com",
      "scope":"https://www.googleapis.com/auth/gmail.send"}
      """
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let urlSession = ConvexClientTesting.makeSession(
      protocolClass: GmailMetadataURLStub.self
    ) { request in
      switch request.url?.path {
      case "/tokeninfo":
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(tokenInfo.utf8)
        )
      case "/token":
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data("{\"access_token\":\"access-token\"}".utf8)
        )
      case "/gmail/v1/users/me/messages/send":
        return (Self.httpResponse(for: request, statusCode: 429), Data())
      default:
        return (Self.httpResponse(for: request, statusCode: 200), Data())
      }
    }
    let service = GmailMessageMetadataService(
      gmailBaseURL: URL(string: "https://gmail.example.test/gmail/v1")!,
      oauthClientId: "gmail-client-id",
      session: urlSession,
      tokenStore: tokenStore,
      tokenInfoURL: URL(string: "https://oauth.example.test/tokeninfo")!,
      tokenRefreshURL: URL(string: "https://oauth.example.test/token")!
    )

    do {
      try await service.send(
        GmailOutgoingMessage(body: "Hello", recipient: "recipient@example.com", subject: "Subject"),
        connection: connection,
        session: session
      )
      Issue.record("Expected send failure")
    } catch {
      #expect(error as? GmailProviderMailActionError == .responseStatus(429))
    }
  }

  @Test
  func testSendPreservesRateLimitReasonForOutboxRetryClassification() async throws {
    let tokenStore = RecordingGmailProviderTokenStore()
    let tokenInfo = """
      {"sub":"gmail-user-001","email":"user@example.com",
      "scope":"https://www.googleapis.com/auth/gmail.send"}
      """
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let urlSession = ConvexClientTesting.makeSession(
      protocolClass: GmailMetadataURLStub.self
    ) { request in
      switch request.url?.path {
      case "/tokeninfo":
        return (Self.httpResponse(for: request, statusCode: 200), Data(tokenInfo.utf8))
      case "/token":
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data("{\"access_token\":\"access-token\"}".utf8)
        )
      case "/gmail/v1/users/me/messages/send":
        return (
          Self.httpResponse(for: request, statusCode: 403),
          Data("{\"error\":{\"errors\":[{\"reason\":\"userRateLimitExceeded\"}]}}".utf8)
        )
      default:
        return (Self.httpResponse(for: request, statusCode: 200), Data())
      }
    }
    let service = GmailMessageMetadataService(
      gmailBaseURL: URL(string: "https://gmail.example.test/gmail/v1")!,
      oauthClientId: "gmail-client-id",
      session: urlSession,
      tokenStore: tokenStore,
      tokenInfoURL: URL(string: "https://oauth.example.test/tokeninfo")!,
      tokenRefreshURL: URL(string: "https://oauth.example.test/token")!
    )

    do {
      try await service.send(
        GmailOutgoingMessage(body: "Hello", recipient: "recipient@example.com", subject: "Subject"),
        connection: connection,
        session: session
      )
      Issue.record("Expected send failure")
    } catch {
      #expect(error as? GmailProviderMailActionError == .rateLimitedResponseStatus(403))
    }
  }

  @Test
  func testSendEncodesRecipientDisplayName() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.send(
      GmailOutgoingMessage(
        body: "Hello",
        recipient: "José García <jose@example.com>",
        subject: "Subject"
      ),
      connection: connection,
      session: session
    )

    let raw = try requireValue(fixture.recorder.requests.last?.jsonBody["raw"] as? String)
    let paddedRaw =
      raw.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try requireValue(Data(base64Encoded: paddedRaw))
    let mimeText = try requireValue(String(bytes: mime, encoding: .utf8))
    #expect(mimeText.contains("To: =?UTF-8?B?Sm9zw6kgR2FyY8OtYQ==?= <jose@example.com>"))
  }

  @Test
  func testSendPreservesMultipleRecipientsWhenEncodingDisplayNames() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.send(
      GmailOutgoingMessage(
        body: "Hello",
        recipient: "Alice <alice@example.com>, José <jose@example.com>",
        subject: "Subject"
      ),
      connection: connection,
      session: session
    )

    let raw = try requireValue(fixture.recorder.requests.last?.jsonBody["raw"] as? String)
    let paddedRaw =
      raw.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try requireValue(Data(base64Encoded: paddedRaw))
    let mimeText = try requireValue(String(bytes: mime, encoding: .utf8))
    #expect(
      mimeText.contains("To: Alice <alice@example.com>, =?UTF-8?B?Sm9zw6k=?= <jose@example.com>"))
  }

  @Test
  func testSendEncodesQuotedDisplayNameWithComma() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.send(
      GmailOutgoingMessage(
        body: "Hello",
        recipient: "\"García, José\" <jose@example.com>",
        subject: "Subject"
      ),
      connection: connection,
      session: session
    )

    let raw = try requireValue(fixture.recorder.requests.last?.jsonBody["raw"] as? String)
    let paddedRaw =
      raw.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try requireValue(Data(base64Encoded: paddedRaw))
    let mimeText = try requireValue(String(bytes: mime, encoding: .utf8))
    #expect(mimeText.contains("To: =?UTF-8?B?IkdhcmPDrWEsIEpvc8OpIg==?= <jose@example.com>"))
  }

  @Test
  func testSendAddsReplyThreadingHeadersAndRejectsHeaderInjection() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.send(
      GmailOutgoingMessage(
        body: "Hello",
        recipient: "recipient@example.com",
        subject: "Subject",
        inReplyTo: "<original@example.com>",
        threadId: "thread-001"
      ),
      connection: connection,
      session: session
    )

    let sentRequest = try requireValue(fixture.recorder.requests.last)
    #expect(sentRequest.jsonBody["threadId"] as? String == "thread-001")
    let raw = try requireValue(sentRequest.jsonBody["raw"] as? String)
    let paddedRaw = raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try requireValue(Data(base64Encoded: paddedRaw))
    let mimeText = try requireValue(String(bytes: mime, encoding: .utf8))
    #expect(mimeText.contains("In-Reply-To: <original@example.com>"))
    #expect(mimeText.contains("References: <original@example.com>"))

    do {
      try await fixture.service.send(
        GmailOutgoingMessage(
          body: "Hello",
          recipient: "victim@example.com\r\nBcc: bad",
          subject: "Subject"
        ),
        connection: connection,
        session: session
      )
      Issue.record("Expected header validation failure")
    } catch GmailMessageMetadataSyncError.invalidMessageHeader {
    }
  }

  private func makeMailActionFixture(
    tokenScopes: String =
      "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.send"
  ) throws -> GmailMailActionFixture {
    let tokenStore = RecordingGmailProviderTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let recorder = GmailMailActionRequestRecorder()
    let urlSession = ConvexClientTesting.makeSession(
      protocolClass: GmailMetadataURLStub.self
    ) { request in
      recorder.requests.append(GmailMailActionRequest(request: request))
      switch request.url?.path {
      case "/token":
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      case "/tokeninfo":
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(
            "{\"sub\":\"gmail-user-001\",\"email\":\"user@example.com\",\"scope\":\"\(tokenScopes)\"}"
              .utf8
          )
        )
      default:
        return (Self.httpResponse(for: request, statusCode: 200), Data())
      }
    }
    return GmailMailActionFixture(
      recorder: recorder,
      service: GmailMessageMetadataService(
        gmailBaseURL: URL(string: "https://gmail.example.test/gmail/v1")!,
        oauthClientId: "gmail-client-id",
        session: urlSession,
        tokenStore: tokenStore,
        tokenInfoURL: URL(string: "https://oauth.example.test/tokeninfo")!,
        tokenRefreshURL: URL(string: "https://oauth.example.test/token")!
      )
    )
  }

  private static func httpResponse(
    for request: URLRequest,
    statusCode: Int
  ) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
  }

  private static func messageMetadataResponseData(
    messageId: String,
    internalDate: String,
    snippet: String,
    replyTo: String? = nil,
    labelIds: [String]? = ["INBOX", "UNREAD"],
    hasAttachments: Bool = false,
    includesCalendarInvitation: Bool = false,
    includesUnsubscribeHeaders: Bool = false
  ) -> Data {
    let replyToHeader =
      replyTo.map {
        ",\n            {\"name\": \"Reply-To\", \"value\": \"\($0)\"}"
      } ?? ""
    let labelIdsField: String
    if let labelIds {
      let encodedLabelIds = labelIds.map { "\"\($0)\"" }.joined(separator: ", ")
      labelIdsField = "\"labelIds\": [\(encodedLabelIds)],"
    } else {
      labelIdsField = ""
    }
    let parts: [String] = [
      hasAttachments ? #"{"filename":"invoice.pdf","headers":[]}"# : nil,
      includesCalendarInvitation
        ? """
        {"body":{"attachmentId":"calendar-001","size":512},"filename":"invite.ics",\
        "headers":[],"mimeType":"text/calendar","partId":"2"}
        """
        : nil,
    ].compactMap { $0 }
    let partsField = parts.isEmpty ? "" : #", "parts": [\#(parts.joined(separator: ","))]"#
    let listUnsubscribeValue =
      "<mailto:leave@example.com?subject=remove&body=unsubscribe>, "
      + "<https://lists.example.com/unsubscribe>"
    let unsubscribeHeaders =
      includesUnsubscribeHeaders
      ? """
      ,
                  {"name": "List-ID", "value": "News <news.example.com>"},
                  {"name": "List-Unsubscribe", "value": "\(listUnsubscribeValue)"},
                  {"name": "List-Unsubscribe-Post", "value": "List-Unsubscribe=One-Click"}
      """
      : ""
    return Data(
      """
      {
        "id": "\(messageId)",
        "threadId": "thread-001",
        "internalDate": "\(internalDate)",
        \(labelIdsField)
        "snippet": "\(snippet)",
        "payload": {
          "headers": [
            {"name": "From", "value": "Sender <sender@example.com>"},
            {"name": "To", "value": "User <user@example.com>"},
            {"name": "Cc", "value": "Finance <finance@example.com>"},
            {"name": "Bcc", "value": "Auditor <auditor@example.com>"},
            {"name": "Subject", "value": "Thread subject"}\(replyToHeader)\(unsubscribeHeaders)
          ]\(partsField)
        }
      }
      """.utf8
    )
  }

  private func makeSyncFixture(
    categorizer: GmailMessageCategorizing = RecordingGmailMessageCategorizer(),
    tokenInfoSubject: String = "gmail-user-001",
    usesPagination: Bool = false,
    rejectsFirstHistoricalPageToken: Bool = false,
    rejectedPageTokenResponseData: Data? = nil,
    replyTo: String? = nil,
    historyStatusCode: Int = 200,
    historyResponseData: Data = Data(#"{"history":[]}"#.utf8),
    shouldContinueHistoricalBackfill: @escaping () -> Bool = { true },
    labelIdsByMessageId: [String: [String]] = [:],
    messageIdsWithoutLabelIds: Set<String> = [],
    hasAttachments: Bool = false,
    includesCalendarInvitation: Bool = false,
    includesUnsubscribeHeaders: Bool = false,
    usesLegacyTokens: Bool = false
  ) throws -> GmailMessageMetadataSyncFixture {
    let eligibilityStore = RecordingGmailPushEligibilityStore()
    let store = RecordingGmailMessageMetadataStore()
    let tokenStore = RecordingGmailProviderTokenStore()
    let requestRecorder = GmailMetadataRequestRecorder()
    let tokens = GmailProviderTokens(
      accessToken: "access-token",
      refreshToken: "refresh-token"
    )
    if usesLegacyTokens {
      tokenStore.saveLegacy(tokens, productAccountId: session.productAccountId)
    } else {
      try tokenStore.save(tokens, productAccountId: session.productAccountId)
    }
    let urlSession = ConvexClientTesting.makeSession(
      protocolClass: GmailMetadataURLStub.self
    ) { request in
      self.makeSyncResponse(
        for: request,
        requestRecorder: requestRecorder,
        tokenInfoSubject: tokenInfoSubject,
        usesPagination: usesPagination,
        rejectsFirstHistoricalPageToken: rejectsFirstHistoricalPageToken,
        rejectedPageTokenResponseData: rejectedPageTokenResponseData,
        replyTo: replyTo,
        labelIdsByMessageId: labelIdsByMessageId,
        messageIdsWithoutLabelIds: messageIdsWithoutLabelIds,
        hasAttachments: hasAttachments,
        includesCalendarInvitation: includesCalendarInvitation,
        includesUnsubscribeHeaders: includesUnsubscribeHeaders,
        historyStatusCode: historyStatusCode,
        historyResponseData: historyResponseData
      )
    }
    let service = GmailMessageMetadataService(
      categorizer: categorizer,
      gmailBaseURL: URL(string: "https://gmail.example.test/gmail/v1")!,
      notificationEligibilityStore: eligibilityStore,
      oauthClientId: "gmail-client-id",
      session: urlSession,
      shouldContinueHistoricalBackfill: shouldContinueHistoricalBackfill,
      store: store,
      tokenStore: tokenStore,
      tokenInfoURL: URL(string: "https://oauth.example.test/tokeninfo")!,
      tokenRefreshURL: URL(string: "https://oauth.example.test/token")!
    )
    return GmailMessageMetadataSyncFixture(
      eligibilityStore: eligibilityStore,
      requestRecorder: requestRecorder,
      service: service,
      store: store,
      tokenStore: tokenStore
    )
  }

  // swiftlint:disable:next function_parameter_count
  private func makeSyncResponse(
    for request: URLRequest,
    requestRecorder: GmailMetadataRequestRecorder,
    tokenInfoSubject: String,
    usesPagination: Bool,
    rejectsFirstHistoricalPageToken: Bool,
    rejectedPageTokenResponseData: Data?,
    replyTo: String?,
    labelIdsByMessageId: [String: [String]],
    messageIdsWithoutLabelIds: Set<String>,
    hasAttachments: Bool,
    includesCalendarInvitation: Bool,
    includesUnsubscribeHeaders: Bool,
    historyStatusCode: Int,
    historyResponseData: Data
  ) -> (HTTPURLResponse, Data) {
    requestRecorder.paths.append(request.url?.path ?? "")
    requestRecorder.queries.append(request.url?.query ?? "")

    if request.url?.path == "/token" {
      #expect(request.httpMethod == "POST")
      #expect(
        request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
      )
    }

    if request.url?.path == "/tokeninfo" {
      #expect(request.url?.query == "access_token=refreshed-access-token")
      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(
          """
          {
            "sub":"\(tokenInfoSubject)",
            "email":"user@example.com",
            "scope":"https://www.googleapis.com/auth/gmail.modify"
          }
          """.utf8
        )
      )
    }

    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-access-token")

    if request.url?.path == "/gmail/v1/users/me/history" {
      return (Self.httpResponse(for: request, statusCode: historyStatusCode), historyResponseData)
    }

    if request.url?.path == "/gmail/v1/users/me/labels" {
      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(
          """
          {"labels":[
            {"id":"INBOX","name":"Inbox"},
            {"id":"STARRED","name":"Starred"},
            {"id":"Label_projects","name":"Projects"},
            {"id":"Label_empty","name":"Empty label"}
          ]}
          """.utf8
        )
      )
    }

    if request.url?.path == "/gmail/v1/users/me/messages" {
      if request.url?.query?.contains("maxResults=50") == true || historyStatusCode == 404 {
        #expect(!(request.url?.query?.contains("labelIds=INBOX") == true))
      } else {
        #expect(request.url?.query?.contains("labelIds=INBOX") == true)
      }
      if usesPagination, request.url?.query?.contains("pageToken=next-page-token") == true {
        if rejectsFirstHistoricalPageToken,
          requestRecorder.queries.filter({ $0.contains("pageToken=next-page-token") }).count == 1
        {
          return (
            Self.httpResponse(for: request, statusCode: 400),
            rejectedPageTokenResponseData
              ?? Data(#"{"error":{"message":"Invalid page token."}}"#.utf8)
          )
        }
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(#"{"messages":[{"id":"message-001"}]}"#.utf8)
        )
      }
      if usesPagination {
        return (
          Self.httpResponse(for: request, statusCode: 200),
          Data(
            #"{"messages":[{"id":"message-003"},{"id":"message-002"}],"nextPageToken":"next-page-token"}"#
              .utf8
          )
        )
      }
      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(#"{"messages":[{"id":"message-002"},{"id":"message-001"}]}"#.utf8)
      )
    }

    return (
      Self.httpResponse(for: request, statusCode: 200),
      makeMessageMetadataResponseData(
        for: request,
        replyTo: replyTo,
        labelIdsByMessageId: labelIdsByMessageId,
        messageIdsWithoutLabelIds: messageIdsWithoutLabelIds,
        options: MessageMetadataOptions(
          hasAttachments: hasAttachments,
          includesCalendarInvitation: includesCalendarInvitation,
          includesUnsubscribeHeaders: includesUnsubscribeHeaders
        )
      )
    )
  }

  private func makeMessageMetadataResponseData(
    for request: URLRequest,
    replyTo: String?,
    labelIdsByMessageId: [String: [String]],
    messageIdsWithoutLabelIds: Set<String>,
    options: MessageMetadataOptions
  ) -> Data {
    let messageId = request.url?.lastPathComponent ?? ""
    let labelIds: [String]? =
      messageIdsWithoutLabelIds.contains(messageId)
      ? nil
      : labelIdsByMessageId[messageId] ?? ["INBOX", "UNREAD"]
    if request.url?.path == "/gmail/v1/users/me/messages/message-001" {
      return Self.messageMetadataResponseData(
        messageId: "message-001",
        internalDate: "1781190000000",
        snippet: "Older message snippet",
        replyTo: replyTo,
        labelIds: labelIds,
        hasAttachments: options.hasAttachments,
        includesCalendarInvitation: options.includesCalendarInvitation,
        includesUnsubscribeHeaders: options.includesUnsubscribeHeaders
      )
    }

    if request.url?.path == "/gmail/v1/users/me/messages/message-003" {
      return Self.messageMetadataResponseData(
        messageId: "message-003",
        internalDate: "1781199000000",
        snippet: "Newest message snippet",
        replyTo: replyTo,
        labelIds: labelIds,
        hasAttachments: options.hasAttachments,
        includesCalendarInvitation: options.includesCalendarInvitation,
        includesUnsubscribeHeaders: options.includesUnsubscribeHeaders
      )
    }

    return Self.messageMetadataResponseData(
      messageId: messageId,
      internalDate: "1781197200000",
      snippet: "Latest message snippet",
      replyTo: replyTo,
      labelIds: labelIds,
      hasAttachments: options.hasAttachments,
      includesCalendarInvitation: options.includesCalendarInvitation,
      includesUnsubscribeHeaders: options.includesUnsubscribeHeaders
    )
  }

  @MainActor
  private func makeUnifiedInboxViewModelFixture(
    historicalMessagesByProviderAccount: [String: GmailMessageMetadata] = [:],
    delaysHistoricalBackfill: Bool = false,
    delaysNavigationRefresh: Bool = false,
    syncErrorsByProviderAccount: [String: String] = [:],
    overrideCategoryErrorDescription: String? = nil,
    phaseGate: UnifiedInboxPhaseGate? = nil
  ) -> UnifiedInboxViewModelFixture {
    let secondConnection = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: "other@example.com",
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
    let service = DelayedMailboxSwitchingService(
      messagesByProviderAccountIdentifier: [
        connection.providerAccountIdentifier: metadata(
          messageId: "message-first",
          threadId: "thread-first",
          internalDateMilliseconds: 100
        ),
        secondConnection.providerAccountIdentifier: metadata(
          messageId: "message-second",
          threadId: "thread-second",
          internalDateMilliseconds: 200,
          providerAccountIdentifier: secondConnection.providerAccountIdentifier
        ),
      ],
      historicalMessagesByProviderAccount: historicalMessagesByProviderAccount,
      delaysHistoricalBackfill: delaysHistoricalBackfill,
      delaysNavigationRefresh: delaysNavigationRefresh,
      syncErrorsByProviderAccount: syncErrorsByProviderAccount,
      overrideCategoryErrorDescription: overrideCategoryErrorDescription,
      phaseGate: phaseGate
    )
    return UnifiedInboxViewModelFixture(
      connections: [
        connection.mailboxConnection(
          productAccountId: session.productAccountId, authorizationState: .authorized),
        secondConnection.mailboxConnection(
          productAccountId: session.productAccountId, authorizationState: .authorized),
      ],
      service: service,
      viewModel: GmailInboxViewModel(service: service, searchService: service, session: session)
    )
  }

  @MainActor
  private func makeMailboxFreshnessFixture(
    outcomes: [RecordingMailboxFreshnessService.Outcome] = [],
    suspendsSync: Bool = false,
    suspendsBackfill: Bool = false,
    completesBackfill: Bool = true,
    failsBackfill: Bool = false,
    cancelsBackfill: Bool = false,
    sleep: @escaping (Duration) async throws -> Void = { _ in throw CancellationError() }
  ) -> MailboxFreshnessFixture {
    let secondConnection = GmailProviderConnectionStatus(
      connectedAt: connection.connectedAt,
      emailAddress: "other@example.com",
      lastVerifiedAt: connection.lastVerifiedAt,
      provider: connection.provider,
      providerAccountIdentifier: "gmail-user-002",
      trustedDeviceId: connection.trustedDeviceId,
      updatedAt: connection.updatedAt
    )
    let service = RecordingMailboxFreshnessService(
      outcomes: outcomes,
      suspendsSync: suspendsSync,
      suspendsBackfill: suspendsBackfill,
      completesBackfill: completesBackfill,
      failsBackfill: failsBackfill,
      cancelsBackfill: cancelsBackfill
    )
    let now = Date(timeIntervalSince1970: 1_781_200_000)
    let sessionState = MailboxFreshnessSessionState()
    let successStore = InMemoryMailboxSyncSuccessStore()
    return MailboxFreshnessFixture(
      connections: [
        connection.mailboxConnection(
          productAccountId: session.productAccountId, authorizationState: .authorized),
        secondConnection.mailboxConnection(
          productAccountId: session.productAccountId, authorizationState: .authorized),
      ],
      now: now,
      sessionState: sessionState,
      service: service,
      successStore: successStore,
      viewModel: MailboxFreshnessViewModel(
        service: service,
        session: session,
        isSessionCurrent: { _ in sessionState.isCurrent },
        now: { now },
        successStore: successStore,
        sleep: sleep
      )
    )
  }

  private func metadata(
    messageId: String,
    threadId: String,
    internalDateMilliseconds: Int64,
    providerAccountIdentifier: String = "gmail-user-001"
  ) -> GmailMessageMetadata {
    GmailMessageMetadata(
      categoryId: nil,
      from: "Sender <sender@example.com>",
      isHistorical: true,
      providerAccountIdentifier: providerAccountIdentifier,
      providerInternalDateMilliseconds: internalDateMilliseconds,
      providerMessageId: messageId,
      providerThreadId: threadId,
      replyTo: nil,
      snippet: "Snippet",
      stableProviderMessageId: "gmail:\(providerAccountIdentifier):\(messageId)",
      subject: "Subject",
      rfcMessageId: nil
    )
  }
}

private struct MailboxFreshnessFixture {
  let connections: [MailboxConnection]
  let now: Date
  let sessionState: MailboxFreshnessSessionState
  let service: RecordingMailboxFreshnessService
  let successStore: InMemoryMailboxSyncSuccessStore
  let viewModel: MailboxFreshnessViewModel
}

@MainActor
private final class MailboxFreshnessSessionState {
  var isCurrent = true
}

@MainActor
private final class InMemoryMailboxSyncSuccessStore: MailboxSyncSuccessPersisting {
  private var dates: [String: Date] = [:]

  func clear(productAccountId: String) {
    let prefix = "\(productAccountId)."
    dates = dates.filter { !$0.key.hasPrefix(prefix) }
  }

  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) {
    dates["\(productAccountId).\(connectionId.rawValue)"] = nil
  }

  func clear(
    productAccountId: String,
    except connectionIds: Set<MailboxConnectionId>
  ) {
    let prefix = "\(productAccountId)."
    let retainedKeys = Set(connectionIds.map { "\(prefix)\($0.rawValue)" })
    dates = dates.filter { !$0.key.hasPrefix(prefix) || retainedKeys.contains($0.key) }
  }

  func load(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) -> Date? {
    dates["\(productAccountId).\(connectionId.rawValue)"]
  }

  func save(
    _ date: Date,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) {
    dates["\(productAccountId).\(connectionId.rawValue)"] = date
  }
}

private struct UnifiedInboxViewModelFixture {
  let connections: [MailboxConnection]
  let service: DelayedMailboxSwitchingService
  let viewModel: GmailInboxViewModel
}

private actor OneShotMailboxPollSleeper {
  private var durations: [Duration] = []

  func sleep(for duration: Duration) async throws {
    durations.append(duration)
    if durations.count > 1 {
      throw CancellationError()
    }
  }

  func receivedDurations() -> [Duration] {
    durations
  }
}

private actor RecordingMailboxFreshnessService: MailboxMetadataSyncing {
  enum Outcome {
    case incomplete
    case incompleteWithoutCheckpoint
    case offline
    case success
  }

  private var backfillConnectionIds: [MailboxConnectionId] = []
  private var backfillContinuation: CheckedContinuation<Void, Never>?
  private var backfillStartContinuations:
    [(callCount: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var connectionIds: [MailboxConnectionId] = []
  private var collections: [MailboxMessageCollection] = []
  private var outcomes: [Outcome]
  private var recentConnectionIds: [MailboxConnectionId] = []
  private var startContinuations: [CheckedContinuation<Void, Never>] = []
  private var syncContinuations: [CheckedContinuation<Void, Error>] = []
  private let completesBackfill: Bool
  private let failsBackfill: Bool
  private let cancelsBackfill: Bool
  private let suspendsBackfill: Bool
  private let suspendsSync: Bool

  init(
    outcomes: [Outcome],
    suspendsSync: Bool,
    suspendsBackfill: Bool,
    completesBackfill: Bool,
    failsBackfill: Bool,
    cancelsBackfill: Bool
  ) {
    self.cancelsBackfill = cancelsBackfill
    self.completesBackfill = completesBackfill
    self.failsBackfill = failsBackfill
    self.outcomes = outcomes
    self.suspendsBackfill = suspendsBackfill
    self.suspendsSync = suspendsSync
  }

  func categorizeHistorical(
    scope _: HistoricalCategorizationScope,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    .empty
  }

  func loadInbox(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    .empty
  }

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    collections.append(collection)
    return .empty
  }

  func syncInbox(
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    connectionIds.append(connection.id)
    return try await nextSyncResult()
  }

  private func nextSyncResult() async throws -> MailboxMetadataSyncResult {
    let continuations = startContinuations
    startContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
    if suspendsSync {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          syncContinuations.append(continuation)
        }
      } onCancel: {
        Task { await self.cancelSuspendedSync() }
      }
    }
    let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
    switch outcome {
    case .incomplete:
      return MailboxMetadataSyncResult(
        hasUnlistedNewMessages: false,
        messages: [],
        newMessageIds: nil,
        providerCursorIsExpired: false,
        threads: [],
        historicalMetadataBackfillIsComplete: false
      )
    case .incompleteWithoutCheckpoint:
      return MailboxMetadataSyncResult(
        hasUnlistedNewMessages: false,
        messages: [],
        newMessageIds: nil,
        providerCursorIsExpired: false,
        threads: [],
        historicalMetadataBackfillCanResume: false,
        historicalMetadataBackfillIsComplete: false
      )
    case .offline:
      throw URLError(.notConnectedToInternet)
    case .success:
      return .empty
    }
  }

  func continueHistoricalBackfill(
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    backfillConnectionIds.append(connection.id)
    let callCount = backfillConnectionIds.count
    let continuations = backfillStartContinuations.filter { $0.callCount <= callCount }
    backfillStartContinuations.removeAll { $0.callCount <= callCount }
    for continuation in continuations {
      continuation.continuation.resume()
    }
    if suspendsBackfill {
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          backfillContinuation = continuation
        }
      } onCancel: {
        Task { await self.cancelSuspendedBackfill() }
      }
    }
    if failsBackfill {
      throw URLError(.timedOut)
    }
    if cancelsBackfill {
      throw CancellationError()
    }
    guard !completesBackfill else { return .empty }
    return MailboxMetadataSyncResult(
      hasUnlistedNewMessages: false,
      messages: [],
      newMessageIds: nil,
      providerCursorIsExpired: false,
      threads: [],
      historicalMetadataBackfillIsComplete: false
    )
  }

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection: MailboxConnection,
    includingHistoryCandidates _: Bool,
    session _: ProductAccountSessionSnapshot,
    sinceHistoryId _: String?,
    throughHistoryId _: String?,
    shouldPersist _: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    recentConnectionIds.append(connection.id)
    return try await nextSyncResult()
  }

  func overrideCategory(
    _ categoryId: String,
    for message: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    message.gmailMetadata.assigningCategory(categoryId).mailboxMetadata(
      connectionId: message.connectionId
    )
  }

  func setCategories(
    _ categoryIds: [String],
    for message: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    message.gmailMetadata.assigningCategories(categoryIds).mailboxMetadata(
      connectionId: message.connectionId
    )
  }

  func syncCallCount() -> Int {
    connectionIds.count + recentConnectionIds.count
  }

  func loadedCollections() -> [MailboxMessageCollection] {
    collections
  }

  func syncedConnectionIds() -> [MailboxConnectionId] {
    connectionIds
  }

  func reconciledConnectionIds() -> [MailboxConnectionId] {
    backfillConnectionIds
  }

  func recentlySyncedConnectionIds() -> [MailboxConnectionId] {
    recentConnectionIds
  }

  func waitUntilSyncStarts(callCount: Int = 1) async {
    guard syncCallCount() < callCount else { return }
    await withCheckedContinuation { continuation in
      startContinuations.append(continuation)
    }
  }

  func waitUntilHistoricalBackfillStarts(callCount: Int = 1) async {
    guard backfillConnectionIds.count < callCount else { return }
    await withCheckedContinuation { continuation in
      backfillStartContinuations.append((callCount, continuation))
    }
  }

  func releaseHistoricalBackfill() {
    backfillContinuation?.resume()
    backfillContinuation = nil
  }

  private func cancelSuspendedBackfill() {
    backfillContinuation?.resume()
    backfillContinuation = nil
  }

  func releaseSync() {
    let continuations = syncContinuations
    syncContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }

  func releaseNextSync() {
    guard !syncContinuations.isEmpty else { return }
    syncContinuations.removeFirst().resume()
  }

  private func cancelSuspendedSync() {
    let continuations = syncContinuations
    syncContinuations.removeAll()
    for continuation in continuations {
      continuation.resume(throwing: CancellationError())
    }
  }
}

private actor MailboxSyncGateProbe {
  private(set) var pollAcquired = false

  func markPollAcquired() {
    pollAcquired = true
  }
}

extension MailboxMetadataSyncResult {
  fileprivate static let empty = MailboxMetadataSyncResult(
    hasUnlistedNewMessages: false,
    messages: [],
    newMessageIds: nil,
    providerCursorIsExpired: false,
    threads: []
  )
}

private actor OverrideGate {
  private var hasStarted = false
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var startContinuations: [CheckedContinuation<Void, Never>] = []

  func waitForRelease() async {
    hasStarted = true
    let continuations = startContinuations
    startContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilStarted() async {
    guard !hasStarted else { return }
    await withCheckedContinuation { continuation in
      startContinuations.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private struct DelayedMailboxSwitchingService: MailboxMetadataSyncing, MailboxMessageSearching {
  let messagesByProviderAccountIdentifier: [String: GmailMessageMetadata]
  var historicalMessagesByProviderAccount: [String: GmailMessageMetadata] = [:]
  var historicalCategorizationResult: MailboxMetadataSyncResult?
  var delaysHistoricalBackfill = false
  var delaysNavigationRefresh = false
  var syncErrorsByProviderAccount: [String: String] = [:]
  var overrideCategoryErrorDescription: String?
  var phaseGate: UnifiedInboxPhaseGate?
  var loadResultIsIncomplete = false
  private let historicalBackfillGate = OverrideGate()
  private let historicalCategorizationGate = OverrideGate()
  private let overrideGate = OverrideGate()
  private let callRecorder = MailboxCallRecorder()

  func syncInboxCallCount() async -> Int {
    await callRecorder.syncCount
  }

  func historicalBackfillCallCount() async -> Int {
    await callRecorder.historicalBackfillCount
  }

  func categorizeHistorical(
    scope _: HistoricalCategorizationScope,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    if let historicalCategorizationResult {
      return historicalCategorizationResult
    }
    await historicalCategorizationGate.waitForRelease()
    throw MailboxSwitchingError.historicalCategorizationFailed
  }

  func loadInbox(
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    await phaseGate?.suspendFirstCacheLoad(for: connection.id)
    return result(
      for: connection,
      using: messagesByProviderAccountIdentifier,
      historicalMetadataBackfillIsComplete: !loadResultIsIncomplete
    )
  }

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    guard collection == .allObserved else {
      return try await loadInbox(connection: connection, session: session)
    }
    if delaysNavigationRefresh {
      await phaseGate?.suspendFirstNavigationLoad(for: connection.id)
    }
    return result(for: connection, using: messagesByProviderAccountIdentifier)
  }

  func syncInbox(
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    await phaseGate?.suspend(.sync, for: connection.id)
    await callRecorder.recordSync()
    if let description = syncErrorsByProviderAccount[
      connection.providerMailboxIdentity.value
    ] {
      throw MailboxSwitchingLocalizedError(description: description)
    }
    return result(
      for: connection,
      using: messagesByProviderAccountIdentifier,
      historicalMetadataBackfillIsComplete:
        historicalMessagesByProviderAccount[
          connection.providerMailboxIdentity.value
        ] == nil
    )
  }

  func continueHistoricalBackfill(
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    await phaseGate?.suspend(.backfill, for: connection.id)
    await callRecorder.recordHistoricalBackfill()
    if delaysHistoricalBackfill {
      await historicalBackfillGate.waitForRelease()
    }
    return result(
      for: connection,
      using: historicalMessagesByProviderAccount
    )
  }

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection: MailboxConnection,
    includingHistoryCandidates _: Bool,
    session _: ProductAccountSessionSnapshot,
    sinceHistoryId _: String?,
    throughHistoryId _: String?,
    shouldPersist _: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    result(for: connection, using: messagesByProviderAccountIdentifier)
  }

  func overrideCategory(
    _ categoryId: String,
    for message: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    if let overrideCategoryErrorDescription {
      throw MailboxSwitchingLocalizedError(description: overrideCategoryErrorDescription)
    }
    await overrideGate.waitForRelease()
    return message.gmailMetadata.assigningCategory(categoryId).mailboxMetadata(
      connectionId: message.connectionId
    )
  }

  func setCategories(
    _ categoryIds: [String],
    for message: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    if let overrideCategoryErrorDescription {
      throw MailboxSwitchingLocalizedError(description: overrideCategoryErrorDescription)
    }
    await overrideGate.waitForRelease()
    return message.gmailMetadata.assigningCategories(categoryIds).mailboxMetadata(
      connectionId: message.connectionId
    )
  }

  func searchProvider(
    query _: String,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata] {
    []
  }

  func waitUntilOverrideStarts() async {
    await overrideGate.waitUntilStarted()
  }

  func releaseOverride() async {
    await overrideGate.release()
  }

  func waitUntilHistoricalCategorizationStarts() async {
    await historicalCategorizationGate.waitUntilStarted()
  }

  func waitUntilHistoricalBackfillStarts() async {
    await historicalBackfillGate.waitUntilStarted()
  }

  func releaseHistoricalCategorization() async {
    await historicalCategorizationGate.release()
  }

  func releaseHistoricalBackfill() async {
    await historicalBackfillGate.release()
  }

  private func result(
    for connection: MailboxConnection,
    using messagesByProviderAccountIdentifier: [String: GmailMessageMetadata],
    historicalMetadataBackfillIsComplete: Bool = true
  ) -> MailboxMetadataSyncResult {
    guard
      let message = messagesByProviderAccountIdentifier[
        connection.providerMailboxIdentity.value
      ]
    else {
      return MailboxMetadataSyncResult(
        hasUnlistedNewMessages: false,
        messages: [],
        newMessageIds: nil,
        providerCursorIsExpired: false,
        threads: []
      )
    }
    return GmailMetadataSyncResult(
      historicalMetadataBackfillIsComplete: historicalMetadataBackfillIsComplete,
      messages: [message],
      threads: GmailInboxThread.group([message])
    ).mailboxResult(connectionId: connection.id)
  }
}

private actor UnifiedInboxPhaseGate {
  enum Phase: Hashable, Sendable {
    case cache
    case sync
    case backfill
    case navigation
  }

  private struct Suspension: Hashable {
    let connectionId: MailboxConnectionId
    let phase: Phase
  }

  private var cachedConnectionIds: Set<MailboxConnectionId> = []
  private var continuations: [Suspension: [CheckedContinuation<Void, Never>]] = [:]
  private let onStart: @Sendable (Phase) -> Void
  private var navigationConnectionIds: Set<MailboxConnectionId> = []
  private var releasedPhases: Set<Phase> = []
  private var releasedSuspensions: Set<Suspension> = []

  init(onStart: @escaping @Sendable (Phase) -> Void) {
    self.onStart = onStart
  }

  func suspendFirstCacheLoad(for connectionId: MailboxConnectionId) async {
    guard cachedConnectionIds.insert(connectionId).inserted else { return }
    await suspend(.cache, for: connectionId)
  }

  func suspendFirstNavigationLoad(for connectionId: MailboxConnectionId) async {
    guard navigationConnectionIds.insert(connectionId).inserted else { return }
    await suspend(.navigation, for: connectionId)
  }

  func suspend(_ phase: Phase, for connectionId: MailboxConnectionId) async {
    onStart(phase)
    let suspension = Suspension(connectionId: connectionId, phase: phase)
    guard
      !releasedPhases.contains(phase),
      !releasedSuspensions.contains(suspension)
    else { return }
    await withCheckedContinuation { continuation in
      continuations[suspension, default: []].append(continuation)
    }
  }

  func release(_ phase: Phase) {
    releasedPhases.insert(phase)
    let phaseSuspensions = continuations.keys.filter { $0.phase == phase }
    let phaseContinuations = phaseSuspensions.flatMap {
      continuations.removeValue(forKey: $0) ?? []
    }
    for continuation in phaseContinuations {
      continuation.resume()
    }
  }

  func release(_ phase: Phase, for connectionId: MailboxConnectionId) {
    let suspension = Suspension(connectionId: connectionId, phase: phase)
    releasedSuspensions.insert(suspension)
    let suspensionContinuations = continuations.removeValue(forKey: suspension) ?? []
    for continuation in suspensionContinuations {
      continuation.resume()
    }
  }
}

private actor DelayedMailboxBodyPrefetcher: MailboxMessageBodyPrefetching {
  private var connectionIds: [MailboxConnectionId] = []
  private var pinnedThreadIds: [Set<StableThreadIdentity>] = []
  private var continuation: CheckedContinuation<Void, Never>?
  private var startContinuations: [CheckedContinuation<Void, Never>] = []

  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedThreadIds: Set<StableThreadIdentity>,
    referenceDate _: Date,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    connectionIds.append(connection.id)
    self.pinnedThreadIds.append(pinnedThreadIds)
    let continuations = startContinuations
    startContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func receivedConnectionIds() -> [MailboxConnectionId] {
    connectionIds
  }

  func receivedPinnedThreadIds() -> [Set<StableThreadIdentity>] {
    pinnedThreadIds
  }

  func waitUntilStarted() async {
    guard connectionIds.isEmpty else { return }
    await withCheckedContinuation { continuation in
      startContinuations.append(continuation)
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private enum MailboxSwitchingError: Error {
  case historicalCategorizationFailed
}

private struct OfflineUpgradeSyncError: LocalizedError {
  var errorDescription: String? { "Provider unavailable." }
}

private actor StaleSyncRecoveryMailboxService:
  MailboxMetadataSyncing, MailboxMessageSearching
{
  let originalProviderAccountIdentifier: String
  let switchedMessage: GmailMessageMetadata
  private let recoveryGate = OverrideGate()
  private var originalLoadCount = 0

  init(
    originalProviderAccountIdentifier: String,
    switchedMessage: GmailMessageMetadata
  ) {
    self.originalProviderAccountIdentifier = originalProviderAccountIdentifier
    self.switchedMessage = switchedMessage
  }

  func loadInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await loadMailbox(.role(.inbox), connection: connection, session: session)
  }

  func loadMailbox(
    _: MailboxMessageCollection,
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    guard connection.providerMailboxIdentity.value == originalProviderAccountIdentifier else {
      let message = switchedMessage.mailboxMetadata(connectionId: connection.id)
      return MailboxMetadataSyncResult(
        hasUnlistedNewMessages: false,
        messages: [message],
        newMessageIds: nil,
        providerCursorIsExpired: false,
        threads: MailboxThread.group([message])
      )
    }
    originalLoadCount += 1
    if originalLoadCount > 1 {
      await recoveryGate.waitForRelease()
    }
    return .empty
  }

  func syncInbox(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    throw OfflineUpgradeSyncError()
  }

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection _: MailboxConnection,
    includingHistoryCandidates _: Bool,
    session _: ProductAccountSessionSnapshot,
    sinceHistoryId _: String?,
    throughHistoryId _: String?,
    shouldPersist _: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    throw OfflineUpgradeSyncError()
  }

  func categorizeHistorical(
    scope _: HistoricalCategorizationScope,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    throw OfflineUpgradeSyncError()
  }

  func overrideCategory(
    _: String,
    for _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    throw OfflineUpgradeSyncError()
  }

  func setCategories(
    _: [String],
    for _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    throw OfflineUpgradeSyncError()
  }

  func searchProvider(
    query _: String,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata] {
    []
  }

  func waitUntilRecoveryStarts() async {
    await recoveryGate.waitUntilStarted()
  }

  func releaseRecovery() async {
    await recoveryGate.release()
  }
}

private actor OfflineUpgradeMailboxService: MailboxMetadataSyncing, MailboxMessageSearching {
  let cachedMessage: GmailMessageMetadata
  let completesIndexUpgradeDuringNavigation: Bool
  private var hasCompletedIndexUpgrade = false
  private var loadInboxCallCount = 0
  private var loadNavigationCallCount = 0
  private var loadProviderMailboxesCallCount = 0
  private var syncInboxCallCount = 0

  var callCounts: (loadInbox: Int, syncInbox: Int) {
    (loadInboxCallCount, syncInboxCallCount)
  }

  var navigationCallCounts: (loadNavigation: Int, loadProviderMailboxes: Int) {
    (loadNavigationCallCount, loadProviderMailboxesCallCount)
  }

  init(
    cachedMessage: GmailMessageMetadata,
    completesIndexUpgradeDuringNavigation: Bool = false
  ) {
    self.cachedMessage = cachedMessage
    self.completesIndexUpgradeDuringNavigation = completesIndexUpgradeDuringNavigation
  }

  func categorizeHistorical(
    scope _: HistoricalCategorizationScope,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    throw OfflineUpgradeSyncError()
  }

  func loadInbox(
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    loadInboxCallCount += 1
    guard hasCompletedIndexUpgrade else {
      throw GmailMessageMetadataStoreError.inboxIndexMigrationPending
    }
    let message = cachedMessage.mailboxMetadata(connectionId: connection.id)
    return MailboxMetadataSyncResult(
      hasUnlistedNewMessages: false,
      messages: [message],
      newMessageIds: nil,
      providerCursorIsExpired: false,
      threads: MailboxThread.group([message])
    )
  }

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    if collection == .role(.inbox) {
      return try await loadInbox(connection: connection, session: session)
    }
    loadNavigationCallCount += 1
    if completesIndexUpgradeDuringNavigation {
      hasCompletedIndexUpgrade = true
    }
    return .empty
  }

  func loadProviderMailboxes(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [ProviderMailbox] {
    loadProviderMailboxesCallCount += 1
    throw OfflineUpgradeSyncError()
  }

  func syncInbox(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    syncInboxCallCount += 1
    hasCompletedIndexUpgrade = true
    throw OfflineUpgradeSyncError()
  }

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection _: MailboxConnection,
    includingHistoryCandidates _: Bool,
    session _: ProductAccountSessionSnapshot,
    sinceHistoryId _: String?,
    throughHistoryId _: String?,
    shouldPersist _: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    throw OfflineUpgradeSyncError()
  }

  func overrideCategory(
    _: String,
    for _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    throw OfflineUpgradeSyncError()
  }

  func setCategories(
    _: [String],
    for _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    throw OfflineUpgradeSyncError()
  }

  func searchProvider(
    query _: String,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata] {
    []
  }
}

private struct MailboxSwitchingLocalizedError: LocalizedError {
  let description: String

  var errorDescription: String? { description }
}

private struct GmailMessageMetadataSyncFixture {
  let eligibilityStore: RecordingGmailPushEligibilityStore
  let requestRecorder: GmailMetadataRequestRecorder
  let service: GmailMessageMetadataService
  let store: RecordingGmailMessageMetadataStore
  let tokenStore: RecordingGmailProviderTokenStore
}

private final class GmailMetadataRequestRecorder {
  var authorizationHeaders: [String?] = []
  var paths: [String] = []
  var queries: [String] = []
}

private actor MailboxCallRecorder {
  private(set) var historicalBackfillCount = 0
  private(set) var syncCount = 0

  func recordHistoricalBackfill() {
    historicalBackfillCount += 1
  }

  func recordSync() {
    syncCount += 1
  }
}

private final class RecordingGmailMessageCategorizer: GmailMessageCategorizing {
  private let categoryId: String?
  private(set) var receivedHistoricalScope: GmailHistoricalCategorizationScope?
  private(set) var receivedMessages: [GmailMessageMetadata] = []
  private(set) var receivedRecordScopes: [MailProfileRecordScope] = []

  init(categoryId: String? = nil) {
    self.categoryId = categoryId
  }

  func categorize(
    messages: [GmailMessageMetadata],
    recordScope: MailProfileRecordScope,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    receivedMessages = messages
    receivedRecordScopes.append(recordScope)
    guard let categoryId else {
      return messages
    }
    return messages.map { $0.assigningCategory(categoryId) }
  }

  func categorizeHistorical(
    messages: [GmailMessageMetadata],
    scope: GmailHistoricalCategorizationScope,
    recordScope: MailProfileRecordScope,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    receivedHistoricalScope = scope
    receivedMessages = messages
    receivedRecordScopes.append(recordScope)
    guard let categoryId else {
      return messages
    }
    return messages.map { message in
      scope.contains(message) ? message.assigningCategory(categoryId) : message
    }
  }

  func overrideCategory(
    _ categoryId: String,
    for message: GmailMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageMetadata {
    message.assigningCategory(categoryId)
  }
}

private struct FixedNotificationProfileResolver: NotificationProfileResolving {
  let resolution: NotificationProfileResolution

  func resolve(
    connectionId _: MailboxConnectionId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> NotificationProfileResolution {
    resolution
  }
}

private struct GmailMailActionFixture {
  let recorder: GmailMailActionRequestRecorder
  let service: GmailMessageMetadataService
}

private final class GmailMailActionRequestRecorder {
  var requests: [GmailMailActionRequest] = []
}

private struct GmailMailActionRequest {
  let jsonBody: [String: Any]
  let method: String
  let path: String

  init(request: URLRequest) {
    method = request.httpMethod ?? "GET"
    path = request.url?.path ?? ""
    jsonBody =
      (try? JSONSerialization.jsonObject(with: Self.bodyData(for: request))) as? [String: Any]
      ?? [:]
  }

  private static func bodyData(for request: URLRequest) -> Data {
    if let body = request.httpBody {
      return body
    }

    guard let stream = request.httpBodyStream else {
      return Data()
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
      let count = stream.read(buffer, maxLength: bufferSize)
      if count <= 0 {
        break
      }
      data.append(buffer, count: count)
    }

    return data
  }
}

private final class RecordingGmailMessageMetadataStore: GmailMessageMetadataPersisting {
  var didClear = false
  var messages: [GmailMessageMetadata] = []
  var saveError: Error?
  var savedMessages: [GmailMessageMetadata] = []
  var syncState: GmailMetadataSyncState?

  func clearMessages(productAccountId _: String) throws {
    didClear = true
    messages = []
    savedMessages = []
  }

  func clearMessages(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    didClear = true
    messages = []
    savedMessages = []
  }

  func loadMessages(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> [GmailMessageMetadata] {
    return messages
  }

  func loadSyncState(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> GmailMetadataSyncState? {
    syncState
  }

  func saveSyncPage(
    _ pageMessages: [GmailMessageMetadata],
    state: GmailMetadataSyncState,
    isFirstPage _: Bool,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    if let saveError {
      throw saveError
    }
    var messagesByStableId = Dictionary(
      uniqueKeysWithValues: messages.map { ($0.stableProviderMessageId, $0) }
    )
    for message in pageMessages {
      messagesByStableId[message.stableProviderMessageId] = message
    }
    messages = messagesByStableId.values.sorted {
      $0.providerInternalDateMilliseconds > $1.providerInternalDateMilliseconds
    }
    savedMessages = messages
    syncState = state
  }

  func saveMessages(
    _ messages: [GmailMessageMetadata],
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    if let saveError {
      throw saveError
    }
    savedMessages = messages
    self.messages = messages
  }
}

private final class RecordingGmailPushEligibilityStore: GmailPushEligibilityPersisting {
  private var records: [String: String] = [:]

  func record(
    _ messages: [GmailMessageMetadata],
    throughHistoryId: String,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    for message in messages {
      if let historyId = records[message.stableProviderMessageId],
        !gmailHistoryIdIsNewer(throughHistoryId, than: historyId)
      {
        continue
      }
      records[message.stableProviderMessageId] = throughHistoryId
    }
  }

  func eligibleStableMessageIds(
    after historyId: String,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> Set<String> {
    Set(records.compactMap { gmailHistoryIdIsNewer($0.value, than: historyId) ? $0.key : nil })
  }

  func discard(
    through historyId: String,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    records = records.filter { gmailHistoryIdIsNewer($0.value, than: historyId) }
  }
}

private enum GmailMessageMetadataTestError: Error {
  case interruptedPersistence
}

private final class RecordingGmailMessageSearchService: MailboxMessageSearching {
  private let messages: [MailboxMessageMetadata]
  private(set) var receivedQueries: [String] = []
  private(set) var receivedConnections: [MailboxConnection] = []

  init(messages: [GmailMessageMetadata]) {
    self.messages = messages.map { $0.mailboxMetadata(connectionId: $0.mailboxConnectionId) }
  }

  func searchProvider(
    query: String,
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata] {
    receivedQueries.append(query)
    receivedConnections.append(connection)
    return messages
  }
}

private final class DelayedGmailMessageSearchService: MailboxMessageSearching {
  private let messages: [MailboxMessageMetadata]
  private let searchGate = OverrideGate()
  private(set) var receivedConnections: [MailboxConnection] = []

  init(messages: [GmailMessageMetadata]) {
    self.messages = messages.map { $0.mailboxMetadata(connectionId: $0.mailboxConnectionId) }
  }

  func searchProvider(
    query _: String,
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata] {
    receivedConnections.append(connection)
    await searchGate.waitForRelease()
    return messages
  }

  func waitUntilSearchStarts() async {
    await searchGate.waitUntilStarted()
  }

  func releaseSearch() async {
    await searchGate.release()
  }
}

private final class DelayedMailboxMessageReader: MailboxMessageReading {
  private let checksCancellationAfterRelease: Bool
  private let loadGate = OverrideGate()
  private(set) var loadBodyCallCount = 0
  private(set) var loadBodyTextCallCount = 0

  init(checksCancellationAfterRelease: Bool = false) {
    self.checksCancellationAfterRelease = checksCancellationAfterRelease
  }

  func clearCachedMessageBodies(session _: ProductAccountSessionSnapshot) throws {}

  func clearCachedMessageBodies(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) throws {}

  func loadMessageBody(
    message _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    loadBodyCallCount += 1
    await loadGate.waitForRelease()
    if checksCancellationAfterRelease {
      try Task.checkCancellation()
    }
    return MailboxMessageBody(text: "Body")
  }

  func loadMessageBodyText(
    message _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> String {
    loadBodyTextCallCount += 1
    return "Text-only body"
  }

  func removeCachedMessageBody(
    message _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws {}

  func waitUntilLoadStarts() async {
    await loadGate.waitUntilStarted()
  }

  func releaseLoad() async {
    await loadGate.release()
  }
}

private actor ConcurrentRemoteMessageContentLoadProbe {
  private var firstLoadReleaseContinuation: CheckedContinuation<Void, Never>?
  private var firstLoadStartContinuations: [CheckedContinuation<Void, Never>] = []
  private var hasStartedFirstLoad = false
  private(set) var requestedMaximumByteCounts: [Int] = []

  var requestCount: Int {
    requestedMaximumByteCounts.count
  }

  func load(
    maximumByteCount: Int,
    loadedByteCount: Int,
    resolvedHTML: SanitizedMessageHTML
  ) async -> RemoteMessageContentLoadResult {
    requestedMaximumByteCounts.append(maximumByteCount)
    if requestedMaximumByteCounts.count == 1 {
      hasStartedFirstLoad = true
      let continuations = firstLoadStartContinuations
      firstLoadStartContinuations.removeAll()
      for continuation in continuations {
        continuation.resume()
      }
      await withCheckedContinuation { continuation in
        firstLoadReleaseContinuation = continuation
      }
    }
    return RemoteMessageContentLoadResult(
      failedImageCount: 0,
      html: resolvedHTML,
      loadedByteCount: loadedByteCount,
      loadedImageCount: 1,
      loadedPixelCount: 1
    )
  }

  func waitUntilFirstLoadStarts() async {
    guard !hasStartedFirstLoad else { return }
    await withCheckedContinuation { continuation in
      firstLoadStartContinuations.append(continuation)
    }
  }

  func releaseFirstLoad() {
    firstLoadReleaseContinuation?.resume()
    firstLoadReleaseContinuation = nil
  }
}

private final class ImmediateMailboxMessageReader: MailboxMessageReading {
  private let bodies: [StableProviderMessageIdentity: MailboxMessageBody]
  private(set) var loadedBodyMessageIds: [StableProviderMessageIdentity] = []
  private(set) var loadBodyTextCallCount = 0

  init(bodyTexts: [StableProviderMessageIdentity: String]) {
    bodies = bodyTexts.mapValues { MailboxMessageBody(text: $0) }
  }

  init(bodies: [StableProviderMessageIdentity: MailboxMessageBody]) {
    self.bodies = bodies
  }

  func clearCachedMessageBodies(session _: ProductAccountSessionSnapshot) throws {}

  func clearCachedMessageBodies(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) throws {}

  func loadMessageBody(
    message: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    loadedBodyMessageIds.append(message.id)
    return bodies[message.id] ?? MailboxMessageBody(text: "")
  }

  func loadMessageBodyText(
    message _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> String {
    loadBodyTextCallCount += 1
    return "Provider body text"
  }

  func removeCachedMessageBody(
    message _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) throws {}
}

private final class RecordingGmailProviderTokenStore: GmailProviderTokenPersisting {
  var legacyTokensByProductAccountId: [String: GmailProviderTokens] = [:]
  var tokensByProductAccountId: [String: GmailProviderTokens] = [:]

  func clear(productAccountId: String) throws {
    tokensByProductAccountId[productAccountId] = nil
  }

  func clear(
    productAccountId: String,
    providerAccountIdentifier _: String
  ) throws {
    try clear(productAccountId: productAccountId)
  }

  func clearAll(productAccountId: String) throws {
    try clear(productAccountId: productAccountId)
  }

  func load(productAccountId: String) throws -> GmailProviderTokens? {
    tokensByProductAccountId[productAccountId]
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier _: String
  ) throws -> GmailProviderTokens? {
    try load(productAccountId: productAccountId)
  }

  func loadLegacy(productAccountId: String) throws -> GmailProviderTokens? {
    legacyTokensByProductAccountId[productAccountId]
  }

  func clearLegacy(productAccountId: String) throws {
    legacyTokensByProductAccountId[productAccountId] = nil
  }

  func saveLegacy(_ tokens: GmailProviderTokens, productAccountId: String) {
    legacyTokensByProductAccountId[productAccountId] = tokens
  }

  func save(
    _ tokens: GmailProviderTokens,
    productAccountId: String
  ) throws {
    tokensByProductAccountId[productAccountId] = tokens
  }

  func save(
    _ tokens: GmailProviderTokens,
    productAccountId: String,
    providerAccountIdentifier _: String
  ) throws {
    try save(tokens, productAccountId: productAccountId)
  }
}
