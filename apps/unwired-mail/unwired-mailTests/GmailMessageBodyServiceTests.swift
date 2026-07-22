import XCTest

@testable import unwired_mail

// swiftlint:disable file_length function_body_length type_body_length

final class GmailMessageBodyServiceTests: XCTestCase {
  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user-001",
    identityToken: "apple-token",
    productAccountId: "product-account-001",
    trustedDeviceId: "trusted-device-001"
  )

  private let message = GmailMessageMetadata(
    categoryId: "travel",
    from: "Sender <sender@example.com>",
    isHistorical: true,
    providerAccountIdentifier: "gmail-user-001",
    providerInternalDateMilliseconds: 1_781_197_200_000,
    providerMessageId: "message-001",
    providerThreadId: "thread-001",
    replyTo: nil,
    snippet: "Body preview",
    stableProviderMessageId: "gmail:gmail-user-001:message-001",
    subject: "Trip details",
    rfcMessageId: nil
  )

  private var connection: GmailProviderConnectionStatus {
    GmailProviderConnectionStatus(
      connectedAt: 1,
      emailAddress: "mailbox@example.com",
      lastVerifiedAt: 1,
      provider: "gmail",
      providerAccountIdentifier: "gmail-user-001",
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: 1
    )
  }

  func testPrefetchPlanSelectsNewestFiveHundredRecentInboxAndSentMessages() {
    let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    let referenceMilliseconds = Int64(referenceDate.timeIntervalSince1970 * 1_000)
    let recentMessages = (0..<501).map { offset in
      prefetchMessage(
        id: String(format: "recent-%03d", offset),
        internalDateMilliseconds: referenceMilliseconds - Int64(offset * 1_000),
        labels: offset.isMultiple(of: 2) ? ["INBOX"] : ["SENT"]
      )
    }
    let plan = GmailMessageBodyPrefetchPlan(
      messages: recentMessages + [
        prefetchMessage(
          id: "boundary",
          internalDateMilliseconds: referenceMilliseconds - 30 * 24 * 60 * 60 * 1_000,
          labels: ["INBOX"]
        ),
        prefetchMessage(
          id: "too-old",
          internalDateMilliseconds: referenceMilliseconds - 30 * 24 * 60 * 60 * 1_000 - 1,
          labels: ["INBOX"]
        ),
        prefetchMessage(
          id: "spam",
          internalDateMilliseconds: referenceMilliseconds,
          labels: ["INBOX", "SPAM"]
        ),
        prefetchMessage(
          id: "trash",
          internalDateMilliseconds: referenceMilliseconds,
          labels: ["SENT", "TRASH"]
        ),
      ],
      pinnedMessageIds: [],
      referenceDate: referenceDate
    )

    XCTAssertEqual(plan.recentMessages.count, 500)
    XCTAssertEqual(plan.recentMessages.first?.providerMessageId, "recent-000")
    XCTAssertEqual(plan.recentMessages.last?.providerMessageId, "recent-499")
    XCTAssertFalse(plan.messages.contains { $0.providerMessageId == "too-old" })
    XCTAssertFalse(plan.messages.contains { $0.providerMessageId == "spam" })
    XCTAssertFalse(plan.messages.contains { $0.providerMessageId == "trash" })
  }

  func testPrefetchPlanIncludesEligiblePinnedBodiesRegardlessOfAge() {
    let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    let oldTimestamp = Int64(
      referenceDate.addingTimeInterval(-90 * 24 * 60 * 60).timeIntervalSince1970 * 1_000
    )
    let eligiblePin = prefetchMessage(
      id: "eligible-pin",
      internalDateMilliseconds: oldTimestamp,
      labels: ["ARCHIVE"]
    )
    let spamPin = prefetchMessage(
      id: "spam-pin",
      internalDateMilliseconds: oldTimestamp,
      labels: ["SPAM"]
    )
    let draftPin = prefetchMessage(
      id: "draft-pin",
      internalDateMilliseconds: oldTimestamp,
      labels: ["DRAFT"]
    )
    let plan = GmailMessageBodyPrefetchPlan(
      messages: [eligiblePin, spamPin, draftPin],
      pinnedMessageIds: [
        eligiblePin.stableProviderMessageId,
        spamPin.stableProviderMessageId,
        draftPin.stableProviderMessageId,
      ],
      referenceDate: referenceDate
    )

    XCTAssertEqual(plan.pinnedMessages.map(\.providerMessageId), ["eligible-pin"])
    XCTAssertEqual(plan.messages.map(\.providerMessageId), ["eligible-pin"])
  }

  func testReadFetchesBodyOnDemandAndCachesOnlyEncryptedPayload() async throws {
    let fixture = try makeFixture()

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.text, "Private trip details")
    XCTAssertEqual(
      fixture.requestPaths, ["/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001"])
    XCTAssertNotNil(fixture.cache.payload)
    XCTAssertFalse(fixture.cache.serializedPayload.contains("Private trip details"))

    let cachedBody = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(cachedBody, body)
    XCTAssertEqual(
      fixture.requestPaths, ["/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001"])
  }

  func testPrefetchFetchesEligibleBodyAndCachesOnlyEncryptedPayload() async throws {
    let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    let prefetchedMessage = prefetchMessage(
      id: "message-001",
      internalDateMilliseconds: Int64(referenceDate.timeIntervalSince1970 * 1_000),
      labels: ["INBOX"]
    )
    let metadataStore = RecordingBodyPrefetchMetadataStore(messages: [prefetchedMessage])
    let fixture = try makeFixture(metadataStore: metadataStore)

    try await fixture.service.prefetchMessageBodies(
      connection: connection,
      pinnedMessageIds: [],
      referenceDate: referenceDate,
      session: session
    )

    XCTAssertEqual(
      fixture.requestPaths, ["/token", "/tokeninfo", "/gmail/v1/users/me/messages/message-001"])
    XCTAssertEqual(fixture.cache.retention, .prefetched)
    XCTAssertNotNil(fixture.cache.payload)
    XCTAssertFalse(fixture.cache.serializedPayload.contains("Private trip details"))
    XCTAssertEqual(
      try fixture.service.loadCachedMessageBody(message: prefetchedMessage, session: session)?.text,
      "Private trip details"
    )
  }

  func testPrefetchFailsBeforeProviderAccessWhenEncryptionMaterialIsMissing() async throws {
    let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    let prefetchedMessage = prefetchMessage(
      id: "message-001",
      internalDateMilliseconds: Int64(referenceDate.timeIntervalSince1970 * 1_000),
      labels: ["INBOX"]
    )
    let fixture = try makeFixture(
      hasKeyMaterial: false,
      metadataStore: RecordingBodyPrefetchMetadataStore(messages: [prefetchedMessage])
    )

    do {
      try await fixture.service.prefetchMessageBodies(
        connection: connection,
        pinnedMessageIds: [],
        referenceDate: referenceDate,
        session: session
      )
      XCTFail("Expected recovery to be required")
    } catch ProductSyncKeyMaterialStoreError.recoveryRequired {
      XCTAssertEqual(fixture.requestPaths, [])
      XCTAssertNil(fixture.cache.payload)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testPrefetchCancellationStopsBeforeProviderAccess() async throws {
    let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    let prefetchedMessage = prefetchMessage(
      id: "message-001",
      internalDateMilliseconds: Int64(referenceDate.timeIntervalSince1970 * 1_000),
      labels: ["INBOX"]
    )
    let fixture = try makeFixture(
      metadataStore: RecordingBodyPrefetchMetadataStore(messages: [prefetchedMessage])
    )
    let task = Task {
      try await fixture.service.prefetchMessageBodies(
        connection: connection,
        pinnedMessageIds: [],
        referenceDate: referenceDate,
        session: session
      )
    }
    task.cancel()

    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertEqual(fixture.requestPaths, [])
      XCTAssertNil(fixture.cache.payload)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testPrefetchRefetchesBodyAfterCacheEviction() async throws {
    let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    let prefetchedMessage = prefetchMessage(
      id: "message-001",
      internalDateMilliseconds: Int64(referenceDate.timeIntervalSince1970 * 1_000),
      labels: ["INBOX"]
    )
    let fixture = try makeFixture(
      metadataStore: RecordingBodyPrefetchMetadataStore(messages: [prefetchedMessage])
    )
    try await fixture.service.prefetchMessageBodies(
      connection: connection,
      pinnedMessageIds: [],
      referenceDate: referenceDate,
      session: session
    )
    try fixture.service.removeCachedMessageBody(message: prefetchedMessage, session: session)

    try await fixture.service.prefetchMessageBodies(
      connection: connection,
      pinnedMessageIds: [],
      referenceDate: referenceDate,
      session: session
    )

    XCTAssertEqual(
      fixture.requestPaths.compactMap { $0 as? String }
        .filter { $0 == "/gmail/v1/users/me/messages/message-001" }.count,
      2
    )
  }

  func testCachedReadDoesNotFetchMissingBodyFromGmail() throws {
    let fixture = try makeFixture()

    let body = try fixture.service.loadCachedMessageBody(message: message, session: session)

    XCTAssertNil(body)
    XCTAssertEqual(fixture.requestPaths, [])
  }

  func testReadPreservesSeparatorsBetweenHTMLTableCells() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"text/html","body":{"data":""#
        + #"PHRhYmxlPjx0cj48dGQ+SGk8L3RkPjx0ZD5UaGVyZTwvdGQ+PC90cj48L3RhYmxlPg=="#
        + #""}}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.text, "\nHi\n\nThere\n\n")
  }

  func testReadRemovesNonVisibleHTMLContentAndDecodesEntities() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"text/html","body":{"data":""#
        + #"PHN0eWxlPi5idXR0b257Y29sb3I6cmVkfTwvc3R5bGU+PHNjcmlwdD50cmFjaygpPC9zY3JpcHQ+PHA+"#
        + #"VG9tICZhbXA7IEplcnJ5Jm5ic3A7PC9wPg=="#
        + #""}}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertFalse(body.text.contains(".button"))
    XCTAssertFalse(body.text.contains("track()"))
    XCTAssertTrue(body.text.contains("Tom & Jerry\u{00A0}"))
  }

  func testReadDecodesNamedAndNumericHTMLEntities() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"text/html","body":{"data":""#
        + #"PHA+VG9tJnJzcXVvO3MmbmJzcDtub3RlJm1kYXNoOyYjODIxNzs8L3A+"#
        + #""}}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertTrue(body.text.contains("Tom’s\u{00A0}note—’"))
  }

  func testReadPreservesAttributedHTMLLineBreaks() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"text/html","body":{"data":""#
        + #"PHA+Rmlyc3Q8YnIgY2xhc3M9Im1lc3NhZ2UtYnJlYWsiPlNlY29uZDwvcD4="#
        + #""}}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertTrue(body.text.contains("First\nSecond"))
  }

  func testReadPrefersHTMLOverWhitespaceOnlyPlainTextAlternative() async throws {
    let fixture = try makeFixture(
      messageResponse:
        #"{"id":"message-001","payload":{"mimeType":"multipart/alternative","parts":["#
        + #"{"mimeType":"text/plain","body":{"data":"DQo="}},"#
        + #"{"mimeType":"text/html","body":{"data":"PHA+QWN0dWFsIGNvbnRlbnQ8L3A+"}}]}}"#
    )

    let body = try await fixture.service.loadMessageBody(message: message, session: session)

    XCTAssertTrue(body.text.contains("Actual content"))
  }

  func testReadRejectsMetadataOnlyTokenBeforeFetchingMessage() async throws {
    let fixture = try makeFixture(
      tokenInfoResponse:
        #"{"scope":"https://www.googleapis.com/auth/gmail.metadata","sub":"gmail-user-001"}"#
    )

    do {
      _ = try await fixture.service.loadMessageBody(message: message, session: session)
      XCTFail("Expected Gmail request failure")
    } catch GmailMessageBodyError.gmailRequestFailed {
      XCTAssertEqual(fixture.requestPaths, ["/token", "/tokeninfo"])
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testRemovingCachedBodyLeavesDurableMessageMetadataUntouched() async throws {
    let fixture = try makeFixture()
    _ = try await fixture.service.loadMessageBody(message: message, session: session)

    try fixture.service.removeCachedMessageBody(message: message, session: session)

    XCTAssertTrue(fixture.cache.didRemove)
    XCTAssertNil(fixture.cache.payload)
    XCTAssertEqual(message.categoryId, "travel")
    XCTAssertEqual(message.subject, "Trip details")
  }

  func testFileCacheClearsOnlySelectedMailboxPayload() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let cache = FileGmailMessageBodyCache(rootDirectory: rootDirectory)
    let payload = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: "ciphertext",
      keyVersion: 1,
      nonceBase64: "nonce",
      schemaVersion: 1,
      tagBase64: "tag"
    )

    let firstProviderAccountIdentifier = "gmail/user"
    let firstStableMessageId = "gmail:\(firstProviderAccountIdentifier):message-001"
    let secondProviderAccountIdentifier = "gmail:user"
    let secondStableMessageId = "gmail:\(secondProviderAccountIdentifier):message-002"
    try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    let legacyFirstURL = legacyBodyCacheURL(
      rootDirectory: rootDirectory,
      stableProviderMessageId: firstStableMessageId
    )
    try JSONEncoder().encode(payload).write(to: legacyFirstURL)
    try cache.saveMessageBody(
      payload,
      productAccountId: session.productAccountId,
      stableProviderMessageId: firstStableMessageId
    )
    try cache.saveMessageBody(
      payload,
      productAccountId: session.productAccountId,
      stableProviderMessageId: secondStableMessageId
    )
    XCTAssertNotNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: firstStableMessageId
      )
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFirstURL.path))

    try cache.clearMessageBodies(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: secondProviderAccountIdentifier
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFirstURL.path))

    let legacySecondURL = legacyBodyCacheURL(
      rootDirectory: rootDirectory,
      stableProviderMessageId: secondStableMessageId
    )
    try JSONEncoder().encode(payload).write(to: legacySecondURL)
    try cache.clearMessageBodies(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: secondProviderAccountIdentifier
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacySecondURL.path))

    XCTAssertNotNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: firstStableMessageId
      )
    )
    XCTAssertNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: secondStableMessageId
      )
    )

    try cache.clearMessageBodies(productAccountId: session.productAccountId)
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFirstURL.path))
  }

  func testReconcileKeepsLegacyCacheWithinDeviceBudget() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    let payload = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: String(repeating: "c", count: 128),
      keyVersion: 1,
      nonceBase64: "nonce",
      schemaVersion: 1,
      tagBase64: "tag"
    )
    let encodedPayload = try JSONEncoder().encode(payload)
    let messageIds = [
      "gmail:gmail-user-001:legacy-001",
      "gmail:gmail-user-001:legacy-002",
    ]
    for messageId in messageIds {
      try encodedPayload.write(
        to: bodyCacheURL(rootDirectory: rootDirectory, stableProviderMessageId: messageId)
      )
    }
    let cache = FileGmailMessageBodyCache(
      maximumByteCount: encodedPayload.count,
      rootDirectory: rootDirectory
    )

    try cache.reconcileSelection(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: "gmail-user-001",
      protectedMessageIds: Set(messageIds),
      pinnedMessageIds: []
    )

    XCTAssertLessThanOrEqual(try cacheByteCount(rootDirectory: rootDirectory), encodedPayload.count)
  }

  func testFileCacheEvictsOpenedThenPrefetchedThenPinnedBodiesAcrossConnections() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    let sizingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: rootDirectory)
      try? FileManager.default.removeItem(at: sizingDirectory)
    }
    let unlimitedCache = FileGmailMessageBodyCache(
      maximumByteCount: .max,
      rootDirectory: rootDirectory
    )
    let payload = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: String(repeating: "c", count: 128),
      keyVersion: 1,
      nonceBase64: "nonce",
      schemaVersion: 1,
      tagBase64: "tag"
    )
    let openedId = "gmail:gmail-user-001:opened"
    let prefetchedId = "gmail:gmail-user-002:prefetched"
    let pinnedId = "gmail:gmail-user-002:pinned"
    let firstIncomingId = "gmail:gmail-user-001:incoming-1"
    let secondIncomingId = "gmail:gmail-user-001:incoming-2"
    let thirdIncomingId = "gmail:gmail-user-001:incoming-3"
    XCTAssertTrue(
      try unlimitedCache.saveMessageBody(
        cacheWrite(payload: payload, retention: .opened, cachedAt: 1),
        productAccountId: session.productAccountId,
        stableProviderMessageId: openedId
      )
    )
    XCTAssertTrue(
      try unlimitedCache.saveMessageBody(
        cacheWrite(payload: payload, retention: .prefetched, cachedAt: 2),
        productAccountId: session.productAccountId,
        stableProviderMessageId: prefetchedId
      )
    )
    XCTAssertTrue(
      try unlimitedCache.saveMessageBody(
        cacheWrite(payload: payload, retention: .prefetched, isPinned: true, cachedAt: 3),
        productAccountId: session.productAccountId,
        stableProviderMessageId: pinnedId
      )
    )
    let incomingSize = try encodedCacheEntrySize(
      payload: payload,
      rootDirectory: sizingDirectory
    )

    try saveForcingOneEviction(
      payload: payload,
      stableProviderMessageId: firstIncomingId,
      incomingSize: incomingSize,
      rootDirectory: rootDirectory
    )
    XCTAssertNil(
      try unlimitedCache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: openedId
      )
    )
    XCTAssertNotNil(
      try unlimitedCache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: prefetchedId
      )
    )
    try unlimitedCache.removeMessageBody(
      productAccountId: session.productAccountId,
      stableProviderMessageId: firstIncomingId
    )

    try saveForcingOneEviction(
      payload: payload,
      stableProviderMessageId: secondIncomingId,
      incomingSize: incomingSize,
      rootDirectory: rootDirectory
    )
    XCTAssertNil(
      try unlimitedCache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: prefetchedId
      )
    )
    XCTAssertNotNil(
      try unlimitedCache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: pinnedId
      )
    )
    try unlimitedCache.removeMessageBody(
      productAccountId: session.productAccountId,
      stableProviderMessageId: secondIncomingId
    )

    try saveForcingOneEviction(
      payload: payload,
      stableProviderMessageId: thirdIncomingId,
      incomingSize: incomingSize,
      rootDirectory: rootDirectory
    )
    XCTAssertNil(
      try unlimitedCache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: pinnedId
      )
    )
  }

  func testFileCacheEvictsLeastRecentlyReadPinnedBodyLast() throws {
    let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    let sizingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: rootDirectory)
      try? FileManager.default.removeItem(at: sizingDirectory)
    }
    let cache = FileGmailMessageBodyCache(maximumByteCount: .max, rootDirectory: rootDirectory)
    let payload = ProductSyncEncryptedPayload(
      algorithm: ProductSyncEncryptedPayload.algorithmName,
      ciphertextBase64: String(repeating: "c", count: 128),
      keyVersion: 1,
      nonceBase64: "nonce",
      schemaVersion: 1,
      tagBase64: "tag"
    )
    let recentlyReadId = "gmail:gmail-user-001:recently-read-pin"
    let leastRecentlyReadId = "gmail:gmail-user-002:least-recently-read-pin"
    _ = try cache.saveMessageBody(
      cacheWrite(payload: payload, retention: .prefetched, isPinned: true, cachedAt: 1),
      productAccountId: session.productAccountId,
      stableProviderMessageId: recentlyReadId
    )
    _ = try cache.saveMessageBody(
      cacheWrite(payload: payload, retention: .prefetched, isPinned: true, cachedAt: 2),
      productAccountId: session.productAccountId,
      stableProviderMessageId: leastRecentlyReadId
    )
    try cache.recordMessageBodyAccess(
      productAccountId: session.productAccountId,
      stableProviderMessageId: recentlyReadId,
      accessedAt: Date(timeIntervalSince1970: 3)
    )
    let incomingSize = try encodedCacheEntrySize(
      payload: payload,
      rootDirectory: sizingDirectory
    )

    try saveForcingOneEviction(
      payload: payload,
      stableProviderMessageId: "gmail:gmail-user-001:incoming",
      incomingSize: incomingSize,
      rootDirectory: rootDirectory
    )

    XCTAssertNotNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: recentlyReadId
      )
    )
    XCTAssertNil(
      try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: leastRecentlyReadId
      )
    )
  }

  private func legacyBodyCacheURL(
    rootDirectory: URL,
    stableProviderMessageId: String
  ) -> URL {
    let productAccount = legacyGmailSafeFileComponent(session.productAccountId)
    let stableMessage = legacyGmailSafeFileComponent(stableProviderMessageId)
    return rootDirectory.appendingPathComponent(
      "\(productAccount)-\(stableMessage).json"
    )
  }

  private func bodyCacheURL(
    rootDirectory: URL,
    stableProviderMessageId: String
  ) -> URL {
    rootDirectory.appendingPathComponent(
      "\(gmailSafeFileComponent(session.productAccountId))-\(gmailSafeFileComponent(stableProviderMessageId)).json"
    )
  }

  private func prefetchMessage(
    id: String,
    internalDateMilliseconds: Int64,
    labels: [String]
  ) -> GmailMessageMetadata {
    GmailMessageMetadata(
      categoryId: nil,
      from: "sender@example.com",
      isHistorical: false,
      providerAccountIdentifier: "gmail-user-001",
      providerInternalDateMilliseconds: internalDateMilliseconds,
      providerLabelIds: labels,
      providerMessageId: id,
      providerThreadId: "thread-\(id)",
      replyTo: nil,
      snippet: "Preview",
      stableProviderMessageId: "gmail:gmail-user-001:\(id)",
      subject: "Message \(id)",
      rfcMessageId: nil
    )
  }

  private func encodedCacheEntrySize(
    payload: ProductSyncEncryptedPayload,
    rootDirectory: URL
  ) throws -> Int {
    let cache = FileGmailMessageBodyCache(maximumByteCount: .max, rootDirectory: rootDirectory)
    _ = try cache.saveMessageBody(
      cacheWrite(payload: payload, retention: .prefetched, cachedAt: 4),
      productAccountId: session.productAccountId,
      stableProviderMessageId: "gmail:gmail-user-001:sizing"
    )
    return try cacheByteCount(rootDirectory: rootDirectory)
  }

  private func saveForcingOneEviction(
    payload: ProductSyncEncryptedPayload,
    stableProviderMessageId: String,
    incomingSize: Int,
    rootDirectory: URL
  ) throws {
    let currentSize = try cacheByteCount(rootDirectory: rootDirectory)
    let cache = FileGmailMessageBodyCache(
      maximumByteCount: currentSize + incomingSize - 1,
      rootDirectory: rootDirectory
    )
    XCTAssertTrue(
      try cache.saveMessageBody(
        cacheWrite(payload: payload, retention: .prefetched, cachedAt: 4),
        productAccountId: session.productAccountId,
        stableProviderMessageId: stableProviderMessageId
      )
    )
  }

  private func cacheByteCount(rootDirectory: URL) throws -> Int {
    try FileManager.default.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: [.fileSizeKey]
    ).reduce(0) { count, fileURL in
      count + (try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
  }

  private func cacheWrite(
    payload: ProductSyncEncryptedPayload,
    retention: GmailMessageBodyCacheRetention,
    isPinned: Bool = false,
    cachedAt: TimeInterval
  ) -> GmailMessageBodyCacheWrite {
    GmailMessageBodyCacheWrite(
      cachedAt: Date(timeIntervalSince1970: cachedAt),
      isPinned: isPinned,
      isProtected: false,
      payload: payload,
      retention: retention
    )
  }

  func testReadFetchesAttachmentBackedBodyOnDemand() async throws {
    let cache = RecordingGmailMessageBodyCache()
    let keyMaterialStore = RecordingBodyCacheKeyMaterialStore()
    try keyMaterialStore.save(
      ProductSyncKeyMaterial.create(
        accountKeyData: Data(repeating: 1, count: ProductSyncKeyMaterial.keyByteCount),
        recoveryKeyData: Data(repeating: 2, count: ProductSyncKeyMaterial.keyByteCount)
      ),
      productAccountId: session.productAccountId
    )
    let tokenStore = RecordingBodyCacheTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let urlSession = ConvexClientTesting.makeSession { request in
      if request.url?.path == "/token" {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }
      if request.url?.path == "/tokeninfo" {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(
            #"{"scope":"https://www.googleapis.com/auth/gmail.readonly","sub":"gmail-user-001"}"#
              .utf8
          )
        )
      }
      if request.url?.path.hasSuffix("/attachments/attachment-001") == true {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(#"{"data":"UHJpdmF0ZSBhdHRhY2htZW50IGJvZHk"}"#.utf8)
        )
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(
          #"{"id":"message-001","payload":{"mimeType":"text/plain","body":{"attachmentId":"attachment-001"}}}"#
            .utf8)
      )
    }
    let service = GmailMessageBodyService(
      gmailBaseURL: URL(string: "https://gmail.example.test/gmail/v1")!,
      cache: cache,
      keyMaterialStore: keyMaterialStore,
      oauthClientId: "gmail-client-id",
      session: urlSession,
      tokenStore: tokenStore,
      tokenRefreshURL: URL(string: "https://gmail.example.test/token")!,
      tokenInfoURL: URL(string: "https://gmail.example.test/tokeninfo")!
    )

    let body = try await service.loadMessageBody(message: message, session: session)

    XCTAssertEqual(body.text, "Private attachment body")
  }

  private func makeFixture(
    hasKeyMaterial: Bool = true,
    metadataStore: GmailMessageMetadataPersisting = RecordingBodyPrefetchMetadataStore(),
    tokenInfoResponse: String =
      #"{"scope":"https://www.googleapis.com/auth/gmail.readonly","sub":"gmail-user-001"}"#,
    messageResponse: String =
      #"{"id":"message-001","payload":{"mimeType":"text/plain","body":{"data":"UHJpdmF0ZSB0cmlwIGRldGFpbHM"}}}"#
  ) throws -> GmailMessageBodyFixture {
    let cache = RecordingGmailMessageBodyCache()
    let keyMaterialStore = RecordingBodyCacheKeyMaterialStore()
    if hasKeyMaterial {
      try keyMaterialStore.save(
        ProductSyncKeyMaterial.create(
          accountKeyData: Data(repeating: 1, count: ProductSyncKeyMaterial.keyByteCount),
          recoveryKeyData: Data(repeating: 2, count: ProductSyncKeyMaterial.keyByteCount)
        ),
        productAccountId: session.productAccountId
      )
    }
    let tokenStore = RecordingBodyCacheTokenStore()
    try tokenStore.save(
      GmailProviderTokens(accessToken: "access-token", refreshToken: "refresh-token"),
      productAccountId: session.productAccountId
    )
    let requestPaths = NSMutableArray()
    let urlSession = ConvexClientTesting.makeSession { request in
      requestPaths.add(request.url!.path)
      if request.url?.path == "/token" {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(#"{"access_token":"refreshed-access-token"}"#.utf8)
        )
      }
      if request.url?.path == "/tokeninfo" {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(tokenInfoResponse.utf8)
        )
      }
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-access-token")
      XCTAssertEqual(request.url?.query, "format=full")
      return (
        HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!,
        Data(messageResponse.utf8)
      )
    }
    return GmailMessageBodyFixture(
      cache: cache,
      requestPaths: requestPaths,
      service: GmailMessageBodyService(
        gmailBaseURL: URL(string: "https://gmail.example.test/gmail/v1")!,
        cache: cache,
        keyMaterialStore: keyMaterialStore,
        metadataStore: metadataStore,
        oauthClientId: "gmail-client-id",
        session: urlSession,
        tokenStore: tokenStore,
        tokenRefreshURL: URL(string: "https://gmail.example.test/token")!,
        tokenInfoURL: URL(string: "https://gmail.example.test/tokeninfo")!
      )
    )
  }
}

private struct GmailMessageBodyFixture {
  let cache: RecordingGmailMessageBodyCache
  let requestPaths: NSMutableArray
  let service: GmailMessageBodyService
}

private final class RecordingGmailMessageBodyCache: GmailMessageBodyCaching {
  var didRemove = false
  var payload: ProductSyncEncryptedPayload?
  var retention: GmailMessageBodyCacheRetention?

  var serializedPayload: String {
    guard let payload, let data = try? JSONEncoder().encode(payload) else {
      return ""
    }
    return String(bytes: data, encoding: .utf8) ?? ""
  }

  func clearMessageBodies(productAccountId _: String) throws {
    payload = nil
  }

  func loadMessageBody(
    productAccountId _: String,
    stableProviderMessageId _: String
  ) throws -> ProductSyncEncryptedPayload? {
    payload
  }

  func removeMessageBody(
    productAccountId _: String,
    stableProviderMessageId _: String
  ) throws {
    didRemove = true
    payload = nil
  }

  func saveMessageBody(
    _ payload: ProductSyncEncryptedPayload,
    productAccountId _: String,
    stableProviderMessageId _: String
  ) throws {
    self.payload = payload
  }

  func saveMessageBody(
    _ write: GmailMessageBodyCacheWrite,
    productAccountId _: String,
    stableProviderMessageId _: String
  ) throws -> Bool {
    payload = write.payload
    retention = write.retention
    return true
  }
}

private final class RecordingBodyPrefetchMetadataStore: GmailMessageMetadataPersisting {
  var messages: [GmailMessageMetadata]

  init(messages: [GmailMessageMetadata] = []) {
    self.messages = messages
  }

  func clearMessages(productAccountId _: String) throws {
    messages = []
  }

  func loadMessages(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> [GmailMessageMetadata] {
    messages
  }

  func loadSyncState(
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws -> GmailMetadataSyncState? {
    nil
  }

  func saveSyncPage(
    _ messages: [GmailMessageMetadata],
    state _: GmailMetadataSyncState,
    isFirstPage _: Bool,
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    self.messages = messages
  }

  func saveMessages(
    _ messages: [GmailMessageMetadata],
    productAccountId _: String,
    providerAccountIdentifier _: String
  ) throws {
    self.messages = messages
  }
}

private final class RecordingBodyCacheKeyMaterialStore: ProductSyncKeyMaterialPersisting {
  var material: ProductSyncKeyMaterial?

  func clear(productAccountId _: String) throws {
    material = nil
  }

  func ensureMaterial(
    productAccountId _: String,
    allowCreation _: Bool
  ) throws -> ProductSyncKeyMaterial {
    try XCTUnwrap(material)
  }

  func load(productAccountId _: String) throws -> ProductSyncKeyMaterial? {
    material
  }

  func restore(
    productAccountId _: String,
    recoveryKey _: ProductSyncRecoveryKey,
    recoveryWrappedAccountKey _: ProductSyncEncryptedPayload
  ) throws -> ProductSyncKeyMaterial {
    try XCTUnwrap(material)
  }

  func save(_ material: ProductSyncKeyMaterial, productAccountId _: String) throws {
    self.material = material
  }
}

private final class RecordingBodyCacheTokenStore: GmailProviderTokenPersisting {
  var tokens: GmailProviderTokens?

  func clear(productAccountId _: String) throws {
    tokens = nil
  }

  func clear(productAccountId: String, providerAccountIdentifier _: String) throws {
    try clear(productAccountId: productAccountId)
  }

  func clearAll(productAccountId: String) throws {
    try clear(productAccountId: productAccountId)
  }

  func load(productAccountId _: String) throws -> GmailProviderTokens? {
    tokens
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier _: String
  ) throws -> GmailProviderTokens? {
    try load(productAccountId: productAccountId)
  }

  func save(_ tokens: GmailProviderTokens, productAccountId _: String) throws {
    self.tokens = tokens
  }

  func save(
    _ tokens: GmailProviderTokens,
    productAccountId: String,
    providerAccountIdentifier _: String
  ) throws {
    try save(tokens, productAccountId: productAccountId)
  }
}
