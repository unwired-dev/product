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
        "Auditor <auditor@example.com>",
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

    let overridden = try await service.overrideCategory(
      "system:invoices",
      for: message,
      session: session
    )

    XCTAssertEqual(overridden.categoryId, "system:invoices")
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
      connection: connection.mailboxConnection(productAccountId: session.productAccountId)
    )

    let overrideTask = Task {
      await viewModel.overrideCategory(
        "system:invoices",
        for: originalMessage.mailboxMetadata(connectionId: originalMessage.mailboxConnectionId)
      )
    }
    await service.waitUntilOverrideStarts()
    await viewModel.loadAfterConnectionChange(
      connection: switchedConnection.mailboxConnection(productAccountId: session.productAccountId)
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
      productAccountId: session.productAccountId
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
  func testInboxViewModelAutomaticallyResumesHistoricalBackfillAfterLoadingCache() async {
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
      connection: connection.mailboxConnection(productAccountId: session.productAccountId)
    )

    XCTAssertEqual(
      viewModel.threads,
      MailboxThread.group([
        historicalMessage.mailboxMetadata(connectionId: historicalMessage.mailboxConnectionId)
      ])
    )
  }

  @MainActor
  func testInboxViewModelDisablesRefreshWhileHistoricalBackfillRuns() async {
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
      delaysHistoricalBackfill: true
    )
    let viewModel = GmailInboxViewModel(
      service: service,
      searchService: service,
      session: session
    )
    let mailboxConnection = connection.mailboxConnection(productAccountId: session.productAccountId)

    await viewModel.loadAfterConnectionChange(connection: mailboxConnection)
    await service.waitUntilHistoricalBackfillStarts()

    XCTAssertTrue(viewModel.isRefreshDisabled)

    await service.releaseHistoricalBackfill()
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
      connectionId: connection.mailboxConnection(productAccountId: session.productAccountId).id
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
      productAccountId: session.productAccountId
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
      productAccountId: session.productAccountId
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
      connection: switchedConnection.mailboxConnection(productAccountId: session.productAccountId)
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
        "maxResults=50",
        "maxResults=50&pageToken=next-page-token",
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
    let fixture = try makeSyncFixture()
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
    XCTAssertEqual(
      fixture.requestRecorder.queries.filter { $0.contains("maxResults=50") },
      ["maxResults=50"]
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
      ["maxResults=50"]
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
      ["maxResults=50"]
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

  func testHistoricalBackfillStoresNonInboxMetadataWithoutShowingItInInbox() async throws {
    let fixture = try makeSyncFixture(
      usesPagination: true,
      labelIdsByMessageId: ["message-001": ["ARCHIVE"]]
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

  func testSyncInboxRejectsRefreshedTokenForDifferentGoogleAccount() async throws {
    let fixture = try makeSyncFixture(tokenInfoSubject: "different-gmail-user")

    do {
      _ = try await fixture.service.syncInbox(
        connection: connection,
        session: session
      )
      XCTFail("Expected refreshed token account mismatch")
    } catch GmailMessageMetadataSyncError.refreshedTokenAccountMismatch {
      XCTAssertEqual(fixture.store.savedMessages, [])
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

    XCTAssertEqual(
      fixture.recorder.requests.map(\.path),
      [
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/modify",
        "/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001/trash",
      ])
    XCTAssertEqual(fixture.recorder.requests[2].method, "POST")
    XCTAssertEqual(fixture.recorder.requests[2].jsonBody["addLabelIds"] as? [String], ["UNREAD"])
    XCTAssertEqual(fixture.recorder.requests[2].jsonBody["removeLabelIds"] as? [String], [])
    XCTAssertEqual(fixture.recorder.requests[5].method, "POST")
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
      "startHistoryId=123&labelId=INBOX"
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
    let fixture = try makeSyncFixture(
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
        "maxResults=25",
        "maxResults=25&pageToken=next-page-token",
      ]
    )
    XCTAssertTrue(fixture.requestRecorder.paths.contains("/gmail/v1/users/me/messages/message-003"))
    XCTAssertTrue(fixture.requestRecorder.paths.contains("/gmail/v1/users/me/messages/message-002"))
    XCTAssertTrue(fixture.requestRecorder.paths.contains("/gmail/v1/users/me/messages/message-001"))
    XCTAssertFalse(result.messages.contains { $0.providerMessageId == "message-stale" })
    XCTAssertFalse(fixture.store.savedMessages.contains { $0.providerMessageId == "message-stale" })
    XCTAssertTrue(fixture.store.savedMessages.contains { $0.providerMessageId == "message-001" })
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
      ["startHistoryId=123&labelId=INBOX"]
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
    labelIds: [String] = ["INBOX", "UNREAD"]
  ) -> Data {
    let replyToHeader =
      replyTo.map {
        ",\n            {\"name\": \"Reply-To\", \"value\": \"\($0)\"}"
      } ?? ""
    let encodedLabelIds = labelIds.map { "\"\($0)\"" }.joined(separator: ", ")
    return Data(
      """
      {
        "id": "\(messageId)",
        "threadId": "thread-001",
        "internalDate": "\(internalDate)",
        "labelIds": [\(encodedLabelIds)],
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
    replyTo: String? = nil,
    historyStatusCode: Int = 200,
    historyResponseData: Data = Data(#"{"history":[]}"#.utf8),
    shouldContinueHistoricalBackfill: @escaping () -> Bool = { true },
    labelIdsByMessageId: [String: [String]] = [:]
  ) throws -> GmailMessageMetadataSyncFixture {
    let eligibilityStore = RecordingGmailPushEligibilityStore()
    let store = RecordingGmailMessageMetadataStore()
    let tokenStore = RecordingGmailProviderTokenStore()
    let requestRecorder = GmailMetadataRequestRecorder()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let urlSession = ConvexClientTesting.makeSession { request in
      self.makeSyncResponse(
        for: request,
        requestRecorder: requestRecorder,
        tokenInfoSubject: tokenInfoSubject,
        usesPagination: usesPagination,
        replyTo: replyTo,
        labelIdsByMessageId: labelIdsByMessageId,
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
    replyTo: String?,
    labelIdsByMessageId: [String: [String]],
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
          {"sub":"\(tokenInfoSubject)","email":"user@example.com"}
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

    if request.url?.path == "/gmail/v1/users/me/messages" {
      if request.url?.query?.contains("maxResults=50") == true || historyStatusCode == 404 {
        XCTAssertFalse(request.url?.query?.contains("labelIds=INBOX") == true)
      } else {
        XCTAssertTrue(request.url?.query?.contains("labelIds=INBOX") == true)
      }
      if usesPagination, request.url?.query?.contains("pageToken=next-page-token") == true {
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
        labelIdsByMessageId: labelIdsByMessageId
      )
    )
  }

  private func makeMessageMetadataResponseData(
    for request: URLRequest,
    replyTo: String?,
    labelIdsByMessageId: [String: [String]]
  ) -> Data {
    let messageId = request.url?.lastPathComponent ?? ""
    let labelIds = labelIdsByMessageId[messageId] ?? ["INBOX", "UNREAD"]
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
  private let historicalBackfillGate = OverrideGate()
  private let historicalCategorizationGate = OverrideGate()
  private let overrideGate = OverrideGate()

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
    result(for: connection, using: messagesByProviderAccountIdentifier)
  }

  func syncInbox(
    connection: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    result(
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

private enum MailboxSwitchingError: Error {
  case historicalCategorizationFailed
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
