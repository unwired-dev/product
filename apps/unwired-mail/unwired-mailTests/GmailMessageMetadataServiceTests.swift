import SwiftData
import XCTest

@testable import unwired_mail

// swiftlint:disable file_length function_body_length type_body_length
final class GmailMessageMetadataServiceTests: XCTestCase {
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
      XCTAssertEqual(
        GmailLocalMetadataSearch.messages(
          in: messages,
          matching: query,
          categoryNamesById: categoryNamesById
        ),
        [matchingMessage],
        "Expected local metadata search to match \(query)"
      )
    }
    XCTAssertEqual(
      GmailLocalMetadataSearch.messages(
        in: messages,
        matching: "read",
        categoryNamesById: categoryNamesById
      ),
      [otherMessage]
    )
    XCTAssertEqual(
      GmailLocalMetadataSearch.messages(
        in: messages,
        matching: "text is not part",
        categoryNamesById: categoryNamesById
      ),
      []
    )
  }

  func testLocalMetadataSearchDoesNotInferStatesWhenLabelsAreMissing() {
    let message = metadata(
      messageId: "message-001",
      threadId: "thread-001",
      internalDateMilliseconds: 10
    )

    XCTAssertEqual(
      GmailLocalMetadataSearch.messages(
        in: [message],
        matching: "read",
        categoryNamesById: [:]
      ),
      []
    )
    XCTAssertEqual(
      GmailLocalMetadataSearch.messages(
        in: [message],
        matching: "unstarred",
        categoryNamesById: [:]
      ),
      []
    )
  }

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
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFirstURL.path))

    XCTAssertEqual(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: second.providerAccountIdentifier
      ),
      []
    )
    XCTAssertEqual(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: first.providerAccountIdentifier
      ),
      [first]
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFirstURL.path))

    try firstData.write(to: legacyFirstURL)
    try store.clearMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: first.providerAccountIdentifier
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFirstURL.path))
    XCTAssertEqual(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: first.providerAccountIdentifier
      ),
      []
    )
  }

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

    XCTAssertEqual(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: first.providerAccountIdentifier
      ),
      [first]
    )
    XCTAssertEqual(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: second.providerAccountIdentifier
      ),
      [second]
    )
  }

  func testSwiftDataMetadataStoreMigratesInboxIndexesWithoutDroppingArchivedMetadata() throws {
    let schema = Schema([
      DurableGmailMessageMetadataRecord.self,
      GmailMetadataSyncCheckpointRecord.self,
    ])
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

    XCTAssertEqual(
      try store.loadInboxThreadMessages(
        additionalProviderMessageIds: [],
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      [inboxMessage]
    )
    XCTAssertEqual(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      [inboxMessage, archivedMessage]
    )

    let indexedContext = ModelContext(container)
    let archivedRecord = try XCTUnwrap(
      indexedContext.fetch(FetchDescriptor<DurableGmailMessageMetadataRecord>())
        .first { $0.stableProviderMessageId == archivedMessage.stableProviderMessageId }
    )
    archivedRecord.encodedMessage = Data("not-json".utf8)
    try indexedContext.save()

    XCTAssertEqual(
      try store.loadInboxThreadMessages(
        additionalProviderMessageIds: [],
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      [inboxMessage]
    )
  }

  func testSwiftDataInboxIndexMigrationBoundsWorkPerLoad() throws {
    let schema = Schema([
      DurableGmailMessageMetadataRecord.self,
      GmailMetadataSyncCheckpointRecord.self,
    ])
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

    XCTAssertThrowsError(
      try store.loadInboxThreadMessages(
        additionalProviderMessageIds: ["message-archive-599"],
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
    ) { error in
      guard case GmailMessageMetadataStoreError.inboxIndexMigrationPending = error else {
        return XCTFail("Expected bounded Inbox index migration to remain pending.")
      }
    }

    let migratedContext = ModelContext(container)
    var records = try migratedContext.fetch(
      FetchDescriptor<DurableGmailMessageMetadataRecord>()
    )
    XCTAssertEqual(records.filter { $0.metadataIndexVersion == 0 }.count, 101)

    XCTAssertEqual(
      try store.loadInboxThreadMessages(
        additionalProviderMessageIds: [],
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      [inboxMessage]
    )
    let completedContext = ModelContext(container)
    records = try completedContext.fetch(FetchDescriptor<DurableGmailMessageMetadataRecord>())
    XCTAssertEqual(records.filter { $0.metadataIndexVersion == 0 }.count, 0)
  }

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

    XCTAssertEqual(
      try store.loadSyncState(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      interruptedState
    )

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

    XCTAssertEqual(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      [newest, older]
    )
    XCTAssertEqual(
      try store.loadSyncState(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      completedState
    )
  }

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

    XCTAssertEqual(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      [newest, older]
    )
  }

  func testSwiftDataMetadataStoreRestoresBackfillCheckpointAfterContainerRecreation() throws {
    let configurationName = "GmailMetadataRestart-\(UUID().uuidString)"
    let schema = Schema([
      DurableGmailMessageMetadataRecord.self,
      GmailMetadataSyncCheckpointRecord.self,
    ])
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
    XCTAssertEqual(
      try restartedStore.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      [message]
    )
    XCTAssertEqual(
      try restartedStore.loadSyncState(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      interruptedState
    )
  }

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

    XCTAssertEqual(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ).first?.categoryId,
      "system:promotions"
    )
  }

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

    XCTAssertEqual(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      [message]
    )
    XCTAssertEqual(
      try legacyStore.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      []
    )
    XCTAssertEqual(
      try store.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      [message]
    )
  }

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

    XCTAssertEqual(
      try store.loadInboxThreadMessages(
        additionalProviderMessageIds: [],
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      [message]
    )
    XCTAssertEqual(
      try legacyStore.loadMessages(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      []
    )
  }

  func testSyncInboxStoresMetadataWithStableProviderIdentityAndNoCategory() async throws {
    let fixture = try makeSyncFixture()

    let result = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    XCTAssertEqual(
      fixture.requestRecorder.paths,
      [
        "/token",
        "/tokeninfo",
        "/gmail/v1/users/me/messages",
        "/gmail/v1/users/me/messages/message-002",
        "/gmail/v1/users/me/messages/message-001",
      ]
    )
    XCTAssertEqual(result.messages.map(\.providerMessageId), ["message-002", "message-001"])
    XCTAssertEqual(result.threads.count, 1)
    XCTAssertEqual(result.threads[0].providerThreadId, "thread-001")
    XCTAssertEqual(result.threads[0].messages.count, 2)
    XCTAssertEqual(
      result.messages[0].stableProviderMessageId,
      "gmail:gmail-user-001:message-002"
    )
    XCTAssertTrue(result.messages.allSatisfy(\.isHistorical))
    XCTAssertTrue(result.messages.allSatisfy { $0.categoryId == nil })
    XCTAssertEqual(fixture.store.savedMessages, result.messages)
    XCTAssertEqual(
      try fixture.tokenStore.load(productAccountId: session.productAccountId),
      GmailProviderTokens(accessToken: "refreshed-access-token", refreshToken: "refresh-token")
    )
  }

  func testSyncInboxStoresReplyToHeader() async throws {
    let fixture = try makeSyncFixture(replyTo: "Replies <replies@example.com>")

    let result = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    XCTAssertEqual(
      result.messages.first { $0.providerMessageId == "message-002" }?.replyTo,
      "Replies <replies@example.com>"
    )
  }

  func testSyncInboxStoresRecipientAndProviderStateForLocalSearch() async throws {
    let fixture = try makeSyncFixture()

    let result = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )

    XCTAssertTrue(
      fixture.requestRecorder.queries
        .filter { $0.contains("format=metadata") }
        .allSatisfy {
          $0.contains("metadataHeaders=To")
            && $0.contains("metadataHeaders=Cc")
            && $0.contains("metadataHeaders=Bcc")
        }
    )
    XCTAssertEqual(
      result.messages.first?.recipientHeaders,
      [
        "User <user@example.com>",
        "Finance <finance@example.com>",
      ]
    )
    XCTAssertEqual(
      result.messages.first?.bccRecipients,
      [
        "Auditor <auditor@example.com>"
      ]
    )
    XCTAssertEqual(result.messages.first?.providerLabelIds, ["INBOX", "UNREAD"])
  }

  func testProviderFullTextSearchSendsQueryAndDoesNotPersistResults() async throws {
    let store = RecordingGmailMessageMetadataStore()
    let tokenStore = RecordingGmailProviderTokenStore()
    let recorder = GmailMetadataRequestRecorder()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let urlSession = ConvexClientTesting.makeSession { request in
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

    XCTAssertEqual(
      recorder.paths,
      [
        "/token",
        "/tokeninfo",
        "/gmail/v1/users/me/messages",
        "/gmail/v1/users/me/messages",
        "/gmail/v1/users/me/messages/message-001",
        "/gmail/v1/users/me/messages/message-002",
      ]
    )
    XCTAssertTrue(recorder.queries[2].contains("q=invoice%20total"))
    XCTAssertEqual(messages.map(\.providerMessageId), ["message-001", "message-002"])
    XCTAssertTrue(store.savedMessages.isEmpty)
  }

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

    XCTAssertEqual(result.threads.map(\.providerThreadId), ["thread-002", "thread-001"])
    XCTAssertEqual(
      result.threads[1].messages.map(\.providerMessageId), ["message-002", "message-001"])
  }

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

    XCTAssertEqual(result.messages.map(\.providerMessageId), ["message-inbox"])
    XCTAssertEqual(result.threads.map(\.providerThreadId), ["thread-visible"])
    XCTAssertEqual(
      result.threads[0].messages.map(\.providerMessageId),
      ["message-sent", "message-inbox"]
    )
  }

  func testLoadInboxDoesNotDecodeLargeArchivedMetadataSet() async throws {
    let schema = Schema([
      DurableGmailMessageMetadataRecord.self,
      GmailMetadataSyncCheckpointRecord.self,
    ])
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

    XCTAssertEqual(result.messages.map(\.providerMessageId), ["message-inbox"])
    XCTAssertEqual(
      result.threads.first?.messages.map(\.providerMessageId),
      ["message-sent", "message-inbox"]
    )

    let projectionCandidates = try await service.loadInboxProjectionCandidates(
      additionalProviderMessageIds: ["message-inbox", "message-archive-500"],
      connection: connection,
      session: session
    )
    XCTAssertEqual(
      projectionCandidates.messages.map(\.providerMessageId),
      ["message-sent", "message-inbox", "message-archive-501", "message-archive-500"]
    )
  }

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

    XCTAssertEqual(sent.messages.map(\.providerMessageId), ["message-sent"])
    XCTAssertEqual(
      sent.threads[0].messages.map(\.providerMessageId),
      ["message-sent", "message-inbox"]
    )
    XCTAssertEqual(archive.messages.map(\.providerMessageId), ["message-archived"])
    XCTAssertEqual(
      projects.messages.map(\.providerMessageId),
      ["message-archived", "message-inbox"]
    )
  }

  func testLoadProviderMailboxesUsesGmailNamesAndKeepsEmptyLabels() async throws {
    let fixture = try makeSyncFixture()

    let mailboxes = try await fixture.service.loadProviderMailboxes(
      connection: connection,
      session: session
    )

    XCTAssertEqual(
      mailboxes,
      [
        ProviderMailbox(id: "Label_empty", title: "Empty label"),
        ProviderMailbox(id: "Label_projects", title: "Projects"),
      ]
    )
    XCTAssertTrue(fixture.requestRecorder.paths.contains("/gmail/v1/users/me/labels"))
  }

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

    XCTAssertEqual(overridden.categoryId, "system:invoices")
    XCTAssertEqual(overridden.providerLabelIds, message.providerLabelIds)
    XCTAssertEqual(store.savedMessages, [overridden])
  }

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
    let service = GmailMessageMetadataService(
      categorizer: categorizer,
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

    XCTAssertEqual(categorizer.receivedHistoricalScope, scope)
    XCTAssertEqual(result.messages.map(\.categoryId), [nil, "system:promotions", nil])
    XCTAssertEqual(store.savedMessages, result.messages)
  }

  @MainActor
  func testInboxViewModelLoadsUnifiedInboxAcrossAuthorizedConnections() async {
    let fixture = makeUnifiedInboxViewModelFixture()

    await fixture.viewModel.loadUnifiedInbox(connections: fixture.connections)

    XCTAssertEqual(
      fixture.viewModel.threads.map(\.providerThreadId),
      ["thread-second", "thread-first"]
    )
    XCTAssertEqual(Set(fixture.viewModel.threads.map(\.id.connectionId)).count, 2)
    let syncInboxCallCount = await fixture.service.syncInboxCallCount()
    XCTAssertEqual(syncInboxCallCount, fixture.connections.count)
  }

  @MainActor
  func testInboxViewModelAppliesCategoryOverrideInUnifiedInbox() async throws {
    let fixture = makeUnifiedInboxViewModelFixture()
    await fixture.viewModel.loadUnifiedInbox(connections: fixture.connections)
    let message = try XCTUnwrap(
      fixture.viewModel.threads
        .flatMap(\.messages)
        .first(where: { $0.connectionId == fixture.connections[1].id })
    )

    let overrideTask = Task {
      await fixture.viewModel.overrideCategory("system:invoices", for: message)
    }
    await fixture.service.waitUntilOverrideStarts()
    await fixture.service.releaseOverride()
    await overrideTask.value

    XCTAssertEqual(
      fixture.viewModel.threads
        .flatMap(\.messages)
        .first(where: { $0.id == message.id })?
        .categoryId,
      "system:invoices"
    )
  }

  @MainActor
  func testInboxViewModelProjectsSuppliedPinsAndOutboxState() async {
    let fixture = makeUnifiedInboxViewModelFixture()
    let pinnedMessageId = StableProviderMessageIdentity(
      connectionId: fixture.connections[1].id,
      providerMessageId: "message-second"
    )
    fixture.viewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: [.failed],
        pinnedMessageIds: [pinnedMessageId]
      )
    )

    await fixture.viewModel.loadUnifiedMailbox(.pins, connections: fixture.connections)

    XCTAssertEqual(fixture.viewModel.threads.flatMap(\.messages).map(\.id), [pinnedMessageId])
    XCTAssertTrue(fixture.viewModel.navigationSnapshot.showsOutbox)
  }

  @MainActor
  func testInboxViewModelRevalidatesPinsBeforePublishingUnifiedPhaseResults() async {
    let syncStarts = expectation(description: "both pin syncs start")
    syncStarts.expectedFulfillmentCount = 2
    let phaseGate = UnifiedInboxPhaseGate { phase in
      if phase == .sync {
        syncStarts.fulfill()
      }
    }
    let fixture = makeUnifiedInboxViewModelFixture(phaseGate: phaseGate)
    let originalPin = StableProviderMessageIdentity(
      connectionId: fixture.connections[1].id,
      providerMessageId: "message-second"
    )
    let replacementPin = StableProviderMessageIdentity(
      connectionId: fixture.connections[0].id,
      providerMessageId: "message-first"
    )
    fixture.viewModel.updateProductMailboxState(
      MailShellProductMailboxState(outboxStates: [], pinnedMessageIds: [originalPin])
    )
    await fixture.viewModel.loadNavigation(connections: fixture.connections)

    let loadTask = Task { @MainActor in
      await fixture.viewModel.loadUnifiedMailbox(.pins, connections: fixture.connections)
    }
    await fulfillment(of: [syncStarts], timeout: 1)
    fixture.viewModel.updateProductMailboxState(
      MailShellProductMailboxState(outboxStates: [], pinnedMessageIds: [replacementPin])
    )
    await phaseGate.release(.sync)
    await loadTask.value

    XCTAssertEqual(
      fixture.viewModel.threads.flatMap(\.messages).map(\.id),
      [replacementPin]
    )
  }

  @MainActor
  func testInboxViewModelReprojectsUnifiedPinsFromCurrentPhaseData() async {
    let syncStarts = expectation(description: "both pin syncs start")
    syncStarts.expectedFulfillmentCount = 2
    let phaseGate = UnifiedInboxPhaseGate { phase in
      if phase == .sync {
        syncStarts.fulfill()
      }
    }
    let fixture = makeUnifiedInboxViewModelFixture(phaseGate: phaseGate)
    let originalPin = StableProviderMessageIdentity(
      connectionId: fixture.connections[1].id,
      providerMessageId: "message-second"
    )
    let replacementPin = StableProviderMessageIdentity(
      connectionId: fixture.connections[0].id,
      providerMessageId: "message-first"
    )
    fixture.viewModel.updateProductMailboxState(
      MailShellProductMailboxState(outboxStates: [], pinnedMessageIds: [originalPin])
    )

    let loadTask = Task { @MainActor in
      await fixture.viewModel.loadUnifiedMailbox(.pins, connections: fixture.connections)
    }
    await fulfillment(of: [syncStarts], timeout: 1)
    fixture.viewModel.updateProductMailboxState(
      MailShellProductMailboxState(outboxStates: [], pinnedMessageIds: [replacementPin])
    )
    await phaseGate.release(.sync)
    await loadTask.value

    XCTAssertEqual(
      fixture.viewModel.threads.flatMap(\.messages).map(\.id),
      [replacementPin]
    )
  }

  @MainActor
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
    XCTAssertEqual(syncInboxCallCount, fixture.connections.count)
    XCTAssertEqual(Set(fixture.viewModel.threads.map(\.id.connectionId)).count, 2)

    await fixture.service.releaseHistoricalBackfill()
    await loadTask.value
  }

  @MainActor
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
    XCTAssertTrue(fixture.viewModel.threads.isEmpty)
    await phaseGate.release(.cache)
    await fulfillment(of: [syncStarts], timeout: 1)
    XCTAssertEqual(
      fixture.viewModel.threads.map(\.providerThreadId),
      ["thread-second", "thread-first"]
    )
    await phaseGate.release(.sync)
    await fulfillment(of: [backfillStarts], timeout: 1)
    await phaseGate.release(.backfill)
    await loadTask.value

    XCTAssertEqual(
      fixture.viewModel.threads.map(\.providerThreadId),
      ["thread-second", "thread-first"]
    )
  }

  @MainActor
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
    XCTAssertEqual(historicalBackfillCallCount, 0)
    XCTAssertTrue(fixture.viewModel.threads.isEmpty)
  }

  @MainActor
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

    XCTAssertEqual(
      fixture.viewModel.errorMessage,
      [
        "\(fixture.connections[0].displayName): first failed",
        "\(fixture.connections[1].displayName): second failed",
      ].joined(separator: "\n")
    )
  }

  @MainActor
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
    XCTAssertFalse(fixture.viewModel.isLoading)
    XCTAssertTrue(fixture.viewModel.threads.isEmpty)
  }

  @MainActor
  func testInboxViewModelRefreshesOneUnifiedInboxConnectionWithoutDroppingOthers() async {
    let fixture = makeUnifiedInboxViewModelFixture()
    await fixture.viewModel.loadUnifiedInbox(connections: fixture.connections)
    let syncInboxCallCount = await fixture.service.syncInboxCallCount()
    fixture.viewModel.errorMessage = "Previous refresh failed"

    let didRefresh = await fixture.viewModel.refresh(connection: fixture.connections[0])

    XCTAssertTrue(didRefresh)
    XCTAssertNil(fixture.viewModel.errorMessage)
    let refreshedSyncInboxCallCount = await fixture.service.syncInboxCallCount()
    XCTAssertEqual(refreshedSyncInboxCallCount, syncInboxCallCount + 1)
    XCTAssertEqual(
      fixture.viewModel.threads.map(\.providerThreadId),
      ["thread-second", "thread-first"]
    )
  }

  @MainActor
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
    XCTAssertEqual(recentConnectionIds, fixture.connections.map(\.id))
    XCTAssertTrue(fullySyncedConnectionIds.isEmpty)
    XCTAssertTrue(reconciledConnectionIds.isEmpty)
    XCTAssertEqual(
      fixture.viewModel.status(for: unauthorizedConnection).phase,
      .authorizationRequired
    )
    for connection in fixture.connections {
      XCTAssertEqual(fixture.viewModel.status(for: connection).phase, .idle)
      XCTAssertEqual(
        fixture.viewModel.status(for: connection).lastSuccessfulSyncAt,
        fixture.now
      )
    }
    XCTAssertEqual(fixture.viewModel.lastSuccessfulSyncAt, fixture.now)
  }

  @MainActor
  func testMailboxFreshnessManualRefreshRunsFullGmailReconciliation() async {
    let fixture = makeMailboxFreshnessFixture()

    await fixture.viewModel.synchronizeFully(connections: fixture.connections)

    let recentConnectionIds = await fixture.service.recentlySyncedConnectionIds()
    let fullySyncedConnectionIds = await fixture.service.syncedConnectionIds()
    XCTAssertTrue(recentConnectionIds.isEmpty)
    XCTAssertEqual(fullySyncedConnectionIds, fixture.connections.map(\.id))
  }

  @MainActor
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
    XCTAssertTrue(recentConnectionIds.isEmpty)
    XCTAssertEqual(fullySyncedConnectionIds, [connection.id])
  }

  @MainActor
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
    XCTAssertEqual(overlappingCallCount, 1)

    await fixture.service.releaseSync()
    _ = try await first.value
    _ = try await second.value
    let completedCallCount = await fixture.service.syncCallCount()
    XCTAssertEqual(completedCallCount, 1)
  }

  @MainActor
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
    XCTAssertEqual(recentConnectionIds, [connection.id])
    XCTAssertEqual(fullConnectionIds, [connection.id])

    await fixture.service.releaseSync()
    await recent.value
    _ = try await full.value
  }

  @MainActor
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
    XCTAssertEqual(fixture.viewModel.status(for: connection).phase, .syncing)

    await fixture.service.releaseNextSync()
    _ = try await full.value
    XCTAssertEqual(fixture.viewModel.status(for: connection).phase, .idle)
  }

  @MainActor
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
      XCTFail("Expected cancelled caller to stop waiting for the shared sync")
    } catch is CancellationError {
    }
    _ = try await second.value

    let completedCallCount = await fixture.service.syncCallCount()
    XCTAssertEqual(completedCallCount, 1)
    XCTAssertEqual(
      fixture.viewModel.status(for: connection).lastSuccessfulSyncAt,
      fixture.now
    )
  }

  @MainActor
  func testMailboxFreshnessForegroundRecoversAfterOfflineFailure() async {
    let fixture = makeMailboxFreshnessFixture(outcomes: [.offline, .success])
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])

    XCTAssertEqual(fixture.viewModel.status(for: connection).phase, .offline)
    XCTAssertNil(fixture.viewModel.status(for: connection).lastSuccessfulSyncAt)

    await fixture.viewModel.synchronize(connections: [connection])

    XCTAssertEqual(fixture.viewModel.status(for: connection).phase, .idle)
    XCTAssertEqual(fixture.viewModel.status(for: connection).lastSuccessfulSyncAt, fixture.now)
    let syncCallCount = await fixture.service.syncCallCount()
    XCTAssertEqual(syncCallCount, 2)
  }

  @MainActor
  func testMailboxFreshnessForegroundCompletesReconciliationAfterMissedPush() async {
    let fixture = makeMailboxFreshnessFixture(
      outcomes: [.incomplete],
      suspendsBackfill: true
    )
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])
    await fixture.service.waitUntilHistoricalBackfillStarts()

    let reconciledConnectionIds = await fixture.service.reconciledConnectionIds()
    XCTAssertEqual(reconciledConnectionIds, [connection.id])
    XCTAssertTrue(fixture.viewModel.isHistoricalBackfillRunning(for: [connection.id]))
    XCTAssertFalse(
      fixture.viewModel.isHistoricalBackfillRunning(for: [fixture.connections[1].id])
    )
    XCTAssertEqual(fixture.viewModel.status(for: connection).phase, .syncing)
    XCTAssertEqual(fixture.viewModel.status(for: connection).lastSuccessfulSyncAt, fixture.now)

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

    XCTAssertEqual(fixture.viewModel.status(for: connection).phase, .idle)
  }

  @MainActor
  func testMailboxFreshnessDoesNotStartBackfillWithoutDurableCheckpoint() async {
    let fixture = makeMailboxFreshnessFixture(outcomes: [.incompleteWithoutCheckpoint])
    let connection = fixture.connections[0]

    await fixture.viewModel.synchronize(connections: [connection])

    let reconciledConnectionIds = await fixture.service.reconciledConnectionIds()
    XCTAssertTrue(reconciledConnectionIds.isEmpty)
    XCTAssertEqual(fixture.viewModel.status(for: connection).phase, .idle)
  }

  @MainActor
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
    XCTAssertEqual(recentConnectionIds, [connection.id, connection.id])
    XCTAssertEqual(reconciledConnectionIds, [connection.id, connection.id])

    await fixture.service.releaseHistoricalBackfill()
  }

  @MainActor
  func testMailboxFreshnessActivePollUsesFiveMinuteInterval() async {
    let sleeper = OneShotMailboxPollSleeper()
    let fixture = makeMailboxFreshnessFixture(sleep: sleeper.sleep)

    await fixture.viewModel.pollWhileActive(
      connections: { fixture.connections },
      didSynchronize: {}
    )

    let receivedDurations = await sleeper.receivedDurations()
    let syncCallCount = await fixture.service.syncCallCount()
    XCTAssertEqual(receivedDurations, [.seconds(300), .seconds(300)])
    XCTAssertEqual(syncCallCount, fixture.connections.count)
  }

  @MainActor
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
      XCTFail("Expected the in-flight mailbox synchronization to be cancelled")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected cancellation, got \(error)")
    }
    XCTAssertEqual(fixture.viewModel.status(for: connection).phase, .idle)
  }

  @MainActor
  func testMailboxFreshnessRejectsSynchronizationAfterSessionChanges() async {
    let fixture = makeMailboxFreshnessFixture()
    fixture.sessionState.isCurrent = false

    await fixture.viewModel.synchronize(connections: fixture.connections)

    let syncCallCount = await fixture.service.syncCallCount()
    XCTAssertEqual(syncCallCount, 0)
  }

  @MainActor
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

    XCTAssertEqual(
      restoredViewModel.status(for: connection).lastSuccessfulSyncAt,
      fixture.now
    )
  }

  @MainActor
  func testMailboxFreshnessClearsLastSuccessWhenConnectionIsRemoved() async {
    let fixture = makeMailboxFreshnessFixture()
    let connection = fixture.connections[0]
    await fixture.viewModel.synchronize(connections: [connection])

    fixture.viewModel.updateConnections([])

    XCTAssertNil(
      fixture.successStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    )
  }

  @MainActor
  func testMailboxFreshnessClearsLastSuccessRemovedBeforeViewModelStarts() {
    let fixture = makeMailboxFreshnessFixture()
    let removedConnection = fixture.connections[0]
    fixture.successStore.save(
      fixture.now,
      productAccountId: session.productAccountId,
      connectionId: removedConnection.id
    )

    fixture.viewModel.updateConnections([fixture.connections[1]])

    XCTAssertNil(
      fixture.successStore.load(
        productAccountId: session.productAccountId,
        connectionId: removedConnection.id
      )
    )
  }

  @MainActor
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

    XCTAssertEqual(
      fixture.successStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      ),
      fixture.now
    )
  }

  @MainActor
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

    XCTAssertEqual(fixture.viewModel.status(for: connection).phase, .backfillPending)
  }

  @MainActor
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

    _ = try await fixture.viewModel.syncInbox(connection: connection, session: session)

    let syncCallCount = await fixture.service.syncCallCount()
    XCTAssertEqual(syncCallCount, 1)
    XCTAssertEqual(fixture.viewModel.status(for: connection).phase, .idle)
    do {
      _ = try await backfill.value
      XCTFail("Expected foreground synchronization to cancel historical backfill")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected cancellation, got \(error)")
    }
  }

  @MainActor
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
      XCTFail("Expected the partial backfill failure to remain visible")
      return
    }
  }

  func testMailboxConnectionSyncGateSerializesPushAndPollForOneConnection() async {
    let gate = MailboxConnectionSyncGate()
    let probe = MailboxSyncGateProbe()
    let connectionId = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    ).id
    let initialAcquired = await gate.acquire(connectionId)
    XCTAssertTrue(initialAcquired)
    let pollAttempted = expectation(description: "poll attempted to acquire sync gate")
    let poll = Task {
      pollAttempted.fulfill()
      let pollAcquired = await gate.acquire(connectionId)
      XCTAssertTrue(pollAcquired)
      await probe.markPollAcquired()
      await gate.release(connectionId)
    }
    await fulfillment(of: [pollAttempted], timeout: 1)
    for _ in 0..<10 {
      await Task.yield()
    }

    let acquiredDuringPush = await probe.pollAcquired
    XCTAssertFalse(acquiredDuringPush)

    await gate.release(connectionId)
    await poll.value
    let acquiredAfterPush = await probe.pollAcquired
    XCTAssertTrue(acquiredAfterPush)
  }

  func testMailboxConnectionSyncGateKeepsLockWhenQueuedTaskIsCancelled() async {
    let gate = MailboxConnectionSyncGate()
    let probe = MailboxSyncGateProbe()
    let connectionId = connection.mailboxConnection(
      productAccountId: session.productAccountId,
      authorizationState: .authorized
    ).id
    let initialAcquired = await gate.acquire(connectionId)
    XCTAssertTrue(initialAcquired)

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
      XCTAssertTrue(nextAcquired)
      await probe.markPollAcquired()
      await gate.release(connectionId)
    }
    for _ in 0..<10 {
      await Task.yield()
    }
    let acquiredBeforeRelease = await probe.pollAcquired
    XCTAssertFalse(acquiredBeforeRelease)

    await gate.release(connectionId)
    await nextWaiter.value
    let acquiredAfterRelease = await probe.pollAcquired
    XCTAssertTrue(acquiredAfterRelease)
  }

  @MainActor
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

    XCTAssertEqual(
      viewModel.threads,
      MailboxThread.group([
        switchedMessage.mailboxMetadata(connectionId: switchedMessage.mailboxConnectionId)
      ])
    )
  }

  @MainActor
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

    XCTAssertEqual(
      viewModel.threads,
      MailboxThread.group([
        cachedMessage.mailboxMetadata(connectionId: mailboxConnection.id)
      ])
    )
    XCTAssertEqual(viewModel.errorMessage, "Provider unavailable.")
    let callCounts = await service.callCounts
    let navigationCallCounts = await service.navigationCallCounts
    XCTAssertEqual(callCounts.loadInbox, 2)
    XCTAssertEqual(navigationCallCounts.loadNavigation, 0)
    XCTAssertEqual(navigationCallCounts.loadProviderMailboxes, 0)
    XCTAssertEqual(callCounts.syncInbox, 1)
  }

  @MainActor
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

    XCTAssertEqual(
      viewModel.threads,
      MailboxThread.group([
        switchedMessage.mailboxMetadata(connectionId: switchedMailboxConnection.id)
      ])
    )
    XCTAssertNil(viewModel.errorMessage)
  }

  @MainActor
  func testInboxViewModelLoadsInitialInboxBeforeNavigationMetadata() async {
    let service = RecordingMailboxFreshnessService(
      outcomes: [],
      suspendsSync: false,
      suspendsBackfill: false,
      completesBackfill: true,
      failsBackfill: false
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
    XCTAssertEqual(loadedCollections, [.role(.inbox), .allObserved, .allObserved])
  }

  @MainActor
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

    XCTAssertFalse(didFinishWaiting)

    await secondLoad.release()
    await waitTask.value

    XCTAssertTrue(didFinishWaiting)
  }

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

    XCTAssertTrue(
      newlyFailedConnectionIds(
        from: oldIds,
        to: newIds,
        mailboxObserversAreActive: false
      ).isEmpty
    )
    XCTAssertEqual(
      newlyFailedConnectionIds(
        from: oldIds,
        to: newIds,
        mailboxObserversAreActive: true
      ),
      [newlyFailedId]
    )
  }

  @MainActor
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

    XCTAssertEqual(
      viewModel.threads,
      MailboxThread.group([
        cachedMessage.mailboxMetadata(connectionId: mailboxConnection.id)
      ])
    )
    XCTAssertNil(viewModel.errorMessage)
    let callCounts = await service.callCounts
    let navigationCallCounts = await service.navigationCallCounts
    XCTAssertEqual(callCounts.loadInbox, 2)
    XCTAssertEqual(navigationCallCounts.loadNavigation, 1)
  }

  @MainActor
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

    XCTAssertEqual(viewModel.searchResult?.source, .localMetadata)
    XCTAssertEqual(
      viewModel.searchResult?.messages,
      [localMessage.mailboxMetadata(connectionId: mailboxConnection.id)]
    )

    viewModel.searchQuery = "private body phrase"
    await viewModel.searchProvider(connection: mailboxConnection)

    XCTAssertEqual(searchService.receivedQueries, ["private body phrase"])
    XCTAssertEqual(searchService.receivedConnections, [mailboxConnection])
    XCTAssertEqual(viewModel.searchResult?.source, .providerFullText)
    XCTAssertEqual(
      viewModel.searchResult?.messages,
      [providerMessage.mailboxMetadata(connectionId: mailboxConnection.id)]
    )
  }

  @MainActor
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

    XCTAssertEqual(
      viewModel.threads,
      MailboxThread.group([
        cachedMessage.mailboxMetadata(connectionId: cachedMessage.mailboxConnectionId)
      ])
    )
  }

  @MainActor
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
    let pinnedMessageId = StableProviderMessageIdentity(
      connectionId: mailboxConnection.id,
      providerMessageId: "message-pinned"
    )
    viewModel.updateProductMailboxState(
      MailShellProductMailboxState(outboxStates: [], pinnedMessageIds: [pinnedMessageId])
    )

    await viewModel.loadAfterConnectionChange(connection: mailboxConnection)
    await prefetcher.waitUntilStarted()

    XCTAssertEqual(
      viewModel.threads,
      MailboxThread.group([
        cachedMessage.mailboxMetadata(connectionId: cachedMessage.mailboxConnectionId)
      ])
    )
    XCTAssertFalse(viewModel.isBusy)
    let receivedConnectionIds = await prefetcher.receivedConnectionIds()
    XCTAssertEqual(receivedConnectionIds, [mailboxConnection.id])
    let receivedPinnedMessageIds = await prefetcher.receivedPinnedMessageIds()
    XCTAssertEqual(receivedPinnedMessageIds, [[pinnedMessageId]])
    await prefetcher.release()
  }

  @MainActor
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
    XCTAssertTrue(viewModel.threads.isEmpty)

    let pinnedMessageId = StableProviderMessageIdentity(
      connectionId: mailboxConnection.id,
      providerMessageId: cachedMessage.providerMessageId
    )
    let otherPinnedMessageId = StableProviderMessageIdentity(
      connectionId: otherMailboxConnection.id,
      providerMessageId: otherCachedMessage.providerMessageId
    )
    viewModel.updateProductMailboxState(
      MailShellProductMailboxState(
        outboxStates: [],
        pinnedMessageIds: [pinnedMessageId, otherPinnedMessageId]
      )
    )

    XCTAssertEqual(
      viewModel.threads,
      MailboxThread.group(
        [
          cachedMessage.mailboxMetadata(connectionId: mailboxConnection.id),
          otherCachedMessage.mailboxMetadata(connectionId: otherMailboxConnection.id),
        ]
      )
    )
  }

  @MainActor
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
    let pinnedMessageId = StableProviderMessageIdentity(
      connectionId: mailboxConnection.id,
      providerMessageId: "message-pinned"
    )
    viewModel.updateProductMailboxState(
      MailShellProductMailboxState(outboxStates: [], pinnedMessageIds: [pinnedMessageId])
    )

    viewModel.refreshBodyPrefetch(
      afterChanging: [pinnedMessageId],
      connections: [mailboxConnection]
    )
    await prefetcher.waitUntilStarted()

    let receivedConnectionIds = await prefetcher.receivedConnectionIds()
    XCTAssertEqual(receivedConnectionIds, [mailboxConnection.id])
    let receivedPinnedMessageIds = await prefetcher.receivedPinnedMessageIds()
    XCTAssertEqual(receivedPinnedMessageIds, [[pinnedMessageId]])
    await prefetcher.release()
  }

  @MainActor
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
    let pinnedMessageId = StableProviderMessageIdentity(
      connectionId: mailboxConnection.id,
      providerMessageId: "message-pinned"
    )
    viewModel.updateProductMailboxState(
      MailShellProductMailboxState(outboxStates: [], pinnedMessageIds: [pinnedMessageId])
    )

    viewModel.refreshPinnedBodyPrefetch(connections: [mailboxConnection])
    await prefetcher.waitUntilStarted()

    let receivedConnectionIds = await prefetcher.receivedConnectionIds()
    let receivedPinnedMessageIds = await prefetcher.receivedPinnedMessageIds()
    XCTAssertEqual(receivedConnectionIds, [mailboxConnection.id])
    XCTAssertEqual(receivedPinnedMessageIds, [[pinnedMessageId]])
    await prefetcher.release()
  }

  @MainActor
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

    XCTAssertTrue(viewModel.isRefreshDisabled)
    XCTAssertFalse(viewModel.areCachedMetadataActionsDisabled)
    XCTAssertTrue(viewModel.isHistoricalBackfillRunning)
    let syncInboxCallCount = await service.syncInboxCallCount()
    XCTAssertEqual(syncInboxCallCount, 0)

    await service.releaseHistoricalBackfill()

    let backfillCompletion = expectation(description: "historical backfill completes")
    Task { @MainActor in
      while viewModel.isRefreshDisabled {
        await Task.yield()
      }
      backfillCompletion.fulfill()
    }
    await fulfillment(of: [backfillCompletion], timeout: 1)

    XCTAssertFalse(viewModel.isRefreshDisabled)
    XCTAssertFalse(viewModel.areCachedMetadataActionsDisabled)
    XCTAssertFalse(viewModel.isHistoricalBackfillRunning)
  }

  @MainActor
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

    XCTAssertTrue(viewModel.isHistoricalBackfillRunning(for: [mailboxConnection]))
    XCTAssertFalse(
      viewModel.areProviderActionsDisabledDuringHistoricalBackfill(for: [mailboxConnection])
    )
    XCTAssertEqual(
      viewModel.historicalBackfillConnectionIds(for: [mailboxConnection, currentConnection]),
      [mailboxConnection.id]
    )

    await service.releaseHistoricalBackfill()
    _ = try await backfill.value
    XCTAssertFalse(viewModel.isHistoricalBackfillRunning(for: [mailboxConnection]))
  }

  @MainActor
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

    XCTAssertTrue(
      viewModel.areProviderActionsDisabledDuringHistoricalBackfill(for: [graphConnection])
    )

    await service.releaseHistoricalBackfill()
    _ = try await backfill.value
  }

  @MainActor
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

    XCTAssertTrue(viewModel.isBusy)
    await reader.releaseLoad()
    let body = try await loadTask.value
    XCTAssertEqual(body, MailboxMessageBody(text: "Body"))
    XCTAssertFalse(viewModel.isBusy)
  }

  @MainActor
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
    XCTAssertEqual(searchService.receivedConnections, [mailboxConnection])
    viewModel.searchQuery = "flight"
    await searchService.releaseSearch()
    await searchTask.value

    XCTAssertNil(viewModel.searchResult)
  }

  @MainActor
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

    XCTAssertNil(viewModel.errorMessage)
  }

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

    XCTAssertTrue(result.messages.allSatisfy(\.isHistorical))
  }

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

    XCTAssertEqual(
      result.messages.first { $0.providerMessageId == "message-001" }?.isHistorical,
      true
    )
  }

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

    XCTAssertEqual(
      result.messages.first { $0.providerMessageId == "message-002" }?.isHistorical,
      true
    )
  }

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

    XCTAssertTrue(categorizer.receivedMessages.allSatisfy { !$0.isHistorical })
    XCTAssertEqual(
      categorizer.receivedMessages.map(\.stableProviderMessageId),
      ["gmail:gmail-user-001:message-002", "gmail:gmail-user-001:message-001"]
    )
    XCTAssertTrue(result.messages.allSatisfy { $0.categoryId == "system:promotions" })
    XCTAssertEqual(fixture.store.savedMessages, result.messages)
  }

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

    XCTAssertEqual(categorizer.receivedMessages.map(\.providerMessageId), ["message-001"])
    let savedMessageTwo = try XCTUnwrap(
      fixture.store.savedMessages.first { $0.providerMessageId == "message-002" }
    )
    XCTAssertNil(savedMessageTwo.categoryId)
  }

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

    XCTAssertEqual(
      fixture.store.syncState?.initialHistoricalCutoffMilliseconds,
      reconnectedConnection.updatedAt
    )
  }

  func testSyncInboxFollowsGmailPaginationBeforeSavingMetadata() async throws {
    let fixture = try makeSyncFixture(usesPagination: true)

    let initial = try await fixture.service.syncInbox(
      connection: connection,
      session: session
    )
    XCTAssertTrue(initial.hasInitialMailboxAvailability)
    XCTAssertFalse(initial.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(initial.messages.map(\.providerMessageId), ["message-003", "message-002"])
    let result = try await fixture.service.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    XCTAssertTrue(result.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(
      result.messages.map(\.providerMessageId),
      [
        "message-003",
        "message-002",
        "message-001",
      ])
    XCTAssertEqual(
      fixture.requestRecorder.queries.filter { $0.contains("maxResults=50") },
      [
        "maxResults=50&includeSpamTrash=true",
        "maxResults=50&includeSpamTrash=true&pageToken=next-page-token",
      ]
    )
    XCTAssertEqual(
      fixture.store.savedMessages.map(\.providerMessageId),
      [
        "message-003",
        "message-002",
        "message-001",
      ])
  }

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

    XCTAssertTrue(result.hasInitialMailboxAvailability)
    XCTAssertFalse(result.historicalMetadataBackfillIsComplete)
  }

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

    XCTAssertTrue(result.hasInitialMailboxAvailability)
    XCTAssertTrue(result.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(
      fixture.requestRecorder.queries.filter { $0.contains("maxResults=50") },
      [
        "maxResults=50&includeSpamTrash=true",
        "maxResults=50&includeSpamTrash=true&pageToken=next-page-token",
      ]
    )
    XCTAssertNotNil(fixture.store.syncState)
  }

  func testSyncInboxRefreshesNewestMessagesBeforeResumingBackfill() async throws {
    let fixture = try makeSyncFixture(usesPagination: true)

    _ = try await fixture.service.syncInbox(connection: connection, session: session)
    fixture.requestRecorder.queries = []

    let result = try await fixture.service.syncInbox(connection: connection, session: session)

    XCTAssertFalse(result.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(
      fixture.requestRecorder.queries.filter { $0.contains("maxResults=50") },
      ["maxResults=50&includeSpamTrash=true"]
    )
  }

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

    XCTAssertFalse(deferred.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(
      fixture.requestRecorder.queries.filter { $0.contains("maxResults=50") },
      ["maxResults=50&includeSpamTrash=true"]
    )

    shouldContinueBackfill = true
    let resumed = try await fixture.service.continueHistoricalBackfill(
      connection: connection,
      session: session
    )

    XCTAssertTrue(resumed.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(
      resumed.messages.map(\.providerMessageId),
      [
        "message-003", "message-002", "message-001",
      ])
  }

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

    XCTAssertTrue(result.historicalMetadataBackfillIsComplete)
    XCTAssertEqual(
      result.messages.map(\.providerMessageId),
      ["message-003", "message-002", "message-001"]
    )
    XCTAssertEqual(
      fixture.requestRecorder.queries.filter { $0.contains("maxResults=50") },
      [
        "maxResults=50&includeSpamTrash=true",
        "maxResults=50&includeSpamTrash=true&pageToken=next-page-token",
        "maxResults=50&includeSpamTrash=true",
        "maxResults=50&includeSpamTrash=true&pageToken=next-page-token",
      ]
    )
  }

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
      XCTFail("Expected the generic Gmail request failure to preserve the checkpoint.")
    } catch {
      XCTAssertEqual(error as? GmailMessageMetadataSyncError, .gmailRequestFailed)
    }

    XCTAssertEqual(fixture.store.syncState?.nextPageToken, "next-page-token")
  }

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

    XCTAssertEqual(result.messages.map(\.providerMessageId), ["message-003", "message-002"])
    XCTAssertEqual(
      fixture.store.savedMessages.map(\.providerMessageId),
      [
        "message-003", "message-002", "message-001",
      ])
  }

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

    XCTAssertTrue(categorizer.receivedMessages.isEmpty)
    let savedMessageOne = try XCTUnwrap(
      fixture.store.savedMessages.first { $0.providerMessageId == "message-001" }
    )
    XCTAssertNil(savedMessageOne.categoryId)
  }

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
      XCTFail("Expected refreshed token account mismatch")
    } catch GmailMessageMetadataSyncError.refreshedTokenAccountMismatch {
      XCTAssertEqual(fixture.store.savedMessages, [])
      XCTAssertNil(
        try fixture.tokenStore.load(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        )
      )
      XCTAssertNotNil(
        try fixture.tokenStore.loadLegacy(productAccountId: session.productAccountId)
      )
      XCTAssertFalse(
        fixture.requestRecorder.paths.contains("/gmail/v1/users/me/messages")
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testSyncInboxRequiresDeviceHeldGmailTokens() async throws {
    let service = GmailMessageMetadataService(
      session: ConvexClientTesting.makeSession { request in
        XCTFail("Unexpected request: \(String(describing: request.url))")
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
      XCTFail("Expected missing local tokens")
    } catch GmailMessageMetadataSyncError.missingLocalGmailTokens {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testSyncInboxMigratesLegacyDeviceHeldGmailTokens() async throws {
    let fixture = try makeSyncFixture(usesLegacyTokens: true)

    _ = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session,
      sinceHistoryId: nil,
      throughHistoryId: nil,
      shouldPersist: { true }
    )

    XCTAssertEqual(
      try fixture.tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      ),
      GmailProviderTokens(
        accessToken: "refreshed-access-token",
        refreshToken: "refresh-token"
      )
    )
    XCTAssertNil(try fixture.tokenStore.loadLegacy(productAccountId: session.productAccountId))
  }

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
      .move(targetProviderMailboxId: "Label_projects"),
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

    XCTAssertEqual(
      fixture.recorder.requests.map(\.path),
      [
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/modify",
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/trash",
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/modify",
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/modify",
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/modify",
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/modify",
      ])
    XCTAssertEqual(fixture.recorder.requests[2].method, "POST")
    XCTAssertEqual(fixture.recorder.requests[2].jsonBody["addLabelIds"] as? [String], ["UNREAD"])
    XCTAssertEqual(fixture.recorder.requests[2].jsonBody["removeLabelIds"] as? [String], [])
    XCTAssertEqual(fixture.recorder.requests[5].method, "POST")
    XCTAssertEqual(
      fixture.recorder.requests[8].jsonBody["addLabelIds"] as? [String],
      ["Label_projects"]
    )
    XCTAssertEqual(fixture.recorder.requests[8].jsonBody["removeLabelIds"] as? [String], ["INBOX"])
    XCTAssertEqual(fixture.recorder.requests[11].jsonBody["addLabelIds"] as? [String], ["SPAM"])
    XCTAssertEqual(fixture.recorder.requests[11].jsonBody["removeLabelIds"] as? [String], ["INBOX"])
    XCTAssertEqual(fixture.recorder.requests[14].jsonBody["addLabelIds"] as? [String], ["INBOX"])
    XCTAssertEqual(fixture.recorder.requests[14].jsonBody["removeLabelIds"] as? [String], ["SPAM"])
    XCTAssertEqual(fixture.recorder.requests[17].method, "POST")
    XCTAssertEqual(fixture.recorder.requests[17].jsonBody["addLabelIds"] as? [String], ["INBOX"])
    XCTAssertEqual(fixture.recorder.requests[17].jsonBody["removeLabelIds"] as? [String], ["TRASH"])
  }

  func testProviderThreadActionsAuthorizeOnce() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.perform(
      .archive,
      messageIds: ["message-001", "message-002"],
      connection: connection,
      session: session
    )

    XCTAssertEqual(
      fixture.recorder.requests.map(\.path),
      [
        "/token", "/tokeninfo",
        "/gmail/v1/users/me/messages/message-001/modify",
        "/gmail/v1/users/me/messages/message-002/modify",
      ]
    )
  }

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

    XCTAssertEqual(
      fixture.requestRecorder.queries.filter { $0.contains("labelIds=INBOX") },
      ["labelIds=INBOX&maxResults=25"]
    )
    XCTAssertEqual(
      result.messages.map(\.providerMessageId),
      ["message-003", "message-002", "message-000"]
    )
    XCTAssertEqual(fixture.store.savedMessages, result.messages)
  }

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

    XCTAssertFalse(initial.historicalMetadataBackfillIsComplete)
    XCTAssertFalse(recent.historicalMetadataBackfillIsComplete)
  }

  func testSyncRecentInboxTreatsMissingHistoricalBackfillStateAsIncomplete() async throws {
    let fixture = try makeSyncFixture(usesPagination: true)

    let result = try await fixture.service.syncRecentInbox(
      connection: connection,
      session: session
    )

    XCTAssertFalse(result.historicalMetadataBackfillIsComplete)
  }

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

    XCTAssertEqual(
      fixture.requestRecorder.queries.first { $0.contains("startHistoryId") },
      "startHistoryId=123"
    )
    XCTAssertTrue(result.messages.contains { $0.providerMessageId == "message-preserved" })
    XCTAssertFalse(result.messages.contains { $0.providerMessageId == "message-archived" })
    XCTAssertFalse(result.messages.contains { $0.providerMessageId == "message-deleted" })
    XCTAssertEqual(
      fixture.store.savedMessages.first { $0.providerMessageId == "message-archived" }?
        .providerLabelIds,
      ["ARCHIVE"]
    )
    XCTAssertFalse(
      fixture.store.savedMessages.contains { $0.providerMessageId == "message-deleted" }
    )
  }

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

    XCTAssertEqual(
      result.messages.first { $0.providerMessageId == "message-preserved" }?.providerLabelIds,
      ["INBOX", "STARRED"]
    )
    XCTAssertEqual(
      fixture.store.savedMessages.first { $0.providerMessageId == "message-preserved" }?
        .providerLabelIds,
      ["INBOX", "STARRED"]
    )
  }

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

    XCTAssertEqual(result.newMessageIds, [])
    XCTAssertTrue(result.historyIsExpired)
    XCTAssertEqual(
      fixture.requestRecorder.queries.filter { $0.contains("maxResults=25") },
      [
        "maxResults=25&includeSpamTrash=true",
        "maxResults=25&includeSpamTrash=true&pageToken=next-page-token",
      ]
    )
    XCTAssertTrue(fixture.requestRecorder.paths.contains("/gmail/v1/users/me/messages/message-003"))
    XCTAssertTrue(fixture.requestRecorder.paths.contains("/gmail/v1/users/me/messages/message-002"))
    XCTAssertTrue(fixture.requestRecorder.paths.contains("/gmail/v1/users/me/messages/message-001"))
    XCTAssertFalse(result.messages.contains { $0.providerMessageId == "message-stale" })
    XCTAssertFalse(fixture.store.savedMessages.contains { $0.providerMessageId == "message-stale" })
    XCTAssertTrue(fixture.store.savedMessages.contains { $0.providerMessageId == "message-001" })
    XCTAssertTrue(
      categorizer.receivedMessages.allSatisfy { $0.providerLabelIds?.contains("INBOX") == true }
    )
    XCTAssertEqual(fixture.store.syncState?.historicalMetadataBackfillIsComplete, true)
    XCTAssertNil(fixture.store.syncState?.nextPageToken)
  }

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

    XCTAssertEqual(result.newMessageIds, [])
  }

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

    XCTAssertEqual(result.newMessageIds, [])
  }

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

    XCTAssertEqual(result.newMessageIds, ["message-002"])
  }

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

    XCTAssertEqual(result.newMessageIds, ["message-002"])
    XCTAssertEqual(
      fixture.store.savedMessages.first { $0.providerMessageId == "message-sent" }?
        .providerLabelIds,
      ["SENT"]
    )
    let sent = try await fixture.service.loadMailbox(
      .role(.sent),
      connection: connection,
      session: session
    )
    XCTAssertEqual(sent.messages.map(\.providerMessageId), ["message-sent"])
  }

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

    XCTAssertEqual(result.newMessageIds, ["message-002"])
  }

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

    XCTAssertEqual(result.newMessageIds, ["message-002"])
    XCTAssertEqual(
      fixture.requestRecorder.queries.filter { $0.contains("startHistoryId") },
      ["startHistoryId=123"]
    )
  }

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

    XCTAssertEqual(result.newMessageIds, ["message-001"])
    XCTAssertFalse(result.hasUnlistedNewMessages)
    XCTAssertEqual(
      fixture.requestRecorder.queries.filter { $0.contains("labelIds=INBOX") },
      [
        "labelIds=INBOX&maxResults=25",
        "labelIds=INBOX&maxResults=25&pageToken=next-page-token",
      ]
    )
  }

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

    XCTAssertFalse(result.hasUnlistedNewMessages)
    XCTAssertEqual(result.newMessageIds, ["message-001"])
  }

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
      XCTFail("Expected interrupted inbox persistence")
    } catch GmailMessageMetadataTestError.interruptedPersistence {
      XCTAssertEqual(
        try fixture.eligibilityStore.eligibleStableMessageIds(
          after: "123",
          productAccountId: session.productAccountId,
          providerAccountIdentifier: connection.providerAccountIdentifier
        ),
        ["gmail:gmail-user-001:message-002"]
      )
    }
  }

  func testSyncRecentInboxDoesNotPersistWhenConnectionChanges() async throws {
    let fixture = try makeSyncFixture()
    let originalTokens = try XCTUnwrap(
      fixture.tokenStore.load(productAccountId: session.productAccountId)
    )

    do {
      _ = try await fixture.service.syncRecentInbox(
        connection: connection,
        session: session,
        sinceHistoryId: nil,
        throughHistoryId: nil,
        shouldPersist: { false }
      )
      XCTFail("Expected stale local connection")
    } catch GmailMessageMetadataSyncError.staleLocalConnection {
      XCTAssertEqual(
        try fixture.tokenStore.load(productAccountId: session.productAccountId),
        originalTokens
      )
      XCTAssertTrue(fixture.store.savedMessages.isEmpty)
    }
  }

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
      XCTFail("Expected insufficient Gmail scope")
    } catch GmailMessageMetadataSyncError.insufficientGmailScope {
      XCTAssertEqual(fixture.recorder.requests.map(\.path), ["/token", "/tokeninfo"])
    }
  }

  func testSendAcceptsGmailModifyScope() async throws {
    let fixture = try makeMailActionFixture(
      tokenScopes: "https://www.googleapis.com/auth/gmail.modify"
    )

    try await fixture.service.send(
      GmailOutgoingMessage(body: "Café", recipient: "recipient@example.com", subject: "Subject"),
      connection: connection,
      session: session
    )

    XCTAssertEqual(fixture.recorder.requests.last?.path, "/gmail/v1/users/me/messages/send")
  }

  func testSendUsesGmailRawMessageEndpoint() async throws {
    let fixture = try makeMailActionFixture()

    try await fixture.service.send(
      GmailOutgoingMessage(body: "Café", recipient: "recipient@example.com", subject: "Subject"),
      connection: connection,
      session: session
    )

    let sentRequest = fixture.recorder.requests.last
    XCTAssertEqual(sentRequest?.path, "/gmail/v1/users/me/messages/send")
    XCTAssertEqual(sentRequest?.method, "POST")
    let raw = try XCTUnwrap(sentRequest?.jsonBody["raw"] as? String)
    let paddedRaw =
      raw.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try XCTUnwrap(Data(base64Encoded: paddedRaw))
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
    XCTAssertEqual(String(bytes: mime, encoding: .utf8), expectedMIME)
  }

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
    let urlSession = ConvexClientTesting.makeSession { request in
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
      XCTFail("Expected send failure")
    } catch {
      XCTAssertEqual(error as? GmailProviderMailActionError, .responseStatus(429))
    }
  }

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
    let urlSession = ConvexClientTesting.makeSession { request in
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
      XCTFail("Expected send failure")
    } catch {
      XCTAssertEqual(error as? GmailProviderMailActionError, .rateLimitedResponseStatus(403))
    }
  }

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

    let raw = try XCTUnwrap(fixture.recorder.requests.last?.jsonBody["raw"] as? String)
    let paddedRaw =
      raw.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try XCTUnwrap(Data(base64Encoded: paddedRaw))
    let mimeText = try XCTUnwrap(String(bytes: mime, encoding: .utf8))
    XCTAssertTrue(mimeText.contains("To: =?UTF-8?B?Sm9zw6kgR2FyY8OtYQ==?= <jose@example.com>"))
  }

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

    let raw = try XCTUnwrap(fixture.recorder.requests.last?.jsonBody["raw"] as? String)
    let paddedRaw =
      raw.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try XCTUnwrap(Data(base64Encoded: paddedRaw))
    let mimeText = try XCTUnwrap(String(bytes: mime, encoding: .utf8))
    XCTAssertTrue(
      mimeText.contains("To: Alice <alice@example.com>, =?UTF-8?B?Sm9zw6k=?= <jose@example.com>")
    )
  }

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

    let raw = try XCTUnwrap(fixture.recorder.requests.last?.jsonBody["raw"] as? String)
    let paddedRaw =
      raw.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try XCTUnwrap(Data(base64Encoded: paddedRaw))
    let mimeText = try XCTUnwrap(String(bytes: mime, encoding: .utf8))
    XCTAssertTrue(mimeText.contains("To: =?UTF-8?B?IkdhcmPDrWEsIEpvc8OpIg==?= <jose@example.com>"))
  }

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

    let sentRequest = try XCTUnwrap(fixture.recorder.requests.last)
    XCTAssertEqual(sentRequest.jsonBody["threadId"] as? String, "thread-001")
    let raw = try XCTUnwrap(sentRequest.jsonBody["raw"] as? String)
    let paddedRaw = raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)
    let mime = try XCTUnwrap(Data(base64Encoded: paddedRaw))
    let mimeText = try XCTUnwrap(String(bytes: mime, encoding: .utf8))
    XCTAssertTrue(mimeText.contains("In-Reply-To: <original@example.com>"))
    XCTAssertTrue(mimeText.contains("References: <original@example.com>"))

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
      XCTFail("Expected header validation failure")
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
    let urlSession = ConvexClientTesting.makeSession { request in
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
    labelIds: [String]? = ["INBOX", "UNREAD"]
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
            {"name": "Subject", "value": "Thread subject"}\(replyToHeader)
          ]
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
    let urlSession = ConvexClientTesting.makeSession { request in
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
    historyStatusCode: Int,
    historyResponseData: Data
  ) -> (HTTPURLResponse, Data) {
    requestRecorder.paths.append(request.url?.path ?? "")
    requestRecorder.queries.append(request.url?.query ?? "")

    if request.url?.path == "/token" {
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Content-Type"),
        "application/x-www-form-urlencoded"
      )
      return (
        Self.httpResponse(for: request, statusCode: 200),
        Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
      )
    }

    if request.url?.path == "/tokeninfo" {
      XCTAssertEqual(request.url?.query, "access_token=refreshed-access-token")
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

    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"),
      "Bearer refreshed-access-token"
    )

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
        XCTAssertFalse(request.url?.query?.contains("labelIds=INBOX") == true)
      } else {
        XCTAssertTrue(request.url?.query?.contains("labelIds=INBOX") == true)
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
        messageIdsWithoutLabelIds: messageIdsWithoutLabelIds
      )
    )
  }

  private func makeMessageMetadataResponseData(
    for request: URLRequest,
    replyTo: String?,
    labelIdsByMessageId: [String: [String]],
    messageIdsWithoutLabelIds: Set<String>
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
        labelIds: labelIds
      )
    }

    if request.url?.path == "/gmail/v1/users/me/messages/message-003" {
      return Self.messageMetadataResponseData(
        messageId: "message-003",
        internalDate: "1781199000000",
        snippet: "Newest message snippet",
        replyTo: replyTo,
        labelIds: labelIds
      )
    }

    return Self.messageMetadataResponseData(
      messageId: messageId,
      internalDate: "1781197200000",
      snippet: "Latest message snippet",
      replyTo: replyTo,
      labelIds: labelIds
    )
  }

  @MainActor
  private func makeUnifiedInboxViewModelFixture(
    historicalMessagesByProviderAccount: [String: GmailMessageMetadata] = [:],
    delaysHistoricalBackfill: Bool = false,
    delaysNavigationRefresh: Bool = false,
    syncErrorsByProviderAccount: [String: String] = [:],
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
      failsBackfill: failsBackfill
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
  private let suspendsBackfill: Bool
  private let suspendsSync: Bool

  init(
    outcomes: [Outcome],
    suspendsSync: Bool,
    suspendsBackfill: Bool,
    completesBackfill: Bool,
    failsBackfill: Bool
  ) {
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
  var delaysHistoricalBackfill = false
  var delaysNavigationRefresh = false
  var syncErrorsByProviderAccount: [String: String] = [:]
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
    await overrideGate.waitForRelease()
    return message.gmailMetadata.assigningCategory(categoryId).mailboxMetadata(
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
  private var pinnedMessageIds: [Set<StableProviderMessageIdentity>] = []
  private var continuation: CheckedContinuation<Void, Never>?
  private var startContinuations: [CheckedContinuation<Void, Never>] = []

  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
    referenceDate _: Date,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    connectionIds.append(connection.id)
    self.pinnedMessageIds.append(pinnedMessageIds)
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

  func receivedPinnedMessageIds() -> [Set<StableProviderMessageIdentity>] {
    pinnedMessageIds
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

  init(categoryId: String? = nil) {
    self.categoryId = categoryId
  }

  func categorize(
    messages: [GmailMessageMetadata],
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    receivedMessages = messages
    guard let categoryId else {
      return messages
    }
    return messages.map { $0.assigningCategory(categoryId) }
  }

  func categorizeHistorical(
    messages: [GmailMessageMetadata],
    scope: GmailHistoricalCategorizationScope,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [GmailMessageMetadata] {
    receivedHistoricalScope = scope
    receivedMessages = messages
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
  private let loadGate = OverrideGate()

  func clearCachedMessageBodies(session _: ProductAccountSessionSnapshot) throws {}

  func clearCachedMessageBodies(
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) throws {}

  func loadMessageBody(
    message _: MailboxMessageMetadata,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    await loadGate.waitForRelease()
    return MailboxMessageBody(text: "Body")
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
